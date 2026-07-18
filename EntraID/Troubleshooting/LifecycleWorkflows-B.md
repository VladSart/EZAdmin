# Entra ID Governance — Lifecycle Workflows — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Lifecycle Workflows automates joiner-mover-leaver (JML) tasks — welcome email, license assignment, group add/remove, account enable/disable/delete, Temporary Access Pass generation — on a schedule or on-demand. It layers on top of account creation (HR-driven provisioning creates the account; Lifecycle Workflows automates what happens to it afterward).

Requires **Microsoft Entra ID Governance** or **Microsoft Entra Suite** license, and the **Lifecycle Workflows Administrator** role (or an app registration with `LifecycleWorkflows.Read.All`/`.ReadWrite.All`).

```powershell
# 1. Confirm the module/connection and list workflows + basic health
Connect-MgGraph -Scopes "LifecycleWorkflows.Read.All"
Get-MgIdentityGovernanceLifecycleWorkflow -All |
  Select Id, DisplayName, Category, IsEnabled, IsSchedulingEnabled, LastModifiedDateTime

# 2. Pull the specific workflow and check its execution conditions
$wf = Get-MgIdentityGovernanceLifecycleWorkflow -LifecycleWorkflowId "<workflowId>"
$wf | Select DisplayName, IsEnabled, IsSchedulingEnabled, ExecutionConditions

# 3. Check the most recent runs for that workflow
Get-MgIdentityGovernanceLifecycleWorkflowRun -LifecycleWorkflowId "<workflowId>" -Top 5 |
  Select Id, Status, ScheduledDateTime, CompletedDateTime, FailedTasks, ProcessedUsers

# 4. Was a specific user processed, and what happened to their tasks?
Get-MgIdentityGovernanceLifecycleWorkflowUserProcessingResult -LifecycleWorkflowId "<workflowId>" `
  -Filter "subject/id eq '<userObjectId>'" -ExpandProperty "tasksProcessingResults"

# 5. Does the user currently meet execution conditions (will be picked up next run)?
# Portal: Workflow → Execution conditions → "Users in scope" tab (no direct Graph list cmdlet for this preview scope tab —
# cross-check manually against the rule using Get-MgUser -Filter matching the workflow's scope rule)
Get-MgUser -UserId "<userObjectId>" -Property employeeHireDate,employeeLeaveDateTime,createdDateTime,accountEnabled |
  Select employeeHireDate, employeeLeaveDateTime, createdDateTime, accountEnabled
```

| Finding | Interpretation | Do this |
|---|---|---|
| `IsEnabled = False` | Workflow itself is off — no schedule, no on-demand | Enable the workflow before anything else |
| `IsEnabled = True`, `IsSchedulingEnabled = False` | Workflow only ever runs on-demand — this is a config choice, not a bug | Confirm with the requester whether scheduled automation was actually expected |
| Run `Status = completed` but user missing from run | User didn't meet execution conditions at evaluation time | Go to [Fix 1](#common-fix-paths) |
| Run shows `FailedTasks > 0` for the user | A specific task errored (permissions, target already in state, dependency) | Pull `tasksProcessingResults` — the per-task error is specific and actionable |
| User's trigger attribute (`employeeHireDate`/`employeeLeaveDateTime`) is `$null` | Attribute was never synced from source system/on-prem AD | Go to [Fix 2](#common-fix-paths) |
| Workflow ran, task shows succeeded, but AD account still enabled/not deleted | User is AD DS-synced; Enable/Disable/Delete tasks need extra on-prem config that isn't in place | Go to [Fix 3](#common-fix-paths) |
| Rule has a red ⚠ / "This rule contains invalid properties" | Scope or trigger references a **deactivated** custom security attribute | Go to [Fix 4](#common-fix-paths) |
| Custom-attribute-triggered workflow "didn't fire" but it's been under 4 hours | Expected — custom attribute change processing has a documented up-to-4-hour upper bound | Wait; don't treat as broken before the 4-hour mark |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Entra ID Governance / Entra Suite license on the tenant
        │
        ▼
Lifecycle Workflows Administrator role (or Graph app perms) ── governs who can author/run workflows
        │
        ▼
Workflow object: IsEnabled = true  ─────────────────┐
        │                                            │  (independent switch —
        ▼                                            │   both must be true)
Scheduling: IsSchedulingEnabled = true ◄─────────────┘
        │
        ▼
Execution conditions evaluated on interval (default 3h, or custom)
   ├─ Trigger:  Time based attribute | Attribute changes | Group membership change
   │            | Sign-in inactivity | On-demand only
   └─ Scope:    rule-based (case-sensitive!) or group-based
        │
        ▼
User must actually meet trigger + scope AT evaluation time
   (source attributes — employeeHireDate, employeeLeaveDateTime, custom security
    attributes — must already be synced/set on the user object; case-sensitive match)
        │
        ▼
3-day catch-up window (covers HR data arriving late) — beyond 3 days, user is skipped
   until the NEXT qualifying change re-triggers evaluation
        │
        ▼
Tasks execute in order (up to 25 tasks/workflow, 100 workflows/tenant)
   ├─ Cloud-only tasks (license, welcome email, cloud group add/remove, TAP) → work out of the box
   └─ AD DS-synced user account tasks (Enable / Disable / Delete)
            │
            ▼
       Requires: Entra provisioning agent (≥ v1.1.1586.0) installed with
       "HR-driven provisioning / Microsoft Entra Connect Sync" extension config
       + gMSA with correct on-prem permissions
       + (Delete only) AD Recycle Bin enabled
       — WITHOUT this, the task reports "succeeded" but nothing happens in AD
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the workflow is both Enabled and Scheduled.**
   `Get-MgIdentityGovernanceLifecycleWorkflow -LifecycleWorkflowId "<id>"` → check `IsEnabled` and `IsSchedulingEnabled` separately. These are two independent switches — a workflow can be "on" but never scheduled to auto-run. Expected: both `True` for a workflow meant to run unattended.

2. **Pull the last 5 runs and look for the user.**
   `Get-MgIdentityGovernanceLifecycleWorkflowRun`. Expected: a run at or after the point the user should have qualified. If there's no run at all since the expected trigger date, scheduling itself is the problem — go back to step 1.

3. **If a run happened but the user isn't in it, check the source attribute.**
   `Get-MgUser -Property employeeHireDate,employeeLeaveDateTime,createdDateTime`. Expected: the attribute the trigger depends on is populated and correct. `createdDateTime` is the date the object was **synced into Entra ID**, not the true on-prem AD creation date — a frequent source of "workflow ran on the wrong day" tickets for hybrid users.

4. **Check whether the user is more than 3 days past their expected trigger date.**
   Compare today's date against `employeeHireDate ± Days from Event`. If more than 3 days have elapsed since the theoretical trigger point and the user was never processed, they've fallen outside the catch-up window and won't self-heal — they need either an on-demand run or a scope-qualifying change to re-trigger.

5. **If the workflow ran and reports success, but the real-world action didn't happen (AD account still enabled), assume the on-prem task path.**
   Check for the Entra provisioning agent extension mode and gMSA permissions — see [Fix 3](#common-fix-paths). This is the single most common "workflow lied to me" ticket.

6. **If the rule itself shows an error icon, check for a deactivated custom security attribute.**
   Entra admin center → Attributes → look for the specific attribute referenced in the rule; if deactivated, the rule is permanently invalid until edited, regardless of anything else.

7. **Validate the fix by running the workflow on-demand for the affected user, then re-checking their processing result.**
   `Initialize-MgIdentityGovernanceLifecycleWorkflow` (on-demand run **ignores** execution conditions entirely and processes the named user(s) regardless of scope match — useful for validation, but don't mistake a successful on-demand run for proof that the *scheduled* trigger/scope logic is fixed).

---
## Common Fix Paths

<details><summary>Fix 1 — User never meets execution conditions (scope/trigger mismatch)</summary>

Most common causes, in order of frequency:
- Trigger attribute (`employeeHireDate`, `employeeLeaveDateTime`) is `$null` on the user — see Fix 2.
- Rule evaluation is **case-sensitive**. A scope rule like `department -eq "Sales"` will not match a user whose attribute value is `"sales"`.
- The workflow's "Users in scope" preview list is a snapshot from the *last* evaluation pass — if you just edited the rule, the list won't reflect it until the engine re-evaluates (next scheduled interval, or force it with an edit-triggered re-evaluation).

```powershell
# Confirm the live attribute value and casing exactly as stored
Get-MgUser -UserId "<userObjectId>" -Property department,employeeHireDate,employeeLeaveDateTime |
  Format-List

# Compare verbatim against the rule expression configured on the workflow
(Get-MgIdentityGovernanceLifecycleWorkflow -LifecycleWorkflowId "<workflowId>").ExecutionConditions
```

No rollback needed — this is a read/compare operation. Correct either the rule text or the attribute value/casing so they match exactly.

</details>

<details><summary>Fix 2 — employeeHireDate / employeeLeaveDateTime never synced (hybrid AD DS user)</summary>

Time-based triggers depend on these attributes being explicitly synced from the source (Cloud Sync attribute mapping, or Entra Connect Sync directory extensions) — they are **not** synced by default.

```powershell
# Check current sync rule scope for the attribute (Entra Connect Sync, run on the sync server)
Get-ADSyncRule | Where-Object { $_.Name -like "*In from AD*User*" } |
  Select Name, Precedence

# Confirm the attribute is actually populated on-prem before troubleshooting the sync side
Get-ADUser -Identity "<samAccountName>" -Properties employeeHireDate |
  Select Name, employeeHireDate
```

Fix: map the attribute in the HR-driven provisioning app (if HR-sourced) or add a directory extension / Cloud Sync attribute mapping rule, then force a delta sync. No destructive action — safe to re-run sync as many times as needed.

</details>

<details><summary>Fix 3 — Enable/Disable/Delete task "succeeds" but AD account is untouched</summary>

This is the single most common false-positive in hybrid environments. The task reports success against the Entra-side task engine, but the actual on-prem AD write requires infrastructure that is very easy to skip during initial setup.

Checklist (all four required):
1. Microsoft Entra provisioning agent installed, version **≥ 1.1.1586.0**.
2. Agent's extension configuration is set to **"HR-driven provisioning / Microsoft Entra Connect Sync"** (not plain cloud sync).
3. The gMSA used by the provisioning agent has the required on-prem delegated permissions on the target OU(s).
4. For Delete tasks specifically: **Active Directory Recycle Bin must be enabled** in the on-prem forest.

```powershell
# On the server running the provisioning agent — confirm version
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure AD Connect Provisioning Agent" -ErrorAction SilentlyContinue |
  Select DisplayVersion

# Confirm AD Recycle Bin is enabled (required for Delete User task)
Get-ADOptionalFeature -Filter 'Name -like "Recycle Bin*"' |
  Select Name, EnabledScopes
```

Rollback note: enabling AD Recycle Bin is a one-way, low-risk, and Microsoft-recommended change — not something to be cautious about reverting. Upgrading the provisioning agent is non-destructive; reinstall in place using the same extension configuration if a repair is needed.

</details>

<details><summary>Fix 4 — Rule references a deactivated custom security attribute (red ⚠, "invalid properties")</summary>

A custom security attribute used in a scope or trigger rule that gets deactivated tenant-wide leaves the workflow's rule permanently invalid — the workflow will not process **any** user until the rule is edited, even users who'd otherwise clearly match.

```powershell
# List active vs. deactivated custom security attribute definitions
Get-MgDirectoryCustomSecurityAttributeDefinition | Select Id, Name, Status
```

Fix: edit the workflow's rule expression to remove the deactivated attribute reference (or reactivate the attribute definition if it was deactivated by mistake), then save — this creates a new workflow version.

</details>

<details><summary>Fix 5 — Custom security attribute value present but rule still doesn't match</summary>

Two near-identical-looking gotchas:
- Matching is **case-sensitive** — `"Contractor"` ≠ `"contractor"`.
- If the attribute has **multiple values** assigned, only ONE of them needs to match the rule value for the user to be in scope — if you expected an AND-all-values match, that's not how it evaluates.

```powershell
Get-MgUser -UserId "<userObjectId>" -Property "customSecurityAttributes" |
  Select -ExpandProperty AdditionalProperties
```

No destructive action — value/casing correction only.

</details>

<details><summary>Fix 6 — Task history looks fragmented / "the workflow used to show more runs"</summary>

Editing a workflow's tasks or execution conditions creates a new **workflow version** — it is reported separately in history from the prior version, which can look like history was lost. It wasn't; check under Workflow History whether a version filter is hiding older-version runs.

</details>

<details><summary>Fix 7 — Need a genuinely custom action (call an internal API, webhook, etc.)</summary>

Lifecycle Workflows only supports adding tasks from Microsoft's built-in task template library (identified by `taskDefinitionID`) — there is no arbitrary "call this Graph endpoint" task type. The supported extensibility path is a **Logic Apps task**: configure a Logic App with an HTTP trigger, then add a Lifecycle Workflow task pointing at that Logic App's URL.

No fix here in the traditional sense — if a requester wants logic beyond the built-in task set, scope the work as a Logic Apps integration, not a Lifecycle Workflow customization.

</details>

---
## Escalation Evidence

```
LIFECYCLE WORKFLOWS ESCALATION
Tenant: <tenantName>
Workflow name / ID: <displayName> / <workflowId>
Category (Joiner/Mover/Leaver): <category>
Affected user(s): <UPN or objectId>

IsEnabled: <true/false>          IsSchedulingEnabled: <true/false>
Trigger type: <TimeBased / AttributeChange / GroupMembership / SignInInactivity / OnDemand>
Scope rule (verbatim): <paste rule expression>

Last run ID: <runId>             Status: <completed/failed/inProgress>
Scheduled run time: <timestamp>  Completed: <timestamp>

Per-task result for affected user:
  Task: <taskDefinitionID / display name>   Status: <succeeded/failed>   Error: <verbatim error text>

Is user AD DS-synced? <yes/no>
  If yes — provisioning agent version: <version>   Extension mode confirmed: <yes/no>
  gMSA permission confirmed: <yes/no>   AD Recycle Bin enabled: <yes/no>

License confirmed (Entra ID Governance / Entra Suite): <yes/no>
Steps already attempted: <bullet list>
```

---
## 🎓 Learning Pointers
- **"Enabled" and "Scheduled" are two separate switches on the same workflow** — a newly created workflow is enabled by default but is *not* automatically scheduled to run unattended. This trips up almost every first Lifecycle Workflows deployment. See [Understanding lifecycle workflows](https://learn.microsoft.com/en-us/entra/id-governance/understanding-lifecycle-workflows).
- **The 3-day catch-up window is a designed grace period, not a bug** — if HR data lands late, a user still gets processed as long as it's within 3 days of the original trigger date. Past that, they're silently skipped until something re-qualifies them. See [Execution conditions and scheduling](https://learn.microsoft.com/en-us/entra/id-governance/lifecycle-workflow-execution-conditions#lifecycle-workflow-catch-up-window).
- **On-demand runs bypass scope entirely** — don't use a successful manual "Run on demand" test as proof that the scheduled trigger/scope logic actually works for that user; it proves the *tasks* work, nothing about matching.
- **For AD DS-synced users, Enable/Disable/Delete tasks have real infrastructure prerequisites** (provisioning agent version, correct extension mode, gMSA rights, Recycle Bin for Delete) that are completely separate from the cloud-only tasks in the same workflow — a workflow can be "half-working" by design until these are set up. See [Managing users synchronized from AD DS with Lifecycle Workflows](https://learn.microsoft.com/en-us/entra/id-governance/lifecycle-workflow-on-premises).
- **Rule matching is case-sensitive, including for custom security attributes** — this is one of the most-reported "why didn't my rule match" issues in Microsoft's own FAQ. See [Lifecycle workflows FAQs](https://learn.microsoft.com/en-us/entra/id-governance/workflows-faqs).
- Cross-reference: Lifecycle Workflows is layered automation on top of account existence — it does not create the account (that's [HR-driven provisioning](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/what-is-hr-driven-provisioning)), and it's a distinct system from `Troubleshooting/AccessReviews-B.md` (periodic recertification) and `Troubleshooting/PIM-B.md` (role activation) — don't conflate ticket types.
