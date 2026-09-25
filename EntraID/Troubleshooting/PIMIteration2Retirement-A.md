# PIM Iteration 2 (Beta) API Retirement — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

> **Hard date: 28 October 2026.** After that date, calls to the Microsoft Entra PIM Iteration 2 beta APIs under `/beta/privilegedAccess/...` "will fail" and "will no longer return data" (MC1181281, published 2025-10-29, act-by 2026-10-28). Fast path: [PIMIteration2Retirement-B.md](PIMIteration2Retirement-B.md).

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
- [Source Confidence](#source-confidence)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

**In scope**
- Every caller of `https://graph.microsoft.com/beta/privilegedAccess/{aadRoles|azureResources|aadGroups}/...`: scripts, Azure Automation, Logic Apps, Power Automate, Azure Functions, ITSM/GRC connectors and open-source governance tools
- Iteration 2 resource types: `governanceResource`, `governanceRoleDefinition`, `governanceRoleAssignment`, `governanceRoleAssignmentRequest`, `governanceRoleSetting`, `governanceSubject`
- Legacy Graph permissions: `PrivilegedAccess.Read.AzureAD`, `PrivilegedAccess.ReadWrite.AzureAD`, `PrivilegedAccess.Read.AzureResources`, `PrivilegedAccess.ReadWrite.AzureResources`, `PrivilegedAccess.Read.AzureADGroup`, `PrivilegedAccess.ReadWrite.AzureADGroup`
- Migration to Iteration 3 on Microsoft Graph (Entra roles, Groups) and on Azure Resource Manager (Azure resources)

**Out of scope**
- Day-to-day PIM activation or approval problems: see [PIM-A.md](PIM-A.md) and [PIMAzureResources-A.md](PIMAzureResources-A.md)
- Iteration 1 (`/beta/privilegedRoles`), which was retired in June 2021. Anything still calling it is already broken.

**Assumptions**
- Commercial cloud. Sovereign-cloud dates aren't stated separately in MC1181281.
- Microsoft Graph PowerShell SDK v2.x and Az PowerShell (Az.Resources ≥ 6.x) are available for the migration examples.

---
## How It Works

<details><summary>Full architecture: three PIM API iterations and why this migration isn't a version bump</summary>

### The API history isn't linear

Microsoft's own PIM API concepts page (ms.date 2026-04-23) says the iterations "don't represent a linear progression of versions":

```
Iteration 1  /beta/privilegedRoles                 Entra roles only      RETIRED June 2021
Iteration 2  /beta/privilegedAccess/aadRoles       Entra roles           DEPRECATED → stops 2026-10-28
             /beta/privilegedAccess/azureResources Azure resource roles  DEPRECATED → stops 2026-10-28
             /beta/privilegedAccess/aadGroups      Privileged access     (see note below)
                                                   groups (legacy)
Iteration 3  Graph  /roleManagement/directory/...  Entra roles           GA
             Graph  /identityGovernance/privilegedAccess/group/...  Groups  GA
             ARM    /providers/Microsoft.Authorization/role*Schedule*  Azure resources  GA
```

**The Groups note:** the Learn history page and the Iteration 2 caution banner only name `aadRoles` and `azureResources`. MC1181281's text says calls "for Azure resources, Microsoft Entra roles **and Groups** will fail". The older privileged-access-groups preview was reachable through the same `/beta/privilegedAccess/` root with the `aadGroups` segment, so treat any `privilegedAccess/aadGroups` caller as **in scope**. Iteration 3 for Groups is `/identityGovernance/privilegedAccess/group/...`. Note the `identityGovernance` prefix, which is a different path from the Iteration 2 root. Don't let the similar name (`privilegedAccess`) fool a grep into flagging Iteration 3 calls as legacy. See the regex in `Find-PIMIteration2CodeReference.ps1`.

### Iteration 2's resource model: "onboard, then request"

Iteration 2 treated every provider generically:
1. **Register/onboard** a `governanceResource` (for Azure: a subscription or management group had to be discovered and registered in PIM first).
2. Read `governanceRoleDefinition` objects *scoped to that resource* (PIM-specific IDs, not the native Azure RBAC or Entra role definition IDs).
3. POST a `governanceRoleAssignmentRequest` with `type` (`AdminAdd`, `UserAdd`, `AdminUpdate`, `AdminRemove`, `UserRemove`, `UserExtend`, `UserRenew`...) and `assignmentState` (`Eligible`/`Active`).
4. Read `governanceRoleSetting` for activation rules.

Everything lived under Microsoft Graph, and permissions were the provider-specific `PrivilegedAccess.*` scopes.

### Iteration 3's model: native objects, schedules and instances

Iteration 3 drops the generic layer and uses each platform's **native** role objects:

| Concept | Iteration 2 | Iteration 3 (Entra roles) | Iteration 3 (Azure resources) | Iteration 3 (Groups) |
|---|---|---|---|---|
| API host | Graph `/beta/privilegedAccess` | Graph `/roleManagement/directory` | ARM `management.azure.com/{scope}/providers/Microsoft.Authorization` | Graph `/identityGovernance/privilegedAccess/group` |
| Role IDs | PIM `governanceRoleDefinition` IDs | Native `unifiedRoleDefinition` IDs (template IDs) | Native Azure RBAC `roleDefinitionId` | `member` / `owner` access IDs |
| Create or activate | `governanceRoleAssignmentRequest` | `unifiedRoleAssignmentScheduleRequest` / `unifiedRoleEligibilityScheduleRequest` | `roleAssignmentScheduleRequests` / `roleEligibilityScheduleRequests` | `privilegedAccessGroupAssignmentScheduleRequest` / `...EligibilityScheduleRequest` |
| Current state | `governanceRoleAssignment` | `...ScheduleInstance` | `roleAssignmentScheduleInstances` / `roleEligibilityScheduleInstances` | `...ScheduleInstance` |
| Settings | `governanceRoleSetting` | `unifiedRoleManagementPolicy` + `...PolicyAssignment` | `roleManagementPolicies` + `roleManagementPolicyAssignments` | `unifiedRoleManagementPolicy` (scopeType `Group`) |
| Onboarding | Required (`register`) | N/A | **Not required**: act on the scope directly | N/A |
| Auth | Graph `PrivilegedAccess.*` | Graph `RoleManagement.*`, `RoleEligibilitySchedule.*`, `RoleAssignmentSchedule.*`, `RoleManagementPolicy.*` | **ARM token** + Azure RBAC Owner / User Access Administrator on the scope. No Graph permission needed. | Graph `PrivilegedEligibilitySchedule.*`, `PrivilegedAssignmentSchedule.*`, `RoleManagementPolicy.*.AzureADGroup` |
| App-only support | Limited | Yes | Yes | Yes |

### The request `action` values changed

| Iteration 2 `type` | Iteration 3 `action` |
|---|---|
| `AdminAdd` | `adminAssign` |
| `AdminUpdate` | `adminUpdate` |
| `AdminRemove` | `adminRemove` |
| `UserAdd` (activate) | `selfActivate` |
| `UserRemove` (deactivate) | `selfDeactivate` |
| `AdminExtend` / `UserExtend` | `adminExtend` / `selfExtend` |
| `AdminRenew` / `UserRenew` | `adminRenew` / `selfRenew` |

Iteration 3 also uses `scheduleInfo` with `startDateTime` and `expiration { type: afterDuration | afterDateTime | noExpiration, duration: "PT8H" }` in place of Iteration 2's `schedule { type: Once, startDateTime, endDateTime }`.

### Why Azure resources is the hard one

For Azure resources, the replacement API **isn't on Microsoft Graph**:
- **Different token audience**: `https://management.azure.com/`, not `https://graph.microsoft.com/`.
- **Different authorization**: Azure RBAC on the target scope (Owner or User Access Administrator), not an Entra app role. A service principal with admin-consented `PrivilegedAccess.ReadWrite.AzureResources` holds **no** rights under Iteration 3 until it's given an RBAC role at the right scope.
- **Different enumeration**: no single call returns "all PIM-managed Azure resources". You enumerate management groups and subscriptions yourself and query each scope, or use `$filter=asTarget()` / `atScope()` at a management-group scope.
- **Different IDs**: role definition IDs are the native Azure RBAC GUIDs (for example, Owner `8e3af657-a8ff-443c-a75c-2fe8c4bcb635`), not Iteration 2's PIM-internal IDs. Stored mappings need rebuilding.

### What "stops returning data" will probably look like

MC1181281 says calls "will fail" and "will no longer return data". Microsoft hasn't documented the exact HTTP status. Plan for any of: `404`, `400 BadRequest` with a deprecation message, `403`, or `200` with an empty `value` array. The last one is the dangerous case for reporting tools, because a governance report showing **zero eligible assignments** looks like a clean bill of health.

### The Entra admin center UI

The Learn concepts page also says Microsoft is "in the process of migrating the UI to Iteration 3 APIs". Portal blades don't need customer action. But screenshots and admin muscle memory from Iteration 2-era blades (for example, the old "Azure resources → Discover resources" onboarding step) will drift from what the portal shows.

</details>

---
## Dependency Stack

```
Layer 7  Business process: JIT access requests, access certifications, audit exports,
         SOC dashboards, ITSM "request admin role" catalogue items
            │
Layer 6  Automation host: PowerShell/Azure Automation · Logic Apps · Power Automate ·
         Functions · 3rd-party (e.g. AzGovViz PIM eligibility report, ITSM connectors)
            │
Layer 5  API call  ──┬─ Iteration 2: graph.microsoft.com/beta/privilegedAccess/...   ✖ 2026-10-28
                     └─ Iteration 3: Graph roleManagement / identityGovernance  |  ARM Microsoft.Authorization
            │
Layer 4  Token  ─ audience graph.microsoft.com (Entra roles, Groups)  |  management.azure.com (Azure)
            │
Layer 3  Authorization
            ├─ Graph app roles / delegated scopes (PrivilegedAccess.* legacy | RoleManagement.* etc.)
            └─ Azure RBAC on scope (Owner / User Access Administrator), Azure path only
            │
Layer 2  PIM service providers: Entra roles · Azure resources · Groups
            │
Layer 1  Licensing: Entra ID P2 or Entra ID Governance for PIM-managed identities
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| PIM eligibility report shows 0 eligible assignments from 28 Oct 2026 | Tool still calls `/beta/privilegedAccess/azureResources` and treats an empty or failed response as "none" | Validation step 3 (Graph activity logs), tool version (AzGovViz issue #291) |
| ITSM "request admin role" catalogue item fails | Connector POSTs `governanceRoleAssignmentRequest` | Find-PIMIteration2CodeReference.ps1 against the connector config, vendor ticket |
| Migrated Azure-resources script returns `403 AuthorizationFailed` | SP has Graph `PrivilegedAccess.*` but no Azure RBAC role on the scope | `Get-AzRoleAssignment -ObjectId <spObjectId> -Scope <scope>` |
| Migrated script returns `401` / `InvalidAuthenticationToken` against ARM | Token requested for the Graph audience and reused on ARM | Decode the token (`aud` claim) and use `Get-AzAccessToken` |
| Migrated Entra-roles call returns `400 RoleNotFound` / invalid roleDefinitionId | Iteration 2 PIM role definition IDs reused | Use `Get-MgRoleManagementDirectoryRoleDefinition` template IDs |
| `selfActivate` fails with `RoleAssignmentRequestPolicyValidationFailed` | Policy needs justification, ticket info or MFA, which Iteration 2 code didn't send | Read the `unifiedRoleManagementPolicy` rules for the role |
| Grep finds `privilegedAccess` in code that works fine after the date | Iteration 3 Groups path `identityGovernance/privilegedAccess/group` (false positive) | Use the anchored regex in the Find script |
| No legacy grants found, yet an integration breaks | Caller uses a **delegated** grant or a shared or third-party app | Validation step 3 (activity logs catch every caller) |

---
## Validation Steps

**1. Legacy permission holders (application and delegated)**
```powershell
Connect-MgGraph -Scopes "Application.Read.All","DelegatedPermissionGrant.Read.All" -NoWelcome
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$legacy  = @($graphSp.AppRoles + $graphSp.Oauth2PermissionScopes | Where-Object Value -like 'PrivilegedAccess.*' | Select-Object -ExpandProperty Value -Unique)
$legacy
# Application assignments
$roleIds = ($graphSp.AppRoles | Where-Object Value -like 'PrivilegedAccess.*').Id
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $graphSp.Id -All |
    Where-Object { $roleIds -contains $_.AppRoleId } |
    Select-Object PrincipalDisplayName, PrincipalId, AppRoleId, CreatedDateTime
# Delegated grants
Get-MgOauth2PermissionGrant -Filter "resourceId eq '$($graphSp.Id)'" -All |
    Where-Object { $_.Scope -match 'PrivilegedAccess\.' } |
    Select-Object ClientId, ConsentType, PrincipalId, Scope
```
- **Good:** no rows, or only apps you've already migrated (then remove the grant, Playbook 5).
- **Bad:** rows. Each one is a lead, not proof. The existing `Get-PIMIteration2APIUsageAudit.ps1` only checks **application** assignments, so run this delegated query as well.

**2. Static code and flow scan**
```powershell
.\Find-PIMIteration2CodeReference.ps1 -Path C:\Repos,C:\Exports\Flows -OutputPath C:\Temp
```
- **Good:** 0 `Iteration2` hits. `Iteration3` hits are informational.
- **Bad:** any `Iteration2Endpoint` or `Iteration2ResourceType` hit. Open that file and plan the migration.

**3. Server-side proof: Microsoft Graph activity logs**

Unlike Graph *permission* data, `MicrosoftGraphActivityLogs` (diagnostic setting to Log Analytics, Entra ID P1/P2) records every request URI with the calling app. This is the only way to catch callers you don't know about.
```kusto
MicrosoftGraphActivityLogs
| where TimeGenerated > ago(30d)
| where RequestUri has "/beta/privilegedAccess/"
| extend Provider = extract(@"/beta/privilegedAccess/([A-Za-z]+)", 1, RequestUri)
| summarize Calls = count(), LastSeen = max(TimeGenerated),
            Methods = make_set(RequestMethod), Codes = make_set(ResponseStatusCode)
          by AppId, ServicePrincipalId, UserId, Provider
| order by Calls desc
```
- **Good:** no rows.
- **Bad:** rows. `AppId` names the caller. `UserId` populated means a delegated or interactive caller, often an admin running an old script. Look up the app with `Get-MgServicePrincipal -Filter "appId eq '<AppId>'"`.

**4. Iteration 3 parity check (before cutover)**
```powershell
# Entra roles: eligible assignments via Iteration 3
Connect-MgGraph -Scopes "RoleEligibilitySchedule.Read.Directory" -NoWelcome
(Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance -All).Count

# Azure resources: eligible assignments at a subscription via ARM
Connect-AzAccount | Out-Null
(Get-AzRoleEligibilityScheduleInstance -Scope "/subscriptions/<subscriptionId>").Count
```
- **Good:** counts match what the Iteration 2 tool reported for the same scope before cutover.
- **Bad:** mismatch. It's usually a scope issue (management-group inheritance, or `asTarget()` vs `atScope()` filters) or a missing RBAC read on the scope.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Discover (now → early October 2026)
1. Validation step 1: permission holders, application **and** delegated.
2. Validation step 2: scan repos, Automation account exports (`Export-AzAutomationRunbook`), Logic App definitions (`Get-AzLogicApp`), and Power Automate exports (solution zip → `Workflows/*.json`).
3. Validation step 3 if Graph activity logs are available. If they aren't, enable them **now**. Even two weeks of data before 28 October is valuable.
4. Check third-party tools: open-source governance tools (AzGovViz tracked this in GitHub issue #291, with a fix branch under test at time of writing), ITSM PIM connectors, and custom Access Review exporters.

### Phase 2 — Classify
For each caller, record the provider (Entra roles / Azure / Groups), operation type (read-only reporting vs write/activation), auth mode (app-only vs delegated) and owner. Read-only reporting callers are the silent-failure risk. Write callers fail loudly but block access workflows.

### Phase 3 — Migrate
Use Playbooks 1–3 for each provider. Run the Iteration 3 path **in parallel** with Iteration 2 before 28 October, compare the outputs (validation step 4), then cut over.

### Phase 4 — Decommission
Remove the legacy `PrivilegedAccess.*` grants (Playbook 5). After 28 October they don't grant anything useful, and leaving them makes future audits noisier.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Entra roles: Iteration 2 → Graph Iteration 3</summary>

**Permissions:** read-only reporting needs `RoleEligibilitySchedule.Read.Directory` + `RoleAssignmentSchedule.Read.Directory` (or `RoleManagement.Read.Directory`). Writes need `RoleEligibilitySchedule.ReadWrite.Directory` / `RoleAssignmentSchedule.ReadWrite.Directory`. Check each endpoint's permission table before granting.

```powershell
Connect-MgGraph -Scopes "RoleManagement.Read.Directory" -NoWelcome

# Replace: GET /beta/privilegedAccess/aadRoles/resources/<tenantId>/roleAssignments
$roleNames = @{}
Get-MgRoleManagementDirectoryRoleDefinition -All | ForEach-Object { $roleNames[$_.Id] = $_.DisplayName }

$eligible = Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance -All |
    Select-Object PrincipalId, @{n='Role';e={$roleNames[$_.RoleDefinitionId]}}, DirectoryScopeId, StartDateTime, EndDateTime, @{n='State';e={'Eligible'}}
$active   = Get-MgRoleManagementDirectoryRoleAssignmentScheduleInstance -All |
    Select-Object PrincipalId, @{n='Role';e={$roleNames[$_.RoleDefinitionId]}}, DirectoryScopeId, StartDateTime, EndDateTime, @{n='State';e={"Active ($($_.AssignmentType))"}}
$eligible + $active | Export-Csv .\EntraRolePIM-Iteration3.csv -NoTypeInformation
```

**Write example: admin makes a user eligible for 180 days**
```powershell
Connect-MgGraph -Scopes "RoleEligibilitySchedule.ReadWrite.Directory" -NoWelcome
$roleId = (Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq 'Exchange Administrator'").Id
$params = @{
    action           = "adminAssign"
    justification    = "Ticket <ticketId>"
    roleDefinitionId = $roleId
    directoryScopeId = "/"
    principalId      = "<userObjectId>"
    scheduleInfo     = @{ startDateTime = (Get-Date).ToUniversalTime().ToString("o")
                          expiration    = @{ type = "afterDuration"; duration = "P180D" } }
}
New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -BodyParameter $params
```
**Rollback:** the same call with `action = "adminRemove"` for the same principal, role and scope. Keep the Iteration 2 code path available (but unused) until 28 October in case you need to compare outputs.
</details>

<details><summary>Playbook 2 — Azure resources: Iteration 2 (Graph) → Azure Resource Manager</summary>

**Auth change:** grant the automation identity **User Access Administrator** (write) or **Reader** plus `Microsoft.Authorization/roleEligibilitySchedules/read` (read-only reporting) at the management group or subscription scope. It needs **no** Graph permission for this.

```powershell
Connect-AzAccount -Identity   # e.g. Automation managed identity
$scopes = Get-AzSubscription | ForEach-Object { "/subscriptions/$($_.Id)" }

$report = foreach ($s in $scopes) {
    Get-AzRoleEligibilityScheduleInstance -Scope $s -ErrorAction Continue |
        Select-Object @{n='Scope';e={$_.Scope}}, PrincipalId, PrincipalType, RoleDefinitionDisplayName, StartDateTime, EndDateTime, MemberType
}
$report | Export-Csv .\AzurePIM-Eligible-Iteration3.csv -NoTypeInformation
```
`MemberType` shows `Direct` vs `Inherited`. Filter to `Direct` if you query nested scopes, or you'll double-count.

**Raw REST equivalent** (for Logic Apps and Functions):
```
GET https://management.azure.com/subscriptions/<subscriptionId>/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&$filter=atScope()
Authorization: Bearer <token with aud https://management.azure.com/>
```
In a Logic App, change the HTTP action's managed-identity audience from `https://graph.microsoft.com` to `https://management.azure.com`. This is the most commonly missed step.

**Write example: make a group eligible for Contributor on a resource group**
```powershell
$scope = "/subscriptions/<subscriptionId>/resourceGroups/<rgName>"
$roleDefId = "$scope/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"  # Contributor
New-AzRoleEligibilityScheduleRequest -Name (New-Guid).Guid -Scope $scope `
    -PrincipalId "<groupObjectId>" -RoleDefinitionId $roleDefId `
    -RequestType AdminAssign -ScheduleInfoStartDateTime (Get-Date).ToUniversalTime().ToString("o") `
    -ExpirationType AfterDuration -ExpirationDuration "P365D" -Justification "Ticket <ticketId>"
```
**Rollback:** `New-AzRoleEligibilityScheduleRequest ... -RequestType AdminRemove` for the same principal, role and scope.
</details>

<details><summary>Playbook 3 — Groups (legacy aadGroups): → Graph identityGovernance/privilegedAccess/group</summary>

```powershell
Connect-MgGraph -Scopes "PrivilegedEligibilitySchedule.Read.AzureADGroup","PrivilegedAssignmentSchedule.Read.AzureADGroup" -NoWelcome
$groupId = "<groupObjectId>"
Get-MgIdentityGovernancePrivilegedAccessGroupEligibilityScheduleInstance -Filter "groupId eq '$groupId'" -All |
    Select-Object PrincipalId, AccessId, StartDateTime, EndDateTime
Get-MgIdentityGovernancePrivilegedAccessGroupAssignmentScheduleInstance -Filter "groupId eq '$groupId'" -All |
    Select-Object PrincipalId, AccessId, AssignmentType, StartDateTime, EndDateTime
```
`AccessId` is `member` or `owner`. Groups queries **need a `groupId` (or `principalId`) filter**, because unfiltered list calls aren't supported. Enumerate PIM-onboarded groups from your own inventory, or from the groups returned by the eligibility schedules you already know about.

**Rollback:** read-only. For write migrations, use `adminRemove` on the matching `...ScheduleRequest`.
</details>

<details><summary>Playbook 4 — Third-party / open-source tool you don't own</summary>

1. Collect proof: Graph activity log rows (validation step 3) with the tool's `AppId`.
2. Check the vendor's release notes or GitHub issues for an Iteration 3 release. For AzGovViz, follow issue #291 (a fix branch was offered for testing). Until you've upgraded, run it with `-NoPIMEligibility` to avoid a misleading empty PIM section.
3. If there's no fix before 28 October, disable the PIM feature in the tool and stand up Playbook 1 or 2 reporting as a stopgap.
4. Record it as a vendor risk with a date.
</details>

<details><summary>Playbook 5 — Remove legacy PrivilegedAccess.* grants after migration</summary>

```powershell
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","DelegatedPermissionGrant.ReadWrite.All","Application.Read.All" -NoWelcome
$graphSp  = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$clientSp = Get-MgServicePrincipal -Filter "appId eq '<clientAppId>'"
$roleIds  = ($graphSp.AppRoles | Where-Object Value -like 'PrivilegedAccess.*').Id

# Save a before-state for rollback
$toRemove = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $clientSp.Id -All |
    Where-Object { $_.ResourceId -eq $graphSp.Id -and $roleIds -contains $_.AppRoleId }
$toRemove | Select-Object Id, AppRoleId, ResourceId, PrincipalId | Export-Csv ".\PIMv2-grants-$($clientSp.AppId).csv" -NoTypeInformation

$toRemove | ForEach-Object { Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $clientSp.Id -AppRoleAssignmentId $_.Id }
```
Also remove `PrivilegedAccess.*` from the app registration's **API permissions** so re-consent doesn't bring it back.

**Rollback (before 28 October only):** `New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $clientSp.Id -PrincipalId $clientSp.Id -ResourceId $graphSp.Id -AppRoleId <AppRoleId from CSV>`. After 28 October, restoring the grant does nothing.
</details>

---
## Evidence Pack

```powershell
<# Collect-PIMIteration2Evidence.ps1: read-only. Graph SDK v2 required. Az.Resources optional. #>
param([string]$OutDir = ".\PIMv2-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)",
      [string[]]$CodePath)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Connect-MgGraph -Scopes "Application.Read.All","DelegatedPermissionGrant.Read.All","RoleManagement.Read.Directory" -NoWelcome
$ctx     = Get-MgContext
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$roleMap = @{}; $graphSp.AppRoles | ForEach-Object { $roleMap[[string]$_.Id] = $_.Value }
$legacyRoleIds = @($graphSp.AppRoles | Where-Object Value -like 'PrivilegedAccess.*' | ForEach-Object { [string]$_.Id })

# 1. Application grants
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $graphSp.Id -All |
  Where-Object { $legacyRoleIds -contains [string]$_.AppRoleId } |
  Select-Object PrincipalDisplayName, PrincipalId, @{n='Permission';e={$roleMap[[string]$_.AppRoleId]}}, CreatedDateTime |
  Export-Csv "$OutDir\01-LegacyAppPermissions.csv" -NoTypeInformation

# 2. Delegated grants
Get-MgOauth2PermissionGrant -Filter "resourceId eq '$($graphSp.Id)'" -All |
  Where-Object { $_.Scope -match 'PrivilegedAccess\.' } |
  Select-Object ClientId, ConsentType, PrincipalId, Scope |
  Export-Csv "$OutDir\02-LegacyDelegatedGrants.csv" -NoTypeInformation

# 3. Iteration 3 baseline counts (Entra roles)
[pscustomobject]@{
  EligibleInstances = @(Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance -All).Count
  ActiveInstances   = @(Get-MgRoleManagementDirectoryRoleAssignmentScheduleInstance -All).Count
} | Export-Csv "$OutDir\03-Iteration3-EntraBaseline.csv" -NoTypeInformation

# 4. Optional static scan
if ($CodePath) {
  $scanner = Join-Path $PSScriptRoot 'Find-PIMIteration2CodeReference.ps1'
  if (Test-Path $scanner) { & $scanner -Path $CodePath -OutputPath $OutDir }
}

# 5. KQL for Log Analytics
@'
MicrosoftGraphActivityLogs
| where TimeGenerated > ago(30d) and RequestUri has "/beta/privilegedAccess/"
| summarize Calls=count(), LastSeen=max(TimeGenerated), Codes=make_set(ResponseStatusCode) by AppId, UserId, RequestMethod
'@ | Out-File "$OutDir\04-GraphActivityLog.kql"

[pscustomobject]@{ TenantId=$ctx.TenantId; Collected=(Get-Date).ToString('u'); MessageCenter='MC1181281'; RetirementDate='2026-10-28' } |
  Export-Csv "$OutDir\00-Summary.csv" -NoTypeInformation
Write-Host "Evidence written to $OutDir" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Legacy permission names | `$graphSp.AppRoles \| ? Value -like 'PrivilegedAccess.*'` |
| App-only legacy holders | `Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $graphSp.Id -All \| ? { $roleIds -contains $_.AppRoleId }` |
| Delegated legacy holders | `Get-MgOauth2PermissionGrant -Filter "resourceId eq '<graphSpId>'" -All \| ? Scope -match 'PrivilegedAccess\.'` |
| Static scan | `.\Find-PIMIteration2CodeReference.ps1 -Path <dir>` |
| Who's calling (KQL) | `MicrosoftGraphActivityLogs \| where RequestUri has "/beta/privilegedAccess/"` |
| Entra eligible (It. 3) | `Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance -All` |
| Entra active (It. 3) | `Get-MgRoleManagementDirectoryRoleAssignmentScheduleInstance -All` |
| Entra role policy | `Get-MgPolicyRoleManagementPolicyAssignment -Filter "scopeId eq '/' and scopeType eq 'DirectoryRole'" -ExpandProperty policy` |
| Azure eligible (It. 3) | `Get-AzRoleEligibilityScheduleInstance -Scope /subscriptions/<id>` |
| Azure active (It. 3) | `Get-AzRoleAssignmentScheduleInstance -Scope /subscriptions/<id>` |
| Azure role policy | `Get-AzRoleManagementPolicyAssignment -Scope /subscriptions/<id>` |
| Groups eligible (It. 3) | `Get-MgIdentityGovernancePrivilegedAccessGroupEligibilityScheduleInstance -Filter "groupId eq '<id>'"` |
| Check token audience | `(Get-AzAccessToken -ResourceUrl https://management.azure.com/).Token` → decode `aud` |
| RBAC for automation SP | `Get-AzRoleAssignment -ObjectId <spObjectId> -Scope <scope>` |

---
## Source Confidence

| Claim | Source | Confidence |
|---|---|---|
| Retirement 2026-10-28, calls "will fail", "no longer return data" | MC1181281 full text (mc.merill.net, published 2025-10-29) | High |
| Iteration 2 = `aadRoles` + `azureResources`; UI migrating to Iteration 3 | Learn "Privileged Identity Management APIs" (ms.date 2026-04-23) | High |
| Groups also affected | MC1181281 only. The Learn pages don't list `aadGroups`. | Medium. Treat as in scope. |
| Iteration 2 → ARM mapping table | Learn "Privileged Identity Management iteration 2 APIs" migration section | High |
| Exact failure HTTP status after cutover | Not documented | Unknown. Plan for any of 404/400/403/empty-200. |
| AzGovViz affected (uses `/beta/privilegedAccess/azureResources`, `PrivilegedAccess.Read.AzureResources`) | GitHub issue JulianHayward/Azure-MG-Sub-Governance-Reporting #291 | High for the code reference. Fix release status still pending. |
| Iteration 2 `type` → Iteration 3 `action` mapping | Graph resource docs for both iterations | High |

---
## 🎓 Learning Pointers

- **"Beta in production" has a deadline.** Iteration 2 was never GA, yet it runs years of governance automation. Keep a register of every `/beta` Graph call in your estate. `Find-PIMIteration2CodeReference.ps1` has a pattern you can adapt for other beta-to-GA migrations. [Microsoft Graph versioning and support](https://learn.microsoft.com/en-us/graph/versioning-and-support)
- **Azure-resource PIM is an Azure RBAC problem, not a Graph problem.** The replacement API authenticates against ARM and authorizes with RBAC at the resource scope. The consent screen that granted `PrivilegedAccess.ReadWrite.AzureResources` has no Iteration 3 equivalent. [PIM for Azure resources REST sample](https://learn.microsoft.com/en-us/rest/api/authorization/privileged-role-eligibility-rest-sample)
- **Microsoft Graph activity logs answer "who calls this endpoint?"** Earlier versions of this repo's B runbook said no call telemetry exists. For Graph it does, if you've enabled the `MicrosoftGraphActivityLogs` diagnostic setting. Enable it before the next retirement date, not after. [Microsoft Graph activity logs](https://learn.microsoft.com/en-us/graph/microsoft-graph-activity-logs-overview)
- **Empty is not zero.** Reporting tools that turn an API failure into "0 eligible assignments" produce a false clean audit. Add an explicit "API call succeeded" check to every governance report, so a failed call can't be read as "no findings".
- **Read MC text and Learn text side by side.** Here they disagree on Groups. When sources conflict, treat the wider one as in scope until you've proved otherwise. [MC1181281 archive](https://mc.merill.net/message/MC1181281) · [PIM API concepts](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-apis)
- Related in this repo: [PIMIteration2Retirement-B.md](PIMIteration2Retirement-B.md), `EntraID/Scripts/Get-PIMIteration2APIUsageAudit.ps1` (application grants), `EntraID/Scripts/Find-PIMIteration2CodeReference.ps1` (static scan), [PIM-A.md](PIM-A.md), [PIMAzureResources-A.md](PIMAzureResources-A.md).
