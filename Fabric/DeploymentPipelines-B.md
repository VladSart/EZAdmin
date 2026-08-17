# Microsoft Fabric — Deployment Pipelines — Hotfix Runbook (Mode B: Ops)
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

Deployment Pipelines tickets almost always trace back to one of four layers: **pairing/naming collision**, **permissions on both source and target workspaces**, **a dependency the target stage doesn't have**, or **a semantic model that can no longer deploy at all**. There's no dedicated PowerShell module for deployment pipelines (unlike `MicrosoftPowerBIMgmt` for capacities) — everything goes through the Fabric REST API.

```powershell
# 1 — Get a Fabric bearer token
Connect-AzAccount
$secureToken = (Get-AzAccessToken -AsSecureString -ResourceUrl "https://api.fabric.microsoft.com").Token
$ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$fabricToken = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
$fabricHeaders = @{ 'Content-Type' = 'application/json'; 'Authorization' = "Bearer $fabricToken" }

# 2 — List pipelines the caller can access, find the affected one
$pipelines = (Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines" -Method GET).value
$pipelines | Select-Object displayName, id

# 3 — List its stages (order matters — index, not display name, drives autobinding)
$pipelineId = "<deploymentPipelineId>"
$stages = (Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines/$pipelineId/stages" -Method GET).value
$stages | Select-Object displayName, id, order, isPublic, workspaceId

# 4 — List items in the target stage and their pre-deployment diff state
$targetStageId = "<targetStageId>"
Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines/$pipelineId/stages/$targetStageId/items" -Method GET |
    Select-Object -ExpandProperty value | Select-Object itemDisplayName, itemType, sourceItemId, targetItemId

# 5 — Check the caller's pipeline role and workspace roles on both stages
Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines/$pipelineId/roleAssignments" -Method GET
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| "Can't assign the workspace" error, names an item | Two items of the same type/name already exist in an adjacent stage — pairing can't disambiguate | Fix 1 |
| "Deploy to previous stage" button greyed out | Target (earlier) stage isn't empty — backward deploy only works into an empty stage | Fix 2 |
| Deploy fails with "continue the deployment" schema-change dialog | Source semantic model has a breaking schema change (e.g. column type change) that would destroy target data | Fix 3 |
| Deploy fails citing a missing dependency, or an item silently doesn't rebind | Autobind couldn't find the linked item in the target stage, or cross-pipeline stage counts/indexes don't line up | Fix 4 |
| Deployment rule is grayed out, or configured but had no visible effect | Not the item owner (rules require ownership), or rules were configured but the item hasn't been redeployed since | Fix 5 |
| Semantic model deploy fails citing an unsupported/legacy metadata format | Model still uses legacy (non-Enhanced) metadata — Fabric retired legacy-metadata deployment support Feb 12, 2026 | Fix 6 |
| Nobody can unassign or manage a pipeline; workspace stuck assigned to it | Pipeline has no admin (owner left, ownership never transferred) — an orphaned pipeline | Fix 7 |
| Automation script gets `200`/`202` but nothing changed, or hits `429` | Rate limiting, or a silent selective-deployment gap (dependency not included in the `items` list) | Fix 8 |

---

## Dependency Cascade

<details><summary>What must be true for a deployment to succeed</summary>

```
[Workspace resides on a Fabric capacity — required, no capacity = can't be assigned to a pipeline]
    └── [Workspace assigned to exactly one pipeline stage — a workspace can belong to only one
         pipeline at a time]
            └── [Item pairing established — at assignment time (existing content) or at first
                 clean deploy (new content); paired items share an identity across stages
                 regardless of later renames]
                    └── [Caller is Pipeline Admin AND >= Contributor on BOTH source and
                         target workspaces — pipeline access alone grants no content access]
                            └── [No item-type+name collision with an adjacent stage —
                                 required for the initial assignment to succeed]
                                    └── [Autobind resolves same-workspace dependencies at
                                         deploy time — fails the deploy if the dependency
                                         isn't present in the target stage]
                                    └── [Cross-pipeline autobind additionally requires: same
                                         STAGE INDEX (not display name) in both pipelines, AND
                                         both pipelines have the SAME total number of stages]
                                            └── [Deployment rules (data source / parameter /
                                                 default lakehouse), if configured, apply to
                                                 the copied content — but only take effect
                                                 starting the NEXT deploy after being set]
                                                    └── [Semantic model must use Enhanced
                                                         Metadata (v3) — legacy-metadata models
                                                         cannot deploy as of Feb 12, 2026]

Separately gated, tenant-wide, horizon item (not yet enforced at time of writing):
[Starting Dec 1, 2026 — deploying to a workspace containing sensitivity-labeled/protected
 items requires read-write on ALL items in that workspace, not just workspace role]
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the caller has both pipeline and workspace permissions**
Pipeline access and workspace access are managed **separately** — a Pipeline Admin with no workspace role can view and share the pipeline but cannot see content or deploy. Confirm the affected user is at least a **Contributor in both the source and target workspaces**, not just a pipeline participant.

**Step 2 — Pull the stage item diff before assuming a deploy will succeed**
```powershell
Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines/$pipelineId/stages/$targetStageId/items" -Method GET |
    Select-Object -ExpandProperty value
```
Good: items show as `New`, `Different`, or `NoDifference` with `sourceItemId`/`targetItemId` both populated for paired items. Bad: an item you expect to see paired appears twice, unpaired — a rename or an out-of-band copy broke pairing.

**Step 3 — Check the last deployment operation's execution plan for the exact failing item**
```powershell
$ops = (Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines/$pipelineId/operations" -Method GET).value
$lastOpId = $ops[0].id
Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines/$pipelineId/operations/$lastOpId" -Method GET |
    Select-Object -ExpandProperty executionPlan | Select-Object -ExpandProperty steps
```
Look at each step's `status` and `error` — this pinpoints exactly which item failed and why, rather than guessing from the portal's generic "deployment failed" banner.

**Step 4 — For a semantic model failure, confirm the metadata format**
Portal: open the semantic model's **More options** menu — if **Open Semantic Model** is greyed out with an "upgrade required" tooltip, it's still on legacy metadata and cannot deploy. This is not always fixed even after a successful re-publish; deployments can still succeed even if the greyed-out tooltip lingers cosmetically.

**Step 5 — For a cross-pipeline autobind failure, confirm stage index and count parity**
Cross-pipeline autobinding matches by **stage position** (1st, 2nd, 3rd...), not display name, and **requires both pipelines to have the same total number of stages**. A 3-stage pipeline can never cross-pipeline-autobind against a 5-stage one, regardless of naming.

---

## Common Fix Paths

<details>
<summary>Fix 1 — Can't assign workspace: item name/type collision</summary>

1. Read the exact error — it links directly to the conflicting item(s)
2. Rename the conflicting item in either the workspace you're assigning, or the adjacent stage it collides with, so type+name is unique across the stages involved
3. Retry the assignment

**Rollback:** renaming an item is non-destructive; revert the name afterward if it was only needed to unblock assignment and a permanent rename isn't desired.
</details>

<details>
<summary>Fix 2 — Backward deployment button disabled</summary>

1. Confirm the target (earlier) stage actually has content:
```powershell
Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/deploymentPipelines/$pipelineId/stages/$earlierStageId/items" -Method GET
```
2. Backward deployment **only works into an empty stage**, and **only supports full deployment** — selective deployment backward isn't supported
3. If the earlier stage has content you need to preserve, this isn't a bug to fix — restructure the workflow (fix forward in Dev, retest in Test, redeploy forward to Prod) rather than trying to force a backward deploy

**Rollback:** not applicable — this is a hard product limitation, not a state to undo.
</details>

<details>
<summary>Fix 3 — "Continue the deployment" schema-breaking-change dialog</summary>

1. Confirm whether the schema change was **intentional** (e.g. a column type was deliberately changed) — check with the content owner before proceeding
2. If intentional: click through **Continue the deployment**, understanding this **destroys the existing data** in the target semantic model — a full refresh is required immediately after
3. If unintentional: close the dialog without continuing, fix the source `.pbix`/semantic model, republish to the source stage, and redeploy
4. After a confirmed-intentional deploy: refresh the target semantic model right away — the target is left empty of data until you do

**Rollback:** there is no rollback for data lost by continuing through a breaking schema change — this is why confirming intent with the owner *before* clicking through matters more than any recovery step.
</details>

<details>
<summary>Fix 4 — Autobind / dependency link failure</summary>

**Same-workspace dependency missing in target stage:**
1. Use **Select related** on the item you're deploying — this auto-selects every item it depends on, avoiding a partial deploy that autobind can't resolve
2. Retry the deploy with the full dependency set included

**Cross-pipeline dependency not resolving:**
1. Confirm both pipelines have the **same total number of stages** — required for cross-pipeline autobind, no exceptions
2. Confirm the dependency lives in the **same-index** stage (1st/2nd/3rd position) in the other pipeline, not just a same-*named* stage — a "Test" stage in position 2 of one pipeline will not autobind against a "Test" stage in position 3 of another
3. If cross-pipeline autobind is actively unwanted (e.g. semantic-model pipeline vs. reporting pipeline that should stay pinned to Production), deliberately avoid connecting items in matching stages, use a parameter rule instead, or proxy through an unconnected semantic model — don't fight autobind after the fact, design around it

**Rollback:** none required — a failed autobind blocks the deploy, it doesn't leave a partial/broken state.
</details>

<details>
<summary>Fix 5 — Deployment rule grayed out or not taking effect</summary>

1. **Grayed out:** confirm you're the **owner** of the item — rule creation requires item ownership, not just workspace admin/member
2. **Grayed out with no rule types available:** the item genuinely has no data sources (data source rule) or no parameters (parameter rule) to configure a rule against
3. **Configured but "didn't work":** deployment rules only take effect on the **next** deploy after being set — check for a `Different` diff indicator on the item; if present, deploy that item from source to target once to apply the rule
4. If a previously-working rule suddenly breaks deployment: the source semantic model was likely republished with a removed/renamed parameter, or a changed data source — open **Configure rules**, find the flagged item, and fix or remove the broken rule

**Rollback:** removing a broken rule reverts to no rule (content deploys as-is); this is safe and doesn't affect already-deployed content.
</details>

<details>
<summary>Fix 6 — Semantic model deploy fails: legacy metadata format</summary>

1. Confirm the model is affected: workspace → item's **More options** → **Open Semantic Model** greyed out with an "upgrade required" tooltip confirms legacy (non-Enhanced) metadata
2. **Recommended fix — republish via Power BI Desktop:** download/open the model in the latest Power BI Desktop, save it (this triggers the Enhanced Metadata conversion), republish to the source stage, then redeploy
3. **Alternative — XMLA read/write (SSMS):** set `compatibilityLevel` to `1520` and add `"defaultPowerBIDataSourceVersion": "powerBI_V3"` to the model's `model` object directly
4. **Exception:** Analysis Services Live Connection (ASLC) semantic models cannot be upgraded (they rely on an external AS server) and remain supported as-is — don't attempt to force-upgrade these
5. Note: even after a successful conversion, the "Open Semantic Model" option may remain cosmetically greyed out — this doesn't mean the deploy will still fail; retry the deployment to confirm

**Rollback:** none needed — upgrading to Enhanced Metadata is additive and required going forward; there's no supported path back to legacy metadata.
</details>

<details>
<summary>Fix 7 — Orphaned pipeline (no admin)</summary>

1. Confirm via the affected workspace: if a workspace shows assigned to a pipeline but no one can unassign it or manage pipeline settings, the pipeline likely has no admin (previous owner left without transferring ownership)
2. A **Fabric/Power BI administrator** must reclaim it using the Admin API: [Pipelines - Update User As Admin](https://learn.microsoft.com/en-us/rest/api/power-bi/admin/pipelines-update-user-as-admin) to add a new admin, or delete the orphaned pipeline outright if it's no longer needed
3. Community PowerShell sample for this specific scenario: [`AddUserToWorkspacePipeline`](https://github.com/microsoft/PowerBI-Developer-Samples/blob/master/PowerShell%20Scripts/Admin-DeploymentPipelines-AddUserToWorkspacePipeline) — takes a workspace name and a UPN, finds the pipeline the workspace belongs to, and grants that user admin
4. Once an admin is restored, the stuck workspace can be unassigned normally if needed

**Rollback:** not applicable — restoring ownership is purely additive; it doesn't alter pipeline content or configuration.
</details>

<details>
<summary>Fix 8 — Automation gets 200/202 but nothing visibly changed, or hits 429</summary>

1. **429 Too Many Requests:** read the `Retry-After` header and back off exactly that long before retrying — don't hammer the endpoint on a fixed short interval
2. **202 with no visible change:** `Deploy Stage Content` is a [long-running operation](https://learn.microsoft.com/en-us/rest/api/fabric/articles/long-running-operation) — a `202` means the deploy was *accepted*, not completed. Poll `GET /v1/deploymentPipelines/{id}/operations/{operationId}` (from the `x-ms-operation-id` response header) until `status` is `Succeeded` or `Failed` before concluding anything
3. **Selective deployment silently skipped an item:** if the request's `items` array was populated, only those items deploy — a dependency you forgot to include won't autobind if it's genuinely missing from the target, and won't error until you check the execution plan; either omit `items` to deploy everything, or explicitly include all dependencies
4. **Max items exceeded:** a single `Deploy Stage Content` call supports a maximum of **300 items** — split larger deployments into multiple calls

**Rollback:** none required — these are read/diagnosis-first issues; no destructive action is taken until you've confirmed the actual operation status.
</details>

---

## Escalation Evidence

```
=== FABRIC DEPLOYMENT PIPELINES ESCALATION ===
Date/Time      :
Engineer       :
Ticket         :

Pipeline Name/ID     :
Source Stage (name, index, workspace) :
Target Stage (name, index, workspace) :

Caller's Pipeline Role  : (Admin required for all pipeline operations)
Caller's Workspace Role — Source :
Caller's Workspace Role — Target :

Affected Item(s)        : (name, type, sourceItemId, targetItemId if paired)
Deployment Operation ID : (from x-ms-operation-id / operations list)
Execution Plan Step Error : (paste relevant step from Get Deployment Pipeline Operation)

Semantic Model Metadata Version : (Enhanced / Legacy — check "Open Semantic Model" greyed-out state)
Deployment Rules Involved       : (item, rule type, owner, last-applied deploy)

Steps Attempted:
1.
2.
3.

Expected behaviour :
Actual behaviour   :
```

---

## 🎓 Learning Pointers

- **Item pairing, not naming, is what deployment pipelines actually track.** Paired items keep their identity even after a rename; unpaired items with matching names just create a duplicate. When a deploy behaves unexpectedly, check pairing state before assuming it's a naming problem. [Item pairing](https://learn.microsoft.com/en-us/fabric/cicd/deployment-pipelines/assign-pipeline#item-pairing)
- **"Deploy" is a long-running operation, not a synchronous call.** Both the portal and the REST API return acceptance (`202`), not completion — for automation, always poll the operation to a terminal status via `Get Deployment Pipeline Operation` rather than trusting the initial response. [Long-running operations in Fabric](https://learn.microsoft.com/en-us/rest/api/fabric/articles/long-running-operation)
- **Cross-pipeline autobinding matches by stage position, not stage name, and requires equal stage counts.** This trips up engineers who assume "same name = same stage" — verify index and total stage count on both pipelines before relying on it. [Autobinding across workspaces](https://learn.microsoft.com/en-us/fabric/cicd/deployment-pipelines/understand-the-deployment-process#autobinding-across-workspaces)
- **Deployment rules never apply retroactively — only on the next deploy after being set.** A `Different` indicator on the item is the signal that a configured rule is waiting to take effect; don't assume a rule "isn't working" without checking for that indicator first. [Create deployment rules](https://learn.microsoft.com/en-us/fabric/cicd/deployment-pipelines/create-rules)
- **Legacy (non-Enhanced) semantic model metadata can no longer deploy at all, as of February 12, 2026.** This is not an upcoming change to plan for — it's already enforced. Any client still hitting this needs the Power BI Desktop republish or XMLA compatibility-level fix, not a workaround. [Retirement of semantic model support for deployment pipelines](https://learn.microsoft.com/en-us/fabric/cicd/troubleshoot-cicd#retirement-of-semantic-model-support-for-deployment-pipelines)
- **An orphaned pipeline (no admin) permanently blocks its assigned workspace from being reassigned anywhere** until a tenant admin reclaims it via the Admin API — this is worth flagging proactively for any client with high engineer turnover, since it's invisible until someone needs to make a change.
