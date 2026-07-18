<#
.SYNOPSIS
    Read-only Azure Policy compliance and governance-health audit for a subscription (or a single
    resource group), covering assignment inventory, non-compliance breakdown by effect type,
    remediation task status, and exemption expiry risk.

.DESCRIPTION
    Produces a report covering:
      - Every Policy/Initiative assignment in scope, its enforcement mode, and effective scope
      - Compliance state breakdown per assignment, split by effect type (deny/audit/deployIfNotExists/etc.)
        so an engineer can immediately see which NonCompliant findings are self-healable vs. manual-only
      - Remediation task history and status for deployIfNotExists/modify assignments, flagging any
        Failed or long-Running tasks
      - Managed identity RBAC coverage sanity check for each remediation-capable assignment — flags
        WARN when the identity's role-assignment scope is narrower than the policy assignment's own
        scope, the single most common real-world remediation failure cause
      - Policy exemptions in scope, with a WARN flag for any expiring within -ExemptionWarningDays
        and a separate flag for exemptions with NO expiration set at all (permanent-by-omission risk)

    Does not modify anything (no assignments, exemptions, or remediation tasks are created, changed,
    or removed). Safe to run at any time. Does not trigger Start-AzPolicyComplianceScan by default —
    use -ForceRescan to request a fresh evaluation before reporting (adds latency, use sparingly).

.PARAMETER SubscriptionId
    Subscription to audit. Defaults to the current Az context's subscription if omitted.

.PARAMETER ResourceGroupName
    Optional. Scope the audit to a single resource group instead of the whole subscription.

.PARAMETER ExemptionWarningDays
    Flag exemptions expiring within this many days as WARN. Defaults to 14.

.PARAMETER ForceRescan
    Switch. Triggers Start-AzPolicyComplianceScan for the target scope before reading compliance
    data, then waits briefly for it to begin. Adds latency and does not guarantee the scan completes
    before the report runs on very large estates — use when a recent fix needs fast confirmation.

.PARAMETER ExportPath
    Path to export the CSV summary. Defaults to C:\Temp\AzurePolicyAudit_<timestamp>.csv.

.EXAMPLE
    .\Get-AzurePolicyComplianceAudit.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    .\Get-AzurePolicyComplianceAudit.ps1 -ResourceGroupName "rg-client-prod" -ExemptionWarningDays 30 -ForceRescan

.NOTES
    Requires: Az.PolicyInsights, Az.Resources, Az.Accounts modules
    Install:  Install-Module Az.PolicyInsights, Az.Resources, Az.Accounts -Scope CurrentUser
    Permissions: Reader is sufficient for compliance/assignment/exemption data. Reading a
                 remediation task's identity role assignments requires Reader at the scope those
                 role assignments live in (typically already covered by subscription Reader).
    Safe to run: Read-only by default. -ForceRescan only triggers a re-evaluation, it does not
                 change any resource, assignment, or exemption.
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [int]$ExemptionWarningDays = 14,
    [switch]$ForceRescan,
    [string]$ExportPath = "C:\Temp\AzurePolicyAudit_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
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
Write-Status "Checking required modules..."
foreach ($mod in @('Az.PolicyInsights', 'Az.Resources', 'Az.Accounts')) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        throw "Required module '$mod' is not installed. Run: Install-Module $mod -Scope CurrentUser"
    }
}

$context = Get-AzContext
if (-not $context) {
    throw "No active Az context. Run Connect-AzAccount first."
}

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
} else {
    $SubscriptionId = $context.Subscription.Id
}

$scope = if ($ResourceGroupName) {
    "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
} else {
    "/subscriptions/$SubscriptionId"
}

Write-Status "Auditing scope: $scope" "OK"

# ---------------------------------------------------------------------------
# Optional forced rescan
# ---------------------------------------------------------------------------
if ($ForceRescan) {
    Write-Status "Triggering on-demand compliance scan (this can take a while on large estates)..."
    try {
        if ($ResourceGroupName) {
            Start-AzPolicyComplianceScan -ResourceGroupName $ResourceGroupName -AsJob | Out-Null
        } else {
            Start-AzPolicyComplianceScan -AsJob | Out-Null
        }
        Write-Status "Scan started as background job. Report below reflects data available NOW — rerun after the scan completes for fully fresh results." "WARN"
    } catch {
        Write-Status "Could not start compliance scan: $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# Detect: Assignments
# ---------------------------------------------------------------------------
Write-Status "Collecting policy/initiative assignments..."
$assignments = Get-AzPolicyAssignment -Scope $scope -ErrorAction SilentlyContinue
Write-Status "Found $($assignments.Count) assignment(s) in scope." "OK"

$assignmentReport = foreach ($a in $assignments) {
    $isInitiative = $null -ne $a.Properties.PolicyDefinitionId -and $a.Properties.PolicyDefinitionId -match 'policySetDefinitions'
    [PSCustomObject]@{
        Name            = $a.Name
        DisplayName     = $a.Properties.DisplayName
        Type            = if ($isInitiative) { 'Initiative' } else { 'Policy' }
        Scope           = $a.Properties.Scope
        EnforcementMode = $a.Properties.EnforcementMode
        HasIdentity     = [bool]$a.Identity
        NotScopesCount  = ($a.Properties.NotScopes | Measure-Object).Count
        AssignmentId    = $a.PolicyAssignmentId
    }
}

# ---------------------------------------------------------------------------
# Detect: Compliance breakdown per assignment, with effect classification
# ---------------------------------------------------------------------------
Write-Status "Collecting compliance states (this queries Azure Resource Graph under the hood)..."

$complianceReport = @()
foreach ($a in $assignments) {
    try {
        $states = Get-AzPolicyState -PolicyAssignmentName $a.Name -Filter "ComplianceState eq 'NonCompliant'" -ErrorAction SilentlyContinue
        $nonCompliantCount = ($states | Measure-Object).Count

        $defId = $a.Properties.PolicyDefinitionId
        $effect = 'Unknown'
        try {
            if ($defId -match 'policySetDefinitions') {
                $effect = 'Initiative (mixed — see member definitions)'
            } else {
                $def = Get-AzPolicyDefinition -Id $defId -ErrorAction SilentlyContinue
                $effect = $def.Properties.PolicyRule.then.effect
            }
        } catch { $effect = 'CouldNotResolve' }

        $selfHealable = $effect -in @('deployIfNotExists', 'DeployIfNotExists', 'modify', 'Modify')

        $complianceReport += [PSCustomObject]@{
            AssignmentName    = $a.Name
            DisplayName       = $a.Properties.DisplayName
            Effect            = $effect
            NonCompliantCount = $nonCompliantCount
            SelfHealable      = $selfHealable
            RemediationNeeded = ($selfHealable -and $nonCompliantCount -gt 0)
        }
    } catch {
        Write-Status "Could not resolve compliance for assignment '$($a.Name)': $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# Detect: Remediation tasks + identity RBAC scope sanity check
# ---------------------------------------------------------------------------
Write-Status "Checking remediation task status and managed identity RBAC coverage..."

$remediationReport = @()
foreach ($row in ($complianceReport | Where-Object SelfHealable)) {
    $assignment = $assignments | Where-Object { $_.Name -eq $row.AssignmentName }
    if (-not $assignment) { continue }

    $tasks = Get-AzPolicyRemediation -PolicyAssignmentId $assignment.PolicyAssignmentId -ErrorAction SilentlyContinue
    $latestTask = $tasks | Sort-Object -Property { $_.Properties.CreatedOn } -Descending | Select-Object -First 1

    $identityStatus = "No managed identity on assignment"
    if ($assignment.Identity -and $assignment.Identity.PrincipalId) {
        try {
            $roleAssignments = Get-AzRoleAssignment -ObjectId $assignment.Identity.PrincipalId -ErrorAction SilentlyContinue
            $assignmentScope = $assignment.Properties.Scope
            $coversFullScope = $roleAssignments | Where-Object { $assignmentScope -like "$($_.Scope)*" }
            $identityStatus = if ($coversFullScope) { "OK — role scope covers assignment scope" }
                               elseif ($roleAssignments) { "WARN — identity has roles but NOT scoped to cover full assignment scope" }
                               else { "WARN — identity present but has NO role assignments" }
        } catch {
            $identityStatus = "Could not evaluate: $($_.Exception.Message)"
        }
    }

    $remediationReport += [PSCustomObject]@{
        AssignmentName       = $assignment.Name
        NonCompliantCount    = $row.NonCompliantCount
        LatestRemediationName  = $latestTask.Name
        LatestProvisioningState = $latestTask.Properties.ProvisioningState
        LatestSucceeded      = $latestTask.Properties.DeploymentSummary.SuccessfulDeployments
        LatestFailed         = $latestTask.Properties.DeploymentSummary.FailedDeployments
        NoTaskEverRun        = [bool]($row.NonCompliantCount -gt 0 -and -not $latestTask)
        IdentityRbacStatus   = $identityStatus
    }
}

# ---------------------------------------------------------------------------
# Detect: Exemptions
# ---------------------------------------------------------------------------
Write-Status "Collecting policy exemptions..."
$exemptions = Get-AzPolicyExemption -Scope $scope -ErrorAction SilentlyContinue

$exemptionReport = foreach ($e in $exemptions) {
    $expiresOn = $e.Properties.ExpiresOn
    $daysLeft = if ($expiresOn) { [math]::Round(((Get-Date $expiresOn) - (Get-Date)).TotalDays, 1) } else { $null }
    [PSCustomObject]@{
        Name             = $e.Name
        Scope            = $e.Properties.Scope
        PolicyAssignmentId = $e.Properties.PolicyAssignmentId
        Category         = $e.Properties.ExemptionCategory
        ExpiresOn        = $expiresOn
        DaysUntilExpiry  = $daysLeft
        Status           = if (-not $expiresOn) { 'WARN: No expiration set (permanent by omission)' }
                            elseif ($daysLeft -lt 0) { 'WARN: EXPIRED — no longer suppressing effect' }
                            elseif ($daysLeft -le $ExemptionWarningDays) { "WARN: Expiring in $daysLeft day(s)" }
                            else { 'OK' }
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host "`n=== Azure Policy Compliance Audit ===" -ForegroundColor Cyan
Write-Host "Scope: $scope`n"

Write-Host "--- Assignments ($($assignmentReport.Count)) ---" -ForegroundColor Cyan
$assignmentReport | Format-Table Name, Type, EnforcementMode, HasIdentity, NotScopesCount -AutoSize

Write-Host "`n--- Compliance by Assignment ---" -ForegroundColor Cyan
$complianceReport | Sort-Object NonCompliantCount -Descending |
    Format-Table AssignmentName, Effect, NonCompliantCount, SelfHealable, RemediationNeeded -AutoSize

$needsAttention = $complianceReport | Where-Object RemediationNeeded
if ($needsAttention) {
    Write-Status "$($needsAttention.Count) assignment(s) have NonCompliant resources that CAN self-heal but may not have been remediated yet." "WARN"
}

Write-Host "`n--- Remediation Task / Identity RBAC Status ---" -ForegroundColor Cyan
if ($remediationReport) {
    $remediationReport | Format-Table AssignmentName, NonCompliantCount, LatestProvisioningState, NoTaskEverRun, IdentityRbacStatus -AutoSize
    $noTask = $remediationReport | Where-Object NoTaskEverRun
    if ($noTask) {
        Write-Status "$($noTask.Count) assignment(s) have NonCompliant resources but NO remediation task has ever been run." "WARN"
    }
    $rbacWarn = $remediationReport | Where-Object { $_.IdentityRbacStatus -like 'WARN*' }
    if ($rbacWarn) {
        Write-Status "$($rbacWarn.Count) assignment(s) show a managed identity RBAC gap — remediation will fail or be incomplete." "WARN"
    }
} else {
    Write-Status "No remediation-capable (deployIfNotExists/modify) assignments with NonCompliant resources found." "OK"
}

Write-Host "`n--- Exemptions ($($exemptionReport.Count)) ---" -ForegroundColor Cyan
if ($exemptionReport) {
    $exemptionReport | Format-Table Name, Category, ExpiresOn, DaysUntilExpiry, Status -AutoSize
    $exemptionWarn = $exemptionReport | Where-Object { $_.Status -like 'WARN*' }
    if ($exemptionWarn) {
        Write-Status "$($exemptionWarn.Count) exemption(s) need attention (expired, expiring soon, or never expire)." "WARN"
    }
} else {
    Write-Status "No exemptions found in scope." "OK"
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
$exportDir = Split-Path $ExportPath -Parent
if ($exportDir -and -not (Test-Path $exportDir)) {
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
}

$combined = @()
$combined += $assignmentReport   | ForEach-Object { $_ | Add-Member -NotePropertyName Section -NotePropertyValue 'Assignment' -PassThru }
$combined += $complianceReport   | ForEach-Object { $_ | Add-Member -NotePropertyName Section -NotePropertyValue 'Compliance' -PassThru }
$combined += $remediationReport  | ForEach-Object { $_ | Add-Member -NotePropertyName Section -NotePropertyValue 'Remediation' -PassThru }
$combined += $exemptionReport    | ForEach-Object { $_ | Add-Member -NotePropertyName Section -NotePropertyValue 'Exemption' -PassThru }

$combined | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Report exported to $ExportPath" "OK"
