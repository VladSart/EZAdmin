# Microsoft Sentinel Watchlists — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why "28-day retention" doesn't mean what it sounds like.

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
- Watchlist architecture: creation methods, storage model (`Watchlist` table, name-value pairs), the `SearchKey` join-performance pattern, and documented limits (item count, file size, name/alias rules)
- The retention-vs-refresh distinction that governs long-term watchlist availability
- Portal/API service-incident troubleshooting patterns, per Microsoft's own current guidance
- MSSP/multi-workspace considerations (specifically, the explicit Azure Lighthouse limitation)

**Out of scope:**
- Threat Intelligence STIX objects — a structurally different, typed model with its own tables and import paths (see `ThreatIntelligence-A.md`)
- Custom log tables / Data Collection Rules for high-volume data — the mechanism watchlists explicitly defer to once data volume exceeds reference-data scale
- Analytics rule authoring in general — see `AnalyticsRules-A.md`; this topic covers only the watchlist-specific join/lookup mechanics used inside such rules

**Assumptions:**
- Sentinel is enabled on a Log Analytics workspace
- Engineer has at minimum Log Analytics Reader to query watchlists; Microsoft Sentinel Contributor (or higher) to create/edit them
- Some referenced features (watchlist templates, Azure Storage-based file creation) are documented as **PREVIEW** as of this writing and carry the standard Azure Preview Supplemental Terms

---

## How It Works

<details><summary>Full architecture</summary>

A watchlist is fundamentally a small, curated set of **name-value pairs** — think of it as a managed, queryable CSV rather than a detection feed. Sentinel stores this data in the workspace's `Watchlist` table and additionally caches it for query performance, which is why watchlist lookups are fast even inside complex joined queries.

**Creation paths:**
```
Local file upload (<= 3.8 MB)
   │
   ▼
Watchlist definition (name/alias, SearchKey column, schema)
   │
   ▼
Watchlist table (workspace-scoped) + query cache
```
or, for larger datasets (PREVIEW):
```
CSV uploaded to an Azure Storage account
   │
   ├─ Shared Access Signature (SAS) URL generated (resource URI + SAS token)
   │
   ▼
Watchlist created by pointing Sentinel at the SAS URL (up to 500 MB)
   │
   ▼
Watchlist table (workspace-scoped) + query cache
```
A third creation path — downloading a built-in watchlist **template**, populating it, and uploading — is also documented and currently in PREVIEW; it produces the same end state as a plain local-file upload, just with a pre-defined schema for common scenarios (e.g. high-value assets, IP allowlists).

**The SearchKey concept:** at creation time, you designate one column as the `SearchKey` — the column expected to be the primary target of joins and searches against this watchlist. This isn't just documentation convention; it's the column two built-in KQL functions are optimized around:

- `_GetWatchlistAlias` — returns the aliases of every watchlist in the workspace (no arguments)
- `_GetWatchlist('alias')` — returns the full name-value pair set for a specific watchlist by alias

A query that joins on `SearchKey` specifically follows Microsoft's documented best-performance pattern; joining on a different column still works (the whole row set is available), but is the less-optimized path and, more practically, is a common source of confusing partial-match results if the analyst authoring the query isn't aware which column was designated as the key.

**The retention/refresh distinction — the architectural detail this whole topic hinges on:**

The underlying Log Analytics `Watchlist` table has a documented **28-day data retention** setting. Read in isolation, this sounds like watchlists expire after 28 days — they do not. Sentinel's watchlist service refreshes watchlist data on a **recurring interval** (documented as every 12 days), which updates the `TimeGenerated` field on the underlying rows. Because the refresh cycle (12 days) is shorter than the retention window (28 days), actively-refreshed watchlist data never actually ages out — the watchlist remains available and queryable indefinitely, refreshed faster than it could expire, until it's explicitly deleted. This is a deliberate, if easily misread, design: retention describes the storage layer's housekeeping, not the watchlist's lifecycle as a managed object.

</details>

---

## Dependency Stack

```
Data source
        ├── Local CSV upload (<=3.8 MB) — synchronous, immediate
        └── Azure Storage SAS-URL upload (PREVIEW, <=500 MB) — requires a valid,
              non-expired SAS token; Sentinel must be able to reach the storage account
              (public network access or an appropriate private-link/firewall exception)
        │
        ▼
Watchlist definition — subject to hard limits:
        ├── Name/alias: 3-64 characters, first AND last character alphanumeric
        │       (hyphens, underscores, spaces permitted only in the middle)
        ├── Columns: must satisfy KQL entity naming restrictions
        └── SearchKey: one column designated as the primary join/search target
        │
        ▼
Watchlist table (workspace-scoped Log Analytics table) + query-performance cache
        ├── Workspace-wide ceiling: 10 million ACTIVE items across ALL watchlists
        │       combined (deleted items excluded from this count)
        ├── Underlying table data retention: 28 days
        └── Refresh interval: every 12 days (updates TimeGenerated on unchanged rows —
                keeps actively-used watchlists perpetually inside the retention window)
        │
        ▼
Query surface
        ├── _GetWatchlistAlias — enumerate all watchlists in the workspace
        └── _GetWatchlist('alias') — retrieve name-value pairs for one watchlist,
                optionally projecting SearchKey for join performance
        │
        ▼
Consumers: analytics rule KQL (join/lookup/in against event tables), hunting queries,
workbooks, notebooks (MSTICPy), Logic Apps playbook actions that call watchlist operations

Explicit unsupported path:
        Cross-workspace watchlist management via Azure Lighthouse — NOT supported;
        each delegated client workspace's watchlists must be managed natively within
        that workspace, with no bulk/delegated management surface for this object type
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Watchlist created a month+ ago, team assumes it "expired" at 28 days and stopped working | Misreading the 28-day retention figure — the refresh cycle (every 12 days) keeps active watchlists perpetually inside the retention window | `_GetWatchlist('alias') \| take 10` — still returns data if not explicitly deleted |
| `_GetWatchlist()` returns fewer rows than expected only when run with a narrow global time filter | Query-level time-range scoping excluding valid rows — a Logs pane behavior, not a watchlist defect | Rerun with a broad time range (e.g. Last 30 days) |
| Watchlist join in an analytics rule produces far fewer matches than manual spot-checking suggests it should | Join/filter is on a column other than the defined `SearchKey` | Confirm which column was set as SearchKey at creation; rewrite join accordingly |
| Portal Watchlists blade blank or throwing 502/5XX, but `_GetWatchlist()` still returns correct data via Logs | Transient service-side incident affecting only the management plane | Check Azure Service Health before any local config change |
| Watchlist upload silently rejected with no clear error | Name/alias violates the 3-64 char / alphanumeric-first-and-last rule, or a column header violates KQL entity naming rules | Re-check exact naming against documented constraints |
| Large dataset (multi-hundred-MB CSV) won't upload via the standard "upload a file" flow | Local upload path capped at 3.8 MB; large files require the Azure Storage SAS-URL path (PREVIEW) | Switch to Azure Storage upload method |
| MSSP: attempted to manage a client's watchlist through a Lighthouse-delegated session, operation fails or is unavailable | Cross-workspace watchlist management via Azure Lighthouse is explicitly unsupported | Manage the watchlist by connecting natively into that specific client workspace |
| Watchlist used for an allowlist/blocklist scenario producing stale results (e.g. a departed employee still absent from a terminated-users blocklist) | Not a platform fault — the underlying business data was never re-uploaded after the source list changed | Confirm data-refresh process/ownership, not a Sentinel-side issue |
| Workspace approaching or exceeding recommended watchlist scale | Watchlists used as a substitute for a proper high-volume ingestion pipeline | Redesign using custom logs / Data Collection Rules once approaching the 10M-item ceiling |

---

## Validation Steps

**1. Enumerate all watchlists and confirm the target is present**
```kusto
_GetWatchlistAlias
```

**2. Query with an intentionally wide time range**
```kusto
_GetWatchlist('<watchlist-alias>')
| take 20
```
Always validate this BEFORE narrowing scope for a specific investigation — establishes a known-good baseline.

**3. Confirm SearchKey usage in a representative join**
```kusto
let watchlist = (_GetWatchlist('ipwatchlist') | project SearchKey);
Heartbeat
| where ComputerIP in (watchlist)
```
Compare match count against a naive join on a non-SearchKey column to confirm SearchKey is actually the more selective/correct join target for the intended use case.

**4. Confirm item volume, if scale is a concern**
```kusto
_GetWatchlist('<watchlist-alias>') | count
```
Sum across every alias returned by `_GetWatchlistAlias` if approaching the workspace-wide 10-million-item ceiling — there's no single built-in cross-watchlist total function, so this must be aggregated manually per alias.

**5. During a suspected service incident, validate query-plane independently of management-plane**
```kusto
_GetWatchlistAlias
_GetWatchlist('<known-good-alias>') | take 10
```
If these succeed while the portal UI is blank/erroring, this confirms data availability and should inform how the incident is communicated (data is intact; only the editing experience is degraded).

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm existence and basic queryability

1. Run Validation Step 1. If the alias is missing, confirm workspace context before assuming creation failed.
2. Run Validation Step 2 with a wide time range. Most "empty watchlist" reports resolve here.

### Phase 2 — Diagnose query-result mismatches

1. Confirm the consuming query's join column against the watchlist's actual `SearchKey` (Validation Step 3).
2. Confirm the underlying CSV/business data source is current — a technically healthy watchlist can still produce stale-looking results if its source data hasn't been refreshed by the process/team that owns it.
3. If scale-related, check item count against the 10-million ceiling (Validation Step 4) and consider whether this data belongs in a custom log table instead.

### Phase 3 — Service-incident diagnosis

1. Determine scope: does the symptom affect all watchlists, multiple users, both portal and API/automation paths? Broad-scope symptoms point to a platform issue.
2. Separate query-plane from management-plane health (Validation Step 5) — don't assume data loss just because the editing UI is unresponsive.
3. Check Azure Service Health for an active, acknowledged Microsoft Sentinel incident.
4. Explicitly avoid repeated delete/recreate cycles while an incident is suspected — this can produce inconsistent state once the platform recovers, compounding the original issue.

### Phase 4 — MSSP/multi-workspace diagnosis

1. If a delegated (Azure Lighthouse) session is involved, confirm whether the failing operation is watchlist management specifically — this is an explicit, documented gap, not a permissions misconfiguration to keep troubleshooting.
2. Manage the affected client's watchlist by connecting directly into that client's own workspace instead of through the delegated session.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Migrate an oversized watchlist to a proper high-volume ingestion pipeline</summary>

**Use when:** A watchlist is approaching or has hit a meaningful fraction of the 10-million-item workspace-wide ceiling, or is regularly uploaded as a multi-hundred-MB file — a sign it was pressed into service as a general-purpose data-ingestion mechanism rather than curated reference data.

```
1. Identify the actual query patterns currently run against the oversized watchlist —
   these define the schema requirements for its replacement.
2. Stand up a custom log table (or, if the source already emits structured logs, a
   standard Data Collection Rule-based ingestion path) sized for the real data volume.
3. Migrate consuming queries from _GetWatchlist('alias') syntax to direct table
   references against the new custom log table.
4. Once migration is validated, delete the oversized watchlist to free workspace-wide
   watchlist item budget for legitimate reference-data use cases.
```

**Rollback:** keep the original watchlist (undeleted) until the new ingestion path and all migrated queries are validated in production; delete only after a confirmed burn-in period.
</details>

<details><summary>Playbook 2 — Recover confidently from a suspected watchlist service incident</summary>

**Use when:** The Watchlists portal blade is blank, throwing 5XX errors, or CRUD operations fail, and the team's instinct is to start deleting and recreating watchlists.

```
1. STOP — do not delete/recreate while the incident is unconfirmed. Run the query-plane
   validation first:
```
```kusto
_GetWatchlistAlias
_GetWatchlist('<known-good-alias>') | take 10
```
```
2. If query-plane succeeds, communicate to stakeholders that watchlist DATA is intact and
   only the management/editing experience is currently degraded — this materially changes
   the urgency and messaging of the incident.
3. Check Azure Service Health for Microsoft Sentinel; if an active incident is confirmed,
   wait for platform recovery rather than working around it destructively.
4. Once the portal/API recovers, re-validate CRUD operations on a low-risk test watchlist
   before resuming normal management activity on production watchlists.
```

**Rollback:** N/A — this playbook is specifically about avoiding an unnecessary, potentially state-corrupting rollback/rebuild during a transient platform issue.
</details>

<details><summary>Playbook 3 — Establish an MSSP watchlist management process around the Lighthouse gap</summary>

**Use when:** An MSSP manages many client Sentinel workspaces via Azure Lighthouse and needs a repeatable process for watchlist updates (e.g. a shared terminated-employee or known-bad-IP list that needs pushing to multiple client workspaces).

```
1. Accept the platform constraint: there is no delegated, cross-workspace watchlist
   management path via Lighthouse — this must be designed around, not worked around.
2. Maintain the canonical source data (the actual CSV/list) in a single, centrally-owned
   location (e.g. a repo, a central storage account).
3. Build a lightweight automation (Logic App, Azure Automation runbook, or scheduled
   script) that authenticates natively INTO each client workspace individually and
   creates/updates that workspace's watchlist via the Sentinel API — not through a
   Lighthouse-delegated session.
4. Document this as a per-workspace push model in onboarding materials so new team
   members don't waste time hunting for a Lighthouse-based bulk-management option that
   doesn't exist.
```

**Rollback:** N/A — this is a process/architecture recommendation, not a reversible technical change.
</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Microsoft Sentinel watchlist health evidence for escalation.
.NOTES     Requires Az.Accounts, Az.OperationalInsights modules and at least Log Analytics
           Reader on the target workspace. Run from an authenticated Az PowerShell session.
#>

param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$WorkspaceName,
    [string]$WatchlistAlias
)

$OutputPath = "$env:TEMP\SentinelWatchlist-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName

# 1. Enumerate every watchlist alias in the workspace
try {
    (Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query "_GetWatchlistAlias").Results |
        Export-Csv "$OutputPath\01-AllWatchlistAliases.csv" -NoTypeInformation
} catch { "Query failed: $($_.Exception.Message)" | Out-File "$OutputPath\01-ERROR.txt" }

# 2. If a specific alias was supplied, pull a sample + count with a wide time range
if ($WatchlistAlias) {
    $q = "_GetWatchlist('$WatchlistAlias') | take 20"
    try {
        (Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $q).Results |
            Export-Csv "$OutputPath\02-WatchlistSample.csv" -NoTypeInformation
    } catch { "Query failed: $($_.Exception.Message)" | Out-File "$OutputPath\02-ERROR.txt" }

    $qCount = "_GetWatchlist('$WatchlistAlias') | count"
    try {
        (Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $qCount).Results |
            Export-Csv "$OutputPath\03-WatchlistItemCount.csv" -NoTypeInformation
    } catch { "Query failed: $($_.Exception.Message)" | Out-File "$OutputPath\03-ERROR.txt" }
}

# 3. Workspace daily quota state (relevant if rows appear missing shortly after creation)
Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName |
    Select-Object Name -ExpandProperty WorkspaceCapping |
    Export-Csv "$OutputPath\04-WorkspaceCapping.csv" -NoTypeInformation

Write-Host "Evidence collected to: $OutputPath" -ForegroundColor Green
Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath.zip" -Force
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|--------------------|
| List all watchlist aliases | `_GetWatchlistAlias` |
| Query a specific watchlist | `_GetWatchlist('<alias>') \| take 10` |
| Count items in a watchlist | `_GetWatchlist('<alias>') \| count` |
| Best-performance join pattern | `... \| where Col in ((_GetWatchlist('<alias>') \| project SearchKey))` |
| Check workspace daily cap | `(Get-AzOperationalInsightsWorkspace ...).WorkspaceCapping` |
| Create/manage watchlists (portal) | Sentinel → Configuration → Watchlists |
| Large-file (up to 500 MB) upload path | Azure Storage account + SAS URL (PREVIEW) |
| Local file upload limit | 3.8 MB |
| Name/alias rule | 3-64 chars, first/last char alphanumeric |
| Workspace-wide item ceiling | 10,000,000 active items across all watchlists |
| Underlying table retention | 28 days (data refreshes every 12 days, keeping active watchlists inside this window) |
| Check Azure Service Health | portal.azure.com → Service Health → Service issues |

---

## 🎓 Learning Pointers

- **"28-day retention" describes the storage layer, not the watchlist's actual lifespan.** The watchlist refresh cycle (every 12 days) keeps actively-managed watchlists perpetually inside that retention window — a watchlist doesn't silently expire on a calendar; it persists until someone deletes it. This is the single fact in this topic most likely to be misremembered or mis-taught to a junior analyst. [Watchlists in Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/watchlists)
- **Watchlists and Threat Intelligence solve visually similar problems (both are "lists Sentinel uses to enrich queries") but are architecturally unrelated.** Watchlists are flat name-value pairs meant for reference data at reference-data scale; Threat Intelligence is a typed STIX object model meant for CTI at a completely different operational purpose. Don't reach for a watchlist to manage IOCs that genuinely belong in TI, or vice versa. [Use Watchlists to Correlate and Enrich Event Data](https://learn.microsoft.com/en-us/azure/sentinel/watchlists)
- **Query-plane and management-plane independence during a service incident is documented Microsoft guidance, not a workaround this repo invented.** Confirming `_GetWatchlist()` still returns correct data before assuming a portal outage means data loss is the officially recommended first step — and directly prevents the single most damaging mistake in this topic: reflexively deleting and recreating watchlists mid-incident.
- **The Azure Lighthouse cross-workspace management gap is a genuine, permanent platform limitation for MSSPs, not a temporary preview restriction.** Any MSSP process built around this repo's own Lighthouse-centralization guidance (see `Azure/Lighthouse/Lighthouse-A.md`) needs an explicit carve-out for watchlists specifically — they must always be managed by connecting natively into each client workspace.
- **The workspace-wide 10-million-item ceiling spans ALL watchlists combined, not per-watchlist.** A workspace with several large watchlists can hit this ceiling well before any single one looks obviously oversized — sum across `_GetWatchlistAlias` results when investigating capacity, don't check just the watchlist currently in question.
- **Reference:** [Create watchlists in Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/watchlists-create) | [Build queries and detection rules with watchlists](https://learn.microsoft.com/en-us/azure/sentinel/watchlists-queries) | [Manage watchlists in Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/watchlists-manage) | [Built-in watchlist schemas](https://learn.microsoft.com/en-us/azure/sentinel/watchlist-schemas)
