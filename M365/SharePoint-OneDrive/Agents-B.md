# Agents in SharePoint — Hotfix Runbook (Mode B: Ops)
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

"Agents in SharePoint" covers the **ready-made agent** every site/library gets automatically, **custom agents** users build from selected files, and the newer **Knowledge Agent** (content-hygiene/summarization). All three ride on the same access model as Copilot — they can only see what the requesting user can already see — so most tickets are really licensing, Restricted Content Discovery (RCD), or the 20-source limit in disguise. Run these first:

```powershell
# 1. Confirm SPO Management Shell module version
Get-Module Microsoft.Online.SharePoint.PowerShell -ListAvailable | Select-Object Name, Version

# 2. Connect (interactive/MFA only — no -Credential support for these cmdlets)
Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com"

# 3. Check tenant-wide agent sharing + Knowledge Agent scope
Get-SPOTenant | Select-Object KnowledgeAgentScope, KnowledgeAgentExcludedSiteIds, `
    DelegateRestrictedContentDiscoverabilityManagement

# 4. Check whether the site is flagged RCD (kills the Agent icon entirely)
Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" |
    Select-Object Url, RestrictContentOrgWideSearch

# 5. Check pay-as-you-go / promo agent access (non-Copilot-licensed users)
Get-SPOCopilotPromoOptInStatus
```

| Result | Meaning | Action |
|---|---|---|
| No "Ask a question" / Agent icon on the site at all | `RestrictContentOrgWideSearch` (RCD) is `$true` on the site — RCD disables the Agent icon site-wide, not just search | Go to Fix 1 |
| Icon present but agent gives generic/empty answers | User lacks permission to the underlying files, or the agent's source library changed and wasn't re-indexed yet | Go to Fix 2 |
| "Sources limit exceeded. The maximum number of sources you can add is 20." | Custom agent creation — hard cap, not a bug | Go to Fix 3 |
| Non-Copilot-licensed user can't create/use an agent | No pay-as-you-go metered billing enabled for SharePoint agents, and any earlier promo/trial access opted out or expired | Go to Fix 4 |
| Agent visible in Microsoft 365 admin center → Copilot Control System → Agents, but org can't stop it being shared further | Org-wide agent sharing setting is still "All users" | Go to Fix 5 |
| Knowledge Agent absent from a specific site | `KnowledgeAgentScope` is `ExcludeSelectedSites`/`NoSites`, or the site is in `KnowledgeAgentExcludedSiteIds` | Go to Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
M365 Copilot licence (per user)         ──OR──   Pay-as-you-go metered billing enabled for SharePoint agents
    │                                                   (lets non-Copilot-licensed users create/use agents,
    │                                                    billed per message; superseded the Jan-Jun 2025 free promo)
    ▼
Entra ID role: SharePoint Administrator / Site Owner or Edit permission (for custom agent creation)
    ▼
Site-level gates
    - RestrictContentOrgWideSearch (RCD) = $false   → Agent icon exists on the site at all
    - Site/library is NOT itself excluded from indexing
    ▼
Agent type in use
    - Ready-made agent   — auto-created per site/library; scope = current site + associated hub sites
    - Custom agent       — user-selected sources, max 20 items, edit permission required to create
    - Knowledge Agent    — governed separately by KnowledgeAgentScope (AllSites/ExcludeSelectedSites/NoSites)
    ▼
Underlying permission model (same as Copilot, not separate)
    - Agent responses are filtered per-requesting-user SharePoint permissions at query time
    - Agent can never surface content the asking user couldn't already open directly
    ▼
Tenant-wide oversight surface
    - Microsoft 365 admin center → Copilot Control System (formerly Integrated Apps) → Agents
      (view usage, disable specific agents, control org-wide sharing: All users / specific users-groups / none)
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the Agent icon issue isn't actually RCD**
```powershell
Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" |
    Select-Object RestrictContentOrgWideSearch
```
Expected: `False` if agents should be available on this site.
Bad: `True` → RCD is on. This is the single most common "agents disappeared" ticket — RCD was toggled for a search/oversharing reason and nobody realized it also kills the Agent icon site-wide. See `Advanced-Management-B.md` for RCD-specific troubleshooting.

**Step 2 — Confirm the requesting user actually has permission to the sources**
```powershell
Get-SPOUser -Site "https://<tenant>.sharepoint.com/sites/<sitename>" -LoginName "<user@domain.com>"
```
Expected: user has at least Read on the site/library the agent draws from.
Bad: no permission entry → the agent isn't broken, it's correctly refusing to surface content the user can't see. This is by design, not a bug — do not attempt to "fix" the agent to bypass it.

**Step 3 — Confirm source count for a failing custom agent build**
```
Count the files/pages selected before "Create an agent" was clicked.
```
Expected: 20 or fewer.
Bad: more than 20 → hard platform limit, not configurable. Split into multiple agents or point the agent at a single library instead of individual files.

**Step 4 — Confirm licensing/metering path for a non-Copilot user**
```powershell
Get-SPOCopilotPromoOptInStatus
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -like "*COPILOT*" }
```
Expected: user has a Copilot SKU assigned, **or** pay-as-you-go metered billing is enabled for the tenant.
Bad: neither — user has no path to agent creation/use regardless of site permissions.

**Step 5 — Confirm Knowledge Agent scope**
```powershell
Get-SPOTenant | Select-Object KnowledgeAgentScope, KnowledgeAgentExcludedSiteIds
```
Expected: `AllSites` (or the target site not present in `KnowledgeAgentExcludedSiteIds` if scope is `ExcludeSelectedSites`).
Bad: `NoSites`, or the site ID present in the exclusion list → Knowledge Agent is deliberately off for this site/tenant.

---
## Common Fix Paths

<details><summary>Fix 1 — Agent icon missing because of Restricted Content Discovery</summary>

**Symptom:** No ready-made agent, no "create an agent" option, and users can't add the site's content to any other agent either.

**Cause:** RCD (`RestrictContentOrgWideSearch`) disables all agent-related features on the site, not just tenant-wide search visibility — this is documented, expected behaviour, and is frequently set for a search-oversharing reason without anyone realizing the agent-icon side effect.

```powershell
# Confirm
Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" | Select-Object RestrictContentOrgWideSearch

# If the business genuinely wants agents disabled here, this is not a bug — communicate that.
# If agents SHOULD be available, turn RCD off:
Set-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" -RestrictContentOrgWideSearch $false
```

**Rollback:**
```powershell
Set-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" -RestrictContentOrgWideSearch $true
```

</details>

<details><summary>Fix 2 — Agent gives empty or generic answers</summary>

**Symptom:** Agent responds but doesn't seem to know anything about the site/library content.

**Cause (in order of likelihood):** (1) requesting user lacks permission to the underlying files — agents never bypass SharePoint permissions, (2) source files were recently moved/deleted/renamed and the agent's index hasn't caught up, (3) the library the ready-made agent draws from doesn't yet have enough indexed content.

```powershell
# Confirm the user's actual permission on the site
Get-SPOUser -Site "https://<tenant>.sharepoint.com/sites/<sitename>" -LoginName "<user@domain.com>"

# If files moved recently, allow standard search re-crawl time (minutes to a few hours for small libraries)
```

**Fix:** Grant the missing permission if the user is legitimately supposed to have access, or explain that generic answers are expected when there's genuinely nothing to ground on yet. Do not treat this as an agent malfunction if the permission check fails — that's the access model working correctly.

**Rollback:** N/A — permission grants are the fix; no destructive change was made.

</details>

<details><summary>Fix 3 — "Sources limit exceeded" creating a custom agent</summary>

**Symptom:** Error creating a custom agent: "Sources limit exceeded. The maximum number of sources you can add is 20."

**Cause:** Hard platform limit — custom agents in SharePoint cannot reference more than 20 individual items (files/pages).

**Fix:** Point the agent at the containing library/folder as a single source instead of selecting files individually, or split the use case into two or more agents each under the 20-item cap.

**Rollback:** N/A — not a config issue.

</details>

<details><summary>Fix 4 — Non-Copilot-licensed user can't create or use an agent</summary>

**Symptom:** User without an M365 Copilot licence gets blocked from agent creation/use.

**Cause:** The Jan 6 – Jun 30, 2025 promotional trial (10,000 free queries/month for tenants with 50+ Copilot licences) has ended. Ongoing non-Copilot access now requires **pay-as-you-go metered billing** for SharePoint agents to be explicitly enabled — it is not on by default.

```powershell
# Check current promo/trial opt-in state (legacy — may already show disabled/expired)
Get-SPOCopilotPromoOptInStatus

# Pay-as-you-go enablement is configured in the Microsoft 365 admin center
# (Billing > Your products > Pay-as-you-go services), not via this cmdlet
```

**Fix:** Either assign the user a Copilot licence, or have someone with Billing admin rights enable pay-as-you-go metered billing for SharePoint agents in the M365 admin center. Confirm with the business owner before enabling metered billing — it has a direct cost impact per message.

**Rollback:**
```powershell
Set-SPOCopilotPromoOptInStatus -IsCopilotPromoStatusEnabled $false
```
(This only affects the legacy promo mechanism, not pay-as-you-go billing, which is disabled from the admin center billing page.)

</details>

<details><summary>Fix 5 — Can't restrict who agents get shared with</summary>

**Symptom:** Agents built by one user are ending up visible to people who shouldn't have them, and there's no obvious per-agent control.

**Cause:** Org-wide agent sharing defaults to "All users" in the Microsoft 365 admin center, independent of the underlying site/file permissions the agent itself respects.

```
1. Microsoft 365 admin center > Settings > Integrated apps > Agents
   (also reachable via Copilot Control System)
2. Locate the org-wide sharing control
3. Change from "All users" to "Specific users or groups" or "No users" (disables org-wide sharing entirely)
```

**Fix:** Tighten the sharing scope to the specific users/groups who should be able to receive shared agents. Note this controls *sharing of the agent itself*, not what data the agent can see — permission-based content filtering still applies underneath regardless of this setting.

**Rollback:** Revert the admin center setting back to "All users" if the change breaks a legitimate cross-team workflow.

</details>

<details><summary>Fix 6 — Knowledge Agent missing from a site</summary>

**Symptom:** Knowledge Agent features (summarization, metadata extraction, content-hygiene suggestions) aren't available on a specific site, though other agent features work.

**Cause:** `KnowledgeAgentScope` is set to `ExcludeSelectedSites` with this site's ID listed, or `NoSites` tenant-wide.

```powershell
# Check current scope and exclusions
Get-SPOTenant | Select-Object KnowledgeAgentScope, KnowledgeAgentExcludedSiteIds

# Enable tenant-wide
Set-SPOTenant -KnowledgeAgentScope AllSites

# Or remove a specific site from the exclusion list (requires rebuilding the full list —
# there is no single "remove one site" switch)
Set-SPOTenant -KnowledgeAgentScope ExcludeSelectedSites -KnowledgeAgentExcludedSiteIds "<comma-separated-guids-minus-the-target>"
```

**Rollback:**
```powershell
Set-SPOTenant -KnowledgeAgentScope NoSites
```

</details>

---
## Escalation Evidence

```
ESCALATION TICKET — Agents in SharePoint Issue
=================================================================
Date/Time:                _______________
Raised by:                _______________
Severity:                 _______________

AGENT TYPE AFFECTED
  [ ] Ready-made agent (site/library default)
  [ ] Custom agent (user-built, source-selected)
  [ ] Knowledge Agent
  [ ] Other: _______________

LICENSING
  Requesting user has M365 Copilot licence:      Yes / No
  Pay-as-you-go metered billing enabled (tenant): Yes / No
  Legacy promo opt-in status (Get-SPOCopilotPromoOptInStatus): _______________

SITE / TENANT DETAILS
  Tenant admin URL:               _______________
  Affected site URL(s):           _______________
  RestrictContentOrgWideSearch (RCD) value: _______________
  KnowledgeAgentScope value:       _______________

USER PERMISSION CHECK
  Get-SPOUser output (permission level on affected site): _______________
  Confirmed user can open the underlying files directly (outside the agent): Yes / No

SYMPTOM DETAIL
  Exact error text (if any):      _______________
  Source count (if custom agent creation failure): _______________
  When did this last work correctly: _______________

PREVIOUS STATE
  Recent changes (RCD toggle, licence changes, KnowledgeAgentScope changes): _______________
```

---
## 🎓 Learning Pointers

- **Agents never bypass SharePoint permissions.** Every agent type — ready-made, custom, or Knowledge Agent — filters responses per the requesting user's existing access at query time. If a "broken agent" ticket turns out to be a missing permission, that's the system working as designed, not a defect. See [Frequently asked questions about Copilot in SharePoint](https://support.microsoft.com/en-us/office/frequently-asked-questions-about-copilot-in-sharepoint-eb1b7668-3d98-4a93-98ef-f0c6dfc694f0).

- **RCD kills the Agent icon entirely, not just search visibility.** A site flagged for Restricted Content Discovery loses the Agent icon from its global header — teams sometimes set RCD purely for search-oversharing reasons and are surprised agents vanish too. See [Manage access to agents in SharePoint](https://learn.microsoft.com/en-us/sharepoint/manage-access-agents-in-sharepoint).

- **The 20-source limit on custom agents is a hard cap, not a licence tier.** Point agents at whole libraries instead of individually-selected files when a use case needs broader coverage. See [Create an agent in SharePoint](https://support.microsoft.com/en-us/sharepoint/copilot-in-sharepoint/create-an-agent-in-sharepoint).

- **The free agent promo period ended June 30, 2025.** Ongoing access for non-Copilot-licensed users now runs through pay-as-you-go metered billing, which has to be explicitly enabled and carries a per-message cost — confirm the business owner has approved this before turning it on. See [Manage trial agents in SharePoint by using PowerShell](https://learn.microsoft.com/sharepoint/manage-trial-agents-sharepoint-powershell).

- **Org-wide agent sharing and content permissions are two separate controls.** Tightening "who can receive shared agents" in the admin center does not change what data an agent can surface — that's still governed entirely by the underlying SharePoint permissions. See [Share and manage agents built with Microsoft 365 Copilot](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/agent-builder-share-manage-agents).

- **Knowledge Agent and ready-made agents are governed by separate settings.** `KnowledgeAgentScope` controls Knowledge Agent independently of RCD and independently of the ready-made/custom agent icon — don't assume one setting covers both. See [Get started with Knowledge Agent](https://learn.microsoft.com/en-us/sharepoint/knowledge-agent-get-started).
