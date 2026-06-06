# Group-Based Licensing — Hotfix Runbook (Mode B: Ops)
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
Connect-MgGraph -Scopes "Group.Read.All","User.Read.All","Organization.Read.All","Directory.ReadWrite.All"

# 1. Check a group's license assignment configuration
$group = Get-MgGroup -Filter "displayName eq '<GroupName>'" -Property Id, DisplayName, AssignedLicenses, LicenseProcessingState
$group.AssignedLicenses
$group.LicenseProcessingState  # Should be "ProcessingComplete"

# 2. Check for users in the group with license errors
$groupId = $group.Id
Get-MgGroupMember -GroupId $groupId | ForEach-Object {
    $user = Get-MgUser -UserId $_.Id -Property UserPrincipalName, LicenseAssignmentStates
    $errors = $user.LicenseAssignmentStates | Where-Object {$_.State -eq "Error" -and $_.AssignedByGroup -eq $groupId}
    if ($errors) {
        [PSCustomObject]@{UPN=$user.UserPrincipalName; Error=$errors.Error; SkuId=$errors.SkuId}
    }
} | Format-Table -AutoSize

# 3. Check a specific user's license assignment source
(Get-MgUser -UserId <UPN> -Property LicenseAssignmentStates).LicenseAssignmentStates | Select-Object AssignedByGroup, State, Error, SkuId | Format-List

# 4. Check group type (GBL only works with Security groups and M365 groups — NOT distribution lists)
Get-MgGroup -Filter "displayName eq '<GroupName>'" -Property GroupTypes, MailEnabled, SecurityEnabled, DisplayName | Select-Object DisplayName, GroupTypes, MailEnabled, SecurityEnabled
```

**Interpretation Table:**

| Symptom | Likely Cause | Go To |
|---------|-------------|-------|
| `LicenseProcessingState` shows `QueuedForProcessing` | GBL processing backlog (normal up to 24h) | Wait |
| `State: Error` + `Error: CountViolation` | No seats available | Fix 1 |
| `State: Error` + `Error: MutuallyExclusiveViolation` | User has conflicting direct/group license | Fix 2 |
| `State: Error` + `Error: UsageLocationViolation` | User missing UsageLocation | Fix 3 |
| `State: Error` + `Error: ProhibitedInUsageLocationViolation` | Service plan not available in user's country | Fix 4 |
| Group is a Distribution List | DLs can't be used for GBL | Fix 5 |
| User added to group but license didn't apply after 24h | Group processing stuck | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for group-based licensing to apply</summary>

```
SKU purchased with available seats
    └── Group type = Security or M365 Group (not DL, not nested dynamic group without replication)
        └── License assigned to the group (AssignedLicenses populated)
            └── User is a member of the group
                └── User has UsageLocation set
                    └── No conflicting license on user (direct or from another group)
                        └── GBL engine processes the assignment (up to 24h for large tenants)
                            └── Service plans provisioned (15-30 min after processing)
                                └── LICENSE ACTIVE ON USER
```
</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm group has licenses configured**
```powershell
$groupId = "<GroupId>"
$group = Get-MgGroup -GroupId $groupId -Property AssignedLicenses, LicenseProcessingState, DisplayName
Write-Host "Group: $($group.DisplayName)"
Write-Host "License Processing State: $($group.LicenseProcessingState)"
$group.AssignedLicenses | ForEach-Object {
    $sku = Get-MgSubscribedSku | Where-Object {$_.SkuId -eq $_.SkuId}
    Write-Host "License SkuId: $($_.SkuId)"
}
```

**Step 2 — Find all members with errors in this group**
```powershell
# Enumerate group members and check license state:
$errUsers = @()
Get-MgGroupMember -GroupId $groupId -All | ForEach-Object {
    $user = Get-MgUser -UserId $_.Id -Property UserPrincipalName, LicenseAssignmentStates -ErrorAction SilentlyContinue
    if ($user) {
        $groupErrors = $user.LicenseAssignmentStates | Where-Object {$_.AssignedByGroup -eq $groupId -and $_.State -eq "Error"}
        if ($groupErrors) {
            $errUsers += [PSCustomObject]@{
                UPN   = $user.UserPrincipalName
                Error = $groupErrors.Error -join ", "
                SkuId = $groupErrors.SkuId -join ", "
            }
        }
    }
}
$errUsers | Format-Table -AutoSize
Write-Host "Total users with errors: $($errUsers.Count)"
```

**Step 3 — Force group reprocessing trigger**
```powershell
# There's no direct "force reprocess" API, but removing and re-adding a license to the group triggers reprocessing:
# CAUTION: This will briefly remove the license from all users in the group
# Only do this if processing has been stuck >48h

$groupLicenses = (Get-MgGroup -GroupId $groupId -Property AssignedLicenses).AssignedLicenses
Set-MgGroupLicense -GroupId $groupId -AddLicenses @() -RemoveLicenses ($groupLicenses.SkuId)
Start-Sleep -Seconds 30
Set-MgGroupLicense -GroupId $groupId -AddLicenses $groupLicenses -RemoveLicenses @()
Write-Host "License removed and re-added to trigger GBL reprocessing."
```

---
## Common Fix Paths

<details><summary>Fix 1 — Resolve CountViolation (no seats available)</summary>

**Use when:** `Error: CountViolation` — tenant ran out of license seats.

```powershell
# Check current seat usage:
$skuId = "<SkuId-GUID>"
Get-MgSubscribedSku | Where-Object {$_.SkuId -eq $skuId} | Select-Object SkuPartNumber, ConsumedUnits, @{N="Available";E={$_.PrepaidUnits.Enabled - $_.ConsumedUnits}}

# Option A: Reclaim licenses from stale users (see License-Assignment-B.md Fix 5)

# Option B: Remove from this group temporarily and assign directly to priority users:
Set-MgUserLicense -UserId <PriorityUserUPN> -AddLicenses @{SkuId = $skuId} -RemoveLicenses @()

# Option C: Purchase additional seats (out of band — admin portal or CSP)
# Microsoft 365 admin centre → Billing → Your products → add seats
```

**Rollback:** Release directly-assigned license when new seats arrive: `Set-MgUserLicense -UserId <UPN> -AddLicenses @() -RemoveLicenses @($skuId)`.
</details>

<details><summary>Fix 2 — Resolve MutuallyExclusiveViolation (conflicting licenses)</summary>

**Use when:** Two licenses contain the same service plan — e.g. user has `EXCHANGESTANDARD` assigned directly AND `ENTERPRISEPACK` (which includes `EXCHANGEENTERPRISE`) via group.

```powershell
# Find all licenses the user has (direct + group):
(Get-MgUser -UserId <UPN> -Property LicenseAssignmentStates).LicenseAssignmentStates | Select-Object SkuId, AssignedByGroup, State | Format-List

# Identify conflicting service plans:
Get-MgUserLicenseDetail -UserId <UPN> | ForEach-Object {
    $sku = $_.SkuPartNumber
    $_.ServicePlans | ForEach-Object { [PSCustomObject]@{SKU=$sku; Plan=$_.ServicePlanName} }
} | Group-Object Plan | Where-Object {$_.Count -gt 1}

# Remove the conflicting direct license:
$conflictSkuId = "<SkuId-of-direct-conflicting-license>"
Set-MgUserLicense -UserId <UPN> -AddLicenses @() -RemoveLicenses @($conflictSkuId)

# GBL will re-process within 24h — or trigger manually:
# Remove and re-add the group license assignment (Fix 6 approach)
```

**Rollback:** Re-add the direct license if removal breaks something: `Set-MgUserLicense -UserId <UPN> -AddLicenses @{SkuId=$conflictSkuId} -RemoveLicenses @()`.
</details>

<details><summary>Fix 3 — Resolve UsageLocationViolation (missing usage location)</summary>

**Use when:** `Error: UsageLocationViolation` — user's `UsageLocation` is null.

```powershell
# Identify all group members with null UsageLocation:
Get-MgGroupMember -GroupId $groupId -All | ForEach-Object {
    $user = Get-MgUser -UserId $_.Id -Property UserPrincipalName, UsageLocation -ErrorAction SilentlyContinue
    if ($user -and -not $user.UsageLocation) {
        Write-Host "Missing UsageLocation: $($user.UserPrincipalName)"
    }
}

# Set UsageLocation for affected users:
$usersToFix = @("<UPN1>", "<UPN2>")
foreach ($upn in $usersToFix) {
    Update-MgUser -UserId $upn -UsageLocation "GB"  # Change to correct country code
    Write-Host "Set UsageLocation for $upn"
}
```

**If synced from on-prem AD:** Set `msExchUsageLocation` (or `co`/`c` attributes) in AD — Entra Connect maps these to `UsageLocation`. Direct cloud edits will be overwritten at next sync.

**Rollback:** `Update-MgUser -UserId <UPN> -UsageLocation $null` (disables licensing again).
</details>

<details><summary>Fix 4 — Resolve ProhibitedInUsageLocationViolation</summary>

**Use when:** User has a UsageLocation set, but the service plan being assigned is not available in that country (e.g. certain compliance or calling features are geo-restricted).

```powershell
# Find which service plans are causing the issue:
(Get-MgUser -UserId <UPN> -Property LicenseAssignmentStates).LicenseAssignmentStates | Select-Object SkuId, Error, State

# Solution A: Disable the blocked service plan for this user (assign license with that plan disabled):
$sku = Get-MgSubscribedSku | Where-Object {$_.SkuId -eq "<SkuId>"}
$blockedPlan = $sku.ServicePlans | Where-Object {$_.ServicePlanName -eq "<BlockedPlanName>"} | Select-Object -ExpandProperty ServicePlanId

Set-MgUserLicense -UserId <UPN> -AddLicenses @{SkuId = $sku.SkuId; DisabledPlans = @($blockedPlan)} -RemoveLicenses @()

# Solution B: Change user's UsageLocation to a supported country
# Only do this if the user is actually located in that country
Update-MgUser -UserId <UPN> -UsageLocation "US"
```

**Note:** Check service plan availability by country at: https://learn.microsoft.com/en-us/azure/active-directory/enterprise-users/licensing-service-plan-reference

**Rollback:** Re-assign without the DisabledPlans override, or revert UsageLocation.
</details>

<details><summary>Fix 5 — Convert Distribution List to Security Group for GBL</summary>

**Use when:** License assignment was configured on a Distribution List (DL) — GBL does not support DLs.

```powershell
# Confirm group type:
Get-MgGroup -Filter "displayName eq '<GroupName>'" -Property GroupTypes, MailEnabled, SecurityEnabled, DisplayName | Select-Object DisplayName, GroupTypes, MailEnabled, SecurityEnabled
# DL: MailEnabled=True, SecurityEnabled=False, GroupTypes=[]

# You cannot convert a DL to a Security Group directly in Exchange Online
# Steps:
# 1. Create a new Microsoft 365 Group or Security Group with the same members
# 2. Assign the license to the NEW group
# 3. Verify members receive licenses
# 4. Remove license from old DL (or delete it if no longer needed)

# Create a new Mail-Enabled Security Group (can receive email AND be used for GBL):
New-DistributionGroup -Name "<NewGroupName>" -Type Security -ManagedBy <AdminUPN>

# Or create an M365 Group:
New-UnifiedGroup -DisplayName "<NewGroupName>" -Alias "<alias>"
```

**Rollback:** N/A — creating a new group is additive. Old DL is unaffected.
</details>

<details><summary>Fix 6 — Unstick GBL processing (stuck > 48 hours)</summary>

**Use when:** Group membership is correct, no errors shown, but users still don't have the license after 48+ hours.

```powershell
# Verify processing state first:
$group = Get-MgGroup -GroupId $groupId -Property LicenseProcessingState, AssignedLicenses, DisplayName
Write-Host "Processing State: $($group.LicenseProcessingState)"

# If state is not "ProcessingComplete" after 48h, trigger by removing + re-adding license to group:
$currentLicenses = $group.AssignedLicenses
Write-Host "Removing licenses from group to force reprocessing..."
Set-MgGroupLicense -GroupId $groupId -AddLicenses @() -RemoveLicenses ($currentLicenses.SkuId)

Start-Sleep -Seconds 60
Write-Host "Re-adding licenses..."
Set-MgGroupLicense -GroupId $groupId -AddLicenses $currentLicenses -RemoveLicenses @()

Write-Host "Done. GBL processing will restart — check again in 1-2 hours."
```

**Warning:** This causes a temporary license removal for all group members. Plan this during off-hours. Features (Teams, SharePoint, etc.) may briefly show as unlicensed.

**Rollback:** Licenses will re-apply automatically as GBL reprocesses. No manual rollback needed.
</details>

---
## Escalation Evidence

```
GROUP-BASED LICENSING ESCALATION
==================================
Group name:            <GroupName>
Group ID:              <GroupId>
Group type:            [ ] Security  [ ] M365  [ ] Distribution List
LicenseProcessingState: <value>

SKU(s) assigned to group: <SkuPartNumber(s)>
Seat availability:         <Available seats count>

Number of users with errors:  <n>
Error types seen:
  [ ] CountViolation
  [ ] MutuallyExclusiveViolation
  [ ] UsageLocationViolation
  [ ] ProhibitedInUsageLocationViolation
  [ ] Other: <describe>

Sample affected user:     <UPN>
Their LicenseAssignmentStates:
  <paste output>

Hours since group membership change:  <n>
Steps already tried:
  [ ] Waited 24h  [ ] Checked group type  [ ] Checked UsageLocation
  [ ] Removed conflicting licenses  [ ] Triggered reprocessing
```

---
## 🎓 Learning Pointers

- **GBL processing is not instant** — after a member is added to a group, license assignment can take up to 24 hours for large tenants. The `LicenseProcessingState` property on the group shows current queue status.
- **Nested groups are partially supported** — Entra ID dynamic group membership considers nested groups, but GBL only processes direct members. If your licensing groups use nesting, flatten them or use dynamic groups with direct membership rules.
- **Errors surface on the user, not the admin centre** — GBL errors don't generate alerts by default. Build a scheduled script using the pattern in Diagnosis Step 2 to email a report of licensing errors weekly.
- **`MutuallyExclusiveViolation` is the most common error** — caused by the same service plan appearing in two SKUs. The fix is always to remove one source — prefer removing the direct assignment and letting GBL manage it.
- **Group-based licensing requires Entra ID P1 or above** — basic Entra ID (free) does not support GBL. If this feature isn't visible in the admin centre, check the tenant's Entra ID licence tier.
- MS Docs — Group-based licensing in Entra ID: https://learn.microsoft.com/en-us/azure/active-directory/enterprise-users/licensing-groups-overview
- MS Docs — GBL error reference: https://learn.microsoft.com/en-us/azure/active-directory/enterprise-users/licensing-groups-resolve-problems
