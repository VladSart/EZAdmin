# Power Automate — SharePoint Site Provisioning Hotfix (Mode B: Ops)

> Flow creating SharePoint sites is broken. Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage (60 sec)](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis Flow](#diagnosis--validation-flow)
- [Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

```
1. Open Power Automate → My flows (or the environment where the flow lives)
2. Find the flow → Click on the last failed run
3. Expand each step to find the first RED step
4. Note: the exact error message and which action failed
5. Note: which connection the failed action is using
```

**Then check:**

```powershell
# Is the SharePoint site creation working at all via PowerShell?
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
Get-SPOSite -Limit 5   # Confirms SPO admin connection works

# Can Graph API reach SharePoint?
# Run this to test if the service principal / app has Sites.FullControl
$token = (Get-MsalToken -ClientId <appId> -TenantId <tenantId> -Scopes "https://graph.microsoft.com/.default").AccessToken
Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites" -Headers @{Authorization="Bearer $token"} -Method Get
```

**Interpret the first red step:**
| Error | Go to |
|-------|-------|
| `Invalid connection` / `Connection requires attention` | [Fix 1 — Connection expired](#fix-1--connection-expired-or-broken) |
| `403 Forbidden` | [Fix 2 — Permissions](#fix-2--403-on-site-creation) |
| `429 Too Many Requests` | [Fix 3 — Throttling](#fix-3--throttling-429) |
| `The site already exists` | [Fix 4 — Idempotency](#fix-4--site-already-exists-error) |
| `Requested operation is part of an experimental feature` | Premium connector, wrong licence |
| Flow runs but site never appears | [Fix 5 — Async timing](#fix-5--flow-succeeds-but-site-not-there) |

---

## Dependency Cascade

<details><summary>What must be true for site provisioning to work</summary>

```
[Flow trigger fires]
    → Connection valid + token not expired
    → Account/Service principal has SharePoint Admin or Sites.FullControl.All
    → Tenant-level site creation not blocked (SharePoint admin policy)
    → URL doesn't already exist
    → Licence sufficient for actions used (HTTP = Premium)
    → Flow not suspended due to quota/DLP violation
    → [SharePoint site creation is async — site may take 60–90 seconds to be ready]
    → Post-creation actions (apply template, set permissions) need delay/retry
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Identify the broken action**

In the flow run history, expand each step. The first red one is your break point. Everything else is downstream noise.

**Step 2 — Check the connection**
```
Power Automate → Data → Connections
Find the connection used by the failed action
Check: Last used, Status (should not show error triangle)
Click the connection → Test it
```

**Step 3 — Check who owns the connection**

```
If connection is delegated (uses a user account):
  - Is that user account still licensed?
  - Has their password/MFA changed?
  - Was the account deleted or disabled?

If connection uses a Service Principal:
  - Has the client secret expired?
  - Were API permissions removed?
```

**Step 4 — Check SharePoint admin settings**
```powershell
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com

# Is self-service site creation disabled? (breaks non-admin flows)
Get-SPOTenant | Select DisableAppViews, SharingCapability, SelfServiceSiteCreationDisabled

# Check if site creation is restricted to admins only
Get-SPOSiteCreationPolicy
```

**Step 5 — Check for DLP policy blocking**
```
Power Automate Admin Center → Data Policies
Check which DLP policies apply to this environment
SharePoint connector should be in "Business" tier
HTTP connector — if used, must be in same tier as SharePoint
```

---

## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — Connection expired or broken</summary>

**Symptoms:** "Invalid connection", "Connection requires attention", 401 errors

```
In Power Automate:
1. Go to Data → Connections
2. Find the broken connection (has error icon)
3. Click → Delete
4. Re-create the connection with fresh OAuth consent
5. Go back to the flow → Edit
6. Update the broken action to use the new connection
7. Save → Test the flow
```

If using a service account / shared connection:
- Ensure the account has MFA excluded or uses a service principal instead
- Shared connections break when the owner account's password changes
- **Recommended:** Migrate to service principal connections for production flows

</details>

<details id="fix-2"><summary>Fix 2 — 403 on site creation</summary>

**Symptom:** Flow fails on "Send an HTTP request to SharePoint" or "Create site" action with 403

```powershell
# Check if the connection account is a SharePoint Admin
Connect-ExchangeOnline
Get-MgUser -UserId <connectionAccount> | Select-Object UserPrincipalName

Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
Get-SPOUser -Site https://<tenant>-admin.sharepoint.com -LoginName <connectionAccount>

# If not admin, add them
Set-SPOUser -Site https://<tenant>-admin.sharepoint.com `
  -LoginName <connectionAccount> -IsSiteCollectionAdmin $true
```

If using Graph API (HTTP action):
```powershell
# Check app permissions in Entra ID
# Required for site creation: Sites.FullControl.All (Application permission)
# Check via Entra portal: App registrations → your app → API permissions
# If missing, add and Grant admin consent
```

</details>

<details id="fix-3"><summary>Fix 3 — Throttling (429)</summary>

**Symptom:** 429 Too Many Requests, especially in loops

Power Automate has built-in retry on 429, but it may not be configured:

```
In the flow action that's throttling:
1. Click "..." on the action → Settings
2. Enable "Retry Policy" → Type: Fixed
3. Count: 4, Interval: PT30S (30 seconds)
4. Save
```

If running bulk operations (creating 50+ sites):
- Add a "Delay" action (30–60 seconds) between iterations in your Apply to Each
- Split large batches across multiple flow runs
- Consider running during off-peak hours

</details>

<details id="fix-4"><summary>Fix 4 — "Site already exists" error</summary>

Flow must check before creating:

```
Add before site creation action:
1. "Send HTTP request to SharePoint" → GET /sites/<siteUrl>
2. Add condition: if status code = 200 → skip creation
3. Handle gracefully or update existing site instead
```

PowerShell to check:
```powershell
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com
$existing = Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" -ErrorAction SilentlyContinue
if ($existing) { Write-Host "Site exists: $($existing.Url)" }
```

</details>

<details id="fix-5"><summary>Fix 5 — Flow succeeds but site not there</summary>

**Root cause:** SharePoint site creation is **asynchronous**. The API returns 202 Accepted, not 200 OK. The site is being created in the background. Flow moves on too fast and subsequent actions fail because the site doesn't exist yet.

**Fix:** Add a loop that polls until the site is ready:

```
Action: Do Until
  Condition: Site exists = true
  Limit: 10 iterations, 2 minute timeout
  Inside loop:
    - "Send HTTP request to SharePoint" → GET /sites/<newSiteUrl>
    - If 404 → Delay 15 seconds → loop again
    - If 200 → set variable SiteReady = true → exit loop
Then: continue with post-creation steps
```

</details>

---

## Escalation Evidence

```
Power Automate Site Provisioning — Evidence Pack
================================================
Flow name:               
Environment:             
Trigger:                 
First failing action:    [exact name]
Error message:           [full text from run history]
Connection type:         [delegated user / service principal]
Connection account:      [UPN or app ID — not the password]
Licence on account:      [E3/E5/Premium]
Site URL being created:  
Admin rights confirmed:  [Yes/No]
DLP policies checked:    [Yes/No — any restrictions found?]
Works in test env:       [Yes/No]
Recent changes:          [password change, new DLP policy, licence change]
```

---

## 🎓 Learning Pointers

- **SharePoint provisioning is async** — this trips up almost everyone the first time. The API returns success before the site exists. The retry/poll pattern is the correct architecture for any post-creation action. [MS Docs: SharePoint site creation async](https://learn.microsoft.com/en-us/sharepoint/dev/apis/site-creation-rest)
- **Service principals vs delegated connections** — delegated connections (using a named user account) break when passwords rotate or MFA triggers. For production automation, use a registered app with application permissions and a client secret/certificate. [Register an app for Power Automate](https://learn.microsoft.com/en-us/power-automate/service-principal-support)
- **HTTP action = Premium** — the HTTP connector is what enables direct Graph API calls in flows. It requires Power Automate Premium (or per-flow). Know which actions are standard vs premium before designing a flow for a client. [Connector reference: Standard vs Premium](https://learn.microsoft.com/en-us/connectors/connector-reference/)
- **SharePoint throttling model** — SharePoint Online uses a "retry-after" header in 429 responses. Understanding this changes how you design bulk operations. [SP throttling guidance](https://learn.microsoft.com/en-us/sharepoint/dev/general-development/how-to-avoid-getting-throttled-or-blocked-in-sharepoint-online)
- **r/PowerAutomate on Reddit** — very active community. Searching "SharePoint site provisioning async" and "connection requires attention service principal" will surface real patterns you'll encounter repeatedly.
