# Shadow Groups (OU/Attribute-Synced Security Groups) — Hotfix Runbook (Mode B: Ops)
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

A "shadow group" is not a native AD object type — it's an ordinary security group whose membership a scheduled script keeps synchronized to an OU (or another attribute filter). There is no built-in flag or attribute marking a group as a shadow group, so triage starts by getting the **defining criteria** (source OU or filter) from whoever owns the group — a naming convention or the group's `Description` field is the usual place to find it if no one remembers.

```powershell
# 1. Current actual membership of the group in question
Get-ADGroupMember -Identity "<GroupName>" | Select-Object Name, SamAccountName, objectClass

# 2. What membership SHOULD be right now, per the stated criteria (OU-based example)
Get-ADUser -SearchBase "<OU_DN>" -Filter * | Select-Object Name, SamAccountName
# — or, for an attribute-based shadow group —
Get-ADUser -Filter "Title -eq '<Value>'" -Properties Title | Select-Object Name, SamAccountName

# 3. Diff: who's IN the group but shouldn't be, and who SHOULD be but isn't
Compare-Object -ReferenceObject (Get-ADGroupMember "<GroupName>" | Select -Expand SamAccountName) `
  -DifferenceObject (Get-ADUser -SearchBase "<OU_DN>" -Filter * | Select -Expand SamAccountName)

# 4. Is the sync job actually still running? (Check on whatever host owns the scheduled task)
Get-ScheduledTask | Where-Object { $_.TaskName -like "*Shadow*" -or $_.TaskName -like "*GroupSync*" } |
  Get-ScheduledTaskInfo | Select-Object TaskName, LastRunTime, LastTaskResult

# 5. Does the sync account still hold delegated write access on the group's member attribute?
dsacls "<GroupDN>" | Select-String "member"
```

| What you see | What it means |
|---|---|
| Group has members who left the defining OU weeks/months ago and are still in it | Classic **additive-only sync bug** — the script adds new matches but never removes stale ones — go to Fix 2 |
| Group is missing someone who clearly belongs (just moved into the OU / attribute was just set) | Either the sync hasn't run yet (check schedule) or it's failing silently — go to Fix 1 |
| `Get-ScheduledTaskInfo` shows `LastTaskResult` non-zero, or `LastRunTime` is unexpectedly old | The sync job itself is broken/stopped — go to Fix 1 |
| Sync job runs on schedule and reports success, but the group still doesn't update | The sync account has lost its delegated `member`-attribute write permission (often after a permissions cleanup or account expiry) — go to Fix 3 |
| Group feeds GPO security filtering and the wrong users are/aren't getting the policy | Confirm this is a membership-drift problem here first, not a GPO-side Read/Apply Group Policy ACE problem — see `Troubleshooting/GroupPolicy/AD-GroupPolicy-B.md` if the group itself is correct — go to Fix 4 |
| Group feeds an FGPP/PSO and the wrong password policy is winning | Confirm membership is current first; if it is, this is PSO precedence, not shadow-group drift — see `Troubleshooting/FineGrainedPasswordPolicies/FGPP-B.md` — go to Fix 5 |
| Someone tried to link a GPO or PSO directly to the OU itself and nothing happened | Root confusion, not a shadow-group bug — OUs cannot be GPO security-filter principals or PSO targets at all — go to Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Security group exists (created ONCE, manually or via script — never auto-created by anything native)
  └── Sync identity (a scheduled task's service account, or a third-party tool's service account)
      holds DELEGATED WRITE on the group's "member" attribute — NOT Domain Admin, a narrow,
      specifically-delegatable right
        └── Scheduled task/job on some host runs on an interval (5 min to nightly — entirely
            admin-chosen, no platform-enforced cadence exists)
              └── Job queries the CURRENT state of the defining criteria (OU SearchBase,
                  attribute filter, or a third-party tool's rule definition)
                    └── Job must RECONCILE (add missing AND remove stale) — additive-only logic
                        is the single most common implementation defect in this pattern
                          └── Group membership updated → replicates via normal AD multi-master
                              replication (see Troubleshooting/Replication/) to all DCs
                                └── DOWNSTREAM CONSUMERS read the now-current membership:
                                      ├── GPO security filtering (Read + Apply Group Policy ACE
                                      │     on the GPO) — see Troubleshooting/GroupPolicy/
                                      ├── FGPP/PSO msDS-PSOAppliesTo (group MUST be global
                                      │     security-scoped, same requirement as here) — see
                                      │     Troubleshooting/FineGrainedPasswordPolicies/
                                      ├── File/share NTFS or share-level ACLs
                                      └── Mail-enabled security group distribution (if the group
                                          is also mail-enabled — a separate property, not a
                                          separate group)
```

Key failure points:
- **No self-healing exists anywhere in this chain.** Unlike GPO processing (which retries every refresh cycle) or FGPP (which is evaluated live), a shadow group's membership is exactly as stale as the last successful sync run — if the scheduled task silently stops, nothing alerts anyone.
- The sync account's delegated permission is easy to lose collaterally during an unrelated permissions/RBAC cleanup, since it doesn't look like anything else in the domain (a narrow write on one attribute of one or a handful of groups).
- A group can be a shadow group for **more than one downstream consumer at once** (e.g., feeding both a GPO security filter and a PSO) — treat any membership change as having a wider blast radius than "just this one ticket."

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Establish the defining criteria (there is no native way to look this up)**
Ask the group owner, check the group's `Description` field, or check the naming convention (e.g., `SG-<OUName>`). If genuinely undocumented, `Get-ADGroup -Identity "<Name>" -Properties Description,whenChanged,Info` is the best starting point.

**Step 2 — Compute the current drift**
```powershell
$actual   = (Get-ADGroupMember "<GroupName>").SamAccountName
$expected = (Get-ADUser -SearchBase "<OU_DN>" -Filter *).SamAccountName
$stale    = $actual   | Where-Object { $_ -notin $expected }   # should be removed
$missing  = $expected | Where-Object { $_ -notin $actual }     # should be added
```
Expected: both lists empty on a healthy shadow group. Any non-empty `$stale` list on a group that's existed for more than one sync interval is the additive-only bug signature.

**Step 3 — Confirm the sync mechanism is actually executing**
Locate the scheduled task (or third-party tool job, e.g. Quest ActiveRoles or FirstWare DynamicGroup) on its host and check last-run time/result. If nobody knows where the sync runs, that itself is the finding — an undocumented, single-point-of-failure automation.

**Step 4 — Confirm the sync account's delegated permission**
```powershell
dsacls "<GroupDN>" | Select-String "<SyncAccountName>"
```
Expected: an explicit `Write member` (or equivalent) grant for the sync account. Its absence, with the task otherwise running "successfully," means the task is silently no-op'ing on the actual membership write — check the job's own logs for a permission-denied error that may have gone unnoticed.

**Step 5 — Confirm downstream impact before declaring the fix complete**
If the group feeds a GPO, re-check security filtering; if it feeds a PSO, re-check `msDS-ResultantPSO` for an affected user. Fixing the group's membership doesn't retroactively speed up whatever refresh cycle the consumer itself runs on.

---
## Common Fix Paths

<details><summary>Fix 1 — Sync job isn't running or is failing</summary>

**Cause:** The scheduled task is disabled, its trigger was removed, its account's password expired, or it's erroring out silently.

```powershell
Get-ScheduledTask -TaskName "<TaskName>" | Get-ScheduledTaskInfo
# Re-enable / re-trigger a run manually to confirm the underlying script still works at all
Start-ScheduledTask -TaskName "<TaskName>"
Start-Sleep -Seconds 30
Get-ScheduledTaskInfo -TaskName "<TaskName>"
```

**Rollback note:** N/A — re-running the sync only ever moves membership toward the correct state (assuming the script itself reconciles correctly — see Fix 2 if it doesn't).

</details>

<details><summary>Fix 2 — Sync script is additive-only (never removes stale members)</summary>

**Cause:** The most common shadow-group implementation defect. Many widely-circulated example scripts for this pattern only ever call `Add-ADGroupMember` for current matches and never call `Remove-ADGroupMember` for members who no longer match — membership only ever grows.

```powershell
# Correct reconciliation pattern — compute the full desired set, diff, act on BOTH directions
$desired = Get-ADUser -SearchBase "<OU_DN>" -Filter * | Select-Object -ExpandProperty DistinguishedName
$current = Get-ADGroupMember -Identity "<GroupName>" | Select-Object -ExpandProperty DistinguishedName

$toAdd    = $desired | Where-Object { $_ -notin $current }
$toRemove = $current | Where-Object { $_ -notin $desired }

if ($toAdd)    { Add-ADGroupMember    -Identity "<GroupName>" -Members $toAdd }
if ($toRemove) { Remove-ADGroupMember -Identity "<GroupName>" -Members $toRemove -Confirm:$false }
```

**Rollback note:** Review `$toRemove` before running against a production group for the first time — a removal is immediately live for downstream GPO/PSO/ACL consumers. Consider a `-WhatIf`-style dry run (echo `$toAdd`/`$toRemove` without acting) on first deployment of a corrected script.

</details>

<details><summary>Fix 3 — Sync account lost its delegated write permission</summary>

**Cause:** The account's `Write member` delegation on the group was removed, often as collateral damage during an unrelated permissions/RBAC cleanup, or the account itself was disabled/expired.

```powershell
# Re-delegate narrowly — write access to the member attribute only, not full group control
$acl = Get-Acl "AD:\<GroupDN>"
$sid = (Get-ADUser "<SyncAccountName>").SID
$rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
  $sid, "WriteProperty", "Allow", ([GUID]"bf9679c0-0de6-11d0-a285-00aa003049e2"))  # member attribute GUID
$acl.AddAccessRule($rule)
Set-Acl "AD:\<GroupDN>" $acl
```

**Rollback note:** Removing this ACE later simply returns the group to sync-broken state — no destructive side effect either direction.

</details>

<details><summary>Fix 4 — Group feeds GPO security filtering, wrong users affected</summary>

**Cause:** Once membership is confirmed current (Step 2 above), a remaining GPO-targeting issue is a GPO-side Read/Apply Group Policy ACE problem, not a shadow-group problem.

Go to `Troubleshooting/GroupPolicy/AD-GroupPolicy-B.md` (security/WMI filtering fixes) — do not keep troubleshooting membership sync once the diff in Step 2 comes back clean.

**Rollback note:** N/A — this fix path is a handoff, not an action here.

</details>

<details><summary>Fix 5 — Group feeds an FGPP/PSO, wrong password policy winning</summary>

**Cause:** Once membership is confirmed current, a remaining wrong-policy-wins issue is PSO precedence resolution, not shadow-group drift.

Go to `Troubleshooting/FineGrainedPasswordPolicies/FGPP-B.md` (precedence and direct-link fixes) — check `msDS-ResultantPSO` on the affected user only after confirming the group itself is accurate.

**Rollback note:** N/A — handoff, not an action here.

</details>

<details><summary>Fix 6 — Someone tried to link a GPO or PSO directly to an OU as if it were a group</summary>

**Cause:** Root confusion this entire pattern exists to solve. GPOs link to OUs for *scope* but security-*filter* only on users/computers/groups; PSOs (`msDS-PSOAppliesTo`) can target users and global security groups **only**, never an OU, at the schema level — there is no workaround.

**The fix is not a command — it's building a shadow group for the OU in question** (see the Deep Dive's Remediation Playbook 1 for a from-scratch build) and pointing the GPO security filter or PSO at the group instead of attempting to reference the OU directly.

**Rollback note:** N/A — this is a design correction, not a reversible action.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Shadow Group Membership Issue
Group name: ____________
Defining criteria (OU DN or attribute filter): ____________
Downstream consumer(s) (GPO security filter / PSO / file ACL / distribution — list all): ____________
Sync mechanism (scheduled task name + host, or third-party tool): ____________
Last successful sync run time: ____________
Stale members found (should be removed): ____________
Missing members found (should be added): ____________
Sync account still holds delegated "Write member" permission (Yes/No): ____________

Steps already attempted:
[ ] Computed actual-vs-expected membership diff directly (not assumed from symptoms)
[ ] Confirmed sync job last-run time/result
[ ] Confirmed sync account's delegated member-attribute permission
[ ] Ruled out a downstream-consumer-specific issue (GPO ACE / PSO precedence) once membership
    itself was confirmed current
```

---
## 🎓 Learning Pointers

- **"Shadow group" is a practitioner term, not an official Microsoft feature or Learn-documented mechanism.** There is no dedicated Microsoft Learn page for it — it's a decades-old community pattern name for "a security group whose membership a scheduled script keeps in sync with an OU or attribute," built entirely from ordinary AD PowerShell cmdlets plus Task Scheduler (or a third-party tool like Quest ActiveRoles or FirstWare DynamicGroup).
- **On-premises AD DS has no native, no-code dynamic/rule-based group membership engine.** That capability exists only in Entra ID (Dynamic Groups, membership-rule based — see `EntraID/Troubleshooting/DynamicGroups-A.md`). Every "dynamic" on-prem AD group, shadow groups included, is a static group kept current by an external script or tool — there is no on-prem equivalent to expect.
- **The single most common implementation bug is additive-only sync logic** — adding new matches without ever removing stale ones. Correct implementations always compute the full desired-vs-actual diff and act in both directions (Fix 2).
- **Why this pattern exists at all:** GPO security filtering and FGPP/PSO targeting (`msDS-PSOAppliesTo`) both require a security-principal object — a user, computer, or **global security group** — and neither can reference an OU directly, even though "apply this to everyone in that OU" is one of the most common real-world asks. See `Troubleshooting/FineGrainedPasswordPolicies/FGPP-A.md` for the PSO-specific version of this same constraint.
- **This pattern has zero self-healing.** A stuck GPO refresh retries every cycle; a shadow group with a dead scheduled task just quietly goes stale forever until someone notices a symptom and traces it back here.
- Related: [GPO Security Filtering: How It Works, Configuration and Troubleshooting](https://www.manageengine.com/products/ad-manager/kb/gpo/what-is-group-policy-security-filtering.html), [Group Policy processing for Windows](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/group-policy/group-policy-processing), [Shadow Groups: Active Directory's Dark Side](https://deployhappiness.com/shadow-groups-security-active-directory/) (the widely-circulated reference implementation — note its own comment thread flags the additive-only defect described in Fix 2)
