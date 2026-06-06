<#
.SYNOPSIS
    Retrieves comprehensive Autopilot device status from Intune via Microsoft Graph.

.DESCRIPTION
    Queries Microsoft Graph for Autopilot-registered devices and their current
    deployment/enrollment status. Outputs a summary of each device including:
    - Autopilot profile assignment state
    - Intune enrollment state
    - Entra join type (Hybrid / Entra-only)
    - Last contact time
    - Serial number and hardware hash presence
    Exports results to CSV for reporting or escalation.

    Does NOT modify any data. Safe to run in production.

.PARAMETER TenantId
    Entra ID tenant ID (GUID). Required for authentication.

.PARAMETER ClientId
    App registration Client ID with DeviceManagementServiceConfig.Read.All permission.
    If omitted, uses interactive auth (requires Microsoft.Graph PowerShell module).

.PARAMETER ClientSecret
    App registration client secret. Used with ClientId for service principal auth.

.PARAMETER FilterSerial
    Optional. Filter output to a specific device serial number.

.PARAMETER ExportPath
    Path to export CSV results. Defaults to .\AutopilotDeviceStatus_<timestamp>.csv

.EXAMPLE
    .\Get-AutopilotDeviceStatus.ps1 -TenantId "contoso.onmicrosoft.com"
    # Interactive login, retrieves all Autopilot devices

.EXAMPLE
    .\Get-AutopilotDeviceStatus.ps1 -TenantId "<guid>" -ClientId "<guid>" -ClientSecret "<secret>"
    # Service principal auth — suitable for scheduled/automated runs

.EXAMPLE
    .\Get-AutopilotDeviceStatus.ps1 -TenantId "<guid>" -FilterSerial "SERIAL123"
    # Check status of a single device by serial number

.NOTES
    Requires: Microsoft.Graph.Intune or Microsoft.Graph PowerShell module
    Permissions: DeviceManagementServiceConfig.Read.All, Device.Read.All
    Safe/Unsafe: READ-ONLY — no changes made
    Run-as: Standard user (with appropriate Graph permissions)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$ClientId,

    [Parameter(Mandatory = $false)]
    [string]$ClientSecret,

    [Parameter(Mandatory = $false)]
    [string]$FilterSerial,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = ".\AutopilotDeviceStatus_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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

function Get-GraphToken {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    }
    $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $response = Invoke-RestMethod -Uri $tokenEndpoint -Method Post -Body $body
    return $response.access_token
}

function Invoke-GraphRequest {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )
    $results = @()
    $nextLink = $Uri
    do {
        $response = Invoke-RestMethod -Uri $nextLink -Headers $Headers -Method Get
        $results += $response.value
        $nextLink = $response.'@odata.nextLink'
    } while ($nextLink)
    return $results
}

# ─── PREFLIGHT ───────────────────────────────────────────────────────────────
Write-Status "Starting Autopilot Device Status Report" "INFO"
Write-Status "Tenant: $TenantId"

# ─── AUTHENTICATION ───────────────────────────────────────────────────────────
$headers = @{}

if ($ClientId -and $ClientSecret) {
    Write-Status "Using service principal authentication" "INFO"
    $token = Get-GraphToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
    $headers["Authorization"] = "Bearer $token"
    $headers["Content-Type"]  = "application/json"
} else {
    Write-Status "Using interactive authentication via Microsoft.Graph module" "INFO"
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Status "Installing Microsoft.Graph.Authentication module..." "WARN"
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
    }
    Import-Module Microsoft.Graph.Authentication
    Connect-MgGraph -TenantId $TenantId -Scopes "DeviceManagementServiceConfig.Read.All", "Device.Read.All" -NoWelcome
    $token = (Get-MgContext).AccessToken
    if (-not $token) {
        # Fallback: get token via helper
        $tokenInfo = Get-MgContext
        Write-Status "Connected as: $($tokenInfo.Account)" "OK"
    }
    # Use MgGraph REST directly
    $useGraphModule = $true
}

# ─── RETRIEVE AUTOPILOT DEVICES ───────────────────────────────────────────────
Write-Status "Querying Autopilot registered devices..." "INFO"

$autopilotUri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$top=1000"
if ($FilterSerial) {
    $autopilotUri += "&`$filter=contains(serialNumber,'$FilterSerial')"
}

if ($useGraphModule -eq $true) {
    $autopilotDevices = (Invoke-MgGraphRequest -Uri $autopilotUri -Method GET).value
} else {
    $autopilotDevices = Invoke-GraphRequest -Uri $autopilotUri -Headers $headers
}

Write-Status "Found $($autopilotDevices.Count) Autopilot device(s)" "OK"

# ─── RETRIEVE MANAGED DEVICES FOR CORRELATION ────────────────────────────────
Write-Status "Querying Intune managed devices for enrollment correlation..." "INFO"

$managedDevicesUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=id,deviceName,serialNumber,enrollmentState,lastSyncDateTime,azureADRegistered,azureADDeviceId,joinType,managementState,complianceState&`$top=1000"

if ($useGraphModule -eq $true) {
    $managedDevices = (Invoke-MgGraphRequest -Uri $managedDevicesUri -Method GET).value
} else {
    $managedDevices = Invoke-GraphRequest -Uri $managedDevicesUri -Headers $headers
}

# Build lookup by serial
$managedBySerial = @{}
foreach ($md in $managedDevices) {
    if ($md.serialNumber) {
        $managedBySerial[$md.serialNumber] = $md
    }
}

# ─── BUILD REPORT ─────────────────────────────────────────────────────────────
Write-Status "Building status report..." "INFO"

$report = foreach ($device in $autopilotDevices) {
    $managed = $managedBySerial[$device.serialNumber]

    $profileState = switch ($device.deploymentProfileAssignmentStatus) {
        "assigned"         { "✅ Assigned" }
        "notAssigned"      { "⚠️  Not Assigned" }
        "failed"           { "❌ Assignment Failed" }
        "assignedUnkownSyncState" { "🔄 Assigned (Sync Pending)" }
        default            { $device.deploymentProfileAssignmentStatus }
    }

    $enrollState = if ($managed) {
        switch ($managed.enrollmentState) {
            "enrolled"    { "✅ Enrolled" }
            "notContacted"{ "⚠️  Not Contacted" }
            "failed"      { "❌ Enrollment Failed" }
            default       { $managed.enrollmentState }
        }
    } else { "⬜ Not in Managed Devices" }

    $joinType = if ($managed) {
        switch ($managed.joinType) {
            "azureADJoined"        { "Entra Joined" }
            "hybridAzureADJoined"  { "Hybrid Joined" }
            "azureADRegistered"    { "Entra Registered" }
            default                { $managed.joinType }
        }
    } else { "Unknown" }

    [PSCustomObject]@{
        SerialNumber          = $device.serialNumber
        Model                 = $device.model
        Manufacturer          = $device.manufacturer
        GroupTag              = $device.groupTag
        AssignedUser          = $device.userPrincipalName
        ProfileName           = $device.deploymentProfileDisplayName
        ProfileAssignedStatus = $profileState
        ProfileAssignedDate   = $device.deploymentProfileAssignedDateTime
        EnrollmentState       = $enrollState
        JoinType              = $joinType
        LastIntuneSync        = if ($managed) { $managed.lastSyncDateTime } else { "N/A" }
        ComplianceState       = if ($managed) { $managed.complianceState } else { "N/A" }
        ManagedDeviceId       = if ($managed) { $managed.id } else { "N/A" }
        AutopilotId           = $device.id
        HasHardwareHash       = if ($device.hardwareIdentifier) { "Yes" } else { "No" }
    }
}

# ─── DISPLAY SUMMARY ──────────────────────────────────────────────────────────
Write-Status "=== SUMMARY ===" "INFO"
Write-Status "Total Autopilot devices:         $($report.Count)"
Write-Status "Profile Assigned:                $(($report | Where-Object { $_.ProfileAssignedStatus -match '✅' }).Count)"
Write-Status "Not Assigned / Failed:           $(($report | Where-Object { $_.ProfileAssignedStatus -match '⚠️|❌' }).Count)"
Write-Status "Enrolled in Intune:              $(($report | Where-Object { $_.EnrollmentState -match '✅' }).Count)"
Write-Status "Not Enrolled / Failed:           $(($report | Where-Object { $_.EnrollmentState -match '⬜|❌' }).Count)"
Write-Status "Hybrid Joined devices:           $(($report | Where-Object { $_.JoinType -match 'Hybrid' }).Count)"

# ─── HIGHLIGHT PROBLEM DEVICES ───────────────────────────────────────────────
$problemDevices = $report | Where-Object {
    $_.ProfileAssignedStatus -match '⚠️|❌' -or
    $_.EnrollmentState -match '⬜|❌'
}

if ($problemDevices) {
    Write-Status "=== DEVICES REQUIRING ATTENTION ===" "WARN"
    $problemDevices | Select-Object SerialNumber, Model, ProfileAssignedStatus, EnrollmentState, JoinType | Format-Table -AutoSize
}

# ─── EXPORT ───────────────────────────────────────────────────────────────────
$report | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Results exported to: $ExportPath" "OK"

# ─── DISCONNECT ───────────────────────────────────────────────────────────────
if ($useGraphModule -eq $true) {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

Write-Status "Report complete." "OK"
