# Entra ID Restricted Management Administrative Units (RMAU) — Reference Runbook (Mode A: Deep Dive)
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

Covers **Restricted Management Administrative Units (RMAU)** — an Administrative Unit created with `isMemberManagementRestricted = true`, which places direct member objects (Users, Devices, Security Groups) under a hard access-control regime: only administrators explicitly assigned a role scoped to that specific RMAU can modify the objects' Entra properties, delete them, reset passwords, or change group membership — and critically, this restriction applies even to **Global Administrator** and **Privileged Role Administrator**, the two roles that otherwise have unrestricted tenant-wide reach.

**Does not cover:**
- **Regular (non-restricted) Administrative Units** — a plain AU scopes *where* a delegated role applies (e.g., "Helpdesk Administrator, but only for the Sales department's users") without blocking any tenant-scoped administrator from also managing those same objects directly. RMAU is the special case; don't conflate the two when a ticket just says "administrative unit."
- **Privileged Identity Management (PIM), Entitlement Management, Lifecycle Workflows, or Access Reviews configuration** — see `PIM-A.md`, `AccessPackages-A.md`, `LifecycleWorkflows-A.md`, `AccessReviews-A.md` respectively for how those features work in general. This topic covers only the specific, hard incompatibility between those features and RMAU membership.
- **Conditional Access, PIM for Azure Resources, or any Azure RBAC concept** — RMAU is an Entra ID (directory-object) construct only; it has no relationship to Azure subscription/resource-group scoping (`PIMAzureResources-A.md`).
- **BitLocker recovery key access delegation mechanics in general** — only the specific point that RMAU can be used to restrict who can retrieve a protected device's BitLocker recovery key is covered; broader BitLocker administration is out of scope here.

**Assumes:** Global Administrator or Privileged Role Administrator access for RMAU creation and initial role scoping; Microsoft Entra ID P1 licensing (required per administrator managing an RMAU); Microsoft Graph PowerShell SDK connected for diagnostics and management.

---
## How It Works

<details><summary>Full architecture</summary>

### The problem RMAU solves

In a standard Entra ID tenant, a handful of roles have effectively unlimited reach over every object in the directory: Global Administrator, Privileged Role Administrator, and — for their specific object type — resource-scoped roles like Groups Administrator or User Administrator. This is fine for the overwhelming majority of objects, but creates a real gap for a small set of genuinely sensitive ones: a CEO's account (where a Helpdesk Administrator resetting the password, however well-intentioned or routine, is itself a risk an organization may want to control tightly), or a security group gating access to financial data in SharePoint (where a tenant-wide Groups Administrator being able to add themselves or anyone else is unacceptable regardless of how well governed that admin's role is otherwise).

Removing tenant-level role assignments entirely isn't a workable answer — those admins still need to do their jobs for every *other* object in the tenant. RMAU solves this by carving out a small, explicitly-designated set of objects and requiring a **separate, RMAU-scoped role assignment** to touch them — one that Global Administrator and Privileged Role Administrator do not automatically hold, and cannot be assigned to hold, but which they *can* grant to themselves or to a specific trusted admin as a distinct, auditable action.

### What counts as an RMAU member, and what doesn't

| Microsoft Entra object type | Regular AU | Restricted management AU |
|---|---|---|
| Users | Yes | Yes |
| Devices | Yes | Yes |
| Security groups | Yes | Yes |
| Microsoft 365 groups | Yes | **No** |
| Mail-enabled security groups | Yes | **No** |
| Distribution groups | Yes | **No** |

This is a real practical constraint: an organization wanting to protect a Microsoft 365 group's membership the way RMAU protects a security group's has no direct equivalent — the underlying object type simply isn't eligible.

Membership is **direct-only** and does **not cascade or nest**. If a security group is added to an RMAU, the group object itself — its properties, ownership, and (for role-assignable groups) its membership list — is protected. The individual users who happen to belong to that group are not separately protected unless each is *also* added directly to the RMAU (or a group they're a member of is added, which still only protects the group object, not transitively the users). This is a common point of confusion: RMAU is not a "protect everything downstream of this container" mechanism the way, say, an OU with inherited permissions works in on-prem AD.

### What operations are actually blocked, and what still works

Not every possible action against an RMAU member is blocked — only operations that modify the object's Entra ID properties directly. Operations against the object from other Microsoft 365 services generally continue to function normally for administrators of those services:

| Operation | Blocked for non-RMAU-scoped admins? |
|---|---|
| Read standard properties (UPN, photo, etc.) | No — reads are unrestricted |
| Modify any Entra property of the user/group/device | **Yes** |
| Delete the user/group/device | **Yes** |
| Reset a user's password | **Yes** |
| Modify owners or members of a group in the RMAU | **Yes** |
| Add an RMAU member to a *different* group elsewhere in Entra ID | No |
| Modify mailbox/Exchange settings for an RMAU-member user | No |
| Apply Intune policy to an RMAU-member device | No |
| Add/remove an RMAU-member group as a SharePoint site owner | No |
| Assign licenses / change usage location for an RMAU-member user | No |

This split matters operationally: RMAU is specifically an Entra-directory-object control, not a blanket "nobody can touch this object anywhere in Microsoft 365" lockdown. Helpdesk and app teams doing routine Exchange/Intune/SharePoint administration against these users generally won't notice the restriction at all — only identity-plane changes (password, group membership, deletion, property edits) trigger it.

### Who can modify RMAU members, and who can manage the RMAU itself — a critical distinction

Only administrators holding a role **explicitly assigned at the scope of the specific RMAU** (or another RMAU the object is also a member of) can modify the protected objects. Every tenant-scoped role is blocked from direct modification, including:

- Global Administrator
- Privileged Role Administrator
- Groups Administrator, User Administrator, or any other tenant- or resource-scoped role
- Owners of the group or device itself (group/device ownership grants no special RMAU exemption)

Critically, **Global Administrator and Privileged Role Administrator retain the ability to manage the RMAU container itself** even though they can't touch its members directly: creating/deleting the RMAU, adding or removing members, and — the mechanism that resolves the apparent paradox — assigning (or removing) roles scoped to that RMAU, including assigning such a role to themselves. Self-assignment is explicitly called out by Microsoft as an intentional, **auditable** capability: a Global Administrator can always regain access to a stuck RMAU by assigning themselves an AU-scoped role, but doing so leaves an audit trail rather than happening silently through their tenant-wide privilege.

If a tenant-scoped administrator attempts to modify a protected object anyway, they see an explicit block message (on the Overview page for users/devices, the Members page for groups): *"This user is a member of a restricted management administrative unit. Management rights are limited to administrators scoped on that administrative unit."*

### The genuine dead-end case: protecting a Global Administrator's own account

Global Administrator and Privileged Role Administrator cannot themselves be assigned at AU scope — they exist only at tenant scope by design. This creates a specific, documented edge case: if a Global Administrator's own account is added to an RMAU, **no role assignable at AU scope is capable of resetting that account's password**, because Helpdesk Administrator and similar AU-scopable roles are deliberately restricted from acting on higher-privileged accounts, and the roles that *could* act on a Global Administrator (Global Administrator/Privileged Role Administrator themselves) can't be scoped to the AU at all. The only way out is removing the account from the RMAU first, performing the reset via ordinary tenant-scoped rights, then optionally re-adding it afterward.

### Governance-feature incompatibility

Groups and users in an RMAU **cannot** be managed with any Microsoft Entra ID Governance feature: Privileged Identity Management (eligible/active role assignment for the object, or PIM for groups), Entitlement Management (access packages), Lifecycle Workflows, or Access Reviews. This is a hard architectural incompatibility, not a bug awaiting a fix, and it has a real design implication: an organization can't have an executive's account both RMAU-protected *and* covered by a PIM-eligible role assignment or a periodic access review — they must choose one control model per object.

### Programmability and licensing

Applications cannot modify RMAU-member objects by default, even with broad Microsoft Graph application permissions granted — those permissions simply don't apply to protected objects. To let an application manage RMAU members, an Entra role must be explicitly assigned to the application's service principal at the scope of the RMAU, the same mechanism used for human administrators.

Licensing: Microsoft Entra ID **P1** is required for each administrator managing an RMAU; RMAU *members* only need Entra ID Free.

### Limits worth planning around

- Restricted-management setting is **permanent at creation** — cannot be toggled on an existing AU.
- Maximum of **100 RMAUs per tenant**.
- Deleting an RMAU can take up to **30 minutes** to fully remove protections from former members.
- Role-assignable groups added to an RMAU can only have their membership changed by Global Administrator/Privileged Role Administrator (group owners are not exempted the way they might expect).
- A temporary limitation (per Microsoft's own documentation, expected to be removed): groups configured for public/self-service membership can still be joined by users via self-service even while in an RMAU — public membership is not recommended for RMAU-protected groups until this is resolved.

</details>

---
## Dependency Stack

```
[Administrative Unit created with isMemberManagementRestricted = true]
  (permanent at creation — cannot be converted from/to a regular AU afterward)
         │
         ▼
[Direct membership: Users, Devices, or Security Groups only]
  (M365 groups / mail-enabled security groups / distribution groups NOT eligible)
  (membership does not cascade — a group member's own users are unaffected)
         │
         ▼
[Entra property modification, deletion, password reset, and group-membership changes
 for these objects now require a role assignment SCOPED TO THIS SPECIFIC RMAU]
         │
         ▼
[Global Administrator / Privileged Role Administrator retain container management only:
 create/delete RMAU, add/remove members, assign/remove RMAU-scoped roles (incl. to self —
 auditable)]
  (they CANNOT modify member objects' properties directly, and cannot be assigned
   AT the RMAU scope themselves)
         │
         ▼
[AU-scopable roles (e.g. Helpdesk Administrator, User Administrator, Groups Administrator,
 and eligible custom roles) — assigned with DirectoryScopeId = /administrativeUnits/<id> —
 are the only principals that can act on member objects directly]
         │
         ▼
[Entra ID Governance features (PIM, Entitlement Mgmt, Lifecycle Workflows, Access Reviews)
 — INCOMPATIBLE, cannot manage RMAU members at all]
         │
         ▼
[Other Microsoft 365 service-plane operations — Exchange mailbox settings, Intune device
 policy, SharePoint site ownership, license assignment — UNAFFECTED by RMAU membership]
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Global Administrator can't reset a user's password / edit a group's membership, no error beyond a blocked-message UI | Object is an RMAU member and the admin holds no role scoped to that RMAU | `Get-MgDirectoryAdministrativeUnit` → `isMemberManagementRestricted` on the containing AU |
| A security group's *members'* accounts aren't protected even though the group itself is in an RMAU | Membership doesn't cascade — only the group object itself is protected, not its members | Confirm whether the affected user is a *direct* RMAU member, separately from the group |
| Attempt to add a Microsoft 365/mail-enabled security/distribution group to an RMAU fails | Unsupported object type for restricted management AUs | Confirm object type; only Users/Devices/Security Groups are eligible |
| Nobody, including Global Admin, can reset the password of a Global Administrator account | No AU-scopable role can act on a Global Administrator, and Global Admin/Privileged Role Admin can't be assigned at AU scope | Remove the account from the RMAU first, reset via normal tenant-scoped rights, optionally re-add |
| PIM eligible assignment, access review, entitlement management access package, or Lifecycle Workflow task silently doesn't apply to a specific user/group | Target is an RMAU member — hard incompatibility with all Governance features | Confirm RMAU membership before troubleshooting the Governance feature itself as broken |
| Admin who used to manage an RMAU's members no longer can, no config appears to have changed on the RMAU itself | Admin's RMAU-scoped role assignment was removed (offboarding, role change) — separate from any tenant-level role they still hold | `Get-MgDirectoryAdministrativeUnitScopedRoleMember` — confirm the admin still appears |
| Trying to convert an existing regular AU into a restricted one | Not supported — the setting is permanent at creation | Create a new RMAU and move objects into it instead |
| A previously-deleted RMAU's former members still seem partially protected briefly after deletion | Expected — removal of protections can take up to 30 minutes to fully propagate | Re-check after the propagation window |
| Application with broad Graph application permissions (e.g. `User.ReadWrite.All`) still can't modify an RMAU member | Application permissions don't apply to RMAU-protected objects by default | Assign an Entra role to the app's service principal at the RMAU's scope specifically |
| Self-service group join still succeeds for a group inside an RMAU | Known, documented temporary limitation for groups configured with public membership visibility | Set the group's visibility away from `Public`, or treat as an accepted temporary gap per current Microsoft guidance |

---
## Validation Steps

**Step 1 — Confirm an AU is restricted, not regular**
```powershell
Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId "<AU-object-id>" |
    Select-Object DisplayName, Id, @{N='IsRestricted';E={$_.AdditionalProperties.isMemberManagementRestricted}}
```

**Step 2 — Enumerate direct members**
```powershell
Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId "<AU-object-id>"
```

**Step 3 — Enumerate roles scoped to this specific RMAU**
```powershell
Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId "<AU-object-id>"
```

**Step 4 — Confirm a specific user/device/group's RMAU membership from the object side**
```powershell
Get-MgDirectoryAdministrativeUnit -Filter "members/any(m: m/id eq '<object-id>')" -ExpandProperty "members"
```

**Step 5 — Confirm a specific admin's directory role assignments and their scope**
```powershell
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<admin-object-id>'" |
    Select-Object RoleDefinitionId, DirectoryScopeId
```
A `DirectoryScopeId` of `/` is tenant scope (blocked for RMAU members); a value like `/administrativeUnits/<id>` matching the RMAU's own ID is the only kind of assignment that grants access.

**Step 6 — Confirm audit trail for RMAU-affecting changes**

Recorded activities in the Entra audit log include: Add administrative unit (with `IsMemberManagementRestricted = true`), Add/Remove member to/from a restricted management AU, and Add/Remove member to/from a role scoped over an RMAU — review these when investigating who granted or changed RMAU-scoped access and when.

---
## Troubleshooting Steps (by phase)

### Phase 1: Confirm the object is actually RMAU-protected

1. Don't assume — check `isMemberManagementRestricted` on the containing AU before troubleshooting a "can't edit this object" report as anything else. This single check resolves the large majority of tickets on this topic immediately.

### Phase 2: Confirm scope of the blocked operation

1. Cross-reference the specific attempted operation (password reset, property edit, group membership change, deletion) against the blocked-vs-allowed operation table — some operations against RMAU members from other M365 services are never blocked and don't need any RMAU-specific remediation.

### Phase 3: Resolve access

1. If ongoing access is needed, a Global Administrator or Privileged Role Administrator assigns an AU-scopable role at the RMAU's scope to the appropriate admin.
2. If the blocked operation has no valid AU-scopable role capable of performing it (the Global-Administrator-as-RMAU-member edge case), remove the object from the RMAU temporarily, perform the operation via ordinary tenant-scoped rights, then decide whether to re-add it.

### Phase 4: Governance-feature conflicts

1. If a PIM/Access Review/Entitlement Management/Lifecycle Workflow issue traces back to an RMAU member, stop troubleshooting the Governance feature as broken — confirm the incompatibility explicitly and decide, with the stakeholder, which control model (RMAU protection or Governance-feature coverage) takes priority for that specific object.

### Phase 5: Design review (for recurring friction)

1. If a specific RMAU is generating frequent access friction, review whether its membership, role scoping, or even its restricted-vs-regular AU choice still matches the organization's actual compliance/security intent — remember the restricted setting can't be changed in place, so a design correction here means creating a new AU.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standing up a new RMAU for an executive-protection scenario</summary>

**When:** Onboarding RMAU protection for a set of C-level accounts and their devices, to prevent Helpdesk Administrators (or any tenant-scoped admin) from resetting passwords or reading BitLocker recovery keys without explicit authorization.

1. Create the RMAU with the restricted flag set at creation (cannot be added later):
```powershell
$params = @{
    DisplayName                  = "Executive Protection"
    Description                  = "Restricted management AU for C-level accounts and devices"
    Visibility                   = "HiddenMembership"
    IsMemberManagementRestricted = $true
}
$rmau = New-MgDirectoryAdministrativeUnit -BodyParameter $params
```
2. Add eligible objects (Users and Devices — not groups, for this scenario) as direct members.
3. Assign a small, named set of trusted administrators an AU-scopable role (commonly Helpdesk Administrator for password/MFA-method resets) scoped to this RMAU.
4. Document that Global Administrator/Privileged Role Administrator retain container management (they can always reassign scoped roles, including to themselves, as an auditable action) but not direct member modification.

**Rollback:** Remove members from the RMAU (protection lifts after processing, up to ~30 minutes) or delete the RMAU entirely if the model is being abandoned — deletion also takes up to 30 minutes to fully remove protections from former members.

</details>

<details><summary>Playbook 2 — Restricting management of a sensitive security group</summary>

**When:** A security group gates access to a sensitive resource (e.g., a SharePoint site with financial data) and tenant-scoped Groups Administrators should not be able to add/remove members or change ownership.

1. Confirm the group is a genuine Security group (not Microsoft 365, mail-enabled security, or distribution) — only security groups are RMAU-eligible.
2. Add the group as a direct RMAU member.
3. Assign a narrowly scoped Groups Administrator (or custom role with group-management permissions) at the RMAU's scope to the specific trusted admin(s) who should control this group's membership going forward.
4. If the group is role-assignable, note that only Global Administrator/Privileged Role Administrator can modify its membership once RMAU-protected — group owners are not exempted, which may itself require a stakeholder conversation if owners currently expect self-service membership control.

**Rollback:** Remove the group from the RMAU to restore normal tenant-scoped Groups Administrator control.

</details>

<details><summary>Playbook 3 — Recovering from the Global-Administrator-as-RMAU-member dead end</summary>

**When:** A Global Administrator's own account was added to an RMAU (directly, or because they're also an executive protected by Playbook 1's scope) and now needs a password reset, MFA method reset, or other action no AU-scopable role can perform.

1. A Global Administrator or Privileged Role Administrator removes the account from the RMAU:
```powershell
Remove-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId "<AU-object-id>" -DirectoryObjectId "<user-object-id>"
```
2. Perform the needed operation using ordinary tenant-scoped Global Administrator rights.
3. Re-add the account to the RMAU afterward if the protection is still desired long-term:
```powershell
New-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId "<AU-object-id>" -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/<user-object-id>"
}
```

**Rollback:** N/A — this playbook is itself the resolution; re-adding restores the original protective intent.

</details>

<details><summary>Playbook 4 — Fleet-wide RMAU configuration audit</summary>

Run `Get-RestrictedManagementAUAudit.ps1` (see Scripts/) to produce a single report covering: every RMAU in the tenant and its member inventory by object type, every RMAU-scoped role assignment (flagging any assignment whose principal no longer exists or is disabled), and a cross-check flagging any RMAU member that is also targeted by a PIM eligible assignment, an access review, an entitlement management access package, or a Lifecycle Workflow rule — since those configurations will silently not apply and are worth surfacing proactively rather than discovering during an incident.

**Rollback:** N/A — read-only audit pass.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect RMAU configuration and scoped-role evidence for escalation
.NOTES     Requires Microsoft.Graph PowerShell SDK connected with AdministrativeUnit.Read.All,
           RoleManagement.Read.Directory scopes. Read-only.
#>

$output = [System.Collections.Generic.List[string]]::new()
$ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
$out    = ".\RMAUEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).txt"

function Add-Section {
    param([string]$Title, [scriptblock]$Body)
    $output.Add("=" * 60)
    $output.Add("  $Title")
    $output.Add("=" * 60)
    try { $output.Add((&$Body | Out-String).Trim()) }
    catch { $output.Add("ERROR: $($_.Exception.Message)") }
    $output.Add("")
}

Add-Section "Collection metadata" {
    "Collected : $ts"
    "Tenant    : $((Get-MgContext).TenantId)"
}

Add-Section "Target RMAU state" {
    Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId $env:RMAU_TARGET_ID |
        Select-Object DisplayName, Id, @{N='IsRestricted';E={$_.AdditionalProperties.isMemberManagementRestricted}} |
        Format-List | Out-String
}

Add-Section "RMAU members" {
    Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $env:RMAU_TARGET_ID | Format-Table -AutoSize | Out-String
}

Add-Section "Roles scoped to this RMAU" {
    Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId $env:RMAU_TARGET_ID | Format-Table -AutoSize | Out-String
}

$output | Set-Content -Path $out -Encoding UTF8
Write-Host "Evidence saved to: $out" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Create a restricted management AU | `New-MgDirectoryAdministrativeUnit -BodyParameter @{DisplayName=...; IsMemberManagementRestricted=$true}` |
| Check whether an AU is restricted | `Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId <id>` → `AdditionalProperties.isMemberManagementRestricted` |
| List RMAU members | `Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId <id>` |
| Add a member | `New-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId <id> -BodyParameter @{"@odata.id"=...}` |
| Remove a member | `Remove-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId <id> -DirectoryObjectId <objId>` |
| List roles scoped to an RMAU | `Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId <id>` |
| Assign an AU-scoped role | `New-MgRoleManagementDirectoryRoleAssignment -BodyParameter @{DirectoryScopeId="/administrativeUnits/<id>";...}` |
| Remove an AU-scoped role assignment | `Remove-MgRoleManagementDirectoryRoleAssignment -UnifiedRoleAssignmentId <assignmentId>` |
| Find which AU(s) an object belongs to | `Get-MgDirectoryAdministrativeUnit -Filter "members/any(m: m/id eq '<objId>')" -ExpandProperty members` |
| Delete an RMAU | `Remove-MgDirectoryAdministrativeUnit -AdministrativeUnitId <id>` |

---
## 🎓 Learning Pointers

- **RMAU is a two-key design, not a single override switch.** Global Administrator and Privileged Role Administrator lose the ability to touch RMAU members directly, but retain full control of the RMAU container itself — including the ability to grant themselves member access, which is deliberately auditable rather than silently automatic. Understanding this distinction (container control vs. member modification) resolves most confusion about "why can't the Global Admin just fix this." [Restricted management administrative units in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/admin-units-restricted-management)
- **Membership doesn't cascade — this is the most common design mistake when standing up an RMAU.** Adding a group to an RMAU protects the group object; it does not extend to protect the Entra properties of that group's individual members. Protecting a set of users requires adding each of them (or their devices) directly.
- **The restricted-vs-regular decision is permanent at creation.** There's no migration path from a regular AU to an RMAU in place — get this decision right before creating the AU, since correcting it means standing up a new one and moving objects across.
- **Only three object types are eligible: Users, Devices, Security Groups.** Microsoft 365 groups, mail-enabled security groups, and distribution groups cannot be RMAU members at all — a real constraint worth flagging early when scoping a client's requirements, rather than discovering it mid-implementation.
- **This is a hard incompatibility with Entra ID Governance features, not a bug to route around.** PIM, Entitlement Management, Lifecycle Workflows, and Access Reviews simply do not work against RMAU members — a client wanting both RMAU protection and PIM-eligible role coverage for the same executive account needs to be told plainly that they must choose one model.
- **License requirement is per-administrator, not per-member.** Entra ID P1 is required for each admin managing an RMAU; the protected users/devices/groups themselves only need Entra ID Free — relevant when scoping licensing cost for a client considering this feature.
- **Reference:** [Create or delete administrative units](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/admin-units-manage) | [Administrative units in Microsoft Entra ID (overview)](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units) | [Administrative units troubleshooting and FAQ](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/admin-units-faq-troubleshoot)
