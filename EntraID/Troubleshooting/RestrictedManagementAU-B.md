# Entra ID Restricted Management Administrative Units (RMAU) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Triage

This topic covers **Restricted Management Administrative Units** — a special-cased Administrative Unit (AU) where `isMemberManagementRestricted = true`, which blocks even tenant-scoped Global Administrators from modifying member objects unless they're explicitly assigned a role scoped to that specific AU. It is distinct from a regular (non-restricted) AU, which only scopes *where* a role applies without blocking tenant-level admins — see `Get-MgDirectoryAdministrativeUnit` output's `IsMemberManagementRestricted` property to tell the two apart at a glance.

```powershell
Connect-MgGraph -Scopes "AdministrativeUnit.Read.All"

# 1. Confirm the AU in question is actually restricted (not a regular AU)
Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId "<AU-object-id>" |
    Select-Object DisplayName, Id, @{N='IsRestricted';E={$_.AdditionalProperties.isMemberManagementRestricted}}

# 2. Confirm what's actually a member (only Users, Devices, Security Groups are ever valid here)
Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId "<AU-object-id>"

# 3. Confirm who is assigned a role scoped to THIS AU specifically
Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId "<AU-object-id>"

# 4. If a Global Admin/Helpdesk Admin says they "can't" reset a password or edit a group —
#    confirm the object really is RMAU-protected (this is almost always the answer)
Get-MgUser -UserId "<UPN>" -Property Id | ForEach-Object {
    Get-MgDirectoryAdministrativeUnit -Filter "members/any(m: m/id eq '$($_.Id)')" -ExpandProperty "members"
}

# 5. Confirm whether the affected admin's role assignment is scoped to the RMAU at all
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<admin-object-id>'"
```

| Result | Action |
|--------|--------|
| Admin is Global Admin/Privileged Role Admin and expects to edit the object directly | → Fix 1: This is by design — explain the model, don't troubleshoot as a bug |
| Admin needs ongoing access to manage RMAU members | → Fix 2: Assign an AU-scopable role at the RMAU scope |
| Object type is a Microsoft 365/mail-enabled security/distribution group | → Fix 3: Not a supported RMAU member type — use a regular AU or restructure |
| Admin was recently removed from the RMAU-scoped role assignment (job change/offboarding) | → Fix 4: Global Admin/Privileged Role Admin must re-assign, an auditable action |
| A Global Administrator account itself is an RMAU member and needs a password reset | → Fix 5: No AU-scopable role covers this — must be removed from the RMAU first |
| Need PIM eligible activation, an access review, or a Lifecycle Workflow against an RMAU member | → Fix 6: Not supported — RMAU is fundamentally incompatible with Entra ID Governance features |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Administrative Unit created with isMemberManagementRestricted = true]
  └─ PERMANENT at creation time — cannot be toggled after the fact
         │
[Object added as a DIRECT member of the RMAU]
  └─ Supported: Users, Devices, Security Groups (only)
  └─ NOT supported: Microsoft 365 groups, mail-enabled security groups, distribution groups
  └─ Restriction is NOT inherited — a group's own members are unaffected unless separately added
         │
[Tenant-scoped roles (Global Administrator, Privileged Role Administrator, resource-scoped
 Groups/User Administrator, group/device owners) — ALL BLOCKED from modifying the object]
         │
[Only a role explicitly assigned AT THE SCOPE OF THIS RMAU (or another RMAU the object
 also belongs to) can modify Entra properties, reset passwords, or change group membership]
         │
[Global Administrator / Privileged Role Administrator CAN still manage the RMAU container
 itself — create/delete it, add/remove members, assign roles at its scope — just not
 modify the protected objects' properties directly]
         │
[Entra ID Governance features (PIM, Entitlement Management, Lifecycle Workflows,
 Access Reviews) DO NOT WORK against RMAU members — hard incompatibility, not a bug]
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the AU is actually restricted**
```powershell
Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId "<AU-object-id>" |
    Select-Object DisplayName, @{N='IsRestricted';E={$_.AdditionalProperties.isMemberManagementRestricted}}
```
If `IsRestricted` is `$null`/`false`, this is a regular AU — the "Global Admin can't edit this" symptom has a different cause; regular AUs never block tenant-scoped admins.

**2. Confirm the object's actual membership**
```powershell
Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId "<AU-object-id>"
```
Remember: only direct members are protected. If someone expects a group's *members* to be protected because the group itself is an RMAU member, that expectation is wrong — RMAUs don't nest or cascade.

**3. Confirm who holds a role scoped to this specific RMAU**
```powershell
Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId "<AU-object-id>"
```
This is the *only* set of people (plus Global Administrator/Privileged Role Administrator managing the RMAU container itself, not its members) who can make changes.

**4. Confirm the specific blocked operation against the "who can manage" table**

Some operations have no valid AU-scopable role at all (see Fix 5) — don't assume every blocked action has a workaround via role assignment.

---
## Common Fix Paths

<details><summary>Fix 1 — "I'm a Global Admin, why can't I edit this user/group?" (by design, not a bug)</summary>

Use when: A Global Administrator or Privileged Role Administrator reports being blocked from resetting a password, editing properties, or changing group membership for an object, and the object is confirmed (Triage step 1) to be an RMAU member.

This is the entire point of the feature — RMAUs exist specifically to stop tenant-scoped admins, including Global Administrators, from touching designated sensitive objects (executive accounts, Tier-0 security groups) without an explicit, auditable RMAU-scoped role assignment.

**No config change needed.** Explain the model, then route to Fix 2 if the admin has a legitimate, ongoing need to manage this object.

**Rollback:** N/A — not a fault condition.

</details>

<details><summary>Fix 2 — Assign an AU-scopable role at the RMAU scope</summary>

Use when: An admin has a legitimate ongoing need to manage members of a specific RMAU.

Only a Global Administrator or Privileged Role Administrator can perform this assignment (it's one of the few things they retain the ability to do against an RMAU — managing the container, not the members directly).

```powershell
$roleDefId = (Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq 'Helpdesk Administrator'").Id

$params = @{
    "@odata.type"    = "#microsoft.graph.unifiedRoleAssignment"
    RoleDefinitionId = $roleDefId
    PrincipalId      = "<admin-object-id>"
    DirectoryScopeId = "/administrativeUnits/<AU-object-id>"
}
New-MgRoleManagementDirectoryRoleAssignment -BodyParameter $params
```

Global Administrator and Privileged Role Administrator themselves **cannot** be assigned at AU scope — they only exist at tenant scope by design, which is exactly why they can't be used to grant themselves RMAU-member access this way (see Fix 5 for the specific edge case this creates).

**Rollback:** `Remove-MgRoleManagementDirectoryRoleAssignment -UnifiedRoleAssignmentId "<assignment-id>"` — the admin immediately loses management rights over this RMAU's members.

</details>

<details><summary>Fix 3 — Unsupported group type as an RMAU member</summary>

Use when: An attempt to add a Microsoft 365 group, mail-enabled security group, or distribution group to an RMAU fails or behaves unexpectedly.

Only **Users, Devices, and Security Groups** can be members of a restricted management AU. Microsoft 365 groups, mail-enabled security groups, and distribution groups can be members of a *regular* (non-restricted) AU, but not a restricted one.

If the goal is protecting a Microsoft 365 group specifically, there is no direct RMAU equivalent — consider restructuring access control around a security group instead, or protecting the group's owners/critical members individually.

**Rollback:** N/A — attempting to add an unsupported type simply fails; no state change to roll back.

</details>

<details><summary>Fix 4 — Admin previously scoped to the RMAU changed roles / left</summary>

Use when: An admin who used to manage an RMAU's members has changed teams, been offboarded, or otherwise lost their RMAU-scoped role assignment, and management access needs to be re-established.

Only a Global Administrator or Privileged Role Administrator can re-assign — either to a new admin or to themselves (the latter is an explicit, auditable action, not an implicit privilege).

```powershell
New-MgRoleManagementDirectoryRoleAssignment -BodyParameter @{
    "@odata.type"    = "#microsoft.graph.unifiedRoleAssignment"
    RoleDefinitionId = $roleDefId
    PrincipalId      = "<new-admin-or-self-object-id>"
    DirectoryScopeId = "/administrativeUnits/<AU-object-id>"
}
```

**Rollback:** Remove the reassigned role once a permanent owner is identified, if it was only a stopgap.

</details>

<details><summary>Fix 5 — A Global Administrator is themselves an RMAU member and needs a password reset</summary>

Use when: A Global Administrator account was added to an RMAU (e.g., an executive who also happens to hold that role), and no administrator anywhere can reset their password.

This happens because **no role that can be assigned at AU scope is capable of resetting a Global Administrator's password** — Helpdesk Administrator and similar AU-scopable roles are explicitly restricted from acting on higher-privileged accounts, and Global Administrator/Privileged Role Administrator themselves cannot be assigned at AU scope at all. The RMAU has created a genuine dead end for this specific operation.

**Fix:** A Global Administrator or Privileged Role Administrator must first **remove the account from the RMAU entirely**, then reset the password using their normal tenant-scoped rights, then optionally re-add the account to the RMAU afterward if the protection is still wanted going forward.

```powershell
Remove-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId "<AU-object-id>" -DirectoryObjectId "<user-object-id>"
# ... reset password via normal Global Admin rights ...
# Optionally re-add:
New-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId "<AU-object-id>" -BodyParameter @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/<user-object-id>" }
```

**Rollback:** N/A — this is itself the fix; re-adding to the RMAU afterward restores the original protective posture.

</details>

<details><summary>Fix 6 — PIM / Access Reviews / Lifecycle Workflows / Entitlement Management don't work against an RMAU member</summary>

Use when: An eligible PIM assignment, an access review, an entitlement management access package, or a Lifecycle Workflow task silently fails, doesn't apply, or behaves unexpectedly for a user or group that turns out to be an RMAU member.

This is a **hard, documented incompatibility**, not a configuration error to chase. Groups and users in a restricted management AU cannot be managed with any Microsoft Entra ID Governance feature (PIM, Entitlement Management, Lifecycle Workflows, Access Reviews) at all.

**Fix:** There is no workaround that keeps both the RMAU protection and the Governance feature active simultaneously for the same object. Choose one: remove the object from the RMAU if Governance-feature coverage is required, or accept that RMAU-protected objects are managed manually/out-of-band from Governance tooling.

**Rollback:** N/A — this is a design constraint to plan around, not a state to revert.

</details>

---
## Escalation Evidence

```
RMAU ESCALATION
================
Date/Time                          :
Tenant ID                          :
RMAU display name / object ID      :
IsMemberManagementRestricted       : (confirm true)
Affected object (user/device/group):
Operation attempted                :
Requesting admin's tenant role(s)  :
Requesting admin's RMAU-scoped role (if any) :
Roles currently scoped to this RMAU (Get-MgDirectoryAdministrativeUnitScopedRoleMember output) :
Is this a Governance-feature conflict (PIM/Access Review/Lifecycle Workflow/Entitlement Mgmt)? :
Steps already tried                :
```

---
## 🎓 Learning Pointers

- **The single most common "ticket" for this topic is a Global Administrator discovering the feature exists the hard way.** Before troubleshooting anything, confirm the object is actually RMAU-protected (Triage step 1) — if so, the "fix" is almost always explaining the model and routing to an RMAU-scoped role assignment, not finding a workaround for the block itself. [Restricted management administrative units in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/admin-units-restricted-management)
- **RMAU membership is direct-only and never cascades.** Adding a security group to an RMAU protects the group object itself (its own properties, ownership, and — for role-assignable groups — its membership), not the Entra properties of the users who happen to be members of that group. This trips up admins expecting AU-style inheritance.
- **The setting is permanent at creation — there's no "make this AU restricted later" path.** If a regular AU needs to become an RMAU, a new RMAU must be created and objects moved into it; plan the restricted/non-restricted decision before creating the AU, not after.
- **Global Administrator and Privileged Role Administrator keep control of the container, not the contents.** They can always create/delete the RMAU and reassign its scoped roles (an auditable action), but they cannot reach in and edit a member object's properties directly — a deliberate two-key design, not an oversight.
- **This feature is fundamentally incompatible with Entra ID Governance tooling.** If a client wants both RMAU protection for an executive account AND that account managed via PIM eligible role assignment or covered by Access Reviews, they need to be told plainly that they can't have both simultaneously — this isn't a configuration gap to close, it's a documented limitation.
- **Community/reference:** [Create or delete administrative units](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/admin-units-manage) | [Administrative units troubleshooting and FAQ](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/admin-units-faq-troubleshoot)
