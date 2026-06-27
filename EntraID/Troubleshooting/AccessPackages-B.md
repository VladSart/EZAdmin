# Entra Entitlement Management — Access Packages Hotfix Runbook (Mode B: Ops)
> Fix or escalate access package assignment and delivery failures in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run these in order. Connect with `Connect-MgGraph -Scopes "EntitlementManagement.Read.All","User.Read.All"` first.

```powershell
# 1. Check if the catalog containing the access package exists and is enabled
Get-MgEntitlementManagementAccessPackageCatalog | Select-Object DisplayName, State, IsExternallyVisible

# 2. List access packages in the tenant and their state
Get-MgEntitlementManagementAccessPackage -All | Select-Object DisplayName, IsHidden, Id

# 3. Check pending/active assignments for a specific user
$userId = (Get-MgUser -Filter "userPrincipalName eq '<UPN>'").Id
Get-MgEntitlementManagementAssignment -Filter "accessPackageAssignment/targetId eq '$userId'" -All |
  Select-Object State, ExpiredDateTime, @{N="Package";E={$_.AccessPackage.DisplayName}}

# 4. Check recent assignment requests (last 24h) — catch failed deliveries
Get-MgEntitlementManagementAssignmentRequest -All |
  Where-Object {$_.CreatedDateTime -gt (Get-Date).AddHours(-24)} |
  Select-Object State, RequestType, @{N="UPN";E={$_.Requestor.Id}}, @{N="Package";E={$_.AccessPackageAssignment.AccessPackage.DisplayName}}

# 5. Check if the requesting user is blocked by Connected Organization policy
Get-MgEntitlementManagementConnectedOrganization -All | Select-Object DisplayName, State, @{N="Domains";E={($_.IdentitySources | ForEach-Object {$_.DomainName}) -join ","}}
```

**Interpretation table:**

| What you see | Most likely cause | Go to |
|---|---|---|
| Assignment State = `PendingApproval` (>24h) | Approver hasn't acted / approval policy misconfigured | Fix 1 |
| Assignment State = `Delivered` but user has no access | Resource role sync lag or group membership not propagated | Fix 2 |
| Request State = `Denied` | Policy conditions not met (scope, Connected Org, expiry) | Fix 3 |
| Access package not visible to user | `IsHidden = true` or wrong Connected Organization state | Fix 4 |
| Assignment expires immediately after grant | Expiry policy misconfigured or end date in past | Fix 5 |

---
## Dependency Cascade

<details><summary>What must be true for an access package assignment to deliver access</summary>

```
Entra ID tenant (P2 license required for Entitlement Management)
 └── Entitlement Management
      └── Catalog (State: Published)
           └── Access Package (IsHidden: false for requestors)
                ├── Resource roles (Groups / Apps / SharePoint sites)
                │    └── Resource provisioned and not orphaned
                ├── Assignment Policy
                │    ├── Requestor scope (specific users / All members / Connected Org / Anyone)
                │    ├── Approval workflow (0-3 approvers, backup approvers if >14 day SLA)
                │    └── Expiry (No expiry / Fixed date / Number of days)
                └── Assignment
                     ├── State: PendingApproval → Approved → Delivering → Delivered
                     └── Resource role assignments written to AAD groups / app roles
```

**Licensing gate:** Entitlement Management requires **Entra ID P2** or **Microsoft Entra ID Governance** for requestors AND approvers. Users without the right license can request but assignments will fail silently.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm P2/Governance license is assigned to the affected user:**
   ```powershell
   (Get-MgUserLicenseDetail -UserId '<UPN>').SkuPartNumber
   # Must contain: AAD_PREMIUM_P2, ENTERPRISEPREMIUM, or MICROSOFT_ENTRA_ID_GOVERNANCE
   ```
   Expected: License listed. Bad: Empty or only P1 (`AAD_PREMIUM`).

2. **Verify the catalog is Published (not Unpublished):**
   ```powershell
   Get-MgEntitlementManagementAccessPackageCatalog -AccessPackageCatalogId '<catalogId>' |
     Select-Object DisplayName, State
   # Expected: State = Published
   ```

3. **Check the assignment policy allows the requesting user type:**
   ```powershell
   Get-MgEntitlementManagementAccessPackageAssignmentPolicy -AccessPackageId '<packageId>' |
     Select-Object DisplayName, @{N="AllowedRequestorScope";E={$_.RequestorSettings.ScopeType}}
   # Valid values: NoSubjects, SpecificDirectorySubjects, SpecificConnectedOrganizationSubjects,
   #               AllMemberUsers, AllExistingDirectoryMemberUsers, AllExistingConnectedOrganizationSubjects
   ```
   Expected: Scope matches user type. Bad: `NoSubjects` = no one can request.

4. **Check if assignment is stuck in `Delivering` state (resource role write-back failed):**
   ```powershell
   Get-MgEntitlementManagementAssignment -Filter "state eq 'Delivering'" -All |
     Select-Object Id, @{N="Package";E={$_.AccessPackage.DisplayName}}, @{N="Target";E={$_.Target.Email}}
   ```
   Expected: Empty. Bad: Assignments here for >30 min = resource provisioning failure.

5. **Verify the resource (group) in the access package exists and is not deleted:**
   ```powershell
   # Get resources in the access package
   Get-MgEntitlementManagementAccessPackageResourceRoleScope -AccessPackageId '<packageId>' |
     Select-Object @{N="Resource";E={$_.AccessPackageResourceRole.DisplayName}},
                   @{N="ResourceId";E={$_.AccessPackageResource.OriginId}}
   # Then validate the group
   Get-MgGroup -GroupId '<resourceGroupId>' | Select-Object DisplayName, Id, DeletedDateTime
   ```
   Expected: Group exists, `DeletedDateTime` is null.

6. **For external users — check Connected Organization state:**
   ```powershell
   Get-MgEntitlementManagementConnectedOrganization -All |
     Where-Object {$_.IdentitySources.DomainName -contains '<externalDomain>'} |
     Select-Object DisplayName, State
   # Expected: State = Configured
   # Bad: State = Proposed (not approved yet) or not present at all
   ```

---
## Common Fix Paths

<details><summary>Fix 1 — Approval stuck / approver not responding</summary>

**Symptom:** Assignment in `PendingApproval` for >14 days or approver reports no email received.

**Diagnose:**
```powershell
# Get the request ID
$req = Get-MgEntitlementManagementAssignmentRequest -All |
  Where-Object {$_.State -eq 'PendingApproval'} |
  Select-Object Id, @{N="Package";E={$_.AccessPackageAssignment.AccessPackage.DisplayName}}

# Check who the approvers are in the policy
Get-MgEntitlementManagementAccessPackageAssignmentPolicy -AccessPackageId '<packageId>' |
  Select-Object -ExpandProperty ApprovalSettings |
  Select-Object -ExpandProperty ApprovalStages |
  ForEach-Object { $_.PrimaryApprovers | Select-Object Description, @{N="Type";E={$_.OdataType}} }
```

**Fix — add backup approver or reassign:**
1. In Entra portal → Identity Governance → Access Packages → [package] → Policies → Edit policy
2. Under Approval, enable **Backup approvers** or change the primary approver
3. Set escalation timeout (recommend 3 days) to auto-escalate

**Emergency: admin direct assignment (bypasses approval):**
```powershell
$body = @{
    requestType = "adminAdd"
    accessPackageAssignment = @{
        targetId = "<targetUserId>"
        assignmentPolicyId = "<policyId>"
        accessPackageId = "<packageId>"
    }
}
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentRequests" -Body ($body | ConvertTo-Json -Depth 5)
```

**Rollback:** Remove assignment via portal or `adminRemove` request type.

</details>

<details><summary>Fix 2 — Assignment delivered but user has no actual access</summary>

**Symptom:** Assignment shows `Delivered` but user can't access the resource (app, SharePoint, group content).

**Diagnose:**
```powershell
# Confirm group membership was written
$groupId = '<resourceGroupId>'
$userId = (Get-MgUser -Filter "userPrincipalName eq '<UPN>'").Id
Get-MgGroupMember -GroupId $groupId | Where-Object {$_.Id -eq $userId}
```

Expected: User returned. If empty, membership wasn't written.

**Fix — force re-evaluation:**
1. In Entra portal → Identity Governance → Access Packages → [package] → Assignments
2. Find the user's assignment → click **Reprocess**

Or via Graph:
```powershell
$assignmentId = '<assignmentId>'
Invoke-MgGraphRequest -Method POST `
  -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignments/$assignmentId/reprocess"
```

**If SharePoint site access is the resource:**
- SharePoint permission sync can take 15-30 min after group membership writes
- Verify the group is connected to the SharePoint site: SharePoint Admin → Site → Permissions → check group is listed
- If group is M365 Group: membership change propagates to SharePoint via background job — wait up to 60 min

</details>

<details><summary>Fix 3 — Request denied by policy</summary>

**Symptom:** User submits request, immediately denied. Error: "You are not allowed to request this access package."

**Diagnose:**
```powershell
# Get denial reason from audit log
Get-MgAuditLogDirectoryAudit -Filter "category eq 'EntitlementManagement' and result eq 'failure'" -Top 20 |
  Select-Object ActivityDisplayName, ResultReason, @{N="Time";E={$_.ActivityDateTime}} |
  Format-Table -AutoSize
```

**Common denial causes and fixes:**

| Denial reason | Fix |
|---|---|
| User not in allowed scope | Edit policy Requestor scope — add user or change to `AllMemberUsers` |
| External user domain not in Connected Organization | Add Connected Organization for the external domain |
| User already has active assignment | Remove expired/active assignment first, then re-request |
| Access package has `IsHidden = true` | Unhide or use direct assignment link |

**Fix policy scope:**
```powershell
# Patch policy to allow all member users
$policyUpdate = @{
    requestorSettings = @{
        scopeType = "AllMemberUsers"
        acceptRequests = $true
    }
}
Update-MgEntitlementManagementAccessPackageAssignmentPolicy `
  -AccessPackageAssignmentPolicyId '<policyId>' `
  -BodyParameter ($policyUpdate | ConvertTo-Json -Depth 5)
```

</details>

<details><summary>Fix 4 — Access package not visible to users in MyAccess portal</summary>

**Symptom:** User goes to myaccess.microsoft.com — package not listed.

**Diagnose:**
```powershell
Get-MgEntitlementManagementAccessPackage -AccessPackageId '<packageId>' |
  Select-Object DisplayName, IsHidden
# Hidden = true → not visible

Get-MgEntitlementManagementAccessPackageCatalog -AccessPackageCatalogId '<catalogId>' |
  Select-Object State, IsExternallyVisible
# State must be Published
# IsExternallyVisible = true for external/guest users
```

**Fix:**
```powershell
# Unhide the access package
Update-MgEntitlementManagementAccessPackage -AccessPackageId '<packageId>' -IsHidden:$false

# Publish the catalog
Update-MgEntitlementManagementAccessPackageCatalog -AccessPackageCatalogId '<catalogId>' -State 'Published'
```

For **external users** who can't see it: ensure `IsExternallyVisible = true` on the catalog AND the Connected Organization state is `Configured` (not `Proposed`).

</details>

<details><summary>Fix 5 — Assignment expires immediately or has wrong duration</summary>

**Symptom:** User gets access then loses it within minutes/hours, or assignment shows expiry in the past.

**Diagnose:**
```powershell
Get-MgEntitlementManagementAccessPackageAssignmentPolicy -AccessPackageId '<packageId>' |
  Select-Object DisplayName -ExpandProperty ExpirationSettings |
  Select-Object DisplayName, ExpirationType, DurationInDays, ExpirationDateTime
```

**Fix — update expiry policy:**
```powershell
$expiryFix = @{
    expirationSettings = @{
        expirationType = "afterDuration"   # Options: notSpecified, noExpiration, afterDuration, afterDateTime
        durationInDays = 365
    }
}
Update-MgEntitlementManagementAccessPackageAssignmentPolicy `
  -AccessPackageAssignmentPolicyId '<policyId>' `
  -BodyParameter ($expiryFix | ConvertTo-Json -Depth 5)
```

**Note:** Existing assignments are NOT retroactively updated. Users with expired assignments must re-request or receive an admin assignment.

**Rollback:** Revert `durationInDays` to previous value, or set `expirationType = "noExpiration"` for testing.

</details>

---
## Escalation Evidence

```
ESCALATION TICKET — Entra Entitlement Management / Access Packages

Tenant ID:          _______________
Package Name:       _______________
Package ID:         _______________
Catalog ID:         _______________
Affected UPN:       _______________
Assignment ID:      _______________
Request ID:         _______________
Assignment State:   _______________
Request State:      _______________

User License (P2?): _______________
Catalog State:      _______________
Policy Scope Type:  _______________
Policy Expiry Type: _______________

Error / Denial Reason (from audit log):
_______________________________________________

Resource (Group/App/SP Site) confirmed exists?  YES / NO
Connected Organization (if external): _______________  State: _______________

Steps already attempted:
- [ ] Reprocessed assignment
- [ ] Verified license
- [ ] Checked policy requestor scope
- [ ] Validated Connected Organization state
- [ ] Confirmed resource/group not deleted

Audit Log Reference (ActivityDateTime):  _______________
```

---
## 🎓 Learning Pointers

- **P2 license gate is silent:** If requestors/approvers lack Entra ID P2 or Governance licenses, requests may be silently denied or stuck. Always license-check first before debugging policy logic. See: [Entitlement Management licensing](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-overview#license-requirements)

- **`Delivering` ≠ delivered:** The pipeline writes group memberships asynchronously. SharePoint access can lag 15–60 minutes after the state shows `Delivered`. Use **Reprocess** on the assignment to trigger a fresh write-back if >30 minutes have passed.

- **Connected Organization `Proposed` state:** When an external user from an unknown domain first requests access, Entra auto-creates a Connected Organization in `Proposed` state. Admins must approve it (`Configured`) before subsequent requests from that domain can succeed. This catches many teams off guard. See: [Connected Organizations](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-organization)

- **Policy scope vs. catalog visibility:** A package can be visible (`IsHidden = false`) but still un-requestable if the policy scope is `NoSubjects`. These are independent controls — check both when a user says they "can see but can't request."

- **Graph API for bulk operations:** The MyAccess portal is user-facing only. For bulk assignments, admin assignments, or automation, use the Graph `identityGovernance/entitlementManagement` namespace. The `adminAdd` request type bypasses approval workflows — useful for migrations. See: [Entitlement Management Graph API](https://learn.microsoft.com/en-us/graph/api/resources/entitlementmanagement-overview)

- **Audit log is your friend:** All access package events appear in Entra audit logs under Category = `EntitlementManagement`. Filter on this category in the portal or via `Get-MgAuditLogDirectoryAudit` to trace the exact denial reason — don't guess from the UI error message alone.
