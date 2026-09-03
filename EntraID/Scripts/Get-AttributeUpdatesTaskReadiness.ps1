<#
.SYNOPSIS
    Audits Microsoft Entra Lifecycle Workflows for use of the Update user attributes task
    (Preview) and flags configurations likely to hit its documented limitations.

.DESCRIPTION
    Companion script to EntraID/Troubleshooting/LifecycleWorkflows-A.md and -B.md, covering the
    "Update user attributes task (Preview, added ~mid-2026)" section and Remediation Playbook 5 /
    Fix 8 in those runbooks.

    The Update user attributes task sets or clears attribute values on cloud-managed users when a
    lifecycle event fires. As of Preview (mid-2026), it carries three documented limitations this
    script checks for:
      - Synced (AD DS) users are NOT supported — the task only runs for cloud-managed users
      - employeeLeaveDateTime is NOT currently a supported target attribute
      - Custom security attributes are NOT supported as a target attribute type
      - Up to 10 attribute updates are supported per task instance

    Microsoft Graph does not expose a dedicated, documented property that names each Lifecycle
    Workflow task's arguments in a fully stable schema for this specific Preview task type as of
    this writing. This script therefore takes a best-effort, defensive approach:
      - Enumerates all workflows and their tasks via identityGovernance/lifecycleWorkflows/workflows
        (expanding tasks), and pattern-matches on the task's displayName/category for anything that
        looks like the Update user attributes task (case-insensitive match on "attribute")
      - Where task arguments ARE present in the Graph response, inspects them for employeeLeaveDateTime
        and for argument counts beyond 10 as a soft signal only — always confirm the actual
        configuration in the Microsoft Entra admin center rather than trusting this script's parse
        of argument shape, since the schema may change while this task is in Preview
      - Separately reports the tenant's cloud-managed vs. synced user population size, so an MSP can
        gauge how much of the target population this task can even reach
      - Flags any workflow using this task whose scope is NOT restricted to exclude synced users
        (best-effort: checks for an explicit onPremisesSyncEnabled exclusion in the workflow's rule
        text; a workflow without one isn't necessarily broken, since the task itself is a no-op for
        synced users, but the scope is misleading to a reader and worth cleaning up)

    Read-only. Makes no changes to any workflow, task, or user.

.PARAMETER OutputPath
    Folder to write CSV reports to. Created if it doesn't exist. Defaults to the current user's
    temp folder.

.EXAMPLE
    .\Get-AttributeUpdatesTaskReadiness.ps1

    Connects (if needed) to Microsoft Graph and produces a readiness report for every workflow
    using the Update user attributes task.

.EXAMPLE
    .\Get-AttributeUpdatesTaskReadiness.ps1 -OutputPath C:\Temp\AttrUpdatesAudit

    Same, with a fixed output folder.

.NOTES
    Requires: Microsoft.Graph.Identity.Governance module (or equivalent Graph permission set:
    LifecycleWorkflows.Read.All, User.Read.All). Read-only — no writes.
    Preview feature reference: Update user attributes with Lifecycle Workflows (Preview),
    https://learn.microsoft.com/en-us/entra/id-governance/how-to-lifecycle-workflow-update-user-attributes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Join-Path $env:TEMP "AttributeUpdatesTaskAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$MAX_ATTRIBUTES_PER_TASK = 10
$UNSUPPORTED_TARGET_ATTRIBUTE = "employeeLeaveDateTime"

# --- Preflight ---
Write-Status "Update User Attributes Task (Preview) Readiness Audit" "INFO"
Write-Status "Reference: https://learn.microsoft.com/en-us/entra/id-governance/how-to-lifecycle-workflow-update-user-attributes" "INFO"

try {
    Get-Command Get-MgIdentityGovernanceLifecycleWorkflow -ErrorAction Stop | Out-Null
}
catch {
    Write-Status "Microsoft.Graph.Identity.Governance module/cmdlets not found. Install-Module Microsoft.Graph -Scope CurrentUser, then Connect-MgGraph -Scopes 'LifecycleWorkflows.Read.All','User.Read.All'." "ERROR"
    throw "Required Graph cmdlets not available."
}

if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# --- Population baseline ---
Write-Status "Sampling cloud-managed vs. synced user population..." "INFO"
try {
    $syncedCount = (Get-MgUser -Filter "onPremisesSyncEnabled eq true" -ConsistencyLevel eventual -CountVariable syncedCountVar -All -ErrorAction SilentlyContinue | Measure-Object).Count
    $cloudCount  = (Get-MgUser -Filter "onPremisesSyncEnabled eq null or onPremisesSyncEnabled eq false" -ConsistencyLevel eventual -CountVariable cloudCountVar -All -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Status "Synced (AD DS) users found: $syncedCount -- Update user attributes task cannot reach these." "INFO"
    Write-Status "Cloud-managed users found: $cloudCount -- eligible population for this task." "INFO"
}
catch {
    Write-Status "Population sampling failed (non-fatal): $($_.Exception.Message)" "WARN"
    $syncedCount = "unknown"; $cloudCount = "unknown"
}

# --- Detect ---
Write-Status "Enumerating Lifecycle Workflows and tasks..." "INFO"
$workflows = @(Get-MgIdentityGovernanceLifecycleWorkflow -ExpandProperty Tasks -All -ErrorAction Stop)

if ($workflows.Count -eq 0) {
    Write-Status "No Lifecycle Workflows found in this tenant. Nothing to audit." "WARN"
    return
}

$results = New-Object System.Collections.Generic.List[Object]

foreach ($wf in $workflows) {

    $attributeTasks = @($wf.Tasks | Where-Object {
        $_.DisplayName -match "(?i)attribute" -or $_.Category -match "(?i)attribute"
    })

    if ($attributeTasks.Count -eq 0) { continue }

    foreach ($task in $attributeTasks) {

        $argCount = $null
        $usesUnsupportedAttribute = $false
        $argInspectionNote = "Task arguments not present/parseable in Graph response for this task -- confirm configuration in the admin center."

        if ($task.Arguments) {
            try {
                $argNames = $task.Arguments | ForEach-Object { $_.Name }
                $argCount = @($argNames).Count
                $usesUnsupportedAttribute = ($argNames -contains $UNSUPPORTED_TARGET_ATTRIBUTE) -or
                                            ($task.Arguments | Where-Object { $_.Value -match $UNSUPPORTED_TARGET_ATTRIBUTE }).Count -gt 0
                $argInspectionNote = "Parsed $argCount argument(s) from Graph response (best-effort parse -- verify in admin center)."
            }
            catch {
                $argInspectionNote = "Argument parsing failed: $($_.Exception.Message) -- verify in admin center."
            }
        }

        $ruleText = ($wf.ExecutionConditions.Scope.Rule) 2>$null
        $scopeExcludesSynced = $false
        if ($ruleText -and ($ruleText -match "(?i)onPremisesSyncEnabled")) {
            $scopeExcludesSynced = $true
        }

        $riskFlag = "OK"
        $riskNotes = New-Object System.Collections.Generic.List[string]

        if (-not $scopeExcludesSynced) {
            $riskNotes.Add("Workflow scope has no explicit onPremisesSyncEnabled exclusion -- task will silently no-op for any synced users the scope otherwise matches.")
        }
        if ($usesUnsupportedAttribute) {
            $riskNotes.Add("Task appears to reference employeeLeaveDateTime -- not a supported target attribute in Preview.")
        }
        if ($argCount -and $argCount -gt $MAX_ATTRIBUTES_PER_TASK) {
            $riskNotes.Add("Parsed argument count ($argCount) exceeds the documented 10-attribute-per-task limit -- re-verify, this should not be possible via the admin center UI.")
        }

        if ($riskNotes.Count -gt 0) { $riskFlag = "REVIEW" }

        $results.Add([PSCustomObject]@{
            WorkflowId              = $wf.Id
            WorkflowDisplayName     = $wf.DisplayName
            WorkflowEnabled         = $wf.IsEnabled
            SchedulingEnabled       = $wf.IsSchedulingEnabled
            TaskDisplayName         = $task.DisplayName
            ScopeExcludesSyncedUsers = $scopeExcludesSynced
            ParsedArgumentCount     = $argCount
            ArgumentInspectionNote  = $argInspectionNote
            RiskFlag                = $riskFlag
            RiskNotes               = ($riskNotes -join " | ")
        })
    }
}

# --- Report ---
Write-Host ""
Write-Status "=== Summary ===" "INFO"
Write-Status "Cloud-managed users (eligible population): $cloudCount" "INFO"
Write-Status "Synced users (task cannot reach these): $syncedCount" "INFO"

if ($results.Count -eq 0) {
    Write-Status "No workflows appear to use the Update user attributes task (name/category match on 'attribute')." "OK"
    Write-Status "Note: this is a heuristic match against DisplayName/Category -- confirm manually if a workflow is believed to use this task and wasn't flagged." "WARN"
}
else {
    $reviewCount = ($results | Where-Object { $_.RiskFlag -eq "REVIEW" }).Count
    Write-Status "Workflow/task combinations found using the Update user attributes task: $($results.Count)" "INFO"
    Write-Status "Flagged for review: $reviewCount" $(if ($reviewCount -gt 0) { "WARN" } else { "OK" })
    $results | Format-Table -AutoSize WorkflowDisplayName, TaskDisplayName, ScopeExcludesSyncedUsers, RiskFlag

    $exportPath = Join-Path $OutputPath "AttributeUpdatesTaskAudit.csv"
    $results | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8
    Write-Status "Full report exported to: $exportPath" "OK"
}

Write-Status "This is a heuristic, best-effort audit against a Preview feature's Graph representation." "WARN"
Write-Status "Always confirm final task configuration in: Entra admin center > ID Governance > Lifecycle workflows > <workflow> > Tasks." "WARN"
