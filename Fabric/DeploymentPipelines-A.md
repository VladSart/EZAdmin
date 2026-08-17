# Microsoft Fabric — Deployment Pipelines — Reference Runbook (Mode A: Deep Dive)
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

---

## Scope & Assumptions

This file covers **Fabric deployment pipelines** — the stage-promotion Application Lifecycle Management (ALM) tool (Development → Test → Production, or any 2–10 stage variant) — at engineering depth: item pairing mechanics, the autobinding algorithm (same-workspace and cross-pipeline), deployment rules, the REST API and its long-running-operation (LRO) pattern, and the permission model.

**Explicitly out of scope, covered elsewhere:**
- **Git integration** — a separate, complementary ALM tool for version control. See `GitIntegration-A.md`/`-B.md`. The two tools are commonly combined (Git for source control within a stage, deployment pipelines for promotion between stages) but have independent permission models, REST APIs, and failure modes.
- **Capacity/tenant-setting administration** — see `FabricAdmin-A.md`/`-B.md`.
- **Fabric domains** — an orthogonal governance/discovery grouping, unrelated to deployment. See `Domains-A.md`/`-B.md`.
- **Item-authoring concerns** (how to build a good semantic model, notebook, or report) — this is end-user/analyst territory, not admin/MSP scope.

**Assumptions:** the reader has Fabric/Power BI Administrator or equivalent delegated access for REST Admin API calls, and at least Contributor on the workspaces involved for pipeline-scoped calls. All REST examples target the Fabric API (`api.fabric.microsoft.com/v1`), which has superseded the legacy Power BI Admin Pipelines API for new automation — legacy `api.powerbi.com/v1.0/myorg/admin/pipelines` endpoints referenced in older community scripts still work but aren't the basis for anything new built here.

---

## How It Works

<details><summary>Full architecture</summary>

**Pipeline structure.** A deployment pipeline has **2 to 10 stages**, default 3 (Development/Test/Production). The **number of stages and their display names are permanent once the pipeline is created** — you cannot add, remove, or rename stages afterward. The **public/private status of a stage can be changed at any time**, independent of the stage-count/name lock. This asymmetry surprises engineers who expect all pipeline settings to be equally mutable — plan stage count and naming carefully at creation time, since it's the one structural decision that can't be walked back.

**Adding content to a stage — two distinct mechanisms.**
1. **Assign a workspace to an empty stage.** Metadata (not data) from every report/dashboard/semantic-model/other supported item in the source workspace is copied into a **newly created workspace** on the target stage's capacity. The deploying user becomes owner of the cloned semantic models and sole admin of the new workspace. If the deploying user lacks capacity-assignment permission, the workspace is still created but content isn't copied — it stays empty until a capacity admin grants access and a later deploy actually populates it.
2. **Deploy content from an already-assigned stage to an adjacent one.** This is the ongoing promotion mechanism — the actual day-to-day ALM operation. Deployment can go in either direction between adjacent stages, but backward deployment only works into an **empty** target stage and only supports **full** (not selective) deployment.

**Item pairing — the core identity mechanism.** Pairing associates an item in one stage with "the same" item in an adjacent stage, independent of display name. Pairing is established either when a workspace is assigned to a stage (existing content) or on a **clean deploy** of new, previously-unpaired content. Once paired, items **remain paired even if renamed** in either stage — pairing tracks an internal identity, not the name. Conversely, **items that are not paired never auto-merge**, even if they end up with an identical name, type, and folder in adjacent stages — a duplicate is created and paired to whichever stage it just came from. This is the single most consequential design fact in this file: assuming "same name = same item" produces unexpected duplicates, and assuming "renamed = disconnected" produces unexpected overwrites.

**Deployment mechanics.** On deploy, Fabric copies content from source to target stage and uses the pairing link to determine what to overwrite. Only the **content** of a paired item is overwritten — its **ID, URL, and permissions remain unchanged** in the target stage across every subsequent deploy. Item properties that aren't copied (URL, ID, permissions, workspace settings, app content/settings, personal bookmarks, and — for semantic models specifically — role assignments, refresh schedule, data source credentials, query-caching settings, endorsement settings) persist as they were in the target before deployment; they are never reset by a deploy. **Data is never copied** — only metadata — so a semantic model or dataflow requires a manual refresh in the target stage after deployment before it reflects current data. For small non-breaking schema changes, existing data is often retained without a refresh being strictly required; for breaking schema changes (e.g. a column type change) or a changed data-source connection, a full refresh is mandatory and Fabric will block the deploy with a confirmation dialog first (see Fix 3 in `DeploymentPipelines-B.md`).

**Autobinding.** When two items are connected (e.g. a report depends on a semantic model), deployment pipelines tries to preserve that connection through a deploy — this is autobinding, and it operates differently within one pipeline versus across two:
- **Same-workspace (within one pipeline):** if the item the deployed item depends on already exists (has been paired) in the target stage, the deployed item is automatically rebound to it. If the dependency does **not** exist in the target stage, the **entire deployment fails** — Fabric will not deploy an item into a broken-dependency state. The **Select related** button auto-includes every dependency of a selected item specifically to avoid this failure mode.
- **Cross-pipeline (two separate pipelines, connected items):** autobinding still applies, but matching is by **stage position** (1st stage, 2nd stage, etc.), not display name — a stage named "Test" in position 2 of pipeline A will not autobind against a stage named "Test" in position 3 of pipeline B. Cross-pipeline autobinding additionally **requires both pipelines to have the exact same total number of stages** — a 3-stage and a 5-stage pipeline can never cross-pipeline-autobind, full stop, regardless of any other configuration.
- **Avoiding autobinding deliberately:** three supported methods exist for when autobinding is unwanted (e.g. all reports should stay pinned to a Production semantic model regardless of pipeline stage): (1) simply don't connect the items in matching stages — pairing is preserved but the original cross-stage connection is kept; (2) define a **parameter rule** (semantic models/dataflows only, not supported for reports); (3) route through a **proxy semantic model or dataflow** that itself isn't part of any pipeline.
- **Parameters and autobinding:** when a connection is controlled by a parameter (including one that resolves to an item ID or workspace ID), autobinding is **suppressed** even after deployment — the item must be manually rebound by changing the parameter value, or via a parameter-type deployment rule (which must be of type `Text`).

**Deployment rules.** Three rule types exist, scoped to specific item types:

| Item | Data source rule | Parameter rule | Default lakehouse rule |
|------|:---:|:---:|:---:|
| Dataflow Gen1 | ✅ | ✅ | ❌ |
| Semantic model | ✅ | ✅ | ❌ |
| Paginated report | ✅ | ❌ | ❌ |
| Mirrored database | ✅ | ❌ | ❌ |
| Notebook | ❌ | ❌ | ✅ |

Rules are defined **in the target stage**, under the specific item, and require the caller to be the **item owner** — not merely workspace admin/member. Rules **never apply retroactively**: they take effect starting with the **next** deployment into that stage after being configured, never immediately, and the item shows a `Different` diff indicator in the interim as the signal that a deploy is pending to apply the rule. Rules are **deleted permanently** (unrestorable) if the item they're attached to is removed, and are **lost** if the workspace is unassigned and reassigned to the stage (reconfiguration required). Rules also cannot be created in the **Development** stage — only in stages content deploys *into*.

**Semantic model metadata format requirement.** As of **February 12, 2026** (already in effect — not an upcoming change), deployment pipelines retired support for semantic models still on legacy (non-Enhanced) metadata. Enhanced Metadata (also called "model v3") is required for both Git integration and deployment pipelines going forward. The sole exception is Analysis Services Live Connection (ASLC) models, which cannot be upgraded because they rely on an external AS server, and remain supported as-is.

**Permissions are two independent grants.** Pipeline-level access has exactly **one** permission tier — *Admin* — required for viewing, sharing, editing, and deleting the pipeline itself, but granting **zero** access to workspace content. Workspace-level roles (Viewer/Contributor/Member/Admin) determine actual content access and deploy capability **separately**. To deploy between two stages, a caller needs **both**: Pipeline Admin, **and** at least Contributor in **both** the source and target workspaces. Microsoft 365 groups are explicitly **not supported** as pipeline admins (unlike some other Fabric role assignments).

</details>

---

## Dependency Stack

```
[Capacity: Fabric F-SKU or Premium/PPU — workspace must reside on a capacity to join a pipeline]
    └── [Workspace assigned to exactly ONE deployment pipeline stage — enforced 1:1]
            └── [Pipeline structure: 2-10 stages, count+names PERMANENT after creation;
                 public/private status per stage is the one thing still mutable later]
                    └── [Item pairing established (at assignment OR at first clean deploy) —
                         tracks identity across renames; unpaired same-name items never merge]
                            └── [Permissions gate every deploy: Pipeline Admin role
                                 REQUIRED, plus >= Contributor on BOTH source AND target
                                 workspace — pipeline access alone grants zero content access]
                                    └── [Autobind resolves connected-item dependencies at
                                         deploy time]
                                        ├── same-workspace: dependency must be PAIRED and
                                        │     present in target stage, or the WHOLE deploy fails
                                        └── cross-pipeline: matches by STAGE INDEX not name;
                                              requires EQUAL stage count on both pipelines
                                    └── [Deployment rules (data source / parameter / default
                                         lakehouse), if present, apply to copied content —
                                         effective starting the NEXT deploy only, never
                                         retroactively; requires item OWNERSHIP to configure]
                                            └── [Semantic model metadata format gate: Enhanced
                                                 Metadata (v3) required since Feb 12, 2026 —
                                                 legacy models cannot deploy (ASLC exempted)]

Orthogonal, does NOT gate deployment mechanics above, but affects it downstream:
[Data is never copied by deployment — only metadata. Post-deploy refresh of the target
 semantic model/dataflow is required to see current data.]
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "Can't assign the workspace" naming an item | Type+name collision with an adjacent stage — pairing can't disambiguate two same-named items of the same type | List stage items in the adjacent stage, compare names/types |
| Deploy succeeds but a report/dashboard shows old content that never updates | Item isn't actually paired — was created independently in both stages, or a rename broke expectations, not the pairing link itself | List stage items, confirm `sourceItemId`/`targetItemId` are both populated for the item |
| Backward deploy button is disabled | Target (earlier) stage isn't empty — hard product limitation, not a permission gap | List items in the earlier stage |
| Deploy fails, "continue the deployment" dialog | Breaking schema change (e.g. column type) in source semantic model would destroy target data | Confirm with content owner whether the change was intentional |
| Deploy fails citing a missing dependency | Same-workspace autobind couldn't find the dependency in the target stage — it wasn't included in a selective deploy | Use **Select related**, or check the item's lineage view |
| Item silently fails to rebind across two pipelines | Cross-pipeline autobind requires matching stage INDEX and EQUAL total stage count — one or both don't match | Compare `order` field across both pipelines' stage lists |
| Deployment rule grayed out | Caller isn't the item owner, or the item genuinely has no data sources/parameters to rule against | Confirm ownership via workspace item list |
| Deployment rule "isn't working" | Rules apply starting the NEXT deploy only — never retroactively | Check for the `Different` diff indicator; deploy once to apply |
| Previously-working deployment rule suddenly breaks the deploy | Source semantic model republished with a removed/renamed parameter or changed data source, invalidating the rule | Open Configure rules, find the flagged item |
| Semantic model deploy fails citing unsupported/legacy format | Model still on legacy (non-Enhanced) metadata — retired for deployment pipelines Feb 12, 2026 | Check "Open Semantic Model" for the greyed-out "upgrade required" tooltip |
| Nobody can unassign a workspace from a pipeline | Orphaned pipeline — no admin, previous owner left without transferring ownership | Admin API: list pipeline role assignments, confirm zero admins |
| Automation script gets `200`/`202` but no visible change | `202` means LRO *accepted*, not completed — must poll to terminal status | `Get Deployment Pipeline Operation` on the returned operation ID |
| Automation script hits `429` repeatedly | Rate limiting — retry cadence too aggressive | Read and honor the `Retry-After` header exactly |
| First-ever deploy for a new stage fails | Caller lacks capacity-assignment permission on the target, or the tenant has disabled workspace creation | Confirm capacity admin has added the caller / their workspace |
| Paginated report deploy fails silently | Caller isn't at least workspace **member** in the source stage — a stricter requirement than other item types | Confirm workspace role, not just pipeline role |

---

## Validation Steps

**Step 1 — Acquire a Fabric bearer token and confirm the target pipeline is visible**
```powershell
Connect-AzAccount
$secureToken = (Get-AzAccessToken -AsSecureString -ResourceUrl "https://api.fabric.microsoft.com").Token
$ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$fabricToken = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
$fabricHeaders = @{ 'Content-Type' = 'application/json'; 'Authorization' = "Bearer $fabricToken" }

(Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines" -Method GET).value |
    Select-Object displayName, id
```
Good: the pipeline appears in the list. Bad: empty result — the caller isn't a pipeline participant at all; confirm they were added via **Add Deployment Pipeline Role Assignment**, not just given a workspace role.

**Step 2 — Confirm stage order and workspace assignment**
```powershell
(Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines/$pipelineId/stages" -Method GET).value |
    Select-Object displayName, id, order, isPublic, workspaceId
```
Good: every stage that should have content shows a populated `workspaceId`. Bad: `workspaceId` is null on a stage expected to have content — it was never assigned, or was unassigned and not reassigned.

**Step 3 — Confirm role assignments before assuming a permissions bug**
```powershell
(Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines/$pipelineId/roleAssignments" -Method GET).value |
    Select-Object principal, role
```
Cross-check this against the **separate** workspace-level role list for both the source and target workspace — remember pipeline role and workspace role are independent grants, and a deploy needs both.

**Step 4 — Pull the pre-deployment diff before deploying**
```powershell
(Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines/$pipelineId/stages/$targetStageId/items" -Method GET).value |
    Select-Object itemDisplayName, itemType, sourceItemId, targetItemId
```
Good: items you expect to be paired show both `sourceItemId` and `targetItemId`. Bad: an item shows only one of the two — it exists in only one stage and will be created fresh (not overwritten) on next deploy, which is often not what's expected.

**Step 5 — After deploying, poll the operation to a terminal state**
```powershell
$opId = "<x-ms-operation-id from the deploy response header>"
do {
    $op = Invoke-RestMethod -Headers $fabricHeaders `
        -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines/$pipelineId/operations/$opId" -Method GET
    Start-Sleep -Seconds 10
} while ($op.status -in @('NotStarted','Running'))
$op.status
$op.executionPlan.steps | Where-Object status -eq 'Failed'
```
Good: `status = Succeeded`, zero failed steps. Bad: `status = Failed` — inspect `executionPlan.steps` for the specific item and error that caused it, rather than treating the whole deploy as an opaque failure.

**Step 6 — For semantic-model-specific failures, confirm the metadata format**
Portal check (no reliable REST signal): item **More options → Open Semantic Model**. Greyed out with an "upgrade required" tooltip confirms legacy metadata. Note this tooltip can persist cosmetically even after a successful upgrade — don't treat it as authoritative proof the deploy will still fail; re-attempt the deploy to confirm.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Structural (before touching content)**
1. Confirm the workspace resides on a Fabric capacity (a non-capacity workspace can never be assigned to a pipeline)
2. Confirm 1:1 assignment — a workspace already assigned to another pipeline must be unassigned first
3. Confirm stage count/order is what's expected — remember these are permanent post-creation, so a "wrong" stage count means a new pipeline, not a fix

**Phase 2 — Permissions (before touching autobind/rules)**
4. Confirm Pipeline Admin role for the caller
5. Confirm >= Contributor workspace role on **both** source and target stages independently
6. For paginated reports specifically, confirm **workspace member** (stricter than Contributor for this one item type)

**Phase 3 — Pairing and content (the actual deploy)**
7. Pull the pre-deployment diff (`New`/`Different`/`NoDifference`) and confirm it matches expectations before deploying
8. For dependent items, decide autobind intent explicitly — either use **Select related** to include dependencies, or confirm a proxy/parameter-rule strategy is deliberately in place to avoid autobinding
9. Deploy, then poll the operation to a terminal state — never assume success from a `202`

**Phase 4 — Post-deploy validation**
10. Refresh the target semantic model/dataflow — data is never copied by deployment, only metadata
11. If a schema-breaking-change dialog was confirmed through, refresh immediately — the target is left empty until you do
12. Re-pull the stage item diff — it should now show `NoDifference` for everything just deployed

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Automating a full CI/CD promotion via the REST API</summary>

**Goal:** deploy content from one stage to the next as part of a scripted pipeline (e.g. an Azure DevOps release stage), reliably, with correct LRO handling.

```powershell
$deployBody = @{
    sourceStageId = $sourceStageId
    targetStageId = $targetStageId
    note          = "Automated promotion — build $env:BUILD_BUILDNUMBER"
    # Omit 'items' to deploy everything; populate it for selective deployment,
    # but then you own including every dependency yourself (autobind still
    # applies within what you selected, but a missing dependency outside the
    # selection is not silently pulled in for you).
} | ConvertTo-Json

$deployResponse = Invoke-WebRequest -Headers $fabricHeaders -Method POST `
    -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines/$pipelineId/deploy" `
    -Body $deployBody

if ($deployResponse.StatusCode -eq 202) {
    $opId = $deployResponse.Headers['x-ms-operation-id']
    do {
        Start-Sleep -Seconds ([int]($deployResponse.Headers['Retry-After'] ?? 15))
        $op = Invoke-RestMethod -Headers $fabricHeaders `
            -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines/$pipelineId/operations/$opId" -Method GET
    } while ($op.status -in @('NotStarted','Running'))

    if ($op.status -eq 'Failed') {
        $op.executionPlan.steps | Where-Object status -eq 'Failed' | Format-List
        throw "Deployment failed — see execution plan steps above."
    }
}
```
Key points: max **300 items** per `Deploy Stage Content` call — batch larger promotions into multiple calls; a `429` response includes a `Retry-After` header that must be honored rather than retried on a fixed interval; service principals are supported **only** if every item type involved supports service-principal auth (verify per item type before assuming a headless pipeline will work end-to-end).

**Rollback:** deployment overwrites paired items' content only — ID/URL/permissions are untouched, so a bad automated deploy can be corrected by re-deploying a known-good prior version from source control (if Git-integrated) or a backup export, not by any built-in pipeline "undo."
</details>

<details>
<summary>Playbook 2 — Recovering an orphaned pipeline</summary>

**Goal:** a pipeline has no admin (owner left without transferring ownership); the workspace stuck assigned to it can't be unassigned by anyone.

1. Confirm via `List Deployment Pipeline Role Assignments` that zero `Admin` roles are currently assigned
2. A **Fabric/Power BI tenant administrator** (not a regular pipeline participant — this genuinely requires admin escalation) calls the Admin API: [Pipelines - Update User As Admin](https://learn.microsoft.com/en-us/rest/api/power-bi/admin/pipelines-update-user-as-admin)
3. Alternative: the community [`AddUserToWorkspacePipeline`](https://github.com/microsoft/PowerBI-Developer-Samples/blob/master/PowerShell%20Scripts/Admin-DeploymentPipelines-AddUserToWorkspacePipeline) PowerShell script — takes a workspace name and target UPN, resolves the pipeline that workspace belongs to, and grants that user admin directly
4. Once an admin exists, normal pipeline management (including unassigning the stuck workspace) works again

**Rollback:** granting a new admin is purely additive — it doesn't touch pipeline content, stage assignments, or deployment history. No rollback needed.
</details>

<details>
<summary>Playbook 3 — Deliberately preventing unwanted autobinding</summary>

**Goal:** a client has one pipeline for organizational semantic models and a separate pipeline for reports; reports should always point at the **Production** semantic model regardless of which stage the report itself is being tested in.

Three supported approaches, in order of typical preference:
1. **Don't connect matching stages** — if the report in the Development stage of the reporting pipeline is instead connected to the semantic model in the **Production** stage of the modeling pipeline (a deliberate cross-stage, not same-stage, connection), that connection survives deployment unchanged, since same-position autobinding only fires between matching-index stages.
2. **Parameter rule** — for semantic models/dataflows only (not supported for reports); the rule must target a parameter of type `Text`.
3. **Proxy semantic model/dataflow** — introduce an intermediate item that itself isn't part of any pipeline, and connect reports to the proxy instead of directly to the pipeline-managed model.

Validate the choice by deploying a lower stage and confirming the report's lineage view still points at Production afterward — don't assume the configuration is correct without confirming through an actual deploy.

**Rollback:** each of the three methods is a connection-configuration choice, not a destructive operation — reverting means simply reconnecting the item normally (accepting autobind going forward).
</details>

<details>
<summary>Playbook 4 — Migrating a semantic model off legacy metadata ahead of a deployment</summary>

**Goal:** a semantic model still on legacy metadata is blocking a deployment (in effect since Feb 12, 2026), and needs to be brought current without losing partitions/data unnecessarily.

1. Confirm the model is genuinely affected (not ASLC, which is exempt and shouldn't be touched)
2. **Preferred path:** download or open the `.pbix` in the current Power BI Desktop, save it (Desktop performs the Enhanced Metadata conversion automatically on save for any model opened there), republish to the source stage
3. **No-Desktop-access path:** connect via the XMLA read-write endpoint (SSMS or equivalent tooling) and directly set `compatibilityLevel` to `1520` plus add `"defaultPowerBIDataSourceVersion": "powerBI_V3"` to the model's `model` object
4. Redeploy and confirm success — don't rely solely on the "Open Semantic Model" greyed-out indicator clearing, since it can lag cosmetically after a real, successful upgrade
5. Flag to the client that legacy queries for certain sources (SQL Server, Oracle, Teradata, SAP HANA especially) may not convert cleanly and can throw native-query-conversion errors requiring manual query fixes — budget time for this on any bulk legacy-model migration, don't assume it's mechanical for every model

**Rollback:** there is no supported path back to legacy metadata once upgraded — treat this as a one-way migration and communicate that clearly before starting, especially for any model with custom M queries that might need manual attention.
</details>

---

## Evidence Pack

Read-only script — audits pipeline structure, role assignments, and the last deployment operation's outcome for escalation without making any changes.

```powershell
<#
.SYNOPSIS    Fabric Deployment Pipelines evidence pack (read-only).
.DESCRIPTION Pulls pipeline stage structure, role assignments, current stage item
             pairing/diff state, and the most recent deployment operation's execution
             plan for a named pipeline. Makes zero writes. Requires Az.Accounts and
             a Fabric/Power BI-privileged sign-in.
.PARAMETER   PipelineId  The deployment pipeline's GUID.
.EXAMPLE     .\Get-FabricDeploymentPipelineEvidence.ps1 -PipelineId "a5ded933-..."
.NOTES       Read-only. Safe to run against production pipelines at any time.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PipelineId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Connect-AzAccount -ErrorAction SilentlyContinue | Out-Null
$secureToken = (Get-AzAccessToken -AsSecureString -ResourceUrl "https://api.fabric.microsoft.com").Token
$ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$fabricToken = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
$headers = @{ 'Content-Type' = 'application/json'; 'Authorization' = "Bearer $fabricToken" }
$base = "https://api.fabric.microsoft.com/v1/deploymentPipelines/$PipelineId"

Write-Host "[INFO] Pipeline metadata" -ForegroundColor Cyan
$pipeline = Invoke-RestMethod -Headers $headers -Uri $base -Method GET
$pipeline | Select-Object displayName, id, description | Format-List

Write-Host "[INFO] Stages (order drives autobinding — verify before cross-pipeline work)" -ForegroundColor Cyan
$stages = (Invoke-RestMethod -Headers $headers -Uri "$base/stages" -Method GET).value
$stages | Select-Object displayName, id, order, isPublic, workspaceId | Format-Table -AutoSize

Write-Host "[INFO] Role assignments (Admin required for all pipeline operations)" -ForegroundColor Cyan
$roles = (Invoke-RestMethod -Headers $headers -Uri "$base/roleAssignments" -Method GET).value
if (-not $roles) { Write-Host "[WARN] No role assignments returned — possible orphaned pipeline." -ForegroundColor Yellow }
$roles | Select-Object principal, role | Format-Table -AutoSize

Write-Host "[INFO] Stage item pairing/diff state" -ForegroundColor Cyan
foreach ($stage in $stages) {
    Write-Host "  Stage: $($stage.displayName) (order $($stage.order))" -ForegroundColor Gray
    try {
        $items = (Invoke-RestMethod -Headers $headers -Uri "$base/stages/$($stage.id)/items" -Method GET).value
        $items | Select-Object itemDisplayName, itemType, sourceItemId, targetItemId | Format-Table -AutoSize
    } catch {
        Write-Host "  [WARN] Could not read items for this stage: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host "[INFO] Most recent deployment operations (up to 20)" -ForegroundColor Cyan
$ops = (Invoke-RestMethod -Headers $headers -Uri "$base/operations" -Method GET).value
$ops | Select-Object id, status, executionStartTime, executionEndTime, sourceStageId, targetStageId |
    Format-Table -AutoSize

if ($ops) {
    $lastOp = Invoke-RestMethod -Headers $headers -Uri "$base/operations/$($ops[0].id)" -Method GET
    Write-Host "[INFO] Most recent operation execution plan" -ForegroundColor Cyan
    $lastOp.executionPlan.steps |
        Select-Object index, status, preDeploymentDiffState, description |
        Format-Table -AutoSize
    $failedSteps = $lastOp.executionPlan.steps | Where-Object status -eq 'Failed'
    if ($failedSteps) {
        Write-Host "[ERROR] Failed steps detected — full error detail:" -ForegroundColor Red
        $failedSteps | ForEach-Object { $_.error | Format-List }
    }
}

$evidence = [PSCustomObject]@{
    PipelineId       = $PipelineId
    PipelineName     = $pipeline.displayName
    StageCount       = $stages.Count
    RoleAssignments  = $roles.Count
    LastOperationId  = $ops[0].id
    LastOperationStatus = $ops[0].status
    Timestamp        = (Get-Date -Format "o")
}
$evidence | Export-Csv -Path ".\FabricDeploymentPipeline-Evidence-$PipelineId.csv" -NoTypeInformation
Write-Host "[OK] Evidence exported to .\FabricDeploymentPipeline-Evidence-$PipelineId.csv" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Purpose | Call |
|---------|------|
| List pipelines caller can access | `GET /v1/deploymentPipelines` |
| Get one pipeline's metadata | `GET /v1/deploymentPipelines/{id}` |
| Create a pipeline | `POST /v1/deploymentPipelines` |
| Delete a pipeline | `DELETE /v1/deploymentPipelines/{id}` |
| List stages (order = autobind index) | `GET /v1/deploymentPipelines/{id}/stages` |
| Get one stage | `GET /v1/deploymentPipelines/{id}/stages/{stageId}` |
| Update a stage (e.g. public/private) | `PATCH /v1/deploymentPipelines/{id}/stages/{stageId}` |
| Assign a workspace to a stage | `POST /v1/deploymentPipelines/{id}/stages/{stageId}/assignWorkspace` |
| Unassign a workspace from a stage | `POST /v1/deploymentPipelines/{id}/stages/{stageId}/unassignWorkspace` |
| List items in a stage (diff state) | `GET /v1/deploymentPipelines/{id}/stages/{stageId}/items` |
| Deploy content (LRO — 202 + operation ID) | `POST /v1/deploymentPipelines/{id}/deploy` |
| List recent deploy operations (up to 20) | `GET /v1/deploymentPipelines/{id}/operations` |
| Get one operation + execution plan | `GET /v1/deploymentPipelines/{id}/operations/{operationId}` |
| Poll a generic LRO by operation ID | `GET /v1/operations/{operationId}` |
| List pipeline role assignments | `GET /v1/deploymentPipelines/{id}/roleAssignments` |
| Add a pipeline role assignment (Admin only) | `POST /v1/deploymentPipelines/{id}/roleAssignments` |
| Delete a pipeline role assignment | `DELETE /v1/deploymentPipelines/{id}/roleAssignments/{principalId}` |
| Legacy Admin API — reclaim an orphaned pipeline | `POST /v1.0/myorg/admin/pipelines/{pipelineId}/users` (Power BI Admin API) |

---

## 🎓 Learning Pointers

- **Item pairing tracks identity, not name — the single most consequential fact in this file.** A renamed item stays paired; two independently-created same-named items never merge into one pair. Diagnose "why did this get duplicated" or "why didn't this rename carry through" from pairing state first, not naming. [Item pairing](https://learn.microsoft.com/en-us/fabric/cicd/deployment-pipelines/assign-pipeline#item-pairing)
- **Cross-pipeline autobinding is positional, not nominal, and requires equal stage counts.** Treat "same stage name across two pipelines" as coincidental, not meaningful — only matching `order` values (and an identical total stage count on both pipelines) make autobinding fire. [Autobinding across workspaces](https://learn.microsoft.com/en-us/fabric/cicd/deployment-pipelines/understand-the-deployment-process#autobinding-across-workspaces)
- **Deploy is always a long-running operation — build automation around polling, not the initial response code.** A `202` is acceptance, not success; only a polled terminal `status` (`Succeeded`/`Failed`) on the operation is authoritative, and the execution plan's per-step detail is where the real error lives. [Long-running operations in Fabric](https://learn.microsoft.com/en-us/rest/api/fabric/articles/long-running-operation)
- **Deployment rules require ownership and apply strictly forward, never retroactively.** A `Different` diff indicator after configuring a rule means "will apply on next deploy," not "already applied" — don't debug a rule as broken until confirming that distinction. [Create deployment rules](https://learn.microsoft.com/en-us/fabric/cicd/deployment-pipelines/create-rules)
- **Legacy semantic model metadata is a hard, already-enforced deployment blocker as of February 12, 2026** — not a future planning item. Any client still running legacy-metadata models against a deployment pipeline needs the Power BI Desktop republish or XMLA `compatibilityLevel` fix now, and ASLC models are the only sanctioned exception. [Retirement of semantic model support for deployment pipelines](https://learn.microsoft.com/en-us/fabric/cicd/troubleshoot-cicd#retirement-of-semantic-model-support-for-deployment-pipelines)
- **Pipeline permission and workspace permission are two independent grants that both gate every deploy.** A Pipeline Admin with no workspace role can view/share the pipeline but see nothing and deploy nothing — always check both role systems, not just one, when a "permission denied" ticket comes in. [Deployment pipelines permissions](https://learn.microsoft.com/en-us/fabric/cicd/deployment-pipelines/understand-the-deployment-process#permissions)
