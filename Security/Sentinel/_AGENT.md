# Microsoft Sentinel — Agent Instructions

## What's in this folder
Runbooks and scripts for Microsoft Sentinel data connector troubleshooting (the layer where most MSP Sentinel incidents actually live — "connector is connected but I see no data"), analytics rule / incident tuning (detection logic, alert grouping, entity mapping, automation rules, false-positive tuning), Logic Apps playbook / SOAR execution troubleshooting (automation rule → playbook handoff, connector authentication, throttling), UEBA (User & Entity Behavior Analytics — behavioral baselining, anomaly detection, and entity enrichment), Hunting (the analyst-driven manual workflow — hunting query library, Bookmarks, the Hunts (Preview) end-to-end wrapper, and KQL jobs as the retired-livestream replacement), and Notebooks (Jupyter/MSTICPy code-first hunting and investigation, executed on a separate Azure Machine Learning workspace launched from Sentinel). Covers the three connector families: agent-based (AMA + Data Collection Rules), API/service-to-service (Office 365, Entra ID, Defender XDR), and Azure-resource diagnostic-settings-based connectors; the five analytics rule kinds (Scheduled, NRT, Microsoft security, Fusion, Anomaly) and the alert→incident→automation pipeline above them; the automation rule → Logic App playbook handoff, its permission model, and the three independent throttling layers (Logic App resource, connector, destination system); UEBA's three independently-toggled capabilities (base behavioral baselining, Detect Anomalies, and the newer UEBA behaviors layer), its data sources, and the `BehaviorAnalytics`/`IdentityInfo`/`UserPeerAnalytics`/`Anomalies` table model that feeds the Anomaly rule kind above; Hunting's Azure-portal-only bookmark creation constraint, the Hunts-clones-not-references model, and the KQL-jobs-are-persistence-not-alerting distinction that trips up livestream migrations; Notebooks' dual-RBAC model (independent Sentinel-workspace and AML-workspace grants), the AML storage-account network posture that gates direct in-portal launch, and the MSTICPy config/auth layer (`msticpyconfig.yaml`, query providers, external TI/GeoIP enrichment) underneath the notebook runtime itself; and the Sentinel **data lake** architecture — the cold, up-to-12-year storage tier, its own INDEPENDENT Entra-ID-directory-role access model (separate from Sentinel SIEM's Azure RBAC), one-time tenant-wide onboarding (DL102/DL103 errors, CMK incompatibility, permanent subscription/RG/region lock), the KQL-job/Summary-rule/Search-job tool-selection decision, and data federation to Azure Databricks/ADLS Gen 2/Microsoft Fabric. Also covers **Microsoft Sentinel graph** — a name spanning two unrelated products: zero-configuration built-in embedded graphs (Incident graph/Blast Radius, Hunting graph, Purview data risk graphs) that auto-provision alongside data lake onboarding, and Custom graphs (preview), a code-first VS Code/PySpark/GQL authoring workflow gated by three independent permission systems (XDR unified RBAC to model, an Entra ID directory role to persist, XDR unified RBAC to query) plus two silent architectural constraints (per-table data access, Sentinel scoping).

## Before responding, also check
- `EntraID/Graph/` — Entra ID sign-in/audit log connectors are actually diagnostic settings, not a distinct Sentinel object; cross-reference if the question is about Entra log gaps specifically
- `Security/Defender/` — Defender XDR (MDE/MDA/MDI) alert ingestion into Sentinel depends on those products' own health first — check sensor/connector health there before assuming a Sentinel-side fault; also relevant if a tenant is onboarded to the Defender portal, since Defender XDR's correlation engine (not Sentinel's own grouping settings) then owns incident creation
- `M365/Exchange/` — Office 365 connector issues often trace back to Unified Audit Log configuration, which is an Exchange Online/compliance setting, not Sentinel-side
- `Azure/` — Arc-onboarded on-prem/multi-cloud servers depend on Arc agent health as a prerequisite layer beneath AMA; if no Azure folder entry exists yet for Arc, treat Arc connectivity as in-scope here until a dedicated Arc runbook exists

## Folder contents

| File | What it covers |
|------|---------------|
| `_AGENT.md` | This file — routing and orientation |
| `DataConnectors-B.md` | Hotfix runbook — connector shows "Connected" but no data, workspace-wide ingestion gaps, AMA/DCR failures, Office 365/API connector auth issues |
| `DataConnectors-A.md` | Deep dive — full architecture of the three connector families, DCR/DCRA dependency chain, MSP multi-tenant/Lighthouse considerations, bulk-repair playbooks |
| `AnalyticsRules-B.md` | Hotfix runbook — AUTO DISABLED rules, rules that never fire, alert/incident flood, false-positive tuning, automation rules auto-closing incidents |
| `AnalyticsRules-A.md` | Deep dive — full alert→incident→automation pipeline architecture, rule-kind comparison (Scheduled/NRT/Fusion/Anomaly/MS security), portal-mode (Azure vs Defender-onboarded) divergence, tuning/migration playbooks |
| `LogicAppsPlaybooks-B.md` | Hotfix runbook — automation rule fires but playbook doesn't, playbook triggered but nothing happened, connector auth broke, 429 throttling |
| `LogicAppsPlaybooks-A.md` | Deep dive — full automation-rule-to-workflow-run architecture, permission/trigger-type model, 3-layer throttling stack, MSP bulk-repair and managed-identity migration playbooks |
| `UEBA-B.md` | Hotfix runbook — UEBA/IdentityInfo tables empty, data-flow stall, Detect Anomalies toggle confusion, on-prem AD sync gaps, BlastRadius/Manager data-hygiene, behaviors-layer tables missing, permission errors enabling/disabling UEBA |
| `UEBA-A.md` | Deep dive — the three-independent-toggle architecture (base UEBA, Detect Anomalies, behaviors layer), data source table, entity enrichment/scoring model (InvestigationPriority vs. AnomalyScore), peer-group TF-IDF calculation, relationship to Anomaly-kind analytics rules and Fusion |
| `Scripts/Get-SentinelConnectorHealth.ps1` | Audits workspace ingestion cap, per-table ingestion gaps, DCR/DCRA associations, and AMA extension state for supplied resources |
| `Scripts/Get-SentinelAnalyticsRuleAudit.ps1` | Audits rule enabled/AUTO-DISABLED state, never-fired rules, entity mapping gaps, false-positive rate, alerts/incident ratio, and automation rules with no expiration on closing actions |
| `Scripts/Get-SentinelPlaybookHealth.ps1` | Audits Sentinel's role assignment on each playbook, Logic App enabled state, and API Connection status; optionally correlates SentinelHealth automation events |
| `Scripts/Get-SentinelUEBAAudit.ps1` | Audits UEBA core table health (data flow/staleness), resource-lock blockers, identity-sync coverage, and BlastRadius/Manager-attribute data-hygiene gaps for a workspace |
| `Hunting-B.md` | Hotfix runbook — bookmark creation missing (wrong portal), livestream-retired confusion, custom query not visible to others, bookmark propagation delay, 1,000-bookmark UI cap, wrong query source promoted to a rule, KQL job permission/creation failures, N/A query results, Hunts RBAC errors |
| `Hunting-A.md` | Deep dive — the three-layer hunting architecture (Queries library, Bookmarks, Hunts (Preview) wrapper), the Azure-portal-only bookmark creation constraint against the March 2027 Defender-portal retirement, the Hunt-queries-are-clones-not-references model, MITRE ATT&CK-driven query discovery, and KQL jobs as the livestream replacement (data lake tier vs. analytics tier, managed identity permission prerequisite, per-tenant job limits) |
| `Scripts/Get-SentinelHuntingAudit.ps1` | Audits HuntingBookmark table activity/soft-delete ratio, Hunts (Preview) RBAC readiness, and the data lake managed identity's KQL-job permission prerequisite for a workspace |
| `Notebooks-B.md` | Hotfix runbook — Sentinel-role-vs-AML-role confusion, no AML workspace exists, private-endpoint/restricted-storage launch blocker, MSTICPy config warnings/init failures, TI/GeoIP enrichment returns null, kernel-switch package install breakage, kernel-restart state loss, wrong query provider/workspace active |
| `Notebooks-A.md` | Deep dive — the Sentinel-launcher-vs-AML-workspace architecture split and its two independent RBAC systems, MSTICPy component autoload order (TILookup→GeoIP→AzureData→AzureSentinelAPI→Notebooklets→Pivot), msticpyconfig.yaml discovery/MSTICPYCONFIG env var, compute-instance-is-personal-per-user model, greenfield onboarding and network-restricted-workaround playbooks |
| `Scripts/Get-SentinelNotebookReadinessAudit.ps1` | Audits Sentinel-workspace RBAC, AML-workspace RBAC (as an independent grant), AML default storage account network posture (PublicNetworkAccess/firewall — the direct-launch blocker), and compute instance presence for a given AML workspace/user |
| `DataLake-B.md` | Hotfix runbook — tenant not onboarded/DL102/DL103, KQL job can't create a new custom table, Sentinel Contributor but no Entra ID role blocking job creation, KQL job error-message lookup table, auxiliary table missing from Advanced Hunting, offboarding request, CMK incompatibility |
| `DataLake-A.md` | Deep dive — the dual Azure-RBAC/Entra-ID-directory-role access model, analytics-vs-data-lake-tier architecture, one-time onboarding permanence (subscription/RG/region lock), the KQL-job/Summary-rule/Search-job decision table, data federation (Databricks/ADLS Gen 2/Fabric) architecture and one-directional read-only model, greenfield onboarding and federation-setup playbooks |
| `Scripts/Get-SentinelDataLakeReadinessAudit.ps1` | Audits data lake onboarding state (managed identity presence), the managed identity's Log Analytics Contributor grant on a target workspace, and a given user's Sentinel Azure RBAC role side-by-side with their Entra ID directory role — surfacing the dual-system access gap directly |
| `SentinelGraph-B.md` | Hotfix runbook — disambiguating built-in vs. custom graph tickets, missing Entra ID role for persisting, silent data-access gaps, Sentinel-scoped-user block, on-demand graph expiry, rename-vs-overwrite confusion, Spark cold start, GQL query/schema mismatch |
| `SentinelGraph-A.md` | Deep dive — the two-products-one-name architecture (built-in embedded graphs vs. Custom graphs preview), the three-independent-permission-system model for custom graphs, the ephemeral-vs-materialized graph lifecycle, and the Edit-vs-Create rename/overwrite distinction |
| `Scripts/Get-SentinelGraphReadinessAudit.ps1` | Audits data lake onboarding (the shared foundation both graph types depend on) and a given user's Entra ID directory role eligibility to persist custom graphs |

## Common entry points

- "Sentinel connector says Connected but I don't see any logs" → `DataConnectors-B.md` Triage + Fix 1
- "All my Sentinel data stopped at the same time" → `DataConnectors-B.md` Fix 2 (workspace quota) before touching individual connectors
- "VM/Arc server missing from Heartbeat table" → `DataConnectors-B.md` Fix 3 (AMA/Arc agent health)
- "Office 365 connector connected but OfficeActivity is empty" → `DataConnectors-B.md` Fix 4 (Unified Audit Log)
- "Connector shows a health warning icon" → `DataConnectors-B.md` Fix 5 (permission/role revoked)
- "Need to bulk-fix missing DCR associations across a fleet" → `DataConnectors-A.md` Playbook 1
- "Admin who set up a connector left the org, now it's broken" → `DataConnectors-A.md` Playbook 3
- "A rule shows AUTO DISABLED" → `AnalyticsRules-B.md` Triage + Fix 1
- "Rule is enabled but never fires / seems broken" → `AnalyticsRules-B.md` Fix 2
- "Too many incidents / duplicate incidents from the same rule" → `AnalyticsRules-B.md` Fix 3
- "Rule is noisy / high false-positive rate" → `AnalyticsRules-B.md` Fix 4 (automation rule vs. query/watchlist exception)
- "Incidents keep reopening, or grouping settings seem ignored" → `AnalyticsRules-B.md` Fix 5 (check Defender-portal onboarding first)
- "Incidents are closing themselves before an analyst sees them" → `AnalyticsRules-B.md` Fix 6 (stale automation rule exception)
- "MSSP cross-tenant rule broke after an analyst left" → `AnalyticsRules-A.md` Playbook 4
- "Migrating classic alert-automation playbooks before March 2026 deprecation" → `AnalyticsRules-A.md` Playbook 2
- "Automation rule ran but the playbook never triggered" → `LogicAppsPlaybooks-B.md` Triage + Fix 2
- "Playbook triggered successfully but nothing seems to have happened" → `LogicAppsPlaybooks-B.md` Fix 3/4 (need Logic Apps diagnostics wired up)
- "Playbook action failing with 429 / Too Many Requests" → `LogicAppsPlaybooks-B.md` Fix 5
- "Playbook broke after an analyst left / connector shows auth error" → `LogicAppsPlaybooks-B.md` Fix 6
- "Playbook doesn't appear in the automation rule's picker at all" → `LogicAppsPlaybooks-A.md` Validation Step 3 (trigger-type mismatch)
- "Need to bulk-fix playbook permissions across an MSP fleet" → `LogicAppsPlaybooks-A.md` Playbook 1
- "Migrating a playbook off named-user auth onto managed identity" → `LogicAppsPlaybooks-A.md` Playbook 2
- "UEBA/BehaviorAnalytics table is empty" → `UEBA-B.md` Triage + Fix 1
- "I turned on UEBA but there are no anomalies" → `UEBA-B.md` Fix 3 (Detect Anomalies is a separate toggle)
- "On-prem AD users missing from IdentityInfo" → `UEBA-B.md` Fix 4 (Defender for Identity sensor prerequisite)
- "BlastRadius is empty/null for most users" → `UEBA-B.md` Fix 5 (Manager attribute in Entra ID)
- "SentinelBehaviorInfo/SentinelBehaviorEntities tables don't exist" → `UEBA-B.md` Fix 6 (behaviors layer is a third, separate toggle)
- "Why did the Anomaly-kind rule / Fusion never catch this" → `UEBA-A.md` How It Works (confirm UEBA + Detect Anomalies are healthy before tuning the rule)
- "Add bookmark button is missing/greyed out" → `Hunting-B.md` Fix 1 (Defender portal — bookmark creation is Azure-portal-only)
- "Where did Livestream go" → `Hunting-B.md` Fix 2 (fully retired platform-wide, not a bug)
- "Colleague can't see the hunting query I created" → `Hunting-B.md` Fix 3 (saved private, not shared)
- "Bookmark just created isn't showing in the Bookmarks tab" → `Hunting-B.md` Fix 4 (propagation delay)
- "Promoted a hunting query to an analytics rule but the KQL is wrong" → `Hunting-B.md` Fix 6 (Hunt clone vs. global query confusion)
- "KQL job fails to create / destination table stays empty" → `Hunting-B.md` Fix 7 (data lake managed identity permission)
- "Migrating a client off livestream" → `Hunting-A.md` Remediation Playbook 2 (one livestream maps to job + rule + playbook, not a single swap)
- "User has Sentinel Contributor but 'Launch notebook' still fails" → `Notebooks-B.md` Fix 1 (AML workspace RBAC is a separate, independent grant)
- "No Azure Machine Learning workspace exists yet" → `Notebooks-B.md` Fix 2 / `Notebooks-A.md` Remediation Playbook 1
- "Launch notebook does nothing / blank page, no error" → `Notebooks-B.md` Fix 3 (AML storage account private endpoint/restricted network)
- "MSTICPy prints config warnings on first run — is this broken?" → `Notebooks-B.md` Fix 4 (expected, not an error)
- "VirusTotal/GeoIP lookups return blank but Sentinel queries work fine" → `Notebooks-B.md` Fix 5 (separate enrichment-provider config)
- "Notebook worked, now throws NameError after I restarted the kernel" → `Notebooks-B.md` Fix 7 (state including auth is wiped on restart)
- "Onboarding a new analyst to Sentinel notebooks" → `Notebooks-A.md` Remediation Playbook 1
- "User has Sentinel Contributor but can't create/schedule a KQL job" → `DataLake-B.md` Fix 3 (Entra ID directory role is a separate system from Sentinel Azure RBAC)
- "Data lake onboarding failed with DL102 or DL103" → `DataLake-B.md` Fix 1
- "KQL job can't create a new custom table" → `DataLake-B.md` Fix 2 (managed identity needs a manual Log Analytics Contributor grant)
- "Auxiliary log table disappeared from Advanced Hunting" → `DataLake-B.md` Fix 5 (expected — moved to Data lake exploration, not lost)
- "Should this be a KQL job, Summary rule, or Search job?" → `DataLake-A.md` How It Works comparison table
- "Federated Databricks/ADLS/Fabric connection won't set up" → `DataLake-A.md` Remediation Playbook 3 (check public network accessibility first)
- "Need to fully offboard the data lake" → `DataLake-B.md` Fix 6 / `DataLake-A.md` Remediation Playbook 4 (support-request only, no self-service)
- "Is this ticket about Blast Radius/Hunting graph, or about a custom graph in VS Code?" → `SentinelGraph-B.md` Triage Step 1 — these are two unrelated products, disambiguate first
- "Custom graph builds fine in notebook but 'Persist'/schedule fails" → `SentinelGraph-B.md` Fix 2 (Entra ID role is a separate permission system from the modeling role)
- "Custom graph is missing expected nodes/edges, no error shown" → `SentinelGraph-B.md` Fix 3 (per-table access fails silently)
- "User can't create a custom graph despite having roles" → `SentinelGraph-B.md` Fix 4 (Sentinel-scoped users are hard-blocked)
- "A materialized custom graph disappeared after about a month" → `SentinelGraph-B.md` Fix 5 (On-demand 30-day auto-expiry)

## Key diagnostic commands

```kusto
// Ingestion volume trend, catches silent degradation
union withsource=TableName * | where TimeGenerated > ago(24h) | summarize count() by TableName

// Last-seen timestamp per table
summarize max(TimeGenerated) by TableName
```

```powershell
# Workspace quota check
(Get-AzOperationalInsightsWorkspace -ResourceGroupName <rg> -Name <ws>).WorkspaceCapping

# DCR association check for a resource
Get-AzDataCollectionRuleAssociation -TargetResourceId <resource-id>
```

```kusto
// UEBA core table health in one query
union isfuzzy=true
  (BehaviorAnalytics | summarize Table="BehaviorAnalytics", Count=count(), Last=max(TimeGenerated)),
  (IdentityInfo | summarize Table="IdentityInfo", Count=count(), Last=max(TimeGenerated)),
  (Anomalies | summarize Table="Anomalies", Count=count(), Last=max(TimeGenerated))
```

```kusto
// Hunting bookmark activity + soft-delete ratio
HuntingBookmark
| where TimeGenerated > ago(30d)
| summarize arg_max(TimeGenerated, *) by BookmarkId
| summarize Total=count(), Active=countif(SoftDelete==false), Deleted=countif(SoftDelete==true)
```

```powershell
# Data lake managed identity KQL-job permission check
Get-AzRoleAssignment -ResourceGroupName <rg> | Where-Object { $_.DisplayName -like "msg-resources-*" }
```

```powershell
# AML workspace RBAC check — independent grant from Sentinel workspace RBAC, check both
Get-AzRoleAssignment -Scope <AML-workspace-resource-id> -SignInName <user@domain.com>

# AML default storage account network posture — gates direct "Launch notebook" from Sentinel
Get-AzStorageAccount -ResourceGroupName <rg> -Name <storage-account> | Select-Object PublicNetworkAccess, NetworkRuleSet
```

```powershell
# Confirm data lake onboarding (managed identity presence)
Get-AzADServicePrincipal -DisplayNameBeginsWith "msg-resources-"

# Check a user's Entra ID directory role — INDEPENDENT of their Sentinel Azure RBAC role above
Get-MgUserMemberOf -UserId <user@domain.com> | Where-Object { $_.AdditionalProperties.displayName -match "Security Operator|Security Administrator|Global Administrator" }
```

```powershell
# Same Entra ID role check, framed specifically as "eligible to persist a custom Sentinel graph"
# (see SentinelGraph-A.md permission model — this is only ONE of three independent gates;
# XDR unified RBAC for modeling/querying has no PowerShell/Graph surface as of this writing)
Get-MgUserMemberOf -UserId <user@domain.com> -All |
    Where-Object { $_.AdditionalProperties.displayName -in @("Security Operator","Security Administrator","Global Administrator") }
```

## Key dependency chain

```
Log Analytics Workspace (data plane)
    ├── Agent-based: AMA extension → Data Collection Rule → Data Collection Rule Association → workspace table
    ├── API/service: source service → first-time consent → Microsoft-managed pipeline → workspace table
    └── Diagnostic-settings: Azure resource → diagnostic setting → workspace table
            │
            ▼
    Microsoft Sentinel (reads from workspace tables — has no ingestion pipeline of its own)
```

**Playbook/SOAR execution chain** (separate from the ingestion chain above — starts only once an incident/alert already exists):
```
Analytics rule / manual trigger produces incident or alert
    └── Automation rule: conditions evaluated, actions run in order
            └── "Run playbook" action → trigger-type match (Incident vs Alert) required
                    └── Sentinel's service principal must have a role on the specific Logic App
                            └── Logic App resource enabled, not locked/read-only, no blocking IP restriction
                                    └── Workflow run starts (now standard Logic Apps execution — SentinelHealth
                                        has no further visibility unless Logic Apps diagnostics are wired to
                                        the same workspace)
                                            └── Each action authenticates via its own API Connection
                                                    └── Subject to 3 independent throttling layers:
                                                        Logic App resource limit → connector limit → destination limit
```

**UEBA chain** (three independently-toggled branches, not one switch — see `UEBA-A.md`):
```
Directory sync (Entra ID and/or on-prem AD via MDI) + data sources connected
    └── Toggle 1: base UEBA enabled → BehaviorAnalytics / IdentityInfo / UserPeerAnalytics populate
            └── Toggle 2 (separate): Detect Anomalies enabled → Anomalies table populates
                    └── feeds: Anomaly-kind analytics rules, Fusion correlation
    └── Toggle 3 (separate, own enablement flow): UEBA behaviors layer → SentinelBehaviorInfo /
        SentinelBehaviorEntities populate
```

**Hunting chain** (three layers; bookmark creation is portal-gated — see `Hunting-A.md`):
```
Hunting query (Content Hub or custom, saved SHARED to be tenant-visible) run against ingested data
    └── Results reviewed in Logs pane
            ├── AZURE PORTAL ONLY: Add bookmark → HuntingBookmark table (soft-delete, 1,000-row UI cap)
            │       └── entity-mapped → investigation graph + UEBA entity page; → incident
            └── "Create analytics rule" → prepopulated KQL (source copy matters: global vs. Hunt clone)

Hunts (Preview) — optional wrapper, RBAC: Sentinel Contributor / Microsoft.SecurityInsights/hunts
    └── Queries added are CLONED (no two-way sync with the global library)

KQL jobs — retired-livestream replacement, separate Sentinel data lake architecture
    └── Data lake onboarding + managed identity (msg-resources-<guid>) needs Log Analytics
        Contributor on the destination workspace
            └── persists data on a schedule; does NOT alert — pair with an analytics rule/playbook
```

**Notebooks chain** (two independent RBAC systems across two Azure resources — see `Notebooks-A.md`):
```
Sentinel workspace RBAC (Reader/Responder/Contributor)
    └── gates: see/save/launch notebook templates from the Sentinel "Notebooks" blade
            │
            ▼  (launches into a SEPARATE resource — no RBAC inheritance between the two)
Azure Machine Learning workspace RBAC (Contributor to run; RG Owner/Contributor to create)
    └── AML default storage account PublicNetworkAccess/firewall
            └── if restricted: direct launch fails — manual template copy/upload into AML Studio required
                    └── Compute instance (personal per user) → must exist and be running
                            └── Kernel (Python 3.8/3.6) → msticpyconfig.yaml (auto-discovered in AML
                                user folder, or via MSTICPYCONFIG env var elsewhere)
                                    ├── Query provider auth → required for ANY KQL query from the notebook
                                    └── External TI/GeoIP provider keys → enrichment only, not core queries
```

**Data lake chain** (dual RBAC systems on the SAME resource — see `DataLake-A.md`):
```
Onboarding (one-time, tenant-wide, Defender portal only — subscription/RG/region PERMANENT)
    └── creates managed identity msg-resources-<guid>
            ├── auto-granted: Azure Reader over onboarded subscriptions
            └── NOT auto-granted: Log Analytics Contributor (manual, per-workspace — required
                only for KQL jobs that create NEW custom tables)
                    │
    ┌───────────────┴───────────────────────────────────────────┐
    │ TWO INDEPENDENT ACCESS SYSTEMS on the same tenant/resource  │
    ├── Azure RBAC (Sentinel SIEM — unchanged)                    │
    │       Sentinel Reader/Responder/Contributor                 │
    │       → incidents/rules/workbooks/playbooks + read-only     │
    │         interactive data lake queries on covered workspaces │
    └── Entra ID directory roles (Data lake — separate system)     │
            Read: Global Reader/Security Reader/+ the 3 below     │
            Write: Security Operator/Administrator/Global Admin   │
            → REQUIRED for ANY KQL job create/schedule/manage —   │
              no Azure RBAC role substitutes for this             │
    └───────────────────────────────────────────────────────────┘
            └── Analytics tier (hot, 90d-2yr) ←mirrored→ Data lake tier (cold, up to 12yr,
                ~15min latency / 90-120min for new tables)
                    ├── KQL jobs (up to 12yr, joins, federated tables) vs. Summary rules
                    │   (frequent, non-lake tiers OK) vs. Search jobs (single table, Archive OK)
                    └── Federated tables (Databricks/ADLS Gen2/Fabric) — READ-ONLY,
                        one-directional, external source must be PUBLICLY network-accessible
```

**Sentinel graph chain** (two unrelated products sharing one foundation — see `SentinelGraph-A.md`):
```
Sentinel data lake onboarded (shared prerequisite for BOTH branches below)
    ├── Built-in embedded graphs (zero configuration, auto-provisioned)
    │       └── Incident graph + Blast Radius / Hunting graph (Defender XDR)
    │       └── Data risk graphs (Purview Insider Risk Management / Data Security Investigations)
    └── Custom graphs (preview) — separate Fabric-powered authoring workflow
            ├── VS Code + Sentinel extension + Jupyter -> Spark pool (~5min cold start)
            ├── PySpark DataFrames -> GraphSpecBuilder (nodes/edges) -> Graph.build()
            ├── THREE independent permission gates (none implies another):
            │       Model (XDR RBAC "data (manage)") / Persist (Entra ID role) /
            │       Query (XDR RBAC "security data basics (read)")
            ├── Silent constraints: per-table read access; user must be UNSCOPED in Sentinel
            └── Lifecycle: Ephemeral (session-only) vs. Materialized (graph job)
                    └── On demand (30-day auto-expiry) vs. Recurring (scheduled refresh)
```

## Response format reminder

Always answer in 3 layers:
1. **Immediate** — what to check right now (KQL query or PowerShell command)
2. **Root cause** — which of the three connector families is involved (data-connector questions), which pipeline layer (detection logic / entity mapping / incident grouping / automation) is involved (analytics-rule questions), or which layer of the automation-rule→workflow-run→connector→destination chain is involved (playbook questions), and why that matters
3. **Prevention** — DCR association verification, quota alerting, consent-renewal checklist for MSP transitions, classification-discipline/tuning-insight review for analytics rules, or Logic Apps diagnostics wiring + managed-identity migration for playbooks
