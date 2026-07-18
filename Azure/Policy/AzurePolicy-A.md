# Azure Policy — Reference Runbook (Mode A: Deep Dive)
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

Covers Azure Policy as the resource-governance/compliance engine for Azure Resource Manager resources: policy definitions and initiatives (policy sets), assignments and their scope model, all six effect types (`deny`, `denyAction`, `audit`/`auditIfNotExists`, `deployIfNotExists`, `modify`, `disabled`/`manual`), remediation tasks and their managed-identity dependency, and exemptions.

Does **not** cover: Azure Blueprints (deprecated, phased retirement beginning 31 July 2026 with full retirement 31 Jan 2027 — see Learning Pointers), Azure landing zone / management group design as a discipline (Policy is one tool used there, not the design itself), Microsoft Purview DLP policies or Conditional Access policies (different products entirely despite the shared "policy" name — see `Security/Purview/` and `Security/ConditionalAccess/`), Azure Virtual Network Manager's dynamic-membership Azure Policy integration mechanics (covered from AVNM's side in `Azure/Networking/AVNM-A.md`), or on-prem Group Policy (see `ActiveDirectory/Troubleshooting/GroupPolicy/`).

---
## How It Works

<details><summary>Full architecture</summary>

**The three building blocks:**

1. **Policy Definition** — a JSON document containing a `policyRule` (an `if`/`then` condition against resource properties) and an `effect`. Built-in definitions ship from Microsoft (thousands exist); custom definitions are authored per-tenant. A definition alone does nothing until assigned.

2. **Initiative (Policy Set) Definition** — a named group of policy definitions, each with a `policyDefinitionReferenceId`, assigned together as one logical control (e.g. "CIS Microsoft Azure Foundations Benchmark"). Initiatives share a single assignment identity and a single set of parameters across all member definitions, which is the main reason to group policies rather than assign them individually.

3. **Policy (or Initiative) Assignment** — the binding of a definition/initiative to a **scope**. Nothing is evaluated until an assignment exists. Assignment scope can be a Management Group, Subscription, Resource Group, or (rarely) an individual resource, and it **cascades down**: an assignment at a Management Group applies to every subscription and resource group beneath it, unless explicitly excluded via `notScopes`.

**The critical architectural point most engineers get wrong:** Azure Policy has **no precedence/priority system**. Unlike NSG rules (numeric priority, first match wins) or GPO (most-specific-OU wins), every assignment that covers a given scope is evaluated **independently and in parallel**. If five different assignments cover a resource and even one has a `deny` effect that matches, the request is blocked — a narrower-scope `audit` assignment does not override a broader-scope `deny`. There is no single authoritative place to check "which policy governs this resource"; the honest answer is always "all of them, simultaneously."

**Effects, precisely:**

| Effect | When it fires | Blocks the request? | Self-heals? |
|---|---|---|---|
| `deny` | At request time (ARM validation) | Yes — 403 `RequestDisallowedByPolicy` | N/A — nothing was created |
| `denyAction` | At request time, **DELETE only** | Yes — 403, resource shows `Protected` state | N/A |
| `disabled` | Never evaluates | No | No |
| `manual` | Never auto-evaluates — compliance is set by a human/API call against an attestation | No | No |
| `audit` | Post-creation, on evaluation cycle | No — logs a warning, allows the request | No |
| `auditIfNotExists` | Post-creation, checks for a *related* resource's existence | No | No |
| `deployIfNotExists` | Post-creation, checks for a related resource; can deploy one if missing | No | Yes — via Remediation Task only |
| `modify` | Post-creation (and at request time for `Modify.Enforcement`), can add/update/remove specific properties (commonly tags) | No (for the append/modify path) | Yes — via Remediation Task only |

`deployIfNotExists` and `modify` are the only effects with any remediation capability, and even then **only when a Remediation Task is explicitly run** — there is no ambient background process that fixes non-compliant resources on its own. A resource created five minutes after the assignment goes live gets evaluated automatically going forward, but a resource that already existed when the assignment was created is stuck NonCompliant until someone runs a remediation task against it.

**Compliance evaluation triggers** (from Microsoft's documented evaluation model):
- A resource is created or updated within an assigned scope → evaluated within ~15 minutes.
- A new policy/initiative assignment is created → evaluation begins after the assignment propagates to the scope (~5 minutes), covering existing resources within that scope shortly after (~30 minutes total for the full cycle to start producing results).
- An existing assignment or its underlying definition is updated → triggers re-evaluation.
- The standard **24-hour compliance evaluation cycle** — this is the backstop that catches everything else, including resources changed outside of Azure Policy's own trigger events, drift from manual portal edits, or changes made by another automation tool.

There is no SLA on how long a full evaluation cycle takes to complete for a large estate — Microsoft explicitly documents this as "no predefined expectation of completion time" for tenants with many resources.

**Remediation task mechanics:**

A remediation task is a discrete, on-demand (or scheduled via automation) operation that:
1. Queries which resources are currently NonCompliant against a specific `deployIfNotExists`/`modify` assignment.
2. For each, deploys the ARM template embedded in the policy's `then.details` block (for `deployIfNotExists`) or applies the property operations (for `modify`).
3. Authenticates as the assignment's **managed identity** — either system-assigned (created automatically when the assignment is made with `-IdentityType SystemAssigned`, or via the portal's "Create a managed identity" checkbox) or user-assigned.
4. The identity needs every RBAC role listed in the policy definition's `policyRule.then.details.roleDefinitionIds` array, granted **at or above the assignment's own scope**. If the identity's role assignment is scoped narrower than the policy assignment (a very common setup mistake — e.g. granting the role only at the RG where someone happened to test the policy first), remediation silently succeeds for in-scope resources and fails for everything else with no obvious pattern.

**Exemptions vs. `notScopes` — two structurally different exclusion mechanisms:**

- **`notScopes`** is a property on the assignment itself — a list of scope paths (subscriptions, RGs, resource IDs) that the assignment simply does not apply to. It is permanent (until manually edited), carries no reason/expiration/category metadata, and is invisible unless someone specifically inspects the assignment object.
- **Policy Exemptions** (`Microsoft.Authorization/policyExemptions`) are first-class objects, separate from the assignment. Each exemption targets a specific scope against a specific assignment, carries a mandatory `ExemptionCategory` (`Waiver` — the requirement doesn't apply here — or `Mitigated` — the requirement is met a different way), an optional `ExpiresOn` date, and a display name/description for audit purposes. **Exemptions with no expiration date are a common source of governance drift** — they were meant as temporary but nobody set a review date, so the exception silently becomes permanent. An exemption that DOES have an expiration silently stops applying once that date passes — the resource reverts to being evaluated normally with no active notification.

</details>

---
## Dependency Stack

```
Layer 6: Compliance reporting (portal / Get-AzPolicyState / Azure Resource Graph)
             — reflects the LAST completed evaluation, not real-time state
Layer 5: Remediation Task execution (deployIfNotExists / modify effects only)
             — requires: managed identity + correctly-scoped RBAC roles
Layer 4: Effect evaluation (deny / denyAction / audit / auditIfNotExists / deployIfNotExists / modify / disabled / manual)
             — evaluated per-assignment, INDEPENDENTLY, no cross-assignment precedence
Layer 3: Exemptions (Microsoft.Authorization/policyExemptions) + notScopes exclusions
             — checked before effect evaluation; a matching exemption suppresses the effect entirely
Layer 2: Policy (or Initiative) Assignment — binds a definition to a scope
             — Management Group > Subscription > Resource Group (cascades downward)
Layer 1: Policy Definition / Initiative Definition — the rule itself (JSON policyRule + effect)
             — built-in (Microsoft-authored) or custom; inert until assigned
Layer 0: Azure Resource Manager — the request pipeline every effect ultimately intercepts (deny/denyAction)
             or observes after the fact (audit/deployIfNotExists/modify)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Deployment fails immediately with `RequestDisallowedByPolicy` | `deny` effect matched at request time | Pull the full ARM error `Details` array for `policyAssignmentId` |
| A resource DELETE fails with 403 but the resource was created fine | `denyAction` effect — blocks delete only, not create/update | `Get-AzPolicyState` on the resource — `ComplianceState = Protected` |
| Resource deployed fine but shows NonCompliant afterward | Post-creation `audit`/`auditIfNotExists` effect | Check the definition's `then.effect` before assuming a fix exists |
| NonCompliant resource never "fixes itself" despite a deployIfNotExists policy | No remediation task has ever been run for this resource | `Get-AzPolicyRemediation` for the assignment — likely empty or task predates the resource |
| Remediation task runs but `ProvisioningState = Failed` for some resources, succeeds for others | Managed identity's RBAC role scoped narrower than assignment scope | Compare the identity's `Get-AzRoleAssignment` scope against the assignment's own scope |
| Exemption exists but the deny/audit still fires | Exemption expired, or scoped to a different resource/assignment pair than expected | `Get-AzPolicyExemption` — check `ExpiresOn` and confirm `PolicyAssignmentId` matches |
| Two engineers disagree about "which policy is in charge" | There is no single authoritative policy — all assignments covering the scope evaluate independently | List every assignment at every scope level above the resource (MG → sub → RG) |
| Compliance dashboard looks stale after a confirmed fix | Standard 24h evaluation cycle hasn't run yet | `Start-AzPolicyComplianceScan` to force re-evaluation |
| Policy blocks a resource in one subscription but not an identical one in another | Assignment scope only covers the first subscription, or a `notScopes`/exemption differs between them | Compare `Get-AzPolicyAssignment -Scope` across both subscriptions |
| Initiative shows partial compliance even though the "main" policy passed | Each member definition inside an initiative reports compliance independently | `Get-AzPolicyState` filtered by `PolicyDefinitionReferenceId`, not just the initiative name |
| A built-in policy's effect can't be changed by editing the definition | Built-in definitions are read-only; only assignment-level effect PARAMETERS (if the definition exposes one) can override it | Check `(Get-AzPolicyDefinition).Properties.Parameters` for an `effect` parameter with `allowedValues` |
| Remediation deployed something unexpected (e.g. a diagnostic setting) that now needs cleanup | `deployIfNotExists` effects create companion resources — this is expected behavior, not a bug | Review the policy definition's `then.details.deployment.properties.template` to see exactly what it deploys |
| Deployment blocked, but the same template deployed fine yesterday | A policy/initiative was newly assigned or updated in the intervening time | `Get-AzPolicyAssignment` sorted by last-modified; check for recent governance changes |

---
## Validation Steps

1. **Confirm the assignment exists and covers the expected scope.**
   ```powershell
   Get-AzPolicyAssignment -Scope "<resourceId>"
   ```
   Expected: at least one assignment listed if any governance is supposed to apply here. Empty result on a resource the client insists is governed means the assignment is at a different scope (or was deleted) — check parent scopes explicitly.

2. **Confirm the definition's actual effect (don't trust the display name).**
   ```powershell
   (Get-AzPolicyDefinition -Id "<policyDefinitionId>").Properties.PolicyRule.then.effect
   ```
   Expected: one of the eight effect strings. A definition named "Audit VMs without managed disks" that actually has `effect: deny` (because someone edited an assignment-level parameter) is a real, if rare, surprise worth ruling out.

3. **Confirm compliance state reflects reality, not stale data.**
   ```powershell
   Get-AzPolicyState -ResourceId "<resourceId>" -Top 1 | Select-Object Timestamp, ComplianceState
   ```
   Bad sign: `Timestamp` older than 24 hours despite a known recent change — trigger `Start-AzPolicyComplianceScan` before drawing conclusions.

4. **Confirm remediation task success, not just existence.**
   ```powershell
   Get-AzPolicyRemediation -PolicyAssignmentId "<policyAssignmentId>" |
       Select-Object Name, ProvisioningState, DeploymentSummary
   ```
   Expected: `ProvisioningState = Succeeded` and `DeploymentSummary.FailedCount = 0`. A `Succeeded` provisioning state with a nonzero `FailedCount` means the task itself ran but individual resource deployments inside it failed — check `Get-AzPolicyRemediationDeployment` for per-resource detail.

5. **Confirm the managed identity's RBAC coverage matches the assignment's real footprint.**
   ```powershell
   $assignment = Get-AzPolicyAssignment -Name "<assignmentName>"
   Get-AzRoleAssignment -ObjectId $assignment.Identity.PrincipalId | Select-Object RoleDefinitionName, Scope
   ```
   Bad sign: role scope is a single Resource Group while the policy assignment scope is the whole subscription — remediation will only ever work inside that one RG.

6. **Confirm an exemption is both current and correctly targeted.**
   ```powershell
   Get-AzPolicyExemption -Scope "<resourceId>" |
       Select-Object Name, PolicyAssignmentId, ExemptionCategory, ExpiresOn
   ```
   Bad sign: `ExpiresOn` in the past, or `PolicyAssignmentId` pointing at a different assignment than the one actually firing.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Classify the symptom**
Determine block-at-request (`deny`/`denyAction`) vs. flag-after-the-fact (`audit`/`deployIfNotExists`/`modify`) immediately — this determines every subsequent step and prevents wasted time looking for a remediation task that can't exist for audit-only effects.

**Phase 2 — Identify every assignment in play**
Enumerate assignments at every scope level between the resource and the tenant root — Management Group, Subscription, Resource Group. Remember there is no precedence; document all of them, not just the first one found.

**Phase 3 — Read the effect, not the display name**
Pull `policyRule.then.effect` directly from the definition (and check for an assignment-level effect parameter override) rather than inferring behavior from the definition's title.

**Phase 4 — For blocks: fix the request or create a scoped, time-bound exemption**
Prefer fixing the underlying resource request (correct SKU, add the required tag, use an allowed region) over exemptions wherever the requirement is legitimate. Reserve exemptions for genuine one-off exceptions, and always set `ExpiresOn`.

**Phase 5 — For flags with remediation capability: verify identity RBAC before running the task**
Confirm the managed identity's role scope covers the full assignment scope before triggering `Start-AzPolicyRemediation` — running it against an under-permissioned identity wastes a cycle and produces confusing partial-success output.

**Phase 6 — Force re-evaluation, don't wait on faith**
After any fix — role grant, exemption, resource correction — trigger `Start-AzPolicyComplianceScan` scoped as narrowly as practical (single resource preferred over subscription-wide) to get a fast, accurate confirmation.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide remediation of a newly assigned deployIfNotExists policy</summary>

Scenario: an initiative (e.g. requiring diagnostic settings on all storage accounts) was just assigned across a subscription with hundreds of pre-existing resources, all of which are now NonCompliant because the policy has no retroactive effect.

```powershell
# 1. Confirm the assignment's identity has the roles it needs, at the assignment's own scope
$assignment = Get-AzPolicyAssignment -Name "<assignmentName>"
$defId = $assignment.Properties.PolicyDefinitionId
$roleIds = (Get-AzPolicyDefinition -Id $defId).Properties.PolicyRule.then.details.roleDefinitionIds
foreach ($r in $roleIds) {
    New-AzRoleAssignment -ObjectId $assignment.Identity.PrincipalId `
        -RoleDefinitionId ($r -split '/')[-1] -Scope $assignment.Properties.Scope
}

# 2. Kick off a single remediation task covering the whole assignment scope
Start-AzPolicyRemediation -Name "fleet-remediate-$(Get-Date -Format yyyyMMdd)" `
    -PolicyAssignmentId $assignment.PolicyAssignmentId -ResourceDiscoveryMode ReEvaluateCompliance

# 3. Monitor — large estates can take significant time; poll rather than assume completion
do {
    Start-Sleep -Seconds 60
    $status = Get-AzPolicyRemediation -Name "fleet-remediate-$(Get-Date -Format yyyyMMdd)"
} while ($status.ProvisioningState -eq 'Running')
$status | Select-Object ProvisioningState, DeploymentSummary
```

**Rollback:** individual `deployIfNotExists` companion resources it created can be deleted directly if unwanted; the remediation task record itself has no side effects to undo beyond the resources it deployed.

</details>

<details><summary>Playbook 2 — Emergency exemption for a production-blocking deny during an incident</summary>

Scenario: an urgent hotfix deployment is blocked by a `deny` policy (e.g. a region restriction) and waiting for a full governance review isn't acceptable.

```powershell
# 1. Identify the exact assignment blocking the request (from the ARM error Details array)
# 2. Create a narrowly-scoped, short-expiry exemption — never widen notScopes for an emergency
New-AzPolicyExemption -Name "incident-<ticketNumber>" `
    -PolicyAssignment (Get-AzPolicyAssignment -Id "<policyAssignmentId>") `
    -Scope "<resourceId>" `
    -ExemptionCategory Waiver `
    -ExpiresOn (Get-Date).AddDays(3) `
    -DisplayName "Incident <ticketNumber> — temporary, review before expiry"

# 3. Redeploy the blocked resource
# 4. File a follow-up task to review/formalize or remove the exemption before ExpiresOn
```

**Rollback:** `Remove-AzPolicyExemption -Name "incident-<ticketNumber>" -Scope "<resourceId>"` once the proper fix or a permanent, reviewed exemption is in place.

</details>

<details><summary>Playbook 3 — Onboarding a client's existing Azure estate to a new governance baseline</summary>

Scenario: assigning a new initiative (e.g. a security baseline) across an existing, previously ungoverned subscription — expect a large initial wave of NonCompliant results and plan the rollout to avoid surprise production blocks.

```powershell
# 1. Assign FIRST in audit-only mode using the effect parameter, never deny, to see impact
#    without blocking anything
New-AzPolicyAssignment -Name "baseline-audit-phase" -PolicySetDefinition $initiative `
    -Scope "/subscriptions/<subId>" `
    -PolicyParameterObject @{ effect = @{ value = "Audit" } }

# 2. Let a full evaluation cycle complete (up to 24h), then review the compliance picture
Get-AzPolicyState -SubscriptionId "<subId>" -Filter "ComplianceState eq 'NonCompliant'" |
    Group-Object PolicyDefinitionName | Sort-Object Count -Descending

# 3. Remediate what's remediable (deployIfNotExists/modify) BEFORE flipping to enforce
Start-AzPolicyRemediation -Name "baseline-pre-enforce-remediate" `
    -PolicyAssignmentId $auditAssignment.PolicyAssignmentId -ResourceDiscoveryMode ReEvaluateCompliance

# 4. Only once remediation is complete and audit-only findings are triaged, flip to Deny/enforce
Set-AzPolicyAssignment -Id $auditAssignment.PolicyAssignmentId `
    -PolicyParameterObject @{ effect = @{ value = "Deny" } }
```

**Rollback:** `Remove-AzPolicyAssignment` at any phase to fully back out of the baseline; reverting from Deny back to Audit mid-rollout is a simple parameter update, not a destructive operation.

</details>

<details><summary>Playbook 4 — Migrating off an Azure Blueprint before its retirement</summary>

Blueprints (a separate, older governance product layering ARM templates + Policy + RBAC assignments together) are deprecated: phased retirement begins 31 July 2026, with full retirement (Blueprints can no longer be modified, Blueprint Locks/Deny Assignments removed, definitions and assignments removed from the portal) on 31 Jan 2027. Any definitions, versions, or assignments not exported before that date are permanently deleted and unrecoverable. Microsoft's guidance is migration to **Deployment Stacks** (recommended) or Template Specs (for the ARM template/artifact portion) plus native Policy/Initiative assignments (for the governance portion).

```powershell
# 1. Inventory existing Blueprint assignments before touching anything
Get-AzBlueprintAssignment | Select-Object Name, BlueprintId, Scope, ProvisioningState

# 2. Export the underlying policy/initiative assignments a Blueprint artifact created —
#    these can typically be re-created as direct native assignments at the same scope
Get-AzPolicyAssignment -Scope "<scope>" | Where-Object { $_.Properties.Metadata.assignedBy -like "*Blueprint*" }

# 3. Re-create each as a standalone Policy/Initiative assignment, then remove the Blueprint
#    assignment last, once native assignments are confirmed active and compliant
```

**Rollback:** N/A for the retirement itself (no override available) — but each migration step (creating native assignments) is independently reversible via `Remove-AzPolicyAssignment` before the source Blueprint assignment is deleted.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects an Azure Policy evidence pack for a specific resource or assignment prior to escalation.
#>
param(
    [string]$ResourceId,
    [string]$PolicyAssignmentName
)

$pack = [ordered]@{
    Timestamp        = Get-Date -Format o
    ResourceId       = $ResourceId
    ComplianceStates = @()
    Assignments      = @()
    Exemptions       = @()
    Remediations     = @()
}

if ($ResourceId) {
    $pack.ComplianceStates = Get-AzPolicyState -ResourceId $ResourceId |
        Select-Object PolicyAssignmentName, PolicyDefinitionAction, ComplianceState, Timestamp
    $pack.Assignments = Get-AzPolicyAssignment -Scope $ResourceId |
        Select-Object Name, Scope, NotScopes, EnforcementMode
    $pack.Exemptions = Get-AzPolicyExemption -Scope $ResourceId |
        Select-Object Name, PolicyAssignmentId, ExemptionCategory, ExpiresOn
}

if ($PolicyAssignmentName) {
    $assignment = Get-AzPolicyAssignment -Name $PolicyAssignmentName
    $pack.Remediations = Get-AzPolicyRemediation -PolicyAssignmentId $assignment.PolicyAssignmentId |
        Select-Object Name, ProvisioningState, DeploymentSummary
}

$pack | ConvertTo-Json -Depth 6 | Out-File "PolicyEvidencePack_$(Get-Date -Format yyyyMMdd_HHmmss).json"
Write-Host "Evidence pack written." -ForegroundColor Green
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-AzPolicyState -ResourceId <id>` | Current compliance state and which assignment(s) apply |
| `Get-AzPolicyAssignment -Scope <id>` | Every assignment covering a scope |
| `Get-AzPolicyDefinition -Id <id>` | Full definition including `policyRule.then.effect` |
| `Get-AzPolicySetDefinition -Id <id>` | Initiative definition, including member policy references |
| `Get-AzPolicyExemption -Scope <id>` | Exemptions targeting a scope, including expiry |
| `New-AzPolicyExemption` | Create a scoped, categorized, time-bound exclusion |
| `Remove-AzPolicyExemption` | Remove an exemption (rollback) |
| `Start-AzPolicyRemediation` | Trigger a remediation task for deployIfNotExists/modify |
| `Get-AzPolicyRemediation` | Check remediation task status/summary |
| `Get-AzPolicyRemediationDeployment` | Per-resource detail inside a remediation task |
| `Start-AzPolicyComplianceScan` | Force an on-demand re-evaluation (bypass the 24h cycle) |
| `Get-AzRoleAssignment -ObjectId <identityId>` | Confirm a remediation identity's RBAC coverage |
| `New-AzPolicyAssignment -PolicyParameterObject @{effect=@{value="Audit"}}` | Assign in audit-only mode to gauge impact before enforcing |
| `Get-AzResourceGroupDeployment` (`.Properties.Error`) | Pull the exact policyAssignmentId from a blocked deployment |
| `Get-AzBlueprintAssignment` | Inventory legacy Blueprint assignments ahead of the July 2026 retirement |

---
## 🎓 Learning Pointers

- **There is no policy precedence system — internalize this before troubleshooting anything else.** Every assignment covering a scope is evaluated independently; the most restrictive `deny` anywhere in the stack wins by definition, not by design priority. See [Azure Policy effects](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects).
- **`deployIfNotExists`/`modify` remediation is never retroactive by default.** Resources that existed before an assignment was created stay NonCompliant forever until a Remediation Task is explicitly run against them — plan for this in every new-baseline rollout, don't assume it self-heals overnight. See [Remediate non-compliant resources](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources).
- **Remediation identity RBAC scope mismatches are the top real-world remediation failure.** Always compare the managed identity's actual role-assignment scope against the policy assignment's scope — a narrower grant produces confusing partial success, not a clean failure. See [Details of the policy remediation task structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/remediation-structure).
- **Exemptions and `notScopes` solve different problems — don't reach for the blunt one out of habit.** Exemptions are auditable, scoped, categorized, and can force a future review via `ExpiresOn`; `notScopes` is a silent, permanent structural exclusion better reserved for shared-services carve-outs than one-off tickets. See [Azure Policy exemption structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure).
- **Compliance data has a real latency model, not a "just refresh the page" one.** New assignments take up to ~30 minutes to start producing results; the full backstop cycle is 24 hours. Use `Start-AzPolicyComplianceScan` to force a fresh read when you've just made a fix and need to confirm it, rather than telling a client to wait.
- **Azure Blueprints' retirement timeline has moved — phased retirement starts 31 July 2026, full retirement 31 Jan 2027 — flag any client still using it now.** Anything not exported before final retirement is permanently deleted; migration is to Deployment Stacks (recommended) or Template Specs plus native Policy/Initiative assignments, and it's a project worth scoping ahead of the deadline rather than reacting to it. See [Azure Blueprints retirement](https://learn.microsoft.com/en-us/azure/governance/blueprints/blueprint-retirement).
