# AD DS Backup & Restore Failures — Hotfix Runbook (Mode B: Ops)
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

Run these from an elevated PowerShell session on a Domain Controller:

```powershell
# 1. Confirm System State backup history and last successful run
wbadmin get versions

# 2. Check for USN rollback indicators in the Directory Service event log (the single most
#    urgent thing to rule out — this DC may need to be quarantined from replication)
Get-WinEvent -LogName "Directory Service" -MaxEvents 100 |
  Where-Object { $_.Id -in 2095, 1113, 1115 } |
  Select-Object TimeCreated, Id, Message

# 3. Confirm the DC's invocationID and highest committed USN (baseline for comparison)
repadmin /showrepl <DCName> /csv | ConvertFrom-Csv | Select-Object -First 1

# 4. Check DSRM (Directory Services Restore Mode) local admin password age — untested DSRM
#    passwords are the #1 reason an emergency authoritative restore stalls
Get-ADDefaultDomainPasswordPolicy   # not DSRM itself, but confirms you're looking at the right domain
dsmod                                # placeholder — see Fix 3 for the actual DSRM reset command

# 5. Confirm tombstone lifetime (the hard ceiling on how old a restore can be)
$domainDN = (Get-ADDomain).DistinguishedName
Get-ADObject "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$domainDN" `
  -Properties tombstoneLifetime | Select-Object tombstoneLifetime
```

| What you see | What it means |
|---|---|
| Event ID 2095 (USN rollback detected) | The DC's database was restored/reverted outside a supported process (snapshot rollback, improper VM restore) — **stop this DC from replicating immediately**, go to Fix 1 |
| Event ID 1113 / 1115 (invalid USN / database inconsistency) | Same family as 2095 — database is in an unreliable state relative to its own replication history |
| `wbadmin get versions` returns nothing / errors | No valid System State backup exists — you have no safety net; escalate immediately if a restore is needed |
| Last successful backup older than tombstone lifetime (default 180 days) | The backup is **unusable for restore** — restoring it would reintroduce deleted objects and desync the DC beyond repair; go to Fix 4 |
| `ntdsutil` "authoritative restore" needed after accidental bulk deletion (OU, GPO links, group memberships) | Standard authoritative restore procedure — go to Fix 2 |
| DC needs a fresh rebuild instead of restore | Prefer this over restore whenever the DC has no unique data (metadata cleanup + `dcpromo` re-add is safer than an old restore) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
A valid, recent System State backup exists (wbadmin / third-party VSS-aware backup)
  └── Backup age is within tombstone lifetime (default 180 days — hard ceiling)
        └── DSRM local administrator password is known/resettable
              └── DC is booted into Directory Services Restore Mode (safe mode variant)
                    └── ntdsutil authoritative/non-authoritative restore executed correctly
                          └── (if authoritative) USN of restored objects bumped above all other DCs'
                                └── Normal replication resumes — restored data pushed outward, not overwritten
```

Key failure points:
- Backups exist but are stale beyond tombstone lifetime — restoring reintroduces already-purged tombstones, causing lingering-object-style corruption
- DSRM password was never reset/tested and is unknown at the moment it's needed
- A DC is restored from a VM snapshot instead of a proper System State backup — this **causes** USN rollback rather than fixing anything
- Authoritative restore run on the wrong DC, or the USN version increment step skipped — restored objects get silently overwritten by normal replication from other DCs

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Determine what actually happened**
```powershell
Get-WinEvent -LogName "Directory Service" -MaxEvents 200 |
  Where-Object { $_.Id -in 2095, 1113, 1115, 1388, 1988 } |
  Select-Object TimeCreated, Id, Message | Format-List
```
Event 2095 = USN rollback (database reverted). Event 1988 = lingering object detected (different problem — see `Troubleshooting/Replication/AD-Replication-B.md`). Do not conflate the two.

**Step 2 — If USN rollback is suspected, isolate the DC immediately**
```powershell
# Disable outbound and inbound replication on the suspect DC to stop it from
# corrupting the rest of the domain, or poisoning it further
repadmin /options <SuspectDC> +DISABLE_OUTBOUND_REPL +DISABLE_INBOUND_REPL
```
This buys time to investigate without making things worse in either direction.

**Step 3 — Confirm backup validity**
```powershell
wbadmin get versions -backuptarget:<BackupDriveOrShare>
```
Check the backup date against tombstone lifetime. A backup older than tombstone lifetime is not a viable restore source — treat the DC as needing a rebuild, not a restore.

**Step 4 — Confirm DSRM password is usable before rebooting into DSRM**
```powershell
ntdsutil "set dsrm password" "reset password on server <DCName>" quit quit
```
Do this *before* rebooting the DC into DSRM — discovering the DSRM password doesn't work after you're already offline is a common, avoidable delay.

**Step 5 — Decide: restore vs. rebuild**
- If backup is valid (within tombstone lifetime) and the DC holds no unique unreplicated data → restore is appropriate
- If backup is stale, missing, or the DC is otherwise healthy but just lost specific objects (accidental deletion) → prefer a **targeted authoritative restore of just the affected objects**, not a full DC restore
- If the DC itself is unrecoverable and holds no unique data → metadata cleanup + clean re-promotion is safer than any restore

---
## Common Fix Paths

<details><summary>Fix 1 — USN rollback detected (Event 2095) on a live DC</summary>

**Cause:** The DC's NTDS database was reverted to an earlier state outside a supported restore process — almost always a VM snapshot rollback/revert, or a disk-level restore that bypassed `ntdsutil`/System State restore.

```powershell
# Immediately stop this DC from replicating in either direction
repadmin /options <SuspectDC> +DISABLE_OUTBOUND_REPL +DISABLE_INBOUND_REPL

# The DC's database is not trustworthy going forward — the supported remediation
# is to demote and cleanly re-promote it, not to try to "fix" the USN state in place
Uninstall-ADDSDomainController -DemoteOperationMasterRole -Force -LocalAdministratorPassword (Read-Host -AsSecureString)

# If demotion itself fails because the DC is too corrupted, force it and clean up metadata
Uninstall-ADDSDomainController -ForceRemoval -LocalAdministratorPassword (Read-Host -AsSecureString)
# then from a healthy DC:
# ntdsutil > metadata cleanup > (remove the dead DC's server object, as in AD-Replication-A.md Playbook 1)
```

⚠️ Never re-enable replication on a DC that showed Event 2095 without demoting first — that pushes the rolled-back (stale/incorrect) data out to every other DC in the domain.

**Rollback note:** Not reversible in place — the correct "rollback" of a USN rollback event is demotion and clean re-promotion, not an attempt to repair the database.

</details>

<details><summary>Fix 2 — Authoritative restore of specific deleted objects (OU, GPO links, group memberships)</summary>

**Cause:** Objects were deleted accidentally (bulk OU deletion, script error) and need to be restored from the Recycle Bin or from backup, marked authoritative so they don't get re-deleted by replication from other DCs.

```powershell
# Preferred path if AD Recycle Bin is enabled (Server 2008 R2+ forest functional level) —
# no DSRM/authoritative restore needed at all
Get-ADObject -Filter 'isDeleted -eq $true' -IncludeDeletedObjects -Properties * |
  Where-Object { $_.Name -like "*<SearchTerm>*" }

Restore-ADObject -Identity "<ObjectGUID-or-DN-from-above>"

# Only if the Recycle Bin is NOT enabled or the deletion predates the deleted-object
# lifetime, fall back to a full authoritative restore from System State backup:
# 1. Boot the DC into DSRM
# 2. Restore System State from the backup (wbadmin or vendor tool)
# 3. In ntdsutil, mark the specific subtree authoritative — NOT the whole database
ntdsutil "activate instance ntds" "authoritative restore" `
  "restore subtree OU=<OrgUnit>,DC=<domain>,DC=<com>" quit quit
```

**Rollback note:** `Restore-ADObject` from the Recycle Bin is safe and non-destructive to other data. A subtree authoritative restore is scoped and safe if you specify the exact subtree — restoring the entire database authoritatively is far riskier and should only be a last resort (see Fix 4 caveats).

</details>

<details><summary>Fix 3 — DSRM password unknown or untested</summary>

**Cause:** The DSRM local administrator password was set once at `dcpromo` time and never reset or documented — standard practice is to reset it periodically alongside a documented password vault entry.

```powershell
# Reset DSRM password on a specific DC without needing to be booted into DSRM
ntdsutil "set dsrm password" "reset password on server <DCName>" quit quit

# Verify it can actually be used to log in locally the next time DSRM is needed —
# document it in your password vault immediately after resetting
```

**Rollback note:** Safe — resetting the DSRM password has no effect on the running domain or replication.

</details>

<details><summary>Fix 4 — Backup is stale (older than tombstone lifetime) and a restore was requested anyway</summary>

**Cause:** Someone wants to restore from a backup that predates tombstone lifetime. This is unsafe — restored objects that were already tombstoned and purged domain-wide will reappear as **lingering objects**, and the restored DC will be out of sync with legitimate changes made since the backup.

```powershell
# Confirm the backup's age against tombstone lifetime before proceeding
$domainDN = (Get-ADDomain).DistinguishedName
Get-ADObject "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$domainDN" `
  -Properties tombstoneLifetime | Select-Object tombstoneLifetime
```

If the backup is stale: do **not** restore it. Instead, rebuild the DC (demote if still reachable, clean metadata, re-promote from a healthy DC) or, if specific data must be recovered, extract only the needed objects from the stale backup into an isolated lab/offline environment first — never restore a stale backup directly into the live production domain.

**Rollback note:** N/A — this fix path is a decision gate, not an executable change. The point is stopping a destructive action before it happens.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — AD DS Backup/Restore Issue

DC affected: ___________________
Symptom (USN rollback / accidental deletion / DC rebuild needed): ____

wbadmin get versions — last successful backup date: ____________
Tombstone lifetime (days): ____________
Backup age vs. tombstone lifetime: (Within / Exceeds)

Directory Service event log — relevant event IDs seen: ____________
  [ ] 2095 (USN rollback)
  [ ] 1113 / 1115 (invalid USN / DB inconsistency)
  [ ] 1988 (lingering object — different issue, cross-reference AD-Replication-B.md)

DSRM password status: (Known/tested / Unknown / Just reset)
Recycle Bin enabled: (Yes/No)

Steps already attempted:
[ ] Directory Service event log reviewed for 2095/1113/1115
[ ] Outbound/inbound replication disabled on suspect DC (if USN rollback suspected)
[ ] Backup validity confirmed against tombstone lifetime
[ ] DSRM password reset/verified
[ ] Recycle Bin restore attempted (if applicable, before full authoritative restore)
```

---
## 🎓 Learning Pointers

- **USN rollback is not "fixable" — it's a demote-and-rebuild scenario.** Once Event 2095 appears, the DC's replication metadata can no longer be trusted going forward. Don't spend time trying to repair it in place; isolate it from replication and rebuild. [USN and USN rollback](https://learn.microsoft.com/en-us/troubleshoot/windows-server/identity/usn-and-usn-rollback)
- **Tombstone lifetime isn't just a replication concept — it's a hard ceiling on backup usability.** A System State backup older than tombstone lifetime (default 180 days) is not a valid restore source; restoring it reintroduces already-purged tombstones as lingering objects. [Back up and restore AD DS](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/ad-forest-recovery-backing-up-ad)
- **The AD Recycle Bin should almost always be your first restore path, not `ntdsutil` authoritative restore.** If it's enabled and the deletion is within the deleted-object lifetime, `Restore-ADObject` is faster, safer, and doesn't require DSRM at all.
- **DSRM password should be treated like a break-glass credential — reset and documented on a schedule, not discovered under pressure.** The worst time to learn the DSRM password doesn't work is mid-incident with a DC already offline.
- **Authoritative restore should be scoped to the smallest subtree possible.** A full-database authoritative restore is a last resort — scoping to the specific OU/subtree that was actually deleted avoids re-authoritative-izing unrelated data that's fine on other DCs.
- Community resource: Microsoft's own AD Forest Recovery guidance is the canonical reference for a full forest-loss scenario (not just single-DC issues) — worth a first read even if you never expect to need it, since forest recovery runbooks age out of institutional memory fast.
