# Microsoft Fabric — Workspace Governance at Scale — Hotfix Runbook (Mode B: Ops)
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

This topic is tenant-wide **workspace naming/lifecycle/creation-restriction governance** — distinct from `Domains-B.md` (data-mesh grouping, never affects access) and `FabricAdmin-B.md` (capacity state/OneLake RBAC). Most tickets here land in one of three buckets: **who's allowed to create workspaces**, **a workspace with no admin (orphaned)**, or **a deleted/retention-window workspace that needs recovery**.

```powershell
# 1 — Connect (one-time)
Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser -Force
Connect-PowerBIServiceAccount

# 2 — Find every orphaned workspace tenant-wide (native cmdlet support — do this first)
Get-PowerBIWorkspace -Scope Organization -Orphaned -All |
    Select-Object Name, Id, Type, State

# 3 — Confirm who can create workspaces (portal only, no single cmdlet covers this)
# app.fabric.microsoft.com > gear icon > Admin portal > Tenant settings > Workspace settings > Create workspaces

# 4 — Confirm a specific workspace's current admin roster (REST — requires a Fabric bearer token)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>/users" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET

# 5 — List deleted/retention-window workspaces (admin portal, or REST with state filter)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces?state=Deleted" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| A user who shouldn't be able to created a new workspace anyway | **Create workspaces** tenant setting is scoped too broadly (Everyone), or the requester is in a security group granted the setting unintentionally | Fix 1 |
| `Get-PowerBIWorkspace -Orphaned` returns a workspace | No one holds the Admin role on it — content is still fully intact, only administration is blocked | Fix 2 |
| A departed employee's "My workspace" needs review or handover | Two different scenarios: still-**Active** (needs temporary admin access) vs. already **Deleted** (needs restore-as-app-workspace) | Fix 3 |
| Workspace names don't follow the agreed convention | **There is no platform-native naming-enforcement feature in Fabric** — this is a governance-process gap, not a misconfiguration | Fix 4 |
| Workspace was deleted by mistake, still within its retention window | Restore via admin portal or REST — full content recoverable | Fix 5 |
| A deleted workspace needs to be purged immediately (compliance/security reason), not wait out retention | Permanently delete before the retention period naturally expires | Fix 6 |
| Workspace can't reach/be reached from an external endpoint that should work (or the opposite — something unexpectedly gets through) | Workspace-level **Networking Communication Policy** (inbound/outbound access protection) — a separate settings-governance surface from naming/lifecycle | Fix 7 |

---

## Dependency Cascade

<details><summary>What must be true for workspace governance to behave as expected</summary>

```
[Tenant admin: "Create workspaces" tenant setting = Everyone | Specific security groups | Nobody]
    └── [Workspace created — displayName must be tenant-unique, <= 256 chars,
         "Admin monitoring" is a reserved name and will be rejected]
            └── [Creator becomes the workspace's first Admin]
                    └── [Admin role required to: update/delete the workspace, add/remove
                         other users incl. other Admins, connect Git, create workspace identity]
                            └── [Workspace lifecycle branches:]
                                ├── Active (normal) ──┬── an Admin's account is deleted/disabled
                                │                      │   in Entra, or the last Admin is removed
                                │                      │   without a replacement being assigned
                                │                      │        └── Orphaned (portal shows this
                                │                      │             state explicitly; REST Admin
                                │                      │             API's `state` field still
                                │                      │             reports "Active" — see
                                │                      │             WorkspaceGovernance-A.md)
                                │                      └── workspace deleted
                                │                               └── Deleted (retention period:
                                │                                    7-90 days configurable for
                                │                                    collaborative workspaces,
                                │                                    fixed 30 days for My workspace)
                                │                                        └── Removing (permanent,
                                │                                             short window)
                                └── (Update Workspace Role Assignment API refuses to change
                                     the LAST Admin's role — this only blocks the API path;
                                     it does NOT prevent orphaning via Entra account removal)

Separately gated, NOT a lifecycle state (settings governance, not naming/lifecycle):
[Workspace-level Networking Communication Policy — inbound/outbound access protection]
    └── independently configured per workspace; defaultAction defaults to Allow if omitted
        from a write request — always specify it explicitly

Explicitly NOT covered by this topic (see the cross-referenced files instead):
[Fabric domains — data-mesh grouping, Domains-B.md/-A.md] — never affects workspace access
[Capacity assignment / OneLake RBAC — FabricAdmin-B.md/-A.md] — a workspace's governance state
    here is independent of what capacity it's on or its OneLake security configuration
[Git integration content sync — GitIntegration-B.md/-A.md] — a workspace's lifecycle state
    here doesn't affect Git sync mechanics, though a Deleted/orphaned workspace obviously
    can't sync
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm which of the three governance buckets the ticket actually is**
Creation-restriction ("why can/can't this user make a workspace"), lifecycle/orphan ("nobody can manage this workspace" or "we need it back"), or naming ("this doesn't match our standard"). The fix paths don't overlap.

**Step 2 — For creation-restriction tickets, check the tenant setting's scope**
Portal: **Admin portal → Tenant settings → Workspace settings → Create workspaces**. Confirm whether it's set to Everyone, specific security groups (and which ones), or Nobody. There is no REST/PowerShell read for this specific setting's current value — it's portal-only.

**Step 3 — For orphan tickets, confirm via the native cmdlet first**
```powershell
Get-PowerBIWorkspace -Scope Organization -Orphaned -All
```
Good: empty result — no orphaned workspaces tenant-wide. Bad: the affected workspace appears — confirmed orphaned, proceed to Fix 2.

**Step 4 — Cross-check via REST if building automation instead of running interactively**
```powershell
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>/users" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET
```
Bad: the `accessDetails` array contains zero entries with `workspaceAccessDetails.workspaceRole = "Admin"`. **Important:** don't rely on the workspace's `state` field from `GET /v1/admin/workspaces/<id>` to detect this — Microsoft's own schema documents that "Orphaned workspaces are displayed as active" via that field. Only the portal's Workspaces list and the `-Orphaned` PowerShell switch surface the true state directly; pure-REST automation must derive it from a zero-Admin roster instead.

**Step 5 — For a departed-employee "My workspace" ticket, determine Active vs. Deleted first**
Portal: **Admin portal → Workspaces**, find the user's personal workspace, check the **State** column.
- **Active**: use temporary admin access (Fix 3, first path).
- **Deleted**: use restore-as-app-workspace (Fix 3, second path) — this is a different action with a different outcome (the personal workspace becomes a normal collaborative workspace other people can be added to).

**Step 6 — For naming tickets, confirm there genuinely is no platform enforcement before writing a governance recommendation**
There is no Fabric tenant setting, REST field, or portal control that blocks a non-conforming workspace name. The only two platform-level name constraints are: tenant-wide uniqueness and the reserved name `Admin monitoring`. Everything else is process (see Fix 4).

---

## Common Fix Paths

<details>
<summary>Fix 1 — Workspace creation isn't scoped the way the client expects</summary>

1. Portal → **Admin portal → Tenant settings → Workspace settings → Create workspaces**.
2. Best practice, and the recommended remediation for "too many people can create workspaces": scope to **Specific security groups** rather than Everyone — create (or reuse) a dedicated group (e.g. "Fabric Workspace Creators") whose members have been trained on the naming/governance standard, and assign only that group.
3. If the client wants creation fully locked down during a migration or cleanup window, temporarily set to **Nobody** — existing workspaces are unaffected, only new creation is blocked.
4. Confirm the change with an affected test user; tenant-setting propagation is not instant, consistent with all other Fabric tenant settings (see `FabricAdmin-B.md` Fix 6).

**Rollback:** revert the setting to its prior scope/group.
</details>

<details>
<summary>Fix 2 — Orphaned workspace (no Admin)</summary>

```powershell
# Confirm it's genuinely orphaned
Get-PowerBIWorkspace -Scope Organization -Orphaned -All |
    Where-Object Id -eq "<workspaceId>"

# Assign a new Admin — this is the actual fix
Add-PowerBIWorkspaceUser -Scope Organization -Id "<workspaceId>" `
    -UserEmailAddress "<upn>" -AccessRight Admin
```
1. Content inside an orphaned workspace is **not** at risk — orphaning only blocks administrative actions (adding/removing users, deleting the workspace, changing capacity assignment, connecting Git); items keep running normally under whatever roles remain.
2. Equivalent portal path: **Admin portal → Workspaces**, select the workspace, choose **Recover** from the ribbon or **More options (…) → Recover**, and assign a new Admin in the panel that appears.
3. Once an Admin exists, normal workspace administration (including reassigning capacity, connecting Git, or deleting the workspace if it's genuinely unused) works again.

**Rollback:** not applicable — assigning an Admin is purely additive and doesn't touch workspace content.
</details>

<details>
<summary>Fix 3 — Departed employee's "My workspace" needs review or handover</summary>

**If the personal workspace is still Active (user removed from Entra but workspace hasn't been deleted/retention-processed yet):**
```powershell
# Grant yourself 24-hour temporary admin access (REST — no dedicated PowerBIMgmt cmdlet for this)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>/grantAdminTemporaryAccess" `
    -Headers @{ Authorization = "Bearer $token" } -Method POST

# ... review/export/reassign content as needed, then explicitly remove access when done ...
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>/removeAdminTemporaryAccess" `
    -Headers @{ Authorization = "Bearer $token" } -Method POST
```
Portal equivalent: **Admin portal → Workspaces**, find the personal workspace, **Get Access** from the ribbon. Access auto-revokes after 24 hours if not manually removed first.

**If the personal workspace already shows State = Deleted** (Entra removed the account and Fabric processed the My-workspace deletion):
1. Portal → **Admin portal → Workspaces**, find the deleted personal workspace, select **Restore** from the ribbon or **More options (…) → Restore**.
2. In the panel, give the restored workspace a new name and assign at least one user the Admin role.
3. After restore, it converts from a personal workspace into a normal collaborative **Workspace** type that other people can be added to — this is a one-way conversion, not a temporary state.

**Rollback:** removing temporary admin access reverts nothing (no content was changed by the access grant itself, only by whatever actions were taken during it). Restoring a deleted My workspace as an app workspace has no built-in reverse path — it's a deliberate conversion, communicate that to the requester before proceeding.
</details>

<details>
<summary>Fix 4 — Workspace names don't follow the agreed convention</summary>

1. **Set expectations first:** confirm with the client/engineer that this needs a **process** fix, not a **platform** fix — Fabric has no naming-pattern enforcement mechanism at the tenant, capacity, or workspace level. The only two platform-enforced name constraints are tenant-wide uniqueness and the reserved name `Admin monitoring`.
2. The practical enforcement pattern Microsoft's own guidance points to: restrict the **Create workspaces** tenant setting (Fix 1) to a trained security group, so only people who know the standard can create workspaces in the first place.
3. For workspaces that already violate the standard, rename via the portal (workspace settings) or REST:
```powershell
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces/<workspaceId>" `
    -Headers @{ Authorization = "Bearer $token" } -Method PATCH `
    -Body (@{ displayName = "<NewConformingName>" } | ConvertTo-Json) -ContentType "application/json"
```
4. For ongoing drift detection rather than a one-off cleanup, run `Scripts/Get-FabricWorkspaceGovernanceAudit.ps1` with a `-NamingPattern` regex on a schedule and route non-conforming results to whoever owns workspace governance.

**Rollback:** renaming a workspace is non-destructive and fully reversible (rename again).
</details>

<details>
<summary>Fix 5 — Deleted workspace needs to come back (within retention window)</summary>

```powershell
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>/restore" `
    -Headers @{ Authorization = "Bearer $token" } -Method POST `
    -Body (@{
        newWorkspaceName = "<name>"
        newWorkspaceAdminPrincipal = @{ id = "<userObjectId>"; type = "User" }
    } | ConvertTo-Json) -ContentType "application/json"
```
1. Confirm the workspace is genuinely still in its retention window: portal → **Admin portal → Workspaces**, `State = Deleted` (not yet `Removing`).
2. `newWorkspaceName` is only mandatory for a **My workspace** restore; for a normal collaborative workspace it's optional (keeps the original name if omitted).
3. `newWorkspaceAdminPrincipal` must be a valid principal (User/Group/ServicePrincipal/ServicePrincipalProfile/EntireTenant) — the restored workspace needs at least one Admin, same as any workspace.
4. This API is rate-limited to 10 requests/minute and is documented as a **preview** surface — treat it as subject to change, and prefer the portal path for one-off restores.
5. Portal equivalent: select the deleted workspace, **Restore** from the ribbon or **More options (…) → Restore**.

**Rollback:** not applicable — restoring recovers the workspace; there's nothing to undo unless the restore itself was a mistake, in which case delete it again (re-enters a fresh retention window).
</details>

<details>
<summary>Fix 6 — Need to purge a deleted workspace before retention naturally expires</summary>

1. Portal → **Admin portal → Workspaces**, find the deleted workspace (`State = Deleted`), select **Permanently delete** from the ribbon or **More options (…) → Permanently delete**.
2. Fabric prompts for confirmation — after confirming, the workspace and its contents are **not recoverable by any means**, including by Microsoft support in the general case.
3. There is no REST Admin API operation for permanent deletion in the currently documented surface (only `Restore Workspace` is exposed under `/v1/admin/workspaces`) — this action is portal-only as of this writing.
4. Common driver for this fix: a compliance/security requirement to remove data immediately rather than wait out the configured 7-90 day retention window — confirm this is genuinely required before using it, since it forecloses the normal safety net.

**Rollback:** none — this is intentionally irreversible. Do not run this without explicit confirmation from whoever owns the data.
</details>

<details>
<summary>Fix 7 — Workspace-level networking (inbound/outbound access protection) misbehaving</summary>

1. This is a distinct settings-governance surface from naming/lifecycle — it controls whether the workspace can be reached from, or reach out to, public networks, specific connection types (SQL, Lakehouse, gateways, Git), by default.
2. Read current policy for one workspace at a time via the portal (workspace settings → Network security), or tenant-wide via REST:
```powershell
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/networking/communicationpolicies" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET
```
Only returns workspaces that have Inbound or Outbound Access Protection explicitly enabled — a workspace absent from this response has no restriction configured (default-open).
3. **Critical write-side gotcha, worth flagging to anyone scripting a policy change:** every `defaultAction` field (top-level inbound/outbound, per-connection-type, gateways) defaults to `Allow` if omitted from a `PUT` request body — an incomplete payload can silently widen access instead of narrowing it. Always specify every `defaultAction` explicitly.
4. If a user reports "can't connect to X from this workspace" or "an external service can reach this workspace and shouldn't be able to," this is the setting to check before assuming it's a capacity, tenant-setting, or OneLake RBAC issue (`FabricAdmin-B.md`).

**Rollback:** revert to the prior policy JSON captured before the change (there's no automatic "previous version" — capture current state via the GET call before writing).
</details>

---

## Escalation Evidence

```
=== FABRIC WORKSPACE GOVERNANCE ESCALATION ===
Date/Time      :
Engineer       :
Ticket         :

Workspace Name/ID  :
Workspace Type      : (Workspace / Personal / AdminWorkspace)
Workspace State     : (Active / Orphaned / Deleted / Removing / Not found — from admin portal, NOT the REST state field alone)

Ticket Category     : (Creation restriction / Orphan-lifecycle / Naming / Deletion-recovery / Networking policy)

Create Workspaces Tenant Setting Scope : (Everyone / Specific security groups — which / Nobody)
Current Admin Roster (from List Workspace Access Details, if orphan-related) :

Retention Window (if Deleted) : (configured days, 7-90; My workspace fixed 30)
Restore Attempted?  : (Y/N, outcome)

Networking Policy State (if relevant) : (paste relevant inbound/outbound defaultAction values)

Steps Attempted:
1.
2.
3.

Expected behaviour :
Actual behaviour   :
```

---

## 🎓 Learning Pointers

- **Fabric has no naming-convention enforcement feature — full stop.** Confirmed directly against the Workspace tenant settings reference: the only two platform-enforced name constraints are tenant-wide uniqueness and the reserved name `Admin monitoring`. Any naming-standard request from a client needs a process answer (restrict creation to a trained group, audit periodically), not a search for a setting that doesn't exist. [Workspace tenant settings](https://learn.microsoft.com/en-us/fabric/admin/portal-workspace)
- **The REST Admin API's workspace `state` field cannot detect orphaned workspaces — only Active/Deleted are exposed there, with orphaned ones reported as Active.** Microsoft's own schema states this explicitly ("Orphaned workspaces are displayed as active"). Pure-REST automation must derive orphan status from a zero-Admin roster via List Workspace Access Details; the portal and the `Get-PowerBIWorkspace -Orphaned` PowerShell switch surface the true state directly. [Get Workspace — REST API (Admin)](https://learn.microsoft.com/en-us/rest/api/fabric/admin/workspaces/get-workspace)
- **Orphaning doesn't touch content, only administration.** An orphaned workspace's items keep functioning for whatever non-Admin roles remain — the fix is purely additive (assign a new Admin), never a recovery-from-data-loss scenario. [Manage workspaces](https://learn.microsoft.com/en-us/fabric/admin/portal-workspaces)
- **"Restore a deleted My workspace" and "grant temporary access to an active My workspace" are two different tools for two different states of the same underlying problem (a departed employee's content).** Using the wrong one either fails outright (can't grant temporary access to something already deleted) or produces an unwanted one-way conversion (restoring an still-recoverable-without-conversion Active workspace as if it were Deleted isn't possible, but the reverse mistake — not realizing restore is a permanent Personal→Workspace type conversion — trips people up). Confirm the State column first. [Set up and manage workspace retention](https://learn.microsoft.com/en-us/fabric/admin/workspace-retention)
- **Retention length is genuinely configurable for collaborative workspaces (7-90 days) but fixed at 30 days for My workspaces regardless of the tenant setting.** Don't quote one retention number for every workspace type in a client conversation. [Set up and manage workspace retention](https://learn.microsoft.com/en-us/fabric/admin/workspace-retention)
- **Networking Communication Policy write calls default every omitted `defaultAction` to `Allow`.** A partial PUT intended to tighten a workspace's network posture can silently do the opposite if a field is left out — always send the complete policy object. [List Networking Communication Policies — REST API (Admin)](https://learn.microsoft.com/en-us/rest/api/fabric/admin/workspaces/list-networking-communication-policies)
