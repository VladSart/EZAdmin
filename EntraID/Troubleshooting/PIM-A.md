# Entra Privileged Identity Management (PIM) — Reference Runbook (Mode A: Deep Dive)
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

---
## Scope & Assumptions

This runbook covers **Entra ID PIM for Directory Roles** (Global Admin, Security Admin, etc.) and **PIM for Groups**. It does not cover PIM for Azure Resources (subscription/resource-group RBAC) except where noted.

**Assumes:**
- Microsoft Graph PowerShell SDK installed (`Install-Module Microsoft.Graph`)
- Operator has at least Privileged Role Administrator or Global Admin
- Tenant has Entra ID P2 licenses

**What PIM solves:**
Standing access (persistent admin role membership) is a security anti-pattern. PIM enforces **just-in-time (JIT) access** — users are *eligible* for roles but only *active* for a bounded time window, triggered by a deliberate activation step with optional MFA + approval + justification.

---
## How It Works

<details><summary>Full architecture</summary>

### PIM Role Assignment Model

PIM tracks two distinct assignment types:

| Type | Meaning | Portal Label |
|------|---------|-------------|
| **Eligible** | User can activate the role on-demand | "Eligible" |
| **Active** | User has the role right now (time-bounded or permanent) | "Active" |

### Activation Flow

```
User clicks "Activate" in PIM portal (or API)
        │
        ▼
Policy engine evaluates activation requirements:
    ├── MFA satisfied? (per-role setting)
    ├── Justification provided? (per-role setting)
    ├── Within allowed activation window? (start/end schedule)
    └── Approval required?
              ├── No  →  Assignment created immediately
              └── Yes →  PendingApproval
                              │
                    Approver action:
                    ├── Approve → Assignment created
                    └── Deny   → Request rejected
                              │
                              ▼
                    Role Assignment Schedule created
                              │
                              ▼
                    Token refresh required (new sign-in)
                              │
                              ▼
                    User has role claims in access token
```

### Token Propagation

Role claims are **embedded in the JWT access token** at issuance. This means:
- After a PIM activation, the user's *current* token still has the old claims.
- They must sign out and sign back in (or wait for token expiry, typically 1 hour) to get a token with the new role.
- Some services (Azure portal, Exchange) have their own token caches — clearing browser cookies or using InPrivate is usually sufficient.

### Policy Engine

Each role has a **Role Management Policy** that controls:
- Maximum activation duration (e.g., 8 hours)
- Whether MFA is required at activation
- Whether justification is required
- Whether approval is required, and who the approvers are
- Notification settings (alerts to admin when activation occurs)
- Assignment eligibility expiry rules

Policies are attached per role per scope. You can have different policies for the same role at different administrative unit scopes.

### PIM for Groups

PIM for Groups allows a group to be designated as a "Privileged Access Group." Members can be eligible for Owner or Member roles in the group. This is useful for:
- App role assignments (assign PIM-managed group to an app role)
- Nested RBAC (control access to a service without direct Entra role assignment)

```
User eligible for group membership
        │
        ▼
User activates group membership via PIM
        │
        ▼
Group membership active (time-bounded)
        │
        ▼
Group's app assignments / access permissions apply to user
        │
        ▼
Membership expires → access removed automatically
```

### Audit Trail

All PIM events write to:
- **Entra Audit Logs** — `activityDisplayName` starts with "Add member to role" or "Remove member from role"
- **Sign-in Logs** — activation MFA events
- **Microsoft Defender XDR** — elevated privilege alerts can be correlated here

</details>

---
## Dependency Stack

```
Physical Layer
    └── Microsoft Entra ID tenant (cloud service — no on-prem component)

License Layer
    └── Entra ID P2 license (or M365 E3/E5, EMS E5, Microsoft 365 E5 Security)
            └── Assigned to BOTH the user activating AND users receiving assignments

Identity Layer
    └── User account in Entra ID
            └── MFA registered (required for activation if policy enforces it)
            └── Not blocked / not in risky user state

PIM Service Layer
    └── Privileged Identity Management enabled (no explicit toggle — auto-enabled with P2)
            └── Role Management Policy configured per role
            └── Eligible assignment created (principalId → roleDefinitionId)
            └── (Optional) Approver assignments configured

Activation Layer
    └── User requests activation
            └── Policy requirements met (MFA, justification, approval)
            └── RoleAssignmentSchedule created with bounded expiry

Token/Cache Layer
    └── User re-authenticates (new sign-in)
            └── Access token issued with updated role claims
            └── Resource service respects token claims
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| "You have no eligible roles" | No eligible assignment / no P2 license | License + eligible schedule |
| Activation popup closes instantly, no activation | MFA not satisfied at current session | Sign out, re-auth with MFA, retry |
| Request stuck in `PendingApproval` | Approver unresponsive or approver account is also PIM-eligible (not active) | Check approver active assignments |
| Activation shows `Provisioned` but access denied | Token not refreshed post-activation | Sign out / InPrivate / token revoke |
| `AuthorizationRequestDenied` error | Justification missing or policy condition not met | Check policy requirements |
| Eligible assignment expired | `endDateTime` passed without renewal | Renew or create new eligibility |
| User can only see resources in one department | Scope set to Administrative Unit, not `/` | Check `directoryScopeId` on assignment |
| PIM activation succeeds but Exchange RBAC denied | Exchange Online has its own RBAC — Entra PIM doesn't control EXO roles directly | Assign EXO role separately |
| Activation fails: `InsufficientPrivileges` when creating assignment | Operator lacks Privileged Role Administrator | Check operator's own PIM assignment |
| PIM alerts firing for every activation | Notification policy set to alert on all activations | Review role notification settings |

---
## Validation Steps

**Step 1 — License validation**
```powershell
Connect-MgGraph -Scopes "User.Read.All","Organization.Read.All"
Get-MgUserLicenseDetail -UserId '<UPN or ObjectId>' |
  Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM_P2|EMS_E5|SPE_E5|M365_E5" } |
  Select-Object SkuPartNumber, SkuId
```
*Good:* Returns at least one matching SKU.
*Bad:* Empty — no P2 license. Assign from available pool or escalate for license procurement.

**Step 2 — Eligible assignment exists and valid**
```powershell
Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "principalId eq '<ObjectId>'" |
  Select-Object roleDefinitionId, directoryScopeId, status, startDateTime, endDateTime |
  Format-Table -AutoSize
```
*Good:* Status = `Provisioned`, expiry in the future or null.
*Bad:* Empty or expired.

**Step 3 — Role policy inspection**
```powershell
# Get role definition
$role = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '<RoleName>'"

# Get the policy assignment for this role at tenant scope
$policyAssignment = Get-MgPolicyRoleManagementPolicyAssignment -Filter "scopeId eq '/' and scopeType eq 'DirectoryRole' and roleDefinitionId eq '$($role.Id)'"

# Get the policy rules
Get-MgPolicyRoleManagementPolicyRule -UnifiedRoleManagementPolicyId $policyAssignment.PolicyId |
  Select-Object id, odataType | Sort-Object id
```
Rules of interest:
- `AuthenticationContext_EndUser_Assignment` — MFA requirement
- `Approval_EndUser_Assignment` — approval settings
- `Justification_EndUser_Assignment` — justification requirement
- `Expiration_EndUser_Assignment` — max duration

**Step 4 — Active assignments**
```powershell
Get-MgRoleManagementDirectoryRoleAssignmentSchedule -Filter "principalId eq '<ObjectId>'" |
  Select-Object roleDefinitionId, directoryScopeId, status, startDateTime, endDateTime |
  Format-Table -AutoSize
```
*Good:* Active entry with future `endDateTime`.
*Bad:* Empty = no currently active assignment.

**Step 5 — Recent request history**
```powershell
Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -Filter "principalId eq '<ObjectId>'" |
  Sort-Object createdDateTime -Descending | Select-Object -First 10 |
  Format-List action, status, createdDateTime, approvalId, completedDateTime
```

**Step 6 — Audit log correlation**
```powershell
Get-MgAuditLogDirectoryAudit -Filter "activityDisplayName eq 'Add member to role completed (PIM activation)' and targetResources/any(t:t/id eq '<ObjectId>')" -Top 20 |
  Select-Object activityDateTime, result, activityDisplayName, @{N='Initiator';E={$_.InitiatedBy.User.UserPrincipalName}}
```

---
## Troubleshooting Steps (by phase)

### Phase 1: Pre-Activation Failures

**User can't see eligible roles:**
1. Confirm P2 license assigned (Step 1 above).
2. Confirm eligible schedule exists and isn't expired (Step 2).
3. Confirm user is accessing `https://entra.microsoft.com` > Identity Governance > PIM, not a classic portal.
4. If recently assigned, wait up to 5 minutes for provisioning.

**Activation dialog fails immediately:**
1. Check if MFA is required in policy (Step 3, `AuthenticationContext` rule).
2. Check user's sign-in to confirm MFA was completed at *this session* (not just registered):
   ```powershell
   Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 3 |
     Select-Object createdDateTime, authenticationRequirement, mfaDetail
   ```
3. If MFA not satisfied: user must sign out, sign in again completing MFA prompt, then retry activation.

### Phase 2: Approval Workflow Issues

**Request stuck in PendingApproval:**
1. Identify the approvers:
   - Portal: PIM > Roles > [Role] > Settings > Approvers list
2. Check if approvers have active PIM assignments (if they need to be active to approve):
   ```powershell
   Get-MgRoleManagementDirectoryRoleAssignmentSchedule -Filter "principalId eq '<ApproverObjectId>'" |
     Where-Object { $_.Status -eq "Provisioned" }
   ```
3. If approver is inactive/unavailable:
   - Option A: Another Privileged Role Admin manually approves via PIM portal.
   - Option B: Temporarily bypass approval in policy.
   - Option C: Create a direct active assignment as emergency workaround (document in ticket).

### Phase 3: Post-Activation Access Issues

**Role active but access denied in portal:**
1. Confirm activation status (Step 4).
2. Force token refresh:
   ```powershell
   Revoke-MgUserSignInSession -UserId '<ObjectId>'
   ```
   User must sign back in fully.
3. Check scope — if `directoryScopeId` is not `/`, only AU-scoped access applies.
4. Check the specific service's own RBAC:
   - Exchange Online: separate `Get-ManagementRoleAssignment` check needed.
   - SharePoint: site-level permissions separate from Entra roles.
   - Azure resources: Entra PIM for Directory Roles ≠ Azure RBAC.

### Phase 4: Policy Misconfiguration

**All activations require approval but approver is an account that also needs PIM to activate:**
This is a deadlock. Resolution:
1. Identify a Global Admin with a *permanent* (non-PIM) assignment.
2. Have them log into PIM and either approve the pending request or modify the approver list to include a permanently-active account.
3. Policy fix: ensure at least one approver per critical role is permanently active (breakglass account pattern).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Create eligible assignment for a user</summary>

```powershell
Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory"

$role = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '<RoleName>'"
$user = Get-MgUser -Filter "userPrincipalName eq '<UPN>'"

$params = @{
    action            = "adminAssign"
    justification     = "MSP support — ticket <TicketID>"
    roleDefinitionId  = $role.Id
    directoryScopeId  = "/"
    principalId       = $user.Id
    scheduleInfo      = @{
        startDateTime = (Get-Date).ToUniversalTime().ToString("o")
        expiration    = @{
            type        = "AfterDateTime"
            endDateTime = (Get-Date).AddDays(90).ToUniversalTime().ToString("o")
        }
    }
}
$request = New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -BodyParameter $params
Write-Output "Eligibility request created: $($request.Id) — Status: $($request.Status)"
```

**Rollback:**
```powershell
New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -BodyParameter @{
    action           = "adminRemove"
    roleDefinitionId = $role.Id
    directoryScopeId = "/"
    principalId      = $user.Id
    justification    = "Reverting — ticket <TicketID>"
}
```
</details>

<details><summary>Playbook 2 — Admin-activate a role on behalf of a user (emergency)</summary>

Use when: user cannot self-activate due to MFA/approval issues and time is critical.

```powershell
Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory"

$role = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '<RoleName>'"
$user = Get-MgUser -Filter "userPrincipalName eq '<UPN>'"

$params = @{
    action            = "adminAssign"   # Direct active assignment, bypasses activation policy
    justification     = "Emergency admin activation — ticket <TicketID>"
    roleDefinitionId  = $role.Id
    directoryScopeId  = "/"
    principalId       = $user.Id
    scheduleInfo      = @{
        startDateTime = (Get-Date).ToUniversalTime().ToString("o")
        expiration    = @{
            type            = "AfterDuration"
            duration        = "PT8H"   # 8 hours
        }
    }
}
New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -BodyParameter $params
```

**Rollback (remove before expiry):**
```powershell
$schedule = Get-MgRoleManagementDirectoryRoleAssignmentSchedule -Filter "principalId eq '$($user.Id)' and roleDefinitionId eq '$($role.Id)'"
New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -BodyParameter @{
    action           = "adminRemove"
    roleDefinitionId = $role.Id
    directoryScopeId = "/"
    principalId      = $user.Id
    justification    = "Emergency revocation — ticket <TicketID>"
}
```
⚠️ `adminAssign` bypasses MFA and approval policy. Document every use in your ticketing system.
</details>

<details><summary>Playbook 3 — Modify role activation policy (approval, MFA, duration)</summary>

```powershell
Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory"

$role     = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '<RoleName>'"
$polAssign = Get-MgPolicyRoleManagementPolicyAssignment `
    -Filter "scopeId eq '/' and scopeType eq 'DirectoryRole' and roleDefinitionId eq '$($role.Id)'"
$policyId = $polAssign.PolicyId

# Get the approval rule
$approvalRule = Get-MgPolicyRoleManagementPolicyRule -UnifiedRoleManagementPolicyId $policyId |
    Where-Object { $_.Id -eq "Approval_EndUser_Assignment" }

# Disable approval requirement (patch the rule)
$body = @{
    "@odata.type" = "#microsoft.graph.unifiedRoleManagementPolicyApprovalRule"
    id            = "Approval_EndUser_Assignment"
    setting       = @{
        isApprovalRequired = $false
        approvalStages     = @()
    }
}
Update-MgPolicyRoleManagementPolicyRule `
    -UnifiedRoleManagementPolicyId $policyId `
    -UnifiedRoleManagementPolicyRuleId "Approval_EndUser_Assignment" `
    -BodyParameter $body
```

⚠️ Policy changes are tenant-wide for that role. Re-enable after the emergency window.
</details>

<details><summary>Playbook 4 — Set up breakglass accounts (permanent admin, outside PIM)</summary>

Breakglass accounts should have **permanent** Global Admin assignments (not PIM-eligible) to ensure access when PIM is misconfigured or unavailable.

```powershell
Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory","User.ReadWrite.All"

# Create or identify the breakglass user (should have no MFA methods — use very long complex password)
$bgUser = Get-MgUser -Filter "userPrincipalName eq 'breakglass@<domain>'"

# Create a permanent active assignment (no schedule expiry)
$role = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq 'Global Administrator'"
$params = @{
    action           = "adminAssign"
    justification    = "Breakglass permanent assignment"
    roleDefinitionId = $role.Id
    directoryScopeId = "/"
    principalId      = $bgUser.Id
    scheduleInfo     = @{
        startDateTime = (Get-Date).ToUniversalTime().ToString("o")
        expiration    = @{ type = "noExpiration" }
    }
}
New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -BodyParameter $params

# Exclude breakglass from ALL Conditional Access policies
# (do this in portal: CA > Named Locations / Exclusions — add breakglass group to each CA policy)
```

Best practices for breakglass:
- Store credentials in offline vault (physical safe or offline password manager)
- Monitor with alert rule: sign-in from breakglass account = P1 incident
- Review and rotate credentials quarterly
- Exclude from MFA Conditional Access policies (but monitor sign-in location)
- Reference: [Microsoft breakglass guidance](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/security-emergency-access)
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collect PIM evidence for escalation or audit
.DESCRIPTION Gathers eligible assignments, active assignments, recent requests, policy
             settings, and MFA status for a specified user.
.PARAMETER   UserUPN   UPN of the user to investigate
.EXAMPLE     .\Collect-PIMEvidence.ps1 -UserUPN "admin@contoso.com"
#>
param(
    [Parameter(Mandatory)][string]$UserUPN
)

Connect-MgGraph -Scopes "RoleManagement.Read.Directory","User.Read.All","AuditLog.Read.All","UserAuthenticationMethod.Read.All"

$user = Get-MgUser -Filter "userPrincipalName eq '$UserUPN'" -Property Id,DisplayName,UserPrincipalName,AccountEnabled
if (-not $user) { Write-Error "User not found: $UserUPN"; exit 1 }

Write-Host "`n=== USER ===" -ForegroundColor Cyan
$user | Format-List DisplayName, UserPrincipalName, Id, AccountEnabled

Write-Host "`n=== LICENSES ===" -ForegroundColor Cyan
Get-MgUserLicenseDetail -UserId $user.Id |
  Where-Object { $_.SkuPartNumber -match "PREMIUM_P2|EMS_E5|SPE_E5|M365_E5" } |
  Select-Object SkuPartNumber, SkuId | Format-Table

Write-Host "`n=== ELIGIBLE ASSIGNMENTS ===" -ForegroundColor Cyan
Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "principalId eq '$($user.Id)'" |
  ForEach-Object {
    $roleName = (Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $_.RoleDefinitionId).DisplayName
    [PSCustomObject]@{ Role = $roleName; Scope = $_.DirectoryScopeId; Status = $_.Status; Expires = $_.EndDateTime }
  } | Format-Table

Write-Host "`n=== ACTIVE ASSIGNMENTS ===" -ForegroundColor Cyan
Get-MgRoleManagementDirectoryRoleAssignmentSchedule -Filter "principalId eq '$($user.Id)'" |
  ForEach-Object {
    $roleName = (Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $_.RoleDefinitionId).DisplayName
    [PSCustomObject]@{ Role = $roleName; Scope = $_.DirectoryScopeId; Status = $_.Status; Expires = $_.EndDateTime }
  } | Format-Table

Write-Host "`n=== RECENT REQUESTS (last 10) ===" -ForegroundColor Cyan
Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -Filter "principalId eq '$($user.Id)'" |
  Sort-Object CreatedDateTime -Descending | Select-Object -First 10 |
  Select-Object Action, Status, CreatedDateTime, CompletedDateTime | Format-Table

Write-Host "`n=== MFA STATUS ===" -ForegroundColor Cyan
Get-MgReportAuthenticationMethodUserRegistrationDetail -UserId $user.Id |
  Select-Object IsMfaRegistered, IsMfaCapable, DefaultMfaMethod, MethodsRegistered | Format-List

Write-Host "`n=== RECENT AUDIT (PIM activations) ===" -ForegroundColor Cyan
Get-MgAuditLogDirectoryAudit -Filter "activityDisplayName eq 'Add member to role completed (PIM activation)' and targetResources/any(t:t/id eq '$($user.Id)')" -Top 10 |
  Select-Object ActivityDateTime, Result, ActivityDisplayName | Format-Table
```

---
## Command Cheat Sheet

```powershell
# Connect with PIM scopes
Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory","PrivilegedAccess.Read.AzureAD","AuditLog.Read.All"

# List all eligible assignments in tenant
Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All | Select-Object PrincipalId, RoleDefinitionId, Status, EndDateTime

# List all active (activated) assignments
Get-MgRoleManagementDirectoryRoleAssignmentSchedule -All | Where-Object { $_.AssignmentType -eq "Activated" }

# Get pending approval requests
Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -Filter "status eq 'PendingApproval'"

# Get role definition by name
Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq 'Global Administrator'"

# Get all PIM-managed roles (built-in)
Get-MgRoleManagementDirectoryRoleDefinition -Filter "isBuiltIn eq true" | Select-Object DisplayName, Id | Sort-Object DisplayName

# Get policy for a specific role
$role = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq 'Security Administrator'"
$polAssign = Get-MgPolicyRoleManagementPolicyAssignment -Filter "scopeId eq '/' and scopeType eq 'DirectoryRole' and roleDefinitionId eq '$($role.Id)'"
Get-MgPolicyRoleManagementPolicyRule -UnifiedRoleManagementPolicyId $polAssign.PolicyId | Select-Object Id

# Admin-activate a role (bypass policy — use for emergencies only)
# See Playbook 2 above

# Revoke user sessions (force token refresh after activation)
Revoke-MgUserSignInSession -UserId '<ObjectId>'

# Issue TAP for MFA bootstrap
New-MgUserAuthenticationTemporaryAccessPassMethod -UserId '<ObjectId>' -IsUsableOnce:$false -LifetimeInMinutes 480

# Get PIM audit events
Get-MgAuditLogDirectoryAudit -Filter "activityDisplayName eq 'Add member to role completed (PIM activation)'" -Top 50

# Check who has permanent (non-PIM) Global Admin
Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '62e90394-69f5-4237-9190-012177145e10'" |
  ForEach-Object { Get-MgUser -UserId $_.PrincipalId -ErrorAction SilentlyContinue | Select-Object DisplayName, UserPrincipalName }
```

---
## 🎓 Learning Pointers

- **Why JIT matters:** Every standing admin account is a persistent attack surface. PIM reduces the "blast radius" of a compromised admin credential — the attacker gets the credential but the account has no privileges until an activation (with MFA) occurs. See: [CISA guidance on privileged access](https://www.cisa.gov/resources-tools/resources/guidelines-applying-least-privilege-microsoft-azure)
- **Token claims are the real permission gate** — Entra roles aren't checked at every API call against a live database. The role claims in the JWT are checked. This is why PIM activation has a "propagation delay" — it's really a "token refresh delay."
- **The deadlock pattern is real and common** — organizations that put all Global Admins in PIM without a permanent breakglass account have locked themselves out. Every tenant should have 2 breakglass accounts excluded from CA policies. [MS guidance on breakglass](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/security-emergency-access)
- **PIM for Groups unlocks app-scoped JIT** — instead of assigning Entra roles, add a PIM-managed group to an app role. Users get JIT access to the application without needing a directory role. Powerful for controlling access to SaaS apps and Azure resources.
- **Audit log integration** — pipe PIM activation events to Microsoft Sentinel or your SIEM. `activityDisplayName eq 'Add member to role completed (PIM activation)'` in the Audit Logs table is the canonical filter.
- **MS Docs:** [PIM configuration guide](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-configure) | [PIM for Groups](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/concept-pim-for-groups)
