<#
.SYNOPSIS
    Audits Microsoft Sentinel hunting-workflow health: bookmark activity, Hunts/data-lake RBAC readiness,
    and KQL-job (livestream-replacement) permission prerequisites.

.DESCRIPTION
    Read-only audit script covering the three surfaces documented in Hunting-A.md / Hunting-B.md:
      1. HuntingBookmark table activity and soft-delete ratio over a lookback window (via
         Invoke-AzOperationalInsightsQuery) — flags workspaces with zero recent bookmark activity,
         which is either a genuine "hunting isn't used here" finding or a sign that analysts are
         working exclusively in the Defender portal where bookmark CREATION silently fails (see
         Hunting-B.md Fix 1).
      2. RBAC assignments relevant to the Hunts (Preview) feature (Microsoft Sentinel Contributor or
         any role scoped to Microsoft.SecurityInsights/hunts) on the target workspace.
      3. Whether the Sentinel data lake's managed identity (msg-resources-<guid>) holds Log Analytics
         Contributor on the resource group — the prerequisite for KQL jobs (the retired livestream's
         replacement) to write to new analytics-tier tables.

    This script deliberately does NOT and CANNOT read:
      - Hunting query definitions or their MITRE ATT&CK tag coverage (Queries tab — portal/API only,
        no public Az PowerShell cmdlet surface for hunting query objects).
      - Hunt (Preview) metadata — name, hypothesis state, status, or its cloned query set (portal/API
        only, no Az PowerShell cmdlet as of this writing).
      - KQL job definitions, schedules, or run history (Data lake exploration > Jobs — portal/API
        only). This script only checks the PERMISSION prerequisite for job creation, not whether any
        jobs actually exist or are healthy.
      - Whether the tenant has completed Sentinel data lake onboarding at all — a missing managed
        identity role assignment is reported the same way whether onboarding never happened or
        onboarding happened but the role grant step was missed; both require manual follow-up.
    These gaps are reported explicitly in the script's console output and CSV rather than silently
    omitted, consistent with this repo's standing practice for scripts that can't fully automate a
    topic's diagnostic surface.

.PARAMETER SubscriptionId
    Azure subscription ID containing the target Sentinel-enabled workspace.

.PARAMETER WorkspaceResourceGroup
    Resource group containing the Log Analytics workspace.

.PARAMETER WorkspaceName
    Name of the Log Analytics workspace with Microsoft Sentinel enabled.

.PARAMETER LookbackDays
    Number of days to look back for HuntingBookmark activity. Default 30.

.PARAMETER OutputPath
    Folder to write the CSV report to. Default is the current directory.

.EXAMPLE
    .\Get-SentinelHuntingAudit.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -WorkspaceResourceGroup "rg-security" -WorkspaceName "law-client-sentinel"

.EXAMPLE
    .\Get-SentinelHuntingAudit.ps1 -SubscriptionId $sub -WorkspaceResourceGroup "rg-sec" `
        -WorkspaceName "law-sentinel" -LookbackDays 90 -OutputPath "C:\Reports"

.NOTES
    Requires: Az.Accounts, Az.OperationalInsights, Az.Resources modules; Connect-AzAccount first.
    Run-as: any account with at least Log Analytics Reader on the workspace and Reader on the
    resource group is sufficient — this script makes no changes.
    Safe: fully read-only. No configuration is modified, no roles are granted.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$WorkspaceResourceGroup,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

    [Parameter()]
    [int]$LookbackDays = 30,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting Sentinel hunting-workflow audit for workspace '$WorkspaceName'..."

foreach ($module in @("Az.Accounts", "Az.OperationalInsights", "Az.Resources")) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Status "Required module '$module' not found. Install with: Install-Module $module -Scope CurrentUser" "ERROR"
        throw "Missing required module: $module"
    }
}

$context = Get-AzContext
if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
    Write-Status "Setting Az context to subscription $SubscriptionId..."
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$report = [System.Collections.Generic.List[pscustomobject]]::new()

# ---------------------------------------------------------------------------
# Detect — resolve the workspace
# ---------------------------------------------------------------------------
try {
    $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $WorkspaceResourceGroup -Name $WorkspaceName
    Write-Status "Resolved workspace '$($workspace.Name)' (CustomerId: $($workspace.CustomerId))" "OK"
}
catch {
    Write-Status "Failed to resolve workspace: $($_.Exception.Message)" "ERROR"
    throw
}

# ---------------------------------------------------------------------------
# Execute — Section 1: HuntingBookmark activity
# ---------------------------------------------------------------------------
Write-Status "Querying HuntingBookmark table activity (last $LookbackDays days)..."

$bookmarkQuery = @"
HuntingBookmark
| where TimeGenerated > ago(${LookbackDays}d)
| summarize arg_max(TimeGenerated, *) by BookmarkId
| summarize
    TotalBookmarks = count(),
    ActiveBookmarks = countif(SoftDelete == false),
    SoftDeletedBookmarks = countif(SoftDelete == true),
    DistinctAnalysts = dcount(CreatedBy),
    LastBookmarkActivity = max(TimeGenerated)
"@

try {
    $bmResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $bookmarkQuery
    $bmRow = $bmResult.Results | Select-Object -First 1

    if ($null -eq $bmRow -or [int]$bmRow.TotalBookmarks -eq 0) {
        Write-Status "Zero bookmark activity in the last $LookbackDays days." "WARN"
        Write-Status "This is either (a) hunting genuinely not in active use, or (b) analysts working" "WARN"
        Write-Status "exclusively in the Defender portal where bookmark CREATION silently fails" "WARN"
        Write-Status "(see Hunting-B.md Fix 1). Verify with a direct portal check before concluding (a)." "WARN"
        $report.Add([pscustomobject]@{
            Category = "Bookmarks"
            Finding  = "Zero bookmark activity in last $LookbackDays days"
            Detail   = "Verify analysts aren't working exclusively in the Defender portal (bookmark creation is Azure-portal-only)"
            Severity = "WARN"
        })
    }
    else {
        Write-Status "Bookmarks: $($bmRow.TotalBookmarks) total ($($bmRow.ActiveBookmarks) active, $($bmRow.SoftDeletedBookmarks) soft-deleted), $($bmRow.DistinctAnalysts) distinct analyst(s), last activity $($bmRow.LastBookmarkActivity)" "OK"
        $report.Add([pscustomobject]@{
            Category = "Bookmarks"
            Finding  = "Active hunting bookmark usage"
            Detail   = "Total=$($bmRow.TotalBookmarks) Active=$($bmRow.ActiveBookmarks) Deleted=$($bmRow.SoftDeletedBookmarks) Analysts=$($bmRow.DistinctAnalysts) LastActivity=$($bmRow.LastBookmarkActivity)"
            Severity = "OK"
        })

        $deletedRatio = if ([int]$bmRow.TotalBookmarks -gt 0) { [math]::Round(([int]$bmRow.SoftDeletedBookmarks / [int]$bmRow.TotalBookmarks) * 100, 1) } else { 0 }
        if ($deletedRatio -gt 50) {
            Write-Status "Soft-deleted bookmark ratio is high ($deletedRatio%) — may indicate analysts bookmarking speculatively then cleaning up, or a workflow worth reviewing with the team." "WARN"
        }
    }
}
catch {
    Write-Status "Failed to query HuntingBookmark table: $($_.Exception.Message)" "ERROR"
    $report.Add([pscustomobject]@{
        Category = "Bookmarks"
        Finding  = "Query failed"
        Detail   = $_.Exception.Message
        Severity = "ERROR"
    })
}

# ---------------------------------------------------------------------------
# Execute — Section 2: Hunts (Preview) RBAC readiness
# ---------------------------------------------------------------------------
Write-Status "Checking RBAC assignments relevant to Hunts (Preview)..."

try {
    $sentinelRoles = Get-AzRoleAssignment -Scope $workspace.ResourceId |
        Where-Object { $_.RoleDefinitionName -match "Sentinel" }

    if (-not $sentinelRoles) {
        Write-Status "No Sentinel-specific role assignments found scoped directly to this workspace (assignments may exist at subscription/RG scope instead)." "WARN"
        $report.Add([pscustomobject]@{
            Category = "Hunts RBAC"
            Finding  = "No workspace-scoped Sentinel roles found"
            Detail   = "Check subscription/resource-group scope assignments; Hunts creation requires Microsoft Sentinel Contributor or a custom role on Microsoft.SecurityInsights/hunts"
            Severity = "WARN"
        })
    }
    else {
        foreach ($role in $sentinelRoles) {
            Write-Status "  $($role.DisplayName) — $($role.RoleDefinitionName)" "OK"
            $report.Add([pscustomobject]@{
                Category = "Hunts RBAC"
                Finding  = $role.DisplayName
                Detail   = "$($role.RoleDefinitionName) at $($role.Scope)"
                Severity = "OK"
            })
        }

        $hasContributor = $sentinelRoles | Where-Object { $_.RoleDefinitionName -eq "Microsoft Sentinel Contributor" }
        if (-not $hasContributor) {
            Write-Status "No account holds 'Microsoft Sentinel Contributor' directly on this workspace — confirm any custom roles present actually cover Microsoft.SecurityInsights/hunts operations before assuming Hunts creation works." "WARN"
        }
    }
}
catch {
    Write-Status "Failed to query role assignments: $($_.Exception.Message)" "ERROR"
    $report.Add([pscustomobject]@{
        Category = "Hunts RBAC"
        Finding  = "Query failed"
        Detail   = $_.Exception.Message
        Severity = "ERROR"
    })
}

# ---------------------------------------------------------------------------
# Execute — Section 3: Data lake managed identity (KQL job prerequisite)
# ---------------------------------------------------------------------------
Write-Status "Checking data lake managed identity (msg-resources-*) permissions for KQL jobs..."

try {
    $identityAssignments = Get-AzRoleAssignment -ResourceGroupName $WorkspaceResourceGroup |
        Where-Object { $_.DisplayName -like "msg-resources-*" }

    if (-not $identityAssignments) {
        Write-Status "No 'msg-resources-*' managed identity role assignment found in resource group '$WorkspaceResourceGroup'." "WARN"
        Write-Status "This means EITHER the tenant hasn't onboarded to the Sentinel data lake, OR onboarding" "WARN"
        Write-Status "happened but the Log Analytics Contributor grant to the managed identity was missed." "WARN"
        Write-Status "KQL job creation targeting NEW analytics-tier tables will fail until this is resolved." "WARN"
        $report.Add([pscustomobject]@{
            Category = "KQL Job Prerequisite"
            Finding  = "No data lake managed identity role assignment found"
            Detail   = "Either data lake onboarding was never completed, or Log Analytics Contributor was never granted to msg-resources-<guid> — manual verification required"
            Severity = "WARN"
        })
    }
    else {
        $hasLAContributor = $identityAssignments | Where-Object { $_.RoleDefinitionName -eq "Log Analytics Contributor" }
        if ($hasLAContributor) {
            Write-Status "Data lake managed identity holds Log Analytics Contributor — KQL job creation for new analytics-tier tables should be permitted." "OK"
            $report.Add([pscustomobject]@{
                Category = "KQL Job Prerequisite"
                Finding  = "Managed identity has Log Analytics Contributor"
                Detail   = "$($hasLAContributor.DisplayName) at $($hasLAContributor.Scope)"
                Severity = "OK"
            })
        }
        else {
            Write-Status "Managed identity found but does NOT hold Log Analytics Contributor — KQL job creation may fail." "WARN"
            $report.Add([pscustomobject]@{
                Category = "KQL Job Prerequisite"
                Finding  = "Managed identity present but missing Log Analytics Contributor"
                Detail   = "Roles held: $($identityAssignments.RoleDefinitionName -join ', ')"
                Severity = "WARN"
            })
        }
    }
}
catch {
    Write-Status "Failed to query managed identity role assignments: $($_.Exception.Message)" "ERROR"
    $report.Add([pscustomobject]@{
        Category = "KQL Job Prerequisite"
        Finding  = "Query failed"
        Detail   = $_.Exception.Message
        Severity = "ERROR"
    })
}

# ---------------------------------------------------------------------------
# Report — known scope exclusions (always emitted so the gap is never silent)
# ---------------------------------------------------------------------------
$exclusions = @(
    "Hunting query library contents / MITRE ATT&CK coverage — no Az PowerShell cmdlet surface; check the Queries tab and MITRE ATT&CK (Preview) page manually.",
    "Hunt (Preview) metadata (names, hypothesis/status, cloned query sets) — portal/API only.",
    "KQL job definitions, schedules, and run history/success rate — portal/API only; this script only validates the PERMISSION prerequisite, not job existence or health.",
    "Whether Sentinel data lake onboarding was actually completed — a missing managed identity role assignment cannot distinguish 'never onboarded' from 'onboarded but role grant missed'."
)
foreach ($item in $exclusions) {
    $report.Add([pscustomobject]@{
        Category = "Scope Exclusion"
        Finding  = "Not covered by this script"
        Detail   = $item
        Severity = "INFO"
    })
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = Join-Path -Path $OutputPath -ChildPath "SentinelHuntingAudit-$WorkspaceName-$timestamp.csv"
$report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Status "Audit complete. Report exported to: $csvPath" "OK"
Write-Status "Remember to manually capture: Queries tab N/A-filtered list, Hunts (Preview) tab hunt list, and Data lake exploration > Jobs list alongside this CSV when escalating." "INFO"
