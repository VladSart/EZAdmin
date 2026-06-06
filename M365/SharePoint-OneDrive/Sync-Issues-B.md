# OneDrive / SharePoint Sync Issues — Hotfix Runbook (Mode B: Ops)
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

```powershell
# 1. Check OneDrive sync client status (run on affected machine)
Get-Process OneDrive -ErrorAction SilentlyContinue | Select-Object Name, Id, CPU, WorkingSet

# 2. Find OneDrive error logs
$logPath = "$env:LOCALAPPDATA\Microsoft\OneDrive\logs\Business1"
Get-ChildItem $logPath -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 5 | Format-Table Name, LastWriteTime, Length

# 3. Check sync status via registry
Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive\Accounts\Business1" -ErrorAction SilentlyContinue | Select-Object UserEmail, UserName, SPOLastSyncTime

# 4. Check known error codes in SyncDiagnostics
$diagPath = "$env:LOCALAPPDATA\Microsoft\OneDrive\logs\Business1\SyncDiagnostics.log"
if (Test-Path $diagPath) { Get-Content $diagPath | Select-String -Pattern "error|fail|0x" | Select-Object -Last 20 }

# 5. Check user's OneDrive quota (admin — requires SPO PowerShell)
# Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com
# Get-SPOSite -Filter {Url -like "*<userAlias>*"} -IncludePersonalSite $true | Select-Object StorageUsageCurrent, StorageQuota
```

**Interpretation Table:**

| Error / Symptom | Likely Cause | Go To |
|-----------------|-------------|-------|
| Red X, error code `0x8004de40` | Not signed in / auth failure | Fix 1 |
| Error `AADSTS50020` or `AADSTS70011` | Token expired or wrong account | Fix 2 |
| Sync stuck — files locked | File in use / antivirus holding handle | Fix 3 |
| Storage quota warning / red | OneDrive full | Fix 4 |
| Files show as online-only, won't download | Files On Demand misconfigured | Fix 5 |
| "You don't have access" on shared library | SPO permissions issue | See Permissions-B.md |
| Known Folder Move (KFM) not completing | GPO conflict or folder redirection clash | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for OneDrive sync to work</summary>

```
Entra ID token valid (user signed in, MFA not blocking)
    └── Network connectivity to *.sharepoint.com, *.onedrive.com (no SSL inspection breaking cert)
        └── Tenant sharing policy allows sync (not blocked by SPO admin)
            └── OneDrive site provisioned for user (first login to OneDrive required)
                └── Storage quota not exceeded
                    └── No conflicting Group Policy (DisableFileSyncNGSC = 0)
                        └── Sync client version supported (not EOL)
                            └── Files On Demand driver loaded (ODNativeFS or StorageFilter)
                                └── FILES SYNC SUCCESSFULLY
```
</details>

---
## Diagnosis & Validation Flow

**Step 1 — Check if OneDrive is running and signed in**
```powershell
# Check process
Get-Process OneDrive -ErrorAction SilentlyContinue

# Check account registry key
Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive\Accounts\Business1" -ErrorAction SilentlyContinue | Select-Object UserEmail, SPOLastSyncTime
```
Expected: Process running, `UserEmail` populated with the user's UPN.

**Step 2 — Check network access to SharePoint endpoints**
```powershell
$endpoints = @(
    "<tenantName>.sharepoint.com",
    "<tenantName>-my.sharepoint.com",
    "onedrive.live.com",
    "login.microsoftonline.com"
)
foreach ($ep in $endpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443 -InformationLevel Quiet
    Write-Host "$ep : $(if ($result) {'OK'} else {'FAIL'})"
}
```
Expected: All return `OK`. Any `FAIL` → check proxy/firewall, SSL inspection policy.

**Step 3 — Check GPO restrictions on sync**
```powershell
# Check if sync is blocked by policy
$policies = @(
    "HKLM:\SOFTWARE\Policies\Microsoft\OneDrive",
    "HKCU:\SOFTWARE\Policies\Microsoft\OneDrive"
)
foreach ($path in $policies) {
    if (Test-Path $path) {
        Get-ItemProperty $path | Format-List
    }
}
```
Expected: `DisableFileSyncNGSC` absent or set to `0`. `AllowTenantList` should include your tenant ID if configured.

**Step 4 — Check Files On Demand driver**
```powershell
Get-Service -Name "OneDrive Updater Service" -ErrorAction SilentlyContinue
fsutil.exe behavior query DisableDeleteNotify
```

**Step 5 — Check sync client version**
```powershell
$odb = Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive" -ErrorAction SilentlyContinue
$odb.Version
```
Check against current release: https://support.microsoft.com/en-us/office/onedrive-release-notes-845dcf18-f921-435e-bf28-4e24b95e5fc0

---
## Common Fix Paths

<details><summary>Fix 1 — Reset OneDrive sync (sign-out and re-sync)</summary>

**Use when:** Red X, sync stuck for >30 min, persistent auth errors.

```powershell
# Step 1: Quit OneDrive gracefully
Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

# Step 2: Reset OneDrive (clears local cache, forces re-auth — does NOT delete files)
$onedrivePath = "$env:LOCALAPPDATA\Microsoft\OneDrive\onedrive.exe"
if (Test-Path $onedrivePath) {
    & $onedrivePath /reset
    Write-Host "OneDrive reset initiated. Waiting 30 seconds..."
    Start-Sleep -Seconds 30
    & $onedrivePath
} else {
    Write-Host "OneDrive not found at expected path. Check installation." -ForegroundColor Yellow
}
```

**Note:** Files remain intact in the local OneDrive folder. The reset only clears the sync state database. User will need to sign back in.

**Post-fix validation:** OneDrive icon returns to cloud-with-arrow (syncing), then blue cloud (synced).
</details>

<details><summary>Fix 2 — Fix account mismatch / AADSTS token errors</summary>

**Use when:** `AADSTS50020` (wrong account), `AADSTS70011` (scope invalid), or user signed in with personal account instead of work account.

```powershell
# Step 1: Check which account is currently signed in
Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive\Accounts\Business1" | Select-Object UserEmail

# Step 2: Unlink account from OneDrive tray
# GUI: OneDrive tray icon → Settings → Account → Unlink this PC
# Then sign in with correct work account

# Step 3: If tenant ID mismatch, check AllowTenantList policy
$tenantId = (Invoke-RestMethod -Uri "https://login.microsoftonline.com/<yourdomain.com>/.well-known/openid-configuration").issuer -replace "https://login.microsoftonline.com/|/v2.0",""
Write-Host "Your Tenant ID: $tenantId"

# Verify GPO AllowTenantList contains this tenant ID:
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\OneDrive" -Name "AllowTenantList" -ErrorAction SilentlyContinue
```

**Rollback:** N/A — re-linking is always reversible.
</details>

<details><summary>Fix 3 — Resolve locked files blocking sync</summary>

**Use when:** Specific files fail to sync, often Office files open in another app.

```powershell
# Find files currently locked by a process:
# Install handle.exe from Sysinternals, then:
# handle.exe <pathToOneDriveFolder> | findstr /i ".docx .xlsx .pptx"

# Alternatively, check for temp/lock files left by Office:
$oneDrivePath = "$env:USERPROFILE\OneDrive - <TenantName>"
Get-ChildItem $oneDrivePath -Recurse -Filter "~$*" -ErrorAction SilentlyContinue | Select-Object FullName, LastWriteTime | Format-Table -AutoSize

# Remove stale Office lock files (only if the owning Office app is confirmed closed):
Get-ChildItem $oneDrivePath -Recurse -Filter "~$*" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Removing lock file: $($_.FullName)"
    Remove-Item $_.FullName -Force -WhatIf  # Remove -WhatIf to actually delete
}
```

**Antivirus exclusions check:**
```powershell
# Check Windows Defender exclusions for OneDrive path:
Get-MpPreference | Select-Object ExclusionPath | Format-List
```
Expected: OneDrive folder path excluded. Add if missing:
```powershell
Add-MpPreference -ExclusionPath "$env:USERPROFILE\OneDrive - <TenantName>"
```

**Rollback:** Re-add any exclusion if sync breaks again after removal.
</details>

<details><summary>Fix 4 — Address OneDrive storage quota</summary>

**Use when:** Sync stops with "storage full" warning, or quota alert in OneDrive web.

```powershell
# Admin — check and increase user's OneDrive quota:
Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com

$userODB = Get-SPOSite -Filter {Url -like "*<userAlias>*"} -IncludePersonalSite $true
Write-Host "Current usage: $($userODB.StorageUsageCurrent) MB / $($userODB.StorageQuota) MB"

# Increase quota (in MB — 1048576 = 1 TB):
Set-SPOSite -Identity $userODB.Url -StorageQuota 1048576

Write-Host "New quota set to 1 TB"
```

**If tenant default quota needs updating (admin centre):**
- SharePoint Admin Centre → OneDrive → Storage → Default storage limit
- Or via PowerShell: `Set-SPOTenant -OneDriveStorageQuota 1048576`

**Rollback:** Reduce quota back to original value using `Set-SPOSite -StorageQuota <originalValue>`.
</details>

<details><summary>Fix 5 — Fix Files On Demand (online-only files won't download)</summary>

**Use when:** Files show cloud icon, double-clicking does nothing or returns "file not available offline."

```powershell
# Check Files On Demand status:
Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive" -Name "FilesOnDemandEnabled" -ErrorAction SilentlyContinue

# Disable Files On Demand to force full download (temporary workaround):
# GUI: OneDrive Settings → Sync and backup → Advanced settings → Files On Demand → Download all files

# Or force download of a specific folder via attrib:
# attrib -U /S /D "C:\Users\<user>\OneDrive - <Tenant>\<FolderName>"

# Check if the StorageFilter minifilter driver is loaded:
fltmc.exe | findstr -i "StorageFilter\|OneDrive"
```

Expected: `StorageFilter` appears in fltmc output. If absent, Files On Demand driver is not loaded — reinstall OneDrive.
</details>

<details><summary>Fix 6 — Fix Known Folder Move (KFM) not completing</summary>

**Use when:** KFM policy deployed but Desktop/Documents/Pictures not redirected to OneDrive.

```powershell
# Check KFM policy application:
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\OneDrive" -Name "KFMSilentOptIn" -ErrorAction SilentlyContinue
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\OneDrive" -Name "KFMBlockOptOut" -ErrorAction SilentlyContinue

# Check if folder redirection GPO is conflicting:
gpresult /r | findstr -i "folder redirection"

# Check current known folder registration:
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v Desktop
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v Personal
```

Expected: Desktop and Personal (Documents) paths should point to OneDrive folder, not `C:\Users\<user>\Desktop`.

**If folder redirection GPO conflict:** Disable or unlink the folder redirection GPO for OneDrive users — both cannot run simultaneously.

**Rollback:** `Set-ItemProperty` to restore original shell folder paths, or remove KFMSilentOptIn policy.
</details>

---
## Escalation Evidence

```
ONEDRIVE SYNC ESCALATION
=========================
User UPN:           <UPN>
Device:             <hostname> / <OS version>
OneDrive version:   <version from registry or About dialog>
Sync client path:   [ ] Personal  [ ] Business1  [ ] Business2

Error code:         <0x... or AADSTS...>
Error message:      <exact text>

Sync Diagnostics log (last 20 error lines):
  <paste from SyncDiagnostics.log>

Network test results (Test-NetConnection to SPO endpoints):
  <paste output>

GPO restrictions found:
  DisableFileSyncNGSC:  <value or not set>
  AllowTenantList:      <value or not set>
  KFMSilentOptIn:       <value or not set>

Quota status:
  Used: <MB>  /  Quota: <MB>

Steps already tried:
  [ ] Reset OneDrive  [ ] Re-signed in  [ ] Checked file locks  [ ] Checked AV exclusions
```

---
## 🎓 Learning Pointers

- **Reset ≠ delete** — `/reset` clears OneDrive's local sync database (SQLite under `%LOCALAPPDATA%\Microsoft\OneDrive\settings`), not the files. Safe to run first.
- **Two sync engines exist** — "Groove" (legacy SharePoint Workspace) and "OneDrive sync client" (NGSync). If users have very old installs, Groove may still be running. Check `Get-Process groove`.
- **Files On Demand requires NTFS + StorageFilter driver** — FAT32 or exFAT drives can't sync via Files On Demand. Always check drive format for users with redirected OneDrive paths.
- **KFM conflicts with folder redirection GPO** — they both try to own `Shell Folders` registry keys. One must be removed before deploying the other.
- MS Docs — Fix OneDrive sync problems: https://support.microsoft.com/en-us/office/fix-onedrive-sync-problems-0899b115-05f7-45ec-945b-d6b2f6bda932
- MS Docs — OneDrive Files On Demand: https://learn.microsoft.com/en-us/sharepoint/enable-co-authoring
