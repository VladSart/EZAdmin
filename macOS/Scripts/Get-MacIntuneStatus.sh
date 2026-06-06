#!/bin/bash
# Get-MacIntuneStatus.sh
# .SYNOPSIS
#   Collect macOS Intune/MDM enrollment and compliance status for triage and escalation.
#
# .DESCRIPTION
#   Gathers MDM enrollment state, Intune Management Extension (IME) status,
#   device compliance signals, recent script execution logs, and hardware info.
#   Outputs a structured report to stdout and saves to /tmp/MacIntuneStatus_<hostname>.txt
#   Safe to run — read-only, no changes made to the system.
#
# .REQUIREMENTS
#   - macOS 11 (Big Sur) or later
#   - Run as root for full log access: sudo bash Get-MacIntuneStatus.sh
#   - Works without root but some sections will be incomplete
#
# .EXAMPLE
#   sudo bash Get-MacIntuneStatus.sh
#   sudo bash Get-MacIntuneStatus.sh 2>/dev/null | tee ~/Desktop/intune_report.txt
#
# .NOTES
#   Safe/read-only. No modifications made.
#   Tested on macOS 12–15, Intel and Apple Silicon.
#   For IME log access, sudo is required.

set -euo pipefail

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
REPORT_FILE="/tmp/MacIntuneStatus_${HOSTNAME}_$(date +%Y%m%d_%H%M%S).txt"
IME_LOG="/Library/Logs/Microsoft/Intune/intune_agent.log"
LOG_LINES=50

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
print_section() {
    echo ""
    echo "════════════════════════════════════════"
    echo "  $1"
    echo "════════════════════════════════════════"
}

print_ok()   { echo "  [OK]   $1"; }
print_warn() { echo "  [WARN] $1"; }
print_info() { echo "  [INFO] $1"; }
print_fail() { echo "  [FAIL] $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo ""
        echo "  ⚠️  Not running as root. Some sections will be incomplete."
        echo "  Run: sudo bash $0"
        echo ""
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────

# Redirect output to both stdout and file
exec > >(tee "$REPORT_FILE") 2>&1

echo "════════════════════════════════════════════════════════"
echo "  macOS Intune Status Report"
echo "  Generated: $(date)"
echo "  Hostname:  $HOSTNAME"
echo "════════════════════════════════════════════════════════"

check_root

# ─────────────────────────────────────────────
# 1. Hardware & OS Info
# ─────────────────────────────────────────────
print_section "1. Hardware & OS"

HW_MODEL=$(system_profiler SPHardwareDataType 2>/dev/null | awk '/Model Name/{print $NF}' || echo "Unknown")
HW_SERIAL=$(system_profiler SPHardwareDataType 2>/dev/null | awk '/Serial Number/{print $NF}' || echo "Unknown")
OS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "Unknown")
OS_BUILD=$(sw_vers -buildVersion 2>/dev/null || echo "Unknown")
ARCH=$(/usr/bin/arch)

print_info "Model:         $HW_MODEL"
print_info "Serial:        $HW_SERIAL"
print_info "macOS:         $OS_VERSION ($OS_BUILD)"
print_info "Architecture:  $ARCH"

# Check Rosetta on ARM
if [[ "$ARCH" == "arm64" ]]; then
    if /usr/bin/pgrep -q oahd 2>/dev/null; then
        print_ok "Rosetta 2: Installed and running"
    else
        print_warn "Rosetta 2: NOT installed (ARM Mac — some scripts may fail)"
    fi
fi

# ─────────────────────────────────────────────
# 2. MDM Enrollment Status
# ─────────────────────────────────────────────
print_section "2. MDM Enrollment"

PROFILES_STATUS=$(profiles status -type enrollment 2>/dev/null || echo "profiles command failed")
echo "$PROFILES_STATUS"

# Check if enrolled
if echo "$PROFILES_STATUS" | grep -qi "MDM enrollment: Yes"; then
    print_ok "Device is MDM enrolled"
elif echo "$PROFILES_STATUS" | grep -qi "enrolled"; then
    print_ok "Device appears enrolled (check output above)"
else
    print_fail "Device does NOT appear to be MDM enrolled"
fi

# Check user-approved enrollment
if echo "$PROFILES_STATUS" | grep -qi "User Approved"; then
    print_ok "Enrollment type: User Approved MDM"
elif echo "$PROFILES_STATUS" | grep -qi "DEP"; then
    print_ok "Enrollment type: ADE/DEP (Automated)"
else
    print_warn "Enrollment type: Could not determine (check output above)"
fi

# ─────────────────────────────────────────────
# 3. Installed MDM Profiles
# ─────────────────────────────────────────────
print_section "3. MDM Configuration Profiles"

if [[ $EUID -eq 0 ]]; then
    PROFILE_COUNT=$(profiles -P 2>/dev/null | grep "attribute: name:" | wc -l | tr -d ' ')
    print_info "Total profiles installed: $PROFILE_COUNT"

    echo ""
    echo "  Profile names:"
    profiles -P 2>/dev/null | grep "attribute: name:" | sed 's/.*name: /    - /' | head -20

    # Check for Intune-specific profiles
    if profiles -P 2>/dev/null | grep -qi "Intune\|Microsoft"; then
        print_ok "Microsoft/Intune profiles present"
    else
        print_warn "No Microsoft/Intune profiles found"
    fi
else
    print_warn "Root required — run sudo for profile details"
    profiles -P 2>/dev/null | grep "attribute: name:" | head -10 | sed 's/.*name: /    - /' || true
fi

# ─────────────────────────────────────────────
# 4. Intune Management Extension (IME)
# ─────────────────────────────────────────────
print_section "4. Intune Management Extension (IME)"

IME_APP="/Library/Intune/Microsoft Intune Agent.app"
IME_BINARY="${IME_APP}/Contents/MacOS/IntuneMdmAgent"

if [[ -d "$IME_APP" ]]; then
    print_ok "IME app installed at: $IME_APP"
    IME_VERSION=$(defaults read "${IME_APP}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "Unknown")
    print_info "IME version: $IME_VERSION"
else
    print_fail "IME app NOT found at expected path"
    print_warn "Shell scripts and LOB apps will not deploy"
fi

# Check daemon
IME_DAEMON="com.microsoft.intune.agent"
if launchctl list "$IME_DAEMON" 2>/dev/null | grep -q PID; then
    IME_PID=$(launchctl list "$IME_DAEMON" 2>/dev/null | grep '"PID"' | awk '{print $3}' | tr -d ';' || echo "?")
    print_ok "IME daemon running (PID: $IME_PID)"
else
    print_fail "IME daemon NOT running ($IME_DAEMON)"
    echo "  Fix: sudo launchctl kickstart -k system/com.microsoft.intune.agent"
fi

# Check Company Portal
CP_APP="/Applications/Company Portal.app"
if [[ -d "$CP_APP" ]]; then
    CP_VERSION=$(defaults read "${CP_APP}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "Unknown")
    print_ok "Company Portal installed (v$CP_VERSION)"
else
    print_warn "Company Portal NOT installed"
fi

# ─────────────────────────────────────────────
# 5. IME Log — Recent Activity
# ─────────────────────────────────────────────
print_section "5. IME Log (Recent Activity)"

if [[ -f "$IME_LOG" ]]; then
    print_ok "IME log found: $IME_LOG"
    print_info "Last modified: $(stat -f '%Sm' "$IME_LOG" 2>/dev/null || ls -la "$IME_LOG" | awk '{print $6, $7, $8}')"

    echo ""
    echo "  ── Last $LOG_LINES lines ──"
    tail -$LOG_LINES "$IME_LOG" 2>/dev/null | sed 's/^/  /'

    echo ""
    echo "  ── Script execution entries ──"
    grep -i "shell script\|ShellScript\|script.*exit\|script.*success\|script.*fail" "$IME_LOG" 2>/dev/null | tail -20 | sed 's/^/  /' || print_info "No script entries found in log"

    echo ""
    echo "  ── Errors / Warnings ──"
    grep -iE "(error|warning|failed|timeout)" "$IME_LOG" 2>/dev/null | tail -15 | sed 's/^/  /' || print_info "No errors/warnings found"
else
    if [[ $EUID -ne 0 ]]; then
        print_warn "IME log not accessible — run as sudo"
    else
        print_fail "IME log not found at: $IME_LOG"
        print_warn "IME may never have run on this device"
    fi
fi

# ─────────────────────────────────────────────
# 6. Network Connectivity (Intune endpoints)
# ─────────────────────────────────────────────
print_section "6. Network — Key Intune Endpoints"

ENDPOINTS=(
    "manage.microsoft.com"
    "enrollment.manage.microsoft.com"
    "fef.msua06.manage.microsoft.com"
    "login.microsoftonline.com"
    "graph.microsoft.com"
)

for endpoint in "${ENDPOINTS[@]}"; do
    if /usr/bin/nc -z -w3 "$endpoint" 443 2>/dev/null; then
        print_ok "$endpoint :443 reachable"
    else
        print_fail "$endpoint :443 UNREACHABLE"
    fi
done

# ─────────────────────────────────────────────
# 7. FileVault Status
# ─────────────────────────────────────────────
print_section "7. FileVault (Encryption)"

if [[ $EUID -eq 0 ]]; then
    FV_STATUS=$(fdesetup status 2>/dev/null || echo "Unknown")
    echo "  $FV_STATUS"

    if echo "$FV_STATUS" | grep -qi "On"; then
        print_ok "FileVault is enabled"
    else
        print_warn "FileVault is NOT enabled — may affect compliance"
    fi
else
    FV_STATUS=$(fdesetup status 2>/dev/null || echo "Root required")
    print_info "$FV_STATUS"
fi

# ─────────────────────────────────────────────
# 8. System Integrity Protection (SIP)
# ─────────────────────────────────────────────
print_section "8. System Integrity Protection (SIP)"

SIP_STATUS=$(csrutil status 2>/dev/null || echo "Unknown")
echo "  $SIP_STATUS"

if echo "$SIP_STATUS" | grep -qi "enabled"; then
    print_ok "SIP is enabled"
elif echo "$SIP_STATUS" | grep -qi "disabled"; then
    print_warn "SIP is DISABLED — security concern, may affect MDM behaviour"
fi

# ─────────────────────────────────────────────
# 9. Local Admin Account Check
# ─────────────────────────────────────────────
print_section "9. Local Users & Admin Accounts"

echo "  Local user accounts:"
dscl . list /Users | grep -v "^_\|daemon\|nobody\|root" | while read user; do
    IS_ADMIN=$(dscl . read /Groups/admin GroupMembership 2>/dev/null | grep -w "$user" && echo "ADMIN" || echo "standard")
    printf "    %-20s %s\n" "$user" "$IS_ADMIN"
done

# ─────────────────────────────────────────────
# 10. Summary
# ─────────────────────────────────────────────
print_section "10. Quick Summary"

# Re-check key states for summary
MDM_ENROLLED=$(profiles status -type enrollment 2>/dev/null | grep -qi "enrolled" && echo "YES" || echo "NO")
IME_RUNNING=$(launchctl list com.microsoft.intune.agent 2>/dev/null | grep -q PID && echo "YES" || echo "NO")
FV_ON=$(fdesetup status 2>/dev/null | grep -qi "On" && echo "YES" || echo "NO")
SIP_ON=$(csrutil status 2>/dev/null | grep -qi "enabled" && echo "YES" || echo "NO")

printf "  %-30s %s\n" "MDM Enrolled:"        "$MDM_ENROLLED"
printf "  %-30s %s\n" "IME Running:"          "$IME_RUNNING"
printf "  %-30s %s\n" "FileVault Enabled:"    "$FV_ON"
printf "  %-30s %s\n" "SIP Enabled:"          "$SIP_ON"
printf "  %-30s %s\n" "Architecture:"         "$ARCH"
printf "  %-30s %s\n" "macOS Version:"        "$OS_VERSION"

echo ""
echo "  Report saved to: $REPORT_FILE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  End of report — $(date)"
echo "════════════════════════════════════════════════════════"
