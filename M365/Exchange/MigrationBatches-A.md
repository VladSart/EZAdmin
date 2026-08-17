# Exchange Online Mailbox Migration Batches — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- **Cutover migration** — all mailboxes moved in a single batch, source Exchange 2003+, tenant-wide limit of 2,000 mailboxes (Microsoft-recommended practical cap ~150)
- **Staged migration** — legacy path for Exchange **2003 or 2007 sources only**, CSV-driven batches over time, requires directory sync
- **IMAP migration** (including Google Workspace/Gmail via IMAP or the native Google Workspace migration endpoint) — non-Exchange source systems
- **Remote Move migration** — the hybrid onboarding (on-prem → EXO) and offboarding (EXO → on-prem) path, built on `New-MoveRequest` wrapped in a migration batch
- **Cross-tenant mailbox migration** — EXO-to-EXO moves between two different Microsoft 365 tenants (mergers, acquisitions, divestitures, tenant consolidation)
- Migration batch/user lifecycle, throttling (WLM/MRS/MRSProxy), skipped-item handling (Data Consistency Score), and post-migration licensing

**Does not cover:**
- Setting up Exchange Hybrid itself (Hybrid Configuration Wizard, hybrid connectors, certificate configuration) — see `Hybrid-Coexistence-A.md`. This file assumes hybrid (or the relevant migration prerequisite) is already in place and focuses on the migration batch mechanics themselves.
- Steady-state on-prem ↔ EXO mail flow after migration is complete — see `Mail-Flow-A.md`
- Public folder migration — see `PublicFolders-A.md`
- SharePoint/OneDrive content migration — see `M365/SharePoint-OneDrive/Migration-A.md`
- Entra ID identity/B2B configuration for cross-tenant scenarios (external identities, guest access) — see `EntraID/Troubleshooting/CrossTenant-A.md`. This file covers the **mailbox move** mechanics specifically, which use Exchange organization relationships, not Entra B2B collaboration.
- Windows print server migration — unrelated, see `Windows/Troubleshooting/PrintServerMigration-A.md`

**Assumptions:**
- Admin has Exchange Online PowerShell access (`Connect-ExchangeOnline`) and, for on-prem source types, on-premises Exchange management access
- Source and target domains are already verified/accepted where required
- For Remote Move and Staged: Microsoft Entra Connect (or Cloud Sync) is configured and syncing
- For Cross-tenant: both tenants have Exchange Online, and an admin has access to both

---
## How It Works

<details><summary>Full architecture — five migration types, one shared engine</summary>

All five migration types run on the **Mailbox Replication Service (MRS)** — the same underlying engine used for ordinary intra-tenant mailbox moves. What differs is how MRS reaches the *source*:

- **Cutover / Staged / Remote Move (onboarding)**: MRS connects to the on-premises Exchange server via **MRSProxy**, a component of the on-prem Client Access (or Mailbox, in modern versions) role, reached over Outlook Anywhere (RPC/HTTP) or EWS depending on version. This is why these three share the same connectivity prerequisites (Outlook Anywhere configured, trusted CA certificate, migration endpoint pointing at Autodiscover).
- **IMAP migration**: MRS connects directly to the source IMAP server using standard IMAP4 protocol commands — no MRSProxy involved, no Exchange-specific object model on the source, which is exactly why it can't carry calendar, contacts, or tasks (IMAP has no concept of those).
- **Cross-tenant migration**: MRS on the target tenant connects to MRS on the source tenant directly over Microsoft's backbone, authorized by a pair of **Organization Relationships** (one per tenant) rather than MRSProxy or admin credentials. No on-premises component is involved at all — both mailboxes are already in Exchange Online.

A **migration batch** is a management wrapper around one or more individual move operations (`New-MoveRequest` equivalents under the hood). The batch tracks aggregate status; each user inside it has its own status that can diverge from the batch-level summary — a batch showing `Syncing` can contain a mix of `CopyingMessages`, `Stalled*`, and `Completed` users simultaneously.

**Migration type selection matrix:**

| Scenario | Source | Recommended type |
|---|---|---|
| Small org, one-time full cutover, can tolerate a maintenance window | Exchange 2003+ | Cutover |
| Legacy Exchange 2003/2007, want gradual coexistence | Exchange 2003/2007 only | Staged |
| Ongoing coexistence, any current on-prem Exchange version, want per-user control | Exchange 2016/2019/SE (hybrid) | Remote Move |
| Non-Exchange source (Gmail, other IMAP host) | Any IMAP4-capable system | IMAP migration |
| Splitting or merging two Microsoft 365 tenants | Exchange Online (another tenant) | Cross-tenant migration |

</details>

---
## Dependency Stack

```
Layer 5:  License assignment on target mailbox
          (30-day grace period before an unlicensed migrated mailbox is disabled)
              ▲
Layer 4:  Migration batch (aggregates individual moves, tracks Status/TotalCount/SuccessfulCount/FailedCount)
              ▲
Layer 3:  Per-user migration status state machine
          Queued → CopyingMessages → (Stalled* if throttled) → Synced/AutoSuspended → Completing → Completed
              ▲
Layer 2:  Throttling layer
          On-prem: WLM (Exchange 2016+, 10 concurrent/source-target default) overrides legacy MRS throttling
          MRSProxy: 100 concurrent connections per endpoint, default
          Cross-tenant: MRS-to-MRS, throttled server-side, not admin-adjustable
              ▲
Layer 1:  Source connectivity (migration endpoint)
          Cutover/Staged/Remote Move → Outlook Anywhere/EWS + Autodiscover + trusted CA cert
          IMAP → IMAP4 host + credentials (per-user or admin, source-dependent)
          Cross-tenant → Organization Relationship pair (source: MailboxMoveEnabled/Capability/PublishedScopes;
                          target: relationship naming source tenant ID) + pre-staged target MailUser object
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Only 10 users show `CopyingMessages`, rest show `Stalled*` in a batch of 50+ | WLM throttling (Exchange 2019 default: 10 concurrent moves/source or target) — expected, not a fault | `Get-MigrationUser \| Group Status` |
| `MRSProxyConnectionLimitReachedTransientException` | On-prem MRSProxy hit its 100-connection default ceiling | Check migration endpoint's active connection count against `MaxMRSConnections` |
| Batch `Status = Synced`, users never auto-complete | `SuspendWhenReadyToComplete` behavior — 95%-sync pause point, by design | `Get-MigrationUser -Identity <upn> \| fl Status` |
| Users stuck `AutoSuspended` indefinitely | Same pause point, batch just hasn't been told to complete | `Complete-MigrationBatch` not yet run |
| `New-MigrationBatch` fails: "a cutover migration batch already exists" | Cutover allows exactly one tenant-wide batch at a time | `Get-MigrationBatch \| ? MigrationType -like "*Cutover*"` |
| Migration report shows unapproved skipped items, won't finish | Data Consistency Score flagged meaningful data loss requiring explicit approval | `Get-MigrationUserStatistics -IncludeReport` |
| Staged migration batch: users in CSV not found / not migrated | Users aren't yet mail-enabled in the target from directory sync, or CSV UPN mismatch | `Get-MailUser -Identity <upn>` in target tenant |
| Cross-tenant batch creation fails at the org-relationship check | Source relationship missing `MailboxMoveEnabled`/`MailboxMoveCapability`/`MailboxMovePublishedScopes`, or target relationship doesn't name source tenant ID | `Get-OrganizationRelationship \| fl Mailbox*` (both tenants) |
| Cross-tenant batch fails per-user pre-check | Target `MailUser` not pre-staged with matching `ExchangeGUID`/`LegacyExchangeDN` | `Get-MailUser \| fl ExchangeGUID,LegacyExchangeDN` (target tenant) |
| Cross-tenant: mailbox not in scope for the batch | Mailbox not added to the `MailboxMovePublishedScopes` security group in the source tenant | `Get-DistributionGroupMember -Identity <scope-group>` |
| IMAP migration: calendar/contacts/tasks missing after migration | By design — IMAP protocol carries mail only, no PIM data | Confirm expectation was set correctly during planning, not a bug |
| Migrated mailbox "disappeared" weeks after a successful migration | 30-day unlicensed-mailbox grace period expired | `Get-Mailbox -Identity <upn> \| fl WhenMailboxCreated, IsMailboxEnabled` + license check in admin center |
| Cutover migration users show wrong/duplicate accounts | Group provisioning issue — cutover migration cannot detect whether an on-prem AD group is a security group, and provisions non-mail groups incorrectly if not pre-staged | Pre-create empty mail-enabled security groups in the target *before* the batch runs |
| MX cutover done but mail still arrives at on-prem mailboxes for some users | Cutover migration batch was deleted too early, or DNS TTL/propagation not yet complete | `Get-MigrationBatch` (should exist until MX has propagated ≥72h) |

---
## Validation Steps

1. **Confirm migration endpoint connectivity before creating any batch.**
   ```powershell
   Test-MigrationServerAvailability -ExchangeOutlookAnywhere -Autodiscover -EmailAddress <onprem-admin-upn> -Credentials (Get-Credential)
   ```
   Good output: connection settings returned with no errors. Bad: authentication or Autodiscover resolution failure — fix before proceeding, a batch created against a broken endpoint just queues and fails identically for every user.

2. **Verify the migration batch was created and, if `AutoStart` wasn't used, start it.**
   ```powershell
   Get-MigrationBatch -Identity <BatchName> | fl Status
   Start-MigrationBatch -Identity <BatchName>
   ```
   Good: `Status` transitions to `Syncing`. Bad: stays `Created`/`Queued` for an extended period — check for a tenant-wide migration concurrency cap being hit by other batches.

3. **Check per-user status distribution, not just the batch summary.**
   ```powershell
   Get-MigrationUser -BatchId <BatchName> | Group-Object Status | Select Name, Count
   ```
   Good: a mix of `Completed`/`CopyingMessages`/expected `Stalled*` counts consistent with throttling limits. Bad: a large `Failed` count — pull individual reports immediately rather than waiting for the batch to finish.

4. **Pull the detailed error report for any failed or stalled-too-long user.**
   ```powershell
   Get-MigrationUserStatistics -Identity <upn> -IncludeReport | Select -ExpandProperty Report
   ```
   Good: no `Errors` entries, or only informational skipped-item notes within acceptable DCS tolerance. Bad: explicit error codes (e.g., `MigrationPermanentException`) — these need root-cause investigation, not a retry.

5. **For cross-tenant, validate both organization relationships independently — a one-sided misconfiguration is the most common failure.**
   ```powershell
   # Source tenant
   Get-OrganizationRelationship | fl Identity, DomainNames, MailboxMoveEnabled, MailboxMoveCapability, MailboxMovePublishedScopes
   # Target tenant
   Get-OrganizationRelationship | fl Identity, DomainNames, MailboxMoveEnabled, MailboxMoveCapability
   ```
   Good: source shows `MailboxMoveCapability = RemoteOutbound` (or matching direction) with a populated scope group; target shows a relationship whose `DomainNames` includes the source tenant ID. Bad: either side missing, or `MailboxMoveEnabled = $false`.

6. **Post-completion: confirm licensing before declaring the migration done.**
   ```powershell
   Get-Mailbox -Identity <upn> | fl RecipientTypeDetails, WhenMailboxCreated
   ```
   Cross-reference against the Microsoft 365 admin center or `Get-MgUserLicenseDetail` (Graph) to confirm a license was actually assigned — a migrated-but-unlicensed mailbox is a silent 30-day time bomb.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Pre-migration prep**
- Confirm accepted/verified domains in the target tenant
- For Cutover: pre-create empty mail-enabled security groups matching on-prem AD groups (cutover can't detect group type)
- For Staged: confirm directory sync has run and target mail users exist
- For Cross-tenant: pre-stage target `MailUser` objects with correct `ExchangeGUID`/`LegacyExchangeDN`, create and populate the scoping security group, configure both organization relationships

**Phase 2 — Endpoint creation and connectivity test**
- `New-MigrationEndpoint` (type depends on source: `-ExchangeOutlookAnywhere`, `-ExchangeRemoteMove`, `-IMAP`, `-PublicFolder`, `-ExchangeExchangeOnline` for cross-tenant depending on migration architecture)
- `Test-MigrationServerAvailability` before batch creation, not after a failed batch

**Phase 3 — Batch creation and start**
- `New-MigrationBatch` referencing the endpoint, with `-AutoStart` or a deliberate manual `Start-MigrationBatch` step
- Confirm `Status` transitions to `Syncing` within a few minutes

**Phase 4 — Monitoring and throttle diagnosis**
- Distinguish expected `Stalled*` throttling from genuine per-user failures (see Symptom → Cause Map)
- Only escalate WLM/MRSProxy limits if timeline genuinely requires it — raising them has a real production-performance cost on the on-prem side

**Phase 5 — Completion**
- Cutover: verify all users `Synced`/`Completed`, change MX record, wait ≥72h for propagation, then `Remove-MigrationBatch`
- Staged/Remote Move: batches typically stay active until the last wave is moved, then removed
- Cross-tenant: batch completes per user; source mailbox converts to a `MailUser` pointing at the new target mailbox (mail forwarding/redirect behavior depends on configuration)

**Phase 6 — Post-migration**
- Assign licenses immediately — don't let the 30-day grace period start the clock unintentionally
- For Cutover: configure Autodiscover CNAME, decommission on-prem Exchange if applicable
- Validate mail flow, calendar free/busy, and any delegate/permission data that doesn't migrate cleanly (e.g., cross-tenant folder permissions referencing old identities)

---
## Remediation Playbooks

<details><summary>Playbook 1 — Speed up a large on-prem-source migration safely</summary>

1. Confirm throttling is genuinely the bottleneck (not endpoint/network saturation) via the `Stalled*` status distribution.
2. Raise WLM limits incrementally (25 → 35 → 45...) on the on-prem server, checking Exchange Server performance counters between each increase.
3. Never exceed 100 total concurrent moves per Microsoft's own guidance — beyond that point you're degrading production mailbox database performance for active users, not just migration jobs.
4. If MRSProxy connection limits are also a bottleneck, raise `MaxMRSConnections` in tandem (see Fix 3 in the hotfix runbook) — WLM and MRSProxy limits are independent ceilings and both must be raised together for real throughput gains.
5. Revert both settings after the migration wave completes.

</details>

<details><summary>Playbook 2 — Cutover migration for an org near the 2,000-mailbox ceiling</summary>

1. Reconsider: Microsoft's own guidance caps practical cutover use at ~150 mailboxes even though 2,000 is technically supported — a large single-batch cutover has no incremental completion, so a late failure re-syncs everything.
2. If cutover is still the right call (small maintenance window, no ongoing coexistence needed), split into multiple **sequential** cutover batches is not possible — only one cutover batch exists at a time — so consider Remote Move (hybrid) instead for anything approaching the practical ceiling, since it supports multiple concurrent batches by wave/department.
3. Pre-create mail-enabled security groups before starting, since cutover can't distinguish security groups from distribution groups on the source.

</details>

<details><summary>Playbook 3 — Cross-tenant migration pre-staging (the most error-prone step)</summary>

1. In the source tenant, create a mail-enabled security group and add every mailbox in scope for the wave.
2. In the source tenant's organization relationship: set `MailboxMoveEnabled = $true`, `MailboxMoveCapability` to the correct direction, `MailboxMovePublishedScopes` to the group from step 1, and `DomainNames` to include the target tenant ID.
3. In the target tenant, create the organization relationship naming the source tenant ID, with `MailboxMoveEnabled = $true`.
4. In the target tenant, pre-stage each `MailUser` with `ExchangeGUID` matching the source mailbox exactly, `LegacyExchangeDN` added as an X500 proxy address (preserves old-client autocomplete/reply resolution), correct `UserPrincipalName`/`PrimarySmtpAddress`, and `ExternalEmailAddress` pointing at the source mailbox's routing address.
5. Only after all of the above is verified, create the migration batch in the target tenant referencing the source-side scoping group.
6. License each target mailbox as soon as the batch completes for that user — cross-tenant migrations are not exempt from the 30-day grace period.

**Rollback:** a cross-tenant move that needs to be reversed generally requires re-running the reverse direction as its own migration, not a simple "undo" — treat pre-staging mistakes as something to fix and retry rather than something to roll back mid-batch.

</details>

<details><summary>Playbook 4 — Handling meaningful data-loss warnings without blindly approving them</summary>

1. Pull the full report: `Get-MigrationUserStatistics -Identity <upn> -IncludeReport`.
2. Review the specific skipped items — corrupted items are usually safe to approve; large numbers of skipped items on a legal-hold or compliance-relevant mailbox are not.
3. If genuinely acceptable, approve with `Set-MigrationUser -Identity <upn> -SkippedItemApprovalTime (Get-Date)`.
4. If not acceptable, do not approve — instead investigate the source mailbox for the underlying corruption (often resolved by an on-prem `New-MailboxRepairRequest` before re-attempting migration for that user).

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
  Collects migration batch/user evidence for escalation to Microsoft Support or a senior engineer.
#>
$OutFile = "MigrationEvidence_$(Get-Date -Format yyyyMMdd_HHmm).txt"

"=== Migration Batches ===" | Out-File $OutFile
Get-MigrationBatch | Format-List * | Out-File $OutFile -Append

"=== Migration Users (non-Completed) ===" | Out-File $OutFile -Append
Get-MigrationUser | Where-Object { $_.Status -ne 'Completed' } | Format-Table Identity, Status, Batch -AutoSize | Out-File $OutFile -Append

"=== Failed/Stalled User Detail Reports ===" | Out-File $OutFile -Append
Get-MigrationUser | Where-Object { $_.Status -in 'Failed','Stalled' } | ForEach-Object {
    Get-MigrationUserStatistics -Identity $_.Identity -IncludeReport | Select -ExpandProperty Report | Out-File $OutFile -Append
}

"=== Organization Relationships (cross-tenant scenarios) ===" | Out-File $OutFile -Append
Get-OrganizationRelationship | Format-List * | Out-File $OutFile -Append

Write-Host "Evidence written to $OutFile"
```

---
## Command Cheat Sheet

```powershell
Connect-ExchangeOnline -UserPrincipalName <admin-upn>

# Endpoints
New-MigrationEndpoint -ExchangeOutlookAnywhere -Name <EndpointName> -ConnectionSettings $TSMA.ConnectionSettings
Get-MigrationEndpoint | fl Identity, EndpointType, Max*

# Batches
New-MigrationBatch -Name <BatchName> -SourceEndpoint <EndpointName> -AutoStart
Start-MigrationBatch -Identity <BatchName>
Complete-MigrationBatch -Identity <BatchName>
Remove-MigrationBatch -Identity <BatchName>
Get-MigrationBatch | ft Identity, MigrationType, Status, TotalCount, FailedCount

# Users
Get-MigrationUser -BatchId <BatchName>
Get-MigrationUserStatistics -Identity <upn> -IncludeReport
Resume-MigrationUser -Identity <upn>
Set-MigrationUser -Identity <upn> -SkippedItemApprovalTime (Get-Date)

# Connectivity test
Test-MigrationServerAvailability -ExchangeOutlookAnywhere -Autodiscover -EmailAddress <upn> -Credentials (Get-Credential)

# Cross-tenant
Get-OrganizationRelationship | fl Identity, DomainNames, MailboxMoveEnabled, MailboxMoveCapability, MailboxMovePublishedScopes
Get-MailUser -Identity <upn> | fl ExchangeGUID, LegacyExchangeDN, ExternalEmailAddress

# On-prem throttling (run on-prem, not in EXO PowerShell)
New-SettingOverride -Name "MdbReplication" -Component WorkloadManagement -Section MdbReplication -Parameters @("MaxConcurrency=25") -Reason "Migration"
Get-SettingOverride
```

---
## 🎓 Learning Pointers
- The five migration types share one engine (MRS) but three completely different connectivity models — on-prem MRSProxy, direct IMAP, and cross-tenant MRS-to-MRS via organization relationships. Diagnosing "why is this migration stuck" starts with identifying which model applies, not with generic move-request troubleshooting.
- Staged migration is functionally obsolete in most 2026 environments — it only supports Exchange 2003/2007 sources. A request for "staged migration" from a 2016+ environment almost always actually means Remote Move (hybrid), and building/using the wrong runbook wastes real time.
- Cutover migration's "only one batch at a time" limitation is a hard platform constraint, not a configuration option — plan around it rather than trying to work around it.
- `BadItemLimit`/`LargeItemLimit` are deprecated (migrations created after ~Nov/Dec 2022 use Data Consistency Score instead); see [Deprecating bad item limit and large item limit migration parameters](https://techcommunity.microsoft.com/blog/exchange/deprecating-bad-item-limit-and-large-item-limit-migration-parameters/3652478).
- Cross-tenant migration pre-staging (`ExchangeGUID`/`LegacyExchangeDN` matching) is the single highest-leverage step in the entire process — get it wrong and the batch either won't create or will silently produce a mailbox with broken legacy-client autocomplete/reply resolution. See [Cross-tenant mailbox migration](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-mailbox-migration?view=o365-worldwide) and the [introductory overview](https://techcommunity.microsoft.com/blog/exchange/introduction-to-cross-tenant-mailbox-migrations/4169613).
- The 30-day unlicensed-mailbox grace period applies uniformly across all five migration types — build license assignment into the migration runbook itself, not as an afterthought after the batch shows `Completed`.
- See [Mailboxes are stalled during a migration](https://learn.microsoft.com/en-us/troubleshoot/exchange/migration/mailboxes-stalled-during-migration) and [Use PowerShell to perform a cutover migration](https://learn.microsoft.com/en-us/microsoft-365/enterprise/use-powershell-to-perform-a-cutover-migration-to-microsoft-365?view=o365-worldwide) for full command-level detail beyond this cheat sheet.
