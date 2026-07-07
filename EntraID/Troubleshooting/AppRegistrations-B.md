# App Registrations & Service Principal Credentials — Hotfix Runbook (Mode B: Ops)

> Fix or escalate in under 10 minutes. An automation, Power Automate flow, Graph API integration, or SSO app has suddenly stopped authenticating.

---

## Skim Index
- [Triage (60 sec)](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

Run these against Microsoft Graph. You need at least `Application.Read.All` to read; `Application.ReadWrite.All` to fix.

```powershell
Connect-MgGraph -Scopes "Application.Read.All" -NoWelcome

# 1. Find the app registration by name or client ID
$app = Get-MgApplication -Filter "displayName eq '<AppName>'"
# or: $app = Get-MgApplication -ApplicationId "<objectId>"
$app | Select-Object DisplayName, AppId, Id, SignInAudience

# 2. Check ALL credentials and their expiry — this is the #1 root cause
$app.PasswordCredentials | Select-Object DisplayName, KeyId, StartDateTime, EndDateTime,
    @{N="ExpiredOrExpiring";E={ $_.EndDateTime -lt (Get-Date).AddDays(7) }}
$app.KeyCredentials | Select-Object DisplayName, KeyId, StartDateTime, EndDateTime, Type,
    @{N="ExpiredOrExpiring";E={ $_.EndDateTime -lt (Get-Date).AddDays(7) }}

# 3. Check who owns this app — if empty, expiry warning emails went nowhere
Get-MgApplicationOwner -ApplicationId $app.Id | Select-Object DisplayName, UserPrincipalName, Mail

# 4. Check the Service Principal exists and is enabled IN THIS TENANT
Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" |
    Select-Object DisplayName, AccountEnabled, AppOwnerOrganizationId

# 5. Pull recent sign-in failures for this app (Service Principal sign-ins, NOT user sign-ins)
Get-MgAuditLogSignIn -Filter "appId eq '$($app.AppId)'" -Top 10 |
    Select-Object CreatedDateTime, AppDisplayName,
        @{N="ErrorCode";E={$_.Status.ErrorCode}},
        @{N="FailureReason";E={$_.Status.FailureReason}}
# NOTE: this cmdlet returns USER sign-ins. For pure app-only (client credential) failures,
# use the Entra portal: Identity > Applications > Enterprise applications > Sign-in logs >
# tab "Service principal sign-ins" — Graph PowerShell has no dedicated cmdlet for this feed.
```

**Interpret — if X then do Y:**

| Finding | Next action |
|---|---|
| `PasswordCredentials`/`KeyCredentials` with `EndDateTime` in the past | Secret/cert has expired — see [Fix 1](#fix-1--rotate-an-expired-or-expiring-credential) |
| `EndDateTime` within 7 days | Rotate now before it becomes an outage — see [Fix 1](#fix-1--rotate-an-expired-or-expiring-credential) |
| `Get-MgApplicationOwner` returns nothing | No owner = no expiry notification ever reached a human — see [Fix 2](#fix-2--zero-owners-on-the-app-registration) |
| Error `AADSTS7000215` or `AADSTS7000222` | Client secret invalid or expired — go straight to [Fix 1](#fix-1--rotate-an-expired-or-expiring-credential) |
| Error `AADSTS700027` | Certificate/client-assertion auth failing — see [Fix 3](#fix-3--certificate-based-auth-failing-aadsts700027) |
| Error `AADSTS500011` | Service principal missing in the target tenant — see [Fix 4](#fix-4--service-principal-missing-in-target-tenant) |
| Error `AADSTS65001` | Consent missing/revoked — see [Fix 5](#fix-5--consent-missing-or-revoked) |
| Credentials look fine, `AccountEnabled: False` on the Service Principal | Someone (or a Conditional Access / security review) disabled the SP — re-enable and investigate why |

---

## Dependency Cascade

<details><summary>What must be true for an app-only (client credential) sign-in to succeed — click to expand</summary>

```
[App Registration exists — multi-tenant object, lives in the app's HOME tenant]
    │   Has: Application (client) ID — same value in every tenant
    │   Has: passwordCredentials[] (secrets) and/or keyCredentials[] (certs)
    │
    ▼
[Credential is valid — not expired, not deleted, matches what the caller is presenting]
    │   Secrets: max 24-month lifetime on anything created after the 2023 policy change
    │   Certs: no hard Microsoft-enforced ceiling, but org policy should still rotate them
    │
    ▼
[Service Principal exists IN THE TENANT being authenticated against]
    │   Created automatically on first admin consent, OR manually via
    │   New-MgServicePrincipal for multi-tenant scenarios
    │   Home-tenant app registration ≠ automatic SP in every other tenant
    │
    ▼
[Service Principal is enabled (AccountEnabled: true) in that tenant]
    │
    ▼
[API permissions requested by the app have been GRANTED CONSENT in this tenant]
    │   Application permissions (app-only) always require admin consent
    │   Delegated permissions can be user- or admin-consented depending on policy
    │
    ▼
[Token issued by Entra, scoped to the consented permissions]
    │
    ▼
[Downstream API (Graph, a SaaS app, a custom API) validates the token's roles/scp claim]
    │
    ▼
[Call succeeds]
```

**What silently breaks this and produces zero proactive warning to anyone:**
- App registration has no owners → expiry emails have no recipient
- Secret was rotated by one team, not communicated to the team whose Key Vault / Power Automate connection / Azure Function app setting still references the old value
- App is multi-tenant but was never explicitly consented in a *new* customer tenant — works fine in the tenant it was built in, fails everywhere else with `AADSTS500011`

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Identify the app and pull every credential with its expiry**
```powershell
Connect-MgGraph -Scopes "Application.Read.All" -NoWelcome
$app = Get-MgApplication -Filter "displayName eq '<AppName>'"
$app.PasswordCredentials + $app.KeyCredentials |
    Select-Object DisplayName, KeyId, StartDateTime, EndDateTime |
    Sort-Object EndDateTime | Format-Table -AutoSize
```
Healthy: at least one credential with `EndDateTime` well in the future. Broken: the credential the caller is actually using has an `EndDateTime` in the past — cross-check the `KeyId`/thumbprint the failing system is configured with, not just "an" unexpired credential existing.

**Step 2 — Confirm which credential the failing system is actually using**
The app can have multiple secrets/certs simultaneously. Check the consuming system's configuration (Key Vault secret, `appsettings.json`, Power Automate connection reference, Azure Function app setting) for the exact `KeyId` or secret value prefix it's presenting — don't assume it's using the newest one.

**Step 3 — Check owners**
```powershell
Get-MgApplicationOwner -ApplicationId $app.Id | Select-Object DisplayName, UserPrincipalName, AccountEnabled
```
Broken: empty result, or all owners show `AccountEnabled: False` (departed staff). Expiry notification emails (30-day and day-of) go only to owners — zero owners means the expiry was always going to be a surprise.

**Step 4 — Confirm the Service Principal exists and is enabled in the target tenant**
```powershell
Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" |
    Select-Object DisplayName, AccountEnabled, AppOwnerOrganizationId, Tags
```
Broken: no results at all (SP was never created here — see [Fix 4](#fix-4--service-principal-missing-in-target-tenant)), or `AccountEnabled: False`.

**Step 5 — Check granted permissions vs. requested permissions**
```powershell
$sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'"
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id |
    Select-Object PrincipalDisplayName, AppRoleId, ResourceDisplayName
Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id |
    Select-Object ClientId, ConsentType, Scope
```
Broken: the app's manifest requests a permission (`RequiredResourceAccess` in `Get-MgApplication`) that has no matching entry here — it was requested but never consented.

**Step 6 — Pull service principal sign-in logs (portal, not Graph PowerShell)**
Entra admin center → **Identity** → **Applications** → **Enterprise applications** → select the app → **Sign-in logs** → tab **Service principal sign-ins**. Graph PowerShell's `Get-MgAuditLogSignIn` only surfaces interactive/user sign-ins reliably in most module versions — for pure client-credential (app-only) failures this portal tab is the authoritative source. Note the exact error code shown there.

---

## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — Rotate an expired or expiring credential</summary>

**Symptom:** `AADSTS7000215` (invalid client secret) or `AADSTS7000222` (client secret keys are expired). `EndDateTime` on the active credential is in the past or within days.

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All" -NoWelcome
$app = Get-MgApplication -Filter "displayName eq '<AppName>'"

# Create a new secret (max recommended: 12 months; hard ceiling: 24 months on new secrets)
$passwordCred = @{
    displayName = "Rotated-$(Get-Date -Format yyyyMMdd)"
    endDateTime = (Get-Date).AddMonths(12)
}
$newSecret = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential $passwordCred
Write-Host "NEW SECRET VALUE (copy now — it is never retrievable again):" -ForegroundColor Yellow
Write-Host $newSecret.SecretText -ForegroundColor Yellow
```

Update every consumer that references this app's credential — Key Vault secret, Power Automate connection reference, Azure Function/App Service application setting, Logic App API connection, on-prem service's config file. Missing a consumer is the most common reason a "fixed" app breaks again in a different system a week later.

After updating consumers, remove the expired credential so it stops cluttering audits and can't be accidentally re-referenced:
```powershell
Remove-MgApplicationPassword -ApplicationId $app.Id -KeyId "<expiredKeyId>"
```

**Rollback:** the old secret is gone once removed. If something still needs it, create a fresh one — Entra never returns a previously-issued secret value again.

</details>

<details id="fix-2"><summary>Fix 2 — Zero owners on the app registration</summary>

**Symptom:** `Get-MgApplicationOwner` returns nothing, or only returns disabled/departed accounts. This app's next credential expiry will generate no warning to anyone.

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All" -NoWelcome
$app   = Get-MgApplication -Filter "displayName eq '<AppName>'"
$owner = Get-MgUser -UserId "<owner@domain.com>"

New-MgApplicationOwnerByRef -ApplicationId $app.Id -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($owner.Id)"
}
```

Prefer adding a shared mailbox or a team distribution list's associated account (or at minimum two named individuals) rather than a single person — the whole point is redundancy so this doesn't happen again when one person leaves. Also add the owner to the **Service Principal**, not just the App Registration — they are separate owner lists:
```powershell
$sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'"
New-MgServicePrincipalOwnerByRef -ServicePrincipalId $sp.Id -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($owner.Id)"
}
```

</details>

<details id="fix-3"><summary>Fix 3 — Certificate-based auth failing (AADSTS700027)</summary>

**Symptom:** App uses certificate-based client assertion instead of a secret. Sign-in fails with `AADSTS700027: Client assertion contains an invalid signature`.

Most common causes, in order of likelihood:
1. **Clock skew** — the JWT assertion's `nbf`/`exp` claims are outside Entra's tolerance window (~5 minutes). Check the calling system's clock.
2. **Wrong certificate thumbprint** — the app is signing with a private key whose public certificate doesn't match (or isn't) what's uploaded to the App Registration.
3. **Expired certificate** — same check as Fix 1, just against `KeyCredentials` instead of `PasswordCredentials`.

```powershell
# Confirm which certs are currently trusted for this app
$app.KeyCredentials | Select-Object DisplayName, KeyId, Type, Usage, StartDateTime, EndDateTime, CustomKeyIdentifier

# Confirm the thumbprint the calling system is actually presenting matches CustomKeyIdentifier
# (CustomKeyIdentifier is typically the cert's SHA-1 thumbprint, base64-encoded)
```

**Fix — upload a valid, non-expired certificate:**
```powershell
$certBytes = [System.IO.File]::ReadAllBytes("<path-to-public-cert.cer>")
$keyCred = @{
    displayName = "Rotated-Cert-$(Get-Date -Format yyyyMMdd)"
    type        = "AsymmetricX509Cert"
    usage       = "Verify"
    key         = $certBytes
}
Update-MgApplication -ApplicationId $app.Id -KeyCredentials (@($app.KeyCredentials) + $keyCred)
```
Only the **public** certificate is ever uploaded to Entra — the private key stays with the calling application and is never sent.

</details>

<details id="fix-4"><summary>Fix 4 — Service Principal missing in target tenant (AADSTS500011)</summary>

**Symptom:** A multi-tenant app works fine in the tenant it was created in, but a new customer/partner tenant gets `AADSTS500011: The resource principal named <appId> was not found in the tenant`.

This means the app registration exists (home tenant) but no Service Principal was ever provisioned in *this* tenant — admin consent was never granted here.

```powershell
# Have a Global Admin (or Application Administrator) in the TARGET tenant run:
Connect-MgGraph -Scopes "Application.ReadWrite.All" -NoWelcome
New-MgServicePrincipal -AppId "<appId>"
```

Or drive the standard admin-consent URL flow (preferred — this also records the specific permission consent, not just SP creation):
```
https://login.microsoftonline.com/<targetTenantId>/adminconsent?client_id=<appId>
```

**Rollback:** `Remove-MgServicePrincipal -ServicePrincipalId <id>` fully removes the app's footprint from that tenant.

</details>

<details id="fix-5"><summary>Fix 5 — Consent missing or revoked (AADSTS65001)</summary>

**Symptom:** `AADSTS65001: The user or administrator has not consented to use the application.` App-only (client credential) flows always need **admin** consent for application permissions — there is no user-consent path for those.

```powershell
$sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'"

# Check what's currently granted
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id
Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id
```

If a required permission is missing from the grant list, re-run admin consent (portal is simplest and least error-prone): **Entra admin center** → **Enterprise applications** → select the app → **Permissions** → **Grant admin consent for `<tenant>`**.

If consent was explicitly revoked (e.g., during a security review) and needs re-granting for a legitimate, still-needed integration, confirm with whoever revoked it before re-granting — a revocation is often deliberate.

</details>

---

## Escalation Evidence

```
App Registration / Service Principal — Evidence Pack
====================================
App display name:          
Application (client) ID:   
Object ID (app reg):       
Object ID (service principal):
Home tenant:                
Affected tenant (if different — multi-tenant scenario):

Credentials:
  Active secret/cert KeyId:  
  EndDateTime:                [expired / expiring / valid]
  Owners on App Registration: [list, or NONE]
  Owners on Service Principal:[list, or NONE]

Service Principal state:
  AccountEnabled:              [YES / NO]
  Exists in affected tenant:   [YES / NO]

Error details:
  Error code:                 [AADSTS.....]
  Failure reason:              
  Sign-in log timestamp:       
  Source (portal Service Principal sign-ins / app's own logs):

API permissions:
  Requested (manifest):        
  Granted (consent):           
  Gap:                         

Symptoms:
  What broke:                  [flow / integration / SSO app / script]
  When it started:              
  Recent changes:               [secret rotation / CA policy / owner departure]

Steps already tried:
```

---

## 🎓 Learning Pointers

- **An App Registration and its Service Principal are two different objects, and both can have their own, separate owners list.** The App Registration is a single global definition (home tenant). The Service Principal is the per-tenant instantiation that permissions are actually granted against. Adding an owner to one does not add them to the other — a very common reason "I added an owner but still got no expiry warning" turns out to be true, because the warning system watches the object you didn't touch. [MS Docs: Apps & service principals](https://learn.microsoft.com/en-us/entra/identity-platform/app-objects-and-service-principals)

- **Client secrets are now capped at a 24-month maximum lifetime for anything created after Microsoft's 2023 policy tightening** — you can no longer create a secret with no expiry or a multi-year lifetime through the portal or Graph. Older secrets created before the change can still be long-lived, which is exactly why they're the ones that catch teams off guard years later. Prefer 6–12 month rotation windows and calendar the renewal, don't rely on the maximum.

- **Zero-owner apps are a silent, ticking liability.** Expiry notification emails (30 days out, and on the day) are sent only to the object's owners. An app with no owner — common after someone leaves and their account is deleted, taking the sole ownership record with it — will expire with no warning to anyone until it breaks in production. This is worth a periodic tenant-wide sweep, not a one-time fix (see the companion script, `Get-AppRegistrationCredentialAudit.ps1`).

- **Federated credentials (workload identity federation) eliminate the rotation problem entirely** for workloads that support it — GitHub Actions, Azure DevOps, Kubernetes workload identity, and Azure Managed Identity can all authenticate to an App Registration via a trust relationship instead of a stored secret or certificate. Wherever the calling platform supports it, this is the actual fix, not another rotation. [MS Docs: Workload identity federation](https://learn.microsoft.com/en-us/entra/identity-platform/workload-identity-federation)

- **`AADSTS500011` almost always means "right app, wrong tenant, no consent yet"** — not a broken app registration. Engineers unfamiliar with multi-tenant app architecture frequently try to "fix" the app registration itself when the actual missing piece is a Service Principal (and consent) in the *specific* tenant that's failing. [MS Docs: AADSTS error codes](https://learn.microsoft.com/en-us/entra/identity-platform/reference-error-codes)

- **Service Principal sign-in logs are a separate tab from user sign-in logs in the Entra portal, and most Graph PowerShell cmdlets don't cleanly surface them.** If `Get-MgAuditLogSignIn` isn't showing the app-only failures you expect, that's expected behaviour, not a script bug — go to the portal's **Enterprise applications → Sign-in logs → Service principal sign-ins** tab, or use the beta `signIns` endpoint filtered on `signInEventTypes` including `servicePrincipal`.
