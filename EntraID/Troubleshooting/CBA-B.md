# Entra ID Certificate-Based Authentication (CBA) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Triage

This topic covers **Entra ID native Certificate-Based Authentication** — signing in directly with a smart card/PIV/CAC or virtual smart card certificate, with Entra ID validating the cert itself (no ADFS in the loop). It is distinct from `EntraID/Troubleshooting/WHfB-B.md` (device-bound TPM key, not a portable certificate) and from `Intune/Troubleshooting/Certificates-B.md`/`CloudPKI-B.md` (the delivery mechanism that *issues* certificates to devices, which CBA can consume but doesn't require).

```powershell
# 1. Confirm CBA is enabled tenant-wide (or scoped to a group)
Connect-MgGraph -Scopes "Policy.Read.All"
Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate" |
    Select-Object State, Id

# 2. Confirm the issuing CA chain is trusted by Entra ID
Get-MgDirectoryCertificateAuthority | Select-Object Certificate, IsRootAuthority

# 3. Check the certificate-to-user binding (affinity) configuration
(Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate").AdditionalProperties.certificateUserBindings

# 4. On the client — confirm the cert/smart card is visible to Windows at all
certutil -scinfo
Get-ChildItem Cert:\CurrentUser\My | Select-Object Subject, Issuer, NotAfter, HasPrivateKey

# 5. Confirm the user's sign-in log for the actual failure reason
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 5 |
    Select-Object CreatedDateTime, Status, AuthenticationDetails
```

| Result | Action |
|--------|--------|
| `State: disabled` | → Fix 1: Enable CBA authentication method |
| Issuing/intermediate CA missing from `Get-MgDirectoryCertificateAuthority` | → Fix 2: Upload missing CA to the trust chain |
| Sign-in log shows "certificate revoked" or CRL-related error | → Fix 3: Fix CRL distribution point reachability |
| Sign-in log shows "no user found" or wrong account matched | → Fix 4: Fix certificate-to-user binding mismatch |
| No cert prompt appears in browser/Windows sign-in at all | → Fix 5: Client-side smart card/middleware issue |
| Cert auth succeeds but doesn't satisfy an MFA-required Conditional Access policy | → Fix 6: Authentication strength / policy OID mapping |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Certificate issued to user/smart card by a PKI]
  └─ Root CA + all intermediate CAs uploaded to Entra ID (up to 250 CAs, v1.0 Graph)
         |
[Entra ID CBA authentication method — State: enabled]
  └─ Scoped to "All users" or a specific security group
         |
[Certificate presented at sign-in]
  └─ Chain validates against uploaded CAs
  └─ CRL distribution point (from cert) reachable and not showing the cert revoked
         |
[Certificate User Binding resolves to exactly one Entra ID user]
  └─ High-affinity binding (X509:<SKI> or X509:<IssuerAndSubject> → certificateUserIds) — recommended
  └─ Low-affinity binding (PrincipalName/RFC822Name → UPN) — legacy, spoofable, being phased out
         |
[Authentication strength / CA-level policy OIDs evaluated]
  └─ Determines whether this cert satisfies "single-factor" or "multifactor" for Conditional Access
         |
[User signed in — CBA satisfies password node entirely, no separate password prompt]
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm CBA is enabled and its scope**
```powershell
Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate" |
    Select-Object State
```
Expected: `State: enabled`. If `disabled`, no certificate prompt will ever appear for affected users regardless of client-side cert health.

**2. Confirm the CA trust chain**
```powershell
Get-MgDirectoryCertificateAuthority | Select-Object Certificate, IsRootAuthority, CrlDistributionPoint
```
Every issuing CA in the certificate's chain — root **and** any intermediates — must appear here. A missing intermediate is the single most common "certificate not trusted" root cause.

**3. Check the sign-in log for the specific failure**
```powershell
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 10 |
    Select-Object CreatedDateTime, Status, @{N='FailureReason';E={$_.Status.FailureReason}}
```
Look for language distinguishing "certificate chain not trusted," "certificate revoked," "unable to reach CRL," and "no user found for certificate" — each maps to a different fix below.

**4. Confirm certificate-to-user binding configuration**
```powershell
(Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate").AdditionalProperties.certificateUserBindings
```
Confirm the binding priority order and which certificate field (PrincipalName, RFC822Name, SubjectKeyIdentifier, IssuerAndSubject, Subject) is mapped to which user attribute.

**5. Client-side cert visibility**
```powershell
certutil -scinfo          # Smart card reader/middleware status
certutil -verifystore -user My   # User cert store integrity
```
If the certificate isn't visible here, this is a smart card driver/middleware problem, not an Entra ID configuration problem — no server-side fix will resolve it.

---
## Common Fix Paths

<details><summary>Fix 1 — CBA authentication method disabled</summary>

Use when: `State: disabled` and no users tenant-wide (or in the target group) see a cert-auth prompt.

**In the Entra admin center:** Protection > Authentication methods > Policies > Certificate-based authentication → set **Enable** and target the correct group (or "All users").

```powershell
# Read-only confirmation after enabling in the portal — Graph write for this policy
# is available via Update-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration
Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate" |
    Select-Object State
```

**Rollback:** Set back to Disabled — users fall back to their next available authentication method (password + MFA, WHfB, FIDO2, etc.), no account lockout risk.

</details>

<details><summary>Fix 2 — Missing CA in the trust chain</summary>

Use when: Sign-in fails with a chain/trust error, or the issuing/intermediate CA doesn't appear in `Get-MgDirectoryCertificateAuthority`.

**In the Entra admin center:** Protection > Authentication methods > Certificate-based authentication > Configure > Certificate authorities → **Upload** the missing root or intermediate `.cer` file, mark root CAs as **Is Root** = Yes.

Every CA in the chain must be uploaded individually — Entra ID does not automatically trust a root just because an intermediate beneath it is uploaded, and vice versa.

**Rollback:** Remove the uploaded CA if added in error — any certs chaining only to that CA immediately stop being trusted for sign-in.

</details>

<details><summary>Fix 3 — CRL distribution point unreachable or cert revoked</summary>

Use when: Sign-in log shows a CRL/revocation-related failure.

```powershell
# Confirm the CRL URL from the certificate is reachable from a client on the corporate network
certutil -URL "<cert file path>"   # Opens the URL Retrieval Tool GUI to test each CDP entry
```

Entra ID CBA validates against the CRL published at the certificate's CDP (CRL Distribution Point) extension — it does not support OCSP. If the CDP is only reachable from the internal network (common with on-prem CA-issued certs), remote/external sign-ins will fail even though the cert is valid, because Entra ID's cloud-side validator can't reach an internal-only CRL endpoint.

Fix: publish the CRL to an internet-reachable HTTP endpoint (most CAs support a secondary internet-facing CDP entry), or a CDN-fronted location, then re-issue or wait for existing certs' next CRL check.

**Rollback:** N/A — this is a network reachability fix, not a destructive change.

</details>

<details><summary>Fix 4 — Certificate-to-user binding mismatch ("no user found")</summary>

Use when: Sign-in log shows no matching user found, or the wrong user account is resolved from a valid certificate.

```powershell
# Check what the current binding priority actually maps
(Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate").AdditionalProperties.certificateUserBindings

# Check the target user's certificateUserIds attribute (used by high-affinity bindings)
Get-MgUser -UserId '<UPN>' -Property certificateUserIds | Select-Object -ExpandProperty AdditionalProperties
```

If using a low-affinity binding (PrincipalName/RFC822Name → userPrincipalName/onPremisesUserPrincipalName), confirm the certificate's SAN field exactly matches the user's UPN — case and domain suffix included.

If using a high-affinity binding (recommended), confirm the user's `certificateUserIds` extension attribute contains the exact `X509:<SKI>` or `X509:<IssuerAndSubject>` value from the cert:
```powershell
Update-MgUser -UserId '<UPN>' -CertificateUserIds @("X509:<IssuerAndSubject>[issuer],[subject]")
```

**Rollback:** Revert `certificateUserIds` to its prior value if the update causes a different mismatch.

</details>

<details><summary>Fix 5 — No certificate prompt appears (client-side)</summary>

Use when: The Entra ID side of CBA is enabled and correctly configured, but the user never sees a "Sign in with a certificate" prompt.

```powershell
# Confirm the OS sees the smart card/cert at all
certutil -scinfo
Get-PnpDevice | Where-Object { $_.Class -eq "SmartCardReader" }

# Confirm the client's browser/Windows sign-in isn't being routed straight to password
# (common cause: home realm discovery or CA policy scoping the user out of CBA)
```

Checklist: smart card middleware/driver installed and current, reader recognized by Windows, certificate not expired, browser configured to allow smart card prompts (some hardened browser policies suppress client cert prompts by default).

**Rollback:** N/A — diagnostic checklist, no config change required unless a driver reinstall is needed.

</details>

<details><summary>Fix 6 — Cert auth succeeds but Conditional Access still demands MFA</summary>

Use when: The user authenticates with a certificate successfully but is still blocked or re-prompted by a CA policy requiring MFA.

**In the Entra admin center:** Protection > Authentication methods > Certificate-based authentication > Configure — under **Authentication binding policies**, map the specific policy OID(s) issued on the certificate to **Multifactor authentication** rather than the default **Single-factor authentication**.

```powershell
(Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate").AdditionalProperties.certificateUserBindings
# Cross-check authenticationModeConfiguration.ruleSets for OID-to-strength mapping
```

Without an OID mapped to multifactor, Entra ID treats every CBA sign-in as single-factor by default — which will never satisfy a Conditional Access grant control requiring MFA.

**Rollback:** Remove or adjust the OID mapping if it over-broadly classifies certs as multifactor.

</details>

---
## Escalation Evidence

```
ENTRA ID CBA ESCALATION
========================
Date/Time                 :
Tenant ID                 :
User UPN                  :
CBA policy State          : enabled / disabled
Certificate Subject       :
Certificate Issuer        :
Issuing CA present in Get-MgDirectoryCertificateAuthority? : YES / NO
Intermediate CA(s) present?: YES / NO
Sign-in log FailureReason :
Binding type in use       : High-affinity (certificateUserIds) / Low-affinity (UPN/RFC822)
certificateUserIds value on user object (if applicable):
CRL reachable externally? : YES / NO / UNKNOWN
Client cert visible via `certutil -scinfo`? : YES / NO
Conditional Access policy involved:
Steps already tried       :
```

---
## 🎓 Learning Pointers

- **Entra native CBA is not the same as ADFS-federated smart card auth.** Native CBA validates the certificate directly in Entra ID with no on-prem federation server in the sign-in path — a big reliability and latency win for orgs migrating off ADFS, but it means the CA trust chain and CRL reachability must now work from Entra ID's cloud-side validator, not just from domain-joined clients on the internal network. [Entra ID Certificate-Based Authentication overview](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-certificate-based-authentication)
- **High-affinity bindings exist because low-affinity bindings are spoofable.** Mapping a certificate's PrincipalName/RFC822Name SAN field to a user's UPN assumes no attacker can obtain a cert with an arbitrary SAN from a trusted-but-loosely-governed CA. Binding via `certificateUserIds` (SKI or IssuerAndSubject) ties the cert to a specific, non-guessable value on the user object instead. [Certificate user binding configuration](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-certificate-based-authentication-technical-deep-dive)
- **Entra ID CBA checks CRLs, not OCSP.** If your PKI only publishes revocation status via OCSP responder, that's invisible to Entra ID's validator — you need a CRL Distribution Point entry Entra ID can reach over the internet.
- **A cert satisfying MFA is a policy decision, not automatic.** Entra ID has no inherent way to know a smart card PIN + private key is "as strong as" MFA unless a specific certificate policy OID is explicitly mapped to the multifactor authentication strength in the CBA configuration.
- **Community/reference:** [Configure certificate-based authentication in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/authentication/how-to-certificate-based-authentication) | [Microsoft Entra Tech Community](https://techcommunity.microsoft.com/t5/microsoft-entra-blog/bg-p/Identity)
