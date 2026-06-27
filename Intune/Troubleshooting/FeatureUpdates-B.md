# Intune Feature Update Policies — Hotfix Runbook (Mode B: Ops)
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

Run on the **affected Windows device** as admin:

```powershell
# 1. Check current Windows version and target
[System.Environment]::OSVersion.Version
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").ReleaseId

# 2. Check Feature Update policy via MDM bridge
Get-CimInstance -Namespace root/cimv2/mdm/dmmap -ClassName MDM_Policy_Result01_Update02 |
  Select-Object TargetReleaseVersion, TargetReleaseVersionInfo, AllowTargetReleaseInfo |
  Format-List

# 3. Check Windows Update client status
UsoClient.exe StartScan
Start-Sleep -Seconds 20
Get-WindowsUpdateLog  # Generates WindowsUpdate.log on Desktop

# 4. Check if device is being held back
(Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate").TargetReleaseVersion
(Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate").TargetReleaseVersionInfo

# 5. Check device compliance / safeguard holds
$updates = Get-WindowsUpdateLog -LogPath C:\Temp\WU.log
```

**Interpretation:**
| Result | Action |
|--------|--------|
| `DisplayVersion` already at target | Policy applied — device is current, no action needed |
| `TargetReleaseVersion` = 0 or missing | Feature update policy not received — check Intune assignment |
| `TargetReleaseVersionInfo` shows wrong version | Stale policy or conflicting GPO — check for GPO overlap |
| Device stuck below target for 30+ days | Safeguard hold or compatibility block — check Windows Update for Business reports |
| `WindowsUpdate.log` shows `FAIL_SAFE_HOLD` | Microsoft has blocked this device from the target version — cannot override |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Device enrolled in Intune (MDM)
  └── Windows 10/11 Pro/Enterprise/Education (not Home — no MDM feature update control)
       └── Device syncing with Intune (last sync < 8 hours)
            └── Feature Update Policy assigned to device or group
                 └── Policy targeting correct version (e.g. "Windows 11, version 24H2")
                      └── No conflicting GPO setting TargetReleaseVersion
                           └── No safeguard hold from Microsoft (compatibility issue)
                                └── Windows Update service running
                                     └── Device can reach Windows Update endpoints
                                          └── Feature update downloads and installs
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm policy is reaching the device**
```powershell
# Check MDM policy registry (set by Intune)
$wuReg = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
Get-ItemProperty $wuReg -ErrorAction SilentlyContinue |
  Select-Object TargetReleaseVersion, TargetReleaseVersionInfo, TargetReleaseVersionType
```
Expected: `TargetReleaseVersion = 1`, `TargetReleaseVersionInfo = 24H2` (or whatever version is targeted).
Missing or wrong → policy not applied — go to Intune portal.

**Step 2 — Check Intune sync and policy assignment**

In Intune portal:
- Devices → Windows → Configuration → Feature Update Policies → select policy → Device Status
- Check if device shows `Succeeded` or `Error` or `Pending`
- Filter by device name

Or from device:
```powershell
# Force Intune sync
Get-ScheduledTask -TaskName "PushLaunch" | Start-ScheduledTask
Start-Sleep -Seconds 30
# Or: Company Portal → Sync this device
```

**Step 3 — Check for conflicting Group Policy**
```powershell
gpresult /scope computer /r | Select-String -Context 2,5 "TargetRelease|Feature|Update"
```
Expected: no GPO setting `TargetReleaseVersion`. If GPO is present → MDM policy may be overridden.

**Step 4 — Check safeguard holds**
```powershell
# Safeguard holds appear in Windows Update log
$logPath = "$env:USERPROFILE\Desktop\WindowsUpdate.log"
Get-WindowsUpdateLog -LogPath $logPath
Select-String -Path $logPath "SAFEGUARD\|Safeguard\|Hold"
```

Also check Windows Update for Business Reports in Intune (if licensed):
- Reports → Windows Updates → Feature Update Failures

**Step 5 — Check Windows Update service and connectivity**
```powershell
Get-Service wuauserv, UsoSvc | Select-Object Name, Status
# Test WU endpoint
Test-NetConnection -ComputerName "fe3cr.delivery.mp.microsoft.com" -Port 443
```
Expected: both services Running; TCP test Succeeded.

---

## Common Fix Paths

<details><summary>Fix 1 — Re-push Feature Update policy (not reaching device)</summary>

In Intune portal:
1. Go to **Devices → Windows → Feature Update Policies**
2. Select the policy → Assignments → verify the device's group is assigned
3. If assigned: go to Device → select the device → Sync
4. Wait 10-15 minutes, then re-run triage Step 1

On device:
```powershell
# Trigger MDM sync
Start-Process "C:\Windows\System32\deviceenroller.exe" -ArgumentList "/o enrollonly" -Wait
# Or scheduled task
Get-ScheduledTask -TaskName "Schedule #3 created by enrollment client" | Start-ScheduledTask
```

</details>

<details><summary>Fix 2 — Remove conflicting GPO (feature update held by Group Policy)</summary>

If `gpresult` shows a GPO setting `TargetReleaseVersion`:
```powershell
# Check exact GPO name applying the setting
gpresult /scope computer /h C:\Temp\gpresult.html
# Open gpresult.html, search for "TargetReleaseVersion"
```

Options:
- **Remove the GPO setting** from Group Policy Management Console (preferred for MDM-managed devices)
- **Use MDM wins over GPO** (Windows 10 1803+, requires `MDMWinsOverGP` policy set)
```powershell
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" `
  -Name "MDMWinsOverGP" -Value 1 -Type DWORD
# Requires restart to take effect
```

**⚠️ Note:** Conflicting GPO + MDM is undefined behaviour on some builds — cleanest fix is removing the GPO setting for MDM-managed devices.

</details>

<details><summary>Fix 3 — Bypass (opt out of) a safeguard hold</summary>

Microsoft-imposed safeguard holds cannot be removed by admins — they protect devices from known compatibility issues. However, you can opt the device out if you accept the risk:

```powershell
# In Intune Feature Update policy → edit → set "Opt out of safeguard holds" to Yes
# This adds DisableWUfBSafeguards = 1 to the device via MDM

# Verify on device after sync:
(Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate").DisableWUfBSafeguards
# Expected: 1
```

**⚠️ Risk:** Opting out of safeguard holds may cause issues Microsoft's compatibility team identified. Only do this if vendor has confirmed compatibility, or in a pilot group.

</details>

<details><summary>Fix 4 — Fix Windows Update service not running</summary>

```powershell
# Restart Windows Update and dependencies
Stop-Service wuauserv, UsoSvc, cryptsvc -Force
Start-Sleep -Seconds 5
Start-Service cryptsvc, UsoSvc, wuauserv

# Clear Windows Update cache if stuck
Stop-Service wuauserv -Force
Remove-Item "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
Start-Service wuauserv

# Trigger scan
UsoClient.exe StartScan
```

</details>

<details><summary>Fix 5 — Device stuck on "Offer Received" / download not starting</summary>

```powershell
# Check disk space (need ~20GB free for feature update)
Get-PSDrive C | Select-Object Used, Free

# Check if Delivery Optimization is working
Get-Service DoSvc | Select-Object Status
Get-DeliveryOptimizationStatus

# Force Windows Update to attempt download
UsoClient.exe StartDownload
Start-Sleep -Seconds 60
UsoClient.exe StartInstall
```

If disk space issue: use Disk Cleanup or DISM:
```powershell
# Clean up superseded components
DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase
```

</details>

---

## Escalation Evidence

```
ESCALATION: Intune Feature Update Policy — Device Not Updating
=============================================================
Date/Time         : [YYYY-MM-DD HH:MM UTC]
Reporter          : [Name / Tier]
Affected devices  : [Hostname(s) / count / percentage of fleet]
Target version    : [e.g. Windows 11 24H2]
Current version   : [e.g. Windows 11 23H2]
Intune policy name: [Policy name in Intune portal]

--- Device Evidence ---
Current DisplayVersion: [e.g. 23H2]
TargetReleaseVersionInfo (registry): [value or "missing"]
MDM sync last: [timestamp from Intune portal]
WU services: wuauserv=[Running/Stopped], UsoSvc=[Running/Stopped]
Safeguard hold found: [Yes (hold ID) / No]
GPO conflict: [Yes (GPO name) / No]
Disk free: [GB]

--- Intune Portal ---
Policy assignment status: [Succeeded/Error/Pending for this device]
Error code (if any): [0xXXXXXXXX]
WUfB Reports showing: [hold type or error if available]

--- Attempted Fixes ---
1. [Tried + result]
2. [Tried + result]

Priority: [e.g. "Compliance deadline in 7 days — 200 devices affected"]
```

---

## 🎓 Learning Pointers

- **Feature Update Policies ≠ Update Rings.** Update Rings control *when* quality updates install (deferral days, maintenance windows). Feature Update Policies control *which Windows version* the device targets. Both can coexist — and both must be aligned. If an Update Ring defers feature updates by 365 days, a Feature Update Policy targeting 24H2 will still be blocked. See [Intune Feature Updates docs](https://learn.microsoft.com/en-us/mem/intune/protect/windows-10-feature-updates).

- **Safeguard holds are Microsoft's quality gate.** When Microsoft detects a driver, application, or hardware incompatibility with a Windows version, they add affected devices to a safeguard hold. Devices with that configuration won't receive the update via WUfB until the hold is lifted or the incompatibility is resolved. You can see holds in [Windows Update for Business reports](https://learn.microsoft.com/en-us/windows/deployment/update/wufb-reports-overview).

- **Windows Home edition does not support MDM feature update targeting.** Feature Update Policies only work on Pro, Enterprise, Education, and Pro Education. Home devices will ignore the policy. This is a common gotcha in BYOD or consumer-device fleets.

- **Conflicting GPO + Intune is the #1 cause of policy not taking effect.** In hybrid-joined environments, GPO and MDM can both write to `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`. MDM doesn't automatically win. Use `MDMWinsOverGP` (Device Config profile → Administrative Templates → MDM) to enforce MDM precedence, or remove the conflicting GPO for co-managed/Intune-only devices.

- **Feature updates need ~20GB free disk space.** The staging process downloads the full OS update (~4-8GB) and expands it to temporary storage. Devices with <20GB free will silently fail at the download or preparation phase. Monitor disk space proactively, especially on devices with 128GB SSDs running full Teams + OneDrive configurations.
