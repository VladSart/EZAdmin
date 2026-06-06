# SharePoint Site Provisioning via Power Automate — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers automated SharePoint Online site provisioning orchestrated through Power Automate using the **Microsoft Graph API** and/or **SharePoint REST API**. It is relevant to:

- Team Sites (`/sites/<name>`) and Communication Sites provisioned via flow
- Hub site association performed post-provisioning
- Permission inheritance and custom role assignment via automation
- Provisioning templates applied using PnP PowerShell or CSOM called from Power Automate child flows or Azure Functions

**Assumes:**
- Tenant has M365 E3/E5 or Business Premium licensing
- Power Automate flows run under a **service account** with SharePoint Admin and Graph permissions, OR use an **app registration** (client credentials) via custom connector
- Engineers have SharePoint Admin or Global Admin for diagnostic purposes
- PnP PowerShell module available: `Install-Module PnP.PowerShell`

---

## How It Works

<details><summary>Full architecture — Site provisioning pipeline</summary>

### Provisioning Pipeline Overview

```
[Trigger]
  │  (HTTP request / SharePoint list / Form / Teams adaptive card)
  ▼
[Power Automate — Main Flow]
  │
  ├─► Validate input (site URL, alias, owner, template type)
  │     └─ "Apply to each" guard — check if site exists via Graph
  │
  ├─► Create site via Graph or SharePoint Admin API
  │     POST https://graph.microsoft.com/v1.0/sites/root/sites
  │     OR
  │     POST /_api/SPSiteManager/create  (Communication sites)
  │     OR
  │     POST https://graph.microsoft.com/v1.0/groups  (M365 Group-connected Team site)
  │
  ├─► Poll for provisioning completion
  │     GET https://graph.microsoft.com/v1.0/sites/<siteId>/... until 200 OK
  │     (Provisioning can take 30s – 3 min. Use Do Until + Delay)
  │
  ├─► Apply site template / PnP template (optional)
  │     ► Child flow calls Azure Function → PnP.PowerShell Invoke-PnPSiteTemplate
  │
  ├─► Set permissions
  │     ► POST /sites/<siteId>/groups/<groupId>/members  (Graph)
  │     ► Add owners, members, visitors
  │
  ├─► Associate to Hub Site (if applicable)
  │     POST /sites/<siteId>/registerHubSite  OR
  │     Register-PnPHubSite / Set-PnPHubSiteAssociation
  │
  └─► Notify requester (Teams adaptive card / email)
```

### Authentication Models

| Model | How it works | Best for |
|-------|-------------|----------|
| **Service account** | Flow connections use a shared account with SharePoint Admin | Simple setups, quick to implement |
| **App registration (cert)** | Custom connector calls Graph as app; no user context | Production, auditable, avoids MFA breakage |
| **Managed Identity** | Logic Apps / Azure Function uses system-assigned identity | Zero-secret approach for Azure-hosted logic |

### Site Types and Their APIs

| Site Type | Primary API | Graph endpoint |
|-----------|------------|----------------|
| Team site (M365 Group) | Graph Groups | `POST /v1.0/groups` |
| Communication site | SharePoint REST `SPSiteManager` | `POST /_api/SPSiteManager/create` |
| Team site (no group) | SharePoint REST | `POST /_api/SPSiteManager/create` with `WebTemplate: "STS#3"` |
| Hub site | Graph + SharePoint Admin | Create site, then `POST /sites/{id}/registerHubSite` |

</details>

---

## Dependency Stack

```
[User / Business Request]
        │
[Power Automate Flow]
        │
        ├── [Microsoft Graph API]
        │       └── Entra ID App Registration (permissions: Sites.ReadWrite.All, Group.ReadWrite.All)
        │               └── Tenant consent granted by Global Admin
        │
        ├── [SharePoint REST API] /_api/SPSiteManager/create
        │       └── Requires SharePoint Admin role on service account
        │
        ├── [Exchange Online] — M365 Group creation also provisions a mailbox
        │       └── Group mailbox provisioning delay (up to 5 min)
        │
        ├── [Azure Active Directory] — Group object backing the Team site
        │       └── Group provisioning policy (naming policy, expiration policy)
        │
        └── [PnP PowerShell / Azure Function] — Template application
                └── Azure Function App (optional)
                        └── Managed Identity or cert-based auth
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Flow errors: `403 Forbidden` on site creation | Service account lacks SharePoint Admin role, or app missing `Sites.FullControl.All` | Check account roles in SharePoint Admin Center; check app permissions in Entra |
| Site URL conflict — `409 Conflict` | Site alias already exists (deleted sites enter a 30-day recycle bin holding the URL) | Check Deleted Sites in SharePoint Admin Center |
| Flow creates M365 Group but no SharePoint site appears | SharePoint provisioning is async — polling loop too short or missing | Add Do Until + Delay(30s) polling the site URL |
| Provisioning succeeds but owner not set | Owner assignment runs before site is fully ready | Add a 60s delay or poll-then-assign pattern |
| Hub site association fails | Hub site not registered yet, or site doesn't exist yet | Verify hub site exists: `Get-PnPHubSite` |
| PnP template application fails | Template uses features not enabled on tenant, or wrong site type | Review template XML for missing features; test manually first |
| `InvalidClientId` on custom connector | App registration Client ID wrong, or connector not updated after secret rotation | Re-enter client credentials in custom connector config |
| Flow triggers repeatedly / infinite loop | SharePoint list trigger fires on flow's own updates | Add "Modified By = <service account>" filter exclusion |
| Group naming policy blocks creation | Tenant has Entra naming policy with required prefix/suffix | Pre-append required prefix in flow before creating group |

---

## Validation Steps

**1. Verify service account / app permissions**
```powershell
# Check SharePoint Admin role for service account
Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
$role = Get-MgDirectoryRole | Where-Object { $_.DisplayName -eq "SharePoint Administrator" }
Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id | Select-Object AdditionalProperties
```
Expected: Service account UPN or app object appears in results.

**2. Confirm site provisioning completed**
```powershell
Connect-PnPOnline -Url "https://<tenant>-admin.sharepoint.com" -Interactive
Get-PnPTenantSite -Url "https://<tenant>.sharepoint.com/sites/<siteName>"
```
Expected: Returns site object with `Status: Active`. Bad: `Status: Creating` (still provisioning) or no result (failed).

**3. Verify M365 Group backing the site**
```powershell
Connect-MgGraph -Scopes "Group.Read.All"
Get-MgGroup -Filter "mailNickname eq '<alias>'" | Select-Object DisplayName, Id, CreatedDateTime
```
Expected: Single group returned with correct alias. Bad: No result or multiple results.

**4. Check hub site association**
```powershell
Connect-PnPOnline -Url "https://<tenant>-admin.sharepoint.com" -Interactive
Get-PnPHubSiteChild -Identity "https://<tenant>.sharepoint.com/sites/<hubSiteName>"
```
Expected: New site appears in hub site's children list.

**5. Check flow run history for errors**
- In Power Automate portal → My flows → `<flow name>` → Run history
- Look for failed actions, expand to see raw HTTP response body
- Common: `Status: 429` (throttle), `403` (permission), `409` (conflict)

---

## Troubleshooting Steps (by phase)

### Phase 1 — Pre-flight (before flow runs)

1. Confirm the service account has no MFA prompt that would break unattended flow connections
2. Check group naming policy: `Get-MgDirectorySettingTemplate` — look for `Group.Unified`
3. Verify the target URL doesn't already exist (including deleted sites)
4. Ensure app registration has admin consent for all required Graph permissions

### Phase 2 — Site creation request

5. Check the raw HTTP response body in the flow — Graph errors include `error.code` and `error.message`
6. For `409 Conflict`: check SharePoint Admin Center → Deleted Sites — purge if needed
7. For `400 Bad Request`: validate JSON body — alias must be ≤ 64 chars, no spaces, no special chars
8. For `503 Service Unavailable`: Graph is throttled or unhealthy — check [status.office365.com](https://status.office365.com)

### Phase 3 — Post-provisioning (template + permissions)

9. If PnP template fails: test the template manually with `Invoke-PnPSiteTemplate` from your machine first
10. If permission assignment fails: verify site is fully active before assigning; add a `Do Until` loop checking `GET /sites/<id>` returns `200`
11. Hub association: verify hub site URL is correct and hub is registered (`Get-PnPHubSite`)

### Phase 4 — Notification

12. If Teams notification fails: verify the Teams connector is authenticated and the target channel ID is valid
13. If email fails: check if Exchange Online throttling applies (high volume provisioning)

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Site URL conflict (409): purge deleted site</summary>

**Symptom:** Flow returns `409 Conflict` when creating site; URL was used before.

```powershell
# Connect as SharePoint Admin
Connect-PnPOnline -Url "https://<tenant>-admin.sharepoint.com" -Interactive

# List deleted sites to confirm it's there
Get-PnPTenantDeletedSite | Where-Object { $_.Url -like "*<siteName>*" }

# Permanently delete to free the URL
Remove-PnPTenantDeletedSite -Identity "https://<tenant>.sharepoint.com/sites/<siteName>" -Force

# Confirm deletion (may take 1-2 min)
Get-PnPTenantDeletedSite | Where-Object { $_.Url -like "*<siteName>*" }
```

**Rollback:** This is permanent. Ensure you don't need the deleted site's content before running. If data is needed, restore it first: `Restore-PnPTenantDeletedSite`.

</details>

<details>
<summary>Fix 2 — Service account MFA blocking flow</summary>

**Symptom:** Flow runs fail intermittently with `AADSTS50076` (MFA required) or connection expires.

**Steps:**
1. Create a dedicated service account (`svc-provisioning@<tenant>`) with a complex password
2. Exclude it from Conditional Access MFA policies using a named exclusion group
3. Apply a Conditional Access policy that restricts this account to specific trusted IPs only (hybrid server or Azure IP range)
4. Re-authenticate the Power Automate connection under this account
5. Enable "Connection reference" in the flow so all flows share one auditable connection

**Rollback:** Re-add the account to the MFA policy if excluding it creates unacceptable risk. Consider switching to app registration (client credentials) instead.

</details>

<details>
<summary>Fix 3 — Switch to app registration (client credentials)</summary>

**Symptom:** Service account approach is fragile; need zero-user-context, auditable provisioning.

```powershell
# Step 1: Create app registration (do this in Entra portal)
# App permissions needed:
#   Sites.FullControl.All (Application)
#   Group.ReadWrite.All (Application)
#   User.Read.All (Application)
# Grant admin consent in Entra portal

# Step 2: Test Graph call with client credentials
$tenantId    = "<tenantId>"
$clientId    = "<clientId>"
$clientSecret= "<clientSecret>"

$body = @{
    grant_type    = "client_credentials"
    client_id     = $clientId
    client_secret = $clientSecret
    scope         = "https://graph.microsoft.com/.default"
}
$token = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -Body $body
$headers = @{ Authorization = "Bearer $($token.access_token)" }

# Step 3: Test site creation call
$siteBody = @{
    displayName = "Test Site"
    mailNickname = "testsite-$(Get-Date -Format 'yyMMddHHmm')"
    groupTypes = @("Unified")
    mailEnabled = $true
    securityEnabled = $false
    visibility = "Private"
} | ConvertTo-Json

Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups" -Method POST -Headers $headers -Body $siteBody -ContentType "application/json"
```

**Rollback:** If app registration has too broad permissions, scope it down — `Sites.ReadWrite.All` works for most provisioning except PnP template application which needs `Sites.FullControl.All`.

</details>

<details>
<summary>Fix 4 — Polling loop for async provisioning</summary>

**Symptom:** Flow assigns owners/templates before the site is ready, causing 404 errors.

**Implementation in Power Automate:**

```
Do Until:
  Condition: HTTP GET "https://graph.microsoft.com/v1.0/sites/<tenantName>.sharepoint.com:/sites/<alias>"
             returns Status 200
  Delay: 30 seconds
  Limit: 10 iterations (5 minutes max)

After loop exits:
  Condition check: If loop exited on timeout (not success) → send failure notification → terminate

Continue with permission + template steps
```

**PowerShell equivalent for testing:**
```powershell
$siteUrl = "https://<tenant>.sharepoint.com/sites/<alias>"
$maxWait = 300  # seconds
$waited  = 0
do {
    Start-Sleep -Seconds 15
    $waited += 15
    try {
        $site = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$('<tenant>.sharepoint.com:/sites/<alias>')" -Headers $headers
        Write-Host "Site ready: $($site.webUrl)" -ForegroundColor Green
        break
    } catch {
        Write-Host "Waiting... ($waited s)" -ForegroundColor Yellow
    }
} while ($waited -lt $maxWait)
if ($waited -ge $maxWait) { Write-Error "Site provisioning timed out after $maxWait seconds" }
```

</details>

<details>
<summary>Fix 5 — Naming policy conflict blocking group creation</summary>

**Symptom:** `400 Bad Request` with message `Entra ID group naming policy requires prefix/suffix`.

```powershell
# Check current naming policy
Connect-MgGraph -Scopes "Directory.ReadWrite.All"
$settings = Get-MgDirectorySetting | Where-Object { $_.DisplayName -eq "Group.Unified" }
$settings.Values | Where-Object { $_.Name -like "*Naming*" }

# If policy requires prefix "MSP-", update flow to prepend it:
# In flow: Set variable displayName = "MSP-" + triggerBody()?['siteName']
# The mailNickname (alias) is typically not subject to naming policy but displayName is
```

**Rollback:** Do not remove the naming policy without approval — it exists for governance reasons. Instead, adapt the flow to comply.

</details>

---

## Evidence Pack

```powershell
<#
  EZAdmin Evidence Pack — SharePoint Site Provisioning
  Run as SharePoint Admin or Global Admin when escalating provisioning failures
#>

$tenantName = "<tenantName>"
$siteUrl    = "https://$tenantName.sharepoint.com/sites/<siteName>"
$alias      = "<alias>"
$output     = @{}

Connect-MgGraph -Scopes "Sites.Read.All","Group.Read.All","Directory.Read.All" -NoWelcome
Connect-PnPOnline -Url "https://$tenantName-admin.sharepoint.com" -Interactive

# 1. Site status
try {
    $site = Get-PnPTenantSite -Url $siteUrl -ErrorAction Stop
    $output["SiteStatus"]  = $site.Status
    $output["SiteOwner"]   = $site.Owner
    $output["SiteCreated"] = $site.LastContentModifiedDate
} catch {
    $output["SiteStatus"] = "NOT FOUND — $_"
}

# 2. Deleted sites check
$deletedMatch = Get-PnPTenantDeletedSite | Where-Object { $_.Url -eq $siteUrl }
$output["DeletedSiteExists"] = ($null -ne $deletedMatch)

# 3. M365 Group check
try {
    $group = Get-MgGroup -Filter "mailNickname eq '$alias'" -ErrorAction Stop
    $output["GroupId"]      = $group.Id
    $output["GroupDisplay"] = $group.DisplayName
    $output["GroupCreated"] = $group.CreatedDateTime
} catch {
    $output["GroupStatus"] = "NOT FOUND — $_"
}

# 4. Naming policy
$namingSettings = Get-MgDirectorySetting | Where-Object { $_.DisplayName -eq "Group.Unified" }
$output["NamingPolicySetting"] = ($namingSettings.Values | Where-Object { $_.Name -like "*Naming*" }).Value

# 5. Recent flow run errors — manual step
Write-Host "`n[ACTION REQUIRED] Export flow run history from Power Automate portal and attach to ticket`n" -ForegroundColor Yellow

# Export results
$output | Format-Table -AutoSize
$output | ConvertTo-Json | Out-File ".\SPProvisioning-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').json"
Write-Host "Evidence saved to JSON file." -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Get site status | `Get-PnPTenantSite -Url <url>` |
| List deleted sites | `Get-PnPTenantDeletedSite` |
| Restore deleted site | `Restore-PnPTenantDeletedSite -Identity <url>` |
| Permanently delete site | `Remove-PnPTenantDeletedSite -Identity <url> -Force` |
| Get M365 Group by alias | `Get-MgGroup -Filter "mailNickname eq '<alias>'"` |
| Add owner to group | `New-MgGroupOwner -GroupId <id> -DirectoryObjectId <userId>` |
| Apply PnP template | `Invoke-PnPSiteTemplate -Path .\template.xml` |
| Get hub sites | `Get-PnPHubSite` |
| Associate site to hub | `Add-PnPHubSiteAssociation -Site <url> -HubSite <hubUrl>` |
| Check tenant naming policy | `Get-MgDirectorySetting \| Where { $_.DisplayName -eq 'Group.Unified' }` |
| List SharePoint Admins | `Get-MgDirectoryRoleMember -DirectoryRoleId (Get-MgDirectoryRole \| Where { $_.DisplayName -eq 'SharePoint Administrator' }).Id` |
| Get Graph token (app) | `Invoke-RestMethod .../oauth2/v2.0/token -Method POST -Body $body` |
| Check tenant storage | `Get-PnPTenant \| Select StorageQuota, StorageQuotaAllocated` |

---

## 🎓 Learning Pointers

- **Async provisioning is the #1 cause of race conditions.** SharePoint site provisioning via Graph or SPSiteManager is not synchronous — even a `200 OK` on the create call doesn't mean the site is usable. Always implement a polling loop before any post-provisioning steps. MS Docs: [Create a site using SharePoint REST](https://learn.microsoft.com/en-us/sharepoint/dev/sp-add-ins/complete-basic-operations-using-sharepoint-rest-endpoints)

- **App registration vs. service account:** App registrations with `Sites.FullControl.All` are more resilient (no MFA, no password expiry breaking flows) but require tenant admin consent and should be audited regularly. MS Docs: [Use app-only auth with SharePoint](https://learn.microsoft.com/en-us/sharepoint/dev/solution-guidance/security-apponly-azuread)

- **M365 Group provisioning also touches Exchange.** A group-connected Team site creates a group mailbox. If Exchange Online is in a degraded state, group creation can fail or leave an orphaned Entra group without a SharePoint site. Always check `Get-MgGroup` AND `Get-PnPTenantSite` separately. MS Docs: [Microsoft 365 Groups service description](https://learn.microsoft.com/en-us/office365/servicedescriptions/office-365-platform-service-description/office-365-groups)

- **Hub site association has order dependencies.** You can only associate a site to a hub site that is already registered. If your flow creates both the hub and the child in sequence, ensure the hub registration step completes (and polls) before the child association step runs.

- **PnP PowerShell templates are version-sensitive.** Templates exported from one tenant may fail on another if they reference features, content types, or term store IDs that don't exist on the target. Always validate templates with `Test-PnPSiteTemplate` before applying in automation. Community resource: [PnP PowerShell docs](https://pnp.github.io/powershell/)

- **Power Automate throttling on SharePoint triggers** (SharePoint list triggers) is a common cause of duplicate flow runs. Use `ModifiedBy` filter exclusions or a dedicated staging list separate from production data to prevent the flow from triggering on its own updates.
