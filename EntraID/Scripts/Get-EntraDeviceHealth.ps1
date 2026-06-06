<#
.SYNOPSIS
    Queries Entra ID via Microsoft Graph and produces a device health report with flag-based analysis.

.DESCRIPTION
    Connects to Microsoft Graph and retrieves all device objects from Entra ID.
    For each device, reports:
        - Display name, join type (Hybrid / Entra Joined / Registered), compliance state
        - Approximate last sign-in date/time, operating system and version
        - Enrollment type and MDM managed status

    Analysis flags applied:
        - STALE:      No sign-in activity in more than StaleThresholdDays (default 90)
        - NO_MDM:     IsManaged = false (not enrolled in any MDM)
        - DUPLICATE:  Another device object shares the same displayName

    Output:
        - Colour-coded console summary grouped by join type
        - CSV export: full device list + separate CSVs for each flag category
        - Summary counts to console

.PARAMETER StaleThresholdDays
    Number of days without sign-in before a device is flagged as stale. Default: 90.

.PARAMETER ExportPath
    Directory path for CSV exports. Created if it does not exist.
    Default: $env:TEMP\EntraDeviceHealth-<yyyyMMdd-HHmm>

.PARAMETER TenantId
    Optional. Entra tenant ID to connect to. If omitted, Connect-MgGraph uses the
    default/cached session or prompts for interactive login.

.EXAMPLE
    .\Get-EntraDeviceHealth.ps1

    Connects interactively, reports all devices, exports to %TEMP%\EntraDeviceHealth-<date>

.EXAMPLE
    .\Get-EntraDeviceHealth.ps1 -StaleThresholdDays 60 -ExportPath "C:\Tickets\DeviceAudit"

    Flags devices with no sign-in in 60+ days, exports to specified path.

.EXAMPLE
    .\Get-EntraDeviceHealth.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -ExportPath "C:\Reports"

    Connects to a specific tenant, useful when running from a multi-tenant admin account.

.NOTES
    Prerequisites:
        Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

    Required Graph scopes:
        Device.Read.All

    Permissions:
        Global Reader, Cloud Device Administrator, or higher.
        No write operations are performed.

    Author  : EZAdmin Runbook Library
    Version : 1.0.0
    Updated : 2026-06-04
#>

#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$StaleThresholdDays = 90,

    [Parameter()]
    [string]$ExportPath = "$env:TEMP\EntraDeviceHealth-$(Get-Date -Format 'yyyyMMdd-HHmm')",

    [Parameter()]
    [string]$TenantId = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region ── Helpers ─────────────────────────────────────────────────────────────

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("OK","WARN","ERROR","INFO")]
        [string]$Status = "INFO"
    )
    $colour = switch ($Status) {
        "OK"    { "Green"  }
        "WARN"  { "Yellow" }
        "ERROR" { "Red"    }
        "INFO"  { "Cyan"   }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-JoinTypeFriendly {
    param([string]$TrustType, [bool]$IsManaged)
    switch ($TrustType) {
        "ServerAd"   { return "HybridJoined" }
        "AzureAd"    { return "EntraJoined" }
        "Workplace"  { return "EntraRegistered" }
        default      { return "Unknown" }
    }
}

function Get-StaleFlag {
    param([System.Nullable[datetime]]$LastSignIn, [int]$ThresholdDays)
    if ($null -eq $LastSignIn) { return $true }
    return ($LastSignIn -lt (Get-Date).AddDays(-$ThresholdDays))
}

#endregion

#region ── Setup ───────────────────────────────────────────────────────────────

New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null

Write-Host ""
Write-Host "=========================================" -ForegroundColor Magenta
Write-Host "  Entra Device Health Report             " -ForegroundColor Magenta
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')                 " -ForegroundColor Magenta
Write-Host "=========================================" -ForegroundColor Magenta
Write-Host ""
Write-Status "Export path: $ExportPath" "INFO"
Write-Status "Stale threshold: $StaleThresholdDays days" "INFO"
Write-Host ""

#endregion

#region ── Connect ─────────────────────────────────────────────────────────────

Write-Status "Connecting to Microsoft Graph..." "INFO"

$connectParams = @{
    Scopes = @("Device.Read.All")
    NoWelcome = $true
}
if ($TenantId) {
    $connectParams["TenantId"] = $TenantId
}

try {
    Connect-MgGraph @connectParams
    $context = Get-MgContext
    Write-Status "Connected as: $($context.Account) | Tenant: $($context.TenantId)" "OK"
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    throw
}

#endregion

#region ── Retrieve Devices ────────────────────────────────────────────────────

Write-Status "Retrieving all device objects from Entra..." "INFO"

$selectProps = @(
    "id", "displayName", "deviceId", "trustType", "isManaged", "isCompliant",
    "approximateLastSignInDateTime", "operatingSystem", "operatingSystemVersion",
    "enrollmentType", "managementType", "accountEnabled", "registrationDateTime",
    "deviceOwnership", "profileType"
)

try {
    $allDevices = Get-MgDevice -All -Property ($selectProps -join ",") -ErrorAction Stop
    Write-Status "Retrieved $($allDevices.Count) device objects" "OK"
} catch {
    Write-Status "Failed to retrieve devices: $($_.Exception.Message)" "ERROR"
    throw
}

if ($allDevices.Count -eq 0) {
    Write-Status "No devices found in tenant. Exiting." "WARN"
    Disconnect-MgGraph | Out-Null
    exit 0
}

#endregion

#region ── Process and Flag Devices ────────────────────────────────────────────

Write-Status "Analysing device objects..." "INFO"

# Build name frequency map for duplicate detection
$nameFrequency = @{}
foreach ($d in $allDevices) {
    $name = $d.DisplayName.ToLower()
    if ($nameFrequency.ContainsKey($name)) {
        $nameFrequency[$name]++
    } else {
        $nameFrequency[$name] = 1
    }
}

$deviceReport = [System.Collections.Generic.List[PSObject]]::new()
$staleDate    = (Get-Date).AddDays(-$StaleThresholdDays)

foreach ($device in $allDevices) {

    $joinType       = Get-JoinTypeFriendly -TrustType $device.TrustType -IsManaged $device.IsManaged
    $lastSignIn     = $device.ApproximateLastSignInDateTime
    $isStale        = Get-StaleFlag -LastSignIn $lastSignIn -ThresholdDays $StaleThresholdDays
    $hasDuplicate   = $nameFrequency[$device.DisplayName.ToLower()] -gt 1
    $noMdm          = (-not $device.IsManaged)

    # Compose flags string
    $flags = [System.Collections.Generic.List[string]]::new()
    if ($isStale)      { $flags.Add("STALE") }
    if ($noMdm)        { $flags.Add("NO_MDM") }
    if ($hasDuplicate) { $flags.Add("DUPLICATE") }

    $daysSinceSignIn = if ($null -ne $lastSignIn) {
        [math]::Round(((Get-Date) - $lastSignIn).TotalDays, 0)
    } else {
        $null
    }

    $deviceReport.Add([PSCustomObject]@{
        DisplayName                   = $device.DisplayName
        DeviceObjectId                = $device.Id
        DeviceId                      = $device.DeviceId
        JoinType                      = $joinType
        TrustType                     = if ($device.TrustType) { $device.TrustType } else { "" }
        OperatingSystem               = $device.OperatingSystem
        OperatingSystemVersion        = $device.OperatingSystemVersion
        IsManaged                     = $device.IsManaged
        IsCompliant                   = $device.IsCompliant
        AccountEnabled                = $device.AccountEnabled
        EnrollmentType                = if ($device.EnrollmentType) { $device.EnrollmentType } else { "" }
        ManagementType                = if ($device.ManagementType) { $device.ManagementType } else { "" }
        DeviceOwnership               = if ($device.DeviceOwnership) { $device.DeviceOwnership } else { "" }
        ProfileType                   = if ($device.ProfileType) { $device.ProfileType } else { "" }
        ApproximateLastSignInDateTime = if ($lastSignIn) { $lastSignIn.ToString("yyyy-MM-dd HH:mm:ss") } else { "Never/Unknown" }
        DaysSinceLastSignIn           = if ($null -ne $daysSinceSignIn) { $daysSinceSignIn } else { "" }
        RegistrationDateTime          = if ($device.RegistrationDateTime) { $device.RegistrationDateTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
        Flag_Stale                    = $isStale
        Flag_NoMDM                    = $noMdm
        Flag_Duplicate                = $hasDuplicate
        Flags                         = if ($flags.Count -gt 0) { $flags -join "|" } else { "" }
    })
}

#endregion

#region ── Console Output by Join Type ─────────────────────────────────────────

$joinTypes = $deviceReport | Select-Object -ExpandProperty JoinType -Unique | Sort-Object

Write-Host ""
Write-Host "=== DEVICES BY JOIN TYPE ===" -ForegroundColor Magenta

foreach ($jt in $joinTypes) {
    $group = $deviceReport | Where-Object { $_.JoinType -eq $jt }
    $staleInGroup  = ($group | Where-Object { $_.Flag_Stale }).Count
    $noMdmInGroup  = ($group | Where-Object { $_.Flag_NoMDM }).Count
    $dupesInGroup  = ($group | Where-Object { $_.Flag_Duplicate }).Count

    Write-Host ""
    Write-Host "  $jt — $($group.Count) device(s)" -ForegroundColor White

    $groupStatus = if ($staleInGroup -gt 0 -or $noMdmInGroup -gt 0 -or $dupesInGroup -gt 0) { "WARN" } else { "OK" }
    Write-Status "  Stale (>$StaleThresholdDays days): $staleInGroup | No MDM: $noMdmInGroup | Duplicates: $dupesInGroup" $groupStatus
}

#endregion

#region ── Flagged Device Detail ───────────────────────────────────────────────

$staleDevices     = $deviceReport | Where-Object { $_.Flag_Stale }
$noMdmDevices     = $deviceReport | Where-Object { $_.Flag_NoMDM }
$duplicateDevices = $deviceReport | Where-Object { $_.Flag_Duplicate }

if ($staleDevices.Count -gt 0) {
    Write-Host ""
    Write-Host "=== STALE DEVICES (no sign-in >$StaleThresholdDays days) — $($staleDevices.Count) ===" -ForegroundColor Yellow
    $staleDevices | Sort-Object DaysSinceLastSignIn -Descending |
        Select-Object DisplayName, JoinType, OperatingSystem,
            ApproximateLastSignInDateTime, DaysSinceLastSignIn, IsManaged, IsCompliant |
        Format-Table -AutoSize
}

if ($noMdmDevices.Count -gt 0) {
    Write-Host ""
    Write-Host "=== DEVICES WITHOUT MDM ENROLLMENT — $($noMdmDevices.Count) ===" -ForegroundColor Yellow
    $noMdmDevices | Sort-Object JoinType, DisplayName |
        Select-Object DisplayName, JoinType, OperatingSystem, IsManaged,
            EnrollmentType, ManagementType, AccountEnabled |
        Format-Table -AutoSize
}

if ($duplicateDevices.Count -gt 0) {
    Write-Host ""
    Write-Host "=== DUPLICATE DEVICE NAMES — $($duplicateDevices.Count) objects ===" -ForegroundColor Yellow
    $duplicateDevices | Sort-Object DisplayName, ApproximateLastSignInDateTime |
        Select-Object DisplayName, DeviceObjectId, JoinType, IsManaged,
            ApproximateLastSignInDateTime, RegistrationDateTime |
        Format-Table -AutoSize
}

#endregion

#region ── CSV Export ──────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== EXPORTING CSVs ===" -ForegroundColor Magenta

$mainCsvPath = "$ExportPath\all-devices.csv"
$deviceReport | Export-Csv -Path $mainCsvPath -NoTypeInformation -Encoding UTF8
Write-Status "All devices:        $mainCsvPath" "OK"

if ($staleDevices.Count -gt 0) {
    $staleCsvPath = "$ExportPath\flagged-stale.csv"
    $staleDevices | Export-Csv -Path $staleCsvPath -NoTypeInformation -Encoding UTF8
    Write-Status "Stale devices:      $staleCsvPath" "WARN"
}

if ($noMdmDevices.Count -gt 0) {
    $noMdmCsvPath = "$ExportPath\flagged-no-mdm.csv"
    $noMdmDevices | Export-Csv -Path $noMdmCsvPath -NoTypeInformation -Encoding UTF8
    Write-Status "No MDM devices:     $noMdmCsvPath" "WARN"
}

if ($duplicateDevices.Count -gt 0) {
    $dupesCsvPath = "$ExportPath\flagged-duplicates.csv"
    $duplicateDevices | Export-Csv -Path $dupesCsvPath -NoTypeInformation -Encoding UTF8
    Write-Status "Duplicate devices:  $dupesCsvPath" "WARN"
}

#endregion

#region ── Summary ─────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=========================================" -ForegroundColor Magenta
Write-Host "  SUMMARY                                " -ForegroundColor Magenta
Write-Host "=========================================" -ForegroundColor Magenta
Write-Status "Total devices in Entra:        $($deviceReport.Count)" "INFO"

$hybridCount    = ($deviceReport | Where-Object { $_.JoinType -eq "HybridJoined" }).Count
$entraCount     = ($deviceReport | Where-Object { $_.JoinType -eq "EntraJoined" }).Count
$regCount       = ($deviceReport | Where-Object { $_.JoinType -eq "EntraRegistered" }).Count
$unknownCount   = ($deviceReport | Where-Object { $_.JoinType -eq "Unknown" }).Count

Write-Status "  Hybrid Joined:               $hybridCount" "INFO"
Write-Status "  Entra Joined:                $entraCount" "INFO"
Write-Status "  Entra Registered:            $regCount" "INFO"
if ($unknownCount -gt 0) {
    Write-Status "  Unknown trust type:          $unknownCount" "WARN"
}

Write-Host ""
$totalFlagged = ($deviceReport | Where-Object { $_.Flags -ne "" }).Count
if ($totalFlagged -gt 0) {
    Write-Status "Flagged devices:               $totalFlagged" "WARN"
    Write-Status "  Stale (>$StaleThresholdDays days):           $($staleDevices.Count)" "WARN"
    Write-Status "  No MDM enrollment:           $($noMdmDevices.Count)" "WARN"
    Write-Status "  Duplicate names:             $($duplicateDevices.Count)" "WARN"
} else {
    Write-Status "No flagged devices — all devices are within thresholds" "OK"
}

Write-Host ""
Write-Status "Report complete. All exports in: $ExportPath" "OK"

#endregion

#region ── Disconnect ──────────────────────────────────────────────────────────

try {
    Disconnect-MgGraph | Out-Null
    Write-Status "Disconnected from Microsoft Graph" "INFO"
} catch {
    # Non-fatal — session may already be expired
}

#endregion
