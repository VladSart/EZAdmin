# App Consent Policies & Illicit Consent Grant Attacks — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. A user is stuck on a consent prompt, a legitimate app can't get approved, or you're investigating a suspicious OAuth consent event.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---
## Triage

Run these against Microsoft Graph. Reading policies needs `Policy.Read.All`; changing them needs `Policy.ReadWrite.Authorization` and/or `Policy.ReadWrite.PermissionGrant`.

```powershell
Connect-MgGraph -Scopes "Policy.Read.All" -NoWelcome

# 1. Tenant-wide: is user consent allowed at all, and under which policy?
$authPolicy = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authorizationPolicy/authorizationPolicy"
$authPolicy.defaultUserRolePermissions.permissionGrantPoliciesAssigned

# 2. Is the admin consent workflow enabled, and who are the reviewers?
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/adminConsentRequestPolicy"

# 3. List all app consent policies (built-in + custom) in the tenant
Get-MgPolicyPermissionGrantPolicy | Select-Object Id, DisplayName, Description

# 4. Find the app in question and check what's already been granted
$sp = Get-MgServicePrincipal -Filter "displayName eq '<AppName>'"
Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id | Select-Object ConsentType, Scope, PrincipalId
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id | Select-Object PrincipalDisplayName, AppRoleId

# 5. Search the audit log for the specific consent event (Purview Audit, last 24h shown here)
# Portal is faster for this one: security.microsoft.com/auditlogsearch — filter Activity = "Consent to application"
```

**Interpret — if X then do Y:**

| Finding | Next action |
|---|---|
| User reports "Need admin approval" and nothing happens after clicking it | Admin consent workflow is disabled, or is enabled but has no active reviewers — see [Fix 1](#fix-1--need-admin-approval-request-goes-nowhere) |
| `AADSTS90094: admin consent is required` on sign-in | Expected behavior for an app requesting permissions the user isn't allowed to grant — see [Fix 2](#fix-2--legitimate-app-blocked-needs-tenant-wide-consent) |
| `AADSTS65001: user or administrator has not consented` | Consent was never granted, or was revoked — see [Fix 2](#fix-2--legitimate-app-blocked-needs-tenant-wide-consent) or [Fix 5](#fix-5--consent-was-revoked-and-a-legitimate-app-now-fails) |
| Audit log shows `Consent to application` with `IsAdminConsent: True` from an admin who doesn't recall doing it, or for an app nobody recognizes | Possible illicit consent grant / compromised admin — stop, go to [Fix 3](#fix-3--suspicious-admin-consent-event) immediately |
| `ConsentType: AllPrincipals` on an unfamiliar, non-Microsoft app | Tenant-wide delegated consent already granted to that app for every user — go to [Fix 4](#fix-4--confirmed-illicit-consent-grant) if the app is confirmed malicious |
| A reviewer is listed on the admin consent workflow but can't approve requests for Graph application permissions | Being a reviewer doesn't elevate privilege — see [Fix 6](#fix-6--reviewer-cant-approve-requests) |
| A custom app consent policy exists but users are still blocked (or unexpectedly allowed) | Policy include/exclude condition-set logic, or a second policy is also in play — see [Fix 7](#fix-7--custom-consent-policy-not-behaving-as-expected) |

---
## Dependency Cascade

<details><summary>What must be true for a user (or admin) to successfully consent to an app — click to expand</summary>

```
[Tenant-wide authorizationPolicy]
    │   allowUserConsentForRiskyApps / defaultUserRolePermissions.permissionGrantPoliciesAssigned
    │   This is the master switch — if user consent is off here, nothing below matters for regular users
    │
    ▼
[permissionGrantPolicyIdsAssignedToDefaultUserRole — which app consent policy applies]
    │   Built-in: microsoft-user-default-low / -legacy / -recommended (Microsoft-managed, auto-updates)
    │   OR a custom policy (include/exclude condition sets) assigned via a custom directory role
    │
    ▼
[The specific consent request must MATCH an "include" condition set AND match NO "exclude" set]
    │   Conditions: permission classification (low/medium/high), verified-publisher status,
    │   app registered-in-tenant status, specific resource APIs
    │
    ▼
[If the request doesn't match any policy the user/actor holds → BLOCKED]
    │   User sees "Need admin approval" IF admin consent workflow is enabled
    │   User sees a dead-end error if the workflow is NOT enabled
    │
    ▼
[Admin consent workflow (optional, Global-Admin-enabled feature)]
    │   Routes the blocked request to designated reviewers
    │   Reviewer being "listed" does NOT grant them RBAC — they still need
    │   Privileged Role Administrator / Application Administrator / Cloud
    │   Application Administrator / Global Administrator to actually approve
    │
    ▼
[Reviewer grants tenant-wide OR per-user admin consent]
    │   Application permissions (app roles) for Microsoft Graph specifically
    │   can ONLY be approved by Global Administrator or Privileged Role Admin
    │   — Application/Cloud Application Administrator cannot, even as a
    │   designated reviewer (documented, deliberate restriction)
    │
    ▼
[oauth2PermissionGrant (delegated) or appRoleAssignment (application) record created]
    │
    ▼
[User's next sign-in succeeds without a consent prompt]
```

**What silently breaks this and produces confusing symptoms:**
- A reviewer is added to the admin consent workflow's reviewer list but was never granted an actual RBAC role — they see the request but every approve action fails or is greyed out, and this reads as "the workflow is broken" rather than "this person lacks permission."
- Two consent policies both apply to a user (e.g., the default policy plus a role-attached custom policy) — only ONE has to approve for consent to succeed, so removing an unwanted permission from one policy doesn't block it if another policy still allows it.
- `microsoft-user-default-recommended` and `microsoft-user-default-allow-consent-apps` are Microsoft-managed and silently change their own rules over time as Microsoft updates its security recommendations — a permission that was blocked last quarter may be allowed today, or vice versa, with no tenant-side change logged.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm what the tenant-wide default actually allows right now**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All" -NoWelcome
$authPolicy = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authorizationPolicy/authorizationPolicy"
$authPolicy.defaultUserRolePermissions.permissionGrantPoliciesAssigned
```
Healthy/expected: a short list like `managePermissionGrantsForSelf.microsoft-user-default-low`. Broken/risky: empty (user consent silently defaulted to legacy-allow-all in older tenants) or `...-legacy` present without a documented reason.

**Step 2 — Identify every policy that could be granting this specific request**
```powershell
Get-MgPolicyPermissionGrantPolicy | ft Id, DisplayName
Get-MgPolicyPermissionGrantPolicyInclude -PermissionGrantPolicyId "<policy-id>" | fl
Get-MgPolicyPermissionGrantPolicyExclude -PermissionGrantPolicyId "<policy-id>" | fl
```
Remember: a user only needs ONE applicable policy to approve, and ownership of the target Service Principal or the `Application.ReadWrite.All` app permission are separate authorization paths that bypass consent policies entirely — don't assume the policy list is exhaustive.

**Step 3 — Check the admin consent workflow configuration and reviewer RBAC**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/adminConsentRequestPolicy"
# Cross-check each listed reviewer's actual directory role assignments:
Get-MgUser -UserId "<reviewer-upn>" | Select-Object Id
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<reviewerObjectId>'" -ExpandProperty RoleDefinition |
    Select-Object @{N="Role";E={$_.RoleDefinition.DisplayName}}
```
Broken: `isEnabled: false` (workflow off entirely), or every listed reviewer lacks Global Administrator/Privileged Role Administrator/Application Administrator/Cloud Application Administrator.

**Step 4 — Pull the actual consent event from the audit log**
Microsoft Defender portal → **Audit** (`security.microsoft.com/auditlogsearch`) → search **Activities: Consent to application**, appropriate date range. Open the matching entry and check `IsAdminConsent`. `True` from an unexpected actor, for an unrecognized app, is the single highest-signal indicator of a compromised-admin or illicit-consent-grant event — escalate immediately rather than continuing routine triage.

**Step 5 — For a specific app, diff requested vs. granted permissions**
```powershell
$sp  = Get-MgServicePrincipal -Filter "displayName eq '<AppName>'"
$app = Get-MgApplication -Filter "appId eq '$($sp.AppId)'"
$app.RequiredResourceAccess                                            # requested
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id      # granted (application permissions)
Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id  # granted (delegated permissions)
```
Broken: a requested permission with no matching grant — the app will keep prompting or failing until it's either consented or the requesting feature is unused.

**Step 6 — Tenant-wide illicit-consent sweep (when investigating, not routine triage)**
Run the community `Get-AzureADPSPermissions.ps1` script (referenced directly by Microsoft's own remediation guidance) to dump every OAuth grant for every user to CSV, then filter `ConsentType = AllPrincipals` and scan `ClientDisplayName` for misspelled/generic/suspicious app names. See [Fix 4](#fix-4--confirmed-illicit-consent-grant).

---
## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — "Need admin approval" request goes nowhere</summary>

**Symptom:** User sees the approval-required screen, submits a justification, and nothing ever happens — no reviewer acts, no notification arrives.

Most likely cause: the admin consent workflow is either disabled, or enabled with zero currently-valid reviewers (all removed/departed since the workflow was configured).

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.Authorization" -NoWelcome
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/adminConsentRequestPolicy"
```

If `isEnabled: false`, turn it on (Global Administrator required — Entra admin center is simplest): **Entra ID** → **Enterprise apps** → **Consent and permissions** → **Admin consent settings** → **Users can request admin consent to apps they are unable to consent to: Yes** → set reviewers, notification, and expiry-days options → **Save**. Allow up to an hour to take effect.

If it's already enabled, confirm the reviewer list isn't stale (see Diagnosis Step 3) and add a currently-valid reviewer with real RBAC:
```
Entra admin center → Enterprise apps → Consent and permissions → Admin consent settings →
Who can review admin consent requests → add reviewer
```

**Rollback:** disabling the workflow again is a single toggle; existing pending requests remain until they individually expire.

</details>

<details id="fix-2"><summary>Fix 2 — Legitimate app blocked, needs tenant-wide consent</summary>

**Symptom:** `AADSTS90094` or `AADSTS65001` for a business-approved app. Users can't self-consent because it requests permissions above what the default policy allows.

Evaluate first — this is a genuinely sensitive action (see the Evaluation checklist in `AppConsentPolicies-A.md`'s How It Works section). If approved, grant tenant-wide admin consent (Global Administrator, or a role holding `microsoft-application-admin`/`microsoft-company-admin` for non-Graph-app-role permissions):

```powershell
Connect-MgGraph -Scopes "DelegatedPermissionGrant.ReadWrite.All","AppRoleAssignment.ReadWrite.All" -NoWelcome
```
Portal path is simplest and least error-prone: **Entra admin center** → **Enterprise applications** → select the app → **Permissions** → **Grant admin consent for `<tenant>`**.

Consider pairing this with **Require user assignment** on the app so tenant-wide consent doesn't silently mean tenant-wide *access*:
```powershell
Update-MgServicePrincipal -ServicePrincipalId $sp.Id -AppRoleAssignmentRequired
```

**Rollback:** revoke via [Fix 5](#fix-5--consent-was-revoked-and-a-legitimate-app-now-fails)'s reverse direction — remove the oauth2PermissionGrant/appRoleAssignment.

</details>

<details id="fix-3"><summary>Fix 3 — Suspicious admin-consent event</summary>

**Symptom:** Audit log shows `Consent to application` / `IsAdminConsent: True` that the named actor doesn't recognize, for an app with an unfamiliar or suspicious-looking name, or at an unusual time.

Treat this as a potential security incident, not a routine consent question, until disproven:

1. **Do not immediately delete/revoke yet** if you need to preserve evidence for a formal investigation — coordinate with security/IR first per your organization's process.
2. Confirm the actor's own account isn't compromised: check their recent sign-in log for impossible travel, unfamiliar IPs, or a recent successful MFA-fatigue-style push approval.
3. Inventory exactly what the app can now do:
```powershell
$sp = Get-MgServicePrincipal -Filter "appId eq '<suspiciousAppId>'"
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id | fl
Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id | fl
```
4. Check `ConsentType` — `AllPrincipals` means every user in the tenant is affected, not just the consenting admin.
5. Escalate to [Fix 4](#fix-4--confirmed-illicit-consent-grant) once confirmed malicious, or to your standard non-security escalation path if it turns out to be a legitimate, forgotten admin action.

</details>

<details id="fix-4"><summary>Fix 4 — Confirmed illicit consent grant</summary>

**Symptom:** An OAuth app has been confirmed malicious or unauthorized, and has account-level access to mail, files, or contacts via a granted consent — not a compromised password, so password resets and MFA changes do **not** remove its access.

```powershell
Connect-MgGraph -Scopes "DelegatedPermissionGrant.ReadWrite.All","AppRoleAssignment.ReadWrite.All" -NoWelcome

# Revoke delegated (OAuth2) permission grants
Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id | ForEach-Object {
    Remove-MgOauth2PermissionGrant -OAuth2PermissionGrantId $_.Id
}

# Revoke application permission (app role) assignments
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id | ForEach-Object {
    Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -AppRoleAssignmentId $_.Id
}
```

Then, in order:
1. Disable the app's Service Principal sign-in entirely if it has no legitimate use: `Update-MgServicePrincipal -ServicePrincipalId $sp.Id -AccountEnabled:$false`
2. Determine scope: which users/mailboxes were exposed, and for how long (audit log time range where the grant existed).
3. Follow your standard incident process for any data potentially accessed — this is a data-access event, not just an access-removal event.
4. Only as a last resort, **Turning Integrated Apps off** blocks ALL consent tenant-wide (severe productivity impact) — reserve for active, ongoing mass-phishing campaigns, not a single confirmed app.

**Rollback:** none needed — revoking a malicious grant has no legitimate reason to be undone. If a legitimate app was wrongly caught in a broad remediation, re-grant via [Fix 2](#fix-2--legitimate-app-blocked-needs-tenant-wide-consent) after re-evaluation.

</details>

<details id="fix-5"><summary>Fix 5 — Consent was revoked and a legitimate app now fails</summary>

**Symptom:** A previously-working integration starts failing with `AADSTS65001` after a security review, permission cleanup, or the illicit-consent sweep in Fix 4 caught it by mistake.

```powershell
$sp = Get-MgServicePrincipal -Filter "displayName eq '<AppName>'"
Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id   # confirm it's actually empty/revoked
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id
```
Confirm with whoever revoked it (a revocation is very often deliberate) before re-granting via **Entra admin center** → **Enterprise applications** → app → **Permissions** → **Grant admin consent**.

</details>

<details id="fix-6"><summary>Fix 6 — Reviewer can't approve requests</summary>

**Symptom:** A user is listed under "Who can review admin consent requests" but their approve action fails, is greyed out, or only works for some requests and not others.

This is expected, documented behavior, not a bug: **being designated as a reviewer does not elevate the reviewer's privileges.** Only Global Administrator can approve requests involving Microsoft Graph application permissions (app roles); other reviewers can view/block/deny but not approve those specific requests.

```powershell
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<reviewerObjectId>'" -ExpandProperty RoleDefinition |
    Select-Object @{N="Role";E={$_.RoleDefinition.DisplayName}}
```
Fix: either add the reviewer to Global Administrator (only if genuinely warranted — high privilege), or route Graph-application-permission requests to a reviewer who already holds Global Administrator, and keep the broader reviewer group for lower-risk delegated-permission requests.

</details>

<details id="fix-7"><summary>Fix 7 — Custom consent policy not behaving as expected</summary>

**Symptom:** A custom app consent policy was created, but consent is still blocked (or still allowed) contrary to what the policy's rules suggest.

```powershell
Get-MgPolicyPermissionGrantPolicyInclude -PermissionGrantPolicyId "<my-custom-policy>" | fl
Get-MgPolicyPermissionGrantPolicyExclude -PermissionGrantPolicyId "<my-custom-policy>" | fl
```

Check, in order:
1. **Match logic**: a request must match AT LEAST ONE include set and NO exclude sets. A single mismatched condition in the only include set fails the whole policy for that request.
2. **Multiple policies**: the user may hold a second policy (e.g., the tenant default, or a different custom role) that independently allows the same request — removing a permission from one policy doesn't block it if another still grants it.
3. **Role attachment**: a custom app consent policy has no effect until it's attached to a custom directory role, and that role is assigned to the intended users — a policy that exists but isn't attached to any role does nothing.
4. **Verified-publisher condition**: `ClientApplicationsFromVerifiedPublisherOnly` fails silently (not a clear error) for legitimate apps whose publisher verification lapsed or was never completed — check the app's Enterprise Applications properties page for its current publisher status.

</details>

---
## Escalation Evidence

```
App Consent — Evidence Pack
====================================
Reported by / affected user(s):
Application display name:
Application (client) ID:
Service Principal Object ID:

Consent state observed:
  Delegated grants (oauth2PermissionGrant): [ConsentType / Scope]
  Application grants (appRoleAssignment):   [AppRoleId / Resource]
  IsAdminConsent on the relevant audit event: [True / False / N/A]
  Actor who granted/attempted consent:

Policy context:
  Tenant defaultUserRolePermissions policy:
  Custom policy involved (if any):
  Admin consent workflow enabled:   [YES / NO]
  Reviewer(s) and their RBAC role(s):

Error details:
  Error code:                 [AADSTS.....]
  Timestamp:
  Sign-in / audit log entry link:

Security assessment (if illicit-consent-grant suspected):
  Publisher verified:         [YES / NO]
  App registered in this tenant or external: 
  ConsentType AllPrincipals:  [YES / NO]
  Scope of exposure (users/mailboxes/data):
  Actions already taken:      [revoked / disabled SP / none yet]

Steps already tried:
```

---
## 🎓 Learning Pointers

- **Consent persists across password resets and bypasses MFA.** An illicit consent grant is not a credential-theft attack — resetting the victim's password or forcing re-MFA does nothing to remove the malicious app's access, because the app authenticates as itself using the OAuth token it was granted, not as the user. The access has to be explicitly revoked. [MS Docs: Detect and remediate illicit consent grants](https://learn.microsoft.com/en-us/defender-office-365/detect-and-remediate-illicit-consent-grants)

- **Being listed as an admin-consent-workflow reviewer does not grant any actual permission.** Microsoft's own documentation states this explicitly: "Simply designating them as a reviewer doesn't elevate their privileges." A reviewer still needs Global Administrator, Privileged Role Administrator, Application Administrator, or Cloud Application Administrator to actually act — and only Global Administrator/Privileged Role Administrator can approve Microsoft Graph application-permission requests specifically. [MS Docs: Configure the admin consent workflow](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/configure-admin-consent-workflow)

- **A user only needs ONE approving policy or authorization mechanism, not all of them.** Multiple app consent policies can apply to the same user simultaneously and are evaluated independently — tightening one policy doesn't close a gap left open by another. Ownership of the target Service Principal, or holding the `Application.ReadWrite.All` app permission as a calling application, are separate authorization paths outside the policy system entirely. [MS Docs: Manage app consent policies](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/manage-app-consent-policies)

- **`microsoft-user-default-recommended` is a Microsoft-managed, living policy** — its rules update automatically as Microsoft revises its security guidance, with no tenant-side change record. A permission classification that was blocked last month may be allowed this month purely because Microsoft updated the policy, not because anyone in your tenant changed anything.

- **The reference detection script (`Get-AzureADPSPermissions.ps1`) is a community/Microsoft-linked GitHub Gist, not a signed module** — review it before running in a production tenant, same as any script from an external source, even when directly referenced by Microsoft's own remediation documentation.

- **`ConsentType: AllPrincipals` is the single highest-severity value to look for during an investigation** — it means the delegated permission grant applies to every user in the tenant, not just the person who happened to trigger the consent prompt or the admin who granted it.
