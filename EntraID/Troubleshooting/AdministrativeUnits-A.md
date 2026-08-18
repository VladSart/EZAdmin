# Administrative Units — Reference Runbook (Mode A: Deep Dive)
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
- Regular administrative units (AUs): containers scoping directory-role permissions to a subset of users, groups, or devices
- Restricted management administrative units (RMAUs): the hardened variant that blocks even tenant-wide roles (Global Administrator, Privileged Role Administrator) from touching member objects
- Static (manually assigned) and dynamic (rule-based) AU membership
- Assigning Microsoft Entra roles with administrative unit scope (the modern `unifiedRoleAssignment` + `directoryScopeId` model)
- Licensing, constraints, and the currently-supported-scenarios matrix across Microsoft Entra admin center / Microsoft 365 admin center / Graph-PowerShell

**Not in scope:**
- **Full Restricted Management Administrative Unit (RMAU) procedure and architecture** — the blocked/allowed operations matrix, the complete who-can-modify/who-can-manage role tables, the Global-Administrator-as-RMAU-member dead end, RMAU-specific limits (100/tenant, 30-minute deletion propagation), and the fleet-wide RMAU audit script are already covered in full depth by `RestrictedManagementAU-A.md`/`-B.md`. This document treats RMAU only to the extent needed to show how it fits into the broader AU role-scoping model — for any RMAU-specific ticket, go straight to those files instead of this one.
- Intune RBAC and scope tags — a wholly separate delegation system; AU-scoped Entra roles do **not** grant Intune management access even when devices are AU members (see How It Works)
- Privileged Identity Management (PIM) eligible/time-bound assignments — AU scope composes with PIM (a P2 feature) for the *timing* of an assignment, but PIM itself is out of scope here
- Microsoft Entra ID Governance features (Entitlement Management, Access Reviews, Lifecycle Workflows) — not available for AUs at all currently
- Exchange/SharePoint/Teams-native delegated administration — AU scope only controls the Entra-side management surface for these workloads (see the SharePoint Administrator/Teams Administrator scope notes below); their native admin centers have their own, separate delegation models

**Assumed knowledge:**
- Comfortable with Microsoft Graph PowerShell (`Microsoft.Graph.Identity.DirectoryManagement`, `Microsoft.Graph.Identity.Governance`)
- Understands Entra RBAC basics: role definitions, role assignments, and the concept of assignment scope
- Familiar with dynamic group membership rule syntax (AU dynamic rules use the identical rule language)

---

## How It Works

<details><summary>Full architecture</summary>

### What an administrative unit actually is

An administrative unit is a Microsoft Entra container object that can hold **users, groups, or devices** (never a mix of all three purposes at once for dynamic rules — see below) and exists for exactly one purpose: to let a directory role's permissions apply to only the members of that container instead of the entire tenant. Assign the **Helpdesk Administrator** role at tenant scope and it can reset any non-admin's password anywhere. Assign the same role scoped to an AU containing only the "Seattle Branch" AU's members, and it can only reset passwords for people in that AU.

```
Tenant
 │
 ├── AU: "School of Business"          ← flat container, no nesting possible
 │      members: [User A, User B, Group X (as an object, not its members)]
 │      role assignment: Helpdesk Administrator @ this AU's scope → IT Team 1
 │
 ├── AU: "School of Engineering"
 │      members: [User C, User D]
 │      role assignment: User Administrator @ this AU's scope → IT Team 2
 │
 └── (any user NOT a member of any AU is only reachable by tenant-scoped roles)
```

A user can belong to multiple AUs simultaneously (e.g., "Seattle" and "Marketing"), and is then manageable by every admin scoped to either one. **AUs cannot be nested** — there is no parent/child AU hierarchy, full stop.

### The single most-missed rule: groups bring themselves, not their members

Adding a group to an AU brings the **group object** into the AU's management scope — an AU-scoped Groups/User Administrator can rename it, delete it, or change its membership list. It does **not** bring the group's *members* into the AU. To manage the individual users, they must be separately, directly added as AU members.

| Permission (AU-scoped User Administrator, group is an AU member) | Can do |
|---|---|
| Manage the group's name | ✅ |
| Manage the group's membership | ✅ |
| Manage user properties of individual group members | ❌ |
| Manage authentication methods of individual group members | ❌ |
| Reset passwords of individual group members | ❌ |

This is arguably the most consequential design decision in the whole feature, because it's the opposite of how most admins intuitively expect group-based scoping to behave.

### Static vs. dynamic membership

**Static (assigned) membership** — objects are added/removed one at a time via `New-MgDirectoryAdministrativeUnitMemberByRef` / `Remove-MgDirectoryAdministrativeUnitMemberByRef` or the portal. Supports users, groups, and devices simultaneously in the same AU.

**Dynamic membership** — a rule (identical syntax to dynamic group membership rules) automatically adds/removes members as their attributes change. Constraints that trip people up:
- A dynamic AU rule can target **users OR devices, but never both in the same AU** — unlike static AUs, which happily hold all three object types together.
- Groups cannot be added to an AU dynamically at all — dynamic rules for AUs only ever evaluate users or devices.
- Every AU member matched by a dynamic rule requires a **Microsoft Entra ID P1 license**, independent of whatever license the AU *administrator* needs.
- Rule length is capped at **3,072 characters**.
- The combined total of dynamic groups **and** dynamic AUs in a tenant cannot exceed **15,000**.
- Once an AU has `MembershipType: Dynamic`, manual add/remove is rejected outright — even for a Privileged Role Administrator. The only way to change membership is editing the rule (an `-or (user.employeeId -eq "...")` clause is the standard escape hatch for a genuine one-off).
- Initial population and any subsequent rule change take a few minutes to fully process — don't treat an empty membership list moments after saving as a failure.

### Assigning roles with administrative unit scope

The modern mechanism is a standard `unifiedRoleAssignment` object whose `directoryScopeId` is set to `/administrativeUnits/<id>` instead of the tenant-wide `/`:

```powershell
New-MgRoleManagementDirectoryRoleAssignment -BodyParameter @{
    "@odata.type"    = "#microsoft.graph.unifiedRoleAssignment"
    roleDefinitionId = "<roleDefinitionId>"
    principalId      = "<userOrGroupOrSpId>"
    directoryScopeId = "/administrativeUnits/<auId>"
}
```

Only **Privileged Role Administrator** can create AUs and assign roles at AU scope in the first place. Not every built-in role can be scoped this way — the eligible list is deliberately narrow (see table below), and **Global Administrator and Privileged Role Administrator themselves cannot be scoped to an AU** — they only ever operate tenant-wide, which is precisely why RMAUs need a separate mechanism to keep them out.

| Role | AU-scoped behavior |
|---|---|
| Authentication Administrator | View/set/reset auth methods for non-admin users in the AU only |
| Attribute Assignment Administrator / Reader | Read/update custom security attribute assignments within the AU only |
| Cloud Device Administrator | Limited device management within the AU |
| Groups Administrator | All aspects of groups within the AU only |
| Helpdesk Administrator | Password reset for non-admins within the AU only |
| License Administrator | Assign/remove/update licenses within the AU only |
| Password Administrator | Password reset for non-admins within the AU only |
| Printer Administrator | Manage printers/connectors (Universal Print's own delegated model layers on top of this) |
| Privileged Authentication Administrator | Auth methods for ANY user (admin or not) — notably NOT restricted to non-admins the way Helpdesk/Password Administrator are |
| SharePoint Administrator | Manages Microsoft 365 groups in the AU only; can update associated SharePoint site name/URL/external-sharing via the M365 admin center — cannot use the SharePoint admin center or SharePoint APIs at AU scope |
| Teams Administrator | Manages Microsoft 365 groups in the AU only; can manage team members via the M365 admin center — cannot use the Teams admin center at AU scope |
| Teams Devices Administrator | Teams-certified device management tasks |
| User Administrator | All aspects of users and groups within the AU only, including password resets for limited admins — cannot manage profile photographs |
| Custom role | Any custom role whose permissions include at least one user/group/device-relevant permission |

**Non-admin-only carve-out:** for AU-scoped Helpdesk Administrator, Password Administrator, and User Administrator specifically, the following actions are blocked against **any** target who holds **any** directory role — admin or otherwise, related to the AU or not:
- Read/modify user authentication methods
- Reset user passwords
- Modify sensitive properties (phone numbers, alternate email addresses, OAuth secret keys)
- Delete or restore the user account

This exists purely to prevent privilege escalation via a narrowly-scoped role — without it, a Helpdesk Administrator scoped to one small AU could reset the password of a Global Administrator who happened to also be a member of that AU.

**Service principals and guest users** don't receive default directory-read permissions the way member users do. An AU-scoped role assignment to a service principal or guest grants *management* rights within the AU, but without a supplementary **tenant-wide** Directory Readers (or broader) assignment, they can't even read the objects well enough to act on them. There's currently no way to scope baseline read access itself to just one AU — the supplementary role is necessarily tenant-wide.

### Restricted management administrative units (RMAU) — how it relates to everything above

An RMAU is the same container object with one additional, **immutable-at-creation** property: `isMemberManagementRestricted = true`. Where a regular AU only *adds* a delegated management path without removing anyone else's, an RMAU *subtracts* — it actively blocks every tenant-scoped role, including Global Administrator and Privileged Role Administrator, from directly modifying member objects' Entra properties. The only way in is the exact same mechanism described above (a `unifiedRoleAssignment` with `directoryScopeId` pointed at the RMAU) — RMAU doesn't introduce a new assignment model, it just narrows who's allowed to hold one and removes the tenant-wide bypass everyone else assumes still applies.

Global Administrator and Privileged Role Administrator retain control of the RMAU *container* (create/delete it, add/remove members, assign/remove its scoped roles, including to themselves — an explicitly audited action) even though they lose direct access to its *members*. Eligible member types are narrower than a regular AU too: users, devices, and security groups only — no Microsoft 365, mail-enabled security, or distribution groups.

For the complete blocked/allowed operations matrix, the full who-can-modify table, the role-assignable-group trap, the Governance-feature exclusion, and the Global-Administrator-as-RMAU-member dead end (plus a dedicated audit script), see `RestrictedManagementAU-A.md` — this document exists specifically to cover that ground in depth and isn't reproduced here.

### Currently supported scenarios (the fine print that determines what actually works)

| Capability | Graph/PowerShell | Entra admin center | Microsoft 365 admin center |
|---|---|---|---|
| Create/delete AUs, add/remove members, assign AU-scoped roles | ✅ | ✅ | ✅ |
| Dynamic membership rules for users/devices | ✅ | ✅ | ❌ |
| Dynamic membership rules for groups | ❌ | ❌ | ❌ (not supported anywhere) |
| AU-scoped user MFA/auth-method management | ✅ | ✅ | ❌ |
| AU-scoped group licensing management | ✅ | ✅ | ❌ |
| Enable/disable/delete AU-scoped devices, read BitLocker recovery keys | ✅ | ✅ | ❌ |
| **Manage AU-scoped devices in Intune** | **❌ — explicitly not supported** | **❌** | **❌** |

That last row is a frequent point of confusion precisely because it looks similar to the RMAU table's "Apply Intune policies to a device" row — those are different claims. RMAU membership doesn't *block* Intune from doing its normal job on a device (Intune's own RBAC still governs that). But there is no mechanism, in either a regular AU or an RMAU, by which an **AU-scoped Entra role** grants someone Intune management rights over that device. Intune delegation is Intune's own separate scope-tag/RBAC system; AU scope and Intune scope simply don't talk to each other.

AU-scoped admins get a real but intentionally thin Microsoft 365 admin center experience — basic user property/password/license management only, with users outside their AU filtered from view there. Critically, **AU scope only limits management permissions, not default read visibility** — an AU-scoped admin can still browse and see users/groups outside their AU via the Entra admin center, PowerShell, or Graph directly; they just can't modify them. Only the Microsoft 365 admin center actively filters the view.

</details>

---

## Dependency Stack

```
AU-scoped admin action succeeds
        │
        ▼
Actor's role assignment resolves with directoryScopeId = "/administrativeUnits/<id>"
        (NOT "/" — a tenant-scoped assignment of the identical role is a separate grant)
        │
        ├── Human user principal — works as soon as assigned
        │
        └── Service principal / guest principal — ALSO requires a supplementary
                TENANT-WIDE (directoryScopeId "/") Directory Readers assignment,
                since neither gets default directory-read access
        │
        ▼
Target object is a DIRECT member of the administrative unit
        (a group being an AU member brings only the GROUP under management,
         never cascades to the group's own membership)
        │
        ├── Static membership — added individually via
        │       New-MgDirectoryAdministrativeUnitMemberByRef
        │
        └── Dynamic membership — single object type only (user OR device),
                every matched member P1-licensed, rule < 3,072 chars,
                tenant-wide dynamic-group+AU count < 15,000,
                manual add/remove permanently disabled once dynamic
        │
        ▼
Assigned role is on the AU-scope-eligible list (or a qualifying custom role)
        (Global Administrator / Privileged Role Administrator CANNOT be
         AU-scoped at all — they only ever act tenant-wide)
        │
        ▼
Target is NOT protected by the anti-escalation carve-out
        (target holds ZERO directory roles of any kind, anywhere —
         required only for Helpdesk/Password/User Administrator actions
         against passwords, auth methods, sensitive properties, delete/restore)
        │
        ▼
[IF the AU is Restricted Management:] the actor's role assignment is scoped
to THIS SPECIFIC restricted management AU — a tenant-wide Global Administrator
or Privileged Role Administrator assignment does NOT satisfy this layer,
no matter how privileged, unless they explicitly self-assigned an AU-scoped
role here first (an audited event)
        │
        ▼
Action succeeds
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| AU-scoped admin can manage a group's membership but not the individual members | Group is an AU member; its members were never separately added | `Get-MgDirectoryAdministrativeUnitMember` — is the user's Id present directly? |
| AU-scoped Password/Helpdesk/User Administrator can't reset one specific user's password, works for everyone else | Target holds some directory role, even an unrelated one | `Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<target>'"` returns anything at all |
| Global Administrator gets "member of a restricted management administrative unit" and is blocked | RMAU protection — expected, not a fault | `$au.IsMemberManagementRestricted -eq $true` — see `RestrictedManagementAU-B.md` Fix 1 |
| Automation account / guest has the correct AU-scoped role but every Graph call 403s | Missing supplementary tenant-wide Directory Readers assignment | `Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<sp>' and directoryScopeId eq '/'"` returns nothing |
| Dynamic AU rule save fails: "Failed to update administrative unit properties" | Wrong property value type in the rule, OR a matched member lacks P1 | Validate rule syntax against the dynamic-membership property reference; spot-check licensing on likely matches |
| Can't manually add/remove a member even as Privileged Role Administrator | AU has `MembershipType: Dynamic` — manual edits are permanently disabled | `$au.MembershipType` |
| Member just added/removed, portal still shows old state | Propagation delay (up to several minutes) | Query Graph directly instead of trusting the portal immediately |
| Trying to add a role-assignable group's individual owners' management rights back inside an RMAU | Not possible — only GA/PRA could normally manage role-assignable group membership, and neither can be AU-scoped | See `RestrictedManagementAU-A.md` Limits section; the fix is removing the group from the RMAU, not finding a workaround role |
| PIM eligible assignment or an access review targeting an AU member silently does nothing | Object is inside a Restricted Management AU — Governance features are excluded from RMAU members entirely | Check `IsMemberManagementRestricted` — see `RestrictedManagementAU-B.md` Fix 6; this is a hard product exclusion, not a licensing gap |
| "We assigned an AU-scoped role but the person also seems to have full tenant access" | A SEPARATE tenant-scoped assignment of the same (or a more powerful) role exists alongside the AU-scoped one | List every assignment for the principal, not just the one you expect — scoped and tenant-wide assignments coexist independently |
| Someone expects an AU-scoped role to grant Intune device-management rights | Not supported at all, regular AU or RMAU | Confirmed by the currently-supported-scenarios table — Intune delegation is a wholly separate RBAC system |
| New rule for dynamic AU membership shows zero members minutes after saving | Either genuinely correct (nothing matches) or still processing | Re-check after ~10 minutes; independently verify the rule logic against a known-should-match test object |

---

## Validation Steps

### Step 1 — Inventory the AU and its type

```powershell
Connect-MgGraph -Scopes "AdministrativeUnit.Read.All" -NoWelcome
$au = Get-MgDirectoryAdministrativeUnit -Filter "displayName eq '<AUName>'"
$au | Select-Object Id, DisplayName, IsMemberManagementRestricted, MembershipType, MembershipRule, MembershipRuleProcessingState
```
**Good:** clear result, `MembershipType` and `IsMemberManagementRestricted` both known before doing anything else. **Bad:** ambiguous match (duplicate display names are allowed — always disambiguate by `Id` once found).

---

### Step 2 — Confirm direct membership vs. group-mediated membership

```powershell
$members = Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $au.Id -All
$members | Select-Object Id, @{N="Type";E={$_.AdditionalProperties['@odata.type']}}
```
**Good:** the specific user/device Object ID you're troubleshooting appears directly in this list. **Bad:** only a group appears, and the ticket concerns an individual inside that group — this is Fix 1 territory (Mode B), not a bug.

---

### Step 3 — Confirm every role assignment scoped to this AU

```powershell
Get-MgRoleManagementDirectoryRoleAssignment -Filter "directoryScopeId eq '/administrativeUnits/$($au.Id)'" -ExpandProperty RoleDefinition |
    Select-Object PrincipalId, @{N="Role";E={$_.RoleDefinition.DisplayName}}
```
**Good:** at least one assignment exists for whoever the ticket says should have access, with the expected role. **Bad:** empty result — for an RMAU specifically, an empty result means **literally no one** can currently manage member objects' Entra properties, including Global Administrator (full remediation: `RestrictedManagementAU-B.md` Fix 2).

---

### Step 4 — Confirm the actor's assignment scope precisely

```powershell
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<actorObjectId>'" -ExpandProperty RoleDefinition |
    Select-Object @{N="Role";E={$_.RoleDefinition.DisplayName}}, DirectoryScopeId
```
**Good:** `DirectoryScopeId` exactly matches `/administrativeUnits/<au.Id>` for the AU in question. **Bad:** the actor holds the right role name but scoped to `/` (tenant-wide — different situation entirely) or to a *different* AU's Id (easy to mix up in a multi-AU tenant).

---

### Step 5 — Check the target for the anti-escalation carve-out

```powershell
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<targetUserObjectId>'" -ExpandProperty RoleDefinition |
    Select-Object @{N="Role";E={$_.RoleDefinition.DisplayName}}, DirectoryScopeId
```
**Good:** empty result — target holds no directory role anywhere, so Helpdesk/Password/User Administrator actions against passwords/auth methods/sensitive properties are unrestricted. **Bad:** any result at all, which blocks those specific actions regardless of how minor or unrelated the held role is.

---

### Step 6 — For dynamic AUs, validate rule health and licensing

```powershell
$au.MembershipRule
$au.MembershipRuleProcessingState   # should be "On"
Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $au.Id -All | ForEach-Object {
    try { Get-MgUserLicenseDetail -UserId $_.Id -ErrorAction Stop | Select-Object SkuPartNumber }
    catch { Write-Warning "No P1-eligible license found for $($_.Id)" }
}
```
**Good:** `MembershipRuleProcessingState: On`, every matched member licensed. **Bad:** `Paused` (silently frozen membership — a common "why hasn't this updated in weeks" root cause) or unlicensed matches (which block the rule from saving in the first place, per Fix 4).

---

### Step 7 — For service principal/guest role holders, confirm the supplementary read role

```powershell
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<spOrGuestObjectId>' and directoryScopeId eq '/'" -ExpandProperty RoleDefinition |
    Select-Object @{N="Role";E={$_.RoleDefinition.DisplayName}}
```
**Good:** `Directory Readers` (or broader) present at tenant scope. **Bad:** nothing here — the AU-scoped role assignment alone is functionally inert for this principal type.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Establish exactly which AU and which scope is in play

1. Resolve the AU by Id, not display name, once found (duplicates are legal). Confirm `IsMemberManagementRestricted` before anything else — it changes every subsequent assumption.
2. In multi-AU tenants, explicitly confirm the actor's assignment references the *specific* AU Id the ticket concerns, not a same-named or similarly-scoped one elsewhere.

### Phase 2 — Membership-layer issues

1. Run Validation Step 2. A group-in-AU-but-not-its-members mismatch is the highest-frequency root cause in this entire topic — check it before anything else involving an individual user.
2. For dynamic AUs, run Validation Step 6 before assuming a static-membership fix path applies.

### Phase 3 — Role-assignment-layer issues

1. Run Validation Steps 3 and 4. Distinguish cleanly between "no assignment exists," "assignment exists but wrong scope (tenant vs. this-AU vs. a-different-AU)," and "assignment exists and is correctly scoped, but the role itself isn't AU-scope-eligible" (shouldn't be possible via the portal, but a scripted `New-MgRoleManagementDirectoryRoleAssignment` call with a bad `roleDefinitionId` can technically attempt it and fail).
2. Confirm for service principal/guest actors specifically whether the supplementary tenant-wide read role (Validation Step 7) is present — this is the single most common "assignment looks right, nothing works" pattern for non-human principals.

### Phase 4 — Anti-escalation carve-out issues

1. Run Validation Step 5 whenever the failing action is specifically password reset, auth-method read/modify, sensitive-property edit, or delete/restore — and the AU-scoped admin's *other* actions on the same AU work fine.
2. Do not attempt to "work around" this by elevating the AU-scoped admin's own role — resolve either by removing the target's stale role (if appropriate) or escalating to a correctly-scoped tenant-wide admin for that specific action.

### Phase 5 — Restricted Management AU layer

1. If `IsMemberManagementRestricted` is true and the actor is a tenant-scoped Global Administrator or Privileged Role Administrator, this is expected behavior — do not troubleshoot further as a fault. Hand off to `RestrictedManagementAU-B.md` Fix 1/Fix 2 for the full explanation and the self-assignment procedure.
2. If a role-assignable group inside an RMAU needs membership changes, recognize this as the specific trap detailed in `RestrictedManagementAU-A.md`'s Limits section — the fix is removing the group from the RMAU (a GA/PRA container-management action), not finding an AU-scoped role that can manage role-assignable groups (none exists).

### Phase 6 — Governance/prevention layer

1. Regardless of what caused today's ticket, check whether the AU (RMAU or not) currently has zero role assignments scoped to it — a delegation container nobody can actually use defeats its own purpose and should be flagged even if unrelated to the immediate issue.
2. For RMAUs specifically, confirm no one has a *standing* self-assigned AU-scoped role left over from a prior one-off task — the audit-log event for self-assignment is a good place to spot this pattern (a Global Admin repeatedly self-assigning to the same RMAU is worth a conversation about a permanent, correctly-scoped assignment instead).

---

## Remediation Playbooks

<details><summary>Playbook 1 — From-scratch AU with static membership and a scoped role</summary>

```powershell
Connect-MgGraph -Scopes "AdministrativeUnit.ReadWrite.All","RoleManagement.ReadWrite.Directory" -NoWelcome

# 1. Create the AU
$au = New-MgDirectoryAdministrativeUnit -BodyParameter @{
    displayName = "School of Business"
    description = "Delegated IT scope for the School of Business"
}

# 2. Add members (one call per object — no bulk-add endpoint)
$usersToAdd = Get-MgUser -Filter "department eq 'School of Business'" -All
foreach ($u in $usersToAdd) {
    New-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId $au.Id -BodyParameter @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($u.Id)"
    }
}

# 3. Assign a role scoped to this AU
$roleDef = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq 'Helpdesk Administrator'"
$admin   = Get-MgUser -UserId "<itadmin@domain.com>"
New-MgRoleManagementDirectoryRoleAssignment -BodyParameter @{
    "@odata.type"    = "#microsoft.graph.unifiedRoleAssignment"
    roleDefinitionId = $roleDef.Id
    principalId      = $admin.Id
    directoryScopeId = "/administrativeUnits/$($au.Id)"
}
```

**Rollback:** `Remove-MgRoleManagementDirectoryRoleAssignment` to pull the assignment; `Remove-MgDirectoryAdministrativeUnit` to delete the AU entirely (members simply lose the delegation, they aren't affected otherwise).

</details>

<details><summary>Playbook 2 — Grant a service principal or guest AU-scoped access correctly (role + supplementary read)</summary>

The two-step pattern that Fix 7 (Mode B) and Validation Step 7 describe — an AU-scoped role assignment alone is functionally inert for non-member principals:

```powershell
Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory","Application.Read.All" -NoWelcome

$sp = Get-MgServicePrincipal -Filter "displayName eq '<AutomationAppName>'"
$au = Get-MgDirectoryAdministrativeUnit -Filter "displayName eq '<AUName>'"

# 1. The AU-scoped management role itself
$mgmtRole = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq 'User Administrator'"
New-MgRoleManagementDirectoryRoleAssignment -BodyParameter @{
    "@odata.type"    = "#microsoft.graph.unifiedRoleAssignment"
    roleDefinitionId = $mgmtRole.Id
    principalId      = $sp.Id
    directoryScopeId = "/administrativeUnits/$($au.Id)"
}

# 2. The supplementary TENANT-WIDE read role — without this, step 1 alone will not work
$readRole = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq 'Directory Readers'"
New-MgRoleManagementDirectoryRoleAssignment -BodyParameter @{
    "@odata.type"    = "#microsoft.graph.unifiedRoleAssignment"
    roleDefinitionId = $readRole.Id
    principalId      = $sp.Id
    directoryScopeId = "/"
}
```

Run `Get-AdministrativeUnitAudit.ps1` afterward (or on a schedule) to catch any automation account that only ever received step 1 — it flags `MISSING_SUPPLEMENTARY_READ_ROLE` for exactly this gap tenant-wide.

**Rollback:** `Remove-MgRoleManagementDirectoryRoleAssignment` on either assignment independently — removing only the read role leaves the AU-scoped role in place but inert again, which is a safe, reversible way to pause an automation account without deleting its configuration.

</details>

<details><summary>Playbook 3 — Build a dynamic-membership AU with a P1-licensing pre-check</summary>

```powershell
Connect-MgGraph -Scopes "AdministrativeUnit.ReadWrite.All","User.Read.All" -NoWelcome

# 1. Pre-check: confirm the target population is P1-licensed BEFORE creating the rule
#    (an unlicensed match blocks the save entirely — cheaper to catch this first)
$candidates = Get-MgUser -Filter "department eq 'Sales'" -All
$p1Sku = "ENTERPRISEPREMIUM"   # adjust to the tenant's actual P1-bearing SKU part number
$unlicensed = $candidates | Where-Object {
    -not (Get-MgUserLicenseDetail -UserId $_.Id | Where-Object { $_.SkuPartNumber -eq $p1Sku })
}
if ($unlicensed) {
    Write-Warning "$($unlicensed.Count) candidate(s) lack P1 — rule save will fail until resolved."
    $unlicensed | Select-Object DisplayName, UserPrincipalName
}

# 2. Create the AU with a dynamic rule (single object type — users OR devices)
$au = New-MgDirectoryAdministrativeUnit -BodyParameter @{
    displayName                   = "Sales Region — Dynamic"
    membershipType                = "Dynamic"
    membershipRule                = '(user.department -eq "Sales")'
    membershipRuleProcessingState = "On"
}
```

**Rollback:** `Update-MgDirectoryAdministrativeUnit -MembershipRuleProcessingState "Paused"` freezes membership without deleting the AU; `Remove-MgDirectoryAdministrativeUnit` removes it entirely.

</details>

<details><summary>Playbook 4 — Remediate tenant-wide zero-scoped-role-assignment gaps from the audit script</summary>

`Get-AdministrativeUnitAudit.ps1` flags every AU (regular or restricted) that currently has no role assigned at its scope — for a regular AU this is a delegation container nobody can use; for an RMAU it means literally no one, including Global Administrator, can currently modify member Entra properties (for that specific RMAU case, the actual self-assignment procedure and its audit-trail implications are Fix 2 in `RestrictedManagementAU-B.md` — don't duplicate that here, just route to it).

```powershell
.\Get-AdministrativeUnitAudit.ps1 -OutputPath C:\Reports\AU
$findings = Import-Csv "C:\Reports\AU\Findings.csv" | Where-Object { $_.Flag -eq "NO_SCOPED_ROLE_ASSIGNMENTS" }

foreach ($gap in $findings) {
    Write-Host "$($gap.AUName) ($($gap.AUId)) — RestrictedMgmt risk: $($gap.RiskLevel)"
    # For each: decide the intended admin/role, then assign per Playbook 1 (regular AU)
    # or route to RestrictedManagementAU-B.md Fix 2 (RMAU self-assignment) as appropriate
}
```

**Rollback:** N/A — this playbook only identifies gaps; the actual role assignment made in response follows the normal rollback pattern of `Remove-MgRoleManagementDirectoryRoleAssignment` if made in error.

</details>

---

## Evidence Pack

```powershell
Connect-MgGraph -Scopes "AdministrativeUnit.Read.All","RoleManagement.Read.Directory" -NoWelcome
$outputDir = "C:\Temp\AU-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$au = Get-MgDirectoryAdministrativeUnit -Filter "displayName eq '<AUName>'"

# 1. AU properties
$au | Select-Object Id, DisplayName, IsMemberManagementRestricted, MembershipType, MembershipRule, MembershipRuleProcessingState |
    ConvertTo-Json | Out-File "$outputDir\01-AdministrativeUnit.json"

# 2. Members
Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $au.Id -All |
    Select-Object Id, @{N="Type";E={$_.AdditionalProperties['@odata.type']}} |
    Export-Csv "$outputDir\02-Members.csv" -NoTypeInformation

# 3. Role assignments scoped to this AU
Get-MgRoleManagementDirectoryRoleAssignment -Filter "directoryScopeId eq '/administrativeUnits/$($au.Id)'" -ExpandProperty RoleDefinition |
    Select-Object PrincipalId, @{N="Role";E={$_.RoleDefinition.DisplayName}} |
    Export-Csv "$outputDir\03-ScopedRoleAssignments.csv" -NoTypeInformation

# 4. For each member, any directory role held anywhere (anti-escalation carve-out check)
$memberRoleReport = foreach ($m in (Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $au.Id -All)) {
    $roles = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($m.Id)'" -ExpandProperty RoleDefinition
    [PSCustomObject]@{
        MemberId  = $m.Id
        HasAnyRole = [bool]$roles
        Roles     = ($roles.RoleDefinition.DisplayName -join "; ")
    }
}
$memberRoleReport | Export-Csv "$outputDir\04-MemberRoleExposure.csv" -NoTypeInformation

# 5. Metadata
[PSCustomObject]@{ CollectedAt = (Get-Date).ToString("u"); TenantId = (Get-MgContext).TenantId } |
    ConvertTo-Json | Out-File "$outputDir\00-CollectionMetadata.json"

Write-Host "Evidence collected to: $outputDir" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| Find an AU by name | `Get-MgDirectoryAdministrativeUnit -Filter "displayName eq '<name>'"` |
| Create an AU | `New-MgDirectoryAdministrativeUnit -BodyParameter @{...}` |
| Create a Restricted Management AU | `New-MgDirectoryAdministrativeUnit -BodyParameter @{ isMemberManagementRestricted = $true; ... }` |
| List AU members | `Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId <id> -All` |
| Add a static member | `New-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId <id> -BodyParameter @{"@odata.id"=...}` |
| Remove a static member | `Remove-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId <id> -DirectoryObjectId <objId>` |
| Set/update a dynamic membership rule | `Update-MgDirectoryAdministrativeUnit -AdministrativeUnitId <id> -MembershipRule '<rule>' -MembershipRuleProcessingState "On"` |
| Pause dynamic membership processing | `Update-MgDirectoryAdministrativeUnit -AdministrativeUnitId <id> -MembershipRuleProcessingState "Paused"` |
| Find a role definition by name | `Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '<role>'"` |
| Assign a role scoped to an AU | `New-MgRoleManagementDirectoryRoleAssignment -BodyParameter @{ directoryScopeId = "/administrativeUnits/<id>"; ... }` |
| List role assignments scoped to a specific AU | `Get-MgRoleManagementDirectoryRoleAssignment -Filter "directoryScopeId eq '/administrativeUnits/<id>'"` |
| List every role assignment for a principal (any scope) | `Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<id>'" -ExpandProperty RoleDefinition` |
| Remove a scoped role assignment | `Remove-MgRoleManagementDirectoryRoleAssignment -UnifiedRoleAssignmentId <assignmentId>` |
| Grant a service principal/guest the supplementary read role | `New-MgRoleManagementDirectoryRoleAssignment -BodyParameter @{ directoryScopeId = "/"; roleDefinitionId = <DirectoryReadersId>; ... }` |
| Delete an AU (also removes RMAU protections, ~30 min) | `Remove-MgDirectoryAdministrativeUnit -AdministrativeUnitId <id>` |

---

## 🎓 Learning Pointers

- **Adding a group to an AU manages the group, never its members — this is the design's single biggest source of confusion.** Every "the AU admin can't do X to this specific person even though the group they're in is right there in the AU" ticket traces back to this one rule. Build the habit of checking direct membership before assuming a permissions bug. [MS Docs: Administrative units in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units)

- **Restricted management AUs block Global Administrator and Privileged Role Administrator on purpose, and require an audited self-assignment to get back in.** This is the feature's entire value proposition — protecting executive accounts, break-glass credentials, and sensitive security groups from casual access by *any* standing tenant-wide role, not just from lower-privilege ones. Don't troubleshoot this as a bug; hand off to `RestrictedManagementAU-A.md`/`-B.md` for the full architecture and procedure rather than re-deriving it here. [MS Docs: Restricted management administrative units](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/admin-units-restricted-management)

- **The anti-escalation carve-out protects the target, not the actor, and applies to ANY role the target holds — not just ones related to the ticket.** An AU-scoped Helpdesk Administrator who can't reset one specific user's password almost always has an unrelated, low-privilege role sitting on that user's account somewhere in the tenant. Check broadly, not just for roles that look relevant. [MS Docs: Assign Microsoft Entra roles](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/manage-roles-portal)

- **Service principals and guest users need a separate, necessarily tenant-wide, Directory Readers-equivalent assignment on top of any AU-scoped role.** There's no way to scope baseline read access to just an AU today — plan automation/guest access around a two-assignment pattern from the start rather than debugging it after the fact. [MS Docs: Assign Microsoft Entra roles — service principals and guest users](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/manage-roles-portal)

- **AU-scoped Entra roles never grant Intune device-management access, in either a regular or restricted AU — this is a completely separate delegation system.** Anyone expecting an AU-scoped Cloud Device Administrator or similar role to unlock Intune policy management for AU-member devices needs Intune's own RBAC/scope-tag model instead; the two systems don't compose. [MS Docs: Administrative units — currently supported scenarios](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units#currently-supported-scenarios)

- **The restricted-management flag is permanent at creation with no toggle — plan the AU type before creating it, not after.** Converting an existing regular AU to restricted (or the reverse) always means creating a new AU and migrating members; there's no in-place upgrade path, which matters for any organization planning to tighten protection on an AU that's already in production use.
