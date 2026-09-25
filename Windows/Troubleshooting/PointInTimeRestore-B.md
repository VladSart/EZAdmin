# Point-in-Time Restore (Windows 11) — Hotfix Runbook (Mode B: Ops)
> Fix, enable, or escalate a point-in-time restore (PITR) ticket in under 10 minutes.

**Status as of Sept 2026:** GA since the **June 2026 non-security update** on Windows 11 24H2/25H2 (CSP minimum **26100.8737 / 26200.8737**). **OFF by default on managed devices** (Enterprise/Education, domain-joined or MDM-enrolled Pro) until **26H2**. Restore is **local-only, from WinRE**. Intune can configure it but can't trigger a restore on physical PCs.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run elevated on the affected device (or ask the user to read out the results). Should take under 60 seconds.

```powershell
# 1. Build eligibility — CSP needs 26100.8737+ (24H2) or 26200.8737+ (25H2)
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
'{0}.{1}  {2}  {3}' -f $cv.CurrentBuild, $cv.UBR, $cv.DisplayVersion, $cv.EditionID

# 2. Are there any VSS snapshots on the OS volume right now? (PITR restore points are VSS snapshots)
Get-CimInstance Win32_ShadowCopy |
    Where-Object { $_.VolumeName -eq (Get-CimInstance Win32_Volume -Filter "DriveLetter='$env:SystemDrive'").DeviceID } |
    Sort-Object InstallDate | Select-Object InstallDate, ID, ClientAccessible

# 3. Free space vs the 20 GB eviction buffer, and OS volume size vs the 200 GB default-on threshold
Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') |
    Select-Object @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}}, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}}

# 4. VSS storage cap and who else is using VSS on this box
vssadmin list shadowstorage /for=$env:SystemDrive
vssadmin list providers

# 5. BitLocker — WinRE restore will demand the 48-digit recovery password on an encrypted OS volume
Get-BitLockerVolume -MountPoint $env:SystemDrive |
    Select-Object VolumeStatus, ProtectionStatus, @{n='HasRecoveryPassword';e={[bool]($_.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword')}}
```

| Finding | Meaning → Action |
|---|---|
| Build below 26100.8737 / 26200.8737 | CSP isn't applicable yet. Intune OMA-URI will error or no-op → patch first (Fix 1) |
| Managed device, zero shadow copies, no policy deployed | **Expected default.** PITR is OFF on managed devices until 26H2 → Fix 2 if the org wants it |
| Policy deployed, still zero snapshots after 24h+ | Check free space (row below), VSS health, and whether the device was asleep or off → Fix 4 |
| Free space ≤ 20 GB | Windows evicts restore points oldest-first to stay above 20 GB. Snapshots won't survive → Fix 4 |
| `vssadmin list shadowstorage` Max is tiny (for example 2 GB) on a busy device | Cap too low. One day of churn evicts the rest → raise `SetMaxDiskUsage` (Fix 3) |
| Non-Microsoft VSS provider or backup agent listed | Shared VSS pool. Third-party snapshots count against the same cap → Fix 4 |
| BitLocker on, `HasRecoveryPassword = False` | **Restore will be blocked at WinRE.** Fix key escrow now, before any incident → Fix 5 |
| User needs a restore *now* and has snapshots | Go to Fix 6 (restore walkthrough), then Fix 7 (post-restore validation — mandatory) |
| Snapshots older than 72h needed | Not possible with PITR (hard 72h ceiling). Use System Restore, Windows Backup, or a rebuild |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Successful point-in-time restore
│
├── WinRE reachable  (reagentc /info → Enabled)
│     └── Entry: repeated boot failure  OR  Settings > Recovery > Advanced startup
│
├── BitLocker recovery password available (if OS volume encrypted)
│     └── Escrowed to Entra ID / AD DS / MBAM and retrievable by helpdesk
│
├── ≥1 usable restore point on the OS volume
│     ├── Feature ON
│     │     ├── Unmanaged Home/Pro with OS volume ≥200 GB → ON by default
│     │     └── Managed (Ent/Edu, domain-joined or MDM Pro) → OFF until 26H2
│     │           └── Intune custom OMA-URI: ./Device/Vendor/MSFT/Recovery/PointInTimeRestore/EnablePointInTimeRestore = true
│     │                 └── Build ≥ 26100.8737 (24H2) / 26200.8737 (25H2)
│     ├── Capture actually happened
│     │     └── Device powered on at cadence (sleep/off/Modern Standby delays it) + VSS writers stable + no heavy I/O
│     └── Snapshot not evicted
│           ├── Age < retention (max 72h)
│           ├── Total VSS usage < SetMaxDiskUsage (2048–51200 MB, shared with ALL VSS consumers)
│           ├── Free space > 20 GB
│           └── No VSS diff-area failure (that wipes ALL restore points)
│
├── Free space ≥ total size of all restore points (needed to complete the restore)
├── No changed EFS-encrypted files (EFS blocks restore)
├── Same Windows edition as when the snapshot was taken (Home→Pro upgrade orphans old points)
└── AC power, no interruption (power loss mid-restore can leave the device unbootable)
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm eligibility**
   ```powershell
   $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; "$($cv.CurrentBuild).$($cv.UBR) $($cv.EditionID)"
   ```
   Expected: `26100.8737` or later / `26200.8737` or later, and `Enterprise`, `Education`, or `Professional`. Lower build means the CSP doesn't exist yet. Home can use PITR but you can't manage it with Intune.

2. **Confirm the Intune policy landed** (managed devices)
   ```powershell
   Get-WinEvent -LogName 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin' -MaxEvents 200 |
       Where-Object { $_.Message -match 'Recovery/PointInTimeRestore' } |
       Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List
   ```
   Expected: no Error-level events that mention the URI. An error that names `PointInTimeRestore` usually means the build is too old, the data type is wrong (Boolean vs Integer), or the URI case doesn't match. OMA-URIs are case-sensitive.

3. **Confirm the configured state in the UI** (fastest ground truth): **Settings > System > Recovery > Point-in-time restore > View or edit** (needs local admin or UAC). Expected: toggle **On**, the configured frequency/retention/max usage, and a list of restore point timestamps.

4. **Confirm restore points exist and are recent**
   ```powershell
   vssadmin list shadows /for=$env:SystemDrive
   ```
   Expected: one or more shadow copies with creation times inside the retention window. **Caveat:** vssadmin doesn't label which VSS client created a shadow. System Restore and third-party tools appear here too. The Settings page is the authoritative PITR list.

5. **Confirm storage headroom**
   ```powershell
   vssadmin list shadowstorage /for=$env:SystemDrive
   ```
   Expected: `Maximum Shadow Copy Storage space` roughly equal to the configured `SetMaxDiskUsage`, and free space comfortably above 20 GB **plus** the used shadow storage (the restore needs at least that much free space).

6. **Confirm the BitLocker key is retrievable** by the helpdesk, not just present on the device: Entra admin center → Devices → *device* → BitLocker keys, or `Get-ADObject -Filter 'objectClass -eq "msFVE-RecoveryInformation"' -SearchBase <computerDN>` for AD DS escrow.

---
## Common Fix Paths

<details><summary>Fix 1 — Build too old for the CSP</summary>

The PointInTimeRestore node applies only to **26100.8737+ (24H2)** and **26200.8737+ (25H2)**, which came with the June 2026 non-security update and later cumulative updates.

```powershell
# Check the latest installed update and whether reboot is pending
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 3
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
```
Push the current cumulative update through your update ring or Autopatch. After the reboot, force an MDM sync: **Settings > Accounts > Access work or school > Info > Sync**, or from Intune: Devices > *device* > **Sync**. Recheck Triage step 1.
</details>

<details><summary>Fix 2 — Enable PITR on managed devices via Intune (OMA-URI)</summary>

As of Sept 2026, community guidance (Wolkenman, Aug 2026; Interian, Sept 2026) says there's **no Settings Catalog entry** yet. Check the Settings Catalog for "point-in-time" first. If it's there, use it instead.

Intune → Devices → Configuration → Create → **Windows 10 and later** → Templates → **Custom**. Add these rows (URIs are case-sensitive):

| OMA-URI | Data type | Example value | Notes |
|---|---|---|---|
| `./Device/Vendor/MSFT/Recovery/PointInTimeRestore/EnablePointInTimeRestore` | Boolean | `True` | Required. The other three depend on it |
| `./Device/Vendor/MSFT/Recovery/PointInTimeRestore/SetMaxDiskUsage` | Integer | `20480` | MB, range 2048–51200 |
| `./Device/Vendor/MSFT/Recovery/PointInTimeRestore/SetRestorePointFrequency` | Integer | `360` | Minutes. The UI offers 4/6/12/16/24 h |
| `./Device/Vendor/MSFT/Recovery/PointInTimeRestore/SetRestorePointRetention` | Integer | `4320` | Minutes. 72 h (4320) is the ceiling |

- Assign to a **pilot device group** first.
- Frequency and retention: the Learn configuration page says **Enterprise only**. The CSP reference lists Pro/Enterprise/Education/IoT. Expect them to be ignored on Pro and verify on Education. Only Enable and MaxDiskUsage are safe to rely on for Pro.
- Local equivalent for a one-off test box: Settings > System > Recovery > Point-in-time restore > View or edit > toggle On.

**Rollback:** set `EnablePointInTimeRestore` = `False` (or unassign the profile and deploy False). Existing restore points **stay** until retention or space evicts them. To free the space immediately, see Fix 4's delete step.
</details>

<details><summary>Fix 3 — Restore points exist but get evicted too fast</summary>

Cause: the `SetMaxDiskUsage` cap is too small for the device's daily change rate. The default is 2% of disk, and the minimum is 2 GB. A dev laptop or a machine with big local PSTs, VHDs, or media churns through a small cap in hours.

```powershell
# Check current cap and used space
vssadmin list shadowstorage /for=$env:SystemDrive
```
Raise `SetMaxDiskUsage` in the Intune profile (for example 20480 → 40960, max 51200). Space is **not** pre-allocated, so a higher cap costs nothing until it's used. Keep free space above 20 GB anyway, or the buffer rule evicts snapshots regardless of the cap.
</details>

<details><summary>Fix 4 — No snapshots being captured, or all of them disappeared</summary>

Work through these in order:

```powershell
# a) Free space — the 20 GB buffer rule. At or below 20 GB free, restore points are evicted oldest-first
Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') | Select-Object SizeRemaining

# b) VSS writer health — an unstable writer means capture fails
vssadmin list writers | Select-String -Pattern 'Writer name|State|Last error' -Context 0

# c) VSS / volsnap errors in the last 3 days (diff-area failure wipes ALL restore points)
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='volsnap'; StartTime=(Get-Date).AddDays(-3)} -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='VSS'; Level=2; StartTime=(Get-Date).AddDays(-3)} -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message

# d) Competing VSS consumers (System Restore, backup agents, rollback tools)
vssadmin list providers
Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Select-Object -Last 5
```

| Finding | Fix |
|---|---|
| Free ≤ 20 GB | Free space: Storage Sense, clear `C:\Windows\SoftwareDistribution\Download`, move data to OneDrive. Then wait one frequency cycle, because the buffer is only checked at restore-point cadence |
| Writer in failed state | Restart the owning service (for example `Restart-Service VSS`, `Restart-Service SQLWriter`), or reboot. Recheck `vssadmin list writers` |
| volsnap 25/36 events (diff area couldn't grow / shadow copies deleted) | Disk too full or I/O too heavy. Fix space, and consider raising the cap |
| Third-party VSS rollback tool installed | Microsoft recommends against combining PITR with other VSS backup tools. Pick one, or raise the cap and accept shorter history |
| Device asleep or off most of the day | Expected. Capture timing isn't guaranteed. No fix, set expectations |

**Destructive (only to reclaim space intentionally):** `vssadmin delete shadows /for=C: /oldest` removes the oldest shadow for that volume. It removes it **whichever tool created it**, including System Restore points and backup-agent snapshots. There's no undo.
</details>

<details><summary>Fix 5 — BitLocker recovery password missing or not escrowed</summary>

Without the recovery password, the WinRE restore can't proceed on an encrypted OS volume.

```powershell
$mv = Get-BitLockerVolume -MountPoint $env:SystemDrive
$rp = $mv.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword'
if (-not $rp) { Add-BitLockerKeyProtector -MountPoint $env:SystemDrive -RecoveryPasswordProtector; $mv = Get-BitLockerVolume -MountPoint $env:SystemDrive; $rp = $mv.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' }
# Escrow to Entra ID (Entra-joined / hybrid-joined)
$rp | ForEach-Object { BackupToAAD-BitLockerKeyProtector -MountPoint $env:SystemDrive -KeyProtectorId $_.KeyProtectorId }
# OR escrow to AD DS (domain-joined, GPO permits AD backup)
# $rp | ForEach-Object { Backup-BitLockerKeyProtector -MountPoint $env:SystemDrive -KeyProtectorId $_.KeyProtectorId }
```
Then verify it's visible in the Entra admin center under the device's BitLocker keys. See `Windows/Troubleshooting/BitLocker/BitLocker-B.md` for escrow failures.
</details>

<details><summary>Fix 6 — Walk a user through a restore (local, WinRE)</summary>

**Before you start, get these decisions made and recorded in the ticket:**

- Which restore point: pick the last one **before** the first symptom, not just the newest.
- What local work since then will be lost. OneDrive-synced files aren't rolled back, but anything local-only is.
- Whether this is a suspected compromise. If so, **stop**. Incident response decides whether to restore and what evidence to preserve first.

**Steps:**

1. Plug into AC power.
2. Get into WinRE: **Settings > System > Recovery > Advanced startup > Restart now**, or it opens automatically after repeated boot failures. From a sign-in screen, Shift + Restart also works.
3. **Troubleshoot > Point-in-time restore**.
4. Enter the BitLocker recovery key. Read it to the user over a verified channel, never in chat or email.
5. Select the restore point, **Continue** (risk acknowledgement), review OS version and data-loss warning, then **Restore**.
6. Don't power off. The device reboots into Windows when it's done.

If **Point-in-time restore** isn't in the Troubleshoot menu, the feature isn't available on this device (build, or no restore points). Fall back to System Restore, Uninstall Updates, QMR, or Reset.
</details>

<details><summary>Fix 7 — Post-restore validation (mandatory, every time)</summary>

The restore rolls back **everything on the OS volume**, including passwords, certificates, keys, security updates and policies. Run this straight after the device boots:

```powershell
# Updates reverted? Get it current again
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 3

# MDM re-sync and Defender health
Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -TaskName 'Schedule #3 created by enrollment client' -ErrorAction SilentlyContinue | Start-ScheduledTask
Get-MpComputerStatus | Select-Object AMServiceEnabled, RealTimeProtectionEnabled, AntivirusSignatureLastUpdated

# Entra / domain trust
dsregcmd /status | Select-String 'AzureAdJoined|DomainJoined|AzureAdPrt '
Test-ComputerSecureChannel -ErrorAction SilentlyContinue   # domain-joined only

# BitLocker: protectors are back to their pre-snapshot state → re-escrow whatever is on disk now
Get-BitLockerVolume -MountPoint $env:SystemDrive | Select-Object -ExpandProperty KeyProtector |
    Where-Object KeyProtectorType -eq 'RecoveryPassword' |
    ForEach-Object { BackupToAAD-BitLockerKeyProtector -MountPoint $env:SystemDrive -KeyProtectorId $_.KeyProtectorId }
```

| Symptom after restore | Fix |
|---|---|
| `Test-ComputerSecureChannel` = False (domain-joined) | Machine account password rotated after the snapshot, so the restored copy is stale. Run `Test-ComputerSecureChannel -Repair -Credential (Get-Credential)` |
| Windows LAPS admin password in Entra/AD doesn't work | The local password reverted but the directory holds the newer one. Run `Reset-LapsPassword` on the device, then retrieve the new one |
| Outlook "outdated .ost" prompt | Close Outlook, rename `%LOCALAPPDATA%\Microsoft\Outlook\*.ost`, reopen (documented known issue) |
| Recall is off and asks for presence confirmation | Documented known issue. The user confirms presence and re-enables it if the policy allows |
| Secondary data volume stays locked | Documented: auto-unlock isn't preserved if the snapshot predates encryption. Unlock with `Unlock-BitLocker -MountPoint D: -RecoveryPassword <key>`, then `Enable-BitLockerAutoUnlock -MountPoint D:` |
| OneDrive conflict copies | Documented. Work out which copy is authoritative before deleting either |

*The secure-channel, LAPS and BitLocker re-escrow rows are engineering inferences from Microsoft's statement that passwords, certificates, and keys revert. They aren't Microsoft-documented PITR known issues. See the A runbook.*
</details>

---
## Escalation Evidence

```
PITR ESCALATION — <ticket #>
Device name:            <hostname>
Build.UBR / Edition:    <e.g. 26100.8745 / Enterprise>
Join state:             <Entra-joined | Hybrid | AD | Workgroup>   Intune-managed: <Y/N>
PITR policy deployed:   <profile name, assignment group, Intune per-setting status>
Settings UI state:      <On/Off, frequency, retention, max usage as shown>
Restore points visible: <count, oldest timestamp, newest timestamp>
vssadmin shadowstorage: <Used / Allocated / Maximum>
Free space OS volume:   <GB>        OS volume size: <GB>
Other VSS providers:    <vssadmin list providers output>
volsnap/VSS errors:     <event IDs + timestamps, last 72h>
BitLocker:              <On/Off, recovery password present Y/N, escrow location verified Y/N>
Restore attempted:      <Y/N, point chosen, result, error text/screenshot from WinRE>
Post-restore checks:    <updates, MDM sync, Defender, secure channel, LAPS>
Evidence script output: Get-PointInTimeRestoreReadiness.ps1 CSV attached  <Y/N>
```

---
## 🎓 Learning Pointers

- **"OFF on managed devices" is a default, not a fault.** Most "PITR isn't working" tickets before 26H2 are just the managed-device default. Check for a deployed policy before troubleshooting VSS. Source: [Point-in-time restore for Windows (Learn)](https://learn.microsoft.com/en-us/windows/configuration/point-in-time-restore).
- **The cap is shared, and the 20 GB buffer overrides it.** `SetMaxDiskUsage` bounds *all* VSS usage on the volume, and at or below 20 GB free Windows evicts snapshots whatever the cap says. Storage is the usual root cause of short or missing history.
- **Restore is local-only today.** Intune configures it but can't trigger it on physical PCs. Don't confuse it with [Windows 365 Enterprise point-in-time restore](https://learn.microsoft.com/en-us/windows-365/enterprise/restore-overview), which is admin-triggered, cloud-stored, and keeps up to a month.
- **A restore is a security event.** It reverts patches, policies, credentials, and keys. Treat Fix 7 as mandatory. Microsoft's own guidance says to "validate and remediate devices post-restore."
- **Know the neighbours.** [Quick Machine Recovery](https://learn.microsoft.com/en-us/windows/configuration/quick-machine-recovery/) fetches a Microsoft fix for boot failures, System Restore rolls back system files over a longer window, and PITR rolls back the whole OS volume over 72 hours. See `QuickMachineRecovery-B.md` for the QMR side. It shares the same `Recovery` CSP.
- **Exact CSP nodes and build gates** are in the [Recovery CSP reference](https://learn.microsoft.com/en-us/windows/client-management/mdm/recovery-csp). Recheck it before 26H2, when defaults flip.
