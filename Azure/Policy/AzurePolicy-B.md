# Azure Policy — Hotfix Runbook (Mode B: Ops)
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

Run these from an admin workstation with the `Az.PolicyInsights` / `Az.Resources` modules.

```powershell
# 1. Was this a deployment BLOCK (deny/denyAction) or a compliance FLAG (audit) that's confusing someone?
#    A blocked deployment fails immediately with a 403 at request time — a flagged resource deploys fine
#    and shows up as NonCompliant later. These are two completely different tickets.
Get-AzPolicyState -ResourceId "<resourceId>" | Select-Object PolicyAssignmentName, PolicyDefinitionAction, ComplianceState

# 2. If blocked: which specific assignment/definition denied it? (deployment error rarely names it clearly)
#    Pull the full ARM deployment error — the policyAssignmentId is buried in the error Details array.
Get-AzLog -ResourceId "<resourceId>" -DetailedOutput -MaxRecord 5 |
    Where-Object { $_.OperationName.Value -like "*Policy*" }

# 3. What scope is the offending assignment actually applied at? (sub, MG, RG — not always where you'd guess)
Get-AzPolicyAssignment -Name "<assignmentName>" | Select-Object Name, Scope, NotScopes

# 4. If flagged NonCompliant: is this a deployIfNotExists/modify policy that CAN self-heal, or audit-only?
(Get-AzPolicyDefinition -Name "<policyDefinitionName>").Properties.PolicyRule.then.effect

# 5. Is there an active exemption that should be covering this resource but isn't?
Get-AzPolicyExemption -Scope "<resourceId>" | Select-Object Name, ExemptionCategory, ExpiresOn, PolicyAssignmentId
```

**Interpretation:**

| Finding | Action |
|---|---|
| Error contains `RequestDisallowedByPolicy` | Fix 1 — a `deny`/`denyAction` effect blocked the request; identify the assignment before requesting an exemption |
| `ComplianceState = NonCompliant`, effect = `audit`/`auditIfNotExists` | Fix 2 — informational only, no auto-remediation exists for this effect; the resource is not broken |
| `ComplianceState = NonCompliant`, effect = `deployIfNotExists`/`modify` | Fix 3 — this CAN self-heal but only via a remediation task, which does not run automatically for pre-existing resources |
| `ComplianceState = Protected` (denyAction) | Fix 1 variant — resource is covered by a delete-blocking policy; this is by design, not a bug |
| Remediation task exists but `Status = Failed` | Fix 4 — almost always the managed identity's RBAC role is missing or scoped too narrowly |
| Exemption exists but resource still shows NonCompliant | Fix 5 — check `ExpiresOn` first (silently lapsed exemptions are the #1 cause), then confirm the exemption's scope actually covers this resource |
| Compliance state hasn't updated after a fix was applied | Fix 6 — standard evaluation cycle is every 24h; trigger an on-demand scan instead of waiting |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Policy Definition (the rule — built-in or custom, JSON policy rule with an `effect`)
    │
    └── Policy (or Initiative/PolicySet) Assignment — binds the definition to a SCOPE
            │
            ├── Scope: Management Group / Subscription / Resource Group / individual resource
            │       (assignment scope, not resource location, determines what's evaluated —
            │        an assignment at a parent MG cascades to every child sub/RG below it)
            │
            ├── notScopes — blunt exclusion list (whole sub-trees excluded, all-or-nothing)
            │
            ├── Exemptions (Microsoft.Authorization/policyExemptions) — first-class object,
            │       per-resource or per-scope, with a category (Waiver/Mitigated) and an
            │       OPTIONAL expiration date — the #1 real-world gap is an exemption with
            │       no expiration that nobody remembers exists, or one that silently expired
            │
            ▼
    Effect evaluated (mutually independent per assignment — NOT layered/prioritized like GPO):
            │
            ├── deny / denyAction  → blocks the REQUEST itself, 403 RequestDisallowedByPolicy,
            │                         never appears as "NonCompliant" because it never got created
            │                         (denyAction specifically blocks DELETE only)
            │
            ├── audit / auditIfNotExists → allows the request, flags NonCompliant afterward,
            │                         ZERO auto-remediation capability — informational only
            │
            └── deployIfNotExists / modify → allows the request, flags NonCompliant, AND CAN
                                        self-heal — but ONLY when a Remediation Task runs
                                        │
                                        └── Remediation Task requires a Managed Identity
                                                │
                                                └── Identity needs the exact RBAC role(s) named
                                                    in the policy definition's roleDefinitionIds,
                                                    granted AT OR ABOVE the assignment scope
                                                    (a narrower grant = remediation fails silently
                                                    for resources outside that narrower scope)
    │
    ▼
Compliance state visible in Get-AzPolicyState / portal
    (updated on: resource create/update, new assignment, definition change, OR the
     standard 24-hour evaluation cycle — NOT instantly on every change)
```

**Critical mental-model correction:** unlike GPO precedence or NSG rule priority, Azure Policy assignments do **not** have an ordering/priority system that resolves conflicts. Every assignment covering a scope evaluates independently. If ANY assignment's effect is `deny`, the request is blocked — a more specific/narrower-scope assignment with `audit` does not "win" over a broader `deny`. There is no single place to look for "the policy that's in charge here"; you must check every assignment covering that scope.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm block vs. flag before doing anything else**
```powershell
Get-AzPolicyState -ResourceId "<resourceId>"
```
If the resource doesn't exist at all and the user says "my deployment failed," this is a `deny`/`denyAction` block — go to Fix 1. If the resource exists and shows `ComplianceState = NonCompliant`, it's a post-deployment flag — go to Fix 2 or Fix 3 depending on effect.

**Step 2 — For a blocked deployment, identify the exact assignment from the error, not guesswork**
```powershell
# ARM deployment errors carry the policy details in a nested Details array — pull it, don't paraphrase it
$deployment = Get-AzResourceGroupDeployment -ResourceGroupName "<rg>" -Name "<deploymentName>"
$deployment.Properties.Error | ConvertTo-Json -Depth 10
```
Expected: a `policyAssignmentId`, `policyDefinitionId`, and (if an initiative) `policySetDefinitionId` in the error payload. Never assume which policy fired based on the definition's display name alone — display names are not unique across a tenant.

**Step 3 — Confirm the assignment's actual scope, not the scope you assumed**
```powershell
Get-AzPolicyAssignment -Id "<policyAssignmentId>" | Select-Object Name, Scope, NotScopes, EnforcementMode
```
`EnforcementMode = DoNotEnforce` means the assignment is in "what-if" mode and should NOT be blocking anything — if a deny is firing anyway, you're looking at the wrong assignment.

**Step 4 — For NonCompliant resources, check the effect before promising remediation**
```powershell
$defId = (Get-AzPolicyAssignment -Name "<assignmentName>").Properties.PolicyDefinitionId
(Get-AzPolicyDefinition -Id $defId).Properties.PolicyRule.then.effect
```
`audit`/`auditIfNotExists` = there is no button to press, this is a reporting-only signal that requires a manual fix to the resource itself. `deployIfNotExists`/`modify` = a remediation task can fix it.

**Step 5 — For a failed or stuck remediation task, check the managed identity's role first**
```powershell
Get-AzPolicyRemediation -Name "<remediationName>" | Select-Object ProvisioningState, DeploymentSummary
$assignment = Get-AzPolicyAssignment -Name "<assignmentName>"
Get-AzRoleAssignment -ObjectId $assignment.Identity.PrincipalId
```
Expected: the identity holds every role listed in the policy definition's `roleDefinitionIds`, at a scope that covers ALL non-compliant resources — not just the ones in the RG where the assignment happened to be created.

**Step 6 — Trust the state, don't wait blindly**
```powershell
Start-AzPolicyComplianceScan -ResourceGroupName "<rg>"
# or narrower/faster:
Start-AzPolicyComplianceScan -ResourceId "<resourceId>"
```
Compliance data is not real-time. After any fix (role grant, resource change, new exemption), trigger an on-demand scan rather than telling the user to "wait and check tomorrow."

---
## Common Fix Paths

<details><summary>Fix 1 — Deployment blocked by deny / denyAction</summary>

```powershell
# Confirm the assignment and read its parameters — many built-ins support an effect PARAMETER
# that can be overridden to Audit/Disabled at assignment scope without touching the definition
Get-AzPolicyAssignment -Id "<policyAssignmentId>" | Select-Object -ExpandProperty Parameter

# Option A — the requirement is legitimate: fix the request itself (e.g. add the required tag,
# use an allowed SKU/region) and redeploy. This is the correct fix in most tickets.

# Option B — a genuine one-off exception is needed: create a scoped, TIME-BOUND exemption
# rather than disabling the policy or excluding a whole subscription via notScopes
New-AzPolicyExemption -Name "<exemptionName>" -PolicyAssignment $assignment `
    -Scope "<resourceId>" -ExemptionCategory Waiver `
    -ExpiresOn (Get-Date).AddDays(30) `
    -DisplayName "Temporary exemption — <ticket/reason>"
```

**Rollback:** `Remove-AzPolicyExemption -Name "<exemptionName>" -Scope "<resourceId>"`. Never widen `notScopes` to work around a single ticket — that silently exempts everything under that scope forever, with no expiration and no audit trail explaining why.

</details>

<details><summary>Fix 2 — NonCompliant flag on an audit-only policy (no auto-fix exists)</summary>

```powershell
# Confirm there genuinely is no remediation path before telling the client "it'll self-heal"
(Get-AzPolicyDefinition -Id $defId).Properties.PolicyRule.then.effect
# If this returns audit / auditIfNotExists / deny / denyAction / disabled / manual —
# STOP. Remediation tasks do not exist for these effects. The only fix is manual:
#   1. Manually correct the non-compliant resource property directly, OR
#   2. Accept the finding with a documented exemption if it's an approved exception
```

**Rollback:** N/A — no automated change was made. Document the manual fix or exemption decision for the compliance record.

</details>

<details><summary>Fix 3 — NonCompliant on a deployIfNotExists/modify policy — trigger remediation</summary>

```powershell
# Existing (pre-dating the assignment) non-compliant resources are NEVER auto-fixed —
# a remediation task must be explicitly created, this is not automatic
Start-AzPolicyRemediation -Name "remediate-$(Get-Date -Format yyyyMMdd)" `
    -PolicyAssignmentId "<policyAssignmentId>" `
    -ResourceDiscoveryMode ReEvaluateCompliance

# Watch progress
Get-AzPolicyRemediation -Name "remediate-$(Get-Date -Format yyyyMMdd)" |
    Select-Object ProvisioningState, DeploymentSummary
```

**Rollback:** deployIfNotExists remediation typically deploys a companion resource (e.g. a diagnostic setting) — remove that resource directly if the remediation was unwanted. `modify` effect changes (e.g. adding a tag) can be reverted by editing the property back manually; the remediation task itself has no built-in undo.

</details>

<details><summary>Fix 4 — Remediation task fails — managed identity RBAC gap</summary>

```powershell
# The single most common remediation failure: the identity's role assignment scope is
# NARROWER than the assignment scope, so it can fix resources in one RG but not the others
# the policy assignment actually covers.
$assignment = Get-AzPolicyAssignment -Name "<assignmentName>"
$roleDefIds = (Get-AzPolicyDefinition -Id $assignment.Properties.PolicyDefinitionId).Properties.PolicyRule.then.details.roleDefinitionIds

foreach ($roleId in $roleDefIds) {
    New-AzRoleAssignment -ObjectId $assignment.Identity.PrincipalId `
        -RoleDefinitionId ($roleId -split '/')[-1] `
        -Scope $assignment.Properties.Scope    # grant at the ASSIGNMENT scope, not a narrower RG
}

# Re-run remediation after the role grant propagates
Start-AzPolicyRemediation -Name "remediate-retry-$(Get-Date -Format yyyyMMdd)" `
    -PolicyAssignmentId $assignment.PolicyAssignmentId -ResourceDiscoveryMode ReEvaluateCompliance
```

**Rollback:** `Remove-AzRoleAssignment` to revoke the grant if it was created in error. If the assignment used a system-assigned identity and the assignment itself is deleted, the identity and its role assignments are cleaned up automatically — but any resources it already remediated are NOT rolled back.

</details>

<details><summary>Fix 5 — Exemption not covering the resource / silently expired</summary>

```powershell
# Check expiration first — this is the #1 real cause of "the exemption stopped working"
Get-AzPolicyExemption -Scope "<resourceId>" |
    Select-Object Name, ExemptionCategory, ExpiresOn, PolicyAssignmentId,
        @{N='DaysUntilExpiry';E={($_.ExpiresOn - (Get-Date)).Days}}

# If expired or missing, recreate with a longer/renewed window and a clear reason,
# never with an open-ended (no ExpiresOn) exemption unless it's a deliberate permanent waiver
New-AzPolicyExemption -Name "<exemptionName>" -PolicyAssignment $assignment `
    -Scope "<resourceId>" -ExemptionCategory Mitigated `
    -ExpiresOn (Get-Date).AddDays(90)
```

**Rollback:** `Remove-AzPolicyExemption`. Set a calendar reminder before the new `ExpiresOn` date — exemptions do not send an expiry warning of their own.

</details>

<details><summary>Fix 6 — Compliance state stale after a real fix was applied</summary>

```powershell
# Don't tell the client to "wait 24 hours" if the fix is already confirmed in place —
# trigger an on-demand scan instead
Start-AzPolicyComplianceScan -ResourceId "<resourceId>"

# For a whole RG/subscription after a bulk fix or new exemption rollout:
Start-AzPolicyComplianceScan -ResourceGroupName "<rg>"
```

**Rollback:** N/A — read-only evaluation trigger, no state is changed.

</details>

---
## Escalation Evidence

```
=== Azure Policy Escalation Pack ===
Date/Time:                     _______________
Resource ID:                   _______________
Subscription:                  _______________

Symptom type:                  Deployment BLOCKED (deny/denyAction) / NonCompliant FLAG
Exact error (if blocked):      _______________
PolicyAssignmentId:            _______________
PolicyDefinitionId:            _______________
PolicySetDefinitionId:         _______________ (if initiative)
Assignment scope:               _______________
EnforcementMode:               Default / DoNotEnforce

Policy effect:                 deny / denyAction / audit / auditIfNotExists / deployIfNotExists / modify
Remediation task attempted:    Yes / No — Name: _______________ — ProvisioningState: _______________
Managed identity role check:   Roles present: _______________ — Scope granted: _______________

Exemption present:             Yes / No — ExpiresOn: _______________ — Category: _______________

Actions taken so far:
1.
2.
3.

Escalation contact: Microsoft Support via Azure Portal > Policy > Support + troubleshooting > New Support Request
Reference: https://learn.microsoft.com/en-us/azure/governance/policy/troubleshoot/general
```

---
## 🎓 Learning Pointers

- **Policy assignments don't have a precedence order — every `deny` blocks, regardless of scope specificity.** Coming from GPO or NSG backgrounds, it's natural to look for "the one policy that wins." Azure Policy doesn't work that way: every assignment covering a scope evaluates independently, and any single `deny`/`denyAction` match blocks the request. See [Azure Policy effects](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects).
- **`audit` and `deployIfNotExists` look similar in the portal (both show NonCompliant) but have completely different remediation stories.** `audit`/`auditIfNotExists` have zero self-heal capability — the fix is always manual. Only `deployIfNotExists` and `modify` support remediation tasks. Check the effect before promising a client "it'll fix itself."
- **Remediation tasks never run automatically for pre-existing resources.** A `deployIfNotExists` policy only auto-applies to resources created or updated *after* the assignment exists. Every resource that predates the assignment needs an explicit remediation task — this is the most common "why didn't it just fix itself" ticket. See [Remediate non-compliant resources](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources).
- **The remediation managed identity's RBAC scope is a frequent silent gap.** If the identity's role is granted at a narrower resource group than the policy assignment's actual scope, remediation quietly succeeds for some resources and fails for others with no obvious pattern until you compare scopes side by side.
- **Exemptions expire, `notScopes` doesn't — pick the narrower tool.** An exemption (`Microsoft.Authorization/policyExemptions`) is scoped, categorized (Waiver/Mitigated), and can carry an expiration date that forces a future review. `notScopes` on an assignment is a permanent, audit-trail-free exclusion of an entire scope subtree — reserve it for structural exclusions (e.g. a shared services RG that should never be in scope), not one-off tickets. See [Azure Policy exemption structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure).
- **Compliance data is not real-time — the standard cycle is every 24 hours.** New assignments start evaluating within ~30 minutes; new/updated resources under an existing assignment show up in ~15 minutes; everything else waits for the daily cycle unless you trigger `Start-AzPolicyComplianceScan` explicitly. See [Get policy compliance data](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/get-compliance-data).
