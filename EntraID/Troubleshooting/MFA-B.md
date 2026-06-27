# Entra ID MFA — Hotfix Runbook (Mode B: Ops)
> Fix or escalate MFA issues in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Run these first. Paste output when escalating.

```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All","Policy.Read.All","AuditLog.Read.All" -NoWelcome

# Target user
$UPN = "<user@domain.com>"

# 1. Check user's registered auth methods
Get-MgUserAuthenticationMethod -UserId $UPN | Select-Object Id, AdditionalProperties

# 2. Check per-user MFA state (legacy)
# Note: Per-user MFA is being deprecated in favour of CA-based MFA
$uri = "https://graph.microsoft.com/beta/users/$UPN/authentication/requirements"
Invoke-MgGraphRequest -Method GET -Uri $uri | ConvertTo-Json

# 3. Pull last 10 sign-ins for the user
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$UPN'" -Top 10 |
    Select-Object CreatedDateTime, AppDisplayName, Status, MfaDetail, ConditionalAccessStatus |
    Format-Table -AutoSize
```

**Interpretation:**

| Finding | Action |
|---------|--------|
| No auth methods registered | User needs MFA registration — send registration URL |
| `perUserMfaState: enforced` with no registered method | Force registration: disable per-user MFA temporarily or enrol via TAP |
| Sign-in shows `MfaDetail: None` but CA requires MFA | CA policy not evaluated — check assignment/exclusions |
| Sign-in shows `Status: Failure - MFA required` | MFA not satisfied — check registered methods & auth app |
| Sign-in shows `ConditionalAccessStatus: NotApplied` | User excluded from all CA policies |

---

## Dependency Cascade

<details><summary>What must be true for MFA to work</summary>

```
User Account (Entra ID)
  └── Licensed (P1/P2 for CA-based MFA; Free supports Security Defaults)
        └── Not excluded from MFA Conditional Access policies
              └── Has registered at least one MFA method
                    ├── Microsoft Authenticator (push/TOTP)
                    ├── TOTP hardware token / FIDO2 key
                    ├── Phone (SMS/call) — if allowed by auth methods policy
                    └── Temporary Access Pass (TAP) — for bootstrap scenarios
                          └── Authentication Methods Policy allows the method
                                └── CA policy requires MFA (or Security Defaults enabled)
```

**Key interlock:** Auth Methods Policy (tenant-wide) controls what methods CAN be used. CA policy controls WHEN MFA is required. Both must be configured correctly.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm how MFA is being enforced in the tenant**
```powershell
# Option A: Security Defaults (no P1 licence needed)
$secDefaults = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy"
Write-Host "Security Defaults enabled: $($secDefaults.isEnabled)"

# Option B: CA policies requiring MFA
Get-MgIdentityConditionalAccessPolicy |
    Where-Object { $_.GrantControls.BuiltInControls -contains "mfa" -and $_.State -eq "enabled" } |
    Select-Object DisplayName, State, @{N="IncludeUsers";E={$_.Conditions.Users.IncludeUsers}} |
    Format-Table -AutoSize
```
Expected: Either Security Defaults = True OR at least one CA policy requires MFA
Bad: Neither — MFA not enforced at all (check if per-user MFA is the only mechanism)

---

**Step 2 — Check user's registered authentication methods**
```powershell
$UPN = "<user@domain.com>"
$methods = Get-MgUserAuthenticationMethod -UserId $UPN
$methods | ForEach-Object {
    $type = $_.AdditionalProperties["@odata.type"]
    Write-Host "Method: $type" -ForegroundColor Cyan
    $_.AdditionalProperties | ConvertTo-Json
}
```
Expected: At least one second factor registered (e.g., `#microsoft.graph.microsoftAuthenticatorAuthenticationMethod`)
Bad: Only `passwordAuthenticationMethod` — no MFA method registered

---

**Step 3 — Check if the user's method is allowed by policy**
```powershell
# Get Authentication Methods Policy
$policy = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy"
$policy.authenticationMethodConfigurations | ForEach-Object {
    Write-Host "$($_.id): $($_.state)" -ForegroundColor $(if ($_.state -eq "enabled") {"Green"} else {"Yellow"})
}
```
Expected: The method the user registered (e.g., MicrosoftAuthenticator) shows `enabled`
Bad: Method is `disabled` — user can't use it even if registered

---

**Step 4 — Check sign-in logs for MFA failure detail**
```powershell
$UPN = "<user@domain.com>"
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$UPN' and createdDateTime gt $(
    (Get-Date).AddHours(-24).ToString('yyyy-MM-ddTHH:mm:ssZ')
)" -Top 20 |
    Select-Object CreatedDateTime, AppDisplayName, 
        @{N="Error";E={$_.Status.ErrorCode}},
        @{N="Reason";E={$_.Status.FailureReason}},
        @{N="MFA";E={$_.MfaDetail}},
        @{N="Location";E={"$($_.Location.City), $($_.Location.CountryOrRegion)"}} |
    Format-Table -AutoSize
```
Error codes to know:
- `50074` — MFA required but user hasn't completed it
- `50076` — MFA required by CA policy (interactive prompt expected)
- `50158` — External security challenge required (third-party MFA)
- `53004` — User must register for MFA before accessing this resource
- `500121` — Incorrect second factor — wrong code entered

---

**Step 5 — Check if CA policy is actually targeting this user**
```powershell
$UPN = "<user@domain.com>"
$userId = (Get-MgUser -UserId $UPN).Id
$userGroups = (Get-MgUserMemberOf -UserId $UPN).Id

# Get all enabled CA policies requiring MFA
Get-MgIdentityConditionalAccessPolicy |
    Where-Object { $_.State -eq "enabled" -and $_.GrantControls.BuiltInControls -contains "mfa" } |
    ForEach-Object {
        $includeAll = $_.Conditions.Users.IncludeUsers -contains "All"
        $excluded = ($_.Conditions.Users.ExcludeUsers -contains $userId) -or
                    ($_.Conditions.Users.ExcludeGroups | Where-Object { $userGroups -contains $_ })
        Write-Host "Policy: $($_.DisplayName)" -ForegroundColor Cyan
        Write-Host "  Includes All: $includeAll | User excluded: $($excluded -ne $null)"
    }
```

---

## Common Fix Paths

<details><summary>Fix 1 — User has no MFA method registered (needs enrolment)</summary>

**Cause:** User never completed MFA registration, or device was replaced.

**Option A — Issue a Temporary Access Pass (TAP) so user can register**
```powershell
$UPN = "<user@domain.com>"

# Check TAP is enabled in auth methods policy first
$tapConfig = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass"
Write-Host "TAP enabled: $($tapConfig.state)"

# Create a TAP (1-hour, one-time use)
$body = @{
    lifetimeInMinutes = 60
    isUsableOnce      = $true
} | ConvertTo-Json

$tap = Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/users/$UPN/authentication/temporaryAccessPassMethods" `
    -Body $body -ContentType "application/json"

Write-Host "TAP created: $($tap.temporaryAccessPass)" -ForegroundColor Green
Write-Host "Valid until: $($tap.startDateTime) + $($tap.lifetimeInMinutes) min"
Write-Host "Give user this URL: https://aka.ms/mysecurityinfo"
```

**Option B — Send MFA registration URL to user**
```
https://aka.ms/mysecurityinfo
```
User visits this URL, signs in, and registers their preferred method.

**Rollback:** None needed — TAPs expire automatically.

</details>

<details><summary>Fix 2 — User's Authenticator app not working / lost phone</summary>

**Cause:** New phone, deleted app, or push notification failures.

```powershell
$UPN = "<user@domain.com>"

# List current authenticator registrations
$methods = Get-MgUserAuthenticationMethod -UserId $UPN
$methods | Where-Object { $_.AdditionalProperties["@odata.type"] -match "microsoftAuthenticator" } |
    ForEach-Object {
        Write-Host "Device: $($_.AdditionalProperties.displayName)" -ForegroundColor Yellow
        Write-Host "Method ID: $($_.Id)"
    }

# Remove the broken authenticator method (user must re-register after)
$methodId = "<paste method ID from above>"
Remove-MgUserAuthenticationMethod -UserId $UPN -AuthenticationMethodId $methodId

# Issue a TAP so user can re-register
$body = @{
    lifetimeInMinutes = 60
    isUsableOnce      = $true
} | ConvertTo-Json
$tap = Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/users/$UPN/authentication/temporaryAccessPassMethods" `
    -Body $body -ContentType "application/json"

Write-Host "TAP: $($tap.temporaryAccessPass) — Send user to https://aka.ms/mysecurityinfo" -ForegroundColor Green
```

**Rollback:** Cannot un-delete a removed method. User must re-register.

</details>

<details><summary>Fix 3 — User excluded from all MFA CA policies (should not be)</summary>

**Cause:** User was put in an exclusion group during an incident and not removed.

```powershell
# Find CA exclusion groups containing the user
$UPN = "<user@domain.com>"
$userId = (Get-MgUser -UserId $UPN).Id

Get-MgIdentityConditionalAccessPolicy |
    Where-Object { $_.State -eq "enabled" } |
    ForEach-Object {
        $policy = $_
        $policy.Conditions.Users.ExcludeGroups | ForEach-Object {
            $groupId = $_
            $members = Get-MgGroupMember -GroupId $groupId
            if ($members.Id -contains $userId) {
                $groupName = (Get-MgGroup -GroupId $groupId).DisplayName
                Write-Host "User is in exclusion group '$groupName' for policy '$($policy.DisplayName)'" -ForegroundColor Red
                Write-Host "Group ID: $groupId"
            }
        }
    }

# Remove user from exclusion group
$groupId = "<ExclusionGroupId>"
Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $userId
Write-Host "User removed from exclusion group. MFA will be enforced on next sign-in." -ForegroundColor Green
```

**Rollback:** Add user back to exclusion group:
```powershell
New-MgGroupMember -GroupId $groupId -DirectoryObjectId $userId
```

</details>

<details><summary>Fix 4 — Per-user MFA state causing conflict (legacy enforcement)</summary>

**Cause:** Per-user MFA is enabled but conflicts with CA-based MFA, causing double prompts or failures.

```powershell
# Check per-user MFA state
$UPN = "<user@domain.com>"
$uri = "https://graph.microsoft.com/beta/users/$UPN/authentication/requirements"
$result = Invoke-MgGraphRequest -Method GET -Uri $uri
Write-Host "Per-user MFA state: $($result.perUserMfaState)"

# Disable per-user MFA (use CA policies instead)
$body = @{ perUserMfaState = "disabled" } | ConvertTo-Json
Invoke-MgGraphRequest -Method PATCH -Uri $uri -Body $body -ContentType "application/json"
Write-Host "Per-user MFA disabled. CA policy will now control MFA enforcement." -ForegroundColor Green
```

**Important:** Only disable per-user MFA if a CA policy already enforces MFA for this user. Verify CA coverage before disabling.

**Rollback:**
```powershell
$body = @{ perUserMfaState = "enforced" } | ConvertTo-Json
Invoke-MgGraphRequest -Method PATCH -Uri $uri -Body $body -ContentType "application/json"
```

</details>

---

## Escalation Evidence

```
=== MFA ISSUE ESCALATION ===
Date/Time (UTC):        ____________________
Reported by:            ____________________
Affected UPN:           ____________________
Tenant ID:              ____________________
Issue description:      ____________________

=== CHECKS COMPLETED ===
[ ] Security Defaults enabled:          YES / NO
[ ] CA policy requiring MFA exists:     YES / NO  Policy name: ____________________
[ ] User excluded from CA policy:       YES / NO  Exclusion group: ________________
[ ] Auth methods registered:            YES / NO  Methods: _______________________
[ ] Auth method allowed by policy:      YES / NO
[ ] Per-user MFA state:                 ENABLED / ENFORCED / DISABLED
[ ] Last sign-in error code:            ____________________
[ ] Last sign-in failure reason:        ____________________

=== ACTIONS TAKEN ===
[ ] TAP issued (valid until):           ____________________
[ ] Auth method removed for re-reg:     YES / NO
[ ] Removed from exclusion group:       YES / NO

=== ESCALATION PATH ===
If issue persists after above steps:
- Entra ID P2 tenant: open case via https://admin.microsoft.com
- Provide: UPN, Tenant ID, exact error code, timestamp of failed sign-in
- Request: Sign-in log deep trace for the specific authentication event
```

---

## 🎓 Learning Pointers

- **TAP is the modern MFA bootstrap tool**: Temporary Access Pass lets a user sign in without MFA to register their first MFA method. This replaces the old workaround of temporarily disabling MFA for the account. TAPs can be single-use, time-limited, and are logged. See: [Temporary Access Pass](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-authentication-temporary-access-pass)

- **Per-user MFA vs. CA-based MFA**: Legacy per-user MFA (`enforced` state) predates Conditional Access. Microsoft is deprecating it. In tenants with P1+ licences, use CA policies for MFA enforcement. Mixed environments (some per-user, some CA) cause confusing double-prompts and "already satisfied" errors. Migrate to CA-only. See: [Migrate from per-user MFA](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-mfa-userstates)

- **Auth Methods Policy is the gatekeeper**: Even if a user registered a phone number for SMS MFA, if `Voice` and `SMS` are disabled in the Authentication Methods Policy, they can't use it. This catches admins off-guard when migrating from SMS to Authenticator — the SMS method may still be registered but disabled at policy level. See: [Authentication methods policy](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-methods)

- **Sign-in error code 50074 vs. 50076**: Error `50074` means MFA was required but the user didn't have a method registered. Error `50076` means MFA was required by CA and the user needs to complete the MFA challenge (expected, interactive flow). These look similar but have different fixes. Always check the exact error code in sign-in logs.
