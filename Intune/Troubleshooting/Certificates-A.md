# Intune Certificate Deployment — Reference Runbook (Mode A: Deep Dive)
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

Covers SCEP (Simple Certificate Enrollment Protocol) and PKCS certificate delivery via Microsoft Intune to Windows 10/11 and macOS endpoints. Assumes:

- Devices are enrolled in Intune (MDM authority = Microsoft Intune or co-managed)
- For SCEP: NDES (Network Device Enrollment Service) role is deployed on-premises or in Azure IaaS
- For PKCS: PFX Certificate Connector is installed and running
- A supported Enterprise CA (Windows Server AD CS) is in place
- Root CA and Intermediate CA certificates are distributed via Intune Trusted Certificate profiles

Does **not** cover:
- Third-party CAs (DigiCert, Entrust via Intune connectors — separate flow)
- User certificate requests from browser/MMC
- S/MIME certificate configuration

---

## How It Works

<details><summary>Full architecture</summary>

### SCEP Flow (most common for device certificates)

```
Device                  Intune Service           NDES/SCEP Proxy          CA
  |                          |                         |                   |
  |-- MDM Check-in --------->|                         |                   |
  |<- SCEP Profile payload --|                         |                   |
  |                          |                         |                   |
  |-- SCEP Request ---------------------------------->|                   |
  |   (Challenge password embedded)                   |                   |
  |                          |                         |-- Cert Request -->|
  |                          |                         |<- Signed Cert ----|
  |<- Signed Certificate ---------------------------------|               |
  |                          |                         |                   |
  |-- Compliance/status ----->|                         |                   |
```

**Key components:**
- **Intune SCEP Profile**: defines cert subject, SAN, key usage, validity, and SCEP URL
- **NDES**: Windows Server role (or Azure Application Proxy fronted) that acts as SCEP proxy
- **NDES Application Pool (AADGraph or ISAPI)**: must run as service account with CA enrollment rights
- **Microsoft Intune Certificate Connector**: optional intermediary; required for PKCS but also used to validate SCEP challenge passwords when not using AAD-integrated NDES
- **Challenge Password**: one-time OTP that NDES generates; Intune validates this server-side to prevent unauthorized enrollments

### PKCS Flow (user/device certificates with exportable private key)

```
Device                  Intune Service           PFX Connector             CA
  |                          |                         |                   |
  |-- MDM Check-in --------->|                         |                   |
  |<- PKCS Profile payload --|                         |                   |
  |                          |-- CSR forwarded ------->|                   |
  |                          |                         |-- Enroll cert --->|
  |                          |                         |<- PFX package ----|
  |                          |<- Encrypted PFX --------|                   |
  |<- Encrypted PFX ---------|                         |                   |
  |   (decrypted locally)    |                         |                   |
```

**Key difference from SCEP:** The CA issues and returns a certificate with a private key (PKCS#12). The private key never leaves the device in SCEP; in PKCS it is generated on-premises and delivered encrypted.

### Trusted Certificate Profile

Before SCEP or PKCS profiles can be processed, the device must trust the issuing CA chain. Intune distributes this as a separate "Trusted certificate" profile:
- Deploys Root CA cert to **Trusted Root Certification Authorities** store
- Deploys Intermediate CA cert to **Intermediate Certification Authorities** store
- Must be assigned to **same group** as SCEP/PKCS profile
- Must complete delivery **before** the SCEP/PKCS profile is processed (Intune handles ordering by profile type, but delays occur)

</details>

---

## Dependency Stack

```
[Intune Device Certificate]
         |
         ▼
[SCEP or PKCS Profile assigned to device group]
         |
         ▼
[Trusted Certificate Profile (Root + Intermediate CA)]
         |
         ▼
[Device enrollment state = Succeeded]
         |
         ├── SCEP path ──────────────────────────────────────────────────┐
         │                                                                │
         ▼                                                                ▼
[NDES Server reachable from device]                  [PFX Certificate Connector running]
         |                                                                |
         ▼                                                                ▼
[NDES App Pool account has Enroll permission on CA template]   [Connector service account: CA Enroll rights]
         |                                                                |
         ▼                                                                ▼
[CA Template: correct EKUs, subject requirements]   [CA Template: Allow private key export]
         |                                                                |
         └─────────────────────┬──────────────────────────────────────────┘
                               ▼
                   [Certificate written to device cert store]
                               |
                               ▼
                   [Intune reports "Succeeded" for cert profile]
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Profile shows "Pending" indefinitely | Trusted cert profile not yet delivered, or device offline | Check trusted cert profile status first; verify device last check-in |
| Profile shows "Failed" — error 0x80094800 | NDES challenge password rejected | NDES event log 24 / NDESConnector.log; check clock skew |
| Profile shows "Failed" — error 0x80094004 | CA template not found or not published | `certutil -TCAInfo` on NDES; check template name in profile matches exactly |
| Profile shows "Failed" — error 0x80070005 | NDES app pool account denied enroll permission | CA template security — add NDES account with Enroll |
| Certificate issued but wrong SAN | Subject name config error in profile | Check `{{UserPrincipalName}}` vs `{{DeviceId}}` variables in profile |
| Certificate delivered but app doesn't see it | Certificate in wrong store (User vs Device) | Profile "Certificate store" setting; SCEP to device store requires system context delivery |
| Cert renews every cycle / never stable | Short validity + auto-renewal threshold overlap | Increase validity period; check renewal threshold % in profile |
| macOS: profile installed, no cert | SCEP payload missing challenge URL or CA fingerprint | Use `security find-certificate` to verify; inspect MDM profile XML |
| "NDES Connector not available" in Intune | Connector heartbeat stopped | Check service `NDESConnectorSvc`; review `\ProgramData\Microsoft\Intune NDES Connector\Logs` |
| Certificate expired, not renewed | Device offline during renewal window, or Intune assignment removed | Check assignment scope; device must check in during renewal window |

---

## Validation Steps

**Step 1 — Confirm device is enrolled and synced recently**
```powershell
# Run on affected device
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" |
    Select-Object EnrollmentState, ProviderID, UPN |
    Where-Object ProviderID -eq "MS DM Server"
```
Expected: `EnrollmentState = 1` (enrolled). If missing or state ≠ 1, enrollment is the root problem, not certificates.

**Step 2 — Check Trusted Certificate profile delivered first**
```powershell
# Confirm Root CA in Trusted Root store
Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like "*<YourRootCAName>*" | Select-Object Subject, Thumbprint, NotAfter
```
Expected: Your Root CA appears with a future expiry. If absent, the Trusted Certificate profile has not delivered — fix this before investigating SCEP/PKCS.

**Step 3 — Check for the issued certificate**
```powershell
# Device cert store
Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, Issuer, Thumbprint, NotAfter | Format-Table -AutoSize

# User cert store (for user-targeted SCEP profiles)
Get-ChildItem Cert:\CurrentUser\My | Select-Object Subject, Issuer, Thumbprint, NotAfter | Format-Table -AutoSize
```
Expected: Certificate with subject matching profile config (e.g. `CN=<devicename>` or `CN=<upn>`). If absent, delivery failed.

**Step 4 — Check Intune MDM diagnostic log for SCEP errors**
```powershell
# Export MDM diagnostics
$diagPath = "$env:TEMP\MDMDiag_$(Get-Date -Format yyyyMMdd_HHmmss)"
New-Item -ItemType Directory -Path $diagPath -Force | Out-Null
MdmDiagnosticsTool.exe -out $diagPath
Write-Host "Diagnostics saved to: $diagPath"
```
Then review `MDMDiagReport.xml` — search for `SCEP`, `CertificateStore`, or `80094` error codes.

**Step 5 — Check NDES connectivity from device**
```powershell
# Replace with your NDES URL from the Intune SCEP profile
$ndesUrl = "https://<ndes-server>/certsrv/mscep/mscep.dll"
try {
    $response = Invoke-WebRequest -Uri $ndesUrl -UseDefaultCredentials -TimeoutSec 10
    Write-Host "NDES reachable. Status: $($response.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "NDES unreachable: $($_.Exception.Message)" -ForegroundColor Red
}
```
Expected: HTTP 200 or 403 (both indicate the server is responding). If connection refused or timeout, check firewall/proxy.

**Step 6 — Validate NDES service health (run on NDES server)**
```powershell
# Check NDES-related services and app pool
Get-Service mscep_admin, mscep | Select-Object Name, Status
Import-Module WebAdministration
Get-WebConfiguration system.applicationHost/applicationPools/add |
    Where-Object { $_.name -like "*SCEP*" -or $_.name -like "*NDES*" } |
    Select-Object name, state
```
Expected: Services running, app pools Started. If stopped, review Windows Event Log → Application for errors from source "MSCEP" or "NDESConnector".

---

## Troubleshooting Steps (by phase)

### Phase 1: Profile assignment & delivery

1. In Intune portal, navigate to **Devices → Configuration profiles** → select the SCEP/PKCS profile → **Device and user check-in status**
2. Identify if the failure is **device-specific** (isolated hardware/OS issue) or **widespread** (connector/CA issue)
3. Verify the assignment group includes the affected device — use **Devices → [device] → Device configuration** to see all assigned profiles and their status
4. Confirm **Trusted Certificate profiles** (Root and Intermediate) show **Succeeded** before investigating SCEP/PKCS

### Phase 2: NDES health (SCEP only)

1. On the NDES server, open **Event Viewer → Application** — filter for source **MSCEP**
2. Event ID **2**: challenge password issued successfully
3. Event ID **24**: SCEP request failed — check sub-code; common: CA unreachable (check CA service), template access denied (check security)
4. Check **IIS logs** at `C:\inetpub\logs\LogFiles\W3SVC*` for 500 errors on `/certsrv/mscep/mscep.dll`
5. Run `certutil -ping` on NDES server to verify CA RPC connectivity

### Phase 3: CA template validation

1. Open **Certification Authority MMC** on CA server
2. Navigate to **Certificate Templates** — right-click → **Manage**
3. Find the template referenced in the Intune profile (exact name match required — case-sensitive for SCEP)
4. Verify:
   - **Request Handling** tab: Key usage matches profile (e.g., Signature and encryption for client auth)
   - **Security** tab: NDES service account has **Enroll** permission
   - **Subject Name** tab: "Supply in request" selected (SCEP supplies the subject)
   - **Extensions** tab: Application Policies includes **Client Authentication** (OID 1.3.6.1.5.5.7.3.2) if used for device auth
5. Template must be **published** to CA: right-click **Certificate Templates** in CA console → **New → Certificate Template to Issue**

### Phase 4: PFX Connector (PKCS only)

1. On the connector server, review `C:\ProgramData\Microsoft\Intune NDES Connector\Logs\NDESConnector.log`
2. Search for `CertificateRequest` entries — look for failures with HTTP error codes
3. Verify the **Intune Certificate Connector** Windows service is running: `Get-Service -Name "NDESConnectorSvc"`
4. Connector must be able to reach `*.manage.microsoft.com` and `*.microsoftonline.com` — check proxy bypass rules
5. Re-run connector setup if heartbeat is stale (> 2 hours): `C:\Program Files\Microsoft Intune\NDESConnector\NDESConnectorUI.exe`

---

## Remediation Playbooks

<details><summary>Playbook 1 — NDES App Pool Account Permission Fix</summary>

**When:** Certificate requests fail with 0x80070005 (access denied) or CA event showing denied enrollment.

```powershell
# Run on CA server
# Step 1: Identify NDES service account
$ndesAccount = "<DOMAIN\NDESServiceAccount>"

# Step 2: Check current template permissions
$templateName = "<YourTemplateName>"
$certutil = certutil -v -template $templateName 2>&1
$certutil | Select-String "AccessRules|SDDL" | Out-Host

# Step 3: Grant Enroll via certutil (alternative to MMC)
# Open Certification Authority MMC → Certificate Templates → Manage
# Right-click template → Properties → Security → Add NDES account → check Enroll
# No PowerShell equivalent for template ACL — must use MMC or ADSI

Write-Host "After granting Enroll permission in MMC, run from NDES server:" -ForegroundColor Yellow
Write-Host 'iisreset /restart' -ForegroundColor Cyan
Write-Host 'Restart-Service NDESConnectorSvc -ErrorAction SilentlyContinue' -ForegroundColor Cyan
```

**Rollback:** Remove Enroll permission from NDES account in template security — this prevents new issuances but does not revoke existing certs.

</details>

<details><summary>Playbook 2 — Force Certificate Re-enrollment on Device</summary>

**When:** Certificate is missing, expired, or corrupted on a specific device and needs to be re-requested.

```powershell
# Run on affected device (as SYSTEM or local admin)

# Step 1: Remove stale/expired Intune-issued certificates
# CAUTION: Only remove certs issued by your Intune CA — check Issuer field first
$intuneCAIssuer = "*<YourCAName>*"
$certsToRemove = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Issuer -like $intuneCAIssuer -and $_.NotAfter -lt (Get-Date).AddDays(30) }

foreach ($cert in $certsToRemove) {
    Write-Host "Removing: $($cert.Subject) [Thumbprint: $($cert.Thumbprint)]" -ForegroundColor Yellow
    # Uncomment to actually remove:
    # Remove-Item -Path "Cert:\LocalMachine\My\$($cert.Thumbprint)" -Force
}

# Step 2: Force Intune sync to re-trigger certificate profile
$session = New-CimSession
Invoke-CimMethod -Namespace root/cimv2/mdm/dmmap `
    -ClassName MDM_DMClient `
    -MethodName TriggerDMSession `
    -Arguments @{ ProviderID = "MS DM Server" } `
    -CimSession $session

Write-Host "Intune sync triggered. Certificate should re-enroll within 5-10 minutes." -ForegroundColor Green
```

**Rollback:** If the device loses a certificate it needs for authentication (e.g., Wi-Fi), re-enroll or use a wired connection to restore access.

</details>

<details><summary>Playbook 3 — Fix Clock Skew Causing SCEP Challenge Failures</summary>

**When:** NDES event 24 shows "The request contains no certificate template information" or challenge password is rejected. Often caused by time drift between device, NDES server, and CA.

```powershell
# Run on NDES server to check CA clock
$caServer = "<YourCAServerName>"
$caTime = (Get-Date -ComputerName $caServer).ToUniversalTime()
$localTime = (Get-Date).ToUniversalTime()
$diff = [Math]::Abs(($caTime - $localTime).TotalSeconds)
Write-Host "CA UTC: $caTime | NDES UTC: $localTime | Diff: ${diff}s"
if ($diff -gt 300) {
    Write-Host "WARNING: Clock skew exceeds 5 minutes — Kerberos and SCEP will fail!" -ForegroundColor Red
} else {
    Write-Host "Clock skew OK." -ForegroundColor Green
}

# Fix: Force NTP sync on NDES server
w32tm /resync /force
w32tm /query /status

# Fix: Force NTP sync on affected device (run on device)
# w32tm /resync /force
```

**Rollback:** N/A — NTP sync is non-destructive.

</details>

<details><summary>Playbook 4 — Redeploy Trusted Certificate Profiles</summary>

**When:** Devices have SCEP/PKCS profile failures because the Root or Intermediate CA cert is not in the trust store.

```powershell
# Run on device to verify CA chain
$rootThumbprint = "<YourRootCAThumbprint>"
$intThumbprint  = "<YourIntermediateCAThumbprint>"

$root = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $rootThumbprint
$int  = Get-ChildItem Cert:\LocalMachine\CA   | Where-Object Thumbprint -eq $intThumbprint

if ($root) { Write-Host "Root CA: PRESENT" -ForegroundColor Green }
else        { Write-Host "Root CA: MISSING — check Trusted Certificate profile assignment" -ForegroundColor Red }

if ($int)  { Write-Host "Intermediate CA: PRESENT" -ForegroundColor Green }
else       { Write-Host "Intermediate CA: MISSING — check Trusted Certificate profile assignment" -ForegroundColor Red }
```

In Intune portal: **Devices → Configuration profiles** → Trusted Certificate profile → **Assignments** — verify the profile is assigned to the same group as the SCEP/PKCS profile.

**Note:** Trusted Certificate profiles have no user-visible error when they fail silently. Always validate the cert store directly.

</details>

<details><summary>Playbook 5 — Rebuild NDES Connector Registration</summary>

**When:** Connector shows as stale in Intune portal (last heartbeat > 2 hours), and restarting the service doesn't help.

```powershell
# Run on NDES/Connector server as local admin

# Step 1: Stop connector service
Stop-Service NDESConnectorSvc -Force -ErrorAction SilentlyContinue

# Step 2: Clear connector registration tokens
$connectorReg = "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\NDESConnector"
if (Test-Path $connectorReg) {
    Remove-Item $connectorReg -Recurse -Force
    Write-Host "Cleared connector registration." -ForegroundColor Yellow
}

# Step 3: Re-register connector (requires Global Admin or Intune Admin credentials)
$connectorUI = "C:\Program Files\Microsoft Intune\NDESConnector\NDESConnectorUI.exe"
if (Test-Path $connectorUI) {
    Start-Process $connectorUI
    Write-Host "Complete re-registration in the UI that opens." -ForegroundColor Cyan
} else {
    Write-Host "Connector not installed at expected path. Re-run connector installer from Intune portal." -ForegroundColor Red
}
```

**Rollback:** Reinstall the connector from Intune portal (Tenant admin → Connectors and tokens → Certificate connectors).

</details>

---

## Evidence Pack

Run this on the **affected device** and attach output to escalation ticket:

```powershell
<#
.SYNOPSIS  Collect Intune certificate deployment evidence for escalation
.NOTES     Run as local admin or SYSTEM. Output saved to desktop.
#>

$output = [System.Collections.Generic.List[string]]::new()
$ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC" -AsUTC
$out    = "$env:USERPROFILE\Desktop\CertEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).txt"

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
    "Device    : $env:COMPUTERNAME"
    "User      : $env:USERNAME"
}

Add-Section "OS Version" {
    (Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsBuildNumber | Format-List | Out-String).Trim()
}

Add-Section "Intune Enrollment State" {
    Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" 2>$null |
        Select-Object PSChildName, EnrollmentState, ProviderID, UPN |
        Where-Object ProviderID -like "*DM*" | Format-List | Out-String
}

Add-Section "Certificates in LocalMachine\My" {
    Get-ChildItem Cert:\LocalMachine\My |
        Select-Object Subject, Issuer, Thumbprint, NotBefore, NotAfter |
        Format-Table -AutoSize | Out-String
}

Add-Section "Certificates in LocalMachine\Root (CA certs)" {
    Get-ChildItem Cert:\LocalMachine\Root |
        Where-Object Subject -like "*CA*" |
        Select-Object Subject, Thumbprint, NotAfter |
        Format-Table -AutoSize | Out-String
}

Add-Section "Certificates in LocalMachine\CA (Intermediates)" {
    Get-ChildItem Cert:\LocalMachine\CA |
        Select-Object Subject, Issuer, Thumbprint, NotAfter |
        Format-Table -AutoSize | Out-String
}

Add-Section "MDM Event Log (last 50 SCEP/Cert events)" {
    $events = Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match "SCEP|Certificate|Cert" } |
        Select-Object -First 50
    $events | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List | Out-String
}

Add-Section "Network connectivity to NDES (replace URL)" {
    "Test-NetConnection requires NDES URL — manual step required"
    "Run: Invoke-WebRequest -Uri '<NDES_URL>/certsrv/mscep/mscep.dll' -UseDefaultCredentials"
}

$output | Set-Content -Path $out -Encoding UTF8
Write-Host "Evidence saved to: $out" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| List device certs | `Get-ChildItem Cert:\LocalMachine\My \| Format-Table Subject, Issuer, NotAfter` |
| List user certs | `Get-ChildItem Cert:\CurrentUser\My \| Format-Table Subject, Issuer, NotAfter` |
| Check Root CA trust | `Get-ChildItem Cert:\LocalMachine\Root \| Where Subject -like "*<CA>*"` |
| Force Intune sync | `Invoke-CimMethod -Namespace root/cimv2/mdm/dmmap -Class MDM_DMClient -Method TriggerDMSession -Arguments @{ProviderID='MS DM Server'}` |
| View MDM event log | `Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 50` |
| Export MDM diagnostics | `MdmDiagnosticsTool.exe -out C:\Temp\MDMDiag` |
| Check NDES service (on NDES server) | `Get-Service mscep_admin, mscep \| Select Name, Status` |
| Ping CA from NDES | `certutil -ping` |
| Check NDES app pool | `Import-Module WebAdministration; Get-WebConfiguration .../applicationPools/add \| Where name -like "*NDES*"` |
| Check connector service | `Get-Service NDESConnectorSvc \| Select Name, Status, StartType` |
| View NTP status | `w32tm /query /status` |
| Force NTP sync | `w32tm /resync /force` |
| View cert template list on CA | `certutil -TCAInfo` |
| Check CRL distribution point | `certutil -URL <thumbprint>` |

---

## 🎓 Learning Pointers

- **SCEP challenge password lifetime is 60 minutes by default on NDES.** If a device is slow to check in or retries too late, the challenge expires and the request fails with event 24. This is particularly common after device reboots during OS updates. The password timeout is controlled by the registry key `HKLM\SOFTWARE\Microsoft\Cryptography\MSCEP\ChallengePasswordLifetime` (in minutes). [NDES configuration — Microsoft Docs](https://learn.microsoft.com/en-us/mem/intune/protect/certificates-scep-configure)

- **Subject name variables are case-sensitive and environment-specific.** `{{UserPrincipalName}}` works only for user-targeted profiles; `{{DeviceId}}` works only for device-targeted profiles. Using the wrong variable results in an empty subject and the CA rejecting the request. Always test with a single-device assignment before broad rollout. [Configure SCEP certificate profiles — Microsoft Docs](https://learn.microsoft.com/en-us/mem/intune/protect/certificates-profile-scep)

- **Trusted Certificate profiles must be assigned before SCEP/PKCS profiles are processed.** Intune sequences profile types internally, but if the device processes SCEP before the trusted cert arrives (race condition on first enrollment), the cert request will fail because the CA chain isn't trusted. Adding a 15-minute delay via an Enrollment Status Page (ESP) app-wait or simply re-syncing resolves this. [Certificate deployment sequencing](https://learn.microsoft.com/en-us/mem/intune/protect/certificates-configure)

- **PKCS certificates have the private key generated on-premises and delivered encrypted.** This means the CA can recover the private key — which is intentional for corporate email decryption scenarios but a risk for device authentication. If using device auth (Wi-Fi, VPN), prefer SCEP where the private key is generated on-device and never leaves. [Compare SCEP and PKCS — Microsoft Docs](https://learn.microsoft.com/en-us/mem/intune/protect/certificates-configure#compare-certificates-profile-types)

- **CRL (Certificate Revocation List) availability is often overlooked.** If the CRL Distribution Point (CDP) in the issued certificate points to an internal URL that devices can't reach (e.g., `ldap://internal-dc/...`), TLS handshakes and authentication may fail even with a valid certificate. Always include an HTTP-accessible CDP in your CA template and test it from non-domain devices. [Configure CDP — TechNet](https://learn.microsoft.com/en-us/windows-server/networking/core-network-guide/cncg/server-certs/configure-cdp-and-aia-extensions-on-ca1)

- **The Intune Certificate Connector logs everything.** `C:\ProgramData\Microsoft\Intune NDES Connector\Logs\NDESConnector.log` is verbose and includes every certificate request, success, and failure with timestamps. When escalating to Microsoft, always attach this log — it dramatically reduces back-and-forth. The log rotates automatically; there are typically 7 days of history.
