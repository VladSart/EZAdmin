# Windows Event Log — Hotfix Runbook (Mode B: Ops)
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

Run these first — interpret results before doing anything else.

```powershell
# 1. Is the Event Log service running?
Get-Service -Name EventLog | Select-Object Name, Status, StartType

# 2. Which logs have errors or are full?
Get-WinEvent -ListLog * -ErrorAction SilentlyContinue |
  Where-Object { $_.IsEnabled -and ($_.RecordCount -eq $_.MaximumSizeInBytes/512 -or $_.LogMode -eq 'Retain') } |
  Select-Object LogName, LogMode, RecordCount, MaximumSizeInBytes |
  Sort-Object RecordCount -Descending | Select-Object -First 15

# 3. Any Event Log corruption events?
Get-WinEvent -LogName System -MaxEvents 200 -ErrorAction SilentlyContinue |
  Where-Object { $_.Id -in @(6, 104, 1102) -and $_.ProviderName -eq 'Microsoft-Windows-Eventlog' } |
  Select-Object TimeCreated, Id, Message | Format-List

# 4. Check log file paths and sizes
Get-WinEvent -ListLog Application, System, Security -ErrorAction SilentlyContinue |
  Select-Object LogName, LogFilePath, MaximumSizeInBytes, RecordCount

# 5. Windows Event Log service dependencies
sc.exe qc EventLog
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| EventLog service `Stopped` | Core service failure | → Fix 1 |
| Log shows `LogMode: Retain` and full | Logs not auto-overwriting | → Fix 2 |
| Event ID 6 in System log | Log file corrupted | → Fix 3 |
| Event ID 104 / 1102 in Security | Log was manually cleared | Audit/escalate |
| `LogFilePath` shows non-default path | GPO redirect; check permissions | → Fix 4 |
| `wevtutil el` hangs / fails | Service or API broken | → Fix 5 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Windows Event Log Service (EventLog)
  └── Depends on: Windows Management Instrumentation (winmgmt)
       └── Depends on: RPC Endpoint Mapper (RpcEptMapper)
            └── Depends on: DCOM Server Process Launcher (DcomLaunch)

Log Files (default: C:\Windows\System32\winevt\Logs\)
  └── Requires: SYSTEM + NETWORK SERVICE write permissions
  └── Requires: Sufficient disk space
  └── Log size limits enforced by registry:
       HKLM\SYSTEM\CurrentControlSet\Services\EventLog\<LogName>\MaxSize
       HKLM\SYSTEM\CurrentControlSet\Services\EventLog\<LogName>\Retention

ETW (Event Tracing for Windows)
  └── Feeds: Analytic and Debug log channels
  └── Requires: tracelog / autologger configuration intact

Security log
  └── Controlled by: Local Security Policy → Audit Policy
  └── GPO: Computer Configuration → Windows Settings → Security Settings → Local Policies → Audit Policy
```
</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the EventLog service state**
```powershell
Get-Service EventLog | Format-List *
```
- Expected: `Status = Running`, `StartType = Automatic`
- Bad: `Stopped` or `Disabled` → proceed to Fix 1

**Step 2 — Test writing a synthetic event**
```powershell
Write-EventLog -LogName Application -Source "MSPTest" -EventId 9999 -EntryType Information -Message "EZAdmin test event"
# Then verify it landed:
Get-EventLog -LogName Application -Newest 5 | Where-Object EventID -eq 9999
```
- Expected: Event appears within 2 seconds
- Bad: `Exception calling Write-EventLog` → service issue or permissions

**Step 3 — Check disk space on the OS volume**
```powershell
Get-PSDrive C | Select-Object Used, Free
```
- Expected: `Free` > 1 GB (event logs need headroom to rotate)
- Bad: Under 500 MB → logs cannot grow, new events dropped silently

**Step 4 — Check for corrupted log files**
```powershell
wevtutil el 2>&1 | Select-Object -Last 5
# Any output like "The data is invalid" = corruption
```

**Step 5 — Verify Security log retention policy**
```powershell
(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Security").Retention
```
- Expected: `0` (overwrite as needed)
- Bad: `4294967295` (−1 / never overwrite) + log full → events lost

---
## Common Fix Paths

<details><summary>Fix 1 — EventLog service stopped or disabled</summary>

```powershell
# Start the service
Start-Service -Name EventLog

# If it fails to start, check dependencies first:
Get-Service WinMgmt, RpcEptMapper, DcomLaunch | Select-Object Name, Status

# If dependencies are stopped:
Start-Service DcomLaunch, RpcEptMapper, WinMgmt -ErrorAction SilentlyContinue
Start-Service EventLog

# Reset start type if disabled:
Set-Service -Name EventLog -StartupType Automatic

# Verify:
Get-Service EventLog
```

**Rollback:** Service start has no rollback risk. If it fails to start after above, escalate — registry or binary damage suspected.
</details>

<details><summary>Fix 2 — Log full due to Retain mode (no auto-overwrite)</summary>

```powershell
# Check current mode for all logs:
Get-WinEvent -ListLog * | Where-Object LogMode -eq 'Retain' |
  Select-Object LogName, LogMode, MaximumSizeInBytes, RecordCount

# Change a specific log to AutoBackup (archive then clear) or Circular (overwrite):
wevtutil sl "System" /rt:false /ms:20971520
# /rt:false = overwrite old events (circular)
# /ms = MaxSize in bytes (20 MB above)

# Or via PowerShell for all Retain-mode logs:
Get-WinEvent -ListLog * | Where-Object { $_.IsEnabled -and $_.LogMode -eq 'Retain' } | ForEach-Object {
    $_.LogMode = [System.Diagnostics.Eventing.Reader.EventLogMode]::Circular
    $_.SaveChanges()
}
```

**Rollback:** Re-enable Retain mode if compliance requires it:
```powershell
wevtutil sl "Security" /rt:true
```
</details>

<details><summary>Fix 3 — Corrupted log file (.evtx)</summary>

```powershell
# Identify which log is corrupt — look for errors:
wevtutil el 2>&1

# For a non-critical log (e.g. Application), clear and recreate:
wevtutil cl Application

# For System log corruption — must do offline. Stop service first won't work.
# Use DISM to check OS file health:
DISM /Online /Cleanup-Image /CheckHealth
DISM /Online /Cleanup-Image /RestoreHealth

# Then SFC:
sfc /scannow

# If Security log is corrupt (cannot clear while protected):
# Must use auditpol to disable auditing, then clear:
auditpol /clear /y
wevtutil cl Security
```

**Rollback:** Clearing a log is irreversible for the existing events. Archive before clearing if audit trail matters:
```powershell
wevtutil epl Application "C:\Temp\Application_backup_$(Get-Date -Format yyyyMMdd).evtx"
wevtutil cl Application
```
</details>

<details><summary>Fix 4 — Log file permissions issue (custom GPO path)</summary>

```powershell
# Check the redirected path:
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog"
Get-ChildItem $regPath | ForEach-Object {
    $file = (Get-ItemProperty $_.PSPath -Name File -ErrorAction SilentlyContinue).File
    if ($file) { [PSCustomObject]@{ Log=$_.PSChildName; File=$file } }
}

# Check ACL on the log folder:
$logPath = "C:\Windows\System32\winevt\Logs"  # adjust if redirected
icacls $logPath

# Fix: ensure SYSTEM and NETWORK SERVICE have full control:
icacls $logPath /grant "SYSTEM:(OI)(CI)F" /grant "NETWORK SERVICE:(OI)(CI)F"

# Restart EventLog service:
Restart-Service EventLog
```

**Rollback:** Save existing ACL before changing:
```powershell
icacls $logPath /save "C:\Temp\evtlogs_acl_backup.txt"
# Restore: icacls $logPath /restore "C:\Temp\evtlogs_acl_backup.txt"
```
</details>

<details><summary>Fix 5 — wevtutil or Get-WinEvent hangs / fails entirely</summary>

```powershell
# Likely corrupt EVTX files or service deadlock. Try restarting:
Stop-Service EventLog -Force
Start-Sleep 5
Start-Service EventLog

# If service hangs on stop:
$svc = Get-WmiObject Win32_Service -Filter "Name='EventLog'"
$svc.StopService()
Start-Sleep 10
Start-Service EventLog

# Nuclear: rename corrupt log files (forces recreation on next start)
# !! Do this only if service cannot start at all !!
Stop-Service EventLog -Force
$corrupt = "C:\Windows\System32\winevt\Logs\Application.evtx"
Rename-Item $corrupt "$corrupt.bak"
Start-Service EventLog
```

**Rollback:** Rename `.bak` back to `.evtx` while service is stopped.
</details>

---
## Escalation Evidence

Copy-paste this block, fill in the blanks, attach to your ticket:

```
=== ESCALATION: Windows Event Log Issue ===
Date/Time:          ________________
Hostname:           ________________
OS Version:         ________________ (winver output)
Affected Log(s):    ________________ (Application / System / Security / Other)
Symptom:            ________________ (events missing / service stopped / corruption / log full)

EventLog Service Status:
  [paste output of: Get-Service EventLog | Format-List *]

Log Status:
  [paste output of: Get-WinEvent -ListLog Application, System, Security | Select LogName, LogMode, RecordCount, MaximumSizeInBytes]

Recent EventLog service errors:
  [paste output of: Get-WinEvent -LogName System | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Eventlog' } | Select -First 10 | Format-List]

Disk free space (C:):
  [paste: Get-PSDrive C | Select Used, Free]

wevtutil el output (last 10 lines):
  [paste]

Fix attempts made:
  ________________

Impact:
  ________________ (auditing broken / application errors not captured / etc.)
```

---
## 🎓 Learning Pointers

- **Event ID 1102** in the Security log means the log was deliberately cleared — always a suspicious event worth investigating in an MSP context. Track via Sentinel or Log Analytics if available. [MS Docs: Audit Log Cleared](https://learn.microsoft.com/en-us/windows/security/threat-protection/auditing/event-1102)
- **Circular vs. Retain vs. AutoBackup**: Retain = stop accepting new events when full; AutoBackup = archive then clear; Circular = overwrite oldest. For security logs in regulated environments, use AutoBackup to a secure share. [MS Docs: Log Modes](https://learn.microsoft.com/en-us/windows/win32/wes/eventmanifestschema-channeltype-complextype)
- **ETW analytic/debug logs** are disabled by default and cannot be cleared while enabled — disable them first (`wevtutil sl <log> /e:false`) before clearing. Forgetting this is a common gotcha.
- **GPO can redirect log paths** via `Computer Configuration → Administrative Templates → Windows Components → Event Log Service → [LogName] → Log file path`. If you see events going missing on domain-joined machines, check this GPO first.
- **SIEM agents (Sentinel, Splunk, etc.) stall** when the Event Log service is stopped or logs are full — always check log health when SIEM gaps are reported.
