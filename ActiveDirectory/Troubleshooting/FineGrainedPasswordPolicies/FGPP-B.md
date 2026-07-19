# Fine-Grained Password Policies (FGPP / PSOs) — Hotfix Runbook (Mode B: Ops)
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

Run these from an elevated PowerShell session with the ActiveDirectory module (RSAT), on a DC or management host:

```powershell
# 1. Query the actual effective policy for the affected user — always start here
Get-ADUserResultantPasswordPolicy -Identity "<UserName>"

# 2. See the computed resultant PSO directly on the user object
Get-ADUser -Identity "<UserName>" -Properties msDS-ResultantPSO | Select-Object Name, msDS-ResultantPSO

# 3. List every PSO in the domain with its precedence
Get-ADFineGrainedPasswordPolicy -Filter * -Properties msDS-PasswordSettingsPrecedence |
  Select-Object Name, Precedence | Sort-Object Precedence

# 4. Check what a specific PSO is actually targeted at
Get-ADFineGrainedPasswordPolicySubject -Identity "<PSOName>"

# 5. Check for precedence collisions across all PSOs
Get-ADFineGrainedPasswordPolicy -Filter * -Properties msDS-PasswordSettingsPrecedence |
  Group-Object Precedence | Where-Object Count -gt 1
```

| What you see | What it means |
|---|---|
| `Get-ADUserResultantPasswordPolicy` returns `$null` / nothing | No PSO applies to this user — they're on the domain-wide GPO-based default. If a PSO was expected, go to Fix 1 or Fix 2 |
| It returns the wrong PSO | Another PSO with lower `msDS-PasswordSettingsPrecedence`, or a directly-linked PSO, is beating the intended one — go to Fix 3 |
| `Get-ADFineGrainedPasswordPolicySubject` lists an OU distinguishedName, or lists nothing at all | **PSO was targeted at an OU, which is not valid** — this is the #1 real-world FGPP misconfiguration — go to Fix 1 |
| Step 3's precedence-collision query returns any groups | Two PSOs share the same precedence value for overlapping users — an unsupported GUID tie-break is deciding the winner unpredictably — go to Fix 4 |
| PSO targets look correct, user is a confirmed group member, but policy still hasn't applied | Group membership hasn't replicated to the DC being queried yet, or the group isn't Global Security scope — go to Fix 2 |
| Non-Domain-Admin staff get access-denied trying to manage a PSO | Password Settings Container delegation is separate from OU delegation and wasn't granted — go to Fix 5 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Domain functional level >= Windows Server 2012
  └── Password Settings Container exists (hidden from default ADUC view)
        └── PSO created with Name + Precedence set
              └── msDS-PSOAppliesTo targets USERS or GLOBAL SECURITY GROUPS ONLY (never an OU)
                    └── User is a current, replicated member of a targeted group (or directly targeted)
                          └── Direct-linked PSOs beat group-linked PSOs; among group-linked,
                              LOWEST msDS-PasswordSettingsPrecedence wins
                                └── msDS-ResultantPSO on the user object reflects the actual winner
                                      └── If nothing applies: silent fallback to the domain-wide
                                          GPO-based Default Domain Policy password settings
```

Key failure points:
- PSO linked to an OU instead of a user/group — silently applies to nobody, no error
- Direct-linked PSO on one user in a group overriding the group's PSO unexpectedly — looks like "it works for everyone except this one person"
- Two PSOs sharing the same precedence value — unpredictable GUID tie-break, not a supported state
- Password Settings Container ACL delegation not extending from OU-level delegation

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Get the actual effective policy, don't manually trace it**
```powershell
Get-ADUserResultantPasswordPolicy -Identity "<UserName>"
```
Expected: the PSO that should apply, or `$null` if the user is correctly on the domain-wide fallback. This single command answers most "wrong password policy" tickets.

**Step 2 — Confirm what the intended PSO is actually targeted at**
```powershell
Get-ADFineGrainedPasswordPolicySubject -Identity "<PSOName>"
```
Expected: only user or Global Security group objects. An OU here (or an empty result) means the targeting itself is broken.

**Step 3 — Confirm the user's actual group membership and its scope/category**
```powershell
Get-ADGroupMember -Identity "<TargetGroupName>" | Select-Object Name
Get-ADGroup -Identity "<TargetGroupName>" | Select-Object GroupScope, GroupCategory
```
Expected: `GroupScope = Global`, `GroupCategory = Security`, and the affected user listed as a current member.

**Step 4 — Check whether the user has a directly-linked PSO overriding the group-based one**
```powershell
Get-ADUser -Identity "<UserName>" -Properties msDS-ResultantPSO
```

**Step 5 — Compare precedence across every PSO that could apply to this user**
```powershell
Get-ADFineGrainedPasswordPolicy -Filter * -Properties msDS-PasswordSettingsPrecedence |
  Select-Object Name, Precedence | Sort-Object Precedence
```
Lowest number wins among group-linked PSOs (direct links always win regardless of number).

---
## Common Fix Paths

<details><summary>Fix 1 — PSO was targeted at an OU (invalid) instead of a user/group</summary>

**Cause:** `msDS-PSOAppliesTo` only accepts user and Global Security group objects. An OU distinguishedName here silently applies to nobody — no error is raised at creation time if this was done via script/`-OtherAttributes` rather than the ADAC UI (which prevents it).

```powershell
# Create (or reuse) a Global Security group representing the intended population
New-ADGroup -Name "PSO-<Purpose>-Group" -GroupScope Global -GroupCategory Security

# Populate it from the OU (one-time sync — new OU members won't auto-join later)
Get-ADUser -Filter * -SearchBase "OU=<TargetOU>,DC=<domain>" |
  ForEach-Object { Add-ADGroupMember -Identity "PSO-<Purpose>-Group" -Members $_.SamAccountName }

# Point the PSO at the group instead
Add-ADFineGrainedPasswordPolicySubject -Identity "<PSOName>" -Subjects "PSO-<Purpose>-Group"
```

**Rollback note:** Removing the group as a subject reverts affected users to whatever next applies (another PSO, or the domain-wide fallback). No impact on already-set passwords.

</details>

<details><summary>Fix 2 — Group membership hasn't replicated, or wrong group type used</summary>

**Cause:** The user was just added to the target group and replication to the queried DC hasn't caught up, or the group is Domain Local/Universal/Distribution instead of Global Security (only Global Security groups are valid PSO targets).

```powershell
# Confirm group type
Get-ADGroup -Identity "<TargetGroupName>" | Select-Object GroupScope, GroupCategory

# If wrong scope/category, this requires recreating as Global Security — GroupScope conversions
# have their own AD rules and may not be directly convertible depending on current membership
```

**Rollback note:** No destructive action here — confirm and wait for replication, or correct the group type as a planned change.

</details>

<details><summary>Fix 3 — Wrong PSO winning due to precedence or direct-link override</summary>

**Cause:** Either another group-linked PSO has a lower `msDS-PasswordSettingsPrecedence` value, or the affected user has a PSO linked *directly* to them (direct always beats group-linked, regardless of precedence number).

```powershell
# Check for a direct link on the specific user
Get-ADFineGrainedPasswordPolicy -Filter * | ForEach-Object {
  $subj = Get-ADFineGrainedPasswordPolicySubject -Identity $_.Name
  if ($subj.Name -contains "<UserName>") { $_.Name }
}

# If found and unintended, remove the direct link
Remove-ADFineGrainedPasswordPolicySubject -Identity "<UnintendedPSOName>" -Subjects "<UserName>"

# If it's a precedence issue instead, adjust the intended PSO's precedence lower
Set-ADFineGrainedPasswordPolicy -Identity "<IntendedPSOName>" -Precedence <lowerNumber>
```

**Rollback note:** Both operations are reversible — re-add the subject or restore the prior precedence value.

</details>

<details><summary>Fix 4 — Precedence collision between two PSOs</summary>

**Cause:** Two PSOs share the identical `msDS-PasswordSettingsPrecedence` value and both apply to an overlapping population. AD resolves this via GUID comparison, which is not administrator-controllable or predictable — treat this as a bug, not a valid configuration.

```powershell
# Identify the colliding PSOs
Get-ADFineGrainedPasswordPolicy -Filter * -Properties msDS-PasswordSettingsPrecedence |
  Group-Object Precedence | Where-Object Count -gt 1 | Select-Object -ExpandProperty Group

# Renumber one of them to a unique value
Set-ADFineGrainedPasswordPolicy -Identity "<PSOName>" -Precedence <uniqueValue>
```

**Rollback note:** Precedence is a simple integer attribute — safe to adjust and re-adjust with no data risk. Re-verify with `Get-ADUserResultantPasswordPolicy` against a sample of affected users afterward.

</details>

<details><summary>Fix 5 — Delegated admin can't manage PSOs despite OU-level rights</summary>

**Cause:** The Password Settings Container has its own ACL, separate from any OU delegation. It's also hidden from the default ADUC view, so this is frequently never delegated at all.

```powershell
# View current ACL on the container (run from a DC or with the AD PowerShell provider)
$path = "AD:\CN=Password Settings Container,CN=System,DC=<domain>,DC=<tld>"
Get-Acl -Path $path | Select-Object -ExpandProperty Access

# Delegate via the Delegation of Control Wizard in ADAC/ADUC pointed specifically at this
# container, or script an ACE grant for the target group — do not attempt to infer this
# from OU-level delegation, it does not carry over
```

**Rollback note:** ACL changes are reversible by removing the added ACE. Prefer using the Delegation of Control Wizard over hand-editing ACEs to avoid inheritance mistakes.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Fine-Grained Password Policy (FGPP) Issue

Affected user(s): ____________
Expected PSO: ____________
PSO actually returned by Get-ADUserResultantPasswordPolicy: ____________

Get-ADFineGrainedPasswordPolicySubject output for expected PSO: ____________
Target group scope/category confirmed Global/Security: (Yes/No)
User confirmed current member of target group: (Yes/No)
Direct-linked PSO found on user (Yes/No): ____________
Precedence collision found across domain (Yes/No): ____________
Password Settings Container delegation confirmed for requesting admin: (Yes/No/N-A)

Steps already attempted:
[ ] Get-ADUserResultantPasswordPolicy run against affected user
[ ] PSO subject/target list confirmed (users/groups only, no OU)
[ ] Group scope/category and membership replication confirmed
[ ] Checked for a directly-linked PSO overriding the group-based one
[ ] Checked for precedence collisions across all domain PSOs
```

---
## 🎓 Learning Pointers

- **`Get-ADUserResultantPasswordPolicy` is always the first command to run**, not a last resort — it does the full precedence-tracing exercise for you in one call.
- **A PSO targeted at an OU silently applies to nobody.** This is the single most common FGPP misconfiguration and produces zero error messages anywhere — always confirm targets with `Get-ADFineGrainedPasswordPolicySubject` before assuming a deeper bug.
- **Direct-linked PSOs always override group-linked ones**, independent of the numeric precedence value — precedence only breaks ties among PSOs applied via group membership.
- **Precedence collisions are a real, reproducible bug class**, not a rare edge case — always check for duplicate precedence values across PSOs sharing a target population when results look inconsistent.
- **The Password Settings Container is invisible in default ADUC** — a delegated admin who manages an OU fine may still be fully blocked from PSO management with no obvious reason why, until this specific container's ACL is checked.
- Related: [Configure fine grained password policies for Active Directory Domain Services](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/get-started/adac/fine-grained-password-policies)
