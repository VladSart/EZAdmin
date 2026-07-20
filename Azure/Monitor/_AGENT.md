# Azure Monitor Agent / Log Analytics — Agent Instructions

## What's in this folder

Runbooks and scripts for the **Azure Monitor Agent (AMA)** telemetry pipeline — agent deployment and managed-identity authentication, **Data Collection Rules (DCRs)**, **Data Collection Endpoints (DCEs)**, and the **Log Analytics workspace** ingestion/table-plan layer underneath it. Applies to Azure VMs, Azure Arc-enabled servers, and VM scale sets. This is the telemetry pipeline underneath most of this repo's other Azure/Security monitoring topics — Sentinel, Defender for Cloud, and diagnostic-settings-based logging all ultimately land data here or in a workspace like it.

---

## Before responding, also check

- **Security/Sentinel** (`Security/Sentinel/DataConnectors-A.md`) — Sentinel data connectors *consume* data landed by this pipeline; connector-specific onboarding is documented there, not here
- **Security/Defender** (`Security/Defender/DefenderForCloud-A.md`) — Defender for Cloud's legacy MMA-based auto-provisioning is a separate, mostly-superseded path from AMA
- **Azure/KeyVault** and **Azure/Networking** (NSG topic) — these resources send data via Diagnostic Settings directly to a workspace, a different ingestion path than the agent/DCR model covered here
- **Azure/Arc** — non-Azure machines must have a healthy Arc Connected Machine agent before AMA can be installed as an extension on them

---

## Folder contents

| File | What it covers |
|------|----------------|
| `LogAnalytics-B.md` | Hotfix runbook — AMA extension install/health failures, missing DCR associations ("nothing shows up"), managed identity/IMDS auth failures, DCE private-link connectivity |
| `LogAnalytics-A.md` | Deep dive — full AMA/DCR/DCE architecture, managed identity authentication model, legacy MMA/OMS agent retirement (backend shut down 2 March 2026), table-plan cost trade-offs |
| `Scripts/Get-AzureMonitorAgentHealth.ps1` | Fleet-wide report: AMA extension status, DCR association coverage, managed identity presence, IMDS reachability |

---

## Common entry points

- **"We installed AMA and nothing shows up in the workspace"** → `LogAnalytics-B.md` Triage 1-2 — almost always zero DCR associations, which is a "healthy" extension state, not a fault
- **"Agent extension shows failed/unhealthy"** → `LogAnalytics-B.md` Common Fix Paths
- **"Machine hasn't sent data since [date around March 2026]"** → `LogAnalytics-A.md` — check for the retired legacy Log Analytics (MMA/OMS) agent; its backend was shut down 2 March 2026 and it cannot upload data at all anymore, under any circumstances
- **"Designing a monitoring pipeline for a new client"** → `LogAnalytics-A.md` full architecture section
- **"Collect fleet-wide AMA health for a ticket/report"** → `Scripts/Get-AzureMonitorAgentHealth.ps1`
- **"Data Collection Endpoint / Private Link connectivity issue"** → `LogAnalytics-A.md` Symptom → Cause Map — DCEs have a hard same-region requirement with their workspace

---

## Key diagnostic commands

```powershell
# Check AMA extension status on a VM
Get-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" |
    Where-Object { $_.ExtensionType -like "*AzureMonitor*Agent*" } |
    Select-Object Name, ProvisioningState, EnableAutomaticUpgrade

# Check managed identity is present (hard prerequisite for AMA/IMDS auth)
(Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>").Identity

# List Data Collection Rules and their associations
Get-AzDataCollectionRule -ResourceGroupName "<rg>"
Get-AzDataCollectionRuleAssociation -TargetResourceId "<vmResourceId>"

# Check workspace table plan (Analytics vs Basic vs Auxiliary) and retention
Get-AzOperationalInsightsWorkspace -ResourceGroupName "<rg>" -Name "<workspaceName>" |
    Select-Object Sku, RetentionInDays
```

---

## Key dependency chain

```
Azure Monitor Agent (VM extension)
    │
    └── Managed Identity (system- or user-assigned) via IMDS (169.254.169.254)
            │
            └── Azure Monitor Configuration Service (AMCS) — retrieves associated DCRs
                    │
                    └── Data Collection Rule (defines WHAT is collected — AMA has no config of its own)
                            │
                            └── Data Collection Endpoint (required for Private Link scenarios — same-region as workspace)
                                    │
                                    └── Log Analytics Workspace (Analytics / Basic / Auxiliary table plan)
```

---

## Response format reminder (always 3 layers)

1. **Immediate action** — confirm extension health and DCR association state (Mode B)
2. **Root cause** — managed identity/IMDS failure, missing DCR, legacy agent still in use, or DCE region mismatch (Mode A)
3. **Prevention** — fleet-wide DCR association audits, legacy agent migration tracking, table-plan cost review
