# Windows Update for Business (WUfB) via Intune — Hotfix Runbook (Mode B: Ops)
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

Run these first on the affected device (elevated PowerShell):

```powershell
# 1. What update ring / deferral is currently applied?
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" |
    Select-Object DeferFeatureUpdatesPeriodInDays, DeferQualityUpdatesPeriodInDays, BranchReadinessLevel

# 2. What is Windows Update actually doing right now?
Get-WindowsUpdateLog  # Generates WindowsUpdate.log on Desktop — check last 50 lines

# 3. What does the Intune Management Extension (IME) report for this device?
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" `
    -FilterHashtable @{ Level = 2; StartTime = (Get-Date).AddHours(-4) } -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Message | Select-Object -First 10

# 4. Is the device correctly enrolled and communicating with Intune?
$dsCfg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderID -eq "MS DM Server" }
$dsCfg | Select-Object EnrollmentType, UPN, EnrollmentState

# 5. What WUfB policies are active from the MDM channel?
$wuPolicies = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -ErrorAction SilentlyContinue
$wuPolicies
$wuAU = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -ErrorAction SilentlyContinue
$wuAU
```

**Interpretation:**

| Finding | Action |
|---------|--------|
| BranchReadinessLevel = 0 (no value) | → Policy not applied → [Fix 1 — Force Intune sync and check policy assignment](#fix-1--force-intune-sync-and-check-policy-assignment) |
| DeferFeatureUpdates shows unexpected large number | → Ring assignment wrong → [Fix 2 — Verify ring assignment](#fix-2--verify-ring-assignment) |
| Group Policy values present in `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` | → GPO conflict → [Fix 3 — Remove conflicting GPO](#fix-3--remove-conflicting-gpo) |
| Device not enrolled or EnrollmentState ≠ 1 | → Device enrollment issue → see Enrollment-B.md |
| Windows Update log shows `BLOCKED_BY_POLICY` | → Conflicting policy blocking updates → [Fix 3](#fix-3--remove-conflicting-gpo) or [Fix 4](#fix-4--fix-wsus-conflict) |
| Update ring applied but updates still not installing | → Windows Update client issue → [Fix 5 — Reset Windows Update client](#fix-5--reset-windows-update-client) |
| Update ring applied, updates downloading but stalled | → Driver or compatibility hold → [Fix 6 — Check and clear safeguard holds](#fix-6--check-and-clear-safeguard-holds) |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Intune (portal.azure.com / endpoint.microsoft.com)
    │
    ├── Device enrolled (MDM authority = Intune or co-managed)
    ├── Device in correct Entra ID / AAD group
    │       └── WUfB ring policy assigned to that group
    │
    ├── Update Ring Policy (Intune > Devices > Update Rings)
    │       ├── Feature update deferral (0–365 days)
    │       ├── Quality update deferral (0–30 days)
    │       ├── Branch readiness level (GA Channel, GA Channel Preview)
    │       └── Active hours / restart behaviour settings
    │
    ├── Feature Update Profile (optional, pins OS version)
    │       └── Supersedes ring deferral for feature updates if conflicting
    │
    └── Driver Update Policies (optional, Intune driver management)

Windows Update for Business Service (device-side)
    │
    ├── Windows 10 1709+ / Windows 11 (all versions)
    ├── Windows Update service (wuauserv) running
    ├── No conflicting WSUS GPO (UseWUServer = 1 blocks WUfB if WSUS unreachable)
    ├── No conflicting Group Policy WU settings
    └── Internet access to windowsupdate.microsoft.com / update.microsoft.com
            └── If behind proxy: proxy must allow *.update.microsoft.com, *.delivery.mp.microsoft.com
```

</details>

---

## Diagnosis & Validation Flow

**1. Check current OS version and expected version**
```powershell
[System.Environment]::OSVersion.Version
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion
# E.g.: 23H2, 24H2
```

**2. Check what WUfB ring is applied via MDM**
```powershell
# MDM-applied values land here (NOT in Policies\ — that's GPO)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" 2>$null |
    Select-Object DeferQualityUpdatesPeriodInDays, DeferFeatureUpdatesPeriodInDays,
                  BranchReadinessLevel, PauseQualityUpdates, PauseFeatureUpdates
```
Expected: Values match your Intune ring configuration.

**3. Confirm no WSUS redirect active**
```powershell
$wu = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -ErrorAction SilentlyContinue
if ($wu.UseWUServer -eq 1) {
    Write-Warning "WSUS redirect active — WUfB will be blocked if WSUS is unreachable"
    Write-Host "WSUS server: $((Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate').WUServer)"
}
```

**4. Check Windows Update service state**
```powershell
Get-Service wuauserv, bits, dosvc, usosvc | Select-Object Name, Status, StartType
```
Expected: wuauserv, bits, dosvc — Running or can be started. usosvc (Update Orchestrator) — Running.

**5. Trigger manual update scan and check result**
```powershell
# Force Windows Update scan
Start-Process "wuauclt.exe" -ArgumentList "/detectnow"
# Or more reliable:
$updateSession = New-Object -ComObject Microsoft.Update.Session
$searcher = $updateSession.CreateUpdateSearcher()
$result = $searcher.Search("IsInstalled=0 and IsHidden=0")
Write-Host "Pending updates: $($result.Updates.Count)"
$result.Updates | Select-Object Title, IsMandatory
```

---

## Common Fix Paths

<details><summary>Fix 1 — Force Intune sync and check policy assignment</summary>

```powershell
# Option A: Force sync from device
$EnrollmentID = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" |
    Where-Object { $_.ProviderID -eq "MS DM Server" }).PSChildName
$syncBody = @"
<SyncBody><Final /></SyncBody>
"@
# Trigger sync via scheduled task
Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\$EnrollmentID" -TaskName "Schedule to run OMA DM Client for MDM sessions initiated by user" 2>$null
# Or via Settings app: Settings → Accounts → Access work or school → Info → Sync

# Option B: Force sync via Intune portal
# Endpoint Manager → Devices → [Device] → Sync
```

**After sync, check assignment:**
```powershell
# Portal: Endpoint Manager → Devices → Update Rings → [Ring] → Device status
# Confirm device shows "Succeeded" or "Pending"
# If not listed — check group membership:
Connect-MgGraph -Scopes "GroupMember.Read.All","Device.Read.All"
$device = Get-MgDevice -Filter "DisplayName eq '<DEVICE_NAME>'"
Get-MgDeviceMemberOf -DeviceId $device.Id | Select-Object -ExpandProperty AdditionalProperties | Select-Object displayName
```

**Rollback:** N/A — sync is non-destructive.

</details>

<details><summary>Fix 2 — Verify ring assignment</summary>

```powershell
# Check what rings are assigned to a device in Intune
# Portal: Endpoint Manager → Devices → [Device] → Update Rings

# Confirm device is in the correct Entra group
Connect-MgGraph -Scopes "GroupMember.Read.All","Device.Read.All"
$deviceObj = Get-MgDevice -Filter "DisplayName eq '<DEVICE_NAME>'"
$groups = Get-MgDeviceMemberOf -DeviceId $deviceObj.Id
$groups | ForEach-Object { $_.AdditionalProperties.displayName }
```

**Common issue — device in multiple rings:**
If a device is in both a "Pilot" ring (0-day deferral) and a "Broad" ring (14-day deferral), Intune applies the least restrictive (shortest deferral). Fix by removing the device from the unintended group.

**Common issue — Feature Update Profile overriding ring:**
Feature Update profiles pin the OS version (e.g., Windows 11 23H2). If the device should be on a newer version, remove or update the Feature Update profile targeting it.

</details>

<details><summary>Fix 3 — Remove conflicting GPO</summary>

```powershell
# 1. Check for GPO-applied WU settings (these conflict with WUfB MDM policies)
$gpWU = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -ErrorAction SilentlyContinue
$gpAU = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -ErrorAction SilentlyContinue

if ($gpWU -or $gpAU) {
    Write-Warning "GPO Windows Update settings detected — these override MDM/WUfB!"
    $gpWU
    $gpAU
}

# 2. Find which GPO is setting these values
gpresult /H C:\Temp\GPResult.html /F
# Open HTML and search for "WindowsUpdate" to identify the GPO

# 3. To test: temporarily remove GPO-applied keys (WARNING: non-persistent, reverts on GPO refresh)
Remove-Item "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Recurse -Force -WhatIf
# Remove -WhatIf to execute; then run gpupdate /force to confirm GPO re-applies

# 4. Permanent fix: In Group Policy Management, edit the offending GPO
# Set WU policy settings to "Not Configured" (not Disabled — must be Not Configured)
# Then: gpupdate /force on affected devices
```

**Key conflict to eliminate:**
`UseWUServer = 1` in the AU key combined with an unreachable WSUS = complete WU blockage.
`DisableWindowsUpdateAccess = 1` = users and WUfB both blocked.

**Rollback:** Re-enable the GPO settings if needed, or run `gpupdate /force`.

</details>

<details><summary>Fix 4 — Fix WSUS conflict</summary>

```powershell
# If device was previously managed by WSUS and still has WSUS registry keys:

# Check current WSUS server
(Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate").WUServer

# Option A: Let Intune's WUfB policy clean this up
# Ensure device has a WUfB ring policy assigned
# The MDM ConfigureWindowsUpdate CSP should override, but sometimes doesn't if GPO wins

# Option B: Manual cleanup (use only if no active WSUS management)
$keys = @(
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate",
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
)
foreach ($key in $keys) {
    if (Test-Path $key) {
        Remove-Item $key -Recurse -Force
        Write-Host "Removed: $key"
    }
}
# Force update scan after cleanup
Start-Process "wuauclt.exe" -ArgumentList "/resetauthorization /detectnow"
```

**Warning:** Only run the manual cleanup if the device is confirmed NOT managed by WSUS. Removing these keys on an active WSUS-managed machine will break WSUS scanning until GPO re-applies.

</details>

<details><summary>Fix 5 — Reset Windows Update client</summary>

```powershell
# Stop Windows Update related services
$services = "wuauserv","bits","dosvc","usosvc","msiserver"
$services | ForEach-Object { Stop-Service $_ -Force -ErrorAction SilentlyContinue }

# Reset Windows Update component store (use with caution — takes 5-10 min)
Write-Host "Running DISM component cleanup..."
Start-Process "DISM.exe" -ArgumentList "/Online /Cleanup-Image /RestoreHealth" -Wait -NoNewWindow

# Clear Windows Update cache
Remove-Item -Path "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue

# Reset Windows Update components
"wuauserv","cryptSvc","bits","msiserver" | ForEach-Object {
    Start-Service $_ -ErrorAction SilentlyContinue
}

# Re-register Windows Update DLLs
$dlls = @("atl.dll","urlmon.dll","mshtml.dll","shdocvw.dll","browseui.dll",
          "jscript.dll","vbscript.dll","scrrun.dll","msxml.dll","msxml3.dll",
          "msxml6.dll","actxprxy.dll","softpub.dll","wintrust.dll","dssenh.dll",
          "rsaenh.dll","gpkcsp.dll","sccbase.dll","slbcsp.dll","cryptdlg.dll",
          "oleaut32.dll","ole32.dll","shell32.dll","initpki.dll","wuapi.dll",
          "wuaueng.dll","wucltui.dll","wups.dll","wups2.dll","wuweb.dll",
          "qmgr.dll","qmgrprxy.dll","wucltux.dll","muweb.dll","wuwebv.dll")
foreach ($dll in $dlls) {
    regsvr32.exe /s $dll
}

# Force re-scan
Start-Process "wuauclt.exe" -ArgumentList "/resetauthorization /detectnow"
Write-Host "Windows Update client reset complete. Check WU in Settings."
```

**Note:** This is a disruptive reset. Only use if WU client is clearly broken (download errors, client crash, persistent scan failures).

</details>

<details><summary>Fix 6 — Check and clear safeguard holds</summary>

```powershell
# Windows Update Safeguard Holds prevent updates on incompatible hardware/software
# Check via Windows Update medic logs or Windows Update portal

# 1. Check if a safeguard hold is blocking a specific update
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\TargetVersionUpgradeExperienceIndicators"
if (Test-Path $regPath) {
    Get-ItemProperty $regPath
}

# 2. Check via Windows Update for Business Compliance reports (Intune)
# Endpoint Manager → Reports → Windows Updates → Update compliance
# Look for devices showing "Safeguard hold" in Status column

# 3. Check for known driver safeguard holds
# Windows Update Catalog or https://learn.microsoft.com/en-us/windows/deployment/update/safeguard-holds
# Search for safeguard IDs shown in the Intune compliance report

# 4. If hold is due to an incompatible app or driver — update the driver/app
# If hold is due to hardware (e.g., specific NIC driver) — get updated driver from OEM

# 5. Override safeguard hold for testing (NOT for production — bypasses compatibility check)
# In the Intune Feature Update Profile:
# Allow override of safeguard holds = Yes
# OR set registry (test machines only):
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags"
New-ItemProperty $regPath -Name "UpgradeEligibility" -Value 1 -PropertyType DWORD -Force
```

**Note:** Safeguard holds exist for a reason. Overriding on a production fleet without resolving the root driver/app issue risks BSOD or app breakage after feature update. Escalate if the hold persists after driver updates.

</details>

---

## Escalation Evidence

```
=== WUfB ESCALATION — UPDATE NOT APPLYING ===

Date/Time:            [TIMESTAMP]
Reporter:             [YOUR NAME / TICKET ID]
Tenant:               [TENANT_NAME.onmicrosoft.com]
Affected Device(s):   [DEVICE_NAME(S)]
Expected OS Version:  [e.g., Windows 11 24H2]
Current OS Version:   [FROM DEVICE]
WUfB Ring Assigned:   [RING NAME FROM INTUNE]
Expected Deferral:    [DAYS]

--- MDM Policy Registry (device) ---
[PASTE: Get-ItemProperty HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update output]

--- GPO WU Policy (if any) ---
[PASTE: HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate output]

--- WSUS Config (if any) ---
[PASTE: UseWUServer / WUServer values]

--- Windows Update Service Status ---
[PASTE: Get-Service wuauserv,bits,dosvc,usosvc output]

--- Device Group Membership (relevant WUfB groups) ---
[LIST: Groups from Get-MgDeviceMemberOf]

--- Intune Device Status for Ring ---
[Intune portal: Device status = Succeeded / Pending / Failed / Conflict]

--- Windows Update Log Sample ---
[PASTE: Last 30 lines from C:\Users\[user]\Desktop\WindowsUpdate.log]

--- Fixes Attempted ---
[LIST each fix tried and result]
```

---

## 🎓 Learning Pointers

- **GPO + MDM conflict is the #1 WUfB issue.** If any Group Policy Object configures Windows Update settings, it can silently override Intune's WUfB MDM policy. GPO wins at the registry level unless the device is fully cloud-managed with no GPO WU settings. Always run `gpresult /H` first on hybrid-joined devices. [WUfB MDM conflicts](https://learn.microsoft.com/en-us/windows/deployment/update/waas-wufb-group-policy)

- **WSUS `UseWUServer=1` is a silent WUfB killer.** A device that previously pointed at WSUS and lost WSUS connectivity gets zero updates — not just no WSUS updates, but no Microsoft Update either. This hits devices migrated from on-prem GPO management to Intune without a clean WU policy handoff. [Migrating from WSUS to WUfB](https://learn.microsoft.com/en-us/windows/deployment/update/wufb-wsus)

- **Feature Update Profiles pin the OS version** — if your ring allows feature updates but a Feature Update Profile targets the device at an older build, the device stays on that older build until you update or remove the profile. Monitor for version drift in Intune compliance reports. [Feature Update profiles](https://learn.microsoft.com/en-us/mem/intune/protect/windows-10-feature-updates)

- **Safeguard holds are real and important.** Microsoft's compatibility telemetry blocks feature updates on devices with known problematic drivers or apps. Before declaring "WUfB broken," check the compliance report for safeguard hold IDs and resolve the underlying driver/software issue. [Safeguard holds](https://learn.microsoft.com/en-us/windows/deployment/update/safeguard-holds)

- **Update rings have two separate deferrals** — quality updates (security patches, monthly B release) and feature updates (annual OS version). Many engineers only set one. Always configure both, with quality deferral typically 7–14 days and feature deferral 60–180 days depending on the ring. [Update ring settings](https://learn.microsoft.com/en-us/mem/intune/protect/windows-update-for-business-configure)
