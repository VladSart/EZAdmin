# Windows Certificate Services (PKI/CA) — Hotfix Runbook (Mode B: Ops)
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

Run on the **affected client machine** first, then on the **CA server** if client looks clean.

```powershell
# 1. Check what certificates the machine has (personal store)
Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, Issuer, NotAfter, Thumbprint | Format-Table -AutoSize

# 2. Check certificate chain errors
$cert = Get-ChildItem Cert:\LocalMachine\My | Select-Object -First 1
$chain = New-Object Security.Cryptography.X509Certificates.X509Chain
$chain.Build($cert) | Out-Null
$chain.ChainStatus | Format-Table -AutoSize

# 3. Check NDES/CEP/CES enrollment errors (client event log)
Get-WinEvent -LogName "Microsoft-Windows-CertificateServicesClient-Lifecycle-System/Operational" -MaxEvents 20 |
  Where-Object { $_.LevelDisplayName -in 'Error','Warning' } |
  Select-Object TimeCreated, Message | Format-List

# 4. Check CA service health (run on CA server)
Get-Service certsvc | Select-Object Status, StartType
certutil -ping

# 5. Check CRL validity (run on CA server or client)
certutil -verify -urlfetch <certThumbprint>
```

**Interpretation:**
| Result | Action |
|--------|--------|
| No certs in `LocalMachine\My` | Enrollment hasn't run — check policy / Intune SCEP profile |
| Chain status shows `RevocationStatusUnknown` | CRL/OCSP unreachable — check CRL Distribution Point URL |
| `certsvc` stopped | Start CA service: `Start-Service certsvc` |
| `certutil -ping` fails | CA RPC connectivity issue — check firewall / CA health |
| Cert present but expired | Auto-enrollment failed — check GPO or Intune SCEP trigger |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Network connectivity to CA (TCP 135 + dynamic RPC, or HTTPS for CEP/CES)
  └── CA Service running (certsvc)
       └── CA certificate valid and in NTAuth store (for domain auth)
            └── CRL/OCSP accessible from clients (HTTP/LDAP URL reachable)
                 └── Certificate Template configured correctly (permissions, CSP, EKU)
                      └── Auto-enrollment GPO enabled OR Intune SCEP/PKCS profile assigned
                           └── Client can contact AD (for GPO-based enrolment)
                                └── Certificate issued to client machine or user
                                     └── Cert in correct store (MY, ROOT, CA, NTAUTH)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Identify what's broken (scope)**
```powershell
# On affected client: check autoenrollment log
certutil -setreg\SetupStatus -SETUP_DCOM_SECURITY_UPDATED_FLAG 2>$null
Get-WinEvent -LogName "Application" -MaxEvents 50 |
  Where-Object { $_.Source -like "*AutoEnrollment*" -or $_.Source -like "*CertMgr*" } |
  Select-Object TimeCreated, Message | Format-List
```
Expected good output: Event ID 19 (`Certificate enrollment for ... succeeded`).
Bad: Event ID 6 (`Certificate enrollment for ... failed`) — note the error code.

**Step 2 — Check SCEP/PKCS profile status (Intune-managed devices)**
```powershell
# Get device management info
(Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Enrollments\*" |
  Where-Object { $_.ProviderId -eq "MS DM Server" }) |
  Select-Object PSChildName, ProviderID
# Then check MDM diagnostics log
mdmdiagnosticstool.exe -area DeviceEnrollment;MDM -zip C:\Temp\mdmdiag.zip
```
Expected: enrollment keys present; DiagnosticsLog shows certificate profile applied.

**Step 3 — Verify CRL accessibility**
```powershell
# Get CDP URLs from a certificate
$cert = Get-ChildItem Cert:\LocalMachine\My | Select-Object -First 1
$cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq "CRL Distribution Points" } |
  ForEach-Object { $_.Format(1) }
```
Then test each URL:
```powershell
Invoke-WebRequest -Uri "http://<cdpURL>/CRL/<CAName>.crl" -UseBasicParsing | Select-Object StatusCode
```
Expected: `StatusCode 200`. Fail → CRL unreachable; check IIS/file share serving CRL.

**Step 4 — Validate CA reachability (for on-prem CA)**
```powershell
# From client — test RPC to CA
Test-NetConnection -ComputerName <CAServerFQDN> -Port 135
# Test HTTPS (for CEP endpoint)
Test-NetConnection -ComputerName <CAServerFQDN> -Port 443
```
Expected: `TcpTestSucceeded: True`. Fail → firewall blocking CA ports.

**Step 5 — Check NTAuth store (machine/domain auth certs)**
```powershell
# Root CA cert must be in NTAuth for smartcard/machine auth
certutil -enterprise -store NTAuth | Select-String "Subject:"
```
Expected: your CA's Subject line present.

---

## Common Fix Paths

<details><summary>Fix 1 — Force auto-enrollment refresh</summary>

Run on client as SYSTEM or Domain Admin:
```powershell
# Trigger certificate auto-enrollment
certutil -pulse

# Or via GPO refresh
gpupdate /force
Start-Sleep -Seconds 30
Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, NotAfter
```

If GPO-based: verify `Certificate Services Client - Auto-Enrollment` GPO is applied:
```powershell
gpresult /scope computer /r | Select-String "Certificate"
```

**Rollback:** None needed — this only triggers enrollment, doesn't remove certs.

</details>

<details><summary>Fix 2 — Restart CA service</summary>

```powershell
# On CA server
Stop-Service certsvc -Force
Start-Sleep -Seconds 5
Start-Service certsvc
Get-Service certsvc

# Verify CA is responding
certutil -ping
```

Expected: `CertUtil: -ping command completed successfully`.

**Rollback:** `Stop-Service certsvc` (but this takes CA offline — coordinate with change window).

</details>

<details><summary>Fix 3 — Publish a new CRL (CRL expired or stale)</summary>

```powershell
# On CA server — publish new CRL immediately
$CA = (certutil -CAInfo name 2>&1 | Select-String "CA name:").ToString().Split(":")[1].Trim()
certutil -CRL

# Verify new CRL published
certutil -store -enterprise Root | Select-String "NotAfter"
```

Then replicate to CRL distribution points (IIS/LDAP):
```powershell
# If using LDAP CDP — force AD replication
repadmin /syncall /AdeP

# If using web CDP — confirm IIS serving correct CRL
Invoke-WebRequest "http://<cdpHost>/<caname>.crl" -UseBasicParsing
```

</details>

<details><summary>Fix 4 — Resolve Intune SCEP profile failure</summary>

```powershell
# Check Intune SCEP/NDES logs on client
Get-WinEvent -LogName "Microsoft-Windows-CertificateServicesClient-Lifecycle-User/Operational" -MaxEvents 30 |
  Select-Object TimeCreated, Id, Message | Format-List

# Force Intune sync to re-push profile
Start-Process "C:\Program Files (x86)\Microsoft Intune Management Extension\Microsoft.Management.Services.IntuneWindowsAgent.exe"
# Or from PowerShell:
Get-ScheduledTask -TaskName "PushLaunch" | Start-ScheduledTask
```

On Intune portal: Device → Certificates — check if SCEP profile shows "Succeeded" or "Error". Error codes:
- `0x80094800` — template not found or client doesn't have Enroll permission
- `0x8009480f` — NDES connector issue — check NDES service account

**Rollback:** Remove SCEP profile assignment in Intune if causing issues; manually enrol or use PKCS instead.

</details>

<details><summary>Fix 5 — Publish CA cert to NTAuth store</summary>

Run on Domain Controller or machine with AD write access:
```powershell
# Publish CA cert to NTAuth store
certutil -enterprise -addstore NTAuth <CACert.cer>

# Verify
certutil -enterprise -store NTAuth | Select-String "Subject:"

# Force propagation to clients
gpupdate /force
```

**Rollback:**
```powershell
certutil -enterprise -delstore NTAuth <Thumbprint>
```
**⚠️ Destructive** — removing from NTAuth breaks smartcard/machine authentication for that CA.

</details>

---

## Escalation Evidence

```
ESCALATION: Windows Certificate Services / PKI Issue
=====================================================
Date/Time         : [YYYY-MM-DD HH:MM UTC]
Reporter          : [Name / Tier]
Affected device(s): [Hostname(s) / count]
CA Server         : [FQDN]
CA Type           : [Enterprise Root / Subordinate / NDES / Cloud PKCS]
Issue description : [e.g. "SCEP certs not issuing to Intune-joined devices"]

--- Client Evidence ---
systeminfo output: [OS, domain membership]
certutil -ping result: [success/failure]
Auto-enrollment event errors: [Event ID + message]
Certs in LocalMachine\My: [Subject + NotAfter]
CRL URL tested: [URL + HTTP status code]

--- CA Server Evidence (if accessible) ---
certsvc status: [Running/Stopped]
certutil -CRL result: [output]
NTAuth store: [CA cert present Y/N]
CA event log errors: [Event ID + message from Application log]

--- Intune (if applicable) ---
SCEP profile status: [Succeeded/Error + error code]
NDES connector version: [x.x.x]
NDES URL reachable: [Y/N]

Attempted fixes:
1. [What was tried + result]
2. [What was tried + result]

Priority/Impact: [How many users/devices affected, what's broken]
```

---

## 🎓 Learning Pointers

- **CRL freshness is the silent killer.** CRL has two validity periods: `ThisUpdate` and `NextUpdate`. If `NextUpdate` has passed and clients can't reach the CRL Distribution Point, *every* certificate validation fails — even if the cert is valid. Monitor CRL lifetime and IIS/CDP health proactively. See [CRL troubleshooting guide](https://learn.microsoft.com/en-us/troubleshoot/windows-server/certificates-and-public-key-infrastructure-pki/troubleshoot-certificate-revocation).

- **NDES is a single point of failure in SCEP deployments.** NDES (Network Device Enrollment Service) uses a dedicated service account and SCEP challenge password. If the account's password expires or Kerberos token bloat hits, all SCEP enrollments silently fail. Check [NDES troubleshooting](https://learn.microsoft.com/en-us/mem/intune/protect/troubleshoot-scep-certificate-ndes-policy).

- **NTAuth store controls which CAs can issue domain auth certs.** If a machine cert is not from a CA published to NTAuth, it won't authenticate to AD services — this is a frequent issue after CA migrations or when adding a Subordinate CA. Always publish new CAs to NTAuth and wait for AD replication.

- **PKCS vs SCEP in Intune:** PKCS (via Intune Certificate Connector) delivers certs without NDES — simpler but requires the Intune Certificate Connector on-prem. SCEP uses NDES + MSCEP for device-side key generation. Choose based on your security requirements and infrastructure. [Comparison here](https://learn.microsoft.com/en-us/mem/intune/protect/certificates-configure).

- **Auto-enrollment requires Enroll permission on the template.** The `Domain Computers` or `Domain Users` group needs `Read` + `Enroll` (and optionally `Autoenroll`) on the template ACL. Missing `Autoenroll` permission means GPO-triggered auto-enrollment silently skips the template.
