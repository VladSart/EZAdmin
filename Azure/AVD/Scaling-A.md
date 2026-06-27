# Azure Virtual Desktop — Scaling Plans Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why autoscale works, when it breaks, and how to fix it.

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

- Applies to Azure Virtual Desktop (AVD) Scaling Plans (GA feature)
- Covers both Pooled and Personal host pool scaling behaviors
- Does **not** cover Azure Automation-based or Logic App-based legacy scaling scripts
- Requires: AVD host pool in Azure, session hosts joined (AD or Entra), Scaling Plan created and assigned
- Engineers need Contributor or Desktop Virtualization Power On Off Contributor role on host pool
- Time zone settings on the Scaling Plan affect when phases trigger — confirm tenant time zone

---

## How It Works

<details><summary>Full architecture — AVD Autoscale / Scaling Plans</summary>

AVD Scaling Plans are an **Azure-native autoscale feature** that manages session host power state (start/stop/deallocate) based on configurable schedules and load thresholds.

### Key Components

```
Azure Portal / ARM Template
  └── Scaling Plan Resource
        ├── Schedule(s): weekday/weekend phases
        ├── Host Pool Assignment (1 plan → multiple host pools)
        └── Exclusion tags (VMs tagged "exclude" are never touched)

                          │
                          ▼
              [AVD Autoscale Service]
               (Microsoft-managed, runs in Azure)
                          │
              Reads: AVD Control Plane metrics
              Acts on: Azure Compute API (Start/Deallocate VMs)
                          │
                          ▼
              [Session Host VMs in Host Pool]
               Running | Stopped (deallocated) | Drain mode
```

### Scaling Plan Phases (Pooled Host Pools)
Each day schedule has 4 phases:

| Phase | Trigger | Action |
|-------|---------|--------|
| **Ramp-Up** | Before peak starts | Pre-start VMs; set load balancing to Breadth-first |
| **Peak** | Business hours | Maintain min session hosts; BFS load balancing |
| **Ramp-Down** | After peak ends | Drain active hosts; wait for sessions to end; deallocate empty hosts |
| **Off-Peak** | Nights/weekends | Minimum hosts running; DF load balancing to consolidate sessions |

### Load Balancing Modes
- **Breadth-First (BFS)**: Spreads users across all available hosts. Maximises responsiveness. Used during Ramp-Up/Peak.
- **Depth-First (DFS)**: Fills one host to its session limit before using the next. Maximises consolidation for power savings. Used during Ramp-Down/Off-Peak.

### Capacity Thresholds
Each phase has:
- **Minimum hosts**: Always keep at least N hosts running
- **Capacity threshold %**: If session load exceeds this %, spin up another host
  - e.g., 60% threshold on 10 hosts with 10 sessions each = 6 sessions/host triggers scale-out

### Drain Mode During Ramp-Down
AVD Autoscale sets hosts to **Drain Mode** before stopping them:
1. Host marked as "Allow new sessions: No"
2. Service waits for existing sessions to disconnect/logoff
3. After `WaitTimeMinutes` (configurable), force-logoff remaining sessions
4. Deallocate the VM

### Personal Host Pools — Power Management
For Personal (assigned) pools, Scaling Plans provide:
- **Start VM on Connect**: VM powers on when user connects (requires role assignment)
- **Disconnect timeout**: VM deallocated after user disconnects for N minutes
- **Logoff timeout**: VM deallocated after user logs off

### Exclusion Tags
Any VM tagged with `VirtualDesktopScalingPlanExclusionTag: <any-value>` is **ignored by the scaling plan**. Use this for always-on hosts (training, jumphosts, etc.).

### Scaling Plan Diagnostic Logs
Scaling Plan operations are logged to:
- `Log Analytics Workspace` (if diagnostic settings configured on the Scaling Plan)
- `WVDAutoscaleEvaluationPooled` table
- Azure Activity Log (for VM start/deallocate operations)

</details>

---

## Dependency Stack

```
[Scaling Plan (Azure Resource)]
        │ Assigned to
        ▼
[AVD Host Pool]
        │ Contains
        ▼
[Session Host VMs]
  ├── Must have AVD Agent running
  ├── Must be reachable from AVD Control Plane
  └── Must allow Azure Compute API actions (Start/Deallocate)
        │
        ▼
[Azure Compute API]
  ├── Requires: Contributor or "Desktop Virtualization Power On Off Contributor" role
  │     on the VMs OR the resource group/subscription
  └── AVD Autoscale service principal needs this role
        │
        ▼
[AVD Autoscale Service (Microsoft-managed)]
  ├── Uses Azure managed identity to call Compute API
  ├── Reads session host metrics from AVD Control Plane
  └── Evaluates schedule phases based on Scaling Plan time zone

[Log Analytics Workspace (optional)]
  └── Scaling Plan diagnostics → WVDAutoscaleEvaluationPooled table
```

**Role requirement — common miss:**
The AVD Autoscale feature requires the service principal `Windows Virtual Desktop` (app ID: 9cdead84-a844-4324-93f2-b2e6bb768d07) to have the `Desktop Virtualization Power On Off Contributor` role on the **resource group** containing the session host VMs.

Without this role: VMs don't start/stop; scaling plan shows no errors; hosts just don't respond.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| VMs not starting during ramp-up | Missing RBAC role for AVD Autoscale SP | Check role assignments on VM resource group |
| VMs start but users can't connect | AVD Agent not running after cold start | Check agent health in AVD portal; check VM startup time |
| Scaling plan assigned but no action taken | Scaling plan not assigned to host pool | Verify host pool assignment in Scaling Plan blade |
| VMs stop during peak hours | Capacity threshold too high (e.g., 90%) | Lower threshold to give earlier scale-out trigger |
| Users force-logged off unexpectedly | Ramp-down wait time too short | Increase `WaitTimeMinutes` in ramp-down phase |
| Off-peak minimum too low, users can't connect | Min hosts = 0 and Start VM on Connect not enabled | Raise min hosts to 1, or enable Start VM on Connect |
| Wrong time zone, phases fire at wrong times | Scaling Plan time zone misconfigured | Check Scaling Plan > Properties > Time Zone |
| Tagged VM still being managed by scaling plan | Tag key typo or wrong tag format | Must be exact: `VirtualDesktopScalingPlanExclusionTag` |
| Diagnostics show no data | Diagnostic settings not configured | Add diagnostic setting on Scaling Plan → LA Workspace |
| Personal pool VM not starting on connect | Start VM on Connect not enabled or RBAC missing | Enable feature; check `Desktop Virtualization Power On Off Contributor` |

---

## Validation Steps

**Step 1 — Verify Scaling Plan is assigned to the host pool**
```powershell
# Install Az.DesktopVirtualization if needed
# Install-Module Az.DesktopVirtualization -Force

$rg = "<ResourceGroup>"
$hostPoolName = "<HostPoolName>"
$pool = Get-AzWvdHostPool -ResourceGroupName $rg -Name $hostPoolName
Write-Host "Scaling Plan assigned: $($pool.ScalingPlanLinkedConfig)"
```
Expected good: Shows scaling plan resource ID
Bad: Empty — Scaling Plan is not assigned

---

**Step 2 — Check RBAC role for AVD Autoscale**
```powershell
$rg = "<ResourceGroup>"
# App ID for AVD / Windows Virtual Desktop service principal
$avdAppId = "9cdead84-a844-4324-93f2-b2e6bb768d07"
$sp = Get-AzADServicePrincipal -ApplicationId $avdAppId

$roles = Get-AzRoleAssignment -ObjectId $sp.Id -ResourceGroupName $rg
$roles | Select-Object RoleDefinitionName, Scope | Format-Table -AutoSize
```
Expected good: `Desktop Virtualization Power On Off Contributor` on the RG
Bad: No role listed — VMs will not be powered on/off

---

**Step 3 — Check session host registration and health**
```powershell
$rg = "<ResourceGroup>"
$hostPoolName = "<HostPoolName>"
Get-AzWvdSessionHost -ResourceGroupName $rg -HostPoolName $hostPoolName |
    Select-Object Name, Status, UpdateState, AllowNewSession, VirtualMachineId |
    Format-Table -AutoSize
```
Expected good: `Status: Available`, `UpdateState: Succeeded`
Bad: `Status: Unavailable` or `Shutdown` — agent not running or VM deallocated

---

**Step 4 — Check Scaling Plan schedule and phases**
```powershell
$rg = "<ResourceGroup>"
$scalingPlanName = "<ScalingPlanName>"
$plan = Get-AzWvdScalingPlan -ResourceGroupName $rg -Name $scalingPlanName
$plan | Select-Object Name, TimeZone, HostPoolType | Format-List

$plan.Schedule | ForEach-Object {
    Write-Host "Schedule: $($_.Name)" -ForegroundColor Cyan
    Write-Host "  Days of Week: $($_.DaysOfWeek -join ', ')"
    Write-Host "  Ramp-Up: $($_.RampUpStartTime) | Min hosts: $($_.RampUpMinimumHostsPct)%"
    Write-Host "  Peak:    $($_.PeakStartTime) | Threshold: $($_.PeakLoadBalancingAlgorithm)"
    Write-Host "  Ramp-Dn: $($_.RampDownStartTime) | Wait: $($_.RampDownWaitTimeMinute) min"
    Write-Host "  Off-Pk:  $($_.OffPeakStartTime) | Min hosts: $($_.OffPeakMinimumHostsPct)%"
}
```

---

**Step 5 — Check diagnostic logs for scaling decisions**
```powershell
# Requires Log Analytics workspace with diagnostics configured
$workspaceId = "<LogAnalyticsWorkspaceId>"
$query = @"
WVDAutoscaleEvaluationPooled
| where TimeGenerated > ago(24h)
| project TimeGenerated, HostPoolName, ActiveSessionHosts, DesiredSessionHosts, 
          ScaleOutCount, ScaleInCount, Message
| order by TimeGenerated desc
| take 50
"@
Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $query |
    Select-Object -ExpandProperty Results | Format-Table -AutoSize
```

---

**Step 6 — Verify Start VM on Connect (Personal pools)**
```powershell
$rg = "<ResourceGroup>"
$hostPoolName = "<HostPoolName>"
$pool = Get-AzWvdHostPool -ResourceGroupName $rg -Name $hostPoolName
Write-Host "Start VM on Connect: $($pool.StartVMOnConnect)"
Write-Host "Host Pool Type: $($pool.HostPoolType)"
```
Expected: `StartVMOnConnect: True` for personal pools with power management

---

## Troubleshooting Steps (by phase)

### Phase 1 — VMs not starting (ramp-up / Start VM on Connect)

1. Confirm role assignment: Step 2 above. This is the most common root cause.
2. If role is correct, check the AVD Activity Log: Azure Portal → Host Pool resource → Activity Log → filter for `Start Virtual Machine`.
3. Check if a VM is tagged with the exclusion tag: `VirtualDesktopScalingPlanExclusionTag`.
4. Check if the VM's Azure Compute quota is exhausted (scale-out blocked).
5. Check if the VM has boot diagnostics errors preventing startup.

### Phase 2 — VMs start but scaling plan seems wrong (wrong hours)

1. Check the Scaling Plan time zone setting. If the plan says UTC but the team is in GMT+1, phases fire 1 hour early.
2. Check DST: Azure Scaling Plans respect DST for IANA time zones but not all Windows-style time zone names.
3. Compare phase start times against Azure Activity Log actual VM start events.

### Phase 3 — Users unexpectedly logged off

1. Check ramp-down `WaitTimeMinutes` — if set too low (e.g., 5 minutes), users in active sessions get force-logged off.
2. Check `RampDownForceLogOffUser: True` — if set, users are warned and then logged off after the wait time. Set to False to prevent forced logoffs (VMs drain but aren't stopped until users naturally disconnect).
3. Check if Off-Peak min hosts is 0 — scaling plan may be draining more aggressively than intended.

### Phase 4 — Diagnostics show no data

1. Open the Scaling Plan resource in Azure Portal.
2. Go to **Diagnostic settings** → verify a setting exists pointing to a LA workspace.
3. If no diagnostic setting: Create one with `WVDAutoscaleEvaluationPooled` and `AllMetrics` selected.
4. Allow 15-30 minutes for first data to appear after creation.

### Phase 5 — Personal pool power management not working

1. Verify host pool type is `Personal`, not `Pooled`.
2. Enable `Start VM on Connect`: Portal → Host Pool → Properties → check the setting.
3. Role check (same as pooled): `Desktop Virtualization Power On Off Contributor` on the VM resource group.
4. For direct assignment: check user is assigned to a specific session host (required for personal pools).

---

## Remediation Playbooks

<details><summary>Playbook 1 — Grant required RBAC role for AVD Autoscale</summary>

**When:** VMs not being started/stopped by scaling plan, role is missing

```powershell
$rg = "<ResourceGroupName>"
$subscriptionId = (Get-AzContext).Subscription.Id

# Get the AVD service principal
$avdSp = Get-AzADServicePrincipal -ApplicationId "9cdead84-a844-4324-93f2-b2e6bb768d07"

# Assign the role
New-AzRoleAssignment `
    -ObjectId $avdSp.Id `
    -RoleDefinitionName "Desktop Virtualization Power On Off Contributor" `
    -ResourceGroupName $rg

Write-Host "Role assigned. Allow 5-15 minutes for first scaling action." -ForegroundColor Green
```

**Rollback:**
```powershell
Remove-AzRoleAssignment `
    -ObjectId $avdSp.Id `
    -RoleDefinitionName "Desktop Virtualization Power On Off Contributor" `
    -ResourceGroupName $rg
```

</details>

<details><summary>Playbook 2 — Update ramp-down wait time to prevent forced logoffs</summary>

**When:** Users being force-logged off during ramp-down

```powershell
# Via Azure Portal: Scaling Plan > Schedules > edit ramp-down phase
# Increase "Wait time before signing out users" to 30-60 minutes
# Optionally disable "Force logoff users during ramp down"

# Via PowerShell (update existing schedule):
$rg = "<ResourceGroupName>"
$planName = "<ScalingPlanName>"

# Get current plan
$plan = Get-AzWvdScalingPlan -ResourceGroupName $rg -Name $planName

# Modify via Portal — PowerShell update of schedule requires full schedule rebuild
# Recommended: use Azure Portal for schedule edits
Write-Host "Edit schedule via portal: https://portal.azure.com/#resource/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$rg/providers/Microsoft.DesktopVirtualization/scalingPlans/$planName"
```

</details>

<details><summary>Playbook 3 — Tag a VM to exclude from scaling plan</summary>

**When:** A specific host should always be on (admin host, always-on pool, etc.)

```powershell
$rg = "<ResourceGroupName>"
$vmName = "<VMName>"

# Add exclusion tag
$vm = Get-AzVM -ResourceGroupName $rg -Name $vmName
$tags = $vm.Tags
$tags["VirtualDesktopScalingPlanExclusionTag"] = "ExcludeFromScaling"
Set-AzVM -VM $vm -Tags $tags

# Verify
$vm = Get-AzVM -ResourceGroupName $rg -Name $vmName
Write-Host "Tags: $($vm.Tags | ConvertTo-Json)"
```

**Rollback:** Remove the tag
```powershell
$vm = Get-AzVM -ResourceGroupName $rg -Name $vmName
$vm.Tags.Remove("VirtualDesktopScalingPlanExclusionTag")
Update-AzVM -VM $vm -ResourceGroupName $rg
```

</details>

<details><summary>Playbook 4 — Enable diagnostic logging for Scaling Plan</summary>

**When:** No data in WVDAutoscaleEvaluationPooled, can't audit scaling decisions

```powershell
$rg = "<ResourceGroupName>"
$planName = "<ScalingPlanName>"
$workspaceId = "<LogAnalyticsWorkspaceId>"

$plan = Get-AzWvdScalingPlan -ResourceGroupName $rg -Name $planName

# Enable diagnostics
Set-AzDiagnosticSetting `
    -ResourceId $plan.Id `
    -WorkspaceId $workspaceId `
    -Name "ScalingPlanDiagnostics" `
    -Enabled $true `
    -Category "Autoscale"

Write-Host "Diagnostics enabled. First data appears in 15-30 minutes." -ForegroundColor Green
```

</details>

---

## Evidence Pack

```powershell
# Run from Azure Cloud Shell or local PowerShell with Az module
# Requires: Az.DesktopVirtualization module
# Install-Module Az.DesktopVirtualization -Force

param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$HostPoolName,
    [string]$ScalingPlanName = "",
    [string]$OutputDir = "C:\Temp\AVD-Scaling-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')"
)

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
Write-Host "[*] Collecting AVD Scaling evidence to $OutputDir" -ForegroundColor Cyan

# 1. Host pool info
$pool = Get-AzWvdHostPool -ResourceGroupName $ResourceGroup -Name $HostPoolName
$pool | ConvertTo-Json -Depth 5 | Out-File "$OutputDir\hostpool.json"
Write-Host "[OK] Host pool config saved" -ForegroundColor Green

# 2. Session hosts and status
Get-AzWvdSessionHost -ResourceGroupName $ResourceGroup -HostPoolName $HostPoolName |
    Select-Object Name, Status, UpdateState, AllowNewSession, VirtualMachineId |
    Export-Csv "$OutputDir\session-hosts.csv" -NoTypeInformation
Write-Host "[OK] Session hosts saved" -ForegroundColor Green

# 3. Scaling plan (if provided)
if ($ScalingPlanName) {
    $plan = Get-AzWvdScalingPlan -ResourceGroupName $ResourceGroup -Name $ScalingPlanName
    $plan | ConvertTo-Json -Depth 10 | Out-File "$OutputDir\scaling-plan.json"
    Write-Host "[OK] Scaling plan config saved" -ForegroundColor Green
}

# 4. RBAC check for AVD Autoscale SP
$avdSp = Get-AzADServicePrincipal -ApplicationId "9cdead84-a844-4324-93f2-b2e6bb768d07"
$roles = Get-AzRoleAssignment -ObjectId $avdSp.Id -ResourceGroupName $ResourceGroup
$roles | Select-Object RoleDefinitionName, ObjectType, Scope |
    Export-Csv "$OutputDir\rbac-check.csv" -NoTypeInformation
Write-Host "[OK] RBAC roles saved" -ForegroundColor Green

# 5. Active sessions
Get-AzWvdUserSession -ResourceGroupName $ResourceGroup -HostPoolName $HostPoolName |
    Select-Object Name, UserPrincipalName, SessionState, CreateTime |
    Export-Csv "$OutputDir\active-sessions.csv" -NoTypeInformation

# 6. VM power states for all session hosts
Get-AzVM -ResourceGroupName $ResourceGroup -Status |
    Where-Object { $_.Tags.Keys -notcontains "VirtualDesktopScalingPlanExclusionTag" } |
    Select-Object Name, @{N="PowerState";E={$_.PowerState}}, @{N="Tags";E={$_.Tags | ConvertTo-Json}} |
    Export-Csv "$OutputDir\vm-power-states.csv" -NoTypeInformation
Write-Host "[OK] VM power states saved" -ForegroundColor Green

Write-Host "`nEvidence collected to: $OutputDir" -ForegroundColor Cyan
Get-ChildItem $OutputDir | Select-Object Name, Length | Format-Table -AutoSize
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| List host pools | `Get-AzWvdHostPool -ResourceGroupName <rg>` |
| Check session hosts | `Get-AzWvdSessionHost -ResourceGroupName <rg> -HostPoolName <pool>` |
| Get scaling plan | `Get-AzWvdScalingPlan -ResourceGroupName <rg> -Name <plan>` |
| Check active sessions | `Get-AzWvdUserSession -ResourceGroupName <rg> -HostPoolName <pool>` |
| Set drain mode on host | `Update-AzWvdSessionHost -ResourceGroupName <rg> -HostPoolName <pool> -Name <host> -AllowNewSession:$false` |
| Start a specific VM | `Start-AzVM -ResourceGroupName <rg> -Name <vmName>` |
| Stop (deallocate) a VM | `Stop-AzVM -ResourceGroupName <rg> -Name <vmName> -Force` |
| Check RBAC for AVD SP | `Get-AzRoleAssignment -ObjectId <avd-sp-oid> -ResourceGroupName <rg>` |
| Tag VM to exclude from scaling | `Update-AzTag -ResourceId <vmId> -Tag @{"VirtualDesktopScalingPlanExclusionTag"="exclude"} -Operation Merge` |
| Query autoscale logs | `Invoke-AzOperationalInsightsQuery -WorkspaceId <id> -Query "WVDAutoscaleEvaluationPooled | take 50"` |
| Get VM power state | `Get-AzVM -ResourceGroupName <rg> -Status | Select Name, PowerState` |
| Enable Start VM on Connect | Portal → Host Pool → Properties → Start VM on Connect |

---

## 🎓 Learning Pointers

- **The RBAC miss is always first**: The single most common reason AVD Scaling Plans don't work is that the `Windows Virtual Desktop` service principal lacks the `Desktop Virtualization Power On Off Contributor` role on the VM resource group. This is easy to miss because the Scaling Plan shows as "assigned" and no error surfaces — hosts just don't respond. Always check this first. See: [Autoscale prerequisites](https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-scaling-plan#prerequisites)

- **Drain mode protects users during scale-in**: Autoscale doesn't brutally kill VMs. It sets drain mode first, waits `WaitTimeMinutes`, optionally sends a warning message to connected users, then (if `ForceLogoff` is enabled) logs them off. Setting `ForceLogoff: False` means VMs drain naturally — safer for users but slower to reclaim capacity. Tune `WaitTimeMinutes` to match typical session duration. See: [Autoscale session host drain mode](https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-faq)

- **Capacity threshold % is of the running pool, not total**: If you have 10 hosts with 10 sessions max each and set threshold to 60%, autoscale starts a new host when 6 of 10 slots on any **running** host are used. This isn't total pool capacity — it's per-session-host load. Plan minimum hosts accordingly to avoid cold-start delays during unexpected load spikes. See: [Autoscale capacity thresholds](https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-scaling-plan)

- **Start VM on Connect complements (not replaces) scaling plans**: For personal host pools, Start VM on Connect handles day-to-day power-on when users connect, while the scaling plan handles nightly power-off via logoff/disconnect timeouts. Together they form a complete power lifecycle. Without scaling plan's off-peak rules, VMs stay on even after users disconnect. See: [Start VM on Connect](https://learn.microsoft.com/en-us/azure/virtual-desktop/start-virtual-machine-connect)

- **Exclusion tags are powerful but invisible**: A VM tagged `VirtualDesktopScalingPlanExclusionTag` is silently skipped — no log entry, no error. This creates confusion when "why isn't this host being managed?" investigations find the tag was added by a previous admin. Document any exclusions in your host naming convention or a dedicated Azure tag for tracking. See: [Scaling plan exclusion tags](https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-scaling-plan)

- **Diagnostic logs are essential for cost analysis**: `WVDAutoscaleEvaluationPooled` logs every scaling decision — how many hosts were desired, how many were active, and why a scale-out/in occurred. This is invaluable for right-sizing schedules and proving cost savings. Enable diagnostic settings on day 1 of the scaling plan deployment. See: [AVD diagnostics with Log Analytics](https://learn.microsoft.com/en-us/azure/virtual-desktop/diagnostics-log-analytics)
