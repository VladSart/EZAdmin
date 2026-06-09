# Windows Event Log — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)

---
## Scope & Assumptions

**Covers:**
- Windows 10/11 and Windows Server 2016–2025 Event Log architecture
- EventLog service internals, log modes, ETW pipeline
- Log corruption diagnosis and recovery
- GPO-driven log configuration
- Security log protection and audit policies
- SIEM/forwarding integration points

**Does not cover:**
- Third-party log aggregation agent troubleshooting (Splunk, NXLog)
- Azure Monitor Agent (AMA) / Log Analytics Agent (MMA) deployment
- Windows Event Forwarding (WEF) subscriptions — see Exchange folder

**Assumed role:** L2/L3 MSP engineer with local admin or SYSTEM-level access.

---
## How It Works

<details><summary>Full architecture</summary>

### The ETW Pipeline

Windows Event Log is built on **Event Tracing for Windows (ETW)**, a kernel-level publish/subscribe system. Events flow through three layers:

```
Publisher (application / driver / OS component)
    │  writes via: ReportEvent(), EvtWriteEx(), TraceEvent()
    ▼
ETW Kernel Buffer (ring buffer, per-CPU, kernel mode)
    │  consumer: Event Log service reads from buffer
    ▼
Windows Event Log Service (svchost -k LocalServiceNetworkRestricted)
    │  processes: channel routing, persistence, ACL enforcement
    ▼
.evtx File (C:\Windows\System32\winevt\Logs\<LogName>.evtx)
    │  format: binary XML, self-describing, block-structured
    ▼
Consumer (Event Viewer, wevtutil, Get-WinEvent, WEF, SIEM agent)
```

### Log Channels

Windows distinguishes four channel types:

| Channel Type | Description | Examples |
|---|---|---|
| **Admin** | For end-user/admin action; always has a meaningful message | System, Application |
| **Operational** | Informational for tools; less human-readable | Microsoft-Windows-Bits-Client/Operational |
| **Analytic** | High-volume; disabled by default; not persisted unless enabled | ETW diagnostic channels |
| **Debug** | Developer traces; disabled by default | Internal component channels |

### .evtx File Format

Each `.evtx` file is a **binary XML database** with:
- **Header block** (4 KB): magic bytes `ElfFile\x00`, version, chunk count, oldest/newest record IDs
- **Chunk records** (65536 bytes each): event records stored in chunks
- **Event records**: individually checksummed; corruption in one record doesn't necessarily invalidate the whole file

When a chunk is corrupt, `wevtutil` or `Get-WinEvent` returns `ERROR_EVT_INVALID_EVENT_DATA`. The header checksum failing means the entire file is considered unreadable.

### Log Modes In Depth

```
Circular (default for most logs):
  - When full: oldest events overwritten
  - MaxSize controlled by registry/GPO
  - No data loss for new events

Retain:
  - When full: new events SILENTLY DROPPED
  - Log stays full indefinitely
  - Must be manually cleared or archived
  - Default for some audit logs if GPO sets retention

AutoBackup:
  - When full: log archived to .evtx file, then cleared
  - Archive path: same folder as active log
  - New events continue uninterrupted
  - Requires write permission on log folder

Snapshot (Server 2019+):
  - Read-only log; not user-configurable
```

### Security Log Special Behaviour

The Security log has additional protections:
- **Protected channel**: only LSASS can write to it
- **Audit policy** (auditpol) controls what gets written
- **CrashOnAuditFail** (HKLM\SYSTEM\CurrentControlSet\Control\Lsa\CrashOnAuditFail):
  - Value 1 = warn user when Security log full
  - Value 2 = BSOD on Security log full (extreme compliance hardening — rare but catastrophic if Retain mode is set and log fills)
- **Event ID 1102**: log cleared by administrator; always logged in the Security channel immediately after clearing

</details>

---
## Dependency Stack

```
─────────────────────────────────────────────────────
  Consumer Layer
  (Event Viewer, Get-WinEvent, wevtutil, WEF, SIEM)
─────────────────────────────────────────────────────
  Windows Event Log API (wevtapi.dll)
─────────────────────────────────────────────────────
  Windows Event Log Service (EventLog)
  svchost.exe -k LocalServiceNetworkRestricted
─────────────────────────────────────────────────────
  Service Dependencies:
    ├── WinMgmt (WMI) — for WMI-based event consumers
    ├── RpcEptMapper — for RPC event forwarding
    └── DcomLaunch — baseline COM/DCOM for service host
─────────────────────────────────────────────────────
  ETW Kernel Subsystem
  (ntoskrnl.exe — always running, not a service)
─────────────────────────────────────────────────────
  Storage Layer
  C:\Windows\System32\winevt\Logs\*.evtx
  (NTFS — requires SYSTEM + NETWORK SERVICE perms)
─────────────────────────────────────────────────────
  Registry Configuration
  HKLM\SYSTEM\CurrentControlSet\Services\EventLog\*
  (log size, retention, custom source registrations)
─────────────────────────────────────────────────────
  Group Policy / MDM (Intune CSP)
  EventLogService CSP, Audit CSPs
─────────────────────────────────────────────────────
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Event Viewer opens blank / shows nothing | EventLog service stopped | `Get-Service EventLog` |
| Events stop appearing after a date | Log full + Retain mode | `Get-WinEvent -ListLog * \| Where LogMode -eq 'Retain'` |
| Security events stop (no BSOD) | Security log full + CrashOnAuditFail=1 | `auditpol /get /category:*` + log size check |
| Machine BSODs randomly | CrashOnAuditFail=2 + Security log full | Check `HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\CrashOnAuditFail` |
| `wevtutil` errors "data is invalid" | .evtx file corruption (bad chunk) | `wevtutil el` to identify which log |
| EventLog service won't start | Dependent service down or binary corruption | `sc qc EventLog`, SFC scan |
| Logs missing from remote machine | WMI/RPC blocked by firewall | Test with `Test-NetConnection <target> -Port 135` |
| Event ID 104 in System log | Log file replaced/cleared (non-security log) | Review who cleared + timeframe |
| Event ID 1102 in Security log | Security audit log cleared | Incident response — was this authorised? |
| SIEM shows gap in events | Agent stall, service restart, or log full | Check EventLog service uptime + SIEM agent logs |
| Custom application log missing | App not registered source in registry | `Get-EventLog -List \| Where Log -eq <name>` |
| `Access denied` writing to log | Wrong permissions on .evtx folder | `icacls C:\Windows\System32\winevt\Logs` |

---
## Validation Steps

**Step 1 — Service health**
```powershell
Get-Service EventLog | Format-List Name, Status, StartType, DependentServices, ServicesDependedOn
```
Expected: `Status = Running`, all dependencies also Running.

**Step 2 — Log inventory and health**
```powershell
Get-WinEvent -ListLog * -ErrorAction SilentlyContinue |
  Where-Object IsEnabled |
  Select-Object LogName, LogMode, RecordCount, MaximumSizeInBytes,
    @{N="UsedPct";E={[math]::Round($_.RecordCount / ($_.MaximumSizeInBytes/512) * 100,1)}} |
  Sort-Object UsedPct -Descending | Select-Object -First 20
```
Expected: No log at 100% UsedPct unless AutoBackup mode.

**Step 3 — Write test**
```powershell
# Register source if it doesn't exist:
if (-not [System.Diagnostics.EventLog]::SourceExists("EZAdminTest")) {
    New-EventLog -LogName Application -Source "EZAdminTest"
}
Write-EventLog -LogName Application -Source "EZAdminTest" -EventId 9998 -EntryType Information -Message "Validation test $(Get-Date)"
Start-Sleep 2
Get-WinEvent -LogName Application -MaxEvents 5 | Where-Object Id -eq 9998
```
Expected: Event appears immediately.

**Step 4 — Registry config review**
```powershell
$logs = @("Application","System","Security")
foreach ($log in $logs) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\$log"
    [PSCustomObject]@{
        Log       = $log
        MaxSize   = (Get-ItemProperty $key -Name MaxSize -EA SilentlyContinue).MaxSize
        Retention = (Get-ItemProperty $key -Name Retention -EA SilentlyContinue).Retention
        File      = (Get-ItemProperty $key -Name File -EA SilentlyContinue).File
    }
}
```
Expected: `Retention = 0` (overwrite), `MaxSize` matching policy requirements.

**Step 5 — CrashOnAuditFail check**
```powershell
(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name CrashOnAuditFail -EA SilentlyContinue).CrashOnAuditFail
```
Expected: `0` or key absent. Value `2` = BSOD risk if Security log fills.

**Step 6 — Disk space**
```powershell
Get-Volume C | Select-Object DriveLetter, Size, SizeRemaining,
  @{N="FreePct";E={[math]::Round($_.SizeRemaining/$_.Size*100,1)}}
```
Expected: >5% free. Under 1 GB free = event log rotation will fail.

---
## Troubleshooting Steps (by phase)

### Phase 1: Service Won't Start

1. Check dependency chain — start from bottom up (DcomLaunch → RpcEptMapper → WinMgmt → EventLog)
2. Check Windows System event source for EventLog errors at last boot
3. Run `sfc /scannow` — corrupted `wevtsvc.dll` or `wevtapi.dll` prevents service start
4. Check for group policy disabling the service: `rsop.msc` → Computer Configuration → Windows Settings → System Services

### Phase 2: Events Dropping / Log Full

1. Identify which logs are in Retain mode (Step 2 above)
2. Check MaxSize vs. business requirement (Security logs often need 1 GB+)
3. Evaluate log mode change: Retain → Circular for non-audit logs; Retain → AutoBackup for audit logs
4. Check if GPO is enforcing Retain mode — if yes, must change at GPO level, not locally
5. For Security log specifically: check `auditpol` for excessive audit categories — "Process Tracking" generates enormous volume

### Phase 3: Log File Corruption

1. Identify the corrupt file using `wevtutil el` — the command fails or hangs at the corrupt log
2. Try `wevtutil qe <LogName> /f:text /c:1` — if this fails, file is corrupt
3. Archive intact events first: `wevtutil epl <LogName> "C:\Backup\<LogName>_$(Get-Date -f yyyyMMdd).evtx"`
4. Clear the log: `wevtutil cl <LogName>` — this recreates the .evtx file
5. If clear fails (locked): stop EventLog service, rename/delete the .evtx file, restart service — OS recreates it empty
6. Post-recovery: run DISM + SFC to address underlying disk/OS corruption

### Phase 4: Security Log Investigation

1. Search for Event ID 1102 (Security cleared) or 104 (Application/System cleared)
2. These events include the user account that performed the clear
3. If unauthorised: treat as security incident — preserve other evidence before it rotates
4. If authorised but unexpected: review GPO or script triggering automated clears

---
## Remediation Playbooks

<details><summary>Playbook 1 — Resize and remode all standard logs to sane defaults</summary>

```powershell
# Set Application, System to 50 MB Circular
$standardLogs = @("Application","System","Setup")
foreach ($log in $standardLogs) {
    wevtutil sl $log /ms:52428800 /rt:false  # 50 MB, circular
    Write-Host "Configured $log" -ForegroundColor Green
}

# Set Security log to 200 MB AutoBackup (archive before clear)
wevtutil sl Security /ms:209715200 /rt:true /ab:true

# Verify:
Get-WinEvent -ListLog Application, System, Security |
  Select-Object LogName, LogMode, MaximumSizeInBytes
```

**Rollback:** Save current config first:
```powershell
Get-WinEvent -ListLog * | Where-Object IsEnabled |
  Select-Object LogName, LogMode, MaximumSizeInBytes |
  Export-Csv "C:\Temp\EventLogConfig_backup.csv" -NoTypeInformation
```
</details>

<details><summary>Playbook 2 — Full corrupt log recovery (non-destructive attempt first)</summary>

```powershell
# Step 1: Identify corrupt log
$corruptLog = $null
Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        Get-WinEvent -LogName $_.LogName -MaxEvents 1 -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Possibly corrupt: $($_.LogName) — $($_.Exception.Message)"
        $corruptLog = $_.LogName
    }
}

# Step 2: Attempt export (may partially succeed):
if ($corruptLog) {
    $backupPath = "C:\Temp\${corruptLog}_corrupt_backup_$(Get-Date -f yyyyMMdd_HHmm).evtx"
    try {
        wevtutil epl $corruptLog $backupPath
        Write-Host "Partial backup saved: $backupPath"
    } catch {
        Write-Warning "Export failed — file too corrupt for partial save"
    }

    # Step 3: Clear (recreates file)
    wevtutil cl $corruptLog
    Write-Host "Log cleared and recreated: $corruptLog"
}
```

**Rollback:** Not applicable — clearing is irreversible. Partial `.evtx` backup may be loadable in Event Viewer manually.
</details>

<details><summary>Playbook 3 — CrashOnAuditFail remediation</summary>

```powershell
# Check current value:
$val = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name CrashOnAuditFail -EA SilentlyContinue).CrashOnAuditFail
Write-Host "CrashOnAuditFail = $val"

# If value is 2 (BSOD on full Security log), change to 1 (warn only) or 0 (disabled):
# !! Only do this if you understand the security implications !!
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name CrashOnAuditFail -Value 0

# Immediately after, grow Security log to prevent it filling:
wevtutil sl Security /ms:524288000 /rt:true /ab:true  # 500 MB AutoBackup

# Verify:
(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa").CrashOnAuditFail
```

**Rollback:**
```powershell
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name CrashOnAuditFail -Value 2
```
⚠️ Only restore if the Security log has been sized appropriately and AutoBackup is configured — otherwise you risk BSOD again.
</details>

<details><summary>Playbook 4 — Register a missing custom event source</summary>

```powershell
# Check if source exists:
[System.Diagnostics.EventLog]::SourceExists("<YourAppName>")

# If false — register it:
New-EventLog -LogName Application -Source "<YourAppName>"

# Verify:
Get-EventLog -List | Where-Object Log -eq "Application"

# Registry location of registered sources:
Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application" |
  Select-Object -ExpandProperty PSChildName
```

**Rollback:** Remove the source registration:
```powershell
Remove-EventLog -Source "<YourAppName>"
```
</details>

---
## Evidence Pack

Run this script on the affected machine and attach output to your escalation ticket:

```powershell
<#
.SYNOPSIS  Collect Windows Event Log diagnostic evidence
.NOTES     Run as Administrator
#>

$outDir = "C:\Temp\EventLogEvidence_$(Get-Date -f yyyyMMdd_HHmm)"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# Service status
Get-Service EventLog, WinMgmt, RpcEptMapper, DcomLaunch |
  Select-Object Name, Status, StartType |
  Export-Csv "$outDir\services.csv" -NoTypeInformation

# Log inventory
Get-WinEvent -ListLog * -ErrorAction SilentlyContinue |
  Where-Object IsEnabled |
  Select-Object LogName, LogMode, RecordCount, MaximumSizeInBytes, LogFilePath |
  Export-Csv "$outDir\log_inventory.csv" -NoTypeInformation

# Registry config for main logs
$logs = @("Application","System","Security")
$regData = foreach ($log in $logs) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\$log"
    [PSCustomObject]@{
        Log       = $log
        MaxSize   = (Get-ItemProperty $key -Name MaxSize -EA SilentlyContinue).MaxSize
        Retention = (Get-ItemProperty $key -Name Retention -EA SilentlyContinue).Retention
        File      = (Get-ItemProperty $key -Name File -EA SilentlyContinue).File
    }
}
$regData | Export-Csv "$outDir\registry_config.csv" -NoTypeInformation

# CrashOnAuditFail
$cafVal = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name CrashOnAuditFail -EA SilentlyContinue).CrashOnAuditFail
"CrashOnAuditFail = $cafVal" | Out-File "$outDir\lsa_settings.txt"

# Recent EventLog service events
Get-WinEvent -LogName System -MaxEvents 500 -ErrorAction SilentlyContinue |
  Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Eventlog' } |
  Select-Object TimeCreated, Id, LevelDisplayName, Message |
  Export-Csv "$outDir\eventlog_service_events.csv" -NoTypeInformation

# Recent clears (1102, 104)
Get-WinEvent -LogName Security, System -MaxEvents 1000 -ErrorAction SilentlyContinue |
  Where-Object { $_.Id -in @(1102, 104) } |
  Select-Object TimeCreated, Id, LogName, Message |
  Export-Csv "$outDir\log_clear_events.csv" -NoTypeInformation

# Disk space
Get-Volume | Select-Object DriveLetter, FileSystemLabel, Size, SizeRemaining |
  Export-Csv "$outDir\disk_space.csv" -NoTypeInformation

# wevtutil log list output
wevtutil el 2>&1 | Out-File "$outDir\wevtutil_el.txt"

# System info
$sys = Get-ComputerInfo | Select-Object CsName, OsName, OsVersion, OsBuildNumber, OsLastBootUpTime
$sys | Out-File "$outDir\sysinfo.txt"

Write-Host "Evidence collected: $outDir" -ForegroundColor Green
Compress-Archive -Path $outDir -DestinationPath "$outDir.zip" -Force
Write-Host "Archive: $outDir.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# List all enabled logs with size info
Get-WinEvent -ListLog * | Where-Object IsEnabled | Select-Object LogName, LogMode, RecordCount, MaximumSizeInBytes

# Query recent events from a specific log
Get-WinEvent -LogName System -MaxEvents 50

# Query by event ID
Get-WinEvent -FilterHashtable @{LogName='System'; Id=7001} -MaxEvents 20

# Query by time range
Get-WinEvent -FilterHashtable @{LogName='Security'; StartTime=(Get-Date).AddHours(-2)}

# Export a log to .evtx file
wevtutil epl Application "C:\Backup\Application.evtx"

# Clear a log
wevtutil cl Application

# Get log configuration
wevtutil gl System

# Set log size and mode (50 MB, circular)
wevtutil sl Application /ms:52428800 /rt:false

# List all registered event sources for a log
Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application" | Select-Object PSChildName

# Check audit policy
auditpol /get /category:*

# Enable/disable an analytic log
wevtutil sl "Microsoft-Windows-TaskScheduler/Operational" /e:true
wevtutil sl "Microsoft-Windows-TaskScheduler/Operational" /e:false

# Get EventLog service dependencies
Get-Service EventLog | Select-Object -ExpandProperty ServicesDependedOn

# Write a test event
Write-EventLog -LogName Application -Source "EZAdminTest" -EventId 9999 -EntryType Information -Message "Test"

# Search for events across all logs (slow but thorough)
Get-WinEvent -ListLog * | Where-Object RecordCount | ForEach-Object {
    Get-WinEvent -LogName $_.LogName -MaxEvents 5 -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -eq 7001 }
}
```

---
## 🎓 Learning Pointers

- **ETW is kernel-level and always on** — even if the EventLog service is stopped, ETW buffers continue accumulating in kernel memory. Events are not lost immediately on service stop, but will be lost when the buffer fills. Starting the service again drains the buffer. [MS Docs: ETW Architecture](https://learn.microsoft.com/en-us/windows/win32/etw/about-event-tracing)
- **The Security log is the most important from a compliance/forensic standpoint** — always size it generously (200 MB+), use AutoBackup mode, and never use Retain without CrashOnAuditFail=0 unless you've architected for it. [MS Docs: Security Auditing](https://learn.microsoft.com/en-us/windows/security/threat-protection/auditing/security-auditing-overview)
- **Event ID 1102 vs 104**: 1102 appears in the Security log when the Security log is cleared; 104 appears in the System log when any other log is cleared. Both record the user account responsible — these are your forensic breadcrumbs.
- **CrashOnAuditFail=2 is a deliberate BSOD failsafe** for high-security environments (think: PCI-DSS, government). The intent is to prevent the system from continuing to operate if audit evidence cannot be preserved. If you find this set to 2, do not change it without understanding the compliance context first.
- **Analytic and Debug log channels** produce enormous event volume — enabling them on production systems fills disks rapidly. Use them for targeted short-duration diagnostics only, then disable. [MS Docs: Analytic and Debug Channels](https://learn.microsoft.com/en-us/windows/win32/wes/defining-channels)
- **Windows Event Forwarding (WEF)** is the built-in solution for centralised log collection without a third-party agent — worth knowing for air-gapped or Defender-only environments. Source-initiated subscriptions scale well for MSP use. [MS Docs: Windows Event Forwarding](https://learn.microsoft.com/en-us/windows/security/threat-protection/use-windows-event-forwarding-to-assist-in-intrusion-detection)
