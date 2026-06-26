# Intune Driver Management Failures — Hotfix Runbook (Mode B: Ops)
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

Run on the **affected device** as an administrator. Also check Intune portal: **Devices → Windows → Driver updates for Windows 10 and later**.

```powershell
# 1. Check current driver update policy status (IME log)
Get-WinEvent -LogName 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin' `
    -MaxEvents 50 | Where-Object { $_.Message -match 'driver' } |
    Select-Object TimeCreated, Id, Message | Format-List

# 2. List all installed drivers and versions
Get-WmiObject Win32_PnPSignedDriver |
    Select-Object DeviceName, DriverVersion, DriverDate, Manufacturer, InfName |
    Sort-Object DeviceName | Format-Table -AutoSize

# 3. Check Windows Update driver delivery (WUAUSERV)
Get-WindowsUpdateLog  # Generates WindowsUpdate.log on Desktop (may take 1–2 min)

# 4. Check update policy (is WUfB or WSUS controlling drivers?)
(Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue) |
    Select-Object DoNotConnectToWindowsUpdateInternetLocations, ExcludeWUDriversInQualityUpdate,
    UseWUServer, WUServer | Format-List

# 5. Trigger IME sync to re-apply driver policies
Start-Process 'C:\Program Files (x86)\Microsoft Intune Management Extension\AgentExecutor.exe' `
    -ArgumentList '-deviceenrollment' -Wait -NoNewWindow
```

**Interpretation table:**

| Result | What it means | Go to |
|---|---|---|
| `ExcludeWUDriversInQualityUpdate = 1` | WSUS or WUfB policy blocking driver updates | [Fix 1 — Check WUfB driver exclusion policy](#fix-1--check-wufb-driver-exclusion-policy) |
| Driver policy events show "Pending approval" | Driver update ring requires manual approval | [Fix 2 — Approve driver in Intune portal](#fix-2--approve-driver-in-intune-portal) |
| Device not appearing in Driver updates report | Device not checked in or not in policy scope | [Fix 3 — Verify scope and sync](#fix-3--verify-policy-scope-and-force-sync) |
| Device showing "Error" in Intune driver report | Driver deployment error — check error code | [Fix 4 — Resolve deployment error](#fix-4--resolve-driver-deployment-error) |
| Driver installed but device still has issue | Driver version conflict or rollback needed | [Fix 5 — Manual driver rollback](#fix-5--manual-driver-rollback) |

---

## Dependency Cascade

<details><summary>What must be true for Intune driver management to work</summary>

```
Device enrolled in Intune (MDM authority = Intune)
    │
    ▼
Device in scope of Driver Update Policy (Intune profile assigned to device/group)
    │
    ▼
Windows Update for Business pipeline reachable (*.windowsupdate.com, *.update.microsoft.com)
    │
    ├── If ExcludeWUDriversInQualityUpdate = 1 → drivers blocked regardless of Intune policy
    │
    ▼
Intune Driver Update Ring configured
    │
    ├── Automatic approval  → driver deploys on schedule
    └── Manual approval     → Admin must approve in portal before deployment
    │
    ▼
Device checks in (IME heartbeat) → receives approved driver assignment
    │
    ▼
Windows Update installs driver on device
    │
    ▼
Device reports installation status back to Intune
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Check if driver updates are blocked by Windows Update policy:**
```powershell
$wuPolicy = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
if ($wuPolicy.ExcludeWUDriversInQualityUpdate -eq 1) {
    Write-Warning "Drivers excluded from Windows Update by policy — Intune driver management may be blocked."
} else {
    Write-Host "Driver exclusion policy: NOT set (OK)"
}
```

**Step 2 — Verify IME is running and healthy:**
```powershell
Get-Service -Name IntuneManagementExtension | Select-Object Status, StartType, DisplayName
Get-Process -Name 'Microsoft.Management.Services.IntuneWindowsAgent' -ErrorAction SilentlyContinue
```
Expected: Status = Running. Bad: Stopped → `Start-Service IntuneManagementExtension`.

**Step 3 — Check device enrollment health:**
```powershell
dsregcmd /status | Select-String -Pattern 'AzureAdJoined|MDMEnrolled|TenantName|MDMUrl'
```
Expected: `AzureAdJoined: YES`, `MDMEnrolled: YES`. Bad: MDMEnrolled = NO — re-enroll device.

**Step 4 — Check for pending Windows Updates including drivers:**
```powershell
(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search("IsInstalled=0").Updates |
    Select-Object Title, @{N='Type';E={if ($_.Categories | Where-Object { $_.Name -match 'Driver'}) {'Driver'} else {'Other'}}} |
    Sort-Object Type | Format-Table -AutoSize
```

**Step 5 — Verify in Intune portal:**
- Go to **Devices → Windows → Driver updates for Windows 10 and later**
- Select the policy → **Driver updates** tab
- Check status: Approved / Pending approval / Error

---

## Common Fix Paths

<details>
<summary>Fix 1 — Check WUfB driver exclusion policy</summary>

**Symptom:** `ExcludeWUDriversInQualityUpdate = 1` in registry.

This setting is often set by Windows Update for Business (WUfB) configuration profiles in Intune or by WSUS GPO. When set, Windows Update will not deliver driver updates, which overrides the Intune Driver Update policy.

**Check in Intune portal:**
1. **Devices → Configuration profiles → Windows Update rings**
2. Find applicable WUfB ring policy for the device
3. Check: **"Driver updates"** setting — should be **"Allow"** (not "Block")

**Check via PowerShell (on device):**
```powershell
# Check if WSUS is configured (overrides WUfB)
(Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue) |
    Select-Object UseWUServer, AUOptions | Format-List

# Check Windows Update for Business ring config
(Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue) |
    Select-Object DeferQualityUpdates, DeferFeatureUpdates, ExcludeWUDriversInQualityUpdate | Format-List
```

If WSUS (`UseWUServer = 1`) is set alongside Intune: migrate device off WSUS to WUfB before using Intune Driver Management.

</details>

<details>
<summary>Fix 2 — Approve driver in Intune portal</summary>

**Symptom:** Driver update ring has approval mode = Manual, driver is pending.

```
Intune Portal:
  Devices → Windows → Driver updates for Windows 10 and later
    → Select policy → Driver updates tab
    → Find driver with status "Needs review" or "Recommended"
    → Select → Approve
```

**Or via Graph API (batch approval):**
```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes 'WindowsUpdates.ReadWrite.All'

# List pending driver approvals (requires Graph SDK or REST)
# Portal approval is recommended for individual cases
# For bulk: use the Microsoft Graph windowsUpdates APIs
# https://learn.microsoft.com/en-us/graph/windowsupdates-manage-driver-update
```

After approval: device must check in (within ~8 hours normally; force with IME sync below).

</details>

<details>
<summary>Fix 3 — Verify policy scope and force sync</summary>

**Symptom:** Device doesn't appear in Intune driver update report, or shows "Not applicable."

```powershell
# 1. Force Intune sync on device
Start-Process 'C:\Windows\System32\deviceenroller.exe' -ArgumentList '/c /AutoEnrollMDM' -Wait

# 2. Restart IME to force policy refresh
Restart-Service IntuneManagementExtension

# 3. Force Windows Update check
UsoClient StartScan

# 4. Or trigger via Intune portal:
#    Devices → select device → Sync
```

**In portal:** Verify the device group is correctly targeted by the driver update policy:
- Devices → Windows → Driver updates for Windows 10 and later → select policy → Properties → Assignments

</details>

<details>
<summary>Fix 4 — Resolve driver deployment error</summary>

**Symptom:** Intune shows error status for driver update on device.

```powershell
# Check Windows Update error codes
$wu = New-Object -ComObject 'Microsoft.Update.Session'
$searcher = $wu.CreateUpdateSearcher()
$history = $searcher.QueryHistory(0, 50)
$history | Where-Object { $_.Title -match 'driver' -or $_.ResultCode -ne 2 } |
    Select-Object Date, Title, ResultCode, HResult, Description |
    Format-Table -AutoSize

# ResultCode: 1=NotStarted, 2=InProgress, 3=Succeeded, 4=SucceededWithErrors, 5=Failed, 6=Aborted
# HResult 0x80070643 = install failure — check device for conflicting driver
# HResult 0x8024000B = update already installed — not an error
```

**Common error codes:**

| HResult | Meaning | Action |
|---|---|---|
| 0x80070643 | Installation failure | Check Device Manager for conflict; collect setup log |
| 0x8024000B | Already installed | Clear from pending; verify correct version |
| 0x80240022 | No applicable update | SPN/driver not compatible with hardware |
| 0x80240034 | Update not applicable | Verify hardware ID matches driver targeting |
| 0x800706BE | RPC failure during install | Restart Windows Update service |

```powershell
# Restart Windows Update service
Stop-Service wuauserv; Start-Service wuauserv
# Retry scan
UsoClient StartScan
```

</details>

<details>
<summary>Fix 5 — Manual driver rollback</summary>

**Use when:** Approved driver caused device issues and must be rolled back quickly.

```powershell
# 1. Identify the driver
Get-WmiObject Win32_PnPSignedDriver |
    Where-Object { $_.DeviceName -match '<device-name>' } |
    Select-Object DeviceName, DriverVersion, DriverDate, InfName

# 2. Roll back via Device Manager (GUI — fastest)
# Device Manager → right-click device → Properties → Driver → Roll Back Driver

# 3. Roll back via PowerShell (pnputil)
# First get the inf name from above
pnputil /delete-driver <oem##.inf> /uninstall /force /reboot

# 4. Block re-installation via Intune:
#    In portal → Driver updates → set the specific driver version to "Declined"
```

After rollback: In the Intune Driver Updates policy, set the problematic version status to **Declined** to prevent re-deployment.

</details>

---

## Escalation Evidence

```
=== Intune Driver Management — Escalation Template ===
Date/Time:          ___________
Affected device(s): ___________
Intune Device ID:   ___________
Driver name/version: __________
Driver update policy name: _____

Symptom:
  [ ] Driver not deploying (stuck pending)
  [ ] Driver showing error in Intune portal
  [ ] Driver deployed but not installing on device
  [ ] Driver caused regression — need rollback
  [ ] Device not appearing in driver update report

ExcludeWUDriversInQualityUpdate value: ___
MDMEnrolled (dsregcmd): ___
IME service status: ___

Windows Update history (Get-WindowsUpdateLog results):
  (attach WindowsUpdate.log)

Intune portal — driver update policy status screenshot:
  (attach)

Error code from WU history HResult: 0x___________

Steps already attempted:
  [ ] IME service restart
  [ ] Intune Sync from portal
  [ ] UsoClient StartScan
  [ ] Checked WUfB ring policy for driver exclusion
  [ ] Checked WSUS conflict
```

---

## 🎓 Learning Pointers

- **Intune Driver Management requires WUfB — not WSUS:** Intune's driver update policies work through the Windows Update for Business delivery pipeline. If the device is configured to use WSUS (`UseWUServer = 1`), Intune driver policies will appear assigned but won't actually deploy drivers. The device must be fully migrated off WSUS to WUfB before Intune driver management works. [Intune driver updates prerequisites](https://learn.microsoft.com/en-us/mem/intune/protect/windows-driver-updates-overview)

- **Manual vs. automatic approval matters for compliance:** If your driver update ring is set to "Automatic", every Microsoft-classified "Recommended" or "Required" driver will deploy on schedule. If it's "Manual", nothing deploys until an admin reviews and approves in the portal. For production environments, start with manual approval on a pilot ring, validate, then switch to automatic for broad deployment.

- **Driver targeting uses hardware IDs — not display names:** When a driver update is displayed in the Intune portal, it's matched to devices by Plug-and-Play hardware IDs (`HWID`). If a driver shows as applicable to 0 devices despite you expecting it to apply, the hardware ID in the driver catalog doesn't match what the device reports. Run `Get-WmiObject Win32_PnPEntity | Select-Object Name, DeviceID | Where DeviceID -match 'PCI'` to see hardware IDs. [Driver hardware IDs](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/hardware-ids)

- **Driver update rings ≠ quality update rings:** Driver updates are managed in a separate section from Windows feature and quality updates. Many admins configure WUfB rings for OS updates but forget to create a Driver Update policy — leaving driver updates either unmanaged or blocked. Create at least a pilot ring and a broad ring for drivers, mirroring your OS update ring structure.

- **Declined drivers stay declined until you change them:** If you decline a driver in Intune, it will not deploy to any device in the policy scope regardless of Windows Update's recommendation. Keep a record of what you've declined and why — it's easy to forget and then wonder six months later why a critical driver update never arrived. [Managing driver approvals](https://learn.microsoft.com/en-us/mem/intune/protect/windows-driver-updates-policy)
