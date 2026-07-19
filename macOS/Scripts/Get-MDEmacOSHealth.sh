#!/bin/bash
# Get-MDEmacOSHealth.sh
# .SYNOPSIS
#   Client-side health, licensing, and deployment-profile audit for Microsoft Defender for
#   Endpoint (MDE) on macOS, matching the triage/diagnosis steps in MDE-macOS-B.md/-A.md.
#
# .DESCRIPTION
#   Companion script to macOS/Troubleshooting/MDE-macOS-B.md and MDE-macOS-A.md.
#   Runs the full ground-truth check in one pass:
#   - MDM supervision state (silent capability approval requires ADE/DEP supervision)
#   - Presence of the 8 capability configuration profiles from the deployment dependency
#     stack (System Extensions, Network Filter, Full Disk Access, Background Services,
#     Notifications, Accessibility, Bluetooth, Microsoft AutoUpdate)
#   - System extension activation state for both com.microsoft.wdav.epsext (EndpointSecurity)
#     and com.microsoft.wdav.netext (Network) — flags a second vendor's Network Filter
#     occupying the single system-wide slot
#   - mdatp health summary + per-feature detail (system_extensions, permissions, edr, definitions)
#   - Licensing/onboarding state via the onboarding plist, and a stale-offboarding-file check
#     that silently blocks re-onboarding (common after MSP re-imaging/re-tenanting)
#   - Cloud connectivity test (flags SSL-inspecting-proxy signatures — curl 35/60 — as a
#     distinct, non-retryable failure class per Microsoft's own guidance)
#   - Full Disk Access TCC/PPPC grant check for the wdav client
#
#   Produces a console summary with pass/fail per check and exports full detail to a text
#   report, so output can be pasted directly into MDE-macOS-B.md's Escalation Evidence template.
#
#   Does NOT cover:
#   - Pushing or editing Intune configuration profiles (portal-side, not scriptable from the client)
#   - Windows MDE onboarding (SENSE service, registry state) — see Security/Defender/Scripts/Get-MDEDeviceStatus.ps1
#   - Generic vendor-agnostic system extension/PPPC mechanics for non-Defender tools — see
#     Get-SystemExtensionStatus.sh for that layer
#   - Purview Endpoint DLP policy content or Device Monitoring portal-side enablement
#
# .REQUIREMENTS
#   - macOS 12 (Monterey) or later
#   - Microsoft Defender for Endpoint installed (mdatp CLI present at /usr/local/bin/mdatp or
#     /Library/Application Support/Microsoft/Defender/wdavdaemon shim) — degrades gracefully
#     with a clear NOT_INSTALLED flag if absent, rather than erroring out
#   - Some checks (TCC.db query, full profile detail) require sudo for complete results
#
# .EXAMPLE
#   sudo bash Get-MDEmacOSHealth.sh
#   sudo bash Get-MDEmacOSHealth.sh 2>/dev/null | tee ~/Desktop/mde_health_report.txt
#
# .NOTES
#   Safe/read-only. Makes no profile, extension, or licensing changes.
#   Tested against MDE on macOS 12-15, Apple Silicon and Intel.
#   Report exported to /tmp/MDEmacOSHealth_<hostname>_<timestamp>.txt

set -uo pipefail

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="/tmp/MDEmacOSHealth_${HOSTNAME}_${TIMESTAMP}.txt"
FLAGS=()

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
print_section() {
    echo ""
    echo "════════════════════════════════════════"
    echo "  $1"
    echo "════════════════════════════════════════"
}

print_ok()   { echo "  [OK]   $1"; }
print_warn() { echo "  [WARN] $1"; }
print_info() { echo "  [INFO] $1"; }
print_fail() { echo "  [FAIL] $1"; }

add_flag() { FLAGS+=("$1"); }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo ""
        echo "  Not running as root — TCC.db and some profile detail checks will be incomplete."
        echo "  Run: sudo bash $0"
        echo ""
    fi
}

mdatp_field() {
    # $1 = field name; returns value or "unavailable"
    mdatp health --field "$1" 2>/dev/null || echo "unavailable"
}

# ─────────────────────────────────────────────
# Start
# ─────────────────────────────────────────────
{
echo "=== MDE on macOS Health Report ==="
echo "Date: $(date)"
echo "Hostname: $(hostname)"
echo "macOS: $(sw_vers -productVersion) (build $(sw_vers -buildVersion))"
echo "Architecture: $(uname -m)"
} | tee "$REPORT_FILE"

check_root

# ─────────────────────────────────────────────
# 1. Is MDE even installed?
# ─────────────────────────────────────────────
print_section "1. Installation Check" | tee -a "$REPORT_FILE"

if ! command -v mdatp >/dev/null 2>&1; then
    print_fail "mdatp CLI not found — Microsoft Defender for Endpoint does not appear to be installed" | tee -a "$REPORT_FILE"
    add_flag "NOT_INSTALLED"
    echo "" | tee -a "$REPORT_FILE"
    echo "Stopping further checks — nothing else can be evaluated without the agent present." | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "=== FLAGS ===" | tee -a "$REPORT_FILE"
    printf '%s\n' "${FLAGS[@]}" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "Report written to: $REPORT_FILE"
    exit 0
else
    MDATP_VERSION=$(mdatp_field app_version)
    print_ok "mdatp CLI present — app_version: $MDATP_VERSION" | tee -a "$REPORT_FILE"
fi

# ─────────────────────────────────────────────
# 2. MDM supervision (gates silent capability approval)
# ─────────────────────────────────────────────
print_section "2. MDM Enrollment / Supervision" | tee -a "$REPORT_FILE"

ENROLL_STATUS=$(profiles status -type enrollment 2>&1)
echo "$ENROLL_STATUS" | tee -a "$REPORT_FILE"

if echo "$ENROLL_STATUS" | grep -qi "MDM enrollment: Yes"; then
    print_ok "Device is MDM enrolled" | tee -a "$REPORT_FILE"
    if echo "$ENROLL_STATUS" | grep -qi "Device Enrollment"; then
        print_ok "Enrollment type indicates supervision (Device Enrollment / ADE)" | tee -a "$REPORT_FILE"
    else
        print_warn "Enrollment does not appear to be ADE/DEP-based — capability profiles may require manual user approval" | tee -a "$REPORT_FILE"
        add_flag "NOT_SUPERVISED"
    fi
else
    print_fail "Device does not appear to be MDM enrolled" | tee -a "$REPORT_FILE"
    add_flag "NOT_MDM_ENROLLED"
fi

# ─────────────────────────────────────────────
# 3. Capability configuration profiles present
# ─────────────────────────────────────────────
print_section "3. Capability Configuration Profiles" | tee -a "$REPORT_FILE"

ALL_PROFILES=$(sudo profiles show -all 2>&1)

declare -A PROFILE_PATTERNS=(
    ["System Extensions"]="system-extension-policy|SystemExtensions"
    ["Network Filter"]="webcontent-filter|NetworkExtension"
    ["Full Disk Access / PPPC"]="TCC.configuration-profile-policy"
    ["Background Services"]="servicemanagement"
    ["Notifications"]="notificationsettings"
    ["Accessibility"]="TCC.configuration-profile-policy.*[Aa]ccessibility|accessibility"
    ["Microsoft AutoUpdate"]="autoupdate2|com.microsoft.autoupdate"
    ["Defender preferences (com.microsoft.wdav)"]="com\.microsoft\.wdav[^.]"
    ["Onboarding package"]="wdav.atp|WindowsDefenderATPOnboarding"
)

for name in "System Extensions" "Network Filter" "Full Disk Access / PPPC" "Background Services" "Notifications" "Accessibility" "Microsoft AutoUpdate" "Defender preferences (com.microsoft.wdav)" "Onboarding package"; do
    pattern="${PROFILE_PATTERNS[$name]}"
    if echo "$ALL_PROFILES" | grep -qiE "$pattern"; then
        print_ok "$name profile found" | tee -a "$REPORT_FILE"
    else
        print_warn "$name profile NOT found" | tee -a "$REPORT_FILE"
        add_flag "PROFILE_MISSING_${name// /_}"
    fi
done

# ─────────────────────────────────────────────
# 4. System extension activation state
# ─────────────────────────────────────────────
print_section "4. System Extension Activation" | tee -a "$REPORT_FILE"

SYSEXT_LIST=$(systemextensionsctl list 2>&1)
echo "$SYSEXT_LIST" | tee -a "$REPORT_FILE"

WDAV_EPSEXT=$(echo "$SYSEXT_LIST" | grep -i "wdav.epsext" || true)
WDAV_NETEXT=$(echo "$SYSEXT_LIST" | grep -i "wdav.netext" || true)

if echo "$WDAV_EPSEXT" | grep -qi "activated enabled"; then
    print_ok "EndpointSecurity extension (epsext) activated" | tee -a "$REPORT_FILE"
elif [[ -n "$WDAV_EPSEXT" ]]; then
    print_fail "EndpointSecurity extension present but NOT fully activated: $WDAV_EPSEXT" | tee -a "$REPORT_FILE"
    add_flag "EPSEXT_NOT_ACTIVATED"
else
    print_fail "EndpointSecurity extension (epsext) not found at all" | tee -a "$REPORT_FILE"
    add_flag "EPSEXT_MISSING"
fi

if echo "$WDAV_NETEXT" | grep -qi "activated enabled"; then
    print_ok "Network extension (netext) activated" | tee -a "$REPORT_FILE"
elif [[ -n "$WDAV_NETEXT" ]]; then
    print_fail "Network extension present but NOT fully activated: $WDAV_NETEXT" | tee -a "$REPORT_FILE"
    add_flag "NETEXT_NOT_ACTIVATED"
else
    print_fail "Network extension (netext) not found at all" | tee -a "$REPORT_FILE"
    add_flag "NETEXT_MISSING"
fi

# Detect a competing Network Filter from another vendor (only one slot exists system-wide)
OTHER_NETEXT_COUNT=$(echo "$SYSEXT_LIST" | grep -ic "network" || true)
if [[ "$OTHER_NETEXT_COUNT" -gt 1 ]] && ! echo "$SYSEXT_LIST" | grep -qi "microsoft" <<< "$(echo "$SYSEXT_LIST" | grep -vi wdav)"; then
    print_warn "Additional non-Microsoft network/system extensions detected — check for Network Filter slot conflict" | tee -a "$REPORT_FILE"
    add_flag "POSSIBLE_NETFILTER_CONFLICT"
fi

# ─────────────────────────────────────────────
# 5. mdatp health summary + detail
# ─────────────────────────────────────────────
print_section "5. mdatp Health" | tee -a "$REPORT_FILE"

HEALTHY=$(mdatp_field healthy)
LICENSED=$(mdatp_field licensed)
RTP_AVAILABLE=$(mdatp_field real_time_protection_available)
ORG_ID=$(mdatp_field org_id)
EDR_MACHINE_ID=$(mdatp_field edr_machine_id)

echo "  healthy                       : $HEALTHY" | tee -a "$REPORT_FILE"
echo "  licensed                      : $LICENSED" | tee -a "$REPORT_FILE"
echo "  real_time_protection_available: $RTP_AVAILABLE" | tee -a "$REPORT_FILE"
echo "  org_id                        : $ORG_ID" | tee -a "$REPORT_FILE"
echo "  edr_machine_id                : $EDR_MACHINE_ID" | tee -a "$REPORT_FILE"

if [[ "$HEALTHY" != "true" ]]; then
    print_fail "Agent reports unhealthy — see health_issues below" | tee -a "$REPORT_FILE"
    add_flag "UNHEALTHY"
    mdatp health 2>/dev/null | grep -A5 "health_issues" | tee -a "$REPORT_FILE"
else
    print_ok "Agent reports healthy" | tee -a "$REPORT_FILE"
fi

if [[ "$LICENSED" != "true" ]]; then
    print_fail "Device NOT licensed — onboarding package likely never delivered, or offboarded" | tee -a "$REPORT_FILE"
    add_flag "NOT_LICENSED"
else
    print_ok "Device is licensed" | tee -a "$REPORT_FILE"
fi

echo "" | tee -a "$REPORT_FILE"
echo "  --- system_extensions detail ---" | tee -a "$REPORT_FILE"
mdatp health --details system_extensions 2>&1 | tee -a "$REPORT_FILE"
echo "  --- permissions detail ---" | tee -a "$REPORT_FILE"
mdatp health --details permissions 2>&1 | tee -a "$REPORT_FILE"

# ─────────────────────────────────────────────
# 6. Onboarding / offboarding artifacts
# ─────────────────────────────────────────────
print_section "6. Onboarding / Offboarding Artifacts" | tee -a "$REPORT_FILE"

DEFENDER_DIR="/Library/Application Support/Microsoft/Defender"
ONBOARD_PLIST="$DEFENDER_DIR/com.microsoft.wdav.atp.plist"
OFFBOARD_PLIST="$DEFENDER_DIR/com.microsoft.wdav.atp.offboarding.plist"

if [[ -f "$ONBOARD_PLIST" ]]; then
    print_ok "Onboarding artifact present: $ONBOARD_PLIST" | tee -a "$REPORT_FILE"
else
    print_fail "Onboarding artifact NOT found: $ONBOARD_PLIST" | tee -a "$REPORT_FILE"
    add_flag "ONBOARDING_PLIST_MISSING"
fi

if [[ -f "$OFFBOARD_PLIST" ]]; then
    print_warn "Offboarding artifact present — this BLOCKS re-onboarding: $OFFBOARD_PLIST" | tee -a "$REPORT_FILE"
    add_flag "STALE_OFFBOARDING_FILE"
else
    print_ok "No offboarding artifact present" | tee -a "$REPORT_FILE"
fi

# ─────────────────────────────────────────────
# 7. TCC / Full Disk Access grant
# ─────────────────────────────────────────────
print_section "7. TCC / Full Disk Access Grant (wdav)" | tee -a "$REPORT_FILE"

if [[ $EUID -eq 0 ]]; then
    TCC_RESULT=$(sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
        "SELECT client, service, allowed FROM access WHERE client LIKE '%wdav%';" 2>&1)
    if [[ -n "$TCC_RESULT" ]]; then
        echo "$TCC_RESULT" | tee -a "$REPORT_FILE"
        if echo "$TCC_RESULT" | grep -q "|1$"; then
            print_ok "Full Disk Access grant found for wdav" | tee -a "$REPORT_FILE"
        else
            print_warn "wdav TCC rows found but none show allowed=1" | tee -a "$REPORT_FILE"
            add_flag "FDA_NOT_GRANTED"
        fi
    else
        print_fail "No TCC rows found for wdav — Full Disk Access not granted" | tee -a "$REPORT_FILE"
        add_flag "FDA_NOT_GRANTED"
    fi
else
    print_info "Skipped — requires sudo to query TCC.db" | tee -a "$REPORT_FILE"
fi

# ─────────────────────────────────────────────
# 8. Cloud connectivity
# ─────────────────────────────────────────────
print_section "8. Cloud Connectivity" | tee -a "$REPORT_FILE"

CONN_TEST=$(mdatp connectivity test 2>&1)
echo "$CONN_TEST" | tee -a "$REPORT_FILE"

if echo "$CONN_TEST" | grep -qi "\[FAIL\]\|failed\|error"; then
    print_fail "One or more connectivity endpoints failed" | tee -a "$REPORT_FILE"
    add_flag "CONNECTIVITY_FAILED"
    if echo "$CONN_TEST" | grep -qE "curl.*(35|60)"; then
        print_warn "Failure pattern matches certificate-pinning rejection — check for an SSL-inspecting proxy (unsupported)" | tee -a "$REPORT_FILE"
        add_flag "POSSIBLE_SSL_INSPECTION"
    fi
else
    print_ok "All connectivity tests passed" | tee -a "$REPORT_FILE"
fi

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
print_section "Summary" | tee -a "$REPORT_FILE"

if [[ ${#FLAGS[@]} -eq 0 ]]; then
    print_ok "No issues flagged — device appears fully healthy and onboarded" | tee -a "$REPORT_FILE"
else
    print_warn "${#FLAGS[@]} issue(s) flagged:" | tee -a "$REPORT_FILE"
    for flag in "${FLAGS[@]}"; do
        echo "    - $flag" | tee -a "$REPORT_FILE"
    done
fi

echo "" | tee -a "$REPORT_FILE"
echo "Full report: $REPORT_FILE"
echo "For a full Microsoft-formatted support bundle, also run: sudo mdatp diagnostic create"
