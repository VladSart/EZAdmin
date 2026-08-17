# Entra ID External MFA (External Authentication Methods) — Hotfix Runbook (Mode B: Ops)
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

External MFA (formerly "External Authentication Methods"/EAM) lets a third-party provider (Duo, etc.) satisfy the MFA leg of sign-in. If the ticket says "Duo/third-party MFA suddenly stopped satisfying Conditional Access," start here — not in `MFA-B.md`, which covers Microsoft's own built-in methods.

```powershell
Connect-MgGraph -Scopes "Policy.Read.AuthenticationMethod","Application.Read.All"

# 1. List all external MFA method configurations and their enabled/disabled state
$policy = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy" -Method GET
$policy.authenticationMethodConfigurations |
    Where-Object { $_.'@odata.type' -eq '#microsoft.graph.externalAuthenticationMethodConfiguration' } |
    Select-Object id, displayName, state, appId

# 2. Confirm admin consent was actually granted to the provider's app (the #1 silent-fail cause)
Get-MgServicePrincipal -Filter "appId eq '<provider-appId>'" | Select-Object DisplayName, Id
Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId "<sp-object-id>" -ErrorAction SilentlyContinue

# 3. Confirm the Conditional Access grant control is plain "Require multifactor authentication"
#    — NOT an Authentication Strength (built-in or custom). Authentication strengths are NOT
#    satisfied by external MFA, full stop.
Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '<policy-name>'" |
    Select-Object DisplayName, @{n="GrantControls";e={$_.GrantControls | ConvertTo-Json -Depth 5}}

# 4. Confirm the affected user is targeted (included, not excluded) on the external MFA method itself
#    — this is a SEPARATE scope from the Conditional Access policy's own user assignment
$policy.authenticationMethodConfigurations |
    Where-Object { $_.'@odata.type' -eq '#microsoft.graph.externalAuthenticationMethodConfiguration' } |
    Select-Object displayName, includeTargets, excludeTargets

# 5. Confirm client OS — external MFA cannot satisfy OOBE sign-in on Windows 10 (documented, unfixable)
```

| Result | Action |
|--------|--------|
| Method `state` is `disabled` | → [Fix 1 — Method Disabled (usually missing admin consent)](#fix-1--method-disabled-usually-missing-admin-consent) |
| Method enabled, but no `Oauth2PermissionGrant` for the provider's service principal | → [Fix 1 — Method Disabled (usually missing admin consent)](#fix-1--method-disabled-usually-missing-admin-consent) |
| CA policy grant control is an Authentication Strength, not "Require MFA" | → [Fix 2 — Authentication Strength Doesn't Accept External MFA](#fix-2--authentication-strength-doesnt-accept-external-mfa) |
| User not in `includeTargets`, or is in `excludeTargets` | → [Fix 3 — User Not Targeted on the Method](#fix-3--user-not-targeted-on-the-method) |
| Sign-in fails specifically during Windows 10 OOBE / device setup | → [Fix 4 — Windows 10 OOBE Not Supported](#fix-4--windows-10-oobe-not-supported) |
| User in both a custom-control CA policy and an MFA-grant CA policy for the same app | → [Fix 5 — Double-Redirect from Overlapping Custom Control + External MFA Policies](#fix-5--double-redirect-from-overlapping-custom-control--external-mfa-policies) |
| Sign-in fails with a signature/key-validation error referencing `kid` | → [Fix 6 — Signing Key / kid Mismatch](#fix-6--signing-key--kid-mismatch) |
| Redirect to provider succeeds, but Entra ID rejects the return with an `acr`/`amr` related error | → [Fix 7 — Provider's Returned Claims Don't Satisfy MFA Type Requirements](#fix-7--providers-returned-claims-dont-satisfy-mfa-type-requirements) |
| All triage clean, still failing | → Escalate — open a Microsoft 365 admin center service request under Entra ID, include the Correlation ID from the sign-in error |

---
## Dependency Cascade

<details><summary>What must be true for external MFA to satisfy a sign-in</summary>

```
Provider registers a multitenant (or single-tenant) Entra app + publishes OIDC discovery doc
  └── Tenant admin (Authentication Policy Administrator) adds the External MFA method
        ├── Enters Name / Client ID / Discovery Endpoint / App ID from the provider
        └── Admin consent granted to the provider's app
              (needs Privileged Role Administrator — a DIFFERENT role than the one that
               created the method — the #1 real-world "saved but stuck disabled" cause)
                    └── Method state can now be set to Enabled
                          └── includeTargets/excludeTargets scope which users can use it
                                └── Conditional Access policy grants "Require multifactor
                                    authentication" (NOT an authentication strength — external
                                    MFA is not accepted by strength-based grant controls)
                                      └── User completes 1st factor (password/passwordless)
                                            └── Entra ID redirects browser to provider's
                                                authorization_endpoint with id_token_hint
                                                  └── Provider authenticates user, returns
                                                      id_token with acr + amr claims
                                                        └── Entra ID validates: signature
                                                            (kid/jwks), issuer, audience,
                                                            nonce, AND that amr's factor type
                                                            differs from the 1st factor's type
                                                              └── MFA satisfied → access granted
```

Any missing link fails **silently from the user's perspective** — they're either never offered the method, or bounced back to the sign-in page with a generic error. None of these failure modes produce a client-side error that names the actual cause.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the method exists and is enabled**
```powershell
$policy = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy" -Method GET
$policy.authenticationMethodConfigurations |
    Where-Object { $_.'@odata.type' -eq '#microsoft.graph.externalAuthenticationMethodConfiguration' } |
    Select-Object id, displayName, state
```
Expected: `state = enabled`. If `disabled`, the method either was deliberately turned off, or — far more commonly — was saved by an admin who lacked Privileged Role Administrator and could never grant consent to flip it on.

**Step 2 — Confirm admin consent was actually granted**
```powershell
Get-MgServicePrincipal -Filter "appId eq '<provider-appId>'"
```
Expected: A service principal exists in the tenant for the provider's app. If it doesn't exist at all, consent was never completed — go to Fix 1.

**Step 3 — Confirm the Conditional Access grant control type**
```powershell
Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '<policy-name>'" |
    Select-Object -ExpandProperty GrantControls
```
Expected: `BuiltInControls` contains `mfa` (plain "Require multifactor authentication"). If the policy instead references an `AuthenticationStrength` grant control (built-in or custom), external MFA cannot satisfy it by design — this is documented, not a bug.

**Step 4 — Confirm user targeting on the method itself**
```powershell
$policy.authenticationMethodConfigurations |
    Where-Object { $_.'@odata.type' -eq '#microsoft.graph.externalAuthenticationMethodConfiguration' } |
    Select-Object -ExpandProperty includeTargets
```
Expected: The user, or a group they're in, appears in `includeTargets` and is not separately excluded. This scope is independent of — and evaluated in addition to — whatever Conditional Access policy requires MFA.

**Step 5 — Confirm the OS/platform isn't Windows 10 OOBE**
```
No PowerShell check exists for this — it's a client-side, in-the-moment failure. If the
symptom is specifically "fails during initial device setup / Out-of-Box Experience" on a
Windows 10 device, this is the documented, permanent limitation in Fix 4 — Windows 10 does
not support external MFA during OOBE and Microsoft has no plans to add it (Windows 10 is
end-of-support). Confirm OS build before spending more time here.
```

---
## Common Fix Paths

<details><summary>Fix 1 — Method Disabled (usually missing admin consent)</summary>

**When:** The method's `state` is `disabled`, or was recently created and never worked.

```
The Authentication Policy Administrator role is sufficient to CREATE and SAVE an external
MFA method, but admin consent for the provider's application requires Privileged Role
Administrator. If the person who configured the method didn't hold that second role, the
method saves successfully in a disabled state with no error — it just silently can't be
turned on.

1. Sign in to entra.microsoft.com as a Privileged Role Administrator.
2. Entra ID > Authentication methods > select the external MFA method.
3. Grant admin consent to the provider's application if not already granted (look for a
   "grant consent" prompt/button on the method's configuration page).
4. Once consent shows granted, set Enable to On and Save.
```

**Rollback:** Set Enable back to Off to immediately stop new sign-ins from offering this method; existing sessions are unaffected until their next MFA challenge.

</details>

<details><summary>Fix 2 — Authentication Strength Doesn't Accept External MFA</summary>

**When:** A Conditional Access policy uses an authentication strength grant control (built-in MFA/Passwordless/Phishing-resistant strength, or any custom strength) and external MFA users are blocked even though the method is enabled and consented.

```
This is a hard platform limitation, not a misconfiguration: "External MFA methods aren't
currently supported with authentication strengths" (Microsoft's own documentation).
Authentication strength policies validate specific authentication METHOD TYPES the platform
recognizes natively — an external MFA completion doesn't map into that model.

Fix: Change the Conditional Access policy's grant control from an authentication strength
to plain "Require multifactor authentication" for any policy scope where external-MFA-only
users need to be covered. If the strength requirement is a compliance/security mandate that
can't be relaxed, external MFA users must be issued a native method (FIDO2, Authenticator,
etc.) instead — there is no way to make external MFA satisfy a strength policy.
```

**Rollback:** Revert the grant control to the authentication strength; external-MFA-only users will be blocked again until they register a native method.

</details>

<details><summary>Fix 3 — User Not Targeted on the Method</summary>

**When:** The external MFA method is enabled and consented tenant-wide, but a specific user still isn't offered it.

```powershell
# Add the user (or their group) to includeTargets via the admin center — Entra ID >
# Authentication methods > select the method > Target — or via Graph:
$body = @{
    includeTargets = @(
        @{
            targetType = "group"   # or "user"
            id         = "<group-or-user-object-id>"
        }
    )
}
Invoke-MgGraphRequest -Method PATCH `
  -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/<method-id>" `
  -Body $body
```

**Rollback:** Remove the target entry the same way; the user reverts to whatever other methods they have registered.

</details>

<details><summary>Fix 4 — Windows 10 OOBE Not Supported</summary>

**When:** Sign-in specifically fails during Windows 10 Out-of-Box Experience (initial device setup) for a user whose only method is external MFA.

```
Documented, unfixable limitation: Windows 10 does not natively support external MFA during
OOBE, and Microsoft has stated there are no plans to extend support given Windows 10 is out
of support.

Workarounds:
  1. Register the user for a native MFA method (Authenticator, FIDO2 security key) they can
     use just for OOBE, in addition to external MFA for normal day-to-day sign-in.
  2. Complete OOBE using an admin-provisioned local/offline account, then have the user
     sign in normally post-setup where external MFA works fine.
  3. Upgrade the device to Windows 11 before enrollment — external MFA works normally there.
```

**Rollback:** N/A — this is a platform limitation, not a configuration to undo.

</details>

<details><summary>Fix 5 — Double-Redirect from Overlapping Custom Control + External MFA Policies</summary>

**When:** During a migration from Conditional Access custom controls (legacy Duo integration) to native external MFA, a user is redirected to the provider TWICE in the same sign-in.

```
This happens when a user is in scope for BOTH the old custom-control policy AND the new
"Require multifactor authentication" policy at the same time. Microsoft's own migration
guidance requires mutually exclusive test groups.

Fix:
1. Identify the two overlapping Conditional Access policies (one with a custom control
   grant, one with an MFA grant referencing the same provider).
2. Ensure any given user/group is included in exactly ONE of the two — exclude the custom-
   control policy for users who've been cut over to external MFA.
3. Once all users are confirmed working on external MFA, set the custom-control policy to
   Off entirely rather than leaving it excluded-but-live.
```

**Rollback:** Re-include affected users in the custom-control policy and exclude them from the external MFA policy to revert to the legacy integration.

</details>

<details><summary>Fix 6 — Signing Key / kid Mismatch</summary>

**When:** Sign-in fails with a token/signature validation error referencing a key ID (`kid`), often right after the provider rotates its signing certificate.

```
Two common root causes:
  1. The kid property in the id_token's JWT header must be base64-encoded consistently with
     the JWKS document at the provider's jwks_uri — a provider-side encoding mismatch breaks
     key matching even though both values "look" correct.
  2. Microsoft caches provider metadata (including keys) for 24 hours. If the provider
     rotated its signing key and did NOT keep the OLD certificate published in jwks_uri
     alongside the new one for at least ~2 days, Entra ID's cache may still be validating
     against a key the provider has already retired.

This is provider-side, not tenant-admin-fixable in the Entra portal. Escalate to the
external MFA provider with the exact error text and Correlation ID, and confirm they
followed the documented key-rollover process (publish both Existing Cert and New Cert
simultaneously, don't retire the old one until the cache window has fully elapsed).
```

**Rollback:** N/A — provider-side certificate issue, nothing to roll back on the tenant.

</details>

<details><summary>Fix 7 — Provider's Returned Claims Don't Satisfy MFA Type Requirements</summary>

**When:** The user completes authentication with the provider successfully (no error on the provider's side), but Entra ID still rejects the sign-in as not satisfying MFA.

```
Entra ID validates that the amr (Authentication Methods Reference) claim the provider
returns maps to a DIFFERENT factor TYPE (knowledge / possession / inherence) than the
first factor the user already completed with their password. If the provider returns an
amr value Entra ID maps to the SAME type as the first factor — or an unrecognized amr
value — the sign-in is rejected as not satisfying MFA even though the user authenticated
successfully with the provider.

This is a provider-integration bug, not a tenant configuration issue. Escalate to the
external MFA provider with the Correlation ID and ask them to confirm which amr value(s)
their integration returns and that it/they map to a possession or inherence factor type
(not knowledge, since the first Entra ID factor is almost always a password/knowledge
factor).
```

**Rollback:** N/A — provider-side claim-mapping issue.

</details>

---
## Escalation Evidence

Copy this template, fill in all fields, attach to ticket before escalating.

```
=== ENTRA ID EXTERNAL MFA ESCALATION EVIDENCE PACK ===
Date/Time (UTC): _______________
Reported by: _______________
Affected user(s)/group: _______________
Tenant ID: _______________
External MFA provider: _______________
Method display name: _______________
Method state (enabled/disabled): _______________
Admin consent granted (Y/N, verified via service principal lookup): _______________
Conditional Access policy name + grant control type (MFA grant vs. authentication strength): _______________
User in includeTargets for the method (Y/N): _______________
Client OS/build: _______________
Windows 10 OOBE scenario (Y/N): _______________
Custom control + external MFA overlap suspected (Y/N): _______________

SYMPTOM:
[ ] Method disabled (missing admin consent)
[ ] Authentication strength grant control rejects external MFA
[ ] User not targeted on the method
[ ] Windows 10 OOBE failure
[ ] Double-redirect from overlapping custom control + external MFA policies
[ ] Signing key / kid mismatch (provider-side)
[ ] Returned acr/amr claims don't satisfy MFA type requirement (provider-side)
[ ] Other: _______________

ACTIONS TAKEN:
_______________

CORRELATION ID / Trace ID (from sign-in error): _______________
```

---
## 🎓 Learning Pointers

- **The role that creates the method isn't the role that turns it on.** Authentication Policy Administrator can save an external MFA method fully configured, but only Privileged Role Administrator can grant admin consent to the provider's app — without that, the method sits disabled with zero error. This is the single most common "why isn't this working" ticket for a brand-new external MFA rollout. Read: [How to manage external MFA in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/authentication/how-to-authentication-external-method-manage)
- **Authentication strengths and external MFA are architecturally incompatible, not just unconfigured.** If a client wants phishing-resistant-only access for certain apps, external MFA cannot be the mechanism — plan for native FIDO2/certificate-based auth in that scope from the start rather than discovering the gap mid-rollout. Read: [Microsoft Entra External MFA Method Provider Reference](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-authentication-external-method-provider)
- **Two independent scoping layers exist, and only one shows up when troubleshooting "MFA isn't required."** Conditional Access decides WHO needs MFA; the external MFA method's own `includeTargets`/`excludeTargets` decides WHO CAN USE this particular method to satisfy it. A user can be correctly in-scope for the CA policy and still never see the method if the second scope excludes them.
- **This is the third distinct MFA-adjacent topic in this repo, and each solves a different problem** — `MFA-A.md`/`-B.md` covers Microsoft's own native methods (Authenticator, FIDO2, SMS, TAP), `Passkeys-A.md`/`-B.md` covers passkey/FIDO2 profiles specifically, and this topic covers delegating the second factor entirely to a non-Microsoft provider via OIDC. Confirm which one a ticket actually describes before picking a runbook — error code `50158` ("external security challenge required") is the one client-visible signal this is genuinely an external-MFA ticket.
- **Migration from custom controls is a parallel-policy exercise, not a cutover.** Running the old custom-control policy and the new MFA-grant policy against the same user simultaneously produces a double provider redirect, not a clean fallback — always keep test groups mutually exclusive per Microsoft's own migration guidance.
