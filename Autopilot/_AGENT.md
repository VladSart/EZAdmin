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

- "Device not picking up Autopilot profile during OOBE" → `Troubleshooting/Profile-Not-Assigned-B.md`
- "Stuck on Enrollment Status Page" → `Troubleshooting/ESP-Stuck-B.md`
- "Hybrid join Autopilot failing" → `Troubleshooting/HybridJoin-Autopilot-B.md`
- "TPM attestation error" → `Troubleshooting/TPM-Attestation-B.md`
- "Need to upload hardware hash and enroll" → `Scripts/Upload-Hash-Enroll2Autopilot.ps1`
- "Network test before Autopilot deployment" → `Scripts/Test-AutopilotNetworkRequirements.ps1`

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
