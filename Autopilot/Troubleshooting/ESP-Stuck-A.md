# Enrollment Status Page (ESP) Stuck — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers the Windows Autopilot Enrollment Status Page (ESP) getting stuck or timing out during device provisioning. It applies to:

- Autopilot user-driven mode (Azure AD joined and Hybrid Azure AD joined)
- Autopilot self-deploying mode
- Pre-provisioning (Technician Phase / White Glove)
- ESP Device Setup phase and ESP User Setup phase

**Not covered:** Traditional MDM enrollment (non-Autopilot), Windows Server enrollment, co-management workload transitions during ESP.

**Assumptions:**
- Tenant has Intune license (Microsoft 365 Business Premium, E3+EMS, or standalone Intune)
- ESP profile is assigned to the device or "All Devices"
- Device is registered in Autopilot (hardware hash uploaded)
- Network meets Autopilot requirements (see Dependency Stack)

---

## How It Works

<details><summary>Full architecture</summary>

### ESP Execution Flow

The ESP is a Windows component (`EnrollmentStatusTracking`) that runs as part of the Windows OOBE (Out-Of-Box Experience) and also during the first user sign-in. It tracks the completion of MDM policies, apps, and certificates before handing off to the desktop.

```
Windows Boot / OOBE
      │
      ├─[Device ESP Phase]──────────────────────────────────────────────┐
      │   Runs as SYSTEM before any user logs in                        │
      │   Tracks:                                                        │
      │     - Device configuration profiles                             │
      │     - Required device apps (Win32, LOB, MSfB)                   │
      │     - Security Baseline / SCEP certificates                     │
      │     - PowerShell scripts (system context)                       │
      │   Timeout: configurable (default 60 min)                        │
      └─────────────────────────────────────────────────────────────────┘
      │
      └─[User ESP Phase]────────────────────────────────────────────────┐
          Runs after user signs in (AAD credentials at OOBE)           │
          Tracks:                                                        │
            - User-targeted configuration profiles                      │
            - User-targeted apps                                         │
            - Office 365 / M365 Apps installation                       │
          Timeout: configurable (default 60 min)                        │
          └───────────────────────────────────────────────────────────  │
```

### ESP State Machine

ESP uses the `EnrollmentStatusTracking` CSP internally. Its state is stored in:
- `HKLM:\SOFTWARE\Microsoft\Enrollments\<EnrollmentGUID>\FirstSync` — overall ESP state
- `HKLM:\SOFTWARE\Microsoft\Windows\Autopilot\EnrollmentStatusTracking\` — app/policy tracking
- `HKLM:\SOFTWARE\Microsoft\Windows\Autopilot\DeviceContext\` — device-phase tracking

The ESP page reads these values and shows "Installing apps" / "Configuring your device" progress based on:
1. A list of **required** apps (set via Intune targeting + ESP profile configuration)
2. A list of **blocking** policies (Compliance, Configuration, Certificates)

If `BlockInStatusPage = true` for an app in the ESP profile, that app must complete before ESP exits. If the app fails to install, ESP shows "Something went wrong" or stays on "Installing apps" until timeout.

### App Installation Sequence During ESP

```
Intune Management Extension (IME) starts as SYSTEM
      │
      ├── Win32 App detection (required, device-targeted)
      │       ↓
      │   Download from Azure CDN (*.do.dsp.mp.microsoft.com, *.dl.delivery.mp.microsoft.com)
      │       ↓
      │   Execute install command (as SYSTEM unless "user context")
      │       ↓
      │   Run detection rule → report success/failure to Intune
      │
      ├── LOB apps (.msi, .msix) via WinGet/Intune LOB pipeline
      │
      └── Office 365 / M365 Apps (Click-to-Run installer)
              Heaviest install — 2-4 GB download, 15-45 min typical
```

### Hybrid Join Complexity

In Hybrid AAD Join mode, there is an additional dependency:
- The device must join the on-premises AD domain during Device ESP
- This requires a **Domain Join connector** (running on-prem) and line-of-sight to a domain controller
- The connector creates a computer account in AD → Entra Connect syncs it → Autopilot profile targets it
- This entire chain must complete within the ESP timeout

```
Device (ESP Device Phase)
    │ HTTPS
    ▼
Intune Service
    │ Sends domain join config blob
    ▼
Intune Connector (on-prem Windows Server)
    │ LDAP
    ▼
Active Directory DC
    │ Entra Connect sync (every 30 min by default)
    ▼
Entra ID (device shows as Hybrid Joined)
```

</details>

---

## Dependency Stack

```
Entra ID / Autopilot Service
    └── Intune (MDM enrollment, policy/app delivery)
        └── Intune Management Extension (IME) — Win32 app engine
            └── Windows Update / Delivery Optimization — app downloads
                └── Network (HTTPS/443 — see URL list below)
                    └── DNS (resolves *.microsoft.com, *.windowsupdate.com, etc.)
                        └── Time (device clock — tokens expire if clock is wrong)
                            └── [Hybrid only] Domain Join Connector (on-prem server)
                                └── [Hybrid only] On-prem AD Domain Controller
                                    └── [Hybrid only] Entra Connect (sync timing)

Key URLs that MUST be reachable during ESP:
  *.manage.microsoft.com
  *.microsoftonline.com
  *.windows.net
  *.do.dsp.mp.microsoft.com       ← Delivery Optimization (app CDN)
  *.dl.delivery.mp.microsoft.com  ← app download CDN
  *.windowsupdate.com
  login.microsoftonline.com
  enterpriseregistration.windows.net
  device.login.microsoftonline.com
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| ESP stuck "Installing apps" > 30 min | Win32 app install failing silently, large app (Office) on slow link | IME log, app install detection rule |
| ESP stuck "Configuring your device" | Policy CSP failing to apply, SCEP cert enrollment failure | MDM event log, SCEP URLs reachable |
| ESP shows "Something went wrong" + error code | App install failure, network timeout, detection failure | IME log, specific error code |
| ESP times out with error 0x800705b4 | Generic timeout — ESP hit the configured timeout limit | Increase ESP timeout or fix underlying app |
| ESP timeout 0x80070774 | Account provisioning failure (Hybrid Join domain join failed) | Connector log, AD computer object |
| ESP stuck after user login (User phase) | User-targeted app failing, Office 365 install issue | IME log, Office CDN reachable |
| Device reboots and ESP restarts from scratch | Device reboot policy during ESP, SCEP triggers reboot | Autopilot event log, policy reboot settings |
| Pre-provisioning (White Glove) fails at technician phase | Same causes as Device ESP + TPM attestation | TPM, network, IME log |
| ESP completes but desktop shows policies not applied | ESP did not block on required policies (config issue) | ESP profile settings, policy assignment |
| Office 365 install percent stuck at same number | Delivery Optimization / CDN throttling, proxy blocking | DO client event log, network trace |

---

## Validation Steps

### 1. Check ESP event log during or after enrollment

```powershell
# These logs are available on the device after ESP (even if it fails)
$espLogs = @(
    "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/AutoPilot",
    "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Diagnostics",
    "Microsoft-Windows-Provisioning-Diagnostics-Provider/AutoPilot"
)

foreach ($log in $espLogs) {
    Write-Host "`n=== $log ===" -ForegroundColor Cyan
    Get-WinEvent -LogName $log -MaxEvents 30 -ErrorAction SilentlyContinue |
        Where-Object { $_.LevelDisplayName -in "Error","Warning","Information" } |
        Select-Object TimeCreated, LevelDisplayName, Id, Message |
        Format-List
}
```

**Good:** No errors or only informational events showing normal progression.
**Bad:** Error events, especially around "SubcategoryStatus" or "TimeoutExpired."

---

### 2. Check Intune Management Extension (IME) log

```powershell
# IME log is the single most useful file for ESP app install failures
$imeLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
if (Test-Path $imeLog) {
    # Show last 200 lines — look for errors, timeouts, app GUIDs
    Get-Content $imeLog -Tail 200 |
        Where-Object { $_ -match "error|fail|timeout|exception|0x8" -or $_ -match "installing|detection|result" } |
        Select-Object -Last 50
} else {
    Write-Warning "IME log not found — IME may not have started"
}
```

**Good:** Lines showing app downloads, installs, and successful detection rules.
**Bad:** Lines with error codes (0x800xxxxx), "detection failed," "installation failed," "timed out."

---

### 3. Check MDM enrollment event log

```powershell
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" `
    -MaxEvents 50 -ErrorAction SilentlyContinue |
    Where-Object { $_.LevelDisplayName -in "Error","Warning" } |
    Select-Object TimeCreated, LevelDisplayName, Id, Message |
    Format-List
```

**Good:** Enrollment events showing successful policy application.
**Bad:** CSP errors, certificate enrollment failures, MDM authority errors.

---

### 4. Check ESP registry state

```powershell
# Overall ESP state
$espBase = "HKLM:\SOFTWARE\Microsoft\Windows\Autopilot\EnrollmentStatusTracking"
if (Test-Path $espBase) {
    Get-ChildItem $espBase -Recurse | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        [PSCustomObject]@{ Path = $_.PSPath -replace ".*EnrollmentStatusTracking\\",""; Properties = ($props | Out-String) }
    } | Select-Object Path, Properties | Format-List
}

# Device context
$devCtx = "HKLM:\SOFTWARE\Microsoft\Windows\Autopilot\DeviceContext"
if (Test-Path $devCtx) {
    Get-ItemProperty $devCtx
}
```

---

### 5. Check if required apps are properly targeted

```powershell
# Check which apps IME is tracking for ESP
$imeAppsKey = "HKLM:\SOFTWARE\Microsoft\EnterpriseDesktopAppManagement\S-0-0-00-0000000000-0000000000-000000000-0000\MSI"
# For Win32 apps:
$win32Key = "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps"
if (Test-Path $win32Key) {
    Get-ChildItem $win32Key | ForEach-Object {
        Get-ChildItem $_.PSPath | ForEach-Object {
            $appProps = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                Path         = $_.PSPath -split "\\" | Select-Object -Last 3 | Join-String -Separator "\"
                Status       = $appProps.ResultCode
                ErrorCode    = $appProps.ErrorCode
            }
        }
    } | Sort-Object Status | Format-Table -AutoSize
}
```

---

### 6. Validate network connectivity for ESP URLs

```powershell
# Run on a device stuck at ESP (via WinPE or after ESP fails with a cmd window)
$espUrls = @(
    "manage.microsoft.com",
    "enterpriseregistration.windows.net",
    "login.microsoftonline.com",
    "portal.manage.microsoft.com",
    "dl.delivery.mp.microsoft.com",
    "dm3p.wns.windows.com",
    "config.office.com"
)

foreach ($url in $espUrls) {
    $result = Test-NetConnection -ComputerName $url -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{
        URL       = $url
        Reachable = $result.TcpTestSucceeded
        LatencyMs = $result.PingReplyDetails.RoundtripTime
    }
} | Format-Table -AutoSize
```

---

## Troubleshooting Steps (by phase)

### Phase 1: App Install Failures (most common cause)

1. Open IME log: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log`
2. Search for the failing app by GUID (cross-reference with Intune portal → Apps → App name → Properties)
3. Common patterns:
   - `Error installing app: 0x80070002` — source file not found (CDN issue, corrupted package)
   - `Detection rule returned false after install` — install succeeded but detection rule is wrong
   - `Timeout waiting for install` — app takes >60 min (increase IME timeout or fix app)
   - `Application not assigned to device` — app is user-targeted but ESP is in device phase

4. For Office 365 specifically: check `C:\Windows\Temp\` and `C:\Windows\Logs\` for Click-to-Run logs
5. Test CDN reachability: `Test-NetConnection -ComputerName dl.delivery.mp.microsoft.com -Port 443`

### Phase 2: Certificate / SCEP Failures

1. Check SCEP connector health in Intune Admin Center → Tenant Admin → Connectors
2. Check MDM event log for SCEP-specific errors (Event IDs 32, 33, 105, 106)
3. Test NDES URL reachability from the device
4. Check device certificate store: `certlm.msc` → Personal → look for the expected cert

### Phase 3: Hybrid Join Domain Join Failure

1. Check Intune Connector for AD service is running on-prem: `Get-Service -Name IntuneConnectorService`
2. Check Connector logs: `C:\ProgramData\Microsoft\Windows\Intune MDM Agent\Logs\`
3. Verify the connector account has permissions to create computer objects in the target OU
4. Check DNS: device must resolve the on-prem AD domain during ESP
5. Check that Entra Connect delta sync interval (30 min default) isn't causing timeout

### Phase 4: Timeout Configuration

1. In Intune Admin Center → Devices → Enrollment → Enrollment Status Page → Profile
2. Current timeout setting (default 60 min — may be too short for complex app sets)
3. Increase timeout to 90-120 min for complex deployments
4. Consider removing low-priority apps from ESP blocking to speed up the experience

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Skip ESP on a stuck device (emergency recovery)</summary>

**When to use:** Device stuck at ESP during production deployment, need to get device to desktop quickly. This does NOT fix the underlying issue.

⚠️ Only use if you understand that policies/apps will be applied post-desktop silently. Do not use in secure environments where ESP is a compliance requirement.

```powershell
# Option A: From within an ESP error screen with a "Collect diagnostics" link
# Press Ctrl+Shift+F3 to enter Audit Mode (may not work in all scenarios)

# Option B: Reset ESP via registry after ESP page is visible
# Open Task Manager → File → Run → cmd.exe (if accessible)

# In cmd.exe during ESP (run as SYSTEM via task manager new task):
REG ADD "HKLM\SOFTWARE\Microsoft\Windows\Autopilot\EnrollmentStatusTracking\Deploy\Tracking" /v "DeploymentState" /t REG_DWORD /d 3 /f
# DeploymentState 3 = success — forces ESP to think it's done

# Restart the ESP shell to pick up the change:
taskkill /f /im WWAHost.exe
# OOBE will restart and may complete normally
```

**Rollback:** Re-enroll device or wipe and re-Autopilot if state is inconsistent.

</details>

<details>
<summary>Fix 2 — Remove a blocking app from ESP profile</summary>

**When to use:** A specific app is reliably causing ESP to time out. Remove it from ESP blocking while you fix the app.

In Intune Admin Center:
1. Devices → Enrollment → Enrollment Status Page
2. Select the profile → Properties → Edit
3. Under "Block device use until these required apps are installed," remove the problematic app
4. Save → assign to devices
5. On the stuck device: perform a reset and re-enroll, or use Fix 1 to unstick the current device

```powershell
# After unblocking, verify no ESP-blocking apps are creating issues
# Check current ESP app tracking on an enrolled device:
$trackingKey = "HKLM:\SOFTWARE\Microsoft\Windows\Autopilot\EnrollmentStatusTracking\Device\WSFB"
if (Test-Path $trackingKey) {
    Get-ChildItem $trackingKey | ForEach-Object {
        Get-ItemProperty $_.PSPath | Select-Object PSChildName, *Status*, *Error*
    } | Format-Table -AutoSize
}
```

</details>

<details>
<summary>Fix 3 — Fix a broken Win32 app detection rule</summary>

**When to use:** App installs successfully but ESP doesn't recognize it — detection rule is wrong.

```powershell
# Step 1: Find the app GUID in IME log
$imeLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Select-String -Path $imeLog -Pattern "detection|installed|failed" | Select-Object -Last 30

# Step 2: Check what Intune detection rule expects vs. reality
# Example: File detection
$expectedPath = "C:\Program Files\<AppName>\<executable>.exe"  # From Intune detection rule
Test-Path $expectedPath

# Example: Registry detection
$expectedKey = "HKLM:\SOFTWARE\<Vendor>\<AppName>"
$expectedValue = "Version"
(Get-ItemProperty $expectedKey -Name $expectedValue -ErrorAction SilentlyContinue).$expectedValue
```

Fix the detection rule in Intune (Apps → select app → Properties → Detection rules) to match actual install location/registry key/version.

</details>

<details>
<summary>Fix 4 — Fix Hybrid Join connector timeout during ESP</summary>

**When to use:** ESP times out with 0x80070774 or "Account provisioning failed" in Hybrid Join mode.

```powershell
# On the Intune Connector server (on-prem)
# Step 1: Check connector service
Get-Service -Name "IntuneConnectorService" -ErrorAction SilentlyContinue |
    Select-Object Status, StartType

# Step 2: Restart connector if stopped/errored
Restart-Service "IntuneConnectorService" -Force
Start-Sleep -Seconds 10
Get-Service "IntuneConnectorService" | Select-Object Status

# Step 3: Check connector event log
Get-WinEvent -LogName "ODJ Connector Service" -MaxEvents 30 -ErrorAction SilentlyContinue |
    Where-Object { $_.LevelDisplayName -in "Error","Warning" } |
    Select-Object TimeCreated, LevelDisplayName, Message |
    Format-List

# Step 4: Verify connector account permissions
# Account must have: Create Computer Objects, Delete Computer Objects in target OU
# Check: Active Directory Users and Computers → target OU → Delegate Control

# Step 5: Check DNS from connector server (must resolve device domain + Intune endpoints)
Resolve-DnsName "manage.microsoft.com" -ErrorAction SilentlyContinue
Resolve-DnsName "<your-on-prem-domain.local>" -ErrorAction SilentlyContinue
```

**Long-term fix:** Increase ESP timeout to 90+ min to accommodate Entra Connect sync delay (up to 30 min by default). Or configure Entra Connect delta sync to run every 5 min for Autopilot deployments.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects ESP/Autopilot diagnostic evidence for escalation
.NOTES     Run on the device after ESP failure — ideally from admin cmd during OOBE or post-reset
           Can also be run post-enrollment if ESP failed and device made it to desktop
#>

$reportPath = "$env:TEMP\ESP_Evidence_$(Get-Date -Format yyyyMMdd_HHmmss)"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

# 1. Autopilot/ESP event logs
$logs = @(
    "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/AutoPilot",
    "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Diagnostics",
    "Microsoft-Windows-Provisioning-Diagnostics-Provider/AutoPilot",
    "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin"
)
foreach ($log in $logs) {
    $safeName = $log -replace "/","-" -replace "\\","-"
    Get-WinEvent -LogName $log -MaxEvents 100 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, LevelDisplayName, Id, Message |
        Export-Csv "$reportPath\EventLog_$safeName.csv" -NoTypeInformation
}

# 2. IME log (last 1000 lines)
$imeLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
if (Test-Path $imeLog) {
    Get-Content $imeLog -Tail 1000 | Out-File "$reportPath\IME_Log_Tail1000.log"
}

# 3. Autopilot registry state
reg export "HKLM\SOFTWARE\Microsoft\Windows\Autopilot" "$reportPath\Autopilot_Registry.reg" /y 2>&1 | Out-Null

# 4. Device join state
dsregcmd /status 2>&1 | Out-File "$reportPath\DsregCmd.txt"
dsregcmd /debug  2>&1 | Out-File "$reportPath\DsregCmd_Debug.txt"

# 5. Network connectivity check
$espUrls = @("manage.microsoft.com","login.microsoftonline.com","dl.delivery.mp.microsoft.com","config.office.com")
$netResults = foreach ($url in $espUrls) {
    $r = Test-NetConnection -ComputerName $url -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{ URL = $url; TCP443 = $r.TcpTestSucceeded; RTT = $r.PingReplyDetails.RoundtripTime }
}
$netResults | Export-Csv "$reportPath\Network_ESP_URLs.csv" -NoTypeInformation

# 6. Installed apps snapshot (for detection rule verification)
Get-WmiObject -Class Win32_Product -ErrorAction SilentlyContinue |
    Select-Object Name, Version, InstallDate |
    Sort-Object Name |
    Export-Csv "$reportPath\Installed_Apps.csv" -NoTypeInformation

# 7. Win32 app registry state
$win32Base = "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps"
if (Test-Path $win32Base) {
    Get-ChildItem $win32Base -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            [PSCustomObject]@{ Key = $_.PSPath -split "\\" | Select-Object -Last 4 | Join-String -Separator "\"; ResultCode = $p.ResultCode; ErrorCode = $p.ErrorCode }
        } |
        Export-Csv "$reportPath\Win32App_Registry.csv" -NoTypeInformation
}

# 8. System info
Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsArchitecture, CsModel, CsManufacturer |
    Export-Csv "$reportPath\SystemInfo.csv" -NoTypeInformation

Write-Host "`n[OK] Evidence at: $reportPath" -ForegroundColor Green
Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "[OK] Zipped: $reportPath.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|-------------------|
| View ESP/Autopilot event log | `Get-WinEvent -LogName "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/AutoPilot"` |
| View IME (app install) log | `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log` |
| Check device join state | `dsregcmd /status` |
| Check Autopilot registry | `reg query "HKLM\SOFTWARE\Microsoft\Windows\Autopilot"` |
| Check Win32 app state registry | `HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps\` |
| Test ESP network URLs | `Test-NetConnection -ComputerName manage.microsoft.com -Port 443` |
| Check Hybrid Join connector | Connector server → `Get-Service IntuneConnectorService` |
| Connector logs (Hybrid) | `C:\ProgramData\Microsoft\Windows\Intune MDM Agent\Logs\` |
| Force ESP to skip (emergency) | Set `DeploymentState = 3` in ESP tracking reg key |
| Increase ESP timeout | Intune → Enrollment → ESP Profile → Edit → Timeout |
| Force sync on post-ESP device | IME tray → Sync or `Invoke-MDMEnrollmentSync.ps1` |
| Check cert enrollment (SCEP) | `certlm.msc` → Personal → Certificates |
| Open MDM diagnostic log | `mdmdiagnosticstool.exe -out C:\Temp\MDMDiag` |
| Check Intune connector status | Intune Admin Center → Tenant Admin → Connectors → Intune Connector for AD |

---

## 🎓 Learning Pointers

- **ESP apps must be device-targeted, not user-targeted, for Device Phase.** A common misconfiguration is assigning a Win32 app to a user group and expecting ESP to install it during the Device Phase (before any user logs in). ESP Device Phase only sees device-targeted apps. Verify assignment targeting in Intune → Apps → App → Properties → Assignments. See: [ESP configuration guidance](https://learn.microsoft.com/en-us/mem/intune/enrollment/windows-enrollment-status)

- **Detection rules are the most common silent failure point.** An app can install correctly but if the detection rule checks for a file path, registry key, or MSI product code that doesn't match exactly (wrong bitness, wrong path on 64-bit OS, wrong GUID), IME reports failure and ESP loops or times out. Always test detection rules manually using PowerShell before deploying apps to production. The IME log shows exactly what the detection rule returned.

- **Office 365 / M365 Apps is the heaviest ESP blocker.** The Click-to-Run installer is 2-4 GB and can take 45-90 min on a slow link. On a brand-new device connected via WiFi at a remote site, this alone can exceed the default 60-min timeout. Either increase timeout, use an ODT (Office Deployment Tool) cached installer, or don't block ESP on Office completion. Reference: [Office ESP considerations](https://learn.microsoft.com/en-us/mem/intune/apps/apps-add-office365)

- **Hybrid Join ESP has a timing dependency on Entra Connect.** The device needs to be visible in Entra ID as Hybrid Joined before ESP can complete certain phases. Entra Connect delta sync runs every 30 min by default — if the connector creates the AD computer object at minute 1, and sync runs at minute 29, ESP has a 28-min gap where the device doesn't exist in Entra ID. Configure Entra Connect to run delta sync every 5 min during heavy Autopilot provisioning windows, or use the `Start-ADSyncSyncCycle -PolicyType Delta` command. See: [Hybrid Autopilot guide](https://learn.microsoft.com/en-us/mem/autopilot/windows-autopilot-hybrid)

- **The MDM Diagnostic Tool is your best friend for post-failure analysis.** Running `mdmdiagnosticstool.exe -area Autopilot;DeviceEnrollment -cab C:\Temp\MDMDiag.cab` collects all relevant logs in one step: ESP registry, MDM event log, IME log, device join state, and policy CSP state. This is what Microsoft Support will ask for in a support case. Teach engineers to run this immediately after an ESP failure before rebooting the device. Reference: [MDM Diagnostics](https://learn.microsoft.com/en-us/windows/client-management/mdm-collect-logs)

- **Pre-provisioning (White Glove) ESP failures require the device to be reset.** Unlike standard ESP where you can sometimes unstick the device, a failed Technician Phase in White Glove mode leaves the device in a non-recoverable pre-provisioning state. The only remedy is Windows Reset (keeping nothing) and re-imaging. Build your Autopilot profiles to succeed at White Glove or test them thoroughly before rolling out to the provisioning team. Track White Glove status under Intune → Devices → Device → Enrollment date / status.
