<#
.SYNOPSIS
    Read-only audit of KB5014754 certificate-based authentication mapping posture across
    Active Directory domain controllers and accounts with explicit altSecurityIdentities mappings.

.DESCRIPTION
    Checks, per domain controller, the effective KB5014754 enforcement state (patch-date-derived,
    since the StrongCertificateBindingEnforcement registry key is non-functional on any DC patched
    with the September 9, 2025 security update or later), the KDC UseSubjectAltName and
    CertificateBackdatingCompensation values, the Schannel CertificateMappingMethods bitmask, and
    a recent count of Kdcsvc Event 39/40/41 (missing strong mapping / certificate predates account /
    SID mismatch). Optionally audits every AD account carrying an explicit altSecurityIdentities
    value and classifies each mapping as weak or strong.

    Does not modify any registry value, GPO, certificate, or AD attribute. Does not inspect
    certificate content itself (no access to the private/public certificate store data beyond
    what AD's altSecurityIdentities attribute already stores as text) — use certutil -dump
    separately against a specific certificate file to check for the SID extension.

.PARAMETER DomainControllers
    Specific DC hostnames to audit. Defaults to every DC in the current domain via
    Get-ADDomainController -Filter *.

.PARAMETER EventLookbackCount
    Maximum number of recent Event 39/40/41 entries to retrieve per DC for counting. Default: 500.

.PARAMETER AuditUserMappings
    Switch. If set, also enumerates every AD user/computer object with a non-empty
    altSecurityIdentities attribute and classifies each mapping string as Weak or Strong.
    This can be a heavy query in large domains — omitted by default.

.PARAMETER OutputPath
    Folder to write the CSV report(s) to. Defaults to the current directory.

.EXAMPLE
    .\Get-CertificateMappingAudit.ps1
    Audits every DC's registry/patch-level posture and recent event counts, writes a CSV.

.EXAMPLE
    .\Get-CertificateMappingAudit.ps1 -AuditUserMappings -OutputPath C:\Temp\CertMappingAudit
    Also inventories and classifies every account's explicit altSecurityIdentities mapping(s).

.NOTES
    Requires: RSAT ActiveDirectory module, PowerShell remoting (WinRM) enabled on target DCs for
    the registry/hotfix/event checks, and read access to AD objects for -AuditUserMappings.
    Run-as: Domain account with read access to DC registry (remote) and AD user attributes.
    Safe: read-only throughout. Does not require Domain Admin, only remote-registry-read rights
    on target DCs (typically already covered by domain admin / delegated DC-management roles)
    and standard AD read permissions for the optional user-mapping audit.
    Windows PowerShell 5.1 compatible — no PowerShell-7-only operators used.
#>
#Requires -Modules ActiveDirectory
[CmdletBinding()]
param(
    [string[]]$DomainControllers,
    [int]$EventLookbackCount = 500,
    [switch]$AuditUserMappings,
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# Full Enforcement became permanent/unbypassable on DCs patched with this update or later.
$FullEnforcementCutoverDate = Get-Date "2025-09-09"

# altSecurityIdentities mapping-type classification (per KB5014754 guidance)
$WeakMappingPatterns   = @("X509:<I>.*<S>", "X509:<S>", "X509:<RFC822>")
$StrongMappingPatterns = @("X509:<I>.*<SR>", "X509:<SKI>", "X509:<SHA1-PUKEY>")

function Get-AltSecurityIdentityClassification {
    param([string]$MappingString)
    if ($MappingString -match "<SR>") { return "Strong (X509IssuerSerialNumber)" }
    if ($MappingString -match "<SKI>") { return "Strong (X509SKI)" }
    if ($MappingString -match "<SHA1-PUKEY>") { return "Strong (X509SHA1PublicKey)" }
    if ($MappingString -match "<RFC822>") { return "Weak (X509RFC822 / email)" }
    if ($MappingString -match "<I>.*<S>") { return "Weak (X509IssuerSubject)" }
    if ($MappingString -match "^X509:<S>") { return "Weak (X509SubjectOnly)" }
    return "Unrecognized format"
}

Write-Status "Starting KB5014754 certificate mapping audit..."

# ---- Preflight ----
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Status "ActiveDirectory module not available. Install RSAT AD PowerShell tools." "ERROR"
    throw
}

if (-not (Test-Path -Path $OutputPath)) {
    Write-Status "Output path '$OutputPath' does not exist, creating it." "WARN"
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

if (-not $DomainControllers) {
    Write-Status "No -DomainControllers specified, discovering all DCs in the current domain..."
    $DomainControllers = (Get-ADDomainController -Filter *).HostName
}
Write-Status "Auditing $($DomainControllers.Count) domain controller(s)."

# ---- Detect / Execute: per-DC registry, patch level, and event counts ----
$dcResults = New-Object System.Collections.Generic.List[Object]

foreach ($dc in $DomainControllers) {
    Write-Status "Querying $dc..."
    try {
        $data = Invoke-Command -ComputerName $dc -ErrorAction Stop -ScriptBlock {
            $latestHotfix = Get-HotFix -ErrorAction SilentlyContinue |
                Sort-Object InstalledOn -Descending | Select-Object -First 1

            $strongBinding = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" `
                -Name "StrongCertificateBindingEnforcement" -ErrorAction SilentlyContinue).StrongCertificateBindingEnforcement
            $useSAN = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" `
                -Name "UseSubjectAltName" -ErrorAction SilentlyContinue).UseSubjectAltName
            $backdating = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" `
                -Name "CertificateBackdatingCompensation" -ErrorAction SilentlyContinue).CertificateBackdatingCompensation
            $schannelMethods = (Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\SecurityProviders\Schannel" `
                -Name "CertificateMappingMethods" -ErrorAction SilentlyContinue).CertificateMappingMethods

            [PSCustomObject]@{
                LatestHotfixDate    = $latestHotfix.InstalledOn
                StrongBindingValue  = $strongBinding
                UseSubjectAltName   = $useSAN
                BackdatingValue     = $backdating
                SchannelMethods     = $schannelMethods
            }
        }

        $event39Count = (Invoke-Command -ComputerName $dc -ErrorAction SilentlyContinue -ScriptBlock {
            param($max)
            (Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Kdcsvc'] and (EventID=39)]]" -MaxEvents $max -ErrorAction SilentlyContinue).Count
        } -ArgumentList $EventLookbackCount)
        $event40Count = (Invoke-Command -ComputerName $dc -ErrorAction SilentlyContinue -ScriptBlock {
            param($max)
            (Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Kdcsvc'] and (EventID=40)]]" -MaxEvents $max -ErrorAction SilentlyContinue).Count
        } -ArgumentList $EventLookbackCount)
        $event41Count = (Invoke-Command -ComputerName $dc -ErrorAction SilentlyContinue -ScriptBlock {
            param($max)
            (Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Kdcsvc'] and (EventID=41)]]" -MaxEvents $max -ErrorAction SilentlyContinue).Count
        } -ArgumentList $EventLookbackCount)

        $isPastCutover = $false
        if ($data.LatestHotfixDate) {
            $isPastCutover = ([DateTime]$data.LatestHotfixDate) -ge $FullEnforcementCutoverDate
        }

        $effectiveState = if ($isPastCutover) {
            "Full Enforcement (permanent — registry key non-functional at this patch level)"
        } elseif ($data.StrongBindingValue -eq 2) {
            "Full Enforcement (registry-set)"
        } elseif ($data.StrongBindingValue -eq 1) {
            "Compatibility mode (registry-set) — WARN: bridge only, verify patch plan"
        } elseif ($data.StrongBindingValue -eq 0) {
            "Disabled (registry-set) — WARN: strong mapping check bypassed entirely"
        } else {
            "Unknown / registry key not set and patch level unconfirmed — verify manually"
        }

        $dcResults.Add([PSCustomObject]@{
            DomainController      = $dc
            LatestHotfixDate      = $data.LatestHotfixDate
            PastSept2025Cutover   = $isPastCutover
            EffectiveEnforcement  = $effectiveState
            StrongBindingRegistry = $data.StrongBindingValue
            UseSubjectAltName     = $data.UseSubjectAltName
            BackdatingCompRegistry= $data.BackdatingValue
            SchannelMappingMethods= $data.SchannelMethods
            Event39Count          = $event39Count
            Event40Count          = $event40Count
            Event41Count          = $event41Count
            Event41_RequiresReview= ($event41Count -gt 0)
        })

        if ($event41Count -gt 0) {
            Write-Status "$dc has $event41Count Event 41 (SID mismatch) hit(s) — review before dismissing as routine." "WARN"
        }
    } catch {
        Write-Status "Failed to query $dc : $($_.Exception.Message)" "ERROR"
        $dcResults.Add([PSCustomObject]@{
            DomainController      = $dc
            LatestHotfixDate      = "ERROR"
            PastSept2025Cutover   = "ERROR"
            EffectiveEnforcement  = "ERROR - could not connect/query"
            StrongBindingRegistry = $null
            UseSubjectAltName     = $null
            BackdatingCompRegistry= $null
            SchannelMappingMethods= $null
            Event39Count          = $null
            Event40Count          = $null
            Event41Count          = $null
            Event41_RequiresReview= $false
        })
    }
}

$dcReportPath = Join-Path $OutputPath "CertificateMappingAudit_DCs_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$dcResults | Export-Csv -Path $dcReportPath -NoTypeInformation
Write-Status "DC-level report written to $dcReportPath" "OK"

# ---- Optional: per-account altSecurityIdentities inventory and classification ----
if ($AuditUserMappings) {
    Write-Status "Auditing accounts with explicit altSecurityIdentities mappings (this may take a while in large domains)..."
    $mappingResults = New-Object System.Collections.Generic.List[Object]

    $accounts = Get-ADUser -Filter { altSecurityIdentities -like "*" } -Properties altSecurityIdentities, SamAccountName, whenCreated -ErrorAction SilentlyContinue
    $computerAccounts = Get-ADComputer -Filter { altSecurityIdentities -like "*" } -Properties altSecurityIdentities, SamAccountName, whenCreated -ErrorAction SilentlyContinue

    $allAccounts = @()
    if ($accounts) { $allAccounts += $accounts }
    if ($computerAccounts) { $allAccounts += $computerAccounts }

    foreach ($acct in $allAccounts) {
        foreach ($mapping in $acct.altSecurityIdentities) {
            $mappingResults.Add([PSCustomObject]@{
                SamAccountName  = $acct.SamAccountName
                AccountCreated  = $acct.whenCreated
                MappingString   = $mapping
                Classification  = Get-AltSecurityIdentityClassification -MappingString $mapping
            })
        }
    }

    $weakCount = ($mappingResults | Where-Object { $_.Classification -like "Weak*" }).Count
    if ($weakCount -gt 0) {
        Write-Status "$weakCount weak mapping(s) found across $($allAccounts.Count) account(s) — these do NOT satisfy Full Enforcement on their own." "WARN"
    }

    $mappingReportPath = Join-Path $OutputPath "CertificateMappingAudit_UserMappings_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $mappingResults | Export-Csv -Path $mappingReportPath -NoTypeInformation
    Write-Status "Account mapping report written to $mappingReportPath ($($mappingResults.Count) mapping value(s) across $($allAccounts.Count) account(s))" "OK"
} else {
    Write-Status "Skipped account-level altSecurityIdentities audit (use -AuditUserMappings to include it)."
}

# ---- Report summary ----
Write-Status "Audit complete." "OK"
$dcResults | Format-Table DomainController, EffectiveEnforcement, Event39Count, Event40Count, Event41Count, Event41_RequiresReview -AutoSize
