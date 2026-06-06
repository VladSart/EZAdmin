# TPM Attestation — Hotfix Runbook (Mode B: Ops)
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

Run these first. Takes ~60 seconds.

```powershell
# 1. Check TPM status and version
Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, TpmActivated, ManagedAuthLevel, SpecVersion

# 2. Check TPM attestation status via Intune
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\{C1D23ACC-752B-43E5-8448-8D0E519CD6D6}" -ErrorAction SilentlyContinue

# 3. Check Windows Hello for Business provisioning state
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\DeviceCredential" -ErrorAction SilentlyContinue
dsregcmd /status | Select-String "NgcSet|NgcKeyId|OnPremTgt"

# 4. Check EK certificate chain (attestation prerequisite)
Get-TpmEndorsementKeyInfo -ErrorAction SilentlyContinue | Select-Object IsPresent, ManufacturerCertificates

# 5. Check UEFI Secure Boot and TPM firmware
Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
Get-WmiObject -Namespace "root\cimv2\security\microsofttpm" -Class Win32_Tpm | Select-Object SpecVersion, ManufacturerId
```

| Result | What it means | Action |
|--------|--------------|--------|
| `TpmReady: False` | TPM not initialised or owned by OS | Check [Fix 1](#fix-1--tpm-not-ready) |
| `TpmPresent: False` | No TPM detected | Check [Fix 2](#fix-2--tpm-not-present-or-disabled-in-uefi) |
| `SpecVersion` shows 1.2 | TPM 1.2 — not supported for attestation | Check [Fix 3](#fix-3--tpm-12-not-supported) |
| EK cert `IsPresent: False` | Missing endorsement key cert | Check [Fix 4](#fix-4--missing-endorsement-key-certificate) |
| `NgcSet: NO` after WHfB push | WHfB provisioning failed | Check [Fix 5](#fix-5--windows-hello-for-business-provisioning-failure) |

---

## Dependency Cascade

<details><summary>What must be true for TPM attestation</summary>

```
Physical TPM 2.0 chip (or firmware TPM via Intel PTT / AMD fTPM)
  └── TPM enabled & activated in UEFI/BIOS
  └── Secure Boot enabled (recommended, required for some policies)
        └── OS takes ownership of TPM at first boot
              └── Endorsement Key (EK) certificate present
              └── Platform Attestation Key (PAK) derived
                    └── Intune/Entra requests attestation
                    └── Microsoft Attestation Service validates EK cert chain
                          └── Attestation token returned
                                └── Device Compliance: TPM attestation = Compliant
                                └── Windows Hello for Business provisioning proceeds
                                      └── NGC key registered in Entra ID
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm TPM 2.0 is present and ready**
```powershell
$tpm = Get-Tpm
if (-not $tpm.TpmPresent) { Write-Host "TPM NOT PRESENT — check UEFI" -ForegroundColor Red }
elseif (-not $tpm.TpmReady) { Write-Host "TPM PRESENT but NOT READY — needs initialisation" -ForegroundColor Yellow }
else { Write-Host "TPM OK" -ForegroundColor Green }
$tpm | Format-List
```

**2. Verify TPM spec version is 2.0**
```powershell
$wmiTpm = Get-WmiObject -Namespace "root\cimv2\security\microsofttpm" -Class Win32_Tpm
$wmiTpm.SpecVersion
# Good: "2.0" | Bad: "1.2" — TPM 1.2 cannot do attestation
```

**3. Check for EK certificate (required for attestation)**
```powershell
# EK certs are stored in the TPM NV storage; check via certutil
certutil -store "TrustedPublisher" 2>$null | Select-String "Manufacturer"
# Also check:
Get-TpmEndorsementKeyInfo | Format-List
```

**4. Confirm attestation is not blocked by policy**
```powershell
# Check if TPM attestation health check is enforced by compliance policy
# Look at event log for attestation failures
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 50 |
  Where-Object { $_.Message -match "attestation|TPM|tpm" } |
  Select-Object TimeCreated, LevelDisplayName, Message | Format-List
```

**5. Force a compliance re-evaluation**
```powershell
# Sync device with Intune and re-trigger compliance check
$syncSession = New-CimSession
Invoke-CimMethod -Namespace "root\cimv2\mdm\dmmap" -ClassName "MDM_DeviceManageability_Enterprise1" -MethodName "Audit" -CimSession $syncSession -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt" -TaskName "Schedule #3 created by enrollment client" -ErrorAction SilentlyContinue
```

---

## Common Fix Paths

<details><summary>Fix 1 — TPM not ready</summary>

TPM present but OS has not taken ownership or TPM is locked out.

```powershell
# Check TPM ownership status
$tpm = Get-Tpm
$tpm | Select-Object TpmOwned, LockoutCount, LockoutHealTime

# If not owned — initialise TPM
Initialize-Tpm -AllowClear -AllowPhysicalPresence
# Warning: -AllowClear will clear existing TPM keys (destroys BitLocker keys if not backed up)

# If locked out — wait for lockout to heal (check LockoutHealTime) or clear lockout
Reset-TpmLockout -ErrorAction SilentlyContinue
```

**Rollback:** `Initialize-Tpm -AllowClear` is **destructive** — it wipes all TPM-bound keys including BitLocker. Ensure BitLocker recovery keys are escrowed to Entra ID / Intune BEFORE running. To check:
```powershell
# Verify BitLocker key is escrowed BEFORE clearing TPM
manage-bde -protectors -get C: | Select-String "ID:"
# Then verify same ID is in Entra ID portal (Devices > [Device] > Recovery keys)
```

</details>

<details><summary>Fix 2 — TPM not present or disabled in UEFI</summary>

This requires physical or remote UEFI access. Cannot be fixed from OS alone.

```powershell
# Confirm TPM is truly absent vs. just disabled
Get-WmiObject -Namespace "root\cimv2\security\microsofttpm" -Class Win32_Tpm -ErrorAction SilentlyContinue
# If null — either not present or UEFI-disabled

# Check if firmware TPM is supported (Intel PTT / AMD fTPM)
(Get-WmiObject Win32_ComputerSystem).Manufacturer
(Get-WmiObject Win32_BaseBoard).Product
```

Steps:
1. Reboot to UEFI settings (manufacturer specific — usually F2, Del, or F10)
2. Navigate to Security > TPM or Platform Trust Technology (PTT for Intel, fTPM for AMD)
3. Enable and save
4. Reboot — OS will initialise TPM on next boot

**Note:** Some enterprise BIOS images have TPM disabled by policy — check with your OEM/SCCM BIOS management config.

</details>

<details><summary>Fix 3 — TPM 1.2 not supported</summary>

TPM 1.2 devices cannot perform attestation required by Intune compliance or Windows Hello for Business.

```powershell
# Confirm version
Get-WmiObject -Namespace "root\cimv2\security\microsofttpm" -Class Win32_Tpm | Select-Object SpecVersion

# Check if firmware upgrade is available (manufacturer-specific)
# Dell: https://www.dell.com/support/kbdoc/en-us/000124377
# HP: HP BIOS Configuration Utility
# Lenovo: Lenovo Vantage or BIOS update
```

If no firmware TPM 2.0 upgrade available: this device **cannot** meet TPM 2.0 attestation requirements. Options:
- Exclude from TPM attestation compliance policy via Entra group
- Replace hardware

**Rollback:** Not applicable — hardware limitation.

</details>

<details><summary>Fix 4 — Missing endorsement key certificate</summary>

Some OEM devices ship without EK certificates in TPM NV storage. Microsoft's attestation service requires a valid EK cert chain.

```powershell
# Check for EK cert
$ekInfo = Get-TpmEndorsementKeyInfo
if (-not $ekInfo.ManufacturerCertificates) {
    Write-Host "EK Certificate MISSING — checking NV index" -ForegroundColor Yellow
}

# Some manufacturers provision EK certs via Windows Update or OEM tool
# Try running Windows Update first
Install-Module PSWindowsUpdate -Force -ErrorAction SilentlyContinue
Get-WindowsUpdate -AcceptAll -Install -AutoReboot -ErrorAction SilentlyContinue
```

For Dell, HP, Lenovo — manufacturer tools can re-provision EK certs. Check OEM support documentation for your specific model.

**Alternative:** Register device using device hash only (bypasses TPM attestation) if compliance policy allows.

</details>

<details><summary>Fix 5 — Windows Hello for Business provisioning failure</summary>

Device has valid TPM but WHfB NGC key not provisioned.

```powershell
# Check NGC/WHfB state
dsregcmd /status | Select-String "NgcSet|NgcKeyId|OnPremTgt|KeySignTest"

# Check event log for WHfB errors
Get-WinEvent -LogName "Microsoft-Windows-HelloForBusiness/Operational" -MaxEvents 30 -ErrorAction SilentlyContinue |
  Where-Object { $_.Level -le 3 } |
  Select-Object TimeCreated, LevelDisplayName, Message | Format-List

# Force WHfB provisioning
$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
# Trigger via task
Get-ScheduledTask -TaskPath "\Microsoft\Windows\Work Folders\*" -ErrorAction SilentlyContinue | Start-ScheduledTask

# Re-register NGC container
certutil -deletekey -csp "Microsoft Platform Crypto Provider" "CN=NGC" -ErrorAction SilentlyContinue
# Then sign out and back in — provisioning restarts automatically
```

**Rollback:** Deleting NGC key forces re-provisioning on next sign-in. User will be prompted to re-enrol WHfB PIN/biometric.

</details>

---

## Escalation Evidence

```
ESCALATION: TPM Attestation Failure
=====================================
Ticket #:              [         ]
Device hostname:       [         ]
Device make/model:     [         ]
BIOS/firmware version: [         ]
OS version:            [         ]

TPM present:           [ YES / NO ]
TPM spec version:      [         ]  (1.2 or 2.0)
TPM ready:             [ YES / NO ]
TPM owned:             [ YES / NO ]
EK cert present:       [ YES / NO ]
Secure Boot enabled:   [ YES / NO ]

dsregcmd /status (NgcSet, AzureAdJoined, DeviceId):
  [paste here]

Intune compliance state:
  [paste here]

MDM diagnostic event log errors (attestation/TPM):
  [paste here]

WHfB Operational log errors:
  [paste here]

Steps already attempted:
  [ ] Verified TPM 2.0 in UEFI
  [ ] Ran Initialize-Tpm
  [ ] Verified EK cert chain
  [ ] Forced Intune sync and compliance re-evaluation
  [ ] Checked WHfB event logs

Escalate to: Intune L3 / Microsoft Support (Security/Identity category)
```

---

## 🎓 Learning Pointers

- **TPM 2.0 is a hard requirement** for Windows 11, Intune TPM attestation compliance, and Windows Hello for Business. TPM 1.2 devices will fail attestation silently — compliance policy just marks them non-compliant with no actionable error to the end user.
  [TPM recommendations for Windows](https://learn.microsoft.com/en-us/windows/security/hardware-security/tpm/tpm-recommendations)

- **Firmware TPM (fTPM/PTT) is as valid as a discrete TPM chip** for attestation purposes, as long as it implements TPM 2.0. Most modern Intel/AMD processors support this — check UEFI if the OS shows no TPM.

- **Clearing the TPM destroys all TPM-bound secrets** including BitLocker keys, WHfB credentials, and any app using DPAPI with TPM binding. Always verify BitLocker escrow before performing any TPM clear operation.
  [BitLocker recovery guide](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/recovery-overview)

- **EK certificate issues** are increasingly common on refurbished or reimaged devices where OEM TPM provisioning was not preserved. Microsoft's attestation service validates the EK cert against the manufacturer's CA — a self-signed or missing EK cert will fail attestation regardless of TPM health.

- **Lockout healing is automatic** — if a TPM enters lockout (too many failed authorisation attempts), it self-heals over time based on the `LockoutHealTime` value. `Reset-TpmLockout` requires the TPM owner authorisation value, which Windows stores internally. See [TechNet community post on TPM lockout](https://techcommunity.microsoft.com/t5/intune-customer-success/support-tip-troubleshooting-tpm-attestation-issues-in-intune/ba-p/3291256).
