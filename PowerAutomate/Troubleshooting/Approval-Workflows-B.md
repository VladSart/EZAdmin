# Power Automate Approval Workflows — Hotfix Runbook (Mode B: Ops)
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

```
1. Open the flow's Run History for the stuck/failing run
   Portal → My Flows → [flow] → Run History → click the in-progress or failed run
   Look at the "Start and wait for an approval" action — is it still "Running" (waiting) or did it error?

2. Check who the approval was sent to
   Click into the approval action → Inputs → note the "Assigned to" list

3. Check the approver's account status
```
```powershell
Get-MgUser -UserId "<approverUPN>" | Select-Object DisplayName, AccountEnabled, Mail
```
```
4. Check the approval type configuration
   Inputs → "Approval type" — is it "Approve/Reject - First to respond" or "Everyone must approve"?
   This determines whether ONE response completes the step or ALL assigned approvers must respond

5. Check whether the run has hit the platform's maximum run duration
   Run History → run start time — if it has been running longer than 30 days, it will be
   auto-terminated by the platform regardless of approver action
```

**Interpret:**

| Observation | Action |
|-------------|--------|
| Approver account disabled/deleted | Cancel run, reassign — [Fix 1](#fix-1--approver-account-disabled-or-departed) |
| "Everyone must approve" but one approver never responds | Reconfigure or manually complete — [Fix 2](#fix-2--everyone-must-approve-stuck-on-one-non-responder) |
| Approver says they never got a notification | Check Approvals app / email delivery — [Fix 3](#fix-3--approver-never-received-notification) |
| Run duration approaching or past 30 days | Escalate for manual resolution — [Fix 4](#fix-4--30-day-maximum-run-duration-reached) |
| Teams Adaptive Card buttons unresponsive | Check Teams connector permissions — [Fix 5](#fix-5--teams-approval-card-buttons-not-working) |

---

## Dependency Cascade

<details><summary>What must be true for an approval step to complete</summary>

```
[Flow reaches "Start and wait for an approval" action]
        │
        ▼
[Approval request record created in the Approvals service]
        │
        ▼
[Notification delivered to assigned approver(s)]
   ├─ Outlook — email with Approve/Reject action buttons (requires Actionable Messages support)
   ├─ Teams — Adaptive Card via the Approvals app (requires app installed + connector permission)
   └─ Approvals mobile/web app (Approvals center)
        │
        ▼
[Approver responds]
   ├─ "First to respond" mode → ANY one response completes the step
   └─ "Everyone must approve" mode → ALL assigned approvers must respond before the step completes
        │
        ▼
[Flow resumes with the approval outcome]
        │
        ▼
[Platform-level run duration ceiling: 30 days per flow run]
   └─ If no approver responds within this window, the run is terminated regardless of business need
```

**Key fact:** once an approval step is running, you cannot edit *who* it was sent to for that specific run — reassigning an approver requires either cancelling the run and starting a new one, or having a currently-assigned approver respond.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the approval is actually still pending, not silently failed**
```
Run History → click the run → find the approval action → check its status:
"Running" = still waiting on a response (normal, not an error)
"Failed"  = something else broke (connector auth, invalid input) — treat as a separate connector issue
```

**Step 2 — Identify exactly who was assigned**
```
Approval action → Inputs → "Assigned to" field
Confirm this is a list of individual UPNs, not a distribution list or security group —
approval actions require named individuals, not group expansion
```

**Step 3 — Check each assigned approver's account and licence status**
```powershell
$approvers = "<approver1UPN>","<approver2UPN>"
foreach ($u in $approvers) {
    Get-MgUser -UserId $u -Property "displayName,accountEnabled,assignedLicenses" |
      Select-Object DisplayName, AccountEnabled, @{N='Licensed';E={$_.AssignedLicenses.Count -gt 0}}
}
```
Expected: `AccountEnabled = True` and at least one licence for all approvers. A disabled account or removed licence silently breaks that approver's ability to respond.

**Step 4 — Check the approval type / completion logic**
```
Inputs → "Approval type":
  "Approve/Reject - First to respond" → step completes on the first response received
  "Approve/Reject - Everyone must approve" → step waits until EVERY assigned approver has responded
```
If configured as "Everyone must approve" and one approver is unavailable (OOO, departed, disabled), the step will wait indefinitely — this is expected behaviour for that configuration, not a bug.

**Step 5 — Check elapsed run time against the 30-day ceiling**
```
Run History → note the run's start timestamp
Compare to current date — flows (including in-progress approvals) are automatically
terminated by the platform after 30 days of continuous running, regardless of approver action
```

---

## Common Fix Paths

<details><summary>Fix 1 — Approver account disabled or departed</summary>

**You cannot edit an in-flight approval's assignee list.** The only ways to unblock it:

**Option A — have a remaining valid approver respond (if "First to respond" mode):**
No action needed if another assigned approver is still active — advise them to complete it.

**Option B — cancel and resubmit (required for "Everyone must approve" mode, or if all approvers are unreachable):**
```
1. Portal → My Flows → [flow] → Run History → click the stuck run → Cancel run
2. Edit the flow's approver list (or the source data driving it) to remove the departed user
3. Manually re-trigger the flow / re-submit the original request
```

**Best practice going forward:** avoid hardcoding named individuals as sole approvers for business-critical flows — use a manager-lookup pattern (e.g., look up `manager` via Graph) or a small rotating group with "First to respond" so single-person-dependency doesn't block the process.

**Rollback:** N/A — cancelling a stuck run does not affect completed runs.

</details>

<details><summary>Fix 2 — "Everyone must approve" stuck on one non-responder</summary>

```
1. Confirm this is genuinely the configured behaviour: Inputs → Approval type → "Everyone must approve"
2. If this is not the desired business behaviour, edit the flow (not just this run):
   Change Approval type to "First to respond" and republish
   Note: this only affects FUTURE runs — the currently stuck run keeps its original configuration
3. For the currently stuck run: the only way to complete it is for every remaining
   un-responded approver to respond, or to cancel the run
```

**Rollback:** Changing approval type is a flow-definition change — revert by editing the flow again if the "everyone must approve" requirement was intentional for a compliance reason.

</details>

<details><summary>Fix 3 — Approver never received notification</summary>

```
1. Confirm the Approvals app is installed for the approver:
   Outlook — check for "Actionable Messages" support (Options → Mail → look for Actionable Messages setting, should be enabled)
   Teams — confirm the "Approvals" app is added to their Teams client (Apps → search "Approvals")

2. Check the approver's mail rules aren't filtering the notification
   (Actionable Message emails from Power Automate can be caught by aggressive spam/rule filtering)

3. Have the approver check the Approvals center directly instead of relying on the notification:
   https://make.powerautomate.com/approvals  (or the Approvals app in Teams/Outlook)
   Pending approvals show here even if the notification itself didn't arrive
```

If the approver can see it in the Approvals center but never got notified, this is a notification delivery issue (email filtering, Teams app not installed) rather than a flow issue — the approval itself is intact.

</details>

<details><summary>Fix 4 — 30-day maximum run duration reached</summary>

**When:** The flow run was automatically terminated with a timeout/duration error before anyone approved.

This is a hard platform limit — approval flows (or any flow using long delays/waits) cannot run longer than 30 days in a single execution. There is no override.

```
For urgent one-off recovery: manually complete the underlying business action
(the thing the approval was gating) and communicate the exception outside the flow.

For a permanent fix, redesign the flow:
1. Set a shorter internal reminder cadence (e.g. a child flow that re-sends the
   approval request every 3-5 days if no response, using a "Do until" loop with
   a nested approval + condition check)
2. Add an explicit escalation path (auto-escalate to the approver's manager) if the
   original approver hasn't responded within a business-appropriate window (e.g. 5 days) —
   don't rely on the 30-day platform ceiling as your business timeout
```

</details>

<details><summary>Fix 5 — Teams approval card buttons not working</summary>

**When:** The Adaptive Card appears in Teams but clicking Approve/Reject does nothing, or the card shows an error.

```
1. Confirm the Approvals app is added and the connector has current Teams permissions:
   Power Automate portal → Data → Connections → find the Teams connection used by the flow → Test

2. Re-authenticate the Teams connection if the test fails (see Connector-Auth-B.md)

3. Check the card wasn't built with more than the supported number of actions —
   Adaptive Cards in Teams approval notifications support a limited action set;
   overly customised "Custom Responses" configurations with many buttons can fail to render
   or fail silently on tap

4. As a fallback, direct the approver to the Approvals center web/app view instead of
   the Teams card — this always reflects current state even if the card itself is misbehaving
```

**Reference:** [MS Docs: Approvals connector](https://learn.microsoft.com/en-us/connectors/approvals/)

</details>

---

## Escalation Evidence

```
Power Automate Approval — Escalation Evidence
====================================================
Flow name:                     
Run Id / start time:           
Approval type:                 [First to respond / Everyone must approve]
Assigned approver(s):          
Approver account status:       [Enabled/Disabled, Licensed Y/N — per approver]
Current run status:            [Running / Failed / Cancelled]
Elapsed run duration:          
Notification method:           [Outlook email / Teams card / both]
Notification received (per approver): 
Visible in Approvals center:   [Y/N]
Business deadline for this approval: 
Steps already taken:
  [ ] Checked Approvals center directly
  [ ] Verified approver account/licence status
  [ ] Confirmed approval type configuration
  [ ] Checked elapsed run time against 30-day limit
```

---

## 🎓 Learning Pointers

- **You cannot edit who an in-flight approval was sent to.** The assignee list is fixed at the moment the "Start and wait for an approval" action fires. If an approver becomes unavailable mid-run, your only options are waiting for a remaining approver ("First to respond" mode) or cancelling and resubmitting. Design approval flows with this constraint in mind — avoid single-named-approver dependencies for anything business-critical. [MS Docs: Approvals in Power Automate](https://learn.microsoft.com/en-us/power-automate/create-approval-flow)
- **Flow runs — including a "waiting" approval — are automatically terminated after 30 days.** This is a hard platform ceiling, not a configurable timeout. If your business process can legitimately take longer than 30 days to get sign-off, you need an external tracking/escalation mechanism, not a single long-running flow. [MS Docs: Power Automate limits](https://learn.microsoft.com/en-us/power-platform/admin/wp-limits-configuration)
- **"Everyone must approve" waits for literally everyone, forever, with no built-in timeout or escalation.** If one assigned approver goes on leave or leaves the company, the flow simply waits. Pair this approval type with your own reminder/escalation sub-flow rather than assuming the platform will nudge anyone.
- **Approval notifications can fail to arrive even when the approval itself is healthy.** Actionable Message emails are sometimes caught by mail filtering rules, and the Teams Approvals app must be explicitly installed for card notifications to render. Always point a "I never got the request" complaint at the Approvals center (make.powerautomate.com/approvals) before assuming the flow is broken.
- **Approval actions require named individual accounts, not distribution lists or security groups.** A flow that appears to "assign" a group as approver either wasn't configured that way (check Inputs carefully) or is quietly only notifying whichever individual accounts were expanded into the list at design time — group membership changes after the flow was built won't be picked up.
