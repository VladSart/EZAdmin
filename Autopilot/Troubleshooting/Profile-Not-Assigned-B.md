# Autopilot Profile Not Assigned — Hotfix Runbook (Mode B: Ops)

> Fix or escalate in under 10 minutes. Device reaches OOBE but no Autopilot profile is applied.

---

## Skim Index
- [Triage (60 sec)](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis Flow](#diagnosis--validation-flow)
- [Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

```powershell
# Run from OOBE shell (Shift+F10 → PowerShell)
# Or from a working machine to check the device in the portal

# 1. Check if device hash is registered in Autopilot
# From a machine with Graph access:
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All"
Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All |
  Where-Object { $_.SerialNumber -eq "<DeviceSerial>" } |
  Select SerialNumber, Model, GroupTag, DeploymentProfileAssignmentStatus, `
         DeploymentProfileAssignedDateTime, DeploymentProfileAssignmentDetailedStatus

# 2. Check internet connectivity to Autopilot endpoints (from OOBE shell)
Test-NetConnection ztd.dds.microsoft.com -Port 443
Test-NetConnection cs.dds.microsoft.com -Port 443
Test-NetConnection login.microsoftonline.com -Port 443

# 3. Collect Autopilot diagnostics from OOBE device
mdmdiagnosticstool.exe -area Autopilot -zip C:\AutopilotDiags.zip

# 4. Check Autopilot event log from OOBE device
Get-WinEvent -LogName "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot" `
  -MaxEvents 30 | Select TimeCreated, Id, Message | Format-Table -Wrap
```

**Interpret:**
| Result | Likely cause | Go to |
|--------|-------------|-------|
| Device not found by serial number in Autopilot | Hash never uploaded, or uploaded to wrong tenant | [Fix 1](#fix-1--hash-not-registered-or-wrong-tenant) |
| Device found, `GroupTag` is empty | Group tag never set — dynamic group won't match | [Fix 2](#fix-2--group-tag-missing-or-wrong) |
| Device found, group tag correct, `DeploymentProfileAssignmentStatus` = `unknown` | Dynamic group has not evaluated yet | [Fix 3](#fix-3--dynamic-group-not-evaluating) |
| Device found, profile assigned, but not applying in OOBE | Network blocked; device reaching wrong tenant | [Fix 4](#fix-4--network-blocking-autopilot-endpoints) |
| Device found, `DeploymentProfileAssignmentStatus` = `notAssigned` | Profile not assigned to the group the device is in | [Fix 5](#fix-5--profile-not-assigned-to-group) |
| `Test-NetConnection` to `ztd.dds.microsoft.com` fails | Firewall/proxy blocking Autopilot registration endpoints | [Fix 4](#fix-4--network-blocking-autopilot-endpoints) |
| Device was previously enrolled in a different tenant | Stale device object; re-registration needed | [Fix 6](#fix-6--device-previously-enrolled-in-different-tenant) |

---

## Dependency Cascade

<details><summary>What must succeed for a profile to be delivered in OOBE</summary>

```
Hardware hash extracted from device
    → Hash uploaded to Intune Autopilot devices
        (via Get-WindowsAutoPilotInfo, OEM upload, or CSV import)
    → Device registered in the correct tenant
    → Group tag assigned to device (manually or via OEM/hash upload)
    → Entra dynamic group query evaluates the group tag
        → Device added to dynamic group
        → Dynamic group membership update can take 5–30 min
    → Deployment profile assigned to that dynamic group
    → Device powers on and reaches OOBE
    → Device makes HTTPS call to ztd.dds.microsoft.com + cs.dds.microsoft.com
    → Microsoft returns the profile to the device
    → OOBE customised (skip screens, enforce AAD join, etc.)
    → Device proceeds with Autopilot provisioning
```

**If any step is missing:** the device reaches OOBE as a plain Windows setup and shows the full Microsoft account/domain join screens — no Autopilot experience.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Check device registration in Intune portal**
```
Intune Admin Center → Devices → Enroll devices → Windows enrollment
→ Windows Autopilot devices
→ Search by serial number or hardware hash
```

If the device is not listed: the hash was never uploaded, or it was uploaded to a different tenant. Go to [Fix 1](#fix-1--hash-not-registered-or-wrong-tenant).

**Step 2 — Check group tag and profile assignment status**
```powershell
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All"
$device = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All |
  Where-Object { $_.SerialNumber -eq "<DeviceSerial>" }

$device | Select SerialNumber, GroupTag, Model, Manufacturer,
  DeploymentProfileAssignmentStatus, DeploymentProfileAssignedDateTime,
  DeploymentProfileAssignmentDetailedStatus | Format-List
```

Key values:
- `GroupTag`: should match your naming convention (e.g., `AP-Corp-Standard`)
- `DeploymentProfileAssignmentStatus`: `assigned` = profile was applied; `notAssigned` = no profile; `unknown` = pending evaluation
- `DeploymentProfileAssignmentDetailedStatus`: gives more context on failures

**Step 3 — Verify dynamic group query**
```
Entra Admin Center → Groups → [Autopilot dynamic group]
→ Dynamic membership rules
→ Typical rule:
    (device.devicePhysicalIds -any (_ -eq "[OrderID]:xxxx"))
    OR
    (device.devicePhysicalIds -any (_ -startsWith "[OrderID]:"))
    OR
    (device.devicePhysicalIds -any (_ -eq "[ZTDId]:<GroupTag>"))

→ Click "Validate Rules" → enter the device's object ID → check if it matches
```

**Step 4 — Check if device is actually in the dynamic group**
```powershell
Connect-MgGraph -Scopes "Group.Read.All","Device.Read.All"
$groupId = "<DynamicGroupObjectId>"
Get-MgGroupMember -GroupId $groupId -All |
  Where-Object { $_.AdditionalProperties.displayName -like "*<DeviceName>*" }
# If device not found: group tag mismatch or group evaluation pending
```

**Step 5 — Test Autopilot endpoint reachability**
```powershell
# Run from the affected device (Shift+F10 in OOBE → PowerShell)
$endpoints = @(
    "ztd.dds.microsoft.com",
    "cs.dds.microsoft.com",
    "login.microsoftonline.com",
    "login.live.com",
    "account.live.com",
    "go.microsoft.com"
)
foreach ($ep in $endpoints) {
    $result = Test-NetConnection $ep -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{
        Endpoint = $ep
        TcpTestSucceeded = $result.TcpTestSucceeded
        PingSucceeded = $result.PingSucceeded
    }
} | Format-Table
```

**Step 6 — Force profile refresh for a registered device**
```powershell
# If device is registered but profile not pushed yet — force refresh from portal:
# Intune → Devices → Windows Autopilot devices → [Device] → Sync
# (Takes 5–10 minutes to propagate to the device)

# Alternatively — force from the device during OOBE if you can get to a shell:
# Refresh does not have a direct command in OOBE; you must restart OOBE
# Hold Shift → Restart → only works if OOBE has not progressed past first screen
```

---

## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — Hash not registered or wrong tenant</summary>

**Option A — Upload hash from the device itself (OOBE shell)**
```powershell
# From OOBE PowerShell (Shift+F10 → PowerShell)
# Device needs internet access for this to work

# Install the script (requires NuGet)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Script -Name Get-WindowsAutoPilotInfo -Force

# Upload hash directly to Intune (requires admin credentials)
Get-WindowsAutoPilotInfo -Online -AddToGroup "<AutopilotGroupName>"
# OR — just capture the hash to a CSV for manual import
Get-WindowsAutoPilotInfo -OutputFile C:\hash.csv
```

**Option B — Import hash from CSV in Intune portal**
```
Intune → Devices → Enroll devices → Windows enrollment → Windows Autopilot devices
→ Import → upload the hash CSV
→ After import: manually set the Group Tag field on the device
→ Wait 5 minutes → check DeploymentProfileAssignmentStatus
```

**Verify tenant is correct before uploading:**
```powershell
# From OOBE shell — check which tenant the device would register against
(Invoke-WebRequest -Uri "https://ztd.dds.microsoft.com/osd/tenant" -UseBasicParsing).Content
# Should return your tenant domain
```

</details>

<details id="fix-2"><summary>Fix 2 — Group tag missing or wrong</summary>

```powershell
# Set or correct the group tag on a registered device
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All"

$device = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All |
  Where-Object { $_.SerialNumber -eq "<DeviceSerial>" }

# Update group tag
Update-MgDeviceManagementWindowsAutopilotDeviceIdentityDeviceProperty `
  -WindowsAutopilotDeviceIdentityId $device.Id `
  -GroupTag "AP-Corp-Standard"

# After updating group tag:
# 1. The dynamic group rule re-evaluates (can take 5–30 min)
# 2. Once in the group, profile is assigned (another few minutes)
# 3. Total wait: up to 30 minutes before the profile is deliverable in OOBE
```

> Note: You cannot set a group tag during OOBE. The device must already have the tag set in Intune before it reaches OOBE for the first time, OR the tag can be set in Intune and the device restarted to re-run OOBE (via Autopilot reset).

</details>

<details id="fix-3"><summary>Fix 3 — Dynamic group not evaluating</summary>

Dynamic group membership in Entra ID is evaluated asynchronously. A newly registered device or a device with a changed group tag can take 5–30 minutes to appear in the group.

```
Entra Admin Center → Groups → [Group] → Members
→ If device not present: wait 10 min, refresh
→ If still not present after 30 min: check the dynamic rule

Manually trigger group evaluation (requires Entra P1 or P2):
Entra Admin Center → Groups → [Group] → Dynamic membership rules
→ Edit → Save (no changes needed — save triggers re-evaluation)

Check for rule syntax errors:
→ Use "Validate Rules" with the specific device to confirm it would match
```

Common dynamic group query mistakes:
```
# Correct format for group tag matching:
(device.devicePhysicalIds -any (_ -eq "[ZTDId]:<GroupTagValue>"))

# Incorrect (quotes wrong or extra spaces):
(device.devicePhysicalIds -any (_ -eq "[ZTDId]: AP-Corp-Standard"))
                                                    ^-- space before value = never matches
```

</details>

<details id="fix-4"><summary>Fix 4 — Network blocking Autopilot endpoints</summary>

```powershell
# Run on-site or from the device in OOBE shell
# Use the network test script in the repo:
# Autopilot/Troubleshooting/Test-AutopilotNetworkRequirements.ps1

# Manual quick test — critical Autopilot registration endpoints:
Test-NetConnection ztd.dds.microsoft.com -Port 443        # Must succeed
Test-NetConnection cs.dds.microsoft.com -Port 443         # Must succeed
Test-NetConnection login.live.com -Port 443               # MSA auth
Test-NetConnection login.microsoftonline.com -Port 443    # AAD auth
Test-NetConnection account.live.com -Port 443             # Account setup
```

Common network issues:
- **Proxy requiring authentication in OOBE** — OOBE cannot authenticate to a proxy. Autopilot must bypass proxy or use WPAD with no-auth zones for Microsoft endpoints.
- **SSL inspection breaking certificate trust** — corporate proxies that intercept TLS will break Autopilot endpoint calls. Add `*.microsoft.com`, `ztd.dds.microsoft.com`, `cs.dds.microsoft.com` to SSL bypass.
- **DNS not resolving Microsoft endpoints** — verify DNS server is reachable and resolves `ztd.dds.microsoft.com`.
- **Captive portal** — hotel/guest networks require browser authentication before internet access is granted. Autopilot cannot complete on a captive portal network.

</details>

<details id="fix-5"><summary>Fix 5 — Profile not assigned to group</summary>

```
Intune → Devices → Enroll devices → Windows enrollment
→ Deployment profiles → [Profile name] → Properties → Assignments
→ Included groups: verify the Autopilot dynamic group is listed
→ Excluded groups: verify device group is not accidentally excluded

If not assigned:
→ Edit → Assignments → Add group → save
→ Allow 10 minutes for propagation
→ Device must reach OOBE after the assignment to receive the profile
```

Also check for profile priority conflicts:
```
If multiple profiles are assigned (e.g., one for All Devices + one for a specific group),
the profile with the highest priority (lowest number) wins.
Intune → Deployment profiles → Priority column
Drag profiles to set correct order.
```

</details>

<details id="fix-6"><summary>Fix 6 — Device previously enrolled in different tenant</summary>

A device registered in a previous tenant's Autopilot cannot be re-used without the previous tenant releasing it or a 30-day wait after deletion.

```powershell
# Symptom: device registered but profile delivery fails with "ZtdDeviceAssignedToOtherTenant"
# Check in the Autopilot diagnostics zip for this error string

# Resolution options:
# Option A — Ask previous MSP/tenant admin to delete the device from their Autopilot list
#   Intune → Devices → Autopilot devices → find device → Delete
#   Then: delete the corresponding Entra device object too

# Option B — Perform a factory reset and wait 30 days
#   After deletion from previous tenant, device cannot be re-registered for 30 days
#   (Microsoft's anti-theft hold period)

# Option C — OEM re-registration
#   If device is new from OEM and was registered to wrong tenant,
#   contact OEM (Dell, HP, Lenovo) with proof of purchase for re-registration
```

</details>

---

## Escalation Evidence

```
Autopilot Profile Not Assigned — Evidence Pack
===============================================
Device serial number:                  
Device model / manufacturer:           
Tenant ID:                             
Hash registered in Intune:             [Yes / No]
Group tag value (current):             
Group tag value (expected):            
Dynamic group object ID:               
Device in dynamic group:               [Yes / No / Pending]
Profile name:                          
Profile assignment status:             [assigned / notAssigned / unknown]
Profile assigned to group:             [Yes / No]
Network test results:
  ztd.dds.microsoft.com 443:           [Pass / Fail]
  cs.dds.microsoft.com 443:            [Pass / Fail]
  login.microsoftonline.com 443:       [Pass / Fail]
Previous tenant / OEM registration:    [Yes / No — if yes, which tenant?]
Autopilot event log errors:            [paste relevant lines]
AutopilotDiags.zip:                    [attach if available]
Time device sat at registration:       [minutes]
```

---

## 🎓 Learning Pointers

- **Group tag is not the same as Order ID** — Group tag (`[ZTDId]`) is a custom string you set on the device in Intune to drive dynamic group membership. Order ID (`[OrderID]`) is set by the OEM during purchase. Both can be used in dynamic group rules but they are different fields. Mixing them up in your dynamic group query is a common source of "profile never assigns". [MS Docs: Group tags](https://learn.microsoft.com/en-us/mem/autopilot/enrollment-autopilot#create-an-autopilot-device-group-using-a-group-tag)
- **Dynamic group evaluation is asynchronous and has no SLA** — Microsoft documents it as "within minutes" but in practice it can take 5–30 minutes, especially in large tenants. After setting or changing a group tag, do not expect the profile to be available immediately. The device needs to be restarted into OOBE *after* the profile is assigned, not before. [MS Docs: Dynamic group rules](https://learn.microsoft.com/en-us/entra/identity/users/groups-dynamic-membership)
- **Autopilot profile delivery happens at the very first OOBE screen** — the device queries `ztd.dds.microsoft.com` once, very early in OOBE, before any user interaction. If the profile is not assigned at that moment, the device boots as a plain Windows setup. You cannot inject a profile mid-OOBE. The device must be reset and re-run OOBE after the profile is properly assigned.
- **Autopilot reset vs clean wipe** — Autopilot reset (`Settings → Recovery → Reset this PC → Keep nothing`) preserves the Autopilot registration and re-runs OOBE with the same device hash. A clean wipe via WinRE (`Shift+Restart → Troubleshoot → Reset`) does the same but from pre-boot. Neither removes the device from Intune Autopilot; the hash stays registered. Use reset to retry a failed provisioning without re-uploading the hash.
- **The 30-day tenant hold exists to prevent theft** — once a device hash is registered in a tenant and then deleted, it cannot be registered in a new tenant for 30 days. This prevents the scenario where a stolen device is factory-reset and re-registered. Budget this time when offboarding devices from one MSP client to another.
