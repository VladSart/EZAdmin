# Conditional Access — Authentication Strengths Reference Runbook (Mode A: Deep Dive)
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
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**Applies to:** Microsoft Entra ID Conditional Access grant control "Require authentication strength," built-in and custom strength policies, Entra ID P1/P2 (custom strengths and Authentication Context both require P1 at minimum; risk-based combinations benefit from P2 Identity Protection signal).

**Role required:** Authentication Policy Administrator or Conditional Access Administrator (create/edit strengths and policies); Security Reader (view/audit).

**Does not cover:** Authentication Context claim tagging on resources (SharePoint sensitivity labels, custom apps emitting `c1`–`c25`) — that mechanism decides *when* a step-up fires and is a distinct configuration surface from strengths themselves, which define *what satisfies* the challenge. Device Filters (see `CA-Filters-A.md`). Named Locations (see `Named-Locations-A.md`). Token Protection / PoP token binding (see `TokenProtection-A.md`) — a related but architecturally separate anti-replay mechanism that operates after an authentication strength challenge is satisfied, not as part of it.

**What is an Authentication Strength?**
Authentication strength is a Conditional Access grant control that lets an admin require a specific *combination* of authentication methods, rather than the older binary "Require multifactor authentication" toggle. It answers a more precise question than legacy MFA: not just "did the user do a second factor," but "did the user do a second factor from this specific, admin-approved set — one strong enough to resist a given threat model (e.g., phishing, SIM-swap, MFA fatigue)."

---

## How It Works

<details><summary>Full architecture</summary>

### The three built-in strengths (immutable)

| Strength | Satisfied by (any one of) |
|----------|---------------------------|
| **Multifactor authentication** | Any two-factor combination Entra supports today (password+SMS, password+push, password+OTP, etc.) — functionally equivalent to the legacy "Require MFA" grant control |
| **Passwordless MFA** | FIDO2 security key, Windows Hello for Business, Certificate-based authentication (Multi-Factor), Microsoft Authenticator (passwordless phone sign-in) |
| **Phishing-resistant MFA** | FIDO2 security key, Windows Hello for Business, Certificate-based authentication (Multi-Factor), `federatedMultiFactor` (only if the federated IdP is explicitly trusted for MFA — see Fix 4 in the Mode B runbook) |

Built-in strengths **cannot be edited or deleted** — the Graph API and portal both reject modification attempts. If a built-in strength almost fits but not exactly, clone its concept into a **custom strength**.

### Custom strengths

An admin builds a custom strength as a named list of **allowed combinations**, where each combination is either:
- A single method that is inherently strong enough alone (e.g., `fido2`), or
- A comma-joined set of methods that together satisfy the strength (e.g., `password,softwareOath`)

```json
{
  "displayName": "Contoso High-Assurance MFA",
  "allowedCombinations": [
    "fido2",
    "windowsHelloForBusiness",
    "x509CertificateMultiFactor",
    "password,microsoftAuthenticatorPush"
  ]
}
```

Each string in `allowedCombinations` is evaluated independently — the user satisfies the strength if **any one** combination in the list matches what they actually did during the sign-in.

### Authentication method values (the vocabulary used in `allowedCombinations`)

| Value | Meaning |
|-------|---------|
| `password` | Password (first factor only, never alone in a combination unless paired) |
| `voice` | Phone call verification |
| `sms` | Text message verification |
| `softwareOath` | Software OTP (Authenticator app time-based code, or third-party TOTP) |
| `hardwareOath` | Hardware OTP token |
| `fido2` | FIDO2 security key |
| `windowsHelloForBusiness` | WHfB (Key Trust, Certificate Trust, or Cloud Kerberos Trust deployment models all count) |
| `x509CertificateSingleFactor` | Certificate-based auth, single-factor |
| `x509CertificateMultiFactor` | Certificate-based auth, multi-factor (cert issuance itself required proof of a strong credential) |
| `temporaryAccessPassOneTime` | Single-use TAP (bootstrap only — see gotcha below) |
| `temporaryAccessPassMultiUse` | Multi-use TAP |
| `email` | Email OTP (guest/B2B scenarios) |
| `federatedSingleFactor` / `federatedMultiFactor` | Claims asserted by a federated IdP (AD FS or third-party SAML/WS-Fed) |
| `deviceBasedPush` | Microsoft Authenticator passwordless phone sign-in |
| `microsoftAuthenticatorPush` | Standard Authenticator app push notification |

**Gotcha — Temporary Access Pass is deliberately excluded from strong strengths.** Even though a TAP is "phishing-resistant" in the sense that it can't be phished over a fake login page the same way a password can, Microsoft does not permit `temporaryAccessPassOneTime`/`temporaryAccessPassMultiUse` to appear as a satisfying method inside the built-in Passwordless MFA or Phishing-resistant MFA strengths, and including them in a *custom* strength intended for ongoing access is against Microsoft's guidance — TAP exists to *bootstrap* registration of a real method, not to serve as a standing credential.

### Evaluation timing and claims challenge

Authentication strength is enforced via a **claims challenge**: when a CA policy requires a strength the current token doesn't satisfy, Entra returns a `claims` challenge to the client, which must re-authenticate and present a qualifying method. This is the same underlying mechanism used for Authentication Context step-up. It means:
- Enforcement is evaluated **per token request**, not persistently — a session that already has a satisfying claim in its token will not be re-prompted until the token expires or a resource requiring a *different, unsatisfied* strength is accessed.
- **Session lifetime and Continuous Access Evaluation (CAE) both interact here.** Without CAE, a satisfied strength claim can persist for the life of the refresh token (up to the tenant's configured lifetime). With CAE, Entra can force a resource to re-evaluate near-real-time, but a strength that was already satisfied earlier in the session generally is not re-challenged unless a policy specifically targets a resource the token hasn't touched yet.

</details>

---

## Dependency Stack

```
Entra ID Conditional Access Policy Engine
    │
    ├──► Grant Control: "Require authentication strength"
    │         │
    │         └──► References a Authentication Strength Policy object (built-in or custom)
    │                    │
    │                    └──► allowedCombinations[] — list of method-value strings/comma-sets
    │
    └──► Evaluated against: methods used by the user THIS sign-in session
              │
              ├── Method availability depends on per-user registration:
              │       ├── FIDO2 — Get-MgUserAuthenticationMethod (fido2AuthenticationMethod)
              │       ├── WHfB — device-bound, provisioned via Intune/AAD join, not portable
              │       ├── CBA (Multi-Factor) — requires CBA enabled tenant-wide + cert issued
              │       └── federatedMultiFactor — requires domain federation config trust setting
              │
              └── Claims challenge mechanism (shared with Authentication Context)
                        └── Token refresh forces re-auth with qualifying method, or hard block if none available
```

**Key dependency:** An authentication strength is only as strong as the weakest method a user can actually invoke. If a "Phishing-resistant MFA" policy is enforced but a user has zero qualifying methods registered (no FIDO2 key issued, no WHfB provisioned, no CBA cert), the result is a hard lockout — there is no automatic fallback to a weaker method. Rollout order matters: register methods for the population *before* enforcing the strength.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|--------------------|-------|
| User permanently blocked, no prompt to add a new method | No qualifying method registered and no self-service registration path enabled | `Get-MgUserAuthenticationMethod`; check Authentication Methods Policy registration campaign settings |
| Custom strength never satisfied by anyone | `allowedCombinations` built with a syntax error (e.g., space instead of comma) | `Get-MgPolicyAuthenticationStrengthPolicy` — inspect raw combination strings |
| Works for password users, not FIDO2 users | FIDO2 key restricted by AAGUID allow-list (Key Restriction Policy) | Entra → Security → Authentication methods → FIDO2 → Key Restrictions |
| WHfB users blocked on new device | WHfB credential is per-device; new/reimaged device has no WHfB key yet | Check device provisioning status; may need re-registration |
| Federated users always re-challenged for phishing-resistant | `federatedIdpMfaBehavior` not set to trust the federated MFA claim | `Get-MgDomainFederationConfiguration` |
| Guest/B2B users can never satisfy a custom strength | Combination list omits `email`/guest-compatible methods, or home-tenant MFA claims aren't trusted (cross-tenant access settings) | Review Cross-Tenant Access Settings inbound trust for MFA claims |
| Policy satisfied unexpectedly by a weak method | Overlapping CA policy grants access via a separate, less strict control (multiple policies evaluate independently — the weakest satisfied one still counts if a *different* policy matched with a weaker requirement) | Review all CA policies scoped to the same users/app for conflicting grant strength |
| Certificate-based auth users failing MF strength | Cert issued as single-factor (`x509CertificateSingleFactor`) rather than multi-factor — depends on the issuing CA's policy mapping in Entra CBA config | Entra → Security → Authentication methods → Certificate-based authentication → check certificate authority mapping (policyOID) |

---

## Validation Steps

**1. Enumerate all authentication strength policies (built-in + custom)**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All"

Get-MgPolicyAuthenticationStrengthPolicy | Select-Object Id, DisplayName, PolicyType, RequirementsSatisfied
```

**2. Inspect a specific strength's allowed combinations**
```powershell
$strength = Get-MgPolicyAuthenticationStrengthPolicy -AuthenticationStrengthPolicyId "<id>"
$strength.AllowedCombinations
```

**3. Find every CA policy that references authentication strength grant controls**
```powershell
Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.GrantControls.AuthenticationStrength } |
    Select-Object DisplayName, State,
        @{N='StrengthId';E={$_.GrantControls.AuthenticationStrength.Id}}
```

**4. Check a user's registered methods against a strength's requirements**
```powershell
$upn = "<user@domain.com>"
Get-MgUserAuthenticationMethod -UserId $upn |
    ForEach-Object { $_.AdditionalProperties['@odata.type'] -replace '#microsoft.graph.', '' }
```

**5. Tenant-wide registration coverage report for phishing-resistant methods**
```powershell
Connect-MgGraph -Scopes "Reports.Read.All"

Get-MgReportAuthenticationMethodUserRegistrationDetail -All |
    Select-Object UserPrincipalName, IsMfaRegistered,
        @{N='MethodsRegistered';E={$_.MethodsRegistered -join ', '}} |
    Where-Object { $_.MethodsRegistered -notmatch 'fido2|windowsHelloForBusiness|x509CertificateMultiFactor' }
```
This surfaces the population that will fail a phishing-resistant enforcement today — run this *before* flipping any such policy to enforced.

**6. Check federation MFA trust for a federated domain**
```powershell
Get-MgDomainFederationConfiguration -DomainId "<domain.com>" | Select-Object IssuerUri, FederatedIdpMfaBehavior
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Confirm the Policy and Strength Definition
1. Identify the exact CA policy and the strength ID it references.
2. Pull `allowedCombinations` for that strength — confirm it isn't empty and contains valid method-value strings.
3. Confirm the policy's `state` (enabled / report-only / disabled) matches what's expected.

### Phase 2: Confirm the User's Method Registration
1. `Get-MgUserAuthenticationMethod` for the affected user.
2. Cross-reference registered method types against the strength's `allowedCombinations`.
3. For device-bound methods (WHfB), confirm the credential exists on the device actually being used — not just "somewhere."

### Phase 3: Confirm the Sign-In Actually Used a Qualifying Method
1. Pull the sign-in log event; check `authenticationDetails` for the method(s) actually presented.
2. A user can *own* a qualifying method and still fail if they didn't use it this session — Entra generally re-prompts for it automatically, but some client/browser flows can silently fall back.

### Phase 4: Confirm Special-Case Population Handling
1. Federated users: verify `federatedIdpMfaBehavior`.
2. Guest/B2B users: verify Cross-Tenant Access Settings trust inbound MFA claims, or that the resource tenant's strength allows guest-compatible methods.
3. Break-glass/service accounts: verify explicit exclusion from any phishing-resistant enforcement (by design, these accounts should not depend on device-bound credentials).

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Staged rollout of a new phishing-resistant strength policy</summary>

Use when: piloting a move to phishing-resistant MFA for a client tenant.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess","Policy.ReadWrite.AuthenticationMethod"

# Step 1 — audit current registration coverage (see Validation Step 5) before doing anything else

# Step 2 — create the policy in report-only mode, scoped to a pilot group first
$pilotGroupId = "<pilotGroupId>"
$strengthId = (Get-MgPolicyAuthenticationStrengthPolicy | Where-Object DisplayName -eq "Phishing-resistant MFA").Id

$policyBody = @{
    displayName = "Pilot - Require Phishing-Resistant MFA"
    state = "enabledForReportingButNotEnforced"
    conditions = @{
        users = @{ includeGroups = @($pilotGroupId) }
        applications = @{ includeApplications = @("All") }
    }
    grantControls = @{
        authenticationStrength = @{ id = $strengthId }
    }
}
New-MgIdentityConditionalAccessPolicy -BodyParameter $policyBody

# Step 3 — after 1-2 weeks of report-only data with zero unexpected failures for the pilot group,
# flip state to "enabled"
```

**Rollback:** set `state = "disabled"` on the policy, or widen `excludeGroups` back out if a subset needs more time.

</details>

<details>
<summary>Playbook 2 — Build a custom strength for a client with mixed method inventory</summary>

Use when: the built-in strengths don't match a client's actual deployed methods (e.g., they use hardware OATH tokens as their "strong" method, not FIDO2).

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.AuthenticationMethod"

$body = @{
    displayName = "Contoso Strong MFA (Hardware Token Compatible)"
    description = "Phishing-resistant methods plus hardware OATH for users without FIDO2/WHfB"
    allowedCombinations = @(
        "fido2",
        "windowsHelloForBusiness",
        "x509CertificateMultiFactor",
        "hardwareOath,password"
    )
}
New-MgPolicyAuthenticationStrengthPolicy -BodyParameter $body
```

Then reference the returned `Id` in a CA policy's `grantControls.authenticationStrength`.

</details>

<details>
<summary>Playbook 3 — Bulk method-registration gap remediation before enforcement</summary>

Use when: the coverage report (Validation Step 5) shows a large population without qualifying methods.

```powershell
Connect-MgGraph -Scopes "UserAuthenticationMethod.ReadWrite.All","Reports.Read.All"

$gapUsers = Get-MgReportAuthenticationMethodUserRegistrationDetail -All |
    Where-Object { $_.MethodsRegistered -notmatch 'fido2|windowsHelloForBusiness|x509CertificateMultiFactor' }

foreach ($u in $gapUsers) {
    # Issue a one-time TAP so each user can bootstrap FIDO2/WHfB registration themselves
    New-MgUserAuthenticationTemporaryAccessPassMethod -UserId $u.UserPrincipalName -BodyParameter @{
        lifetimeInMinutes = 60
        isUsableOnce = $true
    }
    Write-Host "TAP issued for $($u.UserPrincipalName)"
}
```
Communicate the TAP out-of-band (never via the same channel being secured) with instructions to register a FIDO2 key or set up WHfB, then let the policy enforce once coverage is confirmed.

</details>

<details>
<summary>Playbook 4 — Enable trusted federated MFA for phishing-resistant strength</summary>

Use when: AD FS-federated users need to satisfy phishing-resistant MFA without migrating off federation immediately.

```powershell
Connect-MgGraph -Scopes "Domain.ReadWrite.All"

Update-MgDomainFederationConfiguration -DomainId "<domain.com>" -BodyParameter @{
    federatedIdpMfaBehavior = "acceptIfMfaDoneByFederatedIdp"
}
```
**Prerequisite:** the AD FS relying party trust must emit `authnmethodsreferences` with a value Entra recognizes as MFA (e.g., a claim rule asserting `http://schemas.microsoft.com/claims/multipleauthn` when AD FS itself enforced Windows Hello for Business or a hardware token). Validate with a test sign-in and inspect the resulting sign-in log's `authenticationDetails`.

**Rollback:**
```powershell
Update-MgDomainFederationConfiguration -DomainId "<domain.com>" -BodyParameter @{
    federatedIdpMfaBehavior = "rejectMfaByFederatedIdp"
}
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Conditional Access authentication strength evidence for troubleshooting/escalation
.NOTES     Requires Microsoft.Graph modules; run with Policy.Read.All, UserAuthenticationMethod.Read.All, Reports.Read.All
#>
Connect-MgGraph -Scopes "Policy.Read.All","UserAuthenticationMethod.Read.All","Reports.Read.All","AuditLog.Read.All"

$outFile = "C:\Temp\AuthStrength-Evidence-$(Get-Date -Format yyyyMMdd-HHmm).txt"
New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null

{
    "=== Authentication Strength Evidence — $(Get-Date) ==="

    "`n--- All Authentication Strength Policies ---"
    Get-MgPolicyAuthenticationStrengthPolicy | ForEach-Object {
        "Name: $($_.DisplayName) | Type: $($_.PolicyType) | Id: $($_.Id)"
        "  Allowed Combinations: $($_.AllowedCombinations -join '; ')"
        ""
    }

    "`n--- CA Policies Referencing Authentication Strength ---"
    Get-MgIdentityConditionalAccessPolicy -All |
        Where-Object { $_.GrantControls.AuthenticationStrength } |
        ForEach-Object {
            "Policy: $($_.DisplayName) | State: $($_.State) | StrengthId: $($_.GrantControls.AuthenticationStrength.Id)"
        }

    "`n--- Registration Coverage Gaps (no phishing-resistant method) ---"
    Get-MgReportAuthenticationMethodUserRegistrationDetail -All |
        Where-Object { $_.MethodsRegistered -notmatch 'fido2|windowsHelloForBusiness|x509CertificateMultiFactor' } |
        Select-Object -First 50 UserPrincipalName

} | ForEach-Object { $_ } | Out-File $outFile -Encoding UTF8

Write-Host "Evidence saved: $outFile" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| List all authentication strength policies | `Get-MgPolicyAuthenticationStrengthPolicy` |
| Get one strength's allowed combinations | `(Get-MgPolicyAuthenticationStrengthPolicy -AuthenticationStrengthPolicyId <id>).AllowedCombinations` |
| Create a custom strength | `New-MgPolicyAuthenticationStrengthPolicy -BodyParameter $body` |
| Update a custom strength's combinations | `Update-MgPolicyAuthenticationStrengthPolicy -AuthenticationStrengthPolicyId <id> -BodyParameter $body` |
| Delete a custom strength | `Remove-MgPolicyAuthenticationStrengthPolicy -AuthenticationStrengthPolicyId <id>` |
| Find CA policies using auth strength | `Get-MgIdentityConditionalAccessPolicy -All \| Where { $_.GrantControls.AuthenticationStrength }` |
| Check a user's registered methods | `Get-MgUserAuthenticationMethod -UserId <upn>` |
| Tenant registration coverage report | `Get-MgReportAuthenticationMethodUserRegistrationDetail -All` |
| Issue a bootstrap TAP | `New-MgUserAuthenticationTemporaryAccessPassMethod -UserId <upn> -BodyParameter @{lifetimeInMinutes=60;isUsableOnce=$true}` |
| Check federation MFA trust | `Get-MgDomainFederationConfiguration -DomainId <domain>` |
| Set federation MFA trust | `Update-MgDomainFederationConfiguration -DomainId <domain> -BodyParameter @{federatedIdpMfaBehavior="acceptIfMfaDoneByFederatedIdp"}` |
| Enable report-only on a CA policy | Set `state = "enabledForReportingButNotEnforced"` |

---

## 🎓 Learning Pointers

- **Authentication strength is a grant control, not a condition.** It sits alongside `mfa`, `compliantDevice`, and `domainJoinedDevice` in `grantControls` — but unlike those simple booleans, it points at a whole policy object with its own combination logic. Model it mentally as "MFA, but parameterized." [Authentication strengths concept](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-strengths)

- **Built-in strengths are frozen by design — Microsoft updates them as new phishing-resistant methods ship**, so a "Phishing-resistant MFA" policy created two years ago automatically covers new qualifying methods added since, without any admin action. This is a feature, not a maintenance burden — don't recreate it as a custom strength unless you need a genuinely different combination set. [Built-in vs custom strengths](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-strengths#built-in-authentication-strengths)

- **Registration coverage must be validated before enforcement, every time.** The single most common cause of a phishing-resistant rollout turning into an incident is enabling enforcement before confirming the target population has a qualifying method. Always run the registration-detail report first. [Authentication methods registration report](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-authentication-methods-activity)

- **Authentication Context and Authentication Strength solve different problems and are often confused.** Context decides *which resource/action* triggers a step-up (e.g., "opening this sensitivity-labeled document"); Strength decides *what counts* as satisfying that step-up. A client asking for "extra security on sensitive files" usually needs both configured together. [Authentication context overview](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-cloud-apps#authentication-context)

- **Federated MFA trust is opt-in and easy to overlook during AD FS-to-cloud-native migrations.** If a tenant still has federated domains, phishing-resistant strength requires an explicit `federatedIdpMfaBehavior` setting — it is not inferred automatically from AD FS's own MFA configuration. [Federated MFA trust behavior](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-strengths#authentication-strengths-with-federated-users)

- **Temporary Access Pass is a bootstrap tool, never a standing credential for strong strengths.** Resist the temptation to include `temporaryAccessPassMultiUse` in a custom "strong" strength for convenience — it defeats the phishing-resistance goal and Microsoft explicitly advises against it. [TAP guidance](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-authentication-temporary-access-pass)
