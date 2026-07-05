# Conditional Access Policy Rollout — Hotfix Runbook (Mode B: Ops)
> You're about to deploy/edit a CA policy, or just did and something's wrong. Catch it or fix it in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Use this when a **new or recently-edited** CA policy is the suspected cause — not for a long-standing policy suddenly blocking someone (see `CA-Troubleshooting-B.md` for that).

```powershell
Connect-MgGraph -Scopes "Policy.Read.All","AuditLog.Read.All" -NoWelcome

# 1. Find what changed recently — CA policies modified in the last 24h
Get-MgIdentityConditionalAccessPolicy -All |
    Select-Object DisplayName, State, Id, CreatedDateTime, ModifiedDateTime |
    Where-Object { $_.ModifiedDateTime -gt (Get-Date).AddHours(-24) } |
    Sort-Object ModifiedDateTime -Descending

# 2. Is the policy actually enforcing, or still Report-Only?
Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '<PolicyName>'" |
    Select-Object DisplayName, State

# 3. Who does the policy actually target (not who you intended)?
$p = Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '<PolicyName>'"
$p.Conditions.Users | Select-Object IncludeUsers, IncludeGroups, ExcludeUsers, ExcludeGroups, IncludeRoles

# 4. Are break-glass accounts excluded?
$breakGlassUpns = @("<breakglass1@domain.com>","<breakglass2@domain.com>")
$bgIds = $breakGlassUpns | ForEach-Object { (Get-MgUser -UserId $_).Id }
$bgIds | ForEach-Object { if ($_ -notin $p.Conditions.Users.ExcludeUsers) { "MISSING EXCLUSION: $_" } }
```

**Interpretation:**

| Finding | Action |
|---------|--------|
| `State = enabled` and policy was edited minutes before tickets started | → Fix 1: Roll back to Report-Only immediately |
| Policy includes `All users` with no group scoping and no exclusions | → Fix 2: Scope with a pilot group before wide rollout |
| Break-glass account not in `ExcludeUsers` | → Fix 3: Add break-glass exclusion NOW, before touching anything else |
| Policy's Client Apps condition missing legacy auth clients | → Fix 4: Add legacy auth clients or confirm it's intentionally excluded |
| Grant controls conflict with another enabled policy | → Fix 5: Resolve overlapping policy scope |

---

## Dependency Cascade

<details><summary>What must be true before a new CA policy is safe to enforce</summary>

```
Break-glass accounts exist and are cloud-only, MFA-exempt, credentials sealed
  └── Break-glass accounts explicitly excluded from EVERY enabled policy (new and existing)
        └── New policy authored with correct Users/Groups/Roles scope
              └── New policy's Conditions correctly scope apps, platforms, locations, client apps
                    └── New policy deployed in State = "Report-only" FIRST
                          └── Sign-in logs monitored (CA Result column) for a representative period
                                └── No unexpected "failure" results against real users in scope
                                      └── Policy promoted to State = "On"
                                            └── Post-enforcement monitoring window (watch for helpdesk spike)
                                                  └── If stable: rollout complete
                                                  └── If not: rollback to Report-only, re-diagnose
```

**Key interlock:** Skipping the Report-only step is the single most common cause of mass lockout incidents. A policy that "looks correct" on paper can still match unintended users because group membership, device compliance state, or legacy auth usage wasn't what the author assumed.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the policy's actual enforcement state**
```powershell
Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '<PolicyName>'" | Select-Object DisplayName, State
```
*Good:* `Report-only` while still validating, or `On` only after a clean Report-only period.
*Bad:* `On` immediately after creation with no prior Report-only run — the policy has never been validated against real traffic.

---

**Step 2 — Run What If against a representative real user**
Portal only: `Entra ID → Security → Conditional Access → What If`
Input the affected user's UPN, the app they were trying to reach, and their device platform.
*Good:* Output matches what you intended when writing the policy.
*Bad:* An unrelated policy you forgot about also applies and adds a conflicting requirement.

---

**Step 3 — Check for scope-conflicting policies**
```powershell
$policies = Get-MgIdentityConditionalAccessPolicy -Filter "state eq 'enabled'"
$policies | Select-Object DisplayName,
    @{N="Apps";E={$_.Conditions.Applications.IncludeApplications -join ","}},
    @{N="Users";E={$_.Conditions.Users.IncludeUsers -join ","}},
    @{N="Grants";E={$_.GrantControls.BuiltInControls -join ","}} |
    Format-Table -AutoSize
```
Look for two enabled policies targeting overlapping users/apps with conflicting or additive grant controls (e.g., one requires compliant device, another requires hybrid join — a BYOD user can satisfy neither).

---

**Step 4 — Confirm exclusions are still intact after the edit**
```powershell
$p = Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '<PolicyName>'"
$p.Conditions.Users.ExcludeUsers
$p.Conditions.Users.ExcludeGroups
```
Editing a policy in the portal UI occasionally requires re-saving the full Users blade — admins sometimes lose an exclusion by editing Include without re-confirming Exclude was preserved.

---

**Step 5 — Check sign-in log volume of failures since the change**
```powershell
$since = (Get-Date).AddHours(-2)
Get-MgAuditLogSignIn -Filter "createdDateTime ge $($since.ToString('yyyy-MM-ddTHH:mm:ssZ')) and conditionalAccessStatus eq 'failure'" -Top 200 |
    Group-Object AppDisplayName |
    Select-Object Name, Count |
    Sort-Object Count -Descending
```
A sudden spike concentrated on one app right after your change window is strong confirmation the new/edited policy is the cause.

---

## Common Fix Paths

<details><summary>Fix 1 — Immediate rollback to Report-only (stop the bleeding)</summary>

**Cause:** A newly enforced policy is actively blocking users in production.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$policyId = (Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '<PolicyName>'").Id

Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId -BodyParameter @{
    state = "enabledForReportingButNotEnforced"
}
```
This immediately stops enforcement while preserving the policy definition and continuing to log what it *would* have done — use this window to fix the real issue before re-enabling.

**Rollback:** Re-enable with `state = "enabled"` once the root cause is fixed and re-validated in Report-only.

</details>

<details><summary>Fix 2 — Scope a broad new policy down to a pilot group</summary>

**Cause:** Policy was authored against `All users` and rolled out tenant-wide without a pilot phase.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess","Group.ReadWrite.All"

# Create (or reuse) a pilot group
$pilotGroup = New-MgGroup -DisplayName "CA-Pilot-Rollout" -MailEnabled:$false -SecurityEnabled:$true -MailNickname "ca-pilot-rollout"

$policyId = (Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '<PolicyName>'").Id

Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId -BodyParameter @{
    conditions = @{
        users = @{
            includeGroups = @($pilotGroup.Id)
            includeUsers  = @()
        }
    }
}
```
Add IT/champion users to the pilot group first, monitor for a week, then progressively widen scope.

**Rollback:** Revert `includeUsers`/`includeGroups` to the prior scoping.

</details>

<details><summary>Fix 3 — Add missing break-glass exclusions</summary>

**Cause:** Break-glass accounts weren't added to the new policy's exclusions (they must be added to every new policy manually — this isn't automatic).

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess","Directory.Read.All"

$breakGlassUpns = @("<breakglass1@domain.com>","<breakglass2@domain.com>")
$bgIds = $breakGlassUpns | ForEach-Object { (Get-MgUser -UserId $_).Id }

$policyId = (Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '<PolicyName>'").Id
$policy = Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId
$existing = $policy.Conditions.Users.ExcludeUsers
$merged = ($existing + $bgIds) | Select-Object -Unique

Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId -BodyParameter @{
    conditions = @{ users = @{ excludeUsers = $merged } }
}
```

**Rollback:** Remove the added IDs from `excludeUsers` if this was applied in error.

</details>

<details><summary>Fix 4 — Add legacy authentication clients to scope</summary>

**Cause:** New policy's Client Apps condition only covers "Browser" and "Mobile apps and desktop clients," missing `Exchange ActiveSync clients` and `Other clients` — legacy protocols sail through unaffected.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$policyId = (Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '<PolicyName>'").Id

Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId -BodyParameter @{
    conditions = @{
        clientAppTypes = @("browser","mobileAppsAndDesktopClients","exchangeActiveSync","other")
    }
}
```
If the intent was actually to leave a specific legacy line-of-business integration unaffected, exclude that specific service principal/app instead of narrowing client app types tenant-wide.

**Rollback:** Revert `clientAppTypes` to the prior list.

</details>

<details><summary>Fix 5 — Resolve overlapping/conflicting policy scope</summary>

**Cause:** Two enabled policies both match the same user/app combination with grant controls that are individually reasonable but jointly impossible to satisfy (e.g., `Require hybrid Azure AD joined` AND a separate policy requiring `Require compliant device` for a BYOD-only user population that's neither).

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

# Identify the overlap precisely, then narrow one policy's user/app scope so they no longer both apply
# Example: exclude the BYOD population from the hybrid-join policy since they can't be domain joined
$policyId = (Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '<HybridJoinPolicyName>'").Id
$byodGroupId = (Get-MgGroup -Filter "displayName eq 'BYOD-Users'").Id

Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId -BodyParameter @{
    conditions = @{ users = @{ excludeGroups = @($byodGroupId) } }
}
```

**Rollback:** Remove the added exclusion group.

</details>

---

## Escalation Evidence

```
=== CA POLICY ROLLOUT ISSUE ESCALATION ===
Date/Time (UTC):                  ____________________
Reported by:                      ____________________
Policy name / Object ID:          ____________________
Policy state at time of issue:    ON / REPORT-ONLY
Last modified timestamp:          ____________________
Change made by:                   ____________________
Description of impact:            ____________________

=== CHECKS COMPLETED ===
[ ] Policy state confirmed:                 ____________________
[ ] What If tool run against affected user:  YES / NO — result: ____________________
[ ] Overlapping/conflicting policies found:  YES / NO — which: ____________________
[ ] Break-glass exclusions intact:           YES / NO
[ ] Legacy auth client scope reviewed:       YES / NO
[ ] Sign-in log failure spike confirmed:     YES / NO — count: ____________________

=== ACTIONS TAKEN ===
[ ] Rolled back to Report-only:              YES / NO
[ ] Scoped to pilot group:                   YES / NO
[ ] Added break-glass exclusion:             YES / NO
[ ] Adjusted client app types:               YES / NO
[ ] Resolved policy overlap:                 YES / NO

=== ESCALATION PATH ===
If impact is widespread (multiple departments, org-wide lockout risk):
- Immediately roll back to Report-only (Fix 1) before further diagnosis
- Open a case via https://admin.microsoft.com if root cause isn't found within 30 minutes
- Provide: Policy Object ID, exact ModifiedDateTime, sample of 3-5 affected UPNs with sign-in log Correlation IDs
```

---

## 🎓 Learning Pointers

- **Report-only is not optional for anything touching `All users` or `All cloud apps`.** Every mass-lockout incident traced back through this runbook has the same root cause: a policy went straight to `On` without a Report-only observation window. Make Report-only-first a non-negotiable step in your change process, not a nice-to-have. [MS Docs: Report-only mode](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-report-only)
- **The What If tool tests against reality, sign-in log review tests against history — use both.** What If tells you what *would* happen right now for a hypothetical scenario; sign-in logs tell you what *did* happen. A change reviewed only with What If can still miss real-world edge cases like an app registration with a non-obvious App ID. [MS Docs: What If tool](https://learn.microsoft.com/en-us/entra/identity/conditional-access/troubleshoot-conditional-access-what-if)
- **Exclusions do not carry forward automatically when you "duplicate" a policy.** Cloning an existing CA policy as a starting point for a new one is common practice — but the clone does not always retain every exclusion cleanly, especially break-glass accounts. Always re-verify exclusions on any cloned policy before enabling it. [MS Docs: Emergency access accounts](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/security-emergency-access)
- **Grant controls from multiple policies are additive (AND), never averaged.** Two individually sensible policies can combine into an impossible requirement for a subset of users. Before enabling a new policy, always run Step 3 (scope-conflict check) against the full set of currently enabled policies, not just review the new one in isolation.
- **A policy edit is functionally a new deployment.** Treat editing an existing enforced policy with the same caution as creating a new one — temporarily flip to Report-only during significant edits (scope, grant controls, client app types) rather than editing a live enforcing policy directly. [MS Docs: Best practices for Conditional Access](https://learn.microsoft.com/en-us/entra/identity/conditional-access/best-practices)
