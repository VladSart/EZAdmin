# Windows 365 Link — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps (by phase)](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This runbook covers **Windows 365 Link** — Microsoft's first purpose-built **hardware device** for connecting to a Windows 365 Cloud PC. Link is not a Windows PC in the conventional sense: it's a small (120mm × 120mm × 30mm, 418g), full-stack appliance running a minimal, purpose-built OS called **Windows CPC**, whose only job is to authenticate the user against Entra ID and stream their Cloud PC session. General availability was reached March 31, 2025.

This file covers only what is **Link-specific**: the hardware/OS architecture, the mandatory Entra join + automatic-enrollment onboarding model, the reduced (and largely non-configurable) Intune management surface, connectivity/SSO requirements, update behavior, network deployment models, and service/repair/recovery options. It assumes familiarity with `Windows365-A.md` (the Enterprise/Business Cloud PC provisioning model Link ultimately connects to) and does not re-cover Cloud PC provisioning, licensing SKUs, or ANC — Link is a **client device**, not a licensing model or a Cloud PC type; it connects to Cloud PCs provisioned under Enterprise, Business, or Flex, all covered elsewhere in this folder.

**Assumes:**
- Microsoft Graph PowerShell SDK (`Microsoft.Graph` / `Microsoft.Graph.Beta`): `Install-Module Microsoft.Graph.Beta -Scope CurrentUser`
- Authenticated with `Connect-MgGraph` and `DeviceManagementManagedDevices.Read.All`, `DeviceManagementConfiguration.Read.All`, `Directory.Read.All` scopes as a minimum
- Tenant has at least one Windows 365 (Enterprise, Business, or Flex) license and provisioning policy already configured — Link connects to an *existing* Cloud PC, it does not provision one

**Not covered:** Windows 365 Cloud PC provisioning/licensing mechanics (`Windows365-A.md`), Flex pooled licensing (`Flex-A.md`), Windows 365 Reserve (`Reserve-A.md` — note Link is fully compatible with both Reserve and Windows 365 Boot), Windows 365 Cloud Apps (`CloudApps-A.md`), or general Azure Virtual Desktop end-user-device networking beyond what Link inherits directly.

---
## How It Works

<details><summary>Full architecture</summary>

### What Link actually is

Windows 365 Link is a **full-stack, purpose-built hardware device** manufactured by Microsoft — not a repurposed thin client or a software-only client running on arbitrary hardware. When a user signs in, they are connected directly to their Windows 365 Cloud PC virtual machine through the Windows 365 service. The device itself stores no user data, runs no local applications, and has no local user accounts with administrative rights. Everything the user experiences — files, apps, settings — lives entirely in the Cloud PC VM.

### Windows CPC: a deliberately minimal OS

Link runs **Windows CPC**, a small, purpose-built Windows-based operating system that includes only the components needed to securely authenticate against Entra ID and connect to Windows 365. This is the architectural reason so many familiar Intune features (app management, malware scanning, remediation scripts, Autopilot) don't apply — they have nothing to act on, or are explicitly disabled to keep the attack surface minimal. Because the OS is this constrained, Microsoft's own documentation notes there are *"fewer configuration decisions and management actions needed"* compared to managing a normal Windows endpoint.

### Secure by design (non-configurable)

The following are **on by default and cannot be disabled**:
- Discrete Trusted Platform Module (TPM) 2.0 — hardware root of trust
- UEFI Secure Boot
- Virtualization-based Security (VBS) and Hypervisor-protected Code Integrity (HVCI)
- BitLocker drive encryption (enabled during setup)
- Strict, non-modifiable Application Control (code integrity) policy — only software required for the solution can execute
- No local user with administrative rights; no local apps; no local data storage
- Security baseline policies applied by default
- Microsoft Defender EDR sensor (note: the Malware scanning *component* — Quick/Full scan, signature updates — is explicitly absent, see Dependency Stack)

Because BitLocker, Secure Boot, and Code Integrity can never be turned off, they collapse into a single non-negotiable compliance signal — see Intune management model below.

### Onboarding: Entra join + automatic enrollment, and nothing else

At first power-on, the Out of Box Experience (OOBE) prompts the user to sign in and joins the device to their tenant. This is the **only** onboarding path — there is no bulk-provisioning, no manual/legacy MDM enrollment, and critically **no Autopilot support of any kind** (not standard Autopilot, not Autopilot device preparation, not Autopilot-specific device actions like Autopilot Reset). Two independent tenant settings gate this, both of which must permit the specific joining user:
1. **Entra Device Settings** → "Users may join devices to Microsoft Entra" (All / Selected)
2. **Entra Mobility (MDM and WIP) settings** → "MDM user scope" for Microsoft Intune (All / Some)

Automatic enrollment additionally requires the joining user to hold a **Microsoft Entra ID P1** (or bundling) license — without it, the device joins Entra but never becomes Intune-managed. There is no error surfaced to the user explaining this; it manifests only as the device never appearing in the Intune console.

### The Intune management model: intentionally shallow

Once enrolled, Link is managed through Intune "alongside other devices," but the *surface area* of what can be managed is deliberately small:

- **Compliance policy**: the only applicable setting is **Device health**, covering BitLocker, Secure Boot, and Code Integrity — all three already on by default and non-configurable. There is nothing else to build a compliance policy around for these devices.
- **App management**: does not apply — Link runs no local apps. If an app configuration policy targets a Link device anyway, Intune reports a perpetual **Pending install** state (not a fault, just an inapplicable policy that was never excluded).
- **Malware scanning**: the Windows Defender Malware *component* doesn't run on Link at all (only the EDR sensor does). Quick scan, Full scan, and Update Windows Defender security intelligence device actions all fail with **"Initiating (action) failed"** if attempted — expected, not a bug.
- **Device scripts and remediations**: blocked entirely by the non-modifiable strict Application Control policy — remediation packages never execute and never appear in scripts-and-remediation status reports for these devices.
- **Configuration Service Providers (CSPs)**: only a defined subset of CSP policies apply to Link — consult the dedicated CSP-support reference rather than assuming parity with a full Windows 11 endpoint.
- **Device filters**: Intune device filters can identify Link devices by the Windows CPC OS / `Model eq 'Windows 365 Link'`, and are the standard mechanism for *excluding* Link from policies designed for full Windows endpoints.
- **Remote device actions**: while asleep, Link is in **disconnected standby** — it does not check in with Intune and does not respond to remote actions in that state. Waking it (power button, mouse movement, keyboard input) is the fix for an apparently "stuck" remote action, not a support ticket.

### Connectivity: SSO is mandatory, not optional

Link can **only** connect to Windows 365 Cloud PCs that have **Entra ID single sign-on (SSO)** enabled on their provisioning policy. If SSO isn't enabled, the user gets an explicit error that their Cloud PC doesn't support Entra ID SSO and simply cannot connect — there is no fallback authentication path (no password-only, no non-SSO RDP). This is a deliberate password-less design: FIDO2 security key and web sign-in are the only credential providers available on the device itself.

A related, genuinely disruptive gotcha: users are prompted for **SSO consent** on first connection after SSO is enabled, and again every 30 days or after a Cloud PC is reprovisioned — but Link's connection UI **cannot** interact with a consent-prompt dialog, so an un-suppressed consent requirement causes a hard connection failure requiring the user to first consent from another device or browser. Microsoft's December 2025 Quality Update (build 26100.7462) added Web Account Manager (WAM) interactive support, allowing consent prompts to be handled directly on-device when they do appear — but proactively suppressing the prompt via SSO service-principal configuration remains the recommended baseline regardless of build (see Remediation Playbook 4).

### Update behavior

Link updates automatically through the same Windows Update Services infrastructure as Windows 11 — there is no separate update channel to manage. When an update is detected on a powered-on device, it downloads silently and installs at the next reboot or at 3 AM if the device is idle. Driver/firmware updates apply separately from OS updates but combine into a single reboot if both are pending simultaneously. The only administrative lever is the `AllowAutoUpdate` CSP node (values **4** = on, **5** = off; values 0–3 are technically enumerated but explicitly unsupported for Link — don't use them).

### Network architecture and restricted-network deployment

The only network traffic a Link device generates is the **encrypted RDP session** to the Cloud PC and **media traffic offloaded** from Teams (or similar calling apps) for local redirection. No user data, files, or app traffic ever traverses the local network — everything lives in the Cloud PC VM. Microsoft's explicit recommendation is to treat Link like a guest/unrestricted-internet-only device and enforce security (MFA, Conditional Access, device compliance) at the **Cloud PC VM**, not the endpoint — proxying or DLP-inspecting the Link device itself is generally the wrong layer.

For environments that can't offer an open network:
- Stand up a less-restricted **enrollment network** (e.g., a build room) with access to the required connection endpoints, join/enroll the device there, then move it to production.
- **MAC-restricted networks**: the device's MAC address cannot be read from the device itself at all — it must be pulled from Intune's Hardware inventory (or in bulk via Graph) after enrollment on the enrollment network, then allowlisted.
- **Certificate-based authentication**: requires **device** certificates, not user certificates (Link is architecturally a shared device even when used by one person) — pushed via Intune policy while still on the enrollment network, before the device moves to the restricted production network.
- Captive-portal Wi-Fi is supported at the sign-in screen for initial connectivity.

### Recovery, service, and repair

Four distinct paths return a Link device to factory defaults, and they are **not interchangeable** — matching the right one to the device's actual state matters:
1. **Intune Wipe** remote device action — admin-initiated, remote.
2. **Company Portal Reset** — end-user-initiated, requires physical/logged-in access.
3. **Windows Recovery Environment (WinRE) Reset** — requires the device's BitLocker recovery key; auto-triggers after 2 consecutive failed boots, 2 consecutive unexpected shutdowns within 2 minutes of boot, 2 consecutive reboots within 2 minutes of boot, or a Secure Boot error (excluding Bootmgr.efi issues).
4. **Bare Metal Recovery (BMR)** — added March 2026; the only option when the device won't boot and remote/in-OS paths are unavailable. Requires physical access, a USB drive, and a language-matched recovery image downloaded from Microsoft; reimages the device from external media via WinRE's "Use a device" path.

Hardware service is available directly from Microsoft or through a third-party **Windows 365 Link Authorized Service Provider**, opened as a support case from the Intune admin center. Genuinely notable for an appliance-class device: Microsoft explicitly supports **customer self-repair** — no certification is required, replacement components (motherboard module, top enclosure, bottom-plate screw covers) are purchasable through resellers, and self-repair does **not** void Microsoft's Limited Warranty (though damage caused by a non-Microsoft/non-Authorized-Provider repair is not covered). A full multilingual Service Guide PDF is published for this purpose.

### Government cloud and licensing

Windows 365 Link works with Windows 365 Enterprise, Windows 365 Flex, and Windows 365 Business, and **requires Intune** in all cases. As of the May 2026 Quality Update, Link supports connectivity to Windows 365 Government Cloud PCs in GCC and GCCH environments (and Enterprise/Flex for FedRAMP GCC) — confirm current-tenant build level before promising this to a sovereign-cloud client, since it's a comparatively recent addition. Link is fully **compatible** with both **Windows 365 Reserve** and **Windows 365 Boot** (the local-device-boots-directly-into-Cloud-PC feature) — see `Reserve-A.md` for Reserve's own eligibility model.

</details>

---
## Dependency Stack

```
Physical Windows 365 Link device (Windows CPC OS)
  └── Out of Box Experience (OOBE) — first power-on, only onboarding path (no Autopilot, no bulk provisioning)
        └── Microsoft Entra join
              ├── Entra ID > Devices > Device Settings > "Users may join devices" (All/Selected — must include user)
              └── Max devices per user not exceeded (default 50, applies even to DEMs)
                    └── Automatic Intune enrollment (the ONLY enrollment path)
                          ├── Entra ID > Mobility (MDM and WIP) > MDM user scope = All/Some (must include user)
                          ├── Joining user holds Microsoft Entra ID P1 (or bundle) license
                          └── Not blocked by Intune enrollment restrictions
                                └── Intune management (narrow surface — Windows CPC OS)
                                      ├── Compliance: Device health ONLY (BitLocker/Secure Boot/Code Integrity —
                                      │     on by default, non-configurable)
                                      ├── App management — N/A (no local apps; exclude via device filter)
                                      ├── Malware scan device actions — N/A (EDR sensor only, no scan component)
                                      ├── Remediation scripts — N/A (blocked by strict Application Control)
                                      └── CSP support — partial subset only (see CSP-support reference)
                                            └── Connection to a Windows 365 Cloud PC
                                                  ├── Provisioning policy has Entra ID SSO enabled (MANDATORY —
                                                  │     no non-SSO fallback exists)
                                                  ├── SSO consent granted (first connect / every 30 days / after
                                                  │     reprovision) — suppress via service-principal config, or
                                                  │     handle on-device if build ≥ 26100.7462 (WAM interactive)
                                                  └── Conditional Access policies satisfied (device + SSO cloud app
                                                        resource must both be in scope)
                                                        └── Cloud PC VM (provisioned under Enterprise/Business/Flex —
                                                              see Windows365-A.md / Flex-A.md)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Device joins Entra but never appears in Intune | MDM user scope not set to All/Some for this user, or user lacks Entra ID P1 license | Entra Mobility (MDM and WIP) settings; `Get-MgUserLicenseDetail` |
| Device fails/loops at OOBE sign-in before joining Entra | "Users may join devices" doesn't permit this user, or max-devices-per-user cap hit | Entra ID > Devices > Device Settings |
| "Your Cloud PC doesn't support Entra ID single sign-on" error | Target Cloud PC's provisioning policy doesn't have SSO enabled | `Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy` → `MicrosoftEntraSingleSignOnStatus` |
| Connection fails on first SSO connect, or recurs ~every 30 days, or after reprovisioning | SSO consent prompt required but Link's UI can't render it (pre-suppression / pre-WAM-interactive build) | Confirm suppression config; confirm firmware build vs. 26100.7462 |
| App configuration policy stuck "Pending install" indefinitely | App management doesn't apply to Link — policy was never excluded | Confirm target device Model; add device filter exclusion |
| "Initiating (action) failed" on Quick scan / Full scan / Update Defender intelligence | Malware scanning component doesn't run on Link at all | Confirm target device Model before treating as a fault |
| Remediation script never shows in device status reports | Blocked entirely by Link's non-modifiable Application Control policy | Confirm target device Model; not a deployment failure |
| Autopilot profile assigned to a Link device shows odd/partial status | Autopilot (any form) is not supported for Link at all | Remove the assignment; use standard OOBE Entra join instead |
| Remote action (Wipe/Sync/Restart) appears stuck, stale `LastSyncDateTime` | Device is asleep — disconnected standby doesn't check in or respond to remote actions | Wake device (power/mouse/keyboard), retry |
| Device won't boot, no in-OS reset option available | Needs Bare Metal Recovery — requires physical access + USB image | Confirm no lesser recovery option (Wipe/Company Portal/WinRE) applies first |
| WinRE Reset requested but blocked | Missing the device's BitLocker recovery key | Entra ID self-recovery portal for the device's BitLocker key |
| MAC-restricted network deployment can't get the device's MAC address | MAC cannot be read from the device directly — must come from Intune inventory | `Get-MgDeviceManagementManagedDevice` hardware properties (post-enrollment) |
| Certificate-based Wi-Fi auth fails after moving to production network | User certificate deployed instead of device certificate (Link is a shared-device model) | Confirm cert deployment targets device, not user |
| Disk space reporting looks unavailable for a Link device | Feature added May 2026 QU — confirm build level and check Hardware > Storage in device details, not a generic report | Device build/version; Intune device Hardware blade |
| GCC/GCCH customer reports Link can't reach a Government Cloud PC | Government Cloud connectivity only added as of the May 2026 Quality Update | Confirm device firmware/OS build level |
| Update won't apply / pause doesn't take effect | Wrong `AllowAutoUpdate` CSP value used (only 4/on and 5/off are valid for Link) | Confirm CSP value isn't 0–3 (unsupported) |

---
## Validation Steps

**1. Confirm Graph connection and scopes**
```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All","DeviceManagementConfiguration.Read.All","Directory.Read.All"
Get-MgContext | Select-Object Scopes
```
Expected: All three scopes present.

**2. Inventory all Windows 365 Link devices in the tenant**
```powershell
Get-MgDeviceManagementManagedDevice -Filter "model eq 'Windows 365 Link'" |
    Select-Object DeviceName, SerialNumber, ComplianceState, ManagementState, EnrolledDateTime
```
Expected: One row per physical Link device. `ComplianceState` should be `compliant` — remember this reflects Device health only.

**3. Confirm which provisioning policies have SSO enabled (the hard connectivity gate)**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy |
    Select-Object DisplayName, Id, MicrosoftEntraSingleSignOnStatus
```
Expected: Every policy backing a Cloud PC that Link users connect to shows `enabled`. Any policy showing disabled is a guaranteed Link connectivity failure for its users.

**4. Confirm the Entra join and MDM scope settings (portal-only, no direct Graph read commonly used for these tenant-wide toggles)**
```
Entra admin center > Identity > Devices > Overview > Device Settings
Entra admin center > Show more > Settings > Mobility (MDM and WIP) > Microsoft Intune
```
Expected: Both permit the relevant user population.

**5. Confirm a specific user's Entra ID P1 license (enrollment prerequisite)**
```powershell
Get-MgUserLicenseDetail -UserId "<user@domain.com>" | Select-Object SkuPartNumber, ServicePlans
```
Expected: An Entra ID P1-equivalent service plan present.

**6. Pull hardware inventory (MAC addresses, serial) for a specific device or in bulk**
```powershell
Get-MgDeviceManagementManagedDevice -Filter "model eq 'Windows 365 Link'" |
    ForEach-Object { Get-MgDeviceManagementManagedDevice -ManagedDeviceId $_.Id } |
    Select-Object DeviceName, SerialNumber, EthernetMACaddress, WifiMacaddress
```
Expected: Populated values post-enrollment — remember these cannot be obtained any other way for Link.

**7. Confirm compliance policy scope doesn't over-assume feature parity with full Windows endpoints**
```powershell
Get-MgDeviceCompliancePolicy | Select-Object DisplayName, Id
```
Expected: Any compliance policy targeting Link devices should reduce cleanly to Device health — additional settings (e.g., antivirus status, password policy) will simply not evaluate meaningfully against Windows CPC.

---
## Troubleshooting Steps (by phase)

### Phase 1: Join & Enrollment
1. Confirm Entra join succeeded (device visible under Entra ID > Devices) before troubleshooting anything downstream
2. Confirm MDM user scope includes the joining user, and that user holds an Entra ID P1 license
3. Confirm no Intune enrollment restriction is blocking the device/user combination
4. If joined but not enrolled, have the user re-run OOBE (disconnect work/school account, power-cycle) after correcting scope/licensing

### Phase 2: Connectivity & SSO
1. Identify the target Cloud PC's backing provisioning policy and confirm SSO is enabled — this blocks 100% of connections when missing, with no partial-functionality fallback
2. If SSO is enabled but connection still fails, suspect the consent-prompt gap — check firmware build against 26100.7462 and whether consent suppression (Playbook 4) is configured
3. Confirm Conditional Access policies targeting Cloud PC resources also include the SSO cloud app in scope, not just the Windows 365 app

### Phase 3: Management-Model Misdiagnosis
1. Before treating any app/scan/remediation failure as a bug, confirm the target device's Model is `Windows 365 Link` — a large share of "broken" tickets against Link devices are actually inapplicable-feature reports
2. Build (or confirm the existence of) a standing Intune device filter excluding Link from policies designed for full Windows endpoints
3. If a remote action looks stuck, rule out disconnected standby before escalating

### Phase 4: Recovery & Physical Service
1. Match the reported symptom to the correct reset tier (Wipe → Company Portal → WinRE → BMR) rather than defaulting to the most drastic option
2. For WinRE, retrieve the BitLocker recovery key via Entra ID self-recovery before attempting the reset
3. For BMR, confirm physical access and download the correct language-matched image before starting — this path is destructive and requires a recovery window
4. For hardware faults, determine self-repair eligibility (no certification required) vs. Authorized Service Provider/Microsoft service based on the specific component and client risk tolerance

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield Windows 365 Link Deployment</summary>

Use when: standing up Link support in a tenant for the first time.

```
1. Confirm all requirements are met: Windows 365 Enterprise/Flex/Business license + Intune
   for target users, Entra ID P1 for automatic enrollment
2. Entra admin center > Identity > Devices > Device Settings > permit target users/groups to
   join devices to Microsoft Entra
3. Entra admin center > Mobility (MDM and WIP) > set MDM user scope to Microsoft Intune for
   the same target users/groups
4. (Optional) Intune admin center > Devices > Filters > create a filter for
   Model eq "Windows 365 Link" — use this to exclude Link from app/script policies built for
   full Windows endpoints
5. Intune admin center > Devices > Enrollment restrictions > confirm target users aren't
   blocked from enrolling
6. Confirm Conditional Access policies targeting Windows 365/Cloud PC resources also include
   the SSO cloud app resource in scope
7. Onboard devices via standard OOBE (no Autopilot)

Strongly recommended day-one configurations:
  - Auto Detect Local Time Zone policy
  - FIDO2 Security Key as a sign-in method (Link is designed to be password-less)
  - Modify Screen Timeout (optional, based on client physical-security posture)
```

**Rollback:** N/A — initial deployment configuration.

</details>

<details><summary>Playbook 2 — Restricted Network Deployment</summary>

Use when: Link devices must be deployed into a network that can't be treated as open/guest-like (MAC filtering, certificate-based auth, or general internal-network restriction policy).

```
1. Stand up a lower-restriction "enrollment network" (e.g., build room) with access to the
   required Windows 365 Link connection endpoints; captive portal is supported if needed
2. Join + enroll the device on the enrollment network first — this is a hard prerequisite,
   not an optimization, since MAC address and certificate provisioning both depend on it
3. If MAC-filtering the production network:
```
```powershell
   Get-MgDeviceManagementManagedDevice -Filter "model eq 'Windows 365 Link'" |
       ForEach-Object { Get-MgDeviceManagementManagedDevice -ManagedDeviceId $_.Id } |
       Select-Object DeviceName, SerialNumber, EthernetMACaddress, WifiMacaddress |
       Export-Csv "LinkDeviceMACs.csv" -NoTypeInformation
```
```
   Allowlist the exported MAC address(es) in network infrastructure.

4. If certificate-based Wi-Fi/network auth is required: deploy DEVICE certificates (not user
   certificates — Link is architecturally a shared device) via Intune policy while still on
   the enrollment network; confirm successful installation before proceeding
5. Move the device to the restricted production network only after steps 3/4 are confirmed
6. Document this sequencing for the client — attempting to skip the enrollment-network step
   for a restricted target network is the single most common Link deployment failure mode
```

**Rollback:** N/A — deployment sequencing guidance, not a destructive action.

</details>

<details><summary>Playbook 3 — Bare Metal Recovery (Non-Booting Device)</summary>

Use when: a Link device cannot boot and neither remote (Intune Wipe) nor in-OS (Company Portal, WinRE) recovery options are reachable.

```
Prerequisites: physical access to the device, a USB drive with sufficient capacity, and the
correct language-matched Windows 365 Link BMR recovery image.

1. Download and extract the BMR image matching the required display language(s) —
   three language-set packages exist; pick whichever includes the needed language
2. Follow the Surface "Create and use a USB recovery drive" process to build the USB
   recovery drive — leave "Back up system files to the recovery drive" UNCHECKED
3. Boot the device into WinRE:
     Advanced options > Use a device > USB Storage
   The device restarts and prompts for keyboard layout
4. Select "Recover from a drive"
5. Skip the BitLocker recovery key prompt for the device (not needed for this path)
6. Choose "Just remove my files" or "Fully clean the drive" based on the situation (data
   sensitivity, whether the device is being repurposed/transferred to another owner)
7. After completion, the device restarts into OOBE and can be reprovisioned through the
   standard Windows 365/Intune enrollment workflow (Playbook 1)
```

**Rollback:** None — BMR is destructive and irreversible by design. Confirm this is genuinely
the last-resort option (device truly won't boot, no remote/in-OS path works) before starting,
and communicate downtime expectations to the client given the physical-access requirement.

</details>

<details><summary>Playbook 4 — Suppress SSO Consent Prompts Tenant-Wide</summary>

Use when: proactively preventing the SSO consent-prompt connection failure (Fix 4 in
`Link-B.md`) across all Link-connected Cloud PCs, rather than handling it reactively per user.

```
1. Create a dynamic device group scoped to all Cloud PCs (see Windows365-A.md /
   Azure Virtual Desktop dynamic-group guidance for the query pattern)
2. Enable Microsoft Entra authentication for RDP on the SSO service principal
   (Azure portal > Microsoft Entra ID > Enterprise applications > locate the SSO service
   principal for Windows 365 / Azure Virtual Desktop > configure the RDP authentication
   property)
3. Add the Cloud PC device group as the target for that service principal, which hides the
   consent-prompt dialog for connections from devices in scope
4. Validate with a test user connecting from a Link device — confirm no consent prompt
   appears on first connect to a newly-SSO-enabled Cloud PC

Note: this remains best practice even on devices running build 26100.7462+ (which added
on-device Web Account Manager interactive consent support) — suppression avoids the
interruption entirely rather than relying on the user successfully completing an on-device
consent flow.
```

**Rollback:** Remove the Cloud PC device group from the service principal's target to restore
default consent-prompt behavior. Non-destructive to any Cloud PC or device state either way.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Windows 365 Link diagnostic evidence for a specific device or tenant-wide
.NOTES     Requires Microsoft.Graph.Beta module and DeviceManagementManagedDevices.Read.All,
           DeviceManagementConfiguration.Read.All scopes
#>

param(
    [string]$SerialNumber
)

$outputPath = "C:\W365Link_Diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

$devices = Get-MgDeviceManagementManagedDevice -Filter "model eq 'Windows 365 Link'"
if ($SerialNumber) {
    $devices = $devices | Where-Object { $_.SerialNumber -eq $SerialNumber }
}

$devices | Select-Object DeviceName, SerialNumber, ComplianceState, ManagementState,
    EnrolledDateTime, LastSyncDateTime |
    Export-Csv "$outputPath\link_devices.csv" -NoTypeInformation

$hardwareDetail = foreach ($d in $devices) {
    Get-MgDeviceManagementManagedDevice -ManagedDeviceId $d.Id |
        Select-Object DeviceName, SerialNumber, EthernetMACaddress, WifiMacaddress
}
$hardwareDetail | Export-Csv "$outputPath\link_hardware_detail.csv" -NoTypeInformation

Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy |
    Select-Object DisplayName, Id, MicrosoftEntraSingleSignOnStatus |
    Export-Csv "$outputPath\provisioning_policy_sso_status.csv" -NoTypeInformation

Write-Host "NOTE: Entra Device Settings, MDM user scope, sign-in log detail (interactive/" -ForegroundColor Yellow
Write-Host "non-interactive), and SSO consent-suppression service-principal configuration are" -ForegroundColor Yellow
Write-Host "portal-only surfaces as of this writing — pull those manually and attach alongside" -ForegroundColor Yellow
Write-Host "this evidence pack." -ForegroundColor Yellow

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# Inventory all Link devices in the tenant
Get-MgDeviceManagementManagedDevice -Filter "model eq 'Windows 365 Link'" |
    Select DeviceName,SerialNumber,ComplianceState,ManagementState

# Full hardware detail (MAC addresses) for a specific device — cannot be read from the device itself
Get-MgDeviceManagementManagedDevice -ManagedDeviceId "<device-id>" |
    Select DeviceName,SerialNumber,EthernetMACaddress,WifiMacaddress

# Confirm SSO status across all provisioning policies (hard connectivity gate)
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy |
    Select DisplayName,Id,MicrosoftEntraSingleSignOnStatus

# Confirm a user's Entra ID P1 license (automatic-enrollment prerequisite)
Get-MgUserLicenseDetail -UserId "<user@domain.com>" | Select SkuPartNumber,ServicePlans

# Confirm last check-in (rule out disconnected standby before treating a remote action as stuck)
Get-MgDeviceManagementManagedDevice -Filter "model eq 'Windows 365 Link'" |
    Select DeviceName,LastSyncDateTime

# Remote Wipe (destructive — factory reset)
Invoke-MgWipeDeviceManagementManagedDevice -ManagedDeviceId "<device-id>"

# Confirm compliance policies aren't over-scoped for Link's narrow (Device health only) surface
Get-MgDeviceCompliancePolicy | Select DisplayName,Id

# NOT supported for Link — do not attempt, confirm Model first:
#   Any Autopilot profile assignment or Autopilot Reset action
#   Quick scan / Full scan / Update Windows Defender security intelligence device actions
#   App configuration/installation policies (will report perpetual Pending install)
#   Device remediation script packages (will never execute or report status)
```

---
## 🎓 Learning Pointers

- **Link's minimal Windows CPC OS is the root cause of its entire reduced management surface** — app management, malware scanning, and remediation scripts aren't missing due to a licensing gap or misconfiguration; they're architecturally absent because the OS has nothing for them to act on. Treat every "feature doesn't work" ticket against a Link device as a scope question first. Reference: [Manage Windows 365 Link devices with Microsoft Intune](https://learn.microsoft.com/en-us/windows-365/link/device-management-overview)
- **SSO is a hard, binary connectivity requirement, not a security enhancement layered on top of a working connection** — a Cloud PC without SSO enabled on its provisioning policy is completely unreachable from Link, full stop. Confirm this setting before any deeper connectivity troubleshooting. Reference: [Requirements for Windows 365 Link](https://learn.microsoft.com/en-us/windows-365/link/requirements)
- **Two independent tenant settings gate onboarding, and both are easy to half-configure** — Entra's "Users may join devices" and Intune's "MDM user scope" are separate toggles that must both include the same user population, or devices join Entra but silently never reach Intune. Reference: [Allow joining Windows 365 Link to Microsoft Entra](https://learn.microsoft.com/en-us/windows-365/link/join-microsoft-entra), [Automatically enroll Windows 365 Link in Intune](https://learn.microsoft.com/en-us/windows-365/link/intune-automatic-enrollment)
- **The SSO consent-prompt gap is a genuinely disruptive, easy-to-miss production issue** — because Link's connection UI can't render a consent dialog, an un-suppressed 30-day consent renewal (or first-connect requirement) causes a hard failure that looks like a broken device rather than an auth-flow limitation. Suppress it proactively via service-principal configuration rather than waiting for user reports. Reference: [Requirements for Windows 365 Link — Suppress SSO consent prompts](https://learn.microsoft.com/en-us/windows-365/link/requirements)
- **Four recovery tiers exist and picking the wrong one wastes a truck roll** — Intune Wipe and Company Portal Reset cover the routine cases; WinRE needs the BitLocker recovery key; Bare Metal Recovery (added March 2026) is the only path for a device that won't boot at all, and it requires physical access plus a downloaded, language-matched recovery image. Reference: [Wipe or reset Windows 365 Link device](https://learn.microsoft.com/en-us/windows-365/link/wipe-reset-windows-365-link)
- **Customer self-repair is explicitly supported and doesn't void warranty** — a genuinely unusual policy for an appliance-class managed endpoint; replacement components require no certification and are reseller-purchasable, which changes the cost/turnaround calculus for hardware-fault tickets versus defaulting straight to a Microsoft/Authorized-Provider service case. Reference: [Service and repair options for your Windows 365 Link](https://learn.microsoft.com/en-us/windows-365/link/service-repair)
