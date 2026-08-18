# Administrative Units — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. A delegated admin can't manage someone they should be able to, a Global Admin is unexpectedly blocked, or a dynamic AU isn't populating.
>
> For a **Restricted Management AU (RMAU)** ticket specifically — `isMemberManagementRestricted = true`, blocking even Global Administrator — go straight to `RestrictedManagementAU-B.md` instead; this file covers regular AU mechanics and only touches RMAU where it shares the same underlying role-assignment model.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---
## Triage

Requires `AdministrativeUnit.Read.All` and `RoleManagement.Read.Directory` to read; `AdministrativeUnit.ReadWrite.All` and `RoleManagement.ReadWrite.Directory` to fix.

```powershell
Connect-MgGraph -Scopes "AdministrativeUnit.Read.All","RoleManagement.Read.Directory","Directory.Read.All" -NoWelcome

# 1. Find the administrative unit and its restricted-management flag
$au = Get-MgDirectoryAdministrativeUnit -Filter "displayName eq '<AUName>'"
$au | Select-Object Id, DisplayName, IsMemberManagementRestricted, MembershipType, MembershipRule

# 2. Is the target object a DIRECT member? (group membership does NOT cascade)
Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $au.Id |
    Select-Object Id, @{N="Type";E={$_.AdditionalProperties['@odata.type']}}

# 3. Who holds a role scoped to THIS administrative unit specifically?
Get-MgRoleManagementDirectoryRoleAssignment -Filter "directoryScopeId eq '/administrativeUnits/$($au.Id)'" -ExpandProperty RoleDefinition |
    Select-Object PrincipalId, @{N="Role";E={$_.RoleDefinition.DisplayName}}

# 4. Does the target user hold ANY directory role themselves? (blocks AU-scoped admin actions against them)
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<targetUserObjectId>'" -ExpandProperty RoleDefinition |
    Select-Object @{N="Role";E={$_.RoleDefinition.DisplayName}}, DirectoryScopeId

# 5. Confirm the actor's own role and whether it's tenant-scoped or AU-scoped
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<actorObjectId>'" -ExpandProperty RoleDefinition |
    Select-Object @{N="Role";E={$_.RoleDefinition.DisplayName}}, DirectoryScopeId
```

**Interpret — if X then do Y:**

| Finding | Next action |
|---|---|
| Target user is a member of a GROUP that's in the AU, but not a direct member of the AU itself | Expected behavior, not a bug — see [Fix 1](#fix-1--au-scoped-admin-cant-manage-a-user-they-should-be-able-to) |
| Target user holds any directory role at all (even an unrelated, low-privilege one) | AU-scoped admin action is blocked by design (anti-escalation carve-out) — see [Fix 2](#fix-2--au-scoped-password--helpdesk--user-admin-cant-act-on-a-specific-user) |
| Member was just added/removed and the portal still shows the old state | Propagation delay — see [Fix 3](#fix-3--just-changed-membership-and-the-portal-hasnt-caught-up) |
| Dynamic AU rule save fails with "Failed to update administrative unit properties" | Bad property/type in the rule, or a targeted member lacks a P1 license — see [Fix 4](#fix-4--dynamic-au-rule-wont-save) |
| Trying to manually Add/Remove a member on an AU that has a dynamic membership rule | Not permitted regardless of role — see [Fix 5](#fix-5--cant-manually-add-remove-a-member-on-a-dynamic-au) |
| Global Administrator or Privileged Role Administrator can't modify a user/group and sees "member of a restricted management administrative unit" | Expected — see [Fix 6](#fix-6--global-admin-blocked-by-a-restricted-management-au) |
| A service principal or guest user has an AU-scoped role assigned but every action still fails as unauthorized | Missing tenant-wide read permission — see [Fix 7](#fix-7--service-principalguest-au-scoped-role-doesnt-work) |

---
## Dependency Cascade

<details><summary>What must be true for an AU-scoped admin action to succeed — click to expand</summary>

```
[Administrative unit object exists]
    │   Created by a Privileged Role Administrator (the only role that can create AUs)
    │
    ▼
[Target object is a DIRECT member of the administrative unit]
    │   Adding a GROUP to an AU brings the group itself into scope, NOT its members.
    │   A User Administrator scoped to that AU can rename/manage the group's
    │   membership list, but CANNOT touch the individual users inside it unless
    │   those users are separately, directly added as AU members.
    │
    ▼
[Role assignment exists with directoryScopeId = "/administrativeUnits/<id>"]
    │   NOT a tenant-scoped assignment of the same role — those are entirely
    │   separate grants that happen to share a role name.
    │   Only a role from the AU-scope-eligible list (or a qualifying custom role)
    │   can be assigned this way — Global Administrator and Privileged Role
    │   Administrator CANNOT be scoped to an AU at all.
    │
    ├── Human principal (user) — works immediately once assigned
    │
    └── Service principal / guest user — ALSO needs a separate tenant-wide
        read role (Directory Readers, or broader) or the AU-scoped assignment
        is silently useless; SPs/guests get no default directory read access.
    │
    ▼
[Target user is NOT protected by the anti-escalation carve-out]
    │   AU-scoped Helpdesk/Password/User Administrator cannot reset passwords,
    │   read/modify auth methods, change sensitive properties, or delete/restore
    │   ANY user who holds ANY directory role — administrator or not, related
    │   to the AU or not. Only Privileged Authentication Administrator (a role
    │   that CANNOT itself be AU-scoped) can act on other admins' auth methods.
    │
    ▼
[If the AU is a Restricted Management AU: the acting principal's role assignment
 is ITSELF scoped to this specific restricted management AU]
    │   Tenant-wide roles — including Global Administrator and Privileged Role
    │   Administrator — are hard-blocked from modifying Entra properties of
    │   restricted-management-AU members, full stop, regardless of every layer
    │   above being satisfied. The only way in is to explicitly self-assign an
    │   AU-scoped role (an auditable event) or already hold one.
    │
    ▼
[Action succeeds]
```

**What silently breaks this and produces confusing tickets:**
- "I added the Sales team group to the AU, why can't the Sales AU admin reset passwords for anyone on the team?" — group-in-AU only brings the group under management, never its members.
- "The AU admin says they can't reset this one user's password, but everyone else in the AU works fine" — that one user almost certainly holds a role somewhere (even an unrelated, unscoped one like Printer Administrator), tripping the anti-escalation block.
- "I'm a Global Admin and I'm locked out of a user I created" — restricted management AU membership blocks even Global Administrator; this is the feature working as designed, not a fault.
- "The automation account has the role assigned in the portal, every call still 403s" — service principals need a supplementary tenant-wide Directory Readers-equivalent role; the AU-scoped assignment alone grants no read baseline.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the AU, its type, and its membership mode**
```powershell
Connect-MgGraph -Scopes "AdministrativeUnit.Read.All" -NoWelcome
$au = Get-MgDirectoryAdministrativeUnit -Filter "displayName eq '<AUName>'"
$au | Select-Object Id, DisplayName, IsMemberManagementRestricted, MembershipType, MembershipRule
```
`IsMemberManagementRestricted: true` = Restricted Management AU (immutable, set only at creation). `MembershipType: Dynamic` = rule-based, no manual add/remove.

**Step 2 — Confirm the target is a DIRECT member, not a member-of-a-member**
```powershell
Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $au.Id |
    Select-Object Id, @{N="Type";E={$_.AdditionalProperties['@odata.type']}}
```
If the target user's `Id` isn't in this list but a group they belong to is, that's the answer — the group's membership is managed, the group's *members* are not, unless separately added.

**Step 3 — Confirm the actor's role assignment is actually AU-scoped**
```powershell
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<actorObjectId>'" -ExpandProperty RoleDefinition |
    Select-Object @{N="Role";E={$_.RoleDefinition.DisplayName}}, DirectoryScopeId
```
`DirectoryScopeId: /` means tenant-wide (unrelated to any AU). `DirectoryScopeId: /administrativeUnits/<id>` means scoped — confirm the `<id>` matches the AU in question; an admin can easily hold the right role scoped to the *wrong* AU.

**Step 4 — Check the target user for the anti-escalation carve-out**
```powershell
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<targetUserObjectId>'" -ExpandProperty RoleDefinition |
    Select-Object @{N="Role";E={$_.RoleDefinition.DisplayName}}, DirectoryScopeId
```
Any result at all (tenant-scoped or AU-scoped, any role) means AU-scoped Helpdesk/Password/User Administrator cannot reset this user's password or touch their auth methods — this is enforced regardless of how unrelated the held role is to the ticket at hand.

**Step 5 — For Restricted Management AUs, confirm who's actually allowed in**
```powershell
if ($au.IsMemberManagementRestricted) {
    Get-MgRoleManagementDirectoryRoleAssignment -Filter "directoryScopeId eq '/administrativeUnits/$($au.Id)'" -ExpandProperty RoleDefinition |
        Select-Object PrincipalId, @{N="Role";E={$_.RoleDefinition.DisplayName}}
}
```
If this is empty, **nobody** can currently modify Entra properties of the RMAU's members — not even Global Administrator — until a Global Administrator or Privileged Role Administrator explicitly self-assigns (or assigns someone) an AU-scoped role here.

**Step 6 — For service principals/guests, confirm the supplementary read role**
```powershell
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<spOrGuestObjectId>' and directoryScopeId eq '/'" -ExpandProperty RoleDefinition |
    Select-Object @{N="Role";E={$_.RoleDefinition.DisplayName}}
```
Missing `Directory Readers` (or broader) here — with only the AU-scoped assignment present — is the exact cause of "assigned in the portal but every Graph call fails."

---
## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — AU-scoped admin can't manage a user they should be able to</summary>

**Symptom:** An AU-scoped Groups/User Administrator manages a group fine, but can't touch the individual members of that group — reset a password, edit a profile field, etc.

Confirm via Diagnosis Step 2 that the user is not a direct AU member. Then add them directly:

```powershell
Connect-MgGraph -Scopes "AdministrativeUnit.ReadWrite.All" -NoWelcome
$user = Get-MgUser -UserId "<upn>"
New-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId $au.Id -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)"
}
```

If the AU uses a dynamic membership rule instead, this user must match the rule (see Fix 5) — you cannot mix manual adds into a dynamic AU.

**Rollback:** `Remove-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId $au.Id -DirectoryObjectId $user.Id`

</details>

<details id="fix-2"><summary>Fix 2 — AU-scoped Password / Helpdesk / User Admin can't act on a specific user</summary>

**Symptom:** Works for every other user in the AU, fails specifically for one — usually password reset or an auth-method change, sometimes a "sensitive property" edit (phone number, alternate email).

This is the documented anti-escalation carve-out, not a bug. Confirm via Diagnosis Step 4:

```powershell
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<targetUserObjectId>'" -ExpandProperty RoleDefinition
```

If the target holds ANY directory role — including something unrelated like Printer Administrator scoped somewhere else entirely — an AU-scoped Helpdesk/Password/User Administrator cannot act on them. There is no AU-scope workaround for this by design.

**Resolution paths, in order of preference:**
1. If the target's held role is stale/unneeded, have someone with `RoleManagement.ReadWrite.Directory` remove it, then retry.
2. If the role is legitimate, escalate to a **Privileged Authentication Administrator** (tenant-scoped only — cannot itself be AU-scoped) for auth-method/password actions, or a **Global Administrator**/**Privileged Role Administrator** for anything broader.

**Rollback:** N/A — this is a permission boundary, not a state change.

</details>

<details id="fix-3"><summary>Fix 3 — Just changed membership and the portal hasn't caught up</summary>

**Symptom:** Added or removed a member seconds ago; the Administrative Units pane in the Entra admin center still shows the old list.

```powershell
Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $au.Id -Property Id |
    Where-Object { $_.Id -eq "<expectedObjectId>" }
```

Query Graph directly (as above) rather than trusting the portal in the first few minutes — propagation can take a short while depending on tenant size and current load. If Graph itself doesn't reflect the change after ~10 minutes, re-run the add/remove call and check for an error the first attempt may have swallowed silently in a script.

**Rollback:** N/A — this is a timing issue, not a broken state.

</details>

<details id="fix-4"><summary>Fix 4 — Dynamic AU rule won't save</summary>

**Symptom:** `Failed to update administrative unit properties` when saving a rule for dynamic membership in the rule builder.

Two most common causes, in order of likelihood:

```powershell
# Cause A — check every AU member currently matched (or about to be matched) has a P1 license
Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $au.Id |
    ForEach-Object { Get-MgUserLicenseDetail -UserId $_.Id | Select-Object SkuPartNumber }

# Cause B — validate the rule's property/value types directly rather than guessing
$au.MembershipRule
```

Cause A: rules for dynamic membership require a Microsoft Entra ID P1 license on every member the rule would match — an unlicensed match fails the whole save. Cause B: a supplied property value has the wrong type (string vs. Boolean vs. string-collection) for the operator used — cross-check the exact attribute against the dynamic-membership rule reference before resubmitting.

Also confirm the rule targets exactly ONE object type (`user` OR `device`, never both) — a mixed-type rule is rejected outright.

**Rollback:** the AU keeps its previous (working) rule until a new one successfully saves — no partial-state risk.

</details>

<details id="fix-5"><summary>Fix 5 — Can't manually Add/Remove a member on a dynamic AU</summary>

**Symptom:** Even a Privileged Role Administrator gets blocked trying to manually add or remove a member from an AU that has `MembershipType: Dynamic`.

Expected — once an AU has a rule for dynamic membership, ALL membership changes must go through editing the rule itself:

```powershell
Update-MgDirectoryAdministrativeUnit -AdministrativeUnitId $au.Id -MembershipRule "(user.department -eq ""Sales"") or (user.employeeId -eq ""12345"")" -MembershipRuleProcessingState "On"
```

The `-or (user.employeeId -eq "...")` pattern above is the standard way to add a single one-off member without abandoning the broader rule.

**Rollback:** revert `-MembershipRule` to its prior value; membership recalculates automatically.

</details>

<details id="fix-6"><summary>Fix 6 — Global Admin blocked by a Restricted Management AU</summary>

**Symptom:** A Global Administrator (or Privileged Role Administrator) tries to modify a user/group/device and sees: *"This user is a member of a restricted management administrative unit. Management rights are limited to administrators scoped on that administrative unit."*

This is the feature working exactly as designed — RMAU membership blocks tenant-wide roles, including the two highest-privilege roles in the tenant, from touching Entra properties of the object. This topic is covered in full depth, including the self-assignment procedure, the audit-trail implications, and the specific dead-end case where the protected object is itself a Global Administrator account, in **`RestrictedManagementAU-B.md` Fix 1 and Fix 2** — go there directly rather than treating this as a fault on this AU-scoping topic.

**Rollback:** N/A here — see the linked fix.

</details>

<details id="fix-7"><summary>Fix 7 — Service principal/guest AU-scoped role doesn't work</summary>

**Symptom:** An automation account (service principal) or a guest user has the correct role assigned with `directoryScopeId` pointed at the right AU, verified in Graph — every actual API call still comes back unauthorized.

Service principals and guest users don't get default directory-read permissions the way member users do, so an AU-scoped role assignment alone leaves them unable to even read the objects they're supposed to manage:

```powershell
Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory" -NoWelcome
$readerRole = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq 'Directory Readers'"
New-MgRoleManagementDirectoryRoleAssignment -BodyParameter @{
    "@odata.type"     = "#microsoft.graph.unifiedRoleAssignment"
    roleDefinitionId  = $readerRole.Id
    principalId       = "<servicePrincipalOrGuestObjectId>"
    directoryScopeId  = "/"
}
```

Note this supplementary role is necessarily **tenant-scoped** (`/`) — there is currently no way to scope baseline directory-read permission itself to just one AU, so the service principal/guest will be able to *read* tenant-wide even though it can only *manage* within its AU scope. Document this in the ticket if the requester assumed read access would also be AU-limited.

**Rollback:** `Remove-MgRoleManagementDirectoryRoleAssignment` on the Directory Readers assignment if the automation is decommissioned.

</details>

---
## Escalation Evidence

```
Administrative Unit — Evidence Pack
====================================
Administrative unit name:
Administrative unit Object ID:
Restricted management (Y/N):
Membership type:              [Assigned / Dynamic]
Membership rule (if dynamic):

Actor (the admin who is blocked or acting):
  UPN / Object ID:
  Role held:
  DirectoryScopeId of that role assignment:

Target object (user/group/device):
  UPN or display name / Object ID:
  Direct member of the AU?        [YES / NO]
  Member via a GROUP in the AU?   [YES / NO — name group if so]
  Holds any directory role itself? [YES / NO — list roles if so]

Error / symptom observed:
  Exact error text or portal message:
  Timestamp:

Role assignments scoped to this AU (from Triage step 3):

Steps already tried:
```

---
## 🎓 Learning Pointers

- **Adding a group to an administrative unit brings the group under management — not the group's members.** This single distinction explains most "the AU admin can't do X to this specific person" tickets. If individual user management is the goal, the users must be direct AU members. [MS Docs: Administrative units in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units)

- **The anti-escalation carve-out applies to the target, not the actor.** An AU-scoped Helpdesk/Password/User Administrator is blocked from resetting the password or touching the auth methods of ANY user who holds ANY directory role — even a low-privilege, completely unrelated one, and even if that role is itself AU-scoped somewhere else. This is deliberate, not a licensing or sync issue. [MS Docs: Assign Microsoft Entra roles — administrative unit scope](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/manage-roles-portal)

- **Restricted management administrative units block Global Administrator and Privileged Role Administrator by design** — the whole point is that even your highest-privilege roles can't casually touch protected objects (executive accounts, break-glass credentials, sensitive security groups). Getting in requires an explicit, audited self-assignment, which is a feature, not friction to route around. [MS Docs: Restricted management administrative units](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/admin-units-restricted-management)

- **Service principals and guest users need a separate tenant-wide read role on top of any AU-scoped role assignment.** They don't inherit the default directory-read permissions member users get automatically, so "I assigned the role and it still doesn't work" for an automation account is almost always this gap, not a propagation delay. [MS Docs: Assign Microsoft Entra roles — service principals and guest users](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/manage-roles-portal)

- **Dynamic-membership AUs reject manual membership edits entirely, for every role including Privileged Role Administrator.** Once `MembershipType` is `Dynamic`, the rule is the only membership control surface — the fix for "I need to add just this one person" is an `-or` clause in the rule, not a manual add attempt. [MS Docs: Administrative units troubleshooting and FAQ](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/admin-units-faq-troubleshoot)

- **The restricted-management setting is permanent at creation — there's no toggle to flip later.** If an existing regular AU needs to become restricted-management, the fix is creating a new AU with the flag set and migrating members, not editing the original. Plan for this before creating any AU intended for genuinely sensitive objects.
