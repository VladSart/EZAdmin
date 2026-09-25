# User.ReadBasic.All Permission Scope Change — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

> **Status as of 2026-09-25:** Message Center **MC1470871** (published 2026-09-11) confirms the fix applies to **both delegated and application (app-only)** `User.ReadBasic.All`. Worldwide rollout runs from **mid-September 2026** and should finish by **late September 2026**. If you're reading this after that window, assume the fix is live in every commercial tenant. Microsoft's own wording says affected apps "may experience failures or permission-related errors". Expect **403s, not silently empty data**. For the fast path, see [ReadBasicAllScopeChange-B.md](ReadBasicAllScopeChange-B.md).

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
- Microsoft Graph permission `User.ReadBasic.All`, **delegated and application** forms
- The two data sets being removed from it: **user app role assignments** (`/users/{id}/appRoleAssignments`, `Get-MgUserAppRoleAssignment`) and **user license details** (`/users/{id}/licenseDetails`, `Get-MgUserLicenseDetail`)
- Finding exposed apps, detecting real calls with Graph activity logs, choosing replacement permissions and consent mechanics

**Out of scope**
- The `memberOf` retirement from the same month: see `EntraID/Troubleshooting/MemberOfRetirement-B.md`
- General app-consent governance: see `EntraID/Troubleshooting/AppConsentGovernance-*` and `Get-AppConsentGovernanceAudit.ps1`
- Directory-role (`/users/{id}/memberOf` → roles) reads. These are a different permission path and aren't affected by MC1470871.

**Assumptions**
- Commercial (worldwide) cloud. MC1470871 lists only "General Availability (Worldwide)". Sovereign-cloud timing isn't stated.
- You have at least Cloud Application Administrator (to read grants) or Global Reader. You need Privileged Role Administrator or Global Administrator to grant admin consent for application permissions.
- Microsoft Graph PowerShell SDK v2.x.

---
## How It Works

<details><summary>Full architecture: how a Graph permission maps to data, and what MC1470871 changes</summary>

### Permissions are two different objects in Entra

The Microsoft Graph service principal (`appId 00000003-0000-0000-c000-000000000000`) in every tenant publishes two catalogues:

| Catalogue | Property on Graph SP | Consent object created in your tenant | Token claim |
|---|---|---|---|
| Delegated permissions | `oauth2PermissionScopes` | `oAuth2PermissionGrant` (`consentType` = `AllPrincipals` or `Principal`) | `scp` |
| Application permissions | `appRoles` | `appRoleAssignment` on the client SP (`principalId` = client SP, `resourceId` = Graph SP) | `roles` |

`User.ReadBasic.All` exists in **both** catalogues, with different GUIDs. An inventory that only looks at `oAuth2PermissionGrant` objects (like `Get-ReadBasicAllUsageAudit.ps1`, which predates MC1470871) **misses every daemon, backend service and automation account** holding the app-only version. That's why `Get-ReadBasicAllAppOnlyExposure.ps1` exists.

### What the permission is supposed to return

According to the Microsoft Graph permissions reference, `User.ReadBasic.All` covers a small basic profile:
- **Delegated:** display name, first and last name, email address, photo
- **Application:** the same list, plus open extensions

Microsoft's authorization layer checks each Graph **resource/relationship** separately. Before this fix, the authorization rules for two navigation paths off `user` accepted `User.ReadBasic.All`:

```
GET /users/{id}/appRoleAssignments      ← which enterprise apps / app roles the user is assigned
GET /users/{id}/licenseDetails          ← SKU + service-plan detail for the user's licences
```

Neither is "basic profile" data. App role assignments show which apps a person can reach, which is useful reconnaissance for an attacker holding a low-privilege token. Licence details show which security features (P2, Defender, and so on) protect that user. MC1470871 labels the fix a **security vulnerability** remediation, and the reconnaissance value is why.

### What the fix changes

```
BEFORE (pre mid-Sep 2026)                      AFTER (rollout complete, late Sep 2026)
─────────────────────────                      ────────────────────────────────────────
token.scp/roles = User.ReadBasic.All           token.scp/roles = User.ReadBasic.All
  GET /users/{id}?$select=displayName  → 200     GET /users/{id}?$select=displayName  → 200
  GET /users/{id}/appRoleAssignments   → 200     GET /users/{id}/appRoleAssignments   → 403
  GET /users/{id}/licenseDetails       → 200     GET /users/{id}/licenseDetails       → 403
```

It's an **authorization-rule change on Microsoft's side**, and nothing about it lives in your tenant:
- Nothing in your tenant changes. Grants, consent records and app registrations are untouched.
- The permission isn't deprecated or renamed, and its GUIDs stay the same.
- A token issued **before** the rule change still has the same `scp`/`roles` claim. Graph enforces at request time, so cached tokens don't buy any grace period.

### Why "403 or empty" depends on the caller

The failure shape depends on how the app handles errors:

| Caller pattern | What the user or operator sees |
|---|---|
| Direct `GET .../appRoleAssignments` with error handling | Logged 403 `Authorization_RequestDenied`, "Insufficient privileges to complete the operation." |
| Graph SDK cmdlet inside `try { } catch { }` that swallows errors | Empty column in a report ("no apps assigned", "unlicensed") that looks like valid data |
| `$expand=appRoleAssignments` on a `/users` list call | Can fail the **whole** request, not just the expanded property. Treat as unverified: test your exact query. |
| `$batch` request | The outer batch returns 200. The individual sub-response carries the 403 and is easy to miss (see `GraphAPI-BatchOperations-A.md`). |
| Power Automate / Logic Apps HTTP action | The run fails at that action. Flows with "configure run after: has failed" branches may carry on with empty variables. |

The "silently empty licence report" case is the dangerous one. A licence-reconciliation dashboard can show users as unlicensed and trigger wrong procurement or offboarding decisions.

### Replacement permissions: MC guidance vs endpoint docs

MC1470871 recommends:

| Needs | MC1470871 says |
|---|---|
| App role assignments | `User.Read.All` |
| Licence details | `LicenseAssignment.Read.All` |
| Both | `User.Read.All` |

Two community sources (Our Cloud Network, 12 Sep 2026, Daniel Bradley MVP; Tenant Wizards, 14 Sep 2026) point out that the **endpoint reference pages don't agree** at time of writing:
- *List appRoleAssignments (user)* lists `AppRoleAssignment.ReadWrite.All` (delegated) or `Directory.Read.All` (application) as least-privileged. `User.Read.All` isn't listed.
- *List licenseDetails* lists delegated `LicenseAssignment.Read.All` and says application permissions are **not supported** there. That conflicts with the MC saying app-only callers should use it.

**Engineering position:** endpoint permission tables often lag behind authorization-rule changes, so the MC is the more recent statement of intent. Grant according to the MC, then **test the exact call** with the exact grant type (delegated vs app-only) before you remove anything. Don't reach for `Directory.Read.All` or a `ReadWrite` permission as a precaution. That trades a narrow over-grant Microsoft just closed for a much wider one. For app-only licence reads, where the docs say `licenseDetails` doesn't support application permissions, the options are:
1. `User.Read.All` (application) plus reading the `assignedLicenses` property on the user object (SKU GUIDs only, no service-plan breakdown), or
2. The newer cloud licensing APIs with `User-UsageRight.Read.All`. Our Cloud Network recommends this, but it's a different data model, so validate before adopting it.

### Delegated effective-permission reminder

For delegated calls, effective access = **scope ∩ signed-in user's directory rights**. A delegated `User.Read.All` grant used by a guest, or by a member in a tenant with restricted default user permissions, may still fail where the same call succeeds for an admin. When a migrated app works for IT but fails for end users, look here first, before blaming the fix.

</details>

---
## Dependency Stack

```
Layer 6  Business process: licence reconciliation, onboarding checks, access reviews,
         HR integrations, "who has access to app X" reports
            │
Layer 5  App / script / flow code calling:
            /users/{id}/appRoleAssignments   (Get-MgUserAppRoleAssignment)
            /users/{id}/licenseDetails       (Get-MgUserLicenseDetail)
            $expand=appRoleAssignments  |  $batch sub-requests
            │
Layer 4  Access token  ─ scp claim (delegated)  or  roles claim (app-only)
            │             issued by Entra ID token service from…
Layer 3  Consent objects in YOUR tenant
            ├─ oAuth2PermissionGrant  (delegated;  AllPrincipals | Principal)
            └─ appRoleAssignment      (application; client SP → Graph SP)
            │
Layer 2  Microsoft Graph SP permission catalogue
            ├─ oauth2PermissionScopes  "User.ReadBasic.All"  (delegated GUID)
            └─ appRoles                "User.ReadBasic.All"  (application GUID)
            │
Layer 1  Graph authorization rules per resource/relationship   ◄── MC1470871 changes THIS layer
            (Microsoft-side, not visible or configurable in your tenant)
```

The change happens at Layer 1, but every symptom shows up at Layer 5/6. Layers 2–4 look identical before and after, which is why a "nothing changed in our tenant" change review won't find the cause.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Report or script suddenly shows every user as "unlicensed" or "no app assignments" from mid/late Sept 2026 | App holds only `User.ReadBasic.All`, and errors are swallowed | Validation step 4 (Graph activity logs 403s), then read the script's `catch` blocks |
| `403 Authorization_RequestDenied` on `/users/{id}/appRoleAssignments` | MC1470871 fix live; app lacks `User.Read.All` (or a broader permission) | Validation steps 2–3 |
| `403` on `/users/{id}/licenseDetails` in an **app-only** daemon | Fix live, **and** `licenseDetails` may not accept application permissions at all | Playbook 3: switch to `assignedLicenses` via `User.Read.All`, or the cloud licensing API |
| Migrated app works for admins, fails for normal users | Delegated effective permissions = scope ∩ user rights | Test as a non-admin, and check `Get-MgPolicyAuthorizationPolicy` default user permissions |
| Whole `/users?$expand=appRoleAssignments` call fails, not just the expanded field | Expand of an unauthorized relationship | Rerun without `$expand` to confirm, then fix the permission |
| `$batch` returns 200 but downstream data is empty | Sub-request 403 ignored | Inspect `responses[].status` per sub-request |
| Power Automate flow "Succeeded" but outputs empty | "Run after: has failed" branch continued | Flow run history, the failed HTTP action's output body |
| Inventory script shows no apps holding `User.ReadBasic.All`, yet something breaks | Script only checked **delegated** grants | Run `Get-ReadBasicAllAppOnlyExposure.ps1`, which covers both |
| Third-party SaaS integration breaks; vendor says "we only request basic read" | Vendor code relied on the over-grant | Vendor ticket with your Graph activity log evidence (Evidence Pack) |

---
## Validation Steps

**1. Resolve both `User.ReadBasic.All` definitions live**
```powershell
Connect-MgGraph -Scopes "Application.Read.All","DelegatedPermissionGrant.Read.All" -NoWelcome
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$graphSp.Oauth2PermissionScopes | Where-Object Value -eq 'User.ReadBasic.All' | Select-Object Id, Value, AdminConsentDescription
$graphSp.AppRoles               | Where-Object Value -eq 'User.ReadBasic.All' | Select-Object Id, Value, Description
```
- **Good:** two rows with different `Id` GUIDs, one delegated and one application.
- **Bad:** only one row returned. Your SDK or filter is wrong. Don't carry on with a half inventory.

**2. Inventory both grant types**
```powershell
.\Get-ReadBasicAllAppOnlyExposure.ps1 -OutputPath C:\Temp\RBA
```
- **Good:** the CSV lists each client SP with `GrantType` (Delegated/Application), `AlsoHoldsUserReadAll` and `AlsoHoldsLicenseAssignmentRead`.
- **Bad:** rows with `ReplacementPresent = False`. These are your lead list.

**3. Reproduce with a test app registration** (never test with the Graph PowerShell SDK's own first-party app, which already holds broad scopes and hides the failure)
```powershell
# App-only test: test app reg holding ONLY User.ReadBasic.All (Application), certificate auth
Connect-MgGraph -ClientId <testAppId> -TenantId <tenantId> -CertificateThumbprint <thumb> -NoWelcome
(Get-MgContext).Scopes           # expect: User.ReadBasic.All only
Get-MgUser -UserId <UPN> -Property displayName,mail | Select-Object DisplayName, Mail   # expect success
Get-MgUserAppRoleAssignment -UserId <UPN> -ErrorAction Stop                          # post-fix: 403
Get-MgUserLicenseDetail     -UserId <UPN> -ErrorAction Stop                          # post-fix: 403
```
- **Good (fix live):** profile read succeeds, and both relationship reads throw `Insufficient privileges`.
- **Unexpected:** the relationship reads still succeed after late September 2026. Check the Message Center for a tenant-specific delay, and record it.

**4. Find real callers from server-side telemetry: Microsoft Graph activity logs**

This is the only source that shows what apps **actually called**. It needs a diagnostic setting sending `MicrosoftGraphActivityLogs` to Log Analytics (Entra ID P1/P2), and it only covers calls made after that setting was enabled.
```kusto
MicrosoftGraphActivityLogs
| where TimeGenerated > ago(30d)
| where RequestUri has "/appRoleAssignments" or RequestUri has "/licenseDetails"
| where RequestUri has "/users/" or RequestUri has "/me/"
| where Scopes has "User.ReadBasic.All" or Roles has "User.ReadBasic.All"
| summarize Calls = count(),
            Denied = countif(ResponseStatusCode == 403),
            FirstSeen = min(TimeGenerated), LastSeen = max(TimeGenerated)
          by AppId, ServicePrincipalId, ResponseStatusCode
| order by Calls desc
```
- **Good:** no rows. No app called these relationships under `User.ReadBasic.All` in the window.
- **Bad:** rows with `ResponseStatusCode == 200` before the rollout mean the app **depended on the over-grant**. Rows with `403` after it mean the app is **broken now**. The `Scopes`/`Roles` columns show the token's full permission set, so an app that also holds `User.Read.All` won't be listed falsely as dependent.

**5. After remediation, confirm the replacement is in the token**
```kusto
MicrosoftGraphActivityLogs
| where TimeGenerated > ago(1d) and AppId == "<clientAppId>"
| where RequestUri has "/appRoleAssignments" or RequestUri has "/licenseDetails"
| project TimeGenerated, ResponseStatusCode, Scopes, Roles, RequestUri
```
- **Good:** `200`, with `User.Read.All` (or `LicenseAssignment.Read.All`) present in `Scopes`/`Roles`.
- **Bad:** still `403` with the new permission missing. Consent wasn't granted, or the app is still using a cached token from before consent. App-only tokens last about 60–90 minutes, so restart the service or clear its token cache.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Scope the exposure (no tenant changes)
1. Run validation steps 1–2. Split the output into **delegated tenant-wide**, **delegated per-user** and **application** grants.
2. Drop anything that already holds `User.Read.All`, `Directory.Read.All` or `Directory.ReadWrite.All` in the same grant type. Those apps weren't relying on the over-grant for their access, even if their code calls these paths.
3. Rank what's left: **application** grants first (daemons run unattended, and nobody notices until a report is wrong), then **AllPrincipals**, then **Principal**.

### Phase 2 — Prove dependency (telemetry, then code)
1. If `MicrosoftGraphActivityLogs` is available, run validation step 4 over the longest retention window you have. This is proof, not inference.
2. If it isn't available, grep first-party code for `appRoleAssignments`, `licenseDetails`, `Get-MgUserAppRoleAssignment`, `Get-MgUserLicenseDetail`, `assignedLicenses` and `$expand=appRoleAssignments`. For SaaS, open a vendor ticket.
3. Consider enabling the Graph activity log diagnostic setting now, even post-rollout. The 403s it captures are your breakage inventory.

### Phase 3 — Remediate (per app)
Pick Playbook 1, 2 or 3 based on grant type and data need. Always add the new permission **before** removing anything.

### Phase 4 — Verify and close
1. Run validation step 5 for each remediated app.
2. Rerun the inventory. Apps that still hold `User.ReadBasic.All` **and** a replacement are fine. Keep `User.ReadBasic.All` only if some code path still depends on it alone. Otherwise it's redundant but harmless.
3. Record the decision per app (Playbook 4).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Delegated app needs app role assignments (and maybe licences)</summary>

```powershell
Connect-MgGraph -Scopes "DelegatedPermissionGrant.ReadWrite.All","Application.Read.All" -NoWelcome
$graphSp  = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$clientSp = Get-MgServicePrincipal -Filter "appId eq '<clientAppId>'"

# Find the existing tenant-wide delegated grant for this client → Graph
$grant = Get-MgOauth2PermissionGrant -Filter "clientId eq '$($clientSp.Id)' and resourceId eq '$($graphSp.Id)' and consentType eq 'AllPrincipals'"

# ADD User.Read.All to the existing scope string (space-delimited). Don't replace the string.
$newScope = (($grant.Scope -split ' ') + 'User.Read.All' | Where-Object { $_ } | Select-Object -Unique) -join ' '
Update-MgOauth2PermissionGrant -OAuth2PermissionGrantId $grant.Id -Scope $newScope
(Get-MgOauth2PermissionGrant -OAuth2PermissionGrantId $grant.Id).Scope   # verify
```
Also add `User.Read.All` to the **app registration's** required permissions (Entra admin center > App registrations > *app* > API permissions). Otherwise the next interactive consent or re-consent can quietly revert the scope string.

**Rollback:** run `Update-MgOauth2PermissionGrant` again with the original `$grant.Scope` value. Save it before you change anything: `$grant.Scope | Out-File .\grant-<clientAppId>-before.txt`.

**Per-user (`Principal`) grants:** these are one grant per user. Get a tenant-wide admin consent for the new scope instead of editing hundreds of per-user grants.
</details>

<details><summary>Playbook 2 — Application (app-only) daemon needs app role assignments</summary>

```powershell
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All" -NoWelcome
$graphSp  = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$clientSp = Get-MgServicePrincipal -Filter "appId eq '<clientAppId>'"
$role     = $graphSp.AppRoles | Where-Object { $_.Value -eq 'User.Read.All' -and $_.AllowedMemberTypes -contains 'Application' }

New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $clientSp.Id `
    -PrincipalId $clientSp.Id -ResourceId $graphSp.Id -AppRoleId $role.Id
```
Restart the daemon or clear its token cache. App-only tokens only pick up the new `roles` claim when a new token is issued.

**Rollback:**
```powershell
$a = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $clientSp.Id -All |
     Where-Object { $_.AppRoleId -eq $role.Id -and $_.ResourceId -eq $graphSp.Id }
Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $clientSp.Id -AppRoleAssignmentId $a.Id
```
</details>

<details><summary>Playbook 3 — App needs licence data only</summary>

**Delegated:** add `LicenseAssignment.Read.All` (delegated) as in Playbook 1. This is the narrowest option and the one MC1470871 recommends.

**Application:** the `licenseDetails` reference says application permissions aren't supported, which conflicts with the MC. Test in this order:
1. Grant `LicenseAssignment.Read.All` (application) as in Playbook 2 and test `Get-MgUserLicenseDetail`. If it returns `200`, you're done.
2. If it still returns `403`, change the code to read the **`assignedLicenses`** property with `User.Read.All` (application):
   ```powershell
   Get-MgUser -UserId <UPN> -Property id,userPrincipalName,assignedLicenses |
       Select-Object UserPrincipalName, @{n='SkuIds';e={$_.AssignedLicenses.SkuId -join ';'}}
   # Map SkuId → name with Get-MgSubscribedSku (needs Organization.Read.All or LicenseAssignment.Read.All)
   ```
   You lose the per-service-plan breakdown that `licenseDetails` gives you. `assignedLicenses.disabledPlans` still shows which plans are switched off.
3. Evaluate the cloud licensing APIs (`User-UsageRight.Read.All`). They're a different data model, so treat them as a redesign, not a drop-in replacement.

**Rollback:** remove the added grant as in Playbook 1 or 2.
</details>

<details><summary>Playbook 4 — Confirmed unaffected / vendor-owned: document and close</summary>

Record, for each app:

| Field | Example |
|---|---|
| App / AppId | Contoso HR Sync / `<appId>` |
| Grant type(s) | Application |
| Evidence | Graph activity logs: 0 calls to appRoleAssignments/licenseDetails in 90 days |
| Decision | No change. Leave `User.ReadBasic.All` as is. |
| Reviewer / date | `<name>` / `<date>` |

For SaaS vendors that can't confirm: add the replacement permission proactively (Playbook 1 or 2) only if the vendor documents it as supported. Otherwise, log the app as "at risk" and pass your Graph activity log evidence to the vendor.
</details>

<details><summary>Playbook 5 — Post-rollout emergency (something broke, business is impacted)</summary>

1. Confirm the signature: a `403` on `/appRoleAssignments` or `/licenseDetails` under a token whose `Scopes`/`Roles` contains `User.ReadBasic.All` and no broader permission (validation step 4 or the app's own logs).
2. Apply Playbook 1, 2 or 3 straight away. Admin consent takes effect for new tokens within minutes.
3. Force a new token by restarting the service or app pool, or re-running the scheduled task. For delegated desktop or web apps, users may need to sign out and back in.
4. **Don't** grant `Directory.Read.All` "to get it working". It's much broader than what was removed. If you must use it as a stopgap, raise a change ticket that expires within 7 days.
5. Microsoft won't roll this back, because it's a security fix. Don't open a support case asking for the old behaviour back.
</details>

---
## Evidence Pack

```powershell
<#
  Collect-ReadBasicAllEvidence.ps1: read-only evidence bundle for MC1470871 escalations.
  Requires Microsoft.Graph.Authentication + Microsoft.Graph.Applications.
#>
param(
    [Parameter(Mandatory)][string]$ClientAppId,
    [string]$OutDir = ".\RBA-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Connect-MgGraph -Scopes "Application.Read.All","DelegatedPermissionGrant.Read.All" -NoWelcome

$ctx      = Get-MgContext
$graphSp  = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$clientSp = Get-MgServicePrincipal -Filter "appId eq '$ClientAppId'"
if (-not $clientSp) { throw "No service principal for appId $ClientAppId in tenant $($ctx.TenantId)" }

# 1. Permission definitions (both catalogues)
$defs = @(
  $graphSp.Oauth2PermissionScopes | Where-Object Value -in 'User.ReadBasic.All','User.Read.All','LicenseAssignment.Read.All' |
    Select-Object @{n='Type';e={'Delegated'}}, Id, Value, AdminConsentDescription
  $graphSp.AppRoles | Where-Object Value -in 'User.ReadBasic.All','User.Read.All','LicenseAssignment.Read.All' |
    Select-Object @{n='Type';e={'Application'}}, Id, Value, @{n='AdminConsentDescription';e={$_.Description}}
)
$defs | Export-Csv "$OutDir\01-PermissionDefinitions.csv" -NoTypeInformation

# 2. Delegated grants held by the client to Graph
Get-MgOauth2PermissionGrant -Filter "clientId eq '$($clientSp.Id)'" -All |
  Where-Object ResourceId -eq $graphSp.Id |
  Select-Object Id, ConsentType, PrincipalId, Scope |
  Export-Csv "$OutDir\02-DelegatedGrants.csv" -NoTypeInformation

# 3. Application permissions held by the client on Graph
$roleMap = @{}; $graphSp.AppRoles | ForEach-Object { $roleMap[$_.Id] = $_.Value }
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $clientSp.Id -All |
  Where-Object ResourceId -eq $graphSp.Id |
  Select-Object Id, AppRoleId, @{n='Permission';e={$roleMap[$_.AppRoleId]}}, CreatedDateTime |
  Export-Csv "$OutDir\03-ApplicationPermissions.csv" -NoTypeInformation

# 4. App registration's requested permissions (if the app is owned by this tenant)
$app = Get-MgApplication -Filter "appId eq '$ClientAppId'" -ErrorAction SilentlyContinue
if ($app) { $app.RequiredResourceAccess | ConvertTo-Json -Depth 5 | Out-File "$OutDir\04-RequiredResourceAccess.json" }
else      { "Multi-tenant / third-party app: no local application object." | Out-File "$OutDir\04-RequiredResourceAccess.json" }

# 5. KQL for the Graph activity log step (run in Log Analytics, paste results into the ticket)
@"
MicrosoftGraphActivityLogs
| where TimeGenerated > ago(30d) and AppId == "$ClientAppId"
| where RequestUri has "/appRoleAssignments" or RequestUri has "/licenseDetails"
| summarize Calls=count() by ResponseStatusCode, bin(TimeGenerated, 1d), Scopes, Roles
"@ | Out-File "$OutDir\05-GraphActivityLog.kql"

[pscustomobject]@{
  TenantId = $ctx.TenantId; Collected = (Get-Date).ToString('u'); ClientAppId = $ClientAppId
  ClientDisplayName = $clientSp.DisplayName; MessageCenter = 'MC1470871'
} | Export-Csv "$OutDir\00-Summary.csv" -NoTypeInformation
Write-Host "Evidence written to $OutDir" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Graph SP | `Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"` |
| Delegated scope definition | `$graphSp.Oauth2PermissionScopes \| ? Value -eq 'User.ReadBasic.All'` |
| Application role definition | `$graphSp.AppRoles \| ? Value -eq 'User.ReadBasic.All'` |
| All delegated grants with the scope | `Get-MgOauth2PermissionGrant -All \| ? { $_.Scope -split ' ' -contains 'User.ReadBasic.All' }` |
| All app-only holders | `Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $graphSp.Id -All \| ? AppRoleId -eq <appRoleId>` |
| Both, with replacement check | `.\Get-ReadBasicAllAppOnlyExposure.ps1` |
| Test app role read | `Get-MgUserAppRoleAssignment -UserId <UPN> -ErrorAction Stop` |
| Test licence read | `Get-MgUserLicenseDetail -UserId <UPN> -ErrorAction Stop` |
| App-only licence fallback | `Get-MgUser -UserId <UPN> -Property assignedLicenses` |
| Scopes in current token | `(Get-MgContext).Scopes` |
| Add delegated scope | `Update-MgOauth2PermissionGrant -OAuth2PermissionGrantId <id> -Scope '<existing> User.Read.All'` |
| Add app permission | `New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId <sp> -PrincipalId <sp> -ResourceId <graphSp> -AppRoleId <id>` |
| Who called it (KQL) | `MicrosoftGraphActivityLogs \| where RequestUri has "/licenseDetails" and (Scopes has "User.ReadBasic.All" or Roles has "User.ReadBasic.All")` |
| Default user permissions (delegated failures) | `(Get-MgPolicyAuthorizationPolicy).DefaultUserRolePermissions` |

---
## Source Confidence

| Claim | Source | Confidence |
|---|---|---|
| Fix covers delegated **and** app-only; mid → late Sept 2026 worldwide; replacement guidance | MC1470871 full text (mc.merill.net archive, published 2026-09-11) | High (primary) |
| Failures show up as "permission-related errors" | MC1470871 | High |
| Endpoint pages list different least-privileged permissions | Our Cloud Network (12 Sep 2026), Tenant Wizards (14 Sep 2026) | Medium. Recheck the Learn pages, which may since have been updated. |
| `licenseDetails` doesn't support application permissions | Learn endpoint page as reported by Our Cloud Network | Medium. Test it (Playbook 3). |
| `$expand=appRoleAssignments` fails the whole request | Reasoned from Graph authorization behaviour, not documented for this change | Low. Test your query. |
| `assignedLicenses` property readable with `User.Read.All` | Standard Graph user property behaviour | High. It's not named in MC1470871, so it isn't covered by the fix's scope statement. |

---
## 🎓 Learning Pointers

- **Every Graph permission has two identities.** `User.ReadBasic.All` is both an `oauth2PermissionScope` (delegated) and an `appRole` (application), with different GUIDs and different consent objects. The first version of this repo's audit only checked delegated grants and would have missed every daemon. Always inventory both catalogues. [Microsoft Graph permissions overview](https://learn.microsoft.com/en-us/graph/permissions-overview)
- **Graph activity logs turn "we think this app might use it" into proof.** Consent grants show what an app *may* do. `MicrosoftGraphActivityLogs` shows what it *did*, including the `Scopes`/`Roles` on the token and the response code. If the diagnostic setting isn't on, turn it on before the next change like this. [Access Microsoft Graph activity logs](https://learn.microsoft.com/en-us/graph/microsoft-graph-activity-logs-overview)
- **Authorization-rule fixes happen in a layer you can't see.** Nothing in your tenant changes: no grant, no audit log entry, no policy. Change-advisory reviews built on "what did we change?" can't catch these. Subscribe to Message Center items tagged *Admin impact* for Microsoft Entra, or use the [Message Center archive RSS](https://mc.merill.net/rss.xml).
- **When the MC and the endpoint docs disagree, test instead of choosing one.** Here, MC1470871 and the endpoint permission tables give different least-privileged answers. Use the narrowest candidate and a real test call, and escalate to broader permissions one step at a time. [Our Cloud Network analysis](https://ourcloudnetwork.com/microsoft-closes-a-data-access-gap-for-graph-api-permission/)
- **Swallowed errors become wrong data.** A `try { } catch { }` around `Get-MgUserLicenseDetail` turns a 403 into "user is unlicensed". Review report scripts for silent catch blocks, and use `-ErrorAction Stop` with explicit handling. The same pattern hides failures in `$batch` sub-responses (`GraphAPI-BatchOperations-A.md`).
- Related in this repo: [ReadBasicAllScopeChange-B.md](ReadBasicAllScopeChange-B.md), `EntraID/Scripts/Get-ReadBasicAllAppOnlyExposure.ps1`, `EntraID/Scripts/Get-ReadBasicAllUsageAudit.ps1` (delegated only), [GraphPowerShellSDK-A.md](GraphPowerShellSDK-A.md).
