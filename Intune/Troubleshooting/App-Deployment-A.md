# Intune App Deployment — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Win32 app deployment (`.intunewin` packaged apps)
- Microsoft Store for Business / WinGet-based apps (new Store integration)
- Line-of-business (LOB) apps (MSI, MSIX direct upload)
- Required vs. Available app assignment models
- Intune Management Extension (IME) — the engine behind Win32 delivery
- Detection rules, requirements rules, and return code handling
- App supersedence and dependency relationships
- Common failure patterns: stuck in pending, installation failed, reboot loop

**Does not cover:**
- macOS app deployment (separate runbook)
- Android/iOS app deployment
- Microsoft 365 Apps (Office) deployment (handled by Apps for Business/Enterprise profile type, different pipeline)

**Assumed role:** Intune Administrator or Global Administrator.

**Environment:** Windows 10 21H2+ or Windows 11, Entra ID Joined or Hybrid Joined, IME installed (auto-installed when first Win32 app is targeted at the device).

---

## How It Works

<details><summary>Full architecture</summary>

### App Types and Their Delivery Mechanisms

| App Type | Format | Delivery Engine | Detection |
|----------|--------|----------------|-----------|
| Win32 | `.intunewin` | Intune Management Extension (IME) | Detection rules |
| LOB (MSI) | `.msi` | Intune Management Extension | MSI product code |
| LOB (MSIX) | `.msix` / `.appxbundle` | Windows MSIX pipeline | Package ID |
| Microsoft Store (new) | WinGet | IME + WinGet | Package presence |
| Web links | URL | Company Portal (shortcut only) | N/A |

### Win32 App Delivery Pipeline (Most Complex — Focus Here)

```
Intune Admin Console
    │
    │ [Admin uploads .intunewin file]
    │ [Admin configures: Detection, Requirements, Dependencies, Supersedence]
    │ [Admin assigns to group (Required or Available)]
    │
    ▼
Azure Content Delivery Network (CDN)
    │ App content encrypted and stored
    │ Delivery Optimization (DO) may peer-cache content on LAN
    │
    ▼
Device Check-in (every 8 hours by default; or manual sync)
    │
    ▼
Intune Management Extension (IME)
    │ Running as: SYSTEM (for device-targeted apps)
    │             User context (for user-targeted apps)
    │
    ├─ [1] Receives app policy from Intune MDM channel
    ├─ [2] Checks Requirements rules (OS version, disk space, custom script)
    │           If requirements not met → app stays "Not applicable"
    ├─ [3] Runs Detection rules to check if app already installed
    │           If detected → marks as "Installed", skips download
    ├─ [4] Downloads .intunewin content from CDN (via Delivery Optimization)
    ├─ [5] Decrypts content locally (AES-256; key from Intune service)
    ├─ [6] Extracts and runs install command
    │           Runs in: SYSTEM context (device assignment) or User context (user assignment)
    ├─ [7] Waits for install command to exit; checks return code
    │           0 = success, 3010 = success+reboot, 1707 = success
    │           Other codes = configurable as success/failure/retry
    ├─ [8] Re-runs Detection rules to confirm installation
    │           If detected: marks "Installed"
    │           If not detected: marks "Installation failed"
    └─ [9] Reports status back to Intune service
```

### Intune Management Extension (IME)

IME (`IntuneManagementExtension.exe`) is the agent that handles Win32 apps, PowerShell scripts, and Proactive Remediations. It installs automatically when any of these features target the device.

**Key paths:**
- Binary: `C:\Program Files (x86)\Microsoft Intune Management Extension\`
- Logs: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\`
- Agent log: `IntuneManagementExtension.log`
- Win32 app log: `AgentExecutor.log`
- Delivery Optimization log: `%SystemRoot%\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Logs\`

**IME check-in triggers:**
- Every 8 hours (scheduled task: "Microsoft\Intune\Microsoft Intune Agent")
- On user logon
- On device enrollment
- Manual: via Company Portal → Sync, or Intune device page → Sync

### Detection Rules

Detection rules tell IME whether an app is already installed. If the rule returns "detected", IME skips installation. Misconfigured detection rules are the #1 cause of re-installation loops or "always failing" apps.

**Types:**
- **MSI product code** — checks Windows Installer database (reliable for MSI-based apps)
- **File detection** — checks for file/folder existence at a path (version-aware if configured)
- **Registry detection** — checks for registry key/value existence or value comparison
- **Custom script** — PowerShell script that exits with 0 (detected) or non-zero (not detected)

### App Assignment Types

| Assignment Type | Behaviour |
|----------------|-----------|
| **Required** (device group) | App installs silently without user action. Installed as SYSTEM. |
| **Required** (user group) | App installs at user logon via IME. User context. |
| **Available** (user group) | App appears in Company Portal. User initiates install. |
| **Uninstall** | App actively removed from targeted devices. |

</details>

---

## Dependency Stack

```
Intune Portal (App Policy)
        │
        ▼
Intune Service (cloud policy engine)
        │
        ▼
MDM Channel (WNS push notification → device polls)
        │
        ▼
Intune Management Extension (IME on device)
        │
        ├── Azure CDN (content download — requires HTTPS/443)
        │       └── Delivery Optimization (peer cache, BranchCache optional)
        │
        ├── Windows Installer / MSIX Runtime / WinGet
        │       └── App-specific prerequisites (VCRedist, .NET, etc.)
        │
        ├── Entra ID (device must be enrolled and compliant)
        │       └── Device identity certificate (issued at enrollment)
        │
        └── Detection Rules Engine
                └── Registry / Filesystem / MSI DB / PowerShell
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| App stuck in "Pending" indefinitely | IME not running; device not checking in | `Get-Service IntuneManagementExtension`; check IME log |
| App shows "Not applicable" | Requirements rule not met (OS, disk space, custom script failed) | Review requirements in Intune; check `IntuneManagementExtension.log` |
| App shows "Installation failed" (error 0x87D1041C) | Detection rule not detecting app after install | Fix detection rule; or fix install to actually install to detected path |
| App keeps reinstalling (loop) | Detection rule evaluating to "not detected" after install | Review detection rule match; test detection path manually on device |
| App shows "Installed" but user says it's not there | Detection rule too broad / false positive | Tighten detection rule (use version check, not just file existence) |
| 0x80070005 (Access Denied) during install | Installer requires elevation but running as user; or file locked | Ensure assignment is device-targeted (SYSTEM context); check file locks |
| 0x800704C7 (User cancelled) | UAC prompt appeared during SYSTEM install (shouldn't happen) | Check if installer spawns a child process in user context |
| Slow download / timeout | Large app; CDN throttled; Delivery Optimization misconfigured | Check DO logs; verify CDN endpoints reachable |
| App dependency not installed first | Dependencies not configured in Intune | Add dependency chain in app's Dependencies tab |
| Win32 app fails on HAADJ device | IME running but hybrid join not fully completed | Verify `dsregcmd /status`; check PRT |
| "0x8018002b" error | Device not properly enrolled (IME can't authenticate to Intune) | Re-enroll device; check enrollment cert |

---

## Validation Steps

**1. Confirm IME is installed and running**
```powershell
Get-Service -Name "IntuneManagementExtension" | Select Name, Status, StartType
Get-Process -Name "IntuneManagementExtension" -ErrorAction SilentlyContinue | Select Id, CPU, StartTime
```
_Good:_ Service Running, process active  
_Bad:_ Service not found — IME not installed; or Stopped — restart it

**2. Check device check-in timestamp**
```powershell
# Check scheduled task for IME
Get-ScheduledTask -TaskPath "\Microsoft\Intune\" | Select TaskName, State, @{N='LastRunTime';E={$_.LastRunInfo.LastRunTime}}
```
_Good:_ Tasks in Ready/Running state, LastRunTime within 8 hours  
_Bad:_ Tasks Disabled, or never run

**3. Verify app assignment in Intune (PowerShell via Graph)**
```powershell
Connect-MgGraph -Scopes "DeviceManagementApps.Read.All"
$apps = Get-MgDeviceAppManagementMobileApp -Filter "displayName eq '<AppName>'" 
$apps | Select Id, DisplayName, PublishingState
```

**4. Check IME log for app processing**
```powershell
# Last 200 lines of IME log
$logPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Get-Content $logPath -Tail 200 | Select-String -Pattern "error|fail|0x8|install|detect" -CaseSensitive:$false
```
_Good:_ Lines showing install success and detection confirmed  
_Bad:_ Error codes, "Detection failed", "Install failed"

**5. Check AgentExecutor log for Win32 specifics**
```powershell
$agentLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log"
Get-Content $agentLog -Tail 100 | Select-String -Pattern "error|exitcode|returncode|fail" -CaseSensitive:$false
```

**6. Test detection rule manually**
```powershell
# For file-based detection:
Test-Path "C:\Program Files\<AppName>\<executable>.exe"

# For registry-based detection:
Get-ItemProperty "HKLM:\SOFTWARE\<Publisher>\<AppName>" -ErrorAction SilentlyContinue

# For MSI product code detection:
Get-WmiObject -Class Win32_Product | Where-Object {$_.IdentifyingNumber -eq "{<ProductCode>}"}
# Note: Win32_Product is slow; prefer registry HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\" | 
    Get-ItemProperty | Where-Object {$_.PSChildName -eq "{<ProductCode>}"}
```

**7. Check disk space (common requirement rule failure)**
```powershell
Get-PSDrive C | Select Used, Free, @{N='FreeMB';E={[math]::Round($_.Free/1MB,0)}}
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — App Stuck in Pending

1. Confirm IME service is running (Validation Step 1)
2. If not running:
   ```powershell
   Start-Service "IntuneManagementExtension"
   # If it won't start, check Windows Event Log:
   Get-EventLog -LogName "Application" -Source "*Intune*" -Newest 20
   ```
3. Force IME to re-check assignments immediately:
   ```powershell
   # Restart IME (triggers immediate check-in)
   Restart-Service "IntuneManagementExtension"
   # Wait 2-3 minutes, then check Intune device page for updated status
   ```
4. Alternatively, trigger via Intune Portal: Devices → [Device] → Sync
5. Check if WNS (Windows Notification Service) is reachable — IME uses WNS for push notifications:
   ```powershell
   Test-NetConnection -ComputerName "client.wns.windows.com" -Port 443
   ```

### Phase 2 — Installation Failed (Diagnosing Error Codes)

1. Get the error code from Intune portal: Devices → [Device] → Apps → [App] → Installation status
2. Cross-reference with IME logs (Validation Steps 4 & 5)
3. Common codes and fixes:

| Code | Meaning | Fix |
|------|---------|-----|
| `0x87D1041C` | App not detected after install | Fix detection rule or installation path |
| `0x80070005` | Access denied | Switch to device assignment (SYSTEM context) |
| `0x80070002` | File not found | Installer path or dependency missing |
| `0x80070643` | MSI install failed | Check MSI log in `%TEMP%\`; fix MSI parameters |
| `0x800704C7` | Operation cancelled | Installer spawned interactive UI; repackage silently |
| `0xc0000135` | .NET missing | Add .NET as a dependency or prerequisite |
| `0x8024200D` | WU error during app install | Windows Update corruption; run `sfc /scannow` |
| `3010` | Success, reboot required | Normal — configure reboot behaviour in Intune |

4. For deeper MSI failures, check MSI-specific logs:
   ```powershell
   # Enable verbose MSI logging (add to install command in Intune):
   # msiexec /i "app.msi" /qn /l*v "C:\Temp\install.log"
   Get-Content "C:\Temp\install.log" -Tail 50 | Select-String "error|fail|return value 3"
   ```

### Phase 3 — Detection Rule Failures (Reinstall Loop)

1. Manually run the detection logic on the device (Validation Step 6)
2. If detection returns no result but app IS installed, the detection rule is misconfigured:
   - File check: verify exact path and filename (case-sensitive on some checks)
   - Registry check: verify key path is correct for 32-bit vs 64-bit apps (`SOFTWARE\WOW6432Node\` for 32-bit apps on 64-bit OS)
   - MSI: verify product code exactly (GUID format `{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}`)
3. Update the detection rule in Intune admin center (requires creating a new app version or editing the existing)
4. After fixing detection rule, force a sync to re-evaluate

### Phase 4 — Dependency and Supersedence Issues

1. Check app dependencies are configured correctly:
   - Intune Portal → Apps → [App] → Dependencies tab
   - Dependencies must be Win32 apps uploaded to the same tenant
   - IME installs dependencies **first**, in order, before the main app
2. Verify dependency app detection is working (it must install AND detect correctly)
3. For supersedence (newer version replacing older):
   - Supersedence only applies when the older app is detected on the device
   - IME first uninstalls the old app (using old app's uninstall command), then installs the new
   - If uninstall fails, the new app may not install — check old app's uninstall command works silently

### Phase 5 — Content Download Issues

1. Check CDN endpoints are reachable:
   ```powershell
   # Intune CDN endpoints
   $cdnHosts = @(
       "swda01-mscdn.azureedge.net",
       "swda02-mscdn.azureedge.net",
       "swdb01-mscdn.azureedge.net",
       "swdb02-mscdn.azureedge.net",
       "swdc01-mscdn.azureedge.net",
       "swdc02-mscdn.azureedge.net",
       "swdd01-mscdn.azureedge.net",
       "swdd02-mscdn.azureedge.net"
   )
   foreach ($host in $cdnHosts) {
       $r = Test-NetConnection -ComputerName $host -Port 443 -WarningAction SilentlyContinue
       Write-Host "$host : $($r.TcpTestSucceeded)" -ForegroundColor $(if($r.TcpTestSucceeded){"Green"}else{"Red"})
   }
   ```
2. Check Delivery Optimization settings:
   ```powershell
   Get-DeliveryOptimizationStatus | Select FileId, Status, BytesFromPeers, BytesFromCDN, TotalBytesDownloaded
   Get-DOConfig | Select DownloadMode, MinBackgroundQosKbps, MaxBackgroundQosKbps
   ```
3. If DO is blocking download (DownloadMode conflicts with network policy), override:
   ```powershell
   Set-DODownloadMode -DownloadMode 0  # 0 = HTTP only, no peer
   Restart-Service "DoSvc"
   ```

---

## Remediation Playbooks

<details><summary>Playbook 1 — Reinstall IME from scratch</summary>

```powershell
# Stop IME
Stop-Service "IntuneManagementExtension" -Force -ErrorAction SilentlyContinue

# Uninstall IME
$imeProduct = Get-WmiObject -Class Win32_Product | Where-Object {$_.Name -like "*Intune Management Extension*"}
if ($imeProduct) {
    $imeProduct.Uninstall() | Out-Null
    Write-Host "IME uninstalled." -ForegroundColor Yellow
}

# Delete residual files
Remove-Item "C:\Program Files (x86)\Microsoft Intune Management Extension\" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "C:\ProgramData\Microsoft\IntuneManagementExtension\" -Recurse -Force -ErrorAction SilentlyContinue

# Trigger re-enrollment of IME via MDM
# IME will reinstall automatically at next Intune policy check-in
# Force that check-in:
$session = New-CimSession
Invoke-CimMethod -CimSession $session -Namespace "root\ccm" -ClassName "SMS_Client" `
    -MethodName "TriggerSchedule" -Arguments @{sScheduleID="{00000000-0000-0000-0000-000000000021}"} `
    -ErrorAction SilentlyContinue
$session | Remove-CimSession

# Or simply: sign out and sign back into the device
Write-Host "IME removed. Will reinstall automatically at next Intune sync." -ForegroundColor Cyan
```

⚠️ This resets all locally cached IME state. All apps will re-evaluate on next sync.

</details>

<details><summary>Playbook 2 — Build a proper detection rule (file + version)</summary>

For apps where you need to detect a specific version:

```
Detection rule type: File
Path: C:\Program Files\<Publisher>\<AppName>\
File or folder name: <AppExecutable>.exe
Detection method: String (version)
Operator: Greater than or equal to
Value: <MinimumVersion>  (e.g. 2.5.0)
```

Equivalent PowerShell to test manually:
```powershell
$exePath = "C:\Program Files\<Publisher>\<AppName>\<AppExecutable>.exe"
if (Test-Path $exePath) {
    $version = (Get-Item $exePath).VersionInfo.FileVersion
    Write-Host "Detected version: $version"
    if ([version]$version -ge [version]"2.5.0") {
        Write-Host "Detection: PASS (version meets requirement)" -ForegroundColor Green
        exit 0
    } else {
        Write-Host "Detection: FAIL (version below minimum)" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Detection: FAIL (file not found)" -ForegroundColor Red
    exit 1
}
```

</details>

<details><summary>Playbook 3 — Package an app as .intunewin</summary>

```powershell
# Requires IntuneWinAppUtil.exe — download from:
# https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool

$utilPath   = "C:\Tools\IntuneWinAppUtil.exe"
$sourceDir  = "C:\AppSource\<AppName>"    # folder with installer + any other files
$installer  = "setup.exe"                 # main installer file (relative to sourceDir)
$outputDir  = "C:\AppPackages"

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

& $utilPath -c $sourceDir -s $installer -o $outputDir -q

Write-Host "Package created in: $outputDir" -ForegroundColor Green
# Upload the resulting .intunewin file to Intune Apps > Add > Windows app (Win32)
```

**Typical install command for EXE:**
```
setup.exe /S /silent /quiet
```
**Typical uninstall command:**
```
setup.exe /uninstall /S /silent /quiet
```
**Typical install command for MSI:**
```
msiexec /i "AppName.msi" /qn /norestart ALLUSERS=1
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS Collect Intune app deployment diagnostic evidence.
.NOTES Run on the affected Windows device as Administrator.
#>
param(
    [string]$AppNameFilter = "*",
    [string]$OutputPath = "$env:TEMP\IntuneApp-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
)

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# IME service status
Get-Service "IntuneManagementExtension" | Select * | Export-Csv "$OutputPath\ime-service.csv" -NoTypeInformation

# IME log (last 500 lines)
$logPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
if (Test-Path $logPath) { Get-Content $logPath -Tail 500 | Out-File "$OutputPath\ime-log.txt" }

# AgentExecutor log (last 500 lines)
$agentLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log"
if (Test-Path $agentLog) { Get-Content $agentLog -Tail 500 | Out-File "$OutputPath\agentexecutor-log.txt" }

# Installed apps (for cross-reference with detection rules)
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\" |
    Get-ItemProperty | Select DisplayName, DisplayVersion, Publisher, InstallDate, UninstallString |
    Where-Object {$_.DisplayName -like $AppNameFilter} |
    Export-Csv "$OutputPath\installed-apps-hklm.csv" -NoTypeInformation

Get-ChildItem "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\" |
    Get-ItemProperty | Select DisplayName, DisplayVersion, Publisher, InstallDate |
    Where-Object {$_.DisplayName -like $AppNameFilter} |
    Export-Csv "$OutputPath\installed-apps-hklm-wow.csv" -NoTypeInformation

# Scheduled tasks (IME tasks)
Get-ScheduledTask -TaskPath "\Microsoft\Intune\" | 
    Select TaskName, State, @{N='LastRun';E={$_.LastRunInfo.LastRunTime}} |
    Export-Csv "$OutputPath\ime-tasks.csv" -NoTypeInformation

# Delivery Optimization status
Get-DeliveryOptimizationStatus | Export-Csv "$OutputPath\do-status.csv" -NoTypeInformation

# Disk space
Get-PSDrive C | Select @{N='FreeMB';E={[math]::Round($_.Free/1MB,0)}}, @{N='UsedMB';E={[math]::Round($_.Used/1MB,0)}} |
    Export-Csv "$OutputPath\disk-space.csv" -NoTypeInformation

# System info
Get-ComputerInfo | Select WindowsVersion, OsVersion, CsName, TotalPhysicalMemory |
    Export-Csv "$OutputPath\system-info.csv" -NoTypeInformation

Write-Host "Evidence collected to: $OutputPath" -ForegroundColor Green
Invoke-Item $OutputPath
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check IME service | `Get-Service "IntuneManagementExtension"` |
| Restart IME | `Restart-Service "IntuneManagementExtension"` |
| View IME log (live) | `Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Wait -Tail 50` |
| View AgentExecutor log | `Get-Content "C:\ProgramData\Microsoft\...\Logs\AgentExecutor.log" -Tail 100` |
| Check installed apps (registry) | `Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\" \| Get-ItemProperty \| Select DisplayName,DisplayVersion` |
| Test file detection | `Test-Path "C:\Program Files\<App>\<exe>.exe"` |
| Test registry detection | `Get-ItemProperty "HKLM:\SOFTWARE\<Publisher>\<App>"` |
| Check disk free space | `Get-PSDrive C \| Select Free` |
| Force Intune sync (MDM) | `Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" \| Start-ScheduledTask` |
| Check Delivery Optimization mode | `Get-DOConfig \| Select DownloadMode` |
| List DO transfer status | `Get-DeliveryOptimizationStatus` |
| Get device enrollment info | `dsregcmd /status` |
| Check device compliance | `Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<name>'" \| Select ComplianceState,LastSyncDateTime` |

---

## 🎓 Learning Pointers

- **IME runs Win32 apps as SYSTEM for device assignments, user for user assignments.** This distinction matters when apps need to write to user profile paths (`%APPDATA%`, `%USERPROFILE%`) — they'll fail running as SYSTEM because there's no interactive user profile. For apps that must write to user paths, use user group assignment and ensure the app can run non-elevated. For machine-wide installs, always use device group assignment.

- **Detection rules are evaluated BEFORE and AFTER install — design them accordingly.** If your detection rule fires before the install completes (e.g., a partial file gets written), IME thinks the app is already installed and skips the rest. Use version-aware detection (file version, registry version string) rather than bare file existence for apps that update in-place. [MS Docs — Win32 App Detection](https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-add#step-4-detection-rules)

- **Return code 3010 is not a failure — configure it as "success with soft reboot."** Many MSI installers return 3010 when they complete successfully but need a reboot. Intune's default configuration treats 3010 as success. If you're seeing unexpected reboot prompts, check the reboot behaviour setting in the Win32 app configuration and consider setting `Maximum allowed run time (min)` to accommodate slow installs.

- **The IntuneWinAppUtil tool's output is encrypted — you cannot inspect the .intunewin contents without Intune decrypting them.** The encryption key is unique per upload and tied to the Intune service. This means you cannot "re-use" a .intunewin built for one tenant in another tenant without rebuilding. Always keep the original source files.

- **Dependency resolution happens in IME, not in Intune cloud.** IME downloads and installs all dependencies in order before the main app. If a dependency fails detection (i.e., its detection rule doesn't fire after install), IME will abort the main app install. Always test dependency app install and detection independently before chaining. [MS Docs — Win32 App Dependencies](https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-app-management#app-dependencies)

- **Company Portal is the user-facing view; Intune Admin Center is the admin view.** When users report "the app is not showing in Company Portal", check: (1) the app is assigned as Available (not Required) to a user group containing that user, (2) the user's device is enrolled and compliant, (3) the app's device requirements are met by the user's device. A Required app will never appear in Company Portal for the user to initiate — it installs silently. [MS Docs — App Assignment Types](https://learn.microsoft.com/en-us/mem/intune/apps/apps-deploy)
