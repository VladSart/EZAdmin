# Entra ID Certificate-Based Authentication (CBA) — Reference Runbook (Mode A: Deep Dive)
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

Covers **Entra ID native Certificate-Based Authentication (CBA)** — the authentication method that lets a user sign in directly with an X.509 client certificate (smart card, PIV/CAC, virtual smart card, or a certificate loaded into the Windows certificate store) with Entra ID itself validating the certificate chain, revocation status, and certificate-to-user binding. No on-prem federation server (ADFS) participates in the sign-in path.

**Does not cover:**
- **Windows Hello for Business** — a device-bound key (Key Trust) or device-bound certificate (Certificate Trust) that never leaves the TPM and is provisioned per-device. CBA certificates are portable (smart card, USB token) and validated centrally by Entra ID, not tied to TPM attestation. See `WHfB-A.md`/`-B.md`.
- **Intune Cloud PKI / certificate profile delivery** — the mechanism used to *issue* device or user certificates (for WHfB Certificate Trust, Wi-Fi/VPN EAP-TLS, S/MIME) via SCEP/PKCS or Intune's built-in CA. CBA can consume certificates delivered this way, but CBA itself is only concerned with validating a cert at sign-in, not issuing one. See `Intune/Troubleshooting/CloudPKI-A.md` and `Certificates-A.md`.
- **Legacy ADFS-based smart card / certificate authentication** — pre-dates Entra native CBA and routes through a federation server; migration from ADFS CBA to Entra native CBA is a distinct project with its own considerations, briefly noted below but not covered in depth.
- **FIDO2 security keys** — a separate passwordless authentication method with its own attestation and binding model, even though some hardware tokens (e.g. YubiKeys) support both FIDO2 and PIV/certificate modes.

**Assumes:** Global Administrator or Authentication Policy Administrator role for policy configuration; a functioning PKI (internal CA, Intune Cloud PKI, or a public/government-issued PIV/CAC infrastructure) already issuing valid client authentication certificates; Microsoft Graph PowerShell SDK connected for diagnostics.

---
## How It Works

<details><summary>Full architecture</summary>

### The certificate validation chain, end to end

When a user presents a certificate at an Entra ID sign-in prompt (browser, native app broker, or Windows sign-in with WHfB-Certificate-Trust-style logon), Entra ID performs, in order:

1. **Chain validation** — walks the certificate's issuer chain up to a root, checking every intermediate and root CA against the tenant's uploaded `certificateAuthorities` collection (Entra ID directory object, up to 250 CAs as of this writing). If any CA in the chain is missing from this collection, the chain is untrusted and authentication fails immediately — this happens before revocation or binding is ever evaluated.
2. **Revocation check** — retrieves the CRL from the certificate's CDP (CRL Distribution Point) extension and confirms the presented cert's serial number isn't listed as revoked. Entra ID's CBA implementation checks CRLs only; it does not call an OCSP responder even if the cert's AIA (Authority Information Access) extension advertises one. A CDP that's only reachable from an internal network (typical of certs issued by an on-prem CA with no internet-facing CRL distribution) silently fails this step for any sign-in Entra ID's cloud-side validator attempts — which, because Entra ID is cloud infrastructure, is effectively **every** sign-in unless the CDP has been deliberately published externally.
3. **Certificate-to-user binding resolution** — extracts one or more fields from the certificate (Subject Alternative Name PrincipalName, RFC822Name/email, Subject Key Identifier, Issuer+Subject composite, or the full Subject DN) and matches it against a configured user attribute to resolve exactly one Entra ID user object.
4. **Authentication strength classification** — evaluates the certificate's policy OIDs (if any binding policy rules are configured) to decide whether this specific sign-in should be treated as single-factor or multifactor for downstream Conditional Access evaluation.
5. **Token issuance** — on success, Entra ID issues tokens as normal; CBA fully replaces the password node in the sign-in flow rather than supplementing it (a user with CBA available is never separately prompted for a password unless CBA itself fails and a fallback method is invoked).

### High-affinity vs. low-affinity certificate-to-user bindings

This is the single most consequential design decision in a CBA deployment:

| Binding type | Certificate field | Entra user attribute | Security posture |
|---|---|---|---|
| **High-affinity** (recommended) | Subject Key Identifier (SKI) | `certificateUserIds` (format: `X509:<SKI>`) | Strong — SKI is a hash unique to the specific key pair, effectively impossible to spoof by obtaining a different cert |
| **High-affinity** (recommended) | Issuer + Subject (composite) | `certificateUserIds` (format: `X509:<I>[issuer],[subject]`) | Strong — requires matching both issuer and full subject DN |
| **Low-affinity** (legacy) | PrincipalName (SAN UPN field) | `userPrincipalName` or `onPremisesUserPrincipalName` | Weak — any CA in the trusted chain issuing a cert with an attacker-chosen PrincipalName SAN can impersonate that user |
| **Low-affinity** (legacy) | RFC822Name (SAN email field) | `userPrincipalName`/mail-based match | Weak — same spoofing risk as PrincipalName |

Microsoft has been progressively tightening default guidance and, in some tenant configurations, blocking low-affinity bindings by default for newly configured CBA policies, specifically because a low-affinity binding's security is only as strong as the *entire* set of trusted CAs' issuance controls — one loosely governed CA anywhere in the trusted list undermines the binding for every user matched that way. Binding priority order matters too: Entra ID evaluates bindings in the configured priority sequence and uses the first one that produces a match, so a low-affinity binding listed above a high-affinity one can still be exploited even if the high-affinity binding is also configured.

### CBA and Conditional Access authentication strength

Conditional Access policies that require "Multifactor authentication" as a grant control need to know whether a given CBA sign-in counts. By default, Entra ID treats certificate authentication as single-factor unless an admin explicitly maps one or more certificate policy OIDs to the multifactor authentication strength under the CBA configuration's authentication binding policies. This OID-to-strength mapping is what lets, for example, a PIV card issued under a specific government PKI policy (which itself mandates the private key be protected by a PIN-secured hardware token — inherently "something you have + something you know") be recognized by Entra ID as satisfying MFA, while a lower-assurance certificate policy is not.

### Migration context: ADFS-federated CBA vs. Entra native CBA

Organizations previously using ADFS with smart card/certificate authentication (common in government, defense, and healthcare sectors with PIV/CAC mandates) can migrate to Entra native CBA to remove the federation server from the sign-in critical path entirely — eliminating ADFS as a single point of failure and simplifying the architecture to cloud-only. The migration itself is primarily a matter of: uploading the same trusted CA chain to Entra ID, replicating the certificate-to-user binding logic that ADFS's claim rules previously performed, and cutting the domain over from federated to managed (or staying federated for other purposes while scoping CBA specifically to the native method) — but is out of scope for this topic beyond this note.

</details>

---
## Dependency Stack

```
[PKI issues client authentication certificate to user/smart card/hardware token]
         |
         ▼
[Root CA + every intermediate CA uploaded to Entra ID's certificateAuthorities collection]
         |
         ▼
[CBA authentication method policy — State: enabled, scoped to target group or All users]
         |
         ▼
[Certificate presented at sign-in — chain validated against uploaded CAs]
         |
         ▼
[CRL retrieved from certificate's CDP extension, reachable from Entra ID's cloud-side validator]
  (NOT OCSP — CDP must be internet-reachable, not internal-only)
         |
         ▼
[Certificate-to-user binding resolves to exactly one Entra ID user]
  (high-affinity: certificateUserIds attribute  |  low-affinity: UPN/RFC822 match — legacy)
         |
         ▼
[Authentication strength evaluated via certificate policy OID → strength mapping]
         |
         ▼
[Conditional Access evaluates sign-in — MFA grant control satisfied only if OID mapped to multifactor]
         |
         ▼
[Token issued — user signed in, CBA fully replaced the password node]
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No certificate prompt appears at sign-in at all | CBA authentication method policy disabled, or user not in scoped group | `Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate"` → `State` |
| "The certificate chain was issued by an authority that is not trusted" | Missing root or intermediate CA in Entra ID's trust list | `Get-MgDirectoryCertificateAuthority` — compare against the cert's full chain |
| "Certificate has been revoked" for a certificate the issuer says is valid | CRL is stale, or CDP unreachable and treated as an implicit failure depending on tenant/policy config | Test CDP URL reachability from an external network; confirm CRL `nextUpdate` hasn't passed |
| "No user found matching this certificate" | Binding priority mismatch, or `certificateUserIds`/UPN doesn't exactly match the cert's SAN field | Inspect binding priority order and the specific field values on both sides |
| Wrong user account signed in from a valid certificate | Low-affinity binding matched an unintended user (e.g., stale UPN reused) | Move to high-affinity `certificateUserIds` binding; audit for UPN reuse across departed/rehired users |
| Cert sign-in succeeds but CA policy demands MFA and blocks it anyway | No certificate policy OID mapped to the multifactor authentication strength | Review `authenticationModeConfiguration.ruleSets` under CBA configuration |
| Works for internal users, fails for remote/external users only | CDP is only reachable from the internal network — CRL check fails from Entra ID's cloud validator for everyone, but internal users may be authenticating via a path that caches or bypasses this | Confirm CDP has an internet-reachable entry; do not assume "works on VPN" means the config is correct tenant-wide |
| Certificate visible in `certutil -scinfo` output but browser never prompts for it | Client-side browser policy suppressing client certificate prompts, or smart card middleware/driver issue | Check browser client-cert-selection policy settings; confirm middleware is current |
| Migrating from ADFS smart card auth — some users now fail post-cutover | Certificate-to-user binding logic wasn't fully replicated from ADFS claim rules into Entra ID's binding configuration | Compare ADFS claim rule logic against Entra CBA binding priority/field mapping before full cutover |
| CBA works, but user is also being prompted for a second MFA method afterward | Conditional Access policy requiring MFA doesn't recognize this cert's OID as multifactor-equivalent, so it's stacking an additional factor rather than treating CBA as sufficient | Map the relevant OID to multifactor authentication strength, or confirm this stacking is actually the intended security posture |

---
## Validation Steps

**Step 1 — Confirm the CBA policy is enabled and its scope**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All"
Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate" |
    Select-Object State, Id
```
Expected: `State: enabled`. Confirm scope (all users vs. specific group) matches the intended rollout population.

**Step 2 — Enumerate every trusted CA and compare against the certificate's full chain**
```powershell
Get-MgDirectoryCertificateAuthority | Select-Object Certificate, IsRootAuthority, CrlDistributionPoint
```
Extract the issuing chain from a sample certificate (`certutil -dump <certfile>` or PowerShell `[System.Security.Cryptography.X509Certificates.X509Chain]`) and confirm every CA in that chain — root and all intermediates — appears in this list.

**Step 3 — Confirm CRL reachability from outside the corporate network**
```powershell
certutil -URL "<path to sample cert>"   # GUI tool — test each CDP entry, especially from an external network
```
A CDP reachable only internally will fail validation for Entra ID's cloud-side check regardless of where the user is physically signing in from.

**Step 4 — Confirm the certificate-to-user binding configuration and priority order**
```powershell
(Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate").AdditionalProperties.certificateUserBindings
```
Confirm which binding is evaluated first — a low-affinity binding earlier in priority than a high-affinity one undermines the stronger binding's protection.

**Step 5 — Confirm the target user's binding attribute value**
```powershell
Get-MgUser -UserId '<UPN>' -Property certificateUserIds,userPrincipalName,onPremisesUserPrincipalName |
    Select-Object UserPrincipalName, OnPremisesUserPrincipalName, @{N='CertificateUserIds';E={$_.AdditionalProperties.certificateUserIds}}
```

**Step 6 — Confirm authentication strength / OID mapping if MFA satisfaction is in question**
```powershell
(Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate").AdditionalProperties.authenticationModeConfiguration
```

**Step 7 — Confirm sign-in log detail for the specific failed attempt**
```powershell
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 10 |
    Select-Object CreatedDateTime, @{N='FailureReason';E={$_.Status.FailureReason}}, AuthenticationDetails
```

---
## Troubleshooting Steps (by phase)

### Phase 1: Policy and scope

1. Confirm the CBA authentication method is enabled at all, and that the affected user falls within its configured scope (all users vs. a specific group).
2. Rule out a recent scope change (a user recently removed from the target group loses CBA immediately, with no client-side symptom other than "the prompt stopped appearing").

### Phase 2: Trust chain

1. Enumerate the certificate's full issuer chain and cross-reference every CA against Entra ID's uploaded trust list.
2. Confirm root vs. intermediate CA flags are set correctly — a CA uploaded without the correct root/intermediate designation can fail chain building even if technically present.

### Phase 3: Revocation

1. Confirm the CDP extension in the certificate points to a URL, and that URL is reachable from outside the corporate network (Entra ID validates from cloud infrastructure, not from inside the tenant's network).
2. Confirm the CRL itself hasn't expired (`nextUpdate` field) — an expired CRL is sometimes treated as untrustworthy depending on validator behavior, producing revocation-adjacent errors for otherwise-valid certificates.

### Phase 4: Binding resolution

1. Confirm binding priority order, then work top-down through each configured binding to see which one (if any) actually resolves for the affected certificate/user pair.
2. For high-affinity bindings, confirm the exact string format of `certificateUserIds` matches what Entra ID computes from the certificate (case-sensitivity and exact SKI/Issuer+Subject formatting matter).

### Phase 5: Authentication strength and Conditional Access

1. Confirm whether any certificate policy OID is mapped to the multifactor authentication strength.
2. Cross-check the specific Conditional Access policy blocking the sign-in to confirm it's evaluating the CBA sign-in's authentication strength correctly, rather than assuming CBA is being ignored entirely.

### Phase 6: Client-side

1. Confirm the OS/browser can see the certificate or smart card at all before assuming a server-side misconfiguration.
2. Confirm smart card middleware/driver currency, especially after a Windows feature update — driver regressions here are common.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full CA trust chain upload for a new PKI</summary>

**When:** Onboarding a new certificate authority (internal CA, a new Intune Cloud PKI root, or a government/partner PKI) for CBA use for the first time.

1. Extract the complete chain (root + every intermediate) from a representative issued certificate.
2. In the Entra admin center: Protection > Authentication methods > Certificate-based authentication > Configure > Certificate authorities → Upload each CA's `.cer` file individually, correctly marking root CAs.
3. Confirm each CA appears via `Get-MgDirectoryCertificateAuthority` before testing end-user sign-in.
4. Pilot with a small group scope before expanding the CBA policy to all users.

**Rollback:** Remove the uploaded CA(s) — any certificates chaining only to that authority immediately stop being valid for sign-in; ensure no production users are actively relying on it before removing.

</details>

<details><summary>Playbook 2 — Migrating certificate-to-user bindings from low-affinity to high-affinity</summary>

**When:** An existing CBA deployment uses PrincipalName/RFC822Name-based bindings and needs to move to `certificateUserIds`-based bindings for security hardening.

1. For each in-scope user, populate the `certificateUserIds` attribute with the correct `X509:<SKI>` or `X509:<IssuerAndSubject>` value derived from their actual issued certificate.
```powershell
Update-MgUser -UserId '<UPN>' -CertificateUserIds @("X509:<SKI-value>")
```
2. Add the high-affinity binding to the CBA policy's binding list, placing it at **higher priority** than the existing low-affinity binding.
3. Validate sign-in for a pilot group using the new binding before removing the low-affinity binding entirely.
4. Once validated at scale, remove the low-affinity binding from the priority list to close the spoofing exposure it represents.

**Rollback:** Re-prioritize or restore the low-affinity binding if the `certificateUserIds` rollout surfaces unexpected user-mapping gaps — treat this as a temporary safety net only, not a long-term state.

</details>

<details><summary>Playbook 3 — Publishing an internet-reachable CRL for an internal CA</summary>

**When:** CBA sign-ins fail with revocation-related errors because the issuing CA's CRL is only published to an internal distribution point.

1. Identify the CA's current CDP configuration (`certutil -CRL` or the CA's own management console).
2. Add or update a secondary CDP entry pointing to an internet-reachable HTTP endpoint (many enterprise CAs support publishing to an external web server or CDN-fronted storage account in addition to the internal path).
3. Re-issue or wait for the next CRL publish cycle so certificates carry the updated CDP extension — certificates already issued with only the internal CDP baked in will need reissuance to pick up the new entry.
4. Validate reachability from an external network before considering this closed.

**Rollback:** N/A — adding a CDP entry is additive and doesn't remove the internal one; internal-network validation continues to work exactly as before.

</details>

<details><summary>Playbook 4 — Fleet CBA readiness audit ahead of a rollout</summary>

Run `Get-CBAConfigurationAudit.ps1` (see Scripts/) to produce a single report covering: CBA policy enablement/scope, every trusted CA and its root/intermediate flag, binding priority and type (high vs. low affinity) in use, and a per-target-user check of whether their `certificateUserIds`/UPN binding attribute is actually populated — surfacing exactly which users would fail to resolve to an account even if their certificate is otherwise perfectly valid.

**Rollback:** N/A — read-only audit pass.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Entra ID CBA configuration and per-user diagnostic evidence for escalation
.NOTES     Requires Microsoft.Graph PowerShell SDK connected with Policy.Read.All, User.Read.All,
           AuditLog.Read.All scopes. Read-only.
#>

$output = [System.Collections.Generic.List[string]]::new()
$ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC" -AsUTC
$out    = ".\CBAEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).txt"

function Add-Section {
    param([string]$Title, [scriptblock]$Body)
    $output.Add("=" * 60)
    $output.Add("  $Title")
    $output.Add("=" * 60)
    try { $output.Add((&$Body | Out-String).Trim()) }
    catch { $output.Add("ERROR: $($_.Exception.Message)") }
    $output.Add("")
}

Add-Section "Collection metadata" {
    "Collected : $ts"
    "Tenant    : $((Get-MgContext).TenantId)"
}

Add-Section "CBA policy state and scope" {
    Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate" |
        Select-Object State, Id | Format-List | Out-String
}

Add-Section "Trusted certificate authorities" {
    Get-MgDirectoryCertificateAuthority | Select-Object Certificate, IsRootAuthority, CrlDistributionPoint | Format-Table -AutoSize | Out-String
}

Add-Section "Certificate-to-user binding configuration" {
    (Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate").AdditionalProperties.certificateUserBindings |
        Out-String
}

Add-Section "Recent sign-in failures (last 10, target user)" {
    param()
    if ($env:CBA_TARGET_UPN) {
        Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$($env:CBA_TARGET_UPN)'" -Top 10 |
            Select-Object CreatedDateTime, @{N='FailureReason';E={$_.Status.FailureReason}} | Format-Table -AutoSize | Out-String
    } else {
        "Set `$env:CBA_TARGET_UPN before running to include sign-in log detail."
    }
}

$output | Set-Content -Path $out -Encoding UTF8
Write-Host "Evidence saved to: $out" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Confirm CBA policy state | `Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate"` |
| List trusted CAs | `Get-MgDirectoryCertificateAuthority` |
| Check binding configuration | `(...).AdditionalProperties.certificateUserBindings` |
| Check user's high-affinity binding value | `Get-MgUser -UserId <UPN> -Property certificateUserIds` |
| Set a user's high-affinity binding | `Update-MgUser -UserId <UPN> -CertificateUserIds @("X509:<SKI>")` |
| Client: smart card/reader status | `certutil -scinfo` |
| Client: user cert store contents | `Get-ChildItem Cert:\CurrentUser\My` |
| Client: verify user cert store integrity | `certutil -verifystore -user My` |
| Test a certificate's CDP/AIA URLs | `certutil -URL "<cert file>"` |
| Recent sign-in failures for a user | `Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'"` |
| Portal path — enable/scope CBA | Entra admin center > Protection > Authentication methods > Policies > Certificate-based authentication |
| Portal path — upload trusted CA | ...same blade > Configure > Certificate authorities > Upload |
| Portal path — binding priority + OID-to-strength | ...same blade > Configure > Authentication binding policies |

---
## 🎓 Learning Pointers

- **CBA validates from the cloud, so "it works internally" tells you nothing about whether it will work for everyone.** Every trust chain check and CRL lookup happens from Entra ID's cloud-side validator, not from the client's network location — an internal-only CDP will fail for every sign-in Entra ID validates, including sign-ins from domain-joined devices on the corporate LAN, because it's Entra ID's servers doing the CRL fetch, not the client's. [CBA technical deep dive](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-certificate-based-authentication-technical-deep-dive)
- **Binding priority order is a security control, not just a configuration convenience.** If a low-affinity binding sits above a high-affinity one in priority, Entra ID will still resolve via the weaker binding first whenever it produces a match — configuring a strong binding doesn't help if a weaker one is evaluated first and succeeds. [Certificate user binding](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-certificate-based-authentication-technical-deep-dive#certificate-user-binding)
- **CRL only — no OCSP.** A PKI designed around OCSP responders for revocation checking needs a CRL distribution point specifically for Entra ID CBA to work; the AIA extension's OCSP URL is not consulted by Entra ID's validator.
- **Authentication strength for CBA is opt-in per certificate policy OID, not automatic.** A certificate issued under a rigorous, hardware-token-enforced policy is not treated as MFA-equivalent by Conditional Access unless an admin explicitly maps that policy's OID to the multifactor authentication strength — the mere fact that a smart card requires a PIN doesn't communicate that fact to Entra ID on its own.
- **Migrating off ADFS-federated certificate auth removes a single point of failure but requires re-implementing claim-rule-equivalent binding logic natively.** Treat this as a distinct, planned migration project with its own pilot phase — not a same-day cutover — since ADFS claim rules and Entra ID's binding priority model aren't a 1:1 mapping.
- **Reference:** [Configure certificate-based authentication in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/authentication/how-to-certificate-based-authentication) | [Microsoft Entra Tech Community](https://techcommunity.microsoft.com/t5/microsoft-entra-blog/bg-p/Identity)
