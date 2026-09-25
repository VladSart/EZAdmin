# Windows Server Backup (wbadmin) — Reference Runbook (Mode A: Deep Dive)
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
- **In scope:** the in-box Windows Server Backup feature (`Windows-Server-Backup`) on Windows Server 2016, 2019, 2022 and 2025 — `wbadmin.exe`, the `WindowsServerBackup` PowerShell module, the `wbengine` service, scheduled and one-off backups, BMR/System State/volume/file backups, catalog management and restores.
- **Out of scope:** Windows Backup for Organizations (client settings backup — see `WindowsBackup-A.md`), Azure Backup MARS agent (uses its own engine even though it can back up System State), third-party products (Veeam, Datto, etc.) except where their VSS providers interfere.
- **Typical MSP context:** small-site servers (single DC, file server, line-of-business app host) where WSB is the only or the secondary backup, often to a USB/dedicated disk or a NAS share.
- Commands assume an elevated PowerShell 5.1 session on the server.

---
## How It Works
<details><summary>Full architecture</summary>

### Components
```
wbadmin.exe / WindowsServerBackup PS module / wbadmin.msc
            │  (RPC)
            ▼
   wbengine  — Block Level Backup Engine Service (Manual trigger start)
            │
            ├── VSS requestor role ──► VSS service ──► provider (swprv or 3rd-party)
            │                                   └──► writers (System, Registry, NTDS, SQL...)
            │
            ├── Block-level reader — reads used blocks from the snapshot, not files
            │
            └── Writer to target: WindowsImageBackup\<ComputerName>\Backup <date>\*.vhdx
                                   + Catalog\ + SPPMetadataCache\ + MediaId
```

### Backup flow (one run)
1. Task Scheduler (`\Microsoft\Windows\Backup\Microsoft-Windows-WindowsBackup`) launches `wbadmin start backup` with the stored policy, or an admin runs a one-off.
2. `wbengine` enumerates source volumes. With **BMR** (`-allCritical`) it resolves every *critical volume*: the system volume, the boot volume, the EFI System Partition, any volume hosting a service binary, the AD database/logs/SYSVOL, and any volume hosting a Hyper-V VM config that the host depends on. A service with an image path on a data volume makes that data volume critical — this is why BMR sets sometimes silently include huge volumes.
3. VSS gathers writer metadata (`GatherWriterMetadata`), `wbengine` adds components, then `PrepareForBackup` → `DoSnapshotSet`. Writers freeze I/O (≤ 10 s window for the flush-and-hold), the provider creates the snapshot, writers thaw.
4. `wbengine` reads **used blocks** from each snapshot and writes them into a VHDX per volume on the target.
5. On a **dedicated disk / volume target**, after completion WSB creates a VSS snapshot *of the target* — that snapshot is the "version". Subsequent runs are block-level incrementals relative to the previous state, stored as snapshot diff area. Old versions are removed automatically when the target diff area fills.
6. On a **network share**, there is no snapshot of the target: the run overwrites the single `WindowsImageBackup\<ComputerName>` folder. One version only. A failed run mid-write can leave you with **no** valid version.
7. `BackupComplete` is signalled to writers. With **VSS full** backup, writers like SQL/Exchange mark the backup and truncate logs; with **VSS copy** they don't.
8. The catalog is updated in `%SystemRoot%\System32\WindowsImageBackup\Catalog` and on the target.

### Backup types
| Type | Contains | Restore path |
|---|---|---|
| Bare Metal Recovery (BMR) | All critical volumes + system state | WinRE → "System Image Recovery" (from DVD/ISO or recovery partition) |
| System State | Registry, COM+ class DB, boot files, SYSVOL/NTDS on DCs, cert services DB, cluster DB, IIS metabase, protected system files | `wbadmin start systemstaterecovery` (DSRM for authoritative AD) |
| Volume | Named volumes | `wbadmin start recovery -itemType:Volume` |
| Files/folders | Subset — still a VSS block-level read under the hood | `wbadmin start recovery -itemType:File` or the MMC |
| Hyper-V (2016+) | VMs via Hyper-V VSS writer / RCT | `wbadmin start recovery -itemType:App -items:Hyper-V` |

### Target behaviour matrix
| Target | Versions | Formats disk? | Offsite rotation | Notes |
|---|---|---|---|---|
| Dedicated disk (`-Disk`) | Many (limited by space) | **Yes**, hidden, no drive letter | Multiple disks can be added to one policy and rotated | Recommended |
| Volume (`-Volume`) | Many, but shares spindle with other data; performance hit | No | Awkward | Only when no spare disk |
| Network share (`-NetworkPath`) | **One** | No | Via the share's own backups | NAS SMB quirks cause VHDX failures |
| Removable (one-off only) | One per run | No | — | `wbadmin start backup` only, not scheduled |

### Why System State takes so long
System State enumerates every file owned by every Windows component (it walks the WinSxS manifest set via the System Writer). On servers with a bloated component store or many roles, this enumeration can run 30–60 min before any data is written. Keeping the component store healthy (`ComponentStore-B.md`) shortens System State runs.

### Where WSB stores policy
Policy is in the `wbengine` configuration, surfaced by `Get-WBPolicy`; the scheduled task carries only the invocation. Re-saving the policy (`Set-WBPolicy`) regenerates the task.
</details>

---
## Dependency Stack
```
[7] Restore confidence ── periodic test restore / wbadmin get items
[6] Catalog ── local %windir%\System32\WindowsImageBackup\Catalog + target copy
[5] Target ── dedicated disk | volume | SMB share (auth, space, VHDX support)
[4] wbengine ── Block Level Backup Engine service, runs as LocalSystem
[3] VSS ── service + provider (swprv) + all writers Stable + shadow storage per source volume
[2] Source volumes ── online, NTFS/ReFS, unlocked, ESP/Recovery readable, no dirty bit
[1] Scheduler ── \Microsoft\Windows\Backup task enabled, SYSTEM, server awake at schedule time
[0] Feature ── Windows-Server-Backup installed; OS patched (WSB fixes ship in CUs)
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| "Backup failed", `0x80042306` / `0x8004230F` | VSS provider failed (often orphaned 3rd-party provider) | `vssadmin list providers` |
| System State fails, event 517, System Writer missing from `list writers` | ACLs on WinSxS/Temp or corrupted component store; System Writer can't enumerate | `vssadmin list writers`; Application log VSS 8193 |
| `0x80780119` | Source shadow storage too small / source volume full | `vssadmin list shadowstorage` |
| `0x807800C5` | Target can't hold/mount VHDX (NAS, offline disk, sector size) | Target type; try a different target |
| Only one version ever shows | Network share target (by design) | `Get-WBBackupTarget` TargetType |
| Oldest versions keep disappearing | Target diff area full → automatic deletion | Target free space vs data size |
| BMR set includes a huge data volume | A service/driver image path lives on that volume → it's "critical" | `Get-WBVolume -CriticalVolumes`; `Get-CimInstance Win32_Service | ? PathName -like 'D:*'` |
| Schedule never runs | Task disabled / server asleep / policy lost after in-place upgrade | `Get-ScheduledTaskInfo` |
| `wbadmin get versions`: "no backup" but files on target | Local catalog corrupt | `wbadmin restore catalog` |
| SQL/Exchange logs growing after switching to WSB | Using VSS copy (no truncation) | `Get-WBVssBackupOption` |
| SQL/Exchange log chain broken for the other product | Both products doing VSS full | Pick one owner of truncation |
| BMR restore fails "no disk can be used for recovering the system disk" | Target server's disks smaller than source, or storage driver missing in WinRE | Load driver in WinRE; disk sizes |
| Hyper-V VM backup puts VM into saved state | VM lacks integration services / has non-VSS-capable guest | VM integration services; `Get-VMIntegrationService` |

---
## Validation Steps
1. **Feature and module**
   ```powershell
   Get-WindowsFeature Windows-Server-Backup; Get-Module -ListAvailable WindowsServerBackup
   ```
   Good: Installed; module present. Bad: Available → install.
2. **Policy content**
   ```powershell
   $p = Get-WBPolicy; $p | Format-List *; Get-WBVolume -Policy $p | Select-Object MountPath, FileSystem, TotalSpace
   ```
   Good: BMR and SystemState `True` (for servers that need recovery), schedule times set, target present.
3. **Summary**
   ```powershell
   Get-WBSummary | Format-List *
   ```
   Good: `LastSuccessfulBackupTime` within RPO (e.g. < 26 h); `LastBackupResultHR` 0.
4. **Last job detail**
   ```powershell
   Get-WBJob -Previous 1 | Format-List *
   ```
   Good: `HResult 0`, `JobState Completed`. Bad: non-zero HResult / `ErrorDescription` populated.
5. **VSS health**
   ```powershell
   vssadmin list writers; vssadmin list providers; vssadmin list shadowstorage
   ```
   Good: all writers Stable/No error; only "Microsoft Software Shadow Copy provider 1.0" (plus Hyper-V IC provider in VMs); shadow storage defined on source volumes.
6. **Browse-ability of the latest version (restore test without restoring)**
   ```powershell
   $v = (Get-WBBackupSet | Sort-Object BackupTime -Descending | Select-Object -First 1)
   wbadmin get items -version:$($v.VersionId)
   ```
   Good: volumes and applications listed. Bad: error → catalog/target problem.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Does it run?** Task state, `NextBackupTime`, `wbengine` service can start (`Start-Service wbengine`), feature installed.

**Phase 2 — Snapshot creation.** Failures before any data is written are VSS: writers, providers, shadow storage, and the 10-second flush-and-hold. Look at the `Application` log sources `VSS`, `VolSnap`, `SPP` and writer-owner apps (SQLWRITER, MSExchangeIS, NTDS). A writer timing out (`VSS_E_WRITER_TIMEOUT`) on busy SQL/Exchange servers — reschedule off-peak.

**Phase 3 — Data transfer.** Failures mid-run are target-side: space, SMB disconnects, VHDX creation, disk errors (`System` log: `disk`, `Ntfs`, `stornvme`). Check `Get-WBJob -Previous 1` for `BytesTransferred`.

**Phase 4 — Post-backup.** Target snapshot creation (dedicated disk), catalog update, `BackupComplete` to writers. Failures here produce "completed with warnings" — backups may be usable but log truncation didn't happen.

**Phase 5 — Restore.** File restore from the MMC or `wbadmin start recovery`; System State from `wbadmin start systemstaterecovery` (DCs: DSRM, see AD-BackupRestore); BMR from WinRE. Test BMR onto a VM at least once per server class — WinRE storage drivers and firmware mode (UEFI vs BIOS must match) are the usual blockers.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Rebuild a clean policy (BMR + System State to a rotated pair of dedicated disks)</summary>

```powershell
# Record the existing policy first
Get-WBPolicy | Format-List * | Out-File C:\Temp\wbpolicy-before.txt

Remove-WBPolicy -All -Force    # removes schedule; backups on targets are NOT deleted

$pol = New-WBPolicy
Add-WBBareMetalRecovery -Policy $pol
Add-WBSystemState       -Policy $pol
Add-WBVolume -Policy $pol -Volume (Get-WBVolume -CriticalVolumes)
foreach ($n in <DiskNumberA>, <DiskNumberB>) {
    $d = Get-WBDisk | Where-Object DiskNumber -eq $n
    Add-WBBackupTarget -Policy $pol -Target (New-WBBackupTarget -Disk $d -Label "WSB-$env:COMPUTERNAME-$n")
}
Set-WBSchedule -Policy $pol -Schedule 12:30, 21:00
Set-WBVssBackupOption -Policy $pol -VssCopyBackup   # if another product owns log truncation
Set-WBPolicy -Policy $pol -Force
```
**Destructive:** each newly added dedicated disk is formatted. Rollback: re-create the prior policy from the saved text; wiped disks cannot be recovered.
</details>

<details><summary>Playbook 2 — Clear a stuck VSS state without rebooting production hours</summary>

```powershell
vssadmin list shadows          # look for orphaned snapshots from a crashed job
Get-WBJob                      # confirm nothing running
Stop-Service wbengine -Force
Restart-Service VSS -Force
Restart-Service CryptSvc -Force   # System Writer
Restart-Service Winmgmt -Force    # WMI Writer (restarts dependants)
vssadmin list writers
```
If writers remain Failed, schedule a reboot. Do **not** `vssadmin delete shadows /all` on a dedicated-disk target volume — those shadows *are* your backup versions.
</details>

<details><summary>Playbook 3 — Critical-volume creep (BMR including a data volume)</summary>

```powershell
Get-WBVolume -CriticalVolumes | Select-Object MountPath, TotalSpace
Get-CimInstance Win32_Service | Where-Object { $_.PathName -match '^"?<D>:' } |
  Select-Object Name, PathName
Get-CimInstance Win32_SystemDriver | Where-Object { $_.PathName -match '<D>:' } | Select-Object Name, PathName
```
Move the offending service/agent install to C: (reinstall), or accept the size. Do not try to exclude a critical volume from BMR — WSB refuses.
</details>

<details><summary>Playbook 4 — Catalog recovery</summary>

```powershell
wbadmin restore catalog -backupTarget:<E:> -quiet
wbadmin get versions
# Only if the target catalog is also unusable:
wbadmin delete catalog -quiet
wbadmin get versions -backupTarget:<E:>   # versions still enumerable directly from the target
```
Rollback: none needed for `restore catalog`; `delete catalog` loses the local index only.
</details>

<details><summary>Playbook 5 — File-level restore to an alternate location</summary>

```powershell
wbadmin get versions -backupTarget:<E:>
wbadmin start recovery -version:<MM/DD/YYYY-HH:MM> -itemType:File `
  -items:"D:\Shares\Finance\Budget.xlsx" -recoveryTarget:"D:\Restore" -overwrite:CreateCopy -quiet
```
Always restore to an alternate path first; `-overwrite:Overwrite` on the original path is irreversible.
</details>

<details><summary>Playbook 6 — Replace a single rotated disk that failed</summary>

```powershell
$pol = Get-WBPolicy -Editable
$bad = Get-WBBackupTarget -Policy $pol | Where-Object Label -eq '<OldLabel>'
Remove-WBBackupTarget -Policy $pol -Target $bad
$d = Get-WBDisk | Where-Object DiskNumber -eq <NewDiskNumber>
Add-WBBackupTarget -Policy $pol -Target (New-WBBackupTarget -Disk $d -Label "WSB-$env:COMPUTERNAME-new")
Set-WBPolicy -Policy $pol -Force
```
</details>

---
## Evidence Pack
```powershell
$out = "C:\Temp\WSB-Evidence-$env:COMPUTERNAME-$(Get-Date -f yyyyMMdd-HHmm)"
New-Item $out -ItemType Directory -Force | Out-Null
Get-ComputerInfo -Property OsName, OsVersion, OsBuildNumber | Out-File "$out\os.txt"
Get-WindowsFeature Windows-Server-Backup | Out-File "$out\feature.txt"
Get-WBPolicy        | Format-List * | Out-File "$out\policy.txt"
Get-WBSummary       | Format-List * | Out-File "$out\summary.txt"
Get-WBJob -Previous 5 | Format-List * | Out-File "$out\jobs.txt"
Get-WBBackupSet     | Select-Object VersionId, BackupTime, BackupTarget | Out-File "$out\versions.txt"
vssadmin list writers       | Out-File "$out\vss-writers.txt"
vssadmin list providers     | Out-File "$out\vss-providers.txt"
vssadmin list shadowstorage | Out-File "$out\vss-storage.txt"
Get-WinEvent -LogName 'Microsoft-Windows-Backup' -MaxEvents 200 |
  Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\backup-log.csv" -NoTypeInformation
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='VSS'; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, Message | Export-Csv "$out\vss-app-events.csv" -NoTypeInformation
Get-ScheduledTask -TaskPath '\Microsoft\Windows\Backup\' | Get-ScheduledTaskInfo | Out-File "$out\task.txt"
Compress-Archive "$out\*" "$out.zip" -Force
"Evidence: $out.zip"
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| Install feature | `Install-WindowsFeature Windows-Server-Backup -IncludeManagementTools` |
| Status summary | `Get-WBSummary` |
| Last job detail | `Get-WBJob -Previous 1` |
| List versions | `wbadmin get versions [-backupTarget:E:]` |
| Contents of a version | `wbadmin get items -version:<ID>` |
| One-off BMR | `wbadmin start backup -backupTarget:E: -allCritical -systemState -vssFull -quiet` |
| System State only | `wbadmin start systemstatebackup -backupTarget:E: -quiet` |
| File restore | `wbadmin start recovery -version:<ID> -itemType:File -items:<path> -recoveryTarget:<alt>` |
| System State restore | `wbadmin start systemstaterecovery -version:<ID> -quiet` |
| Prune versions | `wbadmin delete backup -keepVersions:<N> -quiet` |
| Restore catalog | `wbadmin restore catalog -backupTarget:E:` |
| Critical volumes | `Get-WBVolume -CriticalVolumes` |
| VSS writers | `vssadmin list writers` |
| Shadow storage | `vssadmin list shadowstorage` |
| Health script | `.\Get-WindowsServerBackupHealth.ps1 -MaxAgeHours 26` |

---
## 🎓 Learning Pointers
- Treat WSB as "a VSS requestor that writes VHDX files". Once you model it that way, failures split cleanly into snapshot-phase (VSS) vs transfer-phase (target) problems. [Volume Shadow Copy Service](https://learn.microsoft.com/windows-server/storage/file-server/volume-shadow-copy-service)
- The critical-volume set is computed, not configured — a single agent installed on D: can make your BMR 10x bigger. [wbadmin start backup `-allCritical`](https://learn.microsoft.com/windows-server/administration/windows-commands/wbadmin-start-backup)
- Network-share targets keep one version: good for "offsite copy", bad as the only backup. Pair with a dedicated disk. [WindowsServerBackup module](https://learn.microsoft.com/powershell/module/windowsserverbackup/)
- BMR restores depend on WinRE having the right storage driver and firmware mode matching the source. Practise on a VM. [wbadmin commands index](https://learn.microsoft.com/windows-server/administration/windows-commands/wbadmin)
- For DCs, System State age vs tombstone lifetime decides whether the backup is even usable — `AD-BackupRestore-A.md`. VSS writer internals: `VSS-A.md`. Slow System State enumeration: `ComponentStore-B.md`.
