# SharePoint & OneDrive Permissions — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**Covers:**
- SharePoint Online site, library, folder, and item-level permissions
- OneDrive for Business sharing (internal and external)
- M365 Groups and Teams-connected site permissions
- Sharing links (Anyone, People in org, Specific people)
- External sharing settings at tenant and site level
- Broken inheritance and unique permissions forensics

**Does not cover:**
- SharePoint Server (on-premises) permissions
- SharePoint Embedded / VIVA Connections
- Power Pages (formerly Power Apps Portals)

**Assumed role:** SharePoint Administrator or Global Administrator; PnP PowerShell and/or SPO Management Shell installed.

---

## How It Works

<details><summary>Full architecture</summary>

### Permission Model Layers

SharePoint Online uses a layered permission model. Each layer can override or restrict the layer below it.

```
LAYER 1: Tenant-level sharing settings
  (Entra admin center / SharePoint admin center)
  Controls: Who can share at all; external sharing enabled/disabled
       │ enforced down through
       ▼
LAYER 2: Site Collection level
  (Site settings → Permissions, or Admin Center per-site settings)
  Controls: Site members, owners, visitors; external sharing cap for site
       │ inherited by default
       ▼
LAYER 3: Library / List level
  (Library settings → Permissions)
  Controls: Unique permissions break from site collection if set
       │ inherited by default
       ▼
LAYER 4: Folder level
  (Folder → Manage access)
  Controls: Can have unique permissions if inheritance broken
       │ inherited by default
       ▼
LAYER 5: Item / File level
  (File → Manage access)
  Controls: Finest grain; each file can have unique permissions
```

**Inheritance:** By default, libraries inherit from the site, folders from the library, items from the folder. When you "break inheritance," a copy of the parent's permission set is made and the link to the parent is severed. Changes to the parent no longer flow down.

**Why this causes problems:** Broken inheritance (unique permissions) at scale — especially auto-created by sharing links — creates thousands of unique permission objects, which:
- Degrades portal performance
- Makes permission auditing nearly impossible
- Can trigger SharePoint throttling on the content DB

### Permission Levels (Built-in)

| Level | What it allows |
|-------|---------------|
| Full Control | All operations including permission management |
| Design | Edit pages, layouts, style sheets; can approve content |
| Edit | Add/edit/delete items and documents |
| Contribute | Add/edit/delete items; cannot delete lists |
| Read | View-only |
| Limited Access | System-generated; allows access to a specific item in a library without seeing the library |
| View Only | View pages/items but cannot download (IRM-enforced) |

**Limited Access** is automatically assigned when a user is given access to a single item in a library. The user needs "Limited Access" at the site level to navigate to the item, but cannot see the rest of the library.

### Sharing Links

| Link type | Who can use | Breaks inheritance? | Counted in permission objects? |
|-----------|------------|---------------------|-------------------------------|
| Anyone link | Any unauthenticated user | Yes | No (link-based, not ACL) |
| People in org | Any authenticated org user | Yes | No |
| Specific people | Named internal/external users | Yes | Yes |
| Direct access | Named users added directly | Yes | Yes |

"Anyone" and "People in org" links do NOT create ACL entries — they create a sharing link token. Access is revoked by deleting the link. "Specific people" and "Direct access" DO create ACL entries (role assignments) on the item.

### M365 Groups / Teams Sites

Team sites created by M365 Groups or Teams have a special permission structure:
- **Owners** = Site owners + M365 Group owners
- **Members** = Site members + M365 Group members
- **Visitors** = Site visitors (not part of the M365 Group)

**Critical:** If you add a user directly to the SharePoint site's "Members" group without adding them to the M365 Group, they can access the site but NOT the Teams channel, Planner, or Group mailbox. This is a common support ticket source.

</details>

---

## Dependency Stack

```
[User Access Request]
      │
      ▼
[Entra ID Authentication]
  - User must exist in tenant (member or guest)
  - Guest must have accepted invitation (account state: Active)
      │
      ▼
[Tenant External Sharing Policy]
  (SharePoint Admin Center → Policies → Sharing)
  - Sets the ceiling: can't share externally if tenant says "Only people in org"
      │
      ▼
[Site Collection External Sharing Setting]
  - Can only be equal to or more restrictive than tenant setting
      │
      ▼
[Site Permission Groups / Unique Permissions]
  - Site Owners, Members, Visitors groups
  - Or custom groups
      │
      ▼
[Library / List Permissions]
  - Inherits from site, or has unique permissions
      │
      ▼
[Folder / Item Permissions]
  - Inherits from library, or has unique permissions
      │
      ▼
[Conditional Access Policies]
  - Session controls (download restriction, browser-only for unmanaged devices)
  - Can block access even if SharePoint grants it
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "You need to request access" | User not in any permission group; request access email sent to owner | Check user's direct and group memberships on site |
| User can see site but not a specific file | Unique permissions on file; Limited Access at site level | Check item-level permissions |
| External user gets "Your organization's policies don't allow sharing" | External sharing disabled at tenant or site level | SharePoint Admin Center → Sites → sharing settings |
| Guest can't accept invitation | Invitation expired (30 days); guest email address changed | Re-send invitation; check B2B redemption state |
| Owner can't manage permissions | Another admin removed them from Owners group | Re-add to Owners group via admin center or PnP |
| "Access denied" after Teams membership | User added to Teams but SharePoint provisioning delayed | Wait 15 min; check M365 Group membership |
| Sharing link sends but recipient gets access denied | Link shared with wrong email; external sharing disabled after link created | Re-check sharing settings; regenerate link |
| Performance degraded on large library | Thousands of unique permissions (broken inheritance at item level) | Count unique permissions; consolidate |
| Site owner added user but can't find in "People and Groups" | User is a guest not yet redeemed | Check guest redemption state in Entra ID |
| Can share but recipient can't download | Conditional Access session policy for unmanaged devices | Check CA policies for SPO app |

---

## Validation Steps

### 1. Check Tenant-Level External Sharing Setting
```powershell
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com

$tenantSettings = Get-SPOTenant | Select-Object SharingCapability, DefaultSharingLinkType,
    RequireAnonymousLinksExpireInDays, DefaultLinkPermission, ExternalServicesEnabled
$tenantSettings
```
**Good:** `SharingCapability` is `ExternalUserSharingOnly` or `ExistingExternalUserSharingOnly` for managed tenants  
**Bad:** `Disabled` — external sharing completely off (check if this is intentional)

### 2. Check Site-Level Sharing Setting
```powershell
Get-SPOSite -Identity https://<tenant>.sharepoint.com/sites/<sitename> |
    Select-Object Url, SharingCapability, ExternalUserExpirationInDays, LimitedAccessFileType
```
**Good:** Matches or is more restrictive than tenant setting  
**Bad:** `SharingCapability = Disabled` when you expect external sharing — site-level override

### 3. Enumerate Site Permission Groups
```powershell
Connect-PnPOnline -Url https://<tenant>.sharepoint.com/sites/<sitename> -Interactive

Get-PnPGroup | ForEach-Object {
    $group = $_
    $members = Get-PnPGroupMember -Group $group.Title
    [PSCustomObject]@{
        GroupTitle = $group.Title
        Role       = $group.Roles -join ', '
        MemberCount = $members.Count
        Members    = ($members | Select-Object -ExpandProperty LoginName) -join '; '
    }
} | Format-Table -Wrap
```

### 4. Check a Specific User's Effective Permissions
```powershell
Connect-PnPOnline -Url https://<tenant>.sharepoint.com/sites/<sitename> -Interactive

# Check what a specific user can do on the site root
$user = Get-PnPUser | Where-Object Email -eq "<user@domain.com>"
Get-PnPUserEffectivePermissions -User $user.LoginName
```

### 5. Find All Unique Permissions (Broken Inheritance) in a Site
```powershell
Connect-PnPOnline -Url https://<tenant>.sharepoint.com/sites/<sitename> -Interactive

# Count items with unique permissions — can be slow on large sites
$items = Get-PnPListItem -List "Documents" -Fields "Title","HasUniqueRoleAssignments" -PageSize 500
$unique = $items | Where-Object { $_["HasUniqueRoleAssignments"] -eq $true }
Write-Host "Items with unique permissions: $($unique.Count) of $($items.Count)"
```
**Good:** Low number (single digits) — intentional unique permissions only  
**Bad:** Hundreds/thousands — sharing at item level has created massive permission fragmentation

### 6. Check Guest/External User Redemption State
```powershell
# Check if guest has redeemed their invitation
Connect-MgGraph -Scopes "User.Read.All"

Get-MgUser -Filter "userType eq 'Guest'" -All |
    Where-Object { $_.Mail -like "*<externaldomain>*" } |
    Select-Object DisplayName, Mail, ExternalUserState, ExternalUserStateChangeDateTime, AccountEnabled
```
**Good:** `ExternalUserState = Accepted`, `AccountEnabled = True`  
**Bad:** `ExternalUserState = PendingAcceptance` — invitation not yet redeemed (resend needed); `AccountEnabled = False` — account blocked

### 7. Verify M365 Group Membership vs Site Membership
```powershell
Connect-MgGraph -Scopes "GroupMember.Read.All","Sites.Read.All"

# Get M365 Group for the team site
$groupId = "<m365GroupId>"

# M365 Group members
$groupMembers = Get-MgGroupMember -GroupId $groupId -All |
    Select-Object -ExpandProperty AdditionalProperties |
    Select-Object displayName, userPrincipalName

# SharePoint site members (via PnP)
Connect-PnPOnline -Url https://<tenant>.sharepoint.com/sites/<sitename> -Interactive
$siteMembers = Get-PnPGroupMember -Group "<siteName> Members"

Write-Host "M365 Group members: $($groupMembers.Count)"
Write-Host "SharePoint site members: $($siteMembers.Count)"
```

---

## Troubleshooting Steps by Phase

### Phase 1: User Can't Access Site at All

1. Verify user exists in Entra ID and account is enabled
2. Check if site requires group membership (M365 Group-connected site) vs direct assignment
3. In SharePoint Admin Center → Sites → select site → Membership tab: confirm user is listed
4. If site is private (Teams site): add user via Teams owner in Teams app, then wait 5–15 min
5. If external: check tenant and site sharing settings (Steps 1–2), check guest redemption (Step 6)
6. Check CA policies for SharePoint — user may be blocked due to device compliance

### Phase 2: User Can Access Site but Not a Specific Item

1. The file/folder likely has unique permissions (inheritance broken)
2. Navigate to the item → Manage access (or "i" panel) → Advanced settings
3. Check if "This item has unique permissions"
4. Review who has access to the item specifically
5. Either:
   - Add the user to the item's permissions directly
   - Restore inheritance: Item → Manage access → Stop sharing → or via PnP:
     ```powershell
     Set-PnPListItemPermission -List "Documents" -Identity <itemId> -InheritPermissions
     ```

### Phase 3: External Sharing Blocked

1. Identify the most restrictive layer blocking sharing:
   ```powershell
   # Check tenant
   Get-SPOTenant | Select-Object SharingCapability
   # Check site
   Get-SPOSite -Identity <siteUrl> | Select-Object SharingCapability
   ```
2. If tenant is set to `Disabled`: escalate — enabling external sharing is a tenant-wide security decision
3. If site is more restrictive than tenant: 
   ```powershell
   Set-SPOSite -Identity <siteUrl> -SharingCapability ExternalUserSharingOnly
   ```
4. Check if specific domain is blocked:
   ```powershell
   Get-SPOTenant | Select-Object SharingAllowedDomainList, SharingBlockedDomainList
   ```

### Phase 4: Permission Sprawl / Performance Issues

1. Identify scope of broken inheritance (Step 5 above)
2. For libraries with many uniquely-permissioned items, consider:
   - Moving sensitive items to a dedicated library (manage permissions at library level)
   - Using sensitivity labels to control access rather than SharePoint permissions
   - Resetting all item permissions to inherit from parent:
     ```powershell
     # CAUTION: this removes all custom item permissions
     Connect-PnPOnline -Url <siteUrl> -Interactive
     $items = Get-PnPListItem -List "Documents" -PageSize 500
     foreach ($item in $items) {
         if ($item["HasUniqueRoleAssignments"]) {
             Set-PnPListItemPermission -List "Documents" -Identity $item.Id -InheritPermissions
             Write-Host "Reset: $($item['FileLeafRef'])"
         }
     }
     ```

---

## Remediation Playbooks

<details><summary>Playbook 1 — Add External User to a Site</summary>

```powershell
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com

# Step 1: Verify tenant allows external sharing
$tenant = Get-SPOTenant
if ($tenant.SharingCapability -eq 'Disabled') {
    Write-Warning "External sharing is disabled at tenant level. Cannot proceed."
    return
}

# Step 2: Verify site allows external sharing
$site = Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>"
if ($site.SharingCapability -eq 'Disabled') {
    Write-Warning "External sharing is disabled for this site."
    # To enable (requires deliberate decision):
    # Set-SPOSite -Identity $site.Url -SharingCapability ExternalUserSharingOnly
    return
}

# Step 3: Invite external user (via PnP for direct permission assignment)
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<sitename>" -Interactive

# Add to the appropriate SharePoint group
Add-PnPGroupMember -LoginName "<external@domain.com>" -Group "<sitename> Visitors"
# OR for direct role assignment:
# Set-PnPWebPermission -User "<external@domain.com>" -AddRole "Read"

Write-Host "External user invited. They will receive an email to redeem the invitation."
Write-Host "Redemption may take up to 24h to fully propagate."
```

**Rollback:**
```powershell
Remove-PnPGroupMember -LoginName "<external@domain.com>" -Group "<sitename> Visitors"
```

</details>

<details><summary>Playbook 2 — Audit Sharing Links on a Site</summary>

```powershell
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com

# Get all sharing links for a site
$siteUrl = "https://<tenant>.sharepoint.com/sites/<sitename>"

$sharingLinks = Get-SPOSiteFileVersionBatchDeleteJobProgress  # Not the right cmdlet

# Use PnP for sharing link audit
Connect-PnPOnline -Url $siteUrl -Interactive

# Get all shared items
$sharedItems = Get-PnPListItem -List "Documents" -Fields "Title","SharedWithUsers","SMTotalFileStreamSize" -PageSize 500 |
    Where-Object { $_["SharedWithUsers"] -ne $null -and $_["SharedWithUsers"] -ne "" }

$report = foreach ($item in $sharedItems) {
    [PSCustomObject]@{
        FileName = $item["FileLeafRef"]
        SharedWith = $item["SharedWithUsers"]
        UniquePerms = $item["HasUniqueRoleAssignments"]
    }
}

$reportPath = "$env:TEMP\SharingLinkAudit_$(Get-Date -Format 'yyyyMMdd').csv"
$report | Export-Csv $reportPath -NoTypeInformation
Write-Host "Report saved to $reportPath"
```

</details>

<details><summary>Playbook 3 — Reset Site Permissions to Default Groups</summary>

**Scenario:** Site permissions have become complex; want to reset to clean Owners/Members/Visitors model.

```powershell
# CAUTION: This removes all custom permission groups and unique permissions
# Always export the current state first

Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<sitename>" -Interactive

# Export current permissions first
$currentGroups = Get-PnPGroup | ForEach-Object {
    $g = $_
    $members = Get-PnPGroupMember -Group $g.Title
    [PSCustomObject]@{
        Group = $g.Title
        Members = ($members | Select-Object -ExpandProperty Email) -join '; '
    }
}
$currentGroups | Export-Csv "$env:TEMP\PermissionsBackup_$(Get-Date -Format 'yyyyMMdd').csv" -NoTypeInformation
Write-Host "Backup saved. Review before proceeding."
Write-Host "Current groups:"
$currentGroups | Format-Table

# Review the backup, then to restore inheritance on all subsites:
# Set-PnPSubWebs -Property NoCrawl -Value $false  # example, adjust as needed

# To add a user to the standard Owners group:
Add-PnPGroupMember -LoginName "<user@domain.com>" -Group "<sitename> Owners"
```

</details>

<details><summary>Playbook 4 — Fix "Access Denied" for M365 Group Connected Site</summary>

**Scenario:** User was added to Teams but still gets access denied on the SharePoint site.

```powershell
# Step 1: Verify M365 Group membership
Connect-MgGraph -Scopes "GroupMember.Read.All","GroupMember.ReadWrite.All"

$groupId = "<m365GroupId>"  # Find in Teams admin or Entra admin center
$userId = "<userId>"  # From Entra ID

# Check membership
$member = Get-MgGroupMember -GroupId $groupId -All | Where-Object Id -eq $userId
if ($null -eq $member) {
    Write-Warning "User is NOT in the M365 Group. Adding now..."
    New-MgGroupMember -GroupId $groupId -DirectoryObjectId $userId
    Write-Host "Added. Allow 5-15 minutes for SharePoint to sync."
} else {
    Write-Host "User IS in the M365 Group. Checking SharePoint directly..."
    # May be a timing issue — wait and retry, or check SPO directly
}

# Step 2: If still failing after 15 min, directly check SPO membership
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
$siteUser = Get-SPOUser -Site "https://<tenant>.sharepoint.com/sites/<sitename>" -LoginName "<user@domain.com>" -ErrorAction SilentlyContinue
if ($null -eq $siteUser) {
    Write-Warning "User not found in SPO — M365 Group sync may be pending or broken"
    # Force via PnP:
    Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<sitename>" -Interactive
    Add-PnPGroupMember -LoginName "<user@domain.com>" -Group "<sitename> Members"
}
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects SharePoint permission diagnostics for a specific user and site
.PARAMETER SiteUrl   Full URL of the SharePoint site
.PARAMETER UserEmail Email address of the affected user
.NOTES     Requires PnP PowerShell and SPO Management Shell
           Run as SharePoint Administrator
#>
param(
    [Parameter(Mandatory)][string]$SiteUrl,
    [Parameter(Mandatory)][string]$UserEmail
)

$outFile = "$env:TEMP\SPOPermDiag_$(Split-Path $SiteUrl -Leaf)_$(Get-Date -Format 'yyyyMMdd_HHmm').txt"

function Write-Section {
    param([string]$Title)
    "`n" + ("="*60) + "`n$Title`n" + ("="*60) | Tee-Object -FilePath $outFile -Append | Write-Host -ForegroundColor Cyan
}

"SharePoint Permission Diagnostics — $SiteUrl — User: $UserEmail — $(Get-Date)" |
    Tee-Object -FilePath $outFile | Write-Host

Connect-SPOService -Url ($SiteUrl -replace '/sites/.*', '-admin.sharepoint.com')
Connect-PnPOnline -Url $SiteUrl -Interactive
Connect-MgGraph -Scopes "User.Read.All","GroupMember.Read.All" -NoWelcome

Write-Section "TENANT SHARING SETTINGS"
Get-SPOTenant | Select-Object SharingCapability, DefaultSharingLinkType, RequireAnonymousLinksExpireInDays |
    Tee-Object -FilePath $outFile -Append | Format-List

Write-Section "SITE SETTINGS"
Get-SPOSite -Identity $SiteUrl | Select-Object Url, SharingCapability, SensitivityLabel, IsHubSite, LockState |
    Tee-Object -FilePath $outFile -Append | Format-List

Write-Section "USER ENTRA ID STATE"
$userObj = Get-MgUser -Filter "mail eq '$UserEmail'" -ErrorAction SilentlyContinue
if ($userObj) {
    $userObj | Select-Object DisplayName, UserPrincipalName, UserType, AccountEnabled, ExternalUserState |
        Tee-Object -FilePath $outFile -Append | Format-List
} else {
    "User not found in Entra ID: $UserEmail" | Tee-Object -FilePath $outFile -Append | Write-Host -ForegroundColor Red
}

Write-Section "USER SPO MEMBERSHIP"
try {
    Get-SPOUser -Site $SiteUrl -LoginName $UserEmail |
        Select-Object LoginName, DisplayName, Groups, IsSiteAdmin |
        Tee-Object -FilePath $outFile -Append | Format-List
} catch {
    "User not found in site: $_" | Tee-Object -FilePath $outFile -Append | Write-Warning
}

Write-Section "SITE GROUPS AND MEMBERSHIP"
Get-PnPGroup | ForEach-Object {
    $members = Get-PnPGroupMember -Group $_.Title | Select-Object -ExpandProperty Email
    [PSCustomObject]@{
        Group = $_.Title
        MemberCount = $members.Count
        HasTargetUser = ($members -contains $UserEmail)
    }
} | Tee-Object -FilePath $outFile -Append | Format-Table

Write-Section "USER EFFECTIVE PERMISSIONS"
try {
    $pnpUser = Get-PnPUser | Where-Object Email -eq $UserEmail
    if ($pnpUser) {
        Get-PnPUserEffectivePermissions -User $pnpUser.LoginName |
            Tee-Object -FilePath $outFile -Append | Format-List
    }
} catch {
    "Could not retrieve effective permissions: $_" | Tee-Object -FilePath $outFile -Append | Write-Warning
}

Write-Host "`nDiagnostic file saved to: $outFile" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check tenant sharing policy | `Get-SPOTenant \| Select SharingCapability` |
| Check site sharing policy | `Get-SPOSite -Identity <url> \| Select SharingCapability` |
| Set site sharing policy | `Set-SPOSite -Identity <url> -SharingCapability ExternalUserSharingOnly` |
| List site groups | `Get-PnPGroup` |
| List group members | `Get-PnPGroupMember -Group "<groupName>"` |
| Add user to group | `Add-PnPGroupMember -LoginName <upn> -Group "<groupName>"` |
| Remove user from group | `Remove-PnPGroupMember -LoginName <upn> -Group "<groupName>"` |
| Check user's SPO state | `Get-SPOUser -Site <url> -LoginName <upn>` |
| Get user effective permissions | `Get-PnPUserEffectivePermissions -User <loginName>` |
| Reset item to inherit | `Set-PnPListItemPermission -List <list> -Identity <id> -InheritPermissions` |
| Check guest redemption | `Get-MgUser -Filter "mail eq '<email>'" \| Select ExternalUserState` |
| Block external domain | `Set-SPOTenant -SharingBlockedDomainList "<domain.com>"` |
| Get sharing links on item | `Get-PnPFileSharingLink -FileUrl <url>` |
| Remove sharing link | `Remove-PnPFileSharingLink -FileUrl <url> -Identity <linkId>` |

---

## 🎓 Learning Pointers

- **The tenant sharing setting is the hard ceiling.** Site admins cannot enable sharing types that the tenant admin has disabled. If users report "sharing is blocked," always check the tenant level first — it is frequently the culprit and a site-level fix will never work. Document your tenant sharing policy and who owns changes to it.  
  → [MS Docs: Manage sharing in SharePoint](https://learn.microsoft.com/en-us/sharepoint/turn-external-sharing-on-or-off)

- **"Limited Access" is not a permission you assign — it's a system artifact.** When a user is given access to a single item, SharePoint automatically assigns "Limited Access" at the site level so the user can navigate to the item. You cannot manage Limited Access entries directly in the UI. This is normal and expected, but can cause confusion when reviewing the site's user list.  
  → [MS Docs: Limited Access permission level](https://learn.microsoft.com/en-us/sharepoint/understanding-permission-levels)

- **M365 Group membership ≠ SharePoint site membership are synced, not identical.** Adding someone to Teams adds them to the M365 Group, which in turn syncs to the SharePoint site's Members group. However, you can add users directly to the SharePoint site without adding them to the M365 Group. These users get SharePoint access but no access to the Group mailbox, Teams channels, or Planner. Always prefer adding users through Teams/Group to keep access consistent.  
  → [MS Docs: Managing access to group-connected team sites](https://learn.microsoft.com/en-us/sharepoint/manage-team-sites-in-new-sharepoint-admin-center)

- **Sharing link sprawl is the most common cause of permission complexity at scale.** Every time a user clicks "Copy link" and selects "Specific people," SharePoint breaks inheritance on that item and creates a new role assignment. In active sites, this can produce thousands of unique permission entries in weeks. Mitigate by setting the default sharing link to "People with existing access" or "Organization" at the tenant level.  
  → [MS Docs: Change the default sharing link](https://learn.microsoft.com/en-us/sharepoint/change-default-sharing-link)

- **Conditional Access session controls can restrict download without blocking access.** If users report they can see files but not download them, the cause is often a CA policy with "Use app-enforced restrictions" or a custom session control targeting SharePoint for unmanaged devices. Check CA policies for the SharePoint Online app — this is intentional security hardening for BYOD devices and should be documented clearly.  
  → [MS Docs: Control access from unmanaged devices](https://learn.microsoft.com/en-us/sharepoint/control-access-from-unmanaged-devices)

- **PnP PowerShell is far more capable for permission management than the built-in SPO module.** The SPO module (`Connect-SPOService`) covers admin-level site operations, but for per-library, per-item, or group-level work, PnP PowerShell (`Connect-PnPOnline`) is essential. Install it with `Install-Module PnP.PowerShell` and use `Connect-PnPOnline -Interactive` for MFA-enabled admin accounts.  
  → [PnP PowerShell docs](https://pnp.github.io/powershell/)
