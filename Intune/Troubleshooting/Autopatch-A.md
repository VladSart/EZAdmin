# Windows Autopatch — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

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

---
## Scope & Assumptions

This runbook covers **Windows Autopatch** — Microsoft's managed update service that orchestrates Windows quality updates, feature updates, driver/firmware updates, and Microsoft 365 Apps updates across a tenant's device fleet using deployment rings. It builds on, but does not replace, the underlying `Windows/Troubleshooting/AlwaysOnVPN-A.md`-style WUfB/CSP mechanics — see `Intune/Troubleshooting/FeatureUpdates-A.md` and `Intune/Troubleshooting/WUfB-A.md` for the raw Windows Update for Business layer Autopatch sits on top of.

**Assumes:**
- Tenant has Windows Autopatch enabled (Intune admin center > Tenant administration > Windows Autopatch)
- Devices are Windows 10/11 Enterprise or Education, E3 or higher (or eligible bundled SKU)
- Microsoft Graph PowerShell SDK for Graph-based diagnostics; portal access for Autopatch-specific blades not fully exposed via Graph

**What Autopatch solves:**
Manually managing staged update rollout (pilot group → broad deployment, with rollback capability) across Windows, drivers, firmware, and Office is high-effort and error-prone at scale. Autopatch automates ring assignment, staggers deployment automatically, monitors update compliance, and will auto-pause/rollback a ring if it detects a spike in update-related incidents — all using Microsoft's own update health telemetry.

---
## How It Works

<details><summary>Full architecture</summary>

### The Four Update Tracks

Autopatch manages four independent update tracks, each with its own cadence and rollout logic:

| Track | What it covers | Cadence |
|-------|----------------|---------|
| **Windows quality updates** | Monthly cumulative security/quality patches | Monthly, staggered by ring |
| **Windows feature updates** | Version upgrades (e.g., 23H2 → 24H2 → 25H2) | Per Microsoft's feature update release cadence |
| **Driver & firmware updates** | OEM driver/firmware packages via Windows Update | Continuous, as published |
| **Microsoft 365 Apps updates** | Office/Microsoft 365 Apps update channel management | Monthly Enterprise Channel by default |

### Deployment Ring Model

```
Test Ring (small, IT/pilot devices — validates before broad rollout)
        │
        ▼
First Ring (small % of production devices — early signal)
        │
        ▼
Fast Ring (larger subset — broader validation)
        │
        ▼
Broad Ring (majority of the fleet — final rollout)
```

Devices are assigned to rings automatically via Autopatch-managed dynamic Entra groups (or manually pinned to a specific ring if required, e.g., VIP/executive devices always in Test). Autopatch balances ring sizes to get statistically meaningful signal from Test/First before rolling to Broad.

### Registration and Readiness Pipeline

```
Device added to Autopatch device registration group (Entra dynamic/assigned group)
        │
        ▼
Autopatch service (background, ~24hr cycle) evaluates readiness:
  ├── License check (Enterprise E3+/eligible SKU)
  ├── Device join state (Entra joined or Entra hybrid joined)
  ├── Management check (Intune-enrolled, or co-managed with Windows Update
  │     workload switched to Intune/Autopatch, or ConfigMgr entirely offboarded)
  ├── OS build check (minimum supported build)
  └── Existing conflicting policy check (e.g., pre-existing WSUS GPOs)
        │
        ▼
Readiness result: Ready / Not Ready / Error
        │
        ▼
If Ready → device auto-assigned to a ring → Autopatch deploys/manages:
  ├── Windows Update for Business CSP policies (deferral, active hours, deadlines)
  ├── Driver update policy
  ├── Feature update policy (target version pinning per ring)
  └── (if enabled) Microsoft 365 Apps update policy
```

### Health Monitoring & Auto-Remediation

Autopatch continuously monitors device update compliance and correlates with **Windows Update health signals** (crash/reliability telemetry Microsoft already collects). If a ring shows anomalous incident rates after a given update, Autopatch can automatically **pause the rollout** to later rings — this is the core value proposition beyond plain WUfB: it's not just staggered deployment, it's staggered deployment with an automated circuit breaker.

### Co-management Interaction

If the tenant still uses ConfigMgr for some workloads, Autopatch requires the **Windows Update workload** (and ideally Office Click-to-Run) to be switched to Intune/Autopatch under the co-management workload slider. ConfigMgr and Autopatch cannot both manage Windows Update policy for the same device simultaneously — conflicting instructions result in unpredictable update behavior (see `Intune/Troubleshooting/CoManagement-A.md`).

### Reporting

Autopatch exposes a **Release health** dashboard and **Software update status** report in the Intune admin center, correlating Microsoft's own known-issue tracking (e.g., "Windows release health" known issues) against your fleet's actual update state — this is the single fastest way to determine "is this a known Microsoft-side issue or something specific to us."

</details>

---
## Dependency Stack

```
Licensing Layer
    └── Windows Enterprise E3+/E5, or Microsoft 365 F3/E3/E5, or eligible bundled SKU
            └── Per-device or per-user, must cover the target device

Identity Layer
    └── Entra ID joined OR Entra ID hybrid joined
            └── Entra Connect sync (for hybrid) must be healthy — see Connect-Sync-A.md

Management Layer
    └── Intune enrollment (native or co-managed)
            └── If co-managed: Windows Update + (ideally) Office C2R workload = Intune/Autopatch
            └── ConfigMgr must NOT independently manage WU policy for the same device

Autopatch Service Layer
    └── Windows Autopatch enabled at tenant level
            └── Device registration group configured (Entra dynamic/assigned group)
            └── Readiness assessment passes (license, join, management, OS build)

Ring Assignment Layer
    └── Device placed into exactly one deployment ring group
            └── Test / First / Fast / Broad

Policy Deployment Layer
    └── Autopatch-managed WUfB CSP policies applied per ring
    └── Autopatch-managed driver update policy
    └── Autopatch-managed feature update policy (version target per ring)
    └── (Optional) Microsoft 365 Apps update policy

Monitoring & Health Layer
    └── Update compliance telemetry correlated with Microsoft's release health signals
            └── Auto-pause logic on anomalous incident detection
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Device never appears in Autopatch device list | Not added to registration group, or readiness check silently failing | Check dynamic group membership rule + readiness column |
| Fleet-wide update delay across all rings | Autopatch service-side pause (known issue/incident) | Check Release health dashboard in Intune admin center |
| One ring stuck, others progressing normally | Auto-pause triggered by anomalous incident telemetry for that ring | Check ring-specific status + Microsoft release health notes |
| Devices installing updates on inconsistent schedules despite same ring | Conflicting local GPO or ConfigMgr policy overriding Autopatch-set WUfB CSPs | Check for legacy WSUS GPO / co-management workload slider |
| Feature update stuck below target version for the ring | Blocked by compatibility hold (safeguard hold) — Microsoft blocks a specific device/driver combo automatically | Check `Get-WindowsUpdateLog` / Feature Update report for safeguard hold reason |
| Autopatch shows device as "Not ready — license" despite license assigned recently | License propagation delay (up to a few hours) or license doesn't cover the device (user-based vs device-based licensing mismatch) | Re-check license assignment scope and wait for next readiness cycle |
| Device duplicated across two rings | Manual override group membership conflicting with dynamic group assignment | Audit static vs dynamic group memberships for that device |
| Office update channel not changing despite Autopatch M365 Apps policy | Office update policy pre-existing from GPO/registry taking precedence | Check `HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate` for conflicting local values |

---
## Validation Steps

**Step 1 — Confirm Autopatch is enabled tenant-wide**
Portal: Intune admin center > Tenant administration > Windows Autopatch > Overview. Confirm "Enrolled" status and review the enrollment prerequisite checklist shown there (this pre-check is portal-only, not fully exposed via Graph).

**Step 2 — Confirm device registration group membership and dynamic rule**
```powershell
Connect-MgGraph -Scopes "Group.Read.All","Device.Read.All"
Get-MgGroup -Filter "displayName eq '<AutopatchRegistrationGroupName>'" | Select-Object Id, DisplayName, MembershipRule
Get-MgGroupMember -GroupId '<GroupId>' -All | Select-Object Id, @{N='Name';E={$_.AdditionalProperties.displayName}}
```

**Step 3 — Check device readiness state**
Portal: Windows Autopatch > Devices > filter by device name, review "Readiness" and "Enrollment status" columns. (Graph beta endpoint `admin/windows/updates/updatableAssets` surfaces some of this but the readiness *reason* detail is currently portal-only.)

**Step 4 — Check ring assignment and current deployment status**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/admin/windows/updates/deployments" |
    Select-Object -ExpandProperty value | Select-Object id, state, content
```

**Step 5 — Check for release health known issues affecting your fleet**
Portal: Windows Autopatch > Release management > Release health. Cross-reference against reported symptoms before assuming a local/tenant-specific misconfiguration.

**Step 6 — Confirm no competing management authority**
```powershell
# On the device — confirm no legacy WSUS GPO conflict
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -ErrorAction SilentlyContinue

# Confirm co-management workload split (if ConfigMgr present)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\CCM\CoManagementFlags" -ErrorAction SilentlyContinue
```
*Good:* No legacy WSUS server value set; co-management flag for Windows Update workload = Intune/Autopatch (bit set).

---
## Troubleshooting Steps (by phase)

### Phase 1: Registration Failures

1. Confirm device object exists in Entra and is not a stale/duplicate device record (common after re-imaging without cleaning up the old device object).
2. Confirm dynamic group membership rule syntax is correct and the device matches (e.g., `device.deviceOwnership -eq "Company"` combined with an OU-based extension attribute).
3. Wait a full 24-hour cycle before treating "not yet registered" as a failure — Autopatch registration is not instantaneous.

### Phase 2: Readiness Failures

1. Work through the readiness checklist in order: license → join state → management state → OS build → conflicting policy.
2. For "Not ready — management": confirm device isn't purely ConfigMgr-managed with the Windows Update workload still on ConfigMgr's side of the co-management slider.
3. For "Not ready — OS build": Autopatch has a minimum supported build floor; devices too far behind must be manually updated once to cross the threshold before Autopatch can take over ongoing management.

### Phase 3: Ring Behavior Anomalies

1. If a specific ring is stuck: check Release health for an active auto-pause/safeguard hold before troubleshooting locally — this is frequently a Microsoft-side protective action, not a local misconfiguration.
2. If ring assignment looks wrong: audit for static group overrides that conflict with the dynamic membership rule — static (manual) assignment always wins over dynamic recalculation and can silently "stick" a device in a stale ring.
3. Confirm ring sizes are reasonably balanced (extremely small Test/First rings reduce the statistical value of the canary approach).

### Phase 4: Feature Update Safeguard Holds

1. Microsoft applies automatic **safeguard holds** to block known incompatible device/driver/app combinations from receiving a feature update — this is separate from Autopatch's own ring logic and applies at the Windows Update service level.
2. Check `Windows Autopatch > Devices > [device] > Feature update status` for a specific hold ID/reason.
3. These holds lift automatically once Microsoft resolves the compatibility issue — do not attempt to force a feature update install to bypass a safeguard hold in production; it exists to prevent a real incompatibility.

### Phase 5: Microsoft 365 Apps Update Conflicts

1. Confirm no legacy Group Policy or registry-based Office update configuration exists on the device that would take precedence over the Autopatch-managed Click-to-Run policy.
2. Confirm the update channel configured in Autopatch's M365 Apps policy matches organizational expectation (Monthly Enterprise Channel is the Autopatch default).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Bulk register devices via CSV</summary>

Portal-driven (no direct Graph write endpoint for bulk CSV registration as of writing):
1. Windows Autopatch > Devices > Add devices.
2. Upload CSV with columns: `Serial number`, `Manufacturer`, `Model` (or use Entra group-based registration instead — preferred for ongoing scale).

Preferred ongoing approach — dynamic group membership rule example:
```
(device.deviceOwnership -eq "Company") and (device.deviceManagementAppId -eq "0000000a-0000-0000-c000-000000000000")
```
Add all Intune-managed corporate devices matching your criteria to the Autopatch registration group automatically.

**Rollback:** Remove the device(s) from the registration group; they revert to whatever WU/WUfB policy was in effect prior (typically none, if freshly deployed).

</details>

<details><summary>Playbook 2 — Manually pin a device to the Test ring (pilot/VIP device)</summary>

```powershell
Connect-MgGraph -Scopes "GroupMember.ReadWrite.All"

# Remove from whatever ring it's dynamically assigned to (if statically overriding)
Remove-MgGroupMemberByRef -GroupId '<CurrentRingGroupId>' -DirectoryObjectId '<DeviceObjectId>'

# Add to Test ring group directly
New-MgGroupMember -GroupId '<TestRingGroupId>' -DirectoryObjectId '<DeviceObjectId>'
```

Use for: IT pilot devices, or devices belonging to power users who want (and can tolerate) earliest exposure to updates for early signal.

**Rollback:** Reverse the membership change to return the device to dynamic ring assignment.

</details>

<details><summary>Playbook 3 — Investigate and respond to a ring-wide auto-pause</summary>

1. Confirm the pause via Release health dashboard — note the specific KB/update and reported issue.
2. Do **not** manually force the update past the pause — Autopatch paused it because Microsoft's own telemetry (or yours) flagged an elevated incident rate.
3. Monitor Release health for the resolution/unblock notice; Autopatch will resume rollout automatically once Microsoft publishes a fix or the hold is lifted.
4. If local incident volume doesn't match the reported issue (i.e., you believe the pause doesn't apply to your fleet), open a support case referencing the specific release health item ID — do not attempt to override via local GPO, as this creates exactly the conflicting-policy state Autopatch is designed to prevent.

</details>

<details><summary>Playbook 4 — Switch co-management workload to Autopatch (from ConfigMgr)</summary>

In ConfigMgr console (not Graph): **Administration > Client Settings > Default Client Settings > Co-management** — set "Windows Update policies" workload slider to "Intune" (or "Pilot Intune" for a staged rollout of the workload switch itself).

Validate the switch took effect on a test device:
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\CCM\CoManagementFlags" -ErrorAction SilentlyContinue
```

**Rollback:** Slide the workload back to ConfigMgr — but note the device will then be ineligible for Autopatch management until switched back.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collect Windows Autopatch evidence for a device, for escalation
.DESCRIPTION Gathers Entra join state, Intune enrollment, WU service health, and local
             policy state relevant to Autopatch troubleshooting. Portal-only readiness/ring
             detail must be captured manually as a screenshot alongside this output.
.PARAMETER   DeviceName   Local device hostname
.EXAMPLE     .\Collect-AutopatchEvidence.ps1 -DeviceName "CONTOSO-LT-042"
#>
param(
    [Parameter(Mandatory)][string]$DeviceName
)

Write-Host "`n=== DEVICE JOIN STATE ===" -ForegroundColor Cyan
dsregcmd /status | Select-String "AzureAdJoined","DomainJoined","TenantId","DeviceId"

Write-Host "`n=== WINDOWS UPDATE SERVICES ===" -ForegroundColor Cyan
Get-Service -Name "wuauserv","UsoSvc","DoSvc","BITS" | Select-Object Name, Status, StartType | Format-Table

Write-Host "`n=== CO-MANAGEMENT FLAGS (if ConfigMgr present) ===" -ForegroundColor Cyan
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\CCM\CoManagementFlags" -ErrorAction SilentlyContinue

Write-Host "`n=== LOCAL WU POLICY (should reflect Autopatch-managed values) ===" -ForegroundColor Cyan
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" -ErrorAction SilentlyContinue |
    Select-Object DeferQualityUpdatesPeriodInDays, DeferFeatureUpdatesPeriodInDays, ActiveHoursStart, ActiveHoursEnd

Write-Host "`n=== LEGACY WSUS GPO CHECK (should be absent) ===" -ForegroundColor Cyan
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -ErrorAction SilentlyContinue

Write-Host "`n=== RECENT WU EVENT LOG ===" -ForegroundColor Cyan
Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 20 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap

Write-Host "`nNOTE: Also capture manually from Intune admin center:" -ForegroundColor Yellow
Write-Host "  - Windows Autopatch > Devices > [this device] > Readiness + Ring assignment"
Write-Host "  - Windows Autopatch > Release management > Release health (for active pauses)"
```

---
## Command Cheat Sheet

```powershell
# Connect for Autopatch/Update Graph queries
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","Group.Read.All","Device.Read.All"

# List updatable assets (Autopatch-managed devices) — beta endpoint
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/admin/windows/updates/updatableAssets"

# List active deployments
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/admin/windows/updates/deployments"

# Check device join state
dsregcmd /status

# Check WU services
Get-Service wuauserv, UsoSvc, DoSvc

# Force a Windows Update scan
UsoClient StartScan

# Check co-management workload flags
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\CCM\CoManagementFlags"

# Check local WUfB CSP-applied policy
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update"

# Pull recent WU client event log
Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 30

# Manage Entra group membership for ring assignment
Get-MgGroupMember -GroupId '<RingGroupId>'
New-MgGroupMember -GroupId '<RingGroupId>' -DirectoryObjectId '<DeviceObjectId>'
Remove-MgGroupMemberByRef -GroupId '<RingGroupId>' -DirectoryObjectId '<DeviceObjectId>'
```

---
## 🎓 Learning Pointers

- **Autopatch's real value is the circuit breaker, not the ring model itself** — plain WUfB deployment rings existed before Autopatch. What Autopatch adds is Microsoft correlating its own update-health telemetry with your rollout and automatically pausing before a bad update reaches your whole fleet.
- **Readiness is evaluated continuously, not once at enrollment** — treat "ready" as a current state, not a permanent certification. Something as simple as a license removal or a co-management workload slider flip can silently drop a device out of Autopatch management.
- **Safeguard holds are a Windows Update platform feature, not Autopatch-specific** — they exist independently to block known-bad device/update combinations. Never try to force past one in production; it's protecting you from a real, Microsoft-confirmed incompatibility.
- **Static group membership always beats dynamic recalculation** — if you ever manually add a device to a ring group for a one-off reason, remember to remove it later, or it will never rejoin the dynamic rotation logic.
- **Co-management conflicts are the most common "silent" Autopatch failure** — a device can appear enrolled and ready in Intune while ConfigMgr is still quietly issuing its own WU policy. Always confirm the workload slider explicitly rather than assuming Intune enrollment implies Intune is in control of updates.
- **MS Docs:** [Windows Autopatch documentation](https://learn.microsoft.com/en-us/windows/deployment/windows-autopatch/) | [Prerequisites](https://learn.microsoft.com/en-us/windows/deployment/windows-autopatch/prepare/windows-autopatch-prerequisites) | [Safeguard holds](https://learn.microsoft.com/en-us/windows/deployment/update/safeguard-holds) | [Co-management workloads](https://learn.microsoft.com/en-us/mem/configmgr/comanage/workloads)
