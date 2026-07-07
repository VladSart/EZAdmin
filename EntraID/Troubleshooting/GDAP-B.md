# GDAP (Granular Delegated Admin Privileges) — Hotfix Runbook (Mode B: Ops)
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

Run these signed into **Microsoft Graph as an Admin Agent in the PARTNER tenant** (not the customer tenant — GDAP relationships and role assignments are partner-tenant objects that project rights *into* the customer tenant):

```powershell
# 1. Connect and confirm you're in the partner (CSP) tenant context
Connect-MgGraph -Scopes "DelegatedAdminRelationship.Read.All","DelegatedAdminRelationship.ReadWrite.All" -NoWelcome
(Get-MgContext).TenantId

# 2. List all GDAP relationships and their status
Get-MgTenantRelationshipDelegatedAdminRelationship |
    Select-Object DisplayName, Status, Customer, CreatedDateTime, EndDateTime |
    Format-Table -AutoSize

# 3. Check a specific customer's relationship in detail (find the ID from step 2)
$relationshipId = "<delegatedAdminRelationshipId>"
Get-MgTenantRelationshipDelegatedAdminRelationship -DelegatedAdminRelationshipId $relationshipId |
    Select-Object Id, Status, AccessDetails, EndDateTime, AutoExtendDuration | Format-List

# 4. List the access assignments (role <-> security group mappings) for that relationship
Get-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment -DelegatedAdminRelationshipId $relationshipId |
    Select-Object Id, Status, AccessContainer, AccessDetails | Format-List

# 5. Confirm the affected partner user is actually a MEMBER (not guest) of the mapped security group
Get-MgGroupMember -GroupId "<securityGroupId>" | Select-Object Id, AdditionalProperties
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| `Status = approvalPending` and >90 days old | Request expired — customer never actioned it | Fix 1 — recreate the relationship request |
| `Status = active` but user still denied in customer tenant | Access assignment or group membership problem | Fix 2 — verify security group mapping |
| `Status = terminated` or `EndDateTime` in the past | Relationship expired or was terminated by customer | Fix 1 — recreate (note: same name blocked for 365 days — see Learning Pointers) |
| User is a **guest** in the security group instead of a native member | GDAP does not honor guest members in access-assignment groups | Fix 3 — replace with native partner-tenant member account |
| Customer reports "all partner/CSP access blocked" tenant-wide | A Conditional Access policy is blocking Service Provider users | Fix 4 — exclude Service Provider users from the CA policy |
| Customer admin locked out, can't approve/action anything | No Privileged Authentication Administrator role granted yet | Fix 5 — bootstrap access via Microsoft-led recovery path |

---
## Dependency Cascade

<details><summary>What must be true for a partner user to actually get into a customer tenant via GDAP</summary>

```
Partner Admin Agent creates GDAP relationship request (Partner Center)
    │
    ▼
Customer Global Admin approves request (link expires in 90 days if ignored)
    │
    ▼
Relationship status = Active (max duration 2 years; Auto Extend can push +6 months at a time)
    │
    ▼
Partner creates/selects Microsoft Entra Security Group(s) IN THE PARTNER TENANT
    │       (limit: 100 security groups per customer)
    │
    ├── Group members MUST be native partner-tenant Member accounts
    │       └── Guest accounts in the group = broken access, silently
    │
    ▼
Partner assigns Microsoft Entra built-in role(s) to each security group
    (Access Assignment — roles must be ones the customer consented to
     in the original relationship request, or the assignment fails)
    │
    ▼
Customer tenant provisions the delegated role for group members
    │
    ├── Conditional Access in the CUSTOMER tenant
    │       └── Must not block "Service provider users" external user type
    │               (a CA policy targeting all guests/externals can lock out GDAP)
    │
    └── Partner user signs in against the CUSTOMER tenant using their delegated role
            └── If role = Global Admin, relationship CANNOT be Auto Extended
                    (Global Admin GDAP must always be manually renewed)
```

**Key distinction from legacy DAP:** DAP granted blanket Global Admin via the Admin Agents security group with no expiry. GDAP replaces that with named, role-scoped, time-bound relationships — there is no "just add them to Admin Agents" shortcut anymore for anything GDAP-managed.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm which side owns the problem — partner tenant object, or customer tenant enforcement.**
   GDAP relationships, access assignments, and security groups are **partner-tenant** objects. Role *enforcement* (Conditional Access, MFA, sign-in blocks) happens in the **customer tenant**. A ticket that says "partner can't access customer tenant" can be broken on either side — check both.

2. **Check relationship status and expiry**
   ```powershell
   Get-MgTenantRelationshipDelegatedAdminRelationship |
       Where-Object { $_.Customer.DisplayName -like "*<CustomerName>*" } |
       Select-Object DisplayName, Status, EndDateTime, AutoExtendDuration
   ```
   `approvalPending` past 90 days = dead, must be recreated. `active` with `EndDateTime` soon and `AutoExtendDuration = P0D` (disabled) = about to silently expire.

3. **Check the access assignment maps to the correct role and hasn't drifted**
   ```powershell
   Get-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment -DelegatedAdminRelationshipId $relationshipId |
       Select-Object -ExpandProperty AccessDetails
   ```
   Compare the `unifiedRoles` GUIDs against what the ticket says the partner user needs (e.g., Exchange Administrator, Intune Administrator). A role not in this list was never consented to by the customer and **cannot** be added without a new relationship request.

4. **Check the security group membership in the PARTNER tenant**
   ```powershell
   Get-MgGroupMember -GroupId "<securityGroupId>" | ForEach-Object {
       Get-MgUser -UserId $_.Id -Property UserPrincipalName, UserType
   } | Select-Object UserPrincipalName, UserType
   ```
   Any `UserType = Guest` here is a broken member for GDAP purposes — GDAP only honors native members.

5. **Check for a Conditional Access policy in the CUSTOMER tenant blocking service provider access**
   Customer tenant → Entra → Security → Conditional Access → review policies targeting "Guests or external users." If **Service provider users** isn't explicitly excluded and the policy blocks external/guest sign-ins broadly, GDAP sign-ins get caught in the same net.

---
## Common Fix Paths

<details><summary>Fix 1 — GDAP relationship expired or stuck in Approval Pending</summary>

**Symptoms:** `Status = approvalPending` for >90 days, or `Status = terminated`/`EndDateTime` in the past. Partner has zero access to the customer tenant.

There is no PowerShell "reactivate" — expired/terminated relationships must be recreated from Partner Center or via API:

```powershell
# Recreate via Graph — mirrors the roles/duration of the original relationship
$params = @{
    displayName    = "<RelationshipName>"
    customer       = @{ tenantId = "<customerTenantId>" }
    accessDetails  = @{
        unifiedRoles = @(
            @{ roleDefinitionId = "<roleGuid1>" }
            @{ roleDefinitionId = "<roleGuid2>" }
        )
    }
    duration       = "P2Y"   # max 2 years
    autoExtendDuration = "PT0S"  # or "P180D" to enable auto-extend
}
New-MgTenantRelationshipDelegatedAdminRelationship -BodyParameter $params
```

This creates a **new** approval request — the customer Global Admin must approve it again before it becomes active.

**Naming gotcha:** if the old relationship was terminated (not just expired), the same `displayName` cannot be reused for 365 days. Use a suffixed name (e.g., `-v2`) if you hit a name conflict.

**Portal path:** Partner Center → Customers → [customer] → Admin relationships → New relationship.

</details>

<details><summary>Fix 2 — Relationship is Active but the user is still denied access</summary>

**Symptoms:** `Get-MgTenantRelationshipDelegatedAdminRelationship` shows `Status = active`, correct role is in the access assignment, but the specific user still can't perform the action in the customer tenant.

```powershell
# 1. Confirm the user is a member of the mapped security group
Get-MgGroupMember -GroupId "<securityGroupId>" |
    Where-Object { $_.Id -eq (Get-MgUser -UserId "<user@partnertenant.com>").Id }

# 2. If missing, add them
New-MgGroupMember -GroupId "<securityGroupId>" -DirectoryObjectId (Get-MgUser -UserId "<user@partnertenant.com>").Id

# 3. Confirm the access assignment itself is not still provisioning
Get-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment -DelegatedAdminRelationshipId $relationshipId |
    Select-Object Id, Status
# Status should be "active" — "pending" can take several minutes to finish provisioning
```

Group membership changes can take a few minutes to propagate into the customer tenant. If still blocked after 15 minutes, verify the role itself (Fix below on wrong-role-consented) and check for a Conditional Access block (Fix 4).

**Rollback:** `Remove-MgGroupMemberByRef` to pull the user back out if this was a temporary escalation.

</details>

<details><summary>Fix 3 — Guest account in the access-assignment security group</summary>

**Symptoms:** Everything looks correctly configured (active relationship, correct role, group has the user) but access still silently fails. `UserType = Guest` on the member.

```powershell
# Identify guest members polluting a GDAP-mapped security group
Get-MgGroupMember -GroupId "<securityGroupId>" | ForEach-Object {
    $u = Get-MgUser -UserId $_.Id -Property UserPrincipalName, UserType
    if ($u.UserType -eq "Guest") { Write-Host "GUEST FOUND: $($u.UserPrincipalName)" -ForegroundColor Red }
}
```

**Fix:** the affected person must have (or be given) a native Member account in the **partner** tenant — not a guest invite — and that native account added to the security group instead. There is no supported way to make GDAP honor a guest member of an access-assignment group.

</details>

<details><summary>Fix 4 — Conditional Access blocking partner/GDAP sign-in (customer tenant)</summary>

**Symptoms:** Customer reports "our partner/MSP suddenly can't get in" right after a new or tightened CA policy targeting external/guest users.

**Portal path (customer tenant):** Entra → Security → Conditional Access → [the blocking policy] → Users → Include/Exclude → Guest or external users → ensure **Service provider users** is explicitly excluded (or scoped out) rather than swept up in a blanket "All guests and external users" include.

```powershell
# In the CUSTOMER tenant — list CA policies that target guest/external users broadly
Get-MgIdentityConditionalAccessPolicy | Where-Object {
    $_.Conditions.Users.IncludeGuestsOrExternalUsers -or $_.Conditions.Users.ExcludeGuestsOrExternalUsers
} | Select-Object DisplayName, State
```

**Rollback:** remove the Service Provider exclusion if it was added in error.

</details>

<details><summary>Fix 5 — Customer admin locked out, can't approve/action a GDAP request</summary>

**Symptoms:** Customer's only Global Admin lost their MFA device/password and can't log in to approve a pending GDAP relationship or manage anything.

1. Request the **Privileged Authentication Administrator** role be included in the very first GDAP relationship with any new customer — this is the role that lets a partner reset another admin's password and re-register their authentication methods. If it isn't already in an active relationship, it cannot be bootstrapped without the customer performing self-service recovery first.
2. Point the customer at self-service password reset (SSPR) if it was configured in advance — this is the intended safety net for exactly this scenario.
3. If neither applies, this becomes a Microsoft support case (customer must prove tenant ownership) — there is no partner-side bypass.

**Prevention:** always include Privileged Authentication Administrator (or ensure SSPR is enabled) on new customer onboarding, before this becomes an emergency.

</details>

---
## Escalation Evidence

```
=== GDAP Relationship Escalation Pack ===
Date/Time:
Partner Tenant ID:
Customer Tenant ID / Name:
Relationship Display Name:
Relationship ID:
Relationship Status (active/approvalPending/terminated):
End Date / Auto Extend setting:

Access Assignment:
  Security Group ID:
  Security Group Name:
  Roles assigned (name + roleDefinitionId):

Affected partner user UPN:
  Member of security group? (Y/N):
  UserType (Member/Guest):

Customer-side Conditional Access:
  Any policy targeting Guests/External users? (Y/N):
  "Service provider users" excluded? (Y/N):

Error message / symptom from user (verbatim):

Steps already tried:
  [ ] Checked relationship status and expiry
  [ ] Checked access assignment role mapping
  [ ] Checked security group membership + UserType
  [ ] Checked customer-tenant Conditional Access policies
  [ ] Attempted group re-add / waited 15 min for propagation
```

---
## 🎓 Learning Pointers

- **GDAP relationships and security groups live in the PARTNER tenant, not the customer tenant.** This trips up engineers used to troubleshooting "normal" role assignments, where the fix is always in the tenant where access is denied. Here, the fix is almost always on the partner side. See: [GDAP introduction](https://learn.microsoft.com/en-us/partner-center/customers/gdap-introduction)

- **Guest members silently break GDAP access assignments.** There's no error message pointing at this — access just doesn't work. If everything else checks out (active relationship, correct role, group has the right user), check `UserType` on the group member before anything else.

- **GDAP relationship requests expire in 90 days if the customer never approves them** — and terminated/expired relationship names are locked for reuse for 365 days. Plan naming conventions (e.g., append a date or version suffix) so a stuck request doesn't block you from quickly recreating it.

- **Auto Extend only pushes the end date +6 months at a time, and never applies to a Global Administrator role assignment** — that one must always be manually renewed. Use [GDAP relationship analytics](https://learn.microsoft.com/en-us/partner-center/insights/gdap-relationship-analytics) in Partner Center to track upcoming expirations instead of waiting for a customer to notice access broke.

- **Conditional Access has a dedicated "Service provider users" external-user type** specifically so customers can exclude CSP/GDAP access from broad guest-blocking policies without having to fully exempt all external users. Point customers at this instead of asking them to disable the policy entirely. See: [Conditional Access for external users](https://learn.microsoft.com/en-us/azure/active-directory/external-identities/authentication-conditional-access)

- **GDAP replaced DAP for a reason — don't recreate DAP's problem with GDAP.** It's tempting to just assign Global Admin to every customer relationship to "make it work." Use [least privileged roles by task](https://learn.microsoft.com/en-us/azure/active-directory/roles/delegate-by-task) and [GDAP role guidance](https://learn.microsoft.com/en-us/partner-center/customers/gdap-least-privileged-roles-by-task) to scope each relationship to what the engagement actually requires.
