# Passkeys (FIDO2) — Hotfix Runbook (Mode B: Ops)
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

Run these first to locate the failure layer. Passkeys (FIDO2) is the phishing-resistant
authentication method covering FIDO2 security keys, passkeys in Microsoft Authenticator
(device-bound), and synced passkeys (Apple iCloud Keychain, Google Password Manager,
third-party providers like Keeper/1Password/Bitwarden).

```powershell
Connect-MgGraph -Scopes "Policy.Read.All","UserAuthenticationMethod.Read.All"

# 1. Check the tenant's Passkey (FIDO2) authentication method policy state
$fido2 = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Fido2"
$fido2 | Select-Object state, isAttestationEnforced, isSelfServiceRegistrationAllowed

# 2. Check if passkey profiles are opted-in (GA March 2026) vs. legacy single-policy mode
# If the response above has no "keyRestrictions"/profile-shaped data, tenant may still be on legacy policy
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/authenticationMethodsPolicy/authenticationMethodConfigurations/Fido2" |
    Select-Object -ExpandProperty additionalProperties

# 3. Check the specific user's registered passkey methods
$upn = "<user@contoso.com>"
Get-MgUserAuthenticationFido2Method -UserId $upn | Select-Object Id, DisplayName, AaGuid, AttestationCertificates, CreatedDateTime

# 4. Check whether MFA was satisfied in the last 5 minutes (required to register a NEW passkey)
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn'" -Top 5 |
    Select-Object CreatedDateTime, AppDisplayName, Status, AuthenticationRequirement

# 5. Check for a Conditional Access authentication-strength lockout loop
# (policy requires phishing-resistant MFA to reach "Register security information" itself)
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.Conditions.Applications.IncludeUserActions -contains "urn:user:registersecurityinfo" } |
    Select-Object DisplayName, State
```

| Result | Action |
|--------|--------|
| `state: disabled` on Fido2 policy | → Fix 1: Enable Passkey (FIDO2) policy |
| User has 0 registered methods, tried to register, got looped back to MFA | → Fix 2: Break the CA registration lockout loop |
| `isAttestationEnforced: true` and user's provider is a synced passkey (iCloud/Google/3rd-party) | → Fix 3: Attestation blocks synced passkeys — adjust the profile |
| Cross-device (QR/Bluetooth) registration or sign-in fails with "Device couldn't connect" | → Fix 4: Cross-device/Bluetooth connectivity |
| User's UPN changed and passkey now unusable | → Fix 5: UPN-change passkey reset |
| Guest / B2B user trying to register a passkey | → Not supported — guests cannot register FIDO2 credentials, no fix exists |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Passkey (FIDO2) Authentication Method Policy — Enabled]
         |
[Passkey profiles opted in (GA March 2026)]
  └─ Default passkey profile + up to 9 additional (10 total)
  └─ Each profile: Attestation (Y/N), Passkey types (Device-bound / Synced), AAGUID restrictions
         |
[Target group assignment]
  └─ User must be in-scope of a profile with a NON-excluded status
  └─ Excluded-group membership always wins over any Included profile
         |
[Registration path]
  └─ Self-service (Security info / mysignins.microsoft.com) — requires "Allow self-service setup: Yes"
  └─ Requires MFA satisfied within the last 5 minutes
  └─ Conditional Access on "Register security information" user action must NOT create a
     phishing-resistant-only loop (chicken/egg — see Learning Pointers)
         |
[Passkey type chosen at registration]
  ├─ Device-bound (Authenticator app / FIDO2 security key) — private key never leaves device
  └─ Synced (iCloud Keychain / Google Password Manager / 3rd-party vault) — no attestation possible
         |
[Sign-in]
  └─ WebAuthn (browser) or CTAP (native app) challenge-response
  └─ Conditional Access authentication strength may require Passkey (FIDO2) specifically
     for sensitive resources
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the Passkey (FIDO2) policy is enabled and check attestation setting**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Fido2" |
    Select-Object state, isAttestationEnforced, isSelfServiceRegistrationAllowed
```
Expected: `state: enabled`, `isSelfServiceRegistrationAllowed: true`. If `isAttestationEnforced: true`,
only device-bound passkeys are allowed — synced passkeys are silently excluded from registration.

**2. Confirm the user is in-scope and not accidentally excluded**
Check **Entra ID > Security > Authentication methods > Policies > Passkey (FIDO2) > Configure** — a
user in an Excluded group is blocked entirely, even if they're also in an Included group.

**3. Confirm MFA was satisfied recently**
```powershell
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<user@contoso.com>'" -Top 3 |
    Select-Object CreatedDateTime, AuthenticationRequirement, Status
```
Passkey (FIDO2) registration requires MFA within the last 5 minutes. If the user's last sign-in
was single-factor, registration will be blocked or prompt for step-up MFA first.

**4. Check for the phishing-resistant CA registration lockout loop**
```powershell
Get-MgIdentityConditionalAccessPolicy |
    Where-Object { $_.GrantControls.AuthenticationStrength.DisplayName -match "Phishing" } |
    Select-Object DisplayName, State, @{N="Actions";E={$_.Conditions.Applications.IncludeUserActions}}
```
If a policy requires **Phishing-resistant MFA** for **All resources** (or specifically the
`urn:user:registersecurityinfo` action) and the user has no phishing-resistant method yet, they
cannot reach Security info to register their first passkey — see Fix 2.

**5. Check registered method AAGUID against key restrictions**
```powershell
Get-MgUserAuthenticationFido2Method -UserId "<user@contoso.com>" | Select-Object DisplayName, AaGuid
```
Compare the AAGUID against the profile's key-restriction allow/block list. A mismatch here means
the passkey registered successfully in the past but is now blocked for sign-in by a policy change.

---
## Common Fix Paths

<details><summary>Fix 1 — Enable Passkey (FIDO2) policy / opt in to passkey profiles</summary>

Use when: `state: disabled`, or the tenant is still on the legacy single-policy model and needs
per-group passkey profiles (admins vs. frontline staff, different attestation/type rules).

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.AuthenticationMethod"

$body = @{
    "@odata.type" = "#microsoft.graph.fido2AuthenticationMethodConfiguration"
    state = "enabled"
    isSelfServiceRegistrationAllowed = $true
    isAttestationEnforced = $false
} | ConvertTo-Json

Invoke-MgGraphRequest -Method PATCH `
    -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Fido2" `
    -Body $body
```

**Admin center path for passkey profiles (recommended over raw Graph PATCH for profile-level
control):** Entra admin center > **Security > Authentication methods > Policies > Passkey (FIDO2)**
> select the banner link to opt in to passkey profiles > configure the **Default passkey profile**
> **Passkey types** > Save. Note: once you opt in to passkey profiles, you can't opt back out.

**Rollback:** Setting `state: disabled` blocks all new registrations but does not remove
already-registered passkeys — they simply can't be used to sign in until re-enabled.

</details>

<details><summary>Fix 2 — Break the CA registration lockout loop (chicken/egg on first passkey)</summary>

Use when: A Conditional Access policy requires phishing-resistant MFA tenant-wide, and a user with
no passkey yet cannot reach Security info to register their first one.

**Root cause:** the built-in "Phishing-resistant MFA" authentication strength does **not** accept
Temporary Access Pass (TAP), so a TAP-based bootstrap flow fails against it.

```
1. Create a custom authentication strength "Onboard Passkey" that includes:
   Temporary Access Pass (One-time use), Passkey (FIDO2), Windows Hello for Business
   (Entra ID > Authentication methods > Authentication strengths > New authentication strength)

2. Confirm Temporary Access Pass is configured for ONE-TIME USE ONLY
   (Entra ID > Authentication methods > Temporary Access Pass > "One-time use" = Yes)
   -- if this is set to "No", the custom strength above will reject the TAP outright.

3. Create/adjust two Conditional Access policies scoped to the same target group:
   a. "Require Phishing-resistant MFA" — All resources, EXCLUDING the
      "Register security information" user action
   b. "Onboard Passkey" — targets ONLY the "Register security information" user action,
      requires the "Onboard Passkey" authentication strength from step 1

4. If step 3 alone still loops (common — several first-party Microsoft apps are hit during
   the registration flow before Security info fully loads), exclude these app IDs from policy
   (a) and require the "Onboard Passkey" strength for them in a third policy instead:
     AADreporting                                    1b912ec3-a9dd-4c4d-a53e-76aa7adb28d7
     Azure Credential Configuration Endpoint Service ea890292-c8c8-4433-b5ea-b09d0668e1a6
     Microsoft App Access Panel                      0000000c-0000-0000-c000-000000000000
     My Profile                                      8c59ead7-d703-4a27-9e55-c96a0054c8d2
     My Signins                                       19db86c3-b2b9-44cc-b339-36da233a3be2
     Windows Azure Active Directory                  00000002-0000-0000-c000-000000000000

# If "My Signins" has no service principal in the tenant yet, create one:
Connect-MgGraph -Scopes "Application.ReadWrite.All"
New-MgServicePrincipal -AppId "19db86c3-b2b9-44cc-b339-36da233a3be2"

5. Wait at least 10 minutes after any CA policy change before testing — propagation is not instant.

6. Issue the user a one-time-use TAP and have them register their passkey at
   https://mysignins.microsoft.com/security-info
```

**Rollback:** Disable the "Onboard Passkey" CA policy exclusions once the affected users have
completed registration — don't leave a standing TAP-acceptable bypass on production apps.

</details>

<details><summary>Fix 3 — Attestation blocking synced passkeys</summary>

Use when: `isAttestationEnforced: true` on the profile, and the user's passkey provider is a
synced type (iCloud Keychain, Google Password Manager, or a third-party vault). Synced passkeys
never support attestation — enforcing it silently excludes them from the profile entirely.

```
Entra admin center > Security > Authentication methods > Policies > Passkey (FIDO2) > Configure
> select the target profile > set "Enforce attestation" to No
  (or split into two profiles: one attestation-enforced/device-bound-only for admins,
   one attestation-off/synced-allowed for standard users)
> Save
```

Microsoft's own recommendation: device-bound passkeys (with attestation enforced) for admins and
highly privileged accounts; synced passkeys (attestation off) for standard users. Don't force one
setting tenant-wide if both populations exist.

**Rollback:** Re-enabling attestation on a profile blocks future synced-passkey registration for
targeted users but does not retroactively delete already-registered synced passkeys — those
simply stop being usable for sign-in against that profile's scope.

</details>

<details><summary>Fix 4 — Cross-device / Bluetooth registration or sign-in fails</summary>

Use when: user sees "Device couldn't connect" during QR-code cross-device passkey flows.

```
1. Confirm Bluetooth AND internet access are enabled on BOTH devices (the device holding the
   passkey and the device being signed into) — this is a hard requirement for CTAP hybrid transport.

2. Confirm attestation is NOT enforced for this user's profile — cross-device registration/
   authentication is not supported when attestation is required.

3. If the organization restricts Bluetooth via policy, confirm these endpoints are reachable:
     Android: cable.ua5v.com
     iOS:     cable.auth.com, app-site-association.cdn-apple.com,
              app-site-association.networking.apple

4. If Bluetooth is centrally restricted (Intune/GPO), configure an exception scoped to
   passkey-enabled FIDO2 authenticators rather than disabling the restriction org-wide —
   see MS Docs "Passkeys in Bluetooth-restricted environments".
```

**Rollback:** Non-destructive — this is a connectivity/config check, not a state change.

</details>

<details><summary>Fix 5 — UPN change breaks an existing passkey</summary>

Use when: a user's UPN was changed (rename, domain migration) and their existing passkey (FIDO2)
no longer works to sign in.

```
Known limitation: passkeys cannot be modified in-place to reflect a UPN change.

1. Have the user sign in with an alternate method (another MFA method, or admin-issued TAP)
2. User goes to https://mysignins.microsoft.com/security-info
3. Delete the old passkey (FIDO2) entry
4. Register a new passkey under the current UPN
```

**Rollback:** N/A — this is the only supported remediation path; there is no cmdlet to
re-associate an existing FIDO2 credential with a new UPN.

</details>

---
## Escalation Evidence

```
PASSKEYS (FIDO2) ESCALATION
============================
Date/Time                     :
Tenant ID                     :
User UPN                      :
Fido2 policy state            : enabled / disabled
Attestation enforced          : Yes / No
Passkey profiles opted in     : Yes / No (legacy single policy)
User's registered method(s)   : (DisplayName, AaGuid, CreatedDateTime from Get-MgUserAuthenticationFido2Method)
Passkey type attempted        : Device-bound (Authenticator/security key) / Synced (provider name)
Last MFA sign-in timestamp    :
Relevant CA policy name(s)    :
CA targets "Register security
information" user action?     : Yes / No
Error message (verbatim)      :
Cross-device / Bluetooth      : Enabled/Disabled on both devices — Y/N
Steps Already Tried           :
```

---
## 🎓 Learning Pointers

- **The registration bootstrap problem is the #1 real-world blocker** — enabling Passkey (FIDO2)
  doesn't make a tenant phishing-resistant by itself. If Conditional Access requires
  phishing-resistant MFA everywhere before a user has registered their first passkey, they can
  never get in to register one. Treat first-passkey onboarding as a scoped TAP-based bootstrap
  flow, not a toggle. Community writeup: [Passkey onboarding in Entra: what Microsoft doesn't tell
  you (agderinthe.cloud)](https://agderinthe.cloud/2026/02/26/passkey-onboarding-in-entra-what-microsoft-doesnt-tell-you/)
- **Attestation is an all-or-nothing gate against synced passkeys** — there is no partial
  attestation for synced providers; enforcing it removes them from the profile entirely. Decide
  device-bound-vs-synced policy per user population (admins vs. everyone else), not tenant-wide.
- **Passkey profiles reached GA in March 2026** and raised the per-tenant profile limit from 3 to
  10 — if your tenant predates this, you may still be on the legacy single Fido2 policy; opting in
  is one-way (no opt-out).
- **AAGUID allow/block lists are a policy guide, not a security control, for synced passkeys** —
  because attestation can't be enforced on them, Entra ID cannot cryptographically verify the
  claimed AAGUID is genuine. Only trust AAGUID restriction as a hard control for device-bound
  (attested) passkeys.
- **Official docs:** [Passkeys (FIDO2) authentication method](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-passkeys-fido2) | [How to enable passkeys (FIDO2)](https://learn.microsoft.com/en-us/entra/identity/authentication/how-to-authentication-passkeys-fido2) | [Passkey FAQs](https://learn.microsoft.com/en-us/entra/identity/authentication/passkey-faq)
- **Community:** [Entra ID Synced Passkeys and security considerations (hybridbrothers.com)](https://hybridbrothers.com/posts/entra-synced-passkeys) — lockout-scenario planning when restricting synced providers by AAGUID
