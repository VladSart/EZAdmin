# Purview Priority Cleanup — Exchange Mailboxes (Roadmap 473493) — Hotfix Runbook (Mode B: Ops)
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

**Priority cleanup for Exchange is a distinct configuration from `PriorityCleanupHardDelete-A/B.md`
(the OneDrive/SharePoint variant) — same feature family, different approver model, different
prerequisites, and a live, mature Microsoft Learn conceptual page** (unlike the SharePoint/OneDrive
variant, which as of this writing still has no dedicated Learn page). It lets an admin permanently
delete sensitive content from Exchange mailboxes even when retention policies, Litigation Holds,
eDiscovery holds, or Preservation Lock would otherwise retain it — gated by **three mandatory,
individual-user approvals** every time, regardless of which hold type is in play. Rolling out in
preview and subject to change; GA (Worldwide) currently targeted November CY2026 per Roadmap ID
473493 — re-verify against the live roadmap entry before quoting a date.

```powershell
Connect-IPPSSession -UserPrincipalName <adminUPN>

# 1. Does the requester actually hold the Priority Cleanup Admin role? (auto-added to Organization
#    Management, but must be MANUALLY added to any other role group)
Get-RoleGroupMember -Identity "Organization Management" |
    Where-Object { $_.Name -match "<requester>" }
Get-RoleGroup | Where-Object { $_.Roles -contains "Priority Cleanup Admin" } |
    Get-RoleGroupMember

# 2. Are the three required approver roles staffed at all in this tenant? Policy CREATION fails
#    outright if an assigned approver lacks the matching role -- check BEFORE troubleshooting a
#    failed policy build.
Get-RoleGroup | Where-Object { $_.Roles -match "Priority Cleanup Admin|Retention Management|Search And Purge" } |
    Select-Object Name, Roles

# 3. Is auditing enabled? Required at least 1 day BEFORE the first priority cleanup policy runs,
#    and required to view simulation-mode results at all.
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled

# 4. Does the target mailbox meet the 10-MB minimum? Priority cleanup silently has no effect on
#    mailboxes below this floor.
Get-MailboxStatistics -Identity <mailbox> | Select-Object DisplayName, TotalItemSize
```

| Result | Interpretation |
|---|---|
| Admin can't see "Priority cleanup" in the Purview portal at all | Missing the **Priority Cleanup Admin** role, OR the tenant-wide toggle is off. Go to Fix 1. |
| Policy creation fails with a role-related error at the approver-assignment step | One or more named approvers lack the exact required role combination for their stage (see Dependency Cascade). Go to Fix 2. |
| A user reports a "Retention: `<policy name>` (-1 days)" banner on an email and is alarmed | Expected end-user experience for priority cleanup — **not** a bug, and not silent like a soft-delete. Go to Fix 3. |
| Content under a Litigation Hold or eDiscovery hold isn't being deleted despite a policy targeting it | Working as designed — requires retention-manager and/or eDiscovery-admin approval per hold type present. Go to Fix 4. |
| Admin turned off priority cleanup for Exchange but SharePoint/OneDrive priority cleanup also disappeared (or vice versa) | **Expected — this is one shared tenant-wide toggle covering both workloads.** There is no way to disable one without the other. Go to Fix 5. |
| Simulation mode results never appear, or an approver can't see item content in Pending cleanups | Auditing not enabled in time, or approver missing `Content Explorer List Viewer`/`Content Explorer Content Viewer`. Go to Fix 6. |
| A priority cleanup policy was deleted, but items already approved for deletion still disappeared afterward | Expected — deletion of items with a completed approval process proceeds even if the policy itself is later deleted. Not a bug. |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
[Tenant-wide "Configure priority cleanup" toggle — ON by default]
  |  (single control shared by BOTH Exchange AND SharePoint/OneDrive -- turning it off
  |   disables policy CREATION for both workloads simultaneously)
  v
[Requester holds "Priority Cleanup Admin" role]
  |  (auto-added to Organization Management only -- any other role group needs manual assignment)
  v
[Auditing enabled >= 1 day before first policy run]
  v
[Admin creates a priority cleanup policy scoped to Exchange]
  |
  +-- Adaptive scope (user scope for user mailboxes, M365 Group scope for group mailboxes --
  |     group mailboxes are ONLY supported via adaptive scopes) OR
  +-- Static scope (Exchange Online location; all mailboxes, up to 100 specific mailboxes,
        or -- NOT for attribute-based targeting, which requires adaptive)
  |
  v
[KeyQL query defines matched content -- some eDiscovery-search properties NOT supported:
  SenderAuthor, SubjectTitle, (c:c), (c:s)]
  |
  v
[Three approvers assigned at policy creation -- ALL THREE roles required regardless of
 which hold type is actually present on matched content]
  ├─ Priority Cleanup admin  (role: Priority Cleanup Admin + Data Classification Content/List
  │     Viewer + Disposition Management)          -- always required, first-stage approval
  ├─ Retention manager       (role: Retention Management + same Data Classification/
  │     Disposition roles)                         -- required if content has a retention
  │                                                    policy/label or Litigation Hold
  └─ eDiscovery admin        (role: Search And Purge + Hold + Review + same Data
        Classification/Disposition roles)          -- required if content has an eDiscovery hold
  |
  |  (if ANY named approver lacks their exact required role combination, POLICY CREATION
  |   FAILS OUTRIGHT with an error -- this is checked at creation time, not deletion time)
  v
[Policy mode: Simulation (optional, recommended) | Enabled | Neither yet]
  |
  v
[Content matched >= 10 MB mailbox floor, not a record/regulatory record]
  |
  v
[Two-person-rule approval chain executes: Priority Cleanup admin -> Retention manager
 (if applicable) -> eDiscovery admin (if applicable)]
  |
  v
[All required approvals complete] --> permanent deletion (up to 7 days to apply after
                                        policy turned on) --> item silently disappears
                                        from Outlook, NOT restorable by user, admin, or
                                        Microsoft
  |
  [OR an approver disagrees] --> approver MUST assign an existing retention label to the
                                   item (no plain "reject" option exists)
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the requester's role and the tenant-wide toggle before anything else**
```powershell
Get-RoleGroupMember -Identity "Organization Management" | Where-Object { $_.Name -match "<requester>" }
```
No dedicated cmdlet reads the tenant-wide priority cleanup on/off toggle — confirm directly in
**Purview portal > Data Lifecycle Management > Priority cleanup settings**. Remember this single
toggle governs Exchange AND SharePoint/OneDrive together.

**2. Verify all three approver pools are correctly role-staffed**
```powershell
Get-RoleGroup | Where-Object { $_.Roles -match "Priority Cleanup Admin" } | Get-RoleGroupMember
Get-RoleGroup | Where-Object { $_.Roles -match "Retention Management" } | Get-RoleGroupMember
Get-RoleGroup | Where-Object { $_.Roles -match "Search And Purge" } | Get-RoleGroupMember
```
A policy-creation failure at the approver-assignment step almost always traces back to one named
individual missing one role in their required combination — cross-check the exact table in
`PriorityCleanupExchange-A.md`'s Dependency Stack before re-submitting.

**3. Confirm auditing was enabled early enough**
```powershell
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
```
If this was only just turned on, wait at least 24 hours before creating the first policy, and expect
simulation-mode results to be unavailable until it has been active long enough to capture them.

**4. Check the audit log for the two dedicated priority-cleanup operations**
```powershell
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) `
    -Operations "PriorityCleanupTagApplied","PriorityCleanupDelete" -ResultSize 5000
```
Neither operation has a friendly name in the Purview portal's audit UI as of this writing — search by
the raw operation name, and cross-reference the returned Cleanup ID against the policy's own details
page to confirm which policy generated which deletion.

**5. Confirm mailbox size eligibility for a "nothing happened" complaint**
```powershell
Get-MailboxStatistics -Identity <mailbox> | Select-Object DisplayName, TotalItemSize
```
Mailboxes under 10 MB of data are not eligible for priority cleanup — this is an undocumented-in-UI
silent no-op, not an error.

**6. Confirm group-mailbox targeting used adaptive, not static, scope**
Static scope for Exchange only supports "all mailboxes" or up to 100 explicitly listed mailboxes —
group mailboxes require an adaptive scope with an M365 Group scope selected. A group mailbox silently
excluded from a static-scope policy is a scoping mismatch, not a bug.

---
## Common Fix Paths

<details><summary>Fix 1 — "Priority cleanup" missing from the Purview portal entirely</summary>

Use when: an admin who should have access can't find the feature at all.

```
1. Confirm the requester actually holds the Priority Cleanup Admin role (Diagnosis Step 1) --
   it is NOT automatically present outside the Organization Management role group.
2. Check Purview portal > Data Lifecycle Management > Priority cleanup settings > the tenant-wide
   toggle. If OFF, someone previously disabled it -- confirm with whoever manages compliance policy
   before re-enabling, since this toggle affects SharePoint/OneDrive priority cleanup too (Fix 5).
3. If the toggle is on and the role is assigned, confirm the user is in the Microsoft Purview portal
   (not the legacy Compliance admin center) and has refreshed/re-authenticated recently -- role
   changes can take time to propagate.
```
**Rollback:** N/A — access/visibility fix only.

</details>

<details><summary>Fix 2 — Policy creation fails at the approver-assignment step</summary>

Use when: an admin gets a role-related error while trying to save a new priority cleanup policy.

```
1. Identify exactly which named approver is failing -- Priority Cleanup admin, Retention manager,
   or eDiscovery admin -- from the error text.
2. Cross-check that individual against the FULL required role combination for their stage (not just
   the headline role name):
     - Priority Cleanup admins need: Priority Cleanup Admin + Data Classification Content Viewer +
       Data Classification List Viewer + Disposition Management
     - Retention managers need:      Retention Management + the same two Data Classification roles
       + Disposition Management
     - eDiscovery admins need:       Search And Purge + Hold + Review + the same two Data
       Classification roles + Disposition Management
3. Assign the FULL missing combination via the appropriate role group in Purview permissions --
   partial role assignment is a very common cause of a second, later failure even after the first
   error appears resolved.
4. Re-attempt policy creation only after confirming ALL three approver roles are correctly staffed --
   Exchange priority cleanup always requires all three, unlike SharePoint/OneDrive's simpler
   eDiscovery-admin-only model.
```
**Rollback:** N/A — the policy was never successfully created.

</details>

<details><summary>Fix 3 — End user alarmed by a "Retention" banner on an email</summary>

Use when: a user sees `Retention: <policy name> (-1 days) Expires: <date>` in Outlook and reports it
as a possible phishing/compromise indicator or asks why their mail is being deleted.

```
1. Confirm this matches the exact banner format priority cleanup produces (policy name, "-1 days",
   an expiry date/time) -- this is expected, by-design UX, not a compromise indicator.
2. Explain to the user (or have compliance/legal explain, per org policy) that the named policy is
   scheduled to permanently delete this specific item as part of an approved data-governance action.
3. If end users should NOT see this banner for a specific rollout (e.g. a sensitive spillage
   response), the supported pattern is to run an eDiscovery search-and-purge FIRST to soft-delete the
   item quietly, then apply the priority cleanup policy afterward to permanently delete the already
   soft-deleted item without ever showing the live Retention banner.
4. Do not attempt to suppress or customize the banner itself -- it is not configurable.
```
**Rollback:** N/A — cosmetic/communication fix, not a technical one.

</details>

<details><summary>Fix 4 — Held content isn't being deleted despite a matching policy</summary>

Use when: a priority cleanup policy targets content that's also under a retention policy, Litigation
Hold, or eDiscovery hold, and deletion hasn't happened.

```
1. This is expected gating, not a stuck job. Confirm which hold type is present on the content:
     - Retention policy / label / Litigation Hold present -> requires Retention manager approval
     - eDiscovery hold present -> requires eDiscovery admin approval
     - Both can apply to the same item, requiring both approvals in sequence
2. Route the pending approval to the correct named approver(s) via Purview portal > Data Lifecycle
   Management > Priority cleanup > Pending cleanups (they are also notified by email, with a
   weekly reminder).
3. If an approver disagrees with deletion, they cannot simply reject it -- they must assign an
   existing retention label to the item instead. Confirm your approvers know in advance which label(s)
   are appropriate for this scenario, or approvals will stall on this exact point.
4. Remember Preservation Lock does NOT block Exchange priority cleanup (unlike SharePoint/OneDrive,
   where it only overrides Preservation Lock for delete-only configurations) -- if the org relies on
   Preservation Lock as a hard technical control, the tenant-wide toggle (Fix 5) is the only lever,
   not the hold itself.
```
**Rollback:** N/A — the approval gate is the safeguard functioning correctly.

</details>

<details><summary>Fix 5 — Disabling priority cleanup for one workload disabled it for both</summary>

Use when: an admin turned off priority cleanup expecting to affect only Exchange (or only
SharePoint/OneDrive) and was surprised the other workload's feature also disappeared.

```
1. Confirm this is expected: Purview portal > Data Lifecycle Management > Priority cleanup settings
   exposes ONE toggle that governs policy CREATION for both Exchange and SharePoint/OneDrive
   together. There is no per-workload control.
2. If the intent was to restrict only Exchange (e.g. due to Preservation Lock reliance, per Fix 4),
   the toggle is not the right tool -- the only workload-specific control is simply not creating new
   Exchange-scoped policies; existing policies for the other workload are unaffected by this decision.
3. If the toggle was turned off: existing policies continue to function and can still be deleted, but
   cannot be modified, and no NEW policies of either type can be created until it's turned back on.
```
**Rollback:** Turn the toggle back on in Priority cleanup settings — this does not retroactively
restore any policies that were deleted while it was off, but does restore the ability to create new ones.

</details>

<details><summary>Fix 6 — Simulation mode produces no results, or an approver can't see item content</summary>

Use when: a policy run in simulation mode never returns sample matches, or an approver reports a
blank/inaccessible preview pane on the Pending cleanups page.

```
1. Confirm auditing was enabled AT LEAST 1 day before the policy was created/run (Diagnosis Step 3) --
   simulation results depend on audit data that didn't exist yet if enabled too late.
2. Confirm simulation has had "a couple of hours" to complete, scaled up for tenants with a very
   large number of in-scope mailboxes.
3. Remember a simulation can run for up to 7 days before it must be restarted -- if it's been longer,
   restart the simulation rather than continuing to wait.
4. For a blank preview pane specifically, confirm the approver holds Content Explorer List Viewer AND
   Content Explorer Content Viewer -- these are required in addition to their stage-specific approval
   role and are easy to miss since they're not mentioned in the headline role name.
```
**Rollback:** N/A — diagnostic/access fix.

</details>

---
## Escalation Evidence

```
PURVIEW PRIORITY CLEANUP (EXCHANGE) ESCALATION
====================================================
Date/Time                                        :
Tenant cloud (Worldwide/GCC/GCC High/DoD)        :
Affected mailbox(es)                             :
Priority cleanup policy name / Cleanup ID        :
Scope type (Adaptive/Static) and targeting       :
Hold type(s) present on matched content          :
Required approver(s) and role(s) confirmed       :
Approval obtained? Stage(s) still pending?       :
Tenant-wide priority cleanup toggle status       :
Auditing enabled date (vs. policy creation date) :
Audit log entries found (PriorityCleanupTagApplied / PriorityCleanupDelete) :
Mailbox met 10-MB minimum?                       :
Business/legal sign-off on file for this policy  :
Steps Already Tried                              :
```

---
## 🎓 Learning Pointers

- **This is NOT the same configuration as `PriorityCleanupHardDelete-A/B.md`.** Same underlying
  feature family and the same shared tenant-wide toggle, but Exchange requires three mandatory
  individual-user approvals every time (Priority Cleanup admin, Retention manager, eDiscovery admin),
  while SharePoint/OneDrive requires only a second Priority Cleanup admin plus an eDiscovery admin.
  Never assume one workload's approver setup satisfies the other.
- **The tenant-wide toggle is shared — there is no way to enable/disable just one workload.** This is
  the single most consequential architectural fact for triage: a "priority cleanup disappeared"
  ticket for either workload should always prompt checking whether someone recently changed the
  *other* workload's configuration.
- **Policy creation fails at save-time if any named approver lacks their exact role combination** —
  this surfaces as a creation error, not a silent misconfiguration discovered later. Always verify all
  three approver role sets *before* attempting policy creation, not after a failure.
- **The end-user Outlook banner is intentional and not configurable.** If a client needs a quiet
  deletion, the documented pattern is eDiscovery search-and-purge first (soft-delete), then priority
  cleanup second — not a request to suppress the banner, which isn't possible.
- **Preservation Lock does not block Exchange priority cleanup at all** (contrast with
  SharePoint/OneDrive's partial, delete-only-config exception) — organizations relying on
  Preservation Lock as a hard technical stop against any override should treat the tenant-wide toggle,
  not the hold itself, as their actual control point.
- Microsoft Learn: [Use priority cleanup to expedite the permanent deletion of sensitive information from mailboxes](https://learn.microsoft.com/en-us/purview/priority-cleanup-exchange). Roadmap ID [473493](https://www.microsoft.com/microsoft-365/roadmap?filters=&searchterms=473493) (In development; GA targeted November CY2026 — reverify before quoting).
