<#
.SYNOPSIS
    Audits Microsoft Entra ID Governance Lifecycle Workflows — enable/schedule state, recent run
    health, AD DS account-task prerequisite risk, and license/custom-security-attribute gotchas.

.DESCRIPTION
    Read-only report against Microsoft Graph (identityGovernance/lifecycleWorkflows).
    Covers:
      - Every workflow's IsEnabled / IsSchedulingEnabled state (the two-switch gotcha that causes
        most "nothing happens" tickets)
      - Recent run history per workflow — flags workflows scheduled but with no runs in the lookback
        window, and runs reporting failed tasks
      - Workflows containing an Enable/Disable/Delete user account task, flagged as
        AD_TASK_PREREQ_UNVERIFIED — Graph cannot see on-prem provisioning agent version, extension
        mode, gMSA rights, or AD Recycle Bin state, so these require manual confirmation per
        LifecycleWorkflows-A.md Playbook 2 before trusting a reported "succeeded" task result
      - Tenant-wide deactivated custom security attribute definitions (a single deactivated
        attribute referenced by any workflow rule invalidates that rule entirely)
      - Microsoft Entra ID Governance / Entra Suite license presence
      - Optional per-user processing result lookup across all workflows via -UserId
    Does NOT create, modify, enable, schedule, or run any workflow. Does NOT change any user,
    group, or license assignment.

.PARAMETER OutputPath
    Folder to write CSV reports to. Created if it doesn't exist.

.PARAMETER RunLookbackDays
    How many days back to consider a workflow "recently run" when scheduling is enabled. Default 7.

.PARAMETER RunsPerWorkflow
    How many of the most recent runs to pull per workflow for failure-rate checking. Default 5.

.PARAMETER UserId
    Optional. A specific user's object ID or UPN. If supplied, also pulls that user's per-task
    processing result across every workflow that has processed them.

.EXAMPLE
    .\Get-LifecycleWorkflowAudit.ps1 -OutputPath C:\Temp\LCW-Audit

.EXAMPLE
    .\Get-LifecycleWorkflowAudit.ps1 -UserId "jdoe@contoso.com" -RunLookbackDays 14

.NOTES
    Requires: Microsoft.Graph.Identity.Governance, Microsoft.Graph.Identity.DirectoryManagement,
    Microsoft.Graph.Users modules.
    Connect-MgGraph -Scopes "LifecycleWorkflows.Read.All","CustomSecAttributeDefinition.Read.All",
                            "Organization.Read.All","User.Read.All"
    Least-privileged directory role: Lifecycle Workflows Administrator (read) or Global Reader is
    sufficient for all reads here; Attribute Assignment Reader is additionally required to see
    custom security attribute definitions.
    Does NOT verify on-prem AD DS prerequisites for Enable/Disable/Delete tasks (provisioning agent
    version/extension mode, gMSA permissions, AD Recycle Bin) — those must be checked directly on
    the provisioning agent host and in AD, per LifecycleWorkflows-A.md.
    Safe to run in production — no writes.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "C:\Temp\LCW-Audit-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    [int]$RunLookbackDays = 7,
    [int]$RunsPerWorkflow = 5,
    [string]$UserId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------- Preflight ----------
Write-Status "Checking for Microsoft Graph session..."
try {
    $null = Get-MgIdentityGovernanceLifecycleWorkflow -Top 1 -ErrorAction Stop
} catch {
    Write-Status "Not connected to Microsoft Graph, or missing LifecycleWorkflows.Read.All. Run Connect-MgGraph first." "ERROR"
    throw
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$findings = [System.Collections.Generic.List[object]]::new()

$adAccountTaskKeywords = @("Disable user account", "Delete user", "Enable user account")

# ---------- Detect: license presence ----------
Write-Status "Checking for Entra ID Governance / Entra Suite license..."
$govLicenseFound = $false
try {
    $skus = Get-MgSubscribedSku -All -ErrorAction Stop
    $govLicenseFound = [bool]($skus | Where-Object {
        $_.SkuPartNumber -match "GOVERNANCE|IDENTITY_GOVERNANCE|ENTRA_SUITE|EntraSuite" -or
        $_.SkuPartNumber -match "Entra_ID_Governance"
    })
    if (-not $govLicenseFound) {
        $findings.Add([PSCustomObject]@{
            Category = "Licensing"; Item = "Tenant"; Flag = "GOVERNANCE_LICENSE_NOT_DETECTED"
            Detail   = "No SKU matching Entra ID Governance / Entra Suite naming pattern found. Lifecycle Workflows requires one of these licenses — confirm manually via the admin center if this is a false negative from SKU naming drift."
        })
        Write-Status "No obviously-named Governance/Suite SKU found — flagged for manual confirmation." "WARN"
    } else {
        Write-Status "Governance/Suite-pattern license SKU found." "OK"
    }
} catch {
    Write-Status "Could not query subscribed SKUs (Organization.Read.All missing?) — skipping license check." "WARN"
}

# ---------- Detect: workflow inventory + enable/schedule state ----------
Write-Status "Collecting Lifecycle Workflow definitions..."
$workflows = Get-MgIdentityGovernanceLifecycleWorkflow -All -ExpandProperty "tasks"

$wfRows = [System.Collections.Generic.List[object]]::new()
foreach ($wf in $workflows) {
    $wfRows.Add([PSCustomObject]@{
        WorkflowId          = $wf.Id
        DisplayName         = $wf.DisplayName
        Category            = $wf.Category
        IsEnabled           = $wf.IsEnabled
        IsSchedulingEnabled = $wf.IsSchedulingEnabled
        TaskCount           = ($wf.Tasks | Measure-Object).Count
        LastModified        = $wf.LastModifiedDateTime
    })

    if ($wf.IsEnabled -and -not $wf.IsSchedulingEnabled) {
        $findings.Add([PSCustomObject]@{
            Category = "Scheduling"; Item = $wf.DisplayName; Flag = "ENABLED_NOT_SCHEDULED"
            Detail   = "Workflow is enabled but IsSchedulingEnabled = false — it will only ever run on-demand. Confirm this is intentional, not an oversight."
        })
    }
    if (-not $wf.IsEnabled) {
        $findings.Add([PSCustomObject]@{
            Category = "Scheduling"; Item = $wf.DisplayName; Flag = "WORKFLOW_DISABLED"
            Detail   = "IsEnabled = false — workflow will not run at all, scheduled or on-demand."
        })
    }

    # AD DS account-task prerequisite risk — keyword match on task display names, since Graph
    # doesn't expose on-prem infrastructure state for verification.
    $adTasks = $wf.Tasks | Where-Object {
        $taskName = $_.DisplayName
        $adAccountTaskKeywords | Where-Object { $taskName -like "*$_*" }
    }
    if ($adTasks) {
        $findings.Add([PSCustomObject]@{
            Category = "OnPremPrereq"; Item = $wf.DisplayName; Flag = "AD_TASK_PREREQ_UNVERIFIED"
            Detail   = "Workflow contains an account task ($(($adTasks.DisplayName) -join '; ')) that may target AD DS-synced users. Manually confirm: provisioning agent >= v1.1.1586.0 with 'HR-driven provisioning/Entra Connect Sync' extension mode, correct gMSA permissions, and (for Delete) AD Recycle Bin enabled. A 'succeeded' task result does not by itself prove the AD-side change occurred."
        })
    }
}
$wfRows | Export-Csv "$OutputPath\workflow_inventory.csv" -NoTypeInformation
Write-Status "Workflow inventory: $($wfRows.Count) workflow(s)." "OK"

# ---------- Detect: recent run health ----------
Write-Status "Collecting recent run history (lookback $RunLookbackDays day(s), top $RunsPerWorkflow per workflow)..."
$runRows = [System.Collections.Generic.List[object]]::new()
$cutoff = (Get-Date).AddDays(-$RunLookbackDays)

foreach ($wf in $workflows) {
    try {
        $runs = Get-MgIdentityGovernanceLifecycleWorkflowRun -LifecycleWorkflowId $wf.Id -Top $RunsPerWorkflow -ErrorAction Stop
    } catch {
        Write-Status "Could not pull runs for workflow '$($wf.DisplayName)' — skipping." "WARN"
        continue
    }

    foreach ($run in $runs) {
        $runRows.Add([PSCustomObject]@{
            WorkflowId    = $wf.Id
            WorkflowName  = $wf.DisplayName
            RunId         = $run.Id
            Status        = $run.Status
            Scheduled     = $run.ScheduledDateTime
            Completed     = $run.CompletedDateTime
            FailedTasks   = $run.FailedTasksCount
            ProcessedUsers= $run.ProcessedUsersCount
            TotalUsers    = $run.TotalUsersCount
        })
        if ($run.FailedTasksCount -and $run.FailedTasksCount -gt 0) {
            $findings.Add([PSCustomObject]@{
                Category = "RunHealth"; Item = $wf.DisplayName; Flag = "RUN_HAS_FAILED_TASKS"
                Detail   = "Run $($run.Id) (scheduled $($run.ScheduledDateTime)) reported $($run.FailedTasksCount) failed task(s). Pull per-user processing results for this run to see specific errors."
            })
        }
    }

    if ($wf.IsSchedulingEnabled) {
        $recentRuns = $runs | Where-Object { $_.ScheduledDateTime -and $_.ScheduledDateTime -ge $cutoff }
        if (-not $recentRuns -or $recentRuns.Count -eq 0) {
            $findings.Add([PSCustomObject]@{
                Category = "RunHealth"; Item = $wf.DisplayName; Flag = "NO_RECENT_RUNS"
                Detail   = "Scheduling is enabled but no runs found in the last $RunLookbackDays day(s) among the $RunsPerWorkflow most recent. Confirm the evaluation interval and whether any user has met execution conditions recently."
            })
        }
    }
}
$runRows | Export-Csv "$OutputPath\run_history.csv" -NoTypeInformation
Write-Status "Run history rows collected: $($runRows.Count)." "OK"

# ---------- Detect: deactivated custom security attributes (tenant-wide rule-invalidation risk) ----------
Write-Status "Checking for deactivated custom security attribute definitions..."
try {
    $csaDefs = Get-MgDirectoryCustomSecurityAttributeDefinition -All -ErrorAction Stop
    $deactivated = $csaDefs | Where-Object { $_.Status -ne "Available" }
    foreach ($d in $deactivated) {
        $findings.Add([PSCustomObject]@{
            Category = "CustomSecurityAttribute"; Item = "$($d.AttributeSet)_$($d.Name)"; Flag = "CSA_DEACTIVATED"
            Detail   = "Custom security attribute is not Available (Status = $($d.Status)). Any workflow rule referencing this attribute is invalid and will stop processing users until the rule is edited or the attribute is reactivated."
        })
    }
    if ($deactivated.Count -eq 0) {
        Write-Status "No deactivated custom security attributes found." "OK"
    } else {
        Write-Status "$($deactivated.Count) deactivated custom security attribute(s) found — cross-check against workflow rules manually (Graph does not expose rule text in a directly parseable form)." "WARN"
    }
} catch {
    Write-Status "Could not query custom security attribute definitions (missing CustomSecAttributeDefinition.Read.All / Attribute Assignment Reader role?) — skipping." "WARN"
}

# ---------- Optional: single-user processing result lookup ----------
if ($UserId) {
    Write-Status "Pulling per-workflow processing results for user '$UserId'..."
    try {
        $user = Get-MgUser -UserId $UserId -Property Id,UserPrincipalName,EmployeeHireDate,EmployeeLeaveDateTime,CreatedDateTime,AccountEnabled -ErrorAction Stop
    } catch {
        Write-Status "Could not resolve user '$UserId' — check the identifier and try again." "ERROR"
        throw
    }

    $userRows = [System.Collections.Generic.List[object]]::new()
    foreach ($wf in $workflows) {
        try {
            $results = Get-MgIdentityGovernanceLifecycleWorkflowUserProcessingResult -LifecycleWorkflowId $wf.Id `
                -Filter "subject/id eq '$($user.Id)'" -ExpandProperty "tasksProcessingResults" -ErrorAction Stop
        } catch {
            continue
        }
        foreach ($r in $results) {
            foreach ($t in $r.TasksProcessingResults) {
                $userRows.Add([PSCustomObject]@{
                    WorkflowName = $wf.DisplayName
                    RunId        = $r.WorkflowExecutionResultId
                    TaskName     = $t.DisplayName
                    TaskStatus   = $t.Status
                    FailureReason= $t.FailureReason
                })
            }
        }
    }
    $userRows | Export-Csv "$OutputPath\user_processing_results.csv" -NoTypeInformation
    Write-Status "User processing results: $($userRows.Count) task result row(s) for $($user.UserPrincipalName)." "OK"

    if (-not $user.EmployeeHireDate -and -not $user.EmployeeLeaveDateTime) {
        $findings.Add([PSCustomObject]@{
            Category = "UserAttributes"; Item = $user.UserPrincipalName; Flag = "NO_TRIGGER_DATE_SET"
            Detail   = "Neither employeeHireDate nor employeeLeaveDateTime is set on this user. Any time-based-attribute-triggered workflow scoped to this user will never fire until one is populated (for AD DS-synced users, these require explicit sync mapping)."
        })
    }
}

# ---------- Report ----------
$findings | Export-Csv "$OutputPath\findings.csv" -NoTypeInformation

Write-Status "----------------------------------------" "INFO"
Write-Status "Workflows inventoried: $($wfRows.Count)" "INFO"
Write-Status "Total findings: $($findings.Count)" $(if ($findings.Count -gt 0) { "WARN" } else { "OK" })
foreach ($group in ($findings | Group-Object Flag)) {
    Write-Status "  $($group.Name): $($group.Count)" "WARN"
}
Write-Status "Reports written to: $OutputPath" "OK"
