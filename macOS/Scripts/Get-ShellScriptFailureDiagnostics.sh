#!/bin/bash
# Get-ShellScriptFailureDiagnostics.sh
# .SYNOPSIS
#   Collect Intune macOS shell-script execution health — agent presence, system extension
#   trust, execution context, architecture, and recent log evidence — for triage or escalation.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/Shell-Script-Failures-A.md and Shell-Script-Failures-B.md.
#   Gathers, in one pass, everything both runbooks' triage/diagnosis steps ask for:
#   - MDM enrollment and profile state (profiles status/list)
#   - Intune Agent / Intune Management Extension (IME) presence and running state — checks
#     BOTH known install locations and launchd labels referenced across the two runbooks
#     (/Library/PrivilegedHelperTools + com.microsoft.intune.agent, and
#     /Library/Intune/Microsoft Intune Agent.app), since agent naming/location has shifted
#     across Intune Agent versions and neither runbook alone reflects every fleet's install
#   - System extension trust state (systemextensionsctl) — the most common "Error" root cause
#   - Execution-context facts: current user/whoami, HOME, effective PATH as seen by this shell
#     vs. the minimal launchd PATH Intune actually uses (env -i simulation)
#   - Apple Silicon / Rosetta presence (arch, pgrep oahd) — Fix 6 in Shell-Script-Failures-B.md
#   - Disk space (script delivery/extraction can fail silently when full)
#   - Recent log evidence from BOTH known log surfaces: the on-disk agent log file
#     (/Library/Logs/Microsoft/Intune/intune_agent.log, referenced by the B runbook) and the
#     unified log subsystem (com.microsoft.intune, referenced by the A runbook) — greps both
#     for script/error/exit-code/timeout keywords so this works regardless of which log
#     surface the installed agent version actually writes to
#   - APNs reachability (gateway.push.apple.com) — required for MDM check-in to happen at all
#
#   Produces a console summary with pass/fail/info per check and exports full detail to CSV,
#   so the output can be pasted directly into either runbook's Escalation Evidence template.
#
#   Does NOT cover:
#   - Forcing an MDM check-in or re-triggering a "run once" script assignment (portal-side —
#     see Shell-Script-Failures-B.md Fix 2 / Fix 3)
#   - Actually running or testing the customer's own script (see both runbooks' "test manually"
#     steps — deliberately left manual since the script content/intent is unknown to this tool)
#   - Editing script assignments, run-as-context settings, or timeouts (portal-side)
#
# .REQUIREMENTS
#   - macOS 12+ (profiles/systemextensionsctl/log CLI behavior assumed for 12-15)
#   - Some profile and log checks are more complete run as root
#   - Run locally on the affected Mac (Terminal or SSH) — not deployable as an Intune shell
#     script itself, since its own output needs to be read interactively or pulled via MDM file-vault
#
# .EXAMPLE
#   bash Get-ShellScriptFailureDiagnostics.sh
#   sudo bash Get-ShellScriptFailureDiagnostics.sh
#
# .NOTES
#   Safe/read-only. Makes no profile, agent, or script changes. Does not trigger a check-in,
#   does not reset "run once" state, does not install Rosetta.
#   Tested on macOS 12-15, Apple Silicon and Intel.
#   CSV exported to /tmp/ShellScriptFailureDiagnostics_<hostname>_<timestamp>.csv

set -uo pipefail

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="/tmp/ShellScriptFailureDiagnostics_${HOSTNAME}_${TIMESTAMP}.csv"
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

echo "Check,Status,Detail" > "$CSV_FILE"

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
print_section() {
    echo ""
    echo "════════════════════════════════════════"
    echo "  $1"
    echo "════════════════════════════════════════"
}

record() {
    # record <CheckName> <OK|WARN|FAIL|INFO> <Detail>
    local check="$1" status="$2" detail="$3"
    case "$status" in
        OK)   echo "  [OK]   $check — $detail"; ((CHECKS_PASSED++)) ;;
        WARN) echo "  [WARN] $check — $detail"; ((CHECKS_WARNED++)) ;;
        FAIL) echo "  [FAIL] $check — $detail"; ((CHECKS_FAILED++)) ;;
        *)    echo "  [INFO] $check — $detail" ;;
    esac
    local safe_detail
    safe_detail=$(echo "$detail" | tr ',' ';')
    echo "\"$check\",\"$status\",\"$safe_detail\"" >> "$CSV_FILE"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo ""
        echo "  ⚠️  Not running as root. Some profile/log checks will be incomplete."
        echo "  Run: sudo bash $0"
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  Intune macOS Shell Script Failure Diagnostics"
echo "  Generated: $(date)"
echo "  Hostname:  $HOSTNAME"
echo "════════════════════════════════════════════════════════"

check_root

# ─────────────────────────────────────────────
# 1. MDM enrollment state
# ─────────────────────────────────────────────
print_section "1. MDM Enrollment State"

ENROLL_STATUS=$(profiles status -type enrollment 2>&1)
echo "  $ENROLL_STATUS"

if echo "$ENROLL_STATUS" | grep -qiE "MDM enrollment: Yes|Enrolled via DEP|^Enrolled"; then
    record "MDMEnrollment" "OK" "Device is MDM enrolled"
else
    record "MDMEnrollment" "FAIL" "Device is NOT MDM enrolled — no script can be delivered until re-enrolled"
fi

if echo "$ENROLL_STATUS" | grep -qi "Supervised: Yes"; then
    record "Supervision" "INFO" "Device is supervised"
else
    record "Supervision" "INFO" "Supervision state not confirmed Yes — not required for shell scripts, informational only"
fi

# ─────────────────────────────────────────────
# 2. Intune Agent / IME presence and running state
# ─────────────────────────────────────────────
print_section "2. Intune Agent / IME Presence"

AGENT_FOUND="no"

if [[ -e "/Library/Intune/Microsoft Intune Agent.app" ]]; then
    record "IMEAppBundle" "OK" "Found: /Library/Intune/Microsoft Intune Agent.app"
    AGENT_FOUND="yes"
else
    record "IMEAppBundle" "INFO" "Not found at /Library/Intune/Microsoft Intune Agent.app (may use a different install path/version)"
fi

if ls /Library/PrivilegedHelperTools/ 2>/dev/null | grep -qi intune; then
    record "PrivilegedHelperTool" "OK" "Intune helper tool present under /Library/PrivilegedHelperTools/"
    AGENT_FOUND="yes"
else
    record "PrivilegedHelperTool" "INFO" "No Intune entry under /Library/PrivilegedHelperTools/"
fi

LAUNCHCTL_ENTRIES=$(launchctl list 2>/dev/null | grep -i "microsoft.intune\|com.microsoft.intune")
if [[ -n "$LAUNCHCTL_ENTRIES" ]]; then
    echo "$LAUNCHCTL_ENTRIES"
    record "AgentLaunchdEntry" "OK" "Intune agent/IME registered with launchd"
    AGENT_FOUND="yes"
else
    record "AgentLaunchdEntry" "FAIL" "No Intune agent/IME launchd entry found — nothing will execute scripts on this device"
fi

if [[ "$AGENT_FOUND" == "no" ]]; then
    record "AgentOverall" "FAIL" "No evidence of Intune Agent/IME installed by any known method — assign any app or script to trigger auto-install, or reinstall via Company Portal"
else
    record "AgentOverall" "OK" "Intune Agent/IME present by at least one detection method"
fi

# ─────────────────────────────────────────────
# 3. System extension trust
# ─────────────────────────────────────────────
print_section "3. System Extension Trust"

SYSEXT=$(systemextensionsctl list 2>&1 | grep -i microsoft)
if [[ -n "$SYSEXT" ]]; then
    echo "  $SYSEXT"
    if echo "$SYSEXT" | grep -qi "activated enabled"; then
        record "SystemExtensionTrust" "OK" "Microsoft Intune Agent extension activated and enabled"
    elif echo "$SYSEXT" | grep -qi "waiting for user"; then
        record "SystemExtensionTrust" "FAIL" "Extension waiting for user approval — user must approve in System Settings > Privacy & Security > Extensions"
    else
        record "SystemExtensionTrust" "WARN" "Extension present but state unclear — review console output above"
    fi
else
    record "SystemExtensionTrust" "WARN" "No Microsoft system extension entry found — may be a version that doesn't use a system extension, or the agent isn't installed (see section 2)"
fi

# ─────────────────────────────────────────────
# 4. Execution context (root vs. user, PATH)
# ─────────────────────────────────────────────
print_section "4. Execution Context & PATH"

record "RunningAsUser" "INFO" "This diagnostic is running as: $(whoami)"
record "CurrentPATH" "INFO" "$PATH"

MINIMAL_PATH_TEST=$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin bash -c 'command -v brew python3 2>/dev/null')
if [[ -z "$MINIMAL_PATH_TEST" ]]; then
    record "MinimalPATHTools" "WARN" "brew/python3 NOT found under the minimal launchd-style PATH Intune uses — scripts calling these by bare name will fail with 'command not found' unless the script exports its own PATH"
else
    record "MinimalPATHTools" "OK" "Common tools resolve even under a minimal PATH: $MINIMAL_PATH_TEST"
fi

# ─────────────────────────────────────────────
# 5. Apple Silicon / Rosetta
# ─────────────────────────────────────────────
print_section "5. Architecture & Rosetta"

ARCH=$(/usr/bin/arch)
record "Architecture" "INFO" "$ARCH"

if [[ "$ARCH" == "arm64" ]]; then
    if /usr/bin/pgrep -q oahd; then
        record "Rosetta" "OK" "Rosetta is installed and running (oahd active)"
    else
        record "Rosetta" "WARN" "Apple Silicon Mac with Rosetta NOT running — scripts calling x86_64 binaries (older admin tools, Intel-path Homebrew) will fail silently. Install via: softwareupdate --install-rosetta --agree-to-license"
    fi
else
    record "Rosetta" "INFO" "Intel Mac — Rosetta not applicable"
fi

# ─────────────────────────────────────────────
# 6. Disk space
# ─────────────────────────────────────────────
print_section "6. Disk Space"

DISK_LINE=$(df -h / | tail -1)
echo "  $DISK_LINE"
DISK_PCT=$(echo "$DISK_LINE" | awk '{print $5}' | tr -d '%')
if [[ "$DISK_PCT" =~ ^[0-9]+$ ]] && [[ "$DISK_PCT" -ge 95 ]]; then
    record "DiskSpace" "FAIL" "Root volume ${DISK_PCT}% full — script delivery/extraction can fail when disk is nearly full"
else
    record "DiskSpace" "OK" "Root volume at ${DISK_PCT}% used"
fi

# ─────────────────────────────────────────────
# 7. APNs reachability (required for check-in)
# ─────────────────────────────────────────────
print_section "7. APNs Reachability"

APNS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://gateway.push.apple.com" 2>/dev/null)
if [[ -n "$APNS_CODE" && "$APNS_CODE" != "000" ]]; then
    record "APNsReachability" "OK" "gateway.push.apple.com reachable (HTTP $APNS_CODE — any response confirms TCP/TLS reachability, APNs does not serve normal HTTP)"
else
    record "APNsReachability" "FAIL" "gateway.push.apple.com unreachable — MDM check-in (and therefore script delivery) cannot happen without this; check firewall/proxy allow-list for Apple push ports"
fi

# ─────────────────────────────────────────────
# 8. Recent log evidence — both known log surfaces
# ─────────────────────────────────────────────
print_section "8. Recent Script Execution Log Evidence"

echo "  --- On-disk agent log (last 30 matching lines, if present) ---"
if [[ -f /Library/Logs/Microsoft/Intune/intune_agent.log ]]; then
    LOGFILE_MATCHES=$(grep -iE "shell script|exit code|error|failed|timeout|timed out" /Library/Logs/Microsoft/Intune/intune_agent.log 2>/dev/null | tail -30)
    if [[ -n "$LOGFILE_MATCHES" ]]; then
        echo "$LOGFILE_MATCHES"
        record "AgentLogFile" "INFO" "Found $(echo "$LOGFILE_MATCHES" | wc -l | tr -d ' ') matching lines in intune_agent.log — review for exit code / timeout detail"
    else
        record "AgentLogFile" "WARN" "intune_agent.log exists but no script/error/timeout keywords found in it — script may never have executed on this device"
    fi
else
    record "AgentLogFile" "INFO" "/Library/Logs/Microsoft/Intune/intune_agent.log not present — this agent version may log only to the unified log (see below)"
fi

echo ""
echo "  --- Unified log, subsystem com.microsoft.intune (last 2h, matching lines) ---"
UNIFIED_MATCHES=$(log show --predicate 'subsystem == "com.microsoft.intune"' --last 2h 2>/dev/null | grep -iE "script|exit code|error|fail|timeout" | tail -30)
if [[ -n "$UNIFIED_MATCHES" ]]; then
    echo "$UNIFIED_MATCHES"
    record "UnifiedLog" "INFO" "Found $(echo "$UNIFIED_MATCHES" | wc -l | tr -d ' ') matching lines in the unified log — review for exit code / timeout detail"
else
    record "UnifiedLog" "WARN" "No matching script/error/timeout entries in the unified log for the last 2h — either no recent script activity, or this agent version logs only to the on-disk file above"
fi

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
print_section "Summary"
printf "  %-20s %s\n" "Checks OK:"   "$CHECKS_PASSED"
printf "  %-20s %s\n" "Checks WARN:" "$CHECKS_WARNED"
printf "  %-20s %s\n" "Checks FAIL:" "$CHECKS_FAILED"
echo ""
if [[ "$CHECKS_FAILED" -eq 0 ]]; then
    echo "  Overall: No hard blockers found in agent/delivery/network layer — if a specific script still"
    echo "  fails, cross-reference the log evidence above against Shell-Script-Failures-A.md's Phase 3/4"
    echo "  (execution-context and exit-code logic issues), since those are script-content problems this"
    echo "  tool cannot evaluate on your behalf."
else
    echo "  Overall: Issues found — cross-reference FAIL/WARN checks against Shell-Script-Failures-B.md fix paths."
fi

echo ""
echo "  CSV report saved to: $CSV_FILE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  End of report — $(date)"
echo "════════════════════════════════════════════════════════"
