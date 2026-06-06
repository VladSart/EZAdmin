# Power Automate — SharePoint Permission Management Hotfix (Mode B: Ops)

> Permission assignment in a flow is failing. Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage (60 sec)](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis Flow](#diagnosis--validation-flow)
- [Fix Paths](#common-fix-paths)
- [Common Permission Patterns](#common-permission-patterns-with-working-examples)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Open the failed flow run. Find the first red action. Then:

| Error | Likely cause |
|-------|-------------|
| `403 Forbidden` on permission action | Account lacks admin rights on the site |
| `Access denied. You do not have permission` | Site permissions inheritance broken incorrectly |
| `User cannot be found` | UPN mismatch or guest user not yet in tenant |
| `The role assignment already exists` | Idempotency — safe to catch and ignore |
| `Sharing is not enabled` | Tenant or site-level sharing settings block external sharing |
| `Value does not fall within expected range` | Invalid role definition ID |

```powershell
# Quick permissions check — can the flow account see + modify this site?
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com

$siteUrl = "https://<tenant>.sharepoint.com/sites/<sitename>"
Get-SPOUser -Site $siteUrl | Where-Object { $_.LoginName -like "*flowaccount*" }

# Check site collection admins
Get-SPOSite -Identity $siteUrl | Select SharingCapability, SharingAllowedDomainList
Get-SPOUser -Site $siteUrl | Where-Object { $_.IsSiteAdmin }
```

---

## Dependency Cascade

<details><summary>What must be true for permission management to work</summary>

```
[Flow action: Grant access / Break inheritance / Add user to group]
    → Connection account must be Site Collection Admin OR SharePoint Admin
    → Target site must be accessible (not deleted, not locked)
    → Target user must exist in Entra ID (and be sync'd if hybrid)
    → Site sharing settings must allow the sharing type (internal/external)
    → Unique permissions model:
        Default → inherits from parent (list/library/item inherits from site)
        After "Break inheritance" → site has unique permissions
        Once broken → must manage permissions explicitly, parent changes don't cascade
    → SharePoint permission levels: Full Control, Edit, Contribute, Read, View Only
    → Permission groups: Owners, Members, Visitors (map to FC, Edit, Read)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Test direct access from flow account**
```powershell
# Log in as the flow connection account and test
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<sitename>" `
  -Interactive

# Can you see permissions?
Get-PnPSiteCollectionAdmin
Get-PnPGroup

# Can you add a user?
Add-PnPGroupMember -Group "Members" -EmailAddress "test@contoso.com"
```

**Step 2 — Check if permissions are inherited or unique**
```powershell
# Check inheritance status
$web = Get-PnPWeb -Includes HasUniqueRoleAssignments
$web.HasUniqueRoleAssignments   # True = unique (broken inheritance)
                                 # False = inheriting from parent

# Check a list/library
Get-PnPList -Identity "Documents" | Select-Object Title, HasUniqueRoleAssignments
```

**Step 3 — Validate role definition IDs**
```powershell
# Get valid role IDs for this site (needed for REST/Graph permission actions)
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<sitename>" -Interactive
Get-PnPRoleDefinition | Select Name, Id, Description | Format-Table
# Common: Full Control=1073741829, Edit=1073741830, Contribute=1073741827, Read=1073741826
```

---

## Common Fix Paths

<details><summary>Fix 1 — 403: Flow account lacks permissions</summary>

```powershell
# Add the flow account as Site Collection Admin on the target site
Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com"
Set-SPOUser -Site "https://<tenant>.sharepoint.com/sites/<sitename>" `
  -LoginName "<flowaccount@tenant.com>" -IsSiteCollectionAdmin $true

# Or add to site Owners group instead (less privileged than SCA)
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<sitename>" -Interactive
Add-PnPGroupMember -Group "Owners" -EmailAddress "<flowaccount@tenant.com>"
```

**Longer-term fix:** Use a service principal with `Sites.FullControl.All` application permission in Graph API — doesn't depend on user account admin rights.

</details>

<details><summary>Fix 2 — Break inheritance before assigning unique permissions</summary>

In Power Automate, use "Send an HTTP request to SharePoint" action:

```
Method: POST
Uri: _api/web/breakroleinheritance(copyRoleAssignments=true, clearSubscopes=false)
Headers:
  Accept: application/json;odata=verbose
  Content-Type: application/json;odata=verbose
  X-RequestDigest: [get from /_api/contextinfo first]
```

Or via PowerShell:
```powershell
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<sitename>" -Interactive

# Break inheritance on the web (site)
$web = Get-PnPWeb
$web.BreakRoleInheritance($true, $false)  # copyAssignments=true, clearSubscopes=false
$web.Update()
Invoke-PnPQuery
```

</details>

<details><summary>Fix 3 — Add user to SharePoint group via REST in flow</summary>

Working REST call to add a user to a SharePoint group:

```
Method: POST
Uri: _api/web/sitegroups/getbyname('<GroupName>')/users
Headers:
  Accept: application/json;odata=nometadata
  Content-Type: application/json;odata=nometadata
Body:
{
  "LoginName": "i:0#.f|membership|user@tenant.com"
}
```

> ⚠️ The `LoginName` must use the claims format: `i:0#.f|membership|<UPN>` for M365 accounts.

</details>

<details><summary>Fix 4 — Grant permission level to user/group via REST</summary>

```
Step 1: Get role definition ID
Method: GET
Uri: _api/web/roledefinitions

Step 2: Get user/group principal ID
Method: GET
Uri: _api/web/siteusers/getbyemail('<email>')

Step 3: Assign role
Method: POST
Uri: _api/web/roleassignments/addroleassignment(principalid=<principalId>,roledefid=<roleDefId>)
```

**PowerShell equivalent (simpler for troubleshooting):**
```powershell
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<sitename>" -Interactive

# Grant a specific permission level to a user
Set-PnPWebPermission -User "user@contoso.com" -AddRole "Contribute"

# Grant to a group
Set-PnPWebPermission -Group "Visitors" -AddRole "Read"
```

</details>

---

## Common Permission Patterns (with working examples)

### Pattern 1: Auto-assign Members group based on form input
```
Trigger: SharePoint list item created
Action 1: Get the "Requested Members" column value (multi-person field)
Action 2: Apply to each person in the field
  → Send HTTP request: POST to sitegroups/getbyname('Members')/users
    Body: { "LoginName": "i:0#.f|membership|@{item()?['Email']}" }
```

### Pattern 2: Create site + assign owner in one flow
```
Action 1: Send HTTP request (Graph) → POST /v1.0/sites → create site
Action 2: Delay 30 seconds (async site creation)
Action 3: Do Until site exists (poll GET /sites/<url>)
Action 4: Set-PnPWebPermission — add owner to Owners group
Action 5: Remove flow service account from site (cleanup)
```

### Pattern 3: Apply different permissions by department (metadata-driven)
```
Trigger: List item updated (Status = Approved)
Get item: Department field
Switch:
  Case HR: Add HR-Managers group as Owners; HR-Staff as Members
  Case Finance: Add Finance-Admin as Owners; Finance-Read as Visitors
  Default: Add IT-Admin as fallback owner
```

---

## Escalation Evidence

```
Power Automate Permission Management — Evidence Pack
====================================================
Flow name:                  
Failing action:             [exact action name]
Error code + message:       [from run history — full text]
Site URL:                   
Target user/group:          [UPN or group name]
Permission being assigned:  [role name or REST endpoint]
Connection account:         [UPN — confirm it's site admin]
Inheritance broken:         [Yes/No]
Sharing settings:           [Internal only / Anyone / Specific people]
Tenant DLP policies:        [any restrictions on SharePoint connector?]
Test via PnP PowerShell:    [result of manual Set-PnPWebPermission test]
```

---

## 🎓 Learning Pointers

- **SharePoint permission model depth** — SP has three layers: tenant sharing settings → site collection policy → individual object permissions. A flow can be technically correct but fail because the tenant setting is more restrictive. Understanding the override hierarchy prevents hours of debugging the wrong layer.
- **Claims format for LoginName** — SharePoint's internal claims format (`i:0#.f|membership|upn`) trips up everyone using REST actions. It's not just the email address. Guest users use a different claims format (`i:0#.f|membership|ext...`). [SharePoint Identity Claim Formats](https://docs.microsoft.com/en-us/sharepoint/dev/general-development/claims-provider-in-sharepoint)
- **PnP PowerShell** — `Connect-PnPOnline` + `Set-PnPWebPermission` is the fastest way to test if a permission operation is possible at all before debugging why the flow can't do it. Install: `Install-Module PnP.PowerShell`
- **Service principal vs delegated in permission flows** — Application permissions (`Sites.FullControl.All`) allow the app to manage any site without a human admin account. Delegated permissions require the user account to have admin rights on every site. For flows that touch many sites, application permissions are the correct architecture.
- **Reddit r/PowerAutomate + r/sharepoint** — "Break inheritance Power Automate" and "add user to SharePoint group HTTP action" are among the most-searched topics. Community has working code samples for every REST call pattern you'll need.
