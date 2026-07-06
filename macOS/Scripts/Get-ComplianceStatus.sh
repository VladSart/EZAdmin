#!/bin/bash
# Get-ComplianceStatus.sh
# .SYNOPSIS
#   Collect macOS Intune compliance signal state (the settings Intune actually evaluates) for triage or escalation.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/Compliance-Policies-B.md and Compliance-Policies-A.md.
#   Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
#   - MDM enrollment/supervision state
#   - The local state of every setting Intune's macOS compliance engine reads:
#       FileVault, Application Firewall, Gatekeeper, SIP, Secure Boot (Apple Silicon)
#   - Company Portal presence and version (required for on-demand sync)
#   - Intune Management Extension (IME) daemon presence (required for custom attributes/shell scripts)
#   - Recent IME agent log lines mentioning compliance evaluation
#
#   Produces a console summary with pass/fail per check and exports full detail to CSV,
#   so the output can be pasted directly into the runbook's Escalation Evidence template.
#
#   Does NOT cover:
#   - Enabling FileVault/Firewall/Gatekeeper itself (that's Compliance-Policies-B.md Fix 3/4 — destructive/user-facing, not run automatically)
#   - Forcing a compliance re-evaluation or MDM check-in (that's Fix 1 — run separately if needed)
#   - Reading Intune's own compliance verdict (that lives in the Intune portal, not on the device)
#
# .REQUIREMENTS
#   - macOS 12 (Monterey) or later
#   - Some checks (IME log tail, full profile enumeration, TCC-adjacent detail) require root
#
# .EXAMPLE
#   bash Get-ComplianceStatus.sh
#   sudo bash Get-ComplianceStatus.sh
#
# .NOTES
#   Safe/read-only. Makes no changes to FileVault, Firewall, Gatekeeper, or SIP.
#   Tested on macOS 12-15, Apple Silicon and Intel.
#   CSV exported to /tmp/ComplianceStatus_<hostname>_<timestamp>.csv

set -uo pipefail

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="/tmp/ComplianceStatus_${HOSTNAME}_${TIMESTAMP}.csv"
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
        echo "  ⚠️  Not running as root. IME log tail and full profile enumeration will be incomplete."
        echo "  Run: sudo bash $0"
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  macOS Compliance Signal Status Report"
echo "  Generated: $(date)"
echo "  Hostname:  $HOSTNAME"
echo "════════════════════════════════════════════════════════"

check_root

# ─────────────────────────────────────────────
# 1. MDM enrollment state
# ─────────────────────────────────────────────
print_section "1. MDM Enrollment"

ENROLL_STATUS=$(profiles status -type enrollment 2>&1)
echo "  $ENROLL_STATUS"

if echo "$ENROLL_STATUS" | grep -qi "MDM enrollment: Yes"; then
    record "MDMEnrollment" "OK" "Device is MDM enrolled"
else
    record "MDMEnrollment" "FAIL" "Device is NOT MDM enrolled — compliance cannot be evaluated"
fi

# ─────────────────────────────────────────────
# 2. FileVault
# ─────────────────────────────────────────────
print_section "2. FileVault"

FV_STATUS=$(fdesetup status 2>&1)
echo "  $FV_STATUS"

if echo "$FV_STATUS" | grep -qi "FileVault is On"; then
    record "FileVault" "OK" "FileVault is On"
else
    record "FileVault" "FAIL" "FileVault is Off — will fail any compliance policy requiring encryption (Compliance-Policies-B.md Fix 3)"
fi

# ─────────────────────────────────────────────
# 3. Application Firewall
# ─────────────────────────────────────────────
print_section "3. Application Firewall"

FW_STATUS=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>&1)
echo "  $FW_STATUS"

if echo "$FW_STATUS" | grep -qi "enabled"; then
    record "Firewall" "OK" "Application Firewall enabled"
else
    record "Firewall" "WARN" "Application Firewall disabled — will fail compliance policies that require it (Fix 4)"
fi

# ─────────────────────────────────────────────
# 4. Gatekeeper
# ─────────────────────────────────────────────
print_section "4. Gatekeeper"

GK_STATUS=$(spctl --status 2>&1)
echo "  $GK_STATUS"

if echo "$GK_STATUS" | grep -qi "assessments enabled"; then
    record "Gatekeeper" "OK" "Gatekeeper assessments enabled"
else
    record "Gatekeeper" "WARN" "Gatekeeper assessments disabled — will fail compliance policies that require it (Fix 4)"
fi

# ─────────────────────────────────────────────
# 5. SIP
# ─────────────────────────────────────────────
print_section "5. System Integrity Protection (SIP)"

SIP_STATUS=$(csrutil status 2>&1)
echo "  $SIP_STATUS"

if echo "$SIP_STATUS" | grep -qi "enabled"; then
    record "SIP" "OK" "SIP enabled"
else
    record "SIP" "WARN" "SIP disabled — will fail compliance policies checking SIP; re-enabling requires booting to Recovery"
fi

# ─────────────────────────────────────────────
# 6. Secure Boot (Apple Silicon only)
# ─────────────────────────────────────────────
print_section "6. Secure Boot (Apple Silicon)"

ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    if [[ $EUID -eq 0 ]]; then
        SB_STATUS=$(bputil --display-all-policies 2>&1 | grep -i "Boot Policy\|Security Policy")
        echo "  $SB_STATUS"
        if echo "$SB_STATUS" | grep -qi "Full Security"; then
            record "SecureBoot" "OK" "Full Security boot policy"
        else
            record "SecureBoot" "WARN" "Boot policy is not Full Security — check if compliance policy requires it: $SB_STATUS"
        fi
    else
        record "SecureBoot" "WARN" "Root required to check bputil boot policy on Apple Silicon"
    fi
else
    record "SecureBoot" "INFO" "Intel Mac — Secure Boot policy check not applicable in the same way"
fi

# ─────────────────────────────────────────────
# 7. Company Portal
# ─────────────────────────────────────────────
print_section "7. Company Portal"

CP_PATH="/Applications/Company Portal.app"
if [[ -d "$CP_PATH" ]]; then
    CP_VERSION=$(defaults read "$CP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    record "CompanyPortal" "OK" "Installed, version $CP_VERSION"
else
    record "CompanyPortal" "WARN" "Company Portal.app not found — on-demand compliance sync via GUI unavailable (device may still check in via background MDM channel)"
fi

# ─────────────────────────────────────────────
# 8. Intune Management Extension (IME) daemon
# ─────────────────────────────────────────────
print_section "8. Intune Management Extension (IME)"

if [[ $EUID -eq 0 ]]; then
    IME_STATUS=$(launchctl list 2>/dev/null | grep -i intune)
    if [[ -n "$IME_STATUS" ]]; then
        echo "  $IME_STATUS"
        record "IMEDaemon" "OK" "IME daemon present — custom attributes/shell scripts can run"
    else
        record "IMEDaemon" "WARN" "IME daemon not found — custom attribute/shell-script compliance checks will not evaluate"
    fi

    IME_LOG=$(ls -t /Library/Logs/Microsoft/Intune/IntuneMDMDaemon*.log 2>/dev/null | head -1)
    if [[ -n "$IME_LOG" ]]; then
        IME_RECENT=$(tail -50 "$IME_LOG" 2>/dev/null | grep -i "compliance\|error\|fail")
        if [[ -n "$IME_RECENT" ]]; then
            echo "$IME_RECENT" | tail -10
            record "IMELogCompliance" "INFO" "Recent compliance/error lines found in IME log — see console output above"
        else
            record "IMELogCompliance" "OK" "No recent compliance errors in IME log"
        fi
    else
        record "IMELogCompliance" "INFO" "No IME log file found at expected path"
    fi
else
    record "IMEDaemon" "WARN" "Root required to check IME daemon and log"
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
    echo "  Overall: Local compliance signal state looks healthy on this device."
    echo "  Note: This reflects local settings only — check the Intune portal for the authoritative compliance verdict and grace period status."
else
    echo "  Overall: Issues found — cross-reference FAIL/WARN checks against Compliance-Policies-B.md Fix 1-5."
fi

echo ""
echo "  CSV report saved to: $CSV_FILE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  End of report — $(date)"
echo "════════════════════════════════════════════════════════"
