# Intune Feature Update Policies — Reference Runbook (Mode A: Deep Dive)
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
- Intune Feature Update Policies (Windows 10 → 11, and version-to-version upgrades)
- Safeguard holds and compatibility checks
- WUfB vs Feature Update Policy interaction
- Enrollment and assignment targeting
- CBS (Component-Based Servicing) and upgrade readiness

**Does not cover:**
- Windows Update for Business rings (see `WUfB-A.md`)
- WSUS-managed endpoints
- In-place upgrades via task sequence (SCCM/MCM)
- Driver update policies (see `DriverManagement-A.md`)

**Assumes:**
- Devices are Intune-enrolled (hybrid or pure cloud)
- Windows 10 21H2+ or Windows 11 baseline
- No active WSUS policy conflict (GPO or legacy MDM)
- Telemetry level set to Enhanced (1) or above — required for safeguard hold signals

---

## How It Works

<details><summary>Full architecture</summary>

### Feature Update Policy Flow

```
Admin creates Feature Update Policy in Intune
         │
         ▼
Policy assigned to AAD group → device receives via MDM channel
         │
         ▼
WUfB Service (Windows Update for Business)
     ├── Checks for safeguard holds (MS compatibility data)
     ├── Checks deferral settings (from WUfB ring policy, if any)
     └── Schedules upgrade scan via Windows Update Agent
         │
         ▼
Windows Update Agent (wuauserv)
     ├── Contacts Windows Update / DO (Delivery Optimization)
     ├── Downloads upgrade content (several GB)
     └── Triggers CBS (Component-Based Servicing) upgrade
         │
         ▼
CBS applies upgrade → Windows PE phase → OOBE-less reboot
         │
         ▼
Post-upgrade: version check, policy re-evaluation
```

### Key Components

| Component | Role |
|-----------|------|
| WUfB Service | Manages deferral, deadline, safeguard hold signals |
| Windows Update Agent (`wuauserv`) | Downloads and stages content |
| UsoClient.exe | Orchestrates the scan/download/install cycle |
| CBS (TrustedInstaller) | Applies the upgrade package |
| MDM Enrollment Agent | Receives and applies Intune policy via OMA-URI |
| Safeguard Hold Registry | Blocks upgrade when MS detects compatibility issue |
| Delivery Optimization | Peer caching / BranchCache for content distribution |

### Policy Delivery Path
Intune feature update policies translate to WUfB-compatible MDM policies, pushed via the `./Vendor/MSFT/Policy/Config/Update/` CSP namespace. The key CSPs are:
- `TargetReleaseVersion` — target build (e.g. "22H2")
- `TargetReleaseVersionInfo` — product name ("Windows 11")
- `DeferFeatureUpdatesPeriodInDays` — holdback (usually 0 for feature update policy)
- `ActiveHoursStart/End` — active hours windows

### Safeguard Holds
Microsoft applies safeguard holds when telemetry data from Windows Insider or early adopter rings identifies incompatibilities (driver, application, hardware). Devices with affected configurations are blocked from receiving the update. Holds are identified by a numeric ID (e.g., 41784788). They clear automatically once MS confirms the issue is resolved or a fix is available.

Safeguard holds require **Diagnostic Data level ≥ 1** (Basic). At level 0, holds cannot be applied but the device also won't receive the update.

</details>

---

## Dependency Stack

```
Azure AD / Entra ID
└── Intune (MEM) — Feature Update Policy defined + assigned
    └── AAD Group Membership — device in scope
        └── MDM Enrollment — device enrolled, check-in active
            └── Windows Update Service (wuauserv) — running
                └── WUfB Policy CSP — applied via MDM
                    └── Safeguard Hold Check — no active hold
                        └── Delivery Optimization / Windows Update CDN
                            └── CBS / TrustedInstaller — applies upgrade
                                └── Device Restart / Scheduled Reboot
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Device stuck on wrong version indefinitely | Safeguard hold active | `Get-WindowsUpdateLog`, registry DWORD `HResult` in WU keys |
| Policy shows "Pending" in Intune reporting | Device hasn't checked in / MDM policy not applied | `dsregcmd /status`, MDM enrollment state |
| "Not applicable" in Intune feature update report | Device not in assignment target group | Group membership, dynamic rule eval |
| Upgrade downloads but never installs | Active hours conflict, deadline not set | Active hours policy, UsoClient logs |
| Upgrade fails mid-process (error code) | Driver/app compatibility, disk space, CBS error | CBS log `%windir%\Logs\CBS\CBS.log` |
| Device shows correct version in Intune but wrong locally | Stale MDM inventory report | Trigger sync, check `DeviceManagementState` |
| "Offered" state never moves to "Installing" | No restart scheduled, device always active | Deadline policy, reboot behavior settings |
| Multiple feature update policies conflict | Overlapping assignments with different targets | Check effective policy via Settings > Windows Update |
| Upgrade completes but reverts after reboot | CBS rollback — compatibility check failure in PE phase | Upgrade event log, CBS log rollback entries |

---

## Validation Steps

**1 — Verify MDM Feature Update Policy is applied**
```powershell
# Check registry for WUfB CSP values
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" |
    Select-Object TargetReleaseVersion, TargetReleaseVersionInfo, DeferFeatureUpdatesPeriodInDays
```
Expected: `TargetReleaseVersion` = "22H2" (or your target), `TargetReleaseVersionInfo` = "Windows 11"  
Bad: Empty or mismatched — policy not applied, check enrollment and MDM channel.

**2 — Check current OS version**
```powershell
[System.Environment]::OSVersion.Version
(Get-ComputerInfo).WindowsVersion
(Get-ComputerInfo).OsDisplayVersion
```
Expected: Version matches target, or is lower (pre-upgrade). If higher, the policy target may be stale.

**3 — Check for active safeguard holds**
```powershell
# Safeguard hold blocks are logged here
Get-WindowsUpdateLog -LogPath "$env:TEMP\wulog.txt"
Select-String -Path "$env:TEMP\wulog.txt" -Pattern "Safeguard|safeguard|hold|block" | Select-Object -Last 20
```
Expected: No safeguard entries or entries showing hold cleared.  
Bad: `HOLD_APPLIED` or `SafeguardHoldID` present — device is blocked.

**4 — Check Windows Update scan state**
```powershell
# Force a WU scan and check status
UsoClient.exe StartScan
Start-Sleep -Seconds 30
Get-WindowsUpdateLog -LogPath "$env:TEMP\wulog2.txt"
Select-String -Path "$env:TEMP\wulog2.txt" -Pattern "error|failed|blocked" | Select-Object -Last 15
```

**5 — Check Delivery Optimization connectivity**
```powershell
# Test DO cloud connectivity
Get-DeliveryOptimizationLog | Where-Object {$_.Message -like "*error*" -or $_.Message -like "*failed*"} | Select-Object -Last 10

# Check DO status
Get-DeliveryOptimizationStatus
```
Expected: Connected peers (if DO enabled), non-zero download speeds.  
Bad: All downloads from HTTP (no DO), errors connecting to DO cloud service.

**6 — Confirm telemetry level**
```powershell
(Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection").AllowTelemetry
```
Expected: 1 or higher. If 0, safeguard holds cannot be received and upgrades may not offer.

**7 — Check MDM enrollment health**
```powershell
dsregcmd /status | Select-String "MDMUrl|EnrollmentState|MDMEnrollment"
```
Expected: `MDMEnrollment : YES`, MDMUrl pointing to Intune endpoint.

---

## Troubleshooting Steps (by phase)

### Phase 1: Policy Not Reaching Device

1. Confirm device is enrolled in Intune: `dsregcmd /status` → `MDMEnrollment : YES`
2. Trigger a manual MDM sync: **Settings → Accounts → Access work or school → Info → Sync**
3. Check Intune portal: **Devices → [Device] → Device configuration** — verify the feature update profile appears and shows "Succeeded" or "Pending"
4. Verify group membership: the device's AAD object must be in the assigned group. Dynamic groups can take 15-30 min to update.
5. Check for conflicting policies — a higher-precedence WUfB ring policy setting `DeferFeatureUpdatesPeriodInDays` can override the target version.

### Phase 2: Policy Applied but Upgrade Not Starting

1. Check for safeguard holds (Step 3 above)
2. Verify disk space: Feature upgrades need 20-30 GB free. Check with `Get-PSDrive C`
3. Confirm Windows Update service is running: `Get-Service wuauserv | Select-Object Status`
4. Check active hours — if the device is always in use during active hours and no deadline is set, the upgrade never installs
5. Trigger a forced update scan: `UsoClient.exe StartScan` then `UsoClient.exe StartDownload`

### Phase 3: Upgrade Downloading but Fails to Install

1. Pull CBS log: `Get-Content "$env:windir\Logs\CBS\CBS.log" | Select-Object -Last 100`
   - Look for `[SR]` or `FATAL` or `ROLLBACK` entries
2. Check event log for CBS/setup errors:
   ```powershell
   Get-WinEvent -LogName "Setup" | Where-Object {$_.LevelDisplayName -eq "Error"} | Select-Object -First 10 | Format-List
   ```
3. Run SFC and DISM before retry:
   ```powershell
   sfc /scannow
   DISM /Online /Cleanup-Image /RestoreHealth
   ```
4. Check for blocking drivers: outdated firmware or drivers (especially NIC/storage) are a common safeguard hold trigger
5. If upgrade installs but reverts: check `$env:windir\Panther\setuperr.log` for the rollback reason

### Phase 4: Upgrade Complete but Intune Reports Wrong State

1. Trigger a sync from the device
2. Force a hardware inventory refresh: `Get-ScheduledTask -TaskName "*Intune*" | Start-ScheduledTask`
3. Wait up to 8 hours for reporting to catch up — Intune feature update reports have a delay
4. Check the **Feature updates for Windows 10 and later** report in Intune: **Reports → Windows Updates → Feature update failures**

---

## Remediation Playbooks

<details><summary>Playbook 1 — Clear a Safeguard Hold (opt-out)</summary>

> ⚠️ Only opt out of a safeguard hold if you have confirmed the device does NOT have the affected hardware/software. Microsoft holds exist to prevent data loss or boot failures.

```powershell
# Check which holds are active
$wuReg = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\TargetVersionUpgradeExperienceIndicators"
if (Test-Path $wuReg) {
    Get-ItemProperty -Path $wuReg | Select-Object * | Format-List
}

# To opt a specific device out of ALL safeguard holds (use with extreme caution)
# This requires the DisableWUfBSafeguards policy via Intune
# In Intune: Devices > Configuration > Create > Settings Catalog > "Disable Safeguards for Feature Updates"
# Value: Enabled

# Via registry (local only, not recommended for production):
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "DisableWUfBSafeguards" -Value 1 -Type DWord
Write-Warning "Safeguard hold opt-out applied. Upgrade will proceed regardless of compatibility warnings."
```

**Rollback:** Remove the `DisableWUfBSafeguards` value or set to 0. The hold will reapply within the next WU scan cycle.
</details>

<details><summary>Playbook 2 — Force Feature Update Install via Windows Update MedIC / Media</summary>

When MDM policy isn't triggering the upgrade, use the Windows 11 Installation Assistant or Media Creation Tool as a break-glass:

```powershell
# Option A: Download Windows 11 upgrade assistant
# https://www.microsoft.com/en-us/software-download/windows11
# Run as admin — performs compatibility check then upgrades in-place

# Option B: Use DISM to mount and apply (advanced)
# Mount the Windows 11 ISO, then run:
# setup.exe /auto upgrade /quiet /eula accept /compat ignorewarning

# Option C: Force via Windows Update directly (bypasses Intune targeting)
$session = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()
$result = $searcher.Search("IsInstalled=0 AND Type='Software'")
$result.Updates | Where-Object {$_.Title -like "*Feature Update*"} | Select-Object Title, IsDownloaded
```
</details>

<details><summary>Playbook 3 — Reset Windows Update Components (when upgrade is stuck)</summary>

```powershell
# Stop WU services
Stop-Service -Name wuauserv, cryptsvc, bits, msiserver -Force -ErrorAction SilentlyContinue

# Rename SoftwareDistribution and Catroot2 (WU cache)
Rename-Item "$env:SystemRoot\SoftwareDistribution" "SoftwareDistribution.bak" -ErrorAction SilentlyContinue
Rename-Item "$env:SystemRoot\System32\catroot2" "catroot2.bak" -ErrorAction SilentlyContinue

# Restart services
Start-Service -Name wuauserv, cryptsvc, bits, msiserver

# Trigger fresh scan
UsoClient.exe StartScan
Write-Status "WU components reset. Allow 10-15 minutes for rescan." "OK"
```

**Rollback:** If issues arise, rename the `.bak` folders back. WU will repopulate SoftwareDistribution automatically.
</details>

<details><summary>Playbook 4 — Fix Intune Assignment Not Reaching Device</summary>

```powershell
# Check all MDM policies applied to the device
$enrollID = (Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" | 
    Where-Object {(Get-ItemProperty $_.PSPath).EnrollmentType -eq 6}).PSChildName

if ($enrollID) {
    Write-Host "Enrollment ID: $enrollID" -ForegroundColor Green
    # Check policy store
    Get-ChildItem "HKLM:\SOFTWARE\Microsoft\PolicyManager\providers\$enrollID\default\Device\Update" -ErrorAction SilentlyContinue |
        Get-ItemProperty | Select-Object TargetReleaseVersion, TargetReleaseVersionInfo
} else {
    Write-Warning "No MDM enrollment found. Device may not be properly enrolled."
}

# Force MDM sync
$objMDM = New-Object -ComObject Microsoft.MDM.Enrollment.SyncML
$objMDM.SyncMLRequest()
```
</details>

---

## Evidence Pack

```powershell
# ============================================================
# Feature Update Policy — Evidence Collection Script
# Run as: Administrator
# ============================================================
$OutputDir = "$env:TEMP\FeatureUpdateEvidence_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null

# OS version
[System.Environment]::OSVersion | Out-File "$OutputDir\01_OSVersion.txt"
(Get-ComputerInfo | Select-Object OsName, OsDisplayVersion, OsBuildNumber, WindowsVersion) | 
    Out-File "$OutputDir\01_OSVersion.txt" -Append

# Feature update policy CSP values
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" 2>$null |
    Out-File "$OutputDir\02_WUfBPolicy.txt"

# Safeguard hold registry
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\TargetVersionUpgradeExperienceIndicators" 2>$null |
    Out-File "$OutputDir\03_SafeguardHolds.txt"

# MDM enrollment
dsregcmd /status | Out-File "$OutputDir\04_DSRegCmd.txt"

# Windows Update log (last 500 lines)
Get-WindowsUpdateLog -LogPath "$OutputDir\05_WindowsUpdate.txt" 2>$null
if (Test-Path "$OutputDir\05_WindowsUpdate.txt") {
    Get-Content "$OutputDir\05_WindowsUpdate.txt" | Select-Object -Last 500 | 
        Out-File "$OutputDir\05_WindowsUpdate_tail.txt"
}

# CBS log tail
if (Test-Path "$env:windir\Logs\CBS\CBS.log") {
    Get-Content "$env:windir\Logs\CBS\CBS.log" | Select-Object -Last 200 |
        Out-File "$OutputDir\06_CBS_tail.txt"
}

# Disk space
Get-PSDrive C | Select-Object Used, Free | Out-File "$OutputDir\07_DiskSpace.txt"

# Delivery Optimization status
Get-DeliveryOptimizationStatus | Out-File "$OutputDir\08_DOStatus.txt"

# Telemetry level
(Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection").AllowTelemetry |
    Out-File "$OutputDir\09_Telemetry.txt"

# Setup error log (post-upgrade failure)
if (Test-Path "$env:windir\Panther\setuperr.log") {
    Get-Content "$env:windir\Panther\setuperr.log" | Select-Object -Last 50 |
        Out-File "$OutputDir\10_SetupErr.txt"
}

Write-Host "Evidence collected at: $OutputDir" -ForegroundColor Green

# Compress
Compress-Archive -Path $OutputDir -DestinationPath "$OutputDir.zip" -Force
Write-Host "ZIP: $OutputDir.zip" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check current OS version | `(Get-ComputerInfo).OsDisplayVersion` |
| Check WUfB target version CSP | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update"` |
| Force MDM sync | Settings → Access work or school → Info → Sync |
| Trigger WU scan | `UsoClient.exe StartScan` |
| Trigger WU download | `UsoClient.exe StartDownload` |
| Trigger WU install | `UsoClient.exe StartInstall` |
| Pull Windows Update log | `Get-WindowsUpdateLog -LogPath "$env:TEMP\wu.txt"` |
| Check CBS log | `Get-Content "$env:windir\Logs\CBS\CBS.log" \| Select-Object -Last 100` |
| Check safeguard hold registry | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\..."` |
| Check disk space | `Get-PSDrive C \| Select-Object Free` |
| Reset WU cache | Stop services, rename SoftwareDistribution, restart services |
| SFC repair | `sfc /scannow` |
| DISM repair | `DISM /Online /Cleanup-Image /RestoreHealth` |
| Check DO status | `Get-DeliveryOptimizationStatus` |

---

## 🎓 Learning Pointers

- **Feature Update vs Quality Update policies** are distinct in Intune. Feature Update policies use the `TargetReleaseVersion` CSP to pin or upgrade devices to a specific Windows version, while WUfB Ring policies control monthly quality updates. Mixing the two can cause unexpected deferral interactions — see [MS Docs: Feature updates for Windows 10 and later](https://learn.microsoft.com/en-us/mem/intune/protect/windows-10-feature-updates).

- **Safeguard holds are not bugs.** Microsoft applies them when early adopter telemetry reveals real-world failures. Opting out without confirming the device doesn't have the affected component can cause boot loops or data loss. Track hold IDs at the [Windows Health Dashboard](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information).

- **CBS (Component-Based Servicing) is the gatekeeper.** If SFC or DISM report corruption, CBS will refuse to apply the upgrade. Always run `sfc /scannow` and `DISM /Online /Cleanup-Image /RestoreHealth` before investigating upgrade failures at a deeper level.

- **Delivery Optimization is critical at scale.** Without DO configured, every device downloads several GB of upgrade content directly from Windows Update CDN. Configure DO Group ID or use a Microsoft Connected Cache server for environments with many devices. See [DO configuration for Intune](https://learn.microsoft.com/en-us/mem/intune/configuration/delivery-optimization-windows).

- **Intune feature update reports lag.** The **Feature updates for Windows 10 and later** report in Intune can be 24-48 hours behind actual device state. For real-time checks, always query the device directly via PowerShell or the Intune device details blade.

- **Windows 11 hardware requirements create a new failure class.** TPM 2.0, Secure Boot, and CPU compatibility gates are enforced by the upgrade setup, not just by Intune. Devices failing hardware checks will silently fail to upgrade even with a valid policy applied. Use the [PC Health Check tool](https://aka.ms/GetPCHealthCheckApp) or `Get-TPM` to prevalidate.
