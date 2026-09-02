<#
.SYNOPSIS
    Audits same-day Intune device-action volume and BitLocker escrow readiness ahead of
    or during a large Wipe/Retire/Delete batch, to help avoid the documented daily
    tenant-wide quotas (500 Wipe/day, 1,000 Retire/day, 1,000 Delete/day).

.DESCRIPTION
    Microsoft Intune enforces tenant-wide daily submission caps per action type, shared
    across the admin center UI, bulk actions, and the Graph API. There is no supported
    API that reports "quota remaining" directly, so this script reconstructs a best-effort
    same-day picture from the available device action report and flags devices most
    likely to trip the Delete-to-Wipe cascade (corporate-owned Android), plus BitLocker
    escrow state for Entra-joined devices that would be affected by the Delete/Retire
    key-protector-removal safeguard.

    This script does NOT and CANNOT:
    - Read an authoritative "quota remaining" figure — no such API exists as of this
      writing. The device action report is the closest available proxy and may not
      capture every submission surface with full fidelity.
    - Issue Wipe, Retire, or Delete actions itself. This is a read-only planning/audit
      tool by design, to avoid an audit script ever contributing to the quota it's
      trying to help you avoid exhausting.
    - Determine whether Multiple Administrative Approval (MAA) is configured for these
      action types — that is a portal-only access-policy setting with no documented
      Graph read surface as of this writing.

.PARAMETER PlatformFilter
    Restrict the device inventory to a specific OS platform (e.g. "Android", "Windows",
    "macOS", "iOS"). Default: all platforms.

.PARAMETER FlagCorporateAndroidOnly
    Return only corporate-owned Android devices (COBO/COSU/COPE/AOSP) — the population
    most likely to trip the Delete-to-Wipe quota cascade described in
    DeviceActionQuotas-A.md.

.PARAMETER CheckBitLockerEscrow
    For Entra-joined Windows devices in scope, also check whether a BitLocker recovery
    key is currently escrowed. Adds one Graph call per matching device — slower on
    large fleets, so it's opt-in rather than default.

.PARAMETER ExportPath
    Full path for CSV export. Defaults to $env:TEMP\DeviceActionQuota-Audit-<date>.csv.

.EXAMPLE
    # Full-fleet planning pass before a large decommissioning project
    .\Get-DeviceActionQuotaAudit.ps1

.EXAMPLE
    # Identify corporate-owned Android devices that would cascade Delete into Wipe
    .\Get-DeviceActionQuotaAudit.ps1 -FlagCorporateAndroidOnly

.EXAMPLE
    # Check BitLocker escrow readiness for Windows devices before a Retire batch
    .\Get-DeviceActionQuotaAudit.ps1 -PlatformFilter Windows -CheckBitLockerEscrow

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement PowerShell modules
    Permissions needed (Graph): DeviceManagementManagedDevices.Read.All;
      BitLockerKey.Read.All also required if -CheckBitLockerEscrow is used.
    Recommended role: Read-only (Intune Read Only Operator or equivalent custom role).
    Fully read-only — safe to run in production at any time, including mid-batch.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$PlatformFilter,

    [Parameter()]
    [switch]$FlagCorporateAndroidOnly,

    [Parameter()]
    [switch]$CheckBitLockerEscrow,

    [Parameter()]
    [string]$ExportPath = "$env:TEMP\DeviceActionQuota-Audit-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("INFO", "OK", "WARN", "ERROR", "SECTION")]
        [string]$Status = "INFO"
    )
    $colour = switch ($Status) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SECTION" { "Cyan" }
        default   { "White" }
    }
    $prefix = if ($Status -eq "SECTION") { "`n====" } else { "[$Status]" }
    Write-Host "$prefix $Message" -ForegroundColor $colour
}

#region Prerequisites
Write-Status "Checking prerequisites..." -Status SECTION

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Status "Microsoft.Graph.Authentication module not found. Install with: Install-Module Microsoft.Graph.Authentication" -Status ERROR
    exit 1
}

try {
    $ctx = Get-MgContext
    if (-not $ctx) {
        $scopes = @("DeviceManagementManagedDevices.Read.All")
        if ($CheckBitLockerEscrow) { $scopes += "BitLockerKey.Read.All" }
        Write-Status "Connecting to Microsoft Graph (scopes: $($scopes -join ', '))..." -Status INFO
        Connect-MgGraph -Scopes $scopes -NoWelcome
    }
    Write-Status "Connected as $((Get-MgContext).Account)" -Status OK
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" -Status ERROR
    exit 1
}
#endregion

#region Same-day device action report (best-effort quota proxy)
Write-Status "Pulling device action report (best-effort same-day quota proxy — no authoritative quota-remaining API exists)..." -Status SECTION

try {
    $actionReport = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/getDeviceActionReport" -Body (@{} | ConvertTo-Json)
    Write-Status "Device action report retrieved. Review manually against today's UTC date for Wipe/Retire/Delete volume — this script does not parse the report body, since its schema is subject to change." -Status OK
}
catch {
    Write-Status "Could not pull device action report: $($_.Exception.Message). Continuing with device inventory only." -Status WARN
    $actionReport = $null
}
#endregion

#region Device inventory
Write-Status "Retrieving managed device inventory..." -Status SECTION

try {
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$top=999"
    $devices = @()
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri
        $devices += $resp.value
        $uri = $resp.'@odata.nextLink'
    } while ($uri)
}
catch {
    Write-Status "Failed to query managed devices. Confirm DeviceManagementManagedDevices.Read.All is granted and admin-consented. Error: $($_.Exception.Message)" -Status ERROR
    exit 1
}

if ($PlatformFilter) {
    $devices = $devices | Where-Object { $_.operatingSystem -like "*$PlatformFilter*" }
}

Write-Status "Retrieved $($devices.Count) managed device(s) matching filters." -Status INFO
#endregion

#region Flag Delete-to-Wipe cascade candidates
Write-Status "Identifying Delete-to-Wipe cascade candidates (corporate-owned Android)..." -Status SECTION

$corporateAndroid = $devices | Where-Object {
    $_.operatingSystem -eq "Android" -and $_.managedDeviceOwnerType -eq "company"
}
Write-Status "$($corporateAndroid.Count) corporate-owned Android device(s) found. A Delete action against these ALSO consumes the 500/day Wipe quota, not just the 1,000/day Delete quota." -Status $(if ($corporateAndroid.Count -gt 0) { "WARN" } else { "OK" })

if ($FlagCorporateAndroidOnly) {
    $devices = $corporateAndroid
}
#endregion

#region Optional BitLocker escrow check
$bitlockerMap = @{}
if ($CheckBitLockerEscrow) {
    Write-Status "Checking BitLocker recovery key escrow for Entra-joined Windows devices in scope..." -Status SECTION
    $windowsDevices = $devices | Where-Object { $_.operatingSystem -eq "Windows" -and $_.azureADDeviceId }

    foreach ($d in $windowsDevices) {
        try {
            $keyUri = "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys?`$filter=deviceId eq '$($d.azureADDeviceId)'"
            $keys = (Invoke-MgGraphRequest -Method GET -Uri $keyUri).value
            $bitlockerMap[$d.id] = if ($keys -and $keys.Count -gt 0) { "Escrowed" } else { "NOT ESCROWED" }
        }
        catch {
            $bitlockerMap[$d.id] = "Check failed"
        }
    }
    $notEscrowed = ($bitlockerMap.Values | Where-Object { $_ -eq "NOT ESCROWED" }).Count
    if ($notEscrowed -gt 0) {
        Write-Status "$notEscrowed Entra-joined Windows device(s) have NO escrowed BitLocker key. Deleting or Retiring these without capturing a key first risks unrecoverable data." -Status WARN
    }
}
#endregion

#region Build report
Write-Status "Building report..." -Status SECTION

$report = foreach ($d in $devices) {
    $isCorporateAndroidCascade = ($d.operatingSystem -eq "Android" -and $d.managedDeviceOwnerType -eq "company")
    $deleteUnderlyingAction = if ($isCorporateAndroidCascade) { "Wipe" } elseif ($d.operatingSystem -eq "Android") { "Retire" } else { "Retire" }

    [PSCustomObject]@{
        DeviceName              = $d.deviceName
        DeviceId                = $d.id
        OperatingSystem         = $d.operatingSystem
        OwnerType                = $d.managedDeviceOwnerType
        DeleteCascadesTo         = $deleteUnderlyingAction
        CorporateAndroidCascade  = $isCorporateAndroidCascade
        AzureADDeviceId          = $d.azureADDeviceId
        BitLockerEscrowState     = if ($CheckBitLockerEscrow -and $bitlockerMap.ContainsKey($d.id)) { $bitlockerMap[$d.id] } else { "Not checked" }
        LastSyncDateTime         = $d.lastSyncDateTime
    }
}
#endregion

#region Export
Write-Status "Exporting report..." -Status SECTION
$report | Sort-Object CorporateAndroidCascade -Descending | Format-Table DeviceName, OperatingSystem, OwnerType, DeleteCascadesTo, BitLockerEscrowState -AutoSize
$report | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Report exported to $ExportPath" -Status OK

Write-Status "Reminder: no API reports quota remaining. Cross-reference this device count against today's UTC device action report totals before running a large batch." -Status INFO
if ($corporateAndroid.Count -gt 0) {
    Write-Status "$($corporateAndroid.Count) device(s) in scope will cascade Delete into Wipe. Model both the Delete (1,000/day) and Wipe (500/day) pools before batching these." -Status WARN
}
#endregion
