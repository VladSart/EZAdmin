# Microsoft Fabric — Domains — Reference Runbook (Mode A: Deep Dive)
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

This is the deep-dive companion to `Domains-B.md`, which already covers day-to-day triage (domain-vs-access confusion, contributor/admin role boundaries, the reassignment-override gate, default-domain mechanics) at hotfix depth — this file does not repeat that content. Instead it covers three things an engineer building automation or investigating a governance incident actually needs:

1. **The data-mesh architecture rationale** behind why Fabric domains work the way they do, and — just as importantly — what a genuine data mesh implies that Fabric domains deliberately do *not* provide.
2. **The full Fabric REST Admin API domain-management surface** — object model, every domain and workspace-assignment operation, exact request/response schemas, rate limits, and the error codes that actually show up in scripts.
3. **The audit schema for domains** — the operation-name taxonomy Microsoft Purview's unified audit log and the Fabric activity log use to record every domain change, including two operations Microsoft's own reference documents as having undocumented property schemas.

**Assumes:** the reader is scripting against the REST Admin API (PowerShell `Invoke-RestMethod`, or any HTTP client) with a Fabric Administrator-scoped bearer token, or investigating a domain-related change via Purview Audit. Portal click-paths are intentionally not repeated here — see `Domains-B.md` for those.

**Does not cover:** the workspace-role/OneLake data-access-role chain that governs actual item visibility (`FabricAdmin-A.md`) — domains never affect it, by design, and that fact is treated as settled here rather than re-argued. Also does not cover domain-level sensitivity-label or certification *authoring* mechanics beyond the delegation model itself (see `Security/Purview/DSPM-for-AI-A.md` for label governance).

---

## How It Works

<details><summary>Full architecture — data mesh rationale and what Fabric domains actually implement</summary>

**Why "data mesh" at all.** The industry framing (Zhamak Dehghani's original data mesh model) rests on four principles: domain-oriented ownership, data-as-a-product, a self-serve data platform, and federated computational governance. The pitch is that centralized data teams become a bottleneck as an organization's data volume and business-unit count grow, so ownership (and the operational burden that comes with it) gets pushed out to the business domains that actually understand the data.

**What Fabric domains actually implement is a subset of that model — and Microsoft's own documentation is explicit about the boundary.** Domains give you:
- **Domain-oriented grouping** — workspaces (and everything inside them) get a `domainId` attribute, enabling filtering/discovery in the OneLake catalog by business area.
- **A thin slice of federated governance** — specific tenant-level settings (sensitivity-label default, certification) can be *delegated* to domain admins, letting each business unit configure those specific settings without needing Fabric-admin escalation for every change.

Domains do **not** give you:
- **Data-as-a-product contracts** — there's no concept of a formal, versioned data contract, SLA, or consumer-facing product boundary enforced by the platform. A domain is a label, not a governed API surface.
- **Automated computational governance** — assigning a workspace to a domain triggers zero automatic policy enforcement (no automatic classification, no automatic access review, no automatic quality gate). Every governance action still has to be manually configured elsewhere (Purview DLP/sensitivity labels, OneLake security roles, workspace-role assignment).
- **Any effect on data access** — this is the single most load-bearing fact in the whole topic (see `Domains-B.md` Triage) and it is fully consistent with the "why" here: Fabric's domain layer was scoped, deliberately, to discovery and delegated-settings governance only, not to access control. Building an access-control mental model on top of domains will always be wrong.

The practical consequence for MSP engineers: when a client asks for "a data mesh," clarify which of the four textbook pillars they actually need. If the ask is "let each department manage its own workspaces and see the data relevant to it," domains plus workspace roles cover it. If the ask is "enforce data contracts/SLAs between producing and consuming teams automatically," that's out of scope for Fabric domains as they exist today — it requires a separate governance process layered on top (or a different platform).

</details>

<details><summary>Full architecture — REST Admin API domain object model and operations</summary>

**The Domain object** is deliberately minimal — there is no `type` field distinguishing a domain from a subdomain:

| Field | Type | Notes |
|-------|------|-------|
| `id` | string (uuid) | Domain object ID |
| `displayName` | string | Max 40 characters; must be unique tenant-wide |
| `description` | string | Max 256 characters |
| `parentDomainId` | string (uuid) or `null` | **This is the only thing that makes something a "subdomain."** `null` = root domain, non-null = subdomain of that parent |
| `defaultLabelId` | string (uuid) | The domain's default sensitivity label, if the delegated-settings feature is enabled and configured |

**Create Domain** — `POST /v1/admin/domains?preview={preview}`
Body: `displayName` (required), `description`, `parentDomainId` (set this to create a subdomain instead of a root domain). Returns `201 Created` with the full Domain object. Rate limit: 25 requests/minute/principal.
- `EntityConflict` — `displayName` already exists tenant-wide (uniqueness is enforced across ALL domains, not just siblings under the same parent).
- `EntityNotFound` — `parentDomainId` doesn't exist (stale ID from a prior List Domains call, or the parent was deleted concurrently).
- `InvalidInput` — malformed `parentDomainId`.

**Update Domain** — `PATCH /v1/admin/domains/{domainId}?preview={preview}`
Body: `displayName`, `description`, `defaultLabelId` (set to the all-zero UUID `00000000-0000-0000-0000-000000000000` to explicitly remove a default label — omitting the field leaves the existing label untouched, it does not clear it). Rate limit: 25/min.

**The `preview` query parameter is not optional in practice, despite reading as a toggle.** Both Create and Update Domain are documented as "a release version of a preview version due to be deprecated" — Microsoft's own docs state callers **must** set `preview=false` to reach the current, supported release surface. Any script copy-pasted from older sample code that omits the query parameter, or that was written against the original preview endpoint, is targeting the surface actively being sunset. Always pass `?preview=false` explicitly.

**Workspace assignment has three independent REST paths**, mirroring the three portal methods (by name, by workspace admin, by capacity) but with materially different execution models:

| Operation | Endpoint | Execution | Rate limit |
|-----------|----------|-----------|-------------|
| Assign Domain Workspaces By Ids | `POST /v1/admin/domains/{domainId}/assignWorkspaces` | **Synchronous** — `200 OK` means done | 10/min |
| Assign Domain Workspaces By Capacities | `POST /v1/admin/domains/{domainId}/assignWorkspacesByCapacities` | **Asynchronous LRO** — `202 Accepted` with `Location`/`x-ms-operation-id`/`Retry-After` headers; must be polled | 10/min |
| Assign Domain Workspaces By Principals | `POST /v1/admin/domains/{domainId}/assignWorkspacesByPrincipals` | Asynchronous LRO (preview), assigns any workspace where a listed principal holds the workspace Admin role | 10/min |

The portal's "assign by workspace name" method resolves names to workspace IDs client-side, then calls the By-Ids endpoint underneath — there is no separate by-name REST operation.

**Every one of the three assignment operations silently obeys the same tenant-level override gate as the portal.** `Preexisting domain assignments will be overridden unless bulk reassignment is blocked by domain management tenant settings` is stated verbatim in the By-Ids and By-Capacities API references. This means a script can receive `200 OK` (or `202 Accepted`, then a successfully-completed LRO) and the workspace's domain assignment will nonetheless be unchanged if **"Allow tenant and domain admins to override workspace assignments (preview)"** is disabled tenant-wide. There is no error, warning header, or partial-success flag distinguishing "assignment applied" from "assignment silently skipped because it already had a domain." Always re-read the workspace's `domainId` after an assignment call in any script that must guarantee the move happened — do not trust the HTTP status code alone.

**Role Assignments Bulk Assign** — `POST /v1/admin/domains/{domainId}/roleAssignments/bulkAssign`
Body: `type` (`DomainRole` enum — `Admin` or `Contributor`), `principals[]` (a discriminated union: `UserPrincipal`, `GroupPrincipal`, `ServicePrincipalPrincipal`, `ServicePrincipalProfilePrincipal`, or `EntireTenantPrincipal`, each with `id`/`displayName`/`type`). Rate limit: 25/min. A mirror `roleAssignments/bulkUnassign` operation exists for rollback.
- `UnsupportedPrincipalTypeForDomainAdminAssignment` — the error's existence confirms the **Admin** role has narrower principal-type support than **Contributor**. Microsoft's public schema lists all five principal types as valid for the request body generically, but this error code is specific to Admin-role assignment attempts — treat any bulk-assign-as-Admin script against a Group or Service Principal as unverified until tested against your tenant, and prefer assigning individual User principals as Domain Admins.
- `PrincipalWithDomainRoleAssignmentAlreadyExists` — the operation is not idempotent; re-running a bulk-assign against a principal already holding that role fails rather than no-op succeeding. Always call **List Role Assignments** first and diff before assigning in any repeatable script.

**List operations** — `GET /v1/admin/domains` (all domains), `GET /v1/admin/domains/{domainId}/workspaces` (workspaces in a domain), `GET /v1/admin/domains/{domainId}/roleAssignments` (admins/contributors). All three are the read-side complement to the write operations above and carry no destructive risk — use them liberally to verify state before and after any write call, given the silent-no-op behavior described above.

</details>

<details><summary>Full architecture — audit schema and what it does (and doesn't) capture</summary>

Every domain create/edit/delete is recorded in the Fabric activity log and surfaced through **Microsoft Purview Audit** (`compliance.microsoft.com/auditlogsearch`) using a consistent `OperationName` / `OperationProperties` (JSON) model, searchable by operation name.

| Activity | OperationName | Key OperationProperties |
|----------|---------------|--------------------------|
| Create domain/subdomain | `InsertDataDomainAsAdmin` | `DataDomainObjectId`, `DataDomainDisplayName`, `ParentObjectId?` |
| Delete domain/subdomain | `DeleteDataDomainAsAdmin` | Same three fields |
| Update domain/subdomain | `UpdateDataDomainAsAdmin` | Same three fields |
| Assign/unassign workspace (as Fabric admin) | `UpdateDataDomainFoldersRelationsAsAdmin` | + `FoldersToSetCounter?`, `FoldersToUnsetCount?` |
| Unassign ALL workspaces from a domain | `DeleteAllDataDomainFoldersRelationsAsAdmin` | `DataDomainObjectId`, `DataDomainDisplayName`, `ParentObjectId?` |
| Assign/unassign workspace (as domain contributor) | `UpdateDataDomainFoldersRelationsAsContributor` | Same as the admin variant |
| Workspace owner removes domain from their own workspace settings | `DeleteDataDomainFolderRelationsAsFolderOwner` | + `FolderId?` |
| Bulk assign by workspace owner (initiate/process) | `BulkAssignDataDomainByWsOwnersAsAdmin` | **Undocumented in Microsoft's own reference** (marked with `?`) |
| Bulk assign by capacity (initiate/process) | `BulkAssignDataDomainByCapacitiesAsAdmin` | **Undocumented in Microsoft's own reference** (marked with `?`) |
| Add/remove/update domain admin or contributor | `UpdateDataDomainAccessAsAdmin` | + `Value` (role enum, see below), `UsersToSetCounter?/UsersToUnsetCounter?`, `GroupsToSetCounter?/GroupsToUnsetCounter?` |
| Change default-domain assignment | `UpdateDefaultDataDomainAsAdmin` | + `UsersToSetCounter?/UsersToUnsetCounter?`, `GroupsToSetCounter?/GroupsToUnsetCounter?` |
| Change contributor scope | `UpdateDataDomainContributorsScopeAsAdmin` | + `Value` (scope enum, see below) |
| Set/remove domain image | `UpdateDataDomainBrandingAsAdmin` | + `Value` (branding ID) |
| Delegated tenant-setting change at domain level | `UpdateDomainTenantSettingDelegation` | Schema not published |

**Two encoded `Value` enums are non-obvious and worth memorizing rather than guessing from the raw number:**
- `UpdateDataDomainAccessAsAdmin.Value`: `0` = None, `7` = Contributor, `15` = Admin. These are **not** sequential small integers — `7` is `0b0111` and `15` is `0b1111`, consistent with a bit-flag design even though only two non-zero roles currently exist. Don't assume `1`/`2` when building a KQL query filter against this field.
- `UpdateDataDomainContributorsScopeAsAdmin.Value`: `0` = AllTenant, `1` = SpecificUsersAndGroups, `2` = AdminsOnly. These three map directly to the "Contributors" tab options in the portal (see `Domains-B.md` Fix 2 context) — a domain with scope `0` (AllTenant, the default) means literally any workspace admin in the tenant can self-assign their workspace as a contributor, regardless of what the domain's role-assignment list shows.

**The two undocumented bulk-assignment operations are a genuine gap in Microsoft's own reference, not a mistake in this file.** If an audit search turns up `BulkAssignDataDomainByWsOwnersAsAdmin` or `BulkAssignDataDomainByCapacitiesAsAdmin` with sparse or unclear `OperationProperties`, that matches Microsoft's own documented state as of this writing — don't spend time trying to reverse-engineer a schema Microsoft itself hasn't published. Instead, correlate the audit entry's timestamp and actor against a direct **List Domain Workspaces** call to establish ground truth about what actually changed.

</details>

---

## Dependency Stack

```
Layer 5 — Data mesh outcome (discovery + delegated governance only)
    OneLake catalog domain filter | domain-scoped sensitivity-label/certification defaults
    └── NOT a data contract layer, NOT automated computational governance —
        both require separate tooling (Purview DLP, manual review process)

Layer 4 — Workspace-domain association (metadata only)
    Workspace.domainId attribute | propagates to every item in the workspace
    └── Governs OneLake catalog filtering/discovery ONLY — explicitly orthogonal
        to Layer 2/3 workspace-role and item-permission access chain (FabricAdmin-A.md)

Layer 3 — Workspace assignment operations (3 independent REST paths, 1 shared gate)
    assignWorkspaces (sync, by ID) | assignWorkspacesByCapacities (async LRO) |
    assignWorkspacesByPrincipals (async LRO, preview)
    └── ALL gated by the same tenant setting: "Allow tenant and domain admins to
        override workspace assignments" — silently no-ops existing assignments
        if disabled, with NO error or warning in the response

Layer 2 — Domain roles (independent of workspace roles)
    Fabric Administrator (tenant-wide, unrestricted)
        └── Domain Admin — role type "Admin"; narrower principal-type support
             (UnsupportedPrincipalTypeForDomainAdminAssignment exists for a reason)
                └── Domain Contributor — role type "Contributor"; broader principal-type
                     support, but STILL requires the same principal to independently
                     hold the Workspace Admin role to actually assign that workspace

Layer 1 — Domain object model
    Domain { id, displayName (≤40 chars, tenant-unique), description (≤256 chars),
             parentDomainId, defaultLabelId }
    └── parentDomainId is the ONLY thing distinguishing a subdomain from a root
        domain — there is no separate "type" field or API surface

Layer 0 — Identity + auth
    Microsoft Entra ID — user/group/service-principal resolution
    └── Fabric REST Admin API — Fabric Administrator role (or delegated
        Tenant.ReadWrite.All scope for a service principal) required for every
        domain-management call in this file

Orthogonal — Observability (reads everything above, gates nothing)
    Fabric activity log + Microsoft Purview unified audit log
        └── OperationName + OperationProperties JSON per domain change
                └── 2 of ~13 documented operations have undocumented property
                    schemas as of this writing (bulk-assign by owner / by capacity)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Create/Update Domain call fails or silently targets old behavior | Missing or incorrect `preview` query parameter — the release endpoint requires `preview=false` explicitly | Confirm the request URL includes `?preview=false` |
| `assignWorkspaces`/`assignWorkspacesByCapacities` returns success but the workspace's domain didn't change | "Allow tenant and domain admins to override workspace assignments" tenant setting is disabled — the API enforces the same silent-no-op gate as the portal | Re-GET the workspace and check `domainId` after every assignment call; don't trust the HTTP status alone |
| `assignWorkspacesByCapacities` or `assignWorkspacesByPrincipals` script "hangs" or the caller assumes it failed | Treating an LRO as synchronous — a `202 Accepted` means in-progress, not done | Poll the `Location` URL / `x-ms-operation-id` until the operation status is terminal |
| Role Assignments Bulk Assign fails with `UnsupportedPrincipalTypeForDomainAdminAssignment` | Attempting to assign a principal type (Group/Service Principal) to the **Admin** role that the API doesn't support for that specific role | Retry with a User principal for Admin; use Contributor for broader principal-type needs |
| Role Assignments Bulk Assign fails with `PrincipalWithDomainRoleAssignmentAlreadyExists` | The operation is not idempotent — script re-ran against an already-assigned principal | Call List Role Assignments first, diff the target list, only assign the delta |
| Create Domain fails with `EntityConflict` | `displayName` collides with an existing domain — uniqueness is tenant-wide, not scoped to siblings under the same parent | GET List Domains first, confirm the name isn't already in use anywhere in the tenant |
| Create Domain (subdomain) fails with `EntityNotFound` | `parentDomainId` is stale — parent was deleted, or the ID came from a cached/older List Domains response | Re-fetch List Domains immediately before create, use the fresh parent ID |
| `429 Too Many Requests` on workspace-assignment calls specifically, but not on domain CRUD | Different rate-limit tiers: workspace assignment = 10 req/min, domain CRUD and role assignment = 25 req/min | Batch workspace IDs into fewer, larger `assignWorkspaces` calls rather than looping per-workspace |
| Audit search for a bulk domain-assignment activity shows the `OperationName` but the `OperationProperties` are sparse or unclear | Two bulk-assignment operations have undocumented property schemas in Microsoft's own reference | Don't rely on `OperationProperties` for these two; cross-check via List Domain Workspaces instead |
| Investigating "who set contributor scope to Admins Only" and the audit `Value` field doesn't match an assumed boolean | `UpdateDataDomainContributorsScopeAsAdmin.Value` is a 3-value enum (0/1/2 = AllTenant/SpecificUsersAndGroups/AdminsOnly), not a boolean | Parse `Value` against the 3-entry enum, not as true/false |
| A Contributor-scope of "AllTenant" means workspace admins are assigning workspaces to a domain nobody explicitly authorized | Expected — `AllTenant` (the default) means any workspace admin tenant-wide can act as a de facto contributor, regardless of the domain's role-assignment list | Confirm the contributor scope setting before treating an unexpected assignment as a security incident |

---

## Validation Steps

1. **Confirm caller identity has the required access.** Call `GET /v1/admin/domains` with the bearer token. Expected: `200 OK` with a JSON array of domains. Bad: `401`/`403` — the token's principal isn't a Fabric Administrator (or, for a service principal, doesn't have the `Tenant.ReadWrite.All` delegated scope).

2. **List all domains and confirm the parent/subdomain structure.** `GET /v1/admin/domains`. Expected: every domain object includes `id`/`displayName`/`description`/`parentDomainId`/`defaultLabelId`; subdomains are distinguishable only by a non-null `parentDomainId`. Bad: an expected subdomain shows `parentDomainId: null` — it was created as a root domain by mistake.

3. **Confirm the `preview=false` flag on any Create/Update call before running it.** Bad: a request built from older sample code that omits the `preview` query parameter, or hardcodes `true`.

4. **List workspaces for the target domain and confirm actual state.** `GET /v1/admin/domains/{domainId}/workspaces`. Expected: the workspace IDs you intended to assign are present. Bad: an expected workspace is missing immediately after an assignment call returned success — check the override tenant setting (Symptom→Cause row 2) before assuming the API call failed silently for another reason.

5. **Poll an in-flight `assignWorkspacesByCapacities` or `assignWorkspacesByPrincipals` LRO to completion.** `GET` the `Location` URL returned in the `202` response headers. Expected: operation status transitions to a terminal `Succeeded` state within a reasonable window. Bad: stuck in a non-terminal state for several minutes — verify the submitted capacity/principal IDs are valid and current.

6. **List role assignments and cross-check against the contributor-scope setting.** `GET /v1/admin/domains/{domainId}/roleAssignments`. Expected: returned Admin/Contributor principals match intent. Important: also check the domain's contributor-scope setting (`AllTenant`/`SpecificUsersAndGroups`/`AdminsOnly`) via the portal or `UpdateDataDomainContributorsScopeAsAdmin` audit history — an `AllTenant` scope means the role-assignment list is not the full picture of who can act as a contributor.

7. **Search Purview unified audit log for the domain's object ID and confirm API-driven changes are captured identically to portal-driven ones.** Search `compliance.microsoft.com/auditlogsearch` by `DataDomainObjectId`. Expected: every Create/Update/Delete/assign call made via the REST API produces the same `OperationName`/`OperationProperties` entries as the equivalent portal action — validates the audit trail has no API-specific blind spot (aside from the two documented undocumented-schema bulk operations).

---

## Troubleshooting Steps (by phase)

**Phase 1 — Discovery (before any write)**
- Confirm the caller's Fabric Administrator role (or delegated scope) with a harmless read call (`List Domains`).
- Pull the current domain list and role-assignment list for any domain you're about to modify — never write against assumed/cached state.

**Phase 2 — Read (establish ground truth)**
- `List Domains`, `List Domain Workspaces`, `List Role Assignments` — all three are safe, side-effect-free, and should be the first calls in any script or investigation, not the last.
- If investigating a reported discrepancy, do the read pass **before** touching the audit log — comparing current API state against what the ticket describes narrows the search before you start parsing `OperationProperties` JSON.

**Phase 3 — Write (apply the change)**
- Domain CRUD (Create/Update/Delete) and Role Assignment Bulk Assign/Unassign: 25 requests/minute/principal.
- Workspace assignment (all three methods): 10 requests/minute/principal — batch IDs into fewer calls rather than looping.
- Always include `preview=false` on Create/Update Domain calls.
- Expect `PrincipalWithDomainRoleAssignmentAlreadyExists` and `UnsupportedPrincipalTypeForDomainAdminAssignment` as normal script-flow errors to handle, not exceptional failures — build retry/skip logic around them rather than treating them as fatal.

**Phase 4 — Verify (confirm the write actually took effect)**
- Re-run the Phase 2 read calls after every write. This is not optional given the documented silent-no-op behavior on workspace assignment when the override tenant setting is disabled.
- For LRO-based calls (`assignWorkspacesByCapacities`, `assignWorkspacesByPrincipals`), poll to a terminal state before declaring success — a `202 Accepted` is not evidence of completion.

**Phase 5 — Record**
- If the change was made on behalf of a client/ticket, capture the before/after state (Phase 2 read output) alongside the audit-log entry, since two bulk-assignment operations don't carry a fully documented property schema and the read-call snapshot may be the more reliable record.

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Scripted bulk domain provisioning from a list (root domains + subdomains)</summary>

1. Call `List Domains` first and build a set of existing `displayName` values — `EntityConflict` is tenant-wide, not per-parent, so a subdomain name that's fine under one parent can still collide with an unrelated root domain elsewhere in the tenant.
2. Create root domains first, in a loop respecting the 25 req/min limit (batch with a short sleep, or queue and retry on `429` using the `Retry-After` header).
3. Capture each newly created domain's `id` from the `201` response body — do not re-list domains to find the ID you just created; use the response directly to avoid a race if another process is creating domains concurrently.
4. Create subdomains using the captured parent IDs from step 3, not IDs looked up from a stale in-memory cache.
5. Verify with a final `List Domains` pass, confirming `parentDomainId` values match intent for every subdomain.

**Rollback:** `DELETE /v1/admin/domains/{domainId}` for any domain created in error (deletes subdomains under it too — confirm this is intended before deleting a parent with children).
</details>

<details>
<summary>Playbook 2 — Migrating manual portal-based workspace assignment to a scripted REST-API process</summary>

1. Before scripting anything, explicitly check and record the current state of **"Allow tenant and domain admins to override workspace assignments (preview)"** — the script's behavior on already-assigned workspaces depends entirely on this setting, and it will not surface as an error either way.
2. If the intent is to move already-assigned workspaces to new domains as part of the migration, enable the override setting first, and note it in change documentation as a deliberate, temporary change (see `Domains-B.md` Fix 3 rollback guidance — consider disabling it again once migration is complete to prevent future accidental overrides).
3. Resolve workspace names to IDs client-side (the portal's "by name" method has no direct REST equivalent), then call `assignWorkspaces` (By-Ids) in batches within the 10 req/min limit.
4. For capacity-based bulk moves, prefer `assignWorkspacesByCapacities` over iterating workspace IDs individually — it's a single LRO call per capacity rather than N synchronous calls, reducing rate-limit pressure.
5. Verify every migrated workspace's `domainId` via `List Domain Workspaces` per target domain — do not rely on the assignment call's status code as proof of the move.

**Rollback:** re-run the same assignment calls pointing at each workspace's original `domainId` (captured in step 3's inventory before any writes) — there is no built-in "undo," so capture original state before migrating.
</details>

<details>
<summary>Playbook 3 — Recovering from an accidental bulk role unassignment</summary>

1. Confirm via `List Role Assignments` (or the Purview audit search for `UpdateDataDomainAccessAsAdmin` with `Value` transitioning to `0`/None) exactly which principals lost Admin or Contributor status and when.
2. Cross-reference the audit entry's actor and timestamp — `UpdateDataDomainAccessAsAdmin` records `UsersToUnsetCounter`/`GroupsToUnsetCounter`, confirming how many principals were affected in the same operation, useful for confirming scope before restoring.
3. Re-assign the affected principals using `Role Assignments Bulk Assign` with `type` matching their prior role — expect `PrincipalWithDomainRoleAssignmentAlreadyExists` only if some principals were only partially unassigned; treat that error as confirmation the principal already has the role, not a failure to fix.
4. If any of the previously-assigned principals were Groups or Service Principals being restored to the **Admin** role, test one call in isolation first — the `UnsupportedPrincipalTypeForDomainAdminAssignment` error means the restoration may need to target the Contributor role instead, which is a governance decision, not purely a technical rollback.

**Rollback of the rollback:** none needed — this playbook only restores prior state; if the restoration itself was wrong, repeat the process with the correct principal/role list.
</details>

<details>
<summary>Playbook 4 — Building a Purview audit query for domain governance change tracking</summary>

1. Search `compliance.microsoft.com/auditlogsearch` filtered to the domain-related `OperationName` values in the audit schema table above — start broad (all 13 operation names) for a full governance timeline, then narrow to specific operations once the shape of the change history is understood.
2. For access/role changes specifically, filter to `UpdateDataDomainAccessAsAdmin` and parse the `Value` field against the bit-flag-style enum (`0`=None, `7`=Contributor, `15`=Admin) — do not build a report that assumes sequential small integers.
3. For contributor-scope changes, filter to `UpdateDataDomainContributorsScopeAsAdmin` and parse `Value` against the 3-entry enum (`0`=AllTenant, `1`=SpecificUsersAndGroups, `2`=AdminsOnly) — a report showing scope `0` for a domain should be flagged for review if the client's governance policy expects controlled contributor membership.
4. Explicitly exclude or flag `BulkAssignDataDomainByWsOwnersAsAdmin` and `BulkAssignDataDomainByCapacitiesAsAdmin` entries as "properties undocumented" in any automated report, rather than silently showing blank/null fields that could be misread as "nothing happened."
5. Cross-reference the resulting timeline against a `List Domains`/`List Domain Workspaces` snapshot taken at report-generation time, to catch drift between what the audit log recorded and current live state (useful when investigating whether a later, undocumented change reversed an earlier documented one).

</details>

---

## Evidence Pack

```powershell
<#
  Domain governance escalation evidence collector — read-only.
  Requires: a bearer token for a principal holding the Fabric Administrator role
  (or Tenant.ReadWrite.All delegated scope for a service principal).
  For routine fleet-wide auditing, prefer Scripts/Get-FabricDomainAudit.ps1 in this
  folder — this block is a lightweight, single-domain escalation snapshot.
#>
param(
    [Parameter(Mandatory)][string]$Token,
    [Parameter(Mandatory)][string]$DomainId
)

$headers = @{ Authorization = "Bearer $Token" }
$base    = "https://api.fabric.microsoft.com/v1/admin/domains"

$domain      = Invoke-RestMethod -Uri "$base/$DomainId" -Headers $headers -Method GET -ErrorAction SilentlyContinue
$allDomains  = Invoke-RestMethod -Uri $base -Headers $headers -Method GET
$workspaces  = Invoke-RestMethod -Uri "$base/$DomainId/workspaces" -Headers $headers -Method GET
$roles       = Invoke-RestMethod -Uri "$base/$DomainId/roleAssignments" -Headers $headers -Method GET

[PSCustomObject]@{
    CollectedAtUtc        = (Get-Date).ToUniversalTime()
    DomainId              = $DomainId
    DomainDisplayName     = ($allDomains.value | Where-Object id -eq $DomainId).displayName
    ParentDomainId        = ($allDomains.value | Where-Object id -eq $DomainId).parentDomainId
    IsSubdomain           = [bool]($allDomains.value | Where-Object id -eq $DomainId).parentDomainId
    WorkspaceCount        = $workspaces.value.Count
    WorkspaceIds          = ($workspaces.value.id -join "; ")
    AdminPrincipals       = ($roles.value | Where-Object role -eq "Admin").displayName -join "; "
    ContributorPrincipals = ($roles.value | Where-Object role -eq "Contributor").displayName -join "; "
} | Format-List

Write-Host "`nNext: cross-reference against Purview Audit (compliance.microsoft.com/auditlogsearch)" -ForegroundColor Yellow
Write-Host "search DataDomainObjectId = $DomainId across the OperationName values listed in Domains-A.md's audit schema table." -ForegroundColor Yellow
```

---

## Command Cheat Sheet

```powershell
# List all domains
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains" -Headers @{Authorization="Bearer $token"} -Method GET

# Create a root domain (note: preview=false is required, not optional)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains?preview=false" -Headers @{Authorization="Bearer $token"} -Method POST -Body (@{displayName="Finance"; description="Financial data and reports"} | ConvertTo-Json)

# Create a subdomain under an existing domain
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains?preview=false" -Headers @{Authorization="Bearer $token"} -Method POST -Body (@{displayName="Payroll"; parentDomainId="<parentDomainId>"} | ConvertTo-Json)

# Update a domain's name/description/default label
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains/<domainId>?preview=false" -Headers @{Authorization="Bearer $token"} -Method PATCH -Body (@{displayName="New Name"} | ConvertTo-Json)

# Remove a domain's default sensitivity label (set to the all-zero UUID)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains/<domainId>?preview=false" -Headers @{Authorization="Bearer $token"} -Method PATCH -Body (@{defaultLabelId="00000000-0000-0000-0000-000000000000"} | ConvertTo-Json)

# Delete a domain (and any subdomains under it)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains/<domainId>?preview=false" -Headers @{Authorization="Bearer $token"} -Method DELETE

# List workspaces assigned to a domain
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains/<domainId>/workspaces" -Headers @{Authorization="Bearer $token"} -Method GET

# Assign workspaces to a domain by ID (synchronous)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains/<domainId>/assignWorkspaces" -Headers @{Authorization="Bearer $token"} -Method POST -Body (@{workspacesIds=@("<wsId1>","<wsId2>")} | ConvertTo-Json)

# Assign all workspaces on given capacities to a domain (async LRO — poll the Location header)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains/<domainId>/assignWorkspacesByCapacities" -Headers @{Authorization="Bearer $token"} -Method POST -Body (@{capacitiesIds=@("<capacityId>")} | ConvertTo-Json)

# List current domain role assignments (admins + contributors)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains/<domainId>/roleAssignments" -Headers @{Authorization="Bearer $token"} -Method GET

# Bulk-assign domain admins
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains/<domainId>/roleAssignments/bulkAssign" -Headers @{Authorization="Bearer $token"} -Method POST -Body (@{type="Admins"; principals=@(@{id="<userId>"; type="User"})} | ConvertTo-Json -Depth 5)

# Bulk-assign domain contributors
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains/<domainId>/roleAssignments/bulkAssign" -Headers @{Authorization="Bearer $token"} -Method POST -Body (@{type="Contributors"; principals=@(@{id="<groupId>"; type="Group"})} | ConvertTo-Json -Depth 5)

# Bulk-unassign (rollback of the above)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains/<domainId>/roleAssignments/bulkUnassign" -Headers @{Authorization="Bearer $token"} -Method POST -Body (@{type="Contributors"; principals=@(@{id="<groupId>"; type="Group"})} | ConvertTo-Json -Depth 5)
```

---

## 🎓 Learning Pointers

- **"Data mesh" is a specific four-pillar architecture, and Fabric domains implement roughly one and a half of the pillars.** You get domain-oriented grouping and a thin slice of federated governance (delegated settings); you do not get data-as-a-product contracts or automated computational governance. When a client's ask implies the fuller model, say so explicitly rather than letting "we have domains configured" imply more than it does. [Fabric domains](https://learn.microsoft.com/en-us/fabric/governance/domains)
- **The REST Admin API enforces the exact same silent-no-op override behavior as the portal — automation doesn't get an exemption or an error message.** Any script that assigns workspaces to domains must re-read state after writing, every time, because a `200`/`202` success response carries no information about whether the tenant-level override gate actually let the change through. This is the single most consequential fact for anyone building Fabric domain automation.
- **`preview=false` is a required parameter on a "release" endpoint, not a toggle you can omit.** Both Create Domain and Update Domain are explicitly documented as still-transitioning off a preview surface (deprecation dated March 31, 2026) — treat any sample code omitting the query parameter as out of date. [Update Domain API](https://learn.microsoft.com/en-us/rest/api/fabric/admin/domains/update-domain)
- **Two `Value` fields in the audit schema are enums that look like arbitrary numbers if you don't know the mapping** — `UpdateDataDomainAccessAsAdmin` (`0`/`7`/`15` = None/Contributor/Admin, bit-flag-shaped) and `UpdateDataDomainContributorsScopeAsAdmin` (`0`/`1`/`2` = AllTenant/SpecificUsersAndGroups/AdminsOnly). Build any audit-log parsing against the documented enum, never against an assumption of sequential small integers. [Audit schema for domains](https://learn.microsoft.com/en-us/fabric/governance/domains-audit-schema)
- **Two audit operations (`BulkAssignDataDomainByWsOwnersAsAdmin`, `BulkAssignDataDomainByCapacitiesAsAdmin`) have undocumented property schemas in Microsoft's own reference as of this writing.** Don't burn time reverse-engineering them from sparse log output — cross-reference the domain's live state via `List Domain Workspaces` instead, which is authoritative regardless of what the audit properties happen to contain.
- **Role-assignment errors are part of normal script flow, not exceptional failures.** `PrincipalWithDomainRoleAssignmentAlreadyExists` means your automation isn't idempotent yet (fix by listing before assigning); `UnsupportedPrincipalTypeForDomainAdminAssignment` means the principal type you're assigning doesn't fit the Admin role specifically — both are documented, expected outcomes worth handling in code rather than alerting on.
