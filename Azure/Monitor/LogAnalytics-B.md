# Azure Monitor Agent / Log Analytics — Hotfix Runbook (Mode B: Ops)
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

Run these from an admin workstation with the `Az.Accounts` / `Az.Monitor` / `Az.OperationalInsights` modules, or directly on the affected machine where noted.

```powershell
# 1. Is this a LEGACY agent (MMA/OMS) machine? The legacy backend was shut down 2 Mar 2026 —
#    if this machine still runs the old agent, it has sent ZERO data since that date, full stop.
Get-Service HealthService -ErrorAction SilentlyContinue   # legacy MMA service — presence = legacy agent still installed

# 2. Is the Azure Monitor Agent (AMA) extension actually installed and provisioned?
Get-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Name AzureMonitorWindowsAgent |
    Select-Object Name, ProvisioningState, EnableAutomaticUpgrade
# Linux: -Name AzureMonitorLinuxAgent

# 3. Is a Data Collection Rule actually associated with this machine? (extension alone collects nothing)
Get-AzDataCollectionRuleAssociation -TargetResourceId "<vmResourceId>" |
    Select-Object Name, DataCollectionRuleId

# 4. Is data actually arriving in the workspace? (heartbeat is the fastest yes/no signal)
#    Run this as a KQL query against the Log Analytics workspace:
#    Heartbeat | where Computer == "<computerName>" | summarize LastHeartbeat = max(TimeGenerated)

# 5. Does the VM have a managed identity? (AMA authenticates to the DCR service via IMDS + managed identity — no identity, no config download)
(Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>").Identity
```

**Interpretation:**

| Finding | Action |
|---|---|
| `HealthService` present, no `AzureMonitorWindowsAgent` extension | Fix 1 — machine is still on the retired legacy agent; every day since 2 Mar 2026 is unrecoverable data loss, this is urgent, not routine |
| Extension `ProvisioningState = Succeeded` but no Heartbeat rows | Fix 2 — "Succeeded" only means the extension package installed; it does NOT mean the agent process is healthy or a DCR was ever received |
| No DCR association returned in step 3 | Fix 3 — extension is running with nothing to do; associate a DCR |
| VM `Identity` is `$null` | Fix 4 — AMA cannot authenticate to pull its DCR without a managed identity; nothing downstream will work until this is fixed |
| Heartbeat present but the specific table/log you need is missing | Fix 5 — the DCR exists but doesn't stream that data source; check the DCR's data flows, not the agent |
| Machine sits behind Private Link / AMPLS and has never reported | Fix 6 — check for a missing Data Collection Endpoint (DCE) before touching anything else |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Virtual Machine / Arc-enabled Server
    │
    ├── System- or User-Assigned Managed Identity  ◄── AMA authenticates via this, through IMDS
    │       (no identity = AMA can never download its configuration — hard stop)
    │
    └── AzureMonitorWindowsAgent / AzureMonitorLinuxAgent extension (VM extension, installed via
    │       Azure Policy, Portal, ARM/Bicep, or Get-AzVMExtension) — "Provisioning succeeded" ONLY
    │       confirms the package installed; it does NOT confirm the agent process is running,
    │       authenticated, or has received a configuration
    │
    ▼
Data Collection Rule (DCR) Association  — links this specific machine to one or more DCRs
    │       (no association = agent is running with an empty configuration, collects nothing —
    │        this is the single most common "AMA is installed but no data" root cause)
    │
    ▼
Data Collection Rule (DCR)  — defines WHAT to collect (perf counters, event logs, syslog facilities,
    │       custom logs, Windows Firewall/Sysmon via table-specific data sources) and WHERE it goes
    │
    ├── (only if the workspace uses Private Link / AMPLS) Data Collection Endpoint (DCE)
    │       — must exist in the SAME REGION as the agent; missing DCE on a Private-Link-enabled
    │         workspace = silent upload failure, agent has nothing useful to log locally
    │
    ▼
Log Analytics Workspace  — ingestion endpoint
    │
    └── Table  — governed by a Table Plan: Analytics ($/GB, full KQL, commitment-tier eligible),
                 Basic ($/GB cheaper, 30-day free retention, restricted KQL — built for high-volume
                 low-query tables), or Auxiliary (cheapest, minimal indexing/retention)
                 — sending a data source to a table with the wrong plan for its query pattern is a
                   common self-inflicted cost or "why can't I query this" surprise, not a bug
```

**Critical mental-model correction:** the legacy Log Analytics agent (MMA/Microsoft Monitoring Agent, sometimes still called "the OMS agent") is not merely deprecated — Microsoft shut down its backend upload path entirely on **2 March 2026**. A machine still running `HealthService` today is not "using an older but working agent," it is a machine that has been completely blind to Azure Monitor since that date. Treat any legacy-agent finding as a P1 data-loss issue, not a routine upgrade backlog item.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Rule out the legacy-agent dead-end first**
```powershell
Get-Service HealthService -ErrorAction SilentlyContinue
```
If this returns a service, stop diagnosing AMA-specific issues — this machine needs a full migration to AMA (Fix 1), not a config tweak. The legacy backend accepts zero uploads as of 2 Mar 2026.

**Step 2 — Confirm the extension is actually healthy, not just "Succeeded"**
```powershell
Get-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Name AzureMonitorWindowsAgent -Status
```
Expected: `ProvisioningState = Succeeded` AND a recent status message. Then, on the machine itself, confirm the agent actually pulled a configuration:
```powershell
# Windows — confirms the DCR was downloaded, not just that the extension is installed
Test-Path "C:\WindowsAzure\Resources\AMADataStore.$env:COMPUTERNAME\mcs\mcsconfig.latest.xml"
```
If this file doesn't exist, the agent has never received a DCR — go to Step 3.

**Step 3 — Confirm DCR association exists and targets this machine**
```powershell
Get-AzDataCollectionRuleAssociation -TargetResourceId "<vmResourceId>"
```
Expected: at least one association. If empty, the extension is running with nothing configured — this is the #1 "installed AMA, still no data" ticket pattern. Go to Fix 3.

**Step 4 — Confirm the managed identity is actually usable, not just present**
```powershell
# Run ON the VM — confirms IMDS itself is reachable, which AMA depends on to authenticate
Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" -Headers @{Metadata="true"}
```
Expected: a valid token response. A failure here (timeout, 400, connection refused) points at IMDS/NSG/firewall blocking loopback traffic to `169.254.169.254`, not a Log Analytics problem at all.

**Step 5 — Confirm data is landing in the workspace**
```kql
Heartbeat
| where Computer == "<computerName>"
| summarize LastHeartbeat = max(TimeGenerated), Count = count() by Computer, Category
```
`Category == "Azure Monitor Agent"` with a recent timestamp = the pipeline is healthy end-to-end. No rows at all = go back to Step 2/3. Rows present but the specific table you actually need (e.g. a custom log or a perf counter) is missing = go to Step 6.

**Step 6 — If heartbeat is healthy but a specific data source is missing, check the DCR's data flows, not the agent**
```powershell
(Get-AzDataCollectionRule -ResourceGroupName "<rg>" -Name "<dcrName>").DataFlow |
    Select-Object Stream, Destination
```
If the stream you need (e.g. `Microsoft-Perf`, `Microsoft-Syslog`, `Microsoft-WindowsEvent`) isn't listed, the agent was never told to collect it — this is a DCR authoring gap, not an agent fault.

---
## Common Fix Paths

<details><summary>Fix 1 — Machine still running the retired legacy agent (MMA/OMS)</summary>

```powershell
# There is no "just leave it" option — the legacy backend stopped accepting uploads 2 Mar 2026.
# Install AMA alongside/in place of the legacy agent, then remove the legacy agent once confirmed healthy.
Set-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Location "<region>" `
    -Publisher "Microsoft.Azure.Monitor" -ExtensionType "AzureMonitorWindowsAgent" `
    -Name "AzureMonitorWindowsAgent" -TypeHandlerVersion "1.*" -EnableAutomaticUpgrade $true

# Ensure a managed identity exists BEFORE the extension needs it
Update-AzVM -ResourceGroupName "<rg>" -VM (Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>") -IdentityType SystemAssigned

# Associate the appropriate DCR(s) — reuse an existing fleet DCR where possible rather than
# authoring a one-off per machine
New-AzDataCollectionRuleAssociation -TargetResourceId "<vmResourceId>" `
    -AssociationName "dcr-assoc-$(Get-Date -Format yyyyMMdd)" -DataCollectionRuleId "<dcrResourceId>"

# Only AFTER confirming Heartbeat data flows from AMA — remove the legacy agent
Remove-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Name "MicrosoftMonitoringAgent" -Force
```

**Rollback:** re-adding the legacy extension does nothing useful — its backend is gone. If AMA migration surfaces an unexpected problem, leave the legacy agent installed (harmless, just non-functional) rather than removing it mid-troubleshoot, and escalate.

</details>

<details><summary>Fix 2 — Extension shows Succeeded but agent isn't actually collecting</summary>

```powershell
# Confirm on-machine whether a config was ever received — this is the real signal, not the extension status
# Windows:
Test-Path "C:\WindowsAzure\Resources\AMADataStore.$env:COMPUTERNAME\mcs\mcsconfig.latest.xml"
Get-ChildItem "C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.Monitor.AzureMonitorWindowsAgent" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 5

# Linux:
#   ls -la /etc/opt/microsoft/azuremonitoragent/config-cache/configchunks
#   tail -n 100 /var/opt/microsoft/azuremonitoragent/log/mdsd.err

# If no config file exists and a DCR association DOES exist, the download itself is failing —
# most often IMDS/managed-identity or outbound-network related. Reinstall as a next step:
Remove-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Name AzureMonitorWindowsAgent -Force
Set-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Location "<region>" `
    -Publisher "Microsoft.Azure.Monitor" -ExtensionType "AzureMonitorWindowsAgent" `
    -Name "AzureMonitorWindowsAgent" -TypeHandlerVersion "1.*" -EnableAutomaticUpgrade $true
```

**Rollback:** extension reinstall is non-destructive to the VM; it only re-registers the agent. No data already ingested is affected.

</details>

<details><summary>Fix 3 — No DCR associated with the machine</summary>

```powershell
# Associate an existing fleet DCR (preferred over authoring a new one per-machine)
Get-AzDataCollectionRule -ResourceGroupName "<rg>" | Select-Object Name, Id

New-AzDataCollectionRuleAssociation -TargetResourceId "<vmResourceId>" `
    -AssociationName "dcr-assoc-$(Get-Date -Format yyyyMMdd)" `
    -DataCollectionRuleId "<dcrResourceId>"

# Confirm it took effect
Get-AzDataCollectionRuleAssociation -TargetResourceId "<vmResourceId>"
```

**Rollback:** `Remove-AzDataCollectionRuleAssociation -TargetResourceId "<vmResourceId>" -AssociationName "<name>"` — stops future collection immediately; already-ingested data is unaffected.

</details>

<details><summary>Fix 4 — No managed identity on the VM</summary>

```powershell
# System-assigned is the simplest fix for a single machine
$vm = Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>"
Update-AzVM -ResourceGroupName "<rg>" -VM $vm -IdentityType SystemAssigned

# For fleet consistency (shared identity across many machines), use a user-assigned identity instead:
Update-AzVM -ResourceGroupName "<rg>" -VM $vm -IdentityType UserAssigned `
    -IdentityId "<userAssignedIdentityResourceId>"

# The AMA extension does NOT automatically pick up an identity added after install on some
# older extension versions — restart the extension after the identity change:
Remove-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Name AzureMonitorWindowsAgent -Force
Set-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" -Location "<region>" `
    -Publisher "Microsoft.Azure.Monitor" -ExtensionType "AzureMonitorWindowsAgent" `
    -Name "AzureMonitorWindowsAgent" -TypeHandlerVersion "1.*" -EnableAutomaticUpgrade $true
```

**Rollback:** `Update-AzVM -IdentityType None` removes the identity — only do this if it was added in error; removing it will break AMA again.

</details>

<details><summary>Fix 5 — Heartbeat is healthy but a specific data source/table is missing</summary>

```powershell
# Inspect the DCR's actual data flows — the agent only sends what the DCR explicitly lists
$dcr = Get-AzDataCollectionRule -ResourceGroupName "<rg>" -Name "<dcrName>"
$dcr.DataFlow | Select-Object Stream, Destination
$dcr.DataSources  # perf counters / event log queries / syslog facilities actually configured

# Add the missing data source to the DCR (example: adding a Windows Event Log stream)
# — typically done via the Portal's DCR "Data Sources" tab or an ARM/Bicep update for fleet
# consistency; direct cmdlet editing of nested DataSource objects is error-prone for complex DCRs
```

**Rollback:** removing a data flow from a DCR stops new collection of that stream; historical data already ingested into the workspace table is unaffected and remains queryable per its table plan's retention.

</details>

<details><summary>Fix 6 — Machine behind Private Link/AMPLS has never reported</summary>

```powershell
# Confirm whether a DCE is required and present — DCE is ONLY needed for Private Link/AMPLS scenarios,
# and it MUST be in the same Azure region as the agent
Get-AzDataCollectionEndpoint -ResourceGroupName "<rg>"

# Confirm the DCR references the DCE (Portal: DCR > Resources > Enable Data Collection Endpoints)
(Get-AzDataCollectionRule -ResourceGroupName "<rg>" -Name "<dcrName>").DataCollectionEndpointId

# Confirm the DCE is registered in the Azure Monitor Private Link Scope (AMPLS) resource
Get-AzMonitorPrivateLinkScope -ResourceGroupName "<rg>"
```

**Rollback:** N/A — this is an investigative/config-correction fix path, not a destructive change.

</details>

---
## Escalation Evidence

```
=== Azure Monitor Agent / Log Analytics Escalation Pack ===
Date/Time:                     _______________
VM / Arc machine resource ID:  _______________
Region:                        _______________

Legacy agent (HealthService) present:   Yes / No
AMA extension installed:                Yes / No — ProvisioningState: _______________
Managed identity present:               Yes / No — Type: System / User-assigned
mcsconfig.latest.xml present on host:   Yes / No (or Linux configchunks dir populated: Yes / No)
DCR association(s) found:               _______________
DCR data flows include needed stream:   Yes / No — Stream(s): _______________
Data Collection Endpoint (if Private Link): Present / Not present / N/A
Heartbeat last seen:                    _______________ (UTC)
Table plan of affected table:           Analytics / Basic / Auxiliary

Actions taken so far:
1.
2.
3.

Escalation contact: Microsoft Support via Azure Portal > Monitor > Diagnostic settings > Support + troubleshooting
Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-windows-vm
```

---
## 🎓 Learning Pointers

- **The legacy Log Analytics agent's backend is gone, not just unsupported.** Microsoft paused legacy uploads for validation on 26 Jan 2026 and shut the legacy backend down entirely on 2 Mar 2026. A machine still showing `HealthService` today isn't running an outdated-but-working agent — it has sent zero telemetry since that date. Treat this as a data-loss incident, not a backlog item. See [Prepare for retirement of the Log Analytics agent](https://learn.microsoft.com/en-us/azure/defender-for-cloud/prepare-deprecation-log-analytics-mma-agent).
- **"Provisioning succeeded" on the VM extension only confirms the package installed — it says nothing about the agent's health.** Always cross-check with the on-disk config file (`mcsconfig.latest.xml` on Windows) or a live `Heartbeat` query before telling a client monitoring is working. See [Troubleshoot Azure Monitor Agent on Windows VMs](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-windows-vm).
- **An installed agent with no DCR association collects nothing — this is normal, expected behavior, not a bug.** Unlike the legacy agent (which was configured centrally via the workspace), AMA is entirely driven by explicit DCR associations per resource. See [Data Collection Rules overview](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-rule-overview).
- **A Data Collection Endpoint is only required for Private Link/AMPLS — don't add one by default.** Adding a DCE unnecessarily adds a region-matching constraint and an extra failure point for zero benefit on a machine that isn't network-isolated. See [Data collection endpoints in Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-endpoint-overview).
- **Multiple DCRs on one machine (multihoming) is supported but can silently double your ingestion bill.** If two associated DCRs both collect the same performance counters or event logs without differentiated filters, you get duplicate rows and duplicate charges — this shows up as an unexplained cost spike, not an error.
- **Table plan choice (Analytics/Basic/Auxiliary) determines both cost and what KQL you can run later.** Routing a high-volume, rarely-queried log source (e.g. verbose diagnostic logs) into an Analytics-plan table is a common, avoidable cost driver — Basic and Auxiliary plans are dramatically cheaper per GB but restrict query capability, so this is a design decision to make before onboarding a new data source, not after. See [Select a table plan](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-table-plans).
