# AD FS (Active Directory Federation Services) — Hotfix Runbook (Mode B: Ops)
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

Run on the **primary AD FS server** first. If the farm uses WID (Windows Internal Database), commands must run on the primary node.

```powershell
# 1. Is the AD FS service running, and on which node?
Get-Service adfssrv | Select-Object Status, StartType
Get-AdfsProperties | Select-Object HostName, Identifier

# 2. Farm-wide cert health — this is the #1 cause of "everyone can't sign in" outages
Get-AdfsCertificate | Select-Object CertificateType, IsPrimary, @{N='DaysLeft';E={($_.Certificate.NotAfter - (Get-Date)).Days}}

# 3. Is AutoCertificateRollover actually doing its job?
Get-AdfsProperties | Select-Object AutoCertificateRollover, CertificateGenerationThreshold, CertificateDuration

# 4. Relying party trust health (M365/Entra is almost always one of these)
Get-AdfsRelyingPartyTrust | Select-Object Name, Enabled, MonitoringEnabled

# 5. Recent AD FS Admin log errors (fastest signal of what's actually broken right now)
Get-WinEvent -LogName 'AD FS/Admin' -MaxEvents 30 | Where-Object LevelDisplayName -in 'Error','Warning' | Select-Object TimeCreated, Id, LevelDisplayName, Message
```

| Signal | Interpretation | Go to |
|---|---|---|
| `DaysLeft` on a Token-Signing or Token-Decrypting cert is negative or < 5 | Certificate expired or about to — this breaks **every** federated sign-in at once | Fix 1 |
| `AutoCertificateRollover = False` | Certs were never going to renew themselves — expect this to recur | Fix 1, then Fix 4 |
| Event 316/315/317 (cert chain build failure) | Cert chain broken, often after a CA change or an untrusted intermediate | Fix 2 |
| Event 387 | AD FS service account lost read access to the cert's private key | Fix 2 |
| A relying party trust shows `Enabled: False` or is missing entirely | Someone disabled/deleted the trust, or M365 federation config drifted | Fix 3 |
| Users get "There was a problem accessing the site" only from **outside** the network | WAP (Web Application Proxy) proxy trust has expired | Fix 5 |
| Event 133 | Federation Service config has invalid `serviceIdentityToken` — usually a farm/gMSA identity problem | Escalate — farm identity corruption, don't self-fix under time pressure |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Active Directory (service account / gMSA auth) 
        │
        ▼
AD FS Configuration Database (WID or SQL) ── stores certs, RP trusts, claims rules
        │
        ▼
adfssrv service on each farm node ── must load Token-Signing + Token-Decrypting certs
        │
        ▼
Federation metadata (/FederationMetadata/2007-06/FederationMetadata.xml) ── published, current
        │
        ▼
Relying Party Trust (e.g. Microsoft Office 365 Identity Platform) ── cert thumbprint must match what's live on the farm
        │
        ▼
Web Application Proxy (WAP) ── proxy trust cert (rolling, ~2 week validity) must be current for extranet access
        │
        ▼
End user gets a token Entra ID / the RP will accept
```

If the farm's live Token-Signing cert thumbprint no longer matches what Entra ID has on file, every federated sign-in fails — internal users may still work via WAP-less internal endpoints in split scenarios, but external/extranet always fails first.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the service is actually up on every farm node**, not just the one you're on.
   ```powershell
   Get-AdfsFarmInformation | Select-Object -ExpandProperty FarmNodes
   ```
   Good: all nodes listed, `FarmBehaviorLevel` matches expectations. Bad: a node is missing or the cmdlet errors — that node has dropped out of the farm.

2. **Check certificate validity and rollover state.**
   ```powershell
   Get-AdfsCertificate -CertificateType Token-Signing
   Get-AdfsCertificate -CertificateType Token-Decrypting
   ```
   Good: `NotAfter` is comfortably in the future for both a primary and (if present) a secondary cert (AD FS keeps the previous cert alive briefly during rollover). Bad: only one cert present and it's expired or expiring within days.

3. **Confirm what Entra ID actually has on file for this domain** (from a client, not the AD FS box):
   ```powershell
   Get-MsolFederationProperty -DomainName <yourdomain.com>   # or Get-MgDomainFederationConfiguration for the Graph-based replacement
   ```
   Good: `SigningCertificate`/thumbprint matches the AD FS farm's current live signing cert. Bad: thumbprints differ — Entra ID is validating tokens against a cert the farm no longer signs with.

4. **Check the relying party trust for M365 specifically.**
   ```powershell
   Get-AdfsRelyingPartyTrust -Name "Microsoft Office 365 Identity Platform" | Format-List Identifier, Enabled, EncryptionCertificate, SignatureAlgorithm
   ```
   Good: `Enabled = True`, identifier is `urn:federation:MicrosoftOnline`. Bad: trust missing, disabled, or `SignatureAlgorithm` doesn't match what Entra ID expects (SHA-256 is standard; SHA-1 trusts are a legacy red flag).

5. **If external users are the only ones affected, check WAP proxy trust.**
   ```powershell
   # Run on the WAP server
   Get-WebApplicationProxyConfiguration
   Get-WinEvent -LogName 'AD FS/Admin' -MaxEvents 20 | Where-Object Id -in 224,276,394,395,396
   ```
   Good: no recent 224/276 errors, trust re-established (396) events appear periodically. Bad: repeated 224/276 with no successful 396 afterward — the proxy trust has lapsed.

6. **Confirm claims rules haven't been silently altered** (common after "someone was troubleshooting this last week"):
   ```powershell
   (Get-AdfsRelyingPartyTrust -Name "Microsoft Office 365 Identity Platform").IssuanceTransformRules
   ```
   Good: standard UPN/immutableID/nameID rules present. Bad: rules empty or missing the `Group` claim / `alternateLoginID` if the tenant uses one.

---
## Common Fix Paths

<details><summary>Fix 1 — Expired or expiring Token-Signing/Token-Decrypting certificate</summary>

```powershell
# Check current state first
Get-AdfsCertificate | Select-Object CertificateType, IsPrimary, Thumbprint, @{N='NotAfter';E={$_.Certificate.NotAfter}}

# If AutoCertificateRollover is on and just hasn't triggered yet, force a rollover
Update-AdfsCertificate -CertificateType Token-Signing
Update-AdfsCertificate -CertificateType Token-Decrypting

# Then push the new metadata to every relying party — Entra ID normally auto-updates within
# 24 hours via federation metadata refresh, but during an active outage don't wait:
Update-MsolFederatedDomain -DomainName <yourdomain.com>   # or Update-MgDomainFederationConfiguration
```
**Rollback:** if you manually rolled a certificate and it made things worse (e.g. a downstream RP that doesn't auto-refresh metadata), you can re-promote the previous cert as primary as long as it hasn't been purged:
```powershell
Set-AdfsCertificate -CertificateType Token-Signing -Thumbprint <previous-thumbprint>
```
This is a stopgap only — get `AutoCertificateRollover` enabled afterward (Fix 4) so this doesn't recur.
</details>

<details><summary>Fix 2 — Certificate chain build failure / service account can't read private key (Events 315/316/317/387)</summary>

```powershell
# Confirm the AD FS service account has read access to the cert's private key
$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -eq "<thumbprint>"
$rsaKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
$keyPath = "$env:ProgramData\Microsoft\Crypto\Keys\$($rsaKey.Key.UniqueName)"
Get-Acl $keyPath | Format-List

# Grant the service account read access if missing (adjust account name to your farm's service identity/gMSA)
$acl = Get-Acl $keyPath
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule("<DOMAIN>\<svc-account>","Read","Allow")
$acl.AddAccessRule($rule)
Set-Acl $keyPath $acl

# Confirm the full chain is installed and trusted on every farm node
certutil -verify -urlfetch $certFilePath
```
**Rollback:** ACL changes are additive-only here — removing the rule you just added restores prior state if it turns out permissions weren't the actual cause.
</details>

<details><summary>Fix 3 — Relying party trust disabled, missing, or thumbprint mismatch</summary>

```powershell
# Re-enable a disabled trust
Set-AdfsRelyingPartyTrust -TargetName "Microsoft Office 365 Identity Platform" -Enabled $true

# If the trust is missing entirely or badly corrupted, re-run federation setup for the domain
# from an Entra Connect/MSOnline-capable admin workstation (NOT on the AD FS box):
Convert-MsolDomainToFederated -DomainName <yourdomain.com> -SupportMultipleDomain
```
**Rollback:** `Convert-MsolDomainToFederated` re-creates the RP trust from scratch — if this makes things worse, `Convert-MsolDomainToStandard` moves the domain back to cloud/managed auth as an emergency bypass (users authenticate directly against Entra ID, bypassing AD FS entirely) while you fix the farm properly.
</details>

<details><summary>Fix 4 — AutoCertificateRollover disabled (root cause of repeat cert outages)</summary>

```powershell
Set-AdfsProperties -AutoCertificateRollover $true
Get-AdfsProperties | Select-Object AutoCertificateRollover, CertificateGenerationThreshold, CertificateDuration
```
No rollback needed — enabling auto-rollover is safe and is the documented best practice unless the org has a specific reason to manage cert lifecycle manually (e.g. HSM-backed certs).
</details>

<details><summary>Fix 5 — WAP proxy trust expired (external users only affected)</summary>

```powershell
# Run on the WAP server, using an AD FS farm admin account
Install-WebApplicationProxy -CertificateThumbprint <wap-ssl-cert-thumbprint> -FederationServiceName <adfs.yourdomain.com>
```
This re-establishes the proxy trust from scratch. It is safe to re-run even if the trust is only partially broken.
**Rollback:** none needed — this only re-establishes trust and does not alter published application configurations.
</details>

---
## Escalation Evidence

```
AD FS Incident — Escalation Package
Reported by: <name>
Time detected: <timestamp>
Scope: [ ] All federated sign-ins   [ ] External/extranet only   [ ] Single application (RP): <name>

Farm topology: [ ] Single node   [ ] WID farm, __ nodes   [ ] SQL farm, __ nodes
FarmBehaviorLevel: <output of Get-AdfsFarmInformation>

Certificate state:
  Token-Signing NotAfter:      <value>
  Token-Decrypting NotAfter:   <value>
  AutoCertificateRollover:     <True/False>

Entra ID federation config thumbprint (Get-MgDomainFederationConfiguration): <value>
Farm live signing cert thumbprint:                                          <value>
  Match? [ ] Yes  [ ] No

Recent AD FS/Admin log errors (last 30, Error/Warning only): <paste>
WAP event IDs seen (224/276/394/395/396): <paste, if applicable>

Fix paths already attempted: <list>
Current status: <still down / partially restored / resolved, monitoring>
```

---
## 🎓 Learning Pointers
- Token-signing/decrypting certificate expiry is the single most common cause of a farm-wide AD FS outage — if `AutoCertificateRollover` is off, it *will* happen again. See [AD FS troubleshooting — certificates](https://learn.microsoft.com/en-us/windows-server/identity/ad-fs/troubleshooting/ad-fs-tshoot-certs).
- Entra ID caches the federation metadata it trusts; a farm-side cert rollover doesn't instantly propagate. During an active outage, force it with `Update-MgDomainFederationConfiguration` rather than waiting on the ~24-hour metadata refresh — see [Certificate renewal for Microsoft 365 and Microsoft Entra users](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-fed-o365-certs).
- WAP's proxy trust is a *separate* rolling certificate from the farm's token-signing certs — a WAP server that's been offline for an extended period (original documentation cites roughly two weeks) will need `Install-WebApplicationProxy` re-run to re-establish trust, not a certificate reissue on the farm itself.
- Treat `Convert-MsolDomainToStandard` (or its Graph equivalent) as your emergency escape hatch, not a routine tool — it moves password validation to the cloud and bypasses AD FS entirely, which is exactly what you want mid-outage but has real security/SSO implications if left in place afterward.
- If a relying party trust's `SignatureAlgorithm` is SHA-1, treat that as a legacy configuration flag worth raising with the client, not just a symptom to fix — see [AD FS SSO troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/troubleshoot-ad-fs-sso-issue).
