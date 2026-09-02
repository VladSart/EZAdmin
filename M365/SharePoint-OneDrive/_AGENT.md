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
| `Sync-Issues-A.md` | Sync client deep dive — sync engine architecture, libraries sync scope, conflict resolution |
| `Permissions-B.md` | SharePoint permission inheritance breaks, sharing link failures, external access issues |
| `Permissions-A.md` | Permission model deep dive — layered inheritance, sharing link types, M365 Group vs. SPO group sync |
| `Migration-B.md` | Migration hotfix — failed migration jobs, throttling, mapping errors |
| `Migration-A.md` | Migration deep dive — SharePoint Migration Tool/Mover architecture, throttling behaviour, permission remapping |
| `Advanced-Management-B.md` | SharePoint Advanced Management (SAM) hotfix — licensing gate errors, RAC not enforcing, RCD not hiding content, site lifecycle notifications not sending, idle sign-out behaviour |
| `Advanced-Management-A.md` | SAM deep dive — RAC/RCD/DAG/Site Lifecycle Management architecture, licensing fork (Copilot licence vs. SAM Plan 1 add-on), dependency stack, remediation playbooks |
| `HubSites-B.md` | Hub site hotfix — association fails/greyed out, navigation not showing, hub-to-hub nesting issues, permission-inheritance misunderstandings |
| `HubSites-A.md` | Hub site deep dive — registration/association mechanics, hub-of-hubs architecture, search scoping, why permissions are never inherited from hub association |
| `Agents-B.md` | Agents in SharePoint hotfix — Agent icon missing (RCD side effect), empty/generic answers, 20-source cap, non-Copilot licensing/pay-as-you-go, org-wide sharing scope, Knowledge Agent scope exclusions |
| `Agents-A.md` | Agents deep dive — ready-made vs. custom vs. Knowledge Agent architecture, licensing paths (Copilot licence vs. pay-as-you-go metered billing), why RCD suppresses agents entirely, Copilot Control System oversight, KnowledgeAgentScope allow-list-via-exclusion caveat |
| `Scripts/Get-SharePointSiteReport.ps1` | Tenant-wide site inventory — storage, quota, sharing, orphaned-owner report |
| `Scripts/Get-SharePointPermissionAudit.ps1` | Site sharing-capability alignment, unique-permission sprawl, M365 Group disconnection, guest redemption audit |
| `Scripts/Get-SharePointMigrationStatus.ps1` | Dual-mode: local SPMT agent/connectivity/log check + destination SPO quota/site-admin check + source pre-scan (oversized files, long paths, bad characters) |
| `Scripts/Get-OneDriveSyncClientHealth.ps1` | Local ODC diagnostic: process/version, Entra join + PRT state, multi-account conflict detection, event log errors, path-length compliance, KFM registry/redirection check |
| `Scripts/Get-SPAdvancedManagementAudit.ps1` | Read-only SAM audit: tenant RAC/RCD delegation flags, per-site RAC group count/enforceability, RCD-on-OneDrive misconfiguration, site lock state, optional DAG report status / idle sign-out / restricted-site-creation checks |
| `Scripts/Get-SPHubSiteAudit.ps1` | Read-only hub structure audit: registration/association inventory, orphan hub detection, tenant limit tracking (2,000 hubs), hub-to-hub nesting depth check, permission-independence snapshot |
| `Scripts/Get-SharePointAgentsAudit.ps1` | Read-only agents audit: tenant Knowledge Agent scope + exclusion-list drift flag, per-site RCD agent-suppression scan, legacy promo opt-in status, optional Copilot licence assignment summary via Graph |

## Common entry points

- "OneDrive isn't syncing" → `Sync-Issues-B.md` — check error code first, then Fix 1 (reset sync) or Fix 2 (account mismatch); run `Scripts/Get-OneDriveSyncClientHealth.ps1` on the endpoint for a full local diagnostic
- "User can't access a SharePoint site" → `Permissions-B.md` — check if they're in the right group, whether inheritance is broken
- "Sync shows red X / error 0x..." → `Sync-Issues-B.md` — Triage section maps error codes
- "External user got an email but can't access" → `Permissions-B.md` Fix 3 (external sharing)
- "OneDrive storage quota exceeded" → `Sync-Issues-B.md` Fix 4 (quota management)
- "SharePoint sharing link stopped working" → `Permissions-B.md` Fix 2 (link policy)
- "Site collection not showing in admin centre" → `Permissions-B.md` — check deleted sites or misrouted hub
- "Audit permission sprawl / broken inheritance across sites" → `Scripts/Get-SharePointPermissionAudit.ps1`
- "Migrating content into SharePoint" → `Migration-B.md` (hotfix) or `Migration-A.md` (architecture)
- "SharePoint Advanced Management license error / RAC or RCD not working" → `Advanced-Management-B.md` — check the exact error text first (licensing vs. propagation delay), then Fix 1-5; run `Scripts/Get-SPAdvancedManagementAudit.ps1` for a full tenant + site posture check
- "Restrict a SharePoint site to specific groups" / "hide a site from Copilot search" → `Advanced-Management-A.md` Playbook 1 (RAC) or Playbook 2 (RCD)
- "Inactive site policy / site went read-only or archived unexpectedly" → `Advanced-Management-A.md` Playbook 3, or `Advanced-Management-B.md` Fix 4
- "Data access governance report stuck / oversharing review" → `Advanced-Management-A.md` Playbook 4
- "Can't associate a site with a hub / option greyed out" → `HubSites-B.md` Fix 1 — check Site Owner rights and hub registration
- "Hub navigation not showing on an associated site" → `HubSites-B.md` Fix 2 — usually a propagation delay (2-4h)
- "Associating with a hub didn't change who can access the site" → `HubSites-B.md` Fix 4 — expected behaviour, hub association never inherits permissions
- "Audit our hub site structure / how many hubs do we have" → `Scripts/Get-SPHubSiteAudit.ps1` for a tenant-wide report with orphan/limit flags
- "The Agent icon disappeared from a site" / "SharePoint agent won't create / gives empty answers" / "sources limit exceeded" / "non-Copilot user can't use agents" → `Agents-B.md` — check RCD state first (Fix 1), then permissions, source count, or licensing/pay-as-you-go path; run `Scripts/Get-SharePointAgentsAudit.ps1` for a full tenant + site posture check

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

# List all hub sites and check a site's hub association
Get-SPOHubSite | Select-Object Title, SiteUrl, RequiresJoinApproval
Get-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> | Select-Object Url, HubSiteId
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
