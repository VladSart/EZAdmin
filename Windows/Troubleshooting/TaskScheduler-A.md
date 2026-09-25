# Task Scheduler (Scheduled Tasks) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what. Hotfix path: `TaskScheduler-B.md`. Fleet audit script: `Windows/Scripts/Get-ScheduledTaskHealth.ps1`.

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
- **In scope:** Task Scheduler 2.0 (Windows 10/11, Windows Server 2016–2025): the Schedule service, task definition storage, principals and logon types, triggers/conditions/settings, run history, deployment via GPO Preferences / Intune scripts / Win32 apps, remote management, and security auditing of task changes.
- **Out of scope:** Automatic Maintenance internals beyond how it gates `\Microsoft\Windows\` tasks; Intune Remediations (run by the Intune Management Extension, not Task Scheduler — see `Intune/Troubleshooting/`); ConfigMgr maintenance windows; Azure Automation / Logic Apps schedules.
- **Assumptions:** elevated PowerShell 5.1+, `ScheduledTasks` module present (inbox since Windows 8 / Server 2012). Placeholders: `<TaskName>`, `<\Path\>` (root is `\`), `<DOMAIN\account>`, `<gMSA$>`, `<Computer>`.
- **Accuracy note:** event IDs and HRESULTs below are the established Task Scheduler 2.0 values; always confirm against the message text in the Operational log on the affected build.

---
## How It Works
<details><summary>Full architecture</summary>

### 1. Components
```
 Callers                         Engine                               Storage
 ─────────                       ──────                               ───────
 taskschd.msc ─┐                                                      C:\Windows\System32\Tasks\<path>\<name>   (XML definition)
 schtasks.exe ─┤   RPC / COM     ┌───────────────────────────────┐    HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\
 ScheduledTasks├──(ITaskService)─▶ Schedule service               │      Schedule\TaskCache\Tree\<path>     (Id GUID, SD, Index)
  (CIM/WMI)    │                 │  svchost -k netsvcs (schedsvc) │      Schedule\TaskCache\Tasks\{GUID}    (Path, Hash, Actions,
 GPP / Intune ─┘                 │  • trigger engine              │                                          Triggers, DynamicInfo)
                                 │  • condition evaluator         │      Schedule\TaskCache\Boot|Logon|Plain|Maintenance (indexes)
                                 │  • credential broker ──────────┼──▶ LSA / credential vault (stored passwords)
                                 │  • launches taskhostw.exe or   │
                                 │    the Exec action directly    │    Microsoft-Windows-TaskScheduler/Operational  (history)
                                 └───────────────────────────────┘    Security log 4698–4702 (if auditing enabled)
```
- The **Schedule** service is protected: on current Windows it cannot be stopped or disabled through the Services console. If it is not running, something has tampered with the service configuration — treat as a security event as much as an outage.
- A task has **two copies of truth**: the XML file under `System32\Tasks` and the registry `TaskCache`. The service loads from the registry; the `Hash` value in `TaskCache\Tasks\{GUID}` must match the XML. A mismatch (file edited by hand, partial copy, restore of only one half, AV quarantine) produces *"The task image is corrupt or has been tampered with"* or a task that shows in `schtasks` but not the MMC (or vice versa).
- **COM handler** actions run inside `taskhostw.exe`; **Exec** actions (`powershell.exe`, `cmd.exe`, your binary) are launched as a new process by the service in the principal's logon session.

### 2. Task definition anatomy (XML, schema `http://schemas.microsoft.com/windows/2004/02/mit/task`)
| Element | What it controls | Field gotchas |
|---|---|---|
| `RegistrationInfo` | Author, Description, URI, `SecurityDescriptor` | SD controls who can see/run/modify the task; tightened SDs hide tasks from non-admins |
| `Triggers` | Time, Calendar (daily/weekly/monthly), Boot, Logon, Idle, Event (XPath), Registration, SessionStateChange | `EndBoundary` in the past = no `NextRunTime`; repetition `Duration` blank = indefinite; `RandomDelay` shifts runs by up to N |
| `Principals` | `UserId` / `GroupId`, `LogonType`, `RunLevel` (`LeastPrivilege` / `HighestAvailable`) | RunLevel Highest = elevated token only if the account is an admin |
| `Settings` | `MultipleInstancesPolicy`, `ExecutionTimeLimit` (default `PT72H`), `DisallowStartIfOnBatteries` (default true), `StopIfGoingOnBatteries`, `StartWhenAvailable`, `RunOnlyIfNetworkAvailable`, `RunOnlyIfIdle`, `WakeToRun`, `Priority` (default 7), `Hidden`, `Enabled` | Defaults are laptop-hostile: on battery the task never starts and returns `0x800710E0` |
| `Actions` | Exec (Command/Arguments/WorkingDirectory), ComHandler; Email/ShowMessage are deprecated and fail on 2.0 | Up to 32 actions run **sequentially**; the first failing action ends the run |

**Priority 7** maps to *below-normal* CPU priority and low I/O/memory priority. A script that takes 2 minutes interactively can take far longer as a task. Set `Priority` to 4–6 for time-sensitive jobs (via XML or `New-ScheduledTaskSettingsSet -Priority`).

### 3. Principals and logon types — the root of most "works interactively, fails as a task" tickets
| LogonType (XML / CIM) | UI equivalent | Password stored? | Network access | Typical failure |
|---|---|---|---|---|
| `InteractiveToken` | "Run only when user is logged on" | No | As the user | Nobody logged on → task not started (`0x800710E0` / Event 332); runs **visibly** on the desktop |
| `Password` | "Run whether user is logged on or not" | **Yes** (LSA) | Full, as the account | Password changed/expired → `0x8007052E` / Event 101; needs *Log on as a batch job* |
| `S4U` | "…whether logged on or not" + "Do not store password" | No | **None** (local-only token, no Kerberos delegation) | UNC paths / SQL / web APIs fail with access denied while local work succeeds |
| `ServiceAccount` | SYSTEM, LOCAL SERVICE, NETWORK SERVICE | No | SYSTEM & NETWORK SERVICE = **computer account** (`DOMAIN\HOST$`); LOCAL SERVICE = anonymous | Share ACL missing the computer account; SYSTEM has no user profile/HKCU/mapped drives |
| `Password` + gMSA (`<gMSA$>`) | Only via PowerShell/schtasks | No — retrieved from AD | Full, as the gMSA | Host not in `PrincipalsAllowedToRetrieveManagedPassword`, no batch-logon right, KDS root key issue |
| `Group` | "Run only when user is logged on" for a group (`BUILTIN\Users`) | No | As each logged-on user | Runs once **per** matching session |

Key consequences:
- **Mapped drives never exist** for a task unless the action maps them itself. Always use UNC paths.
- **SYSTEM on the network is the computer account.** Grant `DOMAIN\HOST$` (or a group containing computers) share + NTFS rights.
- **Stored passwords are a lifecycle liability.** Every rotation of a service-account password breaks every task that stored it, silently, at the next run. gMSA eliminates this; S4U eliminates it only for local-only work.
- **GPO Preferences cannot store passwords** (removed after MS14-025). GPP tasks must run as SYSTEM, a group, the logged-on user (`%LogonDomain%\%LogonUser%`), or be deployed another way.

### 4. Run lifecycle (Operational log event chain)
```
 Trigger fires (107 time / 118 boot / 119 logon / 108 event / 110 user-run)
   └─ Conditions evaluated (battery, idle, network) ── fail → not started (no 100) or 0x800710E0
       └─ Instance policy checked ── IgnoreNew & running → 322 (0x8004131F)   Queue → 325
           └─ 100 Task started
               └─ Principal logon ── fail → 101 (logon failure / batch right) 
                   └─ 200 Action started → 129 process created (PID)
                       │                      └─ 203 / 103 action failed to launch (path, rights)
                       └─ 201 Action completed (return code = LastTaskResult)
                           └─ 102 Task completed        |  329 stopped by ExecutionTimeLimit  → 0x41306
```
Other lifecycle events: **106** registered, **140** updated, **141** deleted, **142** disabled, **111** terminated by user.

`LastTaskResult` is the **exit code of the last action** when the process ran; it is a Task Scheduler HRESULT (`0x41xxx` / `0x8004xxxx`) only when the scheduler itself intervened. `0x1` is almost always your script — not the scheduler.

### 5. Deployment channels and how each breaks
| Channel | Mechanism | Failure pattern |
|---|---|---|
| GPO Preferences → Scheduled Tasks | CSE writes the task at each GP refresh | **Replace** action deletes & recreates every 90 min ± 30 → history resets, `NextRunTime` jumps, running instances can be killed. Use **Update** unless you really need Replace. Item-level targeting mismatches = task silently absent |
| GPP Immediate Task | Created, run once, deleted | Runs again on every refresh unless "Apply once and do not reapply" is set |
| Intune PowerShell script / Win32 app install | `Register-ScheduledTask` in the payload | Platform scripts run in **32-bit** PowerShell unless "Run script in 64-bit PowerShell host" = Yes. The registered task itself is launched by the 64-bit service, so a `Test-Path` / file copy done by the 32-bit installer script (redirected to `SysWOW64` / `Program Files (x86)`) can disagree with what the task later sees. Run registration + validation in 64-bit; detection rule = task exists with expected XML |
| Software installers | MSI / vendor setup registers tasks (updaters) | Uninstall leaves orphaned tasks pointing at deleted binaries → `0x80070002` forever |
| `schtasks /create /xml` | Import exported definition | XML from another machine keeps the old `UserId` SID / Author; re-specify `/ru` |

### 6. Remote management
- `ScheduledTasks` cmdlets accept `-CimSession`, which uses WinRM (WS-Man). `schtasks /s <Computer>` uses RPC over SMB/named pipes and needs the **Remote Scheduled Tasks Management** firewall rule group.
- Both need local admin on the target for anything beyond read of non-hidden tasks.

### 7. Security & auditing
- Scheduled tasks are one of the most common persistence mechanisms (MITRE ATT&CK T1053.005). Security log events **4698** (created), **4699** (deleted), **4700** (enabled), **4701** (disabled), **4702** (updated) are only written when **Audit Other Object Access Events** is enabled.
- Microsoft Defender for Endpoint raises alerts on suspicious task creation; hidden tasks with SD stripped from `TaskCache\Tree` (removing the `SD` value hides a task from enumeration) are a known attacker technique — an orphan/SD-less entry found by the audit script is a security escalation, not just cleanup.
</details>

---
## Dependency Stack
```
Layer 7  Intended business outcome (file copied, report sent, service restarted)
Layer 6  Action logic: script exit codes, working directory, UNC paths, 64-bit host, transcript/logging
Layer 5  Action launch: Execute path exists & readable by principal, interpreter + args quoted correctly
Layer 4  Principal logon: LogonType valid, password/gMSA retrievable, "Log on as a batch job", not in "Deny log on as batch"
Layer 3  Gating: trigger active (EndBoundary, enabled), conditions (AC/idle/network), instance policy, ExecutionTimeLimit
Layer 2  Definition integrity: XML in System32\Tasks ≡ TaskCache registry (Tree/Tasks, Hash, SD), task Enabled
Layer 1  Schedule service running (protected), RPC/COM, Event Log service (for history + event triggers)
Layer 0  OS: time/timezone correct, power state (sleep/hibernate, WakeToRun), domain connectivity for domain principals
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| `0x1` | Script/program returned 1 — execution policy, bad path in script, unhandled error | Run action line as principal; add `-NoProfile -ExecutionPolicy Bypass -File`, transcript |
| `0x2` / `0x80070002` | `Execute` or script path not found (relative path, quotes, deleted app) | `$t.Actions` — Test-Path expanded path |
| `0x0` but no effect | Wrong context (SYSTEM has no HKCU/mapped drives), relative paths without WorkingDirectory, silent script failure | Transcript; `whoami` in action |
| `0x41301` persists | Previous instance hung; `ExecutionTimeLimit` disabled / too long | `Get-ScheduledTask | ? State -eq Running`; Event 129 PID still alive |
| `0x41303` | Never ran — trigger never fired | `NextRunTime`, trigger `EndBoundary`, Enabled |
| `0x41306` | Stopped by user or `ExecutionTimeLimit` (Event 329) | Compare run duration to limit |
| `0x8004131F` / Event 322 | IgnoreNew + instance still running | Instance policy, hung process |
| `0x800710E0` | Conditions not met (battery, idle, network) or InteractiveToken with nobody logged on | Settings: `DisallowStartIfOnBatteries`, `RunOnlyIfIdle`, LogonType |
| `0x8007052E` / Event 101 | Stored password wrong/expired/account locked | AD `pwdLastSet` vs task `Date`; re-register or move to gMSA |
| `0x80070005` / Event 101/104 | No *Log on as a batch job*, or denied via GPO; ACL on script | `secedit /export` → `SeBatchLogonRight`, `SeDenyBatchLogonRight` |
| `0xC000013A` | Process terminated (task stopped, shutdown, console closed) | Correlate with 111/329/shutdown events |
| Works on demand, never on schedule | Trigger/conditions, or `StartWhenAvailable` off with device asleep at trigger time | Event 107 present? `NumberOfMissedRuns` |
| Task runs twice / many times | GPP Replace recreating it; `Group` principal (one per session); repetition + multiple triggers | GPP action type; triggers list |
| "Task image is corrupt or has been tampered with" | XML ≠ TaskCache hash; partial restore; manual XML edit | Playbook 5 |
| Task visible in `schtasks` not MMC (or reverse) | Orphan: registry without XML, or XML without registry; SD removed | Script `-CheckOrphans` |
| Runs fine as admin, fails for standard principal | `RunLevel Highest` required, or file ACLs | Principal RunLevel |
| Event-triggered task never fires | XPath query wrong, channel disabled, event published to a different log | Test XPath in Event Viewer custom view |

---
## Validation Steps
1. **Service and history**
   ```powershell
   Get-Service Schedule | Select-Object Status, StartType
   (Get-WinEvent -ListLog 'Microsoft-Windows-TaskScheduler/Operational').IsEnabled
   ```
   Good: `Running / Automatic`, `True`. Bad: service not running (tampering — escalate to security), history `False` (enable before anything else).
2. **Definition parity (local)**
   ```powershell
   $name='<TaskName>'; $path='<\Path\>'
   Test-Path (Join-Path "$env:windir\System32\Tasks" ($path.TrimStart('\') + $name))
   Get-Item "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree$path$name" | Get-ItemProperty | Select-Object Id, Index, @{n='HasSD';e={$null -ne $_.SD}}
   ```
   Good: file exists, registry key has `Id` and `SD`. Bad: either missing → orphan (Playbook 5); `SD` absent → hidden task, investigate as persistence.
3. **Principal is viable**
   ```powershell
   $t = Get-ScheduledTask -TaskPath $path -TaskName $name
   $t.Principal | Select-Object UserId, LogonType, RunLevel
   ```
   Good: SYSTEM/gMSA, or a Password principal whose account is enabled and whose password hasn't changed since the task was registered. Bad: `S4U` with UNC paths in the action; `InteractiveToken` on a server.
4. **Settings aren't sabotaging the run**
   ```powershell
   $t.Settings | Select-Object DisallowStartIfOnBatteries, StopIfGoingOnBatteries, RunOnlyIfNetworkAvailable, RunOnlyIfIdle, StartWhenAvailable, MultipleInstances, ExecutionTimeLimit, Priority, Enabled
   ```
   Good (laptop job): battery flags `False`, `StartWhenAvailable True`, sensible `ExecutionTimeLimit` (not `PT0S` = unlimited for a job that can hang).
5. **Trigger will fire**
   ```powershell
   $t.Triggers | Select-Object @{n='Type';e={$_.CimClass.CimClassName}}, Enabled, StartBoundary, EndBoundary, @{n='Repeat';e={$_.Repetition.Interval}}
   (Get-ScheduledTaskInfo -InputObject $t).NextRunTime
   ```
   Good: `NextRunTime` populated (except boot/logon/event triggers, where empty is normal).
6. **End-to-end run**
   ```powershell
   Start-ScheduledTask -InputObject $t; Start-Sleep 15
   Get-ScheduledTaskInfo -InputObject $t | Select-Object LastRunTime, @{n='Hex';e={'0x{0:X}' -f $_.LastTaskResult}}
   ```
   Good: `0x0` and the side-effect happened; Operational log shows 100→200→129→201→102.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Did the scheduler try?** Look for trigger events (107/118/119/108/110) around the expected time. None → Layer 3 (trigger disabled/expired, device asleep, `StartWhenAvailable` off) or Layer 2 (task disabled/orphaned). GPP-deployed? Check whether it was just recreated (Event 106/140 timestamps at each GP refresh).

**Phase 2 — Did it start?** Trigger present but no 100 → conditions or instance policy (322/325). 100 then 101 → principal logon (Layer 4): read the 101 message — "logon failure" = password, "not granted the requested logon type" = batch right.

**Phase 3 — Did the action launch?** 200 without 129, or 203/103 → path/ACL/interpreter (Layer 5). Expand env vars and test the path **as the principal**, not as you.

**Phase 4 — Did the action succeed?** 201 carries the return code. Non-zero → Layer 6: reproduce with `psexec -s` (SYSTEM) or `runas` and a transcript. Zero but no effect → context problem (HKCU, mapped drives, 32/64-bit, WorkingDirectory).

**Phase 5 — Did it finish cleanly?** 102 missing, 329 present → timeout; process still alive → hang (dialog box waiting for input in session 0, network wait, lock). Kill, fix the hang cause, set a realistic `ExecutionTimeLimit`.

---
## Remediation Playbooks
<details><summary>Playbook 1 — Migrate a stored-password task to a gMSA</summary>

Prereqs: KDS root key exists; gMSA created with the host in `PrincipalsAllowedToRetrieveManagedPassword`; gMSA has rights to the resources.
```powershell
# On the host
Install-WindowsFeature RSAT-AD-PowerShell -ErrorAction SilentlyContinue | Out-Null   # servers only
Test-ADServiceAccount -Identity '<gMSA>'          # must be True

# Export current definition for rollback
Export-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>' | Out-File "C:\Temp\<TaskName>-pre-gmsa.xml" -Encoding Unicode

$p = New-ScheduledTaskPrincipal -UserId '<DOMAIN>\<gMSA>$' -LogonType Password -RunLevel Highest
Set-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>' -Principal $p
Start-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>'
```
Grant the gMSA **Log on as a batch job** (GPO: Computer Configuration → Windows Settings → Security Settings → Local Policies → User Rights Assignment).
**Rollback:** `Register-ScheduledTask -TaskName '<TaskName>' -TaskPath '<\Path\>' -Xml (Get-Content C:\Temp\<TaskName>-pre-gmsa.xml -Raw) -User '<DOMAIN\account>' -Password '<password>' -Force`
</details>

<details><summary>Playbook 2 — Rebuild a laptop-safe task definition</summary>

```powershell
$action   = New-ScheduledTaskAction -Execute "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" `
              -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\<Org>\<script>.ps1"' `
              -WorkingDirectory 'C:\ProgramData\<Org>'
$trigger  = New-ScheduledTaskTrigger -Daily -At 09:00 -RandomDelay (New-TimeSpan -Minutes 30)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
              -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew -Priority 6
$principal= New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName '<TaskName>' -TaskPath '\<Org>\' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
```
Use a dedicated task folder (`\<Org>\`) so audits and cleanup can target your estate's tasks without touching `\Microsoft\`.
**Rollback:** `Unregister-ScheduledTask -TaskPath '\<Org>\' -TaskName '<TaskName>' -Confirm:$false` (export first).
</details>

<details><summary>Playbook 3 — Make script tasks self-reporting</summary>

Wrap every script so `LastTaskResult` is meaningful and a log exists:
```powershell
# Inside <script>.ps1
$log = "C:\ProgramData\<Org>\Logs\$(Split-Path $PSCommandPath -LeafBase)-$(Get-Date -f yyyyMMdd).log"
Start-Transcript -Path $log -Append | Out-Null
try {
    # ... work ...
    exit 0
} catch {
    Write-Error $_
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
```
Note: `-LeafBase` needs PowerShell 6+; on 5.1 use `[IO.Path]::GetFileNameWithoutExtension($PSCommandPath)`.
</details>

<details><summary>Playbook 4 — Clear a hung instance and prevent recurrence</summary>

```powershell
$t = Get-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>'
Stop-ScheduledTask -InputObject $t
# Find the action's PID from the most recent Event 129 and confirm it is gone
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TaskScheduler/Operational'; Id=129} -MaxEvents 50 |
  Where-Object Message -match [regex]::Escape('<TaskName>') | Select-Object -First 1 TimeCreated, Message
# Set a realistic limit so the scheduler kills future hangs
$s = $t.Settings; $s.ExecutionTimeLimit = 'PT2H'
Set-ScheduledTask -InputObject $t -Settings $s
```
Hang causes to rule out: a UI prompt (tasks run in a non-interactive session — nobody can click OK), `Read-Host`, waiting on a network share, a child process that inherits handles.
</details>

<details><summary>Playbook 5 — Repair a corrupt or orphaned task (destructive)</summary>

1. Export what still exists: `schtasks /query /tn "<\Path\TaskName>" /xml > C:\Temp\<TaskName>.xml` (works if the registry side is intact) **or** copy `C:\Windows\System32\Tasks\<path>\<name>` (if the XML side is intact).
2. Back up the TaskCache: `reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache" C:\Temp\TaskCache.reg`
3. Try the supported removal first: `Unregister-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>' -Confirm:$false`
4. If that fails, remove the leftover half manually:
   - Note `Id` GUID from `TaskCache\Tree\<path>\<name>`.
   - Delete `TaskCache\Tree\<path>\<name>` and `TaskCache\Tasks\{GUID}`, and the `{GUID}` value under `Boot`/`Logon`/`Plain`/`Maintenance` if present.
   - Delete the XML file if it still exists.
5. Re-register from the exported XML: `Register-ScheduledTask -Xml (Get-Content C:\Temp\<TaskName>.xml -Raw) -TaskName '<TaskName>' -TaskPath '<\Path\>' [-User/-Password]`
6. No reboot normally needed; if the MMC still shows ghosts, restart is the only supported way to reload (the service can't be restarted).

**Rollback:** `reg import C:\Temp\TaskCache.reg` and restore the XML file, then reboot.
**Security:** if the orphan has no `SD` value or points to an unknown binary in a user-writable path, stop and hand to security — do not "fix" it.
</details>

<details><summary>Playbook 6 — Stop GPP from churning a task</summary>

- In the GPO: Scheduled Task item → Action **Update** (not Replace). Replace deletes+recreates at every refresh.
- For run-once work use **Immediate Task** + Common tab → **Apply once and do not reapply**.
- If the principal needs network access, use SYSTEM with computer-account rights, or deploy the task by script with a gMSA — GPP cannot store passwords.
- Validate on a client: `gpresult /h C:\Temp\gp.html` → Preferences → Scheduled Tasks; `Get-WinEvent -LogName Application -FilterXPath "*[System[Provider[@Name='Group Policy Scheduled Tasks']]]" -MaxEvents 20`
</details>

<details><summary>Playbook 7 — Turn on task change auditing</summary>

```powershell
auditpol /set /subcategory:"Other Object Access Events" /success:enable /failure:enable
# Verify, then watch for creations
auditpol /get /subcategory:"Other Object Access Events"
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4698,4699,4702} -MaxEvents 20 -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, Message
```
Deploy estate-wide via GPO Advanced Audit Policy rather than `auditpol` per host. **Rollback:** `/success:disable /failure:disable`.
</details>

---
## Evidence Pack
```powershell
# Run elevated. Collects everything needed to escalate one task.
param([string]$TaskPath = '<\Path\>', [string]$TaskName = '<TaskName>', [string]$Out = "C:\Temp\TaskEvidence-$(Get-Date -f yyyyMMdd-HHmm)")
New-Item -ItemType Directory -Path $Out -Force | Out-Null
$t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
Export-ScheduledTask -InputObject $t | Out-File "$Out\task.xml" -Encoding Unicode
Get-ScheduledTaskInfo -InputObject $t | Select-Object *, @{n='LastResultHex';e={'0x{0:X}' -f $_.LastTaskResult}} | Format-List | Out-File "$Out\taskinfo.txt"
$t.Principal, $t.Settings, $t.Triggers, $t.Actions | Format-List * | Out-File "$Out\definition.txt"
Get-Service Schedule | Format-List * | Out-File "$Out\service.txt"
wevtutil epl Microsoft-Windows-TaskScheduler/Operational "$Out\TaskScheduler-Operational.evtx"
wevtutil qe Security /q:"*[System[(EventID=4698 or EventID=4699 or EventID=4700 or EventID=4701 or EventID=4702)]]" /c:200 /f:text > "$Out\security-task-audit.txt" 2>$null
reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree$TaskPath$TaskName" "$Out\tree.reg" /y 2>$null
secedit /export /areas USER_RIGHTS /cfg "$Out\userrights.inf" | Out-Null
gpresult /scope computer /h "$Out\gpresult.html" /f
whoami /all > "$Out\whoami.txt"
Compress-Archive -Path "$Out\*" -DestinationPath "$Out.zip" -Force
Write-Host "Evidence: $Out.zip"
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| List non-Microsoft tasks with results | `Get-ScheduledTask \| ? TaskPath -notlike '\Microsoft\*' \| Get-ScheduledTaskInfo \| select TaskPath,TaskName,LastRunTime,@{n='Hex';e={'0x{0:X}' -f $_.LastTaskResult}}` |
| Verbose dump (all fields incl. "Run As User") | `schtasks /query /v /fo csv > C:\Temp\tasks.csv` |
| Export definition | `Export-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>'` |
| Import definition | `Register-ScheduledTask -Xml (gc <file> -Raw) -TaskName '<TaskName>' -TaskPath '<\Path\>'` |
| Run / stop now | `Start-ScheduledTask` / `Stop-ScheduledTask -TaskPath '<\Path\>' -TaskName '<TaskName>'` |
| Enable / disable | `Enable-ScheduledTask` / `Disable-ScheduledTask` |
| Running tasks | `Get-ScheduledTask \| ? State -eq 'Running'` |
| Enable history | `wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true` |
| Failures last 24h | `Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TaskScheduler/Operational';Id=101,103,203,322,329;StartTime=(Get-Date).AddDays(-1)}` |
| Remote query | `Get-ScheduledTask -CimSession (New-CimSession <Computer>) -TaskPath '\<Org>\'` |
| Batch-logon right holders | `secedit /export /areas USER_RIGHTS /cfg C:\Temp\ur.inf; sls 'SeBatchLogonRight\|SeDenyBatchLogonRight' C:\Temp\ur.inf` |
| gMSA viable on host | `Test-ADServiceAccount -Identity '<gMSA>'` |
| Test as SYSTEM | `psexec -s -i powershell.exe -NoProfile` (Sysinternals) |
| Fleet audit | `.\Get-ScheduledTaskHealth.ps1 -ComputerName (gc hosts.txt) -CheckOrphans` |

---
## 🎓 Learning Pointers
- The task XML schema is the real API — every UI checkbox maps to an element. Reading `Export-ScheduledTask` output is faster than clicking through five tabs. [Task Scheduler Schema](https://learn.microsoft.com/windows/win32/taskschd/task-scheduler-schema)
- LogonType decides network identity: SYSTEM = computer account, S4U = no network, Password = stored secret that will eventually break. [TASK_LOGON_TYPE enumeration](https://learn.microsoft.com/windows/win32/api/taskschd/ne-taskschd-task_logon_type)
- Move stored-password tasks to gMSAs; it removes the #1 recurring cause of `0x8007052E` tickets. [Group Managed Service Accounts overview](https://learn.microsoft.com/windows-server/security/group-managed-service-accounts/group-managed-service-accounts-overview)
- Decode results against the official constants before guessing. [Task Scheduler Error and Success Constants](https://learn.microsoft.com/windows/win32/taskschd/task-scheduler-error-and-success-constants)
- GPP "Replace" vs "Update" semantics explain most "task keeps resetting" reports. [Configure a Scheduled Task item (GPP)](https://learn.microsoft.com/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/cc725745(v=ws.11))
- Treat unknown/hidden tasks as possible persistence: [MITRE ATT&CK T1053.005 — Scheduled Task](https://attack.mitre.org/techniques/T1053/005/) and enable 4698/4702 auditing. Related: `ComponentStore-A.md` (the `StartComponentCleanup` task is a `\Microsoft\` task — don't disable it to "fix" disk space).
