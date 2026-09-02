# eSIM Cellular Profile Deployment (Windows Connected PCs) — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **enterprise bulk deployment of eSIM cellular data profiles to Windows Connected PCs** (Surface Pro/LTE-class and other eSIM-capable Windows hardware) via Microsoft Intune, using either of Microsoft's two supported bulk-activation mechanisms:

1. **CSV activation-code import** (public preview) — importing mobile-operator-supplied one-time-use activation codes, targeted at Windows 10 and 11.
2. **eSIM download server (SM-DP+) configuration** via a Settings Catalog policy — the device authenticates directly to the operator's download server using its hardware EID, no individual codes required. Windows 11 only, and the mobile-operator-recommended method going forward.

Both mechanisms are built on the same underlying Windows platform capability: the **eUICCs Configuration Service Provider (CSP)**, which handles eSIM configuration and profile retrieval on the device regardless of which Intune-side bulk method delivered the configuration.

**In scope:** the full architecture of both methods, their prerequisites, the CSV file contract, the Settings Catalog profile contract, monitoring/status surfaces, and the (narrow) set of currently-documented limitations for each.

**Explicitly out of scope:**
- The consumer, non-MDM **Mobile Plans app** experience for individual users manually adding an eSIM — relevant only as background context (see How It Works) since it's the underlying OS-level UX these MDM methods automate at scale.
- iOS/Android eSIM deployment — an entirely different platform and management surface, not covered here.
- Custom OMA-URI profiles built directly against the [eUICCs CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/euiccs-csp) for single-device, non-bulk scenarios — mentioned only where relevant to the CSV method's underlying mechanism.
- Cellular connectivity troubleshooting unrelated to eSIM profile provisioning itself (APN configuration post-activation, general Wi-Fi/cellular radio issues) — see `NetworkAdapters-A.md` for general connectivity troubleshooting once a profile is confirmed active.

**Assumes:** engineer has Intune Policy and Profile Manager (or equivalent) RBAC role, has a signed contract/relationship with at least one mobile operator supporting enterprise eSIM provisioning, and understands basic Intune Settings Catalog and device-group assignment concepts.

---
## How It Works

<details><summary>Full architecture</summary>

**eSIM fundamentals.** An eSIM (embedded SIM) is a fixed, non-removable chip called an **eUICC (embedded Universal Integrated Circuit Card)** — the secure execution container that a traditional physical SIM card also provides, but permanently soldered into the device rather than swappable. Each eUICC has a globally unique **EID (eUICC Identifier)**, analogous to a physical SIM's ICCID but tied to the device hardware itself rather than a removable card. Multiple **eSIM Profiles** — digital packages containing the credentials and configuration for a specific mobile operator subscription — can be stored on one eUICC, with exactly one active/enabled at a time; the active profile behaves identically to a traditional inserted SIM card from the OS and radio stack's perspective. Windows has supported eSIM since 2017 via the **Mobile Plans** consumer app, which provides a manual, per-device, user-driven flow unsuitable for enterprise scale — the two Intune-side bulk methods exist specifically to eliminate that manual per-device friction.

**Method 1 — CSV Activation-Code Import (public preview).** The mobile operator supplies a CSV containing: row 1, the bare FQDN of their SM-DP+ (Subscription Manager Data Preparation) server; row 2 onward, one-time-use `ICCID,MatchingID` pairs, one per target device. Intune names the resulting "cellular subscription pool" after the SMDP portion of the FQDN automatically. On import, Intune validates file structure strictly and rejects the whole file on any formatting violation. The admin creates a static Entra device group scoped to eSIM-capable devices and assigns it to the imported pool. On the device side, Intune installs an activation code (Intune **randomly distributes** codes across targeted devices — there is no way to guarantee a specific code lands on a specific device), and the eUICC hardware then independently contacts the mobile operator using that code to download and activate the corresponding eSIM profile — this final handshake is entirely between the device and the operator, outside Intune's control or deep visibility. Internally, this is functionally equivalent to (and can alternatively be hand-built as) a custom OMA-URI profile against the **eUICCs CSP**, one profile per device with matching ICCID/activation code — the bulk CSV method exists purely to avoid building hundreds of individual custom profiles by hand.

**Method 2 — eSIM Download Server (SM-DP+ FQDN, recommended, Windows 11 only).** Rather than distributing individual codes, the mobile operator instead **pre-provisions an eSIM profile on their own SM-DP+ server for each device, keyed by that device's EID** — a process the organization enables by supplying the operator with a manifest of device EIDs (obtained from device packaging or, for bulk purchases, an OEM/reseller-supplied manifest file). The admin then builds a Settings Catalog policy containing the operator's SM-DP+ FQDN plus two behavioral settings (**Auto Enable** — whether the retrieved profile activates automatically; **Display Local UI** — whether the end user can see/change eSIM settings locally), and assigns it to a static device group. During Windows's out-of-box experience (or at any later policy-evaluation point for already-deployed devices), the device authenticates to Microsoft Entra ID, enrolls to Intune, receives this policy, then contacts the configured SM-DP+ FQDN directly. The download server authenticates the device by its EID, looks up the pre-provisioned profile, and serves it — the device installs and (if Auto Enable is set) activates it automatically, with Windows then auto-configuring cellular settings (APN, etc.) for the recognized operator.

**Why the download-server method is now recommended over CSV activation codes on Windows 11:** it eliminates per-device manual code handling entirely (only a one-time EID manifest exchange with the operator is required), scales more cleanly for large fleets, and ties activation to hardware identity (EID) rather than a one-time-use secret that must be correctly distributed and tracked. Its tradeoffs are Windows 11-only support and a documented current limitation to a single configured Server Name per policy (multiple entries are accepted in the UI but only the first is honored).

**The eUICCs CSP as the common substrate.** Regardless of which Intune-side bulk method delivered the configuration, the actual on-device eSIM configuration and profile retrieval is handled by the same **eUICCs Configuration Service Provider**. This is why both methods share the same fundamental limitation: Intune's role ends at successful delivery of its half of the configuration (activation code, or SM-DP+ FQDN policy) — the subsequent device-to-operator handshake, and the resulting profile's actual presence/state on the eUICC, is not something Intune can directly query or control after that point. The **only two supported monitoring surfaces** are Intune's own delivery-status reporting (which only confirms *its* half) and the device's local **Settings > Network & Internet > Cellular > Manage eSIM profiles** view (which confirms actual on-device state, but requires physical/remote access to the device to check).

</details>

---
## Dependency Stack

```
Layer 5:  Operator-side activation — SM-DP+ server authenticates the device
          (by activation code, or by EID) and serves the eSIM profile; entirely
          outside Intune's control and largely outside its visibility
              ↑ requires
Layer 4:  eUICCs CSP processing on-device — receives Intune's delivered
          configuration (activation code, or SM-DP+ FQDN) and initiates
          the Layer 5 handshake
              ↑ requires
Layer 3:  Intune-side configuration delivery — CSV-imported activation code
          installed via policy, OR Settings Catalog SM-DP+ FQDN policy
          delivered and applied; this is what Intune's own status reporting
          actually confirms
              ↑ requires
Layer 2:  Static Entra device group correctly scoped to eSIM-capable devices,
          assigned to the pool/policy
              ↑ requires
Layer 1:  Device eligibility — physically eSIM-capable hardware, MDM-enrolled,
          correct Windows version for the chosen method (10/11 for CSV method;
          11 only for download-server method)
```

Reading this stack for triage: Intune's own "Succeeded"/"Active" reporting is authoritative only through **Layer 3**. Any symptom that looks like activation failure despite a confirmed Layer 3 success must be diagnosed at Layer 4/5 — which, critically, has **no remote Intune-side diagnostic** at all. The only Layer 4/5 evidence source is the device's own local Settings UI, or the mobile operator's own support channel.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| CSV import rejected outright | Layer 3 — file structure violation, mixed-operator file, or duplicate provider pool | File structure against the documented CSV contract |
| Device status "Device not synced" | Layer 2/3 — device hasn't checked in since policy/pool assignment | `LastSyncDateTime`; trigger manual sync |
| Device status "Activation fail" (CSV method) | Layer 5 — code already used, expired, or operator-side rejection | Cellular status column (operator-supplied); contact operator |
| Download-server policy "Succeeded," no profile on device | Layer 4/5 — device hasn't yet contacted SM-DP+, wrong/mistyped FQDN, or device's EID not provisioned on operator's server | On-device Settings > Cellular > Manage eSIM profiles; confirm FQDN spelling; confirm EID provisioning with operator |
| Download-server method assigned to Windows 10 | Layer 1 — unsupported combination; policy may still show delivered but the method itself doesn't function on Windows 10 | OS version vs. method support matrix |
| "The request is invalid" on CSV import | Layer 3 — a pool for that same mobile operator already exists; Intune doesn't support two concurrent lists per provider | Existing subscription pools list |
| Admin expects remote eSIM removal | Not a fault — this capability is genuinely absent for the download-server method, and indirect-only (group removal) for the CSV method | Design limitation, not a bug |

---
## Validation Steps

1. **Confirm device eligibility and current sync state:**
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
       Select-Object DeviceName, Model, Manufacturer, OSVersion, LastSyncDateTime
   ```

2. **Identify the deployment method actually assigned** — inspect the device's assigned configuration policies/profiles for either an eSIM cellular subscription pool assignment (CSV method) or a Settings Catalog policy containing eSIM/eUICC settings (download-server method). These are architecturally distinct object types in Intune and must not be conflated.

3. **For the CSV method, use the admin center's Device Status view** (Devices > Manage devices > eSIM cellular profiles > subscription > Device Status) as the authoritative per-device state (Device not synced / Activation pending / Active / Activation fail) plus the operator-supplied **Cellular status** column — this is currently the most complete status surface and has no fully-equivalent friendly Graph cmdlet; see `Get-eSIMDeploymentStatus.ps1` (Intune/Scripts/) for a scripted approximation via the underlying `embeddedSIMActivationCodePools` Graph beta resource.

4. **For the download-server method, separate the two independent facts:**
   - Policy delivery status (Intune/Graph-side — confirms Layer 3 only).
   - Actual profile presence (device-side only — Settings > Network & Internet > Cellular > Manage eSIM profiles). There is no remote/Graph equivalent for this second fact.

5. **If Layer 3 delivery is confirmed but Layer 4/5 shows no result after a reasonable window (allow for at least one full sync + a few minutes for the operator handshake):** treat as a Layer 5 (operator-side) issue by default and engage the mobile operator with the device's EID/ICCID and configured server details — this is the single most common genuine root cause once Intune-side delivery is confirmed clean.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm eligibility (Layer 1).**
Verify device hardware supports eSIM, is running a Windows version compatible with the assigned method, and is MDM-enrolled and recently synced. A large fraction of "not working" reports resolve here — most commonly, the download-server method mistakenly assigned to Windows 10 hardware.

**Phase 2 — Confirm targeting (Layer 2).**
Verify the static Entra device group used for assignment contains exactly the intended eSIM-capable devices — a group that's too broad risks assigning a download-server policy to non-eSIM hardware (which Intune cannot detect or filter for automatically; "Intune can't distinguish between an eSIM and a non-eSIM device" per Microsoft's own documentation) resulting in error assignment status for those devices.

**Phase 3 — Confirm delivery (Layer 3).**
Verify the CSV imported cleanly / the Settings Catalog policy shows a successful assignment status for the specific device. This is the boundary of Intune's authoritative visibility — do not continue troubleshooting inside Intune past this point.

**Phase 4 — Escalate to operator-side diagnosis (Layer 4/5).**
Once Layers 1-3 are confirmed clean, the remaining failure surface is the device-to-operator handshake. Check the device's local eSIM settings UI if accessible; otherwise, engage the mobile operator directly with the device's EID (download-server method) or ICCID/activation code (CSV method) — this is the only channel with visibility into Layer 5.

**Phase 5 — Lifecycle and offboarding planning.**
Because there is no supported remote profile-removal action, build offboarding procedures that explicitly account for this: for CSV-method devices, removal from the assigned Entra group before/at retirement; for download-server-method devices, plan for manual on-device removal or rely on the automatic removal that occurs at retire/unenroll/wipe. Document this limitation for any customer-facing SLA language around device deprovisioning.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standing up a new eSIM deployment (download-server method, Windows 11 fleet)</summary>

1. Confirm the mobile operator supports the SM-DP+ download-server model and obtain their FQDN.
2. Collect and provide the fleet's device EIDs to the operator (from device packaging, or an OEM/reseller-supplied manifest for bulk purchases) so the operator can pre-provision profiles per device.
3. Create a static Entra device group scoped precisely to the eSIM-capable Windows 11 devices in this deployment — err toward under-inclusion and expand deliberately, since Intune cannot filter for eSIM capability automatically.
4. Build a Settings Catalog policy (Windows 10 and later platform, despite the method being Windows-11-functional-only) with the eSIM Download Servers settings: Server Name (bare FQDN, no protocol prefix), Auto Enable, Display Local UI.
5. Assign to the device group; monitor assignment status per device.
6. Validate end-to-end on a small pilot batch by physically or remotely checking the on-device eSIM settings UI before declaring the deployment complete — Intune-side "Succeeded" alone is not sufficient validation, per this runbook's core finding.

</details>

<details><summary>Playbook 2 — Diagnosing a fleet-wide "eSIM not activating" report</summary>

1. Pull the full device list and identify how many are on the CSV method vs. the download-server method — a mixed-method fleet frequently has a mixed root cause, and lumping both together in one investigation wastes time.
2. For each method, work top-down through the Dependency Stack (Layer 1 → 5), confirming each layer before assuming the next is at fault.
3. If Layer 3 delivery is confirmed clean across the affected devices but Layer 4/5 shows no activation, treat this as a single operator-side incident (e.g., an SM-DP+ outage or a manifest-provisioning gap) rather than N individual device issues — escalate once to the operator with the full affected-device list rather than one ticket per device.

</details>

---
## Evidence Pack

```powershell
# eSIM Deployment — Evidence Pack (run against Microsoft Graph; requires
# DeviceManagementManagedDevices.Read.All and DeviceManagementConfiguration.Read.All)

Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All","DeviceManagementConfiguration.Read.All"

$deviceName = "<DeviceName>"

$evidence = [PSCustomObject]@{
    Device            = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$deviceName'" |
                             Select-Object DeviceName, Id, Model, Manufacturer, OSVersion, LastSyncDateTime
    eSIMPolicies      = Get-MgDeviceManagementConfigurationPolicy -Filter "contains(name,'eSIM')" |
                             Select-Object Id, Name, LastModifiedDateTime
    Timestamp         = Get-Date -Format "o"
    Note              = "Actual eSIM profile presence/state is only observable on-device (Settings > Network & Internet > Cellular > Manage eSIM profiles) or via the mobile operator — not retrievable through Graph."
}

$evidence | ConvertTo-Json -Depth 6 | Out-File "$env:TEMP\eSIM-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$evidence
```

---
## Command Cheat Sheet

| Purpose | Command / Location |
|---|---|
| Device eligibility/sync check | `Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<Name>'"` |
| List eSIM-related Settings Catalog policies | `Get-MgDeviceManagementConfigurationPolicy -Filter "contains(name,'eSIM')"` |
| CSV activation-code pool admin UI | Intune admin center > Devices > Manage devices > eSIM cellular profiles |
| Graph beta resource (activation-code pools) | `deviceManagement/embeddedSIMActivationCodePools` |
| On-device profile state (authoritative for Layer 4/5) | Device Settings > Network & Internet > Cellular > Manage eSIM profiles |
| eUICCs CSP reference | [eUICCs CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/euiccs-csp) |
| CSV method official doc | [Enable eSIM data connections in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-configuration/templates/enable-esim) |
| Download-server method official doc | [eSIM configuration of a download server](https://learn.microsoft.com/en-us/intune/device-configuration/templates/configure-esim-download-server) |

---
## 🎓 Learning Pointers

- **Two architecturally different bulk methods exist, and they are not interchangeable.** CSV activation-codes (one-time secrets, Windows 10/11, public preview) vs. SM-DP+ download server (EID-based, Windows 11 only, recommended) — identifying which is deployed is the prerequisite for every subsequent diagnostic step in this topic.
- **Intune's visibility ends at policy/code delivery.** The actual profile-retrieval handshake between device and mobile operator (Layer 4/5) has no remote Intune-side diagnostic at all — this is a hard architectural boundary, not a tooling gap to work around. Build this into ticket-escalation expectations from the start.
- **There is no remote eSIM removal capability**, and this is a documented, current product limitation rather than a bug — plan device offboarding and any customer-facing deprovisioning SLAs with this constraint in mind up front.
- Windows has supported eSIM since **2017** via the consumer Mobile Plans app; the enterprise bulk-deployment methods this runbook covers are comparatively recent additions layered on top of that same underlying eUICCs CSP substrate — understanding the CSP as the shared foundation clarifies why both methods share the same Layer 4/5 visibility limitation.
- [Enable eSIM data connections in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-configuration/templates/enable-esim) and [eSIM configuration of a download server](https://learn.microsoft.com/en-us/intune/device-configuration/templates/configure-esim-download-server) are both current as of mid-2026 and explicitly mark the CSV method as public preview and "supported, but not recommended" on Windows 11 — re-check both pages periodically, since a preview feature's constraints (single Server Name, no CSV append, no remote removal) are plausible candidates for future GA improvement.
