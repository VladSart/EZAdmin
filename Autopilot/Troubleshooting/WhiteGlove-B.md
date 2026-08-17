# Windows Autopilot Pre-Provisioning (White Glove) — Hotfix Runbook (Mode B: Ops)
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

Run from an elevated command prompt (`Shift+F10` during OOBE/ESP, or a live desktop):

```powershell
# 1. Where in the flow did it fail? (device on the failure/error screen, or a running OS)
Get-WinEvent -LogName "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot" -MaxEvents 30 |
    Select-Object TimeCreated, Id, Message | Format-Table -Wrap

# 2. TPM readiness — Technician flow cannot even start without a healthy TPM
Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, ManufacturerVersion

# 3. Device identity state — did Entra join / hybrid join complete before the failure?
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|AzureAdPrt"

# 4. ESP tracking state — what is the device still waiting on?
reg query "HKLM\SOFTWARE\Microsoft\Windows\Autopilot\EnrollmentStatusTracking" /s

# 5. Collect the full Autopilot diagnostic bundle (do this before resetting anything)
mdmdiagnosticstool.exe -area Autopilot -cab C:\WhiteGlove_Diag.cab
```

| Result | Interpretation |
|---|---|
| Red/error screen appears within seconds of pressing **Provision** | TPM attestation failure — device never reached ESP. Go to [Fix 1](#common-fix-paths). |
| Error `0x800705B4` after a long wait on the tracking screen | ESP timeout — a device-targeted app/policy never completed. Go to [Fix 2](#common-fix-paths). |
| Stuck at "Joining your organization's network" | Hybrid join branch — Intune Connector or Entra Connect sync lag. Go to [Fix 3](#common-fix-paths). |
| Error `0x81036502` | Device not found in the Autopilot service — hash never imported/synced, or profile not assigned. Go to [Fix 4](#common-fix-paths). |
| Technician flow succeeded, User flow now failing/noncompliant | Expected transitional state, timing issue, or stale IME cert. Go to [Fix 5](#common-fix-paths). |
| Win32/LOB app fails detection during ESP | Detection rule mismatch, or Win32+LOB apps both targeted to the same device. Go to [Fix 6](#common-fix-paths). |
| Device won't re-enroll after a failed/completed pre-provisioning attempt | Expected — pre-provisioned devices never auto re-enroll. Go to [Fix 7](#common-fix-paths). |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Windows Autopilot for pre-provisioned deployment
  └── Physical device (VMs unsupported) with TPM 2.0 + attestation
        └── TPM attestation succeeds (uses the same mechanism as self-deploying mode)
              └── Entra ID join OR Entra hybrid join completes
                    ├── Entra join: device registers directly, no on-prem dependency
                    └── Hybrid join: Intune Connector creates AD computer object,
                          waits for Entra Connect sync before registration finishes
                          └── MDM enrollment (Intune) succeeds
                                └── Device ESP runs (Technician flow)
                                      ├── Device-targeted security/cert/network policies apply
                                      └── Win32/LOB apps in DEVICE context install
                                            (only if assigned to device, or to the
                                             pre-assigned user in device context —
                                             user-context policies wait for sign-in)
                                            └── Technician selects Reseal
                                                  └── [Device shipped to end user]
                                                        └── User flow: power on, sign in
                                                              └── Compliance resets, then
                                                                  device ESP RERUNS +
                                                                  user ESP runs together
                                                                    └── User-targeted apps/
                                                                        policies now apply
                                                                          └── Desktop access
```

Skipping or breaking any layer above the failure point stalls everything below it — a broken TPM attestation, for example, never even reaches the ESP layer.

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the device is even eligible for pre-provisioning**
```powershell
Get-Tpm | Format-List
```
Expected: `TpmPresent = True`, `TpmReady = True`. If `False`, this is a hardware/BIOS issue — pre-provisioning cannot proceed at all (self-deploying-mode requirement, no override exists).

**2. Confirm the Autopilot profile allows pre-provisioning**
In the Intune admin center: **Devices > Enrollment > Windows Autopilot deployment profiles** → open the assigned profile → confirm **Convert all targeted devices to Autopilot** and **Allow pre-provisioned deployment** are both set correctly for this device's scenario. This is a per-profile toggle — a profile built for standard user-driven deployment will not offer the Technician flow option at OOBE at all.

**3. Confirm ESP is targeted to the device**
```powershell
reg query "HKLM\SOFTWARE\Microsoft\Enrollments" /s | findstr "EnrollmentState"
```
No ESP profile assigned to the device means the Technician flow has nothing to hold the provisioning state open — the Reseal button can appear before software/config actually finished applying.

**4. Confirm network reachability to Autopilot/TPM-attestation endpoints**
```powershell
Test-NetConnection ztd.dds.microsoft.com -Port 443
Test-NetConnection login.microsoftonline.com -Port 443
Test-NetConnection enrollment.manage.microsoft.com -Port 443
Test-NetConnection ekcert.spserv.microsoft.com -Port 443   # TPM attestation (Microsoft-hosted EK cert)
```
Expected: `TcpTestSucceeded : True` on all. A failure here — especially on the TPM attestation endpoint — is the single most common cause of an attestation failure that looks like a hardware fault but isn't.

**5. Read the actual blocking item off the ESP tracking state**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 50 |
    Where-Object { $_.Message -match "ESP|Enrollment Status" } |
    Select-Object TimeCreated, Id, Message
```
Cross-reference the app/policy GUID reported here against Intune's own **Enrollment Status Page** report blade for that device to identify exactly what's stuck.

**6. If Win32 app install is the blocker, check the Intune Management Extension log**
```powershell
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Tail 100
```

---
## Common Fix Paths

<details><summary>Fix 1 — TPM attestation failure at the very start of Technician flow</summary>

```powershell
# Confirm TPM is present, enabled, and ready
Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, ManufacturerVersion, ManufacturerVersionFull20

# Confirm the device can reach its TPM manufacturer's attestation endpoint
# (endpoint differs by TPM vendor — check all three if unsure)
Test-NetConnection ekcert.spserv.microsoft.com -Port 443    # Microsoft-hosted EK certs
Test-NetConnection ekop.intel.com -Port 443                 # Intel-manufactured TPMs
Test-NetConnection ftpm.amd.com -Port 443                   # AMD fTPM
```
Common root causes, in order of frequency:
1. Outdated TPM firmware (especially common on refurbished Lenovo/HP stock) — update via the OEM's firmware tool or BIOS/UEFI update, then retry.
2. TPM holds stale keys from a prior enrollment (reused/refurbished device) — clear the TPM (`tpm.msc` → **Clear TPM**, or via BIOS/UEFI), then retry.
3. Motherboard/TPM module was physically replaced since the hardware hash was captured — the hash no longer matches. Delete the Autopilot device record in Intune and re-capture/re-import the hash.
4. Attestation endpoint blocked by firewall/proxy/SSL inspection — see Fix 3's network guidance below; the same endpoint list applies.

**Rollback:** None of these steps are destructive to existing tenant data. Clearing the TPM invalidates any BitLocker keys tied to that TPM on a device that was previously in production — confirm this is a fresh/reset device before clearing.

</details>

<details><summary>Fix 2 — ESP timeout (0x800705B4) during Technician flow</summary>

```powershell
# On the stuck device (Shift+F10), identify exactly what's still tracked
reg query "HKLM\SOFTWARE\Microsoft\Windows\Autopilot\EnrollmentStatusTracking" /s

# Check IME log for the specific app that's failing to install/detect
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Tail 200 |
    Select-String "Failed|Error|Detection"
```
Remediation, cheapest first:
1. If a specific Win32 app's **detection rule** doesn't match its actual installed state, the ESP retries it in a loop until timeout — fix the detection rule (or the install itself), not the timeout value.
2. If the app is simply large/slow (e.g., Microsoft 365 Apps) and legitimately needs more time, raise the ESP timeout from Intune's default (60 min) to a realistic value for the tracked app set — **treat this as a stopgap, not a fix**, since it just delays the same failure if the underlying install issue is real.
3. Move genuinely non-blocking apps out of "Required" tracking (either off ESP entirely, or onto the user ESP instead of the device ESP) so only what truly must exist before handoff blocks provisioning.

**Rollback:** Raising the ESP timeout is fully reversible (set it back). Removing an app from required-tracking doesn't uninstall it if already applied — it only stops the ESP from waiting on it going forward.

</details>

<details><summary>Fix 3 — Stuck at "Joining your organization's network" (hybrid join branch)</summary>

```powershell
# On the Intune Connector server:
Get-Service "Intune Connector*" | Select-Object Name, Status
# Restart if stopped
Restart-Service "Intune Connector*"
```
Check, in order:
1. Intune Connector for Active Directory service is running on the connector server and can reach a domain controller.
2. The connector's service account has permission to create computer objects in the target OU (verify with `dsacls "<OU DN>"` or the AD delegation wizard) — this is the single most common hybrid-join failure.
3. Entra Connect sync interval — after the connector creates the on-prem AD computer object, Entra Connect must sync it to Entra ID before hybrid join finishes. A 30-minute default sync cycle means the device can sit waiting for up to that long; trigger a manual delta sync (`Start-ADSyncSyncCycle -PolicyType Delta`) to unblock immediately.
4. Confirm the Autopilot profile's domain/OU targeting is correct — a profile pointed at the wrong OU produces the same symptom as a permissions problem.

**Rollback:** None required — all checks above are read-only or a manual sync trigger, neither of which is destructive.

</details>

<details><summary>Fix 4 — Error 0x81036502 (device not found in the Autopilot service)</summary>

```powershell
# Confirm the device's hardware hash is actually imported and assigned
# (run from an admin workstation, not the failing device)
Get-AutopilotDevice -SerialNumber "<serial>" | Select-Object SerialNumber, GroupTag, ProfileStatus
```
1. If the device doesn't appear at all: the hardware hash was never imported, or import is still processing (can take several minutes to a few hours for OEM-registered hashes). Re-run hash capture/import.
2. If it appears but `ProfileStatus` isn't `Assigned`: the assignment hasn't propagated yet, or the device doesn't match the dynamic group's targeting rule — check the dynamic group membership rule and force an evaluation.
3. If the device was previously enrolled and deregistered, deregister and re-import cleanly rather than troubleshooting a partial/stale record.

**Rollback:** N/A — read-only diagnosis; re-importing a hash is additive and safe.

</details>

<details><summary>Fix 5 — Technician flow succeeded, but User flow shows failures or noncompliance</summary>

Before troubleshooting as a fault, rule out three expected/by-design conditions:
1. **Less than 90 minutes elapsed** since Technician flow completed — Microsoft's own guidance is to wait at least 90 minutes before running User flow so tokens refresh correctly between the two phases (this mainly bites lab/test scenarios, not real-world shipping timelines).
2. **More than 6 months elapsed** since Technician flow completed — the Intune Management Extension's certificate used during Technician flow can expire, producing errors like `[Win32App][DetectionActionHandler] ... resulted in action status: Failed and detection state: NotComputed`. If this is the cause, the device needs to be re-provisioned from scratch (delete the device record, re-enroll) rather than repaired in place.
3. **Compliance briefly shows noncompliant right after User flow starts** even though it showed compliant after Technician flow — this is expected. Compliance state resets when User flow begins and needs time to re-evaluate. Don't escalate on this alone; wait one compliance evaluation cycle first.

**Rollback:** N/A — these are diagnostic/timing checks, not remediation actions.

</details>

<details><summary>Fix 6 — Win32/LOB app install or detection failure during ESP</summary>

```powershell
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Tail 200 |
    Select-String "Win32App|LOB|Detection"
```
1. Confirm the failing app's detection rule against the box's actual post-install state — a mismatch here is the most common single cause of app-related ESP failures.
2. Confirm the app is targeted to **DEVICE** context, not user context — user-context apps and policies never install during the Technician flow by design; only device-targeted content (and device-context apps assigned to the pre-assigned user) applies before Reseal.
3. **Check for a Win32+LOB app mixed-targeting conflict.** Microsoft explicitly documents that targeting both a Win32 app and a LOB app to the same device is unsupported in this scenario — if this repo's environment needs to mix both app types on one device, use Windows Autopilot device preparation instead (see `DevicePreparation-B.md`/`-A.md`), not pre-provisioning.

**Rollback:** Retargeting an app from user to device context (or vice versa) doesn't undo a prior partial install — validate app state manually after the retarget if the app previously partially applied.

</details>

<details><summary>Fix 7 — Device won't automatically re-enroll after a completed or failed pre-provisioning attempt</summary>

This is expected behavior, not a bug — a device can't automatically re-enroll through Windows Autopilot after an initial deployment with pre-provisioning mode.

```powershell
# Confirm the device record exists in Intune before deleting
Get-AutopilotDevice -SerialNumber "<serial>"
```
To retry: in the Intune admin center, go to **Devices > All devices**, select the device(s), and **Delete**. Only after the device record is removed will the device be able to go through pre-provisioning again from a clean state.

**Rollback:** Deleting the Intune device record does not affect the Autopilot registration (hash/profile assignment) itself — the device remains a registered Autopilot device and will simply re-enroll on its next attempt.

</details>

---
## Escalation Evidence

```
=== Windows Autopilot Pre-Provisioning — Escalation Template ===

Device serial number:
Autopilot Group Tag / profile name:
Scenario: [ ] Entra join  [ ] Entra hybrid join
Failure phase: [ ] Technician flow — TPM attestation
               [ ] Technician flow — Entra/hybrid join
               [ ] Technician flow — Device ESP
               [ ] User flow — sign-in
               [ ] User flow — compliance/app delivery
Error code / message (verbatim from device screen or log):
Time elapsed between Technician flow completion and User flow start:
mdmdiagnosticstool.exe cab collected: [ ] Yes  [ ] No — attach if yes
TPM state (Get-Tpm output):
Network endpoint test results (ztd.dds.microsoft.com / login.microsoftonline.com / TPM attestation endpoint):
Hybrid join only — Intune Connector service status:
Hybrid join only — last Entra Connect sync time:
Steps already attempted:
```

---
## 🎓 Learning Pointers

- **Pre-provisioning is two separate flows with two separate ESP runs, not one continuous process.** The Technician flow only ever applies device-targeted content; user-targeted apps/policies wait for the User flow's device-ESP-rerun-plus-user-ESP combination after sign-in. Confusing the two is the most common reason engineers assume an app "should have installed" when it never was going to during the Technician phase. Reference: [Windows Autopilot for pre-provisioned deployment](https://learn.microsoft.com/en-us/autopilot/pre-provision)
- **TPM attestation is mandatory here with no bypass**, because the Technician flow inherits its provisioning-state mechanics from self-deploying mode — a device without a working TPM 2.0 simply cannot use this scenario at all, full stop.
- **A pre-provisioned device can never silently self-heal a failed or completed attempt** — deleting the Intune device record is the only supported way to retry, not a workaround. Build this into any deployment runbook or vendor SOP up front so technicians aren't caught guessing.
- **The 90-minute and 6-month windows around the Technician-to-User-flow gap are both real, documented constraints**, not folklore — the former is a token-refresh timing issue that mostly matters in lab/test cycles; the latter is an actual certificate-expiry failure mode that requires a full re-provision, not a repair.
- **SSL inspection on corporate proxies is a disproportionately common root cause** for pre-provisioning network failures — it breaks certificate pinning for Microsoft's enrollment/attestation endpoints. Exclude `*.microsoft.com` and `*.windows.net` from any TLS-inspecting proxy before assuming a deeper fault.
- Community reference for a faster diagnostic pass than manually parsing registry/event-log state: **Get-AutopilotDiagnosticsCommunity** (PowerShell Gallery, successor to Michael Niehaus's original `Get-AutopilotDiagnostics`) — run with `-Online` to resolve app/policy GUIDs to human-readable names.
