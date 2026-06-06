# macOS ADE Enrollment — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index (with jump links)
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

This runbook covers **Automated Device Enrollment (ADE)** — formerly Apple DEP (Device Enrollment Program) — for macOS devices managed through **Microsoft Intune**. It applies to:

- macOS devices assigned to an ADE token in Apple Business Manager (ABM) or Apple School Manager (ASM)
- Devices enrolled via Intune MDM profile (not JAMF, not direct Apple Profile Manager)
- macOS 12 Monterey through macOS 15 Sequoia
- Both user-affinity and user-affinity-less (device-based) enrollment

**Out of scope:** iOS/iPadOS ADE (different flow), BYOD enrollment (no ADE), JAMF-managed devices.

**Assumed knowledge:** Engineer understands Intune basics, has Global Admin or Intune Admin role, and has access to Apple Business Manager.

---
## How It Works

<details><summary>Full ADE enrollment architecture</summary>

ADE enrollment is an out-of-box experience (OOBE) flow that runs during macOS Setup Assistant. Here is the complete sequence:

```
1. Device powers on / is reset to factory
         │
         ▼
2. macOS contacts Apple Activation Server
   ─ Device serial checked against ADE assignment in ABM
   ─ Apple returns: "This device is MDM-managed, contact this MDM server"
   ─ URL returned = your Intune MDM server URL (embedded in ABM token)
         │
         ▼
3. Device downloads MDM enrollment profile from Intune
   ─ Profile is signed by Apple, trusted by macOS
   ─ Contains: MDM server URL, topic (push cert topic), identity cert
   ─ If profile is Supervised+Mandatory: user cannot skip enrollment
         │
         ▼
4. Device installs MDM profile and registers with Intune
   ─ Device generates device identity keypair
   ─ Sends device enrollment request to Intune (HTTPS)
   ─ Intune creates managed device record
         │
         ▼
5. Setup Assistant panes run
   ─ Intune Enrollment Profile controls which panes are skipped
   ─ Company Portal may be installed at this point via enrollment config
   ─ If User Affinity: user authenticates via Company Portal or web sign-in
         │
         ▼
6. User reaches Desktop
   ─ Intune pushes device configuration profiles, apps, compliance policy
   ─ APNS (Apple Push Notification Service) channel established
   ─ Device checks in on schedule: ~8 hours (configurable via check-in interval)
```

**Key architectural facts:**
- ADE assignment in ABM can take **up to 3 days** to sync to Intune (default sync is every 24 hours; manual sync is immediate)
- Intune MDM server URL must be resolvable from the device: `*.manage.microsoft.com`
- macOS trusts the MDM enrollment profile because Apple signs it — this is the chain of trust that makes Supervised mode possible
- The APNS certificate in Intune must be renewed annually (expiry breaks MDM push channel — all device commands fail silently)
- Platform SSO (macOS 13+) is a separate layer on top of ADE; enrollment can succeed while Platform SSO fails independently

**User Affinity vs. No User Affinity:**
| | User Affinity | No User Affinity |
|---|---|---|
| User logs in during Setup | Yes (Company Portal) | No |
| Device tied to specific user in Intune | Yes | No (shared device) |
| Conditional Access on device | Based on user | Device compliance only |
| Best for | Personal-use corporate Mac | Shared/kiosk Mac |

</details>

---
## Dependency Stack

```
Apple Business Manager (ABM / ASM)
    │
    ├── ADE Token (MDM Server Token)
    │       ├── Downloaded from ABM, uploaded to Intune
    │       ├── Validity: 1 year (must be renewed)
    │       └── Links ABM to specific Intune tenant
    │
    ├── Device Assignment in ABM
    │       ├── Device serial → MDM server mapping
    │       ├── Sync to Intune: manual (immediate) or auto (24h)
    │       └── Must happen BEFORE device is activated/enrolled
    │
Apple Push Notification Service (APNS)
    │
    ├── APNS Certificate in Intune
    │       ├── Validity: 1 year (must be renewed with SAME Apple ID)
    │       ├── Expiry = ALL iOS/macOS MDM commands fail
    │       └── Upload via: Intune → Tenant Admin → Apple MDM Push cert
    │
Intune Service (cloud)
    │
    ├── Enrollment Profile (ADE)
    │       ├── Configured in: Intune → Devices → macOS → Enrollment → ADE tokens → Profiles
    │       ├── Controls: supervised mode, user affinity, Setup Assistant panes
    │       └── Must be ASSIGNED to the device (via ADE token sync)
    │
    ├── Device Category / Group membership
    │       └── Used to target config profiles and apps post-enrollment
    │
Network (device-side requirements)
    │
    ├── apple.com / icloud.com (Apple Activation)
    ├── *.manage.microsoft.com (Intune MDM)
    ├── *.apple.com (APNS, software updates)
    └── login.microsoftonline.com (Entra ID auth, if User Affinity)

macOS Device
    │
    ├── Never previously enrolled to a DIFFERENT MDM (or MDM profile removed)
    ├── Serial number in ABM and assigned to correct MDM server
    └── Internet access during Setup Assistant
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Device not offered enrollment at Setup Assistant | Device not assigned to ADE / ABM sync not run | ABM portal → device assignment + force sync in Intune |
| "Remote Management" prompt skipped / skippable | Enrollment profile not Mandatory | Check enrollment profile settings in Intune |
| "Unable to connect" during enrollment | Network can't reach `*.manage.microsoft.com` | Test DNS + proxy from device at Setup |
| Company Portal not installing post-enrollment | Company Portal not in enrollment profile or VPP app | Check ADE profile → App config + VPP assignment |
| Device appears in Intune but shows "Not compliant" | Compliance policy grace period or Platform SSO issue | Check compliance policy, separate from enrollment |
| Enrollment completes but no profiles arrive | APNS cert expired or APNS topic mismatch | Check APNS cert expiry in Intune tenant settings |
| User affinity fails — "cannot authenticate" | Entra ID auth blocked (CA policy, MFA, SSPR) | Check Conditional Access sign-in logs |
| Enrollment profile download fails (4xxx HTTP error) | ADE token expired or invalid | Renew ADE token in ABM + Intune |
| Device enters enrollment loop | Enrollment profile is not marked as mandatory and device keeps re-enrolling | Check if device is in a group that triggers re-enrollment |
| "This Mac is supervised" not shown after enrollment | Supervised mode not enabled in enrollment profile | Re-enroll after correcting profile; cannot change post-enrollment |

---
## Validation Steps

**Step 1 — Confirm device is in ABM and assigned to correct MDM server**
```bash
# In Apple Business Manager portal:
# Devices → search by serial → confirm "MDM Server" field shows your Intune server
# Note: You can also check via Intune:
# Devices → macOS → Enrollment → ADE Tokens → [Token] → Devices
# Filter by serial number
```
Expected: Device listed with MDM server = your Intune ADE token name
Bad: Device not found, or assigned to wrong MDM server (e.g. JAMF, old tenant)

**Step 2 — Verify ADE token validity in Intune**
```powershell
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All"
$tokens = Get-MgDeviceManagementDepOnboardingSetting
$tokens | Select-Object Id, TokenName, TokenExpirationDateTime, SyncedDeviceCount, LastModifiedDateTime |
    Format-Table -AutoSize
```
Expected: `TokenExpirationDateTime` > today's date, `SyncedDeviceCount` > 0
Bad: Token expired (expiry in past) — must renew in ABM + re-upload to Intune

**Step 3 — Verify APNS certificate validity**
```powershell
$apns = Get-MgDeviceManagementApplePushNotificationCertificate
$apns | Select-Object AppleIdentifier, CertificateSerialNumber, ExpirationDateTime, LastModifiedDateTime
```
Expected: `ExpirationDateTime` > today
Bad: Expired — renew immediately (Intune → Tenant Admin → Connectors → Apple MDM Push Certificate)

**Step 4 — Check enrollment profile assignment**
In Intune portal: Devices → macOS → Enrollment → ADE Tokens → [Token] → Profiles
- Verify the profile is created and assigned to the device
- Check "Required" (Mandatory) toggle is ON for corporate devices

**Step 5 — Test network requirements from a device at enrollment**
```bash
# Run these in macOS Terminal during Setup Assistant (Cmd+Option+T to get terminal in some versions)
# Or test from a enrolled Mac on the same network
curl -I https://deviceenrollment.apple.com
curl -I https://mdmenrollment.apple.com
curl -I https://mobile.events.data.microsoft.com
nslookup enrollment.manage.microsoft.com
```
Expected: HTTP 200/302 responses, DNS resolves successfully
Bad: Curl times out, NXDOMAIN — proxy or firewall blocking

**Step 6 — Post-enrollment: verify MDM profile installed on device**
```bash
# Run on the enrolled Mac
sudo profiles list -verbose | grep -A5 "MDM"
sudo profiles show -type enrollment
```
Expected: MDM profile present, `PayloadType = com.apple.mdm`, supervised = true (for ADE)
Bad: No MDM profile — device unenrolled or profile removed

**Step 7 — Check Intune device record**
```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
$serial = "<DeviceSerial>"
Get-MgDeviceManagementManagedDevice -Filter "serialNumber eq '$serial'" |
    Select-Object DeviceName, SerialNumber, EnrolledDateTime, LastSyncDateTime,
                  ManagementState, ComplianceState, OperatingSystem, OsVersion |
    Format-List
```
Expected: `ManagementState = Managed`, `EnrolledDateTime` populated
Bad: Device not found (never enrolled), `ManagementState = RetirePending`

---
## Troubleshooting Steps (by phase)

### Phase 1 — Pre-enrollment (device hasn't started Setup Assistant)

1. Log into **Apple Business Manager** → Devices → Search serial
2. Confirm device is listed and "MDM Server" = your Intune ADE server
3. If not assigned: Add device to ABM (purchase from ABM reseller, or use Apple Configurator 2 for existing devices)
4. In Intune: Devices → macOS → Enrollment → ADE Tokens → [Token] → Sync
5. Wait 2-3 minutes, then verify device appears in token device list
6. Ensure enrollment profile is created and assigned in Intune

### Phase 2 — During Setup Assistant (enrollment failing live)

1. Get terminal access: on some macOS versions, Cmd+Option+T during Setup Assistant opens Terminal
2. Run network tests (see Validation Step 5)
3. If network is blocked: connect via direct internet (bypass proxy/corporate network) to verify
4. Check if device was previously enrolled in another MDM — if so, an MDM lock may be present (requires original MDM to release or Apple to remove via ABM)
5. Check macOS version — very old macOS may need upgrade before ADE works with modern Intune
6. Try: hold down Command+Option while clicking "Remote Management" screen to see verbose errors

### Phase 3 — Post-enrollment (device enrolled but misconfigured)

1. Check profiles: `sudo profiles list` — missing profiles = APNS issue or assignment gap
2. Check compliance: `sudo profiles show -type configuration` — shows all config profiles
3. Force MDM check-in: Intune portal → device → Sync button, or on device: `sudo profiles renew -type enrollment`
4. Check Intune device logs: Devices → [Device] → Monitor → Managed App logs or Diagnostics
5. For User Affinity issues: Company Portal → Settings → Device Management → check registration status

---
## Remediation Playbooks

<details><summary>Playbook 1 — Renew expired ADE token</summary>

**When:** ADE token expiry is past or within 30 days

```powershell
# Step 1: Identify expiring token
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All"
Get-MgDeviceManagementDepOnboardingSetting |
    Select-Object Id, TokenName, TokenExpirationDateTime |
    Format-Table -AutoSize
```

**Manual steps (portal required):**
1. Go to **Apple Business Manager** → Settings → MDM Servers → [Your Intune Server] → Download Token
2. Save the `.p7m` file
3. In Intune: Devices → macOS → Enrollment → ADE Tokens → [Expiring Token] → Renew token
4. Upload the new `.p7m` file
5. Click Sync after renewal

**Rollback:** Not applicable — token renewal is non-destructive. Existing enrolled devices are not affected; only new enrollments benefit from the renewed token.

</details>

<details><summary>Playbook 2 — Move device from wrong MDM server (JAMF → Intune)</summary>

**When:** Device is assigned to JAMF (or another MDM) in ABM but needs to move to Intune

```bash
# Pre-check: confirm current MDM assignment in ABM portal
# ABM → Devices → [serial] → Management → MDM Server

# Step 1: Release device from current MDM
# In JAMF Pro: Computers → [device] → Management → Unmanage
# This sends an MDM unenroll command — must be done BEFORE changing ABM assignment

# Step 2: In ABM, change MDM server assignment
# ABM → Devices → [select device] → Edit MDM Server → [Select Intune server]

# Step 3: Sync in Intune
# Intune → Devices → macOS → Enrollment → ADE Tokens → [Token] → Sync

# Step 4: Wipe and re-enroll the Mac
# Either via System Preferences → Erase All Content and Settings (macOS 12.0.1+)
# Or physically: hold Cmd+R at boot → Disk Utility → Erase → Reinstall macOS
```

**Important:** ADE enrollment only runs at Setup Assistant. If the device is already at the desktop with a different MDM profile, the device must be wiped/reset to trigger ADE enrollment with Intune.

**Rollback:** Re-assign device to original MDM server in ABM and wipe again.

</details>

<details><summary>Playbook 3 — Enroll existing Mac without reseller ADE link (Apple Configurator 2)</summary>

**When:** Mac was not purchased through ABM channel; need to add to ADE without a wipe

**Requirements:** Physical access to Mac, Apple Configurator 2 on a separate Mac, USB-C/Lightning cable

```bash
# This process DOES require a wipe of the target Mac
# Step 1: Open Apple Configurator 2 on your admin Mac
# Step 2: Connect target Mac via USB (boot target Mac in DFU mode if needed)
# Step 3: In Configurator 2: Actions → Prepare → Automated Enrollment
#          Select your MDM server (must be pre-configured in Configurator 2)
# Step 4: Complete wizard — this adds device to ABM AND to your ADE token
# Step 5: Sync in Intune: Devices → macOS → Enrollment → ADE Tokens → Sync
```

Note: Apple Configurator 2 approach creates a "Configurator" record in ABM, not a purchased device record. Functionality is identical for Intune MDM purposes.

**Rollback:** Device can be removed from ABM and unenrolled from Intune normally.

</details>

<details><summary>Playbook 4 — Fix stuck enrollment (device loops at "Remote Management" screen)</summary>

**When:** Device reaches the "Remote Management" Setup Assistant pane but fails to proceed

```bash
# On the stuck device — get terminal (Cmd+Opt+T or Ctrl+Opt+Cmd+T)
# Check activation status
profiles status -type enrollment

# Check network connectivity to Apple/Intune
curl -I https://albert.apple.com
curl -I https://deviceenrollment.apple.com  
curl -I https://mdmenrollment.apple.com

# Check system date/time (wrong date breaks SSL validation)
date

# If date is wrong, set it (requires network time or manual)
sntp -sS time.apple.com
```

If stuck due to network: connect to a network where Apple activation servers are reachable without proxy interception.

If stuck due to MDM server error: check Intune → Tenant Admin → Audit logs for failed enrollment events. The device UDID will appear in logs even for failed enrollments.

**Rollback:** Use `Cmd+Q` to quit Setup Assistant (only works if enrollment profile is NOT marked Mandatory). If Mandatory, device must complete enrollment or be wiped.

</details>

---
## Evidence Pack

Run on an enrolled Mac or admin workstation with Intune access to collect escalation evidence:

```powershell
# === INTUNE ADE EVIDENCE COLLECTOR ===
# Run on admin workstation with Graph access

Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All","DeviceManagementManagedDevices.Read.All"

$serial = "<TargetDeviceSerial>"
$outputPath = "$env:TEMP\ADE-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"

$evidence = @()
$evidence += "=== ADE ENROLLMENT EVIDENCE PACK ==="
$evidence += "Generated: $(Get-Date)"
$evidence += "Target serial: $serial"
$evidence += ""

# ADE Token status
$evidence += "=== ADE TOKENS ==="
$tokens = Get-MgDeviceManagementDepOnboardingSetting
foreach ($t in $tokens) {
    $evidence += "Token: $($t.TokenName) | Expires: $($t.TokenExpirationDateTime) | Devices: $($t.SyncedDeviceCount)"
}
$evidence += ""

# APNS status  
$evidence += "=== APNS CERTIFICATE ==="
try {
    $apns = Get-MgDeviceManagementApplePushNotificationCertificate
    $evidence += "Apple ID: $($apns.AppleIdentifier) | Expires: $($apns.ExpirationDateTime)"
} catch {
    $evidence += "ERROR retrieving APNS cert: $($_.Exception.Message)"
}
$evidence += ""

# Device record
$evidence += "=== DEVICE RECORD ==="
try {
    $device = Get-MgDeviceManagementManagedDevice -Filter "serialNumber eq '$serial'"
    if ($device) {
        $evidence += "Name: $($device.DeviceName)"
        $evidence += "Enrolled: $($device.EnrolledDateTime)"
        $evidence += "Last sync: $($device.LastSyncDateTime)"
        $evidence += "Management state: $($device.ManagementState)"
        $evidence += "Compliance: $($device.ComplianceState)"
        $evidence += "OS: $($device.OperatingSystem) $($device.OsVersion)"
        $evidence += "Enrollment type: $($device.DeviceEnrollmentType)"
    } else {
        $evidence += "Device NOT FOUND in Intune for serial: $serial"
    }
} catch {
    $evidence += "ERROR: $($_.Exception.Message)"
}

$evidence | Out-File -FilePath $outputPath -Encoding UTF8
Write-Host "Evidence written to: $outputPath" -ForegroundColor Green
```

**On the affected Mac (collect locally):**
```bash
# Run in Terminal on the enrolled Mac
sudo profiles list -verbose > ~/Desktop/profiles-list.txt
sudo profiles show -type enrollment >> ~/Desktop/profiles-list.txt
system_profiler SPHardwareDataType | grep -E "Serial|Model" >> ~/Desktop/profiles-list.txt
sw_vers >> ~/Desktop/profiles-list.txt
echo "MDM Enrollment:" >> ~/Desktop/profiles-list.txt
profiles status -type enrollment >> ~/Desktop/profiles-list.txt
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| List all MDM profiles on Mac | `sudo profiles list -verbose` |
| Show enrollment profile detail | `sudo profiles show -type enrollment` |
| Check enrollment status | `profiles status -type enrollment` |
| Force MDM profile renewal | `sudo profiles renew -type enrollment` |
| Remove MDM profile (if not supervised) | `sudo profiles remove -type enrollment` |
| Check supervision status | `sudo profiles show -type enrollment \| grep supervised` |
| List all config profiles | `sudo profiles show -type configuration` |
| Check device serial | `system_profiler SPHardwareDataType \| grep Serial` |
| Test Apple activation servers | `curl -I https://albert.apple.com` |
| Sync ADE token (PowerShell) | `Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/{id}/syncWithAppleDeviceEnrollmentProgram"` |
| Get ADE token list (PowerShell) | `Get-MgDeviceManagementDepOnboardingSetting` |
| Get APNS cert (PowerShell) | `Get-MgDeviceManagementApplePushNotificationCertificate` |
| Find device by serial (PowerShell) | `Get-MgDeviceManagementManagedDevice -Filter "serialNumber eq '<serial>'"` |
| Check macOS version | `sw_vers` |
| Check MDM check-in logs | `log show --predicate 'subsystem == "com.apple.mdmclient"' --last 1h` |

---
## 🎓 Learning Pointers

- **ADE is not the same as manual MDM enrollment:** ADE uses Apple's activation server to inject the MDM profile before the user can interact with the Mac. This is what enables Supervised mode and Mandatory enrollment — key for corporate fleet control. Manual enrollment (User Enrollment or Device Enrollment via Company Portal) doesn't provide these capabilities. See: [Apple ADE overview](https://support.apple.com/guide/apple-business-manager/intro-to-automated-device-enrollment-axe5d7b2a5f/web)

- **APNS and ADE token expiry are separate and both kill functionality:** APNS expiry prevents any MDM commands from being delivered (push channel breaks). ADE token expiry prevents NEW enrollments but doesn't affect already-enrolled devices. Know which one you're dealing with. See: [Renew Apple MDM push certificate](https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get)

- **The "Erase All Content and Settings" shortcut:** macOS 12.0.1+ on Apple Silicon Macs can be wiped via System Settings → General → Transfer or Reset → Erase All Content and Settings. This triggers the ADE flow on next boot. For Intel Macs, use Command+R boot recovery. This is the fastest re-enrollment path for an existing Mac.

- **MDM logs live in Unified Log:** The richest diagnostic source for macOS MDM issues is `log show --predicate 'subsystem == "com.apple.mdmclient"' --last 4h`. This shows every MDM push received, every profile install attempt, and every policy evaluation. Much more useful than anything in the GUI.

- **Supervised mode cannot be added after enrollment:** If a device enrolled without Supervised mode enabled in the ADE profile, you cannot add it later without wiping and re-enrolling. Supervised mode is required for many Intune features: hiding apps, single-app mode, software update enforcement, and some CA policies. Always enable it in the ADE enrollment profile for corporate devices.

- **Platform SSO is a separate layer:** macOS 13+ Platform SSO (sign in with Entra ID at the Mac login window) requires ADE enrollment first but is configured via a separate Configuration Profile (com.apple.configuration.extensibleSso). If Platform SSO is failing but ADE enrollment works, treat them as independent issues. See: [Configure Platform SSO for macOS](https://learn.microsoft.com/en-us/mem/intune/configuration/platform-sso-macos)
