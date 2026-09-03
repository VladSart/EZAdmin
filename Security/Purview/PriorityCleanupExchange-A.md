# Purview Priority Cleanup — Exchange Mailboxes (Roadmap 473493) — Reference Runbook (Mode A: Deep Dive)
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
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

Covers Microsoft Purview Data Lifecycle Management's **priority cleanup** capability as applied to
**Exchange Online mailboxes** — a policy type that permanently deletes content matching a KeyQL query
even when that content is protected by a retention policy, retention label, Litigation Hold,
eDiscovery hold, or **Preservation Lock**. Tracked as Microsoft 365 Roadmap ID **473493** ("In
development" as of this writing, GA targeted November CY2026), documented on a live, mature Microsoft
Learn conceptual page (`ms.date` 2025-12-03, `updated_at` 2026-07-01) — this is a materially different
source-confidence situation from this repo's `PriorityCleanupHardDelete-A/B.md` (the SharePoint/
OneDrive variant), which as of this writing has no dedicated Learn page and is built from a
five-times-revised Message Center notification alone.

**Covers:**
- The Exchange-specific policy model: KeyQL-based scoping, the mandatory three-approver chain, and
  the retention-label-under-the-hood mechanism
- The full comparison between Exchange and SharePoint/OneDrive priority cleanup behavior — they share
  a name, a tenant-wide enable/disable toggle, and a general "override with approval" philosophy, but
  differ in nearly every configuration and approval detail
- Permissions, prerequisites, limitations, and the end-user experience specific to mailboxes
- Auditing and monitoring surface (the two dedicated operation names, and their current lack of
  friendly names in the portal)

**Does not cover:**
- SharePoint/OneDrive priority cleanup configuration and behavior in detail — see
  `PriorityCleanupHardDelete-A.md`, cross-referenced throughout this document for contrast only
- Standard (non-priority-cleanup) Exchange retention policy/label configuration — see
  `M365/Exchange/ArchiveRetention-A.md` and `Security/Purview/RetentionLabels-A.md`
- eDiscovery case/hold administration generally — see `eDiscovery-A.md`; this document assumes
  familiarity with what a Litigation Hold and eDiscovery hold are and focuses only on how priority
  cleanup interacts with them
- Backup/DR strategy — referenced only insofar as this feature increases the consequence of not
  having one, since deletions here are irreversible by every party including Microsoft

**Build context:** Priority cleanup for Exchange was first announced under Message Center MC971035 /
Roadmap 392838 in January 2025 and repeatedly delayed (six tracked Message Center revisions, most
recently "delayed to a later date" as of August 2025). The feature later reappeared under a distinct
roadmap ID, **473493**, first published April 2026, most recently updated June 2026, currently listed
"In development" with **GA date: November CY2026**. The corresponding Learn page is live and detailed,
suggesting the underlying engineering is materially further along than the "In development" status
label alone implies — but the roadmap's own GA date should still be re-verified before being quoted
to a client, given this feature's multi-year history of schedule slips.

---
## How It Works

<details><summary>Full architecture</summary>

### The problem this addresses

Standard Purview retention is preservation-biased by design: when multiple retention policies, labels,
or holds apply to the same item, [the principles of retention](https://learn.microsoft.com/en-us/purview/retention#the-principles-of-retention-or-what-takes-precedence)
mean the longest retention or any active hold always wins over a shorter retention or a delete action.
This is the correct default for compliance, but it creates a real operational problem: a data spillage
incident, a privacy deletion request (e.g. GDPR-style "right to erasure"), or a regulatory-driven
deletion requirement can require permanently removing *specific* sensitive content from a mailbox that
is otherwise legitimately under a two-year retention policy or an active Litigation Hold — and prior to
this feature, the only supported path was releasing the hold or waiting out the retention period
entirely, an all-or-nothing choice with real legal risk.

Priority cleanup for Exchange is a narrow, heavily-gated exception to the preservation-wins principle:
specific matched content can be permanently deleted **despite** a hold or retention policy — including,
notably, despite **Preservation Lock** (the strongest available retention safeguard, normally used by
highly-regulated organizations specifically to prevent any policy weakening) — but only after a defined
chain of human approvals completes.

### The policy model

Under the covers, **priority cleanup uses retention labels with auto-apply policies** — the same
underlying mechanism this repo documents in `RetentionLabels-A.md` and `CopilotRetentionRecommendations-A.md`.
The admin never interacts with these labels/policies directly; Purview creates and manages them as an
implementation detail. The critical architectural point is that these generated labels **supersede the
normal principles of retention** to achieve the requested expedited deletion — this is Microsoft's own
stated design, not an incidental side effect, and it's why priority cleanup can reach behind a
Litigation Hold or Preservation Lock where a manually-created retention label never could.

A priority cleanup policy for Exchange is built from:
1. **Scope type** — Adaptive (built from one or more pre-created adaptive scopes; required for group
   mailboxes) or Static (Exchange Online location, either all mailboxes or up to 100 explicitly named
   mailboxes; static scope cannot target mailboxes by attribute — that requires adaptive).
2. **A KeyQL query** — the same search index used by eDiscovery content search, entered as a
   Keyword Query Language expression (e.g. `AttachmentNames:ContosoEmployeeSalaries.xlsx AND sent>=2024-02-02`).
   Not every eDiscovery search property/condition is supported: `SenderAuthor`, `SubjectTitle`, `(c:c)`,
   and `(c:s)` are explicitly excluded.
3. **A deletion timing choice** — delete matched items as soon as possible (the common case), or retain
   them for a specific period first (used only when compliance requires a defined retention window that
   a standard retention label can't otherwise express for this content).
4. **Three named approvers**, assigned at policy creation, each requiring an exact role combination
   (see Dependency Stack) — this is the single largest configuration difference from the
   SharePoint/OneDrive variant.
5. **A policy mode** — Simulation (recommended, not mandatory for Exchange — contrast with
   SharePoint/OneDrive, where simulation IS mandatory before enabling), Enabled, or neither yet.

### The mandatory two-person-rule approval chain

Every priority cleanup item for Exchange requires **three approvals**, unconditionally, regardless of
which specific hold type is actually present on the matched content:

1. **Priority cleanup admin approval** — always required, first stage.
2. **Retention manager approval** — required if the item is subject to a retention policy, retention
   label, or Litigation Hold.
3. **eDiscovery admin approval** — required if the item is subject to an eDiscovery hold.

This is a materially stricter model than SharePoint/OneDrive, where only a second priority-cleanup
admin (assigned during policy configuration, before the policy is even turned on) plus an eDiscovery
admin are involved. Microsoft's own comparison table (reproduced in the Command Cheat Sheet below)
documents this and several other Exchange-vs-SharePoint/OneDrive differences explicitly — this repo
treats that table as the canonical reference for which behavior applies to which workload.

If an approver disagrees that an item should be permanently deleted, there is **no plain "reject"
option** — disposition review's usual mechanics don't apply here. The approver must instead assign an
existing retention label to the item. Approvers who don't already know which label(s) are appropriate
for this scenario will stall the approval chain at exactly this step; this should be established as
part of onboarding any approver, not discovered mid-incident.

### What is explicitly NOT changed, and what is genuinely new

- The **standard Recycle Bin / Recoverable Items deletion lifecycle** for ordinary user or admin
  deletions is untouched; priority cleanup is an additional, separate deletion path.
- The feature is **enabled by default at the tenant level** once available in a tenant (unlike its
  SharePoint/OneDrive sibling's messaging, which also states default-on, both share the same
  underlying toggle — see below) — the built-in multi-approval safeguards are Microsoft's stated reason
  it ships default-on rather than default-off.
- **The tenant-wide enable/disable toggle is shared between Exchange and SharePoint/OneDrive.**
  Turning off priority cleanup at **Data Lifecycle Management > Priority cleanup settings** disables
  the ability to create NEW policies of *either* type. There is no independent per-workload control.
  Existing policies of either type continue to function, continue to be deletable, but cannot be
  modified while the toggle is off.
- Auditing must be enabled **at least one day before** the first priority cleanup policy is created —
  this is a hard prerequisite for simulation-mode results specifically, not merely a best practice.
- Group mailboxes are supported **only** via adaptive scopes — there is no static-scope path for them.

</details>

---
## Dependency Stack

```
[Purview tenant licensing — Microsoft Purview service description tier gating this feature]
        |
[Tenant-wide "Configure priority cleanup" toggle — shared across Exchange + SharePoint/OneDrive]
        |
[Auditing enabled >= 1 day before first policy]
        |
[Priority Cleanup Admin role assigned to the policy creator]
   (auto-present in Organization Management only; manual assignment required elsewhere)
        |
[Adaptive scope(s) pre-created]  <-- only if using Adaptive scope type
        |
[Policy definition: scope type + KeyQL query + timing choice + policy mode]
        |
[Three named, individual-user approvers assigned -- EACH must hold their FULL role combination
 or policy creation fails outright at save time]
   ├─ Priority Cleanup admin -> Priority Cleanup Admin + Data Classification Content Viewer +
   │        Data Classification List Viewer + Disposition Management
   ├─ Retention manager      -> Retention Management + Data Classification Content Viewer +
   │        Data Classification List Viewer + Disposition Management
   └─ eDiscovery admin       -> Search And Purge + Hold + Review + Data Classification Content
            Viewer + Data Classification List Viewer + Disposition Management
        |
[Mailbox >= 10 MB of data]  <-- below this floor, mailbox is silently ineligible
        |
[Item is NOT a record or regulatory record]  <-- hard exclusion, no override
        |
[Item evaluated against KeyQL query via the eDiscovery content-search index]
        |
[Match found] -> [Hold/retention status checked]
   ├─ No hold/retention on item -> deleted directly (priority-cleanup-admin approval still required)
   ├─ Retention policy/label/Litigation Hold present -> + Retention manager approval required
   ├─ eDiscovery hold present -> + eDiscovery admin approval required
   └─ Already copied into an eDiscovery review set -> survives priority cleanup; only removed
         when the entire eDiscovery case is deleted by an eDiscovery admin
        |
[All required approvals obtained] -- up to 7 days to apply after policy enabled --
        |
[Permanent deletion] -> Outlook "Retention: <name> (-1 days)" banner shown pre-deletion ->
        item silently disappears from Outlook -> NOT restorable by user, admin, or Microsoft
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| "Priority cleanup" option not visible in Purview portal | Missing Priority Cleanup Admin role, or tenant-wide toggle off | `Get-RoleGroup \| Where-Object { $_.Roles -contains "Priority Cleanup Admin" }`; confirm toggle in portal settings |
| Policy creation errors out at the approver step | A named approver lacks one or more roles in their exact required combination | Cross-check each approver against the Dependency Stack's three role lists individually |
| Group mailbox not being matched by a policy | Static scope was used; group mailboxes require Adaptive scope with an M365 Group scope | Review the policy's scope type configuration |
| KeyQL query returns zero/unexpected matches | Query uses an unsupported property (`SenderAuthor`, `SubjectTitle`, `(c:c)`, `(c:s)`) | Rebuild the query using only supported eDiscovery-search properties |
| Simulation mode shows email items marked as records/regulatory records | Documented simulation-mode display quirk — these items are NOT actually in scope outside simulation | Re-confirm against the live enabled policy's actual matched-item count, not the simulation preview alone |
| A specific mailbox never shows any activity from an otherwise-broad policy | Mailbox has < 10 MB of data | `Get-MailboxStatistics -Identity <mbx> \| Select TotalItemSize` |
| Approval stalls indefinitely at the retention-manager or eDiscovery-admin stage | Named approver unaware they must assign a retention label instead of simply declining | Confirm approver training/runbook access; identify the correct label to assign |
| Item was under an eDiscovery hold, approved, but still recoverable via eDiscovery | Item had already been copied into an eDiscovery review set before priority cleanup ran | Delete the entire eDiscovery case (by an eDiscovery admin) to remove the review-set copy |
| SharePoint/OneDrive priority cleanup also became unavailable after an Exchange-focused change | Someone toggled the shared tenant-wide control, not a workload-specific one | Confirm via Purview portal > Priority cleanup settings; there is only one toggle |
| Policy was deleted but items still got permanently deleted afterward | Expected — approvals already completed before deletion continue to be honored even if the policy is later removed | Not a bug; confirm via audit log timestamps relative to policy deletion |

---
## Validation Steps

**1. Confirm licensing and role prerequisites**
```powershell
Connect-IPPSSession -UserPrincipalName <adminUPN>
Get-RoleGroup | Where-Object { $_.Roles -contains "Priority Cleanup Admin" } | Get-RoleGroupMember
```
Expect the requester to appear under Organization Management by default, or under a role group they
were manually added to. No membership anywhere → the role must be assigned before proceeding.

**2. Confirm auditing has been enabled long enough**
```powershell
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled, AdminAuditLogEnabled
```
`UnifiedAuditLogIngestionEnabled` should be `True`, and should have been true for at least 24 hours
before the first policy's creation date — compare against the policy's own creation timestamp in the
portal.

**3. Confirm all three approver role combinations before policy creation, not after a failure**
```powershell
foreach ($approver in @('<pc-admin-upn>','<retention-mgr-upn>','<ediscovery-admin-upn>')) {
    Write-Host "Checking $approver" -ForegroundColor Cyan
    Get-RoleGroup | Where-Object { (Get-RoleGroupMember -Identity $_.Name | Select-Object -ExpandProperty PrimarySmtpAddress) -contains $approver } |
        Select-Object Name, Roles
}
```
Manually cross-reference each returned role set against the three required combinations in the
Dependency Stack — there is no single cmdlet that validates this holistically.

**4. Confirm mailbox eligibility for targeted content**
```powershell
Get-MailboxStatistics -Identity <mailbox> | Select-Object DisplayName, TotalItemSize, ItemCount
```

**5. Validate the KeyQL query independently via eDiscovery before trusting priority cleanup simulation**
Since priority cleanup uses the same search index as eDiscovery content search, run the equivalent
query as an eDiscovery (Premium) content search first to sanity-check expected match volume before
committing it to a priority cleanup policy — this avoids discovering a query logic error only after
a multi-day simulation cycle.

**6. Confirm the tenant-wide toggle state before troubleshooting "feature missing" reports**
Portal-only: **Data Lifecycle Management > Priority cleanup settings**. No PowerShell/Graph read
surface is confirmed for this toggle as of this writing.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Access and prerequisites**
1. Confirm Priority Cleanup Admin role assignment for the requester (Validation Step 1).
2. Confirm the tenant-wide toggle is on (Validation Step 6).
3. Confirm auditing has been enabled for >= 24 hours (Validation Step 2).

**Phase 2 — Policy design**
4. Confirm scope type matches the target population — adaptive for group mailboxes or
   attribute-based targeting, static for a small known list or "all mailboxes."
5. Validate the KeyQL query against eDiscovery content search directly (Validation Step 5) before
   embedding it in a priority cleanup policy.
6. Confirm all three approvers are correctly role-staffed (Validation Step 3) — do this before
   attempting to save the policy, since a failure here blocks creation entirely.

**Phase 3 — Simulation and rollout**
7. Run in simulation mode first (recommended, though not mandatory for Exchange). Allow up to a
   couple of hours for results on typical tenants; scale expectations for very large mailbox counts.
8. Remember a simulation expires after 7 days and must be restarted if not acted on.
9. Cross-check simulation output against Symptom → Cause Map's records/regulatory-records display
   quirk before treating every simulation-surfaced item as a genuine future deletion target.

**Phase 4 — Approval and monitoring**
10. Once enabled, allow up to 7 days for the policy to apply to matched items and trigger approvals.
11. Monitor **Pending cleanups** for stalled approvals; confirm approvers understand the
    relabel-instead-of-reject mechanic (Fix 4 in the Mode B runbook).
12. Search the unified audit log using the policy's Cleanup ID as the search term to trace an
    end-to-end deletion timeline for a specific item or batch.

**Phase 5 — Post-incident review**
13. Export **Pending cleanups** and **Disposed items** views to CSV for the record, before or after
    resolution, since this is the most complete non-audit-log view of what was reviewed and by whom.
14. If content survived deletion because it was already in an eDiscovery review set, confirm with the
    eDiscovery case owner whether case deletion is appropriate — this is the only way to remove that
    copy, and it is a separate, case-level decision outside priority cleanup itself.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standing up Exchange priority cleanup for the first time in a tenant</summary>

```
1. Confirm business/legal sign-off for the specific use case (data spillage response, privacy
   deletion request, or regulatory-driven deletion) BEFORE any technical configuration -- this
   feature is irreversible by every party, including Microsoft, once approvals complete.
2. Confirm the tenant-wide toggle is on (default) and enable auditing if not already enabled --
   wait 24 hours before proceeding to policy creation.
3. Identify and role-assign three distinct individuals for the Priority Cleanup admin, Retention
   manager, and eDiscovery admin approver stages, each with their FULL role combination (Dependency
   Stack) -- confirm this BEFORE attempting policy creation to avoid a save-time failure.
4. Build and validate the KeyQL query against eDiscovery content search directly first.
5. Create the policy in Simulation mode. Review simulation results (allow a couple of hours; note the
   records/regulatory-records display quirk) with all three approvers before enabling.
6. Enable the policy only after simulation results are confirmed correct and approvers have
   acknowledged the relabel-instead-of-reject mechanic.
7. Document the Cleanup ID and monitor Pending cleanups / the audit log through to completion.
```
**Rollback:** Disable or delete the policy before approvals complete to prevent further matches from
being queued — this does not affect items already fully approved and does not restore anything
already permanently deleted.

</details>

<details><summary>Playbook 2 — Data spillage response using priority cleanup</summary>

```
1. If the immediate goal is to stop further exposure quietly (without alerting the sender/recipients
   via the visible Outlook retention banner), run eDiscovery search-and-purge FIRST to soft-delete the
   affected items across all identified mailboxes.
2. Once soft-deleted items are confirmed, build a priority cleanup policy scoped narrowly (via KeyQL,
   ideally matching the exact same criteria used in the search-and-purge) to permanently delete them,
   bypassing the standard Recoverable Items purge timeline.
3. Use Static scope with an explicit, reviewed list of affected mailboxes wherever the population is
   under 100 mailboxes and precisely known -- this is faster and less error-prone than an adaptive
   scope for a one-time incident response action.
4. Skip simulation mode only if time-criticality justifies it and Retention manager/eDiscovery admin
   approvers are on standby to approve immediately -- otherwise use simulation to confirm scope first.
5. After deletion completes, export Disposed items to CSV as part of the incident record.
```
**Rollback:** None after approvals complete and deletion executes — pre-deletion, disabling the policy
prevents further items from being queued.

</details>

<details><summary>Playbook 3 — Recovering from an approver stall</summary>

```
1. Identify the specific stage where approval is stalled (Priority Cleanup admin / Retention
   manager / eDiscovery admin) via the Pending cleanups page.
2. Confirm the assigned approver for that stage is still active in the organization and still holds
   their required role combination -- role or employment changes since policy creation are a common,
   easily-missed cause of silent stalls (no automated re-routing exists).
3. If the approver disagrees with permanent deletion, confirm they understand they must assign an
   existing retention label rather than simply doing nothing or looking for a reject button.
4. If the original approver has left the organization or lost role access, this may require deleting
   and recreating the policy with a valid approver rather than reassigning approvers on an existing
   policy -- confirm current portal capability directly, as approver-reassignment-on-an-existing-
   policy is not documented as supported.
```
**Rollback:** N/A — process remediation, not a technical rollback.

</details>

---
## Evidence Pack

```powershell
<#
Collects tenant-level readiness/evidence for a Purview Priority Cleanup (Exchange) escalation.
Read-only. Requires Connect-IPPSSession with Compliance/eDiscovery read rights.
#>
$evidence = [ordered]@{}

$evidence.AuditingEnabled = (Get-AdminAuditLogConfig).UnifiedAuditLogIngestionEnabled

$evidence.PriorityCleanupAdmins = Get-RoleGroup |
    Where-Object { $_.Roles -contains "Priority Cleanup Admin" } |
    ForEach-Object { Get-RoleGroupMember -Identity $_.Name } |
    Select-Object -ExpandProperty Name -Unique

$evidence.RetentionManagers = Get-RoleGroup |
    Where-Object { $_.Roles -contains "Retention Management" } |
    ForEach-Object { Get-RoleGroupMember -Identity $_.Name } |
    Select-Object -ExpandProperty Name -Unique

$evidence.EDiscoveryAdmins = Get-RoleGroup |
    Where-Object { $_.Roles -contains "Search And Purge" -and $_.Roles -contains "Hold" } |
    ForEach-Object { Get-RoleGroupMember -Identity $_.Name } |
    Select-Object -ExpandProperty Name -Unique

$evidence.RecentPriorityCleanupAudit = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-90) `
    -EndDate (Get-Date) -Operations "PriorityCleanupTagApplied","PriorityCleanupDelete" -ResultSize 5000

$evidence | ConvertTo-Json -Depth 4 | Out-File "$env:TEMP\PriorityCleanupExchange-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
Write-Host "Evidence pack written. NOTE: tenant-wide toggle state and policy configuration details" -ForegroundColor Yellow
Write-Host "have no confirmed PowerShell/Graph read surface -- capture those directly from the portal." -ForegroundColor Yellow
```

---
## Command Cheat Sheet

| Command / Reference | Purpose |
|---|---|
| `Get-RoleGroup \| Where-Object { $_.Roles -contains "Priority Cleanup Admin" }` | Find which role groups grant Priority Cleanup Admin |
| `Get-RoleGroupMember -Identity <group>` | List members of a specific role group |
| `Get-AdminAuditLogConfig` | Confirm unified audit log ingestion state |
| `Get-MailboxStatistics -Identity <mbx> \| Select TotalItemSize` | Check the 10-MB minimum-size eligibility floor |
| `Search-UnifiedAuditLog -Operations "PriorityCleanupTagApplied","PriorityCleanupDelete"` | Trace priority cleanup activity (no friendly names in portal yet) |
| Purview portal > Data Lifecycle Management > Priority cleanup | Create/manage policies (portal-only for policy CRUD) |
| Purview portal > Priority cleanup settings | The single tenant-wide toggle shared by Exchange + SharePoint/OneDrive |
| Purview portal > Pending cleanups | Approver review queue; source of the Cleanup ID for audit correlation |

**Exchange vs. SharePoint/OneDrive priority cleanup — Microsoft's own comparison, reproduced for quick reference:**

| Behavior | Exchange | SharePoint/OneDrive |
|---|---|---|
| Typical use case | Data spillage, compliance-driven deletion | Stale Teams recordings/transcripts; Preservation Hold library cleanup |
| Typical policy cadence | Rare | Continual (recordings/transcripts) or post-offboarding (Preservation Hold library) |
| Two-person rule | Second Priority Cleanup admin approves AFTER policy is on | Second Priority Cleanup admin included BEFORE policy is turned on |
| Approvers | Priority Cleanup admin + Retention manager + eDiscovery admin (all three, always) | eDiscovery admin only |
| Simulation mandatory? | No (recommended) | Yes |
| Overrides Preservation Lock? | Yes, unconditionally | Only if configured delete-only |

---
## 🎓 Learning Pointers

- **Read the Exchange and SharePoint/OneDrive Learn pages side by side before advising a client on
  either.** They share a name, a philosophy, and one tenant-wide toggle — and differ in almost every
  configuration detail that actually matters operationally. Treating them as interchangeable is the
  single most likely source of a bad recommendation here.
- **Preservation Lock — normally the strongest retention safeguard this repo documents anywhere —
  does not block Exchange priority cleanup at all.** For an organization that adopted Preservation
  Lock specifically to guarantee no one (including their own admins) can weaken retention, this is a
  material fact to raise proactively, not wait to be asked about.
- **"In development" on the public roadmap understates how far along this feature actually is** — a
  live, detailed, recently-updated Learn conceptual page exists, which is not typical for a roadmap
  item still labeled "In development." Don't let the roadmap status alone drive a client's timeline
  expectations; point them to the Learn page's own preview note instead.
- **Approver role combinations are the single highest-friction part of adoption.** Each of the three
  approver types needs a specific bundle of roles, not just their headline role — build this out as a
  pre-flight checklist for every new priority cleanup rollout rather than discovering gaps at
  policy-creation time.
- **This feature's history is a caution against quoting Microsoft timelines confidently.** The
  original 2025 iteration (MC971035) was delayed at least five times before effectively disappearing
  from Message Center, only to resurface under a new roadmap ID over a year later. Always link to the
  live roadmap/Learn source rather than restating a date from memory or an older doc.
- Microsoft Learn: [Use priority cleanup to expedite the permanent deletion of sensitive information from mailboxes](https://learn.microsoft.com/en-us/purview/priority-cleanup-exchange) · [Override holds to clean up files for Copilot and reclaim storage (SharePoint/OneDrive sibling page)](https://learn.microsoft.com/en-us/purview/priority-cleanup-onedrive-sharepoint) · Roadmap ID [473493](https://www.microsoft.com/microsoft-365/roadmap?filters=&searchterms=473493).
