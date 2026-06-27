# macOS PPPC / TCC — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- macOS Transparency, Consent & Control (TCC) framework architecture
- PPPC MDM configuration profiles (`com.apple.TCC.configuration-profile-policy`)
- Intune-deployed PPPC payloads for supervised macOS devices
- Common services: Full Disk Access, Accessibility, Screen Recording, Camera, Microphone, Input Monitoring
- Debugging `tccd`, TCC database, and MDM profile delivery chain

**Does not cover:**
- JAMF-deployed PPPC (concepts are identical, tooling differs)
- macOS Sequoia+ new privacy controls (e.g., Local Network prompts handled separately)
- App-specific entitlement provisioning (developer concern)
- Gatekeeper / notarization issues (see separate runbook)

**Assumptions:**
- Devices are DEP/ADE enrolled and supervised via Intune
- MDM admin access to Intune portal
- macOS 12 Monterey or later (TCC behaviour largely stable since Catalina 10.15)

---
## How It Works

<details><summary>Full architecture — TCC framework, tccd, and MDM override path</summary>

### Transparency, Consent & Control (TCC)

TCC is Apple's privacy gating framework, introduced in macOS Mojave (10.14) and significantly expanded in Catalina (10.15). It gates access to sensitive resources and user data behind user consent — or MDM-granted policy overrides on supervised devices.

**Core components:**

| Component | Role |
|-----------|------|
| `tccd` | Daemon that processes all TCC access requests; writes to TCC databases |
| `/Library/Application Support/com.apple.TCC/TCC.db` | System-wide TCC database (MDM grants land here) |
| `~/Library/Application Support/com.apple.TCC/TCC.db` | Per-user TCC database (user-granted permissions) |
| `tccutil` | CLI tool to reset TCC entries |
| `com.apple.TCC.configuration-profile-policy` | MDM payload type for PPPC |

### Request flow

```
Application requests sensitive resource
    │
    ▼
tccd receives request
    │
    ├─► Checks system TCC.db for MDM-granted entry
    │       ├── Found with auth_value=2 → GRANT (silent, no prompt)
    │       └── Found with auth_value=0 → DENY (silent)
    │
    ├─► Checks user TCC.db for user-granted entry
    │       ├── Found with auth_value=2 → GRANT
    │       └── Found with auth_value=0 → DENY
    │
    └─► No entry found
            ├── Device supervised + MDM policy exists → Apply MDM grant
            └── No MDM policy → Show user consent prompt
```

### MDM override path

When a PPPC profile is delivered via MDM:
1. `mdmclient` receives and installs the configuration profile
2. The `com.apple.TCC.configuration-profile-policy` payload is parsed
3. `tccd` writes entries into the **system** TCC.db with `auth_reason = 5` (MDM) and `flags & 0x10000` set
4. These entries take precedence over user decisions for **supervised** devices
5. Users **cannot** revoke MDM-granted permissions via System Settings

### Why supervised matters

On unsupervised (user-enrolled) devices, Apple does not allow MDM to silently grant TCC permissions. The design intent: a personally-owned Mac should always let the user control privacy, even if enrolled in MDM. This is a hard architectural constraint, not a policy choice.

### Code requirements and security

A PPPC entry can target an app by:
- **Bundle ID only** — any app claiming that bundle ID is granted (weak)
- **Bundle ID + Code Requirement** — cryptographically verifies the app's signing identity (recommended)

Code Requirements use Apple's CSL (Code Signing Language):
```
# Example from codesign output:
identifier "com.microsoft.OneDrive" and anchor apple generic and 
certificate 1[field.1.2.840.113635.100.6.2.6] exists and 
certificate leaf[field.1.2.840.113635.100.6.1.13] exists and 
certificate leaf[subject.OU] = UBF8T346G9
```

Always capture and use the full Code Requirement from `codesign -dv --verbose=4 /path/to.app`.

### TCC database schema (simplified)

```sql
CREATE TABLE access (
    service TEXT NOT NULL,           -- e.g., kTCCServiceSystemPolicyAllFiles
    client TEXT NOT NULL,            -- bundle ID or executable path
    client_type INTEGER NOT NULL,    -- 0=bundleID, 1=absolute path
    auth_value INTEGER NOT NULL,     -- 0=deny, 2=allow, 3=limited
    auth_reason INTEGER NOT NULL,    -- 1=error, 2=user, 3=denied, 4=granted, 5=MDM, 6=prompt
    auth_version INTEGER NOT NULL,   -- version
    csreq BLOB,                      -- serialized code requirement (if used)
    policy_id INTEGER,               -- links to MDM policy
    indirect_object_identifier TEXT, -- companion app/service
    flags INTEGER,                   -- 0x10000 = MDM-managed
    last_modified INTEGER NOT NULL   -- Unix timestamp
);
```

### Service keys reference

```
kTCCServiceAddressBook           → Contacts
kTCCServiceCalendar              → Calendars
kTCCServiceReminders             → Reminders
kTCCServicePhotos                → Photos
kTCCServiceCamera                → Camera
kTCCServiceMicrophone            → Microphone
kTCCServiceMotion                → Motion & Fitness
kTCCServiceWillow                → Home data
kTCCServiceAccessibility         → Accessibility
kTCCServicePostEvent             → Accessibility (send events)
kTCCServiceListenEvent           → Input Monitoring
kTCCServiceScreenCapture         → Screen Recording
kTCCServiceSystemPolicyAllFiles  → Full Disk Access
kTCCServiceSystemPolicySysAdminFiles → System administration files
kTCCServiceSystemPolicyDesktopFolder → Desktop folder
kTCCServiceSystemPolicyDownloadsFolder → Downloads folder
kTCCServiceSystemPolicyNetworkVolumes → Network volumes
kTCCServiceSystemPolicyRemovableVolumes → Removable volumes
kTCCServiceDeveloperTool         → Allow app to run unsigned code
kTCCServiceAppleEvents           → Allow app to control other apps
kTCCServiceSpeechRecognition     → Speech Recognition
kTCCServiceLocation              → Location (handled separately by locationd)
```

</details>

---
## Dependency Stack

```
User Experience (app works without prompts)
    │
    ├── tccd grants access (system TCC.db entry with auth_value=2)
    │       │
    │       └── Entry created by MDM (auth_reason=5) or user (auth_reason=2)
    │
    ├── MDM grant requires:
    │       ├── Device is Supervised
    │       ├── Valid PPPC profile delivered (mdmclient succeeded)
    │       ├── PayloadType: com.apple.TCC.configuration-profile-policy
    │       ├── Correct Service key (matches what app requests)
    │       ├── Correct Bundle ID (exact match, case sensitive)
    │       └── Valid Code Requirement (if specified — must match codesign output)
    │
    └── Profile delivery requires:
            ├── Device enrolled in MDM
            ├── Device online and checked in
            ├── Device in correct assignment group
            └── Profile not conflicting with another PPPC profile
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| User sees consent prompt despite PPPC profile | Device not supervised | `profiles status -type enrollment` |
| User sees prompt but profile is deployed | Bundle ID mismatch in profile | `codesign -dv` vs profile payload |
| App silently fails (no prompt, no access) | `auth_value=0` — profile denying | TCC.db `auth_value` field |
| Profile shows `Pending` in Intune for days | MDM check-in failure | `log show --predicate 'process == "mdmclient"'` |
| FDA granted but background daemon still blocked | Daemon binary needs separate entry | `launchctl list` → find daemon bundle ID |
| App worked, now prompts again after update | App re-signed with new identity; Code Requirement invalid | `codesign -dv` after update → compare |
| Permission granted in TCC.db but app reports denied | App checks entitlements before TCC | Check app for hardened runtime / entitlement requirements |
| `tccutil reset` doesn't fix it | SIP is enabled; system TCC.db protected | Boot Recovery OS to modify system TCC.db (last resort) |
| Multiple PPPC profiles conflict | Two profiles both targeting same bundle ID | `profiles show -all` → look for duplicate service keys |

---
## Validation Steps

1. **Confirm supervision status**
   ```bash
   sudo profiles status -type enrollment
   ```
   ✅ Good: `MDM enrollment: Yes (Device Enrollment)` or `Yes (User Approved) - DEP`
   ❌ Bad: `MDM enrollment: No` → PPPC MDM override will not work

2. **Verify profile is installed and content is correct**
   ```bash
   sudo profiles show -all 2>/dev/null | grep -A 40 "com.apple.TCC.configuration-profile-policy"
   ```
   ✅ Good: Your bundle ID and service appear in the payload
   ❌ Bad: No output → profile not installed; wrong bundle ID → will not match

3. **Check TCC database for the target app**
   ```bash
   sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
     "SELECT client, service, auth_value, auth_reason, flags FROM access WHERE client LIKE '%<bundleID>%';"
   ```
   ✅ Good: `auth_value=2, auth_reason=5` (MDM-granted allow)
   ❌ Bad: Missing → profile hasn't applied; `auth_value=0` → denied; `auth_reason=2` → user-granted only (MDM not applying)

4. **Validate code requirement from app binary**
   ```bash
   codesign -dv --verbose=4 /Applications/<AppName>.app 2>&1 | grep -E "Identifier|Designated Req|TeamIdentifier"
   ```
   Compare output to what's in your PPPC profile payload exactly.

5. **Real-time TCC decision logging**
   ```bash
   log stream --predicate 'subsystem == "com.apple.TCC"' --info --level info
   ```
   Launch the app and watch for:
   - `TCCDAccessRequest` — what the app is asking for
   - `added by MDM policy` — MDM grant fired correctly
   - `denied` — why it was denied

6. **Check for profile conflicts**
   ```bash
   sudo profiles show -all 2>/dev/null | grep -c "com.apple.TCC.configuration-profile-policy"
   ```
   ✅ Good: 1 (single profile managing TCC)
   ⚠️ Caution: 2+ profiles → potential conflict; later profile wins per key

---
## Troubleshooting Steps (by phase)

### Phase 1 — Profile delivery
1. Check Intune portal: Devices → [device] → Device configuration → PPPC profile status
2. If `Error`: click the profile → check error detail. Common: "Device not supervised"
3. If `Pending` for >30 min: trigger sync from portal or `sudo profiles renew -type enrollment` on device
4. If `Succeeded` but nothing in TCC.db: proceed to Phase 2

### Phase 2 — Profile content validation
1. Export all profiles: `sudo profiles show -all > /tmp/profiles_dump.txt`
2. Find your TCC payload in the dump
3. Cross-reference every Bundle ID with `codesign -dv --verbose=4` output
4. Cross-reference Service keys with the TCC service key table above
5. If Code Requirement is set: compare character-for-character with `codesign` output (common error: extra whitespace, missing `and`, wrong OU)
6. Fix payload in Intune → save → force device sync → re-check TCC.db

### Phase 3 — TCC database state
1. Query system TCC.db (see Validation Step 3)
2. Check user TCC.db too: `sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT * FROM access WHERE client LIKE '%<bundleID>%';"`
3. If stale/conflicting entries: `sudo tccutil reset <Service> <BundleID>`
4. Wait for mdmclient to re-apply MDM grants (usually within 60 seconds)
5. Re-run TCC query to verify new entries

### Phase 4 — App-level issues
1. Some apps (e.g., endpoint security tools) use System Extensions — those have separate approval via `systemextensionsctl list`
2. Security agents (CrowdStrike, Microsoft Defender) need **both** Full Disk Access (FDA) and a System Extension approval
3. If the app uses a network extension, check: `systemextensionsctl list | grep <vendor>`
4. For login items / LaunchDaemons: check if the launchd plist references a different binary than the main app

### Phase 5 — SIP / system integrity
1. If system TCC.db cannot be modified even with `sudo`: SIP is protecting it (expected on production Macs)
2. `tccutil reset` works from user space for user-level entries
3. MDM re-apply is the correct path for system entries — not direct DB manipulation
4. Only modify system TCC.db directly in Recovery mode as absolute last resort (unsupported, voids support)

---
## Remediation Playbooks

<details><summary>Playbook 1 — Build a correct PPPC profile in Intune from scratch</summary>

**Use case:** No PPPC profile exists, or existing one needs to be rebuilt correctly.

**Step 1 — Gather all required bundle IDs and code requirements:**
```bash
# For each app that needs PPPC grants, run:
APP="/Applications/<AppName>.app"
echo "Bundle ID:"
/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "${APP}/Contents/Info.plist"
echo ""
echo "Code Requirement:"
codesign -dv --verbose=4 "${APP}" 2>&1 | grep "Designated Requirement"
echo ""
echo "Team ID:"
codesign -dv --verbose=4 "${APP}" 2>&1 | grep "TeamIdentifier"
```

**Step 2 — Build in Intune:**
1. Intune → Devices → Configuration profiles → Create → macOS → Templates → Custom
2. Or use: Devices → Configuration profiles → Create → macOS → Settings catalog → Privacy → Privacy Preferences Policy Control
3. Add each app as a separate entry with:
   - **Bundle ID:** from step 1
   - **Identifier Type:** Bundle ID
   - **Code Requirement:** from step 1 (full `designated => ...` string)
   - **Service entries:** toggle Allow for each service needed

**Step 3 — Test in a pilot group first**
- Assign to a test group with 2-3 supervised Macs
- Wait 30 min, check TCC.db on test devices
- Validate no regressions on other apps
- Then expand assignment

**Rollback:** Remove the profile assignment from the group (TCC entries will persist until `tccutil reset` or device wipe).

</details>

<details><summary>Playbook 2 — Handle app update that breaks PPPC (code signing change)</summary>

**Symptoms:** PPPC worked before an app update. After update, prompts return or app silently fails.

**Root cause:** App was re-signed with new certificate, Team ID changed, or Code Requirement format changed.

```bash
# Get new code requirement from updated app
APP="/Applications/<UpdatedApp>.app"
codesign -dv --verbose=4 "${APP}" 2>&1 | grep "Designated Requirement"

# Compare to what's in TCC.db (old entry may still exist with old csreq)
sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT client, csreq FROM access WHERE client = '<bundle.id>';" | xxd | head -20
```

**Resolution:**
1. Capture new Code Requirement from updated binary
2. Update Intune PPPC profile with new Code Requirement
3. Reset stale TCC entry: `sudo tccutil reset <Service> <BundleID>`
4. Push profile update → device sync → verify new TCC entry

**Note:** If only the app version changed but the Team ID and signing certificate are the same, Code Requirements usually don't change. Check carefully before modifying.

**Rollback:** Revert profile to prior Code Requirement value.

</details>

<details><summary>Playbook 3 — Full Disk Access for Endpoint Security agents (CrowdStrike, Defender, SentinelOne)</summary>

**These agents have multiple components:**
1. Main app (`/Applications/Falcon.app`) — needs FDA
2. System Extension (`com.crowdstrike.falcon.Agent`) — needs user/MDM approval
3. Background daemon — may need separate FDA entry

```bash
# List all system extensions
systemextensionsctl list

# Find agent bundle IDs
ls /Applications/ | grep -iE "falcon|defender|sentinel|crowdstrike"
codesign -dv --verbose=4 /Applications/<Agent>.app 2>&1 | grep Identifier
```

**PPPC profile must include ALL of:**
```
Entry 1: Main app bundle ID → SystemPolicyAllFiles = Allow
Entry 2: System Extension bundle ID → SystemPolicyAllFiles = Allow  
Entry 3: Daemon binary path (if separate) → SystemPolicyAllFiles = Allow
```

**System Extension approval** (separate from PPPC, requires its own profile):
- Payload type: `com.apple.system-extension-policy`
- In Intune: Endpoint Security → [platform] → System Extensions

**Rollback:** Remove FDA entries (agent will prompt or fail silently — confirm with vendor which behaviour is expected).

</details>

<details><summary>Playbook 4 — Audit all PPPC grants on a fleet via Intune script</summary>

Deploy as an Intune shell script (Run as root = Yes):

```bash
#!/bin/bash
# PPPC/TCC Audit Script — deploy via Intune as shell script (root)
OUTPUT="/tmp/tcc_audit_$(hostname)_$(date +%Y%m%d).txt"

echo "=== TCC Audit: $(hostname) ===" > "$OUTPUT"
echo "Date: $(date)" >> "$OUTPUT"
echo "macOS: $(sw_vers -productVersion)" >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo "=== Supervision Status ===" >> "$OUTPUT"
profiles status -type enrollment 2>&1 >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo "=== Installed PPPC Profiles ===" >> "$OUTPUT"
profiles list -all 2>/dev/null | grep -A3 "com.apple.TCC\|PrivacyPreferences" >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo "=== System TCC Database (all entries) ===" >> "$OUTPUT"
sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value, auth_reason, flags, datetime(last_modified,'unixepoch') FROM access ORDER BY last_modified DESC;" \
  2>/dev/null | column -t >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo "=== MDM-Granted Entries (auth_reason=5) ===" >> "$OUTPUT"
sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value FROM access WHERE auth_reason = 5;" \
  2>/dev/null | column -t >> "$OUTPUT"

echo "Audit complete: $OUTPUT"
cat "$OUTPUT"
```

Script output goes to Intune shell script output logs (Devices → [device] → Scripts → [script] → Output).

</details>

---
## Evidence Pack

```bash
#!/bin/bash
# TCC Evidence Collection — run as root on affected Mac
# Saves output to /tmp/tcc_evidence_<hostname>.txt

HOST=$(hostname)
OUT="/tmp/tcc_evidence_${HOST}.txt"

echo "=== TCC Evidence Pack: $HOST ===" > "$OUT"
echo "Collected: $(date)" >> "$OUT"
echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))" >> "$OUT"
echo "" >> "$OUT"

section() { echo "" >> "$OUT"; echo "=== $1 ===" >> "$OUT"; }

section "Supervision & Enrollment"
profiles status -type enrollment >> "$OUT" 2>&1

section "All Configuration Profiles"
profiles list -all >> "$OUT" 2>&1

section "PPPC Profile Payloads"
profiles show -all 2>/dev/null | grep -A 50 "TCC.configuration-profile-policy" >> "$OUT"

section "System TCC Database"
sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value, auth_reason, flags, datetime(last_modified,'unixepoch','localtime') FROM access ORDER BY service, client;" \
  2>/dev/null | column -t >> "$OUT"

section "User TCC Database"
sudo -u "$SUDO_USER" sqlite3 \
  "/Users/$SUDO_USER/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service, client, auth_value, auth_reason FROM access ORDER BY service;" \
  2>/dev/null | column -t >> "$OUT"

section "System Extensions"
systemextensionsctl list >> "$OUT" 2>&1

section "MDM Client Log (last 2h)"
log show --predicate 'process == "mdmclient"' --last 2h 2>/dev/null | tail -100 >> "$OUT"

section "TCC Daemon Log (last 30min)"
log show --predicate 'subsystem == "com.apple.TCC"' --last 30m 2>/dev/null | tail -200 >> "$OUT"

echo "" >> "$OUT"
echo "=== Evidence collection complete ===" >> "$OUT"
echo "Saved to: $OUT"
```

---
## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `profiles status -type enrollment` | Check if device is supervised |
| `profiles list -all` | List all installed configuration profiles |
| `profiles show -all` | Show full profile payload content |
| `profiles renew -type enrollment` | Force MDM re-enrollment / profile refresh |
| `sqlite3 /Library/.../TCC.db "SELECT * FROM access;"` | Dump system TCC database |
| `tccutil reset <Service> <BundleID>` | Reset TCC entry for specific app+service |
| `tccutil reset All <BundleID>` | Reset ALL TCC entries for an app |
| `codesign -dv --verbose=4 /path/to.app` | Get bundle ID, team ID, code requirement |
| `mdls -name kMDItemCFBundleIdentifier /path/to.app` | Quick bundle ID lookup |
| `log stream --predicate 'subsystem == "com.apple.TCC"' --info` | Real-time TCC decision stream |
| `systemextensionsctl list` | Show installed system extensions |
| `launchctl list \| grep <vendor>` | Find vendor daemons |
| `sudo mdmclient QueryDeviceInformation` | Query MDM device information |
| `sw_vers` | Show macOS version |

---
## 🎓 Learning Pointers

- **TCC is not about profiles alone.** The profile tells `tccd` what to grant, but tccd only applies it when the app requests the permission AND the device is supervised. Understanding the tccd request-and-grant flow prevents 80% of "why isn't it working" confusion. See: [Apple Developer — Protecting user privacy](https://developer.apple.com/documentation/security/protecting-user-privacy)

- **System vs user TCC.db.** MDM grants land in the **system** database (`/Library/...`). User decisions land in the **user** database (`~/Library/...`). The system database takes precedence on supervised devices. Always query the right one. If you only see entries in the user database, MDM isn't applying.

- **The Code Requirement is a CSL (Code Signing Language) expression.** It's not just the Team ID — it can include certificate chain requirements, specific signing flags, or App Group identifiers. Copy it verbatim from `codesign -dv --verbose=4`. A truncated or reformatted code requirement will never match. See: [Code Signing Guide](https://developer.apple.com/library/archive/technotes/tn2127/)

- **app_type matters for background processes.** Main apps use `client_type=0` (bundle ID). Executables without a bundle ID use `client_type=1` (absolute path). If a daemon binary is at `/usr/local/bin/vendor-daemon` and has no bundle ID, you must use a path-based PPPC entry, not a bundle ID entry.

- **PPPC and System Extensions are different.** FDA via PPPC doesn't replace System Extension approval. Endpoint security products need both: a PPPC profile for FDA + a system extension policy profile. If you only set FDA, the kernel extension will still require user approval. See: [Apple — System Extensions and DriverKit](https://developer.apple.com/system-extensions/)

- **ProfileCreator and iMazing Profile Editor** are your friends for building PPPC payloads correctly before deploying. Both can export to `.mobileconfig` which Intune can upload as a custom profile. Hand-editing XML is error-prone and time-consuming.
