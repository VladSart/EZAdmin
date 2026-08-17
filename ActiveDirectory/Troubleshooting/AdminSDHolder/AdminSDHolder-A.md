# AdminSDHolder / SDProp — Reference Runbook (Mode A: Deep Dive)
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
- The `AdminSDHolder` template object and the `SDProp` process that enforces it against protected accounts and groups
- The full current (2025+) protected groups list, including the newer Enterprise Key Admins/Key Admins groups
- The `adminCount` attribute and inheritance-disabling behavior, including why `adminCount` is never automatically cleared
- Changing the SDProp interval, forcing an on-demand run, and the security/performance trade-offs of each
- Orphaned/stale `adminCount=1` detection and remediation as an AD hygiene practice
- Customizing the `AdminSDHolder` ACL template itself (domain-wide hardening or loosening of protected-object permissions)

**Out of scope:**
- Fine-Grained Password Policies and PSO precedence — a different protection mechanism entirely, targeting password settings rather than object ACLs (see `ActiveDirectory/Troubleshooting/FineGrainedPasswordPolicies/FGPP-A.md`)
- Kerberos delegation and the `AccountNotDelegated`/Protected Users hardening controls — a separate, KDC-evaluated protection layer for Tier-0 accounts, not an ACL-stamping mechanism (see `ActiveDirectory/Troubleshooting/KerberosDelegation/Delegation-A.md`)
- General AD object permission/ACL troubleshooting unrelated to protected groups — standard delegation and inheritance concepts apply the same way to any AD object; this topic covers only the specific override mechanism protected objects are subject to
- Tiered administration / Enterprise Access Model design — AdminSDHolder protects a fixed, built-in group list; it is not a substitute for or equivalent to a full tiering model, though it is a foundational piece of Tier-0 hygiene
- Backup/restore of accidentally-deleted protected accounts — see `ActiveDirectory/Troubleshooting/BackupRestore/AD-BackupRestore-A.md` for AD Recycle Bin and authoritative restore mechanics

**Assumptions:**
- You have rights to read `nTSecurityDescriptor`, `adminCount`, and group membership domain-wide, and Domain Admins/Enterprise Admins rights for anything that modifies the `AdminSDHolder` object itself
- The `ActiveDirectory` PowerShell module is available on the host running diagnostics
- Domain functional level is not a gate for this feature — AdminSDHolder/SDProp has existed since Windows 2000 and applies identically regardless of current functional level

---
## How It Works

<details><summary>Full architecture — the template object, the enforcement process, and the design rationale behind adminCount</summary>

### The AdminSDHolder Object

`AdminSDHolder` is a single object automatically present in every AD domain at `CN=AdminSDHolder,CN=System,DC=<domain>,DC=<domain>`. Its access control list (ACL) is not applied to itself in any special way — its sole purpose is to act as a **permissions template**: whatever security descriptor (SD) is configured on this object is the SD that gets stamped onto every protected account and group in the domain. By default, the `Domain Admins` group owns the object (not `Administrators`, which owns most other domain objects), though members of `Administrators` or `Enterprise Admins` can take ownership if needed. Inheritance is disabled on `AdminSDHolder` itself, specifically so that permission changes on its parent container (`CN=System`) never silently alter the template.

### The Protected Groups List

As of the current Windows Server documentation (2025), the following groups (and their members, evaluated transitively through nested membership) are protected:

Account Operators, Administrator, Administrators, Backup Operators, Domain Admins, Domain Controllers, Enterprise Admins, Enterprise Key Admins, Key Admins, Krbtgt, Print Operators, Read-only Domain Controllers, Replicator, Schema Admins, Server Operators.

This list is fixed by Microsoft and not intended to be edited through supported, documented means for the vast majority of environments — the underlying group set is compiled into the AdminSDHolder enforcement logic (`dssec.dat`/`adminsdholder.dll`-level behavior), and while advanced customization exists in specialized deployments, it requires editing files on every DC and is explicitly a "know exactly what you're doing" operation, not a routine administrative task.

### SDProp — The Enforcement Process

SDProp ("Security Descriptor Propagator") is the background process that actually does the work. It runs **only on the domain controller holding the PDC Emulator (PDCe) FSMO role**, on a fixed interval — 60 minutes by default. On each run, SDProp:

1. Transitively expands membership of every protected group, including nested groups, to build the complete current list of protected principals for the domain
2. For each protected principal, compares its current security descriptor against the `AdminSDHolder` object's security descriptor
3. If they differ, **overwrites** the protected principal's ACL to match the template exactly, sets `adminCount = 1`, and disables ACL inheritance on the object (so future changes to its parent OU's permissions never flow down to it)
4. If they already match, the object is left untouched — notably, this means an object that happens to already have matching permissions before ever being evaluated may never get `adminCount` set at all, which is one reason `adminCount` alone is an imperfect indicator (see below)

Because this only runs on the PDCe, any delay in this DC being reachable, healthy, or having recently taken over the role after an FSMO transfer/seizure directly delays protection convergence for the *entire* domain — there is no distributed or per-DC fallback for this specific process.

### Why adminCount Is Not the Full Story

A common misconception is that `adminCount = 1` is itself the trigger SDProp checks, or that it can be relied upon as a complete list of "currently protected" accounts. In reality, per Microsoft's own engineering clarification, protection determination is based on **transitively expanding current protected-group membership** at each SDProp run — `adminCount` is a side effect that gets stamped when the SD needs correcting, not the authoritative signal. Historically, `adminCount` was intended purely as a performance optimization (avoiding a full re-evaluation of every object), but from Windows Server 2003 onward this optimization alone has not been sufficient to fully drive the AdminSDHolder logic in isolation. Practically, this means: an account can currently be `adminCount=1` and no longer be a member of any protected group (orphaned), and conversely — in rare cases — a very recently added protected member may not yet show `adminCount=1` if its SD happened to already match the template.

### Why adminCount Is Never Automatically Cleared

This is the single most consequential design decision in this system for day-to-day operations. When an account is removed from a protected group, Microsoft's SDProp logic **does not** reset `adminCount` back to 0 or re-enable inheritance. This was a deliberate choice validated with customers during Windows 2000's design: the assumption is that an account which held elevated, protected-group membership at some point could have been used to plant a backdoor (a scheduled task, a service, a modified ACL elsewhere, delegated rights granted while privileged) before being de-admined. Automatically restoring "normal" inherited permissions and clearing the flag would remove the one signal indicating "this account used to be privileged and deserves a closer look" — the expectation baked into the design is that such an account should be reviewed, and likely disabled or deleted, rather than quietly returned to routine status. In practice, most organizations don't delete these accounts; they keep using them, which is exactly why orphaned `adminCount=1` accumulates over time and becomes a recurring audit finding.

### Changing the SDProp Interval

The 60-minute default is controlled by the `AdminSDProtectFrequency` DWORD value at `HKLM\SYSTEM\CurrentControlSet\Services\NTDS\Parameters` on the PDCe, accepting values from 60 to 7200 seconds (1 minute to 2 hours). Reducing this in production is explicitly discouraged by Microsoft — more frequent full protected-membership expansion and ACL comparison increases LSASS processing load on the PDCe, with impact scaling with the number of protected objects in the domain. The supported way to validate a change immediately, without touching the schedule, is to trigger a single on-demand run via the `runProtectAdminGroupsTask` rootDSE operational attribute (Ldp.exe or an ADSI call against the PDCe) — this runs the task once, immediately, with no effect on the ongoing scheduled cadence.

</details>

---
## Dependency Stack

```
PDC Emulator FSMO role — SDProp evaluates ONLY here, no distributed fallback
  └── AdminSDProtectFrequency (default 3600s / 60 min) governs the scheduled interval
        └── On each run: transitively expand membership of all protected groups
              (Domain Admins, Enterprise Admins, Administrators, Schema Admins,
               Account/Backup/Print/Server Operators, Replicator, Krbtgt,
               Domain Controllers, Read-only Domain Controllers, Enterprise/Key Admins)
                └── For each resolved protected principal:
                      compare current SD against AdminSDHolder object's SD (the template)
                        ├── MATCH  → object left untouched (adminCount may stay unset)
                        └── MISMATCH → SD overwritten to match template
                              ├── adminCount attribute set to 1
                              └── ACL inheritance disabled (AreAccessRulesProtected = True)
                                    └── Parent OU delegation no longer flows to this object,
                                        from this point forward, regardless of future OU changes
  └── Standard AD replication then carries the corrected SD/adminCount to every other DC
        (this is normal multi-master replication — no special mechanism beyond it)

  SEPARATE, PERMANENT CONDITION once adminCount=1 is set:
    Removal from the protected group does NOT clear adminCount or re-enable inheritance
      └── Object remains in this "orphaned protected" state indefinitely until
          MANUALLY corrected (Set-ADUser -Clear adminCount + re-enable inheritance)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| A manually-applied ACL/permission change on a Domain Admins/Administrators member disappears within roughly an hour | SDProp reverted it to match the `AdminSDHolder` template on its next scheduled cycle | Compare `whenChanged` on the object against the last SDProp cycle time; confirm `adminCount = 1` |
| An account that hasn't been in a privileged group for months still shows unusual permission behavior or won't inherit from its OU | Orphaned `adminCount = 1` — the account left the protected group, but the flag and disabled inheritance were never cleared | `Get-ADUser -Properties adminCount, MemberOf` cross-referenced against current (transitive) protected-group membership |
| A security assessment tool (PingCastle, Purple Knight, BloodHound) flags a list of stale `adminCount=1` objects | Same orphaned-protection condition, surfaced in bulk as a hygiene finding | Run a domain-wide `(adminCount=1)` LDAP filter and cross-reference against current membership (see audit script) |
| A delegated OU admin's rights (correctly configured via the Delegation of Control wizard) silently don't apply to one specific user/group in that OU | That object has inheritance disabled because it is (or was) AdminSDHolder-protected | `(Get-Acl "AD:\<DN>").AreAccessRulesProtected` |
| Permission changes to an entire security group (not an individual user) keep reverting | The group itself is on the protected list (e.g., `Domain Admins`, `Schema Admins`) — same mechanism applies to groups, not just user accounts | Confirm the group name against the current protected groups list |
| A change is expected to apply domain-wide to every privileged account but only shows up on some of them | SDProp only runs on the PDCe; a recent FSMO transfer/seizure, or the PDCe having been unreachable, delays convergence — not a partial/random failure | `netdom query fsmo` + confirm PDCe health and recent uptime |
| An account was very recently added to a protected group and doesn't yet show `adminCount = 1` | Expected — SDProp hasn't run its next cycle yet (up to 60 minutes by default), or the account's SD already happened to match the template | Force an on-demand SDProp run to confirm rather than waiting, or re-check after the next scheduled interval |
| Custom `AdminSDHolder` template ACL changes aren't reflected on protected accounts yet | Same PDCe-only, interval-bound propagation — template changes don't apply instantly either | Force SDProp on-demand (`runProtectAdminGroupsTask`), or wait for the next cycle |

---
## Validation Steps

**Step 1 — Build the authoritative current protected-principal set**
```powershell
$protectedGroups = "Account Operators","Administrators","Backup Operators","Domain Admins",
  "Domain Controllers","Enterprise Admins","Enterprise Key Admins","Key Admins","Print Operators",
  "Read-only Domain Controllers","Replicator","Schema Admins","Server Operators"
$protectedMembers = foreach ($g in $protectedGroups) {
  Get-ADGroupMember -Identity $g -Recursive -ErrorAction SilentlyContinue
}
```
Expected: a de-duplicated set representing every principal SDProp currently considers protected — this is the ground truth to compare `adminCount` against, not the reverse.

**Step 2 — Cross-reference against every object currently flagged adminCount=1**
```powershell
Get-ADObject -LDAPFilter "(adminCount=1)" -Properties Name, ObjectClass, adminCount, whenChanged
```
Expected: every result here should also appear in Step 1's set. Any that don't are orphaned/stale.

**Step 3 — Confirm PDCe identity and reachability**
```powershell
$pdce = (Get-ADDomain).PDCEmulator
Test-Connection -ComputerName $pdce -Count 2 -Quiet
```
Expected: reachable. If not, SDProp convergence is stalled domain-wide until it's healthy.

**Step 4 — Inspect the AdminSDHolder template object's own security descriptor**
```powershell
$domainDN = (Get-ADDomain).DistinguishedName
Get-Acl "AD:\CN=AdminSDHolder,CN=System,$domainDN" | Select-Object -ExpandProperty Access
```
Expected: this is the exact ACL every protected object will be forced to match on the next SDProp cycle — review before assuming a downstream object's permissions are "wrong."

**Step 5 — Verify inheritance state for a specific suspect object**
```powershell
(Get-Acl "AD:\<object-DN>").AreAccessRulesProtected
```
Expected: `True` for anything currently or historically protected; `False` for a normal object inheriting from its OU.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Confirm the Mechanism, Not the Symptom
1. Before investigating a "permissions reverted" or "delegation not working" report as a bug, check `adminCount` and transitive protected-group membership first
2. If `adminCount = 1` and the account is genuinely still protected, this is expected behavior — redirect to the correct remediation (Fix 1/Playbook 4), not a workaround attempt

### Phase 2 — Distinguish Current Protection from Orphaned Protection
1. Build the current protected-membership set (transitive) and compare against every `adminCount=1` object
2. Anything with `adminCount=1` but no current membership is orphaned — this determines whether the fix is "accept the mechanism" or "clean up stale state"

### Phase 3 — Validate the PDCe Path
1. Confirm the current PDC Emulator and its health/reachability — this is the single point of evaluation for the entire mechanism
2. If a recent FSMO transfer or seizure occurred, expect a delay before the new PDCe's first SDProp cycle catches up domain-wide

### Phase 4 — Remediate
1. For orphaned `adminCount=1`: clear the attribute and re-enable inheritance (Remediation Playbook 1)
2. For a needed domain-wide permission change on protected objects: modify the `AdminSDHolder` template itself, not individual objects (Remediation Playbook 4)
3. For urgent validation: force an on-demand SDProp run rather than waiting for the schedule (Remediation Playbook 2)

### Phase 5 — Prevent Recurrence
1. Schedule periodic orphaned-`adminCount` audits (see the audit script) as part of routine AD hygiene, not just reactive troubleshooting
2. Document any intentional `AdminSDHolder` template customization clearly, since its effects are domain-wide and easy to forget the origin of months later

---
## Remediation Playbooks

<details><summary>Playbook 1 — Domain-wide cleanup of orphaned adminCount=1 accounts</summary>

**Scenario:** A security assessment or routine audit surfaces a list of accounts with `adminCount=1` that are no longer members of any protected group.

**Step 1 — Build ground truth: current protected-group membership, transitively**
```powershell
$protectedGroups = "Account Operators","Administrators","Backup Operators","Domain Admins",
  "Domain Controllers","Enterprise Admins","Enterprise Key Admins","Key Admins","Print Operators",
  "Read-only Domain Controllers","Replicator","Schema Admins","Server Operators"
$currentMembers = (foreach ($g in $protectedGroups) {
  Get-ADGroupMember -Identity $g -Recursive -ErrorAction SilentlyContinue
}) | Select-Object -ExpandProperty SID -Unique
```

**Step 2 — Find every adminCount=1 object not in that set**
```powershell
$flagged = Get-ADObject -LDAPFilter "(adminCount=1)" -Properties Name, ObjectClass, SamAccountName, objectSid
$orphaned = $flagged | Where-Object { $_.objectSid.Value -notin $currentMembers.Value }
$orphaned | Select-Object Name, ObjectClass, SamAccountName
```

**Step 3 — Review each orphaned object before touching anything — this is a security review step, not a mechanical cleanup**
Confirm with the account owner or a change record why the account was previously privileged and whether anything unexpected (unusual delegated rights, service/task creation, ACL changes elsewhere) occurred during that window.

**Step 4 — Clear adminCount and re-enable inheritance for confirmed-safe objects**
```powershell
foreach ($obj in $orphaned) {
    Set-ADObject -Identity $obj.DistinguishedName -Clear adminCount
    $adsi = [ADSI]"LDAP://$($obj.DistinguishedName)"
    $adsi.psbase.ObjectSecurity.SetAccessRuleProtection($false, $true)
    $adsi.psbase.CommitChanges()
}
```

**Rollback note:** Re-enabling inheritance only restores permission *flow* from the parent OU going forward; it grants nothing retroactively. If an account is later re-added to a protected group, SDProp re-flags it correctly on its own — this cleanup does not create any lasting exposure if done on a genuinely-no-longer-privileged account.

</details>

<details><summary>Playbook 2 — Forcing an immediate SDProp run for change validation</summary>

**Scenario:** A group membership change or `AdminSDHolder` template edit was just made and needs to be validated now rather than waiting up to 60 minutes.

**Step 1 — Identify the PDC Emulator**
```powershell
$pdce = (Get-ADDomain).PDCEmulator
```

**Step 2 — Trigger the on-demand task via the rootDSE operational attribute**
```powershell
$rootDSE = [ADSI]"LDAP://$pdce/rootDSE"
$rootDSE.Put("runProtectAdminGroupsTask", 1)
$rootDSE.SetInfo()
```

**Step 3 — Validate the expected object now reflects the change**
```powershell
Get-ADUser <sam> -Properties adminCount, whenChanged -Server $pdce
```

**Rollback note:** N/A — this only triggers a single immediate execution of the existing enforcement logic; it does not alter the scheduled interval or any persistent configuration.

</details>

<details><summary>Playbook 3 — Temporarily tightening the SDProp interval for lab/test validation only</summary>

**Scenario:** Testing AdminSDHolder-related changes repeatedly in a non-production environment and the default 60-minute wait is slowing iteration.

**Step 1 — Set a shorter interval on the PDCe (lab/test environments only)**
```powershell
# Run on the PDC Emulator
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" `
  -Name "AdminSDProtectFrequency" -PropertyType DWord -Value 60 -Force
```

**Step 2 — Validate the change is active by observing the next cycle, or force a run (Playbook 2) instead of waiting even at the shortened interval**

**Step 3 — Revert before returning to production use, or if this was ever run against a production PDCe**
```powershell
Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" `
  -Name "AdminSDProtectFrequency" -ErrorAction SilentlyContinue
# Deleting the value reverts to the 60-minute default
```

**Rollback note:** Do not leave a shortened interval in place in production — Microsoft's own guidance flags the LSASS processing overhead this introduces, scaling with the number of protected objects in the domain. Treat any value below the default as temporary and lab-scoped only.

</details>

<details><summary>Playbook 4 — Customizing the AdminSDHolder ACL template (domain-wide impact)</summary>

**Scenario:** A permanent, domain-wide permission needs to apply to every protected account and group (for example, granting a break-glass monitoring service read access to all Tier-0 objects) — rather than repeatedly re-applying and losing the same ACE on individual objects.

**Step 1 — Review the current template ACL carefully before changing it — every protected account/group in the domain inherits this exactly**
```powershell
$domainDN = (Get-ADDomain).DistinguishedName
Get-Acl "AD:\CN=AdminSDHolder,CN=System,$domainDN" | Select-Object -ExpandProperty Access
```

**Step 2 — Add the new ACE to the template object using standard ACL cmdlets/dsacls, following the same process as any other AD object**
```powershell
# Example approach only — construct the specific access rule matching your actual requirement
dsacls "CN=AdminSDHolder,CN=System,$domainDN" /G "<domain>\<principal>:<rights>"
```

**Step 3 — Force an on-demand SDProp run to propagate the change immediately rather than waiting (Playbook 2)**

**Step 4 — Validate on a representative protected account, not just the template itself**
```powershell
Get-Acl "AD:\<protected-object-DN>" | Select-Object -ExpandProperty Access
```

**Rollback note:** Removing the added ACE from the template and forcing another SDProp run reverts every protected object on the next cycle. Because this change is domain-wide and self-propagating, document it clearly (who, why, when) — it is easy for a future admin to find the ACE on a protected account and not know its origin was the template rather than a one-off grant.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  AdminSDHolder / SDProp Evidence Collector
.NOTES     Read-only. Run with rights to read group membership, adminCount, and ACLs domain-wide.
#>

$reportPath = "C:\Temp\AdminSDHolderEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== PDC Emulator ===" | Out-File "$reportPath\01_PDCe.txt"
(Get-ADDomain).PDCEmulator | Out-File "$reportPath\01_PDCe.txt" -Append

"=== Current Protected-Group Membership (transitive) ===" | Out-File "$reportPath\02_ProtectedMembers.txt"
$protectedGroups = "Account Operators","Administrators","Backup Operators","Domain Admins",
  "Domain Controllers","Enterprise Admins","Enterprise Key Admins","Key Admins","Print Operators",
  "Read-only Domain Controllers","Replicator","Schema Admins","Server Operators"
foreach ($g in $protectedGroups) {
    "--- $g ---" | Out-File "$reportPath\02_ProtectedMembers.txt" -Append
    Get-ADGroupMember -Identity $g -Recursive -ErrorAction SilentlyContinue |
      Select-Object Name, SamAccountName | Format-Table -AutoSize |
      Out-File "$reportPath\02_ProtectedMembers.txt" -Append
}

"=== All adminCount=1 Objects Domain-Wide ===" | Out-File "$reportPath\03_AdminCountFlagged.txt"
Get-ADObject -LDAPFilter "(adminCount=1)" -Properties Name, ObjectClass, SamAccountName, whenChanged |
  Select-Object Name, ObjectClass, SamAccountName, whenChanged | Format-Table -AutoSize |
  Out-File "$reportPath\03_AdminCountFlagged.txt" -Append

"=== AdminSDHolder Template ACL ===" | Out-File "$reportPath\04_TemplateACL.txt"
$domainDN = (Get-ADDomain).DistinguishedName
Get-Acl "AD:\CN=AdminSDHolder,CN=System,$domainDN" | Select-Object -ExpandProperty Access |
  Format-Table -AutoSize | Out-File "$reportPath\04_TemplateACL.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check adminCount and inheritance state for an account | `Get-ADUser <sam> -Properties adminCount, nTSecurityDescriptor` |
| Check inheritance state directly | `(Get-Acl "AD:\<DN>").AreAccessRulesProtected` |
| Find all adminCount=1 objects domain-wide | `Get-ADObject -LDAPFilter "(adminCount=1)"` |
| Identify the PDC Emulator (SDProp runs here only) | `(Get-ADDomain).PDCEmulator` or `netdom query fsmo` |
| Force an immediate SDProp run | ADSI `runProtectAdminGroupsTask=1` against PDCe rootDSE, or Ldp.exe |
| Clear a stale adminCount flag | `Set-ADUser <sam> -Clear adminCount` |
| Re-enable inheritance after clearing adminCount | `SetAccessRuleProtection($false, $true)` via `[ADSI]` |
| View the AdminSDHolder template's own ACL | `Get-Acl "AD:\CN=AdminSDHolder,CN=System,<domain DN>"` |
| Change SDProp interval (lab/test only) | `AdminSDProtectFrequency` DWORD, `HKLM\SYSTEM\CurrentControlSet\Services\NTDS\Parameters` |
| List all members of a protected group (transitive) | `Get-ADGroupMember -Identity "Domain Admins" -Recursive` |

---
## 🎓 Learning Pointers

- **`adminCount` is a side effect of SDProp correcting a mismatch, not the authoritative signal of current protection.** Protection status is determined by transitive current group membership at each SDProp run — treat `adminCount` as a strong hint that needs cross-referencing, not ground truth on its own.
- **`adminCount` is never automatically cleared when an account leaves a protected group — this is a deliberate 25-year-old design decision, not an oversight.** The assumption baked into it is that a formerly-privileged account deserves a security review before being treated as routine again, not silent restoration.
- **SDProp evaluates and enforces only on the PDC Emulator.** A recent FSMO transfer/seizure, or PDCe unavailability, delays domain-wide convergence — this is a single point of evaluation, not a distributed process.
- **Delegated OU-level permissions never reach a protected object, no matter how correctly the delegation is configured**, because inheritance is unconditionally disabled on it. This is one of the most common sources of "my delegation isn't working" tickets that turn out to have nothing wrong with the delegation itself.
- **Orphaned `adminCount=1` accounts are a routine, well-known AD hygiene finding** surfaced by nearly every security assessment tool — worth a periodic proactive audit rather than only reacting when a scan flags it.
- **Customizing the `AdminSDHolder` template itself is the only durable way to apply a permission domain-wide to every protected object** — any change made directly on an individual protected object will be reverted on the next cycle.
- Related: [Appendix C — Protected Accounts and Groups in Active Directory](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/plan/security-best-practices/appendix-c--protected-accounts-and-groups-in-active-directory), [Five common questions about AdminSdHolder and SDProp](https://learn.microsoft.com/en-us/archive/blogs/askds/five-common-questions-about-adminsdholder-and-sdprop), [KB232199 — Description and update of the AdminSDHolder object](https://support.microsoft.com/kb/232199)
