# Point-in-Time Restore (Windows 11) — Reference Runbook (Mode A: Deep Dive)
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

**In scope:** Windows 11 client point-in-time restore (PITR), part of the Windows Resiliency Initiative. It went GA with the **June 2026 non-security update** for Windows 11 **24H2 and 25H2**. This covers configuration through the `Recovery` CSP `PointInTimeRestore` node (Intune custom OMA-URI), the VSS storage model, the local WinRE restore flow, and post-restore security hygiene.

**Out of scope:**

- **Windows 365 Enterprise/Business point-in-time restore.** It's a different product: cloud-stored, admin-triggered, up to one month of retention. See `Azure/Windows365/`.
- **Quick Machine Recovery (QMR).** It shares the `Recovery` CSP but is a different mechanism. See `QuickMachineRecovery-A.md`.
- **Windows Backup for Organizations** (settings restore at enrolment) and classic **System Restore**. They're only compared here.

**Assumptions:** Intune-managed or domain-joined fleet; BitLocker on the OS volume; engineer has local admin on the device and Intune Policy/Profile Manager rights.

**Source basis (fetched 25 Sept 2026):**

| Source | Date | Used for |
|---|---|---|
| [Learn: Point-in-time restore for Windows](https://learn.microsoft.com/en-us/windows/configuration/point-in-time-restore) | ms.date 23 Jun 2026 | Defaults, edition matrix, storage rules, risks, limitations, known issues |
| [Learn: Recovery CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/recovery-csp) | updated 24 Jun 2026 | Exact node paths, data types, ranges, build applicability, dependencies |
| [Support: Point-in-time restore for Windows](https://support.microsoft.com/en-us/windows/experience/backup-recovery/point-time-restore-for-windows) | ms.date 2 Jul 2026 | End-user restore flow, local-admin requirement for the UI |
| [Windows IT Pro Blog GA post](https://techcommunity.microsoft.com/blog/windows-itpro-blog/point-in-time-restore-for-windows-11-is-now-generally-available/4508101) | 22 Jun 2026 | GA timing (body wasn't retrievable; title and date confirmed) |
| Interian (Driek Desmet), "Windows 11 Point in Time Restore: Intune Setup Guide" | 23 Sep 2026 | Intune custom profile practice, pilot methodology |
| Redmondmag / Campus Technology GA coverage | 23 Jun / 6 Jul 2026 | "Remote initiation via Intune recovery planned" roadmap statement |

---
## How It Works

<details><summary>Full architecture</summary>

### 1. What a restore point is

A PITR restore point is a **Volume Shadow Copy Service (VSS) snapshot of the OS volume**. Unlike System Restore, nothing is scoped out. The OS, installed apps, settings, the registry, local user files, cached credentials, certificates and private keys are all in the snapshot. VSS is copy-on-write at the block level. When a block on the live volume is about to change, the original block is copied into the **diff area** (shadow storage) first. A snapshot's size is therefore driven by **how much the volume changes after it's taken**, not by the volume's total size. This one fact explains most PITR storage behaviour.

```
Live OS volume (C:)                     Shadow storage (diff area, on C:)
┌───────────────────────┐    write     ┌──────────────────────────────────┐
│ block 1041 (changed)  │ ───────────► │ original 1041  ← snapshot T-6h   │
│ block 2203 (changed)  │  copy-on-    │ original 2203  ← snapshot T-6h   │
│ ...                   │  write       │ original 1041' ← snapshot T-0h   │
└───────────────────────┘              └──────────────────────────────────┘
                                        Bounded by SetMaxDiskUsage (shared)
```

### 2. Capture scheduling

Capture is **automatic only**. There's no manual "create PITR point now" button. That's a design difference from System Restore, which has event-triggered and manual points. The default cadence is about every 24 hours, configurable on Enterprise to 4/6/12/16/24 h, or any positive number of minutes through the CSP. Timing isn't guaranteed:

- A device that's off, asleep, or in Modern Standby at the scheduled time captures later.
- After enablement or a settings change, the next capture depends on boot timing and the last restore point. If there's no recent one, a capture is scheduled "promptly."
- Capture can fail under heavy I/O, with low disk space, or when a VSS writer is unstable.

### 3. Eviction rules (the part that bites)

Restore points are removed **oldest first** when any of these is true:

| Trigger | Notes |
|---|---|
| Older than retention | Max 72 h. The CSP takes minutes, but the product ceiling is 72 h |
| Total VSS usage exceeds the max usage cap | The cap is **for all VSS consumers** on the volume, not just PITR |
| Free space ≤ 20 GB | Checked only at the restore-point cadence. A new snapshot is still taken, then old ones are evicted until free space is above 20 GB |
| Low-space conditions reported by the OS | VSS limits or evicts |
| VSS can't preserve prior data | Full disk, memory allocation failure, diff area can't grow in time, write errors. **All** restore points are removed |

Storage accounting: restore points live inside **reserved storage** (the space Windows keeps back for updates) where possible. So much of the footprint is space the OS has already set aside, which is why Microsoft calls the storage impact "mitigated". Under pressure, points are evicted from reserved storage and stay only if there's enough ordinary free space.

### 4. Default state: the management fork

```
                      Is the device "enterprise-managed"?
                      (Ent/Edu edition, OR Pro that's domain-joined / MDM-enrolled)
                         │                               │
                        YES                              NO (Home, standalone Pro)
                         │                               │
               OFF by default until 26H2          ON by default IF OS volume ≥ 200 GB
                         │                               │
          Enable via CSP / Settings            <200 GB → OFF, can enable manually
```

The same "managed = off, unmanaged = on" fork exists for QMR. The design intent is that consumers get resilience with no action, and enterprises opt in deliberately because of the data-loss and security-rollback implications.

### 5. Configuration surface

| Setting | CSP node (`./Device/Vendor/MSFT/Recovery/PointInTimeRestore/…`) | Type / range | UI options | Editions (Learn config page) |
|---|---|---|---|---|
| On/Off | `EnablePointInTimeRestore` | bool | On/Off | Home, Pro, Enterprise |
| Max usage | `SetMaxDiskUsage` | int MB, 2048–51200 | % of disk (min 2 GB, max 50 GB) | Home, Pro, Enterprise |
| Frequency | `SetRestorePointFrequency` | int minutes, > 0 | 4/6/12/16/24 h | **Enterprise only** |
| Retention | `SetRestorePointRetention` | int minutes, > 0 | 4/6/12/16/24/72 h | **Enterprise only** |

**Documented conflict:** the CSP reference lists every PointInTimeRestore node, frequency and retention included, as applicable to **Pro, Enterprise, Education, IoT Enterprise/LTSC**. The Learn configuration page restricts frequency and retention to **Enterprise only** and doesn't mention Education. Treat frequency and retention as Enterprise-only until you've proved otherwise on a pilot device. For Education, test before relying on it.

CSP node properties that matter:

- The `PointInTimeRestore` interior node is **Atomic Required: True**.
- `SetMaxDiskUsage` and `SetRestorePointFrequency` declare a **DependsOn** `EnablePointInTimeRestore = true`. The CSP reference doesn't list the dependency for `SetRestorePointRetention`, but the configuration page says they only take effect when the feature is enabled.
- Applicability: **Windows 11 24H2 [26100.8737] and 25H2 [26200.8737] and later.**

In practice: put all four settings in **one** custom profile. Split profiles risk an ordering and dependency race, and the atomic node may reject a partial set.

### 6. The restore path

```
User/tech ──► WinRE (auto after repeated boot failure, or Settings > Recovery > Advanced startup)
               └── Troubleshoot ──► Point-in-time restore
                     ├── BitLocker recovery password (if the OS volume is encrypted)
                     ├── Pick restore point (timestamp)
                     ├── Risk acknowledgement → review OS version + data-loss warning
                     └── Restore ──► VSS revert of OS volume ──► reboot into Windows
```

Hard limits:

- **Local only.** There's no remote or Intune trigger for physical devices yet. Microsoft has said remote initiation "via Intune recovery" is planned, according to GA press coverage. Only the OS volume is restored. Other volumes aren't touched.
- **Free space ≥ total size of all restore points** is required to complete the restore.
- **EFS-encrypted files that changed** block the restore.
- **Edition change** orphans earlier points. A Home→Pro upgrade makes Home-era points unusable.
- There's no export or mount of a restore point as an image.

### 7. What reverts, and why that's a security problem

Microsoft's risk statement is explicit: the restore reverts "user files, applications, settings, passwords, certificates, and keys", and "can revert recent security updates or policies". Mapping that onto an enterprise device, the following are **engineering inferences, not Microsoft-documented PITR known issues**. Validate them in your pilot:

| Artifact on the OS volume | Directory / cloud copy | Consequence after restore |
|---|---|---|
| Computer-account password (LSA secret) | AD DS computer object | Rotates every 30 days by default. If it rotated inside the restore window, the device holds the old secret, the secure channel breaks, and domain logon fails. Same mechanics as a VM snapshot revert |
| Windows LAPS managed local admin password and its local state | Entra ID / AD DS | The directory holds the newer password. The local account has the older one, so the escrowed password doesn't work until `Reset-LapsPassword` |
| BitLocker key protectors | Entra ID / AD DS / MBAM | If a recovery password was rotated after the snapshot (Intune rotation after use), the protector on disk reverts. Re-escrow what's on disk now |
| Cumulative update level | n/a | The device may be one or more CUs behind, so it's exposed again until WU or Autopatch re-offers the update |
| MDM policy state | Intune | Device-side state reverts. Intune re-applies on next sync, but anything *removed* since the snapshot may reappear until a check-in tombstones it |
| Defender platform/engine/signatures | n/a | Reverted, then updates catch up. Check before returning to the user |
| Entra device certificate / PRT | Entra ID | Generally long-lived, so low risk. A user who changed their password after the snapshot will find cached credentials stale and needs one online sign-in |

This is why Microsoft's best practice list includes "Perform post-restore validation. Validate critical apps, security agents, and policy posture."

### 8. Documented known issues (Learn, June 2026)

- **Outlook .ost mismatch.** Outlook may say the data file is outdated. Rename or delete the `.ost` in `%LOCALAPPDATA%\Microsoft\Outlook` and let it rebuild.
- **Recall disabled after restore.** It asks for presence confirmation before re-enabling. Pre-restore Recall snapshots survive, but no new snapshot is created until re-enabled.
- **BitLocker auto-unlock not preserved** if the restore point predates BitLocker or data-volume encryption. Affected data volumes stay locked, so unlock them with the recovery key.
- **OneDrive local/cloud conflicts.** Resolve them with the OneDrive sync conflict guidance.

</details>

---
## Dependency Stack

```
                        ┌───────────────────────────────────────────┐
  Layer 7 (outcome)     │ Device restored AND returned to trusted   │
                        │ state (patched, policy-compliant, joined) │
                        └────────────────────▲──────────────────────┘
  Layer 6 (post)        Post-restore validation: WU/Autopatch, MDM sync, Defender,
                        secure channel, LAPS rotate, BitLocker re-escrow
                                             ▲
  Layer 5 (restore)     WinRE UI → PITR option → restore point → Restore
                        needs: AC power, free space ≥ Σ restore points, no changed EFS files
                                             ▲
  Layer 4 (access)      BitLocker recovery password retrievable by helpdesk
                        (Entra ID / AD DS / MBAM escrow)
                                             ▲
  Layer 3 (history)     ≥1 restore point within retention, not evicted
                        (cap, 20 GB buffer, diff-area health, other VSS consumers)
                                             ▲
  Layer 2 (config)      EnablePointInTimeRestore = true (+ cap / frequency / retention)
                        via Intune custom OMA-URI, Settings UI, or unmanaged default
                                             ▲
  Layer 1 (platform)    Windows 11 24H2 ≥26100.8737 / 25H2 ≥26200.8737 · VSS service ·
                        volsnap driver · WinRE enabled (reagentc) · NTFS OS volume
```

---
## Symptom → Cause Map

| Symptom | Most likely cause | Check |
|---|---|---|
| PITR toggle Off on a managed device, no one changed anything | Managed-device default (OFF until 26H2) | Was a policy deployed? Intune profile assignment |
| Intune custom profile shows **Error** for PITR rows | Build below 26100.8737/26200.8737, wrong data type, URI case, or edition | `CurrentBuild.UBR`, DeviceManagement-Enterprise-Diagnostic-Provider/Admin log |
| Frequency/retention rows show **Not applicable** or have no effect on Pro | Enterprise-only per the Learn config page | `EditionID` |
| Toggle On but no restore points after 24 h+ | Device rarely on, capture failed (I/O, VSS writer), or immediately evicted (≤20 GB free) | `vssadmin list writers`, volsnap/VSS events, free space |
| Only 1 restore point ever, never 72 h of history | Cap too small for daily churn, or 20 GB buffer eviction each cycle | `vssadmin list shadowstorage`, free space trend |
| All restore points vanished at once | VSS couldn't preserve prior data (diff area failed to grow, write error) | volsnap events (25, 36, 33), System log |
| PITR not in the WinRE Troubleshoot menu | Feature not available on this build, or no usable restore points | Build, Settings UI list |
| WinRE asks for a BitLocker key nobody can find | Key not escrowed, or escrowed to a different tenant or domain | Entra device → BitLocker keys, AD `msFVE-RecoveryInformation` |
| Restore fails partway | Not enough free space (needs ≥ Σ points), changed EFS files, power loss, file system corruption | WinRE error text, `cipher /u /n`, `chkdsk` from WinRE |
| Home-era restore points missing after upgrade to Pro | Edition change orphans them (documented) | Upgrade history |
| Domain logon fails after restore: "trust relationship failed" | Machine-account password rotated inside the window (inference) | `Test-ComputerSecureChannel` |
| LAPS password from Entra/AD rejected after restore | Local password reverted (inference) | `Get-LapsDiagnostics`, `Reset-LapsPassword` |
| Outlook "outdated .ost" prompt | Documented known issue | Rename `.ost` |
| Data volume D: locked after restore | Documented: auto-unlock not preserved if the snapshot predates encryption | `Get-BitLockerVolume` |
| Third-party backup snapshots disappearing since PITR enabled | Shared VSS cap: PITR churn evicts other tools' shadows, or the reverse | `vssadmin list providers`, backup-agent logs |

---
## Validation Steps

1. **Platform eligibility**
   ```powershell
   $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
   [pscustomobject]@{ Build=[int]$cv.CurrentBuild; UBR=[int]$cv.UBR; Edition=$cv.EditionID; Display=$cv.DisplayVersion }
   ```
   Good: `Build 26100 / UBR ≥ 8737` or `Build 26200 / UBR ≥ 8737`. Bad: lower UBR, where the CSP isn't applicable. On a build above 26200, check the CSP page for the new applicability line.

2. **WinRE enabled**
   ```powershell
   reagentc /info
   ```
   Good: `Windows RE status: Enabled`. Bad: `Disabled`, which means there's no way to reach the restore UI. See `QuickMachineRecovery-B.md` Fix 2.

3. **Policy delivery**
   ```powershell
   Get-WinEvent -LogName 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin' -MaxEvents 300 |
       Where-Object Message -match 'PointInTimeRestore' | Select-Object TimeCreated, Id, LevelDisplayName, Message
   ```
   Good: no errors, and the Intune per-setting status shows Succeeded. Bad: errors naming the URI. Match the error against the build and data type.

4. **Restore point inventory**
   ```powershell
   $osVol = (Get-CimInstance Win32_Volume -Filter "DriveLetter='$env:SystemDrive'").DeviceID
   Get-CimInstance Win32_ShadowCopy | Where-Object VolumeName -eq $osVol |
       Select-Object @{n='Created';e={$_.InstallDate}}, ID | Sort-Object Created
   ```
   Good: points spaced roughly at the configured frequency, the oldest near the retention boundary. Bad: none, or only one. VSS doesn't tag the creating client, so confirm against **Settings > System > Recovery > Point-in-time restore**.

5. **Storage**
   ```powershell
   vssadmin list shadowstorage /for=$env:SystemDrive
   Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') | Select-Object Size, SizeRemaining
   ```
   Good: Maximum ≈ configured cap, free space > 20 GB + used shadow storage. Bad: free ≤ 20 GB (eviction every cycle), or used ≈ max (history truncated).

6. **Restore-time prerequisites**
   ```powershell
   Get-BitLockerVolume -MountPoint $env:SystemDrive | Select-Object -ExpandProperty KeyProtector | Select-Object KeyProtectorType, KeyProtectorId
   cipher /u /n /h    # lists EFS-encrypted files on local drives without changing them (can be slow)
   ```
   Good: a RecoveryPassword protector exists **and** is escrowed; no EFS files on the OS volume (or they're known and static). Bad: no recovery password, or EFS files present in active user folders.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Configuration (feature won't turn on)**

1. Build and edition check (Validation 1).
2. Intune profile: one custom profile, four rows, URIs exactly as documented, `Boolean` for Enable and `Integer` for the rest.
3. Conflicting profiles: two profiles writing different values to the same URI produce a Conflict state. Search Intune for other profiles containing `Recovery/PointInTimeRestore`.
4. Local check: Settings UI (needs local admin/UAC).

**Phase 2 — Capture (on, but no or thin history)**

1. Device uptime pattern. A laptop that sleeps 20 h a day won't hit a 6 h cadence.
2. `vssadmin list writers`: every writer should be `Stable`, `No error`.
3. volsnap/VSS events (the evidence pack pulls these).
4. Free space trend. The 20 GB buffer is evaluated at cadence, so a device that hovers near 20 GB loses history every cycle.
5. Competing VSS consumers (`vssadmin list providers`, System Restore points, backup agents).

**Phase 3 — Restore (WinRE)**

1. PITR option missing → build or no points. Fall back to other WinRE tools.
2. BitLocker prompt → retrieve the key from escrow and verify the key ID matches the prompt's.
3. Failure mid-restore → note the exact WinRE error. Check free space vs Σ points, EFS, and file system health (`chkdsk C: /scan` from the WinRE command prompt).
4. Device unbootable after an interrupted restore → standard WinRE recovery (Startup Repair, QMR if enabled, Reset, or reimage).

**Phase 4 — Post-restore**

Run Playbook 5. Treat the device as untrusted until every row passes.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Pilot and fleet enablement via Intune</summary>

1. **Pick the pilot cohort** so it covers every model, edition, disk size and backup-agent combination. Include at least one real heavy-use laptop. An idle test VM tells you nothing about churn.
2. **Create the profile:** Devices → Configuration → Create → Windows 10 and later → Templates → Custom. Add all four rows in one profile:
   - `./Device/Vendor/MSFT/Recovery/PointInTimeRestore/EnablePointInTimeRestore` · Boolean · True
   - `./Device/Vendor/MSFT/Recovery/PointInTimeRestore/SetMaxDiskUsage` · Integer · 20480
   - `./Device/Vendor/MSFT/Recovery/PointInTimeRestore/SetRestorePointFrequency` · Integer · 360
   - `./Device/Vendor/MSFT/Recovery/PointInTimeRestore/SetRestorePointRetention` · Integer · 4320
3. **Target** a pilot device group. Use an assignment filter on `operatingSystemVersion` (see `Intune/Troubleshooting/FilterOSVersionMigration-A.md`) to exclude builds below 26100.8737, so they don't show as errors.
4. **Measure for 7 days** with `Get-PointInTimeRestoreReadiness.ps1` on each pilot device: number of points, age span, shadow storage used vs max, free-space minimum.
5. **Run one real restore** on a disposable device: create a marker file, change a setting, install an app, then restore to before those changes. Time the four stages: reported → point chosen → Windows up → user productive.
6. **Size the cap** from the measurements. If history rarely reaches retention, raise `SetMaxDiskUsage`. If devices hover near 20 GB free, fix disk hygiene first.
7. **Roll out in rings**, and update the helpdesk KB with Fix 6 and Fix 7 from the B runbook.

**Rollback:** redeploy with `EnablePointInTimeRestore = False` (unassigning alone may leave the last value in place, which is typical CSP tattoo behaviour, so push an explicit False). Existing points expire on their own. To reclaim space immediately, use Playbook 3.
</details>

<details><summary>Playbook 2 — Coexisting with third-party backup or rollback tools</summary>

The max-usage cap is the **total VSS upper bound on the volume**, and PITR can't reserve a separate pool. Microsoft recommends avoiding a combination with other VSS backup tools.

Decision table:

| Existing tool | Recommendation |
|---|---|
| Image-level endpoint backup that snapshots via VSS then uploads (for example most EDR-bundled rollback, some RMM backup agents) | Pick one as the rollback mechanism. If both are kept, raise the cap and confirm in pilot that neither tool's snapshots evict the other's history below its SLA |
| Instant-rollback products (Reboot-to-restore style) | Don't combine. Their filter drivers and PITR's VSS revert aren't designed to coexist |
| System Restore enabled | It coexists (both are Microsoft VSS clients), but System Restore points eat the same cap. Microsoft suggests trying PITR first, and System Restore for >72 h |
| File-level cloud backup (OneDrive KFM, Backup for M365) | No conflict. This is the recommended complement, because cloud data isn't rolled back |

Evidence to gather: `vssadmin list providers`, `vssadmin list shadows` (look for multiple creators' timestamps), and the backup agent's own snapshot log.
</details>

<details><summary>Playbook 3 — Reclaim space or purge restore points (destructive)</summary>

Use this when a device is critically low on space, or when decommissioning PITR.

```powershell
# 1. Record what exists (evidence before destruction)
vssadmin list shadows /for=$env:SystemDrive | Out-File "$env:TEMP\shadows-before.txt"
# 2. Stop new captures first (Intune: EnablePointInTimeRestore=False, or Settings toggle Off)
# 3. Remove oldest one at a time, re-checking free space between deletions
vssadmin delete shadows /for=$env:SystemDrive /oldest /quiet
# 4. Nuclear option — removes EVERY shadow on C: (System Restore points and backup-agent snapshots too)
# vssadmin delete shadows /for=$env:SystemDrive /all /quiet
```
**Rollback:** none. Deleted shadows can't be recovered. Tell the user that point-in-time and System Restore history is gone.
</details>

<details><summary>Playbook 4 — Guided restore for a remote user</summary>

1. **Decision gate:** confirm it isn't a security incident. If compromise is suspected, IR owns the decision, because a restore destroys volatile and on-disk evidence after the chosen point.
2. **Pick the point.** Take the last known-good timestamp from the user and ticket history, not simply the newest point. Record why.
3. **Data triage:** ask what's local-only since that point (Desktop/Downloads not under KFM, local PSTs, dev folders). Have the user copy those to OneDrive or USB if the device still boots.
4. **Key readiness:** retrieve the BitLocker recovery password and verify the key ID.
5. **Run the restore** (B runbook Fix 6). Stay on the call, and keep the device on AC.
6. **Post-restore** (Playbook 5) before the user resumes work.
</details>

<details><summary>Playbook 5 — Return the device to a trusted state</summary>

Run this elevated straight after first boot. It's designed to be idempotent.

```powershell
$report = [ordered]@{}

# 1. Patch level — kick a scan; WU/Autopatch will re-offer the reverted CU
$report.LatestHotfix = (Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1).HotFixID
Start-Process -FilePath "$env:SystemRoot\System32\UsoClient.exe" -ArgumentList 'StartInteractiveScan' -NoNewWindow

# 2. MDM sync (Intune) — trigger the enrollment client's scheduled sync tasks
Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction SilentlyContinue |
    Where-Object TaskName -like 'Schedule #3*' | Start-ScheduledTask

# 3. Defender
Update-MpSignature -ErrorAction SilentlyContinue
$mp = Get-MpComputerStatus
$report.DefenderRTP = $mp.RealTimeProtectionEnabled
$report.SigAgeDays  = $mp.AntivirusSignatureAge

# 4. Domain secure channel (domain-joined only)
if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
    $report.SecureChannel = Test-ComputerSecureChannel
    # If False: Test-ComputerSecureChannel -Repair -Credential (Get-Credential)
}

# 5. Windows LAPS — force rotation so directory and device agree again
if (Get-Command Reset-LapsPassword -ErrorAction SilentlyContinue) { Reset-LapsPassword; $report.LAPSRotated = $true }

# 6. BitLocker — re-escrow the protector that's actually on disk now
$bl = Get-BitLockerVolume -MountPoint $env:SystemDrive
$bl.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' | ForEach-Object {
    try { BackupToAAD-BitLockerKeyProtector -MountPoint $env:SystemDrive -KeyProtectorId $_.KeyProtectorId -ErrorAction Stop; $report.BitLockerEscrow = 'Entra OK' }
    catch { $report.BitLockerEscrow = "Entra escrow failed: $($_.Exception.Message)" }
}

# 7. Entra join / PRT
$ds = dsregcmd /status
$report.AzureAdJoined = ($ds | Select-String 'AzureAdJoined\s*:\s*YES') -ne $null
$report.PRT           = ($ds | Select-String 'AzureAdPrt\s*:\s*YES') -ne $null

[pscustomobject]$report
```
Then do the documented known-issue checks (Outlook .ost, Recall re-enable, locked data volumes, OneDrive conflicts), and have the user complete one representative business task before closing.
</details>

---
## Evidence Pack

The companion script `Windows/Scripts/Get-PointInTimeRestoreReadiness.ps1` collects everything below into a CSV and transcript. The inline version for when the script isn't on the box:

```powershell
$out = Join-Path $env:TEMP "PITR-Evidence-$env:COMPUTERNAME-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
    Select-Object ProductName, EditionID, DisplayVersion, CurrentBuild, UBR | Out-File "$out\os.txt"
reagentc /info                                          > "$out\reagentc.txt" 2>&1
vssadmin list shadows /for=$env:SystemDrive              > "$out\vss-shadows.txt" 2>&1
vssadmin list shadowstorage /for=$env:SystemDrive        > "$out\vss-storage.txt" 2>&1
vssadmin list writers                                    > "$out\vss-writers.txt" 2>&1
vssadmin list providers                                  > "$out\vss-providers.txt" 2>&1
Get-Volume | Select-Object DriveLetter, FileSystem, Size, SizeRemaining | Out-File "$out\volumes.txt"
Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, ProtectionStatus,
    @{n='Protectors';e={($_.KeyProtector.KeyProtectorType) -join ','}} | Out-File "$out\bitlocker.txt"
dsregcmd /status                                         > "$out\dsregcmd.txt" 2>&1
Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='volsnap';StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\volsnap-events.csv" -NoTypeInformation
Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='VSS';StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\vss-events.csv" -NoTypeInformation
Get-WinEvent -LogName 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin' -MaxEvents 500 -ErrorAction SilentlyContinue |
    Where-Object Message -match 'Recovery' | Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$out\mdm-recovery-events.csv" -NoTypeInformation
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
"Evidence: $out.zip"
```
**Do not attach** the BitLocker recovery password itself to a ticket. The pack records protector *types* only.

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| Build/UBR/edition | `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' \| Select CurrentBuild,UBR,EditionID` |
| WinRE status | `reagentc /info` |
| List shadows on OS volume | `vssadmin list shadows /for=C:` |
| Shadow storage used/max | `vssadmin list shadowstorage /for=C:` |
| VSS writer health | `vssadmin list writers` |
| Other VSS providers | `vssadmin list providers` |
| Shadows via CIM | `Get-CimInstance Win32_ShadowCopy` |
| Delete oldest shadow (destructive) | `vssadmin delete shadows /for=C: /oldest` |
| Free space | `Get-Volume -DriveLetter C` |
| BitLocker protectors | `(Get-BitLockerVolume C:).KeyProtector` |
| Escrow to Entra | `BackupToAAD-BitLockerKeyProtector -MountPoint C: -KeyProtectorId <id>` |
| EFS file scan | `cipher /u /n /h` |
| MDM CSP errors | `Get-WinEvent -LogName 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin'` |
| Post-restore trust | `Test-ComputerSecureChannel -Repair -Credential (Get-Credential)` |
| Post-restore LAPS | `Reset-LapsPassword` |
| Restore UI path | Settings > System > Recovery > Advanced startup → Troubleshoot → Point-in-time restore |

---
## 🎓 Learning Pointers

- **Copy-on-write explains the storage behaviour.** A snapshot's cost is the volume's *change rate* after it's taken, which is why a developer laptop needs a far bigger cap than a kiosk. Read [Volume Shadow Copy Service](https://learn.microsoft.com/en-us/windows-server/storage/file-server/volume-shadow-copy-service) once and the eviction rules make sense.
- **Two Microsoft pages disagree on edition scope.** The [Recovery CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/recovery-csp) lists Pro/Ent/Edu/IoT for every node, while the [configuration page](https://learn.microsoft.com/en-us/windows/configuration/point-in-time-restore) limits frequency and retention to Enterprise. Pilot on each edition you run, and don't assume.
- **"Passwords, certificates, and keys" revert.** Think about every secret that's also held in a directory (machine account, LAPS, BitLocker escrow). It's the same class of problem as reverting a domain-joined VM snapshot, so the same fixes apply.
- **PITR is one tool in a recovery ladder:** QMR (Microsoft-pushed fix for boot failures) → PITR (local 72 h whole-volume rollback) → System Restore (longer, system-only) → Reset/Autopilot reprovision with [Windows Backup for Organizations](https://learn.microsoft.com/en-us/intune/device-enrollment/windows/enable-backup-restore) for settings. It isn't a backup, because the snapshots live on the same disk.
- **Watch 26H2.** Managed-device defaults flip to ON, so any fleet not explicitly configured will start consuming VSS space and gain a user-reachable rollback path. Decide your policy (explicit True or False) before 26H2 lands.
- **Community practice:** Interian's Sept 2026 "[Windows 11 Point in Time Restore: Intune Setup Guide](https://blog.interian.be/2026/09/23/windows-11-point-in-time-restore/)" has a good pilot acceptance checklist (point availability, key retrieval, app and security validation).
