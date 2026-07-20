# Intune Driver Management — Reference Runbook (Mode A: Deep Dive)
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

Covers **Intune Driver Management** (Windows Driver Update Management / WDfB Drivers), which is distinct from Windows Update for Business ring policies. This runbook focuses on:

- Driver Update Management (DUM) policies in Intune
- Windows Driver Update for Business (WDfB) — the cloud-managed driver approval workflow
- Driver conflicts causing BSOD, hardware failure, or policy non-compliance
- Manual driver suppression via Windows Update settings or Group Policy CSP

**Not covered:** Legacy WSUS-based driver approval, ConfigMgr driver packages, or OEM driver deployment via Win32 apps (see App-Deployment runbooks). Also not covered: **Windows Autopatch's own automatically-managed, per-ring driver policy** — on an Autopatch-registered device, Autopatch creates and manages its own driver update policy independently of the manual DUM model described here, and the two can silently conflict if both are scoped to the same device. See `Autopatch-A.md` § "Driver & Firmware Track — Ring Orchestration vs. Manual DUM Approval" before assuming this manual-approval model applies to an Autopatch-managed fleet.

**Assumes:**
- Devices are Azure AD Joined or Hybrid Joined, enrolled in Intune
- Windows 10 21H2+ or Windows 11 (Driver Update Management requires 21H2+)
- Caller has Intune Administrator or Policy and Profile Manager role

---

## How It Works

<details><summary>Full architecture</summary>

### Windows Driver Update for Business (WDfB Drivers)

WDfB Drivers extends Windows Update for Business to give admins control over driver updates distributed through Windows Update, without needing WSUS or ConfigMgr.

**How the pipeline works:**

```
OEM/IHV submits driver → Microsoft WHQL signs → Windows Update catalog
        ↓
Intune DUM policy "pauses" automatic driver updates
        ↓
Admin reviews pending drivers in Intune portal
        ↓
Admin approves/pauses/declines specific drivers
        ↓
Approved drivers pushed to devices via WU service
        ↓
Device installs; reports status back via DMClient
```

**Policy types in Intune:**

| Policy Type | Purpose |
|-------------|---------|
| Driver Update Management (DUM) | Define approval scope — all drivers, specific types |
| Driver approval workflow | Per-driver approve/pause/decline in portal |
| Windows Update rings | Control timing of approved drivers (deadline/deferral) |
| OMA-URI / CSP (Update/ExcludeWUDriversInQualityUpdate) | Block WU-delivered drivers entirely |

**Key registry hive (device-side):**
```
HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate
  - ExcludeWUDriversInQualityUpdate = 1  (block WU drivers via policy)
  - WUServer / WUStatusServer           (WSUS remnants — common conflict source)
```

**DMClient reports driver update status under:**
```
HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update
```

**Diagnostic event channels:**
- `Microsoft-Windows-WindowsUpdateClient/Operational` — driver install events
- `Microsoft-Windows-Bits-Client/Operational` — download issues
- `Microsoft-Windows-Kernel-PnP/Configuration` — PnP driver binding events

### Driver Conflict Architecture

When a bad driver causes issues, Windows layers apply in order:

```
BIOS/UEFI firmware
    └── Windows Boot Manager
        └── Boot-critical drivers (filter drivers, storage)
            └── PnP Manager
                └── Device-specific drivers
                    └── User-mode driver frameworks (UMDF)
```

A BSOD at boot indicates a **boot-critical driver** failed. A BSOD after login typically points to a **PnP or UMDF driver**.

**Driver update sources (precedence, highest first):**
1. ConfigMgr (if co-managed, Update workload on SCCM)
2. Intune DUM policy — approved drivers
3. Windows Update (automatic) — if not blocked
4. WSUS (if WUServer registry key is still present — legacy remnant)
5. Windows Store / DCH drivers

</details>

---

## Dependency Stack

```
Microsoft Update Service (WU)
    │
    ├── Intune DUM Policy (MEM portal approval)
    │       └── Windows Update Client (wuauserv)
    │               └── Download Manager (BITS)
    │                       └── Driver Package (.inf)
    │                               └── PnP Manager (pnpmgr)
    │                                       └── Device (hardware)
    │
    └── Windows Update for Business rings
            └── Deferral / Deadline settings
                    └── Device compliance state
```

**What must be true for driver deployment:**
1. Device reaches Windows Update endpoints (*.update.microsoft.com)
2. DUM policy assigned to device/group
3. Driver approved in Intune portal (if DUM in "manual approval" mode)
4. No conflicting WSUS registry keys overriding WU source
5. Device has sufficient disk space (drivers typically 50–800 MB)
6. PnP Manager not blocked by WDAC policy from loading the driver INF

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Driver listed as "Pending" in Intune for >48h | Not approved in DUM portal OR device not checking in | Intune portal → Devices → Driver updates → review approval status |
| BSOD after driver update | Boot-critical driver conflict | WinRE → `dism /image:C:\ /get-drivers` to enumerate installed drivers |
| Driver rolls back immediately after install | Conflicting older driver from WSUS remnant or OEM tool | `reg query HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` |
| Device shows compliant but driver not installed | WU blocked by `ExcludeWUDriversInQualityUpdate` CSP | Check policy in Intune Update ring or OMA-URI |
| "Not applicable" devices in DUM report | OS version below 21H2, or non-Windows device in scope | Check device OS version filter |
| PnP devices showing yellow bang (!) after Intune enroll | WDAC blocking unsigned/custom INF | Check WDAC audit log for 3089/3076 events |
| Specific hardware fails after domain join / Hybrid join | Conflicting GPO pushing old WSUS-based drivers | `gpresult /h gpreport.html` — look for Update policies |
| Driver deployment stuck at 0% | BITS service stopped or proxy blocking WU CDN | `Get-Service BITS`, test connectivity to `*.delivery.mp.microsoft.com` |
| "Error 0x80070002" in WU event log | Driver package missing from WU catalog (expired) | Admin must decline the driver in DUM and let Microsoft republish |

---

## Validation Steps

**1. Verify DUM policy assignment**
```powershell
# Run on device - check policy applied
Get-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Property | ForEach-Object {
        [PSCustomObject]@{
            Name  = $_
            Value = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate').$_
        }
    }
```
**Good:** `ExcludeWUDriversInQualityUpdate` absent or `0`
**Bad:** `ExcludeWUDriversInQualityUpdate = 1` means WU drivers blocked entirely. WSUS keys present = conflict.

**2. Check driver update pending count**
```powershell
# Trigger WU scan and show pending updates including drivers
$UpdateSession = New-Object -ComObject Microsoft.Update.Session
$UpdateSearcher = $UpdateSession.CreateUpdateSearcher()
$SearchResult   = $UpdateSearcher.Search("IsInstalled=0 AND Type='Driver'")
$SearchResult.Updates | Select-Object Title, MsrcSeverity, IsDownloaded | Format-Table -AutoSize
```
**Good:** Returns empty or only expected drivers
**Bad:** Unexpected drivers pending — check DUM approval status in portal

**3. Confirm device last checked in to WU**
```powershell
# Last WU contact
(Get-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Detect').GetValue('LastSuccessTime')
```
**Good:** Within last 24 hours
**Bad:** More than 48 hours ago — investigate wuauserv or network

**4. Check for WSUS remnant (common post-migration issue)**
```powershell
$wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$wuAU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
@('WUServer','WUStatusServer') | ForEach-Object {
    $val = (Get-ItemProperty $wu -ErrorAction SilentlyContinue).$_
    if ($val) { Write-Warning "WSUS remnant: $_ = $val" }
}
$useWsus = (Get-ItemProperty $wuAU -ErrorAction SilentlyContinue).UseWUServer
if ($useWsus -eq 1) { Write-Warning "UseWUServer = 1 — device pointing to WSUS" }
```
**Good:** No output (keys absent or 0)
**Bad:** Any WARN output — WSUS keys redirect WU traffic away from Microsoft Update

**5. Validate PnP device state**
```powershell
# Devices with errors
Get-PnpDevice | Where-Object { $_.Status -ne 'OK' } |
    Select-Object FriendlyName, Class, Status, Problem, InstanceId |
    Sort-Object Status | Format-Table -AutoSize
```
**Good:** Empty or only known/acceptable devices
**Bad:** Status `Error` or `Unknown` — check Problem code against [PNP error codes](https://learn.microsoft.com/windows-hardware/drivers/install/device-manager-error-messages)

---

## Troubleshooting Steps (by phase)

### Phase 1: Policy Layer — Verify DUM is reaching the device

1. In Intune portal: **Devices → Windows → Driver updates** — confirm policy status is "Success" for the device
2. On device: `dsregcmd /status` — confirm `MDMEnrolled: YES` and `WamDefaultSet: YES`
3. Check MDM diagnostic log: `MDMDiagnosticsTool.exe -area DeviceEnrollment -cab C:\Temp\mdm.cab`
4. In extracted cab, review `DeviceManagement-Enterprise-Diagnostics-Provider-Admin.evtx` for policy application errors

### Phase 2: Update Source — Confirm WU pointing to Microsoft (not WSUS)

1. Run WSUS remnant check (Validation Step 4 above)
2. If WSUS keys found, determine if from GPO or leftover config:
   ```powershell
   gpresult /scope computer /r | Select-String -Pattern 'Windows Update|WSUS' -Context 2
   ```
3. If no GPO is setting them, clean up manually (see Remediation Playbook 2)
4. Force WU scan: `UsoClient.exe StartScan`

### Phase 3: Driver Approval — Confirm driver is approved in DUM

1. Intune portal → **Devices → Driver updates → select your policy → Drivers**
2. Check each driver status: Approved / Paused / Declined / Needs review
3. Drivers in "Needs review" will **not** deploy until approved
4. After approval, device must check in — use `UsoClient.exe StartScan` to accelerate

### Phase 4: Installation Failure — Diagnose why install failed

1. Event Viewer: **Applications and Services → Microsoft → Windows → WindowsUpdateClient → Operational**
   - Event 20 = Install failed; Event 19 = Install success
   - Event 20 includes error code — cross-reference [WU error codes](https://learn.microsoft.com/windows/deployment/update/windows-update-error-reference)
2. Check `C:\Windows\Logs\WindowsUpdate\WindowsUpdate.log` (requires `Get-WindowsUpdateLog` to decode ETL)
3. Check device restart pending: `(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing').RebootPending`

### Phase 5: BSOD / Regression — Recover from bad driver

1. Boot to WinRE (hold Shift + Restart, or via Autopilot reset if severe)
2. Use `dism /image:C:\ /get-drivers /all` to list all installed drivers
3. Identify recently changed driver from `dism` output (Published Date)
4. Roll back: `pnputil /delete-driver <oem#.inf> /uninstall /reboot`
5. In Intune DUM portal: **Decline** the offending driver to prevent re-push

---

## Remediation Playbooks

<details><summary>Playbook 1 — Approve pending drivers in bulk (portal + Graph)</summary>

**Use when:** Multiple drivers stuck in "Needs review" and bulk approval is required.

**Via Portal:**
1. Intune → Devices → Driver updates → your policy → Drivers tab
2. Filter Status = "Needs review"
3. Select all → Approve

**Via Graph API (for automation):**
```powershell
# Connect to Graph
Connect-MgGraph -Scopes 'WindowsUpdates.ReadWrite.All'

# List all pending driver approvals
$catalogEntries = Get-MgWindowsUpdatesCatalogEntry -Filter "offerDateTime ge $((Get-Date).AddDays(-7).ToString('o'))"
$catalogEntries | Where-Object { $_.'@odata.type' -like '*driver*' } |
    Select-Object Id, DisplayName, Version, ReleaseDateTime
```

**Note:** Approving a driver is irreversible via Graph — use portal for single-driver decisions.

</details>

<details><summary>Playbook 2 — Remove WSUS remnant registry keys</summary>

**Use when:** Device is pointing to a defunct/removed WSUS server, blocking WU drivers.

⚠️ **Destructive — test on pilot devices first. Remove only if no WSUS in environment.**

```powershell
<#
.SYNOPSIS  Remove legacy WSUS registry configuration that blocks Windows Update
.NOTES     Run as Administrator. Verify no active WSUS environment before running.
#>
#Requires -RunAsAdministrator

$wuPath   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$wuAUPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'

Write-Host "Current WU policy registry state:" -ForegroundColor Cyan
Get-Item $wuPath -ErrorAction SilentlyContinue | Format-List

# Remove WSUS server pointers
foreach ($key in @('WUServer','WUStatusServer')) {
    if (Get-ItemProperty $wuPath -Name $key -ErrorAction SilentlyContinue) {
        Remove-ItemProperty $wuPath -Name $key -Force
        Write-Host "Removed: $key" -ForegroundColor Yellow
    }
}

# Disable UseWUServer flag
if ((Get-ItemProperty $wuAUPath -ErrorAction SilentlyContinue).UseWUServer -eq 1) {
    Set-ItemProperty $wuAUPath -Name 'UseWUServer' -Value 0 -Type DWord
    Write-Host "Set UseWUServer = 0" -ForegroundColor Yellow
}

# Restart Windows Update service
Restart-Service wuauserv -Force
Write-Host "Windows Update service restarted." -ForegroundColor Green

# Trigger fresh scan
Start-Process 'UsoClient.exe' -ArgumentList 'StartScan' -NoNewWindow
Write-Host "WU scan initiated. Check Windows Update in 5 minutes." -ForegroundColor Green
```

**Rollback:** Re-add keys with correct WSUS server URL if environment still uses WSUS for other update types.

</details>

<details><summary>Playbook 3 — Exclude a specific driver class from WU via CSP</summary>

**Use when:** A specific driver class (e.g., display adapters) keeps receiving problematic updates and you want to block all WU drivers of that class.

**Option A: Block all WU drivers entirely (nuclear option)**

In Intune → Update rings → Windows Update ring → Hardware driver updates:
- Set **"Allow Windows drivers"** to **Block**

This sets `ExcludeWUDriversInQualityUpdate = 1` via CSP.

**Option B: Use DUM policy to decline specific drivers**

More surgical — decline the specific driver in the DUM policy while keeping other driver updates active.

**Option C: Use OMA-URI for specific device guard rule (advanced)**

```
OMA-URI: ./Vendor/MSFT/Policy/Config/Update/ExcludeWUDriversInQualityUpdate
Data type: Integer
Value: 1
```

**Rollback:** Set the Update ring setting back to "Allow" or change OMA-URI value to 0.

</details>

<details><summary>Playbook 4 — Recover from BSOD caused by driver (offline)</summary>

**Use when:** Device BSODs on boot after driver update, cannot boot to Windows.

```powershell
# Run from WinRE Command Prompt (Shift+F10 during Autopilot, or WinRE via USB)

# Step 1: Identify Windows partition
diskpart
    list vol
    exit

# Step 2: List third-party drivers on the offline image (replace C: with correct drive letter)
dism /image:C:\ /get-drivers /all | findstr /I "oem provider published"

# Step 3: Identify the recently-added driver by Published Date and remove it
# Replace oemXX.inf with the offending driver's filename from Step 2 output
pnputil /delete-driver oem42.inf /uninstall

# Step 4: Attempt reboot
wpeutil reboot
```

**After recovery in Windows:**
1. In Intune portal: **Decline** the offending driver in the DUM policy
2. Document driver name and version for ticket escalation
3. Consider enrolling in **Windows Insider Release Preview** channel to catch driver regressions earlier in your environment

**Rollback:** If step 3 fails or makes things worse, restore from a WinRE checkpoint or use Autopilot reset.

</details>

<details><summary>Playbook 5 — Force driver check-in without waiting for WU cycle</summary>

**Use when:** Driver is approved in DUM but device hasn't picked it up yet.

```powershell
#Requires -RunAsAdministrator

Write-Host "Forcing Windows Update scan and driver check..." -ForegroundColor Cyan

# Option 1: UsoClient (modern, works on Win10 1709+)
Start-Process 'UsoClient.exe' -ArgumentList 'StartScan' -NoNewWindow -Wait
Start-Sleep -Seconds 10
Start-Process 'UsoClient.exe' -ArgumentList 'StartDownload' -NoNewWindow -Wait
Start-Sleep -Seconds 10
Start-Process 'UsoClient.exe' -ArgumentList 'StartInstall' -NoNewWindow -Wait

# Option 2: wuauclt (legacy fallback)
# wuauclt /detectnow /updatenow

# Option 3: Force via COM (most reliable for scripting)
$session  = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()
$result   = $searcher.Search("IsInstalled=0 AND Type='Driver'")
Write-Host "Found $($result.Updates.Count) pending driver update(s):" -ForegroundColor Yellow
$result.Updates | ForEach-Object { Write-Host "  - $($_.Title)" }

if ($result.Updates.Count -gt 0) {
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $result.Updates
    $downloader.Download()

    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $result.Updates
    $installResult = $installer.Install()
    Write-Host "Install result code: $($installResult.ResultCode)" -ForegroundColor Cyan
    # 0=NotStarted 1=InProgress 2=Succeeded 3=SucceededWithErrors 4=Failed 5=Aborted
}
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Intune Driver Management diagnostic evidence for escalation
.NOTES     Run as Administrator. Output saved to C:\Temp\DriverMgmt-Evidence\
#>
#Requires -RunAsAdministrator

$outDir = "C:\Temp\DriverMgmt-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

function Write-Status { param([string]$M,[string]$S="INFO")
    $c = switch($S){"OK"{"Green"}"WARN"{"Yellow"}"ERROR"{"Red"}default{"Cyan"}}
    Write-Host "[$S] $M" -ForegroundColor $c
}

Write-Status "Collecting driver management evidence to $outDir"

# 1. Device identity
dsregcmd /status | Out-File "$outDir\dsregcmd.txt"
Write-Status "dsregcmd output captured" "OK"

# 2. WU policy registry
$wuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
Get-Item $wuPath -ErrorAction SilentlyContinue |
    Get-ItemProperty | ConvertTo-Json | Out-File "$outDir\WU-Policy-Registry.json"
Write-Status "WU policy registry captured" "OK"

# 3. All installed drivers
Get-WmiObject Win32_PnPSignedDriver |
    Select-Object DeviceName, DriverVersion, DriverDate, Manufacturer, InfName |
    Sort-Object DeviceName |
    Export-Csv "$outDir\InstalledDrivers.csv" -NoTypeInformation
Write-Status "Installed drivers exported" "OK"

# 4. PnP devices with errors
Get-PnpDevice | Where-Object { $_.Status -ne 'OK' } |
    Select-Object FriendlyName, Class, Status, Problem, InstanceId |
    Export-Csv "$outDir\PnP-Errors.csv" -NoTypeInformation
Write-Status "PnP error devices exported" "OK"

# 5. Pending WU updates (drivers)
$session  = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()
try {
    $result = $searcher.Search("IsInstalled=0 AND Type='Driver'")
    $result.Updates | Select-Object Title, @{N='KB';E={$_.KBArticleIDs -join ','}}, MsrcSeverity |
        Export-Csv "$outDir\Pending-DriverUpdates.csv" -NoTypeInformation
    Write-Status "Pending driver updates: $($result.Updates.Count)" "OK"
} catch {
    Write-Status "WU COM query failed: $_" "WARN"
}

# 6. Windows Update event log (last 100 events)
Get-WinEvent -LogName 'Microsoft-Windows-WindowsUpdateClient/Operational' -MaxEvents 100 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$outDir\WU-Events.csv" -NoTypeInformation
Write-Status "WU event log captured" "OK"

# 7. Intune MDM diagnostic (if possible)
$mdmCab = "$outDir\MDMDiag.cab"
Start-Process 'MDMDiagnosticsTool.exe' -ArgumentList "-area DeviceEnrollment;DeviceProvisioning -cab `"$mdmCab`"" -Wait -NoNewWindow
if (Test-Path $mdmCab) { Write-Status "MDM diagnostic cab captured" "OK" }
else { Write-Status "MDM diagnostic cab not captured (tool may not be present)" "WARN" }

# 8. OS version
[PSCustomObject]@{
    ComputerName = $env:COMPUTERNAME
    OSVersion    = (Get-CimInstance Win32_OperatingSystem).Version
    BuildNumber  = (Get-CimInstance Win32_OperatingSystem).BuildNumber
    Caption      = (Get-CimInstance Win32_OperatingSystem).Caption
} | ConvertTo-Json | Out-File "$outDir\OSVersion.json"

Write-Status "Evidence collection complete. Files in: $outDir" "OK"
Compress-Archive -Path $outDir -DestinationPath "$outDir.zip" -Force
Write-Status "Compressed to: $outDir.zip" "OK"
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check WU policy registry | `Get-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'` |
| Find WSUS remnant keys | `Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' \| Select WUServer,WUStatusServer` |
| List pending driver updates | `(New-Object -Com Microsoft.Update.Session).CreateUpdateSearcher().Search("IsInstalled=0 AND Type='Driver'").Updates \| Select Title` |
| Force WU scan | `UsoClient.exe StartScan` |
| Force WU download | `UsoClient.exe StartDownload` |
| Force WU install | `UsoClient.exe StartInstall` |
| List all installed drivers | `Get-WmiObject Win32_PnPSignedDriver \| Select DeviceName,DriverVersion,DriverDate` |
| Devices with PnP errors | `Get-PnpDevice \| Where Status -ne 'OK'` |
| Delete driver (offline WinRE) | `pnputil /delete-driver oem42.inf /uninstall` |
| List drivers in offline image | `dism /image:C:\ /get-drivers /all` |
| Decode WU log (ETL) | `Get-WindowsUpdateLog` |
| MDM diagnostics | `MDMDiagnosticsTool.exe -area DeviceEnrollment -cab C:\Temp\mdm.cab` |
| GP result | `gpresult /scope computer /r \| Select-String WindowsUpdate` |
| Restart WU service | `Restart-Service wuauserv -Force` |

---

## 🎓 Learning Pointers

- **DUM vs WU rings:** Driver Update Management (DUM) is a separate Intune feature from Windows Update rings. WU rings control *when* approved drivers install; DUM controls *which* drivers are approved for deployment. Both must be configured correctly for driver management to work end-to-end. [MS Docs: Manage driver updates](https://learn.microsoft.com/mem/intune/protect/windows-driver-updates-overview)

- **WSUS keys survive migration:** When migrating from WSUS/SCCM to Intune, the `WUServer` and `UseWUServer` registry keys often persist through domain join removal or re-imaging if the image itself was built on a WSUS-managed machine. Always validate these keys on newly enrolled devices. [MS Docs: Updating from WSUS](https://learn.microsoft.com/windows/deployment/update/plan-determine-app-readiness)

- **Boot-critical vs. standard drivers:** Not all BSODs are equal. If a device BSODs before the login screen, the failing driver is boot-critical (storage, filter driver, NIC with NetBoot). If it BSODs after login, it's likely a PnP device driver. Recovery approach differs — boot-critical failures require WinRE offline repair. [MS Docs: WinRE](https://learn.microsoft.com/windows-hardware/manufacture/desktop/windows-recovery-environment--windows-re--technical-reference)

- **WDAC + unsigned drivers:** If your environment uses WDAC (Windows Defender Application Control), unsigned or self-signed driver INFs will be blocked from loading even if approved in DUM. Check WDAC audit log (Event ID 3089, 3076) before blaming DUM. [MS Docs: WDAC and drivers](https://learn.microsoft.com/windows/security/application-security/application-control/app-control-for-business/design/app-control-and-virtualization-based-protection-of-code-integrity)

- **Driver pausing for regressions:** DUM has a "Pause" option that delays a specific driver without permanently declining it. Use Pause (not Decline) when investigating a suspected regression — it's non-destructive and can be lifted once the driver is validated. [MS Docs: Pause driver updates](https://learn.microsoft.com/mem/intune/protect/windows-driver-updates-policy)

- **Proactive remediation for driver health:** Combine DUM with an Intune Remediation script that checks `Get-PnpDevice` for error states and alerts via Log Analytics. This gives you visibility into driver-related device health without waiting for helpdesk tickets.
