# macOS — Agent Instructions

## What's in this folder

macOS device management via Microsoft Intune — enrollment, configuration profiles, shell scripts, and compliance.

Covers:
- **ADE (Automated Device Enrollment)** — Apple Business (formerly Apple Business Manager) + Intune + DEP profile
- **BYOD enrollment** — Company Portal, manual MDM enrollment
- **Configuration profiles** — password policy, FileVault, firewall, restrictions
- **Shell scripts** — deploying and troubleshooting Intune shell scripts on macOS
- **Compliance** — macOS compliance policies, FileVault encryption reporting
- **Company Portal** — app visibility, install failures
- **Recovery Lock** — Apple Silicon-only recoveryOS/Startup Options password, Settings Catalog policy, check-in-gated rotation, no local bypass (distinct from FileVault Secure Token/Bootstrap Token — see FileVault-A.md for the related-but-separate credential system)
- **Wi-Fi / 802.1X Enterprise** — WPA/WPA2-Enterprise Wi-Fi and wired 802.1X authentication; the three-profile certificate dependency (network profile + Trusted root profile + SCEP/PKCS profile), deployment channel (User/Device) architecture, and `eapolclient` diagnosis
- **Declarative Device Management (DDM)** — the general DDM protocol/transport layer underneath Software Updates, Compliance, and Settings Catalog "Declarative Device Management" category settings; macOS 13+ hard floor, the four declaration types (Configurations/Assets/Activations/Management), the Status Channel, and the false-error/downgrade-detection pattern — distinct from `SoftwareUpdates-A/B.md`'s update-specific content
- **Time Machine backup policy** — the `com.apple.MCX.TimeMachine` MDM payload (Settings Catalog); configuration-delivery-only with no Intune-side completion signal, the credential-provisioning gap for authenticated network destinations, and the Device Enrollment/ADE-only enrollment-method gate
- **VPP / Apple Business (formerly Apple Business Manager) app deployment** — location tokens (formerly VPP tokens), Device vs. User licensing models, the "Intune is a license broker, Apple is the installer" architecture, license oversubscription, and the macOS-specific 30-day post-revocation grace period — distinct from `ABM-Token-Renewal-A.md`'s device-enrollment/DEP token (a separate credential that can, but need not, share the same Managed Apple Account)
- **Managed Login Items** — the `com.apple.servicemanagement` payload and its underlying `SMAppService`/Background Task Management framework; pre-approves (does not install) login items/launch agents/launch daemons via BundleIdentifier/TeamIdentifier/Label rule matching; macOS 13 hard floor that is explicitly NOT retroactive across an OS upgrade, and the newer macOS 26 background-task-continuation prompt
- **Content Caching** — Apple's native local-network caching service for Software Update/App Store/iCloud content, turned on and configured (not operated) via Settings Catalog; discovery is grouped by public IP + local subnet (an Apple-native mechanism, not an Intune/Entra construct) and is the single most common source of "configured correctly but nothing happens" tickets; zero Intune-side telemetry for hit rate or serving, same "configuration delivery only" shape as Time Machine
- **Gatekeeper / Notarization** — custom/internally-signed `.pkg`/`.app` deployments blocked at launch despite installing successfully via Intune, since MDM-pushed installs bypass the interactive Gatekeeper prompt that would normally catch a signing/notarization gap; Developer ID Application vs. Developer ID Installer certificate distinction, notarization/stapling, the quarantine attribute's role, and the Settings Catalog System Policy (`AllowIdentifiedDevelopers`/`EnableAssessment`) layer that can block every non-MAS app fleet-wide — distinct from `Compliance-Policies-A.md`'s use of `spctl --status` as a pass/fail compliance signal
- **Microsoft Defender for Endpoint (MDE) on macOS** — the product-specific Intune deployment (12 components: 8 capability-approval configuration profiles, an AutoUpdate channel pin, the app itself, and a separately-licensed onboarding package), the `mdatp` CLI as ground truth over "profile shows Succeeded," the single-system-wide-Network-Filter-slot conflict with other AV/EDR vendors, and SSL-inspecting-proxy incompatibility on the cloud channel — this is the macOS/Linux-specific gap explicitly left open by `Security/Defender/MDE-Onboarding-A.md`/`-B.md` (Windows-only, SENSE-service-based); distinct from `Extensions-A.md`'s vendor-agnostic system extension/PPPC mechanics, which this topic builds directly on top of
- **Apple Device Migration** — the macOS 26+ Apple Business/School Manager "Assign Device Management" wipe-free MDM-to-MDM re-enrollment workflow, and Managed Migration Assistant (macOS 26.4+ destination), the declarative-config-controlled Mac-to-Mac Home-folder data transfer during Setup Assistant; both gated by Apple eligibility checks (OS version, ADE ownership, Shared iPad/ABE exclusions) invisible to and not overridable from Intune, and both explicitly do NOT copy configuration profiles/policies/scripts from the old MDM — only enrollment, already-installed managed apps, and (for Migration Assistant) user data — distinct from the pre-26 wipe-based MDM move still covered in `ADE-Enrollment-A.md` Playbook 2
- **Managed Apple ID Federation with Entra ID** — linking a verified Apple Business (formerly Apple Business Manager) domain to the Microsoft Entra ID OIDC global cloud so a user's **Managed Apple Account** itself is backed by their Entra identity; the three-step Approve/Test/Turn-on setup flow, the hard `userPrincipalName`-must-equal-email requirement (no aliases/Alternate IDs), the separately-toggled directory-sync feature and its read-only attribute mapping, and Entra audit-log-driven forced session termination on password change/reset — distinct from Platform SSO (a device-level authentication extension, not the identity behind the Apple Account itself) and from the ABM/DEP and VPP tokens in `ABM-Token-Renewal-A.md` (device enrollment/licensing, unrelated to user sign-in identity)
- **Global Secure Access (GSA) client for macOS** — the macOS-specific install/architecture/troubleshooting surface for Entra's SSE client: system extension (`com.microsoft.globalsecureaccess.tunnel`) + transparent application proxy as two independently-gated components, MDM allow-listing via two separate profiles, the June 2025 bundle-identifier migration (`com.microsoft.naas.globalsecure*` → `com.microsoft.globalsecureaccess*`) that traps fleets whose MDM profiles predate it, the mandatory client-version floor (1.1.25070402+) before any macOS 26 upgrade, and the documented GSA/Explicit Forward Proxy coexistence conflict on macOS — distinct from the tenant-side forwarding-profile/connector/Conditional-Access content in `EntraID/Troubleshooting/GlobalSecureAccess-A.md`/`-B.md`, which this topic assumes is already healthy

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
- "VPP app not installing / license exhausted / VPP token expired or invalid / app frozen on old version" → `Troubleshooting/VPP-App-Deployment-B.md` + `Troubleshooting/VPP-App-Deployment-A.md` + `Scripts/Get-VPPAppLicenseAudit.ps1` (admin-side Graph check — token health + per-app license utilization; do not confuse with the ABM/DEP device-enrollment token, see `ABM-Token-Renewal-B.md`)
- "Corporate app's login item can still be disabled / helper won't stay running / user keeps getting a background-task permission prompt" → `Troubleshooting/ManagedLoginItems-B.md` + `Troubleshooting/ManagedLoginItems-A.md` + `Scripts/Get-ManagedLoginItemsAudit.sh` (device-local — `sfltool dumpbtm` is the primary diagnostic; almost always a BundleIdentifier/TeamIdentifier/Label rule-matching gap, not a delivery failure)
- "Content Caching not working / Macs still downloading updates from the internet / cache not being discovered" → `Troubleshooting/ContentCaching-B.md` + `Troubleshooting/ContentCaching-A.md` + `Scripts/Get-ContentCachingAudit.sh` (device-local, run in `-Mode host` on the cache host and `-Mode client` on an affected client for comparison — discovery is grouped by PUBLIC IP, not Intune assignment; a mismatch there explains most tickets)
- "Custom app blocked / unidentified developer / app is damaged / installed via Intune but won't open" → `Troubleshooting/Gatekeeper-Notarization-B.md` + `Troubleshooting/Gatekeeper-Notarization-A.md` + `Scripts/Get-GatekeeperPolicyAudit.ps1` (admin-side Graph check — fleet-wide Settings Catalog System Policy misconfiguration only; individual app signing/notarization is exclusively device-local, triage first via `spctl -a -vvv` and `codesign -dv` on the Mac itself)
- "Defender shield shows a red x / No license found / mdatp health unhealthy / EDR sensor not reporting on a Mac" → `Troubleshooting/MDE-macOS-B.md` + `Troubleshooting/MDE-macOS-A.md` + `Scripts/Get-MDEmacOSHealth.sh` (device-local — `mdatp health` is ground truth over Intune's "profile Succeeded" status; triage first with `mdatp health` and `systemextensionsctl list`)
- "Two security products fighting over network filtering on a Mac / AV migration on macOS" → `Troubleshooting/MDE-macOS-A.md` Playbook 4 (single system-wide Network Filter slot is an Apple OS limit, not vendor-configurable)
- "Moving Macs from Jamf/another MDM to Intune without wiping" / "'Add Deadline' greyed out in ABM when assigning a new MDM server" / "Mac stuck at a full-screen migration prompt" → `Troubleshooting/DeviceMigration-B.md` + `Troubleshooting/DeviceMigration-A.md` + `Scripts/Get-DeviceMigrationReadiness.ps1` (admin-side Graph check — APNs/ABM token health + fleet-wide macOS 26/26.4 readiness classification; pending migrations and the ABM/ASM Activity log are NOT Graph-visible, check the ABM/ASM console directly)
- "New Mac missing files after 'Transfer Your Data to This Mac'" / "Managed Migration Assistant data incomplete" → `Troubleshooting/DeviceMigration-B.md` Fix 5 (check the Intune declarative status transfer report first — it lists exactly which files failed, and confirm the destination is on macOS 26.4+ specifically, not just 26.0+)
- "User can't sign in with Entra credentials on a new Mac/iPhone/iPad" / "Federated sign-in fails with a generic error" → `Troubleshooting/ManagedAppleID-Federation-B.md` + `Troubleshooting/ManagedAppleID-Federation-A.md` (check `userPrincipalName` vs. `Mail` match first — the single highest-frequency cause; no alias/Alternate ID support) + `Scripts/Get-EntraFederationReadiness.ps1` (admin-side Graph check — UPN/email match, alias risk, domain verification, recent password events; does not check the Apple Business console's own federation toggle/conflict banner/sync state, which must be checked manually)
- "New Entra users never appear in Apple Business" / "Users randomly forced to reauthenticate on every Apple device" → `Troubleshooting/ManagedAppleID-Federation-B.md` Fix 5 (federation ≠ directory sync, two separate toggles) / Fix 4 (expected behavior after a password change/reset — not a bug)
- "Mac user can't print to a Universal Print printer" / "Printer visible but jobs fail for this user" → `../M365/UniversalPrint/Universal-Print-macOS-B.md` + `../M365/UniversalPrint/Universal-Print-macOS-A.md` + `../M365/UniversalPrint/Scripts/Get-UniversalPrintMacOSReadiness.ps1` (visibility is per-device, permission is per-user at print time — printer showing up is not proof this user can print to it)
- "GSA client won't connect / stuck on Disconnected / system extension blocked on a Mac" / "GSA broke after upgrading to macOS 26" / "new Macs fail extension approval but existing fleet is fine" → `Troubleshooting/GlobalSecureAccess-macOS-B.md` + `Troubleshooting/GlobalSecureAccess-macOS-A.md` + `Scripts/Get-GSAmacOSHealth.sh` (device-local — checks system extension/proxy activation against BOTH current and deprecated pre-June-2025 bundle identifiers, client version vs. the macOS 26 floor, and secure-DNS/PAC conflicts; tenant-side forwarding profile and Private Access connector health are Graph-side checks, see `../EntraID/Troubleshooting/GlobalSecureAccess-B.md` instead)

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — `sudo profiles status` → identify the broken layer → fix → validate
2. **Deep Dive** — macOS MDM architecture, Apple MDM protocol, ADE flow
3. **Learning Pointers** — Apple + Microsoft documentation resources
