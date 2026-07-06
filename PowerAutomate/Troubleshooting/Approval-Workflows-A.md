# Power Automate Approval Workflows — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- The built-in "Start and wait for an approval" action and the Approvals service/app it depends on
- Outlook (Actionable Messages) and Teams (Adaptive Card) notification delivery paths
- Platform-level constraints (run duration ceiling, approval type semantics) that shape design decisions

**Out of scope:**
- Custom-built approval logic using raw HTTP/webhook patterns instead of the native connector
- Third-party approval/ticketing systems that happen to integrate with Power Automate
- SharePoint list-based "approval" workflows that don't use the Approvals connector at all

**Assumes:**
- Power Automate maker or admin access to the flow and its run history
- Microsoft Graph PowerShell SDK connected for approver account checks
- General familiarity with Power Automate trigger/action/connector concepts

---

## How It Works

<details><summary>Full architecture — the Approvals service and its constraints</summary>

### The Approvals action creates a record in a separate service, not just a flow pause

"Start and wait for an approval" is not simply the flow "pausing." It creates a request record in the **Approvals service**, a backend distinct from the flow engine itself, which is responsible for tracking response state and rendering the request across every surface (Outlook, Teams, the Approvals web/mobile app). The flow run genuinely suspends — consuming a long-running-workflow "slot" — until the Approvals service reports a completion event back to it.

### Assignee list is fixed at request-creation time

The list of approvers is captured into the Approvals service record the moment the action fires. There is no mechanism — from the flow, from the Approvals center UI, or from PowerShell — to edit who an **already-running** approval was sent to. The only two ways to change an in-flight assignee list are: (a) have a currently-assigned approver respond, or (b) cancel the run entirely and start a new one with a corrected assignee list. This is a hard platform design constraint, not a configuration gap.

### Two fundamentally different completion semantics

The "Approval type" field selects between two state machines with very different failure modes:

- **"First to respond"**: the Approvals service completes the request the instant *any one* assigned approver responds. Remaining approvers' responses (if they respond after) are recorded but don't change the outcome.
- **"Everyone must approve"**: the Approvals service holds the request open until *every* assigned approver has responded, with no default timeout or reminder mechanism. If one assigned approver never responds — because they're on leave, left the company, or their account was disabled — the request waits indefinitely up to the platform's outer duration ceiling. This is by design (the semantics genuinely mean "everyone," including someone who's unreachable) and is a frequent source of "stuck approval" tickets that are, technically, functioning exactly as configured.

### Notification delivery is a separate concern from the approval record itself

An approval request can exist and be fully valid in the Approvals service while its **notification** fails to reach the approver through a given channel:
- Outlook delivery relies on **Actionable Messages**, a specific email format with embedded action buttons; mail flow rules, some third-party email security gateways, and certain client configurations can strip or block the actionable elements (or the whole message) without an obvious error to either party.
- Teams delivery relies on the **Approvals app** being installed for that user and the flow's Teams connection having current permissions; if the app isn't installed, no card appears, but the approval itself is still sitting in the Approvals service, visible at `https://make.powerautomate.com/approvals`.

This means "the approver says they never got anything" is a distinct diagnostic branch from "the approval didn't process" — the former is almost always fixable by pointing the approver at the Approvals center directly, the latter requires checking the run itself.

### The 30-day maximum run duration is an absolute platform ceiling

Any flow run — approval or otherwise — is automatically terminated after 30 days of continuous execution, regardless of what it's waiting on. This applies to the run as a whole, so a "Start and wait for an approval" step that has been open for 29 days will be forcibly ended at day 30 even if the approver is mid-way through responding. There is no tenant-level override for this limit; it must be designed around (shorter internal reminder/escalation loops, not relying on the platform's outer bound as a business SLA).

</details>

---

## Dependency Stack

```
┌───────────────────────────────────────────┐
│  Requestor / business process trigger       │  ← Item created, form submitted, etc.
├───────────────────────────────────────────┤
│  Power Automate flow run                    │  ← Genuinely suspends at the approval step
├───────────────────────────────────────────┤
│  Approvals service (backend record)         │  ← Independent of the flow engine; tracks state
├───────────────────────────────────────────┤
│  Notification delivery channels             │  ← Outlook Actionable Messages / Teams Adaptive Card
├───────────────────────────────────────────┤
│  Approver identity (Entra ID account state)  │  ← Enabled + licensed required to respond
├───────────────────────────────────────────┤
│  Platform run-duration ceiling (30 days)     │  ← Hard limit, terminates run regardless of state
└───────────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Approval sits in "Running" indefinitely | Normal pending state, or "Everyone must approve" waiting on a non-responder | Check approval type + each approver's account status |
| Approver says they never received anything | Notification delivery issue, not a missing/broken approval | Direct them to the Approvals center; check Actionable Messages / Teams app install |
| Need to redirect the approval to someone else | Assignee list is fixed once the request fires | No in-flight edit possible — must cancel + resubmit, or wait for a remaining approver |
| Run terminated with a duration/timeout error | 30-day platform ceiling reached | Check run start timestamp vs. termination timestamp |
| Teams card visible but buttons do nothing | Teams connector auth stale, or unsupported custom card configuration | Test the Teams connection; check for over-customized "Custom Responses" |
| Approval completes on first response even though multiple approvers were listed | Approval type is "First to respond," working as designed | Confirm configured type in Inputs |
| Flow fails immediately at the approval step (not "Running") | Distinct connector/auth error, not an approval-semantics issue | Treat as a connector auth problem (see Connector-Auth runbook) |
| Same flow behaves differently after being copied to another environment | Approver list or connection references pointing at stale/wrong-tenant identities | Verify UPNs and connection references post-migration |

---

## Validation Steps

**1. Confirm the approval step's actual state (Running vs. genuinely Failed)**
```
Portal → My Flows → [flow] → Run History → click the run → click the approval action
"Running"  = normal pending state, not an error
"Failed"   = a distinct problem (connector auth, invalid input) — do not treat as approval-semantics
```

**2. Identify exactly who was assigned, and confirm it's individual accounts**
```
Approval action → Inputs → "Assigned to"
Confirm this is a list of individual UPNs — approval assignment does not expand
security groups or distribution lists at response time
```

**3. Check each assigned approver's account and license status**
```powershell
$approvers = "<approver1UPN>","<approver2UPN>"
foreach ($u in $approvers) {
    Get-MgUser -UserId $u -Property "displayName,accountEnabled,assignedLicenses" |
      Select-Object DisplayName, AccountEnabled, @{N='Licensed';E={$_.AssignedLicenses.Count -gt 0}}
}
```
Expected: `AccountEnabled = True` and at least one license for every listed approver.

**4. Confirm the approval type / completion semantics**
```
Inputs → "Approval type"
"Approve/Reject - First to respond"     → completes on ANY one response
"Approve/Reject - Everyone must approve" → waits for ALL assigned approvers
```

**5. Check elapsed run time against the platform ceiling**
```
Run History → run start timestamp
Compare against current time — flows are force-terminated at 30 days regardless of approver action
```

**6. Confirm notification delivery configuration independent of the approval record itself**
```
Outlook: Options → Mail → confirm Actionable Messages is enabled for the approver's mailbox
Teams: Apps → search "Approvals" → confirm installed for the approver
Approvals center (always authoritative): https://make.powerautomate.com/approvals
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Classify: is this a stuck approval or a failed step?
1. Run Validation Step 1
2. "Running" → proceed to Phase 2. "Failed" → this is a connector/auth/input problem, not an approval-semantics issue — escalate separately

### Phase 2 — Semantics: is the wait behavior expected given configuration?
1. Run Validation Step 4 to confirm approval type
2. If "Everyone must approve" and one approver hasn't responded, this is expected behavior for that configuration — not a defect
3. If "First to respond" and it's still waiting, confirm at least one assigned approver hasn't yet responded (check each individually — Validation Step 3 covers whether they even *can* respond)

### Phase 3 — Approver eligibility
1. Run Validation Step 3 for every assigned approver
2. A disabled account or removed license silently breaks that approver's ability to respond, with no error surfaced to the requestor or flow owner
3. If all assigned approvers are ineligible, the request cannot complete without intervention — proceed to remediation (cancel + resubmit)

### Phase 4 — Notification delivery (only if the approver claims they received nothing)
1. Run Validation Step 6
2. Confirm the request is genuinely visible in the Approvals center — if yes, the underlying approval is healthy and this is purely a notification delivery issue
3. Check for mail rule filtering on Actionable Messages, or missing Teams Approvals app install

### Phase 5 — Platform ceiling
1. Run Validation Step 5
2. If approaching or past 30 days, treat as unrecoverable for that run — the business action must be completed manually and the flow's design revisited (see Playbook 4)

---

## Remediation Playbooks

<details><summary>Playbook 1 — Cancel and resubmit when the assignee list needs to change</summary>

Use when: An assigned approver is departed/unreachable and no other assigned approver exists to respond (or the approval type is "Everyone must approve" and any assignee is unreachable).

```
1. Portal → My Flows → [flow] → Run History → click the stuck run → Cancel run
2. Correct the source data driving approver assignment
   (update the SharePoint list column, Dataverse record, or hardcoded value the
   flow reads its approver list from)
3. Manually re-trigger the flow from the original request, or re-submit the source item
```

**Design fix to prevent recurrence:** replace hardcoded named approvers with a manager-lookup pattern via Graph, or a small rotating pool combined with "First to respond," so no single person's availability blocks the process.

**Rollback:** N/A — cancelling an in-flight run has no effect on already-completed runs.

</details>

<details><summary>Playbook 2 — Add a reminder/escalation sub-flow to avoid indefinite "Everyone must approve" waits</summary>

Use when: Business requirements genuinely need every named approver to respond, but the process needs a timeout/escalation rather than an indefinite wait.

```
Flow redesign pattern:
1. Replace the single "Start and wait for approval" with a child flow pattern:
   a. Start the approval as normal
   b. In parallel, run a "Do until" loop checking elapsed time
   c. If elapsed time exceeds a business-defined threshold (e.g. 3-5 days)
      and the approval is still pending, send a reminder (email/Teams message)
      to non-responding approvers
   d. If a second threshold is exceeded (e.g. 7-10 days), escalate to the
      approver's manager (Graph: GET /users/{id}/manager) with a note about
      the original approver's non-response
2. Keep the outer 30-day platform ceiling in mind as an absolute backstop,
   not the business timeout itself
```

**Rollback:** N/A — additive escalation logic.

</details>

<details><summary>Playbook 3 — Diagnose and fix Teams Adaptive Card button failures</summary>

Use when: The approval card renders in Teams but tapping Approve/Reject does nothing or errors.

```
1. Power Automate portal → Data → Connections → locate the Teams connection
   used by the flow → Test the connection
2. If the test fails, re-authenticate the connection (see Connector-Auth-B.md
   / Connector-Auth-A.md for the full re-auth procedure)
3. Review the approval action's "Custom Responses" configuration if used —
   Adaptive Cards support a limited action set; heavily customized response
   button sets can fail to render correctly or silently no-op on tap
4. As an immediate workaround, direct the approver to
   https://make.powerautomate.com/approvals — this always reflects current
   state regardless of card rendering issues
```

**Reference:** [MS Docs: Approvals connector](https://learn.microsoft.com/en-us/connectors/approvals/)

</details>

<details><summary>Playbook 4 — Redesign around the 30-day run duration ceiling</summary>

Use when: A flow run was auto-terminated before resolution, or the business process can legitimately take longer than 30 days end-to-end.

```
Immediate recovery: manually complete the underlying business action the
approval was gating, and document the exception outside the flow.

Permanent redesign options:
1. Break the process into shorter-lived child flow runs, each triggered by
   the previous stage's completion, rather than one long-running parent run
2. Track overall process state in an external store (SharePoint list,
   Dataverse table) rather than relying on a single flow run's in-memory
   state across the full duration
3. Build the reminder/escalation pattern from Playbook 2 so business
   timeouts are enforced well before the platform's outer 30-day bound
```

**Reference:** [MS Docs: Power Automate limits and configuration](https://learn.microsoft.com/en-us/power-platform/admin/wp-limits-configuration)

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect evidence for an escalated/stuck Power Automate approval
.DESCRIPTION
  Checks approver account/license eligibility for a given list of UPNs, useful
  as the PowerShell-side companion to a manual Run History review (the run
  history and approval action inputs must still be captured manually from
  the portal, as they are not exposed via a supported API for this purpose).
#>
param(
    [Parameter(Mandatory)] [string[]]$ApproverUPNs,
    [string]$OutputPath = "C:\Temp\Approval-Evidence"
)

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$ts = Get-Date -Format "yyyyMMdd-HHmmss"

$report = foreach ($u in $ApproverUPNs) {
    $user = Get-MgUser -UserId $u -Property "displayName,accountEnabled,assignedLicenses" -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        UPN            = $u
        DisplayName    = $user.DisplayName
        AccountEnabled = $user.AccountEnabled
        Licensed       = ($user.AssignedLicenses.Count -gt 0)
    }
}
$report | Format-Table -AutoSize
$report | Export-Csv "$OutputPath\approver-eligibility-$ts.csv" -NoTypeInformation

Write-Host "Evidence collected to: $OutputPath"
Write-Host "Remember to also manually export: Run History screenshot, approval action Inputs, elapsed run duration"
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|---------------------|
| Check approver account/license status | `Get-MgUser -UserId <upn> -Property accountEnabled,assignedLicenses` |
| View the Approvals center directly | `https://make.powerautomate.com/approvals` |
| Test a Teams connector connection | Power Automate portal → Data → Connections → Test |
| View run history for a flow | Portal → My Flows → [flow] → Run History |
| Cancel a stuck run | Run History → click run → Cancel run |
| Look up a user's manager (for escalation flows) | `Get-MgUser -UserId <upn> -Property manager -ExpandProperty manager` |
| Platform run duration limit reference | [MS Docs: Limits and configuration](https://learn.microsoft.com/en-us/power-platform/admin/wp-limits-configuration) |

---

## 🎓 Learning Pointers

- **The assignee list of a running approval cannot be edited — this is a platform design constraint, not a missing feature.** Any process design that depends on a single named individual as sole approver creates an unrecoverable-without-cancellation failure mode the moment that person is unavailable. Prefer manager-lookup or rotating-pool patterns for anything business-critical. [MS Docs: Approvals in Power Automate](https://learn.microsoft.com/en-us/power-automate/create-approval-flow)
- **"Everyone must approve" has no default timeout or escalation — it waits genuinely forever, up to the platform's outer 30-day ceiling.** If the business need is "everyone should approve, but escalate if someone doesn't respond in N days," that escalation has to be built explicitly; the platform will not do it for you.
- **A flow run — approval steps included — is hard-terminated at 30 days regardless of what it's waiting on.** This is an absolute ceiling with no tenant override, so any process that could plausibly take longer needs to be redesigned around shorter-lived runs and external state tracking, not a single long-running flow. [MS Docs: Power Automate limits](https://learn.microsoft.com/en-us/power-platform/admin/wp-limits-configuration)
- **"I never got the approval" and "the approval isn't processing" are different diagnostic branches.** The Approvals service record and its notification delivery are separate concerns — always check the Approvals center directly before assuming the underlying approval is broken; most "I never got it" complaints are a notification delivery issue (mail filtering, missing Teams app), not a flow defect.
- **Directory Setting/connection references and approver lists can silently break when a flow is copied between environments or tenants.** UPNs, connection references, and any hardcoded identity values should be explicitly re-verified after migration rather than assumed to carry over correctly.
