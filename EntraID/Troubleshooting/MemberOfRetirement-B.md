# memberOf Rule Operator Retirement — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## ⚠ A note before you start — this has a hard calendar deadline: November 3, 2026

The **`memberOf` dynamic membership rule operator** (public preview) is being retired. Per Microsoft message center notification **MC1448379** (5 August 2026): **after November 3, 2026**, dynamic membership groups and dynamic administrative units that use `memberOf` in their membership rule **stop updating and freeze in their last known state** — no error, no notification banner, membership just goes stale silently. Entitlement management automatic assignment policies that use `memberOf` are **quarantined**: the policy remains but assignment processing stops entirely (no adds, no removes) until `memberOf` is removed from the rule.

This is not a "some day" cleanup item. If today's date is on or close to November 3, 2026, treat this as time-critical — every day of delay is a day closer to silently stale Teams/SharePoint access, Conditional Access targeting, group-based licensing, and access package assignments.

If the ticket is about a dynamic group rule that simply isn't evaluating at all (paused processing, syntax error, sync lag) and doesn't involve `memberOf`, go to `DynamicGroups-B.md` instead — this runbook is scoped specifically to the `memberOf` retirement.

---
## Triage

```powershell
# 1. Connect (read-only scopes cover every check below)
Connect-MgGraph -Scopes "Group.Read.All","AdministrativeUnit.Read.All","EntitlementManagement.Read.All" -NoWelcome

# 2. Find dynamic GROUPS whose rule uses memberOf
Get-MgGroup -Filter "groupTypes/any(c:c eq 'DynamicMembership')" -All -Property Id,DisplayName,MembershipRule,MembershipRuleProcessingState |
    Where-Object { $_.MembershipRule -match '(?i)memberof' } |
    Select-Object DisplayName, Id, MembershipRuleProcessingState, MembershipRule

# 3. Find dynamic ADMINISTRATIVE UNITS whose rule uses memberOf
Get-MgDirectoryAdministrativeUnit -All -Property Id,DisplayName,MembershipType,MembershipRule |
    Where-Object { $_.MembershipType -eq 'Dynamic' -and $_.MembershipRule -match '(?i)memberof' } |
    Select-Object DisplayName, Id, MembershipRule

# 4. Find entitlement management AUTO-ASSIGNMENT POLICIES whose rule uses memberOf
#    (no typed cmdlet exposes membershipRule on assignment policies yet — use Invoke-MgGraphRequest)
$uri = 'https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies?$expand=accessPackage&$top=50'
$hits = do {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri
    foreach ($p in $page.value) {
        if (-not $p.automaticRequestSettings) { continue }
        foreach ($t in @($p.specificAllowedTargets)) {
            if ([string]$t.'@odata.type' -like '*attributeRuleMembers*' -and [string]$t.membershipRule -match '(?i)memberof') {
                [pscustomobject]@{ AccessPackage = $p.accessPackage.displayName; Policy = $p.displayName; Rule = $t.membershipRule }
            }
        }
    }
    $uri = $page.'@odata.nextLink'
} while ($uri)
$hits
```

| Result | Action |
|--------|--------|
| Dynamic group(s) found using `memberOf` | → [Fix 1 — Migrate a Dynamic Group Off memberOf](#fix-1--migrate-a-dynamic-group-off-memberof) |
| Dynamic AU(s) found using `memberOf` | → [Fix 2 — Migrate a Dynamic Administrative Unit Off memberOf](#fix-2--migrate-a-dynamic-administrative-unit-off-memberof) |
| Auto-assignment policy(ies) found using `memberOf` | → [Fix 3 — Migrate an Entitlement Management Auto-Assignment Policy Off memberOf](#fix-3--migrate-an-entitlement-management-auto-assignment-policy-off-memberof) |
| It's after Nov 3, 2026 and a group/AU/policy is already frozen or quarantined | → [Fix 4 — Recover an Already-Frozen or Quarantined Object](#fix-4--recover-an-already-frozen-or-quarantined-object) |
| No supported operator can express the same membership logic | → [Fix 5 — No Equivalent Rule Exists](#fix-5--no-equivalent-rule-exists) |
| Nothing found in any of the three sweeps | Nothing to migrate for this tenant — still worth re-running the sweep periodically before Nov 3, 2026 in case a new rule gets added |

---
## Dependency Cascade

<details><summary>What breaks, and what it depends on</summary>

```
memberOf rule operator (public preview, ending Nov 3, 2026)
  ├── Dynamic membership GROUPS (groupTypes: DynamicMembership)
  │     └── membershipRule contains "memberOf"
  │           └── After Nov 3, 2026: rule STOPS EVALUATING
  │                 └── Group membership freezes at last-known state
  │                       ├── Teams/SharePoint site access (stale)
  │                       ├── Conditional Access group-based targeting (stale)
  │                       └── Group-based licensing (stale)
  ├── Dynamic ADMINISTRATIVE UNITS (membershipType: Dynamic)
  │     └── membershipRule contains "memberOf"
  │           └── After Nov 3, 2026: rule STOPS EVALUATING
  │                 └── AU membership freezes -> AU-scoped role assignments
  │                       stop reflecting reality (over- or under-scoped admin access)
  └── Entitlement management AUTO-ASSIGNMENT POLICIES
        └── specificAllowedTargets[].membershipRule contains "memberOf"
              └── After Nov 3, 2026: policy is QUARANTINED
                    └── Assignment processing STOPS ENTIRELY
                          (existing assignments neither added nor removed)
                                └── Access package assignments go stale
                                      (leavers KEEP access, joiners NEVER get it)
```

**The one fact that matters most:** none of these three objects are deleted, disabled, or flagged with a visible error after November 3, 2026. They simply stop updating. A ticket that shows up as "this person still has access three months after they left the department" is the eventual symptom — by the time it's reported, the rule may have been silently frozen for weeks.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm today's date against the deadline**
```powershell
$deadline = Get-Date "2026-11-03"
$daysLeft = ($deadline - (Get-Date)).Days
"$daysLeft day(s) until memberOf retirement (Nov 3, 2026)"
```
Expected: if `$daysLeft` is negative, any object still using `memberOf` is **already** frozen/quarantined right now — treat every hit from Triage step 2-4 as already broken, not "at risk."

**Step 2 — For each dynamic group hit, confirm current processing state**
```powershell
Get-MgGroup -GroupId "<groupId>" -Property MembershipRuleProcessingState,MembershipRule |
    Select-Object MembershipRule, MembershipRuleProcessingState
```
Expected (pre-deadline): `MembershipRuleProcessingState = On` — the rule is still evaluating normally today; it's the November 3 cutover that will freeze it, not a current fault. Post-deadline, `On` no longer means the rule is actually being evaluated for a `memberOf` rule specifically — the property doesn't change to reflect the retirement, which is exactly why this is easy to miss.

**Step 3 — Confirm whether an equivalent supported rule exists**
Ask: can this same membership logic be expressed with `-eq`, `-startsWith`, `-endsWith`, `-in`, or `-notin` against a real user/device attribute (department, jobTitle, extension attribute, custom security attribute) instead of referencing another group's membership? If yes → Fix 1/2/3. If no → Fix 5.

**Step 4 — For entitlement management, confirm the policy isn't already the only auto-assignment policy relying on that logic**
```powershell
# List every policy on the same access package to understand blast radius before editing
$apid = "<accessPackageId>"
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages/$apid/assignmentPolicies").value |
    Select-Object displayName, id
```
Expected: confirm you're not about to remove the only path by which users get assigned to this access package — line up the replacement rule (or alternative assignment method) before touching the existing policy.

---
## Common Fix Paths

<details><summary>Fix 1 — Migrate a Dynamic Group Off memberOf</summary>

**When:** A dynamic membership group's rule contains `memberOf`.

```powershell
# 1. Capture the current rule and membership before changing anything
$group = Get-MgGroup -GroupId "<groupId>" -Property MembershipRule
$group.MembershipRule
Get-MgGroupMember -GroupId "<groupId>" -All | Select-Object Id | Export-Csv ".\pre-migration-members-$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation

# 2a. OPTION A — replace with a supported attribute-based rule (preferred if an equivalent exists)
$newRule = '(user.department -eq "Sales") -and (user.usageLocation -eq "US")'
Update-MgGroup -GroupId "<groupId>" -BodyParameter @{ membershipRule = $newRule }

# 2b. OPTION B — convert to assigned (manual) membership if no rule-based equivalent exists
Update-MgGroup -GroupId "<groupId>" -BodyParameter @{
    groupTypes            = @()
    membershipRule        = $null
    membershipRuleProcessingState = $null
}
# Then manually add the members captured in step 1:
# Get-Content .\pre-migration-members-*.csv | ForEach-Object { Add-MgGroupMember -GroupId "<groupId>" -DirectoryObjectId $_.Id }
```

3. Validate: re-pull group membership and diff against the pre-migration CSV. If membership is no longer needed at all, pause (`membershipRuleProcessingState = "Paused"`) or delete the group rather than leaving a stale `memberOf` rule in place.

**Rollback:** Restore the prior `membershipRule` string captured in step 1 (works only before Nov 3, 2026 — after that date `memberOf` no longer evaluates regardless of what the rule says).

</details>

<details><summary>Fix 2 — Migrate a Dynamic Administrative Unit Off memberOf</summary>

**When:** A dynamic AU's rule contains `memberOf`.

```powershell
# 1. Capture current rule and membership
$au = Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId "<auId>" -Property MembershipRule
$au.MembershipRule
Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId "<auId>" -All | Select-Object Id | Export-Csv ".\pre-migration-au-members-$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation

# 2a. OPTION A — replace with a supported attribute-based rule
Update-MgDirectoryAdministrativeUnit -AdministrativeUnitId "<auId>" -MembershipRule '(user.department -eq "IT")' -MembershipRuleProcessingState "On"

# 2b. OPTION B — convert to assigned membership
Update-MgDirectoryAdministrativeUnit -AdministrativeUnitId "<auId>" -BodyParameter @{
    membershipType = "Assigned"
}
# Then manually re-add members captured in step 1 via New-MgDirectoryAdministrativeUnitMemberByRef or the admin center
```

3. **Validate both membership AND administrative scope** — an AU's members drive who's *administered*, but AU-scoped role assignments define who *administers*. Confirm the role-assignment side still makes sense after the membership rule changes, not just that the member list looks right.

**Rollback:** Restore the prior `MembershipRule` (pre-deadline only, same caveat as Fix 1).

</details>

<details><summary>Fix 3 — Migrate an Entitlement Management Auto-Assignment Policy Off memberOf</summary>

**When:** An access package's automatic assignment policy rule contains `memberOf`.

```powershell
Connect-MgGraph -Scopes "EntitlementManagement.ReadWrite.All"

# Rebuild the policy with a supported attribute-based rule (PATCH via Graph — no typed
# cmdlet confirmed for updating just the membershipRule sub-object of specificAllowedTargets)
$policyId = "<policyId>"
$body = @{
    specificAllowedTargets = @(@{
        "@odata.type"   = "#microsoft.graph.attributeRuleMembers"
        description     = "Rebuilt off memberOf per MC1448379"
        membershipRule  = '(user.department -eq "Sales")'
    })
}
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies/$policyId" -Body ($body | ConvertTo-Json -Depth 5)
```

**If no equivalent attribute-based rule exists** for the group-membership logic the policy relied on, do **not** simply delete the policy — assignments will silently stop being created (and, depending on the access package's other settings, may not be automatically removed either). Plan an alternative assignment method first: direct assignment, a request-based (non-automatic) policy, or a manually maintained group referenced by a supported rule. See Fix 5.

**Rollback:** Re-apply the prior `membershipRule` JSON via the same PATCH pattern (pre-deadline only — a quarantined policy ignores its rule regardless of content until `memberOf` is removed).

</details>

<details><summary>Fix 4 — Recover an Already-Frozen or Quarantined Object</summary>

**When:** Today's date is past November 3, 2026 and a dynamic group/AU is frozen, or an auto-assignment policy is quarantined.

1. **Dynamic group/AU:** the object is not broken in a way that "resumes" itself — apply Fix 1/Fix 2 (replace or convert the rule). The moment `memberOf` is removed from the rule text, normal evaluation resumes on the next processing cycle; there's no separate "un-freeze" action needed.
2. **Auto-assignment policy:** apply Fix 3. Quarantine lifts automatically once `memberOf` is removed from the policy's rule — there is no manual quarantine-release step to run.
3. **Before assuming membership is current, always diff against the frozen state** — a group that's been silently frozen for weeks or months may have accumulated meaningful drift (leavers still in, joiners never added). Run the standard access-recertification process (see `AccessReviews-B.md`) after fixing the rule, don't assume the group is instantly correct.

**Rollback:** N/A — this is remediation of an already-broken state, not a reversible action.

</details>

<details><summary>Fix 5 — No Equivalent Rule Exists</summary>

**When:** The `memberOf` rule referenced another group's membership in a way that genuinely can't be expressed with a supported attribute-based operator (e.g., the target population is defined purely by ad-hoc group membership with no shared attribute).

There is currently **no drop-in platform replacement** for "members of these other groups" dynamic logic — Microsoft's own guidance states they are "continuing to develop an alternative solution" with no committed date. Options, in order of preference:

1. **Redesign around a real attribute** — if there's any way to tag the target population with an extension attribute, custom security attribute, or existing directory property instead of group membership, this is the most durable fix and avoids re-hitting this problem when the next preview operator is retired.
2. **Convert to assigned (manual) membership** — accept the operational overhead of manually maintaining the group/AU/policy target list going forward. Acceptable for smaller, slow-changing populations; not acceptable at scale without a maintenance process.
3. **Automate manual assignment via script/Logic App** — if the source-of-truth logic can be evaluated outside Entra (e.g., against an HR system or the source groups themselves), a scheduled script that calls `Add-MgGroupMember`/`Remove-MgGroupMember` (or the AU/access-package equivalents) based on that external evaluation approximates the old `memberOf` behavior without relying on the retired operator.

**Rollback:** N/A — planning guidance, not an executable action.

</details>

---
## Escalation Evidence

```
=== memberOf RETIREMENT ESCALATION EVIDENCE PACK ===
Date/Time (UTC): _______________
Reported by: _______________
Tenant ID: _______________
Days until/since Nov 3, 2026 deadline: _______________

AFFECTED OBJECT:
[ ] Dynamic group — Name/ID: _______________
[ ] Dynamic administrative unit — Name/ID: _______________
[ ] Entitlement management auto-assignment policy — Access package/Policy: _______________

CURRENT STATE:
Current membershipRule text: _______________
MembershipRuleProcessingState (groups/AUs only): _______________
Confirmed already frozen/quarantined (Y/N): _______________

MIGRATION STATUS:
Supported-operator equivalent identified (Y/N): _______________
If NO — alternative assignment method planned: _______________
Pre-migration membership snapshot captured (Y/N, file): _______________

ACTIONS TAKEN:
_______________

CORRELATION ID: _______________
```

---
## 🎓 Learning Pointers

- **This is a hard calendar deadline, not a soft deprecation notice**: after November 3, 2026, affected objects don't error — they silently freeze (groups/AUs) or quarantine (auto-assignment policies). Build the migration into change management now rather than waiting for a ticket. Reference: [Configure dynamic membership groups with the memberOf operator](https://learn.microsoft.com/en-us/entra/identity/users/groups-dynamic-rule-member-of)
- **The root cause for the retirement is tenant-wide, not per-group**: Microsoft's own explanation is that a single `memberOf` rule can slow dynamic-group processing for *every* dynamic group in the tenant, not just the one using it — this is why the fix requires a full rule rewrite rather than a scale-limit increase.
- **Three independent object types are affected, each with its own discovery method** — dynamic groups (`Get-MgGroup` + `groupTypes`), dynamic AUs (`Get-MgDirectoryAdministrativeUnit` + `membershipType`), and entitlement management auto-assignment policies (Graph-only, no typed cmdlet exposes the rule) — a sweep that only checks groups will miss AU and access-package exposure entirely.
- **"Frozen" membership can be stale for a long time before anyone notices** — since there's no error state, the first sign is often a stale-access finding during an unrelated access review. Consider proactively re-running the Triage sweep on a schedule (e.g., monthly) until every hit is confirmed remediated.
- **There is currently no feature-parity replacement for "members of these other groups"** — plan around real attributes or manual/scripted maintenance; don't wait on Microsoft's unscoped "alternative solution in development" statement before acting on the Nov 3, 2026 deadline. Reference: [office365itpros — MemberOf Rule Operator Retired](https://office365itpros.com/2026/08/07/memberof-rule-operator/)
- **For entitlement management specifically, deleting a policy is not a safe substitute for fixing the rule** — assignments can silently stop being created (or removed) depending on the access package's other policies; always line up a replacement assignment path first. Reference: [Configure an automatic assignment policy for an access package](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-auto-assignment-policy)
