# BitLocker — Reference Runbook (Mode A: Deep Dive)

> Engineering-grade reference. Explains why things fail, not just what to click. For L2/L3 diagnosis, post-mortems, and building understanding.
> **Environment:** Windows 10/11 · Entra ID joined (Azure AD joined) or Hybrid · Intune-managed · TPM 2.0

---

## Skim Index

- [Scope & Assumptions](#scope--assumptions)
- [How BitLocker Works](#how-bitlocker-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps](#troubleshooting-steps)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

- **Covers:** BitLocker Drive Encryption on OS volumes, managed via Intune BitLocker CSP. Recovery key escrow to Entra ID (Azure AD). Applies to Entra-joined and Hybrid-joined Windows 10/11 devices.
- **Environment:** Intune MDM-managed, TPM 2.0, UEFI firmware with Secure Boot
- **Not covered:** BitLocker on removable drives (BitLocker To Go), on-premises AD-only escrow (separate playbook), standalone MBAM deployments
- **Assumes:** Global Admin / Intune Admin access for portal lookups; Local Admin on device for most commands

---

## How BitLocker Works

<details>
<summary><strong>Full architecture — TPM sealing, PCR registers, boot chain, Intune CSP, and escrow</strong></summary>

### The Encryption Key Hierarchy

BitLocker uses a layered key structure. You never directly encrypt data with a master secret — instead:

```
Full Volume Encryption Key (FVEK)
  └─ encrypted by →
Volume Master Key (VMK)
  └─ protected by one or more Key Protectors:
        ├─ TPM protector          ← seals VMK to TPM + boot state
        ├─ Recovery Password      ← 48-digit key (the one users type at recovery screen)
        ├─ TPM+PIN                ← TPM seal + user PIN required at boot
        └─ AAD (Azure AD) protector ← VMK encrypted with device's Entra certificate
```

The FVEK encrypts the actual volume. The VMK encrypts the FVEK. Key Protectors protect the VMK. This layering means: if one protector is compromised, you can remove it and add a new one without re-encrypting the entire volume.

### TPM Sealing and PCR Registers

The TPM protector works through *sealing*: the VMK is encrypted by the TPM in a way that can only be decrypted if a set of PCR (Platform Configuration Register) values match what they were when the key was sealed.

PCR registers store SHA hashes of measured boot components, accumulated at boot time:

| PCR | Measures |
|-----|---------|
| 0 | BIOS/UEFI firmware |
| 1 | UEFI firmware configuration |
| 2 | Option ROMs |
| 3 | Option ROM config |
| 4 | MBR / boot manager |
| 7 | Secure Boot state and policy |
| 11 | BitLocker access control |

**Default BitLocker profile uses PCR 7 + PCR 11** (Secure Boot state + BitLocker policy). This means:
- Changing Secure Boot policy → PCR 7 changes → TPM won't unseal → recovery key required
- BIOS update that changes PCR 0 → if PCR 0 is in the profile → recovery key required

**Boot measurement chain:**
1. UEFI firmware executes, measures itself into PCR 0
2. Secure Boot validates boot loader signature, measures Secure Boot state into PCR 7
3. Windows Boot Manager loads, measures into PCR 4
4. BitLocker driver asks TPM to unseal VMK using current PCR values
5. If PCR values match sealed state → VMK released → FVEK decrypted → OS boots transparently
6. If mismatch → TPM refuses → user sees recovery screen

**Why this matters operationally:**
- BIOS updates: suspend BitLocker first (`manage-bde -protectors -disable C:`) to avoid recovery screen
- Switching from Legacy BIOS to UEFI on an encrypted device: triggers recovery
- Enabling/disabling Secure Boot on an encrypted device: triggers recovery

### How Intune Manages BitLocker

Intune uses the **BitLocker CSP** (Configuration Service Provider) — a Windows MDM channel that maps to registry keys and internal Windows APIs.

**CSP root path:** `./Device/Vendor/MSFT/BitLocker`

Key CSP nodes and what they do:

| CSP Node | Effect | Registry path |
|----------|--------|---------------|
| `RequireDeviceEncryption` | Triggers encryption on compliant devices | `HKLM\SOFTWARE\Microsoft\PolicyManager\...\BitLocker\RequireDeviceEncryption` |
| `EncryptionMethodByDriveType` | Sets algorithm (XTS-AES 128/256, AES-CBC) | `HKLM\SOFTWARE\Policies\Microsoft\FVE\EncryptionMethodWithXtsOs` |
| `SystemDrivesRequireStartupAuthentication` | Require TPM+PIN or TPM-only | `HKLM\SOFTWARE\Policies\Microsoft\FVE\UseAdvancedStartup` |
| `AllowWarningForOtherDiskEncryption` | Allows/blocks silent encryption | Key for silent flow |
| `ConfigureRecoveryPasswordRotation` | Rotate key after recovery use | — |

**Policy evaluation order (who wins when there's conflict):**

1. Local GPO (weakest)
2. Domain GPO
3. MDM CSP (Intune)
4. "MDM wins" policy (if `ControlPolicyConflict/MDMWinsOverGP` is enabled)

Without `MDMWinsOverGP`, GPO settings in `HKLM\SOFTWARE\Policies\Microsoft\FVE` override CSP settings. This is the most common source of BitLocker policy conflicts in hybrid environments.

### Silent vs User-Driven Encryption

**Silent encryption** is triggered automatically without any user prompt. It requires *all* of the following:

| Requirement | Verification |
|-------------|-------------|
| UEFI firmware (not Legacy/CSM) | `msinfo32` → BIOS Mode: UEFI |
| TPM 2.0 present and ready | `Get-Tpm` → TpmPresent, TpmReady: True |
| Secure Boot enabled | `Confirm-SecureBootUEFI` → True |
| DMA protection (Kernel DMA Protection) | `msinfo32` → Kernel DMA Protection: On |
| No external OS drive attached | — |
| `AllowWarningForOtherDiskEncryption` = Disabled in policy | Intune profile setting |
| Device in scope of Intune BitLocker profile | Intune portal assignment |

If **any** requirement fails, silent encryption does not start. It fails with no notification to the user and no obvious error in the UI. The only signal is Event ID 853 in `Microsoft-Windows-BitLocker/BitLocker Management` log.

**User-driven encryption** falls back to a toast notification prompting the user to encrypt. Less reliable in enterprise (users dismiss it).

### Recovery Key Escrow to Entra ID

The escrow mechanism uses public key cryptography:

1. When device joined Entra ID, a device certificate was issued by Microsoft
2. The device holds the private key; Entra holds the public key
3. When BitLocker generates a recovery password, Windows encrypts it using the Entra public key
4. The encrypted package is POSTed to the Entra endpoint: `enterpriseregistration.windows.net`
5. Entra stores the ciphertext; only the tenant can decrypt it (using HSM-protected keys on Microsoft's side)
6. Admins retrieve it via Entra Portal / Intune Portal / Graph API in plaintext

**What triggers escrow:**
- First encryption of a drive on an Entra-joined device
- `BackupToAAD-BitLockerKeyProtector` called explicitly
- Key rotation (after recovery key use, if rotation policy is configured)
- Intune `ConfigureRecoveryPasswordRotation` policy

**Escrow failure causes:**
- Device not Entra joined (no certificate)
- No internet / firewall blocking `enterpriseregistration.windows.net:443`
- Device certificate expired or missing
- Recovery password protector not present (nothing to escrow)

**Key escrow to on-prem AD (Hybrid):** Uses a different mechanism — `manage-bde -adbackup` writes key to the AD computer object's `msFVE-RecoveryInformation` child object. Requires the AD schema extension (`msFVE-*` attributes) which has been present since Windows Server 2008 R2.

</details>

---

## Dependency Stack

```
Layer 8: Recovery key visible in Entra Portal / Intune
              ↑ requires: successful POST to enterpriseregistration.windows.net
Layer 7: Key escrow initiated
              ↑ requires: Recovery Password protector exists + Entra device certificate valid
Layer 6: BitLocker fully encrypted (ProtectionStatus: On)
              ↑ requires: encryption completed (including WinRE partition healthy)
Layer 5: Encryption initiated by Intune BitLocker CSP
              ↑ requires: policy applied + silent requirements met (or user confirmed)
Layer 4: Intune BitLocker policy applied to device
              ↑ requires: device in scope, Intune sync successful, no conflicting GPO winning
Layer 3: Device Entra joined and Intune-enrolled
              ↑ requires: dsregcmd AzureADJoined:YES, MDM enrolled
Layer 2: TPM ready + Secure Boot enabled
              ↑ requires: UEFI firmware, TPM 2.0 enabled, PCR state clean
Layer 1: Hardware capable (UEFI, TPM 2.0 chip, no Legacy BIOS)
              ↑ prerequisite — no software fix possible if absent
```

**Key insight:** Escrow failures (Layer 7–8) are almost always internet/certificate issues, not BitLocker issues. Encryption failures (Layer 5–6) are almost always TPM/Secure Boot or policy conflicts. Don't conflate the two.

---

## Symptom → Cause Map

| Symptom | Most likely cause | Phase to check |
|---------|------------------|----------------|
| Device shows non-compliant in Intune for encryption | Encryption not started, or policy not applied | Phase 1 + Phase 2 |
| `ProtectionStatus: Off`, `EncryptionPercentage: 0` | Policy not applied, TPM not ready, or silent requirements not met | Phase 2 |
| `ProtectionStatus: Off`, `EncryptionPercentage: 100` | Encryption suspended (normal for updates, expected after BIOS change) | Phase 3 |
| Encryption stuck at % for >30 min | WinRE partition disabled/corrupt, or BDESVC stalled | Phase 4 |
| Encrypted but no key in Entra/Intune | Escrow failed (no internet, no certificate, wrong key protector) | Phase 5 |
| Event 846 in BitLocker Management log | AAD escrow failed — note the error code | Phase 5 |
| User at recovery screen after BIOS update | BIOS changed PCR 0, TPM won't unseal | Phase 6 |
| User at recovery screen for no known reason | PCR drift, BIOS update, Secure Boot state changed | Phase 6 |
| Intune reports BitLocker policy "Error" | CSP/GPO conflict, or device not meeting silent requirements | Phase 2 |
| BitLocker policy applied but wrong algorithm | Stale GPO setting overriding Intune CSP | Phase 7 |
| `TpmReady: False` | TPM in lockout, firmware disabled, or needs initialisation | Phase 8 |
| `Confirm-SecureBootUEFI` returns False | Secure Boot disabled in UEFI, or Legacy BIOS mode | Phase 8 |

---

## Validation Steps

Run in sequence. Each must pass before proceeding to the next.

```powershell
# ============================================================
# LAYER 1 — Hardware and firmware baseline
# ============================================================

# UEFI mode and Secure Boot
Confirm-SecureBootUEFI
# Must return True. False = Secure Boot off or Legacy BIOS mode.
# If error: "Cmdlet not supported on this platform" = Legacy BIOS — cannot support silent encryption

# TPM state
Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, TpmActivated, TpmOwned, ManufacturerId, ManufacturerVersion
# TpmPresent: True, TpmReady: True, TpmEnabled: True — all required

# ============================================================
# LAYER 2 — Entra join and MDM enrollment
# ============================================================

dsregcmd /status | Select-String "AzureADJoined|DomainJoined|MdmEnrollmentUrl|TenantId|DeviceId|KeySignKeyNames"
# AzureADJoined: YES — required for Entra escrow
# MdmEnrollmentUrl populated — MDM enrolled

# ============================================================
# LAYER 3 — Intune policy receipt
# ============================================================

# Check registry for BitLocker policy from MDM/GPO
reg query "HKLM\SOFTWARE\Policies\Microsoft\FVE" /s
# If empty — no policy applied. Check Intune assignment.
# If populated — note which values (encryption method, startup auth, etc.)

reg query "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker" /s
# MDM-side policy. Compare with FVE registry above for conflicts.

# ============================================================
# LAYER 4 — BitLocker volume state
# ============================================================

Get-BitLockerVolume -MountPoint C: | 
  Select-Object MountPoint, ProtectionStatus, EncryptionPercentage, EncryptionMethod, VolumeType, VolumeStatus
# ProtectionStatus: On, EncryptionPercentage: 100, VolumeStatus: FullyEncrypted = healthy

# Key protectors — both TPM and RecoveryPassword must exist
(Get-BitLockerVolume -MountPoint C:).KeyProtector | 
  Select-Object KeyProtectorType, KeyProtectorId

# ============================================================
# LAYER 5 — Recovery key escrow
# ============================================================

# Check escrow event log
Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -MaxEvents 100 |
  Where-Object { $_.Id -in 845, 846, 851, 853 } |
  Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap

# 845 = Key backed up to AAD successfully
# 846 = Key backup to AAD FAILED (look at error code in message)
# 851 = BitLocker cannot complete encryption (WinRE/partition issue)
# 853 = Encryption not started — silent requirement not met

# ============================================================
# LAYER 6 — WinRE and disk layout
# ============================================================

reagentc /info
# Status: Enabled = WinRE healthy
# If Disabled: encryption will stall or fail to initiate

Get-Partition | Select-Object DiskNumber, PartitionNumber, @{N='SizeGB';E={[math]::Round($_.Size/1GB,2)}}, Type, DriveLetter, IsActive
# Expect: System (EFI ~100MB), Recovery (~500MB+), Primary (C:)
# Missing recovery partition = WinRE cannot be enabled = encryption may stall
```

---

## Troubleshooting Steps

### Phase 1 — Confirm scope and environment

```powershell
# What is the current overall state?
manage-bde -status C:
Get-BitLockerVolume | Format-List

# Is this Entra-joined, Hybrid, or Workplace-joined?
dsregcmd /status

# Is device enrolled in Intune?
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" | ForEach-Object {
    Get-ItemProperty $_.PsPath -ErrorAction SilentlyContinue
} | Where-Object { $_.EnrollmentType -ne $null } | Select-Object EnrollmentType, UPN, DiscoveryServiceFullURL
```

### Phase 2 — Policy delivery and application

```powershell
# Force Intune sync — policy delivery
Start-Process -FilePath "C:\Windows\System32\DeviceManagement\dmclient.exe" -ArgumentList "/ProviderID MDM" -NoNewWindow
Start-Sleep -Seconds 30

# Generate full MDM diagnostics report
mdmdiagnosticstool.exe -area DeviceEnrollment;DeviceProvisioning;Autopilot -zip C:\Temp\MDMDiag.zip
# Unzip, open MDMDiagReport.html
# Sections to check:
#   "Configuration" → search for BitLocker CSP nodes
#   "Error" section → any CSP delivery failures

# Check for GPO conflict — is GPO writing FVE keys?
gpresult /h C:\Temp\gpresult.html /f
# Open HTML, search "BitLocker" and "FVE" — any hits from a GPO = potential conflict

# Compare what GPO set vs what MDM set
$gpoFVE = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\FVE" -ErrorAction SilentlyContinue
$mdmBL = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker" -ErrorAction SilentlyContinue
Write-Host "GPO FVE Settings:"; $gpoFVE | Format-List
Write-Host "MDM BitLocker Settings:"; $mdmBL | Format-List
```

### Phase 3 — Encryption suspended

```powershell
# Confirm it's suspended (not failed)
manage-bde -status C:
# "Protection Status: Protection Off" + "Percentage Encrypted: 100%" = suspended

# Who suspended it and when?
Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -MaxEvents 50 |
  Where-Object { $_.Id -in 781, 780, 784 } |
  Select-Object TimeCreated, Id, Message
# 781 = BitLocker protection disabled (suspended)
# 780 = BitLocker protection re-enabled

# Safe to resume if no pending reboot/update in progress
manage-bde -protectors -enable C:
manage-bde -status C:
```

### Phase 4 — Encryption stalled mid-progress

```powershell
# Check current percentage — run twice 60 seconds apart to see if it's moving
Get-BitLockerVolume -MountPoint C: | Select-Object EncryptionPercentage
Start-Sleep -Seconds 60
Get-BitLockerVolume -MountPoint C: | Select-Object EncryptionPercentage

# If not moving — check WinRE
reagentc /info

# Check BDESVC service
Get-Service BDESVC | Select-Object Status, StartType
# If stopped:
Start-Service BDESVC
Start-Sleep -Seconds 10
Get-BitLockerVolume -MountPoint C: | Select-Object EncryptionPercentage  # Should start moving

# Check for Event 851 — partition/space issue
Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -MaxEvents 50 |
  Where-Object { $_.Id -eq 851 } | Select-Object TimeCreated, Message | Format-List

# Check available disk space
Get-PSDrive C | Select-Object @{N='FreeGB';E={[math]::Round($_.Free/1GB,2)}}
```

### Phase 5 — Escrow failure investigation

```powershell
# Get detailed escrow failure info
Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -MaxEvents 100 |
  Where-Object { $_.Id -eq 846 } | Select-Object TimeCreated, Message | Format-List
# Look at the error code in the message — common: 0x80072F8F (TLS/cert), 0x80072EE7 (DNS), 0x80070032 (no recovery key protector)

# Test connectivity to Entra escrow endpoint
Test-NetConnection -ComputerName "enterpriseregistration.windows.net" -Port 443
Test-NetConnection -ComputerName "login.microsoftonline.com" -Port 443

# Verify device has AAD device certificate
Get-ChildItem "Cert:\LocalMachine\My" | Where-Object { $_.Issuer -match "MS-Organization-Access" }
# Must return a certificate. Missing = device certificate issue, may need to re-join Entra.

# Check the device cert validity
Get-ChildItem "Cert:\LocalMachine\My" | Where-Object { $_.Issuer -match "MS-Organization-Access" } |
  Select-Object Thumbprint, Subject, NotBefore, NotAfter, @{N='Valid';E={ $_.NotAfter -gt (Get-Date) }}

# Attempt manual escrow
$keyId = (Get-BitLockerVolume -MountPoint C:).KeyProtector |
  Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" } |
  Select-Object -ExpandProperty KeyProtectorId

BackupToAAD-BitLockerKeyProtector -MountPoint "C:" -KeyProtectorId $keyId
# Note: if this throws "Access Denied" or connectivity error, the problem is at network/cert layer
```

### Phase 6 — Recovery after TPM mismatch (PCR drift)

```powershell
# After user has unlocked with recovery key — confirm drive is accessible
manage-bde -status C:
# ProtectionStatus should now show: Protection Off (temporarily, awaiting resume)

# Resume protection (re-seals VMK to current PCR values)
manage-bde -protectors -enable C:

# If this was caused by a BIOS update, the new PCR 0 value is now sealed — no further intervention
# If caused by Secure Boot state change — verify Secure Boot is in desired state first
Confirm-SecureBootUEFI

# Rotate recovery key and re-escrow (key used in recovery should be rotated)
$vol = Get-BitLockerVolume -MountPoint C:
$oldKey = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }
Remove-BitLockerKeyProtector -MountPoint C: -KeyProtectorId $oldKey.KeyProtectorId
Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector

$newKeyId = (Get-BitLockerVolume -MountPoint C:).KeyProtector |
  Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" } |
  Select-Object -ExpandProperty KeyProtectorId
BackupToAAD-BitLockerKeyProtector -MountPoint "C:" -KeyProtectorId $newKeyId

# Verify escrow
Start-Sleep -Seconds 15
Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -MaxEvents 10 |
  Where-Object { $_.Id -eq 845 } | Select-Object TimeCreated, Message
```

### Phase 7 — GPO vs Intune CSP conflict resolution

```powershell
# Identify the conflicting GPO
gpresult /scope computer /v | Select-String -Pattern "FVE|BitLocker" -Context 5,2

# Check which registry keys are populated and by what source
# HKLM\SOFTWARE\Policies\Microsoft\FVE = GPO-controlled (or Intune writing to GPO path — some old profiles)
# HKLM\SOFTWARE\Microsoft\PolicyManager = MDM CSP-controlled

# Find which values are in conflict
$gpoValues = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\FVE" -ErrorAction SilentlyContinue).PSObject.Properties |
  Where-Object { $_.Name -notmatch "^PS" }
$gpoValues | Select-Object Name, Value | Format-Table

# If GPO is intentionally configuring BitLocker and Intune should not be:
#   Remove Intune BitLocker profile from device assignment in Intune Portal

# If Intune should own BitLocker and GPO is interfering:
#   Option A: Remove BitLocker settings from the GPO
#   Option B: Enable MDM wins via Intune Settings Catalog: 
#     "Configure MDM wins over GP" → Enabled
#     (covers only policies listed in the MDM-over-GPO support list — BitLocker is NOT fully covered)

# Verify after GPO change:
gpupdate /force
Start-Sleep -Seconds 30
reg query "HKLM\SOFTWARE\Policies\Microsoft\FVE" /s
# Should be empty if GPO settings removed
```

### Phase 8 — TPM and Secure Boot remediation

```powershell
# Detailed TPM diagnostics
Get-Tpm | Format-List *
tpm.msc   # GUI — TPM Management console (visual check)

# Check TPM version (must be 2.0 for silent encryption)
Get-WmiObject -Namespace "root\cimv2\security\microsofttpm" -Class Win32_Tpm |
  Select-Object SpecVersion, IsActivated_InitialValue, IsEnabled_InitialValue, IsOwned_InitialValue

# If TpmReady: False with LockoutCount > 0:
Get-Tpm | Select-Object LockoutCount, LockoutHealTime
# Auto-heals; or clear lockout via: Clear-TpmAuthorizationValue (requires admin + physical access)

# If TPM needs initialisation
Initialize-Tpm -AllowClear -AllowPhysicalPresence

# Secure Boot state
Confirm-SecureBootUEFI
# If not enabled: must change in UEFI firmware
# Note: changing Secure Boot state on an already-encrypted device will trigger recovery
# Always suspend BitLocker before changing Secure Boot state:
Suspend-BitLocker -MountPoint C: -RebootCount 1   # Auto-resumes after next reboot
```

---

## Remediation Playbooks

<details>
<summary><strong>Playbook 1 — Enable silent encryption from scratch (new device not encrypting)</strong></summary>

**Pre-check:** All silent requirements met (UEFI, TPM 2.0, Secure Boot, DMA protection).

```powershell
# Step 1: Verify prerequisites
$secureBoot = Confirm-SecureBootUEFI
$tpm = Get-Tpm
$winre = reagentc /info

Write-Host "Secure Boot: $secureBoot"
Write-Host "TPM Ready: $($tpm.TpmReady)"
Write-Host "WinRE: $(($winre | Select-String 'Status').ToString())"

# Step 2: Force Intune policy sync
Start-Process "C:\Windows\System32\DeviceManagement\dmclient.exe" -ArgumentList "/ProviderID MDM" -NoNewWindow
Start-Sleep -Seconds 60

# Step 3: Check if policy now applied
reg query "HKLM\SOFTWARE\Policies\Microsoft\FVE" /s
# If still empty — policy not delivered. Check Intune assignment in portal.

# Step 4: If policy present but encryption not starting — check for Event 853
Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -MaxEvents 30 |
  Where-Object { $_.Id -eq 853 } | Select-Object TimeCreated, Message | Format-List
# Event 853 message identifies which silent requirement failed

# Step 5: If you need to manually trigger (break-glass — should be policy-driven normally)
Enable-BitLocker -MountPoint C: -EncryptionMethod XtsAes128 -TpmProtector -RecoveryPasswordProtector
# This will NOT create the AAD protector — run escrow separately after
```

**Rollback:** `Disable-BitLocker -MountPoint C:` — decrypts the volume (takes time proportional to drive size).

</details>

<details>
<summary><strong>Playbook 2 — Force recovery key escrow to Entra</strong></summary>

**Use when:** Device is encrypted, key not in Entra Portal, need to remediate before audit/compliance deadline.

```powershell
# Step 1: Confirm recovery key protector exists
$keyProtectors = (Get-BitLockerVolume -MountPoint C:).KeyProtector
$recoveryKey = $keyProtectors | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }

if (-not $recoveryKey) {
    Write-Host "No recovery key protector — adding one..."
    Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector
    $recoveryKey = (Get-BitLockerVolume -MountPoint C:).KeyProtector |
      Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }
}

# Step 2: Verify internet and Entra endpoint
$test = Test-NetConnection -ComputerName "enterpriseregistration.windows.net" -Port 443
if (-not $test.TcpTestSucceeded) {
    Write-Host "BLOCKED: Cannot reach Entra escrow endpoint. Fix network/firewall first."
    exit
}

# Step 3: Verify device certificate
$cert = Get-ChildItem "Cert:\LocalMachine\My" | Where-Object { $_.Issuer -match "MS-Organization-Access" }
if (-not $cert) {
    Write-Host "MISSING: Entra device certificate not found. Device may need to re-join Entra."
    exit
}
Write-Host "Device cert valid until: $($cert.NotAfter)"

# Step 4: Force escrow
$keyId = $recoveryKey.KeyProtectorId
BackupToAAD-BitLockerKeyProtector -MountPoint "C:" -KeyProtectorId $keyId
Write-Host "Escrow command sent. Checking event log..."

Start-Sleep -Seconds 15
$escrowEvent = Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -MaxEvents 5 |
  Where-Object { $_.Id -in 845, 846 } | Select-Object -First 1
Write-Host "Last escrow event: ID=$($escrowEvent.Id) — $($escrowEvent.Message)"
```

**Rollback:** N/A — escrow is additive and does not modify encryption state.

</details>

<details>
<summary><strong>Playbook 3 — Resolve GPO/Intune BitLocker conflict</strong></summary>

**Use when:** Intune BitLocker policy reports "Error" or wrong settings are applied; both GPO and MDM writing to FVE registry.

```powershell
# Step 1: Document current state before changes
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$backup = "C:\Temp\bitlocker-policy-backup-$timestamp"
New-Item -ItemType Directory -Path $backup -Force

reg export "HKLM\SOFTWARE\Policies\Microsoft\FVE" "$backup\FVE-GPO.reg"
reg export "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker" "$backup\BitLocker-MDM.reg" 2>$null
gpresult /h "$backup\gpresult.html" /f

Write-Host "Backup saved to $backup"

# Step 2: Identify the conflicting GPO
$gpresultPath = "$backup\gpresult.html"
# Open in browser and search for BitLocker/FVE — note the GPO name

# Step 3a: Remove GPO BitLocker settings (preferred — do this in GPMC on DC or via admin workstation)
# In Group Policy Management Console:
#   Edit the identified GPO → Computer Configuration → Policies → 
#   Administrative Templates → Windows Components → BitLocker Drive Encryption
#   Set all BitLocker settings to "Not Configured"

# Step 3b: OR enable MDM wins (Windows 10 1803+, supported policies only)
# In Intune: Create Configuration Profile → Settings Catalog
# Search: "Configure MDM wins over GP" → Set to Enabled
# Note: BitLocker CSP is NOT fully covered by MDM wins — GPO removal is more reliable

# Step 4: Apply and verify
gpupdate /force
Start-Sleep -Seconds 30
Start-Process "C:\Windows\System32\DeviceManagement\dmclient.exe" -ArgumentList "/ProviderID MDM" -NoNewWindow
Start-Sleep -Seconds 60

reg query "HKLM\SOFTWARE\Policies\Microsoft\FVE" /s
# Should be empty if GPO removed BitLocker settings
```

**Rollback:** Restore saved .reg file: `reg import "C:\Temp\bitlocker-policy-backup-<date>\FVE-GPO.reg"`

</details>

<details>
<summary><strong>Playbook 4 — Remediate WinRE and re-initiate encryption</strong></summary>

**Use when:** Encryption stuck, Event 851 present, `reagentc /info` shows Status: Disabled.

```powershell
# Step 1: Check current WinRE state
reagentc /info

# Step 2: Attempt simple re-enable
reagentc /enable
reagentc /info
# If Status: Enabled → proceed to Step 4

# Step 3: If re-enable fails — check partition layout
Get-Partition | Select-Object DiskNumber, PartitionNumber, @{N='SizeMB';E={[math]::Round($_.Size/1MB)}}, Type, DriveLetter

# Scenario A: Recovery partition exists but WinRE is on wrong path
# Find where winre.wim is
Get-ChildItem -Path C:\Windows\System32\Recovery -Filter "winre.wim" -ErrorAction SilentlyContinue
# If found, re-register:
reagentc /setreimage /path C:\Windows\System32\Recovery
reagentc /enable

# Scenario B: Recovery partition too small or missing
# This requires diskpart to resize/create — see escalation if partition work needed
# Minimum size: 500MB for WinRE. For BitLocker, 750MB recommended.

# Step 4: After WinRE enabled, restart encryption
# Check if BitLocker auto-resumes:
Start-Sleep -Seconds 30
Get-BitLockerVolume -MountPoint C: | Select-Object EncryptionPercentage

# If not auto-resuming, restart BDESVC:
Restart-Service BDESVC
Start-Sleep -Seconds 10
Get-BitLockerVolume -MountPoint C: | Select-Object EncryptionPercentage
```

**Rollback:** `reagentc /disable` (if re-enabling WinRE causes other issues).

</details>

---

## Evidence Pack

Run on affected device — generates a diagnostic bundle for escalation to Microsoft or senior engineer.

```powershell
# ============================================================
# BitLocker Evidence Collection Script
# Run as: Local Administrator
# Output: C:\Temp\BL-Evidence-<timestamp>.zip
# ============================================================

$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$evidencePath = "C:\Temp\BL-Evidence-$timestamp"
New-Item -ItemType Directory -Path $evidencePath -Force | Out-Null

Write-Host "Collecting BitLocker evidence to $evidencePath..." -ForegroundColor Cyan

# --- BitLocker volume status ---
manage-bde -status > "$evidencePath\manage-bde-status.txt"
Get-BitLockerVolume | Format-List * | Out-File "$evidencePath\bitlocker-volume.txt"
(Get-BitLockerVolume -MountPoint C:).KeyProtector | Format-List | Out-File "$evidencePath\key-protectors.txt"

# --- TPM state ---
Get-Tpm | Format-List * | Out-File "$evidencePath\tpm-state.txt"
Get-WmiObject -Namespace "root\cimv2\security\microsofttpm" -Class Win32_Tpm |
  Format-List * | Out-File "$evidencePath\tpm-wmi.txt"

# --- Secure Boot ---
try { Confirm-SecureBootUEFI } catch { "Error: $_" } | Out-File "$evidencePath\secure-boot.txt"

# --- Device join state ---
dsregcmd /status | Out-File "$evidencePath\dsregcmd-status.txt"

# --- WinRE ---
reagentc /info | Out-File "$evidencePath\winre-info.txt"

# --- Disk layout ---
Get-Partition | Select-Object DiskNumber, PartitionNumber, 
  @{N='SizeMB';E={[math]::Round($_.Size/1MB)}}, Type, DriveLetter, IsActive, IsSystem |
  Format-Table | Out-File "$evidencePath\partition-layout.txt"

# --- Policy registry ---
reg query "HKLM\SOFTWARE\Policies\Microsoft\FVE" /s 2>&1 | Out-File "$evidencePath\registry-FVE-GPO.txt"
reg query "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker" /s 2>&1 |
  Out-File "$evidencePath\registry-BitLocker-MDM.txt"

# --- Event logs ---
# BitLocker Management (most important)
Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -MaxEvents 200 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, LevelDisplayName, Message |
  Export-Csv "$evidencePath\events-bitlocker-management.csv" -NoTypeInformation

# System log — TPM/BitLocker service errors
Get-WinEvent -LogName System -MaxEvents 500 -ErrorAction SilentlyContinue |
  Where-Object { $_.ProviderName -match "TPM|BitLocker|BDESVC" } |
  Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
  Export-Csv "$evidencePath\events-system-tpm-bl.csv" -NoTypeInformation

# --- MDM diagnostics ---
mdmdiagnosticstool.exe -area DeviceEnrollment;DeviceProvisioning -zip "$evidencePath\MDMDiag.zip" 2>&1 |
  Out-File "$evidencePath\mdmdiag-output.txt"

# --- GPO result ---
gpresult /h "$evidencePath\gpresult.html" /f 2>&1 | Out-File "$evidencePath\gpresult-output.txt"

# --- Network connectivity to Entra ---
Test-NetConnection -ComputerName "enterpriseregistration.windows.net" -Port 443 |
  Format-List | Out-File "$evidencePath\network-entra-test.txt"

# --- Device certificate ---
Get-ChildItem "Cert:\LocalMachine\My" | Where-Object { $_.Issuer -match "MS-Organization-Access" } |
  Select-Object Thumbprint, Subject, Issuer, NotBefore, NotAfter,
    @{N='Valid';E={ $_.NotAfter -gt (Get-Date) }} |
  Format-List | Out-File "$evidencePath\device-cert.txt"

# --- Zip bundle ---
Compress-Archive -Path $evidencePath -DestinationPath "$evidencePath.zip" -Force
Write-Host "`nEvidence bundle: $evidencePath.zip" -ForegroundColor Green
Write-Host "Files collected:" -ForegroundColor Cyan
Get-ChildItem $evidencePath | Select-Object Name, @{N='SizeKB';E={[math]::Round($_.Length/1KB,1)}} |
  Format-Table
```

---

## Command Cheat Sheet

```powershell
# ---- STATUS ----
manage-bde -status C:                                          # Full status, all volumes
Get-BitLockerVolume                                            # All volumes, PowerShell
Get-BitLockerVolume -MountPoint C: | Select *                  # Detailed single volume
(Get-BitLockerVolume -MountPoint C:).KeyProtector             # Key protectors only

# ---- TPM ----
Get-Tpm                                                        # TPM state summary
Get-Tpm | Select *                                             # Full TPM detail
Initialize-Tpm -AllowClear -AllowPhysicalPresence             # Initialise TPM
Clear-Tpm                                                      # Clear TPM (use with caution)
tpm.msc                                                        # GUI — TPM Management

# ---- SECURE BOOT ----
Confirm-SecureBootUEFI                                         # True = Secure Boot ON
msinfo32                                                       # GUI — shows BIOS Mode + Secure Boot

# ---- ENCRYPTION CONTROL ----
manage-bde -protectors -enable C:                             # Resume suspended encryption
manage-bde -protectors -disable C: -RebootCount 1            # Suspend for next reboot only
Suspend-BitLocker -MountPoint C: -RebootCount 1              # PowerShell equivalent
Enable-BitLocker -MountPoint C: -TpmProtector                 # Enable with TPM only
Disable-BitLocker -MountPoint C:                              # Decrypt volume (slow)
manage-bde -pause C:                                          # Pause in-progress encryption
manage-bde -resume C:                                         # Resume paused encryption

# ---- KEY PROTECTORS ----
Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector    # Add recovery key
Add-BitLockerKeyProtector -MountPoint C: -TpmProtector                 # Add TPM protector
Remove-BitLockerKeyProtector -MountPoint C: -KeyProtectorId "{id}"    # Remove protector
manage-bde -protectors -get C:                                          # List all protectors + IDs
manage-bde -protectors -delete C: -type RecoveryPassword               # Remove all recovery passwords

# ---- ESCROW ----
BackupToAAD-BitLockerKeyProtector -MountPoint C: -KeyProtectorId "{id}"  # Escrow to Entra
manage-bde -protectors -adbackup C: -id "{id}"                           # Escrow to on-prem AD

# ---- DIAGNOSTICS ----
reagentc /info                                                 # WinRE status
mdmdiagnosticstool.exe -area DeviceEnrollment -zip C:\diag.zip  # MDM diagnostics
dsregcmd /status                                               # Entra join/MDM state
gpresult /h C:\gp.html /f                                      # GPO result report

# ---- EVENT LOGS ----
Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -MaxEvents 50
# Key event IDs:
# 845 = Key backed up to AAD (success)
# 846 = Key backup to AAD failed
# 851 = Cannot complete encryption (partition/WinRE issue)
# 853 = Encryption not started (silent requirement not met)
# 780 = Protection enabled
# 781 = Protection disabled (suspended)

# ---- GRAPH API — RECOVERY KEY RETRIEVAL ----
Connect-MgGraph -Scopes "BitLockerKey.Read.All","Device.Read.All"
Get-MgInformationProtectionBitlockerRecoveryKey -Filter "deviceId eq 'DEVICE-ID'" |
  ForEach-Object { Get-MgInformationProtectionBitlockerRecoveryKey -BitlockerRecoveryKeyId $_.Id -Property "key" }

# ---- ON-PREM AD — RECOVERY KEY RETRIEVAL ----
Get-ADObject -Filter { objectClass -eq "msFVE-RecoveryInformation" } `
  -SearchBase (Get-ADComputer "DEVICE-NAME").DistinguishedName `
  -Properties msFVE-RecoveryPassword | Select-Object msFVE-RecoveryPassword
```

---

## 🎓 Learning Pointers

- **PCR register deep dive** — Understanding which PCRs BitLocker measures against is essential for predicting when recovery will trigger. The default profile (PCR 7 + PCR 11) is designed to be change-resilient: BIOS updates don't trigger recovery because PCR 0 is not in the default profile. But enabling/disabling Secure Boot (PCR 7) does. To see the exact PCR profile on a device: `manage-bde -protectors -get C:` — look for "PCR Validation Profile" in the TPM protector details. Read: [Microsoft — BitLocker countermeasures and PCR](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/countermeasures)

- **TPM 1.2 vs TPM 2.0 — what actually changes** — TPM 1.2 supports SHA-1 only; TPM 2.0 supports SHA-256 and multiple algorithms. Windows 11 requires TPM 2.0. For BitLocker specifically: silent encryption in Intune requires TPM 2.0. TPM 1.2 devices can still use BitLocker with TPM-only or TPM+PIN protectors, but cannot use the silent encryption flow. If you see a TPM 1.2 device failing silent encryption, it's by design — not a misconfiguration. The fix is hardware replacement, not policy changes.

- **AAD key protector vs Recovery Password** — These are two separate protectors and serve different purposes. The AAD (Azure AD) key protector is not the recovery key — it's a protector that allows BitLocker to be transparent on Entra-joined devices (similar to how TPM protector works). The Recovery Password is the 48-digit key stored in Entra. Both must exist for a fully managed device. If only one is present, the device may function but recovery or transparency will break. Always verify both protectors exist after any BitLocker remediation.

- **Intune silent encryption failure diagnostics** — Event ID 853 is the single most useful event for silent encryption failures. The event message explicitly states which requirement was not met (e.g., "DMA protection is not enabled", "TPM is not available"). Most engineers go straight to checking policy when encryption doesn't start — going to the event log first saves significant time. The `Microsoft-Windows-BitLocker/BitLocker Management` log is not enabled by default in all tools — you may need to navigate to it manually in Event Viewer under Applications and Services Logs.

- **XTS-AES sector-level encryption** — XTS (XEX-based tweaked codebook mode with ciphertext stealing) applies a unique "tweak" per disk sector using the sector's LBA (logical block address). This means that even if two sectors have identical plaintext, their ciphertext differs. It also means ciphertext manipulation (changing bits without knowing the key) is detectable. AES-CBC, used by older BitLocker and for removable drives, doesn't have the tweak — it's more vulnerable to sector-swap attacks. Use XTS-AES 256 for high-security environments. Note: XTS-AES is incompatible with removable drives that need to be read on pre-Windows 10 1511 systems — use AES-CBC 256 for those. Read: [IEEE 1619-2007 XTS-AES standard](https://standards.ieee.org/ieee/1619/3041/)

- **The `BackupToAAD` cmdlet is not `manage-bde -adbackup`** — `BackupToAAD-BitLockerKeyProtector` (Entra escrow) and `manage-bde -adbackup` (on-prem AD escrow) are different functions writing to different stores. In hybrid environments you may want both. Intune's `ConfigureRecoveryPasswordRotation` policy only rotates and re-escrows to Entra — it doesn't update on-prem AD. If your org uses MBAM or relies on AD recovery, you need to explicitly call `manage-bde -adbackup` as well, typically via a remediation script in Intune.
