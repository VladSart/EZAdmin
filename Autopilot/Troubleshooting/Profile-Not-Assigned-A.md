# Autopilot Profile Not Assigned — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why the profile pipeline breaks, not just what to click.

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

| Item | Detail |
|------|--------|
| Applies to | Windows Autopilot (OOBE), pre-provisioned (White Glove), and self-deploying modes |
| Not covered | Co-management Autopilot flows, Autopilot Reset, DFCI (Device Firmware Configuration Interface) |
| Pre-requisite knowledge | Basic Intune, Entra ID group membership, hardware hash registration |
| Permissions needed | Intune Administrator or Global Reader + Intune Reader at minimum |
| Tenant types | Cloud-only, Hybrid Azure AD Join, Entra-joined |

A "profile not assigned" condition means the device reaches OOBE, contacts the Autopilot service, and receives either no profile or a default/generic one — causing the device to proceed as a standard Windows setup rather than a managed Autopilot flow.

---

## How It Works

<details><summary>Full Autopilot profile assignment architecture</summary>

### Phase 1 — Hardware Hash Registration

When a device is registered for Autopilot, a hardware hash (4K binary blob derived from SMBIOS, disk serial, TPM EK, NIC MACs) is uploaded to the Autopilot service. This hash is the **primary identity** used during OOBE — the device has no Azure AD identity at this point.

```
OEM / MDM Tool / Intune Admin
        │
        │  Upload: Hardware Hash + optional Group Tag + optional Assigned User
        ▼
  Autopilot Service (windowsphone.com)
        │
        │  Stores: Device object with hash + OrderId (Group Tag) + ZTDId
        ▼
  Entra ID: Creates "device" entry (staged, not yet joined)
```

### Phase 2 — Profile Resolution at OOBE

At OOBE (after network connectivity is established), the device calls the Autopilot Discovery Service:

```
Device (OOBE)
    │
    │  GET https://cs.dds.microsoft.com/autopilot/oobe?....
    │  (sends hardware hash fingerprint + TPM EK cert chain)
    ▼
Autopilot Service
    │
    │  1. Match hash → find ZTDId
    │  2. Look up ZTDId in tenant
    │  3. Evaluate deployment profile assignments
    ▼
Returns: Deployment Profile JSON (or "no profile found")
```

### Phase 3 — Profile Assignment Evaluation

Profile assignment is **group-based only** in modern Intune. The service evaluates:

```
ZTDId (Autopilot device object)
    │
    ├── Has Group Tag (OrderId)?
    │       └── Dynamic group rule: (device.devicePhysicalIds -any _ -eq "[OrderID]:MyTag")
    │
    ├── Has Assigned User (pre-assign)?
    │       └── Group membership of the assigned user (user-based dynamic groups)
    │
    └── Device is member of "All Devices" or static group?
            └── Profile assigned to that group
```

**Key constraint:** The Autopilot device object in Entra ID is NOT a regular device object. Dynamic group membership rules for `deviceManagementAppId`, `deviceOSType`, etc. do **not** apply to Autopilot objects during OOBE. Only `devicePhysicalIds` rules work.

### Phase 4 — Profile Delivery & Application

```
Profile JSON received
    │
    ├── Applies OOBE customisation (skip screens, tenant branding, etc.)
    ├── Sets join type: AAD-join vs Hybrid-join
    ├── Sets deployment mode: User-driven vs Self-deploying vs Pre-provisioning
    └── Triggers MDM enrollment via Windows Enrollment Service (WES)
```

### Replication Latency

After registering a device or modifying group membership:

| Action | Typical replication lag | Maximum observed |
|--------|------------------------|-----------------|
| Hash upload → Autopilot service | 5–15 min | 30 min |
| Autopilot service → Entra ID device object | 5–10 min | 20 min |
| Dynamic group rule evaluation | 5–30 min | 60 min |
| Profile assignment to device | Near-instant after group membership resolves | — |

End-to-end: allow **60–90 minutes** after registration before expecting reliable profile assignment.

</details>

---

## Dependency Stack

```
Windows OOBE (OOBE\System32\oobe.exe)
    │
    ▼
Autopilot Discovery Service (cs.dds.microsoft.com)
    │  Requires: TLS 1.2, specific firewall endpoints
    ▼
Autopilot Device Object (Entra ID - devicePhysicalIds)
    │  Requires: Hash registered, not duplicate, not expired
    ▼
Group Membership Evaluation (Entra ID Dynamic Groups)
    │  Requires: Group Tag OR Assigned User OR static group membership
    ▼
Deployment Profile (Intune - Windows Autopilot Deployment Profiles)
    │  Requires: Profile assigned to a group containing the device
    ▼
Profile Returned to Device (JSON via OOBE)
    │  Requires: Network reachable, correct tenant context
    ▼
MDM Enrollment (Windows Enrollment Service)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| OOBE shows standard Windows setup, no tenant branding | No profile assigned; or profile received but has "Skip" for all screens | Intune → Devices → Entra ID devices → find device, check Deployment Profile |
| "Something went wrong" error 0x80180014 | Hash not found in any tenant | Devices → Windows → Windows enrollment → Devices — search by serial |
| "Something went wrong" error 0x80180018 | Device registered to a different tenant | Check if hash registered to old tenant; requires deletion there first |
| Device proceeds as OOBE but skips branding, lands on generic setup | Profile assigned but no customisation configured (defaults to all skips = disabled) | Review profile settings — ensure at least EULA skip or naming convention is set |
| Pre-provisioning (White Glove) fails at technician phase | Profile not set to allow pre-provisioning | Profile → Pre-provision: check "Allow pre-provisioned deployment" = Yes |
| Self-deploying mode device shows user login screen | Profile mode set to User-driven instead of Self-deploying | Profile → Deployment mode |
| Profile shows "Not assigned" in device details after hash upload | Dynamic group hasn't processed yet, or Group Tag mismatch | Wait 60 min; check Group Tag spelling (case-sensitive) |
| New profile not applying after profile update | Device cached old profile from previous OOBE attempt | Profile cache in registry; must reset or re-register |
| Device registers but appears in "Not registered" state | Duplicate hash across multiple registrations | Delete duplicates in Autopilot device list |

---

## Validation Steps

**Step 1 — Confirm device exists in Autopilot service**
```powershell
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All"
$serial = "<DeviceSerial>"
Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -Filter "contains(serialNumber,'$serial')" |
    Select-Object SerialNumber, GroupTag, AzureActiveDirectoryDeviceId, EnrollmentState, DeploymentProfileAssignedDateTime, DeploymentProfileAssignmentStatus
```
Expected good output:
```
SerialNumber   : XXXXXXXXXXXX
GroupTag       : MyTag
EnrollmentState: notContacted
DeploymentProfileAssignmentStatus: assigned
```
Bad: `DeploymentProfileAssignmentStatus: notAssigned` or empty result.

**Step 2 — Check the assigned profile (if any)**
```powershell
$apDevice = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -Filter "contains(serialNumber,'$serial')"
$apDevice.DeploymentProfileAssignedDateTime
$apDevice.IntendedDeploymentProfileId
```
If `IntendedDeploymentProfileId` is null → no profile matched the device's group membership.

**Step 3 — Verify group membership for the Autopilot device object**
```powershell
# Get the Entra ID device object corresponding to the Autopilot registration
$deviceId = $apDevice.AzureActiveDirectoryDeviceId
$device = Get-MgDevice -Filter "deviceId eq '$deviceId'"

# Check which groups it belongs to
Get-MgDeviceMemberOf -DeviceId $device.Id | Select-Object Id, @{N='DisplayName';E={$_.AdditionalProperties['displayName']}}
```
If the device is not in any group that has a profile assigned → that's your root cause.

**Step 4 — Validate the Group Tag rule on the dynamic group**
```powershell
# Find groups using devicePhysicalIds rules
Get-MgGroup -Filter "startswith(displayName,'Autopilot')" | 
    Select-Object DisplayName, MembershipRule | 
    Where-Object { $_.MembershipRule -match "devicePhysicalIds" }
```
Check: does the rule match the Group Tag on the device?
- Rule format for Group Tag: `(device.devicePhysicalIds -any _ -eq "[OrderID]:YourTag")`
- Common mistake: using `[OrderId]` vs `[OrderID]` (capital D matters — use `[OrderID]`)

**Step 5 — Check profile assignments**
```powershell
# List all Autopilot deployment profiles and their assignments
$profiles = Get-MgDeviceManagementWindowsAutopilotDeploymentProfile
foreach ($p in $profiles) {
    $assignments = Get-MgDeviceManagementWindowsAutopilotDeploymentProfileAssignment -WindowsAutopilotDeploymentProfileId $p.Id
    [PSCustomObject]@{
        Profile     = $p.DisplayName
        Assignments = ($assignments | ForEach-Object { $_.Target.AdditionalProperties['groupId'] }) -join ', '
    }
}
```
Verify: at least one profile has an assignment to a group containing your device.

**Step 6 — Check for duplicate registrations**
```powershell
Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -Filter "contains(serialNumber,'$serial')" -All |
    Select-Object Id, SerialNumber, GroupTag, AzureActiveDirectoryDeviceId, LastContactedDateTime
```
If you see multiple rows for the same serial, duplicates are blocking proper resolution.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Device Not Found

1. Confirm serial number exact match (no leading/trailing spaces):
   ```powershell
   Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All | 
       Where-Object { $_.SerialNumber -like "*$serial*" }
   ```
2. If not found: re-collect the hardware hash and re-upload.
   ```powershell
   # On the device (requires admin)
   Install-Script -Name Get-WindowsAutopilotInfo -Force
   Get-WindowsAutopilotInfo -Online  # uploads directly if signed in
   # Or: Get-WindowsAutopilotInfo -OutputFile C:\hash.csv  then import via Intune portal
   ```
3. Wait 15 minutes and re-check.

### Phase 2 — Device Found, Profile Status = notAssigned

1. Check group tag on device vs group rule:
   ```powershell
   $apDevice.GroupTag  # what's on the device
   ```
2. Check group membership manually:
   ```powershell
   # Force-check device's physical IDs
   $device = Get-MgDevice -Filter "deviceId eq '$($apDevice.AzureActiveDirectoryDeviceId)'"
   $device.PhysicalIds  # should include [OrderID]:YourTag and [ZTDID]:...
   ```
3. If physical IDs are missing or wrong: delete and re-register the device with correct Group Tag.
4. Check if dynamic group rule is processing:
   ```powershell
   Get-MgGroup -GroupId "<groupId>" | Select-Object DisplayName, MembershipRule, MembershipRuleProcessingState
   ```
   ProcessingState should be `On`. If `Paused`, the group has too many members — contact Microsoft Support.

### Phase 3 — Profile Assigned but Not Applying at OOBE

1. Collect OOBE network trace. On the device during OOBE, open Event Viewer (Shift+F10 → `eventvwr.msc`):
   - **Applications and Services Logs → Microsoft → Windows → ModernDeployment-Diagnostics-Provider**
   - Look for "Profile received" or "No profile" events
2. Check Autopilot diagnostics log:
   ```
   Shift+F10 during OOBE → cmd
   cd %WINDIR%\System32\winevt\Logs
   ```
   Or post-enrollment: `C:\Windows\ServiceProfiles\NetworkService\AppData\Roaming\Microsoft\Windows\Autopilot\`
3. Verify the device can reach Autopilot endpoints:
   - `cs.dds.microsoft.com` — profile delivery
   - `enterpriseregistration.windows.net` — MDM enrollment
   - `login.microsoftonline.com` — auth
   - `*.do.dsp.mp.microsoft.com` — Windows Update (ESP phase)
4. If profile received but incorrect: verify profile version hasn't been superseded by another profile assignment from a higher-priority group.

### Phase 4 — Correct Profile Received but Wrong Behaviour

1. Compare expected profile settings vs actual:
   ```powershell
   Get-MgDeviceManagementWindowsAutopilotDeploymentProfile -WindowsAutopilotDeploymentProfileId "<profileId>" |
       Select-Object DisplayName, OutOfBoxExperienceSettings, EnrollmentStatusScreenSettings
   ```
2. Check Enrollment Status Page (ESP) settings — if ESP is too restrictive and the profile doesn't exempt critical apps, OOBE will appear "stuck" even though profile is working.
3. Verify language/region settings in profile are not forcing a region mismatch that re-triggers OOBE screens.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Re-register device with correct Group Tag</summary>

**When to use:** Device hash registered without Group Tag, or Group Tag typo.

```powershell
# Step 1: Find the device
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All"
$serial = "<DeviceSerial>"
$apDevice = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -Filter "contains(serialNumber,'$serial')"

# Step 2: Update the Group Tag (no re-registration needed if device is found)
$params = @{
    groupTag = "CorrectGroupTag"
}
Update-MgDeviceManagementWindowsAutopilotDeviceIdentityDeviceProperty `
    -WindowsAutopilotDeviceIdentityId $apDevice.Id `
    -BodyParameter $params

# Step 3: Wait 30-60 min for dynamic group to re-evaluate, then verify
Start-Sleep -Seconds 1800
Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -WindowsAutopilotDeviceIdentityId $apDevice.Id |
    Select-Object GroupTag, DeploymentProfileAssignmentStatus
```

**Rollback:** Update Group Tag back to original value. No device action required.

</details>

<details><summary>Playbook 2 — Delete duplicate Autopilot registrations</summary>

**When to use:** Same serial appears multiple times in Autopilot device list; profile assignment is inconsistent.

```powershell
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All"
$serial = "<DeviceSerial>"

# Get all registrations for this serial
$duplicates = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All |
    Where-Object { $_.SerialNumber -eq $serial }

Write-Host "Found $($duplicates.Count) registration(s)"
$duplicates | Select-Object Id, SerialNumber, GroupTag, LastContactedDateTime, DeploymentProfileAssignmentStatus

# Keep the most recent / correct one, delete the rest
$toDelete = $duplicates | Sort-Object LastContactedDateTime | Select-Object -SkipLast 1

foreach ($d in $toDelete) {
    Write-Host "Deleting: $($d.Id) (last contact: $($d.LastContactedDateTime))"
    Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -WindowsAutopilotDeviceIdentityId $d.Id
}
```

**Rollback:** Re-register the deleted hash if needed. Deletion is not reversible without re-uploading the hash.

⚠️ **Warning:** Deleting an Autopilot registration while the device is enrolled will not unenroll it — only removes the pre-registration. Safe to do for devices not yet through OOBE.

</details>

<details><summary>Playbook 3 — Bulk import devices with Group Tag from CSV</summary>

**When to use:** Large batch registration; need to ensure all devices get the correct tag.

```powershell
<#
  Expected CSV format:
  SerialNumber,GroupTag
  SN123456,Corp-Laptops
  SN789012,Corp-Desktops
#>

Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All"
$csv = Import-Csv -Path "C:\devices.csv"

foreach ($row in $csv) {
    $existing = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All |
        Where-Object { $_.SerialNumber -eq $row.SerialNumber }
    
    if ($existing) {
        # Update group tag on existing registration
        $params = @{ groupTag = $row.GroupTag }
        Update-MgDeviceManagementWindowsAutopilotDeviceIdentityDeviceProperty `
            -WindowsAutopilotDeviceIdentityId $existing.Id `
            -BodyParameter $params
        Write-Host "Updated: $($row.SerialNumber) → $($row.GroupTag)"
    } else {
        Write-Warning "Not found in Autopilot: $($row.SerialNumber)"
    }
}
```

</details>

<details><summary>Playbook 4 — Assign profile to a static group as fallback</summary>

**When to use:** Dynamic group rule issues are unresolved; need immediate profile assignment for upcoming deployment.

```powershell
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All", "Group.ReadWrite.All"

# Create a static Autopilot group
$groupParams = @{
    displayName     = "Autopilot-StaticFallback"
    mailEnabled     = $false
    mailNickname    = "autopilot-static-fallback"
    securityEnabled = $true
    groupTypes      = @()  # empty = static
}
$group = New-MgGroup -BodyParameter $groupParams

# Add the Autopilot device (via its Entra ID device object)
$deviceId = "<EntraDeviceObjectId>"
$ref = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$deviceId" }
New-MgGroupMemberByRef -GroupId $group.Id -BodyParameter $ref

# Now assign the deployment profile to this group via Intune portal
# (Portal: Devices → Enroll devices → Deployment profiles → <profile> → Assignments → Add group)
Write-Host "Group created: $($group.Id) — assign profile to this group in Intune portal"
```

**Rollback:** Remove device from static group; dynamic group assignment will take over within 30 min.

</details>

---

## Evidence Pack

Run this script to collect all relevant evidence before escalating to Microsoft Support or senior escalation.

```powershell
<#
.SYNOPSIS    Collect Autopilot profile assignment evidence for escalation
.NOTES       Requires: Microsoft.Graph.DeviceManagement module, Intune Admin role
#>
param(
    [Parameter(Mandatory)][string]$SerialNumber,
    [string]$OutputPath = "C:\AutopilotEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All", "Device.Read.All", "Group.Read.All"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# 1. Autopilot device registration
$apDevice = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All |
    Where-Object { $_.SerialNumber -eq $SerialNumber }
$apDevice | ConvertTo-Json -Depth 5 | Out-File "$OutputPath\1_AutopilotDeviceRegistration.json"

# 2. Entra ID device object
if ($apDevice.AzureActiveDirectoryDeviceId) {
    $entraDevice = Get-MgDevice -Filter "deviceId eq '$($apDevice.AzureActiveDirectoryDeviceId)'"
    $entraDevice | ConvertTo-Json -Depth 5 | Out-File "$OutputPath\2_EntraDeviceObject.json"
    
    # Group memberships
    Get-MgDeviceMemberOf -DeviceId $entraDevice.Id |
        Select-Object Id, @{N='Name';E={$_.AdditionalProperties['displayName']}}, @{N='Type';E={$_.'@odata.type'}} |
        ConvertTo-Json | Out-File "$OutputPath\3_DeviceGroupMemberships.json"
}

# 3. All deployment profiles and assignments
$profiles = Get-MgDeviceManagementWindowsAutopilotDeploymentProfile
$profileData = foreach ($p in $profiles) {
    $assignments = Get-MgDeviceManagementWindowsAutopilotDeploymentProfileAssignment `
        -WindowsAutopilotDeploymentProfileId $p.Id
    [PSCustomObject]@{
        ProfileId   = $p.Id
        ProfileName = $p.DisplayName
        Mode        = $p.OutOfBoxExperienceSettings.AdditionalProperties
        AssignedGroups = $assignments.Target | ForEach-Object { $_.AdditionalProperties['groupId'] }
    }
}
$profileData | ConvertTo-Json -Depth 5 | Out-File "$OutputPath\4_DeploymentProfiles.json"

# 4. Dynamic groups with devicePhysicalIds rules
Get-MgGroup -All | Where-Object { $_.MembershipRule -match "devicePhysicalIds" } |
    Select-Object Id, DisplayName, MembershipRule, MembershipRuleProcessingState |
    ConvertTo-Json | Out-File "$OutputPath\5_AutopilotDynamicGroups.json"

# Summary
Write-Host "`n=== EVIDENCE SUMMARY ===" -ForegroundColor Cyan
Write-Host "Device Serial      : $SerialNumber"
Write-Host "Autopilot Records  : $($apDevice.Count)"
Write-Host "Group Tag          : $($apDevice.GroupTag)"
Write-Host "Profile Status     : $($apDevice.DeploymentProfileAssignmentStatus)"
Write-Host "Entra Device ID    : $($apDevice.AzureActiveDirectoryDeviceId)"
Write-Host "`nEvidence saved to: $OutputPath"
```

**Escalation ticket template:**
```
Subject: Autopilot Profile Not Assigned — [TenantName] — [Ticket#]

Tenant ID        : <tenantId>
Serial Number    : <serial>
Registration Date: <date>
Group Tag        : <groupTag>
Expected Profile : <profileName>
Assigned Profile : notAssigned / <wrongProfile>

Steps already taken:
[ ] Confirmed hash registered (Get-MgDeviceManagementWindowsAutopilotDeviceIdentity)
[ ] Confirmed Entra device object exists (devicePhysicalIds verified)
[ ] Dynamic group rule verified (syntax matches Group Tag exactly)
[ ] Waited 90+ minutes after registration
[ ] Deleted duplicates (if present)
[ ] Tested with static group assignment (successful / failed)

Evidence attached: AutopilotEvidence_*.zip
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Find device by serial | `Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -Filter "contains(serialNumber,'SN')"` |
| Check profile assignment status | `$apDevice.DeploymentProfileAssignmentStatus` |
| Update Group Tag | `Update-MgDeviceManagementWindowsAutopilotDeviceIdentityDeviceProperty -WindowsAutopilotDeviceIdentityId $id -BodyParameter @{groupTag='Tag'}` |
| Check device's Entra groups | `Get-MgDeviceMemberOf -DeviceId $entraDevice.Id` |
| Check device physical IDs | `(Get-MgDevice -Filter "deviceId eq '$id'").PhysicalIds` |
| List all deployment profiles | `Get-MgDeviceManagementWindowsAutopilotDeploymentProfile` |
| List dynamic groups with AP rules | `Get-MgGroup -All \| Where-Object { $_.MembershipRule -match "devicePhysicalIds" }` |
| Delete duplicate registration | `Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -WindowsAutopilotDeviceIdentityId $id` |
| Re-upload hash from device | `Get-WindowsAutopilotInfo -Online` (requires Get-WindowsAutopilotInfo script) |
| Collect OOBE logs on device | Shift+F10 at OOBE → `mdmdiagnosticstool.exe -area Autopilot -cab C:\ap_diag.cab` |

---

## 🎓 Learning Pointers

- **Dynamic group rules for Autopilot use `devicePhysicalIds`, not standard device attributes.** Rules like `device.operatingSystem -eq "Windows"` do not apply to Autopilot device objects during OOBE — the device hasn't enrolled yet and has no OS attribute. Only `[OrderID]`, `[ZTDID]`, `[GID]`, and `[HWID]` physical ID tags work. See: [Dynamic group rules for Autopilot devices](https://learn.microsoft.com/en-us/mem/autopilot/enrollment-autopilot#create-an-autopilot-device-group-using-intune)

- **Group Tag is case-sensitive end-to-end.** The string `Corp-Laptops` will not match a rule targeting `corp-laptops`. Always standardise casing in your Group Tag naming convention before deployment at scale.

- **Multiple profiles can match a device; priority order matters.** If a device is in two groups and both have profiles assigned, the profile assigned to the group with the lower Intune assignment filter precedence wins. Use the "Intune Enrollment > Windows Autopilot Deployment Profiles > Priority" view to understand resolution order.

- **Autopilot device objects and joined device objects are separate.** Before OOBE completes, the Autopilot object and the Entra ID device object are loosely linked. After enrollment, they merge into one Intune-managed device. Profile assignment issues before and after this merger have different root causes.

- **`mdmdiagnosticstool.exe -area Autopilot`** is the fastest way to collect full OOBE + MDM enrollment diagnostics from a device that completed (or failed) OOBE. Run it from an admin cmd prompt post-enrollment: `mdmdiagnosticstool.exe -area Autopilot;DeviceEnrollment -cab C:\diag.cab`

- **Pre-provisioning ("White Glove") has an additional check.** The profile must explicitly have "Allow pre-provisioned deployment" set to Yes, **and** the Technician phase must complete without error. A profile correctly assigned for standard user-driven enrollment will silently fail pre-provisioning if this flag is off. See: [Pre-provision Autopilot](https://learn.microsoft.com/en-us/mem/autopilot/pre-provision)
