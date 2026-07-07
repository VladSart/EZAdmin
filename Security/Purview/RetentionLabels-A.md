# Retention Labels & Policies — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Label Type Comparison](#label-type-comparison)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

- **Applies to:** Microsoft Purview Data Lifecycle Management (retention labels, retention label policies, and container-level retention policies) across Exchange Online, SharePoint Online, OneDrive, Teams, and Viva Engage.
- **Does not cover:** Sensitivity labels (encryption/classification — see `Sensitivity-Labels-A/B.md`), DLP (`DLP-Policy-A/B.md`), Insider Risk Management, eDiscovery holds (`eDiscovery-A/B.md`) — although eDiscovery case holds and retention labels interact (both can preserve the same item; the longer preservation always wins).
- **Licensing required:** Microsoft 365 E3 gives basic retention policies and labels; **E5 / E5 Compliance** is required for auto-apply (trainable classifiers, SITs), adaptive scopes, and disposition review with multi-stage reviewer workflows.
- **Admin roles needed:** Records Management role group (Records Manager, Records Reader), Compliance Administrator, or Global Administrator. Regulatory record management specifically requires the **Records Management** or **Global Administrator** role — Compliance Administrator alone cannot declare regulatory records.

---
## How It Works

<details><summary>Full architecture — labels vs. policies, the retention clock, and conflict resolution</summary>

### Two independent systems, one goal

Microsoft Purview has **two distinct mechanisms** that both control how long content survives, and engineers frequently conflate them:

1. **Retention labels** (technically `ComplianceTag` objects) — applied to an **individual item** (an email, a document, a Teams message). Explicit, granular, travels with the item if it's moved (e.g., a labeled document copied to another SharePoint site keeps its label and retention settings).
2. **Retention policies** (`RetentionCompliancePolicy` objects, non-label type) — applied to an entire **container** (a mailbox, a site, a Team, or all of them). Implicit, coarse, does not travel with an individual item — it's a blanket rule over the location.

A single item can be governed by a label AND one or more container policies simultaneously. When their settings disagree, Purview resolves the conflict using three fixed principles, evaluated in order:

1. **Retention wins over deletion.** If any applicable setting — from any label or policy — says "retain," the item survives, even if a different rule says "delete now."
2. **Longest retention period wins.** Among all retain settings that apply, the longest duration governs.
3. **Explicit (label) beats implicit (policy) for the delete decision.** Once every retain period from every source has elapsed, a label's own configured delete action takes precedence over a container policy's delete action, because the label represents a decision made about that specific item rather than a blanket rule over its container.

There is no "policy priority number" or "first policy wins" concept for retention (this is a common false mental model imported from DLP or Conditional Access, where priority ordering does matter). Retention conflict resolution is purely principle-based, not order-based.

### The retention clock

Every label has a `RetentionType` (called "clock start" in the portal UI) that determines when the countdown to expiry begins:
- `CreationAgeInDays` — clock starts when the item was created. Simple, predictable, but does not account for ongoing edits.
- `ModificationAgeInDays` — clock starts (and **resets**) every time the item is modified. This is the default for most document-retention scenarios and the single most common source of "why hasn't this expired yet" tickets — a frequently-edited document's clock keeps restarting.
- `TaggedAgeInDays` (labeled/event-based) — clock starts when the label was applied to the item, not when the item itself was created.
- Event-based (`Retention Event Type`) — clock starts when an admin or automated process triggers a named event (e.g., "Employee departure," "Contract end date"). Used for scenarios where retention is tied to a business event rather than a calendar date.

### Auto-apply vs. manual apply

Labels can be applied three ways:
- **Manually** by the end user (Outlook, OWA, SharePoint, Teams) — requires the label to be *published* to that user/location first (see Dependency Stack).
- **Auto-apply based on conditions** — a policy scans content for a Sensitive Information Type, a trainable classifier match, or a keyword query, and applies the label automatically. Auto-apply for **existing** content is a one-time backfill scan; auto-apply for **new/changed** content runs continuously.
- **Default label on a container** — a document library, folder, or retention label policy can specify a default label that's applied automatically to everything uploaded there, with no content inspection needed.

### Disposition review

When a label's action is configured for disposition, expiry does not delete the item — it moves the item into a **disposition review** queue inside Records Management. Assigned reviewers (single-stage or a chained multi-stage sequence) must explicitly approve deletion, relabel it, or extend retention. There is no proactive "upcoming disposition" list exposed anywhere in Purview or via cmdlet — items only surface in the Disposition tab once their retention clock has actually completed. This is a frequent expectation mismatch with compliance/legal teams who assume they'll get advance warning.

### Records vs. regulatory records

A label can optionally be marked as a **record label** (`IsRecordLabel = $true`). Once applied to an item, an end user cannot remove the label or reduce its retention — only a user with the Records Management role can un-declare it. A **regulatory record** (`Regulatory = $true`) goes one step further: it can **never** be un-declared or have its retention shortened by anyone, including Global Administrators, once applied — it is a genuinely one-way, tamper-evident state designed for legally mandated retention (e.g., financial services recordkeeping rules). This distinction must be confirmed with the client before publishing, since it cannot be walked back later for regulatory records.

</details>

---
## Dependency Stack

```
[Microsoft Purview Compliance Portal]
    │
    ├── [Retention Label / Compliance Tag]  ← the "what": retain/delete/review, duration, clock type
    │       created via New-ComplianceTag — not yet visible to anyone
    │
    ├── [Retention Label Policy]  ← the "where": publishes the label to locations
    │       DistributionStatus must reach Success per scoped location
    │       (Exchange | SharePoint | OneDrive | Teams (chat+channel) | Viva Engage | M365 Groups)
    │
    ├── [Adaptive Scopes]  (optional, E5)
    │       Dynamic membership queries against user/site/M365 Group attributes
    │       Re-evaluated on a schedule, NOT in real time
    │
    ├── [Auto-apply Engine]  (optional, E5)
    │       ├── Sensitive Information Types (built-in/custom)
    │       ├── Trainable Classifiers (ML-based)
    │       └── Keyword Query (KQL) — SharePoint/OneDrive only
    │
    ├── [Container-level Retention Policy]  (separate, non-label)
    │       Applies blanket retain/delete over a whole mailbox/site/Team
    │       Interacts with labels per the 3-rule conflict model — see How It Works
    │
    ├── [Item-level Application]
    │       Manual (user picks label) or automatic (auto-apply/default label)
    │       Retention clock starts per RetentionType (creation/modification/tagged/event)
    │
    ├── [Retention Expiry]
    │       ├── Retain only → no action
    │       ├── Retain + Delete → deleted (unless a longer-running rule elsewhere still applies)
    │       ├── Delete only → deleted, no preservation guarantee
    │       └── Trigger Disposition Review → Records Management queue
    │             └── Reviewer(s) → approve delete / relabel / extend
    │
    └── [Legal/eDiscovery Hold]  (independent override layer)
            A hold from an eDiscovery case (see eDiscovery-A/B.md) preserves content
            regardless of any label/policy delete decision — holds are evaluated
            separately from, and win over, standard retention delete actions.
```

---
## Label Type Comparison

| Property | Standard Label | Record Label (`IsRecordLabel`) | Regulatory Record (`Regulatory`) |
|----------|---------------|--------------------------------|-----------------------------------|
| End user can remove label | Yes | No | No |
| End user can reduce retention | Yes | No | No |
| Records Manager can remove/un-declare | N/A | Yes | **No — never, by design** |
| Typical use case | General document lifecycle | Internal compliance records (HR files, contracts) | Legally mandated recordkeeping (SEC/FINRA-style rules) |
| Reversible mistake if misapplied | Yes | Yes (Records Manager can fix) | **No — confirm before publishing** |

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Label doesn't appear in Outlook/SharePoint for anyone | Label created but never published (no label policy) | `Get-RetentionCompliancePolicy` — zero matching policy for the label |
| Label doesn't appear for one user/site only | Publishing scope excludes that location | `ExchangeLocationException` / `SharePointLocationException` on the policy |
| New label still not visible after a few hours | Normal — initial sync ~24h, full rollout up to 7 days | Re-check `DistributionStatus`; don't treat as broken before day 7 |
| Item retained when expected to delete | A longer-running policy/label elsewhere also applies (retention wins, longest wins) | Enumerate every policy/label scoped to that location |
| Item deleted earlier than expected | Label was never actually applied — only a shorter container policy governed it | Audit log `LabelApplied` search for that item |
| Disposition review never appears | Retention period hasn't actually completed yet, or clock type miscalculated | Verify `RetentionType` — `ModificationAgeInDays` resets on every edit |
| Disposition review appears but no reviewer acts | Reviewer left the org / was never actually assigned | `ReviewerEmail` on the label — cross-check against active directory |
| Regulatory record can't be modified/removed | Working as designed — irreversible by anyone | Confirm with client this was the intended configuration at creation time |
| Adaptive scope missing recently-added users/sites | Scope hasn't re-evaluated yet (scheduled, not real-time) | `Get-AdaptiveScope` → `LastQueryTime` |
| Auto-apply not tagging obvious matches | Trainable classifier confidence too low, or content type unsupported | Test via Content Explorer sample matches |
| Teams/Viva Engage retry not working with `Set-RetentionCompliancePolicy` | Wrong cmdlet — Teams/Viva Engage use the App variant | Use `Set-AppRetentionCompliancePolicy -RetryDistribution` instead |

---
## Validation Steps

**1. Confirm the label's core configuration**
```powershell
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>
Get-ComplianceTag -Identity "<LABEL_NAME>" |
    Select-Object Name, RetentionAction, RetentionDuration, RetentionType, ReviewerEmail, IsRecordLabel, Regulatory |
    Format-List
```
Expect a non-null `RetentionDuration` unless the label is "retain forever," and a `RetentionType` that matches the intended clock-start behaviour discussed with the client.

**2. Confirm the label has a publishing policy and it succeeded**
```powershell
Get-RetentionCompliancePolicy | Where-Object { $_.Name -like "*<LABEL_OR_POLICY_NAME>*" } |
    Select-Object Name, Enabled, Mode, DistributionStatus |
    Format-Table -AutoSize
```
`DistributionStatus` must be `Success` for the location in question. `Pending` on a policy less than 7 days old is expected, not a fault.

**3. Confirm no location-level distribution exceptions**
```powershell
$policy = Get-RetentionCompliancePolicy -Identity "<LABEL_POLICY_NAME>"
$policy.ExchangeLocationException
$policy.SharePointLocationException
$policy.OneDriveLocationException
```
Any populated value here names a specific failed location — usually a deleted/renamed site or a mailbox with a conflicting hold.

**4. Confirm adaptive scope freshness (if used)**
```powershell
Get-AdaptiveScope -Identity "<SCOPE_NAME>" | Select-Object Name, ScopeType, LastQueryTime
```
Compare `LastQueryTime` against when the target user/site was actually added to the underlying attribute — a stale scope is the most common "label isn't reaching this new user" root cause.

**5. Enumerate everything that could apply to a given location (conflict surfacing)**
```powershell
Get-RetentionCompliancePolicy | Where-Object {
    $_.ExchangeLocation -contains "<MAILBOX>" -or $_.SharePointLocation -contains "<SITE_URL>"
} | Select-Object Name, Enabled, Mode
```
This is the only reliable way to see every retention source that could be contributing to the 3-rule conflict outcome on a given mailbox or site — there is no single "effective retention" cmdlet.

**6. Confirm audit log ingestion is on (required for any label-application forensics)**
```powershell
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
```

---
## Troubleshooting Steps by Phase

### Phase 1 — Label Not Visible / Not Publishing

1. Confirm the label exists (`Get-ComplianceTag`) — a label with no publishing policy is invisible everywhere.
2. Confirm a label policy actually references it and lists the intended locations.
3. Check `DistributionStatus` — allow up to 7 days for new publishes before escalating.
4. Check `*LocationException` properties for specific failed locations; remove dead references and retry.
5. For Teams/Viva Engage specifically, confirm you're using `Set-AppRetentionCompliancePolicy`, not the standard cmdlet — they use separate backend distribution paths.

### Phase 2 — Unexpected Retention Outcome (Retained When Delete Expected, or Vice Versa)

1. Enumerate every policy/label scoped to the location (Validation Step 5) — do not assume only one setting applies.
2. Apply the 3-rule model manually: does any source say retain? Which retain period is longest? If all retain periods have passed, does the label's own delete action match what happened?
3. Confirm via audit log whether the label was actually applied to the specific item, not just published to the location — publishing ≠ per-item application.
4. If an eDiscovery hold exists on the same mailbox/site, it silently overrides delete regardless of label/policy settings — check `eDiscovery-B.md` Diagnosis Step 2 for hold status.

### Phase 3 — Auto-Apply Not Tagging Content

1. Confirm the auto-apply policy's condition type (SIT / trainable classifier / KQL) is correct for the workload — KQL auto-apply only works on SharePoint/OneDrive, not Exchange.
2. Sample actual matches (or near-misses) via Content Explorer to validate classifier/SIT confidence is tuned correctly.
3. Remember auto-apply for **existing** content runs as a one-time backfill — newly added qualifying content after that backfill needs the continuous "new/changed content" auto-apply policy running as well, which is a separate policy object from the backfill.
4. Confirm licensing — auto-apply features require E5/E5 Compliance; a tenant on E3 will show the option in the portal but it will silently not function.

### Phase 4 — Disposition Review Issues

1. Confirm the retention clock has genuinely completed using `RetentionType` semantics (Validation Step 1) — a `ModificationAgeInDays` label on a living document may never appear to expire.
2. Confirm reviewers are current, active accounts — a departed reviewer with no replacement means items sit unreviewed indefinitely with no alerting.
3. For multi-stage disposition, confirm each stage's reviewer chain in the portal (Records management → Disposition) — this configuration is not fully exposed via `Get-ComplianceTag`.

### Phase 5 — Record / Regulatory Record Confusion

1. Before publishing any label as a record or regulatory record, confirm this is the actual intent — regulatory records cannot be undone by anyone, including Global Admin, once applied to content.
2. If a standard record needs correcting, only the Records Management role (not Compliance Administrator) can un-declare it — verify the requester has (or can be granted) that role rather than assuming Global Admin is sufficient.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Create and publish a new retention label end-to-end</summary>

```powershell
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

# 1. Create the label (compliance tag)
New-ComplianceTag -Name "Contracts-7Year" `
    -RetentionAction Keep `
    -RetentionDuration 2555 `
    -RetentionType ModificationAgeInDays `
    -Comment "7-year retention for signed contracts, clock resets on edit"

# 2. Publish it to SharePoint and OneDrive
New-RetentionCompliancePolicy -Name "Contracts-7Year-Policy" `
    -SharePointLocation All -OneDriveLocation All `
    -PublishComplianceTag "Contracts-7Year"

# 3. Verify distribution after a few hours
Get-RetentionCompliancePolicy -Identity "Contracts-7Year-Policy" | Select-Object Name, DistributionStatus

Write-Host "Label published. Allow up to 24h for initial sync, up to 7 days for full rollout." -ForegroundColor Green
```

</details>

<details><summary>Playbook 2 — Convert a label to a record label (with irreversibility warning)</summary>

```powershell
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

# STOP: confirm with the client this is intended before running.
# Once IsRecordLabel is set and the label is applied to content, end users cannot remove it.
# Setting Regulatory = $true additionally makes it permanently undeclarable by anyone.

Set-ComplianceTag -Identity "Contracts-7Year" -IsRecordLabel $true

# Verify
Get-ComplianceTag -Identity "Contracts-7Year" | Select-Object Name, IsRecordLabel, Regulatory
```
**Rollback:** while `IsRecordLabel = $true` and **not yet Regulatory**, a Records Manager can still reverse it with `Set-ComplianceTag -Identity "Contracts-7Year" -IsRecordLabel $false` — but only for items not yet tagged, or via a documented un-declare process for already-tagged items. Once `Regulatory = $true` is set and applied, there is **no rollback path** for tagged content.

</details>

<details><summary>Playbook 3 — Retry a stuck distribution across all workload types</summary>

```powershell
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

$policyName = "<LABEL_POLICY_NAME>"

# Exchange / SharePoint / OneDrive
Set-RetentionCompliancePolicy -Identity $policyName -RetryDistribution

# Teams (private channels) / Viva Engage — separate cmdlet, separate backend
Set-AppRetentionCompliancePolicy -Identity $policyName -RetryDistribution

Start-Sleep -Seconds 5
Get-RetentionCompliancePolicy -Identity $policyName | Select-Object Name, DistributionStatus
```

</details>

<details><summary>Playbook 4 — Build a bulk multi-location policy update (avoid rate-limit issues)</summary>

```powershell
Connect-IPPSSession -UserPrincipalName <admin@tenant.com>

# Anti-pattern: calling Set-RetentionCompliancePolicy once per site queues excessive
# distribution jobs and can trigger throttling on large tenants.
# Correct pattern: batch all additions into a single call.

$sitesToAdd = @("https://tenant.sharepoint.com/sites/HR",
                "https://tenant.sharepoint.com/sites/Legal",
                "https://tenant.sharepoint.com/sites/Finance")

Set-RetentionCompliancePolicy -Identity "<LABEL_POLICY_NAME>" -AddSharePointLocation $sitesToAdd

Write-Host "Bulk location update submitted as a single distribution job." -ForegroundColor Green
```

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects retention label/policy configuration and distribution health for escalation.
#>
param(
    [string]$LabelName,
    [string]$OutputPath = "$env:TEMP\RetentionEvidence_$(Get-Date -Format yyyyMMdd_HHmm).txt"
)

Connect-IPPSSession -UserPrincipalName $env:USERNAME

"=== RETENTION LABEL EVIDENCE PACK ===" | Out-File $OutputPath
"Generated: $(Get-Date)" | Out-File $OutputPath -Append

"`n--- Label Configuration ---" | Out-File $OutputPath -Append
Get-ComplianceTag -Identity $LabelName |
    Select-Object Name, RetentionAction, RetentionDuration, RetentionType, ReviewerEmail, IsRecordLabel, Regulatory |
    Format-List | Out-File $OutputPath -Append

"`n--- Publishing Policies Referencing This Label ---" | Out-File $OutputPath -Append
Get-RetentionCompliancePolicy | Where-Object { $_.Name -like "*$LabelName*" } |
    Select-Object Name, Enabled, Mode, DistributionStatus |
    Format-Table -AutoSize | Out-File $OutputPath -Append

"`n--- Distribution Exceptions ---" | Out-File $OutputPath -Append
Get-RetentionCompliancePolicy | Where-Object { $_.Name -like "*$LabelName*" } | ForEach-Object {
    "$($_.Name):" | Out-File $OutputPath -Append
    "  Exchange: $($_.ExchangeLocationException)" | Out-File $OutputPath -Append
    "  SharePoint: $($_.SharePointLocationException)" | Out-File $OutputPath -Append
    "  OneDrive: $($_.OneDriveLocationException)" | Out-File $OutputPath -Append
}

"`n--- Recent Label Application Activity (30 days) ---" | Out-File $OutputPath -Append
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) `
    -Operations "LabelApplied" -FreeText $LabelName -ResultSize 100 |
    Select-Object CreationDate, UserIds, Operations |
    Format-Table -AutoSize | Out-File $OutputPath -Append

Write-Host "Evidence pack written to $OutputPath" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Get-ComplianceTag -Identity <name>` | View a label's retention action, duration, clock type, record flags |
| `New-ComplianceTag` | Create a new retention label |
| `Set-ComplianceTag` | Modify an existing label (e.g., set `IsRecordLabel`) |
| `Get-RetentionCompliancePolicy` | List label/policy publishing objects and their `DistributionStatus` |
| `New-RetentionCompliancePolicy -PublishComplianceTag` | Publish a label to one or more locations |
| `Set-RetentionCompliancePolicy -RetryDistribution` | Retry failed distribution (Exchange/SharePoint/OneDrive) |
| `Set-AppRetentionCompliancePolicy -RetryDistribution` | Retry failed distribution (Teams private channels/Viva Engage) |
| `Get-AdaptiveScope` | Check adaptive scope membership and last refresh time |
| `Get-RetentionEventType` | List event-based retention triggers |
| `Search-UnifiedAuditLog -Operations "LabelApplied"` | Confirm whether/when a label was actually applied to an item |
| `Get-AdminAuditLogConfig` | Confirm Unified Audit Log ingestion is enabled (prerequisite for all forensics above) |

---
## 🎓 Learning Pointers

- **Retention labels and retention policies are two systems, not one** — labels are explicit/per-item, policies are implicit/per-container. Nearly every "unexpected retention behaviour" ticket is actually a correct application of the 3-rule conflict model (retain wins, longest wins, explicit label wins on delete), not a platform bug. [MS Docs — Learn about retention](https://learn.microsoft.com/en-us/purview/retention)
- **The clock-start type (`RetentionType`) is the single highest-leverage thing to check first** on any "why hasn't this expired" ticket — `ModificationAgeInDays` resets every time someone touches the file, which surprises almost every first-time compliance administrator.
- **Regulatory records are a genuinely irreversible one-way door** — treat any request to mark a label `Regulatory = $true` as a decision that needs explicit sign-off, not a routine configuration change, since it cannot be undone for content it's already been applied to.
- **New label publishing takes up to 7 days to fully roll out** — set this expectation with clients up front so a "the label isn't showing yet" ticket doesn't get treated as an incident on day 2.
- **Use the correct retry cmdlet for the workload** — `Set-RetentionCompliancePolicy -RetryDistribution` does not retry Teams/Viva Engage distribution; that requires `Set-AppRetentionCompliancePolicy -RetryDistribution` against a separate backend. [MS Docs — Resolve errors in retention and retention label policies](https://learn.microsoft.com/en-us/troubleshoot/microsoft-365/purview/retention/resolve-errors-in-retention-and-retention-label-policies)
- **Disposition review has no proactive notice** — it only surfaces once the retention clock has fully completed, with no advance list. If a client wants a heads-up before disposition, that has to be a separately built report, not an assumed platform feature.
