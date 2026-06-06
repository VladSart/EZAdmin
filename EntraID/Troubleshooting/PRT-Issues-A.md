# PRT Issues — Reference Runbook (Mode A: Deep Dive)
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

**What this covers:**
- Primary Refresh Token (PRT) acquisition failure on Hybrid Azure AD Joined and Azure AD Joined devices
- PRT refresh and rotation failures
- SSO breakage caused by missing or invalid PRT
- PRT issues on both domain-joined (hybrid) and cloud-only joined devices
- Windows 10 21H2+ and Windows 11

**What this does NOT cover:**
- Azure AD B2B/B2C PRT scenarios
- PRT on non-Windows platforms (see `macOS/` folder for macOS Kerberos SSO)
- ADFS-based PRT issuance (deprecated path)

**Required access:**
- Local admin on affected device
- Entra ID (Azure AD) Global Reader or above for sign-in log review
- Access to Microsoft Entra admin portal or Graph API

---

## How It Works

<details><summary>Full PRT architecture</summary>

### What is a PRT?

The **Primary Refresh Token** is a special JWT issued by Azure AD / Microsoft Entra ID to a device's **Cloud Authentication Provider (CloudAP)** plugin. It serves as a device-bound credential that enables seamless SSO across all Azure AD-integrated apps without re-prompting for MFA.

Key characteristics:
- Valid for **14 days**, renewed every time it's used (rolling window)
- Bound to the **device object** in Entra ID AND to the **user session** on that device
- Encrypted with a **Session Transport Key (STK)** stored in the device's **TPM** (if available) or DPAPI
- Contains a `DeviceId` claim and optionally an `MFA` claim

### PRT Issuance Flow (Azure AD Joined device)

```
User logs in (password / WHfB / SmartCard)
         │
         ▼
  CloudAP Plugin (lsass)
         │
         ├─► Checks device registration in Entra ID
         │      (device must be ✅ Enabled in portal)
         │
         ├─► Presents user credential + device certificate
         │      (device cert issued at AADJ/Hybrid join time)
         │
         ├─► POST to https://login.microsoftonline.com/<tenant>/oauth2/token
         │      grant_type=urn:ietf:params:oauth:grant-type:device_code
         │
         ▼
  Entra ID Token Endpoint
         │
         ├─► Validates device cert (from DRS)
         ├─► Validates user credential
         ├─► Checks CA policies (device compliance, MFA state)
         │
         ▼
  Issues PRT + Session Key
         │
         ▼
  CloudAP stores PRT in encrypted token cache
  STK sealed to TPM (or DPAPI if no TPM)
```

### PRT Refresh Flow

Every time a user accesses an Azure AD resource, the **WAM broker** (Windows Account Manager) presents the PRT to acquire access tokens:

```
App requests token (via MSAL / WAM)
         │
         ▼
  WAM Broker (runtimebroker.exe / svchost AAD)
         │
         ├─► Reads PRT from CloudAP cache
         ├─► Creates signed token request (signed with STK)
         │
         ▼
  Entra ID returns:
    - New Access Token (scoped to resource)
    - Refreshed PRT (if within refresh window)
    - New Session Key (if rotation triggered)
```

### Hybrid Azure AD Join — Additional Kerberos Layer

On **Hybrid AADJ** devices, PRT acquisition requires a valid Kerberos TGT from the on-premises DC first:

```
User logs in with AD credential
         │
         ▼
  LSASS obtains Kerberos TGT from DC
         │
         ▼
  CloudAP requests "Kerberos Cloud TGT" from DC
  (via AzureADKerberos / Azure AD Kerberos server object)
         │
         ▼
  CloudAP exchanges Kerberos cloud TGT for PRT
  (POST to login.microsoftonline.com)
```

This is why PRT fails on Hybrid devices when:
- The device can't reach the DC
- The AzureADKerberos server object is missing/unhealthy
- The Entra Connect sync has stale device objects

</details>

---

## Dependency Stack

```
┌─────────────────────────────────────────────────┐
│  App / Browser needing SSO token                │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│  WAM Broker (Windows Account Manager)           │
│  svchost -k AarSvc / runtimebroker.exe          │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│  CloudAP Plugin (lsass.exe)                     │
│  Stores PRT + Session Key                       │
└──────────┬───────────────────────────┬──────────┘
           │                           │
┌──────────▼──────────┐   ┌────────────▼──────────┐
│  TPM 2.0            │   │  Device Certificate   │
│  Seals Session Key  │   │  (from AADJ/Hybrid    │
│  (STK)              │   │   join operation)     │
└─────────────────────┘   └────────────┬──────────┘
                                       │
           ┌───────────────────────────▼──────────┐
           │  Network: HTTPS to                   │
           │  login.microsoftonline.com            │
           │  enterpriseregistration.windows.net  │
           └───────────────────────────┬──────────┘
                                       │
           ┌───────────────────────────▼──────────┐
           │  Entra ID Tenant                     │
           │  - Device object (Enabled)           │
           │  - User object (licensed)            │
           │  - CA policy evaluation              │
           └──────────────────────────────────────┘

  [Hybrid AADJ only — additional dependencies]
           ┌──────────────────────────────────────┐
           │  On-prem AD Domain Controller        │
           │  - Kerberos TGT issuance             │
           │  - AzureADKerberos server object     │
           └──────────────────────────────────────┘
           ┌──────────────────────────────────────┐
           │  Entra Connect Sync                  │
           │  - Device sync (hybrid join)         │
           │  - userCertificate attribute sync    │
           └──────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| `dsregcmd /status` shows `AzureAdPrt: NO` | Device cert expired or device disabled in Entra | Check `CertificateThumbprint` validity; check device in portal |
| `AzureAdPrt: NO` + `PrtUpdateTime` is stale (>14 days) | Network blocking login.microsoftonline.com | Test connectivity from device |
| `AzureAdPrt: YES` but SSO still fails | PRT has no MFA claim; CA requires MFA | Check `AzureAdPrtAuthority` and sign-in logs |
| `OnPremTgt: NO` on Hybrid device | AzureADKerberos server object missing or DC unreachable | `klist get krbtgt` then check DC event log |
| Frequent PRT re-prompts after password change | Old PRT not revoked; stale token cache | `dsregcmd /forcerecovery` or sign out/in |
| `AzureAdPrt: YES` but `AzureAdPrtUpdateTime` never refreshes | TPM malfunction preventing STK re-seal | `tpm.msc` → check TPM health; check event log |
| PRT error on shared/kiosk device | Device not AADJ or not in device-based CA scope | Confirm join type via `dsregcmd /status` |
| `DeviceAuthStatus: Failed` in sign-in logs | Device object disabled or deleted in Entra | Search device in Entra portal |
| `ErrorCode: 70011` in Entra sign-in logs | Invalid scope / unsupported grant during PRT exchange | Usually a WAM bug — check Windows Update status |
| Intune compliance blocks PRT-dependent apps | Device not compliant; CA blocks non-compliant | Intune portal → device compliance state |

---

## Validation Steps

**Step 1 — Check PRT state on the device**
```powershell
dsregcmd /status
```
Expected "good" output (Azure AD Joined):
```
AzureAdJoined : YES
EnterpriseJoined : NO
DomainJoined : NO
AzureAdPrt : YES
AzureAdPrtUpdateTime : <timestamp within last 14 days>
```
Expected "good" output (Hybrid Azure AD Joined):
```
AzureAdJoined : YES
DomainJoined : YES
AzureAdPrt : YES
OnPremTgt : YES
```
"Bad" looks like: `AzureAdPrt : NO`, missing `AzureAdPrtUpdateTime`, or `OnPremTgt : NO` on hybrid.

---

**Step 2 — Check device registration health**
```powershell
dsregcmd /status | Select-String -Pattern "AzureAd|Workplace|Domain|Prt|Device"
```
Look for: `DeviceAuthStatus`, `TenantId`, `DeviceId` — all should be populated.

---

**Step 3 — Verify device certificate**
```powershell
Get-ChildItem Cert:\LocalMachine\MY | Where-Object {$_.Issuer -like "*MS-Organization-Access*"} | 
    Select-Object Subject, Issuer, NotBefore, NotAfter, Thumbprint
```
Good: certificate present with `NotAfter` in the future.
Bad: no certificate, or certificate expired.

---

**Step 4 — Test network connectivity to Entra endpoints**
```powershell
$urls = @(
    "https://login.microsoftonline.com",
    "https://device.login.microsoftonline.com",
    "https://enterpriseregistration.windows.net",
    "https://enterpriseregistration.microsoftonline.com",
    "https://autologon.microsoftazuread-sso.com"
)
foreach ($url in $urls) {
    $result = Test-NetConnection -ComputerName ([System.Uri]$url).Host -Port 443
    [PSCustomObject]@{
        URL = $url
        TcpTestSucceeded = $result.TcpTestSucceeded
        RemoteAddress = $result.RemoteAddress
    }
}
```
Good: all `TcpTestSucceeded = True`.
Bad: any `False` — check proxy/firewall bypass rules for these FQDNs.

---

**Step 5 — Check AAD event log for PRT errors**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-AAD/Operational" -MaxEvents 50 |
    Where-Object { $_.LevelDisplayName -in "Error","Warning" } |
    Select-Object TimeCreated, Id, Message |
    Format-List
```
Key event IDs:
- **1098** — PRT acquisition error (message contains error code)
- **1104** — Device not found or disabled
- **1081** — Token request failed

---

**Step 6 — [Hybrid only] Verify AzureADKerberos server object**
```powershell
# Run on a DC or with RSAT
Get-ADObject -Filter {objectClass -eq "serviceConnectionPoint"} -SearchBase "CN=Services,CN=Configuration,DC=<domain>,DC=<tld>" -Properties * | 
    Where-Object {$_.Name -like "*AzureADKerberos*"}
```
Good: object present, `msDS-KeyVersionNumber` attribute populated.
Bad: missing object — need to re-run `Set-AzureADKerberosServer` from Entra Connect.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Quick Triage (run on affected device)

1. Run `dsregcmd /status` — capture full output
2. Check `AzureAdPrt` value and `AzureAdPrtUpdateTime`
3. Check `OnPremTgt` (hybrid only)
4. Check `DeviceAuthStatus`
5. Note the `TenantId` and `DeviceId` — you'll need these for portal lookups

### Phase 2 — Device Certificate Health

1. Check device cert in `Cert:\LocalMachine\MY` (Step 3 above)
2. If cert is expired: device must be re-joined to get a new cert issued
3. If cert is missing: check whether the join was completed — `dsregcmd /status` will show `AzureAdJoined: NO`
4. For hybrid: also check `Cert:\LocalMachine\MY` for the computer certificate issued by on-prem CA

### Phase 3 — Entra ID Portal Check

1. Navigate to **Entra admin center → Devices → All devices**
2. Search by `DeviceId` from `dsregcmd /status`
3. Verify device is **Enabled** (not disabled)
4. Check **Registered** date and **Last check-in** date
5. If device shows **Pending** state: Entra Connect hasn't synced the `userCertificate` attribute yet — wait for next sync cycle or force sync

### Phase 4 — Network Connectivity

1. Run Step 4 connectivity test above
2. If any endpoint fails, check:
   - Proxy bypass rules (these URLs must be excluded from SSL inspection)
   - Firewall outbound rules (port 443 to Azure)
   - DNS resolution for `login.microsoftonline.com`
3. Use `fiddler` or `netsh trace` to confirm TLS handshake completes successfully

### Phase 5 — Hybrid-Specific Issues

1. Verify DC reachability: `nltest /dsgetdc:<domain>`
2. Check Kerberos tickets: `klist` — should show TGT for AD domain
3. Verify AzureADKerberos server object exists (Step 6 above)
4. Check Entra Connect sync status — device object must be synced
5. Review Entra Connect sync errors for the specific device:
   ```powershell
   # Run on Entra Connect server
   Get-ADSyncCSObject -ConnectorName "<connector>" -DistinguishedName "<device DN>"
   ```

### Phase 6 — Force PRT Recovery

If device is healthy but PRT is stale/corrupted:
```powershell
# Option A: Force PRT recovery (runs as the affected user, not admin)
dsregcmd /forcerecovery

# Option B: Sign out and back in
# (triggers fresh PRT acquisition on next login)

# Option C: Clear AAD token cache (last resort, non-destructive)
# Run as the affected user in an elevated prompt:
$aadTokenPath = "$env:LOCALAPPDATA\Microsoft\TokenBroker\Cache"
if (Test-Path $aadTokenPath) {
    Remove-Item "$aadTokenPath\*" -Force -Recurse
    Write-Host "Token broker cache cleared. Sign out and back in."
}
```

---

## Remediation Playbooks

<details><summary>Playbook 1 — Re-enable a disabled device in Entra ID</summary>

**When to use:** Device shows `AzureAdPrt: NO` and portal shows device is **Disabled**.

```powershell
# Install module if not present
Install-Module Microsoft.Graph -Scope CurrentUser -Force

# Connect with device management permission
Connect-MgGraph -Scopes "Device.ReadWrite.All"

# Find device by DeviceId (from dsregcmd /status)
$deviceId = "<DeviceId-from-dsregcmd>"
$device = Get-MgDevice -Filter "deviceId eq '$deviceId'"

if ($device) {
    # Re-enable the device
    Update-MgDevice -DeviceId $device.Id -AccountEnabled $true
    Write-Host "Device $($device.DisplayName) re-enabled." -ForegroundColor Green
    
    # Verify
    Get-MgDevice -DeviceId $device.Id | Select-Object DisplayName, AccountEnabled, ApproximateLastSignInDateTime
} else {
    Write-Warning "Device not found. Check DeviceId: $deviceId"
}
```

**After re-enabling:** User must sign out and back in on the device to acquire fresh PRT. Allow 5-10 minutes.

**Rollback:** Run `Update-MgDevice -DeviceId $device.Id -AccountEnabled $false` to re-disable.

</details>

<details><summary>Playbook 2 — Rejoin an Azure AD Joined device</summary>

**When to use:** Device certificate is missing or expired, and `dsregcmd /status` shows `AzureAdJoined: NO` or device cert is expired.

**Impact:** Local user profiles remain. User data is preserved. Apps may need to re-authenticate.

```powershell
# Step 1: Leave Entra ID join (run as local admin)
dsregcmd /leave

# Step 2: Verify leave was successful
dsregcmd /status | Select-String "AzureAdJoined"
# Expected: AzureAdJoined : NO

# Step 3: Rejoin — method depends on provisioning approach:

# Method A: Via Settings (interactive)
# Settings > Accounts > Access work or school > Connect > Join this device to Azure Active Directory

# Method B: Via Autopilot re-enrollment (if device is in Autopilot)
# See Autopilot/Troubleshooting/ runbooks

# Method C: Via Intune enrollment reset
# Intune portal > Device > Wipe (if data loss acceptable) OR
# Retire > Re-enroll

# Step 4: After rejoin, verify PRT
dsregcmd /status | Select-String "AzureAdPrt|AzureAdJoined"
```

**Rollback note:** A leave/rejoin generates a **new device object** in Entra ID. The old disabled object can be deleted from the portal after confirming the new join is healthy.

</details>

<details><summary>Playbook 3 — Fix AzureADKerberos server object for Hybrid PRT</summary>

**When to use:** Hybrid AADJ devices show `OnPremTgt: NO` and PRT is failing.

**Requirements:** Domain Admin + Global Admin, run from Entra Connect server or DC.

```powershell
# Install Azure AD Kerberos module (on DC or Entra Connect server)
Install-Module -Name AzureADHybridAuthenticationManagement -Force

# Connect to Azure AD
Connect-AzureAD

# Check if AzureAD Kerberos server exists
Get-AzureADKerberosServer -Domain <domain.com> -CloudCredential (Get-Credential) -DomainCredential (Get-Credential)

# If missing or unhealthy, recreate:
Set-AzureADKerberosServer -Domain <domain.com> `
    -CloudCredential (Get-Credential) `
    -DomainCredential (Get-Credential)

# Verify the server object
Get-AzureADKerberosServer -Domain <domain.com> -CloudCredential (Get-Credential) -DomainCredential (Get-Credential) |
    Select-Object Id, DomainDnsName, KeyVersion, KeyUpdatedOn, KeyUpdatedFrom
```

**After fixing:** Allow Entra Connect to complete a sync cycle (up to 30 mins). Then test on an affected device with `dsregcmd /forcerecovery`.

**Rollback:** The `Set-AzureADKerberosServer` command is non-destructive — it updates the existing object if present, creates it if absent.

</details>

<details><summary>Playbook 4 — Diagnose PRT MFA claim absence</summary>

**When to use:** `AzureAdPrt: YES` but apps still prompt for MFA; CA policy requires MFA claim in PRT.

PRT acquires an MFA claim only if the user performed MFA **during the login that produced the PRT**. If the user used a non-MFA method (e.g. password only) the PRT won't carry an MFA claim.

```powershell
# Check if WHfB or FIDO2 is configured (these produce MFA-claim PRT automatically)
dsregcmd /status | Select-String "NgcSet|Fido"

# Check sign-in log in Entra portal:
# Entra admin center > Users > Sign-in logs
# Filter: Device ID = <from dsregcmd> + Authentication method

# If PRT lacks MFA claim, user must re-authenticate with MFA:
# Option A: Lock screen + unlock with WHfB or FIDO2 (generates MFA-claim PRT)
# Option B: Sign out fully, sign back in with MFA-capable method
# Option C: Enroll in WHfB (persistent fix — every WHfB login produces MFA-claim PRT)
```

**Long-term fix:** Deploy Windows Hello for Business. Every WHfB authentication produces a PRT with the MFA claim automatically — eliminates per-session MFA prompts for CA policies. See `EntraID/Troubleshooting/WHfB-A.md`.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS   Collects PRT diagnostic evidence for escalation.
.NOTES      Run as the AFFECTED USER (not as admin) for accurate PRT/token results.
            Run on the affected device.
#>

$outputDir = "$env:TEMP\PRT-Evidence-$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# 1. Full dsregcmd output
dsregcmd /status > "$outputDir\dsregcmd-status.txt" 2>&1
dsregcmd /status /debug > "$outputDir\dsregcmd-debug.txt" 2>&1

# 2. Device certificate
Get-ChildItem Cert:\LocalMachine\MY | 
    Select-Object Subject, Issuer, NotBefore, NotAfter, Thumbprint |
    Export-Csv "$outputDir\device-certs.csv" -NoTypeInformation

# 3. AAD operational log (last 100 events)
Get-WinEvent -LogName "Microsoft-Windows-AAD/Operational" -MaxEvents 100 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$outputDir\aad-events.csv" -NoTypeInformation

# 4. Network connectivity
$urls = @(
    "login.microsoftonline.com",
    "device.login.microsoftonline.com",
    "enterpriseregistration.windows.net",
    "enterpriseregistration.microsoftonline.com"
)
$netResults = foreach ($host in $urls) {
    $r = Test-NetConnection -ComputerName $host -Port 443
    [PSCustomObject]@{ Host = $host; TcpTest = $r.TcpTestSucceeded; IP = $r.RemoteAddress }
}
$netResults | Export-Csv "$outputDir\network-test.csv" -NoTypeInformation

# 5. TPM status
Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, TpmActivated, ManagedAuthLevel |
    Export-Csv "$outputDir\tpm-status.csv" -NoTypeInformation

# 6. System info
Get-ComputerInfo | Select-Object CsName, WindowsVersion, OsVersion, OsBuildNumber |
    Export-Csv "$outputDir\system-info.csv" -NoTypeInformation

# 7. Kerberos tickets (hybrid only)
klist > "$outputDir\klist-output.txt" 2>&1

Write-Host "`n✅ Evidence collected to: $outputDir" -ForegroundColor Green
Write-Host "Zip and attach to ticket: Compress-Archive '$outputDir' '$env:TEMP\PRT-Evidence.zip'" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Full PRT status | `dsregcmd /status` |
| Force PRT recovery | `dsregcmd /forcerecovery` |
| Leave Entra ID join | `dsregcmd /leave` |
| Debug PRT acquisition | `dsregcmd /status /debug` |
| List device certs | `Get-ChildItem Cert:\LocalMachine\MY` |
| Check AAD event log | `Get-WinEvent -LogName "Microsoft-Windows-AAD/Operational" -MaxEvents 50` |
| Test Entra endpoints | `Test-NetConnection -ComputerName login.microsoftonline.com -Port 443` |
| Check Kerberos tickets | `klist` |
| Check DC reachability | `nltest /dsgetdc:<domain>` |
| Clear token broker cache | `Remove-Item "$env:LOCALAPPDATA\Microsoft\TokenBroker\Cache\*" -Force -Recurse` |
| Get device from Graph | `Get-MgDevice -Filter "deviceId eq '<id>'"` |
| Re-enable device in Entra | `Update-MgDevice -DeviceId <id> -AccountEnabled $true` |
| Check TPM health | `Get-Tpm` |
| Check AzureAD Kerberos | `Get-AzureADKerberosServer -Domain <domain>` |

---

## 🎓 Learning Pointers

- **PRT is per-device AND per-user.** Each user signed into a device has their own PRT. When troubleshooting, always run diagnostics as the **affected user**, not as admin — `dsregcmd /status` reflects the calling user's PRT state.

- **TPM binding is security-critical.** When a TPM is present, the Session Transport Key (STK) is sealed to the TPM. This prevents PRT theft via token cache extraction. If TPM health is degraded, PRT acquisition may silently fail even with valid credentials. Always check `Get-Tpm` during escalation.

- **The "Pending" device state is a common Hybrid AADJ trap.** A device shows as "Pending" in Entra when the device object exists on-prem but Entra Connect hasn't synced the `userCertificate` attribute yet — usually because the on-prem CA hasn't issued the computer certificate, or the sync schedule hasn't run. See [Hybrid Azure AD join controlled validation](https://learn.microsoft.com/en-us/entra/identity/devices/hybrid-join-control).

- **PRT MFA claims don't auto-upgrade.** If a user's PRT was issued via password-only auth, CA policies requiring `mfa` claims will continue to fail until the user re-authenticates with MFA. Windows Hello for Business is the clean fix because every WHfB sign-in produces an MFA-claim PRT. See [Microsoft Docs — PRT and MFA](https://learn.microsoft.com/en-us/entra/identity/devices/concept-primary-refresh-token).

- **AzureADKerberos is the linchpin of Hybrid PRT.** It's the on-prem "Azure AD Kerberos server" object that enables the Kerberos-to-PRT exchange. If it's missing, corrupt, or its key version is out of date, every Hybrid AADJ device in the domain will fail PRT acquisition silently. Rotate the server key annually or when the on-prem account password changes. See [Configure Azure AD Kerberos](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-authentication-passwordless-security-key-on-premises).

- **Sign-in logs are your ground truth.** `dsregcmd /status` tells you the device's view; Entra sign-in logs tell you Entra's view. When they disagree (device says PRT YES, apps still fail), the sign-in log error code is authoritative. Filter by DeviceId and look for `DeviceAuthStatus: Failed` entries. See [Entra sign-in log analysis](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-ins).
