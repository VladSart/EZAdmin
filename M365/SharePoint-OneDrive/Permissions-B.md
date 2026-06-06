# SharePoint Online Permissions — Hotfix Runbook (Mode B: Ops)
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

```powershell
# Connect to SharePoint Online (requires SharePoint Admin or Global Admin)
Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com

# 1. Check user's access to the specific site
Get-SPOUser -Site https://<tenantName>.sharepoint.com/sites/<siteName> -LoginName <UPN> -ErrorAction SilentlyContinue

# 2. Check site-level sharing capability
Get-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> | Select-Object Url, SharingCapability, ExternalUserExpirationEnabled, DenyAddAndCustomizePages

# 3. Check tenant-wide sharing settings
Get-SPOTenant | Select-Object SharingCapability, RequireAcceptingAccountMatchInvitedAccount, DefaultSharingLinkType, PreventExternalUsersFromResharing

# 4. Check if site is part of a hub with inherited policies
Get-SPOHubSite | Where-Object {$_.SiteUrl -like "*<siteName>*"}

# 5. Check site collection admins
Get-SPOSiteAdmins -Identity https://<tenantName>.sharepoint.com/sites/<siteName> -ErrorAction SilentlyContinue
```

**Note:** `Connect-SPOService` may require the `Microsoft.Online.SharePoint.PowerShell` module:
```powershell
Install-Module -Name Microsoft.Online.SharePoint.PowerShell -Force -AllowClobber
```

**Interpretation Table:**

| Symptom | Likely Cause | Go To |
|---------|-------------|-------|
| User not in `Get-SPOUser` output | Not added to site | Fix 1 |
| User in site but "Access Denied" | Broken permission inheritance | Fix 2 |
| External user can't access shared link | Tenant or site sharing blocked | Fix 3 |
| Sharing link expired or invalid | Link expiry policy | Fix 3 |
| Groups showing but access not working | M365 Group membership vs SPO group mismatch | Fix 4 |
| "You need permission to access this site" for everyone | Site locked / read-only | Fix 5 |
| Can't share externally even as admin | Tenant-level external sharing disabled | Fix 3 |

---
## Dependency Cascade

<details><summary>What must be true for SharePoint permissions to work</summary>

```
Entra ID user exists and not blocked
    └── Tenant external sharing policy allows the sharing type (if external user)
        └── Site collection external sharing setting ≤ tenant setting
            └── User added to correct SharePoint group OR M365 Group
                └── Permission inheritance not broken at library/folder level
                    └── Conditional Access not blocking SharePoint access
                        └── User accepts sharing invitation (external only)
                            └── ACCESS GRANTED
```
</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm user can authenticate to Microsoft 365**
Verify the user can log in at https://office.com. If auth fails entirely → EntraID issue, not permissions.

**Step 2 — Check if user has any access to the site**
```powershell
$siteUrl = "https://<tenantName>.sharepoint.com/sites/<siteName>"
try {
    $user = Get-SPOUser -Site $siteUrl -LoginName <UPN>
    Write-Host "User found. Groups: $($user.Groups -join ', ')"
} catch {
    Write-Host "User NOT found in site. Error: $_" -ForegroundColor Red
}
```

**Step 3 — Check group memberships at site level**
```powershell
Get-SPOSiteGroup -Site $siteUrl | ForEach-Object {
    $group = $_
    Get-SPOUser -Site $siteUrl -Group $group.Title -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{Group=$group.Title; User=$_.LoginName}
    }
} | Where-Object {$_.User -like "*<partialUPN>*"} | Format-Table
```

**Step 4 — Check unique permissions at library/folder level (PnP)**
```powershell
# Requires PnP.PowerShell
# Install-Module PnP.PowerShell -Force
Connect-PnPOnline -Url $siteUrl -Interactive
$list = Get-PnPList -Identity "Documents"
Write-Host "HasUniqueRoleAssignments: $($list.HasUniqueRoleAssignments)"
```
Expected: `HasUniqueRoleAssignments: False` (inherits from site). If `True`, permissions were broken — see Fix 2.

**Step 5 — Check sharing settings match access request**
```powershell
$site = Get-SPOSite -Identity $siteUrl
Write-Host "Site sharing: $($site.SharingCapability)"
$tenant = Get-SPOTenant
Write-Host "Tenant sharing: $($tenant.SharingCapability)"
```
Tenant sharing must be ≥ site sharing. Options in order: `Disabled < ExistingExternalUserSharingOnly < ExternalUserSharingOnly < ExternalUserAndGuestSharing`.

---
## Common Fix Paths

<details><summary>Fix 1 — Add user to SharePoint site</summary>

**Use when:** User simply not added to the site.

```powershell
$siteUrl = "https://<tenantName>.sharepoint.com/sites/<siteName>"

# Add as Member (edit access):
Set-SPOUser -Site $siteUrl -LoginName <UPN> -IsSiteCollectionAdmin $false
Add-SPOUser -Site $siteUrl -LoginName <UPN> -Group "<SiteName> Members"

# Add as Visitor (read-only):
Add-SPOUser -Site $siteUrl -LoginName <UPN> -Group "<SiteName> Visitors"

# Add as Owner:
Add-SPOUser -Site $siteUrl -LoginName <UPN> -Group "<SiteName> Owners"
```

**For M365 Group-connected sites (Teams sites):** Add via the M365 Group instead — SPO membership follows group membership:
```powershell
# Add to M365 group (the underlying group for a Teams site):
Add-UnifiedGroupLinks -Identity <GroupEmailAddress> -LinkType Members -Links <UPN>
```

**Rollback:**
```powershell
Remove-SPOUser -Site $siteUrl -LoginName <UPN>
```
</details>

<details><summary>Fix 2 — Restore broken permission inheritance</summary>

**Use when:** User has site access but gets "Access Denied" at library or folder level due to unique permissions overriding site-level grants.

```powershell
# Using PnP.PowerShell — connect first:
Connect-PnPOnline -Url https://<tenantName>.sharepoint.com/sites/<siteName> -Interactive

# Check if a specific library has unique permissions:
$list = Get-PnPList -Identity "Documents"
Write-Host "Unique permissions: $($list.HasUniqueRoleAssignments)"

# Reset library to inherit from site (removes all unique permissions on the library):
# WARNING: This will remove any custom permissions set on the library
$ctx = Get-PnPContext
$list.ResetRoleInheritance()
$ctx.ExecuteQuery()
Write-Host "Inheritance restored on library"

# For a specific folder:
$folder = Get-PnPFolder -Url "/sites/<siteName>/Shared Documents/<FolderName>"
$folderItem = $folder.ListItemAllFields
$ctx.Load($folderItem)
$ctx.ExecuteQuery()
$folderItem.ResetRoleInheritance()
$ctx.ExecuteQuery()
Write-Host "Inheritance restored on folder"
```

**Rollback:** Unique permissions cannot be automatically restored once inheritance is reset. Document existing unique permissions before running.
```powershell
# Export before resetting — capture all unique permission holders:
Get-PnPListItem -List "Documents" -Fields "FileLeafRef","FileRef" | ForEach-Object {
    $item = $_
    if ($item.FieldValues.HasUniqueRoleAssignments) {
        Write-Host "Unique perms: $($item.FieldValues.FileRef)"
    }
}
```
</details>

<details><summary>Fix 3 — Fix external sharing / sharing link issues</summary>

**Use when:** External user can't access shared link, or sharing option missing for site owners.

```powershell
# Step 1: Check tenant-level external sharing:
$tenant = Get-SPOTenant
Write-Host "Tenant sharing: $($tenant.SharingCapability)"

# Step 2: Check site-level setting (must not be more permissive than tenant):
$site = Get-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName>
Write-Host "Site sharing: $($site.SharingCapability)"

# Step 3: Enable external sharing at site level if blocked:
# Options: Disabled | ExistingExternalUserSharingOnly | ExternalUserSharingOnly | ExternalUserAndGuestSharing
Set-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> -SharingCapability ExternalUserSharingOnly

# Step 4: Check link expiry settings:
Get-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> | Select-Object ExternalUserExpirationEnabled, ExternalUserExpireInDays

# Step 5: If link already sent and expired — resend:
# SharePoint Online web: Open document → Share → Manage Access → Resend

# Step 6: Check if "Anyone" links are blocked:
Get-SPOTenant | Select-Object DefaultSharingLinkType, RequireAnonymousLinksExpireInDays
```

**Rollback:** Revert site sharing capability:
```powershell
Set-SPOSite -Identity <siteUrl> -SharingCapability <originalValue>
```
</details>

<details><summary>Fix 4 — Fix M365 Group vs SharePoint group mismatch</summary>

**Use when:** Teams site shows user as member in Teams but they still get "Access Denied" in SharePoint.

```powershell
# Verify M365 Group membership:
Get-UnifiedGroupLinks -Identity <GroupEmailAddress> -LinkType Members | Select-Object Name, PrimarySmtpAddress

# Force sync of M365 group to SharePoint (sometimes needed after adding members):
# Go to: SharePoint site → Settings → Site permissions → Advanced permission settings
# The group sync runs automatically, but can take up to 24h for large groups

# Check if the SPO site is still connected to the M365 Group:
Get-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> | Select-Object GroupId

# If GroupId is empty, the site was disconnected from the group — requires admin reconnection
```

**If permanent disconnection:** Reconnect via SharePoint Admin Centre → Active Sites → select site → Hub → Reconnect group (if available), or raise with Microsoft Support.
</details>

<details><summary>Fix 5 — Unlock a locked/read-only site</summary>

**Use when:** All users (including admins) get "Access Denied" or the site is in read-only mode.

```powershell
# Check site lock status:
Get-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> | Select-Object Url, LockState, Status

# LockState options:
# Unlock = Normal
# ReadOnly = read-only (often quota exceeded or admin action)
# NoAccess = fully locked

# Unlock:
Set-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> -LockState Unlock

# Check storage quota if locked due to quota:
Get-SPOSite -Identity <siteUrl> | Select-Object StorageUsageCurrent, StorageQuota, StorageWarningLevel
```

**Rollback:** Re-lock with `Set-SPOSite -LockState ReadOnly` or `NoAccess` if the lock was intentional.
</details>

---
## Escalation Evidence

```
SHAREPOINT PERMISSIONS ESCALATION
===================================
Affected URL:       https://<tenantName>.sharepoint.com/sites/<siteName>
Affected user(s):   <UPN(s)>
User type:          [ ] Internal  [ ] External/Guest
Issue:              <description>

Sharing capability:
  Tenant: <value>  Site: <value>

User found in Get-SPOUser:  [ ] Yes  [ ] No
User's SPO groups:          <list or "none">
Library has unique perms:   [ ] Yes  [ ] No
Site LockState:             <Unlock / ReadOnly / NoAccess>
GroupId (M365 connected):   <GUID or empty>

Error message seen by user:
  <exact text or screenshot description>

Steps already tried:
  [ ] Re-added user  [ ] Reset inheritance  [ ] Checked sharing settings  [ ] Checked lock state

Recent changes to site/tenant:
  <any admin changes in last 7 days>
```

---
## 🎓 Learning Pointers

- **M365 Group-connected sites use group membership, not SPO groups** — adding someone to the SPO "Members" group directly on a Teams site may not persist. Always use `Add-UnifiedGroupLinks` for group-connected sites.
- **Tenant sharing ≥ site sharing** — you cannot set a site to `ExternalUserAndGuestSharing` if the tenant is at `ExternalUserSharingOnly`. The most permissive setting is always capped by the tenant.
- **Unique permissions are silent** — there is no warning when a library has broken inheritance. `HasUniqueRoleAssignments` is the only way to check. Use PnP scripts to audit this regularly.
- **Sharing links have four types** — Anyone, People in your org, People with existing access, Specific people. `DefaultSharingLinkType` controls which is pre-selected. "Anyone" links bypass all authentication.
- MS Docs — Manage sharing settings: https://learn.microsoft.com/en-us/sharepoint/turn-external-sharing-on-or-off
- MS Docs — SPO PowerShell reference: https://learn.microsoft.com/en-us/powershell/module/sharepoint-online/
