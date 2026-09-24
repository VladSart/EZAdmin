#!/bin/bash
# Get-KerberosSSOStatus.sh
# .SYNOPSIS
#   Collect macOS Kerberos SSO extension (and Platform SSO TGT hand-off) status for triage or
#   escalation.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/KerberosSSO-B.md and KerberosSSO-A.md.
#   Device-local diagnostic. Gathers, in one pass:
#   - macOS version against the macOS 14.6 floor for Platform SSO Kerberos TGT mapping
#   - Company Portal version against the 5.2408.0 floor
#   - Whether a Kerberos Extensible SSO payload (com.apple.AppSSOKerberos.KerberosExtension)
#     is installed (requires sudo to enumerate profiles)
#   - Configured realms (app-sso -l) and realm info for the target realm (app-sso -i)
#   - Platform SSO state lines related to Kerberos TGTs (tgt_ad / tgt_cloud)
#   - Current user's ticket cache (klist)
#   - DNS SRV discovery for the AD domain, and TCP reachability of the first DC on 88/389
#   - Clock offset vs time.apple.com
#   - Optional: FQDN resolution + TCP 445 check for a named file server (--test-host)
#   - Recent com.apple.AppSSO* log lines
#
#   Does NOT cover:
#   - Authenticating, signing out, resetting realms or destroying tickets (read-only)
#   - Server-side checks (SPNs, Entra Kerberos server object) — see KerberosSSO-A.md
#   - Mounting shares
#
# .PARAMETER --realm REALM
#   Kerberos realm to inspect (e.g. CONTOSO.COM). Defaults to the first realm from app-sso -l.
# .PARAMETER --test-host FQDN
#   Optional file server FQDN to test name resolution and SMB (445) reachability.
#
# .EXAMPLE
#   bash Get-KerberosSSOStatus.sh --realm CONTOSO.COM --test-host fs01.contoso.com
#
# .NOTES
#   Run as the AFFECTED USER (not root) so their ticket cache and app-sso state are visible.
#   Profile enumeration needs root; when not root, that check is reported as SKIPPED.
#   Safe/read-only. CSV exported to /tmp/KerberosSSOStatus_<hostname>_<timestamp>.csv

set -uo pipefail

REALM=""; TEST_HOST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --realm) REALM="${2:-}"; shift 2 ;;
    --test-host) TEST_HOST="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; NC='\033[0m'
status() { local c="$CYN"; case "$1" in OK) c="$GRN";; WARN) c="$YEL";; ERROR) c="$RED";; esac; printf "${c}[%s]${NC} %s\n" "$1" "$2"; }
HOST=$(scutil --get ComputerName 2>/dev/null | tr ' ' '_' || hostname -s)
TS=$(date +%Y%m%d_%H%M%S)
CSV="/tmp/KerberosSSOStatus_${HOST}_${TS}.csv"
echo "Check,Item,Value,Status" > "$CSV"
add() { local v="${3//\"/\'}"; echo "\"$1\",\"$2\",\"$v\",\"$4\"" >> "$CSV"; }
verge() { # verge A B → true if version A >= B
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

echo "=== Kerberos SSO Extension — Status ($HOST, $TS, user: $(id -un)) ==="
[[ "$EUID" -eq 0 ]] && status WARN "Running as root — ticket cache/app-sso state shown will be root's, not the user's. Re-run as the affected user."

# ─── Platform prerequisites ───
OSV=$(sw_vers -productVersion)
if verge "$OSV" "14.6"; then status OK "macOS $OSV (>= 14.6 for PSSO TGT mapping)"; add "Platform" "macOS" "$OSV" "OK"
else status WARN "macOS $OSV (< 14.6) — Platform SSO Kerberos TGT mapping unavailable; standalone mode only"; add "Platform" "macOS" "$OSV" "WARN"; fi

CP="/Applications/Company Portal.app/Contents/Info.plist"
if [[ -f "$CP" ]]; then
  CPV=$(defaults read "$CP" CFBundleShortVersionString 2>/dev/null || echo "0")
  if verge "$CPV" "5.2408.0"; then status OK "Company Portal $CPV"; add "Platform" "Company Portal" "$CPV" "OK"
  else status WARN "Company Portal $CPV (< 5.2408.0 required for PSSO Kerberos)"; add "Platform" "Company Portal" "$CPV" "WARN"; fi
else
  status INFO "Company Portal not installed (fine for standalone Kerberos SSO; required for Platform SSO)"; add "Platform" "Company Portal" "not installed" "INFO"
fi

# ─── Profile ───
if [[ "$EUID" -eq 0 ]]; then
  if profiles -P -o stdout 2>/dev/null | grep -q "com.apple.AppSSOKerberos.KerberosExtension"; then
    status OK "Kerberos SSO extension profile installed"; add "Profile" "Kerberos payload" "present" "OK"
  else
    status ERROR "No Kerberos SSO extension profile found"; add "Profile" "Kerberos payload" "absent" "ERROR"
  fi
else
  status INFO "Profile enumeration SKIPPED (needs sudo). Realms below come from app-sso."; add "Profile" "Kerberos payload" "skipped (not root)" "INFO"
fi

# ─── Realms ───
REALMS=$(app-sso -l 2>&1 | tr '\n' ' ')
add "Realms" "app-sso -l" "$REALMS" "INFO"
if [[ -z "$REALM" ]]; then
  REALM=$(app-sso -l 2>/dev/null | grep -oE '[A-Z0-9.-]+\.[A-Z]{2,}' | grep -v "MICROSOFTONLINE" | head -1 || true)
fi
if [[ -n "$REALM" ]]; then
  status OK "Inspecting realm: $REALM  (configured: $REALMS)"
  INFO=$(app-sso -i "$REALM" 2>&1 | head -40)
  echo "$INFO" | sed 's/^/    /'
  add "Realms" "app-sso -i $REALM" "$(echo "$INFO" | tr '\n' ' ')" "INFO"
  [[ "$REALM" != "$(echo "$REALM" | tr '[:lower:]' '[:upper:]')" ]] && { status WARN "Realm '$REALM' is not uppercase — Kerberos realms are case-sensitive"; add "Realms" "casing" "$REALM" "WARN"; }
else
  status ERROR "No realm configured/detected — profile missing (KerberosSSO-B Fix 1)"; add "Realms" "detected" "none" "ERROR"
fi

# ─── Platform SSO TGTs ───
PS=$(app-sso platform -s 2>/dev/null || true)
if [[ -n "$PS" ]]; then
  AD=$(echo "$PS" | grep -c "tgt_ad" || true); CL=$(echo "$PS" | grep -c "tgt_cloud" || true)
  [[ "$AD" -gt 0 ]] && status OK "PSSO on-prem TGT (tgt_ad) present" || status WARN "PSSO on-prem TGT (tgt_ad) NOT present"
  [[ "$CL" -gt 0 ]] && status OK "PSSO cloud TGT (tgt_cloud) present" || status INFO "PSSO cloud TGT (tgt_cloud) not present"
  add "PlatformSSO" "tgt_ad" "$AD" "$([[ $AD -gt 0 ]] && echo OK || echo WARN)"
  add "PlatformSSO" "tgt_cloud" "$CL" "INFO"
else
  status INFO "Platform SSO not configured / no state — standalone Kerberos SSO mode"; add "PlatformSSO" "state" "none" "INFO"
fi

# ─── Tickets ───
KL=$(klist 2>&1)
if echo "$KL" | grep -q "krbtgt/"; then
  status OK "TGT present in user's cache"; add "Tickets" "klist" "$(echo "$KL" | tr '\n' ' ')" "OK"
else
  status WARN "No TGT in user's cache"; add "Tickets" "klist" "$(echo "$KL" | tr '\n' ' ')" "WARN"
fi
echo "$KL" | sed 's/^/    /' | head -20

# ─── Network ───
if [[ -n "$REALM" ]]; then
  DOM=$(echo "$REALM" | tr '[:upper:]' '[:lower:]')
  SRV=$(dig +short -t SRV "_ldap._tcp.dc._msdcs.$DOM" 2>/dev/null | head -5)
  if [[ -n "$SRV" ]]; then
    status OK "DC SRV records resolve for $DOM"; add "Network" "SRV _ldap._tcp.dc._msdcs.$DOM" "$(echo "$SRV" | tr '\n' ' ')" "OK"
    DC=$(echo "$SRV" | head -1 | awk '{print $4}' | sed 's/\.$//')
    for P in 88 389; do
      if nc -z -G 3 "$DC" "$P" >/dev/null 2>&1; then status OK "$DC:$P reachable"; add "Network" "$DC:$P" "open" "OK"
      else status ERROR "$DC:$P NOT reachable"; add "Network" "$DC:$P" "closed/filtered" "ERROR"; fi
    done
  else
    status ERROR "No DC SRV records for $DOM — DNS/VPN path problem (KerberosSSO-B Fix 4)"; add "Network" "SRV $DOM" "none" "ERROR"
  fi
fi

if [[ -n "$TEST_HOST" ]]; then
  IP=$(dig +short "$TEST_HOST" | tail -1)
  [[ -n "$IP" ]] && status OK "$TEST_HOST resolves to $IP" || status ERROR "$TEST_HOST does not resolve"
  add "Resource" "$TEST_HOST DNS" "${IP:-none}" "$([[ -n $IP ]] && echo OK || echo ERROR)"
  if nc -z -G 3 "$TEST_HOST" 445 >/dev/null 2>&1; then status OK "$TEST_HOST:445 reachable"; add "Resource" "$TEST_HOST:445" "open" "OK"
  else status ERROR "$TEST_HOST:445 NOT reachable"; add "Resource" "$TEST_HOST:445" "closed" "ERROR"; fi
fi

# ─── Clock ───
OFF=$(sntp -t 5 time.apple.com 2>/dev/null | grep -oE '^[+-]?[0-9.]+' | head -1)
if [[ -n "$OFF" ]]; then
  ABS=${OFF#[-+]}; ABS=${ABS%%.*}
  if [[ "${ABS:-0}" -lt 120 ]]; then status OK "Clock offset ${OFF}s"; add "Time" "offset vs time.apple.com" "$OFF" "OK"
  else status WARN "Clock offset ${OFF}s — Kerberos default max skew is 300s"; add "Time" "offset vs time.apple.com" "$OFF" "WARN"; fi
else
  status INFO "Could not measure clock offset"; add "Time" "offset" "unknown" "INFO"
fi

# ─── Logs ───
LOGS=$(log show --last 15m --style compact --predicate 'subsystem BEGINSWITH "com.apple.AppSSO"' 2>/dev/null | tail -25)
add "Logs" "AppSSO last 15m" "$(echo "$LOGS" | tr '\n' ' ' | cut -c1-4000)" "INFO"

echo
ERRS=$(grep -c '"ERROR"$' "$CSV" || true); WARNS=$(grep -c '"WARN"$' "$CSV" || true)
echo "=== Summary: $ERRS error(s), $WARNS warning(s) ==="
echo "CSV: $CSV"
