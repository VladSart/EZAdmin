# Intune Co-Management with ConfigMgr — Hotfix Runbook (Mode B: Ops)
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
# 1. Check co-management status on a client device
(Get-CimInstance -Namespace "root\ccm" -ClassName "SMS_Client").ClientVersion
Get-WmiObject -Namespace "root\ccm" -Class "CCM_CoManagementHandler" -ErrorAction SilentlyContinue

# 2. Check co-management enrollment in Intune (run from device or admin host with Graph)
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "contains(deviceName, '<DEVICE-NAME>')" |
    Select-Object DeviceName, ManagementAgent, EnrolledDateTime, LastSyncDateTime, ComplianceState, JoinType

# 3. Check ConfigMgr client health on device
$ccmHealth = Get-WmiObject -Namespace "root\ccm\ClientSDK" -Class "CCM_ClientUtilities" -ErrorAction SilentlyContinue
if (-not $ccmHealth) { Write-Host "CCM client not installed or WMI broken" -ForegroundColor Red }

# 4. Check co-management workload assignments in ConfigMgr console (PowerShell via ConfigMgr module)
# Run on SCCM site server:
Import-Module "$($env:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" -ErrorAction SilentlyContinue
if (Get-Module ConfigurationManager) {
    $SiteCode = (Get-PSDrive -PSProvider CMSite).Name
    Set-Location "$($SiteCode):\"
    Get-CMCoManagementPolicy | Select-Object Name, *Workload* | Format-List
}

# 5. Check Hybrid Join status (co-management requires HAADJ or AADJ)
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|EnterpriseJoined|TenantName|DeviceId"
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| CCM class not found | ConfigMgr client not installed / corrupt | → Fix 1 |
| ManagementAgent = `mdm` only (no ConfigMgr) | Device enrolled in Intune but lost ConfigMgr | → Fix 1 |
| ManagementAgent = `ConfigurationManager` only | Co-management not enabled or workloads not switched | → Fix 2 |
| ComplianceState = Noncompliant | Compliance policy conflict between ConfigMgr/Intune | → Fix 3 |
| AzureAdJoined = NO + DomainJoined = YES | Hybrid join broken — co-management prerequisite missing | → Fix 4 |
| No device in Intune at all | Auto-enrollment not configured or token expired | → Fix 5 |

---
## Dependency Cascade

<details><summary>What must be true for co-management to work</summary>

```
Entra ID (Cloud)
    └── Hybrid Azure AD Join (HAADJ) OR Azure AD Join (AADJ)
          └── Auto-enrollment to Intune (MDM scope = All or scoped group)
                └── ConfigMgr (on-prem SCCM/MECM)
                      ├── Version 1806+ (co-management GA)
                      ├── HTTPS-enabled CMG OR co-management Cloud Management Gateway
                      ├── Client Settings: Enable co-management = Yes
                      ├── Co-management Policy: Auto-enroll via Intune enabled
                      └── Workload Sliders (per workload: ConfigMgr / Pilot Intune / Intune)
                            ├── Compliance Policies
                            ├── Device Configuration
                            ├── Resource Access (Wi-Fi, VPN, Cert)
                            ├── Endpoint Protection
                            ├── Office Click-to-Run
                            ├── Windows Update Policies
                            └── Client Apps
```

Key failure points:
- Device not hybrid-joined (dsregcmd shows DomainJoined=YES but AzureAdJoined=NO)
- MDM auto-enrollment scope doesn't include device's user or group
- ConfigMgr auto-enrollment setting not enabled in co-management properties
- Cloud Management Gateway (CMG) cert expired or connectivity down
- Workload slider conflict: both ConfigMgr and Intune delivering same policy

</details>

---
## Diagnosis & Validation Flow

**1. Confirm device is co-managed (both agents reporting)**
```powershell
# On device — should return both MDM and ConfigMgr enrollment state
Get-WmiObject -Namespace root\ccm -Class CCM_CoManagementHandler -ErrorAction SilentlyContinue |
    Select-Object ComanagedDevice, EnrollmentStatus

# From Intune — confirm ManagementAgent shows co-management
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DEVICE-NAME>'" |
    Select-Object DeviceName, ManagementAgent, JoinType, ComplianceState
```
Expected: `ManagementAgent = comanagedMDM` or both MDM and ConfigMgr listed.

**2. Confirm hybrid join state**
```powershell
# On device
dsregcmd /status
```
Expected:
```
AzureAdJoined : YES
DomainJoined  : YES
```
If AzureAdJoined = NO: hybrid join broken, fix this before co-management can work. See `EntraID/Troubleshooting/HybridJoin-B.md`.

**3. Check auto-enrollment MDM scope**
```powershell
# Verify MDM scope includes the device's user
Connect-MgGraph -Scopes "Policy.Read.All"
$mdmConfig = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/policies/mobileDeviceManagementPolicies" -Method GET
$mdmConfig.value | Select-Object id, displayName, appliesTo | Format-Table
```
Or check in Entra portal: Identity > Devices > Device settings > MDM user scope (must be All or include the user's group).

**4. Check ConfigMgr client co-management status log**
```powershell
# On device — check co-management log
$logPath = "C:\Windows\CCM\Logs\CoManagementHandler.log"
if (Test-Path $logPath) {
    Get-Content $logPath -Tail 50 | Select-String "error|fail|warning|enroll" -CaseSensitive:$false
} else {
    Write-Host "Log not found — CCM client may not be installed" -ForegroundColor Red
}
```

**5. Check workload slider assignments**
In ConfigMgr console: Administration > Cloud Services > Co-management > Properties > Workloads tab.
Verify each workload is set to the intended authority (ConfigMgr / Pilot Intune / Intune).

---
## Common Fix Paths

<details><summary>Fix 1 — Reinstall or repair ConfigMgr client</summary>

```powershell
# Option A: Repair CCM client (preserves enrollment state)
$ccmSetup = "C:\Windows\ccmsetup\ccmsetup.exe"
if (Test-Path $ccmSetup) {
    Start-Process $ccmSetup -ArgumentList "/repair" -Wait
} else {
    Write-Host "ccmsetup not found — perform fresh client install" -ForegroundColor Yellow
}

# Option B: Remote push from ConfigMgr (run on site server)
# In ConfigMgr console: Assets and Compliance > Devices > right-click device > Install Client

# Option C: Manual reinstall (get CCMSetup.exe from site server)
\\<SITESERVER>\SMS_<SITECODE>\Client\CCMSetup.exe /mp:<MANAGEMENT-POINT> SMSSITECODE=<SITECODE>

# Verify client installed and reporting
Get-Service -Name "CcmExec" | Select-Object Name, Status
(Get-CimInstance -Namespace root\ccm -ClassName SMS_Client).ClientVersion
```

**Rollback:** Stop CCM service if reinstall causes issues: `Stop-Service CcmExec -Force`

</details>

<details><summary>Fix 2 — Enable co-management and trigger auto-enrollment</summary>

**In ConfigMgr console (site-wide setting):**
1. Administration > Cloud Services > Co-management > Properties
2. Enrollment tab: Enable "Automatically enroll existing Configuration Manager-managed devices in Microsoft Intune"
3. Set pilot collection or "All" scope as appropriate

**Force enrollment on a specific device (PowerShell on device):**
```powershell
# Trigger MDM enrollment via task scheduler
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)
$action = New-ScheduledTaskAction -Execute "C:\Windows\System32\deviceenroller.exe" -Argument "/c /AutoEnrollMDM"
Register-ScheduledTask -TaskName "TempMDMEnroll" -Trigger $trigger -Action $action -RunLevel Highest -Force
Start-ScheduledTask -TaskName "TempMDMEnroll"
Start-Sleep -Seconds 30
Unregister-ScheduledTask -TaskName "TempMDMEnroll" -Confirm:$false

# Check MDM enrollment result
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" | ForEach-Object {
    $e = Get-ItemProperty $_.PSPath
    [PSCustomObject]@{ EnrollmentID = $_.PSChildName; ProviderID = $e.ProviderID; UPN = $e.UPN }
} | Where-Object { $_.ProviderID -match "MS DM Server" }
```

</details>

<details><summary>Fix 3 — Resolve compliance policy conflict</summary>

When both ConfigMgr and Intune deliver compliance policies, conflicts can mark a device non-compliant even if it meets all settings.

```powershell
# Check which policies are applying from Intune
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"
$device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DEVICE-NAME>'"
$states = Get-MgDeviceManagementManagedDeviceCompliancePolicyState -ManagedDeviceId $device.Id
$states | Select-Object DisplayName, State, Version | Format-Table

# Check ConfigMgr compliance on device
Get-WmiObject -Namespace root\ccm\dcm -Class SMS_DesiredStateConfiguration -ErrorAction SilentlyContinue |
    Select-Object DisplayName, ComplianceState, LastEvalTime | Format-Table
```

**Resolution steps:**
1. Decide which authority should own compliance — Intune is recommended for internet-facing devices
2. In ConfigMgr: move the Compliance Policies workload slider to "Intune" for affected devices/collection
3. Ensure Intune compliance policy covers same baselines as ConfigMgr was enforcing
4. Force Intune sync: `Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{sScheduleID="{00000000-0000-0000-0000-000000000001}"}`

</details>

<details><summary>Fix 4 — Fix Hybrid Join prerequisite for co-management</summary>

Co-management requires either Hybrid Azure AD Join (HAADJ) or pure Azure AD Join (AADJ). If hybrid join is broken:

```powershell
# Check hybrid join errors
dsregcmd /status
# Look for "Error Code" in the output

# Common fix: force hybrid join registration
dsregcmd /debug
# Or trigger via scheduled task:
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
$action = New-ScheduledTaskAction -Execute "C:\Windows\System32\dsregcmd.exe" -Argument "/join"
Register-ScheduledTask -TaskName "TempHybridJoin" -Trigger $trigger -Action $action -RunLevel Highest -Force
Start-ScheduledTask -TaskName "TempHybridJoin"
```

For deeper hybrid join troubleshooting: see `EntraID/Troubleshooting/HybridJoin-B.md`.

</details>

<details><summary>Fix 5 — Fix MDM auto-enrollment scope</summary>

```powershell
# Check current MDM scope via Intune portal
# Entra admin center: Identity > Devices > Device settings

# Or via Graph:
Connect-MgGraph -Scopes "Policy.ReadWrite.MobilityManagement"
$policy = (Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/policies/mobileDeviceManagementPolicies" -Method GET).value |
    Where-Object { $_.displayName -match "Intune" }
$policy | Select-Object id, displayName, appliesTo

# If appliesTo = "selected", ensure the device's user is in the scoped group
# To set to All (tenant-wide) — do this in Entra portal, not via script (admin UI confirmation required)
```

In Entra admin center: Identity > Devices > Device settings > MDM user scope = **All** (or add user's group to Selected).

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Intune / ConfigMgr Co-Management
======================================================
Date/Time (UTC)        : [                    ]
Reported by            : [                    ]
Affected device(s)     : [                    ]
ConfigMgr site code    : [                    ]
ConfigMgr version      : [                    ]
Intune tenant ID       : [                    ]

Symptoms
--------
[ ] Device not appearing in Intune (ConfigMgr-only managed)
[ ] Device appears in Intune but compliance policies not applying
[ ] Device lost ConfigMgr management (MDM-only now)
[ ] Workload conflict — duplicate policy delivery
[ ] Co-management workloads not switching as expected
[ ] Other: [                                         ]

Triage results
--------------
Hybrid join state (dsregcmd)   : [ HAADJ / AADJ / Domain-only ]
ManagementAgent in Intune      : [                    ]
CCM client version             : [                    ]
MDM enrollment UPN             : [                    ]
Co-management workload setting : [                    ]
Compliance state               : [ Compliant / Noncompliant ]

Evidence collected
------------------
[ ] dsregcmd /status output
[ ] CoManagementHandler.log (C:\Windows\CCM\Logs\)
[ ] MDM enrollment registry (HKLM:\SOFTWARE\Microsoft\Enrollments)
[ ] Intune device detail screenshot
[ ] ConfigMgr co-management properties screenshot (Workloads tab)

Escalation path:
- ConfigMgr issues: Microsoft CSS (Configuration Manager support)
- Intune MDM issues: Microsoft 365 admin centre > Support
- Hybrid join issues: see EntraID/Troubleshooting/HybridJoin-B.md
```

---
## 🎓 Learning Pointers

- **Co-management is a spectrum, not a binary switch** — each workload (Compliance, Device Config, Endpoint Protection, etc.) has its own slider: ConfigMgr / Pilot Intune / Intune. You can migrate workloads gradually, piloting with a small collection before moving all devices. This is the recommended migration path. [MS Docs: Co-management workloads](https://learn.microsoft.com/en-us/mem/configmgr/comanage/workloads)
- **Hybrid join is non-negotiable** — co-management only works on devices that are either Hybrid Azure AD Joined or Azure AD Joined. Domain-only joined devices cannot enroll in Intune MDM. If you see domain-joined but not HAADJ, fix hybrid join first. [MS Docs: Prerequisites for co-management](https://learn.microsoft.com/en-us/mem/configmgr/comanage/overview#prerequisites)
- **MDM auto-enrollment scope must include the enrolling user** — the Entra ID > Device settings > MDM user scope setting controls who can auto-enroll. If set to "Selected" and the device user's group isn't included, co-management enrollment will silently fail. Always verify scope when troubleshooting enrollment failures.
- **CoManagementHandler.log is your first stop on the device** — this log at `C:\Windows\CCM\Logs\CoManagementHandler.log` records every enrollment attempt, workload evaluation, and error. Grep for "error" and "enroll" to quickly find root cause without reading the entire log.
- **Cloud Management Gateway (CMG) is required for internet co-management** — devices off-prem need a CMG to reach ConfigMgr. Without it, the CCM client loses communication when off the corporate network. If devices work on-prem but lose ConfigMgr management remotely, CMG is the likely gap. [MS Docs: Cloud Management Gateway overview](https://learn.microsoft.com/en-us/mem/configmgr/core/clients/manage/cmg/overview)
- **"Pilot Intune" workload slider is your safety net** — rather than switching an entire workload to Intune at once, use "Pilot Intune" with a small collection of test devices. Only devices in that collection get the Intune workload; all others stay on ConfigMgr. Graduate the collection once validated.
