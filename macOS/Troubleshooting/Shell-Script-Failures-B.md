# macOS Shell Script Failures — Hotfix Runbook (Mode B: Ops)
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

Run these on the affected Mac (Terminal or SSH) or pull from Intune logs:

```bash
# 1. Check MDM enrollment state
profiles status -type enrollment

# 2. View Intune management agent log (most recent 100 lines)
tail -100 /Library/Logs/Microsoft/Intune/intune_agent.log

# 3. Check script execution history in agent log
grep -i "shell script" /Library/Logs/Microsoft/Intune/intune_agent.log | tail -30

# 4. Check if script ran but failed
grep -E "(error|failed|exit code)" /Library/Logs/Microsoft/Intune/intune_agent.log | tail -20

# 5. Verify MDM agent daemon is running
launchctl list | grep -i microsoft
```

| What you see | What it means |
|---|---|
| `profiles status` shows no MDM enrollment | Device not enrolled — script can't run |
| Agent log: `Script failed with exit code X` | Script ran but logic failed — check exit code |
| Agent log: `Script timed out` | Script exceeded 60-min execution limit |
| Agent log: `Not assigned` or no script entries | Assignment filter mismatch or assignment not yet synced |
| `launchctl` shows agent not loaded | Intune management agent not running — restart it |
| Log shows `Script succeeded` but change not applied | Script ran, idempotency issue or wrong context (user vs. device) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
macOS Device
  └── Enrolled in Intune (ADE/BYOD/Manual)
        └── Intune Management Extension (IME) installed
              └── Microsoft Intune Management Agent daemon running
                    └── Device synced with Intune service
                          └── Script assigned (correct group filter)
                                └── Shell script: Run as account correct (device vs. user)
                                      └── Script not marked "Run once" after already executed
                                            └── Script logic executes cleanly (exit 0)
                                                  └── Change persists (not reverted by other config)
```

Key failure points:
- IME not installed (ARM devices, fresh ADE, or corrupted install)
- Script assigned to User group but set to run as System (or vice versa)
- "Run script as signed-in user" mismatch with script's root-required operations
- Script already ran "once" — Intune won't retry unless you reassign or toggle

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm IME is installed and running**
```bash
ls /Library/Intune/Microsoft\ Intune\ Agent.app/ 2>/dev/null && echo "IME installed" || echo "IME MISSING"
launchctl list com.microsoft.intune.agent 2>/dev/null || echo "Agent daemon NOT loaded"
```
Expected: `IME installed` + PID in launchctl output.  
Bad: Either missing — proceed to Fix 1.

**Step 2 — Check last sync time**
```bash
# In Intune portal → Devices → [device] → check "Last sync" timestamp
# On device:
defaults read /Library/Managed\ Preferences/com.microsoft.intune.plist 2>/dev/null | grep -i last
```
Expected: Sync within last 8 hours.  
Bad: Stale — trigger manual sync (Fix 2).

**Step 3 — Check script assignment**
In Intune portal: Shell Scripts → [script] → Properties → Assignments  
Confirm device or user group is listed. Check filter if any.

**Step 4 — Review script context setting**
Shell Scripts → [script] → Properties → Script settings  
Check: "Run script as signed-in user" — should match what the script does.  
Scripts needing `sudo` must run as device (not user).

**Step 5 — Check exit code in logs**
```bash
grep -A5 "ShellScriptManager" /Library/Logs/Microsoft/Intune/intune_agent.log | grep -E "(exit|error|success)" | tail -20
```
- Exit 0 = success
- Non-zero exit = script failure — investigate script logic
- No entry = script never ran (assignment/sync issue)

**Step 6 — Verify Rosetta (Apple Silicon only)**
```bash
# If script uses x86 binaries on ARM Mac
/usr/bin/arch
softwareupdate --install-rosetta --agree-to-license 2>/dev/null && echo "Rosetta installed"
```
Scripts calling x86 tools without Rosetta fail silently on M-series Macs.

**Step 7 — Test script manually**
```bash
# Run script as root to simulate device context
sudo bash /path/to/test-script.sh
echo "Exit code: $?"
```
This isolates Intune delivery issues from script logic issues.

---
## Common Fix Paths

<details><summary>Fix 1 — IME (Intune Management Extension) not installed or not running</summary>

**Cause:** IME missing, daemon not loaded, or corrupted install.

```bash
# Check if IME app exists
ls "/Library/Intune/Microsoft Intune Agent.app" 2>/dev/null || echo "NOT FOUND"

# Restart agent if installed but not running
sudo launchctl kickstart -k system/com.microsoft.intune.agent

# Check if it comes up
sleep 5 && launchctl list | grep -i microsoft.intune
```

If IME is missing entirely:
- In Intune portal: assign a shell script or a DMG app to the device — this triggers IME install
- Alternatively: Company Portal app install triggers IME
- IME auto-installs on first script/app assignment; it is not manually downloadable

**Verification:**
```bash
launchctl list com.microsoft.intune.agent | grep PID
```

</details>

<details><summary>Fix 2 — Script not syncing / stale assignment</summary>

**Cause:** Device hasn't checked in, or script assignment is new and device hasn't pulled it yet.

```bash
# Trigger manual MDM sync via Company Portal
# OR via command line (requires management privileges):
sudo profiles -N
```

In Intune portal:
- Devices → [device] → Sync (forces check-in)
- Wait 5–10 minutes, then check Shell Scripts → Device status

**Verification:** Re-check `intune_agent.log` for new script execution entries.

</details>

<details><summary>Fix 3 — "Run once" script won't re-execute</summary>

**Cause:** Script is set to run once and already executed (even if it failed). Intune records a "ran" state and won't retry.

**Fix — Force re-execution:**
1. Intune portal → Shell Scripts → [script] → Assignments → Remove assignment
2. Save. Wait 5 minutes.
3. Re-add assignment.
4. Sync device.

**OR — Toggle "Run as signed-in user" setting**  
Changing any script property resets run history.

**Rollback note:** No rollback needed — this only affects when the script next runs.

</details>

<details><summary>Fix 4 — Script failing due to wrong execution context</summary>

**Cause:** Script requires root but is set to "Run as signed-in user", or calls user-context items as root.

```bash
# Check who the script runs as by adding to script top:
echo "Running as: $(whoami)" >> /tmp/intune_script_debug.log
echo "HOME: $HOME" >> /tmp/intune_script_debug.log

# Then pull the log after next run:
cat /tmp/intune_script_debug.log
```

**Fix:** Intune portal → Shell Scripts → [script] → Script settings  
Toggle "Run script as signed-in user":
- `No` = runs as root (device context)
- `Yes` = runs as the logged-in user

Scripts that write to `/Library/`, modify system plists, or use `launchctl` at system level need root.  
Scripts that modify user preferences, keychain, or `~/Library/` need user context.

</details>

<details><summary>Fix 5 — Script times out (long-running operations)</summary>

**Cause:** Shell scripts in Intune have a hard 60-minute execution timeout. Scripts that hang, wait for network, or loop indefinitely are killed.

```bash
# Check log for timeout indicator
grep -i "timeout\|timed out\|exceeded" /Library/Logs/Microsoft/Intune/intune_agent.log | tail -10
```

**Fix options:**
1. Restructure script to exit early and use a LaunchDaemon for long operations
2. Add timeout guards to your script:
```bash
# Wrap long commands with timeout
timeout 300 /usr/bin/softwareupdate --all --install --force
if [ $? -eq 124 ]; then
    echo "Command timed out after 5 minutes" >&2
    exit 1
fi
```
3. Split large scripts into smaller sequential scripts

</details>

<details><summary>Fix 6 — Apple Silicon / Rosetta issues</summary>

**Cause:** Script calls x86_64 binaries that don't exist natively on ARM. Common with older admin tools, Homebrew paths, or hardcoded `/usr/local/bin/`.

```bash
# Check Mac architecture
/usr/bin/arch  # Returns arm64 or x86_64

# Check if Rosetta is installed
/usr/bin/pgrep -q oahd && echo "Rosetta running" || echo "Rosetta NOT installed"

# Install Rosetta via script (add to beginning of your Intune script)
if [[ "$(/usr/bin/arch)" == "arm64" ]]; then
    if ! /usr/bin/pgrep -q oahd; then
        /usr/sbin/softwareupdate --install-rosetta --agree-to-license
    fi
fi
```

**Path differences on ARM:**
| Context | Intel path | ARM path |
|---|---|---|
| Homebrew | `/usr/local/bin/brew` | `/opt/homebrew/bin/brew` |
| Python3 | `/usr/local/bin/python3` | `/opt/homebrew/bin/python3` |

Use `/usr/bin/which <tool>` in scripts instead of hardcoded paths.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — macOS Shell Script Failure

Device: ___________________________  (hostname)
Serial: ___________________________
macOS version: ____________________
Apple Silicon (Y/N): ______________
Intune device ID: _________________

Script name in Intune: ____________
Script last modified: _____________
Run as signed-in user: (Yes / No)
Run frequency: ____________________

Last sync timestamp: ______________
Last script run timestamp (from log): ___________
Exit code observed: _______________

Log excerpt (intune_agent.log):
---
[paste relevant lines here]
---

Manual test result (script run as sudo):
Exit code: ____
Output: ___________________________

IME running (Y/N): ________________
Rosetta installed (Y/N / N/A): ____

Steps already attempted:
[ ] Manual sync triggered
[ ] Script reassigned
[ ] Run context verified
[ ] Script tested manually as root
[ ] Rosetta checked (ARM only)
```

---
## 🎓 Learning Pointers

- **IME is the delivery vehicle:** The Intune Management Extension is what actually runs shell scripts on macOS. If it's not running, nothing works — always verify it first before diving into script logic. [IME docs](https://learn.microsoft.com/en-us/mem/intune/apps/macos-shell-scripts)
- **Exit codes matter:** Intune records success/failure based on exit code 0 vs non-zero. A script that "does nothing wrong" but exits 1 is logged as failed. Always `exit 0` on success.
- **Device vs. user context is a trap:** Root-required operations silently fail when run as the signed-in user. The failure mode isn't obvious from the log — always validate context first when logic looks correct.
- **"Run once" is sticky:** Once Intune records a run, it won't repeat even if the script was wrong. Reassigning is the standard reset mechanism — no need to delete and recreate the script.
- **ARM Macs break x86 scripts:** Any script written when the fleet was Intel may silently fail on M-series Macs. Add architecture checks to all scripts that use external binaries. [Universal binaries on Apple Silicon](https://developer.apple.com/documentation/apple-silicon/porting-your-macos-apps-to-apple-silicon)
- **60-minute timeout is a cliff:** There's no warning — the process is just killed. Long-running ops (full disk encryption enable, large package downloads) need LaunchDaemons, not Intune scripts.
