# Purview Priority Cleanup — Hard Delete for OneDrive & SharePoint (Roadmap 558343 / MC1261587) — Hotfix Runbook (Mode B: Ops)
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

**This is a new, opt-in, irreversible deletion capability — treat every ticket here as high-stakes
until proven otherwise.** Microsoft Purview Data Lifecycle Management is adding a **priority cleanup
policy** with a **Delete data permanently** action that can hard-delete specific OneDrive/SharePoint
content types **even when a retention policy or hold is in place** (Message Center MC1261587, Roadmap
558343). As of the most recent Message Center update (2026-08-19): **Public Preview mid-August to
mid-September 2026; General Availability (Worldwide) late September to mid-November 2026** — this
timeline has already shifted four times since the original March 2026 announcement, so re-verify the
current dates before quoting them to anyone. The feature is **not enabled by default** and requires
explicit admin configuration — nothing changes for any tenant until an admin builds a priority cleanup
policy.

```powershell
Connect-IPPSSession -UserPrincipalName <adminUPN>

# 1. Does any priority cleanup policy exist in this tenant? (portal-first feature; cmdlet surface
#    not yet confirmed as of this writing — try the generic retention cmdlet family first)
Get-RetentionCompliancePolicy | Where-Object { $_.Name -match "Priority|Cleanup|Hard.?[Dd]elete" }

# 2. What retention policies/holds currently protect the SharePoint/OneDrive content in question?
Get-RetentionCompliancePolicy | Where-Object { $_.SharePointLocation -or $_.OneDriveLocation } |
    Select-Object Name, Enabled, SharePointLocation, OneDriveLocation

# 3. Who holds eDiscovery admin rights required to approve a hold-protected hard delete?
Get-RoleGroupMember -Identity "eDiscovery Manager" -ErrorAction SilentlyContinue
Get-RoleGroupMember -Identity "eDiscovery Administrator" -ErrorAction SilentlyContinue
```

| Result | Interpretation |
|---|---|
| Content was hard-deleted and someone wants it back | **Likely not recoverable.** This bypasses the normal SharePoint/OneDrive Recycle Bin and second-stage Recycle Bin entirely by design. Go to Fix 1 immediately to confirm scope before assuming total loss. |
| A user/team asks "why can't I find this file anywhere, not even in the Recycle Bin" | Possible priority-cleanup hard delete rather than a normal deletion — Fix 2 to confirm. |
| Admin wants to configure a priority cleanup policy | Portal-only as of this writing (Purview portal > Data Lifecycle Management > Priority cleanup). Go to Fix 3. |
| Content under a Litigation Hold or eDiscovery hold was targeted by a priority cleanup policy | Requires **explicit eDiscovery admin review and approval** before deletion proceeds — this is a deliberate compliance gate, not a bug if deletion is blocked pending approval. Go to Fix 4. |
| Admin is unsure whether a priority cleanup policy is even active in the tenant | No confirmed dedicated read cmdlet exists yet — verify directly in the portal. Go to Fix 5. |
| Content still appears in SharePoint search / Copilot / eDiscovery after a hard-delete policy ran | Escalate — per Microsoft's stated design this should be fully removed from all three surfaces; capture Escalation Evidence below. |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
[Microsoft Purview portal — Data Lifecycle Management > Priority cleanup]
        |
[Admin explicitly creates a priority cleanup policy]  <- NOT enabled by default, no ambient risk
        |
[Policy targets specific OneDrive/SharePoint content types]
        |
[Policy configured with "Delete data permanently" action]
        |
[Content evaluation]
  ├─ Content NOT under any hold
  │     └─ Hard-deleted directly per policy — removed from SharePoint search, Copilot experiences,
  │           and eDiscovery
  └─ Content UNDER a retention policy or hold (Litigation Hold, delay hold, eDiscovery hold)
        └─ Deletion is GATED — requires explicit eDiscovery admin review and approval before
              proceeding (this is the compliance safeguard distinguishing this from a silent
              hold-bypass)
        |
[Result — content NOT under hold, or hold-content after approval]
  └─ Fully removed from:
        ├─ SharePoint search
        ├─ Copilot experiences (no longer surfaced/grounded in Copilot answers)
        └─ eDiscovery / Content Search
        |
[NOT covered by this feature]
  ├─ Normal user-initiated deletion (still goes through the standard Recycle Bin → second-stage
  │     Recycle Bin → 93-day purge lifecycle, unaffected)
  └─ Content types NOT selected in the priority cleanup policy's scope
```

</details>

---
## Diagnosis & Validation Flow

**1. Determine whether this is a normal deletion or a priority-cleanup hard delete**
```powershell
# Check the standard Recycle Bin first — normal deletions land here regardless of this feature
Get-PnPRecycleBinItem -RowLimit 500 2>$null | Where-Object { $_.Title -match "<filename>" }
```
If the item is genuinely absent from both stages of the Recycle Bin AND a priority cleanup policy
exists targeting its content type, treat it as a probable hard delete rather than a lost/misplaced
normal deletion.

**2. Inventory active priority cleanup policies and their scope**
As of this writing there is no confirmed dedicated cmdlet for priority cleanup policies specifically.
Check the Purview portal directly: **Data Lifecycle Management > Priority cleanup** — list policies,
their targeted content types, and whether "Delete data permanently" is the configured action.

**3. Confirm hold status on the affected content BEFORE assuming irreversible loss**
```powershell
Get-RetentionCompliancePolicy | Where-Object { $_.SharePointLocation -match "<SiteUrl>" -or $_.OneDriveLocation } |
    Select-Object Name, Enabled
```
If a hold existed, the deletion should have been gated behind eDiscovery admin approval — check
approval/audit trail before concluding the content is unrecoverable.

**4. Check the Purview audit log for the deletion event**
```powershell
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) `
    -Operations "PriorityCleanupDelete" -ResultSize 500 2>$null
```
Operation name is provisional pending Microsoft's final audit-schema documentation for this feature —
if the exact operation name above returns nothing, search more broadly for delete-related operations
in the same time window and cross-reference against the priority cleanup policy's configured schedule.

**5. Confirm eDiscovery admin approval requirement was actually satisfied for held content**
Review the Purview portal's priority cleanup policy run history/approval log for the specific item or
batch in question — this is the compliance control that should have prevented an unreviewed hard
delete of hold-protected content.

---
## Common Fix Paths

<details><summary>Fix 1 — Content was hard-deleted; assess recoverability before declaring total loss</summary>

Use when: a user reports content missing with no trace in the standard Recycle Bin.

```
1. Confirm via Diagnosis Steps 1 and 4 that this is genuinely a priority-cleanup hard delete and not
   a normal deletion that simply aged out of the 93-day second-stage Recycle Bin window.
2. Check whether the content existed in any OTHER preserved location Microsoft's design doesn't cover:
   local sync client (OneDrive) cache/version history on an end-user device, an email attachment copy,
   a separate backup/DR solution (Purview's native Recycle Bin lifecycle is NOT a backup replacement,
   and priority-cleanup hard delete is explicitly designed to bypass it).
3. If a third-party backup solution is in place for this tenant, that is the only realistic recovery
   path — check it before telling the user the content is permanently gone.
4. If no backup exists and the deletion is confirmed as priority-cleanup hard delete, this is expected,
   by-design, irreversible behavior — communicate that clearly rather than continuing to search.
```

**Rollback:** None by design. This is the entire point of the "Delete data permanently" action.

</details>

<details><summary>Fix 2 — Confirm whether a "missing file" ticket is actually a hard delete</summary>

Use when: a user can't find a file and doesn't know why.

```
1. Check the standard and second-stage Recycle Bin first (Diagnosis Step 1) — most "missing file"
   tickets are normal deletions still recoverable through the standard 93-day window.
2. If genuinely absent from both Recycle Bin stages, check whether any priority cleanup policy exists
   targeting that content type/location (Diagnosis Step 2).
3. If no priority cleanup policy exists in the tenant at all, this ticket is unrelated to this feature —
   investigate as a standard SharePoint/OneDrive deletion/permissions issue instead.
```

**Rollback:** N/A — diagnostic only.

</details>

<details><summary>Fix 3 — Configure a new priority cleanup policy</summary>

Use when: an admin wants to reduce data exposure risk from specific rapidly-growing content (commonly
cited use case: Copilot-related content such as Teams meeting transcripts).

```
1. Confirm business/legal sign-off BEFORE creating any policy with "Delete data permanently" — this
   is irreversible and overrides standard retention/hold protections after approval.
2. Microsoft Purview portal (https://purview.microsoft.com/) > Data Lifecycle Management > Priority
   cleanup > Create policy.
3. Scope the policy tightly to specific, well-understood content types — do not scope broadly on a
   first rollout.
4. Select "Delete data permanently" as the action.
5. Ensure eDiscovery admin roles and an approval workflow are established BEFORE activating the
   policy, since any hold-protected content the policy encounters will route to that approval step.
6. Pilot against a narrow, low-risk content set first; monitor the policy's run history before
   expanding scope.
```

**Rollback:** Disable/remove the priority cleanup policy going forward to stop future runs — this does
**not** restore content already hard-deleted by prior runs.

</details>

<details><summary>Fix 4 — Hold-protected content is stuck pending eDiscovery approval</summary>

Use when: a priority cleanup policy targeted content under a Litigation/eDiscovery hold and deletion
hasn't proceeded.

```
1. This is expected, by-design gating, not a stuck job — deletion of held content REQUIRES explicit
   eDiscovery admin review and approval before it proceeds.
2. Identify who holds eDiscovery Manager/Administrator rights (Diagnosis query 3) and route the
   approval request to them through the org's normal legal/compliance process.
3. Do NOT attempt to work around the gate by releasing the hold solely to let the cleanup policy
   proceed unless that release itself is a deliberate, separately-approved legal decision.
```

**Rollback:** N/A — the gate itself is the safeguard functioning correctly.

</details>

<details><summary>Fix 5 — Confirm whether priority cleanup is active in the tenant at all</summary>

Use when: an admin isn't sure if this feature has been configured/used previously.

```
1. Check the Purview portal directly: Data Lifecycle Management > Priority cleanup. No confirmed
   dedicated read-only PowerShell cmdlet exists for this feature as of this writing.
2. As a secondary signal, search the unified audit log for delete-related operations in the relevant
   time window (Diagnosis Step 4) and cross-reference against known priority cleanup policy names.
3. If nothing is found in the portal and no relevant audit entries exist, the feature has not been
   configured in this tenant — any missing-content ticket is unrelated to this feature.
```

**Rollback:** N/A — diagnostic only.

</details>

---
## Escalation Evidence

```
PURVIEW PRIORITY CLEANUP / HARD DELETE ESCALATION
====================================================
Date/Time                                  :
Tenant cloud (Worldwide/GCC/GCC High/DoD)  :
Affected site/OneDrive URL                 :
Content type targeted                      :
Priority cleanup policy name (if known)    :
Content was under hold at time of deletion?: Yes/No — Type:
eDiscovery approval obtained (if held)?    : Yes/No — Approver:
Confirmed absent from Recycle Bin (both stages)? : Yes/No
Audit log entry found?                     : Yes/No — Operation/timestamp:
Third-party backup checked?                : Yes/No — Result:
Business/legal sign-off on file for this policy? : Yes/No
Steps Already Tried                        :
```

---
## 🎓 Learning Pointers

- **This is the first native Purview mechanism designed to override retention/holds with approval,
  rather than being blocked by them.** Understand it as intentionally inverting the normal "preservation
  always wins" principle from `CopilotRetentionRecommendations-A.md`'s retention model — here, deletion
  can win, but only through an explicit eDiscovery approval gate.
- **The timeline for this feature has moved four times since its original March 2026 announcement**
  (May-June 2026 → GA moved to Sept-Oct → preview added mid-Aug-mid-Sep → GA now late-Sept-mid-Nov as
  of the 2026-08-19 update). Always re-check the live Message Center entry (MC1261587) before
  committing to a date with a client.
- **Not enabled by default — zero ambient risk until an admin builds a policy.** Frame client
  communications accordingly; this is not a background behavior change like a service-side default flip.
- **Bypasses the standard Recycle Bin entirely, by design.** Don't reflexively check the normal
  93-day second-stage Recycle Bin recovery path and declare "not recoverable through normal means" as
  if that's surprising — it's the stated purpose of the feature.
- **Pair any priority cleanup rollout with a genuine backup/DR conversation.** Purview's native
  deletion lifecycle, with or without this feature, has never been a backup replacement — this feature
  makes that gap more consequential, not less.
- Message Center source (versioned, most current): [MC1261587 Archive](https://mc.merill.net/message/MC1261587). Roadmap ID 558343.
