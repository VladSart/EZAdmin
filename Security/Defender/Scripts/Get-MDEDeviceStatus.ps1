<#
.SYNOPSIS
    Queries Microsoft Defender for Endpoint (MDE) device health, onboarding status,
    sensor health, and active alerts via the Microsoft Graph Security API.

.DESCRIPTION
    Connects to Microsoft Graph (Security scope) and retrieves:
    - MDE onboarding status for one or all devices
    - Sensor health state (active / misconfigured / inactive / no sensor data)
    - Risk level (none / informational / low / medium / high)
    - Exposure level (none / low / medium / high)
    - Active alerts count per device
    - Last seen timestamp
    - OS platform and version
    - Assigned tags

    Output is written to console (colour-coded by risk) and exported to CSV.

    Can be run against a single device by name/MDEID, or against all onboarded devices
    filtered by risk level, sensor health state, or days since last check-in.

.PARAMETER DeviceName
    Filter by device display name (partial match supported).

.PARAMETER RiskLevel
    Filter by MDE risk level: none, informational, low, medium, high.
    Default: returns all risk levels.

.PARAMETER SensorHealthState
    Filter by sensor health state: active, inactive, misconfigured, noSensorData.
    Default: returns all states.

.PARAMETER NotSeenInDays
    Return only devices not seen in the last N days (useful for stale device cleanup).

.PARAMETER ExportPath
    Full path for CSV export. Defaults to $env:TEMP\MDE-DeviceStatus-<date>.csv.

.PARAMETER MaxDevices
    Maximum number of devices to return. Default: 500.

.EXAMPLE
    # Get all high-risk devices
    .\Get-MDEDeviceStatus.ps1 -RiskLevel high

.EXAMPLE
    # Get devices with misconfigured or inactive sensors
    .\Get-MDEDeviceStatus.ps1 -SensorHealthState misconfigured

.EXAMPLE
    # Get devices not seen in 30 days (stale)
    .\Get-MDEDeviceStatus.ps1 -NotSeenInDays 30

.EXAMPLE
    # Get a specific device by name
    .\Get-MDEDeviceStatus.ps1 -DeviceName "DESKTOP-CORP01"

.NOTES
    Requires: Microsoft.Graph PowerShell SDK (Install-Module Microsoft.Graph)
    Permissions needed (Graph): SecurityEvents.Read.All OR Machine.Read.All (MDE)
    Recommended role: Security Reader or Global Reader in Entra ID.
    Does NOT require admin on the target devices.
    Safe to run in production — read-only operations only.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$DeviceName,

    [Parameter()]
    [ValidateSet("none", "informational", "low", "medium", "high")]
    [string]$RiskLevel,

    [Parameter()]
    [ValidateSet("active", "inactive", "misconfigured", "noSensorData")]
    [string]$SensorHealthState,

    [Parameter()]
    [int]$NotSeenInDays,

    [Parameter()]
    [string]$ExportPath = "$env:TEMP\MDE-DeviceStatus-$(Get-Date -Format yyyyMMdd-HHmmss).csv",

    [Parameter()]
    [int]$MaxDevices = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Helpers
function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("INFO","OK","WARN","ERROR","SECTION")]
        [string]$Status = "INFO"
    )
    $colour = switch ($Status) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SECTION" { "Cyan" }
        default   { "White" }
    }
    $prefix = switch ($Status) {
        "SECTION" { "`n====" }
        default   { "[$Status]" }
    }
    Write-Host "$prefix $Message" -ForegroundColor $colour
}

function Get-RiskColour {
    param([string]$Level)
    switch ($Level) {
        "high"          { return "Red" }
        "medium"        { return "Yellow" }
        "low"           { return "Cyan" }
        "informational" { return "White" }
        default         { return "Gray" }
    }
}

function Get-SensorColour {
    param([string]$State)
    switch ($State) {
        "active"        { return "Green" }
        "misconfigured" { return "Yellow" }
        "inactive"      { return "Red" }
        default         { return "Gray" }
    }
}
#endregion

#region Prerequisites
Write-Status "Checking prerequisites..." -Status SECTION

# Check Graph module
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Security)) {
    Write-Status "Microsoft.Graph.Security module not found. Installing..." -Status WARN
    Install-Module Microsoft.Graph.Security -Scope CurrentUser -Force -AllowClobber
}

Import-Module Microsoft.Graph.Security -ErrorAction Stop
Write-Status "Microsoft.Graph.Security module loaded." -Status OK
#endregion

#region Authentication
Write-Status "Connecting to Microsoft Graph..." -Status SECTION

try {
    Connect-MgGraph -Scopes "SecurityEvents.Read.All" -NoWelcome -ErrorAction Stop
    $context = Get-MgContext
    Write-Status "Connected as: $($context.Account) | Tenant: $($context.TenantId)" -Status OK
}
catch {
    Write-Status "Graph connection failed: $($_.Exception.Message)" -Status ERROR
    Write-Status "Try: Connect-MgGraph -Scopes 'SecurityEvents.Read.All'" -Status INFO
    exit 1
}
#endregion

#region Fetch MDE Machines
Write-Status "Fetching MDE device list (max: $MaxDevices)..." -Status SECTION

try {
    # Build OData filter
    $filters = @()
    if ($RiskLevel) {
        $filters += "riskScore eq '$RiskLevel'"
    }
    if ($SensorHealthState) {
        $filters += "sensorHealthState eq '$SensorHealthState'"
    }

    $params = @{
        Top = $MaxDevices
    }
    if ($filters.Count -gt 0) {
        $params.Filter = $filters -join " and "
    }

    # Use the Security machines endpoint
    $uri = "https://api.securitycenter.microsoft.com/api/machines"

    # Fallback: try via Graph if direct API unavailable
    $rawDevices = $null
    try {
        # Try direct MDE API endpoint via Graph proxy
        $response = Invoke-MgGraphRequest -Uri "$uri`?`$top=$MaxDevices$(if($filters.Count -gt 0){" and filter=" + ($filters -join " and ")})" -Method GET
        $rawDevices = $response.value
        Write-Status "Retrieved $($rawDevices.Count) devices via MDE Security Center API." -Status OK
    }
    catch {
        Write-Status "MDE direct API unavailable, falling back to Graph Security API..." -Status WARN
        # Fallback to Graph security alerts for device list
        $secUri = "https://graph.microsoft.com/v1.0/security/microsoft.graph.security.runHuntingQuery"
        $query = @{
            Query = @"
DeviceInfo
| where Timestamp > ago(30d)
| summarize arg_max(Timestamp, *) by DeviceId
| project DeviceId, DeviceName, OSPlatform, OSVersion, OnboardingStatus, SensorHealthState
| order by DeviceName asc
| take $MaxDevices
"@
        }
        $huntingResult = Invoke-MgGraphRequest -Method POST -Uri $secUri -Body ($query | ConvertTo-Json) -ContentType "application/json"

        if ($huntingResult.results) {
            $rawDevices = $huntingResult.results
            Write-Status "Retrieved $($rawDevices.Count) devices via Advanced Hunting." -Status OK
        }
    }
}
catch {
    Write-Status "Failed to retrieve device list: $($_.Exception.Message)" -Status ERROR
    Write-Status "Ensure the account has SecurityEvents.Read.All permission." -Status WARN
    Disconnect-MgGraph | Out-Null
    exit 1
}
#endregion

#region Process and Filter
Write-Status "Processing device records..." -Status SECTION

$results = [System.Collections.Generic.List[PSObject]]::new()
$cutoffDate = if ($NotSeenInDays) { (Get-Date).AddDays(-$NotSeenInDays) } else { $null }

foreach ($dev in $rawDevices) {
    # Normalise field names (MDE API vs Hunting query have different casing)
    $name = $dev.computerDnsName ?? $dev.DeviceName ?? $dev.deviceName ?? "Unknown"
    $id   = $dev.id ?? $dev.DeviceId ?? $dev.deviceId ?? "Unknown"
    $os   = $dev.osPlatform ?? $dev.OSPlatform ?? "Unknown"
    $osVer = $dev.osVersion ?? $dev.OSVersion ?? "Unknown"
    $sensor = $dev.sensorHealthState ?? $dev.SensorHealthState ?? "Unknown"
    $risk = $dev.riskScore ?? $dev.RiskLevel ?? "unknown"
    $exposure = $dev.exposureLevel ?? "unknown"
    $lastSeen = $dev.lastSeen ?? $dev.LastSeen ?? $null
    $onboardStatus = $dev.onboardingStatus ?? $dev.OnboardingStatus ?? "Unknown"
    $alertCount = ($dev.relatedAlerts.Count ?? 0)

    # Apply DeviceName filter
    if ($DeviceName -and $name -notlike "*$DeviceName*") { continue }

    # Apply NotSeenInDays filter
    if ($cutoffDate -and $lastSeen) {
        try {
            $lastSeenDt = [datetime]::Parse($lastSeen)
            if ($lastSeenDt -gt $cutoffDate) { continue }
        }
        catch { <# skip date parse errors #> }
    }

    $record = [PSCustomObject]@{
        DeviceName      = $name
        DeviceId        = $id
        OnboardStatus   = $onboardStatus
        SensorHealth    = $sensor
        RiskLevel       = $risk
        ExposureLevel   = $exposure
        OSPlatform      = $os
        OSVersion       = $osVer
        ActiveAlerts    = $alertCount
        LastSeen        = $lastSeen
        Tags            = ($dev.machineTags -join "; ")
    }
    $results.Add($record)
}

Write-Status "Processed $($results.Count) matching devices." -Status OK
#endregion

#region Summary Report
Write-Status "Summary Report" -Status SECTION

if ($results.Count -eq 0) {
    Write-Status "No devices matched the specified filters." -Status WARN
}
else {
    # Risk breakdown
    $riskGroups = $results | Group-Object RiskLevel | Sort-Object Name
    Write-Host "`nRisk Level Breakdown:" -ForegroundColor Cyan
    foreach ($g in $riskGroups) {
        Write-Host ("  {0,-15} {1,4} device(s)" -f $g.Name, $g.Count) -ForegroundColor (Get-RiskColour $g.Name)
    }

    # Sensor health breakdown
    $sensorGroups = $results | Group-Object SensorHealth | Sort-Object Name
    Write-Host "`nSensor Health Breakdown:" -ForegroundColor Cyan
    foreach ($g in $sensorGroups) {
        Write-Host ("  {0,-20} {1,4} device(s)" -f $g.Name, $g.Count) -ForegroundColor (Get-SensorColour $g.Name)
    }

    # Devices with alerts
    $alertDevices = $results | Where-Object { $_.ActiveAlerts -gt 0 }
    if ($alertDevices) {
        Write-Host "`nDevices with Active Alerts: $($alertDevices.Count)" -ForegroundColor Yellow
        $alertDevices | Sort-Object ActiveAlerts -Descending | Select-Object -First 10 |
            Format-Table DeviceName, RiskLevel, ActiveAlerts, LastSeen -AutoSize
    }

    # Not seen recently
    $staleDevices = $results | Where-Object {
        if ($_.LastSeen) {
            try { [datetime]::Parse($_.LastSeen) -lt (Get-Date).AddDays(-7) } catch { $false }
        }
    }
    if ($staleDevices) {
        Write-Host "`nDevices not seen in >7 days: $($staleDevices.Count)" -ForegroundColor Yellow
    }

    # Print detailed table (top 20)
    Write-Status "Device Details (top 20):" -Status SECTION
    $results | Sort-Object {
        switch ($_.RiskLevel) { "high"{0}"medium"{1}"low"{2}"informational"{3}default{4} }
    } | Select-Object -First 20 |
        Format-Table DeviceName, OnboardStatus, SensorHealth, RiskLevel, ExposureLevel, ActiveAlerts, OSPlatform -AutoSize
}
#endregion

#region Export
if ($results.Count -gt 0) {
    $results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Status "Results exported to: $ExportPath" -Status OK
}
#endregion

#region Disconnect
Disconnect-MgGraph | Out-Null
Write-Status "Disconnected from Microsoft Graph." -Status OK
Write-Status "Run complete. Total devices reported: $($results.Count)" -Status OK
#endregion
