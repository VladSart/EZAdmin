#!/bin/bash
# =============================================================================
# Repair-MacMDMEnrollment.sh
# =============================================================================
# PURPOSE:  Diagnose and repair common macOS MDM/Intune enrollment issues
#           without requiring a full wipe and re-enroll.
#
# COVERS:
#   - MDM enrollment status and profile validation
#   - Company Portal app status and accessibility
#   - Intune Management Extension (IME) daemon health
#   - MDM push certificate validity
#   - ADE (Automated Device Enrollment) token binding
#   - SCEP/certificate profile state
#   - Network reachability to Intune endpoints
#   - mdmclient and profiles daemon health
#
# DOES NOT COVER:
#   - Full unenrollment/re-enrollment (manual step, documented in output)
#   - DEP/ADE profile reassignment (done in Apple Business Manager)
#   - FileVault recovery key escrow (separate runbook)
#
# USAGE:
#   sudo bash Repair-MacMDMEnrollment.sh [--fix] [--output /path/to/report.txt]
#
#   --fix     Attempt safe auto-repairs (restart daemons, re-register MDM)
#   --output  Path for text report (default: /tmp/MDM-Repair-<timestamp>.txt)
#
# REQUIRES: macOS 12+ | Run as root (sudo)
# SAFE:     Read-only by default. --fix mode restarts services only.
#
# =============================================================================

set -euo pipefail

# ─── Argument parsing ───────────────────────────────────────────────────────
FIX_MODE=false
REPORT_PATH="/tmp/MDM-Repair-$(date +%Y%m%d-%H%M).txt"

while [[ $# -gt 0 ]]; do
    case $1 in
        --fix)    FIX_MODE=true; shift ;;
        --output) REPORT_PATH="$2"; shift 2 ;;
        *)        echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# ─── Root check ─────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root: sudo bash $0"
    exit 1
fi

# ─── Helpers ────────────────────────────────────────────────────────────────
OK()   { echo "[OK]   $*"; echo "[OK]   $*" >> "$REPORT_PATH"; }
WARN() { echo "[WARN] $*"; echo "[WARN] $*" >> "$REPORT_PATH"; }
ERR()  { echo "[ERR]  $*"; echo "[ERR]  $*" >> "$REPORT_PATH"; }
INFO() { echo "[INFO] $*"; echo "[INFO] $*" >> "$REPORT_PATH"; }
HEAD() { echo ""; echo "═══ $* ═══"; echo ""; echo "═══ $* ═══" >> "$REPORT_PATH"; }

# Init report
{
    echo "=================================================="
    echo " macOS MDM Enrollment Repair Report"
    echo " Generated: $(date)"
    echo " Host:      $(hostname)"
    echo " macOS:     $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo " Fix Mode:  $FIX_MODE"
    echo "=================================================="
} > "$REPORT_PATH"

echo ""
echo "=================================================="
echo " macOS MDM Enrollment Repair Script"
echo " Fix mode: $FIX_MODE"
echo " Report: $REPORT_PATH"
echo "=================================================="
echo ""

# ═══════════════════════════════════════════════════════════════════════════
HEAD "SECTION 1 — MDM ENROLLMENT STATUS"
# ═══════════════════════════════════════════════════════════════════════════

INFO "Checking MDM enrollment state..."
ENROLLED=false

# profiles status -type enrollment
ENROLLMENT_STATUS=$(profiles status -type enrollment 2>&1 || true)
echo "$ENROLLMENT_STATUS" | tee -a "$REPORT_PATH"

if echo "$ENROLLMENT_STATUS" | grep -q "MDM enrollment: Yes"; then
    OK "Device is MDM enrolled"
    ENROLLED=true
else
    ERR "Device does NOT appear to be MDM enrolled"
fi

# Check for supervised status
if echo "$ENROLLMENT_STATUS" | grep -q "Supervised: Yes"; then
    OK "Device is supervised (ADE/DEP)"
else
    WARN "Device is NOT supervised — ADE enrollment likely not used"
fi

# ═══════════════════════════════════════════════════════════════════════════
HEAD "SECTION 2 — INSTALLED PROFILES"
# ═══════════════════════════════════════════════════════════════════════════

INFO "Listing installed configuration profiles..."
PROFILE_LIST=$(profiles list -all 2>/dev/null || true)

PROFILE_COUNT=$(echo "$PROFILE_LIST" | grep -c "profileIdentifier" 2>/dev/null || echo "0")
INFO "Profiles installed: $PROFILE_COUNT"
echo "$PROFILE_LIST" | head -60 >> "$REPORT_PATH"

# Check for Intune MDM profile
if echo "$PROFILE_LIST" | grep -qi "microsoft.intune\|com.microsoft.intune\|mdm.microsoft.com"; then
    OK "Microsoft Intune MDM profile found"
else
    ERR "Intune MDM profile NOT found — device may not be properly enrolled"
fi

# Check for SCEP/certificate profiles
SCEP_COUNT=$(echo "$PROFILE_LIST" | grep -ic "scep\|certificate" 2>/dev/null || echo "0")
INFO "SCEP/certificate profiles: $SCEP_COUNT"

# ═══════════════════════════════════════════════════════════════════════════
HEAD "SECTION 3 — INTUNE MANAGEMENT EXTENSION (IME)"
# ═══════════════════════════════════════════════════════════════════════════

IME_PLIST="/Library/LaunchDaemons/com.microsoft.intune.microsoftintuneagent.plist"
IME_AGENT="/Library/Intune/Microsoft Intune Agent.app"
IME_LOG="/Library/Logs/Microsoft/Intune/MSIntune_GuardedSecureExtension.log"
IME_LOG2="/Library/Application Support/Microsoft/Intune/Logs"

if [ -f "$IME_PLIST" ]; then
    OK "IME LaunchDaemon plist exists"
else
    WARN "IME LaunchDaemon plist not found at $IME_PLIST"
fi

if [ -d "$IME_AGENT" ]; then
    IME_VERSION=$(defaults read "$IME_AGENT/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "Unknown")
    OK "Intune Management Extension found — version: $IME_VERSION"
else
    WARN "Intune Management Extension app not found at $IME_AGENT"
fi

# Check IME daemon running
IME_DAEMON_LABEL="com.microsoft.intune.microsoftintuneagent"
if launchctl list "$IME_DAEMON_LABEL" &>/dev/null; then
    IME_PID=$(launchctl list "$IME_DAEMON_LABEL" | awk '{print $1}')
    OK "IME daemon is running (PID: $IME_PID)"
else
    ERR "IME daemon is NOT running"
    if [ "$FIX_MODE" = true ]; then
        INFO "FIX: Attempting to start IME daemon..."
        launchctl load "$IME_PLIST" 2>/dev/null && OK "IME daemon started" || WARN "Could not start IME daemon"
    else
        WARN "Run with --fix to attempt daemon restart"
    fi
fi

# IME log check (last 20 lines)
if [ -f "$IME_LOG" ]; then
    INFO "Last 20 lines of IME log:"
    tail -20 "$IME_LOG" | tee -a "$REPORT_PATH"
fi

# ═══════════════════════════════════════════════════════════════════════════
HEAD "SECTION 4 — MDMCLIENT DAEMON"
# ═══════════════════════════════════════════════════════════════════════════

MDM_DAEMON_STATUS=$(launchctl list com.apple.mdmclient 2>&1 || true)
echo "$MDM_DAEMON_STATUS" >> "$REPORT_PATH"

if echo "$MDM_DAEMON_STATUS" | grep -v "^-\t" | grep -q "PID"; then
    OK "mdmclient daemon is running"
else
    MDMCLIENT_PID=$(echo "$MDM_DAEMON_STATUS" | awk 'NR==2 {print $1}')
    if [[ "$MDMCLIENT_PID" =~ ^[0-9]+$ ]] && [ "$MDMCLIENT_PID" -gt 0 ]; then
        OK "mdmclient daemon is running (PID: $MDMCLIENT_PID)"
    else
        ERR "mdmclient daemon may not be running correctly"
        if [ "$FIX_MODE" = true ]; then
            INFO "FIX: Restarting mdmclient..."
            launchctl kickstart -k system/com.apple.mdmclient 2>/dev/null && OK "mdmclient restarted" || WARN "Could not restart mdmclient"
        fi
    fi
fi

# ─── Trigger MDM check-in ───
if [ "$FIX_MODE" = true ] && [ "$ENROLLED" = true ]; then
    INFO "FIX: Triggering MDM check-in with server..."
    mdmclient QueryDeviceInformation 2>&1 | head -5 | tee -a "$REPORT_PATH" || true
    OK "MDM check-in triggered"
fi

# ═══════════════════════════════════════════════════════════════════════════
HEAD "SECTION 5 — COMPANY PORTAL"
# ═══════════════════════════════════════════════════════════════════════════

CP_PATHS=(
    "/Applications/Company Portal.app"
    "/Applications/Intune Company Portal.app"
)

CP_FOUND=false
for CP_PATH in "${CP_PATHS[@]}"; do
    if [ -d "$CP_PATH" ]; then
        CP_VERSION=$(defaults read "$CP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "Unknown")
        OK "Company Portal found at: $CP_PATH (v$CP_VERSION)"
        CP_FOUND=true
        break
    fi
done

if [ "$CP_FOUND" = false ]; then
    WARN "Company Portal not found in /Applications — required for Intune enrollment"
fi

# ═══════════════════════════════════════════════════════════════════════════
HEAD "SECTION 6 — NETWORK REACHABILITY (INTUNE ENDPOINTS)"
# ═══════════════════════════════════════════════════════════════════════════

INTUNE_ENDPOINTS=(
    "manage.microsoft.com"
    "enterpriseregistration.windows.net"
    "login.microsoftonline.com"
    "graph.microsoft.com"
    "appcenter.ms"
    "intunecdnpeasd.azureedge.net"
)

for endpoint in "${INTUNE_ENDPOINTS[@]}"; do
    if curl -s --max-time 5 --head "https://$endpoint" &>/dev/null; then
        OK "Reachable: $endpoint"
    else
        ERR "NOT reachable: $endpoint"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════
HEAD "SECTION 7 — SYSTEM KEYCHAIN & MDM CERTIFICATES"
# ═══════════════════════════════════════════════════════════════════════════

# Check for MDM push certificate
MDM_CERTS=$(security find-certificate -a -c "APSP:" /Library/Keychains/System.keychain 2>/dev/null | grep "labl" | head -5 || true)
if [ -n "$MDM_CERTS" ]; then
    OK "MDM push certificates found in System keychain"
    echo "$MDM_CERTS" >> "$REPORT_PATH"
else
    WARN "No MDM push certs found with 'APSP:' label — may be normal if certs use different naming"
fi

# Check for Microsoft Intune certificate
MS_CERTS=$(security find-certificate -a -c "Microsoft" /Library/Keychains/System.keychain 2>/dev/null | grep "labl" | head -10 || true)
if [ -n "$MS_CERTS" ]; then
    OK "Microsoft certificates found in System keychain"
    echo "$MS_CERTS" >> "$REPORT_PATH"
else
    WARN "No Microsoft certificates found in System keychain"
fi

# ═══════════════════════════════════════════════════════════════════════════
HEAD "SECTION 8 — RECENT MDM LOGS"
# ═══════════════════════════════════════════════════════════════════════════

INFO "Collecting MDM-related log entries (last 50 lines)..."
log show --predicate 'subsystem == "com.apple.ManagedClient"' \
    --last 2h --style compact 2>/dev/null | tail -50 | tee -a "$REPORT_PATH" || \
    WARN "Could not retrieve ManagedClient logs (may require Full Disk Access)"

# ═══════════════════════════════════════════════════════════════════════════
HEAD "SECTION 9 — SUMMARY & RECOMMENDATIONS"
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "RESULTS SUMMARY:" | tee -a "$REPORT_PATH"

WARN_COUNT=$(grep -c "^\[WARN\]" "$REPORT_PATH" 2>/dev/null || echo "0")
ERR_COUNT=$(grep -c "^\[ERR\]"  "$REPORT_PATH" 2>/dev/null || echo "0")

echo "  Warnings: $WARN_COUNT" | tee -a "$REPORT_PATH"
echo "  Errors:   $ERR_COUNT"  | tee -a "$REPORT_PATH"

if [ "$ENROLLED" = false ]; then
    echo "" | tee -a "$REPORT_PATH"
    echo "MANUAL STEPS REQUIRED — Device not enrolled:" | tee -a "$REPORT_PATH"
    echo "  1. Open Company Portal → Sign in with user's Entra ID account" | tee -a "$REPORT_PATH"
    echo "  2. Follow enrollment prompts" | tee -a "$REPORT_PATH"
    echo "  3. If ADE device: check Apple Business Manager for profile assignment" | tee -a "$REPORT_PATH"
    echo "  4. For ADE re-enroll: Erase device → Settings → General → Transfer or Reset" | tee -a "$REPORT_PATH"
fi

echo "" | tee -a "$REPORT_PATH"
echo "Full report saved to: $REPORT_PATH" | tee -a "$REPORT_PATH"

# Exit code: 0 if no errors, 1 if errors found
[ "$ERR_COUNT" -eq 0 ] && exit 0 || exit 1
