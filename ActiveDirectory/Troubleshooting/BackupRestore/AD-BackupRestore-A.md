# AD DS Backup & Restore — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- System State backup strategy and validation for Active Directory Domain Controllers (Windows Server 2016–2022)
- Authoritative vs. non-authoritative restore of the NTDS database
- USN rollback: detection, cause, and correct remediation
- DSRM (Directory Services Restore Mode) — password management and use
- AD Recycle Bin as the preferred first-line object-recovery mechanism
- Single-DC and single-domain recovery scenarios

**Out of scope:**
- Full forest recovery (all DCs lost simultaneously) — this is a materially different, much larger procedure; see the Microsoft AD Forest Recovery guide linked in Learning Pointers
- SYSVOL backup/restore — covered under `DFS/Troubleshooting/Replication/` (SYSVOL is DFSR-replicated, not part of the NTDS System State restore path in the same way)
- Inter-DC replication health outside of a restore's impact on it — see `Troubleshooting/Replication/AD-Replication-A.md`
- Entra Connect / hybrid sync state after a restore — see `EntraID/Troubleshooting/Connect-Sync-A.md`

**Assumptions:**
- You have Domain Admin or delegated backup/restore rights
- A supported, VSS-aware backup tool is in use (`wbadmin`, or a third-party AD-aware backup product)
- At least 2 DCs exist (single-DC domains have no restore safety net beyond backup — treat this as a design gap, not a break/fix issue)

---
## How It Works

<details><summary>Full architecture — backup validity, restore types, and USN rollback internals</summary>

### What a System State Backup Actually Contains

A Windows Server System State backup of a Domain Controller includes the NTDS database (`ntds.dit`), the registry, the boot files, SYSVOL (as a filesystem copy, separate from live DFSR replication), and the DC's certificate services database if applicable. Critically, it is captured via VSS (Volume Shadow Copy Service) using an AD-aware writer, which ensures database consistency at the moment of the snapshot — this is why System State backup/restore is supported, while raw disk image or VM-level snapshot backup of a live DC generally is **not**, unless the hypervisor explicitly integrates with the VSS writer for AD (most do not by default, and Microsoft's official guidance has historically discouraged VM snapshot rollback of DCs entirely).

### Non-Authoritative Restore (the default)

When you restore System State to a DC and boot it normally, the restored DC treats its own data as **out of date** relative to the rest of the domain. It replicates in from its partners after coming back online, pulling any changes made since the backup was taken. This is the correct choice when: the DC itself was lost/corrupted and needs rebuilding, but no accidental *data* deletion needs to be recovered — the rest of the domain still has the correct, current state.

### Authoritative Restore

When specific objects were deleted (an OU, a set of group memberships, GPO links) and you need those specific objects to "win" over the current (deleted) state on every other DC, a non-authoritative restore is not enough — normal replication would simply re-delete the restored objects once the DC syncs with its partners. An **authoritative restore** (`ntdsutil` → `authoritative restore` → `restore subtree`/`restore object`) increments the version number of the restored objects' attributes by a large amount (100,000 per replication cycle by default), which forces every other DC to treat the restored version as newer and accept it during replication — effectively "undeleting" the objects domain-wide.

Scoping matters enormously here: authoritative restore should target the **smallest subtree or object set** that was actually affected. A full-database authoritative restore is rarely correct — it would authoritatively reintroduce old values for everything in the backup, including data that's still correct and current on other DCs.

### USN Rollback — What It Is and Why It's Different From a "Bad Restore"

Every DC maintains a local Update Sequence Number (USN) that increments with every write, and an `invocationID` (a GUID identifying "this instance" of the database) that changes whenever the database is restored from backup through a supported process. The combination of `invocationID` + USN is how other DCs track "what have I already received from this DC."

**USN rollback** happens when a DC's database is reverted to an earlier state **without** going through a supported restore process — most commonly, a VM snapshot revert, or a disk-level restore of just the database file. In this case, the `invocationID` does *not* change, but the USN counter resets backward. Other DCs, which have already recorded having received changes up to the DC's *higher* pre-revert USN, now see the same `invocationID` reporting a *lower* USN and — critically — will assume they've already seen everything up to that point and up to the previously recorded high-water mark, silently **skipping** replication of changes that actually never arrived at the reverted DC. This causes silent, hard-to-detect data divergence rather than an obvious error, which is why Windows Server (2003 SP1+) actively detects this condition (Event ID 2095) and, since that update, disables the affected DC's outbound replication automatically as a safety measure.

The correct remediation for USN rollback is **not** a restore of any kind — the DC's replication identity is no longer trustworthy. The supported fix is demotion (clean if possible, forced if not) followed by metadata cleanup and a fresh promotion.

### DSRM (Directory Services Restore Mode)

A special boot mode for a DC where the NTDS database is offline and the DC boots essentially as a standalone server, authenticating locally against a separate SAM-like database with its own local Administrator account — the **DSRM password**, set at `dcpromo`/`Install-ADDSDomainController` time and not automatically kept in sync with anything afterward. This mode is required for: offline defragmentation of `ntds.dit`, non-authoritative restore via some third-party tools, and authoritative restore via `ntdsutil`. Because it's rarely used, the DSRM password is one of the most commonly "lost" credentials in an AD environment — Microsoft recommends resetting it on a schedule (e.g., alongside other privileged credential rotations) specifically so it's never discovered to be wrong during an actual emergency.

### AD Recycle Bin

Since forest functional level 2008 R2, deleted objects retain **all** their attributes (not just a subset, as with the older tombstone-only model) for a configurable "deleted object lifetime" (defaults to matching tombstone lifetime). `Restore-ADObject` can bring back a deleted object with full fidelity during this window, with no DSRM, no `ntdsutil`, and no authoritative restore mechanics at all. This should be the first thing checked for any "objects got deleted" scenario before reaching for backup-based restore.

</details>

---
## Dependency Stack

```
VSS-aware, AD-integrated backup tool (wbadmin or supported third-party)
  └── Backup captured via System State (not raw disk/VM snapshot of a live DC)
        └── Backup age within tombstone lifetime (default 180 days — hard usability ceiling)
              └── DSRM password known/resettable for the target DC
                    └── (authoritative restore only) DC booted into DSRM
                          └── ntdsutil restore executed (authoritative or non-authoritative)
                                └── (authoritative only) version numbers incremented on restored objects
                                      └── DC rejoins normal replication
                                            └── Restored/incremented objects propagate outward via USN exchange
                                                  └── (separate system) SYSVOL state reconciled via DFSR — see DFS/ runbooks
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Event ID 2095 in Directory Service log | USN rollback — DC was reverted outside a supported restore process (VM snapshot revert is the classic cause) | `repadmin /options <DC>` — confirm `DISABLE_OUTBOUND_REPL` was auto-set; do not clear it before rebuilding |
| Deleted objects silently reappear domain-wide after being deleted | Restored objects were not made authoritative, or version increment step was skipped | `repadmin /showobjmeta` on the object to check version history |
| Same objects keep disappearing after every restore attempt | Authoritative restore scope was too broad or too narrow, or was run before the DC finished a full non-authoritative sync first | Confirm restore order: non-authoritative sync to current state, *then* scoped authoritative restore of just the missing subtree |
| `wbadmin get versions` shows no backups, or errors | Backup job never configured, misconfigured, or failing silently | Check Task Scheduler / backup software job history and VSS writer health (`vssadmin list writers`) |
| Restore appears to succeed but object is still missing after replication | Authoritative restore subtree/object path was wrong (typo'd DN, wrong OU) | Re-run `ntdsutil` restore with the exact DN confirmed via a test lookup on a DC that still has the object in AD Recycle Bin |
| `Restore-ADObject` returns "cannot find object" | Deleted-object lifetime has expired, or AD Recycle Bin was never enabled | Check `Get-ADOptionalFeature "Recycle Bin Feature"` and the object's original deletion date vs. lifetime |
| DC won't boot into DSRM / DSRM password rejected | Password was never set correctly, reset on the wrong DC, or typed with the wrong keyboard layout at the safe-mode logon screen | Reset via `ntdsutil "set dsrm password"` from a *healthy* DC while the target is still online, before rebooting it |
| VSS writer for NTDS shows an error state | Backup will fail or produce an inconsistent snapshot | `vssadmin list writers` — look for "NTDS" writer state; restart `NTDS` service or the DC itself if stuck |
| Restore brings back a GPO link but not the GPO content itself | GPO content lives in SYSVOL (DFSR), not just the AD object — the AD-side GPO container and the SYSVOL-side GPO folder must both be restored/consistent | Cross-reference `DFS/Troubleshooting/Replication/Replication-A.md` |

---
## Validation Steps

**Step 1 — Confirm backup exists, is recent, and is VSS-consistent**
```powershell
wbadmin get versions
vssadmin list writers
```
Expected: at least one backup within your RPO target; NTDS writer shows "No error" / stable state.

**Step 2 — Confirm backup age against tombstone lifetime**
```powershell
$domainDN = (Get-ADDomain).DistinguishedName
Get-ADObject "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$domainDN" `
  -Properties tombstoneLifetime | Select-Object tombstoneLifetime
```
Expected: most recent valid backup is well within this window — treat anything past ~75% of tombstone lifetime as a signal to tighten backup frequency or retention review.

**Step 3 — Confirm no existing USN rollback indicators before assuming backups are the issue**
```powershell
Get-WinEvent -LogName "Directory Service" -MaxEvents 500 |
  Where-Object { $_.Id -in 2095, 1113, 1115 } |
  Select-Object TimeCreated, Id, DCName -ErrorAction SilentlyContinue
```
Expected: none. Any hit here changes the remediation path entirely (Playbook 1, not a restore).

**Step 4 — Confirm AD Recycle Bin is enabled**
```powershell
Get-ADOptionalFeature -Filter 'Name -eq "Recycle Bin Feature"' | Select-Object Name, EnabledScopes
```
Expected: `EnabledScopes` populated with the domain/forest DN. If empty, Recycle Bin is not enabled — enabling it is one-way (cannot be disabled once turned on) but should be done proactively, not reactively.

**Step 5 — Confirm DSRM password is current/testable**
```powershell
ntdsutil "set dsrm password" "reset password on server <DCName>" quit quit
```
Running this (even just to confirm it completes) proves the mechanism works; document the new value immediately in your credential vault.

**Step 6 — Confirm replication is currently healthy before undertaking any restore**
```powershell
repadmin /replsummary
```
A restore performed while replication is already unhealthy compounds the problem — resolve replication health first (see `Troubleshooting/Replication/AD-Replication-A.md`) unless the restore itself is the fix for the replication issue (e.g., recovering from USN rollback).

**Step 7 — After any restore, verify object version and replication propagation**
```powershell
repadmin /showobjmeta <DC> "<Restored-Object-DN>"
repadmin /replsummary
```
Confirm the restored object's version number is higher than what other DCs previously held, and that replication summary shows no new failures post-restore.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Triage the Actual Failure Mode
1. Rule out USN rollback first (Event 2095/1113/1115) — this changes everything downstream
2. Determine if this is "lost objects" (authoritative restore candidate) vs. "lost DC" (non-authoritative restore or rebuild candidate)
3. Check whether AD Recycle Bin can solve it without touching backup/restore mechanics at all

### Phase 2 — Backup Validity Assessment
1. Confirm a usable backup exists and is within tombstone lifetime
2. If no valid backup exists and objects were deleted beyond Recycle Bin's lifetime, this becomes a **data loss** conversation, not a restore procedure — escalate expectations accordingly
3. If the DC itself is unrecoverable and holds no unique data, prefer rebuild over restore

### Phase 3 — Execute the Correct Restore Type
1. Non-authoritative: restore System State, boot normally, let replication catch the DC up
2. Authoritative: restore System State (or use an already-current DC), boot to DSRM, run scoped `ntdsutil` authoritative restore on the minimum subtree/object set
3. USN rollback: do not restore at all — demote and rebuild (see Playbook 1)

### Phase 4 — Post-Restore Verification
1. Confirm object version numbers via `repadmin /showobjmeta`
2. Confirm domain-wide replication propagated the restored state (`repadmin /replsummary`, spot-check on a second DC)
3. If SYSVOL-linked objects (GPOs) were involved, verify SYSVOL-side content matches (see `DFS/` runbooks)
4. Confirm no new lingering-object indicators appeared as a side effect (Event 1988)

### Phase 5 — Close the Loop
1. Document what was restored, why, and the authoritative-restore scope used
2. Review whether the root cause (accidental deletion, backup job failure, unsupported VM snapshot use) needs a process fix, not just a technical one
3. If DSRM password was reset during this incident, confirm it's vaulted

---
## Remediation Playbooks

<details><summary>Playbook 1 — Recover from USN rollback via demote-and-rebuild</summary>

**Scenario:** Event 2095 confirmed. The DC's replication metadata is no longer trustworthy.

**Step 1 — Confirm outbound replication was auto-disabled (or disable manually)**
```powershell
repadmin /options <SuspectDC>
# If DISABLE_OUTBOUND_REPL is not already set:
repadmin /options <SuspectDC> +DISABLE_OUTBOUND_REPL +DISABLE_INBOUND_REPL
```

**Step 2 — Demote cleanly if the DC is still functional enough to do so**
```powershell
Uninstall-ADDSDomainController -LocalAdministratorPassword (Read-Host -AsSecureString)
```

**Step 3 — If clean demotion fails, force removal and clean up metadata from a healthy DC**
```powershell
Uninstall-ADDSDomainController -ForceRemoval -LocalAdministratorPassword (Read-Host -AsSecureString)
# From a healthy DC:
ntdsutil "metadata cleanup" "connections" "connect to server <HealthyDC>" quit `
  "select operation target" "list domains" "select domain <n>" `
  "list sites" "select site <n>" "list servers in site" "select server <n>" quit `
  "remove selected server" quit quit
```

**Step 4 — Re-promote as a fresh DC once metadata is confirmed clean**
```powershell
Get-ADDomainController -Filter * | Select-Object HostName   # confirm the old entry is gone
Install-ADDSDomainController -DomainName "<domain>" -Credential (Get-Credential)
```

**Rollback note:** Not reversible in the traditional sense — this playbook *is* the recovery. Never attempt to re-enable replication on the pre-demotion DC state.

</details>

<details><summary>Playbook 2 — Scoped authoritative restore of an accidentally deleted OU</summary>

**Scenario:** An OU containing users/computers/groups was deleted (script error, fat-fingered console action) and needs to come back exactly as it was, overriding the current (deleted) state on every DC.

**Step 1 — Check AD Recycle Bin first**
```powershell
Get-ADObject -Filter 'isDeleted -eq $true' -IncludeDeletedObjects -SearchBase (Get-ADDomain).DeletedObjectsContainer -Properties * |
  Where-Object { $_.LastKnownParent -like "*<ParentOU>*" }
```
If found and within the deleted-object lifetime, restore via `Restore-ADObject` and skip the rest of this playbook entirely.

**Step 2 — If Recycle Bin can't cover it, boot a DC into DSRM**
```powershell
shutdown /r /o /t 0
# select "Directory Services Restore Mode" from the boot menu, log in with the DSRM local admin account
```

**Step 3 — Restore System State from the most recent valid backup**
```powershell
wbadmin start systemstaterecovery -version:<VersionIdentifier> -backuptarget:<BackupLocation> -quiet
```

**Step 4 — Mark only the affected subtree authoritative**
```powershell
ntdsutil "activate instance ntds" "authoritative restore" `
  "restore subtree OU=<DeletedOU>,DC=<domain>,DC=<com>" quit quit
```

**Step 5 — Reboot normally and verify propagation**
```powershell
repadmin /showobjmeta <DC> "OU=<DeletedOU>,DC=<domain>,DC=<com>"
repadmin /replsummary
```

**Rollback note:** Scoped to the named subtree only — objects outside it are unaffected. If the wrong subtree was restored, repeat the process scoped correctly; the incorrect restore does not corrupt unrelated data.

</details>

<details><summary>Playbook 3 — Non-authoritative restore to rebuild a corrupted-but-recoverable DC</summary>

**Scenario:** A DC's database is corrupted (disk error, improper shutdown) but the DC itself (hardware/VM) is otherwise fine, and no authoritative data recovery is needed — just get this DC healthy and current again.

**Step 1 — Boot into DSRM and restore System State**
```powershell
wbadmin start systemstaterecovery -version:<VersionIdentifier> -backuptarget:<BackupLocation> -quiet
```

**Step 2 — Reboot normally (non-authoritative — do NOT run ntdsutil authoritative restore)**
The DC will start with the backup's data but immediately treat it as stale relative to the domain.

**Step 3 — Let replication catch it up, then verify**
```powershell
repadmin /replsummary
repadmin /showrepl <DC> /verbose
```
Expected: the restored DC pulls in every change made since the backup was taken, converging to current domain state.

**Rollback note:** Safe by design — non-authoritative restore is exactly the "let normal replication win" path, so there's no domain-wide data risk from choosing this over an authoritative restore.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  AD DS Backup/Restore Evidence Collector
.NOTES     Run from any Domain Controller with Domain Admin rights
#>

$reportPath = "C:\Temp\ADBackupRestoreEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== Backup History ===" | Out-File "$reportPath\01_BackupVersions.txt"
wbadmin get versions | Out-File "$reportPath\01_BackupVersions.txt" -Append

"=== VSS Writer State ===" | Out-File "$reportPath\02_VSSWriters.txt"
vssadmin list writers | Out-File "$reportPath\02_VSSWriters.txt" -Append

"=== USN Rollback / DB Consistency Events ===" | Out-File "$reportPath\03_USNEvents.txt"
Get-WinEvent -LogName "Directory Service" -MaxEvents 500 |
  Where-Object { $_.Id -in 2095, 1113, 1115, 1988 } |
  Select-Object TimeCreated, Id, Message |
  Format-List | Out-File "$reportPath\03_USNEvents.txt" -Append

"=== Tombstone Lifetime ===" | Out-File "$reportPath\04_Tombstone.txt"
$domainDN = (Get-ADDomain).DistinguishedName
Get-ADObject "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$domainDN" `
  -Properties tombstoneLifetime | Format-List | Out-File "$reportPath\04_Tombstone.txt" -Append

"=== AD Recycle Bin Status ===" | Out-File "$reportPath\05_RecycleBin.txt"
Get-ADOptionalFeature -Filter 'Name -eq "Recycle Bin Feature"' |
  Format-List | Out-File "$reportPath\05_RecycleBin.txt" -Append

"=== Replication Summary (post-incident) ===" | Out-File "$reportPath\06_ReplSummary.txt"
repadmin /replsummary | Out-File "$reportPath\06_ReplSummary.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| List backup versions | `wbadmin get versions` |
| Start System State recovery | `wbadmin start systemstaterecovery -version:<ID> -backuptarget:<Path> -quiet` |
| Check VSS writer health | `vssadmin list writers` |
| Reset DSRM password remotely | `ntdsutil "set dsrm password" "reset password on server <DC>" quit quit` |
| Enter authoritative restore mode | `ntdsutil "activate instance ntds" "authoritative restore" quit quit` |
| Authoritative restore of a subtree | `ntdsutil "authoritative restore" "restore subtree <DN>" quit` |
| Check AD Recycle Bin status | `Get-ADOptionalFeature -Filter 'Name -eq "Recycle Bin Feature"'` |
| Enable AD Recycle Bin (one-way) | `Enable-ADOptionalFeature "Recycle Bin Feature" -Scope ForestOrConfigurationSet -Target <Forest>` |
| Restore a deleted object | `Restore-ADObject -Identity <ObjectGUID>` |
| Check tombstone lifetime | `Get-ADObject "CN=Directory Service,..." -Properties tombstoneLifetime` |
| Check for USN rollback events | `Get-WinEvent -LogName "Directory Service" \| Where-Object Id -eq 2095` |
| Check replication options flags | `repadmin /options <DC>` |
| Disable a DC's replication (isolate) | `repadmin /options <DC> +DISABLE_OUTBOUND_REPL +DISABLE_INBOUND_REPL` |
| Check object version/metadata | `repadmin /showobjmeta <DC> "<Object-DN>"` |
| Demote a DC | `Uninstall-ADDSDomainController` |
| Force-remove an unreachable DC | `Uninstall-ADDSDomainController -ForceRemoval` |

---
## 🎓 Learning Pointers

- **A VM snapshot is not a supported backup mechanism for a live Domain Controller unless the hypervisor explicitly integrates with the AD VSS writer.** Reverting a DC to an old snapshot is one of the most common real-world causes of USN rollback — this is an operational policy issue as much as a technical one; make sure whoever manages the hypervisor layer knows this. [USN and USN rollback](https://learn.microsoft.com/en-us/troubleshoot/windows-server/identity/usn-and-usn-rollback)
- **Authoritative restore scope should always be the narrowest subtree that covers the actual loss.** A full-database authoritative restore reintroduces old values for everything in the backup, not just what was deleted — this is a common over-correction that creates new problems. [Perform an authoritative restore](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/ad-forest-recovery-authoritative-restore)
- **AD Recycle Bin should be enabled proactively, not discovered as missing during an incident.** Enabling it is a one-way, low-risk operation once the forest is at the 2008 R2 functional level or higher — there's rarely a good reason to leave it off. [AD Recycle Bin overview](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/get-started/adac/introduction-to-active-directory-administrative-center-enhancements--level-100-)
- **DSRM password rot is a real, recurring incident cause.** Because DSRM is rarely used, its password is rarely tested — build it into whatever privileged-credential-rotation cadence you already run for other break-glass accounts.
- **Backup age vs. tombstone lifetime is the single most important number to know before any restore conversation starts.** A technically-successful backup that's simply too old to safely restore is functionally the same as having no backup at all — worse, in fact, since restoring it can cause active harm (lingering objects) instead of just failing cleanly.
- **This runbook covers single-DC/single-domain recovery only.** A scenario where every DC in a domain or forest is lost simultaneously requires the full Microsoft AD Forest Recovery procedure, which is materially different (media creation order, sequential DC recovery, forest-wide password reset) — do not attempt to improvise a forest recovery from single-DC restore steps. [AD Forest Recovery Guide](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/ad-forest-recovery-guide)
