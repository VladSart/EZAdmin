# Microsoft Sentinel — Agent Instructions

## What's in this folder
Runbooks and scripts for Microsoft Sentinel data connector troubleshooting (the layer where most MSP Sentinel incidents actually live — "connector is connected but I see no data"), analytics rule / incident tuning (detection logic, alert grouping, entity mapping, automation rules, false-positive tuning), Logic Apps playbook / SOAR execution troubleshooting (automation rule → playbook handoff, connector authentication, throttling), UEBA (User & Entity Behavior Analytics — behavioral baselining, anomaly detection, and entity enrichment), and Hunting (the analyst-driven manual workflow — hunting query library, Bookmarks, the Hunts (Preview) end-to-end wrapper, and KQL jobs as the retired-livestream replacement). Covers the three connector families: agent-based (AMA + Data Collection Rules), API/service-to-service (Office 365, Entra ID, Defender XDR), and Azure-resource diagnostic-settings-based connectors; the five analytics rule kinds (Scheduled, NRT, Microsoft security, Fusion, Anomaly) and the alert→incident→automation pipeline above them; the automation rule → Logic App playbook handoff, its permission model, and the three independent throttling layers (Logic App resource, connector, destination system); UEBA's three independently-toggled capabilities (base behavioral baselining, Detect Anomalies, and the newer UEBA behaviors layer), its data sources, and the `BehaviorAnalytics`/`IdentityInfo`/`UserPeerAnalytics`/`Anomalies` table model that feeds the Anomaly rule kind above; and Hunting's Azure-portal-only bookmark creation constraint, the Hunts-clones-not-references model, and the KQL-jobs-are-persistence-not-alerting distinction that trips up livestream migrations. Does not yet cover Jupyter/MSTICPy notebook-based hunting or the broader Sentinel data lake architecture beyond KQL jobs (federated tables, data lake onboarding mechanics) — future topics.

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

## Response format reminder

Always answer in 3 layers:
1. **Immediate** — what to check right now (KQL query or PowerShell command)
2. **Root cause** — which of the three connector families is involved (data-connector questions), which pipeline layer (detection logic / entity mapping / incident grouping / automation) is involved (analytics-rule questions), or which layer of the automation-rule→workflow-run→connector→destination chain is involved (playbook questions), and why that matters
3. **Prevention** — DCR association verification, quota alerting, consent-renewal checklist for MSP transitions, classification-discipline/tuning-insight review for analytics rules, or Logic Apps diagnostics wiring + managed-identity migration for playbooks
