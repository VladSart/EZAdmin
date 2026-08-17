# AdminSDHolder / SDProp — Hotfix Runbook (Mode B: Ops)
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

Run these from an elevated PowerShell session with the `ActiveDirectory` module (DC or RSAT host):

```powershell
# 1. Is the account currently flagged as AdminSDHolder-protected, and is inheritance disabled?
Get-ADUser <sam> -Properties adminCount, nTSecurityDescriptor |
  Select-Object Name, adminCount, @{N='InheritanceDisabled';E={$_.nTSecurityDescriptor.AreAccessRulesProtected}}

# 2. Is it STILL a member of a protected group (transitively), or is this a stale/orphaned flag?
"Domain Admins","Enterprise Admins","Schema Admins","Administrators","Account Operators",
"Backup Operators","Print Operators","Server Operators","Replicator" | ForEach-Object {
    Get-ADGroupMember -Identity $_ -Recursive -ErrorAction SilentlyContinue
} | Where-Object { $_.SamAccountName -eq '<sam>' }
# No output = the account is NOT currently in any protected group — adminCount=1 is orphaned (Fix 2)

# 3. Which DC holds the PDC Emulator? SDProp ONLY runs there, every 60 min by default.
netdom query fsmo | Select-String "PDC"

# 4. Did someone modify the AdminSDHolder template object itself (intentional hardening vs. accident)?
Get-ADObject "CN=AdminSDHolder,CN=System,$((Get-ADDomain).DistinguishedName)" -Properties whenChanged, nTSecurityDescriptor |
  Select-Object whenChanged

# 5. Confirm the account is reachable/replicated everywhere before assuming SDProp itself is broken
Get-ADUser <sam> -Server <PDCe-DC> -Properties adminCount
```

| What you see | What it means |
|---|---|
| A custom ACL change on a Domain Admins/Administrators member "disappeared" within about an hour | **Working as designed.** SDProp re-stamped the account's permissions to match the `AdminSDHolder` template — go to Fix 1 |
| `adminCount = 1` but the account is **not** a current (even transitive) member of any protected group | **Orphaned protection.** The account was once privileged, was removed from the group, but `adminCount` was never cleared — this is permanent by design until manually fixed — go to Fix 2 |
| A delegated OU admin can't manage a user/group that used to be (or still is) in a protected group | Inheritance is disabled on that object — OU-level delegated permissions never flow down to it, regardless of delegation wizard settings — go to Fix 3 |
| You need to validate a fix **right now** instead of waiting up to 60 minutes for the next SDProp cycle | Force SDProp to run on-demand — go to Fix 4 |
| An entire security group (not an individual account) has permissions reverting | The group itself is one of the protected groups (Domain Admins, etc.) — same mechanism, same fix path — this is not a bug isolated to user objects |
| Security assessment tool (PingCastle, Purple Knight, BloodHound, etc.) flags a list of "stale adminCount" objects | This is the exact orphaned-protection condition in Fix 2 — a known, common AD hygiene finding, not a sign of compromise by itself, but worth investigating each one |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
PDC Emulator role holder is online and reachable
  └── SDProp process runs on the PDCe only (every 60 min by default, AdminSDProtectFrequency)
        └── Enumerates protected groups (Domain Admins, Enterprise Admins, Administrators,
            Schema Admins, Account/Backup/Print/Server Operators, Replicator, Krbtgt,
            Domain Controllers, Read-only Domain Controllers, Enterprise/Key Admins)
              └── Transitively expands nested group membership to find every protected principal
                    └── Compares each protected principal's ACL against the AdminSDHolder
                        template object's ACL (CN=AdminSDHolder,CN=System,<domain DN>)
                          ├── Mismatch found → ACL is OVERWRITTEN to match the template
                          │     └── adminCount set to 1, inheritance flag (AreAccessRulesProtected)
                          │         set to True — permissions no longer flow from parent OU
                          └── Match already → object left untouched (adminCount may remain 0/unset
                                if the ACL already happened to match before ever being flagged)
  └── Replication then carries the re-stamped ACL/adminCount to every other DC
```

Key failure points:
- SDProp is evaluated **only** on the PDC Emulator — if the PDCe is unreachable, degraded, or was recently seized/transferred, protection convergence for the whole domain stalls until it's healthy again
- `adminCount` is **not automatically cleared** when an account leaves every protected group — this is intentional (see Learning Pointers), and it's the single most common source of confusing "why does this account behave like it's still an admin" tickets
- Determining whether an object is currently protected is based on transitive group membership, not simply reading `adminCount` — a stale `adminCount=1` does not mean the account is still privileged
- Custom delegation/ACL changes made directly on a protected object (not via the AdminSDHolder template) are guaranteed to be reverted on the next SDProp cycle — there is no per-object exemption

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the account is actually AdminSDHolder-protected right now, not just historically**
```powershell
Get-ADUser <sam> -Properties adminCount, nTSecurityDescriptor, MemberOf
```
Expected: if `adminCount = 1`, cross-check `MemberOf` (expanded recursively — see Triage #2) against the current protected-group list. A mismatch means the flag is stale.

**Step 2 — Confirm which DC is the PDC Emulator and that it's healthy**
```powershell
netdom query fsmo
Test-Connection -ComputerName <PDCe-name> -Count 2 -Quiet
```
Expected: PDCe responds. If it was recently seized (metadata cleanup after a DC failure), SDProp will not have run there until the new PDCe processes its first cycle.

**Step 3 — Check when the object last changed to correlate with a reported "permissions reverted" complaint**
```powershell
Get-ADUser <sam> -Properties whenChanged | Select-Object whenChanged
```
Expected: a `whenChanged` timestamp roughly aligned with an hourly boundary (or with a manual SDProp run) supports "SDProp reverted my change" as the explanation.

**Step 4 — Verify inheritance state directly (the practical symptom delegated admins hit)**
```powershell
(Get-Acl "AD:\$((Get-ADUser <sam>).DistinguishedName)").AreAccessRulesProtected
```
Expected: `True` for any currently-or-formerly protected object — this is why OU-delegated rights don't apply to it.

**Step 5 — If planning a fix, confirm no one else depends on the current (possibly stale) protected state before clearing it**
```powershell
Get-ADUser <sam> -Properties adminCount, MemberOf, LastLogonDate
```
Expected: review before touching `adminCount` — clearing it on an account still legitimately needing hardened permissions removes real protection, not just a cosmetic flag.

---
## Common Fix Paths

<details><summary>Fix 1 — Custom ACL/permission change on a protected account keeps reverting</summary>

**Cause:** This is expected behavior, not a bug. Any account that is (or was) a member of a protected group has its permissions overwritten every SDProp cycle (default 60 min) to match the `AdminSDHolder` template — no per-object exception exists.

```powershell
# Confirm this is really the mechanism at play
Get-ADUser <sam> -Properties adminCount | Select-Object Name, adminCount
```

**The only supported fixes:**
- Change the permission on the **`AdminSDHolder` template object itself** if the change should apply to *every* protected account/group domain-wide (high-impact, plan carefully — see the Deep Dive's Remediation Playbook 4)
- Do not delegate rights on a protected account at the object/OU level at all — grant the underlying capability a different way (e.g., through group membership in a role that doesn't itself get overwritten)

**Rollback note:** N/A — nothing to roll back; this is SDProp functioning correctly.

</details>

<details><summary>Fix 2 — Orphaned adminCount=1 (account no longer in any protected group)</summary>

**Cause:** The account was once a member of a protected group (directly or via nested group membership), got `adminCount=1` and inheritance disabled, was later removed from the group — but `adminCount` was never reset. This is Microsoft's original by-design behavior (see Learning Pointers), not a fault.

```powershell
# Confirm the account is genuinely no longer protected before touching anything (see Triage #2)

# Reset adminCount and re-enable inheritance
Set-ADUser <sam> -Clear adminCount
$obj = [ADSI]"LDAP://$((Get-ADUser <sam>).DistinguishedName)"
$acl = $obj.psbase.ObjectSecurity
$acl.SetAccessRuleProtection($false, $true)   # $false = inheritance enabled, $true = preserve existing explicit ACEs
$obj.psbase.CommitChanges()

# Verify
Get-ADUser <sam> -Properties adminCount
(Get-Acl "AD:\$((Get-ADUser <sam>).DistinguishedName)").AreAccessRulesProtected
```

**Rollback note:** Re-enabling inheritance restores permission flow from the parent OU going forward; it does not retroactively grant or revoke anything beyond that. Re-setting `adminCount = 1` and re-disabling inheritance manually reverts this if done in error — but if the account is later re-added to a protected group, SDProp will re-flag it correctly on its own regardless.

</details>

<details><summary>Fix 3 — Delegated OU admin can't manage a protected account/group</summary>

**Cause:** Inheritance is disabled on protected objects, so permissions delegated at the OU level (via the Delegation of Control wizard or a manual ACE on the OU) never reach them — regardless of how correctly the delegation was configured.

```powershell
# Confirm this is the actual blocker
(Get-Acl "AD:\<protected-object-DN>").AreAccessRulesProtected   # True = inheritance disabled, delegation won't flow

# This is not something to "fix" by re-enabling inheritance on a still-legitimately-protected
# account — that would remove real hardening. The correct remediation is one of:
#  - Perform the needed management action using Domain Admins/appropriate Tier-0 rights instead
#    of relying on the OU-level delegation
#  - If the object should NOT be protected at all (see Fix 2), confirm and clear adminCount first
```

**Rollback note:** N/A — no config change is made unless Fix 2 applies. Escalate to whoever owns Tier-0 access if the delegated admin genuinely needs standing rights over a still-protected object; that's an access-model decision, not a bug fix.

</details>

<details><summary>Fix 4 — Need SDProp to run immediately instead of waiting up to 60 minutes</summary>

**Cause:** Testing a change to a protected account, the `AdminSDHolder` template, or group membership, and you don't want to wait for the next scheduled cycle.

```powershell
# Via ADSI against the PDC Emulator's rootDSE (no native PowerShell cmdlet exists for this)
$pdce = (Get-ADDomain).PDCEmulator
$rootDSE = [ADSI]"LDAP://$pdce/rootDSE"
$rootDSE.Put("runProtectAdminGroupsTask", 1)
$rootDSE.SetInfo()
# SDProp runs immediately; this does not change the scheduled 60-minute cadence going forward
```

Alternatively, use **Ldp.exe** connected to the PDCe: Connection → Bind → Browse → Modify, leave DN blank, set attribute `RunProtectAdminGroupsTask` = `1`, click Run.

**Rollback note:** N/A — this only triggers an on-demand run of the existing, unmodified enforcement logic. It does not create, disable, or change anything persistent.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — AdminSDHolder / SDProp Issue

Account or group affected: ____________
adminCount value: ____________
Currently a member of a protected group (Yes/No, transitively checked): ____________
Inheritance disabled (AreAccessRulesProtected) (Yes/No): ____________
PDC Emulator role holder: ____________
PDCe healthy/reachable (Yes/No): ____________
Symptom (permissions reverting / delegation not working / adminCount won't clear / other): ____________
Time permissions were changed vs. time they reverted: ____________

Steps already attempted:
[ ] Confirmed current protected-group membership (transitive) vs. adminCount value
[ ] Confirmed PDC Emulator identity and health
[ ] Checked inheritance state (AreAccessRulesProtected) directly
[ ] Forced an on-demand SDProp run for validation, if applicable
[ ] Ruled out this being expected behavior before escalating
```

---
## 🎓 Learning Pointers

- **`adminCount` does not auto-revert to 0 when an account leaves a protected group — this is intentional, by design, dating back to Windows 2000.** Microsoft's own rationale: a former privileged account could have planted backdoors before being de-admined, so the assumption is it should be reviewed, disabled, or deleted — not silently returned to normal. See [Five common questions about AdminSdHolder and SDProp](https://learn.microsoft.com/en-us/archive/blogs/askds/five-common-questions-about-adminsdholder-and-sdprop).
- **AdminSDHolder is the template object; SDProp is the enforcement process that stamps it onto protected accounts every 60 minutes (PDCe only).** They're related but distinct — troubleshooting "permissions keep reverting" is an SDProp question, troubleshooting "what should the permissions even be" is an AdminSDHolder question.
- **A stale `adminCount=1` with no current protected-group membership is a well-known AD hygiene finding**, routinely surfaced by security assessment tools (PingCastle, Purple Knight, BloodHound). It's not evidence of compromise by itself, but each instance is worth a quick review before clearing.
- **Never try to "fix" reverting permissions by re-applying the same ACE repeatedly.** SDProp will overwrite it again on the next cycle; the only durable options are changing the `AdminSDHolder` template itself (domain-wide impact) or restructuring how the underlying access is granted.
- Related: [Appendix C — Protected Accounts and Groups in Active Directory](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/plan/security-best-practices/appendix-c--protected-accounts-and-groups-in-active-directory), [KB232199 — Description and update of the AdminSDHolder object](https://support.microsoft.com/kb/232199)
