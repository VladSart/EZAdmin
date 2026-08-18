# Group Writeback v2 → Cloud Sync Group Provisioning Migration — Hotfix Runbook (Mode B: Ops)
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
# Run ON the Entra Connect Sync server, with the ADSync and ActiveDirectory modules available.

# 1. Is Group Writeback v2 actually enabled on this tenant?
Import-Module ADSync -ErrorAction SilentlyContinue
(Get-ADSyncAADCompanyFeature).GroupWritebackV2

# 2. How many groups are currently written back, and are any mail-enabled (out of
#    this migration's scope — only cloud-created security groups w/ universal scope
#    written back via GWB v2 are supported by this migration path)?
$gwbOU = '<DN of Group Writeback target OU>'
Get-ADGroup -Filter * -SearchBase $gwbOU -Properties mail, GroupScope, adminDescription |
  Select-Object Name, GroupScope, mail, adminDescription

# 3. Has the adminDescription -> msDS-ExternalDirectoryObjectID copy already run?
#    Cloud Sync validates group membership references against this attribute via
#    the AD global catalog — without it, migrated groups show empty/broken membership.
Get-ADGroup -Filter * -SearchBase $gwbOU -Properties adminDescription, msDS-ExternalDirectoryObjectID |
  Where-Object { $_.adminDescription -ne $_.'msDS-ExternalDirectoryObjectID' } |
  Select-Object Name, adminDescription, msDS-ExternalDirectoryObjectID

# 4. Provisioning agent version (migration procedure needs 1.1.1367.0+; the
#    Group Provisioning to AD feature itself needs 1.1.1373.0+)
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Azure AD Connect Provisioning Agent' -ErrorAction SilentlyContinue |
  Select-Object DisplayVersion

# 5. Is the cloudNoFlow coexistence rule pair already in place (mid-migration state)?
Get-ADSyncRule | Where-Object { $_.Name -match 'cloudNoFlow' } | Select-Object Name, Direction, Precedence
```

| Triage result | Interpretation | Do this |
|---|---|---|
| `GroupWritebackV2` returns `True` and groups are written back | GWB v2 still active — this is the deprecated, unsupported-since-30 Jun 2024 preview feature | Fix 1 |
| Any written-back group has `mail` populated (not `$null`) | Mail-enabled group/DL — **out of scope** for this migration path, stays on GWB v1 behavior | Fix 2 |
| `adminDescription` and `msDS-ExternalDirectoryObjectID` don't match for existing groups | Prerequisite Step 1 not yet run — Cloud Sync membership validation will fail post-migration | Fix 3 |
| Agent version below `1.1.1367.0` | Migration procedure isn't supported on this agent build | Fix 4 |
| `cloudNoFlow` rule pair exists but `GroupWritebackV2` is still `True` | Migration is mid-flight — coexistence rules created but the feature switch hasn't been flipped yet | Fix 5 |
| `cloudNoFlow` rule pair exists AND `GroupWritebackV2` is `False`, but groups aren't provisioning via Cloud Sync | Cloud Sync's Group Provisioning to AD job isn't configured/scoped correctly yet | Fix 6 |
| Customer wants to just disable GWB v2 without migrating (no longer using the feature) | Different, simpler path — no Cloud Sync coexistence needed | Fix 7 |
| Groups renamed unexpectedly after migration (`CN=Group_<guid>` → `CN=<name>_<objectid>`) | Expected Cloud Sync default naming behavior, not a bug | Fix 8 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Group Writeback v2 (Connect Sync) — public preview, DEPRECATED, unsupported
since 30 Jun 2024. Still functions if left alone, but can break without notice
and receives no fixes. This is a "migrate when convenient, not urgent-fire"
finding UNLESS the customer is already hitting a GWB v2 bug.
   │
   ├─ Scope gate — is this migration path even applicable?
   │     ├─ Cloud-created SECURITY groups only
   │     ├─ Written back with UNIVERSAL scope only
   │     └─ Mail-enabled groups / distribution lists → NOT supported by this
   │           migration; they continue on Group Writeback v1 behavior instead
   │
   ├─ Prerequisites
   │     ├─ Hybrid Identity Administrator (Entra) role
   │     ├─ On-prem Domain Administrator (to read/write adminDescription and
   │     │     msDS-ExternalDirectoryObjectID — a schema attribute requiring
   │     │     Server 2016+ DCs)
   │     ├─ Provisioning agent >= 1.1.1367.0 (migration procedure)
   │     │     — Group Provisioning to AD feature itself needs >= 1.1.1373.0
   │     ├─ Connect Sync server can reach DCs on TCP/389 (LDAP) + TCP/3268 (GC)
   │     │     — required for global catalog membership-reference lookups
   │     └─ Entra ID P1 licensing (Group Provisioning to AD DS requirement)
   │
   ├─ Step 1 — Reference-attribute prep (do this BEFORE any rule/staging change)
   │     └─ Copy adminDescription -> msDS-ExternalDirectoryObjectID for every
   │           already-written-back group — Cloud Sync's membership validation
   │           depends on this indexed, GC-replicated attribute
   │
   ├─ Step 2-4 — Coexistence mechanism (narrower than the general Cloud Sync
   │     migration's OU-based cloudNoFlow — this one is ATTRIBUTE-scoped)
   │     ├─ Staging mode + disabled scheduler on Connect Sync while rules build
   │     ├─ INBOUND join rule: cloudMastered=true AND mail=ISNULL -> sets
   │     │     cloudNoFlow=True (catches cloud-created security groups only,
   │     │     not the mail-enabled ones — this is the scope enforcement point)
   │     └─ OUTBOUND rule: LinkType=JoinNoFlow, scope cloudNoFlow=true
   │           — NOTE: JoinNoFlow blocks adds/deletes/non-reference attribute
   │           updates, but reference attributes (e.g. membership) CAN still
   │           flow through. Not a full read-only staging mode.
   │
   ├─ Step 5 — The irreversible switch
   │     └─ Set-ADSyncAADCompanyFeature -GroupWritebackV2 $false
   │           — after this, ALL M365 groups write back independently of the
   │           admin-center "Writeback Enabled" toggle (unconditional GWB v1
   │           behavior for M365 groups) — a side effect worth flagging to the
   │           customer BEFORE flipping this switch, not after
   │
   └─ Step 6-7 — Cutover
         ├─ Remove Connect Sync staging mode
         └─ Configure Cloud Sync's Group Provisioning to AD job, scoped to the
               same cloud-created-security-group population
```

Never remove written-back groups, the target OU, or referenced objects from Connect Sync's scope before Cloud Sync is configured and validated — Connect Sync will interpret that as deprovisioning and may delete the on-prem group objects.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm scope before anything else.** Pull every written-back group's `mail` and `GroupScope` attributes (Triage step 2). Mail-enabled groups and DLs are explicitly unsupported by this migration — they stay on GWB v1 behavior regardless of what happens to GWB v2.
2. **Run the `adminDescription` copy script (Prerequisites) if not already done.** This is the single most common cause of "group migrated but membership is empty" tickets — Cloud Sync can't validate a member reference without `msDS-ExternalDirectoryObjectID` populated.
3. **Confirm agent version and P1 licensing** before scheduling any customer-facing migration window.
4. **Build and verify the `cloudNoFlow`/`JoinNoFlow` rule pair BEFORE flipping the feature switch.** Confirm via Triage step 5 that both halves exist and are scoped correctly (`cloudMastered=true AND mail=ISNULL` inbound; `cloudNoFlow=true` outbound) — a missing or misscoped rule risks Connect Sync deprovisioning groups it thinks fell out of scope.
5. **Treat `Set-ADSyncAADCompanyFeature -GroupWritebackV2 $false` as a point of no return.** Run a full sync cycle immediately before and after, and don't schedule this during a change freeze or right before an unattended period.
6. **After cutover, validate Cloud Sync's Group Provisioning to AD job is actually picking up the groups** — the rule pair alone doesn't move anything; it only stops Connect Sync from exporting.

---
## Common Fix Paths

<details><summary>Fix 1 — GWB v2 still active, planning the migration</summary>

This is expected state for any tenant that hasn't migrated yet. GWB v2 is deprecated (unsupported since 30 Jun 2024) but will keep functioning until it doesn't — Microsoft gives no advance warning for a functional break on a deprecated preview feature. Frame this to the customer as "plan this proactively," not "emergency," unless they're already hitting an active bug.

**Rollback:** n/a — planning finding, no change made yet.
</details>

<details><summary>Fix 2 — Mail-enabled group/DL found in the written-back set</summary>

Confirm this with the customer explicitly: mail-enabled groups and distribution lists written back via GWB v1 or v2 are **not** supported by this migration procedure. After GWB v2 is disabled (Fix 5/Step 5 below), Microsoft 365 groups revert to GWB v1's writeback behavior unconditionally — so mail-enabled M365 groups typically keep working without any migration action needed on them specifically. Document this distinction so the customer doesn't expect a Cloud Sync equivalent for mail-enabled writeback that doesn't exist.

**Rollback:** n/a — scoping clarification, no change.
</details>

<details><summary>Fix 3 — adminDescription / msDS-ExternalDirectoryObjectID mismatch</summary>

```powershell
# Provide the DistinguishedName of the Group Writeback target OU
$gwbOU = '<DN of Group Writeback target OU>'
$properties = @('displayName','Samaccountname','adminDescription','msDS-ExternalDirectoryObjectID')
$groups = Get-ADGroup -Filter * -SearchBase $gwbOU -Properties $properties |
    Where-Object { $_.adminDescription -ne $null } | Select-Object $properties

foreach ($group in $groups) {
    Set-ADGroup -Identity $group.Samaccountname -Add @{('msDS-ExternalDirectoryObjectID') = $group.adminDescription}
}
```
Run this against every group in the writeback OU before proceeding to the rule-pair steps. Without it, Cloud Sync's global-catalog membership validation has nothing to match against and migrated groups can show empty or broken membership post-cutover.

**Rollback:** clearing `msDS-ExternalDirectoryObjectID` is non-destructive to existing GWB v2 operation — safe to re-run if needed.
</details>

<details><summary>Fix 4 — Provisioning agent below required version</summary>

Upgrade the provisioning agent to at least `1.1.1367.0` (migration procedure minimum) — and to at least `1.1.1373.0` if the Group Provisioning to AD feature itself will also be newly configured as part of this migration, not just the coexistence rules. Check current release notes before upgrading, since agent versions move independently of this repo's own records.

**Rollback:** standard provisioning-agent upgrade rollback (uninstall/reinstall the prior MSI) — not specific to this migration.
</details>

<details><summary>Fix 5 — Ready to flip the GroupWritebackV2 switch</summary>

```powershell
# 1. Confirm cloudNoFlow rule pair is in place and correctly scoped (Triage step 5)
Get-ADSyncRule | Where-Object { $_.Name -match 'cloudNoFlow' }

# 2. Run a full sync cycle first
Start-ADSyncSyncCycle -PolicyType Initial

# 3. The irreversible switch — all M365 groups begin writing back unconditionally
#    after this, independent of the admin-center "Writeback Enabled" toggle
Set-ADSyncAADCompanyFeature -GroupWritebackV2 $false

# 4. Run a full sync cycle again
Start-ADSyncSyncCycle -PolicyType Initial

# 5. Re-enable the scheduler if it was disabled for this change
Set-ADSyncScheduler -SyncCycleEnabled $true
```

**Rollback:** none — Microsoft documents this operation as irreversible. The only fallback is a full Connect Sync configuration restore from a pre-migration backup (Import/Export settings) plus re-enabling the feature flag, which is not a guaranteed clean reversal. Confirm the customer understands this before running step 3.
</details>

<details><summary>Fix 6 — Rules in place, feature disabled, but Cloud Sync isn't provisioning groups</summary>

The `cloudNoFlow`/`JoinNoFlow` pair only stops Connect Sync from exporting — it does not itself move anything to Cloud Sync. Confirm a Cloud Sync Group Provisioning to AD job actually exists and is scoped to the same group population (Selected security groups or All security groups + attribute filter — see `CloudSync-A.md` for job configuration detail). Also confirm scale: Cloud Sync's group provisioning caps at 50,000 members per group and has separate group-count ceilings depending on scoping mode.

**Rollback:** none — this is a missing-configuration fix, not a destructive change.
</details>

<details><summary>Fix 7 — Just disabling GWB v2, no Cloud Sync replacement wanted</summary>

If the customer confirms they no longer need cloud-security-group writeback to AD at all, the `cloudNoFlow` coexistence rules aren't needed — `Set-ADSyncAADCompanyFeature -GroupWritebackV2 $false` can be run directly after confirming no downstream app/process depends on those written-back groups. Still back up the Connect Sync configuration first; this switch is irreversible regardless of whether a Cloud Sync replacement is configured.

**Rollback:** none — same irreversibility as Fix 5.
</details>

<details><summary>Fix 8 — Groups renamed after migration (CN format changed)</summary>

Expected behavior, not a fault. Cloud Sync defaults to `CN=<display name>_<last 12 digits of object ID>` even if Connect Sync was using its own default `CN=Group_<guid>` format. To preserve the original Connect Sync naming convention, override the `CN` attribute-flow expression in the Cloud Sync job:

```
Append("Group_", [objectId])
```

**Rollback:** n/a — a configuration preference, apply the expression override going forward; it does not retroactively rename already-migrated groups without a re-sync.
</details>

---
## Escalation Evidence

```
Tenant/customer name: ____________________
GroupWritebackV2 feature status (True/False): ____________________
Total groups written back via GWB v2: ____________________
Mail-enabled groups found in scope (should be 0 for this migration path): ____________________
adminDescription -> msDS-ExternalDirectoryObjectID copy completed (Y/N): ____________________
Provisioning agent version: ____________________
cloudNoFlow rule pair present (Y/N): ____________________
GroupWritebackV2 switch flipped (Y/N, date/time): ____________________
Cloud Sync Group Provisioning to AD job configured and scoped (Y/N): ____________________
Config backup taken before migration started (Y/N, date): ____________________
Specific blocker (if any): ____________________
```

---
## 🎓 Learning Pointers

- **GWB v2 is a deprecated PREVIEW feature, not a GA feature being sunset.** It's been unsupported since 30 June 2024 and can break without notice — this changes the urgency conversation with a customer from "nice to modernize eventually" to "plan this now, before it breaks on its own schedule." [Migrate Microsoft Entra Connect Sync Group Writeback v2 to Microsoft Entra Cloud Sync](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/migrate-group-writeback)
- **This migration path is narrowly scoped — cloud-created security groups with universal scope only.** Mail-enabled groups and distribution lists are explicitly excluded and fall back to Group Writeback v1 behavior instead. Don't assume "migrate group writeback" covers every group type a customer has written back.
- **`msDS-ExternalDirectoryObjectID` is the load-bearing attribute Cloud Sync depends on for membership validation.** Skipping the `adminDescription` copy step is the single most common cause of "migrated but membership is broken" tickets for this topic.
- **`JoinNoFlow` is not full staging mode.** It blocks adds, deletes, and non-reference attribute updates, but reference attributes (like group membership) can still flow through. Understanding this distinction prevents false confidence that a scoped-out OU/attribute set is fully frozen.
- **`Set-ADSyncAADCompanyFeature -GroupWritebackV2 $false` is Microsoft-documented as irreversible**, and it has a side effect beyond the switch itself: all M365 groups start writing back unconditionally afterward, regardless of the admin-center toggle. Flag both facts to the customer before running it, not after.
- **This is a different coexistence mechanism than the general Connect Sync → Cloud Sync migration** covered in `CloudSyncMigration-A.md`/`-B.md` — that one scopes `cloudNoFlow` by OU; this one scopes it by attribute filter (`cloudMastered`/`mail`). Don't reuse one topic's rule pair as a template for the other without adjusting the scoping condition.
