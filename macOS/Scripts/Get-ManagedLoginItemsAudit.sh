#!/bin/bash
# Get-ManagedLoginItemsAudit.sh
# .SYNOPSIS
#   Collect Managed Login Items (com.apple.servicemanagement) applicability, delivery, and
#   rule-matching status for triage or escalation.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/ManagedLoginItems-B.md and ManagedLoginItems-A.md.
#   Device-local diagnostic (this payload's state has no meaningful Graph/Intune-portal-side
#   equivalent to check remotely — Intune only confirms profile assignment/delivery status, not
#   whether the OS actually matched any items against the profile's rules).
#
#   Gathers, in one pass, everything the runbooks' triage and diagnosis steps ask for:
#   - macOS version vs. the macOS 13 (Ventura) hard floor for this payload
#   - Presence of a Service Management (com.apple.servicemanagement) MDM configuration profile
#   - Full sfltool dumpbtm output — the single most useful diagnostic surface for this topic
#   - Optional per-app lookup (-AppPath) reporting BundleIdentifier and TeamIdentifier for a
#     specific app under investigation, to cross-reference against configured profile rules
#   - Recent com.apple.backgroundtaskmanagement/mcx log activity
#
#   Produces a console summary with pass/fail per check and exports full detail to CSV, so the
#   output can be pasted directly into the runbooks' Escalation Evidence template.
#
#   Does NOT cover:
#   - Editing or creating Service Management profile rules in Intune (that's a portal-side task)
#   - Resetting login/background item data (sfltool resetbtm is destructive and NOT run by this
#     script — see ManagedLoginItems-B.md if a reset is genuinely needed)
#   - Confirming whether a specific item is visible in the System Settings > Login Items UI
#     (no CLI equivalent exists for that specific view; requires screen access)
#
# .REQUIREMENTS
#   - macOS 13 (Ventura) or later for sfltool/servicemanagement checks to be meaningful — the
#     script still runs on earlier macOS but will flag the version gap immediately
#   - Run with sudo for complete profile enumeration and sfltool output
#
# .EXAMPLE
#   sudo bash Get-ManagedLoginItemsAudit.sh
#   sudo bash Get-ManagedLoginItemsAudit.sh -AppPath "/Applications/Company Portal.app"
#
# .NOTES
#   Safe/read-only. Makes no profile, registration, or reset changes.
#   CSV exported to /tmp/ManagedLoginItemsAudit_<hostname>_<timestamp>.csv

set -uo pipefail

# ─────────────────────────────────────────────
# Args
# ─────────────────────────────────────────────
APP_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -AppPath|--app-path)
            APP_PATH="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="/tmp/ManagedLoginItemsAudit_${HOSTNAME}_${TIMESTAMP}.csv"
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
        echo "  ⚠️  Not running as root. Profile enumeration and sfltool output will be incomplete."
        echo "  Run: sudo bash $0"
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  Managed Login Items Status Report"
echo "  Generated: $(date)"
echo "  Hostname:  $HOSTNAME"
echo "════════════════════════════════════════════════════════"

check_root

# ─────────────────────────────────────────────
# 1. macOS version gate (hard floor, non-retroactive)
# ─────────────────────────────────────────────
print_section "1. macOS Version"

OS_VERSION=$(sw_vers -productVersion)
echo "  macOS $OS_VERSION"
OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)

if [[ "$OS_MAJOR" -ge 13 ]]; then
    record "macOSVersion" "OK" "$OS_VERSION — meets the macOS 13 floor for Managed Login Items"
else
    record "macOSVersion" "FAIL" "$OS_VERSION — below minimum (13.0). Payload cannot apply, and will NOT apply retroactively after a later upgrade without a fresh sync."
fi

# ─────────────────────────────────────────────
# 2. Service Management MDM profile presence
# ─────────────────────────────────────────────
print_section "2. Service Management Configuration Profile"

if [[ $EUID -eq 0 ]]; then
    SM_PROFILE=$(profiles -P 2>/dev/null | grep -i -B1 -A8 "servicemanagement\|Login Items")
    if [[ -n "$SM_PROFILE" ]]; then
        echo "  $SM_PROFILE"
        record "ServiceManagementProfile" "OK" "Service Management / Login Items profile found on device"
    else
        record "ServiceManagementProfile" "FAIL" "No Service Management profile found — MDM profile not delivered or not assigned"
    fi
else
    record "ServiceManagementProfile" "WARN" "Root required to reliably enumerate installed profiles"
fi

# ─────────────────────────────────────────────
# 3. Full login/background item dump (sfltool dumpbtm)
# ─────────────────────────────────────────────
print_section "3. Login & Background Item Dump (sfltool dumpbtm)"

if command -v sfltool >/dev/null 2>&1; then
    if [[ $EUID -eq 0 ]]; then
        DUMPBTM_OUTPUT=$(sfltool dumpbtm 2>&1)
        echo "$DUMPBTM_OUTPUT"
        ITEM_COUNT=$(echo "$DUMPBTM_OUTPUT" | grep -ci "identifier\|label" || true)
        record "DumpBTM" "INFO" "sfltool dumpbtm ran — see console output above for matched/unmatched items ($ITEM_COUNT identifier/label references found)"
    else
        record "DumpBTM" "WARN" "sfltool dumpbtm requires root for complete output — re-run with sudo"
    fi
else
    record "DumpBTM" "FAIL" "sfltool command not found — macOS may be below the version that ships this tool"
fi

# ─────────────────────────────────────────────
# 4. Optional per-app identifier lookup
# ─────────────────────────────────────────────
print_section "4. Target App Identifier Lookup"

if [[ -n "$APP_PATH" ]]; then
    if [[ -d "$APP_PATH" ]]; then
        BUNDLE_ID=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "unknown")
        echo "  App path:            $APP_PATH"
        echo "  BundleIdentifier:    $BUNDLE_ID"
        record "AppBundleIdentifier" "INFO" "$BUNDLE_ID"

        TEAM_ID=$(codesign -dv "$APP_PATH" 2>&1 | grep "TeamIdentifier" | sed 's/TeamIdentifier=//')
        echo "  TeamIdentifier:      ${TEAM_ID:-none/ad-hoc signed}"
        if [[ -n "$TEAM_ID" && "$TEAM_ID" != "not set" ]]; then
            record "AppTeamIdentifier" "INFO" "$TEAM_ID"
        else
            record "AppTeamIdentifier" "WARN" "No TeamIdentifier found — app may be ad-hoc signed or unsigned; TeamIdentifier rules cannot match this app"
        fi

        echo ""
        echo "  Compare BundleIdentifier/TeamIdentifier above against the rules configured in the"
        echo "  Service Management profile in Intune to confirm an exact (or correct prefix) match."
    else
        record "AppBundleIdentifier" "FAIL" "App path not found: $APP_PATH"
    fi
else
    record "AppBundleIdentifier" "INFO" "No -AppPath supplied — skipped. Re-run with -AppPath \"/Applications/<App>.app\" to check a specific app's identifiers."
fi

# ─────────────────────────────────────────────
# 5. Recent Background Task Management log activity
# ─────────────────────────────────────────────
print_section "5. Recent Background Task Management Log Activity (last 1h)"

BTM_LOG=$(log show --predicate "subsystem = 'com.apple.backgroundtaskmanagement' and category = 'mcx'" --last 1h 2>/dev/null)
if [[ -n "$BTM_LOG" ]]; then
    echo "$BTM_LOG" | tail -30
    LOG_LINES=$(echo "$BTM_LOG" | wc -l | tr -d ' ')
    record "BTMLogActivity" "INFO" "$LOG_LINES log line(s) found in last 1h — see console output above (showing last 30)"
else
    record "BTMLogActivity" "INFO" "No backgroundtaskmanagement/mcx log activity in the last 1h — normal if no items were recently installed or matched"
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
    echo "  Overall: Managed Login Items looks healthy on this device."
    echo "  If a specific item still isn't managed, cross-reference the sfltool dumpbtm output"
    echo "  above (Section 3) against the profile's configured rules in Intune — this is a"
    echo "  rule-matching check, not something this script can confirm without the portal-side"
    echo "  rule values."
else
    echo "  Overall: Issues found — cross-reference FAIL/WARN checks against ManagedLoginItems-B.md fix paths."
fi

echo ""
echo "  CSV report saved to: $CSV_FILE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  End of report — $(date)"
echo "════════════════════════════════════════════════════════"
