# Intune App Deployment — Hotfix Runbook (Mode B: Ops)
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

Run these first — gives you 80% of the answer in under 2 minutes.

**1. Check assignment and install status in Intune portal**
```
Intune portal → Apps → All apps → [select app] → Device install status
Filter by: Failed / Not installed
Note: Error code in the "Error" column — look up at aka.ms/intuneappinstall
```

**2. Check sync status on the device**
```powershell
# Run locally on affected device (or via Intune Remediations/Live Response)
$imeSvc = Get-Service -Name IntuneManagementExtension -ErrorAction SilentlyContinue
$imeSvc | Select-Object Status, StartType

# Check last sync
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Logging" -ErrorAction SilentlyContinue
```

**3. Pull IME log snippet for the failing app**
```powershell
# Run on device — find the app by name in IME log
$imePath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
Select-String -Path $imePath -Pattern "<AppNameKeyword>" -Context 5,5 | Select-Object -Last 30
```

**4. Check if Win32 app content is downloadable (CDN connectivity)**
```powershell
# Intune uses Azure CDN for Win32 app content delivery
Test-NetConnection -ComputerName "swda02.manage.microsoft.com" -Port 443
Test-NetConnection -ComputerName "geo.cdn.office.net" -Port 443
```

**5. Check detection rule is evaluating correctly**
```powershell
# For registry detection rule — run on device:
Get-ItemProperty -Path "HKLM:\<RegistryPath>" -Name "<ValueName>" -ErrorAction SilentlyContinue

# For file detection:
Test-Path "<FilePath>"
```

**Interpretation:**

| Finding | Action |
|---------|--------|
| Install status: "Not applicable" | Check assignment — device/user not in target group, or filter excluded it |
| Error code 0x87D30068 / -2016345000 | App requirements not met (OS version, architecture, disk space) — Fix 1 |
| Error code 0x80070005 / Access denied | App runs as SYSTEM but needs user context, or path permission issue — Fix 2 |
| Error code 0x87D1041C / -2016407524 | Supersedence conflict or dependency not installed — Fix 3 |
| Error code 0x80070643 / Install failure | Detection rule mismatch or installer error — Fix 4 |
| IME service stopped | Restart IME — Fix 5 |
| CDN unreachable | Network/proxy issue — Fix 6 |
| Detection rule passes but portal shows "Not installed" | Force re-evaluation — Fix 7 |

---

## Dependency Cascade

<details><summary>What must be true for a Win32 app to install</summary>

```
[Intune Service assigns app to device/user]
        │
        ▼
[Device checks in to Intune (MDM sync)]  ← Requires AAD connectivity + valid enrollment
        │
        ▼
[IME (IntuneManagementExtension) service running on device]
        │
        ▼
[App policy downloaded by IME]
        │
        ▼
[Requirement rules evaluated]  ← OS version, disk space, architecture, custom rules
        │  (if any requirement fails → "Not Applicable")
        ▼
[Dependency apps installed first]  ← If app has dependencies configured
        │
        ▼
[App content downloaded from Azure CDN]  ← Requires HTTPS access to *.manage.microsoft.com, *.delivery.mp.microsoft.com
        │
        ▼
[App content extracted from .intunewin package]
        │
        ▼
[Install command runs]  ← As SYSTEM (device context) or logged-in user (user context)
        │
        ▼
[Detection rule evaluated]  ← MSI product code, registry key, file path, or custom script
        │
        ▼
[Result reported back to Intune (success/failure + exit code)]
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the device is in scope**
```powershell
# Check: is the device in the target group?
# In Intune portal: Apps → [App] → Properties → Assignments
# Under "Required" or "Available" group — confirm device/user group includes this device

# Check filters (if assignment uses a filter):
# Intune portal → Apps → [App] → Assignments → Assignment filter
# Preview the filter against the device to see if it matches
```

**Step 2 — Force an Intune sync and watch IME**
```powershell
# On the device — trigger sync
Start-Process -FilePath "C:\Windows\System32\cmd.exe" -ArgumentList '/c deviceenroller.exe /o /o /omadmid' -WindowStyle Hidden
# Or via Settings → Accounts → Access work or school → Info → Sync

# Then watch IME log in real time:
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Wait -Tail 50
```

Expected: Lines like `[Win32App] Entering stage: DetectedOrInstalled` = app is detected, OK.
Bad: `[Win32App] Exit code: 1603` or `[Win32App] Failed to download content` = specific failure.

**Step 3 — Read the error code**

IME log will contain an exit code or error. Map it:
```powershell
# Common exit codes:
# 0        = Success
# 1707     = Success (MSI)
# 3010     = Success, reboot required
# 1603     = Fatal error during install (often permissions or VC++ runtime)
# 1618     = Another install in progress
# 1641     = Initiated a restart
# 0x80070005 = Access denied
# 0x87D30068 = Requirements not met

# Check the full error in IME log:
Select-String -Path "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" `
    -Pattern "(?i)(fail|error|exit code)" | Select-Object -Last 20 | ForEach-Object { $_.Line }
```

**Step 4 — Verify detection rule manually**
```powershell
# MSI detection — check product code:
Get-WmiObject -Class Win32_Product | Where-Object { $_.IdentifyingNumber -eq "{<ProductCode>}" }

# Registry detection:
Get-ItemProperty -Path "HKLM:\<KeyPath>" -Name "<ValueName>" -ErrorAction SilentlyContinue

# File detection:
Test-Path "<FullFilePath>"
```

If detection rule passes manually but Intune shows "Not installed": the detection result cache is stale — Fix 7.

---

## Common Fix Paths

<details><summary>Fix 1 — Requirements rule excluding the device</summary>

**When:** Portal shows "Not applicable" — the device is in the assignment group but the app never attempts to install.

1. Intune portal → Apps → [App] → Properties → Requirements
2. Review: OS version, OS architecture (32/64-bit), disk space, custom requirement rule
3. On the device:
```powershell
# Check OS version
[System.Environment]::OSVersion.Version
(Get-ComputerInfo).WindowsProductName

# Check architecture
[System.Environment]::Is64BitOperatingSystem

# Check free disk on C:
(Get-PSDrive C).Free / 1GB
```
4. If the device legitimately doesn't meet requirements, the assignment is correct
5. If the requirements are wrong, update them in the App → Properties → Requirements and save

**Rollback:** N/A — requirement rule change is immediate but only affects future evaluations.

</details>

<details><summary>Fix 2 — Install context mismatch (SYSTEM vs. User)</summary>

**When:** Exit code 0x80070005 (Access denied), or app requires user context (e.g. needs to write to HKCU, user profile, or display a UI).

```powershell
# Check current install context in app config:
# Intune portal → Apps → [App] → Properties → Program
# "Install behavior": Device (= SYSTEM) vs. User (= logged-in user)

# For apps that write to HKCU or need a user session:
# Change to "User" context
# Note: user must be logged in at install time for user context to work

# Verify which account IME ran the installer as:
Select-String -Path "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" `
    -Pattern "(?i)(install context|running as)" | Select-Object -Last 5
```

**Change install context:** Intune portal → Apps → [App] → Edit → Program tab → Install behavior → change System/User → Save → wait for policy sync.

**Rollback:** Change install behavior back to previous setting.

</details>

<details><summary>Fix 3 — Dependency or supersedence conflict</summary>

**When:** Error code 0x87D1041C, or an app with dependencies never installs.

```powershell
# Check app dependencies in portal:
# Intune portal → Apps → [App] → Properties → Dependencies
# Each dependency must be installed successfully before the parent app can run

# Check if dependency is installed on device:
# (Replace with actual app name/detection)
Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*<DependencyName>*" } |
    Select-Object Name, Version, InstallDate
```

1. If dependency isn't installed: check why the dependency itself is failing (treat it as a separate app deployment failure)
2. If supersedence is configured: older version may need to be uninstalled first. Check: Apps → [App] → Properties → Supersedence
3. Ensure supersedence "Uninstall previous version" is toggled if needed

**Rollback:** Remove dependency or supersedence relationship in app properties.

</details>

<details><summary>Fix 4 — Detection rule mismatch causing loop</summary>

**When:** App appears to install (exit code 0) but portal keeps showing "Not installed" or keeps retrying.

The detection rule is evaluating to "not detected" even after the install succeeds.

```powershell
# Step 1: Manually test what the detection rule is looking for
# From Intune portal, note the detection type and value

# Registry example:
$regPath  = "HKLM:\SOFTWARE\<Vendor>\<App>"
$regValue = "Version"
$expected = "1.2.3"
$actual   = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).$regValue
Write-Host "Expected: $expected | Actual: $actual | Match: $($actual -eq $expected)"

# File example:
$filePath = "C:\Program Files\<App>\app.exe"
Write-Host "File exists: $(Test-Path $filePath)"
if (Test-Path $filePath) {
    $version = (Get-Item $filePath).VersionInfo.FileVersion
    Write-Host "File version: $version"
}

# MSI example:
$productCode = "{<GUID>}"
$installed = Get-WmiObject -Class Win32_Product |
    Where-Object { $_.IdentifyingNumber -eq $productCode }
Write-Host "MSI installed: $($null -ne $installed)"
```

If the detection rule is checking the wrong path/value: update it in the app properties → Detection rules.

**Rollback:** Detection rule changes only affect future evaluations — no device state is changed.

</details>

<details><summary>Fix 5 — IME service stopped or crashed</summary>

**When:** IME log not updating, no activity in portal for the device, or `Get-Service IntuneManagementExtension` shows Stopped.

```powershell
# Check status
$ime = Get-Service -Name IntuneManagementExtension
$ime | Select-Object Status, StartType

# Restart
Restart-Service IntuneManagementExtension -Force
Start-Sleep 5
Get-Service IntuneManagementExtension | Select-Object Status

# If it won't start — check Application event log for crash details
Get-WinEvent -LogName Application -MaxEvents 20 |
    Where-Object { $_.ProviderName -like "*IntuneManagementExtension*" } |
    Select-Object TimeCreated, LevelDisplayName, Message

# If IME is corrupted — re-enroll or repair:
# Option A: Force re-install of IME agent via Intune sync (re-enroll)
# Option B: Re-run deviceenroller.exe (doesn't fully repair IME)
# Option C: Escalate to full device re-enrollment if IME binary is corrupted
```

**Rollback:** N/A — restarting IME is non-destructive.

</details>

<details><summary>Fix 6 — CDN / network connectivity blocking content download</summary>

**When:** IME log shows `Failed to download content`, `CDN error`, or `HTTP 407` (proxy auth).

```powershell
# Test required endpoints
$endpoints = @(
    "swda02.manage.microsoft.com",
    "fef.msuc03.manage.microsoft.com",
    "geo.cdn.office.net",
    "dl.delivery.mp.microsoft.com"
)
foreach ($ep in $endpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{
        Endpoint = $ep
        TcpSuccess = $result.TcpTestSucceeded
        PingSuccess = $result.PingSucceeded
    }
}

# Check if proxy is interfering with SSL inspection:
# If using Zscaler, Netskope, or similar: the SSL inspection cert must be trusted by the device
# Check: certlm → Trusted Root CAs → look for your proxy cert
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*<ProxyVendor>*" }

# Check WinHTTP proxy settings:
netsh winhttp show proxy
```

If proxy is interfering: add `*.manage.microsoft.com` and `*.delivery.mp.microsoft.com` to proxy SSL bypass list. Reference: https://docs.microsoft.com/en-us/mem/intune/fundamentals/intune-endpoints

</details>

<details><summary>Fix 7 — Force re-evaluation of detection and reinstall</summary>

**When:** App shows stale state, detection should pass but portal is stuck, or you just updated a detection rule and want it re-evaluated immediately.

```powershell
# Clear IME app state cache to force re-evaluation
# ⚠️ This will cause ALL assigned apps to be re-evaluated on next sync

$imeCachePath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Context"
$backupPath   = "C:\Temp\IME-Context-Backup-$(Get-Date -Format yyyyMMdd-HHmmss)"

if (Test-Path $imeCachePath) {
    Copy-Item -Path $imeCachePath -Destination $backupPath -Recurse -Force
    Write-Host "Backed up to: $backupPath"
    
    Stop-Service IntuneManagementExtension -Force
    Remove-Item -Path "$imeCachePath\*" -Recurse -Force
    Start-Service IntuneManagementExtension
    Write-Host "IME cache cleared. Re-evaluation will occur on next sync."
} else {
    Write-Host "Cache path not found — check IME installation."
}

# Trigger sync
Start-Process "ms-settings:workplace" -ErrorAction SilentlyContinue
```

**Rollback:** Restore from `$backupPath` if apps enter unexpected state.

</details>

---

## Escalation Evidence

```
=== Intune App Deployment — Escalation Evidence ===

Date/Time: _______________
Device Name: _______________
Device AAD Object ID: _______________
Intune Device ID: _______________
OS Version: _______________
Enrolled? Yes / No    Compliant? Yes / No

App Name: _______________
App Type: Win32 / MSI / LOB / Store / Web clip
App version in portal: _______________
Assignment type: Required / Available / Uninstall
Target group: _______________

Install status in portal: Not installed / Failed / Not applicable
Error code from portal: _______________

IME log error snippet:
  _______________

Detection rule type: MSI Product Code / Registry / File / Script
Detection check result on device (manual):
  _______________

Install context: Device (SYSTEM) / User
Dependencies configured: Yes / No  (if yes, list: _______________)
Supersedence configured: Yes / No

Network checks:
  swda02.manage.microsoft.com 443: Reachable / Blocked
  geo.cdn.office.net 443: Reachable / Blocked
  Proxy in use: Yes / No  (type: _______________)

IME service status: Running / Stopped
Last successful Intune sync: _______________

Steps already taken:
  [ ] Forced sync
  [ ] Restarted IME
  [ ] Cleared IME cache
  [ ] Checked detection rule manually

Escalating to: [ ] Intune Admin  [ ] Network Team  [ ] App Packaging Team
```

---

## 🎓 Learning Pointers

- **Exit code 3010 is success — don't treat it as a failure.** It means the install succeeded and a reboot is required. Intune will show the app as "Pending reboot" not "Failed". Configure reboot behaviour in the App → Program tab → Device restart behaviour. Reference: https://docs.microsoft.com/en-us/mem/intune/apps/apps-win32-app-management

- **Win32 apps require the Intune Management Extension (IME) — it's not part of MDM enrollment.** IME is deployed automatically when a Win32 app is first assigned to a device. If it fails to install, no Win32 apps will ever deploy. Check: `C:\Program Files (x86)\Microsoft Intune Management Extension`. If missing, ensure the device has Intune licence and AAD connectivity, then trigger a sync.

- **Detection rules run after every sync, not just at install time.** If someone manually uninstalls an app that has a "Required" assignment, Intune will reinstall it on the next check-in (typically within 8 hours, or sooner with a forced sync). This is by design — use "Available" assignment if users should be able to uninstall.

- **The `.intunewin` package must be re-wrapped if you change the source installer.** Updating the source EXE/MSI without re-wrapping with the `IntuneWinAppUtil.exe` tool and re-uploading will deploy the old content. Always check the app version in portal matches what you expect. Reference: https://docs.microsoft.com/en-us/mem/intune/apps/apps-win32-prepare

- **Filters (assignment filters) can silently exclude devices.** If an app is assigned to a group the device is in, but a filter is applied that the device doesn't match, the result is "Not applicable" — indistinguishable from a requirements failure in the device's install status column. Always check the assignment filter as part of triage.
