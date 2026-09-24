#!/bin/bash
# Get-TeamsMacHealth.sh
# .SYNOPSIS
#   Read-only health check of the Microsoft Teams client on macOS (com.microsoft.teams2): install,
#   classic leftovers, managed prefs, local state, audio driver, PPPC/notification profiles, network.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/TeamsMac-B.md and TeamsMac-A.md.
#   Device-local diagnostic. Gathers, in one pass:
#   - Current Teams install (bundle ID must be com.microsoft.teams2), version, architecture
#   - Classic Teams leftovers (Microsoft Teams classic.app / com.microsoft.teams) — WARN
#   - Managed com.microsoft.teams2 prefs, including CloudType (1/2/3/4/7) sanity
#   - Local state folders (Group Container + Container) and their size
#   - Teams audio driver (/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver)
#   - When run as root: configuration profiles mentioning com.microsoft.teams2 (PPPC denies,
#     notification settings)
#   - Whether Teams is running; proxy presence; TCP 443 reachability to teams.microsoft.com
#   - Presence of recently collected support logs in ~/Downloads
#
#   Does NOT cover:
#   - Clearing cache, resetting TCC, removing apps (read-only)
#   - Reading the user TCC database (protected); report grants from System Settings instead
#   - UDP 3478-3481 media reachability (use Teams → Settings → Devices → Make a test call)
#   - Tenant-side policy, licensing or Conditional Access results
#
# .PARAMETER --user USERNAME
#   Inspect this user's home (useful with sudo / Intune scripts). Defaults to the console user.
#
# .EXAMPLE
#   bash Get-TeamsMacHealth.sh
#   sudo bash Get-TeamsMacHealth.sh --user jdoe
#
# .NOTES
#   Safe/read-only. Run with sudo to include the configuration-profile check.
#   CSV exported to /tmp/TeamsMacHealth_<hostname>_<timestamp>.csv

set -uo pipefail

TARGET_USER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) TARGET_USER="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; NC='\033[0m'
status() { local c="$CYN"; case "$1" in OK) c="$GRN";; WARN) c="$YEL";; ERROR) c="$RED";; esac; printf "${c}[%s]${NC} %s\n" "$1" "$2"; }
HOST=$(scutil --get ComputerName 2>/dev/null | tr ' ' '_' || hostname -s)
TS=$(date +%Y%m%d_%H%M%S)
CSV="/tmp/TeamsMacHealth_${HOST}_${TS}.csv"
echo "Check,Item,Value,Status" > "$CSV"
add() { local v="${3//\"/\'}"; echo "\"$1\",\"$2\",\"$v\",\"$4\"" >> "$CSV"; }

[[ -z "$TARGET_USER" ]] && TARGET_USER=$(stat -f%Su /dev/console 2>/dev/null || id -un)
USER_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[[ -z "$USER_HOME" ]] && USER_HOME="$HOME"
IS_ROOT=0; [[ "$EUID" -eq 0 ]] && IS_ROOT=1

echo "=== Microsoft Teams for Mac — Health ($HOST, $TS, user: $TARGET_USER) ==="
add "Context" "macOS" "$(sw_vers -productVersion 2>/dev/null) ($(uname -m))" "INFO"

# ─── Install ───
APP="/Applications/Microsoft Teams.app"
if [[ -d "$APP" ]]; then
  BID=$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "unknown")
  VER=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
  if [[ "$BID" == "com.microsoft.teams2" ]]; then
    status OK "Teams $VER ($BID)"; add "Install" "Teams" "$VER ($BID)" "OK"
  else
    status ERROR "Unexpected bundle ID at $APP: $BID (expected com.microsoft.teams2)"; add "Install" "Teams" "$BID" "ERROR"
  fi
else
  status ERROR "Microsoft Teams.app not found in /Applications"; add "Install" "Teams" "not installed" "ERROR"
fi
if [[ -d "/Applications/Microsoft Teams classic.app" ]]; then
  status WARN "Classic Teams still installed (retired client) — remove it"; add "Install" "Classic Teams" "present" "WARN"
fi
[[ -d "$USER_HOME/Library/Application Support/Microsoft/Teams" ]] && \
  { status INFO "Classic Teams user data folder present (safe to remove once classic is gone)"; add "Install" "Classic data" "present" "INFO"; }

# ─── Managed prefs ───
MP="/Library/Managed Preferences"
MPF=""
[[ -f "$MP/$TARGET_USER/com.microsoft.teams2.plist" ]] && MPF="$MP/$TARGET_USER/com.microsoft.teams2"
[[ -z "$MPF" && -f "$MP/com.microsoft.teams2.plist" ]] && MPF="$MP/com.microsoft.teams2"
if [[ -n "$MPF" ]]; then
  CT=$(defaults read "$MPF" CloudType 2>/dev/null || true)
  case "$CT" in
    "") status INFO "Managed com.microsoft.teams2 prefs present, no CloudType"; add "Policy" "CloudType" "absent" "INFO" ;;
    1) status OK "CloudType=1 (Commercial)"; add "Policy" "CloudType" "1 Commercial" "OK" ;;
    2) status OK "CloudType=2 (GCC)"; add "Policy" "CloudType" "2 GCC" "OK" ;;
    3) status OK "CloudType=3 (GCCH)"; add "Policy" "CloudType" "3 GCCH" "OK" ;;
    4) status OK "CloudType=4 (DoD)"; add "Policy" "CloudType" "4 DoD" "OK" ;;
    7) status OK "CloudType=7 (Gallatin)"; add "Policy" "CloudType" "7 Gallatin" "OK" ;;
    *) status WARN "CloudType=$CT is not a documented value (1,2,3,4,7)"; add "Policy" "CloudType" "$CT" "WARN" ;;
  esac
else
  status INFO "No managed com.microsoft.teams2 prefs (normal for commercial tenants)"; add "Policy" "Managed prefs" "absent" "INFO"
fi
[[ -f "$MP/com.microsoft.teams.plist" ]] && \
  { status WARN "Managed prefs for com.microsoft.teams (classic domain) — ignored by current Teams"; add "Policy" "Classic domain prefs" "present" "WARN"; }

# ─── Local state ───
for D in "$USER_HOME/Library/Group Containers/UBF8T346G9.com.microsoft.teams" "$USER_HOME/Library/Containers/com.microsoft.teams2"; do
  if [[ -d "$D" ]]; then
    SZ=$(du -sh "$D" 2>/dev/null | awk '{print $1}')
    status INFO "State: $(basename "$D") = ${SZ:-unknown}"; add "State" "$(basename "$D")" "${SZ:-unknown}" "INFO"
  else
    status INFO "State folder absent: $(basename "$D") (never launched, or cache just cleared)"; add "State" "$(basename "$D")" "absent" "INFO"
  fi
done

# ─── Audio driver ───
DRV="/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver"
if [[ -d "$DRV" ]]; then
  DV=$(defaults read "$DRV/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
  status OK "Teams audio driver present ($DV)"; add "Audio" "MSTeamsAudioDevice" "$DV" "OK"
else
  status INFO "Teams audio driver not installed (system-audio sharing unavailable)"; add "Audio" "MSTeamsAudioDevice" "absent" "INFO"
fi

# ─── Profiles (root only) ───
if [[ $IS_ROOT -eq 1 ]]; then
  PROF=$(profiles show -type configuration 2>/dev/null)
  if echo "$PROF" | grep -q "com.microsoft.teams2"; then
    status INFO "Configuration profile(s) reference com.microsoft.teams2"; add "Profiles" "teams2 referenced" "yes" "INFO"
    if echo "$PROF" | grep -A25 "com.microsoft.teams2" | grep -qi "Authorization = Deny\|Allowed = 0"; then
      status WARN "A PPPC entry for Teams appears to DENY a service (camera/mic/screen) — review in Intune"; add "Profiles" "PPPC deny" "suspected" "WARN"
    fi
  else
    status INFO "No configuration profile references com.microsoft.teams2"; add "Profiles" "teams2 referenced" "no" "INFO"
  fi
else
  status INFO "Run with sudo to include configuration-profile checks"
fi

# ─── Runtime / network ───
if pgrep -f "/Applications/Microsoft Teams.app" >/dev/null 2>&1; then status OK "Teams is running"; add "Runtime" "Process" "running" "OK"
else status INFO "Teams is not running"; add "Runtime" "Process" "not running" "INFO"; fi

if scutil --proxy 2>/dev/null | grep -Eq "(HTTPSEnable|ProxyAutoConfigEnable) : 1"; then
  status WARN "System proxy/PAC configured — ensure Teams media (UDP 3478-3481) bypasses it"; add "Network" "Proxy" "configured" "WARN"
else
  status OK "No system proxy/PAC"; add "Network" "Proxy" "none" "OK"
fi
if nc -z -w 3 teams.microsoft.com 443 >/dev/null 2>&1; then status OK "TCP 443 to teams.microsoft.com reachable"; add "Network" "teams.microsoft.com:443" "reachable" "OK"
else status ERROR "TCP 443 to teams.microsoft.com NOT reachable"; add "Network" "teams.microsoft.com:443" "unreachable" "ERROR"; fi

# ─── Logs ───
LOGS=$(ls -dt "$USER_HOME/Downloads/MS Teams Support Log Files"* 2>/dev/null | head -1)
if [[ -n "$LOGS" ]]; then
  status INFO "Latest support logs: $(basename "$LOGS")"; add "Logs" "Support log files" "$(basename "$LOGS")" "INFO"
else
  status INFO "No support logs in Downloads — collect with Option+Command+Shift+1 before clearing cache"; add "Logs" "Support log files" "none" "INFO"
fi

echo ""
echo "Not checked: TCC grants (System Settings → Privacy & Security), UDP media path (Make a test call)."
echo "CSV: $CSV"
