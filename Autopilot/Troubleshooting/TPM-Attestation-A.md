# TPM Attestation — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Windows Autopilot TPM attestation failures (error codes 0x800705B4, 0x80070490, 0x8018044, 0x80180001, 0x801c0003)
- TPM chip provisioning and firmware requirements
- Entra ID device join credential handshake via TPM
- Windows Hello for Business key trust TPM dependencies (see also: `EntraID/Troubleshooting/WHfB-A.md`)

**Out of scope:**
- BitLocker TPM PIN issues (see `Windows/Troubleshooting/BitLocker/BitLocker-A.md`)
- Secure Boot / UEFI firmware flashing
- Physical TPM chip replacement

**Assumptions:**
- Device is modern hardware with TPM 2.0 (TPM 1.2 is not supported by Autopilot attestation)
- BIOS/UEFI has TPM enabled and Secure Boot enabled
- Device has internet access to Windows Autopilot service endpoints during OOBE
- Engineer has access to Intune admin portal and can run PowerShell locally on device

---

## How It Works

<details><summary>Full architecture</summary>

**What TPM attestation is:**

During Autopilot OOBE, Windows must prove to Microsoft's cloud that:
1. The device has a genuine, trusted TPM 2.0 chip
2. The TPM has not been tampered with
3. The device's identity (hardware hash) matches an Autopilot-registered record

```
Device (OOBE)
│
├─ Step 1: TPM Provisioning (auto-provision via Windows)
│   ├── Takes TPM ownership (if not already owned)
│   ├── Clears stale ownership keys from prior builds
│   └── Creates Endorsement Key (EK) — permanent, tied to chip
│
├─ Step 2: Attestation Identity Key (AIK) Creation
│   ├── Windows creates AIK inside TPM
│   ├── Sends AIK certificate request to Microsoft Attestation Service
│   │   (aadcdn.msauth.net / ekop.intel.com or similar)
│   └── Microsoft verifies AIK against EK cert chain (from chip manufacturer)
│
├─ Step 3: Autopilot Device Registration Check
│   ├── Windows sends hardware hash to Windows Autopilot service
│   │   (ztd.dds.microsoft.com)
│   ├── Service confirms hash matches registered record
│   └── Returns Autopilot profile (join type, naming, ESP config)
│
├─ Step 4: Entra ID Join via TPM
│   ├── Windows generates device key pair inside TPM
│   ├── Sends public key to Entra ID (device registration)
│   └── Entra ID issues device certificate backed by TPM private key
│
└─ Step 5: ESP Phase — User / Device certificates
    ├── WHfB key provision (if enabled)
    └── SCEP/PKCS cert delivery from Intune
```

**Why attestation fails:**

```
Failure class         Root cause
─────────────────────────────────────────────────────
Network               Cannot reach attestation endpoints (firewall/proxy)
TPM firmware          Outdated firmware; known-bad EK cert chain
Stale TPM state       Prior OS/tenant left partial TPM ownership
Hardware              TPM physically broken or fTPM disabled in UEFI
Clock skew            System clock >5min off UTC; cert validation fails
Duplicate hash        Same hardware hash registered multiple times
Tenant mismatch       Device registered in wrong tenant
```

**Common error codes:**

| Code | Meaning |
|------|---------|
| `0x800705B4` | Timeout — network or attestation service unreachable |
| `0x80070490` | Element not found — TPM EK cert missing or corrupt |
| `0x80180001` | AIK certification failed — EK chain not trusted |
| `0x801c0003` | Device is not authorized — not registered in Autopilot |
| `0x8018044` | TPM attestation general failure |
| `0x800706BA` | RPC server unavailable — Windows Time service or TPM service stopped |

</details>

---

## Dependency Stack

```
Physical TPM 2.0 chip (or fTPM in CPU)
└── UEFI/BIOS: TPM enabled + Secure Boot ON
    └── Windows TPM Base Services (TBS) — MUST be running
        └── Windows Time Service (W32Tm) — clock within 5min of UTC
            └── Network: HTTPS to attestation endpoints
                ├── ekop.intel.com / ekcert.spserv.microsoft.com (EK cert validation)
                ├── aadcdn.msauth.net (AAD token / AIK cert)
                ├── enterpriseregistration.windows.net (device registration)
                └── ztd.dds.microsoft.com (Autopilot profile)
                    └── Autopilot device record (tenant match)
                        └── Entra ID device object created
                            └── ESP: Intune policy/cert delivery
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| OOBE fails with 0x800705B4 | Network timeout to attestation endpoints | Test endpoints from WinPE or cmd in OOBE |
| Error 0x80070490 | TPM EK certificate missing | `certutil -store -silent "AT service" EK\*`; check UEFI TPM config |
| Error 0x80180001 | EK chain not recognized by Microsoft | Check TPM firmware version; update firmware |
| Error 0x801c0003 | Device hash not found in Autopilot | Verify registration in Intune > Devices > Autopilot |
| Attestation succeeds but device joins wrong tenant | Hash registered in another tenant | Delete hash from old tenant; re-register |
| TPM provisioning loop in OOBE | Stale TPM ownership from prior OS | Clear TPM in UEFI + reset Autopilot registration |
| WHfB fails after Autopilot completes | TPM not bound to device certificate | Check `dsregcmd /status` for `AzureAdJoined=YES` and `TpmProtected=YES` |
| `tpm.msc` shows "TPM is ready for use" but attestation fails | fTPM firmware bug | Update CPU firmware (Intel ME / AMD PSP) |
| Attestation works in test tenant, fails in prod | Different Autopilot registration; policy blocks | Confirm hash registered in prod tenant |

---

## Validation Steps

**Step 1 — Confirm TPM 2.0 is present and active**
```powershell
Get-Tpm
```
**Good output:** `TpmPresent=True`, `TpmReady=True`, `TpmEnabled=True`, `TpmActivated=True`, `ManufacturerId` present
**Bad output:** `TpmPresent=False` — TPM disabled in UEFI; `TpmReady=False` — TPM needs provisioning or is faulty

---

**Step 2 — Confirm TPM specification version**
```powershell
Get-CimInstance -Class Win32_TPM -Namespace root\cimv2\security\microsofttpm |
    Select-Object ManufacturerID, ManufacturerVersion, SpecVersion, IsActivated_InitialValue, IsEnabled_InitialValue
```
**Good output:** `SpecVersion` contains "2.0" — required for Autopilot attestation
**Bad output:** `SpecVersion` shows "1.2" — TPM 1.2 is not supported; hardware replacement needed

---

**Step 3 — Test network connectivity to attestation endpoints**
```powershell
$endpoints = @(
    "https://ekop.intel.com/ekcertservice",
    "https://ekcert.spserv.microsoft.com",
    "https://aadcdn.msauth.net",
    "https://enterpriseregistration.windows.net",
    "https://ztd.dds.microsoft.com"
)
foreach ($ep in $endpoints) {
    try {
        $r = Invoke-WebRequest -Uri $ep -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-Host "OK  [$($r.StatusCode)] $ep" -ForegroundColor Green
    } catch {
        Write-Host "FAIL [$($_.Exception.Message)] $ep" -ForegroundColor Red
    }
}
```
**Good output:** All endpoints return HTTP 200 or 400 (400 = reachable but auth required — that's fine)
**Bad output:** Connection timeout or TCP refused — firewall/proxy blocking

---

**Step 4 — Check Windows Time service accuracy**
```powershell
w32tm /query /status
(Get-Date).ToUniversalTime()
```
**Good output:** `ClockSource: Local CMOS Clock` or NTP, and local UTC time matches actual UTC within 5 minutes
**Bad output:** Time off by >5 minutes — cert validation will fail

---

**Step 5 — Verify Autopilot device registration**
```powershell
# Run from a cloud-connected machine with Intune access
Connect-MgGraph -Scopes "Device.Read.All","DeviceManagementServiceConfig.Read.All"
$serial = Read-Host "Enter device serial number"
Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -Filter "contains(serialNumber,'$serial')" |
    Select-Object SerialNumber,Model,GroupTag,EnrollmentState,ManagedDeviceId
```
**Good output:** Device found with correct serial, GroupTag, and `EnrollmentState`
**Bad output:** No result — device not registered; wrong tenant; or hash needs re-upload

---

**Step 6 — Check device join state post-OOBE**
```powershell
dsregcmd /status | Select-String -Pattern 'AzureAdJoined|TpmProtected|DeviceId|KeySignTest'
```
**Good output:** `AzureAdJoined : YES`, `TpmProtected : YES`, `DeviceId` contains a GUID
**Bad output:** `AzureAdJoined : NO` — join failed; `TpmProtected : NO` — device key not in TPM

---

## Troubleshooting Steps (by phase)

### Phase 1: Pre-OOBE / Hardware Validation

1. Enter UEFI/BIOS → confirm TPM is **Enabled** and set to **TPM 2.0** (not Compatibility Mode)
2. Confirm Secure Boot is **Enabled** (required for Autopilot Device Attestation)
3. Run `Get-Tpm` (Step 1) — if TpmReady=False, run `Initialize-Tpm` in elevated PowerShell
4. If `Initialize-Tpm` fails with "Access denied" — TPM ownership exists from prior OS; clear in UEFI
5. Check manufacturer advisory for known fTPM bugs (especially AMD fTPM 7.x flicker issues, Intel PTT on older BIOS)

### Phase 2: Network / Endpoint Failures

1. Run Step 3 connectivity test from within OOBE (Shift+F10 → PowerShell)
2. If endpoints unreachable: check proxy settings — OOBE has no proxy config by default
3. Add proxy via `netsh winhttp set proxy <proxy>:<port>` in OOBE cmd
4. If behind corporate firewall: whitelist all Autopilot required URLs — see [MS Required URLs](https://learn.microsoft.com/en-us/mem/autopilot/networking-requirements)
5. For 0x800705B4 specifically: usually a timeout — retry after confirming network

### Phase 3: Attestation Endpoint / EK Cert Failures

1. `0x80070490` (EK cert missing): confirm TPM firmware is current; update via UEFI
2. `0x80180001` (EK chain untrusted): the chip manufacturer's EK certificate chain may not be in Microsoft's trusted list — common on older Lenovo/Dell units; update firmware
3. For Intel-based devices: update Intel ME firmware via manufacturer tools (Dell Command Update, HP Image Assistant, Lenovo Vantage)
4. For AMD: update AMD PSP firmware via BIOS update

### Phase 4: Registration / Tenant Mismatch

1. Confirm device hash registered in correct tenant (Step 5)
2. If registered in wrong tenant: delete from old tenant, re-upload hash to correct tenant
3. For decommissioned devices being re-imaged: delete the Autopilot record first, re-register after wipe

---

## Remediation Playbooks

<details><summary>Fix 1 — Clear stale TPM ownership and re-provision</summary>

> ⚠️ Destructive: clears all TPM-backed keys. BitLocker will suspend. Do NOT run on enrolled production devices without backing up BitLocker recovery keys first.

```powershell
# Step 1: Verify BitLocker recovery key is backed up
$vol = Get-BitLockerVolume -MountPoint C:
if ($vol.EncryptionPercentage -gt 0) {
    Write-Warning "BitLocker is active. Ensure recovery key is backed up before clearing TPM."
    $vol | Select-Object MountPoint,EncryptionPercentage,KeyProtector
}

# Step 2: Clear TPM
Clear-Tpm

# Step 3: Force TPM initialization
Initialize-Tpm

# Step 4: Restart (required after TPM clear)
Write-Host "TPM cleared. System restart required." -ForegroundColor Yellow
```

**Alternative:** Clear TPM in UEFI/BIOS (F1/F2/Del during POST → Security → TPM → Clear TPM)

**Rollback:** There is no rollback for TPM clear. Ensure BitLocker recovery keys are stored in Entra ID before proceeding.

</details>

---

<details><summary>Fix 2 — Re-upload hardware hash to correct Autopilot tenant</summary>

```powershell
# Run on the target device (fresh OS or WinPE with PowerShell)
Install-PackageProvider -Name NuGet -Force
Install-Script -Name Get-WindowsAutopilotInfo -Force

# Capture hash to CSV
Get-WindowsAutopilotInfo -OutputFile "C:\Temp\AutopilotHash.csv"

# Then on an admin machine connected to the target tenant:
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All"
Import-AutopilotCSV -CsvFile "C:\Temp\AutopilotHash.csv"
# Or use Intune portal: Devices > Enroll Devices > Autopilot Devices > Import
```

**Note:** After import, allow 15–30 minutes for the profile to synchronize before starting OOBE.

</details>

---

<details><summary>Fix 3 — Fix clock skew causing attestation failure</summary>

```powershell
# In OOBE cmd (Shift+F10):
net start w32tm
w32tm /resync /force
w32tm /query /status

# If NTP unreachable (network issue), set manually:
$utcNow = [System.DateTime]::UtcNow.ToString("MM-dd-yyyy HH:mm:ss")
Write-Host "Current UTC: $utcNow"
# Set via: date and time dialog, or:
# Set-Date -Date (Invoke-RestMethod "http://worldtimeapi.org/api/timezone/UTC").utc_datetime
```

</details>

---

<details><summary>Fix 4 — Force Autopilot re-enrollment on existing device</summary>

```powershell
# Reset Autopilot enrollment state (non-destructive — does NOT wipe device)
# Run from elevated PowerShell after sign-in

# Remove cached Autopilot profile
$apPath = "HKLM:\SOFTWARE\Microsoft\Provisioning\AutopilotPolicyCache"
if (Test-Path $apPath) { Remove-Item $apPath -Recurse -Force }

# Trigger fresh profile pull
$apSvc = Get-Service -Name diagtrack -ErrorAction SilentlyContinue
if ($apSvc) { Restart-Service diagtrack }

# Re-run Autopilot diagnostics
Start-Process "ms-settings:workplace"  # Or run sysprep OOBE for full re-enrollment
```

**For full wipe + re-enroll:** Use Intune > Fresh Start or Autopilot Reset (cloud-triggered wipe that preserves Autopilot registration).

</details>

---

## Evidence Pack

```powershell
<#
  TPM Attestation Evidence Collector
  Run in OOBE (Shift+F10) or on enrolled device for escalation evidence.
#>

$out = "$env:TEMP\TPM-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
$sb  = [System.Text.StringBuilder]::new()

$null = $sb.AppendLine("=== TPM ATTESTATION EVIDENCE PACK ===")
$null = $sb.AppendLine("Collected: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$null = $sb.AppendLine("Machine: $env:COMPUTERNAME")
$null = $sb.AppendLine("")

# TPM state
$null = $sb.AppendLine("--- TPM State (Get-Tpm) ---")
$null = $sb.AppendLine((Get-Tpm | Out-String))

# TPM WMI
$null = $sb.AppendLine("--- TPM WMI ---")
$tpm = Get-CimInstance -Class Win32_TPM -Namespace root\cimv2\security\microsofttpm
$null = $sb.AppendLine("ManufacturerID     : $($tpm.ManufacturerID)")
$null = $sb.AppendLine("ManufacturerVersion: $($tpm.ManufacturerVersion)")
$null = $sb.AppendLine("SpecVersion        : $($tpm.SpecVersion)")
$null = $sb.AppendLine("IsActivated        : $($tpm.IsActivated_InitialValue)")
$null = $sb.AppendLine("")

# System time
$null = $sb.AppendLine("--- System Time ---")
$null = $sb.AppendLine("Local  : $(Get-Date)")
$null = $sb.AppendLine("UTC    : $((Get-Date).ToUniversalTime())")
$null = $sb.AppendLine((w32tm /query /status | Out-String))

# dsregcmd status
$null = $sb.AppendLine("--- dsregcmd /status ---")
$null = $sb.AppendLine((dsregcmd /status | Out-String))

# Endpoint connectivity
$null = $sb.AppendLine("--- Endpoint Connectivity ---")
$eps = @(
    "https://ekop.intel.com/ekcertservice",
    "https://ekcert.spserv.microsoft.com",
    "https://aadcdn.msauth.net",
    "https://enterpriseregistration.windows.net",
    "https://ztd.dds.microsoft.com"
)
foreach ($ep in $eps) {
    try {
        $r = Invoke-WebRequest -Uri $ep -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $null = $sb.AppendLine("OK   [$($r.StatusCode)] $ep")
    } catch {
        $null = $sb.AppendLine("FAIL [$($_.Exception.Message.Substring(0,[Math]::Min(60,$_.Exception.Message.Length)))] $ep")
    }
}

$sb.ToString() | Out-File $out -Encoding UTF8
Write-Host "Evidence written to: $out" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check TPM state | `Get-Tpm` |
| Check TPM WMI details | `Get-CimInstance -Class Win32_TPM -Namespace root\cimv2\security\microsofttpm` |
| Initialize TPM | `Initialize-Tpm` (elevated) |
| Clear TPM | `Clear-Tpm` (elevated — DESTRUCTIVE) |
| Check Autopilot registration | `Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -Filter "contains(serialNumber,'<serial>')"` |
| Capture hardware hash | `Get-WindowsAutopilotInfo -OutputFile hash.csv` (requires script from PS Gallery) |
| Check clock | `w32tm /query /status` |
| Force time sync | `w32tm /resync /force` |
| Check device join state | `dsregcmd /status` |
| Check event logs for TPM errors | `Get-WinEvent -LogName "Microsoft-Windows-TPM-WMI/Operational" -MaxEvents 50` |
| Check Autopilot OOBE logs | `Get-WinEvent -LogName "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/AutoPilot"` |
| Test attestation endpoint | `Invoke-WebRequest -Uri "https://ztd.dds.microsoft.com" -UseBasicParsing` |
| Sync Intune device | `Invoke-MgDeviceManagementManagedDeviceSyncDevice -ManagedDeviceId <id>` |

---

## 🎓 Learning Pointers

- **TPM 2.0 is mandatory for Autopilot — but "enabled in BIOS" isn't always enough.** Many enterprise images set TPM to "Compatibility Mode" (TPM 1.2 emulation) for legacy OS support. Autopilot attestation requires native TPM 2.0 mode. Always confirm `SpecVersion = 2.0` in WMI, not just that TPM is "on". [MS Docs: TPM requirements](https://learn.microsoft.com/en-us/mem/autopilot/tpm)

- **0x80070490 almost always means a stale or missing EK certificate.** The Endorsement Key certificate is burned into the TPM at manufacture. If it's missing (rare hardware defect) or the chain isn't trusted (needs firmware update), attestation cannot complete. The fix is almost always a firmware/BIOS update — not a Windows reinstall. [Intel ME updates](https://www.intel.com/content/www/us/en/support/articles/000005523.html)

- **fTPM (firmware TPM) on AMD is notoriously buggy on older BIOS versions.** AMD Ryzen platforms shipped fTPM firmware with a stuttering bug that corrupted TPM state randomly. Microsoft released a fix in 2022, but many enterprise images predate it. If you see intermittent attestation failures on AMD hardware, check the AGESA firmware version. [AMD fTPM advisory](https://www.amd.com/en/resources/support-articles/faqs/PA-300.html)

- **Autopilot attestation happens entirely in OOBE before the user logs in.** This means proxy configurations and corporate firewall rules applied via GPO or Intune policy do NOT apply during attestation. The device must reach attestation endpoints on the raw network — build your Autopilot network path to allow direct HTTPS to all required Microsoft endpoints without proxy interception. [MS Docs: Autopilot network requirements](https://learn.microsoft.com/en-us/mem/autopilot/networking-requirements)

- **Clock skew of >5 minutes causes silent cert validation failures.** TPM attestation uses time-stamped cryptographic certificates. If the system clock is wrong (common on freshly imaged devices that haven't synced NTP yet), cert validation fails with a cryptic error. Always start your OOBE network troubleshooting by checking `w32tm /query /status` and verifying the time is within 5 minutes of UTC.

- **Deleting and re-registering an Autopilot device does NOT wipe it.** The Autopilot record is separate from the Intune/Entra device object. Deleting the Autopilot hash registration in Intune only removes the enrollment profile assignment — the device remains enrolled (if it already is). For a clean slate, you need: delete Autopilot record + delete Entra device object + delete Intune device object + wipe device. [MS Docs: Delete Autopilot devices](https://learn.microsoft.com/en-us/mem/autopilot/delete-devices)
