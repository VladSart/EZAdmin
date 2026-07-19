# PIM for Azure Resources — Hotfix Runbook (Mode B: Ops)
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

> **Before you start:** this is **not** the same product surface as `EntraID/Troubleshooting/PIM-B.md` (Entra directory roles/groups). PIM for Azure resources governs Azure RBAC roles (Owner, Contributor, User Access Administrator, custom roles) at management group/subscription/resource-group/resource scope, runs on the **ARM API** (`Microsoft.Authorization/roleEligibilityScheduleRequests`), and is scripted with **`Az.Resources`** cmdlets — not `Microsoft.Graph.Identity.Governance`. Running a Graph PIM cmdlet against an Azure-resource question returns empty/wrong results, not an error. Confirm which surface you're actually looking at before you triage.

```powershell
# 1. Confirm you're using the right module/API surface — Az, not Graph
Get-Module -ListAvailable Az.Resources | Select-Object Name, Version
Connect-AzAccount

# 2. Check the target principal's eligible assignments at a given scope
Get-AzRoleEligibilityScheduleInstance -Scope "/subscriptions/<subId>" -Filter "principalId eq '<principalObjectId>'"

# 3. Check active (currently usable) assignments at that scope
Get-AzRoleAssignmentScheduleInstance -Scope "/subscriptions/<subId>" -Filter "principalId eq '<principalObjectId>'"

# 4. Check whether the scope is even PIM-managed yet (onboarding gate)
Get-AzRoleManagementPolicyAssignment -Scope "/subscriptions/<subId>" -ErrorAction SilentlyContinue

# 5. Confirm the MS-PIM service principal still has User Access Administrator at this scope
#    (the #1 root cause of "I can see the resource in PIM but every action fails")
Get-AzRoleAssignment -Scope "/subscriptions/<subId>" -ObjectId (Get-AzADServicePrincipal -DisplayName "MS-PIM").Id |
    Select-Object RoleDefinitionName, Scope
```

| Result | Meaning | Action |
|--------|---------|--------|
| Command errors "term not recognized" for `Get-AzRoleEligibilityScheduleInstance` | `Az.Resources` module missing/outdated | Fix 1 |
| Eligible assignment exists but user still gets access denied | Not yet activated, or activation didn't propagate | Fix 2 |
| No PIM-managed subscription/resource found at that scope | Scope was never onboarded to PIM (legacy manual-discovery model) | Fix 3 |
| MS-PIM service principal has no role assignment at this scope | Service principal's UAA grant was accidentally removed | Fix 4 |
| Activation request `status = Failed` with `RoleAssignmentExists` or similar | Duplicate/conflicting static RBAC assignment already present | Fix 5 |
| User was PIM-eligible, removed, but still has access | A **separate static/permanent** Azure RBAC assignment was never cleaned up — PIM only manages what it created | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Scope onboarded to PIM (management group / subscription — legacy manual "Discover
resources" step, OR auto-managed via the 2026 tenant-wide ARM-API experience)
    └── MS-PIM service principal holds User Access Administrator at that scope
            └── Role settings ("PIM policy") configured PER ROLE, PER RESOURCE
            │       (NOT inherited from a parent scope's policy — a subscription-level
            │        policy edit does not cascade to a resource group beneath it)
            └── Eligible or Active assignment created
                    ├── Eligible → user must self-activate
                    │       ├── MFA satisfied this session? (or CA auth context)
                    │       ├── Justification / ticket info entered if required
                    │       ├── Approval granted if required (approver needs no role)
                    │       └── 5-minute minimum hold — can't be activated <5 min
                    │           and can't be deactivated within 5 min of activation
                    └── Active assignment
                            └── Azure Resource Manager propagates the role (~seconds,
                                but app-layer caching can lag — see Fix 2)
                                    └── User can perform the privileged action
```

**Common gaps:**
- Confusing this with directory-role PIM: different portal blade (**ID Governance > PIM > Azure resources**, not "Microsoft Entra roles"), different API, different PowerShell module.
- Assuming a subscription-level PIM policy applies to its resource groups — it does not; each scope's policy is independent and must be configured separately.
- Forgetting that PIM-eligible and static/permanent RBAC assignments **coexist** — removing PIM eligibility does nothing to a static `Owner` grant made directly in Access Control (IAM).
- Global Admin can't see any subscriptions in PIM at all — this is usually the **"elevate access"** or **"enable subscription management"** prerequisite, not a PIM bug (see Fix 3).
</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm which scope and which module you're actually working with**
```powershell
Get-AzContext | Select-Object Subscription, Tenant
Get-Module Az.Resources | Select-Object Version
```
*Expected:* Correct subscription context, `Az.Resources` ≥ current major version.
*Bad:* Wrong subscription selected — `Set-AzContext -Subscription <subId>` first.

**Step 2 — Confirm the scope is PIM-managed**
```powershell
Get-AzRoleManagementPolicyAssignment -Scope "/subscriptions/<subId>"
```
*Expected:* One or more policy assignments returned (one per role that has ever been configured at this scope).
*Bad:* Empty — the scope was never onboarded (legacy model) or auto-management hasn't picked it up yet. Portal: ID Governance > PIM > Azure resources > Discover resources.

**Step 3 — Confirm the eligible assignment and its schedule**
```powershell
Get-AzRoleEligibilityScheduleInstance -Scope "/subscriptions/<subId>" -Filter "principalId eq '<principalObjectId>'" |
  Select-Object RoleDefinitionId, Status, StartDateTime, EndDateTime, MemberType
```
*Expected:* `Status = Provisioned`, `EndDateTime` in the future or null (permanent).
*Bad:* `MemberType = Group` and the user isn't in that group anymore — check group membership, not the user object directly.

**Step 4 — Confirm activation actually completed**
```powershell
Get-AzRoleAssignmentScheduleRequest -Scope "/subscriptions/<subId>" -Filter "principalId eq '<principalObjectId>'" |
  Sort-Object CreatedOn -Descending | Select-Object -First 5 RequestType, Status, CreatedOn
```
*Expected:* Most recent request `RequestType = SelfActivate`, `Status = Provisioned`.
*Bad:* `Status = Failed` — the request object includes a status detail; also check for `Denied` if approval was required.

**Step 5 — Rule out a static (non-PIM) assignment masking the real state**
```powershell
Get-AzRoleAssignment -Scope "/subscriptions/<subId>" -ObjectId <principalObjectId>
```
*Expected:* Empty, or only assignments you recognize as intentionally static (break-glass, service accounts).
*Bad:* An unexpected permanent `Owner`/`Contributor` grant — this is why "removing PIM eligibility" didn't remove access. See Fix 6.

**Step 6 — Confirm the MS-PIM service principal's own permissions**
```powershell
$msPim = Get-AzADServicePrincipal -DisplayName "MS-PIM"
Get-AzRoleAssignment -Scope "/subscriptions/<subId>" -ObjectId $msPim.Id
```
*Expected:* `User Access Administrator` at the managed scope.
*Bad:* Empty — see Fix 4. This breaks PIM for **everyone** at that scope, not just one user.

---
## Common Fix Paths

<details><summary>Fix 1 — Az.Resources module missing or too old for schedule cmdlets</summary>

**Symptoms:** `Get-AzRoleEligibilityScheduleInstance`/`New-AzRoleEligibilityScheduleRequest` not recognized, or errors about unsupported parameters.

```powershell
Install-Module -Name Az.Resources -Scope CurrentUser -Force -AllowClobber
Import-Module Az.Resources -Force
Get-Module Az.Resources | Select-Object Version
```

**Rollback:** N/A — module install only, no tenant changes.
</details>

<details><summary>Fix 2 — Eligible assignment exists but activation shows denied/stale access</summary>

**Symptoms:** `Get-AzRoleAssignmentScheduleInstance` shows an active, non-expired assignment, but the portal/API still returns 403 for the actual resource action.

**Cause:** ARM role propagation is normally seconds, but browser sessions and some control-plane caches (Cost Management, some PaaS management blades) can hold a stale authorization result.

**Fix:**
```powershell
# Force a fresh token — have the user sign out of all browser sessions, or:
Clear-AzContext -Force
Connect-AzAccount
```
Have the user close all browser tabs for the Azure portal, clear cache or use an InPrivate/incognito window, then retry.

**Rollback:** No rollback needed — no tenant state was changed.
</details>

<details><summary>Fix 3 — Global Admin can't see any subscriptions/management groups in PIM</summary>

**Symptoms:** A Global Administrator opens PIM > Azure resources and the resource list is empty, even though subscriptions clearly exist in the tenant.

**Cause:** Global Admin does not have Azure RBAC permissions by default. Two independent, easily-confused mechanisms grant it:

1. **"Enable Access management for Azure resources"** (persistent, tenant-wide) — Entra admin center > Properties (or `Azure portal > Microsoft Entra ID > Properties`) > toggle **Access management for Azure resources = Yes**. Grants the Global Admin **User Access Administrator** at root scope (`/`) until turned off again.
2. **"Elevate access"** (one-time, self-service, temporary) — a Global Admin can self-elevate via the [elevate-access flow](https://learn.microsoft.com/en-us/azure/role-based-access-control/elevate-access-global-admin), which is the same underlying grant but toggled by the individual admin rather than a tenant-wide setting.

```powershell
# Confirm current tenant setting
Get-AzTenant | Select-Object TenantId
# (Portal-only toggle — no dedicated Az cmdlet for the tenant Properties switch itself)
```

**Fix:** Use either mechanism above, then re-open PIM > Azure resources > Discover resources (legacy) or wait for the scope to appear under the auto-managed experience.

**Rollback:** Toggle **Access management for Azure resources** back to **No** once the one-time task is done — this is a genuinely elevated, tenant-wide grant and should not be left on.
</details>

<details><summary>Fix 4 — MS-PIM service principal lost its User Access Administrator role</summary>

**Symptoms:** Active Owners/User Access Administrators can see the resource inside PIM, but every action (new eligible assignment, viewing role lists) returns an authorization error. Affects **all users** at that scope, not just one.

**Cause:** Someone (often an RBAC cleanup script or "remove unused service principals" audit) removed the MS-PIM service principal's own role assignment.

```powershell
$msPim = Get-AzADServicePrincipal -DisplayName "MS-PIM"
New-AzRoleAssignment -ObjectId $msPim.Id -RoleDefinitionName "User Access Administrator" -Scope "/subscriptions/<subId>"
```

**Rollback:** This is itself the fix for a prior unintended removal — no rollback path needed. Document why the assignment exists (add a description/tag) so it isn't removed again by the same audit process.
</details>

<details><summary>Fix 5 — Activation fails: RoleAssignmentExists / conflicting assignment</summary>

**Symptoms:** `New-AzRoleAssignmentScheduleRequest` (self-activation) fails with a conflict error even though the eligible schedule looks healthy.

**Cause:** A static/permanent Azure RBAC assignment for the **same role at the same scope** already exists for that principal — PIM won't create a duplicate active assignment.

```powershell
Get-AzRoleAssignment -Scope "/subscriptions/<subId>" -ObjectId <principalObjectId> |
  Where-Object { $_.RoleDefinitionName -eq "<RoleName>" }
```

**Fix:** Decide which model you want for this principal/role/scope — static or PIM — and remove the redundant one. Removing the static assignment is usually correct if the intent is JIT access:
```powershell
Remove-AzRoleAssignment -Scope "/subscriptions/<subId>" -ObjectId <principalObjectId> -RoleDefinitionName "<RoleName>"
```

**Rollback:** Re-create the static assignment with `New-AzRoleAssignment` if this turns out to be intentional (e.g., a break-glass account that should never require activation).
</details>

<details><summary>Fix 6 — User removed from PIM eligibility but still has access</summary>

**Symptoms:** An eligible assignment was deleted/expired, but the user still has the Azure role in practice.

**Cause:** PIM only manages the assignments it created. A separate, static assignment made directly via Access Control (IAM) — often from before PIM was adopted at that scope, or made by mistake alongside a PIM eligible assignment — is still active.

```powershell
Get-AzRoleAssignment -Scope "/subscriptions/<subId>" -ObjectId <principalObjectId>
```

**Fix:** Remove the static assignment explicitly:
```powershell
Remove-AzRoleAssignment -Scope "/subscriptions/<subId>" -ObjectId <principalObjectId> -RoleDefinitionName "<RoleName>"
```

**Rollback:** Re-add via `New-AzRoleAssignment` if removed in error.
</details>

---
## Escalation Evidence

```
=== PIM FOR AZURE RESOURCES — ESCALATION EVIDENCE PACK ===
Date/Time (UTC): ___________________
Tenant ID: ___________________
Subscription/Scope: ___________________
Affected Principal (UPN or Object ID): ___________________
Target Role: ___________________
Ticket/Change: ___________________

SYMPTOM:
[ ] Activation failing — error: ___________________
[ ] Eligible assignment missing/expired
[ ] Access denied despite active assignment
[ ] MS-PIM service principal permission issue (affects all users at scope)
[ ] Global Admin cannot see subscriptions in PIM
[ ] Static assignment conflicting with PIM assignment

SCOPE ONBOARDING CHECK:
Get-AzRoleManagementPolicyAssignment result: ___________________

MS-PIM SERVICE PRINCIPAL CHECK:
Has User Access Administrator at scope: [ ] Yes  [ ] No

ELIGIBLE SCHEDULE:
Status: ___________________
StartDateTime / EndDateTime: ___________________
MemberType (Direct/Group): ___________________

MOST RECENT ACTIVATION REQUEST:
RequestType: ___________________
Status: ___________________
StatusDetail (if Failed): ___________________

STATIC (NON-PIM) ASSIGNMENTS FOUND AT SCOPE:
___________________

ADDITIONAL NOTES:
___________________

Collected by: ___________________ at ___________________
```

---
## 🎓 Learning Pointers

- **This is a different product surface from Entra directory-role PIM**, even though it lives under the same "Privileged Identity Management" blade. Different portal path (Azure resources, not Microsoft Entra roles), different backing API (Azure Resource Manager, not Microsoft Graph), and a different PowerShell module (`Az.Resources`, not `Microsoft.Graph.Identity.Governance`). Mixing them up wastes real troubleshooting time because the wrong cmdlet simply returns nothing rather than erroring.
- **Onboarding a scope to PIM is a one-way door.** Once a management group or subscription is "managed" by PIM, it cannot be unmanaged — plan the rollout scope deliberately rather than experimenting on production subscriptions.
- **Role settings do not inherit down the resource hierarchy** — configuring a strict approval/MFA policy at the subscription level has zero effect on a resource group beneath it. Each scope's policy must be set individually.
- **PIM eligibility and static RBAC assignments are two independent systems that can silently coexist.** Deleting PIM eligibility never touches a static `Owner` grant made in Access Control (IAM) — always check both when access "won't go away."
- **"Elevate access" and "Access management for Azure resources" are two different Global Admin mechanisms** that solve the same "I can't see my subscriptions in PIM" symptom — one is a one-time self-service elevation, the other is a persistent tenant property. Prefer the one-time elevation and turn it back off when done.
- **MS Docs reference:** [What is Privileged Identity Management?](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-configure) · [Assign Azure resource roles in PIM](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-resource-roles-assign-roles) · [Troubleshoot resource access denied in PIM](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-troubleshoot)
