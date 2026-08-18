# Entra External ID for Customers — JIT Password Migration Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

Covers **Just-In-Time (JIT) password migration** in an **Entra External ID for customers (CIAM) tenant** — the mechanism that lets a legacy identity provider (or an Azure AD B2C tenant being retired) hand off password validation to External ID transparently, at the user's first sign-in, without a bulk password reset.

**Not covered here:**
- Workforce guest/B2B collaboration (a different tenant configuration entirely) — see `ExternalIdentities-B.md`/`-A.md`
- The broader Azure AD B2C → External ID *migration project* (custom policies, user flows, branding cutover) — this file is scoped to the credential-migration mechanism only; see Microsoft's own [B2C-to-External-ID migration guide](https://learn.microsoft.com/en-us/entra/external-id/customers/migrate-from-b2c-to-external-id) for the full project
- Proactive/bulk password migration where you already have plaintext or hashed passwords at rest — that's a separate, simpler path (`Migrate users and credentials to External ID`, Stage 1–2) that doesn't need a custom authentication extension at all

**Assumes:** you already have an External ID for customers tenant provisioned, and the target client application has been (or is being) re-pointed at External ID endpoints.

---
## How It Works

JIT migration exists to solve one problem: moving a customer-facing user base off a legacy IdP (or B2C) without forcing every user through a password reset on day one. It does this with a **custom authentication extension** — a customer-hosted HTTPS endpoint (in practice, almost always an Azure Function) that External ID calls mid-sign-in to ask "is this password correct against the *old* system?"

<details><summary>Full sign-in flow</summary>

1. **User signs in** to a client app already pointed at External ID, using their legacy-system credentials.
2. **External ID checks the migration flag** — a custom directory extension attribute (commonly named `toBeMigrated`) on the user object.
   - If the flag is `false`/absent: normal Entra password validation, no extension call. This is the steady state once migration completes.
   - If the flag is `true`: External ID does **not** attempt to validate the password itself. It instead invokes the `OnPasswordSubmit` custom authentication extension.
3. **Password encryption.** External ID encrypts the submitted password (RSA JWE format) using the **public key** configured on the extension app's `keyCredentials`. Plaintext never crosses the wire to your endpoint unencrypted, and the corresponding **private key never leaves Azure Key Vault** — your Function retrieves it via managed identity at call time, it isn't baked into app settings.
4. **Your Function is called** with the encrypted payload plus authentication context (tenant ID, correlation ID, client app info, user claims already known to External ID).
5. **Your Function decrypts, validates against the legacy IdP**, and returns exactly one of four actions:
   - `MigratePassword` — password correct; External ID stores it, flips the migration flag to `false`. Every future sign-in bypasses the extension entirely.
   - `UpdatePassword` — password correct but doesn't meet External ID's strong-password policy; user is routed to a forced reset.
   - `Retry` — password incorrect; user can try again (subject to normal lockout policy).
   - `Block` — authentication must not proceed (e.g., account locked in the legacy system).
6. **Steady state.** Once `MigratePassword` fires, the user is a normal External ID account with no further dependency on the legacy IdP or the extension for that identity.

</details>

### The `disableStrongPassword` coexistence option

External ID enforces its own password-complexity policy. A legacy password that was valid under looser rules will, by default, route the user through `UpdatePassword` even though their credentials were otherwise correct — a forced reset for every affected user during the migration window. `disableStrongPassword` on the extension relaxes complexity checking specifically for the `OnPasswordSubmit` path (both browser and Native Auth flows) while still enforcing the 8-character minimum and expiry. It is explicitly a **time-boxed trade-off**: External ID will store and accept sub-standard-complexity passwords until the user's next voluntary change, so plan a forced rotation at the end of the coexistence period.

### Why a custom extension instead of a built-in connector

External ID has no built-in LDAP/legacy-IdP connector for this — every legacy system is different, so Microsoft's design pushes the actual validation logic out to code you own and host. This is also why the endpoint URL constraint exists (see Fix 8 in `CIAMMigration-B.md`): External ID needs a **stable, customer-controlled** endpoint it can call synchronously mid-authentication, which rules out pointing the extension at Graph, another Entra service, or the legacy IdP's own interactive sign-in page.

---
## Dependency Stack

```
Layer 0 — Azure Key Vault
  └── RSA encryption certificate (exportable private key, 2048/4096-bit)
      └── Function App managed identity granted "Get secret"

Layer 1 — Azure Function (customer-hosted HTTPS endpoint)
  └── Retrieves + caches RSA private key from Key Vault
      └── Decrypts encryptedPasswordContext (JWE)
          └── Validates against legacy IdP
              └── Returns MigratePassword | UpdatePassword | Retry | Block

Layer 2 — Custom Authentication Extension app registration
  └── identifierUri: api://<function-hostname>/<app-id>
      └── API permission: CustomAuthenticationExtension.Receive.Payload (admin-consented)
          └── keyCredentials (public cert, type=AsymmetricX509Cert, usage=Encrypt)
              └── tokenEncryptionKeyId — MUST equal the keyId above

Layer 3 — Custom Extension Policy (onPasswordSubmitCustomExtension)
  └── endpointConfiguration.targetUrl → Function endpoint
      └── authenticationConfiguration.resourceId → identifierUri (Layer 2)
          └── clientConfiguration (timeoutInMilliseconds, maximumRetries)

Layer 4 — Client application (the app users actually sign into)
  └── Registered in External ID, redirect URI configured
      └── User.Read delegated permission consented

Layer 5 — Listener Policy (onPasswordSubmitListener)
  └── conditions.applications.includeApplications = [Layer 4 app ID]
      └── priority (relative to any other listener touching the same app)
          └── handler.migrationPropertyId → the toBeMigrated extension attribute
              └── handler.customExtension.id → Layer 3 policy ID

Layer 6 — User object
  └── toBeMigrated extension attribute = true
      └── Sign-in triggers the full chain above
```

A break at any layer produces a different, characteristic symptom — see the Symptom → Cause map below.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Extension never invoked, sign-in falls through to normal (failing) password check | User's `toBeMigrated` flag not set | Layer 6 — `Get-MgUser` extension attribute |
| Extension never invoked, flag is set | Listener not scoped to this app, or wrong priority | Layer 5 — `authenticationEventListeners` conditions |
| Extension invoked, immediate 401/403 | Admin consent missing on `CustomAuthenticationExtension.Receive.Payload` | Layer 2 — service principal app role assignments |
| Extension invoked, Function can't decrypt | `keyId` ≠ `tokenEncryptionKeyId`, or cert expired | Layer 2 — `KeyCredentials` vs `TokenEncryptionKeyId` |
| Function decrypts fine, legacy IdP call fails | Network path from Function to legacy IdP blocked, or legacy IdP outage | Layer 1 — Function logs, outbound connectivity |
| `CustomExtensionThrottlingError` | Migration wave too large, tenant/extension throttling limit hit | Layer 3 — service limits, batch size |
| `CustomExtensionTimedOut` | `timeoutInMilliseconds` too low for legacy IdP round-trip | Layer 3 — `clientConfiguration` |
| User stuck in reset loop (`UpdatePassword` repeatedly) | Legacy password fails External ID complexity policy | `disableStrongPassword` state |
| Native Auth shows raw error instead of reset prompt | Documented known issue — Native Auth doesn't redirect to SSPR on this path | `disableStrongPassword`, Native Auth client version |
| Every sign-in returns Block | Function defaulting unhandled exceptions to Block, or legacy IdP unreachable | Layer 1 — Function error-handling logic |
| Migration "succeeds" but user re-triggers extension on next sign-in | `MigratePassword` action returned but flag update failed downstream, or flag never actually flips | Layer 6 — flag state post-migration |
| Extension policy update via Graph rejected | `targetUrl` points at Graph/Entra/legacy sign-in URL — violates hard constraint | Layer 3 — `endpointConfiguration.targetUrl` |
| Works for one client app, not another | Listener `includeApplications` scoped to only one app ID | Layer 5 — listener conditions |

---
## Validation Steps

1. **Confirm tenant type.** External ID for customers only — `Get-MgOrganization | Select-Object -ExpandProperty AdditionalProperties` and check for CIAM-specific tenant markers, or confirm via the admin center (Overview blade shows tenant type). Bad: this is actually a workforce tenant — JIT migration as described here doesn't apply.
2. **Confirm the extension attribute schema exists.** `Get-MgDirectoryObjectById` or a targeted `Get-MgUser -ExpandProperty extensions` on a known test user. Bad: attribute never created — Stage 1/2 of the base migration guide wasn't completed.
3. **Confirm the extension app's cert isn't expired.** `(Get-MgApplication -ApplicationId <id>).KeyCredentials.EndDateTime`. Bad: `EndDateTime` in the past.
4. **Confirm `keyId` == `tokenEncryptionKeyId`.** Both values must reference the same GUID. Bad: mismatch — decryption fails for every call.
5. **Confirm admin consent on `CustomAuthenticationExtension.Receive.Payload`.** `Get-MgServicePrincipalAppRoleAssignment`. Bad: no matching grant.
6. **Confirm listener priority and scope.** List all `onPasswordSubmitListener` objects, sort by priority, confirm only the intended one targets the affected app. Bad: two listeners on the same app with conflicting priorities.
7. **Confirm `clientConfiguration` timeout is realistic for your legacy IdP's actual latency.** Bad: `timeoutInMilliseconds` set below the legacy IdP's observed p95 response time.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Pre-cutover (nothing works yet)**
- Verify Layers 0–3 exist and are internally consistent (cert, Function, extension app, extension policy) before touching the listener or any user.
- Test the Function directly with a synthetic payload before wiring it into the sign-in flow — a GET health-check route (as in Microsoft's own template) is the fastest signal the Function is even reachable.

**Phase 2 — Cutover (listener goes live)**
- Confirm `includeApplications` and `priority` on the listener before enabling for production traffic.
- Migrate a small test cohort first (flag a handful of test users with `toBeMigrated = true`) rather than the full base.

**Phase 3 — Steady-state migration (users actively migrating)**
- Watch sign-in log error codes for throttling/timeout patterns as volume ramps.
- Track the proportion of `MigratePassword` vs `UpdatePassword` vs `Retry` vs `Block` responses — an unexpectedly high `Block` rate almost always means a Function bug, not genuinely locked-out users.

**Phase 4 — Post-migration cleanup**
- Confirm no users remain with `toBeMigrated = true` past your planned cutover deadline.
- If `disableStrongPassword` was enabled, force a password-complexity rotation and then disable the option.
- Decommission the listener policy (or drop its priority) once migration is complete — leaving it live indefinitely is an unnecessary extra hop in every sign-in for that app.

---
## Remediation Playbooks

<details><summary>Playbook 1 — From-scratch onboarding (Stages 1–5)</summary>

1. Complete Stages 1–2 of the base `Migrate users and credentials to External ID` guide: create user accounts in the External ID tenant, define the migration extension property, flag users `toBeMigrated: true`.
2. **Key Vault:** enable Function App managed identity → grant Key Vault "Get secret" access policy (or equivalent RBAC) → generate the RSA cert (`JitMigrationEncryptionCert`, self-signed, exportable private key, 2048/4096-bit).
3. **Function:** deploy your credential-validation code (Microsoft publishes a C# template — decrypt via cached RSA key, call your legacy IdP, return one of the four actions). Confirm a GET health-check route responds before wiring in POST logic.
4. **Extension app registration:** set `identifierUri`, grant + admin-consent `CustomAuthenticationExtension.Receive.Payload`, export the cert's public key and PATCH it into `keyCredentials` + `tokenEncryptionKeyId` (same GUID for both).
5. **Extension policy:** `POST /beta/identity/customAuthenticationExtensions` with `@odata.type = #microsoft.graph.onPasswordSubmitCustomExtension`, `targetUrl` → your Function, `resourceId` → the `identifierUri` from step 4.
6. **Client app:** register (or reuse) the app users sign into; grant `User.Read` delegated consent.
7. **Listener policy:** `POST /beta/identity/authenticationEventListeners` with `@odata.type = #microsoft.graph.onPasswordSubmitListener`, `conditions.applications.includeApplications` → client app ID, `priority`, `handler.migrationPropertyId` → the extension attribute ID, `handler.customExtension.id` → step 5's policy ID.
8. Test end-to-end with a small cohort before full cutover (Stage 5 of the how-to guide).

</details>

<details><summary>Playbook 2 — Throttling/timeout tuning for a large migration wave</summary>

1. Pull sign-in log error-code distribution for the migration window — count `CustomExtensionThrottlingError` vs `CustomExtensionTimedOut` vs success.
2. If timeouts dominate: raise `timeoutInMilliseconds` on the extension policy (bounded by the service's own cap — check current limits at `reference-service-limits`), and separately profile your Function's actual latency against the legacy IdP (a slow legacy system, not Entra, is usually the real bottleneck).
3. If throttling dominates: this is a per-tenant/per-extension invocation cap, not a config knob — stage the rollout into smaller batches (e.g., by region, by signup cohort, or a percentage-based gradual flag rollout) rather than flipping `toBeMigrated: true` for the entire user base at once.
4. Re-measure after each batch before widening the cohort.

</details>

<details><summary>Playbook 3 — Password-complexity coexistence period (disableStrongPassword)</summary>

1. Confirm the legacy IdP's complexity rules are genuinely looser than External ID's (if they're equal or stricter, leave `disableStrongPassword` off — the `UpdatePassword` flow is working as intended and catching weak passwords).
2. Enable `disableStrongPassword` on the extension policy for the migration window only.
3. Communicate an explicit end date to stakeholders — this is documented by Microsoft as a security trade-off, not a permanent posture.
4. At the end date: disable the option, then force a password reset/rotation for any user who migrated during the coexistence window with a sub-standard-complexity password (track via your Function's own logging of which `MigratePassword` responses occurred while the flag was enabled).

</details>

<details><summary>Playbook 4 — Certificate rotation</summary>

1. Generate a new certificate in Key Vault (new name or new version) well before the current one's `EndDateTime`.
2. Export the new public key, PATCH the extension app's `keyCredentials` to include **both** the old and new cert temporarily, but only flip `tokenEncryptionKeyId` to the new `keyId` once the Function has been updated to also recognize the new private key (avoids a window where External ID encrypts with a key your Function can't yet decrypt).
3. Update the Function's Key Vault certificate name/reference and redeploy.
4. Remove the old `keyCredentials` entry once you've confirmed zero decrypt failures against the new key for a full sign-in cycle.

**Rollback:** re-add the prior `keyCredentials` entry and flip `tokenEncryptionKeyId` back if the new cert causes decrypt failures.

</details>

---
## Evidence Pack

Run `Scripts/Get-CIAMMigrationReadinessAudit.ps1` before escalating or before any cutover — see script header for exact checks (extension existence, listener conflicts, cert/key consistency, admin consent state, RBAC holders). It is explicitly read-only and flags portal-only state (migration flag distribution across the full user base, sign-in log error-code breakdown, Function-side logs) as **out of scope** — pull those from the admin center / Application Insights separately.

---
## Command Cheat Sheet

```powershell
# List all custom authentication extensions
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions"

# List all listener policies, sorted by priority
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/authenticationEventListeners" |
  Select-Object -ExpandProperty value | Sort-Object priority

# Get a specific extension policy
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions/<id>"

# Patch clientConfiguration (timeout/retries)
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions/<id>" `
  -Body (@{ clientConfiguration = @{ timeoutInMilliseconds = 4000; maximumRetries = 2 } } | ConvertTo-Json) -ContentType "application/json"

# Toggle disableStrongPassword
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions/<id>" `
  -Body (@{ disableStrongPassword = $true } | ConvertTo-Json) -ContentType "application/json"

# Check extension app's key credentials
(Get-MgApplication -ApplicationId "<extension-app-object-id>").KeyCredentials | Select-Object KeyId, EndDateTime
(Get-MgApplication -ApplicationId "<extension-app-object-id>").TokenEncryptionKeyId

# Check a user's migration flag (replace with your actual extension attribute name)
Get-MgUser -UserId "<user-id>" -ExpandProperty "extensions"

# Confirm admin consent grant on the extension app
$sp = Get-MgServicePrincipal -Filter "AppId eq '<extension-app-id>'"
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id

# Required RBAC roles for managing this feature
# - Application Administrator
# - User Administrator
# - Authentication Extensibility Password Administrator
```

---
## 🎓 Learning Pointers

- **The migration flag, not the extension, is the actual gate.** If `toBeMigrated` is `false`, External ID never calls out to your Function at all — most "extension seems broken" tickets are actually "the flag was never set" tickets. [How-to: JIT password migration](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-migrate-passwords-just-in-time)
- **Encryption key management is the most fragile part of this design.** The `keyId`/`tokenEncryptionKeyId` pairing has no built-in validation UI feedback — a mismatch fails silently at decrypt time in your own Function, not with a clear Entra-side error. Treat cert rotation as a two-step, overlap-window operation (Playbook 4), never a direct swap.
- **On-premises attributes on the user schema are read-only in this flow.** External ID shares the Microsoft Entra user model, but JIT migration doesn't write back to any on-prem-sourced attribute — user resolution happens earlier in sign-in via UPN/email, not on-prem identity matching.
- **Deploy in a segregated, tightly-RBAC'd subscription.** Microsoft's own guidance calls this out explicitly — the Function and Key Vault sit in the authentication critical path, so treat their subscription/RG like you would any other identity-tier infrastructure, not a general app-dev environment.
- **Azure AD B2C is closed to new purchases (May 1, 2025).** If a client is asking "should we migrate," the honest framing is often "you no longer have the option to keep buying B2C," not a pure feature comparison. [B2C FAQ](https://learn.microsoft.com/en-us/azure/active-directory-b2c/faq?tabs=app-reg-ga#azure-ad-b2c-end-of-sale)
- **Throttling errors during a migration wave are expected, not exceptional.** Design your rollout plan (batching/cohorts) around this from the start rather than treating the first `CustomExtensionThrottlingError` as an incident. [Troubleshoot a custom authentication extension](https://learn.microsoft.com/en-us/entra/identity-platform/custom-extension-troubleshoot) · [Service limits](https://learn.microsoft.com/en-us/entra/external-id/customers/reference-service-limits)
