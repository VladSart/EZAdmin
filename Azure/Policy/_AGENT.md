# Azure Policy — Agent Instructions

## What's in this folder

Runbooks and scripts for **Azure Policy** as the resource-governance/compliance engine for Azure Resource Manager resources: policy definitions and initiatives (policy sets), assignment scope model (Management Group / Subscription / Resource Group cascade), all six effect types (`deny`, `denyAction`, `audit`/`auditIfNotExists`, `deployIfNotExists`, `modify`, `disabled`), remediation tasks and their managed-identity dependency, and exemptions vs. `notScopes`.

**The one thing to internalize before troubleshooting anything here:** Azure Policy has **no precedence/priority system**. Every assignment covering a scope evaluates independently and in parallel — a narrower-scope `audit` assignment never overrides a broader-scope `deny`. There is no single "which policy governs this resource" answer; it is always "all of them, simultaneously."

---

## Before responding, also check

- **Azure/Networking** (`AVNM-A.md`) — Azure Virtual Network Manager's dynamic network group membership is itself powered by Azure Policy-based conditions
- **Security/Defender** (`DefenderForCloud-A.md`) — regulatory compliance standards in Defender for Cloud are delivered as policy initiatives under the hood
- **ActiveDirectory** (`Troubleshooting/GroupPolicy/`) — on-prem Group Policy is a completely different, unrelated system despite sharing the word "policy"
- **Security/Purview** and **Security/ConditionalAccess** — Purview DLP policies and CA policies are different products entirely; do not conflate a "policy" ticket across these domains without confirming which system the client means

---

## Folder contents

| File | What it covers |
|------|----------------|
| `AzurePolicy-B.md` | Hotfix runbook — unexpected deny blocking a deployment, deployIfNotExists/modify remediation not firing, exemption not taking effect, initiative parameter conflicts |
| `AzurePolicy-A.md` | Deep dive — definition/initiative/assignment architecture, the no-precedence evaluation model, all six effect types explained, remediation task managed-identity RBAC dependency, phased Azure Blueprints retirement (begins 31 July 2026) |
| `Scripts/Get-AzurePolicyComplianceAudit.ps1` | Tenant/management-group-wide compliance state report: non-compliant resources, assignments with no remediation identity, orphaned exemptions |

---

## Common entry points

- **"A deployment is being blocked and we don't know which policy is doing it"** → `AzurePolicy-B.md` Triage — pull the deny reason from the deployment's error detail, it names the specific assignment
- **"deployIfNotExists / modify effect isn't remediating existing resources"** → `AzurePolicy-B.md` Common Fix Paths — almost always a missing or under-permissioned remediation task managed identity
- **"We need an exception for one resource without disabling the whole policy"** → `AzurePolicy-A.md` — exemptions vs. `notScopes`, and when to use which
- **"Designing governance for a new client's management group structure"** → `AzurePolicy-A.md` full architecture section
- **"Collect compliance state for a client report"** → `Scripts/Get-AzurePolicyComplianceAudit.ps1`
- **"Client asks about Azure Blueprints"** → `AzurePolicy-A.md` Learning Pointers — Blueprints is deprecated, phased retirement beginning 31 July 2026; steer new work toward Policy initiatives + ARM/Bicep templates instead

---

## Key diagnostic commands

```powershell
# Compliance state for a subscription
Get-AzPolicyState -SubscriptionId "<subId>" -Filter "ComplianceState eq 'NonCompliant'"

# All assignments at or above a given scope
Get-AzPolicyAssignment -Scope "/subscriptions/<subId>"

# Check remediation task status and its managed identity
Get-AzPolicyRemediation -Scope "/subscriptions/<subId>"

# Inspect a specific assignment's effect and parameters
Get-AzPolicyAssignment -Id "<assignmentId>" | Select-Object -ExpandProperty Properties

# Check exemptions covering a scope
Get-AzPolicyExemption -Scope "/subscriptions/<subId>"
```

---

## Key dependency chain

```
Policy Definition (policyRule: if/then + effect)
    │
    └── Initiative Definition (optional grouping, shared parameters/identity)
            │
            └── Assignment (binds definition/initiative to a scope — nothing evaluates without this)
                    │
                    ├── Scope: Management Group / Subscription / Resource Group (cascades down)
                    │       └── notScopes (hard exclusion) / Exemptions (time-bound, reason-coded exclusion)
                    │
                    └── Effect evaluated per matching resource:
                            ├── deny / denyAction → blocks the request outright
                            ├── audit / auditIfNotExists → flags non-compliance, no block
                            └── deployIfNotExists / modify → requires a Remediation Task
                                    └── Remediation Task needs its own Managed Identity with RBAC
                                        rights to perform the remediating deployment/modification
```

---

## Response format reminder (always 3 layers)

1. **Immediate action** — identify the exact assignment causing a deny/block, or the missing remediation identity (Mode B)
2. **Root cause** — no-precedence evaluation model, scope cascade, or remediation RBAC gap (Mode A)
3. **Prevention** — compliance audits, remediation identity coverage checks, exemption expiry tracking
