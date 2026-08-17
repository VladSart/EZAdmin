<#
.SYNOPSIS
    Audits an Active Directory domain's exposure to the noPac attack chain
    (CVE-2021-42278 sAMAccountName spoofing + CVE-2021-42287 KDC name confusion)
    and reports current PAC-requestor-validation hardening posture.

.DESCRIPTION
    Read-only audit. Checks, per domain controller:
      - Presence of the November 2021+ cumulative update (KB5008380 baseline)
      - The legacy PACRequestorEnforcement registry value, where still present
        (retired/unread on any DC patched since October 2022 — reported for
        completeness only, not as a required setting on a current build)
    Domain-wide, checks:
      - ms-DS-MachineAccountQuota (the independent precondition-hardening item)
      - Recent Security log Event 4741 (computer account created) and Event 4781
        (account renamed) correlated by object name, to surface possible active
        exploitation or attempted exploitation
    Does NOT modify any setting, patch any DC, or reset any password. This is an
    audit/evidence-collection tool only — remediation is manual, per the runbook
    playbooks in Troubleshooting/PACValidation/.

.PARAMETER DomainControllers
    Optional list of DC hostnames to check for patch level and registry state.
    Defaults to every DC discovered via Get-ADDomainController -Filter *.

.PARAMETER EventLookbackDays
    How many days back to search the Security log for Event 4741/4781 correlation.
    Default: 30.

.PARAMETER OutputPath
    Folder to write the CSV/JSON evidence export to. Default: current directory.

.EXAMPLE
    .\Get-PACValidationAudit.ps1
    Runs a full domain-wide audit using default discovery and a 30-day event lookback.

.EXAMPLE
    .\Get-PACValidationAudit.ps1 -DomainControllers 'DC01','DC02' -EventLookbackDays 90 -OutputPath C:\Evidence

.NOTES
    Requires: RSAT ActiveDirectory module; remote WinRM/PowerShell reachability to each DC
    for Get-HotFix and registry checks (falls back to a warning per-DC if unreachable).
    Run-as: an account with read access to AD and to each DC's Security event log
    (Event Log Readers or local admin).
    Safe/unsafe: fully read-only. Safe to run at any time, including during business hours.
#>

#Requires -Modules ActiveDirectory

[CmdletBinding()]
param(
    [string[]]$DomainControllers,
    [int]$EventLookbackDays = 30,
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------- Preflight ----------
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Status "ActiveDirectory module not available. Install RSAT-AD-PowerShell and retry." "ERROR"
    throw
}

if (-not (Test-Path $OutputPath)) {
    Write-Status "OutputPath '$OutputPath' does not exist, creating it." "WARN"
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# ---------- Detect ----------
Write-Status "Discovering domain and domain controllers..."
$domain = Get-ADDomain
if (-not $DomainControllers) {
    $DomainControllers = (Get-ADDomainController -Filter *).HostName
}
Write-Status "Domain: $($domain.DNSRoot) | DCs to check: $($DomainControllers -join ', ')"

# MachineAccountQuota
Write-Status "Reading ms-DS-MachineAccountQuota..."
$quota = (Get-ADObject $domain.DistinguishedName -Properties ms-DS-MachineAccountQuota).'ms-DS-MachineAccountQuota'
if ($null -eq $quota) { $quota = 10 } # AD default when unset
if ($quota -gt 0) {
    Write-Status "ms-DS-MachineAccountQuota = $quota (any authenticated user can self-create up to this many computer objects)" "WARN"
} else {
    Write-Status "ms-DS-MachineAccountQuota = 0 (hardened)" "OK"
}

# ---------- Per-DC patch/registry check ----------
$dcResults = foreach ($dc in $DomainControllers) {
    Write-Status "Checking $dc..."
    $entry = [ordered]@{
        DomainController        = $dc
        Reachable                = $false
        KB5008380OrLaterPresent  = $null
        OSBuild                  = $null
        PACRequestorEnforcement  = $null
        EnforcementInterpretation = $null
    }
    try {
        $os = Get-CimInstance -ComputerName $dc -ClassName Win32_OperatingSystem -ErrorAction Stop
        $entry.Reachable = $true
        $entry.OSBuild = $os.BuildNumber

        $hotfix = Get-HotFix -Id KB5008380 -ComputerName $dc -ErrorAction SilentlyContinue
        # Also accept a later cumulative update as evidence of currency — approximate check via install date
        $entry.KB5008380OrLaterPresent = [bool]$hotfix -or ($os.InstallDate -gt (Get-Date "2021-11-09"))

        try {
            $regVal = Invoke-Command -ComputerName $dc -ScriptBlock {
                (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" -Name PACRequestorEnforcement -ErrorAction SilentlyContinue).PACRequestorEnforcement
            } -ErrorAction SilentlyContinue
            $entry.PACRequestorEnforcement = $regVal
            $entry.EnforcementInterpretation = switch ($regVal) {
                0       { "DISABLED — reopens the vulnerability even on a patched build. Remediate immediately." }
                1       { "Deployment/compatibility mode — only meaningful on a DC in the Nov2021-Oct2022 transition window." }
                2       { "Enforcement (explicit) — expected/safe." }
                $null   { "Key absent — expected on any DC patched since Oct 2022 (Enforcement is unconditional, key is retired)." }
                default { "Unrecognized value ($regVal) — investigate." }
            }
        } catch {
            $entry.EnforcementInterpretation = "Could not read registry remotely (WinRM/permissions) — verify manually if this DC predates Oct 2022."
        }
    } catch {
        Write-Status "Could not reach $dc for patch/registry check: $($_.Exception.Message)" "WARN"
    }
    [PSCustomObject]$entry
}

# ---------- Event log correlation (domain-wide, run against reachable DCs) ----------
Write-Status "Scanning Security log for Event 4741/4781 correlation (last $EventLookbackDays days)..."
$startTime = (Get-Date).AddDays(-$EventLookbackDays)
$creationEvents = @()
$renameEvents = @()

foreach ($dc in $DomainControllers) {
    try {
        $creationEvents += Get-WinEvent -ComputerName $dc -FilterHashtable @{ LogName = 'Security'; Id = 4741; StartTime = $startTime } -ErrorAction SilentlyContinue |
            Select-Object @{n='DC';e={$dc}}, TimeCreated, @{n='Actor';e={$_.Properties[4].Value}}, @{n='NewComputer';e={$_.Properties[0].Value}}
        $renameEvents += Get-WinEvent -ComputerName $dc -FilterHashtable @{ LogName = 'Security'; Id = 4781; StartTime = $startTime } -ErrorAction SilentlyContinue |
            Select-Object @{n='DC';e={$dc}}, TimeCreated, @{n='OldName';e={$_.Properties[1].Value}}, @{n='NewName';e={$_.Properties[2].Value}}
    } catch {
        Write-Status "Could not query Security log on $dc (permissions or unreachable) — skipping for event correlation." "WARN"
    }
}

$suspiciousCorrelations = foreach ($rename in $renameEvents) {
    $match = $creationEvents | Where-Object { $_.NewComputer -eq $rename.OldName -and $_.TimeCreated -le $rename.TimeCreated }
    if ($match) {
        foreach ($m in $match) {
            [PSCustomObject]@{
                CreatedBy    = $m.Actor
                ComputerName = $m.NewComputer
                CreatedAt    = $m.TimeCreated
                RenamedTo    = $rename.NewName
                RenamedAt    = $rename.TimeCreated
                MinutesBetween = [math]::Round((New-TimeSpan -Start $m.TimeCreated -End $rename.TimeCreated).TotalMinutes, 1)
            }
        }
    }
}

if ($suspiciousCorrelations) {
    Write-Status "Found $(($suspiciousCorrelations | Measure-Object).Count) create+rename correlation(s) on computer objects — review for noPac indicators." "WARN"
} else {
    Write-Status "No create+rename correlations found on computer objects in the lookback window." "OK"
}

# ---------- Report ----------
$summary = [PSCustomObject]@{
    GeneratedAt              = Get-Date
    Domain                   = $domain.DNSRoot
    MachineAccountQuota      = $quota
    MachineAccountQuotaHardened = ($quota -eq 0)
    DCsChecked               = $DomainControllers.Count
    DCsUnpatchedOrUnknown    = ($dcResults | Where-Object { $_.KB5008380OrLaterPresent -ne $true }).Count
    SuspiciousCorrelationCount = ($suspiciousCorrelations | Measure-Object).Count
}

$summaryPath = Join-Path $OutputPath "PACValidationAudit-Summary.csv"
$dcPath = Join-Path $OutputPath "PACValidationAudit-DomainControllers.csv"
$correlationPath = Join-Path $OutputPath "PACValidationAudit-SuspiciousCorrelations.csv"

$summary | Export-Csv -Path $summaryPath -NoTypeInformation
$dcResults | Export-Csv -Path $dcPath -NoTypeInformation
if ($suspiciousCorrelations) {
    $suspiciousCorrelations | Export-Csv -Path $correlationPath -NoTypeInformation
}

Write-Status "Summary written to $summaryPath" "OK"
Write-Status "Per-DC detail written to $dcPath" "OK"
if ($suspiciousCorrelations) {
    Write-Status "Suspicious correlations written to $correlationPath — REVIEW BEFORE CLOSING THIS AUDIT" "WARN"
}

$summary | Format-List
$dcResults | Format-Table -AutoSize
