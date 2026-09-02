# Security Administrator Role — Identity Response Expansion — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers the **September 2026 Microsoft Entra change announcement** expanding the built-in **Security Administrator** role (`templateId 194ae4cb-b126-40b2-bd5b-6091b380977d`) to include direct identity-response actions — disabling and enabling user accounts, revoking active sign-in sessions, and forcing password resets — against **non-privileged users**. Per Microsoft's own announcement, rollout completes by the end of September 2026, is applied per-tenant with no admin-facing toggle, and is framed as helping "organizations streamline role assignments while maintaining least-privilege access and existing governance and auditing controls."

Assumes:
- A hybrid or cloud-only Entra ID tenant with the Security Administrator built-in role in active use (assigned to at least one principal, standing or PIM-eligible).
- Reader has `RoleManagement.Read.Directory` and `AuditLog.Read.All` Graph scopes at minimum for diagnosis; role-assignment remediation requires `RoleManagement.ReadWrite.Directory` or equivalent (Privileged Role Administrator/Global Administrator).

Out of scope:
- The parallel, separately-announced extension of **Security Operator** identity-containment actions through the **Microsoft Defender portal's unified RBAC** for SOC analysts — a related but architecturally distinct change (different portal, different role, different RBAC surface — Defender unified RBAC, not Entra directory-role RBAC). If a ticket concerns Defender portal containment actions specifically, this is the wrong file.
- General Security Administrator day-2 usage that predates this change (managing Conditional Access, Identity Protection, security configuration) — this runbook is scoped to the **new** identity-response actions and their governance implications, not the role's full existing permission surface.
- PIM activation mechanics in general — see `Troubleshooting/PIM-B.md`/`-A.md` for the base PIM activation/approval workflow; this runbook only covers PIM as it applies to gating the newly-added actions.

---
## How It Works

Microsoft Entra built-in roles are defined as a `roleDefinition` object with an `allowedResourceActions` list under `rolePermissions`. Unlike custom roles, **built-in role definitions are Microsoft-managed** — their action lists can change as part of a platform update, without any tenant-side configuration change, and without the role's `templateId` or `displayName` changing. This is precisely the mechanism behind the September 2026 change: Security Administrator's `allowedResourceActions` gains (per Microsoft's announcement, describing the change in functional rather than literal-API terms) the capability to:

- Disable a non-privileged user's account
- Enable a (previously disabled) non-privileged user's account
- Revoke a non-privileged user's active sign-in sessions
- Force a password reset for a non-privileged user

Structurally, this mirrors action names already present on other built-in roles that perform the identical operations — `microsoft.directory/users/disable`, `microsoft.directory/users/enable`, `microsoft.directory/users/invalidateAllRefreshTokens`, and `microsoft.directory/users/password/update` are the exact action strings already used by Authentication Administrator and User Administrator for the same functional capabilities. **Microsoft's own announcement does not publish the literal appended action-string list for Security Administrator specifically** — this runbook's scripts treat those four strings as the working hypothesis (consistent with Microsoft's established naming convention elsewhere in the same permission model) and verify them live against each tenant's actual role definition rather than assuming they're present. Confirm against your own tenant before relying on this for compliance documentation.

Two independent gates then determine whether a given Security Administrator holder can actually exercise the new power against a given target:

**Gate 1 — Assignment state.** A principal must hold an **Active** assignment, or an **Eligible** (PIM) assignment that has been **activated**, for the new actions to apply. Eligible-but-inactive grants nothing.

**Gate 2 — Target protection ("who can perform sensitive actions").** Microsoft Entra maintains a protection model, documented centrally at the `privileged-roles-permissions` reference, that restricts which roles may act against principals who themselves hold privileged/protected roles. Microsoft's announcement explicitly scopes the new Security Administrator actions to **non-privileged users** — meaning a target who holds any directory role, and especially a privileged one (Global Administrator, Privileged Role Administrator, another protected role), remains shielded from a plain Security Administrator exactly as before this change. This is the same protection model that already prevents (for example) a Helpdesk Administrator from resetting a Global Administrator's password.

The net effect: this is best understood not as "Security Administrator becomes more powerful in the abstract" but as "Security Administrator gains the specific containment toolkit that Authentication Administrator, User Administrator, Helpdesk Administrator, and Password Administrator already had, for the same non-privileged-user population." The operational risk is not new privilege escalation against protected accounts — it's **redundant, under-reviewed access** for anyone who already holds Security Administrator for its read/reporting purpose and now silently also holds meaningful write power over ordinary user accounts.

---
## Dependency Stack

```
Microsoft Entra ID (tenant)
  └── Built-in role definitions (Microsoft-managed, NOT tenant-editable)
        └── Security Administrator (templateId 194ae4cb-b126-40b2-bd5b-6091b380977d)
              ├── Pre-existing action surface: read security info/reports,
              │     manage security configuration in Entra ID + Office 365
              └── Sept 2026 addition (per-tenant gradual rollout, no opt-out):
                    users/disable, users/enable,
                    users/invalidateAllRefreshTokens, users/password/update
                    (scoped to non-privileged targets only)
                    └── Role assignment mechanism
                          ├── Active assignment → immediate effect
                          └── PIM Eligible assignment → requires activation
                                (Entra ID P2 / Governance license required
                                 for PIM itself — see Troubleshooting/PIM-B.md)
                    └── Sensitive-actions protection model
                          (privileged-roles-permissions doc)
                          gates action success against protected targets
              └── Overlapping roles with pre-existing identical actions:
                    Authentication Administrator (broadest overlap —
                      same four action verbs, non-admin-scoped)
                    User Administrator (broader account management,
                      pre-dates this change)
                    Helpdesk Administrator / Password Administrator
                      (password reset only, narrower scope)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| A Security Administrator disabled/reset a user and nobody recalls granting that permission | Sept 2026 role expansion has reached this tenant; this is expected, documented behavior, not a compromise or misconfiguration | Query live role definition for the four candidate actions (Validation Step 2) |
| Security Administrator tries to disable a user and it fails | Target holds a privileged/protected role (sensitive-actions protection) | Check target's directory role memberships (Validation Step 3) |
| Two different admin roles both show as `InitiatedBy` for identical-looking actions across different incidents | Overlapping role assignment — same person holds Security Administrator AND Authentication/User Administrator | Cross-reference role membership lists (Command Cheat Sheet) |
| Query for the four candidate actions returns `False` for all of them in a tenant checked in early September 2026 | Rollout hasn't reached this tenant yet — gradual, not simultaneous | Re-check periodically through end of September 2026; not a query bug |
| A custom role built to replicate "old" Security Administrator is missing an action the built-in role has | Custom roles only support a subset of built-in-role permissions | Confirm each required action's custom-role eligibility individually before relying on the custom role |
| Ticket describes SOC analysts taking containment actions from the Defender portal | Wrong topic — this is the separate Security Operator/Defender-unified-RBAC extension, not this Entra-native Security Administrator change | Confirm which portal/role the ticket actually concerns before proceeding |

---
## Validation Steps

**1. Confirm current role membership (active + eligible)**
```powershell
Connect-MgGraph -Scopes "RoleManagement.Read.Directory" -NoWelcome
$roleId = (Get-MgDirectoryRole -Filter "displayName eq 'Security Administrator'").Id
Get-MgDirectoryRoleMember -DirectoryRoleId $roleId |
    Select-Object Id, @{N='Name';E={$_.AdditionalProperties.displayName}}
```
Good: a short, deliberate list matching a documented security-operations team. Bad: a long, undocumented list including service accounts, third-party vendors, or anyone whose job is unrelated to identity operations.

**2. Confirm the live role definition in this tenant**
```powershell
$roleDef = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/194ae4cb-b126-40b2-bd5b-6091b380977d"
$roleDef.rolePermissions.allowedResourceActions | Where-Object { $_ -match "users/(disable|enable|invalidateAllRefreshTokens|password)" }
```
Good: returns the four candidate actions once rollout has reached the tenant (treat as informational, not something to "fix"). Bad interpretation: assuming an empty result means the query is broken — it more likely means rollout hasn't landed yet for this tenant as of the check date.

**3. Confirm target-user protection status before assuming an action will or won't succeed**
```powershell
Get-MgUserMemberOf -UserId "<targetUserId>" |
    Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.directoryRole' } |
    Select-Object @{N='Role';E={$_.AdditionalProperties.displayName}}
```
Good: empty result for an ordinary end user (fully in scope for the new actions). Bad/expected-to-fail: any role membership, especially a privileged one — Security Administrator alone cannot act on this target regardless of rollout status.

**4. Confirm no PIM activation gap is masking apparent "no access" reports**
```powershell
Get-MgRoleManagementDirectoryRoleAssignmentSchedule -Filter "roleDefinitionId eq '194ae4cb-b126-40b2-bd5b-6091b380977d'" |
    Select-Object PrincipalId, AssignmentType, Status
```
Good: `AssignmentType = Activated` for anyone who reports having successfully used the new actions. Bad: `AssignmentType = Assigned` (i.e., merely eligible, never activated) for someone who claims the action "isn't working" — the fix is activating PIM, not troubleshooting the role definition.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the change is actually in play**
Rule out the two most common false alarms before investigating anything else: (a) rollout hasn't reached this tenant yet (Validation Step 2), and (b) the actor holds a different, pre-existing role (Authentication/User/Helpdesk/Password Administrator) that already explains the observed behavior independent of this change (Command Cheat Sheet overlap query).

**Phase 2 — Confirm assignment and activation state**
Distinguish Active from Eligible-not-yet-activated (Validation Step 4). A large share of "this isn't working" reports for any PIM-gated role trace back to this gap, not to the underlying permission model.

**Phase 3 — Confirm target protection status**
For any report of an action failing against a specific user, check whether that user is privileged (Validation Step 3) before treating it as a bug. This is expected, by-design protection, not a defect.

**Phase 4 — Assess blast-radius / governance exposure**
Independent of any specific incident, run the full assignee-overlap sweep (Evidence Pack script) as a proactive hygiene pass — this is the change's real operational impact: quietly expanding the reach of every existing Security Administrator assignment, active or eligible, the moment rollout lands, with zero tenant-side action required or even visible unless someone goes looking.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Pre-Rollout Access Review (run before end of September 2026 if not already done)</summary>

1. Enumerate every Active and Eligible Security Administrator assignee (Validation Step 1 + PIM eligibility query).
2. For each, confirm the assignment still matches a documented business need for the role's **pre-expansion** purpose (security reporting/configuration).
3. For anyone whose need is read-only, downgrade to **Security Reader** (no write actions of any kind, unaffected by this change) — see `SecurityAdminRoleExpansion-B.md` Fix 1.
4. For anyone whose need is legitimate but infrequent, convert standing Active assignments to **PIM-eligible** — see Fix 2 in the Mode B runbook. This is the single highest-leverage step: it doesn't remove the new capability, but it gates it behind activation (and, if policy requires, approval and MFA) rather than leaving it always-on.
5. Document the review (who was reviewed, what changed, when) — this is exactly the kind of access-hygiene evidence an auditor or cyber-insurance questionnaire will ask for after a platform-driven privilege expansion like this one.

**Rollback:** N/A — this is a review process, not a technical change with a single rollback point. Individual downgrades/PIM conversions each have their own rollback (see Mode B fixes).

</details>

<details><summary>Playbook 2 — Post-Rollout Blast-Radius Reduction</summary>

If the review in Playbook 1 wasn't completed before rollout reached the tenant, run the same steps reactively, plus:

1. Pull the audit log for the four candidate actions filtered to `InitiatedBy` principals holding Security Administrator, since the earliest date the role definition query (Validation Step 2) started returning `True` for this tenant.
2. Review every hit for legitimacy — was this a security-team-initiated containment action, or does it look like scope creep / accidental use by someone who didn't realize they now had this power?
3. Apply Playbook 1's downgrade/PIM-conversion steps going forward.
4. If any hit looks illegitimate or unexplained, treat it as a standard identity-incident investigation (see `IdentityProtection-B.md`) — the new action surface doesn't change incident-response procedure once misuse is suspected, only the set of roles capable of triggering it.

**Rollback:** N/A — investigative process.

</details>

<details><summary>Playbook 3 — Building a Narrower Custom Role for a "Read-Only Security Admin" Persona</summary>

1. Pull 90 days of audit-log activity for current Security Administrator holders to establish the actual action set in use (see Command Cheat Sheet).
2. For each distinct action observed, confirm it is available for use in a custom role — **do not assume parity with the built-in role**; Microsoft explicitly documents that only a subset of built-in permissions are currently custom-role-eligible.
3. Build the custom role with exactly that confirmed action set (`New-MgRoleManagementDirectoryRoleDefinition`), explicitly excluding the four Sept 2026 identity-response actions.
4. Reassign affected principals from Security Administrator to the new custom role; remove the old assignment only after confirming no legitimate, still-needed action was dropped.
5. Re-run the audit-log review after 30 days to confirm nothing broke.

**Rollback:** Reassign affected principals back to the built-in Security Administrator role; delete the custom role definition if unused.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Security Administrator role-expansion posture for escalation or audit review.
#>
Connect-MgGraph -Scopes "RoleManagement.Read.Directory","AuditLog.Read.All" -NoWelcome

$roleId = (Get-MgDirectoryRole -Filter "displayName eq 'Security Administrator'").Id
$active = if ($roleId) { Get-MgDirectoryRoleMember -DirectoryRoleId $roleId } else { @() }
$eligible = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "roleDefinitionId eq '194ae4cb-b126-40b2-bd5b-6091b380977d'"

$roleDef = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/194ae4cb-b126-40b2-bd5b-6091b380977d"
$candidateActions = @(
    "microsoft.directory/users/disable",
    "microsoft.directory/users/enable",
    "microsoft.directory/users/invalidateAllRefreshTokens",
    "microsoft.directory/users/password/update"
)
$rolloutStatus = $candidateActions | ForEach-Object {
    [pscustomobject]@{ Action = $_; PresentInThisTenant = ($roleDef.rolePermissions.allowedResourceActions -contains $_) }
}

$recentActions = Get-MgAuditLogDirectoryAudit -Filter "activityDisplayName eq 'Disable account' or activityDisplayName eq 'Reset user password' or activityDisplayName eq 'Update user'" -Top 100

[pscustomobject]@{
    TenantId               = (Get-MgContext).TenantId
    ActiveAssigneeCount    = $active.Count
    EligibleAssigneeCount  = $eligible.Count
    RolloutStatus          = $rolloutStatus
    RecentCandidateActions = $recentActions.Count
} | ConvertTo-Json -Depth 6
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-MgDirectoryRole -Filter "displayName eq 'Security Administrator'"` | Get the role object ID (only exists once someone has ever been assigned) |
| `Get-MgDirectoryRoleMember -DirectoryRoleId $roleId` | List current Active assignees |
| `Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "roleDefinitionId eq '194ae4cb-...'"` | List PIM-eligible assignees |
| `Get-MgRoleManagementDirectoryRoleAssignmentSchedule -Filter "roleDefinitionId eq '194ae4cb-...'"` | Distinguish Active vs. Activated-from-eligible assignments |
| `Invoke-MgGraphRequest -Method GET -Uri ".../roleDefinitions/194ae4cb-..."` | Read the live, current `allowedResourceActions` for this tenant |
| `Get-MgUserMemberOf -UserId <id>` (filtered to `directoryRole`) | Check whether a target user is privileged/protected |
| `Get-MgAuditLogDirectoryAudit -Filter "activityDisplayName eq '...'"` | Pull recent disable/enable/reset/session-revoke events |
| `New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest` | Convert a standing assignment to PIM-eligible |
| `New-MgRoleManagementDirectoryRoleDefinition` | Build a narrower custom role |
| `Remove-MgDirectoryRoleMemberByRef` / `New-MgDirectoryRoleMemberByRef` | Remove/add a role assignment |

---
## 🎓 Learning Pointers

- **Built-in role permission sets are Microsoft-managed and can change without any tenant-side action.** This is the core mechanic behind the entire topic — treat "what does Security Administrator do" as something to query live (`roleDefinitions`), not something to memorize once and trust indefinitely. Reference: [Microsoft Entra built-in roles](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference)
- **"Non-privileged users" is the load-bearing scope limiter.** Sensitive-actions protection continues to shield privileged/protected role holders from this expanded action set exactly as it did before — don't let an alarmed stakeholder assume this means Security Administrator can now touch a Global Administrator account. Reference: [Who can perform sensitive actions](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/privileged-roles-permissions#who-can-perform-sensitive-actions)
- **The real operational risk is redundant, unreviewed access, not privilege escalation.** Anyone holding Security Administrator alongside Authentication/User/Helpdesk/Password Administrator now has the same containment power through two independent role paths — this is worth folding into the next scheduled access review rather than treating as an emergency.
- **PIM conversion is the highest-leverage single mitigation available**, and it's the same lever every prior role-expansion topic in this repo (memberOf retirement, Custom Controls retirement) has pointed back to: gate a newly-powerful standing assignment behind activation rather than removing access outright.
- **Custom roles are not a guaranteed 1:1 narrowing path.** Confirm action-by-action custom-role eligibility before promising a stakeholder "the old Security Administrator, minus the new powers." Reference: [Create a custom role in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/custom-create)
- **Don't conflate this with the parallel Security Operator/Defender-unified-RBAC SOC extension.** Different portal (Microsoft Defender, not Entra admin center), different role (Security Operator, not Security Administrator), different RBAC surface entirely — worth a second look as its own topic once more MSP-facing operational detail is documented, but out of scope here.
