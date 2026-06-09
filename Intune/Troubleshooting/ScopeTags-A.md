# Intune Scope Tags & RBAC — Reference Runbook (Mode A: Deep Dive)
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

| Item | Detail |
|------|--------|
| **Service** | Microsoft Intune — Scope Tags & Role-Based Access Control (RBAC) |
| **Tenant type** | Any (cloud-only, hybrid) |
| **Roles affected** | Custom Intune roles, built-in roles with scoped assignments |
| **Who this is for** | L2/L3 engineers managing multi-tenant MSP setups or segmented enterprise environments |
| **Not covered** | Entra ID RBAC, Azure RBAC, Defender for Endpoint roles |

**Core use case:** MSPs running multiple customers from a single Intune tenant, or enterprises segmenting IT into regional/divisional teams each with their own device scope.

---

## How It Works

<details><summary>Full architecture</summary>

### What are Scope Tags?

Scope Tags are labels you attach to Intune objects (policies, apps, devices, scripts, etc.) and to admin role assignments. An admin can **only see and manage objects that share at least one of their assigned scope tags**.

The Default scope tag (`0`) is special: objects with only the Default tag are visible to all admins. Any object you explicitly tag with a custom tag becomes invisible to admins who don't carry that tag in their role assignment.

### The RBAC triad

Three components must align for an admin to act on an object:

```
┌─────────────────────────────────────────────────────┐
│  Admin must have ALL THREE:                         │
│                                                     │
│  1. Role Assignment (built-in or custom)            │
│     └─ Grants: what ACTIONS are allowed             │
│        e.g. "Read devices", "Update policies"       │
│                                                     │
│  2. Assigned Groups (members in the role)           │
│     └─ Grants: WHO can use the role                 │
│        e.g. Security Group "Intune-Admins-EMEA"    │
│                                                     │
│  3. Scope Groups / Scope Tags                       │
│     └─ Grants: WHICH OBJECTS are visible            │
│        Scope Tags: label-match on Intune objects    │
│        Scope Groups: AAD group membership of device │
└─────────────────────────────────────────────────────┘
```

### How scope is evaluated

When an admin tries to view or act on an Intune object, the service checks:

1. Is the admin in a role assignment that grants the required permission?
2. Does that role assignment carry a scope tag that matches **at least one** tag on the target object?
3. If both: **ALLOW**. If either fails: **DENY** (object invisible or action blocked).

The "at least one matching tag" rule means objects with multiple tags are visible to any admin whose assignment carries **any one** of those tags — they don't need all of them.

### Scope Groups vs Scope Tags

| | Scope Groups | Scope Tags |
|--|--|--|
| **What they scope** | Devices (via AAD group membership) | All Intune objects (devices, policies, apps, scripts) |
| **Granularity** | Device-level | Object-level |
| **Preferred for** | Legacy setups | Modern recommended approach |
| **Can coexist** | Yes | Yes |

Microsoft is moving away from Scope Groups toward Scope Tags. You can use both, but Scope Tags are more consistent — they scope policies AND devices in the same model.

### How devices get tagged

Devices inherit Scope Tags via:
- **Dynamic assignment** — enrollment profiles carrying a tag apply it to all devices enrolled through that profile
- **Manual assignment** — batch-tagging devices directly in the portal or via script
- **Group-based tagging** — not directly supported; requires scripted bulk-tag via Graph API

If a device has no custom scope tag, it only carries the Default tag — visible to all admins with any Intune role.

### How policies/apps get tagged

When creating or editing a policy, script, app, or configuration profile, the Scope Tags field appears in the Basics tab. Once tagged, only admins carrying that tag can see the object.

**Critical gotcha:** If you tag a policy with a custom tag but forget to tag the assignment groups, the policy won't appear in the admin's view even if they carry the tag. The assignment groups themselves must also be tagged (or the admin must have an all-objects scope).

</details>

---

## Dependency Stack

```
Entra ID (Azure AD)
│
├── User accounts & Security Groups
│   └─ Used in Intune role assignment "Members" and "Scope Groups"
│
└── Device objects
    └─ Membership in AAD groups used for Scope Groups

Intune Tenant
│
├── Scope Tags
│   └─ Attached to: devices, policies, apps, scripts, enrollment profiles,
│      compliance policies, config profiles, filters, remediation scripts
│
├── Custom/Built-in Roles
│   └─ Define: allowed actions (permissions bitmask)
│
└── Role Assignments
    ├─ Members: AAD group → who has this role
    ├─ Scope Tags: which labeled objects they can see
    └─ Scope Groups (optional): which devices by AAD group
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Admin can't see a policy that definitely exists | Policy has a scope tag the admin's assignment doesn't carry | Check policy Scope Tags vs. admin's role assignment tags |
| Admin can see policy but can't edit it | Role doesn't have write permissions for that policy type | Check role permissions — not just scope |
| Device doesn't appear in admin's device list | Device doesn't carry a matching scope tag | Check device's assigned scope tags |
| New policy not visible after creation | Creator's scope tag not applied to the new policy | Scope Tags field blank on policy — defaults to Default only |
| Admins in one tenant see all of another tenant's objects | Scope Tag not applied to objects at provisioning time | Audit all objects for correct tagging |
| "You don't have permission" on a specific action | Missing specific permission in the role | Role audit required — permissions are granular |
| Admin can see but not assign a group | Assignment group not tagged / admin has no scope over that group | Tag the AAD group or expand scope |
| Enrollment profile not visible to sub-admin | Profile missing the sub-admin's scope tag | Edit enrollment profile → Scope Tags |

---

## Validation Steps

**1. Confirm the admin's current role assignments**

```powershell
# Connect-MgGraph -Scopes "DeviceManagementRBAC.Read.All"
$upn = "admin@contoso.com"
$user = Get-MgUser -Filter "userPrincipalName eq '$upn'" -Property Id
$assignments = Get-MgDeviceManagementRoleAssignment -Filter "roleDefinition/id ne null"
foreach ($a in $assignments) {
    $members = Get-MgDeviceManagementRoleAssignmentMember -RoleAssignmentId $a.Id
    if ($members.Id -contains $user.Id) {
        Write-Host "Role: $($a.DisplayName) | Scope Tags: $($a.ScopeTagIds -join ', ')"
    }
}
```

Expected good output: role name + scope tag IDs matching the objects the admin needs to manage.

Bad: no output — admin has no role assignment at all. Empty `ScopeTagIds` — admin has Default scope only.

---

**2. Check scope tags on the target object (policy/app/device)**

```powershell
# For a config profile
$profileName = "Windows-Security-Baseline"
$profile = Get-MgDeviceManagementDeviceConfiguration -Filter "displayName eq '$profileName'"
Write-Host "Scope Tags on '$profileName': $($profile.RoleScopeTagIds -join ', ')"
```

Expected: tag ID that matches the admin's assignment. If empty, it carries Default only.

---

**3. Enumerate all scope tags in the tenant**

```powershell
Get-MgDeviceManagementRoleScopeTag | Select-Object Id, DisplayName, Description |
    Format-Table -AutoSize
```

Maps numeric tag IDs to human-readable names for cross-referencing.

---

**4. Verify device scope tag assignment**

```powershell
$deviceName = "LAPTOP-001"
$device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$deviceName'"
Write-Host "Scope Tags on '$deviceName': $($device.RoleScopeTagIds -join ', ')"
```

---

**5. Check role permissions (not just scope)**

```powershell
$roleName = "EMEA-Helpdesk"
$role = Get-MgDeviceManagementRoleDefinition -Filter "displayName eq '$roleName'"
$role.RolePermissions.ResourceActions | ForEach-Object {
    Write-Host "Allowed: $($_.AllowedResourceActions -join "`n")"
}
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm the RBAC triad

1. Identify the admin's UPN and the specific object they can't see/act on.
2. Run Step 1 above — confirm they have a role assignment with correct scope tags.
3. Run Step 3 — map tag IDs to names so you're working with readable labels.
4. Run Step 2 on the target object — confirm the tag IDs align.

If tags don't align → go to Remediation Playbook 1.
If tags align but action fails → go to Phase 2.

### Phase 2 — Permission check (not scope)

5. Run Step 5 — enumerate allowed actions in the role.
6. Compare against the specific action failing (e.g., `Microsoft.Intune/DeviceConfigurations/Write`).
7. If the permission is missing → go to Remediation Playbook 2.

### Phase 3 — Scope Groups conflict

8. Check if the admin's role assignment uses Scope Groups instead of (or in addition to) Scope Tags.
9. Confirm target devices are members of the Scope Group.
10. If device group membership is wrong → add device to group or migrate to Scope Tags model.

### Phase 4 — Enrollment pipeline (new tenants/new objects)

11. Check enrollment profiles — new profiles default to no custom scope tag.
12. Check if automation (Power Automate, Graph) creating policies is tagging them at creation time.
13. Check that AAD dynamic group rules include new devices before they're scoped.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Add scope tag to an existing policy via Graph</summary>

**Scenario:** Policy exists but admin can't see it because it lacks their scope tag.

```powershell
# Prerequisites: Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All"

$profileId = "<config-profile-object-id>"
$tagToAdd  = "<scope-tag-id>"   # numeric ID from Get-MgDeviceManagementRoleScopeTag

# Get current tags
$profile = Get-MgDeviceManagementDeviceConfiguration -DeviceConfigurationId $profileId
$currentTags = $profile.RoleScopeTagIds

# Add new tag without removing existing
$newTags = $currentTags + $tagToAdd | Select-Object -Unique

Update-MgDeviceManagementDeviceConfiguration -DeviceConfigurationId $profileId `
    -RoleScopeTagIds $newTags

Write-Host "Updated scope tags: $($newTags -join ', ')"
```

**Rollback:** Re-run the update with `$currentTags` only (saved before the change).

**Note:** Repeat for compliance policies using `Update-MgDeviceManagementDeviceCompliancePolicy`.

</details>

<details><summary>Playbook 2 — Create or update a custom Intune role with correct permissions</summary>

**Scenario:** Admin has correct scope but role is missing specific permissions.

```powershell
# Get the current role
$roleName = "EMEA-Helpdesk"
$role = Get-MgDeviceManagementRoleDefinition -Filter "displayName eq '$roleName'"

# Inspect current permissions
$current = $role.RolePermissions[0].ResourceActions.AllowedResourceActions

# Add the missing permission (example: read remediation scripts)
$newPermission = "Microsoft.Intune/DeviceHealthScripts/Read"
$updated = $current + $newPermission | Select-Object -Unique

$params = @{
    RolePermissions = @(
        @{
            ResourceActions = @{
                AllowedResourceActions = $updated
            }
        }
    )
}
Update-MgDeviceManagementRoleDefinition -RoleDefinitionId $role.Id -BodyParameter $params
Write-Host "Role updated. New permission count: $($updated.Count)"
```

**Rollback:** Re-run with `$current` to restore original permissions.

**Warning:** Changes take effect immediately — the admin's next API/portal call will reflect the new permissions. No restart required.

</details>

<details><summary>Playbook 3 — Bulk-tag devices via Graph API</summary>

**Scenario:** A batch of devices needs to be assigned a scope tag (e.g., after migration or MSP onboarding).

```powershell
# Prerequisites: Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All"

$targetTagId = "<scope-tag-id>"
$groupId     = "<aad-group-id>"   # devices in this group

# Get devices via group membership
$members = Get-MgGroupMember -GroupId $groupId -All
$deviceIds = $members | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.device' } |
    ForEach-Object { $_.Id }

$successCount = 0
$failCount    = 0

foreach ($deviceId in $deviceIds) {
    try {
        # Find managed device by AAD device ID
        $managed = Get-MgDeviceManagementManagedDevice -Filter "azureAdDeviceId eq '$deviceId'" |
            Select-Object -First 1
        if ($managed) {
            $currentTags = $managed.RoleScopeTagIds
            $newTags = ($currentTags + $targetTagId) | Select-Object -Unique
            Update-MgDeviceManagementManagedDevice -ManagedDeviceId $managed.Id `
                -RoleScopeTagIds $newTags
            $successCount++
        }
    }
    catch { $failCount++; Write-Warning "Failed: $deviceId — $_" }
}

Write-Host "Tagged: $successCount | Failed: $failCount"
```

**Rollback:** Export current tags before running (add CSV export of `$managed.RoleScopeTagIds` per device).

</details>

<details><summary>Playbook 4 — Audit all untagged objects in the tenant</summary>

**Scenario:** Need to find all policies/profiles with only the Default scope tag (potential visibility gaps).

```powershell
# Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","DeviceManagementApps.Read.All"

$untagged = @()

# Config profiles
Get-MgDeviceManagementDeviceConfiguration -All | Where-Object {
    $_.RoleScopeTagIds.Count -eq 0 -or
    ($_.RoleScopeTagIds.Count -eq 1 -and $_.RoleScopeTagIds[0] -eq "0")
} | ForEach-Object { $untagged += [PSCustomObject]@{ Type="ConfigProfile"; Name=$_.DisplayName; Id=$_.Id } }

# Compliance policies
Get-MgDeviceManagementDeviceCompliancePolicy -All | Where-Object {
    $_.RoleScopeTagIds.Count -eq 0 -or
    ($_.RoleScopeTagIds.Count -eq 1 -and $_.RoleScopeTagIds[0] -eq "0")
} | ForEach-Object { $untagged += [PSCustomObject]@{ Type="CompliancePolicy"; Name=$_.DisplayName; Id=$_.Id } }

$untagged | Export-Csv -Path ".\Untagged-IntuneObjects-$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation
Write-Host "Untagged objects found: $($untagged.Count). Exported to CSV."
```

</details>

---

## Evidence Pack

```powershell
<#
  Evidence Pack — Intune Scope Tags / RBAC Investigation
  Run this before raising a ticket with Microsoft or escalating internally.
  Outputs a single timestamped folder with all relevant data.
#>

# Connect-MgGraph -Scopes "DeviceManagementRBAC.Read.All","DeviceManagementConfiguration.Read.All","DeviceManagementManagedDevices.Read.All"

$affected_upn    = "<admin-upn>"
$affected_object = "<policy-or-device-name>"
$out = ".\IntuneRBAC-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

# 1. All scope tags
Get-MgDeviceManagementRoleScopeTag |
    Select-Object Id, DisplayName, Description |
    Export-Csv "$out\ScopeTags-All.csv" -NoTypeInformation

# 2. Admin's role assignments
$user = Get-MgUser -Filter "userPrincipalName eq '$affected_upn'" -Property Id
$roleAssignments = Get-MgDeviceManagementRoleAssignment -All
$adminAssignments = @()
foreach ($ra in $roleAssignments) {
    $members = Get-MgDeviceManagementRoleAssignmentMember -RoleAssignmentId $ra.Id
    if ($members.Id -contains $user.Id) {
        $adminAssignments += [PSCustomObject]@{
            AssignmentName = $ra.DisplayName
            ScopeTagIds    = $ra.ScopeTagIds -join "|"
            ScopeGroupIds  = $ra.ScopeMembers -join "|"
        }
    }
}
$adminAssignments | Export-Csv "$out\Admin-RoleAssignments.csv" -NoTypeInformation

# 3. All role definitions
Get-MgDeviceManagementRoleDefinition -All |
    Select-Object Id, DisplayName, Description, IsBuiltIn |
    Export-Csv "$out\RoleDefinitions-All.csv" -NoTypeInformation

# 4. Search for target object's tags
$profiles = Get-MgDeviceManagementDeviceConfiguration -Filter "displayName eq '$affected_object'"
$profiles | Select-Object DisplayName, Id, RoleScopeTagIds |
    Export-Csv "$out\TargetObject-Tags.csv" -NoTypeInformation

Write-Host "Evidence collected in: $out"
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| List all scope tags | `Get-MgDeviceManagementRoleScopeTag \| Select Id, DisplayName` |
| List all role assignments | `Get-MgDeviceManagementRoleAssignment -All \| Select DisplayName, ScopeTagIds` |
| List all role definitions | `Get-MgDeviceManagementRoleDefinition -All \| Select DisplayName, IsBuiltIn` |
| Get tags on a config profile | `(Get-MgDeviceManagementDeviceConfiguration -Filter "displayName eq '<name>'").RoleScopeTagIds` |
| Get tags on a device | `(Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<name>'").RoleScopeTagIds` |
| Update tags on a config profile | `Update-MgDeviceManagementDeviceConfiguration -DeviceConfigurationId <id> -RoleScopeTagIds @("0","<tagId>")` |
| Update tags on a device | `Update-MgDeviceManagementManagedDevice -ManagedDeviceId <id> -RoleScopeTagIds @("<tagId>")` |
| Get role members | `Get-MgDeviceManagementRoleAssignmentMember -RoleAssignmentId <id>` |
| Create a new scope tag | `New-MgDeviceManagementRoleScopeTag -DisplayName "<name>" -Description "<desc>"` |
| Get all managed devices with Default tag only | `Get-MgDeviceManagementManagedDevice -All \| Where { $_.RoleScopeTagIds -eq @('0') }` |
| Find policies an admin can see (simulation) | Compare admin ScopeTagIds against policy RoleScopeTagIds |
| Export all assignments for a role | `Get-MgDeviceManagementRoleAssignment -Filter "roleDefinition/id eq '<roleId>'"` |

---

## 🎓 Learning Pointers

- **The "at least one tag" rule is frequently misunderstood.** Objects with multiple scope tags are visible to any admin carrying any one of those tags — not all of them. This matters for shared/cross-team objects. MS Docs: [Scope tags for distributed IT](https://learn.microsoft.com/en-us/mem/intune/fundamentals/scope-tags)

- **Default tag (ID: 0) is a wildcard, not a tag.** Objects only carrying Default are visible to *all* Intune admins with any role. If you want strict segmentation, every object must carry at least one custom tag. Leaving the Default tag on while adding custom tags makes the object visible to more people than you expect.

- **Scope Groups are device-only and legacy.** If you're building a new segmentation model, use Scope Tags for everything. MS has indicated Scope Tags are the strategic path. Scope Groups add complexity with little additional value in modern setups.

- **Enrollment profiles are the source of truth for device tags.** If devices arrive untagged, trace back to the enrollment profile — Autopilot profiles, ADE profiles (macOS/iOS), and bulk enrollment tokens all carry scope tag fields. Missing tags here means every device enrolled through that profile arrives in the wrong scope.

- **Automation must tag at object creation.** If you use Power Automate, Graph, or scripts to create policies/apps/scripts, the `roleScopeTagIds` field must be set at `POST` time. You can patch it later, but untagged objects created between `POST` and `PATCH` are visible to all admins — a security gap in regulated environments.

- **The Intune RBAC permission model is more granular than most admins realise.** There are separate Read/Write/Delete permissions for each policy type (ConfigProfiles, CompliancePolicies, Apps, Scripts, etc.). A common MSP mistake is giving sub-admins a broad "Helpdesk" role that can read but not write, then wondering why a save button is greyed out. Always verify the specific action permission, not just the scope. Reference: [Intune RBAC permission table](https://learn.microsoft.com/en-us/mem/intune/fundamentals/role-based-access-control)
