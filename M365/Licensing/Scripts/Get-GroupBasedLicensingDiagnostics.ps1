<#
.SYNOPSIS
    Diagnoses Entra ID Group-Based Licensing (GBL) configuration and per-user error states.

.DESCRIPTION
    Get-LicenseReport.ps1 already covers tenant-wide SKU inventory and a general GBL-error
    summary, but has no dedicated logic for GBL's specific processing engine behaviour. This
    script automates the Validation Steps and Symptom -> Cause Map from Group-Based-Licensing-A.md
    for a targeted group-by-group diagnostic pass.

    Covers:
    - Enumerates every group with at least one assigned licence (GBL-enabled groups) and its
      licenseProcessingState
    - Per-member checks for the five documented GBL error states: MutuallyExclusiveViolation,
      CountViolation, ProhibitedInUsageLocationViolation, UniquenessViolation, DependencyViolation
      (flags each by name, matching Group-Based-Licensing-A.md's error taxonomy exactly)
    - USAGE_LOCATION_MISSING — flags members with a blank usageLocation, the single most common
      GBL root cause per the runbook's Symptom -> Cause Map, and notes that setting it does NOT
      retroactively fix an existing error state (member must be removed/re-added or the error
      persists until the next re-evaluation cycle)
    - NESTED_GROUP_NOT_FLAT — flags GBL groups whose membership includes other groups (static
      nesting), since GBL does not process nested static groups transitively; only dynamic groups
      that resolve to a flat list are exempt from this limitation
    - SKU_COUNT_VIOLATION_RISK — cross-references each group's assigned SKU against tenant-wide
      available seat count, flagging groups whose member count could exhaust or has exhausted the
      pool (the CountViolation root cause)
    - DIRECT_AND_GROUP_DUPLICATE — informational flag for users carrying both a direct and a
      group-inherited assignment for the same SKU, per the runbook's License Inheritance section
      (not an error, but explains "removed from group, still has licence" tickets)

    Does NOT cover:
    - Classic per-user license assignment outside of GBL (see Get-LicenseReport.ps1)
    - Dynamic group membership rule syntax validation (see EntraID/Troubleshooting/DynamicGroups-A.md)
    - Service-plan-level disabled-plan inheritance detail (see License-Assignment-A.md)

.PARAMETER GroupId
    Optional. Limit the audit to a single group (Object ID). Default: all GBL-enabled groups.

.PARAMETER SkuNearExhaustionPercent
    Percentage of a SKU's total seats consumed before flagging SKU_COUNT_VIOLATION_RISK for
    groups drawing on it. Default: 95.

.PARAMETER OutputPath
    Path to the folder where CSV files will be exported. Default: current directory.

.EXAMPLE
    .\Get-GroupBasedLicensingDiagnostics.ps1

.EXAMPLE
    .\Get-GroupBasedLicensingDiagnostics.ps1 -GroupId "3f1b2c4d-...." -OutputPath C:\Temp\GBL

.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement
    Permissions: User.Read.All, Group.Read.All, Organization.Read.All
    Run as: License Administrator, User Administrator, or Global Reader

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No changes made to group membership, licences, or user attributes.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$GroupId,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$SkuNearExhaustionPercent = 95,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path
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

function Get-GBLGroups {
    param([string]$SingleGroupId)

    Write-Status "Retrieving group-based licensing groups..." "INFO"
    try {
        if ($SingleGroupId) {
            $groups = @(Get-MgGroup -GroupId $SingleGroupId -Property Id, DisplayName, AssignedLicenses, GroupTypes, LicenseProcessingState -ErrorAction Stop)
        } else {
            $all = Get-MgGroup -All -Property Id, DisplayName, AssignedLicenses, GroupTypes, LicenseProcessingState -ErrorAction Stop
            $groups = $all | Where-Object { $_.AssignedLicenses -and $_.AssignedLicenses.Count -gt 0 }
        }
        Write-Status "Found $($groups.Count) group(s) with an assigned licence" "OK"
        return $groups
    }
    catch {
        Write-Status "Failed to retrieve groups: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

function Get-SkuAvailability {
    Write-Status "Retrieving tenant SKU inventory..." "INFO"
    try {
        $skus = Get-MgSubscribedSku -All -ErrorAction Stop
        Write-Status "Found $($skus.Count) SKU(s) in tenant" "OK"
        return $skus
    }
    catch {
        Write-Status "Failed to retrieve SKU inventory: $($_.Exception.Message)" "WARN"
        return @()
    }
}

function Get-GroupMembersFlat {
    param([string]$GroupId)

    try {
        $members = Get-MgGroupMember -GroupId $GroupId -All -ErrorAction Stop
        return $members
    }
    catch {
        Write-Status "  Failed to retrieve members for group $($GroupId): $($_.Exception.Message)" "WARN"
        return @()
    }
}

function Test-GroupDiagnostics {
    param(
        [object]$Group,
        [object[]]$Skus,
        [int]$NearExhaustionPercent
    )

    $result = [PSCustomObject]@{
        GroupId                    = $Group.Id
        GroupName                  = $Group.DisplayName
        IsDynamic                  = ($Group.GroupTypes -contains "DynamicMembership")
        ProcessingState            = $Group.LicenseProcessingState.State
        MemberCount                = 0
        NestedGroupCount           = 0
        UsageLocationMissingCount  = 0
        ErrorStateCount            = 0
        Flags                      = @()
    }

    Write-Status "Auditing group: $($Group.DisplayName)" "INFO"

    if ($Group.LicenseProcessingState.State -eq "ProcessingInProgress") {
        Write-Status "  Note: licence processing currently IN PROGRESS for this group — some results below may reflect a mid-flight state" "WARN"
    }

    $members = Get-GroupMembersFlat -GroupId $Group.Id
    $result.MemberCount = @($members).Count

    # NESTED_GROUP_NOT_FLAT check
    $nestedGroups = $members | Where-Object { $_.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.group" }
    $result.NestedGroupCount = @($nestedGroups).Count
    if ($result.NestedGroupCount -gt 0 -and -not $result.IsDynamic) {
        Write-Status "  NESTED_GROUP_NOT_FLAT: $($result.NestedGroupCount) nested group(s) found in a static group — members of those child groups do NOT inherit this licence" "WARN"
        $result.Flags += "NESTED_GROUP_NOT_FLAT"
    }

    $userMembers = $members | Where-Object { $_.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.user" }

    $usageLocationMissing = @()
    $errorStates          = @()
    $duplicateAssignments = @()

    foreach ($m in $userMembers) {
        try {
            $user = Get-MgUser -UserId $m.Id -Property Id, DisplayName, UserPrincipalName, UsageLocation, LicenseAssignmentStates -ErrorAction Stop
        }
        catch {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($user.UsageLocation)) {
            $usageLocationMissing += [PSCustomObject]@{
                GroupName = $Group.DisplayName
                UPN       = $user.UserPrincipalName
                Issue     = "USAGE_LOCATION_MISSING"
            }
        }

        foreach ($state in @($user.LicenseAssignmentStates)) {
            if ($state.State -eq "Error" -and $state.AssignedByGroup -eq $Group.Id) {
                $errorTag = switch -Regex ($state.Error) {
                    "MutuallyExclusiveViolation"          { "MutuallyExclusiveViolation" }
                    "CountViolation"                       { "CountViolation" }
                    "ProhibitedInUsageLocationViolation"   { "ProhibitedInUsageLocationViolation" }
                    "UniquenessViolation"                  { "UniquenessViolation" }
                    "DependencyViolation"                  { "DependencyViolation" }
                    default                                 { $state.Error }
                }
                $errorStates += [PSCustomObject]@{
                    GroupName = $Group.DisplayName
                    UPN       = $user.UserPrincipalName
                    SkuId     = $state.SkuId
                    ErrorType = $errorTag
                }
            }
            elseif ($state.State -eq "Active" -and -not $state.AssignedByGroup) {
                # direct assignment present — check if this SKU is also assigned by THIS group
                $alsoByGroup = @($user.LicenseAssignmentStates) | Where-Object {
                    $_.SkuId -eq $state.SkuId -and $_.AssignedByGroup -eq $Group.Id
                }
                if ($alsoByGroup) {
                    $duplicateAssignments += [PSCustomObject]@{
                        GroupName = $Group.DisplayName
                        UPN       = $user.UserPrincipalName
                        SkuId     = $state.SkuId
                        Note      = "DIRECT_AND_GROUP_DUPLICATE"
                    }
                }
            }
        }
    }

    $result.UsageLocationMissingCount = @($usageLocationMissing).Count
    $result.ErrorStateCount           = @($errorStates).Count

    if ($result.UsageLocationMissingCount -gt 0) {
        Write-Status "  USAGE_LOCATION_MISSING: $($result.UsageLocationMissingCount) member(s) missing usageLocation — #1 documented GBL root cause" "WARN"
        $result.Flags += "USAGE_LOCATION_MISSING"
    }
    if ($result.ErrorStateCount -gt 0) {
        Write-Status "  LICENSE_ERROR_STATE: $($result.ErrorStateCount) member(s) in an error state for this group's licence" "ERROR"
        $result.Flags += "LICENSE_ERROR_STATE"
    }
    if (@($duplicateAssignments).Count -gt 0) {
        Write-Status "  DIRECT_AND_GROUP_DUPLICATE: $(@($duplicateAssignments).Count) member(s) have both a direct and group-inherited assignment for the same SKU (informational)" "INFO"
    }

    # SKU_COUNT_VIOLATION_RISK check
    foreach ($lic in $Group.AssignedLicenses) {
        $sku = $Skus | Where-Object { $_.SkuId -eq $lic.SkuId }
        if ($sku) {
            $consumedPct = if ($sku.PrepaidUnits.Enabled -gt 0) {
                [math]::Round(($sku.ConsumedUnits / $sku.PrepaidUnits.Enabled) * 100, 1)
            } else { 0 }
            if ($consumedPct -ge $NearExhaustionPercent) {
                Write-Status "  SKU_COUNT_VIOLATION_RISK: SKU $($sku.SkuPartNumber) is at $consumedPct% consumption — new group members may hit CountViolation" "WARN"
                $result.Flags += "SKU_COUNT_VIOLATION_RISK:$($sku.SkuPartNumber)"
            }
        }
    }

    return [PSCustomObject]@{
        Summary              = $result
        UsageLocationMissing = $usageLocationMissing
        ErrorStates          = $errorStates
        DuplicateAssignments = $duplicateAssignments
    }
}

function Write-SummaryReport {
    param([object[]]$GroupResults)

    $separator = "=" * 60
    Write-Host ""
    Write-Host $separator -ForegroundColor Cyan
    Write-Host "  GROUP-BASED LICENSING — DIAGNOSTIC REPORT" -ForegroundColor Cyan
    Write-Host "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
    Write-Host $separator -ForegroundColor Cyan
    Write-Host ""

    $GroupResults | ForEach-Object { $_.Summary } |
        Select-Object GroupName, IsDynamic, ProcessingState, MemberCount, NestedGroupCount, UsageLocationMissingCount, ErrorStateCount |
        Format-Table -AutoSize

    $totalErrors = ($GroupResults | ForEach-Object { $_.Summary.ErrorStateCount } | Measure-Object -Sum).Sum
    $totalMissing = ($GroupResults | ForEach-Object { $_.Summary.UsageLocationMissingCount } | Measure-Object -Sum).Sum
    Write-Host ""
    Write-Host "Tenant-wide totals: $totalErrors user(s) in a licence error state, $totalMissing user(s) missing usageLocation" -ForegroundColor $(if ($totalErrors -gt 0) { "Red" } elseif ($totalMissing -gt 0) { "Yellow" } else { "Green" })
}

# ==========================================
# MAIN SCRIPT
# ==========================================

Write-Status "Starting Group-Based Licensing diagnostics..." "INFO"

foreach ($mod in @("Microsoft.Graph.Authentication", "Microsoft.Graph.Users", "Microsoft.Graph.Groups", "Microsoft.Graph.Identity.DirectoryManagement")) {
    if (-not (Get-Module -Name $mod -ListAvailable)) {
        Write-Status "$mod module not found. Install with: Install-Module $mod" "ERROR"
        exit 1
    }
}

if (-not (Test-Path -Path $OutputPath)) {
    Write-Status "Output path does not exist: $OutputPath — creating..." "WARN"
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Status "Connecting to Microsoft Graph..." "INFO"
try {
    Connect-MgGraph -Scopes "User.Read.All", "Group.Read.All", "Organization.Read.All" -ErrorAction Stop -NoWelcome
    Write-Status "Connected to Microsoft Graph" "OK"
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    exit 1
}

$skus   = Get-SkuAvailability
$groups = Get-GBLGroups -SingleGroupId $GroupId

if ($groups.Count -eq 0) {
    Write-Status "No group-based licensing groups found — nothing to audit." "WARN"
    exit 0
}

$groupResults = foreach ($g in $groups) {
    Test-GroupDiagnostics -Group $g -Skus $skus -NearExhaustionPercent $SkuNearExhaustionPercent
}

Write-SummaryReport -GroupResults $groupResults

# Exports
$stamp = Get-Date -Format 'yyyyMMdd'

$summaryFile = Join-Path $OutputPath "GBL-GroupSummary-$stamp.csv"
$groupResults | ForEach-Object { $_.Summary } | Select-Object GroupName, GroupId, IsDynamic, ProcessingState, MemberCount, NestedGroupCount, UsageLocationMissingCount, ErrorStateCount, @{N="Flags";E={$_.Flags -join ";"}} |
    Export-Csv -Path $summaryFile -NoTypeInformation -Encoding UTF8
Write-Status "Group summary exported to: $summaryFile" "OK"

$missingList = $groupResults | ForEach-Object { $_.UsageLocationMissing } | Where-Object { $_ }
if (@($missingList).Count -gt 0) {
    $f = Join-Path $OutputPath "GBL-UsageLocationMissing-$stamp.csv"
    $missingList | Export-Csv -Path $f -NoTypeInformation -Encoding UTF8
    Write-Status "Usage location gap list exported to: $f" "OK"
}

$errorList = $groupResults | ForEach-Object { $_.ErrorStates } | Where-Object { $_ }
if (@($errorList).Count -gt 0) {
    $f = Join-Path $OutputPath "GBL-ErrorStates-$stamp.csv"
    $errorList | Export-Csv -Path $f -NoTypeInformation -Encoding UTF8
    Write-Status "Licence error state list exported to: $f" "OK"
}

$dupList = $groupResults | ForEach-Object { $_.DuplicateAssignments } | Where-Object { $_ }
if (@($dupList).Count -gt 0) {
    $f = Join-Path $OutputPath "GBL-DuplicateAssignments-$stamp.csv"
    $dupList | Export-Csv -Path $f -NoTypeInformation -Encoding UTF8
    Write-Status "Direct+group duplicate assignment list exported to: $f" "OK"
}

Write-Status "Group-Based Licensing diagnostics complete. Files written to: $OutputPath" "OK"
