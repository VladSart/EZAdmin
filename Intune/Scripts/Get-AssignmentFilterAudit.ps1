<#
.SYNOPSIS
    Audits Intune Assignment Filters and cross-references device property staleness
    and gaps that silently break filter evaluation.

.DESCRIPTION
    Companion diagnostic for Intune/Troubleshooting/Filters-B.md and Filters-A.md.

    Assignment Filter failures are almost never "the filter is wrong" — they are
    usually one of the gaps both runbooks call out:
      1. Property staleness — filters evaluate device properties as of last check-in,
         not in real time (Filters-A.md How It Works, Filters-B.md Learning Pointers).
      2. Missing device properties — `enrollmentProfileName` is blank for non-Autopilot
         devices, `deviceCategory`/`deviceOwnership` unset (Filters-A.md Fix 1/Fix 4,
         Filters-B.md Fix 2).
      3. Platform mismatch — a filter created for one platform silently returns
         `Not evaluated` when assigned to a policy for a different platform
         (Filters-B.md Fix 5).

    This script does NOT evaluate filter rule syntax against device properties (that
    logic lives only in the Intune service and the portal's "Device preview" tool —
    use that first per both runbooks' top Learning Pointer). Instead it surfaces the
    upstream data-quality issues that cause filters to silently fail before you waste
    time debugging rule syntax that was never the problem.

    Produces three CSVs:
      - AllFilters.csv            — every assignment filter in the tenant with its rule and platform
      - FilterReferencingProperty.csv — filters whose rule text references enrollmentProfileName,
                                    category, or ownership (the three highest-risk properties)
      - DeviceGapReport.csv       — devices with STALE_CHECKIN (>StaleHours since last sync),
                                    NO_ENROLLMENT_PROFILE, or NO_CATEGORY flags

.PARAMETER StaleHours
    Hours since LastSyncDateTime before a device is flagged STALE_CHECKIN, meaning any
    recent property change (OS update, category assignment) may not yet be reflected in
    filter evaluation. Default: 9 (slightly above the ~8h default check-in interval).

.PARAMETER OutputPath
    Folder to write CSV reports to. Default: current directory.

.EXAMPLE
    .\Get-AssignmentFilterAudit.ps1
    Runs a full tenant-wide filter and device-gap audit with default staleness threshold.

.EXAMPLE
    .\Get-AssignmentFilterAudit.ps1 -StaleHours 12 -OutputPath C:\Temp\FilterAudit
    Widens the staleness window and writes reports to a specific folder.

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement
    Scopes:   DeviceManagementConfiguration.Read.All, DeviceManagementManagedDevices.Read.All
    Safe/Unsafe: Fully read-only. Makes no changes to filters, policies, or devices.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [int]$StaleHours = 9,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight — connect
# ---------------------------------------------------------------------------
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Not connected. Connecting with required scopes..." "WARN"
        Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All", "DeviceManagementManagedDevices.Read.All" -NoWelcome
    }
    else {
        Write-Status "Connected as $($context.Account)" "OK"
    }
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    throw
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# ---------------------------------------------------------------------------
# 1. All assignment filters in the tenant
# ---------------------------------------------------------------------------
Write-Status "Pulling all assignment filters..." "INFO"
try {
    $filters = Get-MgBetaDeviceManagementAssignmentFilter -All |
        Select-Object DisplayName, Platform, Rule, AssignmentFilterManagementType, Id
}
catch {
    Write-Status "Failed to retrieve assignment filters: $($_.Exception.Message)" "ERROR"
    throw
}

$filtersFile = Join-Path $OutputPath "AllFilters-$timestamp.csv"
$filters | Export-Csv -Path $filtersFile -NoTypeInformation
Write-Status "Found $($filters.Count) filter(s). Exported to $filtersFile" "OK"

# ---------------------------------------------------------------------------
# 2. Flag filters that reference the three highest-risk properties
# ---------------------------------------------------------------------------
$riskyProps = @("enrollmentProfileName", "category", "deviceOwnership", "deviceCategory")
$riskyFilters = $filters | Where-Object {
    $rule = $_.Rule
    $riskyProps | Where-Object { $rule -match $_ }
} | ForEach-Object {
    $matchedProps = ($riskyProps | Where-Object { $_.Rule -match $_ }) -join ", "
    [PSCustomObject]@{
        DisplayName    = $_.DisplayName
        Platform       = $_.Platform
        Rule           = $_.Rule
        RiskyProperties = $matchedProps
    }
}
$riskyFile = Join-Path $OutputPath "FilterReferencingProperty-$timestamp.csv"
$riskyFilters | Export-Csv -Path $riskyFile -NoTypeInformation
Write-Status "$($riskyFilters.Count) filter(s) reference enrollmentProfileName/category/ownership — these are the properties most likely to be blank or stale. Exported to $riskyFile" $(if ($riskyFilters.Count -gt 0) { "WARN" } else { "OK" })

# ---------------------------------------------------------------------------
# 3. Device-level gap report — staleness, missing enrollment profile, missing category
# ---------------------------------------------------------------------------
Write-Status "Pulling managed devices for gap analysis (this may take a moment on large fleets)..." "INFO"
try {
    $devices = Get-MgDeviceManagementManagedDevice -All -Property "deviceName,osVersion,manufacturer,model,enrollmentProfileName,deviceCategoryDisplayName,managementType,lastSyncDateTime,operatingSystem"
}
catch {
    Write-Status "Failed to retrieve managed devices: $($_.Exception.Message)" "ERROR"
    throw
}

$staleThreshold = (Get-Date).AddHours(-$StaleHours)
$gapReport = $devices | ForEach-Object {
    $flags = New-Object System.Collections.Generic.List[string]

    if ($_.LastSyncDateTime -and $_.LastSyncDateTime -lt $staleThreshold) { $flags.Add("STALE_CHECKIN") }
    if ([string]::IsNullOrWhiteSpace($_.EnrollmentProfileName)) { $flags.Add("NO_ENROLLMENT_PROFILE") }
    if ([string]::IsNullOrWhiteSpace($_.DeviceCategoryDisplayName) -or $_.DeviceCategoryDisplayName -eq "Unknown") { $flags.Add("NO_CATEGORY") }

    if ($flags.Count -gt 0) {
        [PSCustomObject]@{
            DeviceName            = $_.DeviceName
            OperatingSystem       = $_.OperatingSystem
            OSVersion             = $_.OsVersion
            EnrollmentProfileName = $_.EnrollmentProfileName
            DeviceCategory        = $_.DeviceCategoryDisplayName
            LastSyncDateTime      = $_.LastSyncDateTime
            Flags                 = ($flags -join "; ")
        }
    }
}

$gapFile = Join-Path $OutputPath "DeviceGapReport-$timestamp.csv"
$gapReport | Export-Csv -Path $gapFile -NoTypeInformation

Write-Host ""
Write-Status "Total devices scanned:     $($devices.Count)" "INFO"
Write-Status "STALE_CHECKIN (>${StaleHours}h):     $(@($gapReport | Where-Object { $_.Flags -match 'STALE_CHECKIN' }).Count)" "WARN"
Write-Status "NO_ENROLLMENT_PROFILE:     $(@($gapReport | Where-Object { $_.Flags -match 'NO_ENROLLMENT_PROFILE' }).Count)" "INFO"
Write-Status "NO_CATEGORY:               $(@($gapReport | Where-Object { $_.Flags -match 'NO_CATEGORY' }).Count)" "INFO"
Write-Host ""
Write-Status "Device gap report exported to: $gapFile" "OK"
Write-Status "NOTE: NO_ENROLLMENT_PROFILE is expected/normal for non-Autopilot devices — only investigate if a filter rule specifically targets enrollmentProfileName for that device's population (per Filters-A.md Fix 1)." "INFO"
Write-Status "Next step for any specific device still not matching a filter: use the portal 'Device preview' tool under Tenant admin > Filters > [filter] — it is faster than any script for rule-level diagnosis." "INFO"
