# Azure Lighthouse — Agent Instructions

## What's in this folder

Runbooks and scripts for **Azure Lighthouse** — cross-tenant delegated resource management for MSPs and multi-tenant enterprises. Covers the two-ARM-resource-type architecture (`registrationDefinition`/`registrationAssignment`), the `authorizations` model and its permanently unsupported role types (Owner, DataActions-bearing roles, custom roles), the constrained User Access Administrator pattern via `delegatedRoleDefinitionIds`, eligible (PIM-based) authorizations and their mandatory-permanent-role prerequisite, onboarding/update/removal lifecycle via direct ARM template or Marketplace Managed Service offer, and the subscription/resource-group delegation scope (no native management-group scope). This is a **management-plane, Azure Resource Manager only** delegation mechanism — it does not touch Microsoft 365/Entra ID admin roles (see GDAP) and does not create any B2B guest account or trust relationship between tenants.

---

## Before responding, also check

- **EntraID/Troubleshooting/GDAP** — if the delegation question is actually about Microsoft 365/Entra ID admin role access for a CSP partner, not Azure resource (ARM) access — the two systems solve a parallel problem for entirely different control planes and are not interchangeable
- **Azure/Policy** — if the scenario involves a policy remediation task needing to assign a role to a managed identity in a delegated customer tenant, the constrained User Access Administrator pattern here is the Lighthouse-side half of that mechanism
- **Security/Copilot** — if the question is about MSSP access to Security Copilot specifically, Lighthouse is one of three non-interchangeable access mechanisms discussed there (alongside B2B tenant switching and GDAP) — see `Security/Copilot/SecurityCopilot-A.md`
- **Azure/KeyVault**, **Azure/Policy** — ordinary Azure resource troubleshooting once Lighthouse access itself is confirmed working belongs to the relevant resource-specific topic, not here

---

## Folder contents

| File | What it covers |
|------|----------------|
| `Lighthouse-B.md` | Hotfix runbook — delegation-not-working triage (principalId mismatch, incomplete onboarding, unsupported-role deployment failures, stuck eligible roles), group-vs-individual authorization fix paths |
| `Lighthouse-A.md` | Deep dive — registrationDefinition/registrationAssignment architecture, the `authorizations` model and its restrictions, eligible/PIM mechanics, onboarding/update/removal lifecycle, constrained UAA pattern, management-group scope workaround, GDAP/B2B disambiguation |
| `Scripts/Get-LighthouseDelegationAudit.ps1` | Read-only audit of every Lighthouse delegation visible to the current session: assignment/definition provisioning state, full authorization detail, unsupported-role and eligible-without-permanent-role flagging, individual-vs-group principal smell detection |

---

## Common entry points

- **"Delegation exists but a specific person can't act on the subscription"** → `Lighthouse-B.md` Fix 1 — check principalId/group membership match first
- **"Customer's subscription never showed up under My customers"** → `Lighthouse-B.md` Fix 2 — registration definition without a succeeded assignment means onboarding never finished
- **"ARM template deployment fails on the authorizations section"** → `Lighthouse-B.md` Fix 3 — Owner, DataActions roles, and custom roles are all permanently unsupported
- **"Eligible/PIM role won't activate"** → `Lighthouse-B.md` Fix 4 — requires a permanent authorization present in the same offer, cannot exist alone
- **"How is this different from GDAP?"** → `Lighthouse-A.md` Scope & Assumptions — Lighthouse is ARM/Azure-resource delegation, GDAP is M365/Entra admin-role delegation, no overlap
- **"Need to move a customer to a new managing tenant"** → `Lighthouse-A.md` Remediation Playbook 3 — requires a new `mspOfferName`, remove the old offer first
- **"Policy remediation needs to assign a role to a managed identity in the customer tenant"** → `Lighthouse-A.md` Remediation Playbook 2 — constrained User Access Administrator via `delegatedRoleDefinitionIds`
- **"Audit every delegation we currently hold"** → `Scripts/Get-LighthouseDelegationAudit.ps1`

---

## Key diagnostic commands

```powershell
# Every delegation visible to the current managing-tenant session
Get-AzManagedServicesAssignment | Select-Object Name, RegistrationDefinitionId, Scope, ProvisioningState

# Full authorization detail for a specific delegation
(Get-AzManagedServicesDefinition -Scope "/subscriptions/<id>").Authorization |
  Format-Table PrincipalId, PrincipalIdDisplayName, RoleDefinitionId

# Validate role resolution from inside the delegated scope
Set-AzContext -Tenant <customerTenantId>
Get-AzRoleAssignment -Scope "/subscriptions/<id>"
```

---

## Key dependency chain

```
Managing tenant (independent Entra ID — NO trust/federation to customer tenant)
    │
    └── ARM template: mspOfferName, managedByTenantId, authorizations[]
            (Owner / DataActions roles / custom roles ALWAYS rejected;
             User Access Administrator only via delegatedRoleDefinitionIds)
                │
                └── CUSTOMER deploys at subscription or resource-group scope
                        │
                        ├── Microsoft.ManagedServices/registrationDefinition (the offer — no
                        │     access granted by itself)
                        │
                        └── Microsoft.ManagedServices/registrationAssignment (LINKS definition
                              to scope — this is what makes access live)
                                │
                                └── Managing-tenant principals resolve as ordinary RBAC role
                                    assignments at the delegated scope, no B2B/consent step
                                        │
                                        └── (optional) Eligible authorizations — requires
                                            >=1 permanent authorization in the SAME offer;
                                            PIM activation lives in the MANAGING tenant
```

---

## Response format reminder (always 3 layers)

1. **Hotfix** — confirm registration definition + assignment both exist and are `Succeeded`, then check the specific authorization entry (Mode B)
2. **Deep Dive** — the two-ARM-resource architecture, authorization restrictions, and eligible/PIM mechanics (Mode A)
3. **Learning Pointers** — GDAP/B2B disambiguation, group-vs-individual design, and the permanently-unsupported-role list to plan around from the start
