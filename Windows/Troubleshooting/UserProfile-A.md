# User Profile Corruption — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

- **Applies to:** Windows 10 22H2+, Windows 11, domain-joined and Azure AD-joined devices
- **Profile types covered:** Local profiles, roaming profiles (legacy), FSLogix profile containers (VDI/AVD), mandatory profiles
- **Out of scope:** RDS/RDSH server-side profile configuration, UE-V, third-party profile management tools
- **Assumed role:** L2/L3 engineer with local admin or equivalent rights
- **Tools required:** Event Viewer, Registry Editor, PowerShell (admin), optionally ProcMon for deep tracing

---

## How It Works

<details><summary>Full architecture — Windows User Profile lifecycle</summary>

### Profile Load Sequence (logon)

```
1. Winlogon authenticates user (credential provider → LSA → Kerberos/NTLM)
2. userinit.exe launches, calls LoadUserProfile() via USERENV.DLL
3. Profile Service (ProfSvc) checks HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList
   ├── SID key found → existing profile path returned
   └── SID key absent → new profile created from Default profile
4. NTUSER.DAT is loaded as HKCU (registry hive mount)
5. Group Policy (user portion) applies via gpupdate engine
6. Shell (explorer.exe) starts; user-specific AppData paths resolve
7. Logon scripts / startup items execute
```

### Profile Registry Hive Structure

```
HKLM\...\ProfileList\
  └── <SID>\
        ├── ProfileImagePath    REG_EXPAND_SZ  → C:\Users\<username>
        ├── State               REG_DWORD      → 0=OK, 4=temp, 256=mandatory
        ├── RefCount            REG_DWORD      → active session count
        └── CentralProfile      REG_SZ         → UNC path (roaming only)
```

### Corruption Scenarios

| Root cause | What breaks | Mechanism |
|---|---|---|
| NTUSER.DAT locked (previous session didn't unload) | Temp profile on next logon | Hive load fails → fallback to temp |
| NTUSER.DAT file-level corruption | Profile load error 1009 | CRC mismatch on hive read |
| ProfileList SID key has `.bak` suffix | Wrong path resolved | Stale State=4 flag + .bak rename |
| Disk quota exceeded | Profile creation fails | CopyProfile fails silently |
| Antivirus locked hive backup | Hive merge on logoff fails | Incomplete dirty region write |
| FSLogix VHD(x) mount failure | Temp profile (FSLogix context) | Network/share/policy issue |

### Roaming Profile Merge

On logoff, Windows merges local dirty pages back to the central store. If the central store is unavailable or the local copy is newer, conflict resolution uses `LastWriteTime` — the newer hive wins. This is why split-brain profile corruption often occurs after forced session termination.

### FSLogix Profile Container (VDI/AVD)

FSLogix replaces the Windows profile service flow entirely:
```
Logon → FSLogix filter driver intercepts → Mounts VHD(x) from share
      → Redirects %USERPROFILE% to container mount point
      → Standard profile load continues inside container
Logoff → VHD(x) unmounted and locked
```
Corruption in FSLogix context = VHD(x) issue, not NTUSER.DAT.

</details>

---

## Dependency Stack

```
User Logon
    │
    ▼
Winlogon / Credential Provider
    │
    ▼
LSA / Authentication (Kerberos or NTLM)
    │
    ▼
Profile Service (ProfSvc — syssvcs.dll)
    │
    ├── HKLM\...\ProfileList  (SID → path mapping)
    │
    ├── NTUSER.DAT            (user registry hive)
    │       └── Must not be locked by another session
    │
    ├── Default Profile       (template for new profiles)
    │
    └── AppData\Local, Roaming, LocalLow
            │
            └── Explorer.exe / Shell
                    │
                    └── User applications
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| "You've been signed in with a temporary profile" | NTUSER.DAT locked or SID key has `.bak` suffix | Event 1511/1515 in Application log |
| Desktop/documents gone, generic appearance | Temp profile loaded | `$env:USERPROFILE` contains `TEMP` |
| Slow logon, profile doesn't fully load | Roaming profile sync from slow/unavailable share | Event 1530 or 1542 in Application log |
| "The User Profile Service failed the logon" | NTUSER.DAT corrupt or hive load error | Event 1500/1502/1509 |
| Profile loads but settings reset each logon | Mandatory profile (`ntuser.man`) or redirect loop | Check ProfileList State value |
| New user gets another user's profile | SID collision after account recreation | ProfileList SID → path mismatch |
| FSLogix: temp profile in AVD | VHD(x) not mounting | FSLogix event log + frxlog.txt |

---

## Validation Steps

**1. Check profile load status:**
```powershell
Get-WinEvent -LogName Application -MaxEvents 50 |
    Where-Object { $_.Id -in @(1500,1502,1509,1511,1515,1530,1542) } |
    Select-Object TimeCreated, Id, Message |
    Format-List
```
Expected good: No events or Event 1500 with "successfully loaded"
Bad: Events 1511 (temp profile), 1509 (error using profile), 1502 (cannot create profile folder)

**2. Check ProfileList for corruption markers:**
```powershell
$ProfileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
Get-ChildItem $ProfileList | ForEach-Object {
    $props = Get-ItemProperty $_.PSPath
    [PSCustomObject]@{
        SID          = $_.PSChildName
        Path         = $props.ProfileImagePath
        State        = $props.State
        HasBakSuffix = $_.PSChildName -match '\.bak$'
    }
} | Format-Table -AutoSize
```
Expected good: State = 0, no `.bak` suffixes
Bad: State = 4 (temp profile in use), `.bak` suffix present

**3. Check NTUSER.DAT lock status:**
```powershell
$username = '<UPN-or-SAMAccountName>'
$profilePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
    Where-Object { $_.ProfileImagePath -match $username }).ProfileImagePath
# Check if hive is loaded (it will be if user is logged in)
Get-ChildItem HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList |
    Get-ItemProperty | Where-Object { $_.ProfileImagePath -eq $profilePath }
```

**4. Verify disk space (profile disk quota):**
```powershell
Get-PSDrive C | Select-Object Used, Free, @{N='FreeMB';E={[math]::Round($_.Free/1MB)}}
```
Good: FreeMB > 500. Bad: < 100 MB free.

**5. Confirm no orphaned hive mounts:**
```powershell
# Loaded hives appear under HKU
Get-ChildItem Registry::HKEY_USERS | Where-Object { $_.Name -match 'S-1-5-21' }
```
If a SID is listed here but the user is not logged in — orphaned hive. Unload with `reg unload HKU\<SID>`.

---

## Troubleshooting Steps by Phase

### Phase 1 — Identify profile state

1. Ask user: Does this happen every logon, or intermittently?
2. Check if it's device-specific or follows the user (log in on another machine)
3. Check Application event log for Event IDs 1500–1542
4. Run ProfileList validation PowerShell above

### Phase 2 — Isolate cause

5. If temp profile: check for `.bak` SID key or locked NTUSER.DAT
6. If "service failed logon": check NTUSER.DAT file permissions and disk space
7. If roaming profile: check network path availability, permissions, size
8. If FSLogix: check FSLogix event log (`Applications and Services Logs > Microsoft > FSLogix > Apps > Operational`)

### Phase 3 — Remediate

9. Apply appropriate playbook from [Remediation Playbooks](#remediation-playbooks)
10. After fix, force profile unload and reload (log user off/on)
11. Verify via event log that profile loaded successfully (no 1511/1509)

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Fix temp profile caused by .bak SID key</summary>

**Symptom:** User gets temp profile. ProfileList has duplicate SID entries — one with `.bak` suffix.

**Cause:** Previous corruption left State=4 and renamed the key. Windows uses the `.bak` copy on next logon but loads temp profile.

```powershell
# RUN AS ADMINISTRATOR
# Ensure the affected user is FULLY logged off before proceeding

$SID = '<user-SID>'  # Get from whoami /user or Get-ADUser
$ProfileList = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

# Check for .bak key
$bakKey  = "$ProfileList\$SID.bak"
$normKey = "$ProfileList\$SID"

if (Test-Path $bakKey) {
    $bakPath  = (Get-ItemProperty $bakKey).ProfileImagePath
    $normPath = if (Test-Path $normKey) { (Get-ItemProperty $normKey).ProfileImagePath } else { $null }

    Write-Host "BAK path:  $bakPath"
    Write-Host "NORM path: $normPath"

    # Rename .bak to correct key (delete normal key first if it exists)
    if (Test-Path $normKey) {
        Write-Warning "Removing corrupted normal key..."
        Remove-Item $normKey -Force
    }
    # Rename BAK to normal (use reg copy + delete — PowerShell can't rename registry keys directly)
    reg copy "$($bakKey -replace 'HKLM:\\','HKLM\')" "$($normKey -replace 'HKLM:\\','HKLM\')" /s /f
    Remove-Item $bakKey -Force
    Set-ItemProperty $normKey -Name 'State' -Value 0
    Write-Host "[OK] ProfileList key restored. Have user log in."
}
```

**Rollback:** Registry is modified — export the key first with `reg export "HKLM\...\ProfileList\<SID>" C:\Temp\profile_backup.reg` before making changes.

</details>

<details>
<summary>Playbook 2 — Repair or replace NTUSER.DAT</summary>

**Symptom:** Event 1509 or 1500, "cannot load the profile" / hive load error.

**Step 1 — Check for backup:**
```powershell
$profilePath = 'C:\Users\<username>'
Test-Path "$profilePath\NTUSER.DAT.LOG1"  # Should be TRUE
Test-Path "$profilePath\NTUSER.DAT.LOG2"
```

**Step 2 — Attempt hive repair with chkdsk (if file-level issue):**
```powershell
chkdsk C: /f /r  # Requires reboot
```

**Step 3 — Reset hive from backup (if hive is corrupt beyond repair):**
```powershell
# Must be done with user logged off
$profilePath = 'C:\Users\<username>'
$backupPath  = 'C:\Temp\NTUSER_BAK'

# Backup current (corrupt) hive
New-Item -ItemType Directory -Path $backupPath -Force
Copy-Item "$profilePath\NTUSER.DAT" "$backupPath\NTUSER.DAT.corrupt" -Force

# Replace with default hive (user loses personalization — warn them)
Copy-Item 'C:\Users\Default\NTUSER.DAT' "$profilePath\NTUSER.DAT" -Force
icacls "$profilePath\NTUSER.DAT" /grant "${env:USERDOMAIN}\<username>:(F)"
```

**Rollback:** Restore from `$backupPath\NTUSER.DAT.corrupt`.

</details>

<details>
<summary>Playbook 3 — Delete profile and recreate from scratch</summary>

**Use when:** Profile is beyond repair, user is willing to lose local settings.

```powershell
# RUN AS ADMINISTRATOR — user must be fully logged off
$username    = '<SAMAccountName>'
$SID         = (New-Object System.Security.Principal.NTAccount($username)).Translate(
                    [System.Security.Principal.SecurityIdentifier]).Value
$profilePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$SID").ProfileImagePath

Write-Host "Profile path: $profilePath"
Write-Host "SID: $SID"

# Backup profile folder (optional but recommended)
$backupDest = "C:\Temp\ProfileBackup_$username"
Write-Host "Backing up to $backupDest..."
robocopy $profilePath $backupDest /E /XJD /R:1 /W:1

# Remove ProfileList registry key
$regKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$SID"
Remove-Item $regKey -Force -Recurse
Write-Host "[OK] Registry key removed."

# Remove profile folder
Remove-Item $profilePath -Recurse -Force
Write-Host "[OK] Profile folder removed. User will get fresh profile on next logon."
```

**Rollback:** Restore registry key from backup: `reg import C:\Temp\profile_backup.reg`. Restore folder from `$backupDest`.

</details>

<details>
<summary>Playbook 4 — Unload orphaned hive</summary>

**Symptom:** Registry under HKU still has user's SID mounted after logoff. Next logon cannot load hive.

```powershell
# Identify loaded hives
$SID = '<user-SID>'
$hiveLoaded = Test-Path "Registry::HKEY_USERS\$SID"

if ($hiveLoaded) {
    Write-Host "Hive is loaded. Attempting to unload..."
    # Must use reg.exe — PowerShell cannot natively unload hives
    $result = reg unload "HKU\$SID" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Hive unloaded."
    } else {
        Write-Warning "Unload failed: $result"
        Write-Warning "A process may be holding the hive open. Use Sysinternals Process Monitor to identify."
    }
}
```

**If unload fails:** Use Sysinternals Handle.exe to find what process holds the hive open:
```
handle.exe -a NTUSER.DAT
```
Kill the holding process, then retry `reg unload`.

</details>

---

## Evidence Pack

```powershell
# Run as administrator — collects all evidence for escalation
$out = "C:\Temp\ProfileEvidence_$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $out -Force | Out-Null

# 1. Profile-related events
Get-WinEvent -LogName Application -MaxEvents 200 |
    Where-Object { $_.Id -in @(1500,1501,1502,1505,1509,1511,1515,1520,1521,1530,1531,1542) } |
    Export-Csv "$out\ProfileEvents.csv" -NoTypeInformation

# 2. ProfileList registry dump
reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" "$out\ProfileList.reg" /y

# 3. All profiles on this machine
Get-WmiObject -Class Win32_UserProfile |
    Select-Object LocalPath, SID, LastUseTime, Status, RoamingConfigured |
    Export-Csv "$out\WMI_UserProfiles.csv" -NoTypeInformation

# 4. Loaded hives (HKU)
Get-ChildItem Registry::HKEY_USERS |
    Select-Object Name, @{N='SubKeyCount';E={$_.SubKeyCount}} |
    Export-Csv "$out\LoadedHives.csv" -NoTypeInformation

# 5. Disk space
Get-PSDrive -PSProvider FileSystem |
    Select-Object Name, Root, @{N='UsedGB';E={[math]::Round($_.Used/1GB,2)}},
    @{N='FreeGB';E={[math]::Round($_.Free/1GB,2)}} |
    Export-Csv "$out\DiskSpace.csv" -NoTypeInformation

# 6. System info
Get-ComputerInfo | Select-Object CsName, OsName, OsVersion, OsLastBootUpTime |
    Export-Csv "$out\SystemInfo.csv" -NoTypeInformation

Write-Host "[OK] Evidence collected at: $out"
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "[OK] Archive: $out.zip"
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| List all profiles on machine | `Get-WmiObject Win32_UserProfile \| Select LocalPath,SID,Status` |
| Get profile events | `Get-WinEvent -LogName Application \| Where Id -in 1500,1509,1511` |
| Check ProfileList registry | `Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'` |
| Check current user profile path | `$env:USERPROFILE` |
| Get user's SID | `(New-Object System.Security.Principal.NTAccount('<user>')).Translate([System.Security.Principal.SecurityIdentifier]).Value` |
| Unload hive | `reg unload "HKU\<SID>"` |
| Check hive lock | `handle.exe -a NTUSER.DAT` (Sysinternals) |
| Delete profile via WMI | `(Get-WmiObject Win32_UserProfile \| Where SID -eq '<SID>').Delete()` |
| Export ProfileList backup | `reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" C:\Temp\profiles.reg` |
| Check temp profile flag | `(Get-ItemProperty 'HKLM:\...\ProfileList\<SID>').State` — 4 = temp |
| List loaded HKU hives | `Get-ChildItem Registry::HKEY_USERS` |
| Force profile unload at logoff | `Set-ItemProperty 'HKLM:\...\ProfileList' -Name 'DeleteRoamingCache' -Value 1` |

---

## 🎓 Learning Pointers

- **Why `.bak` happens:** When Windows detects NTUSER.DAT cannot be loaded (e.g., hive locked from previous session crash), it renames the ProfileList SID key to `SID.bak` and sets State=4, meaning "temp profile was used." On the next logon, it finds the `.bak` key and tries to recover — but if both keys exist in a conflicted state, recovery fails. Understanding this two-key dance is key to diagnosing most temp profile issues. [MS Docs — User Profiles](https://learn.microsoft.com/en-us/windows/win32/shell/user-profiles)

- **Registry hive transaction log:** NTUSER.DAT uses a transactional log model (LOG1 + LOG2 files). Corruption in the hive itself is rare — more commonly the hive is simply locked. Don't jump to "hive is corrupt" without first ruling out a lock. [Registry hive recovery — MS Docs](https://learn.microsoft.com/en-us/troubleshoot/windows-client/user-profiles-and-logon/registry-hive-recovery)

- **Win32_UserProfile vs ProfileList:** WMI's `Win32_UserProfile` class gives richer profile metadata than the registry alone (last use time, roaming status, load state). Use it for reporting; use the registry for low-level repair. `(Get-WmiObject Win32_UserProfile | Where SID -eq '<SID>').Delete()` is the clean way to remove a profile — it handles both registry and folder cleanup atomically.

- **FSLogix changes the failure mode entirely:** If you're troubleshooting profiles on AVD or RDS with FSLogix, NTUSER.DAT issues are almost never the cause — look at VHD(x) mount failures, share permissions, and the FSLogix frxlog (`C:\ProgramData\FSLogix\Logs`). The profile service events will still fire, but the root cause is the container layer, not the Windows profile service. [FSLogix diagnostics](https://learn.microsoft.com/en-us/fslogix/troubleshoot-fslogix)

- **Mandatory profiles and State=256:** If the ProfileList State value is 256 (0x100), the user is loading a mandatory profile (`ntuser.man`). Changes made during the session are discarded on logoff by design. This is not corruption — it's intentional. Check with your customer before "fixing" it. [Mandatory user profiles](https://learn.microsoft.com/en-us/windows/client-management/mandatory-user-profile)

- **Sysinternals Process Monitor is your friend:** When a hive won't unload, ProcMon filtered on `NTUSER.DAT` with operation `ReadFile` or `WriteFile` will immediately show which PID is holding it open. This is faster and more reliable than any other approach.
