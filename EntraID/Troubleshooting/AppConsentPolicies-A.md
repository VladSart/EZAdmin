# App Consent Policies & Illicit Consent Grant Attacks — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This runbook covers the Microsoft Entra ID **application consent framework**: who is allowed to grant an application access to tenant data (user consent vs. admin consent), how that authorization is governed (the tenant-wide `authorizationPolicy` plus built-in and custom `permissionGrantPolicies`), the admin consent workflow that lets blocked users request approval, and the detection/remediation of **illicit consent grant attacks** — OAuth-phishing attacks that trick a user or admin into consenting to a malicious application.

This is a distinct governance layer from credential/service-principal health, which is covered in [`AppRegistrations-A.md`](AppRegistrations-A.md)/[`AppRegistrations-B.md`](AppRegistrations-B.md) — that pair assumes consent has already been granted and something else (a secret, the Service Principal, a missing consent record) is broken. This pair assumes the question is *whether consent should exist at all, who is allowed to grant it, and whether an existing grant is legitimate*. Also distinct from [`EnterpriseAppProvisioning-A.md`](EnterpriseAppProvisioning-A.md) (SCIM provisioning connectors) and [`WorkloadIdentity-A.md`](WorkloadIdentity-A.md) (non-human workload authentication) — both of those assume the app is already trusted and consented; this topic is about the trust decision itself.

Assumes Microsoft Graph PowerShell SDK (`Microsoft.Graph.Applications`, `Microsoft.Graph.Identity.SignIns`) or Graph API access, and familiarity with the delegated-vs-application-permission distinction. Does not cover Conditional Access app-control policies (session/access controls after sign-in — see [`Security/ConditionalAccess/`](../../Security/ConditionalAccess/)) or Microsoft Defender for Cloud Apps OAuth app governance policies (a licensed, separate detection surface referenced but not detailed here).

---
## How It Works

### Two authorization layers, evaluated together

Consent in Entra ID is governed by two distinct but related objects, and confusing them is the single most common source of "I changed the setting but nothing happened" tickets:

1. **`authorizationPolicy`** (singleton, tenant-wide) — the master switch. Its `defaultUserRolePermissions.permissionGrantPoliciesAssigned` collection lists *which* app consent policies apply to the default (non-admin) user role. This is what the Entra admin center's simple "User consent settings" toggle actually writes to under the hood.
2. **`permissionGrantPolicies`** (a collection — built-in and custom) — the actual rules. Each policy is a set of **include** and **exclude condition sets**. A consent request is allowed by a given policy only if it matches at least one include set and matches none of the exclude sets.

A user's ability to consent to a specific request is the union (logical OR) of every policy that applies to them through any assigned role, plus any other standing authorization mechanism they hold (Service Principal ownership, or an app permission that itself grants consent authority, such as `Application.ReadWrite.All`). **Only one has to say yes.** This is why removing a permission from one policy is not sufficient to block it — a second policy, or a non-policy authorization path, can independently allow the same request.

### Built-in consent policies

Every tenant ships with the same fixed set of built-in policies (cannot be edited, only referenced):

| Policy ID | Purpose |
|---|---|
| `microsoft-user-default-low` | Low-risk delegated permissions, verified-publisher/in-tenant apps only |
| `microsoft-user-default-legacy` | Any non-admin-required permission, any app — the pre-hardening default |
| `microsoft-user-default-recommended` | **Microsoft-managed** — auto-updates as Microsoft's security guidance changes |
| `microsoft-user-default-allow-consent-apps` | A fixed allowlist of popular mail clients (Apple Mail, Spark, eM Client, Thunderbird, Android Mail/Samsung) for mail-scoped delegated permissions only |
| `microsoft-application-admin` | What Application Administrator / Cloud Application Administrator can consent to (excludes Graph app roles) |
| `microsoft-company-admin` | What Company Administrator (Global Administrator) can consent to |
| `microsoft-all-application-permissions[-verified]` | All application permissions, for any/verified-publisher-only client apps — used in custom roles, not assigned by default |

`microsoft-user-default-recommended` and `microsoft-user-default-allow-consent-apps` are explicitly called out by Microsoft as **living, Microsoft-managed policies** — their condition sets change over time without any action or log entry on the tenant side. A permission blocked last quarter under `-recommended` may be silently allowed today.

### Delegated vs. application permission consent, and who can grant each

Delegated permissions act on behalf of a signed-in user; application permissions (app roles) act with no user context, at the tenant's full scope for that permission. Any Privileged Administrator can grant *some* level of consent, but Microsoft Graph application permissions specifically are gated tighter than everything else: only **Global Administrator** or **Privileged Role Administrator** can grant tenant-wide admin consent for Graph app roles. Application Administrator and Cloud Application Administrator — despite being described as able to "create and manage all aspects of app registrations and enterprise apps" — are explicitly carved out of that one capability. This exception is documented, not a bug, and is the root cause of Fix 6 in the companion `-B.md` (a designated admin-consent-workflow reviewer who can view but not approve a Graph-app-role request).

### The admin consent workflow

An optional, Global-Administrator-enabled feature (`adminConsentRequestPolicy`) that gives non-admin users a self-service path to *request* approval when they hit a consent wall, instead of a dead end. It routes the request to designated reviewers by email, and reviewers act from a "My Pending" queue. Critically, **being designated as a reviewer is purely a routing/visibility mechanism — it grants no additional RBAC**. A reviewer without an underlying privileged role sees requests they cannot act on.

### Illicit consent grant attacks

A phishing technique, not a credential-theft technique: the attacker registers (often in an external tenant) an application requesting access to mail, files, or contacts, then tricks a user — via a phishing email or a compromised trusted website — into clicking through the consent prompt. Once granted, the attacker's app authenticates as itself using the resulting OAuth token; it does not need the victim's password and is unaffected by password resets or new MFA enrollment. This is why illicit consent grants require an explicit revoke-the-grant remediation rather than the standard "reset credentials" incident playbook, and why detection depends on audit-log review (`Consent to application` activity, `IsAdminConsent` field) rather than sign-in-risk signals.

### Evaluating a request for tenant-wide admin consent

Before granting, Microsoft's own guidance frames this as a five-point check: (1) understand the delegated-vs-application-permission distinction for what's requested, (2) read every permission's actual description, not just its name, (3) confirm which application and which publisher is actually asking, (4) confirm the requested scope matches the app's stated purpose (a SharePoint tool asking for full mailbox impersonation is a red flag), (5) if any of the above is unclear, don't grant — contact the publisher or escalate rather than guessing.

---
## Dependency Stack

```
[Tenant-wide authorizationPolicy — master on/off + which policies apply to default user role]
        │
        ▼
[permissionGrantPolicies — built-in and/or custom — include/exclude condition-set evaluation]
        │
        ▼
[Other standing authorization mechanisms — Service Principal ownership,
 Application.ReadWrite.All-holding caller — evaluated independently, can bypass policy entirely]
        │
        ▼
[If no path allows the request → BLOCKED]
        │
        ▼
[adminConsentRequestPolicy (optional) — routes blocked requests to reviewers]
        │
        ▼
[Reviewer's OWN RBAC role determines what they can actually approve —
 Global Administrator / Privileged Role Administrator required for Graph app roles specifically]
        │
        ▼
[oauth2PermissionGrant (delegated) or appRoleAssignment (application) created]
        │
        ▼
[Purview Audit log records the "Consent to application" event, incl. IsAdminConsent]
        │
        ▼
[Detection layer (optional, licensed): Defender for Cloud Apps OAuth app governance,
 Purview Audit search, community PowerShell inventory scripts]
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| User stuck on "Need admin approval," nothing ever happens | Admin consent workflow disabled or has no valid reviewers | `GET /policies/adminConsentRequestPolicy` — `isEnabled` and reviewer list |
| `AADSTS90094: admin consent is required` | App requests permissions above what any policy applying to the user allows | `Get-MgPolicyPermissionGrantPolicy` + include/exclude sets for the user's assigned policies |
| `AADSTS65001` on a previously-working app | Consent was explicitly revoked, or never completed for this tenant (multi-tenant scenario) | `Get-MgServicePrincipalOauth2PermissionGrant` / `AppRoleAssignedTo` — empty result |
| Reviewer can see a request but Approve fails/greys out | Reviewer lacks the underlying RBAC role for that permission type | `Get-MgRoleManagementDirectoryRoleAssignment` for the reviewer's principal |
| Custom consent policy has no visible effect | Policy not attached to any custom role, or role not assigned to the user | Directory role definitions — confirm `resourceScopes` reference the policy and check role assignment |
| A permission that used to be blocked is now allowed (or vice versa) with no tenant change made | `microsoft-user-default-recommended`'s Microsoft-managed rules changed | Compare current include/exclude sets against prior documentation/screenshots — no built-in change log exists |
| Audit log `Consent to application`, `IsAdminConsent: True`, unrecognized app or actor denies it | Possible illicit consent grant / compromised admin account | Purview Audit search, cross-reference actor's sign-in log for anomalies |
| `ConsentType: AllPrincipals` on an unfamiliar app | Tenant-wide delegated consent already exists for every user, not just one | `Get-MgServicePrincipalOauth2PermissionGrant` — `ConsentType` field |
| User can consent to some apps but not others with seemingly similar permissions | Verified-publisher condition — publisher status differs between apps | App's Enterprise Applications properties — publisher verification badge |
| Tenant-wide admin consent granted, but access is broader than intended | Consent ≠ assignment — no `RequireUserAssignment` set on the Service Principal | `Get-MgServicePrincipal` — `AppRoleAssignmentRequired` property |

---
## Validation Steps

**Step 1 — Read the tenant-wide default (`authorizationPolicy`)**
```powershell
Connect-MgGraph -Scopes "Policy.Read.All" -NoWelcome
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authorizationPolicy/authorizationPolicy" |
    Select-Object -ExpandProperty defaultUserRolePermissions
```
Good: `permissionGrantPoliciesAssigned` contains a deliberate, documented policy (e.g., `managePermissionGrantsForSelf.microsoft-user-default-low`). Bad: empty array (implicit legacy-allow behavior in some older tenants) or `...-legacy` present without a change record explaining why.

**Step 2 — Enumerate every consent policy and inspect condition sets**
```powershell
Get-MgPolicyPermissionGrantPolicy | Select-Object Id, DisplayName, Description
foreach ($p in (Get-MgPolicyPermissionGrantPolicy)) {
    "== $($p.Id) ==" 
    Get-MgPolicyPermissionGrantPolicyInclude -PermissionGrantPolicyId $p.Id | fl
    Get-MgPolicyPermissionGrantPolicyExclude -PermissionGrantPolicyId $p.Id | fl
}
```
Good: custom policies (anything not prefixed `microsoft-`) have documented owners/purpose. Bad: orphaned custom policies with no attached role (dead configuration) or an include set broad enough to defeat the point of having a policy at all.

**Step 3 — Confirm which directory roles carry which policies**
Custom app consent policies only take effect once attached to a **custom directory role** and that role assigned to users. There is no single Graph call that reverse-maps "which role uses this policy" — cross-reference role definitions' `resourceScopes`/`rolePermissions` against the policy ID, or maintain this mapping in documentation as you create custom policies.

**Step 4 — Validate the admin consent workflow and reviewer RBAC together**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/adminConsentRequestPolicy"
```
Good: `isEnabled: true`, a non-empty reviewer list, and every reviewer independently holds Global Administrator, Privileged Role Administrator, Application Administrator, or Cloud Application Administrator. Bad: any reviewer with none of those roles — they will appear functional in the UI but cannot actually approve.

**Step 5 — Audit log sweep for illicit consent indicators**
Purview Audit (`security.microsoft.com/auditlogsearch`) → Activity = `Consent to application`, appropriate range. For each result: `IsAdminConsent`, actor identity, target application, and `ConsentType` if visible in the extended properties. Good: every admin-consent event traces to a known, deliberate change. Bad: any event the named actor does not recognize.

**Step 6 — Full tenant OAuth-grant inventory (periodic, not just incident-driven)**
Run `Get-AzureADPSPermissions.ps1` (Microsoft-referenced community script) → `Export-Csv`. Filter `ConsentType = AllPrincipals` first (tenant-wide blast radius), then scan `ClientDisplayName`/`Permission` columns for suspicious names or excessive Read/Write/All grants. This is also the basis for [Remediation Playbook 4](#playbook-4).

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm which layer is actually blocking or allowing the request**
Tenant default → applicable policy → include/exclude match → other authorization mechanism → admin consent workflow. Work top-down; most tickets are resolved by Validation Steps 1–2 alone.

**Phase 2 — Policy-layer issues**
Missing/misconfigured include set, unintended exclude set, custom policy not attached to a role, two policies producing conflicting expectations (only one needs to allow — see Dependency Stack).

**Phase 3 — Workflow/reviewer-layer issues**
Workflow disabled, stale reviewer list, reviewer lacking underlying RBAC for the specific permission type requested (Graph app roles are the sharpest edge here).

**Phase 4 — Trust/security-layer issues**
Confirmed or suspected illicit consent grant, compromised admin account used to grant consent, publisher verification status blocking (or should be blocking, but isn't because verification was never required) a request.

**Phase 5 — Post-grant governance issues**
Tenant-wide consent granted without `RequireUserAssignment`, meaning every licensed user now has access regardless of business need — a common gap between "we approved this app" and "we scoped this app."

---
## Remediation Playbooks

<details><summary>Playbook 1 — From-scratch baseline: restrict user consent + enable the admin consent workflow</summary>

The Microsoft-recommended starting posture for a tenant that has never deliberately configured consent (i.e., still on the legacy allow-all default).

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.Authorization" -NoWelcome

# 1. Restrict the default user role to low-risk, verified-publisher consent only
$body = @{
    "defaultUserRolePermissions" = @{
        "permissionGrantPoliciesAssigned" = @(
            "managePermissionGrantsForSelf.microsoft-user-default-low"
        )
    }
}
Update-MgPolicyAuthorizationPolicy -BodyParameter $body

# 2. Classify permissions as low/medium/high if not already done — required for
#    microsoft-user-default-low to have any effect (see Learning Pointers)
```

3. Enable the admin consent workflow (portal, Global Administrator): **Entra ID** → **Enterprise apps** → **Consent and permissions** → **Admin consent settings** → enable, add reviewers who hold real RBAC (Application Administrator minimum; add a Global Administrator specifically for Graph-app-role requests), set a reasonable expiry (7–14 days is typical).

4. Communicate the change before flipping it — this playbook will immediately start blocking consent flows users may be used to completing themselves.

**Rollback:** revert `permissionGrantPoliciesAssigned` to its prior value; disable the workflow toggle. Existing grants are unaffected either direction.

</details>

<details><summary>Playbook 2 — Respond to a confirmed illicit consent grant attack</summary>

1. **Confirm** via audit log (`Consent to application`, `IsAdminConsent`) and/or the OAuth-grant inventory script — don't act on a single unverified report.
2. **Scope**: which users, which permissions, `ConsentType` (single user vs. `AllPrincipals`), how long the grant existed (first-seen timestamp in the audit log).
3. **Revoke**:
```powershell
Connect-MgGraph -Scopes "DelegatedPermissionGrant.ReadWrite.All","AppRoleAssignment.ReadWrite.All" -NoWelcome
Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id |
    ForEach-Object { Remove-MgOauth2PermissionGrant -OAuth2PermissionGrantId $_.Id }
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id |
    ForEach-Object { Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -AppRoleAssignmentId $_.Id }
Update-MgServicePrincipal -ServicePrincipalId $sp.Id -AccountEnabled:$false
```
4. **Investigate data exposure** for the scoped time window — this is a data-access incident, not just an access-removal task. Requires Mailbox Auditing and admin/user Activity Auditing to have been enabled *before* the attack to be fully answerable.
5. **Harden**: tighten the default consent policy (Playbook 1) and/or enable Defender for Cloud Apps OAuth app policies if licensed, so the same phishing vector doesn't repeat.
6. **User communication**: the affected user did nothing wrong from a credentials standpoint — frame communication around "you clicked a consent prompt for an app that turned out to be malicious," not "your password was compromised," since the remediation and future-prevention advice genuinely differ.

**Rollback:** none applicable — revoking a confirmed-malicious grant is not reversed. If later found to be a false positive, re-grant via Playbook 1's consent path after full re-evaluation.

</details>

<details><summary>Playbook 3 — Build a custom app consent policy for a specific team or app category</summary>

Example: allow a specific engineering group to self-consent to low-risk Azure DevOps/GitHub-category apps without opening that up tenant-wide.

```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.PermissionGrant" -NoWelcome

New-MgPolicyPermissionGrantPolicy -Id "eng-devtools-consent" `
    -DisplayName "Engineering DevTools Consent" `
    -Description "Low-risk delegated consent for approved dev-tooling apps"

New-MgPolicyPermissionGrantPolicyInclude -PermissionGrantPolicyId "eng-devtools-consent" `
    -PermissionType "delegated" -PermissionClassification "low" `
    -ClientApplicationsFromVerifiedPublisherOnly

# Optional: exclude a specific sensitive resource API even if otherwise "low"
$azureApi = Get-MgServicePrincipal -Filter "servicePrincipalNames/any(n:n eq 'https://management.azure.com/')"
New-MgPolicyPermissionGrantPolicyExclude -PermissionGrantPolicyId "eng-devtools-consent" `
    -PermissionType "delegated" -ResourceApplication $azureApi.AppId
```

Then create/attach a custom directory role referencing this policy and assign it to the target group — an app consent policy with no role attached is inert. See [`custom-consent-permissions`](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/custom-consent-permissions) for the role-attachment schema.

**Rollback:**
```powershell
Remove-MgPolicyPermissionGrantPolicy -PermissionGrantPolicyId "eng-devtools-consent"
```
Deleted custom policies cannot be restored — recreate from source/documentation if needed.

</details>

<details><summary>Playbook 4 — Reduce friction: proactively consent high-usage apps before restricting the default</summary>

Useful immediately after Playbook 1 tightens the default — existing, already-trusted apps with many individual user consents will otherwise start generating a wave of admin-consent-workflow requests.

1. Inventory current consent volume per app using the same `Get-AzureADPSPermissions.ps1` output as the detection script, grouped by `ClientDisplayName`.
2. For each high-volume app, evaluate per the five-point check in How It Works, then grant tenant-wide admin consent (Fix 2 in the `-B.md`).
3. Pair every proactive grant with `AppRoleAssignmentRequired` on the Service Principal so tenant-wide consent doesn't also mean unrestricted tenant-wide access:
```powershell
Update-MgServicePrincipal -ServicePrincipalId $sp.Id -AppRoleAssignmentRequired
```
4. Re-run the volume inventory after the restricted default (Playbook 1) has been live for a few weeks to catch any high-friction app that was missed the first pass.

**Rollback:** revoke the specific app's grant as in Fix 5 of the `-B.md` if a proactively-approved app is later found unsuitable.

</details>

---
## Evidence Pack

```powershell
<#
    Consent Evidence Pack — run against Microsoft Graph, read-only.
    Collects the state needed for either a support escalation or a
    security-incident writeup involving app consent.
#>
Connect-MgGraph -Scopes "Policy.Read.All","Application.Read.All","AuditLog.Read.All" -NoWelcome

$out = @{}
$out.AuthorizationPolicy = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/policies/authorizationPolicy/authorizationPolicy"
$out.AdminConsentWorkflow = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/policies/adminConsentRequestPolicy"
$out.AllConsentPolicies = Get-MgPolicyPermissionGrantPolicy | Select-Object Id, DisplayName, Description

$sp = Get-MgServicePrincipal -Filter "displayName eq '<AppName>'"
$out.TargetApp = $sp | Select-Object DisplayName, AppId, Id, AccountEnabled, AppRoleAssignmentRequired
$out.DelegatedGrants = Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id
$out.ApplicationGrants = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id

$out | ConvertTo-Json -Depth 6 | Out-File "$env:TEMP\ConsentEvidencePack-$(Get-Date -Format yyyyMMdd-HHmm).json"
Write-Host "Evidence pack written. Pair with a Purview Audit export (Consent to application activity) — not Graph-queryable directly."
```

Note: the actual `Consent to application` audit event (with `IsAdminConsent` and the granting actor) lives in Purview Audit, not in a Graph endpoint queryable from PowerShell in the same call — export it separately from `security.microsoft.com/auditlogsearch` and attach both to the evidence pack.

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| Read tenant default consent policy | `Invoke-MgGraphRequest GET .../policies/authorizationPolicy/authorizationPolicy` |
| Read admin consent workflow config | `Invoke-MgGraphRequest GET .../policies/adminConsentRequestPolicy` |
| List all consent policies | `Get-MgPolicyPermissionGrantPolicy` |
| View a policy's include conditions | `Get-MgPolicyPermissionGrantPolicyInclude -PermissionGrantPolicyId <id>` |
| View a policy's exclude conditions | `Get-MgPolicyPermissionGrantPolicyExclude -PermissionGrantPolicyId <id>` |
| Create a custom consent policy | `New-MgPolicyPermissionGrantPolicy` |
| Delete a custom consent policy | `Remove-MgPolicyPermissionGrantPolicy -PermissionGrantPolicyId <id>` |
| List an app's delegated grants | `Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId <spId>` |
| List an app's application grants | `Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId <spId>` |
| Revoke a delegated grant | `Remove-MgOauth2PermissionGrant -OAuth2PermissionGrantId <id>` |
| Revoke an application grant | `Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId <spId> -AppRoleAssignmentId <id>` |
| Require user assignment (scope access post-consent) | `Update-MgServicePrincipal -ServicePrincipalId <spId> -AppRoleAssignmentRequired` |
| Disable a malicious app's sign-in | `Update-MgServicePrincipal -ServicePrincipalId <spId> -AccountEnabled:$false` |
| Check a reviewer's actual RBAC | `Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<id>'" -ExpandProperty RoleDefinition` |
| Classify permissions (prereq for `-low` policy) | Entra admin center → Enterprise apps → Consent and permissions → Permission classifications |
| Tenant-wide OAuth grant inventory | `Get-AzureADPSPermissions.ps1` (community, Microsoft-referenced) |

---
## 🎓 Learning Pointers

- **`authorizationPolicy` and `permissionGrantPolicies` are two different objects that must both be understood together** — the first decides *whether* a policy applies to a user's default role, the second decides *what that policy actually allows*. Changing one without the other is the most common reason a consent-restriction change "doesn't seem to do anything." [MS Docs: Overview of user and admin consent](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/user-admin-consent-overview)

- **`microsoft-user-default-low` only restricts consent to permissions you've actually classified as low-impact** — if permission classification was never configured, this built-in policy has an empty effective allowlist and will appear to block everything, which reads as a bug rather than a missing prerequisite step. [MS Docs: Configure permission classifications](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/configure-permission-classifications)

- **Only Global Administrator and Privileged Role Administrator can grant tenant-wide admin consent for Microsoft Graph application permissions** — Application Administrator and Cloud Application Administrator, despite their broad-sounding names, are specifically excluded from this one capability. This exception explains most "reviewer can't approve" tickets and should be the first thing checked, not the last. [MS Docs: Grant tenant-wide admin consent](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/grant-admin-consent#prerequisites)

- **Illicit consent grants survive password resets and MFA changes because the attacker never needed the victim's credentials** — the OAuth token issued at consent time authenticates the malicious app directly. Any incident-response playbook that starts with "reset the user's password" as the primary remediation step is treating this like a credential-theft incident, which it structurally is not. [MS Docs: Detect and remediate illicit consent grants](https://learn.microsoft.com/en-us/defender-office-365/detect-and-remediate-illicit-consent-grants)

- **A user needs only one approving policy or authorization mechanism — policies are additive, never restrictive by their mere presence.** Auditing "what does our consent policy allow" requires enumerating every policy attached to every role a user holds, plus non-policy paths like Service Principal ownership, not just the tenant default. [MS Docs: Manage app consent policies](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/manage-app-consent-policies)

- **Granting tenant-wide admin consent and requiring user assignment are two separate decisions** — consent answers "is this app trusted at all," assignment answers "which users can actually use it." Skipping the second turns "we approved this app for the finance team's use case" into "every licensed user in the tenant now has this app's granted permissions available to them." [MS Docs: Assign users and groups to an app](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/assign-user-or-group-access-portal)
