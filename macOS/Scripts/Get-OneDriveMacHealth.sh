#!/bin/bash
# Get-OneDriveMacHealth.sh
# .SYNOPSIS
#   Read-only health check of the OneDrive sync app on macOS (build, managed prefs, background item,
#   File Provider sync root, Folder Backup state).
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/OneDriveMac-B.md and OneDriveMac-A.md.
#   Device-local diagnostic. Gathers, in one pass:
#   - OneDrive build type (standalone com.microsoft.OneDrive vs App Store com.microsoft.OneDrive-mac)
#     and version
#   - Whether managed preferences exist for the domain that MATCHES the installed build (and flags
#     a profile written to the other domain)
#   - Key admin settings: KFM*, AllowTenantList/BlockTenantList (both set = WARN), DisableAutoConfig,
#     DisablePersonalSync, EnableODIgnore/EnableODIgnoreFolders, HydrationDisallowedApps, Tier
#   - Whether OneDrive is running and (when run with sudo) its Background Items entry
#   - File Provider sync root(s) under ~/Library/CloudStorage/OneDrive-*
#   - Folder Backup outcome: Desktop/Documents inside the OneDrive root
#   - Free disk space and most recent OneDrive log file timestamp
#
#   Does NOT cover:
#   - Resetting, signing in/out, changing preferences (read-only)
#   - Tenant-side checks (SharePoint sync restrictions, sync admin reports)
#   - Verifying Full Disk Access grants (TCC db is protected); it only reports whether a PPPC
#     profile mentioning OneDrive is installed when run as root
#
# .PARAMETER --user USERNAME
#   Inspect this user's home/prefs (useful when running with sudo). Defaults to the console user.
#
# .EXAMPLE
#   bash Get-OneDriveMacHealth.sh
#   sudo bash Get-OneDriveMacHealth.sh --user jdoe
#
# .NOTES
#   Run as the affected user for accurate effective prefs; run with sudo additionally to include
#   Background Items (sfltool) and profile checks. Safe/read-only.
#   CSV exported to /tmp/OneDriveMacHealth_<hostname>_<timestamp>.csv

set -uo pipefail

TARGET_USER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) TARGET_USER="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; NC='\033[0m'
status() { local c="$CYN"; case "$1" in OK) c="$GRN";; WARN) c="$YEL";; ERROR) c="$RED";; esac; printf "${c}[%s]${NC} %s\n" "$1" "$2"; }
HOST=$(scutil --get ComputerName 2>/dev/null | tr ' ' '_' || hostname -s)
TS=$(date +%Y%m%d_%H%M%S)
CSV="/tmp/OneDriveMacHealth_${HOST}_${TS}.csv"
echo "Check,Item,Value,Status" > "$CSV"
add() { local v="${3//\"/\'}"; echo "\"$1\",\"$2\",\"$v\",\"$4\"" >> "$CSV"; }

[[ -z "$TARGET_USER" ]] && TARGET_USER=$(stat -f%Su /dev/console 2>/dev/null || id -un)
USER_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[[ -z "$USER_HOME" ]] && USER_HOME="$HOME"
IS_ROOT=0; [[ "$EUID" -eq 0 ]] && IS_ROOT=1

# Run a command as the target user when we're root, so per-user prefs are read correctly
asuser() { if [[ $IS_ROOT -eq 1 && "$TARGET_USER" != "root" ]]; then sudo -u "$TARGET_USER" "$@"; else "$@"; fi; }

echo "=== OneDrive for Mac — Health ($HOST, $TS, user: $TARGET_USER) ==="
add "Context" "macOS" "$(sw_vers -productVersion)" "INFO"

# ─── Install / build ───
APP="/Applications/OneDrive.app"
DOMAIN=""; OTHER=""
if [[ -d "$APP" ]]; then
  BID=$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "unknown")
  VER=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
  case "$BID" in
    com.microsoft.OneDrive)     DOMAIN="com.microsoft.OneDrive";     OTHER="com.microsoft.OneDrive-mac"; status OK "Standalone build $VER ($BID)"; add "Install" "Build" "Standalone $VER" "OK" ;;
    com.microsoft.OneDrive-mac) DOMAIN="com.microsoft.OneDrive-mac"; OTHER="com.microsoft.OneDrive";     status WARN "Mac App Store build $VER — Folder Backup (KFM) NOT supported"; add "Install" "Build" "AppStore $VER" "WARN" ;;
    *) status WARN "Unexpected bundle ID: $BID"; add "Install" "Build" "$BID" "WARN"; DOMAIN="com.microsoft.OneDrive"; OTHER="com.microsoft.OneDrive-mac" ;;
  esac
else
  status ERROR "OneDrive.app not found in /Applications"; add "Install" "Build" "not installed" "ERROR"
  echo "CSV: $CSV"; exit 0
fi

# ─── Managed preferences ───
MP="/Library/Managed Preferences"
if [[ -f "$MP/$DOMAIN.plist" || -f "$MP/$TARGET_USER/$DOMAIN.plist" ]]; then
  status OK "Managed preferences present for $DOMAIN"; add "Policy" "Managed prefs ($DOMAIN)" "present" "OK"
else
  status WARN "No managed preferences for $DOMAIN (profile not delivered or not configured)"; add "Policy" "Managed prefs ($DOMAIN)" "absent" "WARN"
fi
if [[ -f "$MP/$OTHER.plist" || -f "$MP/$TARGET_USER/$OTHER.plist" ]]; then
  status WARN "Managed prefs exist for $OTHER — does NOT match installed build; those settings are ignored"; add "Policy" "Managed prefs ($OTHER)" "present (mismatch)" "WARN"
fi

rd() { asuser defaults read "$DOMAIN" "$1" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g'; }
for KEY in KFMSilentOptIn KFMOptInWithWizard KFMSilentOptInDesktop KFMSilentOptInDocuments KFMBlockOptIn KFMBlockOptOut \
           DisableAutoConfig DisablePersonalSync BlockExternalSync EnableODIgnore EnableODIgnoreFolders HydrationDisallowedApps EnableSyncAdminReports; do
  V=$(rd "$KEY")
  if [[ -n "$V" ]]; then status INFO "$KEY = $V"; add "Setting" "$KEY" "$V" "INFO"; fi
done
ALLOW=$(rd AllowTenantList); BLOCK=$(rd BlockTenantList)
[[ -n "$ALLOW" ]] && add "Setting" "AllowTenantList" "$ALLOW" "INFO"
[[ -n "$BLOCK" ]] && add "Setting" "BlockTenantList" "$BLOCK" "INFO"
if [[ -n "$ALLOW" && -n "$BLOCK" ]]; then status WARN "Both AllowTenantList and BlockTenantList set — Microsoft says do not enable both"; add "Setting" "Tenant lists" "both set" "WARN"; fi
KSO=$(rd KFMSilentOptIn); KBI=$(rd KFMBlockOptIn)
if [[ -n "$KSO" && ! "$KSO" =~ ^[0-9a-fA-F-]{36}$ ]]; then status WARN "KFMSilentOptIn is not a tenant GUID ('$KSO')"; add "Setting" "KFMSilentOptIn format" "$KSO" "WARN"; fi
if [[ -n "$KSO" && -n "$KBI" ]]; then status WARN "KFMBlockOptIn set alongside KFMSilentOptIn — block is ignored; check intent"; add "Setting" "KFM conflict" "SilentOptIn+BlockOptIn" "WARN"; fi
TIER=$(asuser defaults read com.microsoft.OneDriveUpdater Tier 2>/dev/null || true)
[[ -n "$TIER" ]] && { status INFO "Update ring (Tier) = $TIER"; add "Setting" "Tier" "$TIER" "INFO"; }

# ─── Running / background ───
if pgrep -x OneDrive >/dev/null; then status OK "OneDrive process running"; add "Runtime" "Process" "running" "OK"
else status WARN "OneDrive not running"; add "Runtime" "Process" "not running" "WARN"; fi
if [[ $IS_ROOT -eq 1 ]]; then
  BTM=$(sfltool dumpbtm 2>/dev/null | grep -i -A6 "onedrive" | grep -iE "Disposition" | head -3 | tr '\n' ' ')
  if [[ -n "$BTM" ]]; then status INFO "Background item: $BTM"; add "Runtime" "Background item" "$BTM" "INFO"
  else status WARN "No OneDrive Background Items entry found"; add "Runtime" "Background item" "none" "WARN"; fi
  if profiles show -type configuration 2>/dev/null | grep -qi "com.microsoft.OneDrive"; then
    status OK "A configuration profile references com.microsoft.OneDrive (PPPC/login items/prefs)"; add "Policy" "Profile mentions OneDrive" "yes" "OK"
  else
    status WARN "No installed profile references com.microsoft.OneDrive"; add "Policy" "Profile mentions OneDrive" "no" "WARN"
  fi
else
  status INFO "Not root — skipping Background Items and profile checks (re-run with sudo)"; add "Runtime" "Background item" "SKIPPED (not root)" "INFO"
fi

# ─── File Provider sync root & Folder Backup ───
shopt -s nullglob
ROOTS=("$USER_HOME"/Library/CloudStorage/OneDrive-*)
shopt -u nullglob
if [[ ${#ROOTS[@]} -eq 0 ]]; then
  status WARN "No ~/Library/CloudStorage/OneDrive-* sync root (not signed in, or File Provider domain broken)"; add "FileProvider" "Sync root" "none" "WARN"
else
  for R in "${ROOTS[@]}"; do
    N=$(basename "$R"); status OK "Sync root: $N"; add "FileProvider" "Sync root" "$N" "OK"
    for F in Desktop Documents; do
      if [[ -d "$R/$F" ]]; then status OK "  $F present in $N (Folder Backup in effect)"; add "FolderBackup" "$F in $N" "present" "OK"
      elif [[ -n "$KSO" ]]; then status WARN "  $F not in $N although KFMSilentOptIn is set"; add "FolderBackup" "$F in $N" "absent" "WARN"; fi
    done
  done
fi

# ─── Disk & logs ───
FREE=$(df -Pk "$USER_HOME" | awk 'NR==2{printf "%.1f GB", $4/1048576}')
status INFO "Free space on home volume: $FREE"; add "Context" "Free space" "$FREE" "INFO"
LOGDIR="$USER_HOME/Library/Logs/OneDrive"
if [[ -d "$LOGDIR" ]]; then
  LAST=$(ls -t "$LOGDIR" 2>/dev/null | head -1)
  status INFO "Latest log: $LAST"; add "Logs" "Latest OneDrive log" "$LAST" "INFO"
else
  status WARN "No OneDrive log directory at $LOGDIR"; add "Logs" "Log dir" "absent" "WARN"
fi

echo "=== Done. CSV: $CSV ==="
