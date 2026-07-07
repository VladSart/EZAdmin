# Microsoft Sentinel Data Connectors — Hotfix Runbook (Mode B: Ops)
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

Run in the Log Analytics workspace tied to Sentinel (Log Analytics query blade or via `Invoke-AzOperationalInsightsQuery`):

```kusto
// 1 — Is ANY data landing in the last 2 hours from the affected table?
union withsource=TableName *
| where TimeGenerated > ago(2h)
| summarize Count = count() by TableName
| where TableName in ("SecurityEvent","SigninLogs","AuditLogs","OfficeActivity","AzureActivity","DeviceEvents")
| order by TableName asc

// 2 — Last ingestion timestamp per table (gap detection)
union withsource=TableName SecurityEvent, SigninLogs, AzureActivity, OfficeActivity
| summarize LastSeen = max(TimeGenerated) by TableName
| extend GapMinutes = datetime_diff('minute', now(), LastSeen)

// 3 — Connector heartbeat (for agent-based connectors: AMA/Log Analytics agent)
Heartbeat
| where TimeGenerated > ago(1h)
| summarize LastHeartbeat = max(TimeGenerated) by Computer, Category
| order by LastHeartbeat asc

// 4 — Data Collection Rule (DCR) association check (AMA-based connectors)
// Run in Azure CLI / Cloud Shell:
// az monitor data-collection rule association list --resource <vm-or-arc-resource-id>

// 5 — Diagnostic settings still pointed at the workspace? (for Azure resource connectors)
// az monitor diagnostic-settings list --resource <resource-id>
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| Table shows 0 rows, connector shows "Connected" in portal | Silent ingestion failure — DCR misconfigured or permissions revoked | Fix 1 |
| `GapMinutes` growing steadily across all tables | Workspace-level issue (quota, permissions) not connector-specific | Fix 2 |
| Heartbeat missing for AMA-managed VMs/Arc servers | AMA extension stopped, DCR unlinked, or agent can't reach ingestion endpoint | Fix 3 |
| Office 365 connector shows "Connected" but `OfficeActivity` empty | Unified Audit Log not enabled in the source tenant, or connector never fully authorized | Fix 4 |
| Connector page shows a red/yellow health warning | Underlying resource permission (Reader role, Contributor, or Managed Identity) revoked | Fix 5 |
| Ingestion delayed 15–90 min but eventually arrives | Normal — some connectors batch (Office 365 up to 30-60 min, Azure Activity up to 15 min) | Not a fault — confirm SLA before escalating |

---

## Dependency Cascade

<details><summary>What must be true for a Sentinel data connector to ingest data</summary>

**Agent-based (AMA / Data Collection Rule) connectors — e.g. Windows Security Events, Syslog, CEF:**
```
[Source machine: VM, Arc-onboarded server, or on-prem via Arc]
    └── [Azure Monitor Agent (AMA) extension installed and running]
            └── [Data Collection Rule (DCR) created and associated with the resource]
                    └── [DCR references the correct Data Collection Endpoint (DCE) if private link is used]
                            └── [Network path: AMA can reach *.ods.opinsights.azure.com / *.monitor.azure.com]
                                    └── [Log Analytics workspace ingestion — table populated]
                                            └── [Sentinel: workspace onboarded to Sentinel]
```

**API/service-to-service connectors — e.g. Office 365, Entra ID, Defender XDR:**
```
[Source service: Microsoft 365 / Entra ID / Defender]
    └── [Diagnostic settings OR native Sentinel connector authorization]
            └── [Service principal / Sentinel's managed identity has required role
                 (e.g. Security Reader, or "Global Administrator" during first-time consent)]
                    └── [Data connector shows "Connected" state in Sentinel portal]
                            └── [Streaming or polling job (Microsoft-managed) pushes data into workspace]
                                    └── [Table populated: OfficeActivity, SigninLogs, AuditLogs, etc.]
```

**Azure resource connectors — e.g. Azure Activity, Azure Firewall, Key Vault:**
```
[Azure resource: subscription, firewall, key vault, etc.]
    └── [Diagnostic settings configured to send logs to the Sentinel-linked Log Analytics workspace]
            └── [Category selected in diagnostic settings matches expected table]
                    └── [RBAC: Contributor or Monitoring Contributor on resource to configure — not needed after setup]
                            └── [Data lands in workspace table]
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm workspace is actually the one Sentinel is bound to**
```
Sentinel portal → Settings → Workspace settings
```
Expected: workspace name matches what you're querying in Log Analytics. Multiple workspaces in a subscription is the #1 cause of "connector says connected but I see no data" — analysts query the wrong workspace.

**Step 2 — Check connector status page**
```
Sentinel portal → Content management → Data connectors → select connector → Instructions tab
```
Good: Green "Connected" with a recent "last log received" timestamp.
Bad: Status stuck on a timestamp from days ago, or the connector requires a Data Collection Rule that shows 0 resources.

**Step 3 — Validate the DCR chain (AMA-based connectors)**
```powershell
# List DCRs and check resource association
Get-AzDataCollectionRule -ResourceGroupName "<rg>" | Select-Object Name, Kind, DataFlows

# Confirm association exists for the target VM/Arc server
Get-AzDataCollectionRuleAssociation -TargetResourceId "<vm-resource-id>"
```
Bad: `Get-AzDataCollectionRuleAssociation` returns nothing → the DCR was created but never linked to the machine. This is the single most common AMA connector failure.

**Step 4 — Check AMA extension health on the source machine**
```powershell
# On the VM/Arc server itself
Get-Service -Name "AzureMonitorAgent" | Select-Object Status, StartType
Get-Content "C:\Resources\Directory\AMADataStore.Legacy\Tables\*" -ErrorAction SilentlyContinue -Tail 20
```
Or via Azure:
```
az vm extension show --resource-group <rg> --vm-name <vm> --name AzureMonitorWindowsAgent --query "instanceView.statuses"
```
Bad: Extension state = `Failed` or `Provisioning`.

**Step 5 — For API connectors, confirm source-side prerequisite**
Office 365: Unified Audit Log must be enabled at the tenant.
```powershell
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
```
Entra ID: Diagnostic settings must route `SignInLogs`/`AuditLogs` to the workspace explicitly — the "connector" in Sentinel is a thin UI wrapper around Entra diagnostic settings.
```
Entra admin center → Monitoring & health → Diagnostic settings → confirm workspace destination + categories checked
```

---

## Common Fix Paths

<details>
<summary>Fix 1 — Connector shows "Connected" but table has 0 rows</summary>

This is almost always a **permissions** or **DCR misassociation** problem, not a connectivity problem.

```powershell
# Re-check DCR association for the resource
Get-AzDataCollectionRuleAssociation -TargetResourceId "<resource-id>"

# If missing, re-associate (example: Windows Security Events via AMA)
New-AzDataCollectionRuleAssociation `
    -ResourceUri "<vm-resource-id>" `
    -AssociationName "SentinelDCR-Association" `
    -RuleId "<dcr-resource-id>"
```

For API-based connectors (Office 365, Entra), re-run the connector wizard — many silently lose consent when the original admin's token expires or role is downgraded:
```
Sentinel portal → Data connectors → <connector> → Open connector page → Disconnect → Reconnect
(requires Global Admin or Security Admin for re-consent)
```

**Rollback:** none needed — reconnecting is non-destructive and does not affect already-ingested data.
</details>

<details>
<summary>Fix 2 — Workspace-wide ingestion gap (all tables affected)</summary>

Check for a daily cap or quota block:
```powershell
Get-AzOperationalInsightsWorkspace -ResourceGroupName "<rg>" -Name "<workspace>" |
    Select-Object -ExpandProperty WorkspaceCapping
```
If `DailyQuotaGb` has been hit, ingestion silently stops until the UTC day rolls over.

```powershell
# Remove or raise the cap
Set-AzOperationalInsightsWorkspace -ResourceGroupName "<rg>" -Name "<workspace>" -DailyQuotaGb -1  # -1 = unlimited
```

Also check the workspace's own RBAC — a Conditional Access or PIM change can silently strip the Sentinel managed identity's **Monitoring Metrics Publisher** or **Log Analytics Contributor** role.

**Rollback:** raising/removing the cap is non-destructive; document the change since it affects billing.
</details>

<details>
<summary>Fix 3 — AMA extension unhealthy / not reporting</summary>

```powershell
# Restart the AMA service (Windows)
Restart-Service -Name "AzureMonitorAgent" -Force

# Or reinstall the extension entirely (most reliable fix)
Remove-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vm>" -Name "AzureMonitorWindowsAgent" -Force
Set-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vm>" -Name "AzureMonitorWindowsAgent" `
    -Publisher "Microsoft.Azure.Monitor" -ExtensionType "AzureMonitorWindowsAgent" `
    -TypeHandlerVersion "1.*" -Location "<region>"
```

For Arc-onboarded on-prem servers, also check the Arc agent itself:
```powershell
& "C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe" show
```
Bad: `Agent Status: Disconnected` → Arc connectivity issue takes priority over the AMA extension — fix Arc first.

**Rollback:** extension reinstall is safe; no data loss, brief ingestion gap only.
</details>

<details>
<summary>Fix 4 — Office 365 connector connected but OfficeActivity empty</summary>

```powershell
# Confirm UAL is enabled (source tenant)
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
# If False:
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true
```
Note: UAL can take up to 60 minutes to start populating after being enabled, and Sentinel's ingestion of it adds further latency (up to 24h in worst case for SharePoint/OneDrive activity types).

If UAL was already enabled, the connector's OAuth grant likely expired:
```
Sentinel portal → Data connectors → Office 365 → Open connector page → toggle Exchange/SharePoint/Teams off then back on
```

**Rollback:** none — toggling connector categories does not delete historical data.
</details>

<details>
<summary>Fix 5 — Connector health warning (permission revoked)</summary>

Most Azure-native connectors (Azure Activity, Key Vault, Defender for Cloud) rely on either the Sentinel workspace's managed identity or a resource's diagnostic settings — not a standing credential. A common MSP-tenant-transition issue: the account that originally set up the connector loses its role.

```powershell
# Check current role assignments on the resource for the Sentinel identity
Get-AzRoleAssignment -ObjectId "<sentinel-managed-identity-object-id>" -Scope "<resource-id>"
```
Re-grant **Reader** (minimum) or the connector-specific role documented on the connector's own instructions tab (roles differ per connector — check before assuming Reader is sufficient).

**Rollback:** none — this is additive permission repair only.
</details>

---

## Escalation Evidence

```
=== SENTINEL DATA CONNECTOR ESCALATION ===
Date/Time        :
Engineer         :
Ticket           :

Workspace Name   :
Connector        :
Affected Table(s):

Last Ingested Row Timestamp (KQL max(TimeGenerated)):
Gap Duration     :

Connector Portal Status (Connected/Warning/Disconnected):
DCR Association Present (Y/N)       :
AMA Extension State (VM/Arc)        :
Daily Quota / Cap Setting           :
Sentinel Identity Role on Resource  :

Steps Attempted:
1.
2.
3.

Expected behaviour : Data flowing into <table> within normal connector SLA
Actual behaviour   :
```

---

## 🎓 Learning Pointers

- **"Connected" in the portal ≠ data flowing.** Most Sentinel connector status indicators only confirm that the *authorization/wiring* succeeded, not that data is currently landing. Always validate with a direct KQL query against the table, not the portal badge. [MS Docs: Connect data sources](https://learn.microsoft.com/en-us/azure/sentinel/connect-data-sources)
- **AMA + Data Collection Rules replaced the legacy Log Analytics (MMA) agent** — if you're troubleshooting an older environment, confirm which agent is actually in play; MMA is being retired (August 2024 cutoff for new onboarding, full retirement later) and the diagnostics differ completely. [AMA migration guidance](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-migration)
- **Office 365 / UAL latency is a known SLA, not a bug** — SharePoint and OneDrive audit events can take up to 24 hours; Exchange and Teams are typically faster (minutes to ~30 min). Don't escalate UAL-based connectors until you've confirmed you're outside documented latency windows. [UAL search latency](https://learn.microsoft.com/en-us/purview/audit-log-search)
- **Daily ingestion caps fail silently** — a workspace cap being hit produces no alert by default; ingestion just stops until UTC midnight. Always check `WorkspaceCapping` early in any "everything stopped" incident.
- **DCR association is the #1 AMA gap in MSP multi-tenant builds** — creating a DCR does not automatically attach it to every VM/Arc server; each resource needs an explicit `DataCollectionRuleAssociation`. Script this as part of any onboarding runbook rather than doing it per-resource manually.
- **Community resource:** r/AzureSentinel and the [Microsoft Sentinel Tech Community blog](https://techcommunity.microsoft.com/category/azure-sentinel) regularly publish connector-specific known issues before they hit official docs.
