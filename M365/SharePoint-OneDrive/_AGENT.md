# SharePoint Online & OneDrive — Agent Instructions

## What's in this folder
Runbooks and scripts for SharePoint Online site issues, OneDrive sync problems, and permission management. Covers both end-user-facing issues (sync client) and admin-level problems (site collections, permissions, quota, hub sites).

## Before responding, also check
- `M365/_AGENT.md` — M365-wide triage starting points
- `PowerAutomate/SharePoint/` — if the issue involves flow-triggered permission changes or site provisioning
- `EntraID/` — if the issue involves group membership affecting SharePoint access
- `Security/ConditionalAccess/` — if users can't access SharePoint from specific devices/networks

## Folder contents

| File | What it covers |
|------|---------------|
| `Sync-Issues-B.md` | OneDrive/SharePoint sync client errors — AADSTS, locked files, quota, selective sync |
| `Permissions-B.md` | SharePoint permission inheritance breaks, sharing link failures, external access issues |

## Common entry points

- "OneDrive isn't syncing" → `Sync-Issues-B.md` — check error code first, then Fix 1 (reset sync) or Fix 2 (account mismatch)
- "User can't access a SharePoint site" → `Permissions-B.md` — check if they're in the right group, whether inheritance is broken
- "Sync shows red X / error 0x..." → `Sync-Issues-B.md` — Triage section maps error codes
- "External user got an email but can't access" → `Permissions-B.md` Fix 3 (external sharing)
- "OneDrive storage quota exceeded" → `Sync-Issues-B.md` Fix 4 (quota management)
- "SharePoint sharing link stopped working" → `Permissions-B.md` Fix 2 (link policy)
- "Site collection not showing in admin centre" → `Permissions-B.md` — check deleted sites or misrouted hub

## Key diagnostic commands

```powershell
# Connect to SharePoint Online
Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com

# List all site collections and status
Get-SPOSite -Limit All | Select-Object Url, Status, StorageUsageCurrent, StorageQuota, SharingCapability | Format-Table -AutoSize

# Check a specific site's permissions
Get-SPOSiteGroup -Site https://<tenantName>.sharepoint.com/sites/<siteName> | Format-Table -AutoSize

# Check user's site access
Get-SPOUser -Site https://<tenantName>.sharepoint.com/sites/<siteName> -LoginName <UPN>

# Check tenant-wide sharing settings
Get-SPOTenant | Select-Object SharingCapability, DefaultSharingLinkType, RequireAcceptingAccountMatchInvitedAccount, ExternalServicesEnabled

# Check OneDrive for a specific user
Get-SPOSite -Filter {Url -like "*-my.sharepoint.com/personal*"} -IncludePersonalSite $true | Where-Object {$_.Owner -eq "<UPN>"}
```

## Key dependency chain

```
Entra ID Identity (user/group)
    └── SharePoint Online Tenant (sharing policies, DLP)
        └── Site Collection (owner, quota, external sharing setting)
            └── Hub Site association (navigation, policies)
                └── Subsite / Team Site / Communication Site
                    └── Library / List (item-level permissions)
                        └── Sharing Links (Anyone / Org / Specific people)
                            └── OneDrive Sync Client (local ↔ cloud)
```

## Response format reminder (always 3 layers)

1. **Triage** — identify error code or symptom in 60 seconds
2. **Fix** — targeted remediation with PowerShell, no unnecessary changes
3. **Validate** — confirm fix worked before closing
