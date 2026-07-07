# Microsoft 365 Backup — Hotfix Runbook (Mode B: Ops)
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

Run these first to locate the failure layer.

```powershell
# 1. Connect with the Backup Storage Graph module
Install-Module Microsoft.Graph.BackupRestore -Scope CurrentUser -Force  # first run only
Connect-MgGraph -Scopes "BackupRestore-Configuration.Read.All","BackupRestore-Configuration.ReadWrite.All"

# 2. Confirm the Backup Storage service itself is enabled for the tenant
Get-MgSolutionBackupRestore | Select-Object Id, ServiceStatus

# 3. List every protection policy and its activation state
Get-MgSolutionBackupRestoreProtectionPolicy | Select-Object Id, DisplayName, Status

# 4. Confirm the affected protection unit (site/OneDrive/mailbox) is actually IN a policy
#    (swap the -Uri for whichever workload the ticket is about)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/siteProtectionUnits" |
    Select-Object -ExpandProperty value | Select-Object id, displayName, status

# 5. Check for an in-flight or recently completed restore session
Get-MgSolutionBackupRestoreSession | Select-Object Id, Status, CreatedDateTime | Sort-Object CreatedDateTime -Descending | Select-Object -First 5
```

| Result | Action |
|--------|--------|
| `ServiceStatus` is anything other than `enabled` | → Fix 1: Enable the Backup Storage service |
| Protection policy `Status` is `activating` for > 2 hours | → Fix 2: Stalled policy activation |
| Target site/OneDrive/mailbox is missing from the protection unit list entirely | → Fix 3: Item was never added to a policy |
| Restore session `Status` shows `failed` | → Fix 4: Failed restore session |
| Restore blocked with a hold/lock error | → Fix 5: Preservation hold blocking in-place restore |
| Admin can't reach the Microsoft 365 Backup pane at all | → Fix 6: Billing/subscription not linked |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Azure Subscription — pay-as-you-go billing linked]
  └─ Resource group + region selected
  └─ Owner/Contributor role granted on the subscription
         |
[Microsoft 365 Backup Storage service — tenant-enabled]
  └─ Enable-MgSolutionBackupRestore has been run (or done via admin center)
  └─ Admin role: Global Admin / SharePoint Admin / Exchange Admin / M365 Backup Admin
         |
[Protection Policy — per workload: SharePoint / OneDrive / Exchange]
  └─ Policy created and Status = "activating" then "active"
  └─ Protection units (sites/accounts/mailboxes) added — directly or via inclusion rule
  └─ Initial backup complete (~15 min per 1,000 protection units)
         |
[Restore Points — generated automatically once policy is active]
  └─ 10-min granularity for 0–14 days back (Exchange: 0–365 days)
  └─ Weekly snapshots beyond 14 days (SharePoint/OneDrive) out to 365 days
         |
[Restore Session — admin-initiated]
  └─ Correct role (SharePoint Backup Admin for granular file/folder restore)
  └─ Target not under a strict SEC 17a-4(f) hold (blocks in-place restore)
  └─ Destination chosen: same URL/mailbox (in-place) or new URL/folder
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the Backup Storage service is enabled**
```powershell
Get-MgSolutionBackupRestore | Select-Object ServiceStatus
```
Expected: `ServiceStatus: enabled`. If not → Fix 1.

**2. Confirm billing is actually linked (no Graph cmdlet for this — portal only)**
```
Microsoft 365 admin center → Settings → Microsoft 365 Backup → Settings tab → Billing
```
Expected: an active pay-as-you-go policy with subscription/resource group/region populated. If blank → Fix 6.

**3. Check policy activation state**
```powershell
Get-MgSolutionBackupRestoreProtectionPolicy | Select-Object DisplayName, Status
```
Expected: `Status: active`. `activating` is normal for up to ~2 hours after creation (60 min to process + 60 min to create restore points, longer for 1,000+ units). Stuck past that → Fix 2.

**4. Confirm the specific item is protected**
```powershell
# SharePoint
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/siteProtectionUnits" |
    Select-Object -ExpandProperty value | Where-Object { $_.displayName -like "*<SiteName>*" }

# OneDrive
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/driveProtectionUnits" |
    Select-Object -ExpandProperty value | Where-Object { $_.displayName -like "*<UPN>*" }

# Exchange
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/mailboxProtectionUnits" |
    Select-Object -ExpandProperty value | Where-Object { $_.displayName -like "*<UPN>*" }
```
Expected: one matching object with `status: protected`. Not found → Fix 3 (the site/account/mailbox was never added to a policy — this is the single most common "why can't I restore this" ticket, since new sites/mailboxes/OneDrives created after a policy exists do **not** auto-join unless an inclusion rule matches them).

**5. Check restore session outcome**
```powershell
Get-MgSolutionBackupRestoreSession | Sort-Object CreatedDateTime -Descending | Select-Object -First 1 |
    Select-Object Id, Status, CreatedDateTime, CompletedDateTime
```
Expected: `Status: succeeded`. `failed` → Fix 4. If the error text mentions a hold → Fix 5.

**6. Confirm restore fidelity for the target type**
- SharePoint/OneDrive full restore = rolls the **entire site/account** back to the chosen point in time (overwrites everything since). Not a per-file operation unless you used granular file/folder restore.
- Exchange restore only recovers **modified, deleted-to-Recoverable-Items, or purged** items — items still sitting in Deleted Items are recovered by the end user directly, not by Backup.

---
## Common Fix Paths

<details><summary>Fix 1 — Enable the Backup Storage service</summary>

Use when: `Get-MgSolutionBackupRestore` shows anything other than `enabled`, or the Microsoft 365 Backup pane in the admin center says the service isn't turned on.

```powershell
Connect-MgGraph -Scopes "BackupRestore-Configuration.ReadWrite.All"
Enable-MgSolutionBackupRestore
Start-Sleep -Seconds 30
Get-MgSolutionBackupRestore | Select-Object ServiceStatus
```

**Note:** Enabling the service is a prerequisite, not a substitute, for billing setup — do this only after pay-as-you-go billing is linked (Fix 6), otherwise policy creation will fail downstream.

**Rollback:** N/A — enabling the service is non-destructive and does not itself create any policies or protection units.

</details>

<details><summary>Fix 2 — Stalled policy activation</summary>

Use when: a protection policy has shown `Status: activating` for more than ~2 hours (or more than ~4 hours for 1,000+ protection units — see the performance table in the A-doc).

```powershell
# Re-check status and look at policy creation time
Get-MgSolutionBackupRestoreProtectionPolicy |
    Select-Object Id, DisplayName, Status, CreatedDateTime

# Confirm the protection units inside the policy aren't themselves stuck
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/sharePointProtectionPolicies/<PolicyId>/protectionUnits" |
    Select-Object -ExpandProperty value | Select-Object id, status
```

If individual protection units show `protectionState: pending` well past the expected window (30 min for 1 unit up to a few hours for 1,000+), open a Microsoft 365 admin center support ticket — policy activation cannot be forced or retried via PowerShell. Do **not** delete and recreate the policy; this restarts the retention clock for every protection unit inside it.

**Rollback:** N/A — this is a monitoring fix path, not a destructive one.

</details>

<details><summary>Fix 3 — Item was never added to a protection policy</summary>

Use when: the site, OneDrive account, or mailbox the user needs restored doesn't appear in any protection-unit list at all.

```powershell
# Add a SharePoint site to an existing policy (admin center is the primary path;
# PowerShell bulk-addition uses a job object — see Microsoft.Graph.BackupRestore
# siteProtectionUnitsBulkAdditionJob cmdlets for scripted bulk adds)

# Fastest single-item path: Microsoft 365 admin center
# Settings > Microsoft 365 Backup > [SharePoint|OneDrive|Exchange] > Manage backup > Add
```

**Root cause reminder:** protection policies do not automatically expand to cover new sites/mailboxes/OneDrives created after the policy was set up, unless the policy uses an **inclusion rule** (e.g., "all sites matching a template" or "all licensed users"). Check whether an inclusion rule exists and why it didn't match:

```powershell
Get-MgSolutionBackupRestoreSharePointProtectionPolicySiteInclusionRule -SharePointProtectionPolicyId <PolicyId>
```

**Important:** even after adding the item, restore points don't exist retroactively — the earliest point you can restore to is whenever the initial backup completes after being added (roughly 15 minutes per 1,000 units added).

**Rollback:** N/A — additive only.

</details>

<details><summary>Fix 4 — Failed restore session</summary>

Use when: `Get-MgSolutionBackupRestoreSession` shows `Status: failed`.

```powershell
Get-MgSolutionBackupRestoreSession -RestoreSessionId <SessionId> |
    Select-Object Id, Status, Error, CreatedDateTime, CompletedDateTime
```

Common failure reasons and what to do:
- **Hold/lock conflict** → see Fix 5.
- **Destination URL/mailbox already at its restore-count ceiling** (new-URL restores cap at ~1,000 per site before you must delete old `R#` copies) → clean up old restore copies or pick a different destination.
- **Multi-geo move mid-flight** → wait for the geo move to fully complete before retrying; a site/account that moved geos can currently only restore to weekly restore points until the restore point re-alignment enhancement ships.
- **Deleted user, no special handling applied** → see the A-doc's "Deleted/Inactive User Recovery" section before retrying.

Retry after resolving the underlying cause — restore sessions are not automatically retried by the service.

**Rollback:** If a **partial** in-place restore already wrote data before failing, there is no automated undo — restore again to the point in time immediately prior to the failed attempt to recover the pre-restore state (this works because every restore point remains available regardless of later restore attempts).

</details>

<details><summary>Fix 5 — Preservation hold blocking in-place restore</summary>

Use when: a restore to the **same URL/mailbox** fails or is rejected specifically citing a hold.

```powershell
# Check for a Purview retention/litigation hold on the target (requires Purview module)
Get-RetentionCompliancePolicy | Where-Object { $_.SharePointLocation -like "*<SiteUrl>*" -or $_.ExchangeLocation -like "*<UPN>*" }
```

- A **strict SEC 17a-4(f)** hold will hard-block any in-place restore — this is by design, to preserve immutability guarantees. The only options are: restore to a **new URL** (SharePoint/OneDrive) or a **new folder** (Exchange), or have compliance formally remove the hold first.
- Any other type of preservation hold (standard litigation hold, retention policy without the strict lockout) still allows an in-place restore — the hold library itself will also be rolled back to the prior point in time as part of the restore.

**Rollback:** N/A — this is an access-control condition, not a destructive action.

</details>

<details><summary>Fix 6 — Billing/subscription not linked</summary>

Use when: the Microsoft 365 Backup pane is inaccessible, greyed out, or policies can't be created at all.

```
Microsoft 365 admin center → Billing → Your bills & payments → Payment methods & subscriptions
  (or, for tenants still on the legacy path: Setup → Billing and licenses → Activate pay-as-you-go services)
→ Confirm an Azure subscription, resource group, and region are linked with Owner/Contributor rights
```

There is no PowerShell cmdlet to configure billing — this step is admin-center/Azure-portal only. Confirm the signed-in account is a **Global Administrator** or **SharePoint Administrator** (OneDrive/SharePoint) or **Exchange Administrator** (Exchange) — a lesser role will not be able to complete this setup.

**Rollback:** Toggling Backup **Status** to Off in the Pay-as-you-go services Settings tab stops new billing but does **not** delete existing backups — those remain recoverable per the 90-day offboarding grace period.

</details>

---
## Escalation Evidence

```
MICROSOFT 365 BACKUP ESCALATION
================================
Date/Time                 :
Tenant ID                  :
Affected Workload          : SharePoint / OneDrive / Exchange (circle)
Affected Item (URL/UPN)    :
Protection Policy Name     :
Policy Status               :
Protection Unit Status      :
Restore Session ID          :
Restore Session Status      :
Restore Session Error Text  :
Hold/Compliance Lock Present: Yes / No
Billing Policy Linked       : Yes / No
Steps Already Tried         :
```

---
## 🎓 Learning Pointers

- **Protection policies don't auto-expand.** A new SharePoint site, OneDrive account, or mailbox created after a policy exists will **not** be backed up unless it matches an inclusion rule or is added manually — this is the #1 "why isn't this restorable" root cause.
- **Restore points don't exist before the item was added to a policy.** Adding an item today does not let you restore to last week — the retention clock starts at first successful backup, not at policy creation.
- **In-place restore is destructive by design.** OneDrive/SharePoint accounts and sites aren't locked read-only during a pending restore — a user can keep editing and lose that work when the rollback lands. Warn the user before restoring in place.
- **SEC 17a-4(f) holds block in-place restores on purpose** — this preserves the immutability guarantee. New-URL/new-folder restore is the only path around it.
- **Official docs:** [Overview of Microsoft 365 Backup](https://learn.microsoft.com/en-us/microsoft-365/backup/backup-overview?view=o365-worldwide) | [Restore data in Microsoft 365 Backup](https://learn.microsoft.com/en-us/microsoft-365/backup/backup-restore-data?view=o365-worldwide) | [Set up Microsoft 365 Backup](https://learn.microsoft.com/en-us/microsoft-365/backup/backup-setup?view=o365-worldwide)
- **Community:** [Microsoft 365 Backup FAQ](https://learn.microsoft.com/en-us/microsoft-365/backup/backup-faq?view=o365-worldwide) | r/Office365, r/sysadmin
