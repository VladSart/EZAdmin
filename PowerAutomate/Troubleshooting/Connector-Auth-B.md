# Power Automate Connector Authentication — Hotfix Runbook (Mode B: Ops)
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

Run these in the Power Automate portal or Graph Explorer — no PowerShell required at first pass.

**1. Identify which connection is broken**
```
Power Automate portal → Data → Connections
Look for connections with a ⚠️ yellow warning or ❌ red error icon
Note: connection name, connector type, and owner account
```

**2. Check if the flow itself is disabled due to auth failure**
```
Portal → My Flows → [select failing flow] → Run History
Error pattern: "The connection ... is not authorized" → connection needs re-auth
Error pattern: "AADSTS..." codes → Azure AD token issue (see fix table below)
Error pattern: "ApiConnectionWait" → throttled or waiting for delegated auth
```

**3. Check the connection owner's account status**
```powershell
# Run in Exchange Online or Azure AD PowerShell
Get-MgUser -UserId <connection-owner-UPN> | Select-Object DisplayName, AccountEnabled, UserPrincipalName
# If AccountEnabled = False → account disabled, flows using this connection are broken
```

**4. Check if admin consent is missing for the connector**
```powershell
# In Azure Portal: Azure Active Directory → Enterprise Applications
# Search for the connector's app registration name (e.g. "Microsoft Flow Service")
# Check: Users and groups → Consent → Admin consent granted?
Get-MgServicePrincipal -Filter "displayName eq '<ConnectorAppName>'" | Select-Object Id, AppId, ConsentProvidedForTenant
```

**5. Check DLP policy blocking the connector**
```
Power Platform Admin Center → Policies → Data Policies
Check: Is the connector in "Blocked" bucket for the environment?
A connector in the Blocked bucket cannot be used in ANY flow in that environment.
```

**Interpretation:**

| Result | Action |
|--------|--------|
| Connection shows ⚠️ in portal | Re-authenticate — Fix 1 |
| AADSTS50076 / MFA required | MFA prompt needed — Fix 2 |
| AADSTS70011 / invalid scope | Connector permissions changed — Fix 3 |
| Account disabled / deleted | Reassign connection — Fix 4 |
| DLP policy blocking | Escalate to Power Platform admin — Fix 5 |
| Admin consent not granted | Escalate to Azure AD admin — Fix 3 |

---

## Dependency Cascade

<details><summary>What must be true for connector auth to work</summary>

```
[Power Automate Flow runs]
        │
        ▼
[Connection record valid]  ← Stored OAuth token not expired/revoked
        │
        ▼
[OAuth token valid]
  ├─ Not expired (access tokens: 1h, refresh tokens: up to 90 days)
  ├─ User account enabled in Entra ID
  ├─ App registration exists and not deleted
  ├─ Permissions (scopes) still granted — not revoked by admin consent change
  └─ No Conditional Access blocking the token request
        │
        ▼
[Connector not blocked by DLP]  ← Environment-level Data Policy
        │
        ▼
[Target service reachable]  ← SharePoint, Exchange, etc. responding
        │
        ▼
[Flow action executes successfully]
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Reproduce the error**

Navigate to the failing flow's run history. Click the failed run. Expand the failing action. Copy the full error message — it contains the AADSTS error code if auth-related.

Expected (good): No runs failing, connection icons green.
Actual (bad): `"The connection '<name>' used by flow '<flowname>' is broken."` or AADSTS error.

**Step 2 — Identify connection owner**

```
Portal → Data → Connections → click broken connection → Properties
Note: "Created by" = the account whose OAuth token is used
```
⚠️ If this account has left the organisation or is disabled, every flow using this connection is broken.

**Step 3 — Test the connection directly**

```
Data → Connections → click the broken connection → Test
If test fails: re-auth needed (Fix 1 or Fix 4)
If test passes but flow still fails: the flow is referencing a different connection ID — Fix 4
```

**Step 4 — Check Entra ID for the refresh token revocation**

```powershell
# Check if user has had all tokens revoked (admin action, password reset, or MFA change)
Get-MgUser -UserId <UPN> -Property "signInSessionsValidFromDateTime" |
    Select-Object DisplayName, SignInSessionsValidFromDateTime
# If this timestamp is recent → tokens were revoked → user must re-auth
```

**Step 5 — Validate no CA policy is blocking**

In Azure Portal: Azure Active Directory → Sign-in logs → filter by User = connection owner, Application = the connector's app name.
Look for sign-in failures with "Conditional Access" failure reason.

---

## Common Fix Paths

<details><summary>Fix 1 — Re-authenticate an existing connection (quickest fix)</summary>

**When:** Connection shows ⚠️, the account is still active, token just expired.

1. Go to **Power Automate portal → Data → Connections**
2. Click the broken connection
3. Click **Edit** (pencil icon)
4. Click **Fix connection**
5. Complete the sign-in / MFA prompt
6. Return to the flow and **test** it

**Rollback:** N/A — re-auth is non-destructive. Old token is replaced with new one.

**PowerShell (find all broken connections for a user):**
```powershell
# Requires Power Platform CLI or Graph API — use portal for fastest resolution
# Admin view: Power Platform Admin Center → Resources → Connections → filter by status
```

</details>

<details><summary>Fix 2 — Handle MFA / Conditional Access blocking re-auth</summary>

**When:** AADSTS50076 (MFA required), AADSTS53003 (CA blocked), or re-auth prompt keeps looping.

The connection owner must re-authenticate from a **compliant device** that satisfies the CA policy.

1. Have the connection owner open Power Automate on a compliant, Intune-enrolled device
2. Navigate to **Data → Connections → [broken connection] → Fix connection**
3. Complete MFA in full (don't cancel)
4. If CA requires compliant device and the user's browser session is from a non-compliant device, the token will be denied even after MFA

**If the connection is a service account:**
- Service accounts should be excluded from device compliance CA policies (use a named exclusion group)
- Escalate to Azure AD admin to add the service account to a CA exclusion if appropriate
- Reference: https://docs.microsoft.com/en-us/power-platform/admin/wp-compliance-data-privacy

**Rollback:** N/A — no state change until auth succeeds.

</details>

<details><summary>Fix 3 — Admin consent missing or permissions changed</summary>

**When:** AADSTS70011 (invalid scope), AADSTS65001 (consent required), or connector worked before and broke after a permissions policy change.

**Check first:**
```powershell
# Requires Global Admin or Cloud Application Admin
Connect-MgGraph -Scopes "Application.Read.All"
$sp = Get-MgServicePrincipal -Filter "displayName eq '<ConnectorName>'"
Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id |
    Select-Object Scope, ConsentType, PrincipalId
```

**Fix (Global Admin required):**
1. Azure Portal → Azure Active Directory → Enterprise Applications
2. Search for the connector app (e.g. "Power Automate", "Microsoft Flow Service")
3. Permissions → Admin consent → **Grant admin consent for [tenant]**
4. Return to Power Automate and re-test the connection

**If permissions were intentionally restricted by admin policy:** escalate — do not work around intentional restrictions.

</details>

<details><summary>Fix 4 — Reassign connection after account deletion/disabling</summary>

**When:** Connection owner account is disabled, deleted, or has left the org. All flows using this connection are broken.

> ⚠️ **Destructive consideration:** changing the connection replaces whose credentials are used. Ensure the new account has appropriate permissions on the target service.

**Steps:**

1. Identify all affected flows:
```
Power Platform Admin Center → Resources → Connections → filter by owner = <departed-user>
Note all connection names and which flows reference them
```

2. Create new connections under a service account:
```
Data → Connections → + New connection → select the connector type
Sign in with the service account (e.g. svc-powerautomate@<domain>)
```

3. Update each flow to use the new connection:
```
Open the flow → Edit → for each action using the old connection:
  Click the connection dropdown → select the new connection
Save and test
```

4. Delete the old broken connection once all flows are updated.

**Best practice going forward:** use a dedicated service account for shared flows, not individual user accounts. Document in your flow inventory.

</details>

<details><summary>Fix 5 — DLP policy blocking connector</summary>

**When:** Error in flow run: `"The connector ... is blocked by the DLP policy"` or connector cannot be added to a flow.

DLP policies are set per-environment by Power Platform admins.

**Diagnose:**
```
Power Platform Admin Center → Policies → Data Policies
Select the policy applied to the environment
Check which bucket the connector is in: Business / Non-Business / Blocked
```

**Fix (Power Platform Admin required):**
- Move the connector from "Blocked" to "Business" or "Non-Business" bucket
- Or create an environment-specific policy that allows the connector
- Reference: https://docs.microsoft.com/en-us/power-platform/admin/wp-data-loss-prevention

**You cannot fix this without admin access — escalate immediately.**

</details>

---

## Escalation Evidence

Copy and fill in before raising a ticket:

```
=== Power Automate Connector Auth — Escalation Evidence ===

Date/Time of issue: _______________
Reporter / Affected user: _______________
Tenant ID: _______________
Environment name: _______________

Failing flow name: _______________
Flow owner: _______________
Connector type (e.g. SharePoint, Exchange, custom): _______________
Connection owner account: _______________

Error message from run history:
  _______________

AADSTS error code (if present): _______________
Connection status in portal (green/warning/error): _______________
Connection "Test" result: _______________

Connection owner account status:
  Enabled: Yes / No
  Last sign-in: _______________
  MFA registered: Yes / No

DLP policy in effect: Yes / No
  Policy name: _______________
  Connector bucket: Business / Non-Business / Blocked

Admin consent granted for connector app: Yes / No / Unknown

Steps already taken:
  [ ] Re-auth attempted
  [ ] Fix connection button clicked
  [ ] Tested from compliant device
  [ ] Admin consent checked

Escalating to: [ ] Power Platform Admin  [ ] Azure AD Admin  [ ] Both
```

---

## 🎓 Learning Pointers

- **OAuth refresh tokens expire if unused for 90 days or when a user's tokens are revoked.** Password resets, admin "Revoke all sessions" actions, and MFA method changes all invalidate refresh tokens. Any connection using that account will break silently — the flow won't fail until the next run. Set up a monitoring flow that tests critical connections weekly. Reference: https://docs.microsoft.com/en-us/azure/active-directory/develop/refresh-tokens

- **Connections are owned by the creating account, not the flow owner.** A flow can be shared to 50 people, but the connection it uses belongs to whoever created it. When that person leaves, every flow using their connection breaks — regardless of who "owns" the flow now. Always use shared service accounts for production flows. Reference: https://docs.microsoft.com/en-us/power-automate/create-team-flows

- **DLP "Blocked" is tenant-wide for that environment — it can't be overridden per-flow.** If a connector is in the Blocked bucket, no flow in that environment can use it, period. The only resolution is a policy change by an admin. Don't spend time debugging the flow itself if DLP is the cause.

- **The `ApiConnectionWait` status in run history is a sign of delegated auth waiting, not an error.** It usually means the flow is paused waiting for an approval or an OAuth prompt that never completed. It's not the same as a broken connection. Check the specific action that shows `ApiConnectionWait` — it may be an approval action, not a connection issue.

- **Premium connectors require a per-user or per-flow Power Automate Premium licence.** If a user's licence changes (e.g. downgrade from M365 E5 to E3), premium connectors in their flows will stop working within 30 days. Check licence status in M365 Admin Center → Active users before assuming the connection is broken.
