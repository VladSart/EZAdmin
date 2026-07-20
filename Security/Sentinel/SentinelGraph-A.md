# Microsoft Sentinel Graph — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

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

This runbook covers **Microsoft Sentinel graph** — a unified graph-analytics capability spanning two genuinely distinct experiences that share only a name and an underlying data foundation (the Sentinel data lake, `DataLake-A.md`):

- **Built-in embedded graphs** — Incident graph with Blast Radius analysis, Hunting graph, and Purview data risk graphs (Insider Risk Management, Data Security Investigations). These auto-provision automatically alongside data lake onboarding and require zero separate configuration.
- **Custom graphs (preview)** — code-first, tenant-modeled graphs built from Sentinel data lake tables (plus non-Microsoft sources) using Jupyter notebooks in VS Code, PySpark, a graph-spec builder library, and Graph Query Language (GQL). This is an entirely separate authoring workflow, permission model, and lifecycle from the built-in graphs.

This runbook assumes familiarity with `DataLake-A.md` (the underlying data lake, dual Azure-RBAC/Entra-ID-role access model, and onboarding prerequisites every graph capability depends on) and `Notebooks-A.md` (the general Jupyter/VS Code notebook environment this topic's custom-graph authoring workflow reuses, though custom graphs use a separate graph-specific Python library rather than MSTICPy).

**Assumes:**
- Microsoft Sentinel data lake onboarded and the tenant signed into the Defender portal (for built-in graphs)
- VS Code with the Microsoft Sentinel extension and Jupyter extension installed (for custom graphs)
- Familiarity with basic PySpark DataFrame operations (for custom graph authoring)

**Not covered:** Sentinel data lake onboarding mechanics and the dual Azure-RBAC/Entra-ID-role access model for KQL jobs (see `DataLake-A.md`); MSTICPy-based hunting notebooks (see `Notebooks-A.md`); Microsoft Security Exposure Management's Attack Path feature and Microsoft Defender for Cloud's own attack-path graphs, mentioned only as related pre-breach graph-based capabilities powered by the same underlying platform; full GQL language reference and the Sentinel graph provider library API surface, referenced only at the level needed for troubleshooting.

---
## How It Works

<details><summary>Full architecture</summary>

### Two products, one name, one shared foundation

Microsoft Sentinel graph is the umbrella name for a unified graph-analytics capability that powers graph-based experiences across Defender, Purview, and the broader Microsoft Security ecosystem. Rather than reasoning over interconnected assets, identities, activities, and threat intelligence as flat tables, it represents them as nodes and edges — enabling questions that are difficult or impossible in tabular form, such as "what is the blast radius of a compromised document" or "what could happen if this specific user account is compromised."

In practice, this umbrella splits into two products with almost nothing in common operationally:

1. **Built-in embedded graphs** ship as features inside Defender XDR and Purview: Incident graph extended with Blast Radius analysis, Hunting graph in Defender, and data risk graphs in Purview Insider Risk Management and Data Security Investigations. These auto-provision the moment a tenant with Sentinel data lake onboarded signs into the Defender portal — there is no separate enable action, license check, or configuration step.
2. **Custom graphs (preview)** are tenant-authored: security teams model their own nodes, edges, and relationships from Sentinel data lake tables (and non-Microsoft sources), using Jupyter notebooks in the VS Code Microsoft Sentinel extension, PySpark for data preparation, a `GraphSpecBuilder`/`Graph` Python library for schema definition, and Graph Query Language (GQL) for querying. This is powered by Fabric under the hood and requires its own Spark compute pool.

Both share the Sentinel data lake as their underlying data foundation, and both surface in the same Defender-portal graph visualization experience once built — but the authoring effort, permission model, and troubleshooting surface for each are entirely separate. A support ticket that simply says "the Sentinel graph is broken" is not yet actionable until this distinction is resolved.

### Built-in graphs: zero-configuration, portal-only

Blast radius analysis extends the existing Incident graph in Defender XDR to visualize the vulnerable paths an attacker could take from a compromised entity toward a critical asset — both current impact and possible future impact in one consolidated view. The Hunting graph lets analysts interactively traverse relationships between users, devices, and other entities to reveal privileged-access paths. Purview's data risk graphs perform the equivalent function for data-centric investigations: mapping sensitive-data access/movement and understanding data-leak blast radius from risky user activity.

None of these require the customer to author anything. They activate automatically once data lake onboarding (`DataLake-A.md`) completes and the graph capability is provisioned alongside it — the only troubleshooting surface here is confirming data lake onboarding itself succeeded, not anything graph-specific.

### Custom graphs: a code-first, Fabric-powered authoring workflow

Custom graphs let a team build tailored graphs for scenarios the built-in graphs don't cover — Microsoft's own documented examples include a phishing-email kill chain enriched with business context, DNS command-and-control beacon hunting, behavioral attack-chain detection across MITRE techniques, and OAuth privilege-escalation self-escalation cycles. Any table available in the Sentinel data lake can become a node or edge source.

The authoring workflow runs entirely inside VS Code:
1. A Jupyter notebook (via the Microsoft Sentinel VS Code extension) connects to the data lake using the `MicrosoftSentinelProvider` and reads tables as PySpark DataFrames.
2. A `GraphSpecBuilder` defines the graph schema — `add_node(...)`/`add_edge(...)` calls binding node/edge type names to DataFrames, key columns, and display columns.
3. `Graph.build(...)` validates the spec and prepares it for querying.
4. GQL `MATCH` queries traverse the graph — for example, `MATCH p=(g1:EntraGroup)-[cg]->{1,8}(g2)` finds nested group relationships up to 8 hops deep in a single clause, versus the multiple separate joins the equivalent KQL query would require.

Graphs authored this way can also be created via **AI-assisted authoring** as an alternative to hand-writing the PySpark/GraphSpecBuilder code — out of deep scope here beyond this mention.

### Ephemeral vs. materialized: the graph lifecycle

A graph built and queried inside an interactive notebook session is **ephemeral** — it exists only for that session and disappears when the session closes. To make a graph durable and shareable, it must be **persisted** by scheduling a **graph job**, which rebuilds the graph on a defined cadence and makes it accessible from three separate surfaces: the graph experience in the Defender portal, VS Code notebooks, and Graph query APIs.

Graph jobs can be scheduled **On demand** (build once, no recurring refresh) or on a **recurring** cadence (by the minute, hourly, daily, weekly, or monthly). **On-demand graphs carry a default 30-day retention and are automatically deleted on expiration** — a documented lifecycle behavior easily mistaken for data loss or a platform fault if a technician doesn't know to expect it.

### The permission model: three independent gates on one capability

Custom graphs are governed by three separate permission requirements that do not imply one another:

| Graph operation | Permission required |
|---|---|
| Model and build a notebook graph | Custom Microsoft Defender XDR unified RBAC role with **data (manage)** permission over the Sentinel data collection |
| Persist a graph in the tenant (schedule a graph job) | An Entra ID directory role: **Security Operator**, **Security Administrator**, or **Global Administrator** — a completely separate permission system from the XDR RBAC role above |
| Query a persisted graph | Custom Defender XDR unified RBAC role with **security data basics (read)** permission over the Sentinel data collection |

On top of this three-way split, two further hard constraints apply, both silent (no descriptive error) if violated:

- **Read access to underlying data is enforced per table, not once at the collection level.** If the identity building the graph lacks access to a specific dataset, that dataset's data is simply excluded from the resulting graph — no error, no partial-build warning.
- **A Sentinel-scoped user cannot create a custom graph at all.** Per Microsoft's own documentation: "To create a graph, you must not be restricted by a Sentinel scope. A scoped user isn't able to create a custom graph." This is a binary architectural constraint, not something addressable by granting more permissions at the scoped level — it requires unscoped access.

This is the same "looks like one gate, is actually several independently-gated things" shape this repo has now documented repeatedly across topics (UEBA's three-toggle model, LifecycleWorkflows' `IsEnabled`/`IsSchedulingEnabled` split, Notebooks' two-Azure-resource RBAC split, DataLake's dual-RBAC-on-one-resource model) — here manifesting as three permission systems plus two silent architectural constraints on a single feature.

### Editing vs. overwriting: a subtle, high-consequence UI distinction

Two visually similar workflows for changing an existing graph produce opposite outcomes:

- **"Edit graph job"** — changing the **Graph name** field creates a **new** graph; the original, differently-named graph is left unchanged and continues to exist. Changing Description, Cluster configuration, or Job frequency in this same workflow **does** update the existing graph in place (triggering a rebuild), rather than creating a new one.
- **"Create Scheduled Job" → "Create a graph job"** (from an updated notebook) — entering a graph name that already exists in the tenant **overwrites** that existing graph after a confirmation prompt, since graph names are unique tenant-wide and duplicates aren't supported.

A technician unfamiliar with this distinction can either accidentally end up with duplicate graphs, or unintentionally overwrite one they meant to preserve, with no built-in undo for the overwrite case.

### Cost consideration

Building and publishing a custom graph triggers billable Graph API calls (`Graph.prepare()` and `Graph.publish()` as separate calls, by design, so their respective costs can be understood independently before committing to a recurring schedule). Frequent recurring graph jobs on large datasets should be sized deliberately with this in mind — see Microsoft's Sentinel billing documentation for current pricing.

</details>

---
## Dependency Stack

```
Microsoft Sentinel data lake (onboarded — see DataLake-A.md)
  ├── Built-in embedded graphs (auto-provisioned, zero separate configuration)
  │     ├── Incident graph + Blast Radius (Defender XDR)
  │     ├── Hunting graph (Defender XDR)
  │     └── Data risk graphs (Purview Insider Risk Management / Data Security Investigations)
  └── Custom graphs (preview — Fabric-powered, entirely separate workflow)
        ├── Prerequisite: Entra ID connector enabled if graph uses Entra* asset tables
        ├── Tooling: VS Code + Microsoft Sentinel extension + Jupyter extension
        ├── Compute: Spark pool (Fabric-backed, ~5 min cold start on first cell run)
        ├── Authoring: PySpark DataFrames -> GraphSpecBuilder (nodes/edges) -> Graph.build()
        ├── Querying: Graph Query Language (GQL) MATCH clauses, schema-bound to the spec
        ├── Permission model (three independent, non-overlapping gates):
        │     ├── Model/build   -> XDR unified RBAC, "data (manage)"
        │     ├── Persist       -> Entra ID role: Security Operator/Administrator/Global Admin
        │     └── Query         -> XDR unified RBAC, "security data basics (read)"
        ├── Silent constraints (no descriptive error if violated):
        │     ├── Per-table read access — missing access = missing data, not an error
        │     └── User must be unscoped in Sentinel — scoped users blocked entirely
        └── Lifecycle
              ├── Ephemeral (interactive notebook session) — gone on session close
              └── Materialized (scheduled graph job)
                    ├── On demand -> 30-day default retention, auto-deletes on expiry
                    └── Recurring -> refreshes per schedule, no auto-expiry
                    └── Accessible from: Defender portal graph experience, VS Code, Graph APIs
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| No Blast Radius/Hunting graph visible on an incident | Data lake not yet onboarded, or user viewing the legacy Azure-portal Sentinel experience | Data lake onboarding state (`DataLake-B.md`); confirm Defender portal, not Azure portal |
| User can model a custom graph but "Persist"/schedule fails | Missing one of the three required Entra ID roles (Security Operator/Administrator/Global Administrator) | User's Entra ID directory role assignments, independent of their XDR RBAC role |
| Custom graph builds with no error, but expected relationships are missing | Identity lacks read access to one or more underlying tables referenced in the spec — fails silently | Per-table read access for every table the graph spec references |
| Custom graph creation fails for a user with seemingly sufficient permissions | User's Sentinel access is scoped, not tenant-wide — a hard architectural block | Whether the user's access is scoped to specific workspaces/resources |
| A previously-available materialized graph is gone | On-demand graph reached its default 30-day retention and auto-deleted | How the graph job was originally scheduled (On demand vs. recurring) |
| Two graphs exist where the technician expected one updated graph | "Edit graph job" name change creates a new graph rather than renaming in place | Which workflow (Edit vs. Create) was actually used, and whether the name changed |
| An existing graph was unexpectedly overwritten | A "Create a graph job" submission reused an existing graph name, triggering a silent-by-comparison overwrite after confirmation | Graph job creation history; confirm no unintended name reuse |
| First notebook cell appears to hang | Spark compute pool cold start (~5 minutes is normal on first run) | Elapsed time; standard Fabric Spark troubleshooting if it exceeds ~10 minutes |
| GQL `MATCH` query returns nothing or errors | Graph build not yet complete (Status ≠ Ready), or query references node/edge/property names that don't match the authored spec | Job Details status; query type/property names against the `GraphSpecBuilder` definition |
| Graph query looks correct but result set is unexpectedly huge or empty | Variable-length path hop-count range (e.g. `{1,8}`) doesn't match intent | The specific hop-count bound used in the `MATCH` clause |
| Recurring graph job cost seems high | Frequent rebuild schedule on a large dataset — `Graph.publish()` calls are independently billable from `Graph.prepare()` | Job frequency vs. dataset size; current Sentinel billing documentation |

---
## Validation Steps

**1. Disambiguate built-in vs. custom graph before any other step**
```
No command needed — confirm with the reporter which experience they mean. Built-in graphs
require no notebook/VS Code involvement at all; if the ticket mentions notebooks, GQL, or
"graph job," it is a custom-graph ticket.
```
Expected: A clear determination that shapes every subsequent validation step.

**2. Confirm data lake onboarding (prerequisite for both graph types)**
```powershell
# No direct Graph/PowerShell read for graph-specific state; confirm data lake onboarding
# via the managed-identity presence check already established in DataLake-A.md
Get-AzADServicePrincipal -DisplayNameBeginsWith "msg-resources-"
```
Expected: A managed identity matching this naming pattern is present, confirming data lake (and therefore built-in graph) onboarding succeeded.

**3. (Custom graphs) Confirm the Entra ID connector is enabled if Entra* tables are used**
```
Portal-only check: Sentinel data lake data connectors — confirm the Microsoft Entra ID
connector is enabled for asset ingestion if the graph spec reads EntraUsers, EntraGroups,
EntraMembers, or EntraServicePrincipals tables.
```
Expected: Connector enabled; otherwise those specific source tables won't exist to build from.

**4. (Custom graphs) Confirm the three permission layers independently**
```powershell
# XDR unified RBAC roles have no direct Az/Graph PowerShell surface as of this writing —
# confirm via the Defender portal's permissions/roles blade for the "data (manage)" and
# "security data basics (read)" custom role assignments.

# Entra ID directory role (persisting) IS checkable via Graph:
Get-MgUserMemberOf -UserId "<user@domain.com>" |
    Where-Object { $_.AdditionalProperties.displayName -in @("Security Operator","Security Administrator","Global Administrator") }
```
Expected: The specific role needed for the specific failing operation (model/persist/query) is present — do not assume one implies the others.

**5. (Custom graphs) Confirm the user is not Sentinel-scoped**
```
Portal-only check: Sentinel roles and permissions blade — confirm the user's access is
tenant-wide/unscoped, not limited to specific workspaces or resources.
```
Expected: Unscoped access for anyone expected to create custom graphs.

**6. (Custom graphs) Confirm underlying table access matches graph spec references**
```
Cross-reference every table name used in the notebook's GraphSpecBuilder definition
against the identity's actual read access to each — partial access produces a silently
incomplete graph, not an error.
```
Expected: Full read access to every referenced table.

**7. Confirm graph job status before troubleshooting a query**
```
VS Code Microsoft Sentinel extension -> graph panel -> Job Details tab -> Status.
```
Expected: `Ready`. `Queued`/`In Progress`/`Failed` all mean the query itself isn't the problem yet.

---
## Troubleshooting Steps (by phase)

### Phase 1: Disambiguation

1. Establish whether the ticket concerns a built-in graph (Blast Radius/Hunting graph, zero setup) or a custom graph (VS Code/notebook/GQL authoring)
2. Route to the correct remaining phases based on that answer — the two paths do not overlap beyond the shared data lake foundation

### Phase 2: Data Lake Foundation (both graph types)

1. Confirm data lake onboarding succeeded — both built-in and custom graphs depend on this
2. For built-in graphs specifically, confirm the user is in the Defender portal, not the legacy Azure-portal Sentinel experience

### Phase 3: Custom Graph Permissions

1. Identify the specific failing operation (model, persist, or query) and check only the corresponding permission layer
2. Confirm the user is not Sentinel-scoped if graph creation itself is blocked
3. Confirm per-table read access if the graph builds but appears incomplete

### Phase 4: Custom Graph Authoring & Compute

1. Rule out normal Spark cold-start latency (~5 minutes) before treating a slow first cell as a fault
2. Confirm the Entra ID connector and required source tables exist if specific Entra*-based nodes/edges are missing
3. Validate GQL query syntax and schema alignment against the `GraphSpecBuilder` definition if queries return unexpected results

### Phase 5: Graph Lifecycle

1. If a graph disappeared, confirm whether it was scheduled On demand (30-day auto-expiry) vs. recurring
2. If duplicate or overwritten graphs are reported, confirm which UI workflow (Edit vs. Create) was used and whether a graph name was changed or reused
3. For cost concerns, review job frequency against dataset size before assuming a billing anomaly

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield Custom Graph Rollout</summary>

Use when: Standing up a first custom graph for a new investigative scenario.

```
Step 1: Confirm data lake onboarding is complete and the Entra ID connector (or other
        relevant source connectors) is enabled for any tables the graph will use.

Step 2: Grant the three permission layers deliberately and separately, to the correct
        people for each role — do not assume one grant covers all three:
          - Modeler/author: custom XDR RBAC role with "data (manage)"
          - Person who will persist/schedule: Entra ID Security Operator/Administrator/
            Global Administrator
          - Consumers who will only query: custom XDR RBAC role with
            "security data basics (read)"

Step 3: Confirm the modeler's account is NOT Sentinel-scoped before they attempt to
        author anything — this blocks graph creation with no clear error if missed.

Step 4: Author the graph in a VS Code notebook, validate the schema
        (graph_spec.show_schema()), and confirm results look correct in an interactive
        session before persisting.

Step 5: Schedule as a recurring graph job (not On demand) if the graph needs to remain
        available long-term, sized to an appropriate refresh frequency for the data
        volume and investigative need.

Step 6: Confirm the persisted graph is queryable from the Defender portal graph
        experience by a consumer holding only the query-level permission.
```

**Rollback:** Delete the graph job if the rollout doesn't meet requirements; this does not affect the underlying Sentinel data lake tables the graph was built from.

</details>

<details><summary>Playbook 2 — Diagnose an Incomplete Custom Graph</summary>

Use when: A custom graph builds successfully but is missing expected nodes, edges, or relationships.

```
Step 1: List every table referenced in the graph spec's node/edge DataFrame sources.

Step 2: For each table, independently confirm the identity that ran the notebook/graph
        job has read access — do not assume collection-level "data (manage)" access
        implies per-table access to everything.

Step 3: For any table with confirmed missing access, grant access and re-run the graph
        job (interactive re-build first to confirm, then re-persist if scheduled).

Step 4: If all table access is confirmed correct and data is still missing, check
        whether the relevant source connector (e.g., Entra ID connector for Entra*
        tables) is actually enabled and ingesting — a disabled connector produces the
        same "table exists but appears empty" symptom as a permission gap.
```

**Rollback:** N/A — this is an access/connector diagnostic and grant process, not a destructive change.

</details>

<details><summary>Playbook 3 — Recover from an Unintended Graph Overwrite</summary>

Use when: A "Create a graph job" submission accidentally overwrote an existing graph by reusing its name.

```
Step 1: Confirm there is no built-in undo for a confirmed overwrite — the prior graph's
        materialized state is gone.

Step 2: If the original notebook/spec that produced the overwritten graph still exists
        (locally or in source control), re-run it and persist under either the same name
        (accepting a second overwrite back to the original state) or a new name to avoid
        further ambiguity.

Step 3: Going forward, standardize team practice: renaming an existing graph via "Edit
        graph job" creates a new graph (safe, non-destructive to the original); reusing
        a name in "Create a graph job" overwrites (destructive, requires explicit
        confirmation) — train technicians on this distinction before it causes a second
        incident.
```

**Rollback:** Only possible if the original authoring notebook/spec is independently preserved outside the platform itself — the platform provides no version history for overwritten graphs.

</details>

<details><summary>Playbook 4 — Right-Size a Recurring Graph Job for Cost</summary>

Use when: A client's recurring custom graph job is contributing more than expected to Sentinel billing.

```
Step 1: Confirm the job's current frequency (By the minute/Hourly/Daily/Weekly/Monthly)
        against the actual investigative need for freshness — many scenarios don't
        require sub-hourly rebuilds.

Step 2: Confirm dataset size/scope in the graph spec — narrowing node/edge source
        DataFrames (e.g., filtering to a relevant time window or subset of entities)
        reduces both build cost and result-set noise.

Step 3: Reduce frequency and/or narrow scope, then re-schedule and monitor the next
        billing cycle for the expected reduction, since Graph.prepare()/Graph.publish()
        costs scale with both frequency and data volume.

Step 4: Consider whether an On-demand schedule (rebuilt manually when needed, with
        30-day auto-expiry) better fits an infrequently-used investigative graph than
        an always-on recurring schedule.
```

**Rollback:** Restore the original frequency/scope if narrowing degraded the graph's usefulness for its intended investigations — no data is lost by adjusting schedule/scope going forward.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Microsoft Sentinel graph diagnostic evidence (data lake foundation + Entra ID role check)
.NOTES     Requires Az.Resources and Microsoft.Graph modules; most graph-specific state is portal/VS-Code-only
#>

param(
    [Parameter(Mandatory)][string]$UserPrincipalName
)

$outputPath = "C:\SentinelGraph_Diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

# Data lake onboarding signal (both graph types depend on this)
Get-AzADServicePrincipal -DisplayNameBeginsWith "msg-resources-" |
    ConvertTo-Json -Depth 5 | Out-File "$outputPath\datalake_managed_identity.json"

# Entra ID directory role check (persist-a-graph permission layer)
try {
    Get-MgUserMemberOf -UserId $UserPrincipalName -ErrorAction Stop |
        Where-Object { $_.AdditionalProperties.displayName -in @("Security Operator","Security Administrator","Global Administrator") } |
        Select-Object -ExpandProperty AdditionalProperties |
        ConvertTo-Json -Depth 5 | Out-File "$outputPath\entra_id_role_check.json"
} catch {
    Write-Warning "Could not read Entra ID role membership for $UserPrincipalName — confirm Microsoft.Graph module connection."
}

Write-Host "NOTE: XDR unified RBAC role assignments (data (manage) / security data basics (read))," -ForegroundColor Yellow
Write-Host "Sentinel scoping state, graph job status/schedule, per-table data access, and GQL query" -ForegroundColor Yellow
Write-Host "results all have no public PowerShell/Graph API surface as of this writing. Capture these" -ForegroundColor Yellow
Write-Host "manually from the Defender portal permissions blade and the VS Code Microsoft Sentinel" -ForegroundColor Yellow
Write-Host "extension's graph panel, and attach alongside this evidence pack." -ForegroundColor Yellow

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# Confirm data lake onboarding (prerequisite for both built-in and custom graphs)
Get-AzADServicePrincipal -DisplayNameBeginsWith "msg-resources-"

# Confirm a user's Entra ID directory roles (persist-a-graph permission layer)
Get-MgUserMemberOf -UserId "<user@domain.com>" |
    Where-Object { $_.AdditionalProperties.displayName -in @("Security Operator","Security Administrator","Global Administrator") }

# NOT available via PowerShell/Graph as of this writing — VS Code Sentinel extension or
# Defender portal only:
#   - XDR unified RBAC role assignments ("data (manage)" / "security data basics (read)")
#   - Sentinel scoping state for a user
#   - Graph job status, schedule, and history
#   - Per-table data access as it applies to a specific graph spec
#   - GQL query execution/results

# Sample GQL query pattern (run inside a VS Code Sentinel notebook against a built graph)
# MATCH p=(g1:EntraGroup)-[cg]->{1,8}(g2) WHERE g1.displayName = '<group-name>' RETURN *
```

---
## 🎓 Learning Pointers

- **One name, two products** — built-in embedded graphs (Blast Radius, Hunting graph) need zero configuration beyond data lake onboarding, while Custom graphs (preview) are a full code-first VS Code/PySpark/GQL authoring workflow. Establish which one a ticket means before doing anything else. Reference: [What is Microsoft Sentinel graph?](https://learn.microsoft.com/en-us/azure/sentinel/datalake/sentinel-graph-overview)
- **Three permission systems gate one custom-graph capability, and none implies the others** — modeling and querying use two different Defender XDR unified RBAC permissions, while persisting requires a completely separate Entra ID directory role. This is the same "several independent gates disguised as one feature" shape documented elsewhere in this repo for UEBA, Notebooks, and the data lake itself. Reference: [Get started with custom graphs](https://learn.microsoft.com/en-us/azure/sentinel/datalake/create-custom-graphs)
- **Two silent failure modes with zero error messages**: missing per-table data access quietly omits data from a graph rather than erroring, and Sentinel-scoped users are blocked from graph creation entirely with no descriptive message pointing at scoping as the cause. Both require reading the documentation's exact wording, not inferring behavior from the UI.
- **On-demand graphs are temporary by design** — 30-day default retention with silent auto-deletion is documented lifecycle behavior; anything meant to persist should be scheduled recurring instead.
- **"Edit" and "Create" do opposite things to an existing graph** — renaming via Edit creates a second graph, while reusing a name via Create overwrites the first one after confirmation, with no undo. Train technicians on this distinction proactively rather than after an incident.
- **Graph.prepare() and Graph.publish() are deliberately separate, billable calls** — sizing a recurring graph job's frequency and data scope against actual investigative need avoids surprise costs, since publish cost scales with both.
