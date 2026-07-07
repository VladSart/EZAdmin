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

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — `sudo profiles status` → identify the broken layer → fix → validate
2. **Deep Dive** — macOS MDM architecture, Apple MDM protocol, ADE flow
3. **Learning Pointers** — Apple + Microsoft documentation resources
