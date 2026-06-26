# FSLogix Profile Containers — Hotfix Runbook (Mode B: Ops)
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

Run these on the **AVD Session Host** (or via Intune/RMM). Results guide which fix path to take.

```powershell
# 1. Is FSLogix service running?
Get-Service frxsvc, frxdrv | Select Name, Status

# 2. Can the session host reach the profile share?
Test-NetConnection -ComputerName "<StorageAccount>.file.core.windows.net" -Port 445

# 3. Last FSLogix operational event (past 1 hour)
Get-WinEvent -LogName "Microsoft-FSLogix-Apps/Operational" -MaxEvents 20 |
    Select TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap -AutoSize

# 4. Check current profile load state for a user
$Username = "<UPN>"
Get-WinEvent -LogName "Microsoft-FSLogix-Apps/Operational" -MaxEvents 50 |
    Where-Object Message -like "*$Username*" |
    Select TimeCreated, Id, Message | Format-Table -Wrap

# 5. Check if VHD(X) files are orphaned (locked from a previous session)
Get-WinEvent -LogName "Microsoft-FSLogix-Apps/Operational" |
    Where-Object {$_.Id -eq 27 -and $_.TimeCreated -gt (Get-Date).AddHours(-2)} |
    Select TimeCreated, Message
```

**Interpretation:**

| Finding | Action |
|---------|--------|
| `frxsvc` Stopped | Fix 1 — restart FSLogix services |
| Port 445 test fails | Fix 2 — storage account connectivity |
| Event ID 43 (profile load failed) | Check Error field — see fix map below |
| Event ID 27 (VHD locked) | Fix 3 — release locked VHD |
| Event ID 7 (profile attached successfully) | FSLogix working, problem is elsewhere |
| Empty event log | FSLogix not registering — check if it's installed correctly |

**Event ID 43 Error Code Quick Map:**

| Error Code | Meaning | Fix |
|------------|---------|-----|
| `0x80070005` | Access denied to VHD share | Fix 2 / Fix 4 |
| `0x80070035` | Network path not found | Fix 2 |
| `0x80070570` | VHD file corrupted | Fix 5 |
| `0xC0000022` | Access denied (NTFS on VHDX) | Fix 4 |
| `0x00000057` | Invalid parameter (FSLogix config) | Check registry settings |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Azure AD / Entra ID (user identity)
    │
    ▼
AVD Host Pool (session host running)
    │
    ▼
FSLogix Services: frxsvc + frxdrv (running)
    │
    ▼
Network: Session host can reach storage on TCP 445
    │
Storage Account: Azure Files or SMB file share
    │  ├── Private endpoint (preferred) or public + firewall rule
    │  └── Auth: Kerberos via AD DS (domain-joined) OR Entra Kerberos
    │
    ▼
Share ACL: Session host computer account OR user has Read+Execute+Write
    │
    ▼
NTFS on share: Users have Modify on their VHD subfolder
    │
    ▼
FSLogix Registry: VHDLocations set correctly
    │  Path: HKLM:\SOFTWARE\FSLogix\Profiles
    │
    ▼
VHDX created/attached (C:\Users\<user> redirected to VHD)
    │
    ▼
User profile loaded (explorer.exe, shell init)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm FSLogix is installed and version**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\FSLogix\Apps" -ErrorAction SilentlyContinue
# Look for: InstallDir, Version
# Expected: Version 2.9.x or higher
```
Expected output: registry key present with a version number.
Missing: FSLogix not installed — deploy via Intune or manual install from https://aka.ms/fslogix-latest

**Step 2 — Confirm VHDLocations is set**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\FSLogix\Profiles" | Select VHDLocations, Enabled, SizeInMBs
```
Expected: `VHDLocations` points to `\\<storage>.file.core.windows.net\<share>` and `Enabled = 1`.
If missing or wrong: GPO/Intune profile configuration not applied — check policy targeting.

**Step 3 — Confirm the storage share is reachable**
```powershell
$StoragePath = "\\<StorageAccount>.file.core.windows.net\<ShareName>"
Test-Path $StoragePath
# If False:
Test-NetConnection "<StorageAccount>.file.core.windows.net" -Port 445
```

**Step 4 — Confirm share permissions (Azure Files with AD DS auth)**
```powershell
# Check storage account's RBAC role assignments in Azure Portal:
# Storage Account > Access Control (IAM) > Role assignments
# Required: Session host's computer account (or user group) must have:
# "Storage File Data SMB Share Contributor" (or higher)

# Then check NTFS ACLs on the share root:
icacls $StoragePath
# Users should have: (OI)(CI)(M) — Modify, inherited
```

**Step 5 — Check FSLogix operational log for the user's session**
```powershell
$UPN = "<user@domain.com>"
$Events = Get-WinEvent -LogName "Microsoft-FSLogix-Apps/Operational" -MaxEvents 200
$UserEvents = $Events | Where-Object Message -like "*$UPN*"
$UserEvents | Sort TimeCreated | Select TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap
```
Event ID 7 = success. Event ID 43 = failure (check Message for error code).

**Step 6 — Check if profile fell back to local (temp) profile**
```powershell
# After user logs in, on the session host:
Get-WmiObject Win32_UserProfile | Where-Object LocalPath -like "*<username>*" |
    Select LocalPath, Special, RoamingConfigured
# If profile is in C:\Users\<username> AND FSLogix VHD is not mounted → temp/local profile was used
```

---

## Common Fix Paths

<details><summary>Fix 1 — FSLogix services not running</summary>

```powershell
# Restart FSLogix services
$Services = "frxsvc", "frxdrv", "frxccss"
foreach ($svc in $Services) {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s) {
        Write-Host "Restarting $svc..."
        Restart-Service $svc -Force
        Start-Sleep -Seconds 3
        Get-Service $svc | Select Name, Status
    } else {
        Write-Host "$svc not found — FSLogix may not be installed" -ForegroundColor Yellow
    }
}

# If services fail to start, check the filter driver
fltMC | Select-String frx
# Expected: frxdrv and frxccd should appear in the list

# If not: reinstall FSLogix
# Download: https://aka.ms/fslogix-latest
# Silent install: .\FSLogixAppsSetup.exe /install /quiet /norestart
```

</details>

<details><summary>Fix 2 — Session host cannot reach storage (TCP 445)</summary>

```powershell
$StorageHost = "<StorageAccount>.file.core.windows.net"

# Test connectivity
$Test = Test-NetConnection $StorageHost -Port 445
if (-not $Test.TcpTestSucceeded) {
    Write-Host "Port 445 BLOCKED. Check:" -ForegroundColor Red
    Write-Host "  1. Azure Storage Account firewall — is the session host's VNet/subnet in the allowed list?"
    Write-Host "  2. NSG rules on the session host's subnet — outbound port 445 to storage?"
    Write-Host "  3. If using Private Endpoint: does DNS resolve to 10.x.x.x (private IP)?"
    
    Resolve-DnsName $StorageHost
    # If this returns a PUBLIC IP (e.g. 52.x.x.x) when you expected private:
    # Private DNS zone for 'privatelink.file.core.windows.net' is not linked to your VNet
} else {
    Write-Host "TCP 445 OK — connectivity is fine." -ForegroundColor Green
}
```

**Azure-side checks (Portal):**
- Storage Account > Networking > Firewalls and virtual networks → add session host VNet/subnet
- If using Private Endpoint: check Private DNS Zone `privatelink.file.core.windows.net` is linked to the session host's VNet

</details>

<details><summary>Fix 3 — VHD locked from previous session (Event ID 27)</summary>

```powershell
# A VHDX file stays locked if a session didn't cleanly terminate
# Find the user's VHD path
$SharePath = "\\<StorageAccount>.file.core.windows.net\<ShareName>"
$Username  = "<SamAccountName>"
$UserVHD   = Get-ChildItem "$SharePath\$Username*" -Recurse -Filter "*.vhd*" -ErrorAction SilentlyContinue
$UserVHD | Select FullName, LastWriteTime

# Check which host has the file locked (if multi-host pool)
# Use Azure Portal: Storage Account > File shares > <share> > Browse > navigate to user folder > right-click file > Properties

# If the locking session host is known and accessible:
# On that host — check for ghost sessions:
qwinsta
# If the session shows Disconnected (not Active), drain it:
logoff <SessionID>

# If the host is unreachable, break the lock via Azure:
# Portal: Storage Account > File Shares > <share> > ... > Manage snapshots (the VHDX will be unlocked after storage-side lock release — may require waiting for lease timeout ~60s)

# Force unlock via PowerShell (requires Az module and Storage Owner role):
$ctx = (Get-AzStorageAccount -ResourceGroupName "<RG>" -Name "<StorageAccount>").Context
$share = Get-AzStorageShare -Name "<ShareName>" -Context $ctx
# Breaks the lease on the blob/file — use with caution
```

**Safe procedure:** Ask if the user was connected to another host. If yes, log them off from that host's session first, then retry login.

</details>

<details><summary>Fix 4 — Access denied to VHD share (0x80070005 / 0xC0000022)</summary>

```powershell
# Two separate ACL layers to check:

# LAYER 1: Azure RBAC (for Azure Files with AD DS or Entra Kerberos auth)
# In Azure Portal: Storage Account > Access Control (IAM)
# The USERS (or their group) need: "Storage File Data SMB Share Contributor"
# The session HOST computer accounts need the same role if using computer-based auth

# LAYER 2: NTFS on the share
$SharePath = "\\<StorageAccount>.file.core.windows.net\<ShareName>"
icacls $SharePath

# Required ACEs:
# CREATOR OWNER: (OI)(CI)(IO)(F)   — Full for owner
# <DOMAIN>\Domain Users: (OI)(CI)(M) — Modify, inherited (so each user can create their VHD folder)
# BUILTIN\Administrators: (OI)(CI)(F) — Full for admins

# Apply correct NTFS ACL:
icacls $SharePath /grant "CREATOR OWNER:(OI)(CI)(IO)(F)"
icacls $SharePath /grant "<DOMAIN>\Domain Users:(M)"
icacls $SharePath /grant "BUILTIN\Administrators:(OI)(CI)(F)"
```

**Note:** FSLogix creates a subfolder per user (`<SharePath>\<Username>_<SID>\Profile_<Username>.vhd`). The user only needs Modify on their own subfolder, but needs Write on the share root to create it on first login.

</details>

<details><summary>Fix 5 — Corrupted VHDX (Event ID 43, error 0x80070570)</summary>

```powershell
# Corrupted VHDX — user cannot log in and gets temp profile
$SharePath = "\\<StorageAccount>.file.core.windows.net\<ShareName>"
$Username  = "<SamAccountName>"
$UserFolder = "$SharePath\$Username*"

# Step 1: Back up the corrupted VHDX
$BackupDest = "$SharePath\_Corrupted_Backup"
New-Item -ItemType Directory -Path $BackupDest -Force
Copy-Item "$UserFolder\*.vhd*" -Destination $BackupDest -Force

# Step 2: Run CHKDSK on the VHDX (requires mounting it)
# Mount the VHDX on an admin machine (NOT while user is logged in):
Mount-VHD -Path "<localcopy>\Profile_$Username.vhdx" -ReadOnly:$false
$DriveLetter = (Get-VHD "<localcopy>\Profile_$Username.vhdx").DiskNumber
$DriveLetter = (Get-Disk -Number $DriveLetter | Get-Partition | Where DriveLetter).DriveLetter
Repair-Volume -DriveLetter $DriveLetter -Scan
Repair-Volume -DriveLetter $DriveLetter -SpotFix
Dismount-VHD -Path "<localcopy>\Profile_$Username.vhdx"

# Step 3: Replace the share copy with the repaired one
Copy-Item "<localcopy>\Profile_$Username.vhdx" -Destination "$UserFolder" -Force

# If repair fails — user gets a new (empty) profile:
# Rename the corrupted file to .old so FSLogix creates a fresh one
Rename-Item "$UserFolder\Profile_$Username.vhdx" "Profile_$Username.vhdx.OLD"
```

**Warning:** Renaming/replacing VHDs causes data loss for the user's profile contents (Desktop, Documents if redirected to VHD). Always back up first and confirm scope with user and manager.

</details>

---

## Escalation Evidence

```
=== FSLogix Escalation Pack ===
Date/Time:          _______________
Session Host Name:  _______________
User UPN:           _______________
AVD Host Pool:      _______________
Storage Account:    _______________
Share Path:         _______________
FSLogix Version:    _______________  (HKLM:\SOFTWARE\FSLogix\Apps)

Symptoms:
[ ] User gets temp profile    [ ] Login hangs    [ ] Access denied    [ ] Profile corrupted

VHD file present on share:    YES / NO
VHD file size:                _____ MB
Last modified:                _______________

TCP 445 test result:          SUCCESS / FAIL
Event ID 43 error code:       0x_______________

Recent FSLogix events (paste output of Get-WinEvent -LogName "Microsoft-FSLogix-Apps/Operational" -MaxEvents 20):

[paste here]

Actions taken so far:
1.
2.
3.

Escalation contact: Microsoft Support via Azure Portal > New Support Request
Reference: https://docs.microsoft.com/en-us/fslogix/
```

---

## 🎓 Learning Pointers

- **FSLogix is the only supported profile solution for AVD** — traditional roaming profiles and UPDs (User Profile Disks) don't work reliably in multi-session environments. FSLogix attaches the VHDX at login, making the profile appear local while it lives on a share. See [FSLogix overview](https://docs.microsoft.com/en-us/fslogix/overview).

- **Event ID 7 = success, Event ID 43 = failure** — memorise these. The Operational log at `Microsoft-FSLogix-Apps/Operational` is the single most useful diagnostic source. Filter by the user's UPN to isolate their session.

- **Azure Files with Entra Kerberos vs AD DS auth** — there are two supported auth models. Entra Kerberos (no on-prem AD required) is simpler for cloud-native deployments; AD DS Kerberos is required for hybrid-joined hosts. Mixing them in the same host pool causes intermittent auth failures. See [Azure Files AD auth docs](https://docs.microsoft.com/en-us/azure/storage/files/storage-files-identity-auth-hybrid-identities-enable).

- **Locked VHDs are the #1 support call** — a VHD stays locked if the session host crashed, lost connectivity, or the user was force-disconnected. The lock has a storage-lease timeout (~60 seconds after the session host releases it). Always check whether the user is still ghosted on another host before breaking the lock.

- **Cloud Cache is the high-availability option** — FSLogix Cloud Cache writes the profile to multiple storage locations simultaneously and the client reads from whichever responds first. This eliminates single-point-of-failure on the share at the cost of higher write IOPS. Consider it for production deployments with strict RTO requirements. See [Cloud Cache docs](https://docs.microsoft.com/en-us/fslogix/cloud-cache-resiliency-availability-cncpt).
