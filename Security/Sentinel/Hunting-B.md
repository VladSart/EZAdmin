# Microsoft Sentinel Hunting (Queries, Bookmarks & Hunts) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Scope note:** This is about the analyst-driven, manual hunting workflow — the **Queries** tab (hunting query library), **Bookmarks**, and the end-to-end **Hunts (Preview)** wrapper — plus how a hunting finding gets promoted into an analytics rule or incident. It is not about scheduled/NRT/Anomaly analytics rules themselves (`AnalyticsRules-B.md`), UEBA's own baselining/scoring (`UEBA-B.md` — hunting *consumes* UEBA entity data via bookmarks/Entities tab, it doesn't produce it), or SOAR automation (`LogicAppsPlaybooks-B.md`). Jupyter/MSTICPy notebooks and the broader Microsoft Sentinel data lake (KQL jobs beyond their role as the livestream replacement, federated tables, data lake onboarding) are also out of scope here — flagged as future topics, not covered in depth.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

```kusto
// 1 — Is anyone actually using hunting bookmarks? (Confirms the feature is reachable and being used at all)
HuntingBookmark
| where TimeGenerated > ago(30d)
| summarize Count = count(), LastBookmark = max(TimeGenerated), Analysts = dcount(CreatedBy)

// 2 — Which bookmarks were soft-deleted vs. still active (explains "missing" bookmarks that were actually removed)
HuntingBookmark
| where TimeGenerated > ago(30d)
| summarize arg_max(TimeGenerated, *) by BookmarkId
| summarize Active = countif(SoftDelete == false), Deleted = countif(SoftDelete == true)

// 3 — Do any hunting queries return zero results tenant-wide because their data source was never connected?
// (Run from the Hunting > Queries tab UI — no direct KQL equivalent; this is a reminder to check the "N/A" filter there)

// 4 — Confirm a specific custom hunting query is visible and its underlying table exists
search "<part of query name or a distinctive column>"
| where TimeGenerated > ago(1d)
| take 5

// 5 — Any KQL jobs (the livestream replacement) currently configured, and are they producing data?
// No Az PowerShell/KQL equivalent exists for job *definitions* — check Defender portal > Microsoft Sentinel >
// Data lake exploration > Jobs. This query only confirms whether a job's OUTPUT table is receiving data:
<JobOutputTableName_KQL_CL>
| where TimeGenerated > ago(1d)
| summarize count(), max(TimeGenerated)
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| "Add bookmark" button is missing or greyed out | Working in the **Defender portal** — bookmark *creation* is Azure-portal-only; Defender portal is view-only for existing bookmarks | Fix 1 |
| Analyst reports "Livestream" isn't in the Hunting menu anymore | Not a bug — Microsoft Sentinel livestreams are fully retired (not a per-tenant toggle); this is expected in 2026 | Fix 2 |
| A colleague can't see a custom hunting query you created | Query was saved as a private/"my queries" item rather than shared tenant-wide, or was created in one portal and the colleague is looking in the other | Fix 3 |
| Bookmark just created isn't showing in the **Bookmarks** tab yet | Normal propagation delay — can be several minutes between creation and tab visibility | Fix 4 |
| `HuntingBookmark` table has far more rows than the Bookmarks tab shows | UI hard cap of 1,000 bookmarks in the tab — the rest only exist in the underlying table | Fix 5 |
| "Create analytics rule" from a query pre-populates the wrong/stale KQL | Promoted from a **Hunt's cloned copy** of a query, which is independent of and can drift from the original in the global Queries tab (or vice versa) | Fix 6 |
| KQL job created but its destination table never receives data, or job creation itself fails with a permissions error | Data lake managed identity (`msg-resources-<guid>`) is missing the **Log Analytics Contributor** role on the destination workspace, or the tenant was never onboarded to the Sentinel data lake at all | Fix 7 |
| Hunting query permanently shows **N/A** results | Query's required data source/table was never connected — not a query defect | Fix 8 |
| "Insufficient permissions" creating or acting on a Hunt | Missing Microsoft Sentinel Contributor role (or an equivalent custom RBAC role scoped to `Microsoft.SecurityInsights/hunts`) | Fix 9 |

---
## Dependency Cascade

<details><summary>What must be true for a hunting finding to become an incident or analytics rule</summary>

```
[Data connector ingesting the source table]  ← see DataConnectors-B.md if this is broken
    └── [Hunting query (Content Hub-installed OR custom) targets that table]
            ├── [Content Hub solution installed]         → out-of-the-box queries appear in Queries tab
            └── [Custom query authored and SAVED SHARED]  → visible to other analysts in the tenant
                    (saved-private queries are visible only to their author)
                        └── [Query run — "Run Query" / "Run selected queries" / "Run all queries"]
                                └── [Results reviewed in Logs (Log Analytics) pane]
                                        ├── [Row(s) marked "Add bookmark" — AZURE PORTAL ONLY]
                                        │       └── [HuntingBookmark table row written — propagation
                                        │            delay of several minutes before Bookmarks tab shows it]
                                        │               ├── [Entity mapping present] → visible in
                                        │               │        investigation graph + UEBA entity page
                                        │               ├── [MITRE ATT&CK tactic/technique mapped]
                                        │               │        (inherited from source query, editable)
                                        │               └── [Bookmark(s) selected → Incident actions →
                                        │                    Create new incident / Add to existing incident]
                                        └── [OR: "New alert rule" > "Create Microsoft Sentinel alert" →
                                             Analytics rule wizard, KQL pre-populated from the query
                                             actually selected — see AnalyticsRules-A.md from here on]

[SEPARATE WRAPPER — optional, not required for the chain above]
Hunts (Preview)
    └── [RBAC: Microsoft Sentinel Contributor, or custom role on Microsoft.SecurityInsights/hunts]
            └── [Hunt created — either from preselected queries ("Create new hunt") or blank ("New Hunt")]
                    └── [Queries added to hunt are CLONED — independent copies, edits don't sync
                         either direction with the global Queries tab library]
                            └── [Hunt's own Queries / Bookmarks / Entities / Comments tabs]
                                    └── [Hypothesis state + Hunt status tracked → feeds the metrics bar]

[SEPARATE REPLACEMENT FOR RETIRED LIVESTREAM — different product surface entirely]
KQL jobs (Microsoft Sentinel data lake)
    └── [Tenant onboarded to the Sentinel data lake]              ← prerequisite, not automatic
            └── [Entra ID role for data-lake-wide read/write, OR
                 Log Analytics Contributor granted to the data lake
                 managed identity (msg-resources-<guid>) on the destination workspace]
                    └── [Job created — one-time or scheduled, up to 100 enabled jobs/tenant,
                         5 concurrent executions/tenant, 1-hour query timeout]
                            └── [Output table (suffixed _KQL_CL or _KQL) populates — subject to
                                 ~15-minute data lake ingestion latency]
                                    └── [Query the promoted table via the analytics-tier KQL editor —
                                         a job does NOT alert/notify on its own; pair with a playbook
                                         or an analytics rule reading the output table for that]
```

**The single most consequential fact in this dependency chain:** bookmark **creation** only works in the Azure portal. Given Microsoft Sentinel's Azure-portal retirement is scheduled for March 31, 2027 and many tenants are already Defender-portal-default, an analyst working entirely in the Defender portal will find every "Add bookmark" affordance missing or non-functional — this is not a permissions or licensing problem, it's a documented portal-parity gap.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm which portal the analyst is actually working in**
```
Azure portal:    portal.azure.com → Microsoft Sentinel → Threat management → Hunting
Defender portal: security.microsoft.com → Microsoft Sentinel → Threat management → Hunting
```
Expected: bookmark creation controls are present and clickable in the Azure portal. Bad: analyst is in the Defender portal and expects to create a bookmark there — this will never work regardless of role/license, by design (view-only in Defender portal).

**Step 2 — Confirm the hunting query's underlying data source is connected**
```kusto
<TableNameTheQueryTargets>
| where TimeGenerated > ago(1d)
| take 1
```
Expected: at least one row (assuming the source generates daily activity). Bad: zero rows — hover the info icon next to the query's **N/A** result in the Queries tab to see exactly which connector it's waiting on, then route to `DataConnectors-B.md`.

**Step 3 — Confirm a bookmark actually wrote to the table (not just "the button was clicked")**
```kusto
HuntingBookmark
| where TimeGenerated > ago(1h)
| where CreatedBy has "<analyst UPN>"
| project TimeGenerated, BookmarkId, DisplayName, Tags, SoftDelete
```
Expected: a row appears within a few minutes of creation. Bad: nothing after 15+ minutes — treat as a genuine fault, not propagation lag, and re-check Step 1 (wrong portal is still the most common root cause even when the analyst insists they clicked "Add bookmark").

**Step 4 — Confirm whether a custom query is shared or private**
```
Hunting > Queries tab → locate the query → check the "Source" / owner column, or reopen the query's
save dialog to see whether it was saved to a shared location or as a personal/private item.
```
Bad: query only shows for its author — resave it to the shared/tenant-visible location so other analysts can see it.

**Step 5 — For "Create analytics rule" producing unexpected KQL, confirm which copy it was promoted from**
```
If promoted from inside a Hunt: the query is a CLONE, independent of the global Queries tab version.
If promoted from the global Queries tab directly: it's the shared, canonical version.
```
Bad: someone edited a Hunt's cloned copy expecting the change to also appear in the global library (or vice versa) — these are two separate objects by design.

**Step 6 — For KQL job / livestream-replacement issues, confirm data lake onboarding and the managed identity's role**
```powershell
Get-AzRoleAssignment -ResourceGroupName "<rg>" | Where-Object { $_.DisplayName -like "msg-resources-*" }
```
Expected: a role assignment for **Log Analytics Contributor** scoped to the destination workspace, held by the `msg-resources-<guid>` managed identity. Bad: no such assignment — job creation/writes will fail with a permissions error, or silently never populate the destination table.

---
## Common Fix Paths

<details>
<summary>Fix 1 — Bookmark creation unavailable (Defender portal)</summary>

Not a defect — bookmark creation is a documented Azure-portal-only capability as of the current Sentinel/Defender-portal split.

```
Switch to: portal.azure.com → Microsoft Sentinel → Threat management → Hunting → Queries tab →
run query → View query results → select rows → Add bookmark
```
Bookmarks created in the Azure portal are visible (read-only) back in the Defender portal's Hunting > Bookmarks tab once propagation completes.

**Rollback:** N/A — no change made, just routing to the correct portal.
</details>

<details>
<summary>Fix 2 — Livestream missing from the Hunting menu</summary>

Expected behavior, not a bug. Microsoft Sentinel livestreams have been fully retired tenant-wide — this isn't a per-workspace or per-license setting that can be turned back on. Redirect the use case:

| Old livestream use case | Current replacement |
|---|---|
| "Notify me the moment this query returns a new hit" | **Analytics rule** (Scheduled or NRT) — see `AnalyticsRules-B.md` |
| "Keep a running, queryable history of this query's results over time" | **KQL job** (scheduled, writes to a persisted table) — see Fix 7 below and `Diagnosis Step 6` |
| "Send matches to Teams/email automatically" | **Playbook** triggered from an analytics rule or automation rule — see `LogicAppsPlaybooks-B.md` |

**Rollback:** N/A — this is a platform retirement, not a configuration to revert.
</details>

<details>
<summary>Fix 3 — Custom hunting query not visible to other analysts</summary>

```
Hunting > Queries tab → open the query → check its save/sharing scope.
Re-save explicitly to the shared/tenant-visible location rather than a personal one.
```
Confirm the other analyst is checking the same portal (Azure vs. Defender) the query was authored in — cross-portal query visibility has occasionally lagged in some tenants during the Defender-portal transition; if the query is confirmed shared and still invisible cross-portal, treat as a genuine sync issue and escalate rather than continuing to re-save.

**Rollback:** N/A — resaving to shared scope is additive, doesn't affect the original private copy's history.
</details>

<details>
<summary>Fix 4 — Bookmark not appearing in the Bookmarks tab yet</summary>

```kusto
HuntingBookmark
| where TimeGenerated > ago(30m)
| where CreatedBy has "<analyst UPN>"
| project TimeGenerated, BookmarkId, DisplayName
```
If the row exists in the table but the tab still doesn't show it, wait the full propagation window (documented as "several minutes," in practice sometimes longer under load) before treating this as a fault. If the table itself has no row, re-check Fix 1 — the most common cause is the analyst was actually in the Defender portal and the click silently did nothing.

**Rollback:** N/A.
</details>

<details>
<summary>Fix 5 — More bookmarks exist than the Bookmarks tab shows (1,000-row UI cap)</summary>

```kusto
HuntingBookmark
| summarize arg_max(TimeGenerated, *) by BookmarkId
| where SoftDelete == false
| project TimeGenerated, BookmarkId, DisplayName, Tags, CreatedBy
| order by TimeGenerated desc
```
Query the `HuntingBookmark` table directly for anything beyond the UI's first 1,000 — this is a documented, permanent UI limit, not a bug to escalate.

**Rollback:** N/A.
</details>

<details>
<summary>Fix 6 — "Create analytics rule" pre-populates unexpected KQL</summary>

Confirm which query object the promotion actually happened from:

```
Global Queries tab → right-click query → New alert rule > Create Microsoft Sentinel alert
   (uses the CANONICAL shared query)

vs.

Inside a Hunt → Queries tab → right-click query → Create analytics rule
   (uses that Hunt's CLONED, independently-editable copy)
```
If the wrong source was used, discard the half-created rule and re-promote from the intended copy. Going forward, edit hunt-specific investigative tweaks only inside the hunt, and make any change meant to be permanent in the shared global query instead.

**Rollback:** delete the incorrectly-created draft analytics rule before it's enabled; no data-plane impact if caught before enabling.
</details>

<details>
<summary>Fix 7 — KQL job (livestream replacement) fails to create or destination table never fills</summary>

```powershell
# Confirm the data lake's managed identity has Log Analytics Contributor on the destination workspace
Get-AzRoleAssignment -ResourceGroupName "<rg>" | Where-Object { $_.DisplayName -like "msg-resources-*" }

# If missing, grant it (requires Owner/User Access Administrator on the workspace)
New-AzRoleAssignment -ObjectId "<managed identity object ID>" -RoleDefinitionName "Log Analytics Contributor" -ResourceGroupName "<rg>"
```
Also confirm:
- The tenant has actually completed **Sentinel data lake onboarding** — this is a separate, prerequisite step, not automatic.
- The job's query doesn't use an unsupported operator (`adx()`, `arg()`, `externaldata()`, `ingestion_time()`, or user-defined functions — none work in data lake jobs).
- The job's start time is at least 30 minutes after creation/edit (a hard scheduling floor) and results account for ~15 minutes of data lake ingestion latency before being queryable.

**Rollback:** disabling or deleting a job stops future runs; it does not delete already-written rows in the destination table.
</details>

<details>
<summary>Fix 8 — Hunting query permanently shows N/A results</summary>

```
Hunting > Queries tab → filter Results = N/A → hover the (i) icon next to a specific query
→ note the required data source(s) listed → confirm connector status in Data connectors
```
Route to `DataConnectors-B.md` for the underlying connector — the query itself is not at fault; it simply has no matching table to run against.

**Rollback:** N/A.
</details>

<details>
<summary>Fix 9 — "Insufficient permissions" creating/acting on a Hunt</summary>

```
Required: built-in Microsoft Sentinel Contributor role, OR a custom Azure RBAC role granting
permissions under Microsoft.SecurityInsights/hunts.
```
Grant the built-in role for the fastest resolution unless the org specifically needs a scoped custom role — see `Security/ConditionalAccess/` or Entra role-assignment scripts for the standard grant pattern used elsewhere in this repo.

**Rollback:** N/A — this is a permission grant, not a destructive change.
</details>

---
## Escalation Evidence

```
=== SENTINEL HUNTING ESCALATION ===
Date/Time              :
Engineer                :
Ticket                  :

Portal in use (Azure / Defender)   :
Workspace Name                     :

Issue type (Query / Bookmark / Hunt / KQL job / Promotion-to-rule):

Query name (if applicable)         :
Query "Results" state (N/A / 0 / count):
Data source(s) required per (i) icon:

Bookmark created (Y/N)             :
HuntingBookmark row confirmed via KQL (Y/N):
Time since creation                :

Hunt name (if applicable)          :
Analyst's Sentinel RBAC role       :

KQL job name (if applicable)       :
Data lake onboarding confirmed (Y/N):
msg-resources managed identity role confirmed (Y/N):

Steps Attempted:
1.
2.
3.

Expected behaviour :
Actual behaviour   :
```

---
## 🎓 Learning Pointers

- **Bookmark creation is Azure-portal-only — this is a documented, permanent portal-parity gap, not a bug or a licensing issue.** With Sentinel's Azure-portal retirement scheduled for March 31, 2027, teams that have already fully switched to the Defender portal need an explicit standing exception (or a documented workaround) for the one workflow step that still requires the old portal. [Hunt with bookmarks in Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/bookmarks)
- **Livestreams are gone, and "just use a KQL job instead" is not a like-for-like replacement.** A KQL job persists query results to a table on a schedule — it does not alert or notify anyone by itself. Real-time notification now requires an analytics rule (with an automation rule/playbook) or a playbook triggered off the job's output table. Framing this correctly to a client avoids a false sense that "the replacement just works the same way." [Threat hunting in Microsoft Sentinel — livestream note](https://learn.microsoft.com/en-us/azure/sentinel/hunting)
- **A Hunt's queries are clones, not live links, to the global Queries tab.** Editing a query inside a Hunt for a specific investigation does not change the shared library version, and vice versa — analysts expecting synchronized edits between the two will be confused by "my fix didn't apply everywhere." [Conduct end-to-end proactive threat hunting](https://learn.microsoft.com/en-us/azure/sentinel/hunts)
- **KQL jobs have real, per-tenant hard limits that aren't obvious until you hit them:** only 5 concurrent job executions and 100 enabled jobs per tenant, a 1-hour query timeout (with partial-result promotion on timeout, not failure), and ~15 minutes of data lake ingestion latency baked into every schedule. Plan job cadence and query cost with these in mind before promising a client near-real-time results from this path. [Create jobs in the Microsoft Sentinel data lake](https://learn.microsoft.com/en-us/azure/sentinel/datalake/kql-jobs)
- **Community resource:** the [Microsoft Sentinel Tech Community blog](https://techcommunity.microsoft.com/category/azure-sentinel) and Microsoft Q&A's `microsoft-sentinel` tag are the fastest place to check for freshly-reported Defender-portal/Azure-portal parity gaps as the March 2027 retirement approaches — this class of issue is actively shifting month to month, not a stable, once-documented state.
