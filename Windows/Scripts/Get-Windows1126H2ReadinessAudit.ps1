<#
.SYNOPSIS
    Audits a Windows 11 device's readiness/status for the Windows 11, version 26H2 enablement-package (eKB) rollout.

.DESCRIPTION
    Read-only diagnostic companion to Windows11-26H2-A.md / Windows11-26H2-B.md. Because 26H2 (like 25H2 before it)
    ships as a small enablement package on the shared 24H2/25H2/26H2 servicing branch rather than a full media-based
    feature update, most "why hasn't this device gotten 26H2" tickets trace back to one of three things this script
    checks directly:
      1. Whether the device is even eKB-eligible (already on 24H2 or 25H2 -- 23H2 and earlier are out of scope)
      2. Whether the prerequisite Latest Cumulative Update (LCU) is installed (the eKB is silently not offered
         without it -- no error is surfaced by the servicing stack)
      3. What Feature Update / WUfB target-version policy is actually in effect, if the device is managed

    It also reports the post-flip commercial-device default-behavior signals (Windows Settings Backup, in
    particular) so admins can distinguish "expected 26H2 default change" from "unexpected configuration drift"
    without re-deriving the distinction from the runbook every time.

    This script does NOT trigger an upgrade, change any policy, or install anything. It is a discovery/reporting
    tool only, intended to be run before opening a rollout ticket or as part of a pre-rollout fleet sweep
    (e.g., via Intune script/Proactive Remediation or a remote PowerShell session).

.PARAMETER ExportCsv
    Optional path to export the single-device result as a CSV row, for fleet-wide aggregation across multiple runs.

.EXAMPLE
    .\Get-Windows1126H2ReadinessAudit.ps1

    Runs the audit against the local device and prints a formatted report to the console.

.EXAMPLE
    .\Get-Windows1126H2ReadinessAudit.ps1 -ExportCsv "C:\Temp\26H2-Readiness.csv"

    Runs the audit and appends the result as a CSV row, suitable for looping across a fleet via remote invocation.

.NOTES
    Requires: Windows 11, PowerShell 5.1+. Does not require administrator rights for the checks performed here
    (all reads are from HKLM policy/version keys and standard cmdlets), though some environments restrict
    Get-HotFix/Get-WinEvent to elevated sessions -- run elevated if results look incomplete.
    Safe: read-only. Makes no configuration changes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ExportCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
Write-Status "Starting Windows 11 26H2 readiness audit on $env:COMPUTERNAME" "INFO"

$result = [ordered]@{
    ComputerName              = $env:COMPUTERNAME
    Timestamp                 = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    DisplayVersion            = $null
    CurrentBuild              = $null
    UBR                       = $null
    EkbEligible               = $false
    MostRecentLCU_HotFixID    = $null
    MostRecentLCU_InstallDate = $null
    LCU_LooksCurrent          = "Unknown"
    ManagementDetected        = "Unmanaged / Not Determined"
    TargetReleaseVersion      = $null
    ProductVersion            = $null
    DeferFeatureUpdatesDays   = $null
    SafeguardOrCompatEvents   = 0
    Is26H2Already             = $false
    SettingsBackupPolicyState = "Not Configured / Default"
    Notes                     = @()
}

# ---- Detect: current version/build ----
try {
    $curVerKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $result.DisplayVersion = Get-ItemPropertyValue $curVerKey -Name DisplayVersion -ErrorAction Stop
    $result.CurrentBuild   = Get-ItemPropertyValue $curVerKey -Name CurrentBuild -ErrorAction Stop
    $result.UBR            = Get-ItemPropertyValue $curVerKey -Name UBR -ErrorAction SilentlyContinue
    Write-Status "DisplayVersion: $($result.DisplayVersion)  Build: $($result.CurrentBuild).$($result.UBR)" "INFO"
}
catch {
    Write-Status "Could not read DisplayVersion/CurrentBuild from registry: $_" "ERROR"
    $result.Notes += "Failed to read CurrentVersion registry key."
}

if ($result.DisplayVersion -eq '26H2') {
    $result.Is26H2Already = $true
    Write-Status "Device is already on 26H2." "OK"
}
elseif ($result.DisplayVersion -in @('24H2', '25H2')) {
    $result.EkbEligible = $true
    Write-Status "Device is on $($result.DisplayVersion) -- eKB-eligible for the 26H2 fast path." "OK"
}
elseif ($result.DisplayVersion) {
    Write-Status "Device is on $($result.DisplayVersion) -- NOT eligible for the eKB path (needs a full feature update to reach the 24H2/25H2/26H2 shared branch first)." "WARN"
    $result.Notes += "Device below shared servicing branch -- route to full feature-update runbook, not this eKB-specific one."
}

# ---- Detect: prerequisite LCU currency ----
try {
    $recentHotfix = Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($recentHotfix) {
        $result.MostRecentLCU_HotFixID    = $recentHotfix.HotFixID
        $result.MostRecentLCU_InstallDate = $recentHotfix.InstalledOn
        $daysSince = (New-TimeSpan -Start $recentHotfix.InstalledOn -End (Get-Date)).Days
        if ($daysSince -le 45) {
            $result.LCU_LooksCurrent = "Likely current ($daysSince days since most recent hotfix)"
            Write-Status "Most recent hotfix $($recentHotfix.HotFixID) installed $daysSince day(s) ago -- looks current." "OK"
        }
        else {
            $result.LCU_LooksCurrent = "Possibly stale ($daysSince days since most recent hotfix)"
            Write-Status "Most recent hotfix $($recentHotfix.HotFixID) is $daysSince day(s) old -- verify against current Patch Tuesday; the 26H2 eKB will not be offered without a current LCU." "WARN"
        }
    }
    else {
        $result.LCU_LooksCurrent = "No hotfix history found"
        Write-Status "No hotfix history returned by Get-HotFix -- cannot assess LCU currency this way." "WARN"
    }
}
catch {
    Write-Status "Get-HotFix failed (may require elevation): $_" "WARN"
    $result.Notes += "Get-HotFix failed -- re-run elevated for a reliable LCU-currency read."
}

# ---- Detect: management/policy targeting ----
try {
    $policyKey = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update"
    $policy = Get-ItemProperty -Path $policyKey -ErrorAction SilentlyContinue
    if ($policy) {
        $result.TargetReleaseVersion    = $policy.TargetReleaseVersion
        $result.ProductVersion          = $policy.ProductVersion
        $result.DeferFeatureUpdatesDays = $policy.DeferFeatureUpdatesPeriodInDays
        if ($policy.TargetReleaseVersion -or $policy.ProductVersion) {
            $result.ManagementDetected = "Managed (Feature Update / WUfB target-version policy present)"
            Write-Status "Target-version policy detected: TargetReleaseVersion=$($policy.TargetReleaseVersion) ProductVersion=$($policy.ProductVersion)" "INFO"
        }
    }
    else {
        Write-Status "No Feature Update / WUfB target-version policy found -- device appears unmanaged for this setting." "INFO"
    }
}
catch {
    Write-Status "Could not read PolicyManager Update policy key: $_" "WARN"
}

# ---- Detect: safeguard/compat hold signals ----
try {
    $events = Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match "safeguard|compat|blocked" }
    $result.SafeguardOrCompatEvents = ($events | Measure-Object).Count
    if ($result.SafeguardOrCompatEvents -gt 0) {
        Write-Status "$($result.SafeguardOrCompatEvents) safeguard/compat-related event(s) found in recent Windows Update Client Operational log -- review before assuming a policy-only block." "WARN"
    }
    else {
        Write-Status "No safeguard/compat-related events found in the recent Windows Update Client Operational log window." "OK"
    }
}
catch {
    Write-Status "Could not query WindowsUpdateClient/Operational log (may require elevation or the log may not exist on this build): $_" "WARN"
}

# ---- Detect: post-flip Settings Backup default state (informational only, single most commonly-flagged 26H2 default change) ----
try {
    $backupPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingsSync"
    $backupPolicy = Get-ItemProperty -Path $backupPolicyKey -ErrorAction SilentlyContinue
    if ($backupPolicy) {
        $result.SettingsBackupPolicyState = "Explicit policy present -- see WindowsBackup-A.md/-B.md for full detail"
    }
    elseif ($result.Is26H2Already) {
        $result.SettingsBackupPolicyState = "No explicit policy found -- device is on 26H2, so the new commercial default-on behavior likely applies unless overridden elsewhere"
    }
}
catch {
    # Non-fatal -- this is a best-effort informational signal only
}

# ---- Report ----
Write-Status "----- Summary -----" "INFO"
$result | Format-List

if ($ExportCsv) {
    try {
        $row = [pscustomobject]$result
        $row | Export-Csv -Path $ExportCsv -NoTypeInformation -Append -Force
        Write-Status "Result appended to $ExportCsv" "OK"
    }
    catch {
        Write-Status "Failed to export CSV to $ExportCsv : $_" "ERROR"
    }
}

Write-Status "Audit complete." "INFO"
