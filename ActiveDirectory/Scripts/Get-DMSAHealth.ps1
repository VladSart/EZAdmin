<#
.SYNOPSIS
    Audits Delegated Managed Service Account (dMSA) health across the platform prerequisite,
    KDS root key, AD delegation, and migration-state layers.

.DESCRIPTION
    Read-only diagnostic script matching the dependency stack documented in
    ActiveDirectory/Troubleshooting/dMSA/dMSA-A.md and dMSA-B.md. Checks, in order:
      1. Platform prerequisite — at least one Windows Server 2025 DC in the domain
         (Get-ADDomainController). Without this, dMSA is architecturally unavailable.
      2. Forest KDS root key existence and EffectiveTime convergence (Get-KdsRootKey) —
         shared prerequisite with gMSA.
      3. Every dMSA object in the domain (or the -Identity list): Enabled state,
         msDS-DelegatedMSAState interpretation, PrincipalsAllowedToRetrieveManagedPassword
         delegation (direct + resolved group membership), and, for migration-linked dMSAs,
         the linked legacy account's own Enabled/superseded state and elapsed time since
         Start-ADServiceAccountMigration against the ~14/28-day observation guidance.
      4. Optionally, when run FROM a target host with -TestLocal, the local
         DelegatedMSAEnabled registry/GPO gate and a scan of the dMSA-relevant
         Kerberos Operational event log (Event IDs 307/308/309).

    This script does NOT create, modify, or remove any AD object, does NOT call
    Start-/Complete-/Undo-/Reset-ADServiceAccountMigration, and does NOT change any
    local registry/GPO value. It requires the ActiveDirectory PowerShell module (RSAT
    for Windows Server 2025 / Windows 11 24H2+) for Parts 1-3, run from a DC or a
    management host. Part 4 (-TestLocal) must be run interactively on the specific
    host being diagnosed, since the client-side policy gate and event log are host-local.

.PARAMETER Identity
    One or more dMSA names (sAMAccountName, without the trailing $) to audit.
    If omitted, audits every dMSA object in the domain.

.PARAMETER TestLocal
    Switch. When present, also checks the local DelegatedMSAEnabled registry/GPO value
    and scans the Microsoft-Windows-Security-Kerberos/Operational event log on THIS host
    for dMSA-relevant events (IDs 307/308/309). Only meaningful when run directly on a
    host that consumes (or is being onboarded to consume) the dMSA(s).

.PARAMETER EventLogLookbackHours
    How far back to scan the Kerberos Operational event log when -TestLocal is used.
    Default: 24.

.PARAMETER OutputPath
    Folder to write the CSV summary to. Default: current directory.

.EXAMPLE
    .\Get-DMSAHealth.ps1
    Audits every dMSA in the domain from the platform/KDS/delegation/migration-state
    perspective.

.EXAMPLE
    .\Get-DMSAHealth.ps1 -Identity "dMSA-webapp01" -TestLocal
    Audits a single dMSA and, since run with -TestLocal, also checks this host's
    DelegatedMSAEnabled policy state and its Kerberos Operational log for the last 24 hours.

.EXAMPLE
    .\Get-DMSAHealth.ps1 -Identity "dMSA-webapp01","dMSA-sqlagent" -OutputPath "C:\Temp"
    Audits two named dMSAs and writes DMSAHealth_<timestamp>.csv to C:\Temp.

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT) for Parts 1-3, on a management
              host or DC that itself is (or can query) Windows Server 2025-aware.
    Run-as: Any account with read access to dMSA objects, the KDS root key container,
            and DC OS attributes is sufficient for Parts 1-3 (no elevated rights
            required for read-only audit). -TestLocal should be run as (or
            Invoke-Command'd against) the host/service context that actually consumes
            or will consume the dMSA, since the policy gate and event log are per-host.
    Safe/Unsafe: 100% read-only. No AD objects are created, modified, or removed; no
                 migration cmdlets are called; no registry/GPO values are changed.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$Identity,

    [Parameter(Mandatory = $false)]
    [switch]$TestLocal,

    [Parameter(Mandatory = $false)]
    [int]$EventLogLookbackHours = 24,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-DelegatedMSAStateText {
    param($StateValue)
    switch ($StateValue) {
        0       { return "0 = uninitialized/unlinked" }
        1       { return "1 = migration in progress" }
        2       { return "2 = migration completed" }
        3       { return "3 = standalone dMSA" }
        default { return "UNKNOWN ($StateValue)" }
    }
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Status "ActiveDirectory module not available. Install RSAT: AD DS and AD LDS Tools (Windows Server 2025 / Windows 11 24H2+ for dMSA cmdlet support), or run from a DC." "ERROR"
    throw
}

$results = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# Part 1 — Platform prerequisite: at least one Windows Server 2025 DC
# ---------------------------------------------------------------------------
Write-Status "Checking for a Windows Server 2025 domain controller..."

$allDCs = @(Get-ADDomainController -Filter * -ErrorAction SilentlyContinue |
    Select-Object HostName, OperatingSystem, Site)
$ws2025DCs = @($allDCs | Where-Object { $_.OperatingSystem -match "2025" })

if ($ws2025DCs.Count -eq 0) {
    Write-Status "No Windows Server 2025 DC found. dMSA is architecturally unavailable in this domain until one exists — this is the #1 wrong-ticket / not-yet-ready cause." "ERROR"
    $platformFlag = "NO_WS2025_DC"
} else {
    Write-Status "Found $($ws2025DCs.Count) Windows Server 2025 DC(s): $($ws2025DCs.HostName -join ', ')" "OK"
    $platformFlag = "OK"
}

# ---------------------------------------------------------------------------
# Part 2 — KDS Root Key state (shared prerequisite with gMSA, checked once)
# ---------------------------------------------------------------------------
Write-Status "Checking KDS root key state..."

$kdsKeys = @(Get-KdsRootKey -ErrorAction SilentlyContinue)

if ($kdsKeys.Count -eq 0) {
    Write-Status "No KDS root key found in this forest. No gMSA or dMSA can retrieve a password until one is created (Add-KdsRootKey)." "ERROR"
    $kdsFlag = "NO_KDS_ROOT_KEY"
} else {
    $convergedKeys = @($kdsKeys | Where-Object { $_.EffectiveTime -le (Get-Date) })
    if ($convergedKeys.Count -eq 0) {
        $earliest = ($kdsKeys | Sort-Object EffectiveTime | Select-Object -First 1).EffectiveTime
        Write-Status "KDS root key(s) exist but none have converged yet. Earliest EffectiveTime: $earliest (default 10-hour post-creation delay)." "WARN"
        $kdsFlag = "KDS_NOT_CONVERGED"
    } else {
        Write-Status "KDS root key converged. $($convergedKeys.Count) usable key(s) found." "OK"
        $kdsFlag = "OK"
    }
}

# ---------------------------------------------------------------------------
# Part 3 — dMSA object inventory, delegation, and migration state
# ---------------------------------------------------------------------------
Write-Status "Enumerating dMSA object(s)..."

$dmsaProps = @(
    "Enabled", "DNSHostName", "PrincipalsAllowedToRetrieveManagedPassword",
    "msDS-DelegatedMSAState", "msDS-ManagedAccountPrecededByLink", "whenCreated",
    "KerberosEncryptionType"
)

if ($Identity) {
    $dmsaAccounts = foreach ($id in $Identity) {
        try {
            Get-ADServiceAccount -Identity $id -Properties $dmsaProps -ErrorAction Stop
        } catch {
            Write-Status "dMSA '$id' not found: $($_.Exception.Message)" "ERROR"
        }
    }
} else {
    try {
        $dmsaAccounts = Get-ADServiceAccount -Filter { ObjectClass -eq "msDS-DelegatedManagedServiceAccount" } `
            -Properties $dmsaProps -ErrorAction Stop
    } catch {
        Write-Status "Could not query msDS-DelegatedManagedServiceAccount objects — schema may not be extended to Windows Server 2025 level yet. $($_.Exception.Message)" "ERROR"
        $dmsaAccounts = @()
    }
}

if (-not $dmsaAccounts -or @($dmsaAccounts).Count -eq 0) {
    Write-Status "No dMSA objects found (or none matched -Identity)." "WARN"
}

foreach ($dmsa in @($dmsaAccounts)) {

    if (-not $dmsa) { continue }

    $name = $dmsa.Name
    Write-Status "Auditing dMSA: $name" "INFO"

    $findings = [System.Collections.Generic.List[string]]::new()

    if (-not $dmsa.Enabled) {
        $findings.Add("ACCOUNT_DISABLED")
    }

    $stateValue = $dmsa."msDS-DelegatedMSAState"
    $stateText = Get-DelegatedMSAStateText -StateValue $stateValue

    if ($null -eq $stateValue -or $stateValue -eq 0) {
        $findings.Add("STATE_UNINITIALIZED")
    }

    # Resolve delegation — direct entries and group-based entries
    $delegatedPrincipals = @($dmsa.PrincipalsAllowedToRetrieveManagedPassword)
    $resolvedHostCount = 0
    $delegationDetail = [System.Collections.Generic.List[string]]::new()

    if ($delegatedPrincipals.Count -eq 0) {
        $findings.Add("NO_DELEGATION_CONFIGURED")
    } else {
        foreach ($principalDN in $delegatedPrincipals) {
            try {
                $obj = Get-ADObject -Identity $principalDN -Properties ObjectClass -ErrorAction Stop
                if ($obj.ObjectClass -eq "group") {
                    $memberCount = @(Get-ADGroupMember -Identity $principalDN -ErrorAction SilentlyContinue |
                        Where-Object { $_.objectClass -eq "computer" }).Count
                    $delegationDetail.Add("Group '$($obj.Name)' ($memberCount computer member(s))")
                    $resolvedHostCount += $memberCount
                } elseif ($obj.ObjectClass -eq "computer") {
                    $delegationDetail.Add("Direct host: $($obj.Name)")
                    $resolvedHostCount += 1
                } else {
                    $delegationDetail.Add("Other principal: $($obj.Name) ($($obj.ObjectClass))")
                }
            } catch {
                $delegationDetail.Add("UNRESOLVABLE_PRINCIPAL: $principalDN")
                $findings.Add("DELEGATION_PRINCIPAL_UNRESOLVABLE")
            }
        }
        if ($resolvedHostCount -eq 0) {
            $findings.Add("DELEGATION_RESOLVES_TO_ZERO_HOSTS")
        }
    }

    # Migration-in-progress specific checks
    $legacyAccountSummary = "N/A (not migration-linked)"
    if ($stateValue -eq 1) {
        $precededByLink = $dmsa."msDS-ManagedAccountPrecededByLink"
        if ($precededByLink) {
            try {
                $legacy = Get-ADObject -Identity $precededByLink -Properties Enabled, whenChanged -ErrorAction Stop
                $daysSinceLink = ((Get-Date) - $dmsa.whenCreated).TotalDays
                $legacyAccountSummary = "Legacy: $($legacy.Name), Enabled=$($legacy.Enabled)"
                if ($daysSinceLink -lt 14) {
                    $findings.Add("MIGRATION_WITHIN_OBSERVATION_WINDOW (~$([math]::Round($daysSinceLink,1))d elapsed, MS guidance recommends >=14d before Complete-)")
                } elseif ($daysSinceLink -ge 14 -and $daysSinceLink -lt 28) {
                    $findings.Add("MIGRATION_APPROACHING_TYPICAL_COMPLETION_WINDOW (~$([math]::Round($daysSinceLink,1))d elapsed)")
                } else {
                    $findings.Add("MIGRATION_PAST_TYPICAL_WINDOW_STILL_OPEN (~$([math]::Round($daysSinceLink,1))d elapsed — confirm intent, may simply be forgotten)")
                }
            } catch {
                $legacyAccountSummary = "UNRESOLVABLE_LEGACY_LINK: $precededByLink"
                $findings.Add("LEGACY_LINK_UNRESOLVABLE")
            }
        } else {
            $findings.Add("STATE_1_BUT_NO_PRECEDING_LINK_FOUND")
        }
    } elseif ($stateValue -eq 2) {
        $precededByLink = $dmsa."msDS-ManagedAccountPrecededByLink"
        if ($precededByLink) {
            try {
                $legacy = Get-ADObject -Identity $precededByLink -Properties Enabled -ErrorAction Stop
                $legacyAccountSummary = "Legacy: $($legacy.Name), Enabled=$($legacy.Enabled)"
                if ($legacy.Enabled) {
                    $findings.Add("LEGACY_ACCOUNT_STILL_ENABLED_AFTER_COMPLETE")
                }
            } catch {
                $legacyAccountSummary = "UNRESOLVABLE_LEGACY_LINK: $precededByLink"
            }
        }
    }

    if ($platformFlag -ne "OK") {
        $findings.Add("BLOCKED_BY_PLATFORM:$platformFlag")
    }
    if ($kdsFlag -ne "OK") {
        $findings.Add("BLOCKED_BY_KDS_STATE:$kdsFlag")
    }

    if ($findings.Count -eq 0) { $findings.Add("OK") }

    $results.Add([PSCustomObject]@{
        dMSAName           = $name
        Enabled            = $dmsa.Enabled
        DNSHostName        = $dmsa.DNSHostName
        WhenCreated        = $dmsa.whenCreated
        KerberosEncryption = $dmsa.KerberosEncryptionType
        MigrationState     = $stateText
        LegacyAccountInfo  = $legacyAccountSummary
        DelegationSummary  = ($delegationDetail -join "; ")
        ResolvedHostCount  = $resolvedHostCount
        PlatformState      = $platformFlag
        KdsRootKeyState    = $kdsFlag
        Findings           = ($findings -join ", ")
    })
}

# ---------------------------------------------------------------------------
# Part 4 — Optional local host checks (-TestLocal)
# ---------------------------------------------------------------------------
$localFindings = [System.Collections.Generic.List[object]]::new()

if ($TestLocal) {
    Write-Status "Running local checks on $($env:COMPUTERNAME)..." "INFO"

    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters"
    $delegatedMSAEnabled = $null
    try {
        $delegatedMSAEnabled = (Get-ItemProperty -Path $regPath -Name DelegatedMSAEnabled -ErrorAction Stop).DelegatedMSAEnabled
    } catch {
        $delegatedMSAEnabled = $null
    }

    if ($delegatedMSAEnabled -eq 1) {
        Write-Status "DelegatedMSAEnabled = 1 on this host." "OK"
        $localGateStatus = "ENABLED"
    } else {
        Write-Status "DelegatedMSAEnabled is NOT set to 1 on this host (missing or 0). dMSA logons will fail here regardless of AD-side authorization." "WARN"
        $localGateStatus = "DISABLED_OR_MISSING"
    }

    $osBuild = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    Write-Status "Local OS: $osBuild (confirm this is Windows Server 2025 or Windows 11 24H2+ for dMSA client support)" "INFO"

    try {
        $since = (Get-Date).AddHours(-$EventLogLookbackHours)
        $events = Get-WinEvent -LogName "Microsoft-Windows-Security-Kerberos/Operational" -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -ge $since -and $_.Id -in 307, 308, 309 }
        $eventSummary = "$($events.Count) dMSA-relevant event(s) (IDs 307/308/309) in last $EventLogLookbackHours h"
        if ($events.Count -gt 0) {
            Write-Status $eventSummary "OK"
        } else {
            Write-Status "$eventSummary — log may not be enabled; run: wevtutil sl Microsoft-Windows-Security-Kerberos/Operational /e:true" "WARN"
        }
    } catch {
        $eventSummary = "Could not read Kerberos Operational log: $($_.Exception.Message)"
    }

    $localFindings.Add([PSCustomObject]@{
        ComputerName         = $env:COMPUTERNAME
        OperatingSystem      = $osBuild
        DelegatedMSAEnabled  = $localGateStatus
        KerberosEventSummary = $eventSummary
    })
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "----- Summary -----" "INFO"
$results | Format-Table dMSAName, Enabled, MigrationState, ResolvedHostCount, Findings -AutoSize

if ($TestLocal -and $localFindings.Count -gt 0) {
    Write-Status "----- Local Host Summary -----" "INFO"
    $localFindings | Format-Table -AutoSize
}

$flaggedCount = @($results | Where-Object { $_.Findings -ne "OK" }).Count
if ($flaggedCount -gt 0) {
    Write-Status "$flaggedCount of $($results.Count) dMSA(s) have one or more findings. Review the Findings column." "WARN"
} else {
    Write-Status "All $($results.Count) dMSA(s) audited cleanly." "OK"
}

$csvPath = Join-Path -Path $OutputPath -ChildPath "DMSAHealth_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to: $csvPath" "OK"

if ($TestLocal -and $localFindings.Count -gt 0) {
    $localCsvPath = Join-Path -Path $OutputPath -ChildPath "DMSAHealth_LocalHost_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $localFindings | Export-Csv -Path $localCsvPath -NoTypeInformation -Encoding UTF8
    Write-Status "Local host results exported to: $localCsvPath" "OK"
}
