# Group-Based Licensing — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Entra ID (Azure AD) Group-Based Licensing (GBL) — Microsoft 365 and EMS license assignment via security groups
- GBL error states: `MutuallyExclusiveViolation`, `CountViolation`, `ProhibitedInUsageLocationViolation`, `UniquenessViolation`, `DependencyViolation`
- GBL with nested groups and dynamic membership rules
- GBL coexistence with direct license assignment
- Transition from manual per-user licensing to GBL

**Out of Scope:**
- Classic (per-user) license assignment from the M365 Admin portal
- Licensing via PowerShell `Set-MsolUserLicense` without GBL backing groups
- Azure subscription (RBAC/cost) licensing

**Assumed Prerequisites:**
- Microsoft Entra ID P1 or P2 (required for GBL)
- Admin roles: License Administrator, User Administrator, or Global Administrator
- `Microsoft.Graph` PowerShell module installed
- `MSOnline` or `AzureAD` module (legacy fallback — prefer Graph)

---

## How It Works

<details><summary>Full architecture</summary>

### Processing Pipeline

When a user is added to a licensing group, the following pipeline executes asynchronously in the Entra ID backend:

```
User added to Group
        │
        ▼
GBL Processing Engine polls group membership
        │
        ▼
Eligibility Checks (parallel)
    ├── Usage Location set?       → No → ProhibitedInUsageLocation error
    ├── SKU available (count)?    → No → CountViolation error
    ├── Service plan conflicts?   → Yes → MutuallyExclusiveViolation error
    ├── Dependencies met?         → No → DependencyViolation error
    └── All pass → License assigned
        │
        ▼
Service Plan Provisioning (per-service)
    ├── Exchange Online mailbox provisioned
    ├── SharePoint site created
    ├── Teams user provisioned
    └── [other service plans enabled]
        │
        ▼
licenseAssignmentStates updated on user object
        │
        ▼
Audit log event: "Change user license"
```

### Key Concepts

**License Inheritance vs. Direct Assignment:**
- GBL creates an "inherited" assignment (`assignedByGroup: <groupId>`)
- Direct assignment (`assignedDirectly: true`) coexists with GBL
- A user can have both; removing from group doesn't revoke directly-assigned licenses

**Conflict Resolution (GBL vs Direct):**
- If a user has a direct E3 assignment AND is in a GBL E3 group: no duplication — one active assignment, both tracked in `licenseAssignmentStates`
- Removing direct assignment while GBL covers the same SKU = seamless; user keeps the license

**Nested Group Limitation:**
- GBL does **not** process nested groups transitively by default
- Exception: dynamic groups that resolve to flat membership lists work normally
- Nested static groups: members of child groups do NOT inherit parent group's licenses

**Processing Latency:**
- Normal: 1–15 minutes for membership changes to propagate
- Large tenants (100k+ users): up to several hours for bulk membership changes
- Error states are surfaced within 24 hours in the licensing portal

**UsageLocation Requirement:**
- Every user receiving a license through GBL must have `usageLocation` set
- If blank, GBL places the user in error state `ProhibitedInUsageLocationViolation`
- Setting `usageLocation` does NOT retroactively fix the error — you must remove and re-add the user, or wait for the next GBL re-evaluation cycle

</details>

---

## Dependency Stack

```
┌─────────────────────────────────────────────────────┐
│              Microsoft 365 Services                 │
│  (Exchange, SharePoint, Teams, Intune, Defender…)   │
└───────────────────────┬─────────────────────────────┘
                        │ depend on
┌───────────────────────▼─────────────────────────────┐
│           License (SKU) Assignment                  │
│     M365 E3/E5, EMS E3/E5, AAD P1/P2…              │
└───────────────────────┬─────────────────────────────┘
                        │ managed by
┌───────────────────────▼─────────────────────────────┐
│         Group-Based Licensing Engine                │
│   (Entra ID backend, async, no SLA guarantee)       │
└───────────┬───────────────────────┬─────────────────┘
            │ reads                 │ reads
┌───────────▼──────────┐  ┌────────▼────────────────┐
│   Security Group /   │  │    SKU Availability      │
│   Dynamic Group      │  │ (tenant purchased seats) │
│   Membership         │  └─────────────────────────┘
└───────────┬──────────┘
            │ contains
┌───────────▼──────────────────────────────────────────┐
│              User Object                              │
│  • usageLocation (REQUIRED)                          │
│  • licenseAssignmentStates                           │
│  • assignedLicenses                                  │
└──────────────────────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| User in group but no license after 1 hour | `usageLocation` not set | `Get-MgUser -UserId <UPN> \| Select UsageLocation` |
| License portal shows red error badge on group | SKU exhausted (`CountViolation`) | Check available seats in M365 Admin → Billing → Licenses |
| Specific service plan disabled for some users | `MutuallyExclusiveViolation` — conflicting plans across groups | Check all groups the user is a member of |
| User removed from group, still has license | User also has direct license assignment | Check `licenseAssignmentStates` for `assignedByGroup` vs. `assignedDirectly` |
| Nested group members not getting licensed | GBL doesn't process nested groups | Flatten group structure or use dynamic groups |
| `DependencyViolation` error | Service plan A requires plan B, but plan B is disabled | Check service plan dependencies (e.g., Teams requires Exchange) |
| `UniquenessViolation` | Duplicate license SKU from multiple GBL groups | Consolidate groups or exclude conflicting plans |
| Processing delay > 24h | Large tenant bulk change, or backend queue | Check Entra ID Service Health; monitor audit log for events |
| User in error state after usageLocation was set | GBL doesn't auto-retry — needs re-trigger | Remove user from group → re-add, or use `Invoke-MgGroupLicenseProcessing` |

---

## Validation Steps

**1. Verify GBL prerequisite license (Entra ID P1/P2)**
```powershell
Connect-MgGraph -Scopes "Directory.Read.All","Organization.Read.All"
(Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "AAD_PREMIUM" }).SkuPartNumber
```
*Expected:* `AAD_PREMIUM` or `AAD_PREMIUM_P2` in at least one SKU.
*Bad:* Empty output — GBL is not available without Entra P1.

**2. Check all GBL-assigned groups for a user**
```powershell
$user = Get-MgUser -UserId "<UPN>" -Property "licenseAssignmentStates,displayName,usageLocation"
$user.LicenseAssignmentStates | Select-Object AssignedByGroup, SkuId, State, Error | Format-Table -AutoSize
```
*Expected:* `State = Active`, `Error = null` for all rows.
*Bad:* `State = Error` with an error code in the `Error` column.

**3. Check usageLocation**
```powershell
Get-MgUser -UserId "<UPN>" -Property "displayName,usageLocation" | Select displayName, usageLocation
```
*Expected:* Two-letter ISO country code (e.g., `GB`, `US`).
*Bad:* Empty/null — GBL will refuse to assign licenses.

**4. Check SKU availability (remaining seats)**
```powershell
Get-MgSubscribedSku | Select-Object SkuPartNumber,
    @{N="Available";E={$_.PrepaidUnits.Enabled - $_.ConsumedUnits}},
    @{N="Total";E={$_.PrepaidUnits.Enabled}},
    @{N="Consumed";E={$_.ConsumedUnits}} | Sort-Object Available
```
*Expected:* Positive `Available` count for each SKU in use.
*Bad:* Zero or negative — `CountViolation` errors will appear.

**5. Confirm service plan conflicts**
```powershell
# Get all license groups for user and enumerate their service plans
$userId = "<UPN>"
$assignedGroups = (Get-MgUser -UserId $userId -Property licenseAssignmentStates).LicenseAssignmentStates |
    Where-Object { $_.AssignedByGroup -ne $null } | Select-Object -ExpandProperty AssignedByGroup

foreach ($groupId in $assignedGroups) {
    $group = Get-MgGroup -GroupId $groupId
    Write-Host "`nGroup: $($group.DisplayName)" -ForegroundColor Cyan
    (Get-MgGroupLicenseDetail -GroupId $groupId).ServicePlans |
        Select-Object ServicePlanName, ProvisioningStatus | Format-Table
}
```
*Expected:* No plan appears as `Disabled` in multiple groups covering the same SKU.

---

## Troubleshooting Steps (by phase)

### Phase 1 — User Not Licensed After Group Add

1. Confirm the user is a **direct member** of the licensing group (not nested):
   ```powershell
   Get-MgGroupMember -GroupId "<GroupId>" | Where-Object { $_.Id -eq (Get-MgUser -UserId "<UPN>").Id }
   ```

2. Confirm `usageLocation` is set. If blank, set it:
   ```powershell
   Update-MgUser -UserId "<UPN>" -UsageLocation "GB"
   ```

3. Wait 15 minutes. Then check `licenseAssignmentStates`:
   ```powershell
   (Get-MgUser -UserId "<UPN>" -Property licenseAssignmentStates).LicenseAssignmentStates
   ```

4. If still in error, force re-evaluation by removing and re-adding:
   ```powershell
   Remove-MgGroupMemberByRef -GroupId "<GroupId>" -DirectoryObjectId (Get-MgUser -UserId "<UPN>").Id
   Start-Sleep -Seconds 10
   New-MgGroupMember -GroupId "<GroupId>" -DirectoryObjectId (Get-MgUser -UserId "<UPN>").Id
   ```

---

### Phase 2 — Error State Investigation

**CountViolation** — Seats exhausted:
- Purchase more seats, or remove stale licensed users
- Script to find users with unused licenses:
  ```powershell
  # Find licensed users inactive for 90+ days
  $cutoff = (Get-Date).AddDays(-90)
  Get-MgUser -Filter "accountEnabled eq true" -All -Property "displayName,userPrincipalName,signInActivity,assignedLicenses" |
      Where-Object { $_.SignInActivity.LastSignInDateTime -lt $cutoff -and $_.AssignedLicenses.Count -gt 0 } |
      Select-Object DisplayName, UserPrincipalName, @{N="LastSignIn";E={$_.SignInActivity.LastSignInDateTime}} |
      Export-Csv -Path "C:\Temp\StaleUsers.csv" -NoTypeInformation
  ```

**MutuallyExclusiveViolation** — Conflicting service plans:
- Common example: User in an E3 GBL group (Teams plan) AND in a standalone Teams Essentials group
- Resolution: Exclude conflicting service plans from one group via `addLicenses.disabledPlans`
- Use `Get-MgGroupLicenseDetail` to audit plans per group

**DependencyViolation** — Plan dependency unmet:
- Example: Teams enabled but Exchange Online Plan 2 disabled
- Exchange is a dependency for Teams — enabling Exchange resolves this
- Check: [Service plan dependencies — docs.microsoft.com](https://learn.microsoft.com/en-us/entra/identity/users/licensing-service-plan-reference)

**ProhibitedInUsageLocationViolation** — Missing/blocked location:
- Set `usageLocation` on the user
- Some licenses cannot be assigned in certain countries — verify against the [M365 availability matrix](https://www.microsoft.com/en-us/microsoft-365/business/compare-all-microsoft-365-business-products?activetab=tab:primaryr2)

---

### Phase 3 — Bulk Remediation

For tenants with many users in error state:

```powershell
# Get all users in GBL error state across the tenant
Connect-MgGraph -Scopes "User.Read.All","Group.Read.All"

$errorUsers = Get-MgUser -All -Property "displayName,userPrincipalName,usageLocation,licenseAssignmentStates" |
    Where-Object {
        $_.LicenseAssignmentStates | Where-Object { $_.State -eq "Error" }
    }

$errorUsers | Select-Object DisplayName, UserPrincipalName, UsageLocation,
    @{N="ErrorCode";E={ ($_.LicenseAssignmentStates | Where-Object {$_.State -eq "Error"}).Error -join ", " }} |
    Export-Csv -Path "C:\Temp\GBL-Errors.csv" -NoTypeInformation

Write-Host "Found $($errorUsers.Count) users in error state. See C:\Temp\GBL-Errors.csv"
```

---

## Remediation Playbooks

<details><summary>Playbook 1 — Migrate from Direct to Group-Based Licensing</summary>

**Goal:** Move all direct license assignments to GBL without user disruption.

**Risk:** Low — license is maintained throughout. Users experience no service disruption.

**Steps:**
```powershell
# Step 1: Create or identify the licensing group
$groupId = "<LicensingGroupId>"
$skuId = "<SkuId>"  # e.g., ENTERPRISEPACK for E3

# Step 2: Add all directly-licensed users to the GBL group
$directUsers = Get-MgUser -All -Property "id,userPrincipalName,assignedLicenses" |
    Where-Object { $_.AssignedLicenses.SkuId -contains $skuId }

foreach ($user in $directUsers) {
    Write-Host "Adding $($user.UserPrincipalName) to group..."
    New-MgGroupMember -GroupId $groupId -DirectoryObjectId $user.Id
}

# Step 3: Wait for GBL to process (minimum 30 min for large tenants)
Write-Host "Wait 30+ minutes before removing direct assignments"

# Step 4: Validate GBL assignment active before removing direct
Start-Sleep -Seconds 1800

# Step 5: Remove direct assignments (ONLY after GBL confirmed active)
foreach ($user in $directUsers) {
    $licenseState = (Get-MgUser -UserId $user.Id -Property licenseAssignmentStates).LicenseAssignmentStates |
        Where-Object { $_.SkuId -eq $skuId -and $_.AssignedByGroup -eq $groupId -and $_.State -eq "Active" }

    if ($licenseState) {
        Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses @($skuId)
        Write-Host "Removed direct license from $($user.UserPrincipalName)" -ForegroundColor Green
    } else {
        Write-Warning "GBL not yet active for $($user.UserPrincipalName) — skipping direct removal"
    }
}
```

**Rollback:** Re-add direct license assignment. GBL continues to function in parallel.

</details>

<details><summary>Playbook 2 — Fix Bulk usageLocation Missing</summary>

**Goal:** Set usageLocation for all users missing it (common after AD sync without location attribute).

**Risk:** Low — only sets a metadata field. Does not change any license or service.

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All"

$defaultLocation = "GB"  # Change to your tenant's primary country

$usersWithoutLocation = Get-MgUser -All -Property "id,userPrincipalName,usageLocation" |
    Where-Object { [string]::IsNullOrEmpty($_.UsageLocation) }

Write-Host "Found $($usersWithoutLocation.Count) users without usageLocation"

foreach ($user in $usersWithoutLocation) {
    Update-MgUser -UserId $user.Id -UsageLocation $defaultLocation
    Write-Host "Set $defaultLocation for $($user.UserPrincipalName)"
}

Write-Host "Done. GBL will re-evaluate these users within 15-60 minutes."
```

**Note:** If synced from on-premises AD, set `msExchUsageLocation` or `c` attribute in AD and let sync propagate — otherwise the next sync will blank the field again.

</details>

<details><summary>Playbook 3 — Disable Specific Service Plans in a GBL Group</summary>

**Goal:** Assign E3 via GBL but disable specific plans (e.g., Sway, Yammer) for a group.

**Risk:** Low. Removing previously enabled plans may restrict access to those services.

```powershell
Connect-MgGraph -Scopes "Group.ReadWrite.All","Directory.ReadWrite.All"

$groupId = "<GroupId>"
$e3SkuId = "<E3-SkuId>"  # Get from Get-MgSubscribedSku

# Plans to disable (get ServicePlanId from Get-MgSubscribedSku)
$plansToDisable = @(
    "a23b959c-7ce8-4e57-9140-b90eb88a9e97",  # Sway
    "7547a3fe-08ee-4ccb-b430-5077c5041653"   # Yammer
)

$licenseDetail = Get-MgGroupLicenseDetail -GroupId $groupId
$currentDisabled = ($licenseDetail | Where-Object { $_.SkuId -eq $e3SkuId }).ServicePlans |
    Where-Object { $_.ProvisioningStatus -eq "Disabled" } | Select-Object -ExpandProperty ServicePlanId

$allDisabled = ($currentDisabled + $plansToDisable) | Select-Object -Unique

Set-MgGroupLicense -GroupId $groupId -AddLicenses @(
    @{ SkuId = $e3SkuId; DisabledPlans = $allDisabled }
) -RemoveLicenses @()

Write-Host "Group license updated. Disabled plans: $($allDisabled -join ', ')"
```

**Rollback:** Re-run with `$plansToDisable = @()` to re-enable all plans.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    GBL Evidence Collector — gather all relevant data for escalation
.NOTES
    Run as: License Admin or Global Admin
    Output: C:\Temp\GBL-Evidence-<timestamp>.txt
#>
Connect-MgGraph -Scopes "User.Read.All","Group.Read.All","Organization.Read.All"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = "C:\Temp\GBL-Evidence-$timestamp.txt"
$upn = Read-Host "Enter affected UPN (or press Enter to collect tenant-wide summary)"

"=== GBL Evidence Pack - $timestamp ===" | Out-File $outFile

"--- Tenant SKU Inventory ---" | Out-File $outFile -Append
Get-MgSubscribedSku | Select-Object SkuPartNumber,
    @{N="Available";E={$_.PrepaidUnits.Enabled - $_.ConsumedUnits}},
    @{N="Consumed";E={$_.ConsumedUnits}} |
    Out-File $outFile -Append

if ($upn) {
    "--- User: $upn ---" | Out-File $outFile -Append
    $u = Get-MgUser -UserId $upn -Property "displayName,userPrincipalName,usageLocation,licenseAssignmentStates,assignedLicenses"
    "Display Name: $($u.DisplayName)" | Out-File $outFile -Append
    "Usage Location: $($u.UsageLocation)" | Out-File $outFile -Append
    "--- License Assignment States ---" | Out-File $outFile -Append
    $u.LicenseAssignmentStates | Format-Table AssignedByGroup, SkuId, State, Error | Out-File $outFile -Append
}

"--- Tenant-Wide GBL Error Summary ---" | Out-File $outFile -Append
Get-MgUser -All -Property "displayName,userPrincipalName,licenseAssignmentStates" |
    Where-Object { $_.LicenseAssignmentStates | Where-Object { $_.State -eq "Error" } } |
    Select-Object DisplayName, UserPrincipalName,
        @{N="Errors";E={ ($_.LicenseAssignmentStates | Where-Object {$_.State -eq "Error"}).Error -join "; " }} |
    Out-File $outFile -Append

Write-Host "Evidence written to: $outFile" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| List all GBL groups | `Get-MgGroup -Filter "assignedLicenses/\$count ne 0" -CountVariable count -ConsistencyLevel eventual` |
| Get user's license state | `(Get-MgUser -UserId <UPN> -Property licenseAssignmentStates).LicenseAssignmentStates` |
| Get group's license assignment | `Get-MgGroupLicenseDetail -GroupId <GroupId>` |
| Check SKU availability | `Get-MgSubscribedSku \| Select SkuPartNumber, ConsumedUnits, @{N="Total";E={$_.PrepaidUnits.Enabled}}` |
| Set usageLocation | `Update-MgUser -UserId <UPN> -UsageLocation "GB"` |
| Add user to licensing group | `New-MgGroupMember -GroupId <GroupId> -DirectoryObjectId <UserId>` |
| Remove user from group | `Remove-MgGroupMemberByRef -GroupId <GroupId> -DirectoryObjectId <UserId>` |
| Add license to group | `Set-MgGroupLicense -GroupId <GroupId> -AddLicenses @(@{SkuId=<SkuId>}) -RemoveLicenses @()` |
| Remove license from group | `Set-MgGroupLicense -GroupId <GroupId> -AddLicenses @() -RemoveLicenses @(<SkuId>)` |
| Get SKU GUID by name | `Get-MgSubscribedSku \| Where-Object {$_.SkuPartNumber -eq "ENTERPRISEPACK"} \| Select SkuId` |
| Export all GBL errors to CSV | See Troubleshooting Phase 3 script above |
| Check service plan dependencies | [MS Docs Plan Reference](https://learn.microsoft.com/en-us/entra/identity/users/licensing-service-plan-reference) |

---

## 🎓 Learning Pointers

- **Nested groups are a common trap.** GBL only processes direct group members. If your org uses a nested group hierarchy for department structure, members of child groups won't inherit licenses. Either flatten the structure or use dynamic membership rules that evaluate transitively. See: [Group-based licensing additional scenarios](https://learn.microsoft.com/en-us/entra/identity/users/licensing-group-advanced)

- **usageLocation is mandatory and must be set before group add.** The field is checked at assignment time. If already in the group when the field is set, the user stays in error — you must re-trigger evaluation. In a hybrid environment, this attribute maps to the AD `c` (country) attribute synced via Entra Connect.

- **Direct + GBL coexistence is safe but creates audit confusion.** A user can have the same SKU assigned both directly and via a group. This wastes a seat. Use the `licenseAssignmentStates` property to find and clean up redundant direct assignments after migration to GBL.

- **MutuallyExclusiveViolation most often happens with Teams add-ons.** Assigning Teams Essentials standalone AND E3 (which includes Teams) creates a conflict. The fix is to exclude Teams from whichever group is the secondary assignment. Reference: [Identifying and resolving license assignment problems](https://learn.microsoft.com/en-us/entra/identity/users/licensing-groups-resolve-problems)

- **GBL errors surface in the Entra ID portal under Groups → Licenses**, not in the standard license assignment view. For programmatic monitoring, poll `licenseAssignmentStates` with `State eq 'Error'` via Graph. Set up an Azure Monitor alert or Logic App to catch new errors within hours, not days.

- **Entra ID P1 is required — but GBL is included in many E3/E5 bundles.** Any tenant with M365 E3 or E5, or EMS E3/E5, already has the P1 entitlement that enables GBL. Verify with `Get-MgSubscribedSku | Where {$_.ServicePlans.ServicePlanName -eq 'AAD_PREMIUM'}`.
