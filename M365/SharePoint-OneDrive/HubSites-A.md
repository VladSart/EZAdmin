# SharePoint Hub Sites — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains hub site architecture, association mechanics, and the boundary between what hubs control (navigation, branding, search) and what they deliberately do not control (permissions).

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
- Hub site registration and association mechanics (`Register-SPOHubSite`, `Add-SPOHubSiteAssociation`)
- Hub-to-hub (nested) associations, one level of nesting
- Hub navigation, theming, and search scoping behavior
- Approval workflows for self-service hub association
- Information architecture planning for hub structures

**Out of scope:**
- Site collection permission model itself (separate runbook — `Permissions-A.md`)
- SharePoint Advanced Management (SAM) Restricted Access Control / Data Access Governance, which CAN provide hub-scoped access governance as a deliberate additional layer (separate runbook — `Advanced-Management-A.md`)
- Communication site vs. Team site template selection (a prerequisite decision, not a hub-specific concern)
- Site provisioning automation (see `PowerAutomate/SharePoint/SharePoint-Site-Provisioning-A.md`)

**Assumptions:**
- Admin has SharePoint Administrator or Global Administrator role for tenant-wide hub registration
- PowerShell: `Microsoft.Online.SharePoint.PowerShell` module (SPO Management Shell)
- Sites involved are modern SharePoint sites (not classic experience)

---
## How It Works

<details><summary>Full architecture</summary>

### What a Hub Site Actually Is

A hub site is a regular SharePoint site (Communication or Team site) that has been **registered** as a hub via `Register-SPOHubSite`. Registration doesn't change the site itself — it creates a hub site object in the tenant's hub site registry that other sites can then **associate** with. The hub site continues to function as a normal site collection; it simply gains the additional role of being a navigation/branding/search anchor for its associated sites.

```
Regular SharePoint site
        │
        ▼
Register-SPOHubSite  (one-time action, requires SharePoint Admin)
        │
        ▼
Hub Site object created in tenant hub registry
   ├── Up to 2,000 hub sites per tenant (hard limit)
   └── Hub retains its own independent permission model — registration
       does not change who can access the hub site itself
        │
        ▼
Other sites call Add-SPOHubSiteAssociation to JOIN this hub
   ├── Each site can join exactly ONE hub
   ├── Unlimited associated sites per hub
   └── Association can require approval if RequiresJoinApproval = $true
```

### What Association Changes (and What It Doesn't)

Association is purely a **grouping declaration**. When Site B associates with Hub A:

| Changes | Does NOT change |
|---|---|
| Site B displays Hub A's navigation bar | Site B's permission groups, owners, or members |
| Site B inherits Hub A's theme (unless overridden) | Site B's sharing/external-access settings |
| Site B's content becomes scoped in Hub A's search vertical | Site B's storage quota or site template |
| Site B may show under Hub A in the SharePoint start page / app bar | Site B's retention or DLP policies |

This separation is deliberate: Microsoft designed hubs as a **discoverability and consistency layer**, not an access-control layer, precisely so that IT could reorganize navigation/branding across dozens of sites without having to touch (or risk breaking) each site's independently-managed permission model.

### Association Approval Flow

```
User (Site Owner) initiates association
        │
        ▼
Is RequiresJoinApproval = $true on the target hub?
        │
   ┌────┴────┐
   NO         YES
   │           │
   ▼           ▼
Association   Request queued
completes     for hub owner/
immediately   admin review
   │           │
   │           ▼
   │      Hub owner approves/denies
   │      via SharePoint Admin Center
   │           │
   │           ▼
   │      If approved: association
   │      completes
   ▼           ▼
Propagation to navigation, theme, search
(can take 2-4 hours to fully appear)
```

### Hub-to-Hub (Nested Hub) Architecture

A hub site can itself be associated with another hub site, creating a **parent hub → child hub → associated sites** hierarchy — but only **one level** of nesting is supported. This enables enterprise information architectures like:

```
Contoso Corporate Hub (parent)
    ├── Sales Division Hub (child)
    │       ├── Sales Team Site 1
    │       ├── Sales Team Site 2
    │       └── Sales Team Site 3
    ├── Engineering Division Hub (child)
    │       ├── Eng Team Site 1
    │       └── Eng Team Site 2
    └── HR Division Hub (child)
            └── HR Team Site 1

# NOT SUPPORTED: a child hub having its own child hubs beneath it
```

Navigation at the parent level surfaces links to child hubs; navigation at the child hub level surfaces its own associated sites. A user browsing an associated site sees breadcrumb-style navigation up through the child hub to the parent hub, giving a consistent enterprise-wide navigation experience without collapsing the underlying permission boundaries between any of the sites.

### Search Scoping Mechanics

Hub association adds a **hub-specific managed property** (`DepartmentId` internally maps to the hub's site ID) to the search index for content in associated sites. This is what powers "search within this hub" experiences. Because this relies on the standard SharePoint search crawl cycle, newly associated sites do not appear in hub-scoped search results until the next crawl completes — typically within 24 hours, not instantaneously.

### Theming Inheritance

When a site associates with a hub, it inherits the hub's theme by default. A site can still apply its own custom theme afterward, which will override the inherited hub theme visually — this is a common source of "why doesn't my site look like the hub" tickets that is actually expected behavior, not a broken inheritance.

</details>

---
## Dependency Stack

```
SharePoint Online Tenant
    │
    ├── Hub Site Registry (tenant-wide, max 2,000 entries)
    │       └── Register-SPOHubSite — creates a hub site object
    │             from an existing regular site
    │
    ├── Hub Site (the registered site itself)
    │       ├── Own independent permission model (unaffected by being a hub)
    │       ├── RequiresJoinApproval setting (governs association workflow)
    │       ├── Own theme (propagates to associated sites by default)
    │       └── Optional: ParentHubSiteId (if this hub is itself a child
    │           in a hub-to-hub relationship — max 1 level of nesting)
    │
    └── Associated Sites (Team sites, Communication sites)
            ├── HubSiteId property — points to exactly ONE hub (or empty)
            ├── Own independent permission model (never inherited from hub)
            ├── Own storage quota, sharing settings, retention policy
            ├── Search index: hub-scoped managed property added on next
            │   crawl cycle (up to 24h after association)
            └── Navigation/theme: hub's nav bar + theme displayed
                (2-4h propagation delay after association)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "Associate with hub" option missing entirely | User lacks Site Owner rights on the site | `Get-SPOUser -Site <url> -LoginName <UPN>` — check `IsSiteAdmin` |
| No hubs appear in the association dropdown | No hub sites registered in the tenant, or user has no visibility into any | `Get-SPOHubSite` |
| Association command succeeds but nothing changes on the site | Propagation delay (up to 2-4h), or browser cache | Re-check after 4h; hard refresh |
| Site shows in `Get-SPOSite -Identity` with correct `HubSiteId` but not in admin center hub view | Admin center UI cache lag | Re-check `Get-SPOHubSite -Identity <hub> \| Get-SPOHubSiteChild` equivalent audit; wait |
| Association silently fails, `HubSiteId` stays empty | Approval required and not yet granted, or target hub isn't actually a registered hub | `(Get-SPOHubSite -Identity <hub>).RequiresJoinApproval`; confirm hub registration |
| User expects hub-wide permission inheritance | Fundamental misunderstanding of hub design — expected behavior, not a bug | Explain via Fix 4 in `HubSites-B.md`; point to SAM if hub-wide governance is truly needed |
| Hub-scoped search missing recently associated site's content | Search crawl cycle hasn't run yet (up to 24h) | Wait for crawl; confirm site content is otherwise indexable |
| Child hub not surfacing under parent hub navigation | Hub-to-hub association not configured, or nav links not manually added | `(Get-SPOHubSite -Identity <childHub>).ParentHubSiteId` |
| "Maximum hub sites reached" error on registration | Tenant at 2,000 hub site ceiling | Requires hub consolidation — no limit increase available |
| Site's theme doesn't match hub after association | Site has its own custom theme applied, overriding inherited hub theme | Expected — confirm intentional, adjust site theme if not |

---
## Validation Steps

**1. Inventory all registered hub sites**
```powershell
Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com
Get-SPOHubSite | Select-Object Title, SiteUrl, ID, RequiresJoinApproval
```

**2. Check total hub count against the tenant limit**
```powershell
$hubCount = (Get-SPOHubSite).Count
Write-Output "Hub sites registered: $hubCount / 2000"
```

**3. Confirm a specific site's association**
```powershell
Get-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> |
    Select-Object Url, HubSiteId
```

**4. List all sites associated with a given hub**
```powershell
$hubId = (Get-SPOHubSite -Identity https://<tenantName>.sharepoint.com/sites/<hubSiteName>).ID
Get-SPOSite -Limit All | Where-Object { $_.HubSiteId -eq $hubId } | Select-Object Url, Title
```

**5. Verify hub-to-hub relationships**
```powershell
Get-SPOHubSite | Select-Object Title, ID, ParentHubSiteId |
    Where-Object { $_.ParentHubSiteId -and $_.ParentHubSiteId -ne "00000000-0000-0000-0000-000000000000" }
```

**6. Confirm the requesting user's rights on both the hub and the target site**
```powershell
Get-SPOUser -Site https://<tenantName>.sharepoint.com/sites/<hubSiteName> -LoginName <UPN>
Get-SPOUser -Site https://<tenantName>.sharepoint.com/sites/<siteName> -LoginName <UPN>
```

---
## Troubleshooting Steps (by phase)

### Phase 1 — Confirm Hub Registry State

1. Run `Get-SPOHubSite` and confirm the intended hub actually exists as a registered hub — not just a regular site with a similar name.
2. Check the tenant's total hub count against the 2,000 limit if registration itself is failing.

### Phase 2 — Association Attempt Diagnosis

3. Confirm the requesting user has Site Owner (or SharePoint/Global Admin) rights on the site being associated — Member-level access is insufficient.
4. Check `RequiresJoinApproval` on the target hub. If `$true`, verify whether a request is sitting in the pending-approval queue rather than assuming the association failed outright.
5. If association was attempted and `HubSiteId` on the site is still empty after a reasonable wait, retry the association — transient service errors during association are uncommon but not unheard of.

### Phase 3 — Propagation and Rendering

6. For "associated but nothing looks different" reports, first confirm the time elapsed since association — under 4 hours is not yet actionable.
7. If beyond 4 hours, check whether the site has its own custom theme that's visually overriding the hub theme (this is not a bug).
8. For missing hub navigation specifically, confirm the site is a modern SharePoint site — legacy classic-experience sites do not render modern hub navigation regardless of association state.

### Phase 4 — Search Scoping

9. For hub-scoped search gaps, confirm the associated site's content is otherwise searchable at all (permissions, not just hub scoping).
10. Allow up to 24 hours post-association for the search crawl cycle to pick up the new hub-scoped managed property before treating this as a defect.

### Phase 5 — Hub-to-Hub Structure

11. For nested hub issues, confirm only one level of nesting is being attempted — a child hub cannot have its own child hubs.
12. Confirm hub-to-hub association was actually run (`Add-SPOHubToHubAssociation`) — parent/child hub navigation links sometimes need to be added manually in the SharePoint Admin Center even after the underlying association succeeds.

### Phase 6 — Permission Expectation Mismatches

13. If the underlying request is really "I want everyone associated with this hub to have consistent access," redirect to the correct tool: either manual per-site permission management (`Permissions-A.md`), or SharePoint Advanced Management's Restricted Access Control applied consistently across the hub's associated sites (`Advanced-Management-A.md`). Hub association itself will never solve this.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Register a new hub site</summary>

```powershell
Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com

# The target site must already exist as a Communication or Team site
Register-SPOHubSite -Site https://<tenantName>.sharepoint.com/sites/<siteName> `
    -Principals @("<securityGroupOrUserUPN>")   # Optional: who can associate sites to this hub

# Verify registration
Get-SPOHubSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName>

# Optionally require approval for future join requests
Set-SPOHubSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> -RequiresJoinApproval $true
```

**Rollback (de-register the hub — does not delete the site, only its hub role):**
```powershell
Unregister-SPOHubSite -Site https://<tenantName>.sharepoint.com/sites/<siteName>
```
> ⚠️ Unregistering a hub automatically disassociates all sites that were joined to it — plan a maintenance window for hubs with many associated sites.

</details>

<details><summary>Playbook 2 — Bulk-associate multiple sites with a hub</summary>

```powershell
Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com

$hubUrl = "https://<tenantName>.sharepoint.com/sites/<hubSiteName>"
$sitesToAssociate = @(
    "https://<tenantName>.sharepoint.com/sites/<site1>",
    "https://<tenantName>.sharepoint.com/sites/<site2>",
    "https://<tenantName>.sharepoint.com/sites/<site3>"
)

foreach ($site in $sitesToAssociate) {
    try {
        Add-SPOHubSiteAssociation -Site $site -HubSite $hubUrl -ErrorAction Stop
        Write-Host "Associated: $site" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed: $site — $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Verify all associations
$hubId = (Get-SPOHubSite -Identity $hubUrl).ID
Get-SPOSite -Limit All | Where-Object { $_.HubSiteId -eq $hubId } | Select-Object Url
```

**Rollback (bulk disassociate):**
```powershell
foreach ($site in $sitesToAssociate) {
    Remove-SPOHubSiteAssociation -Site $site
}
```

</details>

<details><summary>Playbook 3 — Build a hub-of-hubs enterprise structure</summary>

```powershell
Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com

$parentHub = "https://<tenantName>.sharepoint.com/sites/<corporateHub>"
$childHubs = @(
    "https://<tenantName>.sharepoint.com/sites/<salesHub>",
    "https://<tenantName>.sharepoint.com/sites/<engineeringHub>",
    "https://<tenantName>.sharepoint.com/sites/<hrHub>"
)

# Register the parent hub (if not already registered)
Register-SPOHubSite -Site $parentHub

# Register and nest each child hub under the parent
foreach ($childHub in $childHubs) {
    Register-SPOHubSite -Site $childHub
    Add-SPOHubToHubAssociation -Source $childHub -Target $parentHub
    Write-Host "Nested $childHub under $parentHub" -ForegroundColor Green
}

# Verify nesting
foreach ($childHub in $childHubs) {
    $parentId = (Get-SPOHubSite -Identity $childHub).ParentHubSiteId
    Write-Host "$childHub → ParentHubSiteId: $parentId"
}
```

**Note:** manually add navigation links to child hubs in the parent hub's navigation settings if they don't auto-populate — `SharePoint Admin Center → [Parent hub] → Navigation`.

**Rollback:**
```powershell
foreach ($childHub in $childHubs) {
    Remove-SPOHubToHubAssociation -Source $childHub
}
```

</details>

<details><summary>Playbook 4 — Full hub structure audit and health report</summary>

```powershell
Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com

$report = @()
$allHubs = Get-SPOHubSite
$allSites = Get-SPOSite -Limit All

foreach ($hub in $allHubs) {
    $associatedSites = $allSites | Where-Object { $_.HubSiteId -eq $hub.ID }
    $report += [PSCustomObject]@{
        HubTitle            = $hub.Title
        HubUrl               = $hub.SiteUrl
        RequiresJoinApproval = $hub.RequiresJoinApproval
        IsChildHub           = [bool]($hub.ParentHubSiteId -and $hub.ParentHubSiteId -ne "00000000-0000-0000-0000-000000000000")
        AssociatedSiteCount  = $associatedSites.Count
    }
}

$report | Sort-Object AssociatedSiteCount -Descending | Format-Table -AutoSize
$report | Export-Csv "$env:TEMP\HubSiteStructureAudit.csv" -NoTypeInformation

$totalHubs = $allHubs.Count
Write-Host "Total registered hubs: $totalHubs / 2000 tenant limit" -ForegroundColor $(if ($totalHubs -gt 1800) {"Red"} elseif ($totalHubs -gt 1500) {"Yellow"} else {"Green"})
```

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect SharePoint hub site evidence for an escalation
.NOTES     Requires Microsoft.Online.SharePoint.PowerShell module
           Requires SharePoint Administrator role
#>

param(
    [Parameter(Mandatory)]
    [string]$TenantAdminUrl,   # https://<tenantName>-admin.sharepoint.com

    [string]$SiteUrl,
    [string]$HubUrl
)

Connect-SPOService -Url $TenantAdminUrl -ErrorAction Stop

$OutputPath = "$env:TEMP\SPHubSite-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# 1. All registered hubs
Get-SPOHubSite | Export-Csv "$OutputPath\01-AllHubSites.csv" -NoTypeInformation

# 2. Specific site's association state (if provided)
if ($SiteUrl) {
    Get-SPOSite -Identity $SiteUrl | Select-Object Url, HubSiteId, Template, StorageUsageCurrent |
        Export-Csv "$OutputPath\02-SiteAssociationState.csv" -NoTypeInformation

    Get-SPOUser -Site $SiteUrl | Export-Csv "$OutputPath\03-SitePermissions.csv" -NoTypeInformation
}

# 3. Specific hub's detail and associated sites (if provided)
if ($HubUrl) {
    $hub = Get-SPOHubSite -Identity $HubUrl
    $hub | Export-Csv "$OutputPath\04-HubDetail.csv" -NoTypeInformation

    Get-SPOSite -Limit All | Where-Object { $_.HubSiteId -eq $hub.ID } |
        Select-Object Url, Title |
        Export-Csv "$OutputPath\05-AssociatedSites.csv" -NoTypeInformation
}

# 4. Tenant-wide hub count vs. limit
[PSCustomObject]@{
    TotalHubSites = (Get-SPOHubSite).Count
    TenantLimit   = 2000
} | Export-Csv "$OutputPath\06-HubCountVsLimit.csv" -NoTypeInformation

Write-Host "Evidence collected to: $OutputPath" -ForegroundColor Green
Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath.zip" -Force
Write-Host "Zipped: $OutputPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| List all hub sites | `Get-SPOHubSite` |
| Register a new hub | `Register-SPOHubSite -Site <url>` |
| De-register a hub | `Unregister-SPOHubSite -Site <url>` |
| Associate a site with a hub | `Add-SPOHubSiteAssociation -Site <url> -HubSite <hubUrl>` |
| Remove association | `Remove-SPOHubSiteAssociation -Site <url>` |
| Check a site's hub association | `Get-SPOSite -Identity <url> \| Select HubSiteId` |
| Require approval for hub joins | `Set-SPOHubSite -Identity <hubUrl> -RequiresJoinApproval $true` |
| Nest a hub under a parent hub | `Add-SPOHubToHubAssociation -Source <childHubUrl> -Target <parentHubUrl>` |
| Remove hub-to-hub nesting | `Remove-SPOHubToHubAssociation -Source <childHubUrl>` |
| List sites associated with a hub | `Get-SPOSite -Limit All \| Where HubSiteId -eq <hubId>` |
| Count hubs against tenant limit | `(Get-SPOHubSite).Count` (limit: 2,000) |

---
## 🎓 Learning Pointers

- **Hub association is navigation/branding/search only — never permissions.** This single fact resolves the majority of hub-related tickets. Design reviews and client conversations about hub architecture should explicitly separate "how do we want navigation/discoverability organized" from "how do we want access controlled" — they are unrelated decisions in SharePoint's model, even though many other platforms conflate the two. [What is a SharePoint hub site](https://support.microsoft.com/en-us/office/what-is-a-sharepoint-hub-site-fabbfa6a-c5b7-4fdb-b092-8a870b06c37e)

- **A site belongs to exactly one hub — plan the information architecture before deploying, not after.** Because reassociation is easy technically but disruptive practically (navigation and search scoping visibly change for every user of that site), it's worth spending real design time on hub structure before broad rollout rather than iterating live across hundreds of sites. [Plan hub sites in SharePoint](https://learn.microsoft.com/en-us/sharepoint/hub-site-planning)

- **Hub-of-hubs is capped at one level of nesting by design.** Organizations trying to mirror a deep divisional hierarchy (region → division → department → team) directly onto nested hubs will hit this ceiling immediately. The supported pattern is a flatter hub structure with metadata/managed properties or SharePoint site templates carrying the deeper categorization instead. [Hub-to-hub association](https://learn.microsoft.com/en-us/sharepoint/hub-to-hub-association)

- **The 2,000-hub tenant limit is easy to approach in large, decentralized organizations that let every team self-register a hub.** Since there's no limit increase available, MSPs managing large tenants should establish a hub-registration governance process (who can register, when it's actually warranted vs. just associating with an existing hub) well before the limit becomes a blocker.

- **Propagation and crawl delays are frequently mistaken for configuration failures.** Navigation/theme changes: up to 2-4 hours. Search-scoping of newly associated content: up to 24 hours. Build these windows into first-line triage scripts so engineers don't spend time "fixing" something that just needs more time to propagate.
