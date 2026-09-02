<#
.SYNOPSIS
    Collects device-level evidence for Windows Autopatch cloud-based quality update
    policy escalations (approval/deferral/pause troubleshooting).

.DESCRIPTION
    The cloud-based Windows quality update policy (Intune admin center > Devices >
    Manage updates > Windows updates > Quality updates), rolling out September-October
    2026, does not expose a documented, stable Microsoft Graph endpoint for policy
    definitions, per-category approval settings, or per-release approval/pause state
    as of this writing — that configuration lives entirely in the Manage updates portal
    workflow. This script collects the device-level signals that ARE Graph-reachable
    (compliance state, OS version/build, Insider-build heuristic, last check-in) and
    prints a prioritized checklist of the portal-only evidence an engineer must still
    gather manually before escalating.

.PARAMETER DeviceName
    Optional. Filter to a specific device by name. If omitted, audits up to -Top devices.

.PARAMETER Top
    Maximum number of devices to return when -DeviceName is not specified. Default 50.

.EXAMPLE
    .\Get-QualityUpdatePolicyAudit.ps1 -DeviceName "CONTOSO-WKS-042"

.EXAMPLE
    .\Get-QualityUpdatePolicyAudit.ps1 -Top 200

.NOTES
    Read-only. Requires Microsoft.Graph.DeviceManagement module and
    DeviceManagementManagedDevices.Read.All scope. Makes no configuration changes.
    Does NOT and cannot read quality update policy assignment, per-category approval
    method, deferral days, or release approval/pause state — see the printed checklist.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DeviceName,

    [int]$Top = 50,

    [string]$OutputPath = ".\QualityUpdatePolicyAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# --- Preflight ---
Write-Status "Connecting to Microsoft Graph..."
try {
    Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All" -NoWelcome
    Write-Status "Connected." "OK"
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    throw
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# --- Detect: device inventory ---
Write-Status "Querying managed device(s)$(if ($DeviceName) { " matching '$DeviceName'" } else { " (top $Top)" })..."
try {
    $devices = if ($DeviceName) {
        Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$DeviceName'"
    }
    else {
        Get-MgDeviceManagementManagedDevice -Top $Top
    }
}
catch {
    Write-Status "Failed to query managed devices: $($_.Exception.Message)" "ERROR"
    throw
}

if (-not $devices) {
    Write-Status "No matching device(s) found." "WARN"
}

$insiderCount = 0
foreach ($d in $devices) {
    $isWindows = $d.OperatingSystem -match "(?i)windows"
    $insiderFlag = if ($isWindows -and $d.OSVersion -match "(?i)\.(2[5-9]\d{2}|3\d{3})\." ) {
        # Heuristic only — build-number pattern alone cannot reliably confirm Insider channel;
        # this flags "worth checking" rather than a definitive determination.
        "WORTH_VERIFYING"
    } else { "STANDARD" }
    if ($insiderFlag -eq "WORTH_VERIFYING") { $insiderCount++ }

    $staleSync = $null
    if ($d.LastSyncDateTime) {
        $staleSync = [math]::Round(((Get-Date) - $d.LastSyncDateTime).TotalHours, 1)
    }

    $results.Add([PSCustomObject]@{
        Category           = "Device"
        DeviceName         = $d.DeviceName
        OperatingSystem    = $d.OperatingSystem
        OSVersion          = $d.OSVersion
        ComplianceState    = $d.ComplianceState
        LastSyncDateTime   = $d.LastSyncDateTime
        HoursSinceLastSync = $staleSync
        InsiderBuildCheck  = $insiderFlag
        Note               = "Approval/deferral/pause/Applied-policy state is portal-only"
    })
}

Write-Status "Collected $($devices.Count) device record(s); $insiderCount flagged worth verifying for Insider-build exclusion." "OK"

if ($devices | Where-Object { $_.LastSyncDateTime -and ((Get-Date) - $_.LastSyncDateTime).TotalHours -gt 8 }) {
    Write-Status "One or more devices haven't checked in within 8+ hours — factor this into any pause/resume propagation-latency assessment (documented up-to-8h window)." "WARN"
}

# --- Report: portal-only checklist ---
Write-Status ""
Write-Status "=== PORTAL-ONLY ITEMS — this script CANNOT check these; verify manually ===" "WARN"
$portalChecklist = @(
    "Manage updates > Windows updates > Quality updates > Manage updates blade — confirm device's assigned policy"
    "Policy detail — per-category approval method (security/non-security/OOB security/OOB non-security) + deferral days"
    "Manage updates > select Release > Approved policies (X of Y) + Paused flag, per policy"
    "Reports > Windows Autopatch > Windows quality updates > Reports tab > Quality update status"
    "  -> Target compliance, Target release, Installed release, Applied policy, Hotpatch readiness columns"
    "Confirm whether device is ALSO targeted by a legacy Update ring policy (dual-policy precedence)"
    "If hotpatch-enabled: confirm no non-security update was recently approved for the same policy"
)
foreach ($item in $portalChecklist) {
    Write-Host "  [ ] $item" -ForegroundColor Yellow
    $results.Add([PSCustomObject]@{ Category = "PortalOnly"; DeviceName = "N/A"; Note = $item })
}

# --- Export ---
$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported to $OutputPath ($($results.Count) rows)." "OK"
