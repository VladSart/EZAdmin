# Samsung Knox E-FOTA Firmware Update Management — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

> **Source confidence:** built from a live fetch of Microsoft's own current Learn page [Integrate Samsung Knox E-FOTA with Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-updates/android/setup-samsung-knox) (`ms.date` 2026-07-24, `updated_at` 2026-07-25) and the "Week of August 25, 2026 (Service release 2608)" entry in [What's new in Microsoft Intune](https://learn.microsoft.com/en-us/intune/whats-new/). Current, GA how-to documentation — not flagged preview. Samsung-side Knox Admin Portal specifics referenced but not fully re-verified here belong to Samsung's own documentation (`docs.samsungknox.com`), linked inline where Microsoft's page defers to it.

---
## Skim Index (with jump links)
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

This runbook covers the Intune-side integration with Samsung Knox E-FOTA (Firmware Over-The-Air) for remotely managing firmware update campaigns on corporate-owned Samsung Android Enterprise devices. It does not cover Samsung Knox Admin Portal administration beyond what's needed to authorize the Intune connector, general Android Enterprise OS/security-patch compliance (a separate, unrelated Intune capability), or firmware management for non-Samsung Android OEMs (no equivalent Intune-native integration exists for other manufacturers as of this writing).

Applies to Android Enterprise corporate-owned fully managed (COBO), corporate-owned dedicated (COSU), and corporate-owned work profile (COPE) enrollments only. Assumes an Intune Administrator account for connector setup, a Samsung Knox administrator account, an active Samsung Knox E-FOTA license, at least Microsoft 365 E3, and Managed Google Play already configured for the tenant.

---
## How It Works

<details><summary>Full architecture</summary>

Samsung Knox E-FOTA is a Samsung-operated firmware distribution service; Intune does not host or control firmware itself. The Intune admin center integration is a management surface layered on top of Samsung's own service, connected via a tenant-level OAuth-style connector authorization.

The full chain, in order:

1. **Connector authorization.** An Intune Administrator initiates the connection (Tenant administration > Connectors and tokens > Firmware over-the-air update > Samsung), which redirects to the Samsung Knox Admin Portal for a Samsung Knox administrator to sign in and authorize. This establishes a tenant-to-tenant trust between the Intune tenant and the organization's Knox Admin Portal account — a genuinely separate identity system from Entra ID.

2. **App deployment via Managed Google Play.** Two apps must be pushed as Required: **Knox E-FOTA** (`com.samsung.android.knox.efota`), the client the end user interacts with to complete registration, and **Knox Service Plugin** (`com.samsung.android.knox.kpu`), which provides the underlying Knox platform hooks the E-FOTA client needs. Both are ordinary Managed Google Play apps from Intune's perspective — they follow standard Android Enterprise app deployment mechanics (assignment, install status, sync-driven delivery), not a special E-FOTA-specific channel.

3. **OEMConfig-based device policy.** A Samsung OEMConfig profile — not a Settings Catalog policy — carries three specific toggles: **Enable device policy controls**, **Enable firmware controls**, and **Enable E-FOTA client installation & launch**. OEMConfig is Samsung's (and other OEMs') standard mechanism for exposing manufacturer-specific management hooks through a single Android Enterprise-compliant app-config schema, rather than Microsoft building bespoke native settings for every OEM capability. This is why E-FOTA configuration lives under **Templates > OEMConfig** rather than the regular Android Enterprise settings catalog.

4. **Device-to-Samsung registration (sync + manual acceptance).** After the connector, apps, and OEMConfig policy are all in place, an admin explicitly adds the target security group(s) to the Samsung connector and selects **Register** — this uploads the device list to Samsung. However, upload alone does not complete registration: **the end user (or a provisioning technician) must open the Knox E-FOTA app on the device and accept terms and conditions.** This is a hard, undocumented-workaround requirement — there is no remote or API path to accept on the user's behalf. For unattended/kiosk (COSU) fleets, this means E-FOTA enrollment cannot be made fully zero-touch the way Autopilot/ADE profile assignment can; it must be built into a staging/provisioning checklist instead.

5. **Campaign creation and execution.** Once a device shows **Registered**, an admin creates an E-FOTA deployment ("campaign") specifying device model, sales code, and CSC (Consumer Software Customization — Samsung's carrier/region firmware variant code) plus the target firmware version, deployment schedule, installation schedule, and device condition gates (e.g., requiring charging or a specific network state before install). Samsung executes the actual firmware push; Intune's Monitor tab is a read-mostly summary that **refreshes hourly** from Samsung, not a live control-plane view.

6. **Status reporting.** Two separate hourly-refreshed views exist: the connector-level **device registration status report** (registration state per device) and the campaign-level **Monitor tab** (per-campaign rollout progress). Both are sourced from Samsung and are explicitly not real-time.

</details>

---
## Dependency Stack

```
Layer 5: Campaign execution (Samsung-side, hourly-refreshed status in Intune)
         Device model + sales code + CSC + firmware version targeting
         Deployment schedule / installation schedule / device condition gates
Layer 4: Device registration (requires END-USER or technician action —
         cannot be automated or completed via API/remote action)
         Knox E-FOTA app opened on-device, terms & conditions accepted
Layer 3: Security group added to Samsung connector + "Register" selected
         (uploads device list to Samsung — does NOT itself register the device)
Layer 2: OEMConfig profile (Templates > OEMConfig, NOT Settings Catalog)
         Enable device policy controls = true
         Enable firmware controls = true
         Enable E-FOTA client installation & launch = true
Layer 1: Required apps via Managed Google Play (standard Android Enterprise
         app deployment mechanics — assignment, sync, install status)
         Knox E-FOTA (com.samsung.android.knox.efota)
         Knox Service Plugin (com.samsung.android.knox.kpu)
Layer 0: Tenant prerequisites
         Samsung Knox E-FOTA license (Samsung-side purchase, independent of
         any Microsoft licensing)
         Microsoft 365 E3 minimum
         Managed Google Play configured
         Samsung connector authorized (Intune Administrator + separate
         Samsung Knox administrator credential)
         RBAC: Android FOTA / Mobile apps / Device configurations permissions
         Device platform: Android Enterprise COBO, COSU, or COPE only
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Device never appears in the Knox E-FOTA connector's device list at all | Device platform unsupported (device admin/BYOD), or the security group was never added to the connector | Confirm `ManagedDeviceOwnerType`/enrollment type; confirm connector's assigned groups |
| Apps show installed and OEMConfig applied, but device stuck at a non-Registered state indefinitely | End user never opened the Knox E-FOTA app to accept terms | Confirm via Company Portal messaging / remote view whether the app was launched |
| Campaign created but 0% progress after 24+ hours on registered devices | Device model/sales code/CSC mismatch against actual device hardware, or device excluded from campaign's assigned group | Compare campaign targeting criteria against device's real model/CSC in the Knox Admin Portal |
| Connector shows Connected in Intune but campaigns silently stop progressing | Samsung Knox administrator account authorizing the connector was disabled, had MFA reset, or its Knox Admin Portal role changed | Re-authorize the connector; verify the Knox administrator account's current state directly in the Knox Admin Portal |
| Newly-onboarded devices in a previously-working deployment aren't picking up required apps | Managed Google Play sync issue unrelated to E-FOTA specifically | Troubleshoot as a standard Managed Google Play/app deployment issue first |
| Status in Intune looks "wrong" or stale compared to what the end user reports on-device | Expected — all E-FOTA status data (registration report, campaign Monitor tab) refreshes hourly from Samsung, not live | Re-check after the next hourly refresh before escalating |

---
## Validation Steps

1. **Confirm platform eligibility before anything else.**
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<device-name>'" |
       Select-Object DeviceName, OperatingSystem, ManagedDeviceOwnerType
   ```
   Good: `ManagedDeviceOwnerType` = `company` on an Android Enterprise COBO/COSU/COPE enrollment. Bad: device administrator enrollment or a personally-owned work profile — E-FOTA is architecturally unavailable regardless of any further configuration.

2. **Confirm both required apps are installed, not merely assigned.**
   ```powershell
   Get-MgDeviceAppManagementMobileAppDeviceStatus -MobileAppId "<app-id>" |
       Where-Object { $_.DeviceName -eq "<device-name>" }
   ```
   Good: `installed`. Bad: `notInstalled`/`pendingInstall`/`failed` — troubleshoot as standard Managed Google Play app deployment before assuming an E-FOTA-specific fault.

3. **Confirm the OEMConfig profile reports Succeeded on the device with all three toggles enabled.**
   Good: policy status Succeeded, all three settings `true`. Bad: policy Pending/Error, or a toggle explicitly left `false` — the E-FOTA client cannot function without device policy controls and firmware controls both enabled.

4. **Cross-reference the connector's device registration status report.**
   Tenant administration > Connectors and tokens > Firmware over-the-air update > Samsung > Monitor tab. Good: `Registered`. Acceptable transient state: `Pending` within the first hour after the user accepts terms. Bad: device absent entirely — indicates the security group was never added to the connector, or Register was never run.

5. **For campaign-specific issues, validate targeting against the Knox Admin Portal's own device record**, since Samsung — not Intune — is authoritative for the device's actual model/sales code/CSC/current firmware.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Rule out platform ineligibility.** This is a hard architectural boundary, not a misconfiguration — device administrator and BYOD work-profile enrollments simply cannot use Knox E-FOTA. Confirm enrollment type before investing further troubleshooting time.

**Phase 2 — Separate "app/policy deployment failed" from "E-FOTA-specific failure."** The app and OEMConfig layers use entirely standard Android Enterprise deployment mechanics. A failure here should be triaged as a normal app/policy deployment problem (Managed Google Play sync, device connectivity, conflicting profiles) rather than assumed to be Knox E-FOTA-specific.

**Phase 3 — Isolate the manual-registration step as its own workstream.** Because device registration requires human action on-device with no remote/API completion path, a "stuck" registration is very often a process gap (nobody told the field technician to open the app during staging) rather than a technical fault. Treat this differently from Phases 1-2, which are purely technical.

**Phase 4 — For campaign-level issues, validate against Samsung's own source of truth.** Intune's targeting criteria (model/sales code/CSC) must match Samsung's records for the physical device. When in doubt, cross-check directly in the Knox Admin Portal rather than assuming Intune's copy of device metadata is current.

**Phase 5 — For connector-level instability, audit the Samsung Knox administrator account's standing independently of Intune.** Intune has no visibility into why a previously-working connector authorization silently degrades — the root cause almost always lives on the Samsung Knox Admin Portal side (account disabled, MFA reset, role change), which Intune tooling cannot query.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Initial rollout to a new fleet of corporate-owned Samsung devices</summary>

1. Confirm Knox E-FOTA licensing and M365 E3 floor are in place before starting any Intune-side configuration.
2. Set up the Samsung connector using an Intune Administrator plus a dedicated Samsung Knox administrator service account (not a named individual's personal Knox credential, to avoid the account-lapse failure mode).
3. Deploy Knox E-FOTA and Knox Service Plugin as Required via Managed Google Play to the target group; confirm install status before proceeding.
4. Create and assign the OEMConfig profile with all three toggles enabled to the same group.
5. Add the group to the Samsung connector and select Register.
6. **Explicitly add a staging-checklist step**: technician opens the Knox E-FOTA app on each device and accepts terms and conditions before the device leaves the staging area — do not assume this happens automatically.
7. Confirm each device reaches `Registered` in the Monitor tab (allow up to an hour for status refresh) before relying on it for a firmware campaign.

Rollback: removing the OEMConfig profile assignment or the required app assignments halts further E-FOTA functionality for affected devices but does not reverse firmware already installed by a completed campaign.

</details>

<details><summary>Playbook 2 — Firmware campaign not progressing on an already-registered fleet</summary>

1. Confirm campaign targeting criteria (device model, sales code, CSC, firmware version) against actual device hardware for a sample of affected devices, cross-checked in the Knox Admin Portal.
2. Confirm the campaign's device condition gates (charging, network type) aren't silently blocking install on devices that don't meet them during the configured window.
3. Confirm the assigned group for the campaign matches the group of devices genuinely expected to receive it — a campaign can be created against the wrong group without any error at creation time.
4. If targeting and grouping check out, treat this as a Samsung-side service issue and escalate through Knox E-FOTA support channels, since Intune has no independent firmware-delivery telemetry beyond what Samsung reports hourly.

Rollback: canceling the campaign from the Monitor tab stops further rollout to devices not yet updated; already-updated devices are unaffected by cancellation.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Intune-side Samsung Knox E-FOTA readiness evidence: required-app install
    status and OEMConfig policy status for a target device or group, to support
    escalation or pre-campaign verification.
.NOTES
    Read-only. Cannot query Samsung Knox Admin Portal-side registration/campaign
    state directly — cross-reference the Monitor tab or Knox Admin Portal separately.
#>
param(
    [string]$DeviceName
)

$device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$DeviceName'"
$knoxApps = Get-MgDeviceAppManagementMobileApp -Filter "contains(displayName,'Knox E-FOTA') or contains(displayName,'Knox Service Plugin')"
$oemConfig = Get-MgDeviceManagementDeviceConfiguration -Filter "contains(displayName,'OEMConfig')"

[PSCustomObject]@{
    DeviceName            = $device.DeviceName
    OperatingSystem        = $device.OperatingSystem
    ManagedDeviceOwnerType = $device.ManagedDeviceOwnerType
    EligibleForEFOTA        = ($device.OperatingSystem -eq "Android" -and $device.ManagedDeviceOwnerType -eq "company")
    KnoxAppsFound            = $knoxApps.DisplayName
    OEMConfigProfilesFound   = $oemConfig.DisplayName
    PulledAtUtc              = (Get-Date).ToUniversalTime()
} | ConvertTo-Json -Depth 4
```

---
## Command Cheat Sheet

```powershell
# Confirm device platform/ownership eligibility
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<device-name>'" | Select-Object DeviceName, OperatingSystem, ManagedDeviceOwnerType

# Check required-app install status
Get-MgDeviceAppManagementMobileApp -Filter "contains(displayName,'Knox E-FOTA') or contains(displayName,'Knox Service Plugin')"
Get-MgDeviceAppManagementMobileAppDeviceStatus -MobileAppId "<app-id>"

# Check OEMConfig profile assignment/status
Get-MgDeviceManagementDeviceConfiguration -Filter "contains(displayName,'OEMConfig')"

# List all Android corporate-owned devices (E-FOTA-eligible population)
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Android' and managedDeviceOwnerType eq 'company'" -All |
    Select-Object DeviceName, Model, AndroidSecurityPatchLevel

# Portal paths (no Graph equivalent — connector/campaign management is portal-only):
#   Connector setup/status : Tenant administration > Connectors and tokens > Firmware over-the-air update > Samsung
#   Campaigns               : Devices > Android > Manage updates > Android FOTA deployments
```

---
## 🎓 Learning Pointers

- Registration requires **manual, on-device end-user action** (opening the Knox E-FOTA app and accepting terms) with no remote or API completion path — plan this into device staging processes for kiosk/COSU fleets rather than assuming zero-touch coverage extends to E-FOTA the way it does to Autopilot/ADE. See [Integrate Samsung Knox E-FOTA with Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-updates/android/setup-samsung-knox).
- E-FOTA configuration uses **OEMConfig**, not the Android Enterprise settings catalog — this is Samsung's standard manufacturer-extension mechanism, and troubleshooting it follows OEMConfig conventions (profile-level Succeeded/Pending/Error status) rather than individual settings-catalog setting states.
- The Samsung Knox E-FOTA license is entirely separate from Microsoft licensing — a tenant can meet every Intune-side prerequisite and still have E-FOTA non-functional if the Samsung-side license lapses or was never purchased.
- Connector authorization depends on a Samsung Knox administrator account's standing, which Intune cannot monitor or query — use a dedicated service account for this authorization rather than a named individual's credential, to avoid silent disconnects tied to personal account lifecycle events (offboarding, MFA reset).
- All status reporting (registration report, campaign Monitor tab) refreshes **hourly** from Samsung — this is a documented, fixed cadence, not a bug when status appears to lag real-world device state.
- Only Android Enterprise COBO, COSU, and COPE corporate-owned enrollments are eligible; this is a platform-level restriction with no workaround, unlike most Intune settings-catalog gaps which are usually version/licensing issues rather than hard exclusions.
