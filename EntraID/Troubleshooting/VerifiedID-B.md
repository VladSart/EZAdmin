# Entra Verified ID — Hotfix Runbook (Mode B: Ops)
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

Verified ID is **not** part of Microsoft Graph — it has its own Admin API (base URL `https://verifiedid.did.msidentity.com`) and its own Request Service REST API used by issuer/verifier apps. There is no `Microsoft.Graph.VerifiedId` module. Everything below is either a portal check or a raw REST call.

```powershell
# 1. Get a token for the Admin API (requires an app registration with "Verifiable Credentials
#    Service Admin" API permission — see Learning Pointers). App-only client-credentials example:
$tenantId = "<tenantId>"
$body = @{
    client_id     = "<appId>"
    client_secret = "<clientSecret>"
    scope         = "6a8b4b39-c021-437c-b060-5a14a3fd65f3/.default"
    grant_type    = "client_credentials"
}
$token = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body $body).access_token
$headers = @{ Authorization = "Bearer $token" }

# 2. List configured authorities (should be exactly one in almost every tenant)
Invoke-RestMethod -Headers $headers -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities" |
    Select-Object -ExpandProperty value | Select-Object name, status, @{n='did';e={$_.didModel.did}}, @{n='didStatus';e={$_.didModel.didDocumentStatus}}, @{n='domainVerified';e={$_.linkedDomainsVerified}}

# 3. Confirm the well-known DID configuration file is actually publicly reachable
#    (Authenticator will NOT honor redirects — this must return 200 with no redirect hops)
curl.exe -Iv "https://<yourdomain>/.well-known/did-configuration.json"

# 4. List contracts under the authority (need the authorityId from step 2)
Invoke-RestMethod -Headers $headers -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>/contracts" |
    Select-Object -ExpandProperty value | Select-Object name, status, manifestUrl, issueNotificationEnabled
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| `didStatus = outOfSync` | Signing key was rotated/created but the DID document was never re-registered and synced | Fix 1 — re-register DID document and synchronize |
| `didStatus = submitted` (not `published`) | Legacy `did:ion` authority still propagating to the ledger, or stuck | Fix 5 — this is a deprecated trust system, plan migration |
| `domainVerified = false` | Domain never linked, or the `did-configuration.json` file went missing/unreachable | Fix 2 — restore or re-verify the well-known file |
| `curl.exe` shows a redirect (3xx) or TLS error | Authenticator will show the domain as **unverified** even if the portal once said it was fine | Fix 2 — remove the redirect, fix the cert |
| Wallet shows "risky website" / unverified warning to end users | Same root cause as the two rows above — domain-to-DID linkage broken | Fix 2 |
| User's Authenticator error: "You'll have to add this Verified ID and try again" | Work/personal profile mismatch scanning the QR with the phone camera app instead of Authenticator | Fix 3 — no server-side fix, user education only |
| Issuance/verification calls returning HTTP 429 | Request Service API throttling — often from a missing CAPTCHA/auth gate in front of a public issuance page | Fix 4 — add a gate in front of issuance requests |
| Callback URL never receives a result | Network path from Azure Verified ID service (in the tenant's region) to the relying party's callback endpoint is blocked | Fix 6 — open the correct regional Azure service tag/CIDR range |

---
## Dependency Cascade

<details><summary>What must be true for a credential to issue and later verify successfully</summary>

```
Tenant onboarded to Verified ID (opt-in, one-time)
    │
    ▼
Authority created — did:web only (did:ion deprecated Dec 2023, read-only legacy support)
    ├── Azure Key Vault, PERMISSION MODEL MUST BE "Vault Access Policy" (not RBAC)
    │       └── Signing key(s) stored here — Request Service API signs every VC with this key
    ▼
Domain linked to the DID (well-known DID configuration)
    ├── did-configuration.json hosted at https://<domain>/.well-known/did-configuration.json
    ├── Domain must be HTTPS, non-redirecting, publicly reachable with NO auth
    └── Authenticator checks this at issuance/presentation time — not just once at setup
    │
    ▼
Contract created (rules definition + display definition)
    ├── rules: attestation types (idToken / idTokenHint / presentation / selfIssued / accessToken)
    ├── only ONE claim mapping per contract may have indexed:true (used for revocation search)
    └── manifestUrl must be publicly reachable — wallet downloads it as part of issuance
    │
    ▼
Issuer/Verifier web app calls Request Service REST API
    ├── App registration needs VerifiableCredential.Create.All (or split issue/present scopes)
    └── Renders QR code / deep link → holder scans with Microsoft Authenticator
    │
    ▼
Wallet (Authenticator) resolves issuer/verifier DID via the trust system (did:web = plain HTTPS lookup)
    ├── Validates the well-known config is signed by the same DID → shows "Verified" badge
    └── If any of the domain-linkage checks fail → full-page "unverified" warning to the user
    │
    ▼
Credential issued (signed with authority's Key Vault key) → held in Authenticator's wallet
    │
    ▼
Presentation to a relying party → Request Service validates signature + (optionally) revocation status
```

**Key point:** almost every real-world "verification suddenly stopped working" ticket traces back to either the Key Vault signing key (rotated without a resync) or the domain-linkage file (deleted, moved, or now behind a redirect) — not the credential itself.

</details>

---
## Diagnosis & Validation Flow

1. **Identify which of the three setup legs is broken: Key Vault/DID, domain linkage, or contract.**
   Pull the authority object (Triage step 2) and read `didModel.didDocumentStatus` and `linkedDomainsVerified` first — most tickets are one of these two fields, not a contract problem.

2. **Check DID document sync state**
   ```powershell
   Invoke-RestMethod -Headers $headers -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>"
   ```
   `didDocumentStatus`: `published` = healthy. `outOfSync` = a signing key was rotated or created but the DID document was never re-registered/synchronized — every new issuance may still validate against the *old* key until fixed. `submitted` only appears for legacy `did:ion` authorities.

3. **Validate the well-known DID configuration end to end**
   ```powershell
   Invoke-RestMethod -Method Post -Headers $headers `
     -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>/validateWellKnownDidConfiguration"
   ```
   `204 No Content` = good. A `400` with `wellKnownConfigDomainDoesNotExistInIssuer` means the domain in the request doesn't match any `linkedDomainUrls` on the authority — usually a typo or a domain that was changed without re-running setup (which isn't supported for `did:web` — see Learning Pointers).

4. **Confirm the file is actually fetchable from the public internet, not just from inside the corporate network**
   ```bash
   curl -Iv https://<yourdomain>/.well-known/did-configuration.json
   ```
   Run this from an Ubuntu box or WSL — Microsoft's own troubleshooting guidance calls this out specifically because Authenticator's fetcher behaves like `curl`, not like a browser with cached auth/cookies.

5. **Check contract health if the authority/domain both check out**
   ```powershell
   Invoke-RestMethod -Headers $headers -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>/contracts/<contractId>"
   ```
   Confirm `manifestUrl` resolves anonymously in a browser, and that `rules.attestations` matches what the issuer app is actually configured to send (a mismatched `clientId`/`configuration` on an `idTokens` attestation is a common silent-fail cause).

6. **If issuance/verification requests are failing outright, read the structured error, not just the HTTP status**
   The Request Service API's `error.innererror.code` tells you the real cause: `badOrMissingField` (bad request payload — check `target`), `tokenError` (JWT/id_token problem), `transientError` (safe to retry, often a 429).

---
## Common Fix Paths

<details><summary>Fix 1 — DID document out of sync after a signing key rotation</summary>

**Symptoms:** `didDocumentStatus = outOfSync`. Usually right after someone rotated or created a new signing key in Key Vault (deliberately, or via an automated key-rotation policy).

```powershell
# 1. Regenerate the DID document reflecting the new key
Invoke-RestMethod -Method Post -Headers $headers `
  -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>/generateDidDocument" |
  Out-File did.json

# 2. Publish did.json to https://<domain>/.well-known/did.json (public, HTTPS, no redirect)

# 3. Tell the service to start using the new key now that the document is republished
Invoke-RestMethod -Method Post -Headers $headers `
  -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>/didInfo/synchronizeWithDidDocument"
```
Confirm `didDocumentStatus` flips back to `published` after step 3.

**Rollback:** there is no built-in rollback to a prior signing key — if the new key is bad, create another new key and repeat this same three-step process. Do not delete the old key from Key Vault until you've confirmed the new one works end to end, in case you need to re-publish the old DID document as an emergency measure.

</details>

<details><summary>Fix 2 — Domain linkage broken (unverified warning to users)</summary>

**Symptoms:** `linkedDomainsVerified = false`, or users report a full-page "unverified" warning in Authenticator that wasn't there before.

```powershell
# 1. Confirm what domain the authority actually expects
(Invoke-RestMethod -Headers $headers -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>").didModel.linkedDomainUrls

# 2. Re-generate the signed well-known config for that exact domain
$body = @{ domainUrl = "https://<yourdomain>/" } | ConvertTo-Json
Invoke-RestMethod -Method Post -Headers $headers -Body $body -ContentType "application/json" `
  -Uri "https://verifiedid.did.msidentity.com/v1.0/verifiableCredentials/authorities/<authorityId>/generateWellknownDidConfiguration" |
  Out-File did-configuration.json

# 3. Upload did-configuration.json to https://<yourdomain>/.well-known/did-configuration.json
#    (root path only — no subfolder other than .well-known is supported)

# 4. Verify anonymously and without redirects
curl -Iv https://<yourdomain>/.well-known/did-configuration.json
```
Common root causes: the hosting site added a global HTTPS redirect rule that now 301s the `.well-known` path, a CDN/WAF is blocking anonymous access to `.well-known/*`, or the file was overwritten/removed during a site redeploy.

**Note:** you **cannot** change the linked domain on an existing `did:web` authority — the domain is fixed at authority creation. If the business genuinely needs a different domain, the only supported path is opt-out and re-onboard (Fix 5), which invalidates every previously issued credential.

</details>

<details><summary>Fix 3 — User gets "You'll have to add this Verified ID and try again" in Authenticator</summary>

**Symptoms:** Android device, work + personal profiles both have Microsoft Authenticator installed. User scanned the QR with the phone's native camera app instead of Authenticator directly.

**This is not a server-side issue.** The camera app hands the `openid-vc://` link to whichever Authenticator profile last registered the protocol handler — if the credential actually lives in the *other* profile's Authenticator instance, the wrong one intercepts the link and fails.

**Fix:** have the user open Microsoft Authenticator directly and use its in-app QR scanner, rather than the phone's camera app. On Android 9 and older, camera-app scanning of Verified ID QR codes doesn't work at all — Authenticator's own scanner is required regardless of profile.

</details>

<details><summary>Fix 4 — Request Service API returning 429 (throttled)</summary>

**Symptoms:** Issuance or presentation requests intermittently fail with HTTP 429 / `error.code = tooManyRequests`, usually correlating with a public-facing issuance page going viral, getting scraped, or hit by a bot.

Every presentation request consumes Key Vault signing operations, which have their own service-side limits — an unauthenticated public page that lets anyone repeatedly trigger new requests can burn through this quickly.

**Fix (architectural, not a toggle):** put an authentication or CAPTCHA gate in front of any public page that calls the issuance/presentation request creation endpoint, so only real users can trigger a new Key Vault signing operation. There is no tenant-side rate-limit override — this must be fixed in the calling application.

**Rollback:** none needed — this is a design change, not a state change.

</details>

<details><summary>Fix 5 — Legacy did:ion authority (deprecated trust system)</summary>

**Symptoms:** `did` value starts with `did:ion:` instead of `did:web:`. `did:ion` was supported in preview only until December 2023 and is not the recommended trust system for new or ongoing use.

Migration requires reissuing every credential (there is no in-place conversion):
1. Export the existing authority's contract display/rules definitions via the Admin API (`GET .../contracts`) and save them.
2. Create a new `did:web` authority (Admin API `POST .../authorities` with `didMethod: "web"`, or opt-out/opt-in via the portal if this is the tenant's only authority).
3. Recreate each contract on the new authority from the saved definitions.
4. Update every issuer/verifier application to point at the new authority and, for issuers, the new `manifestUrl`.
5. Test issuance and verification end to end on the new `did:web` authority.
6. Only after step 5 passes, delete the old `did:ion` authority (`DELETE /beta/verifiableCredentials/authorities/<id>` — this delete only works for `did:ion`; `did:web` authorities cannot be deleted this way).

**Rollback:** none once the old authority is deleted — deleting an authority permanently invalidates every credential it issued.

</details>

<details><summary>Fix 6 — Callback never reaches the relying party (network blocked)</summary>

**Symptoms:** Presentation flow completes in Authenticator (user consents and submits), but the relying party's callback endpoint never receives the result — request appears to hang or time out from the app's perspective.

Callbacks originate from Azure infrastructure in the **same Azure region as the Microsoft Entra tenant**, not from a fixed, documented static IP list.

**Fix:**
```
# Preferred: allow the Azure service tag at the firewall/NSG level
AzureCloud

# If service tags aren't usable, allow the CIDR ranges for the tenant's specific region(s)
# e.g., a tenant in Europe needs BOTH AzureCloud.northeurope and AzureCloud.westeurope
# Published ranges: https://www.microsoft.com/download/details.aspx?id=56519
```
Confirm the tenant's Azure AD region first (Entra ID → Properties → Country or Region) before picking which regional CIDR ranges to open.

**Rollback:** narrowing the firewall rule back down if this was opened too broadly — prefer the `AzureCloud` service tag over raw CIDR ranges where the firewall supports it, since Microsoft's IP ranges rotate.

</details>

---
## Escalation Evidence

```
=== Entra Verified ID Escalation Pack ===
Date/Time:
Tenant ID:
Authority ID:
DID (did:web:... or did:ion:...):
didDocumentStatus (published/outOfSync/submitted):
linkedDomainsVerified (true/false):
Linked domain URL:

curl -Iv output for https://<domain>/.well-known/did-configuration.json:

Contract ID / name affected:
manifestUrl reachable anonymously? (Y/N):

Request Service API error (if applicable):
  HTTP status:
  error.code:
  error.innererror.code:
  error.innererror.target:

End-user symptom (verbatim, including device OS/Authenticator version if a wallet issue):

Steps already tried:
  [ ] Checked authority didDocumentStatus and linkedDomainsVerified
  [ ] Ran validateWellKnownDidConfiguration
  [ ] Verified did-configuration.json with curl -Iv (no redirects, valid TLS)
  [ ] Checked contract manifestUrl reachability
  [ ] Checked for firewall/NSG blocking Azure region callback traffic
```

---
## 🎓 Learning Pointers

- **Verified ID is not Microsoft Graph.** It has its own Admin API host (`verifiedid.did.msidentity.com`) and its own OAuth resource/App ID URI (`6a8b4b39-c021-437c-b060-5a14a3fd65f3`). There is no `Microsoft.Graph.VerifiedId` PowerShell module — every automation here is a raw REST call. See [Admin API for managing Microsoft Entra Verified ID](https://learn.microsoft.com/en-us/entra/verified-id/admin-api).

- **The Key Vault used for signing must have the "Vault Access Policy" permission model, not Azure RBAC.** This is a documented, current limitation — a Key Vault created with RBAC as its permission model cannot be used for Verified ID setup, and this is easy to hit if a security baseline defaults all new Key Vaults to RBAC. See [Advanced Microsoft Entra Verified ID setup](https://learn.microsoft.com/en-us/entra/verified-id/verifiable-credentials-configure-tenant).

- **You cannot change the linked domain on an existing did:web authority — ever.** The only supported path to a new domain is opt-out (which deletes all contracts and invalidates every issued credential) and re-onboard from scratch. Plan the domain choice carefully before initial setup. See [Link your domain to your DID](https://learn.microsoft.com/en-us/entra/verified-id/how-to-dnsbind#how-do-i-update-the-linked-domain-on-my-did).

- **Authenticator validates domain linkage at issuance/presentation time, not just once at setup** — if the `.well-known/did-configuration.json` file disappears later (site redeploy, new WAF rule, CDN misconfiguration), previously-working flows start showing the unverified warning with no server-side error at all. Treat this file with the same change-control rigor as a production TLS certificate.

- **`did:ion` is a deprecated trust system (preview support ended December 2023).** Any tenant still running a `did:ion` authority should plan a migration to `did:web` — there's no in-place conversion, only export/recreate/reissue. See the [FAQ's did:ion → did:web migration steps](https://learn.microsoft.com/en-us/entra/verified-id/verifiable-credentials-faq#how-do-i-move-to-did-web-from-did-ion).

- **`ngrok` is commonly blocked by corporate IT policy**, which breaks the official sample-app tutorials that assume it's available as a local tunnel. Deploy the sample to Azure App Service (free tier is sufficient) instead of fighting a network policy exception. See the [FAQ's ngrok alternative](https://learn.microsoft.com/en-us/entra/verified-id/verifiable-credentials-faq#i-cant-use-ngrok-what-do-i-do).
