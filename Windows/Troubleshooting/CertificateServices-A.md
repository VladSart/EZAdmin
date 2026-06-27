# Windows Certificate Services (PKI/CA) — Reference Runbook (Mode A: Deep Dive)
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

Covers Windows Server Active Directory Certificate Services (AD CS) in enterprise and MSP environments, including:

- Enterprise Root CA and Subordinate CA (hierarchy)
- Certificate auto-enrollment via Group Policy
- NDES (Network Device Enrollment Service) for SCEP — used by Intune, network devices
- PKCS #12 delivery via Intune Certificate Connector
- CRL and OCSP publishing and client validation
- Certificate stores: LocalMachine and CurrentUser
- Hybrid environments with Microsoft Intune, Entra ID, and on-prem AD

**Prerequisites:** AD DS environment, Windows Server 2016+, appropriate admin rights. For Intune integration: NDES or Intune Certificate Connector installed.

---

## How It Works

<details><summary>Full architecture</summary>

### AD CS Component Roles

```
┌──────────────────────────────────────────────────────────────┐
│                    AD CS Hierarchy                           │
│                                                              │
│  ┌─────────────────┐    OFFLINE    Standalone Root CA        │
│  │   Root CA       │◄─────────────(no network, air-gapped)  │
│  │  (Root of Trust)│                                        │
│  └────────┬────────┘                                        │
│           │ Issues Sub CA cert                              │
│  ┌────────▼────────┐    ONLINE     Enterprise Subordinate CA │
│  │  Issuing CA     │◄─────────────(AD-joined, certsvc)      │
│  │ (Enterprise)    │                                        │
│  └────────┬────────┘                                        │
│           │                                                  │
│     ┌─────┴──────┬────────────┬─────────────┐              │
│     ▼            ▼            ▼             ▼              │
│  AutoEnroll   NDES/SCEP    OCSP         CRL CDP            │
│  (GPO/MDM)   (for Intune/  Responder   (IIS/LDAP)         │
│              network dev)                                   │
└──────────────────────────────────────────────────────────────┘
```

### Certificate Enrollment Paths

**Path 1 — GPO Auto-enrollment (domain computers/users)**
```
Client → LDAP query to AD (find templates) →
  RPC/DCOM to Issuing CA (port 135 + dynamic) →
    Certificate issued → stored in LocalMachine\My
```

**Path 2 — Intune SCEP (via NDES)**
```
Intune Service → MDM Push to client →
  Client generates key pair →
    SCEP request to NDES URL (HTTPS 443) →
      NDES validates SCEP challenge →
        NDES submits to CA (RPC) →
          CA issues cert →
            NDES returns cert to client →
              Stored in LocalMachine\My (device cert) or CurrentUser\My (user cert)
```

**Path 3 — Intune PKCS (via Certificate Connector)**
```
Intune Service → Certificate Connector (on-prem) →
  Connector enrols on behalf of user (RPC to CA) →
    CA issues cert →
      Connector encrypts with device public key →
        Intune delivers to device →
          Device decrypts, stores in appropriate store
```

### Certificate Validation (chain building)

When a certificate is used (TLS, auth, signing), the OS builds a chain:

1. Find issuer cert in local cache or download from AIA URL
2. Repeat up to Root CA
3. Check each cert's revocation status:
   - Download CRL from CDP URL and cache it (default cache: 10% of CRL lifetime)
   - Or query OCSP responder at AIA OCSP URL
4. Verify signatures, validity periods, Key Usage, Enhanced Key Usage
5. Verify Root CA cert is in `Cert:\LocalMachine\Root` (trusted root store)

**Failure at any step = certificate validation failure.**

### CRL Architecture

```
CA publishes CRL on schedule (e.g. weekly Base CRL + daily Delta CRL)
  └── CRL stored on CA server
       └── CDP (CRL Distribution Point) — locations embedded in every issued cert:
            ├── LDAP://CN=<CA>,CN=<container>,DC=... (AD-based)
            └── http://<crlHost>/crldist/<CA>.crl (HTTP-based)
                 └── Clients download and cache CRL
                      └── Delta CRL checked for recent revocations
```

**OCSP** provides real-time revocation status without full CRL download. Requires OCSP Responder role and AIA URL in certificates.

</details>

---

## Dependency Stack

```
Active Directory Domain Services (LDAP, Kerberos, RPC)
  └── CA Server (Windows Server, certsvc running)
       ├── Root CA cert valid and in trusted root stores
       ├── CA cert in NTAuth store (for domain authentication certs)
       ├── CRL/Delta CRL published and accessible (HTTP + LDAP CDPs)
       │    └── IIS / DFS / AD serving CRL files
       ├── OCSP Responder (optional but recommended)
       │    └── OCSP Signing cert valid
       └── Certificate Templates (configured in AD)
            ├── Version 2+ templates with correct EKU, CSP, security ACL
            └── Autoenroll permission for target groups
                 └── GPO: Certificate Services Client - Auto-Enrollment (Enabled)
                      OR Intune SCEP/PKCS profile assigned and synced
                           └── Client certificate in correct store
                                └── Application/service using certificate
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Auto-enrollment Event 6 (failed) | Template missing Autoenroll ACE, or GPO not applied | `gpresult /r`, template ACL |
| 0x80094800 on SCEP | Template name wrong in Intune profile, or Enroll permission missing | Intune SCEP profile + template ACL |
| 0x80094014 (no cert template) | Template not published to CA | `certutil -CATemplates` |
| certutil -ping fails | certsvc stopped, or firewall blocking RPC (135 + dynamic) | `Test-NetConnection -Port 135` |
| Chain validation fails (CRYPT_E_REVOCATION_OFFLINE) | CRL unreachable — CDP URL not accessible | Test CDP URLs from client |
| Certs expire silently | Auto-renewal threshold not met, or CA offline at renewal time | Check `certutil -v -store My` for renewal period |
| NDES challenge password fails | NDES app pool account issues, or challenge too old | NDES application event log |
| Machine certs not trusted for auth | CA not in NTAuth store | `certutil -enterprise -store NTAuth` |
| Intune PKCS fails with "no delivery agent" | Certificate Connector service stopped or cert expired | Check Connector server |
| Duplicate certs accumulating | Auto-enrollment issuing new certs without removing old | Template `superseded by` setting |

---

## Validation Steps

**1. Check CA service and basic ping**
```powershell
# On CA server
Get-Service certsvc | Select-Object Status
certutil -ping
# Expected: "Server "<CAName>" ICertRequest2 interface is alive"
```

**2. List published certificate templates**
```powershell
certutil -CATemplates
# Expected: list including your template name with "V2" or "V3" and allowed EKU
```

**3. Verify client auto-enrollment GPO**
```powershell
# On client
gpresult /scope computer /r | Select-String -Context 2,2 "Certificate"
# Expected: "Certificate Services Client - Auto-Enrollment" under Applied GPOs
```

**4. Check certificate lifecycle events**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-CertificateServicesClient-Lifecycle-System/Operational" -MaxEvents 30 |
  Select-Object TimeCreated, Id, Message | Format-List
# Event 19 = success, Event 6 = failure (note HRESULT)
```

**5. Verify CRL accessibility**
```powershell
# Get CDP URLs from an issued cert
$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -like "*$env:COMPUTERNAME*" } | Select-Object -First 1
($cert.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.31" }).Format(1)
# Then test each HTTP CDP:
Invoke-WebRequest "http://<cdpURL>/<caname>.crl" -UseBasicParsing | Select-Object StatusCode
```

**6. Check NTAuth store**
```powershell
certutil -enterprise -store NTAuth | Select-String "Subject:|Thumbprint:"
# Your issuing CA cert must appear here for domain auth certs
```

**7. Verify NDES health (if SCEP/Intune)**
```powershell
# From a client — test NDES challenge URL
Invoke-WebRequest "https://<NDESServer>/certsrv/mscep/mscep.dll?operation=GetCACert" -UseBasicParsing
# Expected: returns CA cert (HTTP 200 with binary content)
```

**8. Check template ACL**
```powershell
# Must run on CA server or machine with ADCS RSAT
Import-Module ADCSAdministration
$template = Get-CATemplate -Name "<TemplateName>"
# Or use certutil:
certutil -v -template "<TemplateName>" | Select-String "Allow|Deny|Security"
```

**9. Check Intune Certificate Connector (PKCS)**
```powershell
# On Connector server
Get-Service "Microsoft Intune Connector" | Select-Object Status
Get-WinEvent -LogName "Application" | Where-Object { $_.Source -like "*Intune*Connector*" } |
  Select-Object -First 10 TimeCreated, Message | Format-List
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Identify the enrollment path

Is this GPO auto-enrollment, Intune SCEP, or Intune PKCS?
```powershell
# Check MDM enrollment
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" |
  Where-Object { $_.ProviderId -eq "MS DM Server" }) | Measure-Object
# If count > 0: MDM/Intune enrolled → check SCEP/PKCS profile
# If count = 0: likely GPO auto-enrollment → check AD CS + GPO
```

### Phase 2 — GPO auto-enrollment issues

1. Confirm GPO is applied: `gpresult /r`
2. Confirm template exists and is published: `certutil -CATemplates`
3. Confirm computer/user group has Read + Enroll + Autoenroll on template ACL
4. Force re-enrollment: `certutil -pulse`
5. Check event log (Lifecycle-System/Operational) for error HRESULT

Common HRESULTs:
| Code | Meaning |
|------|---------|
| `0x80094012` | Template not found on CA |
| `0x80094800` | No access — check Enroll ACE |
| `0x80092013` | CRL offline during enrolment |
| `0x80070005` | Access denied — check service account |

### Phase 3 — Intune SCEP issues

1. Confirm NDES URL is reachable from client: `Invoke-WebRequest https://<NDES>/certsrv/mscep_admin/`
2. Check NDES application pool identity is running as dedicated service account (not Network Service)
3. Verify NDES challenge password has not expired (default: 60 minutes; set in MSCEP registry)
4. Check NDES/SCEP event logs: `Event Viewer → Application and Services → Microsoft → Windows → NDESCEP`
5. Confirm SCEP profile in Intune has correct template name, CA, and NDES URL
6. Check MDMDiagnosticsTool output: `mdmdiagnosticstool.exe -area Certificates -zip C:\Temp\certdiag.zip`

### Phase 4 — CRL/OCSP issues

1. Get CDP URLs from affected cert (see Validation Step 5)
2. Test each CDP URL from the client network (not CA server)
3. If HTTP CDP fails: check IIS on CA/CDP server, check firewall
4. If LDAP CDP fails: check AD replication, check LDAP connectivity
5. Publish new CRL if expired: on CA server, `certutil -CRL`
6. Check Delta CRL separately — both Base and Delta must be accessible

### Phase 5 — CA hierarchy / trust issues

1. Root CA cert must be in `Cert:\LocalMachine\Root` on all clients
2. Issuing CA cert must be in `Cert:\LocalMachine\CA` (Intermediate)
3. For domain auth: Issuing CA cert must be in NTAuth store (AD-wide)
4. Deploy missing certs via GPO: `Computer Configuration → Windows Settings → Security Settings → Public Key Policies`
5. After NTAuth update: `gpupdate /force` on clients; AD replication needed for full propagation

---

## Remediation Playbooks

<details><summary>Playbook 1 — Fix Certificate Template ACL for auto-enrollment</summary>

Run on CA server (requires Enterprise Admin):
```powershell
# Open template manager
mmc.exe
# Add snap-in: Certificate Templates
# Right-click template → Properties → Security
# Add: "Domain Computers" (for machine certs) or "Domain Users" (for user certs)
# Permissions: Read ✓, Enroll ✓, Autoenroll ✓

# OR via ADSI (scripted approach):
$templateDN = "CN=<TemplateName>,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=<domain>,DC=<tld>"
$acl = Get-Acl "AD:$templateDN"
$sid = (New-Object System.Security.Principal.NTAccount("Domain Computers")).Translate([System.Security.Principal.SecurityIdentifier])
# Add Enroll right (GUID: 0e10c968-78fb-11d2-90d4-00c04f79dc55)
$ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid,
  [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
  [System.Security.AccessControl.AccessControlType]::Allow,
  [GUID]"0e10c968-78fb-11d2-90d4-00c04f79dc55")
$acl.AddAccessRule($ace)
Set-Acl -Path "AD:$templateDN" -AclObject $acl
```

After fixing: `certutil -pulse` on a test client; check Lifecycle-System/Operational log.

**Rollback:** Remove the added ACE from template security.

</details>

<details><summary>Playbook 2 — Renew CA certificate (before expiry)</summary>

⚠️ High impact — plan a maintenance window and notify users.

```powershell
# On CA server — renew with new key pair (recommended) or same key
# Method 1: Same key pair (simpler, keeps same trust chain)
certutil -renewCert ReuseKeys

# Method 2: New key pair (more secure, requires re-publishing CA cert)
certutil -renewCert

# After renewal:
# 1. Publish new CA cert to AD
certutil -dspublish -f <NewCACert.cer> SubCA

# 2. Update NTAuth if CA cert changed
certutil -enterprise -addstore NTAuth <NewCACert.cer>

# 3. Push to clients via GPO (or wait for auto-push)
gpupdate /force   # on representative client to test
```

**Rollback:** Not easily reversible — CA renewal is permanent. Always test in staging first.

</details>

<details><summary>Playbook 3 — Recover from expired CRL causing validation failures</summary>

Immediate mitigation (restores validation while CRL issue is fixed):
```powershell
# On CA server — publish new CRL immediately
certutil -CRL

# Verify new CRL dates
certutil -store -enterprise Root | Select-String "Not After"

# Push to HTTP CDP (if using IIS virtual directory mapped to CertEnroll)
# CRL files live in: C:\Windows\System32\CertSrv\CertEnroll\
ls C:\Windows\System32\CertSrv\CertEnroll\*.crl

# Copy to web/DFS CDP if separate from CA
Copy-Item C:\Windows\System32\CertSrv\CertEnroll\*.crl \\<cdpServer>\<share>\

# Force LDAP publication
certutil -dspublish -f C:\Windows\System32\CertSrv\CertEnroll\<CA>.crl
```

Clients cache CRL — they may still see stale data until cache expires or is cleared:
```powershell
# On client — clear CRL cache
certutil -urlcache CRL delete
certutil -setreg chain\ChainCacheResyncFiletime @now
```

</details>

<details><summary>Playbook 4 — Configure NDES for Intune SCEP</summary>

Prerequisite: Windows Server with NDES role + MSCEP extension, AD CS installed.

```powershell
# NDES configuration checklist:
# 1. Service account: dedicated AD account, not expiring password, no admin rights needed
# 2. IIS app pool running as NDES service account
# 3. SCEP URL accessible from internet (via WAP/AAD App Proxy or direct)
# 4. CA template published for NDES to use (typically "CEP Encryption" + your device template)

# Verify NDES service account has necessary permissions on CA:
certutil -config "<CAServer>\<CAName>" -getconfig
# NDES account needs "Request Certificates" permission on CA

# Test NDES endpoint
Invoke-WebRequest "https://<NDESHost>/certsrv/mscep/mscep.dll?operation=GetCACert&message=test"

# Configure challenge password lifetime (registry on NDES server)
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography\MSCEP" `
  -Name "PasswordValidity" -Value 60  # minutes
```

In Intune portal:
- Create SCEP certificate profile
- Set NDES URL, Root CA cert, Template name
- Assign to device group

</details>

<details><summary>Playbook 5 — Migrate from SCEP to PKCS (simplify CA integration)</summary>

PKCS eliminates NDES and doesn't require device-side key generation challenges.

```powershell
# 1. Install Intune Certificate Connector on on-prem server
# Download from Intune portal → Tenant Administration → Connectors → Certificate Connectors
# Install with service account that has CA Enroll permission

# 2. Verify Connector health
Get-Service "Microsoft Intune Connector" | Select-Object Status, StartType
Get-WinEvent -LogName Application | Where-Object Source -like "*Intune*" | Select-Object -First 5 Message

# 3. In Intune: create PKCS certificate profile
# Device configuration → Certificate → PKCS certificate
# Set CA FQDN, CA name, Template name, Renewal threshold

# 4. Assign PKCS profile; remove SCEP profile from same devices
# (don't overlap — certs will duplicate)
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS EZAdmin — PKI/Certificate Services Evidence Collector
.NOTES    Run on affected client as admin. For CA-side info, run separately on CA server.
#>
$Output = "C:\Temp\PKI_Evidence_$(Get-Date -Format yyyyMMdd_HHmmss).txt"
New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null

"=== EZAdmin PKI Evidence Pack ===" | Out-File $Output
"Date: $(Get-Date)" | Out-File $Output -Append
"Host: $env:COMPUTERNAME" | Out-File $Output -Append
"Domain: $env:USERDNSDOMAIN" | Out-File $Output -Append
"" | Out-File $Output -Append

"=== MDM Enrollment ===" | Out-File $Output -Append
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" |
  Where-Object { $_.ProviderID -eq "MS DM Server" } |
  Select-Object PSChildName, ProviderID) | Out-File $Output -Append

"" | Out-File $Output -Append
"=== Certs in LocalMachine\My ===" | Out-File $Output -Append
Get-ChildItem Cert:\LocalMachine\My |
  Select-Object Subject, Issuer, NotBefore, NotAfter, Thumbprint |
  Format-Table -AutoSize | Out-File $Output -Append

"" | Out-File $Output -Append
"=== GPO: Auto-Enrollment Applied ===" | Out-File $Output -Append
gpresult /scope computer /r 2>&1 | Select-String "Certificate" | Out-File $Output -Append

"" | Out-File $Output -Append
"=== Certificate Lifecycle Events (last 50) ===" | Out-File $Output -Append
try {
  Get-WinEvent -LogName "Microsoft-Windows-CertificateServicesClient-Lifecycle-System/Operational" `
    -MaxEvents 50 -ErrorAction Stop |
    Where-Object { $_.LevelDisplayName -in 'Error','Warning' } |
    Select-Object TimeCreated, Id, Message | Format-List | Out-File $Output -Append
} catch { "Log not available: $_" | Out-File $Output -Append }

"" | Out-File $Output -Append
"=== CRL Cache ===" | Out-File $Output -Append
certutil -urlcache CRL 2>&1 | Out-File $Output -Append

"" | Out-File $Output -Append
"=== Trusted Root CAs ===" | Out-File $Output -Append
Get-ChildItem Cert:\LocalMachine\Root |
  Select-Object Subject, NotAfter | Format-Table -AutoSize | Out-File $Output -Append

"" | Out-File $Output -Append
"=== Intermediate CAs ===" | Out-File $Output -Append
Get-ChildItem Cert:\LocalMachine\CA |
  Select-Object Subject, NotAfter | Format-Table -AutoSize | Out-File $Output -Append

"" | Out-File $Output -Append
"=== Network Connectivity to CA (port 135) ===" | Out-File $Output -Append
# Update with your CA FQDN
try { Test-NetConnection -ComputerName "<CAServerFQDN>" -Port 135 -WarningAction SilentlyContinue |
  Select-Object ComputerName, TcpTestSucceeded | Out-File $Output -Append
} catch { "CA FQDN not set — skip" | Out-File $Output -Append }

Write-Host "Evidence collected: $Output"
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Ping CA | `certutil -ping` |
| List published templates | `certutil -CATemplates` |
| Force certificate auto-enrollment | `certutil -pulse` |
| List certs in machine personal store | `Get-ChildItem Cert:\LocalMachine\My \| Select Subject, NotAfter` |
| Verify cert chain | `certutil -verify -urlfetch <thumbprint>` |
| Publish new CRL | `certutil -CRL` (on CA server) |
| Publish CRL to LDAP | `certutil -dspublish -f <crl.file>` |
| Clear CRL cache on client | `certutil -urlcache CRL delete` |
| Check NTAuth store | `certutil -enterprise -store NTAuth` |
| Add cert to NTAuth | `certutil -enterprise -addstore NTAuth <cert.cer>` |
| Publish CA cert to AD | `certutil -dspublish -f <ca.cer> SubCA` |
| Show CA config | `certutil -getconfig` |
| Show template details | `certutil -v -template "<TemplateName>"` |
| Export CRL to file | `certutil -store "ldap:///CN=<CA>,..." <output.crl>` |
| Check NDES URL | `Invoke-WebRequest https://<NDES>/certsrv/mscep/mscep.dll?operation=GetCACert` |
| Get CA cert thumbprint | `certutil -store CA \| Select-String "Thumbprint:"` |
| Remove stale certs | `Get-ChildItem Cert:\LocalMachine\My \| Where-Object { $_.NotAfter -lt (Get-Date) } \| Remove-Item` |
| MDM cert diagnostics | `mdmdiagnosticstool.exe -area Certificates -zip C:\Temp\certdiag.zip` |

---

## 🎓 Learning Pointers

- **The two-tier CA hierarchy exists for operational resilience.** The Root CA is kept offline (ideally air-gapped). If the Issuing CA is compromised, you revoke its certificate from the Root without exposing the Root CA's private key. For MSP environments managing multiple tenants, this isolation prevents a single breach from destroying all trust. See [AD CS best practices](https://learn.microsoft.com/en-us/windows-server/identity/ad-cs/active-directory-certificate-services-overview).

- **CRL vs OCSP: choose the right revocation model.** CRL is a downloaded list — large, cached, works offline. OCSP is a real-time per-cert query — fast, current, requires network access. OCSP stapling (server caches OCSP response and includes it in TLS handshake) is the modern best practice but requires web server support. For environments with high revocation activity (lots of certificate churn), OCSP is strongly preferred. See [OCSP Responder configuration](https://learn.microsoft.com/en-us/windows-server/networking/core-network-guide/cncg/server-certs/configure-the-cdp-and-aia-extensions-on-ca1).

- **Template versioning matters.** V1 templates (legacy) cannot be modified. V2 templates (Windows 2003 CA+) support autoenrollment, custom EKU, and CSP selection. V3 templates support CNG (Cryptography Next Generation) and elliptic curve keys. For Intune SCEP, you need V2 or V3 with specific EKU. Never edit V1 templates for new deployments — duplicate them as V2.

- **The NTAuth store propagates via AD, not Group Policy.** When you add a cert to NTAuth via `certutil -enterprise -addstore NTAuth`, it writes to AD DS (`CN=NTAuthCertificates,CN=Public Key Services,...`). It then replicates to all DCs and down to domain-joined machines via the Auto Root Certificate Update mechanism (Windows Update / Windows Root Certificate Program or GPCSE). Propagation takes time — don't expect instant effect.

- **SCEP challenge passwords are the weakest link in NDES deployments.** The MSCEP challenge is a one-time password valid for N minutes (default 60). If the Intune policy cycle runs outside that window, enrollment fails. For high-scale deployments, consider increasing `PasswordValidity` to 120+ minutes or migrating to PKCS. See [Intune SCEP troubleshooting](https://learn.microsoft.com/en-us/mem/intune/protect/troubleshoot-scep-certificate-ndes-policy).

- **Certificate sprawl is a real MSP problem.** Auto-enrollment without `Supersede` template settings causes duplicate certs accumulating in machine stores. Over time, this causes long chain-building delays and confuses applications that iterate over certs. Set the `Superseded Templates` list in each new template version and monitor cert count with `(Get-ChildItem Cert:\LocalMachine\My).Count`.
