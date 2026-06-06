# Entra External Identities — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference for B2B guest access, external collaboration, and cross-tenant issues.

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

| Item | Detail |
|------|--------|
| Applies to | Entra ID B2B Guest invitations, Cross-Tenant Access Settings (CTAS), External Collaboration Settings |
| Not covered | Azure AD B2C (customer identity), Entra External ID for workforce (preview) |
| Pre-requisite knowledge | Entra ID basics, Conditional Access, MFA concepts |
| Permissions needed | User Administrator or Guest Inviter role for day-to-day; Global Reader for read-only investigation |
| Tenant types | Any Entra ID tenant acting as resource tenant; home tenant investigation requires access to that tenant |

**Resource tenant** = the MSP or customer tenant hosting the resource (SharePoint, Teams, etc.)
**Home tenant** = the guest user's own Azure AD tenant (or Microsoft Account / Email OTP for unmanaged)

---

## How It Works

<details><summary>Full B2B invitation and redemption architecture</summary>

### B2B Invitation Flow

```
Resource Tenant Admin / User (Inviter)
    │
    │  POST /invitations  (or Bulk Invite / SharePoint share)
    ▼
Entra ID (Resource Tenant)
    │  Creates: Guest user object (userType=Guest)
    │  Generates: Invitation redemption URL (one-time use)
    │  Sends: Email to invitee (optional)
    ▼
Invitee receives link
    │
    ├── Has Azure AD account (managed)
    │       └── Redirected to home tenant login → consent → token issued
    │
    ├── Has Microsoft Account (consumer)
    │       └── MSA login flow → consent → token issued
    │
    └── Has other/no account
            └── Email OTP (one-time passcode) flow
                └── 6-digit code emailed → entered at redemption
```

### Post-Redemption State

After redemption:
```
Resource Tenant: Guest user object
    ├── userType          = Guest
    ├── userPrincipalName = user_externaldomain.com#EXT#@resourcetenant.onmicrosoft.com
    ├── mail              = user@externaldomain.com
    ├── externalUserState = Accepted (was: PendingAcceptance)
    └── creationType      = Invitation
```

The guest object in the resource tenant is a **shadow** of the home identity. Authentication always happens at the home tenant (or MSA/OTP) — the resource tenant only issues authorisation tokens.

### Cross-Tenant Access Settings (CTAS) — Trust Policy Engine

CTAS is the modern policy layer (GA since late 2022) that controls what's trusted from external tenants:

```
Inbound CTAS (resource tenant controls)
    ├── Allow/block B2B collaboration from specific tenants
    ├── Trust MFA claims from home tenant (avoids MFA double-prompt)
    ├── Trust compliant device claims from home tenant
    └── Trust Hybrid Azure AD joined device claims

Outbound CTAS (home tenant controls)
    ├── Allow/block users from accessing external tenants
    └── Control what claims are shared outbound

Default settings (applied if no tenant-specific rule matches)
    ├── Allow all inbound B2B collaboration
    └── Allow all outbound B2B collaboration
```

CTAS tenant-specific rules override defaults. Order of evaluation:
1. Check if target tenant has a specific CTAS rule → use it
2. If no specific rule → apply CTAS defaults
3. Apply Conditional Access policies (can further restrict based on guest user type)

### Authentication Flow for Existing Guest

```
Guest user → Resource tenant URL
    │
    ▼
Resource Tenant: Is this user a guest with externalUserState=Accepted?
    │  Yes → Continue
    │  No  → Redirect to invitation redemption
    ▼
Resource Tenant CTAS: Is this home tenant allowed?
    │  Blocked → 403
    │  Allowed → Continue
    ▼
Redirect to Home Tenant for authentication
    │  Home tenant authenticates user (password, MFA, etc.)
    │  Issues: ID token + access token
    ▼
Resource Tenant evaluates Conditional Access
    │  Guest user policies evaluated (often separate from member policies)
    │  MFA required? → Check if home tenant MFA claim trusted (CTAS inbound trust setting)
    ▼
Access granted / denied
```

### Email OTP vs Managed Identity

| Scenario | Auth method | Guest object type |
|----------|-------------|------------------|
| Invitee has Azure AD account | Entra ID (SAML/OIDC redirect) | Federation |
| Invitee has Microsoft Account | MSA | MSA |
| Invitee has Gmail / generic email | Email OTP | OTP |
| Invitee has SAML-federated IdP | Direct federation | DirectFederation |

Email OTP guests are **unmanaged** — no Conditional Access enforcement from the home tenant. The resource tenant is the only control point.

</details>

---

## Dependency Stack

```
Resource being accessed (SharePoint, Teams, App)
    │
    ▼
Resource Tenant Authorization (Entra ID RBAC / SharePoint permissions)
    │  Requires: Guest user object exists, correct role/group membership
    ▼
Conditional Access Evaluation (Resource Tenant)
    │  Requires: Guest-specific CA policies or member policies (check assignment)
    │  MFA enforcement → CTAS trust settings determine if home MFA satisfies
    ▼
Cross-Tenant Access Settings (CTAS)
    │  Requires: Inbound collaboration not blocked for home tenant
    │  Trust settings: MFA, Compliant Device, HAADJ
    ▼
Home Tenant Authentication
    │  Requires: User account active, not blocked, MFA configured
    │  For OTP: email deliverable, OTP not expired (30 min)
    ▼
Invitation State
    │  Requires: externalUserState = Accepted (not PendingAcceptance, not expired)
    ▼
External Collaboration Settings
    │  Requires: Guest invite policy allows this invitee's domain
    │  Domain allowlist/blocklist evaluated here
    ▼
Guest User Object (Resource Tenant)
    │  Requires: accountEnabled = true, not deleted, correct UPN/mail
    ▼
User Access (success)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Guest receives invitation email but link says "expired" | Invitation redeemed already (one-time use) or older 90-day invitation expired | Check `externalUserState` — if Accepted, invite was already used; resend if OTP |
| Guest gets "You don't have access to this" after sign-in | Guest object exists but not added to resource permissions (SharePoint, Teams, app role) | Check guest object's group memberships and direct assignments |
| Guest gets "Your organization has restricted access" | CTAS inbound block on the guest's home tenant | Check CTAS → External identities → Cross-tenant access settings |
| Guest prompted for MFA every session despite home tenant having MFA | CTAS inbound MFA trust not enabled | Enable "Trust MFA from Azure AD tenants" in CTAS inbound settings |
| Guest can't access resource from compliant device | CTAS compliant device trust not enabled; CA policy requires compliant device for guests | Enable compliant device trust in CTAS or exclude guests from device compliance CA |
| "The user account that you are trying to sign-in with is blocked" | `accountEnabled = false` on guest object in resource tenant | `Update-MgUser -UserId $guestId -AccountEnabled $true` |
| Guest account shows "PendingAcceptance" after weeks | Invitation not redeemed; email may have been filtered | Resend invitation or use direct redemption URL |
| New guest invitation fails: "You cannot invite a user from this domain" | Domain on allowlist/blocklist (External Collaboration Settings) | Check Entra → External Identities → External collaboration settings |
| Guest can access some Teams channels but not others | Private channels require direct membership; guest sharing of private channels requires separate setting | Check channel type and "Allow guest access to private channels" |
| Existing guest "lost access" after working fine | Guest user object soft-deleted or disabled; home account disabled/deleted; CA policy change | Run evidence pack — check all layers |
| B2B direct connect fails (Teams Connect) | B2B direct connect requires mutual CTAS configuration on both tenants | Both tenants need CTAS direct connect enabled for each other |

---

## Validation Steps

**Step 1 — Find the guest user object and check its state**
```powershell
Connect-MgGraph -Scopes "User.Read.All", "Directory.Read.All"
$guestMail = "<guest@externaldomain.com>"

$guest = Get-MgUser -Filter "mail eq '$guestMail' and userType eq 'Guest'" `
    -Property Id, DisplayName, UserPrincipalName, Mail, ExternalUserState, AccountEnabled, CreatedDateTime, SignInActivity

[PSCustomObject]@{
    DisplayName       = $guest.DisplayName
    UPN               = $guest.UserPrincipalName
    Mail              = $guest.Mail
    UserType          = "Guest"
    AccountEnabled    = $guest.AccountEnabled
    ExternalUserState = $guest.ExternalUserState
    CreatedDateTime   = $guest.CreatedDateTime
    LastSignIn        = $guest.SignInActivity.LastSignInDateTime
}
```
Expected: `AccountEnabled = True`, `ExternalUserState = Accepted`

**Step 2 — Check Cross-Tenant Access Settings for the home tenant**
```powershell
# Get all tenant-specific CTAS rules
$ctasRules = Get-MgPolicyCrossTenantAccessPolicyPartner
$ctasRules | Select-Object TenantId, B2BCollaborationInbound, B2BCollaborationOutbound

# Check default settings
Get-MgPolicyCrossTenantAccessPolicyDefault | ConvertTo-Json -Depth 5
```

**Step 3 — Check External Collaboration Settings (invite restrictions)**
```powershell
$extCollab = Get-MgPolicyAuthorizationPolicy
$extCollab.DefaultUserRolePermissions | Select-Object AllowedToCreateSecurityGroups
(Get-MgPolicyAuthorizationPolicy).GuestUserRoleId
# b2bGuestUserRoleId values:
# 10dae51f-b6af-4016-8d66-8c2a99b929b3 = Guest User (most restrictive)
# bf6a0e53-5b87-4e11-87d9-7b70c00b1e12 = Restricted Guest User
# a0b1b346-4d3e-4e8b-98f8-753987be4970 = Member (same as member - not recommended)
```

**Step 4 — Check the guest's group memberships in resource tenant**
```powershell
Get-MgUserMemberOf -UserId $guest.Id | 
    Select-Object Id, @{N='DisplayName';E={$_.AdditionalProperties['displayName']}}, @{N='Type';E={$_.'@odata.type'}}
```

**Step 5 — Review sign-in logs for the guest**
```powershell
# Requires AuditLog.Read.All
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$($guest.UserPrincipalName)'" -Top 10 |
    Select-Object CreatedDateTime, AppDisplayName, Status, ConditionalAccessStatus, 
                  @{N='FailureReason';E={$_.Status.FailureReason}},
                  @{N='CaResult';E={($_.AppliedConditionalAccessPolicies | ForEach-Object { "$($_.DisplayName):$($_.Result)" }) -join '; '}}
```

**Step 6 — Check if invitation has expired or been revoked**
```powershell
# Re-send invitation (resets state to PendingAcceptance, sends new link)
# Only use if guest needs to re-redeem
$inviteParams = @{
    invitedUserEmailAddress = $guestMail
    inviteRedirectUrl       = "https://myapps.microsoft.com"
    sendInvitationMessage   = $true
    invitedUserMessageInfo  = @{
        customizedMessageBody = "Please accept this updated invitation to access our resources."
    }
}
New-MgInvitation -BodyParameter $inviteParams
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Invitation / Account Creation Problems

1. **Invitation fails with domain restriction error:**
   ```powershell
   # Check current allow/block list
   (Get-MgPolicyAuthorizationPolicy).AllowInvitesFrom
   # Values: none | adminsAndGuestInviters | adminsGuestInvitersAndAllMembers | everyone
   ```
   Navigate to: Entra Portal → External Identities → External collaboration settings → Collaboration restrictions

2. **Guest account not created after bulk invite:**
   ```powershell
   # Check bulk operation status via Graph
   # Bulk invite creates an async job — check for errors
   Get-MgDirectoryDeletedItemAsUser -Filter "startswith(userPrincipalName,'target@')" | 
       Select-Object Id, UserPrincipalName, DeletedDateTime
   ```

3. **Duplicate guest objects (user@domain.com and user_domain.com#EXT#):**
   - This happens when a guest self-registers AND is later invited
   - Merge is not natively supported; document the correct object ID and delete the stale one:
   ```powershell
   Remove-MgUser -UserId "<staleGuestObjectId>"
   # Then re-invite if needed
   ```

### Phase 2 — Authentication Failures

1. **"AADSTS50020: User account from identity provider does not exist in tenant":**
   - Home tenant deleted the user
   - User changed email address (now a different identity)
   - Resolution: delete guest object, re-invite with new email
   ```powershell
   Remove-MgUser -UserId $guest.Id
   # Wait 30 seconds, then re-invite
   New-MgInvitation -BodyParameter @{ invitedUserEmailAddress = "newEmail@domain.com"; inviteRedirectUrl = "https://myapps.microsoft.com"; sendInvitationMessage = $true }
   ```

2. **"AADSTS50076: Due to a configuration change made by your administrator, or because you moved to a new location, you must use multi-factor authentication":**
   - CA policy in resource tenant requires MFA for guests, but CTAS trust isn't enabled
   - Option A: Enable CTAS inbound MFA trust for the partner tenant
   - Option B: Exclude from CA policy (less secure)
   ```powershell
   # Enable MFA trust for a specific partner tenant via Graph
   $tenantId = "<partnerTenantId>"
   $params = @{
       b2bCollaborationInbound = @{
           usersAndGroups = @{ accessType = "allowed" }
           applications   = @{ accessType = "allowed" }
           trustSettings  = @{
               isMfaAccepted                    = $true
               isCompliantDeviceAccepted        = $false
               isHybridAzureADJoinedDeviceAccepted = $false
           }
       }
   }
   Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $tenantId -BodyParameter $params
   ```

3. **Email OTP not arriving:**
   - Check spam/junk folder
   - OTP expires after 30 minutes — must request new code
   - Verify email address on guest object matches delivery address
   - Check if OTP feature is enabled:
   ```powershell
   # OTP is controlled under External Identities → All identity providers → Email OTP
   # No PowerShell cmdlet for this; check via portal or Graph:
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/Email"
   ```

### Phase 3 — Access / Permission Problems

1. **Guest can sign in but sees empty MyApps or can't find the resource:**
   - Guest not assigned to application or group
   - Teams: guest not explicitly added to team (even if group member)
   - SharePoint: External sharing must be enabled at site and tenant level

2. **Guest previously had access, now getting 403:**
   ```powershell
   # Check if account was disabled (common after access review)
   (Get-MgUser -UserId $guest.Id -Property AccountEnabled).AccountEnabled
   
   # Re-enable if appropriate:
   Update-MgUser -UserId $guest.Id -AccountEnabled $true
   ```

3. **Access Reviews automatically removed guest:**
   - Entra ID Access Reviews can auto-remove guests who are not approved
   - Check: Entra → Identity Governance → Access reviews — look for reviews on groups/apps the guest was in
   - Resolution: re-add to group/app; consider adjusting Access Review settings

---

## Remediation Playbooks

<details><summary>Playbook 1 — Reset a stuck guest invitation (resend)</summary>

**When to use:** Guest invitation email never received, expired, or link doesn't work.

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All"
$guestMail = "<guest@externaldomain.com>"

# Check current state
$guest = Get-MgUser -Filter "mail eq '$guestMail' and userType eq 'Guest'" -Property Id, ExternalUserState
Write-Host "Current state: $($guest.ExternalUserState)"

# Option A: If guest exists but PendingAcceptance — resend invite
$inviteParams = @{
    invitedUserEmailAddress = $guestMail
    inviteRedirectUrl       = "https://myapps.microsoft.com"
    sendInvitationMessage   = $true
}
$result = New-MgInvitation -BodyParameter $inviteParams
Write-Host "New invitation sent. Redemption URL: $($result.InviteRedeemUrl)"

# Option B: Share the direct link with the guest (avoids email delivery issues)
Write-Host "Direct link (share via alternate channel): $($result.InviteRedeemUrl)"
```

</details>

<details><summary>Playbook 2 — Enable CTAS MFA trust for partner tenant</summary>

**When to use:** Partner tenant guests are getting double-MFA prompts or being blocked by MFA CA policy despite completing MFA at home.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.CrossTenantAccess"
$partnerTenantId = "<partnerTenantId>"

# Check if partner entry exists
$existing = Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $partnerTenantId -ErrorAction SilentlyContinue

if (-not $existing) {
    # Create new partner entry
    $newPartner = @{ tenantId = $partnerTenantId }
    New-MgPolicyCrossTenantAccessPolicyPartner -BodyParameter $newPartner
}

# Enable MFA trust
$params = @{
    b2bCollaborationInbound = @{
        usersAndGroups = @{ accessType = "allowed" }
        applications   = @{ accessType = "allowed" }
        trustSettings  = @{
            isMfaAccepted                       = $true
            isCompliantDeviceAccepted           = $false
            isHybridAzureADJoinedDeviceAccepted = $false
        }
    }
}
Update-MgPolicyCrossTenantAccessPolicyPartner `
    -CrossTenantAccessPolicyPartnerTenantId $partnerTenantId `
    -BodyParameter $params

Write-Host "CTAS MFA trust enabled for tenant: $partnerTenantId"
```

**Rollback:**
```powershell
$params = @{
    b2bCollaborationInbound = @{
        trustSettings = @{
            isMfaAccepted = $false
        }
    }
}
Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $partnerTenantId -BodyParameter $params
```

</details>

<details><summary>Playbook 3 — Bulk guest cleanup (remove stale guests)</summary>

**When to use:** Quarterly or annual guest access hygiene; remove guests who haven't signed in for 90+ days.

```powershell
<#
.SYNOPSIS    Remove stale guest users (not signed in for N days)
.NOTES       Review output CSV before actually deleting — set $WhatIf = $true for dry run
#>
Connect-MgGraph -Scopes "User.Read.All", "User.ReadWrite.All", "AuditLog.Read.All"

$DaysInactive = 90
$WhatIf       = $true   # Set to $false to actually delete
$cutoff       = (Get-Date).AddDays(-$DaysInactive)
$OutputPath   = "C:\StaleGuests_$(Get-Date -Format 'yyyyMMdd').csv"

$staleGuests = Get-MgUser -All -Filter "userType eq 'Guest'" `
    -Property Id, DisplayName, Mail, UserPrincipalName, ExternalUserState, SignInActivity, CreatedDateTime |
    Where-Object {
        $lastSignIn = $_.SignInActivity.LastSignInDateTime
        (-not $lastSignIn) -or ($lastSignIn -lt $cutoff)
    }

$report = $staleGuests | Select-Object DisplayName, Mail, UserPrincipalName, ExternalUserState,
    @{N='LastSignIn';E={$_.SignInActivity.LastSignInDateTime}},
    @{N='CreatedDate';E={$_.CreatedDateTime}},
    @{N='DaysSinceSignIn';E={ if ($_.SignInActivity.LastSignInDateTime) { (New-TimeSpan -Start $_.SignInActivity.LastSignInDateTime).Days } else { "Never" } }}

$report | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Host "Stale guest report: $OutputPath ($($staleGuests.Count) users)"

if (-not $WhatIf) {
    foreach ($u in $staleGuests) {
        Write-Host "Deleting: $($u.Mail)"
        Remove-MgUser -UserId $u.Id
    }
    Write-Host "Deleted $($staleGuests.Count) stale guest accounts."
} else {
    Write-Host "[WhatIf] No changes made. Set `$WhatIf = `$false to execute."
}
```

</details>

<details><summary>Playbook 4 — Block external collaboration from a specific domain</summary>

**When to use:** Security incident; need to immediately block a partner domain from accessing tenant resources.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.CrossTenantAccess"
$blockDomain = "compromiseddomain.com"

# Method 1: CTAS — block by tenant ID (requires knowing their tenant ID)
# Find tenant ID from sign-in logs first:
Get-MgAuditLogSignIn -Filter "contains(userPrincipalName,'$blockDomain')" -Top 5 |
    Select-Object UserPrincipalName, HomeTenantId

# Then add a CTAS block:
$blockTenantId = "<resolvedTenantId>"
$blockParams = @{
    b2bCollaborationInbound = @{
        usersAndGroups = @{ accessType = "blocked" }
        applications   = @{ accessType = "blocked" }
    }
}
New-MgPolicyCrossTenantAccessPolicyPartner -BodyParameter @{ tenantId = $blockTenantId }
Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $blockTenantId -BodyParameter $blockParams

# Method 2: External Collaboration Settings — domain blocklist
# (Portal only for domain blocklist: Entra → External Identities → External collaboration settings → Collaboration restrictions)
# Add domain to "Deny invitations to the specified domains" list

Write-Host "Blocked inbound B2B collaboration from tenant: $blockTenantId"
Write-Host "Note: Existing guest sessions will expire at their normal token lifetime (1 hour access token)"
```

**Rollback:**
```powershell
Remove-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $blockTenantId
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS    Collect External Identities evidence for a specific guest user
.NOTES       Requires: User.Read.All, AuditLog.Read.All, Policy.Read.All
#>
param(
    [Parameter(Mandatory)][string]$GuestEmail,
    [string]$OutputPath = "C:\ExternalIdentitiesEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

Connect-MgGraph -Scopes "User.Read.All", "AuditLog.Read.All", "Policy.Read.All", "Directory.Read.All"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# 1. Guest user object
$guest = Get-MgUser -Filter "mail eq '$GuestEmail' and userType eq 'Guest'" `
    -Property Id, DisplayName, UserPrincipalName, Mail, ExternalUserState, AccountEnabled, 
              CreatedDateTime, SignInActivity, OnPremisesSyncEnabled
$guest | ConvertTo-Json -Depth 5 | Out-File "$OutputPath\1_GuestUserObject.json"

if (-not $guest) {
    Write-Warning "Guest not found. Checking deleted users..."
    Get-MgDirectoryDeletedItemAsUser -Filter "mail eq '$GuestEmail'" | 
        ConvertTo-Json -Depth 3 | Out-File "$OutputPath\1b_DeletedGuestObject.json"
}

# 2. Group memberships
if ($guest) {
    Get-MgUserMemberOf -UserId $guest.Id |
        Select-Object Id, @{N='Name';E={$_.AdditionalProperties['displayName']}} |
        ConvertTo-Json | Out-File "$OutputPath\2_GroupMemberships.json"
}

# 3. Recent sign-in logs
if ($guest) {
    Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$($guest.UserPrincipalName)'" -Top 20 |
        Select-Object CreatedDateTime, AppDisplayName, Status, ConditionalAccessStatus,
                      @{N='FailureReason';E={$_.Status.FailureReason}},
                      @{N='CAPolicies';E={($_.AppliedConditionalAccessPolicies | ForEach-Object {"$($_.DisplayName):$($_.Result)"}) -join '; '}} |
        ConvertTo-Json | Out-File "$OutputPath\3_SignInLogs.json"
}

# 4. CTAS policies (all)
Get-MgPolicyCrossTenantAccessPolicyPartner | ConvertTo-Json -Depth 5 | Out-File "$OutputPath\4_CTASPartnerPolicies.json"
Get-MgPolicyCrossTenantAccessPolicyDefault | ConvertTo-Json -Depth 5 | Out-File "$OutputPath\5_CTASDefaultPolicy.json"

# 6. External collaboration settings
Get-MgPolicyAuthorizationPolicy | 
    Select-Object AllowInvitesFrom, GuestUserRoleId, DefaultUserRolePermissions |
    ConvertTo-Json -Depth 3 | Out-File "$OutputPath\6_ExternalCollaborationSettings.json"

Write-Host "`n=== EVIDENCE SUMMARY ==="
Write-Host "Guest Email        : $GuestEmail"
Write-Host "Account Found      : $($null -ne $guest)"
Write-Host "Account Enabled    : $($guest.AccountEnabled)"
Write-Host "Invitation State   : $($guest.ExternalUserState)"
Write-Host "Last Sign-In       : $($guest.SignInActivity.LastSignInDateTime)"
Write-Host "Evidence saved to  : $OutputPath"
```

**Escalation template:**
```
Subject: Entra External Identities — Guest Access Issue — [TenantName] — [Ticket#]

Tenant ID         : <tenantId>
Guest Email       : <guest@partner.com>
Home Tenant       : <partner tenant name / ID if known>
Issue             : <describe: can't sign in / MFA loop / access denied / etc.>
Started           : <date/time when issue began>

Layers already checked:
[ ] Guest object exists and AccountEnabled = true
[ ] externalUserState = Accepted
[ ] CTAS inbound not blocked for home tenant
[ ] CA policies reviewed for guest user exceptions
[ ] Resource-level permissions verified (SharePoint, Teams, App Roles)

Error message (exact):
<paste AADSTS error code and description>

Evidence attached: ExternalIdentitiesEvidence_*.zip
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Find guest by email | `Get-MgUser -Filter "mail eq 'guest@domain.com' and userType eq 'Guest'"` |
| Check invitation state | `(Get-MgUser -UserId $id -Property ExternalUserState).ExternalUserState` |
| Re-send invitation | `New-MgInvitation -BodyParameter @{ invitedUserEmailAddress='...'; inviteRedirectUrl='https://myapps.microsoft.com'; sendInvitationMessage=$true }` |
| Enable/disable guest | `Update-MgUser -UserId $id -AccountEnabled $true/$false` |
| Guest group memberships | `Get-MgUserMemberOf -UserId $id` |
| Check CTAS for partner | `Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $tenantId` |
| Check CTAS defaults | `Get-MgPolicyCrossTenantAccessPolicyDefault` |
| Enable MFA trust (partner) | `Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerTenantId $id -BodyParameter @{ b2bCollaborationInbound = @{ trustSettings = @{ isMfaAccepted = $true } } }` |
| Find stale guests | `Get-MgUser -All -Filter "userType eq 'Guest'" -Property Id,Mail,SignInActivity` |
| Guest sign-in logs | `Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn'" -Top 20` |
| Check invite policy | `(Get-MgPolicyAuthorizationPolicy).AllowInvitesFrom` |
| Delete guest | `Remove-MgUser -UserId $id` |

---

## 🎓 Learning Pointers

- **The resource tenant controls access; the home tenant controls authentication.** When a guest can authenticate (reach home tenant login) but is denied access, the problem is in the resource tenant — CA policies, CTAS, or resource permissions. When the guest can't authenticate at all (AADSTS errors), the problem is likely the home tenant account state or CTAS blocking the home tenant.

- **CTAS replaced the old per-tenant trust settings and is now the authoritative policy.** The older "External Identities" settings in the portal are still relevant for invite policies and guest role, but CTAS governs cross-tenant trust for MFA, device compliance, and inbound/outbound collaboration blocking. If guests from a specific partner tenant are having consistent issues, CTAS tenant-specific rules are almost always involved. See: [Cross-tenant access overview](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-overview)

- **Email OTP guests have no home tenant CA enforcement.** If a guest authenticates via Email OTP (no Azure AD account), your resource tenant's CA policies are the only enforcement point. Consider requiring MFA (your MFA) for OTP guests and ensuring your MFA methods are configured to work for external users.

- **Access Reviews are a common cause of "sudden" guest access loss.** Entra ID Governance Access Reviews on groups or apps can auto-deny and remove guests if a reviewer doesn't explicitly approve them (or if no one reviews). If a guest loses access cyclically, check if Access Reviews are running against the groups or apps they need.

- **Changing a guest's email (mail attribute) in the resource tenant does NOT reroute authentication.** The guest's UPN suffix (`#EXT#@yourtenant.onmicrosoft.com`) is derived from the original invitation email. Changing the `mail` attribute changes display only — authentication still resolves against the original identity. To change the email used for auth, delete and re-invite.

- **The `SignInActivity` property is not populated in standard Get-MgUser calls.** Always explicitly request it: `Get-MgUser -UserId $id -Property Id,Mail,SignInActivity`. Without `-Property`, this attribute returns null and will mislead you into thinking the user has never signed in. See: [Get-MgUser Microsoft Graph reference](https://learn.microsoft.com/en-us/graph/api/user-get)
