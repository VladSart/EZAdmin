<#
.SYNOPSIS
    Audits Fabric deployment pipeline structure, role assignments, and last
    deployment outcome across every pipeline the supplied token can see.

.DESCRIPTION
    Companion script to Fabric/DeploymentPipelines-B.md and
    Fabric/DeploymentPipelines-A.md. Read-only. For each deployment pipeline
    visible to the calling principal, this script:

    1. Lists stages in order and flags any stage with no workspace assigned
       (a structural gap — content can't flow through an unassigned stage).
    2. Lists pipeline role assignments and flags pipelines with ZERO Admin
       assignments — this is the "orphaned pipeline" state described in
       DeploymentPipelines-B.md Fix 7, where nobody can manage the pipeline
       or unassign its stuck workspaces without tenant-admin intervention.
    3. Pulls the most recent deployment operation (if any) and flags pipelines
       whose last operation status is Failed, surfacing the failing step's
       error text directly rather than just the pass/fail flag.

    IMPORTANT LIMITATION: "List Deployment Pipelines" (GET /v1/deploymentPipelines)
    returns pipelines the CALLING PRINCIPAL can access — there is no tenant-wide
    Admin API enumeration for deployment pipelines equivalent to the workspace
    Admin API's /v1/admin/workspaces. A token belonging to a Fabric admin who
    isn't a participant on every pipeline will see a PARTIAL inventory. This is
    expected behavior, not a script defect, and is reported explicitly in the
    summary rather than silently under-counting. For a genuinely tenant-wide
    inventory, this script would need to be run once per relevant admin/service
    account, or cross-referenced against a workspace-level audit (see
    Get-FabricCapacityHealth.ps1 for the workspace enumeration side).

    Does NOT and CANNOT check: whether a deployment SHOULD have happened
    recently (staleness is contextual, not something this script can judge),
    Git-integration state on the same workspaces (see
    Get-FabricGitIntegrationStatus.ps1), or deployment rule configuration
    detail (not exposed by the pipeline/stage/operation endpoints used here).

.PARAMETER AccessToken
    A bearer token for the Fabric REST API (scope: https://api.fabric.microsoft.com/.default).
    The token's principal must be at least a participant (any role) on the
    pipelines it should audit — Fabric Administrator does not, by itself,
    grant visibility into every tenant pipeline (see LIMITATION above).
    If omitted, the script assumes $env:FABRIC_ADMIN_TOKEN is set.

.PARAMETER OutputPath
    Folder to write CSV exports to. Defaults to the current directory.

.EXAMPLE
    .\Get-FabricDeploymentPipelineStatus.ps1 -AccessToken $token

.EXAMPLE
    $env:FABRIC_ADMIN_TOKEN = $token
    .\Get-FabricDeploymentPipelineStatus.ps1 -OutputPath "C:\Audits"

.NOTES
    Requires: any Entra account that is at least a participant on the
    deployment pipelines to be audited (see LIMITATION — no tenant-wide
    admin enumeration exists for this item type).
    Safe/unsafe: fully read-only (GET requests only). No changes are made.
    Run-as: any account holding the required Fabric role; no local admin needed.
#>

[CmdletBinding()]
param(
    [string]$AccessToken = $env:FABRIC_ADMIN_TOKEN,
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
$base = "https://api.fabric.microsoft.com/v1/deploymentPipelines"

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

# ---- Detect: enumerate pipelines visible to this token ----
Write-Status "Retrieving deployment pipelines visible to the calling principal..."
$pipelinesResponse = Invoke-FabricApi -Uri $base
if (-not $pipelinesResponse) {
    throw "Could not retrieve deployment pipelines — confirm the token is valid and the account is at least a participant on some pipeline."
}
$allPipelines = if ($pipelinesResponse.value) { $pipelinesResponse.value } else { $pipelinesResponse }
Write-Status "Found $($allPipelines.Count) pipeline(s) visible to this token (see LIMITATION in script header — this is not necessarily tenant-wide)." "OK"

# ---- Execute: per-pipeline structure, roles, last operation ----
$report = @()
$i = 0
foreach ($pipeline in $allPipelines) {
    $i++
    Write-Progress -Activity "Auditing deployment pipelines" -Status $pipeline.displayName -PercentComplete (($i / $allPipelines.Count) * 100)
    $pBase = "$base/$($pipeline.id)"

    # Stages
    $stagesResponse = Invoke-FabricApi -Uri "$pBase/stages" -SuppressErrors
    $stages = if ($stagesResponse.value) { $stagesResponse.value } else { @() }
    $unassignedStages = @($stages | Where-Object { -not $_.workspaceId })

    # Role assignments — the orphaned-pipeline check
    $rolesResponse = Invoke-FabricApi -Uri "$pBase/roleAssignments" -SuppressErrors
    $roles = if ($rolesResponse.value) { $rolesResponse.value } else { @() }
    $adminCount = @($roles | Where-Object { $_.role -eq 'Admin' }).Count
    $isOrphaned = ($adminCount -eq 0)

    # Most recent operation
    $opsResponse = Invoke-FabricApi -Uri "$pBase/operations" -SuppressErrors
    $ops = if ($opsResponse.value) { $opsResponse.value } else { @() }
    $lastOp = $ops | Select-Object -First 1
    $lastOpStatus = if ($lastOp) { $lastOp.status } else { "NoDeploymentsYet" }
    $lastOpError = $null

    if ($lastOp -and $lastOp.status -eq 'Failed') {
        $opDetail = Invoke-FabricApi -Uri "$pBase/operations/$($lastOp.id)" -SuppressErrors
        $failedSteps = $opDetail.executionPlan.steps | Where-Object { $_.status -eq 'Failed' }
        if ($failedSteps) {
            $lastOpError = ($failedSteps | ForEach-Object {
                "$($_.sourceAndTarget.sourceItemDisplayName): $($_.error.errorCode) - $($_.error.message)"
            }) -join " | "
        }
    }

    $report += [PSCustomObject]@{
        PipelineName        = $pipeline.displayName
        PipelineId          = $pipeline.id
        StageCount          = $stages.Count
        UnassignedStageCount = $unassignedStages.Count
        UnassignedStageNames = ($unassignedStages.displayName -join ", ")
        AdminRoleCount      = $adminCount
        IsOrphaned          = $isOrphaned
        TotalRoleAssignments = $roles.Count
        LastOperationId     = if ($lastOp) { $lastOp.id } else { $null }
        LastOperationStatus = $lastOpStatus
        LastOperationTime   = if ($lastOp) { $lastOp.executionEndTime } else { $null }
        LastOperationError  = $lastOpError
    }
}
Write-Progress -Activity "Auditing deployment pipelines" -Completed

# ---- Report ----
Write-Host ""
Write-Status "=== Orphaned pipelines (zero Admin role assignments) ==="
$orphaned = $report | Where-Object IsOrphaned
if ($orphaned) {
    Write-Status "$($orphaned.Count) pipeline(s) have no admin — see DeploymentPipelines-B.md Fix 7 to reclaim via the Admin API." "WARN"
    $orphaned | Format-Table PipelineName, PipelineId, TotalRoleAssignments -AutoSize
} else {
    Write-Status "No orphaned pipelines found among those visible to this token." "OK"
}

Write-Host ""
Write-Status "=== Pipelines with unassigned stages ==="
$gapStages = $report | Where-Object { $_.UnassignedStageCount -gt 0 }
if ($gapStages) {
    Write-Status "$($gapStages.Count) pipeline(s) have at least one stage with no workspace assigned." "WARN"
    $gapStages | Format-Table PipelineName, UnassignedStageCount, UnassignedStageNames -AutoSize
} else {
    Write-Status "Every visible pipeline has a workspace assigned to every stage." "OK"
}

Write-Host ""
Write-Status "=== Most recent deployment failed ==="
$failedDeploys = $report | Where-Object { $_.LastOperationStatus -eq 'Failed' }
if ($failedDeploys) {
    Write-Status "$($failedDeploys.Count) pipeline(s) have a FAILED most-recent deployment." "WARN"
    $failedDeploys | Format-Table PipelineName, LastOperationTime, LastOperationError -AutoSize -Wrap
} else {
    Write-Status "No visible pipeline's most recent deployment is in a Failed state." "OK"
}

Write-Host ""
Write-Status "=== Coverage summary ==="
Write-Status "$($report.Count) pipeline(s) audited — visibility is limited to pipelines this token's principal participates in (see script header LIMITATION)." "INFO"

# ---- Export ----
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportPath = Join-Path $OutputPath "FabricDeploymentPipelineStatus_$timestamp.csv"
$report | Export-Csv -Path $reportPath -NoTypeInformation

Write-Host ""
Write-Status "Full report exported: $reportPath" "OK"
Write-Status "Reminder: this is not a tenant-wide enumeration — pipelines this token's principal isn't a participant on are invisible to this script, not counted as zero." "WARN"
