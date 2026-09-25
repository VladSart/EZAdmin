# Shared PC Mode (Shared / Multi-User Windows Devices) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate "profiles aren't being deleted", "a user's profile vanished", "OneDrive doesn't sync on the shared PC", or "Shared PC settings didn't apply" in under 10 minutes.

> **Context (Sept 2026):** Shared PC mode is a Windows 10/11 Pro, Enterprise, Education and IoT Enterprise feature. It's driven by the **SharedPC CSP** (`./Vendor/MSFT/SharedPC/*`), which you configure through the Intune **Settings catalog → Shared PC** category, the older *Shared multi-user device* template, a provisioning package, or the MDM Bridge WMI class. Turning it on writes a set of **local group policy (LGPO)** settings. If you enable **Account Manager**, Windows also caches and **deletes** Entra ID and AD profiles according to the deletion policy and disk thresholds. The big gotcha is in the CSP documentation itself: most nodes say *"must be set before the action on the EnableSharedPCMode node is taken."* Changing thresholds on a device that's already in Shared PC mode often has no effect. Plain `EnableSharedPCMode` also **disables OneDrive sync**. Windows 11 22H2+ adds `EnableSharedPCModeWithOneDriveSync` for that. Sources: [SharedPC CSP (Microsoft Learn)](https://learn.microsoft.com/en-us/windows/client-management/mdm/sharedpc-csp); [Configure a shared or guest Windows device (Microsoft Learn)](https://learn.microsoft.com/en-us/windows/configuration/shared-pc/set-up-shared-or-guest-pc); [Intune shared device settings (Microsoft Learn)](https://learn.microsoft.com/en-us/intune/device-configuration/templates/ref-shared-device-settings-windows).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Run elevated on the affected shared device.

```powershell
# 1. What Shared PC values did the device actually receive? (NodeValues = what the CSP set)
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\NodeValues' -ErrorAction SilentlyContinue |
    Select-Object * -ExcludeProperty PS*
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\AccountManagement' -ErrorAction SilentlyContinue |
    Select-Object * -ExcludeProperty PS*

# 2. Is Shared PC mode actually on? (the same API apps use)
$null = [Windows.System.Profile.SharedModeSettings, Windows.System.Profile, ContentType = WindowsRuntime]
[Windows.System.Profile.SharedModeSettings]::IsEnabled

# 3. Setup log: did the enable action run, and did it error?
Get-Content "$env:WINDIR\SharedPCSetup.log" -Tail 40 -ErrorAction SilentlyContinue

# 4. Free space vs thresholds (deletion only starts below DiskLevelDeletion %)
Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" |
    Select-Object DeviceID, @{n='FreePct';e={[math]::Round($_.FreeSpace / $_.Size * 100, 1)}}, @{n='FreeGB';e={[math]::Round($_.FreeSpace / 1GB, 1)}}

# 5. Profiles present and last use
Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } |
    Select-Object LocalPath, SID, Loaded, LastUseTime | Sort-Object LastUseTime
```

| Finding | Action |
|---|---|
| `NodeValues` missing / `IsEnabled` False | Policy never applied, or it failed. Fix 1 |
| `IsEnabled` True but `EnableAccountManager` absent/0 | Mode is on, but nothing deletes profiles by design. Fix 2 (set the account manager **then** re-trigger) |
| Deletion policy `1` (default) and free space **above** `DiskLevelDeletion` (default 25%) | Working as designed. Profiles are only cleaned when the disk is low. Fix 3 if the customer expects daily cleanup |
| Policy `2` but profiles older than `InactiveThreshold` still present | Deletion runs in the **daily maintenance window** when the device is idle. Check `MaintenanceStartTime` and whether the device is off/asleep then. Fix 3 |
| Intune shows new values, but `NodeValues` still shows the old ones | Values changed after the mode was enabled. Fix 2 |
| A user's profile "disappeared" | Deletion policy `0` (delete at sign-out), or the low-disk emergency delete. Fix 4 (exempt accounts / explain) |
| OneDrive won't start / KFM fails on the shared PC | Plain `EnableSharedPCMode` turns off OneDrive sync. Fix 5 |
| The local admin/service account profile got deleted | Not exempt. Fix 4 |
| Guest / Kiosk tile shown when it shouldn't be (or missing) | `AccountModel` (0 guest-only, 1 domain-only, 2 both). Fix 2 |
| Profile deletion but FSLogix/roaming data loss complaints | Shared PC deletes the **local** profile only. Check where the data really lives. Fix 6 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Windows 10 1607+ / Windows 11, edition Pro | Enterprise | Education | IoT Enterprise
   │   (OneDrive variant needs Windows 11 22H2+ build 22621)
   ▼
MDM enrollment (Intune) or PPKG or MDM Bridge WMI (SYSTEM)
   ▼
SharedPC CSP nodes delivered IN ORDER:
   AccountModel, EnableAccountManager, DeletionPolicy, DiskLevelDeletion, DiskLevelCaching,
   InactiveThreshold, MaintenanceStartTime, SleepTimeout, SignInOnResume, SetPowerPolicies,
   SetEduPolicies, RestrictLocalStorage, KioskModeAUMID/UserTileDisplayText, MaxPageFileSizeMB
   ▼  (then the action node)
EnableSharedPCMode = true   OR   EnableSharedPCModeWithOneDriveSync = true
   ▼
Shared PC setup runs → writes LGPO settings + HKLM\...\SharedPC\{NodeValues,AccountManagement}
   │                   log: C:\Windows\SharedPCSetup.log
   ▼
Account Manager (only if EnableAccountManager = true)
   ├─ Daily maintenance window (MaintenanceStartTime, device idle, powered on)
   │     delete oldest-used Entra/AD profiles while FreePct < DiskLevelDeletion … until FreePct ≥ DiskLevelCaching
   ├─ Policy 2: also delete profiles unused ≥ InactiveThreshold days
   ├─ Policy 0: delete at sign-out
   ├─ Emergency: at sign-out if FreePct < DiskLevelDeletion / 2
   └─ NEVER deletes: pre-existing local accounts, locally created accounts, SIDs under ...\SharedPC\Exemptions\<SID>
   Guest / Kiosk accounts → always deleted at sign-out
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm the policy reached the device.**
   Intune: Devices → *device* → Device configuration → the Shared PC profile shows **Succeeded**. Per setting, `EnableSharedPCMode` or `…WithOneDriveSync` = Succeeded.
   On the device:
   ```powershell
   Get-CimInstance -Namespace root\cimv2\mdm\dmmap -ClassName MDM_SharedPC -ErrorAction SilentlyContinue |
       Select-Object EnableSharedPCMode, EnableSharedPCModeWithOneDriveSync, EnableAccountManager, AccountModel, DeletionPolicy, DiskLevelDeletion, DiskLevelCaching, InactiveThreshold, MaintenanceStartTime
   ```
   The WMI read needs **SYSTEM** context (use `psexec -s` or a remediation script). As a normal admin it usually returns access denied or nothing, which is expected.

2. **Check that the mode is live.**
   `[Windows.System.Profile.SharedModeSettings]::IsEnabled` → `True`. `False` while Intune reports success usually means the enable action ran but failed. Read `SharedPCSetup.log`.

3. **Compare desired with effective.**
   Put the Intune values next to `HKLM\...\SharedPC\NodeValues` and `...\AccountManagement`. A mismatch means the values changed after enablement (Fix 2).

4. **Check the deletion trigger conditions.**
   Free % from Triage step 4. For policy 1 you need `FreePct < DiskLevelDeletion`. For policy 2, a profile's `LastUseTime` must be older than `InactiveThreshold`. Either way, the device must be **on and idle during the maintenance window**.

5. **Check exemptions.**
   ```powershell
   Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\Exemptions' -ErrorAction SilentlyContinue | Select-Object PSChildName
   ```
   Every SID listed is never deleted. Translate them with `([System.Security.Principal.SecurityIdentifier]'<SID>').Translate([System.Security.Principal.NTAccount])`.

6. **Check OneDrive** (if relevant).
   `NodeValues` shows `EnableSharedPCModeWithOneDriveSync` = 1 on OneDrive-dependent fleets. If only `EnableSharedPCMode` = 1, OneDrive sync is blocked by design.

---
## Common Fix Paths

<details><summary>Fix 1 — Shared PC policy never applied / enable failed</summary>

- Check the edition: `(Get-CimInstance Win32_OperatingSystem).Caption`. **Home** isn't supported.
- Force a sync: `Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -TaskName 'Schedule #3 created by enrollment client' | Start-ScheduledTask`, or use Company Portal → Sync.
- Read the errors: `Select-String -Path "$env:WINDIR\SharedPCSetup.log" -Pattern 'error|fail'`.
- Check for conflicts: two profiles (template + Settings catalog) targeting the same device with different SharedPC values. Intune → *device* → Device configuration → look for **Conflict**. Keep **one** Shared PC profile per device.
- Confirm the **action node is in the same profile** as the settings. Microsoft's guidance is to set everything before enabling. Splitting settings and enablement across profiles lets the enable action arrive first.
</details>

<details><summary>Fix 2 — Changed thresholds / AccountModel / Account Manager not taking effect</summary>

Because the nodes must be set **before** `EnableSharedPCMode` fires, changes to an already-enabled device often don't land. Re-trigger the action:

1. In the Shared PC profile, make the value change **and** keep `EnableSharedPCMode` (or `…WithOneDriveSync`) = true.
2. On a **pilot device only**, force re-evaluation of the action. Assign a temporary profile with `EnableSharedPCMode` = false, sync, confirm `IsEnabled` = False, then remove the temporary profile and sync again so the corrected full profile re-applies.
3. Validate `NodeValues` and `AccountManagement` against the desired values.

**Rollback / caution:** disabling Shared PC mode reverts its LGPO settings, but it does **not** restore profiles that were already deleted. Test on one device, then roll out in rings. For large fleets, re-imaging or Autopilot reset with the corrected profile is often cleaner than toggling.
</details>

<details><summary>Fix 3 — "Profiles aren't being cleaned up"</summary>

Set customer expectations first. The default (`DeletionPolicy = 1`) only deletes when free space is **below 25%**, and stops once it's **above 50%**. On a 512 GB SSD that might never happen.

- If they want time-based cleanup, set `DeletionPolicy = 2` with `InactiveThreshold = <days>` (default 30). Re-trigger per Fix 2.
- If they want nothing kept at all (labs, kiosks with sign-in), use `DeletionPolicy = 0` (delete at sign-out). Warn them that users lose local state every session.
- Make sure the device is **powered on and idle** at `MaintenanceStartTime` (minutes after midnight; default 0 = 00:00). Many offices power down at night. Move the window, for example `MaintenanceStartTime = 720` (12:00) for a lunchtime lab, or configure wake timers/power policies.
- **Last-resort manual cleanup** (destructive, profiles are gone):
  ```powershell
  # Remove non-loaded, non-special profiles unused for more than N days, excluding exemptions
  $days = 30
  $exempt = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\Exemptions' -ErrorAction SilentlyContinue | ForEach-Object PSChildName)
  Get-CimInstance Win32_UserProfile | Where-Object {
      -not $_.Special -and -not $_.Loaded -and $_.LastUseTime -lt (Get-Date).AddDays(-$days) -and $exempt -notcontains $_.SID
  } | ForEach-Object { Write-Host "Removing $($_.LocalPath)"; Remove-CimInstance -InputObject $_ -WhatIf }
  # Remove -WhatIf only after reviewing the list and confirming data is backed up / in OneDrive
  ```
</details>

<details><summary>Fix 4 — Protect accounts from deletion (local admin, service, break-glass, named staff)</summary>

```powershell
$acct = '<DOMAIN\user or .\LocalAdmin or AzureAD\user@contoso.com>'
$sid = (New-Object System.Security.Principal.NTAccount($acct)).Translate([System.Security.Principal.SecurityIdentifier]).Value
New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\Exemptions\$sid" -Force | Out-Null
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\Exemptions'
```
- An exemption only stops deletion. It grants **no** permissions.
- Deploy it fleet-wide as an Intune remediation or platform script (SYSTEM). For Entra accounts the SID only exists after the user has signed in once. Resolve it on the device or read it from `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`.
- Local accounts that existed before enablement, or were created later through Settings, are **not** deleted anyway.
- **Rollback:** `Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedPC\Exemptions\<SID>"`.
</details>

<details><summary>Fix 5 — OneDrive doesn't work on the shared PC</summary>

- On Windows 11 22H2+ (build 22621+), replace `EnableSharedPCMode` with **`EnableSharedPCModeWithOneDriveSync` = true** in the profile. Use only one of the two action nodes.
- Re-trigger per Fix 2. Then, as the user, check that OneDrive starts and signs in silently (the "Silently sign in users…" and Known Folder Move policies still apply as usual).
- On Windows 10, OneDrive sync isn't supported alongside Shared PC mode. Choose between them, or move the device to Windows 11.
</details>

<details><summary>Fix 6 — Data loss complaints after profile deletion</summary>

- Shared PC deletes the **local** profile folder and registry hive. Anything only in `C:\Users\<user>` is lost. That's the design.
- Remediate the process, not the device: Known Folder Move to OneDrive (with the OneDrive-sync variant), or FSLogix/roaming for app state. Don't use `RestrictLocalStorage = true` to hide local storage from users unless their data really lives in the cloud.
- To recover files, restore from backup or the OneDrive recycle bin. Shared PC keeps no copy of deleted profiles.
</details>

---
## Escalation Evidence

```
SHARED PC ESCALATION — <ticket #>
Device / serial / OS edition + build : <>
Intune profile(s) targeting device    : <name, type (Settings catalog/template/custom OMA-URI), status>
Action node used                      : EnableSharedPCMode / EnableSharedPCModeWithOneDriveSync
IsEnabled (SharedModeSettings)        : <True/False>
NodeValues (desired vs effective)     : <paste>
AccountManagement key                 : <paste>
DeletionPolicy / DiskLevelDeletion / DiskLevelCaching / InactiveThreshold : <> / <> / <> / <>
MaintenanceStartTime (min)            : <>   Device normally powered on then? <Y/N>
System drive free %                   : <>
Exempted SIDs → accounts              : <>
Symptom                               : <not deleting / deleted unexpectedly / OneDrive / settings not applied / guest tile>
SharedPCSetup.log tail attached       : <Y/N>
Evidence script output                : Get-SharedPCModeStatus.ps1 CSV attached <Y/N>
```

---
## 🎓 Learning Pointers
- Read the CSP's own wording: nearly every node says it *"must be set before the action on the EnableSharedPCMode node is taken."* Treat Shared PC as a **provision-time** configuration, not a live-tunable policy. Plan changes as re-provision events. See the [SharedPC CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/sharedpc-csp).
- The two thresholds work as a **hysteresis band**: deletion starts below `DiskLevelDeletion` (25%) and stops above `DiskLevelCaching` (50%). "Not deleting" is usually a disk that never got full. The worked example is in the CSP doc under DiskLevelDeletion.
- Shared PC mode changes the LGPO. Before you blame Intune for "weird" settings on a shared device, check the [Shared PC technical reference](https://learn.microsoft.com/en-us/windows/configuration/shared-pc/shared-pc-technical) to see exactly what it sets.
- Exemptions are just registry keys named after SIDs. That's handy for scripting, but it also means a wrongly resolved SID silently protects nobody. Always verify by translating the SID back to a name.
- For task-worker or single-app scenarios, compare against `Intune/Troubleshooting/Kiosk-A.md` (Assigned Access). For roaming state, see `Windows/Troubleshooting/UserProfile-A.md`. Peter van der Woude's [Managing account management on Shared PCs](https://petervanderwoude.nl/post/managing-account-management-on-shared-pcs/) walks through the Settings catalog setup.
- Companion files: `SharedPC-A.md` (deep dive) and `Intune/Scripts/Get-SharedPCModeStatus.ps1` (evidence).
