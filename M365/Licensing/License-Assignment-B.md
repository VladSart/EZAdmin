# License Assignment — Hotfix Runbook (Mode B: Ops)
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
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "User.Read.All","Organization.Read.All","Directory.ReadWrite.All"

# 1. Get user's current licenses and service plan status
Get-MgUserLicenseDetail -UserId <UPN> | Select-Object SkuPartNumber, SkuId | Format-Table -AutoSize

# 2. Check for any service plans NOT in "Success" state
Get-MgUserLicenseDetail -UserId <UPN> | ForEach-Object {
    $sku = $_.SkuPartNumber
    $_.ServicePlans | ForEach-Object {
        [PSCustomObject]@{SKU=$sku; ServicePlan=$_.ServicePlanName; Status=$_.ProvisioningStatus}
    }
} | Where-Object {$_.Status -ne "Success"} | Format-Table -AutoSize

# 3. Check tenant-wide license availability
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, @{N="TotalEnabled";E={$_.PrepaidUnits.Enabled}}, @{N="Available";E={$_.PrepaidUnits.Enabled - $_.ConsumedUnits}} | Format-Table -AutoSize

# 4. Check if user has a usage location set (required for license assignment)
Get-MgUser -UserId <UPN> -Property UsageLocation, UserPrincipalName | Select-Object UserPrincipalName, UsageLocation

# 5. Check license assignment errors (GBL or direct)
(Get-MgUser -UserId <UPN> -Property LicenseAssignmentStates).LicenseAssignmentStates | Format-List
```

**Interpretation Table:**

| Symptom | Likely Cause | Go To |
|---------|-------------|-------|
| No licenses shown | User never licensed | Fix 1 |
| Service plan `PendingProvisioning` | License just assigned — wait | Wait 15 min, re-check |
| Service plan `Disabled` | Plan disabled in SKU assignment | Fix 2 |
| `LicenseAssignmentStates.State: Error` | Conflict or seat limit reached | Fix 3 |
| `UsageLocation` is null | Required field missing | Fix 4 |
| `Available` shows 0 for needed SKU | No seats left in tenant | Fix 5 |
| Feature missing even with correct license | Service plan disabled, not plan missing | Fix 2 |

---
## Dependency Cascade

<details><summary>What must be true for a license assignment to succeed</summary>

```
Tenant has the SKU purchased (> 0 seats)
    └── Available seats > 0 (ConsumedUnits < PrepaidUnits.Enabled)
        └── User has UsageLocation set (ISO country code)
            └── No conflicting license preventing assignment
                └── License assigned (directly or via group)
                    └── All required service plans enabled (not manually disabled)
                        └── Provisioning completes (15-30 min for new assignments)
                            └── FEATURE AVAILABLE
```
</details>

---
## Diagnosis & Validation Flow

**Step 1 — Check what the user needs vs what they have**
```powershell
# Common SKU names to look for:
# ENTERPRISEPREMIUM = Microsoft 365 E5
# ENTERPRISEPACK = Microsoft 365 E3
# SPE_E3 = Microsoft 365 E3 (newer SKU name)
# TEAMS_ESSENTIALS = Teams Essentials
# MCOEV = Teams Phone (Phone System add-on)
# EMS = Enterprise Mobility + Security E3
# EMSPREMIUM = EMS E5

$userLicenses = Get-MgUserLicenseDetail -UserId <UPN>
$userLicenses | Select-Object SkuPartNumber | Format-Table
```

**Step 2 — Verify UsageLocation is set**
```powershell
$ul = (Get-MgUser -UserId <UPN> -Property UsageLocation).UsageLocation
if (-not $ul) {
    Write-Host "UsageLocation is NOT set — must be set before license can be assigned" -ForegroundColor Red
} else {
    Write-Host "UsageLocation: $ul"
}
```

**Step 3 — Check if the needed SKU has available seats**
```powershell
$neededSku = "ENTERPRISEPACK"  # Change to required SKU
Get-MgSubscribedSku | Where-Object {$_.SkuPartNumber -eq $neededSku} | Select-Object SkuPartNumber, ConsumedUnits, @{N="Available";E={$_.PrepaidUnits.Enabled - $_.ConsumedUnits}}
```

**Step 4 — Check provisioning status after assignment**
```powershell
# Run 15-30 min after assignment:
Get-MgUserLicenseDetail -UserId <UPN> | ForEach-Object {
    $_.ServicePlans | Select-Object ServicePlanName, ProvisioningStatus
} | Sort-Object ProvisioningStatus | Format-Table -AutoSize
```
Expected: All service plans `Success`. `PendingProvisioning` = still processing (normal). `Disabled` = manually disabled.

---
## Common Fix Paths

<details><summary>Fix 1 — Assign a license to a user</summary>

**Use when:** User has no license or is missing a specific SKU.

```powershell
# Step 1: Get the SkuId for the license you want to assign
$sku = Get-MgSubscribedSku | Where-Object {$_.SkuPartNumber -eq "ENTERPRISEPACK"}
$sku.SkuId  # Copy this GUID

# Step 2: Assign the license
Set-MgUserLicense -UserId <UPN> -AddLicenses @{SkuId = "<SkuId-GUID>"} -RemoveLicenses @()

# Step 3: Verify
Get-MgUserLicenseDetail -UserId <UPN> | Select-Object SkuPartNumber
```

**If assigning multiple licenses at once:**
```powershell
$skus = @(
    @{SkuId = "<SkuId-GUID-1>"},  # e.g. ENTERPRISEPACK
    @{SkuId = "<SkuId-GUID-2>"}   # e.g. MCOEV
)
Set-MgUserLicense -UserId <UPN> -AddLicenses $skus -RemoveLicenses @()
```

**Rollback:**
```powershell
Set-MgUserLicense -UserId <UPN> -AddLicenses @() -RemoveLicenses @("<SkuId-GUID>")
```
</details>

<details><summary>Fix 2 — Enable a disabled service plan within a license</summary>

**Use when:** User has the right SKU but a specific feature (e.g. Teams, Exchange, Defender) is disabled.

```powershell
# Get the SkuId and the list of ALL service plan IDs in the SKU
$sku = Get-MgSubscribedSku | Where-Object {$_.SkuPartNumber -eq "ENTERPRISEPACK"}
$sku.ServicePlans | Select-Object ServicePlanName, ServicePlanId | Format-Table

# Get currently disabled plans for this user:
$userLicense = Get-MgUserLicenseDetail -UserId <UPN> | Where-Object {$_.SkuPartNumber -eq "ENTERPRISEPACK"}
$disabledPlans = $userLicense.ServicePlans | Where-Object {$_.ProvisioningStatus -eq "Disabled"} | Select-Object ServicePlanName, ServicePlanId

Write-Host "Currently disabled plans:"
$disabledPlans | Format-Table

# Re-assign the license with ONLY the plans you want disabled (omit the one you want to enable):
# Example: re-enable Teams (TEAMS1) by removing it from the DisabledPlans list
$allServicePlanIds = $sku.ServicePlans | Select-Object -ExpandProperty ServicePlanId
$keepDisabled = $disabledPlans | Where-Object {$_.ServicePlanName -ne "TEAMS1"} | Select-Object -ExpandProperty ServicePlanId

Set-MgUserLicense -UserId <UPN> `
    -AddLicenses @{SkuId = $sku.SkuId; DisabledPlans = $keepDisabled} `
    -RemoveLicenses @()
```

**Note:** You cannot add a service plan that isn't included in the purchased SKU. If the plan isn't in `$sku.ServicePlans`, you need a different or additional SKU.

**Rollback:** Re-run the above with the original set of disabled plans.
</details>

<details><summary>Fix 3 — Resolve license assignment conflicts</summary>

**Use when:** `LicenseAssignmentStates.State: Error` — common causes are service plan conflicts between two assigned SKUs.

```powershell
# Check the error detail:
(Get-MgUser -UserId <UPN> -Property LicenseAssignmentStates).LicenseAssignmentStates | Select-Object AssignedByGroup, Error, State, SkuId | Format-List

# Common error: "MutuallyExclusiveViolation"
# Cause: Two SKUs contain the same service plan (e.g. Exchange Online in E3 + separate Exchange Online Plan 2)
# Fix: Remove one of the conflicting SKUs

# Identify which SKUs have overlapping plans:
$userSkus = Get-MgUserLicenseDetail -UserId <UPN>
$allPlans = $userSkus | ForEach-Object {
    $sku = $_.SkuPartNumber
    $_.ServicePlans | ForEach-Object { [PSCustomObject]@{SKU=$sku; Plan=$_.ServicePlanName} }
}
$allPlans | Group-Object Plan | Where-Object {$_.Count -gt 1} | Format-Table Name, Count
```

**If conflict between direct and group-based license:**
- Remove the direct assignment: `Set-MgUserLicense -UserId <UPN> -AddLicenses @() -RemoveLicenses @("<conflicting-SkuId>")`
- Let the group-based license apply cleanly

**Rollback:** Re-add the removed SKU if removal breaks something else.
</details>

<details><summary>Fix 4 — Set UsageLocation (required for license assignment)</summary>

**Use when:** License assignment fails with "UsageLocation must be set" error, or user was synced from AD without this attribute.

```powershell
# Set UsageLocation (ISO 3166-1 alpha-2 country code):
Update-MgUser -UserId <UPN> -UsageLocation "GB"  # GB for United Kingdom
# Other common values: US, DE, FR, AU, CA, IE

# Verify:
Get-MgUser -UserId <UPN> -Property UsageLocation | Select-Object UsageLocation

# Bulk-set UsageLocation for all users without one:
$users = Get-MgUser -Filter "usageLocation eq null" -All
foreach ($user in $users) {
    Update-MgUser -UserId $user.Id -UsageLocation "GB"
    Write-Host "Set UsageLocation for $($user.UserPrincipalName)"
}
```

**Note:** If users are synced from on-prem AD, set the `msExchUsageLocation` attribute in AD (maps to `UsageLocation` in Entra ID via Entra Connect). Direct changes in Entra ID may be overwritten on next sync.

**Rollback:** `Update-MgUser -UserId <UPN> -UsageLocation $null` — though this will again prevent license assignment.
</details>

<details><summary>Fix 5 — Audit and manage license inventory</summary>

**Use when:** "Available" seats shows 0 or negative, or you need to reclaim licenses before purchasing more.

```powershell
# Full license inventory report:
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits,
    @{N="TotalSeats";E={$_.PrepaidUnits.Enabled}},
    @{N="Available";E={$_.PrepaidUnits.Enabled - $_.ConsumedUnits}},
    @{N="Suspended";E={$_.PrepaidUnits.Suspended}} |
    Sort-Object Available | Format-Table -AutoSize

# Find users with a specific license who haven't signed in recently (reclaim candidates):
$staleDate = (Get-Date).AddDays(-90)
$targetSkuId = (Get-MgSubscribedSku | Where-Object {$_.SkuPartNumber -eq "ENTERPRISEPACK"}).SkuId

Get-MgUser -Filter "assignedLicenses/any(x:x/skuId eq $targetSkuId)" -All -Property UserPrincipalName, SignInActivity, DisplayName |
    Where-Object {$_.SignInActivity.LastSignInDateTime -lt $staleDate -or $_.SignInActivity.LastSignInDateTime -eq $null} |
    Select-Object DisplayName, UserPrincipalName, @{N="LastSignIn";E={$_.SignInActivity.LastSignInDateTime}} |
    Sort-Object LastSignIn | Format-Table -AutoSize

# Export to CSV:
# | Export-Csv -Path "C:\Temp\StaleUsers.csv" -NoTypeInformation
```

**Rollback:** No rollback needed — this is read-only reporting. Reclaiming licenses requires removing them from users (use Fix 1's rollback).
</details>

---
## Escalation Evidence

```
LICENSE ASSIGNMENT ESCALATION
==============================
User UPN:          <UPN>
UsageLocation:     <GB/US/etc. or "NOT SET">
Required SKU:      <SkuPartNumber>

Tenant seat availability:
  SKU: <name>  Total: <n>  Consumed: <n>  Available: <n>

LicenseAssignmentStates error:
  State: <Error/Active>
  Error: <error text>
  AssignedByGroup: <GroupId or "Direct">

Service plans in "Disabled" or "Error" state:
  <list service plan names>

Expected feature that's missing:
  <e.g. "Microsoft Teams", "Microsoft Defender for Endpoint">

Steps already tried:
  [ ] Checked UsageLocation  [ ] Checked seat availability  [ ] Checked service plan status
  [ ] Removed conflicting license  [ ] Waited 30+ minutes for provisioning
```

---
## 🎓 Learning Pointers

- **`SkuPartNumber` vs `SkuId`** — human-readable names (`ENTERPRISEPACK`) vs GUIDs. Assignment APIs require the GUID. Always look up `SkuId` from `Get-MgSubscribedSku` before scripting bulk assignments.
- **`PendingProvisioning` is normal for 15-30 minutes** after a new assignment. Don't escalate based on this status alone — recheck after the window.
- **Disabled service plans are sticky** — if a service plan was manually disabled when a license was originally assigned, it stays disabled even if the license is re-assigned via a new group. You must explicitly pass `DisabledPlans = @()` to remove all disabled plans.
- **Group-based licensing errors are surfaced on the group, not the user** — check `(Get-MgGroup -GroupId <GroupId> -Property LicenseProcessingState).LicenseProcessingState` to see group-level errors.
- **UsageLocation is required by data residency law** — Microsoft uses it to determine which datacenter region serves the user's data. Setting it incorrectly for compliance reasons (e.g. EU users) has legal implications.
- MS Docs — Assign licenses using Microsoft Graph: https://learn.microsoft.com/en-us/graph/api/user-assignlicense
- MS Docs — Identify and resolve license assignment problems: https://learn.microsoft.com/en-us/azure/active-directory/enterprise-users/licensing-groups-resolve-problems
