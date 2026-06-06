# Intune Remediations — Reference Runbook (Mode A: Deep Dive)
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

**What this covers:**
- Intune Remediations (formerly Proactive Remediations) — detection + remediation script pairs
- Script execution failures, output parsing, and run schedule issues
- Pre-remediation deployment (detection-only) validation
- Output/error collection and log analysis
- Licensing requirements and scope group targeting

**What this does NOT cover:**
- Intune Shell Scripts (single-shot, non-paired — see `macOS/Troubleshooting/Shell-Script-Failures-B.md`)
- Platform Scripts in Intune (separate pipeline from Remediations)
- PowerShell scripts deployed via Win32 apps or SCCM

**Requirements:**
- Windows 10 1903+ / Windows 11
- Intune Remediations requires **Microsoft Intune Plan 1** (formerly EMS E3 / M365 E3 or above) OR a **Windows 365** license
- Devices must be enrolled in Intune and receiving policies
- Scripts run under `NT AUTHORITY\SYSTEM` by default; user-context scripts run as logged-in user

---

## How It Works

<details><summary>Full Remediations architecture</summary>

### What are Remediations?

Intune Remediations are **paired PowerShell script packages** deployed from Intune to Windows devices:

- **Detection script:** Runs first. Must `exit 0` if healthy (no remediation needed) or `exit 1` if issue detected.
- **Remediation script:** Runs only if detection exits with code 1. Must `exit 0` on success or `exit 1` on failure.
- **Output:** Both scripts can write to stdout (`Write-Output`/`Write-Host`) — Intune captures up to **2048 chars** of output per script.

### Execution Engine

Remediations are executed by the **Microsoft Intune Management Extension (IME)** agent:

```
Intune Management Extension (IntuneManagementExtension.exe)
  Service: "Microsoft Intune Management Extension"
  User: NT AUTHORITY\SYSTEM
  Path: C:\Program Files (x86)\Microsoft Intune Management Extension\
  Log: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\
```

### Execution Flow

```
IME Agent polls Intune Graph endpoint every ~8 hours
(or immediately after: sync, enrollment, reboot)
         │
         ▼
IME downloads script package (detection + remediation)
from: https://pipe.skype.com OR https://bam.nr.data.microsoft.com
(actual CDN endpoint varies — must allow *.manage.microsoft.com traffic)
         │
         ▼
IME writes scripts to temp path:
C:\Program Files (x86)\Microsoft Intune Management Extension\
  Content\Remediation\<PackageGUID>\detection.ps1
  Content\Remediation\<PackageGUID>\remediation.ps1
         │
         ▼
IME spawns PowerShell process (64-bit by default)
  If "Run in 64-bit" = Yes: powershell.exe (x64)
  If "Run in 64-bit" = No:  powershell.exe (x86 / syswow64)
  If "Run as logged-in user" = Yes: runs as current user session
         │
         ▼
Detection script runs
  ├── Exit 0 → "Without issues" state, NO remediation
  └── Exit 1 → "With issues" state, remediation triggered
         │
         ▼ (if exit 1)
Remediation script runs
  ├── Exit 0 → "Remediated" state
  └── Exit 1 → "Failed" state (Intune marks as error)
         │
         ▼
IME reports result to Intune via Graph
(output, exit code, run timestamp stored for 30 days)
```

### Execution Context Details

| Setting | Default | Notes |
|---------|---------|-------|
| Run account | SYSTEM | Change to "User" for user-context fixes (requires logged-in user) |
| 64-bit PowerShell | No | Set to Yes for most admin scripts — avoids registry redirection issues |
| Execution policy | Bypass | Scripts always run with `-ExecutionPolicy Bypass` |
| PowerShell version | Windows PowerShell 5.1 | NOT PowerShell 7 — test scripts on 5.1 |
| Max output captured | 2048 chars | Truncated silently if exceeded |
| Max script runtime | 30 minutes | Script killed at 30 min — no error state set |
| Run schedule | Every 1–24 hours OR once | "Once" = run once per device, not repeated |

### Reporting States in Intune

| State | Meaning |
|-------|---------|
| Without issues | Detection returned exit 0 — device is healthy |
| With issues | Detection returned exit 1 — remediation pending or already ran |
| Remediated | Detection exit 1 → remediation exit 0 |
| Failed | Detection OR remediation returned exit 1 AND remediation ran (or detection failed to run) |
| Pending | Script package downloaded, not yet executed |
| No status | Device not targeted or hasn't checked in |

</details>

---

## Dependency Stack

```
┌──────────────────────────────────────────────────────┐
│  Intune Portal / Graph API                           │
│  Script package deployed to AAD group                │
└──────────────────────────┬───────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────┐
│  Intune Management Extension (IME)                   │
│  IntuneManagementExtension.exe — runs as SYSTEM      │
│  Polls Graph every ~8 hours                          │
└──────────────┬───────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────┐
│  Network: HTTPS to                                   │
│  *.manage.microsoft.com                              │
│  *.delivery.mp.microsoft.com (CDN)                   │
│  login.microsoftonline.com (auth)                    │
└──────────────┬───────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────┐
│  PowerShell 5.1 (x86 or x64 depending on setting)   │
│  Runs detection.ps1 → then remediation.ps1           │
│  Working dir: C:\Windows\System32 (SYSTEM context)  │
└──────────────┬───────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────┐
│  Target device                                       │
│  - Intune enrolled                                   │
│  - Licensed (Intune Plan 1 / EMS E3 / M365 E3+)     │
│  - Member of assigned AAD group                      │
│  - Windows 10 1903+ or Windows 11                    │
└──────────────────────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Device shows "No status" in reports | Device not in target group, or IME not running | Check group membership; check IME service |
| Status permanently "Pending" | IME downloaded package but hasn't run it yet | Check IME log for scheduling errors |
| Status "Failed" — detection didn't run | Script download failed or PowerShell crash | IME log: `AgentExecutor.log` |
| Status "Failed" — remediation ran but exited 1 | Script logic error or missing dependency | Check remediation script output in Intune |
| Output is truncated / "..." in portal | Script wrote more than 2048 chars | Trim output; only write key status lines |
| Script works in manual test but fails in Intune | Path issues (SYSTEM vs. user context), 32-bit vs 64-bit | Check "Run in 64-bit" setting; test as SYSTEM |
| Remediation re-runs every cycle even after fix | Detection script not updated to return exit 0 after fix | Review detection logic — it runs before remediation |
| "Script signature" errors in logs | Tenant has strict PowerShell policy applied via Intune | Override with `Set-ExecutionPolicy` at script start (not needed — IME uses Bypass) |
| Device in group but remediation never triggers | Licensing gap — device owner has no Intune Plan 1 | Check user license assignment in M365 admin |
| Output shows error but state is "Remediated" | Remediation script exited 0 despite errors | Ensure all error paths call `exit 1` explicitly |
| Status flaps between "Remediated" and "With issues" | Detection trigger condition still present after partial fix | Review detection logic — conditions may be transient |
| Run schedule not respected | IME sync cycle delayed (no reboot in >7 days) | Restart IME service; check device last check-in |

---

## Validation Steps

**Step 1 — Check IME service and version**
```powershell
Get-Service -Name IntuneManagementExtension | Select-Object Name, Status, StartType
Get-Item "C:\Program Files (x86)\Microsoft Intune Management Extension\IntuneManagementExtension.exe" |
    Select-Object -ExpandProperty VersionInfo | Select-Object FileVersion, ProductVersion
```
Good: Status = Running, version should match current Intune IME release.
Bad: Status = Stopped — remediation engine isn't running.

---

**Step 2 — Check IME log for remediation execution**
```powershell
$logPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
# Search for your script/package GUID or "Remediation" entries
Select-String -Path $logPath -Pattern "Remediation|ProactiveRemediation|HealthScript" | 
    Select-Object -Last 50 |
    Format-Table LineNumber, Line -AutoSize
```

---

**Step 3 — Find script content on device**
```powershell
$remediationBase = "C:\Program Files (x86)\Microsoft Intune Management Extension\Content\Remediation"
Get-ChildItem $remediationBase -Recurse -Filter "*.ps1" |
    Select-Object FullName, LastWriteTime, Length |
    Format-Table -AutoSize
```
Good: detection.ps1 and remediation.ps1 present for each deployed package.
Bad: Missing files indicate download failure.

---

**Step 4 — Check AgentExecutor log for script errors**
```powershell
$agentLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log"
if (Test-Path $agentLog) {
    Select-String -Path $agentLog -Pattern "error|exception|fail|exit" -CaseSensitive:$false |
        Select-Object -Last 30 |
        Format-Table LineNumber, Line -AutoSize
}
```

---

**Step 5 — Manually run detection script as SYSTEM (simulate Intune)**
```powershell
# Install PSExec from Sysinternals, or use this PsExec-free method:
# Create a scheduled task to run the detection script as SYSTEM

$scriptPath = "<path-to-detection-script.ps1>"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
$task = Register-ScheduledTask -TaskName "IME-TestDetection" -Action $action -Trigger $trigger -Principal $principal -Force
Start-ScheduledTask -TaskName "IME-TestDetection"
Start-Sleep -Seconds 10
Get-ScheduledTaskInfo -TaskName "IME-TestDetection" | Select-Object LastRunTime, LastTaskResult
Unregister-ScheduledTask -TaskName "IME-TestDetection" -Confirm:$false
```

`LastTaskResult 0` = exit 0 (healthy). `LastTaskResult 1` = exit 1 (issue detected).

---

**Step 6 — Check device group membership and license**
```powershell
# Run from admin workstation with Graph module
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All","Group.Read.All","User.Read.All"

# Get device
$deviceName = "<deviceName>"
$device = Get-MgDevice -Filter "displayName eq '$deviceName'"

# Check group membership
Get-MgDeviceMemberOf -DeviceId $device.Id | Select-Object -ExpandProperty AdditionalProperties | 
    ForEach-Object { $_.displayName }
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm IME is running and syncing

1. Run Step 1 — verify service is Running
2. If stopped: `Start-Service IntuneManagementExtension`
3. Force an IME sync: `Get-ScheduledTask | Where-Object TaskName -like "*Intune*" | Start-ScheduledTask`
   Or trigger from Company Portal → Sync
4. Check IME log for "Polling" entries confirming Graph communication

### Phase 2 — Confirm targeting is correct

1. Open Intune portal → Remediations → [your package] → Device status
2. Confirm the affected device appears in the list
3. If missing: check group assignment — is the device's **primary user** in the assigned AAD group?
4. Note: Remediations require a **licensed user** associated with the device, not just device group membership

### Phase 3 — Diagnose script failures

1. Pull the script package from the device (Step 3)
2. Review detection logic — does it correctly exit 0 / exit 1?
3. Check for hardcoded paths that differ between SYSTEM and user context
4. Check for 32-bit vs 64-bit issues:
   - `$env:ProgramFiles` in x86 context resolves to `C:\Program Files (x86)` — wrong for most admin tools
   - Enable "Run in 64-bit PowerShell" in Intune Remediations settings
5. Run detection manually as SYSTEM (Step 5) and capture output

### Phase 4 — Review output in Intune portal

1. Intune portal → Remediations → [package] → Device status → click device
2. Review **Detection script output** and **Remediation script output**
3. Check **Pre-remediation detection output** vs **Post-remediation detection output**
4. If output is truncated: trim `Write-Output` statements in the script — cap to < 1500 chars

### Phase 5 — Script logic issues

Common script bugs causing false states:

1. **Detection exits 0 even when issue exists** — logic error, wrong comparison, wrong registry path
2. **Remediation exits 0 but doesn't fix issue** — fix ran but didn't check success; add validation at end of remediation and exit 1 if fix failed
3. **Scripts terminate early due to unhandled exception** — add `$ErrorActionPreference = "Stop"` + try/catch to control exit codes
4. **Script uses `exit` without code** — bare `exit` = exit 0 in PowerShell; must use `exit 1` explicitly

---

## Remediation Playbooks

<details><summary>Playbook 1 — Restart the IME service and force re-run</summary>

**When to use:** Remediation stuck in "Pending" or hasn't run after expected schedule.

```powershell
# Restart IME service
Restart-Service -Name IntuneManagementExtension -Force
Start-Sleep -Seconds 5

# Verify running
Get-Service IntuneManagementExtension | Select-Object Status

# Trigger Intune sync (forces IME to re-poll)
$intuneSync = Get-ScheduledTask | Where-Object { $_.TaskName -like "*Schedule*Sync*Intune*" }
if ($intuneSync) {
    Start-ScheduledTask -TaskPath $intuneSync.TaskPath -TaskName $intuneSync.TaskName
    Write-Host "Intune sync task triggered." -ForegroundColor Green
} else {
    # Fallback: trigger via WMI
    Invoke-WmiMethod -Namespace root\ccm -Class SMS_Client -Name TriggerSchedule -ArgumentList "{00000000-0000-0000-0000-000000000021}"
    Write-Host "WMI sync triggered." -ForegroundColor Yellow
}

Write-Host "Wait 10-15 minutes, then check device status in Intune portal."
```

</details>

<details><summary>Playbook 2 — Clear IME cache and re-download scripts</summary>

**When to use:** Scripts on device are corrupted, truncated, or outdated vs. what's in the portal.

**Destructive:** Clears all IME content — all scripts and Win32 apps will re-download. Only do this during a maintenance window if the device has many Intune apps.

```powershell
# Stop IME
Stop-Service IntuneManagementExtension -Force

# Clear content cache (scripts, Win32 app content)
$imeCachePaths = @(
    "C:\Program Files (x86)\Microsoft Intune Management Extension\Content",
    "$env:ProgramData\Microsoft\IntuneManagementExtension\Content"
)
foreach ($path in $imeCachePaths) {
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force
        Write-Host "Cleared: $path" -ForegroundColor Yellow
    }
}

# Restart IME — will re-download all content from Intune
Start-Service IntuneManagementExtension
Write-Host "IME restarted. Content will re-download on next poll (up to 8 hours or trigger sync)." -ForegroundColor Green
```

**Rollback:** Not applicable — content is re-downloaded from Intune on restart.

</details>

<details><summary>Playbook 3 — Debug a specific remediation script failure</summary>

**When to use:** A specific remediation package reports "Failed" and you need to isolate the script error.

```powershell
# Step 1: Extract the actual script from the device
$remediationBase = "C:\Program Files (x86)\Microsoft Intune Management Extension\Content\Remediation"
$packages = Get-ChildItem $remediationBase -Directory
Write-Host "Found $($packages.Count) remediation packages:" -ForegroundColor Cyan
$packages | ForEach-Object { 
    $scripts = Get-ChildItem $_.FullName -Filter "*.ps1"
    Write-Host "  $($_.Name): $($scripts.Name -join ', ')" 
}

# Step 2: Select your package and test detection
$packageGUID = Read-Host "Enter package GUID to test"
$detectionScript = Join-Path $remediationBase "$packageGUID\detection.ps1"
$remediationScript = Join-Path $remediationBase "$packageGUID\remediation.ps1"

# Step 3: Run detection as SYSTEM using scheduled task method
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -NonInteractive -File `"$detectionScript`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(3)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
Register-ScheduledTask -TaskName "RemTest-Detection" -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
Start-Sleep -Seconds 10
$result = Get-ScheduledTaskInfo -TaskName "RemTest-Detection"
Write-Host "Detection exit code: $($result.LastTaskResult)" -ForegroundColor $(if($result.LastTaskResult -eq 0){"Green"}else{"Yellow"})
Unregister-ScheduledTask -TaskName "RemTest-Detection" -Confirm:$false
```

</details>

<details><summary>Playbook 4 — Write a well-structured detection/remediation pair</summary>

**Template — Detection script:**

```powershell
<#
.SYNOPSIS   Detects [issue description]
.NOTES      Exit 0 = healthy (no remediation needed)
            Exit 1 = issue detected (remediation will run)
#>
$ErrorActionPreference = "Stop"

try {
    # Define what "healthy" looks like
    $regPath = "HKLM:\SOFTWARE\<YourKey>"
    $expectedValue = "ExpectedValue"
    
    if (-not (Test-Path $regPath)) {
        Write-Output "DETECT: Registry key missing — issue detected"
        exit 1
    }
    
    $currentValue = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).<ValueName>
    
    if ($currentValue -ne $expectedValue) {
        Write-Output "DETECT: Value is '$currentValue', expected '$expectedValue' — issue detected"
        exit 1
    }
    
    Write-Output "DETECT: All checks passed — device is healthy"
    exit 0
}
catch {
    Write-Output "DETECT: Exception — $($_.Exception.Message)"
    exit 1  # Treat detection errors as "issue detected" to trigger remediation
}
```

**Template — Remediation script:**

```powershell
<#
.SYNOPSIS   Remediates [issue description]
.NOTES      Exit 0 = remediation succeeded
            Exit 1 = remediation failed
#>
$ErrorActionPreference = "Stop"

try {
    $regPath = "HKLM:\SOFTWARE\<YourKey>"
    $valueName = "<ValueName>"
    $desiredValue = "ExpectedValue"
    
    # Apply fix
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    Set-ItemProperty -Path $regPath -Name $valueName -Value $desiredValue -Type String
    
    # Validate the fix worked
    $newValue = (Get-ItemProperty $regPath).$valueName
    if ($newValue -ne $desiredValue) {
        Write-Output "REMEDIATE: Fix applied but value still wrong — '$newValue'"
        exit 1
    }
    
    Write-Output "REMEDIATE: Successfully set '$valueName' to '$desiredValue'"
    exit 0
}
catch {
    Write-Output "REMEDIATE: Failed — $($_.Exception.Message)"
    exit 1
}
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS   Collects Intune Remediations diagnostic evidence.
.NOTES      Run as administrator on the affected device.
#>

$outputDir = "$env:TEMP\Remediations-Evidence-$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# 1. IME service status and version
Get-Service IntuneManagementExtension | Select-Object Name, Status, StartType |
    Export-Csv "$outputDir\ime-service.csv" -NoTypeInformation
Get-Item "C:\Program Files (x86)\Microsoft Intune Management Extension\IntuneManagementExtension.exe" |
    Select-Object -ExpandProperty VersionInfo |
    Export-Csv "$outputDir\ime-version.csv" -NoTypeInformation

# 2. IME main log (last 500 lines)
$logPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Get-Content $logPath -Tail 500 | Out-File "$outputDir\ime-log-tail.txt"

# 3. AgentExecutor log (full)
$agentLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log"
if (Test-Path $agentLog) { Copy-Item $agentLog "$outputDir\AgentExecutor.log" }

# 4. List deployed remediation packages
$remBase = "C:\Program Files (x86)\Microsoft Intune Management Extension\Content\Remediation"
if (Test-Path $remBase) {
    Get-ChildItem $remBase -Recurse | Select-Object FullName, Length, LastWriteTime |
        Export-Csv "$outputDir\remediation-packages.csv" -NoTypeInformation
}

# 5. Intune event log
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 100 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$outputDir\intune-events.csv" -NoTypeInformation

# 6. Device info
[PSCustomObject]@{
    DeviceName      = $env:COMPUTERNAME
    OSVersion       = (Get-CimInstance Win32_OperatingSystem).Version
    OSBuild         = (Get-CimInstance Win32_OperatingSystem).BuildNumber
    IMEService      = (Get-Service IntuneManagementExtension).Status
    CurrentUser     = $env:USERNAME
    CollectedAt     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
} | Export-Csv "$outputDir\device-info.csv" -NoTypeInformation

Write-Host "`n✅ Evidence collected to: $outputDir" -ForegroundColor Green
Write-Host "Zip for ticket: Compress-Archive '$outputDir' '$env:TEMP\Remediations-Evidence.zip'" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Check IME service | `Get-Service IntuneManagementExtension` |
| Restart IME | `Restart-Service IntuneManagementExtension -Force` |
| Tail IME log | `Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Wait -Tail 50` |
| List remediation packages on device | `Get-ChildItem "C:\Program Files (x86)\Microsoft Intune Management Extension\Content\Remediation"` |
| Grep IME log for errors | `Select-String "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Pattern "error|fail"` |
| Test script as SYSTEM (via schtasks) | `schtasks /create /tn "Test" /tr "powershell -ep Bypass -File C:\test.ps1" /sc once /st 00:00 /ru SYSTEM /f` |
| Check last Intune sync | `Get-ScheduledTask | Where-Object TaskName -like "*Sync*Intune*" | Get-ScheduledTaskInfo` |
| Force Intune sync | Start Company Portal > Sync OR restart IME service |
| Clear IME content cache | Stop IME → delete `C:\Program Files (x86)\Microsoft Intune Management Extension\Content` → Start IME |
| Check Intune events | `Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 50` |
| Test network to Intune | `Test-NetConnection -ComputerName manage.microsoft.com -Port 443` |
| Get device compliance state | `Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<name>'" \| Select-Object ComplianceState` |

---

## 🎓 Learning Pointers

- **Exit codes are the entire contract.** Intune Remediations only look at the PowerShell process exit code — not at error output, not at exceptions, not at the last command result. If your script throws a terminating exception and you haven't caught it, PowerShell exits with code 1 (which Intune treats as "with issues" from detection, or "failed" from remediation). Always wrap script bodies in `try/catch` and explicitly call `exit 0` or `exit 1`. See [Remediations in Intune - MS Docs](https://learn.microsoft.com/en-us/mem/intune/fundamentals/remediations).

- **32-bit vs 64-bit matters.** By default, Remediations run in 32-bit PowerShell. This affects registry access (`HKLM:\SOFTWARE` reads from `HKLM:\SOFTWARE\WOW6432Node` in 32-bit context) and file paths (`$env:ProgramFiles` resolves differently). Always enable "Run in 64-bit PowerShell host" unless you specifically need 32-bit. Test both contexts when debugging.

- **Output length is silently capped at 2048 characters.** There is no warning when output is truncated — the Intune portal simply shows the first 2048 chars. If your detection output is meant to carry diagnostic data, be surgical: write only the key result line, not verbose debug output. Reserve verbose logging for the IME log file written separately.

- **Licensing is the silent gotcha.** Remediations require **Microsoft Intune Plan 1** (part of EMS E3, M365 E3, M365 Business Premium, or standalone). If a device's primary user has only a Basic Mobility license or no Intune license, the Remediations section won't appear for that device at all — not an error, just no status. See [Intune license requirements](https://learn.microsoft.com/en-us/mem/intune/fundamentals/licenses).

- **Detection runs before every remediation, every cycle.** Remediations don't just run once — on every scheduled cycle, detection runs first. If your remediation fixes the issue but detection still returns exit 1, the remediation will run again (and again). Always update the detection script's logic so it returns exit 0 after a successful remediation, verifying the fix actually persisted.

- **IME processes scripts sequentially, not in parallel.** If a device has 20 remediation packages assigned, IME runs them one by one. A long-running or hanging detection script will block all subsequent remediations. Cap your scripts to fast checks (< 30 seconds for detection) and use the 30-minute timeout as a last resort only. See [IME troubleshooting guide](https://learn.microsoft.com/en-us/mem/intune/apps/intune-management-extension).
