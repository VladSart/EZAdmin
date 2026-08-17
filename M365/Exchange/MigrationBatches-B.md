# Exchange Online Mailbox Migration Batches — Hotfix Runbook (Mode B: Ops)
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
Connect-ExchangeOnline -UserPrincipalName <admin-upn>

# 1. What batches exist and what state are they in?
Get-MigrationBatch | Select Identity, MigrationType, Status, TotalCount, SuccessfulCount, FailedCount

# 2. Any individual users actually failing (batch can say "Synced" while users inside are stuck)?
Get-MigrationUser | Where-Object { $_.Status -in 'Failed','Stalled' } | Select Identity, Status, Batch

# 3. What's the actual error text for a failing user?
Get-MigrationUserStatistics -Identity <user-migration-identity> -IncludeReport |
  Select -ExpandProperty Report | Select -ExpandProperty Errors

# 4. Is the source connection itself healthy? (on-prem/Outlook Anywhere/IMAP source only — skip for cross-tenant)
Test-MigrationServerAvailability -ExchangeOutlookAnywhere -Autodiscover -EmailAddress <onprem-admin-upn> -Credentials (Get-Credential)

# 5. Is this a cross-tenant migration? Confirm the org relationship is actually enabled for moves
Get-OrganizationRelationship | Where-Object { $_.MailboxMoveEnabled -eq $true } |
  Select Identity, DomainNames, MailboxMoveEnabled, MailboxMoveCapability
```

| Result | Interpretation |
|---|---|
| Batch `Status = Syncing`, most users show `StalledDueToTarget_*` or `StalledDueToSource_*` | Normal — Workload Management (WLM) throttling. Do not treat as a fault; see Fix 1 only if speed is genuinely unacceptable. |
| Batch `Status = Failed` or `CompletedWithErrors`, specific users `Failed` | Real per-user failures — pull the error report (step 3) before touching anything. |
| Users stuck at `Status = Synced` and never finish | `SuspendWhenReadyToComplete` (or the batch default) is holding them — needs a manual complete/resume. See Fix 2. |
| Users stuck at `AutoSuspended` | Expected pause point at 95% sync — same fix path as above. |
| `MRSProxyConnectionLimitReachedTransientException` in error report | On-prem MRSProxy hit its 100-connection default ceiling. See Fix 3. |
| Report shows `DataConsistencyScore` warnings or "skipped items" pending approval | Migration can't finish until skipped items are reviewed/approved. See Fix 4. |
| `New-MigrationBatch` for cutover fails with "a cutover migration batch already exists" | Only one cutover batch is allowed tenant-wide at a time. See Fix 5. |
| Cross-tenant batch fails at creation with an organization-relationship error | Org relationship missing `MailboxMoveEnabled`/`MailboxMoveCapability`/`MailboxMovePublishedScopes`, or the target `MailUser` isn't correctly pre-staged. See Fix 6. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Migration type selected: Cutover | Staged | IMAP | Remote Move (hybrid) | Cross-tenant]
        │
        ▼
[Migration endpoint created]
  Cutover/Staged/Remote Move → Outlook Anywhere/EWS + admin credentials
  IMAP → IMAP server + per-user or admin credentials
  Cross-tenant → Organization Relationship (both tenants) + pre-staged MailUser
        │
        ▼
[Source connectivity path]
  On-prem → MRSProxy (100 concurrent connections, default)
  Cross-tenant → source tenant's MRS via the org relationship, no MRSProxy involved
        │
        ▼
[Workload Management / MRS throttling]
  Exchange 2016+ WLM: 10 concurrent moves per source/target by default
  Overridable via New-SettingOverride (on-prem only)
        │
        ▼
[Migration batch wraps N individual move requests]
        │
        ▼
[Per-user migration status: Queued → CopyingMessages → (Stalled*) → Synced/AutoSuspended → Completing → Completed]
        │
        ▼
[Batch-level completion]
  Cutover → delete batch → change MX → decommission
  Staged/Remote Move → batch stays until all users moved, then removed
  Cross-tenant → batch completes per user, source mailbox converted to MailUser
        │
        ▼
[License assignment on target — mailbox disabled if unlicensed after 30-day grace period]
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm which migration type you're dealing with.** `Get-MigrationBatch | Select Identity, MigrationType` — the fix path differs completely between Cutover/Staged/IMAP (on-prem or third-party source) and Cross-tenant (both sides are Exchange Online). Don't assume.

2. **Check batch-level status first, then drill into users.** `Get-MigrationBatch -Identity <name> | fl Status,TotalCount,SuccessfulCount,FailedCount,SyncedCount`. A batch showing `Synced` with 0 `FailedCount` is healthy and waiting on completion, not broken.

3. **Pull the per-user report for anyone `Failed` or `Stalled` for more than a sync cycle.** `Get-MigrationUserStatistics -Identity <upn> -IncludeReport` — the `Report.Errors` collection has the actual root cause; don't guess from the batch summary alone.

4. **For on-prem sources, rule out throttling before calling it a fault.** `StalledDueToTarget_MdbReplication`, `StalledDueToTarget_MdbAvailability`, and `StalledDueToTarget_DiskLatency` are Exchange Server 2019 Workload Management doing its job — by default only 10 moves run concurrently per source/target, expected behavior, not a support case.

5. **For cross-tenant, validate both organization relationships before touching the batch.** Source tenant needs `MailboxMoveEnabled = $true`, `MailboxMoveCapability = RemoteOutbound` (or `RemoteInbound` depending on direction), and a `MailboxMovePublishedScopes` security group containing the mailbox being moved. Target tenant needs a matching relationship naming the source tenant ID.

6. **Check license grace period exposure on anything sitting `Completed` for a while.** An unlicensed migrated mailbox is disabled automatically after 30 days — this shows up later as "the mailbox I migrated last month just disappeared."

---
## Common Fix Paths

<details><summary>Fix 1 — Migration "stuck" but it's actually WLM/MRS throttling</summary>

Not a fault. Confirm and, only if genuinely needed, raise the concurrency ceiling on the **on-premises** Exchange server (has no effect on a pure cross-tenant EXO-to-EXO move, which throttles differently and isn't user-adjustable):

```powershell
# Run on the on-prem Exchange server, not in EXO PowerShell
$limit = 25
New-SettingOverride -Name "MdbReplication" -Component WorkloadManagement -Section MdbReplication -Parameters @("MaxConcurrency=$limit") -Reason "Migration throughput"
New-SettingOverride -Name "MdbAvailability" -Component WorkloadManagement -Section MdbAvailability -Parameters @("MaxConcurrency=$limit") -Reason "Migration throughput"
New-SettingOverride -Name "DiskLatency" -Component WorkloadManagement -Section DiskLatency -Parameters @("MaxConcurrency=$limit") -Reason "Migration throughput"
New-SettingOverride -Name "MdbDiskLatency" -Component WorkloadManagement -Section MdbDiskWriteLatency -Parameters @("MaxConcurrency=$limit") -Reason "Migration throughput"
Get-ExchangeServer | Get-ServerComponentState -Component ServerWideOffline # sanity check the server isn't otherwise degraded
```

**Rollback:** `Remove-SettingOverride -Identity "MdbReplication"` (repeat per override name). Microsoft recommends starting at 25 and never exceeding 100 — pushing it too high degrades production mailbox performance, not just migration speed.

</details>

<details><summary>Fix 2 — Users stuck at Synced / AutoSuspended, batch never finishes</summary>

This is a deliberate pause, not a hang — `SuspendWhenReadyToComplete` stops the move at ~95% so both copies stay in sync until you're ready for the final cutover.

```powershell
# Complete a specific batch (finalizes all AutoSuspended/Synced users in it)
Complete-MigrationBatch -Identity <BatchName>

# Or resume a specific stuck user without completing the whole batch
Get-MigrationUser -Identity <upn> | Resume-MigrationUser
```

**Rollback:** none needed — completing a batch is the intended end state. If you completed too early and users report missing recent mail, the source mailbox is untouched for Staged/Cutover until you explicitly delete it; for Remote Move the source mailbox becomes a mail-enabled user object and is not directly recoverable without a backup/restore.

</details>

<details><summary>Fix 3 — MRSProxy hit the 100-connection ceiling</summary>

Error text: `MRSProxyConnectionLimitReachedTransientException ... Current connections: 100, Connections limit: 100`.

```powershell
# Exchange 2013+ — edit the config file on each CAS/MBX server, then restart the MRS Proxy pool
# C:\Program Files\Microsoft\Exchange Server\V15\Bin\MSExchangeMailboxReplication.exe.config
#   <MRSProxyConfiguration MaxMRSConnections="320" ... />

# Exchange 2010 — per Client Access server
Set-WebServicesVirtualDirectory -Server <ServerName> -MRSProxyMaxConnections 320
```

**Rollback:** revert `MaxMRSConnections` back to 100 (or the prior value) once the migration wave finishes. Note this setting is reset by every Exchange cumulative update on 2013+ and must be reapplied.

</details>

<details><summary>Fix 4 — Skipped items / Data Consistency Score blocking completion</summary>

`BadItemLimit`/`LargeItemLimit` are deprecated (any migration started before ~Nov 2022 with them set still honors those values; new migrations use Data Consistency Score instead). If a migration reports meaningful data loss, it will not complete until you explicitly approve it:

```powershell
# Review what was skipped
Get-MigrationUserStatistics -Identity <upn> -IncludeReport | Select -ExpandProperty Report

# Approve skipped items discovered before a given point in time so the migration can complete
Set-MigrationUser -Identity <upn> -SkippedItemApprovalTime (Get-Date)
```

**Rollback:** none — this is an explicit acknowledgment, not a reversible action. Do not approve broadly without reviewing what's actually being skipped; a high skip count against a legal/compliance mailbox needs sign-off before you touch this.

</details>

<details><summary>Fix 5 — "A cutover migration batch already exists"</summary>

Cutover migration allows exactly **one** batch tenant-wide at any time.

```powershell
Get-MigrationBatch | Where-Object { $_.MigrationType -like "*Cutover*" }
# If the existing batch is genuinely done and verified, remove it before creating the new one
Remove-MigrationBatch -Identity <ExistingCutoverBatchName>
```

**Rollback:** none — removing a completed cutover batch just stops the ongoing-sync safety net; it does not touch already-migrated mailboxes. Do not remove a batch that hasn't finished syncing.

</details>

<details><summary>Fix 6 — Cross-tenant batch fails at creation or per-user pre-check</summary>

Two independent things must both be correct — check both before assuming either is broken:

```powershell
# In the SOURCE tenant: relationship must publish move capability to the target tenant
Get-OrganizationRelationship | fl Identity, DomainNames, MailboxMoveEnabled, MailboxMoveCapability, MailboxMovePublishedScopes

# In the TARGET tenant: relationship must name the source tenant ID
Get-OrganizationRelationship | fl Identity, DomainNames, MailboxMoveEnabled, MailboxMoveCapability

# The mailbox being moved must be a member of the scoping security group referenced above (source tenant)
Get-DistributionGroupMember -Identity <MailboxMovePublishedScopes-group-name>

# The target MailUser must already exist with matching ExchangeGUID/LegacyExchangeDN — this is a
# pre-staging step done BEFORE the batch, not something the migration creates for you
Get-MailUser -Identity <upn> | fl ExchangeGUID, LegacyExchangeDN, ExternalEmailAddress
```

**Rollback:** none destructive here — these are read/config checks. If the `MailUser` was pre-staged incorrectly, fix the attributes and retry rather than deleting and recreating (deleting can orphan the eventual mail-enabled user object).

</details>

---
## Escalation Evidence

```
MIGRATION BATCH ESCALATION
---------------------------
Tenant:                 <tenant.onmicrosoft.com>
Migration type:         <Cutover / Staged / IMAP / Remote Move / Cross-tenant>
Batch name:             <BatchName>
Batch status:           <Get-MigrationBatch output>
Total / Success / Fail: <counts>
Affected user(s):       <UPN list>
Error text (verbatim):  <from Get-MigrationUserStatistics -IncludeReport>
Source system:          <on-prem Exchange version / IMAP host / source tenant ID>
Throttling ruled out:   <yes/no — WLM/MRS checked>
Org relationship OK:    <yes/no/n-a — cross-tenant only>
License assigned:       <yes/no — target mailbox>
Business impact:        <mailbox count, deadline, MX cutover dependency>
```

---
## 🎓 Learning Pointers
- Cutover migration technically supports up to 2,000 mailboxes but Microsoft explicitly recommends capping it at ~150 — the batch is a single unit with no incremental completion, so a 2,000-mailbox cutover batch that hits an error late in the run re-syncs the whole batch. See [What you need to know about a cutover email migration](https://learn.microsoft.com/en-us/Exchange/mailbox-migration/what-to-know-about-a-cutover-migration).
- Staged migration only supports **Exchange 2003 or 2007** as the source — not 2010/2013/2016. If someone asks for "a staged migration" off a 2016+ box, they actually want Remote Move (hybrid) migration; the terminology gets confused constantly in the field.
- A `Stalled*` status is not an error state — it's WLM/MRS throttling working as designed. Don't open a Microsoft support case for this; see [Mailboxes are stalled during a migration](https://learn.microsoft.com/en-us/troubleshoot/exchange/migration/mailboxes-stalled-during-migration).
- `BadItemLimit`/`LargeItemLimit` are deprecated for new migrations — Data Consistency Score is the current mechanism. Treat a DCS warning as a real data-fidelity signal to review, not boilerplate to dismiss.
- For cross-tenant migrations, the target-side `MailUser` pre-staging (matching `ExchangeGUID`, `LegacyExchangeDN` as an X500 proxy address) is the single most common point of failure — it has to be exactly right before the batch is even created, and there's no in-batch remediation for it.
- See the companion deep-dive, `MigrationBatches-A.md`, for the full dependency stack, symptom map, and a read-only audit script (`Scripts/Get-MigrationBatchHealth.ps1`).
