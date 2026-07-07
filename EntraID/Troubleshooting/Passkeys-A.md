# Passkeys (FIDO2) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Passkey Types Comparison](#passkey-types-comparison)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

- **Applies to:** Microsoft Entra ID, all editions including Entra ID Free (no extra license
  required). Covers FIDO2 security keys, passkeys in Microsoft Authenticator (iOS/Android), and
  synced passkeys (Apple iCloud Keychain, Google Password Manager, third-party providers).
- **Does not cover:** Windows Hello for Business as a device-bound Windows credential (see
  `WHfB-A.md`/`WHfB-B.md` — related but distinct: WHfB is Windows-device-specific, Passkeys
  (FIDO2) is the cross-platform, cross-device authentication method family) or Entra External ID
  consumer/B2C passkey sign-in (different product surface).
- **Assumes:** At least Authentication Policy Administrator role for policy changes, Conditional
  Access Administrator for authentication-strength/CA changes.
- **Key terminology:** "Passkey (FIDO2)" is Microsoft's umbrella term for all FIDO2-based
  credentials in Entra ID as of the 2026 passkey-profiles GA. Older docs/tickets may still say
  "FIDO2 security key" — treat these as the same authentication method family.

---

## How It Works

<details><summary>Full architecture — registration and sign-in flows</summary>

### What Passkeys Are

Passkeys are FIDO2-standard credentials built on WebAuthn (browser) and CTAP (authenticator
communication). Each passkey is an asymmetric key pair: the private key is generated and held by
an authenticator (a security key, Authenticator app, or OS/browser passkey provider); the public
key is registered with Entra ID as the relying party. Because the key pair is bound to the relying
party's origin, a passkey created for `login.microsoftonline.com` cannot be replayed against any
other site — this is what makes passkeys phishing-resistant by construction, not by policy.

### Registration Flow

```
User navigates to Security info (mysignins.microsoft.com/security-info) →
  MFA satisfied within last 5 minutes (hard requirement) →
  User selects "Add sign-in method" → Passkey →
  Browser/OS invokes WebAuthn navigator.credentials.create() →
  User picks authenticator: same-device platform authenticator, FIDO2 security key,
    or cross-device (QR code + Bluetooth handshake) →
  If attestation enforced: authenticator provides a cryptographic attestation statement
    (FIDO Metadata Service validates make/model) — synced passkeys cannot provide this →
  Public key + AAGUID + credential ID registered to the user's Entra ID object →
  Passkey (FIDO2) authentication method now available for sign-in
```

### Sign-In Flow

```
User initiates sign-in → enters UPN →
  Entra ID sends a WebAuthn challenge (nonce) to the authenticator →
  Authenticator locates the key pair via hashed RP ID + credential ID →
  User performs local gesture (biometric/PIN) to unlock the private key
    (gesture never leaves the device / is never sent to Entra ID) →
  Authenticator signs the challenge, returns signature →
  Entra ID verifies signature against stored public key → issues token
```

### Device-Bound vs. Synced — the Core Architectural Split

- **Device-bound**: private key generated and stored on a single physical device, never exported.
  Examples: FIDO2 security keys, Microsoft Authenticator (device-bound only — Authenticator
  passkeys cannot be synced or restored to a new device; losing the device means re-enrollment).
- **Synced**: private key is created by the local device's hardware security module, then encrypted
  and synced to a cloud passkey provider (iCloud Keychain, Google Password Manager, or a supported
  third-party vault like 1Password/Bitwarden/Keeper). Any device signed into that provider account
  can then use the passkey. **Synced passkeys cannot provide attestation** — this is a hard FIDO2
  protocol limitation, not a Microsoft policy choice, because the provider (not a single hardware
  chip) is the source of truth for the key material.

### Passkey Profiles (GA March 2026)

Prior to profiles, Passkey (FIDO2) was a single tenant-wide policy. Passkey profiles introduced
granular, group-scoped configuration:

```
Passkey (FIDO2) authentication method policy
  └── Default passkey profile (created automatically on opt-in; existing global settings transfer)
  └── Up to 9 additional named profiles (10 total per tenant, raised from 3 at GA)
        Each profile configures:
          - Enforce attestation: Yes/No
          - Passkey types allowed: Device-bound, Synced, or both
          - Key restrictions: allow/block list by AAGUID
        Each profile is then targeted at specific groups or All users
```

A user can be in scope of multiple profiles simultaneously (e.g., a group-based profile plus an
all-users default). Registration/sign-in is allowed if the passkey satisfies **at least one**
scoped profile — there's no defined precedence order between multiple Included profiles. However,
**Excluded group membership on the base Fido2 policy always wins** over any Included profile
membership, full stop.

### The 20 KB Policy Size Limit

The underlying Fido2 policy object (which stores all profiles, their AAGUID lists, and group
targeting) has a hard 20 KB size ceiling. Reference sizing from Microsoft: base policy ~1.44 KB,
each additional applied profile target ~0.23–0.4 KB, each profile with 10 AAGUIDs ~0.3 KB. Large
tenants with many granular profiles and long AAGUID allow-lists can hit this ceiling — plan profile
count and AAGUID list length accordingly rather than creating a profile per department by default.

</details>

---

## Dependency Stack

```
[FIDO2 / WebAuthn / CTAP standards — browser + OS + authenticator support]
         │
[Passkey (FIDO2) Authentication Method Policy — tenant-level, Enabled]
         │
[Passkey profiles — opted in (GA Mar 2026) or legacy single-policy mode]
    ├── Default passkey profile (mandatory once opted in)
    └── Up to 9 additional profiles — attestation / type / AAGUID rules
         │
[Target group assignment — Included vs. Excluded]
    └── Excluded always wins over any Included profile membership
         │
[Registration gate]
    ├── Allow self-service setup = Yes (global setting, not per-profile)
    ├── MFA satisfied within last 5 minutes
    └── Conditional Access on "Register security information" user action —
        must not create a phishing-resistant-only bootstrap loop
         │
[Authenticator layer — where the private key actually lives]
    ├── Device-bound: FIDO2 security key | Microsoft Authenticator (HW-backed: Secure
    │     Enclave on iOS, Android Keystore SE/TEE on Android)
    └── Synced: Apple iCloud Keychain | Google Password Manager | 3rd-party vault
         │
[Conditional Access — Authentication Strengths]
    ├── Built-in "Phishing-resistant MFA" (does NOT accept TAP)
    └── Custom strengths (can combine Passkey/FIDO2 + WHfB + cert-auth + scoped TAP)
         │
[Sign-in / resource access granted]
```

---

## Passkey Types Comparison

| Property | Device-Bound (Security Key) | Device-Bound (Authenticator App) | Synced (Cloud Provider) |
|---|---|---|---|
| Private key location | Physical hardware key | Secure Enclave (iOS) / Keystore SE-TEE (Android) | Provider's encrypted cloud store |
| Can be synced/restored | ❌ No | ❌ No | ✅ Yes |
| Attestation possible | ✅ Yes | ✅ Yes (via Apple App Attest / Google Play Integrity) | ❌ No — hard FIDO2 limitation |
| Best for | Highly regulated industries, admins | Admins/elevated users without a hardware key budget | Standard/non-privileged users at scale |
| Loss/recovery cost | High — physical replacement + re-registration | Medium — re-enroll on new device | Low — already present via provider sync |
| AAGUID reliable as security control | ✅ Yes (attested) | ✅ Yes (attested) | ⚠️ No — treat as policy guide only |
| Registration success rate (Microsoft consumer data) | N/A (hardware-dependent) | N/A | 99% |
| Speed vs. password+MFA | N/A | N/A | ~14x faster (3s vs. 69s reported) |

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| User can't reach Security info to register first passkey at all | CA requires phishing-resistant MFA on all resources including registration action | Check CA policies targeting `urn:user:registersecurityinfo` |
| TAP rejected during passkey bootstrap flow | Custom auth strength includes TAP, but TAP isn't set to "One-time use only" | `Authentication methods > Temporary Access Pass` setting |
| Registration works for some first-party MS apps but not "My Signins" | Missing service principal for a first-party app ID in the tenant | `Get-MgServicePrincipal -Filter "appId eq '<id>'"` |
| Synced passkey provider (iCloud/Google/vault) missing from registration options | Attestation is enforced on the user's scoped profile | Profile config — `isAttestationEnforced` |
| User registered passkey but it silently stopped working for sign-in | Key-restriction AAGUID list changed and removed a previously allowed AAGUID | Compare method's AAGUID vs. current profile allow-list |
| "Device couldn't connect" during QR/cross-device flow | Bluetooth or internet disabled on one of the two devices, or attestation enforced (blocks cross-device) | Confirm Bluetooth+internet on both; check attestation setting |
| Passkey stopped working after UPN rename | Known limitation — passkeys can't be updated in place for UPN changes | Delete + re-register under new UPN |
| Guest/B2B user cannot register a passkey | Not supported for internal or external guest users, by design | No fix — direct guest to an alternate MFA method |
| Registration blocked with generic "something went wrong" | MFA not satisfied within the last 5 minutes | Check recent sign-in `AuthenticationRequirement` |
| Authenticator app registration fails on Android 14 device meeting all other requirements | OEM hasn't implemented required Android Credential Manager APIs | Recommend Android 15 upgrade or fall back to security key |
| User's passkey invalidated after changing device PIN or biometric type | Android/iOS behavior — changing the underlying unlock mechanism invalidates the bound passkey | User must sign in with alternate method and re-create passkey |
| Passkey policy save fails with a size/limit error | 20 KB policy size ceiling reached (too many profiles / large AAGUID lists) | Consolidate profiles or trim AAGUID lists |
| User in China cannot sign in with Authenticator passkey | Passkeys unsupported for Microsoft Azure operated by 21Vianet | Direct to alternate MFA method for that tenant instance |

---

## Validation Steps

**1. Confirm tenant-wide Fido2 policy state and mode**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All"
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Fido2"
```
Expected: `state: enabled`. Cross-reference the admin center's Passkey (FIDO2) > Configure tab to
see whether passkey profiles have been opted into (profiles are not fully exposed via v1.0 Graph
as of this writing — the admin center is the authoritative view for profile-level detail).

**2. Confirm self-service registration and attestation settings per profile**
Admin center: **Entra ID > Security > Authentication methods > Policies > Passkey (FIDO2) >
Configure**. For each profile, note: Enforce attestation (Y/N), Passkey types allowed, Key
restriction enforcement and allow/block AAGUID list.

**3. Confirm target group scoping — Included vs Excluded**
**Entra ID > Security > Authentication methods > Policies > Passkey (FIDO2) > Enable and Target**.
Remember: Excluded overrides any Included profile for the same user.

**4. Verify a specific user's registered passkey methods**
```powershell
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All"
Get-MgUserAuthenticationFido2Method -UserId "<user@contoso.com>" |
    Select-Object Id, DisplayName, AaGuid, CreatedDateTime, AttestationCertificates, AttestationLevel
```
`AttestationLevel: attested` = device-bound with successful attestation. `AttestationLevel: none`
or absent = synced, or attestation not enforced at registration time.

**5. Verify recent MFA satisfaction (registration prerequisite)**
```powershell
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<user@contoso.com>'" -Top 5 |
    Select-Object CreatedDateTime, AuthenticationRequirement, Status, ConditionalAccessStatus
```

**6. Verify Conditional Access authentication strength composition**
```powershell
Get-MgIdentityConditionalAccessAuthenticationStrengthPolicy |
    Select-Object DisplayName, AllowedCombinations
```
Confirm whether the strength includes `fido2` and, separately, whether TAP is included alongside
it (needed for bootstrap flows) — the built-in "Phishing-resistant MFA" strength deliberately
excludes TAP.

**7. Verify service principals exist for first-party apps used during bootstrap**
```powershell
$ids = "1b912ec3-a9dd-4c4d-a53e-76aa7adb28d7","ea890292-c8c8-4433-b5ea-b09d0668e1a6",
       "0000000c-0000-0000-c000-000000000000","8c59ead7-d703-4a27-9e55-c96a0054c8d2",
       "19db86c3-b2b9-44cc-b339-36da233a3be2","00000002-0000-0000-c000-000000000000"
foreach ($id in $ids) {
    $sp = Get-MgServicePrincipal -Filter "appId eq '$id'" -ErrorAction SilentlyContinue
    [PSCustomObject]@{ AppId = $id; Exists = [bool]$sp; DisplayName = $sp.DisplayName }
}
```

---

## Troubleshooting Steps by Phase

### Phase 1 — Policy / Profile Misconfiguration

1. Confirm Fido2 policy `state: enabled` (Validation Step 1)
2. Confirm the specific profile scoped to the affected user has the expected attestation and
   passkey-type settings (Validation Step 2) — a profile built for admins (attestation-enforced,
   device-bound-only) accidentally scoped to all users will silently block synced passkeys tenant-wide
3. Confirm the user isn't in an Excluded group on the base policy (Validation Step 3)
4. If a save fails with a size-limit style error, check total profile count and AAGUID list length
   against the 20 KB ceiling

### Phase 2 — First-Passkey Bootstrap / Registration Loop

1. Identify whether a CA policy requires phishing-resistant MFA for the
   `urn:user:registersecurityinfo` user action or "All resources" without excluding it
2. Build (or verify) the three-policy TAP bootstrap pattern: exclude registration + bootstrap apps
   from the strict phishing-resistant policy, then require a custom "Onboard Passkey" strength
   (TAP one-time-use + Passkey (FIDO2) + WHfB) scoped to registration and the bootstrap app list
3. Confirm TAP is configured for one-time use only — a reusable TAP is silently rejected by any
   authentication strength that lists TAP as an allowed combination requiring one-time use
4. Confirm service principals exist for all six first-party bootstrap apps (Validation Step 7) —
   missing SPs (most commonly "My Signins") cause the loop to persist even with correct CA policies
5. Allow 10+ minutes for CA policy propagation before re-testing — this is the single most common
   false-negative in passkey bootstrap troubleshooting

### Phase 3 — Registered Passkey Fails at Sign-In (Not Registration)

1. Pull the user's registered method AAGUID (Validation Step 4)
2. Compare against the currently active key-restriction list on their scoped profile(s) — a
   removed AAGUID silently breaks sign-in for previously-working passkeys without any user-facing
   change at registration time
3. If cross-device (QR/Bluetooth): confirm Bluetooth + internet on both devices, and confirm
   attestation is not enforced (cross-device flows do not support attested registration or
   authentication)
4. If the user changed their device PIN or biometric type (Android in particular): the passkey is
   invalidated by design — this is not a bug, direct the user to re-enroll

### Phase 4 — Guest / Cross-Tenant / Region Edge Cases

1. Confirm the account type — internal or external guest users cannot register FIDO2 credentials
   at all; this is a hard product limitation, not a config gap
2. For Microsoft Azure operated by 21Vianet (China) tenants: passkeys are unsupported entirely;
   Authenticator passkey sign-in to *other* (non-21Vianet) orgs while physically in China is
   supported on iOS only
3. For UPN changes: confirm the passkey predates the rename — if so, the only remediation is
   delete + re-register, there is no in-place update path

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full passkey profile rollout with admin/standard-user split</summary>

**Goal:** enforce device-bound + attested passkeys for admins/execs, allow synced passkeys for
everyone else, matching Microsoft's own recommendation.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.AuthenticationMethod","Group.Read.All"

# Step 1 — confirm dynamic admin/standard groups exist (create if not, based on your naming convention)
# Example filter for an admin-naming convention "adm-*":
# (userPrincipalName -match "^adm-")

# Step 2 — opt in to passkey profiles via the admin center banner (one-way, no Graph equivalent
# as of this writing — profile CRUD is admin-center-only for full fidelity)
# Entra ID > Security > Authentication methods > Policies > Passkey (FIDO2) > opt-in banner

# Step 3 — configure Default passkey profile: Passkey types = Synced, Enforce attestation = No
#          Target: All users (baseline)

# Step 4 — configure "Admin — Attested Device-Bound" profile:
#          Passkey types = Device-bound, Enforce attestation = Yes, Key restrictions = Disabled
#          Target: <Admin dynamic group>

# Step 5 — verify via Graph that the base policy reflects enabled state
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Fido2" |
    Select-Object state, isSelfServiceRegistrationAllowed
```

**Rollback:** Remove the admin group's target assignment from the attested profile — those users
fall back to whatever the Default passkey profile allows (do not delete the Default profile itself,
it cannot be removed while any target is assigned).

</details>

<details><summary>Playbook 2 — Build the TAP bootstrap flow for first-time passkey onboarding</summary>

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess","Policy.ReadWrite.AuthenticationMethod","Application.ReadWrite.All"

# Step 1 — ensure TAP is one-time-use only
$tapBody = @{
    "@odata.type" = "#microsoft.graph.temporaryAccessPassAuthenticationMethodConfiguration"
    state = "enabled"
    isUsableOnce = $true
} | ConvertTo-Json
Invoke-MgGraphRequest -Method PATCH `
    -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass" `
    -Body $tapBody

# Step 2 — ensure service principals exist for first-party bootstrap apps (most commonly missing: My Signins)
New-MgServicePrincipal -AppId "19db86c3-b2b9-44cc-b339-36da233a3be2" -ErrorAction SilentlyContinue

# Step 3 — create the custom authentication strength "Onboard Passkey"
# (TAP one-time-use + Passkey (FIDO2) + Windows Hello for Business)
# Admin center: Authentication methods > Authentication strengths > New authentication strength
# — no stable Graph-only creation path recommended for authentication strength combinations
# as of this writing; use the admin center for the strength definition itself.

# Step 4 — build/adjust the three Conditional Access policies (admin center or Graph):
#   Policy A: "Require Phishing-resistant MFA" — All resources, EXCLUDE "Register security
#             information" user action AND exclude the 6 bootstrap app IDs
#   Policy B: "Onboard Passkey — Registration" — targets "Register security information" user
#             action, requires "Onboard Passkey" strength
#   Policy C: "Onboard Passkey — Bootstrap Apps" — targets the 6 bootstrap app IDs, requires
#             "Onboard Passkey" strength
```

**Rollback:** Disable policies B and C once the target population has completed registration;
re-enable policy A without the app-ID exclusions so phishing-resistant MFA is enforced uniformly
going forward.

</details>

<details><summary>Playbook 3 — Audit and remediate stale AAGUID key restrictions</summary>

```powershell
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All","User.Read.All"

# Pull every registered FIDO2 method's AAGUID tenant-wide, compare against a known-good allow-list
$knownGoodAaguids = @(
    "de1e552d-db1d-4423-a619-566b625cdc84",  # Microsoft Authenticator (Android)
    "90a3ccdf-635c-4729-a248-9b709135078f"   # Microsoft Authenticator (iOS)
    # add your organization's approved security key / vault AAGUIDs here
)

$users = Get-MgUser -All -Filter "accountEnabled eq true" -Property Id,UserPrincipalName
$orphaned = foreach ($u in $users) {
    $methods = Get-MgUserAuthenticationFido2Method -UserId $u.Id -ErrorAction SilentlyContinue
    foreach ($m in $methods) {
        if ($m.AaGuid -notin $knownGoodAaguids) {
            [PSCustomObject]@{ UPN = $u.UserPrincipalName; AaGuid = $m.AaGuid; MethodId = $m.Id; Created = $m.CreatedDateTime }
        }
    }
}
$orphaned | Export-Csv ".\Orphaned-Passkey-AAGUIDs.csv" -NoTypeInformation
```

**In admin center:** either add the discovered AAGUID(s) to the profile's allow-list (if the
provider is legitimately approved) or, if genuinely unwanted, coordinate directly with affected
users before removing — removing an AAGUID a user is actively relying on for sign-in locks them out
without warning.

**Rollback:** N/A — this playbook is read-only/reporting; the actual allow-list edit is a manual,
reviewed admin center change, not a scripted mutation.

</details>

---

## Evidence Pack

```powershell
# Passkeys (FIDO2) Evidence Collector — run with Graph connected
# Scopes: Policy.Read.All, UserAuthenticationMethod.Read.All, AuditLog.Read.All,
#         Policy.Read.ConditionalAccess (or equivalent read role)
param(
    [Parameter(Mandatory)][string]$UserPrincipalName
)

Connect-MgGraph -Scopes "Policy.Read.All","UserAuthenticationMethod.Read.All","AuditLog.Read.All"

$out = ".\Passkey-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

# 1. Tenant Fido2 policy
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Fido2" |
    ConvertTo-Json -Depth 6 | Out-File "$out\fido2-policy.json"

# 2. User's registered passkey methods
Get-MgUserAuthenticationFido2Method -UserId $UserPrincipalName |
    Select-Object Id, DisplayName, AaGuid, AttestationLevel, CreatedDateTime |
    Export-Csv "$out\user-fido2-methods.csv" -NoTypeInformation

# 3. Recent sign-in activity (MFA satisfaction, CA status)
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$UserPrincipalName'" -Top 10 |
    Select-Object CreatedDateTime, AppDisplayName, Status, AuthenticationRequirement, ConditionalAccessStatus |
    Export-Csv "$out\recent-signins.csv" -NoTypeInformation

# 4. Conditional Access policies referencing phishing-resistant strength or registration action
Get-MgIdentityConditionalAccessPolicy |
    Where-Object {
        $_.GrantControls.AuthenticationStrength.DisplayName -match "Phishing" -or
        $_.Conditions.Applications.IncludeUserActions -contains "urn:user:registersecurityinfo"
    } |
    Select-Object DisplayName, State, Conditions, GrantControls |
    ConvertTo-Json -Depth 6 | Out-File "$out\relevant-ca-policies.json"

# 5. Authentication strength definitions
Get-MgIdentityConditionalAccessAuthenticationStrengthPolicy |
    Select-Object DisplayName, AllowedCombinations |
    Export-Csv "$out\auth-strengths.csv" -NoTypeInformation

# 6. TAP configuration
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass" |
    ConvertTo-Json | Out-File "$out\tap-policy.json"

Compress-Archive -Path "$out\*" -DestinationPath "$out.zip"
Write-Host "Evidence pack: $out.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# 1. Tenant Fido2 (Passkeys) policy state
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Fido2"

# 2. User's registered passkey methods
Get-MgUserAuthenticationFido2Method -UserId "<user@contoso.com>"

# 3. Delete a user's passkey (admin-initiated)
Remove-MgUserAuthenticationFido2Method -UserId "<user@contoso.com>" -Fido2AuthenticationMethodId "<methodId>"

# 4. Recent sign-in / MFA satisfaction check
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<user@contoso.com>'" -Top 5

# 5. CA policies touching the registration user action
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.Conditions.Applications.IncludeUserActions -contains "urn:user:registersecurityinfo" }

# 6. Authentication strength definitions (check TAP + Passkey combinations)
Get-MgIdentityConditionalAccessAuthenticationStrengthPolicy | Select-Object DisplayName, AllowedCombinations

# 7. TAP one-time-use setting
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass"

# 8. Create service principal for a missing first-party bootstrap app (e.g. My Signins)
New-MgServicePrincipal -AppId "19db86c3-b2b9-44cc-b339-36da233a3be2"

# 9. All users without any registered passkey
Get-MgUser -All -Filter "accountEnabled eq true" | ForEach-Object {
    $m = Get-MgUserAuthenticationFido2Method -UserId $_.Id -ErrorAction SilentlyContinue
    if (-not $m) { $_.UserPrincipalName }
}

# 10. Enable Fido2 policy tenant-wide
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Fido2" `
    -Body '{"@odata.type":"#microsoft.graph.fido2AuthenticationMethodConfiguration","state":"enabled"}'

# 11. Check whether a specific AAGUID belongs to Microsoft Authenticator
#     Android: de1e552d-db1d-4423-a619-566b625cdc84   iOS: 90a3ccdf-635c-4729-a248-9b709135078f

# 12. List all conditional access authentication strengths that include fido2
Get-MgIdentityConditionalAccessAuthenticationStrengthPolicy | Where-Object { $_.AllowedCombinations -contains "fido2" }

# 13. Verify self-service registration is allowed
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Fido2").isSelfServiceRegistrationAllowed

# 14. Check a device's join type before assuming WHfB vs. passkey scope
dsregcmd /status | Select-String "AzureAdJoined","DomainJoined"
```

---

## 🎓 Learning Pointers

- **Passkeys are phishing-resistant by cryptographic construction, not policy** — origin-bound key
  pairs mean a credential created for the real Microsoft login page cannot be replayed against a
  lookalike phishing site, unlike passwords, SMS, or push-based MFA which can all be relayed or
  socially engineered. [Passkeys (FIDO2) authentication method](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-passkeys-fido2)
- **The bootstrap problem is the hardest part of a passkey rollout, and it's an identity/CA design
  problem, not a passkey problem** — requiring phishing-resistant MFA everywhere before any user has
  registered a phishing-resistant credential creates a chicken/egg lockout. Budget real design time
  for the TAP-scoped onboarding flow, including the undocumented first-party-app exclusions many
  practitioners have hit in production. [Community deep-dive](https://agderinthe.cloud/2026/02/26/passkey-onboarding-in-entra-what-microsoft-doesnt-tell-you/)
- **Synced passkeys trade attestation for reusability — that's a deliberate, permanent trade-off**,
  not a temporary preview limitation. Decide per-population (admins vs. standard users) rather than
  a single tenant-wide stance, per Microsoft's own published guidance.
- **AAGUID restriction is real security for attested (device-bound) passkeys and only a policy
  guideline for synced ones** — don't present AAGUID allow-listing to stakeholders as a hard control
  if synced passkeys are in scope; the FIDO2 spec itself makes that guarantee impossible for synced
  types. [Entra ID Synced Passkeys and security considerations](https://hybridbrothers.com/posts/entra-synced-passkeys)
- **There is no passkey expiration or automatic lifecycle today** — per Microsoft's own FAQ,
  monitoring and manual lifecycle hygiene (sign-in logs, audit logs, periodic AAGUID review) is the
  only control surface until native lifecycle management ships. [Passkey FAQs](https://learn.microsoft.com/en-us/entra/identity/authentication/passkey-faq)
- **Graph API provisioning of FIDO2 security keys is in preview** — organizations can build custom
  provisioning clients (`creationOptions` → provision via CTAP → register), useful for high-volume
  onboarding (e.g., new-hire kitting), but treat it as preview-grade for production rollout planning.
