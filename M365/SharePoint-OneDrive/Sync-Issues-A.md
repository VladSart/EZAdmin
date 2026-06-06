# SharePoint & OneDrive Sync Issues — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers OneDrive sync client (ODC) and SharePoint library sync failures for Windows 10/11 endpoints managed via Intune or GPO. It covers:

- Personal OneDrive (consumer and business/work accounts)
- SharePoint document library sync via the OneDrive sync client
- Known Folder Move (KFM) / folder backup policies
- Selective Sync and library exclusions
- SharePoint Online throttling and quota issues

**Not covered:** SharePoint Server 2016/2019 on-prem sync (uses older Groove client), OneDrive consumer (MSA) accounts outside corporate tenant.

**Assumptions:**
- OneDrive sync client version 23.x or newer (check via `winver`-style: `%LocalAppData%\Microsoft\OneDrive\version.txt`)
- Client is Entra ID joined or hybrid-joined — user has a work/school account
- Tenant allows sync (no tenant-level block policy in SharePoint Admin Center)

---

## How It Works

<details><summary>Full architecture</summary>

### OneDrive Sync Engine Overview

The OneDrive sync client (OneDrive.exe) is a Windows process that runs as the signed-in user. It maintains a **local sync database** and communicates with SharePoint Online via **REST APIs** (not WebDAV) over HTTPS.

```
  User's filesystem (NTFS)
        |
        | file system watcher (ReadDirectoryChangesW)
        v
  OneDrive.exe (sync engine)
        |
        |-- Local DB: %LocalAppData%\Microsoft\OneDrive\settings\<BusinessN>\
        |       ├── ClientPolicy.ini        ← sync scope / KFM config
        |       ├── <GUID>.dat              ← sync database (SQLite-based)
        |       └── SyncEngineDatabase.db   ← item metadata
        |
        | HTTPS REST (SharePoint REST API + CSOM)
        v
  SharePoint Online / OneDrive for Business
        |
        ├── Personal Site (https://<tenant>-my.sharepoint.com/personal/<UPN_encoded>)
        └── Team Sites  (https://<tenant>.sharepoint.com/sites/<siteName>)
```

### Sync Protocol Flow

1. **Authentication**: OneDrive acquires tokens from Entra ID (MSAL) using the signed-in Windows identity. Silent SSO uses WAM (Web Account Manager) on Windows 10+.
2. **Discovery**: Client polls the /me/drive endpoint (Graph API) to discover the user's OneDrive root and any shared libraries.
3. **Delta Query**: Uses SharePoint's `/_api/v2.0/drives/{driveId}/root/delta` to get changed items since last sync token.
4. **Block Transfer**: Files are transferred in 10 MB blocks using the Resumable Upload API. Files <4 MB use PUT; larger files use session-based upload.
5. **Conflict Resolution**: Last-writer-wins for most conflicts. OneDrive creates a "conflict copy" with the user's name appended rather than silently overwriting.

### Known Folder Move (KFM)

KFM redirects Desktop, Documents, and Pictures to OneDrive-backed folders. It works by:
1. Moving the actual folder contents into the OneDrive folder
2. Creating a junction/reparse point at the old path (on older builds) or updating the Shell Folder registry keys to point to the new location
3. This is controlled via Intune/GPO using the `KFMSilentOptIn` policy (GUID = Tenant ID)

```
HKCU\SOFTWARE\Microsoft\OneDrive\Accounts\Business1
  └── KFMSilentOptIn = <TenantGUID>
  └── KFMOptInWithWizardHidden = 1
```

### Sync Health Reporting

Since OneDrive client 22.x, the client reports sync health telemetry to the **Microsoft 365 Apps Health** dashboard in the M365 Admin Center. This gives per-device error codes visible to admins without touching the endpoint.

</details>

---

## Dependency Stack

```
SharePoint Online (tenant)
    └── SharePoint Admin Center — tenant sync policies, block policies, quota
        └── Entra ID — user identity, token issuance, Conditional Access
            └── WAM / MSAL — silent token acquisition on the device
                └── OneDrive.exe process (running as user)
                    └── Local NTFS filesystem (reparse points, ACLs, path length)
                        └── Sync database (%LocalAppData%\Microsoft\OneDrive\settings\)
                            └── KFM shell folder registry (if KFM enabled)
                                └── Network: HTTPS/443 to *.sharepoint.com, *.onedrive.com
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Red X on OneDrive tray icon, "Sign-in required" | Token expired, Conditional Access blocking, account mismatch | `dsregcmd /status`, sign-in dialog error code |
| Files stuck "Processing changes" for hours | Throttling (HTTP 429), large file >250 GB, path length >256 chars | Event log, ODC error log, file path length |
| "File is in use" sync error | File locked by another process (Outlook PST, database file, .tmp files) | Handle.exe or `openfiles /query` |
| Specific folder not syncing | Selective sync exclusion, folder name contains invalid characters | ODC settings → "Choose folders" |
| KFM not redirecting / reverting | Policy not applied, tenant GUID mismatch, user denied during wizard | Registry check, GPO/Intune resultant set |
| "Your OneDrive is full" | Personal quota exceeded (1 TB default), or tenant storage cap hit | SharePoint Admin → User storage |
| OneDrive shows two accounts / conflicts | User has personal MSA + work account both signed in | ODC settings → Account list |
| Sync stops after Intune policy push | New Conditional Access policy blocking non-compliant devices | CA Sign-in logs, dsregcmd compliance |
| "Location is unavailable" on redirected folder | KFM junction broken after OS upgrade | Shell folder registry, reparse point check |
| Error 0x8004de40 | SSL/TLS issue or proxy intercepting HTTPS | Fiddler trace, proxy bypass list |
| Error 0x80070005 | Access denied to local file/folder | NTFS ACL on sync folder |
| Error 0x8007016A | Cloud file provider not running (Files On-Demand) | OneDrive process running? StorageSense conflict |

---

## Validation Steps

### 1. Confirm OneDrive is running and signed in

```powershell
Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Select-Object Id, CPU, StartTime
```

**Good:** Process is running with reasonable CPU (not pegged at 100%).
**Bad:** No process — OneDrive is not running. Start with: `Start-Process "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"`

---

### 2. Check device AAD/Entra join state

```powershell
# Run as the affected user (not SYSTEM)
dsregcmd /status | Select-String -Pattern "AzureAdJoined|WorkplaceJoined|SSO State|TenantId|UserEmail"
```

**Good:** `AzureAdJoined: YES` or `WorkplaceJoined: YES`, `AzureAdPrt: YES`.
**Bad:** `AzureAdPrt: NO` — WAM cannot get a token silently. OneDrive will prompt for sign-in.

---

### 3. Check sync account binding

```powershell
$settingsPath = "$env:LOCALAPPDATA\Microsoft\OneDrive\settings"
Get-ChildItem $settingsPath -Directory | ForEach-Object {
    $ini = Get-Content "$($_.FullName)\ClientPolicy.ini" -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        Account  = $_.Name
        Policies = ($ini | Select-String "KFM|Tenant|UserEmail" | Select-Object -First 5)
    }
}
```

**Good:** One Business account folder matching the user's UPN/tenant.
**Bad:** Multiple Business folders (Business1, Business2) = multiple accounts causing conflicts.

---

### 4. Check OneDrive sync errors from event log

```powershell
Get-WinEvent -LogName "Microsoft-Windows-OneDrive*" -MaxEvents 50 -ErrorAction SilentlyContinue |
    Where-Object { $_.LevelDisplayName -in "Error","Warning" } |
    Select-Object TimeCreated, LevelDisplayName, Message |
    Format-List
```

**Good:** No recent errors or only informational events.
**Bad:** Repeated error events with 0x800 error codes → cross-reference with Symptom table above.

---

### 5. Validate path length compliance

```powershell
# Check for paths exceeding 256 characters in the sync folder
$syncRoot = (Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive\Accounts\Business1" -ErrorAction SilentlyContinue).UserFolder
if ($syncRoot) {
    Get-ChildItem -Path $syncRoot -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.Length -gt 256 } |
        Select-Object FullName, @{N="PathLength";E={$_.FullName.Length}} |
        Sort-Object PathLength -Descending |
        Select-Object -First 20
}
```

**Good:** No results.
**Bad:** Paths >256 chars will fail to sync. Rename folders/files or enable Long Path Support.

---

### 6. Check KFM registry state

```powershell
$kfmKeys = @{
    "Desktop"   = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue).Desktop
    "Documents" = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue).Personal
    "Pictures"  = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue)."My Pictures"
}
$syncRoot = (Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive\Accounts\Business1" -ErrorAction SilentlyContinue).UserFolder
$kfmKeys | Format-List
Write-Host "Expected prefix: $syncRoot"
```

**Good:** All three paths start with the OneDrive sync root folder.
**Bad:** Paths still point to `%USERPROFILE%\Desktop` etc. — KFM policy hasn't applied.

---

## Troubleshooting Steps (by phase)

### Phase 1: Authentication / Token Issues

Token failures are the most common silent sync stopper. OneDrive won't always show a visible error.

1. Check WAM token state: `dsregcmd /status` → look for `AzureAdPrt: YES`
2. If PRT is missing: run `dsregcmd /refreshprt` (requires network + DC visibility for hybrid)
3. If device is not joined at all: check Entra ID device registration via portal
4. Check Conditional Access sign-in logs: Azure Portal → Entra ID → Sign-in logs → filter by app "OneDrive SyncEngine"
5. If CA policy blocking: verify device compliance state in Intune, confirm the user's license includes Intune

### Phase 2: Sync Engine / Local State

1. Reset the sync client: see [Remediation: Reset OneDrive Sync Client](#fix-3--reset-onedrive-sync-client)
2. Check ODC diagnostic log: `%localappdata%\Microsoft\OneDrive\logs\` — `SyncEngine.log` (last ~500 lines useful)
3. Check for NTFS permission issues on the sync folder
4. Verify OneDrive exe version: newer versions fix known bugs

```powershell
(Get-Item "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe").VersionInfo.ProductVersion
```

Minimum recommended: 23.076.0409.0001 or newer. Check: https://support.microsoft.com/en-us/office/onedrive-release-notes-845dcf18-f921-435e-bf28-4e24b95e5fc0

### Phase 3: SharePoint / Tenant Side

1. Check tenant sync policy: SharePoint Admin Center → Settings → OneDrive → Sync
2. Check if site is blocked for sync: SharePoint Admin Center → Active Sites → select site → Policies
3. Check user's OneDrive quota: M365 Admin Center → Users → Active users → select user → OneDrive tab
4. Check if library has SharePoint features incompatible with sync (IRM/encryption, checkout-required)

### Phase 4: KFM-Specific Issues

1. Confirm Intune/GPO policy is applied: `gpresult /r` or Intune device configuration profile status
2. Check tenant ID in KFM policy matches actual tenant: `(Get-AzureADTenantDetail).ObjectId` vs `KFMSilentOptIn` reg value
3. If KFM applied but folders not moving: check if user previously opted out

```powershell
Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive" -Name "KFMBlockOptOut" -ErrorAction SilentlyContinue
```

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Re-authenticate OneDrive (token / sign-in issues)</summary>

**When to use:** "Sign-in required" error, sync stopped silently, CA policy change.

```powershell
# Step 1: Sign out of OneDrive
Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

# Step 2: Unlink account via registry (non-destructive — files stay)
$odPath = "HKCU:\Software\Microsoft\OneDrive\Accounts\Business1"
if (Test-Path $odPath) {
    Remove-ItemProperty -Path $odPath -Name "UserEmail" -ErrorAction SilentlyContinue
    Write-Host "Account unlinked from registry"
}

# Step 3: Restart OneDrive — it will prompt for sign-in
Start-Process "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"
Write-Host "OneDrive restarted — user must sign in with work account"
```

**Rollback:** Not destructive. Files remain in place; only the auth token is cleared.

</details>

<details>
<summary>Fix 2 — Fix KFM not applying (policy/registry)</summary>

**When to use:** KFM policy deployed but Desktop/Documents/Pictures not redirected.

```powershell
# Step 1: Verify tenant GUID in policy
$tenantId = (Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive\Accounts\Business1" `
    -Name "Business" -ErrorAction SilentlyContinue).Business
$kfmOptIn = (Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive" `
    -Name "KFMSilentOptIn" -ErrorAction SilentlyContinue).KFMSilentOptIn

Write-Host "Tenant ID (from account): $tenantId"
Write-Host "KFM OptIn value:          $kfmOptIn"

if ($tenantId -ne $kfmOptIn) {
    Write-Warning "MISMATCH — KFM policy has wrong tenant GUID. Update Intune/GPO policy."
}

# Step 2: Check for opt-out block
$blockOptOut = (Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive" `
    -Name "KFMBlockOptOut" -ErrorAction SilentlyContinue).KFMBlockOptOut
if ($blockOptOut) { Write-Warning "User has opted out of KFM — admin must set KFMBlockOptOut=1 in policy to prevent this" }

# Step 3: Force policy re-application (if using GPO)
gpupdate /force
Start-Sleep -Seconds 10
Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Start-Process "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"
Write-Host "OneDrive restarted. Check tray icon for KFM prompt."
```

**Rollback:** KFM opt-out: `Set-ItemProperty "HKCU:\Software\Microsoft\OneDrive" -Name "KFMOptedIn" -Value 0 -Type DWord`

</details>

<details>
<summary>Fix 3 — Reset OneDrive Sync Client (last resort for corrupted state)</summary>

**When to use:** Sync database corrupted, persistent errors after other fixes, client in broken state post-upgrade.

⚠️ This clears the local sync database. Files already synced to cloud are safe. Local-only files (not yet uploaded) may be at risk if cloud is not current. Verify cloud state first.

```powershell
# Step 1: Stop OneDrive
Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

# Step 2: Back up sync database (optional)
$settingsPath = "$env:LOCALAPPDATA\Microsoft\OneDrive\settings"
$backupPath   = "$env:TEMP\ODC_Settings_Backup_$(Get-Date -Format yyyyMMdd_HHmmss)"
if (Test-Path $settingsPath) {
    Copy-Item -Path $settingsPath -Destination $backupPath -Recurse -Force
    Write-Host "Settings backed up to: $backupPath"
}

# Step 3: Reset (clears local state, re-syncs from cloud)
Start-Process -FilePath "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe" `
    -ArgumentList "/reset" -Wait
Start-Sleep -Seconds 10

# Step 4: Restart
Start-Process "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"
Write-Host "OneDrive reset complete. Initial sync will begin — may take time for large libraries."
```

**Rollback:** Restore from backup path if needed: `Copy-Item -Path $backupPath -Destination $settingsPath -Recurse -Force`

</details>

<details>
<summary>Fix 4 — Enable Long Path Support (path length errors)</summary>

**When to use:** Files with paths >256 characters failing to sync.

```powershell
# Requires admin
# Method 1: Registry
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" `
    -Name "LongPathsEnabled" -Value 1 -Type DWord
Write-Host "Long path support enabled (requires reboot to take full effect)"

# Method 2: Group Policy equivalent check
$gpoLongPath = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" `
    -Name "LongPathsEnabled" -ErrorAction SilentlyContinue
Write-Host "Current value: $($gpoLongPath.LongPathsEnabled) (1 = enabled)"
```

**Rollback:** `Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Value 0 -Type DWord`

</details>

<details>
<summary>Fix 5 — Resolve Files On-Demand / StorageSense conflict (error 0x8007016A)</summary>

**When to use:** "Cloud file provider is not running" error, dehydrated files not rehydrating.

```powershell
# Check Files On-Demand status
$fodKey = Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive\Accounts\Business1" `
    -Name "FilesOnDemandEnabled" -ErrorAction SilentlyContinue
Write-Host "Files On-Demand enabled: $($fodKey.FilesOnDemandEnabled)"

# Check if Storage Sense is aggressively cleaning cloud-only files
$ssKey = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" `
    -ErrorAction SilentlyContinue
Write-Host "StorageSense cloud file cleanup days: $($ssKey.'2562944001')"
# Value 0 = never clean, 14/30/60 = clean after N days offline

# To disable StorageSense's OneDrive cleanup:
Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" `
    -Name "2562944001" -Value 0 -Type DWord -ErrorAction SilentlyContinue
Write-Host "StorageSense cloud file auto-cleanup disabled"

# Restart OneDrive to re-register cloud provider
Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Start-Process "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects OneDrive/SharePoint sync diagnostic evidence for escalation
.NOTES     Run as the affected user (not admin/SYSTEM)
#>

$reportPath = "$env:TEMP\ODC_Evidence_$(Get-Date -Format yyyyMMdd_HHmmss)"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

# 1. OneDrive process info
Get-Process -Name OneDrive -ErrorAction SilentlyContinue |
    Select-Object Id, CPU, WorkingSet, StartTime |
    Export-Csv "$reportPath\01_ODC_Process.csv" -NoTypeInformation

# 2. OneDrive version
$version = (Get-Item "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe" -ErrorAction SilentlyContinue).VersionInfo.ProductVersion
"OneDrive Version: $version" | Out-File "$reportPath\02_ODC_Version.txt"

# 3. Device join state
dsregcmd /status 2>&1 | Out-File "$reportPath\03_DsregCmd.txt"

# 4. Account settings (sanitized)
$settingsPath = "$env:LOCALAPPDATA\Microsoft\OneDrive\settings"
Get-ChildItem $settingsPath -Directory -ErrorAction SilentlyContinue |
    ForEach-Object {
        $ini = Get-Content "$($_.FullName)\ClientPolicy.ini" -ErrorAction SilentlyContinue
        [PSCustomObject]@{Account = $_.Name; Policies = ($ini -join "`n")}
    } | Export-Csv "$reportPath\04_ODC_Accounts.csv" -NoTypeInformation

# 5. Shell folder redirections (KFM check)
Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" `
    -ErrorAction SilentlyContinue |
    Select-Object Desktop, Personal, "My Pictures" |
    Export-Csv "$reportPath\05_ShellFolders.csv" -NoTypeInformation

# 6. OneDrive event log
Get-WinEvent -LogName "Microsoft-Windows-OneDrive*" -MaxEvents 100 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, LevelDisplayName, Id, Message |
    Export-Csv "$reportPath\06_ODC_EventLog.csv" -NoTypeInformation

# 7. Application event log (OneDrive entries)
Get-EventLog -LogName Application -Source "*OneDrive*" -Newest 50 -ErrorAction SilentlyContinue |
    Select-Object TimeGenerated, EntryType, Message |
    Export-Csv "$reportPath\07_AppLog_ODC.csv" -NoTypeInformation

# 8. Copy last 500 lines of SyncEngine log
$syncLog = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\OneDrive\logs" -Filter "SyncEngine*.log" `
    -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($syncLog) {
    Get-Content $syncLog.FullName -Tail 500 | Out-File "$reportPath\08_SyncEngine_Tail500.log"
}

# 9. Long path check
$syncRoot = (Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive\Accounts\Business1" `
    -ErrorAction SilentlyContinue).UserFolder
if ($syncRoot) {
    Get-ChildItem -Path $syncRoot -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.Length -gt 256 } |
        Select-Object FullName, @{N="Len";E={$_.FullName.Length}} |
        Export-Csv "$reportPath\09_LongPaths.csv" -NoTypeInformation
}

Write-Host "`n[OK] Evidence collected at: $reportPath" -ForegroundColor Green
Write-Host "Zip and attach to support ticket."
Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "[OK] Zip: $reportPath.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check ODC version | `(Get-Item "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe").VersionInfo.ProductVersion` |
| Check device join / PRT | `dsregcmd /status` |
| Restart OneDrive | `Stop-Process -Name OneDrive -Force; Start-Process "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"` |
| Reset OneDrive | `& "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe" /reset` |
| Check KFM registry | `Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive" -Name "KFMSilentOptIn"` |
| Check shell folder redirects | `Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"` |
| View sync errors (event log) | `Get-WinEvent -LogName "Microsoft-Windows-OneDrive*" -MaxEvents 50` |
| Check long paths enabled | `Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled"` |
| Enable long path support | `Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Value 1` |
| Find long sync paths | `Get-ChildItem <syncRoot> -Recurse \| Where-Object { $_.FullName.Length -gt 256 }` |
| Check OneDrive user quota | `Get-SPOSite -IncludePersonalSite $true -Filter "Url -like '-my.sharepoint.com/personal/'"` (SPO module) |
| Open ODC log folder | `explorer "$env:LOCALAPPDATA\Microsoft\OneDrive\logs"` |
| Check StorageSense ODC setting | `Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"` |
| Force GPO refresh (for KFM policy) | `gpupdate /force` |

---

## 🎓 Learning Pointers

- **WAM is the silent auth backbone.** OneDrive on Windows 10+ uses Web Account Manager (WAM) for token acquisition — it never shows a browser. When WAM breaks (e.g. due to Conditional Access or Hybrid Join issues), OneDrive silently stops syncing. Always check `dsregcmd /status` for `AzureAdPrt: YES` before assuming it's a sync engine problem. See: [WAM overview](https://learn.microsoft.com/en-us/azure/active-directory/devices/concept-primary-refresh-token)

- **KFM tenant GUID must match exactly.** The `KFMSilentOptIn` registry policy value must be the Entra ID Tenant ID of the tenant where the user is licensed. Using a group GUID or the wrong tenant (common in multi-tenant MSP setups) silently prevents KFM from applying. Verify with: `(Get-MgOrganization).Id` (Graph PowerShell).

- **Selective Sync is per-device, not per-user.** If a user says "I can see the folder on another machine but not this one," check selective sync settings in the ODC tray icon → Settings → Account → Choose folders. This state is stored in the local sync database, not in the cloud.

- **SharePoint library IRM blocks sync.** If a SharePoint library has Information Rights Management (IRM) enabled, the OneDrive sync client cannot sync it — this is by design. The error appears as a non-sync indicator on the library. The only workaround is to access the library via browser. See: [IRM and sync](https://support.microsoft.com/en-us/office/sync-sharepoint-and-teams-files-with-your-computer-6de9ede8-5b6e-4503-80b2-6190f3354a88)

- **The /reset switch is non-destructive but thorough.** Running `OneDrive.exe /reset` clears the local sync state database but does NOT delete local files. After reset, OneDrive re-syncs everything from the cloud — which means it will re-download Files On-Demand stubs and may take hours on large libraries. Always warn users before running this.

- **M365 Apps Health shows sync errors at scale.** For MSPs managing many devices, the Microsoft 365 Apps Health dashboard (admin.microsoft.com → Health → Microsoft 365 Apps) includes OneDrive sync health per device. You can see error codes and affected user counts without touching endpoints. Reference: [Microsoft 365 Apps health](https://learn.microsoft.com/en-us/deployoffice/admincenter/microsoft-365-apps-health)
