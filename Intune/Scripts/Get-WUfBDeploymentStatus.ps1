<#
.SYNOPSIS
    Reports Windows Update for Business (WUfB) ring assignment, local policy state, and GPO conflicts.

.DESCRIPTION
    Combines a local device-side check (active ring policy from PolicyManager, WSUS/GPO conflict
    detection, enrollment state) with a Graph-side check of Intune Update Ring policy assignment and
    per-device compliance/deployment state. Automates the Triage and Diagnosis steps in
    Intune/Troubleshooting/WUfB-B.md so an engineer can quickly tell whether a device is missing its
    ring policy, stuck on a GPO conflict, or blocked by a safeguard hold.

    This script does NOT modify update ring policies, does NOT remove GPO settings, and does NOT force
    Windows Update installs. It is read-only reporting — remediation must be applied manually or via a
    separate script (see WUfB-B.md Common Fix Paths).

.PARAMETER DeviceName
    Optional filter — only report Graph-side ring policy state for devices whose display name matches
    this wildcard pattern (e.g. "LT-*"). Default: all devices with an update ring assignment.

.PARAMETER SkipLocalCheck
    Switch. Skip the local device-side checks (registry, enrollment state). Use when running remotely
    against Graph only.

.PARAMETER OutputPath
    Path for CSV export of the Graph-side per-device ring policy state. Defaults to
    .\WUfBDeploymentStatus_<timestamp>.csv in the current directory.

.EXAMPLE
    .\Get-WUfBDeploymentStatus.ps1

.EXAMPLE
    .\Get-WUfBDeploymentStatus.ps1 -DeviceName "LT-*" -SkipLocalCheck

.NOTES
    Requires: Microsoft.Graph.Authentication module (uses Invoke-MgGraphRequest against the beta
    endpoint for deviceManagement/deviceConfigurations filtered to windowsUpdateForBusinessConfiguration).
    Requires Graph scope: DeviceManagementConfiguration.Read.All
    Run-as (local check portion): local administrator on the target device.
    Safe: Yes — fully read-only against Microsoft Graph, local registry, and event log.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DeviceName = "*",

    [Parameter(Mandatory = $false)]
    [switch]$SkipLocalCheck,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\WUfBDeploymentStatus_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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
    Write-Status "===== LOCAL WUfB RING / CONFLICT CHECK =====" "OK"

    $pmUpdatePath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update"
    if (Test-Path $pmUpdatePath) {
        $ring = Get-ItemProperty -Path $pmUpdatePath -ErrorAction SilentlyContinue
        Write-Status "Active ring policy from PolicyManager:" "INFO"
        $ring | Select-Object DeferFeatureUpdatesPeriodInDays, DeferQualityUpdatesPeriodInDays, BranchReadinessLevel, PauseFeatureUpdatesStartTime, PauseQualityUpdatesStartTime |
            Format-List

        if (-not $ring.PSObject.Properties.Name -contains "BranchReadinessLevel" -or $null -eq $ring.BranchReadinessLevel) {
            Write-Status "BranchReadinessLevel not set — ring policy likely not applied. See Fix 1 — Force Intune sync and check policy assignment." "WARN"
        }
    }
    else {
        Write-Status "No PolicyManager Update key found — device has not received any WUfB ring policy via MDM." "ERROR"
    }

    $gpoWuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    if (Test-Path $gpoWuPath) {
        $gpoWu = Get-ItemProperty -Path $gpoWuPath -ErrorAction SilentlyContinue
        Write-Status "GPO-delivered WindowsUpdate policy values present — potential conflict source. See Fix 3 — Remove conflicting GPO." "WARN"
        $gpoWu | Select-Object * -ExcludeProperty PS* | Format-List
    }
    else {
        Write-Status "No GPO-delivered WindowsUpdate policy key found — no GPO conflict at this key." "OK"
    }

    $gpoAuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    if (Test-Path $gpoAuPath) {
        $gpoAu = Get-ItemProperty -Path $gpoAuPath -ErrorAction SilentlyContinue
        if ($gpoAu.PSObject.Properties.Name -contains "UseWUServer" -and $gpoAu.UseWUServer -eq 1) {
            Write-Status "UseWUServer = 1 — device is pointed at WSUS and may ignore WUfB ring policy entirely. See Fix 4 — Fix WSUS conflict." "ERROR"
        }
    }

    $enrollKeys = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderID -eq "MS DM Server" }
    if ($enrollKeys) {
        Write-Status "Enrollment record found. EnrollmentState:" "INFO"
        $enrollKeys | Select-Object EnrollmentType, UPN, EnrollmentState | Format-Table -AutoSize
    }
    else {
        Write-Status "No MDM enrollment record found under MS DM Server provider — device may not be Intune-enrolled." "ERROR"
    }

    Write-Status "Checking for safeguard hold / compat block signals in WU client log (last 20 events)..."
    try {
        $wuEvents = Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 20 -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match "safeguard|BLOCKED_BY_POLICY|compat" }
        if ($wuEvents) {
            Write-Status "Found safeguard/compat-related events:" "WARN"
            $wuEvents | Select-Object TimeCreated, Id, Message | Format-Table -AutoSize -Wrap
        }
        else {
            Write-Status "No safeguard hold or policy-block signals in the last 20 WU client events." "OK"
        }
    }
    catch {
        Write-Status "Could not read Microsoft-Windows-WindowsUpdateClient/Operational log: $($_.Exception.Message)" "WARN"
    }

    Write-Host ""
}
else {
    Write-Status "Skipping local device-side check (-SkipLocalCheck specified)." "INFO"
}

# ---------------------------------------------------------------------------
# PREFLIGHT — GRAPH
# ---------------------------------------------------------------------------
Write-Status "===== GRAPH-SIDE UPDATE RING POLICY CHECK =====" "OK"
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
# DETECT — locate Update Ring configurations
# ---------------------------------------------------------------------------
Write-Status "Retrieving Windows Update Ring configurations..."
try {
    $configs = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations").value
}
catch {
    Write-Status "Failed to query deviceConfigurations: $($_.Exception.Message)" "ERROR"
    throw
}

$rings = $configs | Where-Object { $_.'@odata.type' -eq "#microsoft.graph.windowsUpdateForBusinessConfiguration" }

if (-not $rings -or $rings.Count -eq 0) {
    Write-Status "No Update Ring configurations found in this tenant. Confirm rings exist under Intune > Devices > Windows > Update rings." "WARN"
    return
}
Write-Status "Found $($rings.Count) Update Ring(s): $($rings.displayName -join ', ')" "OK"

# ---------------------------------------------------------------------------
# EXECUTE — per-ring device deployment states
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()

foreach ($ring in $rings) {
    Write-Status "Ring '$($ring.displayName)': FeatureDeferral=$($ring.deferFeatureUpdatesPeriodInDays)d, QualityDeferral=$($ring.deferQualityUpdatesPeriodInDays)d, Branch=$($ring.qualityUpdatesDeferralPeriodInDays)"
    Write-Status "Checking device states for ring: $($ring.displayName)..."
    try {
        $deviceStatusUri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$($ring.id)/deviceStatuses"
        $deviceStates = (Invoke-MgGraphRequest -Method GET -Uri $deviceStatusUri).value
    }
    catch {
        Write-Status "  Could not retrieve device statuses for '$($ring.displayName)': $($_.Exception.Message)" "WARN"
        continue
    }

    foreach ($ds in $deviceStates) {
        if ($DeviceName -ne "*" -and $ds.deviceDisplayName -notlike $DeviceName) { continue }

        $flag = switch ($ds.status) {
            "succeeded" { "OK" }
            "error"     { "ERROR — check policy assignment / GPO conflict" }
            "conflict"  { "CONFLICT — overlapping update ring or Feature Update Profile" }
            "pending"   { "PENDING — check sync timing / assignment scope" }
            default     { "Unknown status: $($ds.status)" }
        }

        $results.Add([PSCustomObject]@{
            RingName      = $ring.displayName
            RingId        = $ring.id
            DeviceName    = $ds.deviceDisplayName
            UserPrincipal = $ds.userPrincipalName
            Status        = $ds.status
            LastReported  = $ds.lastReportedDateTime
            Flag          = $flag
        })
    }
}

# ---------------------------------------------------------------------------
# VALIDATE / REPORT
# ---------------------------------------------------------------------------
if ($results.Count -eq 0) {
    Write-Status "No device state rows matched the given filter. Nothing to report." "WARN"
    return
}

$errors    = @($results | Where-Object { $_.Status -eq "error" })
$conflicts = @($results | Where-Object { $_.Status -eq "conflict" })
$pending   = @($results | Where-Object { $_.Status -eq "pending" })
$succeeded = @($results | Where-Object { $_.Status -eq "succeeded" })

Write-Host ""
Write-Status "===== WUFB RING DEPLOYMENT SUMMARY =====" "OK"
Write-Status "Total device-ring rows: $($results.Count)"
Write-Status "Succeeded:  $($succeeded.Count)" "OK"
Write-Status "Error:      $($errors.Count)" $(if ($errors.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Conflict:   $($conflicts.Count)" $(if ($conflicts.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Pending:    $($pending.Count)" $(if ($pending.Count -gt 0) { "WARN" } else { "OK" })

$results | Where-Object { $_.Status -ne "succeeded" } | Format-Table RingName, DeviceName, Status, Flag -AutoSize

try {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "Full report exported to: $OutputPath" "OK"
}
catch {
    Write-Status "Failed to export CSV: $($_.Exception.Message)" "ERROR"
}

Write-Status "Done." "OK"
