# Microsoft Sentinel Data Connectors — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why connectors fail silently, not just what to click.

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
- Microsoft Sentinel data connector architecture across the three connector families: agent-based (AMA/DCR), API/service-to-service (Office 365, Entra ID, Defender XDR), and Azure-resource diagnostic-settings-based
- Ingestion delay, silent failure modes, and workspace-level gating (quota, RBAC)
- Multi-tenant/MSP considerations (Azure Lighthouse-delegated workspaces, Arc-onboarded on-prem servers)

**Out of scope:**
- Analytics rule tuning and detection logic (separate topic)
- KQL query optimization for hunting/workbooks
- Sentinel automation (Logic Apps playbooks) — see a future playbook-specific runbook
- Codeless Connector Platform (CCP) custom connector authoring

**Assumptions:**
- Sentinel is enabled on a Log Analytics workspace (not the legacy "classic" Sentinel-only experience)
- Engineer has Log Analytics Reader minimum, ideally Sentinel Contributor, to query and inspect connector health
- Environment may include Azure Arc-onboarded on-prem or multi-cloud servers (common in MSP estates)

---

## How It Works

<details><summary>Full architecture</summary>

Microsoft Sentinel itself has no ingestion pipeline of its own — it is a solution layered on top of a **Log Analytics workspace**. Every data connector's real job is to get data into workspace tables (`SecurityEvent`, `SigninLogs`, `OfficeActivity`, `AzureActivity`, custom tables, etc.). Sentinel then reads from those tables for analytics rules, workbooks, and hunting.

There are three fundamentally different connector mechanisms, and troubleshooting them requires knowing which one you're dealing with:

**1. Agent-based (AMA + Data Collection Rules) — the modern standard**
```
Source (VM / Arc server / container)
   │
   ├─ Azure Monitor Agent (AMA) — extension installed on the machine
   │      reads: Windows Event Log, Syslog, Performance counters, CEF, custom text logs
   │
   ▼
Data Collection Rule (DCR) — defines WHAT to collect and WHERE to send it
   │      • dataSources: which event log channels / syslog facilities
   │      • destinations: target Log Analytics workspace(s)
   │      • dataFlows: mapping between sources and destinations/tables
   │
   ▼
Data Collection Rule Association (DCRA) — the actual LINK between a
specific resource and a DCR. A DCR existing does not mean any machine
is using it — the association is a separate ARM object.
   │
   ▼
Log Analytics workspace ingestion endpoint (*.ingest.monitor.azure.com)
   │
   ▼
Workspace table populated (e.g. SecurityEvent, Syslog, CommonSecurityLog)
```
This replaced the legacy Log Analytics agent (MMA/OMS agent), which used workspace keys and "Connected Sources" directly — no DCR concept existed. MMA is in deprecation; new Sentinel builds should never use it.

**2. API / service-to-service connectors — Microsoft-managed polling or streaming**
```
Source service (Microsoft 365, Entra ID, Defender XDR, ServiceNow, AWS, GCP, etc.)
   │
   ├─ First-time consent: Global Admin/Security Admin grants Sentinel's
   │  service principal read access to the source service's audit/activity API
   │
   ▼
Microsoft-managed background job (NOT visible to the customer, runs in
Microsoft's service tenant) polls or streams from the source API
   │
   ▼
Data lands directly in workspace table (OfficeActivity, SigninLogs, AuditLogs,
DeviceEvents for Defender, etc.)
```
Critically: there is no local agent, no DCR, and almost nothing to "restart" on the customer side for these. Failures are either (a) consent/token expiry, (b) a source-side toggle being off (e.g. Unified Audit Log), or (c) a Microsoft-side service health issue.

**3. Azure resource connectors — diagnostic settings**
```
Azure resource (Key Vault, Azure Firewall, App Service, subscription Activity Log)
   │
   ├─ Diagnostic setting configured on the resource itself, specifying:
   │      • which log categories to send
   │      • destination = the Sentinel-linked Log Analytics workspace
   │
   ▼
Azure Monitor diagnostics pipeline (platform-managed, no agent)
   │
   ▼
Workspace table (AzureDiagnostics or resource-specific tables like AzureActivity)
```
The Sentinel "connector" for these is often just a UI page with a button that opens the resource's diagnostic settings blade — there's no separate Sentinel-side object to troubleshoot beyond the diagnostic setting itself.

</details>

---

## Dependency Stack

```
Microsoft Sentinel (analytics/workbook layer)
        │
        ▼
Log Analytics Workspace (data plane — this is where connectors actually write)
        │
        ├── Workspace-level gates that silently block ALL ingestion:
        │       ├── Daily ingestion cap (WorkspaceCapping.DailyQuotaGb)
        │       ├── RBAC on the workspace (Log Analytics Contributor / Monitoring Metrics Publisher)
        │       └── Data retention / table plan (Analytics vs. Auxiliary vs. Basic — affects cost, not ingestion, but affects what's queryable in Sentinel UI)
        │
        ├── AGENT-BASED connectors
        │       ├── AMA extension installed + Running on source resource
        │       ├── Data Collection Rule (DCR) exists
        │       ├── Data Collection Rule Association (DCRA) links resource → DCR
        │       ├── Data Collection Endpoint (DCE) — required if Private Link/network isolation in use
        │       ├── Network egress: *.ods.opinsights.azure.com, *.monitor.azure.com, *.ingest.monitor.azure.com
        │       └── For Arc servers: Arc agent (azcmagent) itself must be Connected first
        │
        ├── API/SERVICE connectors
        │       ├── First-time admin consent (Sentinel service principal ↔ source service)
        │       ├── Source-side feature toggle (e.g. UnifiedAuditLogIngestionEnabled for O365)
        │       ├── Underlying licence (e.g. Defender XDR connector needs the relevant Defender SKU)
        │       └── Microsoft-managed pipeline health (no customer-side component)
        │
        └── AZURE RESOURCE connectors
                ├── Diagnostic setting exists on the resource, pointed at the workspace
                ├── Correct log categories selected
                └── RBAC to configure (Monitoring Contributor) — only needed at setup time
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Connector "Connected", zero rows in table | DCR exists but no DCRA linking the resource | `Get-AzDataCollectionRuleAssociation -TargetResourceId <id>` |
| All tables stopped simultaneously | Daily ingestion cap hit, or workspace RBAC change | `Get-AzOperationalInsightsWorkspace ... WorkspaceCapping` |
| Single VM/Arc server missing from Heartbeat | AMA extension crashed, or Arc agent disconnected | `azcmagent show` on the machine; extension status via `az vm extension show` |
| Office 365 connector shows Connected, OfficeActivity empty | UAL not enabled at tenant, or 60-90 min propagation delay | `Get-AdminAuditLogConfig` |
| Entra sign-in logs missing entirely | Diagnostic setting for Entra ID was never configured — the "connector" here is just a shortcut into diagnostic settings | Entra admin center → Monitoring & health → Diagnostic settings |
| Data appears with 12-24h lag consistently | Expected for some log categories (SharePoint/OneDrive UAL); not a fault | Confirm against Microsoft's documented SLA for that specific connector |
| Custom log / CEF/Syslog source stopped after a source appliance firmware update | Appliance changed its log format/port, breaking the AMA/CEF collector parsing rules | Check `CommonSecurityLog` for partial/malformed rows; verify syslog daemon config on the forwarder |
| MSP multi-tenant: connector worked in direct tenant, fails via Lighthouse-delegated access | Delegated role assignment missing the specific role required by that connector (Reader is not always sufficient) | Check the connector's own Prerequisites tab — roles differ per connector |
| DCR shows correct dataFlows but wrong destination workspace | DCR was cloned/copied from another environment without updating `destinations` | `Get-AzDataCollectionRule -Name <name> | Select -Expand Destinations` |
| Ingestion resumed after being stuck — but only for new data, historical gap never backfills | Expected — Sentinel/Log Analytics connectors are forward-only; no automatic backfill exists for most connectors | Confirm gap window with stakeholders; note in escalation record as accepted data loss window |

---

## Validation Steps

**1. Confirm you're querying the correct, Sentinel-bound workspace**
```powershell
Get-AzSentinelWorkspaceManager -ResourceGroupName "<rg>" -WorkspaceName "<workspace>" -ErrorAction SilentlyContinue
# Or simply confirm in portal: Sentinel → Settings → Workspace settings
```

**2. Query ingestion volume trend (catches silent degradation, not just total outage)**
```kusto
union withsource=TableName SecurityEvent, SigninLogs, AzureActivity, OfficeActivity, Heartbeat
| where TimeGenerated > ago(7d)
| summarize Count = count() by TableName, bin(TimeGenerated, 1h)
| render timechart
```
Good: steady volume matching business hours pattern. Bad: a cliff-edge drop to zero at a specific timestamp — correlate that timestamp with change events (patching windows, cert rotations, firewall changes).

**3. Validate DCR → DCRA → resource chain end-to-end**
```powershell
$dcr = Get-AzDataCollectionRule -ResourceGroupName "<rg>" -Name "<dcr-name>"
$dcr.DataFlow | Format-Table Stream, Destination
Get-AzDataCollectionRuleAssociation -TargetResourceId "<vm-resource-id>" |
    Select-Object Name, DataCollectionRuleId
```
Bad: `DataCollectionRuleId` in the association points to a DCR ID that doesn't match `$dcr.Id` — resource is linked to the wrong (or a stale/deleted) DCR.

**4. Confirm workspace ingestion isn't capped**
```powershell
(Get-AzOperationalInsightsWorkspace -ResourceGroupName "<rg>" -Name "<workspace>").WorkspaceCapping
```
Good: `DailyQuotaGb = -1` (unlimited) or a value comfortably above daily average ingestion.

**5. For API connectors, confirm the connector's own health blade + underlying source toggle**
```
Sentinel portal → Data connectors → <connector> → Open connector page
```
Cross-reference with source-side settings (UAL for O365, diagnostic settings for Entra ID, licensing for Defender XDR).

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm scope of the outage

1. Is it one table, one connector, or the whole workspace? Run the union query from Validation Step 2.
2. If whole-workspace: jump to workspace-level checks (quota, RBAC) before touching any individual connector.
3. If single connector: identify which of the three connector families it belongs to (agent/API/diagnostic-settings) — this determines the entire rest of the investigation.

### Phase 2 — Agent-based connector diagnosis

1. Confirm the source machine itself is healthy and reachable (RDP/SSH, basic connectivity).
2. For Arc-onboarded servers, Arc connectivity is a prerequisite layer beneath AMA — check it first:
   ```powershell
   & "C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe" show
   ```
3. Check the AMA extension provisioning state via ARM, not just the local service — a "Running" local service can still be in a `Failed` provisioning state if the extension's own config download failed:
   ```powershell
   az vm extension show --resource-group <rg> --vm-name <vm> --name AzureMonitorWindowsAgent --query "instanceView"
   ```
4. Check the DCR/DCRA chain as in Validation Step 3.
5. Check AMA local logs for parsing or auth errors:
   ```
   C:\Resources\Directory\AMA-Diagnostics\Logs\ (Windows)
   /var/opt/microsoft/azuremonitoragent/log/ (Linux)
   ```

### Phase 3 — API/service connector diagnosis

1. Confirm the connector's consent hasn't expired — Microsoft occasionally requires re-consent after major service changes or tenant admin role changes.
2. Confirm the source-side feature flag is on (UAL for O365 being the most common gap).
3. Check Microsoft 365 Service Health / Entra ID Service Health for an active incident affecting the connector's backend — many "broken connector" tickets are actually upstream Microsoft incidents.
4. If multi-tenant/Lighthouse: confirm the delegated role assignment includes the specific role documented for that connector (not just Reader).

### Phase 4 — Diagnostic-settings connector diagnosis

1. Open the resource directly (not through Sentinel) → Monitoring → Diagnostic settings.
2. Confirm a diagnostic setting exists, targets the correct workspace, and has the expected categories checked.
3. Re-save the diagnostic setting even if it looks correct — this has been a known workaround for settings that silently stop flowing after a platform-side resource migration.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Bulk-repair missing DCR associations across an MSP fleet</summary>

**Use when:** Onboarding revealed multiple VMs/Arc servers have the AMA extension installed but no DCR association (common when DCRs were deployed via policy but assignment lagged, or new VMs were added to a scale set/resource group after the policy's last evaluation cycle).

```powershell
# Get all VMs in a resource group missing the target DCR association
$dcrId = "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Insights/dataCollectionRules/<dcr-name>"
$vms = Get-AzVM -ResourceGroupName "<rg>"

foreach ($vm in $vms) {
    $assoc = Get-AzDataCollectionRuleAssociation -TargetResourceId $vm.Id -ErrorAction SilentlyContinue |
        Where-Object { $_.DataCollectionRuleId -eq $dcrId }

    if (-not $assoc) {
        Write-Host "Missing association: $($vm.Name) — creating..." -ForegroundColor Yellow
        New-AzDataCollectionRuleAssociation `
            -ResourceUri $vm.Id `
            -AssociationName "SentinelDCR-Association" `
            -RuleId $dcrId
    } else {
        Write-Host "$($vm.Name) already associated" -ForegroundColor Green
    }
}
```

**Rollback:** removing an association stops ingestion for that resource but does not delete historical data — safe to reverse via `Remove-AzDataCollectionRuleAssociation`.
</details>

<details><summary>Playbook 2 — Recover from a workspace-wide daily cap event</summary>

**Use when:** A misbehaving log source (verbose debug logging left on, a runaway custom log connector) blew through the daily quota and silently halted ALL ingestion for the remainder of the UTC day — a frequent MSP incident that looks like "Sentinel is down" but is workspace-side.

```powershell
# 1. Confirm the cap was hit and identify which table spiked
Get-AzOperationalInsightsWorkspace -ResourceGroupName "<rg>" -Name "<workspace>" | Select-Object -ExpandProperty WorkspaceCapping

# 2. Identify the volume spike source (run BEFORE the cap resets, using the last available data)
union withsource=TableName *
| where TimeGenerated > ago(24h)
| summarize IngestedMB = sum(_BilledSize) / 1024 / 1024 by TableName
| top 10 by IngestedMB desc

# 3. Either raise the cap (short-term) or fix the noisy source (long-term)
Set-AzOperationalInsightsWorkspace -ResourceGroupName "<rg>" -Name "<workspace>" -DailyQuotaGb 50   # example raised cap

# 4. For a known noisy custom log/CEF source, apply ingestion-time transformation or reduce log verbosity at the source appliance
```

**Rollback:** lowering the cap back down after remediating the noisy source; document original vs. new cap for cost governance sign-off.
</details>

<details><summary>Playbook 3 — Re-establish an Office 365 / Entra connector after tenant admin turnover</summary>

**Use when:** The admin who originally authorized a connector has left, had their account disabled, or lost the role Sentinel's consent depends on — a very common MSP scenario during client offboarding/onboarding of internal IT staff.

```
1. Confirm current UAL / diagnostic setting state (source-side) is still correct — this state
   usually survives the admin change; only the connector's OWN auth token/consent needs refresh.

2. In Sentinel portal, as a current Global Admin or Security Admin:
   Data connectors → <connector> → Open connector page → Disconnect → Reconnect
   (This re-issues consent under the current admin's context; does not require the original admin.)

3. Validate ingestion resumed:
```
```kusto
OfficeActivity
| where TimeGenerated > ago(1h)
| summarize count()
```

**Rollback:** none — reconnect is idempotent and non-destructive to historical data.
</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Sentinel data connector health evidence for escalation.
.NOTES     Requires Az.OperationalInsights, Az.Monitor modules and Log Analytics Reader
           (minimum) on the target workspace. Run from an authenticated Az PowerShell session.
#>

param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$WorkspaceName
)

$OutputPath = "$env:TEMP\Sentinel-ConnectorEvidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# 1. Workspace capping / quota state
Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName |
    Select-Object Name, Sku, RetentionInDays -ExpandProperty WorkspaceCapping |
    Export-Csv "$OutputPath\01-WorkspaceCapping.csv" -NoTypeInformation

# 2. All DCRs in the resource group
Get-AzDataCollectionRule -ResourceGroupName $ResourceGroupName |
    Select-Object Name, Kind, Id |
    Export-Csv "$OutputPath\02-DataCollectionRules.csv" -NoTypeInformation

# 3. Ingestion volume by table, last 7 days (requires workspace query access)
$query = @"
union withsource=TableName *
| where TimeGenerated > ago(7d)
| summarize Count = count(), LastSeen = max(TimeGenerated) by TableName
| order by LastSeen asc
"@
try {
    $ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName
    $results = Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $query
    $results.Results | Export-Csv "$OutputPath\03-TableIngestionSummary.csv" -NoTypeInformation
} catch {
    "Query failed: $($_.Exception.Message)" | Out-File "$OutputPath\03-TableIngestionSummary-ERROR.txt"
}

Write-Host "Evidence collected to: $OutputPath" -ForegroundColor Green
Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath.zip" -Force
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|--------------------|
| Query table ingestion volume | `union withsource=TableName * \| summarize count() by TableName` |
| Check last ingested row per table | `summarize max(TimeGenerated) by TableName` |
| List DCRs | `Get-AzDataCollectionRule -ResourceGroupName <rg>` |
| Check DCR-to-resource association | `Get-AzDataCollectionRuleAssociation -TargetResourceId <id>` |
| Check workspace daily cap | `(Get-AzOperationalInsightsWorkspace ...).WorkspaceCapping` |
| Raise/remove daily cap | `Set-AzOperationalInsightsWorkspace ... -DailyQuotaGb -1` |
| Check AMA extension state | `az vm extension show --name AzureMonitorWindowsAgent` |
| Check Arc agent connectivity | `azcmagent show` |
| Check UAL enabled (O365) | `Get-AdminAuditLogConfig \| Select UnifiedAuditLogIngestionEnabled` |
| Enable UAL | `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true` |
| View connector health in portal | Sentinel → Data connectors → select connector |
| View diagnostic settings on a resource | Resource → Monitoring → Diagnostic settings |
| Reconnect an API connector | Data connectors → connector → Open connector page → Disconnect/Reconnect |
| Check Entra diagnostic settings | Entra admin center → Monitoring & health → Diagnostic settings |
| Check M365/Entra service health | Microsoft 365 admin center → Health → Service health |

---

## 🎓 Learning Pointers

- **Sentinel has no ingestion pipeline of its own** — every connector's job is really "get data into a Log Analytics workspace table." Understanding which of the three connector families (agent/DCR, API/service, diagnostic-settings) you're dealing with determines the entire troubleshooting path — treating them the same wastes time. [Sentinel data connector architecture](https://learn.microsoft.com/en-us/azure/sentinel/connect-data-sources)
- **A DCR existing is not the same as a resource using it** — the Data Collection Rule Association (DCRA) is a distinct ARM object, and MSP fleets built via Azure Policy commonly have gaps where new VMs never got the association applied. Build DCRA verification into every onboarding checklist. [DCR overview](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-rule-overview)
- **Workspace daily quota failures are silent by design** — there's no default alert when a cap is hit; ingestion simply stops until UTC midnight. Set up a budget/quota alert proactively rather than discovering this mid-incident. [Manage workspace cost](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/analyze-usage)
- **API connectors have almost nothing to "restart" on the customer side** — for Office 365/Entra/Defender XDR connectors, most fixes are either a source-side toggle (UAL) or a disconnect/reconnect to refresh consent, not a service you can bounce. Don't waste escalation time looking for a local agent that doesn't exist for these.
- **MMA (legacy Log Analytics agent) is being retired** — if inheriting an older Sentinel deployment, confirm whether connectors still use MMA vs. modern AMA before troubleshooting; the entire diagnostic approach differs and MMA-specific fixes won't apply to AMA/DCR-based connectors. [AMA migration helper](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azum-migration-helper)
- **Community resource:** the [Microsoft Sentinel Tech Community](https://techcommunity.microsoft.com/category/azure-sentinel) and r/AzureSentinel frequently surface connector-specific regressions (e.g. a specific CCP connector breaking after a schema change) faster than official docs update.
