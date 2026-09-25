#!/bin/bash
# Get-MacLOBAppStatus.sh
# .SYNOPSIS
#   Read-only diagnostic for Intune macOS line-of-business (LOB) apps delivered over MDM
#   (InstallEnterpriseApplication), plus optional pre-upload validation of a .pkg file.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/MacLOBApps-B.md and MacLOBApps-A.md.
#   Two independent checks, in one pass:
#
#   DEVICE (always):
#   - macOS version, MDM enrollment state (profiles status -type enrollment)
#   - mdmclient QueryInstalledApps snapshot (the list Intune uses for LOB detection)
#   - For each --bundle-id: whether mdmclient reports it, on-disk path(s) and
#     CFBundleShortVersionString / CFBundleVersion, matching package receipts
#   - Recent mdmclient unified-log lines mentioning InstallEnterpriseApplication or the bundle IDs
#   - Recent /var/log/install.log lines mentioning the bundle IDs
#
#   PACKAGE (when --pkg is given; can be run on any Mac, enrolled or not):
#   - Signature type (must be "Developer ID Installer"), Gatekeeper install assessment
#   - Size against the 2 GB LOB limit
#   - Distribution/PackageInfo metadata: pkg-ref version, CFBundleVersion, install-location
#   - Payload present, payload under /Applications, nested .dmg / .pkg / bare-.app red flags
#   - Install-as-managed eligibility heuristics (single app, no nested pkgs, /Applications)
#
#   Does NOT cover:
#   - Installing, reinstalling, forgetting receipts or removing apps (read-only)
#   - Intune-side object settings (Included apps, Install as managed) - use the Graph
#     snippet in MacLOBApps-A.md "Evidence Pack"
#   - Agent-delivered macOS app (PKG)/(DMG) types - use Get-MacAgentAppStatus.sh
#
# .PARAMETER --bundle-id <id>
#   Bundle identifier to check (repeatable), e.g. com.contoso.widget
# .PARAMETER --pkg <path>
#   Path to the .pkg you uploaded (or will upload) to Intune, for package validation.
# .PARAMETER --hours <n>
#   Look-back window for the mdmclient unified log (default 4).
# .PARAMETER --collect
#   Also tar the QueryInstalledApps output, install.log and mdmclient log excerpt into /tmp.
#
# .EXAMPLE
#   sudo bash Get-MacLOBAppStatus.sh --bundle-id com.contoso.widget
#   sudo bash Get-MacLOBAppStatus.sh --bundle-id com.contoso.widget --pkg ~/Downloads/Widget-2.1.pkg --collect
#   bash Get-MacLOBAppStatus.sh --pkg ./Widget-2.1.pkg      # package-only validation, no sudo needed
#
# .NOTES
#   sudo is needed for mdmclient QueryInstalledApps and full log access. Safe/read-only.
#   Writes only to /tmp. Compatible with the macOS system bash 3.2.
#   CSV exported to /tmp/MacLOBAppStatus_<hostname>_<timestamp>.csv

set -uo pipefail

BUNDLE_IDS=()
PKG=""
HOURS=4
COLLECT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-id) [[ $# -ge 2 ]] || { echo "--bundle-id needs a value"; exit 1; }; BUNDLE_IDS+=("$2"); shift 2 ;;
    --pkg) [[ $# -ge 2 ]] || { echo "--pkg needs a path"; exit 1; }; PKG="$2"; shift 2 ;;
    --hours) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { echo "--hours needs a number"; exit 1; }; HOURS="$2"; shift 2 ;;
    --collect) COLLECT=1; shift ;;
    -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -t 1 ]]; then G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'; else G=""; Y=""; R=""; C=""; N=""; fi
status() { # status <OK|WARN|ERROR|INFO> <message>
  local col="$C"; case "$1" in OK) col="$G";; WARN) col="$Y";; ERROR) col="$R";; esac
  printf '%s[%s]%s %s\n' "$col" "$1" "$N" "$2"
}

HOST=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
TS=$(date +%Y%m%d-%H%M%S)
WORK="/tmp/MacLOBAppStatus_${HOST}_${TS}"
CSV="${WORK}.csv"
mkdir -p "$WORK" || { echo "Cannot create $WORK"; exit 1; }
echo "Section,Check,Result,Status,Detail" > "$CSV"
row() { # row <section> <check> <result> <status> <detail>
  local d="${5//\"/\'}"; local r="${3//\"/\'}"
  printf '"%s","%s","%s","%s","%s"\n' "$1" "$2" "$r" "$4" "$d" >> "$CSV"
  status "$4" "$2: $3${5:+ ($5)}"
}

IS_ROOT=0; [[ $EUID -eq 0 ]] && IS_ROOT=1

# ───────────────────────── Preflight ─────────────────────────
status INFO "Host $HOST  macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
if [[ ${#BUNDLE_IDS[@]} -eq 0 && -z "$PKG" ]]; then
  status WARN "No --bundle-id or --pkg given: running device-level checks only."
fi

# ───────────────────────── Device checks ─────────────────────────
ENR=$(profiles status -type enrollment 2>/dev/null)
if echo "$ENR" | grep -q "MDM enrollment: Yes"; then
  if echo "$ENR" | grep -qi "User Approved"; then row Device "MDM enrollment" "Yes (User Approved)" OK ""
  else row Device "MDM enrollment" "Yes" WARN "not user-approved; managed installs may be refused"; fi
else
  row Device "MDM enrollment" "No" ERROR "LOB apps are delivered only over MDM"
fi

QIA="$WORK/InstalledApps.txt"
if [[ $IS_ROOT -eq 1 ]]; then
  /usr/libexec/mdmclient QueryInstalledApps > "$QIA" 2>&1
  row Device "mdmclient QueryInstalledApps" "captured" OK "$QIA"
else
  : > "$QIA"
  row Device "mdmclient QueryInstalledApps" "skipped" WARN "re-run with sudo to compare against Intune Included apps"
fi

MDMLOG="$WORK/mdmclient.log"
PRED='process == "mdmclient" AND (eventMessage CONTAINS[c] "InstallEnterpriseApplication" OR eventMessage CONTAINS[c] "InstallApplication"'
for b in ${BUNDLE_IDS[@]+"${BUNDLE_IDS[@]}"}; do PRED="$PRED OR eventMessage CONTAINS[c] \"$b\""; done
PRED="$PRED)"
log show --last "${HOURS}h" --style compact --predicate "$PRED" > "$MDMLOG" 2>/dev/null
CMDS=$(grep -ci "InstallEnterpriseApplication" "$MDMLOG" 2>/dev/null || true)
CMDS=${CMDS:-0}
if [[ "$CMDS" -gt 0 ]]; then row Device "InstallEnterpriseApplication (last ${HOURS}h)" "$CMDS line(s)" OK "$MDMLOG"
else row Device "InstallEnterpriseApplication (last ${HOURS}h)" "none seen" WARN "sync the device, then re-run; none = not assigned, not due, or channel issue"; fi
ERRS=$(grep -iE "error|fail" "$MDMLOG" 2>/dev/null | tail -5)
[[ -n "$ERRS" ]] && { status WARN "Recent mdmclient error lines:"; echo "$ERRS"; }

for b in ${BUNDLE_IDS[@]+"${BUNDLE_IDS[@]}"}; do
  if [[ $IS_ROOT -eq 1 ]]; then
    if grep -q "$b" "$QIA"; then row "App:$b" "Reported by mdmclient" "yes" OK "Intune can detect it"
    else row "App:$b" "Reported by mdmclient" "no" ERROR "if listed in Included apps -> 0x87D13BA2 / not detected"; fi
  fi
  PATHS=$(mdfind "kMDItemCFBundleIdentifier == '$b'" 2>/dev/null)
  if [[ -z "$PATHS" ]]; then
    row "App:$b" "On disk" "not found" WARN "Spotlight found no bundle with this ID"
  else
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      V=$(defaults read "$p/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
      BV=$(defaults read "$p/Contents/Info" CFBundleVersion 2>/dev/null || echo "?")
      case "$p" in /Applications/*) S=OK; D="version $V build $BV";; *) S=WARN; D="version $V build $BV; outside /Applications - LOB detection expects /Applications";; esac
      row "App:$b" "On disk" "$p" "$S" "$D"
    done <<< "$PATHS"
  fi
  RC=$(pkgutil --pkgs 2>/dev/null | grep -i "$b" || true)
  if [[ -n "$RC" ]]; then row "App:$b" "Package receipt" "$(echo "$RC" | tr '\n' ' ')" INFO "pkgutil --pkg-info <id> for version; --forget clears stale receipts"
  else row "App:$b" "Package receipt" "none matching bundle ID" INFO "receipt IDs often differ from bundle IDs - check pkgutil --pkgs manually"; fi
  IL=$(grep -i "$b" /var/log/install.log 2>/dev/null | tail -5)
  if [[ -n "$IL" ]]; then status INFO "install.log (last 5 for $b):"; echo "$IL"; fi
done

# ───────────────────────── Package checks ─────────────────────────
if [[ -n "$PKG" ]]; then
  if [[ ! -f "$PKG" ]]; then
    row Package "File" "$PKG" ERROR "not found"
  else
    case "$PKG" in *.pkg|*.PKG) ;; *) row Package "Extension" "$PKG" ERROR "LOB accepts only .pkg; use the DMG type for .dmg/.app";; esac
    SIZE=$(stat -f%z "$PKG" 2>/dev/null || echo 0)
    if [[ "$SIZE" -gt 2147483648 ]]; then row Package "Size" "$SIZE bytes" ERROR "over the 2 GB LOB limit; use macOS app (PKG) type (8 GB)"
    else row Package "Size" "$SIZE bytes" OK ""; fi

    SIG=$(pkgutil --check-signature "$PKG" 2>&1)
    echo "$SIG" > "$WORK/signature.txt"
    if echo "$SIG" | grep -q "Developer ID Installer"; then row Package "Signature" "Developer ID Installer" OK "$(echo "$SIG" | grep -m1 'Developer ID Installer' | sed 's/^ *//')"
    elif echo "$SIG" | grep -qi "no signature"; then row Package "Signature" "unsigned" ERROR "sign with productsign --sign 'Developer ID Installer: ...'"
    else row Package "Signature" "wrong or untrusted" ERROR "$(echo "$SIG" | grep -m1 -i 'status' | sed 's/^ *//')"; fi

    GK=$(spctl -a -vv -t install "$PKG" 2>&1)
    if echo "$GK" | grep -q "accepted"; then row Package "Gatekeeper (install)" "accepted" OK "$(echo "$GK" | grep -m1 'source=' | sed 's/^ *//')"
    else row Package "Gatekeeper (install)" "rejected" WARN "$(echo "$GK" | head -1)"; fi

    EXP="$WORK/expanded"
    if pkgutil --expand "$PKG" "$EXP" 2>/dev/null; then
      XMLS=$(find "$EXP" -maxdepth 2 \( -name Distribution -o -name PackageInfo \) 2>/dev/null)
      if [[ -n "$XMLS" ]]; then
        # shellcheck disable=SC2086
        META=$(grep -hioE 'install-location="[^"]*"|customLocation="[^"]*"|CFBundleVersion="[^"]*"|pkg-ref id="[^"]*" version="[^"]*"|version="[^"]*"' $XMLS 2>/dev/null | sort -u)
        echo "$META" > "$WORK/metadata.txt"
        if echo "$META" | grep -qiE 'install-location="/Applications|customLocation="/Applications'; then row Package "install-location" "/Applications" OK ""
        elif echo "$META" | grep -qiE 'install-location="/"'; then row Package "install-location" "/" WARN "root-relative; confirm payload paths start with ./Applications"
        else row Package "install-location" "missing or not /Applications" ERROR "Learn: silent non-install; rebuild with productbuild --component <app> /Applications"; fi
        if echo "$META" | grep -qi 'CFBundleVersion='; then row Package "CFBundleVersion" "present" OK ""
        else row Package "CFBundleVersion" "not found" ERROR "Learn: required for deployment; rebuild with productbuild --component"; fi
        if echo "$META" | grep -qiE 'version="[^"]+"'; then row Package "pkg version" "present" OK ""
        else row Package "pkg version" "not found" ERROR "package version attribute missing"; fi
        NESTED=$(find "$EXP" -maxdepth 1 -type d -name '*.pkg' | wc -l | tr -d ' ')
        row Package "Component packages" "$NESTED" INFO "managed install needs a single app and no nested packages"
      else
        row Package "Metadata XML" "none found" ERROR "no Distribution/PackageInfo - not a valid flat package"
      fi
    else
      row Package "Expand" "failed" ERROR "pkgutil --expand could not read the package"
    fi

    PAY=$(pkgutil --payload-files "$PKG" 2>/dev/null)
    echo "$PAY" > "$WORK/payload.txt"
    PCOUNT=$(printf '%s\n' "$PAY" | grep -c . || true)
    if [[ "${PCOUNT:-0}" -eq 0 ]]; then row Package "Payload" "empty" ERROR "payload-free packages reinstall while assigned - use a script or unmanaged PKG type"
    else row Package "Payload" "$PCOUNT path(s)" OK ""; fi
    APPS=$(printf '%s\n' "$PAY" | grep -E '\.app$' | grep -vE '\.app/.*\.app$' | sort -u)
    NAPPS=$(printf '%s\n' "$APPS" | grep -c . || true)
    row Package "Top-level .app bundles in payload" "${NAPPS:-0}" INFO "$(echo "$APPS" | tr '\n' ' ')"
    if printf '%s\n' "$PAY" | grep -qiE '\.dmg$'; then row Package "Nested disk image" "found" ERROR "LOB packages must not contain a disk image"; fi
    if [[ -n "$APPS" ]] && ! printf '%s\n' "$APPS" | grep -qE '^\.?/?Applications/'; then
      row Package "Apps outside /Applications" "yes" WARN "check install-location; payload may be relative to it"
    fi
    if [[ "${NAPPS:-0}" -eq 1 && "${NESTED:-0}" -le 1 ]]; then row Package "Install-as-managed eligibility" "likely eligible" OK "single app, no nested packages (verify /Applications and macOS 11+)"
    else row Package "Install-as-managed eligibility" "likely NOT eligible" WARN "needs exactly one app and no nested packages"; fi
  fi
fi

# ───────────────────────── Report ─────────────────────────
if [[ $COLLECT -eq 1 ]]; then
  cp /var/log/install.log "$WORK/" 2>/dev/null
  tar -czf "${WORK}.tgz" -C /tmp "$(basename "$WORK")" 2>/dev/null && status OK "Evidence bundle: ${WORK}.tgz"
fi
status OK "CSV: $CSV"
status INFO "Working files: $WORK"
