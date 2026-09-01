# Windows Autopilot Device Association — Reference Runbook (Mode A: Deep Dive)
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

Covers **Windows Autopilot device association** — a feature of **Autopilot device preparation** (GA, Intune August 2026 release) that binds a physical Windows device to a tenant *before* it enrolls with an MDM provider, by writing a tenant-affinity marker into the device's UEFI firmware and verifying the device's identity via TPM-backed attestation. It is architecturally distinct from classic Autopilot's hardware-hash registration model (`Upload-Hash-Enroll2Autopilot.ps1`, `AutopilotHWID`) — device association applies only to deployments built on **device preparation policies**, not classic Autopilot deployment profiles.

The core value proposition is establishing device trust *earlier* in the provisioning lifecycle than enrollment itself: once a device is associated, Intune can target policy at the device object directly (rather than only via user-group membership), apply OOBE customizations before the user ever reaches the desktop, and automatically mark the device corporate-owned — all before a single MDM enrollment call has occurred.

**Does not cover:**
- Classic Autopilot (hardware-hash based deployment profiles, ESP, White Glove pre-provisioning) — see `Autopilot/_AGENT.md`, `Profile-Not-Assigned-A.md`, `ESP-Stuck-A.md`, `WhiteGlove-A.md`. Device association shares no mechanism with hash-based registration.
- General Autopilot device preparation policy configuration and troubleshooting (Entra join type, app/script assignment, ESP behavior for device-prep deployments) — see `DevicePreparation-A.md`. This file covers only the association layer that sits underneath device-prep policies.
- TPM architecture, attestation internals, or Virtualization-Based Security — see `Windows/Troubleshooting/VBS-CredentialGuard-A.md`. Only the specific TPM 2.0 / Reduced Functionality Mode gate relevant to association eligibility is covered here.
- Windows 365 Cloud PC provisioning — device association explicitly does not apply to Windows 365 devices (already marked as trusted corporate devices by design); see `Azure/Windows365/_AGENT.md`.
- Corporate device identifiers (the legacy manual CSV upload of serial numbers/IMEIs to mark personally-owned-restriction-exempt devices) — device association supersedes the need for this on associated devices specifically, but the legacy mechanism itself is covered in `Intune/_AGENT.md`.

---
## How It Works

<details><summary>Full architecture</summary>

### What "association" actually means

Device association establishes a **verifiable, cryptographically-backed link** between a physical device and a tenant, independent of and prior to MDM enrollment. The mechanism is a **tenant-affinity marker written into the device's UEFI firmware**, whose authenticity at enrollment time is attested using the device's **TPM-backed identity**. This is a materially different trust model from classic Autopilot, where trust is established purely by matching an uploaded hardware-hash string against Microsoft's Autopilot service at enrollment time — device association instead binds the *physical device itself*, at the firmware level, before enrollment logic even runs.

### Three lifecycle operations

| Operation | Performed by | Mechanism |
|---|---|---|
| **Pre-associate** | Admin, in Intune | Stores the *intent* to associate a device with the tenant in a central cloud service. No UEFI write occurs at this stage — it is a declaration, not yet a binding. |
| **Associate** | Automatic (device connects to a network during OOBE), or a technician triggering it manually immediately after pre-associating | The device presents its TPM-backed identity; once verified against the pre-associated intent, the tenant-affinity marker is written into UEFI. This is the step that actually creates the binding. |
| **Remove association** | Admin, OEM vendor, or partner — via a PowerShell script run **on the device itself** | Deletes the UEFI-stored marker, releasing the device from its bound tenant. Not exposed as an Intune admin-center or Graph action in the current release. |

The separation between pre-associate and associate matters operationally: an admin completing the Intune-side step has not yet bound anything. The device must independently reach the associate step — normally an automatic consequence of network connectivity during OOBE — before any association-gated behavior (device-targeted policy, OOBE customization, automatic corporate marking) takes effect.

### Provisioning workflow, end to end

1. **Create a device preparation policy** defining deployment behavior and OOBE experience settings.
2. **Export device information** from the physical device during OOBE (produces the identifying data needed for pre-association).
3. **Pre-associate** the device in Intune by uploading the exported CSV; optionally assign a device-prep policy at this step.
4. **Associate** — triggered automatically when the device connects to a network during OOBE, or manually by a technician immediately after pre-associating. This is what stamps the UEFI marker.
5. **Enroll** — the device receives its device-targeted policy (if assigned), is automatically marked corporate-owned, and has configured OOBE customizations applied, all before the assigned user's first sign-in completes.
6. **Remove association** at end-of-life/decommission/tenant-transfer — via the on-device PowerShell script, not from Intune.

### Why this unlocks device-targeted policy and OOBE customization

Prior to device association, device-preparation deployments could only target policy via **Entra group membership of the intended user** — a device itself had no independently addressable identity until it enrolled. Association gives Intune a trustworthy device identity *before* enrollment, which is what makes **device-based policy targeting** possible: one user signing into multiple associated devices can now receive a different device-prep policy per device, rather than the same user-linked policy on all of them. The same pre-enrollment trust is what allows Intune to safely apply OOBE page-skipping and device naming *before* the user reaches the desktop — those behaviors would otherwise require enrollment (and therefore user interaction) to have already completed.

### OOBE customization settings unlocked by association

Available only in the device-prep **user-driven** policy, and only take effect for associated devices:

- **Language (Region)** — preselects OOBE language.
- **Automatically configure keyboard** — skips the keyboard-selection page once language is set. Does **not** suppress these pages when the device's OOBE network connection is Wi-Fi (a hard, documented limitation — only Ethernet-connected OOBE fully hides them).
- **Hide Microsoft Software License Terms** — skips the EULA page.
- **Hide privacy settings** — skips the privacy page; when hidden, location services default to **disabled**.
- **Hide change account options** — removes change-account links from sign-in/domain-error pages. Hard prerequisite: **company branding must already be configured in Microsoft Entra ID**, or the setting has no effect.
- **Apply device name template** — names the device at enrollment using a template (up to 63 characters, letters/numbers/hyphens, not all-numeric; `%SERIAL%` and `%RAND:x%` tokens supported).

On Windows Professional editions specifically, the **Personal account / Work and school account** OOBE page is hidden by default for all associated devices, independent of the above toggles.

### Automatic corporate-owned marking

Associated devices are automatically flagged corporate-owned in Intune, which bypasses **personally-owned-device enrollment restrictions** without requiring the legacy manual step of uploading a corporate device identifier (serial number/IMEI) ahead of time. This is a meaningful operational simplification for bulk deployments — the corporate-identifier upload workflow effectively becomes unnecessary for any device going through association.

### Current-release limitations

- **Association removal is not available from Intune** — no admin-center control, no documented Graph write operation. The only supported path is running a PowerShell script locally on the device to clear the UEFI marker.
- **Device association does not apply to Windows 365 Cloud PCs** — these are already treated as trusted corporate devices under a separate model, so the association layer is a no-op for them by design, not a gap to work around.
- The UEFI-stored marker is **firmware-level and persists across a standard OS reset or reinstall** — reimaging a device does not release its tenant association.

</details>

---
## Dependency Stack

```
[Tenant licensing: M365 Business Premium / F1-F3 / Academic A1/A3/A5 /
 Enterprise E3/E5 / EMS E3/E5 / Intune for Education / Entra ID P1/P2 + Intune]
        |
        ▼
[Physical device — Windows 11, version 24H2 or 25H2, with KB5120998 or later]
        |         (Pro / Pro Education / Pro for Workstations / Enterprise /
        |          Education / Enterprise LTSC — no VM support, ever)
        ▼
[TPM 2.0 present + enabled + NOT in Reduced Functionality Mode]
        |         (TPM-backed identity is the cryptographic root of the
        |          entire association trust chain — nothing above this
        |          layer functions without it)
        ▼
[Admin creates a device preparation policy: deployment + OOBE experience settings]
        |
        ▼
[Device information exported from device during OOBE → CSV]
        |
        ▼
[PRE-ASSOCIATE: admin uploads CSV in Intune, optionally assigns device-prep policy]
        |         (intent stored centrally — no UEFI write yet)
        ▼
[ASSOCIATE: automatic on OOBE network connect, or technician-triggered manually]
        |         (TPM-backed identity verified → tenant-affinity marker
        |          written to UEFI — this is the actual binding event)
        ▼
[Device enrolls]
        |
        ├── Device-targeted policy applies (independent of user-group targeting)
        ├── Automatic corporate-owned marking (bypasses personal-device restrictions)
        └── Configured OOBE customizations applied pre-desktop
        |
        ▼
[Ongoing monitoring: Intune > Devices > Enrollment > Device association > Devices]
        |         (state / assigned policy / manufacturer / model — filterable)
        ▼
[End of life / decommission / tenant transfer]
        |
        ▼
[REMOVE ASSOCIATION — PowerShell script run ON THE DEVICE by admin/OEM/partner]
        (NOT available from Intune; UEFI marker survives OS reset/reinstall
         and MUST be explicitly cleared before the device can be usefully
         pre-associated with a different tenant)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Device association option not visible/usable for a deployment | Deployment is classic Autopilot, not device preparation; or tenant/device fails licensing/OS/edition prerequisites | Confirm device-prep policy exists; confirm licensing SKU; confirm OS build/edition |
| Device stuck at "Pre-associated," never reaches "Associated" | Device never connected to a network during OOBE, and the OOBE window has since closed | Confirm network connectivity occurred during OOBE; re-run OOBE if the window was missed |
| Association fails outright with a TPM-related error | TPM not 2.0, not enabled, or in Reduced Functionality Mode; or target is a VM (unsupported, no exceptions) | `Get-Tpm`; confirm physical hardware, not virtualized |
| OOBE customizations (skip pages, device naming) configured but not applied | Device reached enrollment without ever completing the Associate step | Check state in Devices > Enrollment > Device association > Devices — must show Associated, not just Pre-associated |
| Device-targeted policy not applying, user-group-targeted policy applies instead | Device isn't associated — device-target assignment requires it | Same as above |
| Language/keyboard OOBE pages still appear despite "Automatically configure keyboard" | Device connected via Wi-Fi during OOBE — those pages are never hidden on Wi-Fi, only Ethernet, by design | Confirm OOBE connection type |
| "Hide change account options" configured but ineffective | Company branding not yet configured in Microsoft Entra ID — hard prerequisite for this specific setting | Entra admin center > Company branding — confirm configured |
| Admin can't find a "remove association" control in Intune | Doesn't exist in the current release — must run the on-device PowerShell removal script instead | N/A — process gap, not a bug |
| Device reset/reimaged but still behaves as tenant-bound | UEFI marker is firmware-level and survives OS reset/reinstall by design | Run the on-device removal script explicitly before assuming a clean state |
| Windows 365 Cloud PC won't associate | By design — device association explicitly excludes Windows 365 devices (already trusted) | Not a defect; redirect to Windows 365's own provisioning/trust model |

---
## Validation Steps

**Step 1 — Confirm the deployment type**
Intune admin center > **Devices > Enrollment > Device preparation policies**. If the affected deployment isn't listed here, it's classic Autopilot and device association doesn't apply.

**Step 2 — Confirm device hardware eligibility**
```powershell
Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, TpmRestrictedMode, ManufacturerVersion
Get-ComputerInfo | Select-Object OsBuildNumber, WindowsProductName
Get-HotFix -Id KB5120998 -ErrorAction SilentlyContinue
Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object Model, Manufacturer
```
Expected: TPM fully present/ready/enabled, not in Restricted (Reduced Functionality) Mode; OS build consistent with 24H2/25H2 plus the required KB; `Model`/`Manufacturer` indicating physical hardware (a hypervisor-reported model string is an immediate disqualifier).

**Step 3 — Confirm licensing**
Cross-check the tenant's active subscriptions against the documented SKU list (M365 Business Premium, F1/F3, Academic A1/A3/A5, Enterprise E3/E5, EMS E3/E5, Intune for Education, or Entra ID P1/P2 + Intune) via **Microsoft 365 admin center > Billing > Licenses**, or `Get-MgSubscribedSku`.

**Step 4 — Confirm pre-association and association state**
Intune admin center > **Devices > Enrollment > Device association > Devices** — locate the device by serial number. Expected states, in order: not listed → **Pre-associated** → **Associated**. A device stuck at Pre-associated indicates the OOBE network-connect trigger never fired.

**Step 5 — Confirm policy assignment matches expectation**
For device-targeted policy tickets, confirm the device-prep policy was assigned **to the device** (available once associated) rather than only to a user group — the two produce different outcomes for a user who enrolls multiple devices.

**Step 6 — Confirm OOBE customization prerequisites**
For "Hide change account options" specifically, confirm **Company branding** is configured in Entra ID (Entra admin center > Company branding) before treating the setting itself as broken.

**Step 7 — Confirm removal path for decommission/tenant-transfer tickets**
Confirm the on-device PowerShell removal script has actually been run, rather than assuming an OS reset already cleared the UEFI marker — it doesn't.

---
## Troubleshooting Steps (by phase)

### Phase 1: Eligibility and prerequisites
1. Confirm device preparation (not classic Autopilot) is the deployment mechanism in use.
2. Confirm tenant licensing, OS build/edition, and TPM state per Validation Steps 2–3.
3. Rule out VM usage immediately — there is no supported path forward for a virtual machine regardless of any other configuration.

### Phase 2: Pre-association and association
1. Confirm the device was pre-associated (CSV upload completed in Intune) — check the Devices blade.
2. Confirm the device actually connected to a network during OOBE, or that a technician manually triggered association immediately after pre-associating.
3. If the OOBE window has closed without association occurring, the only remediation is re-running OOBE (typically via reset) — there's no way to retroactively associate an already-enrolled device.

### Phase 3: Post-association behavior
1. For OOBE customization gaps, confirm Associated state first, then re-verify the specific policy toggle and any hard prerequisite (company branding for "Hide change account options").
2. For device-targeted policy gaps, confirm the policy assignment target (device vs. user group) matches what's expected, and that the device shows Associated.
3. For device-naming issues, validate template syntax (63-char limit, allowed characters, not all-numeric).

### Phase 4: Decommission / tenant transfer
1. Confirm intent: is this device being retired, resold, or moved to a different tenant?
2. Run the on-device PowerShell association-removal script — this is the only supported removal path.
3. Confirm removal succeeded by checking the device no longer shows an Associated state after its next OOBE/enrollment attempt (either in this tenant or, for a transfer, that the receiving tenant can now successfully pre-associate it).
4. Bake this step into standard hardware off-boarding/decommission checklists — it is easy to miss since a plain OS reset gives no visible indication that the tenant binding is still present.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Stand up device association for a new device-prep deployment</summary>

1. Confirm tenant licensing and target device hardware/OS eligibility (Validation Steps 2–3).
2. Create or select the device preparation policy with the desired deployment and OOBE experience settings.
3. During OOBE on the target device, export device information to produce the identifying CSV.
4. In Intune, pre-associate the device by uploading the CSV; assign the device-prep policy at this step if device-targeted assignment is the goal.
5. Ensure the device connects to a network during OOBE (or have a technician manually trigger association immediately after pre-associating) to complete the Associate step.
6. Validate via **Devices > Enrollment > Device association > Devices** that the device reaches **Associated** state before assuming the deployment succeeded.
7. Confirm post-enrollment behavior: device-targeted policy applied, corporate-owned flag set, OOBE customizations honored.

**Rollback:** if the deployment needs to be aborted before enrollment completes, no association-specific rollback is required beyond standard device-prep policy unassignment; if already associated and the device needs releasing, use Playbook 2.

</details>

<details><summary>Playbook 2 — Decommission or transfer an associated device</summary>

1. Confirm the device's current association state in the Devices blade.
2. Obtain and run the documented on-device PowerShell removal script with appropriate local/admin privileges — this must execute **on the physical device**, not from Intune or Graph.
3. Do **not** rely on a factory reset or OS reinstall alone to clear the association — the UEFI marker is firmware-level and will persist.
4. If transferring to a different tenant, confirm removal completed successfully before the receiving tenant attempts to pre-associate the same device — a lingering marker from the prior tenant will block or produce unexpected behavior otherwise.
5. Document the removal (serial number, date, technician) for audit purposes, particularly for MSP client off-boarding scenarios involving hardware buy-back or resale.

**Rollback:** N/A — this operation is itself the corrective/release action; re-associating with the same or a different tenant afterward follows Playbook 1 as normal.

</details>

<details><summary>Playbook 3 — Diagnose and resolve a stuck Pre-associated device</summary>

1. Confirm the device is still in OOBE (or can be returned to it via reset) — association can only complete during this window.
2. Confirm network connectivity is available and functioning during OOBE (correct SSID/credentials for Wi-Fi, or a live Ethernet port).
3. If network connectivity during OOBE is confirmed working and the device still doesn't associate automatically, have a technician manually trigger association immediately after the Intune-side pre-association step, while the device remains in OOBE.
4. If the device has already passed OOBE and enrolled without associating, treat as Playbook 1 from scratch after a reset — there's no partial-completion recovery path.

**Rollback:** N/A — diagnostic/recovery flow, no destructive action.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Windows Autopilot device association evidence for escalation
.NOTES     Run locally on the affected device for the TPM/OS sections;
           run with Intune Graph read scopes for the tenant-level sections.
           Output saved to current directory.
#>

$output = [System.Collections.Generic.List[string]]::new()
$ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC" -AsUTC
$out    = ".\DeviceAssociationEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).txt"

function Add-Section {
    param([string]$Title, [scriptblock]$Body)
    $output.Add("=" * 60)
    $output.Add("  $Title")
    $output.Add("=" * 60)
    try { $output.Add((&$Body | Out-String).Trim()) }
    catch { $output.Add("ERROR: $($_.Exception.Message)") }
    $output.Add("")
}

Add-Section "Collection metadata" {
    "Collected : $ts"
    "Device    : $env:COMPUTERNAME"
}

Add-Section "TPM state" {
    Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, TpmRestrictedMode, ManufacturerVersion | Format-List
}

Add-Section "OS build and servicing state" {
    Get-ComputerInfo | Select-Object OsBuildNumber, WindowsProductName, WindowsVersion | Format-List
    Get-HotFix -Id KB5120998 -ErrorAction SilentlyContinue | Select-Object HotFixID, InstalledOn
}

Add-Section "Hardware type (physical vs. virtual)" {
    Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object Manufacturer, Model, SystemFamily
}

Add-Section "Device preparation policies in tenant (requires Graph auth)" {
    try {
        Get-MgBetaDeviceManagementAutopilotDevicePreparationPolicy -ErrorAction Stop |
            Select-Object Id, DisplayName | Format-Table -AutoSize | Out-String
    } catch {
        "Not connected to Graph, or insufficient permissions — run Connect-MgGraph with DeviceManagementConfiguration.Read.All"
    }
}

$output | Set-Content -Path $out -Encoding UTF8
Write-Host "Evidence saved to: $out" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check TPM state | `Get-Tpm \| Select TpmPresent,TpmReady,TpmEnabled,TpmRestrictedMode` |
| Check OS build number | `Get-ComputerInfo \| Select OsBuildNumber` |
| Check for required servicing update | `Get-HotFix -Id KB5120998 -ErrorAction SilentlyContinue` |
| Confirm physical vs. virtual hardware | `Get-CimInstance Win32_ComputerSystem \| Select Manufacturer,Model` |
| List device preparation policies (Graph, beta) | `Get-MgBetaDeviceManagementAutopilotDevicePreparationPolicy` |
| Check tenant subscribed SKUs | `Get-MgSubscribedSku` |
| Device association state (portal only, no stable Graph read as of this writing) | Intune admin center > Devices > Enrollment > Device association > Devices |
| Device preparation policy authoring | Intune admin center > Devices > Enrollment > Device preparation policies |
| Company branding prerequisite check | Entra admin center > Company branding |

---
## 🎓 Learning Pointers

- **Device association is a physical-firmware-level trust mechanism, not a cloud-only relationship — treat it accordingly for decommission planning.** The UEFI marker persists across a standard OS reset or reinstall and can only be cleared by an on-device PowerShell script; a client's existing "wipe and reissue" hardware process almost certainly does not release it. [Remove association from a device](https://learn.microsoft.com/en-us/autopilot/device-preparation/device-association/remove-association)

- **Pre-associate and associate are genuinely two separate events with a real gap between them** — the Intune-side step is a stored intent, not a binding. Every association-gated behavior (device-targeted policy, OOBE customization, corporate-owned marking) depends on the device independently completing the associate step during OOBE. [Overview of Windows Autopilot device association](https://learn.microsoft.com/en-us/autopilot/device-preparation/device-association/overview)

- **TPM 2.0 and physical hardware are absolute requirements with no fallback path** — Reduced Functionality Mode and virtual machines are both hard-blocked, not degraded-but-working states. This is worth confirming before any deeper diagnosis, since it eliminates an entire class of tickets in one command. [Requirements for Windows Autopilot device association](https://learn.microsoft.com/en-us/autopilot/device-preparation/device-association/requirements)

- **Device association materially changes what's possible with device-preparation policy targeting** — moving from purely user-group-based assignment to genuine per-device targeting, which matters for any client where one user routinely enrolls multiple devices (e.g., a laptop plus a secondary device) that need different configurations. [Introducing device association for Windows Autopilot device preparation](https://techcommunity.microsoft.com/blog/intunecustomersuccess/introducing-device-association-for-windows-autopilot-device-preparation/4550603)

- **This is architecturally separate from classic Autopilot's hardware-hash registration** — don't conflate the two when scoping a deployment or writing a runbook cross-reference. A tenant can run both models simultaneously for different device populations. [Overview of Windows Autopilot device association](https://learn.microsoft.com/en-us/autopilot/device-preparation/device-association/overview)

- **Windows 365 Cloud PCs are deliberately excluded, not an oversight** — if a ticket asks why a Cloud PC won't associate, the answer is that it's already handled by Windows 365's own trusted-device model and doesn't need this mechanism. [Overview of Windows Autopilot device association](https://learn.microsoft.com/en-us/autopilot/device-preparation/device-association/overview)
