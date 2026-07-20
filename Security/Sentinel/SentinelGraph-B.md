# Microsoft Sentinel Graph — Hotfix Runbook (Mode B: Ops)
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

Run these first. There are **two completely different things called "Sentinel graph"** — establish which one the ticket is actually about before doing anything else.

```
# 1. Is this about the BUILT-IN embedded graphs (Incident graph/Blast Radius, Hunting graph)
#    or CUSTOM graphs (VS Code notebooks, GQL authoring)? These have entirely different
#    troubleshooting paths. Built-in graphs need zero setup beyond data lake onboarding;
#    Custom graphs need a whole separate permission/tooling chain.

# 2. For built-in graphs: confirm data lake + graph are onboarded
#    (Intune/Defender portal has no direct PowerShell surface for this — see DataLake-B.md
#    Step 1 for the managed-identity-based onboarding-state check this depends on)

# 3. For custom graphs: confirm which of the THREE separate permission layers is missing
#    - Model/build in notebook -> custom XDR unified RBAC role, "data (manage)"
#    - Persist (schedule a graph job) -> Entra ID role: Security Operator/Administrator/Global Administrator
#    - Query a persisted graph -> custom XDR unified RBAC role, "security data basics (read)"

# 4. Confirm the user isn't Sentinel-scoped (a scoped user cannot create a custom graph at all)

# 5. Confirm the Entra ID connector (asset ingestion) is enabled if the graph uses Entra*
#    tables (EntraUsers/EntraGroups/EntraMembers/EntraServicePrincipals) — see DataLake-B.md
```

| Result | Action |
|--------|--------|
| Ticket is about Incident graph/Blast Radius/Hunting graph in Defender (built-in) | → [Fix 1 — Built-In Graph Not Appearing](#fix-1--built-in-graph-not-appearing) |
| Custom graph notebook can model data but "Persist"/schedule a graph job fails | → [Fix 2 — Missing Entra ID Role for Persisting](#fix-2--missing-entra-id-role-for-persisting) |
| Custom graph is missing expected nodes/edges, no error shown | → [Fix 3 — Silent Data Access Gap](#fix-3--silent-data-access-gap) |
| "A scoped user isn't able to create a custom graph" or similar block | → [Fix 4 — Sentinel-Scoped User Cannot Create Graphs](#fix-4--sentinel-scoped-user-cannot-create-graphs) |
| A materialized graph disappeared after ~30 days | → [Fix 5 — On-Demand Graph Expired](#fix-5--on-demand-graph-expired) |
| Editing a graph job's name unexpectedly left two graphs instead of one | → [Fix 6 — Rename vs. Overwrite Confusion](#fix-6--rename-vs-overwrite-confusion) |
| First notebook cell "hangs" for several minutes | → [Fix 7 — Spark Session Cold Start](#fix-7--spark-session-cold-start) |
| GQL query returns no results / errors | → [Fix 8 — GQL Query or Schema Mismatch](#fix-8--gql-query-or-schema-mismatch) |
| All triage clean, still failing | → Escalate — open a Microsoft 365 admin center service request under Microsoft Sentinel |

---
## Dependency Cascade

<details><summary>What must be true for a graph (built-in or custom) to work</summary>

```
Microsoft Sentinel data lake onboarded (see DataLake-A.md — subscription/RG/region locked)
  ├── Built-in graphs (auto-provisioned, no separate action)
  │     ├── Incident graph + Blast Radius (Defender XDR)
  │     ├── Hunting graph (Defender XDR)
  │     └── Purview data risk graphs (Insider Risk Management / Data Security Investigations)
  │           └── Zero additional setup once data lake + graph auto-provision on Defender sign-in
  └── Custom graphs (preview — separate tooling and permission chain entirely)
        ├── Entra ID connector enabled (if graph uses Entra* asset tables)
        ├── VS Code + Microsoft Sentinel extension + Jupyter extension
        ├── Spark compute pool (Fabric-backed) — ~5 min cold start on first cell run
        └── Three independent permission layers (NOT inherited from each other):
              ├── Model/build (notebook)  -> custom XDR RBAC role, "data (manage)"
              ├── Persist (schedule job)  -> Entra ID role (Security Operator/Admin/Global Admin)
              └── Query (persisted graph) -> custom XDR RBAC role, "security data basics (read)"
              └── User must NOT be Sentinel-scoped (scoped users blocked from graph creation entirely)
        └── Graph lifecycle
              ├── Ephemeral (interactive session) — gone when notebook session closes
              └── Materialized (scheduled graph job)
                    ├── On-demand schedule -> 30-day default retention, auto-deletes on expiration
                    └── Recurring schedule -> refreshes per configured frequency, no auto-expiry
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Disambiguate built-in vs. custom graph**
```
Ask: is the user asking about something they see automatically in a Defender incident
(Blast Radius / Hunting graph) with no setup on their part, or are they authoring something
themselves in VS Code with notebooks and GQL? These are unrelated troubleshooting paths.
```
Expected: A clear answer to this determines every subsequent step — do not mix the two.

**Step 2 (built-in only) — Confirm data lake + graph onboarding**
```
No direct PowerShell/Graph read exists for graph-specific onboarding state. Confirm data lake
onboarding via the managed-identity presence check in Get-SentinelDataLakeReadinessAudit.ps1
(DataLake-A.md) — built-in graphs auto-provision alongside data lake onboarding with no
separate action, so if the data lake isn't onboarded, neither is the graph.
```
Expected: Managed identity `msg-resources-<guid>` present. If missing, this is a data lake onboarding problem (see `DataLake-B.md`), not a graph-specific one.

**Step 3 (custom graph only) — Confirm which permission layer is actually missing**
```
Ask the user exactly which action failed: modeling in the notebook, persisting (scheduling
a graph job), or querying an already-persisted graph. Each maps to a DIFFERENT permission
system — Defender XDR unified RBAC for two of them, plain Entra ID directory roles for the
third. A user can have any one or two of these without the others.
```
Expected: The specific failing action identifies the specific missing permission — see Fix 2.

**Step 4 (custom graph only) — Confirm the user isn't Sentinel-scoped**
```
Check whether the user's Sentinel access is scoped to specific workspaces/resources (any
scoping at all) rather than tenant-wide. Custom graph creation has a hard, undocumented-in-
error-message requirement of NO scoping.
```
Expected: Unscoped access. A scoped user will fail to create a graph with no clear error pointing at scoping as the cause.

**Step 5 (custom graph only) — Confirm underlying data access, not just graph-creation permission**
```
Confirm the user/service actually has read access to every table referenced in the graph
spec (e.g., EntraUsers, EntraGroups, EntraMembers, EntraServicePrincipals). Missing access
to any one table does not error — it silently omits those nodes/edges from the graph.
```
Expected: Full read access to all referenced tables. Partial access produces an incomplete, not failed, graph — the most common source of "why are some relationships missing" tickets.

---
## Common Fix Paths

<details><summary>Fix 1 — Built-In Graph Not Appearing</summary>

**When:** A user expects to see Blast Radius on an incident, or the Hunting graph experience, and it isn't there.

```
Built-in graphs (Incident graph + Blast Radius, Hunting graph) auto-provision the moment
data lake onboarding completes and the user signs into the Defender portal — there is no
separate enable step, toggle, or license to check beyond data lake onboarding itself.

If missing:
1. Confirm data lake onboarding actually completed (see DataLake-B.md Fix 1/2 for DL102/
   DL103 onboarding failures) — this is almost always the real root cause, not the graph
   feature itself.
2. Confirm the user is viewing from the Defender portal, not the legacy Azure-portal
   Sentinel experience — built-in graphs are Defender-portal-only.
```

**Rollback:** N/A — diagnostic path, no destructive action.

</details>

<details><summary>Fix 2 — Missing Entra ID Role for Persisting</summary>

**When:** A user can successfully model and query a graph interactively in the notebook, but "Persist"/scheduling a graph job fails.

```
Confirm the user holds one of exactly THREE Entra ID directory roles required to persist
a graph — this is a completely separate permission system from the custom XDR RBAC role
that let them model the graph in the first place:
  - Security Operator
  - Security Administrator
  - Global Administrator

Holding the custom XDR "data (manage)" RBAC role used for modeling does NOT imply any of
these three Entra ID roles — they must be granted independently.
```

**Rollback:** N/A — permission grant, not destructive.

</details>

<details><summary>Fix 3 — Silent Data Access Gap</summary>

**When:** A custom graph builds and runs without error, but expected nodes or edges (e.g., certain users, groups, or service principals) never appear.

```
Confirm the identity that ran the notebook/graph job has read access to EVERY table
referenced in the graph spec. Microsoft's own documentation states this plainly: "If you
don't have access to a specific dataset, that data won't be included in the graph" — there
is no error, warning, or partial-build flag. The graph simply looks smaller/incomplete than
expected.

Check table-by-table access for the specific tables the graph spec references (e.g.,
EntraUsers, EntraGroups, EntraMembers, EntraServicePrincipals) rather than assuming
"data (manage)" at the collection level covers every underlying table.
```

**Rollback:** N/A — access-grant fix, not destructive. Re-run the graph job after granting access to pick up the missing data.

</details>

<details><summary>Fix 4 — Sentinel-Scoped User Cannot Create Graphs</summary>

**When:** A user with what looks like sufficient permissions still cannot create a custom graph, with no specific error identifying why.

```
Confirm whether the user's Sentinel access is scoped (limited to specific workspaces or
resources) rather than tenant-wide/unscoped. Per Microsoft's own documentation: "To create
a graph, you must not be restricted by a Sentinel scope. A scoped user isn't able to create
a custom graph." This is a hard architectural block, not a permission that can be granted
at the scoped level — the user needs unscoped access, which is a broader change than simply
adding a role.
```

**Rollback:** N/A — access-model change, not destructive, but broader than a typical role grant — confirm with the client before widening a user's scope tenant-wide.

</details>

<details><summary>Fix 5 — On-Demand Graph Expired</summary>

**When:** A previously-working materialized graph is gone, with no configuration change made.

```
Confirm how the graph job was originally scheduled. Graphs created with an "On demand"
schedule have a default 30-day retention and are automatically deleted on expiration — this
is documented, expected behavior, not data loss from a fault.

Fix: re-run the graph job (if the notebook/spec still exists), or reschedule it as a
recurring job (Hourly/Daily/Weekly/Monthly/By the minute) instead of On demand if ongoing
availability is required.
```

**Rollback:** N/A — expected lifecycle behavior. Prevention is rescheduling as recurring, not a fixable "bug."

</details>

<details><summary>Fix 6 — Rename vs. Overwrite Confusion</summary>

**When:** A technician tries to update an existing graph job and ends up with two graphs instead of one updated graph, or unexpectedly overwrites a graph they meant to keep.

```
Two different UI workflows produce two different outcomes — know which one is in play:

- "Edit graph job" -> changing the Graph name field CREATES A NEW graph; the original,
  differently-named graph remains unchanged and still exists. Description, cluster
  configuration, and job frequency changes in this same workflow DO update the existing
  graph in place (they rebuild it, they don't create a new one).

- "Create Scheduled Job" -> "Create a graph job" (from an updated notebook) -> entering an
  EXISTING graph name here overwrites that graph after a confirmation prompt. Graph names
  are unique tenant-wide; duplicates are not supported.

Confirm which workflow the technician actually used before assuming a bug — this is
documented, if easily confused, behavior.
```

**Rollback:** For an unwanted overwrite, no built-in undo exists — the prior graph's build is gone once overwritten and confirmed; only re-running the original notebook/spec recreates it.

</details>

<details><summary>Fix 7 — Spark Session Cold Start</summary>

**When:** The first cell run in a new custom graph notebook appears to hang for several minutes.

```
The first cell run in a session starts the underlying Spark compute pool, which takes
about 5 minutes by Microsoft's own documentation — this is normal cold-start latency, not
a failure. Subsequent cells in the same session run quickly once the Spark session is live.

If it exceeds roughly 10 minutes with no progress, treat as a genuine Spark/Fabric compute
issue (standard Fabric Spark troubleshooting applies — check pool health, resource
exhaustion, and driver logs) rather than continuing to wait indefinitely.
```

**Rollback:** N/A — diagnostic wait, no action taken.

</details>

<details><summary>Fix 8 — GQL Query or Schema Mismatch</summary>

**When:** A `MATCH` (GQL) query against a built custom graph returns no results or errors out.

```
1. Confirm the graph actually built successfully first (Job Details -> Status = Ready,
   not Queued/In Progress/Failed) before assuming the query itself is wrong.

2. Confirm the query's node/edge type names and property names match exactly what was
   defined in the GraphSpecBuilder spec (add_node/add_edge names, with_columns key/display
   fields) — GQL is schema-bound to however the graph was authored, not a generic query
   surface over raw data lake tables.

3. Confirm variable-length path syntax is correct for what's intended, e.g.
   -[edgeAlias]->{1,8} for "1 to 8 hops" — an unintended hop-count range is a common
   source of unexpectedly large or empty result sets.
```

**Rollback:** N/A — query correction, no destructive action against the graph itself.

</details>

---
## Escalation Evidence

Copy this template, fill in all fields, attach to ticket before escalating to Microsoft Support.

```
=== MICROSOFT SENTINEL GRAPH ESCALATION EVIDENCE PACK ===
Date/Time (UTC): _______________
Reported by: _______________
Tenant ID: _______________
Graph type: [ ] Built-in (Blast Radius/Hunting graph)  [ ] Custom graph (preview)
Graph name (if custom): _______________
Data lake onboarding status: [ ] Confirmed onboarded  [ ] Unknown/not confirmed

SYMPTOM:
[ ] Built-in graph not appearing
[ ] Cannot persist graph (missing Entra ID role)
[ ] Silent data access gap (missing nodes/edges)
[ ] Sentinel-scoped user blocked from graph creation
[ ] On-demand graph expired (30-day retention)
[ ] Rename vs. overwrite confusion
[ ] Spark session cold start mistaken for hang
[ ] GQL query/schema mismatch
[ ] Other: _______________

TRIAGE RESULTS:
User's XDR unified RBAC role(s): _______________
User's Entra ID directory role(s): _______________
User Sentinel-scoped: [ ] Yes  [ ] No  [ ] Unknown
Tables referenced in graph spec: _______________
Graph job schedule type: [ ] On demand  [ ] Recurring — frequency: _______________

ACTIONS TAKEN:
_______________

CORRELATION ID / Request ID: _______________
```

---
## 🎓 Learning Pointers

- **"Sentinel graph" names two unrelated things** — zero-setup built-in graphs (Blast Radius, Hunting graph) auto-provisioned with data lake onboarding, and code-first Custom graphs (preview) requiring VS Code, Jupyter, PySpark, and GQL authoring. Confirm which one a ticket means before doing anything else. Reference: [What is Microsoft Sentinel graph?](https://learn.microsoft.com/en-us/azure/sentinel/datalake/sentinel-graph-overview)
- **Three independent permission systems gate one feature** — modeling, persisting, and querying a custom graph each require a different, non-overlapping permission grant (two flavors of Defender XDR unified RBAC plus a plain Entra ID directory role for persisting). This is the same "looks like one gate, is actually several" shape this repo has now documented repeatedly (UEBA run 107, Notebooks run 109, DataLake run 110). Reference: [Get started with custom graphs](https://learn.microsoft.com/en-us/azure/sentinel/datalake/create-custom-graphs)
- **Missing data access fails silently, not loudly** — a graph missing read access to a referenced table simply omits that data, with no error. Always check per-table access before assuming a "broken" or incomplete graph is a platform bug.
- **On-demand graphs are temporary by design** — 30-day default retention with automatic deletion is documented behavior, not data loss. Recommend recurring schedules for anything meant to persist long-term.
- **Renaming in "Edit graph job" and reusing a name in "Create a graph job" do opposite things** — one creates a second graph, the other silently overwrites an existing one after confirmation. This distinction is easy to get backwards under ticket pressure and has no undo once overwritten.
