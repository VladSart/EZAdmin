# SharePoint Hub Sites — Hotfix Runbook (Mode B: Ops)
> Fix or escalate hub site association, navigation, and theming issues in under 10 minutes.

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

# 1. List all hub sites in the tenant
Get-SPOHubSite | Select-Object Title, SiteId, SiteUrl, ID

# 2. Check what a specific site is associated with
Get-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> | Select-Object Url, HubSiteId

# 3. Check the hub site's own registration detail
Get-SPOHubSite -Identity https://<tenantName>.sharepoint.com/sites/<hubSiteName> | Select-Object Title, ID, PermissionsSyncTag, RequiresJoinApproval

# 4. Confirm the requesting user's permission level on the target site
Get-SPOUser -Site https://<tenantName>.sharepoint.com/sites/<siteName> -LoginName <UPN> -ErrorAction SilentlyContinue

# 5. Check tenant-wide hub site count against the 2,000 limit
(Get-SPOHubSite).Count
```

**Interpretation Table:**

| Symptom | Likely Cause | Go To |
|---------|-------------|-------|
| "Associate with a hub site" option greyed out / no hubs listed | Requesting user isn't a site owner, or hub join approval required and not yet granted | Fix 1 |
| Site associated but hub navigation not showing on it | Navigation cache not refreshed, or hub nav explicitly not enabled on the site | Fix 2 |
| Site missing from hub's associated-sites list in admin center | Association still processing (up to 2-4h) or association silently failed | Fix 3 |
| User expects hub-level permission but site permissions differ | Hub association does NOT change permissions — this is by design | Fix 4 (education, not a bug) |
| Search results not scoped to hub as expected | Hub-scoped search requires hub site to be correctly registered and associated sites indexed | Fix 5 |
| Child hub not appearing under parent hub | Hub-to-hub association not configured, or nav links not manually added | Fix 6 |
| Can't associate — "maximum number of hub sites reached" | Tenant at the 2,000 hub site registration limit | Escalate — requires hub consolidation, not a quick fix |

---
## Dependency Cascade

<details><summary>What must be true for hub site association to work</summary>

```
Entra ID user has Site Owner (or above) permission on the site being associated
    └── SharePoint Admin has registered the target hub site
        (Register-SPOHubSite — one-time setup per hub)
        └── Tenant hub site count < 2,000 (hard limit)
            └── Site is NOT already associated with a different hub
                (a site can only belong to ONE hub at a time)
                └── If RequiresJoinApproval = $true on the hub:
                    an approval request must be submitted and accepted
                    by a hub site owner/admin
                    └── Association completes (can take 2-4 hours to
                        fully propagate to navigation/search/theme)
                        └── Site inherits: hub navigation, hub theme
                            ── PERMISSIONS ARE NOT INHERITED ──
                            (this is the single most common misunderstanding)
```

**Key principle:** hub association is a navigation/branding/search grouping mechanism. It has zero effect on who can access the associated site. Never assume associating a site with a hub changes its permission model.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the site's current hub association**
```powershell
Get-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> | Select-Object Url, HubSiteId
# Empty/GUID of all zeros = not associated with any hub
```

**Step 2 — Confirm the target hub is actually registered**
```powershell
Get-SPOHubSite | Where-Object { $_.SiteUrl -eq "https://<tenantName>.sharepoint.com/sites/<hubSiteName>" }
# If nothing returns, the "hub" site was never registered with Register-SPOHubSite —
# it's just a regular site, and association will fail
```

**Step 3 — Confirm the user attempting association has Owner rights on the target site**
```powershell
Get-SPOUser -Site https://<tenantName>.sharepoint.com/sites/<siteName> -LoginName <UPN> |
    Select-Object LoginName, IsSiteAdmin
```
Site Owner (or SharePoint/Global Admin) is required — Member-level access is not sufficient to associate a site with a hub.

**Step 4 — Check if the hub requires join approval**
```powershell
(Get-SPOHubSite -Identity https://<tenantName>.sharepoint.com/sites/<hubSiteName>).RequiresJoinApproval
```
If `$true`, association requests queue for hub owner approval rather than completing immediately — a "nothing happened" report is often just an unapproved pending request.

**Step 5 — Allow for propagation delay before troubleshooting further**
Hub association, navigation updates, and theme changes can take **2-4 hours** to fully propagate across all clients and search. Don't escalate a "just associated, nav isn't showing yet" report inside that window.

**Step 6 — For search-scoping issues, confirm the associated site has been crawled**
Newly associated sites need a search crawl cycle (typically within 24h) before hub-scoped search includes their content.

---
## Common Fix Paths

<details><summary>Fix 1 — Associate a site with a hub (or resolve why the option is unavailable)</summary>

**Use when:** the "Associate with a hub site" option is missing or greyed out.

```powershell
Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com

# Confirm the hub exists and get its exact identity
Get-SPOHubSite | Select-Object Title, SiteUrl

# Associate the site (requires SharePoint Admin, or Site Owner if hub allows self-service join)
Add-SPOHubSiteAssociation -Site https://<tenantName>.sharepoint.com/sites/<siteName> `
    -HubSite https://<tenantName>.sharepoint.com/sites/<hubSiteName>

# Verify
Get-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> | Select-Object Url, HubSiteId
```

**If the requesting user isn't a SharePoint Admin,** they need Site Owner on the site AND the hub must either allow self-service association or their request must be approved (see Fix 3).

**Rollback (remove association):**
```powershell
Remove-SPOHubSiteAssociation -Site https://<tenantName>.sharepoint.com/sites/<siteName>
```

</details>

<details><summary>Fix 2 — Hub navigation not appearing on an associated site</summary>

**Use when:** the site shows as associated (`HubSiteId` populated) but the hub navigation bar doesn't render.

```powershell
# Confirm association is real (not stale UI cache)
Get-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> | Select-Object Url, HubSiteId
```

Most common causes, in order of likelihood:
1. **Propagation delay** — wait up to 2-4 hours after association before troubleshooting further
2. **Browser/client cache** — hard refresh (Ctrl+F5) or try an incognito window
3. **Site theme override** — a site with a custom theme applied AFTER hub association can sometimes suppress the hub nav bar visually; check site theme settings
4. **Classic site / incompatible template** — some legacy classic-experience sites do not render modern hub navigation; confirm the site is a modern SharePoint site

**No destructive fix required** — this is typically a wait-and-verify issue, not a misconfiguration.

</details>

<details><summary>Fix 3 — Site missing from hub's associated-sites list / approve a pending join request</summary>

**Use when:** a user says they associated a site, but the hub's admin center view doesn't show it.

```powershell
# Check if a join request is pending approval (if RequiresJoinApproval is enabled on the hub)
Get-SPOHubSite -Identity https://<tenantName>.sharepoint.com/sites/<hubSiteName> | Select-Object RequiresJoinApproval

# Approve a pending association request via SharePoint Admin Center
# SharePoint Admin Center → Sites → Active sites → [Hub site] → Hub → Review pending requests
```

If `RequiresJoinApproval` is `$false` and the site still doesn't appear after 4+ hours, re-run the association — it may have silently failed due to a transient service error:
```powershell
Remove-SPOHubSiteAssociation -Site https://<tenantName>.sharepoint.com/sites/<siteName> -ErrorAction SilentlyContinue
Add-SPOHubSiteAssociation -Site https://<tenantName>.sharepoint.com/sites/<siteName> -HubSite https://<tenantName>.sharepoint.com/sites/<hubSiteName>
```

</details>

<details><summary>Fix 4 — User expects permission change from hub association (education fix)</summary>

**Use when:** someone reports "I associated this site with the hub but people still can't/can access it the same as before."

This is expected behavior, not a bug. **Hub association never changes site permissions.** Each associated site keeps its own independent permission model — hub association only affects navigation, theme, and search scoping.

```powershell
# Confirm current permissions are unaffected by association (they should be identical to pre-association)
Get-SPOSiteGroup -Site https://<tenantName>.sharepoint.com/sites/<siteName>
Get-SPOUser -Site https://<tenantName>.sharepoint.com/sites/<siteName>
```

If the goal is actually to grant hub-wide access, that requires a separate, deliberate action — e.g. adding a common security group to each associated site's membership, or using SharePoint Advanced Management's Restricted Access Control at the hub level. Point the requester to `Permissions-B.md` for standard permission changes, or `Advanced-Management-A.md` if hub-wide access governance is the actual goal.

</details>

<details><summary>Fix 5 — Hub-scoped search not returning results from associated sites</summary>

**Use when:** searching from the hub site doesn't surface content that clearly exists in an associated site.

```powershell
# Confirm association is correct first
Get-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> | Select-Object Url, HubSiteId
```

Checklist:
1. **Crawl delay** — newly associated sites need a search index cycle (up to 24h) before their content is included in hub-scoped search
2. **Site visibility** — confirm the searching user actually has permission to the associated site (search never surfaces content a user can't access — this is expected, not a hub bug)
3. **Search vertical configuration** — hub-scoped search relies on the hub's search vertical being correctly scoped; verify in SharePoint Admin Center → hub site → Search settings

**No PowerShell remediation** — this is primarily a wait-and-verify or permissions issue, not a configuration fix.

</details>

<details><summary>Fix 6 — Child hub not appearing under a parent hub (hub-to-hub)</summary>

**Use when:** using a hub-of-hubs architecture and a child hub isn't showing under the parent's navigation.

```powershell
Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com

# Associate a hub site as a child of a parent hub
Add-SPOHubToHubAssociation -Source https://<tenantName>.sharepoint.com/sites/<childHubName> `
    -Target https://<tenantName>.sharepoint.com/sites/<parentHubName>

# Verify
Get-SPOHubSite -Identity https://<tenantName>.sharepoint.com/sites/<childHubName> | Select-Object ParentHubSiteId
```

**Note:** only one level of hub-of-hubs nesting is supported — a child hub cannot itself have child hubs beneath it.

Navigation links to associated child hubs are not always auto-updated in the parent's nav bar; if the association is confirmed via PowerShell but the parent's navigation doesn't show it, manually add the link:
```
SharePoint Admin Center → [Parent hub] → Navigation → Add link → point to child hub URL
```

**Rollback:**
```powershell
Remove-SPOHubToHubAssociation -Source https://<tenantName>.sharepoint.com/sites/<childHubName>
```

</details>

---
## Escalation Evidence

```
=== SharePoint Hub Site Escalation Pack ===
Date/Time:              _______________
Engineer:               _______________
Tenant:                 _______________

Site URL:                _______________
Target/actual hub URL:   _______________
Current HubSiteId:       _______________

Get-SPOHubSite output for target hub attached:  [ ] Yes
RequiresJoinApproval:                            [ ] Yes  [ ] No
Time since association attempted:                _______________ (note if <4h — may just be propagation delay)

Requesting user's site permission level:         _______________
Requesting user is Site Owner or SP Admin:       [ ] Yes  [ ] No

Tenant hub site count (Get-SPOHubSite).Count:    _______________ (limit: 2,000)

Steps already taken:
[ ] Confirmed hub is registered (Get-SPOHubSite)
[ ] Confirmed requesting user has Owner rights
[ ] Checked RequiresJoinApproval / pending request queue
[ ] Waited 4+ hours for propagation
[ ] Hard-refreshed browser / tried different client
[ ] Confirmed this is NOT a permissions expectation issue (Fix 4)

Support tier:  [ ] L2 → L3  [ ] L3 → Microsoft
```

---
## 🎓 Learning Pointers

- **Hub association never changes permissions — say this out loud to every requester.** This is by far the most common support ticket pattern for hub sites: someone associates a site expecting it to inherit hub-level access, and it doesn't, because hub sites are a navigation/branding/search grouping mechanism only. If hub-wide access governance is actually the goal, that's a separate, deliberate configuration (shared security groups, or SharePoint Advanced Management's hub-level Restricted Access Control). [Hub sites overview](https://support.microsoft.com/en-us/office/what-is-a-sharepoint-hub-site-fabbfa6a-c5b7-4fdb-b092-8a870b06c37e)

- **A site can only belong to one hub at a time.** If a site needs to appear related to two different organizational groupings, that's a sign the hub structure itself needs rethinking (e.g. hub-of-hubs), not a limitation to work around with duplicate sites. [Plan hub sites](https://learn.microsoft.com/en-us/sharepoint/hub-site-planning)

- **Propagation delay is real and commonly mistaken for a broken association.** Navigation, theme, and search scoping updates after association can take 2-4 hours to fully appear everywhere. Train the first-line team to check the timestamp of the association attempt before escalating a "hub nav isn't showing" ticket.

- **The 2,000 hub site limit is a hard tenant ceiling, not a per-user or per-site-collection limit.** Large enterprises that create a new hub per department/project can hit this faster than expected. If a client is approaching the limit, the fix is hub consolidation (fewer, broader hubs with more associated sites each) — there is no increase available for this limit. [Hub site limits](https://learn.microsoft.com/en-us/sharepoint/hub-site-planning)

- **Hub-to-hub nesting is capped at one level.** A parent hub can have child hubs, but those child hubs cannot have their own child hubs. Enterprises trying to model a deep organizational hierarchy directly onto hub structure will hit this limit — the practical workaround is to use hub navigation links and site metadata/managed properties for deeper categorization rather than nested hub levels beyond what's supported.
