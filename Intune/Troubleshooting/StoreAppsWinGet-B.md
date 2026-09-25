# Intune Microsoft Store Apps (new) / WinGet Delivery — Hotfix Runbook (Mode B: Ops)
> Fix or escalate "Store app stuck at Install pending / Failed", "0x8A15001B", "0x87D1041C but the app is installed", "Requirements Not Met in Company Portal", or "Store apps fail during Autopilot" in under 10 minutes.

> **Context (Sept 2026):** The **Microsoft Store app (new)** app type in Intune doesn't use the old Microsoft Store for Business sync. The **Intune Management Extension (IME)** installs these apps through the **Windows Package Manager** (WinGet, shipped inside *Desktop App Installer*) from the `msstore` source. That means a Store app install has the same dependencies as a Win32 app: IME has to be present and healthy, Desktop App Installer has to be registered, and the device has to reach both the Store catalog **and** the publisher's content host (Win32 Store apps are hosted by the vendor). Two traps catch most admins. First, the **Turn off the Store application** policy does **not** block Intune installs. Second, **RequirePrivateStoreOnly** and the **DesktopAppInstaller** policies (`EnableAppInstaller`, `EnableMicrosoftStoreSource`) **can** block them. Sources: [Add Microsoft Store apps to Intune (Learn, ms.date 2026-06-25)](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-microsoft-store); [Troubleshoot app installation (Learn)](https://learn.microsoft.com/en-us/troubleshoot/mem/intune/app-management/troubleshoot-app-install).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Run elevated on the affected device. Allow about 60 seconds.

```powershell
# 1. IME present and running? (no IME = no Store-app (new) installs at all)
Get-Service IntuneManagementExtension -ErrorAction SilentlyContinue | Select-Object Status, StartType

# 2. Desktop App Installer (the WinGet engine) registered for the system?
Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller | Select-Object Name, Version, Status

# 3. Store / App Installer policies that CAN block Intune Store installs
'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore',
'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller',
'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ApplicationManagement',
'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DesktopAppInstaller' | ForEach-Object {
    if (Test-Path $_) { "`n== $_"; Get-ItemProperty $_ | Select-Object * -ExcludeProperty PS* | Format-List }
}

# 4. Last WinGet / Store errors from the IME app-install log
Select-String -Path "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\AppWorkload*.log" `
    -Pattern '0x8A15[0-9A-F]{4}|0x87D1041C|msstore|WinGet' | Select-Object -Last 25 | ForEach-Object Line

# 5. Can the device reach the Store + WinGet endpoints?
'storeedgefd.dsx.mp.microsoft.com','displaycatalog.mp.microsoft.com','cdn.winget.microsoft.com' |
    ForEach-Object { [pscustomobject]@{Host=$_; Tcp443=(Test-NetConnection $_ -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded} }
```

| Result | Meaning | Go to |
|---|---|---|
| IME service missing / stopped | Nothing can install Store (new) or Win32 apps | Fix 1 |
| DesktopAppInstaller missing, or `Status` isn't `Ok` | WinGet engine unavailable (common on de-bloated images and LTSC) | Fix 2 |
| `RequirePrivateStoreOnly = 1`, `EnableAppInstaller = 0`, or `EnableMicrosoftStoreSource = 0` | Policy blocks the WinGet msstore path (look for **0x8A15001B / 0x8A15001C** in the log) | Fix 3 |
| `RemoveWindowsStore = 1` (Turn off the Store application) | **Not the cause.** This policy doesn't block Intune installs. Keep looking. | — |
| `0x87D1041C` "not detected after install", but the app launches | UWP deployed in **System** context to a device where a user already had it | Fix 4 |
| Company Portal says **Requirements Not Met** | User-context UWP made **Available** on an **Entra registered** device | Fix 5 |
| A 443 test fails | Proxy/firewall is blocking the Store/CDN, or (for Win32 Store apps) the vendor's CDN | Fix 6 |
| `0x8A150011` / `0x8A150008` | Vendor installer hash mismatch or download failure (vendor-hosted Win32 Store app) | Fix 6 / escalate to vendor |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Store app (new) shows "Installed" in Intune
└── Detection succeeds (package present in the assigned context)
    └── WinGet install from msstore source exits 0
        ├── Package allowed by policy
        │   ├── RequirePrivateStoreOnly ≠ 1
        │   ├── DesktopAppInstaller: EnableAppInstaller ≠ 0, EnableMicrosoftStoreSource ≠ 0
        │   └── (RemoveWindowsStore / "Turn off Store app" = irrelevant to Intune)
        ├── Network: Store catalog + WinGet CDN + (Win32 Store apps) vendor content host
        ├── Install context valid
        │   ├── Entra registered device → System context only
        │   └── UWP System context → not already installed per-user
        ├── Architecture: ARM64-only installers not supported; ≥2 CPU cores
        └── Desktop App Installer (WinGet) registered & healthy
            └── Intune Management Extension installed & running
                └── Device MDM-enrolled, IME policy delivered (Win32/PS/Store assignment exists)
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm the app type in the portal.** Go to Apps → the app → Properties. It should show **Microsoft Store app (new)**, with a *Package Identifier* such as `9WZDNCRFJ3PZ` (UWP) or `XP...` (Win32). If it says **Microsoft Store app (legacy)** or **Microsoft Store for Business**, you're on a retired path. Recreate it as (new).

2. **Check that IME picked up the assignment.**
   ```powershell
   Select-String "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\AppWorkload*.log" -Pattern '<PackageIdentifier>' | Select-Object -Last 10
   ```
   *Good:* the package ID shows up, followed by an install and detection result. *Bad:* no hits at all. The assignment hasn't reached IME yet, so sync the device (Company Portal → Settings → Sync) and restart IME (Fix 1).

3. **Read the exit code.** `0x8A15xxxx` codes come from WinGet (`APPINSTALLER_CLI_ERROR_*`). `0x87D1xxxx` codes come from Intune/IME. The most common ones:

   | Code | Meaning | Fix |
   |---|---|---|
   | 0x8A15001B / 0x8A15001C | msstore source or app blocked by policy | 3 |
   | 0x8A150014 | No package found. Wrong region, a paid app, or delisted | Recreate the app / pick a region |
   | 0x8A150010 | No applicable installer. Often an ARM64-only or unsupported architecture | Use a Win32 app instead |
   | 0x8A150008 / 0x8A150011 | Download failure / installer hash mismatch | 6 |
   | 0x87D1041C | Installed but not detected | 4 |

4. **Reproduce the install as SYSTEM.** Run this only as a test, using PsExec or an equivalent tool:
   ```powershell
   $wg = (Resolve-Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" | Select-Object -Last 1).Path
   & $wg install --id <PackageIdentifier> --source msstore --accept-package-agreements --accept-source-agreements --scope machine
   ```
   *Good:* `Successfully installed`. *Bad:* the same `0x8A15…` code as the portal. That confirms the cause is on the device (policy, network, or engine) and not on the Intune side.

5. **Check the install context against the join type.** Run `dsregcmd /status | Select-String 'AzureAdJoined|WorkplaceJoined'`. If `WorkplaceJoined : YES` and `AzureAdJoined : NO`, only **System**-context assignments work.

---
## Common Fix Paths

<details><summary>Fix 1 — IME missing or unhealthy</summary>

```powershell
Restart-Service IntuneManagementExtension -Force
# If the service doesn't exist: IME only installs when the device has at least one
# Win32, PowerShell script, remediation or Store (new) assignment targeting the device/user.
# Verify the device is MDM-enrolled:
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' | ForEach-Object { Get-ItemProperty $_.PSPath } |
    Where-Object ProviderID -eq 'MS DM Server' | Select-Object UPN, EnrollmentState
```
If IME is still absent after a sync and a restart, see `App-Deployment-B.md` (IME install failures).
</details>

<details><summary>Fix 2 — Desktop App Installer missing or broken</summary>

```powershell
# Re-register for all users (use this when the package is present but broken)
Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller | ForEach-Object {
    Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppxManifest.xml" -ErrorAction Continue
}
# If it's missing entirely (stripped image / LTSC): provision the official msixbundle from
# https://aka.ms/getwinget together with its dependencies (VCLibs, UI.Xaml) using
# Add-AppxProvisionedPackage -Online -PackagePath <bundle> -DependencyPackagePath <deps> -SkipLicense
```
Rollback: none needed. Re-registering doesn't remove anything.
</details>

<details><summary>Fix 3 — Policy is blocking the msstore source (0x8A15001B / 0x8A15001C)</summary>

Find which source applies the value: Intune (the PolicyManager path) or GPO (the `Policies` path).

| Setting | Blocks Intune Store installs? | Set to |
|---|---|---|
| Only display the private store (RequirePrivateStoreOnly) | Can block the msstore source | Not configured |
| Enable App Installer (DesktopAppInstaller/EnableAppInstaller) | Yes when Disabled | Not configured or Enabled |
| Enable App Installer Microsoft Store Source (EnableMicrosoftStoreSource) | Yes when Disabled | Not configured or Enabled |
| Disable all apps from the Microsoft Store (DisableStoreOriginatedApps) | Stops Store apps from launching | Not configured |
| Turn off the Store application (RemoveWindowsStore) | **No** | Enabled is fine and is Microsoft's recommended lockdown |

To block users while keeping Intune working, use **Turn off the Store application = Enabled**. **Don't** use RequirePrivateStoreOnly for that.

```powershell
# After fixing the policy source, force a sync and retry
Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -TaskName 'Schedule #3 created by enrollment client' -ErrorAction SilentlyContinue | Start-ScheduledTask
Restart-Service IntuneManagementExtension -Force
```
If a GPO sets the value, fix it in the GPO. Deleting the registry value only lasts until the next `gpupdate`.
</details>

<details><summary>Fix 4 — 0x87D1041C on a System-context UWP app</summary>

This is documented behaviour. When a System-context (provisioned) UWP app is assigned to a device where the app is already installed per-user, Intune reports 0x87D1041C even though the app is present.
- Pick **one** context per app for the whole fleet. Don't mix User and System contexts.
- Check what's installed: `Get-AppxPackage -AllUsers -Name '*<AppName>*' | Select Name, PackageUserInformation`
- If System context is the right call, remove the per-user copies (`Remove-AppxPackage -Package <PackageFullName> -AllUsers`), then sync. Rollback: users can reinstall from the Store or Company Portal.
</details>

<details><summary>Fix 5 — "Requirements Not Met" on Entra registered (BYOD) devices</summary>

User-context UWP apps made Available to **Entra registered** devices show *Requirements Not Met*. Change the app's **Install behavior** to **System**. If System isn't selectable for that app, target Entra-joined devices only. No device-side fix exists.
</details>

<details><summary>Fix 6 — Network / download / hash failures</summary>

```powershell
netsh winhttp show proxy   # IME and WinGet run as SYSTEM, so they use the WinHTTP proxy, not the user's
```
- Allow the Microsoft Store endpoints from the Intune network endpoints list (the Microsoft Store section).
- **Win32 Store apps** download from the **vendor's** host, which isn't on Microsoft's list. Get the host from the vendor, or read it from the WinGet log: `%LOCALAPPDATA%\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir` (for SYSTEM this lives under the systemprofile path).
- `0x8A150011` (hash mismatch) usually means the vendor updated the installer before updating the Store listing. Retry later or raise it with the vendor. Don't bypass the hash check.
</details>

---
## Escalation Evidence
```
Tenant: <tenantName>            Device: <deviceName>   Intune Device ID: <deviceId>
App name: <appName>             Package Identifier: <packageId>   Installer type: UWP / Win32
Install behavior (portal): System / User     Assignment: Required / Available / Uninstall
Join type (dsregcmd): AzureAdJoined=__  WorkplaceJoined=__  DomainJoined=__
IME version: ______   DesktopAppInstaller version: ______   OS build: ______   Arch: x64 / ARM64
Error code (portal): ______     Error in AppWorkload.log (timestamp + line): ______
Policies present (RequirePrivateStoreOnly / EnableAppInstaller / EnableMicrosoftStoreSource): ______
Manual SYSTEM winget install result: ______
Endpoint 443 tests: storeedgefd=__  displaycatalog=__  winget CDN=__  vendor host=__
Script output attached: Get-StoreAppWinGetDiagnostics CSV  [ ]
```

---
## 🎓 Learning Pointers
- The "new" Store integration is **WinGet driven by IME**, so read Store failures the way you'd read Win32 failures: `AppWorkload.log` first, not the Store app. See [Add Microsoft Store apps to Intune](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-microsoft-store).
- **Turn off the Store application** is the right lockdown control. It doesn't affect Intune installs or UWP auto-update. RequirePrivateStoreOnly is a legacy control that Microsoft no longer recommends. See the "Common Store policy settings" section of the same page.
- `0x8A15xxxx` codes come from WinGet. Decode them with the official list in the winget-cli repo: [winget returnCodes.md](https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md).
- Win32 Store apps have **vendor-hosted content**. When the network looks fine but downloads fail, look at the vendor's CDN, not Microsoft's.
- Mixed install contexts cause most "installed but failed" reports. Pick System or User per app and stick with it. See [Troubleshooting app installation issues](https://learn.microsoft.com/en-us/troubleshoot/mem/intune/app-management/troubleshoot-app-install).
- Deep dive: `StoreAppsWinGet-A.md`. Collector script: `Scripts/Get-StoreAppWinGetDiagnostics.ps1`.
