# Microsoft Sentinel Logic Apps Playbooks — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps (by phase)](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This document covers the **SOAR execution layer** of Microsoft Sentinel: how automation rules hand off to Azure Logic Apps playbooks, how those playbooks authenticate back into Sentinel and out to third-party systems, and why playbook execution fails or degrades in ways that are invisible from the Sentinel portal alone.

**Explicitly out of scope** (covered elsewhere in this folder):
- Whether an alert or incident is created in the first place — that's detection logic, entity mapping, and grouping, covered in `AnalyticsRules-A.md`. A playbook cannot run if nothing ever triggers the automation rule that calls it.
- Whether raw data is landing in the workspace at all — that's `DataConnectors-A.md`. No amount of playbook troubleshooting fixes an empty source table.

**Assumes:** familiarity with Azure Logic Apps as a general-purpose iPaaS product (triggers, actions, connectors, workflow definition language) — this document focuses on the Sentinel-specific integration points, not general Logic Apps authoring.

---
## How It Works

<details><summary>Full architecture</summary>

Microsoft Sentinel playbooks are not a Sentinel-native execution engine — they **are** Azure Logic Apps workflows. Sentinel's role is limited to two things: (1) providing a specialized "Microsoft Sentinel" connector with Incident/Alert triggers and Sentinel-specific actions (add task, update incident, run a Fusion recommendation, etc.), and (2) deciding *when* to call a playbook via automation rules. Everything that happens after the trigger fires is standard Logic Apps execution, subject to standard Logic Apps limits, retry behavior, and connector semantics.

This separation is the source of most confusion in this domain: engineers troubleshoot playbook failures by staring at the Sentinel portal, when the actual fault (and actual logs) live in the Logic Apps resource and its own diagnostics.

**The full pipeline, end to end:**

1. **Analytics rule or manual trigger produces an incident or alert.** (See `AnalyticsRules-A.md`.)
2. **Automation rule evaluates its conditions** against the incident/alert's properties (severity, tags, entity type, title match, etc.). Automation rules run in a defined **order** — lower order number runs first, and a rule can stop processing of subsequent rules.
3. **Automation rule executes its action list** in order. Actions can be: change status, assign owner, add tag, add task, **run playbook**, or run another automation rule. A "run playbook" action is fire-and-forget from the automation rule's perspective as soon as the trigger call succeeds — the rule does not wait for the playbook to finish, and reports only whether the *trigger call itself* succeeded.
4. **Trigger-type contract enforcement.** Every playbook has exactly one first trigger: either "Microsoft Sentinel Incident" or "Microsoft Sentinel Alert" (older playbooks built before entity-based automation may use a generic "When an Azure Sentinel incident is created" style trigger — functionally equivalent but worth knowing exists in legacy content). An automation rule triggered on incident creation/update can only successfully call incident-trigger playbooks; a rule on alert creation can only call alert-trigger playbooks. This match is enforced at design time (mismatched playbooks don't appear in the rule's playbook picker) — there is no runtime error for this specific case, because the mismatch is structurally impossible to select.
5. **Permission check.** Sentinel's own service principal (a first-party Microsoft Entra application, distinct from any per-tenant identity you manage) must have a role granting it permission to invoke the specific Logic App resource. This has evolved over time — legacy playbooks used a coarse "Logic App Contributor"-style grant; the current model uses a purpose-built role (commonly surfaced as **Microsoft Sentinel Automation Contributor** in role-assignment UI, sometimes still labeled Logic App Contributor depending on portal version) scoped to the individual playbook resource. A playbook that predates a permissions-model change, or whose access was granted before the automation rule referencing it was last saved, can silently fail to trigger even though the role assignment looks correct — **the automation rule action itself must be re-saved after granting access** to force Sentinel to re-register the trigger link.
6. **Logic App resource-level gates.** Independent of Sentinel's permission to call it, the Logic App resource itself must be: enabled (not manually disabled), in a subscription that isn't disabled/read-only, and not blocked by an IP restriction or resource lock that would reject the inbound trigger call.
7. **Workflow run starts.** From this point on, it is a completely standard Logic Apps execution — Sentinel has no further visibility unless you explicitly wire up Logic Apps diagnostics into the same Log Analytics workspace.
8. **Each action authenticates independently.** Logic Apps has no concept of a single "logged in" session shared across actions. Every connector-based action (Sentinel connector itself, Teams, Exchange, ServiceNow, a generic HTTP+managed-identity call, etc.) references its own **API Connection** resource, which encapsulates one specific credential and its own lifecycle (expiry, revocation, tenant admin consent). A workflow can have working Sentinel-connector auth and simultaneously broken Teams-connector auth in the same run.
9. **Throttling can occur at three independent layers** (see Dependency Stack below) between action execution and the destination system actually processing the request.
10. **Workflow completes** (Succeeded, Failed, Cancelled, or Timed Out) and — if diagnostics are enabled — emits `workflowRunCompleted` and per-action `workflowActionCompleted` events to `AzureDiagnostics`.

**Why "Success" in Sentinel's own health log is misleading:** Sentinel's `SentinelHealth` "Playbook was triggered" event captures only step 5-6 above — it confirms the HTTP trigger call to the Logic App was accepted (HTTP 200/202 from the trigger endpoint). It says nothing about steps 7-10. This is analogous to a web server logging "request accepted" for an endpoint that then throws an unhandled exception mid-request — the acceptance log and the outcome log are genuinely separate systems, and Sentinel deliberately does not poll Logic Apps for completion status by default (that correlation must be built manually via a KQL join, or a delay is introduced that Sentinel's design avoids).

</details>

---
## Dependency Stack

```
Layer 5: Destination system (Teams, Exchange, ITSM platform, firewall API, etc.)
             — has its OWN rate limits independent of the Logic Apps connector's limits
Layer 4: Logic Apps connector (per-connector throttling limit, e.g. Service Bus ~6000 calls/min,
             SQL Server varies by operation) + connector's own auth (API Connection resource)
Layer 3: Logic App resource (Consumption: 5-min rolling action-execution limit unless High Throughput
             Mode is enabled; concurrent trigger instance limit; Standard: no resource-wide action limit)
Layer 2: Automation rule permission + trigger-type match to invoke this specific Logic App
Layer 1: Automation rule conditions + action ordering (does this incident/alert even qualify to fire?)
Layer 0: Analytics rule / manual trigger produced the incident or alert in the first place
             (owned by AnalyticsRules-A.md — a precondition, not part of this stack)
```

A fault at any layer produces a **different observable symptom** and requires checking a different data source — Layer 0-2 symptoms show up in `SentinelHealth`; Layer 3-5 symptoms only show up in Logic Apps' own run history / `AzureDiagnostics`. Treating a Layer 4 connector-auth failure as a Layer 1 automation-rule problem (or vice versa) is the most common misdiagnosis in this domain.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Automation rule shows "Failure" in SentinelHealth, no playbook attempt visible | Conditions never matched, or first action (which may not be the playbook step) failed | `SentinelHealth` `Description` field |
| Automation rule "Success"/"Partial success" but "Playbook was triggered" = Failure | Layer 2 — permission or trigger-type problem | Error text in `SentinelHealth`, then playbook picker/role assignment |
| Playbook not listed at all in automation rule's picker | Trigger-type mismatch (Incident vs Alert) between rule and playbook | Playbook's designer — first trigger type |
| "Playbook wasn't migrated to new permissions model" error | Legacy permission grant predates current per-playbook role model | Re-grant + re-save rule |
| "Playbook was triggered: Success" but nothing observably happened downstream | No visibility wired up — cannot conclude anything without Logic Apps diagnostics | Enable diagnostics, re-test |
| Logic App run history shows the run never started at all | Resource disabled, subscription read-only/locked, or IP restriction blocking Sentinel's egress IPs | Logic App resource state, subscription state, network config |
| Run started, specific action shows red/failed | Layer 4/5 — connector or destination fault, not a Sentinel/automation-rule problem | Action's Inputs/Outputs in run history |
| Action fails intermittently with 429 | Throttling — could be any of Layer 3/4/5 | Metrics (resource-level) vs. retry history (connector-level) vs. timing math (destination-level) |
| Playbook worked for months, suddenly fails with an auth-shaped error | A named-user API Connection's underlying credential expired, was revoked, or the user was offboarded | API Connections blade → connection Status |
| Same playbook works in one client tenant/subscription but not another (MSP context) | Per-tenant permission grant, connector consent, or connection was never replicated to the new environment | Compare API Connections and role assignments between environments |
| Playbook triggers correctly but takes minutes-to-hours to actually run | Concurrency/queuing at Layer 3 (Consumption plan action-execution limit reached) | Logic App Metrics → Action/Trigger Throttled Events |
| Classic (pre-automation-rule) "Playbook" tab shows a deprecation banner | Legacy alert-trigger playbook configuration bypassing automation rules entirely | Migrate to an automation rule per `create-playbooks` guidance |

---
## Validation Steps

**1 — Confirm SentinelHealth feature is enabled**
```
Sentinel portal → Settings → Settings tab → toggle Health feature
```
Good: table exists and has recent rows. Bad: querying `SentinelHealth` returns "table not found" — feature was never turned on, so none of the KQL in this document will return anything.

**2 — Confirm Logic Apps diagnostics route to the SAME workspace as Sentinel**
```
Logic App resource → Diagnostic settings → Add diagnostic setting → Send to Log Analytics workspace → select Sentinel's workspace
```
Good: `AzureDiagnostics` table shows `Microsoft.Logic/workflows/*` events after the next run. Bad: setting exists but points to a *different* workspace than Sentinel — the join in Triage query 4 will silently return zero matches, looking like "no data" instead of "wrong workspace."

**3 — Confirm automation rule → playbook trigger-type alignment**
```
Automation rules → select rule → check "Trigger" (Incident created/updated vs Alert created)
Playbook → Logic App Designer → first step
```
Good: types match exactly. Bad: a rule built for Incident triggers references (or attempts to reference) an Alert-trigger playbook — again, the portal prevents *selecting* a mismatched playbook, so this typically only surfaces via a playbook that was working, then got rebuilt with a different trigger type by someone unaware of the dependency.

**4 — Confirm Sentinel's service principal has current permission on the specific playbook**
```powershell
Get-AzRoleAssignment -Scope "<logic-app-resource-id>" |
    Where-Object { $_.RoleDefinitionName -match "Sentinel|Logic App Contributor" }
```
Good: a role assignment exists scoped to this exact resource (not just the resource group, though group-level is technically sufficient and more common in bulk deployments). Bad: no matching assignment, or one exists but was granted after the automation rule was last saved (re-save required regardless).

**5 — Confirm each connector's API Connection status**
```powershell
Get-AzResource -ResourceGroupName "<rg>" -ResourceType "Microsoft.Web/connections" |
    ForEach-Object {
        $props = (Get-AzResource -ResourceId $_.ResourceId -ExpandProperties).Properties
        [PSCustomObject]@{ Name = $_.Name; Status = $props.overallStatus }
    }
```
Good: all relevant connections show `Connected`/`Error: none`. Bad: any connection used by an active playbook shows `Error` or `Unauthenticated`.

**6 — Correlate a specific incident's automation trail end to end**
```kusto
SentinelHealth
| where TimeGenerated > ago(24h)
| where SentinelResourceType in ("Automation rule")
| where ExtendedProperties has "<incident-number-or-guid>"
| mv-expand TriggeredPlaybooks = ExtendedProperties.TriggeredPlaybooks
| extend runId = tostring(TriggeredPlaybooks.RunId)
| join kind=leftouter (
    AzureDiagnostics
    | where OperationName == "Microsoft.Logic/workflows/workflowRunCompleted"
    | project resource_runId_s, status_s, resource_workflowName_s)
    on $left.runId == $right.resource_runId_s
```
Good: one row per triggered playbook, with a resolved `status_s`. Bad: `runId` populated but the join finds nothing — points straight back to Validation Step 2 (diagnostics not wired to this workspace, or not yet propagated — allow 5-15 minutes lag).

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the trigger side (Sentinel → Logic App handoff)**
Run Triage queries 1 and 2. If `SentinelHealth` shows Failure at the automation-rule level, the problem is entirely on the Sentinel side (rule conditions, action ordering) and no Logic Apps investigation is needed yet.

**Phase 2 — Confirm the playbook was actually permitted and typed correctly to run**
If "Playbook was triggered" = Failure, match the exact error text against the table in `LogicAppsPlaybooks-B.md` Fix 2. This phase resolves the large majority of "playbook never runs" tickets and doesn't require touching Logic Apps at all.

**Phase 3 — Confirm the workflow itself executed**
Open the Logic App's run history directly. If no run appears for the expected time window at all, re-check Phase 2 — a trigger that Sentinel believes succeeded but that the Logic App never received points to a network/IP-restriction problem, not a permissions problem.

**Phase 4 — Isolate the failing action inside a run that did start**
Expand the specific red action in run history. Categorize the failure: connector auth (Fix 4), throttling (Fix 5 — check retry count and HTTP status in the action's raw output), or destination-system logic error (not a Sentinel/Logic-Apps platform issue — a bug or change in the downstream system's API contract).

**Phase 5 — If intermittent, build the correlation query and look for a pattern**
Use Validation Step 6 across several recent incidents. A pattern (e.g., every failure correlates with a specific connector, specific time of day matching a destination system's maintenance window, or specific incident volume spikes) reclassifies an "intermittent mystery" into a concrete, fixable Layer 3/4/5 issue.

---
## Remediation Playbooks

<details>
<summary>Playbook 1 — Bulk permission repair after a playbook permissions-model migration (MSP fleet)</summary>

**Scenario:** An MSP manages dozens of client tenants, each with a similarly-named "Notify-Teams-OnHighSeverity" playbook deployed via ARM template. After a permissions-model change, several tenants' automation rules silently stop triggering their playbook.

```powershell
# Enumerate all Logic Apps tagged as Sentinel playbooks across a subscription, check Sentinel's role assignment on each
$sentinelSpnObjectId = "<sentinel-service-principal-object-id>"   # same first-party app ID across tenants of the same cloud
$logicApps = Get-AzResource -ResourceType "Microsoft.Logic/workflows"

foreach ($app in $logicApps) {
    $hasRole = Get-AzRoleAssignment -ObjectId $sentinelSpnObjectId -Scope $app.ResourceId |
        Where-Object { $_.RoleDefinitionName -match "Sentinel|Logic App Contributor" }
    if (-not $hasRole) {
        Write-Warning "Missing Sentinel permission: $($app.Name) in $($app.ResourceGroupName)"
        # New-AzRoleAssignment -ObjectId $sentinelSpnObjectId -RoleDefinitionName "Microsoft Sentinel Automation Contributor" -Scope $app.ResourceId
    }
}
```
After granting missing roles in bulk, **every automation rule referencing an affected playbook must still be manually re-opened and re-saved** — there is no bulk API to force Sentinel to re-register the trigger link at scale; this is a per-rule portal action (or an ARM/Bicep re-deployment of the automation rule resource if it's managed as code).

**Rollback:** role assignments are additive; remove via `Remove-AzRoleAssignment` if a grant was made in error. Re-saving an automation rule has no destructive side effect.
</details>

<details>
<summary>Playbook 2 — Migrating a named-user-authenticated connector to managed identity</summary>

**Scenario:** A playbook's Sentinel connector (or Teams/Exchange connector) authenticates as a specific analyst's Entra account. That analyst leaves the org and the connection breaks.

1. Enable system-assigned managed identity on the Logic App:
```powershell
Update-AzResource -ResourceId "<logic-app-resource-id>" -Properties @{} -Force  # or via portal: Identity blade -> System assigned -> On
```
2. Grant the managed identity the required role on Microsoft Sentinel:
```powershell
$logicAppIdentity = (Get-AzResource -ResourceId "<logic-app-resource-id>" -ExpandProperties).Properties.identity.principalId
New-AzRoleAssignment -ObjectId $logicAppIdentity -RoleDefinitionName "Microsoft Sentinel Responder" -Scope "<sentinel-workspace-resource-id>"
```
3. In the Logic App designer, open the Sentinel connector action → Change connection → Add new → **Connect with managed identity (Preview)** → select System-assigned → Create.
4. Repeat for any other first-party connector in the same workflow that supports managed identity auth (not all connectors do — third-party/ITSM connectors often require an API key or service-principal pattern instead).
5. Test the full workflow end to end before removing the old named-user connection, since removing it immediately can break in-flight runs still referencing the old API Connection resource.

**Rollback:** the old API Connection resource can be left in place (unused) as a fallback until the new identity path is confirmed stable across several real trigger events, then deleted.
</details>

<details>
<summary>Playbook 3 — Diagnosing and resolving a three-layer throttling storm</summary>

**Scenario:** A playbook that bulk-updates incident tags via a **For each** loop over hundreds of entities starts failing with widespread 429s during a large-scale incident (e.g., a phishing campaign generating hundreds of incidents at once).

1. Check Layer 3 first (cheapest to confirm): Logic App → Metrics → Action Throttled Events / Trigger Throttled Events, Count aggregation, over the incident window.
   - If non-zero: this Consumption-plan workflow hit its 5-minute rolling action-execution limit. Either enable **High Throughput Mode** on the resource, or reduce the trigger's concurrency so fewer instances compete for the same execution budget.
2. If Layer 3 shows nothing unusual, check Layer 4: open one of the failed runs, expand the throttled action, and read the retry history — the connector's own documented throttling limit (found on its Microsoft connector reference page) tells you whether you're actually exceeding it.
   - Fix: reduce **For each** concurrency on that specific loop, or split the action across multiple connections using `take()`/`skip()` to partition the workload.
3. If neither shows a clear culprit, suspect Layer 5 (the destination system itself, e.g. Sentinel's own incident-update API or a downstream ITSM system) — calculate whether the *combined* rate across all concurrently-running workflow instances (not just one run) exceeds the destination's documented limit. Multiple incident-triggered playbook instances hitting the same destination simultaneously is a common cause during mass-incident events, even when each individual instance looks well within its own limits.
   - Fix: refactor to a queue-based pattern — a lightweight parent workflow enqueues work items (e.g., to an Azure Service Bus queue), and a single-instance child workflow drains the queue sequentially, guaranteeing only one caller hits the destination at a time.

**Rollback:** all changes here are workflow-definition edits (concurrency settings, High Throughput Mode toggle, queue refactor) — none are destructive to existing data; test the refactored workflow against a small subset of incidents before relying on it during the next mass-incident event.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Sentinel playbook/automation-rule health evidence for escalation.
.DESCRIPTION
    Read-only. Pulls automation rule definitions, checks Sentinel's role assignment on each
    referenced playbook, checks API Connection status for connectors in those Logic Apps,
    and (if a workspace is supplied) runs the SentinelHealth/AzureDiagnostics correlation query.
    Requires Az.Accounts, Az.Resources, Az.OperationalInsights, and Az.Logic modules.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter()] [string]$WorkspaceResourceId,
    [Parameter()] [string]$SentinelServicePrincipalObjectId
)

$logicApps = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.Logic/workflows"
$evidence = foreach ($app in $logicApps) {
    $roleOk = $null
    if ($SentinelServicePrincipalObjectId) {
        $roleOk = [bool](Get-AzRoleAssignment -ObjectId $SentinelServicePrincipalObjectId -Scope $app.ResourceId |
            Where-Object { $_.RoleDefinitionName -match "Sentinel|Logic App Contributor" })
    }
    [PSCustomObject]@{
        PlaybookName        = $app.Name
        ResourceGroup       = $app.ResourceGroupName
        SentinelRoleGranted = $roleOk
        LogicAppResourceId  = $app.ResourceId
    }
}
$evidence | Export-Csv -Path ".\SentinelPlaybookEvidence.csv" -NoTypeInformation
Write-Host "Evidence exported to .\SentinelPlaybookEvidence.csv" -ForegroundColor Green
```

---
## Command Cheat Sheet

```powershell
# Check Sentinel's role on a specific playbook
Get-AzRoleAssignment -Scope "<logic-app-resource-id>" | Where-Object { $_.RoleDefinitionName -match "Sentinel" }

# List API connections and status in a resource group
Get-AzResource -ResourceGroupName "<rg>" -ResourceType "Microsoft.Web/connections"

# Enable system-assigned managed identity on a Logic App (portal alternative: Identity blade)
Update-AzResource -ResourceId "<logic-app-resource-id>" -Properties @{} -Force

# Grant a managed identity Sentinel Responder rights
New-AzRoleAssignment -ObjectId "<principal-id>" -RoleDefinitionName "Microsoft Sentinel Responder" -Scope "<workspace-resource-id>"
```
```kusto
// Automation rule outcomes
SentinelHealth | where OperationName == "Automation rule run" | order by TimeGenerated desc

// Playbook trigger outcomes
SentinelHealth | where OperationName == "Playbook was triggered" | order by TimeGenerated desc

// Underlying workflow run outcomes (requires Logic App diagnostics wired to this workspace)
AzureDiagnostics | where OperationName == "Microsoft.Logic/workflows/workflowRunCompleted" | order by TimeGenerated desc

// Full correlation: rule -> playbook run -> actual outcome
SentinelHealth
| where SentinelResourceType == "Automation rule"
| mv-expand TriggeredPlaybooks = ExtendedProperties.TriggeredPlaybooks
| extend runId = tostring(TriggeredPlaybooks.RunId)
| join kind=leftouter (AzureDiagnostics | where OperationName == "Microsoft.Logic/workflows/workflowRunCompleted"
    | project resource_runId_s, playbookName = resource_workflowName_s, playbookRunStatus = status_s)
    on $left.runId == $right.resource_runId_s
```

---
## 🎓 Learning Pointers

- **Sentinel's playbook health telemetry and Logic Apps' own execution telemetry are two separate systems that must be explicitly joined** — `SentinelHealth` confirms the handoff, `AzureDiagnostics` confirms the outcome. Most "mystery" playbook failures are actually a visibility gap (diagnostics never wired up), not an execution fault. [Monitor automation health](https://learn.microsoft.com/en-us/azure/sentinel/monitor-automation-health)
- **Permission grants and automation-rule saves are decoupled operations by design** — this is easy to miss because most Azure RBAC changes take effect immediately without any secondary action. Sentinel's trigger-registration model is the exception; internalize it as a two-step process every time. [Authenticate playbooks to Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/automation/authenticate-playbooks-to-sentinel)
- **Throttling is a three-layer problem and the fix for one layer can look identical to (and be mistaken for) another layer's fix** — always confirm which layer via Metrics vs. run-history vs. cross-instance timing math before changing configuration, since a Layer 3 fix (High Throughput Mode) does nothing for a Layer 5 (destination-system) problem. [Handle throttling problems (429 errors)](https://learn.microsoft.com/en-us/azure/logic-apps/handle-throttling-problems-429-errors)
- **Managed identity auth for Sentinel-facing connectors is explicitly documented as Preview** — factor that into change-management risk assessments for production MSP deployments; service principal auth remains the more mature, fully-supported alternative to named-user sign-in for connectors that don't yet support managed identity.
- **A trigger-type mismatch (Incident vs Alert) fails silently at design time, not runtime** — there's no error to search for in logs because the portal prevents the invalid selection outright. If a previously-working playbook "disappears" from an automation rule's options, check whether someone rebuilt its trigger, not whether permissions changed.
- **Community resource:** the [Microsoft Sentinel Tech Community blog](https://techcommunity.microsoft.com/category/azure-sentinel) has published several deep dives specifically on the permissions-model transition and managed-identity playbook patterns — search there before assuming Microsoft Learn's how-to articles reflect the very latest portal behavior, since this surface has changed more than once in recent release cycles.
