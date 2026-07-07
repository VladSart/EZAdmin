# Microsoft Sentinel — Agent Instructions

## What's in this folder
Runbooks and scripts for Microsoft Sentinel data connector troubleshooting (the layer where most MSP Sentinel incidents actually live — "connector is connected but I see no data") and analytics rule / incident tuning (detection logic, alert grouping, entity mapping, automation rules, false-positive tuning). Covers the three connector families: agent-based (AMA + Data Collection Rules), API/service-to-service (Office 365, Entra ID, Defender XDR), and Azure-resource diagnostic-settings-based connectors — plus the five analytics rule kinds (Scheduled, NRT, Microsoft security, Fusion, Anomaly) and the alert→incident→automation pipeline above them. Does not yet cover hunting/KQL authoring or Logic Apps playbook internals — those are future topics.

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
| `Scripts/Get-SentinelConnectorHealth.ps1` | Audits workspace ingestion cap, per-table ingestion gaps, DCR/DCRA associations, and AMA extension state for supplied resources |
| `Scripts/Get-SentinelAnalyticsRuleAudit.ps1` | Audits rule enabled/AUTO-DISABLED state, never-fired rules, entity mapping gaps, false-positive rate, alerts/incident ratio, and automation rules with no expiration on closing actions |

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

## Response format reminder

Always answer in 3 layers:
1. **Immediate** — what to check right now (KQL query or PowerShell command)
2. **Root cause** — which of the three connector families is involved (data-connector questions) or which pipeline layer (detection logic / entity mapping / incident grouping / automation) is involved (analytics-rule questions), and why that matters
3. **Prevention** — DCR association verification, quota alerting, consent-renewal checklist for MSP transitions, or classification-discipline/tuning-insight review for analytics rules
