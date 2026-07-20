# macOS Compliance Policies — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **Intune-managed macOS compliance policies** — the mechanism by which a Mac device is evaluated against a set of rules and marked Compliant or NonCompliant. The result feeds directly into Entra ID Conditional Access, so a non-compliant Mac cannot reach protected resources until remediated.

**Assumes:**
- macOS enrolled via ADE (Apple Business / Apple School Manager) with Intune MDM
- Intune-managed apps or Platform SSO in use
- Conditional Access policy requires device compliance for at least one app
- Admin has Intune Admin or Intune Read-Only role

**Out of scope:** JAMF compliance integration (Compliance Partner), third-party UEM.

---

## How It Works

<details><summary>Full architecture</summary>

### Compliance Evaluation Flow

```
Device boots / check-in occurs
        │
        ▼
Intune MDM checkin (every 8h by default, or on-demand)
        │
        ▼
MDM evaluates compliance settings from assigned policy
        │
        ├── OS version check      → compares to minimum/maximum OS in policy
        ├── Password check        → reads local password policy state
        ├── Encryption check      → reads FileVault state via MDM
        ├── System Integrity Prot → reads SIP status (csrutil)
        ├── Secure Boot check     → reads startup security from bputil/nvram
        ├── Firewall check        → reads /usr/libexec/ApplicationFirewall/socketfilterfw
        ├── Gatekeeper check      → reads spctl --status
        └── Custom Attributes     → Shell script results surfaced to Intune
                │
                ▼
        Intune calculates Compliant / NonCompliant / Not Evaluated
                │
                ▼
        Result synced to Entra ID device object (complianceExpiryTime)
                │
                ▼
        Conditional Access evaluates compliance signal
                │
        ┌───────┴───────┐
        │               │
   Compliant         NonCompliant
   → Access OK       → Grace period (if configured)
                         │
                         └── After grace period → Block
```

### Grace Period Behaviour
Intune compliance has a **grace period** (default: 30 days for new policy, configurable). A device that first hits a new compliance policy gets this grace period before being blocked. During grace, the device shows "In grace period" in the portal but CA still allows access. After grace expires, if still non-compliant, CA blocks.

### Custom Attributes vs Compliance Settings
- **Compliance settings** are MDM-native checks that Intune evaluates automatically
- **Custom Attributes** are shell scripts (run as user or system) that return a string/integer/date; you then create a **custom compliance policy** in Intune that evaluates the returned value
- Custom Attributes require the Intune Management Extension (IME) — `com.microsoft.intuneMDMAgent`

### Policy Assignment and Precedence
- Compliance policies are assigned to **user groups** or **device groups**
- If a device has **no compliance policy** assigned, its compliance state is **Compliant by default** (controllable via tenant-wide setting: *Mark devices with no compliance policy assigned as*)
- If multiple compliance policies apply, a device must satisfy **all** of them

</details>

---

## Dependency Stack

```
Conditional Access (Entra ID)
        │
        └── requires device: Compliant
                │
                └── Intune Compliance Engine
                        │
                        ├── MDM Channel (APNs push → device check-in)
                        │       └── com.apple.mdm protocol
                        │
                        ├── Intune Management Extension (IME)
                        │       └── /Library/Intune/Microsoft Intune Agent.app
                        │       └── Required for: Custom Attributes, Shell Scripts
                        │
                        ├── Apple MDM-reported values
                        │       ├── FileVaultEnabled
                        │       ├── OSVersion
                        │       ├── PasscodePresent
                        │       ├── SIPEnabled
                        │       └── GatekeeperEnabled
                        │
                        └── Entra ID device object
                                └── complianceState (Compliant/NonCompliant)
                                └── complianceExpiryTime
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Device stuck "Not evaluated" for >24h | No compliance policy assigned, or device not checked in | Portal: Device → Compliance policies; IME logs |
| Device shows NonCompliant, user can't find reason | Multiple policies; one silent failure | Portal: Device → Compliance → each policy detail |
| Custom attribute returning wrong value | Script running as wrong context (user vs system) | IME agent logs: `/Library/Logs/Microsoft/Intune/` |
| Compliant in Intune, blocked by CA | Entra ID not yet synced, or CA checking wrong signal | `dsregcmd /status` equivalent; check sign-in logs |
| OS version check failing after upgrade | Compliance policy minimum not updated after new macOS GA | Compare policy vs actual OS version |
| FileVault compliant but still flagged | MDM hasn't received escrow key confirmation | Check FileVault escrow in Intune portal |
| Grace period expired, user suddenly blocked | Grace was hiding existing non-compliance | Audit grace period config; fix root cause |
| Password complexity failing | macOS local password policy not matching Intune policy | `pwpolicy -getaccountpolicies` |
| Secure Boot check failing | Legacy T2 or Intel Mac with non-default startup security | `bputil --display-all-policies` |
| Device reports wrong OS version | OS Beta enrolled or version string mismatch | MDM raw data in Intune portal |

---

## Validation Steps

**1. Confirm device is MDM-enrolled and checked in recently**
```bash
profiles status -type enrollment
# Expected: "MDM enrollment: Yes (User Approved)"
# Bad: Not enrolled, or Enrollment Type: Device
```

**2. Check IME (Intune Management Extension) is running**
```bash
sudo launchctl list | grep intune
# Expected: com.microsoft.intuneMDMAgent present with PID
# Bad: Not listed — IME not installed or crashed
```

**3. Check IME agent log for compliance evaluation errors**
```bash
tail -100 /Library/Logs/Microsoft/Intune/IntuneMDMDaemon*.log | grep -i "compliance\|error\|fail"
# Good: "Compliance evaluation completed: Compliant"
# Bad: Error codes, script timeout, attribute not found
```

**4. Verify FileVault state (MDM perspective)**
```bash
fdesetup status
# Expected: FileVault is On.
# Bad: FileVault is Off — triggers NonCompliant
```

**5. Verify SIP status**
```bash
csrutil status
# Expected: System Integrity Protection status: enabled.
# Bad: disabled (if policy requires SIP)
```

**6. Check Gatekeeper**
```bash
spctl --status
# Expected: assessments enabled
# Bad: assessments disabled
```

**7. Check macOS Firewall**
```bash
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
# Expected: Firewall is enabled. (State = 1)
# Bad: Firewall is disabled.
```

**8. Check Secure Boot (Apple Silicon)**
```bash
sudo bputil --display-all-policies
# Look for: Boot Policy: Full Security
# Bad: Reduced Security or Permissive Security
```

**9. Verify Entra ID compliance sync**
```bash
# On the Mac, check the Company Portal app:
# Open /Applications/Company Portal.app → Device Details → Compliance Status
# Or check sign-in logs in Entra ID: filter for device compliance failure
```

**10. Force manual compliance evaluation**
```bash
# Trigger MDM check-in:
sudo profiles -D 2>/dev/null; sudo profiles -I -F /tmp/placeholder 2>/dev/null
# Better: Open Company Portal → "Check Status" button
# Or from Intune portal: Device → Sync
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Identify which check is failing

1. Navigate to Intune portal: **Devices → macOS → [Device] → Compliance policies**
2. Click each assigned policy, review per-setting compliance detail
3. Note the exact setting that shows **Not compliant**
4. Cross-reference with Validation Steps above for that specific check

### Phase 2 — Verify MDM channel health

1. On the device, run `profiles status -type enrollment`
2. Confirm check-in timestamp is recent (Intune: Device → Overview → Last check-in)
3. If >8 hours: trigger manual sync from portal or Company Portal app
4. If sync doesn't help: check APNs certificate validity (Intune → Tenant Admin → Apple MDM Push Certificate)

### Phase 3 — Custom attribute / custom compliance issues

1. Navigate to Intune portal: **Devices → macOS → Shell scripts and custom attributes**
2. Find the custom attribute script → check **Device status** → look for error or "Not Assigned"
3. Check IME log on device:
   ```bash
   cat /Library/Logs/Microsoft/Intune/IntuneMDMDaemon-latest.log | grep -A5 "CustomAttribute"
   ```
4. Run the custom attribute script manually as the target context:
   ```bash
   # If running as user:
   sudo -u <username> /bin/zsh -c '<paste script content here>'
   # If running as system:
   sudo /bin/zsh -c '<paste script content here>'
   ```
5. Confirm the script output matches what the compliance rule expects (string, integer, date)

### Phase 4 — Grace period assessment

1. In Intune: **Endpoint security → Device compliance → Compliance policy settings**
2. Note "Mark devices with no compliance policy as": Compliant or Not Compliant
3. On the device's compliance page: check if "In grace period" is shown and when it expires
4. If grace expires soon: escalate to end-user to remediate or extend grace at tenant level

### Phase 5 — Conditional Access vs Intune sync lag

1. Check Entra ID sign-in logs: **Entra ID → Monitoring → Sign-in logs → [Failed sign-in]**
2. Look for: Failure reason "Device is not compliant" or "Device state unknown"
3. Compare: Intune shows Compliant, but Entra ID blocked? Wait 15-30 min for sync, or trigger sync manually
4. If persistent: check the Entra ID device object — navigate to **Entra ID → Devices → [Device]** and verify `isCompliant: true`

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — FileVault not enabled (compliance failure)</summary>

**Cause:** User bypassed FileVault prompt or it was deferred.

**Resolution:**
```bash
# Check current state
fdesetup status

# If off, enable FileVault (requires admin):
sudo fdesetup enable -user <username>
# This generates a personal recovery key
# Intune will escrow the key on next MDM check-in if policy is set
```

**Verify escrow:**
- Intune portal: **Device → Recovery keys → macOS FileVault key**
- If key is not escrowed, trigger device sync

**Rollback note:** FileVault encryption cannot be undone without full decryption. Ensure user is aware of the process time on large drives.

</details>

<details>
<summary>Playbook 2 — OS version below minimum</summary>

**Cause:** Device on older macOS; compliance policy requires newer version.

**Check current OS:**
```bash
sw_vers -productVersion
# e.g. 14.4.1
```

**Update via Software Update:**
```bash
# List available updates:
softwareupdate -l

# Install all recommended:
sudo softwareupdate -i -r --restart
```

**Or trigger via Intune:**
- Intune portal: **Devices → [Device] → Operating system updates → Update now**
- Requires macOS Software Update MDM profile with DDM (Declarative Device Management) for forced installs

**Post-update:** Trigger MDM sync; compliance re-evaluates automatically within 15 minutes of check-in.

</details>

<details>
<summary>Playbook 3 — SIP disabled (compliance failure)</summary>

**Cause:** SIP was disabled (usually for developer tooling) and policy requires it enabled.

**Re-enable SIP (requires Recovery Mode):**
1. Shut down Mac
2. Boot to Recovery (Apple Silicon: Hold power button; Intel: Cmd+R on boot)
3. Open Terminal from Utilities menu
4. Run: `csrutil enable`
5. Restart normally

**Verify:**
```bash
csrutil status
# Expected: System Integrity Protection status: enabled.
```

**Note:** This is a disruptive change. Confirm with user that no critical developer tools depend on SIP being off.

</details>

<details>
<summary>Playbook 4 — Custom attribute script failing</summary>

**Cause:** Script error, wrong user context, or dependency missing.

**Debug steps:**
```bash
# Check IME log for the attribute name:
grep -A10 "CustomAttribute\|ScriptError" /Library/Logs/Microsoft/Intune/IntuneMDMDaemon-latest.log

# Run script manually in the correct context:
sudo -u <current_user> /bin/zsh << 'EOF'
# Paste script content here
EOF

# Check exit code:
echo "Exit: $?"
```

**Common fixes:**
- Add `#!/bin/zsh` shebang if missing
- Ensure script returns output to stdout (not stderr)
- Check for path issues (`/usr/local/bin` not in PATH for system context) — use full paths
- Verify the attribute type in Intune matches the output (String vs Integer)

**After fixing script:** Re-upload to Intune → wait for next IME agent run (default: every 8h for custom attributes) or trigger via Company Portal sync.

</details>

<details>
<summary>Playbook 5 — Firewall disabled</summary>

**Enable macOS Application Firewall:**
```bash
# Enable firewall:
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on

# Verify:
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
# Expected: Firewall is enabled. (State = 1)
```

**Via Intune MDM profile:** Assign a device configuration profile with Firewall settings under **macOS → Templates → Endpoint Protection**.

</details>

---

## Evidence Pack

Run this script on the affected Mac to collect a full compliance evidence bundle:

```bash
#!/bin/zsh
# EZAdmin — macOS Compliance Evidence Collector
# Run as: sudo /bin/zsh collect-compliance.sh

OUTFILE="$HOME/Desktop/compliance-evidence-$(date +%Y%m%d-%H%M%S).txt"
echo "=== macOS Compliance Evidence Pack ===" > "$OUTFILE"
echo "Date: $(date)" >> "$OUTFILE"
echo "Host: $(hostname)" >> "$OUTFILE"
echo "User: $(logname)" >> "$OUTFILE"
echo "" >> "$OUTFILE"

echo "--- MDM Enrollment Status ---" >> "$OUTFILE"
profiles status -type enrollment >> "$OUTFILE" 2>&1

echo "" >> "$OUTFILE"
echo "--- macOS Version ---" >> "$OUTFILE"
sw_vers >> "$OUTFILE"

echo "" >> "$OUTFILE"
echo "--- FileVault Status ---" >> "$OUTFILE"
fdesetup status >> "$OUTFILE" 2>&1

echo "" >> "$OUTFILE"
echo "--- SIP Status ---" >> "$OUTFILE"
csrutil status >> "$OUTFILE" 2>&1

echo "" >> "$OUTFILE"
echo "--- Gatekeeper Status ---" >> "$OUTFILE"
spctl --status >> "$OUTFILE" 2>&1

echo "" >> "$OUTFILE"
echo "--- Firewall Status ---" >> "$OUTFILE"
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate >> "$OUTFILE" 2>&1

echo "" >> "$OUTFILE"
echo "--- IME Agent Running ---" >> "$OUTFILE"
sudo launchctl list | grep intune >> "$OUTFILE" 2>&1

echo "" >> "$OUTFILE"
echo "--- Password Policy ---" >> "$OUTFILE"
pwpolicy -getaccountpolicies 2>&1 | head -50 >> "$OUTFILE"

echo "" >> "$OUTFILE"
echo "--- Installed MDM Profiles ---" >> "$OUTFILE"
profiles -P -o stdout-xml 2>/dev/null | grep -E "PayloadType|PayloadDisplayName" | head -60 >> "$OUTFILE"

echo "" >> "$OUTFILE"
echo "--- Last 50 IME Log Lines ---" >> "$OUTFILE"
ls -t /Library/Logs/Microsoft/Intune/IntuneMDMDaemon*.log 2>/dev/null | head -1 | xargs tail -50 >> "$OUTFILE" 2>&1

echo "" >> "$OUTFILE"
echo "=== END ===" >> "$OUTFILE"
echo "Evidence written to: $OUTFILE"
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Check MDM enrollment | `profiles status -type enrollment` |
| Check FileVault state | `fdesetup status` |
| Check SIP state | `csrutil status` |
| Check Gatekeeper | `spctl --status` |
| Check Firewall | `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate` |
| List all MDM profiles | `profiles -P -o stdout-xml` |
| Check Secure Boot (AS) | `sudo bputil --display-all-policies` |
| Check password policy | `pwpolicy -getaccountpolicies` |
| Show IME processes | `sudo launchctl list \| grep intune` |
| Tail IME log | `tail -f /Library/Logs/Microsoft/Intune/IntuneMDMDaemon-latest.log` |
| List software updates | `softwareupdate -l` |
| Install all recommended updates | `sudo softwareupdate -i -r` |
| Check macOS version | `sw_vers -productVersion` |
| Show current user | `logname` |
| Trigger MDM checkin | Open Company Portal → Check Status |

---

## 🎓 Learning Pointers

- **Compliance vs Configuration Profiles:** Compliance policies in Intune *evaluate* a state; they do not *enforce* it. A compliance check for FileVault tells you if FileVault is on, but the *actual enablement* must be pushed via a Device Configuration profile or Endpoint Security policy. Always deploy both.

- **Entra ID sync lag is real:** Intune and Entra ID sync compliance state every 5–15 minutes. A device that just became compliant may still be blocked by CA for up to 15 minutes. Inform users to wait and retry before escalating.

- **Custom Attributes context matters critically:** Scripts running as the MDM daemon (system context) do not have access to user-space keychain or preferences. If your custom attribute script reads user preferences, it must run in user context. This is set per-attribute in Intune and cannot be mixed within one script.

- **"Not Evaluated" vs "NonCompliant":** *Not Evaluated* means the compliance engine hasn't run yet, or the device hasn't checked in. *NonCompliant* means the engine ran and a check failed. These require different remediation paths.

- **MS Docs — macOS compliance settings reference:** https://learn.microsoft.com/en-us/mem/intune/protect/compliance-policy-create-mac-os

- **MS Docs — Custom Compliance for macOS:** https://learn.microsoft.com/en-us/mem/intune/protect/compliance-use-custom-settings
