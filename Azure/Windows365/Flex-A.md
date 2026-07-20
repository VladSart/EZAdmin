# Windows 365 Flex (formerly Frontline) — Reference Runbook (Mode A: Deep Dive)
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
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This runbook covers **Windows 365 Flex** — the pooled-license Cloud PC product formerly named **Windows 365 Frontline**, renamed by Microsoft on **May 8, 2026** (see How It Works for why this matters operationally, not just cosmetically). It covers both of Flex's deployment modes:
- **Dedicated mode** — up to 3 Cloud PCs per license, each pinned to one user, 1 concurrent session per license, with a concurrency buffer for short overlap
- **Shared mode** — 1 Cloud PC per license shared non-concurrently across a group, no persistence, no concurrency buffer, with optional Cloud Apps (published-app) delivery

This runbook assumes familiarity with `Azure/Windows365/Windows365-A.md` (the Enterprise/Business runbook) — Flex shares the same underlying provisioning pipeline, Intune-mandatory enrollment model, and AVD-based connection broker described there. This file covers **only what is different or Flex-specific**: the pooled licensing model, the two deployment modes, concurrency mechanics, and the rename itself as an operational gotcha.

**Assumes:**
- Microsoft Graph PowerShell SDK (beta module): `Install-Module Microsoft.Graph.Beta -Scope CurrentUser`
- Authenticated with `Connect-MgGraph` and `CloudPC.ReadWrite.All`, `DeviceManagementConfiguration.Read.All` scopes
- Tenant has Windows 365 Flex licenses purchased and at least one provisioning policy configured

**Not covered:** Windows 365 Enterprise/Business provisioning pipeline, domain join models, and ANC (see `Windows365-A.md`); Windows 365 Cloud Apps (published-application delivery inside Shared mode) beyond a brief mention — see `CloudApps-A.md`/`CloudApps-B.md` for the full app discovery/publish lifecycle, since it introduces no separate licensing/concurrency model of its own; Windows 365 Government/GCC network requirements.

---
## How It Works

<details><summary>Full architecture</summary>

### The rename: same product, new name, UI lag

On May 8, 2026, Microsoft renamed **Windows 365 Frontline** to **Windows 365 Flex**. Per Microsoft's own documentation: *"The product name in the Microsoft Intune admin center is being updated and may still appear as Frontline in some places."* Confirmed still-lagging UI element as of this writing: the **Devices > All devices** list still exposes a **Frontline Type** column (not renamed) to distinguish Shared vs. Dedicated Cloud PCs. Licensing, features, and pricing are unchanged — existing Frontline licenses continue to work as Flex licenses with no migration action required. Any documentation, screenshot, blog post, or ticket history referencing "Frontline" from before mid-2026 describes the **same product** as "Flex" — do not treat these as two different things when triaging a ticket or reading an old runbook.

The reason for the rename is scope, not mechanics: the original "Frontline" name implied shift/frontline workers only, but the product now targets any worker who doesn't need a dedicated 24/7 Cloud PC — part-time staff, contingent workers, users spanning time zones, and short-task customer-facing staff.

### Pooled licensing — the core departure from Enterprise/Business

Unlike Windows 365 Enterprise/Business (one license = one Cloud PC = one user, described in `Windows365-A.md`), **Windows 365 Flex licenses are pooled at the tenant level and are not assigned directly to individual users.** The Microsoft 365 admin center shows Flex licenses as assigned to zero users — this is expected, not a licensing error. License consumption is only visible through the Windows 365 utilization report or Graph, not the standard license-assignment UI a technician might habitually check first.

### Dedicated mode

- A single Flex license lets you provision **up to 3 Cloud PCs**, each pinned to a single user via Entra ID group membership, but only **1 concurrent session per license** across those 3.
- Designed for workers on rotation, spanning time zones, part-time, or contingent — i.e., users who need a *personal, persistent* Cloud PC but not 24/7 concurrent access.
- **Power behavior differs fundamentally from Enterprise/Business**: a Dedicated-mode Flex Cloud PC **automatically powers off** after the user signs off, and powers back on when the user next connects — adding startup latency to that reconnect that does not apply to Enterprise/Business Cloud PCs (which stay running). After sign-off, the Cloud PC stays powered on for a 2-hour grace window; reconnecting inside that window behaves like a normal Enterprise Cloud PC connection.
- **Intelligent prestart**: once a user has connected on 3+ of the past 30 days, the system learns their typical connect time and prestarts the Cloud PC ~30 minutes ahead, holding it powered on for 2 hours. A prestarted Cloud PC does not consume a concurrent-session license slot until the user's connection actually completes — only an actual connection consumes the slot.
- **Concurrency buffer**: the tenant can temporarily exceed the licensed concurrency ceiling — designed for shift-change overlap where an outgoing and incoming worker are both briefly connected. Buffer use is capped at **4 times per day, max 1 hour per use**, timed from the moment the ceiling was exceeded. GPU-enabled Cloud PCs are excluded from the buffer entirely.
  - **Temporary block**: triggered when the buffer is used beyond 1 hour on 4+ occasions within a 24-hour window → blocks further buffer use for the next 48 hours (base concurrency ceiling still usable).
  - **Permanent block**: triggered by 2+ temporary blocks within a 7-day period → requires an Intune-portal support ticket to lift.
- When both Dedicated- and Shared-mode provisioning policies exist and new licenses are added, **Dedicated-mode Cloud PCs are provisioned first**.

### Shared mode

- A single Flex license provisions **1 Cloud PC** shared non-concurrently by an entire assigned Entra ID group — 10 licenses assigned to a group means up to 10 concurrent Cloud PC sessions across however many users are in that group.
- **No persistence by default**: when a user signs out, their profile is deleted and the Cloud PC is released for the next user in the group. If **User Experience Sync (UES)** is enabled, user-specific app data and Windows settings are stored in the cloud and reapplied on next sign-in, but the local Cloud PC state itself is still wiped.
- **No concurrency buffer** — pool exhaustion in Shared mode is a hard stop, not a temporary excess. "No Cloud PC available" is the expected, correct behavior of a fully-utilized pool, not a bug.
- Supports **Cloud Apps**: instead of streaming a full Cloud PC desktop, Shared mode can publish individual applications to users. Defined by a validated policy property pairing (`userExperienceType=cloudApp` + `provisioningType=sharedByEntraGroup`) with its own app discovery/publish lifecycle — see `CloudApps-A.md`/`CloudApps-B.md` for full coverage; out of deep scope in this file beyond this mention.
- Shared mode is currently **only available in Azure Global Cloud** — not GCC/GCC High/DoD/sovereign clouds.

### Feature gaps vs. Enterprise/Business

As of this writing, Windows 365 Flex does **not** support:
- **Resize** as a remote action (the Resize workflow described in `Windows365-A.md`/`Windows365-B.md` Fix 5 does not apply to Flex Cloud PCs — right-sizing a Flex user means moving them to a different provisioning policy/license tier, not resizing in place)
- **Cross-region disaster recovery**

### Purview Customer Key

Microsoft Purview Customer Key is supported for Flex Cloud PCs in both Dedicated and Shared modes — newly provisioned Cloud PCs are encrypted using Customer Key once enabled in Purview, same as Enterprise/Business.

</details>

---
## Dependency Stack

```
Windows 365 Flex License Pool (tenant-level, pooled — NOT assigned per-user in M365 admin center)
  └── License requirements per active user session:
        ├── Windows 11/10 Enterprise
        ├── Microsoft Intune
        └── Microsoft Entra ID P1
              (all three bundled in M365 E3/E5/F3/A3/A5/Business Premium — Flex itself
               is a separate product, NOT governed by M365 F1/F3 eligibility conditions)
  └── Provisioning Policy — Mode selection (mutually exclusive per policy)
        ├── Dedicated mode
        │     ├── Entra ID group assignment (each Cloud PC pinned to 1 user)
        │     ├── Up to 3 Cloud PCs/license, 1 concurrent session/license
        │     ├── Concurrency buffer (4x/day, 1hr max, excludes GPU-enabled)
        │     │     └── Temporary block (48h) after 4x >1hr in 24h → Permanent block after 2x in 7 days
        │     ├── Auto power-off after sign-off (2hr reconnect grace window)
        │     └── Intelligent prestart (requires 3+ connects in trailing 30 days)
        └── Shared mode
              ├── Entra ID group assignment (any member may use any available pool Cloud PC)
              ├── 1 Cloud PC/license, 1 concurrent session/license, NO concurrency buffer
              ├── Profile create-on-signin / delete-on-signout (unless UES enabled)
              ├── Optional: Cloud Apps (published-app delivery, not full desktop — see CloudApps-A.md)
              └── Azure Global Cloud only (no GCC/sovereign cloud support)
  └── Same underlying platform as Windows 365 Enterprise/Business below this point:
        ├── Cloud PC VM (Microsoft-managed subscription)
        ├── Windows 365 agent
        ├── Intune enrollment (mandatory — see Windows365-A.md)
        └── AVD connection broker registration
              └── User's local client (Windows App / web / RDP)
                    └── Conditional Access evaluation
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "No Cloud PC available" — Shared mode | Pool fully utilized (no concurrency buffer exists in Shared mode) — this is correct behavior, not a bug | Active session count vs. licenses assigned to the group |
| "No Cloud PC available" — Dedicated mode, despite concurrency buffer | Buffer temporarily or permanently blocked from excessive use | Buffer usage history via Windows 365 Flex connection hourly report |
| User connects but experiences a long delay (Dedicated mode) | Cloud PC was powered off (normal between-session state) and is cold-starting | Power state property on the device; check if intelligent prestart pattern was established |
| Prestart doesn't seem to be working for a regular user | User hasn't connected on 3+ of the trailing 30 days, or connects at inconsistent times | Sign-in history / connection pattern for that user |
| "Resize" option missing or fails for a Flex Cloud PC | Resize is a not-yet-supported feature for Flex | Confirm Cloud PC's ProvisioningType is Frontline/Flex-flavored, not Enterprise |
| Config drift across a Shared-mode pool (some Cloud PCs behave differently) | Individual Cloud PCs updated/patched at different times without a periodic reprovision | Bulk reprovision schedule status on the provisioning policy |
| Ticket references "Frontline" but nothing named that exists in the portal anymore | Pre-May-2026 terminology — same product, renamed to Flex; UI may still show "Frontline Type" column | Cross-reference old ticket against current Flex documentation, not a separate product |
| User in a Shared-mode group loses all data every session, complains of "lost work" | Expected behavior — Shared mode has no persistence unless UES is explicitly enabled | Confirm UES (User Experience Sync) configuration on the policy |
| PowerShell script using `provisioningType eq 'shared'` stops matching new policies | `shared` is a deprecated enum value (retires April 30, 2027) — new policies increasingly use `sharedByUser`/`sharedByEntraGroup` | Update filter logic to include all shared-flavored enum values |
| Dedicated-mode user's Cloud PC assigned to someone else / disappeared | User removed from Entra ID group backing the Dedicated policy, or license pool exhausted so their 1-of-3 Cloud PC didn't provision | Group membership; license pool utilization vs. group size |
| Shared-mode group member can't get a GPU-accelerated session during a burst | Concurrency buffer explicitly excludes GPU-enabled Cloud PCs, and Shared mode has no buffer at all | Confirm whether GPU size + Shared/Dedicated mode combination is even a supported scenario |
| Bulk reprovision doesn't seem to run | Cloud PCs don't reprovision while users are signed in — this is by design, not a failure | Reprovision status per Cloud PC; whether "keep % available" setting is stalling behind active sessions |
| "Keep % available" during bulk reprovision doesn't match expectation | Percentage rounds DOWN to nearest whole Cloud PC (e.g., 27% of 150 = 40, not 40.5→41) | Recompute expected available count manually before escalating as a bug |
| User in a region outside Azure Global Cloud can't get a Shared-mode Cloud PC | Shared mode is Global-Cloud-only as of this writing | Confirm tenant's cloud environment and target Azure region |
| Ticket claims "Frontline dedicated" Cloud PC behaves like old 1:1-only Frontline (no shift overlap) | Confusing legacy Frontline dedicated (pre-rename, may have had different mechanics) with current Flex Dedicated mode's up-to-3-Cloud-PCs-per-license + concurrency buffer model | Confirm current mode configuration and buffer availability rather than assuming legacy behavior |

---
## Validation Steps

**1. Confirm Graph connection and required scopes**
```powershell
Connect-MgGraph -Scopes "CloudPC.ReadWrite.All","DeviceManagementConfiguration.Read.All","DeviceManagementManagedDevices.Read.All"
Get-MgContext | Select-Object Scopes
```
Expected: All three scopes present.

**2. Identify which provisioning policies are Flex (Dedicated/Shared) vs. Enterprise**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy |
    Select-Object DisplayName, Id, ProvisioningType, CloudPcNamingTemplate |
    Format-Table -AutoSize
```
Expected: `ProvisioningType` of `dedicated` covers both Enterprise policies and Flex Dedicated-mode policies — disambiguate by checking whether the policy's assigned license SKU is a Flex SKU (see Command Cheat Sheet). `shared`/`sharedByUser`/`sharedByEntraGroup` values are Flex Shared-mode only.

**3. List available Flex service plan sizes**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointFrontLineServicePlan |
    Select-Object DisplayName, Id, RamInGB, StorageInGB, VCpuCount
```
Expected: A list of Flex-eligible service plan sizes distinct from Enterprise/Business SKUs.

**4. Enumerate Cloud PCs and distinguish Flex mode**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Select-Object DisplayName, UserPrincipalName, Status, ProvisioningType, ServicePlanName |
    Sort-Object ProvisioningType | Format-Table -AutoSize
```
Expected: `ProvisioningType` on the Cloud PC object itself reports human-readable values distinguishing Enterprise from Frontline/Flex Dedicated and Shared — this is a **different property surface** than the enum on the provisioning policy object checked in step 2; do not conflate the two.

**5. Confirm Shared-mode pool utilization for a specific group**
```powershell
$policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<shared-policy-name>'"
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId $policy.Id
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId -eq $policy.Id } |
    Group-Object Status | Select-Object Name, Count
```
Expected: Active/in-use count should not persistently sit at the total licensed pool size — if it does, the pool is undersized for demand.

**6. Confirm a user's license requirements are all present (not just the Flex pool)**
```powershell
Get-MgUserLicenseDetail -UserId "<user@domain.com>" |
    Select-Object SkuPartNumber, ServicePlans
```
Expected: Windows Enterprise, Intune, and Entra ID P1 service plans present — either standalone or bundled via M365 E3/E5/F3/A3/A5/Business Premium. Flex's pooled license alone does not satisfy these three prerequisites.

**7. Confirm Cloud PC is enrolled in Intune (same requirement as Enterprise/Business)**
```powershell
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" |
    Where-Object { $_.Model -like "*Cloud PC*" } |
    Select-Object DeviceName, ComplianceState, LastSyncDateTime
```
Expected: Compliant, recent sync — Flex Cloud PCs are Intune-mandatory identically to Enterprise/Business.

---
## Troubleshooting Steps (by phase)

### Phase 1: Licensing & Mode Confirmation

1. Confirm the user (or their Entra ID group) is genuinely licensed via the Flex pool, not confused with an Enterprise/Business assignment — remember Flex licenses show as assigned to zero users in the M365 admin center by design
2. Confirm which mode (Dedicated vs. Shared) the relevant provisioning policy uses — this determines every downstream troubleshooting path
3. Confirm all three prerequisite licenses (Windows Enterprise, Intune, Entra ID P1) are present for the affected user independently of the Flex pool license

### Phase 2: Availability / Concurrency

1. **Shared mode**: check whether the pool is simply exhausted (expected behavior, no buffer) — the fix is adding licenses or splitting users across more policies, not troubleshooting a "failure"
2. **Dedicated mode**: check concurrency buffer usage history — a temporary or permanent block explains "no Cloud PC available" even when licenses exist
3. Confirm the affected Entra ID group's membership size doesn't exceed what the assigned license count can realistically support at expected peak concurrency

### Phase 3: Connection & Power State (Dedicated mode)

1. Confirm the Cloud PC's power state — "slow to connect" complaints against Dedicated-mode Flex Cloud PCs are frequently just cold-start latency from the auto-power-off behavior, not a fault
2. Check whether the user has an established connection pattern (3+ of trailing 30 days) for intelligent prestart to have kicked in
3. If prestart should be active but isn't reducing latency, confirm the user's actual connect times are consistent day-to-day — irregular schedules defeat the prediction model

### Phase 4: Configuration Consistency (Shared mode)

1. If users report inconsistent app/config experience across sessions in a shared pool, check whether a periodic bulk reprovision schedule exists on the policy
2. If reprovisioning appears stuck, confirm it isn't simply waiting on currently-signed-in users to sign out (reprovision does not force-disconnect by default)
3. If forced reprovisioning is required, use 0% "keep available" plus a Restart remote action per Cloud PC to force disconnection — communicate this to affected users first, this is destructive to any in-progress work

### Phase 5: Feature-Gap Misdiagnosis

1. If a user or technician reports "Resize doesn't work," confirm the target Cloud PC is Flex, not Enterprise/Business, before treating it as a bug — Resize is a documented not-yet-supported feature for Flex
2. If cross-region failover is expected, confirm the same way — not yet supported for Flex

---
## Remediation Playbooks

<details><summary>Playbook 1 — Right-Size a Dedicated-Mode Flex Deployment After Recurring Concurrency Buffer Blocks</summary>

Use when: A Dedicated-mode group is repeatedly triggering (and eventually exhausting) the concurrency buffer — a sign the license count is undersized for actual peak concurrent usage, not a one-off shift-overlap event.

```powershell
# Step 1: Pull the group's Cloud PC count and current license allocation
$policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<dedicated-policy-name>'"
$cloudPcs = Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All | Where-Object { $_.ProvisioningPolicyId -eq $policy.Id }
$cloudPcs | Group-Object Status | Select-Object Name, Count

# Step 2: Cross-reference against the Windows 365 Flex connection hourly report (portal-only,
# no direct Graph endpoint as of this writing) to confirm sustained peak-concurrency overshoot
# rather than a single anomalous day

# Step 3: If overshoot is sustained, purchase additional Flex licenses and assign to the
# backing Entra ID group rather than continuing to rely on the buffer — the buffer is
# designed for rare/brief overlap, not as ongoing headroom

# Step 4: Confirm the additional licenses are consumed by the pool
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId $policy.Id
```

**Rollback:** N/A — this is a capacity-planning correction, not a destructive change. Removing added licenses later simply reduces the pool back toward the prior undersized state.

</details>

<details><summary>Playbook 2 — Bulk Reprovision a Shared-Mode Pool to Clear Configuration Drift</summary>

Use when: Multiple Shared-mode Cloud PCs in the same pool show inconsistent app versions, settings, or behavior after incremental updates/patches were applied unevenly over time.

```powershell
# There is no direct Graph cmdlet for the bulk-reprovision-with-percentage-available action as
# of this writing — this remains an Intune admin center-only workflow:
# Devices > Provision Cloud PCs > Provisioning policies > select the Shared-mode policy >
# Reprovision > set "Keep a percentage of devices available" > confirm

# Percentage rounds DOWN to the nearest whole Cloud PC (e.g., 27% of 150 = 40, not 41)
# Cloud PCs do not reprovision while a user is actively signed in

# To force full reprovisioning immediately (skips graceful wait for sign-outs):
# 1. Start the bulk reprovision at 0% "keep available"
# 2. For any Cloud PC still showing a signed-in user, issue a Restart remote action:
$stuckCloudPcs = Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId -eq $policy.Id -and $_.Status -eq "provisioned" }
foreach ($cpc in $stuckCloudPcs) {
    Invoke-MgBetaDeviceManagementVirtualEndpointCloudPcRestart -CloudPcId $cpc.Id
}

# 3. Consider scheduling a recurring bulk reprovision (Weekly/Monthly) on the policy going
# forward instead of relying on ad hoc manual reprovisioning to prevent drift recurring
```

**Rollback:** None — reprovisioning wipes all local Cloud PC data by design in Shared mode (data is already non-persistent). Communicate the maintenance window to affected users before forcing disconnection via Restart.

</details>

<details><summary>Playbook 3 — Migrate a Deprecated `provisioningType eq 'shared'` Filter/Script to `sharedByUser`</summary>

Use when: An existing automation script, scheduled report, or Graph query filters on `provisioningType eq 'shared'` and is expected to keep working past the deprecation date (April 30, 2027) or is already missing newly-created Shared-mode policies that use the newer enum value.

```powershell
# Old (deprecated, still functional until April 30, 2027):
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "provisioningType eq 'shared'"

# New — cover all current shared-flavored values explicitly rather than a single literal:
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -All |
    Where-Object { $_.ProvisioningType -in @('shared','sharedByUser','sharedByEntraGroup') }

# Update any downstream automation/report logic to use the -in comparison above instead of
# a single -Filter literal, since new tenant configuration may adopt sharedByUser or
# sharedByEntraGroup ahead of the 2027 removal date
```

**Rollback:** N/A — this is a forward-compatibility fix to reporting/automation logic, not a change to any Cloud PC or policy itself.

</details>

<details><summary>Playbook 4 — Greenfield Flex Deployment Decision (Dedicated vs. Shared vs. Enterprise)</summary>

Use when: A client is evaluating Windows 365 for a new worker population and it's unclear which product/mode fits.

```
Decision guide (walk in order):

1. Does the worker need 24/7 dedicated access with full persistence and no automatic
   power-off? → Windows 365 Enterprise/Business (see Windows365-A.md)

2. Does the worker need a *personal, persistent* Cloud PC, but only during scheduled shifts
   or part-time hours, and can tolerate a brief cold-start on reconnect?
   → Windows 365 Flex, Dedicated mode

3. Does the worker need short, task-specific access with no requirement to retain local
   state between sessions, potentially shared across many different individuals?
   → Windows 365 Flex, Shared mode (consider Cloud Apps — see `CloudApps-A.md` — if only
     specific applications, not a full desktop, are needed)

4. Does the workload need GPU acceleration under Dedicated mode concurrency-buffer
   coverage? → Not supported — GPU-enabled Cloud PCs are excluded from the buffer
   entirely regardless of mode; plan license headroom accordingly, don't rely on the buffer

5. Is the tenant in GCC/GCC High/DoD or another sovereign cloud?
   → Flex Shared mode is Azure Global Cloud only as of this writing; confirm current
     region support before committing a sovereign-cloud client to this design
```

**Rollback:** N/A — planning playbook, not an operational change.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Windows 365 Flex diagnostic evidence for a specific user or provisioning policy
.NOTES     Requires Microsoft.Graph.Beta module and CloudPC.Read.All scope
#>

param(
    [string]$UserPrincipalName,
    [string]$ProvisioningPolicyName
)

$outputPath = "C:\W365Flex_Diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

if ($ProvisioningPolicyName) {
    $policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '$ProvisioningPolicyName'"
    $policy | ConvertTo-Json -Depth 5 | Out-File "$outputPath\policy_detail.json"

    Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
        Where-Object { $_.ProvisioningPolicyId -eq $policy.Id } |
        Select-Object DisplayName, UserPrincipalName, Status, ProvisioningType |
        Export-Csv "$outputPath\pool_cloudpcs.csv" -NoTypeInformation
}

if ($UserPrincipalName) {
    Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "userPrincipalName eq '$UserPrincipalName'" |
        ConvertTo-Json -Depth 5 | Out-File "$outputPath\user_cloudpc_detail.json"

    Get-MgUserLicenseDetail -UserId $UserPrincipalName |
        Select-Object SkuPartNumber, ServicePlans | Export-Csv "$outputPath\license_detail.csv" -NoTypeInformation
}

Get-MgBetaDeviceManagementVirtualEndpointFrontLineServicePlan |
    Select-Object DisplayName, Id, RamInGB, StorageInGB, VCpuCount |
    Export-Csv "$outputPath\flex_service_plans.csv" -NoTypeInformation

Write-Host "NOTE: Concurrency buffer usage history and Shared-mode pool utilization trends are" -ForegroundColor Yellow
Write-Host "only available via the Windows 365 Flex connection hourly report in the Intune admin" -ForegroundColor Yellow
Write-Host "center as of this writing — no direct Graph endpoint exists. Pull that report manually" -ForegroundColor Yellow
Write-Host "and attach alongside this evidence pack." -ForegroundColor Yellow

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# List all provisioning policies with mode/type
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy | Select DisplayName,ProvisioningType

# List Flex-eligible service plan sizes
Get-MgBetaDeviceManagementVirtualEndpointFrontLineServicePlan | Select DisplayName,VCpuCount,RamInGB,StorageInGB

# List all Cloud PCs with per-object ProvisioningType (Enterprise/Frontline-Dedicated/Frontline-Shared)
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All | Select DisplayName,UserPrincipalName,Status,ProvisioningType

# Get a specific user's Flex Cloud PC(s) — up to 3 possible under Dedicated mode
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "userPrincipalName eq '<upn>'"

# Restart (non-destructive) — the correct way to force-disconnect a Shared-mode session
Invoke-MgBetaDeviceManagementVirtualEndpointCloudPcRestart -CloudPcId "<id>"

# Reprovision (destructive — wipes local state; expected/routine for Shared mode)
Invoke-MgBetaReprovisionDeviceManagementVirtualEndpointCloudPc -CloudPcId "<id>"

# Check a user's full license bundle (Flex pool alone is not sufficient — Windows Enterprise/Intune/Entra ID P1 also required)
Get-MgUserLicenseDetail -UserId "<upn>"

# Check managed device (Cloud PC as Intune endpoint) — identical requirement to Enterprise/Business
Get-MgDeviceManagementManagedDevice -Filter "userPrincipalName eq '<upn>'"

# Provisioning policy assignment (which Entra ID group backs a Dedicated/Shared policy)
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId "<policy-id>"

# Forward-compatible shared-mode filter (avoid the deprecated 'shared' literal alone)
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -All |
    Where-Object { $_.ProvisioningType -in @('shared','sharedByUser','sharedByEntraGroup') }

# NOT supported for Flex as of this writing — do not attempt, confirm mode first:
# Invoke-MgBetaResizeDeviceManagementVirtualEndpointCloudPc  (Resize)
```

---
## 🎓 Learning Pointers

- **A rename is not a migration — old tickets, old docs, and current UI can all disagree on the name at once**: Windows 365 Frontline became Windows 365 Flex on May 8, 2026 with zero functional change, but the Intune admin center's own "Frontline Type" column hasn't caught up yet. Treat "Frontline" and "Flex" as fully interchangeable when triaging, and don't waste time hunting for a "Frontline" product that no longer exists by that name in current documentation. Reference: [What is Windows 365 Flex?](https://learn.microsoft.com/en-us/windows-365/enterprise/introduction-windows-365-flex)
- **Pooled licensing breaks the habitual "check the user's assigned license" reflex**: Flex licenses show as assigned to zero users in the M365 admin center by design — a technician checking license assignment the way they would for Enterprise/Business will conclude (incorrectly) that the user has no license at all. Use the Windows 365 utilization report or Graph instead. Reference: [Windows 365 Flex licensing](https://learn.microsoft.com/en-us/windows-365/enterprise/windows-365-flex-license)
- **Dedicated mode's concurrency buffer is a safety valve, not extra capacity**: 4 uses/day, 1 hour each, with escalating temporary (48h) and permanent blocks for abuse — plan license counts for genuine sustained peak concurrency, don't treat the buffer as free headroom. Reference: [Concurrency buffer](https://learn.microsoft.com/en-us/windows-365/enterprise/concurrency-buffer)
- **Shared mode has zero slack by design**: no concurrency buffer exists in Shared mode at all — "no Cloud PC available" there is the pool working exactly as designed, not a fault. The fix is always more licenses or better group segmentation by peak usage window, never a technical troubleshooting step. Reference: [What is Windows 365 Flex?](https://learn.microsoft.com/en-us/windows-365/enterprise/introduction-windows-365-flex)
- **The `provisioningType` enum is mid-deprecation right now**: the `shared` value on provisioning policy objects is deprecated and stops returning after April 30, 2027, replaced by `sharedByUser` — any existing automation filtering on the literal `shared` string should be updated proactively rather than waiting for it to silently stop matching new policies.
- **Resize doesn't exist for Flex — don't apply Enterprise/Business muscle memory**: a technician trained on `Windows365-B.md` Fix 5 will instinctively reach for Resize when a Flex user needs more resources; that action is a documented not-yet-supported feature here, and the actual fix is moving the user to a differently-sized policy/license tier. Reference: [What is Windows 365 Flex?](https://learn.microsoft.com/en-us/windows-365/enterprise/introduction-windows-365-flex)
