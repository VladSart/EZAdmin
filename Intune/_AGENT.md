# Intune — Agent Instructions

## What's in this folder

Microsoft Intune / Endpoint Manager — device management, compliance, configuration, app deployment, and update management.

Covers:
- **Enrollment** — Windows Autopilot, manual MDM enrollment, co-management, enrollment restrictions
- **Policy** — configuration profiles, compliance policies, settings catalog, GPO conflicts
- **Apps** — Win32 app deployment, MSIX, LOB, required vs available
- **Updates** — Update rings, Windows Update for Business, driver updates, feature updates
- **Reporting** — compliance dashboards, device inventory, Graph queries
- **Remediation scripts** — proactive remediation, PowerShell scripts, platform scripts

---

## Before responding, also check

- `Autopilot/` — if enrollment failure happens during Autopilot flow specifically
- `EntraID/` — if device shows as non-compliant due to identity issues (Entra join state, PRT)
- `Windows/` — if the underlying OS issue is causing compliance failure
- `Security/ConditionalAccess/` — if compliance status is blocking access to resources

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Troubleshooting/Enrollment-B.md` | Hotfix: device enrollment failures |
| `Troubleshooting/Policy-Conflict-B.md` | Hotfix: policy not applying, compliance not resolving |
| `Troubleshooting/App-Deployment-B.md` | Hotfix: Win32 app stuck in pending/failed |
| `Scripts/Get-IntuneDeviceStatus.ps1` | Device compliance + enrollment state via Graph |
| `Scripts/Invoke-IntuneSync.ps1` | Force policy sync on device or bulk |
| `Reporting/Get-NonCompliantDevices.ps1` | Export all non-compliant devices with reasons |
| `Scripts/Get-LAPSPasswordStatus.ps1` | Audit LAPS rotation/retrieval status + legacy LAPS conflict check |
| `Scripts/Get-CertificateProfileStatus.ps1` | Flag Failed/Conflict/stale-Pending SCEP/PKCS cert profiles |
| `Scripts/Get-SecurityBaselineDrift.ps1` | Fleet-wide baseline Error/Conflict/Pending report across assigned baselines |

---

## Common entry points

- "Device not enrolling in Intune" → `Troubleshooting/Enrollment-B.md`
- "Policy not applying to device" → `Troubleshooting/Policy-Conflict-B.md`
- "App stuck at 'Pending install'" → `Troubleshooting/App-Deployment-B.md`
- "Device shows non-compliant, user can't access resources" → `Troubleshooting/Policy-Conflict-B.md` + `Security/ConditionalAccess/`
- "User can't see available apps" → check MDM scope + Company Portal
- "Settings applied by GPO are conflicting with Intune" → `Troubleshooting/Policy-Conflict-B.md`
- "Bulk compliance report needed" → `Reporting/Get-NonCompliantDevices.ps1`
- "LAPS password not showing / rotation not happening" → `Troubleshooting/LAPS-B.md` + `Scripts/Get-LAPSPasswordStatus.ps1`
- "Cert profile stuck Pending/Failed for a device or fleet" → `Troubleshooting/Certificates-B.md` + `Scripts/Get-CertificateProfileStatus.ps1`
- "Security baseline shows Error/Conflict" → `Troubleshooting/Security-Baselines-B.md` + `Scripts/Get-SecurityBaselineDrift.ps1`

---

## Key diagnostic commands (always useful)

```powershell
# Device join + MDM state (run on the device)
dsregcmd /status

# Force Intune sync (run on device as admin)
Start-Process -FilePath "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/o"
# Or trigger via Intune portal: Device → Sync

# Intune MDM diagnostic logs
mdmdiagnosticstool.exe -area DeviceEnrollment+DeviceProvisioning+TPM -zip C:\MDMLogs.zip

# Check what policies are applied and any errors
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" |
  Where-Object { $_.LevelDisplayName -in "Error","Warning" } |
  Select TimeCreated, Id, Message | Format-Table -Wrap
```

---

## Key dependency chain

```
Entra ID device object exists + is enabled
    → Device is Entra joined (not just registered)
    → Intune licence assigned to user
    → MDM authority = Microsoft Intune (not mixed/SCCM)
    → Device within MDM scope (All Users or specific group)
    → Intune service reachable (firewall: *.manage.microsoft.com)
    → Device checks in (every 8h by default; force sync for immediate)
    → Policies target correct AAD group
    → No conflicting GPO overriding Intune settings (MDM wins unless GPO is CSP-equivalent)
```

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — `dsregcmd /status` → identify broken layer → fix → force sync → validate
2. **Deep Dive** — MDM architecture, CSP vs GPO conflict model, compliance evaluation chain
3. **Learning Pointers** — what to study after resolution
