# Agents in SharePoint — Reference Runbook (Mode A: Deep Dive)
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
- Ready-made agents — the default agent auto-provisioned on every SharePoint site and document library
- Custom agents — user-built agents scoped to up to 20 selected files/pages, created via the site or library context menu
- Knowledge Agent — the separate content-hygiene/summarization/enrichment agent, governed by its own tenant scope setting
- Licensing paths: M365 Copilot per-user licence vs. pay-as-you-go metered billing (successor to the Jan–Jun 2025 free promotional trial)
- The interaction between Restricted Content Discovery (RCD) and all agent features on a site
- Tenant-wide oversight via the Microsoft 365 admin center's Copilot Control System (Agents) — usage visibility, disabling agents, and org-wide sharing controls

**Does not cover:**
- Restricted Access Control (RAC), Site Lifecycle Management, and Data Access Governance reports — see `Advanced-Management-A.md`; this runbook covers RCD only where it intersects with agent availability
- Copilot Studio custom agent *development* (Power Platform, connectors, topics/actions authoring) — see `PowerAutomate/PowerApps/CopilotStudio-Security-A.md`
- The M365 Admin Agent (a distinct agent for tenant administration itself, not content agents) — see `M365/AdminAgent/AdminAgent-A.md`
- Cross-agent governance policy authored in the Copilot Control System's Agent Governance surface — see `M365/Copilot/AgentGovernance-A.md`
- SharePoint Syntex content processing (autofill columns, taxonomy) — a related but licensing-distinct SharePoint Premium capability

**Assumed role:** SharePoint Administrator (tenant-wide agent settings), Site Owner or Edit permission (custom agent creation), and Global/Billing Administrator for pay-as-you-go metered billing enablement. `Microsoft.Online.SharePoint.PowerShell` module required for `KnowledgeAgentScope` and promo-status cmdlets.

---

## How It Works

<details><summary>Full architecture</summary>

### The three agent surfaces

SharePoint doesn't have one "agent" feature — it has three, layered on the same underlying access model but governed by separate settings:

```
1. Ready-made agent
   - Auto-provisioned on EVERY SharePoint site and document library, no setup required
   - Scope = the current site + any associated hub sites
   - General-purpose: Q&A, navigation, reasoning over the site's content
   - Cannot be customized beyond what's inherently in scope

2. Custom agent
   - Built by a user with Edit permission via "Create an agent" (right-click or ellipsis on selected items)
   - Scope = explicitly selected files/pages, hard-capped at 20 sources
   - Customizable: branding, purpose, behavior instructions
   - Exceeding 20 sources fails outright with "Sources limit exceeded"

3. Knowledge Agent
   - A content-hygiene and enrichment agent, not primarily a Q&A agent
   - Summarizes long documents, extracts metadata, compares versions, flags outdated content,
     suggests structure
   - Governed independently via Set-SPOTenant -KnowledgeAgentScope (AllSites / ExcludeSelectedSites / NoSites)
   - Conceptually complements the other two: Knowledge Agent prepares/enriches content;
     ready-made and custom agents reason over it
```

All three agent types are built on the same Microsoft Graph grounding model Copilot uses generally: at query time, results are filtered to what the *requesting user* can already see. There is no separate "agent permission" layer — an agent is never a backdoor around SharePoint's native permission model, by architecture, not merely by policy.

### Licensing paths

Two independent ways a user gets access to create/use SharePoint agents:

```
Path 1: M365 Copilot licence assigned to the user
    → Full access to all three agent surfaces, no additional cost, no admin action required

Path 2: Pay-as-you-go metered billing (for non-Copilot-licensed users)
    → Enabled at the tenant level in Microsoft 365 admin center > Billing > Pay-as-you-go services
    → Billed per message/interaction — a direct, ongoing cost the org has to explicitly opt into
    → Superseded the free promotional trial (Jan 6 - Jun 30, 2025) that gave tenants with
      50+ Copilot licences 10,000 free queries/month for non-Copilot users
    → Get-SPOCopilotPromoOptInStatus / Set-SPOCopilotPromoOptInStatus manage the legacy promo
      mechanism specifically, NOT pay-as-you-go billing itself (that's admin-center-only)
```

A common misconfiguration: an admin assumes disabling the legacy promo (`Set-SPOCopilotPromoOptInStatus -IsCopilotPromoStatusEnabled $false`) also disables pay-as-you-go billing. It doesn't — they're separate mechanisms with separate on/off switches, and pay-as-you-go must be turned off from the admin center billing page.

### Why RCD disables agents entirely (not just search)

Restricted Content Discovery (RCD, `RestrictContentOrgWideSearch` on `Set-SPOSite`) was originally built to control tenant-wide search and Copilot grounding for oversharing scenarios. Because ready-made and custom agents are built on the same Graph-grounding pipeline, RCD's scope was extended to also suppress the Agent icon from the site's global header entirely — when RCD is on, users cannot see or use the ready-made agent, cannot create new custom agents, and cannot add the site's content as a source to an agent built elsewhere. This is a single on/off flag with a wider blast radius than its name suggests, and is the most common source of "agents just disappeared" tickets when RCD was toggled for an unrelated search-hygiene reason.

### The Copilot Control System as the oversight surface

Tenant admins and AI admins manage actively-used agents (including SharePoint agents) from the Microsoft 365 admin center, under **Copilot Control System → Agents** (the successor branding for what was previously called Integrated Apps). From here, admins can:
- View which agents exist and their usage
- Disable specific agents tenant-wide
- Control the default org-wide sharing scope for newly created agents: **All users** (default) / **Specific users or groups** / **No users** (fully disables org-wide sharing)

This setting governs *who an agent can be shared with*, not *what data it can access* — the underlying per-user permission filtering at query time is unaffected by sharing scope.

</details>

---

## Dependency Stack

```
Tenant subscription: any base M365/O365 plan that supports SharePoint Online
    │
    ▼
Licensing path (per requesting user)
    ├── M365 Copilot licence  ──OR──  Pay-as-you-go metered billing enabled (tenant-level, Billing admin)
    ▼
Entra ID role / SharePoint permission
    - SharePoint Administrator          (tenant-wide agent settings: KnowledgeAgentScope, sharing scope)
    - Site Owner / Edit permission      (create a custom agent; ready-made agent needs no extra grant)
    - Billing Administrator             (enable/disable pay-as-you-go metered billing)
    ▼
Site-level gate: RestrictContentOrgWideSearch (RCD)
    - $false required for ANY agent feature (ready-made, custom, or adding this site as a source) to appear
    ▼
Agent-type-specific configuration
    - Ready-made:    none — always on if RCD allows it
    - Custom:        ≤20 selected sources; branding/behavior instructions set at creation
    - Knowledge:     Set-SPOTenant -KnowledgeAgentScope {AllSites | ExcludeSelectedSites | NoSites}
                      + -KnowledgeAgentExcludedSiteIds for the ExcludeSelectedSites case
    ▼
Query-time enforcement (all three types, identical mechanism)
    - Requesting user's existing SharePoint/OneDrive permissions are checked against Microsoft Graph
    - Results are filtered per-user; the agent process itself has no elevated access
    ▼
Tenant oversight surface (post-hoc, not a gate)
    - Microsoft 365 admin center > Copilot Control System > Agents
      (usage visibility, disable-agent action, org-wide sharing scope)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Agent icon completely absent from a site | RCD (`RestrictContentOrgWideSearch`) is `$true` on the site | `Get-SPOSite -Identity <url> \| Select RestrictContentOrgWideSearch` |
| Agent gives empty/generic answers for a user who "should" see the content | User lacks the underlying SharePoint permission — agent is correctly filtering, not malfunctioning | `Get-SPOUser -Site <url> -LoginName <user>` |
| "Sources limit exceeded" on custom agent creation | Hard 20-item cap on custom agent sources | Count selected items before creation |
| Non-Copilot user can't create/use any agent | No licence path — promo expired and pay-as-you-go not enabled | `Get-SPOCopilotPromoOptInStatus`; check admin center billing |
| Knowledge Agent absent from one site but present elsewhere | Site is in `KnowledgeAgentExcludedSiteIds`, or tenant scope is `NoSites` | `Get-SPOTenant \| Select KnowledgeAgentScope, KnowledgeAgentExcludedSiteIds` |
| Agent shared outside intended team | Org-wide sharing scope still "All users" in Copilot Control System | Admin center > Copilot Control System > Agents > sharing scope |
| Ready-made agent missing content from a linked hub site | Hub association was never completed, or agent scope only includes the current site (hub content should auto-include if properly associated) | See `HubSites-B.md` Fix 1 to confirm association state |
| Newly uploaded file not reflected in agent answers | Standard search re-crawl/indexing lag, not agent-specific | Wait for indexing; confirm via `Get-PnPSearchCrawlLog` if available |

---

## Validation Steps

**1. Confirm module and connectivity**
```powershell
Get-Module Microsoft.Online.SharePoint.PowerShell -ListAvailable | Select-Object Name, Version
Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com"
```
Good: module present, connects without error.
Bad: module missing → `Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser`.

**2. Confirm tenant-wide agent-relevant settings**
```powershell
Get-SPOTenant | Select-Object KnowledgeAgentScope, KnowledgeAgentExcludedSiteIds, `
    DelegateRestrictedContentDiscoverabilityManagement
```
Good: values reflect intended policy.
Bad: `KnowledgeAgentScope` is `NoSites` when it shouldn't be, or expected exclusions aren't present.

**3. Confirm site-level RCD state**
```powershell
Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" | Select-Object RestrictContentOrgWideSearch
```
Good: `False` if agents should be available.
Bad: `True` unexpectedly → cross-check against `Advanced-Management-A.md`'s RCD playbooks; someone may have set this for a search reason without knowing about the agent side effect.

**4. Confirm licensing/metering path for a specific user**
```powershell
Connect-MgGraph -Scopes "Organization.Read.All", "User.Read.All"
Get-MgUserLicenseDetail -UserId "<user@domain.com>" | Where-Object { $_.SkuPartNumber -like "*COPILOT*" }
Get-SPOCopilotPromoOptInStatus
```
Good: user has a Copilot SKU, or pay-as-you-go is confirmed enabled via the admin center.
Bad: neither present → no access path exists regardless of site permissions.

**5. Confirm Copilot Control System sharing scope**
```
Microsoft 365 admin center > Settings > Integrated apps > Agents (Copilot Control System)
Review the org-wide sharing default and any per-agent overrides.
```
Good: scope matches intended governance posture.
Bad: "All users" when the org expected a restricted default.

---

## Troubleshooting Steps by Phase

**Phase 1 — Rule out the licensing gate**
Every agent feature ultimately depends on either a Copilot licence or pay-as-you-go billing being active for the requesting user's tenant. Confirm this first — a licensing gap looks identical to a functional bug (agent simply "isn't there" or "won't create") from the end-user's perspective.

**Phase 2 — Rule out RCD**
Because RCD's effect on agents is a documented but easily-forgotten side effect, always check `RestrictContentOrgWideSearch` before assuming a genuine agent malfunction. Cross-reference with `Advanced-Management-B.md`/`-A.md` if RCD delegation to site admins is in play — a site admin may have toggled RCD for a search-hygiene reason unaware of the agent impact.

**Phase 3 — Rule out the permission model working as intended**
Confirm the requesting user's actual SharePoint permission on the content in question. A very large share of "broken agent" reports are the access-filtering model functioning correctly — the fix is a permission grant (if legitimate) or user education (if not), never a workaround to bypass the filter.

**Phase 4 — Isolate by agent type**
Ready-made, custom, and Knowledge Agent are governed by different settings (RCD affects all three; `KnowledgeAgentScope` affects only Knowledge Agent; the 20-source cap affects only custom agents). Identify which of the three is actually failing before applying a fix — a Knowledge Agent absence is never fixed by touching RCD if RCD is already `$false`.

**Phase 5 — Escalate only after confirming propagation isn't the cause**
Tenant-level `Set-SPOTenant` changes (including `KnowledgeAgentScope`) follow the same general SPO tenant-setting propagation behavior as other settings — allow a reasonable window (consistent with other SPO tenant settings, typically well under an hour) before escalating a "the setting didn't take" report.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Enable agents broadly for a site that was over-restricted by RCD</summary>

**Scenario:** A site had RCD enabled for legitimate search-oversharing reasons, but the business now also wants agent functionality restored without fully reopening search visibility.

**Reality check first:** RCD does not have an independent "search only, keep agents" mode — it is a single flag covering both. If the business genuinely needs search restricted but agents available, there is no native switch for that split; the options are (a) accept RCD's full scope, or (b) restrict access at the permission level instead of RCD, which naturally constrains both search and agents to the same authorized audience without the all-or-nothing RCD behavior.

```powershell
# Option A: fully lift RCD (search AND agents become available)
Set-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" -RestrictContentOrgWideSearch $false

# Option B: leave RCD on, and instead tighten SharePoint permissions/RAC to the intended
# audience — this naturally scopes both search and agent access without the all-or-nothing tradeoff
# (see Advanced-Management-A.md, Restricted Access Control)
```

**Rollback:** Re-enable RCD if Option A is reversed:
```powershell
Set-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" -RestrictContentOrgWideSearch $true
```

</details>

<details><summary>Playbook 2 — Roll out pay-as-you-go agent access for non-Copilot users</summary>

**Scenario:** The org wants a subset of non-Copilot-licensed staff to use SharePoint agents, following the end of the free 2025 promotional trial.

```
1. Confirm business sign-off on per-message billing before proceeding — this has an ongoing cost.
2. Microsoft 365 admin center > Billing > Your products > Pay-as-you-go services
3. Enable metered billing for SharePoint agents (requires Billing Administrator or Global Administrator).
4. Confirm activation:
```
```powershell
# Legacy promo status (informational only — does not reflect pay-as-you-go state)
Get-SPOCopilotPromoOptInStatus
```
```
5. Communicate the per-message cost model to affected teams so usage patterns don't generate
   unexpected billing.
```

**Rollback:** Disable pay-as-you-go metered billing from the same admin center billing page. There is no PowerShell cmdlet for this specific toggle.

</details>

<details><summary>Playbook 3 — Restrict Knowledge Agent to a defined subset of sites</summary>

**Scenario:** The org wants Knowledge Agent's content-hygiene features available only on a curated set of sites (e.g., a document-heavy knowledge base) rather than tenant-wide.

```powershell
# Confirm current scope
Get-SPOTenant | Select-Object KnowledgeAgentScope, KnowledgeAgentExcludedSiteIds

# Approach A: allow-list via exclusion of everything except the intended sites
# (there is no direct "include only these sites" scope value — ExcludeSelectedSites is
# an exclusion list, so achieving an effective allow-list means excluding every site
# EXCEPT the intended ones)
$allSiteIds = (Get-SPOSite -Limit All).Id
$keepSiteIds = @("<guid-of-site-to-keep-1>", "<guid-of-site-to-keep-2>")
$excludeIds = $allSiteIds | Where-Object { $_ -notin $keepSiteIds }
Set-SPOTenant -KnowledgeAgentScope ExcludeSelectedSites -KnowledgeAgentExcludedSiteIds ($excludeIds -join ",")
```

**Caution:** This pattern is exclusion-list-based, not allow-list-based at the API surface — for tenants with hundreds or thousands of sites, the exclusion list becomes unwieldy to maintain as new sites are created (new sites are NOT automatically excluded by default under `ExcludeSelectedSites`, so a governance process is needed to add new sites to the exclusion list going forward, or the "curated allow-list" intent will silently erode).

**Rollback:**
```powershell
Set-SPOTenant -KnowledgeAgentScope AllSites
```

</details>

<details><summary>Playbook 4 — Tighten org-wide agent sharing after an oversharing incident</summary>

**Scenario:** An agent built by one team was discovered shared broadly across the tenant via the default "All users" sharing scope, and the org wants to lock this down going forward.

```
1. Microsoft 365 admin center > Settings > Integrated apps > Agents (Copilot Control System)
2. Change the org-wide default sharing scope from "All users" to "Specific users or groups"
   (recommended: define the target group(s) in Entra ID first) or "No users" if agent sharing
   should require a separate approval process entirely.
3. Review already-shared agents individually — the tenant-wide setting only affects the
   DEFAULT for new sharing actions; it does not retroactively un-share agents already
   distributed under the old default.
4. For the specific agent involved in the incident, manually review and revoke its
   existing sharing list from the admin center's per-agent detail view.
```

**Rollback:** Revert the default sharing scope to "All users" if the change breaks legitimate cross-team agent distribution workflows; this does not restore any sharing grants that were manually revoked in step 4.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects SharePoint agent configuration state for escalation.
.NOTES     Read-only. Requires SharePoint Administrator + Microsoft.Online.SharePoint.PowerShell.
#>
param(
    [Parameter(Mandatory)][string]$TenantAdminUrl,
    [Parameter(Mandatory)][string]$SiteUrl,
    [string]$UserPrincipalName
)

Connect-SPOService -Url $TenantAdminUrl

$evidence = [ordered]@{
    CollectedAt              = Get-Date -Format "u"
    TenantSettings           = Get-SPOTenant | Select-Object KnowledgeAgentScope, `
        KnowledgeAgentExcludedSiteIds, DelegateRestrictedContentDiscoverabilityManagement
    SiteRCDState             = Get-SPOSite -Identity $SiteUrl | Select-Object Url, RestrictContentOrgWideSearch
    PromoOptInStatus         = Get-SPOCopilotPromoOptInStatus
    ModuleVersion            = (Get-Module Microsoft.Online.SharePoint.PowerShell -ListAvailable |
                                 Select-Object -First 1).Version.ToString()
}

if ($UserPrincipalName) {
    $evidence.UserSitePermission = Get-SPOUser -Site $SiteUrl -LoginName $UserPrincipalName |
        Select-Object LoginName, IsSiteAdmin, Groups
}

$evidence | ConvertTo-Json -Depth 4
```

Attach the JSON output plus the exact end-user-reported error text (if any) to the escalation ticket.

---

## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-SPOTenant \| Select KnowledgeAgentScope, KnowledgeAgentExcludedSiteIds` | Check Knowledge Agent tenant scope |
| `Set-SPOTenant -KnowledgeAgentScope AllSites\|ExcludeSelectedSites\|NoSites` | Configure Knowledge Agent scope |
| `Get-SPOSite -Identity <url> \| Select RestrictContentOrgWideSearch` | Check whether RCD is suppressing agents on a site |
| `Set-SPOSite -Identity <url> -RestrictContentOrgWideSearch $false\|$true` | Toggle RCD (also toggles all agent availability on the site) |
| `Get-SPOCopilotPromoOptInStatus` | Check legacy free-promo opt-in state |
| `Set-SPOCopilotPromoOptInStatus -IsCopilotPromoStatusEnabled $true\|$false` | Toggle legacy promo (NOT pay-as-you-go billing) |
| `Get-SPOUser -Site <url> -LoginName <user>` | Confirm a user's underlying SharePoint permission |
| `Get-MgSubscribedSku \| Where SkuPartNumber -like "*COPILOT*"` | Check tenant Copilot licence assignment |
| Admin center: Copilot Control System > Agents | View/disable agents, set org-wide sharing scope |
| Admin center: Billing > Pay-as-you-go services | Enable/disable metered billing for non-Copilot agent access |

---

## 🎓 Learning Pointers

- **Three agent types, three separate governance settings.** Ready-made and custom agents are gated together by RCD; Knowledge Agent has its own independent `KnowledgeAgentScope` setting. Diagnosing "agents are missing" requires first identifying which of the three is actually affected. See [Get started with agents in SharePoint](https://support.microsoft.com/en-us/office/get-started-with-agents-in-sharepoint-69e2faf9-2c1e-4baa-8305-23e625021bcf).

- **RCD's agent-suppression side effect is easy to miss.** It was designed as a search-discoverability control and later extended to cover agents; teams that set it purely for search-hygiene reasons are frequently surprised when agent functionality disappears too. See [Manage access to agents in SharePoint](https://learn.microsoft.com/en-us/sharepoint/manage-access-agents-in-sharepoint).

- **`KnowledgeAgentScope` with `ExcludeSelectedSites` is exclusion-based, not allow-list-based.** Building an effective allow-list means excluding every site except the intended ones, and new sites are not auto-excluded — this requires an ongoing governance process, not a one-time setup. See [Get started with Knowledge Agent](https://learn.microsoft.com/en-us/sharepoint/knowledge-agent-get-started).

- **The 2025 promo and pay-as-you-go billing are entirely separate mechanisms.** `Set-SPOCopilotPromoOptInStatus` only touches the legacy trial; pay-as-you-go metered billing is enabled and disabled exclusively from the Microsoft 365 admin center billing page, with real per-message cost implications. See [Manage trial agents in SharePoint by using PowerShell](https://learn.microsoft.com/sharepoint/manage-trial-agents-sharepoint-powershell).

- **Org-wide sharing scope changes are not retroactive.** Tightening the Copilot Control System's default sharing scope only affects future sharing actions — agents already shared under the old "All users" default remain shared until manually reviewed and revoked per-agent. See [Share and manage agents built with Microsoft 365 Copilot](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/agent-builder-share-manage-agents).

- **Agents can never see more than the requesting user already can.** This is an architectural property of the Graph-grounding model, not a policy choice — there is no admin toggle that would let an agent bypass a user's own SharePoint permissions, which rules out an entire class of "can we make the agent see everything" requests as simply not possible. See [Frequently asked questions about Copilot in SharePoint](https://support.microsoft.com/en-us/office/frequently-asked-questions-about-copilot-in-sharepoint-eb1b7668-3d98-4a93-98ef-f0c6dfc694f0).
