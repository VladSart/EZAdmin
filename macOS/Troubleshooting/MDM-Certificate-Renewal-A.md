# macOS MDM Certificate Renewal — Reference Runbook (Mode A: Deep Dive)
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
- **Scope:** MDM enrollment certificate lifecycle on macOS devices managed via Microsoft Intune (or any MDM using APNs)
- **MDM stack:** Apple Push Notification service (APNs) certificate on the MDM server side + device-side MDM enrollment certificate (identity certificate)
- **Two distinct certificates:** (1) APNs certificate held by Intune/MDM server (renewed annually in Apple Push Certificates Portal); (2) device MDM identity certificate issued at enrollment, typically renewed automatically
- **macOS versions:** Applicable to macOS 12 Monterey through macOS 15 Sequoia. ADE/DEP behaviour referenced.
- **Admin access:** Server-side APNs renewal requires Apple ID used for original APNs request + Intune/MDM admin role. Device-side operations may require local admin.

---
## How It Works

<details><summary>Full architecture</summary>

### Certificate 1: APNs Certificate (MDM Server → Apple)

The APNs certificate is what allows Microsoft Intune (or any MDM) to send push notifications to Apple devices, triggering MDM check-ins. Without a valid APNs cert, Intune cannot push policies, apps, or commands to any managed Apple device.

```
Microsoft Intune (MDM Server)
        │
        │  Uses APNs cert (issued by Apple)
        ▼
Apple Push Notification Service (APNs)
        │
        │  Push notification to device (via APNS token)
        ▼
macOS device (mdmclient daemon)
        │
        ▼
Device checks in with Intune → receives policies, profiles, commands
```

**APNs certificate facts:**
- Issued by Apple to the MDM vendor for a specific MDM server instance
- Valid for **1 year** from issuance — no auto-renewal
- Tied to the Apple ID used to create it — renewal MUST use the same Apple ID
- If APNs cert expires: ALL managed Apple devices lose MDM connectivity simultaneously
- Renewal preserves the APNS topic (unique identifier) so devices don't need re-enrollment
- Renewable up to 30 days early in Apple Push Certificates Portal

**APNs renewal flow:**
```
1. Intune admin downloads CSR from Intune portal
2. Uploads CSR to Apple Push Certificates Portal (appleid.apple.com)
3. Apple issues new APNs cert (.pem)
4. Admin uploads .pem back to Intune portal
5. Intune uses new cert for all subsequent pushes
```

### Certificate 2: Device MDM Enrollment Identity Certificate

Each enrolled device has a unique X.509 identity certificate issued at enrollment time. This certificate:
- Authenticates the device to the MDM server during check-in
- Is stored in the System keychain: `login.keychain` → `System` keychain or within the MDM profile
- Typically valid for 1-2 years; auto-renewed by mdmclient before expiry
- Lives inside the MDM enrollment profile (`MDM Profile` in System Preferences → Privacy & Security → Profiles)

```
Device enrolled → MDM pushes identity cert (via SCEP or manual provisioning)
        │
        ▼
Cert stored in System Keychain
        │
        ▼
mdmclient uses cert to authenticate each MDM check-in (TLS mutual auth)
        │
        ▼
Cert expires → auto-renewal attempted 30 days before expiry
        │
        ├─ Auto-renewal success → transparent to user
        └─ Auto-renewal failure → device loses MDM connectivity; re-enrollment required
```

</details>

---
## Dependency Stack

```
Apple Push Certificates Portal (Apple ID — annual renewal)
          │
          ▼
APNs Certificate in Intune
(Microsoft Intune > Devices > iOS/macOS > Apple MDM Push Certificate)
          │
          ▼
Apple Push Notification Service (APNs)
(gateway.push.apple.com:2195 / api.push.apple.com:443)
          │
          ▼
mdmclient (macOS daemon — /usr/libexec/mdmclient)
          │
          ├─ Network: device must reach *.push.apple.com, *.manage.microsoft.com
          ├─ System keychain: MDM enrollment identity certificate
          └─ MDM enrollment profile (System Preferences > Privacy & Security > Profiles)
                    │
                    ▼
          Intune MDM Server
          (*.manage.microsoft.com, EnrollmentServer URL in MDM profile)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| All macOS/iOS devices stop receiving policies simultaneously | APNs cert expired | Intune portal → Devices → macOS → Apple MDM Push Certificate → expiry date |
| Intune shows device as "Not checked in" for 7+ days (macOS) | APNs cert expired OR device network issues | Check APNs cert first; then device-side network |
| "Your MDM certificate has expired" alert on device | Device-side enrollment identity cert expired | `security find-certificate -a -Z /Library/Keychains/System.keychain` |
| Device checks in manually but not on schedule | mdmclient daemon issue, or APNs push failing | `sudo mdmclient CheckIn` — if succeeds, APNs push path is broken |
| MDM profile shows as "Expired" in System Settings > Profiles | Enrollment profile expired | Re-enroll device |
| Renewal fails with "Apple ID mismatch" in portal | Different Apple ID used for renewal vs original | Must use exact same Apple ID as original APNs request |
| Device re-enrolled after APNs cert renewal but apps missing | Device treated as new enrollment — need time for re-deploy | Wait for Intune sync; check app assignment targeting |
| APNs cert renewed but devices still not receiving pushes | Old cert not fully replaced, or Intune caching issue | Sign out of Intune portal session, clear browser cache, re-verify |

---
## Validation Steps

**1. Check APNs certificate expiry in Intune**
```bash
# Via browser: Intune admin center → Devices → macOS → Apple MDM Push Certificate
# Check the "Expiration" date shown on the certificate card
# Alert: renew 30 days early — Apple only allows renewal up to 30 days ahead
```

**2. Verify APNs connectivity from a managed Mac**
```bash
# Test APNs gateway connectivity
nc -zv gateway.push.apple.com 2195
nc -zv api.push.apple.com 443

# Test Intune management endpoints
nc -zv *.manage.microsoft.com 443  # Use specific FQDNs from MS Docs
curl -I https://EnterpriseEnrollment.manage.microsoft.com
```
Expected: Connection succeeds (exit 0)  
Bad: Connection refused/timeout → firewall blocking APNs or Intune endpoints

**3. Trigger manual MDM check-in on device**
```bash
sudo mdmclient CheckIn
```
Expected: Check-in succeeds with no errors  
Bad: `Error: The MDM server rejected the request` → enrollment cert or APNs issue

**4. View MDM enrollment profile on device**
```bash
# List all profiles
sudo profiles list -verbose

# Show MDM-specific profiles
sudo profiles show -type enrollment
```
Expected: MDM profile present with valid PayloadOrganization and no expiry warning  
Bad: No MDM profile → device not enrolled, or profile removed

**5. Inspect device identity certificate in System keychain**
```bash
# List all certs in System keychain
security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null | grep -A3 "MDM\|Intune\|Management"

# Check cert expiry
security find-certificate -a -c "MDM" /Library/Keychains/System.keychain -p | openssl x509 -noout -dates
```
Expected: `notAfter` date is in the future  
Bad: `notAfter` is past → re-enrollment required

**6. Review mdmclient log for errors**
```bash
log show --predicate 'process == "mdmclient"' --last 1h --info | grep -i "error\|fail\|cert\|expire"
```
Expected: No certificate or connection errors  
Bad: `Error validating device identity` → identity cert issue

---
## Troubleshooting Steps (by phase)

### Phase 1: Diagnosing APNs Certificate Expiry
1. Log into [Intune admin center](https://intune.microsoft.com) → **Devices** → **macOS** → **Apple MDM Push Certificate**
2. Note the expiry date. If expired or within 30 days → renew immediately
3. Gather the original Apple ID used — check with the IT admin who set up MDM
4. If Apple ID owner has left org: contact Apple Business/School Manager support — Apple ID transfer is not self-service
5. Export the current APNs cert info (APNS topic) for reference before renewal

### Phase 2: Renewing the APNs Certificate
1. In Intune: **Devices** → **macOS** → **Apple MDM Push Certificate** → **Configure**
2. Download the CSR (`.pem` file)
3. Navigate to [Apple Push Certificates Portal](https://identity.apple.com/pushcert/)
4. Sign in with the **exact same Apple ID** used originally — any deviation creates a NEW topic which requires all devices to re-enroll
5. Find the existing certificate for your MDM vendor → click **Renew** (NOT Create)
6. Upload the CSR → download the renewed `.pem`
7. Back in Intune: upload the `.pem` → save
8. Verify the expiry date updated and the APNS topic (UID) matches the previous cert

### Phase 3: Device Not Checking In After APNs Renewal
1. Wait 15-30 minutes — renewed cert propagation takes time
2. On a test device: `sudo mdmclient CheckIn`
3. If check-in fails: verify the device still has its enrollment profile (`sudo profiles list`)
4. If profile missing → device needs re-enrollment (ADE: wipe and re-deploy; non-ADE: manual enrollment)
5. For persistent check-in issues: restart mdmclient — `sudo launchctl kickstart -k system/com.apple.mdmclient`

### Phase 4: Device-Side Enrollment Certificate Expired
1. Confirm cert expiry: `security find-certificate -a -c "MDM" /Library/Keychains/System.keychain -p | openssl x509 -noout -dates`
2. Attempt forced check-in: `sudo mdmclient CheckIn` — if auth fails, cert is the issue
3. For Intune: if auto-renewal failed, the only resolution is re-enrollment
4. For ADE devices: wipe via Erase All Content and Settings → device auto-re-enrolls
5. For non-ADE devices: user must enroll manually via Company Portal or enrollment URL
6. Check Intune for the re-enrolled device — may appear as new device entry

---
## Remediation Playbooks

<details><summary>Playbook 1 — Emergency APNs certificate renewal</summary>

**Scenario:** APNs cert expired or within 7 days of expiry.

1. Identify the Apple ID that owns the APNs certificate (check original MDM setup records)
2. In Intune admin center: **Devices** → **macOS** → **Apple MDM Push Certificate** → **Configure**
3. Download the new CSR
4. Log in to Apple Push Certificates Portal with the **original Apple ID**
5. Renew (not create) the existing certificate
6. Upload the renewed `.pem` to Intune

```bash
# Verify APNS topic matches pre-renewal (run before and after)
# In Intune portal: note the "Apple ID" and "Expiration" fields
# Topic (UID in the cert) must stay the same — if it changes, all devices need re-enrollment
openssl x509 -in ApnsCert.pem -noout -subject | grep -o 'UID=[^/]*'
```

**Validation:** Check Intune for device last-check-in timestamps — should update within 1 hour of renewal.

**Rollback:** Not applicable. If wrong Apple ID was used and APNS topic changed, all devices require re-enrollment.

</details>

<details><summary>Playbook 2 — Force re-enrollment for a single device (non-ADE)</summary>

**Scenario:** Device-side enrollment cert expired; device not ADE-registered.

```bash
# Step 1: Remove existing MDM enrollment profile (device-side)
sudo profiles remove -forced -identifier "com.microsoft.intune.mdm"
# Or remove all management profiles:
sudo profiles remove -forced -type enrollment

# Step 2: Clear cached MDM data
sudo rm -rf /Library/Application\ Support/com.apple.TCC/
# Note: this removes TCC approvals — apps will re-prompt for permissions

# Step 3: Verify profiles removed
sudo profiles list

# Step 4: Re-enroll
# ADE: wipe device — Settings > General > Transfer or Reset iPhone/Mac > Erase All Content
# Non-ADE: open Company Portal and sign in, or navigate to enrollment URL
open "https://portal.manage.microsoft.com/EnrollmentServer/Discovery.svc"
```

**Rollback:** Re-enrollment is additive — removes old enrollment and creates new. No destructive data loss unless device is wiped.

</details>

<details><summary>Playbook 3 — Bulk identify macOS devices with stale check-ins (PowerShell/Graph)</summary>

**Scenario:** After APNs expiry, identify all devices that stopped checking in.

```powershell
# Requires: Microsoft.Graph.Intune module or Graph API access
# Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"

$staleDays = 7
$cutoff = (Get-Date).AddDays(-$staleDays).ToUniversalTime().ToString("o")

$devices = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'macOS' and lastSyncDateTime le $cutoff&`$select=deviceName,lastSyncDateTime,serialNumber,userPrincipalName,managedDeviceOwnerType" `
    -OutputType PSObject

$devices.value | ForEach-Object {
    [PSCustomObject]@{
        DeviceName    = $_.deviceName
        SerialNumber  = $_.serialNumber
        User          = $_.userPrincipalName
        LastSync      = $_.lastSyncDateTime
        DaysSinceSync = ([datetime]::UtcNow - [datetime]$_.lastSyncDateTime).Days
    }
} | Sort-Object DaysSinceSync -Descending |
  Export-Csv C:\Temp\StaleMacDevices.csv -NoTypeInformation

Write-Host "[OK] Report saved: C:\Temp\StaleMacDevices.csv"
```

</details>

---
## Evidence Pack

```bash
#!/bin/bash
# MDM Certificate Renewal Evidence Collector
# Run as: sudo bash mdm_evidence.sh
# Output: /tmp/MDMEvidence_<timestamp>/

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTDIR="/tmp/MDMEvidence_$TIMESTAMP"
mkdir -p "$OUTDIR"

# 1. MDM enrollment profiles
sudo profiles list -verbose > "$OUTDIR/profiles_list.txt" 2>&1
sudo profiles show -type enrollment > "$OUTDIR/profiles_enrollment.txt" 2>&1

# 2. System keychain certificates (MDM-related)
security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null | \
    grep -A5 -i "MDM\|Intune\|Management\|APNS" > "$OUTDIR/system_keychain_mdm_certs.txt"

# 3. MDM cert expiry
security find-certificate -a -c "MDM" /Library/Keychains/System.keychain -p 2>/dev/null | \
    openssl x509 -noout -dates -subject > "$OUTDIR/mdm_cert_dates.txt" 2>&1

# 4. mdmclient recent logs
log show --predicate 'process == "mdmclient"' --last 24h --info 2>/dev/null | \
    grep -i "error\|fail\|cert\|expire\|checkin\|push" > "$OUTDIR/mdmclient_errors.log"

# 5. APNs connectivity test
nc -zv -G5 gateway.push.apple.com 2195 > "$OUTDIR/apns_connectivity.txt" 2>&1
nc -zv -G5 api.push.apple.com 443 >> "$OUTDIR/apns_connectivity.txt" 2>&1

# 6. System info
sw_vers > "$OUTDIR/system_info.txt"
hostname >> "$OUTDIR/system_info.txt"
networksetup -getinfo Wi-Fi >> "$OUTDIR/system_info.txt" 2>/dev/null

# 7. Compress
cd /tmp && zip -r "MDMEvidence_$TIMESTAMP.zip" "MDMEvidence_$TIMESTAMP/" > /dev/null
echo "[OK] Evidence pack: /tmp/MDMEvidence_$TIMESTAMP.zip"
```

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| Trigger MDM check-in | `sudo mdmclient CheckIn` |
| List all profiles | `sudo profiles list` |
| Show enrollment profile detail | `sudo profiles show -type enrollment` |
| Remove MDM enrollment profile | `sudo profiles remove -forced -type enrollment` |
| Restart mdmclient daemon | `sudo launchctl kickstart -k system/com.apple.mdmclient` |
| Find MDM certs in System keychain | `security find-certificate -a -Z /Library/Keychains/System.keychain \| grep -i MDM` |
| Check MDM cert expiry | `security find-certificate -a -c "MDM" /Library/Keychains/System.keychain -p \| openssl x509 -noout -dates` |
| View mdmclient errors (last hour) | `log show --predicate 'process == "mdmclient"' --last 1h \| grep -i error` |
| Test APNs connectivity | `nc -zv gateway.push.apple.com 2195` |
| Check macOS version | `sw_vers` |
| View device serial number | `system_profiler SPHardwareDataType \| grep Serial` |

---
## 🎓 Learning Pointers

- **APNs topic is the key identifier:** The APNS topic (a UID embedded in the APNs cert) is how Apple routes pushes to the correct MDM. If you renew using a different Apple ID, Apple issues a new topic — every device needs to re-enroll. The Apple ID for the original cert must be preserved in IT records as a critical credential. See [Intune APNs renewal](https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get).

- **Two separate renewal windows:** APNs cert (server-side): renew annually, up to 30 days early, in Apple Push Certificates Portal. Device identity cert (device-side): auto-renews via mdmclient 30 days before expiry if the APNs channel is healthy. If APNs expired, device identity cert auto-renewal also stops — fix APNs first.

- **ADE/DEP makes re-enrollment painless:** ADE (Automated Device Enrollment) devices automatically re-enroll on wipe because they're registered in Apple Business Manager. Non-ADE devices require user action. For MSPs managing mixed fleets, tracking ADE registration status is critical before any re-enrollment event.

- **Apple Business Manager Apple ID management:** The Apple ID used for APNs should be a role-based account (e.g., `mdm-admin@company.com`), not tied to an individual employee. When staff leave, individual Apple IDs lose organisational access and cannot be transferred. See [Apple Business Manager User Guide](https://support.apple.com/guide/apple-business-manager/welcome/web).

- **mdmclient is the macOS MDM agent:** Unlike Windows (where MDM is handled by the Enrollment Agent in the OS), macOS uses `/usr/libexec/mdmclient` as a launchd daemon. Understanding its log output is key to diagnosing why a device isn't checking in. Use `log stream --predicate 'process == "mdmclient"'` for live MDM activity.

- **Intune check-in frequency on macOS:** macOS devices check in with Intune approximately every 8 hours when healthy (plus APNs-triggered push check-ins). A device that hasn't checked in for >24 hours after APNs renewal is likely disconnected at the device level — check network, System keychain, and enrollment profile. See [Intune check-in intervals](https://learn.microsoft.com/en-us/mem/intune/configuration/device-profile-troubleshoot#how-long-does-it-take-for-devices-to-get-a-policy-profile-or-app-after-they-are-assigned).
