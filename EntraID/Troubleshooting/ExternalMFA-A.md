# Entra ID External MFA (External Authentication Methods) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the OIDC trust handshake and claim-validation model, not just the fix commands.

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

This runbook covers **Entra ID External MFA** — the feature formerly called External Authentication Methods (EAM), now GA under the "External MFA" name — which lets a third-party provider (Cisco Duo being the first widely-deployed integration) satisfy the multifactor authentication leg of a Conditional Access sign-in via an OpenID Connect (OIDC) handshake. Entra ID remains the policy decision point and identity control plane throughout; the external provider only ever supplies a second-factor assertion.

This is architecturally distinct from three other MFA-adjacent topics already covered in this repo: `MFA-A.md`/`-B.md` (Microsoft's own native methods — Authenticator, FIDO2, SMS/voice, TOTP, certificate-based auth, TAP), `Passkeys-A.md`/`-B.md` (passkey/FIDO2 profiles specifically), and Conditional Access custom controls (the legacy, pre-2024 mechanism third-party MFA providers used before this feature existed — still supported in parallel during migration, see below). It is also distinct from B2B/external-user cross-tenant MFA trust (`Security/ConditionalAccess/` covers cross-tenant access settings for guest users trusting a home tenant's MFA claim) — that's a different Entra tenant vouching for MFA already completed elsewhere; External MFA is a non-Entra provider completing MFA on Entra ID's behalf for a user native to this tenant.

**Assumes:**
- Microsoft Graph PowerShell SDK: `Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser`
- Authenticated with `Connect-MgGraph` and `Policy.Read.AuthenticationMethod` (read) or `Policy.ReadWrite.AuthenticationMethod` (write) scopes
- A Conditional Access Administrator or Authentication Policy Administrator role for policy/method configuration; Privileged Role Administrator specifically for granting admin consent to the provider's application
- Entra ID P1 or higher (Conditional Access is a prerequisite for enforcing any MFA requirement)

**Not covered:** the provider-side implementation of an OIDC identity provider (this runbook covers the Entra ID side of the contract only); Conditional Access policy design in general (see `Security/ConditionalAccess/`); native Microsoft MFA methods (see `MFA-A.md`); authentication strength policy design (see `Security/ConditionalAccess/` — noting the hard incompatibility documented below).

---
## How It Works

<details><summary>Full architecture</summary>

### External MFA is a provider registration, not a new authentication method type

Unlike adding a new native method, configuring external MFA registers an **external identity provider** with the tenant's Authentication Methods Policy as an `externalAuthenticationMethodConfiguration` object. Three pieces of metadata anchor the trust:

- **Application ID (`appId`)** — a multitenant (usually) app the provider registered in their own Entra tenant. The customer tenant must grant admin consent to this app.
- **Client ID (`clientId`)** — identifies Entra ID to the provider during the OIDC exchange, nested under `openIdConnectSetting`.
- **Discovery URL (`discoveryUrl`)** — the provider's OIDC discovery endpoint (`.../.well-known/openid-configuration`), which Entra ID fetches and caches to learn the provider's `authorization_endpoint` and `jwks_uri`.

The provider can implement this as one multitenant app shared across all their customers, or one app per customer tenant — a multitenant app reduces per-tenant misconfiguration risk since the provider controls metadata (like reply URLs) centrally.

### The two-role consent gate

Creating and saving the method configuration only requires **Authentication Policy Administrator**. Granting admin consent to the provider's application — without which the method can be saved but never enabled — requires **Privileged Role Administrator**, a materially higher-privilege role. This split is deliberate (consenting to an app that can assert MFA completion on a tenant's behalf is a high-trust action) but is also the single most common "I configured it and it doesn't work" root cause: an admin with only Authentication Policy Administrator can complete every visible step in the UI and still end up with a method stuck in a disabled, unconsentable state.

### The sign-in handshake (OIDC implicit flow)

1. A user completes a first factor (password, or a passwordless method) against an app protected by Entra ID.
2. Entra ID determines a Conditional Access policy requires MFA and the user has external MFA available (and, if system-preferred authentication is enabled, offers it alongside any other registered methods).
3. Entra ID redirects the browser to the provider's `authorization_endpoint` via an HTTP `POST` (chosen specifically to avoid URL-length limits), carrying an `id_token_hint` — a short-lived, already-expired-by-design token identifying the user (`oid`, `tid`, `preferred_username`) that the provider uses only as a hint, never for authentication itself.
4. The provider validates the hint token's signature against Entra ID's own published discovery metadata, performs whatever authentication activity it deems appropriate (push notification, biometric, hardware key, etc.), and constructs a response `id_token` containing `acr` (authentication context class — the factor category satisfied) and `amr` (authentication methods reference — the specific method used) claims.
5. The provider `POST`s the response back to Entra ID's `redirect_uri`. Entra ID validates the token's signature (via the provider's `jwks_uri`), issuer, audience, and — critically — that the `amr` value maps to a **different factor type** than whatever type completed the first factor.
6. If valid, MFA is considered satisfied and the user proceeds; other Conditional Access requirements (device compliance, location, etc.) are still evaluated independently.

Entra ID abandons the entire authentication attempt roughly **5 minutes** after redirecting to the provider — a slow or hung provider-side flow fails as a timeout, not a descriptive error.

### The acr/amr type-mapping validation — the actual "was this really MFA" check

Because External MFA methods are implemented entirely on top of a generic OIDC contract, Entra ID has no visibility into what the provider *actually* did during step 4 — it can only trust the `amr` claim the provider asserts, and cross-checks that claim's declared **factor type** (knowledge / possession / inherence) differs from the type that satisfied the first factor. The supported `amr` values and their type mapping are fixed by Entra ID, not configurable per-provider:

| `amr` value | Type | | `amr` value | Type |
|---|---|---|---|---|
| `otp` | Possession | | `face` | Inherence |
| `sms` | Possession | | `fpt` | Inherence |
| `tel` | Possession | | `iris` | Inherence |
| `hwk` | Possession | | `retina` | Inherence |
| `swk` | Possession | | `vbm` | Inherence |
| `sc` | Possession | | `fido` | Possession* |
| `pop` | Possession | | | |

*FIDO2 is mapped to Possession as its primary security attribute even though some implementations also require biometric confirmation.

A provider whose integration returns an `amr` value Entra ID doesn't recognize, or one that maps to the same type as the user's first factor (almost always Knowledge, since passwords dominate first-factor sign-in), causes Entra ID to reject the sign-in as not satisfying MFA — even though the provider itself reports success on its own side. This is a provider-integration defect, invisible to tenant admins beyond the failed sign-in itself.

### Provider metadata caching and key rollover

Entra ID caches the provider's OIDC discovery metadata — including signing keys from `jwks_uri` — for **24 hours** to avoid a discovery round-trip on every authentication. This has a direct operational consequence for certificate rotation: a provider rotating their signing key must publish **both** the existing and new certificate in `jwks_uri` simultaneously and keep the old one live for at least the cache refresh window (documented guidance: roughly 2 days) before retiring it. A provider that swaps keys atomically (old cert removed the instant the new one is published) will break signature validation for any tenant whose cache hasn't yet refreshed — a transient, self-resolving-within-24-hours failure that looks alarming but requires no tenant-side action once understood.

Separately, the `kid` (Key ID) property in both the JWT header and the JWKS document must be **base64-encoded consistently** between the two — a provider-side encoding mismatch breaks key lookup even when both values are otherwise "correct," and is a documented gotcha specific to this integration pattern.

### Interaction with authentication strengths — a hard incompatibility, not a gap

Authentication strength Conditional Access policies validate against Entra ID's own internal enumeration of recognized method types. External MFA completions do not map into that model at all: **"External MFA methods aren't currently supported with authentication strengths"** is stated directly in Microsoft's documentation, with no roadmap caveat. Any Conditional Access policy using a built-in or custom authentication strength grant control will never accept an external MFA completion, regardless of how the method or provider is configured. This is a design boundary a client's compliance requirements may collide with — if phishing-resistant-only access is mandated for a scope, external-MFA-only users in that scope need a native method issued in addition, not instead.

### Migration from Conditional Access custom controls

Before External MFA existed, providers like Duo integrated via Conditional Access **custom controls** — a different, older extensibility mechanism. Microsoft's documented migration path runs the two in parallel using **mutually exclusive test groups**: one Conditional Access policy retains the custom control grant, a second uses "Require multifactor authentication" and targets external MFA, and a user should only ever be in scope for one of the two at a time. A user caught in both policies simultaneously is redirected to the provider **twice** in the same sign-in attempt — once to satisfy the custom control, once to satisfy the MFA grant — a jarring but non-destructive symptom that's purely a scoping overlap, not a provider or platform fault.

### Registration and reporting

Users register an external MFA method either self-service (Security info → Add sign-in method → External Auth methods) or via a first-sign-in registration wizard, or an admin can register — or deregister, for recovery scenarios — a user's external MFA directly via the admin center or Microsoft Graph (`externalAuthenticationMethod` resource), without the user needing to touch Security info at all. One reporting gap worth flagging to clients: **users relying on external MFA are not included in standard authentication method registration reports** — a tenant-wide "MFA registration coverage" report will systematically undercount a population that's fully covered via an external provider, which can trigger false-alarm compliance findings if not understood ahead of time.

### Platform limitation: Windows 10 OOBE

External MFA is documented as **not supported during Windows 10's Out-of-Box Experience (OOBE)** — a device set up with an external-MFA-only identity can fail to complete initial sign-in. Microsoft has stated no plans to extend support, consistent with Windows 10 being out of support entirely. This is a permanent platform boundary, not a configuration gap — the only fixes are a native-method fallback for OOBE specifically, an offline/local-account OOBE path, or moving to Windows 11.

</details>

---
## Dependency Stack

```
Provider's Entra tenant
  └── Provider registers app (multitenant or per-customer), publishes OIDC discovery doc
        └── Customer tenant: Authentication Policy Administrator creates the external MFA
              method configuration (Name / Client ID / Discovery URL / App ID)
                └── GATE: admin consent to the provider's app
                      ├── Requires Privileged Role Administrator (DIFFERENT role than the
                      │     one that created the method — the #1 real-world blocker)
                      └── Without consent: method saves, cannot be Enabled, no error surfaced
                            └── Method state = Enabled
                                  └── includeTargets / excludeTargets — SEPARATE scope layer
                                      from any Conditional Access policy's own targeting
                                        └── Conditional Access: "Require multifactor
                                            authentication" grant control
                                              (NOT an authentication strength — hard
                                               incompatibility, not a config option)
                                                └── User completes 1st factor
                                                      └── OIDC redirect to provider
                                                          (authorization_endpoint, id_token_hint,
                                                           5-minute abandonment window)
                                                            └── Provider authenticates user
                                                                  └── Provider returns id_token
                                                                      with acr + amr claims
                                                                        └── Entra ID validates:
                                                                            signature (jwks_uri,
                                                                            kid/base64 alignment,
                                                                            24h metadata cache),
                                                                            issuer, audience, nonce,
                                                                            AND amr-type ≠ 1st-
                                                                            factor-type
                                                                              └── MFA satisfied
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Method created but permanently shows `state = disabled` | Admin consent never granted — creator lacked Privileged Role Administrator | Service principal existence for the provider's `appId` |
| Method enabled, consent confirmed, still not offered to a specific user | User (or their group) missing from the method's own `includeTargets`, or explicitly in `excludeTargets` | Method's target scope — separate from CA policy targeting |
| MFA still enforced via a native method even though external MFA is enabled tenant-wide | Conditional Access policy uses an authentication strength grant control, not "Require MFA" | Grant control type on the relevant CA policy |
| User redirected to the provider twice in one sign-in | User is in scope for both a legacy custom-control policy and a new external-MFA policy simultaneously | Overlapping CA policy assignments during migration |
| Sign-in fails with a `kid`/signature validation error, especially after a provider cert rotation | Provider retired the old signing cert before Entra ID's 24h metadata cache refreshed, or `kid` base64 encoding mismatch between JWT header and JWKS | Timing of the provider's key rollover; encoding consistency (provider-side) |
| Provider reports successful authentication, Entra ID still rejects the sign-in as MFA-not-satisfied | Returned `amr` claim unrecognized, or maps to the same factor type as the first factor | Provider's `acr`/`amr` claim values (provider-side integration defect) |
| Windows 10 device fails during initial setup (OOBE) with an external-MFA-only identity | Documented, permanent Windows 10 OOBE incompatibility | OS version/build; not fixable in tenant configuration |
| Tenant-wide MFA registration report shows unexpectedly low coverage | External MFA users are excluded from standard registration reports by design | Cross-reference against the external MFA method's own target list, not the registration report |
| Sign-in appears to hang, then fails after ~5 minutes | Provider-side flow stalled or errored silently; Entra ID abandons the attempt at the 5-minute mark | Provider's own logs/telemetry for the same time window |

---
## Validation Steps

**1. Confirm Graph connection and scope**
```powershell
Connect-MgGraph -Scopes "Policy.Read.AuthenticationMethod"
Get-MgContext | Select-Object Scopes
```
Expected: `Policy.Read.AuthenticationMethod` present (add `Policy.ReadWrite.AuthenticationMethod` for write operations).

**2. Read the full authentication methods policy and isolate external MFA configurations**
```powershell
$policy = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy" -Method GET
$policy.authenticationMethodConfigurations |
    Where-Object { $_.'@odata.type' -eq '#microsoft.graph.externalAuthenticationMethodConfiguration' } |
    Select-Object id, displayName, state, appId, openIdConnectSetting, includeTargets, excludeTargets
```
Expected: One entry per configured provider. `state` must be `enabled`; `openIdConnectSetting.discoveryUrl` and `clientId` must be populated.

**3. Confirm admin consent to the provider's application**
```powershell
Get-MgServicePrincipal -Filter "appId eq '<provider-appId>'" | Select-Object DisplayName, Id, AppId
```
Expected: A service principal object exists. Its absence means consent was never completed regardless of what the method configuration shows.

**4. Confirm Conditional Access grant control type**
```powershell
Get-MgIdentityConditionalAccessPolicy -All |
    Select-Object DisplayName, @{n="GrantControls";e={$_.GrantControls | ConvertTo-Json -Depth 6}} |
    Where-Object { $_.GrantControls -match "authenticationStrength" }
```
Expected: This query surfaces any CA policy using an authentication strength — cross-check whether affected external-MFA-only users fall into scope for any of these; if so, they structurally cannot satisfy that policy via external MFA.

**5. Confirm the discovery endpoint the tenant is actually configured against is reachable and valid**
```powershell
$discoveryUrl = ($policy.authenticationMethodConfigurations |
    Where-Object { $_.'@odata.type' -eq '#microsoft.graph.externalAuthenticationMethodConfiguration' }).openIdConnectSetting.discoveryUrl
Invoke-RestMethod -Uri $discoveryUrl -Method GET | Select-Object issuer, authorization_endpoint, jwks_uri
```
Expected: A valid OIDC discovery document. `issuer` must exactly match the discovery URL's scheme/host/port (no default-port suffix mismatches — Microsoft documents this exact mismatch as a common misconfiguration on the provider side).

---
## Troubleshooting Steps (by phase)

### Phase 1: Method Configuration & Consent

1. Confirm the method exists and read its `state`
2. If `disabled`, check for the provider's service principal (Step 3 above) before assuming it's a deliberate off-switch
3. If consent is missing, escalate internally to a Privileged Role Administrator to complete it — this cannot be done by Authentication Policy Administrator alone

### Phase 2: Targeting

1. Confirm the affected user/group is in the method's `includeTargets` and not in `excludeTargets`
2. Separately confirm the Conditional Access policy requiring MFA actually includes this user — these are two independent scopes that both must resolve to "in scope"

### Phase 3: Grant Control Compatibility

1. Identify every Conditional Access policy the user is subject to for the affected app
2. Confirm none of them use an authentication strength grant control if the user is external-MFA-only
3. If a strength policy is mandatory for compliance reasons, plan a native-method fallback rather than trying to make external MFA satisfy it — it cannot

### Phase 4: OIDC Handshake

1. Validate the discovery document is reachable and internally consistent (issuer/discovery URL pairing)
2. If failures correlate with a recent provider certificate rotation, suspect the 24-hour metadata cache window and the `kid` base64-encoding requirement — escalate to the provider with timing details
3. If the provider confirms successful authentication on their side but Entra ID still rejects it, escalate to the provider to review their returned `acr`/`amr` claim values against Entra ID's supported claim list

### Phase 5: Platform/Client Edge Cases

1. Confirm OS build if the failure is specifically during initial device setup (Windows 10 OOBE)
2. Confirm whether the user is also targeted by a legacy custom-control Conditional Access policy if a double-redirect is reported

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield External MFA Rollout</summary>

Use when: Standing up a new external MFA provider integration for a pilot group.

```powershell
# Step 1: Confirm the discovery endpoint before configuring anything in Entra ID
Invoke-RestMethod -Uri "<provider-discovery-url>" | Select-Object issuer, authorization_endpoint, jwks_uri

# Step 2: Create the method configuration (Authentication Policy Administrator)
$body = @{
    "@odata.type" = "#microsoft.graph.externalAuthenticationMethodConfiguration"
    displayName   = "<Provider Display Name>"   # cannot be changed after creation
    appId         = "<provider-appId>"
    openIdConnectSetting = @{
        clientId     = "<provider-client-id>"
        discoveryUrl = "<provider-discovery-url>"
    }
    state = "disabled"   # start disabled until consent is confirmed
    includeTargets = @(
        @{ targetType = "group"; id = "<pilot-group-object-id>" }
    )
}
Invoke-MgGraphRequest -Method POST `
  -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations" `
  -Body $body

# Step 3 (as Privileged Role Administrator): grant admin consent to the provider's app in
# the Entra admin center (Authentication methods > select method > grant consent), or via
# Microsoft Graph app-role/oauth2PermissionGrant flows if automating end-to-end.

# Step 4: Once consent shows granted, enable the method
$patchBody = @{ state = "enabled" }
Invoke-MgGraphRequest -Method PATCH `
  -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/<method-id>" `
  -Body $patchBody

# Step 5: Create a parallel Conditional Access policy scoped to the same pilot group using
# grant control "Require multifactor authentication" (never an authentication strength).

# Step 6: Have a pilot user register via https://mysignins.microsoft.com/security-info and
# complete a test sign-in before expanding scope.
```

**Rollback:** Set `state` back to `disabled` and remove the pilot group from `includeTargets`; delete the method configuration entirely if abandoning the integration.

</details>

<details><summary>Playbook 2 — Custom Control → External MFA Migration</summary>

Use when: Moving an existing legacy custom-control integration (e.g., an older Duo Conditional Access custom control deployment) to native external MFA without service disruption.

```
Step 1: Configure and fully validate the external MFA method per Playbook 1 against a
        small test group BEFORE touching the existing custom-control policy at all.

Step 2: Create a NEW Conditional Access policy with grant control "Require multifactor
        authentication," scoped ONLY to the same test group. Do not modify the existing
        custom-control policy yet.

Step 3: Confirm the test group is explicitly EXCLUDED from the legacy custom-control
        policy (or the custom-control policy is scoped to exclude anyone now in the new
        policy) — this exclusivity is what prevents the double-redirect symptom.

Step 4: Validate test-group sign-ins end-to-end, including from a device/network profile
        representative of the wider population.

Step 5: Incrementally expand both the external MFA method's includeTargets and the new CA
        policy's assignment together, keeping the custom-control policy's scope shrinking
        in lockstep (never overlapping).

Step 6: Once 100% of the target population is migrated and validated, set the legacy
        custom-control policy to Off entirely rather than leaving it in an excluded-but-
        still-enabled state indefinitely.
```

**Rollback:** Re-include affected users in the custom-control policy and exclude them from the external-MFA CA policy to fall back to the legacy integration; the external MFA method itself can remain configured without being removed.

</details>

<details><summary>Playbook 3 — Recovering a User Locked Out of External MFA</summary>

Use when: A user has lost access to their external MFA provider account/device (e.g., lost phone with the provider's push app) and needs an admin-assisted recovery.

```powershell
# Step 1: Confirm the user's current external MFA registration
Get-MgUserAuthenticationExternalAuthenticationMethod -UserId "<user-upn>" -ErrorAction SilentlyContinue

# Step 2: An admin (with appropriate Authentication Administrator-tier role) can delete the
# user's existing external MFA registration to force re-registration on next sign-in:
Remove-MgUserAuthenticationExternalAuthenticationMethod -UserId "<user-upn>" `
  -ExternalAuthenticationMethodId "<registration-id>"

# Step 3: If the user has no other registered method and needs immediate access, an admin
# can temporarily register an alternate native method (e.g., Temporary Access Pass) via
# the admin center to bridge access until the user re-registers with the provider.

# Step 4: Direct the user to https://mysignins.microsoft.com/security-info or the
# in-context registration wizard on next sign-in to complete fresh registration with
# the provider.
```

**Rollback:** N/A — this is itself the recovery action; no destructive tenant-wide change is made.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Entra ID External MFA diagnostic evidence for escalation
.NOTES     Requires Microsoft.Graph.Identity.SignIns module and Policy.Read.AuthenticationMethod scope
#>

param(
    [Parameter(Mandatory=$false)][string]$MethodDisplayName
)

$outputPath = "C:\ExternalMFA_Diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

$policy = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy" -Method GET
$externalMethods = $policy.authenticationMethodConfigurations |
    Where-Object { $_.'@odata.type' -eq '#microsoft.graph.externalAuthenticationMethodConfiguration' }
if ($MethodDisplayName) {
    $externalMethods = $externalMethods | Where-Object { $_.displayName -eq $MethodDisplayName }
}
$externalMethods | ConvertTo-Json -Depth 6 | Out-File "$outputPath\external_mfa_methods.json"

foreach ($m in $externalMethods) {
    try {
        $sp = Get-MgServicePrincipal -Filter "appId eq '$($m.appId)'" -ErrorAction Stop
        [PSCustomObject]@{ MethodName = $m.displayName; AppId = $m.appId; ServicePrincipalExists = $true; ServicePrincipalId = $sp.Id } |
            Export-Csv "$outputPath\consent_status.csv" -NoTypeInformation -Append
    } catch {
        [PSCustomObject]@{ MethodName = $m.displayName; AppId = $m.appId; ServicePrincipalExists = $false; ServicePrincipalId = $null } |
            Export-Csv "$outputPath\consent_status.csv" -NoTypeInformation -Append
    }
}

Get-MgIdentityConditionalAccessPolicy -All |
    Select-Object DisplayName, State, @{n="GrantControls";e={$_.GrantControls | ConvertTo-Json -Depth 6 -Compress}} |
    Export-Csv "$outputPath\ca_policies_grant_controls.csv" -NoTypeInformation

Write-Host "NOTE: acr/amr claim validation failures and kid/signature errors only surface in" -ForegroundColor Yellow
Write-Host "sign-in logs (Entra ID > Sign-in logs, filter by Correlation ID) and are not" -ForegroundColor Yellow
Write-Host "retrievable via this evidence pack alone — export the relevant sign-in log entry" -ForegroundColor Yellow
Write-Host "separately and attach it alongside this pack." -ForegroundColor Yellow

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# List all external MFA method configurations
$policy = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy" -Method GET
$policy.authenticationMethodConfigurations | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.externalAuthenticationMethodConfiguration' }

# Read one method by ID
Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/<id>" -Method GET

# Enable/disable a method
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/<id>" -Body @{ state = "enabled" }

# Confirm provider app consent (service principal existence = consent granted)
Get-MgServicePrincipal -Filter "appId eq '<provider-appId>'"

# Check a user's external MFA registration
Get-MgUserAuthenticationExternalAuthenticationMethod -UserId "<user-upn>"

# Delete a user's external MFA registration (admin-assisted recovery)
Remove-MgUserAuthenticationExternalAuthenticationMethod -UserId "<user-upn>" -ExternalAuthenticationMethodId "<id>"

# Fetch a provider's own OIDC discovery document directly (bypasses Entra ID's cache — useful for confirming current provider state)
Invoke-RestMethod -Uri "<provider-discovery-url>"

# List CA policies and grant control types (spot authentication-strength incompatibilities)
Get-MgIdentityConditionalAccessPolicy -All | Select DisplayName, GrantControls

# NOT available via Graph as of this writing:
#   - acr/amr claim validation detail for a specific failed sign-in (Sign-in logs / portal only)
#   - Live confirmation of Entra ID's current 24h metadata cache state for a given provider
```

---
## 🎓 Learning Pointers

- **The consent gate is a two-role split by design, and it's the single most common rollout blocker.** Authentication Policy Administrator can do everything visible except the one step that actually turns the method on. Always confirm which role completed which step before assuming the configuration itself is wrong. Read: [How to manage external MFA in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/authentication/how-to-authentication-external-method-manage)
- **Authentication strengths and external MFA don't just need "the right settings" — they're structurally incompatible.** This is worth surfacing proactively to any client planning phishing-resistant-only Conditional Access alongside a third-party MFA rollout, since it constrains architecture decisions made well before any ticket gets filed. Read: [Microsoft Entra External MFA Method Provider Reference](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-external-method-provider)
- **The acr/amr type-mapping check is the actual trust boundary, not a formality.** Because Entra ID cannot see what happened on the provider's side, the only signal it validates is that the returned factor TYPE differs from the first factor's type — a provider integration bug here produces a confusing "provider says success, Entra says failure" symptom that's easy to misdiagnose as an Entra-side problem when it's provider-side.
- **This is the third MFA-adjacent runbook in this repo — always confirm which one actually applies before investigating.** `MFA-A/B.md` (native methods), `Passkeys-A/B.md` (passkey/FIDO2 specifically), and this topic (delegated third-party providers) share overlapping vocabulary but almost no shared failure modes. Error code `50158` is the one reliable client-visible signal a ticket belongs here.
- **Registration reporting has a systematic, by-design blind spot.** A tenant-wide MFA registration coverage report will under-report any population relying on external MFA — don't let that trigger a false compliance alarm; cross-reference against the method's own target list instead.
- **The 5-minute session-abandonment window and 24-hour metadata cache are both worth knowing before a certificate-rotation incident happens, not during one.** A provider's poorly-timed key rotation produces a transient, self-resolving-within-24-hours failure that looks alarming in the moment — knowing the mechanism in advance turns a scramble into a known, bounded wait.
