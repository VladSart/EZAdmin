#!/bin/bash
# Get-FileVaultStatus.sh
# .SYNOPSIS
#   Collect FileVault encryption, escrow, and token health for triage or escalation.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/FileVault-B.md and FileVault-A.md.
#   Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
#   - fdesetup status (on/off/encrypting) and enabled-user list
#   - Secure Token status for the console user and local admins
#   - Bootstrap Token escrow state (profiles show -type bootstraptoken)
#   - MDM enrollment type (ADE/supervised vs. user-enrolled) — Bootstrap Token requires ADE
#   - Presence of the FileVault MDM configuration profile (com.apple.MCX.FileVault2)
#   - Disk free space (relevant to stuck/stalled encryption)
#   - Power source (FileVault pauses encryption on battery on many models)
#
#   Produces a console summary with pass/fail per check and exports full detail to CSV,
#   so the output can be pasted directly into the runbook's Escalation Evidence template.
#
#   Does NOT cover:
#   - Rotating recovery keys or enabling FileVault (that's FileVault-B.md Fix 1 / Fix 2)
#   - Reading or displaying the actual recovery key value (never printed by this script)
#   - Verifying the key is present server-side in Intune (must be checked in the portal)
#
# .REQUIREMENTS
#   - macOS 11 (Big Sur) or later
#   - Run as root for full detail: sudo bash Get-FileVaultStatus.sh
#   - Some checks (fdesetup list, bootstraptoken) require root; script degrades gracefully without it
#
# .EXAMPLE
#   sudo bash Get-FileVaultStatus.sh
#   sudo bash Get-FileVaultStatus.sh -u jsmith
#
# .NOTES
#   Safe/read-only. Never prints or exports the actual recovery key value.
#   Tested on macOS 12–15, Intel (T2) and Apple Silicon.
#   CSV exported to /tmp/FileVaultStatus_<hostname>_<timestamp>.csv

set -uo pipefail

# ─────────────────────────────────────────────
# Args
# ─────────────────────────────────────────────
TARGET_USER=""
while getopts "u:" opt; do
    case $opt in
        u) TARGET_USER="$OPTARG" ;;
        *) echo "Usage: $0 [-u <username>]"; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="/tmp/FileVaultStatus_${HOSTNAME}_${TIMESTAMP}.csv"
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
    # Escape commas in detail for CSV safety
    local safe_detail
    safe_detail=$(echo "$detail" | tr ',' ';')
    echo "\"$check\",\"$status\",\"$safe_detail\"" >> "$CSV_FILE"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo ""
        echo "  ⚠️  Not running as root. fdesetup list / bootstraptoken checks will be incomplete."
        echo "  Run: sudo bash $0"
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  FileVault Status Report"
echo "  Generated: $(date)"
echo "  Hostname:  $HOSTNAME"
echo "════════════════════════════════════════════════════════"

check_root

# If no target user supplied, default to the console user
if [[ -z "$TARGET_USER" ]]; then
    TARGET_USER=$(stat -f%Su /dev/console 2>/dev/null || echo "")
fi

# ─────────────────────────────────────────────
# 1. FileVault On/Off Status
# ─────────────────────────────────────────────
print_section "1. FileVault Status"

FV_STATUS=$(fdesetup status 2>&1)
echo "  $FV_STATUS"

if echo "$FV_STATUS" | grep -qi "FileVault is On"; then
    record "FileVaultEnabled" "OK" "FileVault is On"
elif echo "$FV_STATUS" | grep -qi "Encryption in progress\|Decryption in progress"; then
    record "FileVaultEnabled" "WARN" "$(echo "$FV_STATUS" | head -1)"
elif echo "$FV_STATUS" | grep -qi "FileVault is Off"; then
    record "FileVaultEnabled" "FAIL" "FileVault is Off"
else
    record "FileVaultEnabled" "WARN" "Unexpected status: $FV_STATUS"
fi

# ─────────────────────────────────────────────
# 2. Enabled Users (who can unlock)
# ─────────────────────────────────────────────
print_section "2. FileVault-Enabled Users"

if [[ $EUID -eq 0 ]]; then
    FV_USERS=$(fdesetup list 2>&1)
    echo "  $FV_USERS"
    if [[ -n "$FV_USERS" ]] && ! echo "$FV_USERS" | grep -qi "no such\|error"; then
        USER_COUNT=$(echo "$FV_USERS" | grep -c ",")
        record "FileVaultUserList" "OK" "$USER_COUNT user(s) enabled: $(echo "$FV_USERS" | cut -d, -f1 | tr '\n' ';')"
        if [[ -n "$TARGET_USER" ]] && ! echo "$FV_USERS" | grep -qi "^$TARGET_USER,"; then
            record "TargetUserFVEnabled" "WARN" "$TARGET_USER is NOT in the FileVault-enabled user list"
        fi
    else
        record "FileVaultUserList" "FAIL" "No users enabled for FileVault unlock"
    fi
else
    record "FileVaultUserList" "WARN" "Root required to list FileVault users"
fi

# ─────────────────────────────────────────────
# 3. Secure Token Status
# ─────────────────────────────────────────────
print_section "3. Secure Token"

if [[ -n "$TARGET_USER" ]]; then
    ST_STATUS=$(sysadminctl -secureTokenStatus "$TARGET_USER" 2>&1)
    echo "  $ST_STATUS"
    if echo "$ST_STATUS" | grep -qi "ENABLED"; then
        record "SecureToken-$TARGET_USER" "OK" "Secure Token enabled"
    else
        record "SecureToken-$TARGET_USER" "FAIL" "Secure Token NOT enabled — user cannot unlock disk or be FV-enabled"
    fi
else
    record "SecureToken" "WARN" "No target/console user detected — pass -u <username> to check"
fi

# List all local admins and their Secure Token state
echo ""
echo "  Local admin accounts and Secure Token state:"
dscl . read /Groups/admin GroupMembership 2>/dev/null | sed 's/GroupMembership: //' | tr ' ' '\n' | grep -v "^root$\|^$" | while read -r admin; do
    st=$(sysadminctl -secureTokenStatus "$admin" 2>&1 | grep -o "ENABLED\|DISABLED" || echo "UNKNOWN")
    printf "    %-20s %s\n" "$admin" "$st"
done

# ─────────────────────────────────────────────
# 4. Bootstrap Token Escrow
# ─────────────────────────────────────────────
print_section "4. Bootstrap Token (MDM silent-management capability)"

if [[ $EUID -eq 0 ]]; then
    BT_STATUS=$(profiles show -type bootstraptoken 2>&1)
    echo "  $BT_STATUS"
    if echo "$BT_STATUS" | grep -qi "escrowed to the MDM server\|Bootstrap Token.*escrowed"; then
        record "BootstrapToken" "OK" "Bootstrap Token escrowed to MDM"
    else
        record "BootstrapToken" "WARN" "Bootstrap Token not escrowed — silent recovery key rotation / user-add unavailable"
    fi
else
    record "BootstrapToken" "WARN" "Root required to check Bootstrap Token"
fi

# ─────────────────────────────────────────────
# 5. MDM Enrollment Type (ADE required for Bootstrap Token)
# ─────────────────────────────────────────────
print_section "5. MDM Enrollment Type"

ENROLL_STATUS=$(profiles status -type enrollment 2>&1)
echo "  $ENROLL_STATUS"

if echo "$ENROLL_STATUS" | grep -qi "Enrolled via DEP: Yes"; then
    record "EnrollmentType" "OK" "ADE/DEP supervised — Bootstrap Token eligible"
elif echo "$ENROLL_STATUS" | grep -qi "MDM enrollment: Yes"; then
    record "EnrollmentType" "WARN" "User-enrolled MDM — Bootstrap Token NOT available (Apple limitation)"
else
    record "EnrollmentType" "FAIL" "Device not enrolled in MDM"
fi

# ─────────────────────────────────────────────
# 6. FileVault MDM Profile Present
# ─────────────────────────────────────────────
print_section "6. FileVault MDM Configuration Profile"

if [[ $EUID -eq 0 ]]; then
    if profiles show -all 2>/dev/null | grep -qi "FileVault"; then
        record "FileVaultProfile" "OK" "FileVault MDM payload found in installed profiles"
    else
        record "FileVaultProfile" "WARN" "No FileVault-specific MDM payload found — Intune Disk Encryption policy may not be targeting this device"
    fi
else
    record "FileVaultProfile" "WARN" "Root required to enumerate installed profiles"
fi

# ─────────────────────────────────────────────
# 7. Disk Space (relevant to stalled encryption)
# ─────────────────────────────────────────────
print_section "7. Disk Free Space"

DISK_INFO=$(df -h / | tail -1)
echo "  $DISK_INFO"
FREE_PCT=$(df / | tail -1 | awk '{gsub("%","",$5); print 100-$5}')
if [[ "$FREE_PCT" -ge 10 ]]; then
    record "DiskFreeSpace" "OK" "${FREE_PCT}% free"
else
    record "DiskFreeSpace" "WARN" "Only ${FREE_PCT}% free — low disk space can stall encryption"
fi

# ─────────────────────────────────────────────
# 8. Power Source (encryption pauses on battery on some models)
# ─────────────────────────────────────────────
print_section "8. Power Source"

POWER_INFO=$(pmset -g batt 2>/dev/null | head -1)
echo "  $POWER_INFO"
if echo "$POWER_INFO" | grep -qi "AC Power"; then
    record "PowerSource" "OK" "On AC power"
elif echo "$POWER_INFO" | grep -qi "Battery Power"; then
    record "PowerSource" "WARN" "On battery — encryption may pause; connect to power if encrypting"
else
    record "PowerSource" "INFO" "Could not determine power source (desktop Mac?)"
fi

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
print_section "Summary"
printf "  %-20s %s\n" "Checks OK:"     "$CHECKS_PASSED"
printf "  %-20s %s\n" "Checks WARN:"   "$CHECKS_WARNED"
printf "  %-20s %s\n" "Checks FAIL:"   "$CHECKS_FAILED"
echo ""
if [[ "$CHECKS_FAILED" -eq 0 ]]; then
    echo "  Overall: FileVault looks healthy on this device."
else
    echo "  Overall: Issues found — cross-reference FAIL/WARN checks against FileVault-B.md fix paths."
fi

echo ""
echo "  CSV report saved to: $CSV_FILE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  End of report — $(date)"
echo "════════════════════════════════════════════════════════"
