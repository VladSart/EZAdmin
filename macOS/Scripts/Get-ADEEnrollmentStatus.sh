#!/bin/bash
# Get-ADEEnrollmentStatus.sh
# .SYNOPSIS
#   Collect Automated Device Enrollment (ADE/DEP) health data from a Mac for triage or escalation.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/ADE-Enrollment-B.md and ADE-Enrollment-A.md.
#   Runs client-side checks the runbook's triage and diagnosis steps ask for:
#   - MDM enrollment state and whether it was completed via DEP/ADE (supervised)
#   - IsMDMUnremovable flag (confirms locked/supervised profile from ADE)
#   - Bootstrap Token escrow (only available on ADE-enrolled, supervised devices)
#   - Reachability of required Apple activation/ADE endpoints (albert.apple.com, captive.apple.com)
#   - Reachability of required Microsoft Intune enrollment endpoints
#   - Recent com.apple.ManagedClient log entries (errors/failures only)
#
#   Produces a console summary with pass/fail per check and exports full detail to CSV,
#   so the output can be pasted directly into the runbook's Escalation Evidence template.
#
#   Does NOT cover:
#   - Server-side checks (ADE token expiry, APNS cert expiry, ABM device assignment) —
#     those must be checked in Intune portal / Apple Business Manager, see ADE-Enrollment-B.md Fix 1-3
#   - Forcing re-enrollment or erasing the device
#
# .REQUIREMENTS
#   - macOS 11 (Big Sur) or later
#   - Run as root for full detail: sudo bash Get-ADEEnrollmentStatus.sh
#   - Network checks require outbound HTTPS; some corporate proxies may skew results
#
# .EXAMPLE
#   sudo bash Get-ADEEnrollmentStatus.sh
#   sudo bash Get-ADEEnrollmentStatus.sh 2>/dev/null | tee ~/Desktop/ade_report.txt
#
# .NOTES
#   Safe/read-only. No modifications made, no re-enrollment triggered.
#   Tested on macOS 12–15, Intel and Apple Silicon.
#   CSV exported to /tmp/ADEEnrollmentStatus_<hostname>_<timestamp>.csv

set -uo pipefail

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="/tmp/ADEEnrollmentStatus_${HOSTNAME}_${TIMESTAMP}.csv"
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

ADE_ENDPOINTS=(
    "albert.apple.com"
    "captive.apple.com"
    "gs.apple.com"
    "identity.apple.com"
)

INTUNE_ENDPOINTS=(
    "enrollment.manage.microsoft.com"
    "manage.microsoft.com"
    "login.microsoftonline.com"
    "graph.microsoft.com"
)

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
        echo "  ⚠️  Not running as root. Profile/log detail will be incomplete."
        echo "  Run: sudo bash $0"
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  ADE / DEP Enrollment Status Report"
echo "  Generated: $(date)"
echo "  Hostname:  $HOSTNAME"
echo "════════════════════════════════════════════════════════"

check_root

# ─────────────────────────────────────────────
# 1. MDM Enrollment State
# ─────────────────────────────────────────────
print_section "1. MDM Enrollment State"

ENROLL_STATUS=$(sudo profiles status -type enrollment 2>&1)
echo "  $ENROLL_STATUS"

if echo "$ENROLL_STATUS" | grep -qi "MDM enrollment: Yes"; then
    record "MDMEnrolled" "OK" "Device is MDM enrolled"
else
    record "MDMEnrolled" "FAIL" "Device is NOT MDM enrolled"
fi

if echo "$ENROLL_STATUS" | grep -qi "Enrolled via DEP: Yes"; then
    record "EnrolledViaDEP" "OK" "Enrolled via ADE/DEP (supervised, automated)"
elif echo "$ENROLL_STATUS" | grep -qi "User Approved: Yes"; then
    record "EnrolledViaDEP" "WARN" "User Approved MDM but NOT via DEP — Bootstrap Token unavailable"
else
    record "EnrolledViaDEP" "FAIL" "Not enrolled via DEP and not User Approved"
fi

# ─────────────────────────────────────────────
# 2. Supervision / IsMDMUnremovable
# ─────────────────────────────────────────────
print_section "2. Supervision State"

if [[ $EUID -eq 0 ]]; then
    ENROLL_DETAIL=$(profiles show -type enrollment 2>&1)
    if echo "$ENROLL_DETAIL" | grep -qi "IsMDMUnremovable.*1\|IsMDMUnremovable = 1"; then
        record "Supervised" "OK" "IsMDMUnremovable=1 — device is supervised via ADE"
    elif echo "$ENROLL_DETAIL" | grep -qi "IsMDMUnremovable"; then
        record "Supervised" "WARN" "IsMDMUnremovable present but not 1 — device not supervised"
    else
        record "Supervised" "WARN" "Could not determine supervision state from profile output"
    fi
else
    record "Supervised" "WARN" "Root required to inspect enrollment profile detail"
fi

# ─────────────────────────────────────────────
# 3. Bootstrap Token
# ─────────────────────────────────────────────
print_section "3. Bootstrap Token Escrow"

if [[ $EUID -eq 0 ]]; then
    BT_STATUS=$(profiles show -type bootstraptoken 2>&1)
    echo "  $BT_STATUS"
    if echo "$BT_STATUS" | grep -qi "escrowed"; then
        record "BootstrapToken" "OK" "Bootstrap Token escrowed to MDM"
    else
        record "BootstrapToken" "WARN" "Bootstrap Token not escrowed — expected if not ADE/supervised"
    fi
else
    record "BootstrapToken" "WARN" "Root required to check Bootstrap Token"
fi

# ─────────────────────────────────────────────
# 4. Apple ADE / Activation Endpoint Reachability
# ─────────────────────────────────────────────
print_section "4. Apple ADE Endpoint Reachability"

for endpoint in "${ADE_ENDPOINTS[@]}"; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://${endpoint}" 2>/dev/null || echo "000")
    if [[ "$code" != "000" ]]; then
        record "Endpoint-$endpoint" "OK" "Reachable (HTTP $code)"
    else
        record "Endpoint-$endpoint" "FAIL" "UNREACHABLE — check firewall/proxy for *.apple.com"
    fi
done

# ─────────────────────────────────────────────
# 5. Intune Enrollment Endpoint Reachability
# ─────────────────────────────────────────────
print_section "5. Intune Enrollment Endpoint Reachability"

for endpoint in "${INTUNE_ENDPOINTS[@]}"; do
    if /usr/bin/nc -z -w3 "$endpoint" 443 2>/dev/null; then
        record "Endpoint-$endpoint" "OK" "$endpoint :443 reachable"
    else
        record "Endpoint-$endpoint" "FAIL" "$endpoint :443 UNREACHABLE"
    fi
done

# ─────────────────────────────────────────────
# 6. ManagedClient Log — Recent Errors
# ─────────────────────────────────────────────
print_section "6. ManagedClient Log (Recent Errors)"

if command -v log >/dev/null 2>&1; then
    ERROR_ENTRIES=$(log show --predicate 'subsystem == "com.apple.ManagedClient"' --last 1h 2>/dev/null | grep -iE "error|fail|timeout" | tail -20)
    if [[ -n "$ERROR_ENTRIES" ]]; then
        echo "$ERROR_ENTRIES" | sed 's/^/  /'
        ERR_COUNT=$(echo "$ERROR_ENTRIES" | wc -l | tr -d ' ')
        record "ManagedClientLog" "WARN" "$ERR_COUNT error/failure entries in last 1h"
    else
        record "ManagedClientLog" "OK" "No error/failure entries in last 1h"
    fi
else
    record "ManagedClientLog" "WARN" "log command not available"
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
    echo "  Overall: ADE enrollment looks healthy on this device."
else
    echo "  Overall: Issues found — cross-reference FAIL checks against ADE-Enrollment-B.md fix paths."
    echo "  Remember: token/cert expiry and ABM device assignment must still be checked server-side."
fi

echo ""
echo "  CSV report saved to: $CSV_FILE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  End of report — $(date)"
echo "════════════════════════════════════════════════════════"
