# WMI Corruption & Repository Issues — Hotfix Runbook (Mode B: Ops)
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

Run on affected machine (admin PowerShell):

```powershell
# 1. Quick WMI test
Get-WmiObject Win32_OperatingSystem | Select-Object Caption, Version

# 2. Check WMI service status
Get-Service winmgmt | Select-Object Status, StartType

# 3. Check WMI repository consistency
winmgmt /verifyrepository

# 4. Check WMI error count in event log (last hour)
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='WinMgmt'; StartTime=(Get-Date).AddHours(-1)} -ErrorAction SilentlyContinue |
    Group-Object LevelDisplayName | Select-Object Name, Count

# 5. Check disk space (low disk can cause WMI corruption)
Get-PSDrive C | Select-Object Used, Free
```

**Interpretation:**

| Result | Meaning | Action |
|---|---|---|
| `Get-WmiObject` returns error or hangs | WMI broken or service unresponsive | Restart WMI service first (Fix 1), then test again |
| `winmgmt /verifyrepository` returns `WMI repository is inconsistent` | Repository corrupt | Rebuild repository (Fix 2) |
| `winmgmt /verifyrepository` returns `WMI repository is consistent` but WMI still fails | Provider or namespace issue, not repository | Check specific WMI provider (Fix 3) |
| `winmgmt` service `Stopped` or `StartType: Disabled` | Service not running | Start service: `Start-Service winmgmt` |
| Many `Error` events from `WinMgmt` in last hour | Ongoing provider crash loop | Identify crashing provider (Fix 3) |
| C: drive < 5 GB free | Disk pressure may have caused corruption | Free up disk before rebuilding repository |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Windows Management Instrumentation (WMI)
    │
    ├── WMI Service (winmgmt) — must be Running
    │       └── Depends on: DCOM Server Process Launcher (DcomLaunch)
    │                       RPC Endpoint Mapper (RpcEptMapper)
    │                       Remote Procedure Call (RPC) service
    │
    ├── WMI Repository
    │       Path: C:\Windows\System32\wbem\Repository\
    │       ├── OBJECTS.DATA  — main object store
    │       ├── INDEX.BTR     — index B-tree
    │       └── MAPPING*.MAP  — mapping files
    │
    ├── WMI Providers
    │       Path: C:\Windows\System32\wbem\*.dll, *.mof
    │       └── Each provider registered in repository
    │           Corruption of one provider ≠ full WMI failure
    │
    └── Consumers of WMI
            ├── Intune / MDM agent (reads compliance data)
            ├── SCCM/ConfigMgr agent
            ├── Defender (hardware/OS info)
            ├── System Center agents
            ├── PowerShell (Get-WmiObject, Get-CimInstance)
            └── Any application using COM/DCOM to query WMI
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Is WMI service running?**
```powershell
Get-Service winmgmt
```
- **Good:** `Status: Running`
- **Bad:** `Stopped` → `Start-Service winmgmt` → re-test

**Step 2 — Can you query basic WMI namespace?**
```powershell
Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object Caption, LastBootUpTime
```
- **Good:** Returns OS info
- **Bad:** `Access denied`, `RPC server unavailable`, or hangs → proceed to Fix 1

**Step 3 — Verify repository integrity**
```powershell
winmgmt /verifyrepository
```
- **Good:** `WMI repository is consistent`
- **Bad:** `WMI repository is inconsistent` → Fix 2

**Step 4 — Identify if a specific namespace/class fails**
```powershell
# Test a specific class (example: Intune-relevant)
Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_DeviceStatus -ErrorAction Stop
```
- **Bad:** Only this namespace fails → provider-level issue, not full WMI corruption → Fix 3

**Step 5 — Check for provider host crashes**
```powershell
Get-WinEvent -FilterHashtable @{
    LogName   = 'Application'
    ProviderName = 'WMI'
    StartTime = (Get-Date).AddHours(-4)
} -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, LevelDisplayName, Message |
    Format-Table -AutoSize -Wrap
```
- Look for `Provider ... failed to initialize` or `Provider host process...terminated`

---

## Common Fix Paths

<details><summary>Fix 1 — Restart WMI service (safe, non-destructive — always try first)</summary>

```powershell
# Stop dependent services first, then restart WMI
Stop-Service -Name winmgmt -Force
Start-Service -Name winmgmt

# Verify
Get-Service winmgmt
Get-WmiObject Win32_OperatingSystem | Select-Object Caption
```

**Note:** Restarting `winmgmt` may briefly interrupt monitoring agents (SCCM, Defender, Intune) — they will reconnect automatically within a few minutes.

**Rollback:** N/A — service restart is non-destructive.

</details>

<details><summary>Fix 2 — Reset WMI repository (repository is inconsistent)</summary>

> ⚠️ This rebuilds the WMI repository from scratch. WMI provider registrations are re-read from MOF files. Custom/third-party providers may need to be re-registered. Do NOT do this if `winmgmt /verifyrepository` says consistent.

```powershell
# Step 1: Stop WMI
Stop-Service -Name winmgmt -Force

# Step 2: Rename existing (corrupted) repository as backup
$repoPath = "$env:SystemRoot\System32\wbem\Repository"
$backupPath = "$env:SystemRoot\System32\wbem\Repository_backup_$(Get-Date -Format yyyyMMdd_HHmm)"
Rename-Item -Path $repoPath -NewName (Split-Path $backupPath -Leaf)

# Step 3: Restart WMI — Windows will auto-create a new repository
Start-Service -Name winmgmt

# Step 4: Wait for rebuild (30-60 seconds), then test
Start-Sleep -Seconds 30
winmgmt /verifyrepository
Get-WmiObject Win32_OperatingSystem | Select-Object Caption

# Step 5: Re-register all WMI providers from MOF files
$wbemPath = "$env:SystemRoot\System32\wbem"
Get-ChildItem -Path $wbemPath -Filter "*.mof" | ForEach-Object {
    Write-Host "Registering: $($_.Name)"
    mofcomp $_.FullName 2>&1 | Out-Null
}
```

**Rollback:**
```powershell
# If new repository is worse — restore backup
Stop-Service -Name winmgmt -Force
Remove-Item "$env:SystemRoot\System32\wbem\Repository" -Recurse -Force
Rename-Item -Path $backupPath -NewName "Repository"
Start-Service -Name winmgmt
```

</details>

<details><summary>Fix 3 — Re-register a specific WMI provider (provider-level failure)</summary>

```powershell
# Identify the failing provider from the event log error message
# Common failing providers: MDM, Defender, SCCM, HyperV

# Re-register all MOF files in the WBEM folder (safe to run repeatedly)
$wbemPath = "$env:SystemRoot\System32\wbem"
Get-ChildItem -Path $wbemPath -Filter "*.mof" -ErrorAction SilentlyContinue | ForEach-Object {
    $result = & mofcomp "$($_.FullName)" 2>&1
    if ($result -match "error") {
        Write-Warning "MOF error: $($_.Name) — $result"
    }
}

# Re-register WMI DLLs
Get-ChildItem -Path $wbemPath -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
    regsvr32 /s $_.FullName
}

# Restart WMI
Restart-Service winmgmt

# Test specific namespace after
Get-CimInstance -ClassName Win32_Service | Select-Object -First 3
```

</details>

<details><summary>Fix 4 — WMI consumer subscription using excessive CPU (malware indicator)</summary>

> ⚠️ Malware commonly uses WMI subscriptions for persistence. Before removing, capture evidence.

```powershell
# Check for WMI event subscriptions (often used by malware for persistence)
# List all WMI subscriptions
Get-WMIObject -Namespace root\subscription -Class __EventFilter | Select-Object Name, Query
Get-WMIObject -Namespace root\subscription -Class __EventConsumer | Select-Object Name, CommandLineTemplate, ScriptText
Get-WMIObject -Namespace root\subscription -Class __FilterToConsumerBinding | Select-Object Filter, Consumer

# If suspicious subscription found — document then remove:
# Get-WMIObject -Namespace root\subscription -Class __EventFilter | Where-Object { $_.Name -eq "<SuspiciousName>" } | Remove-WmiObject
# Get-WMIObject -Namespace root\subscription -Class __EventConsumer | Where-Object { $_.Name -eq "<SuspiciousName>" } | Remove-WmiObject
# Get-WMIObject -Namespace root\subscription -Class __FilterToConsumerBinding | Where-Object { ... } | Remove-WmiObject
```

> ⚠️ If you find unexpected WMI subscriptions you did not create, **escalate to security** before removing — this may be an active compromise. Capture output before removal.

</details>

---

## Escalation Evidence

```
=== WMI ESCALATION TICKET ===
Date/Time (UTC):
Hostname:
OS Version:
Issue Description:

--- WMI Service Status ---
[Paste: Get-Service winmgmt | Select-Object Status, StartType]

--- Repository Verification ---
[Paste: winmgmt /verifyrepository output]

--- Basic WMI Query Test ---
[Paste: Get-WmiObject Win32_OperatingSystem output or error]

--- WMI Event Log Errors (last 4 hours) ---
[Paste: Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='WMI'; StartTime=(Get-Date).AddHours(-4)}]

--- WMI Subscriptions (for security review if suspicious) ---
[Paste: Get-WMIObject -Namespace root\subscription -Class __EventFilter | Select-Object Name, Query]

--- Disk Space ---
[Paste: Get-PSDrive C | Select-Object Used, Free]

--- System Info ---
[Paste: Get-ComputerInfo | Select-Object CsDNSHostName, OsName, OsVersion]

Escalation contact: Microsoft Support or internal security team
```

---

## 🎓 Learning Pointers

- **WMI is the plumbing that Intune, Defender, and SCCM all depend on.** When WMI is broken, compliance reporting fails silently — the device appears stale in MEM/Intune, Defender reports no data, and SCCM hardware inventory stops updating. Always check WMI health when troubleshooting "device not reporting" issues. See [WMI overview](https://learn.microsoft.com/en-us/windows/win32/wmisdk/wmi-start-page).

- **"Repository inconsistent" is rare on modern Windows.** Abrupt power loss, failed updates, or disk errors are the most common causes. Before rebuilding, check `chkdsk C: /f` output and Windows Update history for a failed update that may have corrupted the repository.

- **`Get-CimInstance` is preferred over `Get-WmiObject`.** `Get-CimInstance` uses WS-Man/DCOM and is faster and more reliable on modern systems. `Get-WmiObject` is deprecated in PowerShell 7+. Use `Get-CimInstance -ClassName Win32_X` instead of `Get-WmiObject Win32_X` in new scripts.

- **WMI subscriptions are a favourite malware persistence mechanism.** They survive reboots and run as SYSTEM without appearing as scheduled tasks or services. Review `root\subscription` namespace regularly and alert on unexpected subscriptions. Microsoft Defender can detect known malicious WMI subscriptions — check ASR rule "Block persistence through WMI event subscription". Reference: [WMI-based attacks](https://learn.microsoft.com/en-us/windows/security/threat-protection/intelligence/fileless-threats).

- **MOF files are the source of truth for WMI provider registration.** When rebuilding the repository, `mofcomp *.mof` re-registers all providers. If a third-party application (monitoring agent, AV) uses WMI, their provider may not re-register automatically — reinstall the application or manually run the vendor's MOF registration step after a repository rebuild.
