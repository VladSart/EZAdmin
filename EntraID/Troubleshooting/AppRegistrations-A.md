# App Registrations & Service Principal Credentials — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- App Registration objects (`applications`) and Service Principal objects (`servicePrincipals`) in Microsoft Entra ID
- Client secrets (`passwordCredentials`) and certificates (`keyCredentials`) — creation, expiry, rotation
- App-only (client credential grant) and delegated authentication flows as they relate to credential and consent failures
- Multi-tenant app scenarios: Service Principal provisioning and admin consent in a consuming tenant
- Federated credentials (workload identity federation) as a rotation-free alternative
- Ownership and lifecycle governance (who gets notified before a credential expires)

**Not in scope:**
- Conditional Access policy design targeting workload identities (Workload ID CA is a Premium P2 feature) — see `Security/ConditionalAccess/CA-Design-A.md` for general CA architecture; this document covers the underlying app/SP objects those policies would target
- Managed Identities (system-assigned or user-assigned) — these have no visible credential to rotate at all and are a different object type (`managedIdentity` service principal type); mentioned only as a contrast/alternative
- GDAP or Cross-Tenant Access Settings (XTAS) — those govern human delegated access between organizations, not app-to-app authentication; see `GDAP-A.md` and `CrossTenant-A.md`

**Assumed knowledge:**
- Comfortable with OAuth 2.0 concepts: client credentials, tokens, scopes
- Familiar with Microsoft Graph PowerShell (`Microsoft.Graph.Applications` module)
- Understands the difference between delegated and application permissions at a basic level

---

## How It Works

<details><summary>Full architecture</summary>

### Two objects, one identity

Every Entra-integrated application is represented by **two distinct directory objects** that are frequently conflated:

1. **Application (App Registration)** — the global definition. Created once, in a "home" tenant. Holds the Application (client) ID, the redirect URIs, the requested API permissions (`requiredResourceAccess`), the app's own credentials (`passwordCredentials`/`keyCredentials`), and its own owner list. If the app is registered as `AzureADMultipleOrgs` or `AzureADandPersonalMicrosoftAccount`, this single definition can be consented into any number of other tenants.

2. **Service Principal (Enterprise Application)** — the local instantiation. One is created **per tenant** the app is used in, the first time someone (or an admin, via consent) authorizes it there. This is the object that actually holds *granted* permissions (`appRoleAssignments`, `oauth2PermissionGrants`) for that specific tenant, its own `accountEnabled` flag, and — critically — its **own, separate owner list** from the App Registration.

```
Home Tenant                              Consuming Tenant A         Consuming Tenant B
┌─────────────────────────┐              ┌───────────────────┐     ┌───────────────────┐
│ Application (App Reg)    │              │ Service Principal  │     │ Service Principal  │
│  - AppId (same everywhere)│─consented──▶│  - appId (same)    │     │  - appId (same)    │
│  - passwordCredentials[]  │             │  - accountEnabled   │     │  - accountEnabled   │
│  - keyCredentials[]       │             │  - appRoleAssignments│    │  - appRoleAssignments│
│  - requiredResourceAccess │             │  - owners (LOCAL)   │     │  - owners (LOCAL)   │
│  - owners (LOCAL)         │             └───────────────────┘     └───────────────────┘
└─────────────────────────┘
```

The credential (secret or certificate) that proves the app's identity lives **only on the Application object**, in the home tenant, and is the same for every tenant the app operates in. Rotating it once updates authentication everywhere the app runs — but also means a single expired secret can break every tenant simultaneously if the app is multi-tenant.

### App-only (client credential) authentication flow

```
1. Calling system (script, Azure Function, Power Automate) holds: client_id, client_secret (or cert+private key), tenant_id
2. POST to https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token
     grant_type=client_credentials
     client_id=<appId>
     client_secret=<secret>          (or client_assertion=<signed JWT> for cert auth)
     scope=https://graph.microsoft.com/.default
3. Entra validates:
     a. Does an Application object with this client_id exist? (home tenant lookup, client_id is global)
     b. Does the presented secret/cert match a non-expired entry in passwordCredentials/keyCredentials?
     c. Does a Service Principal for this appId exist in <tenant>? (AADSTS500011 if not)
     d. Is that Service Principal accountEnabled?
     e. Have the requested scopes been admin-consented in <tenant>? (AADSTS65001 if not)
4. Entra issues an access token containing a "roles" claim listing the granted application permissions
5. Downstream API (e.g., Microsoft Graph) authorizes the call based on the roles claim
```

Every one of steps 3a–3e fails with a distinct, greppable AADSTS error code — the troubleshooting discipline here is almost entirely "read the exact error code, map it to the exact step that failed," rather than guessing.

### Credential lifecycle and Microsoft's 2023 tightening

Prior to a 2023 platform change, client secrets could be created with no expiry or multi-year lifetimes through the API (the portal always enforced sane defaults, but Graph/PowerShell did not). Microsoft now enforces a **hard maximum of 24 months** on any new secret created via the portal, Graph API, or PowerShell — you cannot create a longer-lived one even by requesting it. Certificates have no equivalent platform-enforced ceiling, which is one reason organizations with strict rotation requirements prefer certificate-based auth or, better, federated credentials that need no rotation at all.

**Notification behavior:** Entra sends automated emails at two points — approximately 30 days before expiry, and on the day of expiry — to the **owners of the Application object**. Not to the Service Principal's owners (a separate list). Not to any security or IT distribution list by default. Not to anyone if the owner list is empty, which happens routinely when the person who registered the app leaves the organization and their account is deleted along with the ownership record.

### Federated credentials (the rotation-free alternative)

Workload identity federation lets a workload (GitHub Actions, Azure DevOps pipeline, Kubernetes service account, another Azure AD tenant's managed identity) present a short-lived, platform-issued OIDC token instead of a stored secret. Entra validates the token's issuer/subject against a configured trust relationship (`federatedIdentityCredentials`) rather than checking it against a stored secret value. There is nothing to rotate and nothing to leak, because no long-lived credential exists at all. This is the recommended direction for any new CI/CD or cloud-native integration where the calling platform supports it — GitHub Actions and Azure DevOps both do natively.

### Multi-tenant apps and the "works here, not there" trap

A multi-tenant App Registration's credentials are shared globally, but its **consent and Service Principal existence are per-tenant**. This produces a specific, recurring support pattern: an integration works flawlessly in the tenant it was built and tested in, then fails immediately with `AADSTS500011` the moment it's pointed at a second customer or partner tenant, because nobody ran the admin-consent step there. This is not a credential problem and rotating the secret will not fix it.

</details>

---

## Dependency Stack

```
Downstream API call succeeds (Graph, custom API, SaaS integration)
        │
        ▼
Access token issued with correct "roles" (app permissions) claim
        │
        ▼
Requested API permission was ADMIN-CONSENTED in the target tenant
        (appRoleAssignedTo on the Service Principal)
        │
        ▼
Service Principal exists in the target tenant AND is accountEnabled
        (created automatically on first consent, or via New-MgServicePrincipal)
        │
        ▼
Presented credential (secret or cert) matches a NON-EXPIRED entry
        on the Application object's passwordCredentials/keyCredentials
        │
        ├── Secret path: client_secret string matches, EndDateTime in future
        │
        └── Certificate path: JWT client_assertion signed by a private key whose
                public cert is uploaded, thumbprint matches, clock skew < ~5 min
        │
        ▼
Application object exists (found by AppId — global lookup via home tenant)
        │
        ▼
Someone/something is watching credential expiry BEFORE it happens
        (App Registration owners receive the 30-day/day-of notification emails —
         empty owner list = no notification = this whole stack fails blind)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Automation/flow that has run for months suddenly fails with 401/403 | Client secret or certificate expired | `PasswordCredentials`/`KeyCredentials` `EndDateTime` on the Application object |
| `AADSTS7000215` | Invalid client secret presented | Confirm the consuming system's configured secret matches a current, non-expired `KeyId` |
| `AADSTS7000222` | Client secret keys are expired (all of them) | Every `passwordCredentials` entry has `EndDateTime` in the past |
| `AADSTS700027` | Client assertion (cert-based auth) has an invalid signature | Clock skew, wrong private key, expired or unmatched certificate thumbprint |
| `AADSTS500011` | Resource principal (Service Principal) not found in the tenant being called | `Get-MgServicePrincipal -Filter "appId eq '<id>'"` returns nothing in that tenant |
| `AADSTS65001` | Admin/user has not consented | `Get-MgServicePrincipalAppRoleAssignedTo` / `Get-MgServicePrincipalOauth2PermissionGrant` missing the required scope |
| `AADSTS90002` | Tenant identifier in the request doesn't resolve | Typo'd tenant ID/domain in the calling system's config, or tenant was renamed/decommissioned |
| Integration worked in the dev/test tenant, fails in every new customer tenant | Multi-tenant app never had its Service Principal + consent provisioned in the new tenant | Run the admin-consent URL flow in the new tenant |
| "Nobody knew this was about to expire" | Zero owners on the Application object, or all owners are disabled/departed accounts | `Get-MgApplicationOwner` |
| Credential was rotated, a *different* system that also used the old one broke a week later | Rotation didn't account for all consumers of a shared app registration | Audit every Key Vault secret, connection reference, and app setting that stores this AppId's credential |
| App suddenly stopped signing users in entirely, but API/service calls still work | Service Principal `accountEnabled` set to `false` (often via a security review or CA block) | `Get-MgServicePrincipal` → `AccountEnabled` |
| Certificate-based app works from one server, fails from another with the same cert | Clock drift on the failing server | Compare server time against an authoritative NTP source; `AADSTS700027` tolerance is tight |

---

## Validation Steps

### Step 1 — Locate the app and inventory every credential

```powershell
Connect-MgGraph -Scopes "Application.Read.All" -NoWelcome
$app = Get-MgApplication -Filter "displayName eq '<AppName>'"
$app.PasswordCredentials | Select-Object DisplayName, KeyId, StartDateTime, EndDateTime
$app.KeyCredentials     | Select-Object DisplayName, KeyId, Type, StartDateTime, EndDateTime
```
**Good:** at least one credential per auth method in use, `EndDateTime` comfortably in the future (30+ days). **Bad:** the credential actually configured in the consuming system has an `EndDateTime` in the past, or is absent from this list entirely (deleted).

---

### Step 2 — Confirm ownership on BOTH objects

```powershell
Get-MgApplicationOwner -ApplicationId $app.Id | Select-Object DisplayName, UserPrincipalName, AccountEnabled
$sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'"
Get-MgServicePrincipalOwner -ServicePrincipalId $sp.Id | Select-Object DisplayName, UserPrincipalName, AccountEnabled
```
**Good:** two or more enabled owners on each object (redundancy against departures). **Bad:** empty, or owners whose `AccountEnabled` is `false`.

---

### Step 3 — Confirm Service Principal state in the affected tenant

```powershell
Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" |
    Select-Object DisplayName, AccountEnabled, AppOwnerOrganizationId, ServicePrincipalType, Tags
```
**Good:** one result, `AccountEnabled: true`, `ServicePrincipalType` is `Application` (not `ManagedIdentity` unless expected). **Bad:** no results (never consented here) or `AccountEnabled: false`.

---

### Step 4 — Diff requested permissions against granted permissions

```powershell
# Requested (defined on the Application object's manifest)
$app.RequiredResourceAccess | ForEach-Object {
    $resourceSp = Get-MgServicePrincipal -Filter "appId eq '$($_.ResourceAppId)'"
    $_.ResourceAccess | ForEach-Object {
        [PSCustomObject]@{ Resource = $resourceSp.DisplayName; PermissionId = $_.Id; Type = $_.Type }
    }
}

# Granted (application permissions actually assigned to the Service Principal)
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id |
    Select-Object PrincipalDisplayName, AppRoleId, ResourceDisplayName

# Granted (delegated permissions, if applicable)
Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id |
    Select-Object ClientId, ConsentType, Scope
```
**Good:** every requested permission has a matching granted entry. **Bad:** a gap — the app was updated to request a new permission but nobody re-consented.

---

### Step 5 — Certificate-specific validation (if cert-based auth is in use)

```powershell
$app.KeyCredentials | Select-Object DisplayName, Type, Usage, StartDateTime, EndDateTime, CustomKeyIdentifier
```
Cross-check `CustomKeyIdentifier` (the trusted cert's thumbprint, base64-encoded) against the thumbprint of the certificate the calling system is actually presenting. A mismatch here — not expiry — is the most common cause of `AADSTS700027` when the expiry dates look fine.

---

### Step 6 — Confirm tenant-wide credential hygiene (fleet view)

```powershell
Get-MgApplication -All | ForEach-Object {
    $expiring = ($_.PasswordCredentials + $_.KeyCredentials) | Where-Object { $_.EndDateTime -lt (Get-Date).AddDays(30) }
    if ($expiring) {
        [PSCustomObject]@{
            AppName    = $_.DisplayName
            AppId      = $_.AppId
            SoonestExp = ($expiring.EndDateTime | Sort-Object | Select-Object -First 1)
            OwnerCount = (Get-MgApplicationOwner -ApplicationId $_.Id -All).Count
        }
    }
}
```
**Good:** every app on this list has `OwnerCount` ≥ 1. **Bad:** any app with `OwnerCount = 0` and an imminent expiry — this is a guaranteed future outage with no warning path. See the companion script for the full, exportable version of this audit.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm which object and which layer is actually broken

1. Get the exact `AADSTS` error code first — every subsequent step depends on it. Guessing "it's probably the secret" without the code wastes time on the wrong object roughly as often as it's right.
2. Confirm you're looking at the right tenant. Multi-tenant apps have identical `AppId` values everywhere — Service Principal state, consent, and `accountEnabled` are all tenant-local and must be checked in the specific tenant that's failing.

### Phase 2 — Credential-layer issues

1. Run Validation Steps 1 and 5. Confirm the *specific* credential the failing system presents (not just "an unexpired one exists") is valid.
2. If expired: rotate (Fix 1 in the Mode B runbook), then verify every consumer was updated — not just the one that surfaced the ticket.
3. If certificate-based and expiry looks fine: check clock skew on the calling server before assuming the certificate itself is bad.

### Phase 3 — Object/consent-layer issues

1. Run Validation Steps 3 and 4.
2. Missing Service Principal in this tenant → this is a provisioning gap, not a credential problem. Run the admin-consent flow.
3. Service Principal exists but permissions gap found → re-run admin consent; do not attempt to patch individual `appRoleAssignments` by hand unless you fully understand the specific `AppRoleId` GUIDs involved — the portal consent flow is far less error-prone.

### Phase 4 — Governance/prevention layer

1. Run Validation Step 2 (ownership) and Step 6 (fleet-wide expiry sweep) regardless of whether they caused today's incident — a ticket for one expired app is the highest-value moment to check whether siblings are about to do the same thing.
2. For any app found with zero owners, add at least two before closing the ticket.
3. For any app whose calling platform supports it (GitHub Actions, Azure DevOps, Kubernetes, cross-tenant Managed Identity), flag it as a federated-credential migration candidate rather than scheduling yet another manual rotation.

### Phase 5 — Multi-tenant-specific

1. If the same app works in one tenant and not another, do not touch credentials at all — go straight to Service Principal + consent verification in the failing tenant (Validation Steps 3–4).
2. Confirm the app's `SignInAudience` property actually supports the tenant in question (`AzureADMultipleOrgs` or `AzureADandPersonalMicrosoftAccount` required for cross-tenant use — `AzureADMyOrg` restricts it to the home tenant only, and no amount of consent will make it work elsewhere).

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full credential rotation with zero-downtime overlap</summary>

Create the new credential *before* removing the old one so there's an overlap window with no outage:

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All" -NoWelcome
$app = Get-MgApplication -Filter "displayName eq '<AppName>'"

# 1. Add new secret (old one still valid and in use)
$newSecret = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential @{
    displayName = "Rotated-$(Get-Date -Format yyyyMMdd)"
    endDateTime = (Get-Date).AddMonths(12)
}
Write-Host "New secret (save immediately): $($newSecret.SecretText)" -ForegroundColor Yellow

# 2. Update EVERY consumer — Key Vault, app settings, connection references
#    (enumerate consumers first; do not assume there is only one)

# 3. Verify the new secret authenticates successfully from at least one consumer
#    before removing the old one

# 4. Remove the old credential only after verification
Remove-MgApplicationPassword -ApplicationId $app.Id -KeyId "<oldKeyId>"
```

**Rollback:** if the new secret fails validation, do not remove the old one — leave both in place, investigate, and only remove the old credential once the new one is confirmed working end-to-end.

</details>

<details><summary>Playbook 2 — Migrate a workload from client secret to federated credential</summary>

Example: GitHub Actions workflow authenticating to Azure/Graph.

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All" -NoWelcome
$app = Get-MgApplication -Filter "displayName eq '<AppName>'"

$params = @{
    name        = "github-actions-main"
    issuer      = "https://token.actions.githubusercontent.com"
    subject     = "repo:<org>/<repo>:ref:refs/heads/main"
    audiences   = @("api://AzureADTokenExchange")
    description = "Federated credential for GitHub Actions main branch deploys"
}
New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter $params
```

Once the calling workflow authenticates successfully using the federated credential (no `client_secret` needed at all — the platform's OIDC token is exchanged automatically), remove the client secret it previously used, closing the rotation liability entirely for this consumer.

**Rollback:** `Remove-MgApplicationFederatedIdentityCredential` removes the trust; re-add a client secret if reverting.

</details>

<details><summary>Playbook 3 — Provision consent for a multi-tenant app in a new tenant</summary>

```powershell
# Preferred: admin-consent URL, run by a Global Admin / Application Administrator in the TARGET tenant
# (browser flow — records granular per-permission consent correctly)
$url = "https://login.microsoftonline.com/<targetTenantId>/adminconsent?client_id=<appId>"
Write-Host "Have target-tenant admin open: $url"

# Programmatic alternative (creates the SP, but application-permission grants still need
# a separate appRoleAssignment step — the URL flow above is simpler and less error-prone)
Connect-MgGraph -Scopes "Application.ReadWrite.All" -NoWelcome -TenantId "<targetTenantId>"
New-MgServicePrincipal -AppId "<appId>"
```

**Rollback:** `Remove-MgServicePrincipal` in the target tenant fully removes the app's footprint there without affecting any other tenant.

</details>

<details><summary>Playbook 4 — Tenant-wide ownership backfill for zero-owner apps</summary>

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All" -NoWelcome
$fallbackOwner = Get-MgUser -UserId "<itops-shared-mailbox-or-lead@domain.com>"

$orphaned = Get-MgApplication -All | Where-Object {
    (Get-MgApplicationOwner -ApplicationId $_.Id -All).Count -eq 0
}

foreach ($orphan in $orphaned) {
    New-MgApplicationOwnerByRef -ApplicationId $orphan.Id -BodyParameter @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($fallbackOwner.Id)"
    }
    Write-Host "Added fallback owner to: $($orphan.DisplayName)" -ForegroundColor Green
}
```

Treat the fallback owner as a stopgap, not a permanent solution — follow up to identify the actual business owner for each app so expiry notifications reach someone who understands what breaks if it's ignored.

**Rollback:** `Remove-MgApplicationOwnerByRef` per app if the fallback was added in error.

</details>

---

## Evidence Pack

```powershell
Connect-MgGraph -Scopes "Application.Read.All" -NoWelcome
$outputDir = "C:\Temp\AppReg-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$app = Get-MgApplication -Filter "displayName eq '<AppName>'"
$sp  = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'"

# 1. Application object detail
$app | Select-Object DisplayName, AppId, Id, SignInAudience |
    ConvertTo-Json -Depth 5 | Out-File "$outputDir\01-Application.json"

# 2. Credentials
($app.PasswordCredentials + $app.KeyCredentials) |
    Select-Object DisplayName, KeyId, StartDateTime, EndDateTime |
    Export-Csv "$outputDir\02-Credentials.csv" -NoTypeInformation

# 3. Owners (both objects)
Get-MgApplicationOwner -ApplicationId $app.Id |
    Select-Object DisplayName, UserPrincipalName, AccountEnabled |
    Export-Csv "$outputDir\03-AppOwners.csv" -NoTypeInformation
if ($sp) {
    Get-MgServicePrincipalOwner -ServicePrincipalId $sp.Id |
        Select-Object DisplayName, UserPrincipalName, AccountEnabled |
        Export-Csv "$outputDir\04-SPOwners.csv" -NoTypeInformation
}

# 4. Service Principal state and grants
if ($sp) {
    $sp | Select-Object DisplayName, AccountEnabled, AppOwnerOrganizationId |
        ConvertTo-Json | Out-File "$outputDir\05-ServicePrincipal.json"
    Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id |
        Export-Csv "$outputDir\06-AppRoleAssignments.csv" -NoTypeInformation
    Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id |
        Export-Csv "$outputDir\07-OAuth2Grants.csv" -NoTypeInformation
}

# 5. Metadata
[PSCustomObject]@{ CollectedAt = (Get-Date).ToString("u"); TenantId = (Get-MgContext).TenantId } |
    ConvertTo-Json | Out-File "$outputDir\00-CollectionMetadata.json"

Write-Host "Evidence collected to: $outputDir" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| Find an app by name | `Get-MgApplication -Filter "displayName eq '<name>'"` |
| List all credentials + expiry | `$app.PasswordCredentials + $app.KeyCredentials` |
| Add a new client secret | `Add-MgApplicationPassword -ApplicationId <id> -PasswordCredential @{...}` |
| Remove a credential | `Remove-MgApplicationPassword -ApplicationId <id> -KeyId <keyId>` |
| Upload a certificate | `Update-MgApplication -ApplicationId <id> -KeyCredentials @(...)` |
| Check Application owners | `Get-MgApplicationOwner -ApplicationId <id>` |
| Add an Application owner | `New-MgApplicationOwnerByRef -ApplicationId <id> -BodyParameter @{"@odata.id"=...}` |
| Find the Service Principal for an app | `Get-MgServicePrincipal -Filter "appId eq '<appId>'"` |
| Check Service Principal owners | `Get-MgServicePrincipalOwner -ServicePrincipalId <id>` |
| Create SP in a new tenant (multi-tenant app) | `New-MgServicePrincipal -AppId <appId>` (run in target tenant) |
| List granted application permissions | `Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId <id>` |
| List granted delegated permissions | `Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId <id>` |
| Admin consent URL (browser flow) | `https://login.microsoftonline.com/<tenant>/adminconsent?client_id=<appId>` |
| Add a federated credential | `New-MgApplicationFederatedIdentityCredential -ApplicationId <id> -BodyParameter @{...}` |
| Disable/enable a Service Principal | `Update-MgServicePrincipal -ServicePrincipalId <id> -AccountEnabled:$false` |

---

## 🎓 Learning Pointers

- **The App Registration and the Service Principal are not the same object, do not share an owner list, and fail differently.** The single most common misdiagnosis in this space is treating them as one thing. Credentials live only on the Application object (home tenant); enablement, granted permissions, and per-tenant owners live only on the Service Principal. Build the habit of checking both, every time. [MS Docs: Apps & service principals](https://learn.microsoft.com/en-us/entra/identity-platform/app-objects-and-service-principals)

- **Microsoft's 24-month secret lifetime cap (introduced 2023) only applies going forward** — pre-existing longer-lived secrets are grandfathered in and will keep working until their original expiry. Don't assume a fleet-wide audit is clean just because "new secrets can't be created long-lived anymore"; the dangerous ones are the old ones nobody remembers creating.

- **Federated credentials are the actual fix for the rotation problem, not just another workaround.** Any time a ticket says "the secret expired again," the right follow-up question is whether the calling platform (GitHub Actions, Azure DevOps, Kubernetes, another Azure tenant's managed identity) supports workload identity federation — if it does, migrating removes the recurring task permanently instead of scheduling the next rotation. [MS Docs: Workload identity federation](https://learn.microsoft.com/en-us/entra/identity-platform/workload-identity-federation)

- **AADSTS error codes map to specific, mechanical failure points in the auth flow** — memorizing the handful that show up repeatedly (7000215, 7000222, 700027, 500011, 65001, 90002) turns a vague "the integration is broken" ticket into a two-minute diagnosis instead of a guessing exercise. [MS Docs: AADSTS error code reference](https://learn.microsoft.com/en-us/entra/identity-platform/reference-error-codes)

- **Zero-owner app registrations are a governance gap that only shows up as an outage, never as a warning.** Because expiry notifications go exclusively to owners, an orphaned app is invisible until it fails. Treat "does this app have at least two enabled owners" as a standing item in any credential-related ticket, not a one-off fix — see the companion script `Get-AppRegistrationCredentialAudit.ps1` for a tenant-wide sweep.

- **A multi-tenant app failing in a new tenant is a provisioning problem, not a credential problem — rotating the secret will not fix `AADSTS500011`.** The credential is shared across every tenant the app operates in; what's missing is tenant-local (Service Principal existence and consent). Recognizing this distinction quickly avoids an unnecessary and disruptive credential rotation on an app that was working fine everywhere else.
