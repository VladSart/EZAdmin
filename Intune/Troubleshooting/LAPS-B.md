# Intune LAPS (Local Administrator Password Solution) — Hotfix Runbook (Mode B: Ops)
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
# 1. Check if device has LAPS policy applied
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
  Select-Object DeviceName, Id, ComplianceState, ManagementState

# 2. Retrieve LAPS password for a device (requires LAPS Read role)
$deviceId = "<IntuneDeviceId>"
Get-MgDeviceManagementManagedDeviceLocalAdminPassword -ManagedDeviceId $deviceId

# 3. Check LAPS policy assignment in Intune
# Portal: Endpoint Security → Account Protection → [LAPS policy] → Device status

# 4. On device — check Windows LAPS service state
Get-Service -Name WLAPSVC -ErrorAction SilentlyContinue | Select-Object Status, StartType

# 5. Check LAPS event log on device
Get-WinEvent -LogName "Microsoft-Windows-LAPS/Operational" -MaxEvents 20 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, Message | Format-List
```

| What you see | What it means |
|---|---|
| `WLAPSVC` service missing or disabled | Windows LAPS not running — Win 11 22H2+ required for native LAPS |
| Event ID 10020 | LAPS policy received and applied successfully |
| Event ID 10021 | Password rotation succeeded |
| Event ID 10031 | Password rotation failed — check Event Message for reason |
| Event ID 10035 | LAPS policy conflict (legacy LAPS vs. Windows LAPS) |
| `Get-MgDeviceManagementManagedDeviceLocalAdminPassword` returns empty | Device hasn't rotated yet, or admin doesn't have LAPS Read role |
| Compliance: `Not compliant` | LAPS policy not applied or backup not completed |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Windows 11 22H2+ (or Windows 10 22H2 with April 2023 update)
  └── Windows LAPS feature present (native, not legacy)
        └── WLAPSVC service running
              └── Device enrolled in Intune (Azure AD Joined or Hybrid)
                    └── Intune LAPS policy created & assigned
                          └── Device group filter matches device
                                └── Policy sync completed (device checked in)
                                      └── LAPS backup target: Azure AD or Active Directory
                                            └── Password backed up to Entra ID
                                                  └── Admin has LAPS Read permission in Entra
                                                        └── Password retrievable via Intune/Entra portal
```

Key failure points:
- Legacy LAPS (CSE-based) still installed and conflicting with Windows LAPS
- Policy created but targeting wrong group or wrong backup target (AD vs. Entra ID)
- Insufficient RBAC — reader can't see the password even if it exists
- Password never rotated after policy applied (device hasn't checked in)

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm OS version supports Windows LAPS**
```powershell
Get-ComputerInfo -Property WindowsProductName, OSDisplayVersion, OsBuildNumber
```
Expected: Windows 11 22H2+ (build 22621+) or Windows 10 22H2 with KB5025221 or later.  
Bad: Older build — LAPS will not work natively. Must update first.

**Step 2 — Check LAPS service**
```powershell
Get-Service WLAPSVC | Select-Object Status, StartType, DisplayName
```
Expected: `Running`, `Automatic`.  
Bad: Stopped or missing — see Fix 1.

**Step 3 — Check LAPS event log**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-LAPS/Operational" -MaxEvents 30 |
  Select-Object TimeCreated, Id, Message | Format-List
```
Event IDs to look for:

| ID | Meaning |
|---|---|
| 10020 | Policy received |
| 10021 | Password rotated |
| 10031 | Rotation failed — read message |
| 10035 | Policy conflict (legacy LAPS interference) |
| 10042 | Backup to Azure AD succeeded |
| 10043 | Backup to Azure AD failed |

**Step 4 — Verify Intune policy assignment**  
Intune portal: Endpoint Security → Account Protection → [LAPS policy] → Device status  
Check: policy shows "Succeeded" for target device, not "Pending" or "Error".

**Step 5 — Check backup target matches policy**
```powershell
# Read LAPS policy from registry
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Policies\LAPS" -ErrorAction SilentlyContinue
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS" -ErrorAction SilentlyContinue
```
Key: `BackupDirectory` — 1 = AD, 2 = Azure AD (Entra ID).  
Mismatch between registry and policy config = policy not applied correctly.

**Step 6 — Try to retrieve password**
```powershell
# Requires: Install-Module Microsoft.Graph.DeviceManagement -Scope CurrentUser
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
$device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'"
Get-MgDeviceManagementManagedDeviceLocalAdminPassword -ManagedDeviceId $device.Id
```
If this returns empty: device hasn't rotated password yet, or you lack permissions (Fix 3).

**Step 7 — Check for legacy LAPS conflict**
```powershell
# Check if legacy LAPS CSE is installed
Get-Item "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}" -ErrorAction SilentlyContinue
# If this key exists, legacy LAPS CSE is present → Fix 4
```

---
## Common Fix Paths

<details><summary>Fix 1 — WLAPSVC not running</summary>

**Cause:** Service disabled, or OS doesn't have Windows LAPS native support.

```powershell
# Check service
Get-Service WLAPSVC -ErrorAction SilentlyContinue

# Start if stopped
Start-Service WLAPSVC
Set-Service WLAPSVC -StartupType Automatic

# If service doesn't exist, verify OS version
(Get-ComputerInfo).OsBuildNumber  # Must be 22621+ for Win11, or 19045 + KB5025221 for Win10

# Force immediate LAPS policy evaluation
gpupdate /force
Invoke-LapsRotation  # If supported (Windows LAPS cmdlet)
```

**Rollback note:** Starting WLAPSVC is non-destructive.

</details>

<details><summary>Fix 2 — Policy not applying (Pending / Error in Intune)</summary>

**Cause:** Device not synced, group filter mismatch, or policy conflict.

```powershell
# Force Intune sync
Start-Process "ms-device-enrollment://status" -Wait
# OR via scheduled task:
Start-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt" -TaskName "*Schedule*" -ErrorAction SilentlyContinue

# Trigger LAPS policy evaluation after sync
$svc = Get-Service WLAPSVC
if ($svc.Status -eq "Running") {
    # Force LAPS to re-read policy
    Restart-Service WLAPSVC
}
```

In Intune portal:
1. Devices → [device] → Sync
2. Wait 10 minutes
3. Re-check Endpoint Security → Account Protection → [policy] → Device status

</details>

<details><summary>Fix 3 — Can't read LAPS password (permissions)</summary>

**Cause:** Account lacks LAPS Read permission. Windows LAPS passwords in Entra ID require a specific role assignment.

**Required roles (any one of):**
- Global Administrator
- Intune Administrator
- Cloud Device Administrator  
- `DeviceLocalCredential.Read.All` Graph permission (custom role)

**Check current role:**
```powershell
Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
$upn = "<your-upn>"
Get-MgUserMemberOf -UserId $upn | Where-Object {$_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.directoryRole'} |
  Select-Object @{N='Role';E={$_.AdditionalProperties['displayName']}}
```

**Grant read access (requires Global Admin):**  
Entra portal: Roles and Admins → Cloud Device Administrator → Add assignment → [user]

**Retrieve via portal (no PowerShell needed):**  
Intune → Devices → [device] → Local admin password

</details>

<details><summary>Fix 4 — Legacy LAPS conflict (Event ID 10035)</summary>

**Cause:** The old LAPS Group Policy CSE (`.dll`) is still installed. Windows LAPS detects a conflict and refuses to manage the local admin password.

```powershell
# Detect legacy LAPS CSE
$legacyLAPS = Get-Item "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}" -ErrorAction SilentlyContinue
if ($legacyLAPS) { Write-Warning "Legacy LAPS CSE present — conflict likely" }

# Check if legacy LAPS policy values exist
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd" -ErrorAction SilentlyContinue
```

**Fix options:**
1. **Remove legacy LAPS CSE** — uninstall the legacy LAPS package from Add/Remove Programs or deploy removal script via Intune
2. **Enable interop** — if you need both (hybrid AD/Entra), configure `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS\BackupDirectory` = 2 and set `UseLegacyPolicy` registry values per [MS docs](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-scenarios-legacy)
3. **Preferred:** Remove legacy LAPS, rely solely on Windows LAPS with Entra backup

**Rollback note:** Removing legacy LAPS CSE is reversible — reinstall the MSI if needed.

</details>

<details><summary>Fix 5 — Force password rotation</summary>

**Cause:** Policy applied but password was never rotated (new deployment), or you need to force a rotation after a compromise.

```powershell
# Force immediate rotation (Windows LAPS PowerShell module)
# Module ships with Windows LAPS — no install needed on 22H2+
Invoke-LapsRotation

# Verify rotation completed
Get-LapsAADPassword -DeviceIds (Get-AzureADDevice -SearchString $env:COMPUTERNAME).ObjectId
# (Requires Azure AD module + appropriate permissions)

# Check event log for success
Get-WinEvent -LogName "Microsoft-Windows-LAPS/Operational" -MaxEvents 5 |
  Where-Object {$_.Id -in @(10021, 10042)} |
  Select-Object TimeCreated, Message
```

**Via Intune portal:**  
Devices → [device] → Rotate local admin password  
This forces the device to generate a new password on next check-in.

**Rollback note:** Rotation is non-reversible — old password is gone once rotated. Always retrieve existing password first if you need it.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Intune LAPS Issue

Device name: _____________________
Device Intune ID: _________________
Azure AD Device ID: _______________
OS Version + Build: _______________
Domain joined (Y/N): ______________
Hybrid join (Y/N): _________________

LAPS policy name in Intune: _______
Backup target: (Azure AD / Active Directory)
Policy status in Intune: (Succeeded / Pending / Error)

WLAPSVC running (Y/N): ____________
Legacy LAPS CSE present (Y/N): ____
BackupDirectory registry value: ___

Relevant Event IDs from LAPS Operational log:
---
[paste events here — include TimeCreated, Id, Message]
---

Password retrieval result: (retrieved / empty / permission denied)
Admin account used to retrieve: ________________
Role assigned to that account: _________________

Steps already attempted:
[ ] Intune sync triggered
[ ] WLAPSVC restarted
[ ] Policy re-applied / device re-targeted
[ ] Legacy LAPS conflict checked
[ ] Permissions verified
[ ] Rotation forced
```

---
## 🎓 Learning Pointers

- **Windows LAPS ≠ Legacy LAPS:** The old LAPS (AdmPwd.dll CSE) and the new Windows LAPS (built into Windows 11 22H2+) are different products. Legacy uses Group Policy push; Windows LAPS integrates natively with Intune and backs up to Entra ID. Running both causes conflicts (Event ID 10035). [Windows LAPS overview](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-overview)
- **Backup target matters:** LAPS can back up to AD or Entra ID, not both simultaneously (without extra config). For cloud-only or Hybrid joined devices managed by Intune, choose Entra ID (BackupDirectory = 2). Getting this wrong means the password is backed up somewhere you can't read it.
- **RBAC is strict for LAPS reads:** You can't see a stored LAPS password without Cloud Device Administrator or equivalent. This is intentional — least-privilege design. Set up a LAPS Reader role assignment for your helpdesk team before they need it under pressure.
- **Rotation is irreversible:** Once a password rotates, the old one is gone from Entra. Always retrieve before rotating if you think someone might be using the existing credential.
- **First rotation takes time:** After policy assignment, the device needs to check in and run WLAPSVC logic. This can take 30–90 minutes on first assignment. Don't assume failure just because the password isn't immediately available. [LAPS deployment guide](https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-management-policy-settings)
- **Event log is your friend:** The `Microsoft-Windows-LAPS/Operational` log is detailed and reliable. Event 10021 = rotation OK, 10042 = Entra backup OK. If you see 10031 or 10043, read the full message — it tells you exactly what failed.
