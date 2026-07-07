# Microsoft 365 Backup — Reference Runbook (Mode A: Deep Dive)
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

This covers **Microsoft 365 Backup** (the first-party, pay-as-you-go backup service for SharePoint, OneDrive, and Exchange Online — sometimes internally called "M365 Backup Storage" or referenced by its Graph namespace `solutions/backupRestore`). It is a **different product** from:

- **Microsoft Purview retention policies/labels** (compliance-driven preservation, not point-in-time recovery — see `Security/Purview/Retention-Policies-A.md`)
- **Third-party backup solutions** built on the same Backup Storage platform (Veeam, AvePoint, Commvault, etc.) — those wrap the same underlying Graph APIs but bill and manage through their own apps
- **OneDrive/SharePoint's native 93-day recycle bin and file version history** — those are always-on and free; Microsoft 365 Backup is the paid, longer-retention, bulk-recovery layer on top

Assumes: tenant has (or is evaluating) an Azure subscription for pay-as-you-go billing, and the reader has Global Administrator, SharePoint Administrator, Exchange Administrator, or the dedicated **Microsoft 365 Backup Administrator** role.

---
## How It Works

<details><summary>Full architecture</summary>

Microsoft 365 Backup does not move your data to a separate backup vault. Backups are created **inside the same data trust boundary** as the live service — OneDrive/SharePoint backups live in Azure Blob + Azure SQL alongside the production tenant data; Exchange backups live inside the Exchange Online infrastructure itself. This is the source of its headline feature: restore speeds of up to 1–3 TB/hour, because there's no cross-region data transfer required to "rehydrate" anything.

```
┌─────────────────────────────────────────────────────────────┐
│  Microsoft 365 data trust boundary (tenant's own geography)  │
│                                                               │
│   OneDrive/SharePoint          Exchange Online                │
│   ┌───────────────────┐        ┌───────────────────┐          │
│   │ Live content       │        │ Live mailbox items │          │
│   │ (SPO infra)        │        │ (EXO infra)        │          │
│   └─────────┬──────────┘        └─────────┬─────────┘          │
│             │ append-only copy            │ append-only copy   │
│             ▼                              ▼                   │
│   ┌───────────────────┐        ┌───────────────────┐          │
│   │ Azure Blob         │        │ EXO backup store    │          │
│   │ (content)          │        │ (item-level,        │          │
│   │ + Azure SQL         │        │  append-only)       │          │
│   │ (metadata, via      │        └───────────────────┘          │
│   │  point-in-time      │                                       │
│   │  restore snapshots) │                                       │
│   └───────────────────┘                                        │
│                                                                │
│   Only tenantID/siteID metadata leaves the boundary — sent    │
│   to Azure for billing purposes only.                         │
└─────────────────────────────────────────────────────────────┘
```

**Why "append-only" matters:** SharePoint/OneDrive content is stored as content blobs that can only be **added to**, never overwritten, until permanently deleted. Exchange items are backed up the same way and are not reachable by any client process (Outlook, OWA, MFCMAPI) once written. This is what protects backups from a compromised admin account or ransomware trying to encrypt/delete the backup copies themselves — the live production data can be destroyed, but the append-only backup blobs referencing prior states cannot be altered in place.

**Immutability vs. append-only — the distinction that matters for compliance conversations:** true immutable storage cannot be deleted either, for a defined retention period. Microsoft 365 Backup deliberately does **not** implement full immutability, because full immutability would conflict with GDPR right-to-erasure obligations. Instead it approximates immutability with three guardrails:
1. A fixed **90-day recovery grace period** after offboarding (soft-delete-style) — deleting Backup doesn't destroy your restore points for 90 days.
2. Purview retention/deletion policies **never** touch the Backup retention period — the two systems are fully isolated from each other.
3. **Multi-admin email notifications** fire automatically whenever a potentially harmful action is taken (disabling Backup, removing protection units, pausing billing, offboarding, transferring the backup controller, revoking the app, editing the notification list itself).

**The core object model:**

| Object | What it is |
|--------|-----------|
| **Protection unit** | A single SharePoint site, OneDrive account, or Exchange mailbox that is individually backed up |
| **Protection policy** | The configuration object that says *what* to protect (a set of protection units, added directly or via an inclusion rule) and *how* (implicitly — retention/RPO is fixed per workload, not configurable per policy) |
| **Inclusion rule** | A rule-based membership definition for a policy (e.g., "all sites of template X", "all licensed mailboxes") so new matching items join automatically instead of requiring manual addition |
| **Restore point** | A specific prior point in time from which a protection unit's content and metadata can be recovered |
| **Express restore point** | A tool-recommended restore point (SharePoint/OneDrive only) that yields materially faster restores than an arbitrary point in time — always prefer these when the exact minute doesn't matter |
| **Restore session** | The actual restore operation once triggered — tracks status, errors, and completion time |
| **Browse session** | Used for granular restore — lets an admin browse/search a restore point's file tree without doing a full rollback |

</details>

---
## Dependency Stack

```
[Tier 0 — Azure]
  Azure subscription (pay-as-you-go) + resource group + region
  Owner/Contributor role on the subscription
         │
[Tier 1 — Tenant enablement]
  Microsoft 365 Backup Storage service: ServiceStatus = enabled
  Admin role: Global Admin / SharePoint Admin / Exchange Admin / M365 Backup Admin
         │
[Tier 2 — Protection policy, per workload]
  SharePoint protection policy  ──┐
  OneDrive protection policy    ──┼─ each independently created, activated, billed
  Exchange protection policy    ──┘
         │
[Tier 3 — Protection units]
  Individual sites / OneDrive accounts / mailboxes
  added directly OR matched by an inclusion rule
         │
[Tier 4 — Restore points]
  Generated automatically once policy is active
  10-min granularity (0–14 days) → weekly (15–365 days)
  Exchange: 10-min granularity for the full 365 days
         │
[Tier 5 — Restore session]
  Correct role (SharePoint Backup Admin for granular restore)
  Target not under a strict SEC 17a-4(f) hold (in-place restores)
  Destination: same URL/mailbox (in-place) or new URL/folder
```

**Cross-cutting dependency:** Microsoft 365 Backup is billed **pay-as-you-go through Azure**, not through M365 licensing. A tenant can have every user licensed for E5 and Backup will still be completely inert until an Azure subscription is linked and enabled — this trips up admins who assume "we have E5, backup should already be running."

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Microsoft 365 Backup pane missing/greyed out in admin center | Billing not linked, or signed-in account lacks SharePoint/Exchange/Global Admin | Admin center → Settings → Microsoft 365 Backup; confirm role via Entra |
| New site/mailbox/OneDrive can't be restored at all | Never added to a protection policy — policies don't auto-expand without an inclusion rule | `Get-MgSolutionBackupRestoreProtectionPolicy`, then check protection units/inclusion rules on that policy |
| "No restore points available before <date>" | Item was added to the policy after that date — retention doesn't back-fill | Compare protection unit's "date added" to requested restore date |
| Restore to same URL/mailbox rejected | Strict SEC 17a-4(f) hold in place | Purview `Get-RetentionCompliancePolicy` against the target location |
| Restore session `failed`, error references quota/count | New-URL restore counter hit its ~1,000 ceiling for that site | Look for accumulated `...R0`, `...R1`, ... restored copies; clean up old ones |
| Deleted mailbox/OneDrive shows as blank "–" in restore picker | User's Entra ID object was deleted; backups still exist but need reconnection | Follow the deleted-user recovery flow below |
| Granular file/folder restore option missing from the UI | Admin lacks the **SharePoint Backup Admin** role | Confirm role assignment in Entra ID role-based access control |
| Policy stuck in `activating` far past the expected window | Very large protection-unit count (1,000+) still processing, or a genuine service-side stall | Compare elapsed time to the performance table below; escalate if grossly exceeded |
| Term Store metadata missing after a SharePoint restore | Expected behavior for new-URL restores — term store never copies to a new URL | Not a bug — document as known limitation |
| Calendar item restored but attendees don't see the update | Restoring the organizer's copy doesn't retroactively sync attendee copies | Expected behavior — only future organizer updates propagate |

---
## Validation Steps

**1. Confirm service enablement**
```powershell
Connect-MgGraph -Scopes "BackupRestore-Configuration.Read.All"
Get-MgSolutionBackupRestore | Select-Object Id, ServiceStatus
```
Good: `ServiceStatus: enabled`. Bad: `notActive`/`disabled` — nothing downstream will function until this is fixed.

**2. Confirm each workload has an active policy**
```powershell
Get-MgSolutionBackupRestoreProtectionPolicy | Select-Object DisplayName, Status, CreatedDateTime
Get-MgSolutionBackupRestoreSharePointProtectionPolicy | Select-Object DisplayName, Status
Get-MgSolutionBackupRestoreOneDriveForBusinessProtectionPolicy | Select-Object DisplayName, Status
Get-MgSolutionBackupRestoreExchangeProtectionPolicy | Select-Object DisplayName, Status
```
Good: `Status: active` for each policy you expect to exist. Bad: missing entirely (workload isn't protected at all) or stuck `activating`.

**3. Confirm protection unit coverage matches intent**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/siteProtectionUnits" |
    Select-Object -ExpandProperty value | Measure-Object | Select-Object Count
```
Compare this count against your actual SharePoint site inventory (`Get-MgSite -All`). A material gap means sites are being created outside whatever inclusion rule is configured. Same pattern applies to `driveProtectionUnits` (OneDrive) and `mailboxProtectionUnits` (Exchange).

**4. Confirm restore point depth matches the retention promise**
```powershell
Get-MgSolutionBackupRestorePoint | Sort-Object CreatedDateTime | Select-Object -First 1 -Property CreatedDateTime
```
Good: earliest restore point roughly matches when the protection unit was added to its policy. If it's much later than expected, the unit may have been re-added after a prior removal — check the policy's protection-unit history.

**5. Test a real (non-production-impacting) restore**
```powershell
# Use a test/throwaway OneDrive or a decommissioned test site — never test against production
# without confirming destination = new URL to avoid overwriting live data.
```
Good: restore session reaches `Status: succeeded` within the expected performance window (see table below). Bad: `failed`, or `succeeded` but content doesn't match the expected point in time (check for term-store/metadata caveats first before assuming a defect).

---
## Troubleshooting Steps (by phase)

**Phase 1 — Enablement & billing**
1. Confirm Azure subscription is linked with Owner/Contributor rights.
2. Confirm `ServiceStatus: enabled` via `Get-MgSolutionBackupRestore`.
3. Confirm the admin's role matches the workload they're trying to configure (SharePoint Admin ≠ can manage Exchange Backup).

**Phase 2 — Policy & coverage**
4. Enumerate all policies per workload; confirm `Status: active`.
5. Diff protection-unit counts against actual tenant inventory (sites/OneDrives/mailboxes) to catch silent coverage gaps.
6. Review inclusion rules — confirm the rule criteria actually matches how new sites/mailboxes get provisioned in this tenant (e.g., a rule scoped to "Team site" template won't catch communication sites).

**Phase 3 — Restore point depth**
7. Confirm the requested restore date falls within the retention window for that workload (SharePoint/OneDrive: 10-min granularity for 14 days, weekly out to 365 days; Exchange: 10-min granularity for the full 365 days).
8. If the protection unit was recently re-added after removal, restore points restart from zero — this is not a bug.

**Phase 4 — Restore execution**
9. Prefer express restore points for SharePoint/OneDrive full restores — materially faster RTO.
10. Check for holds (SEC 17a-4(f) specifically blocks in-place restore) before attempting in-place.
11. For Exchange, confirm the target items are eligible (modified/deleted-to-Recoverable-Items/purged only — items sitting in Deleted Items are not Backup's responsibility).
12. For a deleted Entra ID user, follow the correct reconnection path (below) rather than attempting a normal restore, which will show the user as a blank "–" entry.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Close a protection coverage gap</summary>

1. Identify all sites/OneDrives/mailboxes not currently in any protection policy (see the audit script below).
2. Decide: add individually (small, deliberate set) or create/adjust an inclusion rule (ongoing, scales with tenant growth).
3. For an inclusion rule, scope it as broadly as safely possible (e.g., "all licensed mailboxes" rather than a naming convention that will drift) to avoid repeating this gap next quarter.
4. Re-run the coverage audit after ~1 hour to confirm the new units show `protectionState: protected` and have begun generating restore points.

**Rollback:** Removing a protection unit from a policy stops future backups but does not delete existing restore points — those remain available for the standard retention window.

</details>

<details><summary>Playbook 2 — Recover a deleted user's OneDrive or mailbox</summary>

**If deleted within 30 days:**
1. Restore the user via the standard Microsoft 365 admin center **Restore a user** flow first.
2. Once the user reappears in Entra ID, Backup's restore picker will show their name again (no longer blank) and normal restore works.

**If the mailbox is permanently deleted (Exchange, past 30 days):**
1. Backup retains the **inactive mailbox** for the duration of the backup policy regardless of Entra deletion.
2. Follow Purview's [Recover an inactive mailbox](https://learn.microsoft.com/en-us/purview/recover-an-inactive-mailbox) guidance to convert it to a new active mailbox.
3. Add the new user to the backup policy to regain access to the recovered mailbox's backups.
4. Remove the old (deleted) user entry from the policy once confirmed working.

**If OneDrive's owner is gone permanently:**
1. Restore to original or a new URL — the OneDrive lands in an **orphaned** state (no owner attached).
2. Use [Fix site user ID mismatch in SharePoint or OneDrive](https://learn.microsoft.com/en-us/sharepoint/troubleshoot/sharing-and-permissions/fix-site-user-id-mismatch) to reattach it to a user.

**Rollback:** N/A — this is a recovery procedure, not a destructive one.

</details>

<details><summary>Playbook 3 — Restore around a preservation hold</summary>

1. Identify the hold type: strict SEC 17a-4(f) vs. standard litigation/retention hold.
2. Strict 17a-4(f): in-place restore is hard-blocked. Choose new-URL (SharePoint/OneDrive) or new-folder (Exchange) restore instead, or coordinate with compliance/legal to lift the hold if truly appropriate.
3. Standard holds: in-place restore is allowed; the preservation hold library itself rolls back along with the site.
4. Document the hold type and decision in the change record — restoring around a hold has compliance implications that should be visible to legal, not just IT.

**Rollback:** N/A — no destructive action is taken by choosing a restore destination.

</details>

<details><summary>Playbook 4 — Recover from a failed large-scale (ransomware-style) incident</summary>

1. Do **not** panic-restore individually — for 1,000+ protection units, use bulk restore via the admin center or bulk-addition-job cmdlets rather than one-by-one restores, which is dramatically slower.
2. Choose in-place restore (same URL/mailbox) wherever possible — it is faster than new-URL/new-folder restore and is the documented pattern for bulk attack recovery.
3. Prefer standard/express restore points that have had time to "warm up" — the performance table below shows large restores may take a few hours to begin but then execute quickly once warmed.
4. Track restore session status across the batch; do not assume completion — poll `Get-MgSolutionBackupRestoreSession` until every session reports `succeeded`.

**Rollback:** If a bulk restore itself needs to be undone, restore again to the point in time immediately preceding the bulk restore — this works because restore points remain available regardless of subsequent restore activity.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Microsoft 365 Backup service, policy, and restore-session state for escalation.
#>
Connect-MgGraph -Scopes "BackupRestore-Configuration.Read.All"

$evidence = [ordered]@{
    ServiceStatus     = (Get-MgSolutionBackupRestore).ServiceStatus
    Policies          = Get-MgSolutionBackupRestoreProtectionPolicy | Select-Object Id, DisplayName, Status, CreatedDateTime
    SiteUnitCount     = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/siteProtectionUnits").value.Count
    DriveUnitCount    = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/driveProtectionUnits").value.Count
    MailboxUnitCount  = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/mailboxProtectionUnits").value.Count
    RecentSessions    = Get-MgSolutionBackupRestoreSession | Sort-Object CreatedDateTime -Descending | Select-Object -First 10 Id, Status, CreatedDateTime, CompletedDateTime
}

$evidence.GetEnumerator() | ForEach-Object { "`n=== $($_.Key) ===`n"; $_.Value | Format-Table -AutoSize | Out-String }
$evidence | ConvertTo-Json -Depth 6 | Out-File ".\M365Backup-Evidence-$(Get-Date -Format yyyyMMdd-HHmm).json"
```

---
## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Get-MgSolutionBackupRestore` | Tenant-level Backup Storage service status |
| `Enable-MgSolutionBackupRestore` | Turn on the Backup Storage service |
| `Get-MgSolutionBackupRestoreProtectionPolicy` | List all protection policies across workloads |
| `Get-MgSolutionBackupRestoreSharePointProtectionPolicy` | SharePoint-specific policies |
| `Get-MgSolutionBackupRestoreOneDriveForBusinessProtectionPolicy` | OneDrive-specific policies |
| `Get-MgSolutionBackupRestoreExchangeProtectionPolicy` | Exchange-specific policies |
| `Get-MgSolutionBackupRestoreProtectionUnit` | All protection units tenant-wide |
| `Get-MgSolutionBackupRestorePoint` | List restore points |
| `Get-MgSolutionBackupRestoreSession` | List/check restore sessions |
| `Get-MgSolutionBackupRestoreServiceApp` | Backup controller/app registration details |
| `Invoke-MgGraphRequest -Uri .../siteProtectionUnits` | Raw REST call for site-level protection unit detail not yet fully surfaced in cmdlet form |
| `Invoke-MgGraphRequest -Uri .../driveProtectionUnits` | Raw REST call for OneDrive protection unit detail |
| `Invoke-MgGraphRequest -Uri .../mailboxProtectionUnits` | Raw REST call for mailbox protection unit detail |
| `Get-RetentionCompliancePolicy` (Purview module) | Check for holds that may block in-place restore |

**Performance reference (from Microsoft's published benchmarks):**

| Protection units | OneDrive/SharePoint restore | Exchange restore |
|---|---|---|
| 1 | ~30 minutes | ~2 hours |
| 50 | ~3 hours | ~2.5 hours |
| 250 | ~4 hours | ~3 hours |
| 1,000+ | ~250 units/hour, up to 2 TB/hour | ~250+ units/hour, up to 2 TB/hour |

---
## 🎓 Learning Pointers

- **This is not a licensing feature — it's pay-as-you-go Azure billing.** E3/E5 licensing has no bearing on whether Backup is active; an Azure subscription must be linked and billing enabled first. This is the most common "why isn't backup running, we pay for E5" support call.
- **Protection policies are workload-specific and don't cross-pollinate.** A SharePoint policy says nothing about OneDrive or Exchange coverage — each workload needs its own policy and its own inclusion-rule strategy.
- **Append-only storage, not full immutability — know the difference for compliance conversations.** Backups can still be deleted (with a 90-day grace period), which matters for GDPR erasure requests; they just can't be silently altered.
- **Term Store and calendar-attendee sync are documented, permanent limitations, not bugs** — don't burn escalation time chasing them as defects.
- **Official docs:** [Overview of Microsoft 365 Backup](https://learn.microsoft.com/en-us/microsoft-365/backup/backup-overview?view=o365-worldwide) | [Set up Microsoft 365 Backup](https://learn.microsoft.com/en-us/microsoft-365/backup/backup-setup?view=o365-worldwide) | [Restore data in Microsoft 365 Backup](https://learn.microsoft.com/en-us/microsoft-365/backup/backup-restore-data?view=o365-worldwide) | [Microsoft 365 Backup FAQ](https://learn.microsoft.com/en-us/microsoft-365/backup/backup-faq?view=o365-worldwide) | [Microsoft.Graph.BackupRestore module reference](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.backuprestore/?view=graph-powershell-1.0)
- **Community:** Microsoft 365 Backup is new enough (broad GA in 2024–2025) that r/Office365 and the Microsoft 365 Tech Community are still the best sources for real-world edge cases beyond the official docs.
