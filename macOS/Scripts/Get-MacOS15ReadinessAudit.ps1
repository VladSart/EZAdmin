<#
.SYNOPSIS
    Reports macOS fleet readiness ahead of Intune's upcoming minimum-supported-version
    change to macOS 15 (Sequoia) and later, tied to Apple's macOS Golden Gate 27 release.

.DESCRIPTION
    Per Microsoft Message Center MC1403402 ("Plan for Change: Intune moving to support
    macOS 15 and higher later this year"), Intune, Company Portal, and the Intune MDM
    agent for macOS will require macOS 15+ for NEW enrollments after this change ships.
    Already-enrolled devices on macOS 14.x or below are not retroactively affected.

    This script surfaces:
    - Full macOS fleet OS-version distribution
    - Devices currently below the coming macOS 15 floor
    - Devices with no associated user principal name (candidates for the separately
      documented ADE-without-user-affinity / Direct Enrollment support nuance —
      see aka.ms/Intune/macOS/ADE-DE-support for the authoritative rule)

    This script does NOT and CANNOT:
    - Confirm the exact cutover date — no confirmed date has been published by
      Microsoft as of this writing; this is a Plan for Change, not a shipped feature.
    - Determine Apple hardware compatibility for macOS 15 — cross-reference the
      DeviceName/model output against Apple's own published compatibility list
      (https://support.apple.com/120282) separately.
    - Distinguish the exact ADE-without-affinity support nuance from the standard
      rule — it only flags devices with no user principal name as candidates for
      manual review against Microsoft's dedicated reference.
    - Trigger or schedule any OS upgrade itself — this is a read-only reporting tool.

.PARAMETER IncludeAllVersions
    Include the full OS-version distribution breakdown, not just devices below the
    macOS 15 floor. Off by default to keep default output focused on the at-risk population.

.PARAMETER ExportPath
    Full path for CSV export. Defaults to $env:TEMP\MacOS15Readiness-Audit-<date>.csv.

.EXAMPLE
    # Default: list devices below the coming macOS 15 floor
    .\Get-MacOS15ReadinessAudit.ps1

.EXAMPLE
    # Include the full fleet OS-version breakdown alongside the at-risk list
    .\Get-MacOS15ReadinessAudit.ps1 -IncludeAllVersions

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement PowerShell modules
    Permissions needed (Graph): DeviceManagementManagedDevices.Read.All
    Recommended role: Read-only (Intune Read Only Operator or equivalent custom role).
    Fully read-only — safe to run in production at any time. Intended for recurring
    (e.g. monthly) use as a fleet-readiness tracker until the change actually ships.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$IncludeAllVersions,

    [Parameter()]
    [string]$ExportPath = "$env:TEMP\MacOS15Readiness-Audit-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
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
        Write-Status "Connecting to Microsoft Graph (scope: DeviceManagementManagedDevices.Read.All)..." -Status INFO
        Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All" -NoWelcome
    }
    Write-Status "Connected as $((Get-MgContext).Account)" -Status OK
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" -Status ERROR
    exit 1
}
#endregion

#region Fetch macOS device inventory
Write-Status "Retrieving macOS managed device inventory..." -Status SECTION

try {
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'macOS'&`$top=999"
    $macDevices = @()
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri
        $macDevices += $resp.value
        $uri = $resp.'@odata.nextLink'
    } while ($uri)
}
catch {
    Write-Status "Failed to query managed devices. Confirm DeviceManagementManagedDevices.Read.All is granted and admin-consented. Error: $($_.Exception.Message)" -Status ERROR
    exit 1
}

Write-Status "Retrieved $($macDevices.Count) macOS managed device(s)." -Status INFO
#endregion

#region Version distribution
if ($IncludeAllVersions) {
    Write-Status "Full macOS version distribution:" -Status SECTION
    $macDevices | Group-Object { ($_.osVersion -split '\.')[0..1] -join '.' } |
        Sort-Object Name -Descending |
        Format-Table @{L='MajorMinorVersion';E={$_.Name}}, Count -AutoSize
}
#endregion

#region Identify devices below the macOS 15 floor
Write-Status "Identifying devices below the coming macOS 15 floor..." -Status SECTION

$belowFloor = $macDevices | Where-Object {
    try {
        [version](($_.osVersion -split '\.')[0..1] -join '.') -lt [version]"15.0"
    }
    catch {
        $false
    }
}

Write-Status "$($belowFloor.Count) of $($macDevices.Count) macOS device(s) are below macOS 15 and would be blocked from NEW enrollment once this change ships. Already-enrolled devices remain managed regardless." -Status $(if ($belowFloor.Count -gt 0) { "WARN" } else { "OK" })

$noAffinity = $belowFloor | Where-Object { -not $_.userPrincipalName }
if ($noAffinity.Count -gt 0) {
    Write-Status "$($noAffinity.Count) of those have no associated user (likely ADE-without-affinity or Direct Enrollment) — verify against aka.ms/Intune/macOS/ADE-DE-support before applying the standard remediation." -Status WARN
}
#endregion

#region Build report
$report = $belowFloor | ForEach-Object {
    [PSCustomObject]@{
        DeviceName          = $_.deviceName
        OSVersion            = $_.osVersion
        UserPrincipalName    = $_.userPrincipalName
        LikelySharedOrKiosk  = [bool](-not $_.userPrincipalName)
        ManagedDeviceOwnerType = $_.managedDeviceOwnerType
        EnrolledDateTime     = $_.enrolledDateTime
        LastSyncDateTime     = $_.lastSyncDateTime
        Model                 = $_.model
    }
}
#endregion

#region Export
Write-Status "Exporting report..." -Status SECTION
$report | Sort-Object LikelySharedOrKiosk -Descending | Format-Table DeviceName, OSVersion, UserPrincipalName, LikelySharedOrKiosk -AutoSize
$report | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Report exported to $ExportPath" -Status OK
Write-Status "Cross-reference the Model column against Apple's macOS Sequoia compatibility list (https://support.apple.com/120282) to split this population into software-upgrade-eligible vs. hardware-refresh-required." -Status INFO
Write-Status "No confirmed cutover date has been published as of this writing — treat this as a recurring readiness tracker, not a one-time check." -Status INFO
#endregion
