# SharePoint Permission Management via Power Automate — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **SharePoint Online permission management** when orchestrated through Power Automate, including:

- Granting/revoking site member, visitor, and owner roles via flow
- Managing item-level or folder-level permissions (unique permissions)
- Using **SharePoint REST API** or **Microsoft Graph** connectors inside flows
- Handling permission inheritance — breaking and restoring it
- Managing **external sharing** (guest invites) through automated flows

**Not in scope:** On-premises SharePoint, SharePoint legacy user experience, direct PnP scripting outside of Power Automate.

**Privilege model in scope:**
- Flow connections run under either the **signed-in user** (delegated) or a **service account / app registration** (application)
- Site Collection Administrator rights are required for most permission management operations
- Global Admin is **not** required for most site-level operations

---

## How It Works

<details><summary>Full architecture</summary>

### SharePoint Permissions Model

SharePoint Online uses a **role-based security model** with inheritance:

```
Tenant
  └── Site Collection (root permissions / SCA)
        └── Site (inherits from collection by default)
              └── Library / List (inherits from site by default)
                    └── Folder (can inherit or be unique)
                          └── Item / Document (can inherit or be unique)
```

When inheritance is **not broken**, permission changes at a parent level cascade down automatically. When you break inheritance on a list or item, that object gets its own copy of the permission list — and further parent changes **no longer apply**.

### How Power Automate Interacts with SharePoint Permissions

Power Automate has two primary paths to manage permissions:

**Path 1 — SharePoint Connector built-in actions**
These are the easiest but most limited:
- "Grant access to an item or a folder" — sends an email invitation and grants role
- "Stop sharing an item or a document" — removes unique permissions (restores inheritance OR removes all)
- Limited to delegated permissions of the connection owner

**Path 2 — Send an HTTP request to SharePoint (REST API)**
Full control over the SharePoint REST API via `/_api/web/` endpoints:
- `/_api/web/lists/getbytitle('<list>')/items(<id>)/roleassignments` — manage per-item roles
- `/_api/web/roleassignments` — manage site-level roles
- `/_api/web/breakroleinheritance` / `/_api/web/resetroleinheritance` — control inheritance
- Requires the connection account to have `Site.Manage` or SCA rights

**Path 3 — Microsoft Graph HTTP action**
- `PATCH /sites/{siteId}/permissions` — manage site-level permissions
- More consistent for programmatic use, better for app registrations

### Service Account vs. App Registration

| Approach | Permissions Type | Pros | Cons |
|----------|-----------------|------|------|
| Service account connection | Delegated | Easy setup, no app reg needed | Requires M365 license, MFA-exempt CA policy needed |
| App registration (certificate or secret) | Application | No user context, scales better, no MFA issues | Requires Global Admin or SharePoint Admin to consent; over-permissioned if not scoped |
| Per-user connection | Delegated | Audited as the user | Flow breaks when user leaves org |

### Permission Roles in SharePoint (Numeric IDs for REST API)

When using the REST API, role definitions are referenced by ID:

| Role Name | Typical Role Definition ID |
|-----------|---------------------------|
| Full Control | 1073741829 |
| Design | 1073741828 |
| Edit | 1073741830 |
| Contribute | 1073741827 |
| Read | 1073741826 |
| View Only | 1073741873 |

These IDs are constant across SharePoint Online tenants.

</details>

---

## Dependency Stack

```
Power Automate Flow (Permission Management)
  └── Connection / Credentials
        ├── Delegated: Service account or user
        │     ├── Licensed M365 user
        │     ├── Site Collection Administrator on target site
        │     └── MFA-exempt (for unattended flows) or CA-exempt
        └── Application: App Registration
              ├── SharePoint > Sites.FullControl.All (or Sites.Selected)
              ├── Admin consent granted
              └── Certificate or client secret not expired

  └── Target SharePoint Site
        ├── Site exists and is not read-only / locked
        ├── Inheritance state known (broken or inherited)
        └── External sharing settings (if managing guest access):
              ├── Tenant-level external sharing not disabled
              └── Site-level external sharing = ExistingExternalUserSharingOnly or higher

  └── Entra ID (if managing guest invites)
        └── B2B Collaboration policy not blocking invitations
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "Access Denied" on SharePoint HTTP action | Connection account not SCA on target site | Verify SCA via `/_api/web/currentuser/issiteadmin` |
| "List does not exist" in REST call | List title mismatch (case-sensitive, special chars) | Use `/_api/web/lists` to enumerate actual list names |
| Permission granted but user still blocked | Permissions cached; or item inherits permissions that block | Check unique permissions on item; clear browser cache |
| Flow adds user but role not visible in SharePoint | Used wrong role definition ID | Enumerate role definitions: `/_api/web/roledefinitions` |
| Breaking inheritance fails silently | List has a large number of unique items already (limit: 50,000) | Check unique scopes count in tenant admin |
| Guest invite sent but user can't access | Tenant or site external sharing setting too restrictive | Check tenant sharing level vs. site sharing level |
| "The attempted operation is prohibited because it exceeds the list view threshold" | Returning too many permissions in a single REST call | Use `$select`, `$filter`, pagination with `$skiptoken` |
| App registration flow fails with 401 | Client secret expired, or wrong tenant ID in request | Check app reg secret expiry in Entra ID |
| Flow previously worked but now fails | Connection account removed from SCA, or account licensed changed | Re-add SCA; reconnect the connection |

---

## Validation Steps

**1. Confirm connection account is Site Collection Administrator**
```http
GET https://<tenant>.sharepoint.com/sites/<site>/_api/web/currentuser/issiteadmin
Accept: application/json;odata=nometadata
Authorization: Bearer <token>
```
Expected response: `{"value":true}`. If `false`, add the account as SCA in SharePoint Admin Center or via:
```powershell
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
Set-SPOUser -Site https://<tenant>.sharepoint.com/sites/<site> -LoginName <UPN> -IsSiteCollectionAdmin $true
```

**2. Enumerate role definitions on the target site**
```powershell
# Use PnP PowerShell to list role definition IDs
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<site>" -Interactive
Get-PnPRoleDefinition | Select-Object Name, Id, Description | Format-Table -AutoSize
```

**3. Check inheritance state on a list or item**
```powershell
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<site>" -Interactive

# Check list
$list = Get-PnPList -Identity "<ListName>"
Write-Host "List HasUniqueRoleAssignments: $($list.HasUniqueRoleAssignments)"

# Check specific item
$item = Get-PnPListItem -List "<ListName>" -Id <ItemId>
Write-Host "Item HasUniqueRoleAssignments: $($item.HasUniqueRoleAssignments)"
```

**4. Verify external sharing settings**
```powershell
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com

# Tenant level
$tenant = Get-SPOTenant
Write-Host "Tenant SharingCapability: $($tenant.SharingCapability)"

# Site level
$site = Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<site>"
Write-Host "Site SharingCapability: $($site.SharingCapability)"
```
For guest access to work, **both** tenant AND site levels must allow external sharing.

**5. Validate flow connection in Power Automate**
- In Power Automate > Connections > find the SharePoint connection used by the flow
- Click the connection > verify status is "Connected"
- Re-authenticate if the account's password changed or MFA tokens expired

---

## Troubleshooting Steps (by phase)

### Phase 1 — Flow Fails Immediately (Auth / Connection)

1. **Check the error message in the flow run history.** Power Automate surfaces the HTTP status code — 401 = auth, 403 = permission, 404 = resource not found.

2. **For 401 errors:**
   - Connection account password changed → update the connection
   - App registration secret expired → rotate the secret in Entra ID > App registrations
   - MFA prompt blocking unattended flow → create a CA policy that excludes the service account from MFA (scope to service account group only, require compliant device or named location instead)

3. **For 403 errors:**
   - Service account not SCA on target site → add as SCA
   - App registration missing admin consent → Global Admin must consent to the `Sites.FullControl.All` or `Sites.Selected` Graph permission

---

### Phase 2 — Flow Runs but Permission Not Applied

1. **Verify the principal being granted access exists in Entra ID:**
   ```powershell
   Get-MgUser -Filter "userPrincipalName eq '<UPN>'" | Select-Object Id, DisplayName
   ```
   External users (guests) must already be invited before you can grant them SharePoint access.

2. **Check for inheritance blocking the permission change:**
   - If you grant access at the site level, a list with broken inheritance (unique permissions) will NOT inherit that change
   - You must grant access at the specific item/list level if unique permissions are set

3. **Verify correct principal ID format in REST calls:**
   - SharePoint REST API expects `i:0#.f|membership|<UPN>` format for login names
   - Graph API expects the user's Entra Object ID
   - Mixing formats causes silent failures or wrong principal binding

4. **Check if the flow is running under the correct connection:**
   - In the flow designer, click each SharePoint action > confirm the connection shown matches the intended service account
   - If the connection is "per user" and the trigger user is different from the one tested, permissions may differ

---

### Phase 3 — External Sharing / Guest Access Failures

1. **Check if B2B Collaboration is restricted in Entra ID:**
   ```powershell
   Connect-MgGraph -Scopes "Policy.Read.All"
   Get-MgPolicyCrossTenantAccessPolicyDefault | Select-Object -ExpandProperty B2BCollaborationInbound
   ```
   If `UsersAllowedToInvite` is restricted, the flow can't invite guests even with correct SharePoint settings.

2. **Check if the domain being invited is on the allowlist/blocklist:**
   Entra ID > External Identities > External collaboration settings > Collaboration restrictions

3. **If guest invite email sent but user can't access:**
   - Confirm the user accepted the invitation (status in Entra ID > Users > Guest users)
   - Check that the site's sharing level allows "New and existing guests" not just "Existing guests only"

---

### Phase 4 — Permission Scope Creep / Audit Issues

1. **Identify items with unique permissions (potential scope creep):**
   ```powershell
   Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<site>" -Interactive
   $items = Get-PnPListItem -List "<ListName>" -Fields "HasUniqueRoleAssignments"
   $items | Where-Object {$_["HasUniqueRoleAssignments"] -eq $true} | ForEach-Object {
       Write-Host "Item ID $($_.Id) has unique permissions"
   }
   ```

2. **Reset inheritance to clean up unique permissions:**
   ```powershell
   # Resets a specific list item to inherit from parent
   Set-PnPListItemPermission -List "<ListName>" -Identity <ItemId> -InheritPermissions
   ```

3. **Export a full permission report for a site:**
   See `M365/SharePoint-OneDrive/Scripts/Get-SharePointSiteReport.ps1` for a comprehensive audit export.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Grant Site Member Access via Power Automate HTTP Action</summary>

```json
// Power Automate — "Send an HTTP request to SharePoint" action
// Method: POST
// Uri: _api/web/roleassignments/addroleassignment(principalid=<USER_ID>,roledefid=1073741827)
// This grants "Contribute" (Edit) role to a SharePoint user principal

// Step 1: Get the principal ID of the user
// GET _api/web/siteusers/getbyemail('<UPN>')
// Response: { "d": { "Id": 12 } }  ← use this integer ID

// Step 2: Grant the role
// POST _api/web/roleassignments/addroleassignment(principalid=12,roledefid=1073741827)
// Headers: X-RequestDigest: <digest from /_api/contextinfo>
//          Accept: application/json;odata=nometadata
//          Content-Type: application/json

// PowerShell equivalent using PnP:
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<site>" -Interactive
Set-PnPWebPermission -User "<UPN>" -AddRole "Contribute"
```

**Rollback:** Replace `addroleassignment` with `removeroleassignment` using the same parameters.

</details>

<details><summary>Playbook 2 — Break Inheritance and Set Unique Permissions on a List Item</summary>

```powershell
# Using PnP PowerShell — equivalent to what a Power Automate REST call would do
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<site>" -Interactive

$listName = "<ListName>"
$itemId   = <ItemId>
$userUPN  = "<UPN>"

# Break inheritance (copy existing permissions, remove inherited ones)
Set-PnPListItemPermission -List $listName -Identity $itemId -BreakRoleInheritance -CopyRoleAssignments

# Grant specific role on the item only
Set-PnPListItemPermission -List $listName -Identity $itemId -User $userUPN -AddRole "Read"

Write-Host "Unique permissions set on item $itemId" -ForegroundColor Green
```

**Rollback — restore inheritance:**
```powershell
Set-PnPListItemPermission -List $listName -Identity $itemId -InheritPermissions
```

</details>

<details><summary>Playbook 3 — Revoke All User Access from a Site</summary>

```powershell
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<site>" -Interactive

$userToRemove = "<UPN>"

# Remove from all SharePoint groups on the site
Get-PnPGroup | ForEach-Object {
    $group = $_
    $members = Get-PnPGroupMember -Group $group.Title
    if ($members | Where-Object {$_.LoginName -like "*$userToRemove*"}) {
        Remove-PnPGroupMember -Group $group.Title -LoginName $userToRemove
        Write-Host "Removed from group: $($group.Title)" -ForegroundColor Yellow
    }
}

# Remove any direct role assignments
$web = Get-PnPWeb -Includes RoleAssignments
$web.Context.Load($web.RoleAssignments)
$web.Context.ExecuteQuery()

$principal = Get-PnPUser -Identity $userToRemove
$web.RoleAssignments | Where-Object {$_.PrincipalId -eq $principal.Id} | ForEach-Object {
    $_.DeleteObject()
}
$web.Context.ExecuteQuery()

Write-Host "All role assignments removed for $userToRemove" -ForegroundColor Green
```

</details>

<details><summary>Playbook 4 — Invite External User and Grant Access via Flow</summary>

```powershell
# Step 1: Invite guest via Graph API (or use Entra ID > Users > Invite)
Connect-MgGraph -Scopes "User.Invite.All"

$invitation = New-MgInvitation -InvitedUserEmailAddress "<external@domain.com>" `
    -InviteRedirectUrl "https://<tenant>.sharepoint.com/sites/<site>" `
    -SendInvitationMessage:$true `
    -InvitedUserDisplayName "External Collaborator"

Write-Host "Invitation sent. Guest Object ID: $($invitation.InvitedUser.Id)"

# Step 2: Wait for acceptance, then grant SharePoint access
# (In a flow, use a delay or a second trigger on user object created)
Start-Sleep -Seconds 30  # In production, use an approval or delay mechanism

Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<site>" -Interactive
Set-PnPWebPermission -User "<external@domain.com>" -AddRole "Read"
Write-Host "External user granted Read access." -ForegroundColor Green
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collect SharePoint permission evidence for a specific site.
.DESCRIPTION
    Exports site permissions, group memberships, unique scopes count, and sharing settings.
    Use before escalating permission anomalies.
.PARAMETER SiteUrl
    Full URL of the target site (e.g. https://contoso.sharepoint.com/sites/hr)
.PARAMETER OutputPath
    Output CSV path (default: C:\Temp\SPPermissions-<date>.csv)
.EXAMPLE
    .\Collect-SPOPermissionEvidence.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/hr"
#>
param(
    [Parameter(Mandatory)][string]$SiteUrl,
    [string]$OutputPath = "C:\Temp\SPPermissions-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Connect-PnPOnline -Url $SiteUrl -Interactive

$report = [System.Collections.Generic.List[PSCustomObject]]::new()

# Site Collection Admins
$scas = Get-PnPSiteCollectionAdmin
foreach ($sca in $scas) {
    $report.Add([PSCustomObject]@{
        Type  = "SCA"
        Name  = $sca.Title
        Login = $sca.LoginName
        Role  = "Site Collection Administrator"
        Source = "Site"
    })
}

# SharePoint Group memberships
$groups = Get-PnPGroup
foreach ($group in $groups) {
    $members = Get-PnPGroupMember -Group $group.Title
    foreach ($member in $members) {
        $report.Add([PSCustomObject]@{
            Type   = "GroupMember"
            Name   = $member.Title
            Login  = $member.LoginName
            Role   = $group.Title
            Source = "SharePoint Group"
        })
    }
}

# External sharing setting
$site = Get-SPOSite -Identity $SiteUrl -ErrorAction SilentlyContinue
$sharingCap = if ($site) { $site.SharingCapability } else { "N/A (run from SPO admin context)" }

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Cyan
Write-Host "Site: $SiteUrl"
Write-Host "Sharing Capability: $sharingCap"
Write-Host "Total permission entries: $($report.Count)"
Write-Host ""

$report | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "Report saved to: $OutputPath" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|--------------------|
| Add SCA to a site | `Set-SPOUser -Site <url> -LoginName <UPN> -IsSiteCollectionAdmin $true` |
| List SCA accounts | `Get-PnPSiteCollectionAdmin` |
| Check current user is SCA | REST: `/_api/web/currentuser/issiteadmin` |
| List all SharePoint groups | `Get-PnPGroup` |
| Add user to SP group | `Add-PnPGroupMember -Group "<GroupName>" -LoginName "<UPN>"` |
| Remove user from SP group | `Remove-PnPGroupMember -Group "<GroupName>" -LoginName "<UPN>"` |
| Grant site-level role | `Set-PnPWebPermission -User <UPN> -AddRole "Contribute"` |
| Check item unique permissions | `(Get-PnPListItem -List "<List>" -Id <Id>).HasUniqueRoleAssignments` |
| Break list inheritance | `Set-PnPList -Identity "<List>" -BreakRoleInheritance` |
| Restore list inheritance | REST: `/_api/web/lists/getbytitle('<list>')/resetroleinheritance` |
| List role definitions | `Get-PnPRoleDefinition \| Select Name, Id` |
| Check tenant sharing level | `Get-SPOTenant \| Select SharingCapability` |
| Check site sharing level | `Get-SPOSite -Identity <url> \| Select SharingCapability` |
| Enumerate guest users | `Get-MgUser -Filter "userType eq 'Guest'"` |

---

## 🎓 Learning Pointers

- **SharePoint permission inheritance is hierarchical and one-directional.** Breaking inheritance creates a local copy of the ACL at that point in the hierarchy. Once broken, changes at the parent no longer propagate down. The 50,000 unique permission scopes per site collection limit is a hard limit — exceeding it prevents any further unique permissions from being added. Monitor this limit in large document libraries. See: [SharePoint permissions and roles](https://learn.microsoft.com/en-us/sharepoint/understanding-permission-levels)

- **Power Automate flows run under the connection context, not the trigger user.** A common mistake is to assume the flow has the same access as the person who triggered it. If the connection was created by a service account, all SharePoint actions run as that account. If you use "Run only users" connections, the runtime context may differ from what was tested. See: [Manage connections in Power Automate](https://learn.microsoft.com/en-us/power-automate/add-manage-connections)

- **The X-RequestDigest header is required for all POST operations against the SharePoint REST API.** When using Power Automate's "Send an HTTP request to SharePoint" action, the connector handles this automatically — but when building your own HTTP actions against `/_api/`, you must first call `/_api/contextinfo` to get a fresh digest. Digests expire after 30 minutes. See: [SharePoint REST API basics](https://learn.microsoft.com/en-us/sharepoint/dev/sp-add-ins/complete-basic-operations-using-sharepoint-rest-endpoints)

- **`Sites.FullControl.All` is a powerful Graph permission — prefer `Sites.Selected`.** For production flows using app registrations, request `Sites.Selected` instead of `Sites.FullControl.All`. With `Sites.Selected`, a SharePoint Admin must explicitly grant the app access to each specific site, following least-privilege. See: [Use Sites.Selected for app-only access](https://learn.microsoft.com/en-us/sharepoint/dev/solution-guidance/security-apponly-azuread)

- **External users must accept their invitation before they can be added to SharePoint groups.** A common automation failure: the flow invites a guest and immediately tries to set their SharePoint permissions, but the user object isn't fully provisioned until invitation acceptance. Build in a delay or use a separate trigger (e.g., on user created/updated in Entra ID) to handle the async gap.

- **MFA-exempt Conditional Access for service accounts should use Named Locations or device-based conditions, not just account exclusion.** Excluding a service account from all MFA globally creates an attack vector. Instead, create a CA policy that requires the service account to authenticate only from the specific IP range of your automation infrastructure or require a compliant device. See: [Conditional Access service account best practices](https://learn.microsoft.com/en-us/entra/identity/conditional-access/howto-conditional-access-policy-all-users-mfa)
