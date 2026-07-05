# Windows Autopatch — Hotfix Runbook (Mode B: Ops)
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

Run these first to locate the failure layer.

```powershell
# 1. Check device registration status in Autopatch (via Graph)
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"
Get-MgDeviceManagementDevice -Filter "deviceName eq '<DeviceName>'" | Select-Object DeviceName, ManagementState

# 2. Check the device's Autopatch group / deployment ring assignment
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/admin/windows/updates/updatableAssets" |
    Select-Object -ExpandProperty value | Where-Object { $_.deviceName -eq '<DeviceName>' }

# 3. Check local Windows Update for Business / Autopatch policy application
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" -ErrorAction SilentlyContinue

# 4. Check required prerequisite services are running
Get-Service -Name "wuauserv","UsoSvc","DoSvc" | Select-Object Name, Status, StartType

# 5. Check Intune enrollment + compliance (Autopatch requires co-managed or Intune-managed + Entra hybrid/joined)
dsregcmd /status | Select-String "AzureAdJoined","DomainJoined","EnterpriseJoined"
```

| Result | Action |
|--------|--------|
| Device not in `updatableAssets` list | → Fix 1: Register device with Autopatch |
| Device in "Not ready" or "Error" readiness state | → Fix 2: Resolve prerequisite failures |
| Wrong or no deployment ring assignment | → Fix 3: Reassign device to a deployment ring group |
| WU services stopped/disabled | → Fix 4: Restart/re-enable Windows Update services |
| Device not Entra joined or hybrid joined | → Fix 5: Fix device join state (Autopatch hard requirement) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Licensing]
  └─ Windows 10/11 Enterprise E3+ (or E5, Microsoft 365 F3/E3/E5) per device/user
         |
[Device Join State]
  └─ Entra ID joined OR Entra ID hybrid joined (Entra ID Connect syncing)
  └─ NOT purely on-prem AD joined with no cloud sync
         |
[Management]
  └─ Intune-enrolled and Intune the sole/primary MDM (or co-managed with ConfigMgr,
     Windows Update workloads shifted to Intune)
         |
[Autopatch Enrollment]
  └─ Autopatch enabled in Intune tenant admin
  └─ Device added to an Autopatch-managed dynamic/assigned Entra group
  └─ Device passes readiness prerequisite checks
         |
[Deployment Ring Assignment]
  └─ Test / First / Fast / Broad ring (device auto-balanced or manually pinned)
         |
[Update Orchestration]
  └─ Windows Update for Business policies (feature + quality + driver) applied by Autopatch
  └─ Deployment schedule staggered by ring
         |
[Device installs updates on managed schedule]
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the device appears as an Autopatch-managed asset**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/admin/windows/updates/updatableAssets/$('<DeviceId>')"
```
*Good:* Returns an object with `enrollment.enrollmentState: enrolled`.
*Bad:* 404 or `notReady` — device hasn't completed Autopatch registration.

**2. Check readiness assessment (registration prerequisites)**
In Intune admin center: **Windows Autopatch > Devices** — look at the "Readiness" column. Common failure reasons surfaced here:
- Not licensed
- Not Entra ID (hybrid) joined
- Not Intune enrolled / co-management workload not shifted
- Outdated OS build below Autopatch's minimum baseline

**3. Confirm deployment ring / group membership**
```powershell
Get-MgGroupMember -GroupId '<AutopatchRingGroupId>' | Where-Object { $_.Id -eq '<DeviceObjectId>' }
```
*Good:* Device object present in exactly one ring group.
*Bad:* Present in zero or multiple ring groups — causes conflicting policy assignment.

**4. Check Windows Update service health locally**
```powershell
Get-Service -Name "wuauserv","UsoSvc","DoSvc","BITS" | Select-Object Name, Status
Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 20 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message
```

**5. Confirm the device pulled the correct Autopatch-deployed policies**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" -ErrorAction SilentlyContinue |
    Select-Object DeferQualityUpdatesPeriodInDays, DeferFeatureUpdatesPeriodInDays, ActiveHoursStart, ActiveHoursEnd
```
These values should match the ring's configured deferral (Autopatch manages these behind the scenes — Test ring = 0 day defer, Broad ring = longer defer).

---
## Common Fix Paths

<details><summary>Fix 1 — Register a device with Autopatch</summary>

Use when: device meets prerequisites but was never added to Autopatch.

1. In Intune admin center: **Windows Autopatch > Devices > Add devices** — add via CSV (Serial Number + Manufacturer) or via device group.
2. Simplest ongoing method: add the device object to your configured Autopatch dynamic Entra group (e.g., `sg-Windows-Autopatch-Devices`), which auto-enrolls on next Autopatch sync cycle (up to 24 hours).
```powershell
Connect-MgGraph -Scopes "GroupMember.ReadWrite.All"
New-MgGroupMember -GroupId '<AutopatchDynamicGroupId>' -DirectoryObjectId '<DeviceObjectId>'
```

**Rollback:** Remove from the group — device falls back to whatever Windows Update policy applied before (typically default WUfB or none).

</details>

<details><summary>Fix 2 — Resolve prerequisite/readiness failures</summary>

Use when: readiness status shows "Not ready" or "Error."

```powershell
# Confirm license
Get-MgUserLicenseDetail -UserId '<UPN>' | Where-Object { $_.SkuPartNumber -match "ENTERPRISE|M365" }

# Confirm Entra join state
dsregcmd /status | Select-String "AzureAdJoined","DomainJoined"

# Confirm Intune enrollment
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" | Select-Object ManagementAgent, ComplianceState
```

Fix path depends on which prerequisite failed:
- License missing → assign from license pool.
- Not Entra joined → re-run `dsregcmd /leave` then rejoin, or fix Entra Connect sync (see `EntraID/Troubleshooting/Connect-Sync-B.md`).
- Not Intune enrolled → trigger enrollment, confirm co-management workload switch for Windows Update if ConfigMgr-managed.

**Rollback:** N/A — these are corrective actions restoring intended state.

</details>

<details><summary>Fix 3 — Reassign device to correct deployment ring</summary>

Use when: device is in the wrong ring, or in zero/multiple rings.

```powershell
Connect-MgGraph -Scopes "GroupMember.ReadWrite.All"

# Remove from incorrect ring group
Remove-MgGroupMemberByRef -GroupId '<WrongRingGroupId>' -DirectoryObjectId '<DeviceObjectId>'

# Add to correct ring group
New-MgGroupMember -GroupId '<CorrectRingGroupId>' -DirectoryObjectId '<DeviceObjectId>'
```

Default rings: **Test** (pilot, smallest, first to receive updates), **First** (early broad rollout), **Fast**, **Broad** (majority of the fleet, longest deferral). A device should belong to exactly one ring group at a time.

**Rollback:** Reverse the group membership changes.

</details>

<details><summary>Fix 4 — Restart/re-enable Windows Update services</summary>

Use when: `wuauserv`, `UsoSvc`, or `DoSvc` are stopped or disabled locally.

```powershell
Set-Service -Name "wuauserv" -StartupType Automatic
Start-Service -Name "wuauserv"
Set-Service -Name "UsoSvc" -StartupType Automatic
Start-Service -Name "UsoSvc"
Set-Service -Name "DoSvc" -StartupType Automatic
Start-Service -Name "DoSvc"

# Force a scan
UsoClient StartScan
```

**Rollback:** N/A — restoring services to running state is the fix, not a risk.

</details>

<details><summary>Fix 5 — Fix device join state blocking Autopatch</summary>

Use when: device is domain-joined only with no Entra sync, or hybrid join is broken.

```powershell
dsregcmd /status
# If DomainJoined: YES but AzureAdJoined: NO — hybrid join is broken
dsregcmd /forcerecovery
```

See `EntraID/Troubleshooting/HybridJoin-B.md` for the full hybrid join troubleshooting path if `/forcerecovery` doesn't resolve it.

**Rollback:** N/A — corrective action.

</details>

---
## Escalation Evidence

```
WINDOWS AUTOPATCH ESCALATION
======================================
Date/Time                :
Tenant ID                 :
Device Name                :
Device Object ID            :
Autopatch Enrollment State : (enrolled / notReady / error)
Readiness Failure Reason    :
Deployment Ring             :
Entra Join State            : (AzureAdJoined / HybridJoined / DomainOnly)
Intune Managed              : YES / NO
WU Services State           : (wuauserv / UsoSvc / DoSvc status)
Last Successful Update Scan :
Steps Already Tried          :
```

---
## 🎓 Learning Pointers

- **Autopatch is an orchestration layer over WUfB, not a replacement update mechanism** — it doesn't reinvent Windows Update; it manages ring assignment, deferral policy, and staged rollout on top of Windows Update for Business and driver/feature update policies you'd otherwise hand-configure in Intune.
- **Device join state is a hard gate, not a soft preference** — pure on-prem AD-joined devices with no Entra sync cannot be Autopatch-managed at all. Hybrid join (Entra Connect syncing) or full Entra join is mandatory.
- **Ring assignment should never be manual busywork at scale** — use dynamic Entra groups with membership rules (e.g., based on device tag or OU) so ring balancing happens automatically as devices are added/removed.
- **Readiness assessment runs continuously, not just at enrollment** — a device that passes prerequisites today can drop out of "ready" state later (e.g., license removed, Intune enrollment breaks) — check the Devices readiness column periodically, don't assume enrollment is permanent.
- **MS Docs:** [Windows Autopatch overview](https://learn.microsoft.com/en-us/windows/deployment/windows-autopatch/overview/windows-autopatch-overview) | [Prerequisites](https://learn.microsoft.com/en-us/windows/deployment/windows-autopatch/prepare/windows-autopatch-prerequisites) | [Deployment rings](https://learn.microsoft.com/en-us/windows/deployment/windows-autopatch/deploy/windows-autopatch-groups-overview)
