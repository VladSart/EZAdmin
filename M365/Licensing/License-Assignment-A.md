# M365 License Assignment — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Direct license assignment via Entra ID / M365 Admin Center
- Group-based licensing (GBL) via Entra security/M365 groups
- License conflict resolution (ServicePlanConflict, MutuallyExclusive)
- Disabled service plans (partial licensing)
- License inheritance failures in hybrid and synced environments

**Out of scope:**
- Azure CSP billing disputes
- Subscription-level provisioning (adding SKUs to tenant)
- Per-user MFA licensing specifics (covered in Entra ID runbooks)

**Assumptions:**
- You have Global Admin or User Administrator + License Administrator roles
- Microsoft Graph PowerShell SDK v2.x installed (`Microsoft.Graph` module)
- Exchange Online PowerShell (`ExchangeOnlineManagement`) available for mailbox validation

---

## How It Works

<details><summary>Full architecture</summary>

M365 licensing is a two-layer system:

```
Subscription (SKU)
└── Product License (e.g. Microsoft 365 E3)
    ├── Service Plan: EXCHANGE_S_ENTERPRISE  (Exchange Online Plan 2)
    ├── Service Plan: TEAMS1                 (Microsoft Teams)
    ├── Service Plan: SHAREPOINTENTERPRISE   (SharePoint Online Plan 2)
    ├── Service Plan: INTUNE_A               (Microsoft Intune Plan 1)
    └── Service Plan: AAD_PREMIUM_P2         (Entra ID P2)
```

**Assignment methods:**

```
User Account (AzureAD object)
│
├── Direct Assignment
│   └── Applied immediately via Graph API write
│
└── Group-Based Licensing (GBL)
    ├── User added to Entra group
    ├── License Processing Engine evaluates membership
    ├── Propagation delay: 0–24 hours (typically <15 min for <1000 users)
    └── Errors surfaced on group object, NOT on user object
```

**Processing pipeline for GBL:**
1. Group membership change detected (write to directory)
2. Licensing engine queues evaluation job
3. Engine checks available licenses (SKU unit count vs. assigned count)
4. Engine evaluates service plan conflicts with user's existing assignments
5. Writes license to user object
6. Downstream services (Exchange, SharePoint, Teams) provision entitlements

**Why provisioning delays happen:**
- Exchange mailbox creation: up to 24h for brand-new cloud-only users
- Teams tenant provisioning: typically <2h, can be 24h in large tenants
- SharePoint personal site: triggered on first login, not on license assignment
- Intune: enrollment eligibility typically within 15 minutes

**Service plan states:**
| State | Meaning |
|-------|---------|
| `Success` | Plan active |
| `Disabled` | Plan exists in SKU but manually disabled for this user |
| `PendingActivation` | License assigned, downstream provisioning in progress |
| `PendingInput` | License assigned but depends on another service plan being active |
| `Error` | GBL assignment failed — check group object for error details |

</details>

---

## Dependency Stack

```
Azure Subscription (CSP / EA / PAYG)
└── Tenant SKU Pool (available units per product)
    └── Group-Based Licensing Engine (Entra ID P1 required for GBL)
        ├── Direct Assignment (via Admin Center or Graph API)
        │   └── User Object — assignedLicenses[]
        │       └── Service Plans → Downstream provisioning
        │           ├── Exchange Online (mailbox creation, mail routing)
        │           ├── SharePoint Online (site collection access)
        │           ├── Teams (presence, calling, meetings)
        │           └── Intune (enrollment eligibility, compliance scope)
        │
        └── Group Assignment (GBL)
            ├── Entra ID P1 license REQUIRED on tenant
            ├── Group must be: Security or M365 (not Distribution, not dynamic nested)
            └── Errors surface on: group object → licenseProcessingState
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| User cannot log in to Teams | Teams service plan disabled or unassigned | `Get-MgUserLicenseDetail` — check TEAMS1 state |
| Exchange mailbox not created 24h after license | GBL propagation error OR Exchange provisioning backlog | Check group `licenseProcessingState`; check Exchange Admin Center |
| License count shows 0 available | All SKU units consumed | Tenant SKU usage report in Admin Center |
| "You need a license" error in SharePoint | SharePoint plan disabled in user's assignment | Check SHAREPOINTENTERPRISE service plan state |
| GBL user shows no license assigned | User not propagated yet, OR conflict with direct assignment | Check group errors; check if user has conflicting direct license |
| ServicePlanConflict error | Two SKUs containing mutually exclusive plans assigned to same user | Identify conflicting plans; remove one SKU |
| License assignment succeeds but Intune enrollment fails | Intune plan is disabled in service plan assignment | Enable INTUNE_A service plan on user |
| Admin Center shows license but user is blocked | Conditional Access blocking service, not licensing | Check Sign-In logs for CA failure |
| Synced user can't be licensed | User is DirSync'd — must be licensed from on-prem or cloud carefully | Check ImmutableId; verify no on-prem license conflict |

---

## Validation Steps

**Step 1 — Confirm user's current license state**
```powershell
Connect-MgGraph -Scopes "User.Read.All","Organization.Read.All"
$user = "user@contoso.com"
Get-MgUserLicenseDetail -UserId $user | Select-Object SkuPartNumber,
    @{N='ServicePlans';E={$_.ServicePlans | Select-Object ServicePlanName,ProvisioningStatus}}
```
**Good output:** Each required service plan shows `ProvisioningStatus: Success`
**Bad output:** Plans show `Error`, `PendingInput`, or are missing entirely

---

**Step 2 — Check available SKU units**
```powershell
Get-MgSubscribedSku | Select-Object SkuPartNumber,
    @{N='Available';E={$_.PrepaidUnits.Enabled - $_.ConsumedUnits}},
    @{N='Enabled';E={$_.PrepaidUnits.Enabled}},
    @{N='Consumed';E={$_.ConsumedUnits}} |
    Where-Object { $_.Available -lt 10 } | Sort-Object Available
```
**Good output:** Available count is positive for all needed SKUs
**Bad output:** Available = 0 or negative — you need to purchase more units

---

**Step 3 — Check GBL group error state**
```powershell
$groupId = "<GroupObjectId>"
$group = Get-MgGroup -GroupId $groupId -Property "Id,DisplayName,LicenseProcessingState,AssignedLicenses"
$group.LicenseProcessingState
# Check per-user errors
Get-MgGroupMemberWithLicenseError -GroupId $groupId | ForEach-Object {
    $userId = $_.Id
    $user = Get-MgUser -UserId $userId -Property "UserPrincipalName,LicenseAssignmentStates"
    [PSCustomObject]@{
        UPN    = $user.UserPrincipalName
        Errors = $user.LicenseAssignmentStates | Where-Object { $_.Error -ne 'None' } |
                 Select-Object AssignedByGroup,Error,DisabledPlans
    }
}
```
**Good output:** `LicenseProcessingState.State = "ProcessingComplete"` and no members in error
**Bad output:** `State = "ProcessingFailed"` or members returned with error details

---

**Step 4 — Validate Exchange mailbox provisioning**
```powershell
Connect-ExchangeOnline
Get-Mailbox -Identity "user@contoso.com" -ErrorAction SilentlyContinue |
    Select-Object DisplayName, RecipientTypeDetails, WhenMailboxCreated
```
**Good output:** Returns mailbox object with `RecipientTypeDetails = UserMailbox`
**Bad output:** "Couldn't find object" — mailbox not yet provisioned or wrong license

---

**Step 5 — Check service plan conflict details**
```powershell
$user = Get-MgUser -UserId "user@contoso.com" -Property "LicenseAssignmentStates"
$user.LicenseAssignmentStates | Where-Object { $_.Error -ne 'None' } |
    Select-Object Error, AssignedByGroup, AssignedByUser, DisabledPlans |
    Format-List
```
**Good output:** No results (no errors)
**Bad output:** `Error = "MutuallyExclusiveViolation"` or `"DependencyViolation"` — service plan conflict detected

---

## Troubleshooting Steps (by phase)

### Phase 1: License Not Showing After Assignment

1. Confirm the assignment was saved (check Admin Center audit log)
2. For GBL: verify user is actually a member of the licensing group (not just nested)
3. Run Step 1 validation — if `PendingActivation`, wait up to 24h
4. If no assignment at all: check if the user object is in scope (guest users, external members, and some service accounts cannot be licensed via GBL)
5. Check for conflicting direct assignments blocking GBL

### Phase 2: License Assigned but Service Not Working

1. Run Step 1 — confirm the specific service plan is `Success` (not `Disabled`)
2. If `Disabled`: the plan was manually disabled in the assignment — re-enable it
3. If `Success` but service broken: downstream provisioning delay — check Exchange/Teams separately
4. For Teams: `Teams` service requires `TEAMS1` AND `EXCHANGE_S_ENTERPRISE` (or Exchange Online Plan 1) — Teams licensing is dependent on Exchange
5. For Intune: confirm `INTUNE_A` is `Success` AND device compliance policies are targeted

### Phase 3: GBL Processing Errors

1. Run Step 3 — identify users in error state
2. `CountViolation`: SKU has 0 available units — purchase more
3. `MutuallyExclusiveViolation`: conflicting SKUs — identify and remove one
4. `DependencyViolation`: required dependent plan not available — check if user needs another license
5. `ProhibitedInUsageLocationViolation`: user's UsageLocation is a country where the service is unavailable — update user's UsageLocation first

---

## Remediation Playbooks

<details><summary>Fix 1 — Enable a disabled service plan on a direct-assigned license</summary>

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All"

$userUpn   = "user@contoso.com"
$skuId     = "<SkuId-GUID>"   # Get from Get-MgSubscribedSku
$enablePlan = "INTUNE_A"       # Service plan to enable

# Get current disabled plans
$current = Get-MgUserLicenseDetail -UserId $userUpn |
    Where-Object { $_.SkuId -eq $skuId }

# Get ServicePlanId for plans that should REMAIN disabled (all except the one we want)
$keepDisabled = $current.ServicePlans |
    Where-Object { $_.ServicePlanName -ne $enablePlan -and $_.ProvisioningStatus -eq 'Disabled' } |
    Select-Object -ExpandProperty ServicePlanId

# Build the assignment update
$addLicenses = @(
    @{
        SkuId        = $skuId
        DisabledPlans = $keepDisabled
    }
)

Set-MgUserLicense -UserId $userUpn -AddLicenses $addLicenses -RemoveLicenses @()
Write-Host "Service plan $enablePlan enabled. Verify with Get-MgUserLicenseDetail."
```

**Rollback:** Re-add the plan's GUID to `DisabledPlans` and re-run `Set-MgUserLicense`.

</details>

---

<details><summary>Fix 2 — Resolve MutuallyExclusiveViolation in GBL</summary>

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All","Group.Read.All"

# Identify the conflicting SKUs on the user
$userUpn = "user@contoso.com"
$states  = (Get-MgUser -UserId $userUpn -Property LicenseAssignmentStates).LicenseAssignmentStates

# Show all assignments and their source
$states | Select-Object AssignedByGroup,AssignedByUser,
    @{N='SkuId';E={$_.SkuId}},Error | Format-Table -AutoSize

# If conflict is from a direct assignment, remove the conflicting SKU:
$conflictSkuId = "<SKU-GUID-to-remove>"
Set-MgUserLicense -UserId $userUpn -AddLicenses @() -RemoveLicenses @($conflictSkuId)

# If conflict is from another GBL group, remove user from that group:
$conflictGroupId = "<GroupObjectId>"
Remove-MgGroupMemberByRef -GroupId $conflictGroupId -DirectoryObjectId `
    (Get-MgUser -UserId $userUpn).Id
```

**Common mutually exclusive pairs:**
- `ENTERPRISEPACK` (E3) + `DEVELOPERPACK_E5` (E5 Developer) — cannot coexist
- `FLOW_FREE` + `FLOW_P2` — Free tier conflicts with paid tier plans

**Rollback:** Re-add the removed SKU or re-add user to the group as needed.

</details>

---

<details><summary>Fix 3 — Bulk assign licenses via GBL to a new group</summary>

```powershell
Connect-MgGraph -Scopes "Group.ReadWrite.All","Directory.ReadWrite.All"

$groupId    = "<ExistingGroupObjectId>"
$skuId      = "<SkuId-GUID>"
# Optionally disable specific service plans:
$disablePlans = @("<ServicePlanId1>", "<ServicePlanId2>")

$assignedLicense = @{
    AddLicenses = @(
        @{
            SkuId         = $skuId
            DisabledPlans = $disablePlans
        }
    )
    RemoveLicenses = @()
}

Set-MgGroupLicense -GroupId $groupId -BodyParameter $assignedLicense
Write-Host "License queued for GBL propagation. Check group state in 15-30 minutes."
```

**Note:** GBL requires Entra ID P1 (included in E3/E5). The group must be a Security or M365 group — NOT a distribution list.

**Rollback:** Remove the license from the group: set `AddLicenses = @()` and `RemoveLicenses = @($skuId)`.

</details>

---

<details><summary>Fix 4 — Fix UsageLocation blocking license assignment</summary>

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All"

# Users missing UsageLocation cannot be licensed in some tenants
$usersNoLocation = Get-MgUser -Filter "assignedLicenses/\$count eq 0" -ConsistencyLevel eventual `
    -Property "Id,UserPrincipalName,UsageLocation" -CountVariable total |
    Where-Object { -not $_.UsageLocation }

foreach ($u in $usersNoLocation) {
    Update-MgUser -UserId $u.Id -UsageLocation "GB"  # Change to appropriate country code
    Write-Host "Set UsageLocation=GB for $($u.UserPrincipalName)"
}
```

**Rollback:** Update-MgUser with the correct UsageLocation value for each user.

</details>

---

## Evidence Pack

```powershell
<#
  License Assignment Evidence Collector
  Run before escalating to Microsoft Support or for change review.
#>
Connect-MgGraph -Scopes "User.Read.All","Organization.Read.All","Group.Read.All"

$userUpn  = Read-Host "Enter UPN"
$outPath  = "$env:TEMP\License-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"

$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine("=== LICENSE EVIDENCE PACK ===")
$null = $sb.AppendLine("UPN: $userUpn")
$null = $sb.AppendLine("Collected: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC")
$null = $sb.AppendLine("")

# User basics
$u = Get-MgUser -UserId $userUpn -Property "Id,DisplayName,UsageLocation,AssignedLicenses,LicenseAssignmentStates,AccountEnabled"
$null = $sb.AppendLine("--- User Object ---")
$null = $sb.AppendLine("DisplayName   : $($u.DisplayName)")
$null = $sb.AppendLine("AccountEnabled: $($u.AccountEnabled)")
$null = $sb.AppendLine("UsageLocation : $($u.UsageLocation)")
$null = $sb.AppendLine("")

# License details
$null = $sb.AppendLine("--- Assigned Licenses ---")
$lic = Get-MgUserLicenseDetail -UserId $userUpn
foreach ($l in $lic) {
    $null = $sb.AppendLine("SKU: $($l.SkuPartNumber) [$($l.SkuId)]")
    foreach ($sp in $l.ServicePlans | Sort-Object ServicePlanName) {
        $null = $sb.AppendLine("  $($sp.ServicePlanName.PadRight(40)) $($sp.ProvisioningStatus)")
    }
}
$null = $sb.AppendLine("")

# Assignment states (GBL errors)
$null = $sb.AppendLine("--- License Assignment States ---")
foreach ($s in $u.LicenseAssignmentStates) {
    $null = $sb.AppendLine("  SkuId: $($s.SkuId) | Error: $($s.Error) | Source: $(if($s.AssignedByGroup){"Group:$($s.AssignedByGroup)"}else{"Direct"})")
}
$null = $sb.AppendLine("")

# SKU availability
$null = $sb.AppendLine("--- Tenant SKU Availability ---")
Get-MgSubscribedSku | ForEach-Object {
    $avail = $_.PrepaidUnits.Enabled - $_.ConsumedUnits
    $null = $sb.AppendLine("  $($_.SkuPartNumber.PadRight(40)) Enabled=$($_.PrepaidUnits.Enabled)  Consumed=$($_.ConsumedUnits)  Available=$avail")
}

$sb.ToString() | Out-File $outPath -Encoding UTF8
Write-Host "Evidence written to: $outPath" -ForegroundColor Green
notepad $outPath
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| List user's licenses | `Get-MgUserLicenseDetail -UserId <UPN>` |
| List available SKUs | `Get-MgSubscribedSku \| Select-Object SkuPartNumber,ConsumedUnits,@{N='Avail';E={$_.PrepaidUnits.Enabled-$_.ConsumedUnits}}` |
| Check GBL group errors | `Get-MgGroupMemberWithLicenseError -GroupId <id>` |
| Check group license assignment | `Get-MgGroup -GroupId <id> -Property AssignedLicenses,LicenseProcessingState` |
| Assign license directly | `Set-MgUserLicense -UserId <UPN> -AddLicenses @(@{SkuId='<GUID>'}) -RemoveLicenses @()` |
| Remove license directly | `Set-MgUserLicense -UserId <UPN> -AddLicenses @() -RemoveLicenses @('<GUID>')` |
| Assign GBL to group | `Set-MgGroupLicense -GroupId <id> -BodyParameter @{AddLicenses=@(@{SkuId='<GUID>'}); RemoveLicenses=@()}` |
| Find users with no license | `Get-MgUser -Filter "assignedLicenses/\$count eq 0" -ConsistencyLevel eventual` |
| Find unlicensed but enabled | `Get-MgUser -Filter "accountEnabled eq true and assignedLicenses/\$count eq 0" -ConsistencyLevel eventual` |
| Check assignment states | `(Get-MgUser -UserId <UPN> -Property LicenseAssignmentStates).LicenseAssignmentStates` |
| SKU GUID lookup | `Get-MgSubscribedSku \| Select-Object SkuPartNumber,SkuId` |
| Service plan GUID lookup | `(Get-MgSubscribedSku \| Where SkuPartNumber -eq '<SKU>').ServicePlans \| Select-Object ServicePlanName,ServicePlanId` |
| Set user's usage location | `Update-MgUser -UserId <UPN> -UsageLocation 'GB'` |
| Validate Exchange mailbox | `Get-Mailbox -Identity <UPN> \| Select-Object RecipientTypeDetails,WhenMailboxCreated` |

---

## 🎓 Learning Pointers

- **GBL errors surface on the group, not the user.** If a user looks licensed but something's wrong, go to the Entra group's "Licenses" blade and check for members with errors — the user object alone won't tell you about GBL propagation failures. [MS Docs: Identify and resolve license assignment problems](https://learn.microsoft.com/en-us/entra/identity/users/licensing-groups-resolve-problems)

- **UsageLocation is required for license assignment.** Cloud-only users created without a UsageLocation silently fail license assignment in some tenant configurations. Always set `UsageLocation` before licensing — it's a country code, not optional. [MS Docs: Assign licenses to users](https://learn.microsoft.com/en-us/entra/fundamentals/license-users-groups)

- **Teams depends on Exchange.** Microsoft Teams requires an Exchange Online mailbox for calendar integration and voicemail. If a user has `TEAMS1` but no Exchange plan, Teams will partially work but meeting features and voicemail will fail. The dependency isn't always enforced at license level — it's enforced at provisioning time. [MS Docs: Teams licensing](https://learn.microsoft.com/en-us/microsoftteams/user-access)

- **GBL doesn't work with nested groups.** If your licensing group contains a nested group, members of the nested group will NOT receive licenses. GBL only processes direct membership. This is a very common "it should be working" gotcha in complex AD-synced environments. [MS Docs: Group-based licensing additional scenarios](https://learn.microsoft.com/en-us/entra/identity/users/licensing-group-advanced)

- **`MutuallyExclusiveViolation` is usually E3+E5 overlap.** When migrating from E3 to E5, overlapping service plans (Entra ID P2, Intune P2, etc.) cause conflicts if both SKUs are assigned simultaneously. The safe migration path is: assign E5 → remove E3 in the same operation via GBL group swap, not sequential steps. [MS Docs: Migrate users between product licenses](https://learn.microsoft.com/en-us/entra/identity/users/licensing-groups-change-licenses)

- **The `LicenseAssignmentStates` property is your single source of truth.** Unlike `assignedLicenses` (which only shows what's assigned), `LicenseAssignmentStates` shows the error, the source (direct vs. group), and which plans are disabled — everything you need in one API call. Use it first on any license investigation.
