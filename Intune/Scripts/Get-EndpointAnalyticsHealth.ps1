<#
.SYNOPSIS
    Fleet-wide Intune Endpoint analytics health sweep via Microsoft Graph — flags
    devices below the reporting population threshold, devices with unavailable/stale
    scores, and Work From Anywhere cloud-provisioning gaps caused by inherited
    (rather than explicitly assigned) Autopilot deployment profiles.

.DESCRIPTION
    EndpointAnalytics-A.md's Symptom -> Cause Map and Dependency Stack identify several
    failure modes that are invisible from any single device's portal page but become
    obvious once compared across the fleet:

    - Reporting population below the documented 5-device minimum for a given scope,
      which silently forces every score in that scope to "Insufficient data" regardless
      of pipeline health (Layer 7 of the Dependency Stack)
    - Per-device scores that are unavailable (-1/-2 encoding, per the CSV/Graph
      documentation) versus genuinely low, a distinction that is easy to conflate when
      only looking at a raw exported number (EndpointAnalytics-A.md Symptom -> Cause Map)
    - Devices with a healthStatus of "Insufficient data" (1) or "Unknown" (0) at the
      per-device level, which are the individual-device analogue of the scope-wide
      population problem and worth surfacing separately since they usually indicate a
      device that only recently onboarded or has a local pipeline break (DiagTrack,
      restart timing, network path -- all covered in EndpointAnalytics-B.md Triage)
    - Work From Anywhere Cloud Provisioning gaps where a device shows as Autopilot
      registered but the deployment profile field indicates inheritance from the
      default (all-devices) profile rather than an explicit assignment -- the specific
      trap documented in EndpointAnalytics-A.md's How It Works section and Symptom ->
      Cause Map, which is not visible from the Autopilot "registered" status alone

    This script queries the Graph v1.0 userExperienceAnalyticsDeviceScores and
    userExperienceAnalyticsWorkFromAnywhereMetrics resources, cross-references them,
    and exports a combined per-device report to CSV with a colour-coded console summary.

    Does NOT cover (see EndpointAnalytics-A.md for why):
    - Local device-side checks (DiagTrack service state, restart timing, proxy/SSL
      inspection path) -- these have no Graph-side signal at all and are exclusively
      covered by EndpointAnalytics-B.md's Triage section and local diagnostic commands
    - Startup performance boot-process-level detail or Application reliability
      per-crash detail -- both require userExperienceAnalyticsDeviceStartupHistory /
      userExperienceAnalyticsAppHealth* endpoints with their own pagination and
      per-device drill-in model; out of scope for a fleet-level sweep script
    - Configuration Manager-managed devices reporting purely through tenant attach --
      the Graph resources used here reflect Intune's own aggregation and should include
      ConfigMgr-sourced devices once deduplicated, but this script does not separately
      validate the ConfigMgr-side collection/upload configuration covered in
      EndpointAnalytics-A.md Playbook 2

.PARAMETER MinDeviceThreshold
    The documented minimum device count for a meaningful score. Default: 5
    (matches Microsoft's own documented floor -- do not lower this without a reason).

.PARAMETER StaleScoreDays
    Not currently exposed via the scores endpoint's own timestamp (the API does not
    return a last-updated field per device); reserved for future use if Microsoft adds
    one. Present now only so the parameter surface doesn't need a breaking change later.

.PARAMETER OutputPath
    Path for CSV export. Default: C:\Temp\EndpointAnalyticsHealth-<timestamp>.csv

.EXAMPLE
    .\Get-EndpointAnalyticsHealth.ps1

.EXAMPLE
    .\Get-EndpointAnalyticsHealth.ps1 -MinDeviceThreshold 5 -OutputPath "C:\Reports\EA-Health.csv"

.NOTES
    Requires: Microsoft.Graph.Authentication module (uses Invoke-MgGraphRequest directly
              rather than typed cmdlets, since Endpoint analytics' typed PowerShell
              cmdlets are split across GA and Beta modules depending on resource --
              raw Graph calls against the confirmed v1.0 GA resource paths avoid that
              module-version ambiguity)
    Permissions: DeviceManagementManagedDevices.Read.All (delegated or app)
    Safe: Read-only -- no configuration, consent, or assignment changes made
    Cross-references: Intune/Troubleshooting/EndpointAnalytics-A.md and -B.md
#>

[CmdletBinding()]
param(
    [int]$MinDeviceThreshold = 5,

    [int]$StaleScoreDays = 30,

    [string]$OutputPath = "C:\Temp\EndpointAnalyticsHealth-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Status "Microsoft.Graph.Authentication module not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" "ERROR"
    exit 1
}

try {
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context) { throw "No active Graph session" }
    Write-Status "Using existing Graph session: $($context.Account)" "OK"
} catch {
    Write-Status "Connecting to Graph (DeviceManagementManagedDevices.Read.All)..." "INFO"
    Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All" -NoWelcome
}

$healthStatusMap = @{
    0 = "Unknown"
    1 = "Insufficient data"
    2 = "Needs attention"
    3 = "Meeting goals"
}

# ── Step 1: Pull device scores ──────────────────────────────────────────────
Write-Status "Pulling userExperienceAnalyticsDeviceScores..." "INFO"
$deviceScores = [System.Collections.Generic.List[object]]::new()

try {
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/userExperienceAnalyticsDeviceScores"
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri
        foreach ($item in $resp.value) { $deviceScores.Add($item) }
        $uri = $resp.'@odata.nextLink'
    } while ($uri)
    Write-Status "Retrieved $($deviceScores.Count) device score record(s)." "OK"
} catch {
    Write-Status "Failed to query userExperienceAnalyticsDeviceScores: $($_.Exception.Message)" "ERROR"
    exit 1
}

if ($deviceScores.Count -lt $MinDeviceThreshold) {
    Write-Status "Reporting population ($($deviceScores.Count)) is below MinDeviceThreshold ($MinDeviceThreshold) -- every score in this scope will read 'Insufficient data' regardless of individual device pipeline health (EndpointAnalytics-A.md Layer 7)." "WARN"
}

# ── Step 2: Pull Work From Anywhere metrics ─────────────────────────────────
Write-Status "Pulling userExperienceAnalyticsWorkFromAnywhereMetrics..." "INFO"
$wfaMetrics = [System.Collections.Generic.List[object]]::new()

try {
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/userExperienceAnalyticsWorkFromAnywhereMetrics"
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri
        foreach ($item in $resp.value) { $wfaMetrics.Add($item) }
        $uri = $resp.'@odata.nextLink'
    } while ($uri)
    Write-Status "Retrieved $($wfaMetrics.Count) Work From Anywhere metric record(s)." "OK"
} catch {
    Write-Status "Failed to query userExperienceAnalyticsWorkFromAnywhereMetrics: $($_.Exception.Message)" "WARN"
    Write-Status "Continuing with device scores only -- WFA cross-reference will be skipped." "WARN"
}

# ── Step 3: Build per-device report ─────────────────────────────────────────
Write-Status "Building per-device report..." "INFO"
$report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($d in $deviceScores) {
    $healthStatusRaw = $d.healthStatus
    $healthStatusLabel = if ($null -ne $healthStatusRaw -and $healthStatusMap.ContainsKey([int]$healthStatusRaw)) {
        $healthStatusMap[[int]$healthStatusRaw]
    } else { "Unknown (raw: $healthStatusRaw)" }

    # -1 / -2 in a score field means unavailable, not zero -- flag explicitly rather
    # than letting it silently sort/average alongside real low scores downstream.
    $flags = [System.Collections.Generic.List[string]]::new()
    foreach ($scoreField in @('endpointAnalyticsScore','startupPerformanceScore','appReliabilityScore','workFromAnywhereScore')) {
        $val = $d.$scoreField
        if ($null -ne $val -and ($val -eq -1 -or $val -eq -2)) {
            $flags.Add("$scoreField=UNAVAILABLE")
        }
    }
    if ($healthStatusRaw -in @(0,1)) {
        $flags.Add("HEALTHSTATUS_$($healthStatusLabel.ToUpper().Replace(' ','_'))")
    }

    $report.Add([PSCustomObject]@{
        DeviceName              = $d.deviceName
        Model                   = $d.model
        Manufacturer            = $d.manufacturer
        EndpointAnalyticsScore  = $d.endpointAnalyticsScore
        StartupPerformanceScore = $d.startupPerformanceScore
        AppReliabilityScore     = $d.appReliabilityScore
        WorkFromAnywhereScore   = $d.workFromAnywhereScore
        HealthStatus            = $healthStatusLabel
        Flags                   = if ($flags.Count -gt 0) { $flags -join "; " } else { "" }
    })
}

# ── Step 4: Cross-reference WFA Cloud Provisioning gap ──────────────────────
# The Graph WFA metrics resource reports aggregate/percentage metrics rather than a
# clean per-device "profile explicitly assigned vs inherited default" boolean, so this
# is surfaced as a scope-wide summary rather than a per-device flag -- consistent with
# EndpointAnalytics-A.md's note that this specific gap is best confirmed against the
# Autopilot deployment profile assignment view directly (see Autopilot/ scripts) rather
# than reconstructed purely from this endpoint.
if ($wfaMetrics.Count -gt 0) {
    Write-Host "`n=== Work From Anywhere Metrics (scope-wide) ===" -ForegroundColor Cyan
    $wfaMetrics | Select-Object * -ExcludeProperty '@odata.type' | Format-Table -AutoSize
    Write-Status "If Cloud Provisioning reads low despite fleet-wide Autopilot use, confirm devices have an explicitly assigned deployment profile (not just the default all-devices profile) -- see EndpointAnalytics-A.md Symptom -> Cause Map and Autopilot/ deployment profile scripts." "INFO"
}

# ── Export ────────────────────────────────────────────────────────────────
$outputDir = Split-Path $OutputPath
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$report | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Full report exported to: $OutputPath" "OK"

# ── Console summary ─────────────────────────────────────────────────────────
Write-Host "`n=== Reporting Population ===" -ForegroundColor Cyan
Write-Host "Total devices with scores: $($deviceScores.Count) (minimum for meaningful scoring: $MinDeviceThreshold)"

$needsAttention = $report | Where-Object { $_.HealthStatus -eq "Needs attention" }
$insufficientOrUnknown = $report | Where-Object { $_.HealthStatus -in @("Insufficient data","Unknown") }
$flagged = $report | Where-Object { $_.Flags -ne "" }

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Devices 'Needs attention'        : $($needsAttention.Count)"
Write-Host "Devices Insufficient data/Unknown : $($insufficientOrUnknown.Count)"
Write-Host "Devices with unavailable-score flags : $($flagged.Count)"

if ($needsAttention.Count -gt 0) {
    Write-Host "`n=== Devices Needing Attention ===" -ForegroundColor Yellow
    $needsAttention | Format-Table DeviceName, Model, EndpointAnalyticsScore, StartupPerformanceScore, AppReliabilityScore, WorkFromAnywhereScore -AutoSize
}

if ($flagged.Count -gt 0) {
    Write-Host "`n=== Devices With Unavailable-Score or Insufficient-Data Flags ===" -ForegroundColor Yellow
    $flagged | Format-Table DeviceName, HealthStatus, Flags -AutoSize
    Write-Status "Unavailable (-1/-2) scores and Insufficient-data/Unknown health statuses are NOT the same as a genuinely low score -- do not average or trend these devices alongside real scores (EndpointAnalytics-A.md Symptom -> Cause Map)." "WARN"
}

Write-Status "Sweep complete." "OK"
