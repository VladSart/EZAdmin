# App Governance (Microsoft Defender for Cloud Apps) — Hotfix Runbook (Mode B: Ops)
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

App governance has almost no PowerShell/Graph surface of its own — it's a Defender XDR portal feature layered on top of ordinary Entra ID service principals and OAuth grants. Run these to establish context before touching the portal:

```powershell
# 1. Confirm Defender for Cloud Apps licensing is present (app governance rides on this SKU)
Connect-MgGraph -Scopes "Directory.Read.All"
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "CAS|CLOUD_APP_SECURITY|EMS|E5|MDATP" } |
    Select-Object SkuPartNumber, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}, ConsumedUnits |
    Format-Table -AutoSize

# 2. Confirm the account you're using holds one of the app-governance-capable roles
#    (Company/Global Admin, Compliance Admin, Compliance Data Admin, Global Reader,
#    Security Admin, Security Operator, Security Reader — NOT Cloud App Security
#    Admin alone; see Fix 1)
Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<your-object-id>'" -ExpandProperty roleDefinition |
    Select-Object @{N="Role";E={$_.RoleDefinition.DisplayName}}

# 3. Identify the OAuth app in question and whether it's currently enabled/disabled
#    (app governance's primary enforcement action is disabling the app's Service Principal)
Connect-MgGraph -Scopes "Application.Read.All"
Get-MgServicePrincipal -Filter "displayName eq '<app-display-name>'" |
    Select-Object DisplayName, AppId, AccountEnabled, @{N="VerifiedPublisher";E={$_.VerifiedPublisher.DisplayName}}

# 4. Check whether the app is the Microsoft first-party app (out of app governance scope entirely)
#    Microsoft's own first-party home tenant ID:
"f8cdef31-a31e-4b4a-93e4-5f571e91255a"
# If the app's AppOwnerOrganizationId matches this tenant, app governance will never show it —
# that is expected behaviour, not a bug.
Get-MgServicePrincipal -Filter "displayName eq '<app-display-name>'" | Select-Object DisplayName, AppOwnerOrganizationId

# 5. Recent Entra sign-in activity for the app (confirms it's actually in active use before you act on it)
Connect-MgGraph -Scopes "AuditLog.Read.All"
Get-MgAuditLogSignIn -Filter "appDisplayName eq '<app-display-name>'" -Top 10 |
    Select-Object CreatedDateTime, UserPrincipalName, AppDisplayName, @{N="Status";E={$_.Status.ErrorCode}}
```

**Interpretation table:**

| Result | What it means | Action |
|---|---|---|
| No CAS/EMS/E5-family SKU found | Tenant is not licensed for Defender for Cloud Apps | App governance cannot be turned on regardless of role — check licensing first |
| Role check returns only "Cloud App Security Administrator" | This account CAN turn app governance on, but CANNOT view or manage it once on | Add one of: Global Admin, Compliance Admin, Compliance Data Admin, Global Reader, Security Admin, Security Operator, Security Reader — see Fix 1 |
| `AccountEnabled = False` on the app's Service Principal | The app is currently deactivated — either by an app governance policy, manually, or Entra sign-in risk | Confirm the cause before reactivating (Fix 5) — check the Governance log first |
| `AppOwnerOrganizationId` = `f8cdef31-a31e-4b4a-93e4-5f571e91255a` | This is a Microsoft first-party app | App governance explicitly excludes these — you're looking in the wrong place; check Enterprise Apps / Entra sign-in logs instead |
| Sign-in activity is weeks/months old | App may be dormant | Still worth a policy review, but not an active-incident priority |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Defender for Cloud Apps license (standalone, or bundled in EMS E5 / M365 E5 / MDA add-on)
    │
    ├── Billing address NOT in an excluded region
    │       (Singapore, Poland, Italy, Qatar, Israel, Spain, Mexico, Taiwan)
    │       └── If excluded/unavailable → "Use app governance" toggle absent,
    │               waitlist consent is the only path (Fix 3)
    │
    ├── Turned on: Defender XDR > Settings > Cloud Apps > App governance > Use app governance
    │       └── Up to 10 HOURS before any data appears — empty ≠ broken (Fix 2)
    │
    ├── RBAC — TWO SEPARATE CAPABILITIES, not one:
    │       ├── Turn-on right: Global Admin, Security Admin, Compliance Admin,
    │       │       Compliance Data Admin, Cloud App Security Admin
    │       └── View/manage right (dashboard, policies, alerts, remediation):
    │               Global Admin, Compliance Admin, Compliance Data Admin,
    │               Global Reader, Security Admin, Security Operator, Security Reader
    │               — Cloud App Security Admin is EXCLUDED from this second list (Fix 1)
    │
    ├── Provisioning gate: BOTH Microsoft Defender for Cloud Apps AND Microsoft
    │       Defender XDR portals must each be accessed at least once, or alerts
    │       never flow through (Fix 6)
    │
    ├── Scope: OAuth apps registered to Entra ID, Google Workspace, or Salesforce
    │       └── Microsoft first-party apps (tenant f8cdef31-...) are excluded by design
    │
    ├── Detection engine
    │       ├── Threat detection alerts — ML/anomaly-based, always-on, not user-configurable
    │       └── Policy alerts
    │               ├── Predefined policies — on by default, can be deactivated,
    │               │       can carry a "Disable app" action (Fix 4)
    │               └── User-defined policies — app-usage or permissions-based,
    │                       templates or fully custom (20+ conditions)
    │
    └── Remediation surface
            ├── Microsoft 365 apps → Ban app / Disable app permissions / Unban / Enable
            │       (Entra Enterprise Applications-backed, one-time actions)
            └── Google Workspace / Salesforce apps → Revoke app / Notify user
                    (direct OAuth revocation, different mechanism per platform — Fix 7)
```

</details>

---

## Diagnosis & Validation Flow

**1. Establish which symptom you're actually looking at**

```
App governance shows no data / empty dashboard right after enabling?     → Fix 2
Admin enabled app governance but sees nothing in the portal?             → Fix 1
"Use app governance" option isn't in Settings at all?                    → Fix 3
A business app suddenly can't authenticate / users locked out?           → Fix 4 or Fix 5
Alerts never show up in Defender XDR alert queue?                        → Fix 6
Need to revoke a risky app's access right now?                           → Fix 7
Custom policy created but never triggers?                                → Fix 8
"We already blocked this in consent policies, why is it still active?"   → Fix 9
```

**2. Confirm licensing and role before anything else**

Run Triage steps 1–2. Most "app governance is broken" tickets are actually "app governance was never fully turned on" or "this admin has the wrong role" — confirm both before assuming a product fault.

**3. Check the Governance log for any prior automated action**

Defender XDR portal → Cloud Apps → Governance log. This is the single source of truth for every action app governance (or any Defender for Cloud Apps policy) has taken — including automatic app disables. Check this BEFORE reactivating anything, so you understand why it was disabled in the first place.

**4. Pull the specific policy that fired**

App governance → Policies → find the policy by name (shown on the alert or in the Governance log entry) → open it → check **Source** (Predefined vs. User defined), **Status** (Active/Disabled), and whether **Disable app** is checked under Policy action.

---

## Common Fix Paths

<details><summary>Fix 1 — Admin turned on app governance but the portal shows nothing for them</summary>

**Cause:** Cloud App Security Administrator grants the right to turn app governance ON, but **does not** grant the right to view or manage it afterward. This is the single most common "I enabled it and it's broken" ticket for this feature.

**Steps:**

1. Confirm the affected admin's roles:

```powershell
Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<object-id>'" -ExpandProperty roleDefinition |
    Select-Object @{N="Role";E={$_.RoleDefinition.DisplayName}}
```

2. If the only Cloud-Apps-related role held is **Cloud App Security Administrator**, add one of: Global Administrator, Compliance Administrator, Compliance Data Administrator, Global Reader, Security Administrator, Security Operator, or Security Reader.
3. Per Microsoft's own least-privilege guidance, prefer **Security Reader** (view-only) or **Security Operator** (view + remediate) over Global Administrator unless full policy authoring is genuinely required.
4. Re-check the portal — no propagation delay beyond normal Entra role-assignment replication (a few minutes).

**Rollback:** N/A — this is an additive role grant, not a destructive change.

</details>

<details><summary>Fix 2 — App governance dashboard is empty right after enabling</summary>

**Cause:** Expected behaviour. It takes **up to 10 hours** after first enabling app governance for data to populate. During this window, app counts and data-access statistics can also be inaccurate rather than simply absent.

**Steps:**

1. Confirm when app governance was actually turned on — Defender XDR → Settings → Cloud Apps → App governance (the toggle state and enablement timestamp are shown here).
2. If under 10 hours have elapsed, this is not a fault. Set expectation with the requester and re-check after the window closes.
3. If more than 10 hours have elapsed and the dashboard is still empty, check that the **Microsoft 365 connector** is connected (Settings → Cloud Apps → Connected apps → App Connectors → Office 365) — advanced-hunting visibility and some data surfaces depend on it separately from the app governance toggle itself.
4. Confirm the tenant's billing address isn't in one of the excluded regions (Fix 3) — a tenant that only partially qualifies can show an inconsistent state.

**Rollback:** N/A — no action taken, this is a waiting-period confirmation.

</details>

<details><summary>Fix 3 — "Use app governance" option is missing from Settings entirely</summary>

**Cause:** One of two reasons: the tenant's billing address is in an excluded region, or Microsoft is capacity-constrained for new tenants in general.

**Excluded regions (as of this writing):** Singapore, Poland, Italy, Qatar, Israel, Spain, Mexico, Taiwan.

**Steps:**

1. Confirm the tenant's billing address region in the Microsoft 365 admin center (`admin.microsoft.com` → Billing → Your bills & payments → Billing account).
2. If the billing address is in an excluded region: there is currently no self-service path — document this as a product limitation, not a config error.
3. If the billing address is NOT excluded and the option is still missing: capacity constraint. Join the waitlist (the consent prompt appears automatically in Settings → Cloud Apps in this state) — Microsoft notifies the tenant by email when app governance becomes available.
4. There is no supported way to force-enable app governance outside this flow — do not attempt Graph/API workarounds; none exist for this specific gate.

**Rollback:** N/A.

</details>

<details><summary>Fix 4 — A legitimate business app got auto-disabled by a predefined policy</summary>

**Cause:** A predefined app governance policy has its **Disable app** action turned on, and the app's behaviour matched the policy's conditions (often overly broad thresholds tripped by a legitimate but unusual usage pattern — e.g. a burst of API calls during a bulk import).

**Steps:**

1. Defender XDR → Cloud Apps → Governance log → find the disable event, confirm the policy name and timestamp.
2. Defender XDR → Cloud Apps → App governance → Policies → open the named policy → review its conditions against what the app actually did.
3. If the disable was a false positive: App governance → Overview → OAuth apps (or Google/Salesforce tab) → find the app → **Activate**. This restores the app's ability to authenticate to Entra ID immediately.
4. Tune the policy before this repeats: either narrow its conditions, raise its threshold, exclude this specific app, or uncheck **Disable app** and leave it as alert-only until you're confident in the tuning.

```powershell
# Confirm reactivation took effect
Connect-MgGraph -Scopes "Application.Read.All"
Get-MgServicePrincipal -Filter "displayName eq '<app-display-name>'" | Select-Object DisplayName, AccountEnabled
# Expect: AccountEnabled = True
```

**Rollback:** Re-disabling is the same Activate/Deactivate toggle — no data loss either direction, but users are signed out and must re-authenticate on reactivation.

</details>

<details><summary>Fix 5 — App shows AccountEnabled = False and nobody remembers why</summary>

**Cause:** Could be app governance, a manual admin action, or an unrelated Entra ID Protection risk-based action. Don't assume the cause — check the log.

**Steps:**

1. Governance log (Cloud Apps → Governance log) — search for the app name, look for a Ban/Disable entry and its policy source.
2. If nothing appears in the Governance log, check Entra ID sign-in/audit logs for a manual `Disable service principal` or Identity Protection risk-driven action instead — this is outside app governance's remit and needs the Entra-side playbook, not this one.
3. Only reactivate once you know the cause — reactivating a genuinely malicious/compromised app undoes the one protection that was working.

**Rollback:** N/A — investigation step, no changes made.

</details>

<details><summary>Fix 6 — App governance shows activity but alerts never appear in the Defender XDR alert queue</summary>

**Cause:** App governance alerts require BOTH the Microsoft Defender for Cloud Apps portal AND the Microsoft Defender XDR portal to have been accessed at least once by an admin — this is an undocumented-in-the-UI provisioning gate, not a licensing or policy problem.

**Steps:**

1. Have an admin with the correct role (Fix 1) sign in to `https://security.microsoft.com/cloudapps` at least once.
2. Have the same or another eligible admin sign in to `https://security.microsoft.com` (the main Defender XDR portal) at least once.
3. Allow a short propagation window, then re-check the alert queue: `https://security.microsoft.com/alerts` filtered by **Detection source: App Governance**.
4. If still empty after both portals have been visited, fall back to Fix 2 (the 10-hour data window may not have fully elapsed).

**Rollback:** N/A.

</details>

<details><summary>Fix 7 — Need to revoke a risky app's access right now</summary>

**Cause:** N/A — this is an active remediation action, not a bug. The mechanism **differs by platform** and getting this wrong is the most common "I revoked it but it still works" complaint.

**Steps — Microsoft 365 (Entra ID) apps:**

1. App governance → OAuth apps tab → select the app → **Ban app** (blocks future permission grants; does not revoke existing ones) or **Disable app permissions** (one-time revoke of ALL existing permissions, but does not prevent the app from being re-consented to later).
2. For a full stop, do both: Disable app permissions now, then Ban app to prevent re-consent.
3. Confirm via Graph that the app's existing grants are actually gone:

```powershell
Connect-MgGraph -Scopes "Application.Read.All"
$sp = Get-MgServicePrincipal -Filter "displayName eq '<app-display-name>'"
Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id
# Expect: both empty after "Disable app permissions"
```

**Steps — Google Workspace / Salesforce apps:**

1. App governance → Google or Salesforce tab → find the app row → three-dot menu → **Revoke app** (removes all permissions granted under Enterprise Applications in Entra ID for that connector) and/or **Notify user** (sends a customisable email telling the user to revoke it themselves in their Google/Salesforce security settings — app governance cannot force-revoke a Google/Salesforce-native grant the way it can an Entra one).

**Rollback:** Banned/disabled apps can be un-banned/re-enabled from the same menu if revoked in error — but any user who was mid-session will need to re-authorise from scratch.

</details>

<details><summary>Fix 8 — Custom user-defined policy created but never triggers</summary>

**Cause:** Either the policy conditions/thresholds don't actually match real app behaviour, or a stronger predefined policy is silently resolving the conflict first.

**Steps:**

1. Confirm the policy is **Active**, not saved as Disabled (App governance → Policies → Status column).
2. Re-read the condition set against the actual app's telemetry (App governance → OAuth apps → select the app → review its real permission/usage attributes) — a common miss is setting a permissions-based condition against an app that only has usage-based signals, or vice versa.
3. Check for a broader/stronger predefined policy already covering the same condition space — when multiple policies overlap, app governance resolves in favour of the stronger action, which can mask a narrower custom policy's own alert.
4. Export the policy list to CSV (Policies → Export) and sort by **Total alerts** to confirm zero is genuinely zero, not a filtered view — clear any severity/source filters first.

**Rollback:** N/A — diagnostic only.

</details>

<details><summary>Fix 9 — "We already blocked this app in App Consent Policies, why does App Governance still show it as active?"</summary>

**Cause:** These are two different, non-overlapping layers. App Consent Policies (see `EntraID/Troubleshooting/AppConsentPolicies-B.md`) govern whether a **new** consent grant is allowed to happen in the first place. App governance operates entirely **after** consent already exists — it monitors and can act on apps that already have access, regardless of how they got it (including apps consented before any policy existed, or consented under a different, looser policy at the time).

**Steps:**

1. Confirm the app already has an active OAuth grant (Triage step 3) — if so, App Consent Policies changes going forward will not retroactively remove it.
2. To actually remove existing access, use App Governance's own revoke path (Fix 7) — App Consent Policies has no mechanism to revoke a grant that already exists.
3. Going forward, tightening the relevant `permissionGrantPolicy` prevents this specific app (or apps like it) from being newly consented to again — but treat that as prevention, not remediation of the current grant.

**Rollback:** N/A — clarification/diagnostic fix path.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Microsoft Defender for Cloud Apps: App Governance
=======================================================================
Date/Time of issue:                ___________________________
Affected app (display name):       ___________________________
Affected app AppId:                ___________________________
Platform:  [ ] Microsoft 365 (Entra ID)   [ ] Google Workspace   [ ] Salesforce
Symptom observed:
  [ ] Dashboard empty / no data
  [ ] Admin enabled it but sees nothing (role gap)
  [ ] "Use app governance" option missing entirely
  [ ] Legitimate app auto-disabled
  [ ] AccountEnabled=False, cause unknown
  [ ] Alerts not reaching Defender XDR queue
  [ ] Revoke requested/completed, confirm effective
  [ ] Custom policy not triggering

Tenant ID:                         ___________________________
Defender for Cloud Apps license confirmed:   [ ] Yes  [ ] No — SKU: ___________
Billing region excluded from app governance: [ ] Yes  [ ] No  [ ] Unchecked
Admin's role (from Triage step 2):           ___________________________
App governance enabled-since timestamp:      ___________________________
10-hour data window elapsed:                 [ ] Yes  [ ] No

Relevant policy name (predefined/user-defined): ___________________________
Governance log entry (action, timestamp, policy source): ___________________________
AccountEnabled state at time of ticket:      [ ] True  [ ] False

Attached evidence:
  [ ] Governance log export
  [ ] Policy configuration screenshot
  [ ] Get-MgServicePrincipal output (AccountEnabled, VerifiedPublisher)
  [ ] Sign-in log export for the app

Support contact: https://admin.microsoft.com → Support → New service request
Product: Microsoft Defender for Cloud Apps — App governance
```

---

## 🎓 Learning Pointers

- **Two RBAC lists, not one.** The role that lets an admin flip the "Use app governance" toggle on is a strict superset check against a *narrower* list than the roles needed to actually see or manage anything afterward — and Cloud App Security Administrator is the one role that's on the first list but not the second. Always check both before assuming a bug. [MS Docs: Turn on app governance — Roles](https://learn.microsoft.com/en-us/defender-cloud-apps/app-governance-get-started#roles)

- **"Empty" is a valid state for up to 10 hours.** Set that expectation with whoever just turned it on before spending time troubleshooting a non-issue. [MS Docs: App governance FAQ](https://learn.microsoft.com/en-us/defender-cloud-apps/app-governance-faq)

- **Revocation is platform-specific — there is no single "revoke" button that works everywhere.** Microsoft 365 apps go through Ban/Disable app permissions (Entra-backed); Google Workspace and Salesforce apps go through a genuinely different Revoke app / Notify user flow because app governance doesn't have native write access to revoke a grant stored in a third-party platform's own consent system. [MS Docs: Governing connected apps](https://learn.microsoft.com/en-us/defender-cloud-apps/governance-actions)

- **App governance and App Consent Policies solve different problems and don't talk to each other.** Consent policies gate the *decision to grant*; app governance monitors and acts on *grants that already exist*. Tightening one does nothing to apps already holding access under the other. See `EntraID/Troubleshooting/AppConsentPolicies-A.md` for the consent-side layer this topic sits downstream of.

- **The Governance log is the ground truth for "why is this disabled."** Before reactivating any app, check it first — reactivating a policy-triggered disable without understanding why undoes a working control, and reactivating a manually/risk-triggered disable through the wrong playbook can leave the actual root cause (e.g. a compromised account) unaddressed. [MS Docs: Governing connected apps — Review the governance log](https://learn.microsoft.com/en-us/defender-cloud-apps/governance-actions#review-the-governance-log)

- **App governance never sees Microsoft's own first-party apps.** If a ticket concerns an app that turns out to belong to Microsoft's own tenant (`f8cdef31-a31e-4b4a-93e4-5f571e91255a`), the correct troubleshooting surface is Entra ID Enterprise Applications and sign-in logs, not app governance — this is by design, not a coverage gap. [MS Docs: App governance FAQ — what types of apps does app governance secure](https://learn.microsoft.com/en-us/defender-cloud-apps/app-governance-faq)
