# Fine-Grained Password Policies (FGPP / PSOs) — Reference Runbook (Mode A: Deep Dive)
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
- Fine-Grained Password Policies (FGPP), implemented as Password Settings Objects (PSO) — multiple password/lockout policies within a single domain
- The Password Settings Container, PSO precedence resolution, and direct-vs-group application
- `Get-ADUserResultantPasswordPolicy` / `msDS-ResultantPSO` effective-policy resolution
- Delegating FGPP management below Domain Admins

**Out of scope:**
- The single domain-wide password policy set via the Default Domain Policy GPO — covered here only as the fallback FGPP defers to, not as a GPO-processing topic (see `ActiveDirectory/Troubleshooting/GroupPolicy/AD-GroupPolicy-A.md` for GPO processing itself)
- Entra ID password protection / Smart Lockout / cloud-side password policies (a completely separate, cloud-native system — see `EntraID/`)
- Azure AD Password Protection (on-premises DC agent that blocks weak/banned passwords) — a related but distinct feature from FGPP; not covered here
- LAPS / local administrator password rotation (see `Intune/Troubleshooting/LAPS-A.md`) — LAPS manages local built-in admin account passwords, not domain user password *policy*

**Assumptions:**
- Domain functional level is Windows Server 2012 or higher (required for FGPP)
- You have Domain Admins membership or a delegated equivalent to manage Password Settings Objects
- The `ActiveDirectory` PowerShell module (RSAT) or Active Directory Administrative Center (ADAC) is available

---
## How It Works

<details><summary>Full architecture — PSO objects, precedence, and resultant policy calculation</summary>

### The Problem FGPP Solves

Before Windows Server 2008, a domain could have exactly **one** password and account lockout policy, set via the Default Domain Policy GPO and applied uniformly to every user in the domain. Any org wanting stricter rules for privileged accounts or service accounts, and looser rules for general staff, had no native way to do it short of a second domain. Fine-Grained Password Policies remove that constraint: multiple **Password Settings Objects (PSOs)** can coexist in a single domain, each specifying its own complexity, length, history, age, and lockout settings, targeted at different sets of users.

### Password Settings Objects (PSOs) and the Password Settings Container

Every PSO is an `msDS-PasswordSettings` object stored in a dedicated, non-visible-by-default container: `CN=Password Settings Container,CN=System,DC=<domain>`. This container is not exposed in the standard Active Directory Users and Computers snap-in — it's only visible via ADAC's System > Password Settings Container node, ADSI Edit, or PowerShell. This is itself a common real-world confusion: an engineer familiar only with the classic ADUC console may not know FGPP exists in the domain at all until told to look elsewhere.

### What a PSO Can Target — Users and Global Security Groups Only

**The single most important architectural constraint to internalize: a PSO's `msDS-PSOAppliesTo` attribute can only reference user objects and global security security groups — never an Organizational Unit directly.** This trips up almost everyone coming from a GPO mental model, where OU-linking is the default targeting mechanism. To apply a PSO "to an OU," the correct pattern is: create a global security group, populate it with the users who happen to live in that OU (or better, use it as the actual membership boundary going forward), and link the PSO to the group — not the OU.

### Precedence — How Conflicts Resolve

When more than one PSO's `msDS-PSOAppliesTo` includes a given user — either directly, or via more than one group the user belongs to — Active Directory must pick exactly one PSO as the Resultant Set of Policy (RSoP) for that user. The rule is governed by the `msDS-PasswordSettingsPrecedence` integer attribute: **the PSO with the lowest Precedence value wins.** There is no averaging, no merging of individual settings from multiple PSOs — the entire winning PSO's settings apply as a unit, and every losing PSO's settings for that user are ignored in full. Microsoft's own guidance recommends spacing precedence values in multiples of 10 or 100 (e.g., 100, 200, 300) specifically so a new policy can later be inserted between two existing ones without renumbering everything.

A secondary tie-breaking rule applies only when two PSOs somehow have the *same* precedence value for the same user (a misconfiguration, not a supported design): the PSO with the lexicographically smaller GUID wins, which is effectively unpredictable from an administrator's perspective — precedence collisions should always be treated as a configuration error to fix, not a tie-break to rely on.

### Direct-vs-Group Resolution Order

If a PSO is linked **directly** to a user object (not via a group), any directly-linked PSO takes precedence over every group-linked PSO for that user, regardless of precedence values — direct application is the strongest form of targeting. Only when no PSO is directly linked to the user does AD fall back to comparing the precedence values of every PSO applied via the user's global security group memberships.

### The Resultant Policy — `msDS-ResultantPSO` and `Get-ADUserResultantPasswordPolicy`

Rather than requiring an administrator to manually trace every PSO a user might be a member of and compare precedence by hand, Windows Server exposes a **computed, read-only attribute directly on the user object**: `msDS-ResultantPSO`, which contains the distinguished name of the PSO that actually applies to that user right now (or is empty if none applies, meaning the domain-wide GPO-based policy is the fallback). The `Get-ADUserResultantPasswordPolicy` cmdlet is the supported way to query this — it returns the full effective policy object, not just the winning PSO's name, saving the precedence-tracing exercise entirely. **This should always be the first diagnostic step**, not a last resort — most "why does this user have the wrong password policy" tickets are solved in one command.

### Fallback — The Domain-Wide GPO Policy Still Exists

If no PSO applies to a user at all (directly or via any group), the user falls back to the single domain-wide password/lockout policy defined in the Default Domain Policy GPO (the classic, pre-2008 mechanism). FGPP does not replace this policy — it only layers additional, higher-priority exceptions on top of it for specific users/groups. This fallback is itself a common source of "why didn't my PSO apply" tickets: if the intended group link or precedence didn't take effect as expected, the user simply reverts silently to the domain default with no error anywhere.

### Delegation Model

By default, only members of Domain Admins can create, modify, or delete PSOs. This can be delegated to a narrower group (e.g., a Tier-1 helpdesk group that should never actually hold full Domain Admins) via standard AD ACL delegation on the Password Settings Container — a detail frequently missed because the container isn't visible in the default ADUC view, so admins delegate access to visible OUs and are then surprised the delegation doesn't extend to PSOs.

</details>

---
## Dependency Stack

```
Domain functional level >= Windows Server 2012
  └── Password Settings Container exists (CN=Password Settings Container,CN=System,DC=...)
        └── PSO (msDS-PasswordSettings object) created with required Name + Precedence
              └── msDS-PSOAppliesTo set to one or more users and/or GLOBAL SECURITY GROUPS
                    (never an OU directly — this is the #1 real-world misconfiguration)
                          └── User is a member of a targeted group, or directly targeted
                                └── If multiple PSOs apply: direct-link PSOs beat group-link PSOs;
                                    among group-link PSOs, lowest msDS-PasswordSettingsPrecedence wins
                                      └── msDS-ResultantPSO computed on the user object reflects the winner
                                            └── If NO PSO applies at all, user falls back to the single
                                                domain-wide GPO-based Default Domain Policy password settings
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| PSO created and linked, but user still shows the old/default policy | PSO was linked to an OU instead of a user or global security group — this silently fails, no error is raised | `Get-ADFineGrainedPasswordPolicySubject -Identity "<PSOName>"` — confirm only users/groups are listed |
| User is in the intended group but the wrong PSO still applies | A different PSO with lower `msDS-PasswordSettingsPrecedence` also applies to the user via another group | `Get-ADUserResultantPasswordPolicy -Identity "<user>"` then trace both PSOs' precedence values |
| PSO applies correctly to most group members but not one specific user | That user also has a PSO linked *directly* — direct links always beat group-linked PSOs regardless of precedence | `Get-ADUser -Identity "<user>" -Properties msDS-ResultantPSO`; check for a directly-linked PSO |
| New PSO seems to have no effect on anyone | Group membership hasn't replicated yet to the DC being queried, or the group used is a Domain Local / Universal group instead of Global Security | Confirm `GroupScope` is `Global` and `GroupCategory` is `Security`; check replication convergence |
| Two PSOs both claim to apply and results seem inconsistent between queries | Precedence collision — two PSOs share the same `msDS-PasswordSettingsPrecedence` value for the same user (unsupported, GUID tie-break applies) | `Get-ADFineGrainedPasswordPolicy -Filter *` and check for duplicate Precedence values across PSOs that share a target |
| Non-Domain-Admin staff can't create/edit PSOs even though they manage the relevant OU | PSO delegation is separate from and not inherited by OU-level delegation — the Password Settings Container needs its own ACL delegation | Check ACL on `CN=Password Settings Container,CN=System,DC=...` |
| PSO exists and looks correctly targeted, but `Get-ADUserResultantPasswordPolicy` returns nothing | No PSO applies to this user at all — confirm the fallback (domain-wide GPO policy) is actually the expected outcome, not a misconfiguration | Compare `msDS-PSOAppliesTo` membership against the actual user/group, checking for typos or the wrong group entirely |
| Password policy was recently tightened via FGPP but users report they can still set old, weak passwords | Client cached credentials, or the PSO's `ComplexityEnabled`/`MinPasswordLength` was set but the user hasn't been prompted for a password change since (policy applies at next password set, not retroactively) | Confirm PSO settings are correct, then force a password change (`Set-ADUser -ChangePasswordAtLogon $true`) to test |
| Fine-grained lockout policy seems more/less strict than expected compared to domain default | Domain default GPO lockout settings and the PSO's lockout settings are independent — a PSO does not "adjust" the domain default, it fully replaces it for the users it covers | `Get-ADUserResultantPasswordPolicy` shows lockout threshold/duration actually in effect |

---
## Validation Steps

**Step 1 — Confirm domain functional level supports FGPP**
```powershell
Get-ADDomain | Select-Object DomainMode
```
Expected: `Windows2012Domain` or higher.

**Step 2 — List every PSO in the domain and its precedence/targets**
```powershell
Get-ADFineGrainedPasswordPolicy -Filter * -Properties msDS-PasswordSettingsPrecedence |
  Select-Object Name, Precedence, ComplexityEnabled, MinPasswordLength, MaxPasswordAge |
  Sort-Object Precedence
```

**Step 3 — Confirm what each PSO is applied to**
```powershell
Get-ADFineGrainedPasswordPolicy -Filter * | ForEach-Object {
  [PSCustomObject]@{
    PSO     = $_.Name
    Targets = (Get-ADFineGrainedPasswordPolicySubject -Identity $_.Name | Select-Object -ExpandProperty Name) -join ", "
  }
}
```
Expected: every target listed is a user or a **Global Security** group — never an OU.

**Step 4 — Query the actual resultant policy for a specific affected user**
```powershell
Get-ADUserResultantPasswordPolicy -Identity "<UserName>"
```
Expected: returns the winning PSO's full policy object, or `$null` if the domain-wide fallback applies. **This is the single authoritative answer — always run this before manually tracing precedence.**

**Step 5 — Confirm the computed resultant PSO attribute directly on the user object**
```powershell
Get-ADUser -Identity "<UserName>" -Properties msDS-ResultantPSO |
  Select-Object Name, msDS-ResultantPSO
```

**Step 6 — For a group-based PSO, confirm membership has actually replicated**
```powershell
Get-ADGroupMember -Identity "<TargetGroupName>" | Select-Object Name, ObjectClass
```

**Step 7 — Check for precedence collisions across the domain**
```powershell
Get-ADFineGrainedPasswordPolicy -Filter * -Properties msDS-PasswordSettingsPrecedence |
  Group-Object Precedence | Where-Object Count -gt 1
```
Expected: no groups returned. Any result here means two PSOs share a precedence value — a misconfiguration to fix, not a valid tie-break to rely on.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Functional Level / Container Layer
1. Confirm domain functional level is Server 2012 or higher — FGPP simply doesn't exist below this
2. Confirm the Password Settings Container exists and is reachable (it's created automatically at the required functional level, but verify if this domain was ever downgraded/rebuilt unusually)

### Phase 2 — Targeting Layer
1. Confirm the PSO's `msDS-PSOAppliesTo` lists users or **Global Security groups only** — an OU listed here (via a misunderstanding, since ADAC's UI won't actually let this happen, but scripted/OtherAttributes-based creation can) will silently apply to nobody
2. Confirm the group used is `GroupScope: Global` and `GroupCategory: Security` — Domain Local and Universal groups, and Distribution groups, are not valid PSO targets
3. Confirm the affected user is actually a current, replicated member of the target group

### Phase 3 — Precedence Resolution Layer
1. Run `Get-ADUserResultantPasswordPolicy` first, always — don't manually trace precedence until this doesn't answer the question
2. If the wrong PSO wins, check for a directly-linked PSO on the user first (direct always beats group-linked, independent of precedence number)
3. If no direct link exists, compare `msDS-PasswordSettingsPrecedence` across every PSO the user's groups pull in — lowest number wins
4. Check for precedence collisions (two PSOs sharing the same value) — treat any hit as a bug to fix, not a valid state

### Phase 4 — Fallback / Domain-Wide Policy Layer
1. If `Get-ADUserResultantPasswordPolicy` returns nothing, confirm this is the *expected* outcome (user genuinely shouldn't have a custom PSO) rather than a targeting miss
2. Confirm the domain-wide GPO-based Default Domain Policy password settings are themselves correct, since this is the fallback every un-targeted user receives

### Phase 5 — Delegation Layer (if non-Domain-Admin staff report access-denied managing PSOs)
1. Confirm the requesting account's delegated rights are on the Password Settings Container specifically — OU-level delegation does not extend here
2. Check the ACL directly via ADSI Edit or `Get-Acl` against the AD provider path for the container

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standing up a new tier of password policy (e.g., stricter policy for admin accounts)</summary>

**Scenario:** The org wants a stricter password policy (longer minimum length, shorter max age) applied only to a defined set of privileged accounts, without changing the domain-wide default for everyone else.

**Step 1 — Create a dedicated Global Security group for the target population**
```powershell
New-ADGroup -Name "PSO-PrivilegedAccounts" -GroupScope Global -GroupCategory Security
Add-ADGroupMember -Identity "PSO-PrivilegedAccounts" -Members "admin.jsmith","admin.mwong"
```

**Step 2 — Create the PSO, targeted at the group, with a precedence lower than any general-population PSO**
```powershell
New-ADFineGrainedPasswordPolicy -Name "PSO-PrivilegedAccounts-Policy" `
  -Precedence 100 `
  -ComplexityEnabled $true `
  -MinPasswordLength 16 `
  -MaxPasswordAge "60.00:00:00" `
  -MinPasswordAge "1.00:00:00" `
  -PasswordHistoryCount 24 `
  -LockoutThreshold 5 `
  -LockoutDuration "0.01:00:00" `
  -LockoutObservationWindow "0.00:30:00"

Add-ADFineGrainedPasswordPolicySubject -Identity "PSO-PrivilegedAccounts-Policy" -Subjects "PSO-PrivilegedAccounts"
```

**Step 3 — Validate against an actual member**
```powershell
Get-ADUserResultantPasswordPolicy -Identity "admin.jsmith"
```
Expected: returns `PSO-PrivilegedAccounts-Policy`, not the domain default.

**Rollback note:** Removing the PSO (`Remove-ADFineGrainedPasswordPolicy`) or removing users from the target group reverts affected accounts to the next-highest-precedence applicable PSO, or the domain-wide fallback if none remain. Non-destructive to any password already set — existing passwords remain valid until their next required change under the *new* effective policy.

</details>

<details><summary>Playbook 2 — Adding a new, intermediate-precedence policy without renumbering existing PSOs</summary>

**Scenario:** Two PSOs exist with precedence 100 and 200. A new policy needs to sit between them in priority.

**Step 1 — Confirm current precedence values leave room**
```powershell
Get-ADFineGrainedPasswordPolicy -Filter * -Properties msDS-PasswordSettingsPrecedence |
  Select-Object Name, Precedence | Sort-Object Precedence
```

**Step 2 — Create the new PSO with a precedence value between the two**
```powershell
New-ADFineGrainedPasswordPolicy -Name "PSO-Intermediate-Policy" -Precedence 150 `
  -ComplexityEnabled $true -MinPasswordLength 12 -MaxPasswordAge "90.00:00:00"
```

**Rollback note:** This is why Microsoft's guidance is to space initial precedence values in multiples of 10 or 100 — if values are instead assigned sequentially (1, 2, 3...) with no gaps, inserting a new intermediate policy later requires renumbering every PSO with a value at or above the insertion point, which is disruptive and easy to get wrong under time pressure. If already in that situation, renumber during a maintenance window and re-verify `Get-ADUserResultantPasswordPolicy` against a sample of affected users afterward.

</details>

<details><summary>Playbook 3 — Migrating from "OU-based" thinking to correct group-based PSO targeting</summary>

**Scenario:** An admin new to FGPP has tried to link a PSO to an OU (via `Set-ADFineGrainedPasswordPolicy -OtherAttributes` or a scripted approach bypassing ADAC's validation) and it silently has no effect.

**Step 1 — Confirm the PSO's actual current targets**
```powershell
Get-ADFineGrainedPasswordPolicySubject -Identity "<PSOName>"
```
If this returns nothing, or returns an OU distinguishedName that doesn't resolve as a valid subject, this confirms the misconfiguration.

**Step 2 — Create (or identify an existing) Global Security group that represents the same population as the OU**
```powershell
New-ADGroup -Name "PSO-<Purpose>-Group" -GroupScope Global -GroupCategory Security
Get-ADUser -Filter * -SearchBase "OU=<TargetOU>,DC=<domain>" |
  ForEach-Object { Add-ADGroupMember -Identity "PSO-<Purpose>-Group" -Members $_.SamAccountName }
```
Note: this is a point-in-time membership sync, not a live link — new users added to the OU later will **not** automatically join the group unless a separate process (script, Entra Dynamic Group equivalent doesn't apply on-prem, or manual process) keeps them in sync. Document this as an ongoing operational responsibility.

**Step 3 — Correct the PSO's targeting**
```powershell
Add-ADFineGrainedPasswordPolicySubject -Identity "<PSOName>" -Subjects "PSO-<Purpose>-Group"
```

**Rollback note:** Removing the group as a subject (`Remove-ADFineGrainedPasswordPolicySubject`) reverts affected users to whatever next applies — no impact on already-set passwords.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Fine-Grained Password Policy Evidence Collector
.NOTES     Run with rights to read PSOs and the Password Settings Container.
#>

$reportPath = "C:\Temp\FGPPEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== Domain Functional Level ===" | Out-File "$reportPath\01_DomainMode.txt"
Get-ADDomain | Select-Object DomainMode | Format-List | Out-File "$reportPath\01_DomainMode.txt" -Append

"=== All PSOs (Precedence order) ===" | Out-File "$reportPath\02_AllPSOs.txt"
Get-ADFineGrainedPasswordPolicy -Filter * -Properties msDS-PasswordSettingsPrecedence |
  Sort-Object Precedence | Format-List |
  Out-File "$reportPath\02_AllPSOs.txt" -Append

"=== PSO Targets ===" | Out-File "$reportPath\03_PSOTargets.txt"
Get-ADFineGrainedPasswordPolicy -Filter * | ForEach-Object {
  "--- $($_.Name) ---" | Out-File "$reportPath\03_PSOTargets.txt" -Append
  Get-ADFineGrainedPasswordPolicySubject -Identity $_.Name |
    Format-List | Out-File "$reportPath\03_PSOTargets.txt" -Append
}

"=== Resultant Policy for Named User (if supplied) ===" | Out-File "$reportPath\04_ResultantPolicy.txt"
# Replace <UserName> before running interactively
Get-ADUserResultantPasswordPolicy -Identity "<UserName>" -ErrorAction SilentlyContinue |
  Format-List | Out-File "$reportPath\04_ResultantPolicy.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| List all PSOs with precedence | `Get-ADFineGrainedPasswordPolicy -Filter * -Properties msDS-PasswordSettingsPrecedence` |
| Create a new PSO | `New-ADFineGrainedPasswordPolicy -Name "<Name>" -Precedence <n> -MinPasswordLength <n> ...` |
| View a PSO's targets | `Get-ADFineGrainedPasswordPolicySubject -Identity "<PSOName>"` |
| Apply a PSO to a user/group | `Add-ADFineGrainedPasswordPolicySubject -Identity "<PSOName>" -Subjects "<UserOrGroup>"` |
| Remove a PSO's application | `Remove-ADFineGrainedPasswordPolicySubject -Identity "<PSOName>" -Subjects "<UserOrGroup>"` |
| Query effective policy for a user | `Get-ADUserResultantPasswordPolicy -Identity "<UserName>"` |
| View the computed resultant PSO on a user | `Get-ADUser -Identity "<UserName>" -Properties msDS-ResultantPSO` |
| Edit an existing PSO | `Set-ADFineGrainedPasswordPolicy -Identity "<PSOName>" -MinPasswordLength <n>` |
| Delete a PSO | `Remove-ADFineGrainedPasswordPolicy -Identity "<PSOName>"` |
| Check domain functional level (FGPP requires 2012+) | `Get-ADDomain \| Select DomainMode` |

---
## 🎓 Learning Pointers

- **A PSO can only target users and Global Security groups — never an OU directly.** This is the single most common real-world FGPP misconfiguration for admins coming from a GPO background, where OU-linking is the default mental model. [Configure fine grained password policies for Active Directory Domain Services](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/get-started/adac/fine-grained-password-policies)
- **Always run `Get-ADUserResultantPasswordPolicy` first.** It's a purpose-built cmdlet that does the entire precedence-tracing exercise for you — manually comparing PSOs by hand is slower and more error-prone.
- **Direct-linked PSOs always beat group-linked PSOs**, independent of the numeric precedence value. Precedence only breaks ties *among* group-linked PSOs.
- **Precedence values should be spaced (100, 200, 300...), not sequential.** This avoids a disruptive renumbering exercise the first time a new intermediate-priority policy needs to be inserted. [New-ADFineGrainedPasswordPolicy](https://learn.microsoft.com/en-us/powershell/module/activedirectory/new-adfinegrainedpasswordpolicy)
- **FGPP does not replace the domain-wide GPO password policy — it layers on top of it.** Any user with no applicable PSO silently falls back to the classic Default Domain Policy settings, with no error or warning anywhere.
- **The Password Settings Container isn't visible in the default ADUC console.** An admin unaware of this may not realize FGPP is in use in a domain at all, or may delegate OU-level rights and be confused when that delegation doesn't extend to PSO management — the container needs its own explicit ACL delegation.
