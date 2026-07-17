#!/bin/bash
# Get-ContentCachingAudit.sh
# .SYNOPSIS
#   Collect Content Caching service status, registration health, network reachability,
#   and (optionally) client-side discovery evidence, per ContentCaching-B.md and ContentCaching-A.md.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/ContentCaching-B.md and ContentCaching-A.md.
#   Because Content Caching is a native macOS service that Intune only configures and enables —
#   there is no Intune-side compliance signal or portal report for registration health, discovery,
#   or actual serving — this script exists to fill that visibility gap on-device, in one pass:
#     - Presence of the managed Content Caching profile (profiles -P)
#     - Service activation state and effective settings (AssetCacheManagerUtil status/settings)
#     - Outbound reachability to Apple's registration/config endpoints (the #1 root cause of
#       "never registers" tickets — see ContentCaching-B.md Fix 1)
#     - This host's public IP (the actual client-discovery grouping key Apple uses — compare
#       this value against a client's own public IP manually, since a client-side companion
#       check cannot be run remotely from here)
#     - Free space at the configured cache location
#     - Recent unified log activity for registration/serving evidence
#
#   Run with -Mode client on a CLIENT Mac instead of a cache host to run the discovery-side
#   check (AssetCacheLocatorUtil) and public IP, for direct comparison against a host's report.
#
#   Produces a console summary with pass/fail per check and exports full detail to CSV, so
#   output can be pasted directly into the runbook's Escalation Evidence template.
#
#   Does NOT cover:
#   - Resetting or clearing the cache (see ContentCaching-A.md Remediation Playbook 3 —
#     the supported path is the System Settings UI, deliberately not automated here)
#   - Multi-site/peer-cache hierarchy configuration (see ContentCaching-A.md Playbook 2)
#   - Any Intune/Graph-side check — there is no meaningful Graph signal for this topic beyond
#     basic profile-assignment confirmation, which `profiles -P` already covers device-locally
#
# .REQUIREMENTS
#   - macOS 10.13.5 or later (AssetCacheManagerUtil availability)
#   - Run as root for full detail (managed profiles + service status): sudo bash Get-ContentCachingAudit.sh
#   - Some checks degrade gracefully without root
#
# .EXAMPLE
#   sudo bash Get-ContentCachingAudit.sh
#   sudo bash Get-ContentCachingAudit.sh -Mode client
#
# .NOTES
#   Safe/read-only. Never modifies the cache, never resets/clears stored content, never changes
#   service configuration. CSV exported to /tmp/ContentCachingAudit_<hostname>_<timestamp>.csv

set -uo pipefail

# ─────────────────────────────────────────────
# Args
# ─────────────────────────────────────────────
MODE="host"
while getopts "M:" opt; do
    case $opt in
        M) MODE="$OPTARG" ;;
        *) echo "Usage: $0 [-M host|client]"; exit 1 ;;
    esac
done
# Also accept a bare "-Mode client" style invocation for readability, without breaking getopts above
for arg in "$@"; do
    if [[ "$arg" == "client" ]]; then MODE="client"; fi
done

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="/tmp/ContentCachingAudit_${HOSTNAME}_${TIMESTAMP}.csv"
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
        echo "  ⚠️  Not running as root. Profile list / full status checks will be incomplete."
        echo "  Run: sudo bash $0"
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  Content Caching Audit — Mode: $MODE"
echo "  Generated: $(date)"
echo "  Hostname:  $HOSTNAME"
echo "════════════════════════════════════════════════════════"

check_root

if [[ "$MODE" == "client" ]]; then
    # ─────────────────────────────────────────────
    # CLIENT MODE — discovery-side check only
    # ─────────────────────────────────────────────
    print_section "Client Discovery Check"

    if command -v /usr/bin/AssetCacheLocatorUtil >/dev/null 2>&1; then
        LOCATOR_OUT=$(/usr/bin/AssetCacheLocatorUtil 2>&1)
        echo "$LOCATOR_OUT"
        if echo "$LOCATOR_OUT" | grep -qiE "no caches|not found|^$"; then
            record "ClientDiscovery" "FAIL" "No Content Caching host discovered from this client — check public IP match against the intended host (see ContentCaching-B.md Fix 2)"
        else
            record "ClientDiscovery" "OK" "At least one cache discovered from this client"
        fi
    else
        record "ClientDiscovery" "WARN" "AssetCacheLocatorUtil not found at expected path on this device"
    fi

    print_section "Client Public IP"
    CLIENT_IP=$(curl -s --max-time 8 https://api.ipify.org 2>&1)
    if [[ -n "$CLIENT_IP" ]]; then
        record "ClientPublicIP" "INFO" "$CLIENT_IP — compare against the cache host's public IP (run this script in host mode there); a mismatch is the #1 discovery-failure cause"
    else
        record "ClientPublicIP" "WARN" "Could not determine public IP (network issue or api.ipify.org unreachable)"
    fi

else
    # ─────────────────────────────────────────────
    # HOST MODE (default) — full cache-host audit
    # ─────────────────────────────────────────────

    # 1. Managed profile present
    print_section "1. Managed Content Caching Profile"
    if [[ $EUID -eq 0 ]]; then
        if profiles -P 2>/dev/null | grep -qi "AssetCache\|Content Caching"; then
            record "ManagedProfile" "OK" "Content Caching payload found in installed profiles"
        else
            record "ManagedProfile" "FAIL" "No Content Caching payload found — policy not assigned to this device, or this device isn't the intended cache host"
        fi

        PROFILE_COUNT=$(profiles -P 2>/dev/null | grep -ic "AssetCache")
        if [[ "$PROFILE_COUNT" -gt 1 ]]; then
            record "ProfileCount" "WARN" "$PROFILE_COUNT AssetCache-related profile matches found — Apple's payload spec forbids multiple Content Caching profiles per device (undefined behavior), verify only one is truly a Content Caching payload (see ContentCaching-B.md Fix 4)"
        fi
    else
        record "ManagedProfile" "WARN" "Root required to enumerate installed profiles"
    fi

    # 2. Service status
    print_section "2. Service Activation Status"
    if command -v AssetCacheManagerUtil >/dev/null 2>&1; then
        STATUS_OUT=$(sudo AssetCacheManagerUtil status 2>&1)
        echo "$STATUS_OUT"
        if echo "$STATUS_OUT" | grep -qi '"Activated" = 1\|Activated: true\|Activated = true'; then
            record "ServiceActivated" "OK" "Content Caching service is activated"
        else
            record "ServiceActivated" "FAIL" "Content Caching service does not report activated — check disk space at cache location and profile delivery"
        fi

        if echo "$STATUS_OUT" | grep -qi '"Active" = 1\|Active: true\|Active = true'; then
            record "ServiceActive" "OK" "Content Caching service is actively running"
        else
            record "ServiceActive" "WARN" "Service activated but not currently reporting Active — may still be initializing"
        fi
    else
        record "ServiceStatus" "FAIL" "AssetCacheManagerUtil not found — this macOS version may not support Content Caching, or this device is not the cache host"
    fi

    # 3. Registration / public IP
    print_section "3. Apple Registration Status"
    if command -v AssetCacheManagerUtil >/dev/null 2>&1; then
        REG_INFO=$(sudo AssetCacheManagerUtil status 2>&1 | grep -iE "public|registration")
        echo "  $REG_INFO"
        if echo "$REG_INFO" | grep -qiE "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"; then
            record "Registration" "OK" "Public IP present in status output — host appears registered"
        else
            record "Registration" "FAIL" "No public IP found in status output — registration with Apple's LCDN likely failed (see check 4)"
        fi
    fi

    # 4. Endpoint reachability
    print_section "4. Apple Registration/Config Endpoint Reachability"
    for endpoint_pair in "lcdn-registration.apple.com|https://lcdn-registration.apple.com/lcdn/register" "suconfig.apple.com|https://suconfig.apple.com/resource/registration/v1/config.plist"; do
        HOST_LABEL="${endpoint_pair%%|*}"
        URL="${endpoint_pair##*|}"
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$URL" 2>&1)
        if [[ "$HTTP_CODE" =~ ^[0-9]+$ ]] && [[ "$HTTP_CODE" != "000" ]]; then
            record "Reachability-$HOST_LABEL" "OK" "Reached $HOST_LABEL (HTTP $HTTP_CODE — any response confirms TLS/network path is open)"
        else
            record "Reachability-$HOST_LABEL" "FAIL" "Could not reach $HOST_LABEL — check outbound firewall/proxy rules, especially TLS-intercepting proxies (see ContentCaching-B.md Fix 1)"
        fi
    done

    # 5. Host public IP (for manual comparison against clients)
    print_section "5. Host Public IP"
    HOST_IP=$(curl -s --max-time 8 https://api.ipify.org 2>&1)
    if [[ -n "$HOST_IP" ]]; then
        record "HostPublicIP" "INFO" "$HOST_IP — run this script with '-Mode client' on an affected client and compare; a mismatch is the #1 discovery-failure cause"
    else
        record "HostPublicIP" "WARN" "Could not determine public IP"
    fi

    # 6. Cache storage free space
    print_section "6. Cache Storage Free Space"
    CACHE_PATH="/Library/Application Support/Apple/AssetCache/Data"
    if [[ -d "$CACHE_PATH" ]]; then
        DF_OUT=$(df -h "$CACHE_PATH" 2>&1 | tail -1)
        echo "  $DF_OUT"
        record "CacheStorage" "INFO" "$DF_OUT (default path checked — adjust manually if a custom Cache Location is configured)"
    else
        record "CacheStorage" "WARN" "Default cache path not found — either not yet initialized, or a custom Cache Location is configured (check AssetCacheManagerUtil settings output above)"
    fi

    # 7. Recent activity in unified log
    print_section "7. Recent Content Caching Activity (last 1h)"
    if [[ $EUID -eq 0 ]]; then
        RECENT_ACTIVITY=$(log show --predicate 'subsystem == "com.apple.AssetCache"' --last 1h --info 2>/dev/null | grep -ciE "Received GET|Received PUT|Served")
        if [[ "$RECENT_ACTIVITY" -gt 0 ]]; then
            record "RecentActivity" "OK" "$RECENT_ACTIVITY GET/PUT/serve event(s) in the last hour — cache is actively serving requests"
        else
            record "RecentActivity" "WARN" "No GET/PUT/serve events found in the last hour — this may be normal (no eligible downloads occurred) or may indicate clients aren't reaching the cache; correlate with a known-eligible test download"
        fi
    else
        record "RecentActivity" "WARN" "Root required to read the unified log for this subsystem"
    fi
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
    echo "  Overall: Content Caching looks healthy from this device's perspective ($MODE mode)."
else
    echo "  Overall: Issues found — cross-reference FAIL/WARN checks against ContentCaching-B.md fix paths."
fi

echo ""
echo "  Reminder: discovery is grouped by PUBLIC IP, not by Intune assignment or device group —"
echo "  a host-mode and client-mode run whose public IPs don't match explains most 'configured"
echo "  correctly but nothing happens' tickets on this topic (see ContentCaching-A.md)."
echo ""
echo "  CSV report saved to: $CSV_FILE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  End of report — $(date)"
echo "════════════════════════════════════════════════════════"
