#!/bin/bash
# Get-MacAgentAppStatus.sh
# .SYNOPSIS
#   Read-only health check for Intune agent-delivered macOS apps (macOS app (PKG) / macOS app (DMG)).
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/PKG-DMG-Apps-B.md and PKG-DMG-Apps-A.md.
#   Device-local diagnostic. Gathers, in one pass:
#   - macOS version, free disk space, /Applications ownership and permissions
#   - Microsoft Intune management agent presence and version, with feature-floor flags
#     (PKG >= 2308.006, PKG scripts >= 2309.007, DMG update >= 2304.039)
#   - Whether IntuneMdmDaemon / IntuneMdmAgent are running
#   - Newest IntuneMDMDaemon log: count and last N lines of 0x87D301xx / 2016214710 app error codes,
#     each decoded against the Microsoft Learn PKG/DMG troubleshooting tables
#   - Optional (--bundle-id, repeatable): every on-disk location of that bundle ID with its
#     CFBundleShortVersionString, plus daemon-log lines that mention it
#   - Optional (--collect): tarball of /Library/Logs/Microsoft/Intune and /var/log/install.log
#
#   Does NOT cover:
#   - Installing, reinstalling or removing any app (read-only)
#   - Intune-side assignment or detection-rule configuration (portal/Graph tasks)
#   - MDM-delivered LOB PKGs (InstallEnterpriseApplication) - see MacLOBApps-A.md / Get-MacLOBAppStatus.sh
#
# .PARAMETER --bundle-id <id>
#   Bundle identifier to locate on disk and in logs (repeatable).
# .PARAMETER --lines <n>
#   How many recent error lines to report (default 15).
# .PARAMETER --collect
#   Also create a log tarball in /tmp for escalation.
#
# .EXAMPLE
#   sudo bash Get-MacAgentAppStatus.sh
#   sudo bash Get-MacAgentAppStatus.sh --bundle-id com.google.Chrome --bundle-id us.zoom.xos --collect
#
# .NOTES
#   Run with sudo: the daemon logs are root-readable only. Safe/read-only.
#   CSV exported to /tmp/MacAgentAppStatus_<hostname>_<timestamp>.csv

set -uo pipefail

BUNDLE_IDS=()
LINES=15
COLLECT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-id) [[ $# -ge 2 ]] || { echo "--bundle-id needs a value"; exit 1; }; BUNDLE_IDS+=("$2"); shift 2 ;;
    --lines) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { echo "--lines needs a number"; exit 1; }; LINES="$2"; shift 2 ;;
    --collect) COLLECT=1; shift ;;
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
CSV="/tmp/MacAgentAppStatus_${HOST}_${TS}.csv"
echo "Check,Item,Value,Status,Note" > "$CSV"
csvq() { local s="${1//\"/\"\"}"; printf '"%s"' "$s"; }
record() { # record CHECK ITEM VALUE STATUS [NOTE]
  local note="${5:-}"
  status "$4" "$1 | $2 = $3${note:+ ($note)}"
  printf '%s,%s,%s,%s,%s\n' "$(csvq "$1")" "$(csvq "$2")" "$(csvq "$3")" "$(csvq "$4")" "$(csvq "$note")" >> "$CSV"
}
# version_ge A B  -> true if A >= B (numeric dotted compare)
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | head -1)" == "$2" ]]; }

decode() {
  case "$1" in
    0x87D30137) echo "Below Minimum OS requirement" ;;
    2016214710) echo "PKG pre-install script returned non-zero (retried next check-in)" ;;
    0x87D3013E) echo "DMG contains no .app" ;;
    0x87D30139) echo "DMG could not be mounted" ;;
    0x87D3013B) echo "Could not install to /Applications" ;;
    0x87D30135) echo "Device error (disk space / write failure)" ;;
    0x87D3013A) echo "Disk resources exhausted or corrupt payload" ;;
    0x87D30131|0x87D30132) echo "Download failed" ;;
    0x87D3012F|0x87D30130|0x87D30133|0x87D30134|0x87D30136) echo "Internal agent error - retry manually / recreate app / escalate" ;;
    *) echo "See PKG-DMG-Apps-A.md symptom map" ;;
  esac
}

[[ $EUID -eq 0 ]] || status WARN "Not running as root - daemon logs may be unreadable. Re-run with sudo."

# ─────────────────────────────────────────────
# Preflight: device
# ─────────────────────────────────────────────
record "Device" "macOS" "$(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))" INFO
FREE_KB=$(df -k / | awk 'NR==2 {print $4}')
FREE_GB=$(( ${FREE_KB:-0} / 1048576 ))
if (( FREE_GB < 10 )); then record "Device" "Free disk (GB)" "$FREE_GB" WARN "Low space causes 0x87D3013A / 0x87D30135"
else record "Device" "Free disk (GB)" "$FREE_GB" OK; fi
APPS_PERM=$(stat -f '%Sp %Su:%Sg' /Applications 2>/dev/null)
record "Device" "/Applications" "$APPS_PERM" "$([[ "$APPS_PERM" == drwxrwxr-x*root:admin ]] && echo OK || echo WARN)"

# ─────────────────────────────────────────────
# Detect: agent
# ─────────────────────────────────────────────
AGENT="/Library/Intune/Microsoft Intune Agent.app"
if [[ -d "$AGENT" ]]; then
  AVER=$(defaults read "$AGENT/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "unknown")
  record "Agent" "Version" "$AVER" OK
  if [[ "$AVER" != "unknown" ]]; then
    version_ge "$AVER" "2304.039" || record "Agent" "DMG update support" "no" WARN "Needs >= 2304.039"
    version_ge "$AVER" "2308.006" || record "Agent" "PKG app support" "no" ERROR "Needs >= 2308.006"
    version_ge "$AVER" "2309.007" || record "Agent" "PKG pre/post scripts" "no" WARN "Needs >= 2309.007"
  fi
else
  record "Agent" "Installed" "no" ERROR "Agent installs when a script/PKG/DMG is assigned - check assignment + check-in"
fi
PROCS=$(pgrep -il "^IntuneMdm" 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')
if [[ "$PROCS" == *IntuneMdmDaemon* ]]; then record "Agent" "Processes" "$PROCS" OK
else record "Agent" "Processes" "${PROCS:-none}" ERROR "IntuneMdmDaemon not running - see Fix 1"; fi

# ─────────────────────────────────────────────
# Detect: logs
# ─────────────────────────────────────────────
LOGDIR="/Library/Logs/Microsoft/Intune"
LATEST=$(ls -t "$LOGDIR"/IntuneMDMDaemon*.log 2>/dev/null | head -1)
if [[ -z "$LATEST" ]]; then
  record "Logs" "IntuneMDMDaemon log" "not found" WARN "No agent workload processed yet (or not root)"
else
  record "Logs" "Newest daemon log" "$LATEST" INFO
  PATTERN='0x87D30[0-9A-Fa-f]{3}|2016214710'
  COUNT=$(grep -hEc "$PATTERN" "$LOGDIR"/IntuneMDMDaemon*.log 2>/dev/null | awk '{s+=$1} END {print s+0}')
  record "Logs" "App error lines (all daemon logs)" "$COUNT" "$([[ "$COUNT" -gt 0 ]] && echo WARN || echo OK)"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    code=$(printf '%s' "$line" | grep -oE "$PATTERN" | head -1)
    record "Logs" "Error $code" "$(printf '%s' "$line" | cut -c1-300)" WARN "$(decode "$code")"
  done < <(grep -hE "$PATTERN" "$LOGDIR"/IntuneMDMDaemon*.log 2>/dev/null | tail -n "$LINES")
fi

# ─────────────────────────────────────────────
# Detect: specific bundle IDs
# ─────────────────────────────────────────────
for BID in "${BUNDLE_IDS[@]+"${BUNDLE_IDS[@]}"}"; do
  FOUND=0
  while IFS= read -r APPPATH; do
    [[ -z "$APPPATH" ]] && continue
    FOUND=1
    V=$(defaults read "$APPPATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
    NOTE=""; [[ "$APPPATH" == /Applications/* ]] || NOTE="Outside /Applications - DMG detection won't see it"
    record "Bundle" "$BID" "$APPPATH v$V" OK "$NOTE"
  done < <(mdfind "kMDItemCFBundleIdentifier == '$BID'" 2>/dev/null)
  (( FOUND == 1 )) || record "Bundle" "$BID" "not found on disk" ERROR "If listed in Included apps, Intune reports Failed"
  if [[ -n "${LATEST:-}" ]]; then
    HITS=$(grep -hF "$BID" "$LOGDIR"/IntuneMDMDaemon*.log 2>/dev/null | wc -l | tr -d ' ')
    record "Bundle" "$BID log lines" "$HITS" "$([[ "$HITS" -gt 0 ]] && echo OK || echo WARN)" \
      "$([[ "$HITS" -gt 0 ]] || echo 'Not seen by agent - check assignment / Check status')"
    grep -hF "$BID" "$LOGDIR"/IntuneMDMDaemon*.log 2>/dev/null | tail -3 | while IFS= read -r l; do
      record "Bundle" "$BID last line" "$(printf '%s' "$l" | cut -c1-300)" INFO
    done
  fi
done

# ─────────────────────────────────────────────
# Optional: evidence tarball
# ─────────────────────────────────────────────
if (( COLLECT == 1 )); then
  OUT="/tmp/MacAgentEvidence_${HOST}_${TS}"
  mkdir -p "$OUT"
  cp "$LOGDIR"/*.log "$OUT/" 2>/dev/null
  cp /var/log/install.log "$OUT/" 2>/dev/null
  cp "$CSV" "$OUT/" 2>/dev/null
  tar -czf "$OUT.tgz" -C /tmp "$(basename "$OUT")" 2>/dev/null && record "Evidence" "Tarball" "$OUT.tgz" OK
fi

# ─────────────────────────────────────────────
# Report
# ─────────────────────────────────────────────
ERRS=$(grep -c ',"ERROR",' "$CSV"); WARNS=$(grep -c ',"WARN",' "$CSV")
status "$([[ $ERRS -gt 0 ]] && echo ERROR || ([[ $WARNS -gt 0 ]] && echo WARN || echo OK))" \
  "Done. $ERRS error(s), $WARNS warning(s). CSV: $CSV"
