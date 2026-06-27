# Entra ID MFA — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the full MFA stack, token claims, and CA integration.

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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

- Applies to Microsoft Entra ID (formerly Azure AD) MFA in cloud and hybrid environments
- Covers all enforcement models: Security Defaults, Conditional Access, per-user MFA (legacy)
- Covers authentication methods: Microsoft Authenticator, TOTP, FIDO2, SMS/voice, TAP, certificate-based
- Does **not** cover on-premises MFA Server (deprecated by Microsoft)
- Assumes Entra ID P1 or higher for Conditional Access features
- MFA registration portal: `https://aka.ms/mysecurityinfo`

---

## How It Works

<details><summary>Full architecture — MFA in the Entra ID authentication pipeline</summary>

MFA in Entra ID is not a single feature — it is a **signal evaluated by the token issuance pipeline** after primary authentication (password, certificate, FIDO2 passwordless).

### Authentication Flow

```
User initiates sign-in to App/Service
        │
        ▼
[Entra ID STS (Security Token Service)]
  ├── Evaluates identity: username + primary factor (password, cert, FIDO2)
  ├── Evaluates Conditional Access policies (if P1+):
  │     - Is MFA required for this user + app + location + device?
  │     - If YES: issue "interaction required" response
  └── OR evaluates Security Defaults / per-user MFA state (no P1)
        │
        ▼ (if MFA required)
[MFA Challenge]
  User is redirected to Microsoft's MFA service
  ├── Push notification → Microsoft Authenticator app
  ├── TOTP code → Authenticator / hardware token
  ├── SMS/voice OTP (if enabled in Auth Methods Policy)
  ├── FIDO2 security key
  ├── Windows Hello for Business (satisfies MFA via device-bound credential)
  └── Temporary Access Pass (for registration scenarios only)
        │
        ▼ (MFA satisfied)
[Token issued with claims]
  - amr (Authentication Method Reference): ["pwd", "mfa"]
  - acr (Authentication Context): often "urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport"
  - auth_time: timestamp of last authentication
        │
        ▼
[App receives ID token + Access token]
  App may inspect acr/amr claims to verify MFA was completed
```

### MFA Enforcement Models

| Model | Requires | Scope | Recommended? |
|-------|----------|-------|-------------|
| **Security Defaults** | Free tier | All users, all apps | Yes, for small orgs without P1 |
| **Conditional Access** | P1+ | Granular: user/group/app/location/device | Yes, for all P1+ tenants |
| **Per-user MFA (legacy)** | Free/P1 | Per user account | No — being deprecated |
| **Authentication Strength** | P1+ | Specific method combinations per CA policy | Best practice for sensitive apps |

### Authentication Methods Policy
Controls which second factors are available in the tenant:

```
Authentication Methods Policy (tenant-wide)
  ├── Microsoft Authenticator
  │     ├── Push notifications (passwordless + MFA)
  │     └── TOTP (time-based one-time password)
  ├── FIDO2 Security Keys
  ├── Temporary Access Pass (TAP)
  ├── Software OATH tokens
  ├── Hardware OATH tokens
  ├── SMS (OTP via text)
  ├── Voice calls
  ├── Certificate-based authentication (CBA)
  └── Email OTP (for B2B guests only)
```

Each method can be enabled for **All users** or **selected groups**, with configurable parameters.

### Authentication Strength (Entra ID P1)
Authentication Strength policies let CA policies require **specific** method combinations rather than just "any MFA":

```
CA Policy → Grant → Require authentication strength → [custom or built-in strength]

Built-in strengths:
  - MFA (any valid second factor)
  - Passwordless MFA (Authenticator + FIDO2 + Windows Hello)
  - Phishing-resistant MFA (FIDO2 + Windows Hello + CBA)
```

### Claims in the Token
After MFA, the access token contains claims that apps and CA policies evaluate:

- `amr` (Authentication Method Reference): array of methods used. `["pwd","mfa"]` = password + MFA
- `acr` (Authentication Context Class Reference): level of assurance
- `auth_time`: epoch timestamp of the last interactive authentication
- `mfa_auth_time` / `pwd_auth_time` (in some token versions)

### MFA Registration
Users register methods at `https://aka.ms/mysecurityinfo`. The registration itself can be:
- **Self-service**: user registers freely
- **Combined registration**: single flow for MFA + SSPR registration (default in modern tenants)
- **Interrupted at sign-in**: user prompted to register when they first hit a CA policy requiring MFA
- **Enforced via CA registration policy**: CA policy targets "All users" with registration location exclusion

### MFA Session Persistence (Stay signed in / token lifetime)
CA policies can control how long an MFA satisfaction persists:
- **Sign-in frequency**: After X hours/days, force re-authentication even with valid session
- **Persistent browser session**: Controls whether "Stay signed in?" prompt appears
- **Remember MFA**: Legacy per-user setting that remembers MFA for 1-60 days on trusted device

</details>

---

## Dependency Stack

```
[User Account in Entra ID]
        │ Has
        ├── Registered Authentication Methods (mysecurityinfo)
        │         validated by
        ▼
[Authentication Methods Policy]
  (tenant-wide, controls which methods are available)
        │
        ▼
[Entra ID Conditional Access Policies]
  Evaluate: User + App + Location + Device + Risk → Grant controls
  OR
[Security Defaults] (if P1 not available)
  OR
[Per-user MFA state] (legacy, being deprecated)
        │
        ▼
[MFA Challenge Service (Microsoft-hosted)]
  Delivers: Push / TOTP / SMS / FIDO2 challenge
        │ Requires for push:
        ├── Internet connectivity from user device
        ├── Microsoft Authenticator app installed and signed in
        └── Device notification service (FCM/APNS reachable)
        │
        ▼
[Entra ID STS]
  Issues token with MFA claims (amr: ["mfa"])
        │
        ▼
[App / Service receiving token]
  Validates token; enforces its own claim checks if applicable
```

**Key constraint:** MFA push notifications require the user's device to reach Microsoft push services. Corporate proxy/firewall blocking `*.microsoft.com`, `*.live.com`, or mobile notification services (FCM for Android, APNs for iOS) will break push even though the registration looks correct.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| User prompted for MFA every sign-in, even on trusted device | Sign-in frequency CA policy or "Remember MFA" disabled | Check CA policies for sign-in frequency settings |
| Push notification not received on Authenticator | Network/firewall blocking push services, or app signed out | Re-test with TOTP; check device's push notification service |
| User gets "Your account is set up to block this" | Auth method blocked by Authentication Methods Policy | Check policy for that method type |
| TOTP code rejected ("incorrect code") | Clock skew on user device | Check device time sync; TOTP requires <30 second accuracy |
| MFA not triggering for specific app | App excluded from CA policy or uses legacy auth | Check CA policy app inclusions; check if app uses basic auth |
| Error 53004 "must register for MFA" | User hits CA policy before registering methods | Issue TAP + registration URL; check MFA registration CA policy |
| Error 50076 on every auth | MFA not being cached — sign-in frequency too low | Adjust CA policy sign-in frequency or check token cache |
| FIDO2 key not working | Key not registered or relying party ID mismatch | Re-register key at mysecurityinfo; check RP ID configuration |
| B2B guest can't MFA | Home tenant doesn't trust target tenant's MFA | Configure cross-tenant access settings; or require guest to MFA at home tenant |
| App claims MFA not satisfied even though user did MFA | App checking specific amr values; token cached before MFA | Force re-auth; check app's token validation code |

---

## Validation Steps

**Step 1 — Determine enforcement model in tenant**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All","UserAuthenticationMethod.Read.All","AuditLog.Read.All" -NoWelcome

# Check Security Defaults
$sd = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy"
Write-Host "Security Defaults: $($sd.isEnabled)"

# Check MFA-requiring CA policies
$caPolicies = Get-MgIdentityConditionalAccessPolicy |
    Where-Object { $_.State -eq "enabled" -and $_.GrantControls.BuiltInControls -contains "mfa" }
Write-Host "Active CA policies requiring MFA: $($caPolicies.Count)"
$caPolicies | Select-Object DisplayName, State | Format-Table
```

---

**Step 2 — Audit registered methods for a user**
```powershell
$UPN = "<user@domain.com>"
$methods = Get-MgUserAuthenticationMethod -UserId $UPN

Write-Host "Auth methods for $UPN :" -ForegroundColor Cyan
$methods | ForEach-Object {
    $type = $_.AdditionalProperties["@odata.type"]
    $detail = switch -Wildcard ($type) {
        "*microsoftAuthenticator*" { "Device: $($_.AdditionalProperties.displayName)" }
        "*phone*"                  { "Phone: $($_.AdditionalProperties.phoneNumber) ($($_.AdditionalProperties.phoneType))" }
        "*fido2*"                  { "FIDO2: $($_.AdditionalProperties.displayName)" }
        "*temporaryAccessPass*"    { "TAP (expires: $($_.AdditionalProperties.startDateTime))" }
        "*password*"               { "Password (primary factor)" }
        "*softwareOath*"           { "Software OATH token" }
        default                    { $type }
    }
    Write-Host "  [$type] $detail"
}
```

---

**Step 3 — Review Authentication Methods Policy**
```powershell
$policy = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy"

$policy.authenticationMethodConfigurations | 
    Select-Object id, state |
    Sort-Object id |
    Format-Table -AutoSize
```

---

**Step 4 — Decode a sign-in failure**
```powershell
$UPN = "<user@domain.com>"
$hours = 24

$signIns = Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$UPN'" -Top 30 |
    Where-Object { $_.CreatedDateTime -gt (Get-Date).AddHours(-$hours) }

$signIns | ForEach-Object {
    $s = $_
    [PSCustomObject]@{
        Time        = $s.CreatedDateTime
        App         = $s.AppDisplayName
        ErrorCode   = $s.Status.ErrorCode
        Reason      = $s.Status.FailureReason
        MFA         = "$($s.MfaDetail.AuthMethod) - $($s.MfaDetail.AuthDetail)"
        CAStatus    = $s.ConditionalAccessStatus
        Location    = "$($s.Location.City), $($s.Location.CountryOrRegion)"
        IPAddress   = $s.IPAddress
    }
} | Format-Table -AutoSize
```

---

**Step 5 — Verify CA policy coverage for user**
```powershell
$UPN = "<user@domain.com>"
$user = Get-MgUser -UserId $UPN -Property Id, DisplayName
$userId = $user.Id
$groupIds = (Get-MgUserMemberOf -UserId $UPN -All).Id

Write-Host "Checking CA policy coverage for: $UPN" -ForegroundColor Cyan

Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.State -eq "enabled" } | ForEach-Object {
    $policy = $_
    $grantMFA = $policy.GrantControls.BuiltInControls -contains "mfa"
    $inclAll  = $policy.Conditions.Users.IncludeUsers -contains "All"
    $inclUser = $policy.Conditions.Users.IncludeUsers -contains $userId
    $inclGroup= $policy.Conditions.Users.IncludeGroups | Where-Object { $groupIds -contains $_ }
    $exclUser = $policy.Conditions.Users.ExcludeUsers -contains $userId
    $exclGroup= $policy.Conditions.Users.ExcludeGroups | Where-Object { $groupIds -contains $_ }

    $applies  = ($inclAll -or $inclUser -or $inclGroup) -and -not ($exclUser -or $exclGroup)

    if ($grantMFA -and $applies) {
        Write-Host "  [APPLIES - MFA required] $($policy.DisplayName)" -ForegroundColor Green
    } elseif ($grantMFA) {
        Write-Host "  [DOES NOT APPLY] $($policy.DisplayName)" -ForegroundColor Yellow
    }
}
```

---

**Step 6 — Check MFA registration status at scale (reporting)**
```powershell
# Requires Reports.Read.All permission
$report = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/reports/authenticationMethods/userRegistrationDetails" |
    Select-Object -ExpandProperty value

$report | Select-Object userPrincipalName, isMfaRegistered, isMfaCapable, 
    isPasswordlessCapable, methodsRegistered |
    Export-Csv "C:\Temp\MFA-Registration-Report.csv" -NoTypeInformation

Write-Host "Total users: $($report.Count)"
Write-Host "MFA registered: $(($report | Where-Object isMfaRegistered).Count)"
Write-Host "MFA NOT registered: $(($report | Where-Object { -not $_.isMfaRegistered }).Count)"
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — MFA not being triggered at all

1. Check if Security Defaults is enabled (blocks CA for the same tenant — pick one).
2. Verify CA policies: are they in Report-Only mode? Report-Only = no enforcement.
3. Confirm the user + app combination is included in the CA policy.
4. Check if the app uses legacy authentication (Basic Auth): CA "Require MFA" doesn't apply to legacy auth clients. Block legacy auth via a separate CA policy.
5. Check if the app registers as a "Confidential Client" — some service account flows skip MFA.

### Phase 2 — MFA triggered but push not working

1. User should use TOTP as fallback (open Authenticator → tap the account → use the 6-digit code).
2. Check Authenticator app is signed in with the same account.
3. Check device push notification settings (iOS: Settings > Notifications > Authenticator > Allow Notifications; Android: similar).
4. Verify corporate proxy/firewall doesn't block: `login.microsoftonline.com`, `*.aadcdn.msauthimages.net`, `management.azure.com`, and mobile push services.
5. If push consistently fails: consider enabling Microsoft Authenticator in "number matching + additional context" mode in Auth Methods Policy — number matching requires user action that indicates the push was received.

### Phase 3 — TOTP code rejected

1. Most common cause: **clock skew**. TOTP is time-based with a 30-second window.
2. On iOS: Settings > General > Date & Time > Set Automatically = ON
3. On Android: Settings > General Management > Date and Time > Automatic date and time = ON
4. If device clock is correct and codes still fail: remove and re-add the account in Authenticator.
5. Hardware token clock drift: hardware tokens need periodic resynchronisation via Entra ID admin portal.

### Phase 4 — MFA required too frequently (user frustration)

1. Check CA policies for "Sign-in frequency" settings. Default = no frequency restriction (session persists per token lifetime).
2. If sign-in frequency is set to e.g., 1 hour, users re-auth every hour on every app.
3. Consider: increase sign-in frequency threshold, or use "Persistent browser session" for compliant devices.
4. Enable "Require reauthentication every time" only for highly sensitive apps (PAM, Azure portal).
5. Check if "Remember MFA" (legacy per-user setting) was disabled — re-enable per user if still on legacy model.

### Phase 5 — B2B guests can't satisfy MFA

1. Check the guest's home tenant — do they have MFA registered there?
2. Configure **Cross-Tenant Access Settings** in the resource tenant: allow inbound trusts to accept MFA claims from the home tenant.
3. If home tenant is unmanaged/external: configure CA policy in resource tenant to require MFA for guests regardless, so they perform MFA against the resource tenant.
4. Check if the guest has registered an auth method in the resource tenant's `mysecurityinfo`.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Bulk-identify users without MFA registered</summary>

```powershell
# Requires Reports.Read.All
$report = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/reports/authenticationMethods/userRegistrationDetails" |
    Select-Object -ExpandProperty value

$notRegistered = $report | Where-Object { -not $_.isMfaRegistered -and $_.accountEnabled -eq $true }

Write-Host "Users without MFA: $($notRegistered.Count)" -ForegroundColor Yellow
$notRegistered | Select-Object userPrincipalName, methodsRegistered |
    Export-Csv "C:\Temp\MFA-Not-Registered.csv" -NoTypeInformation

Write-Host "Report saved to C:\Temp\MFA-Not-Registered.csv" -ForegroundColor Green
```

</details>

<details><summary>Playbook 2 — Bulk-issue TAPs for users needing to register</summary>

```powershell
# Issue TAPs to a list of users (e.g., from the bulk report above)
# Requires UserAuthenticationMethod.ReadWrite.All

$usersToEnrol = @(
    "user1@domain.com",
    "user2@domain.com"
    # Add more UPNs
)

$results = @()
foreach ($UPN in $usersToEnrol) {
    try {
        $body = @{
            lifetimeInMinutes = 480   # 8 hours
            isUsableOnce      = $true
        } | ConvertTo-Json

        $tap = Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/users/$UPN/authentication/temporaryAccessPassMethods" `
            -Body $body -ContentType "application/json"

        $results += [PSCustomObject]@{
            UPN = $UPN
            TAP = $tap.temporaryAccessPass
            Expires = (Get-Date $tap.startDateTime).AddMinutes($tap.lifetimeInMinutes)
            Status = "Success"
        }
        Write-Host "[OK] TAP issued for $UPN" -ForegroundColor Green
    } catch {
        $results += [PSCustomObject]@{
            UPN = $UPN; TAP = "FAILED"; Expires = "N/A"; Status = $_.Exception.Message
        }
        Write-Host "[FAIL] $UPN : $($_.Exception.Message)" -ForegroundColor Red
    }
}

$results | Export-Csv "C:\Temp\TAP-Issued.csv" -NoTypeInformation
Write-Host "`nTAPs saved to C:\Temp\TAP-Issued.csv — distribute securely (phone/in-person)" -ForegroundColor Cyan
```

</details>

<details><summary>Playbook 3 — Enable number matching on Microsoft Authenticator (anti-MFA fatigue)</summary>

**When:** Users are approving push notifications without reading them (MFA fatigue attacks)

```powershell
# Enable number matching + additional context for Authenticator
$body = @{
    "@odata.type" = "#microsoft.graph.microsoftAuthenticatorAuthenticationMethodConfiguration"
    state = "enabled"
    featureSettings = @{
        numberMatchingRequiredState = @{
            state = "enabled"
            includeTarget = @{ targetType = "group"; id = "all_users" }
        }
        displayAppInformationRequiredState = @{
            state = "enabled"
            includeTarget = @{ targetType = "group"; id = "all_users" }
        }
    }
} | ConvertTo-Json -Depth 10

Invoke-MgGraphRequest -Method PATCH `
    -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/MicrosoftAuthenticator" `
    -Body $body -ContentType "application/json"

Write-Host "Number matching + context enabled for Microsoft Authenticator" -ForegroundColor Green
```

**Rollback:** Set `state` to `"disabled"` for each featureSettings block.

</details>

<details><summary>Playbook 4 — Migrate from per-user MFA to CA-based MFA (bulk)</summary>

```powershell
# PREREQUISITES: Ensure CA policy already enforces MFA for all users before running this
# This disables per-user MFA state for all users who have it set

# Verify CA coverage first
$caPolicies = Get-MgIdentityConditionalAccessPolicy |
    Where-Object { $_.State -eq "enabled" -and $_.GrantControls.BuiltInControls -contains "mfa" }
if ($caPolicies.Count -eq 0) {
    Write-Host "WARNING: No CA policies requiring MFA found! Do not proceed." -ForegroundColor Red
    return
}
Write-Host "CA policies found: $($caPolicies.Count). Safe to migrate." -ForegroundColor Green

# Get all users with per-user MFA enforced
# Note: This uses the beta endpoint as Graph v1.0 doesn't expose perUserMfaState for bulk reads
$users = Get-MgUser -All -Property Id, UserPrincipalName | 
    Where-Object { $_.UserPrincipalName -notmatch "#EXT#" }  # skip guests

$migratedCount = 0
foreach ($user in $users) {
    $uri = "https://graph.microsoft.com/beta/users/$($user.Id)/authentication/requirements"
    try {
        $current = Invoke-MgGraphRequest -Method GET -Uri $uri
        if ($current.perUserMfaState -eq "enforced") {
            $body = @{ perUserMfaState = "disabled" } | ConvertTo-Json
            Invoke-MgGraphRequest -Method PATCH -Uri $uri -Body $body -ContentType "application/json"
            $migratedCount++
            Write-Host "[OK] $($user.UserPrincipalName) migrated" -ForegroundColor Green
        }
    } catch {
        Write-Host "[SKIP] $($user.UserPrincipalName): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
Write-Host "`nMigrated $migratedCount users from per-user MFA to CA-based MFA." -ForegroundColor Cyan
```

</details>

---

## Evidence Pack

```powershell
# MFA Evidence Collector — run as GA or Auth Admin
Connect-MgGraph -Scopes "Policy.Read.All","UserAuthenticationMethod.Read.All","AuditLog.Read.All","Reports.Read.All" -NoWelcome

$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$outDir = "C:\Temp\MFA-Evidence-$timestamp"
$UPN = "<user@domain.com>"  # Target user
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
Write-Host "[*] Collecting MFA evidence for $UPN" -ForegroundColor Cyan

# 1. User auth methods
Get-MgUserAuthenticationMethod -UserId $UPN |
    Select-Object Id, @{N="Type";E={$_.AdditionalProperties["@odata.type"]}}, AdditionalProperties |
    ConvertTo-Json -Depth 5 | Out-File "$outDir\auth-methods.json"
Write-Host "[OK] Auth methods" -ForegroundColor Green

# 2. Sign-in logs (last 48h)
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$UPN'" -Top 50 |
    Select-Object CreatedDateTime, AppDisplayName, 
        @{N="ErrorCode";E={$_.Status.ErrorCode}},
        @{N="FailureReason";E={$_.Status.FailureReason}},
        @{N="MFADetail";E={$_.MfaDetail | ConvertTo-Json}},
        ConditionalAccessStatus, IPAddress |
    Export-Csv "$outDir\sign-in-logs.csv" -NoTypeInformation
Write-Host "[OK] Sign-in logs" -ForegroundColor Green

# 3. CA policies (MFA-related)
Get-MgIdentityConditionalAccessPolicy |
    Where-Object { $_.GrantControls.BuiltInControls -contains "mfa" } |
    ConvertTo-Json -Depth 10 | Out-File "$outDir\ca-policies-mfa.json"
Write-Host "[OK] CA policies" -ForegroundColor Green

# 4. Auth Methods Policy
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy" |
    ConvertTo-Json -Depth 10 | Out-File "$outDir\auth-methods-policy.json"
Write-Host "[OK] Auth Methods Policy" -ForegroundColor Green

# 5. User registration detail
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/reports/authenticationMethods/userRegistrationDetails/$((Get-MgUser -UserId $UPN).Id)" |
    ConvertTo-Json -Depth 5 | Out-File "$outDir\user-registration-detail.json"
Write-Host "[OK] User registration detail" -ForegroundColor Green

# 6. Security Defaults
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy" |
    ConvertTo-Json | Out-File "$outDir\security-defaults.json"

Write-Host "`nEvidence saved to: $outDir" -ForegroundColor Cyan
Get-ChildItem $outDir | Select-Object Name, Length | Format-Table -AutoSize
Write-Host "Compress and attach to ticket: Compress-Archive -Path '$outDir' -DestinationPath '$outDir.zip'"
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Connect to Graph (MFA scope) | `Connect-MgGraph -Scopes "Policy.Read.All","UserAuthenticationMethod.Read.All","AuditLog.Read.All"` |
| Get user's auth methods | `Get-MgUserAuthenticationMethod -UserId <UPN>` |
| Remove an auth method | `Remove-MgUserAuthenticationMethod -UserId <UPN> -AuthenticationMethodId <id>` |
| Issue a TAP | `Invoke-MgGraphRequest -Method POST -Uri ".../users/<UPN>/authentication/temporaryAccessPassMethods" -Body $body` |
| Get CA policies requiring MFA | `Get-MgIdentityConditionalAccessPolicy \| Where-Object { $_.GrantControls.BuiltInControls -contains "mfa" }` |
| Get sign-in logs | `Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 20` |
| Get auth methods policy | `Invoke-MgGraphRequest -GET ".../policies/authenticationMethodsPolicy"` |
| Get MFA registration report | `Invoke-MgGraphRequest -GET ".../reports/authenticationMethods/userRegistrationDetails"` |
| Check security defaults | `Invoke-MgGraphRequest -GET ".../policies/identitySecurityDefaultsEnforcementPolicy"` |
| Set per-user MFA state | `Invoke-MgGraphRequest -PATCH ".../users/<UPN>/authentication/requirements" -Body '{"perUserMfaState":"disabled"}'` |
| MFA registration URL | `https://aka.ms/mysecurityinfo` |
| Sign-in logs in portal | `https://entra.microsoft.com/#view/Microsoft_AAD_IAM/SignInEventsV3Blade` |

---

## 🎓 Learning Pointers

- **Security Defaults and CA cannot coexist**: If Security Defaults is enabled, Conditional Access policies are disabled for the tenant. This is by design — Security Defaults provides baseline MFA without needing P1 licences. When you purchase P1 and want to use CA, the first step is disabling Security Defaults. Failing to do this explains why CA policies "aren't working." See: [Security defaults vs. Conditional Access](https://learn.microsoft.com/en-us/entra/fundamentals/security-defaults)

- **Authentication Strength is the future of MFA requirements**: Instead of just "require MFA" in CA, Authentication Strength lets you require specific method types (e.g., phishing-resistant only). This is critical for privileged access scenarios — a CA policy on Azure Portal should require phishing-resistant MFA (FIDO2/WHfB/CBA), not just any MFA (including SMS which is phishable). See: [Authentication strength](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-authentication-strengths)

- **Report-Only mode is your safety net**: Before enabling any CA policy, always deploy it in Report-Only mode first. Sign-in logs show what *would have happened* without enforcement. This prevents accidental lockouts. A common mistake: creating a "block legacy auth" policy without checking which apps still use legacy auth. Report-Only + sign-in log review first. See: [Report-only mode](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-report-only)

- **Number matching defeated MFA fatigue attacks**: Before number matching, attackers would spam push notifications until a tired user approved one. Number matching requires the user to enter a number displayed in the app, matching the number shown on the sign-in page. This broke the "mindless approve" pattern. Microsoft enabled this by default across all tenants in 2023. Ensure it's active in the Authentication Methods Policy. See: [Number matching](https://learn.microsoft.com/en-us/entra/identity/authentication/how-to-mfa-number-match)

- **Token claims prove MFA happened — or didn't**: The `amr` claim in a JWT access token lists what authentication methods were used. `["pwd"]` = only password. `["pwd","mfa"]` = password + MFA. You can decode any token at `https://jwt.ms`. If an app complains that MFA wasn't satisfied even though the user completed it, decode the token and check the `amr` claim — you may find a cached token from before MFA was required, or the app itself has claim validation bugs. See: [Access token claims reference](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference)

- **Per-user MFA migration has no big-bang risk**: Disabling per-user MFA state while a CA policy enforces MFA for the same user is completely safe — the user still gets MFA prompts, just enforced by the CA policy instead of the account property. The only risk is migrating users who aren't covered by the CA policy. Always audit CA coverage before migrating. See: [Migrate to CA-based MFA](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-mfa-userstates)
