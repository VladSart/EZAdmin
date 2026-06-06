# Intune Assignment Filters — Hotfix Runbook (Mode B: Ops)
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

Run these within the first 2 minutes to determine what's broken:

```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","DeviceManagementManagedDevices.Read.All"

# 1. List all assignment filters
Get-MgBetaDeviceManagementAssignmentFilter | Select-Object DisplayName, Platform, Rule, AssignmentFilterManagementType | Format-Table -AutoSize

# 2. Check a specific device's filter evaluation result
# (Replace deviceId with the Intune Device ID from portal)
$deviceId = "<IntuneDeviceId>"
Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$deviceId/managementState" |
  ConvertTo-Json

# 3. Check what policies are assigned with a filter
Get-MgBetaDeviceManagementDeviceConfiguration | Select-Object DisplayName, Id |
  ForEach-Object {
    $assignments = Get-MgBetaDeviceManagementDeviceConfigurationAssignment -DeviceConfigurationId $_.Id
    if ($assignments) {
        [PSCustomObject]@{
            Policy = $_.DisplayName
            Assignments = ($assignments | ConvertTo-Json -Compress)
        }
    }
  } | Format-Table -AutoSize

# 4. Check filter evaluation for a specific device (portal path)
# Intune portal > Devices > [Device] > Managed by > Device configuration > filter evaluation
```

**Interpretation:**

| What you see | What it means |
|---|---|
| Filter not listed | Filter doesn't exist — check spelling in policy assignment |
| Filter has wrong platform | Filter targets wrong OS — recreate for correct platform |
| Device shows `Not evaluated` | Device hasn't checked in since filter was applied — trigger sync |
| Device shows `Excluded` when should be `Included` | Filter rule logic error — review rule syntax |
| Policy assigned but not applying | Filter is excluding the device — check filter result in device config view |
| All devices affected | Filter rule syntax error or wrong property used |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Intune Assignment Filter
        │
        │ evaluates against
        ▼
Device Properties at Check-in Time
  ├── device.platform             (Windows, iOS, Android, macOS)
  ├── device.osVersion            (OS version string)
  ├── device.manufacturer         (e.g., "Microsoft", "Apple")
  ├── device.model                (e.g., "Surface Pro 9")
  ├── device.enrollmentProfileName (Autopilot profile name)
  ├── device.deviceCategory       (custom category assigned in Intune)
  ├── device.deviceOwnership      (Corporate, Personal)
  └── device.managementType       (MDM, EAS, etc.)
        │
        │ result used in
        ▼
Policy / App / Compliance Assignment
  ├── Include filter = only apply to devices where filter = true
  └── Exclude filter = skip devices where filter = true
        │
        │ requires device to
        ▼
Check in to Intune (sync) to re-evaluate filter
  └── Filters are NOT evaluated in real-time — only at check-in
```

**Critical constraint:** Filters are evaluated at policy sync time, not continuously. If a device property changes (e.g., model, category), the new filter result only takes effect after the next check-in.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the device is checking in**
```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
$device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'"
$device | Select-Object DeviceName, LastSyncDateTime, ManagementState, OperatingSystem, OsVersion, Manufacturer, Model
```
Expected: `LastSyncDateTime` within last 8 hours; `ManagementState = Managed`.  
Bad: `LastSyncDateTime` is days old — trigger a sync before drawing filter conclusions.

**Step 2 — Verify filter rule syntax**

In the Intune portal: Tenant admin > Filters > [Filter Name] > Properties > Filter rule.

Valid rule example:
```
(device.platform -eq "Windows10AndLater") and (device.manufacturer -eq "Microsoft")
```

Common syntax mistakes that silently fail:
- Using `-contains` when `-eq` is needed (substring vs exact match)
- Wrong platform string: `Windows` instead of `Windows10AndLater`
- Case-sensitive strings: `"microsoft"` instead of `"Microsoft"`
- Missing parentheses around complex `and`/`or` conditions

**Step 3 — Check filter evaluation result for a specific device**
In the Intune portal:
1. Devices > All devices > [Device]
2. Select "Device configuration" or "Compliance policies"
3. For each policy, look at the "Filter" column — shows `Included`, `Excluded`, or `Not evaluated`

**Step 4 — Validate the filter with Preview**
In the Intune portal: Tenant admin > Filters > [Filter] > Filter evaluation (Preview tab).
Enter a device name to simulate what the filter would return for that device without applying anything. Use this before editing live filters.

**Step 5 — Confirm policy assignment includes the correct filter**
```powershell
# Check policy assignments for a specific configuration profile
$policyId = "<PolicyId>"
Get-MgBetaDeviceManagementDeviceConfigurationAssignment -DeviceConfigurationId $policyId |
    Select-Object Id, @{N='Target';E={$_.Target | ConvertTo-Json}}
```
Look for `deviceAndAppManagementAssignmentFilterId` in the JSON — confirm it matches the intended filter GUID.

---

## Common Fix Paths

<details><summary>Fix 1 — Filter syntax error preventing evaluation</summary>

**Symptom:** Policy not applying to any devices despite filter should match many.

**Cause:** Incorrect operator, wrong property name, or misquoted string value.

**Fix:**
1. Navigate to Intune portal > Tenant admin > Filters > [Filter].
2. Click Edit > Rule syntax.
3. Use the Filter preview to test against known devices.
4. Correct common errors:

| Wrong | Correct |
|-------|---------|
| `device.platform -eq "Windows"` | `device.platform -eq "Windows10AndLater"` |
| `device.manufacturer -eq "microsoft"` | `device.manufacturer -eq "Microsoft"` (case sensitive) |
| `device.model -contains "Surface"` | `device.model -startsWith "Surface"` |
| `device.osVersion -eq "10.0.22621"` | `device.osVersion -startsWith "10.0.22621"` |

5. Save the filter.
6. Trigger device sync to re-evaluate: Devices > [Device] > Sync.

**Rollback:** Revert rule to previous syntax via portal history or by removing the filter from the assignment temporarily.

</details>

<details><summary>Fix 2 — Device property not populated (category, ownership)</summary>

**Symptom:** Filter on `device.deviceCategory` or `device.deviceOwnership` not matching expected devices.

**Cause:** Device category not assigned; ownership not set to Corporate.

**Fix — Set device category:**
```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All","DeviceManagementConfiguration.ReadWrite.All"

# Get the device category ID
$category = Get-MgDeviceManagementDeviceCategory | Where-Object { $_.DisplayName -eq "<CategoryName>" }

# Assign category to device
$deviceId = "<IntuneDeviceId>"
Set-MgDeviceManagementManagedDeviceCategory -ManagedDeviceId $deviceId `
  -DeviceCategoryId $category.Id
```

**Fix — Change ownership to Corporate:**
```powershell
Update-MgDeviceManagementManagedDevice -ManagedDeviceId $deviceId `
  -ManagedDeviceOwnerType "company"
```

Trigger sync after making changes.

**Rollback:** Set category back to None, or ownership back to `personal`.

</details>

<details><summary>Fix 3 — Filter applied as "Exclude" instead of "Include"</summary>

**Symptom:** Policy not reaching a device that the filter should match; device shows "Excluded" in policy view.

**Cause:** Filter was assigned as Exclude mode instead of Include mode, or vice versa.

**Fix:**
1. In Intune portal, open the policy > Assignments.
2. For each group assignment, check the "Filter mode" column — should be `Include` to limit to matching devices, `Exclude` to skip matching devices.
3. Click the assignment, change filter mode, save.
4. Trigger device sync.

**Logic reminder:**
- **Include filter** = "Only apply this policy to devices matching the filter"
- **Exclude filter** = "Apply this policy to all devices in the group EXCEPT those matching the filter"

</details>

<details><summary>Fix 4 — Filter not re-evaluated after device property change</summary>

**Symptom:** Filter should match device (e.g., after category assignment), but policy still not applying.

**Cause:** Filters only re-evaluate at check-in. Device hasn't synced since the property change.

**Fix:**
```powershell
# Trigger a sync for a specific device
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All"
$deviceId = "<IntuneDeviceId>"
Invoke-MgDeviceManagementManagedDeviceSync -ManagedDeviceId $deviceId
```

Or in portal: Devices > [Device] > Sync (or from the device itself: Settings > Accounts > Access work or school > Info > Sync).

Wait 5-10 minutes, then re-check policy status in the device's configuration view.

</details>

<details><summary>Fix 5 — Filter assigned to wrong platform policy</summary>

**Symptom:** Filter exists and is correct, but Windows filter is assigned to a macOS or iOS policy (or vice versa).

**Cause:** Filters are platform-specific. A Windows filter will silently return `Not evaluated` on an iOS device assignment.

**Fix:**
1. Check the filter's platform: Tenant admin > Filters > [Filter] > Platform.
2. Check the policy's platform.
3. If mismatched, either:
   - Create a new filter with the correct platform, or
   - Remove the filter from the cross-platform policy assignment.

Filters cannot be assigned cross-platform — they will always return `Not evaluated` if platforms don't match.

</details>

---

## Escalation Evidence

```
=== Intune Assignment Filter Escalation Pack ===

Date/Time:          ___________________________
Tenant ID:          ___________________________
Filter Name:        ___________________________
Filter GUID:        ___________________________
Filter Rule:        ___________________________
Filter Platform:    ___________________________
Filter Mode (Inc/Exc): _______________________

Affected Policy:    ___________________________
Policy Type:        ___________________________
Policy GUID:        ___________________________

Affected Device:    ___________________________
Intune Device ID:   ___________________________
OS / Version:       ___________________________
Last Sync Time:     ___________________________
Filter Evaluation Result (in portal): _________

Expected Behavior:  ___________________________
Actual Behavior:    ___________________________

Steps Already Taken:
  1. ___________________________________________
  2. ___________________________________________
  3. ___________________________________________

Filter Preview Result (test device name used): ___
Screenshot of device > policy > filter column: [attached]

Raise via: Microsoft Intune support case
Required role evidence: [attach screenshot of admin role assignment]
```

---

## 🎓 Learning Pointers

- **Filters evaluate at check-in, not in real-time.** A changed device property (model, category, ownership) won't affect policy targeting until the device syncs. Always trigger a sync and wait before concluding a filter isn't working. [MS Docs: Assignment filters](https://learn.microsoft.com/en-us/mem/intune/fundamentals/filters)

- **Filter preview is your safe testing ground.** Before editing a live filter, use the Filter evaluation preview in the portal to simulate what the rule returns for specific devices without touching any assignments. Never edit production filter rules without testing first.

- **Platform strings must be exact.** `Windows10AndLater`, `iOS`, `macOS`, `Android` — these are case-sensitive enumerations. `Windows` alone will not match any device. Check the [filter property reference](https://learn.microsoft.com/en-us/mem/intune/fundamentals/filters-device-properties) for valid values.

- **Filters don't replace groups — they refine them.** A filter is always applied on top of a group assignment. The device must still be a member of the assigned group AND match the filter. If the group assignment is wrong, fixing the filter won't help.

- **Filters work on managed device properties, not Entra ID attributes.** Device category, enrollment profile name, and ownership come from Intune — not from Entra ID device attributes. You cannot filter on Entra ID extension attributes. [Filter properties list](https://learn.microsoft.com/en-us/mem/intune/fundamentals/filters-device-properties)

- **Use filters over multiple groups where possible.** Maintaining one large group with Include filters per scenario is cleaner than dozens of device groups. Reduces AAD group sprawl and makes targeting intent explicit and auditable.
