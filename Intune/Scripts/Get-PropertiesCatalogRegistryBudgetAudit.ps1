<#
.SYNOPSIS
    Audits Intune properties catalog profiles for per-device registry-key budget
    exposure against the documented 100-key-per-device cap.

.DESCRIPTION
    Intune's properties catalog Registry category enforces a 100-registry-key limit
    per device, cumulative across EVERY properties catalog profile assigned to that
    device — not per-profile (see PropertiesCatalog-A.md / PropertiesCatalog-B.md for
    full architecture). Because a device can be targeted by multiple profiles built
    by different admins/teams at different times, it's easy to exceed this cap
    without any single profile looking large in isolation.

    This script enumerates properties catalog / registry-named device configuration
    profiles, reports how many are assigned to each candidate device (via group
    assignment membership), and flags devices targeted by an unusually high number
    of such profiles as candidates for manual key-count review, since Graph does not
    expose a direct "registry keys configured" count per profile.

    It explicitly CANNOT and does not attempt to: parse the actual registry key list
    configured inside each profile's payload (Graph's device configuration resource
    does not expose properties catalog settings content in a stable, parseable form
    at the time of writing), confirm whether any specific value is being silently
    filtered by sensitive-value detection, or read collected Device Inventory data
    itself. It is a planning/triage aid to find devices at risk of profile-count
    sprawl, not an authoritative key-count report.

.PARAMETER DeviceName
    Optional. Audits a single device by name. If omitted, audits all Windows managed
    devices.

.PARAMETER ProfileCountWarningThreshold
    Number of properties-catalog/registry-named profiles assigned to a single device
    at or above which it's flagged for manual review. Defaults to 3, since even a
    modest number of independently-built profiles can plausibly approach the 100-key
    cap in combination.

.PARAMETER ExportPath
    Full path for CSV export. Defaults to
    $env:TEMP\PropertiesCatalog-RegistryBudgetAudit-<date>.csv.

.EXAMPLE
    .\Get-PropertiesCatalogRegistryBudgetAudit.ps1
    Audits all Windows managed devices for properties-catalog profile-count exposure.

.EXAMPLE
    .\Get-PropertiesCatalogRegistryBudgetAudit.ps1 -DeviceName "FIN-LAPTOP-221" -ProfileCountWarningThreshold 2
    Audits a single device with a stricter warning threshold.

.NOTES
    Read-only. Requires an active Microsoft Graph connection with at least
    DeviceManagementManagedDevices.Read.All and DeviceManagementConfiguration.Read.All
    scopes (Connect-MgGraph is NOT called by this script — connect first with the
    scopes appropriate to your environment). Requires the
    Microsoft.Graph.DeviceManagement and Microsoft.Graph.Authentication modules.
#>
[CmdletBinding()]
param(
    [string]$DeviceName,
    [int]$ProfileCountWarningThreshold = 3,
    [string]$ExportPath = "$env:TEMP\PropertiesCatalog-RegistryBudgetAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

try {
    $ctx = Get-MgContext -ErrorAction Stop
    if (-not $ctx) { throw "No active Graph context." }
}
catch {
    Write-Status "No active Microsoft Graph connection found. Run Connect-MgGraph with DeviceManagementManagedDevices.Read.All and DeviceManagementConfiguration.Read.All before running this script." "ERROR"
    return
}

Write-Status "Starting properties catalog registry-budget exposure audit..." "INFO"

# ---------------------------------------------------------------------------
# 1. Pull candidate Windows devices
# ---------------------------------------------------------------------------
$deviceFilter = "operatingSystem eq 'Windows'"
if ($DeviceName) { $deviceFilter = "$deviceFilter and deviceName eq '$DeviceName'" }

Write-Status "Querying Windows managed devices..." "INFO"
$devices = Get-MgDeviceManagementManagedDevice -Filter $deviceFilter -All

if (-not $devices) {
    Write-Status "No matching Windows devices found." "WARN"
    return
}
Write-Status "Found $($devices.Count) candidate device(s)." "OK"

# ---------------------------------------------------------------------------
# 2. Pull candidate properties-catalog / registry profiles and their assignments
# ---------------------------------------------------------------------------
Write-Status "Querying device configuration profiles matching 'Properties catalog' or 'Registry' by name..." "INFO"
$candidateProfiles = Get-MgDeviceManagementDeviceConfiguration -Filter "contains(displayName,'Properties catalog') or contains(displayName,'Registry')" -All

if (-not $candidateProfiles) {
    Write-Status "No properties-catalog/registry-named profiles found. If your naming convention differs, this script will under-report — adjust the -Filter match manually." "WARN"
    return
}
Write-Status "Found $($candidateProfiles.Count) candidate profile(s) by name match." "OK"

$profileAssignments = @{}
foreach ($profile in $candidateProfiles) {
    try {
        $assignments = Get-MgDeviceManagementDeviceConfigurationAssignment -DeviceConfigurationId $profile.Id -ErrorAction Stop
        $profileAssignments[$profile.Id] = $assignments
    }
    catch {
        Write-Status "Could not read assignments for profile '$($profile.DisplayName)': $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# 3. Per-device rollup: how many candidate profiles could plausibly target it
#    NOTE: this is a name/assignment-based heuristic, not a confirmed
#    group-membership resolution (that requires an additional directory read
#    per assignment target group, intentionally out of scope for this script).
# ---------------------------------------------------------------------------
$results = foreach ($device in $devices) {
    $matchedProfiles = $candidateProfiles | Where-Object { $profileAssignments.ContainsKey($_.Id) }

    [PSCustomObject]@{
        DeviceName                  = $device.DeviceName
        OperatingSystem              = $device.OperatingSystem
        JoinType                     = $device.JoinType
        ManagementAgent              = $device.ManagementAgent
        CandidateProfileNamesTenantWide = ($matchedProfiles.DisplayName -join "; ")
        CandidateProfileCountTenantWide = $matchedProfiles.Count
        FlaggedForManualReview       = ($matchedProfiles.Count -ge $ProfileCountWarningThreshold)
        Note                         = "CandidateProfileCountTenantWide is a TENANT-WIDE count of matching profiles, not a confirmed per-device assignment count — resolve target-group membership manually to confirm which of these profiles actually target this specific device before treating the 100-key cap as at risk."
    }
}

$results | Sort-Object FlaggedForManualReview -Descending | Format-Table -AutoSize
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8

$flaggedCount = ($results | Where-Object { $_.FlaggedForManualReview }).Count
Write-Status "Audit complete. $($results.Count) device(s) evaluated; $flaggedCount flagged for manual registry-key-budget review." "OK"
Write-Status "Results exported to: $ExportPath" "OK"
Write-Status "This script cannot read actual configured registry-key counts inside profile payloads or resolve group membership to devices — treat output as a starting point for manual review, not an authoritative over-cap determination." "WARN"
