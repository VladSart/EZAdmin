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
| `FabricAdmin-A.md` | Deep dive — CU-second billing/bursting/smoothing mechanics, the four-stage throttling policy (overage protection → interactive delay → interactive rejection → background rejection), carryforward/burndown, compound throttling protection, capacity overage (preview, 3x billing), and the full OneLake data-access-role (RBAC) model — workspace-role bypass, default roles, permission inheritance, RLS/CLS union-vs-intersection evaluation, shortcut identity-passthrough nuances, propagation latencies |
| `Domains-B.md` | Hotfix runbook — Fabric domains (data-mesh governance grouping): domain vs. workspace-access disambiguation (domain assignment never grants visibility/access), domain admin/contributor/Fabric-admin role boundaries, the 3 workspace-assignment methods, the reassignment-override tenant-setting gate, default-domain auto-assignment scope, delegated settings (sensitivity label, certification) |
| `Domains-A.md` | Deep dive — data mesh architecture rationale (what Fabric domains implement vs. what a full data-mesh model implies); the full REST Admin API domain-management surface (Domain object model, Create/Update/Delete Domain incl. the required `preview=false` flag, the 3 workspace-assignment operations and their shared silent-override-gate behavior, Role Assignments Bulk Assign/Unassign incl. the Admin-vs-Contributor principal-type restriction); the audit schema (13 `OperationName` values, 2 with undocumented property schemas, and the bit-flag-shaped `Value` enums on access/contributor-scope changes) |
| `Scripts/Get-FabricCapacityHealth.ps1` | Audits F-SKU capacity assignment, workspace-to-capacity mapping, and flags workspaces with no capacity or capacities in a non-Active state |
| `Scripts/Get-FabricDomainAudit.ps1` | Audits domain/subdomain structure via the Fabric REST Admin API — domain-to-workspace mapping, workspaces with no domain assignment, domains missing a description; flags that admin/contributor lists and delegated-settings state require a manual portal check (not exposed by this API surface) |

**Not yet built (candidates for a future run):** Git integration deep dive (currently only covered at hotfix depth in `FabricAdmin-B.md` Fix 4), workspace governance at scale beyond domains (e.g. tenant-wide workspace-naming/lifecycle policy).

## Common entry points

- "Users can't run reports / refresh is failing tenant-wide" → `FabricAdmin-B.md` Triage — check capacity state (Active/Paused/Deleted) before anything else
- "Workspace was working, now everything is grey/disabled" → `FabricAdmin-B.md` Fix 1 — capacity paused or deleted
- "Reports are slow / queries queuing" → `FabricAdmin-B.md` Fix 2 — CU throttling, check the Fabric Capacity Metrics app
- "New workspace can't create Fabric items, only classic Power BI works" → `FabricAdmin-B.md` Fix 3 — no capacity assigned, falls back to Pro-tier behavior
- "Git integration won't connect / sync fails" → `FabricAdmin-B.md` Fix 4
- "External user can't be added to a workspace despite being invited" → `FabricAdmin-B.md` Fix 5 — tenant-level external sharing switch not enabled
- "We deleted a capacity by mistake, is the data gone?" → `FabricAdmin-B.md` Fix 1 — 7-day soft-delete recovery window, region-matched reassignment
- "Who can see what" / workspace role confusion → `FabricAdmin-B.md` Escalation Evidence section — Admin/Member/Contributor bypass OneLake granular security; only Viewer/external is meaningfully restricted
- "Why is the capacity showing 150% utilization but nobody's complaining" → `FabricAdmin-A.md` How It Works — smoothing/bursting explained, only a Throttling-chart event is user-visible impact
- "Why does this Viewer still see everything even though we set up OneLake security" → `FabricAdmin-A.md` Symptom→Cause Map — workspace-role Write access always overrides OneLake security Read restrictions for Admin/Member/Contributor
- "I removed someone from the security group, they can still see the data" → `FabricAdmin-A.md` Validation Step 6 — group-membership propagation can take up to ~2 hours across cached engines
- "I put a workspace in the Finance domain but the Finance team still can't see it" → `Domains-B.md` Fix 1 — domain assignment never grants access, that's a workspace-role/OneLake-security problem
- "I'm a domain contributor but can't assign a workspace to my domain" → `Domains-B.md` Fix 2 — must also independently hold Workspace Admin on that workspace
- "I moved a workspace to a new domain and it didn't take" → `Domains-B.md` Fix 3 — reassignment-override tenant setting is off by default
- "Our script assigns workspaces to a domain via the REST API and gets 200 OK, but nothing changed" → `Domains-A.md` How It Works / Symptom→Cause Map — the API silently obeys the same override tenant-setting gate as the portal, no error either way
- "Bulk-assigning a security group as a domain admin via the API fails" → `Domains-A.md` Symptom→Cause Map — `UnsupportedPrincipalTypeForDomainAdminAssignment`, Admin role has narrower principal-type support than Contributor
- "Who deleted/renamed this domain, or changed contributor scope?" → `Domains-A.md` Evidence Pack / Command Cheat Sheet — Purview audit search by `DataDomainObjectId`, parse the `Value` enums correctly (they're not sequential integers)
- "Building automation to bulk-create or bulk-assign domains" → `Domains-A.md` Remediation Playbooks 1–2 — rate limits (25/min domain CRUD, 10/min workspace assignment), `preview=false` requirement, LRO polling for capacity-based assignment

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

# Fabric REST Admin API — list domains (no dedicated cmdlet exists for domains)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains" `
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

Separately gated, ORTHOGONAL to the access chain above (never affects visibility/access):
[Domain — data-mesh governance/discovery grouping]
    └── Fabric admin creates domain → assigns domain admins
            └── Domain admin manages contributors/workspace-assignment/delegated settings
                    └── Domain contributor assigns workspaces THEY administer (must also be
                        Workspace Admin on that specific workspace — two independent checks)
                            └── Workspace gets domainId metadata — enables OneLake catalog
                                filter/discovery and delegated tenant-setting overrides ONLY
```

## Response format reminder

Always answer in 3 layers:
1. **Immediate** — what to check right now (capacity state first, always)
2. **Root cause** — why this happens (F-SKU model, tenant-setting gate, or throttling mechanics)
3. **Prevention** — capacity sizing, monitoring via the Fabric Capacity Metrics app, or tenant-setting review before it recurs
