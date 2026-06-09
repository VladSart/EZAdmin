# Conditional Access — Device Filters Reference Runbook (Mode A: Deep Dive)
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

**Applies to:** Microsoft Entra ID (Azure AD) Conditional Access with Device Filters; Microsoft 365 E3/E5 or Entra ID P1/P2  
**Role required:** Conditional Access Administrator or Global Administrator (to create/modify policies); Security Reader (to view/audit)  
**Does not cover:** Legacy device-based CA conditions (device compliance/hybrid join toggles), Named Locations (see `Named-Locations-A.md`), CA authentication context

**What are Device Filters?**  
Device Filters in Conditional Access are rule expressions that target (include or exclude) devices based on their Entra ID device object attributes. They use a filter query language similar to OData filtering, and are evaluated at sign-in time against the device object in Entra ID. Unlike the older "Require compliant device" toggle, filters give you granular targeting — e.g., "only Autopilot-enrolled devices," "exclude Privileged Access Workstations," or "only devices running a specific OS version."

---

## How It Works

<details><summary>Full architecture</summary>

### How Device Filters Are Evaluated

```
User Sign-in Attempt
        │
        ▼
Entra ID Authentication Engine
        │
        ├── Evaluates ALL active CA policies in order
        │
        └── For each policy with a Device Filter condition:
                │
                ▼
        Entra ID fetches Device Object
                │  (from Entra ID device registry)
                │
                ▼
        Evaluates filter expression against device attributes
                │
                ├── Filter matches + Mode = Include → Policy APPLIES to this device
                ├── Filter matches + Mode = Exclude → Device is EXCLUDED from policy
                └── Filter does not match → Policy does not apply to this device

Result: Access granted, blocked, or MFA/compliant required per policy
```

### Filter Query Language
Device filters use the Rule Builder or direct expression syntax. The expression is evaluated against the Entra ID device object properties.

**Supported properties for filtering:**

| Property | Type | Example Values |
|----------|------|----------------|
| `device.deviceId` | String (GUID) | `"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"` |
| `device.displayName` | String | `"LAPTOP-001"` |
| `device.operatingSystem` | String | `"Windows"`, `"iOS"`, `"Android"`, `"macOS"` |
| `device.operatingSystemVersion` | String | `"10.0.19041.0"` |
| `device.isCompliant` | Boolean | `true`, `false` |
| `device.trustType` | String | `"AzureAD"`, `"Hybrid"`, `"ServerAD"` |
| `device.extensionAttribute1-15` | String | Custom values set on device object |
| `device.isManaged` | Boolean | `true`, `false` |
| `device.manufacturer` | String | `"Microsoft"`, `"Dell"`, `"Apple"` |
| `device.model` | String | `"Surface Pro 9"`, `"MacBook Pro"` |
| `device.physicalIds` | String (multi-value) | `[ZTDID]:...`, `[OrderId]:...`, `[PurchaseOrder]:...` |
| `device.profileType` | String | `"RegisteredDevice"`, `"SecureVM"`, `"Printer"` |
| `device.systemLabels` | String (multi-value) | `"Compliant"`, `"M365Managed"` |
| `device.deviceOwnership` | String | `"Company"`, `"Personal"` |
| `device.enrollmentProfileName` | String | Autopilot profile name |
| `device.isRooted` | Boolean | `true`, `false` |

**Supported operators:**
- `eq` — equals
- `ne` — not equals
- `startsWith` — string starts with
- `endsWith` — string ends with
- `contains` — string contains
- `-in` — value in list
- `and`, `or`, `not` — logical operators
- `-any` / `-all` — for multi-value properties like `physicalIds`, `systemLabels`

### Filter Mode: Include vs Exclude

**Include mode:** The policy applies *only* to devices matching the filter.  
**Exclude mode:** The policy applies to *all* devices *except* those matching the filter (effectively a carve-out).

```
Policy: "Block legacy auth"
├── Users: All
├── Apps: All
├── Device Filter (Exclude): device.extensionAttribute1 -eq "PAW"
└── Grant: Block

Effect: Blocks legacy auth for everyone EXCEPT devices tagged as PAW.
```

### physicalIds for Autopilot Targeting
The `device.physicalIds` attribute is a multi-value string array populated by Autopilot during device registration. It contains hardware hash-derived identifiers:

```
[ZTDID]:<ZeroTouchDeploymentId>
[OrderId]:<OrderId>
[PurchaseOrder]:<PONumber>
[GID]:<GroupTag>
```

To target Autopilot-enrolled devices:
```
device.physicalIds -any (_ -startsWith "[ZTDID]")
```

To target devices with a specific Autopilot group tag:
```
device.physicalIds -any (_ -eq "[OrderId]:PAW-GROUP")
```

</details>

---

## Dependency Stack

```
Entra ID CA Policy Engine
        │
        ├──► Device Object in Entra ID
        │       └── Attributes populated by:
        │           ├── Intune enrollment (isCompliant, isManaged, enrollmentProfileName)
        │           ├── Autopilot registration (physicalIds)
        │           ├── Entra Join / Hybrid Join (trustType)
        │           ├── Admin-set extensions (extensionAttribute1-15)
        │           └── MDM reports (manufacturer, model, OS version)
        │
        └──► Policy Assignment
                ├── Users/Groups (included/excluded)
                ├── Apps (cloud apps or All)
                ├── Conditions (sign-in risk, device platforms, etc.)
                └── Device Filter (the focus of this runbook)
```

**Key dependency:** Device filter evaluation requires the device object to exist in Entra ID and be up-to-date. A device that is not registered/joined will not have a device object — filters will never match. The policy will then apply as if no device filter exists (or not apply, depending on other conditions).

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| CA policy with device filter applying to wrong devices | Filter expression evaluates incorrectly; attribute not populated | Use What If tool with specific device; check device object attributes |
| CA policy not applying to Autopilot devices | `physicalIds` not populated; device not yet registered in Autopilot | `Get-MgDevice -DeviceId <id> \| Select-Object PhysicalIds` |
| Policy applies to PAW devices it should exclude | Filter mode is Include instead of Exclude | Review policy filter mode in Entra portal |
| `extensionAttribute` filter not matching | Attribute value not set on device object; case mismatch | `Get-MgDevice -DeviceId <id> \| Select-Object AdditionalProperties` |
| Filter works for some users but not others | Users sign in from different registered devices; shared device issue | Check What If for each user; verify device object per user |
| Filter targeting by `manufacturer` not working | Attribute value differs from expected (e.g. `"LENOVO"` vs `"Lenovo"`) | Check actual attribute value on device object |
| "What If" shows wrong result | Stale device data in What If tool; What If doesn't simulate real-time sync | Wait for device sync; test with actual sign-in in sign-in logs |
| iOS/Android device filter not matching | Devices not enrolled in Intune; `isManaged = false` | `Get-MgDevice -Filter "operatingSystem eq 'iOS'"` |
| Policy supposed to block unmanaged devices but managed devices are also blocked | Missing device filter or filter condition inverted | Review filter; consider Exclude mode for managed devices |

---

## Validation Steps

**1. Check the device object attributes for a specific device**
```powershell
Connect-MgGraph -Scopes "Device.Read.All"

$deviceId = "<DeviceObjectId-from-Entra>"  # NOT the Intune device ID
$device = Get-MgDevice -DeviceId $deviceId
$device | Select-Object DisplayName, OperatingSystem, OperatingSystemVersion,
    IsCompliant, IsManaged, TrustType, DeviceOwnership, ProfileType, Manufacturer, Model,
    EnrollmentProfileName, PhysicalIds, SystemLabels
```

**2. Check extensionAttributes on a device**
```powershell
$device = Get-MgDevice -DeviceId $deviceId -Property "id,displayName,extensionAttributes"
$device.AdditionalProperties.extensionAttributes
```

**3. Verify Autopilot physicalIds are populated**
```powershell
$device = Get-MgDevice -DeviceId $deviceId -Property "physicalIds"
$device.PhysicalIds
# Look for entries starting with [ZTDID], [OrderId], [GID], [PurchaseOrder]
```

**4. Use the CA What If tool (PowerShell)**
```powershell
# Install if needed: Install-Module Microsoft.Graph.Beta -Scope CurrentUser
Connect-MgGraph -Scopes "Policy.Read.All"

# What If evaluation for a specific user + device
$params = @{
    UserId = "<UserObjectId>"
    IpAddress = "0.0.0.0"
    ClientAppType = "browser"
    SignInRiskLevel = "none"
    DeviceInfo = @{
        DeviceId = "<DeviceObjectId>"
        OperatingSystem = "Windows"
        OperatingSystemVersion = "10.0.22000.0"
    }
}
# Note: Full What If via PowerShell uses beta Graph; use the Entra portal What If for interactive testing
```

**5. Review sign-in logs for CA filter evaluation**
```powershell
Connect-MgGraph -Scopes "AuditLog.Read.All"

Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<user@domain>'" -Top 10 |
    Select-Object CreatedDateTime, UserPrincipalName, AppDisplayName,
    @{N="CA Result";E={$_.ConditionalAccessStatus}},
    @{N="Device";E={$_.DeviceDetail.DisplayName}},
    @{N="Applied Policies";E={($_.AppliedConditionalAccessPolicies | Select-Object -ExpandProperty DisplayName) -join ", "}}
```

**6. Find devices matching a filter expression (test before applying to policy)**
```powershell
# Find all Autopilot-enrolled devices
Get-MgDevice -Filter "physicalIds/any(x:startsWith(x,'[ZTDID]'))" -All |
    Select-Object DisplayName, PhysicalIds, IsCompliant | Format-Table -AutoSize

# Find devices with extensionAttribute1 = "PAW"
Get-MgDevice -Filter "extensionAttributes/extensionAttribute1 eq 'PAW'" -All |
    Select-Object DisplayName, IsCompliant | Format-Table -AutoSize
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Validate Device Object State
1. Confirm the device is registered in Entra ID: `Get-MgDevice -Filter "displayName eq '<DEVICE-NAME>'"`.
2. Check `lastActivityDateTime` — stale device objects may have outdated attributes.
3. Verify `trustType` — `AzureAD` (Entra-joined), `Hybrid` (hybrid join), `ServerAD` (on-prem only, not usable for CA filters).
4. Verify `isCompliant` and `isManaged` reflect current Intune state.

### Phase 2: Validate Filter Expression Syntax
1. Use the Entra portal Rule Builder to construct filter expressions interactively — it validates syntax before saving.
2. Test filter expression against known devices using `Get-MgDevice -Filter "..."` before applying to a policy.
3. Watch for case sensitivity: `operatingSystem eq 'Windows'` — values are case-insensitive for most string properties, but verify with actual attribute values.
4. For `physicalIds` and `systemLabels` (multi-value), use `-any` or `-all` operators.

### Phase 3: Validate Policy Assignment and Mode
1. Open the policy in Entra portal → Conditions → Filter for devices.
2. Confirm **Mode** (Include/Exclude) is correct for the intended behaviour.
3. Check user/group assignment — filters are ANDed with all other conditions.
4. Use the **What If** tool in the Entra portal with a specific user + device to simulate policy outcome.

### Phase 4: Check Sign-In Logs for Mismatch
1. Filter sign-in logs for the affected user.
2. Look at `AppliedConditionalAccessPolicies` — each policy shows `success`, `failure`, or `notApplied`.
3. Expand policy detail → `conditionsNotSatisfied` or `conditionsSatisfied` to see why the filter matched or didn't.

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Set extensionAttribute on device objects for PAW/role targeting</summary>

Use when: Targeting specific device roles (PAW, Kiosk, Shared) via filter without Autopilot group tags.

```powershell
Connect-MgGraph -Scopes "Device.ReadWrite.All"

$deviceId = "<DeviceObjectId>"

# Set extensionAttribute1 = "PAW" on the device
$params = @{
    extensionAttributes = @{
        extensionAttribute1 = "PAW"
    }
}
Update-MgDevice -DeviceId $deviceId -BodyParameter $params

# Verify
$device = Get-MgDevice -DeviceId $deviceId -Property "extensionAttributes"
$device.AdditionalProperties.extensionAttributes.extensionAttribute1
```

**Bulk set for a list of devices:**
```powershell
$deviceNames = @("LAPTOP-001", "LAPTOP-002", "LAPTOP-003")
foreach ($name in $deviceNames) {
    $device = Get-MgDevice -Filter "displayName eq '$name'"
    if ($device) {
        Update-MgDevice -DeviceId $device.Id -BodyParameter @{
            extensionAttributes = @{ extensionAttribute1 = "PAW" }
        }
        Write-Host "Tagged: $name" -ForegroundColor Green
    } else {
        Write-Host "Not found: $name" -ForegroundColor Red
    }
}
```

</details>

<details>
<summary>Fix 2 — Create a CA policy that excludes Privileged Access Workstations</summary>

Use when: Blocking risky sign-ins everywhere except designated PAW devices.

```powershell
# Prerequisites: extensionAttribute1 = "PAW" set on PAW devices (Fix 1)
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$policyBody = @{
    displayName = "Block Legacy Auth - Exclude PAW"
    state = "enabledForReportingButNotEnforced"  # Start in report-only; change to "enabled" after validation
    conditions = @{
        users = @{
            includeUsers = @("All")
        }
        clientAppTypes = @("exchangeActiveSync", "other")  # Legacy auth
        devices = @{
            deviceFilter = @{
                mode = "exclude"
                rule = 'device.extensionAttribute1 -eq "PAW"'
            }
        }
    }
    grantControls = @{
        operator = "OR"
        builtInControls = @("block")
    }
}

New-MgIdentityConditionalAccessPolicy -BodyParameter $policyBody
```

**Rollback:** Set policy `state` to `"disabled"`:
```powershell
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId "<PolicyId>" `
    -BodyParameter @{ state = "disabled" }
```

</details>

<details>
<summary>Fix 3 — Create a CA policy targeting only Autopilot devices</summary>

Use when: Applying a policy only to corporate-owned Autopilot-registered devices.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$policyBody = @{
    displayName = "Require Compliant Device - Autopilot Only"
    state = "enabledForReportingButNotEnforced"
    conditions = @{
        users = @{ includeUsers = @("All") }
        applications = @{ includeApplications = @("All") }
        devices = @{
            deviceFilter = @{
                mode = "include"
                rule = "device.physicalIds -any (_ -startsWith `"[ZTDID]`")"
            }
        }
    }
    grantControls = @{
        operator = "OR"
        builtInControls = @("compliantDevice")
    }
}

New-MgIdentityConditionalAccessPolicy -BodyParameter $policyBody
```

</details>

<details>
<summary>Fix 4 — Repair filter expression (wrong mode or expression)</summary>

Use when: Policy applying to wrong devices; filter mode or expression incorrect.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$policyId = "<PolicyObjectId>"

# View current filter
$policy = Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId
$policy.Conditions.Devices.DeviceFilter | ConvertTo-Json

# Update filter mode and expression
$updatedFilter = @{
    conditions = @{
        devices = @{
            deviceFilter = @{
                mode = "exclude"                       # Change to "include" or "exclude"
                rule = 'device.extensionAttribute1 -eq "PAW"'  # Updated expression
            }
        }
    }
}

Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policyId `
    -BodyParameter $updatedFilter
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects CA device filter evidence for troubleshooting escalation
.NOTES     Run as Entra ID admin; requires Microsoft.Graph modules
#>
Connect-MgGraph -Scopes "Policy.Read.All","Device.Read.All","AuditLog.Read.All"

$outFile = "C:\Temp\CA-Filter-Evidence-$(Get-Date -Format yyyyMMdd-HHmm).txt"
New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null

{
    "=== CA Device Filter Evidence — $(Get-Date) ==="

    "`n--- CA Policies with Device Filters ---"
    Get-MgIdentityConditionalAccessPolicy -All |
        Where-Object { $_.Conditions.Devices.DeviceFilter } |
        ForEach-Object {
            "Policy: $($_.DisplayName) | State: $($_.State)"
            "  Filter Mode: $($_.Conditions.Devices.DeviceFilter.Mode)"
            "  Filter Rule: $($_.Conditions.Devices.DeviceFilter.Rule)"
            ""
        }

    "`n--- Device Object Details (Replace with target device) ---"
    # $deviceId = "<DeviceObjectId>"
    # Get-MgDevice -DeviceId $deviceId | Format-List

    "`n--- Recent Sign-Ins with CA Results (last 20) ---"
    Get-MgAuditLogSignIn -Top 20 |
        Select-Object CreatedDateTime, UserPrincipalName, AppDisplayName,
        ConditionalAccessStatus,
        @{N="Device";E={$_.DeviceDetail.DisplayName}},
        @{N="Applied CA";E={($_.AppliedConditionalAccessPolicies.DisplayName) -join "; "}} |
        Format-Table -AutoSize

} | ForEach-Object { $_ } | Out-File $outFile -Encoding UTF8

Write-Host "Evidence saved: $outFile" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| List all CA policies with device filters | `Get-MgIdentityConditionalAccessPolicy -All \| Where { $_.Conditions.Devices.DeviceFilter }` |
| Get device object by name | `Get-MgDevice -Filter "displayName eq 'DEVICE-NAME'"` |
| Get device extensionAttributes | `Get-MgDevice -DeviceId <id> -Property "extensionAttributes"` |
| Get device physicalIds (Autopilot) | `Get-MgDevice -DeviceId <id> \| Select-Object PhysicalIds` |
| Set extensionAttribute on device | `Update-MgDevice -DeviceId <id> -BodyParameter @{extensionAttributes=@{extensionAttribute1="PAW"}}` |
| Find devices matching filter | `Get-MgDevice -Filter "extensionAttributes/extensionAttribute1 eq 'PAW'" -All` |
| Find Autopilot devices | `Get-MgDevice -Filter "physicalIds/any(x:startsWith(x,'[ZTDID]'))" -All` |
| Create CA policy | `New-MgIdentityConditionalAccessPolicy -BodyParameter $policyBody` |
| Update CA policy filter | `Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId <id> -BodyParameter $update` |
| Disable CA policy | `Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId <id> -BodyParameter @{state="disabled"}` |
| View sign-in CA evaluation | `Get-MgAuditLogSignIn -Filter "userPrincipalName eq 'user@domain'"` |
| Enable report-only mode | Set policy `state = "enabledForReportingButNotEnforced"` |

---

## 🎓 Learning Pointers

- **Always start in report-only mode:** CA policies with device filters can inadvertently block users if the filter expression is wrong. Always set `state = "enabledForReportingButNotEnforced"` when creating or modifying a policy. Use the Entra sign-in logs to validate the filter is behaving as expected before enabling enforcement. [Microsoft: CA report-only mode](https://docs.microsoft.com/en-us/azure/active-directory/conditional-access/concept-conditional-access-report-only)

- **Device filters vs. Device compliance conditions:** The older CA approach uses "Require compliant device" as a grant control — this applies to any device. Device filters are more surgical: you can require compliance only for specific device types, or exclude certain devices entirely. Use filters when you need per-device-group policies; use compliance grant controls for blanket requirements. [Microsoft: Device filter conditions](https://docs.microsoft.com/en-us/azure/active-directory/conditional-access/concept-condition-filters-for-devices)

- **extensionAttributes are powerful but manual:** Unlike Autopilot `physicalIds` (auto-populated) or `isCompliant` (Intune-managed), `extensionAttribute1-15` must be set manually or via automation. Build a script or Intune remediation to maintain these attributes, or they'll drift as devices are reimaged or re-enrolled. [Manage device extensionAttributes via Graph](https://docs.microsoft.com/en-us/graph/api/device-update)

- **physicalIds for Autopilot targeting is the most reliable corporate device filter:** Because `physicalIds` includes `[ZTDID]` only for Autopilot-registered devices, filtering on `device.physicalIds -any (_ -startsWith "[ZTDID]")` precisely targets corporate-owned Autopilot devices without relying on manually maintained attributes. This is the recommended pattern for "corporate device" CA policies in Autopilot environments.

- **The What If tool is your best pre-deployment test:** In the Entra portal → Security → Conditional Access → What If, you can simulate a sign-in as any user from any device and see exactly which policies would apply, which would block, and why. Use it exhaustively before taking any filter-based policy out of report-only mode. [Entra CA What If tool](https://docs.microsoft.com/en-us/azure/active-directory/conditional-access/what-if-tool)

- **Device filter evaluation requires an up-to-date device object:** If a device was re-enrolled or re-imaged recently, its Entra ID device object attributes (especially Intune-sourced ones like `isCompliant`, `isManaged`) may be stale by up to 15 minutes. For filters based on Intune compliance, there can be a gap between compliance state change and CA enforcement. This is expected behaviour, not a bug. [Entra device sync latency](https://docs.microsoft.com/en-us/azure/active-directory/devices/troubleshoot-device-dsregcmd)
