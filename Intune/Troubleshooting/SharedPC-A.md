# Shared PC Mode (Shared / Multi-User Windows Devices) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

> **Currency (Sept 2026):** The SharedPC CSP node set hasn't changed since Windows 11 22H2 added `EnableSharedPCModeWithOneDriveSync` and `EnableWindowsInsiderPreviewFlighting`. In Intune, configure it through **Settings catalog → Shared PC**. The older *Shared multi-user device* template still exists, and so does custom OMA-URI. Primary sources: [SharedPC CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/sharedpc-csp), [Configure a shared or guest Windows device](https://learn.microsoft.com/en-us/windows/configuration/shared-pc/set-up-shared-or-guest-pc), [Shared PC technical reference](https://learn.microsoft.com/en-us/windows/configuration/shared-pc/shared-pc-technical), [Intune shared device settings](https://learn.microsoft.com/en-us/intune/device-configuration/templates/ref-shared-device-settings-windows); community: [Peter van der Woude](https://petervanderwoude.nl/post/managing-account-management-on-shared-pcs/), [Simon Skotheimsvik](https://skotheimsvik.no/the-ultimate-guide-to-intune-powered-windows-11-shared-devices).

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
- **In scope:** Windows 10/11 devices that many named users sign in to one at a time (labs, hot desks, shift-worker PCs, classroom carts, front-desk PCs). Covers Shared PC mode, Account Manager profile lifecycle, Guest/Kiosk sign-in tiles, OneDrive interaction, power/maintenance behaviour, and exemptions.
- **Adjacent, not duplicated:** single-app and multi-app **kiosk / Assigned Access** (`Intune/Troubleshooting/Kiosk-A.md`), **multi-session** Windows (AVD, `Azure/AVD/`), profile corruption and FSLogix (`Windows/Troubleshooting/UserProfile-A.md`), and **Windows 365 Frontline shared mode** (`Azure/Windows365/`).
- **Assumptions:** the devices are Entra-joined or hybrid-joined and Intune-managed, and you have Intune Policy and Profile Manager (or higher) rights. On the device you can run as SYSTEM (psexec or a remediation script) for MDM Bridge reads.

---
## How It Works
<details><summary>Full architecture</summary>

### Two parts: an action and a set of parameters
The SharedPC CSP has **action nodes** and **parameter nodes**:

| Type | Nodes |
|---|---|
| Action (triggers setup) | `EnableSharedPCMode` · `EnableSharedPCModeWithOneDriveSync` (Win11 22H2+) |
| Account Manager | `EnableAccountManager`, `DeletionPolicy` (0 immediate / **1 disk threshold (default)** / 2 disk + inactivity), `DiskLevelDeletion` (default **25**%), `DiskLevelCaching` (default **50**%), `InactiveThreshold` (default **30** days) |
| Sign-in model | `AccountModel` (**0 guest-only (default)** / 1 domain-joined only / 2 both), `KioskModeAUMID`, `KioskModeUserTileDisplayText` |
| Device behaviour | `SetPowerPolicies`, `SleepTimeout` (default 300 s), `SignInOnResume`, `MaintenanceStartTime` (minutes after midnight, default 0), `MaxPageFileSizeMB` (only on < 32 GB storage with ≥ 3 GB RAM), `RestrictLocalStorage`, `SetEduPolicies`, `EnableWindowsInsiderPreviewFlighting` |

Almost every parameter node carries the note *"If used, this value must be set before the action on the EnableSharedPCMode node is taken."* When the action fires, Shared PC setup **reads the parameters at that moment**, writes its LGPO settings and account-management configuration, and records what it applied under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\NodeValues` and `...\AccountManagement`. Parameters that arrive later are stored by the CSP but may not be acted on until the action runs again. That's why "we changed the threshold in Intune and nothing happened" is the most common escalation.

> ⚠️ **AccountModel default = 0 (guest-only).** The CSP default allows only guest accounts. The Intune UI usually sets this explicitly, but a hand-built custom OMA-URI profile that leaves out `AccountModel` can produce a device where domain/Entra users can't sign in as expected. Always set it explicitly (1 or 2 for organisational users).

### What "on" changes
Enabling runs setup, which writes LGPO settings. The exact list is in the Shared PC technical reference. The main groups are: sign-in experience and fast user switching behaviour, removal of some consumer features, profile/account policies, and, if you use `SetPowerPolicies`/`SetEduPolicies`, the power and education bundles. Apps can detect the mode through `Windows.System.Profile.SharedModeSettings.IsEnabled` and `ShouldAvoidLocalStorage`. Some Store apps change their behaviour because of it.

**OneDrive:** plain `EnableSharedPCMode` **turns off OneDrive sync**. The OneDrive variant (22H2+) keeps it available, which is essential if you rely on Known Folder Move to protect user data before Account Manager deletes profiles.

### Account Manager lifecycle
```
             FreePct ≥ DiskLevelCaching (50%) ─── stop deleting
                         ▲
   caching band          │   (profiles cached, nothing deleted)
                         │
             FreePct < DiskLevelDeletion (25%) ─── start deleting, oldest LastUse first,
                                                   during daily maintenance while idle
             FreePct < DiskLevelDeletion / 2 ───── delete immediately at sign-out, even if in use
Policy 2 adds: any profile unused ≥ InactiveThreshold days is eligible at maintenance
Policy 0: delete at sign-out, always
Guest / Kiosk accounts: deleted at sign-out, always
Never deleted: local accounts that pre-date enablement, local accounts created via Settings afterwards,
               any SID with a key under ...\SharedPC\Exemptions\
```
Consequences:
- **Maintenance-window dependency.** Idle-time deletion only happens while the device is powered on during the window that starts at `MaintenanceStartTime`. Devices switched off overnight with the default 00:00 window may never clean up.
- **The deleted profile is gone.** No recycle bin, no backup. Pair it with OneDrive KFM or another data-at-rest strategy.
- **Entra ID and AD accounts are handled the same way.** Local accounts are deliberately left alone, so a technician's local account won't disappear, but local accounts also never get cleaned up. For those, use the GPO *Delete user profiles older than a specified number of days on system restart*.

### Delivery channels
1. **Intune Settings catalog (Shared PC category)** is the recommended route. One profile per device, containing the parameters **and** the action.
2. **Intune "Shared multi-user device" template** is older. Don't mix it with a Settings catalog profile on the same device.
3. **Custom OMA-URI** (`./Vendor/MSFT/SharedPC/<Node>`) gives full control, but you must include every parameter yourself, including `AccountModel`.
4. **Provisioning package (WCD → SharedPC)** is used for staging before enrollment. The action runs during provisioning.
5. **MDM Bridge WMI** (`root\cimv2\mdm\dmmap`, class `MDM_SharedPC`, running as SYSTEM) is used for scripted or lab setup. Set all properties, then the action property, in one `Set-CimInstance`.
</details>

---
## Dependency Stack
```
L6  User data strategy: OneDrive KFM (needs *WithOneDriveSync*), FSLogix/roaming, or "stateless by design"
L5  Account Manager behaviour: policy 0/1/2, thresholds, InactiveThreshold, exemptions, maintenance window + power state
L4  Shared PC setup result: LGPO written, NodeValues/AccountManagement keys, SharedPCSetup.log, IsEnabled=True
L3  Action node fired AFTER parameters landed (same profile; single source of truth; no template/catalog conflict)
L2  Management channel: Intune MDM (Settings catalog / template / OMA-URI) | PPKG | MDM Bridge WMI as SYSTEM
L1  Identity/sign-in: AccountModel permits org users; Entra/hybrid join healthy; (Guest/Kiosk tiles if enabled)
L0  Windows 10 1607+/11, Pro/Enterprise/Education/IoT Enterprise; Win11 22621+ for OneDrive variant; disk sized for caching band
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Intune says Succeeded, `IsEnabled` False | Enable action failed during setup | `SharedPCSetup.log` |
| Setting changes don't take effect | Parameters changed after the action fired | NodeValues vs profile |
| Profiles never deleted | Policy 1 and disk never below 25%, or device off during maintenance | Free %, MaintenanceStartTime, power schedule |
| Profiles deleted "randomly" mid-week | Emergency delete (< half of DiskLevelDeletion) at sign-out, or policy 0 | Free % history, DeletionPolicy |
| Specific user always loses their profile | Policy 0, or their data was never in OneDrive | DeletionPolicy, OneDrive status |
| Local admin profile survived cleanup | By design (local account) | Expected |
| Service/break-glass Entra account profile deleted | Not exempted | `...\SharedPC\Exemptions` |
| Exemption added but profile still deleted | Wrong SID (resolved on another device, or before first sign-in) | Translate the SID back to a name |
| Org users can't sign in, only Guest works | `AccountModel` = 0 (CSP default) via custom OMA-URI | NodeValues AccountModel |
| Guest tile appears unexpectedly | `AccountModel` = 2 | NodeValues |
| OneDrive won't sync, KFM errors | Plain `EnableSharedPCMode` | Use the OneDrive variant (22H2+) |
| Users can't see C:\ in Explorer | `RestrictLocalStorage` = true | NodeValues |
| PC sleeps after 5 minutes in a lab | `SetPowerPolicies`/`SleepTimeout` default 300 s | NodeValues SleepTimeout |
| Password prompt on every wake | `SignInOnResume` = true | Expected |
| Insider builds offered on shared PCs | `EnableWindowsInsiderPreviewFlighting` = true | NodeValues |
| Two Shared PC profiles show "Conflict" | Template + Settings catalog both targeted | Intune per-setting status |

---
## Validation Steps
1. **Edition/build:** `Get-CimInstance Win32_OperatingSystem | Select Caption, BuildNumber`. Good: Pro/Ent/Edu/IoT Ent. Build ≥ 22621 if you're using the OneDrive variant.
2. **Mode live:** `[Windows.System.Profile.SharedModeSettings]::IsEnabled` → `True`.
3. **Effective values:** `Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\NodeValues`. The values should match the Intune profile exactly.
4. **Account management config:** `...\SharedPC\AccountManagement` should be present when `EnableAccountManager` = true.
5. **Setup log clean:** `Select-String C:\Windows\SharedPCSetup.log -Pattern 'error|fail'` should return nothing recent.
6. **Exemptions resolve:** each subkey under `...\SharedPC\Exemptions` translates to the intended account.
7. **Disk band:** the current free % relative to 25/50 (or your custom values) tells you whether deletion *should* be running now.
8. **Maintenance reachability:** `powercfg /waketimers`, and the power settings or schedule show the device is on at `MaintenanceStartTime`.
9. **OneDrive** (if used): signed-in user → OneDrive running and KFM healthy (`HKCU\Software\Microsoft\OneDrive\Accounts\Business1\KfmFoldersProtectedNow` is non-zero where present).

---
## Troubleshooting Steps (by phase)
**Phase 1 — Design.** Decide the data strategy (OneDrive KFM, FSLogix, or stateless) **before** picking `DeletionPolicy`. Size the disk so the caching band makes sense. Decide which accounts must be exempt. Choose `AccountModel` explicitly.

**Phase 2 — Delivery.** Use one profile with all parameters plus the action. Avoid splitting it across profiles or mixing the template with the Settings catalog. For Autopilot, assign it to the **device** group so it lands during ESP, before users sign in and create profiles that later count against thresholds.

**Phase 3 — Setup.** If `IsEnabled` is False, the log explains why (edition, pending reboot, conflicting policy). Fix the cause, then re-trigger the action (Playbook 1).

**Phase 4 — Runtime.** Check deletion complaints against disk %, maintenance window and power state. Check unexpected deletions against policy 0, the emergency threshold, and missing exemptions.

**Phase 5 — Change management.** Treat every parameter change as a re-provision: pilot ring, re-trigger, validate NodeValues, then widen.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Re-apply Shared PC with new parameters (pilot first)</summary>

**Option A (Intune):** update the profile. Temporarily assign an override profile with the action node = false to the pilot device. Sync, verify `IsEnabled` = False, remove the override, sync again, then verify the new NodeValues.

**Option B (MDM Bridge, run as SYSTEM, pilot/lab):**
```powershell
$ns = 'root\cimv2\mdm\dmmap'
$obj = Get-CimInstance -Namespace $ns -ClassName MDM_SharedPC
$obj.AccountModel = 1
$obj.EnableAccountManager = $true
$obj.DeletionPolicy = 2
$obj.DiskLevelDeletion = 25
$obj.DiskLevelCaching = 50
$obj.InactiveThreshold = 14
$obj.MaintenanceStartTime = 720
$obj.EnableSharedPCModeWithOneDriveSync = $true   # or EnableSharedPCMode on Win10
Set-CimInstance -CimInstance $obj
```
If the device is Intune-managed, Intune re-asserts its own values at the next sync. Make the profile the source of truth, and use this option only for unmanaged lab units or to confirm behaviour.
**Rollback:** set the action property to `$false` with `Set-CimInstance`, or re-image. Deleted profiles can't be recovered.
</details>

<details><summary>Playbook 2 — Fleet-wide exemptions via Intune remediation</summary>

Detection (exit 1 if missing):
```powershell
$accounts = @('<AzureAD\svc-frontdesk@contoso.com>', '<.\LocalSupport>')
$base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\Exemptions'
$missing = foreach ($a in $accounts) {
    try { $sid = (New-Object System.Security.Principal.NTAccount($a)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { continue }
    if (-not (Test-Path "$base\$sid")) { $a }
}
if ($missing) { Write-Output "Missing: $($missing -join ', ')"; exit 1 } else { exit 0 }
```
Remediation: the same loop with `New-Item -Path "$base\$sid" -Force`. Accounts whose SID can't be resolved yet (an Entra user who has never signed in on that device) are skipped and picked up on a later run.
**Rollback:** remove the SID subkeys.
</details>

<details><summary>Playbook 3 — Move a Windows 10 shared fleet to OneDrive-compatible Shared PC</summary>

1. Upgrade the devices to Windows 11 (22H2 or later).
2. In the profile, swap `EnableSharedPCMode` for `EnableSharedPCModeWithOneDriveSync`. Don't configure both.
3. Deploy the OneDrive silent sign-in and KFM policies to the same devices.
4. Re-trigger (Playbook 1), then validate as a test user that OneDrive is running and KFM is protected.
5. Only then tighten `DeletionPolicy` (for example to 2 with a short `InactiveThreshold`).
</details>

<details><summary>Playbook 4 — Emergency disk-space relief without disabling Shared PC</summary>

Run Fix 3 from `SharedPC-B.md` (manual profile removal with `-WhatIf` first), then clear the Windows Update cache (`Dism /Online /Cleanup-Image /StartComponentCleanup`) and Delivery Optimization cache (`Delete-DeliveryOptimizationCache -Force`). Review `DiskLevelDeletion` so that Account Manager does this on its own next time.
**Caution:** profile removal is irreversible.
</details>

---
## Evidence Pack
Run `Intune/Scripts/Get-SharedPCModeStatus.ps1 -CollectLogs` as admin (or as SYSTEM to include the MDM Bridge read). It exports CSV plus `SharedPCSetup.log` and the registry exports. Minimal inline alternative:
```powershell
$out = "C:\Temp\SharedPC-$(Get-Date -Format yyyyMMdd-HHmm)"; New-Item $out -ItemType Directory -Force | Out-Null
reg export 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC' "$out\SharedPC.reg" /y | Out-Null
Copy-Item "$env:WINDIR\SharedPCSetup.log" $out -ErrorAction SilentlyContinue
Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } | Select-Object LocalPath, SID, Loaded, LastUseTime | Export-Csv "$out\profiles.csv" -NoTypeInformation
Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" | Select-Object Size, FreeSpace | Export-Csv "$out\disk.csv" -NoTypeInformation
Compress-Archive "$out\*" "$out.zip" -Force; "Evidence: $out.zip"
```

---
## Command Cheat Sheet
| Purpose | Command |
|---|---|
| Mode live? | `[Windows.System.Profile.SharedModeSettings, Windows.System.Profile, ContentType=WindowsRuntime] \| Out-Null; [Windows.System.Profile.SharedModeSettings]::IsEnabled` |
| Effective values | `Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\NodeValues` |
| Account mgmt config | `Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\AccountManagement` |
| Setup log | `Get-Content C:\Windows\SharedPCSetup.log -Tail 60` |
| CSP via WMI (SYSTEM) | `Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_SharedPC` |
| Exemptions | `Get-ChildItem HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\Exemptions` |
| Add exemption | `New-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\Exemptions\<SID>" -Force` |
| Name → SID | `(New-Object Security.Principal.NTAccount('<acct>')).Translate([Security.Principal.SecurityIdentifier]).Value` |
| Profiles + last use | `Get-CimInstance Win32_UserProfile \| ? {-not $_.Special} \| select LocalPath,SID,LastUseTime` |
| Free % | `Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" \| % { $_.FreeSpace/$_.Size*100 }` |
| Wake timers | `powercfg /waketimers` |
| Force MDM sync | `Start-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\<enrollmentGUID>\' -TaskName 'Schedule #3 created by enrollment client'` |

---
## 🎓 Learning Pointers
- The CSP splits **parameters** from an **action**, and setup reads the parameters only when the action fires. That one design decision explains most Shared PC tickets. See the [SharedPC CSP reference](https://learn.microsoft.com/en-us/windows/client-management/mdm/sharedpc-csp).
- Account Manager uses a hysteresis band (delete below 25%, stop above 50%) plus a maintenance window. Model your disk size and power schedule before promising "profiles get cleaned up nightly".
- `AccountModel` defaults to **guest-only** at the CSP level. Custom OMA-URI builds must set it explicitly. The Intune Settings catalog UI hides that risk.
- Profile deletion is irreversible. Make OneDrive KFM (with `EnableSharedPCModeWithOneDriveSync`) the default companion setting on Windows 11 shared fleets. See [Simon Skotheimsvik's shared device guide](https://skotheimsvik.no/the-ultimate-guide-to-intune-powered-windows-11-shared-devices).
- To understand the LGPO side effects that confuse app owners, read the [Shared PC technical reference](https://learn.microsoft.com/en-us/windows/configuration/shared-pc/shared-pc-technical).
- Related in this repo: `Intune/Troubleshooting/Kiosk-A.md` (Assigned Access), `Windows/Troubleshooting/UserProfile-A.md` (profile corruption and FSLogix), `Azure/Windows365/` (Frontline shared mode).
