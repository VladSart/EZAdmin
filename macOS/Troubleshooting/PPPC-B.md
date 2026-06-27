# macOS PPPC / TCC — Hotfix Runbook (Mode B: Ops)
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

Run these on the affected Mac (Terminal or via Intune shell script):

```bash
# 1. Check TCC database for app in question (replace with actual bundle ID)
sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT client, service, auth_value FROM access WHERE client LIKE '%<bundleID>%';"

# 2. List currently loaded PPPC profiles (Intune-deployed)
profiles list -all 2>/dev/null | grep -A2 -B2 -i "privacy\|TCC\|PPPC"

# 3. Check if MDM is managing TCC overrides
sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT client, service, auth_value, indirect_object_code_identity FROM access WHERE flags & 0x10000 = 0x10000 LIMIT 20;"

# 4. Confirm mdmclient sees the profile
sudo mdmclient QueryDeviceInformation 2>&1 | grep -i "profile\|TCC"

# 5. Dump all installed profile payloads and grep for PrivacyPreferences
sudo profiles show -all 2>/dev/null | grep -A20 "com.apple.TCC.configuration-profile-policy"
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| App missing from TCC.db entirely | Profile never applied OR app hasn't launched yet | Check profile deployment status → Fix 1 |
| `auth_value = 0` | Permission explicitly denied | Manual approval OR re-push corrected profile → Fix 2 |
| `auth_value = 2` | Permission allowed | TCC is fine — check app's own config |
| Profile not listed in `profiles list` | Intune hasn't delivered it yet | Force sync → Fix 3 |
| `flags & 0x10000` entries present | MDM-granted (correct path) | TCC is MDM-managed, look elsewhere |
| Profile listed but app still prompted | Bundle ID or code requirement mismatch | Rebuild payload → Fix 4 |

---
## Dependency Cascade

<details><summary>What must be true for PPPC to work</summary>

```
macOS TCC Framework (tccd daemon)
    └── MDM Enrollment (supervised, DEP or manual)
            └── PPPC Configuration Profile delivered via MDM
                    └── Correct PayloadType: com.apple.TCC.configuration-profile-policy
                            └── Correct Bundle ID (or Code Requirement) for target app
                                    └── Correct Service key (e.g., SystemPolicyAllFiles)
                                            └── App launches AFTER profile applies
                                                    └── Expected: no user prompt, permission silently granted
```

**Critical constraint:** PPPC via MDM only works on **Supervised** devices. Unsupervised devices require user interaction regardless of profile.

**Service name → Entitlement mapping:**
| Service Key | What it grants |
|-------------|---------------|
| `SystemPolicyAllFiles` | Full Disk Access |
| `Accessibility` | Accessibility API access |
| `ScreenCapture` | Screen Recording |
| `Camera` | Camera access |
| `Microphone` | Microphone access |
| `AddressBook` | Contacts |
| `CalendarAgent` | Calendars |
| `SystemPolicySysAdminFiles` | Admin file access |
| `ListenEvent` | Input Monitoring |
| `PostEvent` | Accessibility (events) |

</details>

---
## Diagnosis & Validation Flow

1. **Confirm device is supervised**
   ```bash
   sudo profiles status -type enrollment
   ```
   Expected output includes: `MDM enrollment: Yes (User Approved) or (Device Enrollment)`
   ⚠️ If not supervised — PPPC MDM override will NOT work. Go to Escalation.

2. **Find the app's bundle ID**
   ```bash
   mdls -name kMDItemCFBundleIdentifier /Applications/<AppName>.app
   # or
   /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" /Applications/<AppName>.app/Contents/Info.plist
   ```

3. **Check Intune device profile assignment**
   - Portal: Intune → Devices → macOS → [device] → Device configuration
   - Look for your PPPC profile → status should be `Succeeded`
   - If `Pending` or `Error`: check device sync and assignment group

4. **Inspect the TCC database directly**
   ```bash
   sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
     "SELECT client, service, auth_value, auth_reason FROM access WHERE client = '<bundle.id.here>';"
   ```
   - `auth_value = 2` = allowed
   - `auth_reason = 5` = MDM-granted (correct)
   - `auth_reason = 3` = user-granted

5. **Stream TCC logs in real time** (reproduce the prompt):
   ```bash
   log stream --predicate 'subsystem == "com.apple.TCC"' --info
   # In another terminal, launch the app
   ```
   Look for: `TCCDAccessRequest denied` or `added via MDM policy`

6. **Validate profile payload structure**
   ```bash
   sudo profiles show -all 2>/dev/null | python3 -c "
   import sys, plistlib
   # paste output into temp file and inspect PayloadContent
   "
   # Or extract to inspect:
   sudo profiles export -all -o /tmp/profiles_export
   ```

---
## Common Fix Paths

<details><summary>Fix 1 — Profile not deployed / device not in assignment group</summary>

**Symptoms:** App missing from TCC.db, `profiles list` shows no PPPC profile.

```powershell
# PowerShell (Graph API) — verify device group membership
Connect-MgGraph -Scopes "Device.Read.All", "Group.Read.All"

$deviceName = "<deviceName>"
$device = Get-MgDevice -Filter "displayName eq '$deviceName'"
$memberships = Get-MgDeviceMemberOf -DeviceId $device.Id
$memberships | Select-Object -ExpandProperty AdditionalProperties | ForEach-Object { $_["displayName"] }
```

**On Mac:**
```bash
# Force Intune MDM check-in
sudo /usr/local/bin/IntuneMDMDaemonProcess &
# Or via Company Portal app → click "Check status"
# Or:
sudo profiles renew -type enrollment
```

**Resolution:** Add device/user to the assignment group in Intune → wait 15 min or force sync.

**Rollback:** N/A — additive change.

</details>

<details><summary>Fix 2 — Profile applied but permission shows denied (auth_value = 0)</summary>

**Symptoms:** App is in TCC.db with `auth_value = 0`. Profile may have an error in bundle ID.

```bash
# Check exact bundle ID from app binary (source of truth)
codesign -dv --verbose=4 /Applications/<App>.app 2>&1 | grep "Identifier\|TeamIdentifier"

# Compare to what's in the profile
sudo profiles show -all 2>/dev/null | grep -A5 "Identifier\|BundleID"
```

**If bundle ID is wrong in profile:**
1. In Intune → Device Configuration → [PPPC profile] → Edit
2. In the Privacy Preferences Policy Control payload, correct the **Bundle ID** field
3. Set **Identifier Type** to `bundleID`
4. Save → device will receive updated profile on next sync

**If code requirement is wrong:**
```bash
# Get the exact code requirement for the app
codesign -dv --verbose=4 /Applications/<App>.app 2>&1 | grep "Designated Requirement"
# Copy the output exactly — paste into the "Code Requirement" field in Intune
```

**Rollback:** Revert profile to previous version in Intune.

</details>

<details><summary>Fix 3 — Profile stuck / Intune sync not delivering</summary>

**Symptoms:** Profile visible in Intune portal as assigned but device shows `Pending`.

```bash
# On the Mac — force MDM daemon restart
sudo launchctl kickstart -k system/com.apple.mdmclient
sleep 5
sudo profiles renew -type enrollment

# Verify profiles refreshed
profiles list -all | grep -i "privacy\|TCC"
```

**If still stuck after 30 min:**
```bash
# Check MDM daemon logs for errors
log show --predicate 'process == "mdmclient"' --last 1h | grep -i "error\|fail\|profile"
```

**Portal action:** Intune → Devices → [device] → Sync (button)

**Rollback:** N/A.

</details>

<details><summary>Fix 4 — Full Disk Access not working for background service / daemon</summary>

**Symptoms:** App has FDA in TCC.db but a background service/daemon component is still blocked.

Background daemons (launchd services) need their **own** PPPC entry — the main app bundle ID is not sufficient.

```bash
# Find the daemon's bundle ID or executable path
launchctl list | grep <companyname>
# Get the label and find the plist:
sudo cat /Library/LaunchDaemons/<label>.plist | grep -E "BundleID|Program|Label"
```

**Profile fix:** Add a second entry in the PPPC payload for the **daemon's bundle ID** or use the **executable path** with identifier type `path`:

```xml
<!-- In the Intune custom profile XML (or via GUI) -->
<dict>
    <key>Identifier</key>
    <string>/path/to/daemon/binary</string>
    <key>IdentifierType</key>
    <string>path</string>
    <key>Services</key>
    <dict>
        <key>SystemPolicyAllFiles</key>
        <dict>
            <key>Allowed</key>
            <true/>
            <key>CodeRequirement</key>
            <string><!-- from codesign -dv --></string>
        </dict>
    </dict>
</dict>
```

**Rollback:** Remove the path-based entry from the profile.

</details>

<details><summary>Fix 5 — Reset TCC database entry and re-test (last resort)</summary>

**Symptoms:** Conflicting entries in TCC database, profile correct but nothing works.

⚠️ **Destructive** — removes all existing TCC decisions for the app. User may be prompted again if supervised MDM re-grant doesn't fire.

```bash
# Remove specific app's TCC entries (requires SIP disabled or Full Disk Access for Terminal)
tccutil reset All <bundle.id.here>

# Or reset specific service only
tccutil reset SystemPolicyAllFiles <bundle.id.here>

# Then force MDM re-apply
sudo profiles renew -type enrollment
sleep 10
# Re-launch the app
```

**Rollback:** Re-add entries manually via System Settings → Privacy & Security (for supervised devices, MDM should re-grant automatically).

</details>

---
## Escalation Evidence

```
=== PPPC / TCC Escalation Pack ===
Date/Time:          
Device Name:        
macOS Version:      
Supervised (Y/N):   
MDM Enrollment Type: [ADE / User Approved]

App Affected:       
App Bundle ID:      
Service Requested:  [e.g., SystemPolicyAllFiles / Camera / Microphone]

Intune Profile Name:     
Intune Profile Status:   [Succeeded / Pending / Error]

TCC DB Entry:
  auth_value:    [0=denied / 2=allowed]
  auth_reason:   [3=user / 5=MDM]
  flags:         

Profiles installed (PPPC):
  [paste output of: profiles list -all | grep -A2 "TCC\|Privacy"]

TCC log excerpt:
  [paste from: log stream --predicate 'subsystem == "com.apple.TCC"']

codesign output:
  [paste from: codesign -dv --verbose=4 /Applications/<App>.app]

Steps already tried:
  [ ] Forced device sync
  [ ] Verified bundle ID in profile
  [ ] Checked code requirement
  [ ] Reset TCC entry

```

---
## 🎓 Learning Pointers

- **Supervised = requirement.** PPPC MDM overrides are only enforced on supervised Macs. Unsupervised devices will always show user prompts regardless of profiles. See: [Apple Platform Deployment — Privacy Preferences Policy Control](https://support.apple.com/en-gb/guide/deployment/dep38df53c2a/web)

- **tccd is the daemon.** All TCC decisions go through `tccd`. If you see repeated prompts after a profile should have applied, `log stream --predicate 'subsystem == "com.apple.TCC"'` will show you exactly why tccd denied the request — it's the fastest path to root cause.

- **Bundle ID vs. Code Requirement.** Bundle ID alone is weak — any app claiming that bundle ID would get the grant. A Code Requirement (from `codesign -dv --verbose=4`) ties the grant to a cryptographically signed identity. Always use Code Requirements for sensitive services like FDA and Accessibility.

- **Daemons need their own entry.** A PPPC grant for `com.vendor.app` does NOT cover `com.vendor.app.daemon` or a helper at `/usr/local/bin/vendor-helper`. Each binary that makes a TCC request needs its own payload entry.

- **Intune PPPC profiles use a custom mobileconfig payload** (`com.apple.TCC.configuration-profile-policy`). If building manually, use [ProfileCreator](https://github.com/ProfileCreator/ProfileCreator) or the Intune GUI — hand-editing XML is error-prone. See: [Intune PPPC payload docs](https://learn.microsoft.com/en-us/intune/intune-service/configuration/device-restrictions-macos#privacy-preferences-policy-control)

- **TCC reset is your break-glass.** `tccutil reset <Service> <BundleID>` clears stale decisions and lets MDM re-apply cleanly. It's non-destructive to the app itself and safe to use in testing.
