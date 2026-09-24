#!/bin/bash
# Get-M365MacAppsHealth.sh
# .SYNOPSIS
#   Collect Microsoft 365 Apps for Mac install, licensing and Microsoft AutoUpdate (MAU) health for
#   triage or escalation.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/M365AppsMac-B.md and M365AppsMac-A.md.
#   Device-local diagnostic. Gathers, in one pass:
#   - macOS version and MDM enrolment state
#   - Per-app presence, version, build and code-signing Team ID for Word, Excel, PowerPoint,
#     Outlook, OneNote, OneDrive, Teams and Microsoft AutoUpdate
#   - Presence of the machine-wide Office LTSC volume licence file
#     (/Library/Preferences/com.microsoft.office.licensingV2.plist)
#   - MAU configuration as seen by the logged-in console user (msupdate --config) plus the key
#     com.microsoft.autoupdate2 preference values (HowToCheck, ChannelName, UpdateCache, deadlines)
#   - Whether a managed configuration profile targets com.microsoft.autoupdate2
#   - Office CDN reachability
#   - Optional (--check-updates): a live 'msupdate --list' as the console user
#
#   Does NOT cover:
#   - Installing, updating, or removing any app (read-only — no --install is ever run)
#   - Reading or removing licence tokens/keychain entries (privacy + no supported CLI)
#   - Intune-side install status or Entra licence assignment (portal/Graph tasks)
#
# .PARAMETER --check-updates
#   Also run 'msupdate --list' (contacts the Office CDN; may take up to a minute).
#
# .EXAMPLE
#   sudo bash Get-M365MacAppsHealth.sh
#   sudo bash Get-M365MacAppsHealth.sh --check-updates
#
# .NOTES
#   Run with sudo for full profile enumeration. Safe/read-only.
#   msupdate may raise a first-run privacy prompt if no PPPC profile pre-approves it — see PPPC-B.md.
#   CSV exported to /tmp/M365MacAppsHealth_<hostname>_<timestamp>.csv

set -uo pipefail

CHECK_UPDATES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-updates) CHECK_UPDATES=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; NC='\033[0m'
status() { # status LEVEL MESSAGE
  local c="$CYN"; case "$1" in OK) c="$GRN";; WARN) c="$YEL";; ERROR) c="$RED";; esac
  printf "${c}[%s]${NC} %s\n" "$1" "$2"
}
HOST=$(scutil --get ComputerName 2>/dev/null | tr ' ' '_' || hostname -s)
TS=$(date +%Y%m%d_%H%M%S)
CSV="/tmp/M365MacAppsHealth_${HOST}_${TS}.csv"
echo "Check,Item,Value,Status" > "$CSV"
add() { # add CHECK ITEM VALUE STATUS
  local v="${3//\"/\'}"
  echo "\"$1\",\"$2\",\"$v\",\"$4\"" >> "$CSV"
}

MSU="/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"
CONSOLE_USER=$(stat -f%Su /dev/console 2>/dev/null || echo "")
as_user() { # run a command as the console user when possible
  if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$EUID" -eq 0 ]]; then
    sudo -u "$CONSOLE_USER" "$@"
  else
    "$@"
  fi
}

# ─────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────
echo "=== Microsoft 365 Apps for Mac — Health Check ($HOST, $TS) ==="
[[ "$EUID" -ne 0 ]] && status WARN "Not running as root — profile enumeration will be incomplete. Re-run with sudo."
OSV=$(sw_vers -productVersion)
status INFO "macOS $OSV  |  console user: ${CONSOLE_USER:-none}"
add "Platform" "macOS version" "$OSV" "INFO"

ENR=$(profiles status -type enrollment 2>/dev/null | tr '\n' ' ')
if echo "$ENR" | grep -q "MDM enrollment: Yes"; then
  status OK "MDM enrolled: $ENR"; add "Platform" "MDM enrolment" "$ENR" "OK"
else
  status ERROR "Not MDM enrolled — Intune cannot deliver the suite. ($ENR)"; add "Platform" "MDM enrolment" "$ENR" "ERROR"
fi

# ─────────────────────────────────────────────
# Detect — apps
# ─────────────────────────────────────────────
echo; echo "--- Installed apps ---"
APPS=(
  "/Applications/Microsoft Word.app"
  "/Applications/Microsoft Excel.app"
  "/Applications/Microsoft PowerPoint.app"
  "/Applications/Microsoft Outlook.app"
  "/Applications/Microsoft OneNote.app"
  "/Applications/OneDrive.app"
  "/Applications/Microsoft Teams.app"
  "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app"
)
MISSING=0
for APP in "${APPS[@]}"; do
  NAME=$(basename "$APP" .app)
  if [[ -d "$APP" ]]; then
    VER=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
    BLD=$(defaults read "$APP/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "?")
    TEAM=$(codesign -dv "$APP" 2>&1 | awk -F= '/^TeamIdentifier/{print $2}')
    if [[ "$TEAM" == "UBF8T346G9" ]]; then
      status OK "$NAME $VER ($BLD) — signed by Microsoft"; add "Apps" "$NAME" "$VER ($BLD) Team=$TEAM" "OK"
    else
      status WARN "$NAME $VER ($BLD) — unexpected signature Team='${TEAM:-none}'"; add "Apps" "$NAME" "$VER ($BLD) Team=${TEAM:-none}" "WARN"
    fi
  else
    status WARN "$NAME not installed"; add "Apps" "$NAME" "not installed" "WARN"; MISSING=$((MISSING+1))
  fi
done

# ─────────────────────────────────────────────
# Detect — licensing
# ─────────────────────────────────────────────
echo; echo "--- Licensing ---"
VL="/Library/Preferences/com.microsoft.office.licensingV2.plist"
if [[ -f "$VL" ]]; then
  MOD=$(stat -f "%Sm" "$VL")
  status WARN "Volume (LTSC) licence file present (modified $MOD). Expected ONLY on LTSC devices — overrides Microsoft 365 subscription. See M365AppsMac-B Fix 3."
  add "Licensing" "Volume licence file" "present, modified $MOD" "WARN"
else
  status OK "No machine-wide volume licence file (expected for Microsoft 365 subscription)."
  add "Licensing" "Volume licence file" "absent" "OK"
fi

# ─────────────────────────────────────────────
# Detect — MAU
# ─────────────────────────────────────────────
echo; echo "--- Microsoft AutoUpdate ---"
if [[ -x "$MSU" ]]; then
  for KEY in HowToCheck ChannelName UpdateCache UpdateDeadline.DaysBeforeForcedQuit UpdateDeadline.StartAutomaticUpdates UpdateDeadline.FinalCountDown; do
    VAL=$(as_user defaults read com.microsoft.autoupdate2 "$KEY" 2>/dev/null | tr '\n' ' ' || true)
    [[ -z "$VAL" ]] && VAL="(not set)"
    LVL="INFO"
    if [[ "$KEY" == "HowToCheck" && "$VAL" == Manual* ]]; then
      LVL="WARN"; status WARN "HowToCheck = Manual — MAU will not update on its own. Confirm another tool owns patching."
    else
      status INFO "$KEY = $VAL"
    fi
    add "MAU" "$KEY" "$VAL" "$LVL"
  done
  CFG=$(as_user "$MSU" --config 2>&1 | head -40 | tr '\n' ' ')
  add "MAU" "msupdate --config" "$CFG" "INFO"
  if echo "$CFG" | grep -qiE "not permitted|denied|xpc"; then
    status WARN "msupdate reported a permission/XPC problem — likely missing PPPC pre-approval (Fix 6)."
  fi
else
  status ERROR "Microsoft AutoUpdate / msupdate not found — apps cannot self-update."
  add "MAU" "msupdate" "not found" "ERROR"
fi

if [[ "$EUID" -eq 0 ]]; then
  PCOUNT=$(profiles -P -o stdout 2>/dev/null | grep -c "com.microsoft.autoupdate2" || true)
  if [[ "$PCOUNT" -gt 0 ]]; then
    status INFO "Managed profile content referencing com.microsoft.autoupdate2 found ($PCOUNT match(es)) — managed values override user values."
  else
    status INFO "No managed profile targets com.microsoft.autoupdate2 — MAU is on defaults/user settings."
  fi
  add "MAU" "Managed profile matches" "$PCOUNT" "INFO"
fi

# ─────────────────────────────────────────────
# Detect — network
# ─────────────────────────────────────────────
echo; echo "--- Network ---"
CDN=$(curl -sI --max-time 15 https://officecdnmac.microsoft.com 2>/dev/null | head -1 | tr -d '\r')
if [[ -n "$CDN" ]]; then
  status OK "Office CDN reachable: $CDN"; add "Network" "officecdnmac.microsoft.com" "$CDN" "OK"
else
  status ERROR "Office CDN NOT reachable (timeout/TLS) — check proxy / SSL inspection."; add "Network" "officecdnmac.microsoft.com" "unreachable" "ERROR"
fi

# ─────────────────────────────────────────────
# Optional — live update list
# ─────────────────────────────────────────────
if [[ "$CHECK_UPDATES" -eq 1 && -x "$MSU" ]]; then
  echo; echo "--- msupdate --list (live) ---"
  LIST=$(as_user "$MSU" --list 2>&1 | tail -30)
  echo "$LIST"
  add "MAU" "msupdate --list" "$(echo "$LIST" | tr '\n' ' ')" "INFO"
fi

# ─────────────────────────────────────────────
# Report
# ─────────────────────────────────────────────
echo
ERRS=$(grep -c '"ERROR"$' "$CSV" || true)
WARNS=$(grep -c '"WARN"$' "$CSV" || true)
echo "=== Summary: $ERRS error(s), $WARNS warning(s), $MISSING app(s) missing ==="
echo "CSV: $CSV"
