#!/bin/bash
# Get-PPPCStatus.sh
# .SYNOPSIS
#   Collect PPPC/TCC permission state for a target app to speed up triage or escalation.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/PPPC-B.md and PPPC-A.md.
#   Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
#   - Device supervision / MDM enrollment status (PPPC MDM overrides require supervised)
#   - Target app's bundle ID and code signing identity (from the app binary — source of truth)
#   - TCC.db entries for the target app (auth_value, auth_reason, MDM-granted flag)
#   - Installed PPPC/Privacy configuration profiles (grep for TCC/Privacy payloads)
#   - A live decision explaining whether the grant appears MDM-managed, user-granted, or missing
#
#   Produces a console summary with pass/fail per check and exports full detail to CSV,
#   so the output can be pasted directly into the runbook's Escalation Evidence template.
#
#   Does NOT cover:
#   - Editing or re-pushing the PPPC profile in Intune (that's PPPC-B.md Fix 1-2 — this script only detects)
#   - Resetting TCC entries (that's PPPC-B.md Fix 5 — destructive, not run automatically by this script)
#   - Daemon/helper-specific PPPC entries beyond the main app bundle (checked manually per PPPC-B.md Fix 4)
#
# .REQUIREMENTS
#   - macOS 11 (Big Sur) or later
#   - Run as root for full detail: sudo bash Get-PPPCStatus.sh -b <bundleID>
#   - TCC.db read and profile enumeration require root; script degrades gracefully without it
#
# .EXAMPLE
#   sudo bash Get-PPPCStatus.sh -b com.vendor.app
#   sudo bash Get-PPPCStatus.sh -a "/Applications/VendorApp.app"
#
# .NOTES
#   Safe/read-only. Never modifies TCC.db or installed profiles.
#   Tested on macOS 12–15, Intel and Apple Silicon.
#   CSV exported to /tmp/PPPCStatus_<hostname>_<timestamp>.csv

set -uo pipefail

# ─────────────────────────────────────────────
# Args
# ─────────────────────────────────────────────
BUNDLE_ID=""
APP_PATH=""
while getopts "b:a:" opt; do
    case $opt in
        b) BUNDLE_ID="$OPTARG" ;;
        a) APP_PATH="$OPTARG" ;;
        *) echo "Usage: $0 -b <bundleID> | -a </Applications/App.app>"; exit 1 ;;
    esac
done

if [[ -z "$BUNDLE_ID" && -z "$APP_PATH" ]]; then
    echo "Usage: $0 -b <bundleID>   (e.g. -b com.vendor.app)"
    echo "   or: $0 -a <appPath>    (e.g. -a /Applications/VendorApp.app)"
    exit 1
fi

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="/tmp/PPPCStatus_${HOSTNAME}_${TIMESTAMP}.csv"
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0
TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"

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
        echo "  ⚠️  Not running as root. TCC.db and profile enumeration checks will be incomplete."
        echo "  Run: sudo bash $0 ${BUNDLE_ID:+-b $BUNDLE_ID}${APP_PATH:+-a $APP_PATH}"
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  PPPC / TCC Status Report"
echo "  Generated: $(date)"
echo "  Hostname:  $HOSTNAME"
echo "════════════════════════════════════════════════════════"

check_root

# Resolve app path from bundle ID if only bundle ID given
if [[ -z "$APP_PATH" && -n "$BUNDLE_ID" ]]; then
    APP_PATH=$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | grep -m1 "\.app$" || true)
fi

# Resolve bundle ID from app path if only path given
if [[ -z "$BUNDLE_ID" && -n "$APP_PATH" ]]; then
    BUNDLE_ID=$(mdls -name kMDItemCFBundleIdentifier -raw "$APP_PATH" 2>/dev/null || true)
fi

# ─────────────────────────────────────────────
# 1. MDM Enrollment / Supervision Status
# ─────────────────────────────────────────────
print_section "1. MDM Enrollment / Supervision"

ENROLL_STATUS=$(profiles status -type enrollment 2>&1)
echo "  $ENROLL_STATUS"

if echo "$ENROLL_STATUS" | grep -qi "Enrolled via DEP: Yes"; then
    record "Supervision" "OK" "ADE/DEP enrolled — supervised, PPPC MDM overrides can apply"
elif echo "$ENROLL_STATUS" | grep -qi "MDM enrollment: Yes"; then
    record "Supervision" "WARN" "MDM-enrolled but not via DEP — device may be unsupervised; PPPC overrides may not be enforced"
else
    record "Supervision" "FAIL" "Device not enrolled in MDM — PPPC profiles cannot be delivered"
fi

# ─────────────────────────────────────────────
# 2. Bundle ID / Code Signing Identity
# ─────────────────────────────────────────────
print_section "2. Target App Identity"

if [[ -z "$APP_PATH" ]]; then
    record "AppPath" "WARN" "Could not resolve app path for bundle ID '$BUNDLE_ID' — is the app installed?"
elif [[ ! -d "$APP_PATH" ]]; then
    record "AppPath" "FAIL" "App path does not exist: $APP_PATH"
else
    record "AppPath" "OK" "$APP_PATH"

    CODESIGN_OUT=$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)
    SIGNED_ID=$(echo "$CODESIGN_OUT" | grep "^Identifier=" | cut -d= -f2)
    TEAM_ID=$(echo "$CODESIGN_OUT" | grep "^TeamIdentifier=" | cut -d= -f2)

    if [[ -n "$SIGNED_ID" ]]; then
        if [[ -n "$BUNDLE_ID" && "$SIGNED_ID" != "$BUNDLE_ID" ]]; then
            record "BundleIDMatch" "WARN" "Signed identifier ($SIGNED_ID) differs from supplied/queried bundle ID ($BUNDLE_ID) — use the signed value in the PPPC profile"
        else
            record "BundleIDMatch" "OK" "Signed identifier: $SIGNED_ID"
        fi
        BUNDLE_ID="$SIGNED_ID"
    else
        record "CodeSigning" "WARN" "Could not extract signed identifier — app may be unsigned or ad-hoc signed"
    fi

    if [[ -n "$TEAM_ID" && "$TEAM_ID" != "not set" ]]; then
        record "TeamIdentifier" "OK" "Team ID: $TEAM_ID"
    else
        record "TeamIdentifier" "WARN" "No Team ID (ad-hoc/unsigned) — Code Requirement-based PPPC grants will not work reliably"
    fi
fi

# ─────────────────────────────────────────────
# 3. TCC.db Entries for Target App
# ─────────────────────────────────────────────
print_section "3. TCC Database Entries"

if [[ -z "$BUNDLE_ID" ]]; then
    record "TCCEntries" "WARN" "No bundle ID resolved — cannot query TCC.db"
elif [[ $EUID -ne 0 ]]; then
    record "TCCEntries" "WARN" "Root required to read TCC.db"
else
    TCC_ROWS=$(sqlite3 "$TCC_DB" \
        "SELECT service, auth_value, auth_reason FROM access WHERE client = '$BUNDLE_ID';" 2>&1)

    if [[ -z "$TCC_ROWS" ]]; then
        record "TCCEntries" "WARN" "No TCC entries found for $BUNDLE_ID — profile may not have applied yet, or app hasn't launched/requested access"
    else
        record "TCCEntryCount" "INFO" "$(echo "$TCC_ROWS" | wc -l | tr -d ' ') entr(ies) found for $BUNDLE_ID"
        echo "$TCC_ROWS" | while IFS='|' read -r service auth_value auth_reason; do
            echo "    service=$service  auth_value=$auth_value  auth_reason=$auth_reason"
            if [[ "$auth_value" == "2" ]]; then
                if [[ "$auth_reason" == "5" ]]; then
                    record "TCC-$service" "OK" "Allowed, MDM-granted (auth_reason=5)"
                elif [[ "$auth_reason" == "3" ]]; then
                    record "TCC-$service" "OK" "Allowed, user-granted (auth_reason=3) — not MDM-managed but functional"
                else
                    record "TCC-$service" "OK" "Allowed (auth_reason=$auth_reason)"
                fi
            elif [[ "$auth_value" == "0" ]]; then
                record "TCC-$service" "FAIL" "Denied (auth_value=0) — check profile bundle ID / code requirement"
            else
                record "TCC-$service" "WARN" "Unexpected auth_value=$auth_value"
            fi
        done
    fi
fi

# ─────────────────────────────────────────────
# 4. Installed PPPC / Privacy Profiles
# ─────────────────────────────────────────────
print_section "4. Installed PPPC/Privacy Profiles"

if [[ $EUID -ne 0 ]]; then
    record "PPPCProfiles" "WARN" "Root required to enumerate installed profiles"
else
    PROFILE_HITS=$(profiles show -all 2>/dev/null | grep -c "com.apple.TCC.configuration-profile-policy" || true)
    if [[ "$PROFILE_HITS" -gt 0 ]]; then
        record "PPPCProfiles" "OK" "$PROFILE_HITS PPPC payload(s) installed on this device"
    else
        record "PPPCProfiles" "WARN" "No PPPC (com.apple.TCC.configuration-profile-policy) payloads found — profile likely not delivered to this device"
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
    echo "  Overall: PPPC/TCC state for $BUNDLE_ID looks healthy on this device."
else
    echo "  Overall: Issues found — cross-reference FAIL/WARN checks against PPPC-B.md Fix 1-5."
fi

echo ""
echo "  CSV report saved to: $CSV_FILE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  End of report — $(date)"
echo "════════════════════════════════════════════════════════"
