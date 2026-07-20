# Microsoft Sentinel Hunting (Queries, Bookmarks & Hunts) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

> **Scope note:** Covers the analyst-driven, manual/semi-automated hunting workflow in Microsoft Sentinel — the hunting query library (**Queries** tab), **Bookmarks**, the end-to-end **Hunts (Preview)** wrapper, MITRE ATT&CK-driven query discovery, and the paths from a hunting finding to an analytics rule or incident. Also covers **KQL jobs** specifically as the retired-livestream replacement mechanism. Does not cover: scheduled/NRT/Anomaly analytics rule authoring itself (see `AnalyticsRules-A.md`), UEBA's baselining/scoring internals (see `UEBA-A.md` — hunting *consumes* UEBA entity data via the Entities tab and bookmark entity mapping, it doesn't produce it), SOAR/playbook automation (`LogicAppsPlaybooks-A.md`), Jupyter/MSTICPy notebook-based hunting, or the broader Microsoft Sentinel data lake architecture beyond KQL jobs (federated tables, data lake onboarding mechanics, notebooks-on-the-lake) — all flagged as candidate future topics, not covered here.

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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

Assumes a working Microsoft Sentinel deployment on a Log Analytics workspace with at least one active data connector already ingesting (see `DataConnectors-A.md`) — hunting queries have nothing to run against otherwise. Assumes the reader has Microsoft Sentinel Reader-or-higher for running queries and viewing bookmarks, Microsoft Sentinel Contributor (or a custom role scoped to `Microsoft.SecurityInsights/hunts`) for creating/managing Hunts, and appropriate Log Analytics workspace RBAC for KQL job creation against the Sentinel data lake. Hunting queries, bookmarks, and Hunts are included with Sentinel at no extra licensing cost beyond normal ingestion/retention billing; the Sentinel data lake (which KQL jobs depend on) is a separate, additionally-onboarded capability with its own billing model, not assumed to be already configured.

**Portal duality is the single most load-bearing fact in this topic, more than in most others in this repo.** After **March 31, 2027**, Microsoft Sentinel is Defender-portal-only. Unlike most other Sentinel capabilities where the Azure-portal-vs-Defender-portal difference is cosmetic or involves Preview-only data sources, **bookmark creation itself is Azure-portal-only** — the Defender portal can only view bookmarks that were already created elsewhere. This is not a Preview limitation being phased out; it is the current, documented state of a core hunting workflow step, and it has a hard collision course with the 2027 retirement date that has not yet been resolved in public documentation as of this writing (mid-2026). Treat this as a standing operational constraint for any client migrating fully to the Defender portal, not a temporary rough edge.

---
## How It Works

<details><summary>Full architecture: from a raw hunting query to an incident or analytics rule</summary>

**The three layers of the hunting surface, from simplest to most structured:**

| Layer | What it is | Where it lives | Persistence |
|---|---|---|---|
| **Hunting queries** | A library of KQL queries — Content Hub-installed (solution-bundled) or custom/authored — tagged with MITRE ATT&CK tactics/techniques | **Queries** tab under Hunting | Query definitions persist in the workspace; results are ephemeral unless bookmarked or promoted to a job/rule |
| **Bookmarks** | A saved snapshot of specific query result rows, with notes, tags, entity mappings, and MITRE mappings | **Bookmarks** tab under Hunting; underlying `HuntingBookmark` table | Persisted rows in Log Analytics, subject to normal retention |
| **Hunts (Preview)** | An end-to-end, hypothesis-driven investigation wrapper around cloned queries, bookmarks, entities, and comments, with status/metrics tracking | **Hunts (Preview)** tab under Hunting | Hunt metadata + its own cloned query/bookmark set persist independently of the global library |

**Hunting queries — the library.** Every hunting query, whether installed from a Content Hub solution or authored by an analyst, appears on the **Queries** tab. Each entry shows: a description of what it hunts for, the data source(s) it requires, its MITRE ATT&CK tactic/technique tags, a **Results** count (or **N/A** if the required data source isn't connected), and a **Results delta** — the change in result count over the trailing 24-48 hours, which is the fastest way to spot something newly active without reading every query's output line by line. Queries can be run individually, as a selected subset, or all at once ("Run all queries"), with runtime scaling from seconds to many minutes depending on volume and time range selected.

Custom queries are created or cloned directly from the Queries tab and can be saved either privately (visible only to the author) or shared tenant-wide — this save-scope choice is the single most common reason a newly-authored query "disappears" for everyone except its creator.

**Bookmarks — the annotation layer.** A bookmark preserves a specific set of query result rows plus the query that produced them, along with analyst-added tags and notes. Bookmarks inherit entity mappings and MITRE ATT&CK mappings from their source query by default but can be edited independently. Once mapped to at least one entity, a bookmark becomes visible in the investigation graph and links directly to the corresponding UEBA entity page (see `UEBA-A.md` for what that page shows). Bookmarks can be escalated directly to a new or existing incident from the Bookmarks tab.

**Critically, bookmark creation is gated to the Azure portal only.** The Defender portal shows existing bookmarks (read-only) but has no "Add bookmark" affordance in its Logs/hunting results experience. This asymmetry doesn't apply to the Hunts (Preview) experience's own in-hunt bookmark creation flow the same way — Hunts is described as available in both portals with its own "Add bookmark" step inside a hunt's query results — but the standalone global Bookmarks tab workflow described in Microsoft's own bookmarks documentation is explicitly scoped "Azure portal only" for the *creation* action. In practice, MSPs should verify current behavior against both portals for the specific Sentinel version a client is on, since this exact boundary is one of the areas Microsoft has been actively adjusting as the Defender-portal migration progresses.

The underlying `HuntingBookmark` table in Log Analytics is worth knowing directly: it supports at most 1,000 bookmarks visible in the UI tab, uses a soft-delete pattern (`SoftDelete = true` on the latest row rather than physical deletion — `arg_max(TimeGenerated, *) by BookmarkId` is the correct way to get current state per bookmark), and has a documented propagation delay of "several minutes" between bookmark creation and its appearance in the Bookmarks tab UI (though the table row itself can be queried sooner).

**Hunts (Preview) — the structured workflow wrapper.** A Hunt exists to give a hypothesis-driven investigation a persistent home: a name, description, hypothesis state (validating/validated/invalidated), and overall hunt status (new/active/closed), with its own Queries, Bookmarks, Entities, and Comments tabs. Two creation paths exist: (1) select queries from the global Queries tab first, then **Hunt actions → Create new hunt**, which clones the selected queries into the new hunt; or (2) start from the **Hunts (Preview)** tab's **New Hunt** button with no preselected queries, adding them later.

**The queries inside a Hunt are clones — independent copies, not live references.** Editing a query inside a Hunt does not change the shared global Queries tab version, and editing the global version after cloning does not retroactively update hunts that already cloned it. Each Hunt's Queries tab also supports a **"Create analytics rule"** context-menu action distinct from the same action available on the global Queries tab — both prepopulate a new analytics rule's name, description, and KQL from whichever copy the action was invoked against, and either path links the resulting rule back under that Hunt's **Related analytics rules** for traceability.

A Hunt's **Entities** tab auto-resolves and deduplicates entities collected across all of that hunt's bookmarks, linking each one to its UEBA entity page and exposing entity-type-specific right-click actions (e.g., adding an IP to threat intelligence, running an entity-specific playbook). The **metrics bar** at the top of the Hunts tab tracks validated hypotheses, incidents created, and analytics rules created — the closest thing this feature has to an ROI dashboard for a hunting program, useful for MSPs justifying dedicated hunting time to a client.

**MITRE ATT&CK-driven discovery.** Beyond browsing the Queries tab directly, the **MITRE ATT&CK (Preview)** page can filter to show which techniques currently have associated hunting queries (via the **Simulated** filter's **Hunting queries** option), providing a systematic way to find and close detection/hunting-coverage gaps by technique rather than by keyword search.

**Livestream retirement and its replacement, KQL jobs.** Microsoft Sentinel livestreams — the previous mechanism for running a query on a recurring basis and pushing near-real-time notifications — are fully retired. This is a platform-wide removal, not a per-tenant or per-license toggle, and there is no "still available for legacy customers" exception documented. The stated replacements are **KQL jobs**, **analytics rules**, and **playbooks**, but these are not interchangeable with what livestream did:

- **KQL jobs** (part of the separate Microsoft Sentinel *data lake* architecture) run a KQL query once or on a schedule and **persist the results to a table** — they promote data, they do not alert. A KQL job with no analytics rule or playbook watching its output table is a silent data pipeline, not a notification mechanism.
- **Analytics rules** (Scheduled or NRT) are the correct replacement for "alert me when this query returns new results" — see `AnalyticsRules-A.md`.
- **Playbooks** handle the "send a Teams/email message" half of what livestream's downstream integrations did, but need to be triggered from somewhere (an analytics rule's automation rule, typically) — see `LogicAppsPlaybooks-A.md`.

KQL jobs run against the Sentinel **data lake tier** and/or **federated tables**, writing output either back into the data lake tier (tables suffixed `_KQL` when targeting System tables) or promoted up into the **analytics tier** (tables suffixed `_KQL_CL`), which costs more to store but is queryable in the same near-real-time way as any other analytics-tier table. Promoting only the columns and rows actually needed (via `project`/`where` in the job's own query) is the documented cost-control lever, mirroring the general Log Analytics ingestion-cost discipline used elsewhere in this repo.

Job creation requires the tenant already onboarded to the Sentinel data lake (a separate, non-default prerequisite) and one of the supported Entra ID roles for tenant-wide data lake read/write, or — for writing into a *new* table in the analytics tier specifically — the data lake's own system-assigned managed identity (named `msg-resources-<guid>`) must separately hold **Log Analytics Contributor** on the destination workspace. This managed-identity-permission step is easy to miss because it's not part of the job-creation wizard itself; it's a one-time IAM grant made in the Azure portal against a resource whose name isn't obviously connected to "KQL jobs" at first glance.

</details>

---
## Dependency Stack

```
[Log Analytics workspace with Microsoft Sentinel enabled]
    └── [Data connector(s) ingesting source tables]                    ← DataConnectors-A.md
            └── [Hunting query targets a table with data]
                    ├── Content Hub solution installed  → out-of-the-box queries appear
                    └── Custom query authored            → saved SHARED (not private) to be visible tenant-wide
                            └── [Query run: individually / selected subset / all]
                                    └── [Results reviewed in Log Analytics "Logs" pane]
                                            ├── AZURE PORTAL: "Add bookmark" available
                                            │       └── HuntingBookmark table row (soft-delete pattern,
                                            │           several-minute propagation delay to the UI tab,
                                            │           1,000-row UI cap — query the table directly beyond that)
                                            │               ├── entity mapping → investigation graph + UEBA entity page
                                            │               ├── MITRE ATT&CK mapping (inherited, editable)
                                            │               └── Incident actions → new/existing incident
                                            │
                                            └── DEFENDER PORTAL: bookmark creation NOT available (view-only)
                                            │
                                            └── "New alert rule" > "Create Microsoft Sentinel alert"
                                                    └── Analytics rule wizard, KQL prepopulated       ← AnalyticsRules-A.md

[Hunts (Preview) — optional structured wrapper, both portals]
    └── RBAC: Microsoft Sentinel Contributor, or custom role on Microsoft.SecurityInsights/hunts
            └── Hunt created (from preselected queries, or blank)
                    └── Queries CLONED into the hunt — independent of global library, no two-way sync
                            └── Hunt's own Queries / Bookmarks / Entities / Comments tabs
                                    ├── "Create analytics rule" from a hunt query uses the CLONE
                                    ├── Entities tab auto-dedupes entities from hunt's bookmarks
                                    └── Hypothesis/status tracked → feeds the Hunts tab metrics bar

[KQL jobs — livestream replacement, separate data lake architecture]
    └── Tenant onboarded to Microsoft Sentinel data lake              ← non-default prerequisite
            └── Entra ID data-lake role (tenant-wide), AND/OR
                Log Analytics Contributor granted to msg-resources-<guid>
                managed identity on the destination workspace (for new analytics-tier tables)
                    └── Job created — one-time or scheduled
                            ├── limits: 100 enabled jobs/tenant, 5 concurrent executions/tenant,
                            │           1-hour query timeout (partial results promoted on timeout)
                            ├── unsupported in job KQL: adx(), arg(), externaldata(),
                            │   ingestion_time(), user-defined functions
                            └── ~15-minute data lake ingestion latency before output is queryable
                                    └── Output table populates (_KQL_CL analytics tier / _KQL data lake tier)
                                            └── Does NOT alert on its own — pair with an analytics rule
                                                reading the output table, or a playbook, for notification
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| "Add bookmark" button missing or non-functional | Working in the Defender portal — bookmark creation is Azure-portal-only | Which portal URL is open |
| Livestream missing from the Hunting page entirely | Full platform-wide retirement, not a per-tenant setting | Confirm against `hunting` overview doc's retirement note — not a config issue |
| Custom hunting query invisible to other analysts | Saved as private/"my queries" rather than shared | Reopen query's save dialog, check scope |
| Bookmark created but absent from the Bookmarks tab | Propagation delay (several minutes, sometimes longer) | Query `HuntingBookmark` table directly for the row |
| Only ~1,000 bookmarks visible in the Bookmarks tab despite more existing | Documented UI display cap | Query `HuntingBookmark` table for the full set |
| "Create analytics rule" prepopulates stale/unexpected KQL | Promoted from a Hunt's cloned query copy, not the global shared version (or vice versa) | Confirm which Queries tab (global vs. in-hunt) the action was invoked from |
| Hunting query permanently shows N/A results | Required data source/table never connected | Hover the (i) icon next to the N/A result; check `DataConnectors-A.md` |
| Query returns 0 results but data source is connected | Legitimate zero — the behavior the query hunts for simply hasn't occurred; not every query is expected to have hits | Confirm against Results Delta trend, not a single point-in-time run |
| "Insufficient permissions" creating/editing a Hunt | Missing Microsoft Sentinel Contributor or custom `Microsoft.SecurityInsights/hunts` RBAC | Check role assignment on the workspace/subscription |
| KQL job creation fails with a permissions error | Data lake managed identity (`msg-resources-<guid>`) lacks Log Analytics Contributor on destination workspace, or tenant never onboarded to the data lake | `Get-AzRoleAssignment` against the managed identity; confirm data lake onboarding status |
| KQL job runs successfully but destination table stays empty | Query uses an unsupported operator (`adx()`, `arg()`, `externaldata()`, `ingestion_time()`, UDFs), or schema mismatch when appending to an existing table | Re-review the job's KQL against the documented unsupported-operator list; check schema alignment |
| KQL job results look "incomplete" for a large query | Job hit the 1-hour execution timeout — partial results are promoted, not a failure | Check job run history/duration; narrow the query's time range or filter earlier |
| Scheduled KQL job's results are consistently missing the most recent few minutes of data | Expected — ~15-minute data lake ingestion latency; job's own lookback/delay parameters should already account for this | Confirm the job query includes a `delay` buffer per Microsoft's documented pattern |
| Analyst expects a KQL job to send a notification and nothing happens | KQL jobs only persist data — they have no built-in alerting; this is a misunderstanding of the livestream replacement, not a fault | Confirm an analytics rule or playbook is separately watching the job's output table |

---
## Validation Steps

**1. Confirm the portal in use before troubleshooting anything bookmark-related**
```
Azure portal: portal.azure.com → Microsoft Sentinel → Threat management → Hunting
Defender portal: security.microsoft.com → Microsoft Sentinel → Threat management → Hunting
```
Good: analyst confirms Azure portal for any bookmark-creation task. Bad: analyst insists bookmark creation "isn't working" while in the Defender portal — this is expected behavior, not a defect, resolved by switching portals.

**2. Confirm the hunting query's data source is connected**
```kusto
<TableName>
| where TimeGenerated > ago(1d)
| take 1
```
Good: at least one row returned. Bad: zero rows — the query will always show N/A regardless of how it's written; this is a connector problem, not a query problem.

**3. Confirm bookmark write and propagation**
```kusto
HuntingBookmark
| where TimeGenerated > ago(1h)
| summarize arg_max(TimeGenerated, *) by BookmarkId
| where SoftDelete == false
| project TimeGenerated, BookmarkId, DisplayName, CreatedBy
```
Good: row appears within a few minutes of creation. Bad: no row after 15+ minutes with a confirmed Azure-portal creation attempt — treat as a genuine fault.

**4. Confirm shared vs. private scope for a custom query**
```
Queries tab → locate query → reopen save dialog → check sharing scope field
```
Good: scope set to shared/tenant-visible. Bad: scope set to private when the intent was team-wide visibility.

**5. Confirm which query copy an analytics rule was promoted from**
```
If issue reported: compare the rule's KQL against BOTH the global Queries tab version
AND (if applicable) the specific Hunt's cloned version, to identify which was actually used.
```
Good: rule's KQL matches the intended source. Bad: rule's KQL matches the "wrong" copy (stale hunt clone vs. updated global version, or vice versa).

**6. Confirm Hunt RBAC before troubleshooting a permissions error as something else**
```powershell
Get-AzRoleAssignment -Scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace>" |
  Where-Object { $_.RoleDefinitionName -like "*Sentinel*" }
```
Good: analyst holds Microsoft Sentinel Contributor or a custom role with `Microsoft.SecurityInsights/hunts` permissions. Bad: only Sentinel Reader present — Hunts creation/management will fail.

**7. Confirm data lake managed identity permissions before troubleshooting a KQL job as a query-syntax problem**
```powershell
Get-AzRoleAssignment -ResourceGroupName "<rg>" | Where-Object { $_.DisplayName -like "msg-resources-*" }
```
Good: `Log Analytics Contributor` assignment present for the `msg-resources-<guid>` identity scoped to the destination workspace. Bad: no assignment found — job creation targeting a new analytics-tier table will fail regardless of how correct the KQL is.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Establish which capability is actually broken.** "Hunting doesn't work" is too broad a starting symptom — first determine whether the report is about the query library (N/A results, missing queries), bookmarks (creation, visibility, or the tab display), a Hunt (creation, RBAC, cloned-query confusion), or a KQL job (creation, permissions, or the "why didn't it notify me" livestream-replacement misunderstanding). Each has a distinct root-cause tree below.

**Phase 2 — For query-library issues, isolate data-source connectivity from query authorship.** Confirm the underlying table has any data at all (Validation Step 2) before assuming the query itself is broken — a perfectly correct KQL query against a disconnected data source will always show N/A, and no amount of query editing fixes that.

**Phase 3 — For bookmark issues, confirm portal first, then propagation timing, then the UI display cap.** In that order — most "bookmark broken" tickets resolve at the portal check alone.

**Phase 4 — For Hunt issues, separate RBAC failures from clone-vs-global confusion.** A permissions error on Hunt creation/access is a straightforward RBAC grant (Validation Step 6). An "unexpected KQL" or "my edit didn't apply everywhere" report is architectural, not a permissions issue — explain the clone model rather than searching for a sync bug that doesn't exist.

**Phase 5 — For KQL job issues, check data lake onboarding and managed identity permissions before touching the query.** A job that fails to create, or creates but never writes data, is far more often a missing prerequisite (data lake onboarding, managed identity role) than a KQL syntax error — the supported/unsupported operator list is short and worth a quick manual check, but permissions issues are the more common real-world cause per this topic's Microsoft Learn source material.

**Phase 6 — For "livestream replacement doesn't alert me" reports, correct the underlying expectation.** This is not a technical fault to fix — it's a workflow redesign conversation. Route the analyst/client to the correct combination of KQL job (persistence) + analytics rule (alerting) + playbook (notification/response) for their specific use case, per the table in How It Works above.

---
## Remediation Playbooks

<details>
<summary>Playbook 1 — Standing up a baseline hunting program for a new client (greenfield)</summary>

1. Confirm at least the client's highest-value data connectors are active and ingesting (`DataConnectors-A.md`).
2. Install relevant Content Hub solutions for the client's stack to populate the Queries tab with out-of-the-box, MITRE-tagged hunting queries.
3. Run **Run all queries** once to establish a baseline of which queries return results (vs. N/A) — use this to prioritize which additional data connectors are worth onboarding next.
4. Set up a recurring cadence (documented guidance: at least weekly) for an analyst to review Results Delta and investigate spikes.
5. For any finding worth escalating, use Add bookmark (**Azure portal**) → map entities and MITRE technique → either promote directly to an analytics rule if it's a repeatable pattern, or escalate to an incident if it's a one-off active concern.
6. Optionally wrap ongoing investigation threads in a Hunt for tracking and metrics, especially for MSP engagements where "hours spent hunting, findings validated" needs to be reportable to the client.

**Rollback:** N/A — this is additive configuration; disabling a Content Hub solution later doesn't retroactively remove already-run query history or bookmarks.
</details>

<details>
<summary>Playbook 2 — Migrating a livestream-dependent workflow to its replacement</summary>

1. Inventory what the retired livestream was actually doing for the client: was it (a) persisting results for later analysis, (b) alerting on new matches, (c) pushing notifications to Teams/email, or some combination?
2. For (a): create a scheduled **KQL job** targeting the same source query, writing to a new or existing analytics-tier table. Confirm data lake onboarding is complete and the `msg-resources-<guid>` managed identity holds Log Analytics Contributor on the destination workspace before creating the job.
3. For (b): convert the query into a **Scheduled** or **NRT analytics rule** instead — see `AnalyticsRules-A.md` for rule-kind selection guidance.
4. For (c): attach a **playbook** to the analytics rule's automation rule (not to the KQL job, which cannot trigger playbooks directly).
5. Validate end-to-end: confirm the KQL job's output table populates (if used), confirm the analytics rule fires on a test/known-positive condition, and confirm the playbook's notification actually arrives.
6. Document for the client that this is now two or three separate constructs doing what one livestream used to do — set expectations that "why did the notification stop" tickets from this migration are a real risk if any one leg (rule vs. job vs. playbook) is later disabled independently without the others being reconsidered.

**Rollback:** delete the KQL job/analytics rule/automation rule individually if any prove unnecessary — each is independent and removing one doesn't affect the others.
</details>

<details>
<summary>Playbook 3 — Fleet-wide hunting-coverage audit across MSP client tenants</summary>

1. For each client workspace, run the audit script below (`Get-SentinelHuntingAudit.ps1`) to capture bookmark activity levels, soft-delete ratios, and Hunt usage.
2. Cross-reference against the MITRE ATT&CK (Preview) page's **Simulated → Hunting queries** filter per tenant to identify techniques with zero associated hunting query coverage.
3. Flag tenants with zero bookmark activity in the trailing 30 days as either (a) genuinely not using the hunting workflow — a conversation about whether it's a value-add worth activating, or (b) using it exclusively via the Defender portal in a way that masks bookmark creation attempts that are silently failing (Fix 1 in the Mode B runbook) — worth a direct portal check before assuming (a).
4. For any client relying on livestream-era automation that hasn't yet been migrated (Playbook 2), flag explicitly — this is a platform retirement, not an optional upgrade, and gaps here represent a genuine notification blind spot for the client.

**Rollback:** N/A — read-only audit.
</details>

<details>
<summary>Playbook 4 — Retrofitting Hunts (Preview) onto an existing ad-hoc hunting practice</summary>

1. Identify recent, still-relevant informal hunting threads (Slack/Teams discussions, saved private queries, loose bookmarks not yet tied together).
2. Create a Hunt per active investigation thread via **Hunts (Preview) → New Hunt**, using the description field to capture the working hypothesis.
3. Add the relevant existing hunting queries to the hunt (they'll be cloned — original global-library versions are unaffected).
4. Re-bookmark relevant findings inside the hunt context (existing bookmarks made outside a hunt are not automatically pulled in) so the hunt's Entities tab and metrics correctly reflect the investigation.
5. Set hypothesis/status fields going forward so the metrics bar starts producing meaningful, reportable numbers for the client relationship.

**Rollback:** deleting a Hunt removes the hunt wrapper and its cloned query copies; it does not delete bookmarks that were already promoted to an incident, or analytics rules already created from it.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects Microsoft Sentinel hunting-workflow evidence for escalation or MSP fleet review.
.DESCRIPTION Read-only. Queries HuntingBookmark table health, RBAC assignments relevant to Hunts,
             and the data lake managed identity's role assignment relevant to KQL jobs. Does NOT
             read hunting query definitions, Hunt metadata, or KQL job definitions directly — none
             of those have a public Az PowerShell/KQL surface; capture those via portal screenshot
             (Hunting > Queries tab, Hunts (Preview) tab, Data lake exploration > Jobs) alongside
             this script's output when escalating.
.NOTES       Requires: Az.Accounts, Az.OperationalInsights, Az.Resources modules; a Log Analytics
             Contributor-or-Reader connection to the target workspace for the KQL portion.
#>
param(
    [Parameter(Mandatory)] [string]$WorkspaceResourceGroup,
    [Parameter(Mandatory)] [string]$WorkspaceName,
    [Parameter(Mandatory)] [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
$ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $WorkspaceResourceGroup -Name $WorkspaceName

Write-Host "=== HuntingBookmark table health (30d) ===" -ForegroundColor Cyan
$bmQuery = @"
HuntingBookmark
| where TimeGenerated > ago(30d)
| summarize arg_max(TimeGenerated, *) by BookmarkId
| summarize Total=count(), Active=countif(SoftDelete==false), Deleted=countif(SoftDelete==true), Analysts=dcount(CreatedBy), LastActivity=max(TimeGenerated)
"@
Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $bmQuery | Select-Object -ExpandProperty Results

Write-Host "=== Sentinel/Hunts-relevant RBAC on this workspace ===" -ForegroundColor Cyan
Get-AzRoleAssignment -Scope $ws.ResourceId | Where-Object { $_.RoleDefinitionName -match "Sentinel|Log Analytics" } |
    Select-Object DisplayName, SignInName, RoleDefinitionName, Scope

Write-Host "=== Data lake managed identity (msg-resources-*) role check ===" -ForegroundColor Cyan
$identityAssignments = Get-AzRoleAssignment -ResourceGroupName $WorkspaceResourceGroup |
    Where-Object { $_.DisplayName -like "msg-resources-*" }
if ($identityAssignments) {
    $identityAssignments | Select-Object DisplayName, RoleDefinitionName, Scope
} else {
    Write-Host "[WARN] No msg-resources-* managed identity role assignment found in this resource group. KQL job creation targeting new analytics-tier tables will fail until Log Analytics Contributor is granted." -ForegroundColor Yellow
}

Write-Host "=== Reminder: capture manually alongside this output ===" -ForegroundColor Yellow
Write-Host "- Hunting > Queries tab: N/A-filtered query list + MITRE ATT&CK coverage view"
Write-Host "- Hunts (Preview) tab: active hunt list, hypothesis/status states"
Write-Host "- Data lake exploration > Jobs: job list, last-run status, destination tables"
```

---
## Command Cheat Sheet

| # | Command | Purpose |
|---|---|---|
| 1 | `HuntingBookmark \| where TimeGenerated > ago(30d) \| summarize count()` | Quick bookmark activity pulse |
| 2 | `HuntingBookmark \| summarize arg_max(TimeGenerated, *) by BookmarkId \| where SoftDelete==false` | Current, non-deleted bookmark state |
| 3 | `<TableName> \| where TimeGenerated > ago(1d) \| take 1` | Confirm a hunting query's data source is live |
| 4 | `search "<term>" \| where TimeGenerated > ago(1d)` | Cross-table quick search during triage |
| 5 | `Get-AzRoleAssignment -Scope <workspaceResourceId>` | Confirm Hunts RBAC on the workspace |
| 6 | `Get-AzRoleAssignment -ResourceGroupName <rg> \| Where-Object { $_.DisplayName -like "msg-resources-*" }` | Confirm data lake managed identity's KQL job permissions |
| 7 | `New-AzRoleAssignment -ObjectId <identityObjectId> -RoleDefinitionName "Log Analytics Contributor" -ResourceGroupName <rg>` | Grant the missing KQL job write permission |
| 8 | `Get-AzOperationalInsightsWorkspace -ResourceGroupName <rg> -Name <workspace>` | Resolve workspace resource ID / customer ID for further queries |
| 9 | `Invoke-AzOperationalInsightsQuery -WorkspaceId <id> -Query <kql>` | Run any KQL from PowerShell for scripted evidence collection |
| 10 | `<JobOutputTable>_KQL_CL \| where TimeGenerated > ago(1d) \| summarize count(), max(TimeGenerated)` | Confirm a KQL job's analytics-tier output is populating |
| 11 | Portal: Hunting > Queries tab > filter Results = N/A | Find hunting queries blocked on a missing data connector |
| 12 | Portal: Hunting > Queries tab > hover (i) next to N/A | Identify exactly which data source a specific query needs |
| 13 | Portal: MITRE ATT&CK (Preview) > Simulated filter > Hunting queries | Find MITRE techniques with zero hunting query coverage |
| 14 | Portal: Data lake exploration > Jobs | View KQL job list, schedule, and last-run status (no PowerShell equivalent) |
| 15 | Portal: Hunts (Preview) tab > metrics bar | View validated-hypothesis / incident / rule-creation counts for the hunting program |

---
## 🎓 Learning Pointers

- **Bookmark creation being Azure-portal-only is a structural gap, not a rough edge, given the March 31, 2027 Defender-portal-only retirement date.** Any client fully committed to the Defender portal today has an unresolved workflow question for this specific step — worth raising proactively in migration planning conversations rather than waiting for an analyst to hit the missing button. [Hunt with bookmarks in Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/bookmarks)
- **"Migrate off livestream" is a one-to-many mapping, not a one-to-one swap.** A single retired livestream might need to become a KQL job (persistence), an analytics rule (alerting), and a playbook (notification) simultaneously depending on what it was actually used for — treating it as a single like-for-like replacement is the most likely source of "the new thing doesn't do what the old thing did" complaints post-migration. [Threat hunting in Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/hunting)
- **A Hunt's queries are independent clones from the moment they're added — there is no ongoing sync in either direction.** This mirrors a broader pattern worth internalizing across Sentinel's newer preview features: "wrapped" or "cloned" content inside a higher-level construct (Hunts here; compare the Hunt-query-vs-global-query split to other clone-not-reference patterns elsewhere in Microsoft's security stack) needs to be checked explicitly, not assumed to inherit edits automatically. [Conduct end-to-end proactive threat hunting](https://learn.microsoft.com/en-us/azure/sentinel/hunts)
- **KQL jobs carry firm, per-tenant capacity limits that don't scale with workspace size or license tier** — 100 enabled jobs and 5 concurrent executions per tenant, a flat 1-hour query timeout regardless of query complexity, and roughly 15 minutes of unavoidable data lake ingestion latency. For an MSP managing many client tenants, these are per-tenant caps, not shared across an aggregated view — plan job allocation accordingly rather than assuming headroom scales with the number of workspaces managed. [Create jobs in the Microsoft Sentinel data lake](https://learn.microsoft.com/en-us/azure/sentinel/datalake/kql-jobs)
- **The data lake managed identity's permission grant (`msg-resources-<guid>` → Log Analytics Contributor) is easy to miss because it isn't part of the KQL job creation wizard itself** — it's a separate, one-time IAM step whose resource name gives no obvious hint that it's related to KQL jobs at all. Worth documenting explicitly in any client's Sentinel data lake onboarding runbook rather than relying on the wizard to surface it. [Create jobs in the Microsoft Sentinel data lake — permissions](https://learn.microsoft.com/en-us/azure/sentinel/datalake/kql-jobs#permissions)
- **Community resource:** the [Microsoft Sentinel Tech Community blog](https://techcommunity.microsoft.com/category/azure-sentinel) has covered both the livestream retirement and early Hunts (Preview) rollout in more practical, example-driven detail than the reference docs alone — useful for real-world query and hunt-structuring patterns beyond what's captured here.
