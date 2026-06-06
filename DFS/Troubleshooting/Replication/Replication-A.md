# DFS Replication — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- DFS Replication (DFSR) between Windows Server 2012 R2 and later
- Replication group members in AD domains (not standalone/workgroup)
- Sysvol replication migrated to DFSR (not FRS)
- Pull-based replication topologies (hub-and-spoke and full mesh)

**Out of scope:**
- FRS (File Replication Service) — legacy, decommission it
- Azure File Sync (different service entirely)
- DFS Namespaces without replication

**Assumes:**
- Domain admin or equivalent rights
- PowerShell 5.1+ with RSAT DFS Management Tools installed
- Event log access to DFSR source (Event ID range 1000–9000 in `DFS Replication` log)

---

## How It Works

<details><summary>Full architecture — DFSR internals</summary>

### Core Engine

DFSR uses the **Remote Differential Compression (RDC)** algorithm to transfer only changed blocks of files, not whole files. It also uses the **USN (Update Sequence Number) Journal** on each NTFS volume to track file changes without scanning the entire share.

### Replication Pipeline

```
[File Change on Member A]
       │
       ▼
USN Journal entry created on Member A
       │
       ▼
DFSR service reads USN journal (polls every ~3 sec by default)
       │
       ▼
Changed file staged in ConflictAndDeleted or Staging area
       │  (Staging area: %SystemDrive%\System Volume Information\DFSR\Staging)
       ▼
RPC connection to replication partner (Member B)
       │  Port: 135 (RPC endpoint mapper) + dynamic high ports (49152–65535)
       ▼
Version vector exchange — partners compare what each has
       │
       ▼
RDC signature exchange — only diffs computed and transferred
       │
       ▼
File installed to destination path on Member B
       │
       ▼
USN Journal updated on Member B (change attributed to DFSR, not replicated again)
```

### Replication Groups vs. Replicated Folders

- A **Replication Group** is the container — it defines membership and topology.
- A **Replicated Folder** is the actual path being synced. One group can have multiple replicated folders.
- **Primary Member**: On initial sync, the primary member's content wins. Critical: designate correctly or you'll replicate empty folders over real data.

### Staging Area

DFSR stages outbound files in a **Staging** folder before sending them. Default max size is 4 GB. If staging fills up, replication stalls with Event ID 2213. This folder is **not** the same as the replicated folder path.

### ConflictAndDeleted Folder

When two members modify the same file simultaneously (a "conflict"), DFSR keeps one version in the replicated folder and moves the loser to `DfsrPrivate\ConflictAndDeleted`. Default max size is 660 MB. When full, oldest entries are purged. Not user-accessible by default.

### Bandwidth Throttling

DFSR can be throttled per-schedule using RDC profile settings. By default, it uses all available bandwidth. Configured via `dfsrdiag` or DFSRM console. Limits are per-connection, not global.

### Sysvol Replication (Special Case)

Domain controllers replicate SYSVOL via DFSR after the SYSVOL migration wizard completes. The replication group is `Domain System Volume` and the replicated folder is `SYSVOL Share`. If this breaks, Group Policy and logon scripts fail across the domain.

</details>

---

## Dependency Stack

```
┌─────────────────────────────────────┐
│       Application / Users           │  ← Access files via DFS Namespace or UNC
├─────────────────────────────────────┤
│        DFS Namespace (optional)     │  ← \\domain\share → target resolution
├─────────────────────────────────────┤
│        DFSR Service (dfsr.exe)      │  ← Replication engine, runs as SYSTEM
├─────────────────────────────────────┤
│        RPC / WMI                    │  ← Port 135 + dynamic (49152–65535)
├─────────────────────────────────────┤
│        Active Directory             │  ← Stores replication topology in CN=DFSR-GlobalSettings
├─────────────────────────────────────┤
│        DNS                          │  ← Member discovery and RPC resolution
├─────────────────────────────────────┤
│        NTFS + USN Journal           │  ← Change tracking on replicated volumes
├─────────────────────────────────────┤
│        Network / Firewall           │  ← TCP 135, dynamic RPC, SMB 445
└─────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Files not replicating, no errors | AD replication lag — topology not propagated | `repadmin /showrepl`, check DFSR topology in AD Sites & Services |
| Event ID 2213 — staging area full | Staging quota too low or a huge file being staged | `dfsrdiag ReplicationState`, check staging path size |
| Event ID 4012 — DFSR stopped replicating | Replication partner is in "error" state, USN rollback suspected | Check Event ID 4012 body for member name, run `dfsrdiag PollAD` |
| Event ID 5002 — error communicating with partner | RPC blocked, DFSR service stopped on remote, or DNS failure | Test-NetConnection to partner on port 135, check DFSR service |
| Event ID 1202/1206 — access denied staging | DFSR service account can't write to staging folder | Check NTFS permissions on DfsrPrivate folder |
| Replication backlog > 10,000 | High change rate, low bandwidth, or one-directional connection issue | `dfsrdiag backlog` per connection, check bandwidth throttle schedule |
| ConflictAndDeleted folder growing fast | Users editing same files from multiple locations simultaneously | Check which members are designated as writable, consider redirecting access to single member |
| SYSVOL not replicating | DFSR stopped or SYSVOL migration stuck in state 2 or 3 | `dfsrmig /getglobalstate`, check `netlogon` service, Event ID 4614 |
| Initial sync never completes | Primary member not set, staging area too small, or a locked file blocking staging | Check Event ID 4114 (initial sync) and staging area quota |
| `dfsrdiag` returns WMI errors | WMI corruption on member or DFSR WMI provider not registered | `winmgmt /verifyrepository`, re-register DFSR WMI |

---

## Validation Steps

**1. Confirm DFSR service is running on all members**
```powershell
$members = "SERVER1","SERVER2","SERVER3"
foreach ($s in $members) {
    $svc = Get-Service -ComputerName $s -Name DFSR -ErrorAction SilentlyContinue
    [PSCustomObject]@{Server=$s; Status=$svc.Status; StartType=$svc.StartType}
}
```
Expected: `Running` / `Automatic`. If `Stopped` → service failure, check Event ID 1202.

**2. Check replication backlog on all connections**
```powershell
$RG = "<ReplicationGroupName>"
$members = "SERVER1","SERVER2"
foreach ($src in $members) {
    foreach ($dst in $members) {
        if ($src -ne $dst) {
            dfsrdiag Backlog /RgName:"$RG" /RfName:"<ReplicatedFolderName>" /SendingMember:$src /ReceivingMember:$dst
        }
    }
}
```
Expected: `No backlog` or a small number. `> 1000` warrants investigation. `> 50000` is a crisis.

**3. Check for active replication errors**
```powershell
Get-WinEvent -ComputerName <member> -LogName "DFS Replication" -MaxEvents 100 |
    Where-Object { $_.LevelDisplayName -in 'Error','Warning' } |
    Select-Object TimeCreated, Id, Message |
    Format-List
```
Bad: Event IDs 2213, 4012, 5002, 1202. Good: Only informational 4104, 4112.

**4. Verify AD replication topology is current**
```powershell
repadmin /showrepl * /csv | Out-File C:\Temp\repl-health.csv
# Then check for any FAIL entries:
Import-Csv C:\Temp\repl-health.csv | Where-Object {$_."Number of Failures" -gt 0}
```
Expected: No failures. Any failures mean DFSR topology changes may not have propagated.

**5. Confirm staging area size is adequate**
```powershell
# Run on each member
$path = "C:\System Volume Information\DFSR\Staging"  # adjust drive if needed
$items = Get-ChildItem $path -Recurse -ErrorAction SilentlyContinue
$sizeMB = ($items | Measure-Object Length -Sum).Sum / 1MB
Write-Host "Staging size: $([math]::Round($sizeMB,2)) MB"
# Also check configured quota:
Get-DfsrMembership -GroupName "<ReplicationGroupName>" -ComputerName <member> | Select-Object ComputerName, StagingPathQuotaInMB
```
Expected: Staging usage < 80% of quota. Quota should be at least 10x the size of the largest file being replicated.

**6. Poll AD for topology refresh**
```powershell
dfsrdiag PollAD /Member:<memberFQDN>
```
Expected: Success. Forces DFSR to re-read topology from AD — useful after making configuration changes.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Is replication occurring at all?

1. Check DFSR service status on all members (Step 1 above)
2. Create a test file on the primary/source member and time how long until it appears on target
3. If test file never arrives: go to Phase 2
4. If test file arrives slowly: go to Phase 3 (backlog/bandwidth)

### Phase 2 — Connectivity and Service Health

1. Confirm network connectivity: `Test-NetConnection -ComputerName <partner> -Port 135`
2. Check for firewall blocking dynamic RPC: `netsh advfirewall firewall show rule name="DFS Replication"` — should have inbound allow rules
3. Check DFSR event log on both members for errors (Step 3 above)
4. If Event ID 4012 present: the member has been in error state. Check body — it will name the offending partner and suggest action (usually `dfsrdiag ReplicationState /Member:<name>`)
5. Force AD topology refresh: `dfsrdiag PollAD /Member:<memberFQDN>` on all members

### Phase 3 — Backlog and Performance

1. Measure backlog size: Step 2 above
2. Check bandwidth schedule in DFSRM console: `dfsmgmt.msc` → Replication Groups → right-click group → Properties → Connection
3. Check for a file stuck in staging: Event ID 2213 indicates staging full; increase staging quota
4. Check if large files are causing the backlog: `dfsrdiag Backlog` will show individual file names if count is low
5. If backlog is growing faster than it's clearing, identify the root cause (high change rate, insufficient bandwidth, or a single huge file)

### Phase 4 — Conflict and Data Integrity

1. Check ConflictAndDeleted folder size: `Get-ChildItem "\\<member>\<share>\DfsrPrivate\ConflictAndDeleted" | Measure-Object Length -Sum`
2. Identify what's in there: files are renamed with a GUID suffix; original name is in their NTFS alternate data stream
3. For SYSVOL specifically: `dfsrmig /getglobalstate` — should be in "Eliminated" (state 4). If in state 2 or 3, the migration isn't complete — follow: https://docs.microsoft.com/en-us/troubleshoot/windows-server/group-policy/sysvol-dfsr-migration

---

## Remediation Playbooks

<details><summary>Playbook 1 — Restart DFSR and force re-poll</summary>

Use when: Replication has stalled and no obvious error, or after config changes.

```powershell
$member = "<ServerName>"

# Restart DFSR service
Invoke-Command -ComputerName $member -ScriptBlock {
    Restart-Service DFSR -Force
    Start-Sleep -Seconds 10
    Get-Service DFSR | Select-Object Status
}

# Force AD poll
dfsrdiag PollAD /Member:$member

# Verify replication state
dfsrdiag ReplicationState /Member:$member
```

**Rollback:** N/A — restarting DFSR is non-destructive. Replication will resume from last checkpoint (USN journal position is preserved).

</details>

<details><summary>Playbook 2 — Increase staging area quota</summary>

Use when: Event ID 2213 — staging full; or backlog growing due to large files.

```powershell
$GroupName  = "<ReplicationGroupName>"
$MemberName = "<ServerName>"
$NewQuotaMB = 10240  # 10 GB — adjust to 2x your largest expected file

# Check current quota
Get-DfsrMembership -GroupName $GroupName -ComputerName $MemberName |
    Select-Object ComputerName, StagingPathQuotaInMB

# Set new quota
Set-DfsrMembership -GroupName $GroupName -FolderName "<ReplicatedFolderName>" `
    -ComputerName $MemberName -StagingPathQuotaInMB $NewQuotaMB -Force

# Poll AD to apply
dfsrdiag PollAD /Member:$MemberName
```

**Rollback:** Set `StagingPathQuotaInMB` back to previous value (default is 4096).

</details>

<details><summary>Playbook 3 — Perform a non-authoritative restore of a replication member</summary>

Use when: A member's data is corrupt or severely out of sync and you want to re-sync it from a healthy partner. **Destructive — the member's current content will be replaced.**

```powershell
# Step 1: Stop DFSR on the affected member
$badMember = "<BadServerName>"
Invoke-Command -ComputerName $badMember -ScriptBlock { Stop-Service DFSR }

# Step 2: Rename the existing NTFRS or DFSR database to force re-initialization
# DFSR database location: <ReplicatedFolder>\DfsrPrivate\
Invoke-Command -ComputerName $badMember -ScriptBlock {
    $dbPath = "<ReplicatedFolderPath>\DfsrPrivate"
    Rename-Item "$dbPath\Sc*.frx"  "Sc.frx.bak"   -ErrorAction SilentlyContinue
    Rename-Item "$dbPath\Df*.frx"  "Df.frx.bak"   -ErrorAction SilentlyContinue
    # More complete: just rename the whole DfsrPrivate folder
    # Rename-Item $dbPath "DfsrPrivate.bak"
}

# Step 3: Set the member to non-authoritative restore mode via registry
Invoke-Command -ComputerName $badMember -ScriptBlock {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\DFSR\Parameters\Replication Groups\<GUID>\Replica Set Configuration File"
    # The GUID is the Replication Group GUID from DFSRM console
    # Easier: use dfsrdiag to force non-auth sync
    dfsrdiag InitialSync /RgName:"<ReplicationGroupName>" /RfName:"<FolderName>" /Member:$env:COMPUTERNAME
}

# Step 4: Start DFSR
Invoke-Command -ComputerName $badMember -ScriptBlock { Start-Service DFSR }

# Step 5: Poll AD and wait for initial sync event (Event ID 4114 → 4104)
dfsrdiag PollAD /Member:$badMember
```

**Rollback:** Before starting, take a VSS snapshot or backup of the member's replicated folder. Once non-auth sync completes, the local copy is overwritten by partner data.

> **Reference:** https://docs.microsoft.com/en-us/troubleshoot/windows-server/networking/dfsr-non-authoritative-sync

</details>

<details><summary>Playbook 4 — Authoritative restore (make one member the source of truth)</summary>

Use when: All members are out of sync and you need to designate one as authoritative.

```powershell
# Step 1: Stop DFSR on ALL members except the authoritative one
$nonAuthMembers = "SERVER2","SERVER3"
foreach ($m in $nonAuthMembers) {
    Invoke-Command -ComputerName $m -ScriptBlock { Stop-Service DFSR }
}

# Step 2: On the authoritative member, set the "Authoritative" attribute via AD
# Using DFSRM console: right-click Membership → set Primary Member = Yes
# Or via PowerShell (AD attribute msDFSR-options = 1):
$authMember = "SERVER1"
$groupDN = (Get-DfsReplicationGroup -GroupName "<ReplicationGroupName>").DistinguishedName
# This is advanced - recommend using dfsmgmt.msc → member properties → "Primary Member"

# Step 3: Start DFSR on non-auth members
foreach ($m in $nonAuthMembers) {
    Invoke-Command -ComputerName $m -ScriptBlock { Start-Service DFSR }
    dfsrdiag PollAD /Member:$m
}

# Step 4: Monitor Event ID 4114 (initial sync started) → 4104 (initial sync complete)
```

**Rollback:** No rollback once sync completes — back up non-authoritative members before starting.

</details>

<details><summary>Playbook 5 — Fix WMI provider errors blocking dfsrdiag</summary>

Use when: `dfsrdiag` returns WMI errors, or PowerShell DFSR cmdlets fail.

```powershell
# Run on the affected member
# Step 1: Verify WMI repo
winmgmt /verifyrepository

# Step 2: If corrupt, rebuild (non-destructive in most cases)
# winmgmt /resetrepository   ← Only if /verifyrepository fails

# Step 3: Re-register DFSR WMI provider
$dfsrDll = "$env:SystemRoot\System32\dfsrwmi.dll"
if (Test-Path $dfsrDll) {
    $result = & regsvr32 /s $dfsrDll
    Write-Host "Re-registered DFSR WMI provider"
}

# Step 4: Restart WMI
Restart-Service winmgmt -Force

# Step 5: Test
Get-DfsReplicationGroup -ErrorAction Stop | Select-Object GroupName, State
```

</details>

---

## Evidence Pack

Run this on any affected member to collect a complete evidence bundle for escalation:

```powershell
<#
.SYNOPSIS  Collect DFSR evidence for escalation
#>
param(
    [Parameter(Mandatory)]
    [string[]]$Members,
    [Parameter(Mandatory)]
    [string]$ReplicationGroupName,
    [string]$OutputPath = "C:\Temp\DFSR-Evidence"
)

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$ts = Get-Date -Format "yyyyMMdd-HHmmss"

foreach ($m in $Members) {
    $outDir = Join-Path $OutputPath $m
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    # DFSR service status
    Get-Service -ComputerName $m -Name DFSR |
        Export-Csv "$outDir\dfsr-service-$ts.csv" -NoTypeInformation

    # Replication state
    dfsrdiag ReplicationState /Member:$m | Out-File "$outDir\replication-state-$ts.txt"

    # Backlog (all connections)
    dfsrdiag Backlog /RgName:$ReplicationGroupName /Member:$m |
        Out-File "$outDir\backlog-$ts.txt"

    # Event log — last 200 DFSR events (errors and warnings)
    Get-WinEvent -ComputerName $m -LogName "DFS Replication" -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { $_.LevelDisplayName -in 'Error','Warning','Information' } |
        Export-Csv "$outDir\dfsr-events-$ts.csv" -NoTypeInformation

    # Membership config
    Get-DfsrMembership -GroupName $ReplicationGroupName -ComputerName $m -ErrorAction SilentlyContinue |
        Export-Csv "$outDir\membership-$ts.csv" -NoTypeInformation

    # Staging area usage
    $stagePath = "\\$m\C$\System Volume Information\DFSR\Staging"
    $stageSize = (Get-ChildItem $stagePath -Recurse -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum / 1MB
    "$m staging size: $([math]::Round($stageSize,2)) MB" |
        Out-File "$outDir\staging-size-$ts.txt"
}

Write-Host "Evidence collected to: $OutputPath"
Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath-$ts.zip"
Write-Host "Zipped: $OutputPath-$ts.zip"
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check DFSR service on remote | `Get-Service -ComputerName <srv> -Name DFSR` |
| Get replication group state | `dfsrdiag ReplicationState /Member:<srv>` |
| Check backlog for a connection | `dfsrdiag Backlog /RgName:<group> /RfName:<folder> /SendingMember:<src> /ReceivingMember:<dst>` |
| Force AD topology refresh | `dfsrdiag PollAD /Member:<srv>` |
| List all replication groups | `Get-DfsReplicationGroup` |
| Get membership details | `Get-DfsrMembership -GroupName <group>` |
| Get connection details | `Get-DfsrConnection -GroupName <group>` |
| Set staging quota | `Set-DfsrMembership -GroupName <group> -FolderName <folder> -ComputerName <srv> -StagingPathQuotaInMB <n>` |
| Get last AD replication status | `repadmin /showrepl` |
| Check SYSVOL migration state | `dfsrmig /getglobalstate` |
| View DFSR debug log | `Get-WinEvent -LogName "DFS Replication" -MaxEvents 100` |
| Restart DFSR on remote | `Invoke-Command -ComputerName <srv> -ScriptBlock { Restart-Service DFSR }` |
| Check staging folder path | `Get-DfsrMembership -GroupName <group> | Select-Object ComputerName,StagingPath` |
| Test RPC connectivity | `Test-NetConnection -ComputerName <partner> -Port 135` |

---

## 🎓 Learning Pointers

- **USN journal wrap causes non-authoritative sync to trigger.** If a volume's USN journal wraps (can happen when the journal is too small relative to change rate), DFSR detects this as a potential database inconsistency and stops replicating. Event ID 4012. Fix: set a larger USN journal using `fsutil usn createjournal m=<size> a=<alloc> <drive>:`. See: https://docs.microsoft.com/en-us/troubleshoot/windows-server/networking/dfsr-event-4012-stopping-replication

- **SYSVOL migration has four states: 0=Start, 1=Prepared, 2=Redirected, 3=Eliminated.** If you promoted a DC and it stays in state 2, Group Policy may be partially broken — GPOs are readable but edits go to the wrong location. Run `dfsrmig /getglobalstate` to check and `dfsrmig /setglobalstate 3` to advance once all DCs are at state 2. Reference: https://docs.microsoft.com/en-us/windows-server/storage/dfs-replication/migrate-sysvol-to-dfsr

- **The staging area must be larger than your largest file, with headroom.** Microsoft recommends the staging quota be at least as large as the 32 largest files in the replicated folder. A common mistake is leaving it at the 4 GB default while replicating a 6 GB database backup. Reference: https://docs.microsoft.com/en-us/windows-server/storage/dfs-replication/dfsr-faq

- **Backlog ≠ broken.** A non-zero backlog is normal during active replication. Concern starts when backlog is growing over time, not when it's present at a point in time. Use the `Get-DFSRBacklog.ps1` script to track trends over a 10-minute window rather than spot-checking once.

- **ConflictAndDeleted is not a trash bin.** Files there are the loser in a write-write conflict. Review them before they're auto-purged — a user's work may be in there. The default size is 660 MB; when full, oldest entries are deleted permanently. Increase with `Set-DfsrMembership -ConflictAndDeletedQuotaInMB`.

- **DFS Replication is not a backup.** A ransomware encryption event on one member will replicate to all members. Use VSS (Volume Shadow Copies) or Azure Backup alongside DFSR. Reference: https://docs.microsoft.com/en-us/windows-server/storage/dfs-replication/dfsr-overview
