# Entra External ID for Customers — JIT Password Migration Hotfix Runbook (Mode B: Ops)
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

**Scope check first:** this file is for an **External ID for customers (CIAM) tenant** migrating end users from a legacy identity provider (or Azure AD B2C) via Just-In-Time (JIT) password migration. If the ticket is about workforce guest/B2B invitations, you're in the wrong file — see `ExternalIdentities-B.md`.

```powershell
Connect-MgGraph -Scopes "Application.Read.All","Policy.Read.All" -Environment Global

# 1. Confirm the custom authentication extension (OnPasswordSubmit) exists
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions" |
  Select-Object -ExpandProperty value | Where-Object { $_."@odata.type" -match "onPasswordSubmit" } |
  Select-Object id, displayName, endpointConfiguration

# 2. Confirm the listener policy that activates it for the affected app
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/authenticationEventListeners" |
  Select-Object -ExpandProperty value | Where-Object { $_."@odata.type" -match "onPasswordSubmitListener" } |
  Select-Object id, priority, conditions, handler

# 3. Check the extension app's encryption certificate + tokenEncryptionKeyId match
$extAppObjectId = "<custom-extension-app-object-id>"
Get-MgApplication -ApplicationId $extAppObjectId | Select-Object DisplayName, KeyCredentials, TokenEncryptionKeyId

# 4. Confirm the affected user's migration flag state (requires the extension attribute set name)
$userId = "<user-object-id>"
Get-MgUser -UserId $userId -Property "Id,DisplayName,Identities" -ExpandProperty "extensions" |
  Select-Object -ExpandProperty AdditionalProperties

# 5. Check your own admin role — most "can't configure the extension" tickets are an RBAC gap
Get-MgUserMemberOf -UserId (Get-MgContext).Account -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty AdditionalProperties | Where-Object { $_.displayName -match "Authentication Extensibility Password Administrator|Application Administrator|User Administrator" }
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| No `onPasswordSubmit` custom extension found | Migration never configured, or wrong tenant | → Fix 1 |
| Listener exists but `priority` conflicts with another listener on the same app | Extension not invoked, or invoked in wrong order | → Fix 2 |
| `keyId` on app ≠ `tokenEncryptionKeyId` | Decryption fails in your Function; silent auth failures | → Fix 3 |
| Sign-in logs show `CustomExtensionThrottlingError` / `CustomExtensionTimedOut` | Function too slow or migration wave too large | → Fix 4 |
| User reports **repeated password-reset prompts** on first sign-in | Password complexity mismatch (`UpdatePassword` loop) | → Fix 5 |
| User reports **hard error instead of a reset prompt** in a Native Auth (embedded) app | Known issue — Native Auth doesn't redirect to SSPR on weak legacy password | → Fix 5 |
| User always gets a **Block screen** | Your Function is returning `Block`, or the legacy IdP call is failing and defaulting to Block | → Fix 6 |
| 401/403 calling `CustomAuthenticationExtension.Receive.Payload` | Admin consent not granted on the extension app | → Fix 7 |
| Extension URL points at Graph, Entra, or the legacy IdP's own sign-in page | Violates the required endpoint shape — will never be invoked correctly | → Fix 8 |

---
## Dependency Cascade

<details><summary>What must be true for JIT password migration to work</summary>

```
Azure Key Vault
└── Encryption certificate (RSA, exportable private key)
    └── Managed Identity on Azure Function ── granted Key Vault "Get secret"
        └── Azure Function (customer-hosted HTTPS endpoint)
            └── Decrypts encryptedPasswordContext, validates against legacy IdP
                └── Returns one of: MigratePassword | UpdatePassword | Retry | Block
Custom Authentication Extension app registration
└── identifierUri (api://<function-hostname>/<app-id>)
    └── API permission: CustomAuthenticationExtension.Receive.Payload (admin-consented)
        └── keyCredentials (public cert) + tokenEncryptionKeyId — MUST match keyId
Custom Extension policy (onPasswordSubmitCustomExtension)
└── targetUrl → your Function endpoint
    └── authenticationConfiguration → resourceId = identifierUri above
        └── Listener policy (onPasswordSubmitListener)
            └── conditions.applications.includeApplications = [client app ID]
                └── priority (must not conflict with other listeners on same app)
                    └── handler.migrationPropertyId (the toBeMigrated extension attribute)
                        └── User signs in with legacy credentials
                            └── toBeMigrated = true on user object?
                                ├── YES → OnPasswordSubmit invoked → your Function called
                                └── NO  → normal Entra password check, no migration path
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the user is actually flagged for migration**
```powershell
Get-MgUser -UserId "<user-id>" -Property "Id,UserPrincipalName" -ExpandProperty "extensions"
```
- Expected: the custom extension attribute (e.g. `extension_<appid>_toBeMigrated`) = `true` before first sign-in
- Bad: attribute missing entirely → user was never prepared for migration (Stage 1/2 of the migrate-users guide was skipped for this account)

**Step 2 — Check sign-in logs for the correlation ID and error code**
```powershell
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<user-upn>'" -Top 5 |
  Select-Object CreatedDateTime, AppDisplayName, Status, CorrelationId | Format-Table
```
- Look for `CustomExtensionThrottlingError`, `CustomExtensionTimedOut`, or a generic auth failure with the extension's correlation ID

**Step 3 — Validate the listener policy targets the right app and isn't shadowed**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/authenticationEventListeners" |
  Select-Object -ExpandProperty value |
  Sort-Object priority |
  Select-Object id, priority, "@odata.type", conditions
```
- Lower `priority` number generally evaluates first — confirm no other `onPasswordSubmitListener` or Native Auth policy on the same app is intercepting first

**Step 4 — Validate the encryption key pair**
```powershell
$app = Get-MgApplication -ApplicationId "<extension-app-object-id>"
$app.KeyCredentials | Select-Object KeyId, Type, Usage, EndDateTime
$app.TokenEncryptionKeyId
```
- Bad: `TokenEncryptionKeyId` doesn't match any `KeyId` in `KeyCredentials`, or the matching cert's `EndDateTime` is in the past

**Step 5 — Confirm admin consent on the extension app**
```powershell
$sp = Get-MgServicePrincipal -Filter "AppId eq '<extension-app-id>'"
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id |
  Where-Object { $_.AppRoleId -ne $null } | Select-Object ResourceDisplayName, AppRoleId
```
- Confirm a Graph application permission grant exists for `CustomAuthenticationExtension.Receive.Payload`

---
## Common Fix Paths

<details><summary>Fix 1 — Custom extension never configured</summary>

**Symptom:** No `onPasswordSubmit` custom authentication extension exists at all; every legacy-credential sign-in fails or silently creates a fresh account instead of migrating.

This is a from-scratch build, not a quick fix — walk the five-stage setup in `CIAMMigration-A.md` Playbook 1 (Key Vault cert → Function → extension app → extension policy → listener policy). Confirm the account you're using holds all three required roles first:

```powershell
# Required roles: Application Administrator, User Administrator,
# Authentication Extensibility Password Administrator
Get-MgUserMemberOf -UserId (Get-MgContext).Account |
  Select-Object -ExpandProperty AdditionalProperties |
  Where-Object { $_.displayName -match "Administrator" } | Select-Object displayName
```

</details>

<details><summary>Fix 2 — Listener priority conflict / extension not invoked</summary>

**Symptom:** Users sign in with legacy credentials but the migration never triggers — no call ever reaches your Function.

```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/authenticationEventListeners" |
  Select-Object -ExpandProperty value | Select-Object id, priority, conditions

# Update priority so the migration listener evaluates correctly relative to others on the same app
$body = @{ priority = 500 } | ConvertTo-Json
Invoke-MgGraphRequest -Method PATCH `
  -Uri "https://graph.microsoft.com/beta/identity/authenticationEventListeners/<listener-id>" `
  -Body $body -ContentType "application/json"
```

Also confirm `conditions.applications.includeApplications` on the listener lists the correct client app ID — a listener scoped to the wrong `appId` never fires for the affected sign-in.

**Rollback:** revert `priority` to its prior value via the same PATCH.

</details>

<details><summary>Fix 3 — Key mismatch / decrypt failures in your Function</summary>

**Symptom:** Function receives the call but decryption throws; users get stuck in `Retry` indefinitely.

```powershell
$app = Get-MgApplication -ApplicationId "<extension-app-object-id>"
$app.KeyCredentials | Select-Object KeyId, EndDateTime

# Re-patch keyCredentials + tokenEncryptionKeyId together — they must reference the same GUID
$keyGuid = [guid]::NewGuid().ToString()
$body = @{
    keyCredentials = @(@{
        endDateTime   = (Get-Date).AddYears(1).ToString("o")
        keyId         = $keyGuid
        startDateTime = (Get-Date).ToString("o")
        type          = "AsymmetricX509Cert"
        usage         = "Encrypt"
        key           = "<base64-encoded-public-cert>"
        displayName   = "CN=JitMigration"
    })
    tokenEncryptionKeyId = $keyGuid
} | ConvertTo-Json -Depth 5
Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/<extension-app-object-id>" -Body $body -ContentType "application/json"
```

**Rollback:** re-patch with the previous `keyCredentials`/`tokenEncryptionKeyId` pair if you have it recorded.

</details>

<details><summary>Fix 4 — Throttling or timeout on the extension call</summary>

**Symptom:** `CustomExtensionThrottlingError` or `CustomExtensionTimedOut` in sign-in logs, usually during a large migration wave.

```powershell
# Raise the per-call timeout and retry count on the extension policy (max values are capped by the service)
$body = @{ clientConfiguration = @{ timeoutInMilliseconds = 4000; maximumRetries = 2 } } | ConvertTo-Json
Invoke-MgGraphRequest -Method PATCH `
  -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions/<extension-id>" `
  -Body $body -ContentType "application/json"
```

Longer-term: stage the migration in batches rather than cutting the whole user base over at once — throttling is a tenant-wide/per-extension limit, not something you can fully eliminate with config alone. Check current caps in `CIAMMigration-A.md` Command Cheat Sheet.

**Rollback:** revert `timeoutInMilliseconds`/`maximumRetries` to prior values.

</details>

<details><summary>Fix 5 — UpdatePassword loop / Native Auth hard error on weak legacy passwords</summary>

**Symptom:** User re-enters correct legacy credentials but is repeatedly routed to a password reset because their old password doesn't meet External ID's strong-password policy. In embedded (Native Auth) apps this can surface as a raw error instead of a reset prompt.

```powershell
# Enable disableStrongPassword on the custom extension so legacy-valid passwords aren't force-reset
$body = @{ disableStrongPassword = $true } | ConvertTo-Json
Invoke-MgGraphRequest -Method PATCH `
  -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions/<extension-id>" `
  -Body $body -ContentType "application/json"
```

**Security trade-off — do not leave this on indefinitely.** It only relaxes complexity, not the 8-character minimum or expiry checks. Time-box the coexistence period and plan a forced rotation once migration completes.

**Rollback:** set `disableStrongPassword = $false`.

</details>

<details><summary>Fix 6 — Every sign-in returns Block</summary>

**Symptom:** All migrating users see the Block screen ("Admin has blocked your sign-in attempt").

Most common cause: your Function is defaulting to `Block` on an unhandled exception, or the legacy IdP call itself is failing (network/credentials/outage) and your code maps that failure to `Block` instead of `Retry`.

```
1. Pull Azure Function logs for the time window — look for exceptions in ProcessResponse/legacy-IdP call
2. Confirm the legacy IdP endpoint is reachable from the Function's outbound network path
3. Confirm the Function isn't defaulting unhandled errors to Block — Retry is almost always the safer default
```

No rollback needed — this is a code/config fix in your Function, not an Entra-side setting.

</details>

<details><summary>Fix 7 — Admin consent missing on the extension app</summary>

**Symptom:** 401/403 when the extension is invoked; Graph shows no application permission grant for `CustomAuthenticationExtension.Receive.Payload`.

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All","AppRoleAssignment.ReadWrite.All"

$graphSp = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
$extSp   = Get-MgServicePrincipal -Filter "AppId eq '<extension-app-id>'"
$role    = $graphSp.AppRoles | Where-Object { $_.Value -eq "CustomAuthenticationExtension.Receive.Payload" }

New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $extSp.Id -BodyParameter @{
    PrincipalId = $extSp.Id
    ResourceId  = $graphSp.Id
    AppRoleId   = $role.Id
}
```

> Portal path: App registrations → [extension app] → API permissions → Grant admin consent.

</details>

<details><summary>Fix 8 — Extension URL misconfigured</summary>

**Symptom:** Extension consistently fails to invoke, or Graph rejects the `endpointConfiguration` update.

The `targetUrl` **must** be your own customer-hosted HTTPS endpoint (typically an Azure Function). It must **not** point at Microsoft Graph, any Entra service endpoint, or the legacy identity provider's interactive sign-in URL — Microsoft's own guidance explicitly calls this out as a hard requirement, not a best practice.

```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions/<extension-id>" |
  Select-Object -ExpandProperty endpointConfiguration
```

Fix by re-pointing `targetUrl` at the correct Function endpoint via the same PATCH pattern used in Fix 3/4.

</details>

---
## Escalation Evidence

```
ESCALATION TICKET — Entra External ID (CIAM) JIT Password Migration
================================================
Date/Time:                  _______________
Reported by:                _______________
Affected user UPN:          _______________
Affected user object ID:    _______________
Client app ID:               _______________
Custom extension app ID:     _______________
Custom extension policy ID:  _______________
Listener policy ID:          _______________

Symptom:                    _______________
Response action returned:   MigratePassword / UpdatePassword / Retry / Block / none
Sign-in log correlation ID: _______________
Error code (if any):        _______________

Triage results:
  Migration flag on user:        _______________
  Listener priority conflict:    _______________
  keyId == tokenEncryptionKeyId: _______________
  Admin consent granted:         _______________
  disableStrongPassword state:   _______________

Azure Function logs attached:  Y / N
Steps already taken:            _______________
Escalating to:                  _______________
```

---
## 🎓 Learning Pointers

- **This is JIT migration, not password validation.** The legacy IdP is only ever consulted on the user's *first* sign-in after cutover. Every sign-in after a successful `MigratePassword` response authenticates directly against External ID — if a "migrated" user is still hitting your legacy IdP, the migration flag didn't actually clear. [How-to: JIT password migration](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-migrate-passwords-just-in-time)
- **`disableStrongPassword` is a time-boxed coexistence tool, not a permanent setting.** It doesn't touch the 8-character minimum or password expiry — only complexity. Plan the rotation-out before you plan the rotation-in.
- **The Block response should be rare and intentional.** If your Function is silently mapping every unhandled exception to `Block`, you'll fail-closed on transient legacy-IdP outages instead of letting users `Retry`.
- **Throttling is real at migration-wave scale.** `CustomExtensionThrottlingError`/`CustomExtensionTimedOut` are documented, expected failure modes for large simultaneous cutovers — batch the rollout rather than treating every occurrence as a bug. [Service limits](https://learn.microsoft.com/en-us/entra/external-id/customers/reference-service-limits) · [Troubleshoot a custom authentication extension](https://learn.microsoft.com/en-us/entra/identity-platform/custom-extension-troubleshoot)
- **Azure AD B2C is closed to new customers (as of May 1, 2025).** If this ticket originated as "why can't we just keep using B2C," the answer is it's no longer purchasable for new tenants — External ID for customers is the forward path. [B2C FAQ](https://learn.microsoft.com/en-us/azure/active-directory-b2c/faq?tabs=app-reg-ga#azure-ad-b2c-end-of-sale)
- **Don't confuse this with workforce B2B.** This entire topic lives in an External ID *for customers* (CIAM) tenant. Guest/partner collaboration in a workforce tenant is a completely different system — see `ExternalIdentities-B.md`/`-A.md`.
