# Intune / ConfigMgr Co-Management — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the co-management architecture, workload ownership, and how to troubleshoot transitions between ConfigMgr and Intune authority.

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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- Co-management setup via ConfigMgr automatic enrollment (Internet-facing via CMG or on-prem)
- Workload slider management (ConfigMgr vs Intune authority per workload)
- Troubleshooting devices stuck in co-management transition
- Resolving policy conflicts between ConfigMgr and Intune for the same workload
- Co-management reporting in both ConfigMgr console and Intune portal

**Out of scope:**
- Full Intune-only enrollment (no ConfigMgr involved)
- ConfigMgr-only management (no Intune enrollment)
- Tenant attach (read-only portal view without full co-management)

**Assumptions:**
- ConfigMgr Current Branch 2103+ (co-management generally available from 1710, but 2103+ for full workload support)
- Devices are Active Directory domain-joined and Hybrid Entra ID joined
- Intune tenant is configured with the same Azure tenant as ConfigMgr's cloud attachment

---

## How It Works

<details><summary>Full architecture</summary>

### Co-Management Defined

Co-management is a state where a Windows device is simultaneously managed by both **ConfigMgr (on-prem)** and **Microsoft Intune (cloud)**. The device has a ConfigMgr client installed AND is enrolled in Intune MDM. For each **workload**, exactly one authority is the effective policy source.

```
┌─────────────────────────────────────────────────────────┐
│                     Windows Device                      │
│                                                         │
│  ┌─────────────────────┐  ┌─────────────────────────┐  │
│  │  ConfigMgr Client   │  │   Intune MDM Enrollment  │  │
│  │  (ccmexec.exe)      │  │   (MDM Bridge / WMI)     │  │
│  └──────────┬──────────┘  └───────────┬─────────────┘  │
│             │                         │                  │
│     [ConfigMgr Policy]        [Intune Policy]            │
│             │                         │                  │
│             └──────────┬──────────────┘                  │
│                        │                                  │
│                 Workload Slider                           │
│              (per-workload authority)                    │
└─────────────────────────────────────────────────────────┘
```

### Workloads and Sliders

Each workload is independently assigned to either ConfigMgr or Intune. The slider in ConfigMgr (Administration → Cloud Services → Co-management → Properties → Workloads) controls this:

| Workload | ConfigMgr (default) | Intune (pilot/all) | Notes |
|----------|--------------------|--------------------|-------|
| Compliance policies | ✅ | ✅ | Switch Intune early — feeds CA |
| Device configuration | ✅ | ✅ | High impact; plan exclusions |
| Endpoint Protection | ✅ | ✅ | Switches MDA management authority |
| Resource access | ✅ | ✅ | Wi-Fi, VPN, cert profiles |
| Client apps | ✅ | ✅ | Win32 app delivery stays ConfigMgr |
| Office Click-to-Run | ✅ | ✅ | O365 channel management |
| Windows Update policies | ✅ | ✅ | WUfB rings |

**Pilot collections:** Each workload can be moved to Intune for a **pilot collection** first. Devices in the pilot get Intune authority; devices not in pilot stay with ConfigMgr. This allows controlled rollout.

### Enrollment Mechanism

Co-management enrollment happens via ConfigMgr **automatically enrolling** the device into Intune MDM. Two paths:

```
Path 1: Auto-enrollment via ConfigMgr (most common)
  ConfigMgr detects Hybrid Entra Join
        │
  Co-management enabled in ConfigMgr tenant
        │
  ConfigMgr client triggers MDM auto-enrollment
        │
  Device appears in Intune as "Co-managed"
        │
  DeviceEnrollmentType = 7 (ConfigMgr-managed) in Intune

Path 2: Existing MDM-enrolled devices + ConfigMgr client pushed
  Device already in Intune (EnrollmentType = 1/3/6)
        │
  ConfigMgr client deployed (pushed or app)
        │
  Co-management detected automatically
```

### MDM Enrollment Authority During Co-Management

When ConfigMgr enrolls a device into MDM for co-management:
- The MDM enrollment authority is **Intune**
- The ConfigMgr client remains installed and running
- For workloads assigned to ConfigMgr: ConfigMgr policy wins, Intune sends no conflicting policy
- For workloads assigned to Intune: Intune policy wins, ConfigMgr policy is not applied for that workload

### CMG Role (Cloud Management Gateway)

For internet-based co-managed devices, CMG provides the ConfigMgr management channel:

```
Internet Device
      │
      ▼ (HTTPS)
  CMG (Azure VM/VMSS)
      │
      ▼ (internal HTTPS)
  CMG Connection Point (site server role)
      │
      ▼
  ConfigMgr Primary Site
```

Without CMG, ConfigMgr can only manage devices on-premises (or VPN). Intune workloads continue working for internet devices regardless.

### Key Registry Locations

```
Co-management state:
HKLM\SOFTWARE\Microsoft\CCM\CoManagementFlags
  Flags = bitmask of active co-management features

MDM enrollment status:
HKLM\SOFTWARE\Microsoft\Enrollments\{GUID}\
  ProviderID = MS DM Server (Intune)

ConfigMgr client state:
HKLM\SOFTWARE\Microsoft\CCM
  CcmExec service status

Workload authority (local cache):
HKLM\SOFTWARE\Microsoft\CCM\CoManagementSettings
```

</details>

---

## Dependency Stack

```
Microsoft Entra ID (Hybrid Join — device object must exist)
        │
Active Directory (on-prem domain join)
        │
ConfigMgr Site (Primary or CAS) — reachable from device
        │
ConfigMgr Client (ccmexec.exe) — installed and healthy
        │
Co-management setting enabled in ConfigMgr Cloud Services
        │
Azure AD Connect / Entra Connect — hybrid join sync
        │
Intune MDM auto-enrollment (triggered by ConfigMgr)
        │
Workload sliders (ConfigMgr Admin Console → Co-management)
        │
Policy delivery per workload (ConfigMgr or Intune)
        │
Device compliance state (Intune) + ConfigMgr deployment state
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Device shows "ConfigMgr" in Intune but no MDM enrollment | Co-management in Tenant Attach mode only (not full enrollment) | `dsregcmd /status` → MDMUrl field |
| Device enrolled in Intune but not showing co-managed in SCCM console | ConfigMgr client not installed or not communicating | CCMExec service status; `ccm.log` |
| Policy not applying after workload moved to Intune | Device not yet picked up new workload assignment | Force ConfigMgr policy eval; wait for Intune check-in |
| Compliance policy not evaluating in Intune | Compliance workload still on ConfigMgr | Check workload slider setting |
| Device shows compliant in ConfigMgr but non-compliant in Intune | Different compliance policies from each authority | Identify which workload owns compliance; check Intune compliance details |
| ConfigMgr app deployments not working | Client apps workload moved to Intune but apps not repackaged | Revert client apps workload or repackage as Intune Win32 apps |
| Duplicate device objects in Intune | Device enrolled via ConfigMgr co-management AND re-enrolled manually | Check enrollment type; remove stale object |
| `CoManagementFlags` = 0 in registry | Co-management not actually configured or client not receiving settings | Re-check ConfigMgr Cloud Services → Co-management enabled |
| Device in pilot collection but still getting ConfigMgr policy | Pilot collection membership not yet evaluated | Force collection membership evaluation in ConfigMgr |

---

## Validation Steps

**1. Confirm Hybrid Entra Join state:**
```powershell
dsregcmd /status
# Look for:
# AzureAdJoined : YES
# DomainJoined  : YES
# DeviceId      : <GUID>
# MdmUrl        : https://enrollment.manage.microsoft.com/enrollmentserver/discovery.svc
```

**2. Confirm ConfigMgr client is healthy:**
```powershell
$svc = Get-Service -Name CcmExec -ErrorAction SilentlyContinue
Write-Host "CCMExec: $($svc.Status)"
Get-WmiObject -Namespace root\ccm -Class SMS_Client -ErrorAction SilentlyContinue |
    Select ClientVersion, ClientActionInProgress
```

**3. Check co-management flags:**
```powershell
$flags = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\CCM\CoManagementFlags" -ErrorAction SilentlyContinue
Write-Host "CoManagementFlags: $($flags.Flags)"
# 0 = not co-managed, non-zero = active co-management bitmask
```

**4. Verify MDM enrollment:**
```powershell
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" |
    ForEach-Object { Get-ItemProperty $_.PSPath } |
    Where-Object { $_.ProviderID -eq "MS DM Server" } |
    Select-Object ProviderID, EnrollmentType, UPN
# EnrollmentType 7 = co-management (ConfigMgr-initiated), 6 = MDM auto-enroll
```

**5. Check workload authority for compliance:**
```powershell
# ConfigMgr WMI — which workloads are set to Intune
Get-WmiObject -Namespace root\ccm -Class CCM_CoManagementWorkload -ErrorAction SilentlyContinue |
    Select-Object WorkloadName, UseIntune
```

**6. Confirm device shows in Intune with correct enrollment type:**
```powershell
# Via Microsoft Graph (requires DeviceManagementManagedDevices.Read.All)
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
    Select-Object DeviceName, ManagementAgent, EnrollmentType, ComplianceState
```

**7. Check ConfigMgr co-management health report:**
```
ConfigMgr Console → Monitoring → Co-management → 
  Co-management Status (per workload)
  Enrollment errors
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Device Not Enrolling into Co-Management

1. Verify Hybrid Entra Join is complete (`dsregcmd /status` → `AzureAdJoined = YES` AND `DomainJoined = YES`).
2. Verify ConfigMgr client is installed and CcmExec service is running.
3. Check `CoManagementHandler.log` on client: `C:\Windows\CCM\Logs\CoManagementHandler.log`.
4. In ConfigMgr console: confirm co-management is enabled (Administration → Cloud Services → Co-management → Properties → Enablement = `Pilot` or `All`).
5. Confirm device is in the co-management pilot collection (if using Pilot mode).
6. Check `CCMSetup.log` for client installation issues.
7. Verify MDM auto-enrollment is allowed: Entra ID → Mobility (MDM and WIP) → Microsoft Intune → MDM User scope must include the device's user.

### Phase 2: Co-Management Active but Workload Transition Not Working

1. In ConfigMgr console, verify workload slider position for the target workload.
2. If using pilot: confirm device is in the pilot collection. Force collection eval: right-click collection → Run Summarization.
3. On client: trigger ConfigMgr policy retrieval:
   ```
   Right-click Configuration Manager in system tray → Machine Policy Retrieval & Evaluation Cycle
   ```
4. Check `CoManagementSettings.log` on client for workload assignment update.
5. Wait for Intune check-in (up to 8 hours, or trigger sync via Company Portal → Sync).
6. Verify in Intune portal: Device → Overview → MDM authority should show workload ownership.

### Phase 3: Policy Conflict Between ConfigMgr and Intune

1. Identify which workload owns the conflicting setting (e.g., device configuration).
2. If workload is on ConfigMgr: Intune sends no policy for that workload; any Intune config for those settings is ignored.
3. If workload is on Intune: ConfigMgr does not apply baselines/config items for that workload.
4. For compliance: only one system's compliance result feeds Conditional Access. If Compliance workload = ConfigMgr, the device must be marked compliant in ConfigMgr (which syncs to Entra).
5. Check for settings applied by both systems before workload assignment was made (stale settings may persist).

### Phase 4: Device Showing Stale/Duplicate in Intune

1. Identify both device objects in Intune (filter by device name or serial).
2. Check enrollment type and last check-in time of each.
3. The correct co-managed object will have `ManagementAgent = ConfigurationManagerClientMdm`.
4. Delete the stale object (older, not checking in) via Intune portal → Device → Delete.
5. If the device re-creates a duplicate, check if the ConfigMgr client is triggering re-enrollment; review `CoManagementHandler.log`.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Force co-management enrollment on a device</summary>

**Use when:** Device has ConfigMgr client and is Hybrid Joined but hasn't enrolled into MDM co-management.

```powershell
# Step 1: Verify prerequisites on device
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|MdmUrl"

# Step 2: Check if MDM enrollment is blocked by scope
# In Entra Admin Center: Azure AD → Mobility → Microsoft Intune → verify user/group in MDM User scope

# Step 3: Force ConfigMgr machine policy
Invoke-WmiMethod -Namespace root\ccm -Class SMS_Client -Name TriggerSchedule -ArgumentList "{00000000-0000-0000-0000-000000000021}"

# Step 4: Check co-management handler log for errors
Get-Content "C:\Windows\CCM\Logs\CoManagementHandler.log" -Tail 50

# Step 5: If MDM URL missing from dsregcmd, force Entra re-join task
dsregcmd /debug
# Then check Event Viewer: Applications and Services Logs → Microsoft → Windows → Workplace Join
```

**Rollback:** N/A (enrollment is additive; removing co-management requires unenrolling the MDM enrollment).

</details>

<details><summary>Playbook 2 — Move a workload from ConfigMgr to Intune (phased)</summary>

**Use when:** Ready to transition a specific workload (e.g., Compliance) to Intune authority.

```
Step 1: In ConfigMgr Console
  Administration → Cloud Services → Co-management → Properties → Workloads
  Move target workload slider to "Pilot Intune"
  Assign a small pilot collection (50-100 devices)

Step 2: Monitor pilot for 1 week
  ConfigMgr: Monitoring → Co-management → check workload compliance
  Intune: Devices → Monitor → Device compliance

Step 3: Validate no compliance regression
  Run in Intune (PowerShell + Graph):
```
```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
$devices = Get-MgDeviceManagementManagedDevice -Filter "complianceState eq 'noncompliant'"
$devices | Select-Object DeviceName, ComplianceState, LastSyncDateTime | 
    Sort-Object LastSyncDateTime -Descending | Format-Table
```
```
Step 4: If no issues → move slider to "Intune" (all devices)
Step 5: Remove equivalent ConfigMgr compliance baselines to avoid duplication
```

**Rollback:** Move slider back to ConfigMgr for the workload. Re-apply ConfigMgr compliance baselines.

</details>

<details><summary>Playbook 3 — Remove stale Intune MDM enrollment from co-managed device</summary>

**Use when:** Device has two MDM enrollments or you need to remove the Intune enrollment while keeping ConfigMgr.

```powershell
# WARNING: This removes Intune management authority. Device returns to ConfigMgr-only.
# Only run if intentionally retiring co-management on this device.

# Step 1: Find enrollment ID
$enrollments = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" |
    ForEach-Object { Get-ItemProperty $_.PSPath } |
    Where-Object { $_.ProviderID -eq "MS DM Server" }
$enrollmentId = $enrollments.PSChildName
Write-Host "Enrollment ID: $enrollmentId"

# Step 2: Review before removing
$enrollments | Select-Object ProviderID, EnrollmentType, UPN

# Step 3: Remove MDM enrollment (destructive — confirm first)
# Use the MDM unenrollment via Company Portal or:
$csPath = "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\$enrollmentId"
# Do NOT delete registry manually — use proper MDM unenrollment command:
Start-Process "C:\Windows\System32\MdmDiagnosticsTool.exe" -ArgumentList "-mdm" -Wait
# Or run from elevated PS:
# Invoke-WmiMethod -Namespace root\cimv2\mdm\dmmap -ClassName MDM_Unenrollment -MethodName Unenroll
```

**Rollback:** Re-trigger ConfigMgr co-management enrollment by running Machine Policy eval on client.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect co-management evidence for escalation
.NOTES     Run as local admin on the co-managed device
#>

$OutputDir = "C:\Temp\CoMgmt-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. Entra/Domain join status
dsregcmd /status | Out-File "$OutputDir\dsregcmd-status.txt"

# 2. ConfigMgr client version and health
try {
    Get-WmiObject -Namespace root\ccm -Class SMS_Client |
        Select-Object ClientVersion, ClientActionInProgress |
        Export-Csv "$OutputDir\CCM-Client.csv" -NoTypeInformation
} catch { "ConfigMgr WMI not available" | Out-File "$OutputDir\CCM-Client.csv" }

# 3. Co-management flags
$flags = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\CCM\CoManagementFlags" -ErrorAction SilentlyContinue
[PSCustomObject]@{ Flags = $flags.Flags } | Export-Csv "$OutputDir\CoManagement-Flags.csv" -NoTypeInformation

# 4. MDM enrollments
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" |
    ForEach-Object { Get-ItemProperty $_.PSPath } |
    Select-Object ProviderID, EnrollmentType, UPN, PSChildName |
    Export-Csv "$OutputDir\MDM-Enrollments.csv" -NoTypeInformation

# 5. Co-management workloads (ConfigMgr WMI)
try {
    Get-WmiObject -Namespace root\ccm -Class CCM_CoManagementWorkload |
        Select-Object WorkloadName, UseIntune |
        Export-Csv "$OutputDir\CoMgmt-Workloads.csv" -NoTypeInformation
} catch { "WMI workload class not available" | Out-File "$OutputDir\CoMgmt-Workloads.csv" }

# 6. CCM service status
Get-Service -Name CcmExec -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType |
    Export-Csv "$OutputDir\CCM-Service.csv" -NoTypeInformation

# 7. Recent CoManagementHandler log
$logPath = "C:\Windows\CCM\Logs\CoManagementHandler.log"
if (Test-Path $logPath) {
    Get-Content $logPath -Tail 200 | Out-File "$OutputDir\CoManagementHandler-tail200.txt"
}

# 8. System info
Get-ComputerInfo | Select-Object CsName, OsVersion, OsBuildNumber |
    Export-Csv "$OutputDir\System-Info.csv" -NoTypeInformation

Write-Host "Evidence collected to: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Check Hybrid Join and MDM enrollment state
dsregcmd /status

# ConfigMgr client version
Get-WmiObject -Namespace root\ccm -Class SMS_Client | Select ClientVersion

# Co-management flags (0 = not co-managed)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\CCM\CoManagementFlags"

# List MDM enrollments on device
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" | ForEach-Object { Get-ItemProperty $_.PSPath } | Where ProviderID -eq "MS DM Server"

# Workload authority from ConfigMgr WMI
Get-WmiObject -Namespace root\ccm -Class CCM_CoManagementWorkload | Select WorkloadName, UseIntune

# Force ConfigMgr machine policy retrieval
Invoke-WmiMethod -Namespace root\ccm -Class SMS_Client -Name TriggerSchedule -ArgumentList "{00000000-0000-0000-0000-000000000021}"

# Force Intune MDM sync
Invoke-CimMethod -Namespace root/CIMV2/MDM/DMMap -ClassName MDM_Client -MethodName TriggerSync

# Tail CoManagementHandler log
Get-Content "C:\Windows\CCM\Logs\CoManagementHandler.log" -Wait -Tail 50

# Check CCMExec service
Get-Service CcmExec | Select Status, StartType

# List co-managed devices in Intune (Graph)
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "managementAgent eq 'configurationManagerClientMdm'" | Select DeviceName, ComplianceState, LastSyncDateTime
```

---

## 🎓 Learning Pointers

- **Workload sliders are the heart of co-management** — each workload is independently controlled. Moving Compliance to Intune does not move Device Configuration. Plan the order: Compliance first (low risk, feeds CA), then Resource Access, then Device Configuration last (highest impact). [MS Docs: Co-management workloads](https://learn.microsoft.com/en-us/mem/configmgr/comanage/workloads)

- **Compliance authority determines what feeds Conditional Access** — if the Compliance workload is on ConfigMgr, Intune reads the ConfigMgr compliance result (synced via Entra). If it's on Intune, Intune evaluates its own policies. Mixing up authority here is the most common cause of CA bypass or unexpected blocks. [MS Docs: Co-management and CA](https://learn.microsoft.com/en-us/mem/configmgr/comanage/coexistence)

- **Pilot collections reduce rollout risk** — every workload supports a separate pilot collection. Use this to test Intune authority on 50 devices before fleet-wide transition. The pilot collection is evaluated server-side by ConfigMgr; devices check in and receive the updated workload assignment within the next policy cycle.

- **Co-management is NOT tenant attach** — tenant attach gives read-only portal visibility into ConfigMgr devices without MDM enrollment. Co-management enrolls devices into Intune MDM. Many teams confuse the two. `dsregcmd /status` → `MdmUrl` field confirms actual MDM enrollment. [MS Docs: Tenant attach vs co-management](https://learn.microsoft.com/en-us/mem/configmgr/tenant-attach/device-sync-actions)

- **CMG is required for internet-based co-managed devices** — without CMG, ConfigMgr cannot reach devices off-network. Intune workloads work fine for internet devices, but ConfigMgr workloads (app deployment, baselines) only work on-prem or via VPN/CMG. Plan CMG capacity before extending co-management to remote workers.

- **`CoManagementHandler.log` is your primary troubleshooting source** — it logs every co-management state change, workload assignment update, and MDM enrollment attempt on the client. When a device isn't enrolling or workload transitions aren't applying, this log explains why. Located at `C:\Windows\CCM\Logs\CoManagementHandler.log`.
