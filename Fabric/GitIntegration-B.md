# Microsoft Fabric — Git Integration — Hotfix Runbook (Mode B: Ops)
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

Git integration tickets almost always trace back to one of four layers: **tenant switch**, **item-level permission**, **provider-side (ADO/GitHub) access**, or **a genuine sync conflict**. Confirm the tenant switch and the user's item permission before touching anything provider-side — those two account for most "can't connect / greyed out" tickets.

```powershell
# 1 — Confirm the workspace is even eligible (capacity assigned, not MyWorkspace, no template app)
Get-PowerBIWorkspace -Scope Organization -Include All |
    Where-Object Name -eq "<workspace name>" |
    Select-Object Name, Id, CapacityId, Type

# 2 — Git status via REST API (requires a Fabric bearer token — see Diagnosis Step 1)
$ws = (Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces" -Method GET).value |
    Where-Object DisplayName -eq "<workspace name>"
Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($ws.id)/git/connection" -Method GET

# 3 — Git item-level status (what's out of sync, in which direction)
Invoke-RestMethod -Headers $fabricHeaders `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($ws.id)/git/status" -Method GET

# 4 — Tenant settings for Git (portal, no single cmdlet covers all three switches)
# app.fabric.microsoft.com > gear icon > Admin portal > Tenant settings > search "Git"

# 5 — Confirm the connecting user's item-level permission (not just workspace role)
Get-PowerBIWorkspace -Scope Organization -Id $ws.id -Include All |
    Select-Object -ExpandProperty Users |
    Where-Object Identifier -eq "<connecting user UPN>"
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| "Connect to Git" is greyed out entirely | Relevant tenant switch (Git integration / GitHub sync) is disabled, or workspace has a template app installed | Fix 1 |
| Connect succeeds, sync fails with a generic error | Item-level read-write permission missing on the connecting account, or provider-side repo/branch access missing | Fix 2 |
| `InitializeGitConnection` / connect returns `GitProviderDetailsInvalid` or a logical-ID conflict message | Logical ID collision between workspace items and Git repo items | Fix 3 |
| Commit fails with a size/limit error | Commit exceeds the provider's size cap, or workspace/branch exceeds the 1,000-item cap | Fix 4 |
| Update from Git is disabled, or commit is disabled | Uncommitted changes on one side block the opposite action — must resolve direction first | Fix 5 |
| Folder structure looks wrong after connect (constant "uncommitted changes") | Workspace folder structure differs from Git folder structure — this always shows as a diff until committed | Fix 6 |
| Duplicate items appear after using Undo/Update from Git alongside recycle-bin restore | Git re-creates items with a new logical ID; recycle-bin restore preserves the original ID — two live copies now exist | Fix 7 |
| Cross-region connect fails only for Azure DevOps, not GitHub | Cross-geo export tenant setting not enabled (ADO-specific; GitHub has no such gate) | Fix 8 |

---

## Dependency Cascade

<details><summary>What must be true for a workspace to sync with Git</summary>

```
[Tenant admin: Fabric admin switch = ON]
    └── [Tenant setting: "Users can synchronize workspace items with their Git
         repositories" = ON  (Azure DevOps path)]
         [Tenant setting: "...with GitHub repositories" = ON  (GitHub path, disabled
         by default)]
            └── [Workspace is eligible: has a capacity assigned, is NOT MyWorkspace,
                 has NO template app installed, is under 1,000 items]
                    └── [Workspace Admin performs the initial Connect — only Admin
                         can connect/disconnect/add a branch]
                            └── [Connecting account has Git Read=Allow on the target
                                 repo/branch (ADO or GitHub side, not Fabric side)]
                                    └── [Fabric authentication strength >= Git's
                                         required strength — e.g. if Git repo enforces
                                         MFA, Fabric sign-in must also satisfy MFA]
                                            └── [Initial sync direction resolved:
                                                 commit workspace→Git, OR update
                                                 Git→workspace — cannot do both at once]
                                                    └── [Ongoing work: any user with
                                                         item-level READ-WRITE on all
                                                         items can commit/update —
                                                         workspace role alone (Member/
                                                         Contributor) is not sufficient
                                                         if item permissions were
                                                         customized]

Separately gated, cross-geo (Azure DevOps only, not GitHub):
[Workspace capacity region != Azure DevOps repo region]
    └── Tenant setting "Users can export items to Git repositories in other
        geographical locations" must be ON, or the export is blocked
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Get a Fabric bearer token and confirm you can query the workspace**
```powershell
Connect-AzAccount
$secureToken = (Get-AzAccessToken -AsSecureString -ResourceUrl "https://api.fabric.microsoft.com").Token
$ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$fabricToken = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
$fabricHeaders = @{ 'Content-Type' = 'application/json'; 'Authorization' = "Bearer $fabricToken" }
```
Expected: token acquired without error. Bad: auth failure — check the account has at least Fabric Contributor/Viewer somewhere and MFA is satisfied.

**Step 2 — Confirm workspace eligibility**
```powershell
Get-PowerBIWorkspace -Scope Organization -Include All |
    Where-Object Name -eq "<workspace name>" | Select-Object Name, Id, CapacityId, Type
```
Bad: `Type = PersonalGroup` (this is MyWorkspace — cannot connect to Git, full stop). Bad: `CapacityId` empty — no capacity, connect will fail regardless of Git settings.

**Step 3 — Pull current Git connection state**
```powershell
$connUrl = "https://api.fabric.microsoft.com/v1/workspaces/$($ws.id)/git/connection"
Invoke-RestMethod -Headers $fabricHeaders -Uri $connUrl -Method GET
```
Good: returns `gitProviderDetails` with organization/project/repo/branch populated and no error. Bad: 404/empty — workspace was never connected, or was disconnected; a `NotConnectedToGit` style error confirms this is a fresh connect, not a broken one.

**Step 4 — Pull Git status to see which direction is out of sync**
```powershell
$statusUrl = "https://api.fabric.microsoft.com/v1/workspaces/$($ws.id)/git/status"
$status = Invoke-RestMethod -Headers $fabricHeaders -Uri $statusUrl -Method GET
$status.changes | Select-Object itemMetadata, conflictType, workspaceChange, remoteChange
```
Look for `conflictType` populated on any item — that item was changed in *both* the workspace and the Git branch since the last sync, and blocks Update until resolved. Empty `changes` array with a report of "still broken" points away from a sync-state problem and toward a permissions/tenant-setting problem.

**Step 5 — Confirm tenant switches**
Portal: **app.fabric.microsoft.com → gear → Admin portal → Tenant settings**, search "Git". Confirm the ADO switch (**enabled by default**) and, separately, the GitHub switch (**disabled by default** — must be explicitly turned on if the client uses GitHub). Check whether either has been delegated to capacity/workspace admin — a workspace admin override can silently contradict what the tenant admin thinks is set.

**Step 6 — Confirm item-level permission on the connecting account, not just workspace role**
Workspace Admin/Member/Contributor is necessary but not always sufficient — if item-level permissions were customized, the connecting account needs explicit **read-write on every item** in the workspace to commit or update. This is the single most common cause of "I'm the workspace Contributor but commit fails" tickets.

---

## Common Fix Paths

<details>
<summary>Fix 1 — Connect option greyed out entirely</summary>

```powershell
# Confirm workspace isn't MyWorkspace and doesn't have a template app
Get-PowerBIWorkspace -Scope Organization -Include All |
    Where-Object Name -eq "<workspace name>" | Select-Object Name, Type
```
1. Portal → Admin portal → Tenant settings → confirm the correct switch is ON for this user's security group (ADO switch is enabled tenant-wide by default; GitHub switch is off by default and must be explicitly enabled)
2. Confirm the workspace is not **MyWorkspace** (`Type = PersonalGroup`) — these can never connect to Git, this is a hard product limitation, not a misconfiguration
3. Confirm the workspace does not have a **template app** installed — also a hard block
4. Confirm the requesting user is **Workspace Admin** — only Admin can perform the initial connect, disconnect, or add a branch

**Rollback:** not applicable — this is enablement, not a destructive change.
</details>

<details>
<summary>Fix 2 — Connect succeeds but sync/commit/update fails</summary>

```powershell
# Check the connecting account's effective item permission
Get-PowerBIWorkspace -Scope Organization -Id $ws.id -Include All |
    Select-Object -ExpandProperty Users | Where-Object Identifier -eq "<UPN>"
```
1. Confirm **read-write on all items**, not just workspace role — workspace Contributor with restricted item-level ACLs will fail commit/update even though the portal doesn't always make this obvious
2. Confirm Git-side permission independently: for Azure DevOps, `Read=Allow` at minimum, `Contribute=Allow` plus a branch policy allowing direct commit for committing; for GitHub, equivalent repo write access
3. Confirm Fabric's authentication strength is not weaker than Git's — if the ADO/GitHub org enforces MFA or Conditional Access, the Fabric sign-in session must satisfy the same policy or the sync silently fails
4. If using a service principal, confirm it was set up per [Git integration with service principal](https://learn.microsoft.com/en-us/fabric/cicd/git-integration/git-integration-with-service-principal) — user-principal-style ADO connections are not supported for service principals

**Rollback:** none needed — this is a permission gap, not a state change to undo.
</details>

<details>
<summary>Fix 3 — Logical ID conflict on connect / InitializeConnection</summary>

1. Read the exact error payload — it names the conflicting item(s) and their logical IDs
2. Two resolution paths:
   - **Rename** the conflicting item in the workspace so its logical ID no longer collides, then retry connect
   - **Change the logical ID in the remote Git repo** to match the workspace's copy, if the workspace version is authoritative
3. If this surfaces during **Update from Git** (not initial connect) as a duplicate-logical-ID dialog: if you have write permission on the repo, use **Fix with direct commit** — Fabric auto-creates a new branch, you change the logical ID of the copied item on that branch, then commit and merge normally
4. Full detail: [Resolve logical ID conflicts in Microsoft Fabric](https://learn.microsoft.com/en-us/fabric/cicd/git-integration/logical-id-conflict-resolution)

**Rollback:** renaming an item or changing a logical ID in Git is not destructive to data — only to the identifier used for sync matching. No rollback needed beyond reverting the rename if it was cosmetic-only.
</details>

<details>
<summary>Fix 4 — Commit fails on size/item-count limit</summary>

1. Confirm which limit was hit:
   - **Azure DevOps + Service Principal:** 25 MB per commit
   - **Azure DevOps + user principal (default SSO):** 125 MB per commit
   - **GitHub:** 50 MB combined size per commit — split into multiple commits if several items are queued at once
   - **Workspace/branch item cap:** 1,000 Fabric + Power BI items total — if the Git branch already has 1,000+ items, syncing to the workspace fails outright
2. For an oversized single commit: split into multiple smaller commits via **Selective Commit** in the Source Control panel (or the `Git - Commit To Git` API with a specific `items` list) rather than **Commit All**
3. For the 1,000-item cap: this needs a structural fix, not a one-off — split the workspace into smaller sets, each linked to its own Git branch, or reorganize a single branch into folders (folders don't raise the cap, but make the eventual split easier)
4. If a single item's own files exceed the individual file cap (25 MB per file, 250-char path limit), that item needs restructuring — this is not fixable by batching commits differently

**Rollback:** none required — no partial commit is applied when the size check fails; nothing to undo.
</details>

<details>
<summary>Fix 5 — Update or Commit is disabled in the Source Control panel</summary>

1. **Commit disabled:** there are pending **Updates** (Git branch has changes not yet in the workspace) — you must Update first before Fabric will let you Commit; this is enforced to prevent overwriting unseen upstream changes
2. **Update disabled:** the same item was changed in *both* the workspace and Git since last sync — a **conflict** exists and must be resolved (see [conflict resolution](https://learn.microsoft.com/en-us/fabric/cicd/git-integration/conflict-resolution)) before Update re-enables
3. Remember: sync is **one direction at a time** — you cannot commit and update in the same operation, this is by design, not a bug
4. If truly stuck, use **Checkout new branch** (workspace admin only) to snapshot the current workspace state into a fresh branch, sidestepping the conflict, then reconcile via a normal PR/merge process afterward

**Rollback:** Checkout new branch does not modify workspace content — safe to use as an escape hatch.
</details>

<details>
<summary>Fix 6 — Persistent "uncommitted changes" after connecting a workspace with folders</summary>

1. This is expected, not a bug, the first time a workspace with folders connects to a Git branch that doesn't already mirror that folder structure — Fabric treats differing folder structure as a diff
2. Commit the folder structure to Git once to clear it: **Source Control panel → Commit** the pending folder changes
3. If direct commits to the connected branch are blocked by branch policy, use **Checkout new branch → commit the folder changes there → merge via normal PR process** instead of fighting the direct-commit restriction
4. Going forward: empty folders in the workspace are **not** auto-deleted even after all items move out, but empty folders in Git **are** auto-deleted — don't be surprised by asymmetric folder-cleanup behavior between the two sides

**Rollback:** not applicable — committing folder structure is additive metadata, not destructive.
</details>

<details>
<summary>Fix 7 — Duplicate items after Git operation + recycle bin restore</summary>

1. Root cause: **Undo**/**Update from Git** re-creates a deleted item with a **new** logical ID; restoring the same item from the **recycle bin** preserves the **original** logical ID — if both paths were used on the same deleted item, two live copies now exist with different identities
2. Fix: delete the item that was **re-created by the Git operation** (the newer-ID copy), keeping the recycle-bin-restored original (which retains its data — Git-recreated items only restore the item *definition*, not data)
3. After removing the duplicate, Git operations on that item should resume normally
4. Prevention: don't mix recycle-bin restore and Git Undo/Update as competing recovery methods for the same deleted item — pick one path and confirm it before trying the other

**Rollback:** deleting the Git-recreated duplicate is the fix itself; no further rollback needed once confirmed which copy has the real data.
</details>

<details>
<summary>Fix 8 — Cross-region connect fails for Azure DevOps only</summary>

1. Confirm the workspace's capacity region and the Azure DevOps organization/repo region — if they differ, this is expected to require an explicit tenant setting
2. Portal → Admin portal → Tenant settings → **"Users can export items to Git repositories in other geographical locations"** → confirm enabled for this user/group
3. Note: this restriction and its override switch **do not apply to GitHub** — GitHub cross-region connects are not gated the same way, and this specific setting cannot be enforced for GitHub at all
4. Only item **metadata** crosses the geo boundary when this is enabled — item data and user-related information are not exported

**Rollback:** disable the tenant setting to revert to the geo-restricted default; existing connections made while it was enabled are not automatically severed by disabling it afterward.
</details>

---

## Escalation Evidence

```
=== FABRIC GIT INTEGRATION ESCALATION ===
Date/Time      :
Engineer       :
Ticket         :

Workspace Name/ID   :
Capacity Region      :
Git Provider          : (Azure DevOps / GitHub)
Repo / Project / Branch / Directory :

Tenant Setting State  : (Git integration switch, GitHub switch, cross-geo switch —
                         current values + whether delegated to capacity/workspace admin)
Connecting Account     :
Workspace Role         :
Item-Level Permission  : (confirmed read-write on all items? Y/N)

Git Status API Output  : (paste relevant `changes` array — conflictType, workspaceChange,
                          remoteChange per affected item)
Exact Error Text        :

Steps Attempted:
1.
2.
3.

Expected behaviour :
Actual behaviour   :
```

---

## 🎓 Learning Pointers

- **"Workspace role" and "item-level permission" are not the same gate.** A user can be workspace Contributor and still fail commit/update if item-level ACLs were customized to restrict them below read-write on every item — check item permissions specifically, not just the workspace role list. [Git integration process — permissions](https://learn.microsoft.com/en-us/fabric/cicd/git-integration/git-integration-process#permissions)
- **The GitHub switch is off by default; the Azure DevOps switch is on by default.** A tenant that "has Git integration enabled" may still have GitHub users blocked entirely — always confirm which specific switch applies to the provider actually in use. [Git integration tenant settings](https://learn.microsoft.com/en-us/fabric/admin/git-integration-admin-settings)
- **You cannot commit and update in the same operation — sync is always one direction.** This surprises engineers coming from a mental model of `git pull --rebase`; Fabric has no equivalent, resolve conflicts explicitly first. [Git integration process — commit/update](https://learn.microsoft.com/en-us/fabric/cicd/git-integration/git-integration-process#commits-and-updates)
- **Commit size limits differ by provider and by principal type** — 25 MB (ADO + service principal), 125 MB (ADO + user/SSO), 50 MB combined (GitHub). Don't quote one number for every ticket; confirm which auth path is in play first. [Git integration limitations](https://learn.microsoft.com/en-us/fabric/cicd/git-integration/git-integration-process#considerations-and-limitations)
- **Recycle-bin restore and Git Undo/Update are two different recovery mechanisms that don't know about each other** — mixing them on the same deleted item produces duplicate items with different logical IDs. Pick one recovery path and confirm before trying the other.
- **Starting December 1, 2026, read-write on workspace items becomes a hard requirement for Git integration**, not just a best practice — sensitivity-labeled or protection-policy-restricted items a user can currently view-but-not-edit will stop being syncable for that user. Flag this proactively for clients using sensitivity labels heavily in Fabric-connected workspaces. [Information protection in Microsoft Fabric](https://learn.microsoft.com/en-us/fabric/governance/information-protection)
