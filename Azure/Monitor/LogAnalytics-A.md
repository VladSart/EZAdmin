# Azure Monitor Agent / Log Analytics — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers the **Azure Monitor Agent (AMA)** telemetry pipeline: agent deployment and identity, **Data Collection Rules (DCRs)**, **Data Collection Endpoints (DCEs)**, and the **Log Analytics workspace** ingestion/table-plan layer underneath it. It applies to Azure VMs, Azure Arc-enabled servers, and VM scale sets.

It explicitly does **not** cover:
- **The retired legacy Log Analytics agent (MMA/OMS/Microsoft Monitoring Agent)** in depth beyond migration guidance — its backend was shut down 2 March 2026 and it is not a supported path going forward. Any client still running it needs migration, not troubleshooting of the old agent itself.
- **Microsoft Sentinel** data connector configuration and analytics rules — those consume data that lands in a Log Analytics workspace via this pipeline, but connector-specific onboarding lives in `Security/Sentinel/DataConnectors-A.md`.
- **Microsoft Defender for Cloud**'s own use of Log Analytics for its legacy MMA-based auto-provisioning — see `Security/Defender/DefenderForCloud-A.md`, which now uses MDE's own sensor for most signal collection rather than this pipeline.
- **Container insights / Managed Prometheus** for AKS — those use a related but architecturally distinct agent (the `ama-logs`/`ama-metrics` containerized agents), not the VM extension model documented here.
- **Azure Key Vault** diagnostic settings, **NSG** flow logs, and other resources that *send data into* a Log Analytics workspace via Diagnostic Settings rather than the AMA/DCR pipeline — those are a separate ingestion path (Diagnostic Settings → workspace directly) and are documented in their own domain folders; this runbook covers only the agent-based collection path.

**Assumption:** the reader is troubleshooting an MSP client's existing Azure Monitor/Log Analytics deployment, not designing one from a blank slate — though the remediation playbooks below include a greenfield onboarding path.

---
## How It Works

<details><summary>Full architecture</summary>

Azure Monitor Agent replaced the legacy Log Analytics agent (Microsoft Monitoring Agent/MMA, also called the OMS agent) as the single unified agent for collecting monitoring data from Windows and Linux machines — Azure, Arc-enabled on-premises/other-cloud, and (for a subset of scenarios) client OS. The legacy agent's Log Analytics backend was retired: uploads were paused for a validation window on 26 January 2026 (12:00 AM–12:00 PM Pacific Time, with any cached telemetry captured during that window permanently lost), and the backend was fully shut down on **2 March 2026**. As of that date, legacy-agent machines cannot upload data at all, under any circumstances — this is not a soft deprecation with a grace period, it is a hard stop.

AMA is a **VM extension** (`AzureMonitorWindowsAgent` / `AzureMonitorLinuxAgent`), not a standalone install. It is fundamentally **configuration-driven from the cloud**: unlike the legacy agent, which pulled its configuration centrally from a connected Log Analytics workspace, AMA has *no* inherent configuration of its own. Every single thing it collects is defined by one or more **Data Collection Rules (DCRs)** explicitly associated with that specific resource. An AMA extension with zero DCR associations is fully "healthy" from an extension-status perspective and collects precisely nothing — this is normal, expected behavior, not a fault condition, and it is the single most common source of "we installed AMA and nothing shows up" tickets.

**Authentication model:** AMA authenticates to the Azure Monitor configuration service (AMCS) using the machine's **managed identity** (system- or user-assigned) via the **Azure Instance Metadata Service (IMDS)**, reachable at the well-known link-local address `169.254.169.254`. No managed identity means AMA can never retrieve its DCR — this is a hard prerequisite, checked before anything else in this runbook's diagnosis flow.

**The DCR is the unit of "what to collect and where to send it."** A DCR contains:
- **Data sources** — performance counters, Windows event log queries (XPath), Linux syslog facilities, IIS logs, custom text logs, or Windows Firewall/extension-specific data sources.
- **Data flows** — each maps one or more data source streams (e.g. `Microsoft-Perf`, `Microsoft-Event`, `Microsoft-Syslog`, or a custom `Custom-*` stream) to one or more destinations.
- **Destinations** — typically one or more Log Analytics workspaces, but DCRs also support Azure Monitor Metrics and, for the ingestion-API scenario, Event Hubs/Storage as destinations for custom data.

A single machine can be associated with **multiple DCRs simultaneously** ("multihoming") — for example, one DCR for general operations telemetry and a second, separately-scoped DCR for security event collection feeding Sentinel. This is fully supported, but if two associated DCRs both collect the same data source (e.g. both define the same performance counter set) without differentiating filters, the result is **duplicate rows and duplicate ingestion billing** — a silent cost problem, not an error the platform will surface.

**Data Collection Endpoints (DCEs)** are a separate, optional resource type. A DCE is only required when the target Log Analytics workspace is configured for **Private Link** (via an Azure Monitor Private Link Scope, AMPLS) — in that scenario, the agent needs a network-reachable, region-matched ingestion endpoint rather than talking to the public AMCS/ingestion endpoints directly. A DCE **must be in the same Azure region as the agent it serves**; a client with agents across multiple regions needs one DCE per region, not one shared DCE. Outside of Private Link scenarios, a DCE is unnecessary overhead and should not be added by default.

**The workspace and table-plan layer:** once data lands in the Log Analytics workspace, each **table** is governed by a **table plan** that determines cost, retention behavior, and available query capability:
- **Analytics Logs** — full KQL capability (joins, cross-table correlation), ~$2.30/GB ingestion (2026 pricing, after a small free monthly allowance), eligible for commitment-tier discounts.
- **Basic Logs** — restricted KQL (no joins/cross-table correlation), ~$0.50/GB ingestion, 30 days of free retention, not eligible for commitment tiers.
- **Auxiliary Logs** — the cheapest tier, minimal indexing, ~$0.05/GB ingestion, 30 days free retention, intended for high-volume/rarely-queried data (e.g. verbose audit trails kept mainly for compliance retrieval, not day-to-day investigation).

Choosing the wrong plan for a data source's actual query pattern is a common, avoidable cost or capability surprise — not a platform bug — and is a design decision that belongs in the onboarding conversation, not discovered after the first invoice.

</details>

---
## Dependency Stack

```
Layer 7 — Query & Alerting
    KQL queries (Log Analytics blade, Workbooks, Sentinel Analytics Rules, Azure Monitor Alerts)
        └── restricted by the table's Table Plan (Basic/Auxiliary can't do joins/cross-table correlation)

Layer 6 — Log Analytics Workspace
    Tables (Analytics / Basic / Auxiliary plan per table) — ingestion + retention + query behavior

Layer 5 — Data Collection Endpoint (DCE) — CONDITIONAL, only if workspace uses Private Link/AMPLS
    Must be same-region as the agent; registered in the AMPLS resource for DNS/private routing

Layer 4 — Data Collection Rule (DCR)
    Data Sources (what) + Data Flows (stream → destination mapping) + optional DCE reference

Layer 3 — Data Collection Rule Association
    Binds ONE specific resource (VM/Arc machine/VMSS) to ONE OR MORE DCRs
    (no association = extension runs with an empty configuration, collects nothing)

Layer 2 — Azure Monitor Agent Extension
    AzureMonitorWindowsAgent / AzureMonitorLinuxAgent VM extension
    "Provisioning succeeded" confirms package install only — NOT agent health or config receipt

Layer 1 — Authentication
    Managed Identity (system- or user-assigned) + Azure Instance Metadata Service (IMDS, 169.254.169.254)
    (no identity or blocked IMDS = agent can never retrieve its DCR — everything above is unreachable)

Layer 0 — Compute Resource
    Azure VM / Azure Arc-enabled server / VM Scale Set
```

Every layer depends on the one below it being fully healthy — a DCR authored perfectly at Layer 4 does nothing if Layer 1's managed identity is missing, and this is the most common misdiagnosis pattern: engineers jump straight to "rewrite the DCR" when the actual break is a missing identity two layers down.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Machine has sent zero data ever; `HealthService` present | Still running the retired legacy agent (backend shut down 2 Mar 2026) | `Get-Service HealthService` |
| AMA extension shows `Succeeded`, but no `Heartbeat` rows | "Succeeded" only confirms package install, not agent health/config receipt | `mcsconfig.latest.xml` presence; extension logs |
| Extension install itself fails or times out | No managed identity, or IMDS blocked by NSG/firewall/host firewall | VM `Identity` property; IMDS token request from the host |
| Heartbeat present, but a specific event/perf/syslog stream is missing | DCR exists but its data flows don't include that stream | `Get-AzDataCollectionRule` → `.DataFlow` / `.DataSources` |
| No DCR association found for the resource at all | Onboarding never completed the association step (common when Policy-based auto-onboarding was skipped/scoped out) | `Get-AzDataCollectionRuleAssociation` |
| Duplicate rows / unexplained ingestion cost spike | Two associated DCRs both collect the same data source without differentiating filters | Compare `DataFlow`/`DataSources` across all associated DCRs |
| Machine behind Private Link/AMPLS never reports, extension looks healthy | Missing or wrong-region DCE, or DCE not registered in the AMPLS resource | `Get-AzDataCollectionEndpoint`; `Get-AzMonitorPrivateLinkScope` |
| Query returns "operator not supported" or join fails on a table that used to work | Table plan was changed to Basic/Auxiliary (deliberately or via a cost-optimization pass) | `Get-AzOperationalInsightsTable` → current plan |
| Ingestion cost jumped sharply with no new data source added | A DCR change (e.g. lowered sampling interval, added verbose logging) or a plan change on a high-volume table | `analyze-usage` workbook / `Usage` table query |
| Arc-enabled server extension install fails specifically (works fine on native Azure VMs) | Arc Connected Machine agent itself unhealthy — AMA depends on Arc, not the reverse | `Azure/Arc/AzureArc-B.md` first |
| AVD session host or Update Manager-managed VM shows no monitoring data | AMA extension never deployed to that resource type by the same automation that deployed the base image/policy | Cross-check Policy assignment scope covering that resource type |
| Data was flowing, then stopped abruptly on/around 26 Jan or 2 Mar 2026 | Legacy agent finally hit the validation-pause or backend-shutdown milestone | `HealthService` presence + last-ingested-data timestamp correlated to those dates |
| Custom log source (text file / custom table) never appears | Custom table/DCR schema mismatch, or the Data Collection Endpoint's ingestion (logs) URL wasn't used for the custom ingestion API call | Confirm DCR immutable ID and DCE logs-ingestion endpoint used in the ingestion call |

---
## Validation Steps

1. **Confirm no legacy agent remnants.**
   ```powershell
   Get-Service HealthService -ErrorAction SilentlyContinue
   ```
   Good: no service found. Bad: service present — this machine is fully dark to Azure Monitor as of 2 Mar 2026 regardless of anything else checked below.

2. **Confirm managed identity and IMDS reachability.**
   ```powershell
   (Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>").Identity
   # On the machine itself:
   Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" -Headers @{Metadata="true"}
   ```
   Good: identity object populated, token request returns a valid JWT. Bad: `$null` identity, or the IMDS call times out/is refused (points at a host firewall or NSG blocking `169.254.169.254`, which should never be blocked — it's a platform-internal, non-routable address).

3. **Confirm extension provisioning AND on-machine config receipt.**
   ```powershell
   Get-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Name AzureMonitorWindowsAgent -Status
   Test-Path "C:\WindowsAzure\Resources\AMADataStore.$env:COMPUTERNAME\mcs\mcsconfig.latest.xml"
   ```
   Good: `Succeeded` AND the config file exists with a recent write time. Bad: `Succeeded` but no config file — extension installed but has never talked to AMCS successfully (usually an identity/IMDS/network issue, loop back to step 2).

4. **Confirm DCR association targets this exact resource.**
   ```powershell
   Get-AzDataCollectionRuleAssociation -TargetResourceId "<vmResourceId>"
   ```
   Good: one or more associations returned. Bad: empty — extension is running with nothing to collect, a config/onboarding gap, not an agent fault.

5. **Confirm the DCR's data flows actually cover the data the client is asking about.**
   ```powershell
   (Get-AzDataCollectionRule -ResourceGroupName "<rg>" -Name "<dcrName>").DataFlow
   ```
   Good: the relevant stream (`Microsoft-Perf`, `Microsoft-Event`, `Microsoft-Syslog`, or a `Custom-*` stream) is present with a destination. Bad: stream absent — this is a DCR authoring gap, resolve by editing the DCR, not by touching the agent.

6. **Confirm end-to-end delivery via Heartbeat and the target table.**
   ```kql
   Heartbeat
   | where Computer == "<computerName>"
   | summarize LastHeartbeat = max(TimeGenerated) by Computer, Category
   ```
   Good: a recent `Category == "Azure Monitor Agent"` row. Bad: no rows — the pipeline is broken somewhere in layers 1–5; work back down the dependency stack rather than guessing.

7. **Confirm the table plan matches the client's actual query needs before closing out an onboarding or cost-review ticket.**
   ```powershell
   Get-AzOperationalInsightsTable -ResourceGroupName "<rg>" -WorkspaceName "<workspace>" -TableName "<tableName>"
   ```
   Good: plan matches usage pattern (Analytics for tables needing joins/correlation, Basic/Auxiliary for high-volume rarely-queried data). Bad: a high-volume table sitting on Analytics plan when nobody has run a cross-table query against it in months — flag as a cost-optimization opportunity, not a fault.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Legacy agent sweep.** Before investigating any specific "no data" ticket, always confirm the machine isn't simply a legacy-agent holdout. This single check resolves a disproportionate share of "monitoring stopped working" tickets raised after 2 Mar 2026 and should be step zero on every ticket touching this pipeline.

**Phase 2 — Identity and network layer.** Confirm managed identity presence and IMDS reachability from the host. This is the most commonly skipped check because engineers assume "the extension installed, so networking must be fine" — but extension *installation* doesn't require IMDS; ongoing *configuration retrieval* does, and the two can diverge (e.g. identity removed after initial install, or an NSG rule added later that inadvertently blocks link-local traffic).

**Phase 3 — Extension and configuration receipt.** Distinguish "extension installed" from "extension has a working configuration" using the on-disk config artifact, not just `ProvisioningState`. This is the single highest-value distinction in this entire runbook — most misdiagnosis time is spent because someone trusted `Succeeded` as proof of health.

**Phase 4 — DCR association and content.** Confirm the resource is associated with the correct DCR(s), and that those DCRs' data flows actually cover the data the client is asking about. Treat "no data source X" and "no data at all" as different diagnostic paths — the former is almost always a DCR authoring gap, the latter is almost always layers 1–3.

**Phase 5 — Network isolation layer (conditional).** Only relevant if the workspace is Private-Link-enabled. Confirm DCE presence, region match, and AMPLS registration. Skipping this phase's applicability check (i.e. assuming every client needs a DCE) is itself a common source of wasted effort — most clients do not use Private Link and this phase should be skipped entirely for them.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fleet migration off the legacy Log Analytics agent</summary>

**When to use:** any client still running `HealthService`-based monitoring anywhere in their estate. This is urgent given the 2 Mar 2026 backend shutdown, not a "schedule it for next quarter" item.

1. Inventory every machine still running the legacy agent:
   ```powershell
   Get-AzVM | ForEach-Object {
       $ext = Get-AzVMExtension -ResourceGroupName $_.ResourceGroupName -VMName $_.Name -ErrorAction SilentlyContinue |
           Where-Object { $_.ExtensionType -eq "MicrosoftMonitoringAgent" }
       if ($ext) { [PSCustomObject]@{ VM = $_.Name; RG = $_.ResourceGroupName; LegacyExtension = $true } }
   }
   ```
2. For each machine, ensure a system- or user-assigned managed identity exists (prerequisite for AMA), then deploy the AMA extension alongside the legacy agent — they can coexist during migration.
3. Associate the fleet-standard DCR(s) covering the same data the legacy agent was collecting (perf counters, Windows/syslog events, any custom logs).
4. Validate via `Heartbeat` that AMA is delivering data equivalent to what the legacy agent was sending, side by side, for at least one full collection interval.
5. Only after validation, remove the legacy `MicrosoftMonitoringAgent` extension.
6. At scale, prefer an Azure Policy initiative (`Configure Windows/Linux machines to run Azure Monitor Agent...`) to auto-deploy AMA, an identity, and DCR associations across the fleet rather than doing this VM-by-VM.

**Rollback:** none needed for the AMA-add step (non-destructive, additive). Do not roll back a legacy-agent removal by reinstalling it — its backend is permanently unavailable; if AMA migration surfaces a real regression, fix forward on AMA rather than reverting.

</details>

<details><summary>Playbook 2 — Greenfield onboarding for a new client environment</summary>

1. Confirm/enable managed identity on every target resource (system-assigned is simplest for a single environment; user-assigned for cross-subscription/cross-tenant consistency in an MSP fleet model).
2. Create one or more fleet-standard DCRs scoped by purpose (e.g. "Ops-Baseline" for perf/event basics, "Security" for the data Sentinel/Defender needs) rather than one DCR per machine — this keeps future data-source changes centrally manageable.
3. Deploy the AMA extension fleet-wide via Azure Policy (`DeployIfNotExists` effect) rather than manual per-VM extension installs, so newly created VMs are automatically onboarded going forward.
4. Associate DCRs to resources — either individually or, at scale, via a Policy-driven DCR association initiative.
5. Assign table plans deliberately at onboarding: default high-volume/low-query-value data sources (verbose diagnostic logs, some security event categories destined only for long-term retention) to Basic or Auxiliary; keep operationally-queried data (the tables feeding dashboards, alerts, and Sentinel correlation) on Analytics.
6. Validate end-to-end with the Validation Steps above on a representative sample before declaring the environment "monitored."

**Rollback:** removing DCR associations or the AMA extension stops future collection without affecting already-ingested data; deleting a DCR itself should only be done after confirming no other resource association depends on it.

</details>

<details><summary>Playbook 3 — Recovering from a Private Link/AMPLS misconfiguration</summary>

1. Confirm the workspace is genuinely Private-Link-enabled — check for an associated AMPLS resource before assuming a DCE is needed at all.
2. Create a DCE in the **same region** as each group of affected agents (one DCE per region, not a single shared DCE across regions).
3. Register each DCE with the AMPLS resource (adds it to the private DNS zone and enables private routing).
4. Update the relevant DCR(s) to reference the DCE (`DataCollectionEndpointId`), then re-associate or confirm existing associations pick up the change.
5. Validate DNS resolution from an affected machine resolves the AMCS/ingestion endpoints to private IPs, not public ones, before declaring the fix complete.

**Rollback:** removing the DCE reference from a DCR reverts affected agents to attempting public endpoint connectivity, which will fail again if the workspace is genuinely Private-Link-only — only do this as a temporary rollback while re-planning, not as a final state.

</details>

<details><summary>Playbook 4 — Fleet-wide cost/table-plan optimization pass</summary>

1. Run the `analyze-usage` workbook (or an equivalent `Usage` table query) per workspace to identify the highest-ingesting tables.
2. For each high-volume table, confirm actual query patterns against it (search/audit history) — tables that are ingested heavily but rarely queried with joins/correlation are Basic/Auxiliary candidates.
3. Change the table plan where appropriate:
   ```powershell
   Update-AzOperationalInsightsTable -ResourceGroupName "<rg>" -WorkspaceName "<workspace>" -TableName "<tableName>" -Plan Basic
   ```
4. Re-validate that any Sentinel analytics rules, alerts, or Workbooks depending on that table still function correctly under the new plan's query restrictions before closing the change out — a plan downgrade can silently break a join-dependent alert rule.

**Rollback:** table plans can be changed back to Analytics at any time; note that a minimum retention commitment may apply before switching back, and switching plans does not retroactively re-index already-ingested data under the new plan's rules.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Azure Monitor Agent / Log Analytics pipeline evidence for a single VM, end to end.
#>
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$VMName
)

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
$evidence = [ordered]@{
    VMName            = $VMName
    ResourceGroup     = $ResourceGroupName
    Region            = $vm.Location
    LegacyAgentFound  = $null
    ManagedIdentity   = $vm.Identity.Type
    AMAExtension      = $null
    DCRAssociations   = $null
    HeartbeatLastSeen = $null
}

$legacy = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -ErrorAction SilentlyContinue |
    Where-Object { $_.ExtensionType -eq "MicrosoftMonitoringAgent" }
$evidence.LegacyAgentFound = [bool]$legacy

$ama = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -ErrorAction SilentlyContinue |
    Where-Object { $_.ExtensionType -match "AzureMonitor(Windows|Linux)Agent" }
$evidence.AMAExtension = if ($ama) { $ama.ProvisioningState } else { "NOT INSTALLED" }

$evidence.DCRAssociations = (Get-AzDataCollectionRuleAssociation -TargetResourceId $vm.Id -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty DataCollectionRuleId) -join "; "

$evidence | ConvertTo-Json -Depth 5
$evidence | Export-Csv -Path ".\AMA-Evidence-$VMName-$(Get-Date -Format yyyyMMdd-HHmm).csv" -NoTypeInformation

Write-Host "Also run this KQL against the target workspace and attach the result:" -ForegroundColor Cyan
Write-Host "Heartbeat | where Computer == `"$VMName`" | summarize LastHeartbeat = max(TimeGenerated) by Category" -ForegroundColor Yellow
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-Service HealthService` | Detect legacy MMA/OMS agent presence (run on-machine) |
| `Get-AzVM \| Select Identity` | Confirm managed identity type/presence |
| `Get-AzVMExtension -Name AzureMonitorWindowsAgent -Status` | Extension provisioning state and status message |
| `Test-Path ...\mcs\mcsconfig.latest.xml` | Confirm agent actually received a DCR config (Windows) |
| `Get-AzDataCollectionRuleAssociation -TargetResourceId <id>` | List DCRs associated with a resource |
| `Get-AzDataCollectionRule -Name <dcr>` | Inspect a DCR's data sources/flows |
| `Get-AzDataCollectionEndpoint` | List DCEs in a resource group |
| `Get-AzMonitorPrivateLinkScope` | Inspect AMPLS registration |
| `Get-AzOperationalInsightsTable -TableName <table>` | Check current table plan |
| `Update-AzOperationalInsightsTable -Plan Basic\|Analytics\|Auxiliary` | Change a table's plan |
| `Invoke-RestMethod http://169.254.169.254/metadata/identity/oauth2/token?...` | Test IMDS/managed identity token retrieval (run on-machine) |
| `Heartbeat \| summarize max(TimeGenerated) by Computer` (KQL) | Confirm end-to-end delivery |
| `Get-AzOperationalInsightsWorkspace` | Workspace-level properties (SKU, retention, Private Link status) |
| `New-AzDataCollectionRuleAssociation` | Associate a resource to a DCR |
| `Remove-AzVMExtension -Name AzureMonitorWindowsAgent -Force` then reinstall | Force a clean re-registration when config receipt is stuck |

---
## 🎓 Learning Pointers

- **AMA has no configuration of its own — it is 100% DCR-driven.** This is the single biggest mental-model shift from the legacy agent, which pulled a workspace-wide configuration automatically on connection. A perfectly healthy AMA extension with zero DCR associations is fully "working" and collects nothing — this is by design, not a fault. See [Azure Monitor Agent overview](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-overview).
- **The legacy agent's shutdown is a hard, dated fact, not a slow-motion deprecation.** Validation-pause 26 Jan 2026, full backend shutdown 2 Mar 2026 — both now in the past as of this runbook's writing. Any legacy-agent finding during a health check is a live incident, not a modernization backlog item. See [Prepare for retirement of the Log Analytics agent](https://learn.microsoft.com/en-us/azure/defender-for-cloud/prepare-deprecation-log-analytics-mma-agent).
- **"Provisioning succeeded" is a package-install signal, not a health signal.** Cross-check with the on-disk config artifact or a `Heartbeat` query before ever telling a client their monitoring is confirmed working. See [Troubleshoot AMA on Windows VMs](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-windows-vm).
- **A Data Collection Endpoint is a Private-Link-only concept, region-bound, and easy to over-apply.** Adding a DCE to every deployment "just in case" adds unnecessary regional coupling and a failure point with zero benefit for clients not using Private Link. See [Data collection endpoints in Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-endpoint-overview).
- **Multihoming is supported and safe — duplicate, unfiltered data sources across DCRs are the actual risk.** Don't avoid multiple DCRs per machine out of caution; do audit for overlapping data sources across them, since duplication shows up as a cost anomaly, not an error.
- **Table plan is a decision, not a default.** Analytics-plan-by-default for every table is the single most common avoidable Log Analytics cost driver in an MSP's client estate; revisit plan choice as part of any cost-review engagement, not just at initial onboarding. See [Select a table plan based on data usage](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-table-plans).
