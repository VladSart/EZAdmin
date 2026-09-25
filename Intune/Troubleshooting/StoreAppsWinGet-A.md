# Intune Microsoft Store Apps (new) / WinGet Delivery — Reference Runbook (Mode A: Deep Dive)
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
- **In scope:** the Intune app type **Microsoft Store app (new)** on Windows 10/11 (x64). That covers both UWP/MSIX packages and the Win32 (`.exe`/`.msi`) Store listings, the Store and App Installer policies that interact with it, and Store apps delivered during Autopilot/ESP.
- **Out of scope:** the retired Microsoft Store for Business/Education sync and the "Microsoft Store app (legacy)" type (migrate these, don't troubleshoot them); Win32 `.intunewin` apps (see `App-Deployment-A.md`); the Enterprise App Catalog (see `EnterpriseAppManagement-A.md`); and user-driven `winget` use outside Intune.
- **Assumes:** the device is MDM-enrolled, you have Intune Administrator or Application Manager rights, and you have local admin on the device to collect logs.
- **Status (Sept 2026):** Win32 Store apps are still **preview**. Regional selection in the portal search is temporarily unavailable, so searches default to the US catalog. ARM64 installers are unsupported. Source: [Add Microsoft Store apps to Intune (ms.date 2026-06-25)](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-microsoft-store).

---
## How It Works
<details><summary>Full architecture</summary>

**1. Control plane.** When you add a Store app (new), Intune stores a `winGetApp` object (Graph type `#microsoft.graph.winGetApp`). The object holds a `packageIdentifier` (the Store product ID, e.g. `9WZDNCRFJ3PZ` for UWP or `XP…` for Win32) and `installExperience.runAsAccount` (`system` | `user`). **No binary is uploaded.** Intune only stores a pointer to the Store catalog.

**2. Delivery agent.** Unlike legacy Store apps, which the MDM stack pushed through the EnterpriseModernAppManagement CSP, Store (new) apps are **IME workloads**. IME receives the assignment during its app check-in, which happens at startup, about every 60 minutes, and on Company Portal sync. It then evaluates applicability and detection, and calls the Windows Package Manager engine inside **Desktop App Installer** (`Microsoft.DesktopAppInstaller_8wekyb3d8bbwe`) to install from the `msstore` source.

```
Intune service ──(IME app check-in)──► IME (SYSTEM)
                                         │  AppWorkload.log
                                         ▼
                             Windows Package Manager engine
                             (Desktop App Installer package)
                                         │ msstore source
                    ┌────────────────────┴───────────────────┐
                    ▼                                        ▼
         UWP / MSIX package                         Win32 .exe/.msi listing
   Store CDN (Microsoft-hosted)               Installer URL → VENDOR host
   AppX deployment (per-user or              Silent switches from the Store
   provisioned for System context)           manifest; hash verified by WinGet
```

**3. Context model.**
- **User context (UWP):** the package is registered for the signed-in user only.
- **System context (UWP):** the package is **provisioned**, and every user who signs in gets it. Microsoft's own caveat: if an end user uninstalls it, it still shows as installed because it stays provisioned. It must not already be installed for any user, or detection reports **0x87D1041C** even though the app installed.
- **Win32 Store apps:** the listing itself decides whether the app is User or System. If the option is greyed out in the portal, that's why.
- **Entra registered devices:** these must use System context. A User-context *Available* app shows **Requirements Not Met** in Company Portal.

**4. Update model. This is the part people get wrong.**
- **UWP:** the **Store service** updates it, with or without an Intune assignment, unless `AllowAppStoreAutoUpdate` / *Turn off Automatic Download and Install of updates* blocks updates.
- **Win32 Store apps:** **Intune** keeps them updated, and only while an assignment exists. Store update policies **don't** affect them. If you remove the assignment, updates stop.
- **Required Win32 app not detected:** if the version or context doesn't match, Intune reinstalls it in the targeted context. For *Available* Win32 apps, Intune only takes over management after the user clicks Install in Company Portal.

**5. Policy interaction matrix.** This comes from Microsoft's "Common Store policy settings" table.

| Policy (CSP / GPO) | Effect on users | Effect on Intune Store (new) installs |
|---|---|---|
| ADMX_WindowsStore/RemoveWindowsStore ("Turn off the Store application") | Blocks Store browsing and manual updates | **None.** This is Microsoft's recommended lockdown. `winget.exe` isn't affected either. |
| ApplicationManagement/RequirePrivateStoreOnly | Blocks the Store UI | Legacy control, not recommended. Still lets the `winget` CLI reach the Store, so it's a weak lockdown. Can interfere with the msstore source in some builds. |
| ApplicationManagement/AllowAppStoreAutoUpdate (off) | — | Stops UWP updates. Win32 Store apps with an active assignment still update. |
| ApplicationManagement/DisableStoreOriginatedApps | Store apps won't launch | Installs may succeed but the apps are unusable |
| DesktopAppInstaller/EnableAppInstaller = Disabled | Blocks App Installer / WinGet | **Blocks** the WinGet engine that IME uses |
| DesktopAppInstaller/EnableMicrosoftStoreSource = Disabled | Removes the msstore source | **Blocks.** Typical errors are 0x8A15001B / 0x8A15001C. |

**6. Hard requirements.** At least 2 CPU cores, IME must be supported on the device, network access to the Store **and** the destination content, and a free (not paid) app that's available in the chosen region. ARM64 installers aren't supported.
</details>

---
## Dependency Stack
```
L7  Intune reporting: Installed / Failed (detection result)
L6  Detection: AppX package present (context-correct) | Win32 ARP/product present
L5  WinGet install from msstore  → exit code (0x8A15xxxx on failure)
L4  Policy gates: EnableAppInstaller, EnableMicrosoftStoreSource, RequirePrivateStoreOnly
L3  Network: Store catalog/CDN + WinGet CDN + vendor host (Win32), via WinHTTP proxy (SYSTEM)
L2  Desktop App Installer package registered (WinGet engine) + ≥2 cores, x64
L1  Intune Management Extension installed & running (IME app check-in)
L0  MDM enrollment + assignment targeting (user/device groups, filters)
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Stuck at "Install pending" for hours | IME not installed, not checking in, or assignment not yet received | `Get-Service IntuneManagementExtension`, then search AppWorkload.log for the package ID |
| 0x8A15001B / 0x8A15001C | A policy blocks the msstore source or the app | DesktopAppInstaller / RequirePrivateStoreOnly values (PolicyManager and Policies paths) |
| 0x8A150014 "no applications found" | Region mismatch, delisted, or paid app | Search the Store catalog in the portal again |
| 0x8A150010 "no applicable installer" | Architecture (ARM64) or OS applicability | `$env:PROCESSOR_ARCHITECTURE`, the listing's supported platforms |
| 0x8A150008 / 0x8A150011 | Download blocked, or vendor installer hash mismatch | Proxy (`netsh winhttp show proxy`), vendor CDN reachability |
| 0x87D1041C, but the app works | UWP in System context while already installed per-user | `Get-AppxPackage -AllUsers` → PackageUserInformation |
| "Requirements Not Met" in Company Portal | User-context Available app on an Entra registered device | `dsregcmd /status` |
| UWP app never updates | AllowAppStoreAutoUpdate disabled (Turn off Automatic Download…) | PolicyManager ApplicationManagement key |
| Win32 Store app stopped updating | Intune assignment removed (Intune owns Win32 Store updates) | App assignments in the portal |
| Store apps fail in ESP, work later | Desktop App Installer not yet registered/updated at OOBE, or the Store isn't reachable before the user signs in | ESP-Stuck-A.md; blocking-app list; Autopilot DevicePreparation |
| Users can still install from the Store despite lockdown | Only RequirePrivateStoreOnly is used (winget CLI still reaches the Store) | Switch to RemoveWindowsStore = Enabled |

---
## Validation Steps
1. **IME healthy.** `Get-Service IntuneManagementExtension` returns *Running / Automatic*. Bad: missing, which means no IME workload is assigned or the IME install failed.
2. **WinGet engine present.** `Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller` returns Status `Ok` and Version ≥ 1.2x. Bad: nothing returned, which is common on LTSC and heavily debloated images.
3. **Policy clean.** Neither `HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller` nor `...\PolicyManager\current\device\DesktopAppInstaller` contains `EnableAppInstaller=0` or `EnableMicrosoftStoreSource=0`. Bad: either value is 0.
4. **Network.** TCP 443 succeeds to `storeedgefd.dsx.mp.microsoft.com`, `displaycatalog.mp.microsoft.com` and `cdn.winget.microsoft.com` under the WinHTTP proxy. Bad: any failure, and a *SYSTEM* test fails even when the user's browser works.
5. **Context.** Portal Install behavior matches the join type. Entra registered devices must use System.
6. **Outcome.** AppWorkload.log shows the package ID with a successful install and detection. `Get-AppxPackage -AllUsers` (UWP) or ARP (Win32) shows the app.

---
## Troubleshooting Steps (by phase)
**Phase 1: Targeting.** Confirm the device or user is in the assigned group and not excluded by a filter. Device → Managed apps shows the app with a status. If the app isn't listed, the problem is targeting or check-in, not installation.

**Phase 2: Agent.** Check IME: service state, `IntuneManagementExtension.log` check-in lines, and that `AppWorkload.log` is being written. Restart IME to force an app check-in.

**Phase 3: Engine.** Check that Desktop App Installer is registered, and resolve `winget.exe` under `%ProgramFiles%\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\`. A SYSTEM-context `winget --info` should run without errors.

**Phase 4: Policy.** Enumerate the Store and App Installer policies from both sources (MDM PolicyManager and GPO `Policies`). GPO values win on refresh, so remove them at the source.

**Phase 5: Network.** Test from SYSTEM context. Check WinHTTP proxy and TLS inspection exclusions for `*.mp.microsoft.com` and the WinGet CDN. For Win32 listings, identify the vendor's host from the WinGet DiagOutputDir logs.

**Phase 6: Detection and context.** For 0x87D1041C, compare `PackageUserInformation` across users. Decide on a single context for the app and clean up the conflicting installs.

---
## Remediation Playbooks
<details><summary>Playbook 1 — Rebuild the WinGet engine on a device</summary>

```powershell
# Re-register existing Desktop App Installer for all users
Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller | ForEach-Object {
    Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppxManifest.xml"
}
Restart-Service IntuneManagementExtension -Force
```
If the package is absent, provision the signed bundle from `https://aka.ms/getwinget` plus its dependencies using `Add-AppxProvisionedPackage -Online`. At fleet scale, fix the golden image instead. Rollback: not required.
</details>

<details><summary>Playbook 2 — Correct Store lockdown without breaking Intune</summary>

Target state (Settings catalog):
- **Turn off the Store application** = Enabled (blocks users)
- **Allow apps from the Microsoft app store to auto update** = Allowed (keeps UWP current)
- **Only display the private store** = Not configured
- DesktopAppInstaller **EnableAppInstaller** / **EnableMicrosoftStoreSource** = Not configured or Enabled. These aren't in the Settings catalog, so use a custom OMA-URI profile if you must enforce them:
  - `./Device/Vendor/MSFT/Policy/Config/DesktopAppInstaller/EnableMicrosoftStoreSource` (ADMX-backed: `<enabled/>`)

Remove conflicting GPOs from hybrid-joined devices (`gpresult /h` → Windows Components → Store / Desktop App Installer). Rollback: re-enable the previous profile. The settings are non-destructive.
</details>

<details><summary>Playbook 3 — Resolve System vs User context conflicts (0x87D1041C)</summary>

```powershell
$name = '*<AppName>*'
Get-AppxPackage -AllUsers -Name $name | Select-Object Name, PackageFullName, @{n='Users';e={$_.PackageUserInformation.UserSecurityId.Username -join ';'}}
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $name
# Standardise on System: remove per-user copies (destructive to per-user app data)
# Get-AppxPackage -AllUsers -Name $name | Remove-AppxPackage -AllUsers
```
Then keep a single assignment (System) and delete any duplicate User-context app objects in Intune. Rollback: users reinstall from Company Portal. Per-user app data isn't recoverable.
</details>

<details><summary>Playbook 4 — Migrate off legacy Store / MSfB app objects</summary>

```powershell
Connect-MgGraph -Scopes 'DeviceManagementApps.Read.All'
# Legacy Store (MSfB/online) and legacy store-link apps
Get-MgDeviceAppManagementMobileApp -All -Filter "isof('microsoft.graph.windowsStoreApp') or isof('microsoft.graph.microsoftStoreForBusinessApp')" |
    Select-Object DisplayName, Id, @{n='Type';e={$_.AdditionalProperties.'@odata.type'}}
# Current Store (new) apps
Get-MgDeviceAppManagementMobileApp -All -Filter "isof('microsoft.graph.winGetApp')" |
    Select-Object DisplayName, Id, @{n='PackageId';e={$_.AdditionalProperties.packageIdentifier}}
```
For each legacy object, create a Store (new) equivalent, copy its assignments, and set the old one to **Uninstall** only if the new one uses the **same install context**. Otherwise remove the old assignment without uninstalling, or you'll get uninstall/reinstall churn.
</details>

<details><summary>Playbook 5 — Store apps during Autopilot / ESP</summary>

- Keep Store (new) apps **out of the ESP blocking list** unless they're truly required. Store availability and Desktop App Installer updates at OOBE are a known source of timeouts.
- Prefer device-targeted **System** context for apps that must be present before the user signs in.
- For Autopilot device preparation (v2), note the per-policy app limit and that only allowed app types are processed. See `Autopilot/Troubleshooting/DevicePreparation-A.md`.
</details>

---
## Evidence Pack
Run `Intune/Scripts/Get-StoreAppWinGetDiagnostics.ps1 -PackageId <PackageIdentifier>` elevated. It exports a CSV with IME, engine, policy, network, log and context findings. Also collect the IME logs:
```powershell
$out = "$env:TEMP\StoreAppEvidence_$(Get-Date -f yyyyMMdd_HHmm)"
New-Item $out -ItemType Directory -Force | Out-Null
Copy-Item "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\*" $out -ErrorAction SilentlyContinue
dsregcmd /status > "$out\dsregcmd.txt"
netsh winhttp show proxy > "$out\winhttp.txt"
Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller | Format-List * > "$out\DesktopAppInstaller.txt"
Compress-Archive "$out\*" "$out.zip" -Force; "Evidence: $out.zip"
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| IME state | `Get-Service IntuneManagementExtension` |
| Restart IME (forces an app check-in) | `Restart-Service IntuneManagementExtension -Force` |
| WinGet engine | `Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller` |
| Resolve winget.exe for SYSTEM | `Resolve-Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe"` |
| WinGet sources | `& $wg source list` |
| Test install as SYSTEM | `& $wg install --id <id> --source msstore --scope machine --accept-package-agreements --accept-source-agreements` |
| Store errors in the IME log | `Select-String "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\AppWorkload*.log" -Pattern '0x8A15'` |
| MDM Store policies | `Get-ItemProperty HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ApplicationManagement` |
| GPO Store policies | `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore` |
| App Installer policies | `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller` |
| Per-user vs provisioned UWP | `Get-AppxPackage -AllUsers -Name <n>`; `Get-AppxProvisionedPackage -Online` |
| Join type | `dsregcmd /status` |
| SYSTEM proxy | `netsh winhttp show proxy` |
| List Store (new) apps in the tenant | `Get-MgDeviceAppManagementMobileApp -All -Filter "isof('microsoft.graph.winGetApp')"` |

---
## 🎓 Learning Pointers
- [Add Microsoft Store apps to Microsoft Intune](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-microsoft-store) is the authoritative source for the context rules, the update ownership split (Store for UWP, Intune for Win32), and the policy impact table this runbook is built on.
- [Intune Management Extension](https://learn.microsoft.com/en-us/intune/device-management/tools/management-extension-windows): Store (new) is an IME workload, so every IME prerequisite and log applies.
- [Policy CSP – DesktopAppInstaller](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-desktopappinstaller) lists the policies that can silently disable the engine IME depends on.
- [winget-cli return codes](https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md) decodes every `0x8A15xxxx` value you'll see in AppWorkload.log.
- [Intune network endpoints — Microsoft Store](https://learn.microsoft.com/en-us/intune/fundamentals/endpoints#microsoft-store): remember that Win32 Store listings add a vendor host on top.
- Related: `App-Deployment-A.md` (Win32/IME), `EnterpriseAppManagement-A.md` (Enterprise App Catalog), `Autopilot/Troubleshooting/ESP-Stuck-A.md`.
