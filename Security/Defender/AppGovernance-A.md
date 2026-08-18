# App Governance (Microsoft Defender for Cloud Apps) — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **app governance**, a feature set inside Microsoft Defender for Cloud Apps and Microsoft Defender XDR that delivers visibility, detection, and remediation specifically for **OAuth-enabled applications** registered against Microsoft Entra ID, Google Workspace, or Salesforce. Its job is to answer: which third-party apps have access to our organization's data, what permissions do they hold, are they behaving anomalously, and can we act on the risky ones without waiting for a full incident.

This is a distinct, narrower surface than [`MDA-A.md`](MDA-A.md)/[`MDA-B.md`](MDA-B.md), which covers the full Defender for Cloud Apps CASB product (Cloud Discovery/Shadow IT, session and access policies via Conditional Access App Control, file policies, general app connectors). App governance is one specific pillar inside that broader product, surfaced primarily through Defender XDR rather than the classic MDA portal, and focused exclusively on the OAuth-app risk surface.

It is also distinct from [`EntraID/Troubleshooting/AppConsentPolicies-A.md`](../../EntraID/Troubleshooting/AppConsentPolicies-A.md)/`-B.md`, which governs the **decision to grant** consent in the first place (who can consent, under what policy). App governance assumes consent already happened — legitimately or not — and operates on apps that already hold access: monitoring their behavior, alerting on anomalies, and providing one-click remediation (disable, ban, revoke) independent of how the original grant was authorized. It is not a substitute for tightening consent policy, and tightening consent policy does not retroactively touch anything app governance already tracks.

It is also distinct from [`AppRegistrations-A.md`](../../EntraID/Troubleshooting/AppRegistrations-A.md) (credential/Service Principal health for apps your own tenant registered and owns) and from [`CIEM-A.md`](CIEM-A.md) (cloud infrastructure entitlement risk for Azure/AWS/GCP identities — a different resource class entirely, sharing only the general "governance" vocabulary).

**Assumptions:**
- Microsoft Defender for Cloud Apps license present (standalone, or bundled in Microsoft 365 E5, EMS E5, or an equivalent add-on)
- Tenant billing address is not in one of app governance's currently excluded regions (Singapore, Poland, Italy, Qatar, Israel, Spain, Mexico, Taiwan)
- Reader has basic familiarity with Entra ID Service Principals, OAuth2 delegated vs. application permissions, and Enterprise Applications
- Coverage here is Microsoft 365 (Entra ID)-registered apps first, with Google Workspace/Salesforce noted where the mechanism genuinely differs

---

## How It Works

<details><summary>Full architecture — the OAuth app risk pipeline</summary>

### The four capability pillars

App governance is built around four functions applied to the same underlying object — a third-party OAuth app and its grants:

```
┌──────────────────────────────────────────────────────────────────────┐
│                         App Governance                                │
│                                                                        │
│  ┌───────────┐   ┌────────────┐   ┌────────────┐   ┌───────────────┐ │
│  │  Insights │   │ Governance │   │  Detection │   │  Remediation  │ │
│  │  (single  │──▶│ (proactive/│──▶│  (ML +     │──▶│  (disable /   │ │
│  │  dashboard│   │  reactive  │   │  anomaly + │   │  ban / revoke │ │
│  │  of every │   │  policies) │   │  policy    │   │  / notify)    │ │
│  │  non-MS   │   │            │   │  alerts)   │   │               │ │
│  │  OAuth app)│  │            │   │            │   │               │ │
│  └───────────┘   └────────────┘   └────────────┘   └───────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

### Scope of what is tracked

App governance tracks **non-Microsoft OAuth apps** registered against three identity providers: Microsoft Entra ID, Google Workspace, and Salesforce. For the Entra ID case specifically, it identifies and excludes apps whose home tenant is Microsoft's own "first-party app" tenant (ID `f8cdef31-a31e-4b4a-93e4-5f571e91255a`) — meaning Microsoft's own first-party applications (Outlook, Teams, SharePoint clients, etc.) never appear as governable objects here, even though they also use OAuth. Every other app — anything a user or admin has consented to that isn't Microsoft's own — is in scope, whether it was registered by your tenant, by a vendor, or by an individual user via self-service consent.

Defender for Cloud Apps' *broader* product also tracks OAuth apps accessing Microsoft 365 in a more limited way (via its general app connector/Cloud Discovery framework), but app governance layers extra out-of-box ML detections and a dedicated, highly customizable policy engine on top of that same underlying object set — this is the differentiator, not a separate data source.

### Two detection mechanisms, feeding one alert queue

1. **Threat detection alerts** — always-on, based on Microsoft threat intelligence and ML/anomaly-detection models. These are not configurable via policy; they represent Microsoft's own out-of-box judgment that an app is likely involved in an attack (e.g. sudden mass data exfiltration pattern, known-malicious app signature).
2. **Policy alerts** — driven by the policy engine, split into:
   - **Predefined policies**: shipped by app governance's own threat detection team, active by default, periodically updated by Microsoft without tenant-side action. Cover common attributes and behaviors (certification status, data-use patterns, API access errors, unused permissions).
   - **User-defined policies**: admin-authored, built from 20+ available conditions across app usage patterns and permission grants, either from a recommended template or fully custom. Two starting points: an **app usage policy** or a **permissions policy**.

Both alert types land in the same Defender XDR alert queue, tagged with **Detection source: App Governance**, and correlate with signals from other Defender XDR products (e.g. Defender for Endpoint) to build unified incidents. This is also the integration point for Microsoft Sentinel — app governance does not have its own separate Sentinel connector; it rides the general Defender XDR connector, which forwards all Defender XDR incidents/alerts (including app governance's) as a set.

### Policy conflict resolution

When multiple policies (predefined and/or user-defined) would apply overlapping actions to the same app/event, app governance does not stack or double-apply — it resolves to whichever action is **stronger** (e.g. Disable app wins over Alert-only). Unrelated actions from different policies (e.g. one policy alerting, another notifying a specific user) both fire independently. This mirrors the general Defender for Cloud Apps governance-conflict model described in `MDA-A.md`.

### Remediation is platform-asymmetric — the most important architectural fact for triage

For **Microsoft 365 (Entra ID) apps**, remediation actions operate through Entra ID's own Enterprise Applications object model:
- **Disable app permissions** — a one-time revoke of every currently-granted permission (does not block future re-consent)
- **Ban app** — blocks the app from receiving new consent going forward (does not revoke existing grants)
- **Enable app permissions** / **Unban app** — the reverse, restorative actions
- The predefined-policy **Disable app** action goes further: it disables the app's Service Principal (`accountEnabled = false`), which blocks the app from authenticating to Entra ID at all until manually reactivated (App governance → Activate)

For **Google Workspace / Salesforce apps**, there is no equivalent "disable the Service Principal" concept — app governance instead offers:
- **Revoke app** — removes all permissions previously granted under "Enterprise Applications" in Entra ID for that connector (note: this is still an Entra-side action even though the app itself lives in Google/Salesforce)
- **Notify user** — sends a customizable message instructing the end user to manually revoke the app's access themselves inside their Google Workspace/Salesforce security settings, because app governance cannot write directly into a third-party platform's own native consent store

This asymmetry is the single most common source of "I revoked it but it's still working" tickets — an admin applying the Microsoft-365 mental model (one-click, immediately effective) to a Google/Salesforce app, where the actual removal depends on either an Entra-side Enterprise Applications action or the end user completing a manual step in a platform app governance doesn't control.

### The provisioning gate that produces "no alerts ever appear"

App governance alerts will not flow into the Defender XDR alert queue until an eligible admin has accessed **both** the Microsoft Defender for Cloud Apps portal (`security.microsoft.com/cloudapps`) and the main Microsoft Defender XDR portal (`security.microsoft.com`) at least once each. This is a one-time provisioning step, undocumented in the enablement UI itself, and is a common cause of "app governance shows data on its own dashboard but nothing shows up as an alert" tickets.

### The 10-hour data-population window

After first turning on app governance, allow **up to 10 hours** before treating an empty or inaccurate-looking dashboard as a fault. During this window, app counts and data-access statistics can specifically be inaccurate (not just empty) — do not use early readings to make policy decisions.

</details>

---

## Dependency Stack

```
[Microsoft Defender for Cloud Apps license — standalone or bundled: EMS E5 / M365 E5]
        │
        ▼
[Billing-region eligibility check — excluded: Singapore, Poland, Italy, Qatar, Israel, Spain, Mexico, Taiwan]
        │
        ▼
[Turned on: Defender XDR > Settings > Cloud Apps > App governance > "Use app governance"]
        │         (waitlist consent flow if capacity-constrained even when region-eligible)
        ▼
[Data population — up to 10 hours before dashboard/statistics are reliable]
        │
        ▼
[RBAC — two independent gates]
        ├── Turn-on capability: Global Admin | Security Admin | Compliance Admin |
        │       Compliance Data Admin | Cloud App Security Admin
        └── View/manage capability: Global Admin | Compliance Admin |
                Compliance Data Admin | Global Reader | Security Admin |
                Security Operator | Security Reader
                (Cloud App Security Admin is NOT on this second list)
        │
        ▼
[Provisioning gate for alerts: BOTH Defender for Cloud Apps portal AND
        Defender XDR portal accessed at least once by an eligible admin]
        │
        ▼
[Tracked object universe: OAuth apps registered to Entra ID / Google Workspace /
        Salesforce, EXCLUDING Microsoft first-party apps (tenant f8cdef31-...)]
        │
        ├── Threat detection alerts (always-on, ML/anomaly, not configurable)
        │
        └── Policy alerts
                ├── Predefined policies (Microsoft-maintained, on by default)
                └── User-defined policies (admin-authored, templates or custom,
                        20+ conditions, app-usage OR permissions basis)
                        │
                        ▼
                [Policy conflict resolution — strongest action wins on overlap]
                        │
                        ▼
                [Remediation — platform-asymmetric]
                        ├── M365 (Entra ID) apps: Ban / Disable permissions /
                        │       Enable / Unban / Disable app (Service Principal)
                        └── Google Workspace / Salesforce apps: Revoke app /
                                Notify user (partial, Entra-side only)
                        │
                        ▼
                [Governance log — full action audit trail, retry/revert entry point]
                        │
                        ▼
                [Defender XDR alert queue — correlated with MDE/other signals,
                        forwarded to Sentinel via the shared Defender XDR connector]
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Dashboard/statistics empty right after enabling | 10-hour data-population window not yet elapsed | Enablement timestamp vs. current time |
| Admin turned it on but sees nothing | Cloud App Security Administrator role only grants turn-on, not view/manage | `Get-MgRoleManagementDirectoryRoleAssignment` against the account |
| "Use app governance" option absent from Settings | Billing region excluded, or Microsoft-side capacity constraint | M365 admin center billing address region |
| Legitimate app stopped authenticating | Predefined policy's "Disable app" action fired | Governance log for a matching Ban/Disable entry |
| `AccountEnabled = False`, cause unclear | Could be app governance, manual action, or Entra ID Protection risk — three different owners | Governance log first, then Entra sign-in/audit log if empty |
| Alerts never reach Defender XDR queue despite dashboard activity | Provisioning gate — one or both portals never visited by an eligible admin | Confirm both `security.microsoft.com/cloudapps` and `security.microsoft.com` have been opened |
| "Revoked" a Google/Salesforce app but it still authenticates | Revoke app only touches the Entra-side Enterprise Applications record; the platform-native grant needs the user's own action | Combine Revoke app with Notify user, or have the user self-revoke in Google/Salesforce security settings |
| Custom policy never triggers | Conditions don't match real telemetry, or a stronger predefined policy is masking it | Policies → Export CSV, review actual app attributes against the condition set |
| App shows as unmanaged/absent from app governance | It's a Microsoft first-party app (excluded by design), or it hasn't been consented to yet | Check `AppOwnerOrganizationId` against `f8cdef31-a31e-4b4a-93e4-5f571e91255a` |
| Sentinel shows no app governance-specific incidents | No dedicated connector exists — it rides the general Defender XDR connector | Confirm the Defender XDR-to-Sentinel connector itself is configured, not an app-governance-specific one |

---

## Validation Steps

**1. Confirm licensing and enablement state**

Defender XDR → Settings → Cloud Apps → App governance. Confirm the toggle is on and note the enablement timestamp.

Expected: toggle **On**, timestamp populated. If the option is absent entirely, this is a licensing/region/capacity gate, not a config issue (see Common Fix Paths in the companion `-B.md`, Fix 3).

**2. Confirm RBAC for the specific admin having trouble**

```powershell
Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<object-id>'" -ExpandProperty roleDefinition |
    Select-Object @{N="Role";E={$_.RoleDefinition.DisplayName}}
```

Expected: at least one of Global Admin, Compliance Admin, Compliance Data Admin, Global Reader, Security Admin, Security Operator, Security Reader. Cloud App Security Administrator alone is not sufficient for view/manage — this is the correct interpretation of a "role present but can't see anything" result, not an error to chase further.

**3. Confirm the provisioning gate has been satisfied**

There is no Graph/API-readable flag for this — it must be confirmed by asking whether both portals have genuinely been opened by an eligible admin, or by simply opening both now and waiting a short propagation window before re-checking the alert queue.

**4. Confirm scope boundary for a specific app in question**

```powershell
Connect-MgGraph -Scopes "Application.Read.All"
Get-MgServicePrincipal -Filter "displayName eq '<app-display-name>'" |
    Select-Object DisplayName, AppId, AccountEnabled, AppOwnerOrganizationId,
        @{N="VerifiedPublisher";E={$_.VerifiedPublisher.DisplayName}}
```

Expected: `AppOwnerOrganizationId` should NOT equal `f8cdef31-a31e-4b4a-93e4-5f571e91255a` for anything you expect app governance to track. If it does match, the app is a Microsoft first-party app and is correctly absent from app governance by design.

**5. Confirm a remediation action actually took effect**

For an M365 app after Disable app permissions:

```powershell
$sp = Get-MgServicePrincipal -Filter "displayName eq '<app-display-name>'"
Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id
```

Expected: both empty. A non-empty result after a reported "Disable app permissions" action means the action either didn't complete or targeted the wrong Service Principal object (check for duplicate app registrations under the same display name).

For a Google/Salesforce app after Revoke app: confirm via the Governance log that the action logged as successful, and separately confirm with the end user (or via that platform's own admin console, out of scope for this runbook) whether the platform-native grant is actually gone — Revoke app alone does not guarantee this.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the feature is actually reachable**
1. Licensing (Validation Step 1's prerequisite — Defender for Cloud Apps SKU present)
2. Billing region eligibility
3. Enablement toggle state and timestamp

**Phase 2 — Confirm the right person can see the right things**
1. RBAC check against the two-list model (Validation Step 2)
2. Both-portals provisioning gate (Validation Step 3)

**Phase 3 — Confirm the object in question is actually in scope**
1. First-party app exclusion check (Validation Step 4)
2. Platform identification — M365 vs. Google Workspace vs. Salesforce, since every remaining troubleshooting step diverges by platform from here

**Phase 4 — Confirm policy/detection behavior**
1. Governance log review for any prior automated action
2. Policy list review (predefined vs. user-defined, Active vs. Disabled, action configuration)
3. Conflict-resolution awareness if multiple policies could plausibly apply

**Phase 5 — Confirm remediation actually landed**
1. Platform-appropriate post-action verification (Validation Step 5)
2. For Google/Salesforce: confirm user-side completion where "Notify user" was the chosen path, since app governance cannot verify this on its own

---

## Remediation Playbooks

<details><summary>Playbook 1 — Standing up app governance in a new tenant</summary>

1. Confirm Defender for Cloud Apps licensing and billing-region eligibility.
2. Turn on app governance (Defender XDR → Settings → Cloud Apps → App governance → Use app governance).
3. Assign at least one admin a view/manage-capable role (not Cloud App Security Admin alone) — prefer Security Reader or Security Operator per least-privilege guidance unless full authoring is required.
4. Have that admin visit both `security.microsoft.com/cloudapps` and `security.microsoft.com` at least once to satisfy the alert-provisioning gate.
5. Connect the Microsoft 365 connector (Settings → Cloud Apps → Connected apps → App Connectors → Office 365) for enhanced advanced-hunting visibility into OAuth-app-accessed resources.
6. Wait out the 10-hour data-population window before drawing any conclusions from the dashboard.
7. Review the full predefined policy list once data has populated — confirm which carry a "Disable app" action and decide, per policy, whether that's the desired default posture for this tenant (alert-only is the safer starting point for a first rollout).

**Rollback:** Turning app governance off again does not appear to have a documented one-click path in current Microsoft guidance at the time of writing — treat enablement as a durable decision and pilot in alert-only mode first rather than planning to reverse it.

</details>

<details><summary>Playbook 2 — Responding to a confirmed illicit/malicious OAuth app</summary>

1. Confirm the app is genuinely malicious (verified publisher status, permission scope vs. stated purpose, threat detection alert detail) rather than merely unusual — see the five-point evaluation framework in `EntraID/Troubleshooting/AppConsentPolicies-A.md`.
2. Platform-appropriate immediate action:
   - M365 app: Disable app permissions (revoke existing grants) immediately, then Ban app (block re-consent).
   - Google/Salesforce app: Revoke app immediately, and Notify user in parallel (do not wait on the notification before revoking).
3. Confirm removal via Graph (Validation Step 5).
4. Check for any other tenants/users who separately consented to the same malicious app (`Get-MgServicePrincipalOauth2PermissionGrant`/`Get-MgServicePrincipalAppRoleAssignedTo` return every grant across the tenant, not just the one that triggered the alert) — a phishing campaign rarely targets a single user.
5. Cross-reference against `EntraID/Troubleshooting/AppConsentPolicies-A.md`'s illicit consent grant guidance for the Purview Audit log review and any credential-adjacent follow-up (note: this is explicitly NOT a credential-reset scenario — the attacker never needed the victim's password).
6. Document in the Governance log context (the log itself is automatic) and file a permanent record for the incident report.

**Rollback:** N/A by design — this playbook is itself the remediation, not a reversible test.

</details>

<details><summary>Playbook 3 — Recovering from an over-aggressive predefined-policy auto-disable</summary>

1. Governance log → identify the disable event, policy name, and timestamp.
2. Reactivate the app (App governance → Overview → OAuth apps/Google/Salesforce tab → select app → Activate).
3. Confirm reactivation via Graph (`AccountEnabled = True`).
4. Open the offending policy → review its condition set against the app's actual behavior at the time of the trigger.
5. Choose one: narrow the condition thresholds, add an explicit app exclusion, or uncheck the **Disable app** action and run alert-only for a probation period before re-enabling auto-disable.
6. Communicate to the app's business owner that a re-trigger is possible until tuning is validated, and set a follow-up review date.

**Rollback:** Re-disabling later (if the tuning attempt still proves too permissive) uses the same Activate/Deactivate toggle — no destructive state either direction beyond forcing affected users to re-authenticate.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects the Graph-readable subset of app governance context for an
    escalation ticket — licensing signal, RBAC state for a given admin,
    and the target app's Service Principal state.
.NOTES
    Portal-only data (Governance log entries, policy configuration, alert
    detail, dashboard statistics) is NOT retrievable via this script — export
    those manually from the Defender XDR portal and attach alongside this
    output. See Security/Defender/Scripts/Get-AppGovernanceReadinessAudit.ps1
    for the fuller pre-enablement/ongoing readiness audit.
#>
param(
    [Parameter(Mandatory)][string]$AppDisplayName,
    [string]$AdminObjectId
)

Connect-MgGraph -Scopes "Directory.Read.All","Application.Read.All","RoleManagement.Read.Directory" -NoWelcome

Write-Host "=== Licensing signal ===" -ForegroundColor Cyan
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "CAS|CLOUD_APP_SECURITY|EMS|E5|MDATP" } |
    Select-Object SkuPartNumber, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}, ConsumedUnits

if ($AdminObjectId) {
    Write-Host "`n=== Admin RBAC ===" -ForegroundColor Cyan
    Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$AdminObjectId'" -ExpandProperty roleDefinition |
        Select-Object @{N="Role";E={$_.RoleDefinition.DisplayName}}
}

Write-Host "`n=== Target app Service Principal state ===" -ForegroundColor Cyan
$sp = Get-MgServicePrincipal -Filter "displayName eq '$AppDisplayName'"
$sp | Select-Object DisplayName, AppId, AccountEnabled, AppOwnerOrganizationId,
    @{N="VerifiedPublisher";E={$_.VerifiedPublisher.DisplayName}}

Write-Host "`n=== Existing grants ===" -ForegroundColor Cyan
if ($sp) {
    Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id |
        Select-Object ConsentType, Scope, PrincipalId
    Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id |
        Select-Object PrincipalDisplayName, AppRoleId
}

Write-Host "`nManually attach: Governance log export, Policies CSV export, and the alert detail pane screenshot from security.microsoft.com/cloudapps." -ForegroundColor DarkGray
```

---

## Command Cheat Sheet

```powershell
# Licensing check
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "CAS|CLOUD_APP_SECURITY|EMS|E5" }

# RBAC check for a given admin
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<id>'" -ExpandProperty roleDefinition

# Find a Service Principal and its enablement state
Get-MgServicePrincipal -Filter "displayName eq '<app>'" | Select-Object DisplayName, AppId, AccountEnabled

# Confirm first-party exclusion boundary
Get-MgServicePrincipal -Filter "displayName eq '<app>'" | Select-Object AppOwnerOrganizationId
# Microsoft's own tenant: f8cdef31-a31e-4b4a-93e4-5f571e91255a

# Pull all delegated + application grants for an app (post-remediation check)
$sp = Get-MgServicePrincipal -Filter "displayName eq '<app>'"
Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id

# Recent sign-in activity for an app
Get-MgAuditLogSignIn -Filter "appDisplayName eq '<app>'" -Top 10

# Portal deep links (no Graph equivalent exists for these)
# Enablement:      security.microsoft.com/cloudapps/settings?tabid=activateAppG
# Overview/OAuth:  security.microsoft.com/cloudapps  -> App governance -> Overview
# Policies:        security.microsoft.com/cloudapps  -> App governance -> Policies
# Governance log:  security.microsoft.com/cloudapps  -> Governance log
# Alerts:          security.microsoft.com/alerts     -> filter Detection source: App Governance
```

---

## 🎓 Learning Pointers

- **App governance's remediation model is asymmetric by platform, and that asymmetry is architectural, not a gap Microsoft is expected to close.** Microsoft 365 apps live in Entra ID, which app governance can write to directly (disable, ban). Google Workspace and Salesforce apps have their own separate, external consent stores app governance cannot write into directly — Revoke app only ever touches the Entra-side record of that connection. Build this distinction into any client-facing SLA language around "how fast can we cut off a risky app." [MS Docs: Governing connected apps](https://learn.microsoft.com/en-us/defender-cloud-apps/governance-actions)

- **The Cloud App Security Administrator role is a trap for admins who only read the role name.** It sounds like the obvious role for "cloud app security" work, and it does let you flip the enablement toggle — but Microsoft's own guidance explicitly recommends against relying on it and instead using a narrower, purpose-fit role for ongoing view/manage work. [MS Docs: Turn on app governance — Roles table](https://learn.microsoft.com/en-us/defender-cloud-apps/app-governance-get-started#roles)

- **App governance has almost no dedicated Graph API surface.** Unlike many Defender products, there is no `Get-MgSecurityAppGovernance*`-style cmdlet family — everything portal-visible (policies, alerts, Governance log, dashboard) is portal-only today. Scripts can only reach the underlying Entra ID objects (Service Principals, OAuth grants) that app governance happens to act upon, not app governance's own configuration or alert state. Plan evidence collection accordingly. [MS Docs: App governance FAQ](https://learn.microsoft.com/en-us/defender-cloud-apps/app-governance-faq)

- **First-party app exclusion is a hard, tenant-ID-based rule, not a display-name heuristic.** Don't assume an app is Microsoft's own because its name sounds official — verify against `AppOwnerOrganizationId = f8cdef31-a31e-4b4a-93e4-5f571e91255a` before concluding app governance's silence on an app is a coverage bug.

- **Predefined policies change without any tenant-side action or log entry, similar to Entra ID's living consent policies.** Microsoft's app governance threat detection team modifies conditions and adds new predefined policies over time. A predefined policy that never fired last quarter can start firing today with no configuration change on your side — factor this into "what changed" triage before assuming a client-side misconfiguration. [MS Docs: Predefined app policies](https://learn.microsoft.com/en-us/defender-cloud-apps/app-governance-predefined-policies)

- **Alerts share the Defender XDR queue and Sentinel connector with every other Defender XDR product — there is no app-governance-specific integration to separately troubleshoot.** If Sentinel isn't receiving app governance incidents, the fault (or missing config) is almost always in the general Defender XDR-to-Sentinel connector, not anything specific to app governance. [MS Docs: App governance FAQ — Sentinel integration](https://learn.microsoft.com/en-us/defender-cloud-apps/app-governance-faq)
