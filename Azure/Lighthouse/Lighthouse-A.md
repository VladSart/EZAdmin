# Azure Lighthouse — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Azure Lighthouse's cross-tenant delegated resource management architecture: registration definitions and registration assignments, the `authorizations` model, and the ARM-template-based onboarding/update/removal lifecycle
- Supported and unsupported role types (Owner, DataActions-bearing roles, custom roles, classic subscription administrator roles, and the constrained User Access Administrator pattern via `delegatedRoleDefinitionIds`)
- Eligible (PIM-based) authorizations — just-in-time activation, the mandatory-permanent-role prerequisite, and where auditing lives
- Delegation scope boundaries (subscription and resource group, and the management-group onboarding workaround via Azure Policy)
- Marketplace-published Managed Service offers as an alternative onboarding path to direct ARM template deployment
- MSP/multi-tenant operating model guidance: this repo's other MSSP access mechanisms this topic complements (GDAP for M365/Entra, direct B2B guest access) and when to use each

**Out of scope:**
- GDAP (Granular Delegated Admin Privileges) — Lighthouse delegates **Azure Resource Manager** (ARM) resource access; GDAP delegates **Microsoft 365/Entra ID admin role** access for CSP partners. The two are entirely separate delegation systems that happen to solve a parallel problem for different control planes — see `EntraID/Troubleshooting/GDAP-A.md` for the M365/Entra side
- Azure Active Directory B2B guest access — a different cross-tenant model requiring an explicit invite/consent step and creating a guest object in the resource tenant's directory; Lighthouse explicitly does **not** create any guest accounts or require consent from end users in the customer tenant
- Azure Lighthouse's use as a foundation for Microsoft Security Copilot's MSSP access model — referenced briefly where relevant, but see `Security/Copilot/SecurityCopilot-A.md` for that product's own three-mechanism MSSP access comparison
- Deploying and managing actual Azure resources within a delegated subscription once access is working — that's ordinary Azure resource management, out of scope for this topic which covers the delegation mechanism itself

**Assumptions:**
- You have Contributor-or-above rights (or the specific built-in roles referenced below) in whichever tenant you're troubleshooting from — most Lighthouse operations require action in **both** the managing and customer tenants at different points
- The `Az.ManagedServices` PowerShell module (or equivalent Azure CLI `az managedservices` commands) is available
- Familiarity with standard ARM template deployment mechanics — this topic focuses on the Lighthouse-specific `authorizations` schema, not general ARM template troubleshooting

---
## How It Works

<details><summary>Full architecture — the two-tenant, two-resource-type delegation model</summary>

### The Problem Azure Lighthouse Solves

Before Azure Lighthouse, an MSP or enterprise managing resources across multiple Azure tenants had exactly two options, both poor: create a separate user account in every customer tenant (a credential-sprawl and offboarding nightmare), or use Azure AD B2B guest access (which requires an explicit invite/consent flow per user, per tenant, and still surfaces the customer's tenant as a *separate* directory context the managing user has to switch into). Neither scales past a handful of customers, and neither gives the customer clean, auditable, revocable control over exactly what the managing party can do.

Azure Lighthouse solves this by introducing **delegated resource management**: the managing tenant's users and groups are granted RBAC roles at a specific scope (subscription or resource group) *inside the customer's tenant*, without ever creating an account, invite, or consent prompt for those users in the customer's directory. Critically, this delegation is a **one-way relationship evaluated entirely by Azure Resource Manager, not Entra ID** — there is no trust relationship, federation, or B2B object created between the two tenants' identity systems at all. The managing tenant's own Entra ID remains the sole authority for who those users/groups are; the customer tenant simply grants Azure RBAC rights to principals that live in someone else's directory, and ARM honors those principals' tokens (issued by their own home tenant) at the delegated scope.

### The Two ARM Resource Types

Every Lighthouse delegation is built from exactly two Azure Resource Manager resource types, always created together via a single ARM template deployment run **by the customer** (or by someone with sufficient rights in the customer tenant):

1. **`Microsoft.ManagedServices/registrationDefinitions`** — the "offer" itself. Defines `mspOfferName` (a display identifier for this specific delegation relationship), `mspOfferDescription`, `managedByTenantId` (the managing tenant's Entra tenant ID), and the `authorizations` array (the actual list of who gets what role). This resource is essentially a **template/contract** — it doesn't grant access by itself.
2. **`Microsoft.ManagedServices/registrationAssignments`** — links a registration definition to an actual scope (a specific subscription, or a specific resource group within one). **This is the resource that makes the delegation live.** A registration definition can technically exist without a corresponding successful assignment (e.g., from a failed or partial deployment), in which case no access is actually granted — a common point of confusion during onboarding troubleshooting.

Once both resources exist with `ProvisioningState: Succeeded`, the managing tenant's authorized principals see the delegated subscription/resource group appear directly in the Azure portal under **My customers**, and can act on it using ordinary Azure RBAC evaluation — from ARM's perspective, it's simply another role assignment, just one whose principal happens to live in a different tenant's directory.

### The `authorizations` Model and Its Deliberate Restrictions

Each entry in the `authorizations` array is a `{principalId, principalIdDisplayName, roleDefinitionId}` tuple — a managing-tenant user or (strongly preferred) security group object ID, paired with an Azure built-in role definition GUID. Microsoft deliberately restricts what can appear here, for reasons rooted in the trust model:

- **The Owner role is never supported.** Owner includes the ability to grant *further* role assignments — allowing a delegated Owner role would let the managing tenant re-delegate or escalate access the customer never explicitly reviewed, undermining the entire premise of an auditable, scoped delegation.
- **Roles carrying `DataActions`** (data-plane operations like retrieving a Storage Account's access keys, reading Key Vault secrets via RBAC data actions, etc.) **are not supported**, keeping Lighthouse strictly a control-plane (management-operations) delegation mechanism, not a data-access one.
- **Custom roles and classic (Co-Administrator/Service Administrator-era) subscription roles are not supported** — only modern Azure built-in roles.
- **User Access Administrator is supported only in a narrow, constrained form**, via the `delegatedRoleDefinitionIds` property. When present, `delegatedRoleDefinitionIds` lists specific built-in roles (excluding Owner and User Access Administrator itself) that the authorized principal may assign **only to managed identities** in the customer tenant — no other User Access Administrator capability (assigning roles to users/groups, removing arbitrary assignments) applies. This exists specifically to support the common MSP scenario of deploying an Azure Policy with a `deployIfNotExists`/`modify` effect that needs to grant a role to the policy's own system-assigned managed identity during remediation — see `Azure/Policy/AzurePolicy-A.md` for that side of the mechanism.

### Eligible (PIM-Based) Authorizations

Introduced as an enhancement layered on top of the base model, an `authorizations` entry can instead be typed as **eligible**, referencing Microsoft Entra Privileged Identity Management concepts (maximum activation duration between 30 minutes and 8 hours, MFA requirement, approver list) entirely evaluated **in the managing tenant** — the customer's own PIM configuration (if any) is irrelevant to this mechanism. A hard architectural constraint governs this: **at least one permanent (non-eligible) authorization must exist in the same offer** before any eligible role within it can be activated. This exists to guarantee there's always some baseline, always-on access path into the delegation for break-glass/initial-setup purposes — an offer consisting entirely of eligible roles with nothing permanently active is not a supported configuration.

Auditing for eligible-role activity is split by tenant and purpose: PIM activation events (who activated, when, approval chain) are visible in the **managing** tenant's own PIM audit log, while the resulting actions taken against the delegated resources appear in the **customer's** Azure Activity Log at the delegated scope — a deliberate split reflecting who owns which half of the accountability.

### Onboarding Paths: Direct ARM Template vs. Marketplace Managed Service Offer

Two distinct onboarding mechanisms exist:
1. **Direct ARM template deployment** — the managing tenant authors an ARM template (or the customer does, using a template the MSP supplies) and the **customer** deploys it against their own subscription/resource group. This is the most common path for bespoke/1:1 MSP-customer relationships and internal enterprise multi-tenant scenarios.
2. **A published Managed Service offer in Microsoft Marketplace** (public or private) — the MSP publishes an offer with one or more authorization "plans," and customers discover and accept it through the Marketplace UI rather than running a raw ARM template themselves. Updating authorizations under this model means publishing a **new version** of the offer for the customer to review and accept, rather than a silent redeploy.

Both paths ultimately produce the same underlying `registrationDefinition`/`registrationAssignment` resource pair — the difference is purely in how the customer discovers and consents to the offer, not in the resulting access model.

### Updating and Removing a Delegation

Changing only the `authorizations` (adding a role, changing who's authorized) can reuse the same `mspOfferName` — redeploying the updated template replaces the prior authorizations wholesale with whatever the new template defines; it is not additive. **Changing the managing tenant itself requires a new `mspOfferName`** — this is treated as an entirely new, separate offer, and if the old offer is left in place, both tenants retain access unless the old one is explicitly removed. Reusing `principalId` values across two different `mspOfferName`s without removing the first is explicitly called out by Microsoft as a scenario that can cause affected users to lose access entirely, due to conflicting/overlapping role assignment resolution — always remove the prior delegation first when changing offer identity.

Removal itself requires either a managing-tenant user holding the specific built-in **Managed Services Registration Assignment Delete Role** (a role that exists for exactly this purpose and nothing else), or the customer removing the offer directly from their own Azure portal (**My customers** is the managing-tenant view; the customer sees and manages incoming offers under **Service providers**). A managing-tenant admin with ordinary Owner/Contributor rights over their *own* tenant's resources has no inherent ability to remove a delegation without that specific role — a frequent point of confusion during cleanup.

</details>

---
## Dependency Stack

```
Managing tenant (MSP or enterprise central IT) — has its own independent Entra ID, its own
users/groups, its own RBAC — NO trust relationship or federation exists to the customer tenant
  │
  └── ARM template authored, listing:
        mspOfferName / mspOfferDescription / managedByTenantId (= managing tenant's ID)
        authorizations[]: {principalId (managing-tenant object ID), roleDefinitionId}
          ├── Owner role                     → REJECTED at deployment
          ├── Role with DataActions          → REJECTED at deployment
          ├── Custom / classic admin role    → REJECTED at deployment
          └── User Access Administrator      → allowed ONLY with delegatedRoleDefinitionIds
                                                (managed-identity role assignment only)
  │
  └── CUSTOMER deploys the template at subscription or resource-group scope
        (requires Owner-equivalent rights in the CUSTOMER tenant to deploy)
          │
          ├── Creates Microsoft.ManagedServices/registrationDefinition
          │     (the offer contract — no access granted yet by itself)
          │
          └── Creates Microsoft.ManagedServices/registrationAssignment
                (LINKS the definition to the actual scope — THIS grants live access)
                  │
                  └── ProvisioningState = Succeeded on BOTH resources
                        │
                        └── Managing-tenant principals now see the delegated
                            subscription/RG under "My customers" — evaluated by ARM
                            as an ordinary role assignment at that scope, sourced
                            from a principal whose home directory is elsewhere
                              │
                              └── (optional) Eligible authorizations — requires
                                  >=1 PERMANENT authorization in the SAME offer;
                                  PIM activation lives in the MANAGING tenant;
                                  resulting resource actions log to the CUSTOMER's
                                  Activity Log at the delegated scope
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Delegation shows as existing, but a specific person still can't act on the subscription | `principalId` mismatch — either an individual user's GUID was baked in incorrectly, or they're not actually a member of the authorized group | Compare the user's Entra object ID against the exact `principalId`/group membership in the deployed `authorizations` |
| Subscription never appears under "My customers" at all | Registration definition exists without a succeeded registration assignment — onboarding never actually completed | `Get-AzManagedServicesDefinition` + `Get-AzManagedServicesAssignment`, compare `ProvisioningState` on both |
| ARM template deployment fails validating the `authorizations` section | Owner role, a DataActions-bearing role, a custom role, or an unconstrained User Access Administrator grant was included — none are supported | Review the exact `roleDefinitionId` values against the supported-role list; use the constrained `delegatedRoleDefinitionIds` pattern if UAA is genuinely needed |
| Eligible role never activates via PIM | No permanent authorization exists in the same offer — eligible roles cannot stand alone | List all authorizations in the offer and confirm at least one is non-eligible |
| Changed the managing tenant, some users on both old and new tenant have access, some have none | The old offer (different managing tenant, same `mspOfferName` reused incorrectly, or `principalId` values reused across offers) wasn't removed before the new one was deployed | Inventory both offers' authorizations; remove the stale one explicitly rather than assuming the new deployment supersedes it |
| Managing-tenant admin can't remove a delegation they believe they should have rights to remove | They lack the specific **Managed Services Registration Assignment Delete Role** — ordinary Owner/Contributor over the managing tenant's own resources does not confer this | Confirm role assignment for the Managed Services Registration Assignment Delete Role specifically, or have the customer remove the offer from their side instead |
| Onboarded via a group, added a new team member, they still can't get in after a day | Confirm the user was actually added to the **correct** authorized group (not a similarly-named one) and that their token has refreshed — group-based authorization changes don't require a redeploy but do rely on normal Entra group-claim propagation timing | `Get-AzADGroupMember` against the exact group object ID referenced in the authorizations, not just a name match |
| Trying to delegate an entire management group and it silently doesn't cover new subscriptions added later | Lighthouse has no native management-group delegation scope — this requires an Azure Policy `deployIfNotExists` assignment scoped to the management group, which only onboards subscriptions the policy evaluates against, not a live continuous delegation of the group construct itself | Confirm the Azure Policy assignment (not a native Lighthouse resource) exists and its compliance state across all subscriptions in scope |
| A policy remediation task needs to assign a role to a system-assigned managed identity in the customer tenant, deployment fails on permissions | The standard authorization set doesn't include a delegated User Access Administrator grant — this is the specific, narrow scenario `delegatedRoleDefinitionIds` exists for | Add a constrained UAA authorization listing only the specific roles the managed identity needs, per the ARM syntax in Remediation Playbook 2 |

---
## Validation Steps

**Step 1 — Inventory every delegation the managing tenant currently holds**
```powershell
Get-AzManagedServicesAssignment | Select-Object Name, RegistrationDefinitionId, Scope, ProvisioningState
```
Expected: one entry per live customer delegation, all `Succeeded`.

**Step 2 — Inspect the exact authorizations for a specific delegation**
```powershell
$def = Get-AzManagedServicesDefinition -Scope "/subscriptions/<customerSubscriptionId>"
$def.Authorization | Format-Table PrincipalId, PrincipalIdDisplayName, RoleDefinitionId
```
Expected: every authorized principal and role matches what was actually intended — this is the single most useful validation step for "who can do what" questions.

**Step 3 — Confirm role resolution from inside the delegated scope**
```powershell
Set-AzContext -Tenant <customerTenantId> -Subscription <customerSubscriptionId>
Get-AzRoleAssignment -Scope "/subscriptions/<customerSubscriptionId>"
```
Expected: the delegated principals' role assignments appear here, sourced from the Lighthouse registration rather than a native customer-tenant grant — confirms end-to-end resolution, not just that the ARM resources exist.

**Step 4 — For eligible roles, confirm the permanent-role prerequisite**
```powershell
$def.Authorization | Where-Object { $_.Type -eq 'Eligible' }
$def.Authorization | Where-Object { $_.Type -ne 'Eligible' }
```
Expected: both non-empty when eligible authorizations are in use — an eligible-only offer is a misconfiguration, not a valid minimal-permanent-access design.

**Step 5 — Confirm no unsupported role type is present, proactively**
```powershell
$def.Authorization | Where-Object {
  $_.RoleDefinitionId -in @('8e3af657-a8ff-443c-a75c-2fe8c4bcb635')  # Owner GUID, for example
}
```
Expected: empty result. Cross-reference every `roleDefinitionId` against the current supported-role guidance before assuming a stale template will still deploy cleanly after a re-run.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Confirm Which Two ARM Resources Exist and Their State
1. Check for both `registrationDefinition` and `registrationAssignment` at the target scope
2. A definition without a succeeded assignment means onboarding is incomplete — do not assume the definition's mere existence implies working access

### Phase 2 — Validate the Authorizations Content
1. Pull the full `authorizations` array and check every `principalId` against the actual intended user/group object ID
2. Check every `roleDefinitionId` against the supported-role constraints (no Owner, no DataActions, no custom roles, UAA only if constrained via `delegatedRoleDefinitionIds`)

### Phase 3 — Validate From the Affected Principal's Own Context
1. Switch directory/tenant context to the customer tenant as the affected user (or impersonate via `Get-AzRoleAssignment` lookups against their object ID)
2. Confirm the role assignment resolves at the actual delegated scope, not just that the Lighthouse resources exist upstream

### Phase 4 — For Eligible Roles, Validate the PIM Layer Specifically
1. Confirm the permanent-role prerequisite is satisfied
2. Confirm activation is being attempted in the **managing** tenant's PIM interface, not the customer's — a common point of confusion since the customer subscription is what's being acted on

### Phase 5 — For Multi-Offer / Migration Scenarios
1. Inventory every `mspOfferName` present against the target scope, not just the one currently being modified
2. Explicitly remove any stale/superseded offer before assuming a new deployment fully supersedes it

---
## Remediation Playbooks

<details><summary>Playbook 1 — Onboarding a new customer via direct ARM template</summary>

**Scenario:** Standing up a fresh Lighthouse delegation for a new customer subscription, using groups (not individuals) for every authorization.

**Step 1 — Identify or create the managing-tenant security group(s) for each role tier**
```powershell
# In the MANAGING tenant
New-AzADGroup -DisplayName "Lighthouse-CustomerX-Contributors" -MailNickname "LighthouseCustomerXContrib"
```

**Step 2 — Author the ARM template's authorizations section referencing the group object IDs**
```json
{
  "mspOfferName": "Contoso MSP - Managed Services",
  "mspOfferDescription": "Contoso MSP delegated management",
  "managedByTenantId": "<managingTenantId>",
  "authorizations": [
    {
      "principalId": "<contributorsGroupObjectId>",
      "principalIdDisplayName": "Lighthouse-CustomerX-Contributors",
      "roleDefinitionId": "b24988ac-6180-42a0-ab88-20f7382dd24c"
    }
  ]
}
```

**Step 3 — Customer deploys the template against their subscription or resource group**
```powershell
# Run BY THE CUSTOMER, in their own tenant/subscription context
New-AzSubscriptionDeployment -Name "LighthouseOnboarding" -Location "eastus" `
  -TemplateFile "./lighthouse-onboarding.json"
```

**Step 4 — Confirm from the managing tenant**
```powershell
Get-AzManagedServicesAssignment -Scope "/subscriptions/<customerSubscriptionId>"
```

**Rollback note:** If onboarding needs to be undone, removal requires either the Managed Services Registration Assignment Delete Role in the managing tenant, or the customer removing the offer from their own portal.

</details>

<details><summary>Playbook 2 — Constrained User Access Administrator for policy-remediation managed identities</summary>

**Scenario:** An Azure Policy with a `deployIfNotExists`/`modify` effect needs its system-assigned managed identity to receive a role assignment in the customer's subscription during remediation — full User Access Administrator is not appropriate to grant.

**Step 1 — Add a constrained UAA authorization to the offer**
```json
{
  "principalId": "<managingTenantPrincipalOrGroupId>",
  "principalIdDisplayName": "Lighthouse-PolicyRemediation",
  "roleDefinitionId": "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9",
  "delegatedRoleDefinitionIds": [
    "b24988ac-6180-42a0-ab88-20f7382dd24c"
  ]
}
```
This grants the ability to assign **only** the Contributor role (in this example) to managed identities — nothing else User Access Administrator would normally permit.

**Step 2 — Redeploy the updated template (same `mspOfferName`, since only authorizations changed)**

**Step 3 — Validate the managed identity's role assignment is created successfully during the next policy remediation task run**

**Rollback note:** Removing this authorization entry and redeploying reverts to the prior, more restricted authorization set — no residual grant persists once the entry is gone.

</details>

<details><summary>Playbook 3 — Migrating a delegation to a new managing tenant</summary>

**Scenario:** An MSP consolidates onto a new managing tenant (e.g., after an acquisition/tenant merge) and needs to move existing customer delegations over cleanly.

**Step 1 — Inventory the existing offer's authorizations for reference**
```powershell
Get-AzManagedServicesDefinition -Scope "/subscriptions/<customerSubscriptionId>" |
  Select-Object -ExpandProperty Authorization
```

**Step 2 — Author a new ARM template with a NEW `mspOfferName` and the new tenant's `managedByTenantId`**

**Step 3 — Remove the OLD delegation before deploying the new one**, especially if any `principalId` values will be reused under the new offer
```powershell
Remove-AzManagedServicesAssignment -Scope "/subscriptions/<customerSubscriptionId>" -Name <oldAssignmentName>
```

**Step 4 — Customer deploys the new template**

**Step 5 — Validate exclusively from the new managing tenant's context, and confirm the old tenant no longer resolves any access**

**Rollback note:** Keep a record of the old offer's exact authorizations before removal — if migration needs to be reversed, redeploying the original template recreates the prior state, but any interim access changes made under the new offer will need to be manually reconciled.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Azure Lighthouse Delegation Evidence Collector
.NOTES     Run authenticated to the managing tenant with Az.ManagedServices available.
#>

$reportPath = "C:\Temp\LighthouseEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== All Registration Assignments (Managing Tenant View) ===" | Out-File "$reportPath\01_Assignments.txt"
Get-AzManagedServicesAssignment | Format-List | Out-File "$reportPath\01_Assignments.txt" -Append

"=== All Registration Definitions ===" | Out-File "$reportPath\02_Definitions.txt"
Get-AzManagedServicesDefinition | Format-List | Out-File "$reportPath\02_Definitions.txt" -Append

"=== Per-Definition Authorization Detail ===" | Out-File "$reportPath\03_Authorizations.txt"
foreach ($def in (Get-AzManagedServicesDefinition)) {
  "--- $($def.RegistrationDefinitionName) ---" | Out-File "$reportPath\03_Authorizations.txt" -Append
  $def.Authorization | Format-Table PrincipalId, PrincipalIdDisplayName, RoleDefinitionId -AutoSize |
    Out-File "$reportPath\03_Authorizations.txt" -Append
}

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| List all Lighthouse delegations (managing tenant) | `Get-AzManagedServicesAssignment` |
| Inspect a specific registration definition's authorizations | `Get-AzManagedServicesDefinition -Scope "/subscriptions/<id>"` |
| Switch context into a customer tenant | `Set-AzContext -Tenant <customerTenantId>` |
| Validate role resolution at the delegated scope | `Get-AzRoleAssignment -Scope "/subscriptions/<id>"` |
| Remove a registration assignment (requires the delete role) | `Remove-AzManagedServicesAssignment -Scope "/subscriptions/<id>" -Name <name>` |
| Remove a stuck/orphaned registration definition | `Remove-AzManagedServicesDefinition -Scope "/subscriptions/<id>" -Name <name>` |
| Look up a managing-tenant user's object ID | `Get-AzADUser -UserPrincipalName <upn>` |
| Check group membership for an authorized group | `Get-AzADGroupMember -GroupObjectId <id>` |
| Deploy/update the onboarding ARM template (customer-side) | `New-AzSubscriptionDeployment -TemplateFile <path>` |

---
## 🎓 Learning Pointers

- **Lighthouse is an ARM-only, one-way delegation with zero identity federation.** No trust relationship, B2B guest object, or consent prompt is created between tenants — the customer simply grants Azure RBAC to principals whose home directory is entirely someone else's. This is architecturally distinct from GDAP (M365/Entra admin-role delegation) and B2B guest access, and the three are not interchangeable — pick the one matching the control plane actually being delegated.
- **Owner, DataActions-bearing roles, and custom roles are permanently unsupported**, not a temporary limitation — there is no supported path to a true Owner-equivalent delegated grant. The constrained User Access Administrator pattern via `delegatedRoleDefinitionIds` is the narrow, purpose-built exception, scoped specifically to managed-identity role assignment for policy remediation scenarios.
- **Always authorize groups, never individuals.** This is the single highest-leverage design decision in any Lighthouse onboarding template — it turns every personnel change into a group-membership edit instead of a customer-side ARM redeployment.
- **Eligible authorizations require a permanent authorization to coexist in the same offer.** This is a hard architectural rule, not a best-practice suggestion — an eligible-only offer will never allow activation.
- **A registration definition existing does not mean access is live** — always confirm the paired registration assignment also exists with `ProvisioningState: Succeeded`. This is the most common false-positive in "we set up the delegation" troubleshooting.
- **There is no native management-group delegation scope.** Apparent management-group-wide Lighthouse coverage is always an Azure Policy `deployIfNotExists` construct onboarding subscriptions individually, not a single native delegation of the group itself — new subscriptions added to the group need the policy to evaluate and remediate them, not an automatic inherited delegation.
- Related: [Azure Lighthouse architecture](https://learn.microsoft.com/en-us/azure/lighthouse/concepts/architecture), [Update a delegation](https://learn.microsoft.com/en-us/azure/lighthouse/how-to/update-delegation), [Create eligible authorizations](https://learn.microsoft.com/en-us/azure/lighthouse/how-to/create-eligible-authorizations), [Deploy a policy that can be remediated within a delegated subscription](https://learn.microsoft.com/en-us/azure/lighthouse/how-to/deploy-policy-remediation), [Onboard all subscriptions in a management group](https://learn.microsoft.com/en-us/azure/lighthouse/how-to/onboard-management-group)
