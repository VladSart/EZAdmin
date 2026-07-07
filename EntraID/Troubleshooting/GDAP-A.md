# GDAP (Granular Delegated Admin Privileges) — Reference Runbook (Mode A: Deep Dive)
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
- Granular Delegated Admin Privileges (GDAP) relationships between a Microsoft Cloud Solution Provider (CSP) partner and their customer tenants
- Relationship lifecycle: request → customer approval → active → expiry/termination
- Access Assignments (security group ↔ Microsoft Entra role mapping)
- Interaction with Conditional Access in the customer tenant
- Azure RBAC access via GDAP (Azure Managers pattern)
- Legacy DAP (Delegated Admin Privileges) as context for why GDAP exists and what it replaced

**Not in scope:**
- Azure Lighthouse (a separate, Azure-Resource-Manager-level cross-tenant delegation model — does not use GDAP relationships or Entra roles the same way)
- Multi-Tenant Organization (MTO) — explicitly mutually exclusive with a CSP/GDAP relationship; a service provider cannot be part of an MTO with its customer
- General Entra Cross-Tenant Access Settings (XTAS) for B2B collaboration between two independent organizations — see `CrossTenant-A.md`/`CrossTenant-B.md`. GDAP is a distinct, purpose-built delegation model for the CSP/reseller relationship, not general B2B.

**Assumed knowledge:**
- Familiar with Entra ID built-in roles and RBAC concepts
- Has (or is working with someone who has) the Admin Agent role in a Partner Center / CSP partner tenant
- Comfortable with Microsoft Graph PowerShell (`Microsoft.Graph.Identity.Partner` module)

---

## How It Works

<details><summary>Full architecture</summary>

### Why GDAP exists

Before GDAP, CSP partners managed customer tenants via **DAP (Delegated Admin Privileges)**: any partner user added to the **Admin Agents** security group in the partner tenant received **Global Administrator** access to *every* customer tenant the partner had a DAP relationship with — indefinitely, with no expiry, no scoping, and no per-customer partitioning. This was flagged repeatedly as a major supply-chain risk: compromise one partner's Admin Agents group and every one of that partner's customers is exposed at Global Admin level.

GDAP replaces that blanket model with:
1. **Named, per-customer relationships** instead of one global Admin Agents grant
2. **Role-scoped access** — the customer explicitly consents to a specific list of Entra built-in roles, not "everything"
3. **Time-bound duration** — every relationship has an end date; nothing is permanent
4. **Zero Trust default** — the partner starts with *no* access; access must be explicitly requested, explicitly approved, and explicitly assigned down to named security groups

### The three-layer model

```
Layer 1 — Relationship (partner ↔ customer, Partner Center object)
    Defines: which customer, which Entra roles are IN SCOPE, how long, auto-extend Y/N

Layer 2 — Access Assignment (partner tenant object, created after relationship is Active)
    Defines: which security group(s) in the PARTNER tenant map to which of the
    in-scope roles. Multiple groups can be mapped to different roles for the
    same relationship (e.g., "Tier1-Helpdesk" group → Helpdesk Administrator,
    "Tier2-Engineers" group → Exchange Administrator + Intune Administrator)

Layer 3 — Group Membership (partner tenant object, ordinary Entra group membership)
    Defines: which individual partner users actually get the delegated access,
    by virtue of being a MEMBER (not guest) of a mapped security group
```

Nothing about this lives in the customer tenant except the *effect* — a security-group-to-role mapping projected in as if it were a native role assignment. The customer's Entra ID shows GDAP-derived role assignments distinctly (as "delegated" / partner-managed) but neither the security groups nor their membership are customer-tenant objects.

### Relationship lifecycle and timers

| Timer | Value | Notes |
|---|---|---|
| Approval request expiry | 90 days | If the customer's Global Admin never approves, the request simply expires — no relationship is created |
| Maximum relationship duration | 2 years | Cannot be made permanent under any circumstances |
| Auto Extend increment | +6 months (180 days) per extension | Applied automatically at the end date if enabled; can be toggled on an *active* relationship without new customer consent |
| Auto Extend exception | Global Administrator role assignments | Cannot be auto-extended — always requires manual renewal, by design, since it's the highest-privilege role available |
| Relationship name reuse cooldown | 365 days | After termination or expiry, the same `displayName` is blocked from reuse for a full year — plan naming with a version/date suffix to avoid getting stuck |

### Security group constraints

- **Hard limit: 100 security groups per customer** across all of a partner's Access Assignments for that customer. This is a Partner Center/GDAP-specific ceiling, not a general Entra group limit.
- **Groups must contain native Member accounts from the partner tenant.** Guest accounts do not work as GDAP access-assignment group members — this is a documented, hard limitation, not a misconfiguration on the customer's part. If a partner user was invited as a guest into their own partner tenant for any reason, they must instead exist there as a native member for GDAP purposes.
- **Best practice for Azure access:** rather than granting broad Entra roles, create a dedicated group (commonly named something like *Azure Managers*), nest it under Admin Agents, and assign it the least-privileged Entra role needed (Directory Readers is the documented minimum) — Azure RBAC ownership is then layered on top of that inside the customer's Azure subscription, not via the Entra role itself.

### Interaction with Conditional Access

Customer tenants increasingly run Conditional Access policies that target "Guests or external users" broadly (blocking sign-in from any organization not their own). Because GDAP-delegated partner sign-ins technically originate as a form of external/service-provider access, a blanket external-user-blocking CA policy will also block legitimate GDAP access. Entra CA has a dedicated **"Service provider users"** external-user type specifically so customers can exclude CSP/GDAP traffic from these policies without exempting all guests — this is the documented, supported remediation, not a workaround.

</details>

---

## Dependency Stack

```
Customer's Microsoft 365 / Azure workloads
        │
        ▼
Delegated role assignment (projected into customer tenant, "GDAP-managed")
        │
        ▼
Access Assignment — security group → Entra role mapping (partner tenant object)
        │
        ├── Role must be one the customer consented to in the relationship request
        │       (adding an out-of-scope role requires a NEW relationship, not an edit)
        │
        └── Security group membership (partner tenant)
                └── Must be native Member accounts — guests are silently ignored/broken
        │
        ▼
GDAP Relationship (Active status, within duration window)
        │
        ├── Created by: partner user with Admin Agent role
        ├── Approved by: customer Global Admin (or expires in 90 days)
        └── Bounded by: max 2yr duration, optional 6-month Auto Extend increments
                (Global Admin role assignments excluded from Auto Extend)
        │
        ▼
Customer tenant enforcement layer
        ├── Conditional Access — must not block "Service provider users"
        ├── MFA / sign-in risk policies — apply normally to the partner user's sign-in
        └── License/service plan — the delegated role only grants RBAC, not licensing
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Partner has zero access to a customer they previously supported | GDAP relationship expired/terminated (2yr max, or Auto Extend was disabled) | `Get-MgTenantRelationshipDelegatedAdminRelationship` — check `Status` and `EndDateTime` |
| GDAP request sent to customer, nothing ever happens | Customer never approved within 90 days — request silently expired | Relationship won't appear as `active`; must be recreated, not resent |
| Relationship shows Active, correct role listed, but named user still can't do the task | User not a member of the mapped security group, or is a guest in it | `Get-MgGroupMember` on the mapped group; check `UserType` |
| Access "used to work, stopped without warning" tenant-wide for the whole partner team | Auto Extend was disabled (or never enabled) and the relationship quietly hit its end date | Check `EndDateTime` vs. today; check `AutoExtendDuration` |
| Can request new roles for a customer but Partner Center won't let you add one to an existing relationship | Role wasn't in the original consented scope | Roles are fixed per relationship at creation — must create an additional/new relationship for new roles |
| Everything configured correctly, access still silently fails | A guest account (not native member) is in the access-assignment security group | Enumerate group members, check `UserType -eq 'Guest'` |
| "Our MSP suddenly can't get into our tenant" right after a new CA rollout | New/tightened Conditional Access policy targeting all guest/external sign-ins, not excluding Service Provider users | Review CA policies in the *customer* tenant scoped to Guests or external users |
| Customer's only admin locked out, can't approve a GDAP request or reset anything | Privileged Authentication Administrator role was never included in an earlier GDAP relationship | Check whether any active relationship already grants this role; if not, this is a Microsoft-support-assisted recovery, not a partner-side fix |
| Can't create a support ticket for a customer despite an active relationship | Relationship doesn't include Service Support Administrator (or higher) | Check access assignment role list against least-privileged-roles-by-task guidance |
| Trying to reuse a relationship name after cleaning up an old one | 365-day name-reuse cooldown after termination/expiry | Use a suffixed/versioned name instead of retrying the same one |
| Security Copilot / other cross-tenant portal integration says "Can't get account information" | GDAP security group permissions for that specific workload weren't granted correctly | Re-verify the workload-specific Access Assignment (see `gdap-assign-microsoft-entra-roles` docs) — some newer workloads have their own permission-grant step beyond the base relationship |

---

## Validation Steps

### Step 1 — Enumerate all GDAP relationships and their lifecycle state

```powershell
Connect-MgGraph -Scopes "DelegatedAdminRelationship.Read.All" -NoWelcome
Get-MgTenantRelationshipDelegatedAdminRelationship |
    Select-Object DisplayName, Status, CreatedDateTime, EndDateTime, Duration, AutoExtendDuration |
    Sort-Object EndDateTime | Format-Table -AutoSize
```
**Good:** All relevant customer relationships show `Status = active` with `EndDateTime` comfortably in the future (or Auto Extend enabled). **Bad:** Any `approvalPending` older than a few weeks (heading toward the 90-day expiry), or `terminated`/`expired` entries for customers you're still actively supporting.

---

### Step 2 — Inspect a single relationship's consented role scope

```powershell
$rel = Get-MgTenantRelationshipDelegatedAdminRelationship -DelegatedAdminRelationshipId "<id>"
$rel.AccessDetails.UnifiedRoles | Select-Object RoleDefinitionId
```
**Good:** Every role the support team actually needs for this customer is present. **Bad:** A role the team needs (e.g., Exchange Administrator) is absent — it cannot be added to this relationship; a new relationship (or a role-scoped additional one) is required.

---

### Step 3 — Validate Access Assignment provisioning state

```powershell
Get-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment -DelegatedAdminRelationshipId "<id>" |
    Select-Object Id, Status, AccessContainer, AccessDetails
```
**Good:** `Status = active` for every assignment. **Bad:** `Status = pending` for more than ~15 minutes — provisioning is stuck and typically needs to be recreated (delete and reissue the access assignment) rather than waited out indefinitely.

---

### Step 4 — Validate security group membership and user type

```powershell
$groupId = "<securityGroupId>"
Get-MgGroupMember -GroupId $groupId | ForEach-Object {
    Get-MgUser -UserId $_.Id -Property DisplayName, UserPrincipalName, UserType
} | Select-Object DisplayName, UserPrincipalName, UserType | Format-Table -AutoSize
```
**Good:** All members show `UserType = Member`. **Bad:** Any `UserType = Guest` — that member's delegated access will not function; they need a native partner-tenant account instead.

---

### Step 5 — Confirm the customer tenant isn't blocking Service Provider users via Conditional Access

*(Run in the CUSTOMER tenant, or ask the customer's admin to run/screen-share this)*

```powershell
Get-MgIdentityConditionalAccessPolicy | Where-Object {
    $_.Conditions.Users.IncludeGuestsOrExternalUsers -or $_.Conditions.Users.ExcludeGuestsOrExternalUsers
} | Select-Object DisplayName, State,
    @{N="Includes";E={$_.Conditions.Users.IncludeGuestsOrExternalUsers.GuestOrExternalUserTypes}},
    @{N="Excludes";E={$_.Conditions.Users.ExcludeGuestsOrExternalUsers.GuestOrExternalUserTypes}}
```
**Good:** Policies blocking external users explicitly exclude `serviceProvider` type, or the policy scopes only to specific non-partner external types. **Bad:** A broad "block all guest/external" policy with no Service Provider exclusion, State = `enabled`.

---

### Step 6 — Confirm Auto Extend state on relationships nearing expiry

```powershell
Get-MgTenantRelationshipDelegatedAdminRelationship |
    Where-Object { $_.EndDateTime -lt (Get-Date).AddDays(30) -and $_.Status -eq "active" } |
    Select-Object DisplayName, EndDateTime, AutoExtendDuration
```
**Good:** `AutoExtendDuration` populated (e.g., `P180D`) for relationships you intend to keep long-term. **Bad:** `AutoExtendDuration` empty/zero and `EndDateTime` inside 30 days — this relationship will go dark soon with no warning to the customer or partner beyond Partner Center's own expiry notifications.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Establish which tenant and which layer owns the fault

1. Confirm you are troubleshooting the **partner tenant's** GDAP objects (relationship, access assignment, security group) first — this is where 90% of GDAP issues originate, not the customer tenant.
2. Only move to the **customer tenant** if the partner-side objects all check out (active relationship, correct role, correct group membership) and access is still denied — at that point suspect Conditional Access, sign-in risk policies, or license/service-plan gaps in the customer tenant.

### Phase 2 — Relationship-level issues

1. Run Validation Step 1. Anything not `active` needs to be recreated via Partner Center or the Graph API — there is no "resume" for an expired/terminated relationship.
2. If recreating, check the 365-day name-reuse cooldown before reusing a prior `displayName`.
3. If the relationship needs a role that was never in the original scope, a new relationship (or an additional relationship covering just that role) must be created — role scope cannot be edited on an existing relationship.

### Phase 3 — Access Assignment and group membership issues

1. Run Validation Steps 3 and 4.
2. `pending` access assignments stuck >15 minutes: delete and recreate the assignment rather than waiting further.
3. Guest accounts found in a mapped group: this is not fixable by any group setting — the affected person needs a native Member account in the partner tenant.
4. Confirm the 100-security-groups-per-customer ceiling hasn't been hit if new group creation is failing.

### Phase 4 — Customer-tenant enforcement issues

1. Run Validation Step 5 for Conditional Access.
2. Check customer-tenant sign-in logs for the specific partner user's UPN, filtering for Conditional Access failures — the failure reason will usually name the blocking policy directly.
3. Confirm the delegated role itself grants the capability being attempted (e.g., a Helpdesk Administrator role cannot reset an Exchange Administrator's password) — GDAP is granular by design, and "it used to be Global Admin" is not a valid baseline to compare against anymore.

### Phase 5 — Recovery/lockout scenarios

1. If the customer's only admin is locked out and no Privileged Authentication Administrator role exists in any active relationship, this cannot be resolved by the partner alone — direct the customer to Microsoft's tenant-ownership-verification recovery path, or to SSPR if it was pre-configured.
2. Use this as the trigger to add Privileged Authentication Administrator to the relationship going forward, so the next occurrence doesn't repeat the same dead end.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Recreate an expired/terminated relationship with the same role scope</summary>

```powershell
Connect-MgGraph -Scopes "DelegatedAdminRelationship.ReadWrite.All" -NoWelcome

# Pull the old relationship's role scope first (if still readable) to mirror it
$old = Get-MgTenantRelationshipDelegatedAdminRelationship -DelegatedAdminRelationshipId "<oldId>" -ErrorAction SilentlyContinue

$params = @{
    displayName   = "<CustomerName>-Support-v2"   # versioned to dodge the 365-day name cooldown
    customer      = @{ tenantId = "<customerTenantId>" }
    accessDetails = @{
        unifiedRoles = @(
            @{ roleDefinitionId = "<HelpdeskAdministratorRoleGuid>" }
            @{ roleDefinitionId = "<ExchangeAdministratorRoleGuid>" }
        )
    }
    duration           = "P2Y"
    autoExtendDuration = "P180D"
}

$new = New-MgTenantRelationshipDelegatedAdminRelationship -BodyParameter $params
Write-Host "Created relationship $($new.Id) — awaiting customer approval (expires in 90 days if not actioned)" -ForegroundColor Yellow
```

**Rollback:** relationships can be terminated any time after creation:
```powershell
Update-MgTenantRelationshipDelegatedAdminRelationship -DelegatedAdminRelationshipId $new.Id -BodyParameter @{ status = "terminating" }
```

</details>

<details><summary>Playbook 2 — Create an Access Assignment mapping a security group to specific roles</summary>

```powershell
Connect-MgGraph -Scopes "DelegatedAdminRelationship.ReadWrite.All" -NoWelcome

$relationshipId = "<activeRelationshipId>"
$groupId        = "<partnerTenantSecurityGroupId>"

$params = @{
    accessContainer = @{
        accessContainerId   = $groupId
        accessContainerType = "securityGroup"
    }
    accessDetails = @{
        unifiedRoles = @(
            @{ roleDefinitionId = "<roleGuid>" }
        )
    }
}

New-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment -DelegatedAdminRelationshipId $relationshipId -BodyParameter $params
```

**Note:** the API accepts one security group per call — for multiple group-to-role mappings on the same relationship, call this once per group (Partner Center's UI can batch multiple mappings in one flow, the API cannot).

**Rollback:**
```powershell
Remove-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment -DelegatedAdminRelationshipId $relationshipId -AccessAssignmentId "<assignmentId>"
```

</details>

<details><summary>Playbook 3 — Replace a guest member with a native member in a GDAP-mapped group</summary>

```powershell
$groupId  = "<securityGroupId>"
$guestUpn = "<guest_user@partnertenant.com#EXT#@partnertenant.onmicrosoft.com>"

# 1. Identify and remove the guest
$guest = Get-MgUser -Filter "userPrincipalName eq '$guestUpn'"
Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $guest.Id

# 2. Confirm/create the native member account for this person in the partner tenant
#    (native account creation is an identity-governance decision, not scripted here)

# 3. Add the native account
$nativeUser = Get-MgUser -Filter "userPrincipalName eq '<person@partnertenant.com>'"
New-MgGroupMember -GroupId $groupId -DirectoryObjectId $nativeUser.Id
```

**Rollback:** re-add the guest and remove the native member — not recommended, since guest membership is documented as non-functional for GDAP access assignments.

</details>

<details><summary>Playbook 4 — Enable Auto Extend on relationships approaching expiry (bulk)</summary>

```powershell
Connect-MgGraph -Scopes "DelegatedAdminRelationship.ReadWrite.All" -NoWelcome

$expiringSoon = Get-MgTenantRelationshipDelegatedAdminRelationship |
    Where-Object {
        $_.Status -eq "active" -and
        $_.EndDateTime -lt (Get-Date).AddDays(60) -and
        -not ($_.AccessDetails.UnifiedRoles.RoleDefinitionId -contains "62e90394-69f5-4237-9190-012177145e10") # Global Administrator role GUID — cannot auto-extend
    }

foreach ($rel in $expiringSoon) {
    Update-MgTenantRelationshipDelegatedAdminRelationship -DelegatedAdminRelationshipId $rel.Id `
        -BodyParameter @{ autoExtendDuration = "P180D" }
    Write-Host "Auto Extend enabled for $($rel.DisplayName)" -ForegroundColor Green
}
```

**Note:** relationships containing the Global Administrator role are filtered out because they cannot be auto-extended — those must be tracked for manual renewal separately (see the evidence/audit script).

</details>

---

## Evidence Pack

```powershell
# Run signed into the PARTNER tenant as an Admin Agent
Connect-MgGraph -Scopes "DelegatedAdminRelationship.Read.All" -NoWelcome

$outputDir = "C:\Temp\GDAP-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# 1. All relationships and lifecycle state
Get-MgTenantRelationshipDelegatedAdminRelationship |
    Select-Object Id, DisplayName, Status, CreatedDateTime, EndDateTime, Duration, AutoExtendDuration |
    Export-Csv "$outputDir\01-Relationships.csv" -NoTypeInformation

# 2. Access assignments for a specific relationship under investigation
$relationshipId = "<relationshipId>"
Get-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment -DelegatedAdminRelationshipId $relationshipId |
    Select-Object Id, Status, AccessContainer, AccessDetails |
    ConvertTo-Json -Depth 8 | Out-File "$outputDir\02-AccessAssignments.json"

# 3. Group membership + UserType for the mapped group(s)
$groupId = "<securityGroupId>"
Get-MgGroupMember -GroupId $groupId | ForEach-Object {
    Get-MgUser -UserId $_.Id -Property DisplayName, UserPrincipalName, UserType
} | Select-Object DisplayName, UserPrincipalName, UserType |
    Export-Csv "$outputDir\03-GroupMembers.csv" -NoTypeInformation

# 4. Metadata
[PSCustomObject]@{
    CollectedAt    = (Get-Date).ToString("u")
    PartnerTenant  = (Get-MgContext).TenantId
    RelationshipId = $relationshipId
} | ConvertTo-Json | Out-File "$outputDir\00-CollectionMetadata.json"

Write-Host "Evidence collected to: $outputDir" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| List all GDAP relationships | `Get-MgTenantRelationshipDelegatedAdminRelationship` |
| Get one relationship's detail | `Get-MgTenantRelationshipDelegatedAdminRelationship -DelegatedAdminRelationshipId <id>` |
| Create a new relationship | `New-MgTenantRelationshipDelegatedAdminRelationship -BodyParameter $params` |
| Terminate a relationship | `Update-MgTenantRelationshipDelegatedAdminRelationship -DelegatedAdminRelationshipId <id> -BodyParameter @{status="terminating"}` |
| List access assignments for a relationship | `Get-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment -DelegatedAdminRelationshipId <id>` |
| Create an access assignment (group ↔ role) | `New-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment -DelegatedAdminRelationshipId <id> -BodyParameter $params` |
| Delete an access assignment | `Remove-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment -DelegatedAdminRelationshipId <id> -AccessAssignmentId <aid>` |
| List members of a mapped security group | `Get-MgGroupMember -GroupId <groupId>` |
| Check a member's UserType (Member vs Guest) | `Get-MgUser -UserId <id> -Property UserType` |
| Enable Auto Extend on a relationship | `Update-MgTenantRelationshipDelegatedAdminRelationship -DelegatedAdminRelationshipId <id> -BodyParameter @{autoExtendDuration="P180D"}` |
| Check customer-tenant CA policies for guest/external targeting | `Get-MgIdentityConditionalAccessPolicy \| Where Conditions.Users.*GuestsOrExternalUsers` |
| Confirm current Graph context/tenant | `Get-MgContext` |

---

## 🎓 Learning Pointers

- **GDAP is a purpose-built CSP/reseller delegation model — it is not the same thing as Entra Cross-Tenant Access Settings (XTAS) or Azure Lighthouse**, even though all three solve "access another organization's tenant." XTAS governs peer-to-peer B2B collaboration; Lighthouse governs Azure-Resource-Manager-scoped delegation; GDAP governs the specific CSP-partner-to-customer relationship with its own lifecycle, roles, and Partner Center tooling. Picking the wrong mental model wastes troubleshooting time. See: [GDAP introduction](https://learn.microsoft.com/en-us/partner-center/customers/gdap-introduction)

- **The Global Administrator role is deliberately excluded from Auto Extend.** This is a security control, not a bug — Microsoft wants the highest-privilege relationship type to force periodic manual re-approval rather than silently renewing forever. Any relationship still granting Global Admin should be flagged for a least-privilege review anyway. See: [GDAP role guidance](https://learn.microsoft.com/en-us/partner-center/customers/gdap-least-privileged-roles-by-task)

- **Guest accounts breaking GDAP group membership is one of the most support-generating, least-documented-in-error-messages failure modes.** There is no error telling you a guest is the problem — access simply fails. Make checking `UserType` on group members a reflexive first step, not a last resort. See: [GDAP FAQ](https://learn.microsoft.com/en-us/partner-center/customers/gdap-faq)

- **The 90-day approval expiry and 365-day name-reuse cooldown are easy to get burned by during customer onboarding.** If a customer's Global Admin is slow to approve, the clock is already running — build a reminder cadence into onboarding rather than discovering the request quietly expired weeks later.

- **GDAP explicitly cannot coexist with a Multi-Tenant Organization (MTO) relationship between the same two tenants.** If a customer is also being onboarded into an MTO for unrelated reasons, that path and the GDAP path are mutually exclusive — this needs to be resolved as an architecture decision, not a troubleshooting task.

- **Conditional Access "Service provider users" is a purpose-built exclusion category** — introduced specifically because customers were (correctly, from their own security posture) writing broad guest-blocking CA policies that also blocked their MSP's legitimate GDAP access. Recommending this exclusion to a customer is the supported fix, not a security compromise. See: [Conditional Access for external users](https://learn.microsoft.com/en-us/azure/active-directory/external-identities/authentication-conditional-access)
