# Entra ID Governance — Account Discovery — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Account Discovery — the Entra ID Governance / Entra Suite feature that retrieves every user account from a provisioned target application and classifies it against Microsoft Entra ID as a local (orphan), unassigned-but-matched, or assigned-and-managed account
- The correlation/matching mechanism (direct matching attribute only), the identity classification model, and the Microsoft Graph beta reporting surface (`identityCorrelation` / `correlatedIdentity`)
- Licensing and RBAC gates specific to running discovery (distinct from the RBAC needed merely to read a completed report)
- The supported vs. explicitly unsupported connector-type matrix
- Bulk remediation via the Microsoft-provided `Assign-CorrelatedUsers.ps1` script and its rules-file model
- Downstream integration with entitlement management (access packages) and Lifecycle Workflows

**Does not cover:**
- **Enterprise Application (SCIM) provisioning configuration itself** (credentials, attribute mappings other than the matching attribute, quarantine, cycle mechanics) — Account Discovery is layered on top of an already-configured, already-tested provisioning job; see `EnterpriseAppProvisioning-A.md`/`-B.md` for that layer
- **Entra Cloud Sync** and **Cross-tenant synchronization** — both are explicitly on Account Discovery's unsupported-connector list; see `CloudSync-A.md`/`-B.md` and `CrossTenant-A.md`/`-B.md` respectively for their own (unrelated) troubleshooting
- **Entitlement management (access packages) configuration** beyond the single step of assigning a correlated user to one — policy design, approval chains, and access package lifecycle are their own topic
- **Lifecycle Workflows task authoring** — Account Discovery's Learn documentation references LCW as a downstream governance step for discovered accounts, but this file does not cover building workflows; see `LifecycleWorkflows-A.md`/`-B.md`
- **Microsoft Entra ID Governance licensing/feature matrix in general** — only the specific add-on/Suite gate that unlocks Account Discovery is covered here, not the full Governance feature-to-SKU breakdown

**Assumes:**
- Microsoft Graph PowerShell SDK installed and connected via `Connect-MgGraph`, with at minimum `ProvisioningLog.Read.All` (read a completed report) and `Application.Read.All`/`Directory.Read.All` (resolve Service Principal and role context) scopes; `Application.ReadWrite.All` and entitlement-management write scopes only if performing bulk remediation
- Reader/operator triggering NEW discovery runs holds Application Administrator, Cloud Application Administrator, or Hybrid Identity Administrator (a narrower set than what can merely read a report)
- The target Enterprise Application already has automatic provisioning configured with a successful Test Connection

---
## How It Works

<details><summary>Full architecture — what Account Discovery actually does</summary>

### The problem it solves

When an organization turns on automatic provisioning for an application that already has an existing user base (the overwhelmingly common case — very few SaaS rollouts start from zero), the target application already contains accounts Entra ID has never heard of: former employees whose app account was never cleaned up, service/shared accounts created directly in the app, users provisioned through some earlier process, or accounts a data-quality issue simply failed to match. Provisioning itself has no visibility into this population — it only ever acts on objects it already knows are in scope. Account Discovery is a separate, report-generating feature that closes this specific visibility gap.

### The correlation model

Discovery retrieves the **full list of user accounts** from the target application (via the same SCIM connector provisioning already uses) and attempts to correlate each one against Microsoft Entra ID using the provisioning job's own configured **matching attribute** — the same "Match objects using this attribute" setting that governs ordinary provisioning's create-vs-update decision. This is a deliberate design choice: discovery reuses the existing join key rather than introducing a second, independently-configured one, which also means a broken/wrong matching attribute breaks both provisioning *and* discovery identically.

**Hard constraint: the matching attribute must be a DIRECT mapping.** Expression-based mappings (concatenations, substring transforms, function chains — otherwise fully supported for ordinary attribute mapping) are explicitly unsupported for correlation. If multiple matching attributes happen to be configured on the job, only the first one is used for discovery, regardless of how the others are ordered or intended.

### Classification

Every retrieved target-app account lands in exactly one bucket:

| Portal label | Graph `status` value | Meaning |
|---|---|---|
| Local accounts | `uncorrelated` | No matching Entra ID user found via the matching attribute — a genuine orphan, or a data-quality miss |
| Unassigned users | `correlatedNotAssigned` | Matched to a real Entra ID user, but that user has no app role assignment to this Enterprise Application — provisioning has never been managing this account despite the person existing in the directory |
| Assigned users | `correlatedAssigned` | Matched to an Entra ID user who IS assigned — fully managed by provisioning already; informational only |
| *(not named as a distinct bucket in the portal UI)* | `failToCorrelate` | The correlation *attempt itself* errored for this specific identity — not a clean no-match, a processing failure. The portal's own how-to documentation describes only three categories; this fourth Graph-only status is easy to miss if triage is done purely through the UI |

### Execution model — portal-triggered, Graph-readable

Discovery is started from **Enterprise Apps → [App] → Provisioning → Discover identities** (or the Graph-equivalent action is simply absent — there is no documented POST/start endpoint in the beta API). Once running, it queries the target app's full user list — subject to whatever pagination the connector implements — and can take anywhere from a documented 30-minute minimum up to 12+ hours for very large account populations (Microsoft's own example: ~250K accounts). The completed run produces an `identityCorrelation` report object, readable via `GET /beta/reports/correlations`, with a `/identities` sub-resource returning every individual `correlatedIdentity` result.

This portal-trigger / Graph-read split is architecturally deliberate but easy to miss operationally: an MSP trying to build a scheduled/automated discovery-refresh pipeline can read results programmatically but cannot currently kick off the run itself without a human (or UI-automation) step.

### Connector support matrix

Account Discovery requires the target connector to support SCIM pagination per **RFC 7644 §3.4.2.4**. Microsoft documents two explicit lists rather than a single blanket "SCIM apps work" statement:

**Connectors with established, consistently-complete discovery results:** Atlassian Cloud, generic SCIM, Salesforce, SAP Cloud Identity Services, ECMA (the connector family covering on-prem SQL, LDAP, Web Services, and PowerShell targets), and GitHub Enterprise Cloud (with a documented pagination-related limitation of its own).

**Connectors explicitly unsupported, by design, not as a bug:** HR-driven provisioning (Workday, SAP SuccessFactors, API-driven provisioning), ServiceNow, Amazon Web Services (AWS), Snowflake, Cross-tenant synchronization, Cloud sync, and Group provisioning to AD. Two of these — Cross-tenant sync and Cloud sync — are themselves separately-documented provisioning surfaces in this repo (`CrossTenant-A.md`/`-B.md`, `CloudSync-A.md`/`-B.md`); their exclusion from Account Discovery is a hard product boundary, not a configuration gap to chase.

All other connectors fall into a third, unlisted category: discovery *can* be enabled, but actual results depend on whether the specific target implements listing + pagination correctly — a 0-result report for one of these should be diagnosed against the matching-attribute and pagination checks below rather than assumed broken outright.

### Downstream remediation paths

Three ways to act on discovery results, in increasing order of scale:

1. **Manual, per-account, in the portal** — assign an individual unassigned-but-matched user to the app or an access package directly from the Discovery UX results grid.
2. **Bulk, script-driven** — Microsoft publishes `Assign-CorrelatedUsers.ps1` (downloadable via `aka.ms/AssignCorrelatedUsersPowerShell`), which reads the correlation results and assigns matched users to the Enterprise Application and/or entitlement-management access packages, optionally driven by a rules CSV for conditional, attribute-based assignment logic (`RuleGroup`/`PropertyName`/`Operator`/`Value`/`AccessPackageId`/`PolicyId` columns; `-DryRun`, duplicate-assignment detection, and a full CSV audit trail are all built in).
3. **Governance handoff** — once a discovered identity is assigned (app role or access package), it becomes subject to the rest of the Entra ID Governance stack: Access Reviews can recertify the assignment, Lifecycle Workflows can automate its future disable/removal on a joiner-mover-leaver trigger. Account Discovery's own documentation explicitly frames this as the intended end state — discovery finds and classifies, it does not itself govern anything ongoing.

</details>

---
## Dependency Stack

```
Layer 5 — Target application's user list + SCIM pagination support (RFC 7644 §3.4.2.4)
          — a vendor-side capability Entra ID cannot influence; several connector
            types are architecturally excluded regardless of pagination support
Layer 4 — Microsoft Entra ID Governance add-on license, or Microsoft Entra Suite
          — hard license gate on the "Discover identities" portal action itself
Layer 3 — RBAC to TRIGGER discovery: Application Administrator, Cloud Application
          Administrator, or Hybrid Identity Administrator
          (narrower than the RBAC that can merely READ a completed report —
          Global Reader, Reports Reader, Security Reader/Operator/Administrator,
          and Enterprise Application Owner are all sufficient for reads only)
Layer 2 — An existing, working provisioning job for the app
          (successful Test Connection; see EnterpriseAppProvisioning-A.md Layer 4/5)
Layer 1 — The provisioning job's matching attribute, and specifically that it is
          a DIRECT mapping (Expression-type matching attributes silently break
          correlation with error code MissingJoiningProperty — they work fine
          for ordinary provisioning create/update logic, only correlation rejects them)
Layer 0 — The identityCorrelation report itself (portal-triggered only) and its
          Graph-readable /identities collection — four possible per-identity
          statuses: uncorrelated / correlatedNotAssigned / correlatedAssigned /
          failToCorrelate
```

A gap at Layer 4 or 3 means the feature is simply unavailable to the operator — no amount of Layer 0-2 troubleshooting will surface a button that licensing/RBAC has hidden. A gap at Layer 1 (wrong matching-attribute type) is the single most common whole-report failure once licensing/RBAC/connectivity are confirmed healthy.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| "Discover identities" button doesn't appear anywhere in the Provisioning blade | No Entra ID Governance add-on / Entra Suite license on the tenant | `Get-MgSubscribedSku`, best-effort SKU name match |
| Button appears but selecting it produces an access-denied-style error | Operator lacks Application Administrator / Cloud Application Administrator / Hybrid Identity Administrator | Role assignment check against the signed-in principal |
| `GET /beta/reports/correlations` returns an empty collection for the app | Discovery has genuinely never been run for this Service Principal | Trigger a first run via the portal |
| Report exists with `error.code = MissingJoiningProperty` | Matching attribute is Expression-type, not Direct | Portal: Mappings → Show advanced options → matching attribute type |
| Report exists, `error` is null, but almost every identity is `uncorrelated` | Matching attribute value mismatch/staleness on one or both sides, or the population genuinely is mostly local accounts | Spot-check 2-3 known-good users' attribute values directly |
| A user known to exist in Entra ID shows `uncorrelated` instead of correlated | The matching attribute in use isn't the one that's actually unique/populated for that user (e.g. `mail` changed after original provisioning) | Compare the specific matching-attribute value on both sides for that one user |
| Individual identity shows `failToCorrelate` rather than `uncorrelated` | The correlation *attempt* errored for that identity specifically — check its own `error` sub-object | `GET .../identities?$filter=status eq 'failToCorrelate'` |
| Discovery has been "in progress" far longer than expected | Large target-app account population — 250K accounts can legitimately take 12+ hours | `endDateTime` still absent on the report object; compare against known target account count |
| App is Workday/SuccessFactors/ServiceNow/AWS/Snowflake/Cross-tenant-sync/Cloud-sync/Group-to-AD | Explicitly unsupported connector type — architectural, not a bug | Confirm connector type against the supported/unsupported matrix before further troubleshooting |
| Discovery results seem incomplete for GitHub Enterprise Cloud specifically | A documented, connector-specific SCIM listing/pagination limitation for that vendor | Cross-check against Microsoft's GitHub Enterprise Cloud SCIM listing-limitations reference |
| Trying to trigger discovery from a script/automation pipeline does nothing | No documented Graph POST/start endpoint exists for this action — it is portal-trigger-only | Confirm via `reportroot-list-correlations` — List/Get only, no create method documented |
| `Assign-CorrelatedUsers.ps1` runs but assigns nobody | Wrong `-ServicePrincipalId` (Application/client ID used instead of the Service Principal object ID), or a rules CSV that matches nothing | Re-run with `-DryRun` and inspect the output CSV before assuming a permissions problem |
| Multiple matching attributes configured, discovery seems to ignore the "obvious" one | Only the FIRST configured matching attribute is used for correlation | Confirm ordering in the Mappings advanced view |

---
## Validation Steps

1. **License present.**
   ```powershell
   Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "GOVERNANCE|EntraSuite|Entra_Suite" }
   ```
   Expected: at least one matching SKU with `ConsumedUnits` > 0. This is a best-effort name match — confirm against the tenant's actual purchased SKUs in the M365 admin center rather than trusting the string match alone.

2. **Operator RBAC for triggering discovery.**
   ```powershell
   Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<UserObjectId>'" -ExpandProperty roleDefinition |
     Select-Object -ExpandProperty RoleDefinition | Select-Object DisplayName
   ```
   Expected: Application Administrator, Cloud Application Administrator, or Hybrid Identity Administrator present.

3. **Provisioning job is healthy.**
   ```powershell
   (Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id).Status
   ```
   Expected: `Code = Active` with at least one prior successful execution. Bad: no job, or a job that has never completed an initial cycle.

4. **Matching attribute is a direct mapping.** Portal-only check: **Provisioning → Edit provisioning → Mappings → [Object] → Show advanced options → Match objects using this attribute**. Expected: source is a plain attribute name. Bad: source shows an `Expression()` transform.

5. **Connector type is supported.** Cross-reference against the confirmed-good / explicitly-unsupported lists in How It Works. Expected: app is SCIM, ECMA, or one of the named confirmed-good connectors. Bad: app is on the unsupported list — stop troubleshooting, no fix exists inside this feature.

6. **Report completed successfully.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/reports/correlations/$reportId"
   ```
   Expected: `endDateTime` populated, `error` null. Bad: `error` populated (read `error.code`/`error.message` directly — don't guess at the cause) or `endDateTime` absent well past a reasonable duration for the target's account count.

7. **Identity-level results are internally consistent.**
   ```powershell
   (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/reports/correlations/$reportId/identities?`$top=999").value |
     Group-Object status | Select-Object Name, Count
   ```
   Expected: a plausible split across the four statuses given known headcount and app history. Bad: 100% `uncorrelated` on an app that's been provisioning successfully for a long time — almost always points back to Layer 1 (matching attribute) rather than a genuinely all-orphan population.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Is the feature even available to this operator?**
Confirm license (Layer 4) and RBAC (Layer 3) before anything else. A missing button is a licensing/RBAC symptom, not a discovery-engine fault, and no amount of Graph querying will fix it.

**Phase 2 — Is there a healthy provisioning job underneath?**
Account Discovery cannot produce meaningful results against a provisioning job that has never had a successful Test Connection or initial cycle. If Layer 2 isn't solid, fix that first via `EnterpriseAppProvisioning-B.md`.

**Phase 3 — Is the matching attribute correctly typed?**
This is the highest-yield single check in this entire topic. A Direct-vs-Expression mismatch explains the large majority of both whole-report failures (`MissingJoiningProperty`) and suspiciously-high `uncorrelated` counts.

**Phase 4 — Is the connector type even supported?**
Rule out the explicit unsupported-connector list before investing further diagnostic time — this is a binary architectural gate, not something to troubleshoot around.

**Phase 5 — Read the report's own error field, then the identity-level detail.**
Treat `error`/`error.code` on the report object as ground truth over any assumption. Only descend into individual `correlatedIdentity` results once the report-level state is confirmed healthy.

**Phase 6 — Escalate to Microsoft only after Phases 1-5 clear.**
If license, RBAC, provisioning health, matching-attribute type, and connector support are all confirmed correct and the report still fails or produces implausible results, capture the exact `error.code`/`error.message` and escalate — this is one of the newer Entra ID Governance surfaces and genuinely undocumented failure modes are more plausible here than in a long-mature feature.

---
## Remediation Playbooks

<details><summary>Playbook 1 — From-scratch onboarding: bring a legacy app under full governance</summary>

1. Confirm license (Entra ID Governance add-on / Entra Suite) and operator RBAC (Application/Cloud Application/Hybrid Identity Administrator) before starting.
2. Confirm the app's provisioning job has a successful Test Connection and at least one completed cycle.
3. Audit the matching attribute configuration; if it's an Expression mapping, rebuild it as a direct attribute first (expect a full provisioning restart as a side effect — this is intentional and unavoidable).
4. Run **Discover identities**. For a large target app, plan for this to run unattended for hours, not minutes.
5. Review results by category: for `correlatedNotAssigned` (Unassigned users), assign to the app or an access package; for `uncorrelated` (Local accounts), triage each as legitimate-but-unmatched (fix the source data and re-run discovery), a service/shared account (leave alone, out of scope for individual-identity governance), or a genuine orphan (remove from the target app per that app's own offboarding process — Entra ID cannot delete a target-app-local account itself).
6. Once assignments are in place, configure Access Reviews and/or Lifecycle Workflows for ongoing governance of the now-managed population — Account Discovery's job ends at classification and initial assignment, it does not provide recurring governance on its own.

**Rollback:** unassigning an app role or access package assignment made during this playbook is non-destructive and reversible via the normal assignment-removal path; re-running discovery after any correction is always safe since discovery itself makes no changes to the target app.
</details>

<details><summary>Playbook 2 — Bulk remediation via Assign-CorrelatedUsers.ps1</summary>

1. Download the script from `aka.ms/AssignCorrelatedUsersPowerShell` (Microsoft-hosted, not part of this repo) and, if using conditional assignment logic, the companion rules CSV template from `aka.ms/AssignCorrelatedUsersCSV`.
2. Build the rules file if conditional logic is needed: each row's `RuleGroup` number ANDs conditions together; different `RuleGroup` numbers are evaluated independently; `Operator` supports `eq`/`ne`/`contains`/`startswith`/`endswith`/`regex` against a `PropertyName` sourced from the SCIM property bag visible in the Discovery UX's per-user attribute view.
3. **Always dry-run first**: `-DryRun -OutputFile '.\results-dryrun.csv'`. Review the output CSV before any live run — it is the documented mechanism for previewing exactly what would be assigned.
4. Run live once the dry-run output looks correct. Use `-SkipAppRoleAssignment` if only entitlement-management access-package assignment is wanted (e.g., because app-role assignment is deliberately being left to a separate SSO-focused process).
5. Configure a fallback package (`-AccessPackageId`/`-PolicyId` with `-FallbackBehavior UseFallback`) if some correlated users should land in a default/catch-all access package rather than being skipped when no rule matches.
6. Retain the `-OutputFile` audit-trail CSV as evidence for governance/audit purposes — it's the authoritative record of what this run actually changed.

**Rollback:** every assignment this script makes is an ordinary app-role or access-package assignment, reversible the normal way (`Remove-MgServicePrincipalAppRoleAssignedTo`, or removing the access package assignment) — the `-OutputFile` CSV is the source of truth for what to reverse if a rule was miscalibrated.
</details>

<details><summary>Playbook 3 — Diagnosing a zero-result or all-uncorrelated discovery report</summary>

1. Read the report object's top-level `error` field first. If populated, resolve that specific error (most commonly `MissingJoiningProperty`) before looking at anything else.
2. If `error` is null but results still look wrong, confirm the connector type isn't on the unsupported list — a 0-result report against Cloud sync, Cross-tenant sync, or any of the other excluded connectors is expected behavior, not a bug to chase.
3. If the connector is supported and `error` is null, re-verify the matching attribute is genuinely Direct (not Expression) — this is worth re-confirming even if "already checked," since a subsequent unrelated mapping edit can silently change it.
4. Spot-check 2-3 individual accounts: pull the matching-attribute value from the target app's own admin console (or the Discovery UX's per-user attribute view) and compare byte-for-byte against the same attribute in Entra ID. Case sensitivity, trailing whitespace, and domain-suffix differences (`user@contoso.com` vs `user@contoso.onmicrosoft.com`) are the most common invisible mismatches.
5. If individual mismatches are confirmed, correct the source data (Entra ID or the target app, whichever is authoritative for that attribute) and re-run discovery — there is no partial/incremental re-correlation, each run re-evaluates the full target-app population.

**Rollback:** none — this playbook is entirely diagnostic.
</details>

<details><summary>Playbook 4 — Correcting a matching-attribute type without losing provisioning state</summary>

1. Before changing anything, export the current mapping configuration from the portal (Mappings → Advanced → Show advanced options → Edit attribute list) as a record of prior state — identical first step to `EnterpriseAppProvisioning-A.md` Playbook 2, since this is the same underlying mapping surface.
2. Identify a genuinely unique, stable, non-null, non-expression source attribute (`userPrincipalName`, `mail`, or `employeeId` are the common safe choices).
3. Update "Match objects using this attribute" to the direct attribute and save. This **will** trigger a full provisioning restart (new initial cycle, cleared watermark) — this is an unavoidable side effect shared with ordinary provisioning, not something specific to fixing Account Discovery.
4. Allow the restart to complete before re-running Discover identities — running discovery mid-restart against a job that hasn't re-stabilized will produce misleading results.
5. Re-run discovery and confirm the `MissingJoiningProperty` (or high-`uncorrelated`) symptom is resolved.

**Rollback:** re-apply the exported prior mapping if the new matching attribute produces incorrect provisioning behavior (duplicate accounts, wrong updates) — accept that this also re-triggers a full restart.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects Account Discovery report evidence for a named Enterprise
             Application, for ticket escalation or governance audit.
.DESCRIPTION Read-only. Pulls the most recent identityCorrelation report and its
             full per-identity results for a Service Principal, exporting to CSV.
.PARAMETER   AppDisplayName   Display name of the Enterprise Application's Service Principal.
.EXAMPLE     .\Get-AccountDiscoveryEvidence.ps1 -AppDisplayName "Salesforce"
.NOTES       Requires Microsoft.Graph.Authentication + Microsoft.Graph.Applications,
             Connect-MgGraph -Scopes "ProvisioningLog.Read.All","Application.Read.All"
#>
param([Parameter(Mandatory)][string]$AppDisplayName)

$sp = Get-MgServicePrincipal -Filter "displayName eq '$AppDisplayName'"

$reports = (Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/reports/correlations?`$filter=servicePrincipal/id eq '$($sp.Id)'").value
$latest = $reports | Sort-Object startDateTime -Descending | Select-Object -First 1

if (-not $latest) {
    Write-Warning "No correlation report found for '$AppDisplayName' — discovery has never been run."
    return
}

[PSCustomObject]@{
    AppName            = $sp.DisplayName
    ServicePrincipalId = $sp.Id
    ReportId           = $latest.id
    StartDateTime      = $latest.startDateTime
    EndDateTime        = $latest.endDateTime
    ErrorCode          = $latest.error.code
    ErrorMessage       = $latest.error.message
} | Export-Csv -Path ".\AccountDiscoveryReport_$($sp.DisplayName)_$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation

$identities = (Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/reports/correlations/$($latest.id)/identities?`$top=999").value

$identities | Select-Object id, status, correlatedDateTime,
  @{n='SourceId';e={$_.sourceIdentity.id}}, @{n='TargetId';e={$_.targetIdentity.id}},
  @{n='ErrorCode';e={$_.error.code}} |
  Export-Csv -Path ".\AccountDiscoveryIdentities_$($sp.DisplayName)_$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation
```

---
## Command Cheat Sheet

```powershell
# Find the Service Principal
$sp = Get-MgServicePrincipal -Filter "displayName eq '<AppName>'"

# List correlation reports for this app
Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/reports/correlations?`$filter=servicePrincipal/id eq '$($sp.Id)'"

# Get one report by ID
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/reports/correlations/<reportId>"

# List every identity result for a report, filtered by status
Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/reports/correlations/<reportId>/identities?`$filter=status eq 'uncorrelated'"

# Tally identity results by status
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/reports/correlations/<reportId>/identities?`$top=999").value |
  Group-Object status | Select-Object Name, Count

# Confirm the provisioning job's Test Connection health (prerequisite)
Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id | Select-Object -ExpandProperty Status

# Best-effort tenant licensing check (verify manually — not authoritative)
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "GOVERNANCE|EntraSuite" }

# Assign a discovered-and-matched user to the app (manual, single-user path)
New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -BodyParameter @{
  principalId = $userId; resourceId = $sp.Id; appRoleId = "00000000-0000-0000-0000-000000000000"
}

# Bulk remediation (Microsoft-hosted script, download separately)
pwsh -File '.\Assign-CorrelatedUsers.ps1' -ServicePrincipalId $sp.Id -DryRun -OutputFile '.\results-dryrun.csv'
```

---
## 🎓 Learning Pointers

- **Account Discovery reuses provisioning's own matching attribute rather than introducing a second join key — deliberately, but with a sharp edge.** Anything that breaks the matching attribute for provisioning breaks it for discovery too, and vice versa; troubleshoot them as one shared dependency, not two independent configurations. [Discover identities in target applications with Account Discovery](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/how-to-account-discovery)
- **The unsupported-connector list is architectural, not a maturity gap to wait out.** Cloud sync and Cross-tenant synchronization being excluded isn't "not yet supported" — both are structurally different provisioning directions/models from outbound SaaS provisioning, and Account Discovery's design assumes the outbound SCIM shape. Don't file a "when will this work" ticket for these; redesign the visibility requirement around each platform's own tooling instead.
- **The beta Graph API's `failToCorrelate` status is easy to miss if triage only happens through the portal UI**, since Microsoft's own how-to documentation names only three categories. Build any scripted audit (like the Evidence Pack above) to explicitly break out all four statuses rather than assuming "not assigned and not local" can't happen.
- **There is currently no way to programmatically trigger a discovery run** — only to read results afterward. Any MSP process wanting recurring discovery-freshness needs a human/UI-automation trigger step; don't design an unattended pipeline around a Graph POST that doesn't exist yet (re-check Microsoft's release notes periodically, since this is a young enough feature that the write-side API gap may close).
- **Read-RBAC for a completed report is deliberately broader than trigger-RBAC.** Security Reader, Reports Reader, and Global Reader can all pull `GET /beta/reports/correlations` results — useful for building read-only compliance/audit tooling without granting anyone the ability to actually kick off new discovery runs against production apps.
- **Discovery classifies and enables initial assignment; it does not govern anything ongoing.** Treat a successful discovery + bulk-assignment run as the *start* of a governance lifecycle, not the end — pair it with Access Reviews or Lifecycle Workflows so newly-assigned accounts don't become the next cycle's orphans. [What are Lifecycle Workflows?](https://learn.microsoft.com/en-us/entra/id-governance/what-are-lifecycle-workflows)
