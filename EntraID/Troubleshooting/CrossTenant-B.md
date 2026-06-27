# Entra ID Cross-Tenant Access — Hotfix Runbook (Mode B: Ops)
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

Run these in PowerShell (connect as Global Admin or Security Admin):

```powershell
# 1. Check current cross-tenant access default settings
Connect-MgGraph -Scopes "Policy.Read.All"
$xtas = Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/v1.0/policies/crossTenantAccessPolicy"
$xtas | ConvertTo-Json -Depth 5

# 2. List all partner-specific cross-tenant settings (org-to-org overrides)
$partners = Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/v1.0/policies/crossTenantAccessPolicy/partners"
$partners.value | Select-Object tenantId, displayName | Format-Table

# 3. Check if guest user can sign in — look at sign-in logs for cross-tenant failures
Get-MgAuditLogSignIn -Filter "crossTenantAccessType ne 'none' and status/errorCode ne 0" `
  -Top 20 | Select-Object CreatedDateTime, UserPrincipalName, Status, CrossTenantAccessType | 
  Format-Table -AutoSize

# 4. Check B2B collaboration default settings (inbound)
$inbound = Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/v1.0/policies/crossTenantAccessPolicy/default"
$inbound.b2bCollaborationInbound | ConvertTo-Json

# 5. Check Conditional Access policies targeting external guests
Get-MgIdentityConditionalAccessPolicy | Where-Object {
  $_.Conditions.Users.IncludeGuestsOrExternalUsers -ne $null -or
  $_.Conditions.Users.ExcludeGuestsOrExternalUsers -ne $null
} | Select-Object DisplayName, State | Format-Table
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| `b2bCollaborationInbound.usersAndGroups.accessType = blocked` | Inbound B2B blocked by default | Fix 1 — open inbound |
| Partner entry missing for external tenant | No org-level override configured | Fix 2 — add partner config |
| Sign-in error 65001 | User hasn't consented to guest permissions | Fix 3 — admin consent |
| Sign-in error 90072 | User's home tenant has blocked outbound | External admin must fix their outbound settings |
| Sign-in error 53003 | Conditional Access blocking external user | Fix 4 — check CA policy |
| Sign-in error 50076 | MFA required but external MFA not trusted | Fix 5 — configure MFA trust |

---
## Dependency Cascade

<details><summary>What must be true for cross-tenant access to work</summary>

```
External User Accesses Resource in Your Tenant
    │
    ├── Home tenant (theirs) — OUTBOUND settings
    │       └── Must allow outbound B2B collaboration to your tenant
    │               (if blocked there, you cannot fix it — their admin must)
    │
    └── Resource tenant (yours) — INBOUND settings
            ├── Default inbound policy (applies to all external tenants)
            │       └── B2B collaboration: usersAndGroups.accessType = allowed
            │
            ├── Partner-specific override (per external tenant, overrides default)
            │       └── Optional: more permissive or restrictive than default
            │
            ├── MFA trust settings
            │       └── If trusting external MFA: users won't be re-prompted in your tenant
            │
            ├── Device compliance trust
            │       └── Optional: trust external tenant's Intune compliance claims
            │
            └── Conditional Access policies
                    └── Policies targeting GuestsOrExternalUsers apply here
                            └── Must not block the external user's scenario
```

**Who controls what:**
| Setting | Controlled by |
|---------|--------------|
| Can external users be invited? | Your tenant (inbound B2B) |
| Can your users be guests elsewhere? | Your tenant (outbound B2B) |
| Which external users can sign in | Your tenant's CA + inbound XTAS |
| Whether external users need MFA in your tenant | Your tenant (MFA trust setting) |
| Whether external users can even start the flow | External user's home tenant outbound settings |

</details>

---
## Diagnosis & Validation Flow

1. **Identify the error code from the user's failed sign-in**
   - Ask user: exact error message and correlation ID
   - Or pull from Entra sign-in logs: Entra Portal → Monitoring → Sign-in logs → filter by user UPN
   - Filter: `Cross-tenant access type` ≠ None → shows all external/inbound sign-ins

2. **Identify the external tenant involved**
   ```powershell
   # Look up tenant ID from a known UPN (e.g., user@externaldomain.com)
   $domain = "externaldomain.com"
   $result = Invoke-WebRequest -Uri "https://login.microsoftonline.com/$domain/.well-known/openid-configuration" | 
     ConvertFrom-Json
   $result.issuer  # Contains the tenant ID
   ```

3. **Check if partner-specific settings exist for that tenant**
   ```powershell
   $externalTenantId = "<guid-of-external-tenant>"
   $partner = Invoke-MgGraphRequest -Method GET `
     -Uri "https://graph.microsoft.com/v1.0/policies/crossTenantAccessPolicy/partners/$externalTenantId" `
     -ErrorAction SilentlyContinue
   $partner | ConvertTo-Json -Depth 5
   ```
   If 404 → no partner entry exists; default policy applies.

4. **Check default inbound policy**
   ```powershell
   $default = Invoke-MgGraphRequest -Method GET `
     -Uri "https://graph.microsoft.com/v1.0/policies/crossTenantAccessPolicy/default"
   # Key fields:
   $default.b2bCollaborationInbound.usersAndGroups.accessType  # should be 'allowed'
   $default.b2bCollaborationInbound.applications.accessType     # should be 'allowed' or specific apps
   $default.inboundTrust.isMfaAccepted                          # true = trust external MFA
   ```

5. **Check if a CA policy is blocking**
   - Entra Portal → Sign-in logs → click the failed sign-in → Conditional Access tab
   - Look for any policy showing `Failure` status

---
## Common Fix Paths

<details><summary>Fix 1 — Default inbound B2B blocked — open access for external guests</summary>

**Symptoms:** All external users from any tenant are blocked. No partner entry exists. Error 500121 or sign-in rejected before authentication.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.CrossTenantAccess"

$body = @{
  b2bCollaborationInbound = @{
    usersAndGroups = @{
      accessType = "allowed"
      targets = @(
        @{ target = "AllExternalUsers"; targetType = "user" }
      )
    }
    applications = @{
      accessType = "allowed"
      targets = @(
        @{ target = "Office365"; targetType = "application" }
      )
    }
  }
} | ConvertTo-Json -Depth 5

Invoke-MgGraphRequest -Method PATCH `
  -Uri "https://graph.microsoft.com/v1.0/policies/crossTenantAccessPolicy/default" `
  -Body $body `
  -ContentType "application/json"
```

**Portal path:** Entra → External Identities → Cross-tenant access settings → Default settings → Inbound access → B2B collaboration → Edit → Allow access

**Rollback:**
```powershell
# Re-set to blocked
$body = @{ b2bCollaborationInbound = @{ usersAndGroups = @{ accessType = "blocked" } } } | ConvertTo-Json -Depth 5
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/policies/crossTenantAccessPolicy/default" -Body $body -ContentType "application/json"
```

</details>

<details><summary>Fix 2 — Add partner-specific settings for a trusted external tenant</summary>

**Use case:** You want more permissive (or restrictive) settings for a specific partner org than your default allows.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.CrossTenantAccess"

$partnerTenantId = "<external-tenant-guid>"

$body = @{
  tenantId = $partnerTenantId
  b2bCollaborationInbound = @{
    usersAndGroups = @{
      accessType = "allowed"
      targets = @(@{ target = "AllExternalUsers"; targetType = "user" })
    }
    applications = @{
      accessType = "allowed"
      targets = @(@{ target = "AllApplications"; targetType = "application" })
    }
  }
  inboundTrust = @{
    isMfaAccepted = $true          # Trust their MFA — users won't be re-prompted
    isCompliantDeviceAccepted = $false
    isHybridAzureADJoinedDeviceAccepted = $false
  }
} | ConvertTo-Json -Depth 6

Invoke-MgGraphRequest -Method POST `
  -Uri "https://graph.microsoft.com/v1.0/policies/crossTenantAccessPolicy/partners" `
  -Body $body `
  -ContentType "application/json"

Write-Host "Partner entry created for tenant: $partnerTenantId"
```

**Portal path:** Entra → External Identities → Cross-tenant access settings → Organizational settings → Add organization → enter tenant domain → configure inbound/outbound

**Rollback:**
```powershell
Invoke-MgGraphRequest -Method DELETE `
  -Uri "https://graph.microsoft.com/v1.0/policies/crossTenantAccessPolicy/partners/$partnerTenantId"
```

</details>

<details><summary>Fix 3 — External user has error 65001 (needs admin consent)</summary>

**Symptoms:** User can authenticate but gets error 65001 "Need admin approval" for your application.

**Cause:** The application requires permissions that the guest user cannot self-consent to.

```powershell
# Option A: Grant admin consent for the specific application
# Portal: Entra → App Registrations → [app] → API Permissions → Grant admin consent

# Option B: Enable user consent for low-risk permissions
# Portal: Entra → Enterprise Applications → Consent and permissions → User consent settings

# Option C: Configure admin consent workflow so guests can request access
# Portal: Entra → Enterprise Applications → Consent and permissions → Admin consent workflow → Enable

# Option D: Pre-consent the app for the external tenant via partner settings
$partnerTenantId = "<external-tenant-guid>"
$appId = "<your-app-client-id>"

$body = @{
  b2bCollaborationInbound = @{
    applications = @{
      accessType = "allowed"
      targets = @(@{ target = $appId; targetType = "application" })
    }
  }
} | ConvertTo-Json -Depth 5

Invoke-MgGraphRequest -Method PATCH `
  -Uri "https://graph.microsoft.com/v1.0/policies/crossTenantAccessPolicy/partners/$partnerTenantId" `
  -Body $body -ContentType "application/json"
```

**Rollback:** Revoke admin consent from the application's API Permissions page.

</details>

<details><summary>Fix 4 — Conditional Access blocking external user</summary>

**Symptoms:** Sign-in logs show CA policy failure for an external/guest user. Error 53003.

```powershell
# Find CA policies that apply to external users
Get-MgIdentityConditionalAccessPolicy | ForEach-Object {
  $p = $_
  $targets = $p.Conditions.Users
  if ($targets.IncludeGuestsOrExternalUsers -or $targets.IncludeUsers -contains "GuestsOrExternalUsers") {
    [PSCustomObject]@{
      Name    = $p.DisplayName
      State   = $p.State
      GrantControls = $p.GrantControls.BuiltInControls -join ", "
    }
  }
} | Format-Table -AutoSize
```

**Quick fix options:**
1. Exclude the guest user's UPN from the blocking CA policy (temporary)
2. Create an exclusion group for trusted external partner users → add to CA exclusion
3. Modify the CA policy to scope only to specific guest types (B2B Collaboration vs B2B Direct Connect)

**Portal:** Entra → Security → Conditional Access → [policy] → Users → Exclude → [guest user or group]

**Rollback:** Remove the exclusion.

</details>

<details><summary>Fix 5 — External user prompted for MFA every session (trust their MFA)</summary>

**Symptoms:** Partner org uses MFA, but guests are re-prompted for MFA in your tenant every time. Error 50076 or user complaint about repeated MFA.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.CrossTenantAccess"

$partnerTenantId = "<external-tenant-guid>"

# Update or create partner entry with MFA trust
$body = @{
  inboundTrust = @{
    isMfaAccepted = $true
  }
} | ConvertTo-Json -Depth 3

# If partner entry exists:
Invoke-MgGraphRequest -Method PATCH `
  -Uri "https://graph.microsoft.com/v1.0/policies/crossTenantAccessPolicy/partners/$partnerTenantId" `
  -Body $body -ContentType "application/json"

Write-Host "MFA trust enabled for partner: $partnerTenantId"
```

**Portal:** Entra → External Identities → Cross-tenant access settings → [org] → Inbound access → Trust settings → Trust multi-factor authentication from Microsoft Entra tenants

**Important:** Only trust MFA from tenants you control or have verified security posture for. Trusting MFA from unknown tenants reduces your security.

**Rollback:**
```powershell
$body = @{ inboundTrust = @{ isMfaAccepted = $false } } | ConvertTo-Json -Depth 3
Invoke-MgGraphRequest -Method PATCH -Uri ".../partners/$partnerTenantId" -Body $body -ContentType "application/json"
```

</details>

---
## Escalation Evidence

```
=== Cross-Tenant Access Escalation Pack ===
Date/Time:                
Your Tenant ID:           
External Tenant ID:       
External User UPN:        
Error Code:               
Correlation ID (from sign-in logs): 

Cross-Tenant Access Type shown in logs:
  [ ] B2B Collaboration
  [ ] B2B Direct Connect
  [ ] Microsoft Support
  [ ] Service Provider

Current default inbound setting:
  usersAndGroups.accessType:    
  applications.accessType:      
  isMfaAccepted:                

Partner-specific entry exists (Y/N):  
  If Y — inbound.accessType:    
  If Y — isMfaAccepted:         

CA policy blocking (Y/N):       
  If Y — Policy name:           

Error description from user:
  [paste exact error message or screenshot URL]

Steps already tried:
  [ ] Checked default inbound settings
  [ ] Checked partner entry
  [ ] Checked sign-in logs (error code confirmed)
  [ ] Checked CA policies
  [ ] Verified external tenant outbound settings (ask their admin)
```

---
## 🎓 Learning Pointers

- **XTAS has inbound AND outbound.** Inbound governs who can come into your tenant. Outbound governs where your users can go as guests. Both tenants must allow the flow — if the external tenant blocks outbound B2B to your domain, there's nothing you can do on your side. The error code `90072` means the home tenant blocked the outbound — their admin must fix it.

- **Partner entries override defaults.** The default policy applies to all external tenants that don't have a partner entry. A partner entry completely overrides (not merges with) the default for that specific tenant. Plan your defaults conservatively and use partner entries to selectively open trusted orgs.

- **MFA trust ≠ skip MFA.** Trusting external MFA means you accept the external tenant's MFA claim — the user still did MFA at their home tenant. You're choosing to honor their assertion rather than forcing a second MFA challenge. It's a trust decision, not a security bypass.

- **Cross-tenant access settings apply to B2B Collaboration AND B2B Direct Connect (Teams Connect) separately.** Check which type your scenario involves — a Teams Shared Channel uses B2B Direct Connect, not B2B Collaboration. They have separate configuration sections. See: [Microsoft Cross-tenant access overview](https://learn.microsoft.com/en-us/entra/external-id/cross-tenant-access-overview)

- **Sign-in log filtering.** Entra sign-in logs let you filter by `Cross-tenant access type` — use this to instantly isolate all external/inbound authentication events without scrolling through millions of internal sign-ins. The `Correlation ID` from the error screen is your fastest path to the exact failed sign-in event.

- **Tenant ID lookup.** You can find any Microsoft tenant's ID from their domain using the OpenID Connect metadata endpoint: `https://login.microsoftonline.com/<domain>/.well-known/openid-configuration` — the `issuer` field contains the tenant ID. This is public and requires no authentication.
