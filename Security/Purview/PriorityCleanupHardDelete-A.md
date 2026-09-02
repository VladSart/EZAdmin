# Purview Priority Cleanup — Hard Delete for OneDrive & SharePoint (Roadmap 558343 / MC1261587) — Reference Runbook (Mode A: Deep Dive)
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

Covers Microsoft Purview Data Lifecycle Management's **priority cleanup** capability — a new
**"Delete data permanently"** policy action for OneDrive for Business and SharePoint Online content
that can hard-delete targeted content types **even when a retention policy or hold is in place**,
subject to a mandatory eDiscovery admin review-and-approval gate for held content. Tracked as Message
Center **MC1261587** and Microsoft 365 Roadmap ID **558343**.

**As of this writing, no Microsoft Learn conceptual page exists for this feature specifically** — this
runbook is built from the Message Center notification itself (the only primary Microsoft source
available), cross-checked across its five tracked revisions via the merill.net Message Center archive.
**Every date below has already changed multiple times and should be re-verified against the live
Message Center entry before being treated as final.**

**Covers:**
- The priority cleanup policy model: scope, "Delete data permanently" action, hold-approval gate
- What is confirmed removed (SharePoint search, Copilot experiences, eDiscovery) and what is not yet
  documented (exact audit schema, any PowerShell/Graph surface, precise UI location)
- How this interacts with — and deliberately overrides, after approval — the standard retention/hold
  model this repo documents elsewhere

**Does not cover:**
- Standard SharePoint/OneDrive Recycle Bin and second-stage Recycle Bin deletion/recovery lifecycle,
  which this feature explicitly bypasses rather than modifies — see `M365/SharePoint-OneDrive/` for
  that separate, unaffected mechanism
- General Purview retention policy configuration for SharePoint/OneDrive locations outside this
  specific hard-delete action — see `RetentionLabels-A.md`
- Backup/DR strategy generally — referenced here only insofar as this feature increases the
  consequence of not having one

**Build context (subject to Microsoft revision — reconfirm before treating any date below as final):**
- Original announcement: 2026-03-25 (v1) — GA (Worldwide) originally targeted late May-mid-June 2026
- v2 (2026-06-10): timeline revised
- v3 (2026-08-11): timeline revised again, end date changed
- v4/v5 (2026-08-19, most recent as of this writing): **Public Preview mid-August to mid-September
  2026; General Availability (Worldwide) late September to mid-November 2026**
- Five tracked revisions in under five months is itself a signal to treat any specific date as
  provisional, not a signal the feature itself is unstable in scope

---
## How It Works

<details><summary>Full architecture</summary>

### The problem this addresses

Microsoft's stated motivation is **data exposure risk from rapidly growing Copilot-related content**
(the Message Center explicitly cites Teams meeting transcripts as an example). Retention policies and
holds are, by design, preservation-biased — the existing Purview principle that a hold or longer
retention policy always wins over a shorter or delete-only one (documented in this repo's
`CopilotRetentionRecommendations-A.md`) means that once content is held for legal/compliance reasons,
there has historically been no supported way to selectively remove a narrow subset of it without
releasing the hold entirely — an all-or-nothing choice with real legal risk either way. Priority
cleanup introduces a narrow, deliberately gated exception to that principle: specific content types can
be hard-deleted **even under a hold**, but only after a human eDiscovery admin explicitly reviews and
approves that specific deletion.

### The policy model

An admin creates a **priority cleanup policy** in the Purview portal (Data Lifecycle Management >
Priority cleanup), scoping it to specific OneDrive/SharePoint **content types** and configuring the
**"Delete data permanently"** action. This is a new, distinct policy type from the existing retention/
deletion policies this repo documents elsewhere — it is not an additional action bolted onto a
standard retention policy.

When the policy runs against in-scope content:

- **Content not subject to any hold** is hard-deleted directly.
- **Content subject to a retention policy or hold** (Litigation Hold, delay hold, eDiscovery hold) is
  **not** deleted automatically — it is routed to a required **eDiscovery admin review and approval**
  step. Only after explicit approval does deletion proceed for that specific content.

Microsoft states that content removed through this workflow becomes **fully unavailable** across three
surfaces simultaneously: SharePoint search, Copilot experiences (the content will no longer be
retrievable or groundable in a Copilot answer), and eDiscovery/Content Search (after approval, for
previously-held content). This three-surface removal is the feature's core value proposition — a
retention-expiry-based deletion already achieves eventual removal from these surfaces over time, but
priority cleanup achieves immediate, deliberate removal on an admin's own schedule rather than waiting
out a retention period.

### What is explicitly NOT changed

- The standard SharePoint/OneDrive **Recycle Bin → second-stage Recycle Bin → ~93-day purge** lifecycle
  for ordinary user-initiated deletions is untouched — priority cleanup is a separate, additional
  deletion path, not a modification of the default one.
- The feature is **not enabled by default** in any tenant — it requires explicit admin policy creation,
  meaning there is zero behavior change or ambient risk for a tenant that never configures it.
- Normal retention-policy-driven, un-approved, non-priority-cleanup deletion behavior is unaffected —
  this feature adds a new override path, it does not change how standard retention expiry works.

### What remains undocumented as of this writing

Microsoft's Message Center notification, while detailed on business impact, does not disclose: the
exact PowerShell/Graph cmdlet surface (if any) for creating or auditing priority cleanup policies, the
precise unified audit log operation name(s) generated by a hard-delete event, whether there is any
supported bulk-export of a policy's run history, or whether "content types" scoping maps to file
extensions, sensitivity labels, item metadata, or some combination. Treat all of the above as open
questions to verify directly against the live Purview portal once in-tenant, not as settled fact.

</details>

---
## Dependency Stack

```
[Microsoft Purview Data Lifecycle Management]
        |
[Priority cleanup — NEW policy type, distinct from standard retention policies]
  (Roadmap 558343 / MC1261587 — Preview ~mid-Aug-mid-Sep 2026, GA ~late-Sep-mid-Nov 2026 per
   the 2026-08-19 revision; RE-VERIFY before quoting)
        |
[Admin explicitly creates policy]  <- feature is OFF by default, zero ambient risk pre-configuration
        |
[Policy scope: specific OneDrive/SharePoint content types]
        |
[Policy action: "Delete data permanently"]
        |
[Runtime hold check per targeted item]
  ├─ No hold present        → hard-deleted directly
  └─ Hold present (Litigation Hold / delay hold / eDiscovery hold / conflicting retention policy)
        └─ Routed to REQUIRED eDiscovery admin review and approval
              ├─ Approved   → hard-deleted
              └─ Not approved → remains held, untouched
        |
[Result — for any content that IS hard-deleted]
  └─ Fully removed, simultaneously, from:
        ├─ SharePoint search index
        ├─ Copilot grounding/retrieval
        └─ eDiscovery / Content Search
        |
[Explicitly UNCHANGED, parallel systems]
  ├─ Standard user-deletion Recycle Bin / second-stage Recycle Bin lifecycle (separate, unaffected)
  └─ Standard retention-policy-driven expiry deletion for content NOT targeted by a priority
        cleanup policy (unaffected)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Content missing with no trace in either Recycle Bin stage | Priority cleanup hard delete, if a matching policy exists | Check Purview portal for an active priority cleanup policy scoped to that content type |
| Content under Litigation Hold went missing without an approval record the legal team recalls | Approval process gap, or content was never actually under the hold the team assumed | Confirm hold scope and approval log before assuming a compliance failure |
| Content still findable in SharePoint search/Copilot/eDiscovery after a hard-delete policy ran | Policy scoping mismatch, run hasn't completed, or genuine platform issue | Confirm exact content-type scope matched the item; check policy run status; escalate if scope and status both confirm it should be gone |
| Admin can't find a way to configure this in the portal | Preview not yet rolled out to this tenant/cloud, or licensing gate | Confirm rollout wave against the live MC1261587 entry; confirm Purview Data Lifecycle Management licensing |
| A hard-delete policy appears to have deleted MORE than intended | Content-type scoping broader than assumed | Review policy scope definition carefully; content-type-to-item mapping specifics are not yet fully documented by Microsoft — treat scoping as an area requiring careful pilot testing |
| Team assumes this is the same as raising/lowering a normal retention period | Conceptual confusion between the two mechanisms | Priority cleanup is a distinct override path with an approval gate, not a retention-duration change — clarify explicitly |

---
## Validation Steps

1. **Confirm feature availability in this tenant/cloud.**
   Check the Purview portal (Data Lifecycle Management > Priority cleanup) directly — do not assume
   availability from the Message Center rollout percentage alone, since rollout is staged.
   Good: the Priority cleanup area is visible and policy creation is available. Bad: area absent —
   confirm licensing and rollout wave before troubleshooting further.

2. **Inventory any existing priority cleanup policies and their exact scope.**
   Portal-only as of this writing. Document each policy's targeted content types and confirm
   "Delete data permanently" is the configured action (versus any other available action, if
   Microsoft has added alternatives by the time this is checked).

3. **Confirm eDiscovery admin role coverage before any policy touches held content.**
   ```powershell
   Connect-IPPSSession -UserPrincipalName <adminUPN>
   Get-RoleGroupMember -Identity "eDiscovery Manager" -ErrorAction SilentlyContinue
   Get-RoleGroupMember -Identity "eDiscovery Administrator" -ErrorAction SilentlyContinue
   ```
   Good: current, appropriate personnel hold these roles and know an approval workflow exists. Bad:
   role membership stale/empty — approvals for held content will stall or be missed entirely.

4. **Confirm no priority cleanup policy is scoped too broadly before enabling "Delete data
   permanently" in production.**
   Pilot against a narrow, well-understood content type first; verify actual deleted-item identity
   matches intent before expanding scope.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Feature availability**
Confirm tenant cloud, rollout wave against the live MC1261587 entry, and Data Lifecycle Management
licensing before assuming a configuration problem.

**Phase 2 — Policy scoping**
Review the exact content types selected in the policy. Since Microsoft has not published granular
content-type-to-item mapping documentation as of this writing, treat any unexpected scope result
(too broad or too narrow) as requiring a support case with Microsoft alongside internal investigation.

**Phase 3 — Hold/approval gate**
For any content confirmed to have been under a hold, verify the eDiscovery approval record exists and
matches the deletion. Absence of an approval record for held content that was nonetheless deleted is a
genuine escalation-worthy finding, not routine.

**Phase 4 — Post-deletion verification**
Confirm removal across all three stated surfaces (SharePoint search, Copilot, eDiscovery) — partial
removal (e.g., still appearing in one surface) is inconsistent with Microsoft's stated design and
warrants escalation with specific reproduction evidence.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Pre-GA readiness assessment</summary>

```
1. Confirm this repo's own timeline caveat is current: check the live Message Center entry MC1261587
   (or Microsoft 365 Roadmap 558343) for the latest Preview/GA dates before any client communication.
2. Identify realistic candidate content types for this feature within the org (Microsoft's own example:
   Copilot-generated Teams meeting transcripts) — don't scope broadly on day one.
3. Confirm eDiscovery Manager/Administrator role coverage and an internal approval SLA/process BEFORE
   any policy that could touch held content goes live.
4. Confirm backup/DR coverage for the targeted content types separately — this feature's irreversibility
   makes an existing backup gap materially more consequential than it was before.
5. Secure explicit legal/compliance sign-off specifically for the "Delete data permanently" action,
   distinct from ordinary retention-policy sign-off, given the hold-override behavior.
```

**Rollback:** N/A — assessment only.

</details>

<details><summary>Playbook 2 — Piloting a first priority cleanup policy safely</summary>

```
1. Scope the pilot policy to a single, well-understood, low-risk content type in a single site
   collection or OneDrive, not tenant-wide.
2. Configure "Delete data permanently" and let the policy run against the narrow pilot scope only.
3. Verify actual deleted-item identity matches intent via post-run confirmation (SharePoint search,
   Copilot retrieval test, eDiscovery search) BEFORE expanding scope.
4. If any held content was encountered, confirm the eDiscovery approval workflow actually triggered
   and was routed to the correct approvers — this is the highest-risk failure mode to catch during
   a pilot rather than in production.
5. Document the pilot's exact scope and outcome as a template for scaling to additional content types.
```

**Rollback:** Disable the pilot policy to stop future runs. Content already hard-deleted during the
pilot is not recoverable — this is why the pilot scope must be genuinely low-risk.

</details>

---
## Evidence Pack

```powershell
# Purview Priority Cleanup — Evidence Pack
Connect-IPPSSession -UserPrincipalName <adminUPN>

Write-Host "=== eDiscovery Approval Role Coverage ===" -ForegroundColor Cyan
Get-RoleGroupMember -Identity "eDiscovery Manager" -ErrorAction SilentlyContinue | Select-Object Name, RecipientType
Get-RoleGroupMember -Identity "eDiscovery Administrator" -ErrorAction SilentlyContinue | Select-Object Name, RecipientType

Write-Host "=== Retention Policies Covering SharePoint/OneDrive (potential hold-gate candidates) ===" -ForegroundColor Cyan
Get-RetentionCompliancePolicy | Where-Object { $_.SharePointLocation -or $_.OneDriveLocation } |
    Select-Object Name, Enabled, SharePointLocation, OneDriveLocation | Format-Table -AutoSize

Write-Host "=== Unified Audit Log — delete-related events (last 30 days, provisional operation match) ===" -ForegroundColor Cyan
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) -RecordType SharePointFileOperation `
    -ResultSize 500 2>$null | Where-Object { $_.Operations -match "Delete" } |
    Select-Object CreationDate, UserIds, Operations | Format-Table -AutoSize

Write-Host "NOTE: No confirmed dedicated cmdlet exists for priority cleanup policies as of this" -ForegroundColor Yellow
Write-Host "writing. Confirm policy existence and exact scope directly in the Purview portal:" -ForegroundColor Yellow
Write-Host "Data Lifecycle Management > Priority cleanup." -ForegroundColor Yellow
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-RoleGroupMember -Identity "eDiscovery Manager"` | Confirm who can approve hold-protected hard deletes |
| `Get-RetentionCompliancePolicy` | Identify existing holds/retention that priority cleanup would need to gate against |
| `Search-UnifiedAuditLog -RecordType SharePointFileOperation` | Best-effort audit trail search (exact operation name for this feature not yet confirmed) |
| `Get-PnPRecycleBinItem` | Rule out normal (recoverable) deletion before assuming hard delete |
| Purview portal > Data Lifecycle Management > Priority cleanup | Authoritative source for policy existence, scope, and configured action — no confirmed cmdlet equivalent |

---
## 🎓 Learning Pointers

- **This is Purview's first mechanism that lets deletion win over a hold — deliberately and with
  approval.** Contrast directly with the "preservation always wins" principle covered in
  `CopilotRetentionRecommendations-A.md`; understanding that these are two different, coexisting
  design philosophies (one default, one opt-in-and-gated) is the fastest way to reason about tickets
  involving both features.
- **Track this feature's Message Center entry directly rather than trusting any single blog post's
  dates** — MC1261587 has already been revised five times in under five months; the merill.net archive
  (linked below) preserves the full version history, which is more reliable than a single point-in-time
  secondary source.
- **Zero risk exists until an admin explicitly builds a policy.** This is not a default-behavior flip
  like several other topics in this repo (e.g. `Windows/Troubleshooting/Windows11-26H2-A.md`'s
  eKB-driven defaults) — don't apply the same "check for silent config drift" instinct here.
- **This makes an existing backup/DR gap materially worse, not better.** Any conversation about
  enabling this feature should include a genuine backup coverage check for the targeted content —
  Purview's Recycle Bin lifecycle was never a backup replacement, and this feature removes even that
  fallback for in-scope content.
- **Content-type-to-item scoping precision is not yet fully documented by Microsoft.** Pilot narrowly
  and verify actual deleted-item identity before trusting the scope definition at face value.
- Primary source (versioned, most current — always check for further revisions):
  [MC1261587 Archive](https://mc.merill.net/message/MC1261587). Roadmap ID 558343.
