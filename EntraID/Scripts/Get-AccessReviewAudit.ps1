<#
.SYNOPSIS
    Audits Microsoft Entra Access Reviews — coverage, stalled instances, remediation gaps, and
    reviewability blockers.

.DESCRIPTION
    Read-only report against Microsoft Graph (identityGovernance/accessReviews).
    Covers:
      - Every access review definition, its recurrence and auto-apply setting
      - Per-instance status and decision completion rate (flags stalled/low-response instances)
      - Definitions with auto-apply disabled (remediation requires manual follow-up)
      - Reviews scoped to on-premises AD-synced groups (survey-only unless writeback configured)
      - Applications with AppRoleAssignmentRequired = $false (not reviewable, hidden gap)
      - Recent AccessReviews-category audit log activity
    Does NOT create, modify, apply, or stop any review. Does NOT change group/app/role membership.

.PARAMETER OutputPath
    Folder to write CSV reports to. Created if it doesn't exist.

.PARAMETER AuditLogDays
    How many days of AccessReviews audit log activity to pull. Default 7.

.EXAMPLE
    .\Get-AccessReviewAudit.ps1 -OutputPath C:\Temp\AccessReview-Audit

.EXAMPLE
    .\Get-AccessReviewAudit.ps1 -AuditLogDays 30

.NOTES
    Requires: Microsoft.Graph.Identity.Governance, Microsoft.Graph.Applications,
    Microsoft.Graph.Groups, Microsoft.Graph.Reports modules.
    Connect-MgGraph -Scopes "AccessReview.Read.All","Application.Read.All","Group.Read.All","AuditLog.Read.All"
    Least-privileged directory role: Global Reader / Security Reader is sufficient for all reads here.
    Does NOT cover Azure resource role reviews (PIM for Azure resources) — the Graph API for
    access reviews does not expose that resource type; see AccessReviews-A.md for the ARM-API path.
    Safe to run in production — no writes.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "C:\Temp\AccessReview-Audit-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    [int]$AuditLogDays = 7
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
    $null = Get-MgIdentityGovernanceAccessReviewDefinition -Top 1 -ErrorAction Stop
} catch {
    Write-Status "Not connected to Microsoft Graph, or missing AccessReview.Read.All. Run Connect-MgGraph first." "ERROR"
    throw
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$findings = [System.Collections.Generic.List[object]]::new()

# ---------- Detect: review definitions ----------
Write-Status "Collecting access review definitions..."
$defs = Get-MgIdentityGovernanceAccessReviewDefinition -All

$defRows = $defs | ForEach-Object {
    [PSCustomObject]@{
        Id            = $_.Id
        DisplayName   = $_.DisplayName
        Status        = $_.Status
        AutoApply     = $_.Settings.AdditionalProperties.autoApplyDecisionsEnabled
        RecurrenceRaw = ($_.Settings.AdditionalProperties.recurrence | ConvertTo-Json -Compress -Depth 5 -ErrorAction SilentlyContinue)
    }
}
$defRows | Export-Csv "$OutputPath\review_definitions.csv" -NoTypeInformation

foreach ($def in $defRows) {
    if ($def.AutoApply -ne $true) {
        $findings.Add([PSCustomObject]@{
            Category = "AUTO_APPLY_DISABLED"
            Object   = $def.DisplayName
            Detail   = "Auto-apply is off — completed reviews require manual applyDecisions action to change access"
        })
    }
}

# ---------- Detect: instance status + decision completion ----------
Write-Status "Collecting instance status and decision completion per definition..."
$instanceRows = [System.Collections.Generic.List[object]]::new()
$decisionSummaryRows = [System.Collections.Generic.List[object]]::new()

foreach ($def in $defs) {
    try {
        $instances = Get-MgIdentityGovernanceAccessReviewDefinitionInstance -AccessReviewScheduleDefinitionId $def.Id -All
    } catch {
        Write-Status "Could not get instances for '$($def.DisplayName)': $_" "WARN"
        continue
    }

    foreach ($inst in $instances) {
        $instanceRows.Add([PSCustomObject]@{
            DefinitionName = $def.DisplayName
            DefinitionId   = $def.Id
            InstanceId     = $inst.Id
            Status         = $inst.Status
            StartDateTime  = $inst.StartDateTime
            EndDateTime    = $inst.EndDateTime
        })

        try {
            $decisions = Get-MgIdentityGovernanceAccessReviewDefinitionInstanceDecision `
                -AccessReviewScheduleDefinitionId $def.Id -AccessReviewInstanceId $inst.Id -All
        } catch {
            Write-Status "Could not get decisions for instance $($inst.Id): $_" "WARN"
            continue
        }

        $total = $decisions.Count
        $reviewed = ($decisions | Where-Object { $_.Decision -and $_.Decision -ne "NotReviewed" }).Count
        $approved = ($decisions | Where-Object Decision -eq "Approve").Count
        $denied = ($decisions | Where-Object Decision -eq "Deny").Count

        $decisionSummaryRows.Add([PSCustomObject]@{
            DefinitionName = $def.DisplayName
            InstanceId     = $inst.Id
            Status         = $inst.Status
            Total          = $total
            Reviewed       = $reviewed
            Approved       = $approved
            Denied         = $denied
            NotReviewed    = $total - $reviewed
        })

        # Flag stalled/low-response instances: InProgress, past halfway to end date, low response rate
        if ($inst.Status -eq "InProgress" -and $inst.EndDateTime) {
            $now = Get-Date
            $end = [datetime]$inst.EndDateTime
            $start = if ($inst.StartDateTime) { [datetime]$inst.StartDateTime } else { $end.AddDays(-14) }
            $totalWindow = ($end - $start).TotalHours
            $elapsed = ($now - $start).TotalHours
            if ($totalWindow -gt 0 -and ($elapsed / $totalWindow) -gt 0.5 -and $total -gt 0 -and ($reviewed / $total) -lt 0.25) {
                $findings.Add([PSCustomObject]@{
                    Category = "STALLED_REVIEW_INSTANCE"
                    Object   = "$($def.DisplayName) / instance $($inst.Id)"
                    Detail   = "Past halfway to end date with only $reviewed of $total ($([math]::Round(($reviewed/$total)*100))%) decisions recorded — check reviewer availability/fallback"
                })
            }
        }

        if ($inst.Status -eq "Completed" -and $denied -gt 0 -and $def.Settings.AdditionalProperties.autoApplyDecisionsEnabled -ne $true) {
            $findings.Add([PSCustomObject]@{
                Category = "UNAPPLIED_DENY_DECISIONS"
                Object   = "$($def.DisplayName) / instance $($inst.Id)"
                Detail   = "$denied Deny decision(s) recorded but auto-apply is off — verify results were manually applied"
            })
        }
    }
}
$instanceRows | Export-Csv "$OutputPath\review_instances.csv" -NoTypeInformation
$decisionSummaryRows | Export-Csv "$OutputPath\decision_summaries.csv" -NoTypeInformation

# ---------- Detect: on-prem synced group scope (remediation gap) ----------
Write-Status "Cross-referencing reviewed groups against on-premises sync state..."
try {
    $allGroups = Get-MgGroup -All -Property Id,DisplayName,OnPremisesSyncEnabled
    $syncedGroupIds = ($allGroups | Where-Object OnPremisesSyncEnabled -eq $true).Id

    foreach ($def in $defs) {
        $scopeJson = $def.Scope.AdditionalProperties | ConvertTo-Json -Compress -Depth 5 -ErrorAction SilentlyContinue
        if ($scopeJson) {
            foreach ($gid in $syncedGroupIds) {
                if ($scopeJson -match [regex]::Escape($gid)) {
                    $groupName = ($allGroups | Where-Object Id -eq $gid).DisplayName
                    $findings.Add([PSCustomObject]@{
                        Category = "REVIEW_TARGETS_SYNCED_GROUP"
                        Object   = "$($def.DisplayName) → $groupName"
                        Detail   = "Review scope includes an on-prem AD-synced group — Deny decisions will NOT auto-remediate unless group writeback is configured"
                    })
                }
            }
        }
    }
} catch {
    Write-Status "Could not cross-reference group sync state: $_" "WARN"
}

# ---------- Detect: applications not reviewable ----------
Write-Status "Checking for applications with assignment enforcement disabled (not reviewable)..."
try {
    $apps = Get-MgServicePrincipal -All -Property Id,DisplayName,AppRoleAssignmentRequired,ServicePrincipalType |
        Where-Object { $_.ServicePrincipalType -eq "Application" }
    $apps | Select-Object DisplayName, AppRoleAssignmentRequired | Export-Csv "$OutputPath\app_reviewability_gate.csv" -NoTypeInformation

    $notReviewable = $apps | Where-Object { -not $_.AppRoleAssignmentRequired }
    Write-Status "$($notReviewable.Count) of $($apps.Count) enterprise apps have AppRoleAssignmentRequired = false (not individually reviewable)" "INFO"
    # Not added to findings individually — this is often intentional (SSO apps meant to be open) and
    # would flood the findings list; the CSV export is the source of truth for follow-up.
} catch {
    Write-Status "Could not enumerate service principals: $_" "WARN"
}

# ---------- Detect: recent audit log activity ----------
Write-Status "Collecting AccessReviews audit log activity (last $AuditLogDays days)..."
try {
    $since = (Get-Date).AddDays(-$AuditLogDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
    Get-MgAuditLogDirectoryAudit -Filter "category eq 'AccessReviews' and activityDateTime ge $since" -All |
        Select-Object ActivityDisplayName, ActivityDateTime, Result, @{N="Target";E={$_.TargetResources.DisplayName -join ", "}} |
        Export-Csv "$OutputPath\audit_log_recent.csv" -NoTypeInformation
} catch {
    Write-Status "Could not query audit log (requires AuditLog.Read.All): $_" "WARN"
}

# ---------- Report ----------
$findings | Export-Csv "$OutputPath\findings_summary.csv" -NoTypeInformation

Write-Status "----------------------------------------" "OK"
Write-Status "Audit complete: $OutputPath" "OK"
Write-Status "Total findings flagged for review: $($findings.Count)" "OK"
if ($findings.Count -gt 0) {
    $findings | Group-Object Category | Select-Object Name, Count | Sort-Object Count -Descending | Format-Table -AutoSize
}
Write-Status "Files written: $(Get-ChildItem $OutputPath | Measure-Object | Select-Object -ExpandProperty Count)" "OK"
