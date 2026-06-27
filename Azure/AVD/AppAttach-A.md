# MSIX App Attach — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the full architecture of MSIX App Attach in AVD: VHD/VHDX mounting, CIM containers, package staging, registration, and deregistration.

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

| Item | Value |
|------|-------|
| Scope | Azure Virtual Desktop — MSIX App Attach (VHD/VHDX and CimFS containers) |
| Audience | L2/L3 AVD engineers troubleshooting application delivery failures |
| Assumes | Host pool with session hosts, Azure Files share for MSIX images, Entra-joined or hybrid-joined hosts |
| Out of scope | Traditional App-V, FSLogix profile containers (see FSLogix-A.md) |

---

## How It Works

<details><summary>Full architecture — MSIX App Attach lifecycle</summary>

MSIX App Attach delivers applications to AVD session hosts without installing them. The process has four distinct phases:

**Phase 1 — Stage (VHD Mount)**
```
Azure Files Share (\\storage.file.core.windows.net\msix-packages\)
         │
         │  SMB 3.0 over port 445
         ▼
Session Host (HV Service)
    Mount-DiskImage → VHD/VHDX or CimFS (.cim)
    Drive letter assigned (e.g., Z:\) or volume GUID
```
The host mounts the container at user sign-in (or pre-stage). CimFS containers are preferred over VHD for read performance — they're read-only, composite image format designed for this workload.

**Phase 2 — Register**
```
Mounted volume (Z:\<PackageName>\)
         │
         │  AppX service reads manifest
         ▼
    Add-AppxPackage -Path Z:\<PackageName>\AppxManifest.xml
                    -Register
                    -DisableDevelopmentMode
```
Registration associates the package with the user session. The app appears in Start Menu. Files remain on the mounted share — nothing is copied locally.

**Phase 3 — Use**
```
User launches app → Shell activates package
    AppX runtime resolves VFS (Virtual File System) from mount
    COM registration served from mounted container
    User data written to local AppData (not the package)
```

**Phase 4 — Deregister & Destage (sign-out)**
```
Sign-out → Remove-AppxPackage (user scope)
         → Dismount-DiskImage
         → Volume released
```

**CimFS vs VHD/VHDX comparison:**
| Feature | VHD/VHDX | CimFS (.cim) |
|---------|----------|--------------|
| Concurrent mounts | Limited (VHD: 1 writer) | Unlimited readers |
| Mount speed | Slower (HV stack) | Faster (filter driver) |
| Antivirus scanning | Scans each file | Container-level exclusion |
| Requires | Hyper-V service | CimFS driver (Win 10 2004+) |
| Recommended for | Small deployments | Production AVD |

**Key processes and services:**
- `ShellHWDetection` — autoplay/mount notifications
- `AppXSVC` — AppX deployment service (runs registration)
- `CimFS.sys` — kernel filter driver for CIM containers
- AVD Agent — orchestrates stage/register calls via `MsixManager.exe`

</details>

---

## Dependency Stack

```
Azure Files Share (SMB 445)
        │
        ▼
Network connectivity: Session Host → storage endpoint
        │  (Private Endpoint preferred; check NSG/firewall)
        ▼
Storage Account RBAC
   └─ Session Host computer account: Storage File Data SMB Share Reader
   └─ (or MSI/service principal if not domain-joined to storage)
        │
        ▼
VHD/CimFS container file (.vhdx / .cim)
        │
        ▼
Host pool MSIX package assignment (AVD portal / ARM)
        │
        ▼
Session Host: Hyper-V service (VHD) or CimFS driver
        │
        ▼
AppX Deployment Service (AppXSVC) — runs as SYSTEM
        │
        ▼
User session — package registered per-user
        │
        ▼
Application launches (no local install)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| App missing from Start Menu after sign-in | Package not registered — staging failed | Event Log: Microsoft-Windows-AppXDeployment-Server |
| "App failed to start" / error 0x80073D0A | VHD not mounted / CimFS driver issue | `Get-DiskImage`, check Hyper-V service |
| Package visible but crashes immediately | VFS path broken — container dismounted mid-session | `Get-AppxPackage -AllUsers` — check PackageStatus |
| Slow app launch (10–30s) | VHD mount latency — file share throughput | Azure Files metrics (SuccessE2ELatency) |
| Error 0x80080204 | AppXSVC cannot access the manifest | Storage permission issue on computer account |
| Error during staging — "The system cannot find the path" | UNC path wrong in AVD package assignment | Re-check `\\<storageAccount>.file.core.windows.net\<share>\<package>` |
| App works for some users not others | User assignment scope wrong in host pool | Check app group assignment in AVD |
| CimFS mount fails with driver error | CimFS driver not installed / outdated OS | Verify OS build ≥ 19041; check `Get-WindowsDriver` |
| After host pool image update, apps broken | Package assignment still pointing to old path | Update package path in AVD portal |
| High CPU on session host at logon | Too many packages staging simultaneously | Stagger pre-stage or reduce package count |

---

## Validation Steps

**1. Confirm Azure Files SMB connectivity from session host:**
```powershell
# Run on session host
$storageAccount = "<storageAccountName>"
$share = "<shareName>"
Test-NetConnection -ComputerName "$storageAccount.file.core.windows.net" -Port 445
```
Expected: `TcpTestSucceeded: True`
Bad: `False` → NSG blocks 445, or Private Endpoint DNS not resolving

**2. Confirm storage RBAC on computer account:**
```powershell
# Run from management host with Az module
$storageAccountName = "<storageAccountName>"
$rg = "<resourceGroup>"
$sa = Get-AzStorageAccount -Name $storageAccountName -ResourceGroupName $rg
Get-AzRoleAssignment -Scope $sa.Id | Where-Object { $_.RoleDefinitionName -like "*Storage File*" }
```
Expected: Computer account (or MSI) has `Storage File Data SMB Share Reader` role.

**3. Confirm the MSIX package assignment in AVD:**
```powershell
# Using Az.DesktopVirtualization module
Get-AzWvdMsixPackage -HostPoolName "<hostPool>" -ResourceGroupName "<rg>"
```
Check: `Path` matches the current UNC path. `IsActive: True`. `IsRegularRegistration` or `IsFirstLogon` set appropriately.

**4. Check staging event log on session host:**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-AppXDeploymentServer/Operational" -MaxEvents 50 |
    Where-Object { $_.LevelDisplayName -ne "Information" } |
    Select-Object TimeCreated, Id, Message |
    Format-List
```
Event ID 400x range = staging errors; 821x range = registration errors.

**5. Verify mounted disk images:**
```powershell
Get-DiskImage | Select-Object ImagePath, Attached, DevicePath, StorageType
```
Expected: Packages currently in use appear with `Attached: True`.

**6. Verify registered AppX packages (user scope):**
```powershell
Get-AppxPackage -AllUsers | Where-Object { $_.PackageUserInformation -like "*Staged*" -or $_.PackageUserInformation -like "*Installed*" } |
    Select-Object Name, PackageFullName, PackageUserInformation
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Storage & Network

**Step 1.1 — Verify SMB port 445**
```powershell
Test-NetConnection -ComputerName "<storageAccount>.file.core.windows.net" -Port 445
```
If fails: Check NSG on subnet, check Private Endpoint DNS (`Resolve-DnsName`), check Azure Files firewall (requires "Allow from selected virtual networks").

**Step 1.2 — Verify DNS resolution of storage endpoint**
```powershell
Resolve-DnsName "<storageAccount>.file.core.windows.net" -Type A
```
With Private Endpoint: should resolve to `10.x.x.x` (private IP).
Without: resolves to public Azure IP. Either can work if firewall permits.

**Step 1.3 — Validate RBAC on computer account**
If host is Entra-joined (not hybrid), use a managed identity. Assign `Storage File Data SMB Share Reader` at the storage account scope.

---

### Phase 2: Package Assignment & Container Health

**Step 2.1 — Verify package path is accessible from session host**
```powershell
$uncPath = "\\<storageAccount>.file.core.windows.net\<share>\<PackageFolder>\<Package>.vhdx"
Test-Path $uncPath
```
If `False`: Path wrong, permissions missing, or share not accessible.

**Step 2.2 — Validate the VHD/VHDX mounts correctly**
```powershell
$vhdPath = "\\<storageAccount>.file.core.windows.net\<share>\<Package>.vhdx"
Mount-DiskImage -ImagePath $vhdPath -NoDriveLetter -Access ReadOnly
$disk = Get-DiskImage -ImagePath $vhdPath
$volume = Get-Partition -DiskNumber $disk.Number | Get-Volume
Write-Output "Mounted: $($volume.DriveLetter) — $($volume.SizeRemaining)B free"
Dismount-DiskImage -ImagePath $vhdPath
```

**Step 2.3 — Validate CimFS container (if using .cim)**
```powershell
# CimFS requires mounting differently
$cimPath = "\\<storageAccount>.file.core.windows.net\<share>\<Package>.cim"
# Mount via CimFS API (AVD agent handles this)
# Manual check:
Get-WindowsDriver -Online | Where-Object { $_.Driver -like "*cimfs*" }
```
If driver missing: OS needs updating (build 19041+) or driver reinstall.

---

### Phase 3: AppX Registration

**Step 3.1 — Re-register a stuck package manually**
```powershell
$manifestPath = "Z:\<PackageName>\AppxManifest.xml"  # Adjust drive/path
Add-AppxPackage -Path $manifestPath -Register -DisableDevelopmentMode
```

**Step 3.2 — Check AppXSVC health**
```powershell
Get-Service AppXSVC | Select-Object Status, StartType
# If stopped:
Start-Service AppXSVC
```

**Step 3.3 — Clear AppX package cache (caution — affects all packages)**
```powershell
# Stop-Service AppXSVC; Remove-Item "$env:LOCALAPPDATA\Packages\*" -Recurse -Force; Start-Service AppXSVC
# Only do this in test — will break all UWP apps until re-registered
```

---

### Phase 4: AVD Agent & Orchestration

**Step 4.1 — Check AVD agent version and health**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\RDAgentBootLoader" |
    Select-Object BootloaderVersion
Get-Service RDAgentBootLoader | Select-Object Status
```

**Step 4.2 — Review AVD agent log for MSIX errors**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-RemoteDesktopServices-RdpCoreCDV/Operational" -MaxEvents 30 |
    Where-Object { $_.Message -like "*MSIX*" -or $_.Message -like "*AppAttach*" } |
    Select-Object TimeCreated, Message
```

**Step 4.3 — Force re-registration by signing out and back in**
App Attach registration is per-session. A fresh sign-in re-triggers staging → registration. Ask user to fully sign out (not disconnect).

---

## Remediation Playbooks

<details><summary>Playbook 1 — Fix storage permission (computer account missing RBAC)</summary>

**Symptom:** Staging fails with 0x80080204 or `Access Denied` in event log.

```powershell
# Run from management host with Az permissions
$subscriptionId = "<subscriptionId>"
$storageRG = "<storageResourceGroup>"
$storageAccountName = "<storageAccountName>"
$sessionHostName = "<sessionHostComputerName>"  # e.g., avd-host-001

# Get the storage account resource ID
$sa = Get-AzStorageAccount -Name $storageAccountName -ResourceGroupName $storageRG
$scope = $sa.Id

# Find the computer/VM identity
$vm = Get-AzVM -Name $sessionHostName -ResourceGroupName "<vmRG>"
$principalId = $vm.Identity.PrincipalId  # requires system-assigned managed identity

if ($null -eq $principalId) {
    Write-Warning "No managed identity on VM. Assign one or use hybrid domain for Kerberos auth."
} else {
    New-AzRoleAssignment -ObjectId $principalId `
        -RoleDefinitionName "Storage File Data SMB Share Reader" `
        -Scope $scope
    Write-Output "RBAC assigned. Allow 2-5 minutes for propagation."
}
```

**Rollback:** Remove-AzRoleAssignment with same parameters.

</details>

<details><summary>Playbook 2 — Re-create package assignment in AVD</summary>

**Symptom:** Package path changed (storage account or share renamed), apps broken after migration.

```powershell
# Using Az.DesktopVirtualization module
$hostPoolName = "<hostPoolName>"
$rg = "<resourceGroup>"
$packagePath = "\\<newStorageAccount>.file.core.windows.net\<share>\<Package>.vhdx"

# List existing packages
$existing = Get-AzWvdMsixPackage -HostPoolName $hostPoolName -ResourceGroupName $rg
$existing | Select-Object Name, Path, IsActive

# Remove old assignment (does NOT delete the VHD file)
Remove-AzWvdMsixPackage -HostPoolName $hostPoolName -ResourceGroupName $rg -FullName $existing[0].Name

# Add new assignment
New-AzWvdMsixPackage -HostPoolName $hostPoolName `
    -ResourceGroupName $rg `
    -ImagePath $packagePath `
    -IsActive $true `
    -IsRegularRegistration $false
```

**Rollback:** Re-add the old path using the same New-AzWvdMsixPackage command.

</details>

<details><summary>Playbook 3 — Convert VHD to CimFS for performance</summary>

**Symptom:** Slow application launch due to VHD mounting overhead on shared host pool.

```powershell
# Run on an admin workstation with MSIX Packaging Tool or msixmgr.exe
# msixmgr.exe is the Microsoft-provided tool for creating App Attach containers
# Download: https://docs.microsoft.com/en-us/azure/virtual-desktop/app-attach-tooling

$msixPackagePath = "C:\Packages\MyApp.msix"
$outputFolder = "C:\AppAttach\MyApp_CimFS"
$volumeSize = 200  # MB — set to slightly larger than package

New-Item -Path $outputFolder -ItemType Directory -Force

# Create CimFS container using msixmgr.exe
& "C:\Tools\msixmgr.exe" -Unpack `
    -packagePath $msixPackagePath `
    -destination $outputFolder `
    -applyacls `
    -create `
    -fileType CimFS `
    -rootDirectory Apps

# Output: MyApp.cim file in $outputFolder
# Upload MyApp.cim to Azure Files share, update AVD package assignment
```

**Rollback:** Keep original VHD. Swap assignment back via AVD portal.

</details>

<details><summary>Playbook 4 — Force-destage a stuck package on session host</summary>

**Symptom:** Package stuck in "Staged" state after session ended; VHD still mounted, blocking updates.

```powershell
# Identify stuck mounts
Get-DiskImage | Where-Object { $_.Attached -eq $true } |
    Select-Object ImagePath, DevicePath, StorageType

# Force dismount (use only after confirming no active user sessions)
$stuckImage = "\\storage.file.core.windows.net\msix\MyApp.vhdx"
Dismount-DiskImage -ImagePath $stuckImage

# Remove staged AppX registration (all users)
$pkg = Get-AppxPackage -AllUsers | Where-Object { $_.Name -like "*MyApp*" }
if ($pkg) {
    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers
}
```

**Rollback:** N/A — next user sign-in will re-stage and re-register automatically.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect MSIX App Attach diagnostic evidence for escalation
.NOTES     Run on affected AVD session host as SYSTEM or Administrator
#>

$report = @{}
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outputPath = "$env:TEMP\AppAttach_Evidence_$timestamp"
New-Item -Path $outputPath -ItemType Directory -Force | Out-Null

# 1. OS & AVD Agent info
$report["OS"] = (Get-WmiObject Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber)
$report["AVDAgent"] = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\RDAgentBootLoader" -ErrorAction SilentlyContinue)

# 2. Mounted disk images
$report["MountedImages"] = Get-DiskImage | Where-Object { $_.Attached } | Select-Object ImagePath, StorageType, DevicePath

# 3. AppX packages (staged/installed)
$report["AppxPackages"] = Get-AppxPackage -AllUsers | Select-Object Name, PackageFullName, InstallLocation, PackageUserInformation

# 4. CimFS driver
$report["CimFSDriver"] = Get-WindowsDriver -Online | Where-Object { $_.Driver -like "*cim*" } | Select-Object Driver, Version, Date

# 5. AppX deployment event log (errors/warnings)
$report["AppXEvents"] = Get-WinEvent -LogName "Microsoft-Windows-AppXDeploymentServer/Operational" -MaxEvents 100 -ErrorAction SilentlyContinue |
    Where-Object { $_.Level -le 3 } | Select-Object TimeCreated, Id, LevelDisplayName, Message

# 6. Network test to storage
$storageHost = Read-Host "Enter storage account hostname (e.g., mystorage.file.core.windows.net)"
$report["NetworkTest"] = Test-NetConnection -ComputerName $storageHost -Port 445

# 7. AVD services
$report["Services"] = Get-Service -Name "RDAgentBootLoader","AppXSVC","ShellHWDetection" |
    Select-Object Name, Status, StartType

# Export
$report | ConvertTo-Json -Depth 5 | Out-File "$outputPath\AppAttach_Report.json"
Get-WinEvent -LogName "Microsoft-Windows-AppXDeploymentServer/Operational" -MaxEvents 200 -ErrorAction SilentlyContinue |
    Export-Clixml "$outputPath\AppX_EventLog.xml"

Write-Host "Evidence collected: $outputPath" -ForegroundColor Green
Compress-Archive -Path $outputPath -DestinationPath "$env:TEMP\AppAttach_Evidence_$timestamp.zip" -Force
Write-Host "ZIP: $env:TEMP\AppAttach_Evidence_$timestamp.zip" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Get-AzWvdMsixPackage -HostPoolName <hp> -ResourceGroupName <rg>` | List all MSIX packages assigned to host pool |
| `Get-DiskImage \| Where-Object Attached` | Show currently mounted VHD/VHDX images |
| `Mount-DiskImage -ImagePath <path> -NoDriveLetter -Access ReadOnly` | Manually mount a VHD to test access |
| `Dismount-DiskImage -ImagePath <path>` | Unmount a stuck VHD image |
| `Get-AppxPackage -AllUsers` | List all AppX packages including App Attach |
| `Add-AppxPackage -Path <manifest> -Register -DisableDevelopmentMode` | Re-register a staged MSIX package |
| `Remove-AppxPackage -AllUsers -Package <fullname>` | Remove staged/registered package for all users |
| `Get-WinEvent -LogName "Microsoft-Windows-AppXDeploymentServer/Operational"` | AppX deployment event log |
| `Test-NetConnection -ComputerName <storage>.file.core.windows.net -Port 445` | Test SMB connectivity to Azure Files |
| `Get-Service AppXSVC \| Restart-Service` | Restart AppX deployment service |
| `Get-WindowsDriver -Online \| Where-Object Driver -like "*cim*"` | Verify CimFS driver installed |
| `Resolve-DnsName <storage>.file.core.windows.net` | Verify storage DNS (check private endpoint) |
| `Get-AzRoleAssignment -Scope <storageId>` | Check RBAC on storage account |

---

## 🎓 Learning Pointers

- **MSIX App Attach vs. App Streaming:** App Attach mounts a static image — the app doesn't run from the cloud in real-time. All app binaries are in the VHD/CimFS container on Azure Files. This means Azure Files latency directly impacts launch time. Use Premium Azure Files (SSD) for production. See: [MS Docs — MSIX App Attach FAQ](https://docs.microsoft.com/en-us/azure/virtual-desktop/app-attach-faq)

- **CimFS is the right choice for AVD at scale:** VHD/VHDX have concurrency limitations (especially with write-capable mounts). CimFS containers are inherently read-only and designed for high-concurrency mount scenarios — hundreds of simultaneous mounts from a single file. See: [CimFS Overview](https://docs.microsoft.com/en-us/azure/virtual-desktop/app-attach-overview#cimfs)

- **Computer account auth to Azure Files:** When session hosts authenticate to Azure Files via Kerberos (hybrid-joined hosts), the computer account must be synced to Entra ID and have RBAC assigned. For Entra-joined hosts, use system-assigned managed identity + RBAC. See: [Azure Files AD auth](https://docs.microsoft.com/en-us/azure/storage/files/storage-files-identity-auth-azure-active-directory-enable)

- **AppX registration is per-user, staging is per-host:** Staging (mounting the VHD) happens once per host. Registration (associating the package with a user) happens once per user session. If staging fails, no user on that host can access the app. If registration fails, only that user is affected.

- **Antivirus exclusions are critical:** If Defender or third-party AV scans files inside mounted MSIX containers, it dramatically increases login time. Add the Azure Files share path and the CimFS/VHD mount points to AV exclusions. See: [Defender exclusions for AVD](https://docs.microsoft.com/en-us/azure/virtual-desktop/security-guide)

- **Use msixmgr.exe, not manual packaging:** Microsoft's `msixmgr.exe` tool correctly sets NTFS ACLs inside the container that AppX requires. Manually extracted MSIX packages often fail to register due to missing ACLs. Download link: [MSIX Packaging Tool](https://docs.microsoft.com/en-us/azure/virtual-desktop/app-attach-tooling)
