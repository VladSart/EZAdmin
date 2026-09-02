# Security Administrator Role — Identity Response Expansion — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## ⚠ A note before you start — nobody changed a setting, Microsoft changed the role

Starting with the September 2026 "What's New in Microsoft Entra" change announcement, Microsoft is expanding the built-in **Security Administrator** role to include direct identity-response actions against non-privileged (non-admin) users: **disabling and enabling user accounts, revoking active sign-in sessions, and forcing password resets.** Rollout completes by **end of September 2026**, tenant by tenant, with **no admin toggle, opt-in, or opt-out** — it is a platform-side update to the role's permission set. If a ticket says "a Security Administrator was able to disable/reset a user and nobody remembers granting that," this is very likely why — check Triage before assuming a misconfiguration or compromise. If the ticket is instead about SOC analysts taking containment actions from the **Microsoft Defender portal** specifically, that is a related but separate Defender-unified-RBAC extension to the **Security Operator** role, not this one — verify which portal/role the ticket actually concerns before applying fixes here.

---
## Triage

```powershell
# 1. Connect with the scopes needed for every check below
Connect-MgGraph -Scopes "RoleManagement.Read.Directory","AuditLog.Read.All" -NoWelcome
(Get-MgContext).TenantId

# 2. List everyone who currently holds Security Administrator — ACTIVE assignments
$roleId = (Get-MgDirectoryRole -Filter "displayName eq 'Security Administrator'").Id
if (-not $roleId) {
    # Role hasn't been activated in this tenant yet (no one has ever held it) — check the template instead
    $roleId = (Get-MgDirectoryRoleTemplate | Where-Object DisplayName -eq "Security Administrator").Id
    Write-Host "Security Administrator has never been activated in this tenant (no active assignments possible yet)." -ForegroundColor Yellow
} else {
    Get-MgDirectoryRoleMember -DirectoryRoleId $roleId |
        Select-Object Id, @{N='Type';E={$_.AdditionalProperties.'@odata.type' -replace '#microsoft.graph.',''}}, @{N='Name';E={$_.AdditionalProperties.displayName}}
}

# 3. List everyone ELIGIBLE for Security Administrator via PIM (they gain the same new actions once activated)
Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "roleDefinitionId eq '194ae4cb-b126-40b2-bd5b-6091b380977d'" |
    Select-Object PrincipalId, Status, @{N='Ends';E={$_.ScheduleInfo.Expiration.EndDateTime}}

# 4. Check whether the identity-response actions have actually landed in THIS tenant's role definition yet
#    (rollout is gradual through end of Sept 2026 — not every tenant sees it the same day)
$roleDef = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/194ae4cb-b126-40b2-bd5b-6091b380977d"
$candidateActions = @(
    "microsoft.directory/users/disable",
    "microsoft.directory/users/enable",
    "microsoft.directory/users/invalidateAllRefreshTokens",
    "microsoft.directory/users/password/update"
)
$allowed = $roleDef.rolePermissions.allowedResourceActions
$candidateActions | ForEach-Object {
    [pscustomobject]@{ Action = $_; PresentInThisTenant = ($allowed -contains $_) }
}

# 5. Cross-check assignees against roles that ALREADY had these actions before this change
#    (overlap here is a role-hygiene signal, not a bug)
foreach ($overlapRole in @("Authentication Administrator","User Administrator","Helpdesk Administrator","Password Administrator")) {
    $rid = (Get-MgDirectoryRole -Filter "displayName eq '$overlapRole'").Id
    if ($rid) {
        Write-Host "`n-- $overlapRole members --" -ForegroundColor Cyan
        Get-MgDirectoryRoleMember -DirectoryRoleId $rid | Select-Object Id, @{N='Name';E={$_.AdditionalProperties.displayName}}
    }
}
```

| Result | Action |
|--------|--------|
| Security Administrator is broadly assigned (SOC vendor, monitoring team, auditors) beyond a tight security-ops group | → [Fix 1 — Reduce Over-Assignment](#fix-1--reduce-over-assignment) |
| Standing (permanent Active, non-PIM) Security Administrator assignments exist | → [Fix 2 — Convert Standing Assignments to PIM-Eligible](#fix-2--convert-standing-assignments-to-pim-eligible) |
| Candidate actions from step 4 show `PresentInThisTenant = True` and nobody is watching for them | → [Fix 3 — Wire Up Audit-Log Alerting](#fix-3--wire-up-audit-log-alerting) |
| Someone needs the pre-expansion (read/reporting-only) shape of the role, not the new identity-response powers | → [Fix 4 — Build a Narrower Custom Role](#fix-4--build-a-narrower-custom-role) |
| Ticket concerns a target who is themselves a privileged-role holder | → [Fix 5 — Confirm Sensitive-Actions Protection Still Applies](#fix-5--confirm-sensitive-actions-protection-still-applies) |
| All checks pass, behavior still doesn't match documentation | → Escalate — capture the Evidence Pack below and open a support case |

---
## Dependency Cascade

<details><summary>What determines whether a Security Administrator can act on a given user</summary>

```
Entra ID RBAC
  └── Security Administrator built-in role
        (templateId 194ae4cb-b126-40b2-bd5b-6091b380977d — privileged role)
        └── Microsoft-managed rollout, Sept 2026 (no tenant opt-in/opt-out)
              adds to the role's allowedResourceActions:
                microsoft.directory/users/disable
                microsoft.directory/users/enable
                microsoft.directory/users/invalidateAllRefreshTokens
                microsoft.directory/users/password/update
              └── Role assignment to a principal
                    (ACTIVE assignment — immediate)
                    (PIM-ELIGIBLE — must be ACTIVATED before actions apply)
                    └── Target user evaluated against
                          "who can perform sensitive actions" protection model
                          ├── Target is a NON-PRIVILEGED user
                          │     → action succeeds (this is the whole point of the change)
                          └── Target holds a privileged/protected role themselves
                                → action is BLOCKED unless the actor also holds a
                                  role permitted to touch protected principals
                                  (e.g. Privileged Authentication Administrator,
                                  Global Administrator) — Security Administrator
                                  alone does NOT get this exception
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm who currently holds the role (active + PIM-eligible)**
Use Triage steps 2–3. A principal must be either an active assignee, or an eligible assignee who has **activated**, before the new actions apply to them — eligible-but-not-activated grants nothing yet.

**Step 2 — Confirm the rollout has actually reached this tenant**
Use Triage step 4. Microsoft's own announcement states rollout completes by end of September 2026 tenant-by-tenant, not all-at-once — a tenant checked early in the window may legitimately show `PresentInThisTenant = False` for all four actions. Re-check periodically rather than assuming the query is broken.

**Step 3 — Confirm the target user is or isn't protected**
```powershell
# Does the target hold any directory role themselves?
Get-MgUserMemberOf -UserId "<targetUserId>" |
    Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.directoryRole' } |
    Select-Object @{N='Role';E={$_.AdditionalProperties.displayName}}
```
Expected: if this returns any role, the target is privileged and the "who can perform sensitive actions" protection model governs whether a plain Security Administrator can act on them — most privileged targets require a more senior role (Privileged Authentication Administrator or Global Administrator) to touch, exactly as before this change.

**Step 4 — Validate against audit logs after a reported action**
```powershell
Get-MgAuditLogDirectoryAudit -Filter "activityDisplayName eq 'Disable account' or activityDisplayName eq 'Reset user password' or activityDisplayName eq 'Update user'" -Top 25 |
    Select-Object ActivityDateTime, ActivityDisplayName, InitiatedBy, TargetResources
```
Cross-reference `InitiatedBy` against the Security Administrator assignee list from Step 1 to confirm the action was performed under this role's new permissions rather than an overlapping role (Authentication Administrator, User Administrator) the same person may also hold.

---
## Common Fix Paths

<details><summary>Fix 1 — Reduce Over-Assignment</summary>

**When:** Security Administrator is assigned to people or groups whose job is reading security reports/configuring security tooling, not managing user accounts — auditors, a SOC vendor, a monitoring dashboard service account.

```powershell
# Remove a member from the ACTIVE assignment
Remove-MgDirectoryRoleMemberByRef -DirectoryRoleId $roleId -DirectoryObjectId "<principalObjectId>"

# Reassign to Security Reader if only read access to security info/reports is needed
$readerRoleId = (Get-MgDirectoryRole -Filter "displayName eq 'Security Reader'").Id
New-MgDirectoryRoleMemberByRef -DirectoryRoleId $readerRoleId -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/<principalObjectId>"
}
```

Security Reader has **no write actions at all** and was not touched by this change — it is the correct downgrade target for anyone who only ever needed dashboards and reports.

**Rollback:** Re-add the removed principal to Security Administrator via the same `New-MgDirectoryRoleMemberByRef` pattern.

</details>

<details><summary>Fix 2 — Convert Standing Assignments to PIM-Eligible</summary>

**When:** Security Administrator is a permanent (Active, not PIM) assignment for people who need it only occasionally.

```powershell
# Remove standing Active assignment
Remove-MgDirectoryRoleMemberByRef -DirectoryRoleId $roleId -DirectoryObjectId "<principalObjectId>"

# Create a PIM-eligible assignment instead (requires Entra ID P2/Governance)
$params = @{
    Action = "adminAssign"
    Justification = "Convert standing Security Administrator to eligible per Sept 2026 identity-response expansion"
    RoleDefinitionId = "194ae4cb-b126-40b2-bd5b-6091b380977d"
    DirectoryScopeId = "/"
    PrincipalId = "<principalObjectId>"
    ScheduleInfo = @{
        StartDateTime = (Get-Date)
        Expiration = @{ Type = "afterDuration"; Duration = "P365D" }
    }
}
New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -BodyParameter $params
```

This is the single highest-leverage mitigation for this change: it does not remove anyone's access, but it means the newly-added disable/enable/revoke/reset-password powers require an active PIM activation (and, if configured, approval/justification/MFA) rather than being always-on for a standing assignee.

**Rollback:** Cancel the eligibility schedule request and re-add as an Active assignment if the PIM friction proves operationally unworkable.

</details>

<details><summary>Fix 3 — Wire Up Audit-Log Alerting</summary>

**When:** The candidate actions are confirmed live in this tenant (Triage step 4) and nobody is currently notified when a Security Administrator uses them.

Build an alert (Sentinel analytics rule, Log Analytics scheduled query, or a simple scheduled script against `Get-MgAuditLogDirectoryAudit`) that fires when `InitiatedBy` holds Security Administrator **and** `ActivityDisplayName` is one of `Disable account`, `Enable account`, `Reset user password`, `Revoke session`/`Update user` (session revocation currently logs as a user-update event in most tenants — verify the exact activity name in your own audit log stream before finalizing the query, since Microsoft has not published a fixed activity-name mapping for this specific new capability).

**Rollback:** N/A — monitoring only.

</details>

<details><summary>Fix 4 — Build a Narrower Custom Role</summary>

**When:** A team genuinely needs the pre-expansion (read security info/reports + manage security configuration) shape of the role and should not gain the new identity-response actions.

Microsoft Entra custom roles only support a **subset** of the permissions available to built-in roles — do not assume every action the current Security Administrator role grants (old or new) can be replicated 1:1 in a custom role. Before building one, enumerate the specific actions the team actually uses today (via the audit log query in Diagnosis Step 4 over a representative period) and confirm each is available as a custom-role-assignable permission.

```powershell
# Create a custom role scoped to read-only security actions (example — validate action availability first)
New-MgRoleManagementDirectoryRoleDefinition -DisplayName "Security Reader Plus (Custom)" -Description "Read security info/reports + config, no identity-response actions" -RolePermissions @(
    @{ AllowedResourceActions = @(
        "microsoft.directory/signInReports/allProperties/read",
        "microsoft.directory/auditLogs/allProperties/read"
        # add remaining actions only after confirming custom-role eligibility for each
    )}
) -IsEnabled
```

**Rollback:** Delete the custom role definition and reassign affected principals back to a built-in role.

</details>

<details><summary>Fix 5 — Confirm Sensitive-Actions Protection Still Applies</summary>

**When:** A ticket asks "can a Security Administrator now disable my Global Administrator's account?"

No — this change is explicitly scoped to **non-privileged users**. Run Diagnosis Step 3 against the target account; if it holds any directory role, standard sensitive-actions protection continues to require a more senior role (Privileged Authentication Administrator, Global Administrator) to act on it. This is read-only reassurance, not a configuration change.

**Rollback:** N/A.

</details>

---
## Escalation Evidence

```
=== SECURITY ADMINISTRATOR ROLE EXPANSION ESCALATION EVIDENCE PACK ===
Date/Time (UTC): _______________
Reported by: _______________
Tenant ID: _______________

SYMPTOM:
[ ] Security Administrator performed an unexpected disable/enable/revoke/reset action
[ ] Need to confirm whether rollout has reached this tenant
[ ] Over-broad role assignment discovered
[ ] Custom-role permission-availability question
[ ] Sensitive-actions protection concern (target holds a privileged role)
[ ] Other: _______________

TRIAGE RESULTS:
Active Security Administrator assignees (count): _______________
PIM-eligible assignees (count): _______________
Candidate actions present in this tenant's role definition (Y/N per action): _______________
Overlap with Authentication/User/Helpdesk/Password Administrator (Y/N): _______________
Target user privileged-role status (from Diagnosis Step 3): _______________

ACTIONS TAKEN:
_______________

CORRELATION ID: _______________
```

---
## 🎓 Learning Pointers

- **This is a platform-side role change, not a tenant misconfiguration.** No admin toggle turns the new identity-response actions on or off, and rollout is scheduled to complete by end of September 2026 tenant-by-tenant. Reference: [What's new in Microsoft Entra: September 2026](https://techcommunity.microsoft.com/blog/microsoft-entra-blog/what%E2%80%99s-new-in-microsoft-entra-september-2026/4545179)
- **Security Administrator's action list can change without your role assignments changing.** The role's `allowedResourceActions` are Microsoft-managed for built-in roles — query the live role definition (Triage step 4) rather than trusting stale documentation or memory of "what Security Administrator used to do." Reference: [Microsoft Entra built-in roles — Security Administrator](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference#security-administrator)
- **"Non-privileged users" is doing real protective work here.** Sensitive-actions protection (the same model that already governs Authentication Administrator, User Administrator, and Helpdesk Administrator) continues to shield privileged-role holders from a plain Security Administrator. Reference: [Who can perform sensitive actions](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/privileged-roles-permissions#who-can-perform-sensitive-actions)
- **Overlap with existing identity-management roles is now a real hygiene question, not a hypothetical.** Anyone holding Security Administrator *and* Authentication/User/Helpdesk/Password Administrator now has fully redundant identity-response power through two paths — worth cleaning up during the next access review.
- **Custom roles are not a guaranteed narrowing path.** Only a subset of built-in-role permissions are currently assignable to custom roles — verify action-by-action before promising a team "the old Security Administrator, minus the new powers" via a custom role. Reference: [Create a custom role in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/custom-create)
- **Don't confuse this with the parallel Security Operator/Microsoft Defender change.** Microsoft is separately extending containment actions for SOC analysts through the Defender portal's unified RBAC on the **Security Operator** role — a distinct mechanism, distinct portal, and distinct role from the Entra-native Security Administrator expansion this runbook covers. Verify which one a ticket actually concerns before applying these fixes.
