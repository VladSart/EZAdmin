# macOS Managed Software Updates — Hotfix Runbook (Mode B: Ops)
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

Run these on the affected Mac (via SSH, Terminal, or Intune shell script):

```bash
# 1. Check available and pending software updates
softwareupdate --list 2>&1

# 2. Check current OS version and build
sw_vers

# 3. Check MDM enrollment and managed update settings
profiles show -type configuration 2>/dev/null | grep -E "Update|SoftwareUpdate|Deferral|ForceInstall"

# 4. Check Intune MDM channel status
log show --last 1h --predicate 'subsystem == "com.apple.ManagedClient"' \
    --info 2>/dev/null | grep -i "softwareupdate\|update" | tail -30

# 5. Check current DDM (Declarative Device Management) update state if on macOS 13+
/usr/bin/profiles show -type enrollment 2>/dev/null | grep -i "declarative\|DDM"
```

**Interpretation table:**

| Result | What it means | Action |
|---|---|---|
| `No new software available` + user says update is pending | Update deferred by MDM policy or already installed | Check Intune policy deferral settings + device OS version |
| `Error 100` in softwareupdate output | Can't reach Apple Update servers | Check DNS, proxy, firewall — `swupd.apple.com` must be reachable |
| MDM profile shows `enforcedSoftwareUpdateDelay = 30` | Updates are deferred 30 days from Apple release | Expected — update won't appear until deferral expires |
| `forceInstallDate` in profile | A deadline is set for forced install | Tell user — they must save work before that date/time |
| OS version matches target | Update is already applied | Verify in Intune device record that compliance policy is reflecting correctly |
| No MDM profile entries for SoftwareUpdate | No update management policy deployed | Deploy an Intune update policy or DDM update declaration |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Intune / MDM Server
        │
        ├── Software Update Policy (legacy MDM payload — macOS 10.15–13)
        │       ├── AllowPreReleaseSoftwareUpdates
        │       ├── AutomaticCheckEnabled / AutomaticDownloadEnabled
        │       ├── CriticalUpdateInstall
        │       ├── enforcedSoftwareUpdateDelay (0–90 days)
        │       └── forceInstallDate (deadline for forced install)
        │
        ├── DDM — Declarative Device Management (macOS 13+ preferred)
        │       ├── Software Update Declaration
        │       │       ├── TargetOSVersion
        │       │       ├── TargetBuildVersion
        │       │       └── TargetLocalDateTime (deadline)
        │       └── Sent via MDM Activation → Declarative framework
        │
        ├── Apple Software Update infrastructure
        │       ├── swupd.apple.com (catalog)
        │       ├── gdmf.apple.com (version data)
        │       └── *.apple.com CDN (download)
        │
        ├── macOS Software Update subsystem
        │       ├── /Library/Preferences/com.apple.SoftwareUpdate.plist
        │       ├── /var/db/.SoftwareUpdateAtLogout (logout trigger flag)
        │       └── softwareupdated daemon (launchd managed)
        │
        └── Managed Client (MDM agent)
                └── /Library/Managed Preferences/ (managed policy files)
```

</details>

---

## Diagnosis & Validation Flow

**1. Determine the update management method in use:**

```bash
# Check if DDM is active (macOS 13+ with modern Intune)
/usr/bin/profiles show -type enrollment 2>/dev/null | grep -i declarative

# Check for legacy MDM SoftwareUpdate payload
/usr/bin/profiles show -type configuration 2>/dev/null | grep -A5 "PayloadType.*SoftwareUpdate"

# Check managed preferences for SoftwareUpdate
/usr/bin/defaults read /Library/Managed\ Preferences/com.apple.SoftwareUpdate 2>/dev/null
```

**2. For Intune: check the device's update assignment**

In Intune portal (endpoint.microsoft.com):
- Devices → macOS → select device → Update policies (filter by OS)
- Confirm a "macOS update policy" or "DDM Update" profile is assigned and shows "Success"

**3. Check the actual OS installed vs. the policy target:**

```bash
# Current version
sw_vers -productVersion   # e.g. 14.4.1

# Target from MDM policy (DDM)
/usr/bin/profiles show -type configuration 2>/dev/null | grep -i "TargetOSVersion\|targetOSVersion"
```

**4. Verify Apple server reachability:**

```bash
# Test access to Apple Software Update CDN
curl -s -o /dev/null -w "%{http_code}" "https://swupd.apple.com/index-10.15-10.16.merged-1.sucatalog" 
# Expected: 200
# Non-200: proxy or firewall blocking Apple update CDN

curl -s -o /dev/null -w "%{http_code}" "https://gdmf.apple.com/v2/pmv"
# Expected: 200 (version manifest endpoint used by Intune DDM)
```

---

## Common Fix Paths

<details><summary>Fix 1 — Update not offered to user despite Intune policy being assigned</summary>

**Cause A — Deferral period active:**

```bash
# Check deferral setting in managed preferences
/usr/bin/defaults read /Library/Managed\ Preferences/com.apple.SoftwareUpdate enforcedSoftwareUpdateDelay 2>/dev/null
# If this returns 14 / 30 etc. — updates are deferred that many days from Apple release
```

Fix: In Intune, edit the update policy → reduce `Software update schedule` deferral OR switch to a DDM update declaration which overrides deferrals with a specific target version.

**Cause B — Intune MDM check-in hasn't happened:**

```bash
# Force MDM check-in
sudo /usr/bin/profiles renew -type enrollment
# Wait 2–5 minutes, then:
sudo /usr/bin/profiles show -type configuration | grep -i softwareupdate
```

**Cause C — No policy assigned:**

In Intune portal:
1. Devices → macOS → select device → Overview → Policies → verify "macOS Software Update Policy" shows in list.
2. If missing: Devices → macOS → Update policies → create or assign an existing policy to the device's group.
3. After assignment, trigger sync: Intune portal → device → Sync.

</details>

<details><summary>Fix 2 — User keeps dismissing update prompts (update overdue)</summary>

**Use DDM forceInstallDate to enforce a deadline:**

Intune portal → Devices → macOS → Update policies → select policy → Edit:
- "Schedule type" = "Update at scheduled time" or "Download, install, and restart" 
- Set a specific deadline (e.g. 72 hours from now)

For DDM (macOS 14+), the update declaration sets `TargetLocalDateTime`:

```json
{
    "type": "com.apple.configuration.softwareupdate.enforcement.specific",
    "identifier": "ForceUpdate-2025Q2",
    "payload": {
        "TargetOSVersion": "14.5",
        "TargetBuildVersion": "23F79",
        "TargetLocalDateTime": "2025-11-01T22:00:00"
    }
}
```

On macOS 14+ with DDM, after the `TargetLocalDateTime` passes, the update is applied at the next login/logout without user interaction.

**Notify the user explicitly:** Send an email or Teams message explaining the deadline.

</details>

<details><summary>Fix 3 — softwareupdate fails with network error / can't reach update server</summary>

```bash
# Test specific Apple update endpoints
curl -sv "https://swupd.apple.com" 2>&1 | grep -E "Connected|SSL|200|403|FAILED"
curl -sv "https://gdmf.apple.com/v2/pmv" 2>&1 | grep -E "Connected|SSL|200|403|FAILED"

# Check system proxy settings
scutil --proxy

# Check if a web proxy is intercepting Apple CDN (SSL inspection)
openssl s_client -connect swupd.apple.com:443 -showcerts 2>/dev/null | 
    openssl x509 -noout -issuer 2>/dev/null
# If issuer is your corporate proxy CA rather than Apple — SSL inspection is the cause
```

**Fix for SSL inspection blocking Apple updates:**

Option A (recommended): Add `*.apple.com` to the proxy bypass list / SSL inspection exclusions.
Option B: Push the corporate CA certificate to Mac keychain via Intune → Devices → macOS → Configuration profiles → Certificate profile.

**Fix for restricted DNS/firewall:**

Ensure these are reachable on port 443:
- `swupd.apple.com`
- `gdmf.apple.com`
- `mesu.apple.com`
- `oscdn.apple.com`
- `updates.cdn-apple.com`

Reference: [Apple Support HT210060 — Software Update ports](https://support.apple.com/en-us/101555)

</details>

<details><summary>Fix 4 — Device shows update installed in Intune but OS version still shows old</summary>

**Cause:** Intune hardware inventory hasn't refreshed after the update.

```bash
# Check current OS version on device
sw_vers -productVersion

# Force Intune inventory sync
sudo /usr/bin/profiles renew -type enrollment
# Then in Intune portal: device → Sync
```

If the local OS version matches the target but Intune still shows old:
- Intune portal → device → Sync → wait 15 minutes → refresh.
- If still wrong after 1 hour, check the device's `osVersion` attribute via Graph:

```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "serialNumber eq '<serialNumber>'" |
    Select-Object DeviceName, OsVersion, LastSyncDateTime | Format-List
```

</details>

<details><summary>Fix 5 — macOS major version upgrade (e.g. Ventura → Sonoma) not offered via Intune</summary>

**Cause:** Major OS upgrades require either a DDM declaration or a managed installer — they are not offered via the legacy SoftwareUpdate MDM payload.

**Modern approach (macOS 14+ recommended):**

1. Intune portal → Devices → macOS → Update policies → Create → "macOS updates" type.
2. Set minimum OS version (e.g. 14.0) — Intune uses DDM to deliver the upgrade declaration.
3. Assign to device group.
4. Sync the device.

**Verify DDM delivery:**

```bash
# Check DDM activation state
/usr/bin/profiles show -type enrollment 2>/dev/null | grep -A5 -i "declarative\|DDM"

# Check that softwareupdated received the DDM instruction
log show --last 2h \
    --predicate 'subsystem == "com.apple.softwareupdate"' \
    --info 2>/dev/null | grep -i "enforc\|DDM\|declaration" | tail -20
```

**Alternative — managed installer via Installomator or direct MDM command:**

For environments where DDM isn't fully deployed, use an Intune shell script to run:
```bash
/usr/sbin/softwareupdate --fetch-full-installer --full-installer-version 14.5
```
Then trigger install via a second script or via the startosinstall binary. Note: this approach requires ~13 GB free disk space.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — macOS Managed Software Updates
===================================================
Date/Time of issue:          ___________________________
Affected device name:        ___________________________
Device serial number:        ___________________________
Current OS version (sw_vers): __________________________
Target OS version (policy):  ___________________________
Intune device ID:            ___________________________
Intune last sync:            ___________________________

Update management method:
  [ ] Legacy SoftwareUpdate MDM payload
  [ ] DDM (Declarative Device Management) — macOS 13+
  [ ] None / not deployed

Symptom:
  [ ] Update not offered to user
  [ ] Network/server error when checking for updates
  [ ] Update installed but Intune shows old version
  [ ] Major OS upgrade not offered
  [ ] Update prompt dismissed / user non-compliant

softwareupdate --list output (paste):
-----------------------------------------


Apple server reachability (curl output):
  swupd.apple.com:  [ ] 200  [ ] Other: _____
  gdmf.apple.com:   [ ] 200  [ ] Other: _____

MDM SoftwareUpdate managed pref:
  enforcedSoftwareUpdateDelay: _____
  forceInstallDate:            _____

MDM check-in log (last error if any):


Attached:
  [ ] profiles show output
  [ ] softwareupdate --list output
  [ ] Intune device overview screenshot
  [ ] Network trace (if proxy/firewall suspected)

Intune support: https://endpoint.microsoft.com → Troubleshooting + support → Help and support
Apple MDM reference: https://developer.apple.com/documentation/devicemanagement/softwareupdate
```

---

## 🎓 Learning Pointers

- **DDM is the future for macOS updates:** Starting macOS 14 (Sonoma), Apple strongly prefers the Declarative Device Management framework for update enforcement. Unlike legacy MDM payloads, DDM gives the device a specific target version and deadline, and the device applies it autonomously — no MDM polling required. Intune maps its "macOS update policy" to DDM on supported devices automatically. [Apple Platform Deployment: Software updates](https://support.apple.com/en-gb/guide/deployment/dep360ccbee4/web)

- **Deferrals vs. forceInstallDate:** `enforcedSoftwareUpdateDelay` delays when an update *appears* to the user (counts from Apple release date). `forceInstallDate` (or DDM `TargetLocalDateTime`) forces the *install* by a deadline regardless of user action. These are independent levers — you need both for a complete policy. [MS Docs: macOS software update policies in Intune](https://learn.microsoft.com/en-us/mem/intune/protect/software-updates-macos)

- **Major upgrades need MDM-supervised devices:** A device must be MDM-supervised (Apple Business Manager enrolled via ADE, not user-enrolled) to receive forced OS upgrades via MDM. User-enrolled Macs can only be nudged — the user must ultimately approve. Check supervision status: `profiles status -type enrollment | grep Supervised`. [Apple MDM Protocol Reference: ScheduleOSUpdate](https://developer.apple.com/documentation/devicemanagement/schedule_an_os_update)

- **SSL inspection breaks softwareupdate:** Corporate proxies that perform SSL/TLS inspection frequently break macOS software update. Apple's update CDN certificates must be trusted as-is. The fix is always to add `*.apple.com` to the SSL bypass list, not to push your corporate CA to the Mac (the CA won't help because Apple pins their certificate chain). [Apple KB: HT210060 — ports used by Apple software products](https://support.apple.com/en-us/101555)

- **Installomator is the community standard for managed pkg installs:** For third-party app updates or pre-staging the macOS installer, [Installomator](https://github.com/Installomator/Installomator) is widely used in MSP environments. It downloads from the vendor's official CDN, verifies the signature, and installs silently. It's MIT-licensed and actively maintained — a solid addition to your Intune shell script library.
