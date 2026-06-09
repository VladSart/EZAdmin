# WMI Corruption — Reference Runbook (Mode A: Deep Dive)
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

**Applies to:** Windows 10/11, Windows Server 2016–2025  
**Role required:** Local Administrator (most steps); Domain Admin for remote WMI fixes  
**Does not cover:** WMI in non-Windows environments, WMI on Server Core without GUI tools

WMI (Windows Management Instrumentation) is the Microsoft implementation of WBEM (Web-Based Enterprise Management). Nearly every management tool — Intune, ConfigMgr, Defender, PowerShell's `Get-WmiObject`/`Get-CimInstance`, SCCM hardware inventory, and most third-party monitoring agents — relies on a functioning WMI repository. When WMI is corrupted, symptoms are often diffuse and misdirected: Intune sync fails, hardware inventory stops, scripts time out, and Event Viewer floods with spurious errors.

---

## How It Works

<details><summary>Full architecture</summary>

### WMI Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   Consumer Layer                         │
│  PowerShell  │  WBEM APIs  │  WMI Control  │  Agents   │
└──────────────┴─────────────┴───────────────┴───────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│              WMI Service (winmgmt)                       │
│  Manages namespace routing, security descriptors,        │
│  provider host processes, subscription routing           │
└─────────────────────────────────────────────────────────┘
                        │
          ┌─────────────┴──────────────┐
          ▼                            ▼
┌──────────────────┐        ┌──────────────────────────┐
│  WMI Repository  │        │  WMI Provider Hosts       │
│  (CIM database)  │        │  (WmiPrvSE.exe instances) │
│  OBJECTS.DATA    │        │  One per provider DLL      │
│  INDEX.BTR       │        │  Isolated by security ctx  │
│  MAPPING*.MAP    │        └──────────────────────────┘
└──────────────────┘
         │
         ▼
┌──────────────────────────────────────────────────────────┐
│           WMI Providers (DLLs registered in repo)         │
│  Win32_* classes  │  MSFT_* classes  │  Third-party      │
└──────────────────────────────────────────────────────────┘
```

### Repository Files
The WMI repository lives at:
```
%SystemRoot%\System32\wbem\Repository\
  OBJECTS.DATA   – The main CIM database (binary B-tree)
  INDEX.BTR      – Index into OBJECTS.DATA
  MAPPING1.MAP   – Transaction mapping file
  MAPPING2.MAP   – Transaction mapping file (alternate)
```

Corruption typically occurs in `OBJECTS.DATA` or `INDEX.BTR`. The repository is a transactional store — incomplete writes (power loss, crash during update) can leave it in an inconsistent state.

### Provider Host Isolation
Starting Windows Vista, WMI providers run in isolated `WmiPrvSE.exe` processes (WMI Provider Host). Each provider DLL runs in its own host, so a crashing provider does not bring down the WMI service — it just causes that provider's namespace queries to fail.

### Namespace Hierarchy
```
ROOT
├── CIMV2          (core OS classes — Win32_*, CIM_*)
│   └── Security
├── DEFAULT        (default namespace; legacy)
├── Microsoft
│   ├── Windows
│   │   ├── Defender
│   │   ├── Intune
│   │   └── StorageManagementService
│   └── PolicyPlatform
├── MSFT           (modern Microsoft classes)
└── WMI            (WMI infrastructure itself)
```

</details>

---

## Dependency Stack

```
Management Tools (PowerShell, Intune Agent, MEM, Defender)
        │
        ▼
WMI API / COM Interface
        │
        ▼
winmgmt Service (C:\Windows\System32\wbem\WinMgmt.exe)
        │
        ├──► WMI Repository (OBJECTS.DATA, INDEX.BTR)
        │       └── Integrity validated at service start
        │
        └──► WMI Provider Hosts (WmiPrvSE.exe)
                └── Load provider DLLs on demand
                        └── Registered in repository namespaces
```

**Critical dependencies:**
- DCOM / RPC service must be running (WMI is COM-based)
- Windows Management Instrumentation service (`winmgmt`) 
- WMI Performance Adapter (`wmiApSrv`) for performance counters
- Remote Procedure Call (`RpcSs`) — WMI will not start without it

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| `Get-CimInstance` returns 0x80041003 (Access Denied) | WMI namespace security descriptor broken | `Get-WmiObject -Namespace root\cimv2 -List` |
| `winmgmt` service fails to start | Repository corruption (OBJECTS.DATA) | Event ID 5612, 63 in System log |
| WmiPrvSE.exe consuming >10% CPU continuously | Provider DLL stuck in a loop or buggy third-party provider | `Get-WmiObject -Query "SELECT * FROM Win32_Process WHERE Name='WmiPrvSE.exe'"` |
| Intune sync stuck / MDM enrollment failing | ROOT\cimv2\MDM namespace missing or broken | `Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_DeviceManageability_Enrollment01` |
| `gwmi win32_computersystem` hangs indefinitely | winmgmt service deadlocked | `Test-NetConnection -ComputerName localhost -Port 135` (DCOM) |
| `0x80041010` (Invalid class) | Provider DLL unregistered or missing | `Get-CimClass -Namespace root\cimv2 -ClassName Win32_OperatingSystem` |
| Event ID 10 (WMI activity log) repeated | Broken WMI subscription | `Get-WMIObject -Namespace root\subscription -Class __EventFilter` |
| Hardware inventory stops in ConfigMgr/Intune | Win32_Product class broken (notoriously fragile) | `Get-WmiObject Win32_Product` (watch for timeout) |
| `HRESULT 0x80080005` (Server execution failed) | COM/DCOM misconfiguration | `Get-Service -Name RpcSs,DcomLaunch` |

---

## Validation Steps

**1. Check WMI service status**
```powershell
Get-Service winmgmt | Select-Object Name, Status, StartType
```
Expected: `Running`, `Automatic`  
Bad: `Stopped` or repeated stop/start cycling in Event Log

**2. Basic namespace query**
```powershell
Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber
```
Expected: Returns OS details within 5 seconds  
Bad: Hangs, returns error, or returns empty

**3. Repository integrity check**
```powershell
winmgmt /verifyrepository
```
Expected: `WMI repository is consistent`  
Bad: `WMI repository is inconsistent` → see Remediation Playbooks

**4. Provider host check**
```powershell
Get-Process WmiPrvSE | Select-Object Id, CPU, WorkingSet | Sort-Object CPU -Descending
```
Expected: Multiple short-lived instances, CPU < 5% each  
Bad: One instance consuming sustained high CPU (runaway provider)

**5. Check for broken event subscriptions (common cause of WmiPrvSE CPU)**
```powershell
Get-WMIObject -Namespace root\subscription -Class __EventFilter | Select-Object Name, Query
Get-WMIObject -Namespace root\subscription -Class __EventConsumer | Select-Object Name, __CLASS
Get-WMIObject -Namespace root\subscription -Class __FilterToConsumerBinding
```
Expected: Only Microsoft-signed filters (Defender, SCM, etc.)  
Bad: Unknown third-party entries or leftover malware persistence

**6. DCOM/RPC dependencies**
```powershell
Get-Service RpcSs, DcomLaunch, RpcEptMapper | Select-Object Name, Status
```
Expected: All `Running`  
Bad: Any stopped → WMI cannot function

**7. WMI event log check**
```powershell
Get-WinEvent -LogName Microsoft-Windows-WMI-Activity/Operational -MaxEvents 20 |
    Where-Object { $_.LevelDisplayName -ne 'Information' } |
    Select-Object TimeCreated, LevelDisplayName, Message
```
Expected: No errors or warnings in the last 24 hours  
Bad: Repeated Event ID 5612 (repository inconsistency), Event ID 63 (provider registration failure)

---

## Troubleshooting Steps (by phase)

### Phase 1: Determine Scope
1. Is the issue machine-wide (all WMI queries fail) or namespace-specific (only certain classes fail)?
   - Machine-wide → repository corruption or service crash
   - Namespace-specific → provider DLL issue or missing registration
2. Is the winmgmt service running? If not, check Event ID 7000/7009 in System log.
3. Is the issue reproducible or transient? Transient = provider timeout; consistent = corruption.

### Phase 2: Identify the Failing Provider
```powershell
# Find which WmiPrvSE.exe is consuming CPU (match PID to provider)
$highCPU = Get-Process WmiPrvSE | Sort-Object CPU -Descending | Select-Object -First 1
$highCPU.Id  # Get PID

# In Task Manager → Details, right-click WmiPrvSE.exe with matching PID → Go to service
# Or use:
Get-WmiObject -Class Win32_Service | Where-Object { $_.ProcessId -eq $highCPU.Id }
```

### Phase 3: Check System Event Log for WMI Errors
```powershell
Get-WinEvent -LogName System -MaxEvents 500 |
    Where-Object { $_.ProviderName -like '*WMI*' -or $_.Id -in @(5612, 63, 4096, 4097, 4098) } |
    Select-Object TimeCreated, Id, Message | Format-List
```

Key event IDs:
- **5612** — WMI repository detected as inconsistent
- **63** — Provider registration not found
- **4096** — WMI service started
- **4097** — WMI service stopped unexpectedly
- **4098** — Provider could not be loaded

### Phase 4: Salvage vs. Rebuild Decision
- **Salvage** (attempt first): `winmgmt /salvagerepository` — tries to compact and recover
- **Reset** (last resort): `winmgmt /resetrepository` — rebuilds from scratch, re-registers all providers

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Restart WMI service (safe, non-destructive)</summary>

Use when: winmgmt stopped or unresponsive; transient failure.

```powershell
Stop-Service -Name winmgmt -Force
Start-Service -Name winmgmt
Get-Service winmgmt

# Verify
winmgmt /verifyrepository
Get-CimInstance Win32_OperatingSystem | Select-Object Caption
```

**Rollback:** N/A — non-destructive. If service fails to start, proceed to Fix 3.

</details>

<details>
<summary>Fix 2 — Kill runaway WmiPrvSE.exe instance</summary>

Use when: Specific WmiPrvSE.exe consuming sustained CPU; other WMI queries still work.

```powershell
# Identify runaway PID
$target = Get-Process WmiPrvSE | Sort-Object CPU -Descending | Select-Object -First 1
Write-Host "Killing WmiPrvSE PID: $($target.Id)"

# Kill it — WMI service will restart a new host automatically
Stop-Process -Id $target.Id -Force

# Wait and verify
Start-Sleep -Seconds 5
Get-Process WmiPrvSE | Select-Object Id, CPU
```

**Rollback:** N/A — WMI automatically restarts the host. If problem recurs, identify the provider DLL (see Phase 2 troubleshooting).

</details>

<details>
<summary>Fix 3 — Salvage repository (safe recovery)</summary>

Use when: `winmgmt /verifyrepository` returns inconsistent; service crashes on start.

```powershell
# Stop WMI and dependent services
Stop-Service -Name winmgmt -Force -PassThru
Stop-Service -Name wscsvc -Force -ErrorAction SilentlyContinue  # Windows Security Center

# Attempt salvage
winmgmt /salvagerepository

# Restart
Start-Service -Name winmgmt

# Validate
winmgmt /verifyrepository
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, BuildNumber
```

**Expected output of salvage:** `WMI repository has been salvaged` or `WMI repository is consistent`  
If still inconsistent: proceed to Fix 4 (reset).

**Rollback:** If salvage makes things worse, proceed to Fix 4 (reset is the final state anyway).

</details>

<details>
<summary>Fix 4 — Reset WMI repository (destructive — last resort)</summary>

Use when: Salvage fails; repository is unrecoverably corrupt; `winmgmt` will not start.

⚠️ **Warning:** Reset wipes all WMI class registrations and re-registers from MOF files. Any third-party WMI providers (monitoring agents, AV tools) will need re-registration. Intune/ConfigMgr may require a device re-sync.

```powershell
#Requires -RunAsAdministrator

Write-Host "Stopping dependent services..." -ForegroundColor Yellow
$servicesToStop = @('winmgmt', 'wscsvc', 'iphlpsvc', 'SharedAccess')
foreach ($svc in $servicesToStop) {
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 5

Write-Host "Resetting WMI repository..." -ForegroundColor Red
winmgmt /resetrepository

Write-Host "Restarting WMI service..." -ForegroundColor Yellow
Start-Service -Name winmgmt
Start-Sleep -Seconds 10

Write-Host "Verifying repository..." -ForegroundColor Yellow
winmgmt /verifyrepository

Write-Host "Re-registering MOF files..." -ForegroundColor Yellow
$mofDir = "$env:SystemRoot\System32\wbem"
Get-ChildItem "$mofDir\*.mof" | ForEach-Object {
    Write-Host "  Compiling: $($_.Name)"
    mofcomp $_.FullName 2>&1 | Out-Null
}

Write-Host "Basic validation..." -ForegroundColor Yellow
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
Write-Host "OK: $($os.Caption) $($os.BuildNumber)" -ForegroundColor Green

Write-Host "Done. Recommend rebooting." -ForegroundColor Cyan
```

**Rollback:** If reset makes things worse (extremely rare), last resort is in-place Windows repair:
```powershell
# In-place repair (preserves data, reinstalls system files)
# DISM /Online /Cleanup-Image /RestoreHealth
# sfc /scannow
```

</details>

<details>
<summary>Fix 5 — Re-register a specific provider DLL</summary>

Use when: One WMI namespace/class fails but others work; Event ID 63 shows specific provider.

```powershell
# Example: re-register the WBEM core provider
$wbemPath = "$env:SystemRoot\System32\wbem"

# Re-register a specific DLL (replace with actual DLL from Event 63)
$providerDll = "<ProviderDLL.dll>"  # e.g. "wmiprvsd.dll"
regsvr32 /s "$wbemPath\$providerDll"

# Re-compile associated MOF
$mofFile = "<provider.mof>"  # e.g. "wmidcprv.mof"
mofcomp "$wbemPath\$mofFile"

# Restart WMI
Restart-Service winmgmt -Force
winmgmt /verifyrepository
```

</details>

<details>
<summary>Fix 6 — Remove malicious/broken WMI subscriptions</summary>

Use when: WmiPrvSE.exe CPU, suspicious Event ID 10 in WMI-Activity log, or known malware.

⚠️ Caution: Deleting legitimate Microsoft subscriptions can break Defender/SCM. Identify unknown entries only.

```powershell
# List all subscriptions
$filters = Get-WMIObject -Namespace root\subscription -Class __EventFilter
$consumers = Get-WMIObject -Namespace root\subscription -Class __EventConsumer
$bindings = Get-WMIObject -Namespace root\subscription -Class __FilterToConsumerBinding

# Review — legitimate ones are from Microsoft, SCM, Defender, ConfigMgr
$filters | Select-Object Name, Query | Format-Table -AutoSize
$consumers | Select-Object Name, __CLASS | Format-Table -AutoSize

# Remove a specific suspicious filter (confirm identity first)
$suspiciousFilter = $filters | Where-Object { $_.Name -eq "<SuspiciousFilterName>" }
$suspiciousFilter | Remove-WmiObject -Confirm

# Remove associated binding and consumer
$bindings | Where-Object { $_.Filter -like "*<SuspiciousFilterName>*" } | Remove-WmiObject -Confirm
$consumers | Where-Object { $_.Name -eq "<SuspiciousConsumerName>" } | Remove-WmiObject -Confirm

Restart-Service winmgmt
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects WMI health evidence for escalation
.NOTES     Run as Administrator; outputs to C:\Temp\WMI-Evidence-<hostname>.txt
#>
$outFile = "C:\Temp\WMI-Evidence-$env:COMPUTERNAME-$(Get-Date -Format yyyyMMdd-HHmm).txt"
New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null

{
    "=== WMI Evidence Pack — $env:COMPUTERNAME — $(Get-Date) ==="

    "`n--- WMI Service Status ---"
    Get-Service winmgmt, wscsvc, RpcSs, DcomLaunch, RpcEptMapper | Format-Table -AutoSize

    "`n--- Repository Verification ---"
    & winmgmt /verifyrepository

    "`n--- WmiPrvSE Processes ---"
    Get-Process WmiPrvSE -ErrorAction SilentlyContinue | Format-Table Id, CPU, WorkingSet -AutoSize

    "`n--- WMI Activity Log (last 30 errors/warnings) ---"
    Get-WinEvent -LogName Microsoft-Windows-WMI-Activity/Operational -MaxEvents 100 -ErrorAction SilentlyContinue |
        Where-Object { $_.LevelDisplayName -ne 'Information' } |
        Select-Object -First 30 TimeCreated, Id, Message | Format-List

    "`n--- System Log WMI Events (last 20) ---"
    Get-WinEvent -LogName System -MaxEvents 500 -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -in @(5612,63,4096,4097,4098,7000,7009) } |
        Select-Object -First 20 TimeCreated, Id, Message | Format-List

    "`n--- Basic WMI Query Test ---"
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        "PASS: Win32_OperatingSystem — $($os.Caption) $($os.BuildNumber)"
    } catch {
        "FAIL: Win32_OperatingSystem — $_"
    }

    "`n--- WMI Subscriptions ---"
    Get-WMIObject -Namespace root\subscription -Class __EventFilter -ErrorAction SilentlyContinue |
        Select-Object Name, Query | Format-Table -AutoSize

    "`n--- Repository Files ---"
    Get-ChildItem "$env:SystemRoot\System32\wbem\Repository" -ErrorAction SilentlyContinue |
        Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize

} | ForEach-Object { $_ } | Out-File $outFile -Encoding UTF8

Write-Host "Evidence collected: $outFile" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Check WMI repository integrity | `winmgmt /verifyrepository` |
| Salvage repository (safe recovery) | `winmgmt /salvagerepository` |
| Reset repository (last resort) | `winmgmt /resetrepository` |
| Restart WMI service | `Restart-Service winmgmt -Force` |
| Basic WMI query | `Get-CimInstance Win32_OperatingSystem` |
| List all WMI namespaces | `Get-CimInstance -Namespace root -ClassName __Namespace` |
| Check WmiPrvSE CPU | `Get-Process WmiPrvSE \| Sort CPU -Descending` |
| Compile a MOF file | `mofcomp <file>.mof` |
| Register a provider DLL | `regsvr32 /s <path>\<provider>.dll` |
| View WMI activity log | `Get-WinEvent -LogName Microsoft-Windows-WMI-Activity/Operational -MaxEvents 50` |
| List WMI event subscriptions | `Get-WMIObject -Namespace root\subscription -Class __EventFilter` |
| Check DCOM/RPC dependencies | `Get-Service RpcSs, DcomLaunch, RpcEptMapper` |
| Test remote WMI | `Get-CimInstance -ComputerName <PC> -ClassName Win32_OperatingSystem` |
| Find WMI errors in System log | `Get-WinEvent -LogName System \| Where { $_.Id -in @(5612,63,4097) }` |

---

## 🎓 Learning Pointers

- **Why WMI corrupts in the first place:** The repository is a transactional B-tree database. Abrupt power loss, forced reboots during WMI writes (e.g. patch installs), or buggy provider DLLs writing invalid data are the top causes. Anti-virus real-time protection scanning `OBJECTS.DATA` mid-write is a historically documented trigger. [MS: WMI Repository Corruption](https://docs.microsoft.com/en-us/troubleshoot/windows-server/system-management-components/wmi-repository-corruption)

- **`Win32_Product` is notoriously bad:** Querying `Win32_Product` triggers an MSI consistency check on every installed product, which can corrupt installations and takes minutes. Use `Get-Package` or HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall instead. [Raymond Chen: Win32_Product is evil](https://devblogs.microsoft.com/oldnewthing/20120711-00/?p=7173)

- **WMI subscriptions are a common malware persistence vector:** Attackers register `__EventFilter` / `__EventConsumer` bindings to run code at system events (logon, startup). Tools like Autoruns (Sysinternals) and the `Get-WMIObject -Namespace root\subscription` query are your detection methods. [MITRE ATT&CK T1546.003](https://attack.mitre.org/techniques/T1546/003/)

- **Provider host isolation means partial failure is normal:** A single `WmiPrvSE.exe` crash does not bring down WMI. If only some classes fail, the problem is the provider DLL, not the repository. Check Event ID 4625 in the WMI-Activity log for the specific namespace and class that failed. [MS WMI Provider Hosting](https://docs.microsoft.com/en-us/windows/win32/wmisdk/provider-hosting-and-security)

- **Intune and WMI:** The Intune Management Extension relies heavily on `root\cimv2\mdm` and related namespaces. WMI corruption is one of the top causes of "Intune sync not working" tickets. After a WMI reset, trigger a manual Intune sync: `Start-Process "ms-device-enrollment:?mode=mdm"` or restart the IntuneManagementExtension service.

- **SFC and DISM before WMI reset:** If WMI appears broken system-wide, run `sfc /scannow` and `DISM /Online /Cleanup-Image /RestoreHealth` first — they may repair the WMI binaries without a full repository reset. Reserve `resetrepository` for confirmed repository corruption confirmed by `verifyrepository`. [MS: Fix Windows corruption errors](https://support.microsoft.com/en-us/topic/use-the-system-file-checker-tool-to-repair-missing-or-corrupted-system-files-79aa86cb-ca52-166a-92a3-966e85d4094e)
