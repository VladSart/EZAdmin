# macOS — Agent Instructions

## What's in this folder

macOS device management via Microsoft Intune — enrollment, configuration profiles, shell scripts, and compliance.

Covers:
- **ADE (Automated Device Enrollment)** — Apple Business Manager + Intune + DEP profile
- **BYOD enrollment** — Company Portal, manual MDM enrollment
- **Configuration profiles** — password policy, FileVault, firewall, restrictions
- **Shell scripts** — deploying and troubleshooting Intune shell scripts on macOS
- **Compliance** — macOS compliance policies, FileVault encryption reporting
- **Company Portal** — app visibility, install failures
- **Recovery Lock** — Apple Silicon-only recoveryOS/Startup Options password, Settings Catalog policy, check-in-gated rotation, no local bypass (distinct from FileVault Secure Token/Bootstrap Token — see FileVault-A.md for the related-but-separate credential system)
- **Wi-Fi / 802.1X Enterprise** — WPA/WPA2-Enterprise Wi-Fi and wired 802.1X authentication; the three-profile certificate dependency (network profile + Trusted root profile + SCEP/PKCS profile), deployment channel (User/Device) architecture, and `eapolclient` diagnosis
- **Declarative Device Management (DDM)** — the general DDM protocol/transport layer underneath Software Updates, Compliance, and Settings Catalog "Declarative Device Management" category settings; macOS 13+ hard floor, the four declaration types (Configurations/Assets/Activations/Management), the Status Channel, and the false-error/downgrade-detection pattern — distinct from `SoftwareUpdates-A/B.md`'s update-specific content
- **Time Machine backup policy** — the `com.apple.MCX.TimeMachine` MDM payload (Settings Catalog); configuration-delivery-only with no Intune-side completion signal, the credential-provisioning gap for authenticated network destinations, and the Device Enrollment/ADE-only enrollment-method gate

---

## Before responding, also check

- `Intune/` — macOS management is a sub-domain of Intune; enrollment architecture is the same
- `EntraID/` — Entra join for macOS (platform SSO) and token issues

---

## Key diagnostic commands

```bash
# On the Mac — MDM enrollment state
sudo profiles status -type enrollment

# List all installed MDM profiles
sudo profiles list -all

# Check Intune agent logs
log show --predicate 'subsystem == "com.microsoft.intune"' --last 1h

# Company Portal logs
~/Library/Logs/Company\ Portal/

# Check MDM push notification token (required for remote actions)
sudo profiles -e /tmp/MDMProfile.plist
```

---

## Common entry points

- "Mac not enrolling via ADE" → check ABM token in Intune + DEP profile assignment
- "New Macs stopped appearing for ADE sync" or "VPP app licenses failing" (existing Macs check in fine) → `Troubleshooting/ABM-Token-Renewal-B.md` (hotfix) / `Troubleshooting/ABM-Token-Renewal-A.md` (deep dive — token architecture, VPP vs. device sync split) + `Scripts/Get-ABMTokenStatus.ps1` (admin-side Graph check — tenant-wide token expiry, sync error, and stale-sync report; not device-local since ABM token health isn't observable from a Mac) — do not confuse with MDM push cert expiry, see comparison table in that file
- "Shell script not running / showing as failed" → `Troubleshooting/Shell-Script-Failures-B.md` + `Troubleshooting/Shell-Script-Failures-A.md` + `Scripts/Get-ShellScriptFailureDiagnostics.sh` (agent/IME presence, system extension trust, PATH/context, Rosetta, both log surfaces)
- "FileVault not being reported to Intune" → compliance profile + FileVault escrow settings → `Troubleshooting/FileVault-B.md` + `Scripts/Get-FileVaultStatus.sh`
- "Mac not enrolling / stuck at Setup Assistant" → `Troubleshooting/ADE-Enrollment-B.md` + `Scripts/Get-ADEEnrollmentStatus.sh`
- "Company Portal shows no apps" → check app assignment + device group membership
- "Platform SSO not registering / user stuck at sign-in / SSO not working" → `Troubleshooting/Platform-SSO-B.md` + `Troubleshooting/Platform-SSO-A.md` + `Scripts/Get-PlatformSSOStatus.sh`
- "macOS update not offered / stuck on old version / update deadline questions" → `Troubleshooting/SoftwareUpdates-B.md` + `Troubleshooting/SoftwareUpdates-A.md` + `Scripts/Get-SoftwareUpdateStatus.sh`
- "Compliance policy shows non-compliant / device not reporting correctly" → `Troubleshooting/Compliance-Policies-B.md` + `Troubleshooting/Compliance-Policies-A.md` + `Scripts/Get-ComplianceStatus.sh`
- "System extension blocked / kernel extension not approved / PPPC prompt appearing when it shouldn't" → `Troubleshooting/Extensions-B.md` + `Troubleshooting/Extensions-A.md` + `Scripts/Get-SystemExtensionStatus.sh`
- "Privacy Preferences Policy Control (PPPC/TCC) permission not being granted silently" → `Troubleshooting/PPPC-B.md` + `Troubleshooting/PPPC-A.md` + `Scripts/Get-PPPCStatus.sh`
- "MDM push certificate expiring or expired / device dropped MDM management" → `Troubleshooting/MDM-Certificate-Renewal-B.md` + `Troubleshooting/MDM-Certificate-Renewal-A.md` + `Scripts/Get-MDMCertificateStatus.sh` + `Scripts/Repair-MacMDMEnrollment.sh`
- "General Mac/Intune status check before deeper triage" → `Scripts/Get-MacIntuneStatus.sh`
- "Recovery Lock passcode needed / user stuck at recoveryOS prompt / Rotate action greyed out / device eligibility for Recovery Lock" → `Troubleshooting/RecoveryLock-B.md` + `Troubleshooting/RecoveryLock-A.md` + `Scripts/Get-RecoveryLockAudit.ps1` (admin-side Graph check — policy assignment + fleet supervision/sync-freshness eligibility; the passcode itself is never bulk-queryable, only per-device in the Intune portal with the correct RBAC "Remote tasks" permission)
- "Mac won't join enterprise Wi-Fi / 802.1X wired network fails / cert-based Wi-Fi not authenticating" → `Troubleshooting/WiFi-8021x-B.md` + `Troubleshooting/WiFi-8021x-A.md` + `Scripts/Get-WiFiProfileAudit.ps1` (admin-side Graph check — cross-references network/Trusted-root/SCEP-PKCS profile assignment scope for the "three-legged stool" gap; triage first via `security find-identity -v -p ssl-client` and the `eapolclient` log on the Mac itself)
- "Software Update / Compliance / a Settings Catalog policy all stuck or erroring at once on one device" or "DDM declaration not landing / device eligibility for DDM" → `Troubleshooting/DDM-B.md` + `Troubleshooting/DDM-A.md` + `Scripts/Get-DDMStatusAudit.ps1` (admin-side Graph check — fleet-wide macOS-13+ eligibility + DDM-category Settings Catalog policy inventory; `mdmclient QueryDeclarations`/`QueryResponses` remain the device-local source of truth, not Graph-visible)
- "Managed Time Machine not backing up / destination not configuring / backup destination questions" → `Troubleshooting/TimeMachine-B.md` + `Troubleshooting/TimeMachine-A.md` + `Scripts/Get-TimeMachineBackupAudit.sh` (device-local — there is no Intune-side backup-completion report; script checks destination reachability, credential presence, and last-backup recency)

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — `sudo profiles status` → identify the broken layer → fix → validate
2. **Deep Dive** — macOS MDM architecture, Apple MDM protocol, ADE flow
3. **Learning Pointers** — Apple + Microsoft documentation resources
