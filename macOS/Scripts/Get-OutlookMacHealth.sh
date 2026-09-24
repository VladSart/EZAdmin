#!/bin/bash
# Get-OutlookMacHealth.sh
# .SYNOPSIS
#   Read-only health check of Outlook for Mac: version, new-vs-legacy mode, admin EnableNewOutlook
#   (flags values that pin legacy ahead of/after the Oct 2026 EWS retirement), managed prefs, profiles.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/OutlookMac-B.md and OutlookMac-A.md.
#   Device-local diagnostic. Gathers, in one pass:
#   - Outlook install, version, bundle ID, App Store vs non-App Store build
#   - Managed EnableNewOutlook (com.microsoft.Outlook) — 0/1 = ERROR (keeps users on legacy, which
#     stops working against Exchange Online mailboxes from October 2026), 2/absent = OK, 3 = OK
#   - User-level EnableNewOutlook and the community-observed IsRunningNewOutlook mode indicator
#   - Selected managed keys: AllowedEmailDomains, DisallowedEmailDomains, DisableBasic,
#     FailAllCertificateErrors, DisableExport, DisableImport, DisableTeamsMeeting,
#     DefaultEmailAddressOrDomain; plus OfficeAutoSignIn (com.microsoft.office)
#   - Outlook profiles on disk (Outlook 15 Profiles) and their size
#   - Whether Outlook is running; free disk space
#
#   Does NOT cover:
#   - Changing any setting, switching modes, deleting profiles or keychain items (read-only)
#   - Mailbox location / CAS gates (MacOutlookEnabled) — run the Evidence Pack in OutlookMac-A.md
#   - Keychain token validity or Conditional Access results
#
# .PARAMETER --user USERNAME
#   Inspect this user's prefs/profiles (useful when running with sudo or as an Intune script).
#   Defaults to the console user.
#
# .EXAMPLE
#   bash Get-OutlookMacHealth.sh
#   sudo bash Get-OutlookMacHealth.sh --user jdoe
#
# .NOTES
#   Safe/read-only. Works as user or root; as root it reads per-user prefs via sudo -u.
#   IsRunningNewOutlook is not a Microsoft-documented admin key — treat as an indicator only.
#   CSV exported to /tmp/OutlookMacHealth_<hostname>_<timestamp>.csv

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
CSV="/tmp/OutlookMacHealth_${HOST}_${TS}.csv"
echo "Check,Item,Value,Status" > "$CSV"
add() { local v="${3//\"/\'}"; echo "\"$1\",\"$2\",\"$v\",\"$4\"" >> "$CSV"; }

[[ -z "$TARGET_USER" ]] && TARGET_USER=$(stat -f%Su /dev/console 2>/dev/null || id -un)
USER_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[[ -z "$USER_HOME" ]] && USER_HOME="$HOME"
IS_ROOT=0; [[ "$EUID" -eq 0 ]] && IS_ROOT=1
asuser() { if [[ $IS_ROOT -eq 1 && "$TARGET_USER" != "root" ]]; then sudo -u "$TARGET_USER" "$@"; else "$@"; fi; }

echo "=== Outlook for Mac — Health ($HOST, $TS, user: $TARGET_USER) ==="
add "Context" "macOS" "$(sw_vers -productVersion 2>/dev/null)" "INFO"

# ─── Install ───
APP="/Applications/Microsoft Outlook.app"
if [[ ! -d "$APP" ]]; then
  status ERROR "Microsoft Outlook.app not found in /Applications"; add "Install" "Outlook" "not installed" "ERROR"
  echo "CSV: $CSV"; exit 0
fi
VER=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
BID=$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "unknown")
if [[ -d "$APP/Contents/_MASReceipt" ]]; then SRC="App Store"; else SRC="Microsoft installer/Intune"; fi
status OK "Outlook $VER ($BID, $SRC build)"; add "Install" "Version" "$VER ($SRC)" "OK"

# ─── Managed / user prefs ───
MP="/Library/Managed Preferences"
mread() { # domain key -> value from user-scoped managed prefs first, then device-scoped
  local d="$1" k="$2" v=""
  [[ -f "$MP/$TARGET_USER/$d.plist" ]] && v=$(defaults read "$MP/$TARGET_USER/$d" "$k" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')
  [[ -z "$v" && -f "$MP/$d.plist" ]] && v=$(defaults read "$MP/$d" "$k" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')
  echo "$v"
}

M_ENO=$(mread com.microsoft.Outlook EnableNewOutlook)
U_ENO=$(asuser defaults read com.microsoft.Outlook EnableNewOutlook 2>/dev/null || true)
MODE=$(asuser defaults read com.microsoft.Outlook IsRunningNewOutlook 2>/dev/null || true)

case "$M_ENO" in
  0) status ERROR "Managed EnableNewOutlook=0 (switch hidden) — can pin users to legacy; legacy stops working with Exchange Online from Oct 2026"; add "Policy" "Managed EnableNewOutlook" "0" "ERROR" ;;
  1) status ERROR "Managed EnableNewOutlook=1 (switch shown, default OFF) — new users land in legacy; breaks for Exchange Online from Oct 2026"; add "Policy" "Managed EnableNewOutlook" "1" "ERROR" ;;
  2) status OK "Managed EnableNewOutlook=2 (switch shown, default on)"; add "Policy" "Managed EnableNewOutlook" "2" "OK" ;;
  3) status OK "Managed EnableNewOutlook=3 (new Outlook forced, switch hidden)"; add "Policy" "Managed EnableNewOutlook" "3" "OK" ;;
  "") status INFO "No managed EnableNewOutlook (default = 2)"; add "Policy" "Managed EnableNewOutlook" "absent" "INFO" ;;
  *) status WARN "Unexpected managed EnableNewOutlook value: $M_ENO"; add "Policy" "Managed EnableNewOutlook" "$M_ENO" "WARN" ;;
esac
if [[ -n "$U_ENO" ]]; then
  if [[ "$U_ENO" == "0" || "$U_ENO" == "1" ]]; then S=WARN; else S=INFO; fi
  status "$S" "User-level EnableNewOutlook=$U_ENO (overridable; managed value wins if present)"; add "Policy" "User EnableNewOutlook" "$U_ENO" "$S"
fi

case "$MODE" in
  1) status OK "Mode indicator: NEW Outlook (IsRunningNewOutlook=1)"; add "Mode" "IsRunningNewOutlook" "1" "OK" ;;
  0) status ERROR "Mode indicator: LEGACY Outlook (IsRunningNewOutlook=0) — not viable for Exchange Online mailboxes from Oct 2026"; add "Mode" "IsRunningNewOutlook" "0" "ERROR" ;;
  *) status INFO "Mode indicator not present (check the Legacy Outlook switch in the UI)"; add "Mode" "IsRunningNewOutlook" "absent" "INFO" ;;
esac

for KEY in AllowedEmailDomains DisallowedEmailDomains DefaultEmailAddressOrDomain DisableBasic FailAllCertificateErrors \
           TrustO365AutodiscoverRedirect DisableExport DisableImport DisableTeamsMeeting DisableSignatures ItemsToOtherAccountsEnabled; do
  V=$(mread com.microsoft.Outlook "$KEY")
  if [[ -n "$V" ]]; then
    S=INFO
    [[ "$KEY" == "FailAllCertificateErrors" && "$V" == "1" ]] && S=WARN
    status "$S" "Managed $KEY = $V"; add "Policy" "$KEY" "$V" "$S"
  fi
done
[[ "$(mread com.microsoft.Outlook FailAllCertificateErrors)" == "1" ]] && \
  status WARN "FailAllCertificateErrors blocks silently on TLS errors — check for TLS-inspecting proxies if sync fails"

OAS=$(mread com.microsoft.office OfficeAutoSignIn)
[[ -n "$OAS" ]] && { status INFO "Managed OfficeAutoSignIn (com.microsoft.office) = $OAS"; add "Policy" "OfficeAutoSignIn" "$OAS" "INFO"; }

# Wrong-domain sanity: EnableNewOutlook written to com.microsoft.office is ignored
WRONG=$(mread com.microsoft.office EnableNewOutlook)
[[ -n "$WRONG" ]] && { status WARN "EnableNewOutlook found in com.microsoft.office — wrong domain, ignored (use com.microsoft.Outlook)"; add "Policy" "EnableNewOutlook wrong domain" "$WRONG" "WARN"; }

# ─── Profiles ───
PDIR="$USER_HOME/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles"
if [[ -d "$PDIR" ]]; then
  COUNT=0
  while IFS= read -r -d '' P; do
    COUNT=$((COUNT+1))
    NAME=$(basename "$P")
    SIZE=$(du -sh "$P" 2>/dev/null | awk '{print $1}')
    MOD=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$P" 2>/dev/null)
    status INFO "Profile '$NAME' size $SIZE, modified $MOD"; add "Profile" "$NAME" "$SIZE / $MOD" "INFO"
  done < <(find "$PDIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  [[ $COUNT -eq 0 ]] && { status WARN "Profiles folder exists but is empty"; add "Profile" "count" "0" "WARN"; }
  [[ $COUNT -gt 1 ]] && { status WARN "$COUNT profiles — confirm the intended one is default (Outlook Profile Manager)"; add "Profile" "count" "$COUNT" "WARN"; }
else
  status INFO "No Outlook profile folder yet (Outlook never launched for this user, or new data location)"; add "Profile" "folder" "absent" "INFO"
fi

# ─── Runtime / disk ───
if pgrep -x "Microsoft Outlook" >/dev/null 2>&1; then status OK "Outlook is running"; add "Runtime" "Process" "running" "OK"
else status INFO "Outlook is not running"; add "Runtime" "Process" "not running" "INFO"; fi
FREE_GB=$(df -g / 2>/dev/null | awk 'NR==2{print $4}')
if [[ -n "$FREE_GB" && "$FREE_GB" -lt 10 ]]; then S=WARN; else S=OK; fi
status "$S" "Free disk: ${FREE_GB:-?} GB"; add "Runtime" "FreeDiskGB" "${FREE_GB:-unknown}" "$S"

echo ""
echo "Next: tenant-side checks (MacOutlookEnabled, mailbox location) → Evidence Pack in OutlookMac-A.md"
echo "CSV: $CSV"
