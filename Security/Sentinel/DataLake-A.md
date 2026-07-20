# Microsoft Sentinel Data Lake — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This covers the **Microsoft Sentinel data lake** — the cold-storage, long-retention (up to 12 years) tier that sits alongside Sentinel's existing hot analytics tier, plus the tools that operate on it: **KQL jobs**, **data federation** (Azure Databricks, ADLS Gen 2, Microsoft Fabric), and **tenant onboarding/access model**. It is the fifth pillar of this repo's Sentinel analyst-workflow coverage, sitting alongside [[Security/Sentinel/DataConnectors-A]] (ingest), [[Security/Sentinel/AnalyticsRules-A]] (detect), [[Security/Sentinel/UEBA-A]] (behavioral baseline), [[Security/Sentinel/Hunting-A]] (query/bookmark/Hunts-based hunting), and [[Security/Sentinel/Notebooks-A]] (code-first analysis) — the data lake is the storage and query substrate several of those other topics already depend on (KQL jobs were introduced in `Hunting-A.md` only as the retired-Livestream replacement; this topic covers the data lake itself as a standalone architecture).

**Explicitly out of scope here** (covered elsewhere or genuinely out of scope for this repo):
- Jupyter notebook authoring and MSTICPy configuration — see `Notebooks-A.md`/`Notebooks-B.md`. "Notebooks on the lake" (running notebooks directly against data lake tables/federated sources rather than a Sentinel workspace) shares the same AML-workspace prerequisite documented there.
- Hunting query authoring, Bookmarks, and the Hunts (Preview) wrapper — see `Hunting-A.md`. This topic covers KQL **jobs** specifically as a data lake tool, not the broader hunting query library.
- Summary rules and Search jobs are covered here only as decision-table alternatives to KQL jobs, not in full operational depth — both predate the data lake and work independently of it.
- Microsoft Sentinel graph (the unified graph capability, blast-radius analysis, hunting graph) — enabled automatically as part of data lake onboarding but is a distinct analyst-facing feature with its own UI, not covered in depth here.
- Microsoft Purview Data Security Investigations and Insider Risk Management's use of data lake/graph data — mentioned only as consumers of the same onboarding, not covered as their own topics.

---
## How It Works

<details><summary>Full architecture</summary>

Microsoft Sentinel has historically offered a single hot storage tier (the Log Analytics-backed **analytics tier**) plus a cheaper but query-limited **Archive tier** for data past its interactive retention window. The data lake adds a genuinely different third tier: a **fully managed, Parquet-based, open-format lake** with separated storage and compute, designed to hold up to **12 years** of security data cost-effectively while remaining queryable.

```
┌───────────────────────────────────────────────────────────────────┐
│  Analytics tier (existing Sentinel/Log Analytics)                  │
│  Hot, real-time. Interactive retention: 90 days default,           │
│  extensible to 2 years. Powers analytics rules, incidents,         │
│  workbooks, unlimited-query interactive hunting at no per-query    │
│  charge.                                                            │
└─────────────────────────┬───────────────────────────────────────────┘
                           │ mirrored forward from data lake onboarding
                           │ date onward (pre-existing data NOT backfilled)
                           ▼
┌───────────────────────────────────────────────────────────────────┐
│  Microsoft Sentinel data lake tier                                  │
│  Cold, Parquet open format, single copy of data, storage/compute    │
│  separated. Up to 12 years retention. ~15 min typical ingestion     │
│  latency for new rows (cold storage, not near-real-time).           │
│    ├─ System tables (Entra ID, Microsoft 365, Azure Resource Graph  │
│    │    asset data — auto-ingested on onboarding)                   │
│    ├─ Mirrored analytics-tier tables (same retention, no extra      │
│    │    charge for the mirror itself — separate meter for lake      │
│    │    tier retention beyond that)                                 │
│    ├─ Auxiliary log tables (absorbed from Defender connected        │
│    │    workspaces — no longer visible in Advanced Hunting once     │
│    │    absorbed)                                                   │
│    └─ Federated tables (Databricks/ADLS Gen2/Fabric — queried in    │
│         place, never physically copied into the lake)               │
└───────────────────────────┬───────────────────────────────────────┘
                             │ queried via
                             ▼
        KQL queries/jobs  │  Jupyter notebooks (AML)  │  MCP tools
```

**Why a third tier exists, architecturally.** The analytics tier's economics (near-real-time indexing, unlimited free interactive queries) only make sense for data that's actually queried frequently — "primary security data" in Microsoft's own categorization (auth logs, EDR, audit trails, TI feeds). High-volume, low-per-event-value "secondary security data" (NetFlow, proxy, firewall, cloud storage access logs) doesn't need millisecond query performance, but organizations still want it retained and queryable for retrospective investigations, threat hunting, and compliance. The data lake's separated storage/compute model and open Parquet format let Microsoft price this dramatically cheaper per GB while still supporting real KQL and Python/Jupyter analysis — at the cost of the ~15-minute ingestion latency and, for genuinely new tables, a 90–120 minute activation window that a hot tier doesn't have.

**The dual access-control model — the single most consequential architectural fact in this topic.** Sentinel SIEM (analytics tier: incidents, analytics rules, workbooks, playbooks) has always used **Azure RBAC** — role assignments scoped to a resource group or workspace (Sentinel Reader/Responder/Contributor). The data lake instead uses **Microsoft Entra ID directory roles** — tenant-wide roles (Global Reader, Security Reader, Security Operator, Security Administrator, Global Administrator) that are not scoped to a single Azure resource at all. These are two entirely separate authorization planes:

- Holding **Microsoft Sentinel Contributor** (Azure RBAC) grants interactive data lake *queries* on workspaces that role covers — but grants **nothing** toward creating, scheduling, or managing KQL jobs.
- Creating or scheduling **any** KQL job — reading OR writing — requires one of the three write-capable Entra ID roles (Security Operator, Security Administrator, Global Administrator), regardless of what Azure RBAC role the user holds.
- This is the same "looks like one gate, is actually several independent ones" shape already documented for `Notebooks-A.md`'s dual-Azure-resource RBAC split, `EntraID/Troubleshooting/LifecycleWorkflows-A.md`'s `IsEnabled`/`IsSchedulingEnabled` split, and `UEBA-A.md`'s three-independently-gated-capabilities model — but here the split isn't across two Azure resources or two feature flags, it's across **two entirely different RBAC systems layered on the same resource**, which makes it the easiest of the three to miss during a routine access review that only checks Azure RBAC.

**Onboarding is a single, tenant-wide, largely irreversible decision.** A tenant has exactly one data lake, provisioned once from the Defender portal (`security.microsoft.com` → onboarding banner, or **System → Settings → Microsoft Sentinel → Data lake**), locked permanently to the subscription, resource group, and **region of the primary Sentinel workspace** at the time of onboarding — none of those three can be changed after the fact. Onboarding automatically attaches **every** Defender-connected Sentinel workspace in that same region (no selective opt-in per workspace) and begins ingesting Entra ID, Microsoft 365, and Azure Resource Graph asset data into new **System tables** — if that data isn't already in the data lake's region, onboarding is itself the action that consents to moving it there. Offboarding — whether the whole tenant or a single workspace — has no self-service path at all; both require a Microsoft support request.

**Workspaces using Customer-Managed Keys (CMK) cannot use the data lake at all.** This is stated as a flat incompatibility in Microsoft's own prerequisites, not a configurable restriction — CMK-protected workspaces are simply invisible to data lake experiences. Since CMK is frequently a client-mandated compliance control rather than an incidental setting, this is worth surfacing to a client proactively during any Sentinel modernization conversation, not discovered mid-project.

**KQL jobs vs. Summary rules vs. Search jobs — three tools that solve adjacent but distinct problems.** All three "run a query and store/promote results," which is why they get confused in tickets:

| | KQL jobs | Summary rules | Search jobs |
|---|---|---|---|
| Best for | Deep investigation queries needing joins/unions across up to 12 years | Frequent (as often as every 20 min) aggregation of high-volume logs | One-time hydration of a single table, including from Archive tier |
| Requires data lake onboarding | Yes | No — works on Analytics/Auxiliary/Basic tiers directly | No |
| Can query federated tables | **Yes** | No | No |
| Join support | Full KQL joins/unions | Analytics tier: full; Basic tier: `lookup()` against up to 5 tables only | Not supported |
| Output destination | New/existing table, analytics or data lake tier | Custom table, analytics tier only | New custom table, analytics tier only |
| Timeout | 1 hour (partial results promoted if exceeded) | 10 minutes | 24 hours |

Reach for a **KQL job** by default for anything investigative or historical; reach for a **Summary rule** specifically when the need is frequent, lightweight aggregation of high-volume logs (the out-of-the-box template library exists for exactly this); reach for a **Search job** only when hydrating a single table wholesale, especially from Archive tier or from before the tenant's data lake onboarding date (KQL jobs only reach data from the onboarding date forward).

**Data federation queries external stores without copying them.** Federated connections to Azure Databricks (Unity Catalog), ADLS Gen 2, or Microsoft Fabric Lakehouses let KQL queries, KQL jobs, and Notebooks reference external tables — named `<tableName>_<connectorInstanceName>` — as if they were native lake tables, without ever physically ingesting the data. This is deliberately **one-directional and read-only**: the data lake can query the federated source, never the reverse, and federated tables cannot be a KQL job's *output* destination. The prerequisite that trips up the most setups is that the **external source itself must be publicly network-accessible** — private endpoints on the Databricks/ADLS/Fabric side are not currently supported, which is a hard blocker for security-conscious data platforms that default to network isolation.

</details>

---
## Dependency Stack

```
Layer 0 — Tenant prerequisites (before onboarding)
  Primary Sentinel workspace connected to the Defender portal
  Direct Azure subscription Owner (management-group-level Owner is NOT sufficient)
  Data lake region availability (locked to the primary workspace's region)
  Workspace NOT protected by Customer-Managed Keys (CMK)  ◄── hard, unconditional incompatibility

Layer 1 — Onboarding (one-time, tenant-wide, ~60 min)
  Azure Policy allows Microsoft.SentinelPlatformServices/sentinelplatformservices
    (blocked → DL103 — needs a policy exemption scoped to the target resource group)
  Sufficient regional Azure capacity (transient failure → DL102 — retry)
  Subscription + resource group + region choice — PERMANENT once set
  Auto-attaches ALL Defender-connected Sentinel workspaces in-region (no selective opt-in)

Layer 2 — Managed identity (created automatically during onboarding)
  msg-resources-<guid> — system-assigned managed identity
    Auto-granted: Azure Reader over onboarded subscriptions
    NOT auto-granted: Log Analytics Contributor — must be manually assigned per workspace
      to allow KQL jobs to create NEW custom tables in the analytics tier

Layer 3 — Access control (TWO INDEPENDENT SYSTEMS on the same resource)
  Azure RBAC (Sentinel SIEM surface — unchanged from pre-data-lake Sentinel)
    Sentinel Reader/Responder/Contributor → incidents, rules, workbooks, playbooks
    ALSO grants: interactive data lake queries on covered workspaces (read only)
  Entra ID directory roles (Data lake surface — entirely separate system)
    Read:  Global Reader / Security Reader / Security Operator / Security Administrator /
           Global Administrator
    Write: Security Operator / Security Administrator / Global Administrator
           (required for ANY KQL job creation, scheduling, or management — no Azure RBAC
           substitute exists)

Layer 4 — Storage tiers
  Analytics tier — hot, 90 days default / up to 2 years, unlimited free interactive queries
  Data lake tier — cold, up to 12 years, ~15 min routine ingestion latency,
    90–120 min for newly enabled tables or tier switches
    Mirrors analytics tier data FORWARD from onboarding date only (no retroactive backfill)

Layer 5 — Data access tools (pick correctly — see How It Works comparison table)
  KQL queries (interactive, 500,000-row cap) / KQL jobs (up to 12 yr, 1 hr timeout, no row cap)
  Summary rules (frequent aggregation, works without data lake onboarding)
  Search jobs (single-table hydration, works on Archive tier)
  Jupyter notebooks (AML-hosted — see Notebooks-A.md for that resource's own RBAC layer)

Layer 6 — Data federation (optional, per-connection)
  Service principal + Azure Key Vault (public network access required during setup)
  External source PUBLIC network accessibility (private endpoints unsupported)
  Connector instance limits: 100 max per tenant; Fabric max 100 tables per connection
  Read-only, one-directional — cannot write back, cannot be a job's output table
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| User has Sentinel Contributor but "Create job" is missing/errors | Entra ID directory role (Security Operator+) not assigned — Azure RBAC does not grant job rights | `Get-MgUserMemberOf` filtered to Security Operator/Administrator/Global Administrator |
| "Get started" banner never appeared, or onboarding never completes | Missing Subscription Owner/Contributor or Entra Global/Security Administrator role on the onboarding account | Confirm both role types on the account attempting onboarding |
| Onboarding fails with **DL102** | Transient regional Azure resource capacity shortage | Retry the setup |
| Onboarding fails with **DL103** | Azure Policy blocks `Microsoft.SentinelPlatformServices/sentinelplatformservices` | Add a scoped policy exemption, retry |
| KQL job errors "cannot create new custom table" / write denied on a new table | Managed identity `msg-resources-<guid>` lacks Log Analytics Contributor on the destination workspace | `Get-AzRoleAssignment -Scope <workspace>` filtered to the managed identity |
| Newly enabled table or a table that just switched tiers shows no data | Still inside the documented 90–120 minute activation window | Wait; re-check after the window closes |
| Scheduled job "misses" the most recent few minutes of data every run | No delay buffer built into the query — cold storage has ~15 min routine ingestion latency | Add `now() - 15m` (or larger) delay logic to the query |
| Auxiliary log table no longer visible in Defender Advanced Hunting | Expected — absorbed into data lake exploration once onboarded, not deleted | Redirect the user to Data lake exploration KQL queries/Notebooks |
| Interactive KQL query truncates or errors past 500,000 rows | Interactive queries are row-capped; only jobs/Notebooks are not | Move the query into a KQL job |
| Job writes fewer rows than the query should return | Query exceeded the 1-hour job timeout; **partial results were promoted**, not a clean failure | Narrow the time range/filters and re-run |
| Federated table connector setup fails | External source (Databricks/ADLS/Fabric) has private endpoints or restricted public network access | Confirm the external source's network posture — currently unsupported if restricted |
| KQL job/query references a federated table as its OUTPUT destination and fails | Federated tables are read-only, one-directional — never a valid write target | Change the job's destination to an analytics- or lake-tier table |
| Workspace never shows the data lake onboarding option at all | Workspace is CMK-protected — unconditional incompatibility | Confirm via the linked Log Analytics cluster's key configuration |
| Data older than the tenant's onboarding date is missing from a KQL job's results | KQL jobs only reach data mirrored from the onboarding date forward | Use a **Search job** against Archive tier for pre-onboarding data instead |
| `ingestion_time()`, `adx()`, `arg()`, or `externaldata()` used in a lake query fails | These four functions are explicitly unsupported in the data lake KQL engine | Rewrite the query without them |
| Billing spiked sharply after onboarding | Existing SIEM billing meters (search jobs, auxiliary logs, long-term retention/Archive) switch to data lake-based billing meters on onboarding — a documented, expected cost-model change | Review [Manage and monitor costs](https://learn.microsoft.com/en-us/azure/sentinel/billing-monitor-costs#manage-and-monitor-costs-for-the-data-lake-tier) with the client before/soon after onboarding |

---
## Validation Steps

1. **Confirm the tenant is actually onboarded.**
   ```powershell
   Get-AzRoleAssignment -ResourceGroupName <DataLakeRG> | Where-Object { $_.DisplayName -like "msg-resources-*" }
   ```
   Good: the managed identity exists. Bad: nothing found — onboarding was never completed, not just "not visible to this user."

2. **Confirm the managed identity's write capability on the target workspace, if custom-table creation is needed.**
   ```powershell
   Get-AzRoleAssignment -Scope $sentinelWs.ResourceId | Where-Object { $_.DisplayName -like "msg-resources-*" }
   ```
   Good: `Log Analytics Contributor` present. Bad: only the default `Reader` role (or nothing) — new custom tables via KQL job will fail on this workspace specifically.

3. **Confirm the affected user's Entra ID directory role — independently of their Sentinel Azure RBAC role.**
   ```powershell
   Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
   Get-MgUserMemberOf -UserId <user@domain.com> | Where-Object { $_.AdditionalProperties.displayName -match "Security Operator|Security Administrator|Global Administrator" }
   ```
   Good: at least one write-capable role present for job creation/scheduling; Global Reader/Security Reader is sufficient for read-only cross-workspace queries. Bad: none present — this precisely explains "I can query in the portal but can't save a job."

4. **Confirm workspace CMK status before assuming data lake features should be available at all.**
   Check the Log Analytics **cluster** (not the workspace itself) linked to the Sentinel workspace for a customer-managed key configuration. If present, data lake features are unavailable by design — stop troubleshooting access and set expectations instead.

5. **Confirm ingestion timing before treating "missing data" as a fault.**
   For a newly enabled table or a tier switch: allow 90–120 minutes. For routine new rows in an existing table or federated table: allow ~15 minutes. Re-run the check after the appropriate window.

6. **For a failing KQL job, capture the exact error text and match it against the Fix 4 error table in `DataLake-B.md`** before investigating further — most job failures map directly to a documented, actionable cause.

7. **For federated table issues, confirm the external source's public network accessibility** — this is checked on the Databricks/ADLS Gen 2/Fabric side, not in Sentinel, and is the most common federation setup failure.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Onboarding state.** Run Validation Step 1. If the tenant was never onboarded, nothing else in this topic applies — route to onboarding (Remediation Playbook 1) rather than diagnosing individual features.

**Phase 2 — Tool selection.** Before troubleshooting a specific "broken" query/job, confirm the right tool was used for the scenario (KQL job vs. Summary rule vs. Search job vs. federation) per the How It Works comparison table. A large share of tickets in this topic are tool-selection mistakes, not defects.

**Phase 3 — Access.** Run Validation Steps 2–3. Azure RBAC and Entra ID directory roles must both be checked — assume neither implies the other. This is the single highest-yield check in the whole topic.

**Phase 4 — Timing.** Run Validation Step 5. Cold-storage latency (15 min routine, 90–120 min for new tables/tier switches) explains a large share of "data is missing" tickets that aren't actually data loss.

**Phase 5 — Query/job-specific errors.** Run Validation Steps 6–7 as applicable. Match exact error text to the known-error tables before assuming a novel bug — Microsoft's own troubleshooting doc for this surface is unusually complete.

**Phase 6 — Escalate with evidence, not conclusions.** If a genuinely new/undocumented error appears, or DL102/DL103 persists after policy exemption and retry, package the Evidence Pack output and escalate rather than continuing to guess — this platform is under active development and error surfaces do change between Microsoft Learn revisions.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield onboarding for a new client</summary>

1. Confirm prerequisites: Defender-connected primary Sentinel workspace, a subscription where the requester holds **direct** Owner (not inherited from a management group), and confirm the workspace is **not** CMK-protected.
2. From the Defender portal, complete onboarding (subscription + resource group selection is permanent — confirm this with the client explicitly before proceeding, especially for clients with strict resource-group naming/governance standards).
3. Immediately after onboarding, grant the data lake managed identity (`msg-resources-<guid>`) **Log Analytics Contributor** on every workspace where custom-table-creating KQL jobs are expected, rather than waiting for the first job failure to discover the gap.
4. Assign Entra ID directory roles deliberately, least-privilege first: **Security Operator** for analysts who need to create/schedule jobs; **Global Reader** or **Security Reader** for read-only cross-workspace query access; reserve **Security Administrator**/**Global Administrator** for genuine admin needs, not as a default job-creation workaround.
5. Review the client's existing SIEM billing (search jobs, auxiliary logs, Archive/long-term retention) with them before or immediately after onboarding — these switch to data-lake-based billing meters automatically and can materially change monthly cost.
6. Confirm success: a test KQL job against a System table (Entra ID sign-in data, auto-ingested on onboarding) completes and writes to a destination table within the expected timing windows.

No rollback via self-service once onboarded — treat step 2 as the one genuinely irreversible decision point in this playbook and get explicit client sign-off before executing it.

</details>

<details><summary>Playbook 2 — Migrating a client from ad-hoc Search jobs / Archive-tier querying to KQL jobs</summary>

1. Confirm the tenant is onboarded to the data lake (Validation Step 1) — KQL jobs are unavailable otherwise.
2. Identify which existing Search job workflows are candidates: multi-table joins/unions are the clearest win (Search jobs don't support joins at all); single-table wholesale hydration should stay on Search jobs, especially for Archive-tier or pre-onboarding-date data KQL jobs cannot reach.
3. Rebuild the query as a scheduled KQL job with an explicit `now() - 15m` (or larger) delay buffer to avoid missing late-arriving data.
4. Point the job's output at an existing analytics-tier table where possible to avoid the extra Log Analytics Contributor grant step; if a new table is genuinely needed, complete Playbook 1 step 3 first.
5. Validate the first few scheduled runs land within the expected latency window and the output schema matches on every run, not just the first — schema drift in the source data will start failing writes to an *existing* destination table silently otherwise.

</details>

<details><summary>Playbook 3 — Setting up data federation to an external Databricks/ADLS Gen 2/Fabric source</summary>

1. Confirm the external source is **publicly network-accessible** — this is a hard prerequisite today; if the client's Databricks/ADLS/Fabric deployment is locked to private endpoints, stop here and document this as a known limitation rather than attempting workarounds.
2. Create a service principal with appropriate read permissions in the external source.
3. Store the service principal's credentials in an Azure Key Vault; during setup, that Key Vault must allow **public access from all networks** (it can be re-restricted after the connection is created and validated).
4. In the Defender portal's **Data connectors** page, create a connector instance for the source type, select the tables to federate, and confirm the resulting federated table names (`<tableName>_<connectorInstanceName>`) don't collide with existing native tables.
5. Validate with a simple KQL query against the federated table before building anything more complex on top of it — remember federated tables can never be a KQL job's output destination, and query performance depends entirely on the external source's own responsiveness.
6. Track connector instance count against the 100-per-tenant ceiling if the client federates many sources (Fabric additionally caps at 100 tables per lakehouse-schema connection).

Rollback: delete the connector instance from the Data connectors page; this does not affect the external source's own data, since federation never copies it.

</details>

<details><summary>Playbook 4 — Full offboarding request</summary>

1. Confirm this is genuinely desired at the tenant level — offboarding cannot be scoped to a single workspace via self-service, and reverses auxiliary-table visibility, disables all KQL jobs/federated connections, and affects Purview Data Security Investigations/Insider Risk Management graph features that also consume the same data lake.
2. Document the business driver (cost, compliance, platform consolidation) for the support ticket.
3. [Submit a support request](https://learn.microsoft.com/en-us/defender-xdr/contact-defender-support) explicitly requesting Microsoft Sentinel data lake offboarding — there is no self-service control.
4. Set client expectations on timeline; this is a manual, Microsoft-side operation with no published SLA in the current documentation.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Microsoft Sentinel data lake readiness/access evidence for escalation.
.NOTES     Read-only. Requires Az.Accounts, Az.OperationalInsights, Az.Resources, and (for the
           Entra ID role check) Microsoft.Graph.Users / Microsoft.Graph.Identity.DirectoryManagement.
           Cannot inspect: individual KQL job execution history/logs, federated connector health,
           or Notebooks-on-the-lake state — capture those from the Defender portal directly.
#>
param(
    [Parameter(Mandatory)][string]$DataLakeResourceGroup,
    [Parameter(Mandatory)][string]$SentinelResourceGroup,
    [Parameter(Mandatory)][string]$SentinelWorkspaceName,
    [string]$UserPrincipalName
)

$evidence = [ordered]@{}

$identity = Get-AzADServicePrincipal -DisplayNameBeginsWith "msg-resources-" -ErrorAction SilentlyContinue
$evidence["DataLakeOnboarded"] = [bool]$identity
$evidence["ManagedIdentity"] = $identity | Select-Object DisplayName, Id

if ($identity) {
    $sentinelWs = Get-AzOperationalInsightsWorkspace -ResourceGroupName $SentinelResourceGroup -Name $SentinelWorkspaceName
    $evidence["ManagedIdentityWorkspaceRoles"] = Get-AzRoleAssignment -Scope $sentinelWs.ResourceId -ObjectId $identity.Id
}

if ($UserPrincipalName) {
    try {
        $roles = Get-MgUserMemberOf -UserId $UserPrincipalName -ErrorAction Stop |
            Where-Object { $_.AdditionalProperties.displayName -match "Security Operator|Security Administrator|Global Administrator|Global Reader|Security Reader" }
        $evidence["UserEntraIDDirectoryRoles"] = $roles | Select-Object -ExpandProperty AdditionalProperties
    } catch {
        $evidence["UserEntraIDDirectoryRoles"] = "Could not query — connect via Connect-MgGraph -Scopes 'RoleManagement.Read.Directory' first."
    }
}

$evidence | ConvertTo-Json -Depth 6 | Out-File "SentinelDataLakeEvidence_$(Get-Date -Format yyyyMMdd_HHmm).json"
Write-Host "Evidence exported. Attach manually: exact KQL job error text, job schedule/timing, and federated connector configuration screenshot if relevant." -ForegroundColor Yellow
```

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| Confirm data lake onboarding | `Get-AzRoleAssignment -ResourceGroupName <rg> \| Where-Object { $_.DisplayName -like "msg-resources-*" }` |
| Check managed identity's workspace write role | `Get-AzRoleAssignment -Scope <workspace-resource-id> -ObjectId <identity-object-id>` |
| Grant Log Analytics Contributor to managed identity | `New-AzRoleAssignment -ObjectId <identity-object-id> -RoleDefinitionName "Log Analytics Contributor" -Scope <workspace-resource-id>` |
| Check a user's Entra ID directory roles | `Get-MgUserMemberOf -UserId <user@domain.com>` |
| Assign an Entra ID directory role | `New-MgDirectoryRoleMemberByRef -DirectoryRoleId <role-id> -BodyParameter @{"@odata.id"="https://graph.microsoft.com/v1.0/directoryObjects/<user-object-id>"}` |
| Check Sentinel Azure RBAC (SIEM side, separate system) | `Get-AzRoleAssignment -Scope <workspace-resource-id> -SignInName <user>` |
| Confirm workspace SKU/CMK-relevant properties | `Get-AzOperationalInsightsWorkspace -ResourceGroupName <rg> -Name <ws> \| Select Name,Sku` |
| KQL: build a 12-year lookback job query pattern | `let delay = 15m; let endTime = now() - delay; TableName \| where TimeGenerated < endTime` |
| KQL: query a federated table | `<tableName>_<connectorInstanceName> \| take 100` |
| KQL: reference a specific source workspace | `workspace("MyWorkspace").AuditLogs` |
| Decide KQL job vs. Summary rule vs. Search job | See comparison table in [How It Works](#how-it-works) |
| Offboard the data lake | [Submit a support request](https://learn.microsoft.com/en-us/defender-xdr/contact-defender-support) — no CLI/portal self-service |

---
## 🎓 Learning Pointers
- The data lake's Entra-ID-directory-role access model, layered on top of Sentinel SIEM's existing Azure RBAC, is a genuinely different flavor of the "looks like one gate, is actually several" pattern this repo keeps encountering (`Notebooks-A.md`'s dual-Azure-resource split, `LifecycleWorkflows-A.md`'s `IsEnabled`/`IsSchedulingEnabled` split, `UEBA-A.md`'s three-toggle model) — here it's two *entirely different RBAC systems* on the *same* resource, which is the easiest variant to miss in a routine access review. See [Roles and permissions for the Microsoft Sentinel data lake](https://learn.microsoft.com/en-us/azure/sentinel/roles#roles-and-permissions-for-the-microsoft-sentinel-data-lake).
- Treat the subscription/resource-group/region choice at onboarding as a one-way door with the same weight given elsewhere in this repo to purge-protected Key Vaults and immutable Backup vaults — get explicit client sign-off before executing Remediation Playbook 1 step 2. See [Onboarding to Microsoft Sentinel data lake](https://learn.microsoft.com/en-us/azure/sentinel/datalake/sentinel-lake-onboarding).
- KQL jobs, Summary rules, and Search jobs solve genuinely different problems despite surface-level similarity — internalizing the decision table prevents a large share of "why doesn't this work" tickets before they're even filed. See [KQL jobs, summary rules, and search jobs](https://learn.microsoft.com/en-us/azure/sentinel/datalake/kql-jobs-summary-rules-search-jobs).
- Data federation's public-network-accessibility requirement is a real, current limitation worth surfacing proactively to security-conscious clients evaluating Databricks/Fabric integration, not discovered after a failed connector setup — see [Data federation overview](https://learn.microsoft.com/en-us/azure/sentinel/datalake/data-federation-overview) and its Limitations section.
- Onboarding switches existing SIEM billing meters (search jobs, auxiliary logs, long-term retention/Archive) to data-lake-based billing automatically — flag this explicitly in any onboarding conversation rather than letting a client discover it on their next invoice. See [Plan costs and understand Microsoft Sentinel pricing and billing](https://learn.microsoft.com/en-us/azure/sentinel/billing).
- Community/reference reading: the [Microsoft Sentinel data lake FAQ](https://techcommunity.microsoft.com/blog/microsoftsentinelblog/microsoft-sentinel-data-lake-faq/4457728) on Tech Community for scenario-driven Q&A beyond the structured Learn docs, and [Troubleshoot KQL queries for the data lake](https://learn.microsoft.com/en-us/azure/sentinel/datalake/kql-troubleshoot) for the full, actively maintained error-message reference this runbook's Fix 4 table is drawn from.
