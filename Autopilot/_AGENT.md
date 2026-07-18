# Autopilot — Agent Instructions

## What's in this folder

Windows Autopilot — zero-touch device provisioning for Entra joined and Hybrid joined devices.

Covers:
- **Enrollment** — hash upload, profile assignment, OOBE flow
- **Hybrid join (HAADJ)** — the most complex scenario; requires on-prem AD + Entra Connect + Intune Connector
- **Deployment profiles** — user-driven, self-deploying, pre-provisioning (white glove)
- **ESP (Enrollment Status Page)** — why devices get stuck, timeout handling
- **TPM issues** — attestation failures, firmware version problems
- **Network requirements** — firewall/proxy requirements for Autopilot to reach Microsoft
- **Windows Autopilot device preparation (APDP)** — the newer, Entra-join-only enrollment mode built on Enrollment Time Grouping; architecturally distinct from classic Autopilot above (no ESP, no dynamic-group wait) — classic Autopilot always takes precedence if a device matches both

---

## Before responding, also check

- `Intune/` — Autopilot is a provisioning surface; Intune handles everything after enrollment
- `EntraID/` — device join state and PRT issues affect every Autopilot flow
- `Windows/` — if the device has OS-level issues (BitLocker, VBS, TPM) blocking enrollment

---

## Key diagnostic commands

```powershell
# Check Autopilot registration and profile
# Run in OOBE (Shift+F10 for command prompt → PowerShell)
Install-Script -Name Get-WindowsAutoPilotInfo -Force
Get-WindowsAutoPilotInfo -Online  # Requires internet + tenant access

# Check if device is registered in Intune Autopilot
# In Intune portal: Devices → Enroll devices → Windows enrollment → Windows Autopilot devices

# Collect Autopilot diagnostic logs
mdmdiagnosticstool.exe -area Autopilot -zip C:\AutopilotDiags.zip

# Check Autopilot-specific event log
Get-WinEvent -LogName "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot" `
  -MaxEvents 50 | Select TimeCreated, Id, Message | Format-Table -Wrap
```

---

## Common entry points

- "Device not picking up Autopilot profile during OOBE" → `Troubleshooting/Profile-Not-Assigned-B.md` + `Scripts/Get-AutopilotProfileAssignmentAudit.ps1`
- "Stuck on Enrollment Status Page" → `Troubleshooting/ESP-Stuck-B.md` + `Scripts/Get-ESPDeploymentStatus.ps1`
- "Hybrid join Autopilot failing" → `Troubleshooting/HybridJoin-Autopilot-B.md` (cross-ref `EntraID/Scripts/Get-HybridJoinDiagnostics.ps1`)
- "ESP timing out on Hybrid Join / is our ESP timeout even long enough for Entra Connect sync" → `Scripts/Get-HybridJoinESPTimingCorrelation.ps1` (cross-ref `ESP-Stuck-A.md` "Hybrid Join ESP has a timing dependency on Entra Connect")
- "TPM attestation error" → `Troubleshooting/TPM-Attestation-B.md` + `Scripts/Get-TPMAttestationStatus.ps1`
- "Need to upload hardware hash and enroll" → `Scripts/Upload-Hash-Enroll2Autopilot.ps1`
- "Network test before Autopilot deployment" → `Scripts/Test-AutopilotNetworkRequirements.ps1`
- "Device prep policy won't save / 0 groups assigned / ESP showing when it shouldn't" → `Troubleshooting/DevicePreparation-B.md` (hotfix) / `DevicePreparation-A.md` (deep dive — Enrollment Time Grouping architecture) + `Scripts/Get-DevicePreparationReadinessAudit.ps1`
- "Apps/scripts Skipped during a device preparation OOBE deployment" → `Troubleshooting/DevicePreparation-B.md` (Fix 4)
- "Reset device for next user / redeploy / wipe and reprovision" → `Troubleshooting/Reset-B.md` (hotfix) / `Reset-A.md` (deep dive — Autopilot Reset vs. Wipe vs. Fresh Start comparison, hybrid-join hard exclusion) + `Scripts/Get-AutopilotResetReadinessAudit.ps1`

---

## Folder contents

| File | What it covers |
|------|-----------------|
| `Scripts/Get-AutopilotDeviceStatus.ps1` | Comprehensive Autopilot device status from Intune via Graph |
| `Scripts/Get-AutopilotProfileAssignmentAudit.ps1` | Single-device or tenant-wide audit of profile assignment breakdown — hash registration, Entra device object, dynamic group membership, Group Tag rule matching, duplicate registrations |
| `Scripts/Get-ESPDeploymentStatus.ps1` | Device-local ESP diagnostic — event logs, IME app-install log, ESP/DeviceContext registry state, Win32 app tracking, Hybrid Join check, ESP endpoint connectivity |
| `Scripts/Get-HybridJoinESPTimingCorrelation.ps1` | Device-local — correlates Hybrid Join registration wait (Automatic-Device-Join task history + User Device Registration event 304/335) against the configured ESP timeout budget, with optional live Entra Connect sync-interval check; flags whether ESP is structurally too short for the sync window |
| `Scripts/Get-EnrollmentLogs.ps1` | Collects Autopilot/Intune enrollment event log entries to a transcript |
| `Scripts/Get-TPMAttestationStatus.ps1` | Device-local TPM attestation diagnostic — TPM state/spec version, clock accuracy, attestation endpoint reachability, dsregcmd join state, TPM-WMI event log |
| `Scripts/Upload-AutopilotDiagnostics.ps1` | Uploads Autopilot diagnostic data for support cases |
| `Scripts/Upload-Hash-Enroll2Autopilot.ps1` | Captures hardware hash and enrolls device into Autopilot |
| `Troubleshooting/Test-AutopilotNetworkRequirements.ps1` | Tests reachability of required Autopilot network endpoints |
| `Troubleshooting/Profile-Not-Assigned-B.md` / `-A.md` | Hotfix / deep dive: device not picking up an Autopilot profile at OOBE — hash registration, dynamic group membership timing, Group Tag matching |
| `Troubleshooting/ESP-Stuck-B.md` / `-A.md` | Hotfix / deep dive: device stuck on Enrollment Status Page — app/policy tracking, timeout budget, Hybrid Join timing dependency |
| `Troubleshooting/HybridJoin-Autopilot-B.md` / `-A.md` | Hotfix / deep dive: Hybrid Join Autopilot failures — on-prem AD + Entra Connect + Intune Connector dependency chain |
| `Troubleshooting/TPM-Attestation-B.md` / `-A.md` | Hotfix / deep dive: TPM attestation failures at enrollment — spec version, firmware, clock accuracy |
| `Troubleshooting/DevicePreparation-B.md` / `-A.md` | Hotfix / deep dive: Windows Autopilot device preparation (APDP) — Enrollment Time Grouping, device group ownership/eligibility, classic-Autopilot precedence shadowing |
| `Scripts/Get-DevicePreparationReadinessAudit.ps1` | Read-only audit of device-prep prerequisites — device group ownership/eligibility, Intune Provisioning Client SP presence, classic-Autopilot shadowing by serial |
| `Troubleshooting/Reset-B.md` / `-A.md` | Hotfix / deep dive: Windows Autopilot Reset (local + remote) — hybrid-join/Surface Hub hard exclusion, WinRE preflight gate, local vs. remote identity-handoff divergence, comparison vs. Wipe/Fresh Start |
| `Scripts/Get-AutopilotResetReadinessAudit.ps1` | Fleet-wide pre-flight audit of Autopilot Reset eligibility via Graph — flags hybrid-joined devices and stale MDM sync before a bulk reset is attempted |

> ⚠️ Not listed above: `Troubleshooting/Autopilot-Troubleshooting2.ps1` and `Troubleshooting/Autopilot-Network-Connectivity.ps1` (misfiled `.ps1` scripts sitting under `Troubleshooting/` rather than `Scripts/`, one a near-duplicate of `Test-AutopilotNetworkRequirements.ps1`) are flagged since run 30 for interactive user review (rename/relocate/dedupe), not touched autonomously.

---

## Firewall requirements (verify before every deployment)

```
Required endpoints (all HTTPS/443 unless noted):
*.manage.microsoft.com
*.microsoftonline.com
*.windows.net
ztd.dds.microsoft.com          (Autopilot device registration)
cs.dds.microsoft.com           (Autopilot device registration)
login.live.com                 (MSA auth for device registration)
ekop.intel.com                 (TPM attestation — Intel)
ekcert.spserv.microsoft.com    (TPM attestation)
ftpm.amd.com                   (TPM attestation — AMD)
```

Run `Scripts/Test-AutopilotNetworkRequirements.ps1` before any Autopilot deployment.

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — network check → profile check → logs → fix → validate
2. **Deep Dive** — Autopilot architecture, TPM model, hybrid join complexity
3. **Learning Pointers** — what to study after resolution
