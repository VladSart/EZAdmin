#!/bin/bash
# Get-TimeMachineBackupAudit.sh
# .SYNOPSIS
#   Collect managed Time Machine configuration, destination, and backup execution status
#   for triage or escalation, per TimeMachine-B.md and TimeMachine-A.md.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/TimeMachine-B.md and TimeMachine-A.md.
#   Because the com.apple.MCX.TimeMachine MDM payload is configuration-delivery-only —
#   there is no Intune-side compliance signal or portal report for backup completion —
#   this script exists specifically to fill that visibility gap on-device, in one pass:
#   - Enrollment method (Device Enrollment/ADE required; payload unsupported on BYOD)
#   - Presence of the managed TimeMachine profile (profiles -P)
#   - Managed Preferences plist content (destination, auto-backup, exclusions as configured)
#   - All known Time Machine destinations (tmutil destinationinfo -A) — flags mismatches
#     between the managed destination and any user-added ones
#   - Destination network reachability (best-effort, SMB share test if URL looks like smb://)
#   - Current backup status and recency of last successful backup
#   - Destination free space (when locally mounted/visible)
#
#   Produces a console summary with pass/fail per check and exports full detail to CSV,
#   so output can be pasted directly into the runbook's Escalation Evidence template.
#
#   Does NOT cover:
#   - Provisioning or storing destination credentials (this is the payload's own gap —
#     see TimeMachine-B.md Fix 1; this script can only report whether a credential
#     appears to already exist in the console user's keychain, not create one)
#   - Forcing a backup (see TimeMachine-B.md Fix 2 for `tmutil startbackup --auto`)
#   - Deleting/removing destinations (see TimeMachine-B.md Fix 4 — a manual, deliberate action)
#
# .REQUIREMENTS
#   - macOS 11 (Big Sur) or later
#   - Run as root for full detail (managed preferences + all profiles): sudo bash Get-TimeMachineBackupAudit.sh
#   - Some checks degrade gracefully without root
#
# .EXAMPLE
#   sudo bash Get-TimeMachineBackupAudit.sh
#   sudo bash Get-TimeMachineBackupAudit.sh -s 7        # flag backups older than 7 days as stale
#
# .NOTES
#   Safe/read-only. Never modifies destinations, never starts/stops backups, never touches
#   Keychain entries (only checks for presence via `security find-internet-password`).
#   CSV exported to /tmp/TimeMachineAudit_<hostname>_<timestamp>.csv

set -uo pipefail

# ─────────────────────────────────────────────
# Args
# ─────────────────────────────────────────────
STALE_DAYS=3
while getopts "s:" opt; do
    case $opt in
        s) STALE_DAYS="$OPTARG" ;;
        *) echo "Usage: $0 [-s <staleDays>]"; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="/tmp/TimeMachineAudit_${HOSTNAME}_${TIMESTAMP}.csv"
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
        echo "  ⚠️  Not running as root. Managed preferences / full profile list checks will be incomplete."
        echo "  Run: sudo bash $0"
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  Time Machine Backup Audit"
echo "  Generated: $(date)"
echo "  Hostname:  $HOSTNAME"
echo "════════════════════════════════════════════════════════"

check_root

# ─────────────────────────────────────────────
# 1. Enrollment method (payload gate — BYOD unsupported)
# ─────────────────────────────────────────────
print_section "1. MDM Enrollment Method"

ENROLL_STATUS=$(profiles status -type enrollment 2>&1)
echo "  $ENROLL_STATUS"

if echo "$ENROLL_STATUS" | grep -qi "Enrolled via DEP: Yes"; then
    record "EnrollmentType" "OK" "ADE/DEP enrolled — Time Machine payload supported"
elif echo "$ENROLL_STATUS" | grep -qi "MDM enrollment: Yes"; then
    record "EnrollmentType" "WARN" "MDM-enrolled but not confirmed ADE — verify Device Enrollment vs. BYOD; the Time Machine payload does not support user-approved/BYOD enrollment"
else
    record "EnrollmentType" "FAIL" "Device not enrolled in MDM — Time Machine payload cannot be delivered"
fi

# ─────────────────────────────────────────────
# 2. Managed profile present
# ─────────────────────────────────────────────
print_section "2. Managed Time Machine Profile"

if [[ $EUID -eq 0 ]]; then
    if profiles -P 2>/dev/null | grep -qi "TimeMachine"; then
        record "ManagedProfile" "OK" "TimeMachine MDM payload found in installed profiles"
    else
        record "ManagedProfile" "FAIL" "No TimeMachine payload found in installed profiles — policy not assigned or not yet synced"
    fi
else
    record "ManagedProfile" "WARN" "Root required to enumerate installed profiles"
fi

# ─────────────────────────────────────────────
# 3. Managed Preferences content
# ─────────────────────────────────────────────
print_section "3. Managed Preferences (com.apple.TimeMachine.plist)"

MP_PATH="/Library/Managed Preferences/com.apple.TimeMachine.plist"
if [[ $EUID -eq 0 ]]; then
    if [[ -f "$MP_PATH" ]]; then
        MP_CONTENT=$(defaults read "$MP_PATH" 2>&1)
        echo "  $MP_CONTENT"
        if [[ -n "$MP_CONTENT" ]] && ! echo "$MP_CONTENT" | grep -qi "does not exist\|error"; then
            record "ManagedPreferences" "OK" "Managed preferences populated"
        else
            record "ManagedPreferences" "FAIL" "Managed preferences file present but empty/unreadable — payload may be malformed"
        fi
    else
        record "ManagedPreferences" "WARN" "Managed preferences file not found at expected path — profile may not have finished processing"
    fi
else
    record "ManagedPreferences" "WARN" "Root required to read managed preferences"
fi

# ─────────────────────────────────────────────
# 4. Destinations (managed vs. any user-added)
# ─────────────────────────────────────────────
print_section "4. Time Machine Destinations"

DEST_INFO=$(tmutil destinationinfo -A 2>&1)
echo "  $DEST_INFO"

if echo "$DEST_INFO" | grep -qi "No destinations configured"; then
    record "Destinations" "FAIL" "No Time Machine destinations configured on this device"
else
    DEST_COUNT=$(echo "$DEST_INFO" | grep -c "^Name" || echo 0)
    record "Destinations" "OK" "$DEST_COUNT destination(s) found"
    if [[ "$DEST_COUNT" -gt 1 ]]; then
        record "MultipleDestinations" "WARN" "More than one destination configured — confirm which is the MDM-managed one vs. user-added (see TimeMachine-B.md Fix 4)"
    fi
fi

# Extract destination URL(s) for reachability testing
DEST_URLS=$(echo "$DEST_INFO" | grep -i "^URL" | sed 's/^URL[[:space:]]*:[[:space:]]*//')

# ─────────────────────────────────────────────
# 5. Destination reachability (best-effort, SMB only)
# ─────────────────────────────────────────────
print_section "5. Destination Reachability"

if [[ -z "$DEST_URLS" ]]; then
    record "DestinationReachability" "WARN" "No destination URL available to test (see check 4)"
else
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        if [[ "$url" == smb://* ]]; then
            SMB_HOST=$(echo "$url" | sed -E 's#smb://([^/]+)/.*#\1#')
            if command -v smbutil >/dev/null 2>&1; then
                SMB_TEST=$(smbutil view "//$SMB_HOST" 2>&1)
                if echo "$SMB_TEST" | grep -qi "error\|failed\|denied\|no route"; then
                    record "DestinationReachability" "FAIL" "SMB host $SMB_HOST unreachable or auth failed: $(echo "$SMB_TEST" | head -1)"
                else
                    record "DestinationReachability" "OK" "SMB host $SMB_HOST reachable"
                fi
            else
                record "DestinationReachability" "INFO" "smbutil not available — cannot test $url"
            fi
        else
            record "DestinationReachability" "INFO" "Non-SMB destination ($url) — reachability not tested by this script, check manually"
        fi
    done <<< "$DEST_URLS"
fi

# ─────────────────────────────────────────────
# 6. Credential presence (console user keychain, best-effort)
# ─────────────────────────────────────────────
print_section "6. Destination Credential Presence (best-effort)"

CONSOLE_USER=$(stat -f%Su /dev/console 2>/dev/null || echo "")
if [[ -n "$CONSOLE_USER" && -n "$DEST_URLS" ]]; then
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        SMB_HOST=$(echo "$url" | sed -E 's#smb://([^/]+)/.*#\1#')
        [[ "$url" != smb://* ]] && continue
        CRED_CHECK=$(sudo -u "$CONSOLE_USER" security find-internet-password -s "$SMB_HOST" 2>&1)
        if echo "$CRED_CHECK" | grep -qi "could not be found\|does not exist"; then
            record "CredentialPresence-$SMB_HOST" "WARN" "No stored credential found for $SMB_HOST in $CONSOLE_USER's keychain — unattended backup may fail (see TimeMachine-B.md Fix 1)"
        else
            record "CredentialPresence-$SMB_HOST" "OK" "Credential entry found for $SMB_HOST"
        fi
    done <<< "$DEST_URLS"
else
    record "CredentialPresence" "INFO" "No console user detected or no SMB destination to check"
fi

# ─────────────────────────────────────────────
# 7. Backup execution status
# ─────────────────────────────────────────────
print_section "7. Backup Execution Status"

TM_STATUS=$(tmutil status 2>&1)
echo "  $TM_STATUS"

LAST_BACKUP=$(tmutil latestbackup 2>&1)
if [[ "$LAST_BACKUP" == /* ]]; then
    LAST_BACKUP_DATE=$(basename "$LAST_BACKUP" | sed -E 's/\.backup$//' | cut -d'-' -f1-3)
    LAST_BACKUP_EPOCH=$(date -j -f "%Y-%m-%d" "$LAST_BACKUP_DATE" "+%s" 2>/dev/null || echo 0)
    NOW_EPOCH=$(date "+%s")
    if [[ "$LAST_BACKUP_EPOCH" -gt 0 ]]; then
        DAYS_SINCE=$(( (NOW_EPOCH - LAST_BACKUP_EPOCH) / 86400 ))
        if [[ "$DAYS_SINCE" -le "$STALE_DAYS" ]]; then
            record "LastBackupRecency" "OK" "Last backup $DAYS_SINCE day(s) ago ($LAST_BACKUP)"
        else
            record "LastBackupRecency" "WARN" "Last backup $DAYS_SINCE day(s) ago — exceeds ${STALE_DAYS}-day staleness threshold"
        fi
    else
        record "LastBackupRecency" "INFO" "Could not parse backup date from: $LAST_BACKUP"
    fi
else
    record "LastBackupRecency" "FAIL" "No completed backups found (tmutil latestbackup returned no path)"
fi

if echo "$TM_STATUS" | grep -qi '"Running" = 1'; then
    record "BackupInProgress" "INFO" "A backup is currently running"
fi

# ─────────────────────────────────────────────
# 8. Destination free space (if locally mounted/visible)
# ─────────────────────────────────────────────
print_section "8. Destination Free Space (if mounted)"

MOUNTED_DEST=$(echo "$DEST_INFO" | grep -i "^Mount Point" | sed 's/^Mount Point[[:space:]]*:[[:space:]]*//' | head -1)
if [[ -n "$MOUNTED_DEST" && -d "$MOUNTED_DEST" ]]; then
    DEST_DF=$(df -h "$MOUNTED_DEST" 2>&1 | tail -1)
    echo "  $DEST_DF"
    record "DestinationFreeSpace" "INFO" "$DEST_DF"
else
    record "DestinationFreeSpace" "INFO" "Destination not currently mounted/visible locally — cannot check free space from this device"
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
    echo "  Overall: Managed Time Machine configuration looks healthy on this device."
else
    echo "  Overall: Issues found — cross-reference FAIL/WARN checks against TimeMachine-B.md fix paths."
fi

echo ""
echo "  Reminder: this script cannot see Intune-side policy assignment or confirm backup"
echo "  completion from the portal — there is no such signal (see TimeMachine-A.md Scope)."
echo ""
echo "  CSV report saved to: $CSV_FILE"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  End of report — $(date)"
echo "════════════════════════════════════════════════════════"
