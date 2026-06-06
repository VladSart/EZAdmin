# macOS ADE Enrollment — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers Automated Device Enrollment (ADE/DEP) failures via Apple Business Manager + Intune.

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

Run from **Intune portal** or PowerShell with Graph access:

```powershell
# 1. Check ADE token expiry in Intune (MDM Push cert + ADE token)
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All" -NoWelcome
$adeTokens = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/depOnboardingSettings"
$adeTokens.value | Select tokenName, tokenExpirationDateTime, enrollmentAuthenticationMethod, lastModifiedDateTime | Format-Table
# Bad: tokenExpirationDateTime in the past → Fix 1

# 2. Check Apple MDM Push certificate expiry
$mdmPush = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/applePushNotificationCertificate"
$mdmPush | Select appleIdentifier, expirationDateTime, lastModifiedDateTime
# Bad: expirationDateTime in the past → renew at https://identity.apple.com

# 3. List failed/blocked enrollments (last 24h)
$enrollments = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceEnrollmentConfigurations"
# For specific device errors, check: Intune portal > Devices > macOS > macOS enrollment > Enrollment program tokens > [token] > Devices

# 4. Check if device is visible in ABM and assigned to correct MDM server
# Must be done in Apple Business Manager portal (appleid.apple.com/account/manage is deprecated)
# ABM > Devices > [serial number] > MDM Server = your Intune tenant

# 5. Verify enrollment profile is assigned to the device/group
$profiles = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/depOnboardingSettings"
$profiles.value | Select id, tokenName | Format-Table
```

**Interpret immediately:**

| Symptom | Meaning | Go to |
|---------|---------|-------|
| ADE token expired | ABM ↔ Intune sync broken | [Fix 1](#fix-1--renew-expired-ade-token) |
| MDM Push cert expired | ALL iOS/macOS MDM commands broken | [Fix 2](#fix-2--renew-apple-mdm-push-certificate) |
| Device shows in ABM but not Intune | ABM sync not run / device assigned to wrong MDM server | [Fix 3](#fix-3--device-not-syncing-from-abm-to-intune) |
| Mac boots but skips Setup Assistant (no enrollment) | Profile not assigned or device pre-dates ABM add | [Fix 4](#fix-4--mac-skips-setup-assistant--ade-enrollment) |
| Enrollment stuck at "Setting up your Mac" | Intune enrollment profile issue or network block | [Fix 5](#fix-5--mac-stuck-at-setting-up-your-mac) |

---

## Dependency Cascade

<details><summary>What must be true for ADE to work</summary>

```
┌──────────────────────────────────────────────────────┐
│               macOS Device (new/wiped)               │
└──────────────────────┬───────────────────────────────┘
                       │ Contacts Apple activation servers
                       ▼
┌──────────────────────────────────────────────────────┐
│              Apple Activation Servers                │
│   (albert.apple.com, captive.apple.com, etc.)        │
└──────────────────────┬───────────────────────────────┘
                       │ Device serial in ADE program?
                       ▼
┌──────────────────────────────────────────────────────┐
│            Apple Business Manager (ABM)              │
│   Device assigned to Intune MDM server               │
└──────────────────────┬───────────────────────────────┘
                       │ ABM ↔ Intune token (valid, synced)
                       ▼
┌──────────────────────────────────────────────────────┐
│         Intune ADE Token (DEP Token)                 │
│   Valid, not expired, synced in last 24h             │
└──────────────────────┬───────────────────────────────┘
                       │ ADE enrollment profile assigned to device
                       ▼
┌──────────────────────────────────────────────────────┐
│        Intune ADE Enrollment Profile                 │
│   (Setup Assistant config, supervised, affinity)     │
└──────────────────────┬───────────────────────────────┘
                       │ Device completes Setup Assistant
                       ▼
┌──────────────────────────────────────────────────────┐
│         Apple MDM Push Certificate (APNS)            │
│   Valid, tied to same Apple ID as original           │
└──────────────────────┬───────────────────────────────┘
                       │ MDM commands delivered
                       ▼
┌──────────────────────────────────────────────────────┐
│             Intune Device Management                 │
│   Policies, apps, compliance applied                 │
└──────────────────────────────────────────────────────┘
```

**Critical:** ADE enrollment requires port 443 to `*.apple.com`, `*.mzstatic.com`, and `*.itunes.apple.com`. Check firewall/proxy if enrollment stalls.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Check device's ADE history on the Mac**

On the target Mac (Terminal or SSH):
```bash
# Check if device was enrolled via ADE
sudo profiles status -type enrollment
# Good: "MDM enrollment: Yes (User Approved: Yes)" or "Enrolled via DEP: Yes"
# Bad:  "MDM enrollment: No" after Setup Assistant completed

# Check MDM profile
sudo profiles show -type enrollment

# Check enrollment logs
log show --predicate 'subsystem == "com.apple.ManagedClient"' --last 1h | tail -50
# Look for: error strings, "Could not contact MDM server", "enrollment failed"
```

**Step 2 — Verify device is in ADE scope**

```bash
# On the Mac — check if device was activated via ADE
sudo /usr/bin/profiles show -type enrollment | grep "IsMDMUnremovable\|DEP"
# IsMDMUnremovable = 1 means enrolled via ADE/DEP (profile is locked)
```

**Step 3 — Check Intune enrollment errors**

In Intune portal: **Devices > macOS > macOS enrollment > Enrollment program tokens > [your token] > Devices**

Look for the serial number. Status column shows:
- `Ready` — awaiting first boot/wipe
- `Discovered` — seen by Apple, not yet enrolled
- `Enrolled` — complete
- `Failed` — error in Detail column

**Step 4 — Network check (ADE required endpoints)**

```bash
# On the Mac during Setup Assistant (or pre-enrollment):
curl -s https://albert.apple.com/deviceservices/deviceActivation -o /dev/null -w "%{http_code}"
# Good: 200 or 500 (server processed it)
# Bad:  000 (no connectivity), 403 (blocked by proxy)

# Check if captive portal is intercepting
curl -s https://captive.apple.com/ | head -1
# Expected: <HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>
```

---

## Common Fix Paths

<details><summary>Fix 1 — Renew expired ADE token</summary>

**When:** `tokenExpirationDateTime` is in the past in Intune. No new ADE devices will sync.

1. In **Intune portal**: Devices > macOS > macOS enrollment > Enrollment program tokens > [expired token] > **Renew token**
2. Download the new public key (.pem file) from Intune
3. In **Apple Business Manager**: Settings > MDM Servers > [your Intune server] > Upload MDM Server Certificate > upload the .pem
4. Download the new server token (.p7m) from ABM
5. Back in **Intune**: upload the .p7m to complete renewal
6. Click **Sync** to force a device list refresh

**Note:** Renewing the token does NOT interrupt existing enrolled devices. Only new/unassigned devices need the valid token for assignment.

</details>

<details><summary>Fix 2 — Renew Apple MDM Push Certificate</summary>

**When:** APNS cert is expired. Existing enrolled Macs will fail to receive MDM commands.

⚠️ **CRITICAL:** You MUST renew (not create new) using the **same Apple ID** that created the original cert. Creating a new cert breaks all existing enrolled devices — they must be re-enrolled.

1. Go to **Intune portal**: Devices > Enroll devices > Apple enrollment > Apple MDM Push certificate
2. Click **Download your CSR** to get the Intune .csr file
3. Go to [Apple Push Certificates Portal](https://identity.apple.com/pushcert/)
4. Find the existing Intune cert → **Renew** (not Create) → upload the .csr → download the .pem
5. Back in Intune: **Upload** the .pem and complete renewal

**After renewal:** Existing enrolled devices reconnect automatically within the next MDM check-in (up to 8h) or on next Dock/menu bar Intune agent call.

</details>

<details><summary>Fix 3 — Device not syncing from ABM to Intune</summary>

**When:** Device is visible in ABM but not appearing in Intune ADE device list.

```powershell
# Step 1: Force sync from Intune (Graph API)
$tokenId = "<your-ade-token-id-from-step-above>"
Invoke-MgGraphRequest -Method POST `
  -Uri "https://graph.microsoft.com/v1.0/deviceManagement/depOnboardingSettings/$tokenId/syncWithAppleDeviceEnrollmentProgram"
# Sync runs in background — wait 2-3 minutes then check device list
```

**Also check in ABM:**
- Device is assigned to the **correct** MDM server (your Intune tenant URL)
- Device was not recently transferred between MDM servers (30-min propagation delay after transfer)
- Device serial number is not already assigned to a different ABM account

</details>

<details><summary>Fix 4 — Mac skips Setup Assistant / ADE enrollment</summary>

**When:** Mac boots to desktop without going through ADE Setup Assistant. Common after user restores from Time Machine or completes macOS reinstall incorrectly.

```bash
# Option A: Trigger enrollment on an already-booted Mac (if device IS in Intune ADE scope)
# This works if the device is assigned and profile says "Allow Pairing = Yes" (or user-approved MDM)
sudo profiles renew -type enrollment
# User will see MDM enrollment prompt

# Option B: For devices that truly skipped ADE, erase and start over
# Wipe the device: Apple menu > System Settings > General > Transfer or Reset > Erase All Content and Settings
# Device will re-activate via ADE on next boot if assigned in ABM

# Option C: Pre-check before erase — confirm device is in Intune ADE list
# Intune portal: Devices > macOS > macOS enrollment > Enrollment program tokens > [token] > Devices
# Serial must appear with status "Ready" or "Enrolled"
```

**If device is NOT in ABM:** It cannot be ADE enrolled. It must be added to ABM (purchased through an authorised reseller with ABM linked, or added manually if on macOS 12+ via Apple Configurator 2 → ABM).

</details>

<details><summary>Fix 5 — Mac stuck at "Setting up your Mac" during enrollment</summary>

**When:** ADE Setup Assistant completes but Mac hangs on the Intune onboarding screen for >20 minutes.

```bash
# On the Mac:
# Step 1: Check Intune MDM agent logs
log show --predicate 'subsystem == "com.apple.ManagedClient"' --last 2h 2>/dev/null | grep -i "error\|fail\|timeout" | tail -30

# Step 2: Check if Company Portal is hanging
# Look for Company Portal in Activity Monitor — high CPU or "Not Responding"
# Kill and relaunch: killall "Company Portal"

# Step 3: Force re-check of MDM profile
sudo profiles -N  # (macOS 12 and earlier — forces re-enroll attempt)
# or on macOS 13+:
sudo profiles renew -type enrollment
```

**Common causes:**
- Proxy blocking `*.manage.microsoft.com` or `*.microsoftonline.com`
- Company Portal app not updated (update via App Store before enrollment)
- Enrollment profile requires VPN that isn't yet active

</details>

---

## Escalation Evidence

```
=== macOS ADE Enrollment — Escalation Template ===
Date/Time:            ___________________________
Ticket #:             ___________________________

ENVIRONMENT
  macOS version:                ___________________________  (e.g. Sequoia 15.3)
  Device model / serial:        ___________________________
  ABM account:                  ___________________________
  Intune tenant:                ___________________________  (e.g. contoso.onmicrosoft.com)
  ADE token name:               ___________________________
  Apple ID used for APNS cert:  ___________________________

ISSUE TYPE
  [ ] ADE token expired
  [ ] APNS cert expired
  [ ] Device not appearing in Intune
  [ ] Setup Assistant skipped
  [ ] Stuck at "Setting up your Mac"
  [ ] Other: ___________________________

TRIAGE RESULTS
  ADE token expiry date:         ___________________________
  APNS cert expiry date:         ___________________________
  Device in ABM (Y/N):           ___________________________
  ABM assigned MDM server:       ___________________________
  Intune ADE device status:      ___________________________
  profiles status -type enrollment output:
    ___________________________

NETWORK CHECK
  albert.apple.com curl response: ___________________________
  captive.apple.com response:     ___________________________

FIXES ATTEMPTED
  1. ___________________________
  2. ___________________________

ESCALATION TARGET:
  [ ] Microsoft Intune support (admin.microsoft.com > Support)
  [ ] Apple Business Manager support (businessmanager.apple.com/help)
  [ ] Network/proxy team
```

---

## 🎓 Learning Pointers

- **ADE enrollment is bootstrapped at activation, not at OS login.** The device checks for an MDM assignment the moment it contacts Apple's activation servers on first boot. If the device was already activated before being added to ABM, you must erase it for ADE to apply. `sudo profiles renew` is a workaround for already-activated devices, not a substitute. See: [Apple ADE documentation](https://support.apple.com/guide/apple-business-manager/intro-to-automated-device-enrollment-axm6f9e93ba/web)

- **Never let the APNS cert expire.** Unlike ADE tokens (which only block new enrollments), an expired APNS cert stops ALL MDM communication with ALL enrolled Apple devices — including existing ones. Put a calendar reminder 30 days before expiry. See: [Renew Apple MDM Push cert in Intune](https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get)

- **The ADE token must be renewed with the same Apple ID that created it.** If the person who created the ABM account left the company, you need to recover the Apple ID before you can renew. Plan ahead — don't use personal Apple IDs for ABM.

- **macOS ADE enrollment requires internet access to `albert.apple.com` on port 443 before the Wi-Fi profile can be pushed.** If your network blocks unknown devices, you need to either allow these Apple endpoints pre-enrollment or use a dedicated SSID for onboarding. Full list: [Apple network requirements](https://support.apple.com/en-gb/101555)

- **`sudo profiles status -type enrollment`** is the fastest 10-second check on any Mac to confirm MDM state. "Enrolled via DEP: Yes" and "MDM enrollment: Yes (User Approved: Yes)" is the gold standard for supervised ADE devices.
