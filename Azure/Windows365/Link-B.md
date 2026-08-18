# Windows 365 Link — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Windows 365 Link is a **physical thin-client hardware device**, not a regular Windows PC — most of the usual endpoint-troubleshooting instincts (Autopilot, malware scans, remediation scripts, local app installs) do not apply here. Run these first.

```powershell
# 1. Confirm the device exists in Intune at all and check its compliance/enrollment state
Get-MgDeviceManagementManagedDevice -Filter "model eq 'Windows 365 Link'" |
    Select-Object DeviceName, SerialNumber, ComplianceState, ManagementState, EnrolledDateTime

# 2. Confirm the target Cloud PC has SSO enabled — the #1 cause of "can't connect" tickets
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy |
    Select-Object DisplayName, Id, MicrosoftEntraSingleSignOnStatus

# 3. Confirm the joining user holds an Entra ID P1 (or bundle) license — required for automatic enrollment
Get-MgUserLicenseDetail -UserId "<user@domain.com>" | Select-Object SkuPartNumber, ServicePlans

# 4. If a remote action (Wipe, Sync, Restart) seems stuck, rule out sleep/disconnected-standby first —
#    Link does not check in or respond to remote actions while asleep
Get-MgDeviceManagementManagedDevice -Filter "model eq 'Windows 365 Link'" |
    Select-Object DeviceName, LastSyncDateTime

# 5. If an app/script assignment shows stuck on a Link device, confirm it was even supposed to apply —
#    app management, malware scans, and remediation scripts don't run on Link at all (see Fix 5)
Get-MgDeviceManagementManagedDevice -Filter "model eq 'Windows 365 Link'" -ExpandProperty detectedApps |
    Select-Object DeviceName -ExpandProperty detectedApps -ErrorAction SilentlyContinue
```

| Result | Action |
|--------|--------|
| Device never appears in Intune after OOBE | → [Fix 1 — Automatic Enrollment Not Occurring](#fix-1--automatic-enrollment-not-occurring) |
| Device won't join Entra ID at first sign-in | → [Fix 2 — Entra Join Blocked](#fix-2--entra-join-blocked) |
| User gets "your Cloud PC doesn't support Entra ID single sign-on" | → [Fix 3 — SSO Not Enabled on Target Cloud PC](#fix-3--sso-not-enabled-on-target-cloud-pc) |
| Connection fails after ~30 days or on first SSO connect, user can't grant consent from the device | → [Fix 4 — SSO Consent Prompt Loop](#fix-4--sso-consent-prompt-loop) |
| App config policy stuck "Pending install," or remediation script never runs, or malware scan action fails | → [Fix 5 — Intune Features That Don't Apply to Link](#fix-5--intune-features-that-dont-apply-to-link) |
| Someone tried to enroll via Autopilot / Autopilot device preparation | → [Fix 6 — Autopilot Is Not Supported](#fix-6--autopilot-is-not-supported) |
| Remote action (Wipe/Sync/Restart) "stuck," device shows old LastSyncDateTime | → [Fix 7 — Device in Disconnected Standby](#fix-7--device-in-disconnected-standby) |
| Device won't boot, needs factory reset, or in-OS reset options are unavailable | → [Fix 8 — Wipe/Reset/Recovery Decision Tree](#fix-8--wipereesetrecovery-decision-tree) |
| Deploying into a MAC-filtered or certificate-authenticated restricted network | → [Fix 9 — Restricted Network Onboarding](#fix-9--restricted-network-onboarding) |
| All triage clean, still failing | → Escalate — Intune admin center → Troubleshooting + Support → Help and Support → Windows 365 → Windows 365 Link |

---
## Dependency Cascade

<details><summary>What must be true for a Windows 365 Link device to be usable</summary>

```
Physical Windows 365 Link device (Windows CPC OS — minimal, purpose-built)
  └── Out of Box Experience (OOBE) — first power-on
        └── Microsoft Entra join
              ├── Entra ID > Devices > Device Settings > "Users may join devices" permits this user
              └── "Maximum number of devices per user" not exceeded (default 50)
                    └── Automatic Intune enrollment
                          ├── Entra ID > Mobility (MDM and WIP) > MDM user scope = All or Some (user's group)
                          ├── Joining user holds Microsoft Entra ID P1 (or bundle) license
                          └── Not blocked by Intune device enrollment restrictions
                                └── Intune management (device appears, Device health compliance only)
                                      ├── BitLocker, Secure Boot, Code Integrity — on by default, can't be disabled
                                      └── App mgmt / malware scan / remediation scripts — DO NOT apply (by design)
                                            └── Connection attempt to a Windows 365 Cloud PC
                                                  ├── Target Cloud PC has Entra ID SSO enabled (provisioning policy)
                                                  ├── SSO consent granted (or suppressed via service principal config)
                                                  └── Conditional Access policies satisfied (device + SSO cloud app)
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the device is enrolled and compliant**
```powershell
Get-MgDeviceManagementManagedDevice -Filter "model eq 'Windows 365 Link'" |
    Select-Object DeviceName, SerialNumber, ComplianceState, ManagementState
```
Expected: `ComplianceState = compliant`. Remember the *only* compliance setting evaluated for Link is Device health (BitLocker/Secure Boot/Code Integrity) — there is nothing else to check here.

**Step 2 — If the device is missing entirely, confirm Entra join permission first, then MDM scope**
```
Entra admin center > Identity > Devices > Overview > Device Settings >
    "Users may join devices to Microsoft Entra" = All (or user's group under Selected)
Entra admin center > Show more > Settings > Mobility (MDM and WIP) > Microsoft Intune >
    MDM user scope = All (or user's group under Some)
```
Expected: Both permit the joining user. If either is missing, the device silently never appears in Intune — there's no error surfaced to the user beyond a failed OOBE sign-in.

**Step 3 — Confirm the joining user's Entra ID P1 license**
```powershell
Get-MgUserLicenseDetail -UserId "<user@domain.com>" | Select-Object SkuPartNumber, ServicePlans
```
Expected: An Entra ID P1-equivalent service plan present. Automatic enrollment (the *only* enrollment path Link supports — there is no manual/bulk-provisioning alternative) requires it.

**Step 4 — Confirm SSO is enabled on the target Cloud PC's provisioning policy**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy |
    Select-Object DisplayName, Id, MicrosoftEntraSingleSignOnStatus
```
Expected: `enabled` for any policy backing a Cloud PC that Link users will connect to. Link **cannot** connect to a non-SSO Cloud PC at all — this isn't a degraded experience, it's a hard block with an explicit on-device error.

**Step 5 — Before treating a stuck remote action as a fault, rule out sleep**
```powershell
Get-MgDeviceManagementManagedDevice -Filter "model eq 'Windows 365 Link'" |
    Select-Object DeviceName, LastSyncDateTime
```
Expected: A stale `LastSyncDateTime` on an otherwise-healthy device usually means disconnected standby, not failure — wake the device (power button, mouse, or keyboard) and retry before escalating.

---
## Common Fix Paths

<details><summary>Fix 1 — Automatic Enrollment Not Occurring</summary>

**When:** Device joined Entra successfully (visible in Entra ID > Devices) but never appears in Intune.

```
1. Entra admin center > Show more > Settings > Mobility (MDM and WIP) > Microsoft Intune
2. Confirm "MDM user scope" = All, or Some with the joining user's group included
3. If more than one MDM app is listed on this page, confirm no conflicting scope overlap —
   only Microsoft Intune should have a non-None scope for users who need Link enrollment
4. Confirm the joining user holds an Entra ID P1 (or bundling) license:
```
```powershell
Get-MgUserLicenseDetail -UserId "<user@domain.com>" | Select-Object SkuPartNumber, ServicePlans
```
```
5. Intune admin center > Tenant administration > Tenant status > Tenant details >
   confirm "MDM authority" = Microsoft Intune
6. Have the user complete OOBE again (Settings > Accounts > Access work or school > Disconnect,
   then power-cycle) once scope/licensing is corrected
```

**Rollback:** N/A — configuration correction, not destructive.

</details>

<details><summary>Fix 2 — Entra Join Blocked</summary>

**When:** OOBE sign-in fails or loops before the device ever reaches Intune enrollment.

```
1. Entra admin center > Identity > Devices > Overview > Device Settings
2. Confirm "Users may join devices to Microsoft Entra" = All, or Selected with the user's
   group included (must be an Entra ID user group, not a mail-enabled or distribution group)
3. Confirm "Maximum number of devices per user" (default 50) hasn't been hit for this user —
   this cap applies even to Device Enrollment Managers
```

**Rollback:** N/A — permission correction.

</details>

<details><summary>Fix 3 — SSO Not Enabled on Target Cloud PC</summary>

**When:** User gets an explicit on-device error that their Cloud PC doesn't support Entra ID SSO and cannot connect.

```powershell
# Confirm the provisioning policy backing the affected Cloud PC
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy |
    Select-Object DisplayName, Id, MicrosoftEntraSingleSignOnStatus

# Enable SSO on the existing policy (applies to all Cloud PCs under it going forward) —
# or provision new Cloud PCs from a policy that already has SSO enabled
```
```
Intune admin center > Devices > Provisioning policies > select policy > enable
"Microsoft Entra ID single sign-on" > Review + Save
```

**Rollback:** N/A — this is an enablement, not a destructive change. Note: this is a **hard requirement**, not a recommendation — Link has no non-SSO connection mode at all.

</details>

<details><summary>Fix 4 — SSO Consent Prompt Loop</summary>

**When:** Connection fails on first SSO connect to a newly-enabled Cloud PC, or recurs roughly every 30 days / after a Cloud PC is reprovisioned — the Link device's connection UI cannot interact with a consent prompt.

```
Option A (immediate, per-user workaround): have the user connect to the same Cloud PC from
another device or a web browser first, grant SSO consent there, then retry from the Link device.

Option B (permanent, tenant-wide fix) — suppress the consent prompt entirely:
1. Create a dynamic device group covering all Cloud PCs
2. Enable Microsoft Entra authentication for RDP on the SSO service principal
3. Add the Cloud PC device group to that service principal's target
   (see Link-A.md Playbook 4 for the full step-by-step)

Option C: confirm the Link device is on the December 2025 Quality Update or later
(version 26100.7462+) — this build added Web Account Manager (WAM) interactive support,
letting users respond to a consent prompt directly on the device when one does appear.
Suppression (Option B) is still the recommended baseline even on this build.
```

**Rollback:** N/A — consent/authentication configuration, not destructive.

</details>

<details><summary>Fix 5 — Intune Features That Don't Apply to Link</summary>

**When:** An app configuration policy shows perpetually "Pending install," a remediation script never shows up in device status reports, or a Quick scan/Full scan/Update Defender intelligence action returns "Initiating (action) failed" against a Link device.

```
This is expected behavior, not a fault — do not spend time troubleshooting these as failures:

- App management: Link runs no local applications. Exclude Link devices from any app
  configuration policy using an Intune device filter (Model eq "Windows 365 Link"), don't
  chase the "Pending install" state.
- Malware scanning: Link doesn't run the Windows Defender Malware component — only the
  Defender EDR sensor. Quick scan / Full scan / Update Windows Defender security intelligence
  device actions silently fail by design.
- Device scripts and remediations: Link's strict, non-modifiable Application Control policy
  blocks remediation script packages from executing at all — they will never appear in
  scripts-and-remediations device status reports for these devices.
```
```powershell
# Build the exclusion filter once, reuse across app/script assignments
# (Intune admin center > Devices > Filters > Create — Filter query:
#   (device.model -eq "Windows 365 Link"))
```

**Rollback:** N/A — no action was actually failing; this documents expected scope limits.

</details>

<details><summary>Fix 6 — Autopilot Is Not Supported</summary>

**When:** Someone attempts to enroll a Link device via Windows Autopilot or Autopilot device preparation, assigns an Autopilot deployment profile to it, or expects Autopilot Reset to work.

```
Windows 365 Link does not support Autopilot or Autopilot device preparation in any form —
no Autopilot enrollment, no onboarding configuration, no Autopilot-specific device actions.
The only supported enrollment path is Entra join + automatic Intune enrollment at OOBE
(see Fix 1/Fix 2). Remove any Autopilot profile assignment targeting Link devices — it will
never apply and may cause confusing partial-state reporting in the Autopilot deployment blade.
```

**Rollback:** N/A — removing an inapplicable assignment, not a destructive change.

</details>

<details><summary>Fix 7 — Device in Disconnected Standby</summary>

**When:** A Wipe, Sync, Restart, or other remote device action appears stuck or is taking far longer than expected.

```
When Windows 365 Link is asleep, it is also in disconnected standby — it does not check in
with Intune and does not respond to remote device actions while in this state. This is not
a fault. Wake the device with any of:
  - Press the power button
  - Move the mouse
  - Press several keys on the keyboard
Then retry the remote action or wait for the next natural check-in.
```

**Rollback:** N/A — no action taken, diagnostic clarification only.

</details>

<details><summary>Fix 8 — Wipe/Reset/Recovery Decision Tree</summary>

**When:** A device needs to be returned to factory defaults (performance issues, repurposing) or can't boot / has no working in-OS reset option.

```
Pick based on device state and access:

1. Device is healthy, remotely reachable, admin-initiated:
   → Intune Wipe remote device action

2. Device is healthy, end-user-initiated, has physical access:
   → Company Portal app > Reset device

3. Device boots but is unstable / needs an in-OS recovery path:
   → Windows Recovery Environment (WinRE) Reset — requires the device's BitLocker
     recovery key (Entra ID self-recovery). WinRE also auto-triggers on:
       - 2 consecutive failed boot attempts
       - 2 consecutive unexpected shutdowns within 2 min of boot completion
       - 2 consecutive reboots within 2 min of boot completion
       - A Secure Boot error (except Bootmgr.efi issues)

4. Device cannot boot at all, or remote/in-OS options are unavailable, and you have
   physical access:
   → Bare Metal Recovery (BMR) — requires a USB drive and the language-matched Windows 365
     Link BMR recovery image (download from Microsoft, build a USB recovery drive per the
     Surface USB-recovery-drive process, leave "Back up system files to the recovery drive"
     UNCHECKED, then boot into WinRE > Advanced options > Use a device > USB Storage and
     follow the reimage prompts). After completion the device restarts into OOBE and can be
     reprovisioned through standard Windows 365/Intune workflows.
```

**Rollback:** N/A for options 1–3 (standard supported reset paths). BMR (option 4) is
destructive and irreversible by nature — confirm no other option applies first, since it
requires physical access and a recovery window.

</details>

<details><summary>Fix 9 — Restricted Network Onboarding</summary>

**When:** Deploying Link devices into a network that restricts by MAC address, requires certificate-based authentication, or otherwise can't be treated as an open/unrestricted network.

```
Windows 365 Link sends no user data over the local network — the only traffic is the
encrypted RDP session to the Cloud PC and Teams/calling media offload. Microsoft's own
recommendation is an open, internet-only network (like a guest network) with security
enforced at the Cloud PC VM (MFA, Conditional Access, compliance), not the endpoint.

If a fully open network isn't possible:

1. Stand up an "enrollment network" with fewer restrictions (e.g., a build room) that has
   access to the required Windows 365 Link connection endpoints — captive portal is supported
   during OOBE if needed.
2. For MAC-restricted production networks: the MAC address CANNOT be read from the device
   itself — enroll via the enrollment network first, then pull it from Intune:
```
```powershell
Get-MgDeviceManagementManagedDevice -Filter "model eq 'Windows 365 Link'" |
    ForEach-Object { Get-MgDeviceManagementManagedDevice -ManagedDeviceId $_.Id } |
    Select-Object DeviceName, SerialNumber, EthernetMACaddress, WifiMacaddress
```
```
   Then allowlist the returned MAC address(es) in your network infrastructure before moving
   the device to the production network.

3. For certificate-based authentication: enroll on the enrollment network, push device
   certificates (NOT user certificates — Link is a shared device) via Intune policy, confirm
   installation, then move the device to the restricted production network.
```

**Rollback:** N/A — network onboarding sequencing, not a destructive change.

</details>

---
## Escalation Evidence

Copy this template, fill in all fields, attach to ticket before escalating.

```
=== WINDOWS 365 LINK ESCALATION EVIDENCE PACK ===
Date/Time (UTC): _______________
Reported by: _______________
Affected device serial number: _______________
Affected user (UPN): _______________
Tenant ID: _______________

SYMPTOM:
[ ] Device never enrolled in Intune
[ ] Entra join blocked/failed
[ ] SSO not supported error on connect
[ ] SSO consent prompt loop
[ ] App/script/scan action misreported as failing (feature doesn't apply to Link)
[ ] Autopilot assignment/attempt
[ ] Device unresponsive to remote actions
[ ] Wipe/reset/recovery needed
[ ] Restricted network onboarding
[ ] Other: _______________

TRIAGE RESULTS:
Device ComplianceState: _______________
Device ManagementState: _______________
Provisioning policy SSO status: _______________
Joining user Entra ID P1 present (Y/N): _______________
Firmware/OS build (Settings > Device information): _______________
LastSyncDateTime: _______________

ACTIONS TAKEN:
_______________

To open a Microsoft support case directly:
Intune admin center > Troubleshooting + Support > Help and Support > Windows 365 >
Windows 365 Link > describe the issue > Contact Support

CORRELATION ID / Request ID: _______________
```

---
## 🎓 Learning Pointers

- **Link is a hardware device with its own management surface, not a Windows PC with a client installed** — it runs a minimal, purpose-built OS (Windows CPC), and most standard Intune endpoint features (app management, malware scanning, remediation scripts, Autopilot) are explicitly excluded by design, not misconfigured. Reference: [Manage Windows 365 Link devices with Microsoft Intune](https://learn.microsoft.com/en-us/windows-365/link/device-management-overview)
- **SSO is not optional — it's the only connection mode Link supports.** A Cloud PC without Entra ID SSO enabled on its provisioning policy is completely unreachable from a Link device, with an explicit on-device error. Don't waste time on client-side troubleshooting before confirming this policy setting. Reference: [Requirements for Windows 365 Link](https://learn.microsoft.com/en-us/windows-365/link/requirements)
- **Automatic enrollment is the only enrollment path — there's no bulk-provisioning or Autopilot alternative.** Both the Entra join permission and the Intune MDM user scope must independently permit the joining user, and that user needs an Entra ID P1-equivalent license, or the device silently never reaches Intune. Reference: [Automatically enroll Windows 365 Link in Intune](https://learn.microsoft.com/en-us/windows-365/link/intune-automatic-enrollment)
- **Sleep = disconnected standby.** A Link device that looks unresponsive to remote actions is very often just asleep, not broken — it doesn't check in with Intune in that state at all. Wake it before escalating. Reference: [Device management overview for Windows 365 Link](https://learn.microsoft.com/en-us/windows-365/link/device-management-overview)
- **Security posture is intentionally non-configurable** — BitLocker, Secure Boot, and Code Integrity are on by default and cannot be turned off, which is also why "Device health" is the *only* compliance setting that applies to Link. Don't build a broader compliance policy expecting more granularity than that. Reference: [Windows 365 Link security](https://learn.microsoft.com/en-us/windows-365/link/security-overview)
- **Four different reset/recovery paths exist and they are not interchangeable** — Intune Wipe and Company Portal Reset are the routine options; WinRE Reset needs the BitLocker recovery key; Bare Metal Recovery (added March 2026) is the only option when the device won't boot at all and requires physical access plus a USB recovery image. Reference: [Wipe or reset Windows 365 Link device](https://learn.microsoft.com/en-us/windows-365/link/wipe-reset-windows-365-link)
