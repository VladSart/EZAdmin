# Shadow Groups (OU/Attribute-Synced Security Groups) — Reference Runbook (Mode A: Deep Dive)
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
- The shadow group pattern: why it exists, what problem it actually solves, and why it is a script/tool-driven convention rather than a native AD feature
- The scheduled-sync architecture: query criteria (OU SearchBase or attribute filter), reconciliation logic, and the delegated-permission model for the account that runs it
- Staleness/eventual-consistency mechanics and why this pattern has no self-healing
- Downstream consumers that require a security group rather than an OU: GPO security filtering and FGPP/PSO targeting, covered here only as the reason shadow groups get built, not as their own internals
- Design and migration guidance for standing up a new shadow group correctly, and for retiring one safely

**Out of scope:**
- **Entra ID Dynamic Groups** — a genuinely native, rule-engine-based dynamic membership feature, but cloud-only; no on-premises AD DS equivalent has ever shipped. See `EntraID/Troubleshooting/DynamicGroups-A.md`. Conflating the two is the single most common expectation mismatch this topic produces.
- **Exchange Dynamic Distribution Groups** — membership calculated at send-time from a recipient filter, with no stored membership at all. A real, elegant, natively-dynamic mechanism, but scoped to mail routing only; distribution groups are not security principals and cannot be used for GPO security filtering, PSO targeting, or NTFS/share ACLs regardless of how their membership is computed.
- GPO security filtering internals (Read/Apply Group Policy ACE model, WMI filtering) — see `Troubleshooting/GroupPolicy/AD-GroupPolicy-A.md`; covered here only as a downstream consumer
- FGPP/PSO internals (precedence resolution, Password Settings Container) — see `Troubleshooting/FineGrainedPasswordPolicies/FGPP-A.md`; covered here only as a downstream consumer, though this topic and FGPP share the identical root architectural constraint (a PSO's `msDS-PSOAppliesTo` cannot target an OU)
- AD replication mechanics for how a membership change propagates domain-wide once written — see `Troubleshooting/Replication/AD-Replication-A.md`
- Third-party dynamic-group products (Quest ActiveRoles, FirstWare DynamicGroup, ManageEngine ADManager Plus) in vendor-specific detail — mentioned only as alternatives to a DIY scheduled script, not documented feature-by-feature

**Assumptions:**
- The `ActiveDirectory` PowerShell module (RSAT) is available on whatever host runs the sync
- A scheduled task, third-party tool job, or equivalent automation is the sync mechanism (there is no native, agentless way to keep a group's membership tied to an OU)
- The reader understands basic AD security-principal concepts (users, computers, security vs. distribution groups, group scope)

---
## How It Works

<details><summary>Full architecture — why the pattern exists, the sync model, and the delegation boundary</summary>

### The Problem: OUs Are Containers, Not Security Principals

Organizational Units exist to organize objects for administrative delegation and Group Policy *linking* — an OU has a Distinguished Name and can be a GPO link target, but it has no Security Identifier (SID) and cannot appear in an access token, a GPO's security filter list, or a Password Settings Object's applicability list. Two specific, extremely common real-world requirements collide directly with this limitation:

1. **GPO security filtering** — "apply/exclude this GPO for only some of the users/computers in this OU" requires listing security principals in the GPO's DACL (Read + Apply Group Policy). An OU cannot appear there; only users, computers, and groups can.
2. **Fine-Grained Password Policies** — a Password Settings Object's `msDS-PSOAppliesTo` attribute can reference **users and global security groups only**, never an OU, at the schema level (see `Troubleshooting/FineGrainedPasswordPolicies/FGPP-A.md`). An admin coming from the GPO mental model ("just link it to the OU") hits this wall immediately and has no override.

A **shadow group** is the practitioner answer to both: an ordinary security group whose membership is kept synchronized — by a scheduled script or third-party tool, never by AD itself — to whatever OU (or attribute) actually defines the population that should receive the GPO filter or PSO. The group is the security principal AD requires; the OU (or attribute) remains the source of truth an admin actually manages day to day (moving a user's account between OUs, or changing a Title attribute, rather than manually maintaining group membership).

### There Is No Native Mechanism — This Is Entirely Script/Tool-Driven

It's worth being explicit about this because it's easy to assume otherwise coming from Entra ID: **on-premises AD DS has never shipped a native, no-code, rule-based dynamic group membership engine.** Every implementation of the shadow-group pattern is one of:
- A custom PowerShell script (`Get-ADUser -SearchBase <OU>` / `-Filter <attribute>` followed by `Add-`/`Remove-ADGroupMember`) triggered by Windows Task Scheduler on an interval the admin chooses entirely
- A third-party product (Quest ActiveRoles, FirstWare DynamicGroup, ManageEngine ADManager Plus, and similar) that provides a GUI rule builder and its own scheduling engine over the same underlying mechanism
- A SIEM/IAM platform's connector doing the same reconciliation as part of a broader identity governance workflow

All three ultimately reduce to the same thing at the directory level: a batch process periodically overwrites `member` on an ordinary security group. There is no AD-native equivalent of Entra ID's Dynamic Group membership rule engine, which evaluates rules live and updates membership automatically without any external process — that capability simply does not exist on-premises.

### Reconciliation, Not Just Addition

A correct sync implementation computes the **full desired member set** from the current criteria, compares it against the **full current member set**, and acts in both directions — adding accounts that now match and removing accounts that no longer match. The single most common defect found in real-world shadow-group implementations (including in widely-circulated example scripts) is **additive-only logic**: the script adds new matches on every run but never removes anyone, so membership only ever grows. This produces silent privilege/policy creep — a user who transfers departments (and OUs) keeps the old GPO settings or password policy indefinitely, alongside whatever the new group now also grants them, until someone notices and manually cleans it up.

### The Delegation Model

The identity running the sync (a service account for a scheduled task, or a third-party tool's service account) needs exactly one thing: **delegated Write access to the `member` attribute** of the target group(s) — a narrow, specifically-delegatable right via `dsacls` or the ADUC Delegation of Control wizard's "Modify the membership of a group" option. It does not need Domain Admins, does not need broader group-management rights, and should never be granted them as a shortcut — an over-privileged sync account is a standing risk disproportionate to the account's actual job, the same over-broad-permission theme covered for RODC replication rights in `Troubleshooting/RODC/RODC-A.md`.

### Staleness Is Structural, Not a Bug

Because membership only changes when the sync process runs, a shadow group's accuracy is bounded by the sync interval — typically anywhere from every few minutes to nightly, entirely at the implementer's discretion, with no platform-enforced cadence. Unlike GPO client-side processing (which retries every refresh cycle, self-healing a missed application) or PSO resolution (evaluated live against current group membership at logon), **a shadow group has no self-healing property at all**. If the scheduled task is disabled, its account expires, or its delegated permission is revoked, membership simply freezes at its last-known-correct state with no error surfaced anywhere an admin would naturally look — the first signal is usually a user reporting the wrong GPO settings or password policy, at which point the investigation has to work backward to a scheduled task nobody remembered existed.

</details>

---
## Dependency Stack

```
OU structure or a chosen attribute defines the TRUE population an admin actually manages
day to day (moving user accounts between OUs, setting a Title/department attribute, etc.)
  └── Security group created ONCE as the shadow group — no native AD feature creates or
      maintains this; it is a plain, ordinary security group from AD's perspective
        └── Sync identity delegated Write access to the group's "member" attribute ONLY
            (dsacls / Delegation of Control wizard — never full group-management rights,
            never Domain Admin)
              └── Scheduled task (or third-party tool job) runs on an admin-chosen interval
                    └── Job computes desired-vs-actual membership diff and RECONCILES
                        (adds AND removes) — additive-only logic is the #1 defect class
                          └── AD multi-master replication propagates the membership change
                              domain-wide (see Troubleshooting/Replication/)
                                └── Downstream consumers evaluate the now-current membership
                                    on THEIR OWN independent schedules/triggers:
                                      ├── GPO security filtering — evaluated at the client's
                                      │     next foreground/background refresh cycle
                                      ├── FGPP/PSO msDS-PSOAppliesTo — evaluated live at
                                      │     logon via msDS-ResultantPSO calculation
                                      ├── NTFS/share ACLs — evaluated at next access-token
                                      │     build (typically next logon, for a group SID to
                                      │     be added to a user's Kerberos PAC/access token)
                                      └── Mail-enabled distribution (if applicable) — near-
                                          real-time once membership itself is replicated
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Group has long-stale members who left the defining OU/attribute weeks or months ago | Additive-only sync script — membership was never designed to shrink | Compute the actual-vs-expected diff directly; a nonzero "stale" set on a mature group is the signature |
| A newly-added/moved user isn't reflected in the group yet | Normal sync-interval lag, or the scheduled task is failing silently | `Get-ScheduledTaskInfo` last-run time/result |
| Sync job reports success on schedule but the group genuinely never changes | Sync account lost its delegated `member`-attribute write permission | `dsacls <GroupDN>` for the sync account's ACE |
| GPO targeting via the shadow group is wrong even though the group's own membership is confirmed current | Not a shadow-group problem — this is a GPO-side Read/Apply Group Policy ACE issue | `Troubleshooting/GroupPolicy/AD-GroupPolicy-A.md` |
| PSO/FGPP wrong-policy-wins even though the group's own membership is confirmed current | Not a shadow-group problem — this is PSO precedence resolution | `Troubleshooting/FineGrainedPasswordPolicies/FGPP-A.md` |
| Admin expected a rule-based/no-code dynamic group like they've seen in Entra ID | Expectation mismatch — no such native on-prem AD feature exists; every on-prem "dynamic" group is script/tool-driven | `EntraID/Troubleshooting/DynamicGroups-A.md` for the cloud-only equivalent |
| Nobody knows where the sync job for a legacy shadow group even runs | The single-point-of-failure automation was never documented — treat discovery of this fact as a finding in itself, not just a blocker | Check the group's `Description`, `Info`, and `whenChanged`/`whenCreated` for clues; check common automation hosts |
| A group used for mail distribution also unexpectedly affects GPO application or password policy | The same group object is doing double duty as both a distribution list and a shadow group feeding a security-sensitive consumer — a design smell, not a bug | Confirm via `Troubleshooting/GroupPolicy/` and `Troubleshooting/FineGrainedPasswordPolicies/` whether the group is genuinely referenced by either |

---
## Validation Steps

**Step 1 — Confirm the group is security-scoped and security-enabled, not a distribution group**
```powershell
Get-ADGroup -Identity "<GroupName>" -Properties GroupCategory, GroupScope
```
Expected: `GroupCategory = Security`, `GroupScope = Global` (global scope is required for PSO targeting and is the conventional, broadly-compatible choice for GPO security filtering as well).

**Step 2 — Compute the full desired-vs-actual membership diff**
```powershell
$actual   = (Get-ADGroupMember "<GroupName>").DistinguishedName
$expected = (Get-ADUser -SearchBase "<OU_DN>" -Filter *).DistinguishedName
Compare-Object $actual $expected | Group-Object SideIndicator
```
Expected: no differences on a healthy, currently-synced group. `<=` entries (in actual only) are stale; `=>` entries (in expected only) are missing.

**Step 3 — Confirm the sync mechanism's health directly, not by inference from group state**
Locate and check the scheduled task or tool job's own execution history — don't assume "group looks correct" means "sync is healthy," since a stopped sync task on an OU with zero recent membership changes can look identical to a working one until the next real change occurs.

**Step 4 — Confirm the sync account's delegation is exactly as narrow as intended**
```powershell
dsacls "<GroupDN>"
```
Expected: the sync account holds `Write member` (or the broader-but-still-narrow "Write All Properties" only if deliberately chosen) — flag anything broader (e.g., Full Control, or Domain Admins membership used as a shortcut) as a hygiene finding independent of whether sync is currently working.

**Step 5 — Confirm downstream consumer(s) reflect the corrected membership**
For a GPO consumer, `gpresult /r` on an affected machine after its next refresh; for a PSO consumer, `Get-ADUserResultantPasswordPolicy <user>` or check `msDS-ResultantPSO` directly.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Establish Ground Truth on the Defining Criteria
1. There is no native lookup for "what makes this a shadow group" — get the SearchBase or attribute filter from documentation, the group's `Description` field, or the group owner directly
2. Treat an undocumented shadow group as a finding, not just an obstacle — flag it for documentation as part of resolving the ticket

### Phase 2 — Isolate Membership Drift From Downstream Symptoms
1. Always compute the actual-vs-expected diff directly before assuming a GPO/PSO-side problem
2. A clean diff at this stage redirects the investigation entirely to the downstream consumer's own troubleshooting path (GPO or FGPP docs) — don't keep re-checking group membership once it's confirmed correct

### Phase 3 — Diagnose the Sync Mechanism Itself
1. Check the scheduled task/tool job's own execution history and any application-specific logging
2. Distinguish "job ran and reported success but wrote nothing" (points at Fix 3 / a permissions problem) from "job never ran at all" (points at Fix 1 / task configuration)

### Phase 4 — Confirm the Delegation Boundary Is Correct, Not Just Functional
1. Even after restoring sync functionality, verify the sync account's permission is scoped narrowly (member-attribute write only) rather than over-privileged as an expedient fix
2. An over-privileged sync account that "works" is still a finding worth raising, consistent with this repo's standing pattern of flagging over-broad permissions as security-relevant even when they aren't the ticket's root cause

### Phase 5 — Validate the Actual Business Outcome, Not Just the Group
1. Confirm the specific downstream effect the ticket was opened for (GPO applied correctly, PSO resolving correctly, ACL access correct) — a corrected group does not retroactively speed up whatever independent refresh/evaluation cycle the consumer itself runs on

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standing up a new shadow group correctly from scratch</summary>

**Scenario:** A GPO needs to apply to (or be excluded from) a subset of an OU's population, or a PSO needs to target users who live in a specific OU, and no shadow group exists yet.

**Step 1 — Create the group with the correct scope**
```powershell
New-ADGroup -Name "SG-<Purpose>" -GroupCategory Security -GroupScope Global `
  -Path "<OU_DN_for_the_group_object_itself>" `
  -Description "ShadowGroup: synced from OU=<SourceOU> — sync task: <TaskName>@<Host>, interval <X min>"
```
Documenting the source criteria and sync task location directly in `Description` closes the "nobody knows how this group works" gap this playbook's diagnosis phase exists to solve for future engineers.

**Step 2 — Delegate narrowly to the sync account**
```powershell
$acl = Get-Acl "AD:\$((Get-ADGroup 'SG-<Purpose>').DistinguishedName)"
$sid = (Get-ADServiceAccount -Identity "<SyncAccount>").SID   # or Get-ADUser for a standard service account
$rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
  $sid, "WriteProperty", "Allow", ([GUID]"bf9679c0-0de6-11d0-a285-00aa003049e2"))
$acl.AddAccessRule($rule)
Set-Acl "AD:\$((Get-ADGroup 'SG-<Purpose>').DistinguishedName)" $acl
```

**Step 3 — Build the reconciliation script (add AND remove), and schedule it**
```powershell
$desired = (Get-ADUser -SearchBase "<OU_DN>" -Filter *).DistinguishedName
$current = (Get-ADGroupMember -Identity "SG-<Purpose>").DistinguishedName
$toAdd    = $desired | Where-Object { $_ -notin $current }
$toRemove = $current | Where-Object { $_ -notin $desired }
if ($toAdd)    { Add-ADGroupMember    -Identity "SG-<Purpose>" -Members $toAdd }
if ($toRemove) { Remove-ADGroupMember -Identity "SG-<Purpose>" -Members $toRemove -Confirm:$false }
```
Register via `Register-ScheduledTask` running as the delegated sync account, on the interval appropriate to how quickly membership changes need to propagate (5-15 minutes for security-sensitive GPO scoping; nightly is often sufficient for slower-moving FGPP tiering).

**Step 4 — Point the actual consumer at the group**
For GPO: GPMC → GPO → Delegation tab → Advanced → add the group with Read + Apply Group Policy (and remove Authenticated Users if the intent is to *limit* scope, not extend it). For PSO: set `msDS-PSOAppliesTo` to the group's DN, never the OU's.

**Rollback note:** N/A — this is a greenfield build. If retiring later, see Playbook 2.

</details>

<details><summary>Playbook 2 — Retiring a shadow group safely</summary>

**Scenario:** A shadow group is no longer needed (the GPO/PSO it fed was retired, or the population it represented is now managed a different way).

**Step 1 — Confirm every downstream reference is removed first, not the group**
Check GPO security filtering (GPMC Delegation tabs across all GPOs, or `Get-GPO -All | Get-GPPermission` equivalent scripted sweep) and every PSO's `msDS-PSOAppliesTo` for a reference to this group before touching anything.

**Step 2 — Disable the scheduled sync task first, and observe for one full cycle**
Confirms nothing downstream breaks purely from staleness before the group itself is removed — a cheap, reversible checkpoint.

**Step 3 — Remove the group and its delegation**
```powershell
Remove-ADGroup -Identity "SG-<Purpose>" -Confirm:$false
```
The delegated ACE is removed automatically with the group object; no separate cleanup step is required for that specific permission.

**Rollback note:** Group deletion is not natively reversible without the AD Recycle Bin (see `Troubleshooting/BackupRestore/AD-BackupRestore-B.md` if the Recycle Bin is enabled and a restore is needed) — confirm Step 1 thoroughly before proceeding to Step 3.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Shadow Group Evidence Collector
.NOTES     Read-only. Run against a specific group + its stated source OU.
#>

param(
    [Parameter(Mandatory=$true)][string]$GroupName,
    [Parameter(Mandatory=$true)][string]$SourceOU
)

$reportPath = "C:\Temp\ShadowGroupEvidence_${GroupName}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== Group Properties ===" | Out-File "$reportPath\01_GroupProps.txt"
Get-ADGroup -Identity $GroupName -Properties GroupCategory, GroupScope, Description, whenChanged |
  Format-List | Out-File "$reportPath\01_GroupProps.txt" -Append

"=== Actual Current Membership ===" | Out-File "$reportPath\02_Actual.txt"
Get-ADGroupMember -Identity $GroupName | Select-Object Name, SamAccountName |
  Format-Table -AutoSize | Out-File "$reportPath\02_Actual.txt" -Append

"=== Expected Membership per Source OU ===" | Out-File "$reportPath\03_Expected.txt"
Get-ADUser -SearchBase $SourceOU -Filter * | Select-Object Name, SamAccountName |
  Format-Table -AutoSize | Out-File "$reportPath\03_Expected.txt" -Append

"=== Delegated Permissions on the Group ===" | Out-File "$reportPath\04_ACL.txt"
dsacls "$((Get-ADGroup $GroupName).DistinguishedName)" | Out-File "$reportPath\04_ACL.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Current group membership | `Get-ADGroupMember -Identity <Group>` |
| Compute expected membership from an OU | `Get-ADUser -SearchBase <OU_DN> -Filter *` |
| Compute expected membership from an attribute | `Get-ADUser -Filter "Title -eq '<Value>'" -Properties Title` |
| Diff actual vs. expected | `Compare-Object $actual $expected` |
| Reconcile (add + remove) | `Add-ADGroupMember` / `Remove-ADGroupMember` on the computed diff |
| Check scheduled sync task health | `Get-ScheduledTaskInfo -TaskName <Task>` |
| Check delegated permission on the group | `dsacls <GroupDN>` |
| Delegate member-attribute write narrowly | `New-Object ...ActiveDirectoryAccessRule(...)` + `Set-Acl AD:\<GroupDN>` |
| Confirm group scope/category (PSO/security-filter eligibility) | `Get-ADGroup -Identity <Group> -Properties GroupCategory,GroupScope` |
| Check resultant password policy for a user fed by a shadow group | `Get-ADUserResultantPasswordPolicy <user>` |
| Check GPO security filter membership | GPMC → GPO → Scope tab → Security Filtering |

---
## 🎓 Learning Pointers

- **Shadow groups are a practitioner pattern, not a Microsoft product feature.** There's no Learn page to cite as the authority because none exists — the authority is the underlying, well-documented constraint that GPO security filtering and FGPP/PSO targeting both require a security-principal object, never an OU. See [Group Policy processing for Windows](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/group-policy/group-policy-processing) for the GPO-side constraint and `Troubleshooting/FineGrainedPasswordPolicies/FGPP-A.md` for the PSO-side one.
- **Do not expect on-prem AD to behave like Entra ID here.** Entra ID's Dynamic Groups are a genuinely native, live-evaluated rule engine; on-prem AD has never had an equivalent, and every "dynamic" on-prem group is fundamentally a static group plus an external batch process. See `EntraID/Troubleshooting/DynamicGroups-A.md` for the cloud-side feature this is most often mistakenly assumed to have an on-prem twin.
- **Reconciliation, not addition, is the correct sync model.** Any implementation review of an existing shadow group should treat additive-only logic as a defect to fix, not a minor inefficiency — it causes one-directional privilege/policy creep that compounds over time.
- **This pattern has no self-healing anywhere in its chain**, unlike almost everything else it feeds into (GPO refresh cycles, live PSO resolution). Document the sync mechanism's location and schedule directly on the group object (`Description`) specifically because there is no other discoverable trace of it once the person who built it moves on.
- **The delegation boundary matters as much as functionality.** A working-but-over-privileged sync account is a standing risk worth flagging on sight, the same pattern this repo applies to over-broad replication rights in `Troubleshooting/RODC/RODC-A.md`.
- Related: [Shadow Groups: Active Directory's Dark Side](https://deployhappiness.com/shadow-groups-security-active-directory/), [GPO Security Filtering: How It Works, Configuration and Troubleshooting](https://www.manageengine.com/products/ad-manager/kb/gpo/what-is-group-policy-security-filtering.html), [Group Policy processing for Windows](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/group-policy/group-policy-processing)
