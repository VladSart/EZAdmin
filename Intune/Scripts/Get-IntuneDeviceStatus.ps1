
<#
.SYNOPSIS
    Retrieves Intune managed device status — compliance, last sync, OS version, and enrollment details.

.DESCRIPTION
    Queries the Microsoft Graph API to return a comprehensive snapshot of one or more Intune managed
    devices. Useful for L2/L3 triage before escalating compliance or enrollment issues.

    Output includes:
      - Compliance state and last evaluation timestamp
      - Last MDM sync time and sync state
      - OS version and build number
      - Enrollment type, profile status, and AAD join type
      - Primary user and device category

    Results are exported to CSV for evidence packs and ticket notes.

.PARAMETER DeviceName
    Filter by device display name (supports partial match).

.PARAMETER UPN
    Filter devices by primary user UPN.

.PARAMETER ComplianceState
    Filter by compliance state: compliant, noncompliant, unknown, error, inGracePeriod.

.PARAMETER All
    Return all managed devices (may be slow in large tenants — use with -Top).

.PARAMETER Top
    Maximum number of devices to return (default 100, max 999).

.PARAMETER TenantId
    Azure AD Tenant ID or primary domain.

.PARAMETER ClientId
    App registration client ID with DeviceManagementManagedDevices.Read.All.

.PARAMETER ClientSecret
    App registration client secret.

.EXAMPLE
    # Get status of a specific device
    .\Get-IntuneDeviceStatus.ps1 -DeviceName "LAPTOP-01" -TenantId "contoso.com" -ClientId "<id>" -ClientSecret "<secret>"

.EXAMPLE
    # Get all non-compliant devices
    .\Get-IntuneDeviceStatus.ps1 -ComplianceState "noncompliant" -All -TenantId "contoso.com" -ClientId "<id>" -ClientSecret "<secret>"

.EXAMPLE
    # Get devices for a user
    .\Get-IntuneDeviceStatus.ps1 -UPN "jane.doe@contoso.com" -TenantId "contoso.com" -ClientId "<id>" -ClientSecret "<secret>"

.NOTES
    Requires: DeviceManagementManagedDevices.Read.All (Application permission)
    Run-as: Standard user (no elevation needed)
    Safe/Unsafe: SAFE — read-only
#>

[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(ParameterSetName = 'ByName')]
    [string]$DeviceName,

    [Parameter(ParameterSetName = 'ByUser', Mandatory)]
    [string]$UPN,

    [Parameter(ParameterSetName = 'ByCompliance')]
    [ValidateSet('compliant','noncompliant','unknown','error','inGracePeriod')]
    [string]$ComplianceState,

    [Parameter(ParameterSetName = 'AllDevices', Mandatory)]
    [switch]$All,

    [int]$Top = 100,

    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$ClientId,

    [Parameter(Mandatory)]
    [string]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$Status] $Message" -ForegroundColor $colour
}

# ─────────────────────────────────────────────
# AUTH
# ─────────────────────────────────────────────
Write-Status "Acquiring Graph token..."
$tokenBody = @{
    grant_type    = "client_credentials"
    client_id     = $ClientId
    client_secret = $ClientSecret
    scope         = "https://graph.microsoft.com/.default"
}
$tokenResp = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
    -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
$headers = @{ Authorization = "Bearer $($tokenResp.access_token)" }
Write-Status "Token OK" -Status "OK"

# ─────────────────────────────────────────────
# FIELD SELECT — what we care about for triage
# ─────────────────────────────────────────────
$selectFields = @(
    "id", "deviceName", "managedDeviceOwnerType", "enrolledDateTime",
    "lastSyncDateTime", "operatingSystem", "osVersion", "complianceState",
    "jailBroken", "managementAgent", "azureADRegistered", "azureADDeviceId",
    "deviceEnrollmentType", "activationLockBypassCode", "emailAddress",
    "userDisplayName", "userPrincipalName", "deviceCategoryDisplayName",
    "isEncrypted", "deviceActionResults", "autopilotEnrolled",
    "managementCertificateExpirationDate", "enrollmentProfileName"
) -join ","

$baseUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices"

# ─────────────────────────────────────────────
# BUILD FILTER
# ─────────────────────────────────────────────
$filterParts = @()
switch ($PSCmdlet.ParameterSetName) {
    'ByName'       { if ($DeviceName)      { $filterParts += "contains(deviceName,'$DeviceName')" } }
    'ByUser'       { $filterParts += "userPrincipalName eq '$UPN'" }
    'ByCompliance' { $filterParts += "complianceState eq '$ComplianceState'" }
    'AllDevices'   { } # no filter
}

$query = "`$select=$selectFields&`$top=$Top"
if ($filterParts) { $query += "&`$filter=$($filterParts -join ' and ')" }
$uri = "${baseUri}?${query}"

# ─────────────────────────────────────────────
# FETCH (handle paging)
# ─────────────────────────────────────────────
Write-Status "Querying Intune managed devices..."
$allDevices = [System.Collections.Generic.List[object]]::new()

do {
    $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
    $resp.value | ForEach-Object { $allDevices.Add($_) }
    $uri = $resp.'@odata.nextLink'
    if ($uri) { Write-Status "Paging... ($($allDevices.Count) so far)" }
} while ($uri -and $allDevices.Count -lt $Top)

Write-Status "Retrieved $($allDevices.Count) device(s)" -Status "OK"

if ($allDevices.Count -eq 0) {
    Write-Status "No devices matched your query." -Status "WARN"
    exit 0
}

# ─────────────────────────────────────────────
# ENRICH & DISPLAY
# ─────────────────────────────────────────────
$report = $allDevices | ForEach-Object {
    $d = $_
    $lastSync = if ($d.lastSyncDateTime) { [datetime]$d.lastSyncDateTime } else { $null }
    $daysSinceSync = if ($lastSync) { [math]::Round(([datetime]::UtcNow - $lastSync).TotalDays, 1) } else { "N/A" }

    $syncHealth = switch ($true) {
        ($daysSinceSync -eq "N/A") { "Never synced" }
        ($daysSinceSync -gt 14)    { "STALE (>14d)" }
        ($daysSinceSync -gt 3)     { "Delayed (>3d)" }
        default                    { "OK" }
    }

    [PSCustomObject]@{
        DeviceName              = $d.deviceName
        ComplianceState         = $d.complianceState
        LastSyncDateTime        = $lastSync
        DaysSinceSync           = $daysSinceSync
        SyncHealth              = $syncHealth
        OS                      = "$($d.operatingSystem) $($d.osVersion)"
        UserUPN                 = $d.userPrincipalName
        UserDisplayName         = $d.userDisplayName
        EnrollmentType          = $d.deviceEnrollmentType
        EnrollmentProfile       = $d.enrollmentProfileName
        AutopilotEnrolled       = $d.autopilotEnrolled
        AzureADRegistered       = $d.azureADRegistered
        AzureADDeviceId         = $d.azureADDeviceId
        IsEncrypted             = $d.isEncrypted
        CertExpiryDate          = $d.managementCertificateExpirationDate
        Category                = $d.deviceCategoryDisplayName
        ManagedDeviceId         = $d.id
    }
}

# ─────────────────────────────────────────────
# CONSOLE SUMMARY
# ─────────────────────────────────────────────
Write-Host "`n===== INTUNE DEVICE STATUS SUMMARY =====" -ForegroundColor Cyan
$report | Format-Table DeviceName, ComplianceState, SyncHealth, OS, UserUPN, EnrollmentType -AutoSize

# Highlight problems
$problems = $report | Where-Object {
    $_.ComplianceState -ne "compliant" -or $_.SyncHealth -notlike "OK"
}
if ($problems) {
    Write-Host "`n[!] DEVICES NEEDING ATTENTION:" -ForegroundColor Yellow
    $problems | Format-Table DeviceName, ComplianceState, SyncHealth, DaysSinceSync, UserUPN -AutoSize
}

# Cert expiry warnings
$certWarnings = $report | Where-Object {
    $_.CertExpiryDate -and ([datetime]$_.CertExpiryDate - [datetime]::UtcNow).TotalDays -lt 30
}
if ($certWarnings) {
    Write-Status "MDM cert expiring within 30 days on $($certWarnings.Count) device(s)!" -Status "WARN"
    $certWarnings | ForEach-Object { Write-Status "  $($_.DeviceName) — expires $($_.CertExpiryDate)" -Status "WARN" }
}

# ─────────────────────────────────────────────
# EXPORT
# ─────────────────────────────────────────────
$csvPath = "IntuneDeviceStatus_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
$report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Full report saved → $csvPath" -Status "OK"

# Stats
Write-Host "`n--- Stats ---" -ForegroundColor Cyan
$report | Group-Object ComplianceState | ForEach-Object {
    Write-Host "  $($_.Name.PadRight(20)) : $($_.Count)" -ForegroundColor $(
        switch ($_.Name) { "compliant"{"Green"} "noncompliant"{"Red"} default{"Yellow"} }
    )
}
Write-Host ""
