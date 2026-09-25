# Task Scheduler (Scheduled Tasks) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers tasks that don't run, run but do nothing, `0x1`, `0x41301`/`0x41303`/`0x41306`, `0x800710E0`, `0x8007052E`, "Run whether user is logged on or not" failures, and GPO/Intune-deployed tasks.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Elevated PowerShell. Replace `<TaskName>` / `<\Path\>` (root is `\`).

```powershell
# 1. Service + history
Get-Service Schedule | Select-Object Status, StartType
Get-WinEvent -ListLog Microsoft-Windows-TaskScheduler/Operational | Select-Object IsEnabled, RecordCount

# 2. Task state + last result
$t = Get-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>'
$t | Select-Object TaskName, State, @{n='RunAs';e={$_.Principal.UserId}}, @{n='LogonType';e={$_.Principal.LogonType}}, @{n='RunLevel';e={$_.Principal.RunLevel}}
$t | Get-ScheduledTaskInfo | Select-Object LastRunTime, @{n='LastResultHex';e={'0x{0:X}' -f $_.LastTaskResult}}, NextRunTime, NumberOfMissedRuns

# 3. Action exactly as the task sees it
$t.Actions | Select-Object Execute, Arguments, WorkingDirectory

# 4. Recent task events (last 24h)
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TaskScheduler/Operational'; StartTime=(Get-Date).AddDays(-1)} -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -match [regex]::Escape('<TaskName>') } | Select-Object -First 15 TimeCreated, Id, Message
```

| Result | Meaning | Go to |
|---|---|---|
| History log `IsEnabled: False` | No run history — you're blind | Fix 1 (enable), then reproduce |
| `State: Disabled` | Task disabled (by admin, GPO, or a failed deploy) | `Enable-ScheduledTask` |
| `NextRunTime` empty | No active trigger (expired, end date passed, trigger disabled) | Fix 5 |
| `0x0` but "nothing happened" | Process ran and exited 0 — script logic, working dir, mapped drives, or wrong context | Fix 3 |
| `0x1` | Program returned 1 — usually PowerShell/cmd error: bad path, execution policy, quoting | Fix 2 |
| `0x2` / `0x80070002` | File not found — `Execute` path wrong or relative | Fix 2 |
| `0x41301` | Currently running (or hung from last run) | Fix 4 |
| `0x41303` | Has not yet run | Check trigger / NextRunTime |
| `0x41306` | Terminated by user or by "Stop task if runs longer than" | Fix 4 |
| `0x800710E0` | Operator/admin refused the request — conditions (AC power, idle, network) or "Run only when logged on" with nobody logged on | Fix 5 |
| `0x8007052E` / Event 101 "logon failure" | Stored password wrong/expired for "Run whether user is logged on or not" | Fix 6 |
| `0x80070005` / Event 104 | Account lacks **Log on as a batch job** or access to files | Fix 6 |
| `0x8004131F` | An instance is already running and multiple-instances policy = IgnoreNew | Fix 4 |
| Event 322 "launch request ignored, instance already running" | Same | Fix 4 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Task action produces the intended result
└── Action process starts in correct context
    ├── Execute path absolute & reachable by the RunAs account (no mapped drives, UNC needs share+NTFS rights)
    ├── WorkingDirectory set (scripts using relative paths)
    └── Interpreter args correct (powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<path>")
        └── Principal can log on
            ├── SYSTEM / LOCAL SERVICE / NETWORK SERVICE → no password (SYSTEM = computer account on network)
            ├── gMSA → LogonType Password, KDS/AD reachable, host in PrincipalsAllowedToRetrieveManagedPassword
            ├── Domain user "Run whether logged on or not" → stored credential valid + "Log on as a batch job" right
            └── "Run only when user is logged on" → interactive session exists
                └── Conditions satisfied (AC power, idle, network available) & Settings allow start
                    └── Trigger fires (schedule, at startup, at logon, on event) & not expired
                        └── Task enabled, definition not corrupt (C:\Windows\System32\Tasks\<path> + TaskCache registry)
                            └── Task Scheduler service (Schedule) running
```
</details>

---
## Diagnosis & Validation Flow
1. **Run it on demand and watch**
   ```powershell
   Start-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>'
   Start-Sleep 10
   Get-ScheduledTaskInfo -TaskPath '<\Path\>' -TaskName '<TaskName>' | Select-Object LastRunTime, @{n='Hex';e={'0x{0:X}' -f $_.LastTaskResult}}
   ```
   Good: `0x0` and the expected side-effect. If manual works but scheduled doesn't → trigger/conditions (Fix 5).
2. **Read the event sequence** (Operational log)
   - 106 registered → 100 started → 200 action started → 129 process created (PID) → 201 action completed (with return code) → 102 finished.
   - 101 = failed to start (reason in message). 103 = action failed to start. 322/324 = instance policy.
   ```powershell
   Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TaskScheduler/Operational'; Id=101,103,201,322,329} -MaxEvents 20 |
     Select-Object TimeCreated, Id, Message
   ```
3. **Reproduce as the task's principal**
   - SYSTEM: `psexec -s -i powershell.exe` (Sysinternals) and run the exact action line.
   - Service account: `runas /user:<DOMAIN\svc> "powershell.exe -NoProfile"`.
   Expected: same failure appears interactively with a readable error.
4. **Wrap scripts with a transcript** so exit 0/1 becomes explainable:
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Transcript C:\Temp\<TaskName>.log; & '<C:\Scripts\script.ps1>'; exit $LASTEXITCODE"`

---
## Common Fix Paths

<details><summary>Fix 1 — Enable task history</summary>

```powershell
wevtutil set-log Microsoft-Windows-TaskScheduler/Operational /enabled:true
```
Rollback: `/enabled:false`. History is off by default on many builds; enabling it is safe (log is size-capped).
</details>

<details><summary>Fix 2 — 0x1 / 0x2: fix the action line</summary>

```powershell
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
  -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<C:\Scripts\script.ps1>"' `
  -WorkingDirectory '<C:\Scripts>'
Set-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>' -Action $action
```
Rules: absolute paths; quote paths with spaces inside `-Argument`; don't put arguments in `Execute`; `-File` not `-Command` for scripts; for `pwsh.exe` use its full path (`C:\Program Files\PowerShell\7\pwsh.exe`). `.bat`/`.cmd` → `Execute cmd.exe`, `Argument /c "<path>"`.
</details>

<details><summary>Fix 3 — Runs (0x0) but does nothing</summary>

Common causes and fixes:
- **Mapped drive letters** don't exist in a batch/SYSTEM logon → use UNC paths.
- **SYSTEM on the network** authenticates as `DOMAIN\COMPUTER$` → grant the computer object share/NTFS rights, or use a gMSA.
- **Relative paths** resolve to `C:\Windows\System32` → set `WorkingDirectory` or use `$PSScriptRoot`.
- **HKCU / user profile** operations under SYSTEM hit the SYSTEM profile, not the user's.
- **UI/interactive** actions (message boxes, `Start-Process` of GUI apps) never show in a non-interactive session — expected behaviour.
- **Script swallows errors** → add transcript (step 4 above) and `exit 1` on failure so `LastTaskResult` means something.
</details>

<details><summary>Fix 4 — Stuck / overlapping instances (0x41301, 0x8004131F, 0x41306)</summary>

```powershell
Get-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>' | Select-Object State
Stop-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>'
# Kill orphaned child if the action process survives (identify via Event 129 PID)
# Stop-Process -Id <PID> -Force
$s = (Get-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>').Settings
$s.ExecutionTimeLimit = 'PT2H'          # ISO 8601; 'PT0S' = no limit (default is 72h)
$s.MultipleInstances  = 'IgnoreNew'     # Parallel | Queue | IgnoreNew | StopExisting
Set-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>' -Settings $s
```
0x41306 after exactly 72h = default time limit hit — the script hung, fix the script.
</details>

<details><summary>Fix 5 — Trigger never fires / 0x800710E0 conditions</summary>

```powershell
$t = Get-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>'
$t.Triggers | Select-Object Enabled, StartBoundary, EndBoundary, @{n='Type';e={$_.CimClass.CimClassName}}
$t.Settings | Select-Object DisallowStartIfOnBatteries, StopIfGoingOnBatteries, RunOnlyIfIdle, RunOnlyIfNetworkAvailable, StartWhenAvailable, WakeToRun
# Typical server/laptop-safe settings:
$set = $t.Settings
$set.DisallowStartIfOnBatteries = $false
$set.StopIfGoingOnBatteries     = $false
$set.RunOnlyIfIdle              = $false
$set.StartWhenAvailable         = $true   # catch up missed runs after downtime
Set-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>' -Settings $set
```
If the principal is `LogonType Interactive` ("Run only when user is logged on") and no one is logged on → switch to SYSTEM, gMSA, or stored password (Fix 6). `EndBoundary` in the past = trigger expired → recreate trigger.
</details>

<details><summary>Fix 6 — Credential / logon failures (0x8007052E, Event 101/104, 0x80070005)</summary>

Re-store the password after a service-account change:
```powershell
Set-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>' -User '<DOMAIN\svc-account>' -Password '<password>'
```
(Prompt for it rather than typing into history in shared sessions: `$c = Get-Credential; ... -User $c.UserName -Password $c.GetNetworkCredential().Password`.)

Better — convert to a gMSA (no stored password to expire):
```powershell
$p = New-ScheduledTaskPrincipal -UserId '<DOMAIN\gmsa-name$>' -LogonType Password -RunLevel Highest
Set-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>' -Principal $p
Test-ADServiceAccount '<gmsa-name>'   # must be True on this host (RSAT AD module)
```
"Log on as a batch job" (`SeBatchLogonRight`): check `secpol.msc → Local Policies → User Rights Assignment`, or `gpresult /h` for a GPO that overwrote the list. Also check "Network access: Do not allow storage of passwords and credentials for network authentication" — if Enabled, stored-password tasks can't access network resources.
</details>

<details><summary>Fix 7 — Corrupt / ghost task ("The task image is corrupt or has been tampered with", task missing in UI)</summary>

```powershell
Export-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>' | Out-File C:\Temp\<TaskName>.xml   # if exportable
Unregister-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>' -Confirm:$false
Register-ScheduledTask -Xml (Get-Content C:\Temp\<TaskName>.xml -Raw) -TaskName '<TaskName>' -TaskPath '<\Path\>' -User '<DOMAIN\svc-account>' -Password '<password>'
```
If not exportable, the XML file lives at `C:\Windows\System32\Tasks\<path>\<TaskName>`; its registration is under `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree` and `\Tasks\{GUID}`. A mismatch between the two produces the "corrupt" error — back up both (`reg export`) before deleting either, then recreate. For GPO-deployed tasks (Preferences → Scheduled Tasks), fix the GPO instead; it will re-create on refresh (`gpupdate /force`).
</details>

---
## Escalation Evidence
```
Hostname / OS build:                ____________________
Task path + name:                   ____________________
Deployed by (manual/GPO/Intune/app):____________________
Principal (UserId / LogonType / RunLevel): ____________________
Trigger(s) + NextRunTime:           ____________________
LastRunTime / LastTaskResult (hex): ____________________
Manual Start-ScheduledTask result:  ____________________
Reproduced as principal? result:    ____________________
Operational log event IDs seen:     ____________________
History enabled:                    Yes / No
Attached: task XML export, Operational log (.evtx), action script transcript   [ ]
```

---
## 🎓 Learning Pointers
- `LastTaskResult` is usually the *action's* exit code, not a Task Scheduler error — `0x1` is your script failing. Make scripts exit non-zero on failure so the result means something. [Task Scheduler error and success constants](https://learn.microsoft.com/windows/win32/taskschd/task-scheduler-error-and-success-constants)
- The Operational log event chain (100/200/129/201/102) tells you exactly where a run stopped — turn history on before you troubleshoot.
- SYSTEM uses the computer account on the network; a gMSA removes password-expiry failures entirely. [Group Managed Service Accounts overview](https://learn.microsoft.com/windows-server/security/group-managed-service-accounts/group-managed-service-accounts-overview)
- Cmdlet reference for everything above: [ScheduledTasks module](https://learn.microsoft.com/powershell/module/scheduledtasks/).
- Deploying tasks at scale: GPO Preferences for domain estates, Intune remediations / Win32 app install scripts for cloud-managed — see `GPO-B.md` and `Intune/Troubleshooting/` for deploy-side failures.
