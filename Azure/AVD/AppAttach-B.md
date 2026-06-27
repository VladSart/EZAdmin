# MSIX App Attach — Hotfix Runbook (Mode B: Ops)
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

Run on the **session host** (as admin) where the app is not appearing:

```powershell
# 1. Check App Attach package stage status
Get-EventLog -LogName Application -Source "Microsoft-Windows-AppxPackagingOM" -Newest 20 2>$null |
    Select-Object TimeGenerated, EntryType, Message | Format-List

# 2. Check staged packages (all users)
Get-AppxPackage -AllUsers | Where-Object { $_.PackageUserInformation -like '*Staged*' -or $_.Status -ne 'Ok' } |
    Select-Object Name, Version, Status | Format-Table -AutoSize

# 3. Check if the VHD/VHDX/CIM image is mounted
Get-DiskImage | Where-Object { $_.Attached -eq $true } | Select-Object ImagePath, Attached, FileSize | Format-Table

# 4. Check AVD App Attach event log
Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin' -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeGenerated, LevelDisplayName, Message | Format-List

# 5. Check AppX log for staging/registration errors
Get-WinEvent -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' -MaxEvents 30 -ErrorAction SilentlyContinue |
    Where-Object { $_.LevelDisplayName -eq 'Error' } | Select-Object TimeGenerated, Message | Format-List
```

**Interpretation:**

| Finding | Action |
|---------|--------|
| VHD/VHDX not in Get-DiskImage | Image not mounted → check SMB share access, Fix 1 |
| AppXDeploymentServer errors: "0x80073CF9" | Package staging conflict → Fix 2 |
| AppXDeploymentServer errors: "0x80073D19" | Package already registered for user → Fix 3 |
| No staged packages at all | App Attach package not assigned to host pool → check portal |
| Event 3398 in TerminalServices log | Session host not receiving App Attach payload → Fix 4 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
AVD Control Plane (App Attach service)
        │
        └── Host Pool has App Attach package assigned (portal)
                │
                └── MSIX image file (.vhd/.vhdx/.cim) accessible on SMB share
                        │
                        └── Session host can access the SMB share
                                │ (Network: port 445, authentication via computer account)
                                └── Image mounted by AppX staging service
                                        │
                                        └── Package staged (per-machine)
                                                │
                                                └── Package registered for user (per-user, on login)
                                                        │
                                                        └── App appears in Start Menu / RemoteApp feed
```

**Key SMB access requirement:** Session hosts access the MSIX image via the computer account, not the user account. The computer account (or a dedicated service account) must have **Read** access to the SMB share. On Azure Files: Storage File Data SMB Share Reader role on the storage account.

</details>

---

## Diagnosis & Validation Flow

**Step 1: Confirm App Attach package assignment in AVD portal**
```
Azure Portal → Azure Virtual Desktop → [Host Pool] → Application Groups
→ Application Group → Applications → Confirm the app is listed
→ Also: Azure Virtual Desktop → [Host Pool] → MSIX packages
→ Confirm the package shows "Active" (not "Inactive" or "Paused")
```
- Expected: Package shows Active
- Bad: Not listed, or state is Inactive/Paused

**Step 2: Confirm the MSIX image file is accessible from session host**
```powershell
# Run on session host:
$imagePath = "\\<storageaccount>.file.core.windows.net\<share>\<appname>.vhdx"
Test-Path $imagePath
# Expected: True
# Bad: False → UNC path not reachable → network/auth issue
```

**Step 3: Confirm the image can be mounted**
```powershell
# Try mounting manually:
$mount = Mount-DiskImage -ImagePath "\\<storageaccount>.file.core.windows.net\<share>\<appname>.vhdx" -PassThru
Get-Volume -DiskImage $mount
# Expected: Volume shows with DriveLetter or mount point
# Bad: Error or no volume → image corrupt or access denied
```

**Step 4: Check staging for the package**
```powershell
# Must run elevated:
Get-AppxPackage -AllUsers | Where-Object { $_.Name -like '*<AppPartialName>*' } |
    Select-Object Name, Version, PackageUserInformation
# Expected: Shows Staged or OK for system or target user
# Bad: Not found → staging never ran
```

**Step 5: Check user-side registration**
```powershell
# Run as the affected user (or use PsExec):
Get-AppxPackage | Where-Object { $_.Name -like '*<AppPartialName>*' }
# Expected: Package listed with Status: Ok
# Bad: Not listed → registration failed
```

**Step 6: Check Application event log for staging errors**
```powershell
Get-WinEvent -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' -MaxEvents 50 |
    Where-Object { $_.LevelDisplayName -eq 'Error' -and $_.Message -like '*<AppPartialName>*' } |
    Select-Object TimeGenerated, Message | Format-List
```

---

## Common Fix Paths

<details>
<summary>Fix 1 — SMB share not accessible / image not mounting</summary>

**Cause:** Session host computer account cannot read the MSIX image on the SMB share (Azure Files most common).

**Check:**
```powershell
# Test SMB connectivity:
Test-NetConnection -ComputerName <storageaccount>.file.core.windows.net -Port 445
# Expected: TcpTestSucceeded: True
```

**Fix — Azure Files RBAC:**
1. Open Azure Portal → Storage Account → Access Control (IAM)
2. Add role assignment: **Storage File Data SMB Share Reader**
3. Assignee: The **computer account** of the session host VM (or the AVD session host AAD object)
4. Wait 5–10 minutes for RBAC to propagate
5. Retry mounting the image on the session host

**Fix — Classic file share permissions:**
```powershell
# If using a traditional SMB share, ensure computer account (or service account) has Read access:
# Open share ACL → Add [DOMAIN\COMPUTERNAME$] with Read permission
```

**Rollback:** Removing RBAC role will re-break access. Keep the role.

</details>

<details>
<summary>Fix 2 — Package staging conflict (0x80073CF9)</summary>

**Cause:** A previous version of the package is staged and conflicting with the new one.

**Fix:**
```powershell
# Find and remove the old staged package:
$conflicting = Get-AppxPackage -AllUsers | Where-Object { $_.Name -like '*<AppPartialName>*' }
$conflicting | Format-List Name, PackageFullName, Version

# Remove all versions (per-machine staging):
foreach ($pkg in $conflicting) {
    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Continue
}

# Verify cleared:
Get-AppxPackage -AllUsers | Where-Object { $_.Name -like '*<AppPartialName>*' }
# Expected: No output
```

After removal, trigger a new AVD App Attach staging by restarting the Remote Desktop Agent:
```powershell
Restart-Service RdAgent
```

**Rollback:** The old package is removed; AVD will re-stage the current package version on next agent cycle.

</details>

<details>
<summary>Fix 3 — Package already registered for user (0x80073D19)</summary>

**Cause:** User has the app registered from a previous session or sideload; registration fails because it conflicts.

**Fix (run in user context or via elevated PsExec):**
```powershell
# Remove user-registered package:
Get-AppxPackage | Where-Object { $_.Name -like '*<AppPartialName>*' } |
    Remove-AppxPackage -ErrorAction Continue

# Force user log-off and back on to allow re-registration:
# From session host (admin):
logoff <sessionID>
```

Ask user to log back in. App Attach will re-register the package on login.

</details>

<details>
<summary>Fix 4 — App Attach package not reaching session host (AVD control plane issue)</summary>

**Cause:** Host pool App Attach assignment not pushed to the host, or host is in drain mode.

**Check drain mode:**
```powershell
# Using Az PowerShell:
Get-AzWvdSessionHost -ResourceGroupName <rg> -HostPoolName <hostpool> |
    Select-Object Name, AllowNewSession, Status | Format-Table
# AllowNewSession = False means drain mode is ON → new logins blocked
```

**Fix — Take host out of drain mode:**
```powershell
Update-AzWvdSessionHost -ResourceGroupName <rg> -HostPoolName <hostpool> -Name <hostname> -AllowNewSession $true
```

**Fix — Force App Attach refresh (restart RdAgent):**
```powershell
Restart-Service RdAgent -Force
# Wait 2-3 minutes, then check staging:
Get-AppxPackage -AllUsers | Where-Object { $_.Name -like '*<AppPartialName>*' }
```

**Fix — Re-activate a paused package:**
- Azure Portal → Azure Virtual Desktop → [Host Pool] → MSIX packages
- Select the package → Change state to **Active**
- Wait 5 minutes, then restart RdAgent on session host

</details>

<details>
<summary>Fix 5 — App visible in Start Menu but crashes on launch</summary>

**Cause:** MSIX package was built or captured incorrectly; dependency packages missing.

**Check for dependency errors:**
```powershell
Get-WinEvent -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' -MaxEvents 100 |
    Where-Object { $_.Message -like '*dependency*' -or $_.Message -like '*framework*' } |
    Select-Object TimeGenerated, Message | Format-List
```

**Check Windows App Runtime / VCLibs presence:**
```powershell
Get-AppxPackage -AllUsers | Where-Object { $_.Name -like '*VCLibs*' -or $_.Name -like '*Runtime*' -or $_.Name -like '*Desktop*' } |
    Select-Object Name, Version
```

If dependencies are missing, install them:
```powershell
# Install Microsoft.VCLibs.140 (x64):
Add-AppxPackage -Path "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx"
```

**Escalate if:** The MSIX package itself needs to be rebuilt from the original installer — this requires the original IT ops team or application vendor.

</details>

---

## Escalation Evidence

```
=== MSIX App Attach Escalation ===
Date/Time     : [TIMESTAMP]
Raised by     : [ENGINEER NAME]
Ticket #      : [TICKET]

Environment
-----------
Host Pool     : [NAME]
Session Host  : [VM NAME / FQDN]
Affected User : [UPN]
App Name      : [APPLICATION NAME]
Package Name  : [MSIX PackageFullName if known]
Image Path    : [UNC PATH TO .vhdx/.cim]

Symptoms
--------
[ ] App not appearing in start menu
[ ] App appears but fails to launch
[ ] Package staging error: [ERROR CODE]
[ ] Image not mounting
[ ] Other: [DESCRIBE]

Steps taken
-----------
[ ] Confirmed package Active in portal
[ ] Tested SMB path reachable from host (Test-Path result: [TRUE/FALSE])
[ ] Checked AppXDeploymentServer log (top error: [MESSAGE])
[ ] Attempted RdAgent restart (staging result: [STAGED/NOT STAGED])
[ ] Removed conflicting package versions: [YES/NO]

Get-DiskImage output
--------------------
[PASTE]

Get-AppxPackage -AllUsers (filtered)
-------------------------------------
[PASTE]

Top 10 AppXDeploymentServer errors
------------------------------------
[PASTE]
```

---

## 🎓 Learning Pointers

- **MSIX App Attach vs. App Attach (preview):** Microsoft introduced a simplified "App Attach" (GA in 2023) that replaces the older "MSIX App Attach" flow. The underlying technology is the same; the newer version is managed directly in the AVD portal blade under the host pool, without needing a separate application group. If your portal shows both options, use the newer App Attach blade.

- **CIM vs VHD vs VHDX formats:** CIM (Composite Image) is read-only and more efficient for multi-session (the OS doesn't need to parse the VHD filesystem overhead). VHD/VHDX are more compatible but slower in multi-session due to per-user expand locking. Prefer CIM format for production App Attach.

- **Computer account vs user account SMB auth:** This is the single most common misconfiguration. The image is mounted at machine startup by the AVD agent, not by the user. The machine's computer account (or a managed identity) must have SMB read permission — not just the user's account.

- **MS Docs — Set up MSIX App Attach:** https://learn.microsoft.com/en-us/azure/virtual-desktop/app-attach-overview

- **MS Docs — App Attach portal setup:** https://learn.microsoft.com/en-us/azure/virtual-desktop/app-attach-setup

- **MSIX Packaging Tool (for creating packages):** https://learn.microsoft.com/en-us/windows/msix/packaging-tool/tool-overview
