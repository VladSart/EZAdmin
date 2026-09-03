# PIM Iteration 2 (Beta) API Retirement — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Context:** Microsoft Entra Privileged Identity Management (PIM) "Iteration 2" beta APIs — the `/beta/privilegedAccess/aadRoles` and `/beta/privilegedAccess/azureResources` endpoints — stop returning data on **October 28, 2026**. Any script, scheduled task, Logic App, Power Automate flow, or third-party integration still calling these endpoints will start failing that day with no advance per-call warning beyond the retirement date itself. Source: [MC1181281 — Message Center archive](https://mc.merill.net/message/MC1181281) (published 2025-10-29, act-by 2026-10-28); [Privileged Identity Management iteration 2 APIs](https://learn.microsoft.com/en-us/graph/api/resources/privilegedidentitymanagement-root?view=graph-rest-beta); [API concepts in Privileged Identity Management](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-apis) (ms.date 2026-04-23).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

```powershell
# 1. Find app registrations / service principals holding legacy PIM iteration-2 permissions —
#    the strongest available proxy signal, since Graph exposes no per-endpoint call telemetry.
$legacyScopes = 'PrivilegedAccess.Read.AzureAD','PrivilegedAccess.ReadWrite.AzureAD',
                 'PrivilegedAccess.Read.AzureResources','PrivilegedAccess.ReadWrite.AzureResources'

Get-MgServicePrincipal -All | ForEach-Object {
    $sp = $_
    Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -ErrorAction SilentlyContinue |
        Where-Object { $legacyScopes -contains (Get-MgServicePrincipalAppRole -ServicePrincipalId $sp.Id -AppRoleId $_.AppRoleId -ErrorAction SilentlyContinue).Value } |
        Select-Object @{n='App';e={$sp.DisplayName}}, @{n='AppId';e={$sp.AppId}}
}

# 2. Grep your own automation source (scripts, Logic Apps exports, Power Automate flow JSON,
#    Terraform/Bicep) for the literal deprecated endpoint paths:
#      /beta/privilegedAccess/aadRoles
#      /beta/privilegedAccess/azureResources
#      governanceRoleAssignmentRequest | governanceRoleDefinition | governanceRoleSetting | governanceResource
```

| Observation | Meaning | Do |
|---|---|---|
| A service principal holds `PrivilegedAccess.*` legacy scopes and your source-code grep finds `/beta/privilegedAccess/...` calls | Confirmed Iteration 2 caller — will break Oct 28, 2026 | Go to [Fix 1](#fix-1) |
| Source grep finds `unifiedRoleAssignmentScheduleRequest`, `unifiedRoleEligibilityScheduleRequest`, or Azure Resource Manager `roleEligibilityScheduleRequests` calls | Already on Iteration 3 (GA) — not affected | No action; confirm no *mixed* legacy calls remain |
| No legacy scopes found, no legacy endpoint hits in source | Tenant likely unaffected, or automation isn't inventoried yet | Broaden search to Logic Apps / Power Automate / Azure Automation runbooks — see [Diagnosis step 3](#diagnosis--validation-flow) |
| Ticket describes a working integration suddenly returning empty results or 404s starting late Oct 2026 | Textbook post-retirement symptom | Go to [Fix 1](#fix-1) immediately — this is time-critical, not degrading gracefully |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
PIM API history (non-linear — NOT a simple v1→v2→v3 progression)
  Iteration 1 (/beta/privilegedRoles) — retired June 2021, Entra roles only
  Iteration 2 (/beta/privilegedAccess/{aadRoles,azureResources}) — DEPRECATED,
        stops returning data 2026-10-28
        └─ requires legacy Graph permissions: PrivilegedAccess.Read/ReadWrite.AzureAD,
           PrivilegedAccess.Read/ReadWrite.AzureResources
        └─ resources: governanceRoleAssignmentRequest, governanceRoleDefinition,
           governanceRoleSetting, governanceResource
  Iteration 3 (current, GA) — the only supported path after 2026-10-28
        ├─ PIM for Microsoft Entra roles  → Microsoft Graph
        │     (unifiedRoleAssignmentScheduleRequest / unifiedRoleEligibilityScheduleRequest)
        ├─ PIM for Azure resources        → Azure Resource Manager REST API
        │     (roleEligibilityScheduleRequests / roleAssignmentScheduleRequests —
        │      NOT Microsoft Graph; different auth audience/permission model entirely)
        └─ PIM for Groups                 → Microsoft Graph
              (privilegedAccessGroupAssignmentScheduleRequest / ...EligibilityScheduleRequest)
```
The critical trap: Iteration 3 for **Azure resources** moved off Microsoft Graph entirely onto Azure Resource Manager's own REST API — a migration is not just "call a newer Graph endpoint," it's a different API surface, different base URL, and potentially different auth scope/consent setup.
</details>

---
## Diagnosis & Validation Flow

1. **Confirm which provider(s) are affected** — Entra roles, Azure resources, or Groups. Iteration 2 only ever covered Entra roles (`aadRoles`) and Azure resources (`azureResources`); PIM for Groups was never part of Iteration 2, so a Groups-only integration is not in scope for this retirement.

2. **Search all automation surfaces, not just PowerShell scripts.** Iteration 2 calls commonly hide in:
   - Power Automate flows (HTTP / Graph connector actions)
   - Azure Logic Apps (HTTP action or Graph connector)
   - Azure Automation runbooks
   - Third-party ITSM/GRC tooling with custom Graph integrations
   - Internal dashboards or reporting scripts built years ago and rarely touched
   ```powershell
   # Power Automate / Logic Apps often aren't visible to PowerShell-based grep —
   # export flow definitions and search the JSON directly:
   #   Get-Content flow_definition.json | Select-String 'privilegedAccess/(aadRoles|azureResources)'
   ```

3. **Check permission consent history.** If `PrivilegedAccess.*` (legacy) scopes were granted years ago and never revisited, that's a strong signal of an Iteration 2 dependency even if nobody remembers writing the integration.
   ```powershell
   Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId <spId> |
       Select-Object AppRoleId, CreatedDateTime, PrincipalDisplayName
   ```

4. **For Azure resources specifically, confirm the target API family.** A call to `graph.microsoft.com/beta/privilegedAccess/azureResources/...` is Iteration 2 (breaking). A call to `management.azure.com/.../providers/Microsoft.Authorization/roleEligibilityScheduleRequests` is already Iteration 3/ARM (safe).

5. **Validate against the resource type, not just the URL path**, since some tooling wraps the raw endpoint: look for `governanceRoleAssignmentRequest`, `governanceRoleDefinition`, `governanceRoleSetting`, or `governanceResource` object/type names in code — these are Iteration-2-only resource types with no Iteration 3 equivalent by that name.

---
## Common Fix Paths

<details><summary>Fix 1 — Migrate an Entra-roles integration to Iteration 3 (Microsoft Graph)</summary>

Iteration 3 for Microsoft Entra roles stays on Microsoft Graph but uses different resource types and a different permission model (supports app-only permissions, which Iteration 2 for Entra roles largely didn't).

| Old (Iteration 2) | New (Iteration 3) |
|---|---|
| `governanceRoleAssignmentRequest` (POST to create) | [`unifiedRoleAssignmentScheduleRequest`](https://learn.microsoft.com/en-us/graph/api/resources/unifiedroleassignmentschedulerequest) (active) / [`unifiedRoleEligibilityScheduleRequest`](https://learn.microsoft.com/en-us/graph/api/resources/unifiedroleeligibilityschedulerequest) (eligible) |
| `governanceRoleAssignment` (list) | `unifiedRoleAssignmentScheduleInstance` / `unifiedRoleEligibilityScheduleInstance` |
| `governanceRoleSetting` (read/update policy) | `unifiedRoleManagementPolicy` + `unifiedRoleManagementPolicyAssignment` |

1. Re-scope app registration permissions to the Iteration 3 Graph permissions for `RoleManagement.ReadWrite.Directory` (or the narrower role-specific equivalents per the resource's own permission table).
2. Rewrite calls against the mapped resource types above.
3. Remove the legacy `PrivilegedAccess.*` app role assignment once migration is validated in a non-production run.
4. Rollback: keep the legacy permission grant in place (inert, harmless) until the new code path is confirmed working end-to-end in production — don't strip access before the replacement is proven.
</details>

<details><summary>Fix 2 — Migrate an Azure-resources integration to Iteration 3 (Azure Resource Manager)</summary>

This is the higher-effort migration: Iteration 3 for Azure resources isn't on Microsoft Graph at all.

| Old (Iteration 2, Microsoft Graph) | New (Iteration 3, Azure Resource Manager) |
|---|---|
| Register a resource (`governanceResource` register) | Not required — ARM operates directly on the resource scope, no onboarding step |
| List role definitions (`governanceRoleDefinition` list) | [Role Definitions - List](https://learn.microsoft.com/en-us/rest/api/authorization/role-definitions/list) |
| Create assignment request (`governanceRoleAssignmentRequest` POST) | [Role Eligibility Schedule Requests - Create](https://learn.microsoft.com/en-us/rest/api/authorization/role-eligibility-schedule-requests/create) (eligible) / [Role Assignment Schedule Requests - Create](https://learn.microsoft.com/en-us/rest/api/authorization/role-assignment-schedule-requests/create) (active) |
| List role assignments (`governanceRoleAssignment` list) | [Role Eligibility Schedule Instances - List](https://learn.microsoft.com/en-us/rest/api/authorization/role-eligibility-schedule-instances/list-for-scope) / [Role Assignment Schedule Instances - List](https://learn.microsoft.com/en-us/rest/api/authorization/role-assignment-schedule-instances/list-for-scope) |
| Manage role settings (`governanceRoleSetting`) | [Role Management Policies](https://learn.microsoft.com/en-us/rest/api/authorization/role-management-policies) / [Policy Assignments](https://learn.microsoft.com/en-us/rest/api/authorization/role-management-policy-assignments) |

1. Switch the integration's auth to consent for **Azure Resource Manager** (`management.azure.com`) rather than (or in addition to) Microsoft Graph — this is a genuinely separate audience/token.
2. Confirm the calling identity has at least **Owner** or **User Access Administrator** on the target Azure resource scope — ARM's PIM API relies on Azure RBAC, not a Graph app role.
3. The "register a resource" onboarding step Iteration 2 required has **no equivalent and is unnecessary** in Iteration 3 — don't try to port it; ARM operates on resource scope directly.
4. Rollback: same as Fix 1 — leave legacy permissions in place until the ARM-based path is validated.
</details>

<details><summary>Fix 3 — No inventory exists; you're finding out via a ticket after Oct 28, 2026</summary>

If enforcement has already hit and a previously-working integration is now failing:

1. Confirm the failure signature: empty results / silent no-op / explicit 404 or deprecation error from `/beta/privilegedAccess/...` calls is expected post-cutover, not a bug to file against Microsoft.
2. Triage business impact — is this integration blocking an access-request workflow, an audit export, or a dashboard? Prioritize accordingly; there is no emergency re-enablement path from Microsoft once the endpoint stops returning data.
3. Apply Fix 1 or Fix 2 above as an emergency migration, or stand up a temporary manual process (PIM Azure Portal UI directly) while the code fix is developed.
4. Rollback: not applicable — Microsoft's retirement is one-directional; there's no reverting to Iteration 2.
</details>

---
## Escalation Evidence

```
PIM ITERATION 2 API RETIREMENT — ESCALATION
=============================================
Ticket #: <>
Integration/automation name: <script / Power Automate flow / Logic App / Azure Automation runbook / 3rd-party tool>
Provider affected: <Entra roles / Azure resources / both>
Endpoint(s) called: <literal path, e.g. /beta/privilegedAccess/azureResources/roleAssignmentRequests>
Legacy permission(s) granted to calling app: <PrivilegedAccess.* list>
App registration / service principal: <name, App ID>
Owning team: <>
Business function of integration: <access request automation / audit export / dashboard / other>
First observed failure date: <>
Failure signature: <empty result / 404 / explicit deprecation error / silent no-op>
Target Iteration 3 API identified: <Graph unifiedRole* / ARM roleEligibilityScheduleRequests>
Migration status: <not started / in progress / blocked on — specify>
Business impact if not migrated by 2026-10-28: <>
```

---
## 🎓 Learning Pointers
- PIM's API history is explicitly **not a linear version progression** — Microsoft's own documentation states Iterations 1, 2, and 3 have overlapping-but-different functionality rather than each superseding the last cleanly. Don't assume "just bump the version number" migrates anything; map each old call to its specific Iteration 3 replacement resource individually.
- The single most consequential migration detail: **PIM for Azure resources moves off Microsoft Graph entirely** in Iteration 3, onto Azure Resource Manager's own REST API. Teams that only search their codebase for `graph.microsoft.com` references will miss ARM-bound Azure-resources calls that were already using a Graph wrapper — audit by *resource type name* (`governanceRoleAssignmentRequest` etc.), not just by hostname.
- No usable server-side call telemetry exists for "who is still calling Iteration 2" — the practical proxy is auditing **legacy permission grants** (`PrivilegedAccess.*` scopes) combined with a source-code/flow-definition grep, which is what this runbook's Triage section and `Get-PIMIteration2APIUsageAudit.ps1` (see `EntraID/Scripts/`) both do. Treat the result as a lead list requiring manual confirmation, not an authoritative inventory.
- Reference the full endpoint mapping table directly from Microsoft before writing migration code — it's compact and authoritative: [Migrate from PIM iteration 2 APIs to PIM iteration 3 APIs](https://learn.microsoft.com/en-us/graph/api/resources/privilegedidentitymanagement-root?view=graph-rest-beta#migrate-from-pim-iteration-2-apis-to-pim-iteration-3-apis).
- Cross-reference this repo's existing [PIM-A.md](PIM-A.md) / [PIM-B.md](PIM-B.md) and [PIMAzureResources-A.md](PIMAzureResources-A.md) / [PIMAzureResources-B.md](PIMAzureResources-B.md) for general PIM activation/assignment troubleshooting — this runbook is scoped narrowly to the API-retirement/migration concern, not day-to-day PIM operational issues.
