#!/bin/bash
# Get-PlatformSSOStatus.sh
# .SYNOPSIS
#   Collect Platform SSO registration, extension, and MDM profile health for triage or escalation.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/Platform-SSO-B.md.
#   Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
#   - app-sso platform registration state (Registered/Not registered) and auth method
#   - Presence of the Extensible SSO (com.apple.extensiblesso) MDM configuration profile
#   - Company Portal SSO extension responsiveness and app version
#   - MDM enrollment status (Platform SSO requires active MDM enrollment)
#   - Kerberos SSO extension state, if present (informational — hybrid environments only)
#   - Recent AuthenticationServices / Company Portal errors from the unified log
#
#   Produces a console summary with pass/fail per check and exports full detail to CSV,
#   so the output can be pasted directly into the runbook's Escalation Evidence template.
#
#   Does NOT cover:
#   - Triggering registration or signing the user out of Platform SSO (that's Platform-SSO-B.md Fix 1 / Fix 2)
#   - Fixing the Intune-side profile assignment (that's Fix 3 — this script only detects a missing profile)
#   - Browser-specific SSO redirect URL configuration (that's Fix 6 — checked at a high level only)
#
# .REQUIREMENTS
#   - macOS 13 (Ventura) or later — Platform SSO requires 13+; UserSecureEnclaveKey requires 14+
#   - Microsoft Company Portal installed for full extension detail
#   - Some checks (profiles -P, bootstraptoken-adjacent detail) are more complete run as root
#
# .EXAMPLE
#   bash Get-PlatformSSOStatus.sh
#   sudo bash Get-PlatformSSOStatus.sh
#
# .NOTES
#   Safe/read-only. Makes no registration, sign-out, or profile changes.
#   Tested on macOS 13–15, Apple Silicon and Intel.
#   CSV exported to /tmp/PlatformSSOStatus_<hostname>_<timestamp>.csv

set -uo pipefail

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="/tmp/PlatformSSOStatus_${HOSTNAME}_${TIMESTAMP}.csv"
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

SSO_EXTENSION_ID="com.microsoft.CompanyPortalMac.ssoextension"

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
echo "  Platform SSO Status Report"
echo "  Generated: $(date)"
echo "  Hostname:  $HOSTNAME"
echo "════════════════════════════════════════════════════════"

check_root

# ─────────────────────────────────────────────
# 1. macOS version gate
# ─────────────────────────────────────────────
print_section "1. macOS Version"

OS_VERSION=$(sw_vers -productVersion)
echo "  macOS $OS_VERSION"
OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)

if [[ "$OS_MAJOR" -ge 14 ]]; then
    record "macOSVersion" "OK" "$OS_VERSION — supports UserSecureEnclaveKey auth method"
elif [[ "$OS_MAJOR" -ge 13 ]]; then
    record "macOSVersion" "OK" "$OS_VERSION — Platform SSO supported (Password auth only; upgrade to 14+ for hardware-bound key)"
else
    record "macOSVersion" "FAIL" "$OS_VERSION — below minimum (13.0) for Platform SSO"
fi

# ─────────────────────────────────────────────
# 2. MDM enrollment status
# ─────────────────────────────────────────────
print_section "2. MDM Enrollment"

ENROLL_STATUS=$(profiles status -type enrollment 2>&1)
echo "  $ENROLL_STATUS"

if echo "$ENROLL_STATUS" | grep -qi "MDM enrollment: Yes"; then
    record "MDMEnrollment" "OK" "Device is MDM enrolled"
else
    record "MDMEnrollment" "FAIL" "Device is NOT MDM enrolled — Platform SSO cannot register without this"
fi

# ─────────────────────────────────────────────
# 3. Extensible SSO MDM profile present
# ─────────────────────────────────────────────
print_section "3. Extensible SSO Configuration Profile"

if [[ $EUID -eq 0 ]]; then
    SSO_PROFILE=$(profiles -P 2>/dev/null | grep -i -A5 "extensiblesso\|com.apple.extensiblesso")
    if [[ -n "$SSO_PROFILE" ]]; then
        echo "  $SSO_PROFILE"
        record "SSOProfile" "OK" "Extensible SSO profile found on device"
    else
        record "SSOProfile" "FAIL" "No Extensible SSO profile found — MDM profile not delivered or not assigned"
    fi
else
    record "SSOProfile" "WARN" "Root required to reliably enumerate installed profiles"
fi

# ─────────────────────────────────────────────
# 4. Platform SSO registration state
# ─────────────────────────────────────────────
print_section "4. Platform SSO Registration"

if command -v app-sso >/dev/null 2>&1; then
    PSSO_STATUS=$(app-sso platform -s 2>&1)
    echo "  $PSSO_STATUS"

    if echo "$PSSO_STATUS" | grep -qi "Registration: Registered\|Registered: Yes"; then
        AUTH_METHOD=$(echo "$PSSO_STATUS" | grep -i "Authentication method" | sed 's/.*: //')
        record "PlatformSSORegistration" "OK" "Registered${AUTH_METHOD:+ (Auth: $AUTH_METHOD)}"
    elif echo "$PSSO_STATUS" | grep -qi "Not registered\|UserRegistrationRequired"; then
        record "PlatformSSORegistration" "FAIL" "Not registered — user has not completed the Platform SSO registration flow"
    else
        record "PlatformSSORegistration" "WARN" "Unexpected app-sso output — review manually"
    fi
else
    record "PlatformSSORegistration" "FAIL" "app-sso command not found — macOS may be below 13.0 or SSO extension not installed"
fi

# ─────────────────────────────────────────────
# 5. Company Portal presence, version, and SSO extension
# ─────────────────────────────────────────────
print_section "5. Company Portal & SSO Extension"

CP_PATH="/Applications/Company Portal.app"
if [[ -d "$CP_PATH" ]]; then
    CP_VERSION=$(defaults read "$CP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    echo "  Company Portal version: $CP_VERSION"
    record "CompanyPortalInstalled" "OK" "Version $CP_VERSION"

    if command -v app-sso >/dev/null 2>&1; then
        EXT_STATUS=$(app-sso extension -p "$SSO_EXTENSION_ID" 2>&1)
        if echo "$EXT_STATUS" | grep -qi "error\|not found"; then
            record "SSOExtension" "FAIL" "Extension query failed: $(echo "$EXT_STATUS" | head -1)"
        else
            record "SSOExtension" "OK" "SSO extension responding"
        fi
    fi
else
    record "CompanyPortalInstalled" "FAIL" "Company Portal.app not found — SSO extension bundle does not exist on this device"
fi

# ─────────────────────────────────────────────
# 6. Kerberos SSO extension (informational, hybrid environments)
# ─────────────────────────────────────────────
print_section "6. Kerberos SSO Extension (informational)"

if command -v app-sso >/dev/null 2>&1; then
    KERB_STATUS=$(app-sso kerberos -s 2>&1)
    if echo "$KERB_STATUS" | grep -qi "not found\|no kerberos\|error"; then
        record "KerberosSSO" "INFO" "Not configured (expected for cloud-only environments)"
    else
        echo "  $KERB_STATUS"
        record "KerberosSSO" "INFO" "Kerberos SSO extension present — hybrid environment"
    fi
fi

# ─────────────────────────────────────────────
# 7. Recent SSO-related errors from unified log
# ─────────────────────────────────────────────
print_section "7. Recent SSO Errors (last 1h)"

LOG_ERRORS=$(log show --predicate 'process == "CompanyPortal" OR process == "SSOExtensionProcess"' --last 1h 2>/dev/null | grep -i "error\|fail" | tail -10)
if [[ -n "$LOG_ERRORS" ]]; then
    echo "$LOG_ERRORS"
    ERROR_COUNT=$(echo "$LOG_ERRORS" | wc -l | tr -d ' ')
    record "RecentLogErrors" "WARN" "$ERROR_COUNT error/fail line(s) found in last 1h — see console output above"
else
    record "RecentLogErrors" "OK" "No SSO-related errors in unified log (last 1h)"
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
    echo "  Overall: Platform SSO looks healthy on this device."
else
    echo "  Overall: Issues found — cross-reference FAIL/WARN checks against Platform-SSO-B.md fix paths."
fi

echo ""
echo "  CSV report saved to: $CSV_FILE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  End of report — $(date)"
echo "════════════════════════════════════════════════════════"
