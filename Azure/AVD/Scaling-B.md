# AVD Scaling Plans & Autoscale — Hotfix Runbook (Mode B: Ops)
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
# Connect to Azure (if not already)
Connect-AzAccount

# 1 — Check scaling plan assignment to host pool
$rg = "<ResourceGroupName>"
$hostPool = "<HostPoolName>"
Get-AzWvdScalingPlanHostPoolAssociation -ResourceGroupName $rg -HostPoolName $hostPool

# 2 — Check host pool session host states (are VMs running/available?)
Get-AzWvdSessionHost -ResourceGroupName $rg -HostPoolName $hostPool |
    Select-Object Name, Status, AllowNewSession, Sessions, AssignedUser

# 3 — Check scaling plan's managed identity / service principal permissions
$scalingPlan = "<ScalingPlanName>"
Get-AzWvdScalingPlan -ResourceGroupName $rg -Name $scalingPlan |
    Select-Object Name, FriendlyName, HostPoolType, ExclusionTag

# 4 — Check Azure Activity Log for scaling errors (last 24h)
$startTime = (Get-Date).AddHours(-24)
Get-AzActivityLog -ResourceGroupName $rg -StartTime $startTime |
    Where-Object {$_.OperationName.Value -like "*scaling*" -and $_.Status.Value -ne "Succeeded"} |
    Select-Object EventTimestamp, OperationName, Status, SubStatus | 
    Format-Table -AutoSize

# 5 — Check VM power states in the host pool
Get-AzVM -ResourceGroupName $rg -Status |
    Where-Object {$_.Name -like "*<hostpool-prefix>*"} |
    Select-Object Name, @{N="PowerState";E={$_.Statuses[1].DisplayStatus}}
```

**Interpretation:**
| Result | Action |
|--------|--------|
| No scaling plan assignment returned | Scaling plan not linked to host pool — go to Fix 1 |
| Session hosts show "Unavailable" | VM agent issue or health check failing — go to Fix 2 |
| Activity log shows authorization errors | Missing role assignment on host pool/VMs — go to Fix 3 |
| VMs stuck in "Stopping" or "Deallocating" | Azure resource lock or policy blocking — go to Fix 4 |
| All VMs deallocated, no ramp-up happening | Schedule not matching timezone or ramp settings — go to Fix 5 |
| Sessions accumulating on one host, others idle | Load balancing type mismatch — go to Fix 5 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Azure Subscription (active, no spending limits)
└── AVD Service Principal / Managed Identity
    └── Role: "Desktop Virtualization Power On Off Contributor" on host pool scope
        └── Scaling Plan created and enabled
            └── Scaling Plan assigned to Host Pool
                └── Host Pool has session hosts (VMs) registered
                    └── VMs can be started/stopped by Azure compute
                        └── AVD Agent running on each session host
                            └── No Azure Policy blocking VM power operations
                                └── No resource locks on VMs or RG
                                    └── Session host "Allow New Sessions" = True
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm scaling plan is assigned and enabled**
```powershell
$rg = "<ResourceGroupName>"
$scalingPlan = "<ScalingPlanName>"

$plan = Get-AzWvdScalingPlan -ResourceGroupName $rg -Name $scalingPlan
Write-Host "Plan: $($plan.Name)"
Write-Host "Enabled: $($plan.Exclusioncontains)" 
Write-Host "Timezone: $($plan.TimeZone)"
Write-Host "Host Pool Type: $($plan.HostPoolType)"

# List schedules
$plan.Schedule | ForEach-Object {
    Write-Host "Schedule: $($_.Name) | Ramp-up: $($_.RampUpStartTime) | Peak: $($_.PeakStartTime)"
}
```
Expected: Plan enabled, timezone correct, at least one schedule defined covering current time window.

**Step 2 — Check role assignment for AVD service principal**
```powershell
# The AVD scaling service uses: "Windows Virtual Desktop" enterprise app
# Required role: Desktop Virtualization Power On Off Contributor
$hostPoolId = (Get-AzWvdHostPool -ResourceGroupName $rg -Name "<HostPoolName>").Id

Get-AzRoleAssignment -Scope $hostPoolId |
    Where-Object {$_.RoleDefinitionName -like "*Desktop Virtualization*" -or $_.RoleDefinitionName -like "*Power On Off*"} |
    Select-Object RoleDefinitionName, PrincipalName, PrincipalType
```
Expected: "Desktop Virtualization Power On Off Contributor" assigned to the AVD service principal at the host pool scope.  
Bad: No matching role assignment — go to Fix 3.

**Step 3 — Check session host health**
```powershell
Get-AzWvdSessionHost -ResourceGroupName $rg -HostPoolName "<HostPoolName>" |
    Select-Object @{N="Host";E={$_.Name.Split("/")[-1]}}, Status, UpdateState, AllowNewSession, Sessions |
    Format-Table -AutoSize
```
Expected: Status = `Available`, `AllowNewSession` = True for VMs that should accept sessions.  
Bad: Status = `Unavailable` or `NeedsAssistance` — check AVD agent on those VMs.

**Step 4 — Check VM power state**
```powershell
$rg = "<ResourceGroupName>"
Get-AzVM -ResourceGroupName $rg -Status |
    Select-Object Name, @{N="State";E={$_.Statuses | Where-Object Code -like "PowerState*" | Select-Object -ExpandProperty DisplayStatus}} |
    Format-Table -AutoSize
```
Expected: At least minimum number of VMs in "running" state per scaling plan settings.

**Step 5 — Verify scaling plan schedule aligns with current time**
```powershell
# Get current time in host pool's configured timezone
$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("<Scaling-Plan-Timezone>")
$localTime = [System.TimeZoneInfo]::ConvertTime([DateTime]::UtcNow, $tz)
Write-Host "Current time in plan timezone: $localTime"
Write-Host "Check if this falls in ramp-up, peak, ramp-down, or off-peak window"
```

---

## Common Fix Paths

<details><summary>Fix 1 — Scaling Plan Not Assigned to Host Pool</summary>

```powershell
$rg = "<ResourceGroupName>"
$scalingPlan = "<ScalingPlanName>"
$hostPoolName = "<HostPoolName>"
$hostPoolId = (Get-AzWvdHostPool -ResourceGroupName $rg -Name $hostPoolName).Id

# Assign scaling plan to host pool
Update-AzWvdScalingPlan -ResourceGroupName $rg -Name $scalingPlan `
    -HostPoolReference @(@{HostPoolArmPath = $hostPoolId; ScalingPlanEnabled = $true})

Write-Host "Scaling plan assigned to $hostPoolName" -ForegroundColor Green
```

**Rollback:** Remove the host pool reference:
```powershell
Update-AzWvdScalingPlan -ResourceGroupName $rg -Name $scalingPlan -HostPoolReference @()
```
</details>

<details><summary>Fix 2 — Session Hosts Unavailable (AVD Agent / Health Check)</summary>

```powershell
# Identify unavailable session hosts
$unavailable = Get-AzWvdSessionHost -ResourceGroupName $rg -HostPoolName "<HostPoolName>" |
    Where-Object {$_.Status -ne "Available"}

foreach ($host in $unavailable) {
    $vmName = $host.Name.Split("/")[-1].Split(".")[0]
    Write-Host "Checking $vmName..."
    
    # Check if VM is running
    $vm = Get-AzVM -ResourceGroupName $rg -Name $vmName -Status
    $powerState = ($vm.Statuses | Where-Object Code -like "PowerState*").DisplayStatus
    Write-Host "  Power state: $powerState"
    
    if ($powerState -ne "VM running") {
        Start-AzVM -ResourceGroupName $rg -Name $vmName
        Write-Host "  Started VM" -ForegroundColor Yellow
    }
}

# If VM is running but session host still unavailable — restart AVD agent on the VM
# Run via Run Command:
Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName "<VMName>" -CommandId "RunPowerShellScript" -ScriptString @"
    Restart-Service RDAgentBootLoader -Force
    Restart-Service RDInfraAgent -Force
    Write-Output "AVD Agent restarted"
"@
```
</details>

<details><summary>Fix 3 — Missing Role Assignment for Scaling Service</summary>

```powershell
# Find the AVD first-party service principal
$avdSP = Get-AzADServicePrincipal -DisplayName "Windows Virtual Desktop"
if (-not $avdSP) {
    $avdSP = Get-AzADServicePrincipal -DisplayName "Azure Virtual Desktop"
}

$rg = "<ResourceGroupName>"
$hostPoolName = "<HostPoolName>"
$hostPoolId = (Get-AzWvdHostPool -ResourceGroupName $rg -Name $hostPoolName).Id
$subId = (Get-AzContext).Subscription.Id

# Assign required role at host pool scope
New-AzRoleAssignment `
    -ObjectId $avdSP.Id `
    -RoleDefinitionName "Desktop Virtualization Power On Off Contributor" `
    -Scope $hostPoolId

Write-Host "Role assigned to AVD service principal at host pool scope" -ForegroundColor Green

# Note: Can also assign at subscription scope for all host pools
# -Scope "/subscriptions/$subId"
```

**Rollback:**
```powershell
Remove-AzRoleAssignment -ObjectId $avdSP.Id `
    -RoleDefinitionName "Desktop Virtualization Power On Off Contributor" `
    -Scope $hostPoolId
```
</details>

<details><summary>Fix 4 — Resource Lock or Policy Blocking VM Power Operations</summary>

```powershell
$rg = "<ResourceGroupName>"

# Check for locks on the resource group or VMs
Get-AzResourceLock -ResourceGroupName $rg | Select-Object Name, LockLevel, ResourceType

# Remove a lock if found (requires Owner/User Access Admin)
# $lock = Get-AzResourceLock -ResourceGroupName $rg -LockName "<LockName>"
# Remove-AzResourceLock -LockId $lock.LockId -Force

# Check Azure Policy for deny effects on VM operations
Get-AzPolicyState -ResourceGroupName $rg |
    Where-Object {$_.ComplianceState -eq "NonCompliant"} |
    Select-Object ResourceType, PolicyDefinitionName, ComplianceState |
    Format-Table -AutoSize
```

**Rollback:** Re-apply the lock after scaling is confirmed working, if it was legitimate.
</details>

<details><summary>Fix 5 — Schedule / Timezone Misconfiguration</summary>

```powershell
$rg = "<ResourceGroupName>"
$scalingPlan = "<ScalingPlanName>"

# Get current plan
$plan = Get-AzWvdScalingPlan -ResourceGroupName $rg -Name $scalingPlan
Write-Host "Current timezone: $($plan.TimeZone)"

# List available timezone IDs
[System.TimeZoneInfo]::GetSystemTimeZones() | Where-Object {$_.Id -like "*UTC*" -or $_.Id -like "*Eastern*" -or $_.Id -like "*GMT*"} |
    Select-Object Id, DisplayName

# Update timezone if wrong
# Use the Azure Portal for schedule edits — the Az PowerShell module requires full schedule re-submission
# Portal: Azure Virtual Desktop > Scaling Plans > [Plan] > Schedules

# Common timezone IDs:
# "UTC"
# "Eastern Standard Time"
# "GMT Standard Time" (UK)
# "Central European Standard Time"
# "AUS Eastern Standard Time"

# Check minimum host count — if set to 0, all VMs may be deallocated
$plan.Schedule | ForEach-Object {
    Write-Host "Schedule: $($_.Name)"
    Write-Host "  Ramp-up min hosts: $($_.RampUpMinimumHostsPct)%"
    Write-Host "  Peak min hosts: $($_.PeakMinimumHostsPct)%"
}
```
</details>

---

## Escalation Evidence

```
TICKET: AVD Scaling Plan Not Working
=====================================
Date/Time         : _______________
Subscription      : _______________
Resource Group    : _______________
Host Pool         : _______________
Scaling Plan      : _______________

Symptoms
--------
VMs not starting at ramp-up      : [ ] Yes  [ ] No
VMs not draining/stopping        : [ ] Yes  [ ] No
Session hosts show Unavailable   : [ ] Yes  [ ] No
Specific schedule not triggering : [ ] Yes  [ ] No (which: _______)

Triage Results
--------------
Scaling plan assigned to host pool  : [ ] Yes  [ ] No
AVD role assigned                   : [ ] Yes  [ ] No
VM power states                     : _______________
Activity log errors (24h)           : _______________
Resource locks found                : [ ] Yes  [ ] No
Azure Policy blocking               : [ ] Yes  [ ] No
Scaling plan timezone               : _______________
Current time in plan timezone       : _______________

Fixes Already Tried
-------------------
[ ] Confirmed role assignment
[ ] Restarted AVD agent on affected VMs
[ ] Manually started/stopped test VM via scaling plan
[ ] Checked Activity Log for authorization errors
[ ] Verified schedule windows match current time

Evidence Attached
-----------------
[ ] Get-AzWvdScalingPlan output
[ ] Get-AzWvdSessionHost output
[ ] Activity log export (CSV)
[ ] VM power state table
```

---

## 🎓 Learning Pointers

- **The AVD scaling service principal is "Windows Virtual Desktop" or "Azure Virtual Desktop" in Entra ID.** It must have the "Desktop Virtualization Power On Off Contributor" role on either the host pool resource or the subscription. Without it, every scale-out/in action fails silently — the only evidence is in the Azure Activity Log. See [MS Docs: Set up scaling plans](https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-scaling-plan).

- **Scaling plans use UTC internally.** Even though you configure a timezone in the scaling plan, the AVD service converts schedule times to UTC. If your environment spans DST transitions, verify the plan accounts for the offset change — off by one hour at DST boundaries is a common complaint from end users experiencing too many/too few VMs.

- **"Exclusion tag" protects session hosts from autoscale.** Any VM tagged with the scaling plan's exclusion tag will not be started or stopped by the plan. Use this for dedicated VMs or when you need to hold a VM for maintenance. The tag key/value is defined on the scaling plan itself — check `$plan.ExclusionTag`.

- **Drain mode blocks autoscale shutdown.** If a session host is in drain mode (`AllowNewSession = False`) but still has active sessions, the scaling plan will not shut it down. This is by design — always check `Sessions` count before wondering why a VM isn't shutting down. See [MS Docs: Enable drain mode](https://learn.microsoft.com/en-us/azure/virtual-desktop/drain-mode).

- **Pooled vs Personal host pools have different scaling behaviors.** Pooled host pools scale based on total active sessions vs capacity. Personal host pools scale on user assignment — the VM starts when the assigned user connects and stops when disconnected (if configured). Mixing up the host pool type in the scaling plan configuration is a common setup error.
