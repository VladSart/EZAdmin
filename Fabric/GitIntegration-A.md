# Microsoft Fabric — Git Integration — Reference Runbook (Mode A: Deep Dive)
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
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

This is the deep-dive companion to `GitIntegration-B.md`. It covers the **why** behind three mechanics that generate the most confusing tickets and the most fragile automation:

1. **The connection lifecycle and sync-direction state machine** — what actually happens on Connect/Initialize/Commit/Update, why sync is a strict one-direction-at-a-time operation, and how per-item Git status is computed.
2. **The Git integration REST API surface and its long-running-operation (LRO) pattern** — the exact call sequence needed to automate connect → initial sync → ongoing commit/update safely, including the `RequiredAction` decision point that trips up most first automation attempts.
3. **The tenant-setting delegation model and provider-specific limitation set** — why "Git integration is enabled" can still mean GitHub is blocked, why ADO and GitHub enforce different limits, and why Conditional Access / sovereign cloud / geography interact with this feature in non-obvious ways.

**Assumes:** commercial cloud Fabric tenant, Azure DevOps or GitHub.com as the Git provider (GitHub Enterprise Server has its own additional restrictions, noted separately). Read `GitIntegration-B.md` first for the fast-path triage table and fix recipes — this document explains the mechanics behind those fixes.

**Does not cover:** Deployment Pipelines (Fabric's separate promotion-between-stages ALM tool — related but architecturally distinct from Git integration; a candidate for its own future runbook), Fabric item authoring content itself (what's *inside* a Lakehouse/Notebook/Report), or Purview sensitivity-label enforcement mechanics (see `Security/Purview/DSPM-for-AI-A.md`) beyond the specific Git-export interaction noted below.

---

## How It Works

<details><summary>Full architecture — connection lifecycle, sync-direction mechanics, and per-item Git status</summary>

**Connecting is a workspace-admin-only, one-time act; working in a connected workspace is not.** Only a Workspace Admin can perform the initial `Connect`, `Disconnect`, or add/switch a branch (unless the workspace-level **"Allow users with at least Contributor role to change Git branch"** setting is enabled, which extends branch-switching — not connect/disconnect — to Member/Contributor with write access to all items). Once connected, any user with sufficient item-level permission can commit and update without further admin involvement.

**The initial sync direction is a one-time fork in the road, not a preference.** When a workspace first connects to a Git branch:
- If exactly one side (workspace or branch) has content and the other is empty, Fabric copies from the non-empty side automatically — no decision needed.
- If **both** sides have content, a human must choose a direction: **commit** (workspace content overwrites the Git branch) or **update** (Git branch content overwrites the workspace). Choosing update is a destructive, confirmed action for the workspace side, because a Git branch can always be reverted to a prior commit but a workspace has no equivalent undo once overwritten.
- Programmatically, this decision surfaces through the **Initialize Connection** API's `RequiredAction` field in its response: `None` (already in sync, no action needed) or `UpdateFromGit` (the workspace must be updated from the branch before anything else can happen). There's no `RequiredAction` value that means "commit" — a divergent-content scenario that needs a commit decision is presented as a conflict requiring resolution, not auto-resolved by the API.

**Sync is always exactly one direction at a time — this is enforced, not a UI limitation.** You cannot commit and update in a single operation. If the Git branch has changes not yet reflected in the workspace, **Commit is disabled** until you Update. If the same item changed on both sides since the last sync, **Update is disabled** until the conflict is resolved. This ordering prevents silently discarding either side's changes.

**Per-item Git status is a six-state model**, computed by diffing the item's current definition against the last-synced commit on both sides:
- **Synced** — identical in workspace and branch.
- **Conflict** — changed in both places since last sync; blocks Update.
- **Unsupported** — item type isn't Git-integration-compatible; ignored by sync operations entirely (not an error state, just excluded).
- **Uncommitted changes** — workspace differs from branch, workspace side is ahead.
- **Update required** — branch differs from workspace, branch side is ahead.
- **Needs update to last commit** (warning icon) — item is byte-identical in both places already, but the internal sync pointer wasn't advanced to the latest commit hash; a no-content-change technical sync is needed to clear it.

**Folder structure is mirrored bidirectionally, with one deliberate asymmetry.** Workspace folders map 1:1 to Git folders (and vice versa) up to **10 levels deep**. Empty folders are **not** copied workspace→Git (Git has no concept of an empty directory without a placeholder file, so Fabric doesn't create one). Conversely, empty folders **in Git are auto-deleted** by Fabric on sync. But empty folders **in the workspace are never auto-deleted**, even after every item inside has been moved out. This three-way asymmetry — no propagation of empty-workspace-folders to Git, auto-deletion of empty-Git-folders, no auto-deletion of empty-workspace-folders — is a frequent source of "why does my folder still exist / why did my folder disappear" confusion and is intentional, not a bug in either direction.

**Items are matched between workspace and Git by a stable logical ID (GUID), not by display name or path.** This is why renaming an item safely round-trips (the ID doesn't change) but why two items with genuinely different histories can collide if their logical IDs happen to match — most commonly when an item was duplicated through a path Fabric didn't expect (e.g., certain copy operations, or restoring from recycle bin after a Git-side re-creation already happened — see the dedicated note on this below). `InitializeGitConnection` explicitly validates for logical ID collisions and fails fast with the colliding item(s) named in the response rather than silently merging or overwriting.

**Recycle bin recovery and Git-side re-creation are two independent recovery mechanisms that use different identity rules — mixing them produces duplicates.** Git operations that recreate a deleted item (Undo, or Update from Git bringing back an item that still exists in the branch) assign the recreated item a **new** logical ID, because from Git's perspective this is a fresh item being materialized, not a restore. Recycle-bin restore, by contrast, preserves the **original** logical ID, because the platform's own trash mechanism tracks true identity. If both paths are used on the same deleted item — say, Update from Git recreates it because the branch still has it, and someone separately restores the same item from the recycle bin — the workspace now holds two items with different logical IDs representing what the user thinks of as "the same thing." Only the recycle-bin-restored copy has the item's actual **data**; Git recreation restores the item **definition** only. The fix is always to delete the Git-recreated (new-ID) duplicate and keep the recycle-bin original, once you've confirmed which one holds real data.

</details>

<details><summary>Full architecture — REST API surface, LRO polling, and the tenant-setting delegation model</summary>

**The Git integration REST API surface (all under `/v1/workspaces/{workspaceId}/git/*` unless noted) covers the full connect-to-sync lifecycle:**

| Operation | Method + path | Notes |
|-----------|---------------|-------|
| Connect | `POST .../git/connect` | Requires a `connectionId` (from a stored Git provider credentials connection) unless using Automatic/SSO for an interactive user against Azure DevOps |
| Disconnect | `POST .../git/disconnect` | No body required; leaves workspace content untouched |
| Get connection | `GET .../git/connection` | Returns current `gitProviderDetails` (org/project/repo/branch/directory) |
| Initialize connection | `POST .../git/initializeConnection` | Establishes the sync baseline; response `RequiredAction` (`None` / `UpdateFromGit`) tells the caller what to do next |
| Get status | `GET .../git/status` | Per-item diff — `workspaceChange`, `remoteChange`, `conflictType` |
| Commit to Git | `POST .../git/commitToGit` | Body can target `All` items or a specific `items` list (selective commit) |
| Update from Git | `POST .../git/updateFromGit` | Requires `remoteCommitHash` and `workspaceHead` from the Initialize Connection or Get Status response |
| Get my Git credentials | `GET .../git/myGitCredentials` | Per-user credential configuration for this workspace connection |
| Update my Git credentials | `PATCH .../git/myGitCredentials` | Requires a `connectionId` |
| List / create connections | `GET` / `POST /v1/connections` | Not workspace-scoped — tenant-level store of reusable Git provider credential connections |

**Commit and Update from Git are both long-running operations (LROs), not synchronous calls.** The initiating `POST` returns immediately with `202 Accepted` and two response headers: `x-ms-operation-id` and `Retry-After` (seconds). The correct automation pattern is: capture `x-ms-operation-id`, then poll `GET /v1/operations/{operationId}` at the `Retry-After` interval until `Status` leaves `NotStarted`/`Running` (terminal states are `Succeeded`, `Failed`). Treating the initiating `202` response as completion — a common first-automation mistake — will race the actual sync and report false success.

**A connection's credentials are established independently of the connect call itself**, via the `/v1/connections` resource, because the same stored credential connection can be reused across many workspace connect operations. Two credential shapes matter operationally:
- **Automatic (SSO)** — only valid for interactive **user principals** against **Azure DevOps**; Fabric delegates to the signed-in user's own Entra identity and ADO permissions at call time. Not usable for service principals, since it requires an interactive OAuth2 flow.
- **ConfiguredConnection** — a stored credential (`ServicePrincipal` for Azure DevOps, or a personal access token / OAuth `Key` credential for GitHub) referenced by `connectionId`. This is the **required** path for any service-principal-driven automation, and the only path GitHub supports at all (GitHub has no SSO/Automatic mode).

**The tenant-setting model has three independent switches, not one, and a three-level override chain.** The switches:
1. **"Users can synchronize workspace items with their Git repositories"** — the Azure DevOps path, **enabled by default**.
2. **"Users can sync workspace items with GitHub repositories"** — the GitHub path, **disabled by default**. A tenant can have (1) on and (2) off simultaneously, which is the single most common cause of "Git integration is enabled tenant-wide but my GitHub connect still fails" tickets.
3. **"Users can export items to Git repositories in other geographical locations"** — gates cross-geo export, **Azure DevOps only**; GitHub has no equivalent enforcement mechanism (Microsoft's docs are explicit that GitHub can't enforce this cross-geo validation at all, so it isn't gated for GitHub either way).

Each switch supports **Apply to** targeting (entire organization, specific security groups, or entire organization except specific groups) and **delegation**: by default only the tenant (Fabric) admin controls the switch, but delegation can be extended so a **capacity admin** overrides it for workspaces on their capacity, and independently a **workspace admin** overrides both tenant and capacity settings for their own workspace. The resulting precedence is **tenant → capacity → workspace**, each level only able to override if delegation was explicitly turned on at that level. A workspace behaving differently from what the tenant admin configured is very often an unnoticed workspace- or capacity-level delegated override, not a propagation delay.

**All three Git switches are themselves gated by the master Fabric admin switch.** If Fabric is disabled tenant-wide, Git integration still functions for workspaces containing **only** Power BI items (Power BI's own Git story predates and is independent of the Fabric admin switch) — but any Fabric-native item type in the mix requires Fabric to be enabled.

</details>

---

## Dependency Stack

```
Layer 6 — Automation / CI-CD tooling (optional, sits on top of the API surface)
    Azure DevOps pipelines | GitHub Actions | fabric-cicd (Python) | fabric-samples
    PowerShell scripts (GitIntegration-ConnectAndUpdateFromGit.ps1, -CommitAll.ps1,
    -CommitSelective.ps1, -StoreGitProviderCredentials.ps1)
        └── depends entirely on Layer 5 below; adds nothing new to the auth/permission
            model, just orchestrates the same calls a human would make in the portal

Layer 5 — Git integration REST API
    connect | disconnect | get connection | initializeConnection | get status |
    commitToGit | updateFromGit | myGitCredentials (get/update) | connections (list/create)
        └── Commit + Update are LROs: 202 + x-ms-operation-id + Retry-After,
            poll /v1/operations/{id} to terminal state
                └── Requires: Entra bearer token (user or service principal),
                    connectionId for any non-Automatic/SSO credential path

Layer 4 — Sync-direction state machine (per item, per workspace)
    Synced | Conflict | Unsupported | Uncommitted changes | Update required |
    Needs update to last commit
        └── One direction at a time — Commit and Update are mutually exclusive
            until the blocking condition (pending update / unresolved conflict)
            clears
                └── Logical ID (GUID) is the identity key for matching items
                    across workspace and Git — NOT display name or folder path

Layer 3 — Workspace + Git permission intersection (both required, independently)
    Fabric side: Admin (connect/disconnect/branch mgmt) > Member/Contributor with
    item-level READ-WRITE on ALL items (commit/update) > Viewer (nothing)
    Git side (ADO or GitHub): Read=Allow (baseline) + Contribute=Allow + branch
    policy allowing direct commit (for commit specifically)
        └── BOTH sides must independently permit the operation — a Fabric
            Contributor with no repo write access fails commit just as surely
            as an ADO repo Contributor with only Fabric Viewer role

Layer 2 — Tenant setting delegation chain (tenant → capacity → workspace)
    3 independent switches: ADO sync (default ON) | GitHub sync (default OFF) |
    cross-geo export (ADO only, default OFF)
        └── gated above by: master Fabric admin switch (OFF breaks all
            Fabric-item Git integration; Power BI-only workspaces still work)

Layer 1 — Authentication strength parity + workspace eligibility
    Fabric sign-in auth strength >= Git provider's required auth strength
    (e.g. Git-side MFA enforcement requires Fabric-side MFA too)
        └── Workspace must NOT be MyWorkspace, must NOT have a template app
            installed, must be under the 1,000-item cap, must have a capacity
            assigned
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| GitHub connect blocked tenant-wide even though "Git integration" reads as enabled | The ADO switch and the GitHub switch are independent; GitHub's is off by default | Admin portal → Tenant settings → confirm the GitHub-specific switch, not just the general one |
| Workspace admin insists a tenant setting is off, but users can still connect | A capacity or workspace admin has an active delegated override | Check capacity's "Delegated tenant settings" page and the workspace's own Git settings for an override |
| `InitializeConnection` returns `RequiredAction: UpdateFromGit` but automation proceeds straight to Commit | Automation didn't branch on `RequiredAction`; workspace and branch had divergent content requiring an explicit direction choice | Fix automation to call Update From Git first when `RequiredAction != None` |
| Automation reports "success" immediately after Commit/Update POST, but nothing actually changed | Treated the `202 Accepted` as completion instead of polling the LRO | Poll `GET /v1/operations/{operationId}` to a terminal `Status` before declaring success |
| Service principal fails to connect to Azure DevOps with an "SSO"/Automatic-style credential | Automatic/SSO credential mode requires an interactive user principal; SPs must use `ConfiguredConnection` | Recreate the connection with `credentialType: ServicePrincipal` and reference it explicitly |
| Two items with the same apparent content both claim the same logical ID, `InitializeGitConnection` fails | True logical ID collision — often from an unusual duplicate/copy path, or from the recycle-bin + Git-recreate duplication scenario | Read the error payload for the specific colliding item(s); rename or realign the logical ID per `logical-id-conflict-resolution` |
| Empty folder vanished from the Git repo after a sync, but the equivalent workspace folder is still there | Expected asymmetry — empty Git folders auto-delete, empty workspace folders never auto-delete | Not a bug; document as expected in the ticket |
| Commit fails with a size-limit error only intermittently, same client | Client alternates between service-principal and interactive-user automation paths, which have different size caps (25 MB vs 125 MB on ADO) | Confirm which credential path produced the failing commit before quoting a limit |
| Cross-region Git connect works for GitHub but fails for the same client's Azure DevOps org | Cross-geo export gate applies to ADO only; GitHub has no equivalent enforcement | Enable the ADO-specific cross-geo tenant setting; no GitHub-side setting exists to change |
| Conditional Access is configured correctly in Entra, but Azure DevOps Git integration still fails auth | **Enable IP Conditional Access policy validation** in Azure DevOps org settings is fundamentally incompatible with Fabric's ADO integration | Disable IP CAP validation for the ADO org, or accept that Fabric Git integration cannot be used with it enabled |
| Government/sovereign cloud tenant can't get Git integration working at all, no clear tenant-setting explanation | Sovereign clouds are not supported for Git integration, full stop — this is a platform limitation, not a misconfiguration | Confirm tenant cloud environment before spending further troubleshooting time |
| A workspace-identity-backed item updates fine in its original workspace but fails after a branch-out to a new workspace | Workspace-identity-backed items can only be updated back from Git in a workspace connected to the **same** identity | Confirm the new (branched) workspace shares the source workspace's identity before expecting Git updates to apply |
| Read access to an item was fine last month; user can no longer sync it via Git as of a recent date | Read-write-on-items enforcement for Git integration (effective **December 1, 2026**) — user has read-only access via a sensitivity label or protection policy | Confirm item permission level explicitly; this is a scheduled platform-wide tightening, not a regression |

---

## Validation Steps

**1 — Acquire a Fabric bearer token and confirm the credential path matches the automation's identity type**
```powershell
Connect-AzAccount
$secureToken = (Get-AzAccessToken -AsSecureString -ResourceUrl "https://api.fabric.microsoft.com").Token
$ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$fabricToken = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
$fabricHeaders = @{ 'Content-Type' = 'application/json'; 'Authorization' = "Bearer $fabricToken" }
```
Expected: token acquired for the identity the automation is meant to run as (user vs. service principal — confirm this matches which credential mode was configured on the connection).

**2 — List stored Git provider credential connections and confirm the right one exists**
```powershell
Invoke-RestMethod -Headers $fabricHeaders -Uri "https://api.fabric.microsoft.com/v1/connections" -Method GET |
    Select-Object -ExpandProperty value | Select-Object id, displayName, connectivityType, connectionDetails
```
Bad: the expected connection is missing, or its `connectionDetails.type` doesn't match the intended provider (`AzureDevOpsSourceControl` vs `GitHubSourceControl`).

**3 — Get the workspace's current Git connection state**
```powershell
$connUrl = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/git/connection"
Invoke-RestMethod -Headers $fabricHeaders -Uri $connUrl -Method GET
```
Good: returns populated `gitProviderDetails` (organization/project/repository/branch/directory). Bad: error or empty response — workspace isn't connected yet, or the connection was dropped.

**4 — Call Initialize Connection and branch explicitly on `RequiredAction`**
```powershell
$initUrl = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/git/initializeConnection"
$init = Invoke-RestMethod -Headers $fabricHeaders -Uri $initUrl -Method POST -Body "{}"
$init.RequiredAction
```
`None` — already synced, safe to proceed to Commit/Update as needed. `UpdateFromGit` — **do not attempt a Commit yet**; the workspace must be updated from Git first using `$init.RemoteCommitHash` and `$init.WorkspaceHead` in the Update From Git body.

**5 — Get status before any commit/update to see the exact per-item diff**
```powershell
$statusUrl = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/git/status"
$status = Invoke-RestMethod -Headers $fabricHeaders -Uri $statusUrl -Method GET
$status.changes | Select-Object itemMetadata, conflictType, workspaceChange, remoteChange
```
Bad: any row with `conflictType` populated — resolve the conflict before attempting Update; Commit will also be blocked until this clears if it affects the direction you need.

**6 — For any Commit or Update call, capture and poll the LRO correctly**
```powershell
$resp = Invoke-WebRequest -Headers $fabricHeaders -Uri $updateFromGitUrl -Method POST -Body $updateFromGitBody
$operationId = $resp.Headers['x-ms-operation-id']
$retryAfter = [int]$resp.Headers['Retry-After']
do {
    Start-Sleep -Seconds $retryAfter
    $op = Invoke-RestMethod -Headers $fabricHeaders -Uri "https://api.fabric.microsoft.com/v1/operations/$operationId" -Method GET
} while ($op.Status -in @('NotStarted','Running'))
$op.Status   # expect 'Succeeded'
```
Bad: script exits or reports success right after the initial `202` without ever checking `$op.Status`.

**7 — Confirm tenant-setting state and delegation for the specific provider in play**
Portal: **Admin portal → Tenant settings**, search "Git". Confirm the ADO switch, the GitHub switch, and (if cross-region) the cross-geo export switch independently — and check the affected workspace's/capacity's own Git-related settings for a delegated override before assuming the tenant-level value is authoritative.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Determine whether this is a connection problem, a sync-direction problem, or a permission problem**
Connection problems fail at `connect`/`get connection`. Sync-direction problems fail at `initializeConnection`/`commitToGit`/`updateFromGit` with the operation itself reachable but blocked or erroring. Permission problems typically return an authorization-style error rather than a sync-state error — distinguish carefully, since the fix paths don't overlap.

**Phase 2 — If connection-level: verify eligibility before touching credentials**
Confirm the workspace isn't MyWorkspace, doesn't have a template app, has a capacity, and is under the 1,000-item cap. These are hard platform blocks no credential or tenant-setting change can work around.

**Phase 3 — If sync-direction-level: read `RequiredAction` and `conflictType` before calling anything**
Never call Commit or Update speculatively. `initializeConnection`'s `RequiredAction` and `git/status`'s `conflictType` fields exist specifically so automation doesn't have to guess — use them as the branch conditions they're designed to be.

**Phase 4 — If permission-level: check both sides independently**
Fabric item-level read-write is necessary but not sufficient; Git-side (ADO/GitHub) repo permission is a fully separate check. A failure can originate from either side alone — don't assume fixing one resolves the other.

**Phase 5 — If provider-specific: confirm which provider and which credential mode**
ADO vs. GitHub have different default tenant-setting states, different size limits, and different unsupported-configuration lists (IP Conditional Access for ADO; GitHub Enterprise Server restrictions for GitHub). Service-principal vs. user-principal changes both the size limit and the required credential mode. Don't apply one provider's known limitation to the other.

**Phase 6 — If automation-specific: confirm LRO handling**
Most "automation intermittently reports success but nothing changed" tickets trace to not polling the operation to a terminal state, or to polling with a fixed interval shorter than the `Retry-After` value the API returned, causing premature/wasteful polling that can mask a still-`Running` op as ambiguous.

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Build a safe automated connect-and-sync flow (avoid the RequiredAction trap)</summary>

1. Acquire a token matching the intended credential mode (interactive SSO for a user-run script; a stored `ConfiguredConnection` with `ServicePrincipal`/`Key` credentials for unattended automation).
2. Call `connect` with the correct `gitProviderDetails` and, for anything other than interactive ADO SSO, an explicit `connectionId`.
3. Call `initializeConnection` and **branch on `RequiredAction`** — do not proceed to a Commit call under any circumstance if `RequiredAction` is `UpdateFromGit`; call `updateFromGit` first using the `RemoteCommitHash`/`WorkspaceHead` from the init response.
4. Only after confirming (via `git/status`) that no `conflictType` remains, proceed with `commitToGit` (selective, using a specific `items` list, if only some items should move — safer for repeatable pipelines than `All`).
5. Wrap every Commit/Update call in the LRO polling pattern from Validation Step 6 — never treat the `202` as completion.
6. Log the final `operationId` and terminal `Status` for every run — this is the evidence a future troubleshooting session needs to distinguish "automation ran and failed" from "automation never ran."

**Rollback:** Disconnect (`git/disconnect`) leaves workspace content untouched and only removes the sync pointer — safe to use if an automated flow needs to be paused for investigation without touching data.
</details>

<details>
<summary>Playbook 2 — Migrate a workspace's Git connection between providers (e.g. Azure DevOps → GitHub) or between organizations</summary>

1. Confirm the target provider's tenant switch is enabled for the affected users/groups first — this is the most common reason a well-executed migration still fails at the last step.
2. On the source side, ensure the workspace is fully synced (no `Uncommitted changes` or `Update required` items) before disconnecting — disconnecting doesn't lose workspace content, but starting a migration mid-sync makes the eventual reconciliation harder to reason about.
3. `git/disconnect` from the source provider/repo.
4. Create or confirm a stored connection (`POST /v1/connections`) for the **target** provider with the correct credential type — remember GitHub has no Automatic/SSO mode, so a `ConfiguredConnection` with a PAT/OAuth `Key` credential is required even for interactive-feeling workflows.
5. `git/connect` to the new target, then `initializeConnection` and handle `RequiredAction` exactly as in Playbook 1 — for a genuine provider migration, the workspace is almost always the side with authoritative content, so expect (and plan for) a **Commit** direction rather than Update.
6. Validate item-by-item via `git/status` post-migration — confirm all items report `Synced`, not just that the connect call succeeded.
7. If the workspace uses folders, confirm the new repo's folder structure matches or is empty — a structural mismatch produces the "uncommitted changes" folder-diff behavior on first sync (see `GitIntegration-B.md` Fix 6) even on an otherwise clean migration.

**Rollback:** Because workspace content is authoritative and untouched throughout, reconnecting to the original provider/repo (if still intact) restores the prior state — this playbook does not delete anything on either provider side unless a commit explicitly does so.
</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Git integration connection + sync-status evidence for a specific
    workspace, for escalation.
.DESCRIPTION
    Read-only. Calls the Git integration REST API (not the PowerBIMgmt module,
    which has no Git integration cmdlets) to pull connection details and
    per-item status. Requires an Entra bearer token for the Fabric service
    (interactive Connect-AzAccount, or a service principal already
    authenticated in the calling context).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$WorkspaceId,

    [string]$OutputPath = ".\FabricGitEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Connect-AzAccount -ErrorAction SilentlyContinue | Out-Null
$secureToken = (Get-AzAccessToken -AsSecureString -ResourceUrl "https://api.fabric.microsoft.com").Token
$ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$fabricToken = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
$headers = @{ 'Content-Type' = 'application/json'; 'Authorization' = "Bearer $fabricToken" }

$base = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/git"

Write-Host "Pulling Git connection details..." -ForegroundColor Cyan
$connection = Invoke-RestMethod -Headers $headers -Uri "$base/connection" -Method GET

Write-Host "Pulling Git status (per-item diff)..." -ForegroundColor Cyan
$status = Invoke-RestMethod -Headers $headers -Uri "$base/status" -Method GET

$report = foreach ($item in $status.changes) {
    [PSCustomObject]@{
        WorkspaceId    = $WorkspaceId
        GitProvider    = $connection.gitProviderDetails.gitProviderType
        Organization   = $connection.gitProviderDetails.organizationName
        Repository     = $connection.gitProviderDetails.repositoryName
        Branch         = $connection.gitProviderDetails.branchName
        ItemName       = $item.itemMetadata.displayName
        ItemType       = $item.itemMetadata.itemType
        WorkspaceChange = $item.workspaceChange
        RemoteChange    = $item.remoteChange
        ConflictType    = $item.conflictType
    }
}

$report | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Host "Evidence exported to $OutputPath" -ForegroundColor Green
Write-Host "Attach manually: exact error text from the failing operation, and the operationId/Status" -ForegroundColor Yellow
Write-Host "from the last Commit/Update attempt if this is an LRO-related escalation." -ForegroundColor Yellow
```

---

## Command Cheat Sheet

```powershell
# Acquire Fabric bearer token
Connect-AzAccount
$secureToken = (Get-AzAccessToken -AsSecureString -ResourceUrl "https://api.fabric.microsoft.com").Token
$ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$fabricToken = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
$fabricHeaders = @{ 'Content-Type' = 'application/json'; 'Authorization' = "Bearer $fabricToken" }

# List stored Git provider credential connections
Invoke-RestMethod -Headers $fabricHeaders -Uri "https://api.fabric.microsoft.com/v1/connections" -Method GET

# Get a workspace's Git connection
Invoke-RestMethod -Headers $fabricHeaders -Uri "https://api.fabric.microsoft.com/v1/workspaces/$wsId/git/connection" -Method GET

# Initialize connection (check RequiredAction before doing anything else)
Invoke-RestMethod -Headers $fabricHeaders -Uri "https://api.fabric.microsoft.com/v1/workspaces/$wsId/git/initializeConnection" -Method POST -Body "{}"

# Get per-item Git status
Invoke-RestMethod -Headers $fabricHeaders -Uri "https://api.fabric.microsoft.com/v1/workspaces/$wsId/git/status" -Method GET

# Commit all workspace changes to Git (returns 202 — poll the LRO)
Invoke-WebRequest -Headers $fabricHeaders -Uri "https://api.fabric.microsoft.com/v1/workspaces/$wsId/git/commitToGit" -Method POST -Body (@{mode="All"} | ConvertTo-Json)

# Update workspace from Git (needs remoteCommitHash + workspaceHead from init/status)
Invoke-WebRequest -Headers $fabricHeaders -Uri "https://api.fabric.microsoft.com/v1/workspaces/$wsId/git/updateFromGit" -Method POST -Body $updateFromGitBody

# Poll a long-running operation to completion
do {
    Start-Sleep -Seconds $retryAfter
    $op = Invoke-RestMethod -Headers $fabricHeaders -Uri "https://api.fabric.microsoft.com/v1/operations/$operationId" -Method GET
} while ($op.Status -in @('NotStarted','Running'))

# Disconnect a workspace from Git (non-destructive to content)
Invoke-RestMethod -Headers $fabricHeaders -Uri "https://api.fabric.microsoft.com/v1/workspaces/$wsId/git/disconnect" -Method POST
```

Portal-only (no cmdlet/API coverage, or coverage exists but portal is faster for humans):
- Admin portal → Tenant settings → Git integration switches (ADO sync, GitHub sync, cross-geo export) and their delegation configuration
- Capacity → Delegated tenant settings → Override tenant admin selection
- Source Control panel → Branches tab → Branch out to another workspace / Checkout new branch / Switch branch
- Source Control panel → Accounts tab → connected GitHub account details (GitHub-connected workspaces only)

---

## 🎓 Learning Pointers

- **`RequiredAction` and `conflictType` exist so automation never has to guess a sync direction — use them as hard branch conditions.** The single most common first-automation bug is calling Commit unconditionally without checking whether Initialize Connection actually returned `UpdateFromGit`. [Automate Git integration by using APIs](https://learn.microsoft.com/en-us/fabric/cicd/git-integration/git-automation)
- **Commit and Update are LROs returning `202` — the response headers (`x-ms-operation-id`, `Retry-After`) are not optional metadata, they're the only way to know the operation actually finished.** Scripts that skip polling report false success on every run, which is worse than an obvious failure. [Git — REST API reference](https://learn.microsoft.com/en-us/rest/api/fabric/core/git)
- **The Azure DevOps and GitHub tenant switches are fully independent, and GitHub's is off by default.** "Git integration is enabled" tenant-wide is not a complete answer to "why can't this GitHub connection work" — always confirm the specific provider's switch. [Git integration tenant settings](https://learn.microsoft.com/en-us/fabric/admin/git-integration-admin-settings)
- **Service principals cannot use the Automatic/SSO credential mode against Azure DevOps — it requires interactive OAuth2.** Any unattended automation must use a `ConfiguredConnection` with stored `ServicePrincipal` (ADO) or `Key`/PAT (GitHub) credentials, set up ahead of time. [Git integration with service principal](https://learn.microsoft.com/en-us/fabric/cicd/git-integration/git-integration-with-service-principal)
- **Recycle-bin restore and Git-driven re-creation preserve item identity differently — mixing them on the same deleted item creates duplicates with different logical IDs, and only the recycle-bin copy has real data.** This is an architectural consequence of how each recovery path establishes identity, not a bug to file upstream. [Git integration process — considerations and limitations](https://learn.microsoft.com/en-us/fabric/cicd/git-integration/git-integration-process#considerations-and-limitations)
- **Starting December 1, 2026, plain workspace-role access is no longer sufficient — Git integration will require read-write on the specific item, enforced against sensitivity labels and protection policies.** For MSP clients with heavy sensitivity-label usage in Fabric-connected workspaces, this is worth a proactive readiness check well before the date, not a reactive fix after users start losing sync access. [Information protection in Microsoft Fabric](https://learn.microsoft.com/en-us/fabric/governance/information-protection)
