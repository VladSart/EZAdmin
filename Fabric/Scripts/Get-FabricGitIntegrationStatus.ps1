<#
.SYNOPSIS
    Audits Git integration connection state, sync health, and item-count-cap
    exposure across Fabric workspaces.

.DESCRIPTION
    Companion script to Fabric/GitIntegration-B.md and Fabric/GitIntegration-A.md.
    Read-only. Two-tier approach:

    1. Uses the Fabric REST Admin API (GET /v1/admin/workspaces and
       GET /v1/admin/workspaces/{id}/items) to enumerate all tenant workspaces
       and their current item counts, and flags any workspace approaching the
       1,000 Fabric+Power BI item cap that Git integration syncing enforces.
    2. For each workspace, calls the workspace-scoped Git integration endpoints
       (GET .../git/connection and GET .../git/status) with the SAME supplied
       token to report connection state and per-item sync health (conflicts,
       uncommitted changes, pending updates).

    IMPORTANT LIMITATION: the Git connection/status endpoints are workspace-scoped,
    not admin-scoped — there is no tenant-wide "list all Git connections" Admin
    API surface as of this script's writing. The supplied token's principal must
    itself have at least Contributor-with-item-permission (or be a Fabric admin
    who is ALSO a member of the workspace) to see Git status for a given
    workspace. Workspaces the token's principal cannot access are reported as
    "Not accessible with this token" rather than failing the whole run — this is
    expected for a tenant-admin token that isn't a member of every workspace, and
    is NOT itself evidence of a Git integration problem.

    Does NOT and CANNOT check: tenant-setting values or their delegation state
    (portal-only, see GitIntegration-B.md Diagnosis Step 5), Git-provider-side
    (ADO/GitHub) repo permissions, or commit-size-limit exposure (cannot be known
    without inspecting the actual pending diff content).

.PARAMETER AccessToken
    A bearer token for the Fabric REST API (scope: https://api.fabric.microsoft.com/.default).
    Needs Fabric Administrator role for the admin/workspaces enumeration step, and
    ideally also workspace membership across the tenant for full Git-status coverage
    (rare in practice — expect partial coverage, see LIMITATION above).
    If omitted, the script assumes $env:FABRIC_ADMIN_TOKEN is set.

.PARAMETER ItemCountWarningThreshold
    Percentage of the 1,000-item cap at which a workspace is flagged as approaching
    the limit. Defaults to 80 (i.e. 800+ items).

.PARAMETER OutputPath
    Folder to write CSV exports to. Defaults to the current directory.

.EXAMPLE
    .\Get-FabricGitIntegrationStatus.ps1 -AccessToken $token

.EXAMPLE
    $env:FABRIC_ADMIN_TOKEN = $token
    .\Get-FabricGitIntegrationStatus.ps1 -ItemCountWarningThreshold 90 -OutputPath "C:\Audits"

.NOTES
    Requires: Fabric Administrator (or Global/Power Platform Administrator) role
    for the admin enumeration step; workspace-level access for full Git-status
    coverage (partial results are expected and reported, not an error state).
    Safe/unsafe: fully read-only (GET requests only). No changes are made.
    Run-as: any account holding the required Entra role; no local admin needed.
#>

[CmdletBinding()]
param(
    [string]$AccessToken = $env:FABRIC_ADMIN_TOKEN,
    [ValidateRange(1, 100)]
    [int]$ItemCountWarningThreshold = 80,
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
if (-not $AccessToken) {
    Write-Status "No access token supplied via -AccessToken or `$env:FABRIC_ADMIN_TOKEN." "ERROR"
    Write-Status "Acquire one with scope https://api.fabric.microsoft.com/.default and pass it in." "ERROR"
    throw "AccessToken is required."
}

$headers = @{ Authorization = "Bearer $AccessToken" }
$adminBase = "https://api.fabric.microsoft.com/v1/admin"
$wsBase    = "https://api.fabric.microsoft.com/v1"
$itemCap   = 1000

function Invoke-FabricApi {
    param([string]$Uri, [switch]$SuppressErrors)
    try {
        return Invoke-RestMethod -Uri $Uri -Headers $headers -Method GET
    } catch {
        if (-not $SuppressErrors) {
            Write-Status "Call failed: $Uri — $($_.Exception.Message)" "ERROR"
        }
        return $null
    }
}

# ---- Detect: enumerate all tenant workspaces via Admin API ----
Write-Status "Retrieving tenant workspace list via Admin API..."
$wsResponse = Invoke-FabricApi -Uri "$adminBase/workspaces"
if (-not $wsResponse) {
    throw "Could not retrieve workspaces — confirm the token's account holds the Fabric Administrator role."
}
$allWorkspaces = if ($wsResponse.workspaces) { $wsResponse.workspaces } else { $wsResponse }
$allWorkspaces = $allWorkspaces | Where-Object { $_.type -ne "PersonalGroup" }
Write-Status "Found $($allWorkspaces.Count) governable workspace(s) (excluding MyWorkspace)." "OK"

# ---- Execute: per-workspace item count + Git status ----
$report = @()
$i = 0
foreach ($ws in $allWorkspaces) {
    $i++
    Write-Progress -Activity "Auditing Git integration status" -Status $ws.name -PercentComplete (($i / $allWorkspaces.Count) * 100)

    # Item count (for the 1,000-item cap warning)
    $itemsResponse = Invoke-FabricApi -Uri "$adminBase/workspaces/$($ws.id)/items" -SuppressErrors
    $itemCount = if ($itemsResponse.value) { @($itemsResponse.value).Count } elseif ($itemsResponse) { @($itemsResponse).Count } else { $null }
    $pctOfCap = if ($null -ne $itemCount) { [math]::Round(($itemCount / $itemCap) * 100, 1) } else { $null }

    # Git connection state (workspace-scoped — may not be accessible to this token)
    $gitAccessible = $true
    $connection = Invoke-FabricApi -Uri "$wsBase/workspaces/$($ws.id)/git/connection" -SuppressErrors
    if (-not $connection) { $gitAccessible = $false }

    $conflictCount = 0
    $uncommittedCount = 0
    $updateRequiredCount = 0
    $provider = $null
    $org = $null
    $repo = $null
    $branch = $null

    if ($gitAccessible -and $connection.gitProviderDetails) {
        $provider = $connection.gitProviderDetails.gitProviderType
        $org      = $connection.gitProviderDetails.organizationName
        $repo     = $connection.gitProviderDetails.repositoryName
        $branch   = $connection.gitProviderDetails.branchName

        $status = Invoke-FabricApi -Uri "$wsBase/workspaces/$($ws.id)/git/status" -SuppressErrors
        if ($status.changes) {
            $conflictCount       = @($status.changes | Where-Object { $_.conflictType }).Count
            $uncommittedCount    = @($status.changes | Where-Object { $_.workspaceChange -and -not $_.remoteChange }).Count
            $updateRequiredCount = @($status.changes | Where-Object { $_.remoteChange }).Count
        }
    }

    $report += [PSCustomObject]@{
        WorkspaceName       = $ws.name
        WorkspaceId         = $ws.id
        CapacityId          = $ws.capacityId
        ItemCount           = $itemCount
        PctOfItemCap        = $pctOfCap
        ApproachingItemCap  = [bool]($pctOfCap -ge $ItemCountWarningThreshold)
        GitCheckAccessible  = $gitAccessible
        GitConnected        = [bool]($gitAccessible -and $connection.gitProviderDetails)
        Provider            = $provider
        Organization        = $org
        Repository          = $repo
        Branch              = $branch
        ConflictCount       = $conflictCount
        UncommittedCount    = $uncommittedCount
        UpdateRequiredCount = $updateRequiredCount
    }
}
Write-Progress -Activity "Auditing Git integration status" -Completed

# ---- Report ----
Write-Host ""
Write-Status "=== Workspaces approaching the 1,000-item cap (>= $ItemCountWarningThreshold%) ==="
$nearCap = $report | Where-Object ApproachingItemCap
if ($nearCap) {
    Write-Status "$($nearCap.Count) workspace(s) at or above the threshold." "WARN"
    $nearCap | Format-Table WorkspaceName, ItemCount, PctOfItemCap -AutoSize
} else {
    Write-Status "No workspaces at or above the $ItemCountWarningThreshold% threshold." "OK"
}

Write-Host ""
Write-Status "=== Git-connected workspaces with unresolved conflicts ==="
$withConflicts = $report | Where-Object { $_.GitConnected -and $_.ConflictCount -gt 0 }
if ($withConflicts) {
    Write-Status "$($withConflicts.Count) workspace(s) have items in Conflict state — Update is blocked until resolved." "WARN"
    $withConflicts | Format-Table WorkspaceName, Provider, Branch, ConflictCount -AutoSize
} else {
    Write-Status "No accessible Git-connected workspace reports an unresolved conflict." "OK"
}

Write-Host ""
Write-Status "=== Coverage summary ==="
$notAccessible = @($report | Where-Object { -not $_.GitCheckAccessible }).Count
$connected     = @($report | Where-Object GitConnected).Count
Write-Status "Git status checked for $($report.Count - $notAccessible) of $($report.Count) workspace(s); $notAccessible were not accessible with this token (expected for tenant-admin tokens without workspace membership)." "INFO"
Write-Status "$connected workspace(s) confirmed connected to Git out of those checked." "INFO"

# ---- Export ----
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportPath = Join-Path $OutputPath "FabricGitIntegrationStatus_$timestamp.csv"
$report | Export-Csv -Path $reportPath -NoTypeInformation

Write-Host ""
Write-Status "Full report exported: $reportPath" "OK"
Write-Status "Reminder: tenant-setting values/delegation and Git-provider-side (ADO/GitHub) repo permissions are NOT checked by this script — verify those manually per GitIntegration-B.md Diagnosis steps." "WARN"
