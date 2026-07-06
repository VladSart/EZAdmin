<#
.SYNOPSIS
    Reports Intune Feature Update Policy assignment/deployment state, local target-version CSP values,
    safeguard hold signals, and GPO/disk-space blockers for Windows feature update ("24H2"-style) rollouts.

.DESCRIPTION
    Combines a local device-side check (TargetReleaseVersion CSP, GPO conflict at the
    WindowsUpdate\TargetReleaseVersion key, safeguard hold registry/log signals, disk space, telemetry
    level, WU service state) with a Graph-side check of Intune Windows Feature Update Profile assignment
    and per-device deployment state. Automates the Triage/Diagnosis steps and the Symptom -> Cause Map in
    Intune/Troubleshooting/FeatureUpdates-B.md and FeatureUpdates-A.md so an engineer can quickly tell
    whether a device is missing its feature update policy, blocked by a safeguard hold, overridden by a
    conflicting GPO, or simply short on disk space for the upgrade.

    Covers:
    - Local TargetReleaseVersion / TargetReleaseVersionInfo CSP values (device + PolicyManager stores)
    - Conflicting GPO detection at HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate
    - MDMWinsOverGP precedence flag
    - Safeguard hold signal scan (registry + WU client operational log, last 20 events)
    - Disk space check (feature updates need ~20GB free)
    - Telemetry/diagnostic data level (required >= 1 for safeguard hold signals to be received)
    - Graph-side: windowsFeatureUpdateProfiles + per-device deploymentStatuses, flagged and exported to CSV

    Does NOT modify feature update policy, does NOT opt devices out of safeguard holds, and does NOT
    force Windows Update installs. Read-only reporting only — remediation is manual, see
    FeatureUpdates-B.md Common Fix Paths / FeatureUpdates-A.md Remediation Playbooks.

.PARAMETER ProfileName
    Optional filter — only report Graph-side device status for feature update profiles whose display
    name matches this wildcard pattern (e.g. "*24H2*"). Default: all feature update profiles.

.PARAMETER SkipLocalCheck
    Switch. Skip the local device-side checks (registry, GPO, safeguard signals, disk space). Use when
    running remotely against Graph only (e.g. from an admin workstation, not the affected device).

.PARAMETER StalePendingDays
    Devices in "pending" state whose profile has been assigned longer than this many days are flagged
    STALE_PENDING (likely device not checking in or stuck, not a genuine in-progress rollout).
    Default: 14.

.PARAMETER OutputPath
    Path for CSV export of the Graph-side per-device feature update status. Defaults to
    .\FeatureUpdateDeploymentStatus_<timestamp>.csv in the current directory.

.EXAMPLE
    .\Get-FeatureUpdateDeploymentStatus.ps1

.EXAMPLE
    .\Get-FeatureUpdateDeploymentStatus.ps1 -ProfileName "*24H2*" -SkipLocalCheck -StalePendingDays 21

.NOTES
    Requires: Microsoft.Graph.Authentication module (uses Invoke-MgGraphRequest against the beta
    endpoint for deviceManagement/windowsFeatureUpdateProfiles and their deviceStatuses).
    Requires Graph scope: DeviceManagementConfiguration.Read.All
    Run-as (local check portion): local administrator on the target device.
    Safe: Yes — fully read-only against Microsoft Graph, local registry, and event log.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ProfileName = "*",

    [Parameter(Mandatory = $false)]
    [switch]$SkipLocalCheck,

    [Parameter(Mandatory = $false)]
    [int]$StalePendingDays = 14,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\FeatureUpdateDeploymentStatus_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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

# ---------------------------------------------------------------------------
# LOCAL DEVICE-SIDE CHECK (skip with -SkipLocalCheck)
# ---------------------------------------------------------------------------
if (-not $SkipLocalCheck) {
    Write-Status "===== LOCAL FEATURE UPDATE POLICY / BLOCKER CHECK =====" "OK"

    Write-Status "Current OS version:" "INFO"
    try {
        (Get-ComputerInfo -Property OsDisplayVersion, OsBuildNumber, WindowsVersion) | Format-List
    }
    catch {
        [System.Environment]::OSVersion.Version | Format-List
    }

    $pmUpdatePath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update"
    if (Test-Path $pmUpdatePath) {
        $target = Get-ItemProperty -Path $pmUpdatePath -ErrorAction SilentlyContinue
        Write-Status "TargetReleaseVersion CSP values (PolicyManager):" "INFO"
        $target | Select-Object TargetReleaseVersion, TargetReleaseVersionInfo, DeferFeatureUpdatesPeriodInDays |
            Format-List

        if (-not $target.PSObject.Properties.Name -contains "TargetReleaseVersionInfo" -or [string]::IsNullOrWhiteSpace($target.TargetReleaseVersionInfo)) {
            Write-Status "TargetReleaseVersionInfo not set — Feature Update Policy has not reached this device via MDM. See FeatureUpdates-B.md Fix 1." "ERROR"
        }
        else {
            Write-Status "Feature Update Policy is present locally, targeting: $($target.TargetReleaseVersionInfo)" "OK"
        }
    }
    else {
        Write-Status "No PolicyManager Update key found — device has not received any Feature Update Policy via MDM." "ERROR"
    }

    $gpoWuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    if (Test-Path $gpoWuPath) {
        $gpoWu = Get-ItemProperty -Path $gpoWuPath -ErrorAction SilentlyContinue
        if ($gpoWu.PSObject.Properties.Name -contains "TargetReleaseVersion") {
            Write-Status "GPO-delivered TargetReleaseVersion found at $gpoWuPath — potential conflict with the MDM Feature Update Policy. See FeatureUpdates-B.md Fix 2." "WARN"
            $gpoWu | Select-Object TargetReleaseVersion, TargetReleaseVersionInfo, MDMWinsOverGP | Format-List

            if (-not ($gpoWu.PSObject.Properties.Name -contains "MDMWinsOverGP" -and $gpoWu.MDMWinsOverGP -eq 1)) {
                Write-Status "MDMWinsOverGP is not set to 1 — GPO value may take precedence over the Intune Feature Update Policy on this build." "ERROR"
            }
        }
        else {
            Write-Status "No GPO TargetReleaseVersion value found at $gpoWuPath — no GPO conflict at this key." "OK"
        }
    }
    else {
        Write-Status "No GPO-delivered WindowsUpdate policy key found — no GPO conflict." "OK"
    }

    Write-Status "Checking for safeguard hold signals (registry)..."
    $safeguardRegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\TargetVersionUpgradeExperienceIndicators"
    if (Test-Path $safeguardRegPath) {
        Write-Status "Safeguard hold indicator key present — device may be held back from the target version. See FeatureUpdates-A.md Playbook 1." "WARN"
        Get-ItemProperty -Path $safeguardRegPath -ErrorAction SilentlyContinue | Select-Object * -ExcludeProperty PS* | Format-List
    }
    else {
        Write-Status "No safeguard hold indicator key found." "OK"
    }

    Write-Status "Scanning WU client operational log for safeguard/hold signals (last 20 events)..."
    try {
        $wuEvents = Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 20 -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match "safeguard|SAFEGUARD|hold|FAIL_SAFE_HOLD" }
        if ($wuEvents) {
            Write-Status "Found safeguard/hold-related events:" "WARN"
            $wuEvents | Select-Object TimeCreated, Id, Message | Format-Table -AutoSize -Wrap
        }
        else {
            Write-Status "No safeguard hold signals in the last 20 WU client events." "OK"
        }
    }
    catch {
        Write-Status "Could not read Microsoft-Windows-WindowsUpdateClient/Operational log: $($_.Exception.Message)" "WARN"
    }

    Write-Status "Checking free disk space (feature updates typically need ~20GB free)..."
    $sysDrive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($sysDrive) {
        $freeGB = [math]::Round($sysDrive.Free / 1GB, 1)
        if ($freeGB -lt 20) {
            Write-Status "Only $freeGB GB free on $($env:SystemDrive) — below the ~20GB feature update staging requirement. See FeatureUpdates-B.md Fix 5." "ERROR"
        }
        else {
            Write-Status "$freeGB GB free on $($env:SystemDrive) — sufficient for feature update staging." "OK"
        }
    }

    Write-Status "Checking telemetry/diagnostic data level (required for safeguard hold signals)..."
    $telemetry = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -ErrorAction SilentlyContinue).AllowTelemetry
    if ($null -eq $telemetry -or $telemetry -lt 1) {
        Write-Status "AllowTelemetry is 0 or not set — device cannot receive safeguard hold signals and may silently fail to be offered the update." "WARN"
    }
    else {
        Write-Status "AllowTelemetry = $telemetry — sufficient for safeguard hold signal delivery." "OK"
    }

    Write-Status "Checking Windows Update service state..."
    Get-Service wuauserv, UsoSvc -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType | Format-Table -AutoSize

    Write-Host ""
}
else {
    Write-Status "Skipping local device-side check (-SkipLocalCheck specified)." "INFO"
}

# ---------------------------------------------------------------------------
# PREFLIGHT — GRAPH
# ---------------------------------------------------------------------------
Write-Status "===== GRAPH-SIDE FEATURE UPDATE PROFILE CHECK =====" "OK"
Write-Status "Checking for required Microsoft Graph module..."
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Status "Module 'Microsoft.Graph.Authentication' not found. Install with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" "ERROR"
    throw "Missing required module: Microsoft.Graph.Authentication"
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Not connected to Microsoft Graph. Connecting..." "WARN"
        Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All" | Out-Null
    }
    else {
        Write-Status "Connected to Graph as $($context.Account) (tenant $($context.TenantId))" "OK"
    }
}
catch {
    Write-Status "Failed to establish Graph connection: $($_.Exception.Message)" "ERROR"
    throw
}

# ---------------------------------------------------------------------------
# DETECT — locate Feature Update Profiles
# ---------------------------------------------------------------------------
Write-Status "Retrieving Windows Feature Update Profiles..."
try {
    $profiles = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsFeatureUpdateProfiles").value
}
catch {
    Write-Status "Failed to query windowsFeatureUpdateProfiles: $($_.Exception.Message)" "ERROR"
    throw
}

$profiles = $profiles | Where-Object { $_.displayName -like $ProfileName }

if (-not $profiles -or $profiles.Count -eq 0) {
    Write-Status "No Feature Update Profiles found matching '$ProfileName'. Confirm profiles exist under Intune > Devices > Windows > Feature updates for Windows 10 and later." "WARN"
    return
}
Write-Status "Found $($profiles.Count) Feature Update Profile(s): $($profiles.displayName -join ', ')" "OK"

# ---------------------------------------------------------------------------
# EXECUTE — per-profile device deployment states
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()
$now = Get-Date

foreach ($fup in $profiles) {
    Write-Status "Profile '$($fup.displayName)': Target=$($fup.featureUpdateVersion), Created=$($fup.createdDateTime), RolloutSettings=$($fup.rolloutSettings.offerStartDateTimeInUTC)"
    Write-Status "Checking device states for profile: $($fup.displayName)..."
    try {
        $deviceStatusUri = "https://graph.microsoft.com/beta/deviceManagement/windowsFeatureUpdateProfiles/$($fup.id)/deviceStatuses"
        $deviceStates = (Invoke-MgGraphRequest -Method GET -Uri $deviceStatusUri).value
    }
    catch {
        Write-Status "  Could not retrieve device statuses for '$($fup.displayName)': $($_.Exception.Message)" "WARN"
        continue
    }

    foreach ($ds in $deviceStates) {
        $ageDays = $null
        $flag = switch ($ds.status) {
            "success" { "OK" }
            "error"   { "ERROR — check safeguard hold, GPO conflict, or CBS log (FeatureUpdates-A.md Phase 3)" }
            "conflict" {
                "CONFLICT — overlapping Feature Update Profile or Update Ring deferral (FeatureUpdates-A.md Symptom row 8)"
            }
            "pending" {
                if ($ds.lastReportedDateTime) {
                    $ageDays = [math]::Round(($now - [datetime]$ds.lastReportedDateTime).TotalDays, 1)
                }
                if ($ageDays -and $ageDays -gt $StalePendingDays) {
                    "STALE_PENDING — pending $ageDays days, likely stuck or device not checking in (FeatureUpdates-B.md Fix 1)"
                }
                else {
                    "PENDING — within normal rollout window"
                }
            }
            "notApplicable" { "NOT_APPLICABLE — device not in scope, wrong SKU, or already at/above target" }
            default         { "Unknown status: $($ds.status)" }
        }

        $results.Add([PSCustomObject]@{
            ProfileName    = $fup.displayName
            ProfileId      = $fup.id
            TargetVersion  = $fup.featureUpdateVersion
            DeviceName     = $ds.deviceDisplayName
            UserPrincipal  = $ds.userPrincipalName
            Status         = $ds.status
            LastReported   = $ds.lastReportedDateTime
            PendingAgeDays = $ageDays
            Flag           = $flag
        })
    }
}

# ---------------------------------------------------------------------------
# VALIDATE / REPORT
# ---------------------------------------------------------------------------
if ($results.Count -eq 0) {
    Write-Status "No device state rows returned for any matching profile. Nothing to report." "WARN"
    return
}

$errors        = @($results | Where-Object { $_.Status -eq "error" })
$conflicts     = @($results | Where-Object { $_.Status -eq "conflict" })
$stalePending  = @($results | Where-Object { $_.Flag -like "STALE_PENDING*" })
$pending       = @($results | Where-Object { $_.Status -eq "pending" })
$succeeded     = @($results | Where-Object { $_.Status -eq "success" })
$notApplicable = @($results | Where-Object { $_.Status -eq "notApplicable" })

Write-Host ""
Write-Status "===== FEATURE UPDATE DEPLOYMENT SUMMARY =====" "OK"
Write-Status "Total device-profile rows: $($results.Count)"
Write-Status "Succeeded:       $($succeeded.Count)" "OK"
Write-Status "Error:           $($errors.Count)" $(if ($errors.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Conflict:        $($conflicts.Count)" $(if ($conflicts.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Pending (total): $($pending.Count)" $(if ($pending.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "  of which stale (> $StalePendingDays days): $($stalePending.Count)" $(if ($stalePending.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Not applicable:  $($notApplicable.Count)"

$results | Where-Object { $_.Status -ne "success" -and $_.Status -ne "notApplicable" } |
    Format-Table ProfileName, DeviceName, Status, PendingAgeDays, Flag -AutoSize -Wrap

try {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "Full report exported to: $OutputPath" "OK"
}
catch {
    Write-Status "Failed to export CSV: $($_.Exception.Message)" "ERROR"
}

Write-Status "Done." "OK"
