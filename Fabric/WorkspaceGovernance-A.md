# Microsoft Fabric — Workspace Governance at Scale — Reference Runbook (Mode A: Deep Dive)
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

This is the deep-dive companion to `WorkspaceGovernance-B.md`. It covers tenant-wide **workspace governance at scale**: who is allowed to create workspaces and how that's gated, what naming enforcement actually exists on the platform (and what doesn't), the full workspace lifecycle and retention/recovery model, orphaned-workspace detection and recovery mechanics, and the relevant REST API surface (Admin and Core) for automating all of the above.

**This is explicitly a different topic from three existing Fabric runbooks, not an overlapping one:**
- `Domains-A.md`/`-B.md` — Fabric domains are a data-mesh **grouping/discovery** layer (`domainId` metadata). Domain assignment never affects workspace lifecycle, creation eligibility, or naming — a workspace can be orphaned or perfectly healthy regardless of its domain, and vice versa.
- `FabricAdmin-A.md`/`-B.md` — capacity state, CU-second throttling, and the OneLake data-access-role (RBAC) model. This file assumes capacity/OneLake concerns are already understood and doesn't repeat them; a workspace's governance state here (Active/Orphaned/Deleted) is orthogonal to what capacity it's on.
- `GitIntegration-A.md`/`-B.md` — content synchronization with an external Git repository. A Deleted or orphaned workspace obviously can't sync, but Git integration mechanics themselves are out of scope here.

**Assumes:** the reader has Fabric Administrator (or Power BI Administrator/Global Administrator, which also carry this capability) rights for admin-scoped calls, and is comfortable with `Invoke-RestMethod` and the `MicrosoftPowerBIMgmt` PowerShell module.

**Does not cover:** domain-level or capacity-level settings delegation (see the cross-referenced files), item-level (as opposed to workspace-level) retention and recovery, or OneLake security role authoring.

---

## How It Works

<details><summary>Full architecture — workspace creation governance</summary>

Workspace creation in Fabric is gated by exactly one tenant setting: **Create workspaces**, found under **Admin portal → Tenant settings → Workspace settings**. It supports three states:
- **Everyone** in the organization can create workspaces (the default, and the single biggest reason a tenant ends up with governance debt — anyone can spin up a workspace with any name, on any capacity they have access to, with zero naming or approval gate).
- **Specific security groups** — the recommended production posture. Only members of the designated group(s) can create new workspaces; everyone else can still be added to existing workspaces normally, this setting only gates *creation*.
- **Nobody** — a hard lockdown, typically used temporarily during a migration, consolidation, or cleanup project.

There is no REST API surface for reading or writing this specific tenant setting's current value as of this writing — it is portal-only, unlike some other Fabric tenant settings that have a documented settings-API equivalent. Publish/app-distribution permissions are a separate, adjacent tenant-setting section, not the same gate.

The practical governance pattern this enables: create a dedicated security group (commonly named something like "Fabric Workspace Creators"), populate it only with users who have been trained on the organization's naming/lifecycle standard, and scope **Create workspaces** to that group alone. This is Microsoft's own documented recommendation and is the closest thing Fabric has to naming enforcement — enforcement-by-restricting-who-can-act, not enforcement-by-validating-what-they-typed.

</details>

<details><summary>Full architecture — naming: what's actually enforced vs. what isn't</summary>

It would be easy to assume a mature SaaS platform has a naming-policy feature for a resource as fundamental as a workspace. **It does not, as of this writing**, and this was confirmed directly against the current Workspace tenant settings reference rather than assumed from general platform maturity. The complete list of platform-enforced constraints on a workspace's `displayName`, taken from the `Update Workspace` (core) and `Get/List Workspace` (admin) API schemas:

- **Tenant-wide uniqueness.** No two workspaces in the same tenant can share a display name, regardless of domain, capacity, or folder. This mirrors the same uniqueness rule already documented for domain names in `Domains-A.md` — a recurring Fabric platform pattern of tenant-wide (not scoped-to-parent) uniqueness.
- **256-character maximum.**
- **`Admin monitoring` is a reserved name** — attempting to create or rename a workspace to this exact string fails, because it collides with the built-in admin monitoring workspace that ships with every tenant.

That's the entire list. There is no:
- Regex/pattern validation against an admin-configured naming template.
- Required-prefix or required-suffix enforcement (e.g. forcing every workspace to start with a business-unit code).
- A "naming policy" object anywhere in the REST Admin API surface (contrast with, e.g., the Fabric domain object's own `displayName` uniqueness rule, which is at least documented as an explicit validation — workspace naming has no equivalent policy object to even point at).

**Enforcement is therefore entirely a governance-process problem, and the tooling available is indirect:**
1. Restrict who can create workspaces (previous section) to people who know and will follow the standard.
2. Make naming-standard adherence a condition of getting an **Endorsed**/**Certified** badge on content within the workspace, giving the standard a visible, socially-enforced consequence.
3. Run a periodic **audit** (regex match against `List Workspaces` output) and route non-conformers back to their owning team for a rename — this repo's `Scripts/Get-FabricWorkspaceGovernanceAudit.ps1` implements exactly this pattern.

Any MSP engagement that promises a client "we'll enforce your naming convention in Fabric" needs to be scoped as an audit-and-remediate process with a defined cadence, not a one-time technical control — a materially different deliverable and SOW than "configure the naming policy," which doesn't exist as a thing to configure.

</details>

<details><summary>Full architecture — workspace lifecycle, retention, and the orphan-detection blind spot</summary>

**The full state model has five values, but they don't all live in the same place.** The Fabric admin portal's Workspaces list documents five states — `Active`, `Orphaned`, `Deleted`, `Removing`, `Not found` — but the REST Admin API's `WorkspaceState` enum (used by both `Get Workspace` and `List Workspaces`) only defines two: `Active` and `Deleted`, with the schema explicitly noting **"Orphaned workspaces are displayed as active."** This is not a documentation oversight to work around — it's the API's actual documented behavior, confirmed directly against the current REST reference rather than assumed.

**Practical consequence:** a script that calls `GET /v1/admin/workspaces` and filters on `state == "Active"` will silently include every orphaned workspace in that result set, indistinguishable from a perfectly healthy one, using the `state` field alone. There are exactly two reliable ways to actually detect orphaning:
- **The `Get-PowerBIWorkspace -Scope Organization -Orphaned -All` PowerShell switch** — a dedicated, purpose-built parameter in the `MicrosoftPowerBIMgmt.Workspaces` module that does expose true orphan state (it queries a different, legacy Power BI Admin API surface underneath that predates the Fabric v1 Admin API and does carry an explicit Orphaned value).
- **Deriving it yourself** by calling `List Workspace Access Details` (`GET /v1/admin/workspaces/{workspaceId}/users`) for each workspace and checking whether zero entries have `workspaceAccessDetails.workspaceRole == "Admin"`. This is the only pure-REST path, and it's O(n) admin API calls against a 200-requests/hour rate limit — expensive for a large tenant, which is why the PowerShell cmdlet path is strongly preferred for interactive/scheduled auditing, with the REST cross-check reserved for automation that specifically needs to avoid a PowerBIMgmt dependency.

**How a workspace actually becomes orphaned.** The `Update Workspace Role Assignment` (core) API explicitly documents that *"the role assignment of the last admin can't be changed"* — this is a real, enforced guardrail against an in-band API call orphaning a workspace. But it only protects the in-band path. A workspace still becomes orphaned when the **out-of-band** removal happens instead: the sole remaining Admin's Entra account is disabled or deleted (e.g. offboarding), or every Admin leaves the organization without anyone reassigning the role first. Neither of those events goes through the workspace role-assignment API at all, so the guardrail never fires. This same shape — an in-band API protecting against a direct action, while an identity-lifecycle event on the other side of the boundary bypasses it entirely — is worth recognizing as a recurring class of governance gap, not unique to Fabric.

**Retention and recovery, once a workspace is actually deleted (not merely orphaned — these are different states):**
- Collaborative (`Workspace`-type) deletions get a **configurable retention period, 7-90 days**, set via the **Define workspace retention period** tenant setting. If that setting is left off, the *default* retention is still 7 days — turning the setting off does not mean "no retention," it means "use the 7-day default."
- **My workspace** (personal) deletions get a **fixed 30-day retention period**, unaffected by the collaborative-workspace retention tenant setting. This asymmetry is easy to misstate in a client conversation — confirm which workspace *type* before quoting a retention window.
- After retention expires, a workspace moves to a **Removing** state (permanent deletion in progress, a short-lived transitional state) rather than disappearing instantly.
- Restoring a deleted **collaborative** workspace keeps it as a `Workspace` type, recovers all content, and requires assigning at least one new Admin plus (optionally) a new name.
- Restoring a deleted **My workspace** is a **one-way conversion**: it comes back not as a personal workspace but as a normal collaborative `Workspace` that other people can subsequently be added to. `newWorkspaceName` is mandatory specifically for this scenario (a My workspace restore) because personal workspaces don't have a meaningful display name to preserve.
- **Permanently delete** (available any time during the retention window) skips the wait and is irreversible — as of this writing it is portal-only; the REST Admin API surface exposes `Restore Workspace` but no permanent-delete operation.

</details>

<details><summary>Full architecture — the full REST API surface for workspace governance</summary>

**Admin-scoped operations** (`/v1/admin/workspaces/*`, require Fabric Administrator or a service principal, all preview-flagged as of this writing):

| Operation | Method + path | Rate limit | Notes |
|-----------|---------------|------------|-------|
| Get Workspace | `GET .../{workspaceId}` | 200/hour | Returns `state` (Active/Deleted only — see orphan-detection note above) |
| List Workspaces | `GET .../` | 200/hour | Supports `type`, `capacityId`, `name`, `state`, `encryptionStatus`, `include` filters; paginated, max 10,000 records/page via `continuationToken` |
| List Workspace Access Details | `GET .../{workspaceId}/users` | 200/hour | Per-workspace role roster — the only reliable pure-REST orphan-detection signal |
| List Git Connections | `GET .../gitConnections` | — | Admin-scoped enumeration of Git-connected workspaces tenant-wide (complements the workspace-scoped calls in `GitIntegration-A.md`) |
| List Networking Communication Policies | `GET .../networking/communicationpolicies` | — | Only returns workspaces with Inbound or Outbound Access Protection explicitly enabled; paginated |
| Grant Admin Temporary Access | `POST .../{workspaceId}/grantAdminTemporaryAccess` | 25/min | My workspace only; 24-hour auto-revoking grant; `EntityNotFound` if target isn't a My workspace |
| Remove Admin Temporary Access | `POST .../{workspaceId}/removeAdminTemporaryAccess` | 25/min | `BadRequest` if the caller doesn't currently hold temporary access |
| Restore Workspace | `POST .../{workspaceId}/restore` | 10/min | Preview surface; `newWorkspaceName` mandatory only for My workspace restores |

**Core-scoped operations** (`/v1/workspaces/*`, require the relevant workspace role rather than tenant-admin rights):

| Operation | Method + path | Permission required | Notes |
|-----------|---------------|---------------------|-------|
| Update Workspace | `PATCH /v1/workspaces/{workspaceId}` | Admin workspace role | `displayName` (≤256 chars, tenant-unique, `Admin monitoring` reserved), `description` (≤4000 chars) |
| Update Workspace Role Assignment | `PATCH /v1/workspaces/{workspaceId}/roleAssignments/{id}` | Admin workspace role | Refuses to change the **last** Admin's role — see the orphan-mechanics note above for what this does and doesn't protect against |

All admin-scoped list/get operations require the `Tenant.Read.All` or `Tenant.ReadWrite.All` delegated scope; the two temporary-access operations and `Restore Workspace` require `Tenant.ReadWrite.All` specifically. Core-scoped operations require `Workspace.ReadWrite.All`. Every operation documented here supports both user and service-principal/managed-identity callers.

**Common error codes worth handling explicitly in automation**, gathered across these operations: `EntityNotFound` (workspace ID doesn't exist, or — specific to the temporary-access operations — the target isn't a My workspace at all), `InsufficientPrivileges`/`InsufficientScopes` (caller lacks the Fabric Administrator role or the right delegated scope), `Unauthorized` (temporary-access operations specifically require a *tenant admin*, not just any Fabric admin-adjacent role, and reject non-admin service principals outright), `BadRequest` (context-specific — e.g. requesting temporary access that's already granted, or removing access that was never granted), and the universal `429 Too Many Requests` with a `Retry-After` header that must be honored.

</details>

---

## Dependency Stack

```
Layer 5 — Governance process (no platform enforcement exists at this layer)
    Naming-convention adherence | approval workflows | Endorsed/Certified as a
    social-enforcement mechanism
        └── entirely process/audit-driven — Get-FabricWorkspaceGovernanceAudit.ps1
            implements the audit half of this layer

Layer 4 — Workspace-level settings governance
    Networking Communication Policy (inbound/outbound access protection,
    defaultAction Allow-by-omission gotcha) | workspace description/tags
        └── independently configured per workspace, does not gate creation
            or lifecycle state below

Layer 3 — Workspace lifecycle state machine
    Active ──(all Admins removed, in-band OR via Entra account
              deletion/disable — only the in-band path is API-guarded)──> Orphaned
        (REST `state` field still reports "Active" for Orphaned — portal
         and Get-PowerBIWorkspace -Orphaned are the only reliable signals)
    Active ──(delete)──> Deleted (retention: 7-90d collaborative / 30d fixed
              My workspace) ──(retention expires)──> Removing ──> gone
    Deleted ──(Restore Workspace)──> Active (collaborative: same type;
              My workspace: ONE-WAY conversion to collaborative Workspace type)
    Deleted ──(Permanently delete, portal-only)──> gone immediately, no
              recovery, skips the remaining retention window

Layer 2 — Workspace object identity and role model
    displayName (tenant-unique, <=256 chars, "Admin monitoring" reserved) |
    Admin/Member/Contributor/Viewer roles | Admin required for
    update/delete/role-management/Git-connect/identity-creation
        └── "last Admin" role-change is API-blocked (Update Workspace Role
            Assignment) — but this guardrail is bypassed by identity-lifecycle
            events outside the workspace API surface entirely

Layer 1 — Tenant-level creation gate
    "Create workspaces" tenant setting: Everyone | Specific security groups |
    Nobody — portal-only, no REST/PowerShell read of current value
        └── the single practical lever for naming/governance enforcement:
            restrict creation to a trained group, since nothing downstream
            validates what gets typed into displayName

Orthogonal, cross-referenced elsewhere in this Fabric domain:
[Domains — data-mesh grouping, Domains-A.md/-B.md] — never affects any layer above
[Capacity assignment / OneLake RBAC — FabricAdmin-A.md/-B.md] — independent of
    workspace governance state; a workspace can be Orphaned on a perfectly
    healthy Active capacity, or vice versa
[Git integration — GitIntegration-A.md/-B.md] — content sync mechanics;
    Deleted/Orphaned workspaces can't meaningfully sync but Git health itself
    is a separate failure domain
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| A script filtering `GET /v1/admin/workspaces` on `state == "Active"` includes a workspace everyone agrees is orphaned | REST `state` field genuinely cannot distinguish Orphaned from Active — documented API behavior, not a bug | Cross-check via `Get-PowerBIWorkspace -Orphaned` or `List Workspace Access Details` zero-Admin roster |
| Client asks "where do we configure the naming policy" | No such feature exists in Fabric as of this writing | Redirect to the governance-process pattern: restrict creation (Layer 1) + periodic audit |
| A workspace can't be created with a specific name, error is generic | Name collides tenant-wide with an existing workspace, OR the name is exactly `Admin monitoring` (reserved) | `List Workspaces` filtered by `name` to check for an existing collision |
| "Nobody can manage this workspace, but the reports still work fine" | Orphaned — content unaffected, only administration blocked | `Get-PowerBIWorkspace -Orphaned`, then assign a new Admin |
| Update Workspace Role Assignment call fails when trying to demote/remove the only Admin | Expected — the API explicitly refuses to change the last Admin's role | This is a guardrail working as intended, not a bug to route around; assign a second Admin first if a role change is genuinely needed |
| A workspace became orphaned even though "the API should have stopped that" | The orphaning happened via Entra account deletion/disable, not via a workspace role-assignment call — the in-band guardrail never had a chance to fire | Confirm via Entra sign-in logs / audit whether the departure was account-deletion-driven rather than an explicit role change |
| Departed employee's personal workspace: temporary-access grant fails with `EntityNotFound` | The workspace's `state` is already `Deleted`, not `Active` — temporary access only applies to a still-Active My workspace | Check `State` column in the admin portal Workspaces list first |
| Restored a departed employee's My workspace and now it behaves like a normal team workspace other people can join | Expected — restoring a Deleted My workspace is a documented one-way conversion to a collaborative `Workspace` type | Not a bug; communicate this conversion is permanent before the restore is performed |
| Client assumed a 90-day retention window applies to a departed employee's My workspace, but it was purged sooner | My workspace retention is a **fixed 30 days**, independent of the collaborative-workspace retention tenant setting (7-90 days configurable) | Confirm workspace *type* before quoting any retention figure |
| A `PUT` to the Networking Communication Policy endpoint intended to tighten access instead widened it | An omitted `defaultAction` field defaults to `Allow` — a partial payload silently opens access | Always send every `defaultAction` field explicitly on every write |
| Restore Workspace call returns success but the workspace still isn't usable | `Restore Workspace` is a documented **preview** API — treat schema/behavior as subject to change; verify via a follow-up `Get Workspace` call rather than trusting the `200` alone | Re-GET the workspace and confirm `state == "Active"` and an Admin is actually assigned |
| Automation hitting 429s specifically on `List Workspace Access Details` calls during a tenant-wide orphan sweep | 200 requests/hour cap on this specific admin-scoped operation, easily exhausted when called once per workspace across a large tenant | Prefer `Get-PowerBIWorkspace -Orphaned` for bulk detection; reserve the REST cross-check for spot-checks or cap the call count explicitly |

---

## Validation Steps

**1 — Confirm the caller's rights before anything else**
```powershell
Connect-PowerBIServiceAccount
Get-PowerBIWorkspace -Scope Organization -Top 1
```
Good: returns a result without a permissions error — the account holds sufficient admin rights for `-Scope Organization` calls. Bad: an authorization error — the account isn't a Fabric/Power BI Administrator.

**2 — Enumerate orphaned workspaces via the authoritative PowerShell path**
```powershell
Get-PowerBIWorkspace -Scope Organization -Orphaned -All | Select-Object Name, Id, Type
```
Good: a complete, accurate list (this cmdlet queries a surface that does carry a true Orphaned state). Bad: an empty result when the portal clearly shows an orphaned workspace — re-confirm the account has `-Scope Organization` rights; the switch silently requires it.

**3 — Cross-check one specific workspace via REST, and observe the `state` field's actual behavior**
```powershell
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<orphanedWorkspaceId>" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET
```
Expected/documented: `state` reports `"Active"` even for a confirmed orphan — this is not a bad result, it's the documented behavior. Confirm the true state via Step 4 instead.

**4 — Confirm zero Admins via List Workspace Access Details**
```powershell
$access = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<orphanedWorkspaceId>/users" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET
$access.accessDetails | Where-Object { $_.workspaceAccessDetails.workspaceRole -eq "Admin" }
```
Bad (confirming orphan status): this returns nothing. Good (workspace is healthy): at least one entry with `workspaceRole = "Admin"`.

**5 — Confirm the Create Workspaces tenant setting's current scope**
Portal only: **Admin portal → Tenant settings → Workspace settings → Create workspaces**. No REST/PowerShell read exists for this setting's live value — document the observed portal state directly in any evidence pack rather than trying to script this check.

**6 — Confirm retention window and type before promising a recovery timeline**
```powershell
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET |
    Select-Object id, name, type, state
```
If `type = "Personal"`, retention is a fixed 30 days regardless of the tenant setting. If `type = "Workspace"`, retention follows the **Define workspace retention period** tenant setting (7-90 days, defaults to 7 if the setting itself is off).

**7 — After a Restore Workspace call, verify rather than trust the response**
```powershell
Start-Sleep -Seconds 5
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET
```
Good: `state = "Active"`. Bad: still `Deleted`, or an unexpected `type` — this is a preview API; don't skip verification just because the initial `POST` returned `200`.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Classify the ticket**
Creation-restriction, orphan/lifecycle, naming, or workspace-level settings (networking). Each has a non-overlapping fix path — don't start pulling REST data before this classification is clear.

**Phase 2 — If orphan/lifecycle: establish true state first**
Never trust the REST `state` field alone for orphan detection. Run `Get-PowerBIWorkspace -Orphaned` (or the portal's Workspaces list, which shows the real five-state model) before concluding a workspace is or isn't orphaned.

**Phase 3 — If lifecycle involves a departed employee: determine Active vs. Deleted before choosing a tool**
Temporary admin access only works on an Active My workspace; restore-as-app-workspace only works on a Deleted one. Using the wrong tool fails with `EntityNotFound`, not a helpful redirect.

**Phase 4 — If naming: confirm no platform control is being overlooked before recommending a process fix**
Re-check the Workspace tenant settings reference if there's any doubt — Fabric ships new tenant settings reasonably often, and a naming-policy feature could in principle be added in the future. As of this writing, it hasn't been.

**Phase 5 — If automating any of the above: respect the two different rate-limit tiers**
Admin-scoped list/get calls: 200/hour. Temporary-access and Restore Workspace: 25/min and 10/min respectively. A tenant-wide orphan sweep using the REST cross-check (not the PowerShell switch) can exhaust the 200/hour budget quickly — architect around the PowerShell path for bulk work.

**Phase 6 — Verify, always, before closing**
Every mutating call in this topic (Restore Workspace, Grant/Remove Admin Temporary Access, Update Workspace, Update Workspace Role Assignment) should be followed by a read-back confirming the intended state, not just a `200` status code — consistent with the preview-API caution already established for `Restore Workspace` and the general Fabric REST API pattern seen across `Domains-A.md` and `GitIntegration-A.md`.

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Build a scheduled, tenant-wide orphaned-workspace sweep and recovery queue</summary>

1. Run `Get-PowerBIWorkspace -Scope Organization -Orphaned -All` on a schedule (daily/weekly depending on tenant size and turnover rate) — this is the authoritative, rate-limit-friendly detection path; don't default to the REST cross-check for bulk enumeration.
2. For each orphaned workspace, resolve an appropriate recovery owner — common heuristics: last known Admin's manager (via Entra), or the workspace's domain assignment if one exists (`Domains-A.md` — note domain assignment doesn't grant access, but it's a reasonable *routing* signal for "who should own this").
3. Assign the new Admin via `Add-PowerBIWorkspaceUser -Scope Organization -Id <id> -UserEmailAddress <upn> -AccessRight Admin` — this is additive and doesn't require deleting/recreating anything.
4. Log every recovery action (workspace ID, prior state, new Admin, timestamp) — this becomes the audit trail proving orphaned workspaces aren't silently accumulating unmanaged content.
5. For a tenant with a genuinely high volume of orphaning (frequent offboarding without a formal handover step), treat this as a signal to fix the *upstream* process — e.g. requiring a workspace-handover step in the offboarding checklist — rather than only ever running reactive sweeps.

**Rollback:** none needed — every action here is additive (assigning an Admin), never destructive.
</details>

<details>
<summary>Playbook 2 — Enforce a naming standard without a platform feature to enforce it</summary>

1. Restrict the **Create workspaces** tenant setting to a dedicated, trained security group — this is the only true *preventive* control available; everything else in this playbook is *detective*.
2. Publish the naming standard as a short, unambiguous regex or template (e.g. `^[A-Z]{2,4}-(Dev|Test|Prod)-[A-Za-z0-9]+$`) and hand it directly to whoever owns the Workspace Creators group membership.
3. Run `Scripts/Get-FabricWorkspaceGovernanceAudit.ps1 -NamingPattern '<regex>'` on a schedule; route flagged workspaces to their listed Admin(s) for a rename (via portal or `Update Workspace` PATCH) rather than renaming unilaterally, unless the engagement explicitly grants that authority.
4. Consider tying naming-standard compliance to whether a workspace's content is eligible for **Endorsed**/**Certified** status — a real, visible incentive users care about, compensating for the lack of a hard technical gate.
5. Re-audit after each rename cycle and track the non-conformance count over time as a governance-health metric worth reporting to the client, not just a one-off cleanup.

**Rollback:** renames are non-destructive; revert via another `Update Workspace` PATCH call if a rename was made in error.
</details>

<details>
<summary>Playbook 3 — Standard offboarding handling for a departed employee's My workspace</summary>

**If content review/handover is needed before the account is fully deprovisioned (workspace still Active):**
1. Grant temporary admin access: `POST /v1/admin/workspaces/{id}/grantAdminTemporaryAccess`.
2. Review contents, export or note anything that needs to move to a team workspace (temporary access lets you view/modify but not grant others access — plan the actual handover as a separate step using a normal workspace, not the My workspace itself).
3. Explicitly call `removeAdminTemporaryAccess` when done, rather than relying on the 24-hour auto-revoke, to keep the access window as short as possible and leave a clean audit trail.

**If the account/workspace has already been deleted and entered its 30-day retention window:**
1. Confirm via the admin portal Workspaces list that `State = Deleted` and the type is `Personal`.
2. Restore via portal or `POST /v1/admin/workspaces/{id}/restore` with a `newWorkspaceName` (mandatory for this scenario) and a `newWorkspaceAdminPrincipal` set to whoever should own the content going forward (often a manager or a team distribution list turned into a proper workspace membership).
3. Communicate clearly to that new owner that this is now a normal collaborative workspace, not a personal one — other people can be added, and it will not behave like the original owner's My workspace in any respect going forward.

**If the 30-day window has already elapsed:** the content is gone. This is the practical argument for building Playbook 1's proactive sweep and a documented offboarding SLA (e.g. "My workspace review happens within 5 business days of an offboarding ticket") rather than relying on ad hoc requests that can arrive after the window closes.

**Rollback:** temporary access removal has nothing to roll back. A My workspace restore-as-app-workspace has no reverse path — flag this to the requester as a one-way decision before executing it.
</details>

<details>
<summary>Playbook 4 — Auditing and safely updating workspace-level Networking Communication Policy at scale</summary>

1. Enumerate current policy state tenant-wide: `GET /v1/admin/workspaces/networking/communicationpolicies` (paginated via `continuationToken`) — remember this only returns workspaces with an explicit policy configured; absence from the result means default-open, not "policy = deny."
2. Before writing any policy change, `GET` the specific workspace's current full policy object first and modify it in place rather than constructing a new payload from scratch — this avoids the omitted-`defaultAction`-defaults-to-`Allow` trap documented in `WorkspaceGovernance-B.md` Fix 7.
3. For a tenant-wide tightening initiative (e.g. "deny outbound SQL by default, allow-list specific endpoints"), stage the change on a small pilot group of workspaces first and confirm no legitimate connections break before rolling tenant-wide — this setting can break working data pipelines if applied incorrectly.
4. Re-`GET` after every write to confirm the applied policy matches intent — same verify-don't-trust principle as every other mutating call in this file.

**Rollback:** restore the exact prior policy JSON captured in step 2 via another `PUT` call — there's no platform-side version history for this setting, so capturing prior state before any change is the only safety net.
</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects workspace governance evidence (orphan status, admin roster,
    lifecycle state, naming) for a specific workspace, for escalation.
.DESCRIPTION
    Read-only. Combines the MicrosoftPowerBIMgmt module (for authoritative
    orphan detection) with direct Fabric REST Admin API calls (for the
    role roster and lifecycle state) since neither surface alone tells the
    complete story for this topic. For routine fleet-wide auditing, prefer
    Scripts/Get-FabricWorkspaceGovernanceAudit.ps1 in this folder — this
    block is a lightweight, single-workspace escalation snapshot.
#>
param(
    [Parameter(Mandatory)][string]$WorkspaceId,
    [Parameter(Mandatory)][string]$Token
)

Import-Module MicrosoftPowerBIMgmt -ErrorAction Stop
if (-not (Get-PowerBIAccessToken -ErrorAction SilentlyContinue)) {
    Connect-PowerBIServiceAccount
}

$headers = @{ Authorization = "Bearer $Token" }
$base    = "https://api.fabric.microsoft.com/v1/admin/workspaces/$WorkspaceId"

$workspaceRest = Invoke-RestMethod -Uri $base -Headers $headers -Method GET -ErrorAction SilentlyContinue
$accessDetails = Invoke-RestMethod -Uri "$base/users" -Headers $headers -Method GET -ErrorAction SilentlyContinue
$orphanCheck   = Get-PowerBIWorkspace -Scope Organization -Orphaned -All | Where-Object Id -eq $WorkspaceId

$adminCount = ($accessDetails.accessDetails |
    Where-Object { $_.workspaceAccessDetails.workspaceRole -eq "Admin" }).Count

[PSCustomObject]@{
    CollectedAtUtc            = (Get-Date).ToUniversalTime()
    WorkspaceId                = $WorkspaceId
    WorkspaceName               = $workspaceRest.name
    WorkspaceType                = $workspaceRest.type
    RestReportedState             = $workspaceRest.state      # NOTE: will show "Active" even if orphaned
    ConfirmedOrphanedViaCmdlet     = [bool]$orphanCheck
    AdminCountFromAccessDetails     = $adminCount
    IsOrphanedByZeroAdminCheck       = ($adminCount -eq 0)
    CapacityId                        = $workspaceRest.capacityId
    DomainId                           = $workspaceRest.domainId
} | Format-List

Write-Host "`nNext steps if orphaned: Add-PowerBIWorkspaceUser -Scope Organization -Id $WorkspaceId -UserEmailAddress <upn> -AccessRight Admin" -ForegroundColor Yellow
Write-Host "If Deleted: check admin portal Workspaces list for the State column (portal shows the true 5-state model; REST does not)." -ForegroundColor Yellow
```

---

## Command Cheat Sheet

```powershell
# Connect
Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser -Force
Connect-PowerBIServiceAccount

# All orphaned workspaces tenant-wide (authoritative — prefer this over REST for bulk detection)
Get-PowerBIWorkspace -Scope Organization -Orphaned -All

# Assign a new Admin to an orphaned (or any) workspace
Add-PowerBIWorkspaceUser -Scope Organization -Id "<workspaceId>" -UserEmailAddress "<upn>" -AccessRight Admin

# Fabric REST Admin API — get one workspace (state field: Active/Deleted only, orphan-blind)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>" -Headers @{Authorization="Bearer $token"} -Method GET

# Fabric REST Admin API — list workspaces, filter by state (Deleted = in retention window)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces?state=Deleted" -Headers @{Authorization="Bearer $token"} -Method GET

# Fabric REST Admin API — role roster for one workspace (the pure-REST orphan-detection path)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>/users" -Headers @{Authorization="Bearer $token"} -Method GET

# Grant / remove 24h temporary admin access to an Active My workspace
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>/grantAdminTemporaryAccess" -Headers @{Authorization="Bearer $token"} -Method POST
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>/removeAdminTemporaryAccess" -Headers @{Authorization="Bearer $token"} -Method POST

# Restore a Deleted workspace (preview API; newWorkspaceName mandatory only for My workspace restores)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>/restore" -Headers @{Authorization="Bearer $token"} -Method POST -Body (@{newWorkspaceName="Contoso Workspace"; newWorkspaceAdminPrincipal=@{id="<userId>";type="User"}} | ConvertTo-Json)

# Rename / re-describe a workspace (core API — requires Admin workspace role, not tenant admin)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces/<workspaceId>" -Headers @{Authorization="Bearer $token"} -Method PATCH -Body (@{displayName="New Name"} | ConvertTo-Json)

# Change a role assignment (fails if targeting the last remaining Admin)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces/<workspaceId>/roleAssignments/<roleAssignmentId>" -Headers @{Authorization="Bearer $token"} -Method PATCH -Body (@{role="Contributor"} | ConvertTo-Json)

# Tenant-wide Networking Communication Policy read (paginated)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/networking/communicationpolicies" -Headers @{Authorization="Bearer $token"} -Method GET
```

Portal-only (no cmdlet/REST coverage):
- Admin portal → Tenant settings → Workspace settings → **Create workspaces** (current scope value has no API read)
- Admin portal → Workspaces → **Permanently delete** (no REST Admin API equivalent as of this writing)
- Admin portal → Workspaces → **Recover** (portal wrapper around assigning a new Admin to an orphaned workspace — the underlying `Add-PowerBIWorkspaceUser` path is the scriptable equivalent)

---

## 🎓 Learning Pointers

- **Workspace naming enforcement does not exist as a platform feature — the only real lever is restricting who can create workspaces in the first place.** Confirmed directly against the current Workspace tenant settings reference rather than assumed; scope any client naming-governance engagement as process-plus-audit, not "flip a setting." [Workspace tenant settings](https://learn.microsoft.com/en-us/fabric/admin/portal-workspace)
- **The REST Admin API's workspace `state` field cannot see orphaning — Microsoft's own schema documents "Orphaned workspaces are displayed as active."** Any automation built purely against the REST surface without accounting for this will silently miss every orphaned workspace in a state-filtered query. Use `Get-PowerBIWorkspace -Orphaned` or a zero-Admin roster derivation instead. [Get Workspace — REST API (Admin)](https://learn.microsoft.com/en-us/rest/api/fabric/admin/workspaces/get-workspace)
- **"Last Admin can't be changed" is a real but narrow guardrail — it only blocks the in-band role-assignment API, not the out-of-band Entra account removal that causes most real-world orphaning.** Don't assume this API protection means orphaning "shouldn't be possible"; it only closes one of two paths to the same outcome. [Update Workspace Role Assignment — REST API (Core)](https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/update-workspace-role-assignment)
- **My workspace retention (fixed 30 days) and collaborative workspace retention (configurable 7-90 days) are genuinely different numbers governed by different mechanisms.** Restoring a deleted My workspace is also a one-way conversion to a collaborative workspace type — get both facts right before advising a client on recovery timelines or restore consequences. [Set up and manage workspace retention](https://learn.microsoft.com/en-us/fabric/admin/workspace-retention)
- **`Grant`/`Remove Admin Temporary Access` and `Restore Workspace` (My workspace variant) solve two different problems that look similar — "I need into a departed employee's stuff."** The first works only while the workspace is still Active; the second only applies once it's Deleted. Confirm the `State` column before picking a tool, or the call fails with `EntityNotFound`. [Manage workspaces](https://learn.microsoft.com/en-us/fabric/admin/portal-workspaces)
- **Networking Communication Policy writes silently default every omitted `defaultAction` to `Allow`.** This is explicitly called out in Microsoft's own schema descriptions for every relevant field — always `GET` current policy and modify in place rather than constructing a partial payload from scratch. [List Networking Communication Policies — REST API (Admin)](https://learn.microsoft.com/en-us/rest/api/fabric/admin/workspaces/list-networking-communication-policies)
