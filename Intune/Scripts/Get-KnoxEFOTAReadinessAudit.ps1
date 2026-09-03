<#
.SYNOPSIS
    Audits Intune-side readiness for Samsung Knox E-FOTA firmware update management
    across corporate-owned Android Enterprise devices.

.DESCRIPTION
    Samsung Knox E-FOTA integration with Intune depends on a layered chain: platform
    eligibility (Android Enterprise COBO/COSU/COPE only), two required Managed Google
    Play apps (Knox E-FOTA, Knox Service Plugin), an OEMConfig profile with three
    specific toggles enabled, and a manual on-device terms-acceptance step performed
    by the end user or a provisioning technician (see SamsungKnoxEFOTA-A.md /
    SamsungKnoxEFOTA-B.md for full architecture).

    This script audits the Intune-controllable portion of that chain read-only:
    platform/ownership eligibility, required-app install status, and OEMConfig
    profile presence, for either a single named device or the full fleet of
    Android corporate-owned managed devices. It flags devices that are eligible
    but appear to be missing a prerequisite, so staging/rollout gaps can be found
    before escalating to Samsung.

    It explicitly CANNOT and does not attempt to: query the Samsung Knox Admin
    Portal or Knox E-FOTA connector directly (no supported Graph surface exists
    for this), confirm whether the end user has completed the manual terms-
    acceptance step, or confirm actual on-device firmware campaign status. Cross-
    reference the Intune admin center's Samsung connector Monitor tab (or the Knox
    Admin Portal) for that Samsung-sourced, hourly-refreshed data.

.PARAMETER DeviceName
    Optional. Audits a single device by name. If omitted, audits all managed
    Android devices with ManagedDeviceOwnerType "company" (the E-FOTA-eligible
    population before filtering to COBO/COSU/COPE specifically).

.PARAMETER ExportPath
    Full path for CSV export. Defaults to
    $env:TEMP\KnoxEFOTA-ReadinessAudit-<date>.csv.

.EXAMPLE
    .\Get-KnoxEFOTAReadinessAudit.ps1
    Audits all corporate-owned Android devices for Knox E-FOTA prerequisite readiness.

.EXAMPLE
    .\Get-KnoxEFOTAReadinessAudit.ps1 -DeviceName "SAMSUNG-KIOSK-014"
    Audits a single device.

.NOTES
    Read-only. Requires an active Microsoft Graph connection with at least
    DeviceManagementManagedDevices.Read.All, DeviceManagementApps.Read.All, and
    DeviceManagementConfiguration.Read.All scopes (Connect-MgGraph is NOT called by
    this script — connect first with the scopes appropriate to your environment).
    Requires the Microsoft.Graph.DeviceManagement, Microsoft.Graph.DeviceManagement.Actions,
    and Microsoft.Graph.Authentication modules.
#>
[CmdletBinding()]
param(
    [string]$DeviceName,
    [string]$ExportPath = "$env:TEMP\KnoxEFOTA-ReadinessAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
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
    Write-Status "No active Microsoft Graph connection found. Run Connect-MgGraph with DeviceManagementManagedDevices.Read.All, DeviceManagementApps.Read.All, and DeviceManagementConfiguration.Read.All before running this script." "ERROR"
    return
}

Write-Status "Starting Samsung Knox E-FOTA readiness audit..." "INFO"

# ---------------------------------------------------------------------------
# 1. Pull candidate devices: Android, corporate-owned
# ---------------------------------------------------------------------------
$filter = "operatingSystem eq 'Android' and managedDeviceOwnerType eq 'company'"
if ($DeviceName) { $filter = "$filter and deviceName eq '$DeviceName'" }

Write-Status "Querying managed devices ($filter)..." "INFO"
$devices = Get-MgDeviceManagementManagedDevice -Filter $filter -All

if (-not $devices) {
    Write-Status "No matching corporate-owned Android devices found." "WARN"
    return
}
Write-Status "Found $($devices.Count) candidate device(s)." "OK"

# ---------------------------------------------------------------------------
# 2. Pull required apps and OEMConfig profiles once (avoid per-device calls)
# ---------------------------------------------------------------------------
Write-Status "Querying Knox E-FOTA / Knox Service Plugin app records..." "INFO"
$knoxApps = Get-MgDeviceAppManagementMobileApp -Filter "contains(displayName,'Knox E-FOTA') or contains(displayName,'Knox Service Plugin')" -All

if (-not $knoxApps) {
    Write-Status "Neither Knox E-FOTA nor Knox Service Plugin found as a deployed app in this tenant. Confirm both are added via Managed Google Play before proceeding." "ERROR"
}

Write-Status "Querying OEMConfig device configuration profiles..." "INFO"
$oemConfigProfiles = Get-MgDeviceManagementDeviceConfiguration -Filter "contains(displayName,'OEMConfig')" -All

if (-not $oemConfigProfiles) {
    Write-Status "No OEMConfig profile found by name match 'OEMConfig'. If your OEMConfig profile uses a different display name, results below will show FALSE for OEMConfigProfilePresent — verify manually." "WARN"
}

# ---------------------------------------------------------------------------
# 3. Per-device readiness assessment
# ---------------------------------------------------------------------------
$results = foreach ($device in $devices) {
    $appStatuses = foreach ($app in $knoxApps) {
        try {
            Get-MgDeviceAppManagementMobileAppDeviceStatus -MobileAppId $app.Id -ErrorAction Stop |
                Where-Object { $_.DeviceId -eq $device.Id }
        }
        catch { $null }
    }

    $knoxEFotaInstalled = ($appStatuses | Where-Object { $_.DeviceName -eq $device.DeviceName -and $_ -match "efota" }) -ne $null
    $anyAppInstalled = ($appStatuses | Measure-Object).Count -gt 0

    $eligibleOwnership = $device.ManagedDeviceOwnerType -eq "company"

    [PSCustomObject]@{
        DeviceName             = $device.DeviceName
        Model                   = $device.Model
        OperatingSystem         = $device.OperatingSystem
        ManagedDeviceOwnerType  = $device.ManagedDeviceOwnerType
        PlatformEligible        = $eligibleOwnership
        KnoxAppRecordsInTenant  = $knoxApps.Count
        AnyKnoxAppStatusFound   = $anyAppInstalled
        OEMConfigProfilePresent = ($oemConfigProfiles.Count -gt 0)
        LastSyncDateTime        = $device.LastSyncDateTime
        ReadinessNote           = if (-not $eligibleOwnership) {
            "NOT ELIGIBLE: ownership type must be Android Enterprise COBO/COSU/COPE (company-owned)."
        } elseif (-not $anyAppInstalled) {
            "GAP: no Knox E-FOTA / Knox Service Plugin install status found for this device — confirm Managed Google Play deployment."
        } elseif (-not $oemConfigProfiles) {
            "GAP: no OEMConfig profile found by name in this tenant — confirm OEMConfig template exists and is assigned."
        } else {
            "Intune-side prerequisites appear present. Cross-check Samsung connector Monitor tab / Knox Admin Portal for actual registration and campaign status — this script cannot query Samsung directly."
        }
    }
}

$results | Sort-Object PlatformEligible, DeviceName | Format-Table -AutoSize
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8

Write-Status "Audit complete. $($results.Count) device(s) evaluated." "OK"
Write-Status "Results exported to: $ExportPath" "OK"
Write-Status "This script cannot confirm Samsung-side registration or campaign status — cross-reference the Samsung connector's Monitor tab (Tenant administration > Connectors and tokens > Firmware over-the-air update > Samsung) or the Knox Admin Portal directly." "WARN"
