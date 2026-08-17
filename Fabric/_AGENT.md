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
| `GitIntegration-B.md` | Hotfix runbook — Git connect greyed out, sync/commit/update failures, logical-ID conflicts, commit size/item-cap limits, disabled Commit/Update in the Source Control panel, folder-structure "uncommitted changes" after connect, recycle-bin-vs-Git-recreate duplicate items, cross-region ADO connect failures |
| `GitIntegration-A.md` | Deep dive — the full connect/initializeConnection/commitToGit/updateFromGit REST API surface and LRO polling pattern; the one-direction-at-a-time sync state machine and `RequiredAction` decision point; the 6-state per-item Git status model; the 3-switch tenant-setting delegation chain (tenant→capacity→workspace, ADO-default-on/GitHub-default-off/cross-geo-ADO-only); provider-specific limits (commit size by credential type, 1,000-item cap, logical ID collision architecture); service-principal credential setup; the Dec 1 2026 read-write-on-items enforcement change |
| `Scripts/Get-FabricCapacityHealth.ps1` | Audits F-SKU capacity assignment, workspace-to-capacity mapping, and flags workspaces with no capacity or capacities in a non-Active state |
| `Scripts/Get-FabricDomainAudit.ps1` | Audits domain/subdomain structure via the Fabric REST Admin API — domain-to-workspace mapping, workspaces with no domain assignment, domains missing a description; flags that admin/contributor lists and delegated-settings state require a manual portal check (not exposed by this API surface) |
| `Scripts/Get-FabricGitIntegrationStatus.ps1` | Audits Git connection state and per-item sync health (conflicts/uncommitted/pending-update counts) across all tenant workspaces, and flags workspaces approaching the 1,000-item cap; explicitly reports (not silently skips) workspaces the supplied token can't check Git status for, since the Git endpoints are workspace-scoped, not admin-scoped |
| `DeploymentPipelines-B.md` | Hotfix runbook — Fabric's separate stage-promotion ALM tool (complementary to, not the same as, Git integration): can't-assign-workspace name collisions, backward-deploy-disabled, breaking schema-change confirmation dialogs, autobind/dependency failures (same-workspace and cross-pipeline), deployment rules grayed out or not applying, legacy semantic model metadata deploy failures, orphaned pipelines (no admin), and REST automation gotchas (LRO polling, 429s, selective-deployment gaps) |
| `DeploymentPipelines-A.md` | Deep dive — pipeline structure and item pairing mechanics (identity survives renames, never auto-merges unpaired same-named items); the autobinding algorithm (same-workspace fail-whole-deploy behavior vs. cross-pipeline stage-index-and-equal-count matching); the 3 deployment rule types and their owner-only, next-deploy-only semantics; the two-tier permission model (pipeline Admin vs. workspace role, both required to deploy); the full Deploy Stage Content REST API and LRO/execution-plan pattern; and the Feb 12 2026 (already-enforced) legacy semantic model metadata retirement, with ASLC's exemption |
| `Scripts/Get-FabricDeploymentPipelineStatus.ps1` | Audits pipeline stage structure (flags unassigned stages), role assignments (flags orphaned pipelines with zero Admins), and the most recent deployment operation's outcome (surfaces the failing step's exact error) across every pipeline the supplied token can see; explicitly flags that pipeline visibility is participant-scoped, not tenant-admin-scoped — there is no equivalent to the workspace Admin API for this item type |
| `WorkspaceGovernance-B.md` | Hotfix runbook — tenant-wide workspace naming/lifecycle/creation-restriction governance (distinct from `Domains-B.md`'s grouping and `FabricAdmin-B.md`'s capacity/OneLake scope): the "Create workspaces" tenant setting (Everyone/specific security groups/Nobody), orphaned-workspace detection and recovery, departed-employee My-workspace handling (temporary access vs. restore-as-app-workspace), the confirmed absence of any platform naming-enforcement feature, deleted-workspace retention/restore/permanent-delete, and workspace-level Networking Communication Policy gotchas |
| `WorkspaceGovernance-A.md` | Deep dive — the full workspace creation/naming/lifecycle governance architecture: what's actually enforced on `displayName` (tenant-wide uniqueness, 256 chars, the reserved `Admin monitoring` name) vs. what isn't (no naming-pattern policy exists); the 5-state portal lifecycle model (Active/Orphaned/Deleted/Removing/Not found) vs. the REST Admin API's 2-state `WorkspaceState` enum that reports orphaned workspaces as "Active" (the orphan-detection blind spot); retention asymmetry (7-90 day configurable for collaborative workspaces vs. fixed 30 days for My workspaces); the full Admin + Core REST API surface for workspace governance (Get/List Workspaces, List Workspace Access Details, Grant/Remove Admin Temporary Access, Restore Workspace, Update Workspace, Update Workspace Role Assignment) with rate limits and error codes; and Networking Communication Policy's defaultAction-defaults-to-Allow-if-omitted write-side gotcha |
| `Scripts/Get-FabricWorkspaceGovernanceAudit.ps1` | Read-only audit combining the authoritative `Get-PowerBIWorkspace -Orphaned` PowerShell path with REST Admin API calls (naming-pattern audit via `List Workspaces`, a rate-limit-capped zero-Admin cross-check via `List Workspace Access Details`, and optional `-IncludeDeleted` retention-window enumeration); explicitly reports (not silently skips) sections that require a token it wasn't given, and caps REST cross-check volume to protect the 200 requests/hour limit on that endpoint |

**Not yet built:** none currently flagged — workspace governance at scale (this run's topic) was the last open candidate from runs 158/159's roadmap. See `_BUILD/MANIFEST.md`'s run 162 entry for the "for next run" pointer (a fresh cross-domain gap sweep, since Fabric itself is now considered complete relative to its originally scoped coverage).

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
- "Connect to Git is greyed out" → `GitIntegration-B.md` Fix 1 — check the specific provider's tenant switch (ADO on by default, GitHub off by default), MyWorkspace/template-app hard blocks, and Workspace Admin requirement
- "I'm a Contributor but commit/update fails" → `GitIntegration-B.md` Fix 2 — workspace role alone isn't enough, needs item-level read-write on every item plus separate Git-side repo permission
- "Connect fails with a logical ID / conflicting items error" → `GitIntegration-B.md` Fix 3 or `GitIntegration-A.md` How It Works — items are matched by logical ID (GUID), not name or path
- "Commit fails on a size or item-count limit" → `GitIntegration-B.md` Fix 4 — limits differ by provider AND by credential type (25MB ADO+SP / 125MB ADO+SSO / 50MB GitHub combined; 1,000-item workspace cap)
- "Commit or Update button is disabled in the Source Control panel" → `GitIntegration-B.md` Fix 5 — sync is one direction at a time by design, resolve the blocking side first
- "Duplicate items after using Undo/Update from Git and also restoring from recycle bin" → `GitIntegration-B.md` Fix 7 or `GitIntegration-A.md` How It Works — the two recovery paths assign different logical IDs to the same deleted item
- "Building automation that calls the Git integration REST API" → `GitIntegration-A.md` Remediation Playbook 1 — branch on `RequiredAction` before committing, and poll the LRO (`x-ms-operation-id`/`Retry-After`) rather than trusting the initial `202`
- "Service principal can't authenticate Git integration to Azure DevOps" → `GitIntegration-A.md` How It Works / Learning Pointers — Automatic/SSO credential mode is interactive-user-only; SPs need a `ConfiguredConnection`
- "Client asks if sensitivity-labeled items in Fabric will still sync to Git" → `GitIntegration-A.md` Symptom→Cause Map — flag the December 1, 2026 read-write-on-items enforcement change proactively
- "Can't assign a workspace to a pipeline stage, error names an item" → `DeploymentPipelines-B.md` Fix 1 — a same-type/same-name item already exists in an adjacent stage
- "Deploy to previous/earlier stage button is greyed out" → `DeploymentPipelines-B.md` Fix 2 — backward deploy only works into an empty target stage
- "Deployment popped up a 'continue the deployment' warning" → `DeploymentPipelines-B.md` Fix 3 — breaking schema change would destroy target data, confirm intent before continuing
- "Deploy fails citing a missing dependency, or an item silently didn't rebind" → `DeploymentPipelines-B.md` Fix 4 or `DeploymentPipelines-A.md` How It Works — same-workspace autobind needs the dependency present in target; cross-pipeline autobind needs matching stage INDEX and equal stage counts
- "Deployment rule is grayed out, or I set one and nothing happened" → `DeploymentPipelines-B.md` Fix 5 — requires item ownership, and only applies starting the NEXT deploy
- "Semantic model won't deploy, error mentions an unsupported/legacy format" → `DeploymentPipelines-B.md` Fix 6 — legacy metadata retired for deployment pipelines as of Feb 12, 2026 (already in effect); ASLC models are exempt
- "Nobody can unassign our workspace from its pipeline" → `DeploymentPipelines-B.md` Fix 7 — orphaned pipeline (no admin), needs tenant-admin reclaim via the Admin API
- "Building automation that calls the Deployment Pipelines REST API" → `DeploymentPipelines-A.md` Remediation Playbook 1 — poll the LRO to a terminal status, respect `Retry-After` on 429s, max 300 items per call
- "We want reports to always point at the Production semantic model, not whatever stage they're being tested in" → `DeploymentPipelines-A.md` Remediation Playbook 3 — 3 supported ways to deliberately avoid autobinding
- "Where's the setting to enforce our workspace naming convention?" → `WorkspaceGovernance-B.md` Fix 4 or `WorkspaceGovernance-A.md` How It Works — no such platform feature exists; enforcement is restricting the Create Workspaces tenant setting to a trained group plus periodic audit
- "This workspace shows Active via the API but the portal/everyone says it's orphaned" → `WorkspaceGovernance-A.md` How It Works / Symptom→Cause Map — the REST `state` field cannot detect orphaning; use `Get-PowerBIWorkspace -Orphaned` or a zero-Admin roster check instead
- "Nobody can manage this workspace anymore, but the reports still run fine" → `WorkspaceGovernance-B.md` Fix 2 — orphaned workspace (no Admin); content is unaffected, assign a new Admin via `Add-PowerBIWorkspaceUser`
- "An employee left, we need their My workspace" → `WorkspaceGovernance-B.md` Fix 3 — confirm Active (use temporary admin access) vs. Deleted (restore as app workspace, a one-way conversion) before picking a tool
- "We accidentally deleted a workspace" → `WorkspaceGovernance-B.md` Fix 5 — restore within the retention window (7-90 days configurable for collaborative, fixed 30 days for My workspace)
- "Who's allowed to create new workspaces in this tenant?" → `WorkspaceGovernance-B.md` Fix 1 — the Create Workspaces tenant setting (Everyone/specific security groups/Nobody), portal-only, no REST/PowerShell read
- "A workspace's outbound connections/Git/gateway access got blocked (or unexpectedly opened) after a policy change" → `WorkspaceGovernance-B.md` Fix 7 or `WorkspaceGovernance-A.md` Remediation Playbook 4 — Networking Communication Policy, and the defaultAction-defaults-to-Allow-if-omitted write gotcha
- "Building automation to sweep the tenant for orphaned or non-conforming workspaces" → `WorkspaceGovernance-A.md` Remediation Playbooks 1-2, or run `Scripts/Get-FabricWorkspaceGovernanceAudit.ps1` directly

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

# Fabric REST API — list deployment pipelines visible to the caller (no admin-scoped
# enumeration exists for this item type — see Get-FabricDeploymentPipelineStatus.ps1 header)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines" `
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

Separately gated, ORTHOGONAL to the access chain above (a workspace's pipeline membership
never grants or restricts who can see it — deploying needs pipeline role AND workspace role):
[Deployment Pipeline — stage-promotion ALM tool]
    └── Workspace assigned to exactly ONE pipeline stage (1:1, permanent stage count/names)
            └── Item pairing established (survives renames; unpaired same-name items never merge)
                    └── Deploy requires: pipeline Admin role AND >= Contributor on BOTH the
                        source AND target workspace — pipeline access alone grants nothing
                            └── Autobind resolves dependencies at deploy time (same-workspace:
                                fails whole deploy if missing; cross-pipeline: stage-INDEX +
                                equal-stage-count match only)
```

## Response format reminder

Always answer in 3 layers:
1. **Immediate** — what to check right now (capacity state first, always)
2. **Root cause** — why this happens (F-SKU model, tenant-setting gate, or throttling mechanics)
3. **Prevention** — capacity sizing, monitoring via the Fabric Capacity Metrics app, or tenant-setting review before it recurs
