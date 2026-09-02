# memberOf Rule Operator Retirement — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers the **retirement of the `memberOf` dynamic membership rule operator** in Microsoft Entra ID, announced via message center notification **MC1448379** (5 August 2026), with the preview ending **November 3, 2026**. `memberOf` was a preview-only rule operator that let a dynamic membership group or dynamic administrative unit populate based on **membership of other groups** (e.g., "everyone who is a direct member of Security-Group-X or Security-Group-Y"), and let an entitlement management automatic assignment policy do the same for access package assignment.

**In scope:**
- The `memberOf` operator's mechanics and preview-era limitations as they existed up to retirement
- Exactly what "retirement" means operationally for each of the three affected object types (dynamic groups, dynamic administrative units, entitlement management auto-assignment policies) — they do **not** all fail the same way
- Discovery: how to find every `memberOf`-dependent object across all three surfaces in a tenant
- Migration paths: supported-operator rewrite, conversion to assigned/manual membership, and the "no equivalent exists" fallback
- The underlying reason Microsoft gives for retiring the feature (tenant-wide dynamic-group processing performance), because it explains why there's no simple scale-limit fix

**Assumes:**
- Microsoft Graph PowerShell SDK: `Install-Module Microsoft.Graph -Scope CurrentUser` (groups, AUs) — no separate `.Beta` module is required, since `memberOf` rules and their retirement are v1.0/GA-documented, not beta-gated
- A user holding **Groups Administrator** (for dynamic groups), **Privileged Role Administrator** (for administrative units), or **Identity Governance Administrator** (for entitlement management policies) to make changes; **Global Reader** is sufficient for every read-only discovery step in this runbook
- Familiarity with ordinary dynamic membership rule syntax (`-eq`, `-startsWith`, `-match`, `-in`, etc.) — see `DynamicGroups-A.md` for that foundational mechanism if unfamiliar

**Not covered:**
- Ordinary dynamic group troubleshooting unrelated to `memberOf` (paused processing, rule syntax errors, evaluation lag) — see `DynamicGroups-B.md`/`-A.md`
- Regular (non-dynamic, non-`memberOf`-specific) administrative unit mechanics — see `AdministrativeUnits-B.md`/`-A.md`
- Entitlement management access package delivery and approval workflow mechanics unrelated to automatic assignment — see `AccessPackages-B.md`/`-A.md`
- Any future Microsoft-provided replacement for group-membership-based dynamic rules — as of this writing (September 2026) Microsoft has stated only that an alternative is "being developed," with no committed scope or date

---
## How It Works

<details><summary>Full architecture</summary>

### What `memberOf` was for

Ordinary dynamic membership rules evaluate **identity attributes** — `user.department -eq "Sales"`, `device.deviceOSType -eq "Windows"`, and so on. What they structurally cannot do is evaluate **group topology**: "give me everyone who is a member of Group A or Group B," where A and B are pre-existing groups with no shared attribute tying their members together. The `memberOf` operator, introduced as a public preview, filled exactly that gap:

```text
user.memberof -any (group.objectId -in ['<groupId1>', '<groupId2>'])
device.memberof -any (group.objectId -in ['<groupId1>'])
```

A `memberOf` dynamic group could aggregate members from up to 50 source groups (security groups, Microsoft 365 groups, and on-premises-synced groups could all be mixed as sources) into a single dynamic group — useful for consolidating access-granting logic without either re-tagging every user with a new attribute or maintaining a manually-curated aggregate group by hand.

### Preview-era constraints (context for why migration isn't always simple)

Several `memberOf`-specific limitations shaped how organizations actually used it, and matter when planning migration:

- **Direct membership only** — a `memberOf` dynamic group picks up only *direct* members of a referenced source group; transitive/nested membership (a member of a group nested inside the source group) is not evaluated, unlike on-premises AD nested-group semantics some admins expect.
- **No `memberOf`-of-`memberOf` chaining** — a `memberOf` dynamic group cannot itself be used as a source group for another `memberOf` dynamic group.
- **`memberOf` couldn't combine with other rule syntax** — a rule using `memberOf` could not also filter on, say, `user.city -eq "Redmond"` in the same rule; it was all-`memberOf` or none.
- **No live re-evaluation on source-group deletion or member removal** — if a child/source group was deleted or lost a member, the `memberOf` dynamic group's membership did **not** automatically update; the affected users/devices remained members until the `memberOf` dynamic group's own rule was explicitly modified. This one-way staleness behavior existed even *before* the retirement — it's a separate, preview-era quirk worth knowing when investigating "why does this group still have someone who left the source group weeks ago."
- **Scale caps**: 500 dynamic groups per tenant could use `memberOf` (counting toward the overall 15,000 dynamic-group tenant limit), and each such group could reference up to 50 source groups.
- **Global cloud only** — never available in Azure Government or Microsoft Azure operated by 21Vianet.
- **No rule builder UI support** — `memberOf` rules could only be authored via the raw rule-syntax editor, never the visual rule builder, in the Azure/Entra portal.

### Why it's being retired — the tenant-wide processing cost

Microsoft's stated reason is a scale/performance one, not a security or compliance one: **a single dynamic group using `memberOf` could slow membership processing for every other dynamic group in the same tenant**, not just the one referencing it. This is the detail that explains why the fix is a full operator retirement rather than, say, a raised per-tenant limit — the cost isn't isolated to the object using the feature, so no amount of per-object throttling would have contained it. Microsoft's public statement acknowledges the underlying customer scenarios `memberOf` served remain valid and says a scalable, reliable alternative is in development, but gives no committed timeline — which is why this runbook treats "redesign around attributes" and "convert to assigned membership" as the only currently actionable paths, not "wait for the replacement."

### What "retirement" actually means — three different failure modes

This is the single most important operational distinction in this topic, because the three affected object types **do not fail the same way** after November 3, 2026:

1. **Dynamic membership groups using `memberOf`** — the rule simply **stops being evaluated**. The group is not deleted, not disabled, and its `membershipRuleProcessingState` property does not change to reflect this — it will still report `On` even though `memberOf`-based evaluation has effectively stopped. Membership **freezes at whatever it was at the moment of retirement** and never changes again until an admin edits the rule.
2. **Dynamic administrative units using `memberOf`** — identical freeze behavior to dynamic groups, with the added consequence that AU-scoped role assignments (Helpdesk Administrator, User Administrator, etc. scoped to that AU) now apply to a **frozen population** — an admin might retain scoped rights over a user who's since left the AU's intended scope, or a new user who should be in scope never gets the administrative coverage they need.
3. **Entitlement management automatic assignment policies using `memberOf`** — a materially different mechanism: the policy is **quarantined**. Quarantine means assignment processing stops **entirely** for that policy — no new assignments are created for users who newly match, and (just as importantly) no existing assignments are removed for users who no longer match. This is a full processing halt on the policy, not a frozen snapshot of "who was in scope" — the practical effect for access review purposes is the same (stale assignments), but the underlying state (policy object flagged as quarantined vs. group object silently ignoring its own rule) differs, and that difference matters for how each is discovered (see Symptom → Cause Map).

None of the three produce a visible error, alert, or portal warning banner once the deadline passes — this is a deliberate design choice by Microsoft to avoid breaking existing configurations outright, but it means **the retirement is fully silent from an admin's perspective** unless they proactively check.

### No feature-parity replacement exists today

As of this runbook's writing, Microsoft has not shipped a drop-in replacement rule operator. The three migration paths documented in this runbook — supported-attribute rewrite, conversion to assigned/manual membership, and external/scripted automation — are the complete list of currently available options, not a subset pending a better native fix.

</details>

---
## Dependency Stack

```
memberOf rule operator (public preview -> retiring Nov 3, 2026, MC1448379)
  ├── Dynamic membership GROUPS
  │     groupTypes contains "DynamicMembership"
  │     membershipRule references memberOf, e.g.:
  │       user.memberof -any (group.objectId -in ['<id1>','<id2>'])
  │     ├── Preview constraints: direct-membership-only source evaluation,
  │     │     no memberOf-of-memberOf chaining, no combination with other
  │     │     rule syntax, no rule-builder UI, Global cloud only,
  │     │     500 memberOf-groups/tenant, 50 source-groups/group
  │     └── AFTER Nov 3, 2026: rule STOPS EVALUATING
  │           (MembershipRuleProcessingState still reports "On" -- MISLEADING)
  │           └── Membership FROZEN at last-evaluated state
  │                 ├── Teams / SharePoint site access -> stale
  │                 ├── Conditional Access group targeting -> stale
  │                 └── Group-based license assignment -> stale
  ├── Dynamic ADMINISTRATIVE UNITS
  │     membershipType = "Dynamic"
  │     membershipRule references memberOf (same syntax as groups)
  │     └── AFTER Nov 3, 2026: rule STOPS EVALUATING
  │           └── AU membership FROZEN
  │                 └── AU-scoped Entra role assignments
  │                       now apply to a STALE population
  │                       (over-scoped OR under-scoped admin access)
  └── Entitlement management AUTOMATIC ASSIGNMENT POLICIES
        assignmentPolicy.automaticRequestSettings present
        specificAllowedTargets[].membershipRule references memberOf
        └── AFTER Nov 3, 2026: policy QUARANTINED
              (policy object itself is untouched -- processing halts)
              └── Assignment processing STOPS COMPLETELY
                    ├── New matches -> NEVER get assigned
                    └── Existing assignees who fall out of scope
                          -> NEVER get unassigned
                                └── Access package assignments -> stale
                                      (a leaver KEEPS access indefinitely)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|--------------------|-------|
| Dynamic group membership hasn't changed in weeks/months despite known personnel changes | Rule uses `memberOf` and the tenant has passed Nov 3, 2026 — silently frozen | `MembershipRule -match '(?i)memberof'` + confirm current date vs. deadline |
| `MembershipRuleProcessingState` reports `On` but the group genuinely isn't updating | This property does NOT reflect `memberOf` retirement — it stays `On` regardless | Don't trust this property alone for `memberOf` groups; cross-check rule content and date |
| AU-scoped admin has (or is missing) rights that don't match current org structure | Dynamic AU using `memberOf`, frozen post-deadline | `Get-MgDirectoryAdministrativeUnit` + `MembershipType`/`MembershipRule` check |
| Access package assignment never arrived for a newly-matching user | Auto-assignment policy quarantined (uses `memberOf`, post-deadline) | Graph query against `assignmentPolicies` for `memberOf` in `specificAllowedTargets[].membershipRule` |
| A departed/reassigned user still holds an access package assignment months later | Same — quarantined policy also stops REMOVALS, not just additions | Same check; cross-reference assignment `createdDateTime`/user's actual current attributes |
| A `memberOf` dynamic group is missing someone who left a source group weeks ago (pre-deadline) | Documented preview-era behavior — no live re-evaluation on source-group member removal, not a retirement symptom | Confirm the group's rule was actually edited/re-saved since the source-group change; if not, this is expected preview behavior, not new breakage |
| Trying to combine a `memberOf` clause with an attribute filter in the same rule fails | Preview-era limitation — `memberOf` cannot combine with other operators in one rule, was never supported | Redesign as two separate objects or migrate away from `memberOf` entirely per this runbook |
| New `memberOf` dynamic group creation fails at 500 groups | Preview per-tenant `memberOf`-group cap reached | Irrelevant post-migration — this cap is moot once no `memberOf` groups remain |

---
## Validation Steps

**1. Confirm the deadline relative to today**
```powershell
$daysLeft = ([datetime]"2026-11-03" - (Get-Date)).Days
"$daysLeft day(s) until memberOf retirement"
```
Expected: any positive number means dynamic-group/AU rules using `memberOf` are still evaluating normally today (though not for long); zero or negative means treat every hit below as already frozen/quarantined, not "at risk."

**2. Sweep dynamic groups**
```powershell
Get-MgGroup -Filter "groupTypes/any(c:c eq 'DynamicMembership')" -All -Property Id,DisplayName,MembershipRule,MembershipRuleProcessingState |
    Where-Object { $_.MembershipRule -match '(?i)memberof' }
```
Expected: an empty result means no groups are exposed to this retirement. Any result requires migration per Playbook 1.

**3. Sweep dynamic administrative units**
```powershell
Get-MgDirectoryAdministrativeUnit -All -Property Id,DisplayName,MembershipType,MembershipRule |
    Where-Object { $_.MembershipType -eq 'Dynamic' -and $_.MembershipRule -match '(?i)memberof' }
```
Expected: same interpretation as step 2, for AUs.

**4. Sweep entitlement management auto-assignment policies**
```powershell
$uri = 'https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies?$expand=accessPackage&$top=50'
$hits = do {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri
    foreach ($p in $page.value) {
        if (-not $p.automaticRequestSettings) { continue }
        foreach ($t in @($p.specificAllowedTargets)) {
            if ([string]$t.'@odata.type' -like '*attributeRuleMembers*' -and [string]$t.membershipRule -match '(?i)memberof') {
                [pscustomobject]@{ AccessPackage = $p.accessPackage.displayName; Policy = $p.displayName; PolicyId = $p.id; Rule = $t.membershipRule }
            }
        }
    }
    $uri = $page.'@odata.nextLink'
} while ($uri)
$hits
```
Expected: same interpretation — any result requires migration per Playbook 2. This sweep is Graph-only because no typed Microsoft Graph PowerShell cmdlet currently exposes `membershipRule` on an assignment policy's `specificAllowedTargets` collection directly.

**5. For any hit, confirm whether a supported-operator equivalent exists**
Manually assess: does the target population share a real, queryable attribute (department, extension attribute, custom security attribute) that could replace the group-membership logic? This determines whether the fix is Playbook 1 (rewrite) or Playbook 3 (no equivalent — redesign/manual).

---
## Troubleshooting Steps (by phase)

### Phase 1 — Discovery
1. Run all three sweeps (Validation Steps 2-4) — a partial sweep (e.g., groups only) will miss AU and entitlement-management exposure
2. Record the exact `membershipRule` text for every hit before making any change — this is the only record of the original intent once the rule is rewritten
3. For entitlement management specifically, also record which access package each hit belongs to and whether other assignment policies exist on the same package (blast-radius check)

### Phase 2 — Feasibility Assessment
1. For each hit, determine whether the underlying population can be expressed via a supported attribute-based rule
2. Where source groups themselves have a common defining characteristic (e.g., all source groups happen to correspond to a department), that characteristic is usually the attribute to rebuild the rule around
3. Where source-group membership is genuinely ad hoc with no shared attribute, plan for assigned/manual membership or external automation instead (Playbook 3)

### Phase 3 — Migration Execution
1. Capture a pre-migration membership/assignment snapshot for every object being changed (export to CSV) — this is the only way to validate the migration didn't silently drop or add members
2. Apply the rewritten rule, or convert to assigned membership, per Playbook 1/2
3. Immediately re-pull membership/assignments and diff against the pre-migration snapshot

### Phase 4 — Post-Migration Validation
1. Confirm the object's rule no longer contains `memberOf` (re-run the relevant Validation Step sweep — it should no longer be included)
2. For groups/AUs, confirm `MembershipRuleProcessingState = On` and that a subsequent membership change (e.g., a test user's attribute change) actually triggers a membership update — proving live evaluation resumed, not just that the rule text changed
3. For entitlement management policies, confirm the quarantine flag has cleared by checking that a newly-matching test identity receives an assignment within the normal processing window

### Phase 5 — Ongoing Monitoring Until the Deadline
1. Re-run the full three-surface sweep periodically (at minimum monthly) until every hit across the tenant is confirmed remediated
2. Treat any *newly created* `memberOf`-based object discovered in a later sweep as a process gap — someone is still creating preview-operator rules; add a reminder/training note, since the portal doesn't block new `memberOf` rule creation before the retirement date

---
## Remediation Playbooks

<details><summary>Playbook 1 — Rewrite a memberOf Rule with a Supported Attribute-Based Operator</summary>

Use when: the target population defined by `memberOf` shares a real, queryable identity attribute.

```
Step 1: Export the object's current membershipRule and current membership/
        assignment list to CSV — this is the last record of "who this rule
        was actually including" before rewriting it.

Step 2: Identify the shared attribute across the source groups' member
        populations. If none of the standard supported properties
        (department, jobTitle, companyName, country, usageLocation,
        userType, accountEnabled, extension attributes 1-15, custom
        security attributes, device attributes) fit, this playbook does
        not apply -- go to Playbook 3 instead.

Step 3: Draft the replacement rule using the MOST EFFICIENT supported
        operator for the case: prefer -eq over -startsWith/-endsWith,
        prefer those over -match; use -in/-notin to collapse multiple
        -or'd equality checks into a single criterion. (See "Create
        simpler, more efficient rules for dynamic membership groups",
        referenced in Learning Pointers -- this also reduces the tenant-
        wide processing cost that motivated retiring memberOf in the
        first place.)

Step 4: Apply the new rule (Update-MgGroup / Update-MgDirectory
        AdministrativeUnit / PATCH the assignment policy, per the
        relevant Fix in MemberOfRetirement-B.md).

Step 5: Diff the resulting membership/assignment list against the Step 1
        export. Investigate every delta -- some drift is expected (the
        new rule may correctly include/exclude people the old memberOf
        rule didn't), but confirm each delta is EXPECTED, not accidental.

Step 6: Document the old-rule-to-new-rule mapping somewhere durable
        (ticket, change record) -- the next admin who wonders "why does
        this group only include Sales in Redmond" needs the reasoning,
        not just the final rule text.
```

**Rollback:** Restore the previous `membershipRule` string from the Step 1 export — only meaningful before November 3, 2026; after that date the old `memberOf`-based rule would not evaluate even if restored.

</details>

<details><summary>Playbook 2 — Migrate an Entitlement Management Auto-Assignment Policy</summary>

Use when: an access package's automatic assignment policy rule uses `memberOf`.

```
Step 1: List every assignment policy on the same access package
        (GET .../accessPackages/{id}/assignmentPolicies) to understand
        whether this is the ONLY path by which users get assigned --
        removing/rewriting the only policy without a replacement in
        place will silently stop new assignments.

Step 2: Export current assignments for the access package
        (GET .../accessPackageAssignments?$filter=accessPackage/id eq
        '{id}') as a pre-migration snapshot.

Step 3: Rebuild the policy's specificAllowedTargets membershipRule using
        a supported attribute-based operator (PATCH via Graph -- no
        typed cmdlet confirmed for this sub-object as of this writing).
        If no equivalent exists, do not delete the policy outright --
        proceed to Step 4 instead.

Step 4: If no attribute-based equivalent exists, replace automatic
        assignment with a REQUEST-based policy (requiresApproval /
        catalog visibility) as an interim measure, or stand up a
        scheduled script/Logic App that evaluates the original
        group-membership logic externally and calls the access-package
        assignment Graph API directly to add/remove assignments on a
        schedule.

Step 5: Validate: confirm a test identity matching the NEW rule receives
        an assignment, and a test identity that no longer matches has
        its assignment removed, within the normal processing window.

Step 6: Cross-reference the pre-migration snapshot (Step 2) against
        current assignments -- flag and manually resolve any assignment
        that predates the migration and no longer matches ANY current
        policy on the access package (these are the "quarantine-era"
        stale assignments this whole migration exists to catch).
```

**Rollback:** Re-apply the prior `membershipRule` JSON via the same PATCH pattern — meaningful only before the deadline; a quarantined policy ignores rule content entirely regardless of what's restored.

</details>

<details><summary>Playbook 3 — No Supported-Operator Equivalent Exists</summary>

Use when: Playbook 1/2's Step 2 feasibility check fails — the population has no shared queryable attribute.

```
Step 1: Confirm this conclusion is actually correct, not just
        convenient -- check custom security attributes specifically,
        since these are newer and easy to overlook; a population that
        looks purely ad hoc from standard properties may already have
        a custom security attribute assigned for an unrelated purpose
        that happens to also define this population.

Step 2: If genuinely no attribute exists, decide between:
        (a) Convert to assigned/manual membership -- acceptable for
            small or slow-changing populations; document who owns
            ongoing maintenance.
        (b) Build external/scripted automation -- a scheduled script
            or Logic App that evaluates the original group-membership
            logic against source-of-truth data (which may BE the
            original source groups, read via Get-MgGroupMember, with
            the aggregation logic now living in script instead of in
            the retired rule operator) and calls Add-MgGroupMember /
            Remove-MgGroupMember, New-MgDirectoryAdministrativeUnit
            MemberByRef, or the access-package assignment API on a
            schedule.

Step 3: For option (b), build the replacement with the SAME direct-
        membership-only semantics memberOf had (no accidental nested/
        transitive expansion) unless a deliberate scope change is
        intended and documented.

Step 4: Whichever option is chosen, set a follow-up reminder to
        re-evaluate once Microsoft ships its stated "alternative
        solution" -- there is no committed date, so this should be a
        periodic check (e.g., each "What's new in Microsoft Entra"
        review), not an indefinite wait before acting on option (a) or
        (b) now.
```

**Rollback:** N/A — planning/architecture playbook, not a single reversible action.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect memberOf-retirement exposure evidence across dynamic groups,
           dynamic administrative units, and entitlement management
           auto-assignment policies.
.NOTES     Requires Group.Read.All, AdministrativeUnit.Read.All,
           EntitlementManagement.Read.All scopes. Read-only.
#>

$outputPath = "C:\MemberOfRetirement_Evidence_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

$deadline = [datetime]"2026-11-03"
$daysLeft = ($deadline - (Get-Date)).Days
"Days until Nov 3, 2026 deadline: $daysLeft" | Out-File "$outputPath\deadline_status.txt"

# Dynamic groups using memberOf
Get-MgGroup -Filter "groupTypes/any(c:c eq 'DynamicMembership')" -All -Property Id,DisplayName,MembershipRule,MembershipRuleProcessingState |
    Where-Object { $_.MembershipRule -match '(?i)memberof' } |
    Select-Object DisplayName, Id, MembershipRuleProcessingState, MembershipRule |
    Export-Csv "$outputPath\memberof_groups.csv" -NoTypeInformation

# Dynamic administrative units using memberOf
Get-MgDirectoryAdministrativeUnit -All -Property Id,DisplayName,MembershipType,MembershipRule |
    Where-Object { $_.MembershipType -eq 'Dynamic' -and $_.MembershipRule -match '(?i)memberof' } |
    Select-Object DisplayName, Id, MembershipRule |
    Export-Csv "$outputPath\memberof_administrative_units.csv" -NoTypeInformation

# Entitlement management auto-assignment policies using memberOf
$uri = 'https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies?$expand=accessPackage&$top=50'
$policyHits = do {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri
    foreach ($p in $page.value) {
        if (-not $p.automaticRequestSettings) { continue }
        foreach ($t in @($p.specificAllowedTargets)) {
            if ([string]$t.'@odata.type' -like '*attributeRuleMembers*' -and [string]$t.membershipRule -match '(?i)memberof') {
                [pscustomobject]@{ AccessPackage = $p.accessPackage.displayName; Policy = $p.displayName; PolicyId = $p.id; MembershipRule = $t.membershipRule }
            }
        }
    }
    $uri = $page.'@odata.nextLink'
} while ($uri)
$policyHits | Export-Csv "$outputPath\memberof_assignment_policies.csv" -NoTypeInformation

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# Connect with read scopes covering all three surfaces
Connect-MgGraph -Scopes "Group.Read.All","AdministrativeUnit.Read.All","EntitlementManagement.Read.All"

# Sweep: dynamic groups using memberOf
Get-MgGroup -Filter "groupTypes/any(c:c eq 'DynamicMembership')" -All -Property Id,DisplayName,MembershipRule |
    Where-Object { $_.MembershipRule -match '(?i)memberof' }

# Sweep: dynamic administrative units using memberOf
Get-MgDirectoryAdministrativeUnit -All -Property Id,DisplayName,MembershipType,MembershipRule |
    Where-Object { $_.MembershipType -eq 'Dynamic' -and $_.MembershipRule -match '(?i)memberof' }

# Rewrite a dynamic group's rule
Update-MgGroup -GroupId "<groupId>" -BodyParameter @{ membershipRule = '(user.department -eq "Sales")' }

# Convert a dynamic group to assigned membership
Update-MgGroup -GroupId "<groupId>" -BodyParameter @{ groupTypes = @(); membershipRule = $null }

# Rewrite a dynamic AU's rule
Update-MgDirectoryAdministrativeUnit -AdministrativeUnitId "<auId>" -MembershipRule '(user.department -eq "IT")' -MembershipRuleProcessingState "On"

# List assignment policies for one access package (blast-radius check)
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages/<apId>/assignmentPolicies").value

# PATCH an assignment policy's membership rule
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies/<policyId>" -Body (@{
    specificAllowedTargets = @(@{ "@odata.type" = "#microsoft.graph.attributeRuleMembers"; membershipRule = '(user.department -eq "Sales")' })
} | ConvertTo-Json -Depth 5)

# Days remaining until the retirement deadline
([datetime]"2026-11-03" - (Get-Date)).Days
```

---
## 🎓 Learning Pointers

- **Three affected object types, three different failure modes**: dynamic groups and dynamic AUs silently *freeze* (with a processing-state property that misleadingly still reports `On`); entitlement management auto-assignment policies are explicitly *quarantined* (processing halts entirely, both additions and removals). A discovery sweep or remediation plan built around only one failure mode will miss the others. Reference: [Configure dynamic membership groups with the memberOf operator](https://learn.microsoft.com/en-us/entra/identity/users/groups-dynamic-rule-member-of)
- **The retirement reason is tenant-wide blast radius, not a per-object issue**: a single `memberOf` rule could slow dynamic-group processing for every dynamic group in the tenant — this is why there's no "just raise the limit" fix, and why the guidance is unconditional removal rather than throttled continued use.
- **`MembershipRuleProcessingState` is not a reliable signal for `memberOf`-specific health**, before or after the deadline — it reflects whether the group's rule engine is generally enabled, not whether a `memberOf`-based rule is actually still evaluating. Always inspect the rule text itself.
- **The preview's own pre-existing quirks (direct-membership-only, no live re-evaluation on source-group member removal) are easy to mistake for new retirement-related breakage** — confirm whether a reported symptom predates the deadline (a known preview limitation) or postdates it (an actual retirement effect) before diagnosing.
- **No feature-parity native replacement exists as of this writing** — Microsoft has stated an alternative is in development with no committed date; plan and execute migration now using supported operators, assigned membership, or external automation rather than deferring. Reference: [MemberOf Rule Operator Retired from Entra ID in Nov 2026 — office365itpros](https://office365itpros.com/2026/08/07/memberof-rule-operator/)
- **When rewriting rules, apply the general dynamic-rule efficiency guidance** (prefer `-eq`/`-startsWith`/`-endsWith` over `-match`/`-contains`, collapse `-or` chains into `-in`) — this both produces a cleaner replacement rule and reduces exactly the kind of tenant-wide processing cost that motivated retiring `memberOf` in the first place. Reference: [Create simpler, more efficient rules for dynamic membership groups](https://learn.microsoft.com/en-us/entra/identity/users/groups-dynamic-rule-more-efficient)
