# Windows Autopilot Device Association — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Triage

Windows Autopilot **device association** (GA, Intune August 2026 release) binds a physical Windows device to your tenant **before** it enrolls in Intune, by writing a tenant-affinity marker into the device's UEFI firmware, verified via TPM-backed attestation. It's a feature of **Autopilot device preparation** specifically — a different pipeline from classic Autopilot's hardware-hash registration (`Upload-Hash-Enroll2Autopilot.ps1`). If a ticket mentions "device association," "pre-associate," or OOBE customizations/device naming not applying on a device-prep deployment, it's this feature — not classic Autopilot profile assignment.

```powershell
# 1. Confirm this is device PREPARATION (not classic Autopilot) — device association only applies to device prep policies
Get-MgBetaDeviceManagementAutopilotDevicePreparationPolicy | Select-Object Id, DisplayName

# 2. Confirm TPM state on the affected device (physical device only — VMs are never supported)
Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, ManufacturerVersion, TpmRestrictedMode

# 3. Confirm Windows build has the required servicing update
Get-ComputerInfo | Select-Object OsBuildNumber, WindowsVersion
Get-HotFix -Id KB5120998 -ErrorAction SilentlyContinue

# 4. Confirm device association state from the Intune admin center (no stable Graph read as of this writing)
# Intune admin center > Devices > Enrollment > Device association > Devices — filter by state/policy/manufacturer/model

# 5. Confirm this isn't a Windows 365 Cloud PC — device association explicitly doesn't apply to them
Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object Model
```

| If... | Then... |
|---|---|
| Device association isn't offered at all for a device-prep deployment | Tenant/device doesn't meet licensing or OS/TPM prerequisites, or the deployment is using classic Autopilot (hash-based) rather than device preparation. See Fix 1. |
| Pre-association succeeds in Intune but the device never shows as "Associated" | Device never connected to a network during OOBE (association is triggered by that connection, or by a technician manually triggering it right after pre-associating) — not a background/delayed process. See Fix 2. |
| Association fails with a TPM/attestation-related error | TPM isn't 2.0, isn't enabled, or is in **Reduced Functionality Mode** — a hard requirement, not a soft warning. See Fix 3. |
| Device is a VM (Hyper-V, Azure VM, test lab) | Not supported — device association requires a **physical device**. No workaround exists. See Fix 3. |
| OOBE customizations (skip EULA/privacy, custom device name) aren't applying even though a device-prep policy is assigned | Those specific settings only unlock for **associated** devices, not merely policy-assigned ones — check association state before assuming the policy itself is broken. See Fix 4. |
| Device-targeted policy isn't applying / user-targeted policy is winning instead | Confirm the device is actually pre-associated (device-target assignment requires association) — user-group targeting is the fallback path when it isn't. See Fix 4. |
| Admin tried to "remove" an association from the Intune admin center and found no option | Expected — **removing association isn't supported from Intune**. It must be cleared by running a PowerShell script on the device itself. See Fix 5. |
| Device shows "Associated" but was later reset/reimaged and now behaves like it's still bound to the old tenant | The UEFI marker survives a standard OS reinstall/reset — it isn't cleared by wiping Windows. Must be explicitly removed. See Fix 5. |
| Language/keyboard selection pages still show even though "Automatically configure keyboard" is enabled | Expected when the device connects via **Wi-Fi** during OOBE — those pages aren't hidden on a Wi-Fi-driven OOBE flow regardless of policy. See Fix 6. |
| Device is a Windows 365 Cloud PC and association won't apply | By design — Windows 365 devices are already marked as trusted corporate devices and are explicitly excluded from device association. Not a bug. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Tenant licensed: M365 Business Premium / F1-F3 / A1/A3/A5 / E3/E5,
 EMS E3/E5, Intune for Education, or Entra ID P1/P2 + Intune]
        |
        ▼
[Physical device — Windows 11 24H2 or 25H2 + KB5120998 or later,
 Pro / Pro Education / Pro for Workstations / Enterprise / Education / Enterprise LTSC]
        |
        ▼
[TPM 2.0 present, enabled, NOT in Reduced Functionality Mode]
        |
        ▼
[Admin creates a device preparation policy (deployment + OOBE experience settings)]
        |
        ▼
[Device info exported from device during OOBE (CSV)]
        |
        ▼
[Admin PRE-ASSOCIATES device in Intune — uploads CSV, optionally assigns device-prep policy]
        |   (stores intent centrally — UEFI not yet written)
        ▼
[ASSOCIATE — automatic on network connect in OOBE, or technician-triggered manually]
        |   (verifies TPM-backed identity → writes tenant-affinity marker to UEFI)
        ▼
[Device enrolls: receives device-targeted policy, auto-marked corporate-owned,
 configured OOBE customizations applied]
        |
        ▼
[Ongoing: monitor via Intune > Devices > Enrollment > Device association > Devices]
        |
        ▼
[Decommission: REMOVE ASSOCIATION — admin/OEM/partner runs a PowerShell script
 ON THE DEVICE. Not supported from Intune. UEFI marker survives OS reset/reinstall.]
```

If the ticket is about classic Autopilot (hardware-hash registration, ESP, profile assignment) rather than device preparation specifically, you're in the wrong topic — cross-check `Profile-Not-Assigned-B.md`, `ESP-Stuck-B.md`, or `DevicePreparation-B.md` first.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the deployment is device preparation, not classic Autopilot**
Device association is exclusively a device-preparation feature. Intune admin center > **Devices > Enrollment > Device preparation policies** — confirm a policy exists and is the one assigned to the affected device's Entra group.

**Step 2 — Confirm device hardware/OS eligibility**
```powershell
Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, TpmRestrictedMode
Get-ComputerInfo | Select-Object OsBuildNumber
```
Expected: `TpmPresent`/`TpmReady`/`TpmEnabled` all `True`, `TpmRestrictedMode` `False`, and a build number consistent with 24H2/25H2 plus KB5120998. A VM will show no usable TPM identity at all — rule this out first since it's non-negotiable.

**Step 3 — Confirm pre-association actually happened**
Intune admin center > **Devices > Enrollment > Device association > Devices** — search by serial number. Expect a **Pre-associated** or **Associated** state. If the device isn't listed at all, the CSV upload/pre-association step was never completed for it.

**Step 4 — Confirm the association trigger occurred**
Association only happens when the device connects to a network during OOBE (automatically), or when a technician manually triggers it immediately after pre-associating. A device sitting at "Pre-associated" with no network connection during OOBE will never progress to "Associated" on its own — there's no background retry once OOBE has moved past that point without connectivity.

**Step 5 — Confirm which OOBE/policy behaviors actually require association**
Device naming templates, OOBE page-skipping, and device-targeted (vs. user-targeted) policy assignment all require **Associated** state specifically — a device that's merely enrolled via a device-prep policy without ever being associated will not get these behaviors. Don't troubleshoot the policy configuration before confirming association state.

**Step 6 — For "can't remove association" tickets**
Confirm this is being attempted from Intune (unsupported, by design) rather than via the on-device PowerShell removal script. See Fix 5 for the correct path.

---
## Common Fix Paths

<details><summary>Fix 1 — Device association isn't offered / doesn't apply to this deployment</summary>

1. Confirm the deployment uses **Autopilot device preparation**, not classic Autopilot (hardware-hash based). Device association is device-prep-only.
2. Confirm tenant licensing covers Autopilot device preparation (M365 Business Premium, F1/F3, Academic A1/A3/A5, Enterprise E3/E5, EMS E3/E5, Intune for Education, or Entra ID P1/P2 + Intune).
3. Confirm the device isn't a Windows 365 Cloud PC — these are explicitly excluded (already trusted corporate devices by design).
4. Confirm OS build/edition eligibility (Windows 11 24H2/25H2 + KB5120998, supported edition list) before assuming a licensing or configuration gap.

**Rollback:** N/A — eligibility check only, no configuration change.

</details>

<details><summary>Fix 2 — Pre-associated but never reaches "Associated" state</summary>

1. Confirm the device actually connected to a network (Wi-Fi or Ethernet) at some point during OOBE — this is the automatic association trigger. No connection = no automatic association attempt.
2. If the device is currently sitting in OOBE, a technician can manually trigger association immediately after the pre-association step completes in Intune — don't assume it will happen silently in the background afterward.
3. If the device has already passed OOBE and enrolled without ever associating, the OOBE-specific window has closed — pre-association intent alone doesn't retroactively associate a device once it's past OOBE.
4. Re-image and restart the OOBE flow if the deployment absolutely requires association and the window was missed.

**Rollback:** N/A — no destructive action taken.

</details>

<details><summary>Fix 3 — TPM/attestation failure or attempted use on a VM</summary>

1. `Get-Tpm` — confirm `TpmPresent`, `TpmReady`, `TpmEnabled` are all `True` and `TpmRestrictedMode` is `False`. Reduced Functionality Mode blocks association outright.
2. If TPM is disabled in firmware, enable it via UEFI/BIOS settings (vendor-specific) and re-run OOBE.
3. If the target is a virtual machine (Hyper-V, Azure VM, any hypervisor), stop — device association has no VM support path, full stop. Redirect the deployment to a physical device, or to classic Autopilot/manual MDM enrollment if a VM-based test/deployment is genuinely required.
4. Confirm the OS build includes KB5120998 or later — an unpatched 24H2/25H2 build can behave as if the feature isn't present at all, which is easy to misdiagnose as a TPM fault.

**Rollback:** N/A — hardware/firmware verification, no configuration change unless TPM was disabled and needs re-enabling (vendor-specific, reversible in firmware).

</details>

<details><summary>Fix 4 — OOBE customizations or device-targeted policy not applying</summary>

1. Confirm the device shows **Associated** (not just Pre-associated or absent) in **Devices > Enrollment > Device association > Devices**. OOBE skip-pages, device naming, and device-targeted policy assignment are gated on this state specifically.
2. If Associated but customizations still aren't applying, re-check the device-prep policy's OOBE experience settings tab — confirm the specific toggles (Hide EULA, Hide privacy settings, Automatically configure keyboard, Apply device name template) are actually enabled on the policy assigned to that device, not a different policy in the tenant.
3. For "Hide change account options" specifically: confirm company branding is configured in Microsoft Entra ID first — this setting has that as a hard prerequisite and fails silently (setting has no effect) without it.
4. For device naming: confirm the template syntax is valid (`%SERIAL%`, `%RAND:x%`, letters/numbers/hyphens only, ≤ 63 characters, not all-numeric).

**Rollback:** N/A — configuration verification.

</details>

<details><summary>Fix 5 — Need to remove/clear a device's association</summary>

Removing association **from Intune is not supported** in the current release — there is no admin-center button or Graph call that clears it centrally. The UEFI marker also **survives a standard Windows reset or reinstall**, so wiping the OS does not clear it either.

1. Obtain the current device-association removal script from Microsoft's documentation (see Learning Pointers) — it must be **run locally on the device itself**, typically by an admin, the OEM, or a partner with physical/remote access.
2. Run the script with appropriate privileges on the target device to clear the UEFI-stored tenant-affinity marker.
3. Confirm removal by checking the device no longer shows an Associated state in **Devices > Enrollment > Device association > Devices** after its next enrollment/OOBE attempt.
4. For decommissioned or repurposed hardware being moved to a different tenant (common in MSP off-boarding/hardware-resale scenarios), removal must happen **before** the device is handed off — a receiving tenant cannot pre-associate a device that's still carrying another tenant's marker.

**Rollback:** N/A — this is itself the corrective/rollback action for a stale association.

</details>

<details><summary>Fix 6 — Language/keyboard OOBE pages still showing despite policy setting</summary>

Expected behavior, not a bug: when a device connects via **Wi-Fi** during OOBE, the language and keyboard selection pages are **not** hidden regardless of the "Automatically configure keyboard" setting. This only behaves as configured on Ethernet-connected OOBE flows.

1. Confirm how the device connected during OOBE (Wi-Fi vs. wired).
2. If consistent, unskippable OOBE language/keyboard pages are unacceptable for the deployment, move affected sites to wired OOBE connectivity, or set expectations with the client that Wi-Fi-based OOBE will always show these two pages.

**Rollback:** N/A — informational, no configuration change.

</details>

---
## Escalation Evidence

```
Ticket: Windows Autopilot Device Association issue
─────────────────────────────────────────
Tenant ID:                          <____________________>
Device serial number:               <____________________>
Device preparation policy name:     <____________________>
TPM state (TpmPresent/Ready/Enabled/RestrictedMode): <_______>
OS build / KB5120998 present:       <____________________>
Physical device or VM:              <____________________>
Association state (absent / Pre-associated / Associated): <_______>
OOBE connectivity type (Wi-Fi / Ethernet):  <_______>
Symptom (won't associate / OOBE customization not applying / can't remove / other): <_______>
Time issue first observed:          <____________________>
```

---
## 🎓 Learning Pointers

- **Device association is a device-preparation-only feature — it does not apply to classic (hardware-hash) Autopilot.** Confirm which pipeline a deployment actually uses before troubleshooting; the two share the Autopilot name but have different device-trust mechanics entirely. [Overview of Windows Autopilot device association](https://learn.microsoft.com/en-us/autopilot/device-preparation/device-association/overview)

- **Pre-associate and associate are two distinct steps, and only the second one writes anything to the device.** An admin completing the Intune-side pre-association step has not yet bound the device — that only happens when the device itself connects to a network in OOBE (or a technician triggers it manually right after). Don't tell a client "it's associated" until the Devices blade actually shows that state. [Overview of Windows Autopilot device association](https://learn.microsoft.com/en-us/autopilot/device-preparation/device-association/overview)

- **TPM 2.0 and a physical device are hard requirements with zero workaround** — no Reduced Functionality Mode, no virtual machines, period. Rule this out first on any association failure before spending time on policy configuration. [Requirements for Windows Autopilot device association](https://learn.microsoft.com/en-us/autopilot/device-preparation/device-association/requirements)

- **Removing an association cannot be done from Intune, and the UEFI marker survives a plain OS reset/reinstall.** This matters most in MSP hardware-resale/off-boarding/tenant-transfer scenarios — a device physically leaving a tenant must have its association cleared via the on-device PowerShell script before it can be usefully pre-associated elsewhere. Build this into decommissioning checklists now, before it becomes a fire drill. [Remove association from a device](https://learn.microsoft.com/en-us/autopilot/device-preparation/device-association/remove-association)

- **Several of the flagship benefits (OOBE page-skipping, device naming, device-targeted policy) only activate for devices that reach the Associated state** — a device merely covered by an assigned device-prep policy but never associated will not get them. Treat "policy assigned" and "device associated" as two separate, independently-verifiable facts. [Introducing device association for Windows Autopilot device preparation](https://techcommunity.microsoft.com/blog/intunecustomersuccess/introducing-device-association-for-windows-autopilot-device-preparation/4550603)

- **Wi-Fi-driven OOBE connections always show the language/keyboard pages, regardless of policy.** This is a documented, permanent limitation of the current release, not an intermittent bug — set client expectations accordingly for Wi-Fi-only deployment scenarios. [Overview of Windows Autopilot device association](https://learn.microsoft.com/en-us/autopilot/device-preparation/device-association/overview)
