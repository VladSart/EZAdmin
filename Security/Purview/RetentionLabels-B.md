# Retention Labels & Policies — Hotfix Runbook (Mode B: Ops)
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

```powershell
# 1. Connect to Security & Compliance PowerShell
Connect-IPPSSession -UserPrincipalName <ADMIN_UPN>

# 2. Check retention policy distribution status
Get-RetentionCompliancePolicy | Select-Object Name, Enabled, Mode, DistributionStatus, RetryDistribution | Format-Table -AutoSize

# 3. Check retention label (compliance tag) list and their retention action
Get-ComplianceTag | Select-Object Name, RetentionAction, RetentionDuration, IsRecordLabel, Regulatory | Format-Table -AutoSize

# 4. Check which locations a label policy has published to
Get-RetentionCompliancePolicy -Identity "<LABEL_POLICY_NAME>" | Select-Object Name, ExchangeLocation, SharePointLocation, OneDriveLocation, ModernGroupLocation | Format-List

# 5. Check for label-application errors (last 7 days)
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) -Operations "Set-ComplianceTag","LabelUpdated,LabelApplied" -ResultSize 100
```

| Output | Interpretation | Next Step |
|--------|---------------|-----------|
| `DistributionStatus = Pending` and policy is < 24 hrs old | Normal — initial sync takes up to 24 hrs, full deployment up to 7 days | Wait; re-check tomorrow |
| `DistributionStatus = Error` | Distribution to one or more locations failed | [Fix 1 — Retry Failed Distribution](#fix-1--retry-failed-distribution) |
| Label exists but doesn't appear in Outlook/SharePoint UI after 7+ days | Label not published, or published to wrong location/scope | [Fix 2 — Fix Label Publishing Scope](#fix-2--fix-label-publishing-scope) |
| Two labels/policies conflict on the same item (wrong retention period wins) | Conflict resolution misunderstood — **not a bug** | [Fix 3 — Resolve Label/Policy Conflicts](#fix-3--resolve-labelpolicy-conflicts) |
| User can't manually apply label in Outlook/SharePoint | Label not published to that user/site, or label is a record label with restricted assignment | [Fix 4 — Label Not Available to User](#fix-4--label-not-available-to-user) |
| Item auto-deleted before expected date | Retention policy on the container deleted it — label wasn't applied in time, or wasn't a record | [Fix 5 — Unexpected Early Deletion](#fix-5--unexpected-early-deletion) |
| Disposition review never triggers at end of retention period | Disposition stage not configured on the label, or reviewers never assigned | [Fix 6 — Disposition Review Not Triggering](#fix-6--disposition-review-not-triggering) |

---
## Dependency Cascade

<details><summary>What must be true for a retention label to actually retain/delete content</summary>

```
Microsoft Purview compliance portal (purview.microsoft.com)
  └── Retention Label (Compliance Tag) — the "what" (retain/delete, duration, disposition)
        │  Created via New-ComplianceTag — not yet visible to any user
        │
        ▼
  Label Policy (Retention Label Policy) — the "where"
        │  Publishes label to: Exchange mailboxes | SharePoint sites | OneDrive | Teams | M365 Groups
        │  Requires: DistributionStatus = Success at every scoped location
        │
        ▼
  Auto-apply (optional) OR manual apply (user picks label in Outlook/SPO/OWA)
        │  Auto-apply trigger types: keyword/SIT match, sensitive info type, trainable classifier
        │  Manual apply requires label to be published to that specific user/site
        │
        ▼
  Item is now tagged — retention clock starts
        │  Start event: "when created" | "when last modified" | "when labeled" | event-based (Retention Event Type)
        │
        ▼
  Retention period expires
        │
        ├── Action = Retain only            → item stays, no further action
        ├── Action = Retain and delete       → item deleted after period (unless legal hold overrides)
        ├── Action = Delete only             → item deleted after period, no preservation guarantee
        └── Action = Trigger disposition review
              └── Reviewer(s) notified in Records Management → Disposition
                    └── Reviewer approves delete / relabels / extends
```

**Separate, container-level system that can conflict with labels:**
```
Retention Policy (non-label, applies to a whole mailbox/site/Team, not per-item)
  └── Applies "Retain" and/or "Delete" broadly across a workload location
        └── Conflict resolution vs. labels: see Fix 3
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the label exists and is configured as expected**
```powershell
Get-ComplianceTag -Identity "<LABEL_NAME>" | Select-Object Name, RetentionAction, RetentionDuration, RetentionType, ReviewerEmail, IsRecordLabel, Regulatory | Format-List
```
- `RetentionType = ModificationAgeInDays` vs `CreationAgeInDays` vs `TaggedAgeInDays` — the clock start point is a very common source of "why hasn't this deleted yet" tickets.
- `IsRecordLabel = True` → this is a **records management** label; it cannot be removed or changed by end users once applied (by design).

**Step 2 — Confirm the label is published (not just created)**
```powershell
Get-RetentionCompliancePolicy | Where-Object { $_.RetentionRuleTypes -contains "AdvancedRule" -or $_.Name -like "*<LABEL_NAME>*" } |
    Select-Object Name, DistributionStatus, ExchangeLocation, SharePointLocation, OneDriveLocation
```
- A label with **zero** matching policies means it was created but never published — invisible to every user. This is the #1 "label doesn't show up" root cause.

**Step 3 — Confirm distribution actually succeeded per-location**
```powershell
$policy = Get-RetentionCompliancePolicy -Identity "<LABEL_POLICY_NAME>"
$policy | Select-Object -ExpandProperty SharePointLocationException
$policy | Select-Object -ExpandProperty ExchangeLocationException
```
- Any populated exception property is a location that failed. Common causes: a SharePoint site was deleted after being scoped, or a mailbox is on a different retention hold that's blocking application.

**Step 4 — Confirm adaptive scope membership (if used) is current**
```powershell
Get-AdaptiveScope -Identity "<SCOPE_NAME>" | Select-Object Name, ScopeType, LastQueryTime
Get-RetentionCompliancePolicy -Identity "<LABEL_POLICY_NAME>" | Select-Object -ExpandProperty AdaptiveScopeLocation
```
- Adaptive scopes re-evaluate on a schedule (not instantly). A user/site added to the underlying attribute query won't get the label until the next scope refresh.

**Step 5 — Confirm conflict resolution outcome on a specific item**
```powershell
# Content Explorer / audit log is the only way to see which label "won" on an item.
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) `
    -Operations "LabelApplied" -FreeText "<ITEM_NAME_OR_ID>" -ResultSize 50
```

---
## Common Fix Paths

<details><summary>Fix 1 — Retry Failed Distribution</summary>

**Symptom:** `DistributionStatus = Error`, or "taking longer than expected to deploy the policy" shown in the portal.

```powershell
# For Exchange mailboxes and SharePoint/OneDrive sites:
Set-RetentionCompliancePolicy -Identity "<LABEL_POLICY_NAME>" -RetryDistribution

# For Teams private channels and Viva Engage (uses a different backend cmdlet):
Set-AppRetentionCompliancePolicy -Identity "<LABEL_POLICY_NAME>" -RetryDistribution

# Re-check after 1-2 hours
Get-RetentionCompliancePolicy -Identity "<LABEL_POLICY_NAME>" | Select-Object Name, DistributionStatus
```
**If it stays in Error after a retry:** the most common cause is a deleted/inaccessible location still listed in scope. Remove it explicitly:
```powershell
Set-RetentionCompliancePolicy -Identity "<LABEL_POLICY_NAME>" -RemoveSharePointLocation "<DEAD_SITE_URL>"
```

</details>

<details><summary>Fix 2 — Fix Label Publishing Scope</summary>

**Symptom:** Label created, never appears in Outlook/SharePoint/OWA for any user after 7+ days.

```powershell
# Check whether the label has ANY publishing policy at all
Get-RetentionCompliancePolicy | Where-Object { $_.RetentionRuleTypes -contains "AdvancedRule" } |
    Select-Object Name, DistributionStatus

# If none exists, publish it (creates the label policy that makes it user-visible)
New-RetentionCompliancePolicy -Name "<LABEL_POLICY_NAME>" `
    -ExchangeLocation All -SharePointLocation All -OneDriveLocation All -PublishComplianceTag "<LABEL_NAME>"

# If the policy exists but is scoped too narrowly, widen it:
Set-RetentionCompliancePolicy -Identity "<LABEL_POLICY_NAME>" -AddSharePointLocation "<SITE_URL>"
```
**Note:** New label publishing can take **up to 7 days** to fully propagate to every mailbox/site (initial sync is ~24 hrs, but full tenant-wide rollout is slower). This is normal Microsoft behaviour, not a fault.

</details>

<details><summary>Fix 3 — Resolve Label/Policy Conflicts</summary>

**Symptom:** An item was retained when you expected it to delete, or vice versa, and multiple retention settings apply to it.

**This is (almost always) working as designed, not a bug.** Microsoft Purview resolves conflicts using three fixed principles, in this order:

1. **Retention wins over deletion.** If ANY applicable policy or label says "retain," the item is preserved — even if another policy says "delete."
2. **Longest retention period wins.** If multiple retain settings apply with different durations, the longest one governs.
3. **Explicit (label) beats implicit (policy) for the delete decision.** A retention label applied directly to an item is more specific than a container-level retention policy, so a label's delete action overrides a broader policy's delete action once the label's period is also satisfied.

```powershell
# Enumerate everything that could apply to a given mailbox/site to find the actual winner
Get-RetentionCompliancePolicy | Where-Object {
    $_.ExchangeLocation -contains "<MAILBOX>" -or $_.SharePointLocation -contains "<SITE_URL>"
} | Select-Object Name, RetentionDuration -ExpandProperty RetentionComplianceRule
```
**Fix path:** don't fight the precedence rules — instead, adjust the *shorter* or *conflicting* setting so it matches intent. If a policy is deleting things too early and a label should be overriding it, confirm the label was actually applied (Step 5 above) rather than assuming precedence is broken.

</details>

<details><summary>Fix 4 — Label Not Available to User</summary>

**Symptom:** Specific user/site can't see or apply the label, but others can.

```powershell
# Check if the label policy targets this user directly or via a group
Get-RetentionCompliancePolicy -Identity "<LABEL_POLICY_NAME>" | Select-Object -ExpandProperty ExchangeLocation
Get-RetentionCompliancePolicy -Identity "<LABEL_POLICY_NAME>" | Select-Object -ExpandProperty ExchangeLocationException

# Add the missing mailbox/site
Set-RetentionCompliancePolicy -Identity "<LABEL_POLICY_NAME>" -AddExchangeLocation "<USER_UPN>"
```
- If `IsRecordLabel = True` on the label, remember: once applied, end users **cannot** remove it or reduce its retention — this is intentional records-management behaviour, not a permissions bug. Only a Records Manager role can un-declare a regulatory record, and regulatory records (`Regulatory = True`) can never be removed by anyone.

</details>

<details><summary>Fix 5 — Unexpected Early Deletion</summary>

**Symptom:** A file/email was deleted before the label's retention period should have expired.

```powershell
# Confirm the label was actually applied to the item before deletion (check audit log)
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) -Operations "LabelApplied" -FreeText "<ITEM_NAME>"

# Check if a container-level retention POLICY (not label) with a shorter delete window also applied
Get-RetentionCompliancePolicy | Select-Object Name, RetentionDuration, SharePointLocation, ExchangeLocation
```
Most common root cause: the label was never actually applied (auto-apply trainable classifier missed it, or the user never manually tagged it) — so only the shorter container-level policy governed the item. Recovery: check the second-stage Recycle Bin (SharePoint/OneDrive, 93 days) or Recoverable Items (Exchange, up to 30 days by default, longer if on hold) before escalating as unrecoverable.

</details>

<details><summary>Fix 6 — Disposition Review Not Triggering</summary>

**Symptom:** Retention period expired, item should route to disposition review, but nothing happens and no reviewer is notified.

```powershell
# Confirm the label actually has disposition configured
Get-ComplianceTag -Identity "<LABEL_NAME>" | Select-Object Name, RetentionAction, ReviewerEmail
```
- `RetentionAction` must be `Keep` with a disposition trigger, or explicitly configured for review in the portal — this cannot be fully verified from `RetentionAction` alone for multi-stage disposition; cross-check in **Purview portal → Records management → Disposition** where multi-stage reviewer chains are configured.
- Disposition items only appear in the portal's Disposition tab **after** the retention period fully expires — there is no early-warning list. If the expected date has passed and nothing appeared, verify Step 1 (clock start type) wasn't miscalculated (e.g. `CreationAgeInDays` instead of the intended `ModificationAgeInDays` can push the real expiry out by months on a frequently-edited document).
- If reviewers were never assigned or left the organisation, items still complete their retention clock but sit unreviewed indefinitely — audit `ReviewerEmail` for stale/departed accounts as part of any records-management hygiene pass.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION: Retention Label / Policy Issue
=====================================
Admin UPN:                  ___________________________
Label name:                 ___________________________
Label policy name:          ___________________________
Retention action:           Retain / Retain+Delete / Delete only / Disposition review
Is record label:            Yes / No     Regulatory: Yes / No
Distribution status:        Success / Pending / Error
Failed locations (if any):  ___________________________
Affected user/site/mailbox: ___________________________
Expected behaviour:         ___________________________
Actual behaviour:           ___________________________
Item still recoverable?     Yes (Recycle Bin/Recoverable Items) / No
Date issue started:         ___________________________
Compliance portal URL:      https://purview.microsoft.com
Support path:                Microsoft 365 Admin → Support → New service request
                             (select "Data Lifecycle Management" / "Records Management")
```

---
## 🎓 Learning Pointers

- **Retention labels vs. retention policies are two different systems that both apply to the same content.** Labels are per-item and explicit; policies are per-container and implicit. Most "why didn't this delete/retain correctly" tickets are actually a precedence question, not a bug — memorize the three rules in Fix 3. [MS Docs — Retention overview](https://learn.microsoft.com/en-us/purview/retention)
- **"Retention wins, longest wins, explicit label wins on delete"** is the complete conflict-resolution model — nothing else matters. If you find yourself reasoning about "which policy is evaluated first," you're solving the wrong problem.
- **New label publishing is not instant** — budget up to 7 days before treating a "label doesn't show up" ticket as broken. Set expectations with the client accordingly.
- **Records vs. regular retention labels** are a one-way door: a regulatory record can never be un-declared by anyone, and a standard record can only be un-declared by a Records Manager role. Confirm with the client which behaviour they actually want before publishing — this is a common mismatch between compliance intent and IT delivery.
- **Use `-RetryDistribution` before escalating any distribution error** — the two cmdlets (`Set-RetentionCompliancePolicy` for Exchange/SharePoint/OneDrive, `Set-AppRetentionCompliancePolicy` for Teams/Viva Engage) both self-heal most transient distribution failures. [MS Docs — Resolve retention policy/label errors](https://learn.microsoft.com/en-us/troubleshoot/microsoft-365/purview/retention/resolve-errors-in-retention-and-retention-label-policies)
- **Disposition review has no early-warning surface** — it only appears in the portal once the retention clock has fully expired. If a client expects proactive notice before disposition, that has to be built as a separate process (e.g. a scheduled report), not assumed from the platform.
