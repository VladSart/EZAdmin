# Windows Server Backup (wbadmin) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Run elevated on the affected server (Windows Server 2016–2025).

```powershell
# 1. Is the feature installed and is there a schedule?
Get-WindowsFeature Windows-Server-Backup | Select-Object Name, InstallState
Get-WBPolicy -ErrorAction SilentlyContinue | Select-Object Schedule, BMR, SystemState

# 2. Last run vs last success
Get-WBSummary | Select-Object LastSuccessfulBackupTime, LastBackupTime, LastBackupResultHR, NextBackupTime, NumberOfVersions

# 3. Recent failures in the Backup operational log
Get-WinEvent -LogName 'Microsoft-Windows-Backup' -MaxEvents 30 |
  Where-Object { $_.Level -le 3 } | Select-Object TimeCreated, Id, Message | Format-List

# 4. VSS writers (the #1 hidden cause)
vssadmin list writers | Select-String 'Writer name|State|Last error'

# 5. Target reachable + free space
Get-WBBackupTarget -Policy (Get-WBPolicy) | Select-Object Label, TargetType, TargetPath, FreeSpace, TotalSpace
```

| Result | Meaning | Go to |
|---|---|---|
| `InstallState` = Available | Feature not installed — `wbadmin` unavailable | Install feature (Fix 1) |
| `Get-WBPolicy` returns nothing | No scheduled backup exists — only ad-hoc runs ever happened | Fix 1 |
| `LastBackupTime` recent but `LastSuccessfulBackupTime` old | Job runs and fails | Read `LastBackupResultHR` + events 5, 517, 521, 546 |
| `LastBackupResultHR` = `0x80042306` / `0x8004230F` / events 517/521 mention VSS | Shadow copy provider / writer failure | Fix 2 |
| Writer state `[8] Failed` or `Last error: Timed out` | That application's VSS writer broken | Fix 2 |
| Event 4 success but 'versions' missing / `NumberOfVersions` low | Target full; oldest versions auto-deleted or shadow storage too small | Fix 3 |
| `0x80070005`, `0x80070035` on network target | Share permissions / creds / SMB path | Fix 4 |
| `0x80780119` "not enough disk space to create the volume shadow copy" | Shadow storage on a **source** volume too small or volume nearly full | Fix 3 (source-side block) |
| `0x807800C5` "failure in preparing the backup image" | Target VHDX can't be created/mounted — target offline, re-used disk, NAS rejecting large sparse files, sector-size mismatch | Fix 3 / Fix 5 |
| `NextBackupTime` blank | Schedule task disabled | Fix 6 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Successful Windows Server Backup job
└── Task Scheduler: \Microsoft\Windows\Backup\Microsoft-Windows-WindowsBackup (enabled, runs as SYSTEM)
    └── wbengine service (Block Level Backup Engine) — Manual, starts on demand
        ├── VSS service (Volume Shadow Copy) — Manual, starts on demand
        │   ├── swprv (Microsoft Software Shadow Copy provider)
        │   ├── Shadow storage on each source volume (vssadmin list shadowstorage)
        │   └── Every VSS writer in Stable / No error
        │       (System Writer, Registry, COM+ REGDB, WMI, NTDS, DFSR, Hyper-V, SQL, Exchange...)
        ├── Source volumes: NTFS/ReFS, online, not BitLocker-locked
        │   └── EFI System Partition + Recovery partition readable (for BMR)
        └── Backup target
            ├── Dedicated disk: formatted by WSB, hidden, no drive letter, GPT, ≥ 1.5x used data
            ├── Volume: shares I/O with the host volume, VSS snapshots can't be kept there long-term
            └── Network share: SMB reachable, account has Full Control on share + NTFS
                └── Only ONE version kept (each run overwrites) — no history on network targets
```
</details>

---
## Diagnosis & Validation Flow
1. **Confirm the last result code**
   ```powershell
   $s = Get-WBSummary; '{0:X}' -f $s.LastBackupResultHR
   ```
   Expected: `0`. Anything else → search the hex in the events (step 2).
2. **Read the failing job's event chain**
   ```powershell
   Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Backup'; StartTime=(Get-Date).AddDays(-3)} |
     Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap
   ```
   Good: `1` (started) → `14` (completed) → `4` (success). Bad: `5` (failed), `517`/`521` (system-state / volume backup failed). Read the error text — the HRESULT is in the message.
3. **Check VSS writers after a failure (not before — a clean reboot hides the state)**
   ```powershell
   vssadmin list writers
   ```
   Good: all `State: [1] Stable`, `Last error: No error`. Bad: `[8] Failed`, `Retryable error`, `Timed out`.
4. **Check shadow storage on every source volume**
   ```powershell
   vssadmin list shadowstorage
   ```
   Bad: "No items found" on a source volume, or Maximum Shadow Copy Storage < ~10% of volume.
5. **Check the catalog knows the versions**
   ```powershell
   wbadmin get versions
   ```
   Bad: "There is no backup" while backups ran → catalog corrupt (Fix 7).
6. **Validate after fixing** — run a one-off to the same target:
   ```powershell
   wbadmin start backup -backupTarget:<E:|\\server\share> -include:C: -allCritical -systemState -vssFull -quiet
   ```
   Expected: "The backup operation successfully completed." then event ID 4.

---
## Common Fix Paths

<details><summary>Fix 1 — Feature missing or no schedule configured</summary>

```powershell
Install-WindowsFeature Windows-Server-Backup -IncludeManagementTools

# Minimal BMR + system state schedule to a dedicated disk (WIPES the target disk)
$pol  = New-WBPolicy
Add-WBBareMetalRecovery -Policy $pol
Add-WBSystemState       -Policy $pol
Add-WBVolume            -Policy $pol -Volume (Get-WBVolume -CriticalVolumes)
$disk = Get-WBDisk | Where-Object { $_.DiskNumber -eq <DiskNumber> }
$tgt  = New-WBBackupTarget -Disk $disk -Label "WSB-$env:COMPUTERNAME"
Add-WBBackupTarget -Policy $pol -Target $tgt
Set-WBSchedule     -Policy $pol -Schedule 21:00
Set-WBVssBackupOption -Policy $pol -VssFullBackup   # use VssCopyBackup if another product owns log truncation
Set-WBPolicy -Policy $pol -Force
```
**Destructive:** adding a dedicated disk formats it. Confirm `Get-WBDisk` number twice. Rollback: none — the disk's previous contents are gone.
</details>

<details><summary>Fix 2 — VSS writer / provider failure (0x80042306, 0x8004230F, 517, 521)</summary>

```powershell
# Identify failed writer
vssadmin list writers | Select-String -Context 0,4 'Failed|error: (?!No error)'

# Restart the service that owns the writer (map below), then re-check
$map = @{
  'System Writer'='CryptSvc'; 'WMI Writer'='Winmgmt'; 'Registry Writer'='VSS'
  'COM+ REGDB Writer'='VSS'; 'NTDS'='NTDS'; 'DFS Replication service writer'='DFSR'
  'Microsoft Hyper-V VSS Writer'='vmms'; 'SqlServerWriter'='SQLWriter'; 'IIS Config Writer'='AppHostSvc'
}
Restart-Service -Name <ServiceFromMap> -Force
vssadmin list writers
```
- **System Writer failed** almost always = permission on `%windir%\WinSxS\` or a service binary path with stale ACLs → check `Application` log for VSS event 8193/8230 naming the file.
- **Third-party provider** in `vssadmin list providers` (old backup agent, SAN provider) → the provider is chosen before `swprv`; uninstall the orphaned agent.
- Still failing after restart → reboot (clears writer state), then run the validation backup in step 6 before the scheduled window.
</details>

<details><summary>Fix 3 — Target full / versions disappearing / 0x807800C5</summary>

```powershell
Get-WBBackupTarget -Policy (Get-WBPolicy) | Format-List Label, FreeSpace, TotalSpace
vssadmin list shadowstorage /for=<TargetVolume>:
```
- WSB on a **dedicated disk** keeps versions as VSS snapshots of the target; when it's full, the oldest are deleted automatically. This is by design — size the disk at 1.5–2.5x the protected data.
- To delete old versions manually (not system state only):
  ```powershell
  wbadmin delete backup -keepVersions:<N> -backupTarget:<E:> -quiet
  ```
- System-state-only pruning: `wbadmin delete systemstatebackup -keepVersions:<N> -quiet`
- **Source-side `0x80780119`:** grow shadow storage on the source volume (needs free space on it):
  ```powershell
  vssadmin resize shadowstorage /for=<C:> /on=<C:> /maxsize=15%
  ```
- Target disk was re-used / reformatted outside WSB → remove and re-add the target in the policy (Fix 1 target block) — **wipes it**.
</details>

<details><summary>Fix 4 — Network share target failing (0x80070005, 0x80070035, event 49/50)</summary>

```powershell
Test-NetConnection <FileServer> -Port 445
# Test with the exact credential the policy uses
$c = Get-Credential <DOMAIN\svc-backup>
New-PSDrive -Name T -PSProvider FileSystem -Root \\<FileServer>\<Share> -Credential $c
New-Item T:\wsb-test.txt -ItemType File; Remove-Item T:\wsb-test.txt; Remove-PSDrive T

# Re-set the network target with credentials
$pol = Get-WBPolicy -Editable
$pol | Get-WBBackupTarget | ForEach-Object { Remove-WBBackupTarget -Policy $pol -Target $_ }
Add-WBBackupTarget -Policy $pol -Target (New-WBBackupTarget -NetworkPath \\<FileServer>\<Share> -Credential $c)
Set-WBPolicy -Policy $pol -Force
```
Remember: a share target holds **one** version — each run overwrites `WindowsImageBackup\<Server>`. If the client needs history, move to a dedicated disk or iSCSI LUN.
</details>

<details><summary>Fix 5 — Large volume / sector mismatch / NAS target (0x807800C5)</summary>

- Source volumes > 2 TB require **VHDX** (Server 2012+ writes VHDX; failures here usually mean a NAS share that rejects large sparse files, or a legacy target).
- Targets with 4K native sectors and sources with 512e can fail on older builds → use a different target disk or patch to current CU.
- Exclude non-critical giant data volumes from the BMR set and back them up as separate volume jobs:
  ```powershell
  $pol = Get-WBPolicy -Editable
  Remove-WBVolume -Policy $pol -Volume (Get-WBVolume -VolumePath <D:>)
  Set-WBPolicy -Policy $pol -Force
  ```
</details>

<details><summary>Fix 6 — Schedule not firing (NextBackupTime blank)</summary>

```powershell
Get-ScheduledTask -TaskPath '\Microsoft\Windows\Backup\' | Select-Object TaskName, State
Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Backup\' -TaskName 'Microsoft-Windows-WindowsBackup'
Get-ScheduledTaskInfo -TaskPath '\Microsoft\Windows\Backup\' -TaskName 'Microsoft-Windows-WindowsBackup' |
  Select-Object LastRunTime, LastTaskResult, NextRunTime
```
If the task is missing entirely, re-save the policy (`Set-WBPolicy -Policy (Get-WBPolicy -Editable) -Force`) — it recreates the task.
</details>

<details><summary>Fix 7 — Catalog corrupt ("no backup" but backups exist)</summary>

```powershell
# Catalog lives in %SystemRoot%\System32\WindowsImageBackup\Catalog — the target has its own copy
wbadmin restore catalog -backupTarget:<E:> -quiet
wbadmin get versions -backupTarget:<E:>
```
Only if the target catalog is also damaged: `wbadmin delete catalog -quiet` (**loses all version history in the local catalog** — the backups on disk are still usable by pointing at `-backupTarget`). Next scheduled run starts a fresh catalog.
</details>

---
## Escalation Evidence
```
Server / OS build:              ____________________
WSB policy (BMR/SysState/Vols): ____________________
Target type + path:             ____________________
LastSuccessfulBackupTime:       ____________________
LastBackupResultHR (hex):       ____________________
Failing event IDs + text:       ____________________
Failed VSS writer(s):           ____________________
vssadmin list providers (non-MS): __________________
Shadow storage on source vols:  ____________________
Target free / total:            ____________________
Fixes attempted + result:       ____________________
Script output attached:         Get-WindowsServerBackupHealth.ps1 CSV  [ ]
```

---
## 🎓 Learning Pointers
- WSB is a VSS *requestor* — nearly every "backup failed" is really a writer or provider failure. Read writer state **after** the failure, before any reboot. [VSS overview](https://learn.microsoft.com/windows-server/storage/file-server/volume-shadow-copy-service)
- Dedicated-disk targets keep history as shadow copies of the target; network shares keep exactly one version. That single fact explains most "where did my old backups go" tickets. [wbadmin start backup](https://learn.microsoft.com/windows-server/administration/windows-commands/wbadmin-start-backup)
- `-vssFull` truncates application logs (Exchange/SQL); `-vssCopy` doesn't. Two tools both doing full backups break each other's log chains. [Set-WBVssBackupOption](https://learn.microsoft.com/powershell/module/windowsserverbackup/set-wbvssbackupoption)
- A DC's System State from WSB is only valid for the tombstone lifetime — see `ActiveDirectory/Troubleshooting/BackupRestore/AD-BackupRestore-B.md`.
- Test restores, not just backups: `wbadmin get items -version:<ID>` proves the catalog can browse content. Deep dive: `WindowsServerBackup-A.md`; VSS internals: `VSS-B.md`.
