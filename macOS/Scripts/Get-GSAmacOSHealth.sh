#!/bin/bash
# Get-GSAmacOSHealth.sh
# .SYNOPSIS
#   Collect Global Secure Access (GSA) client health on a Mac for triage or escalation.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/GlobalSecureAccess-macOS-B.md / -A.md.
#   Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
#   - macOS version / processor against the client's hard eligibility floor (14.0+, Intel/M1-M4)
#   - Installed GSA client version, cross-checked against the mandatory macOS 26 compatibility
#     floor (1.1.25070402+)
#   - System extension activation state, checked against BOTH the current
#     (com.microsoft.globalsecureaccess*) and deprecated pre-June-2025
#     (com.microsoft.naas.globalsecure*) bundle identifiers, to catch fleets mid-migration
#   - Transparent Proxy network service state
#   - MDM enrollment status (GSA's own Entra-registration prerequisite)
#   - DNS resolver list and a per-resolver port-853 (DoH/DoT) check that can silently break
#     FQDN-based forwarding rules
#   - Configured proxy auto-config (PAC) URL, if any
#   - Basic non-GSA internet reachability, to separate "network is down" from "GSA is broken"
#
#   Produces a console summary with pass/fail per check and exports full detail to CSV,
#   so the output can be pasted directly into the runbook's Escalation Evidence template.
#
#   Does NOT cover:
#   - Tenant-side traffic forwarding profile state, Private Access connector health, or
#     Conditional Access "Compliant Network" policy — those are Entra/Graph-side checks,
#     see EntraID/Troubleshooting/GlobalSecureAccess-B.md instead
#   - Running or parsing the client's own Advanced Diagnostics Health Check tab (GUI-only,
#     no CLI equivalent exists) — this script's checks are a device-local complement to it,
#     not a replacement
#   - Forcing a policy refresh, clearing cached data, or any other client state change
#     (all read-only checks; see the runbook's Fix paths for those actions)
#
# .REQUIREMENTS
#   - macOS 13+ to run this script itself; the GSA client requires macOS 14+ separately
#     (the script reports on eligibility, it doesn't require it to run)
#   - Global Secure Access client installed for most checks to be meaningful
#   - Some checks (systemextensionsctl detail) are more complete run as root
#
# .EXAMPLE
#   bash Get-GSAmacOSHealth.sh
#   sudo bash Get-GSAmacOSHealth.sh
#
# .NOTES
#   Safe/read-only. Makes no client, profile, or network configuration changes.
#   Tested on macOS 14-15 (Sonoma/Sequoia), Apple Silicon and Intel.
#   CSV exported to /tmp/GSAmacOSHealth_<hostname>_<timestamp>.csv

set -uo pipefail

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="/tmp/GSAmacOSHealth_${HOSTNAME}_${TIMESTAMP}.csv"
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

CLIENT_APP_PATH="/Applications/GlobalSecureAccessClient/Global Secure Access Client.app"
MIN_MACOS26_CLIENT="1.1.25070402"

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
        echo "  ⚠️  Not running as root. System extension enumeration may be incomplete."
        echo "  Run: sudo bash $0"
    fi
}

version_lt() {
    # Returns 0 (true) if $1 < $2, using sort -V
    [[ "$1" == "$2" ]] && return 1
    local lower
    lower=$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)
    [[ "$lower" == "$1" ]]
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  Global Secure Access (macOS Client) Health Report"
echo "  Generated: $(date)"
echo "  Hostname:  $HOSTNAME"
echo "════════════════════════════════════════════════════════"

check_root

# ─────────────────────────────────────────────
# 1. macOS version / hardware eligibility
# ─────────────────────────────────────────────
print_section "1. macOS Version & Hardware"

OS_VERSION=$(sw_vers -productVersion)
CPU_BRAND=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")
OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
echo "  macOS $OS_VERSION on $CPU_BRAND"

if [[ "$OS_MAJOR" -ge 14 ]]; then
    record "macOSVersion" "OK" "$OS_VERSION — meets GSA client's macOS 14.0 floor"
else
    record "macOSVersion" "FAIL" "$OS_VERSION — below minimum (14.0) for GSA client; not eligible, no workaround"
fi

# ─────────────────────────────────────────────
# 2. GSA client version, cross-checked against macOS 26 floor
# ─────────────────────────────────────────────
print_section "2. GSA Client Version"

if [[ -d "$CLIENT_APP_PATH" ]]; then
    CLIENT_VERSION=$(defaults read "$CLIENT_APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    echo "  GSA Client version: $CLIENT_VERSION"

    if [[ "$OS_MAJOR" -ge 26 ]]; then
        if [[ "$CLIENT_VERSION" == "unknown" ]]; then
            record "ClientVersionVsMacOS26" "WARN" "Could not read client version to check against macOS 26 floor"
        elif version_lt "$CLIENT_VERSION" "$MIN_MACOS26_CLIENT"; then
            record "ClientVersionVsMacOS26" "FAIL" "Client $CLIENT_VERSION predates the mandatory macOS 26 fix ($MIN_MACOS26_CLIENT) — documented cause of total connectivity loss; upgrade client before troubleshooting anything else"
        else
            record "ClientVersionVsMacOS26" "OK" "Client $CLIENT_VERSION meets the macOS 26 compatibility floor"
        fi
    else
        record "ClientVersionVsMacOS26" "INFO" "Not on macOS 26 — floor check not applicable yet"
    fi
else
    record "ClientInstalled" "FAIL" "GSA client app not found at expected path — client not installed"
fi

# ─────────────────────────────────────────────
# 3. System extension activation — current AND deprecated identifiers
# ─────────────────────────────────────────────
print_section "3. System Extension State"

EXT_LIST=$(systemextensionsctl list 2>/dev/null)
CURRENT_EXT=$(echo "$EXT_LIST" | grep -i "com.microsoft.globalsecureaccess")
LEGACY_EXT=$(echo "$EXT_LIST" | grep -i "com.microsoft.naas.globalsecure")

if [[ -n "$CURRENT_EXT" ]]; then
    echo "  $CURRENT_EXT"
    if echo "$CURRENT_EXT" | grep -qi "activated enabled"; then
        record "SystemExtension" "OK" "Current-identifier extension active and enabled"
    else
        record "SystemExtension" "FAIL" "Current-identifier extension present but NOT enabled — approve via Privacy & Security or MDM Allowed System Extensions profile"
    fi
elif [[ -n "$LEGACY_EXT" ]]; then
    echo "  $LEGACY_EXT"
    record "SystemExtension" "WARN" "Only the DEPRECATED pre-June-2025 identifier (com.microsoft.naas.globalsecure*) is present — this device is running an old client or a stale MDM allow-list profile; see the Bundle Identifier Migration section in GlobalSecureAccess-macOS-A.md"
else
    record "SystemExtension" "FAIL" "No GSA system extension found (current or legacy identifier) — not installed, or never approved"
fi

# ─────────────────────────────────────────────
# 4. Transparent Proxy network service
# ─────────────────────────────────────────────
print_section "4. Transparent Proxy Service"

NC_LIST=$(scutil --nc list 2>/dev/null)
if echo "$NC_LIST" | grep -qi "globalsecureaccess\|global secure access"; then
    echo "$NC_LIST" | grep -i "globalsecureaccess\|global secure access"
    if echo "$NC_LIST" | grep -i "globalsecureaccess" | grep -qi "Connected\|(1)"; then
        record "TransparentProxy" "OK" "GSA Transparent Proxy network service present and appears active"
    else
        record "TransparentProxy" "WARN" "GSA Transparent Proxy service found but state unclear — verify manually at System Settings > Network > Filters & Proxies"
    fi
else
    record "TransparentProxy" "FAIL" "No GSA Transparent Proxy service found — either not installed, or the MDM transparent-app-proxy custom profile hasn't landed"
fi

# ─────────────────────────────────────────────
# 5. MDM enrollment (GSA's own auth prerequisite)
# ─────────────────────────────────────────────
print_section "5. MDM Enrollment"

ENROLL_STATUS=$(profiles status -type enrollment 2>&1)
echo "  $ENROLL_STATUS"

if echo "$ENROLL_STATUS" | grep -qi "MDM enrollment: Yes"; then
    record "MDMEnrollment" "OK" "Device is MDM enrolled"
else
    record "MDMEnrollment" "FAIL" "Device is NOT MDM enrolled — GSA client requires Entra registration via Company Portal, separate from general MDM enrollment"
fi

# ─────────────────────────────────────────────
# 6. DNS resolvers + secure DNS (DoH/DoT) check
# ─────────────────────────────────────────────
print_section "6. DNS Resolvers & Encryption Check"

RESOLVERS=$(scutil --dns 2>/dev/null | grep -oE 'nameserver\[[0-9]+\] : [0-9.]+' | awk '{print $NF}' | sort -u)

if [[ -z "$RESOLVERS" ]]; then
    record "DNSResolvers" "WARN" "No DNS resolvers found — check network configuration"
else
    echo "  Resolvers found: $(echo "$RESOLVERS" | tr '\n' ' ')"
    ENCRYPTED_FOUND=0
    for ip in $RESOLVERS; do
        if command -v nc >/dev/null 2>&1; then
            if nc -zv -G 2 "$ip" 853 2>&1 | grep -qi "succeeded\|open"; then
                echo "  Resolver $ip: port 853 OPEN — DNS-over-TLS likely enforced"
                ENCRYPTED_FOUND=1
            fi
        fi
    done
    if [[ "$ENCRYPTED_FOUND" -eq 1 ]]; then
        record "SecureDNSCheck" "WARN" "At least one resolver has port 853 open — FQDN-based GSA forwarding rules may silently fail to match traffic using it"
    else
        record "SecureDNSCheck" "OK" "No resolver responded on port 853 — FQDN-based rules should match normally"
    fi
fi

# ─────────────────────────────────────────────
# 7. Proxy Auto-Config (PAC) check
# ─────────────────────────────────────────────
print_section "7. Proxy Auto-Config (PAC)"

PAC_URL=""
for service in "Wi-Fi" "Ethernet"; do
    URL=$(networksetup -getautoproxyurl "$service" 2>/dev/null | grep "URL:" | awk '{print $2}')
    if [[ -n "$URL" && "$URL" != "(null)" ]]; then
        PAC_URL="$URL"
        echo "  $service PAC URL: $URL"
    fi
done

if [[ -n "$PAC_URL" ]]; then
    record "PACConfigured" "WARN" "PAC file configured ($PAC_URL) — confirm it excludes GSA's tunneled/diagnostic FQDNs (.edgediagnostic.globalsecureaccess.microsoft.com and tenant destinations) or GSA traffic may be double-routed through the proxy"
else
    record "PACConfigured" "OK" "No PAC file configured on active network services"
fi

# ─────────────────────────────────────────────
# 8. Basic internet reachability (non-GSA test)
# ─────────────────────────────────────────────
print_section "8. Basic Internet Reachability"

if command -v curl >/dev/null 2>&1; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://www.msftconnecttest.com/connecttest.txt 2>/dev/null)
    echo "  HTTP $HTTP_CODE from msftconnecttest.com"
    if [[ "$HTTP_CODE" == "200" ]]; then
        record "InternetReachable" "OK" "Basic internet connectivity confirmed independent of GSA"
    else
        record "InternetReachable" "FAIL" "HTTP $HTTP_CODE — underlying network path is broken; troubleshoot connectivity before GSA-specific issues"
    fi
else
    record "InternetReachable" "WARN" "curl not available — could not test"
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
    echo "  Overall: GSA macOS client looks healthy on this device."
else
    echo "  Overall: Issues found — cross-reference FAIL/WARN checks against GlobalSecureAccess-macOS-B.md fix paths."
fi
echo ""
echo "  Reminder: this script does not check tenant-side forwarding profile state,"
echo "  Private Access connector health, or run the client's own GUI Health Check tab."
echo "  Run those separately per GlobalSecureAccess-macOS-A.md Phase 5-6."

echo ""
echo "  CSV report saved to: $CSV_FILE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  End of report — $(date)"
echo "════════════════════════════════════════════════════════"
