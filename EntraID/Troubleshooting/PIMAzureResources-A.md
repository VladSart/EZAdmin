# PIM for Azure Resources — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index (with jump links)
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

This runbook covers **Microsoft Entra Privileged Identity Management (PIM) for Azure resources** — just-in-time, time-bound activation of Azure RBAC roles (built-in roles like Owner/Contributor/User Access Administrator, and custom roles) at management group, subscription, resource group, or individual resource scope.

**Explicitly disambiguated from three adjacent, easily-confused mechanisms:**

| Not this topic | What it actually is | Where it's covered |
|---|---|---|
| **PIM for Entra Directory Roles / PIM for Groups** | Time-bound activation of *Entra ID* roles (Global Admin, etc.) and group membership. Different portal blade ("Microsoft Entra roles" / "Groups"), different backing API (Microsoft Graph — `roleManagement/directory/...`), different PowerShell module (`Microsoft.Graph.Identity.Governance`). | `EntraID/Troubleshooting/PIM-A.md` / `PIM-B.md` |
| **"Elevate access" (Global Admin self-elevation)** | A one-time, self-service, temporary grant of **User Access Administrator at root scope (`/`)** for a Global Administrator who otherwise has zero Azure RBAC permissions. Not PIM — it's a standing Entra/ARM interop feature (`Microsoft.Authorization/elevateAccess`) that is often the *prerequisite* to a Global Admin seeing anything in PIM for Azure resources for the first time. | [Elevate access for a Global Administrator](https://learn.microsoft.com/en-us/azure/role-based-access-control/elevate-access-global-admin) |
| **Static/permanent Azure RBAC assignments** | Ordinary "Access control (IAM)" role assignments with no PIM involvement at all. These **coexist** with PIM-managed assignments at the same scope — PIM never touches, and is not aware of, a static assignment it didn't create. | `Azure/*` — general RBAC is out of scope for this repo as a standalone topic; this runbook covers it only where it intersects PIM troubleshooting |

**Assumes:**
- Az PowerShell (`Az.Resources` module) installed and authenticated (`Connect-AzAccount`)
- Operator has Owner or User Access Administrator on the target scope, or is a Global Administrator who has completed either the tenant-wide "Access management for Azure resources" toggle or a one-time "elevate access"
- Entra ID P2 (or equivalent — M365 E5, EMS E5) license on principals who need PIM activation; PIM for Azure resources uses the **same tenant-level PIM licensing** as directory-role PIM, not a separate SKU

**What PIM for Azure Resources solves:** the same standing-access anti-pattern as directory-role PIM, applied to the Azure control plane instead of Entra ID itself — a user who is *eligible* for `Contributor` on a subscription has zero standing access until they deliberately activate, bounded by a time window, optional MFA/justification/approval.

---
## How It Works

<details><summary>Full architecture</summary>

### Two independent authorization systems layered on the same Azure RBAC role assignments

Azure RBAC has always supported two states for any role assignment: it exists, or it doesn't. PIM for Azure resources adds a **scheduling layer** on top of the same underlying `Microsoft.Authorization/roleAssignments` resource type, via two new resource types:

- **`roleEligibilityScheduleRequests`** / **`roleEligibilitySchedules`** — the *eligible* state. A principal is permitted to activate, but has no standing access.
- **`roleAssignmentScheduleRequests`** / **`roleAssignmentSchedules`** — the *active* state. This is what actually grants access; it's created either directly (an "Active" PIM assignment, functionally identical to a static assignment but time-bound) or as the result of a successful activation of an eligible schedule.

Critically: **a plain, non-PIM static role assignment is just a `roleAssignments` object with no corresponding schedule** — PIM's view of the world and Azure RBAC's authorization engine are not the same query. This is why removing PIM eligibility never removes a static assignment made outside PIM: they are different objects that happen to grant the same permission.

### Onboarding model (two generations, both currently live)

**Legacy (manual discovery):** the first time an administrator opens PIM > Azure resources, they must explicitly "discover" and "manage" each management group or subscription. Onboarding a scope:
1. Creates a service principal named **MS-PIM** (if it doesn't already exist in the tenant)
2. Assigns **User Access Administrator** to MS-PIM at that scope — this is how the PIM service itself gets permission to create/modify role assignments on the administrator's behalf
3. Is a **one-way door** — once a scope is "managed," it cannot be unmanaged, specifically to prevent a resource administrator from quietly disabling PIM oversight after the fact

**Current (auto-managed, ARM-API-native):** as of the 2026 experience refresh, PIM can automatically manage every Azure resource in a tenant with **no onboarding step required at all**, built on the newer PIM ARM API for improved performance and finer scope selection. This is now the default UI when navigating to Azure resources in PIM; the legacy manual-discovery flow is still reachable via a banner toggle for organizations that haven't migrated. **Do not assume a tenant is still on the legacy model** — verify via the portal banner or by checking whether `Get-AzRoleManagementPolicyAssignment` already returns policies for scopes nobody manually "discovered."

### Assignment types: Eligible vs. Active

Identical conceptual model to directory-role PIM:

| Type | Meaning | Requires activation? |
|------|---------|----------------------|
| **Eligible** | Principal *can* activate the role | Yes |
| **Active** | Principal has standing access right now, PIM-tracked and time-bound | No — but still expires per the configured duration, unlike a static assignment |

An "Active" PIM assignment is not the same as a static assignment: it still has an expiration and still shows up in PIM's own reporting/audit surface. A static assignment made via Access Control (IAM) has neither.

### Activation flow

```
Principal requests activation (portal "My roles" / mobile app / ARM API SelfActivate)
        │
        ▼
Policy engine evaluates the role's settings (a "PIM policy," configured PER ROLE
PER RESOURCE — see Policy scoping below):
    ├── MFA satisfied this session? (or CA authentication context configured)
    ├── Business justification required?
    ├── Ticket number required? (informational only — no external system validated)
    ├── Within allowed activation window / custom start time?
    ├── ABAC condition present? (only 3 built-in roles support conditions today:
    │     Storage Blob Data Contributor/Owner/Reader)
    └── Approval required?
              ├── No  →  roleAssignmentScheduleRequest created (RequestType=SelfActivate)
              │              → active for up to the configured max (1–24 hours)
              └── Yes →  Status = PendingApproval, notification to approver(s)
                              (approver needs no specific role — just to be listed)
                                    ├── Approve → assignment created
                                    └── Deny    → request rejected, nothing created
```

**Hard timing constraints** (not configurable): an assignment cannot be activated for a duration of **less than 5 minutes**, and cannot be **deactivated within 5 minutes** of being activated. This is a platform floor, not a policy setting — engineers scripting rapid activate/deactivate cycles for testing will hit this.

### Policy scoping: assignments inherit down, policies do not

This is the single most consequential architectural detail for troubleshooting. Azure RBAC's normal inheritance model means a role assigned at a subscription applies to every resource group and resource beneath it. **PIM policies do not follow that same inheritance.** Role settings ("PIM policies" — MFA requirement, approval, duration ceilings, notifications) are defined **per role, per resource** — a policy configured for `Contributor` at the subscription has zero effect on the `Contributor` policy for a resource group nested inside it. Each scope's policy is a fully independent object that must be configured on its own.

### API surface: Azure Resource Manager, not Microsoft Graph

Every operation in this topic goes through the **ARM API** under the `Microsoft.Authorization` provider (`roleEligibilityScheduleRequests`, `roleAssignmentScheduleRequests`, `roleManagementPolicyAssignments`), scripted via the **`Az.Resources`** PowerShell module (`New-AzRoleEligibilityScheduleRequest`, `Get-AzRoleEligibilityScheduleInstance`, `Get-AzRoleAssignmentScheduleInstance`, `Update-AzRoleEligibilityScheduleRequest`, `New-AzRoleAssignmentScheduleRequest`). None of this overlaps with the Graph endpoints or `Microsoft.Graph.Identity.Governance` cmdlets used for directory-role/group PIM (`Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance` and siblings) — the two surfaces share a UI concept and a name, and nothing else technically. A script written against the Graph cmdlets against an Azure-resource question will return an empty collection or throw a not-found on the wrong object type, not a helpful "wrong API" error.

### Shared reauthentication window

One genuinely cross-cutting behavior: when a Conditional Access authentication context is configured on a PIM policy and a user reauthenticates to satisfy it, a **10-minute grace window** applies — and that window is shared **across Entra directory roles, Azure resource roles, and PIM for Groups simultaneously**. A user activating an Azure resource role right after activating a directory role within that window won't be reprompted, which can look like a misconfigured (too weak) policy when it's actually working as designed.

</details>

---
## Dependency Stack

```
Entra ID P2 / equivalent license (tenant-level PIM feature gate — shared with
directory-role PIM, not a separate SKU)
    └── Scope onboarded to PIM (legacy manual discovery, OR auto-managed via the
        2026 tenant-wide ARM-API experience — verify which model is in play)
            └── MS-PIM service principal holds User Access Administrator at scope
                    (created automatically on first onboarding; if this assignment
                     is later removed — e.g. by an unrelated RBAC cleanup — PIM
                     itself breaks for every user at that scope, not just one)
                    └── PIM policy (role settings) configured — PER ROLE, PER
                        RESOURCE, with NO inheritance from a parent scope's policy
                            └── Eligible or Active schedule created
                                    ├── Eligible → activation request
                                    │       ├── MFA / CA auth context satisfied
                                    │       ├── Justification / ticket entered
                                    │       ├── ABAC condition evaluated (if the
                                    │       │   role is one of the 3 that support it)
                                    │       ├── Approval granted (if required)
                                    │       └── 5-minute minimum hold enforced
                                    └── roleAssignmentSchedule (Active) created
                                            └── Standard Azure RBAC authorization
                                                check (ARM control plane) — the
                                                SAME check a static assignment
                                                would satisfy; PIM and static
                                                assignments are evaluated
                                                identically once "Active"
                                                    └── Access granted to the
                                                        Azure resource/action
```

**Where this silently coexists with static RBAC:** a principal can simultaneously hold a static, permanent `Contributor` assignment (via Access Control (IAM), untouched by PIM) *and* a PIM-eligible `Contributor` assignment at the same scope. Azure RBAC's authorization engine doesn't care which one satisfied the check — access works either way, and removing the PIM side changes nothing if the static side is still there.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Global Admin sees zero subscriptions/management groups in PIM | No Azure RBAC permissions by default for Global Admin | `Get-AzRoleAssignment` for the admin's object ID — likely empty; use elevate-access or the tenant "Access management for Azure resources" toggle |
| Resource visible in PIM but every action returns an authorization error, for every user | MS-PIM service principal lost its User Access Administrator role at that scope | `Get-AzRoleAssignment -ObjectId (Get-AzADServicePrincipal -DisplayName "MS-PIM").Id` |
| Eligible assignment exists, activation succeeds, but the resource action still fails | Static/browser/control-plane cache lag, or the activated role's *actions* don't actually cover what the user is trying to do | Re-check the role definition's `Actions`/`NotActions`; force fresh sign-in |
| Configuring a strict policy at the subscription doesn't seem to apply at a resource group | Policies don't inherit down the scope hierarchy — must be set per scope | `Get-AzRoleManagementPolicyAssignment -Scope <RG scope>` |
| Activation blocked, error resembling `RoleAssignmentExists` | A static assignment for the same role/scope/principal already exists | `Get-AzRoleAssignment` filtered to that principal + role |
| User removed from PIM eligibility, access persists | A static (non-PIM) assignment was never removed — PIM doesn't know about it | `Get-AzRoleAssignment` — look for an assignment with no matching schedule |
| ABAC "Add condition" option greyed out for a custom role | Conditions only supported today on 3 built-in Storage Blob Data roles | Confirm role name; conditions aren't available for arbitrary roles |
| Can't deactivate a role immediately after activating | 5-minute minimum hold is a platform floor, not a policy setting | Wait — this cannot be overridden |
| Approval request never resolves | Sole approver is also PIM-eligible (not standing) and unavailable — same deadlock pattern as directory-role PIM | Confirm approver list has at least one standing-active approver |
| Script using `Get-MgRoleManagementDirectory*` cmdlets returns nothing for an Azure-resource question | Wrong API/module — that's the Graph surface for directory roles, not ARM | Switch to `Az.Resources` cmdlets (`Get-AzRoleEligibilityScheduleInstance`, etc.) |
| Subscription was onboarded to PIM by mistake and someone wants it "removed" from PIM | Onboarding is a one-way door — cannot be unmanaged | Not fixable; document the decision, tighten policies instead |
| Eligible assignment shows `MemberType = Group` and access doesn't work for a specific user | Group-based eligibility — the user must be a member of the eligible group, not directly eligible | Check group membership, not the user's own schedule |
| Newly assigned eligible role doesn't appear immediately in "My roles" | Group-based eligibility propagation delay, or the requester used the wrong scope filter in the portal dropdown | Retry after a short delay; confirm scope selection matches where the assignment was made |

---
## Validation Steps

**1. Confirm module and authentication context**
```powershell
Get-Module -ListAvailable Az.Resources | Select-Object Name, Version
Connect-AzAccount
Get-AzContext | Select-Object Subscription, Tenant
```
Good: current `Az.Resources` version, correct subscription context. Bad: outdated module — several schedule cmdlets are relatively recent additions.

**2. Confirm scope onboarding / policy existence**
```powershell
Get-AzRoleManagementPolicyAssignment -Scope "/subscriptions/<subId>"
```
Good: one or more results (every role that has ever had a policy touched at this scope). Bad: empty on a scope you believe is actively used with PIM — either it's genuinely unmanaged, or you're checking the wrong scope string (management group vs. subscription vs. resource group path syntax differs).

**3. Confirm MS-PIM service principal health**
```powershell
$msPim = Get-AzADServicePrincipal -DisplayName "MS-PIM"
Get-AzRoleAssignment -Scope "/subscriptions/<subId>" -ObjectId $msPim.Id
```
Good: `User Access Administrator` returned. Bad: empty — this is a scope-wide outage for PIM, escalate immediately (Playbook 3).

**4. Confirm eligible schedule for the affected principal**
```powershell
Get-AzRoleEligibilityScheduleInstance -Scope "/subscriptions/<subId>" -Filter "principalId eq '<objectId>'"
```
Good: `Status = Provisioned`, sane start/end. Bad: empty, expired, or `MemberType = Group` when you expected direct eligibility.

**5. Confirm most recent activation/assignment request outcome**
```powershell
Get-AzRoleAssignmentScheduleRequest -Scope "/subscriptions/<subId>" -Filter "principalId eq '<objectId>'" |
  Sort-Object CreatedOn -Descending | Select-Object -First 3
```
Good: `Status = Provisioned` for the most recent `SelfActivate`/`AdminAssign`. Bad: `Failed` or `Denied` — inspect status detail.

**6. Rule out a conflicting or masking static assignment**
```powershell
Get-AzRoleAssignment -Scope "/subscriptions/<subId>" -ObjectId <objectId>
```
Good: only assignments you expect (PIM-active ones will also appear here — PIM-active assignments ARE role assignments). Bad: an unexplained permanent assignment with no corresponding schedule object.

**7. Confirm role settings (policy) at the exact scope in question**
```powershell
$policy = Get-AzRoleManagementPolicyAssignment -Scope "/subscriptions/<subId>/resourceGroups/<rg>" |
  Where-Object { $_.RoleDefinitionId -like "*<roleDefId>" }
Get-AzRoleManagementPolicy -Scope $policy.Scope -Name $policy.PolicyId
```
Good: policy rules match what the requester expects for *this* scope specifically. Bad: requester assumed a subscription-level policy edit applied here — it didn't.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the right surface.** Before anything else, confirm this is genuinely an Azure-resource-role question and not a directory-role or PIM-for-Groups question misfiled here. Check the portal breadcrumb (Azure resources vs. Microsoft Entra roles vs. Groups) or, in a ticket with only a role name, resolve whether that name is an Azure built-in role (Owner, Contributor, Reader, custom) vs. an Entra directory role (Global Administrator, User Administrator) — the names don't overlap by design, which is the fastest tell.

**Phase 2 — Confirm onboarding and service-principal health.** Run Validation Steps 2 and 3. A scope-wide MS-PIM permission failure explains "everyone is broken" tickets; a missing policy assignment explains "this subscription was never set up for PIM" tickets.

**Phase 3 — Confirm the specific principal's eligible/active state.** Validation Steps 4–5. Distinguish "never eligible," "eligible but activation failed," and "activated but access still denied" — these have entirely different fixes.

**Phase 4 — Check for static-assignment interference.** Validation Step 6, in both directions: a static assignment can either mask a PIM removal (access "won't go away") or block a PIM activation (`RoleAssignmentExists` conflict).

**Phase 5 — Check policy scope precision.** Validation Step 7, whenever the reported behavior is "I configured this policy and it didn't take effect" — the near-universal cause is that the policy was edited at the wrong scope in the hierarchy.

**Phase 6 — Escalate with the Evidence Pack** if MS-PIM's own role assignment needs restoring (a genuinely elevated action, Playbook 3) or if the fix requires removing a static assignment that might be intentional (confirm with the resource owner first).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield onboarding of a new subscription to PIM for Azure resources</summary>

1. Confirm which onboarding model is live in this tenant (portal banner on PIM > Azure resources — legacy manual discovery vs. 2026 auto-managed).
2. **Legacy model:** ID Governance > PIM > Azure resources > Discover resources > select the management group/subscription > Manage resource. Confirm the MS-PIM service principal received User Access Administrator:
   ```powershell
   $msPim = Get-AzADServicePrincipal -DisplayName "MS-PIM"
   Get-AzRoleAssignment -Scope "/subscriptions/<subId>" -ObjectId $msPim.Id
   ```
3. **Auto-managed model:** no manual step — verify the scope is already policy-aware:
   ```powershell
   Get-AzRoleManagementPolicyAssignment -Scope "/subscriptions/<subId>"
   ```
4. Configure role settings deliberately for each role you intend to manage via PIM **at this specific scope** — do not assume a policy set elsewhere applies here (see Policy scoping in How It Works).
5. Create eligible assignments (not active) as the default posture:
   ```powershell
   New-AzRoleEligibilityScheduleRequest -Name (New-Guid) -Scope "/subscriptions/<subId>" `
     -PrincipalId <objectId> -RoleDefinitionId "/subscriptions/<subId>/providers/Microsoft.Authorization/roleDefinitions/<roleDefGuid>" `
     -RequestType AdminAssign -ExpirationType AfterDuration -ExpirationDuration "P365D" `
     -ScheduleInfoStartDateTime (Get-Date).ToUniversalTime()
   ```
6. **One-way door reminder:** onboarding cannot be reversed. Do not run this playbook against a production subscription as a test — use a sandbox subscription first if the org is new to PIM for Azure resources.

**Rollback:** none for onboarding itself. Individual eligible/active assignments can be removed with `AdminRemove` requests.
</details>

<details><summary>Playbook 2 — Migrating a set of static/permanent assignments to PIM-managed eligible assignments</summary>

1. Inventory existing static assignments at the target scope:
   ```powershell
   Get-AzRoleAssignment -Scope "/subscriptions/<subId>" | Where-Object { $_.ObjectType -eq "User" }
   ```
2. For each principal/role pair intended for JIT access, create the eligible assignment **before** removing the static one, to avoid an access gap:
   ```powershell
   New-AzRoleEligibilityScheduleRequest -Name (New-Guid) -Scope "/subscriptions/<subId>" `
     -PrincipalId <objectId> -RoleDefinitionId "<roleDefId>" -RequestType AdminAssign `
     -ExpirationType NoExpiration -ScheduleInfoStartDateTime (Get-Date).ToUniversalTime()
   ```
3. Confirm the eligible schedule is `Provisioned`, then remove the static assignment:
   ```powershell
   Remove-AzRoleAssignment -Scope "/subscriptions/<subId>" -ObjectId <objectId> -RoleDefinitionName "<RoleName>"
   ```
4. Notify the affected user they must now activate before using the role — this is a genuine workflow change, not just a backend swap.
5. Verify no `RoleAssignmentExists` conflicts remain for anyone migrated (Symptom → Cause Map row 5).

**Rollback:** re-create the static assignment with `New-AzRoleAssignment` for any principal who needs to revert (e.g., a break-glass account that shouldn't require activation at all).
</details>

<details><summary>Playbook 3 — Restoring MS-PIM service principal permissions after accidental removal</summary>

**When to use:** Symptom → Cause Map row 2 — every user at a scope reports PIM actions failing, but static Owner/UAA holders still have normal Azure access.

1. Confirm the failure is genuinely MS-PIM, not a single user's own permission gap:
   ```powershell
   $msPim = Get-AzADServicePrincipal -DisplayName "MS-PIM"
   Get-AzRoleAssignment -Scope "/subscriptions/<subId>" -ObjectId $msPim.Id
   ```
2. If empty, re-assign:
   ```powershell
   New-AzRoleAssignment -ObjectId $msPim.Id -RoleDefinitionName "User Access Administrator" -Scope "/subscriptions/<subId>"
   ```
3. Confirm the fix by re-running Validation Step 3, then have an affected user retry their original PIM action.
4. **Prevent recurrence:** if the removal came from an automated "unused service principal" or "unused role assignment" cleanup script, add MS-PIM to that script's exclusion list — this is a known, recurring failure pattern across tenants that run aggressive RBAC hygiene automation without an allowlist for platform service principals.

**Rollback:** none needed — this playbook only restores an assignment that should already exist.
</details>

<details><summary>Playbook 4 — Fleet-wide MSP health sweep across managed subscriptions</summary>

1. Enumerate subscriptions in scope for the sweep:
   ```powershell
   $subs = Get-AzSubscription
   ```
2. For each subscription, confirm MS-PIM's permission and flag any missing:
   ```powershell
   $msPim = Get-AzADServicePrincipal -DisplayName "MS-PIM"
   foreach ($sub in $subs) {
       Set-AzContext -Subscription $sub.Id | Out-Null
       $assignment = Get-AzRoleAssignment -Scope "/subscriptions/$($sub.Id)" -ObjectId $msPim.Id -ErrorAction SilentlyContinue
       [PSCustomObject]@{ Subscription = $sub.Name; MSPimHealthy = [bool]$assignment }
   }
   ```
3. Cross-reference against the fleet-wide audit script (see Evidence Pack) for eligible assignments with no expiry, and static assignments duplicating PIM-eligible ones.
4. Report findings; do not auto-remediate static-assignment conflicts without confirming intent with each resource owner — some are deliberate break-glass configurations.

**Rollback:** N/A — read-only sweep.
</details>

---
## Evidence Pack

```powershell
<#
Run this before escalating any PIM for Azure Resources issue.
Read-only. Requires Az.Resources, Connect-AzAccount already run.
#>
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$PrincipalObjectId
)

$scope = "/subscriptions/$SubscriptionId"
Write-Host "=== PIM for Azure Resources — Evidence Pack ===" -ForegroundColor Cyan
Write-Host "Scope: $scope"
Write-Host "Principal: $PrincipalObjectId"
Write-Host ""

Write-Host "--- Scope onboarding / policy assignments ---" -ForegroundColor Yellow
Get-AzRoleManagementPolicyAssignment -Scope $scope | Format-Table RoleDefinitionId, PolicyId -AutoSize

Write-Host "--- MS-PIM service principal permission ---" -ForegroundColor Yellow
$msPim = Get-AzADServicePrincipal -DisplayName "MS-PIM" -ErrorAction SilentlyContinue
if ($msPim) {
    Get-AzRoleAssignment -Scope $scope -ObjectId $msPim.Id | Format-Table RoleDefinitionName, Scope -AutoSize
} else {
    Write-Host "MS-PIM service principal not found in tenant — legacy manual-discovery model may never have been used." -ForegroundColor Red
}

Write-Host "--- Eligible schedules for principal ---" -ForegroundColor Yellow
Get-AzRoleEligibilityScheduleInstance -Scope $scope -Filter "principalId eq '$PrincipalObjectId'" |
    Format-Table RoleDefinitionId, Status, StartDateTime, EndDateTime, MemberType -AutoSize

Write-Host "--- Active schedules for principal ---" -ForegroundColor Yellow
Get-AzRoleAssignmentScheduleInstance -Scope $scope -Filter "principalId eq '$PrincipalObjectId'" |
    Format-Table RoleDefinitionId, Status, StartDateTime, EndDateTime, MemberType -AutoSize

Write-Host "--- Recent activation/assignment requests ---" -ForegroundColor Yellow
Get-AzRoleAssignmentScheduleRequest -Scope $scope -Filter "principalId eq '$PrincipalObjectId'" |
    Sort-Object CreatedOn -Descending | Select-Object -First 10 |
    Format-Table RequestType, Status, CreatedOn, RoleDefinitionId -AutoSize

Write-Host "--- Static (permanent) role assignments for principal ---" -ForegroundColor Yellow
Get-AzRoleAssignment -Scope $scope -ObjectId $PrincipalObjectId | Format-Table RoleDefinitionName, Scope -AutoSize

Write-Host "Evidence pack complete." -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Confirm module | `Get-Module -ListAvailable Az.Resources` |
| Confirm scope onboarding | `Get-AzRoleManagementPolicyAssignment -Scope <scope>` |
| Check MS-PIM's own permission | `Get-AzRoleAssignment -Scope <scope> -ObjectId (Get-AzADServicePrincipal -DisplayName "MS-PIM").Id` |
| List eligible schedules for a principal | `Get-AzRoleEligibilityScheduleInstance -Scope <scope> -Filter "principalId eq '<id>'"` |
| List active schedules for a principal | `Get-AzRoleAssignmentScheduleInstance -Scope <scope> -Filter "principalId eq '<id>'"` |
| Create an eligible assignment (admin) | `New-AzRoleEligibilityScheduleRequest -Scope <scope> -PrincipalId <id> -RoleDefinitionId <roleDefId> -RequestType AdminAssign ...` |
| Self-activate an eligible role | `New-AzRoleAssignmentScheduleRequest -Scope <scope> -PrincipalId <id> -RoleDefinitionId <roleDefId> -RequestType SelfActivate -LinkedRoleEligibilityScheduleId <id> ...` |
| Check recent requests/outcomes | `Get-AzRoleAssignmentScheduleRequest -Scope <scope> -Filter "principalId eq '<id>'"` |
| List static assignments | `Get-AzRoleAssignment -Scope <scope> -ObjectId <id>` |
| Remove a static assignment | `Remove-AzRoleAssignment -Scope <scope> -ObjectId <id> -RoleDefinitionName <name>` |
| Restore MS-PIM permission | `New-AzRoleAssignment -ObjectId <MS-PIM objectId> -RoleDefinitionName "User Access Administrator" -Scope <scope>` |
| Global Admin one-time elevation | Portal only: [Elevate access for a Global Administrator](https://learn.microsoft.com/en-us/azure/role-based-access-control/elevate-access-global-admin) — no dedicated Az cmdlet |
| Tenant "Access management for Azure resources" toggle | Portal only: Entra admin center > Properties |
| ARM API — create eligible assignment | `PUT .../providers/Microsoft.Authorization/roleEligibilityScheduleRequests/{name}?api-version=2020-10-01-preview` |
| ARM API — activate (self) | `PUT .../providers/Microsoft.Authorization/roleAssignmentScheduleRequests/{name}?api-version=2020-10-01` with `requestType=SelfActivate` |
| List a principal's assignments across the whole tenant (slow, use sparingly) | Loop `Get-AzSubscription` + `Get-AzRoleAssignment -ObjectId <id>` per subscription — no single tenant-wide cmdlet exists |
| Extend/renew an assignment | Portal: PIM > Azure resources > My roles > Extend/Renew, or `Update-AzRoleEligibilityScheduleRequest` |
| Reference: PIM ARM API | [PIM Azure Resource Manager API reference](https://learn.microsoft.com/en-us/rest/api/authorization/role-eligibility-schedule-requests) |

---
## 🎓 Learning Pointers

- **The name overlap with directory-role PIM is the single biggest source of wasted troubleshooting time.** Same product family, same portal shell, completely disjoint API/module/permission model underneath. Always confirm which surface a ticket is actually about before running any cmdlet.
- **Onboarding is permanent by design** — this mirrors a pattern seen elsewhere in this repo (Key Vault purge protection, Purview retention labels): Microsoft deliberately makes some safety/oversight features impossible to quietly turn off once enabled, specifically to prevent an insider from disabling the control that's watching them.
- **Policies don't inherit; assignments do.** This asymmetry — where the access itself flows down the resource hierarchy but the *rules governing how you get that access* do not — is worth internalizing as a general Azure RBAC-adjacent pattern, not just a PIM quirk.
- **Static and PIM-managed assignments are structurally different objects that produce identical access.** Any "why won't this access go away" or "why can't I activate, it says it already exists" ticket should check both `Get-AzRoleAssignment` (static) and the schedule cmdlets (PIM) — checking only one gives an incomplete picture.
- **The MS-PIM service principal is a single point of failure for an entire scope.** Treat it the way you'd treat any critical platform service account — exclude it explicitly from automated "clean up unused role assignments" tooling, since its role assignment looking "unused" (no interactive sign-ins) is exactly what makes those tools flag it.
- **MS Docs reference:** [What is Privileged Identity Management?](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-configure) · [Assign Azure resource roles](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-resource-roles-assign-roles) · [Configure Azure resource role settings](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-resource-roles-configure-role-settings) · [Activate Azure resource roles](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-resource-roles-activate-your-roles) · [Discover Azure resources to manage in PIM](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-resource-roles-discover-resources) · [Elevate access for a Global Administrator](https://learn.microsoft.com/en-us/azure/role-based-access-control/elevate-access-global-admin)
