<#
.SYNOPSIS
    Fleet-wide Intune Remediations (Proactive Remediations) run-state report via Graph —
    the scale complement to Remediations-A.md/B.md's device-local AgentExecutor.log
    reading and per-device portal clicking.

.DESCRIPTION
    Remediations-A.md and Remediations-B.md's Diagnosis steps are device-local: tail
    AgentExecutor.log, check IME service state, manually run detection as SYSTEM on one
    machine. That's the right tool once you know which device and package are affected,
    but there's no fast way to answer "which of our Remediation packages are failing
    fleet-wide, and on how many devices" without opening every package's Device status
    blade one at a time.

    This script uses Microsoft Graph's deviceHealthScripts (Remediations) API to:
    - Enumerate all deployed Remediation script packages in the tenant
    - Pull the per-device run state for each package (deviceHealthScriptDeviceState:
      detectionState, lastStateUpdateDateTime, remediation output/error fields)
    - Classify each device+package pair per the states documented in Remediations-A.md's
      "Reporting States in Intune" table: Without issues / With issues / Remediated /
      Failed / Pending / No status
    - Rank packages by failure count and by "No status" count, so you know which package
      to open first — mirroring Policy-Conflict's fleet-scan pattern applied to
      Remediations
    - Flag packages where "No status" is unusually high relative to assigned device count
      as a likely group-assignment or licensing gap per Remediations-A.md's "Licensing is
      the silent gotcha" Learning Pointer, rather than a script bug

    Exports full per-device-per-package results to CSV, plus a package-level summary CSV,
    and prints a colour-coded console summary of the worst-performing packages.

    Does NOT cover (device-local only, see Remediations-A.md / Remediations-B.md):
    - AgentExecutor.log / IntuneManagementExtension.log tailing on a specific device
    - Manually re-running detection/remediation scripts as SYSTEM to test logic
    - IME service health and network reachability from the device
    - Confirming a specific user's Intune Plan 1 license assignment (Graph call for that
      is per-user, not exposed on the deviceHealthScriptDeviceState object — cross-check
      manually via Get-MgUserLicenseDetail for devices flagged as "No status")

.PARAMETER PackageNameFilter
    Wildcard filter on Remediation package display name (e.g. "*BitLocker*"). Default "*"
    (all packages). Narrowing this speeds up the scan significantly in large tenants.

.PARAMETER FailureRateThresholdPct
    Minimum failure rate (failed / total reporting devices, as a percentage) for a
    package to be flagged in the console warning summary. Default: 10.

.PARAMETER OutputPath
    Directory for CSV export. Default: C:\Temp\RemediationRunHistory-<timestamp>\

.EXAMPLE
    .\Get-RemediationRunHistory.ps1

.EXAMPLE
    .\Get-RemediationRunHistory.ps1 -PackageNameFilter "*Defender*" -FailureRateThresholdPct 5

.NOTES
    Requires: Microsoft.Graph.DeviceManagement module (or Microsoft.Graph meta-module)
    Permissions: DeviceManagementConfiguration.Read.All
    Safe: Read-only — no script re-runs, no assignment changes
    Cross-references: Intune/Troubleshooting/Remediations-B.md (Fix Paths, Escalation
                       Evidence) and Remediations-A.md (Reporting States, Symptom -> Cause
                       Map, Phase 2 targeting checks)
#>

[CmdletBinding()]
param(
    [string]$PackageNameFilter = "*",

    [double]$FailureRateThresholdPct = 10,

    [string]$OutputPath = "C:\Temp\RemediationRunHistory-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

# ── Preflight ────────────────────────────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.DeviceManagement)) {
    Write-Status "Microsoft.Graph.DeviceManagement module not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Graph.DeviceManagement -Scope CurrentUser" "ERROR"
    exit 1
}

try {
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context) { throw "No active Graph session" }
    Write-Status "Using existing Graph session: $($context.Account)" "OK"
} catch {
    Write-Status "Connecting to Graph (DeviceManagementConfiguration.Read.All)..." "INFO"
    Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All" -NoWelcome
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# ── Step 1: Enumerate Remediation packages (deviceHealthScripts) ───────────
Write-Status "Enumerating Remediation packages (deviceHealthScripts)..." "INFO"

$packages = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    $scripts = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts?`$select=id,displayName,publisher,runAsAccount,isGlobalScript" |
        Select-Object -ExpandProperty value

    foreach ($s in $scripts) {
        if ($s.displayName -like $PackageNameFilter -and -not $s.isGlobalScript) {
            $packages.Add([PSCustomObject]@{
                Id          = $s.id
                DisplayName = $s.displayName
                Publisher   = $s.publisher
                RunAsAccount = $s.runAsAccount
            })
        }
    }
} catch {
    Write-Status "Could not enumerate deviceHealthScripts: $($_.Exception.Message)" "ERROR"
    exit 1
}

if ($packages.Count -eq 0) {
    Write-Status "No Remediation packages matched filter '$PackageNameFilter'. Exiting." "ERROR"
    exit 1
}

Write-Status "Found $($packages.Count) Remediation package(s) matching filter." "OK"

# ── Step 2: Pull per-device run state for each package ─────────────────────
$allDeviceStates = [System.Collections.Generic.List[PSCustomObject]]::new()
$packageSummary  = [System.Collections.Generic.List[PSCustomObject]]::new()
$i = 0

foreach ($pkg in $packages) {
    $i++
    Write-Status "[$i/$($packages.Count)] Pulling device run states for: $($pkg.DisplayName)" "INFO"

    $states = $null
    try {
        $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts/$($pkg.Id)/deviceRunStates" +
               "?`$select=id,detectionState,lastStateUpdateDateTime,lastSyncDateTime,preRemediationDetectionScriptOutput,postRemediationDetectionScriptOutput,preRemediationDetectionScriptError,postRemediationDetectionScriptError,remediationScriptError,remediationScriptOutput"
        $states = Invoke-MgGraphRequest -Method GET -Uri $uri | Select-Object -ExpandProperty value
    } catch {
        Write-Status "  Could not pull run states for '$($pkg.DisplayName)': $($_.Exception.Message)" "WARN"
        continue
    }

    if (-not $states) {
        $packageSummary.Add([PSCustomObject]@{
            PackageName = $pkg.DisplayName; RunAsAccount = $pkg.RunAsAccount
            NoStatusCount = 0; PendingCount = 0; WithoutIssuesCount = 0
            WithIssuesCount = 0; RemediatedCount = 0; FailedCount = 0
            TotalReporting = 0; FailureRatePct = 0
        })
        continue
    }

    $counts = @{
        noStatus = 0; pending = 0; withoutIssues = 0; withIssues = 0
        remediated = 0; failed = 0; other = 0
    }

    foreach ($s in $states) {
        $detState = if ($s.detectionState) { $s.detectionState } else { "unknown" }

        # Map Graph detectionState values to the Remediations-A.md "Reporting States" table
        switch ($detState) {
            "unknown"          { $counts.noStatus++ }
            "success"          { $counts.withoutIssues++ }   # detection ran, no issue
            "issueDetected"    { $counts.withIssues++ }
            "responseNotApplicable" { $counts.noStatus++ }
            "scriptError"      { $counts.failed++ }
            "remediationScriptError" { $counts.failed++ }
            "pendingReboot"    { $counts.pending++ }
            "internalError"    { $counts.failed++ }
            default {
                if ($s.remediationScriptError -or $s.postRemediationDetectionScriptError) { $counts.failed++ }
                else { $counts.other++ }
            }
        }

        $hasFailureSignal = $detState -in @("scriptError","remediationScriptError","internalError") -or
                            $s.remediationScriptError -or $s.postRemediationDetectionScriptError

        if ($hasFailureSignal -or $detState -eq "unknown") {
            $allDeviceStates.Add([PSCustomObject]@{
                PackageName            = $pkg.DisplayName
                PackageId              = $pkg.Id
                RunStateId             = $s.id
                DetectionState         = $detState
                LastStateUpdate        = $s.lastStateUpdateDateTime
                LastSync               = $s.lastSyncDateTime
                PreDetectionError      = $s.preRemediationDetectionScriptError
                PostDetectionError     = $s.postRemediationDetectionScriptError
                RemediationError       = $s.remediationScriptError
                RemediationOutput      = $s.remediationScriptOutput
            })
        }
    }

    $totalReporting = $states.Count - $counts.noStatus
    $failureRate = if ($totalReporting -gt 0) { [math]::Round(($counts.failed / $totalReporting) * 100, 1) } else { 0 }

    $packageSummary.Add([PSCustomObject]@{
        PackageName        = $pkg.DisplayName
        RunAsAccount       = $pkg.RunAsAccount
        NoStatusCount      = $counts.noStatus
        PendingCount       = $counts.pending
        WithoutIssuesCount = $counts.withoutIssues
        WithIssuesCount    = $counts.withIssues
        RemediatedCount    = $counts.remediated
        FailedCount        = $counts.failed
        TotalReporting     = $totalReporting
        FailureRatePct     = $failureRate
    })

    if ($counts.failed -gt 0) {
        Write-Status "  $($counts.failed) device(s) FAILED (of $totalReporting reporting, $failureRate% failure rate)" "ERROR"
    }
    if ($counts.noStatus -gt ($states.Count * 0.3)) {
        Write-Status "  $($counts.noStatus) device(s) with No status — check assignment scope and licensing (Remediations-A.md 'silent gotcha')" "WARN"
    }
}

# ── Export ────────────────────────────────────────────────────────────────
$deviceCsv  = Join-Path $OutputPath "FailedAndNoStatusRunStates.csv"
$summaryCsv = Join-Path $OutputPath "PackageSummary.csv"

$allDeviceStates | Export-Csv -Path $deviceCsv -NoTypeInformation -Encoding UTF8
$packageSummary  | Sort-Object FailureRatePct -Descending | Export-Csv -Path $summaryCsv -NoTypeInformation -Encoding UTF8

Write-Status "Per-device failed/no-status detail: $deviceCsv" "OK"
Write-Status "Package-level summary: $summaryCsv" "OK"

Write-Host "`n=== Top Packages by Failure Rate ===" -ForegroundColor Cyan
$packageSummary | Sort-Object FailureRatePct -Descending | Select-Object -First 10 |
    Format-Table PackageName, TotalReporting, FailedCount, FailureRatePct, NoStatusCount -AutoSize

$flagged = $packageSummary | Where-Object { $_.FailureRatePct -ge $FailureRateThresholdPct }
if ($flagged) {
    Write-Status "$($flagged.Count) package(s) at or above $FailureRateThresholdPct% failure rate — start with these (Remediations-B.md Fix Paths)" "ERROR"
} else {
    Write-Status "No packages at or above $FailureRateThresholdPct% failure rate." "OK"
}

$highNoStatus = $packageSummary | Where-Object { $_.NoStatusCount -gt 0 } | Sort-Object NoStatusCount -Descending | Select-Object -First 5
if ($highNoStatus) {
    Write-Host "`n=== Packages With Notable 'No Status' Counts (assignment/licensing gap candidates) ===" -ForegroundColor Yellow
    $highNoStatus | Format-Table PackageName, NoStatusCount -AutoSize
}

Write-Host "`nNext step for a specific failing device: run Remediations-A.md Evidence Pack or" -ForegroundColor DarkGray
Write-Host "Playbook 3 (device-local script extraction + manual SYSTEM re-run) against that device." -ForegroundColor DarkGray
