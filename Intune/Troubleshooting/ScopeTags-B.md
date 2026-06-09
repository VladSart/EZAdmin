# Intune Scope Tags & RBAC — Hotfix Runbook (Mode B: Ops)
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

Run these first to identify whether this is a scope tag, RBAC role, or assignment issue.

```powershell
# Requires: Microsoft.Graph PowerShell SDK
# Connect: Connect-MgGraph -Scopes "DeviceManagementRBAC.Read.All","DeviceManagementConfiguration.Read.All"

# 1. List all scope tags in the tenant
Get-MgDeviceManagementRoleScopeTag | Select-Object DisplayName, Id, Description

# 2. List all custom RBAC roles
Get-MgDeviceManagementRoleDefinition |
  Where-Object IsBuiltIn -eq $false |
  Select-Object DisplayName, Id, IsBuiltIn

# 3. Get all role assignments
Get-MgDeviceManagementRoleAssignment |
  Select-Object DisplayName, Id, @{N="ScopeTagIds";E={$_.RoleScopeTagIds -join ", "}} |
  Format-Table

# 4. Check which scope tags are on a specific device (replace DeviceId)
$deviceId = "<device-object-id>"
Get-MgDeviceManagementManagedDevice -ManagedDeviceId $deviceId |
  Select-Object DeviceName, RoleScopeTagIds

# 5. Get scope tag members (which resources have this tag)
$tagId = "<scope-tag-id>"
Get-MgDeviceManagementRoleScopeTagAssignment -RoleScopeTagId $tagId |
  Select-Object DisplayName, TargetType
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| Admin can't see devices/policies | Missing scope tag on role assignment or device | → Fix 1 |
| Policy not visible to helpdesk role | Scope tag on policy not in helpdesk's role assignment | → Fix 2 |
| `403 Forbidden` when assigning scope tag | Admin doesn't have RBAC write permissions | → Fix 3 |
| Device shows wrong scope tag | Auto-assignment rule misconfigured | → Fix 4 |
| Scope tag present but role sees nothing | Role definition missing required resource actions | → Fix 5 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Intune RBAC Model
  │
  ├── Role Definition (built-in or custom)
  │     └── Resource Actions (read/write per resource type)
  │
  ├── Role Assignment
  │     ├── Assigned to: Entra ID Security Group (members = admins who get this role)
  │     ├── Scope Groups: Entra ID groups (defines which USER objects they can manage)
  │     └── Scope Tags: which resources (devices, policies, apps) are visible
  │
  └── Scope Tags
        ├── Assigned to: Role Assignments (determines visibility)
        ├── Assigned to: Managed Devices (device must have tag to be visible)
        ├── Assigned to: Configuration Policies (policy must have tag to be visible)
        └── Assigned to: Apps (app must have tag to be visible)

For a resource to be visible to an admin:
  Admin ∈ Role Assignment Group
  AND Role Assignment has Scope Tag X
  AND Resource has Scope Tag X (or resource has Default scope tag and assignment includes Default)
```
</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the admin's effective role assignments**
```powershell
# Get the admin's UPN
$adminUpn = "<admin@domain.com>"
$adminId = (Get-MgUser -Filter "UserPrincipalName eq '$adminUpn'").Id

# Find which role assignment groups they're a member of
Get-MgDeviceManagementRoleAssignment | ForEach-Object {
    $assignment = $_
    $groups = Get-MgDeviceManagementRoleAssignmentPrincipal -RoleAssignmentId $assignment.Id
    foreach ($g in $groups) {
        $members = Get-MgGroupMember -GroupId $g.Id -ErrorAction SilentlyContinue
        if ($members.Id -contains $adminId) {
            Write-Host "Role Assignment: $($assignment.DisplayName) | Tags: $($assignment.RoleScopeTagIds -join ',')"
        }
    }
}
```

**Step 2 — Compare scope tags on resource vs. role assignment**
```powershell
# Check tags on a config policy (replace policyId)
$policyId = "<policy-object-id>"
Get-MgDeviceManagementDeviceConfiguration -DeviceConfigurationId $policyId |
  Select-Object DisplayName, RoleScopeTagIds
```
- Resource scope tag must match at least one scope tag in the admin's role assignment
- If resource has only `Default (0)` and role assignment doesn't include Default → invisible

**Step 3 — Check if scope tag 0 (Default) is included in the role assignment**
- In Intune portal: Tenant admin → Roles → [Role] → Assignments → check Scope Tags column
- Default scope tag (ID = 0) covers all untagged resources
- If admin's assignment excludes Default, they cannot see any resource without an explicit tag

**Step 4 — Verify the role definition includes required resource actions**
```powershell
$roleDefId = "<role-definition-id>"
Get-MgDeviceManagementRoleDefinition -RoleDefinitionId $roleDefId |
  Select-Object -ExpandProperty RolePermissions | ForEach-Object {
    $_.ResourceActions | Select-Object AllowedResourceActions, NotAllowedResourceActions
  }
```
- Must include `Microsoft.Intune_DeviceConfigurations_Read` (or relevant resource) to see policies
- Read permission alone is not enough if the scope tag doesn't match

---
## Common Fix Paths

<details><summary>Fix 1 — Admin can't see devices: add scope tag to role assignment</summary>

Via portal (fastest):
1. Intune → Tenant admin → Roles → [Role Name] → Assignments → [Assignment Name] → Edit
2. Add the required scope tag to the "Scope tags" field
3. Save

Via PowerShell:
```powershell
Connect-MgGraph -Scopes "DeviceManagementRBAC.ReadWrite.All"

$assignmentId = "<role-assignment-id>"
$newTagId = "<scope-tag-id>"

# Get current tags
$assignment = Get-MgDeviceManagementRoleAssignment -RoleAssignmentId $assignmentId
$currentTags = $assignment.RoleScopeTagIds
$updatedTags = $currentTags + $newTagId

# Update assignment
Update-MgDeviceManagementRoleAssignment -RoleAssignmentId $assignmentId `
  -RoleScopeTagIds $updatedTags
```

**Rollback:** Remove the added tag from `$updatedTags` and update again.
</details>

<details><summary>Fix 2 — Policy not visible: add scope tag to the policy</summary>

Via portal:
1. Intune → Devices → Configuration profiles → [Policy] → Properties → Scope tags → Edit
2. Add the required scope tag
3. Review + Save

Via PowerShell (device configuration):
```powershell
$policyId = "<policy-id>"
$tagId = "<scope-tag-id>"

$existing = (Get-MgDeviceManagementDeviceConfiguration -DeviceConfigurationId $policyId).RoleScopeTagIds
$updated = ($existing + $tagId) | Select-Object -Unique

Update-MgDeviceManagementDeviceConfiguration -DeviceConfigurationId $policyId `
  -RoleScopeTagIds $updated
```

**Note:** The `Default` scope tag (ID = "0") is applied automatically to resources created without tags. Removing it from a resource removes visibility for any admin whose role assignment only includes Default.
</details>

<details><summary>Fix 3 — 403 error when trying to manage scope tags</summary>

```powershell
# The acting admin needs: Intune Role Administrator or Global Administrator
# Check current admin's Intune role:
$adminUpn = "<admin@domain.com>"
$adminId = (Get-MgUser -Filter "UserPrincipalName eq '$adminUpn'").Id

# Check directory role assignments (Global Admin, Intune Admin)
Get-MgUserTransitiveMemberOf -UserId $adminId |
  Where-Object { $_.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.directoryRole" } |
  Select-Object @{N="Role";E={$_.AdditionalProperties["displayName"]}}
```

If the admin lacks the **Intune Role Administrator** or **Intune Administrator** (Entra ID role), they cannot modify RBAC. Escalate to Global Admin or have a Global Admin make the change.

**Rollback:** N/A — this is a permission check, not a configuration change.
</details>

<details><summary>Fix 4 — Device has wrong scope tag (auto-assignment issue)</summary>

Scope tags on devices are set manually or via dynamic group rules in some configurations. To correct:

Via portal:
1. Intune → Devices → All devices → [Device] → Properties → Scope tags → Edit
2. Remove incorrect tag, add correct tag
3. Save

Via PowerShell:
```powershell
$deviceId = "<managed-device-id>"
$correctTagId = "<scope-tag-id>"

Update-MgDeviceManagementManagedDevice -ManagedDeviceId $deviceId `
  -RoleScopeTagIds @($correctTagId)
```

**If devices are getting auto-assigned wrong tags**: review if an auto-assignment rule or bulk import script is setting incorrect tags. Check recent Intune audit logs:
```powershell
Get-MgDeviceManagementAuditEvent -Filter "resources/any(r: r/resourceId eq '$deviceId')" |
  Select-Object ActivityDateTime, ActivityType, Actor, Resources |
  Sort-Object ActivityDateTime -Descending | Select-Object -First 10
```
</details>

<details><summary>Fix 5 — Role has correct scope tags but admin still sees nothing</summary>

The role definition itself may be missing resource action permissions. Common gaps:

```powershell
# View all allowed actions in the role definition:
$roleDefId = "<role-def-id>"
(Get-MgDeviceManagementRoleDefinition -RoleDefinitionId $roleDefId).RolePermissions.ResourceActions.AllowedResourceActions

# Compare to built-in Help Desk Operator allowed actions:
$builtIn = Get-MgDeviceManagementRoleDefinition | Where-Object DisplayName -eq "Help Desk Operator"
$builtIn.RolePermissions.ResourceActions.AllowedResourceActions
```

If the custom role is missing `Read` actions for the relevant resource type (devices, configurations, apps), add them via portal:
1. Intune → Tenant admin → Roles → [Custom Role] → Properties → Permissions → Edit
2. Add the missing Read permissions for the affected resource category
3. Save

**Note:** Built-in roles cannot be modified — clone them to a custom role if customisation is needed.
</details>

---
## Escalation Evidence

```
=== ESCALATION: Intune Scope Tags / RBAC Issue ===
Date/Time:            ________________
Affected Admin UPN:   ________________
Tenant ID:            ________________
Issue:                ________________ (can't see devices / policies / apps)

Admin's Role Assignments:
  [paste output of role assignment enumeration from Step 1]

Scope Tags on Admin's Role Assignment:
  ________________ (list tag names/IDs)

Scope Tags on Affected Resource:
  ________________ (list tag names/IDs on the device/policy/app)

Match check:
  [ ] Tags overlap — check role definition permissions
  [ ] Tags do NOT overlap — scope tag assignment mismatch

Role definition resource actions (relevant excerpt):
  [paste AllowedResourceActions for the affected resource type]

Admin's Entra ID roles:
  [paste output of Get-MgUserTransitiveMemberOf check]

Recent audit events on affected resource:
  [paste]

Steps attempted:
  ________________
```

---
## 🎓 Learning Pointers

- **Scope tags are AND logic at the assignment level**: an admin needs their role assignment to contain scope tag X, AND the resource must have scope tag X — both must be true. A role assignment with tags A+B can see resources tagged A, resources tagged B, but not resources tagged C. [MS Docs: Scope Tags](https://learn.microsoft.com/en-us/mem/intune/fundamentals/scope-tags)
- **The Default scope tag (ID = 0)** is automatically applied to every resource unless you explicitly assign a different tag. If you exclude Default from an admin's role assignment, they lose visibility over all untagged resources — a common "why can't I see anything?" scenario after RBAC hardening.
- **Built-in roles cannot be scoped beyond their definition** — if you need a scoped Help Desk role, you must clone the built-in Help Desk Operator role to a custom role and then apply scope tags to the assignment.
- **Scope Groups vs. Scope Tags**: these are different things. Scope Groups limit which **users** an admin can manage (e.g., which user objects they can reset passwords for in Intune). Scope Tags limit which **resources** (devices, policies, apps) are visible. Both must align. [MS Docs: RBAC Concepts](https://learn.microsoft.com/en-us/mem/intune/fundamentals/role-based-access-control)
- **Audit logs are your friend**: every scope tag assignment and RBAC change is logged in Intune audit logs (Tenant admin → Audit logs). Filter by `Category: Role` or `Activity: Assigned scope tag` to trace who changed what and when.
