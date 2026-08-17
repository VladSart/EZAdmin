# Microsoft Fabric — Tenant/Capacity Administration — Agent Instructions

## What's in this folder

Runbooks for **Microsoft Fabric** from an IT admin/MSP perspective — tenant settings, capacity provisioning (F-SKUs), workspace-to-capacity assignment, and the admin-facing failure modes that generate tickets (paused/deleted capacity, throttling, workspaces with no capacity, Git integration setup, external sharing gates, OneLake workspace-role security model). This folder is deliberately **not** about data engineering inside Fabric (pipelines, notebooks, Lakehouse/Warehouse item authoring) — that's end-user/analyst territory outside L2/L3 MSP scope. Fabric absorbed Power BI Premium (P-SKUs retired in favor of F-SKUs), so Power BI capacity-administration tickets increasingly route here too.

## Before responding, also check

| Resource | Why |
|----------|-----|
| `M365/SharePoint-OneDrive/` | OneLake is a separate storage layer from SharePoint/OneDrive despite similar governance concepts (external sharing, tenant settings) — don't conflate the two |
| `Security/Purview/DSPM-for-AI-A.md` | Sensitivity labels and DLP can extend into Fabric items; Purview governs the data classification layer, not Fabric admin itself |
| `EntraID/Graph/GraphAPI-BatchOperations-A.md` | Fabric REST Admin API follows the same OAuth/Graph-adjacent auth patterns and throttling behavior documented there |
| `Azure/` | F-SKU capacities are provisioned as Azure resources — Azure RBAC/subscription issues blocking capacity creation are an Azure-layer problem, not a Fabric-portal one |
| `M365/Licensing/_AGENT.md` | Per-user Pro licensing still applies below F64 capacity — license assignment issues surface here, not in Fabric admin |

## Folder contents

| File | What it covers |
|------|---------------|
| `_AGENT.md` | This file — routing and orientation |
| `FabricAdmin-B.md` | Hotfix runbook — workspace has no capacity, capacity paused/deleted, throttling symptoms, tenant setting propagation, Git integration setup failures, external sharing/guest access gaps |
| `Scripts/Get-FabricCapacityHealth.ps1` | Audits F-SKU capacity assignment, workspace-to-capacity mapping, and flags workspaces with no capacity or capacities in a non-Active state |

**Not yet built (candidates for a future run):** `FabricAdmin-A.md` (deep dive — capacity architecture, CU-second throttling model, OneLake data-access-role internals), Git integration deep dive, domains/workspace governance at scale.

## Common entry points

- "Users can't run reports / refresh is failing tenant-wide" → `FabricAdmin-B.md` Triage — check capacity state (Active/Paused/Deleted) before anything else
- "Workspace was working, now everything is grey/disabled" → `FabricAdmin-B.md` Fix 1 — capacity paused or deleted
- "Reports are slow / queries queuing" → `FabricAdmin-B.md` Fix 2 — CU throttling, check the Fabric Capacity Metrics app
- "New workspace can't create Fabric items, only classic Power BI works" → `FabricAdmin-B.md` Fix 3 — no capacity assigned, falls back to Pro-tier behavior
- "Git integration won't connect / sync fails" → `FabricAdmin-B.md` Fix 4
- "External user can't be added to a workspace despite being invited" → `FabricAdmin-B.md` Fix 5 — tenant-level external sharing switch not enabled
- "We deleted a capacity by mistake, is the data gone?" → `FabricAdmin-B.md` Fix 1 — 7-day soft-delete recovery window, region-matched reassignment
- "Who can see what" / workspace role confusion → `FabricAdmin-B.md` Escalation Evidence section — Admin/Member/Contributor bypass OneLake granular security; only Viewer/external is meaningfully restricted

## Key diagnostic commands

```powershell
# Install the official Power BI/Fabric admin management module
Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser

# Connect as a Fabric/Power BI Administrator
Connect-PowerBIServiceAccount

# List all capacities visible to the admin
Get-PowerBICapacity -Scope Organization

# List workspaces and their assigned capacity
Get-PowerBIWorkspace -Scope Organization -Include All |
    Select-Object Name, Id, CapacityId, State

# Fabric REST Admin API — list workspaces (requires Fabric Administrator role + token)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET
```

## Key dependency chain

```
Azure subscription (F-SKU capacity is an Azure resource: Microsoft.Fabric/capacities)
    └── Capacity provisioned (F2–F2048) OR trial capacity (auto F4/F64) OR legacy P-SKU (migrating out)
            └── Capacity state: Active (required) — NOT Paused, NOT Deleted
                    └── Workspace explicitly assigned to that capacity
                            └── Fabric items (Lakehouse, Warehouse, Notebook, Data Pipeline, etc.)
                                    function; below F64, viewers still need Power BI Pro license
                                    ├── CU-second consumption tracked per capacity
                                    │       └── >100% for >10 min → progressive throttling
                                    │               (InteractiveDelay → InteractiveRejected →
                                    │                AllRejected → SurgeProtection)
                                    ├── OneLake data-access-role security — only meaningfully
                                    │       restricts Viewer/external; Admin/Member/Contributor
                                    │       bypass granular OneLake security entirely
                                    └── Tenant settings gate: external sharing, guest access,
                                            Git integration — set at admin.microsoft.com /
                                            Fabric admin portal, propagate tenant-wide (not
                                            instant)
```

## Response format reminder

Always answer in 3 layers:
1. **Immediate** — what to check right now (capacity state first, always)
2. **Root cause** — why this happens (F-SKU model, tenant-setting gate, or throttling mechanics)
3. **Prevention** — capacity sizing, monitoring via the Fabric Capacity Metrics app, or tenant-setting review before it recurs
