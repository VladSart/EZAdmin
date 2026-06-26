# FSLogix Profile Containers — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How FSLogix Works](#how-fslogix-works)
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

| Item | Detail |
|------|--------|
| Product | FSLogix Profile Containers (VHD/VHDX) on Azure Virtual Desktop or RDS |
| Applies to | AVD multi-session hosts, RDS session hosts, persistent/non-persistent pools |
| Storage backends | Azure Files (SMB), Azure NetApp Files, Storage Spaces Direct |
| FSLogix version | 2210+ (bundled with AVD host agent since 2022) |
| Auth model | Kerberos (preferred), NTLM fallback — Azure Files requires identity-based auth |
| Out of scope | FSLogix App Masking, Office Container (covered separately) |

---

## How FSLogix Works

<details><summary>Full architecture</summary>

FSLogix intercepts Windows profile loading at the kernel level using a filter driver (`frxdrv.sys`). At logon, the filter driver:

1. **Mounts** a VHD/VHDX file from a network share as a local disk volume
2. **Redirects** the user's profile path (`C:\Users\<username>`) to the mounted VHD via a junction point and registry redirect
3. **Merges** the profile container with the local temp profile shell so Windows sees a single coherent profile

At logoff, the VHD is cleanly detached and the session's write layer is discarded (for non-persistent pools).

```
USER LOGON
    │
    ▼
frxdrv.sys (filter driver intercepts profile load)
    │
    ├─► Connect to SMB share ──► \\<storage>\<share>\<username>\Profile_<username>.vhdx
    │
    ├─► Mount VHDX as disk volume (e.g. \\.\PHYSICALDRIVE3)
    │
    ├─► Attach volume → assign drive letter or mount point
    │
    ├─► Create junction: C:\Users\<username> → <mount>\Profile\AppData (etc.)
    │
    └─► Profile load continues — Windows sees local disk, not network path

USER LOGOFF
    │
    ▼
frxdrv.sys detaches volume → VHDX file on share updated → session terminates
```

**Identity-based auth for Azure Files:**
Azure Files uses either:
- **Kerberos via Entra Kerberos** (cloud-only identities — recommended)
- **AD DS Kerberos** (hybrid — AD-joined hosts authenticate to on-prem AD which has a computer account for the storage account)
- **NTLM** (legacy fallback — never use for production, blocks SMB signing)

**VHDX size:**
Default max is 30 GB (configurable). FSLogix uses dynamic VHDX so actual disk usage is less. The VHDX grows as data is written and does not shrink automatically — compaction requires `Optimize-VHD`.

**Concurrent sessions:**
By default, FSLogix does NOT support concurrent multi-session attach (same user, two hosts simultaneously). `ProfileType=3` (R/W + RO shadow) enables concurrent sessions but with caveats.
</details>

---

## Dependency Stack

```
User Session (AVD/RDS)
    │
    └─ frxdrv.sys (FSLogix filter driver — must be running)
         │
         └─ SMB 3.x connection to storage backend
              │
              ├─ Azure Files (SMB)
              │    ├─ Storage account firewall (must allow AVD subnet or "Allow Azure services")
              │    ├─ Private endpoint (recommended for AVD)
              │    ├─ Identity auth: Entra Kerberos OR AD DS join of storage account
              │    └─ NTFS permissions on share + directory level
              │
              ├─ Azure NetApp Files
              │    ├─ ANF subnet delegation (Microsoft.NetApp/volumes)
              │    ├─ AD join of ANF account (AD DS required)
              │    └─ Export policy (NFSv3/SMBv3 with correct CIDR)
              │
              └─ Storage Spaces Direct (on-prem/hybrid)
                   ├─ SMB server reachable from session host
                   └─ Kerberos to on-prem AD
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Temp profile assigned, VHD not mounting | SMB connectivity failure or auth error | Event 33 in FSLogix log; `Test-NetConnection -Port 445` |
| Profile loads but slow (30-60s extra) | SMB session negotiation delay / NTLM fallback | Check `frxlog.txt` for "NTLM" vs "Kerberos"; check Kerberos ticket issuance |
| VHD stuck locked — user can't log on | Previous session did not clean up (crash/forced logoff) | Check for `Profile_<user>.vhdx.lock` file or open handle on storage |
| Profile container grows unbounded | AppData pollution (Teams cache, browser cache) | Check VHDX size; enable redirect exclusions |
| Concurrent logon from second device fails | ProfileType=0 (default) doesn't support multi-attach | Switch to ProfileType=3 if business requires concurrent sessions |
| "Profile failed to attach" — Event ID 26 | VHDX corruption | Attempt `Repair-VHD`; restore from backup |
| User missing Office activations after logon | Office Container not configured / ODFC missing | Check `HKLM\SOFTWARE\FSLogix\Profiles\IncludeOfficeActivation` |
| FSLogix not applying — local profile loads | Service not running or registry policy missing | `Get-Service frxsvc`; check `HKLM\SOFTWARE\FSLogix\Profiles\Enabled` |
| Event 43 — VHD max size reached | Container hit 30 GB limit | Expand VHDX; check exclusions for large caches |

---

## Validation Steps

**1 — Confirm FSLogix service & driver**
```powershell
Get-Service frxsvc, frxccds | Select-Object Name, Status, StartType
# Expected: Running, Automatic

Get-WindowsDriver -Online | Where-Object OriginalFileName -like "*frxdrv*" | Select-Object OriginalFileName, Version
# Expected: frxdrv.sys present with version 2.x
```
Bad: Service stopped or driver absent → reinstall FSLogix agent.

**2 — Confirm registry configuration**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\FSLogix\Profiles" | Select-Object Enabled, VHDLocations, DeleteLocalProfileWhenVHDShouldApply, SizeInMBs
# Expected: Enabled=1, VHDLocations points to \\<share>\<path>, SizeInMBs >= 30720
```
Bad: Enabled=0 or VHDLocations empty → GPO/Intune policy not applying.

**3 — Test SMB connectivity from session host**
```powershell
$share = (Get-ItemProperty "HKLM:\SOFTWARE\FSLogix\Profiles").VHDLocations
Test-NetConnection -ComputerName ($share -replace '\\\\([^\\]+)\\.*','$1') -Port 445
# Expected: TcpTestSucceeded = True
```
Bad: TcpTestSucceeded = False → NSG/firewall blocking port 445.

**4 — Check Azure Files identity auth**
```powershell
# On the session host, test Kerberos ticket for the storage account
klist
# Look for krbtgt and cifs/<storageaccount>.file.core.windows.net
```
Bad: No CIFS ticket → Entra Kerberos not configured or AD DS not syncing storage account object.

**5 — Check NTFS permissions on share root**
```powershell
$share = (Get-ItemProperty "HKLM:\SOFTWARE\FSLogix\Profiles").VHDLocations
$acl = Get-Acl $share
$acl.Access | Select-Object IdentityReference, FileSystemRights, AccessControlType
# Expected: "Creator Owner" = Modify; AVD users group = ListDirectory + CreateFiles; SYSTEM = FullControl
```
Bad: Users lacking CreateFiles → VHD creation will fail silently.

**6 — Review FSLogix operational log**
```powershell
$logPath = "C:\ProgramData\FSLogix\Logs\Profile"
Get-ChildItem $logPath | Sort-Object LastWriteTime -Descending | Select-Object -First 5
# Open frxlog.txt — search for ERROR, WARN, or the affected user's UPN
```

**7 — Check for locked VHDX**
```powershell
# On storage host or via storage admin — check for .lock files
$share = "\\<storageaccount>.file.core.windows.net\<share>"
Get-ChildItem "$share\<username>" -Recurse -Filter "*.lock" -ErrorAction SilentlyContinue
```
Bad: `.lock` file present → session did not clean up. See remediation.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Profile Not Mounting (Temp Profile)

1. Confirm FSLogix service running (Step 1 above).
2. Check Event Viewer: `Applications and Services Logs > Microsoft > FSLogix > Apps > Operational` — Event IDs 26 (error), 33 (VHD not found), 98 (access denied).
3. Test SMB port 445 from session host to storage FQDN (Step 3).
4. Run `klist` — verify Kerberos tickets for storage account (Step 4).
5. Verify NTFS permissions (Step 5) — **Creator Owner must have Modify, not just Read**.
6. Check if `VHDLocations` registry value is set (Step 2).
7. Check storage account firewall: Azure Portal → Storage Account → Networking → ensure session host subnet is allowed.

### Phase 2 — Slow Profile Load

1. Open `frxlog.txt`, search for "Kerberos" and "NTLM". NTLM auth adds 2-10 seconds per logon.
2. If NTLM: configure Entra Kerberos (cloud-only) or verify AD DS computer account for storage account exists and password hasn't expired (rotates every 30 days automatically via AD sync).
3. Check if Azure Files private endpoint is configured — public endpoint adds DNS resolution latency.
4. Check VHD size (`Get-VHD` if accessible) — oversized VHDs take longer to mount.
5. Review redirections exclusions for large caches (Teams, Chrome, Edge).

### Phase 3 — Locked VHDX / "Profile in use"

1. Identify if user has an active session on another host: `query session /server:<host>`.
2. If no active sessions, check for ghost lock files (Step 7 above).
3. Delete `.lock` file from storage share (with care — confirm no active session).
4. If VHD handle is open, use `handle.exe` (Sysinternals) on the session host or check Azure Files metrics for open file handles in the portal.
5. Force-close open handles: Azure Portal → Storage Account → File shares → Open handles → Close.

### Phase 4 — VHD Corruption

1. Check Event ID 26 in FSLogix log for "failed to attach" with error code.
2. Attempt repair: `Repair-VHD -Path "\\<share>\<user>\Profile_<user>.vhdx" -RepairType Full` (requires Hyper-V module).
3. If repair fails, rename corrupt VHD (preserve for forensics) and let FSLogix create a new one on next logon (user loses profile data).
4. Restore from Azure Files snapshots if available (Portal → File Share → Snapshots).

---

## Remediation Playbooks

<details><summary>Playbook 1 — Configure Entra Kerberos for Azure Files (cloud-only identities)</summary>

```powershell
# Run on a hybrid-joined or Entra-joined admin machine with AzureAD + Az.Storage modules

# 1. Enable Entra Kerberos on the storage account
$resourceGroupName = "<ResourceGroup>"
$storageAccountName = "<StorageAccount>"

Update-AzStorageAccount -ResourceGroupName $resourceGroupName `
    -StorageAccountName $storageAccountName `
    -EnableAzureActiveDirectoryKerberosForFile $true `
    -ActiveDirectoryDomainName "<yourdomain.com>" `
    -ActiveDirectoryDomainGuid "<domain-guid>"

# 2. Assign IAM role: Storage File Data SMB Share Contributor
# This is needed for users to read/write their profile VHDs
$scope = "/subscriptions/<subId>/resourceGroups/$resourceGroupName/storageAccounts/$storageAccountName/fileServices/default/fileshares/<sharename>"
New-AzRoleAssignment -ObjectId "<AVD-users-group-objectId>" `
    -RoleDefinitionName "Storage File Data SMB Share Contributor" `
    -Scope $scope

# 3. Set NTFS permissions on the share root
# Connect via net use with storage account key first, then set ACLs
$storageKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $storageAccountName)[0].Value
net use Z: "\\$storageAccountName.file.core.windows.net\<sharename>" /user:"AZURE\$storageAccountName" $storageKey

icacls Z:\ /grant "CREATOR OWNER:(OI)(CI)(IO)(M)"
icacls Z:\ /grant "<DOMAIN\AVDUsers>:(M)"
icacls Z:\ /grant "BUILTIN\Administrators:(OI)(CI)(F)"
icacls Z:\ /grant "NT AUTHORITY\SYSTEM:(OI)(CI)(F)"
net use Z: /delete
```

**Rollback:** Disable Entra Kerberos via `Update-AzStorageAccount -EnableAzureActiveDirectoryKerberosForFile $false`. Users will fall back to NTLM or storage key auth.
</details>

<details><summary>Playbook 2 — Remove a locked VHDX and reset user profile</summary>

```powershell
param(
    [Parameter(Mandatory)][string]$UPN,
    [Parameter(Mandatory)][string]$ProfileShare  # e.g. \\sa.file.core.windows.net\profiles
)

$username = ($UPN -split '@')[0]
$profileFolder = Join-Path $ProfileShare $username

Write-Host "Checking for active sessions for $username..." -ForegroundColor Cyan
# Query all session hosts if you have a list
# query session /server:<host> | Select-String $username

Write-Host "Checking for lock files in: $profileFolder" -ForegroundColor Cyan
$lockFiles = Get-ChildItem $profileFolder -Filter "*.lock" -Recurse -ErrorAction SilentlyContinue
if ($lockFiles) {
    Write-Warning "Lock files found:"
    $lockFiles | ForEach-Object { Write-Host $_.FullName }
    $confirm = Read-Host "Remove lock files? (yes/no)"
    if ($confirm -eq 'yes') {
        $lockFiles | Remove-Item -Force
        Write-Host "Lock files removed. User can now log on." -ForegroundColor Green
    }
} else {
    Write-Host "No lock files found. Issue may be an open handle — check Azure Portal." -ForegroundColor Yellow
}
```
</details>

<details><summary>Playbook 3 — Expand a full VHDX container</summary>

```powershell
param(
    [Parameter(Mandatory)][string]$VHDXPath,  # UNC path to the VHDX
    [int]$NewSizeGB = 50
)

# NOTE: User must be logged off before expanding
$newSizeBytes = $NewSizeGB * 1GB

# Expand the VHDX
Resize-VHD -Path $VHDXPath -SizeBytes $newSizeBytes
Write-Host "VHDX expanded to $NewSizeGB GB. User must log on — Windows will extend the partition." -ForegroundColor Green
# FSLogix automatically extends the NTFS partition inside the VHD at next attach
```

**Rollback:** You cannot shrink a VHDX below its used space without tools like `Optimize-VHD -Mode Full` (compacts) followed by `Resize-VHD`. Expanding is one-way in practice.
</details>

<details><summary>Playbook 4 — Add profile exclusions to reduce VHDX bloat</summary>

```powershell
# Apply via Intune (Settings Catalog) or GPO
# Registry path: HKLM\SOFTWARE\FSLogix\Profiles

$exclusions = @(
    "AppData\Local\Microsoft\Teams\meeting-addin",
    "AppData\Local\Microsoft\Teams\packages",
    "AppData\Local\Google\Chrome\User Data\Default\Cache",
    "AppData\Local\Microsoft\Edge\User Data\Default\Cache",
    "AppData\Local\Temp",
    "AppData\LocalLow\Sun\Java\Deployment\cache"
)

$regPath = "HKLM:\SOFTWARE\FSLogix\Profiles"

# ExcludeList_ISM entries (user-specific paths that are excluded from the container)
for ($i = 0; $i -lt $exclusions.Count; $i++) {
    Set-ItemProperty -Path $regPath -Name "ExcludeList_ISM$i" -Value $exclusions[$i] -Type String
}

Write-Host "Exclusions configured. Takes effect at next user logon." -ForegroundColor Green
```
</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  FSLogix Evidence Collector — gathers all diagnostic data for escalation
.NOTES     Run on the AVD session host (or via RMM on affected host). No admin required for most checks.
#>

$report = [System.Collections.Generic.List[string]]::new()
$report.Add("=== FSLogix Evidence Pack - $(Get-Date -Format 'yyyy-MM-dd HH:mm') ===`n")

# FSLogix version & services
$report.Add("--- FSLogix Services ---")
Get-Service frxsvc, frxccds -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType |
    ForEach-Object { $report.Add($_ | Out-String) }

# Registry config
$report.Add("`n--- FSLogix Registry (HKLM:\SOFTWARE\FSLogix\Profiles) ---")
try {
    $reg = Get-ItemProperty "HKLM:\SOFTWARE\FSLogix\Profiles"
    $report.Add("Enabled: $($reg.Enabled)")
    $report.Add("VHDLocations: $($reg.VHDLocations)")
    $report.Add("SizeInMBs: $($reg.SizeInMBs)")
    $report.Add("DeleteLocalProfileWhenVHDShouldApply: $($reg.DeleteLocalProfileWhenVHDShouldApply)")
    $report.Add("ProfileType: $($reg.ProfileType)")
} catch { $report.Add("ERROR reading registry: $_") }

# SMB connectivity
$report.Add("`n--- SMB Connectivity ---")
try {
    $share = (Get-ItemProperty "HKLM:\SOFTWARE\FSLogix\Profiles").VHDLocations
    $server = ($share -replace '\\\\([^\\]+)\\.*','$1')
    $tcpTest = Test-NetConnection -ComputerName $server -Port 445 -WarningAction SilentlyContinue
    $report.Add("Target: $server | Port 445: $($tcpTest.TcpTestSucceeded)")
} catch { $report.Add("ERROR testing SMB: $_") }

# Kerberos tickets
$report.Add("`n--- Kerberos Tickets (klist) ---")
$klist = & klist 2>&1
$report.Add($klist | Out-String)

# Recent FSLogix log (last 100 lines)
$report.Add("`n--- FSLogix Log (last 100 lines) ---")
$logPath = "C:\ProgramData\FSLogix\Logs\Profile"
$latestLog = Get-ChildItem $logPath -Filter "frxlog.txt" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestLog) {
    Get-Content $latestLog.FullName -Tail 100 | ForEach-Object { $report.Add($_) }
} else { $report.Add("Log not found at $logPath") }

# FSLogix events
$report.Add("`n--- FSLogix Event Log (last 20 errors/warnings) ---")
Get-WinEvent -LogName "Microsoft-FSLogix-Apps/Operational" -MaxEvents 50 -ErrorAction SilentlyContinue |
    Where-Object Level -in 2,3 |
    Select-Object -First 20 |
    ForEach-Object { $report.Add("[$($_.TimeCreated)] ID:$($_.Id) $($_.Message.Substring(0,[Math]::Min(200,$_.Message.Length)))") }

# Output
$outPath = "$env:TEMP\FSLogix-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
$report | Out-File $outPath -Encoding UTF8
Write-Host "Evidence saved to: $outPath" -ForegroundColor Green
$outPath
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check FSLogix service | `Get-Service frxsvc` |
| Show FSLogix config | `Get-ItemProperty HKLM:\SOFTWARE\FSLogix\Profiles` |
| Test SMB port | `Test-NetConnection -ComputerName <fqdn> -Port 445` |
| Show Kerberos tickets | `klist` |
| Check VHDX size | `Get-VHD "\\<share>\<user>\Profile_<user>.vhdx"` |
| Expand VHDX | `Resize-VHD -Path <path> -SizeBytes <bytes>` |
| Repair VHDX | `Repair-VHD -Path <path> -RepairType Full` |
| Compact VHDX | `Optimize-VHD -Path <path> -Mode Full` |
| List open SMB handles (Azure) | Azure Portal → Storage Account → File shares → Open handles |
| Find lock files | `Get-ChildItem <share>\<user> -Filter *.lock` |
| Force FSLogix log | `frxtray.exe` → Show Logs |
| Check FSLogix events | `Get-WinEvent -LogName Microsoft-FSLogix-Apps/Operational -MaxEvents 50` |
| Set VHD location via reg | `Set-ItemProperty HKLM:\SOFTWARE\FSLogix\Profiles VHDLocations "\\<server>\<share>"` |
| Test profile redirect | `whoami /upn && echo %USERPROFILE%` |

---

## 🎓 Learning Pointers

- **FSLogix filter driver model:** The kernel-mode filter driver (`frxdrv.sys`) is why FSLogix is faster than traditional roaming profiles — it presents the VHD as a local volume, eliminating the copy-on-logon overhead. See: [FSLogix architecture overview](https://learn.microsoft.com/en-us/fslogix/overview-what-is-fslogix)
- **Entra Kerberos vs AD DS:** For cloud-only (Entra-only) environments, Entra Kerberos is the only supported identity-based auth for Azure Files — NTLM won't provide identity. Hybrid environments should prefer AD DS for lowest latency. [Azure Files identity auth](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-identity-auth-hybrid-identities-enable)
- **ProfileType=3 (concurrent sessions):** Allows one R/W primary and multiple R/O shadow containers. Use with caution — write conflicts between sessions are not merged. Only the last-to-logoff session "wins" for any conflicting keys. [FSLogix concurrent access](https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings?tabs=profiles#profiletype)
- **VHDX compaction cadence:** Dynamic VHDs grow automatically but never shrink. Plan a quarterly `Optimize-VHD -Mode Full` job run against profile shares during off-hours. Failing to do this leads to storage cost creep.
- **Office Container (ODFC):** For Office telemetry, activation, and OneNote data, a separate Office Container (ODFC) is recommended alongside the profile container. This separates Teams/Office churn from user profile data and simplifies backup/restore.
- **Azure Files snapshot policy:** Configure snapshot schedules on the profile file share (daily minimum, 7-day retention) so individual VHD files can be restored without restoring the whole share. [Azure Files snapshots](https://learn.microsoft.com/en-us/azure/storage/files/storage-snapshots-files)
