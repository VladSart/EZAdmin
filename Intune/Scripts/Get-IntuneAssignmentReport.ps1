<#
.SYNOPSIS
    Generates a comprehensive Intune assignment report showing all policies, apps, and
    scripts with their group targets and assignment filters.

.DESCRIPTION
    This script queries Intune via the Microsoft Graph API and exports a full assignment
    report covering:
      - Device configuration profiles
      - Compliance policies
      - App assignments (Required and Available)
      - PowerShell scripts
      - Proactive remediations (health scripts)

    For each assignment it captures:
      - Target group name (resolved from Azure AD)
      - Assignment type (Include / Exclude)
      - Filter name and filter mode (if present)
      - Object display name and ID

    Output is exported to CSV for analysis in Excel or importing into a CMDB.

    Useful for:
      - Auditing what a device or group will receive
      - Pre-change impact assessment
      - Troubleshooting "why isn't this policy applying" scenarios

.PARAMETER OutputPath
    Directory path where the CSV report will be saved.
    Defaults to C:\Temp\IntuneAssignmentReport_<timestamp>.

.PARAMETER ObjectType
    Scope the report to specific object types. Valid values:
    DeviceConfig, Compliance, Apps, Scripts, Remediations, All
    Defaults to All.

.PARAMETER GroupName
    Optional. Filter output to assignments targeting a specific Azure AD group name.

.EXAMPLE
    .\Get-IntuneAssignmentReport.ps1
    Runs a full export of all Intune assignments to C:\Temp.

.EXAMPLE
    .\Get-IntuneAssignmentReport.ps1 -ObjectType DeviceConfig,Compliance -OutputPath "D:\Reports"
    Exports only device config profiles and compliance policies to D:\Reports.

.EXAMPLE
    .\Get-IntuneAssignmentReport.ps1 -GroupName "SG-Intune-CorpDevices"
    Exports all assignments targeting the group "SG-Intune-CorpDevices".

.NOTES
    Required modules: Microsoft.Graph.DeviceManagement, Microsoft.Graph.Groups,
                      Microsoft.Graph.Applications
    Required permissions: DeviceManagementConfiguration.Read.All,
                          DeviceManagementApps.Read.All,
                          DeviceManagementManagedDevices.Read.All,
                          Group.Read.All

    Safe to run — read-only, no changes made.
#>

[CmdletBinding()]
param(
    [string]$OutputPath,

    [ValidateSet("DeviceConfig","Compliance","Apps","Scripts","Remediations","All")]
    [string[]]$ObjectType = "All",

    [string]$GroupName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region --- Helpers ---

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green"  }
        "WARN"  { "Yellow" }
        "ERROR" { "Red"    }
        default { "Cyan"   }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-GroupDisplayName {
    param([string]$GroupId, [hashtable]$Cache)
    if ([string]::IsNullOrWhiteSpace($GroupId)) { return "All Devices / All Users" }
    if ($GroupId -eq "adele_vance") { return "All Devices (built-in)" }
    if ($Cache.ContainsKey($GroupId))  { return $Cache[$GroupId] }
    try {
        $group = Get-MgGroup -GroupId $GroupId -Property DisplayName -ErrorAction Stop
        $Cache[$GroupId] = $group.DisplayName
        return $group.DisplayName
    } catch {
        $Cache[$GroupId] = "Unknown ($GroupId)"
        return $Cache[$GroupId]
    }
}

function Get-FilterDisplayName {
    param([string]$FilterId, [hashtable]$FilterCache)
    if ([string]::IsNullOrWhiteSpace($FilterId)) { return "" }
    if ($FilterCache.ContainsKey($FilterId))    { return $FilterCache[$FilterId] }
    try {
        $filter = Get-MgDeviceManagementAssignmentFilter -AssignmentFilterId $FilterId `
            -Property DisplayName -ErrorAction Stop
        $FilterCache[$FilterId] = $filter.DisplayName
        return $filter.DisplayName
    } catch {
        $FilterCache[$FilterId] = "Unknown ($FilterId)"
        return $FilterCache[$FilterId]
    }
}

function Get-AssignmentMode {
    param([string]$TargetType)
    return switch ($TargetType) {
        "#microsoft.graph.exclusionGroupAssignmentTarget" { "Exclude" }
        "#microsoft.graph.allDevicesAssignmentTarget"     { "Include (All Devices)" }
        "#microsoft.graph.allLicensedUsersAssignmentTarget" { "Include (All Users)" }
        default { "Include" }
    }
}

function ConvertTo-AssignmentRows {
    param(
        [string]$ObjectType,
        [string]$ObjectName,
        [string]$ObjectId,
        [object[]]$Assignments,
        [hashtable]$GroupCache,
        [hashtable]$FilterCache,
        [string]$FilterByGroup
    )
    $rows = @()
    foreach ($a in $Assignments) {
        $target     = $a.Target
        $groupId    = $target.AdditionalProperties.groupId
        $groupName  = Get-GroupDisplayName -GroupId $groupId -Cache $GroupCache
        $mode       = Get-AssignmentMode -TargetType $target.ODataType
        $filterId   = $target.AdditionalProperties.deviceAndAppManagementAssignmentFilterId
        $filterMode = $target.AdditionalProperties.deviceAndAppManagementAssignmentFilterType
        $filterName = Get-FilterDisplayName -FilterId $filterId -FilterCache $FilterCache

        if ($FilterByGroup -and $groupName -notlike "*$FilterByGroup*") { continue }

        $rows += [PSCustomObject]@{
            ObjectType      = $ObjectType
            ObjectName      = $ObjectName
            ObjectId        = $ObjectId
            TargetGroup     = $groupName
            TargetGroupId   = $groupId
            AssignmentMode  = $mode
            FilterName      = $filterName
            FilterMode      = $filterMode
            FilterId        = $filterId
        }
    }
    return $rows
}

#endregion

#region --- Connect ---

Write-Status "Connecting to Microsoft Graph..."
$scopes = @(
    "DeviceManagementConfiguration.Read.All",
    "DeviceManagementApps.Read.All",
    "DeviceManagementManagedDevices.Read.All",
    "Group.Read.All"
)
Connect-MgGraph -Scopes $scopes -NoWelcome
Write-Status "Connected." "OK"

#endregion

#region --- Setup ---

if (-not $OutputPath) {
    $OutputPath = "C:\Temp\IntuneAssignmentReport_$(Get-Date -Format yyyyMMdd-HHmm)"
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$groupCache  = @{}
$filterCache = @{}
$allRows     = @()
$runAll      = $ObjectType -contains "All"

#endregion

#region --- Device Configuration Profiles ---

if ($runAll -or $ObjectType -contains "DeviceConfig") {
    Write-Status "Collecting device configuration profiles..."
    $profiles = Get-MgDeviceManagementDeviceConfiguration -All
    Write-Status "  Found $($profiles.Count) profiles."

    foreach ($p in $profiles) {
        try {
            $assignments = Get-MgDeviceManagementDeviceConfigurationAssignment `
                -DeviceConfigurationId $p.Id -All
            $rows = ConvertTo-AssignmentRows -ObjectType "DeviceConfig" `
                -ObjectName $p.DisplayName -ObjectId $p.Id `
                -Assignments $assignments -GroupCache $groupCache -FilterCache $filterCache `
                -FilterByGroup $GroupName
            $allRows += $rows
        } catch {
            Write-Status "  Skipped $($p.DisplayName): $_" "WARN"
        }
    }
}

#endregion

#region --- Compliance Policies ---

if ($runAll -or $ObjectType -contains "Compliance") {
    Write-Status "Collecting compliance policies..."
    $compPolicies = Get-MgDeviceManagementDeviceCompliancePolicy -All
    Write-Status "  Found $($compPolicies.Count) compliance policies."

    foreach ($cp in $compPolicies) {
        try {
            $assignments = Get-MgDeviceManagementDeviceCompliancePolicyAssignment `
                -DeviceCompliancePolicyId $cp.Id -All
            $rows = ConvertTo-AssignmentRows -ObjectType "CompliancePolicy" `
                -ObjectName $cp.DisplayName -ObjectId $cp.Id `
                -Assignments $assignments -GroupCache $groupCache -FilterCache $filterCache `
                -FilterByGroup $GroupName
            $allRows += $rows
        } catch {
            Write-Status "  Skipped $($cp.DisplayName): $_" "WARN"
        }
    }
}

#endregion

#region --- Apps ---

if ($runAll -or $ObjectType -contains "Apps") {
    Write-Status "Collecting app assignments..."
    $apps = Get-MgDeviceAppManagementMobileApp -All |
        Where-Object { $_.AdditionalProperties.'@odata.type' -notlike "*webApp*" }
    Write-Status "  Found $($apps.Count) apps."

    foreach ($app in $apps) {
        try {
            $assignments = Get-MgDeviceAppManagementMobileAppAssignment `
                -MobileAppId $app.Id -All
            $rows = ConvertTo-AssignmentRows -ObjectType "App" `
                -ObjectName $app.DisplayName -ObjectId $app.Id `
                -Assignments $assignments -GroupCache $groupCache -FilterCache $filterCache `
                -FilterByGroup $GroupName
            $allRows += $rows
        } catch {
            Write-Status "  Skipped $($app.DisplayName): $_" "WARN"
        }
    }
}

#endregion

#region --- PowerShell Scripts ---

if ($runAll -or $ObjectType -contains "Scripts") {
    Write-Status "Collecting PowerShell scripts..."
    $scripts = Get-MgDeviceManagementScript -All
    Write-Status "  Found $($scripts.Count) scripts."

    foreach ($s in $scripts) {
        try {
            $assignments = Get-MgDeviceManagementScriptAssignment `
                -DeviceManagementScriptId $s.Id -All
            $rows = ConvertTo-AssignmentRows -ObjectType "PowerShellScript" `
                -ObjectName $s.DisplayName -ObjectId $s.Id `
                -Assignments $assignments -GroupCache $groupCache -FilterCache $filterCache `
                -FilterByGroup $GroupName
            $allRows += $rows
        } catch {
            Write-Status "  Skipped $($s.DisplayName): $_" "WARN"
        }
    }
}

#endregion

#region --- Proactive Remediations (Health Scripts) ---

if ($runAll -or $ObjectType -contains "Remediations") {
    Write-Status "Collecting proactive remediations..."
    try {
        $remediations = Get-MgDeviceManagementDeviceHealthScript -All
        Write-Status "  Found $($remediations.Count) remediations."

        foreach ($r in $remediations) {
            try {
                $assignments = Get-MgDeviceManagementDeviceHealthScriptAssignment `
                    -DeviceHealthScriptId $r.Id -All
                $rows = ConvertTo-AssignmentRows -ObjectType "Remediation" `
                    -ObjectName $r.DisplayName -ObjectId $r.Id `
                    -Assignments $assignments -GroupCache $groupCache -FilterCache $filterCache `
                    -FilterByGroup $GroupName
                $allRows += $rows
            } catch {
                Write-Status "  Skipped $($r.DisplayName): $_" "WARN"
            }
        }
    } catch {
        Write-Status "Could not collect remediations (requires Intune P2 or add-on): $_" "WARN"
    }
}

#endregion

#region --- Export ---

$csvPath = Join-Path $OutputPath "IntuneAssignmentReport.csv"
$allRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported: $csvPath" "OK"

# Summary
$summary = $allRows | Group-Object ObjectType | Sort-Object Name
Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
$summary | ForEach-Object {
    Write-Host ("  {0,-25} {1} assignments" -f $_.Name, $_.Count)
}

if ($GroupName) {
    Write-Host "`nFiltered to group: $GroupName" -ForegroundColor Yellow
    $filtered = $allRows | Where-Object { $_.TargetGroup -like "*$GroupName*" }
    Write-Host "$($filtered.Count) assignments target this group." -ForegroundColor Green
}

Write-Host ""
Write-Status "Done. Open: $csvPath" "OK"

#endregion
