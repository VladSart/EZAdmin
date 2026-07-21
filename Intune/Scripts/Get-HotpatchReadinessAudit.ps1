<#
.SYNOPSIS
    Windows 11 Hotpatch (Windows Autopatch) readiness audit — checks all six eligibility conditions
    on the local device and reports which, if any, are blocking hotpatch enrollment.

.DESCRIPTION
    Collects and reports on:
      - OS build (24H2+ requirement) and CPU architecture
      - Virtualization-based Security runtime status (Running vs. merely enabled — the #1 real-world blocker)
      - Baseline currency (most recent cumulative update install date vs. the current quarterly baseline month)
      - Arm64-specific CHPE (Compiled Hybrid PE) disable state
      - Local hotpatch enrollment flag (Configured update policies)
      - Recent hotpatch-related Application log events, flagging any critical errors that would have
        triggered the inbox monitor service's automatic fallback to the standard LCU

    Does NOT enable/disable hotpatch, modify CHPE state, install/uninstall updates, or touch Intune
    policy. Read-only, local-device audit. Exports a CSV suitable for a fleet-wide readiness rollup
    when run via Invoke-Command / remote collection across multiple devices.

.PARAMETER ExportPath
    Path for the CSV export. Default: $env:TEMP\HotpatchReadiness_<timestamp>.csv

.PARAMETER SkipEventLogCheck
    Skip the Application log scan for hotpatch-related events (faster, useful for a quick bulk sweep).
    Default: $false.

.EXAMPLE
    .\Get-HotpatchReadinessAudit.ps1
    # Full local readiness audit with CSV export

.EXAMPLE
    Invoke-Command -ComputerName (Get-Content .\devices.txt) -FilePath .\Get-HotpatchReadinessAudit.ps1
    # Fleet-wide sweep — run locally on each targeted device via remoting

.NOTES
    Requires: Local admin rights are NOT required for the read-only checks in this script (standard
              user can read Win32_DeviceGuard, registry values, and Application log in most configurations)
    Run as: Any account with local read access; admin rights recommended for consistent event log access
    Best run: Directly on the device being audited (or via remoting for a fleet sweep)
    Safe/Unsafe: READ-ONLY — makes no changes to CHPE state, hotpatch enrollment, or update policy
    Tested against: Windows 11, version 24H2+ (Enterprise)
#>

[CmdletBinding()]
param(
    [string] $ExportPath = "$env:TEMP\HotpatchReadiness_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    [switch] $SkipEventLogCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"     { "Green"  }
        "WARN"   { "Yellow" }
        "ERROR"  { "Red"    }
        "HEADER" { "Cyan"   }
        default  { "White"  }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region --- Preflight ---

Write-Status "Windows 11 Hotpatch Readiness Audit" -Status "HEADER"
Write-Status "Device: $env:COMPUTERNAME  |  Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"

$findings = [System.Collections.Generic.List[string]]::new()

#endregion

#region --- Baseline calendar (informational, current cycle context) ---

$currentMonth = (Get-Date).Month
$baselineMonths = @(1, 4, 7, 10)
$isBaselineMonth = $baselineMonths -contains $currentMonth
Write-Status "Current month is a $(if ($isBaselineMonth) { 'BASELINE (restart-required)' } else { 'HOTPATCH (no restart expected)' }) month." -Status "INFO"

#endregion

#region --- Condition 1: OS build + license/architecture context ---

Write-Status "Checking OS build and architecture..." -Status "INFO"
try {
    $osInfo = Get-ComputerInfo -Property WindowsProductName, OsBuildNumber, CsSystemType -ErrorAction Stop
    $buildNumber = [int]($osInfo.OsBuildNumber)
    $isArm64 = $osInfo.CsSystemType -match "ARM64"

    $osEligible = $buildNumber -ge 26100
    if (-not $osEligible) {
        $findings.Add("OS build $buildNumber is below the 24H2 floor (26100) — device is permanently ineligible for hotpatch until upgraded.")
    }
} catch {
    $findings.Add("Could not determine OS build/architecture: $_")
    $osEligible = $null
    $isArm64 = $false
}

#endregion

#region --- Condition 2: VBS runtime status (the #1 real-world blocker) ---

Write-Status "Checking Virtualization-based Security runtime status..." -Status "INFO"
$vbsRunning = $null
try {
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
    # VirtualizationBasedSecurityStatus: 0 = Not enabled, 1 = Enabled but not running, 2 = Running
    $vbsRunning = ($dg.VirtualizationBasedSecurityStatus -eq 2)
    if (-not $vbsRunning) {
        $stateDesc = switch ($dg.VirtualizationBasedSecurityStatus) {
            0       { "Not enabled" }
            1       { "Enabled but NOT running (the most common real-world hotpatch blocker)" }
            default { "Unknown state ($($dg.VirtualizationBasedSecurityStatus))" }
        }
        $findings.Add("VBS status: $stateDesc. Hotpatch requires VBS to be actually Running, not just policy-enabled.")
    }
} catch {
    $findings.Add("Could not query VBS status via Win32_DeviceGuard: $_")
}

#endregion

#region --- Condition 3: Baseline currency ---

Write-Status "Checking baseline currency..." -Status "INFO"
$mostRecentHotfixDate = $null
try {
    $recentHotfix = Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object -First 1
    $mostRecentHotfixDate = $recentHotfix.InstalledOn

    if ($mostRecentHotfixDate) {
        $daysSinceLastUpdate = (New-TimeSpan -Start $mostRecentHotfixDate -End (Get-Date)).Days
        if ($daysSinceLastUpdate -gt 95) {
            $findings.Add("Most recent installed update was $daysSinceLastUpdate days ago ($mostRecentHotfixDate) — device may have fallen behind the current quarterly baseline. Verify against the baseline calendar (Jan/Apr/Jul/Oct).")
        }
    } else {
        $findings.Add("No hotfix install history returned — could not assess baseline currency.")
    }
} catch {
    $findings.Add("Could not query hotfix history: $_")
}

#endregion

#region --- Condition 4 (Arm64 only): CHPE disable state ---

$chpeDisabled = $null
if ($isArm64) {
    Write-Status "Arm64 device detected — checking CHPE disable state..." -Status "INFO"
    try {
        $chpeValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "HotPatchRestrictions" -ErrorAction SilentlyContinue
        $chpeDisabled = ($chpeValue -and $chpeValue.HotPatchRestrictions -eq 1)
        if (-not $chpeDisabled) {
            $findings.Add("Arm64 device with CHPE still active (HotPatchRestrictions not set to 1) — hotpatch cannot service SyChpe32 content until CHPE is explicitly disabled. Confirm no 32-bit x86 legacy app dependency before changing this.")
        }
    } catch {
        $findings.Add("Could not query CHPE disable state: $_")
    }
}

#endregion

#region --- Condition 5: Local enrollment flag (best-effort, event-log-derived) ---

$enrollmentFlagFound = $null
if (-not $SkipEventLogCheck) {
    Write-Status "Checking for local hotpatch enrollment signal in event logs..." -Status "INFO"
    try {
        $enrollmentEvents = Get-WinEvent -LogName "Microsoft-Windows-WaaSMedic/Operational" -MaxEvents 100 -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match "AllowRebootlessUpdates" }
        $enrollmentFlagFound = [bool]$enrollmentEvents

        if (-not $enrollmentFlagFound) {
            $findings.Add("No AllowRebootlessUpdates enrollment signal found in recent WaaSMedic event history. Confirm via Settings > Windows Update > Advanced options > Configured update policies > 'Enable hotpatching when available', and confirm the Intune quality update policy assignment.")
        }
    } catch {
        $findings.Add("Could not scan WaaSMedic event log for enrollment signal: $_")
    }
}

#endregion

#region --- Condition 6: Recent hotpatch-related Application log errors ---

$criticalHotpatchErrors = 0
if (-not $SkipEventLogCheck) {
    Write-Status "Checking Application log for hotpatch-related errors..." -Status "INFO"
    try {
        $appEvents = Get-WinEvent -LogName "Application" -MaxEvents 500 -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match "hotpatch" }
        $criticalHotpatchErrors = @($appEvents | Where-Object Level -eq 2).Count

        if ($criticalHotpatchErrors -gt 0) {
            $findings.Add("$criticalHotpatchErrors critical hotpatch-related Application log event(s) found — the inbox monitor service may have already triggered an automatic fallback to the standard LCU for this device.")
        }
    } catch {
        $findings.Add("Could not scan Application log for hotpatch events: $_")
    }
}

#endregion

#region --- Report ---

Write-Status "" -Status "INFO"
Write-Status "=== Summary ===" -Status "HEADER"

$overallReady = $osEligible -and ($vbsRunning -eq $true) -and (-not $isArm64 -or $chpeDisabled -eq $true)

if ($overallReady) {
    Write-Status "Device appears eligible for hotpatch based on locally-checkable conditions (OS build, VBS runtime, CHPE if applicable)." -Status "OK"
    Write-Status "Note: Intune policy assignment and tenant-level default cannot be verified from the device itself — confirm those separately in the Intune admin center." -Status "INFO"
} else {
    Write-Status "Device has one or more findings blocking hotpatch eligibility:" -Status "WARN"
    foreach ($f in $findings) { Write-Status "  $f" -Status "WARN" }
}

$exportRow = [pscustomobject]@{
    ComputerName            = $env:COMPUTERNAME
    RunTime                 = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    IsBaselineMonth         = $isBaselineMonth
    OSBuildEligible         = $osEligible
    IsArm64                 = $isArm64
    VBSRunning              = $vbsRunning
    MostRecentHotfixDate    = $mostRecentHotfixDate
    CHPEDisabled            = $chpeDisabled
    EnrollmentSignalFound   = $enrollmentFlagFound
    CriticalHotpatchErrors  = $criticalHotpatchErrors
    OverallLocallyEligible  = $overallReady
    FindingsCount           = $findings.Count
    Findings                = ($findings -join " | ")
}

$exportRow | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported: $ExportPath" -Status "OK"

#endregion
