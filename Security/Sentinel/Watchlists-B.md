# Microsoft Sentinel Watchlists — Hotfix Runbook (Mode B: Ops)
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

**Disambiguation up front:** Watchlists are reference-data name-value pair lists (high-value assets, terminated employees, allow/block IP lists) that analysts import and join against event data — a curated small-volume lookup mechanism, not a detection or ingestion source in their own right. They're distinct from Threat Intelligence (STIX-typed threat objects — see `ThreatIntelligence-A.md`) and from custom log tables (built for large, high-volume raw data — see `Get-AzOperationalInsightsWorkspace`-based ingestion topics).

```kusto
// 1 — List every watchlist alias currently defined in the workspace
_GetWatchlistAlias

// 2 — Query a specific watchlist by alias — confirm rows actually return
_GetWatchlist('<watchlist-alias>')
| take 10

// 3 — Confirm the watchlist item count against the workspace-wide 10 million active-item ceiling
_GetWatchlist('<watchlist-alias>') | count

// 4 — Widen the time scope before concluding a watchlist is "empty" — Logs pane time-range
// filters apply to Watchlist table TimeGenerated same as any other table
// (set the Logs pane time picker to a broad range, e.g. Last 30 days, then rerun query 2)
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| `_GetWatchlistAlias` doesn't list a watchlist you know exists | Wrong workspace, or watchlist creation genuinely failed silently | Fix 1 |
| `_GetWatchlist('<alias>')` returns 0 rows but the watchlist shows as created in the portal | Workspace ingestion daily cap reached at creation time, or a narrow query-level time scope is excluding the rows | Fix 2 |
| Portal **Watchlists** page is blank, repeatedly refreshing, or CRUD operations return `502`/`5XX` | Likely a Sentinel service-side incident, not a local misconfiguration | Fix 3 |
| Query (`_GetWatchlist`) still works but the portal editor/management UI is unresponsive | Management-plane and query-plane can degrade independently during a transient service issue — data is probably NOT lost | Fix 4 |
| Join against a watchlist in an analytics rule/hunting query returns unexpectedly few matches | Not joining on the defined `SearchKey`, or a stale/never-refreshed watchlist row | Fix 5 |
| CSV upload rejected outright | Local upload exceeds 3.8 MB, or the watchlist name/alias violates naming rules (3–64 chars, alphanumeric first/last character) | Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true for a watchlist to be usable in a query or rule</summary>

```
[CSV data source: local file (<=3.8 MB) or Azure Storage account file (preview, <=500 MB via SAS URL)]
    └── [Watchlist created: name/alias 3-64 chars, alphanumeric first+last char,
         columns follow KQL entity naming restrictions]
            └── [SearchKey column defined — the column expected to be used most often for joins/searches]
                    └── [Data written to the Watchlist table as name-value pairs, cached for query performance]
                            └── [Queryable via _GetWatchlistAlias / _GetWatchlist('alias') functions]
                                    └── [Consumed by: KQL join/lookup/in operators in analytics rules,
                                         hunting queries, workbooks, notebooks, automation playbooks]

Independent, ongoing background process:
    [Watchlist refreshes on a recurring interval, updating TimeGenerated —
     NOT the same as the 28-day underlying Log Analytics table retention setting]
```

**The retention-vs-availability distinction is the load-bearing fact in this topic:** the underlying Log Analytics `Watchlist` table has a 28-day data retention setting, but the watchlist itself does **not** expire after 28 days — it remains available and queryable indefinitely until explicitly deleted, because Sentinel's watchlist service refreshes the data on a recurring interval, which resets `TimeGenerated`. Treating the 28-day figure as an expiration date is the most common conceptual mistake this topic exists to correct.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the watchlist exists and is queryable at all**
```kusto
_GetWatchlistAlias
```
Good: the expected alias appears in the list. Bad: alias absent — either wrong workspace or a genuinely failed creation (proceed to Fix 1).

**Step 2 — Query the watchlist directly with a wide time range**
```kusto
_GetWatchlist('<watchlist-alias>')
| take 10
```
Run this with the Logs pane time picker set broad (e.g. Last 30 days) before concluding the watchlist is empty — a narrow global time filter is a common false-negative cause since watchlist rows carry `TimeGenerated` like any other table row.

**Step 3 — Confirm the SearchKey is being used correctly in the consuming query**
```kusto
// Best-performance pattern — join/filter on SearchKey specifically
Heartbeat
| where ComputerIP in (
    (_GetWatchlist('ipwatchlist') | project SearchKey)
)
```
Bad: the consuming query joins on a different column than the one defined as `SearchKey` at watchlist creation time — this still works but is the documented sub-optimal pattern and, in more complex joins, a common source of "why are there so few matches" reports.

**Step 4 — During a suspected service incident, separate query-plane from management-plane symptoms**
```
Portal Watchlists blade: responsive? CRUD operations succeed?
_GetWatchlistAlias / _GetWatchlist(): still returning expected data?
```
If query access works but the portal doesn't, this points to a transient service issue affecting only the management plane — check Azure Service Health before making any configuration change.

**Step 5 — Confirm item volume against the workspace-wide ceiling**
```kusto
_GetWatchlistAlias
| extend Count = toint(0)  // Sentinel does not expose a single cross-watchlist count function —
                            // sum item counts per-alias manually if approaching the ceiling
```
Sentinel enforces a maximum of **10 million active items across all watchlists in a workspace combined** (deleted items don't count against this). Approaching this ceiling on any single large watchlist is a sign the data belongs in a custom log table instead — watchlists are documented as reference data, not a large-volume ingestion mechanism.

---

## Common Fix Paths

<details>
<summary>Fix 1 — Watchlist doesn't appear in _GetWatchlistAlias</summary>

```
1. Confirm you're querying the SAME workspace the watchlist was created in — this is the
   single most common false alarm (multiple workspaces in a subscription, same pattern as
   Sentinel data connector troubleshooting).
2. Re-check the portal Watchlists blade directly for the expected alias.
3. If genuinely absent, recreate — check the original CSV/template for a naming violation
   (3-64 characters, first and last character alphanumeric) that may have caused a silent
   partial failure during the original creation attempt.
```

**Rollback:** none — recreating a watchlist is additive and non-destructive to other data.
</details>

<details>
<summary>Fix 2 — Watchlist created successfully but query returns zero rows</summary>

```
1. Widen the Logs pane query-level time range — this resolves the majority of "empty
   watchlist" reports without any configuration change (see Diagnosis Step 2).
2. Check the Log Analytics workspace's daily ingestion cap — if the cap was reached at the
   moment the watchlist was being written, rows may not yet be visible:
```
```powershell
(Get-AzOperationalInsightsWorkspace -ResourceGroupName "<rg>" -Name "<workspace>").WorkspaceCapping
```
```
3. If the cap was the cause, allow ingestion to resume (UTC day rollover) or raise the cap,
   then re-validate:
```
```kusto
_GetWatchlist('<watchlist-alias>') | count
```

**Rollback:** raising the daily cap is non-destructive; document the change for cost governance.
</details>

<details>
<summary>Fix 3 — Portal Watchlists page blank / repeated refresh / 502 or other 5XX responses</summary>

```
1. Confirm scope: does this affect all watchlists, multiple users, both the Azure portal AND
   API/automation calls? Broad-scope symptoms point to a service incident, not local config.
2. Validate whether watchlist DATA is still queryable even though the management UI is down:
```
```kusto
_GetWatchlistAlias
```
```
3. Check Azure Service Health for an active Microsoft Sentinel incident before changing
   anything watchlist-side.
4. Do NOT repeatedly delete and recreate the watchlist while an incident is suspected — a
   portal/API failure does not necessarily mean watchlist data was lost, and repeated
   delete/recreate attempts during an active incident can create duplicate or inconsistent
   state once service recovers.
```

**Rollback:** N/A — this fix path is explicitly about NOT taking destructive action prematurely.
</details>

<details>
<summary>Fix 4 — Logic Apps playbook using watchlist operations returns 502/transient errors</summary>

```
1. Before assuming a connector permission or workflow configuration problem, validate
   Microsoft Sentinel service health specifically — automation failures during a watchlist
   service incident can surface as generic access or gateway errors even when the workflow's
   identity and configuration are completely unchanged.
2. If service health is clean, then proceed to standard Logic Apps connector/permission
   troubleshooting (see LogicAppsPlaybooks-B.md).
```

**Rollback:** N/A — diagnostic step only.
</details>

<details>
<summary>Fix 5 — Watchlist join returns fewer matches than expected</summary>

```
1. Confirm the consuming query joins/filters on the watchlist's defined SearchKey column,
   not an arbitrary column — SearchKey is documented as the best-performance join pattern
   and mismatches here are the most common "why so few matches" cause.
2. Confirm the watchlist's data is current — while watchlists don't expire at 28 days, a
   watchlist that was uploaded once and never refreshed with new business data (e.g. a
   terminated-employee list that hasn't been updated in months) will produce stale results
   that look like a query bug but are actually a data-freshness/process gap.
3. Re-upload updated CSV data if the underlying business list has changed.
```

**Rollback:** none — this is query/process correction, not a destructive change.
</details>

<details>
<summary>Fix 6 — CSV upload rejected</summary>

```
1. Local file upload: confirm file size is 3.8 MB or under. For larger files (up to 500 MB),
   use the Azure Storage upload path (currently PREVIEW) instead:
   - Upload the CSV to an Azure Storage account
   - Generate a SAS URL (resource URI + SAS token)
   - Provide that SAS URL when adding the watchlist in Sentinel
2. Confirm the watchlist name/alias itself: 3-64 characters, first and last character
   alphanumeric (hyphens/underscores/spaces allowed only in the middle).
3. Confirm column headers in the CSV satisfy KQL entity naming restrictions — a header with
   an unsupported character silently breaks the upload or the resulting SearchKey binding.
```

**Rollback:** none — re-attempting upload after correcting the issue is non-destructive.
</details>

---

## Escalation Evidence

```
=== SENTINEL WATCHLIST ESCALATION ===
Date/Time         :
Engineer          :
Ticket            :

Workspace Name     :
Watchlist Alias    :
SearchKey Column   :

_GetWatchlistAlias output includes this alias (Y/N):
_GetWatchlist() row count (wide time range):
Workspace Daily Quota / Cap Setting:

Portal Watchlists page status (Responsive/Blank/5XX):
Query-plane vs management-plane divergence observed (Y/N):
Azure Service Health incident confirmed for Sentinel (Y/N):

Steps Attempted:
1.
2.
3.

Expected behaviour : Watchlist queryable via _GetWatchlist() and usable in joins on SearchKey
Actual behaviour   :
```

---

## 🎓 Learning Pointers

- **The 28-day retention figure is the single most misread fact about watchlists.** It describes the underlying Log Analytics table's data retention, not a watchlist expiration date — the watchlist service refreshes data on a recurring interval, resetting `TimeGenerated`, so a watchlist stays available and queryable indefinitely until someone explicitly deletes it. Don't schedule "recreate watchlists every 28 days" as a maintenance task; it isn't necessary. [Watchlists in Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/watchlists)
- **A narrow query-level time scope is the most common cause of a "watchlist is broken" false alarm.** Because watchlist rows carry `TimeGenerated` like any other Log Analytics table row, a tightly scoped global datetime filter in the Logs pane can make `_GetWatchlist()` appear to return partial or zero results even though the watchlist is completely healthy — widen the time range before escalating.
- **Watchlists are explicitly reference data, not a bulk ingestion mechanism.** The workspace-wide 10-million-active-item ceiling and the documented "use custom logs for larger volumes" guidance both point the same direction: if a watchlist is approaching that scale, it's a signal to redesign the data path, not to request a limit increase.
- **Query-plane and management-plane availability are independent during a service incident.** `_GetWatchlist()` can keep returning correct data even while the portal editor or CRUD API calls are failing — confirm which plane is actually affected before assuming data loss, and avoid repeated delete/recreate cycles mid-incident, which can leave inconsistent state once the platform recovers.
- **Cross-workspace watchlist management via Azure Lighthouse is explicitly unsupported** — a real constraint for MSSPs already relying on Lighthouse for delegated multi-tenant access (see `Azure/Lighthouse/Lighthouse-A.md`). Each client workspace's watchlists must be managed natively within that workspace; there's no delegated bulk-management path for this specific object type.
- **Reference:** [Create watchlists in Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/watchlists-create) | [Build queries and detection rules with watchlists](https://learn.microsoft.com/en-us/azure/sentinel/watchlists-queries) | [Built-in watchlist schemas](https://learn.microsoft.com/en-us/azure/sentinel/watchlist-schemas)
