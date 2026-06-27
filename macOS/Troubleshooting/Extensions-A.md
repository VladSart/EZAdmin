# macOS System Extensions & Kernel Extensions — Reference Runbook (Mode A: Deep Dive)
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

Covers macOS system extensions (`.systemextension` bundles, introduced macOS 10.15) and legacy kernel extensions (kexts, deprecated in macOS 11+). Applies to:

- Endpoint security solutions (CrowdStrike, Defender, Jamf Protect, Carbon Black)
- Network extensions (VPN clients, content filters, DNS proxies)
- MDM-managed approvals via Intune or Jamf
- Apple Silicon and Intel Macs (behaviour differs significantly)

**Prerequisites:** macOS 12.x or later, Intune MDM enrolled, administrator or MDM policy rights.

---

## How It Works

<details><summary>Full architecture</summary>

### System Extension Framework (macOS 10.15+)

System extensions replace kernel extensions and run in **user space** (not kernel space). They communicate with the OS via the `SystemExtensions.framework` API.

```
┌──────────────────────────────────────────┐
│              User Space                  │
│  ┌──────────────────────────────────┐    │
│  │       Host App (e.g. Defender)   │    │
│  │  OSSystemExtensionRequest        │    │
│  └──────────┬───────────────────────┘    │
│             │ Activates                  │
│  ┌──────────▼───────────────────────┐    │
│  │   System Extension (.systemext)  │    │
│  │   - EndpointSecurity             │    │
│  │   - NetworkExtension             │    │
│  │   - DriverKit                    │    │
│  └──────────┬───────────────────────┘    │
│             │ API calls only             │
└─────────────┼──────────────────────────-─┘
              │
┌─────────────▼────────────────────────────┐
│              Kernel Space                │
│   EndpointSecurity framework             │
│   NetworkExtension framework             │
│   DriverKit framework                    │
└──────────────────────────────────────────┘
```

### Approval Flow

1. App requests extension activation via `OSSystemExtensionRequest`
2. macOS requires **user approval** OR **MDM pre-approval**
3. MDM pre-approval uses `SystemExtensions` payload (team ID + bundle ID whitelist)
4. Once approved, extension runs persistently across reboots
5. PPPC (Privacy Preferences Policy Control) controls what the extension can *access*

### MDM Approval (Intune)

Intune delivers a **System Extensions** configuration profile with:
- `AllowedSystemExtensions` — specific bundle IDs
- `AllowedSystemExtensionTypes` — by type (EndpointSecurity, NetworkExtension, DriverKit)
- `AllowedTeamIdentifiers` — all extensions from a vendor's team ID

Without MDM approval on supervised devices, users see a "System Extension Blocked" notification and must manually approve in System Settings → Privacy & Security.

### Kernel Extensions (Legacy)

Kexts load into kernel memory and require:
- Developer ID signed with kext entitlement
- MDM-approved `KernelExtensionPolicy` payload (team ID)
- On Apple Silicon: kexts require entering **Reduced Security** mode in recoveryOS

On macOS 12+, Apple shows deprecation warnings. macOS 15 Sequoia removes most third-party kext support.

### PPPC (Full Disk Access / Privacy)

Separate from extension approval. Even if a system extension is active, it may fail to function without PPPC grants:
- Full Disk Access — required for AV scanners
- Network Filter — required for network content filters
- Screen Recording — for some monitoring tools

MDM delivers PPPC via `PrivacyPreferencesPolicyControl` profile.

</details>

---

## Dependency Stack

```
macOS Sequoia/Sonoma/Ventura
  └── Secure Boot / SIP (System Integrity Protection)
       └── MDM Supervision (AppleMDM / DEP)
            └── SystemExtensions Profile (team ID whitelist)
                 └── PPPC Profile (Full Disk Access, etc.)
                      └── System Extension Bundle (.systemext)
                           └── Host Application
                                └── Endpoint functionality
                                     (AV scanning, VPN, DNS proxy, DLP)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| "System Extension Blocked" notification | No MDM approval profile, or profile not yet applied | `systemextensionsctl list` + Intune profile status |
| Extension shows "activated waiting for user" | User must approve manually (device not supervised or MDM policy pending) | Check supervision status: `profiles status -type enrollment` |
| Security tool not scanning files | PPPC Full Disk Access not granted | `tccutil reset All` not applicable via MDM — check PPPC profile |
| VPN extension loads but traffic not filtered | Network Extension approved but system-level filter not installed | Check `ifconfig utun*` and `/Library/SystemExtensions/` |
| Extension unloads after app update | Bundle ID or team ID changed in new version | Re-deliver MDM profile with updated identifiers |
| Kext blocked on Apple Silicon | Kexts require Reduced Security; MDM can't override | User must boot to recoveryOS and lower security policy |
| `systemextensionsctl` shows "terminated" | Extension crashed; check Console.app | `log show --predicate 'subsystem == "com.apple.system_extensions"'` |
| Extension works on Intel, not M-series | App not Universal Binary / missing arm64 slice | Check app binary: `file /path/to/app.app/Contents/MacOS/appname` |
| Profile shows "installed" in Intune but extension blocked | Profile delivered but SIP blocking unsigned extension | Verify code signing: `codesign -dv --verbose=4 /path/to.systemextension` |

---

## Validation Steps

**1. Check extension status**
```bash
systemextensionsctl list
```
Expected good output:
```
[activated enabled]  com.vendor.extension (1.2.3) [TeamID: ABCD1234EF]
```
Bad output: `waiting for user`, `terminated`, or entry missing entirely.

**2. Verify MDM enrollment and supervision**
```bash
profiles status -type enrollment
```
Expected: `MDM enrollment: Yes (User Approved)` or `Yes (Device Enrollment)`. Supervised = `Yes` is required for silent approval.

**3. Check Intune profile delivery**
```bash
profiles show -all | grep -A5 "SystemExtension"
```
Or: System Settings → Privacy & Security → Profiles. If profile absent, extension approval cannot be silent.

**4. Check PPPC profile**
```bash
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, service, allowed FROM access WHERE client LIKE '%<vendorBundleID>%';"
```
Expected: rows with `allowed = 1` for `kTCCServiceSystemPolicyAllFiles` (Full Disk Access).

**5. Check code signing**
```bash
codesign -dv --verbose=4 /Library/SystemExtensions/<TeamID>/<BundleID>.systemextension 2>&1 | grep -E "TeamIdentifier|BundleID|Authority"
```
Expected: Authority lines chain to Apple Root CA; TeamIdentifier matches MDM profile.

**6. Check SIP status**
```bash
csrutil status
```
Expected: `System Integrity Protection status: enabled`. If disabled, document — extension behaviour may differ.

**7. Check extension logs**
```bash
log show --last 1h --predicate 'subsystem == "com.apple.system_extensions"' | grep -i "error\|fail\|block"
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm the problem scope

1. Is this one device or many? One → likely device-specific. Many → profile or deployment issue.
2. Is the device supervised? `profiles status -type enrollment`
3. Was the device enrolled before or after the extension policy was created? New policy may not backfill reliably.
4. Did this follow a macOS upgrade? SIP re-enables after upgrade; some extensions need re-approval.

### Phase 2 — Profile delivery

1. In Intune portal → Devices → macOS → Configuration Profiles → find the SystemExtensions profile → check Assignment and Status
2. On device: `profiles show -all` — confirm profile present and no error state
3. If profile missing: force sync `sudo profiles -D && sudo profiles -R -p <profileID>` or trigger sync from Company Portal / Intune management

### Phase 3 — Extension activation

1. `systemextensionsctl list` — note exact state
2. If `waiting for user`: device is not supervised or MDMCCID not matching — re-enrol via ADE/DEP
3. If `terminated`: extension crashed — collect crash report from `/Library/Logs/DiagnosticReports/`
4. If extension missing from list: host application was not run post-profile delivery, or app not installed

### Phase 4 — PPPC / permissions

1. Check TCC database (step 4 above)
2. Verify PPPC profile in Intune covers all required services
3. Note: TCC entries from MDM take precedence over manual user grants — do not mix both

### Phase 5 — Apple Silicon specific

1. Check architecture: `uname -m` (arm64 = Apple Silicon)
2. `system_profiler SPiBridgeDataType` — confirm T2/M-series chip
3. For kexts: advise client that kexts are not supported without reduced security; plan migration to system extensions
4. Verify app supports arm64 — open Activity Monitor, find process, confirm Architecture column = Apple Silicon

---

## Remediation Playbooks

<details><summary>Playbook 1 — Push MDM System Extension approval profile</summary>

**Intune → Devices → Configuration profiles → Create → macOS → Templates → Extensions**

Required payload fields:
```
Payload Type: System Extensions
Allowed system extensions (specific):
  Bundle ID: com.vendor.extension
  Team Identifier: ABCD1234EF

OR

Allowed system extension types:
  Team ID: ABCD1234EF
  Allowed types: EndpointSecurity, NetworkExtension
```

Assign to device group. After sync (up to 8 hours, or trigger via Company Portal), verify:
```bash
profiles show -all | grep -A10 "SystemExtensions"
systemextensionsctl list
```

**Rollback:** Remove profile assignment in Intune. Extensions may prompt for manual removal or remain active until app removed.

</details>

<details><summary>Playbook 2 — Fix PPPC / Full Disk Access for security tools</summary>

**Intune → Configuration profiles → Create → macOS → Templates → Privacy preferences policy control**

```
Bundle ID: com.vendor.endpointsecurity
Bundle type: App
App or service: SystemPolicyAllFiles
Access: Allow
```

Add entries for all required services. Assign to same device group as extension profile.

Verify after sync:
```bash
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, service, allowed, auth_value FROM access WHERE service = 'kTCCServiceSystemPolicyAllFiles';"
```

</details>

<details><summary>Playbook 3 — Force extension re-activation after macOS upgrade</summary>

```bash
# Remove and re-activate (requires app to be running)
# First try: relaunch host app
sudo killall -9 <hostAppProcess>
open -a "<App Name>"

# If still blocked, deactivate and reactivate via systemextensionsctl
sudo systemextensionsctl deactivate <TeamID>/<BundleID>
# Then relaunch app — it will re-request activation
```

If profile was applied before upgrade, try removing and re-pushing from Intune to force re-evaluation.

</details>

<details><summary>Playbook 4 — Collect crash info for terminated extension</summary>

```bash
# Find crash reports
ls -lt /Library/Logs/DiagnosticReports/ | grep -i <extensionBundleID> | head -5

# Get recent extension syslog
log show --last 2h \
  --predicate 'subsystem == "com.apple.system_extensions" OR process == "<extensionProcess>"' \
  > /tmp/extension_log.txt

# Check for panics (kernel extension crashes)
ls /Library/Logs/DiagnosticReports/*.panic 2>/dev/null
```

Send crash report and log to vendor support.

</details>

---

## Evidence Pack

Run this script to collect all relevant state for escalation:

```bash
#!/bin/bash
# EZAdmin — macOS Extension Evidence Collector
OUTPUT="/tmp/mac_ext_evidence_$(date +%Y%m%d_%H%M%S).txt"

echo "=== macOS Extension Evidence Pack ===" > "$OUTPUT"
echo "Date: $(date)" >> "$OUTPUT"
echo "Hostname: $(hostname)" >> "$OUTPUT"
echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))" >> "$OUTPUT"
echo "Arch: $(uname -m)" >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo "=== MDM Enrollment ===" >> "$OUTPUT"
profiles status -type enrollment >> "$OUTPUT" 2>&1

echo "" >> "$OUTPUT"
echo "=== Installed Profiles ===" >> "$OUTPUT"
profiles show -all 2>&1 | grep -E "ProfileDisplayName|ProfileType|PayloadType" >> "$OUTPUT"

echo "" >> "$OUTPUT"
echo "=== System Extensions ===" >> "$OUTPUT"
systemextensionsctl list >> "$OUTPUT" 2>&1

echo "" >> "$OUTPUT"
echo "=== SIP Status ===" >> "$OUTPUT"
csrutil status >> "$OUTPUT" 2>&1

echo "" >> "$OUTPUT"
echo "=== Code Signing (check /Library/SystemExtensions) ===" >> "$OUTPUT"
for ext in /Library/SystemExtensions/*/*.systemextension; do
  [ -e "$ext" ] || continue
  echo "--- $ext ---" >> "$OUTPUT"
  codesign -dv "$ext" 2>&1 | grep -E "TeamIdentifier|Identifier|Authority" >> "$OUTPUT"
done

echo "" >> "$OUTPUT"
echo "=== TCC Full Disk Access ===" >> "$OUTPUT"
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, service, allowed FROM access WHERE service = 'kTCCServiceSystemPolicyAllFiles';" \
  >> "$OUTPUT" 2>&1

echo "" >> "$OUTPUT"
echo "=== Recent Extension Errors (1h) ===" >> "$OUTPUT"
log show --last 1h \
  --predicate 'subsystem == "com.apple.system_extensions"' \
  2>/dev/null | grep -i "error\|fail\|block\|denied" | tail -30 >> "$OUTPUT"

echo "" >> "$OUTPUT"
echo "Evidence written to: $OUTPUT"
cat "$OUTPUT"
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| List all system extensions | `systemextensionsctl list` |
| Check MDM enrollment/supervision | `profiles status -type enrollment` |
| Show all MDM profiles | `profiles show -all` |
| Check SIP | `csrutil status` |
| Verify code signing | `codesign -dv --verbose=4 /path/to.systemextension` |
| Check TCC (Full Disk Access) | `sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db "SELECT client,service,allowed FROM access WHERE service='kTCCServiceSystemPolicyAllFiles';"` |
| View extension logs | `log show --last 1h --predicate 'subsystem == "com.apple.system_extensions"'` |
| Check architecture | `uname -m` (arm64 = Apple Silicon) |
| Verify app binary architecture | `file /Applications/App.app/Contents/MacOS/appname` |
| Find crash reports | `ls /Library/Logs/DiagnosticReports/ \| grep <bundleID>` |
| Force MDM check-in | `sudo profiles -D && sudo profiles renew -type enrollment` |
| Deactivate extension | `sudo systemextensionsctl deactivate <TeamID>/<BundleID>` |
| Check kext approval (legacy) | `spctl kext-consent list` |
| macOS version | `sw_vers` |

---

## 🎓 Learning Pointers

- **System extensions are user-space, not kernel.** This is the fundamental architectural shift since Catalina. They cannot crash the kernel, but they also can't do everything kexts could — vendors must use Apple's EndpointSecurity, NetworkExtension, or DriverKit frameworks. See [Apple's System Extensions guide](https://developer.apple.com/documentation/systemextensions).

- **Supervision is the key unlock.** Without Apple DEP/ADE supervision, MDM cannot silently approve system extensions. The user gets a notification and must approve manually in System Settings. For MSP environments, always ensure devices are enrolled via ADE — see [Apple Business Manager DEP docs](https://support.apple.com/guide/apple-business-manager/welcome/web).

- **PPPC and extension approval are separate.** Getting the extension *running* (SystemExtensions profile) is different from granting it *permissions* (PPPC profile). Both must be present. Security tools that silently fail to detect threats are often missing the Full Disk Access PPPC grant.

- **Apple Silicon changed kext rules permanently.** Kernel extensions require Reduced Security mode on M-series, which also disables features like Secure Boot verification. If a vendor still requires a kext on Apple Silicon, that's a red flag — push them to deliver a system extension. See [Apple's kext deprecation notice](https://developer.apple.com/support/kernel-extensions/).

- **TCC database is MDM-controlled.** On managed devices, entries from MDM profiles write to a protected system TCC database that takes priority over user grants. Don't manually grant FDA in System Settings if an MDM PPPC profile is in play — the MDM entry wins, and conflicts cause confusion. Use `tccutil reset` only in lab/test scenarios.

- **macOS 15 Sequoia tightened things further.** Some legacy extension patterns stopped working in Sequoia. Always test extension compatibility after major macOS upgrades in a staging group before broad rollout. Track vendor compatibility matrices for your security tools.
