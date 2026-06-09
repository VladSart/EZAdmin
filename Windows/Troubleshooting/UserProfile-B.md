# User Profile Corruption — Hotfix Runbook (Mode B: Ops)
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

Run these from an admin PowerShell session on the affected machine:

```powershell
# 1. Check if user landed in a temp profile
$currentProfile = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$profilePath = $env:USERPROFILE
Write-Host "User: $currentProfile | Profile path: $profilePath"
# If path contains "TEMP" → temp profile active

# 2. Find the user's SID and registry profile entry
$username = "<USERNAME>"  # replace with affected user
$sid = (New-Object System.Security.Principal.NTAccount($username)).Translate([System.Security.Principal.SecurityIdentifier]).Value
Write-Host "SID: $sid"

# 3. Check registry for profile state
$profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
if (Test-Path $profileKey) {
    Get-ItemProperty $profileKey | Select-Object ProfileImagePath, State, RefCount
} else {
    Write-Host "No registry entry for this SID — profile may have been deleted"
}

# 4. Check Event Log for profile load failures
Get-WinEvent -LogName Application -MaxEvents 100 |
    Where-Object { $_.ProviderName -eq "Microsoft-Windows-User Profiles Service" -and $_.Id -in @(1500,1502,1505,1511,1515,1530,1534) } |
    Select-Object TimeCreated, Id, Message | Format-Table -Wrap
```

| Output | Interpretation | Next Step |
|--------|---------------|-----------|
| Profile path ends in `.BKUP` or `.000` | Registry has corrupt/duplicate SID key | [Fix 1 — Clean Duplicate SID Keys](#fix-1--clean-duplicate-sid-keys) |
| Profile path = `C:\Users\TEMP` | Temp profile active | [Fix 2 — Clear Temp Profile and Reload](#fix-2--clear-temp-profile-and-reload) |
| `State = 4` in registry | Profile in use / locked | [Fix 3 — Force Profile Release](#fix-3--force-profile-release) |
| No registry entry for SID | Profile key missing entirely | [Fix 4 — Recreate Profile Registry Entry](#fix-4--recreate-profile-registry-entry) |
| Event ID 1502 or 1511 | Windows used temp profile — root cause varies | Check Event Message text |
| Profile folder missing from disk | Profile was deleted but registry remains | [Fix 5 — Rebuild Profile from Scratch](#fix-5--rebuild-profile-from-scratch) |

---
## Dependency Cascade

<details><summary>What must be true for profile load to succeed</summary>

```
Windows Logon (winlogon.exe)
  └── User Profiles Service (ProfSvc)
        ├── HKLM\...\ProfileList\<SID>  ← must exist, must point to valid path
        ├── Profile folder on disk       ← must be accessible, not locked
        ├── NTUSER.DAT                   ← must be loadable (not corrupt/locked)
        │     └── Registry load via RegLoadKey
        ├── Permissions on profile dir   ← user must own it (SID must match)
        └── Disk space                   ← < 200 MB free = profile load errors
              └── C:\ drive / quota settings
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the symptom**
```powershell
# From another admin account on the same machine:
$sid = (New-Object System.Security.Principal.NTAccount("<USERNAME>")).Translate([System.Security.Principal.SecurityIdentifier]).Value
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

# Check for duplicate entries (SID and SID.bak)
Get-ChildItem $regPath | Where-Object { $_.PSChildName -like "$sid*" }
```
- Expected (healthy): exactly one key matching the SID, no `.bak` variants
- Bad: two entries — `<SID>` and `<SID>.bak` — this causes temp profile loops

**Step 2 — Check NTUSER.DAT health**
```powershell
$profilePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath
Test-Path "$profilePath\NTUSER.DAT"
# False = file missing; True = exists but may still be corrupt
```

**Step 3 — Check disk space**
```powershell
Get-PSDrive C | Select-Object Used, Free
# If Free < 500MB, profile operations may fail silently
```

**Step 4 — Check if profile folder is locked**
```powershell
# List processes with handles open in the profile path
# Requires Sysinternals handle.exe if present, otherwise check via:
Get-Process | Where-Object { $_.MainWindowTitle -like "*<USERNAME>*" }
```

**Step 5 — Validate after fix**
```powershell
# After any fix, sign the user out and back in, then verify:
$env:USERPROFILE  # Should be C:\Users\<username>, not C:\Users\TEMP
whoami            # Should be DOMAIN\username
```

---
## Common Fix Paths

<details><summary>Fix 1 — Clean Duplicate SID Keys (most common temp profile cause)</summary>

**Symptom:** Two registry entries exist — `<SID>` and `<SID>.bak`

**Cause:** A previous unclean logoff left a `.bak` key. Windows loads a temp profile when it finds a duplicate.

```powershell
$username = "<USERNAME>"
$sid = (New-Object System.Security.Principal.NTAccount($username)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$regBase = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

# Check which entry has the correct profile path
$mainKey   = Get-ItemProperty "$regBase\$sid"        -ErrorAction SilentlyContinue
$bakKey    = Get-ItemProperty "$regBase\$sid.bak"    -ErrorAction SilentlyContinue

Write-Host "Main key path: $($mainKey.ProfileImagePath)"
Write-Host "Bak key path:  $($bakKey.ProfileImagePath)"

# If .bak has the real path and main key has a temp/wrong path:
# 1. Delete the main (wrong) key
Remove-Item "$regBase\$sid" -Force

# 2. Rename .bak to remove the .bak suffix
Rename-Item "$regBase\$sid.bak" -NewName $sid
```

**Rollback:** Export both keys before deleting:
```powershell
reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" "C:\Temp\profile_main_backup.reg"
reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid.bak" "C:\Temp\profile_bak_backup.reg"
```

**After fix:** Sign the user out and back in. Do NOT delete the temp profile folder until you confirm the real profile loads.

</details>

<details><summary>Fix 2 — Clear Temp Profile and Reload</summary>

**Symptom:** User logs in to `C:\Users\TEMP`, all settings reset, no `.bak` key present.

**Cause:** NTUSER.DAT is locked, corrupt, or profile state flag is set.

```powershell
$username = "<USERNAME>"
$sid = (New-Object System.Security.Principal.NTAccount($username)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"

# 1. Check the State value
$state = (Get-ItemProperty $regPath).State
Write-Host "Profile state: $state"
# State 0 = normal, State 4 = profile already loaded, State 256 = mandatory

# 2. Set State back to 0 if it's stuck
Set-ItemProperty $regPath -Name State -Value 0

# 3. Check RefCount (should be 0 when user is logged off)
$refCount = (Get-ItemProperty $regPath).RefCount
Write-Host "RefCount: $refCount"
if ($refCount -gt 0) {
    Set-ItemProperty $regPath -Name RefCount -Value 0
}
```

**After fix:** Reboot the machine (not just sign out), then have user log in fresh.

</details>

<details><summary>Fix 3 — Force Profile Release (State = 4 / profile locked)</summary>

**Symptom:** Registry State = 4, user cannot log in or gets temp profile, machine was not shut down cleanly.

```powershell
# 1. Ensure no ghost session for this user exists
query session /server:<COMPUTERNAME>

# Kill any lingering session:
logoff <SESSION_ID> /server:<COMPUTERNAME>

# 2. Reset profile state
$sid = "<USER_SID>"
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
Set-ItemProperty $regPath -Name State -Value 0
Set-ItemProperty $regPath -Name RefCount -Value 0

# 3. Restart User Profile Service
Restart-Service -Name ProfSvc -Force
```

**Rollback:** If restarting ProfSvc causes issues, reboot the machine — this resets all profile states cleanly.

</details>

<details><summary>Fix 4 — Recreate Profile Registry Entry</summary>

**Symptom:** No ProfileList entry for the user's SID at all — profile folder exists on disk but Windows doesn't recognise it.

```powershell
$username  = "<USERNAME>"
$domain    = "<DOMAIN>"
$sid       = (New-Object System.Security.Principal.NTAccount("$domain\$username")).Translate([System.Security.Principal.SecurityIdentifier]).Value
$regBase   = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
$profPath  = "C:\Users\$username"  # Adjust if different

# Create the key
New-Item -Path "$regBase\$sid" -Force

# Set required values
Set-ItemProperty "$regBase\$sid" -Name ProfileImagePath -Value $profPath
Set-ItemProperty "$regBase\$sid" -Name State            -Value 0
Set-ItemProperty "$regBase\$sid" -Name RefCount         -Value 0
Set-ItemProperty "$regBase\$sid" -Name Flags            -Value 0

Write-Host "Profile registry entry created for $username ($sid)"
```

**Important:** The profile folder `C:\Users\<username>` and `NTUSER.DAT` must exist for this to work. If they don't, proceed to Fix 5.

</details>

<details><summary>Fix 5 — Rebuild Profile from Scratch</summary>

**Symptom:** Profile folder deleted or NTUSER.DAT missing/irreparably corrupt. User will lose local profile data (desktop items, local app settings).

```powershell
$username = "<USERNAME>"
$sid      = (New-Object System.Security.Principal.NTAccount($username)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$regPath  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"

# 1. Backup whatever is left (if anything)
$oldProfile = "C:\Users\$username"
if (Test-Path $oldProfile) {
    Copy-Item $oldProfile "C:\Temp\ProfileBackup_$username" -Recurse -Force
}

# 2. Delete old registry key so Windows generates a fresh profile on next login
Remove-Item $regPath -Force -ErrorAction SilentlyContinue
Remove-Item "$regPath.bak" -Force -ErrorAction SilentlyContinue

# 3. Rename old profile folder so Windows doesn't pick it up
if (Test-Path $oldProfile) {
    Rename-Item $oldProfile "${oldProfile}_OLD_$(Get-Date -Format yyyyMMdd)"
}

Write-Host "Old profile cleared. User will get a new profile on next login."
# User logs in → Windows creates fresh profile → restore Desktop/Documents from backup
```

**After:** Once user logs in with new profile, manually restore key data:
```powershell
# Copy Desktop, Documents, Favorites from backup
$backup = "C:\Temp\ProfileBackup_$username"
$newProfile = "C:\Users\$username"
foreach ($folder in @("Desktop","Documents","Favorites","Pictures")) {
    if (Test-Path "$backup\$folder") {
        Copy-Item "$backup\$folder\*" "$newProfile\$folder\" -Recurse -Force
    }
}
```

</details>

---
## Escalation Evidence

```
TICKET ESCALATION: User Profile Corruption
==========================================
Machine:            ___________________________
Username:           ___________________________
Domain / SID:       ___________________________
Profile path:       ___________________________
Profile state reg:  State=___ RefCount=___
Duplicate SID key:  Yes / No
NTUSER.DAT exists:  Yes / No
Event IDs found:    ___________________________
Fix attempted:      ___________________________
Fix outcome:        ___________________________
C:\ free space:     ___________________________
Last clean boot:    ___________________________
Screenshots:        [ ] Registry keys  [ ] Event log  [ ] Profile folder
```

---
## 🎓 Learning Pointers

- **Why temp profiles happen**: Windows loads the default profile when it can't acquire a lock on NTUSER.DAT or finds duplicate SID keys. The `.bak` key pattern is created whenever a profile is in use during shutdown — if the machine crashes before cleanup, both entries persist. [MS Docs — User Profiles](https://learn.microsoft.com/en-us/windows/client-management/mandatory-user-profile)
- **Profile State flags explained**: State 0 = normal, 4 = loaded (user active), 256 = mandatory profile, 1024 = local profile. Stuck State 4 with no active session = unclean shutdown artifact. Fix by setting to 0 + reboot.
- **NTUSER.DAT is a registry hive**: It gets loaded via `RegLoadKey` at logon and unloaded at logoff. If another process has a handle open to it, the unload fails and RefCount stays > 0. Sysinternals Handle.exe can identify the culprit process.
- **USMT for full profile migration**: When rebuilding profiles across machine replacements or domain changes, use User State Migration Tool (USMT) — `scanstate` + `loadstate`. Far more reliable than manual copy. [USMT Overview](https://learn.microsoft.com/en-us/windows/deployment/usmt/usmt-overview)
- **Mandatory profiles vs temp profiles**: A mandatory profile (State 256) is intentional — local changes don't persist. A temp profile (C:\Users\TEMP) is always a fault condition. Know which one you're dealing with before touching anything.
- **Roaming profiles in hybrid environments**: If the user has a roaming profile path set in AD, profile load issues may originate from the file server, not the local machine. Check `net use` and SMB connectivity to the profile share.
