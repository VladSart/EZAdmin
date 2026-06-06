# Entra ID External Identities (B2B/B2C) — Hotfix Runbook (Mode B: Ops)
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

Run these first to determine which layer is broken:

```powershell
# 1. Check if B2B collaboration is enabled tenant-wide
Connect-MgGraph -Scopes "Policy.Read.All"
Get-MgPolicyAuthorizationPolicy | Select-Object AllowInvitesFrom, AllowEmailVerifiedUsersToJoinOrganization

# 2. Check guest user state in directory
Get-MgUser -Filter "UserType eq 'Guest'" -Select "DisplayName,Mail,ExternalUserState,ExternalUserStateChangeDateTime,AccountEnabled" | Format-Table

# 3. Check Cross-Tenant Access Settings (affects inbound/outbound B2B)
Get-MgPolicyCrossTenantAccessPolicy | Format-List
Get-MgPolicyCrossTenantAccessPolicyDefault | Format-List

# 4. Check if specific guest account is blocked
$guestUPN = "guest_email#EXT#@<yourtenant>.onmicrosoft.com"
Get-MgUser -UserId $guestUPN -Property "AccountEnabled,ExternalUserState,SignInActivity" | Format-List

# 5. Check External Collaboration Settings
Get-MgPolicyAuthorizationPolicy | Select-Object -ExpandProperty DefaultUserRolePermissions
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| `AllowInvitesFrom` = `none` | Invitations globally disabled | → Fix 1 |
| Guest `ExternalUserState` = `PendingAcceptance` | Invite sent but not redeemed | → Fix 2 |
| Guest `AccountEnabled` = `False` | Account manually blocked | → Fix 3 |
| CrossTenantAccess blocks inbound | Partner org restricted | → Fix 4 |
| Guest gets AADSTS65005 / AADSTS50020 | App not configured for guest | → Fix 5 |
| Redemption loop / infinite redirect | B2B redemption config issue | → Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for B2B to work</summary>

```
Inviting Tenant
└── B2B Collaboration Enabled (AllowInvitesFrom policy)
    └── External Collaboration Settings allow domain/org
        └── Cross-Tenant Access Policy (inbound/outbound)
            └── Invitation email delivered to guest
                └── Guest redeems via redemption URL
                    └── Guest account created (UserType=Guest)
                        └── Conditional Access evaluated
                            |── MFA satisfied (via trust or prompt)
                            |── Device compliance (if required)
                            └── Terms of Use accepted (if required)
                                └── Resource access granted
                                    └── App registration allows guest users
                                        └── App role or group assignment
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm guest account exists and state**
```powershell
Get-MgUser -Filter "Mail eq '<guest@external.com>'" -Property "Id,DisplayName,UserPrincipalName,UserType,ExternalUserState,AccountEnabled" | Format-List
```
- Expected: `UserType = Guest`, `ExternalUserState = Accepted`, `AccountEnabled = True`
- Bad: `PendingAcceptance` = invite not redeemed; `AccountEnabled = False` = blocked

**Step 2 — Check sign-in logs for the guest**
```powershell
# Requires AuditLog.Read.All
$guestId = "<guest-object-id>"
Get-MgAuditLogSignIn -Filter "UserId eq '$guestId'" -Top 10 | Select-Object CreatedDateTime,AppDisplayName,Status,ConditionalAccessStatus | Format-Table
```
- Look for `errorCode` in Status — map to AADSTS error list

**Step 3 — Check Cross-Tenant Access Policy for partner tenant**
```powershell
# Find partner tenant ID first (from error logs or admin)
$partnerTenantId = "<partner-tenant-id>"
Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyConfigurationPartnerTenantId $partnerTenantId -ErrorAction SilentlyContinue
```
- No result = using default policy; result = check B2BCollaboration.InboundAllowed

**Step 4 — Validate app registration allows guest users**
```powershell
# Check app's signInAudience and guest settings
Get-MgApplication -Filter "DisplayName eq '<AppName>'" | Select-Object SignInAudience, @{N="GuestUserAccess";E={$_.Api.AcceptMappedClaims}}
```
- `AzureADMyOrg` with no guest exception = guests blocked at app level

**Step 5 — Check CA policies targeting guests**
```powershell
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.Conditions.Users.IncludeGuestsOrExternalUsers -ne $null } | Select-Object DisplayName,State | Format-Table
```
- Confirm no policy is blocking with unsatisfiable conditions (e.g., requiring compliant device with no guest device trust)

---
## Common Fix Paths

<details><summary>Fix 1 — Re-enable B2B collaboration / invitations</summary>

**Symptom:** Invitations cannot be sent, or error "Your organization has disabled external collaboration."

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.Authorization"

# Check current state
Get-MgPolicyAuthorizationPolicy | Select-Object AllowInvitesFrom

# Re-enable (options: adminsAndGuestInviters, adminsGuestInvitersAndAllMembers, everyone, none)
Update-MgPolicyAuthorizationPolicy -AllowInvitesFrom "adminsAndGuestInviters"

# Verify
Get-MgPolicyAuthorizationPolicy | Select-Object AllowInvitesFrom
```

**Rollback:** Change `AllowInvitesFrom` back to previous value.

> In Entra portal: External Identities → External collaboration settings → Guest invite settings

</details>

<details><summary>Fix 2 — Resend or reset a pending invitation</summary>

**Symptom:** Guest stuck in `PendingAcceptance`, original invite email expired or lost.

```powershell
Connect-MgGraph -Scopes "User.Invite.All"

# Option A: Resend via new invitation (idempotent — reuses existing guest object if exists)
$params = @{
    InvitedUserEmailAddress = "<guest@external.com>"
    InviteRedirectUrl       = "https://myapps.microsoft.com"
    SendInvitationMessage   = $true
    InvitedUserDisplayName  = "<Guest Display Name>"
}
New-MgInvitation @params

# Option B: Generate redemption URL without email
$params = @{
    InvitedUserEmailAddress = "<guest@external.com>"
    InviteRedirectUrl       = "https://myapps.microsoft.com"
    SendInvitationMessage   = $false
}
$result = New-MgInvitation @params
$result.InviteRedeemUrl  # Send this URL manually to the guest
```

**Note:** If the guest object is in an inconsistent state, delete and re-invite:
```powershell
$guestId = (Get-MgUser -Filter "Mail eq '<guest@external.com>'").Id
Remove-MgUser -UserId $guestId
# Then re-run New-MgInvitation above
```

</details>

<details><summary>Fix 3 — Re-enable a blocked guest account</summary>

**Symptom:** Guest `AccountEnabled = False`; error AADSTS50057 "The user account is disabled."

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All"

$guestId = (Get-MgUser -Filter "Mail eq '<guest@external.com>'").Id
Update-MgUser -UserId $guestId -AccountEnabled $true

# Confirm
Get-MgUser -UserId $guestId -Property "AccountEnabled" | Select-Object AccountEnabled
```

**Rollback:** `Update-MgUser -UserId $guestId -AccountEnabled $false`

</details>

<details><summary>Fix 4 — Fix Cross-Tenant Access Policy blocking guest</summary>

**Symptom:** Error AADSTS900439 or "Access blocked by your organization's cross-tenant access policy."

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.CrossTenantAccess"

$partnerTenantId = "<partner-tenant-id>"

# Check if a partner-specific config exists
$existing = Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyConfigurationPartnerTenantId $partnerTenantId -ErrorAction SilentlyContinue

if ($existing) {
    # Update existing partner config to allow B2B inbound
    $b2bSettings = @{
        usersAndGroups = @{ accessType = "allowed"; targets = @(@{ target = "AllUsers"; targetType = "user" }) }
        applications   = @{ accessType = "allowed"; targets = @(@{ target = "AllApplications"; targetType = "application" }) }
    }
    Update-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyConfigurationPartnerTenantId $partnerTenantId -B2bCollaborationInbound $b2bSettings
} else {
    # Create new partner config allowing inbound B2B
    $params = @{
        TenantId = $partnerTenantId
        B2bCollaborationInbound = @{
            usersAndGroups = @{ accessType = "allowed"; targets = @(@{ target = "AllUsers"; targetType = "user" }) }
            applications   = @{ accessType = "allowed"; targets = @(@{ target = "AllApplications"; targetType = "application" }) }
        }
    }
    New-MgPolicyCrossTenantAccessPolicyPartner @params
}
```

**Rollback:** Remove the partner-specific config; the default policy will apply:
```powershell
Remove-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyConfigurationPartnerTenantId $partnerTenantId
```

</details>

<details><summary>Fix 5 — App not allowing guest sign-in</summary>

**Symptom:** Guest gets AADSTS65005 ("Invalid resource"), AADSTS50020 ("User account does not exist in tenant"), or access denied at app level.

In **Entra portal**: App Registrations → [App] → Authentication → Supported account types

For **multi-tenant apps**: ensure `signInAudience` is `AzureADandPersonalMicrosoftAccount` or `AzureADMultipleOrgs`, not `AzureADMyOrg` unless guest user assignment is explicitly allowed.

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All"

$appId = "<application-client-id>"
$app = Get-MgApplication -Filter "AppId eq '$appId'"

# Check current audience
$app.SignInAudience

# If app must stay single-tenant, add guest via direct assignment instead:
# Enterprise Applications → [App] → Users and Groups → Add guest user
```

**Alternative — assign guest to app directly:**
```powershell
$servicePrincipalId = (Get-MgServicePrincipal -Filter "AppId eq '$appId'").Id
$guestId = (Get-MgUser -Filter "Mail eq '<guest@external.com>'").Id

New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $servicePrincipalId -BodyParameter @{
    PrincipalId = $guestId
    ResourceId  = $servicePrincipalId
    AppRoleId   = "00000000-0000-0000-0000-000000000000"  # Default role
}
```

</details>

<details><summary>Fix 6 — Redemption loop / guest stuck in redirect</summary>

**Symptom:** Guest clicks invitation link, gets redirected back to redemption page repeatedly; AADSTS75011 or AADSTS50126.

Common causes:
1. Guest's home tenant has conditional access blocking the redemption
2. Guest's email domain is on tenant's blocked list
3. Redemption URL has expired (>30 days for some scenarios)

```powershell
# Check if guest's domain is blocked
Connect-MgGraph -Scopes "Policy.Read.All"
$policy = Get-MgPolicyAuthorizationPolicy
$policy.AllowedToInviteExternalUsers  # If false, guests from all domains blocked

# Check domain allow/block list
# Entra portal: External Identities → External collaboration settings → Collaboration restrictions

# Force fresh redemption URL
Connect-MgGraph -Scopes "User.Invite.All"
$result = New-MgInvitation -InvitedUserEmailAddress "<guest@external.com>" `
    -InviteRedirectUrl "https://myapps.microsoft.com" `
    -SendInvitationMessage $false `
    -ResetRedemption $true  # Forces new redemption even if already accepted
$result.InviteRedeemUrl
```

**Note:** `ResetRedemption = $true` resets the guest's redemption state — they must re-accept. Use only when directed by the guest that they are looping.

</details>

---
## Escalation Evidence

```
ESCALATION TICKET — Entra ID External Identities / B2B
================================================
Date/Time:          _______________
Reported by:        _______________
Guest email:        _______________
Guest UPN (EXT):    _______________
Guest object ID:    _______________
Inviting tenant ID: _______________
Guest home tenant:  _______________

Symptom:            _______________
Error code (AADSTS):_______________
Error message:      _______________

Triage results:
  AllowInvitesFrom:            _______________
  ExternalUserState:           _______________
  AccountEnabled:              _______________
  CrossTenantAccess (default): Inbound B2B = _______________
  CrossTenantAccess (partner): _______________
  CA policies affecting guests:_______________
  App SignInAudience:          _______________

Sign-in log correlation ID: _______________
Sign-in log request ID:     _______________

Steps already taken:        _______________
Escalating to:              _______________
```

---
## 🎓 Learning Pointers

- **B2B vs B2C are separate systems.** B2B (guest collaboration) lives in your own tenant; Azure AD B2C is a separate tenant type for customer-facing apps. Don't conflate them — misconfiguring one won't fix the other. [B2B overview](https://learn.microsoft.com/en-us/entra/external-id/what-is-b2b)
- **Cross-Tenant Access Policies replaced the old "allow/block list."** If you're troubleshooting a new tenant (post-2022) and the old block list approach isn't working, check Cross-Tenant Access — it takes precedence. [XTAP docs](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-overview)
- **Guest redemption URLs expire after 90 days** for invitations not yet redeemed. After that, the guest must be re-invited. `ResetRedemption` lets you force a new invite for an existing guest object.
- **Conditional Access MFA for guests requires trust or on-the-spot prompt.** If your CA requires MFA and you haven't configured MFA trust from the guest's home tenant (via XTAP), the guest needs to register MFA in your tenant. Many guest issues are CA-related, not B2B config. [MFA for guests](https://learn.microsoft.com/en-us/entra/external-id/b2b-tutorial-require-mfa)
- **AADSTS error codes are your friend.** Every B2B failure produces an AADSTS code in sign-in logs. Always capture it. [Full error code list](https://learn.microsoft.com/en-us/entra/identity-platform/reference-error-codes)
- **Guest Access Restrictions in Microsoft 365** (Entra External Collaboration Settings → Guest user access) control what guests can enumerate in the directory — separate from whether they can sign in. A guest who can sign in but "can't see anything" is usually hitting this.
