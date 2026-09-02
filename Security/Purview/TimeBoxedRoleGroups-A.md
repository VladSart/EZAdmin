# Purview Time-Boxed Role Group Assignments — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

Covers Microsoft Purview's native **time-limited role group assignment** feature: setting an expiration
date (1 day to 2 years) directly on a role group member (user or, in commercial cloud, security group),
after which Purview automatically removes that assignment. Rolled out by Microsoft starting late July
2026, with completion expected by late August 2026.

Does **not** cover:
- Microsoft Entra Privileged Identity Management (PIM) for Groups — the pre-existing, more complex
  just-in-time activation pattern this feature partially supersedes for simple time-boxing use cases
  (still relevant for full JIT workflows — see How It Works below).
- eDiscovery Manager / eDiscovery Administrator role groups — explicitly excluded from this feature.
- General Purview role group architecture (creating custom role groups, role assignment policies) — see
  `ComplianceManager-A.md` and this folder's other `-A.md` files for the broader RBAC model each
  solution builds on.

Assumes: Microsoft Purview compliance portal access with Role Management permissions (Organization
Management or Role Management role group membership), Microsoft 365 commercial cloud for
security-group-based assignments specifically (GCC/sovereign cloud limitation noted below).

---
## How It Works

<details><summary>Full architecture</summary>

**The problem this solves.** Microsoft Entra ID Privileged Identity Management (PIM) has long given
admins a native way to keep privileged directory-role access temporary. Microsoft Purview's own role
groups — the RBAC layer controlling access to DLP, eDiscovery, Insider Risk Management, Communication
Compliance, and most other compliance-portal capabilities — had no equivalent. An admin who wanted
time-bound Purview access had to build an indirect chain:

```
User → PIM-eligible security group → Purview role group assignment
```

1. Create a security group in Microsoft Entra ID.
2. Assign that security group (not individual users) to the target Purview role group.
3. Configure the security group in PIM for Groups.
4. Make users **eligible** members of the group rather than permanent members.
5. Users activate their group membership through PIM when they need Purview access; when the PIM
   activation expires, group membership — and therefore the inherited Purview role group access —
   is revoked too.

This works and remains the right tool for genuine **just-in-time** (JIT) workflows requiring an
approval/activation step. But when the actual requirement is simpler — "this contractor needs DLP
Compliance Manager access until their contract ends in 90 days, no activation ceremony needed" — the
PIM-for-Groups chain is more infrastructure than the problem calls for.

**The native solution.** Purview now lets admins set an expiration date directly on a role group
member assignment, for both individual users and (commercial-cloud-only) security groups:

```
Purview portal > Settings > Roles and scopes > Role groups > <role group> > Members >
  Add member > select user(s)/group(s) > select the newly-added member(s) > Edit expiration >
  choose a date 1 day - 2 years out > Apply
```

When the expiration date arrives, Purview automatically removes that specific role group assignment —
no activation, no approval step, no PIM licensing dependency (this feature does not require Entra ID
P2/PIM licensing, unlike the group-based JIT pattern it complements).

**Existing assignments are not retroactively changed.** When this capability rolls out to a tenant, all
pre-existing role group memberships remain permanent ("No expiry") until an admin explicitly opens that
assignment and sets a date. This is a deliberate non-breaking rollout choice — Microsoft does not assume
every existing permanent assignment should suddenly acquire a default expiration.

**What expiration does and does not revoke.** Setting an expiration on one assignment path removes only
that path. Purview's RBAC model allows the same role group to be reached multiple ways (direct user
assignment, security-group assignment, potentially both simultaneously) — each has an independent
expiration clock. Similarly, a user might separately hold an overlapping Microsoft Entra ID directory
role (e.g., Compliance Administrator) that grants similar capability through an entirely different
authorization path; Purview's expiration mechanism has no visibility into or effect on Entra directory
role assignments. Effective access is the union of every valid grant across both systems — admins must
check both when confirming a user has actually lost access.

**No PowerShell surface (as of this writing).** Unlike much of Purview's older role/permission
management surface (`Get-RoleGroup`, `Get-RoleGroupMember`, `New-RoleGroupMember`), expiration
configuration is portal-only. `Get-RoleGroupMember` still enumerates current members but does not
expose an expiration-date property — there is no cmdlet-based way to audit expiration dates at scale.
This is the single biggest operational gap admins hit trying to build reporting or automation around
this feature; the workaround is manual portal review or (if available) exporting the Members view.

**eDiscovery exclusion rationale.** eDiscovery Manager and eDiscovery Administrator role groups do not
support automatic expiration. Access to active legal holds and case data carries continuity
requirements (an expiring assignment mid-litigation-hold review would be operationally dangerous) that
make silent, date-driven removal an inappropriate default for this specific pair of role groups — those
assignments must be manually managed and removed.

</details>

---
## Dependency Stack

```
[Microsoft Purview compliance portal]                    ← where this feature lives entirely; no
        │                                                     dedicated Graph/PowerShell API surface
[Role Management permission / Organization Management     ← required to view/edit role group members
 or Role Management role group membership]                    and their expiration
        │
[Target role group — supports expiration]                 ← ALL built-in/custom role groups EXCEPT
        │                                                     eDiscovery Manager / eDiscovery Administrator
[Member type]
  ├─ Individual user                                       ← direct expiration, all commercial +
  │                                                             government cloud environments
  └─ Security group (commercial cloud only)                ← group-based assignment + its expiration;
                                                                 NOT available in GCC/sovereign clouds
        │
[Expiration value: 1 day – 2 years, or No expiry]          ← set/edited/extended/removed independently
        │                                                     per assignment, per member
[Purview's automatic removal job]                          ← removes the SPECIFIC expired assignment
        │                                                     only; runs on Microsoft's schedule, not
        │                                                     admin-controlled
[Effective access = union of ALL valid grants]             ← other Purview assignment paths (direct +
                                                                group) AND overlapping Entra ID directory
                                                                roles are evaluated independently and are
                                                                NOT touched by this expiration mechanism
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| User loses Purview access with zero warning | Expected — no proactive expiration notification exists | Portal "My Permissions" page for the user |
| Admin can't find an expiration option for a role group | Role group is eDiscovery Manager or eDiscovery Administrator | Confirm role group name against the exclusion list |
| Expiration date set on a security group has no visible option in a GCC tenant | Security-group-based assignment/expiration is commercial-cloud-only | Confirm tenant cloud environment |
| User retains access after their assignment's documented expiration | A second assignment path (direct + group) or an overlapping Entra role is still granting access | `Get-RoleGroupMember`, then check Entra `Get-MgUserAppRoleAssignment` |
| Existing (pre-feature) assignments show "No expiry" and admin expected a default | Rollout is non-retroactive by design; existing assignments must be manually edited | Confirm this is expected, not a fault |
| No PowerShell cmdlet returns the expiration date for auditing | Feature has no dedicated PowerShell/Graph surface as of this writing | Portal Members view is the only authoritative source |
| Admin wants approval-gated activation, not just a fixed end date | Wrong tool for the requirement — evaluate PIM for Groups instead | See Remediation Playbook 2 |

---
## Validation Steps

**1. Confirm role group management access**
```powershell
Connect-IPPSSession -UserPrincipalName <adminUPN>
Get-RoleGroup -Identity "Role Management" | Get-RoleGroupMember
```
Good: your admin account (or its group) appears as a member — you have rights to manage other role
groups' membership and expiration. Bad: not listed — request Role Management or Organization
Management role group membership before proceeding.

**2. Confirm current membership for the target role group**
```powershell
Get-RoleGroupMember -Identity "<RoleGroupName>"
```
Good: expected members returned. This does not show expiration — cross-check the portal Members tab
for the `Expires on` column per member.

**3. Confirm exclusion status before troubleshooting a missing expiration option**
Compare the role group name exactly against `eDiscovery Manager` and `eDiscovery Administrator`. Any
other role group (built-in or custom) supports expiration.

**4. Confirm cloud environment for security-group-based assignments**
```powershell
Get-OrganizationConfig | Select-Object Name, IsDehydrated
# Cross-check tenant type via the Microsoft 365 admin center's "About your organization" or
# confirm directly with the client which government/commercial offering they're licensed under.
```
Security-group role-group assignment (and its expiration) is documented as supported only for
Microsoft 365 commercial cloud organizations at this time.

**5. Confirm no orphaned overlapping access after an expected expiration**
```powershell
Get-RoleGroupMember -Identity "<RoleGroupName>"
Get-MgUserAppRoleAssignment -UserId "<user@contoso.com>"
```
Good: user no longer appears in either the direct role group membership or via any group they belonged
to, and holds no overlapping Entra directory role. Bad: still present in one of these — that is the
active grant keeping their access alive, not a defect in the expired assignment.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm this is actually the expiration feature, not a manual removal.** Check the audit
log / Unified Audit Log for a `Remove role group member` or equivalent event and its actor — an
automatic system-driven removal at exactly the documented expiration date confirms this feature
operated as designed rather than an admin manually removing access (which would appear with a human
actor).

**Phase 2 — Enumerate all assignment paths before troubleshooting "access didn't go away."** Purview's
RBAC allows multiple simultaneous paths to the same role group; always check both direct and
group-based membership, plus any overlapping Entra ID role, before concluding the expiration failed.

**Phase 3 — Confirm role group and cloud-environment eligibility.** Rule out the eDiscovery exclusion
and the GCC/sovereign-cloud security-group limitation before assuming a configuration mistake.

**Phase 4 — For reporting/audit requirements, plan around the missing PowerShell surface.** If a client
needs scheduled reporting on upcoming expirations, there is no cmdlet to query this — recommend a
manual portal review cadence or, if in place, an internal governance tool with API access to the
underlying Purview/Graph surface (verify current API support before promising this capability, as it
was not exposed at initial feature rollout).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standardize expiration for contractor/temporary-access role groups</summary>

```
1. Identify role groups commonly granted to contractors/temporary staff (e.g., DLP Compliance
   Management, Compliance Data Administrator for a specific short-term project).
2. For every NEW assignment to those role groups going forward, set an expiration date matching the
   contract/engagement end date (or a conservative default, e.g., 90 days, with a renewal process).
3. For EXISTING assignments in that category, run an access review: enumerate current members via
   Get-RoleGroupMember, cross-reference against HR/contract end dates, and manually apply expiration
   dates via the portal.
4. Document the process so it becomes standard practice for onboarding contractors into Purview
   role groups, not an ad hoc one-time cleanup.
```

**Rollback:** Edit any individual assignment back to "No expiry" if a contractor converts to a
permanent role requiring ongoing access.

</details>

<details><summary>Playbook 2 — Choose between static expiration and full PIM-for-Groups JIT</summary>

```
Use native expiration (this feature) when:
  - The requirement is "access should end on/around a known date"
  - No approval/activation ceremony is required
  - The org doesn't have Entra ID P2/PIM licensing, or doesn't want the added process overhead

Use PIM for Groups (User → PIM-eligible security group → Purview role group) when:
  - Access should be dormant by default and require active justification/approval per use
  - Full audit trail of WHO activated access WHEN (not just when it expired) is a compliance requirement
  - The org already has a PIM-for-Groups pattern established for other applications/roles and wants
    Purview access managed consistently within that same model
```

**Rollback:** Both patterns can coexist; migrating from one to the other is a manual re-configuration,
not a reversible toggle.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects role group membership and adjacent-signal evidence for a Purview time-boxed
    assignment escalation. Does not read expiration dates directly (no cmdlet exposes them).
#>
Connect-IPPSSession -UserPrincipalName <adminUPN>

$roleGroupName = "<RoleGroupName>"
$evidence = [ordered]@{
    RoleGroupName      = $roleGroupName
    CurrentMembers     = Get-RoleGroupMember -Identity $roleGroupName | Select-Object Name, RecipientType
    IsExclusionRoleGrp = $roleGroupName -in @("eDiscovery Manager", "eDiscovery Administrator")
    AllRoleGroups      = Get-RoleGroup | Select-Object Name
}
$evidence | ConvertTo-Json -Depth 4 | Out-File "$env:TEMP\PurviewTimeBoxedRoleGroups-Evidence.json"
Write-Host "Evidence written to $env:TEMP\PurviewTimeBoxedRoleGroups-Evidence.json"
Write-Host "IMPORTANT: cross-check the Purview portal's Members tab manually for per-member expiration dates — no cmdlet exposes this field."
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Connect-IPPSSession -UserPrincipalName <adminUPN>` | Connect to Security & Compliance PowerShell |
| `Get-RoleGroup` | List all Purview role groups |
| `Get-RoleGroupMember -Identity "<RoleGroupName>"` | List current members of a role group (no expiration data) |
| `Get-RoleGroupMember -Identity "Role Management"` | Confirm who can manage role group membership/expiration |
| `Get-MgUserAppRoleAssignment -UserId <UPN>` | Check for overlapping Entra ID directory role grants |
| `Get-DistributionGroupMember -Identity "<SecurityGroupName>"` | Confirm a user's membership in a group assigned to a role group |
| Purview portal > Settings > Roles and scopes > Role groups | The only place to view/set/edit expiration dates |

---
## 🎓 Learning Pointers

- **This is a genuinely new capability (rollout late July–August 2026), not a rename of something
  older** — treat it as its own feature when researching, not a variant of PIM. [Auto-Expiring Role Group Assignments in Microsoft Purview](https://blog.admindroid.com/microsoft-purview-role-group-permission-expiration/)
- **The lack of a PowerShell/Graph surface at launch is a real operational gap** — flag this explicitly
  to clients who want automated compliance reporting on temporary access; the honest answer today is
  "manual portal review," not "we'll script it."
- **Effective access is always a union across systems** — Purview role groups, Entra directory roles,
  and (for some capabilities) SharePoint/Exchange-native permissions can all independently grant
  overlapping capability. An expiration in one system is never proof of full access removal on its own.
- **This does not replace access reviews** — expiration answers "how long," access reviews answer
  "should this still exist." Recommend both together for a mature governance posture. [Create access reviews in Microsoft Entra](https://blog.admindroid.com/create-access-reviews-in-entra-id/)
- **eDiscovery's exclusion reflects a real operational risk, not an oversight** — don't file feedback
  requesting expiration support for eDiscovery Manager/Administrator without first confirming the
  client understands why continuity of legal-hold access matters more than automatic cleanup there.
