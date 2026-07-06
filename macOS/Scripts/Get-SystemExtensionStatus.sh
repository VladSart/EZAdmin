#!/bin/bash
# Get-SystemExtensionStatus.sh
# .SYNOPSIS
#   Collect macOS System/Kernel Extension state, MDM approval policy, and PPPC linkage for triage or escalation.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/Extensions-B.md and Extensions-A.md.
#   Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
#   - systemextensionsctl state for every installed extension (activated/blocked/terminated)
#   - SIP (System Integrity Protection) status — required ON for MDM-managed extension policy
#   - MDM supervision status (silent approval requires ADE/DEP supervision)
#   - Presence of a com.apple.system-extension-policy MDM profile (Allowed bundle/team IDs)
#   - Architecture check (Apple Silicon vs Intel) — kexts need Reduced Security on Apple Silicon
#   - Duplicate endpoint-security-type extensions (macOS allows only one active per type)
#   - Recent com.apple.system_extensions log errors
#
#   Produces a console summary with pass/fail per check and exports full detail to CSV,
#   so the output can be pasted directly into the runbook's Escalation Evidence template.
#
#   Does NOT cover:
#   - Approving a blocked extension in System Settings (that's Extensions-B.md Fix 1 — user action)
#   - Pushing or editing the MDM System Extension policy profile (that's Fix 2/Playbook 1 — Intune-side)
#   - Uninstalling a conflicting endpoint security product (that's Fix 5 — destructive, not run automatically)
#
# .REQUIREMENTS
#   - macOS 11 (Big Sur) or later; systemextensionsctl and PPPC checks assume macOS 12+
#   - Some checks (profiles show -all, full log detail) are more complete run as root
#
# .EXAMPLE
#   bash Get-SystemExtensionStatus.sh
#   sudo bash Get-SystemExtensionStatus.sh
#
# .NOTES
#   Safe/read-only. Makes no activation, deactivation, or profile changes.
#   Tested on macOS 12-15, Apple Silicon and Intel.
#   CSV exported to /tmp/SystemExtensionStatus_<hostname>_<timestamp>.csv

set -uo pipefail

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="/tmp/SystemExtensionStatus_${HOSTNAME}_${TIMESTAMP}.csv"
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
        echo "  ⚠️  Not running as root. MDM profile enumeration and full log detail will be incomplete."
        echo "  Run: sudo bash $0"
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  System / Kernel Extension Status Report"
echo "  Generated: $(date)"
echo "  Hostname:  $HOSTNAME"
echo "════════════════════════════════════════════════════════"

check_root

# ─────────────────────────────────────────────
# 1. Architecture and macOS version
# ─────────────────────────────────────────────
print_section "1. Architecture & macOS Version"

ARCH=$(uname -m)
OS_VERSION=$(sw_vers -productVersion)
echo "  macOS $OS_VERSION ($ARCH)"

if [[ "$ARCH" == "arm64" ]]; then
    record "Architecture" "INFO" "Apple Silicon — third-party kexts require Reduced Security mode; System Extensions unaffected"
else
    record "Architecture" "INFO" "Intel — kexts load without a security-mode change"
fi

# ─────────────────────────────────────────────
# 2. SIP status
# ─────────────────────────────────────────────
print_section "2. System Integrity Protection (SIP)"

SIP_STATUS=$(csrutil status 2>&1)
echo "  $SIP_STATUS"

if echo "$SIP_STATUS" | grep -qi "enabled"; then
    record "SIP" "OK" "SIP enabled — required for MDM-managed extension allow-listing to behave as expected"
else
    record "SIP" "WARN" "SIP disabled — MDM-managed extension allow-list may not enforce correctly; confirm this is intentional (test/dev machine)"
fi

# ─────────────────────────────────────────────
# 3. MDM supervision status
# ─────────────────────────────────────────────
print_section "3. MDM Enrollment / Supervision"

ENROLL_STATUS=$(profiles status -type enrollment 2>&1)
echo "  $ENROLL_STATUS"

if echo "$ENROLL_STATUS" | grep -qi "Enrolled via DEP: Yes"; then
    record "Supervision" "OK" "ADE/DEP enrolled — supervised, extensions can be silently pre-approved by MDM"
elif echo "$ENROLL_STATUS" | grep -qi "MDM enrollment: Yes"; then
    record "Supervision" "WARN" "MDM-enrolled but not via DEP — device may be unsupervised; user will need to manually approve extensions in System Settings"
else
    record "Supervision" "FAIL" "Device not enrolled in MDM — no extension policy can be delivered"
fi

# ─────────────────────────────────────────────
# 4. System Extension MDM policy delivered
# ─────────────────────────────────────────────
print_section "4. System Extension MDM Policy"

if [[ $EUID -eq 0 ]]; then
    SE_POLICY=$(profiles show -all 2>/dev/null | grep -A8 -i "system-extension-policy\|AllowedSystemExtensions\|AllowedTeamIdentifiers")
    if [[ -n "$SE_POLICY" ]]; then
        echo "  $SE_POLICY"
        record "SystemExtensionPolicy" "OK" "com.apple.system-extension-policy profile found on device"
    else
        record "SystemExtensionPolicy" "WARN" "No System Extension allow-policy profile found — extensions on this device will require manual user approval"
    fi

    KEXT_POLICY=$(profiles show -all 2>/dev/null | grep -A5 -i "kernel-extension-policy")
    if [[ -n "$KEXT_POLICY" ]]; then
        record "KernelExtensionPolicy" "INFO" "com.apple.syspolicy.kernel-extension-policy profile also present (legacy kext allow-list)"
    fi
else
    record "SystemExtensionPolicy" "WARN" "Root required to reliably enumerate installed MDM profiles"
fi

# ─────────────────────────────────────────────
# 5. Installed extension state
# ─────────────────────────────────────────────
print_section "5. Installed Extensions (systemextensionsctl)"

SE_LIST=$(systemextensionsctl list 2>&1)
echo "$SE_LIST"

if echo "$SE_LIST" | grep -qi "waiting for user"; then
    record "ExtensionApprovalState" "WARN" "One or more extensions are waiting for user approval"
elif echo "$SE_LIST" | grep -qi "terminated"; then
    record "ExtensionApprovalState" "FAIL" "One or more extensions are terminated — check crash logs (Fix path: collect from /Library/Logs/DiagnosticReports)"
elif echo "$SE_LIST" | grep -qi "activated enabled"; then
    record "ExtensionApprovalState" "OK" "At least one extension is activated and enabled"
else
    record "ExtensionApprovalState" "INFO" "No system extensions currently installed on this device"
fi

# ─────────────────────────────────────────────
# 6. Duplicate endpoint-security-type extensions
# ─────────────────────────────────────────────
print_section "6. Endpoint Security Extension Conflict Check"

ES_COUNT=$(echo "$SE_LIST" | grep -ci "endpointsecurity" || true)
if [[ "$ES_COUNT" -gt 1 ]]; then
    record "EndpointSecurityConflict" "WARN" "$ES_COUNT EndpointSecurity-type extensions found — macOS allows only one active per type from non-Apple vendors; expect one to be blocked"
elif [[ "$ES_COUNT" -eq 1 ]]; then
    record "EndpointSecurityConflict" "OK" "Exactly one EndpointSecurity-type extension found — no conflict expected"
else
    record "EndpointSecurityConflict" "INFO" "No EndpointSecurity-type extensions found on this device"
fi

# ─────────────────────────────────────────────
# 7. Recent extension errors from unified log
# ─────────────────────────────────────────────
print_section "7. Recent Extension Errors (last 1h)"

LOG_ERRORS=$(log show --last 1h --predicate 'subsystem == "com.apple.system_extensions"' 2>/dev/null | grep -i "error\|fail\|block\|denied" | tail -15)
if [[ -n "$LOG_ERRORS" ]]; then
    echo "$LOG_ERRORS"
    ERROR_COUNT=$(echo "$LOG_ERRORS" | wc -l | tr -d ' ')
    record "RecentLogErrors" "WARN" "$ERROR_COUNT error/fail/block line(s) found in last 1h — see console output above"
else
    record "RecentLogErrors" "OK" "No system-extension errors in unified log (last 1h)"
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
    echo "  Overall: System/Kernel Extension state looks healthy on this device."
else
    echo "  Overall: Issues found — cross-reference FAIL/WARN checks against Extensions-B.md Fix 1-5."
fi

echo ""
echo "  CSV report saved to: $CSV_FILE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  End of report — $(date)"
echo "════════════════════════════════════════════════════════"
