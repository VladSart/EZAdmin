# Microsoft Sentinel Logic Apps Playbooks — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Scope note:** This covers the SOAR execution layer — automation rules triggering Logic Apps playbooks, connector authentication to Sentinel, and throttling. If alerts/incidents aren't being created at all, that's `AnalyticsRules-B.md`, not this file. If data isn't flowing into the workspace in the first place, that's `DataConnectors-B.md`.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

```kusto
// 1 — Automation rule run outcomes in the last 24h (requires SentinelHealth feature turned on)
SentinelHealth
| where TimeGenerated > ago(24h)
| where OperationName == "Automation rule run"
| project TimeGenerated, SentinelResourceName, Status, Description
| order by TimeGenerated desc

// 2 — Playbook trigger attempts and their immediate success/failure
SentinelHealth
| where TimeGenerated > ago(24h)
| where OperationName == "Playbook was triggered"
| project TimeGenerated, SentinelResourceName, Status, Description
| order by TimeGenerated desc

// 3 — What actually happened INSIDE the playbook run (requires Logic App diagnostics -> Log Analytics enabled)
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where OperationName in ("Microsoft.Logic/workflows/workflowRunCompleted", "Microsoft.Logic/workflows/workflowActionCompleted")
| where status_s != "Succeeded"
| project TimeGenerated, resource_workflowName_s, resource_actionName_s, status_s, OperationName
| order by TimeGenerated desc

// 4 — Correlate: automation rule fired -> did the underlying playbook run actually succeed?
SentinelHealth
| where SentinelResourceType == "Automation rule"
| mv-expand TriggeredPlaybooks = ExtendedProperties.TriggeredPlaybooks
| extend runId = tostring(TriggeredPlaybooks.RunId)
| join kind=leftouter (
    AzureDiagnostics
    | where OperationName == "Microsoft.Logic/workflows/workflowRunCompleted"
    | project resource_runId_s, playbookName = resource_workflowName_s, playbookRunStatus = status_s)
    on $left.runId == $right.resource_runId_s
| project TimeGenerated, SentinelResourceName, Status, runId, playbookName, playbookRunStatus
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| "Automation rule run" = Failure, before any playbook triggers | Rule condition logic never matched, or the first action itself failed | Fix 1 |
| "Automation rule run" = Success/Partial success, but "Playbook was triggered" = Failure | Playbook couldn't be triggered — permissions, trigger type mismatch, or the playbook resource itself | Fix 2 |
| "Playbook was triggered" = Success, but no matching `AzureDiagnostics` row, or `playbookRunStatus` = Failed | The playbook ran but an action inside it failed — connector auth, throttling, or bad logic inside the workflow | Fix 3 / Fix 4 |
| Playbook actions show repeated `429` status codes in run history | Connector or destination-system throttling | Fix 5 |
| Playbook worked yesterday, fails today with an auth/connection error | Expired credential, revoked managed identity role, or admin who owned the connection left | Fix 6 |
| No `SentinelHealth` rows at all for this rule | Health monitoring feature not turned on for the workspace | Enable it first — see Validation Step 1 |

---
## Dependency Cascade

<details><summary>What must be true for an incident to trigger a working playbook action</summary>

```
[Analytics rule fires an alert / groups into an incident]
        │
        ▼
[Automation rule: conditions evaluated against the incident/alert]
        │  (Failure here = conditions never matched, or first action failed outright)
        ▼
[Automation rule action: "Run playbook"]
        │  requires: correct trigger type on the target playbook
        │            (Incident-triggered rule -> Sentinel Incident trigger playbook;
        │             Alert-triggered rule -> Sentinel Alert trigger playbook — these do NOT mix)
        ▼
[Microsoft Sentinel has permission to run this specific Logic App]
        │  (Sentinel Automation Contributor-style role grant on the playbook resource,
        │   OR the newer per-playbook "Microsoft Sentinel Playbook Contributor" ARM permission
        │   — a playbook built before the permissions model migration needs re-saving)
        ▼
[Logic App resource itself: enabled, not in a locked/read-only subscription, no IP restriction blocking Sentinel]
        │
        ▼
[Workflow run starts — trigger fires]
        │
        ▼
[Each action's own connector authenticates independently]
        │  Managed identity (Preview) | Service principal (Entra app) | Entra user sign-in
        │  Each connector = its own API Connection resource with its own credential lifecycle
        ▼
[Connector calls destination (Teams, Exchange, ITSM, firewall API, etc.)]
        │  subject to: Logic Apps resource-level throughput limits,
        │              per-connector throttling limits (varies by connector),
        │              destination system's own rate limits
        ▼
[Action succeeds -> workflow run completes -> incident updated/ticket created/etc.]
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm health monitoring is actually on**
```
Sentinel portal → Settings → Settings tab → Health feature toggle
```
If off, `SentinelHealth` table won't exist yet — first success/failure event creates it. Turn on before relying on any query above.

**Step 2 — Confirm Logic App diagnostics are wired to the same workspace**
```
Logic App resource → Diagnostic settings → confirm a setting sends to your Sentinel-linked Log Analytics workspace
```
Bad: no diagnostic setting exists → you'll see the automation rule "triggered the playbook" but have zero visibility into what happened inside it. This is the single most common blind spot in playbook troubleshooting.

**Step 3 — Check automation rule trigger-type match**
```
Automation rule → Actions → Run playbook → confirm listed playbooks
```
If a playbook doesn't appear in the picker at all (not just greyed out), its trigger type doesn't match the rule's trigger (Incident vs Alert) — this is a silent mismatch, not an error message.

**Step 4 — Check Sentinel's permission on the specific playbook**
```powershell
Get-AzRoleAssignment -Scope "<logic-app-resource-id>" | Where-Object { $_.RoleDefinitionName -match "Sentinel" }
```
Bad: no role assignment for the Sentinel service, or the playbook predates the current permissions model (older playbooks sometimes need the automation rule re-saved after granting access to re-register the trigger permission).

**Step 5 — Check the workflow run history directly in Logic Apps**
```
Logic App resource → Overview → Run history → select the failing run → expand the failed action
```
Look at Inputs/Outputs and the retry count. A `429` status with multiple retry attempts logged = throttling, not a broken workflow.

**Step 6 — Check the specific connector's API connection**
```
Azure portal → search "API connections" → filter by the Logic App's resource group
```
Bad: Status = "Error" or "Unauthenticated" → the credential behind that specific connector (not the Logic App itself) has expired or been revoked.

---
## Common Fix Paths

<details>
<summary>Fix 1 — Automation rule shows Failure before any playbook runs</summary>

```kusto
SentinelHealth
| where OperationName == "Automation rule run"
| where Status == "Failure"
| project TimeGenerated, SentinelResourceName, Description
```
Read `Description` — it will say either "Conditions evaluation failed" (rule logic never matched this incident's properties — check the rule's conditions against the actual incident fields) or "Conditions met, but the first action failed" (the first action, not necessarily the playbook step, errored — check if the first action is a different type like "add task" or "change status").

**Rollback:** none — this is read-only diagnosis. Fix is editing the automation rule's conditions/action order in the portal.
</details>

<details>
<summary>Fix 2 — Playbook could not be triggered (automation rule succeeded, playbook trigger failed)</summary>

Cross-reference the exact error text against these known causes:

| Error text contains | Cause | Fix |
|---|---|---|
| "unsupported trigger type" | Playbook's first trigger isn't the Sentinel Incident/Alert trigger | Open playbook in designer, confirm trigger, rebuild if it's a generic HTTP trigger |
| "missing permissions on it" / "wasn't migrated to new permissions model" | Sentinel's service identity was never granted access to this specific Logic App | Grant access (see below), then **re-save the automation rule** — permission grants alone don't retroactively fix already-saved rule references |
| "playbook was disabled" | Logic App resource itself is turned off | Re-enable in Logic Apps resource page or Sentinel's Active Playbooks tab |
| "subscription is disabled and marked as read-only" | Subscription-level billing/compliance hold | Escalate to whoever owns the subscription — not fixable from Sentinel |
| "Access control configuration restricts Microsoft Sentinel" | Logic App has an IP restriction blocking Sentinel's service traffic | Remove or widen the IP restriction on the Logic App |
| "subscription or resource group was locked" | An ARM resource lock (CanNotDelete/ReadOnly) is blocking the trigger call | Remove or scope the lock away from the playbook resource |

```powershell
# Grant Sentinel permission to run a specific playbook (via Azure RBAC on the Logic App resource)
New-AzRoleAssignment -ObjectId "<sentinel-service-principal-object-id>" `
    -RoleDefinitionName "Microsoft Sentinel Automation Contributor" `
    -Scope "<logic-app-resource-id>"
```
After granting, re-open the automation rule, remove and re-add the "Run playbook" action referencing the same playbook, then save — this forces Sentinel to re-register the trigger link.

**Rollback:** role grant is additive/non-destructive; remove the role assignment to revert.
</details>

<details>
<summary>Fix 3 — Playbook triggered successfully but the workflow run itself failed</summary>

```
Logic App → Run history → select run → find the red (failed) action
```
Check the action's Inputs/Outputs pane for the actual downstream error (e.g., a Teams webhook returning 403, a ServiceNow API returning a validation error). This is almost never a Sentinel-side problem once the trigger succeeded — the fault is inside the workflow logic or its downstream target.

**Rollback:** none — this is diagnosis. Fix depends entirely on what the specific action's error says.
</details>

<details>
<summary>Fix 4 — Connector-level failure inside a working playbook</summary>

```
Azure portal → API connections → locate the connector used by the failing action → check Status
```
```powershell
# List all API connections in the Logic App's resource group
Get-AzResource -ResourceGroupName "<rg>" -ResourceType "Microsoft.Web/connections" |
    Select-Object Name, @{N='Status';E={(Get-AzResource -ResourceId $_.ResourceId -ExpandProperties).Properties.overallStatus}}
```
If Status shows an auth error, re-authenticate the connection (Edit API connection → re-enter credentials or re-sign in). This does not require touching the workflow definition itself — API connections are separate resources referenced by the workflow.

**Rollback:** none — reauthenticating a connection doesn't alter workflow logic or past run history.
</details>

<details>
<summary>Fix 5 — Repeated 429 (throttling) on a playbook action</summary>

Identify which of the three throttling layers is actually hit:

1. **Logic App resource throughput limit** — check Logic App → Metrics → add "Action Throttled Events" and "Trigger Throttled Events" (Count aggregation). If these are non-zero, the *whole Logic App resource* is capped, not just one connector.
   - Fix: turn on High Throughput mode (Consumption plan), or limit concurrent trigger instances via the trigger's concurrency control.
2. **Connector-level throttling** — each connector (SQL, Service Bus, Teams, etc.) has its own published limit on its Microsoft connector reference page. Check the failing action's retry history for the specific 429.
   - Fix: use a customized [retry policy](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-exception-handling#retry-policies) on the action, split the workload across multiple connections/credentials to the same destination, or reduce **For each** loop concurrency.
3. **Destination system throttling** — the connector itself isn't capped, but the underlying service (e.g., Exchange Server behind the Outlook connector) is. Multiple parallel workflow instances hitting the same endpoint at once compounds this via race conditions.
   - Fix: refactor into a parent/child workflow pattern (parent enqueues, single child processes sequentially), or switch polling triggers to webhook-based triggers where the connector supports it.

**Rollback:** all of the above are configuration changes to the workflow definition, not destructive operations — but test in a non-prod copy of the playbook first if the workflow drives ticket creation, to avoid duplicate tickets during retry-storm cleanup.
</details>

<details>
<summary>Fix 6 — Playbook broke after previously working (credential/ownership change)</summary>

This is the classic MSP scenario: the analyst who authenticated a connector (especially "Sign in as a user" auth) left the org, and their token/session is now invalid.

```
API connections → locate connection → Status = Error/Unauthenticated
```

**Preferred long-term fix:** migrate the connection to managed identity or a dedicated service principal instead of a named user account — see `LogicAppsPlaybooks-A.md` Playbook 3.

**Immediate fix:** re-authenticate using a service account or current admin, understanding this is a stopgap:
```
API connection resource → Edit API connection → re-enter credentials / re-sign in → Save
```

**Rollback:** none needed — re-authentication doesn't affect workflow definitions or history.
</details>

---
## Escalation Evidence

```
=== SENTINEL PLAYBOOK / AUTOMATION ESCALATION ===
Date/Time            :
Engineer             :
Ticket               :

Automation Rule Name :
Playbook (Logic App) :
Incident/Alert ID    :

SentinelHealth "Automation rule run" Status  :
SentinelHealth "Playbook was triggered" Status:
Logic App Run ID (from AzureDiagnostics join) :
Logic App Run Status (Succeeded/Failed)       :
Failing Action Name  :
Failing Action Error (verbatim from run history):

Connector Involved   :
API Connection Status:
Throttling Observed (Y/N, which layer)        :

Steps Attempted:
1.
2.
3.

Expected behaviour : Playbook completes and takes its documented remediation/notification action
Actual behaviour   :
```

---
## 🎓 Learning Pointers

- **"Playbook was triggered: Success" only means the trigger fired — not that the playbook did anything useful.** `SentinelHealth` tells you Sentinel's side of the handoff; you need Logic Apps diagnostics in the *same* workspace to see what happened inside the run. Wire both up before you need them. [Monitor automation health](https://learn.microsoft.com/en-us/azure/sentinel/monitor-automation-health)
- **Trigger-type mismatch is silent, not an error.** An incident-triggered automation rule simply won't list an alert-triggered playbook as an option — there's no error message, the playbook just doesn't appear in the picker. Always confirm the playbook's first trigger before debugging further. [Playbook triggers and actions](https://learn.microsoft.com/en-us/azure/sentinel/automation/playbook-triggers-actions)
- **Permission grants and rule saves are two separate steps.** Granting Sentinel's identity a role on a Logic App does not retroactively repair an automation rule that already references it — the rule (or at minimum the action) needs to be re-saved to re-register the trigger permission, especially on playbooks that predate the current permissions model. [Authenticate playbooks to Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/automation/authenticate-playbooks-to-sentinel)
- **Throttling has three independent layers (resource, connector, destination) and they look identical from a 429 error alone.** Diagnose which layer via Metrics (resource-level) vs. run-history retry details (connector-level) vs. timing math (destination-level) before picking a fix — the fixes for each layer don't overlap. [Handle throttling problems](https://learn.microsoft.com/en-us/azure/logic-apps/handle-throttling-problems-429-errors)
- **Named-user authentication ("Sign in") on a Sentinel connector is an operational liability in MSP environments** — it silently breaks the moment that person's account is disabled, offboarded, or has MFA/CA policy changes applied. Managed identity or a dedicated service principal survives personnel changes; a signed-in user's session does not.
- **Community resource:** the [Microsoft Sentinel Tech Community blog](https://techcommunity.microsoft.com/category/azure-sentinel) and r/AzureSentinel regularly cover playbook permission-model changes (the migration away from legacy Logic Apps Contributor-only access) before Microsoft Learn fully catches up.
