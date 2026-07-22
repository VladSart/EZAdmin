# Azure Lighthouse — Hotfix Runbook (Mode B: Ops)
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

Run these from Azure CLI or PowerShell authenticated to the **managing tenant**:

```powershell
# 1. What delegations does the managing tenant currently have into customer tenants?
Get-AzManagedServicesAssignment | Select-Object Name, RegistrationDefinitionId, Scope

# 2. What does a specific registration definition (the "offer") actually authorize?
Get-AzManagedServicesDefinition | Select-Object Name, ManagedByTenantId, RegistrationDefinitionName, Authorization

# 3. Confirm the signed-in user's own role assignment resolves under the delegation (run while
#    authenticated in the CONTEXT of the delegated subscription, not just the managing tenant)
Get-AzRoleAssignment -Scope "/subscriptions/<customerSubscriptionId>" |
  Where-Object { $_.ObjectId -eq (Get-AzContext).Account.ExtendedProperties.HomeAccountId }

# 4. Is the delegated subscription even visible? (requires switching context/tenant first)
Set-AzContext -Tenant <customerTenantId>
Get-AzSubscription | Where-Object { $_.Id -eq "<customerSubscriptionId>" }

# 5. Check for a stuck/conflicting registration definition from a prior onboarding attempt
Get-AzManagedServicesDefinition -Scope "/subscriptions/<customerSubscriptionId>"
```

| What you see | What it means |
|---|---|
| Delegation exists (`Get-AzManagedServicesAssignment` returns a result) but the user still can't act on the subscription | The user/group's `principalId` in the ARM template's `authorizations` doesn't match the signed-in user, or their token was issued before the assignment propagated — go to Fix 1 |
| No subscription visible at all when the managing-tenant user switches directory context | Onboarding never completed, or the registration assignment was removed/never deployed on the customer side — go to Fix 2 |
| New ARM template deployment fails with a role/authorization validation error | The `authorizations` array references an unsupported role — Owner, a role with `DataActions`, or a custom role — go to Fix 3 |
| A user was recently added to the authorized security group in the managing tenant but still has no access | Group membership changes for Lighthouse authorizations are **not** picked up automatically — the underlying `principalId` was the group's object ID, which doesn't require redeployment, but Entra token/group-claim propagation can lag; also confirm the group itself (not an individual) was actually used in the original template | 
| Re-deploying an updated template with new authorizations silently doesn't apply | Same `mspOfferName` was reused correctly (good) but the customer never re-ran the updated ARM template deployment — Lighthouse authorization changes require an explicit customer-side re-deployment, they don't push automatically | 
| Eligible (PIM-based) role never becomes active after "Activate" | No corresponding **permanent** role authorization exists for that principal — Lighthouse eligible roles require at least one permanent role present in the same offer, they cannot exist alone — go to Fix 4 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Managing tenant deploys an ARM template INTO the CUSTOMER tenant/subscription
  └── Template defines: mspOfferName, mspOfferDescription, managedByTenantId (managing tenant's ID)
        └── authorizations[] — each entry: principalId (managing-tenant user OR group object ID)
            + roleDefinitionId (built-in Azure role GUID)
              ├── Owner role — NOT SUPPORTED, template deployment will be rejected
              ├── Roles with DataActions (e.g., storage key retrieval) — NOT SUPPORTED
              ├── Custom roles / classic subscription admin roles — NOT SUPPORTED
              └── User Access Administrator — supported ONLY in constrained form via
                  delegatedRoleDefinitionIds (managed-identity role assignment use case only)
  └── Customer deploys the template at SUBSCRIPTION or RESOURCE GROUP scope (never a
      management group directly — that requires an Azure Policy deployIfNotExists workaround)
        └── Creates a Microsoft.ManagedServices/registrationDefinition (the "offer" contract)
              └── Creates a Microsoft.ManagedServices/registrationAssignment (links definition
                  to the actual scope) — THIS is what makes the delegation live
                    └── Managing-tenant principals now see the subscription/RG under
                        "My customers" in the Azure portal, WITHOUT any B2B guest invite,
                        without any Conditional Access/consent step in the customer tenant
                          └── (optional) Eligible authorizations — requires >=1 PERMANENT
                              role authorization present in the SAME offer; PIM activation
                              is evaluated in the MANAGING tenant, not the customer's
```

Key failure points:
- Updating `authorizations` only (same `mspOfferName`) replaces the delegation on next deploy; changing the **managing tenant** requires a **new** `mspOfferName` — reusing the old name with a different managing tenant does not work as expected
- If you reuse `principalId` values under a new `mspOfferName` without removing the old delegation first, users can silently lose access due to conflicting role assignments
- Only the customer (or a managing-tenant user holding the built-in "Managed Services Registration Assignment Delete Role") can remove a delegation — a managing-tenant admin with no such role assignment cannot self-service a cleanup
- Security group membership changes are the correct pattern (avoids a redeploy for every join/leave) — using individual `principalId` values for people is the most common design mistake found during troubleshooting

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the registration definition exists and inspect its authorizations**
```powershell
Get-AzManagedServicesDefinition -Scope "/subscriptions/<customerSubscriptionId>" |
  Select-Object -ExpandProperty Authorization
```
Expected: one or more entries with the exact `principalId` (object ID, not UPN/display name) and `roleDefinitionId` you expect to be authorized.

**Step 2 — Confirm the registration assignment is actually linked (not just the definition)**
```powershell
Get-AzManagedServicesAssignment -Scope "/subscriptions/<customerSubscriptionId>"
```
Expected: a `ProvisioningState` of `Succeeded`. A definition existing without a linked, succeeded assignment means onboarding never completed.

**Step 3 — Confirm the specific user/group principalId is correct**
```powershell
# In the MANAGING tenant
Get-AzADUser -UserPrincipalName "user@managingtenant.com" | Select-Object Id, DisplayName
# Compare Id (object ID) against the principalId in the authorizations list from Step 1
```
Expected: an exact GUID match. A UPN or display name typo/mismatch at template-authoring time is a common, silent cause of "delegated but this specific person still can't get in."

**Step 4 — Validate from the affected user's own session**
```powershell
Set-AzContext -Tenant <customerTenantId>
Get-AzRoleAssignment -Scope "/subscriptions/<customerSubscriptionId>"
```
Expected: the user's (or their group's) role assignment appears at the delegated scope, sourced from the Lighthouse assignment rather than a native customer-tenant RBAC grant.

**Step 5 — For eligible (PIM) roles specifically**
```powershell
# Confirm a permanent authorization exists in the SAME offer alongside the eligible one
Get-AzManagedServicesDefinition -Scope "/subscriptions/<customerSubscriptionId>" |
  Select-Object -ExpandProperty Authorization | Where-Object { $_.Type -ne 'Eligible' }
```
Expected: at least one non-eligible (permanent) authorization present — its absence is the most common reason an eligible role fails to activate.

---
## Common Fix Paths

<details><summary>Fix 1 — Delegation exists but a specific user still can't act on the subscription</summary>

**Cause:** The `principalId` in the deployed template doesn't match this user (wrong GUID, or the group they belong to wasn't actually the one authorized), or their Entra token predates the assignment and hasn't refreshed.

```powershell
# Confirm the correct object ID for the user (or the group they should be a member of)
Get-AzADUser -UserPrincipalName "user@managingtenant.com" | Select-Object Id
Get-AzADGroupMember -GroupObjectId <authorizedGroupObjectId> | Select-Object Id, DisplayName

# If the user is missing from the authorized group, add them there (no redeploy needed) —
# this is the entire point of authorizing a group instead of individuals
Add-AzADGroupMember -TargetGroupObjectId <authorizedGroupObjectId> -MemberObjectId <userObjectId>

# If the wrong principalId was baked into the template directly (an individual, not a group),
# this requires a template re-deploy from the customer with the corrected authorizations
```

**Rollback note:** Adding/removing group membership is non-destructive and instantly reversible. Correcting a baked-in individual `principalId` requires a customer-side redeploy — plan for a brief propagation window after.

</details>

<details><summary>Fix 2 — Subscription not visible at all under "My customers"</summary>

**Cause:** Onboarding was never completed successfully — a registration definition may exist without a corresponding, succeeded registration assignment, or the customer never ran the deployment at all.

```powershell
# Check for a definition without a completed assignment
Get-AzManagedServicesDefinition -Scope "/subscriptions/<customerSubscriptionId>"
Get-AzManagedServicesAssignment -Scope "/subscriptions/<customerSubscriptionId>"

# If a stuck/partial registration definition exists from a prior failed attempt, it may need
# to be removed before a clean re-deployment (requires Owner-equivalent rights in the
# CUSTOMER tenant — this is not something the managing tenant can self-service)
Remove-AzManagedServicesDefinition -Scope "/subscriptions/<customerSubscriptionId>" -Name <definitionName>
```

**Rollback note:** Removing a stuck registration definition is safe if the assignment never succeeded — confirm `ProvisioningState` isn't `Succeeded` before removing anything a live delegation might depend on.

</details>

<details><summary>Fix 3 — ARM template deployment fails on the authorizations section</summary>

**Cause:** The `authorizations` array references the Owner role, a role that carries `DataActions`, a custom role, or a classic subscription administrator role — none of which Azure Lighthouse supports.

```powershell
# Confirm which built-in roles are actually supported before retrying — swap the Owner role
# for Contributor + a scoped custom-role WORKAROUND is not available either; choose the
# closest supported built-in role instead (e.g., Contributor, or a specific service-scoped
# built-in role) and grant Owner-equivalent tasks via a documented exception process instead

# If the requirement is specifically "assign roles to a managed identity in the customer
# tenant" (a common policy-remediation scenario), use the CONSTRAINED User Access
# Administrator pattern instead of attempting a full Owner/UAA grant:
#   "authorizations": [{
#     "principalId": "<managingTenantPrincipalId>",
#     "roleDefinitionId": "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9",  // User Access Administrator
#     "delegatedRoleDefinitionIds": ["<built-in-role-guid-1>", "<built-in-role-guid-2>"]
#   }]
# This grants ONLY the ability to assign the listed roles to managed identities — no other
# User Access Administrator capability applies to this principal.
```

**Rollback note:** N/A — this is a template-authoring correction, not a live change to roll back.

</details>

<details><summary>Fix 4 — Eligible (PIM) role won't activate</summary>

**Cause:** Lighthouse eligible authorizations require at least one **permanent** role authorization to exist in the same offer — an eligible-only offer with no permanent role present will not allow activation.

```powershell
# Confirm a permanent authorization is present alongside the eligible one
Get-AzManagedServicesDefinition -Scope "/subscriptions/<customerSubscriptionId>" |
  Select-Object -ExpandProperty Authorization

# If missing, the customer must redeploy an updated template that includes at least one
# permanent authorization entry in addition to the eligible one(s)
```

**Rollback note:** N/A — this is a required architectural prerequisite, not a toggle to revert.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Azure Lighthouse Delegation Issue

Managing tenant ID: ____________
Customer tenant ID: ____________
Delegated scope (subscription/RG): ____________
mspOfferName in use: ____________
Affected user/group principalId: ____________
Role expected (roleDefinitionId/name): ____________
Registration definition ProvisioningState: ____________
Registration assignment ProvisioningState: ____________
Eligible or permanent authorization: ____________

Steps already attempted:
[ ] Confirmed registration definition + assignment both exist with Succeeded state
[ ] Confirmed the exact principalId matches the affected user or their authorized group
[ ] Confirmed no unsupported role (Owner/DataActions/custom) is in the authorizations
[ ] For eligible roles, confirmed a permanent authorization also exists in the same offer
[ ] Validated directly from the affected user's own session in the customer tenant context
```

---
## 🎓 Learning Pointers

- **Always authorize security groups, never individual users, in the `authorizations` array.** Group membership changes take effect without a redeploy; an individual `principalId` baked into the template requires a full customer-side ARM redeployment for every personnel change.
- **Owner, DataActions-bearing roles, and custom roles are all unsupported by Azure Lighthouse** — there is no workaround that grants true Owner-equivalent access through a delegation. Plan MSP operating models around the built-in role set from the start.
- **Eligible (PIM-based) authorizations cannot exist alone** — Lighthouse requires at least one permanent role authorization present in the same offer before any eligible role in that offer can be activated.
- **Changing the managing tenant requires a new `mspOfferName`; changing only the authorized roles/users does not.** Reusing the same offer name with a different managing tenant, or reusing `principalId` values across two different offer names without removing the old one first, are the two most common self-inflicted access-loss scenarios.
- **Delegation is native to subscriptions and resource groups only** — there is no direct management-group delegation scope; onboarding an entire management group requires an Azure Policy `deployIfNotExists` pattern that individually onboards each subscription within it.
- Related: [Azure Lighthouse architecture](https://learn.microsoft.com/en-us/azure/lighthouse/concepts/architecture), [Update a delegation](https://learn.microsoft.com/en-us/azure/lighthouse/how-to/update-delegation), [Create eligible authorizations](https://learn.microsoft.com/en-us/azure/lighthouse/how-to/create-eligible-authorizations), [Tenants, users, and roles in Azure Lighthouse scenarios](https://learn.microsoft.com/en-us/azure/lighthouse/concepts/tenants-users-roles)
