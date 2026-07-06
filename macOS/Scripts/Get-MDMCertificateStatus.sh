#!/bin/bash
# Get-MDMCertificateStatus.sh
# .SYNOPSIS
#   Collect macOS MDM enrollment/certificate health and APNs connectivity for triage or escalation.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/MDM-Certificate-Renewal-B.md and MDM-Certificate-Renewal-A.md.
#   Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
#   - MDM enrollment state (profiles status)
#   - Device-side MDM identity certificate presence and expiry (System keychain)
#   - Connectivity to the Intune enrollment endpoint and Apple APNs gateways
#   - Result of a manual mdmclient check-in attempt
#   - Recent com.apple.mdmclient log errors mentioning cert/expiry/auth failures
#   - Active proxy configuration (SSL-inspecting proxies break APNs certificate pinning)
#
#   Produces a console summary with pass/fail per check and exports full detail to CSV,
#   so the output can be pasted directly into the runbook's Escalation Evidence template.
#
#   Does NOT cover:
#   - Renewing the tenant-wide APNs certificate in the Apple Push Certificates Portal (that's Fix 3 — admin portal action)
#   - Removing/re-enrolling the device (that's Fix 1/2 — destructive to managed state, not run automatically)
#   - Changing proxy SSL-inspection rules (that's Fix 5 — network/firewall admin action)
#
# .REQUIREMENTS
#   - macOS 12 (Monterey) or later
#   - mdmclient check-in and full keychain enumeration require root
#   - Network checks assume outbound HTTPS/443 is at least partially reachable
#
# .EXAMPLE
#   bash Get-MDMCertificateStatus.sh
#   sudo bash Get-MDMCertificateStatus.sh
#
# .NOTES
#   Safe/read-only, except for a single non-destructive `mdmclient CheckIn` trigger (matches runbook Step 4).
#   Tested on macOS 12-15, Apple Silicon and Intel.
#   CSV exported to /tmp/MDMCertificateStatus_<hostname>_<timestamp>.csv

set -uo pipefail

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="/tmp/MDMCertificateStatus_${HOSTNAME}_${TIMESTAMP}.csv"
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
        echo "  ⚠️  Not running as root. Keychain cert-expiry and mdmclient check-in checks will be incomplete."
        echo "  Run: sudo bash $0"
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  MDM Certificate / Enrollment Status Report"
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

if echo "$ENROLL_STATUS" | grep -qi "MDM enrollment: Yes"; then
    record "MDMEnrollment" "OK" "Device is enrolled in MDM"
else
    record "MDMEnrollment" "FAIL" "Device is NOT enrolled — go to MDM-Certificate-Renewal-B.md Fix 1 (re-enrollment)"
fi

# ─────────────────────────────────────────────
# 2. Device-side MDM identity certificate expiry
# ─────────────────────────────────────────────
print_section "2. MDM Identity Certificate (System Keychain)"

if [[ $EUID -eq 0 ]]; then
    MDM_CERT_PEM=$(security find-certificate -a -c "MDM" /Library/Keychains/System.keychain -p 2>/dev/null)
    if [[ -z "$MDM_CERT_PEM" ]]; then
        # Fall back to a broader identity search if the "MDM" common-name match returns nothing
        MDM_IDENTITY=$(security find-identity -v /Library/Keychains/System.keychain 2>/dev/null | grep -i "mdm\|management\|intune")
        if [[ -n "$MDM_IDENTITY" ]]; then
            echo "  $MDM_IDENTITY"
            record "MDMIdentityCert" "INFO" "MDM-related identity found via find-identity; run 'security find-certificate -a -c \"MDM\" ... -p | openssl x509 -noout -dates' manually with the exact common name for expiry"
        else
            record "MDMIdentityCert" "WARN" "No MDM identity certificate found in System keychain — device may not be fully enrolled or cert already expired/removed"
        fi
    else
        CERT_DATES=$(echo "$MDM_CERT_PEM" | openssl x509 -noout -dates 2>&1)
        echo "  $CERT_DATES"
        NOT_AFTER=$(echo "$CERT_DATES" | grep "notAfter=" | cut -d= -f2)
        if [[ -n "$NOT_AFTER" ]]; then
            EXPIRY_EPOCH=$(date -j -f "%b %e %T %Y %Z" "$NOT_AFTER" "+%s" 2>/dev/null || echo 0)
            NOW_EPOCH=$(date "+%s")
            if [[ "$EXPIRY_EPOCH" -gt 0 && "$EXPIRY_EPOCH" -lt "$NOW_EPOCH" ]]; then
                record "MDMIdentityCert" "FAIL" "Certificate expired ($NOT_AFTER) — re-enrollment required (Fix 1/Playbook 2)"
            elif [[ "$EXPIRY_EPOCH" -gt 0 ]]; then
                DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
                if [[ "$DAYS_LEFT" -lt 30 ]]; then
                    record "MDMIdentityCert" "WARN" "Certificate expires in $DAYS_LEFT day(s) ($NOT_AFTER) — auto-renewal should trigger if device stays online and reachable"
                else
                    record "MDMIdentityCert" "OK" "Certificate valid, expires $NOT_AFTER ($DAYS_LEFT days remaining)"
                fi
            else
                record "MDMIdentityCert" "INFO" "Could not parse expiry date automatically — review notAfter value above manually"
            fi
        else
            record "MDMIdentityCert" "WARN" "Could not extract notAfter date from certificate output"
        fi
    fi
else
    record "MDMIdentityCert" "WARN" "Root required to read System keychain certificate details"
fi

# ─────────────────────────────────────────────
# 3. mdmclient manual check-in
# ─────────────────────────────────────────────
print_section "3. mdmclient Check-In"

if [[ $EUID -eq 0 ]]; then
    CHECKIN_OUT=$(mdmclient CheckIn 2>&1)
    echo "  $CHECKIN_OUT"
    if echo "$CHECKIN_OUT" | grep -qi "error\|reject\|fail"; then
        record "MDMCheckIn" "FAIL" "Check-in reported an error — see output above; likely identity cert or APNs channel issue"
    else
        record "MDMCheckIn" "OK" "Check-in completed without an explicit error"
    fi
else
    record "MDMCheckIn" "WARN" "Root required to trigger 'mdmclient CheckIn'"
fi

# ─────────────────────────────────────────────
# 4. Connectivity — Intune enrollment endpoint
# ─────────────────────────────────────────────
print_section "4. Intune Enrollment Endpoint Connectivity"

INTUNE_TEST=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://enrollment.manage.microsoft.com/ 2>&1)
if [[ "$INTUNE_TEST" =~ ^[0-9]+$ && "$INTUNE_TEST" -lt 500 ]]; then
    record "IntuneEndpoint" "OK" "enrollment.manage.microsoft.com reachable (HTTP $INTUNE_TEST)"
else
    record "IntuneEndpoint" "FAIL" "enrollment.manage.microsoft.com unreachable or erroring (result: $INTUNE_TEST) — check network/proxy (Fix 5)"
fi

# ─────────────────────────────────────────────
# 5. Connectivity — Apple APNs gateways
# ─────────────────────────────────────────────
print_section "5. Apple APNs Gateway Connectivity"

if command -v nc >/dev/null 2>&1; then
    if nc -z -G 5 gateway.push.apple.com 443 2>/dev/null; then
        record "APNsGateway443" "OK" "gateway.push.apple.com:443 reachable"
    else
        record "APNsGateway443" "FAIL" "gateway.push.apple.com:443 unreachable — MDM pushes cannot arrive; check firewall/proxy SSL inspection exclusions (Fix 5)"
    fi

    if nc -z -G 5 gateway.push.apple.com 2195 2>/dev/null; then
        record "APNsGateway2195" "OK" "gateway.push.apple.com:2195 reachable (legacy APNs port)"
    else
        record "APNsGateway2195" "INFO" "gateway.push.apple.com:2195 not reachable — legacy port, not required if 443 path works"
    fi
else
    record "APNsGateway" "WARN" "nc (netcat) not available — cannot test APNs port reachability"
fi

# ─────────────────────────────────────────────
# 6. Proxy configuration (SSL inspection breaks APNs pinning)
# ─────────────────────────────────────────────
print_section "6. Proxy Configuration"

PROXY_CFG=$(scutil --proxy 2>&1 | grep -E "HTTPSEnable|HTTPSProxy|HTTPEnable" || true)
if echo "$PROXY_CFG" | grep -qi "HTTPSEnable : 1\|HTTPEnable : 1"; then
    echo "  $PROXY_CFG"
    record "ProxyConfig" "WARN" "A system proxy is configured — if it performs SSL/TLS inspection on *.push.apple.com, APNs traffic will silently fail (Fix 5). Confirm APNs is excluded from inspection."
else
    record "ProxyConfig" "OK" "No system HTTP/HTTPS proxy configured on this network interface"
fi

# ─────────────────────────────────────────────
# 7. Recent mdmclient log errors
# ─────────────────────────────────────────────
print_section "7. Recent mdmclient Errors (last 1h)"

LOG_ERRORS=$(log show --last 1h --predicate 'process == "mdmclient"' 2>/dev/null | grep -i "error\|fail\|expired\|cert" | tail -15)
if [[ -n "$LOG_ERRORS" ]]; then
    echo "$LOG_ERRORS"
    ERROR_COUNT=$(echo "$LOG_ERRORS" | wc -l | tr -d ' ')
    record "RecentLogErrors" "WARN" "$ERROR_COUNT error/fail/cert line(s) found in last 1h — see console output above"
else
    record "RecentLogErrors" "OK" "No mdmclient cert/error lines in unified log (last 1h)"
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
    echo "  Overall: MDM certificate/connectivity state looks healthy on this device."
else
    echo "  Overall: Issues found — cross-reference FAIL/WARN checks against MDM-Certificate-Renewal-B.md Fix 1-5."
fi

echo ""
echo "  CSV report saved to: $CSV_FILE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  End of report — $(date)"
echo "════════════════════════════════════════════════════════"
