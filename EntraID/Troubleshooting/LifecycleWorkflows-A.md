# Entra ID Governance — Lifecycle Workflows — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index (with jump links)
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

This covers **Microsoft Entra ID Governance Lifecycle Workflows** — the joiner-mover-leaver (JML) task-automation engine that runs scheduled or on-demand tasks (license assignment, welcome email, Temporary Access Pass generation, group add/remove, account enable/disable/delete, custom Logic App calls) against users based on execution conditions (trigger + scope).

**Explicitly out of scope here, covered elsewhere:**
- **HR-driven provisioning** (creates/updates the account itself from Workday/SuccessFactors/etc.) — Lifecycle Workflows assumes the account already exists and automates what happens *around* it, layering on top rather than replacing HR provisioning.
- **`Troubleshooting/AccessReviews-A.md`** — periodic access recertification. Different trigger model (scheduled review campaigns, not JML events) and different remediation semantics (revoke access vs. run a task).
- **`Troubleshooting/PIM-A.md`** — just-in-time role activation. Lifecycle Workflows can assign group membership that in turn feeds a PIM-eligible assignment, but it does not itself activate roles.
- **`Troubleshooting/DynamicGroups-A.md`** — rule-based group membership evaluation is a related-but-separate engine; a Lifecycle Workflow group task adds/removes a user from a group directly, it does not define dynamic membership rules.

**License requirement:** Microsoft Entra ID Governance or Microsoft Entra Suite. **Role requirement:** Lifecycle Workflows Administrator (delegated) or `LifecycleWorkflows.ReadWrite.All`/`.Read.All` (application).

---
## How It Works

<details><summary>Full architecture</summary>

A workflow has three parts:

1. **General information** — display name, description, category (Joiner/Mover/Leaver — determines which task templates and event attributes are available).
2. **Tasks** — an ordered list of built-in task templates (each identified by a `taskDefinitionID`), executed in sequence for every user the workflow processes. Up to **25 tasks per workflow**, up to **100 workflows per tenant**.
3. **Execution conditions** — a **trigger** (when) and a **scope** (who), evaluated together to determine which users a *scheduled* run processes.

### Triggers (five types)

| Trigger | Fires when | Notes |
|---|---|---|
| Time based attribute | A configured offset (0–180 days, Before/After/On) from an event attribute is reached | Joiner workflows commonly use `employeeHireDate` or `createdDateTime`; leaver workflows use `employeeLeaveDateTime` or `lastSignInDateTime`. Custom attributes supported (Preview). |
| Attribute changes | A specific attribute changes to/from a specified value | Rule-based, case-sensitive evaluation. |
| Group membership change | User added to or removed from a specific group | Group-based scope, not rule-based. |
| Sign-in inactivity | N days since last sign-in is reached | Rule-based scope. |
| On-demand only | Never runs on schedule | Default for templates designed for manual/ad-hoc use; also usable for testing any workflow. |

### Scope

Scope narrows *which* users among those matching the trigger are actually processed. For rule-based triggers, scope supports a rich set of user properties (including custom security attributes) via the same rule-expression syntax used elsewhere in Entra ID Governance (access packages, entitlement management). **Rule evaluation is case-sensitive** — this single fact accounts for a large share of "workflow didn't fire for an obviously-matching user" tickets.

### Scheduling — two independent switches

A workflow has an `IsEnabled` flag and a separate `IsSchedulingEnabled` flag. **Newly created workflows are enabled by default, but scheduling is NOT automatically turned on** — an admin must explicitly enable scheduling. Once scheduling is on, the workflow engine evaluates execution conditions on an interval (default **3 hours**, configurable in workflow settings) to decide whether to run. This two-switch design is the single most common source of "I built the workflow and nothing happens" tickets.

### The 3-day catch-up window

By design, Lifecycle Workflows tolerates up to **3 days** of delay between a user's theoretical trigger date and when their account/attribute data actually becomes available (e.g., HR system lag). If a user's `employeeHireDate`-based trigger point already passed by the time the account is provisioned, the engine will still process them **as long as the gap is 3 days or less**. Beyond 3 days, the user is not automatically caught up — they need either a fresh qualifying change (which re-evaluates them) or an on-demand run. This is deliberate design, not a defect, and should be the first thing checked before assuming a bug.

### On-demand execution bypasses scope entirely

Running a workflow on-demand for named users **applies the tasks regardless of whether those users currently meet the execution conditions**. This makes on-demand runs excellent for testing task logic, but a successful on-demand run for a user proves nothing about whether the *scheduled* trigger/scope combination would ever have picked that user up on its own — don't let a passing manual test close a ticket about broken automatic scheduling.

### Custom security attributes as scope/trigger criteria

Lifecycle Workflows can scope on custom security attributes, with several sharp edges:
- Matching against the assigned value is **case-sensitive**.
- If a user has a **multi-value** custom security attribute, matching **any one** of the values against the rule is sufficient — it is not an all-values match.
- If the referenced custom security attribute is later **deactivated**, the rule shows an invalid-properties error and the entire workflow stops processing until the rule is corrected — it does not silently ignore that one clause.
- Seeing custom security attributes in the rule-builder property list requires the **Attribute Assignment Administrator** or **Attribute Assignment Reader** role — an admin without either role will see an empty list and may incorrectly conclude the attributes don't exist.
- Custom-attribute-triggered workflows have a documented processing delay of **up to 4 hours** (variable, tenant activity-dependent) — this is expected latency, not a stuck workflow.

### Extensibility model — task library only, no arbitrary custom code

Tasks can only be selected from Microsoft's built-in task template catalog; there is no task type that calls an arbitrary internal API or webhook directly. The supported extensibility mechanism is a dedicated **Logic Apps task** — a Logic App with an HTTP trigger, invoked from within the workflow as one of its ordered tasks. Any requirement beyond the built-in catalog should be scoped as a Logic App integration project, not treated as a workflow customization request.

### Versioning

Editing a workflow's tasks or execution conditions creates a new **version** of that workflow, which is tracked and reported separately from prior versions in workflow history (Users / Runs / Tasks views). This is by design (so historical runs remain attributable to the exact configuration that produced them) but frequently looks to an admin like "history got reset" after an edit.

</details>

---
## Dependency Stack

```
Microsoft Entra ID Governance / Entra Suite license
        │
Lifecycle Workflows Administrator role (delegated) or app permissions (application)
        │
Workflow object created from a category-appropriate template
        │
   ┌────┴────┐
   │         │
IsEnabled  IsSchedulingEnabled     ← two INDEPENDENT booleans; both required for unattended operation
   │         │
   └────┬────┘
        │
Execution conditions evaluation (interval-based, default 3h)
   ├─ Trigger match (time/attribute/group/sign-in-inactivity/on-demand)
   └─ Scope match (rule-based, case-sensitive — or group-based)
        │
Source attribute availability on the user object
   (employeeHireDate / employeeLeaveDateTime / custom security attributes
    must be POPULATED — not synced by default for AD DS-originated users)
        │
3-day catch-up window (grace period for late HR/sync data)
        │
Task execution (ordered, ≤25 tasks/workflow, ≤100 workflows/tenant)
   │
   ├─ Cloud-native tasks (license, welcome email, TAP, cloud group add/remove,
   │  Logic App call) — function immediately, no extra prerequisites
   │
   └─ AD DS-synced account tasks (Enable / Disable / Delete user)
            │
            ├─ Microsoft Entra provisioning agent installed (≥ v1.1.1586.0)
            ├─ Agent extension config = "HR-driven provisioning / Entra Connect Sync"
            ├─ gMSA with correct delegated on-prem permissions
            └─ (Delete task only) AD Recycle Bin enabled in the target forest
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Workflow built, nothing ever runs automatically | `IsSchedulingEnabled = false` — enabling the workflow does not enable its schedule | `Get-MgIdentityGovernanceLifecycleWorkflow` → `IsSchedulingEnabled` |
| User obviously matches the rule but wasn't processed | Case mismatch between rule value and actual attribute value | Compare rule text vs. `Get-MgUser` attribute value byte-for-byte |
| Workflow "used to" process users, now skips new hires whose start date already passed | User provisioned more than 3 days after their theoretical trigger date — outside catch-up window | Compare `employeeHireDate` + offset against provisioning date; if >3 days, needs on-demand run |
| `createdDateTime`-triggered workflow fires on an unexpected date for a hybrid user | `createdDateTime` reflects **sync-into-Entra** date, not true on-prem AD object creation date | Compare AD `whenCreated` vs. Entra `createdDateTime` |
| Time-based trigger never fires for AD DS-synced users at all | `employeeHireDate`/`employeeLeaveDateTime` not mapped/synced — these require explicit mapping, unlike core attributes | Check Cloud Sync attribute mapping or Connect Sync directory extension config |
| Task reports "succeeded" but AD account is still enabled/present | AD DS account task prerequisites (agent version/mode, gMSA rights, Recycle Bin) not fully met | Verify all four prerequisites individually — a partial setup fails silently at the AD layer only |
| Rule shows "This rule contains invalid properties" (red icon) | A custom security attribute referenced in the rule was deactivated | `Get-MgDirectoryCustomSecurityAttributeDefinition` → check `Status` |
| Admin can't see expected custom security attributes in the rule builder | Missing Attribute Assignment Administrator/Reader role | Verify role assignment, not attribute existence |
| Custom-attribute-triggered workflow appears delayed | Expected — up to 4-hour processing window is documented and normal | Confirm elapsed time before escalating |
| "Users in scope" preview list looks stale right after a rule edit | Preview reflects the last evaluation pass, not live matching | Wait for next scheduled evaluation interval, or re-check after it passes |
| Group add/remove task has no effect for an on-prem-synced group | Groups synced **from** AD DS to Entra cannot be targeted by Lifecycle Workflow group tasks | Use a cloud-native group instead; optionally writeback to AD via Cloud Sync group writeback |
| Workflow history looks fragmented after an edit | Editing tasks/conditions creates a new workflow **version**, tracked separately | Check version filter in Workflow History |
| A manual "Run on demand" test succeeded but the ticket says scheduled automation is broken | On-demand bypasses scope matching entirely — proves tasks work, not that scheduling logic works | Re-verify scope match independently before closing |
| Need a workflow task that calls an internal system/API | Not supported natively — task catalog is fixed | Scope as a Logic Apps task integration, not a workflow feature request |

---
## Validation Steps

1. **Confirm license and role.** `Get-MgSubscribedSku` for Entra ID Governance/Entra Suite SKU; confirm the operator holds Lifecycle Workflows Administrator. Good: license present, role assigned. Bad: attempts to manage workflows fail with an authorization/feature-not-available error.

2. **Confirm workflow state.** `Get-MgIdentityGovernanceLifecycleWorkflow` → `IsEnabled` and `IsSchedulingEnabled` both `true` for any workflow expected to run unattended. Bad: either is `false` while the requester expects automatic behavior.

3. **Confirm execution conditions match intent.** Read back `ExecutionConditions` (trigger + scope) and compare against the actual rule expression intended by the requester, checking case exactly. Bad: rule text present but with a casing/value mismatch against real attribute data.

4. **Confirm source attribute population** for any user expected to be processed. `Get-MgUser -Property employeeHireDate,employeeLeaveDateTime`. Bad: `$null` for a hybrid AD DS user whose trigger depends on it — mapping was never configured.

5. **Confirm run history shows evaluation activity.** `Get-MgIdentityGovernanceLifecycleWorkflowRun` — runs should appear at each scheduled interval regardless of whether any users matched. Bad: no runs at all since scheduling was enabled — points back to a scheduling-layer problem, not a scope problem.

6. **Confirm per-user, per-task outcomes** for anyone reported as "processed but nothing happened." `Get-MgIdentityGovernanceLifecycleWorkflowUserProcessingResult -ExpandProperty tasksProcessingResults`. Good: each task shows `succeeded` with a real, verifiable side effect (license present, account disabled). Bad: `succeeded` status with no corresponding real-world change — strongly suggests the AD DS on-prem task prerequisite gap.

7. **For AD DS-synced account tasks specifically, validate all four prerequisites independently** rather than assuming one implies the others: provisioning agent version, extension config mode, gMSA permissions, and (for Delete) AD Recycle Bin state.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Configuration.** Verify license, role, `IsEnabled`, `IsSchedulingEnabled`. Most "nothing happens" tickets resolve here.

**Phase 2 — Trigger/scope matching.** Verify the rule expression against live attribute data, case-sensitive, including custom security attribute activation state and role visibility.

**Phase 3 — Timing.** Check the 3-day catch-up window boundary and, for custom-attribute triggers, the up-to-4-hour processing window, before assuming either scope or scheduling is broken.

**Phase 4 — Task execution.** For each task in the affected run, inspect its individual result. Cloud-native task failures usually carry a specific, actionable Graph error (permission scope, target already in the desired state, license SKU exhausted). AD DS-synced account task "successes" that didn't actually change AD require independent verification of the four on-prem prerequisites.

**Phase 5 — Escalation prep** (see Remediation Playbooks and Evidence Pack) if the above phases don't resolve the issue, particularly for anything indicating a platform-side processing delay beyond documented limits or a Graph API error without a clear cause.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Stand up a new Joiner (pre-hire) workflow end-to-end</summary>

1. Confirm `employeeHireDate` is mapped and populated for the target user population (Cloud Sync attribute mapping or Connect Sync directory extension for hybrid users; direct HR-driven provisioning mapping for cloud-first users).
2. Create the workflow from the **Onboard pre-hire employee** template; set trigger to Time based attribute, `employeeHireDate`, offset e.g. 7 days Before.
3. Add tasks in the order they should execute (e.g., Generate Temporary Access Pass and email manager → Add user to groups → Assign licenses → Send welcome email).
4. Set scope (rule- or group-based) matching the intended population, verifying case exactly against real attribute values.
5. Enable the workflow, **then separately enable scheduling** — do not assume enabling the workflow enables its schedule.
6. Validate with an on-demand run against a test user first (remembering this bypasses scope matching), then confirm a real scheduled run picks up a genuinely in-scope user at the next evaluation interval.

No destructive steps; safe to iterate.

</details>

<details><summary>Playbook 2 — Enable AD DS-synced account tasks (Enable/Disable/Delete) for a Leaver workflow</summary>

1. Install or upgrade the Microsoft Entra provisioning agent to **≥ v1.1.1586.0**.
2. During/after installation, set the agent's extension configuration to **"HR-driven provisioning / Microsoft Entra Connect Sync"** — this can coexist with an existing Entra Connect Sync deployment; no other cloud sync configuration is required on the same agent.
3. Grant the gMSA used by the agent the documented on-prem delegated permissions against the relevant OU(s).
4. If the workflow includes a Delete User task, enable the **AD Recycle Bin** in the target forest first — this is a one-way-to-enable, low-risk, Microsoft-recommended change with no meaningful downside to enabling early.
5. Re-run the leaver workflow on-demand for a test (non-production-critical) account and confirm the AD-side state actually changes (account disabled/deleted in AD, not just marked processed in Entra).

**Rollback:** disabling the account tasks is as simple as removing them from the workflow's task list — no on-prem state is altered by removing the task itself (already-applied changes to previously processed users are not reverted).

</details>

<details><summary>Playbook 3 — Recover a workflow with an invalid rule (deactivated custom security attribute)</summary>

1. Identify the deactivated attribute: `Get-MgDirectoryCustomSecurityAttributeDefinition | Where-Object Status -eq "Deprecated"`.
2. Confirm whether deactivation was intentional. If not, reactivate the attribute definition — this immediately restores rule validity with zero further changes needed.
3. If deactivation was intentional, edit the workflow's rule expression to remove the reference, then save (this creates a new workflow version — expected, not an error).
4. Re-check the workflow's `IsEnabled`/`IsSchedulingEnabled` state after the edit; saving a rule change does not disable the workflow, but always verify rather than assume.

</details>

<details><summary>Playbook 4 — Full fleet audit ahead of a client's JML process review</summary>

1. Run `Scripts/Get-LifecycleWorkflowAudit.ps1` for a tenant-wide inventory of workflow state, recent run health, and per-workflow task failure trends.
2. Cross-reference any workflow with AD DS-synced account tasks against the four on-prem prerequisites, flagging any workflow that has such tasks configured without confirmed prerequisites (a workflow can be fully valid in Entra ID configuration while being functionally inert on the AD side).
3. Review workflows with `IsSchedulingEnabled = false` — confirm with the client whether this is intentional (on-demand-only by design) or an oversight.
4. Deliver findings alongside the client's actual JML process documentation so gaps (e.g., no leaver workflow exists at all) are visible, not just misconfigurations in existing workflows.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Lifecycle Workflows evidence pack for escalation — read-only.
#>
Connect-MgGraph -Scopes "LifecycleWorkflows.Read.All","User.Read.All" -NoWelcome

$workflows = Get-MgIdentityGovernanceLifecycleWorkflow -All
foreach ($wf in $workflows) {
    [PSCustomObject]@{
        WorkflowId          = $wf.Id
        DisplayName         = $wf.DisplayName
        Category            = $wf.Category
        IsEnabled           = $wf.IsEnabled
        IsSchedulingEnabled = $wf.IsSchedulingEnabled
        LastModified        = $wf.LastModifiedDateTime
    }
}

$runs = Get-MgIdentityGovernanceLifecycleWorkflowRun -LifecycleWorkflowId "<workflowId>" -Top 10
$runs | Select Id, Status, ScheduledDateTime, CompletedDateTime, FailedTasks, ProcessedUsers, TotalUsers

Get-MgIdentityGovernanceLifecycleWorkflowUserProcessingResult -LifecycleWorkflowId "<workflowId>" `
  -Filter "subject/id eq '<userObjectId>'" -ExpandProperty "tasksProcessingResults" |
  Select -ExpandProperty TasksProcessingResults
```

Export each block to CSV and attach alongside the affected user's current `employeeHireDate`/`employeeLeaveDateTime`/relevant custom security attribute values when escalating.

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-MgIdentityGovernanceLifecycleWorkflow -All` | List all workflows, enabled/scheduled state |
| `New-MgIdentityGovernanceLifecycleWorkflow` | Create a workflow (up to 100/tenant) |
| `Update-MgIdentityGovernanceLifecycleWorkflow` | Modify workflow properties, execution conditions |
| `New-MgIdentityGovernanceLifecycleWorkflowTask` | Add a task to a workflow (up to 25/workflow) |
| `Update-MgIdentityGovernanceLifecycleWorkflowTask` | Modify an existing task's configuration |
| `Initialize-MgIdentityGovernanceLifecycleWorkflow` | Run a workflow on-demand (bypasses scope matching) |
| `Get-MgIdentityGovernanceLifecycleWorkflowRun` | List recent runs and their status/summary counts |
| `Get-MgIdentityGovernanceLifecycleWorkflowUserProcessingResult` | Per-user processing result for a workflow run |
| `Get-MgDirectoryCustomSecurityAttributeDefinition` | Check active/deactivated custom security attributes |
| `Get-MgUser -Property employeeHireDate,employeeLeaveDateTime,createdDateTime` | Verify trigger-relevant attributes on a user |
| `Get-ADUser -Properties employeeHireDate` | Verify the on-prem AD source value before troubleshooting sync |
| `Get-ADSyncRule` | Inspect Entra Connect Sync inbound rules (attribute mapping) |
| `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure AD Connect Provisioning Agent"` | Confirm provisioning agent version on-prem |
| `Get-ADOptionalFeature -Filter 'Name -like "Recycle Bin*"'` | Confirm AD Recycle Bin state (required for Delete task) |
| `Get-MgSubscribedSku` | Confirm Entra ID Governance / Entra Suite license presence |

---
## 🎓 Learning Pointers
- Lifecycle Workflows and HR-driven provisioning solve **different halves** of the JML problem — provisioning creates/updates the account from a system of record, Lifecycle Workflows automates what happens to it afterward. Conflating the two leads to troubleshooting the wrong system. [What are Lifecycle Workflows?](https://learn.microsoft.com/en-us/entra/id-governance/what-are-lifecycle-workflows)
- The **two-switch enable/schedule model** and the **3-day catch-up window** are both deliberate design choices documented by Microsoft, not edge-case bugs — internalizing both will resolve a large fraction of "the workflow isn't working" tickets before any deep diagnosis is needed. [Execution conditions and scheduling](https://learn.microsoft.com/en-us/entra/id-governance/lifecycle-workflow-execution-conditions)
- Hybrid AD DS environments have a **completely separate prerequisite chain** for account-mutating tasks (provisioning agent, extension mode, gMSA rights, Recycle Bin) layered on top of the cloud-only task requirements — treat any Enable/Disable/Delete task failure on a synced user as an on-prem infrastructure question first. [Managing users synchronized from AD DS with Lifecycle Workflows](https://learn.microsoft.com/en-us/entra/id-governance/lifecycle-workflow-on-premises)
- Case-sensitive rule matching (including for custom security attributes) is explicitly called out in Microsoft's own FAQ as one of the most common points of confusion — worth testing rule expressions against real attribute casing before assuming a logic error. [Lifecycle workflows FAQs](https://learn.microsoft.com/en-us/entra/id-governance/workflows-faqs)
- The extensibility model (built-in task catalog + Logic Apps task for anything custom) is a hard architectural boundary — don't scope a "custom Graph call" as a Lifecycle Workflows task; it has to be a Logic App the workflow calls into. [Lifecycle Workflow built-in tasks](https://learn.microsoft.com/en-us/entra/id-governance/lifecycle-workflow-tasks)
- Worth a deeper look when time allows: [Lifecycle Workflows service limits](https://learn.microsoft.com/en-us/entra/id-governance/governance-service-limits#lifecycle-workflows) (workflow/task counts, run history retention) and [custom attribute triggers (Preview)](https://learn.microsoft.com/en-us/entra/id-governance/workflow-custom-triggers) for scenarios beyond the standard employeeHireDate/employeeLeaveDateTime model.
