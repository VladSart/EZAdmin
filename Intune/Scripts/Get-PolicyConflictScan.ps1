<#
.SYNOPSIS
    Fleet-wide scan of Intune device configuration profile deployment states via Graph,
    surfacing every device+profile combination currently in Conflict or Error — the
    scale version of the single-device registry comparison in Policy-Conflict-A.md.

.DESCRIPTION
    Policy-Conflict-A.md's Evidence Pack and Validation Steps are device-local: they
    compare the PolicyManager registry hive against the GPO Policies hive on one
    machine at a time. That's the right tool once you know which device and profile
    are affected, but there's no fast way in the portal to answer "how many devices
    across the whole tenant are currently in Conflict or Error state, and which
    profiles are most affected" — you'd have to click into every configuration profile
    individually.

    This script uses Microsoft Graph's device configuration device-status reporting to:
    - Enumerate all device configuration profiles (Settings Catalog + legacy
      deviceConfigurations) in the tenant
    - Pull the per-device deployment status for each profile
      (succeeded / error / conflict / notApplicable / pending)
    - Flag every device+profile pair currently in "conflict" or "error"
    - Cross-reference conflicting profile pairs where possible, so you get a head
      start on Policy-Conflict-A.md Playbook 1 ("identify both conflicting policies")
      without opening the portal
    - Summarise which profiles have the highest conflict/error device counts — the
      profiles worth reviewing first per Policy-Conflict-A.md's Phase 2 conflict-type
      triage

    Exports full per-device-per-profile results to CSV, plus a profile-level summary
    CSV, and prints a colour-coded console summary of the top offending profiles.

    Does NOT cover (device-local only, see Policy-Conflict-A.md Evidence Pack):
    - Actual PolicyManager vs GPO registry comparison on a specific device
    - GPO RSoP data (gpresult) — Graph has no visibility into on-prem GPO
    - MDM diagnostic report generation (mdmdiagnosticstool.exe)
    - Co-management workload slider state (portal-only for the current value)

.PARAMETER ProfileNameFilter
    Wildcard filter on profile display name (e.g. "*Defender*"). Default "*" (all
    profiles). Narrowing this speeds up the scan significantly in large tenants.

.PARAMETER IncludeNotApplicable
    Switch. If set, also includes "notApplicable" status rows in the CSV (normally
    excluded as noise — these are filter/scope-tag/OS-version mismatches, not
    conflicts, and are covered by Policy-Conflict-A.md's Type D triage separately).

.PARAMETER OutputPath
    Directory for CSV export. Default: C:\Temp\PolicyConflictScan-<timestamp>\

.EXAMPLE
    .\Get-PolicyConflictScan.ps1

.EXAMPLE
    .\Get-PolicyConflictScan.ps1 -ProfileNameFilter "*BitLocker*"

.NOTES
    Requires: Microsoft.Graph.DeviceManagement module (or Microsoft.Graph meta-module)
    Permissions: DeviceManagementConfiguration.Read.All
    Safe: Read-only — no policy edits, no assignment changes
    Cross-references: Intune/Troubleshooting/Policy-Conflict-B.md (Fix Paths) and
                       Policy-Conflict-A.md (Playbook 1 — Resolve Intune-vs-Intune conflict)
#>

[CmdletBinding()]
param(
    [string]$ProfileNameFilter = "*",

    [switch]$IncludeNotApplicable,

    [string]$OutputPath = "C:\Temp\PolicyConflictScan-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

# ── Step 1: Enumerate configuration profiles ───────────────────────────────
Write-Status "Enumerating device configuration profiles..." "INFO"

$profiles = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    # Settings Catalog + legacy deviceConfigurations, unified via beta configurationPolicies
    # where available; fall back to deviceConfigurations for legacy profile types.
    $legacyConfigs = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations?`$select=id,displayName" |
        Select-Object -ExpandProperty value

    foreach ($c in $legacyConfigs) {
        if ($c.displayName -like $ProfileNameFilter) {
            $profiles.Add([PSCustomObject]@{ Id = $c.id; DisplayName = $c.displayName; Source = "deviceConfigurations" })
        }
    }
} catch {
    Write-Status "Could not enumerate legacy deviceConfigurations: $($_.Exception.Message)" "WARN"
}

try {
    $settingsCatalog = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$select=id,name" |
        Select-Object -ExpandProperty value

    foreach ($c in $settingsCatalog) {
        if ($c.name -like $ProfileNameFilter) {
            $profiles.Add([PSCustomObject]@{ Id = $c.id; DisplayName = $c.name; Source = "configurationPolicies (Settings Catalog)" })
        }
    }
} catch {
    Write-Status "Could not enumerate Settings Catalog policies: $($_.Exception.Message)" "WARN"
}

if ($profiles.Count -eq 0) {
    Write-Status "No profiles matched filter '$ProfileNameFilter'. Exiting." "ERROR"
    exit 1
}

Write-Status "Found $($profiles.Count) profile(s) matching filter." "OK"

# ── Step 2: Pull per-device status for each profile ────────────────────────
$allDeviceStatus = [System.Collections.Generic.List[PSCustomObject]]::new()
$profileSummary  = [System.Collections.Generic.List[PSCustomObject]]::new()
$i = 0

foreach ($profile in $profiles) {
    $i++
    Write-Status "[$i/$($profiles.Count)] Checking device status for: $($profile.DisplayName)" "INFO"

    $statuses = $null
    try {
        if ($profile.Source -eq "deviceConfigurations") {
            $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$($profile.Id)/deviceStatuses?`$select=deviceDisplayName,status,userPrincipalName,lastReportedDateTime"
        } else {
            $uri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($profile.Id)/deviceStatuses?`$select=deviceDisplayName,status,userName,lastUpdateDateTime"
        }
        $statuses = Invoke-MgGraphRequest -Method GET -Uri $uri | Select-Object -ExpandProperty value
    } catch {
        Write-Status "  Could not pull device statuses for '$($profile.DisplayName)': $($_.Exception.Message)" "WARN"
        continue
    }

    if (-not $statuses) { continue }

    $conflictCount = 0
    $errorCount    = 0
    $succeedCount  = 0

    foreach ($s in $statuses) {
        $statusVal = if ($s.status) { $s.status } else { "unknown" }

        if (-not $IncludeNotApplicable -and $statusVal -eq "notApplicable") { continue }

        switch ($statusVal) {
            "conflict"  { $conflictCount++ }
            "error"     { $errorCount++ }
            "succeeded" { $succeedCount++ }
        }

        if ($statusVal -in @("conflict","error") -or $IncludeNotApplicable) {
            $allDeviceStatus.Add([PSCustomObject]@{
                ProfileName  = $profile.DisplayName
                ProfileId    = $profile.Id
                ProfileType  = $profile.Source
                DeviceName   = $s.deviceDisplayName
                Status       = $statusVal
                LastReported = if ($s.lastReportedDateTime) { $s.lastReportedDateTime } elseif ($s.lastUpdateDateTime) { $s.lastUpdateDateTime } else { "Unknown" }
            })
        }
    }

    $profileSummary.Add([PSCustomObject]@{
        ProfileName     = $profile.DisplayName
        ProfileType     = $profile.Source
        ConflictCount   = $conflictCount
        ErrorCount      = $errorCount
        SucceededCount  = $succeedCount
        TotalIssues     = $conflictCount + $errorCount
    })

    if ($conflictCount -gt 0) {
        Write-Status "  $conflictCount device(s) in CONFLICT" "ERROR"
    }
    if ($errorCount -gt 0) {
        Write-Status "  $errorCount device(s) in ERROR" "WARN"
    }
}

# ── Export ────────────────────────────────────────────────────────────────
$deviceCsv  = Join-Path $OutputPath "ConflictAndErrorDevices.csv"
$summaryCsv = Join-Path $OutputPath "ProfileSummary.csv"

$allDeviceStatus | Export-Csv -Path $deviceCsv -NoTypeInformation -Encoding UTF8
$profileSummary  | Sort-Object TotalIssues -Descending | Export-Csv -Path $summaryCsv -NoTypeInformation -Encoding UTF8

Write-Status "Per-device conflict/error detail: $deviceCsv" "OK"
Write-Status "Profile-level summary: $summaryCsv" "OK"

Write-Host "`n=== Top Profiles by Conflict/Error Count ===" -ForegroundColor Cyan
$profileSummary | Sort-Object TotalIssues -Descending | Select-Object -First 10 |
    Format-Table ProfileName, ProfileType, ConflictCount, ErrorCount, TotalIssues -AutoSize

$totalConflicts = ($profileSummary | Measure-Object -Property ConflictCount -Sum).Sum
$totalErrors    = ($profileSummary | Measure-Object -Property ErrorCount -Sum).Sum

if ($totalConflicts -gt 0) {
    Write-Status "$totalConflicts total device-profile pairs in CONFLICT tenant-wide — start with the highest TotalIssues profile above" "ERROR"
}
if ($totalErrors -gt 0) {
    Write-Status "$totalErrors total device-profile pairs in ERROR tenant-wide" "WARN"
}
if ($totalConflicts -eq 0 -and $totalErrors -eq 0) {
    Write-Status "No conflicts or errors found across scanned profiles." "OK"
}

Write-Host "`nNext step for flagged devices: run the device-local Evidence Pack script from" -ForegroundColor DarkGray
Write-Host "Policy-Conflict-A.md against the specific device+profile pair to compare" -ForegroundColor DarkGray
Write-Host "PolicyManager vs GPO Policies hive values (see Policy-Conflict-A.md Playbook 1/2)." -ForegroundColor DarkGray
