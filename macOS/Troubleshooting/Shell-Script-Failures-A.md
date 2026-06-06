# macOS Intune Shell Script Failures — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Shell scripts deployed via Microsoft Intune (macOS shell scripts feature)
- Script delivery, execution, and result reporting via Intune MDM channel
- macOS system extension and daemon trust (Microsoft Intune Agent)
- Shebang issues, permission errors, and script exit code misinterpretation
- Custom Attributes (script-based) reporting failures

**Out of scope:**
- Declarative Device Management (DDM) configuration items (separate channel from shell scripts)
- macOS apps deployment failures (see: `macOS/Troubleshooting/ADE-Enrollment-A.md` for enrollment context)
- Intune Remediations on macOS (different execution channel — see `Intune/Troubleshooting/Remediations-A.md`)

**Assumptions:**
- Device is enrolled via ADE or User-Initiated Enrollment (UIE) and supervised
- macOS version 12.0 (Monterey) or later (Intune shell scripts require macOS 10.15+, recommended 12+)
- Microsoft Intune Company Portal AND Microsoft Intune Agent are installed
- Engineer has SSH or Terminal access, or can push a diagnostic script via Intune

---

## How It Works

<details><summary>Full architecture</summary>

Intune shell scripts on macOS are delivered and executed through a specific channel that is completely separate from configuration profiles:

```
Intune Cloud Service
└── MDM Push Notification (APNs)
    └── macOS MDM Client (mdmclient)
        └── CheckIn → Shell Script Assignment Fetched
            └── Microsoft Intune Agent (IntuneMdmAgent)
                ├── Downloads script from Intune CDN (encrypted, signed)
                ├── Writes to temp location: /tmp/ or similar
                ├── Executes script as:
                │   ├── Root context (Run as account: System) — default
                │   │   └── Launched as root via launchd
                │   └── User context (Run as account: User)
                │       └── Launched as logged-in user via launchd user session
                ├── Captures stdout + stderr
                ├── Reads exit code
                └── Reports result back to Intune
                    ├── Exit 0 = Success
                    ├── Exit non-0 = Failure
                    └── Timeout (default: 15 min) = Failure
```

**Key execution constraints:**

| Constraint | Detail |
|------------|--------|
| Max script size | 200KB |
| Execution timeout | 15 minutes (hard kill) |
| Max retries | Configurable: 1–3 (applied on failure, not on "Not applicable") |
| Execution context | Root OR logged-in user (not both) |
| Shell | Defined by shebang (`#!/bin/bash`, `#!/bin/zsh`, etc.) — default bash |
| Output capture | First 256KB of stdout/stderr reported to Intune |
| Frequency | Once, or on each check-in (per policy setting) |
| Supervision required | NO for basic scripts, YES for some MDM commands |

**Check-in frequency:** macOS MDM check-in is every 8 hours by default (not instant). Scripts can also be triggered manually via `sudo /Library/PrivilegedHelperTools/com.microsoft.intune.agent.mdmagent` or Intune Company Portal sync.

**Result states in Intune:**

| State | Meaning |
|-------|---------|
| `Success` | Script exited 0 |
| `Failed` | Script exited non-0, or timed out |
| `Pending` | Not yet executed (MDM check-in not happened) |
| `Not applicable` | Device not in scope for assignment |
| `Error` | Script could not be delivered or launched |

**Why "Error" differs from "Failed":**
- `Error` = delivery/launch failure (permissions, agent crash, network issue)
- `Failed` = script ran but exited non-0 or timed out

</details>

---

## Dependency Stack

```
Microsoft Intune Service (cloud)
└── Apple APNs (Push Notification Service)
    └── macOS APNs enrollment token (must be valid; MDM profile present)
        └── mdmclient (macOS MDM daemon)
            └── MDM check-in: https://manage.microsoft.com & apple.com APNs
                └── Microsoft Intune Agent (com.microsoft.intune.agent)
                    ├── Must be installed: /Library/PrivilegedHelperTools/
                    ├── System Extension trusted in System Settings > Privacy & Security
                    └── Script execution via launchd
                        ├── Root context: /bin/sh, /bin/bash, /bin/zsh
                        └── User context: active GUI session required
                            └── Exit code → Intune result reporting
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Script status stuck on "Pending" forever | MDM check-in not happening; APNs issue | `sudo /usr/bin/profiles status -type enrollment`; Company Portal sync |
| Script shows "Error" (not "Failed") | Intune Agent not installed or crashed | Check Agent in Applications/Utilities; check system extension |
| Script shows "Failed" but manual run succeeds | Execution context difference (root vs user); PATH issues | Test script with `sudo` explicitly; check PATH in script |
| Script shows "Success" but effect didn't apply | Script exited 0 even on error (missing `set -e`); logic flaw | Review script exit handling; add explicit `exit 1` on failures |
| Script fails with "command not found" | `/usr/local/bin` or Homebrew paths not in root's PATH | Use absolute paths in script; add `export PATH` at top |
| Script fails silently — no output in Intune | Script redirecting stderr to /dev/null; output exceeds 256KB | Fix stderr redirect; split script into smaller units |
| User context script never runs | No active GUI session on device (headless/kiosk) | Change to root context; ensure user is logged in |
| Script was run once, now won't re-run | "Run script only once" setting is ON | Change frequency to "Every check-in"; delete and re-assign |
| Custom Attributes always show "Not applicable" | Device not in Custom Attributes assignment scope | Check Custom Attribute assignment groups |
| Script fails on specific macOS version | API or path change in newer macOS | Add OS version check at top of script |

---

## Validation Steps

**Step 1 — Confirm MDM enrollment is active**
```bash
sudo /usr/bin/profiles status -type enrollment
sudo /usr/bin/profiles list -type configuration
```
**Good output:** `MDM enrollment: Enrolled via DEP` or `Enrolled` and Intune profile present in list
**Bad output:** `MDM enrollment: Not enrolled` — device lost MDM trust; re-enroll

---

**Step 2 — Confirm Intune Agent is running**
```bash
sudo /bin/launchctl list | grep -i intune
ls -la /Library/PrivilegedHelperTools/ | grep -i intune
```
**Good output:** `com.microsoft.intune.agent.mdmagent` or similar appears in launchctl list, agent binary exists
**Bad output:** Nothing returned — agent not installed or not running

---

**Step 3 — Check Intune Agent system extension trust**
```bash
systemextensionsctl list | grep -i microsoft
```
**Good output:** Microsoft Intune Agent extension listed with `[activated enabled]`
**Bad output:** `[waiting for user]` or not listed — needs user approval in System Settings

---

**Step 4 — Force MDM check-in and watch logs**
```bash
# Trigger manual check-in
sudo /usr/bin/profiles -e -type enrollment
# Then watch real-time logs for script-related messages
log stream --predicate 'subsystem == "com.microsoft.intune"' --level debug 2>&1 | head -100
```
**Good output:** Log entries showing check-in and script download/execution
**Bad output:** No Intune log entries — agent not running or not registered with system log

---

**Step 5 — Manually test the script in matching context**
```bash
# To test as root (matching system context):
sudo bash /path/to/your-script.sh
echo "Exit code: $?"

# To test as logged-in user (matching user context):
bash /path/to/your-script.sh
echo "Exit code: $?"

# To test with limited PATH (matching Intune agent context):
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin bash /path/to/your-script.sh
echo "Exit code: $?"
```
**Good output:** Exit code 0, expected effect applied
**Bad output:** Non-zero exit, "command not found" errors — identify and fix before re-deploying

---

**Step 6 — Check script logs and agent logs**
```bash
# Intune agent log location (varies by version):
ls -la ~/Library/Logs/Microsoft/
ls -la /Library/Logs/Microsoft/Intune/

# Or use unified log:
log show --predicate 'subsystem == "com.microsoft.intune"' --last 1h | grep -i "script\|error\|fail"
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Script Never Executes (Pending / No Status)

1. Confirm device is enrolled (Step 1)
2. Trigger Company Portal sync: open Company Portal > Devices > select device > Sync
3. Force MDM check-in (Step 4)
4. Verify script assignment — is the device in the target group? Check Entra group membership
5. Check if script has "Run script only once" enabled and was previously marked Success — delete assignment and re-add to reset

### Phase 2: Script Shows "Error" State

1. Confirm Intune Agent is installed and running (Step 2)
2. Check system extension trust (Step 3) — if `[waiting for user]`, the user must approve in System Settings > Privacy & Security > Extensions
3. Check if APNs connectivity is working: `curl -I https://gateway.push.apple.com`
4. Reinstall Intune Agent via Company Portal if binary missing
5. Check disk space — agent extraction of script temp files can fail if disk is full

### Phase 3: Script Shows "Failed" but Works Manually

1. Identify the execution context mismatch:
   - Root context: no GUI, no user home directory, no Keychain, no user defaults
   - User context: requires active GUI session; fails on headless devices
2. Test with `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin bash script.sh` (Step 5) to simulate limited environment
3. Add explicit PATH at top of script: `export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"`
4. Replace all relative paths with absolute paths
5. If script uses Homebrew (`/usr/local/bin/brew` or `/opt/homebrew/bin/brew`) — these are NOT available in root context without explicit PATH

### Phase 4: Script Shows "Success" but Did Nothing

1. Review script exit code logic — if script uses `||`, `&&`, or subshells, exit code may not propagate correctly
2. Add `set -e` at top to exit on first error
3. Add explicit `exit 1` in all error branches
4. Test with `echo $?` after each critical command
5. Remember: Intune only sees exit code — it does NOT evaluate whether the script's intended effect was achieved

---

## Remediation Playbooks

<details><summary>Fix 1 — Reinstall Microsoft Intune Agent</summary>

```bash
# Check current version
defaults read /Applications/Company\ Portal.app/Contents/Info.plist CFBundleShortVersionString

# Download latest Intune Agent from Microsoft:
# https://aka.ms/intune-macosagent

# Or install via Intune: assign the "Microsoft Intune Agent" app package to the device group
# The agent package is available in Intune > Apps > Add > macOS app (PKG)

# After install, verify:
sudo /bin/launchctl list | grep -i intune
systemextensionsctl list | grep -i microsoft
```

**Note:** If system extension shows `[waiting for user]`, guide user to approve:
System Settings > Privacy & Security > scroll to "Extensions" section > enable Microsoft Intune

</details>

---

<details><summary>Fix 2 — Script template with robust error handling for Intune deployment</summary>

```bash
#!/bin/bash
# ============================================================
# Script name: <YourScriptName>.sh
# Description: <What this script does>
# Context:     System (root) / User (specify which)
# Version:     1.0
# ============================================================

set -e          # Exit on any command failure
set -u          # Treat unset variables as errors
set -o pipefail # Catch failures in pipes

# Ensure consistent PATH for Intune context
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

# Logging function
LOG_FILE="/tmp/intune-script-$(date +%Y%m%d-%H%M%S).log"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "Script starting. Running as: $(whoami)"
log "macOS version: $(sw_vers -productVersion)"

# --- Your logic here ---
# Example: create a file
TARGET="/Library/MyOrg/config.txt"
mkdir -p "$(dirname "$TARGET")" || { log "ERROR: Could not create directory"; exit 1; }
echo "configured=$(date)" > "$TARGET" || { log "ERROR: Could not write config file"; exit 1; }
log "Config file written: $TARGET"

# Always exit explicitly
log "Script completed successfully."
exit 0
```

**Key rules:**
- `set -e` ensures non-zero command exits stop the script
- Always use `exit 0` (success) or `exit 1` (failure) explicitly
- Log to `/tmp/` — readable by support; cleared on reboot
- Use absolute paths for all commands

</details>

---

<details><summary>Fix 3 — Reset "run only once" script to re-execute</summary>

The Intune portal does not have a "reset" button for script execution state. To force re-execution:

1. Go to Intune > Devices > macOS > Shell scripts
2. Select the script
3. Click **Delete** the assignment (not the script itself)
4. Wait 1–2 minutes
5. Re-add the assignment with the same or updated group

**Alternative:** Duplicate the script with a minor comment change (e.g., `# v2`) — this creates a new script object with fresh execution tracking.

**If "Run script only once" is the problem:** Edit the script settings and change frequency to **"Every check-in"** — this allows re-execution on each MDM check-in (every 8 hours).

</details>

---

<details><summary>Fix 4 — Collect Intune Agent diagnostic logs for escalation</summary>

```bash
#!/bin/bash
# Collect Intune shell script diagnostic data

OUT="/tmp/intune-script-diag-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

# MDM enrollment status
/usr/bin/profiles status -type enrollment > "$OUT/enrollment-status.txt" 2>&1
/usr/bin/profiles list -type configuration >> "$OUT/enrollment-status.txt" 2>&1

# Intune agent processes
ps aux | grep -i intune > "$OUT/intune-processes.txt"

# System extensions
systemextensionsctl list > "$OUT/system-extensions.txt" 2>&1

# Intune logs (last 2 hours)
log show --predicate 'subsystem == "com.microsoft.intune"' --last 2h \
    > "$OUT/intune-log-2h.txt" 2>&1

# MDM logs
log show --predicate 'subsystem == "com.apple.mdmclient"' --last 2h \
    > "$OUT/mdm-log-2h.txt" 2>&1

# System info
sw_vers > "$OUT/system-info.txt"
uname -a >> "$OUT/system-info.txt"
whoami >> "$OUT/system-info.txt"

# Archive
tar -czf "/tmp/intune-diag-$(hostname)-$(date +%Y%m%d).tar.gz" -C /tmp "$(basename $OUT)"
echo "Diagnostics saved: /tmp/intune-diag-$(hostname)-$(date +%Y%m%d).tar.gz"
```

</details>

---

## Evidence Pack

```bash
#!/bin/bash
# Intune Shell Script Evidence Collector
# Run this on the affected Mac (as admin or via Intune itself)

REPORT="/tmp/ShellScript-Evidence-$(date +%Y%m%d-%H%M%S).txt"

{
echo "=== INTUNE SHELL SCRIPT EVIDENCE PACK ==="
echo "Hostname   : $(hostname)"
echo "macOS      : $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "Arch       : $(uname -m)"
echo "Collected  : $(date)"
echo "Running as : $(whoami)"
echo ""

echo "--- MDM Enrollment Status ---"
/usr/bin/profiles status -type enrollment 2>&1
echo ""

echo "--- Enrolled MDM Profiles ---"
/usr/bin/profiles list -type configuration 2>&1 | grep -E "ProfileDisplayName|ProfileIdentifier|Microsoft|Intune"
echo ""

echo "--- Intune Agent Processes ---"
ps aux | grep -i "[i]ntune" 2>&1
echo ""

echo "--- System Extensions ---"
systemextensionsctl list 2>&1 | grep -i microsoft
echo ""

echo "--- Intune Launchd Daemons ---"
/bin/launchctl list 2>&1 | grep -i "microsoft\|intune"
echo ""

echo "--- Intune Log (last 30 min) ---"
log show --predicate 'subsystem == "com.microsoft.intune"' --last 30m 2>&1 | tail -50
echo ""

echo "--- MDM Client Log (last 30 min) ---"
log show --predicate 'subsystem == "com.apple.mdmclient"' --last 30m 2>&1 | grep -i "script\|error\|fail" | tail -30
echo ""

echo "--- Disk Space ---"
df -h /
echo ""

} | tee "$REPORT"

echo ""
echo "Evidence written to: $REPORT"
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check MDM enrollment | `sudo /usr/bin/profiles status -type enrollment` |
| List all MDM profiles | `sudo /usr/bin/profiles list -type configuration` |
| Force MDM check-in | `sudo /usr/bin/profiles -e -type enrollment` |
| Check Intune Agent processes | `ps aux \| grep -i intune` |
| Check system extensions | `systemextensionsctl list \| grep -i microsoft` |
| List Intune launchd entries | `/bin/launchctl list \| grep -i "microsoft\|intune"` |
| Stream Intune live logs | `log stream --predicate 'subsystem == "com.microsoft.intune"' --level debug` |
| Check macOS version | `sw_vers` |
| Check disk space | `df -h /` |
| Test script as root | `sudo bash /path/to/script.sh; echo "Exit: $?"` |
| Test with minimal PATH | `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin bash /path/to/script.sh` |
| Check script result in Intune | Intune > Devices > macOS > Shell scripts > [script] > Device status |
| Check Custom Attribute results | Intune > Devices > macOS > Custom attributes > [attribute] > Device status |
| APNs connectivity test | `curl -I https://gateway.push.apple.com` |
| View Company Portal logs | `open ~/Library/Logs/Microsoft/` |

---

## 🎓 Learning Pointers

- **The most common script failure cause is PATH.** When Intune runs a script as root, it uses a minimal launchd environment — `/usr/local/bin`, Homebrew (`/opt/homebrew/bin`), and other user-added paths are NOT in PATH. Scripts that work perfectly in Terminal fail silently via Intune because `brew`, `python3`, or other tools aren't found. The fix is always: add `export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"` at the top of every script. [MS Docs: Shell scripts on macOS](https://learn.microsoft.com/en-us/mem/intune/apps/macos-shell-scripts)

- **Exit code 0 means "success" to Intune — even if your script did nothing useful.** Intune has no way to evaluate whether a script's *intent* was achieved. If your script has error handling that catches exceptions but doesn't `exit 1`, Intune will report Success while the actual configuration was never applied. Always write explicit `exit 0` / `exit 1` in every code path, and use `set -e` to propagate subcommand failures automatically.

- **User context scripts require an active GUI session.** If you deploy a user-context script and the device is at the login screen, locked, or headless, the script will not run — it stays Pending until a user logs in. For configurations that don't need user context (file writes, system settings, daemon installs), always use System context. Use User context only when you genuinely need access to user-specific resources like `~/Library/Preferences` or the user's Keychain.

- **The 15-minute timeout is ruthless.** Intune kills the script process after 15 minutes with no warning. If your script installs a large package, runs `softwareupdate`, or does anything time-consuming, it will be killed and reported as Failed. For long-running operations, structure the script to trigger a background process (`nohup ... &`) and exit 0 — then use a separate Custom Attribute script to check the result on the next check-in cycle. [MS Docs: Script limitations](https://learn.microsoft.com/en-us/mem/intune/apps/macos-shell-scripts#script-limitations)

- **Intune Agent and Company Portal are separate binaries with separate roles.** Company Portal handles user-facing enrollment and is the UI users see. The Intune Agent (MDM Agent) is the system daemon that actually executes shell scripts, custom attributes, and some compliance checks. If shell scripts are broken but app installs work, the Agent is the problem — not Company Portal. Check them independently: `systemextensionsctl list | grep microsoft` for the Agent, `ps aux | grep "Company Portal"` for the Portal.

- **Custom Attributes are a different execution path from Shell Scripts.** Custom Attributes run as a separate script type on a separate schedule and have their own device status reporting page. If a Custom Attribute always shows "Not applicable," check that the device is in the Custom Attribute assignment group — it's completely separate from the Shell Script assignment group even if they look similar in the Intune UI. [MS Docs: Custom attributes for macOS](https://learn.microsoft.com/en-us/mem/intune/apps/macos-custom-attributes)
