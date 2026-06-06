# BitLocker — Hotfix Runbook (Mode B: Ops)

> Fix or escalate in under 10 minutes.
> **Environment:** Windows 10/11 · Entra ID joined (Azure AD joined) or Hybrid · Intune-managed · TPM 2.0

---

## Skim Index

- [Triage (60 seconds)](#triage-60-seconds)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Triage (60 seconds)

```powershell
# 1) BitLocker status — current protection state and key protectors
manage-bde -status C:

# 2) PowerShell view — more structured, includes key protector IDs
Get-BitLockerVolume -MountPoint C: | Select-Object MountPoint, ProtectionStatus, EncryptionPercentage, KeyProtector

# 3) TPM state
Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, TpmActivated, TpmOwned, LockoutCount

# 4) Device join state (Entra/Hybrid — confirm AzureADJoined and TenantId)
dsregcmd /status | Select-String -Pattern "AzureADJoined|DomainJoined|WorkplaceJoined|TenantId|DeviceId"

# 5) Check recovery key escrow to Entra (event log — look for Event ID 845 = key backed up)
Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -MaxEvents 50 |
  Where-Object { $_.Id -in 845, 846, 851 } |
  Select-Object TimeCreated, Id, Message | Format-Table -Wrap
```

**If X → Do Y**

| What you see | Likely cause | Jump to |
|---|---|---|
| `ProtectionStatus: Off` + `EncryptionPercentage: 0` | Encryption never started — policy not applied or TPM not ready | [Fix 1](#fix-1--encryption-has-never-started-policy-not-applied) |
| `ProtectionStatus: Off` + `EncryptionPercentage: 100` | Encryption is suspended (BitLocker paused for updates/policy change) | [Fix 2](#fix-2--suspended-encryption-protecting-off-but-fully-encrypted) |
| `ProtectionStatus: On` + no Event ID 845 | Encrypted but key not escrowed to Entra | [Fix 3](#fix-3--recovery-key-not-escrowed-to-entraIntune) |
| `manage-bde -status` shows `Percentage Encrypted: X%` but stuck | Encryption stalled — often WinRE partition issue or free space | [Fix 4](#fix-4--encryption-stuck-not-completing) |
| User locked out at boot, needs key | User triggered recovery mode | [Fix 5](#fix-5--user-locked-out--needs-recovery-key) |
| `TpmReady: False` | TPM not initialised, ownership issue, or Secure Boot mismatch | [Fix 6](#fix-6--tpm-not-ready) |
| Policy applied but encryption not starting | Intune BitLocker CSP vs GPO conflict | [Fix 7](#fix-7--intune-bitlocker-policy-conflict-with-gpo) |

---

## Dependency Cascade

<details>
<summary><strong>What must be true for BitLocker to encrypt and escrow successfully</strong></summary>

```
[1] TPM chip present and enabled in UEFI firmware
         ↓ required for
[2] TPM is Ready (initialised, no lockout, ownership cleared if needed)
         ↓ required for
[3] Secure Boot is ON (UEFI mode, not Legacy/CSM)
         ↓ required for
[4] OS drive supports encryption (MBR → GPT required for silent encryption)
         ↓ combined with
[5] Intune BitLocker CSP policy applied to device
         ↓ triggers
[6] Encryption initiates (silent or user-prompted depending on config)
         ↓ on completion
[7] Recovery key generated and held by AAD key protector
         ↓ then
[8] Key escrow attempt made to Entra ID (Azure AD)
         ↓ requires
[9] Device is Entra joined AND has line-of-sight to Entra endpoint
         ↓ success =
[10] Recovery key visible in Entra Portal / Intune Portal under device
```

**Break at any layer and the next layer either fails silently or shows wrong status.**

- Silent encryption additionally requires: DMA protection enabled, no removable OS media, UEFI-only boot.
- GPO BitLocker settings override or conflict with Intune CSP if both exist — GPO wins in most cases.

</details>

---

## Diagnosis & Validation Flow

Work top-to-bottom. Stop when you find the break.

**Step 1 — Confirm join state**
```powershell
dsregcmd /status
```
- `AzureADJoined: YES` → Entra joined, key escrow to Entra should work.
- `DomainJoined: YES` + `AzureADJoined: YES` → Hybrid join. Key may escrow to both AD and Entra depending on policy.
- `AzureADJoined: NO` → Device not joined. Intune BitLocker policy will not apply correctly. Fix join state first.

**Step 2 — Check Intune policy receipt**
```powershell
# MDM diagnostics — look for BitLocker CSP under ./Device/Vendor/MSFT/BitLocker
mdmdiagnosticstool.exe -area DeviceEnrollment;DeviceProvisioning -zip C:\Temp\MDMDiag.zip
# Unzip and inspect MDMDiagReport.html → Configuration section → BitLocker

# Faster: check registry for applied policy
reg query "HKLM\SOFTWARE\Policies\Microsoft\FVE" /s
# Populated values = policy applied (GPO or MDM)
# Empty = no policy reaching device
```

**Step 3 — Confirm TPM health**
```powershell
Get-Tpm
# TpmPresent: True — chip exists
# TpmReady: True — fully operational
# TpmEnabled: True — not disabled in UEFI
# LockoutCount: 0 — not in lockout (lockout = wrong PIN attempts)
```
Expected: all `True`, `LockoutCount: 0`. Anything else → [Fix 6](#fix-6--tpm-not-ready).

**Step 4 — Check key protectors**
```powershell
(Get-BitLockerVolume -MountPoint C:).KeyProtector
# You want to see:
#   KeyProtectorType: RecoveryPassword  ← the 48-digit key
#   KeyProtectorType: Tpm               ← TPM sealing
#   KeyProtectorType: TpmPin            ← if PIN required by policy
# Missing "RecoveryPassword" = no key to escrow
```

**Step 5 — Confirm escrow event**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -MaxEvents 100 |
  Where-Object { $_.Id -in 845, 846 } |
  Select-Object TimeCreated, Id, Message | Format-List
# Event 845 = Recovery key successfully backed up to AAD
# Event 846 = Recovery key backup to AAD FAILED (note the error code)
```

**Step 6 — Check for WinRE/partition issues (if encryption stuck)**
```powershell
reagentc /info
# Status: Enabled — WinRE healthy
# Status: Disabled — WinRE offline, BitLocker encryption will stall at ~98%

# Check disk partition layout
Get-Partition | Select DiskNumber, PartitionNumber, Size, Type, DriveLetter
# You need a Recovery partition AND a System (EFI) partition
```

**Step 7 — Check for GPO conflict**
```powershell
gpresult /h C:\Temp\gpresult.html /f
# Open HTML, search for "BitLocker" or "FVE"
# Any GPO-applied BitLocker settings here = potential conflict with Intune CSP
```

---

## Common Fix Paths

<details>
<summary><strong>Fix 1 — Encryption has never started (policy not applied)</strong></summary>

**Confirms:** `ProtectionStatus: Off`, `EncryptionPercentage: 0`, `reg query HKLM\SOFTWARE\Policies\Microsoft\FVE` returns empty or no values.

```powershell
# 1. Force Intune sync
Start-Process -FilePath "C:\Windows\System32\DeviceManagement\dmclient.exe" -ArgumentList "/ProviderID MDM" -NoNewWindow
# Or via Settings > Accounts > Access work or school > Info > Sync

# 2. Wait 5 minutes, then check if policy now shows
reg query "HKLM\SOFTWARE\Policies\Microsoft\FVE" /s

# 3. If still empty — check device is in correct Entra group for BitLocker policy assignment
# Verify in Intune Portal: Devices > [device] > Device configuration > check BitLocker policy listed

# 4. If policy shows but encryption still not starting, check for silent encryption blockers:
Get-Tpm | Select TpmPresent, TpmReady
msinfo32   # Check: Secure Boot State = On; BIOS Mode = UEFI
```

**Intune Portal check:** Devices → [device] → Device configuration → confirm BitLocker profile is "Succeeded". If "Pending" or "Error" — check assignment and compliance policy.

</details>

<details>
<summary><strong>Fix 2 — Suspended encryption (Protection Off but fully encrypted)</strong></summary>

**Confirms:** `ProtectionStatus: Off`, `EncryptionPercentage: 100`, `manage-bde -status` shows `Protection Status: Protection Off`.

This is normal and expected during: Windows Update, driver installation, BIOS update, or when an admin explicitly suspended protection. BitLocker *is* encrypted — it just isn't validating the TPM measurements at boot.

```powershell
# Resume protection immediately
manage-bde -protectors -enable C:

# Verify
manage-bde -status C:
# Protection Status should now show: Protection On

# If it suspends again after reboot — something is triggering auto-suspend
# Check for pending Windows Updates or Intune policy pushing a BIOS update
```

**Note:** If the device is pending a reboot for Windows Update, let it reboot first — BitLocker will auto-resume after the update completes. Force-resuming before update reboot can cause recovery key prompt.

</details>

<details>
<summary><strong>Fix 3 — Recovery key not escrowed to Entra/Intune</strong></summary>

**Confirms:** Device is encrypted, `ProtectionStatus: On`, but no key visible in Entra Portal or Intune, and no Event ID 845 in BitLocker Management log.

**Method 1 — Force escrow via PowerShell (preferred)**
```powershell
# Get the recovery key ID
$keyId = (Get-BitLockerVolume -MountPoint C:).KeyProtector |
  Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" } |
  Select-Object -ExpandProperty KeyProtectorId

# Force backup to Azure AD
BackupToAAD-BitLockerKeyProtector -MountPoint "C:" -KeyProtectorId $keyId

# Verify — check event log for Event 845
Start-Sleep -Seconds 10
Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -MaxEvents 20 |
  Where-Object { $_.Id -eq 845 } | Select-Object TimeCreated, Message
```

**Method 2 — Force escrow via manage-bde**
```powershell
# Get numerical password ID
manage-bde -protectors -get C:
# Note the ID: {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}

manage-bde -protectors -adbackup C: -id "{paste-id-here}"
```

**Method 3 — Rotate key and escrow (if above fails)**
```powershell
# Remove existing recovery password protector and add fresh one
$vol = Get-BitLockerVolume -MountPoint C:
$oldKey = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }
Remove-BitLockerKeyProtector -MountPoint C: -KeyProtectorId $oldKey.KeyProtectorId

# Add new recovery password (auto-generates)
Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector

# Escrow new key
$newKeyId = (Get-BitLockerVolume -MountPoint C:).KeyProtector |
  Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" } |
  Select-Object -ExpandProperty KeyProtectorId
BackupToAAD-BitLockerKeyProtector -MountPoint "C:" -KeyProtectorId $newKeyId
```

**Check result in Intune:** Devices → [device] → Recovery keys tab. Key should appear within 2–5 minutes of successful escrow.

**If escrow still fails (Event 846):** Check device has internet access and Entra endpoint reachability: `Test-NetConnection -ComputerName enterpriseregistration.windows.net -Port 443`

</details>

<details>
<summary><strong>Fix 4 — Encryption stuck / not completing</strong></summary>

**Confirms:** `EncryptionPercentage` shows a value < 100 and has not moved for 30+ minutes.

**Common cause A — WinRE disabled**
```powershell
reagentc /info
# If Status: Disabled:
reagentc /enable
# Retry — encryption should resume automatically

# If reagentc /enable fails (no WinRE partition):
# WinRE partition has been deleted or is too small
# Check with: Get-Partition | Where-Object { $_.Type -eq "Recovery" }
# If missing — this requires partition resizing (see escalation)
```

**Common cause B — Insufficient free space**
```powershell
Get-PSDrive C | Select-Object Used, Free
# BitLocker needs ~500 MB free to complete encryption
# If low: clear temp files, run Disk Cleanup
```

**Common cause C — Encryption service not running**
```powershell
Get-Service BDESVC
# StartType should be Manual (triggered), Status Running during encryption
# If stopped and not auto-starting:
Start-Service BDESVC
manage-bde -status C:  # Check if percentage resumes
```

**Common cause D — Paused via Intune policy mid-flight**
```powershell
# Check if Intune pushed a "pause" or conflicting policy
# In Intune Portal: Devices > [device] > Device configuration
# Look for any conflicting profiles targeting the device
```

</details>

<details>
<summary><strong>Fix 5 — User locked out, needs recovery key</strong></summary>

**Situation:** User is at the BitLocker recovery screen (blue screen asking for 48-digit key). You need to retrieve the key fast.

**Method 1 — Entra Portal (fastest, no PowerShell needed)**
1. Sign in to [entra.microsoft.com](https://entra.microsoft.com)
2. Navigate to: **Devices → All devices → [device name]**
3. Select **BitLocker keys** tab (top nav)
4. Key ID and recovery password visible — read to user

**Method 2 — Intune Portal**
1. Sign in to [intune.microsoft.com](https://intune.microsoft.com)
2. Navigate to: **Devices → All devices → [device name]**
3. Select **Recovery keys** (left panel)
4. Recovery key visible

**Method 3 — PowerShell via Microsoft Graph**
```powershell
# Requires: Microsoft.Graph module, BitLockerKey.Read.All permission
Connect-MgGraph -Scopes "BitLockerKey.Read.All", "Device.Read.All"

# Find device
$device = Get-MgDevice -Filter "displayName eq 'DEVICE-NAME'"

# Get BitLocker keys for device
Get-MgInformationProtectionBitlockerRecoveryKey -Filter "deviceId eq '$($device.DeviceId)'" |
  ForEach-Object {
    Get-MgInformationProtectionBitlockerRecoveryKey -BitlockerRecoveryKeyId $_.Id -Property "key"
  }
```

**Method 4 — On-premises AD (Hybrid joined devices)**
```powershell
# If device is hybrid joined, key may also be in on-prem AD
Get-ADObject -Filter { objectClass -eq "msFVE-RecoveryInformation" } `
  -SearchBase (Get-ADComputer "DEVICE-NAME" -Properties DistinguishedName).DistinguishedName `
  -Properties msFVE-RecoveryPassword | Select-Object msFVE-RecoveryPassword
```

**After user is unlocked:** Follow [Fix 3](#fix-3--recovery-key-not-escrowed-to-entraIntune) to ensure key is properly escrowed — the lockout event may mean a new key was generated.

</details>

<details>
<summary><strong>Fix 6 — TPM not ready</strong></summary>

**Confirms:** `Get-Tpm` shows `TpmReady: False`, `TpmEnabled: False`, or `LockoutCount > 0`.

**Scenario A — TPM in lockout (too many wrong PIN attempts)**
```powershell
# Check lockout
Get-Tpm | Select-Object LockoutCount, LockoutHealTime

# Clear lockout (requires local admin + current TPM owner auth)
# Wait for lockout to heal naturally (auto-resets after ~2 hours in most cases)
# Or — if you have TPM owner credentials:
Clear-TpmAuthorizationValue
```

**Scenario B — TPM not enabled in firmware**
- Reboot to UEFI/BIOS settings
- Look for: Security → TPM, or Platform Trust Technology (PTT on Intel), or fTPM (on AMD)
- Enable the TPM, save, reboot
- Then verify: `Get-Tpm` → `TpmEnabled: True`

**Scenario C — TPM initialisation needed after firmware change**
```powershell
Initialize-Tpm -AllowClear -AllowPhysicalPresence
# Requires physical confirmation (keyboard press) on some devices
```

**Scenario D — Secure Boot disabled (blocks TPM-based BitLocker)**
```powershell
Confirm-SecureBootUEFI
# Returns True if Secure Boot is ON
# Returns False or error if OFF or BIOS mode
```
- If False: reboot → UEFI → Security → Secure Boot → Enable
- Note: enabling Secure Boot on a device that previously had it off may trigger BitLocker recovery on next boot

**Scenario E — TPM PCR mismatch after BIOS/firmware update**
- Expected: BitLocker suspends automatically before BIOS update (managed via Intune policy)
- If not suspended and BIOS updated: user will hit recovery screen
- Provide recovery key (Fix 5), let boot complete, then resume protection (Fix 2)

</details>

<details>
<summary><strong>Fix 7 — Intune BitLocker policy conflict with GPO</strong></summary>

**Confirms:** `gpresult /h` shows BitLocker/FVE GPO settings applied AND Intune MDM reports BitLocker policy. Device may show encryption not applying, wrong settings, or Intune reporting errors.

**Root cause:** Group Policy (`HKLM\SOFTWARE\Policies\Microsoft\FVE`) overrides Intune MDM CSP for BitLocker. Both writing to the same keys causes conflicts — GPO typically wins.

**Diagnosis:**
```powershell
# Check what GPO is setting
reg query "HKLM\SOFTWARE\Policies\Microsoft\FVE" /s

# Check what MDM is setting (Intune)
reg query "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker" /s

# They should not both have values — if both populated, you have a conflict
```

**Fix — Option A: Remove GPO BitLocker settings (preferred)**
- Identify the GPO applying BitLocker settings via `gpresult /h`
- In Group Policy Management: remove BitLocker/FVE settings from that GPO
- Run `gpupdate /force` on device
- Force Intune sync
- Wait for encryption to re-apply under CSP control

**Fix — Option B: Use MDM wins over GPO (Windows 10 1803+)**
```powershell
# Enable MDM wins via Intune: Configuration profile > Settings catalog
# Search for: "Configure MDM wins over GP"
# Set to: Enabled
# This makes Intune CSP settings take precedence for supported policies
```

**Fix — Option C: Move BitLocker management entirely to GPO (if Intune not owning it)**
- If the org uses GPO for BitLocker intentionally, remove the Intune BitLocker profile from assignment
- Ensure GPO is fully configured for encryption + escrow to AD/Entra

</details>

---

## Escalation Evidence

Copy/paste into ticket before escalating:

```text
BITLOCKER ESCALATION EVIDENCE
==============================
Date/Time      : <timestamp>
Device Name    : <hostname>
Device ID      : <from dsregcmd /status — DeviceId>
Entra Tenant   : <TenantId from dsregcmd>
OS Version     : <winver>
Engineer       : <your name>

--- JOIN STATE ---
AzureADJoined  : <YES/NO>
DomainJoined   : <YES/NO>
WorkplaceJoined: <YES/NO>

--- BITLOCKER STATUS ---
ProtectionStatus      : <On/Off>
EncryptionPercentage  : <%>
KeyProtectors present : <list from Get-BitLockerVolume>

--- TPM ---
TpmPresent    : <True/False>
TpmReady      : <True/False>
TpmEnabled    : <True/False>
LockoutCount  : <n>

--- ESCROW STATUS ---
Event 845 present : <Yes/No — with timestamp if yes>
Event 846 present : <Yes/No — error code if yes>
Key visible in Entra Portal : <Yes/No>
Key visible in Intune Portal : <Yes/No>

--- POLICY ---
FVE registry keys populated : <Yes/No>
GPO BitLocker settings found: <Yes/No — GPO name if yes>
Intune BitLocker profile     : <Name — Succeeded/Error/Pending>

--- WINRE ---
reagentc /info output: <paste>

--- ERRORS ---
Relevant event log entries (BitLocker Management log, last 24h):
<paste Event ID, timestamp, message>

--- FIXES ATTEMPTED ---
<list what was tried and result>
```

---

## 🎓 Learning Pointers

- **TPM sealing and PCR registers** — BitLocker with TPM seals the Volume Master Key (VMK) against the TPM. The TPM only releases the key if a set of PCR (Platform Configuration Register) values match what they were at encryption time. PCR 0 = BIOS/UEFI, PCR 7 = Secure Boot state, PCR 11 = BitLocker access control. A BIOS update changes PCR 0 → mismatch → recovery key required. This is why you always suspend BitLocker before BIOS updates. Read: [Microsoft — BitLocker and TPM](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/bitlocker-and-tpm)

- **Silent vs prompted encryption** — Intune can trigger encryption silently (no user interaction) or with a user prompt. Silent requires: UEFI, TPM 2.0, Secure Boot on, DMA protection (IOMMU), no external OS drive. If any condition fails, silent encryption does not start — it fails silently with no obvious error to the user. Check [Intune requirements for silent BitLocker](https://learn.microsoft.com/en-us/mem/intune/protect/encrypt-devices#silent-encryption-requirements).

- **Escrow mechanism** — The AAD key protector is a separate key protector from the RecoveryPassword. It encrypts the recovery key using the device's Azure AD public key certificate, so only Azure AD can decrypt it. `BackupToAAD-BitLockerKeyProtector` forces the device to POST the encrypted key to the Entra endpoint. Failure usually means no internet, wrong TLS, or missing device certificate.

- **XTS-AES vs AES-CBC** — Intune defaults to XTS-AES 128-bit for OS drives (XTS-AES 256 for higher security policy). AES-CBC is the legacy algorithm, still valid for removable drives (XTS-AES isn't compatible with removable media on older Windows). XTS is sector-level encryption with a tweak value — it's more resistant to ciphertext manipulation attacks. If you're migrating from on-prem GPO BitLocker (AES-CBC) to Intune (XTS-AES), the algorithm change requires decryption and re-encryption.

- **manage-bde vs PowerShell** — `manage-bde` is the classic CLI and works on all Windows versions. `Get-BitLockerVolume` / `BackupToAAD-BitLockerKeyProtector` are the modern PowerShell cmdlets. The PowerShell cmdlets are more scriptable and return structured objects. For the AAD escrow specifically, you *must* use the PowerShell cmdlet — `manage-bde -adbackup` only escrows to on-premises AD, not Entra. This is a very common mistake.

- **Community reference** — When Intune BitLocker silent encryption fails for non-obvious reasons (compliant device, TPM ready, Secure Boot on, still no encryption), check the MDM diagnostics report and the `Microsoft-Windows-BitLocker/BitLocker Management` event log together. The combination of Event 853 (encryption not started) alongside MDM policy receipt events usually pinpoints the exact silent encryption requirement that failed. [Intune BitLocker troubleshooting — Microsoft Learn](https://learn.microsoft.com/en-us/troubleshoot/mem/intune/device-protection/troubleshoot-bitlocker-policies)
