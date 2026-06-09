# Entra Privileged Identity Management (PIM) — Hotfix Runbook (Mode B: Ops)
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

```powershell
# 1. Check PIM service health
Connect-MgGraph -Scopes "RoleManagement.Read.Directory","PrivilegedAccess.Read.AzureAD"
Get-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -Filter "principalId eq '<UserObjectId>'" | Select-Object status, action, createdDateTime

# 2. Check user's active assignments
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<UserObjectId>'" | Select-Object roleDefinitionId, directoryScopeId

# 3. Check eligible assignments
Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "principalId eq '<UserObjectId>'" | Select-Object roleDefinitionId, status, startDateTime, endDateTime

# 4. Check pending approvals
Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -Filter "status eq 'PendingApproval'" | Select-Object principalId, roleDefinitionId, createdDateTime

# 5. Check MFA registration status for activating user
Get-MgReportAuthenticationMethodUserRegistrationDetail -UserId '<UserObjectId>' | Select-Object isMfaRegistered, isMfaCapable, defaultMfaMethod
```

| Result | Meaning | Action |
|--------|---------|--------|
| Request status = `Failed` | Activation blocked — check justification/MFA/approval | Fix 1 |
| No eligible assignments | User has no PIM eligibility configured | Fix 2 |
| Request status = `PendingApproval` | Waiting on approver — check approver availability | Fix 3 |
| `isMfaRegistered = false` | User can't activate — MFA not set up | Fix 4 |
| Active assignment exists but access denied | Role propagation delay or scope mismatch | Fix 5 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Entra ID P2 License (per user)
    └── PIM Service enabled in tenant
            └── Role eligibility assignment
                    ├── Activation policy configured (approval, MFA, justification, duration)
                    │       └── MFA registered on activating user's account
                    ├── (Optional) Approver assigned & available
                    └── Active assignment
                            └── Role permissions propagated to service
                                    └── User can perform privileged action
```

**Common gaps:**
- User has P2 license but it's not assigned to their account
- Eligible assignment exists but the role's activation policy requires an approver who is also in PIM (and not currently active)
- Role activated successfully but Graph/ARM permissions haven't propagated (~5 min)
- Scope set to a specific AU (Administrative Unit) — user can't see tenant-wide resources
</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the user has a PIM-eligible license**
```powershell
Get-MgUserLicenseDetail -UserId '<UserObjectId>' | Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM_P2|EMS_E5|M365_E5|SPE_E5" } | Select-Object SkuPartNumber, SkuId
```
*Expected:* At least one P2/E5 SKU returned.
*Bad:* Empty — assign an Entra P2 or upgrade license.

**Step 2 — Confirm eligible assignment exists and isn't expired**
```powershell
Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "principalId eq '<UserObjectId>'" |
  Select-Object @{N='Role';E={$_.RoleDefinitionId}}, status, startDateTime, endDateTime
```
*Expected:* Status = `Provisioned`, `endDateTime` in the future (or null for permanent).
*Bad:* Empty, or `endDateTime` has passed — create/renew the assignment.

**Step 3 — Check the activation policy for that role**
```powershell
$roleDef = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq 'Global Administrator'"
Get-MgPolicyRoleManagementPolicy -Filter "scopeId eq '/' and scopeType eq 'DirectoryRole'" |
  Where-Object { (Get-MgPolicyRoleManagementPolicyAssignment -Filter "policyId eq '$($_.Id)'").RoleDefinitionId -eq $roleDef.Id }
```
Check returned policy rules for: `isApprovalRequired`, `isMultifactorAuthenticationRequired`, `justificationRequired`.
*Expected:* MFA = true (acceptable), approval = depends on policy design.
*Bad:* ApprovalRequired = true with no approvers configured → activation will always be stuck.

**Step 4 — Check for stale/failed activation requests**
```powershell
Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -Filter "principalId eq '<UserObjectId>'" |
  Sort-Object createdDateTime -Descending | Select-Object -First 5 | 
  Format-List action, status, createdDateTime, completedDateTime, statusDetail
```
*Expected:* Most recent request = `Provisioned`.
*Bad:* `Failed` — expand `statusDetail` for reason code.

---
## Common Fix Paths

<details><summary>Fix 1 — Activation failing: MFA or justification error</summary>

**Symptoms:** User's activation request fails immediately with `AuthorizationRequestDenied` or user reports popup disappears without activating.

**Check:**
```powershell
# Confirm user has completed MFA at current session
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 5 |
  Select-Object createdDateTime, authenticationRequirement, mfaDetail
```

**Fix for MFA not satisfied:**
- User must complete MFA *at time of activation* — not just be registered.
- Have user sign out and sign back in with MFA, then try PIM activation again.
- If MFA fails (no phone/authenticator available): temporarily lower policy requirement OR use TAP:
```powershell
# Issue a Temporary Access Pass (TAP) to allow MFA registration
New-MgUserAuthenticationTemporaryAccessPassMethod -UserId '<UserObjectId>' -IsUsableOnce:$true -LifetimeInMinutes 60
```

**Fix for justification missing:**
- Policy requires justification text — user must enter a reason in the activation dialog.
- Cannot be bypassed without editing the role policy.

**Rollback:** No rollback needed — request simply fails without activating anything.
</details>

<details><summary>Fix 2 — User has no eligible assignment</summary>

**Symptoms:** User sees "You have no eligible roles" in PIM portal.

**Add eligible assignment via portal or PowerShell:**
```powershell
# Get role definition ID
$role = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '<RoleName>'"

# Assign eligibility (adjust dates as needed)
$params = @{
    action = "adminAssign"
    justification = "MSP support access per ticket <TicketID>"
    roleDefinitionId = $role.Id
    directoryScopeId = "/"
    principalId = "<UserObjectId>"
    scheduleInfo = @{
        startDateTime = (Get-Date).ToUniversalTime().ToString("o")
        expiration = @{
            type = "AfterDateTime"
            endDateTime = (Get-Date).AddDays(90).ToUniversalTime().ToString("o")
        }
    }
}
New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -BodyParameter $params
```

**Rollback:**
```powershell
# Remove eligibility (get the schedule ID first)
$schedule = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "principalId eq '<UserObjectId>' and roleDefinitionId eq '<RoleDefId>'"
New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -BodyParameter @{
    action = "adminRemove"; roleDefinitionId = $schedule.RoleDefinitionId
    directoryScopeId = "/"; principalId = "<UserObjectId>"
}
```
</details>

<details><summary>Fix 3 — Request stuck in PendingApproval</summary>

**Symptoms:** User activated PIM role but it's been pending for more than a few minutes.

**Check who the approvers are:**
```powershell
# Find approvers for the role's policy
$roleDef = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '<RoleName>'"
# In portal: PIM > Roles > <Role> > Settings > Require Approval > Approvers
```

**Options:**
1. **Notify the approver** — they must go to PIM > Approve requests.
2. **Admin-approve directly:**
```powershell
$request = Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -Filter "status eq 'PendingApproval' and principalId eq '<UserObjectId>'"
# Approve via portal: PIM > Approve requests > select request > Approve
```
3. **Emergency bypass** — temporarily disable approval requirement:
   - PIM > Roles > [Role] > Settings > Edit > Require Approval = Off
   - Re-enable after the user activates.

**Rollback:** Re-enable approval requirement if disabled.
</details>

<details><summary>Fix 4 — User not MFA registered</summary>

**Symptoms:** User cannot complete activation step requiring MFA; registration portal fails.

```powershell
# Check registration details
Get-MgReportAuthenticationMethodUserRegistrationDetail -UserId '<UserObjectId>' |
  Select-Object isMfaRegistered, isMfaCapable, methodsRegistered, defaultMfaMethod

# Issue TAP so user can register without existing MFA method
New-MgUserAuthenticationTemporaryAccessPassMethod -UserId '<UserObjectId>' `
  -IsUsableOnce:$false -LifetimeInMinutes 480
```
User navigates to `https://aka.ms/mfasetup`, signs in with TAP, registers Authenticator app.
After registration, TAP should be revoked:
```powershell
$tap = Get-MgUserAuthenticationTemporaryAccessPassMethod -UserId '<UserObjectId>'
Remove-MgUserAuthenticationTemporaryAccessPassMethod -UserId '<UserObjectId>' -TemporaryAccessPassAuthenticationMethodId $tap.Id
```
</details>

<details><summary>Fix 5 — Role activated but permissions not working</summary>

**Symptoms:** Activation shows as `Provisioned` in PIM but user still gets access denied in portal/API.

**Propagation wait:** Role assignments propagate within 2–5 minutes. Have user:
1. Sign out completely (all browser tabs)
2. Clear browser cache / use InPrivate
3. Sign back in
4. Retry the action

**Check scope:**
```powershell
Get-MgRoleManagementDirectoryRoleAssignmentSchedule -Filter "principalId eq '<UserObjectId>'" |
  Select-Object roleDefinitionId, directoryScopeId, status
```
If `directoryScopeId` is not `/`, the assignment is scoped to an Administrative Unit — the user only has access within that AU.

**Force token refresh:**
```powershell
# Revoke user sessions to force new token with updated role claims
Revoke-MgUserSignInSession -UserId '<UserObjectId>'
```
User must sign in again.
</details>

---
## Escalation Evidence

```
=== PIM ESCALATION EVIDENCE PACK ===
Date/Time (UTC): ___________________
Tenant ID: ___________________
Affected UPN: ___________________
Target Role: ___________________
Ticket/Change: ___________________

SYMPTOM:
[ ] Activation failing — error: ___________________
[ ] Stuck in PendingApproval since: ___________________
[ ] Eligible assignment missing
[ ] Role activated but access denied

PIM REQUEST STATUS:
RequestId: ___________________
Status: ___________________
StatusDetail: ___________________
CreatedDateTime: ___________________

LICENSE CHECK:
P2 License assigned: [ ] Yes  [ ] No  SKU: ___________________

MFA CHECK:
isMfaRegistered: ___________________
defaultMfaMethod: ___________________

ROLE POLICY:
Approval required: [ ] Yes  [ ] No
Approvers configured: [ ] Yes  [ ] No
MFA required: [ ] Yes  [ ] No

ADDITIONAL NOTES:
___________________

Collected by: ___________________ at ___________________
```

---
## 🎓 Learning Pointers

- **PIM requires Entra ID P2** per user (activating and eligible) — it's included in M365 E3+, EMS E5, and standalone Entra P2. Users without the license simply can't see eligible roles.
- **Activation ≠ immediate access** — role claims are embedded in the user's access token. The token must be refreshed (new sign-in) before role permissions are visible to services.
- **Approval chains can deadlock** — if the only approvers for a role are themselves PIM-eligible (not permanently active), and they're unavailable, no one can approve. Always have at least one permanently-active Global Admin as a fallback approver or breakglass account.
- **TAP is the right tool for MFA bootstrapping** — Temporary Access Pass lets you register MFA on accounts that can't complete the current MFA challenge. See: [Microsoft Docs — TAP](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-authentication-temporary-access-pass)
- **Audit everything** — PIM activations are logged in `AuditLogs` and `SignInLogs`. Filter on `activityDisplayName eq 'Add member to role completed (PIM activation)'` for post-incident review.
- **MS Docs reference:** [Entra PIM Documentation](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-configure)
