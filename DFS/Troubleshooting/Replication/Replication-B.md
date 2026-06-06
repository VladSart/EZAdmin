# DFS Replication — Hotfix Runbook (Mode B: Ops)

> Fix or escalate in under 10 minutes. Covers DFSR backlog, stuck replication, and SYSVOL.

---

## Skim Index
- [Triage (60 sec)](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis Flow](#diagnosis--validation-flow)
- [Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

```powershell
# 1. Check DFSR service on affected members
Get-Service DFSR -ComputerName <member1>, <member2>

# 2. Current backlog size (files waiting to replicate)
# Replace replication group + connection names as needed
Get-DfsrBacklog -GroupName "<ReplicationGroupName>" `
  -FolderName "<FolderName>" `
  -SourceComputerName <source> `
  -DestinationComputerName <destination> |
  Measure-Object | Select Count

# 3. Check for DFSR errors in last 2 hours
Get-WinEvent -LogName "DFS Replication" -MaxEvents 50 |
  Where-Object { $_.LevelDisplayName -in "Error","Warning" } |
  Select TimeCreated, Id, Message | Format-Table -Wrap

# 4. Is replication completely stopped or just delayed?
# Look for Event ID 4004 (replication stopped) vs 4016 (initialising)
Get-WinEvent -LogName "DFS Replication" -MaxEvents 20 |
  Where-Object { $_.Id -in 4004, 4008, 4012, 5002, 5004 } |
  Select TimeCreated, Id, Message

# 5. SYSVOL specifically — are GPOs applying?
dcdiag /test:sysvolcheck
dcdiag /test:netlogons
```

**Interpret:**
- DFSR service stopped → start it, see [Fix 1](#fix-1--dfsr-service-not-running)
- Backlog > 0 but growing → replication running but overwhelmed
- Backlog stuck at same number for hours → replication stalled, see [Fix 2](#fix-2--replication-stalled--stuck)
- Event 4004 → replication explicitly stopped (quota exceeded or admin action)
- Event 5002/5004 → connectivity or authentication issue to partner
- dcdiag SYSVOL fails → SYSVOL not shared or DFSR not initialised

---

## Dependency Cascade

<details><summary>What must be true for DFSR to work</summary>

```
[DFSR Service running on all members]
    → TCP 5722 open between all members (RPC for DFSR)
    → TCP 135 + dynamic RPC open (RPC endpoint mapper)
    → Kerberos auth between members (DC reachable, time sync OK)
    → Members in same replication group + connection objects in AD
    → AD replication healthy (DFSR config lives in AD)
    → Disk space available (staging + destination)
    → Staging quota not exceeded (default 4 GB — often too small)
```

**SYSVOL specifically:**
```
DFSR SYSVOL → only active when SYSVOL is authoritative on one DC
            → PDC emulator holds the authoritative copy
            → All other DCs replicate FROM PDC (star topology initially, then mesh)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Service state on all members**
```powershell
$members = "<dc1>","<dc2>","<member1>"  # Adjust to your env
$members | ForEach-Object {
    [PSCustomObject]@{
        Server = $_
        Status = (Get-Service DFSR -ComputerName $_).Status
    }
} | Format-Table
```

**Step 2 — Replication group health report**
```powershell
# Generate HTML diagnostic report (opens in browser)
# Run in DFS Management MMC: Replication → right-click group → Create Diagnostic Report
# Or via PowerShell:
$report = "C:\DFSRReport-$(Get-Date -Format yyyyMMdd).html"
dfsrdiag ReplicationState /member:<member1> > C:\dfsr-state.txt
```

**Step 3 — Backlog per connection**
```powershell
Get-DfsrConnection -GroupName "<group>" | ForEach-Object {
    $conn = $_
    try {
        $backlog = Get-DfsrBacklog -GroupName "<group>" `
          -FolderName "<folder>" `
          -SourceComputerName $conn.SourceComputerName `
          -DestinationComputerName $conn.DestinationComputerName `
          -ErrorAction Stop | Measure-Object
        [PSCustomObject]@{
            Source = $conn.SourceComputerName
            Destination = $conn.DestinationComputerName
            BacklogCount = $backlog.Count
        }
    } catch {
        [PSCustomObject]@{
            Source = $conn.SourceComputerName
            Destination = $conn.DestinationComputerName
            BacklogCount = "ERROR: $($_.Exception.Message)"
        }
    }
} | Format-Table
```

**Step 4 — Check staging quota**
```powershell
# Default is 4 GB — often the silent killer for large files
Get-DfsrMembership -GroupName "<group>" -ComputerName <member> |
  Select ComputerName, FolderName, StagingPathQuotaInMB, ConflictAndDeletedQuotaInMB
```

**Step 5 — SYSVOL state on DCs**
```powershell
# Check SYSVOL sharing status — must be SHARED, not SYSVOL_NOT_YET_INITIALIZED
net share | Where-Object { $_ -match "SYSVOL|NETLOGON" }

# Check SYSVOL via DFSR state
dfsrdiag StaticRPC /member:<dcname>

# Authoritative state
(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\DFSR\Parameters\SysVols\Migrating Sysvols\Domain System Volume").msDFSR-Flags
# Value 0 = PDC authoritative; Value 4 = non-PDC synced
```

---

## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — DFSR Service not running</summary>

```powershell
Start-Service DFSR -ComputerName <member>
Set-Service DFSR -StartupType Automatic -ComputerName <member>

# Watch event log for 30 seconds
Start-Sleep 30
Get-WinEvent -ComputerName <member> -LogName "DFS Replication" -MaxEvents 10 |
  Select TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap
```

Look for Event 4602 (DFSR initialised) as confirmation.

</details>

<details id="fix-2"><summary>Fix 2 — Replication stalled / stuck</summary>

```powershell
# Step 1: Force a replication poll on the destination member
Invoke-CimMethod -Namespace root\MicrosoftDFS `
  -ClassName DfsrConfig -MethodName PollDsNow `
  -CimSession <destinationMember>

# Step 2: If that doesn't clear it, restart DFSR service
Restart-Service DFSR -ComputerName <member>

# Step 3: Check bandwidth throttling schedule — may be set to "No bandwidth"
Get-DfsrConnection -GroupName "<group>" | Select * | Format-List
```

</details>

<details><summary>Fix 3 — Staging quota exceeded</summary>

**Symptom:** Event ID 4202 (staging space low), replication slows/stops for large files

```powershell
# Increase staging quota (example: 16 GB)
# Find the membership first
$membership = Get-DfsrMembership -GroupName "<group>" -ComputerName <member>

Set-DfsrMembership -GroupName "<group>" `
  -FolderName "<folder>" `
  -ComputerName <member> `
  -StagingPathQuotaInMB 16384  # 16 GB

# Force update
Update-DfsrConfigurationFromAD -ComputerName <member>
```

> ⚠️ Staging folder lives on the same volume as the replicated folder by default. Ensure disk has space.

</details>

<details><summary>Fix 4 — SYSVOL not replicating (non-authoritative restore)</summary>

> ⚠️ Use this only if SYSVOL is genuinely empty/corrupt on a non-PDC DC. This triggers full re-sync from PDC. Confirm with your lead before running.

```powershell
# On the non-authoritative DC (the broken one — NOT the PDC)
# Stop DFSR
Stop-Service DFSR

# Set the non-authoritative flag
$keyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\DFSR\Parameters\SysVols\Migrating Sysvols\Domain System Volume"
Set-ItemProperty -Path $keyPath -Name "msDFSR-Flags" -Value 0

# Start DFSR — it will perform a non-authoritative sync from PDC
Start-Service DFSR

# Monitor — wait for Event 4614 (non-auth sync started) then 4604 (SYSVOL initialised)
Get-WinEvent -LogName "DFS Replication" -MaxEvents 20 |
  Where-Object { $_.Id -in 4602, 4604, 4614 } |
  Select TimeCreated, Id, Message
```

</details>

<details><summary>Fix 5 — Conflict files accumulating</summary>

**Symptom:** `DfsrPrivate\ConflictAndDeleted` folder growing; users seeing `_CONFLICT` files

```powershell
# Check conflict folder size
$conflictPath = "\\<member>\<replFolderPath>\DfsrPrivate\ConflictAndDeleted"
(Get-ChildItem $conflictPath -Recurse -ErrorAction SilentlyContinue |
  Measure-Object -Property Length -Sum).Sum / 1GB

# Conflicts happen when two members modify the same file before replication catches up
# Resolution: last-writer wins — older version goes to ConflictAndDeleted

# Increase conflict quota if needed (default 660 MB)
Set-DfsrMembership -GroupName "<group>" -FolderName "<folder>" `
  -ComputerName <member> -ConflictAndDeletedQuotaInMB 4096
```

Root fix: identify which users/apps modify same files from multiple sites simultaneously. Application-level locking or read-only replicas for remote sites are architectural solutions.

</details>

---

## Escalation Evidence

```
DFSR Issue — Evidence Pack
====================================
Replication Group:       
Affected folders:        
Affected members:        
Backlog count:           [run Get-DfsrBacklog]
DFSR service state:      [Running / Stopped on each member]
Replication started when: 
Last successful sync:    
Key event IDs:           [4004 / 4202 / 5002 / 5004 / other]
SYSVOL affected:         [Yes/No]
Disk space on members:   [GB free on replicated volume]
Staging quota:           [current MB vs files being replicated]
Network between sites:   [bandwidth, latency]
AD replication health:   [repadmin /replsummary output]
```

---

## 🎓 Learning Pointers

- **Staging quota is the most common silent killer** — the default 4 GB was set when files were smaller. Any environment with large files (VMs, ISOs, big Office docs) hits this constantly. Know the formula: staging quota should be 1.5× the size of the largest 32 files in the replicated folder. [MS Docs: Staging Quota](https://learn.microsoft.com/en-us/windows-server/storage/dfs-replication/preseed-dfsr-with-robocopy)
- **DFSR uses RDC (Remote Differential Compression)** — it doesn't replicate entire files on change; it replicates only the changed blocks. Knowing this explains why large-file replication is efficient but why small-frequent-changes (like databases) are still a bad fit for DFSR.
- **SYSVOL and DFSR migration from FRS** — if you're in an older domain, SYSVOL may still be on FRS (File Replication Service). FRS is deprecated. Check migration state with `dfsrmig /getglobalstate`. This matters because FRS and DFSR have completely different troubleshooting paths.
- **Conflict resolution model** — DFSR is last-writer-wins per file, at block level. Conflicts go to `DfsrPrivate\ConflictAndDeleted`. Understanding this helps you set expectations with users about what happens in multi-site write scenarios.
- **r/sysadmin gold**: Search "DFSR backlog not draining" — bandwidth throttling schedules accidentally set to "No bandwidth" during business hours is a classic gotcha that trips up experienced engineers.
