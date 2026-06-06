# Power Automate Connector Authentication — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the OAuth 2.0 architecture behind Power Automate connections, why they break, and how to fix them durably.

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
- Power Automate connections and connectors (standard and premium)
- OAuth 2.0 / API key / basic auth connection authentication failures
- Service principal (SPN) connections for automation
- Conditional Access policy conflicts blocking connector auth
- Connection sharing and co-ownership models
- Microsoft 365 first-party connectors (SharePoint, Exchange, Teams, Dataverse)
- Third-party connectors (Salesforce, ServiceNow, etc.) — auth pattern focus only

**Out of scope:**
- Custom connector development and AAD app registration (separate topic)
- Power Apps connection issues (partially overlapping, different UX)
- On-premises data gateway connectivity issues
- DLP policy enforcement (covered in a separate runbook)

**Assumptions:**
- Environment is Power Platform with Microsoft 365 licence or Power Automate per-user/per-flow plan
- Admin has access to Power Platform Admin Center (`admin.powerplatform.microsoft.com`)
- Analyst understands basic OAuth 2.0 concepts (authorization code flow, refresh tokens)

---

## How It Works

<details><summary>Full architecture</summary>

### The Connection Object

A **connection** in Power Automate is a stored credential object that lives in a **Power Platform environment** and maps to a specific connector. When a flow uses a SharePoint connector action, it references a connection object — not raw credentials. The connection holds:
- The connector identity (which service)
- The authentication method (OAuth, API key, Basic, Windows)
- The encrypted credential/token payload
- The **owner** (the user who created the connection)

```
Power Automate Flow
        │
        └── Action: "Get items from SharePoint"
                    │
                    └── references → Connection Object (id: "shared_sharepointonline_xxxxx")
                                              │
                                              ├── Connector: SharePoint Online
                                              ├── Auth type: OAuth 2.0
                                              ├── Owner: user@contoso.com
                                              └── Token payload (encrypted in Azure)
                                                        │
                                                        ▼
                                              Azure Key Vault (managed by Microsoft)
                                                        │
                                                        └── Access Token (short-lived, 1h)
                                                            Refresh Token (long-lived, 90d rolling)
```

### OAuth 2.0 Token Lifecycle

Power Automate uses **Authorization Code Flow** for most Microsoft connectors:

1. **Initial auth:** User clicks "Sign in" in Power Automate → redirected to Azure AD for consent → returns with an authorization code → Power Platform exchanges it for an **access token** (1h) + **refresh token** (90 days, rolling)
2. **Token refresh:** Power Platform silently uses the refresh token to get new access tokens before each flow run. The refresh token's 90-day clock resets every time it's used.
3. **Token expiry:** If the refresh token isn't used for 90 days (e.g. flow disabled, user on leave), it expires. **This is the #1 cause of "Connection expired" errors.**
4. **Revocation:** Refresh tokens are revoked when: the user's password changes, MFA is reconfigured, the user is disabled, or an admin revokes all refresh tokens for the user.

```
Time 0:     User authenticates → Access Token (1h) + Refresh Token (90d)
Time 1h:    Access Token expires → Power Platform uses Refresh Token → New Access Token (1h)
Time 89d:   Refresh Token still valid (rolling) — new refresh token issued each use
Time 90d+0: Refresh Token NOT used for 90 days → EXPIRES → connection broken
OR
Event:      User password changed → Refresh Token REVOKED immediately → connection broken
OR
Event:      Admin runs "Revoke-AzADUserToken" → all refresh tokens revoked → broken
```

### Conditional Access Intersection

Conditional Access policies evaluate at **token issuance time** (initial auth) AND optionally at **Continuous Access Evaluation (CAE)** events. A CA policy that requires:
- **MFA** — satisfied once at initial auth; the refresh token carries the MFA claim (amr=mfa)
- **Compliant device** — evaluated at initial auth; if the token is created on a non-compliant device, it may not carry the device compliance claim, causing future re-auth to fail from the service context
- **Location/IP** — evaluated at initial auth; Power Platform service IPs must be excluded or the token issued from within the allowed range

The key point: **Power Platform runs flows from its own service IP range, not from the user's machine.** Conditional Access policies that enforce IP location may break connections when the flow actually executes, even if the initial auth from the user's PC succeeded.

### Service Principal Connections

For production flows, the preferred pattern is:

```
App Registration (Entra ID)
        │
        ├── Client ID + Client Secret (or Certificate)
        └── API Permissions: SharePoint (Sites.ReadWrite.All), etc.
                  │
                  ▼
Power Automate Custom Connector or direct HTTP connector
        │
        └── Uses Client Credentials Flow (OAuth 2.0)
                  └── No user context → no refresh token expiry problem
                      No MFA requirement → no CA policy conflict
                      Token auto-refreshed by the connector every call
```

Service principal connections don't expire (unless the client secret expires or the SPN is disabled). This is the **production-grade approach** for any flow that needs reliability beyond 90 days.

</details>

---

## Dependency Stack

```
Power Automate Flow
        │
        ▼
Connection Object (per-environment, per-user)
        │
        ├── Connector definition (standard / custom)
        │
        ├── Azure AD / Entra ID
        │         ├── User account: enabled, licensed, not locked
        │         ├── App registration (for the connector): not expired, correct permissions
        │         ├── Conditional Access: policy allows Power Platform service IPs
        │         └── Refresh token: not expired, not revoked
        │
        ├── Power Platform environment
        │         ├── Environment health (not suspended/deleted)
        │         └── DLP policy: connector not blocked
        │
        └── Target service (SharePoint, Exchange, etc.)
                  ├── Service health: not degraded
                  ├── Tenant permissions: user has rights to the resource
                  └── For SharePoint: site permissions, not just connector auth
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| `AADSTS50173: The provided grant has expired` | Refresh token expired (90d no use) | When was the flow last run? User password changed? |
| `AADSTS70011: Invalid scope` | Connector permissions changed or app registration misconfigured | Check app registration permissions in Entra ID |
| `AADSTS50076: MFA required` | CA policy requiring MFA not satisfied from Power Platform service IP | Check CA policy; exclude Power Platform service tags |
| `AADSTS53003: Access blocked by CA policy` | Conditional Access blocking the token refresh from Power Platform IPs | CA policy evaluation; check location/device conditions |
| `Connection is invalid or doesn't exist` | Connection deleted, owner left the org, or environment changed | Check connection owner's account status; re-create |
| `The caller does not have permission to invoke this action` | Service permissions (SharePoint, etc.) changed, not connector auth | Verify user's permissions on the target resource |
| `401 Unauthorized` from target service | Token is valid but user has no access to the specific resource | Check SharePoint site permissions, mailbox delegation, etc. |
| `Connection owner account disabled` | User who created the connection was offboarded | Transfer connection to a service account / SPN |
| `Token revoked after password reset` | User changed password or MFA device → all tokens revoked | User must re-authenticate the connection |
| Flow runs fine in test but fails in production | Runs as different user context in different environments | Check connection references — flow may use different connections per environment |

---

## Validation Steps

**1. Check connection status in Power Automate**
- Navigate to: [make.powerautomate.com](https://make.powerautomate.com) → **Data → Connections**
- Look for connections with a red ⚠️ or "Error" badge
- Click the connection → "Edit" to see the detailed error

```powershell
# Via Power Platform CLI (pac):
pac auth create --environment <envId>
pac connection list --environment <envId>
# Lists all connections with status
```

**2. Verify connection owner's account health**
```powershell
# Check if the connection owner's Entra account is active:
Connect-MgGraph -Scopes "User.Read.All"
Get-MgUser -UserId <ownerUPN> |
  Select-Object DisplayName, AccountEnabled, UserPrincipalName,
    @{N="LastSignIn"; E={ $_.SignInActivity.LastSignInDateTime }}
```

**3. Check for CA policy conflicts**
```powershell
# Review sign-in logs for the connection owner filtered to Power Platform service:
# Entra ID portal → Sign-in logs → filter:
# Application: "Microsoft Power Automate" OR "Power Platform"
# Status: Failure
# Look for "Conditional Access" in the failure reason
```

**4. Test the connection manually**
- In Power Automate, go to **Data → Connections → [connection] → Test**
- A successful test confirms the token is valid now (doesn't guarantee future runs)

**5. Verify DLP policy isn't blocking the connector**
```powershell
# Via Power Platform Admin Center:
# Policies → Data policies → [policy] → Connectors
# The connector must be in "Business data only" or "Allow" group, not "Blocked"

# Via CLI:
pac dlp list --environment <envId>
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Identify the Failing Connection

1. Check the flow run history for the specific error:
   - **Flow → Run history → failed run → expand the failing action → error details**
   - The error code (AADSTS-prefixed) tells you the root cause

2. Go to **Data → Connections** and identify any connections with error status

3. Correlate the connection to the flow:
   - **Flow → Edit → [action] → ... → My connections** — which connection is selected?

### Phase 2 — Diagnose the Auth Failure Type

**Expired refresh token:**
- Error: `AADSTS50173`, `AADSTS70008`, or `The refresh token has expired`
- Fix: The connection owner must re-authenticate (Fix 1)

**Revoked token (password change, MFA reset):**
- Error: `AADSTS50173` immediately after a recent password change
- Check: When did the user last change their password?
- Fix: Re-authenticate (Fix 1), then consider service account (Fix 3)

**Conditional Access blocking:**
- Error: `AADSTS53003`, `AADSTS50076`
- Fix: Update CA policy to exclude Power Platform IPs or use SPN (Fix 2, Fix 3)

**Connection owner departed:**
- Symptom: Connection shows error; owner account disabled
- Fix: Re-create connection under active account or SPN (Fix 3, Fix 4)

### Phase 3 — Determine Permanent Fix

- **Individual user flow, non-critical:** re-auth by the user (Fix 1)
- **Shared/department flow, runs on a schedule:** migrate to service account or SPN (Fix 3)
- **CA policy conflict:** update CA policy or use SPN (Fix 2, Fix 3)
- **Owner departed:** transfer flow ownership and re-create connections (Fix 4)

---

## Remediation Playbooks

<details><summary>Fix 1 — Re-authenticate an expired connection</summary>

**Fastest fix** — the connection owner must do this.

```powershell
# Cannot be done via PowerShell — must be done in the browser by the connection owner

# Steps:
# 1. Go to make.powerautomate.com
# 2. Data → Connections
# 3. Find the broken connection (red icon)
# 4. Click "..." → Edit
# 5. Click "Sign in" / "Reconnect" and complete the auth flow
# 6. Test the connection after re-auth

# After re-auth, verify the flow works:
# Flows → [flow name] → Run → check run history
```

**If the user can't re-auth themselves** (e.g. they're on leave):
- An admin can't re-auth on their behalf — the token must be tied to the actual user
- Options: wait for user return, create a service account connection, or use SPN (Fix 3)

**Rollback:** N/A — re-authentication is non-destructive.

</details>

<details><summary>Fix 2 — Fix Conditional Access blocking Power Platform</summary>

**Root cause:** CA policy enforcing IP location, compliant device, or session controls blocks the token refresh that Power Platform service performs from Microsoft datacenters.

```powershell
# Step 1: Identify which CA policy is blocking
# Entra ID → Sign-in logs → filter by:
# - Application: "Microsoft Power Automate"
# - Status: Failure
# - Look at "Conditional Access" tab in the sign-in event detail
# Note the Policy Name and failure reason

# Step 2: Determine the right exemption approach

# Option A — Exclude Power Platform service principal from the CA policy
# (Best for IP-based policies)
# Entra ID → Security → Conditional Access → [policy] → Users → Exclude
# Add the "Power Platform" or "Microsoft Power Automate" service principal

# Option B — Exclude Power Platform from named location requirements
# Add Microsoft Power Platform IP ranges to the "trusted locations" in Entra ID
# IP ranges: https://learn.microsoft.com/en-us/connectors/common/outbound-ip-addresses

# Option C — Create a CA policy exclusion for service accounts used for connectors
# Exclude service accounts from CA policies that require compliant devices
# Apply MFA exemption only to these accounts via named location (corpnet only)

# Step 3: Verify the fix
# Trigger a flow run → check run history → should succeed now
# Check Entra sign-in logs — no longer showing CA failure for Power Automate
```

**Rollback:** Revert CA policy changes. Document the change in your CA policy change log.

</details>

<details><summary>Fix 3 — Migrate connection to a service principal (SPN)</summary>

**Best practice for production flows** — no refresh token expiry, no user dependency.

```powershell
# Step 1: Create an App Registration in Entra ID
Connect-MgGraph -Scopes "Application.ReadWrite.All"

$app = New-MgApplication -DisplayName "PowerAutomate-ServiceAccount" `
  -SignInAudience "AzureADMyOrg"

# Step 2: Create a client secret (set expiry to max 24 months)
$secret = Add-MgApplicationPassword -ApplicationId $app.Id `
  -PasswordCredential @{
    DisplayName = "PowerAutomate-Secret"
    EndDateTime = (Get-Date).AddMonths(24)
  }

Write-Host "Client ID: $($app.AppId)"
Write-Host "Client Secret: $($secret.SecretText)"  # Save this immediately — shown once

# Step 3: Grant API permissions (example: SharePoint)
# Entra ID portal → App registrations → [app] → API permissions
# Add: SharePoint → Application permissions → Sites.ReadWrite.All
# Grant admin consent

# Step 4: Create the connection in Power Automate
# In make.powerautomate.com → Data → Connections → New connection
# Select the connector → choose "Service Principal" auth (if available)
# Enter: Tenant ID, Client ID, Client Secret

# Note: Not all connectors support SPN auth
# SharePoint: Yes | Exchange/Outlook: Yes (via Graph) | Teams: Yes | Third-party: Varies

# Step 5: Update flows to use the new connection
# Edit each flow → change connection references to the new SPN connection
# Test thoroughly in a non-prod environment first

# Step 6: Track secret expiry — calendar reminder at 22 months
Write-Host "Secret expires: $((Get-Date).AddMonths(24).ToString('yyyy-MM-dd'))"
```

**Rollback:** Switch flows back to the original user connection. SPN connections can coexist with user connections during transition.

</details>

<details><summary>Fix 4 — Transfer connection ownership when creator has left</summary>

**Cause:** The user who created the connection (and thus owns the OAuth tokens) has left the organisation. Their account is disabled → all their tokens are revoked → all connections they owned are broken.

```powershell
# Option A — Re-create the connection under a new owner
# This is the most reliable fix
# 1. New owner (or service account) goes to Data → Connections
# 2. Creates a new connection for the same connector
# 3. Signs in with their own credentials
# 4. In each affected flow: edit → change each action's connection to the new connection
# 5. Save and test

# Option B — Use Power Platform Admin Center to see all connections
# admin.powerplatform.microsoft.com → Environments → [env] → Resources → Connections
# Filter by owner = <departed user>
# Note all affected flows

# Option C — PowerShell audit of affected flows
# Install Power Platform CLI: https://aka.ms/PowerAppsCLI
pac auth create --environment <envUrl>
pac connection list --environment <envId> | Where-Object { $_ -match "<departedUserUPN>" }

# Step 2: After identifying affected flows, re-create connections and update all flows
# Document which flows were affected for change management

# Step 3: Consider setting up a service account going forward
# A shared mailbox or dedicated service account (no MFA) used only for PA connections
# Exempt from CA policies that don't apply to service accounts
```

**Prevention:** Establish a process to audit Power Automate connections when offboarding users. The offboarding checklist should include: "Check Power Automate Admin Center for connections owned by this user."

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Power Automate connection evidence for escalation
.NOTES     Requires Power Platform admin access and Graph permissions
           Outputs a summary of broken connections and affected flows
#>

# Requires: Microsoft.PowerApps.Administration.PowerShell module
Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Force -Scope CurrentUser
Import-Module Microsoft.PowerApps.Administration.PowerShell

$OutputPath = "$env:TEMP\PA-ConnAuth-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# 1. Add PAC auth — requires interactive auth
Add-PowerAppsAccount

# 2. Get all connections in the environment
$environmentName = "<environment-GUID>"
$connections = Get-AdminPowerAppConnection -EnvironmentName $environmentName
$connections | Export-Csv "$OutputPath\01-AllConnections.csv" -NoTypeInformation

# 3. Filter for broken connections
$brokenConnections = $connections | Where-Object { $_.Statuses.status -ne "Connected" }
$brokenConnections | Export-Csv "$OutputPath\02-BrokenConnections.csv" -NoTypeInformation
Write-Host "Broken connections found: $($brokenConnections.Count)"

# 4. Get all flows referencing broken connections
$allFlows = Get-AdminFlow -EnvironmentName $environmentName
$affectedFlows = @()
foreach ($conn in $brokenConnections) {
  $flows = $allFlows | Where-Object {
    $_.Internal.properties.connectionReferences -ne $null -and
    ($_.Internal.properties.connectionReferences | ConvertTo-Json) -match $conn.ConnectionName
  }
  $affectedFlows += $flows | Select-Object FlowName, DisplayName,
    @{N="BrokenConnection"; E={ $conn.DisplayName }},
    @{N="ConnectionOwner"; E={ $conn.CreatedBy.email }}
}
$affectedFlows | Export-Csv "$OutputPath\03-AffectedFlows.csv" -NoTypeInformation

# 5. Get DLP policies for context
Get-DlpPolicy | Select-Object PolicyName, DisplayName, Type |
  Export-Csv "$OutputPath\04-DLPPolicies.csv" -NoTypeInformation

# 6. Summary report
$summary = @"
Power Automate Connection Auth Evidence
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Environment: $environmentName

Total connections: $($connections.Count)
Broken connections: $($brokenConnections.Count)
Affected flows: $($affectedFlows.Count)

Broken connections detail:
$($brokenConnections | ForEach-Object { "  - $($_.DisplayName) | Owner: $($_.CreatedBy.email) | Connector: $($_.ConnectorName)" } | Out-String)
"@
$summary | Out-File "$OutputPath\00-Summary.txt"
Write-Host $summary

Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath.zip" -Force
Write-Host "Evidence collected: $OutputPath.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|--------------------|
| View all connections (user) | make.powerautomate.com → Data → Connections |
| View all connections (admin) | admin.powerplatform.microsoft.com → Environments → Resources → Connections |
| Test a connection | Connections → connection → "..." → Test connection |
| Re-authenticate a connection | Connections → connection → Edit → Sign in |
| List connections via CLI | `pac connection list --environment <envId>` |
| Check connection owner account | `Get-MgUser -UserId <UPN>` |
| List all flows in environment | `Get-AdminFlow -EnvironmentName <envGuid>` |
| List broken connections (PS) | `Get-AdminPowerAppConnection \| Where-Object { $_.Statuses.status -ne "Connected" }` |
| Check CA sign-in failures | Entra ID → Sign-in logs → filter Application = "Power Automate" + Status = Failure |
| View DLP policies | `Get-DlpPolicy` |
| Power Platform IP ranges | https://learn.microsoft.com/en-us/connectors/common/outbound-ip-addresses |
| Service principal for SharePoint | App reg → API permissions → SharePoint → Sites.ReadWrite.All (Application) |
| AADSTS error lookup | https://learn.microsoft.com/en-us/azure/active-directory/develop/reference-aadsts-error-codes |
| Flow connection references | Edit flow → action → "..." → My connections → change connection |

---

## 🎓 Learning Pointers

- **The 90-day refresh token cliff** — Microsoft's Entra ID refresh tokens for interactive (user) flows expire after 90 days of inactivity. This is a Microsoft security policy, not configurable by tenant admins. Any flow that stops running for 90 days (e.g. seasonal workflows, flows paused during a project) will have its connection expire. The solution for critical flows is to either run a test execution monthly, or migrate to a service principal connection which doesn't use refresh tokens. [Token lifetime policies](https://learn.microsoft.com/en-us/azure/active-directory/develop/configurable-token-lifetimes)

- **Connections are environment-scoped** — a connection created in the Production environment is not available in the Dev environment and vice versa. When promoting flows between environments using ALM pipelines, connection references must be remapped in the target environment. This is why flows work in Dev and fail in Prod — they're using different (or missing) connections. [Connection references in ALM](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/create-connection-reference)

- **The "created by" user is baked in at auth time** — when a user creates a SharePoint connection and a flow uses "Get items" via that connection, every SharePoint operation runs as that user, not the flow owner. This has two implications: (1) that user needs SharePoint permissions on every site the flow touches, (2) if that user leaves, the permissions are still needed on the SharePoint side even after you re-auth with a new connection. [Connection ownership and permissions](https://learn.microsoft.com/en-us/power-automate/share-buttons)

- **Conditional Access + Power Platform = location policy headache** — Power Platform runs flows from Microsoft Azure datacenters. If your CA policy enforces "must be on named location (corpnet)," the token refresh that happens inside Azure will fail because Azure datacenters aren't on your named location. The fix is to add Power Platform IP ranges to named locations, or exclude the Power Automate service principal from location-based CA policies. [Power Platform outbound IPs](https://learn.microsoft.com/en-us/connectors/common/outbound-ip-addresses)

- **Service principal connections are the production standard** — any flow that runs on a schedule, processes business-critical data, or is owned by a team (not an individual) should use an SPN connection. SPNs don't have password reset events, don't have refresh token expiry problems, and don't become orphaned when someone leaves. The investment is worth it. [App-only auth in Power Automate](https://learn.microsoft.com/en-us/power-automate/desktop-flows/actions-reference/microsoftazure)

- **Premium connectors require a Power Automate premium licence on the flow owner** — not just the person who created the connection. If a flow using a premium connector (e.g. Dataverse, SQL, HTTP) is run or edited by a user without a premium licence, the flow will fail even if the connection is perfectly healthy. Check licence assignment when auth errors follow a user account change. [Power Automate licensing FAQ](https://learn.microsoft.com/en-us/power-platform/admin/power-automate-licensing/faqs)
