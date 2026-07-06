#!/bin/bash
# Get-SoftwareUpdateStatus.sh
# .SYNOPSIS
#   Collect macOS managed software update state — MDM policy, DDM status, deferrals, and Apple CDN
#   reachability — for triage or escalation.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/SoftwareUpdates-B.md.
#   Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
#   - Current OS version and build (sw_vers)
#   - MDM enrollment and supervision status (required for forced upgrades)
#   - Whether DDM (Declarative Device Management) or legacy MDM SoftwareUpdate payload is in use
#   - Managed preference values: enforcedSoftwareUpdateDelay, forceInstallDate / TargetLocalDateTime
#   - softwareupdate --list output (pending updates)
#   - Apple Software Update CDN reachability (swupd.apple.com, gdmf.apple.com) over HTTPS
#   - Basic SSL inspection detection (compares cert issuer against expected Apple chain)
#
#   Produces a console summary with pass/fail per check and exports full detail to CSV,
#   so the output can be pasted directly into the runbook's Escalation Evidence template.
#
#   Does NOT cover:
#   - Forcing an MDM check-in or triggering an install (that's SoftwareUpdates-B.md Fix 1 / Fix 2)
#   - Editing or assigning Intune update policies (that's Fix 1 Cause C — portal-side, not scriptable here)
#   - Fetching/staging a full macOS installer (that's Fix 5 — separate, disk-heavy operation)
#
# .REQUIREMENTS
#   - macOS 12+ (profiles/softwareupdate CLI behavior assumed for 12-15)
#   - Some profile enumeration checks are more complete run as root
#   - curl and openssl (both included in macOS base install)
#
# .EXAMPLE
#   bash Get-SoftwareUpdateStatus.sh
#   sudo bash Get-SoftwareUpdateStatus.sh
#
# .NOTES
#   Safe/read-only. Makes no policy, profile, or install changes. Does not trigger downloads
#   beyond small HTTPS HEAD-equivalent reachability checks to Apple's own CDN.
#   Tested on macOS 12-15, Apple Silicon and Intel.
#   CSV exported to /tmp/SoftwareUpdateStatus_<hostname>_<timestamp>.csv

set -uo pipefail

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="/tmp/SoftwareUpdateStatus_${HOSTNAME}_${TIMESTAMP}.csv"
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
        echo "  ⚠️  Not running as root. Some profile enumeration checks will be incomplete."
        echo "  Run: sudo bash $0"
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  macOS Managed Software Update Status Report"
echo "  Generated: $(date)"
echo "  Hostname:  $HOSTNAME"
echo "════════════════════════════════════════════════════════"

check_root

# ─────────────────────────────────────────────
# 1. Current OS version
# ─────────────────────────────────────────────
print_section "1. Current OS Version"

OS_VERSION=$(sw_vers -productVersion)
OS_BUILD=$(sw_vers -buildVersion)
echo "  macOS $OS_VERSION ($OS_BUILD)"
record "CurrentOSVersion" "INFO" "$OS_VERSION ($OS_BUILD)"

# ─────────────────────────────────────────────
# 2. MDM enrollment and supervision
# ─────────────────────────────────────────────
print_section "2. MDM Enrollment & Supervision"

ENROLL_STATUS=$(profiles status -type enrollment 2>&1)
echo "  $ENROLL_STATUS"

if echo "$ENROLL_STATUS" | grep -qi "MDM enrollment: Yes"; then
    record "MDMEnrollment" "OK" "Device is MDM enrolled"
else
    record "MDMEnrollment" "FAIL" "Device is NOT MDM enrolled — managed update policy cannot be delivered"
fi

if echo "$ENROLL_STATUS" | grep -qi "Supervised: Yes"; then
    record "Supervision" "OK" "Device is supervised — eligible for forced OS upgrades via MDM"
else
    record "Supervision" "WARN" "Device is NOT supervised — major OS upgrades can only be nudged, not forced; user must approve"
fi

# ─────────────────────────────────────────────
# 3. Update management method — DDM vs legacy MDM payload
# ─────────────────────────────────────────────
print_section "3. Update Management Method"

DDM_CHECK=$(profiles show -type enrollment 2>/dev/null | grep -i "declarative")
if [[ -n "$DDM_CHECK" ]]; then
    record "DDMActive" "OK" "Declarative Device Management is active"
else
    record "DDMActive" "INFO" "No explicit DDM indicator found — may still be using legacy MDM SoftwareUpdate payload"
fi

LEGACY_PAYLOAD=$(profiles show -type configuration 2>/dev/null | grep -A5 "PayloadType.*SoftwareUpdate")
if [[ -n "$LEGACY_PAYLOAD" ]]; then
    record "LegacyUpdatePayload" "OK" "Legacy SoftwareUpdate MDM payload found"
else
    record "LegacyUpdatePayload" "INFO" "No legacy SoftwareUpdate payload found"
fi

if [[ -z "$DDM_CHECK" && -z "$LEGACY_PAYLOAD" ]]; then
    record "UpdatePolicyPresence" "FAIL" "No update management method detected (neither DDM nor legacy payload) — no policy assigned to this device"
else
    record "UpdatePolicyPresence" "OK" "At least one update management method detected"
fi

# ─────────────────────────────────────────────
# 4. Managed preference values — deferral and deadline
# ─────────────────────────────────────────────
print_section "4. Deferral & Deadline Settings"

DEFER_DAYS=$(defaults read /Library/Managed\ Preferences/com.apple.SoftwareUpdate enforcedSoftwareUpdateDelay 2>/dev/null)
if [[ -n "$DEFER_DAYS" ]]; then
    record "DeferralDays" "INFO" "enforcedSoftwareUpdateDelay = $DEFER_DAYS day(s) from Apple release"
else
    record "DeferralDays" "INFO" "No deferral configured"
fi

FORCE_DATE=$(profiles show -type configuration 2>/dev/null | grep -i "forceInstallDate\|TargetLocalDateTime")
if [[ -n "$FORCE_DATE" ]]; then
    echo "  $FORCE_DATE"
    record "ForceInstallDeadline" "WARN" "A forced install deadline is configured — user should be notified before it passes"
else
    record "ForceInstallDeadline" "INFO" "No forced install deadline found in current profiles"
fi

# ─────────────────────────────────────────────
# 5. Pending updates (softwareupdate --list)
# ─────────────────────────────────────────────
print_section "5. Pending Updates"

SU_LIST=$(softwareupdate --list 2>&1)
echo "$SU_LIST"

if echo "$SU_LIST" | grep -qi "no new software"; then
    record "PendingUpdates" "OK" "No new software available"
elif echo "$SU_LIST" | grep -qi "error"; then
    record "PendingUpdates" "FAIL" "softwareupdate --list returned an error — check network/proxy reachability below"
else
    record "PendingUpdates" "WARN" "Update(s) available — see console output above"
fi

# ─────────────────────────────────────────────
# 6. Apple Software Update CDN reachability
# ─────────────────────────────────────────────
print_section "6. Apple Update Server Reachability"

check_endpoint() {
    local url="$1" name="$2"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null)
    if [[ "$http_code" == "200" ]]; then
        record "$name" "OK" "HTTP $http_code"
    elif [[ -z "$http_code" || "$http_code" == "000" ]]; then
        record "$name" "FAIL" "No response (timeout/DNS/firewall) — check proxy and outbound HTTPS to *.apple.com"
    else
        record "$name" "WARN" "HTTP $http_code (expected 200)"
    fi
}

check_endpoint "https://swupd.apple.com/index-10.15-10.16.merged-1.sucatalog" "SWUpdateCDN"
check_endpoint "https://gdmf.apple.com/v2/pmv" "GDMFVersionManifest"

# ─────────────────────────────────────────────
# 7. SSL inspection detection
# ─────────────────────────────────────────────
print_section "7. SSL Inspection Check"

CERT_ISSUER=$(echo | openssl s_client -connect swupd.apple.com:443 -servername swupd.apple.com 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)
if [[ -n "$CERT_ISSUER" ]]; then
    echo "  $CERT_ISSUER"
    if echo "$CERT_ISSUER" | grep -qi "apple"; then
        record "SSLInspection" "OK" "Certificate issuer is Apple — no inspection detected"
    else
        record "SSLInspection" "FAIL" "Certificate issuer is NOT Apple ($CERT_ISSUER) — corporate proxy is intercepting TLS to Apple's update CDN; this breaks software update"
    fi
else
    record "SSLInspection" "WARN" "Could not retrieve certificate — connection may be blocked entirely (see reachability checks above)"
fi

# ─────────────────────────────────────────────
# 8. System proxy configuration (informational)
# ─────────────────────────────────────────────
print_section "8. System Proxy Configuration"

PROXY_INFO=$(scutil --proxy 2>/dev/null | grep -E "HTTPEnable|HTTPSEnable|HTTPProxy|HTTPSProxy")
if [[ -n "$PROXY_INFO" ]]; then
    echo "$PROXY_INFO"
    record "SystemProxy" "INFO" "Proxy configuration present — see console output"
else
    record "SystemProxy" "INFO" "No system-wide proxy configured"
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
    echo "  Overall: Managed software update pipeline looks healthy on this device."
else
    echo "  Overall: Issues found — cross-reference FAIL/WARN checks against SoftwareUpdates-B.md fix paths."
fi

echo ""
echo "  CSV report saved to: $CSV_FILE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  End of report — $(date)"
echo "════════════════════════════════════════════════════════"
