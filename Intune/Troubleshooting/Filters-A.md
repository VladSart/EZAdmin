# Intune Assignment Filters — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why assignment filters work the way they do, not just how to configure them.

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

**What this covers:**
- Intune Assignment Filters — creation, evaluation, and failure modes
- Filter syntax (device property rules), managed device types, and supported workloads
- Troubleshooting policy/app not applying due to filter mismatch
- Filter evaluation order and interaction with group-based assignments

**What this does NOT cover:**
- App Protection Policies (filters work differently there — scope limited to Managed Devices)
- Azure AD dynamic groups (separate mechanism, often confused with filters)
- Autopilot pre-provisioning filter behavior (device is not yet enrolled, filters don't evaluate)

**Assumed environment:**
- Microsoft Intune tenant (commercial cloud)
- Devices enrolled via Autopilot, manual enrollment, or ADE
- Engineer has Intune Administrator or Policy and Profile Manager role

---

## How It Works

<details><summary>Full architecture — Assignment Filter evaluation engine</summary>

### What filters ARE

Assignment Filters are **post-group membership evaluators**. They do not replace group targeting — they refine it. The evaluation sequence is:

```
1. Policy is assigned to Group A  (with filter F1, Include)
2. Intune checks: Is device a member of Group A?  → YES
3. Intune evaluates filter F1 against device properties
4. If filter F1 returns TRUE → policy is delivered
5. If filter F1 returns FALSE → policy is skipped for that device
```

This means a device can be in the target group but still NOT receive a policy if the filter evaluates to false. This is the most common source of confusion.

### Filter property source

Filters evaluate **device properties at enrollment time and at check-in**. The evaluated properties come from the device object in Intune, NOT from Azure AD. This is a critical distinction.

Supported device properties for filter rules:
| Property | Type | Example |
|----------|------|---------|
| `deviceName` | String | `device.deviceName -startsWith "CORP-"` |
| `deviceType` | Enum | `device.deviceType -eq "Desktop"` |
| `osVersion` | Version | `device.osVersion -startsWith "10.0.22"` |
| `manufacturer` | String | `device.manufacturer -eq "Microsoft Corporation"` |
| `model` | String | `device.model -contains "Surface"` |
| `enrollmentProfileName` | String | `device.enrollmentProfileName -eq "CORP-AP"` |
| `category` | String | `device.category -eq "Corporate"` |
| `isRooted` | Bool | `device.isRooted -eq false` |
| `operatingSystemSKU` | String | `device.operatingSystemSKU -eq "Enterprise"` |
| `managementType` | Enum | `device.managementType -eq "MDM"` |

### Operator support
- `-eq` — equals (exact match, case-insensitive for strings)
- `-ne` — not equals
- `-startsWith` — string prefix
- `-endsWith` — string suffix
- `-contains` — substring
- `-notContains` — does not contain
- `-in` — matches one of a list: `device.model -in ["Surface Pro 9", "Surface Laptop 5"]`
- `-notIn` — not in list

### Logical operators
- `and` — both conditions must be true
- `or` — either condition must be true
- `not(...)` — negation
- Parentheses for grouping

### Include vs. Exclude mode
When assigning a policy to a group, you choose a filter mode:
- **Include**: deliver policy ONLY to group members WHERE filter = TRUE
- **Exclude**: deliver policy to ALL group members EXCEPT WHERE filter = TRUE

You can assign the same policy with multiple group+filter combinations. The union of all resulting devices gets the policy.

### Evaluation timing
Filters are NOT evaluated continuously. They are evaluated:
1. During device check-in with Intune (typically every 8 hours for managed devices)
2. When a policy change is triggered by admin action
3. On-demand when the user/admin initiates a sync

Property staleness is possible: if a device's `osVersion` was updated overnight, the filter may not reflect the new OS until next check-in.

### Supported workloads
Filters are supported for:
- Device configuration profiles
- Compliance policies
- App assignments (Required, Available, Uninstall)
- PowerShell scripts
- Shell scripts (macOS)
- Proactive remediations
- Windows Update rings and feature update policies

Filters are NOT supported for:
- App Protection Policies (MAM)
- Enrollment restrictions (use enrollment platforms instead)
- Terms and Conditions

</details>

---

## Dependency Stack

```
Intune Policy Assignment
        │
        ▼
Target Group (Azure AD Security Group)
        │
        ▼
Group Membership Resolved (Azure AD)
        │
        ▼
Assignment Filter Evaluated (Intune)
        │  (device properties from Intune device record)
        ▼
Policy Delivered or Skipped
        │
        ▼
Device Check-in / MDM Channel
        │
        ▼
Policy Applied on Device
```

**External dependencies:**
- Azure AD group membership must resolve correctly before filter evaluation
- Intune device object must have current property values (staleness risk)
- Device must be able to reach Intune MDM endpoints for check-in

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Policy not applied to device; device is in target group | Filter evaluating to FALSE | Check filter rule syntax vs. actual device properties in Intune portal |
| Policy applies to ALL devices in group, filter seems ignored | Filter is set to "Exclude" not "Include" | Review assignment blade in Intune — check Include/Exclude toggle |
| Filter evaluates correctly but policy still missing | Device check-in hasn't occurred since filter change | Force sync via Company Portal or `Invoke-IntuneSync` |
| `enrollmentProfileName` filter returns no matches | Device enrolled before Autopilot profile was assigned | Profile name is blank for devices not enrolled via Autopilot |
| `category` property empty, filter rule fails | Device Category not assigned post-enrollment | Assign a device category in Intune: Devices > device > Properties |
| Filter syntax error at creation | Invalid operator for property type | Validate against Intune filter builder in portal — it blocks invalid syntax |
| Filter works in test, fails in production | Case sensitivity or trailing spaces in string value | Re-enter string values; filter strings are case-insensitive but trim whitespace |
| `deviceType` filter doesn't match | Enrolled as "Unknown" device type | Check enrollment method — some enrollments leave deviceType unresolved |
| Policy applies when filter should exclude it | Excluded via group has higher precedence than include | Verify: Exclude always wins over Include in Intune conflict resolution |

---

## Validation Steps

**Step 1 — Confirm device properties visible in Intune**

In the Intune portal: Devices > All Devices > [device] > Properties.

Or via PowerShell:
```powershell
# Requires: Microsoft.Graph.DeviceManagement module
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"

$upn = "<UserUPN>"
$devices = Get-MgDeviceManagementManagedDevice -Filter "userPrincipalName eq '$upn'" -Property `
    "deviceName,operatingSystem,osVersion,manufacturer,model,enrollmentProfileName,deviceCategoryDisplayName,managementType,isJailBroken"

$devices | Select-Object deviceName, osVersion, manufacturer, model, enrollmentProfileName, 
    deviceCategoryDisplayName, managementType, isJailBroken | Format-Table -AutoSize
```

**Expected good output:** All fields populated. `enrollmentProfileName` populated only for Autopilot devices.

**Bad output:** `enrollmentProfileName` is empty on a device your filter targets. The filter will NEVER match.

---

**Step 2 — Test filter against a specific device in portal**

Intune portal → Tenant Administration → Filters → [your filter] → "Device preview"

Enter device name or search by property. The portal will show:
- Match: YES/NO
- Which rule clause caused the result

This is the fastest diagnostic tool. Use it first.

---

**Step 3 — Check policy assignment in device context**

Intune portal: Devices > [device] > Device configuration (or Compliance)

Look for the policy in question. Status should show "Succeeded". If "Not applicable":
- Filter evaluated to FALSE, OR
- Device is excluded via a conflict group assignment

---

**Step 4 — Check assignment configuration**

Intune portal → [Policy] → Properties → Assignments → Review

Verify:
1. Target group is correct
2. Filter is selected and has the right name
3. Mode is "Include" not "Exclude" (if you want to narrow scope)
4. No conflicting "Exclude" group assignment overriding this

---

**Step 5 — Force sync and recheck**

```powershell
# Force Intune sync on local device (run as user or SYSTEM)
$session = New-CimSession
$result = Invoke-CimMethod -Namespace "root\ccm" -ClassName "SMS_Client" `
    -MethodName "TriggerSchedule" -Arguments @{sScheduleID="{00000000-0000-0000-0000-000000000021}"}
# OR via scheduled task:
Get-ScheduledTask -TaskName "PushLaunch" | Start-ScheduledTask
```

Or trigger from Intune portal: Devices > [device] > Sync

Wait 5-10 minutes and recheck device configuration status.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Identify scope

1. Is this one device or many?
   - **One device:** likely a property mismatch between filter rule and device data
   - **Many devices:** likely a filter syntax error or wrong assignment mode

2. Was this working before?
   - **Never worked:** filter may have been misconfigured from creation
   - **Stopped working:** a device property changed (e.g., OS update changed `osVersion`), or filter was edited

3. What changed recently?
   - Filter rule edited
   - Policy assignment group changed
   - Device re-enrolled (resets some properties like `enrollmentProfileName`)

---

### Phase 2 — Isolate the filter

1. Use portal "Device preview" on the filter — test the affected device
2. If NO MATCH: check which clause fails — the portal highlights it
3. Edit filter to a broader rule temporarily (e.g., remove a clause) and test again

---

### Phase 3 — Check device property accuracy

```powershell
# Get specific device Intune record properties
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"

$deviceName = "<DeviceName>"
$device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$deviceName'"

[PSCustomObject]@{
    DeviceName            = $device.DeviceName
    OSVersion             = $device.OsVersion
    Manufacturer          = $device.Manufacturer
    Model                 = $device.Model
    EnrollmentProfile     = $device.EnrollmentProfileName
    DeviceCategory        = $device.DeviceCategoryDisplayName
    ManagementType        = $device.ManagementType
    ComplianceState       = $device.ComplianceState
    LastSyncDateTime      = $device.LastSyncDateTime
    OperatingSystemSKU    = $device.OperatingSystemSku
} | Format-List
```

Compare each field against your filter rule's expected value. Even one character difference causes a mismatch.

---

### Phase 4 — Conflict resolution check

If the device IS receiving the policy but shouldn't (filter should exclude it):

1. Check if the device is in an "Exclude" group for that policy
2. Verify the filter mode on the assignment that should exclude is set to "Exclude"
3. Remember: Intune Exclude group assignments (without filters) take absolute precedence

---

## Remediation Playbooks

<details><summary>Fix 1 — Correcting a filter property mismatch</summary>

**Scenario:** Filter uses `device.enrollmentProfileName -eq "CORP-AP"` but device shows blank profile name.

**Root cause:** Device was enrolled without the Autopilot profile being assigned at enrollment time. `enrollmentProfileName` is only populated for Windows Autopilot enrollments.

**Fix:**
1. If the device SHOULD be an Autopilot device: re-register the device hash, assign the correct profile, and reset/re-enroll
2. If you want to target these devices differently: change the filter to use a different property (e.g., `deviceName -startsWith "CORP-"` or `device.category -eq "Corporate"`)
3. Assign device category manually: Intune portal → Devices → [device] → Properties → Device category

**Rollback:** Not destructive — filter changes don't affect enrolled state. Revert filter rule to previous value.

</details>

<details><summary>Fix 2 — Filter mode set to Exclude instead of Include</summary>

**Scenario:** Policy applies to everyone in the group instead of the filtered subset.

**Fix:**
1. Intune portal → [Policy] → Properties → Assignments
2. Click the "Edit" button on the assignment row
3. In the Filter section, change mode from "Exclude" to "Include"
4. Save → Review + Save

**Verify:** Use Device preview on the filter for an affected device. It should show MATCH. Then check device configuration status after next sync.

**Rollback:** Revert mode back to "Exclude" if unintended change.

</details>

<details><summary>Fix 3 — Filter syntax error on osVersion</summary>

**Scenario:** Filter `device.osVersion -startsWith "10.0.22000"` doesn't match Windows 11 devices running 10.0.22621.

**Root cause:** The `-startsWith` operator matches the string prefix. `10.0.22000` will NOT match `10.0.22621`. Each major Windows build has a different third octet.

**Fix — match all Windows 11 variants:**
```
(device.osVersion -startsWith "10.0.22000") or (device.osVersion -startsWith "10.0.22621") or (device.osVersion -startsWith "10.0.22631")
```

Or use a broader match for all Windows 11+:
```
device.osVersion -startsWith "10.0.2"
```
> ⚠️ Be careful: future Windows versions may start with different prefixes.

**Better approach:** Use `device.operatingSystemSKU` to target Windows editions rather than build numbers.

</details>

<details><summary>Fix 4 — Device category not set, filter rule using category fails</summary>

**Scenario:** Filter `device.category -eq "Corporate"` returns no matches because devices have no category assigned.

**Fix — Bulk assign device category via PowerShell:**

```powershell
# Requires: Microsoft.Graph.DeviceManagement
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All", "DeviceManagementConfiguration.ReadWrite.All"

# Get category ID
$category = Get-MgDeviceManagementDeviceCategory | Where-Object { $_.DisplayName -eq "Corporate" }
if (-not $category) {
    Write-Warning "Category 'Corporate' not found. Create it in Intune portal first."
    return
}

# Get all Windows devices without a category
$devices = Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" -All |
    Where-Object { [string]::IsNullOrEmpty($_.DeviceCategoryDisplayName) }

Write-Host "Devices without category: $($devices.Count)"

foreach ($device in $devices) {
    try {
        Update-MgDeviceManagementManagedDevice -ManagedDeviceId $device.Id `
            -DeviceCategoryId $category.Id
        Write-Host "Set category for: $($device.DeviceName)" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed for $($device.DeviceName): $_"
    }
}
```

**Rollback:** Assign a different category or clear it via the same script with `-DeviceCategoryId ""`.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Intune Assignment Filter evidence for escalation
.NOTES     Run as Intune admin. Requires Microsoft.Graph.DeviceManagement module.
#>
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All","DeviceManagementConfiguration.Read.All"

$deviceName  = "<DeviceName>"     # Device to investigate
$policyName  = "<PolicyName>"     # Policy not applying (optional)
$outputPath  = "C:\Temp\FilterEvidence_$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

# 1. Device properties
$device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$deviceName'" |
    Select-Object DeviceName, OsVersion, Manufacturer, Model, EnrollmentProfileName,
        DeviceCategoryDisplayName, ManagementType, ComplianceState, LastSyncDateTime,
        OperatingSystemSku, JailBroken, Id
$device | Export-Csv "$outputPath\DeviceProperties.csv" -NoTypeInformation

# 2. All assignment filters in tenant
$filters = Get-MgDeviceManagementAssignmentFilter -All |
    Select-Object DisplayName, Platform, Rule, Id
$filters | Export-Csv "$outputPath\AllFilters.csv" -NoTypeInformation

# 3. Device configuration profile assignments
$profiles = Get-MgDeviceManagementDeviceConfiguration -All |
    Select-Object DisplayName, Id
$assignments = foreach ($profile in $profiles) {
    $assigns = Get-MgDeviceManagementDeviceConfigurationAssignment -DeviceConfigurationId $profile.Id
    foreach ($a in $assigns) {
        [PSCustomObject]@{
            ProfileName  = $profile.DisplayName
            ProfileId    = $profile.Id
            GroupId      = $a.Target.AdditionalProperties.groupId
            TargetType   = $a.Target.ODataType
            FilterId     = $a.Target.AdditionalProperties.deviceAndAppManagementAssignmentFilterId
            FilterType   = $a.Target.AdditionalProperties.deviceAndAppManagementAssignmentFilterType
        }
    }
}
$assignments | Export-Csv "$outputPath\ProfileAssignments.csv" -NoTypeInformation

Write-Host "Evidence saved to: $outputPath" -ForegroundColor Green
Write-Host ""
Write-Host "=== DEVICE PROPERTIES ===" -ForegroundColor Cyan
$device | Format-List
Write-Host ""
Write-Host "=== ALL FILTERS ===" -ForegroundColor Cyan
$filters | Format-Table DisplayName, Platform, Rule -AutoSize
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|-------------------|
| List all filters in tenant | `Get-MgDeviceManagementAssignmentFilter -All` |
| Get specific filter details | `Get-MgDeviceManagementAssignmentFilter -AssignmentFilterId <id>` |
| Test filter against device | Intune portal → Tenant Admin → Filters → [filter] → Device preview |
| Check device properties | `Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<name>'"` |
| List device categories | `Get-MgDeviceManagementDeviceCategory` |
| Assign device category | `Update-MgDeviceManagementManagedDevice -ManagedDeviceId <id> -DeviceCategoryId <catId>` |
| Force device sync | Intune portal → [device] → Sync |
| Check policy status on device | Intune portal → [device] → Device configuration |
| List all profile assignments | `Get-MgDeviceManagementDeviceConfigurationAssignment -DeviceConfigurationId <id>` |
| Create new filter | Intune portal → Tenant Admin → Filters → Create |
| Get managed device by UPN | `Get-MgDeviceManagementManagedDevice -Filter "userPrincipalName eq '<UPN>'"` |

---

## 🎓 Learning Pointers

- **Filters ≠ Dynamic Groups.** Azure AD dynamic groups decide who is IN a group. Filters decide who (within that group) gets a policy. They operate at different layers and should be used together for flexible targeting. Reference: [Intune assignment filters overview](https://learn.microsoft.com/en-us/mem/intune/fundamentals/filters)

- **`enrollmentProfileName` is Autopilot-only.** Attempting to filter on this property for manually enrolled or bulk-enrolled devices will always return empty/no match. Use `deviceName` prefix or `category` for non-Autopilot targeting.

- **Property staleness is real.** The Intune device record lags behind actual device state by up to one check-in cycle (typically 8 hours). A device that just updated its OS won't match a new `osVersion` filter rule until it checks back in. Force sync to accelerate this.

- **Exclude beats Include.** When a device is in both an Include-filtered assignment and an Exclude group assignment for the same policy, the Exclude wins — regardless of filter evaluation. This mirrors Intune's standard conflict resolution. Reference: [Intune conflict resolution](https://learn.microsoft.com/en-us/mem/intune/configuration/device-profile-troubleshoot)

- **Use the portal "Device preview" first.** Before digging into PowerShell, test the filter directly in the Intune portal against the affected device. It shows exactly which rule clause is failing. This cuts diagnostic time from 30 minutes to 2 minutes.

- **Filter rules are case-insensitive but whitespace-sensitive.** The string `"CORP-"` matches `"corp-"` — but `"CORP- "` (trailing space) does NOT match `"CORP-"`. Always trim string values when building filter rules.
