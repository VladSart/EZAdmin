# Intune Certificate Deployment — Hotfix Runbook (Mode B: Ops)
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

Run these within 60 seconds to identify the failure layer:

```powershell
# 1. Check NDES/SCEP connector service status on the NDES server
Get-Service -Name NDESConnector -ComputerName <NDESServer> | Select-Object Name, Status

# 2. Check Intune Certificate Connector health (run on connector server)
Get-EventLog -LogName "Application" -Source "Microsoft Intune" -Newest 20 | Select-Object TimeGenerated, EntryType, Message

# 3. Check PKCS connector / Intune Certificate Connector v2
Get-Service -Name "PFXCertificateConnectorSvc" -ComputerName <ConnectorServer> | Select-Object Name, Status

# 4. Check device certificate state via Intune Graph
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" | Select-Object Id, DeviceName, ComplianceState

# 5. Check Entra ID / AAD device object certificate attributes
dsregcmd /status | Select-String -Pattern "Certificate|Cert"
```

| Result | Interpretation | Action |
|--------|----------------|--------|
| NDESConnector = Stopped | NDES connector down | → Fix 1: Restart NDES Connector |
| PFXCertificateConnectorSvc = Stopped | PKCS connector down | → Fix 2: Restart PKCS Connector |
| Event 30 / 31 errors in Application log | NDES policy module failure | → Fix 3: Check IIS/NDES config |
| Device shows "Not enrolled" in Intune | Enrollment issue, not cert issue | → Check Enrollment-B.md |
| dsregcmd shows no cert | Device-level cert missing | → Fix 4: Force device re-enroll |
| "Failed" state in Intune cert profile | Profile delivery issue | → Fix 5: Re-push cert profile |

---
## Dependency Cascade

<details><summary>What must be true for certificate delivery to succeed</summary>

```
Intune Service (cloud)
    │
    ├── Intune Certificate Connector (on-prem server)
    │       ├── Installed and running (v6.x+ for PKCS; NDES Connector for SCEP)
    │       ├── Service account has "Log on as service" right
    │       ├── Service account enrolled with client cert for auth to Intune
    │       └── Network: outbound HTTPS to *.manage.microsoft.com / manage.microsoft.com
    │
    ├── NDES Role (for SCEP only)
    │       ├── IIS running on NDES server
    │       ├── NDES service account has Read on CA template
    │       ├── MSCEP_ADMIN_PASSWORD correct
    │       └── URL reachable from devices: https://<NDESServer>/certsrv/mscep/mscep.dll
    │
    ├── Certificate Authority (on-prem or ADCS)
    │       ├── CA service running (certsvc)
    │       ├── Certificate template published and enabled
    │       ├── Template allows autoenroll for NDES/connector service account
    │       └── CA CRL published and accessible
    │
    ├── Device (Entra/Intune enrolled)
    │       ├── Device enrolled and in correct Entra group
    │       ├── Certificate profile assigned to device/user group
    │       ├── Device has line-of-sight to NDES URL (for SCEP)
    │       └── Time sync correct (cert validity window)
    │
    └── Certificate Profile in Intune
            ├── SCEP or PKCS profile type configured correctly
            ├── Root/Trusted cert profile deployed BEFORE SCEP/PKCS profile
            ├── Subject name format matches directory attributes
            └── SAN (Subject Alternative Name) configured if required
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the certificate type in use**
```powershell
# On the affected device, check what certs exist
Get-ChildItem -Path Cert:\LocalMachine\My | Select-Object Subject, Issuer, NotAfter, Thumbprint
Get-ChildItem -Path Cert:\CurrentUser\My | Select-Object Subject, Issuer, NotAfter, Thumbprint
```
- Expected: Certificate from your CA with correct Subject/SAN
- Bad: No certificate, or certificate issued by wrong CA, or expired

**Step 2 — Check Intune device certificate report**
In Intune portal: Devices → [Device] → Monitor → Certificate details
- Expected: Profile status = "Succeeded"
- Bad: "Failed", "Pending", or "Not applicable"

**Step 3 — Check connector server event logs**

For SCEP (NDESConnector):
```powershell
Get-WinEvent -ComputerName <NDESServer> -LogName "Microsoft-Windows-NDES*" -MaxEvents 50 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List
```

For PKCS (Intune Certificate Connector v2):
```powershell
Get-WinEvent -ComputerName <ConnectorServer> -LogName "Application" -MaxEvents 50 |
    Where-Object { $_.ProviderName -like "*Intune*" -or $_.ProviderName -like "*PFX*" } |
    Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List
```
- Expected: Info events showing successful certificate issuance requests
- Bad: Error events with "Unable to connect to CA", "Template not found", "Access denied"

**Step 4 — Test NDES URL reachability (SCEP only)**
```powershell
# Run from the AFFECTED DEVICE or a machine in same network segment
$url = "https://<NDESServer>/certsrv/mscep/mscep.dll"
try {
    $resp = Invoke-WebRequest -Uri $url -UseDefaultCredentials -TimeoutSec 10
    Write-Host "HTTP $($resp.StatusCode) — NDES reachable" -ForegroundColor Green
} catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
}
```
- Expected: HTTP 200 or 403 (403 is normal — means NDES is up but rejecting unauthenticated)
- Bad: Timeout, connection refused, or HTTP 500

**Step 5 — Verify CA template permissions**
```powershell
# On the CA server or a machine with RSAT
$template = "<YourTemplateName>"
certutil -v -dstemplate $template | Select-String -Pattern "pKIExtendedKeyUsage|msPKI-Enrollment-Flag"
# Also check ACL — NDES service account needs Read + Enroll
```

---
## Common Fix Paths

<details><summary>Fix 1 — NDES Connector service stopped/crashing</summary>

**Applies to:** SCEP deployments using the legacy NDESConnector

```powershell
# On the NDES server
$server = "<NDESServer>"

# Restart the connector
Invoke-Command -ComputerName $server -ScriptBlock {
    Restart-Service -Name "NDESConnector" -Force
    Start-Sleep -Seconds 5
    Get-Service -Name "NDESConnector" | Select-Object Name, Status, StartType
}

# Check for crash in Windows Event Log
Get-WinEvent -ComputerName $server -LogName "Application" -MaxEvents 30 |
    Where-Object { $_.LevelDisplayName -eq "Error" -and $_.TimeCreated -gt (Get-Date).AddHours(-1) } |
    Select-Object TimeCreated, Message | Format-List
```

If service won't start: Check the service account password hasn't expired, and that the account still has "Log on as a service" right (secpol.msc → Local Policies → User Rights Assignment).

**Rollback:** Not applicable (restarting a service is non-destructive).

</details>

<details><summary>Fix 2 — PKCS connector (Intune Certificate Connector v2) stopped</summary>

**Applies to:** PKCS certificate deployments (connector version 6.x)

```powershell
$server = "<ConnectorServer>"

Invoke-Command -ComputerName $server -ScriptBlock {
    # List all Intune/PFX related services
    Get-Service | Where-Object { $_.Name -like "*PFX*" -or $_.Name -like "*Intune*" } |
        Select-Object Name, Status, StartType

    # Restart the PFX connector service
    Restart-Service -Name "PFXCertificateConnectorSvc" -Force
    Start-Sleep -Seconds 5
    Get-Service -Name "PFXCertificateConnectorSvc" | Select-Object Name, Status
}

# Verify connector shows as Active in Intune portal:
# Tenant Admin → Connectors and tokens → Certificate connectors
```

If connector shows "Error" in portal after restart, the service account certificate used to authenticate to Intune may have expired. Re-run the connector installer to re-enroll the service account cert.

**Rollback:** Non-destructive restart.

</details>

<details><summary>Fix 3 — NDES IIS / policy module errors (HTTP 500 or Event ID 30)</summary>

**Applies to:** SCEP — NDES returning 500 errors or Event ID 30 in Application log

```powershell
# On the NDES server — check IIS application pool
Invoke-Command -ComputerName <NDESServer> -ScriptBlock {
    Import-Module WebAdministration
    
    # Check SCEP app pool state
    $pool = Get-WebConfiguration -Filter "system.applicationHost/applicationPools/add[@name='SCEP']"
    Write-Host "SCEP pool state: $($pool.state)"
    
    # Restart if stopped
    if ($pool.state -ne "Started") {
        Start-WebAppPool -Name "SCEP"
        Write-Host "App pool started" -ForegroundColor Green
    }
    
    # Check NDES challenge password expiry (default 1 hour)
    $reg = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography\MSCEP" -ErrorAction SilentlyContinue
    Write-Host "MSCEP password cache timeout: $($reg.PasswordCacheExpireTime) seconds"
}

# Verify NDES registry settings
Invoke-Command -ComputerName <NDESServer> -ScriptBlock {
    $mscep = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Cryptography\MSCEP"
    [PSCustomObject]@{
        EncryptionTemplate   = $mscep.EncryptionTemplate
        GeneralPurposeTemplate = $mscep.GeneralPurposeTemplate
        SignatureTemplate    = $mscep.SignatureTemplate
    }
}
```

If template names don't match what's published in CA, update the registry values to match exactly.

**Rollback:** Registry change — note original values before editing.

</details>

<details><summary>Fix 4 — Device not receiving certificate (SCEP profile "Pending")</summary>

**Applies to:** Device enrolled, profile assigned, but cert never arrives

```powershell
# Force Intune sync on device (run locally on device or via remote PS)
# Method 1: Trigger via Intune portal — Devices → [Device] → Sync

# Method 2: PowerShell on device
$enrollmentPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
$accounts = Get-ChildItem -Path $enrollmentPath
foreach ($acct in $accounts) {
    $val = Get-ItemProperty -Path $acct.PSPath -ErrorAction SilentlyContinue
    if ($val.ProviderID -eq "MS DM Server") {
        Write-Host "Found MDM enrollment: $($acct.Name)"
    }
}

# Trigger sync via scheduled task
Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" |
    Where-Object { $_.TaskName -like "*Schedule*" } |
    Start-ScheduledTask

# Also try: deviceenroller.exe /o <EnrollmentID> /c /h /b MOBILEPROVISIONINGURL
```

Wait 5-10 minutes after sync. If still not delivered:
1. Remove device from cert profile assignment group
2. Wait 10 minutes
3. Re-add device to group
4. Force sync again

**Rollback:** Re-add device to group if accidentally removed.

</details>

<details><summary>Fix 5 — Certificate profile shows "Failed" — subject name attribute error</summary>

**Applies to:** SCEP/PKCS profile fails with "Failed to build certificate request" or attribute errors

```powershell
# Check if the required directory attributes are populated on the user/device object
Connect-MgGraph -Scopes "User.Read.All", "Device.Read.All"

$upn = "<UserUPN>"
$user = Get-MgUser -Filter "userPrincipalName eq '$upn'" -Property "DisplayName,UserPrincipalName,Department,JobTitle,Mail,OnPremisesSamAccountName"

$user | Select-Object DisplayName, UserPrincipalName, Department, JobTitle, Mail, OnPremisesSamAccountName
```

Common causes:
- Subject name format uses `{{UserPrincipalName}}` but user UPN is null
- SAN format uses `{{EmailAddress}}` but Mail attribute is empty
- Device profile uses `{{AADDeviceId}}` — check device is Entra joined

Fix: Either populate the missing directory attribute via AD/Entra, or change the certificate profile Subject/SAN format to use an attribute that IS populated.

**Rollback:** Reverting cert profile Subject name format is safe — devices will request new certs with updated format on next sync.

</details>

---
## Escalation Evidence

Copy and fill before raising with Microsoft or senior engineer:

```
CERTIFICATE DEPLOYMENT ESCALATION
==================================
Ticket/Ref:
Date/Time of issue:
Environment:
  Cert type (SCEP / PKCS):
  Connector version:
  Connector server OS:
  CA type (ADCS / Cloud):
  Device platform (Windows / iOS / Android / macOS):

Symptom:
  Intune profile status:                [ Succeeded / Failed / Pending / Not applicable ]
  Error message in Intune portal:
  Event ID(s) on connector server:
  Error message text:

Connector server:
  NDESConnector / PFXCertConnector service status:
  Last successful certificate issuance:
  Connector last check-in to Intune:

Affected scope:
  Number of affected devices:
  Is it ALL devices or specific group:
  Works on some platforms but not others: [ Y / N ]
  
Recent changes (last 7 days):
  Connector upgraded:  [ Y / N ]
  Certificate template modified:  [ Y / N ]
  Service account password changed:  [ Y / N ]
  CA CRL updated/expired:  [ Y / N ]

Logs attached:
  [ ] Application event log from connector server (last 24h)
  [ ] NDES IIS logs (for SCEP)
  [ ] Intune device diagnostics (MDMDiagReport)
  [ ] certutil output for CA template
```

---
## 🎓 Learning Pointers

- **SCEP vs PKCS:** SCEP is request-based (device generates key pair, submits CSR to NDES); PKCS is delivery-based (Intune/CA generates cert and pushes it). SCEP requires NDES role on-prem; PKCS only needs the Intune Certificate Connector v2. See: [Intune SCEP overview](https://learn.microsoft.com/en-us/mem/intune/protect/certificates-scep-configure)
- **Root cert profile must deploy first:** If the Trusted Certificate profile hasn't landed on the device, SCEP/PKCS will always fail. Intune does enforce ordering, but check compliance policies aren't blocking the device before the root arrives.
- **Connector service account cert expiry:** The connector service account enrolls a client certificate to authenticate to Intune. This cert has a validity period (typically 1-2 years). When it expires, all certificate deliveries silently stop. Monitor this proactively. See: [Intune Certificate Connector](https://learn.microsoft.com/en-us/mem/intune/protect/certificate-connector-overview)
- **CRL availability:** If your CA's Certificate Revocation List (CRL) is unreachable from internet-based devices, SCEP will fail for those devices. Consider enabling OCSP or configuring CRL Distribution Points accessible externally.
- **NDES challenge password is one-time-use:** The MSCEP challenge password is consumed after one SCEP request. If a device retries with the same challenge, it will fail. This is by design — retry the sync to get a fresh challenge.
- **Event IDs to know:** NDES Event 30 = CA unreachable; Event 31 = template error; Event 32 = password error. Intune Connector events in Application log under "Microsoft Intune" or "NDESConnector" source. See: [NDES event reference](https://learn.microsoft.com/en-us/troubleshoot/mem/intune/certificates/troubleshoot-scep-certificate-profiles)
