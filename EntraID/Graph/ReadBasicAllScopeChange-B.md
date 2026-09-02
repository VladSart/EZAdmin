# User.ReadBasic.All Permission Scope Change — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## ⚠ A note before you start — this is a security fix, not a bug, and Microsoft says it "is not a breaking change." Treat that claim with healthy suspicion.

Per Microsoft's official **"What's new in Microsoft Entra: September 2026"** post (Tech Community, published 2026-09-01, authored by the CVP of Identity and Network Access): the delegated Graph permission **`User.ReadBasic.All`** is meant to grant an app access to only a small set of basic user properties. Microsoft has confirmed it **"accidentally allows the app to read app role assignments and license details of users"** as well — access that was never supposed to be part of this scope. The fix removes those two extra reads from what `User.ReadBasic.All` returns.

Microsoft's own framing: *"This update addresses a vulnerability and is not a breaking change. Customers using User.ReadBasic.All as intended should experience no disruption."* That statement is true only for apps that only ever wanted the basic profile fields. It is **not** true for any app in your tenant that (knowingly or not) has been relying on `User.ReadBasic.All` to read `appRoleAssignments` or license details — those calls will start returning incomplete data (or silently drop those fields/relationships) once the fix rolls out to your tenant, with no error and no warning banner. That silent-failure shape is exactly what this runbook exists to get ahead of.

**No specific rollout date for this particular item was published in the primary source** — unlike the same month's `memberOf` retirement (hard deadline, see `EntraID/Troubleshooting/MemberOfRetirement-B.md`) or the Security Administrator role expansion (rollout completing by end of September 2026), this permission-scope fix carries no stated effective date. Check your tenant's **Message Center** (Entra admin center > Message center, search "User.ReadBasic.All" or "permission scope") for a tenant-specific rollout window before assuming this has already landed — do not assume it is live yet, and do not assume it isn't.

---
## Triage

This is a proactive audit, not a symptom-driven fix — there's no error code to chase. The question is: **which apps in this tenant have been granted `User.ReadBasic.All` and might be relying on the accidental extra access?**

```powershell
# 1. Connect with read-only scopes
Connect-MgGraph -Scopes "DelegatedPermissionGrant.Read.All","Application.Read.All","Directory.Read.All" -NoWelcome

# 2. Live-resolve the CURRENT scope id/value for User.ReadBasic.All directly from your
#    tenant's Microsoft Graph service principal — do NOT hardcode a permission GUID from
#    memory or an old script; scope ids are stable but should always be confirmed live.
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$readBasicScope = $graphSp.Oauth2PermissionScopes | Where-Object { $_.Value -eq 'User.ReadBasic.All' }
$readBasicScope | Select-Object Id, Value, Type, AdminConsentDisplayName, AdminConsentDescription

# 3. Find every delegated permission grant in the tenant that includes User.ReadBasic.All
$grants = Get-MgOauth2PermissionGrant -All | Where-Object { $_.Scope -match '\bUser\.ReadBasic\.All\b' }
$grants | ForEach-Object {
    $client = Get-MgServicePrincipal -ServicePrincipalId $_.ClientId -ErrorAction SilentlyContinue
    [pscustomobject]@{
        AppDisplayName = $client.DisplayName
        AppId          = $client.AppId
        ConsentType    = $_.ConsentType   # "AllPrincipals" (admin, tenant-wide) or "Principal" (per-user)
        PrincipalId    = $_.PrincipalId   # populated only for per-user consent
        Scopes         = $_.Scope
    }
} | Format-Table -AutoSize
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| No grants found | No app in this tenant currently holds `User.ReadBasic.All` — nothing to remediate | Done, no further action |
| Grants found, `ConsentType = AllPrincipals` | Tenant-wide (admin) consent — highest-impact, affects every user the app acts on behalf of | → Fix 1 |
| Grants found, `ConsentType = Principal` | Per-user consent only — affects just that one user's delegated calls, but still needs the same code-level review | → Fix 1 (scoped to the one user/app pair) |
| App's code/vendor confirms it only reads basic profile fields | No action needed — this is the "used as intended" case Microsoft says is unaffected | → Fix 2 (document and close) |
| App's code/vendor confirms (or you can't confirm) it reads app role assignments or license data via this scope | Needs a permission change before the fix rolls out | → Fix 3 |

---
## Dependency Cascade

<details><summary>What actually changes, and what depends on it</summary>

```
Microsoft Graph delegated permission: User.ReadBasic.All
    │
    ├── INTENDED scope (unchanged by this fix)
    │     └── Basic profile properties: displayName, given/surname, mail,
    │           open extensions, photo — read-only, least-privileged by design
    │
    └── UNINTENDED scope (removed by this fix — the vulnerability being closed)
          ├── appRoleAssignments read access
          │     └── Any app reading "what app roles does this user have" via
          │           User.ReadBasic.All loses that data once the fix is live
          │           for your tenant — the call may still succeed, but the
          │           app-role-assignment data silently stops coming back
          └── License detail read access
                └── Any app reading a user's assigned licenses via
                      User.ReadBasic.All loses that data the same way

Least-privileged replacement permissions (per Microsoft's own guidance):
    ├── User.Read.All          — covers app role assignments AND license details
    │                             (sufficient alone if an app needs BOTH)
    └── LicenseAssignment.Read.All — covers ONLY license details, nothing else
          (use this instead of User.Read.All if an app needs license data only —
           narrower scope, easier admin consent conversation)
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the live scope definition for User.ReadBasic.All in your tenant**

```powershell
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
($graphSp.Oauth2PermissionScopes | Where-Object { $_.Value -eq 'User.ReadBasic.All' }).AdminConsentDescription
```
Expected: the description as currently published by Microsoft. Compare wording against what's quoted at the top of this runbook — if Microsoft has since updated the description to explicitly exclude appRoleAssignments/license data, that's your confirmation the fix has rolled out to this tenant.

**2. For each flagged app, determine what it actually calls (Graph itself cannot tell you this)**

```powershell
# Sign-in logs won't show which PROPERTIES were requested in a /users or /me call,
# only that a call was made under this scope. You must go to the source:
#   - the app's own documentation/support if third-party,
#   - or the app's source code / API call logs if first-party/internal.
# As a practical proxy, check whether the app also independently holds
# AppRoleAssignment.Read* or LicenseAssignment.Read* / License.Read* --
# if it does NOT, and it's a first-party integration you can inspect, that's
# a strong signal it may have been relying on User.ReadBasic.All's extra access.
Get-MgServicePrincipal -All | Where-Object {
    $_.AppId -in $grants.ClientId
} | Select-Object DisplayName, AppId, @{N='OtherAppRoles';E={
    (Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $_.Id -ErrorAction SilentlyContinue).AppRoleId
}}
```

**3. Test the replacement permission in a non-production app registration first**

```powershell
Connect-MgGraph -Scopes "User.Read.All"
(Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/users/<test-user-upn>?`$select=id,displayName,appRoleAssignments" -Method GET)
```
Expected: `appRoleAssignments` (and license data via a separate `licenseDetails` call) returns successfully under the new, correctly-scoped permission — confirming the migration path works before you touch a production app registration.

---
## Common Fix Paths

<details><summary>Fix 1 — Migrate an app off User.ReadBasic.All to the correct least-privileged permission</summary>

```powershell
# In the app registration's API permissions (Entra admin center > App registrations >
# <app> > API permissions), add whichever of these actually matches what the app needs:

#   Needs app role assignments only, or both app role assignments AND license data:
#     Add delegated permission  Microsoft Graph > User.Read.All
#     (Microsoft's own guidance: "If apps need to read both app role assignments and
#      license details, User.Read.All is sufficient.")

#   Needs license details only:
#     Add delegated permission  Microsoft Graph > LicenseAssignment.Read.All

# Grant admin consent for the new permission, THEN remove User.ReadBasic.All once the
# app is confirmed working end-to-end on the new scope — don't remove the old one first,
# or you'll create a live outage window for the app's basic-profile reads too.
```
**Rollback:** re-add `User.ReadBasic.All` and re-grant consent if the migration breaks something unexpected — this is purely a permission-grant change, fully reversible via the admin center or `New-MgOauth2PermissionGrant`/`Remove-MgOauth2PermissionGrant`.

</details>

<details><summary>Fix 2 — Confirmed unaffected: document and close</summary>

```powershell
# No code change needed. Record the finding so a future audit doesn't re-flag it:
#   - App name, AppId
#   - Confirmation source (vendor statement / code review / ticket reference)
#   - Date confirmed
# Add to your tenant's standing Graph-permission inventory if you keep one
# (see EntraID/Graph/Useful-Queries.md for a broader permission-inventory query).
```
**Rollback:** N/A — no change made.

</details>

<details><summary>Fix 3 — Can't confirm what the app reads (third-party, no vendor response, no source access)</summary>

```powershell
# Treat as affected until proven otherwise. Two options, in order of preference:

# Option A — proactively add the broader replacement permission now
#   Add User.Read.All alongside the existing User.ReadBasic.All, grant consent,
#   and monitor: if the app keeps working after the fix rolls out, remove
#   User.ReadBasic.All later. This avoids a surprise outage.

# Option B — if you cannot get admin consent approved in time, at minimum
#   document the app as "at risk, unconfirmed scope usage" so a sudden
#   loss of app-role/license data in that app is recognized immediately as
#   THIS change, not treated as a fresh, unexplained bug during triage.
```
**Rollback:** removing the added `User.Read.All` grant if it turns out to be unnecessary is a simple permission removal — no data or configuration risk either way.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — User.ReadBasic.All Permission Scope Change
================================================================
Date/Time (UTC)                 : [                    ]
Reported by                     : [                    ]
Tenant ID                       : [                    ]

App(s) affected
----------------
App display name / AppId        : [                    ]
Consent type (AllPrincipals/Principal) : [              ]
Confirmed relying on appRoleAssignments via User.ReadBasic.All? : [ ] Yes [ ] No [ ] Unknown
Confirmed relying on license details via User.ReadBasic.All?    : [ ] Yes [ ] No [ ] Unknown

Evidence collected
-------------------
[ ] Output of the Triage step 2/3 queries above (live scope grants)
[ ] Message Center post ID / rollout date for this tenant, if found
[ ] Vendor statement or code excerpt confirming scope usage
[ ] Test result from re-pointing the app at User.Read.All / LicenseAssignment.Read.All in non-prod

Escalation path: app owner (internal) or vendor support (third-party) to update the
app's requested permissions before the fix rolls out tenant-wide.
```

---
## 🎓 Learning Pointers

- **"Not a breaking change" is a claim about intended usage, not actual usage.** Microsoft is correct that an app using `User.ReadBasic.All` exactly as documented sees no change. The gap is that Microsoft itself confirms the permission has been over-granting access for an unknown period — meaning some number of apps in the wild are almost certainly relying on that accidental access without realizing it. Read every "not a breaking change" security-fix announcement as "not breaking for correct usage," and audit for incorrect usage anyway.

- **Least-privileged scope selection is context-dependent, not a fixed lookup.** This one change surfaces three different correct answers depending on what the app actually needs (`User.Read.All` for app-role-only or both; `LicenseAssignment.Read.All` for license-only) — there's no single universal replacement permission. Always match the replacement to the actual data need, not just the nearest-sounding permission name.

- **Graph's own directory has no reliable way to tell you what data an app's code actually reads.** Consent grants tell you what an app is *authorized* to read, never what it *does* read. This is a structural limitation worth remembering for any future permission-scope-narrowing change, not just this one — plan for a code/vendor-confirmation step every time, not just a PowerShell sweep.

- **Always resolve permission scope ids live, never from memory or an old script.** This runbook's own Triage step 2 queries the tenant's Microsoft Graph service principal directly for the current `User.ReadBasic.All` definition rather than hardcoding a GUID — permission ids are generally stable, but the description text (which is what actually tells you whether the fix has landed for your tenant) is not, and recall is not a substitute for a live check. [MS Docs: Microsoft Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference)

- **Change announcements without a stated rollout date still need tracking.** Unlike this same month's `memberOf` retirement (explicit November 3, 2026 deadline), this fix has no published effective date — that makes it easier to deprioritize and forget. Put a standing reminder to re-check Message Center rather than treating "no date given" as "not urgent." [MS Docs: What's new in Microsoft Entra](https://learn.microsoft.com/entra/fundamentals/whats-new)
