# Entra Verified ID — Reference Runbook (Mode A: Deep Dive)
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
- Microsoft Entra Verified ID architecture: issuer, holder, verifier, decentralized identifier (DID), DID document, trust system
- Tenant setup (Key Vault, authority creation, domain linking) and its failure modes
- The Request Service REST API (issuance and presentation flows) and its error model
- The Admin API (authorities, contracts, credentials, opt-out) used for management/automation
- Microsoft Authenticator as the reference wallet application
- did:web (current, only actively supported trust system) and did:ion (deprecated, legacy)

**Not in scope:**
- Building a full issuer or verifier web application (see Microsoft's [Woodgrove samples](https://learn.microsoft.com/en-us/entra/verified-id/verifiable-credentials-configure-issuer) for that)
- Non-Microsoft wallets or verifiers interoperating purely via W3C Verifiable Credentials/DID standards outside the Microsoft ecosystem
- Face Check (Microsoft's identity-verification-partner-based onboarding credential), which builds on Verified ID but has its own separate configuration surface
- Conditional Access "Verified ID" conditions/policies referencing VC claims at sign-in — a downstream consumer of this service, not the service itself

**Assumed knowledge:**
- Comfortable with OAuth2 client-credentials and delegated-token flows
- Basic understanding of public-key cryptography (signing/verification) and DNS/HTTPS hosting
- Familiar with Azure Key Vault access models (Vault Access Policy vs. Azure RBAC)

---

## How It Works

<details><summary>Full architecture</summary>

### Centralized vs. decentralized identity, and why this product exists

Traditional (centralized) identity has one identity provider (IDP) controlling the full lifecycle of every credential inside a trust boundary. That works well for employees accessing employer-owned resources, but breaks down for anything that needs to cross a trust boundary — proving you're an employee to a *different* company's website, verifying a job candidate's identity before they have any account at all, or letting a partner accept a claim about someone without having to stand up federation.

Verified ID augments (not replaces) centralized identity with **W3C Verifiable Credentials (VCs)** and **Decentralized Identifiers (DIDs)**. Control of a credential is split three ways instead of living entirely with one IDP:

- **Issuer** — asserts claims about a subject and signs them into a VC (e.g., an employer, a government identity-proofing partner)
- **Holder** — possesses the VC in a wallet (Microsoft Authenticator) and decides if/when/to whom to present it
- **Verifier** (a.k.a. relying party) — receives and validates a presented VC, without ever needing a direct trust relationship or federation with the issuer

Trust between these three doesn't flow through a central authority — it flows through cryptography. Every actor has a **DID**, a portable, self-owned identifier. A **DID document**, resolvable via a **trust system**, holds that DID's public keys and linked domains. Anyone can independently verify a signature came from a given DID without ever contacting the issuer's servers, because the DID document — not a phone call to the issuer — is the source of truth for the public key.

### Components

| Component | Role |
|---|---|
| **Microsoft Entra Verified ID service** | Azure-hosted issuance/verification service; exposes the Request Service REST API and the Admin API |
| **Azure Key Vault** | Stores the authority's private signing key(s); the service never stores private keys itself |
| **Microsoft Authenticator (wallet)** | Creates/holds the holder's DID, stores issued VCs, drives issuance and presentation UX, validates domain linkage |
| **Resolver** | Looks up a DID and returns its DID document (for `did:web`, this is nothing more exotic than an HTTPS GET to the domain's `/.well-known/did.json`) |
| **Trust system** | The mechanism DIDs are anchored in. Verified ID currently supports only `did:web` (domain-anchored, centralized-but-standardized); `did:ion` (a Bitcoin-anchored distributed ledger method) was preview-only and retired December 2023 |

### did:web vs did:ion — why this matters operationally

`did:web` anchors trust to a DNS domain the organization already controls — the DID document lives at a predictable, plain-HTTPS URL. There's no ledger, no propagation delay, no blockchain infrastructure — just a JSON file and a webserver. This is now the **only** trust system Verified ID supports for new authorities.

`did:ion` anchored trust to a Bitcoin-based Sidetree ledger instead of DNS. It was more "purely decentralized" in spirit but operationally heavier (ledger propagation, `didDocumentStatus: submitted` while waiting to anchor) and was deprecated after preview. Any tenant that still has a `did:ion` authority is running on a legacy, unsupported-for-new-use trust system and should plan a migration (see Remediation Playbook 4).

### The two request flows

**Flow 1 — Issuance**
1. Holder visits the issuer's web frontend.
2. Issuer frontend calls the Verified ID Request Service API to generate an issuance request.
3. The frontend renders that request as a QR code (desktop) or deep link (mobile).
4. Holder scans/taps with Authenticator.
5. Authenticator resolves the issuer's DID via the trust system, validates the signature on the request, and validates domain linkage.
6. Depending on the contract's attestation requirements, Authenticator may collect self-attested claims, complete an OIDC sign-in for an `id_token`, or present another VC as an input claim.
7. Authenticator submits the collected artifacts back to the Request Service API, which returns the signed VC. Authenticator stores it.

**Flow 2 — Presentation (verification)**
1. Holder visits the relying party's (verifier's) web frontend.
2. Verifier frontend calls the Request Service API to generate a presentation request (specifying required credential type(s)/schema).
3. Rendered as QR/deep link; holder scans with Authenticator.
4. Authenticator resolves the verifier's DID, validates the request is genuinely from that domain, and finds matching stored VC(s).
5. Holder consents; Authenticator sends a signed presentation response (VC + subject DID + verifier DID as audience) to the Request Service API.
6. The Request Service API validates the response — including, depending on how the verifier configured the request, checking with the issuer whether the VC has been revoked — then calls back the verifier's app with the result.

Every one of these calls to generate a request also performs a **Key Vault signing operation** — this is the basis for the service's DDOS/throttling posture (see Symptom → Cause Map and Learning Pointers).

</details>

---

## Dependency Stack

```
Layer 5 — Consuming Applications
    Issuer web frontend, Verifier web frontend, third-party wallets/RPs
        │ calls Request Service REST API with VerifiableCredential.Create.All
        ▼
Layer 4 — Contracts (per-authority)
    Rules definition (attestations: idToken / idTokenHint / presentation / selfIssued / accessToken)
    Display definition (branding, claim labels)
    manifestUrl — MUST be publicly, anonymously reachable
        │
        ▼
Layer 3 — Authority / DID
    did:web (current) or did:ion (deprecated)
    didDocumentStatus: published (healthy) / outOfSync (key rotated, not resynced) / submitted (did:ion only)
        │
        ▼
Layer 2 — Domain Linkage
    Well-known DID configuration: https://<domain>/.well-known/did-configuration.json
    Non-redirecting HTTPS, anonymously fetchable, signed by the authority's own DID
        │
        ▼
Layer 1 — Azure Key Vault
    Permission model MUST be "Vault Access Policy" (Azure RBAC model is NOT supported)
    Holds the private signing key(s) — every VC and every request is signed from here
        │
        ▼
Layer 0 — Tenant Onboarding
    One-time opt-in via Admin API /onboard or Azure portal — creates the three
    verifiableCredential*ServicePrincipalId service principals
```

A failure at any lower layer masks as a confusing symptom at a much higher layer — for example, a Key Vault permission-model mismatch (Layer 1) surfaces to an end user as "credential issuance just doesn't work," with nothing in the contract (Layer 4) actually wrong.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Authenticator shows full-page "unverified"/risky warning | Domain linkage broken or never completed | `linkedDomainsVerified` on the authority; `curl -Iv` the well-known file |
| Issuance/verification worked yesterday, fails today with no code change | Signing key was rotated (deliberately or via an automated KV policy) without a DID document resync | `didDocumentStatus` — check for `outOfSync` |
| New Key Vault won't work for Verified ID setup | Key Vault created with Azure RBAC as its permission model | Key Vault → Access configuration → must show "Vault access policy" |
| Setup wizard fails at "Register decentralized ID" step | Missing Authentication Policy Administrator (or Global Admin) role, or app registration lacks `VerifiableCredential.Authority.ReadWrite` | Role assignment; app API permissions |
| `wellKnownConfigDomainDoesNotExistInIssuer` error | Domain in the API call doesn't exactly match `linkedDomainUrls` on the authority | Compare literal string, including trailing slash and scheme |
| Intermittent HTTP 429 from Request Service API | Public issuance/presentation page with no auth/CAPTCHA gate is being hit repeatedly, burning Key Vault signing-operation quota | Front-end traffic pattern; add a gate |
| Callback endpoint never invoked after a successful wallet interaction | Firewall/NSG blocking inbound traffic from the tenant's Azure region | Firewall logs for the relying party's callback URL; confirm AzureCloud service tag/CIDR allowed |
| Android user gets "You'll have to add this Verified ID and try again" | Wrong Authenticator work/personal profile intercepted a camera-app QR scan | Ask which app (camera vs. Authenticator) was used to scan |
| `ngrok`-based sample tutorial won't run in the corporate environment | ngrok blocked by IT policy | Deploy sample to Azure App Service instead |
| Can't delete an old/unwanted `did:web` authority | Delete Authority API only supports `did:ion` | Full tenant opt-out is the only removal path for `did:web` |
| Revocation search returns nothing for a claim you know was issued | Search uses a hashed index value (`Base64(SHA256(contractId + claimValue))`), not the plaintext claim | Confirm the exact hashing/encoding steps were followed, including which claim was marked `indexed: true` |
| Contract update rejected / index search stops working after an edit | More than one claim mapping marked `indexed: true` in the same contract | Only one indexed claim mapping is supported per contract |

---

## Validation Steps

1. **Confirm tenant onboarding completed exactly once**
   ```powershell
   Invoke-RestMethod -Method Post -Headers $headers -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/onboard"
   ```
   Safe to call repeatedly — returns the same `Enabled` status and the three service principal IDs every time; does not create duplicate onboarding.

2. **Confirm the Key Vault permission model before troubleshooting anything else**
   Azure portal → Key Vault → Access configuration → Permission model must read **Vault access policy**. If it shows **Azure role-based access control**, Verified ID setup cannot proceed against this vault at all — this is a hard product limitation, not a misconfiguration to "fix" on the Key Vault side without recreating it.

3. **Confirm the authority object's health**
   ```powershell
   Invoke-RestMethod -Headers $headers -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>"
   ```
   Good output: `status: Enabled`, `didModel.didDocumentStatus: published`, `linkedDomainsVerified: true` (note: `linkedDomainsVerified` appears on the create/rotate response shape; use the domain-validation call below as the authoritative live check).

4. **Validate domain linkage live, not from memory**
   ```powershell
   Invoke-RestMethod -Method Post -Headers $headers -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>/validateWellKnownDidConfiguration"
   ```
   `204 No Content` = good. Anything else means Authenticator will likely also fail this same check for real end users.

5. **Validate the file is fetchable exactly the way Authenticator fetches it**
   ```bash
   curl -Iv https://<domain>/.well-known/did-configuration.json
   ```
   Look for: `HTTP/1.1 200`, `Content-Type: application/json` (or similar), and **no** `Location:` redirect header. Authenticator does not follow redirects during this check.

6. **Validate each contract's public-facing dependency (manifestUrl)**
   ```powershell
   $contract = Invoke-RestMethod -Headers $headers -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>/contracts/<contractId>"
   Invoke-WebRequest -Uri $contract.manifestUrl -UseBasicParsing | Select-Object StatusCode
   ```
   Must return `200` anonymously — this is fetched by the holder's wallet, not by an authenticated service call.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Isolate the layer.** Using the Dependency Stack, work top-down from the symptom: is this an application-integration issue (Layer 5), a contract/manifest issue (Layer 4), an authority/DID issue (Layer 3), a domain-linkage issue (Layer 2), or a Key Vault issue (Layer 1)? Most tickets that "feel like an application bug" are actually Layer 1-3.

**Phase 2 — Reproduce with the Admin API directly, bypassing the application.** If the issuer/verifier app reports a failure, call the same Request Service/Admin API endpoints directly with a test token to determine whether the fault is in Verified ID itself or in the calling application's integration code.

**Phase 3 — Check for a recent change.** Signing key rotation, domain/hosting changes (new CDN, new WAF rule, SSL cert renewal introducing a redirect), and firewall/NSG changes are the three most common "it worked last week" root causes. None of these show up as an error in the Verified ID service itself — they show up as a downstream symptom.

**Phase 4 — Read the structured error, don't guess from the HTTP status alone.** The Request Service API's error format nests real detail in `error.innererror.code` and `error.innererror.target` — always capture and read these before escalating.

**Phase 5 — Escalate with the Evidence Pack** if the fault is confirmed inside the Verified ID service itself (not the calling app, not domain linkage, not Key Vault) — this is genuinely rare and usually points at a wider service incident.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full signing-key rotation with zero-downtime resync</summary>

1. Create the new key without disturbing the old one:
   ```powershell
   $body = @{ signingKeyCurve = "P-256" } | ConvertTo-Json
   Invoke-RestMethod -Method Post -Headers $headers -Body $body -ContentType "application/json" `
     -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>/didInfo/signingKeys"
   ```
   `didDocumentStatus` flips to `outOfSync` immediately — this is expected and does not yet affect live traffic, since the *old* key is still what's published in the DID document.
2. Regenerate and re-publish the DID document (now containing both keys until old-key cleanup):
   ```powershell
   Invoke-RestMethod -Method Post -Headers $headers -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>/generateDidDocument" | Out-File did.json
   # publish did.json to https://<domain>/.well-known/did.json
   ```
3. Synchronize — this tells the service to start signing with the new key:
   ```powershell
   Invoke-RestMethod -Method Post -Headers $headers -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>/didInfo/synchronizeWithDidDocument"
   ```
4. Confirm `didDocumentStatus` returns to `published`.

**Rollback:** if issuance/verification breaks after sync, the old key is still present in Key Vault and in the previously-published DID document — re-publish the prior `did.json` (kept from before step 2) to revert, then investigate the new key before retrying.

</details>

<details><summary>Playbook 2 — Recovering from a broken domain migration</summary>

Because `did:web` authorities cannot have their linked domain changed, a business requirement to move to a new domain requires a full opt-out/re-onboard:

1. Export every contract's `rules` and `displays` definitions first (`GET .../contracts` for each contract) — save the JSON. This is the only backup; there's no "export all" button.
2. Warn stakeholders explicitly: **every previously issued credential becomes permanently unverifiable** the moment opt-out completes. This is not reversible.
3. Opt out: `POST /v1.0/verifiableCredentials/optout`.
4. Re-onboard and complete setup against the new domain (Key Vault with Vault Access Policy, new authority, new domain linkage).
5. Recreate every contract from the saved JSON.
6. Update every issuer/verifier application's authority/contract references and `manifestUrl`s.
7. Communicate to all credential holders that they need a **new** credential — old ones in their wallet are now dead weight (Authenticator does not auto-notify users that a VC is now unverifiable).

**Rollback:** none — opt-out is destructive and immediate for every existing credential and contract in that tenant.

</details>

<details><summary>Playbook 3 — Revoking a specific issued credential</summary>

1. Compute the search hash for the indexed claim value (must match exactly how the contract's indexed claim mapping was originally hashed):
   ```powershell
   $claimValue = "<the indexed claim's plaintext value>"
   $contractId = "<contractId>"
   $sha256 = [System.Security.Cryptography.SHA256]::Create()
   $bytes = [System.Text.Encoding]::UTF8.GetBytes($contractId + $claimValue)
   $hash = [System.Convert]::ToBase64String($sha256.ComputeHash($bytes))
   $encodedHash = [System.Uri]::EscapeDataString($hash)
   ```
2. Search for the credential:
   ```powershell
   Invoke-RestMethod -Headers $headers -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>/contracts/$contractId/credentials?filter=indexclaimhash eq $encodedHash"
   ```
3. Revoke by the returned credential ID:
   ```powershell
   Invoke-RestMethod -Method Post -Headers $headers -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>/contracts/$contractId/credentials/<credentialId>/revoke"
   ```

**Rollback:** revocation is intended to be permanent (e.g., "employee was terminated"); there's no un-revoke endpoint. If revoked in error, the only remedy is issuing the holder a brand-new credential.

</details>

<details><summary>Playbook 4 — Migrating a legacy did:ion authority to did:web</summary>

See Fix 5 in the companion hotfix runbook (`VerifiedID-B.md`) for the condensed version. In full:

1. Export all contract definitions from the `did:ion` authority.
2. Create the new `did:web` authority (`POST /v1.0/verifiableCredentials/authorities` with `didMethod: "web"`) targeting the chosen domain, or opt-out/opt-in if this tenant only has the one legacy authority.
3. Complete domain linkage for the new authority (Key Vault, well-known config, `curl` verification) exactly as for a brand-new setup.
4. Recreate contracts from the exported definitions on the new authority.
5. Update all issuer/verifier applications to the new authority/contract manifest URLs.
6. Run issuance and presentation tests end to end on the new `did:web` authority before touching the old one.
7. Only once step 6 passes: `DELETE /beta/verifiableCredentials/authorities/<did:ion authorityId>` to remove the legacy authority. This delete call **only** works for `did:ion` — attempting it against a `did:web` authority will fail; that trust system has no delete path (full tenant opt-out is the only removal option for `did:web`).

**Rollback:** keep the old `did:ion` authority live (don't delete it) until the new `did:web` authority is fully validated in production — this is the one step in this playbook that is safely reversible if caught before step 7.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Entra Verified ID authority/contract health for escalation, using app-only
    client-credentials auth against the Verified ID Admin API (NOT Microsoft Graph).
.NOTES
    Requires an app registration with "Verifiable Credentials Service Admin" API permission
    (VerifiableCredential.Authority.ReadWrite at minimum — there is no read-only variant
    documented for this permission as of this writing).
#>
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][securestring]$ClientSecret
)

$plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret))

$tokenBody = @{
    client_id     = $ClientId
    client_secret = $plainSecret
    scope         = "6a8b4b39-c021-437c-b060-5a14a3fd65f3/.default"
    grant_type    = "client_credentials"
}
$token = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $tokenBody).access_token
$headers = @{ Authorization = "Bearer $token" }
$base = "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials"

Write-Host "=== Entra Verified ID Evidence Pack ===" -ForegroundColor Cyan
$authorities = (Invoke-RestMethod -Headers $headers -Uri "$base/authorities").value
foreach ($a in $authorities) {
    Write-Host "`nAuthority: $($a.name) [$($a.id)]"
    $a | Select-Object name, status, @{n='did';e={$_.didModel.did}}, @{n='didDocumentStatus';e={$_.didModel.didDocumentStatus}}, @{n='linkedDomainUrls';e={$_.didModel.linkedDomainUrls -join ', '}} | Format-List

    try {
        Invoke-RestMethod -Method Post -Headers $headers -Uri "$base/authorities/$($a.id)/validateWellKnownDidConfiguration" -ErrorAction Stop
        Write-Host "  Well-known DID configuration: VALID" -ForegroundColor Green
    } catch {
        Write-Host "  Well-known DID configuration: FAILED — $($_.Exception.Message)" -ForegroundColor Red
    }

    $contracts = (Invoke-RestMethod -Headers $headers -Uri "$base/authorities/$($a.id)/contracts").value
    $contracts | Select-Object name, status, manifestUrl, issueNotificationEnabled | Format-Table -AutoSize
}
Write-Host "`nCollect separately (not available via this API): Key Vault permission model, firewall/NSG rules for callback traffic, Request Service API error logs from the calling application." -ForegroundColor Yellow
```

---

## Command Cheat Sheet

| Task | Command / Endpoint |
|---|---|
| Get Admin API token (app-only) | `POST https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token`, `scope=6a8b4b39-c021-437c-b060-5a14a3fd65f3/.default` |
| One-time tenant onboarding | `POST /v1.0/verifiableCredentials/onboard` |
| List authorities | `GET /v1.0/verifiableCredentials/authorities` |
| Get one authority | `GET /v1.0/verifiableCredentials/authorities/<id>` |
| Create authority (did:web only) | `POST /v1.0/verifiableCredentials/authorities` |
| Update authority display name | `PATCH /v1.0/verifiableCredentials/authorities/<id>` |
| Delete authority (did:ion only) | `DELETE /beta/verifiableCredentials/authorities/<id>` |
| Rotate signing key | `POST /v1.0/verifiableCredentials/authorities/<id>/didInfo/signingKeys/rotate` |
| Create additional signing key | `POST /v1.0/verifiableCredentials/authorities/<id>/didInfo/signingKeys` |
| Regenerate DID document | `POST /v1.0/verifiableCredentials/authorities/<id>/generateDidDocument` |
| Sync DID document after rotation | `POST /v1.0/verifiableCredentials/authorities/<id>/didInfo/synchronizeWithDidDocument` |
| Generate well-known DID config | `POST /v1.0/verifiableCredentials/authorities/<id>/generateWellknownDidConfiguration` |
| Validate well-known DID config | `POST /v1.0/verifiableCredentials/authorities/<id>/validateWellKnownDidConfiguration` |
| List contracts | `GET /v1.0/verifiableCredentials/authorities/<id>/contracts` |
| Create contract | `POST /v1.0/verifiableCredentials/authorities/<id>/contracts` |
| Update contract | `PATCH /v1.0/verifiableCredentials/authorities/<id>/contracts/<contractId>` |
| Search credentials by indexed claim | `GET .../contracts/<id>/credentials?filter=indexclaimhash eq {hash}` |
| Revoke a credential | `POST .../contracts/<id>/credentials/<credentialId>/revoke` |
| Full tenant opt-out (destructive) | `POST /v1.0/verifiableCredentials/optout` |
| Verify well-known file is publicly reachable | `curl -Iv https://<domain>/.well-known/did-configuration.json` |

---

## 🎓 Learning Pointers

- **This entire product lives outside Microsoft Graph.** Anyone reaching for `Connect-MgGraph`/`Microsoft.Graph.*` cmdlets to manage Verified ID will find nothing — it's a standalone Admin API and Request Service API with their own OAuth resource. Treat it like managing a separate SaaS product that happens to live inside the Entra admin center. See [Admin API for managing Microsoft Entra Verified ID](https://learn.microsoft.com/en-us/entra/verified-id/admin-api).

- **The Key Vault permission-model requirement (Vault Access Policy, not RBAC) is a hard product limitation, not a best-practice suggestion.** Organizations that have standardized on RBAC-only Key Vaults as a security baseline will need an explicit, documented exception for the Verified ID signing vault. See [Advanced Microsoft Entra Verified ID setup](https://learn.microsoft.com/en-us/entra/verified-id/verifiable-credentials-configure-tenant).

- **Domain linkage is continuously re-validated, not a one-time setup checkbox.** A `.well-known/did-configuration.json` file that quietly disappears during a site redesign six months after setup breaks live issuance/verification with a user-facing "unverified" warning and zero server-side error — build this file into change-management/monitoring the same way you would a production TLS cert. See [Link your domain to your DID](https://learn.microsoft.com/en-us/entra/verified-id/how-to-dnsbind).

- **did:web authorities cannot change their linked domain, and cannot be deleted via the Admin API at all** — only full tenant opt-out removes a `did:web` authority, and opt-out invalidates every credential the tenant ever issued. This makes the initial domain choice a one-way door; treat it with the same care as choosing a production DNS zone. See the [FAQ](https://learn.microsoft.com/en-us/entra/verified-id/verifiable-credentials-faq#if-i-reconfigure-the-microsoft-entra-verified-id-service-do-i-need-to-relink-my-did-to-my-domain).

- **Every presentation/issuance request consumes a Key Vault signing operation with its own service limits** — an unauthenticated public-facing issuance page is a real availability and cost risk, not just a security nicety. Gate it with authentication or CAPTCHA before it goes live, not after the first incident. See the [FAQ's network hardening / DDOS guidance](https://learn.microsoft.com/en-us/entra/verified-id/verifiable-credentials-faq#network-hardening-for-callback-events).

- **`did:ion` is retired (preview support ended December 2023) with no in-place conversion path to `did:web`** — only export/recreate/reissue. If a tenant's authority still shows a `did:ion:` DID, that's a standing migration item, not just a cosmetic detail. See the [FAQ's migration steps](https://learn.microsoft.com/en-us/entra/verified-id/verifiable-credentials-faq#how-do-i-move-to-did-web-from-did-ion).
