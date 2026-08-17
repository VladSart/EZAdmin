# Windows Autopilot Pre-Provisioning (White Glove) — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **Windows Autopilot for pre-provisioned deployment** — the current Microsoft terminology for the scenario historically branded **White Glove**. All references in Microsoft's own current documentation have been renamed to "pre-provisioning," and this file uses both names interchangeably since "White Glove" remains the term most commonly heard in the field.

Covers: the Technician flow and User flow architecture, TPM-attestation-driven eligibility, device-vs-user targeting during each phase, Entra join and Entra hybrid join variants, the timing constraints between the two flows, and the interaction with Enrollment Status Page (ESP).

**Assumes:**
- Intune is the MDM authority (pre-provisioned deployments require currently supported Windows versions managed via Microsoft Intune — no ConfigMgr-only path exists for this scenario)
- Devices are physical hardware with TPM 2.0 and device attestation support — virtual machines are explicitly unsupported
- Existing Windows Autopilot user-driven scenarios (Entra join or Entra hybrid join) already work in the tenant before attempting pre-provisioning — pre-provisioning builds directly on top of user-driven mode and cannot succeed if the underlying scenario doesn't

**Not covered:** standard user-driven Autopilot enrollment without pre-provisioning (see `HybridJoin-Autopilot-A.md`/`-B.md` and general enrollment coverage), Windows Autopilot self-deploying mode for kiosk/shared-device scenarios (a related but distinct scenario that pre-provisioning's Technician flow borrows its provisioning-state mechanics from, not the same thing), Windows Autopilot device preparation/APDP (the newer Entra-join-only mode built on Enrollment Time Grouping — see `DevicePreparation-A.md`/`-B.md`; explicitly recommended by Microsoft when Win32 and LOB apps both need to target the same device, since pre-provisioning doesn't support mixing the two), general ESP tuning outside the pre-provisioning context (see `ESP-Stuck-A.md`/`-B.md`), and TPM attestation failures outside this scenario (see `TPM-Attestation-A.md`/`-B.md`, though the underlying mechanism is the same one this file's Technician flow depends on).

---
## How It Works

<details><summary>Full architecture</summary>

### Why pre-provisioning exists

Standard Windows Autopilot user-driven mode is fast, but the end user still has to sit through OS finalization, policy application, and app installation on first boot. Pre-provisioning splits that work in two: the time-consuming portion (device-targeted policies, certs, and apps) is done in advance by IT staff, a services partner, or an OEM, in a **Technician flow**, and the device is resealed to OOBE. The end user then completes a much shorter **User flow** — sign in, receive any remaining user-targeted content, reach the desktop.

From the end user's perspective, the experience is still the standard Autopilot user-driven flow. What changes is how much work is already done by the time they open the box.

### Two scenarios, same two-flow shape

Pre-provisioning supports exactly two join scenarios, each following the same Technician-flow-then-User-flow shape:
- **Entra join** — the device joins directly to the Entra tenant. No on-premises dependency at any point.
- **Entra hybrid join** — the device joins an on-premises Active Directory domain and is separately registered with Entra ID. Microsoft explicitly recommends against deploying *new* devices as hybrid joined (including via Autopilot) in favor of cloud-native Entra join, but hybrid join remains a fully supported pre-provisioning scenario for organizations still transitioning.

A structurally important detail for the hybrid case: because the OEM or vendor technician typically has no access to the end customer's on-premises domain infrastructure, the Technician flow **postpones the reboot that would normally be needed to contact a domain controller**. The device is resealed before that point, and the domain network is only actually contacted once the device is unboxed on-premises by the end user during the User flow. This is a deliberate architectural choice, not a limitation being worked around.

### Technician flow, step by step

1. Boot the device to the first OOBE screen (language/locale/region selection, or the Entra sign-in page).
2. **Do not select Next.** Press the Windows key five times to open a hidden options dialog, then select **Windows Autopilot provisioning** → **Continue**.
3. The **Windows Autopilot Configuration** screen displays the assigned profile, organization name, pre-assigned user (if any), and a QR code encoding a unique device identifier (useful for looking the device up in Intune to make live changes — assign a user, add it to a group for targeting).
4. Select **Refresh** if any changes were made in Intune, to redownload the updated profile.
5. Select **Provision**.
6. Under the hood, this inherits its provisioning-state mechanics from **self-deploying mode**: the ESP holds the device in a provisioning state so the user (or, here, the technician) cannot proceed to the desktop until software/configuration finishes applying. This has a direct operational consequence — **if ESP is disabled**, the Reseal button can appear before the technician flow's provisioning is actually complete, since nothing is holding the state open. The success screen only validates that enrollment succeeded, not that the technician flow content fully applied.
7. If it completes: a success screen shows the same profile/org/QR-code details plus elapsed time. Select **Reseal** to shut the device down for shipping.
8. If it fails: an error screen shows the same details. Diagnostic logs can be collected, and the device reset to retry from scratch.

### What actually applies during the Technician flow — the device/user targeting boundary

This is the single most consequential architectural detail in the entire scenario. During the Technician flow, Intune applies:
- **All device-targeted policies** — certificates, security templates, general configuration settings, anything targeted at the device object.
- **Win32 or LOB apps**, but only if both of the following are true: (a) the app is configured to install in **device context**, and (b) it's assigned either directly to the device, or to the **user pre-assigned to the Autopilot device** (still evaluated in device context — a pre-assigned user doesn't mean user-context policies apply yet).

Everything else — genuinely user-targeted policies and apps, evaluated against the signed-in user's own identity rather than the pre-assigned placeholder — is **not applied until the User flow**, after the real end user signs in. This is why an app assigned to "All Users" rather than to the device or pre-assigned user will never show up during the Technician flow no matter how long the technician waits; it isn't broken, it's out of scope for this phase by design.

**A hard platform constraint follows from this:** Microsoft explicitly states not to target both a Win32 app and a LOB app to the same device in this scenario. If a deployment genuinely needs both app types on one device, the documented path is **Windows Autopilot device preparation** instead (see `DevicePreparation-A.md`), not working around the limitation inside pre-provisioning.

### User flow, step by step

1. Power on the resealed device.
2. Select language, locale, keyboard.
3. Connect to a network. Internet access is always required; for Entra hybrid join, connectivity to a domain controller is also required at this stage (the postponed reboot from the Technician flow finally happens here).
4. Entra join: sign in on the branded sign-on screen with Entra credentials. Entra hybrid join: the device reboots, then Active Directory credentials are entered (Entra credentials may also be prompted in some hybrid configurations, e.g., when ADFS isn't in use).
5. More policies and apps deliver, tracked by ESP — this time as **both the device ESP re-running and the user ESP running together**, so any device-targeted content assigned *after* the Technician flow completed also gets a chance to apply here.
6. Desktop access once ESP completes.

### The three timing constraints that generate most "it broke after handoff" tickets

None of the following are bugs — they are documented, deliberate constraints of the two-flow architecture:

1. **Wait at least 90 minutes** between Technician flow completion and starting the User flow, so authentication tokens refresh correctly across the gap. In real-world shipping timelines (days between provisioning and unboxing) this is a non-issue; it mainly bites lab/demo/test cycles where both flows are run back-to-back on the same device.
2. **Run the User flow within 6 months** of Technician flow completion. Beyond that window, the certificate used by the Intune Management Extension (IME) during the Technician phase can expire, producing detection-handler failures like `[Win32App][DetectionActionHandler] Detection for policy with id: <policy_id> resulted in action status: Failed and detection state: NotComputed`. A device that hits this needs a clean re-provision (delete the Intune device record, start over), not an in-place repair — the expired trust relationship isn't something a policy resync fixes.
3. **Compliance resets when the User flow starts.** A device can correctly show compliant in Entra ID right after the Technician flow, then flip to noncompliant the moment the User flow begins, purely because compliance state re-evaluates fresh at that point. This is expected transitional behavior — give it time to re-evaluate before treating it as a fault.

### Re-enrollment is a one-way door

A device **cannot automatically re-enroll through Windows Autopilot after an initial pre-provisioned deployment.** There's no supported "reset and retry in place" path the way there might be for a simple enrollment failure. The only supported recovery is deleting the device record in the Intune admin center (**Devices > All devices** → select → **Delete**), after which the device can go through the pre-provisioning process again from a clean state. Deleting the Intune device record does not touch the underlying Autopilot registration (hash import/profile assignment) — the device remains a registered Autopilot device throughout.

</details>

---
## Dependency Stack

```
Physical device with TPM 2.0 + device attestation (VMs unsupported)
  └── Currently supported Windows, Pro/Enterprise/Education edition
        └── Intune subscription + tenant reachable over the network
              └── Windows Autopilot hardware hash imported + profile assigned
                    └── Autopilot profile has "Allow pre-provisioned deployment" enabled
                          └── ESP profile targeted to the device (holds provisioning state open)
                                └── Existing user-driven Autopilot scenario already functional
                                      ├── Entra join path (no on-prem dependency)
                                      └── Entra hybrid join path
                                            ├── Intune Connector for AD, running, correct OU rights
                                            └── Entra Connect sync completes before registration finishes
                    TECHNICIAN FLOW
                    ├── TPM attestation succeeds (self-deploying-mode mechanics)
                    ├── Entra/hybrid join completes
                    ├── MDM enrollment completes
                    └── Device ESP: device-targeted policies + device-context Win32/LOB apps
                          (never both Win32 AND LOB targeted to the same device)
                    [RESEAL — device shipped]
                    ≥90 minutes, ≤6 months elapsed
                    USER FLOW
                    ├── Network + (hybrid only) domain controller reachable
                    ├── End-user sign-in (Entra or AD credentials)
                    ├── Device ESP RERUNS + User ESP runs together
                    └── User-targeted policies/apps apply
                          └── Compliance re-evaluates (transitional noncompliant state expected)
                                └── Desktop access
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|--------------------|-------|
| Red/error screen appears almost immediately after **Provision** | TPM attestation failure — outdated firmware, uncleared TPM, or hardware-hash/hardware mismatch | `Get-Tpm`, TPM attestation endpoint reachability |
| Error `0x800705B4` after a long wait | ESP timeout — a required app/policy never completed within the configured window | ESP tracking registry keys, IME log |
| Stuck at "Joining your organization's network" | Hybrid join branch — Intune Connector down, OU permission gap, or Entra Connect sync lag | Connector service status, `dsacls`, sync cycle timestamp |
| Error `0x81036502` | Device not found in the Autopilot service — hash not imported/synced, or profile not assigned | `Get-AutopilotDevice` |
| Reseal button appears suspiciously fast, device later shows incomplete config | ESP was disabled for this profile, so nothing held the provisioning state open | Autopilot profile → ESP assignment |
| App assigned to "All Users" never installs during Technician flow | Expected — only device-targeted (or device-context pre-assigned-user) content applies before Reseal | Confirm app assignment target and install context |
| Both a Win32 app and a LOB app fail/conflict on the same device during ESP | Unsupported mixed targeting for this scenario | Review app assignments; consider device preparation instead |
| User flow fails with IME detection-handler errors months after shipping | >6-month gap between Technician and User flow — IME certificate expired | Compare Technician-flow completion date vs. today |
| Device shows compliant, then noncompliant right after first sign-in | Expected — compliance resets and re-evaluates at User flow start | Wait one compliance evaluation cycle before escalating |
| Failed/completed device won't go through pre-provisioning again | By design — no automatic re-enrollment after an initial pre-provisioned deployment | Delete the Intune device record, retry |
| SSL-inspecting proxy in place, multiple unrelated-looking failures | TLS inspection breaking certificate pinning for Microsoft enrollment/attestation endpoints | Test the documented endpoint list from a device behind the proxy |

---
## Validation Steps

**1. Confirm hardware eligibility**
```powershell
Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled
```
Expected: both `True`. A VM will always fail this scenario entirely — there's no supported path around the physical-hardware/TPM requirement.

**2. Confirm the Autopilot profile is configured for pre-provisioning**
In Intune: **Devices > Enrollment > Windows Autopilot deployment profiles** → the assigned profile → confirm pre-provisioning is enabled for the intended join type (Entra or hybrid).
Expected: the Technician flow option appears at OOBE after pressing the Windows key five times. If it doesn't appear at all, the profile itself is the gap — not a device-side fault.

**3. Confirm ESP targeting**
```powershell
reg query "HKLM\SOFTWARE\Microsoft\Enrollments" /s | findstr "EnrollmentState"
```
Expected: an active enrollment state entry exists. No ESP profile means no state is held open during provisioning.

**4. Confirm required network endpoints are reachable**
```powershell
Test-NetConnection ztd.dds.microsoft.com -Port 443
Test-NetConnection cs.dds.microsoft.com -Port 443
Test-NetConnection login.microsoftonline.com -Port 443
Test-NetConnection enterpriseregistration.windows.net -Port 443
Test-NetConnection enrollment.manage.microsoft.com -Port 443
Test-NetConnection ekcert.spserv.microsoft.com -Port 443
```
Expected: `TcpTestSucceeded = True` across the board. Any failure on the TPM-attestation-related endpoint specifically points at Fix 1 in the hotfix runbook before assuming a hardware issue.

**5. Confirm existing user-driven Autopilot works independently of pre-provisioning**
Deploy one device through the standard user-driven flow for the same profile/join type. If that fails, pre-provisioning cannot succeed either — it builds directly on top of user-driven mode.

**6. If hybrid join, confirm the Intune Connector chain**
```powershell
Get-Service "Intune Connector*" | Select-Object Name, Status
```
Expected: `Running`. Cross-reference the connector's own event log (`Application and Services > Microsoft > Intune > ODJConnectorSvc`) for recent errors.

**7. Confirm elapsed time between flows before troubleshooting a User-flow failure as a fault**
Compare the Technician flow completion timestamp (visible on the success screen, or in Intune's device enrollment timeline) against the current date — apply the 90-minute minimum and 6-month maximum windows before assuming something is actually broken.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Pre-flight (before attempting Technician flow at all)

1. Confirm TPM 2.0 present and ready.
2. Confirm the device's hardware hash is imported and the Autopilot profile shows `Assigned`.
3. Confirm the assigned profile has pre-provisioning enabled for the correct join type.
4. Confirm an ESP profile targets the device.
5. Confirm network reachability to all documented endpoints, especially if behind a corporate proxy with TLS inspection.

### Phase 2 — Technician Flow Failure

1. Read the exact error screen text/code — this alone usually places the failure at TPM attestation, join, or ESP.
2. If TPM attestation: work through Fix 1 in the hotfix runbook (firmware, TPM state, hash-vs-hardware match, endpoint reachability).
3. If join (hybrid specifically): verify the Intune Connector chain and Entra Connect sync state.
4. If ESP: identify the specific blocking app/policy via the ESP tracking registry keys and the IME log, and determine whether it's a genuine failure vs. simply slow.

### Phase 3 — Between Flows (shipping window)

1. No action needed under normal timelines. If testing in a lab, deliberately wait ≥90 minutes before running User flow.
2. If more than 6 months will elapse before the device reaches the end user, flag this as a risk up front — the IME certificate expiry is a real, date-driven failure mode, not a hypothetical.

### Phase 4 — User Flow Failure

1. Confirm network (and, for hybrid, domain controller) connectivity from the unboxing location.
2. If sign-in fails, treat as a standard Entra/AD authentication issue (see `EntraID/Troubleshooting/PRT-Issues-A.md` or `HybridJoin-Autopilot-A.md`), not a pre-provisioning-specific fault.
3. If ESP fails during User flow, remember device ESP is rerunning here in addition to user ESP — check both tracks, not just user-targeted content.
4. If compliance shows unexpectedly noncompliant, wait one evaluation cycle before escalating — this is expected transitional behavior.

### Phase 5 — Retry / Recovery

1. Confirm whether this device has already completed (successfully or not) one full pre-provisioning attempt.
2. If yes, delete the Intune device record before attempting again — there is no automatic re-enrollment path.
3. Re-verify Phase 1 pre-flight checks before the retry, since the original failure may have been caused by a condition that's since changed (profile edit, network change, etc.).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standing up pre-provisioning for the first time in a tenant</summary>

```powershell
# 1. Confirm standard user-driven Autopilot already works for the target join type
#    (deploy one test device through the normal flow first — do not skip this)

# 2. Confirm hardware hash import and profile assignment for the fleet
Get-AutopilotDevice | Select-Object SerialNumber, GroupTag, ProfileStatus

# 3. In Intune: edit the target Autopilot deployment profile, enable pre-provisioning
#    for the correct join type (Entra join or Entra hybrid join)

# 4. Confirm an ESP profile is assigned to the same device scope, tracking at minimum
#    the Win32/LOB apps intended to install during the Technician flow

# 5. Review every app intended for device-context Technician-flow install:
#    - Confirm install context = Device, not User
#    - Confirm no device has both a Win32 AND a LOB app targeted to it
#    - Confirm detection rules are validated against a real successful install
```
Rollback: disabling pre-provisioning on the profile reverts affected devices to standard user-driven behavior; already-provisioned devices are unaffected retroactively.

</details>

<details><summary>Playbook 2 — Recovering a fleet-wide stall traced to a single bad app</summary>

Use when many devices are timing out at the same ESP stage during Technician flow.

```powershell
# On one representative stuck device:
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Tail 200 |
    Select-String "Failed|Detection"

# Cross-reference the failing app ID against Intune's Enrollment Status Page report blade
# to confirm the same app is the common blocker across multiple affected devices
```
1. If confirmed as a bad detection rule or broken installer, fix the app in Intune (this does not require touching any already-stuck device individually).
2. For devices already stuck mid-ESP, they will pick up the corrected app definition on their next retry cycle within the existing timeout window — no manual per-device intervention needed unless the timeout has already elapsed.
3. For devices that already hit timeout and errored out, they must be treated as a fresh retry per Phase 5 above (delete device record, re-provision).

**Rollback:** Reverting an app change back to its broken state is possible but pointless mid-incident — no rollback concern here beyond standard app-version change management.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Windows Autopilot pre-provisioning diagnostic evidence for escalation
.NOTES     Run from the affected device (Shift+F10 during a stuck OOBE/ESP screen, or a live desktop)
#>

$outputPath = "C:\WhiteGlove_Evidence_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

# Full Autopilot diagnostic bundle
mdmdiagnosticstool.exe -area Autopilot -cab "$outputPath\autopilot-diag.cab"

# TPM state
Get-Tpm | Format-List | Out-File "$outputPath\tpm-state.txt"

# Device identity state
dsregcmd /status | Out-File "$outputPath\dsregcmd-status.txt"

# Autopilot + MDM enrollment event logs
wevtutil epl "Microsoft-Windows-Provisioning-Diagnostics-Provider/AutoPilot" "$outputPath\autopilot-events.evtx" -ErrorAction SilentlyContinue
wevtutil epl "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" "$outputPath\mdm-events.evtx" -ErrorAction SilentlyContinue

# ESP tracking registry state
reg export "HKLM\SOFTWARE\Microsoft\Enrollments" "$outputPath\enrollments-reg.reg" /y 2>$null
reg export "HKLM\SOFTWARE\Microsoft\Windows\Autopilot\EnrollmentStatusTracking" "$outputPath\esp-tracking-reg.reg" /y 2>$null

# Intune Management Extension log (Win32 app install detail)
Copy-Item "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" "$outputPath\" -ErrorAction SilentlyContinue

# Network endpoint reachability snapshot
$endpoints = @("ztd.dds.microsoft.com","cs.dds.microsoft.com","login.microsoftonline.com",
               "enterpriseregistration.windows.net","enrollment.manage.microsoft.com","ekcert.spserv.microsoft.com")
$endpoints | ForEach-Object {
    [PSCustomObject]@{ Endpoint = $_; Reachable = (Test-NetConnection $_ -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded }
} | Export-Csv "$outputPath\endpoint-reachability.csv" -NoTypeInformation

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# TPM readiness
Get-Tpm | Select TpmPresent,TpmReady,TpmEnabled

# Device identity / join state
dsregcmd /status

# ESP tracking state (device-local)
reg query "HKLM\SOFTWARE\Microsoft\Windows\Autopilot\EnrollmentStatusTracking" /s
reg query "HKLM\SOFTWARE\Microsoft\Enrollments" /s | findstr EnrollmentState

# Full Autopilot diagnostic bundle
mdmdiagnosticstool.exe -area Autopilot -cab C:\diag.cab

# Autopilot event log
Get-WinEvent -LogName "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot" -MaxEvents 30

# IME (Win32 app install) log
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Tail 200

# Device lookup in the Autopilot service (from an admin workstation with the Graph/Autopilot module)
Get-AutopilotDevice -SerialNumber "<serial>"

# Endpoint reachability
Test-NetConnection ztd.dds.microsoft.com -Port 443
Test-NetConnection ekcert.spserv.microsoft.com -Port 443

# Hybrid join — Intune Connector service
Get-Service "Intune Connector*"

# Hybrid join — force Entra Connect delta sync (on the sync server)
Start-ADSyncSyncCycle -PolicyType Delta

# Retry a completed/failed pre-provisioned device — delete via Intune admin center
# Devices > All devices > select device(s) > Delete (no PowerShell-only equivalent documented)
```

---
## 🎓 Learning Pointers

- **The device/user targeting boundary is the single most important architectural fact in this topic.** Only device-targeted content (and device-context apps assigned to the pre-assigned user) applies during the Technician flow; everything genuinely user-targeted waits for the User flow's sign-in. Most "why didn't my app install during provisioning" tickets trace back to this boundary, not a fault. Reference: [Windows Autopilot for pre-provisioned deployment](https://learn.microsoft.com/en-us/autopilot/pre-provision)
- **Pre-provisioning inherits self-deploying mode's provisioning-state mechanics**, which is why TPM 2.0 and device attestation are non-negotiable requirements here, and why a disabled ESP profile lets the Reseal button appear before content actually finished applying. Reference: [Windows Autopilot self-deploying mode](https://learn.microsoft.com/en-us/autopilot/self-deploying)
- **The 90-minute and 6-month timing windows between Technician and User flow are documented platform constraints, not folklore** — treat them as real inputs to deployment planning (especially the 6-month IME certificate expiry) rather than something to discover mid-incident.
- **Re-enrollment after an initial pre-provisioned attempt is a one-way door by design** — build "delete the Intune device record" into any team's standard retry procedure up front, since there is no in-place reset path.
- **Win32 + LOB app mixed targeting on the same device is explicitly unsupported in this scenario** — Windows Autopilot device preparation (`DevicePreparation-A.md`) is Microsoft's own documented alternative when a deployment genuinely needs both app types on one device.
- Community deep-dive worth bookmarking for a faster diagnostic pass than manually parsing registry/event-log state: **Get-AutopilotDiagnosticsCommunity** on the PowerShell Gallery — resolves policy/app GUIDs to human-readable names with `-Online` and provides a chronological timeline of the enrollment flow.
