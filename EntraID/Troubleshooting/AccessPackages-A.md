# Entra ID Entitlement Management / Access Packages — Reference Runbook (Mode A: Deep Dive)
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

Covers Entra ID Entitlement Management (EM) — the Identity Governance feature for managing access lifecycle through Access Packages. Applies to:

- **Access Packages** — bundles of resources (groups, SharePoint sites, apps, Teams) with associated policies
- **Catalogs** — containers for access packages and their resources
- **Access Policies** — who can request, who approves, and lifecycle rules
- **Access Reviews** — periodic review of assignments (Governance add-on)
- **Connected Organizations** — B2B partner access through access packages

Requires Entra ID P2 (or Microsoft Entra ID Governance) license. Without P2, the portal shows Entitlement Management but most features are locked. Assumes engineer has at minimum the **Identity Governance Administrator** role.

---

## How It Works

<details><summary>Full architecture</summary>

### Core Concepts

```
Catalog
  └─► Access Package
            ├─► Resource Role Assignments (what access is granted)
            │       ├─► Microsoft 365 Group (member role)
            │       ├─► SharePoint Online site (member role)
            │       ├─► Enterprise Application (app role assignment)
            │       └─► Teams team (member role)
            └─► Access Policies (who/how/when)
                    ├─► Requestors (who can ask for access)
                    ├─► Approvers (1 or 2-stage approval chain)
                    ├─► Lifecycle (expiry, renewal, auto-assignment)
                    └─► Questions (custom form fields for request)
```

### Request → Assignment Lifecycle

```
User visits My Access portal (myaccess.microsoft.com)
       │
       ▼
Selects Access Package → Answers custom questions → Submits request
       │
       ▼
Policy evaluation:
  ├─► Is requestor eligible? (user scope, group scope, connected org)
  ├─► Approval required?
  │       ├─► Stage 1 approver notified (email + My Access)
  │       └─► Stage 2 approver notified (if configured)
  └─► Auto-approve? (no approval required policy)
       │
       ▼
Assignment created:
  ├─► User added to each resource role
  │       ├─► Group membership added via Graph
  │       ├─► App role assignment created
  │       └─► SharePoint site member added
  └─► Expiry timer set (if configured)
       │
       ▼
Lifecycle events:
  ├─► Expiry approaching → renewal notification email
  ├─► Expiry reached → assignment removed → resources removed
  ├─► Access review → reviewer confirms/denies → assignment retained or removed
  └─► Manual removal by admin → immediate resource removal
```

### Provisioning Engine

Entitlement Management uses the **Entra ID Provisioning Engine** (the same engine used by group-based licensing) to propagate resource assignments:

- Group memberships: **near-real-time** (seconds to minutes)
- SharePoint site access: **may lag 15–60 minutes** after group membership is set (SharePoint processes membership changes asynchronously)
- App role assignments: **near-real-time** for most SaaS apps; SCIM-provisioned apps depend on the SCIM sync cycle (typically 40 minutes)
- Teams: **may take 5–30 minutes** after group membership (Teams syncs group membership on its own schedule)

### Catalog Architecture

A **Catalog** is the administrative boundary:
- Resources must be added to a catalog before they can be assigned to access packages in that catalog
- Catalog **Owners** can manage everything in the catalog without needing global EM admin rights
- **General catalog** (built-in, not deletable) is the default
- Custom catalogs enable delegated administration — business units own their own catalogs

### Connected Organizations (B2B)

For external/guest access:
```
Connected Organization (partner tenant / domain)
       │
       └─► Access Package Policy: "For users not in my directory"
                    └─► Guest account auto-created in home tenant
                              └─► Access assigned
                                        └─► On expiry: guest account optionally removed
```

Guest lifecycle management settings in Connected Organizations control auto-removal of guest accounts when all access packages expire.

### Licensing Note

Each user who is governed by (or manages) EM features requires **Entra ID P2** or **Microsoft Entra ID Governance**. This includes:
- Users who receive assignments (P2 not required for the assignment itself but IS required for Access Reviews on those assignments)
- Users who request access
- Users who approve requests

In practice, assign P2 to all active directory members in governed departments.

</details>

---

## Dependency Stack

```
My Access Portal (myaccess.microsoft.com) — user-facing
        │
        ▼
  Entitlement Management Service (Entra ID backend)
        │
        ├─► Catalog Store (access packages, policies, resources)
        │
        ├─► Approval Workflow Engine
        │        └─► Email notifications via Exchange Online / Entra notification service
        │
        ├─► Assignment Engine (Provisioning)
        │        ├─► Microsoft Graph API (group membership, app roles)
        │        ├─► SharePoint Online CSOM/REST (site permissions)
        │        └─► Teams Graph API (team membership)
        │
        ├─► Access Review Engine (P2/Governance feature)
        │        └─► Exchange Online (reviewer notification emails)
        │
        └─► Audit Log (Entra audit log, accessible via Graph and Azure Monitor)

License requirement: Entra ID P2 or Microsoft Entra ID Governance per governed user
Admin roles: Identity Governance Administrator, Global Admin, or Catalog Owner
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| User can't see access package in My Access | Policy requestor scope excludes user, or package is hidden | Portal: check policy → "Who can request" scope |
| Request submitted but stuck "Pending" | Approver not responding, or approver account disabled | Check pending requests in portal; check approver is active |
| Request approved but access not provisioned | Provisioning lag (SharePoint/Teams) or resource removed from catalog | Wait 60 min then check; verify resource still in catalog |
| "You are not eligible" error in My Access | User not in allowed scope (wrong group, wrong org, wrong domain) | Check policy requestor scope and user's group memberships |
| Assignment expired but user still has access | SharePoint/Teams lag on group removal | Wait 60 min; force SharePoint sync if needed |
| Approval email not received | Approver email in junk, or Exchange delivery issue | Check M365 message trace; verify approver SMTP address |
| Can't add resource to catalog | Resource already in another catalog, or insufficient permission | Each resource can only be in one catalog; check catalog ownership |
| Access review not triggering | Review not started yet, or reviewer scope issue | Check review schedule; confirm reviewer received email |
| Guest user not auto-removed after expiry | Connected org lifecycle settings not configured | Check Connected Org → "Governance" tab settings |
| Access package assignment shows "Delivered" but user lacks access | SCIM/provisioning sync lag, or app-side issue | Check app provisioning logs; trigger manual sync |
| Admin can't see catalog in portal | Missing Catalog Owner or Identity Governance Admin role | Check role assignments in Entra ID roles blade |

---

## Validation Steps

### 1. Verify licensing
```powershell
Connect-MgGraph -Scopes "Organization.Read.All","Directory.Read.All"
$sku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM_P2|IDENTITY_GOVERNANCE" }
$sku | Select-Object SkuPartNumber, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}, @{N="Consumed";E={$_.ConsumedUnits}}
```
**Good:** P2 or Governance SKU shows Enabled > 0 and sufficient Consumed licenses.  
**Bad:** No matching SKU — Entitlement Management UI will show but key features will be unavailable.

### 2. List all access packages in a catalog
```powershell
Connect-MgGraph -Scopes "EntitlementManagement.Read.All"
Get-MgEntitlementManagementAccessPackage -All | Select-Object Id, DisplayName, IsHidden, CatalogId | Format-Table -AutoSize
```

### 3. Check a specific user's assignments
```powershell
$upn = "<UserPrincipalName>"
$user = Get-MgUser -UserId $upn
Get-MgEntitlementManagementAssignment -Filter "principalId eq '$($user.Id)'" -ExpandProperty "accessPackage,target" -All |
    Select-Object Id, 
        @{N="Package";E={$_.AccessPackage.DisplayName}},
        @{N="State";E={$_.State}},
        @{N="Expiry";E={$_.Schedule.Expiration.EndDateTime}} |
    Format-Table -AutoSize
```

### 4. Check pending requests
```powershell
Get-MgEntitlementManagementRequest -Filter "state eq 'pendingApproval'" -ExpandProperty "requestor,accessPackage" -All |
    Select-Object Id,
        @{N="Requestor";E={$_.Requestor.DisplayName}},
        @{N="Package";E={$_.AccessPackage.DisplayName}},
        @{N="Created";E={$_.CreatedDateTime}} |
    Format-Table -AutoSize
```

### 5. Verify resources in a catalog
```powershell
$catalogId = "<CatalogId>"  # Get from Get-MgEntitlementManagementCatalog
Get-MgEntitlementManagementCatalogResource -AccessPackageCatalogId $catalogId -All -ExpandProperty "scopes" |
    Select-Object DisplayName, ResourceType, OriginSystem, OriginId | Format-Table -AutoSize
```
**Good:** All expected resources appear with correct `OriginSystem` (AadGroup, SharePoint, AadApplication).  
**Bad:** Missing resource — it may have been deleted from Entra/M365 without removing from catalog, causing "orphaned resource" errors.

### 6. Check audit logs for assignment activity
```powershell
# Requires AuditLog.Read.All
Get-MgAuditLogDirectoryAudit -Filter "loggedByService eq 'Entitlement Management'" -Top 50 |
    Select-Object ActivityDateTime, OperationType, Result, InitiatedBy | Format-Table -AutoSize
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — User can't request / can't see the package

```powershell
# Step 1: Get the access package ID
$packageName = "<AccessPackageDisplayName>"
$pkg = Get-MgEntitlementManagementAccessPackage -Filter "displayName eq '$packageName'"
$pkg | Select-Object Id, DisplayName, IsHidden, CatalogId

# Step 2: Get policies for this package
Get-MgEntitlementManagementAccessPackageAssignmentPolicy -AccessPackageId $pkg.Id -ExpandProperty "requestorSettings" |
    Select-Object DisplayName, @{N="AllowedRequestors";E={$_.RequestorSettings.AllowedRequestors}} | Format-List
```

Common issues:
- `IsHidden = true` → package won't appear in My Access for regular users (admin-assigned only)
- `AllowedRequestors` scope doesn't include the user's group or org
- User is already assigned (can't re-request while active assignment exists)
- User previously had assignment that was denied — denial creates a cool-down period (configurable, default 0)

```powershell
# Check if user has existing assignment
$userId = (Get-MgUser -UserId "<UPN>").Id
Get-MgEntitlementManagementAssignment -Filter "principalId eq '$userId'" -All |
    Where-Object { $_.AccessPackage.Id -eq $pkg.Id }
```

### Phase 2 — Request stuck in pending approval

```powershell
# Get pending request details
$requestId = "<RequestId>"
$request = Get-MgEntitlementManagementRequest -EntitlementManagementRequestId $requestId -ExpandProperty "approvalStages"
$request | Select-Object State, CreatedDateTime, CompletedDateTime | Format-List

# Check approver stages
Get-MgEntitlementManagementRequestApproval -EntitlementManagementRequestId $requestId -ErrorAction SilentlyContinue
```

Actions to unstick:
1. **Remind approver** via email (portal: request → Remind button)
2. **Reassign approver** if approver is unavailable (requires Global Admin or Identity Governance Admin)
3. **Approve/deny directly** via admin override in portal (Identity Governance > Access Packages > [package] > Requests)
4. **Check approver account status** — if approver account is disabled or deleted, approval stage is permanently blocked until approver is changed on the policy

```powershell
# Check approver account status
$approverUPN = "<ApproverUPN>"
Get-MgUser -UserId $approverUPN | Select-Object DisplayName, AccountEnabled, UserPrincipalName
```

### Phase 3 — Assignment granted but resources not provisioned

This is the most common production complaint. The assignment state shows "Delivered" but:
- User isn't a member of the M365 group
- User doesn't have SharePoint access
- User can't access the Teams team

```powershell
# Check assignment delivery state
$assignment = Get-MgEntitlementManagementAssignment -Filter "principalId eq '$userId' and state eq 'Delivered'" -ExpandProperty "target,accessPackage" -All |
    Where-Object { $_.AccessPackage.Id -eq $pkg.Id }
$assignment | Select-Object Id, State, @{N="Expiry";E={$_.Schedule.Expiration.EndDateTime}} | Format-List

# Check if user is actually in the target group
$groupId = "<ResourceGroupId>"
Get-MgGroupMember -GroupId $groupId | Where-Object { $_.Id -eq $userId }
```

If user isn't in the group despite "Delivered" state, the provisioning engine may have encountered an error:

```powershell
# Check provisioning logs (requires Reports.Read.All)
Get-MgAuditLogProvisioning -Filter "servicePrincipal/displayName eq 'Entitlement Management'" -Top 20 |
    Select-Object ActivityDateTime, StatusInfo, ProvisioningAction, SourceIdentity, TargetIdentity | Format-List
```

**SharePoint-specific:** SharePoint processes group membership changes asynchronously. Allow 30–60 minutes. If still not working after 60 minutes, check if the SharePoint site is using classic permissions vs. modern group-connected permissions.

### Phase 4 — Access review issues

```powershell
# List active access reviews
Connect-MgGraph -Scopes "AccessReview.Read.All"
Get-MgIdentityGovernanceAccessReviewDefinition -All |
    Select-Object DisplayName, Status, ScheduleSettings | Format-Table

# Check decisions for a specific review
$reviewId = "<ReviewId>"
Get-MgIdentityGovernanceAccessReviewDefinitionInstance -AccessReviewScheduleDefinitionId $reviewId -All |
    Select-Object Id, Status, StartDateTime, EndDateTime | Format-Table

# Get reviewer decisions
$instanceId = "<InstanceId>"
Get-MgIdentityGovernanceAccessReviewDefinitionInstanceDecision -AccessReviewScheduleDefinitionId $reviewId -AccessReviewInstanceId $instanceId -All |
    Select-Object Decision, ReviewedBy, Justification, Principal | Format-Table
```

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Manually assign access package to user (admin override)</summary>

**Scenario:** Request workflow is not suitable (e.g., onboarding new employee who needs immediate access) or request is failing and access is urgent.

```powershell
Connect-MgGraph -Scopes "EntitlementManagement.ReadWrite.All"

$userId    = (Get-MgUser -UserId "<UPN>").Id
$packageId = (Get-MgEntitlementManagementAccessPackage -Filter "displayName eq '<PackageName>'").Id

# Get the policy that allows admin-direct-assignment
$policy = Get-MgEntitlementManagementAccessPackageAssignmentPolicy -AccessPackageId $packageId |
    Where-Object { $_.RequestorSettings.ScopeType -eq "NoSubjects" -or $_.DisplayName -match "admin" } |
    Select-Object -First 1

if (-not $policy) {
    # Create a direct-assignment policy if none exists
    Write-Warning "No admin direct-assignment policy found. Use portal to create one or add user via group directly."
} else {
    # Create the assignment
    $body = @{
        requestType = "adminAdd"
        accessPackageAssignment = @{
            targetId  = $userId
            assignmentPolicyId = $policy.Id
            accessPackageId    = $packageId
        }
    }
    New-MgEntitlementManagementRequest -BodyParameter $body
    Write-Host "Admin assignment request submitted." -ForegroundColor Green
}
```

**Rollback:** Remove assignment via portal (Identity Governance > Access Packages > Assignments > Remove) or via Graph:
```powershell
$assignmentId = "<AssignmentId>"
$removeBody = @{ requestType = "adminRemove"; accessPackageAssignment = @{ id = $assignmentId } }
New-MgEntitlementManagementRequest -BodyParameter $removeBody
```

</details>

<details>
<summary>Fix 2 — Extend expiring assignment</summary>

**Scenario:** User's assignment is about to expire and needs an extension (e.g., project running longer than expected).

```powershell
Connect-MgGraph -Scopes "EntitlementManagement.ReadWrite.All"

$assignmentId = "<AssignmentId>"
$newExpiry    = (Get-Date).AddDays(90)  # Extend by 90 days

$body = @{
    requestType = "adminUpdate"
    accessPackageAssignment = @{
        id = $assignmentId
        schedule = @{
            expiration = @{
                endDateTime = $newExpiry.ToUniversalTime().ToString("o")
                type        = "afterDateTime"
            }
        }
    }
}
New-MgEntitlementManagementRequest -BodyParameter $body
Write-Host "Extension request submitted. New expiry: $newExpiry" -ForegroundColor Green
```

**Note:** The extension must be within the policy's maximum duration. If you need to exceed the policy limit, update the policy first.

</details>

<details>
<summary>Fix 3 — Bulk-assign access package via CSV</summary>

**Scenario:** Onboarding a large cohort (e.g., new department) who all need the same access package.

```powershell
<#
.SYNOPSIS  Bulk-assign an access package to multiple users from a CSV
.NOTES     CSV format: UPN column header required
           Requires EntitlementManagement.ReadWrite.All
#>
Connect-MgGraph -Scopes "EntitlementManagement.ReadWrite.All"

$csvPath   = "<Path\to\users.csv>"  # CSV with "UPN" column
$packageId = "<AccessPackageId>"
$policyId  = "<DirectAssignmentPolicyId>"  # Must be a policy with ScopeType=NoSubjects
$expiryDays = 365  # Set to 0 for no expiry

$users = Import-Csv $csvPath
$results = foreach ($row in $users) {
    $user = Get-MgUser -UserId $row.UPN -ErrorAction SilentlyContinue
    if (-not $user) {
        [PSCustomObject]@{ UPN=$row.UPN; Status="Not Found"; AssignmentId="" }
        continue
    }
    
    $expiryObj = if ($expiryDays -gt 0) {
        @{ endDateTime = (Get-Date).AddDays($expiryDays).ToUniversalTime().ToString("o"); type = "afterDateTime" }
    } else {
        @{ type = "noExpiration" }
    }
    
    try {
        $body = @{
            requestType = "adminAdd"
            accessPackageAssignment = @{
                targetId           = $user.Id
                assignmentPolicyId = $policyId
                accessPackageId    = $packageId
                schedule = @{ expiration = $expiryObj }
            }
        }
        $req = New-MgEntitlementManagementRequest -BodyParameter $body
        [PSCustomObject]@{ UPN=$row.UPN; Status="Submitted"; AssignmentId=$req.Id }
    } catch {
        [PSCustomObject]@{ UPN=$row.UPN; Status="Error: $($_.Exception.Message)"; AssignmentId="" }
    }
    Start-Sleep -Milliseconds 500  # Throttle
}

$results | Export-Csv "$env:DESKTOP\BulkAssign-Results-$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation
$results | Format-Table -AutoSize
```

</details>

<details>
<summary>Fix 4 — Clean up orphaned/stale assignments</summary>

**Scenario:** Users have left the org or changed roles but still have active assignments. Access reviews weren't enforced.

```powershell
Connect-MgGraph -Scopes "EntitlementManagement.ReadWrite.All","User.Read.All"

# Find assignments where user account is disabled or not found
$assignments = Get-MgEntitlementManagementAssignment -Filter "state eq 'Delivered'" -ExpandProperty "target,accessPackage" -All
$stale = foreach ($a in $assignments) {
    $user = Get-MgUser -UserId $a.Target.ObjectId -ErrorAction SilentlyContinue
    if (-not $user -or -not $user.AccountEnabled) {
        [PSCustomObject]@{
            AssignmentId = $a.Id
            UPN          = $a.Target.Email
            Package      = $a.AccessPackage.DisplayName
            UserEnabled  = $user.AccountEnabled ?? "Deleted"
            Expiry       = $a.Schedule.Expiration.EndDateTime
        }
    }
}

$stale | Format-Table -AutoSize
$stale | Export-Csv "$env:DESKTOP\StaleAssignments-$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation

# To remove stale assignments (review CSV first):
# $stale | ForEach-Object {
#     $body = @{ requestType = "adminRemove"; accessPackageAssignment = @{ id = $_.AssignmentId } }
#     New-MgEntitlementManagementRequest -BodyParameter $body
#     Write-Host "Removed assignment $($_.AssignmentId) for $($_.UPN)"
# }
```

**Rollback:** Re-assign via Fix 1 if a user was removed in error. Resource access is restored within minutes to hours depending on resource type.

</details>

<details>
<summary>Fix 5 — Configure guest lifecycle (auto-remove expired guests)</summary>

**Scenario:** Guest accounts linger after their access package expires because Connected Organization lifecycle settings aren't configured.

In Entra ID Portal:
1. Navigate to **Identity Governance > Entitlement Management > Connected Organizations**
2. Select the partner organization
3. Under **Governance**, enable **"Remove access when the guest's last access package expires"**

Via Graph (preview endpoint):
```powershell
Connect-MgGraph -Scopes "EntitlementManagement.ReadWrite.All"

$connectedOrgId = "<ConnectedOrgId>"  # Get from Get-MgEntitlementManagementConnectedOrganization

# Update lifecycle settings
$uri = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/connectedOrganizations/$connectedOrgId"
$body = @{
    identitySources = @()  # Preserve existing - this is an example, use PATCH carefully
    state = "configured"
} | ConvertTo-Json -Depth 5

# Note: full lifecycle settings are in beta and may change
# Best practice: configure this through the portal UI
Invoke-MgGraphRequest -Method GET -Uri $uri | ConvertTo-Json -Depth 5
```

</details>

---

## Evidence Pack

```powershell
<#
  Entitlement Management Evidence Collector
  Run as Identity Governance Administrator or Global Admin.
  Collects catalog state, access package config, pending requests, and audit activity.
  Output: $env:TEMP\EM-Evidence-<timestamp>.txt
#>
Connect-MgGraph -Scopes "EntitlementManagement.Read.All","AuditLog.Read.All","User.Read.All" -NoWelcome

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile   = "$env:TEMP\EM-Evidence-$timestamp.txt"
$sep       = "`n" + ("=" * 70) + "`n"

function Write-Section {
    param([string]$Title, [scriptblock]$Block)
    $result = try { & $Block | Out-String } catch { "ERROR: $($_.Exception.Message)" }
    Add-Content $outFile "$sep### $Title ###$sep$result"
}

Set-Content $outFile "=== Entitlement Management Evidence Pack === $(Get-Date) ==="

Write-Section "Licensing (P2/Governance)" {
    Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM_P2|IDENTITY_GOVERNANCE" } |
        Select-Object SkuPartNumber, @{N="Licensed";E={$_.PrepaidUnits.Enabled}}, @{N="Consumed";E={$_.ConsumedUnits}}
}
Write-Section "Catalogs" {
    Get-MgEntitlementManagementCatalog -All | Select-Object Id, DisplayName, State, IsExternallyVisible | Format-Table
}
Write-Section "Access Packages (all)" {
    Get-MgEntitlementManagementAccessPackage -All | Select-Object Id, DisplayName, IsHidden, CatalogId | Format-Table
}
Write-Section "Pending Requests" {
    Get-MgEntitlementManagementRequest -Filter "state eq 'pendingApproval'" -ExpandProperty "requestor,accessPackage" -All |
        Select-Object Id, @{N="Requestor";E={$_.Requestor.DisplayName}}, @{N="Package";E={$_.AccessPackage.DisplayName}}, CreatedDateTime | Format-Table
}
Write-Section "Active Assignments (last 50)" {
    Get-MgEntitlementManagementAssignment -Filter "state eq 'Delivered'" -ExpandProperty "target,accessPackage" -Top 50 |
        Select-Object Id, @{N="User";E={$_.Target.Email}}, @{N="Package";E={$_.AccessPackage.DisplayName}},
            @{N="Expiry";E={$_.Schedule.Expiration.EndDateTime}} | Format-Table
}
Write-Section "Recent EM Audit Events (last 7 days)" {
    Get-MgAuditLogDirectoryAudit -Filter "loggedByService eq 'Entitlement Management' and activityDateTime ge $((Get-Date).AddDays(-7).ToString('o'))" -Top 50 |
        Select-Object ActivityDateTime, OperationType, Result, @{N="Initiator";E={$_.InitiatedBy.User.UserPrincipalName}} | Format-Table
}

Write-Host "Evidence saved to: $outFile" -ForegroundColor Green
Invoke-Item (Split-Path $outFile)
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| List all catalogs | `Get-MgEntitlementManagementCatalog -All \| Select-Object Id, DisplayName, State` |
| List access packages | `Get-MgEntitlementManagementAccessPackage -All \| Select-Object Id, DisplayName, IsHidden` |
| List packages in catalog | `Get-MgEntitlementManagementAccessPackage -Filter "catalogId eq '<id>'" -All` |
| Get package policies | `Get-MgEntitlementManagementAccessPackageAssignmentPolicy -AccessPackageId '<id>'` |
| List pending requests | `Get-MgEntitlementManagementRequest -Filter "state eq 'pendingApproval'" -All` |
| Get user's assignments | `Get-MgEntitlementManagementAssignment -Filter "principalId eq '<userId>'" -All` |
| List catalog resources | `Get-MgEntitlementManagementCatalogResource -AccessPackageCatalogId '<id>' -All` |
| List connected orgs | `Get-MgEntitlementManagementConnectedOrganization -All` |
| Get access reviews | `Get-MgIdentityGovernanceAccessReviewDefinition -All` |
| Check EM audit logs | `Get-MgAuditLogDirectoryAudit -Filter "loggedByService eq 'Entitlement Management'" -Top 50` |
| Force-assign to user | See Remediation Fix 1 |
| Bulk assign from CSV | See Remediation Fix 3 |
| Find stale assignments | See Remediation Fix 4 |

---

## 🎓 Learning Pointers

- **Entitlement Management is not the same as Access Reviews** — they are complementary features. EM manages the request/approval/lifecycle of access. Access Reviews periodically validate that existing access is still appropriate. Both require P2. You can have access packages *without* access reviews (lifecycle by expiry only), but access reviews add the human-validation layer. See: [What is Entitlement Management?](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-overview)

- **Each resource can only live in one catalog.** This is the most common architecture mistake. If you try to add a SharePoint site or M365 group to a second catalog, it fails silently or throws a conflict. Design your catalog structure around organizational boundaries (department, project, business unit) before building access packages. See: [Manage resources in catalogs](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-catalog-create)

- **Provisioning delays are by design, not bugs.** SharePoint and Teams process group membership changes asynchronously. A "Delivered" assignment state means Entra has written the group membership — it does NOT mean SharePoint or Teams has processed it yet. The propagation can take up to 60 minutes for SharePoint and 30 minutes for Teams. Communicate this to users and help desk rather than re-triggering assignments. See: [Access package resource roles](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-resources)

- **The My Access portal URL is myaccess.microsoft.com** — not a URL most users know by heart. Include this in your onboarding documentation and IT knowledge base. External (B2B) guests use the same portal after accepting their invitation. You can also generate direct links to specific access packages (Identity Governance > Access Packages > Properties > Copy link). See: [Request access to an access package](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-request-access)

- **Access packages support custom questions for business justification.** Policies can include free-text or multiple-choice questions that appear at request time (e.g., "What project is this for?" or "Approve by which date?"). Answers are stored with the request and visible to approvers and auditors. This is a powerful compliance control — use it to capture business context at the time of access grant. See: [Change approval and requestor information settings](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-approval-policy)

- **Separation of Duties (SoD) constraints are available in Microsoft Entra ID Governance.** If you have the Governance license (not just P2), you can configure *incompatible access packages* — where having one package prevents requesting another (e.g., someone in "Finance Approvers" can't also hold "Finance Submitters"). This is a powerful control for segregation of duty compliance in regulated industries. See: [Separation of duties for access packages](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-incompatible)
