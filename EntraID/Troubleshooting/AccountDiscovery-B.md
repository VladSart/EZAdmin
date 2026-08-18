# Entra ID Governance — Account Discovery — Hotfix Runbook (Mode B: Ops)
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

```powershell
# Requires: Microsoft.Graph.Authentication module (beta cmdlets not published — use Invoke-MgGraphRequest)
# Connect-MgGraph -Scopes "ProvisioningLog.Read.All","Application.Read.All","Directory.Read.All"

# 1. Find the Service Principal and confirm provisioning is actually configured (Account Discovery
#    is layered ON TOP of an existing provisioning job — it is not a standalone feature)
$sp  = Get-MgServicePrincipal -Filter "displayName eq '<AppName>'"
$job = Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id

# 2. Pull the most recent correlation (discovery) report for this Service Principal
$reports = Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/reports/correlations?`$filter=servicePrincipal/id eq '$($sp.Id)'"
$latest = $reports.value | Sort-Object startDateTime -Descending | Select-Object -First 1
$latest | Select-Object id, startDateTime, endDateTime, error

# 3. If a report exists, pull its per-identity results and tally by status
if ($latest) {
  $identities = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/beta/reports/correlations/$($latest.id)/identities?`$top=999"
  $identities.value | Group-Object status | Select-Object Name, Count
}

# 4. Confirm the operator's own RBAC for triggering a NEW discovery run (portal action, not Graph-writable)
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$((Get-MgContext).Account)'" -ExpandProperty roleDefinition |
  Select-Object -ExpandProperty RoleDefinition | Select-Object DisplayName
```

| Triage result | Interpretation | Do this |
|---|---|---|
| No `$job` returned for the Service Principal | Account Discovery requires an *existing* provisioning configuration — there is nothing to discover against | Fix 1 |
| `$reports.value` is empty, no report has ever been generated | Discovery has never been run for this app — this is expected pre-first-run state, not a fault | Fix 2 |
| Report exists, `error` is non-null (e.g. `MissingJoiningProperty`) | The whole correlation run failed — almost always a matching-attribute problem | Fix 3 |
| Report exists, `error` is null, but every identity shows `status = uncorrelated` and you know local accounts should have matched | Matching attribute is populated but wrong data, or genuinely all local/orphan accounts | Fix 4 |
| **Discover identities** button greyed out or missing in the portal | License gate (no Entra ID Governance add-on / Entra Suite) or RBAC gap | Fix 5 |
| Report `endDateTime` is null / discovery has been "running" for hours | Expected at scale — large target apps can take 12+ hours; not stuck by default | Fix 6 |
| App is Workday/SuccessFactors/API-driven HR, ServiceNow, AWS, Snowflake, Cross-tenant sync, Cloud sync, or Group provisioning to AD | Connector is explicitly unsupported for Account Discovery — no fix exists | Fix 7 |
| Individual identity shows `status = failToCorrelate` | That specific identity's correlation attempt errored — distinct from a clean `uncorrelated` (no-match) result | Fix 8 |
| Bulk `Assign-CorrelatedUsers.ps1` run errors out or assigns nothing | Wrong `-ServicePrincipalId`, missing Graph write scopes, or a malformed rules CSV | Fix 9 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Entra ID Governance add-on license OR Microsoft Entra Suite
   │  (gates the "Discover identities" action in the portal entirely)
   │
   ├─ RBAC: Application Administrator, Cloud Application Administrator,
   │        or Hybrid Identity Administrator (to trigger discovery)
   │        — NOTE: reading an already-generated report via Graph is
   │          much broader-RBAC (Global Reader, Reports Reader, Security
   │          Reader/Operator/Administrator, Enterprise App Owner all
   │          qualify) — a "can't see the report" ticket and a "can't
   │          run discovery" ticket are two different RBAC surfaces
   │
   ├─ Enterprise Application already configured for automatic provisioning
   │     ├─ Valid admin credentials + successful Test Connection
   │     │     (see EnterpriseAppProvisioning-B.md Fix 1 if this is broken)
   │     └─ A DIRECT (non-expression) matching attribute configured
   │           — expression-based / transformed matching attributes are
   │             NOT supported for correlation, even though they ARE
   │             supported for ordinary provisioning
   │
   ├─ Target application's connector type supports discovery
   │     ├─ Confirmed-good: Atlassian Cloud, generic SCIM, Salesforce,
   │     │   SAP Cloud Identity Services, ECMA (on-prem SQL/LDAP/Web
   │     │   Services/PowerShell), GitHub Enterprise Cloud (with limits)
   │     └─ Explicitly UNSUPPORTED: HR provisioning (Workday/SuccessFactors/
   │         API-driven), ServiceNow, AWS, Snowflake, Cross-tenant sync,
   │         Cloud sync, Group provisioning to AD
   │
   ├─ Target app's SCIM implementation supports pagination
   │     (RFC 7644 §3.4.2.4) — a vendor-side requirement Entra ID cannot fix
   │
   └─ "Discover identities" triggered (portal-only — no Graph POST/start
      endpoint exists for this action) ──▶ identityCorrelation report
      generated ──▶ readable via GET /beta/reports/correlations (and its
      /identities sub-resource) once complete
```

If the provisioning job itself doesn't exist or has never had a successful Test Connection, nothing below that layer is worth checking.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm provisioning exists and has run at least once.** `Get-MgServicePrincipalSynchronizationJob` — a job with no successful execution has nothing meaningful to discover against yet.
2. **Confirm the matching attribute is DIRECT, not expression-based.** Portal: **Provisioning → Edit provisioning → Mappings → [Object] → Show advanced options → Match objects using this attribute**. If the configured mapping type is `Expression`, this is almost always the root cause of a failed or empty discovery report.
3. **Confirm the connector type is on the supported list.** Cross-reference the app against the Dependency Cascade's confirmed-good/unsupported lists above before spending time on anything else — this rules out an entire class of tickets in one step.
4. **Trigger (or re-check) discovery in the portal.** **Enterprise Apps → [App] → Provisioning → Discover identities**. There is no Graph-callable way to start this — if automation needs to *initiate* discovery, it currently cannot; Graph is read-only for this feature.
5. **Read the report's top-level `error` field first**, before looking at individual identities — a populated `error` (e.g. `MissingJoiningProperty`) means the entire run failed and no individual identity results are meaningful yet.
6. **If the report succeeded, pull `/identities` and check the `status` distribution.** Four possible values: `uncorrelated` (no Entra match — the portal calls this "Local accounts"), `correlatedNotAssigned` ("Unassigned users"), `correlatedAssigned` ("Assigned users"), and `failToCorrelate` (the correlation attempt itself errored for that specific identity — not the same as a clean no-match).
7. **For a suspiciously high `uncorrelated` count**, spot-check 2-3 of those accounts' attribute values in the target app against the matching-attribute value in Entra ID — stale/mismatched data (a changed `mail`, a renamed account) is the most common false-positive cause.

---
## Common Fix Paths

<details><summary>Fix 1 — No provisioning job exists for this app</summary>

Account Discovery is not a standalone feature — it runs against an existing automatic-provisioning configuration. Configure provisioning first (see `EnterpriseAppProvisioning-B.md` for that setup), confirm Test Connection passes, and let at least one cycle attempt to run before returning to Account Discovery.

**Rollback:** none — this is a prerequisite check, not a change.
</details>

<details><summary>Fix 2 — Discovery has never been run</summary>

```powershell
# Confirm this is genuinely a "never run" state, not a missed/failed run
Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/reports/correlations?`$filter=servicePrincipal/id eq '$($sp.Id)'"
```
If this returns nothing at all, no discovery run has ever completed for this Service Principal. Run it manually: **Enterprise Apps → [App] → Provisioning → Discover identities**. Expect a minimum of 30 minutes; large target apps (250K+ accounts) can take 12+ hours.

**Rollback:** none — discovery is read-only against the target app; it makes no changes.
</details>

<details><summary>Fix 3 — Report exists but `error` is populated (e.g. `MissingJoiningProperty`)</summary>

```powershell
# Confirm the matching attribute's mapping TYPE, not just that one is configured
# Portal: Provisioning → Edit provisioning → Mappings → [Object] → Show advanced options
# Look for "Match objects using this attribute" and confirm the source is a direct
# attribute (e.g. userPrincipalName, mail) rather than an Expression mapping.
```
`MissingJoiningProperty` means the correlation engine could not find a usable direct matching attribute — this is the single most common whole-report failure. Rebuild the matching attribute mapping as a direct (non-expression) mapping, save (this will also silently trigger a full provisioning restart per `EnterpriseAppProvisioning-A.md`'s "Attribute mappings" section — expect a fresh initial cycle), then re-run Discover identities.

**Rollback:** re-apply the prior matching attribute if the new one produces incorrect correlation results — re-running discovery afterward is non-destructive either way.
</details>

<details><summary>Fix 4 — Report succeeded but correlation looks wrong (too many "Local accounts")</summary>

```powershell
# Spot-check the matching attribute value for a specific known-good user
Get-MgUser -UserId "<user@contoso.com>" -Property "userPrincipalName,mail,employeeId" |
  Select-Object userPrincipalName, mail, employeeId
# Compare directly against that same user's value in the target app (portal: view attributes
# on the individual identity row in the Discovery UX, or the target app's own admin console)
```
Only the FIRST configured matching attribute is used for correlation, even if multiple are mapped — confirm which one is actually first before assuming the visible one is being used. Common root causes: the matching attribute value changed on one side after the account was created (renamed mailbox, migrated domain), or the account genuinely is an orphan/local account and the "Local accounts" bucket is working as intended.

**Rollback:** none — this is investigative, not a change.
</details>

<details><summary>Fix 5 — "Discover identities" button missing or greyed out</summary>

```powershell
# Check tenant licensing (best-effort SKU name match — verify manually against your tenant's
# actual purchased SKUs, do not treat this as authoritative)
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "GOVERNANCE|ENTRAID_GOVERNANCE|EntraSuite|Entra_Suite" } |
  Select-Object SkuPartNumber, ConsumedUnits, @{n='Enabled';e={($_.PrepaidUnits).Enabled}}

# Check the current user's directory role assignments
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<UserObjectId>'" -ExpandProperty roleDefinition |
  Select-Object -ExpandProperty RoleDefinition | Select-Object DisplayName
```
Two independent gates, check both: (1) the tenant must hold the Microsoft Entra ID Governance add-on license or Microsoft Entra Suite — no license, no button, regardless of role; (2) the signed-in user needs Application Administrator, Cloud Application Administrator, or Hybrid Identity Administrator specifically to trigger discovery (this is narrower than the broad set of roles that can merely *read* an already-generated report via Graph).

**Rollback:** none — licensing/RBAC confirmation only.
</details>

<details><summary>Fix 6 — Discovery has been "running" for a long time</summary>

```powershell
Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/reports/correlations/$($latest.id)"
# endDateTime being null/absent means the run has not yet completed
```
Discovery duration scales with target-app account volume — Microsoft's own guidance cites 30 minutes minimum and 12+ hours for an application with ~250K accounts. Only escalate if `endDateTime` is still absent after a duration clearly disproportionate to the target app's known user count, or if the portal shows an explicit failure state rather than "in progress."

**Rollback:** none — this is a read-only wait/verify step.
</details>

<details><summary>Fix 7 — App is on the explicitly unsupported connector list</summary>

No fix exists inside Account Discovery for these connector types: HR provisioning (Workday, SAP SuccessFactors, API-driven provisioning), ServiceNow, Amazon Web Services (AWS), Snowflake, Cross-tenant synchronization, Cloud sync, and Group provisioning to AD. If unmanaged/local-account visibility is genuinely needed for one of these, it has to be built manually against that platform's own reporting/API surface — do not spend further time trying to get the Discover identities button to produce results for these connector types.

**Rollback:** N/A — no action was taken against Entra ID.
</details>

<details><summary>Fix 8 — Individual identity shows `failToCorrelate`</summary>

```powershell
Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/reports/correlations/$($latest.id)/identities?`$filter=status eq 'failToCorrelate'"
```
This is distinct from `uncorrelated` (a clean "no Entra match found" result — expected for genuine local accounts). `failToCorrelate` means the correlation *attempt* for that specific identity errored — check the identity's own `error` sub-object for detail. Common cause: a malformed or unexpectedly-null attribute value on that one target-app account tripping the correlation logic even though the matching attribute mapping itself is otherwise healthy.

**Rollback:** none — investigative only.
</details>

<details><summary>Fix 9 — `Assign-CorrelatedUsers.ps1` bulk-assignment run fails</summary>

```powershell
# Always dry-run first — this is documented as a supported parameter for exactly this reason
pwsh -File '.\Assign-CorrelatedUsers.ps1' -ServicePrincipalId "<sp-object-id>" -DryRun -OutputFile '.\results-dryrun.csv'
```
Verify `-ServicePrincipalId` is the Service Principal's **object ID** (not the Application/client ID — a common mix-up across every Graph-app-related script in this repo). If assignments still fail after confirming the ID, the signed-in identity running the script needs Graph write permissions covering both app role assignment and (if targeting access packages) entitlement management write scopes — this script's own documentation does not enumerate its exact required Graph scopes, so confirm by testing with `-DryRun` first and reading any permission-denied error text literally rather than assuming a scope.

**Rollback:** re-run with `-DryRun` to confirm scope before ever running live; the script's own audit-trail `-OutputFile` CSV is the record to check for what was actually changed if a live run needs to be reversed manually (unassign via `Remove-MgServicePrincipalAppRoleAssignedTo`, per `EnterpriseAppProvisioning-B.md` Fix 4).
</details>

---
## Escalation Evidence

```
App / Service Principal name: ____________________
Service Principal Object ID: ____________________
Provisioning job status (Code / QuarantineReason): ____________________
Latest correlation report ID: ____________________
Report startDateTime / endDateTime: ____________________
Report top-level error (code / message, if any): ____________________
Identity status counts (uncorrelated / correlatedNotAssigned / correlatedAssigned / failToCorrelate): ____________________
Matching attribute configured, and mapping type (Direct / Expression): ____________________
Target application connector type: ____________________
Tenant license confirmed (Entra ID Governance add-on / Entra Suite, Y/N): ____________________
Operator's RBAC role for triggering discovery: ____________________
```

---
## 🎓 Learning Pointers

- **Account Discovery has no Graph-callable "start" endpoint.** Every other action in this file's dependency chain is Graph-readable, but triggering a NEW discovery run is portal-only — plan any recurring/scheduled discovery process around a human (or RPA-style UI automation) trigger, not a Graph API call. [Discover identities in target applications with Account Discovery](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/how-to-account-discovery)
- **The Graph beta API exposes a 4th correlation status the portal's own documentation doesn't name as a distinct bucket.** The portal how-to page describes exactly three categories (Local/Unassigned/Assigned accounts), but `GET /beta/reports/correlations/{id}/identities` can also return `failToCorrelate` — an errored correlation attempt, not a clean no-match. Don't conflate the two when triaging a high "Local accounts" count.
- **Expression-based matching attributes work fine for ordinary provisioning but silently disqualify Account Discovery.** If a tenant configured a concatenation/transformation expression as its matching attribute (a common pattern for apps needing a composite unique key), discovery will fail with `MissingJoiningProperty` even though provisioning itself has been running successfully for months.
- **RBAC for reading a report is much broader than RBAC for running one.** Global Reader, Reports Reader, and the Security Reader/Operator/Administrator family can all read an existing `identityCorrelation` report via Graph — but none of them can click Discover identities in the portal. A "why can't I see the report" ticket and a "why can't I run discovery" ticket point at two different role sets.
- **The unsupported-connector list includes two other topics already covered in this repo** — Cloud sync (`CloudSync-A.md`/`-B.md`) and Cross-tenant synchronization (`CrossTenant-A.md`/`-B.md`) are both explicitly excluded from Account Discovery. If a ticket references either of those provisioning types, redirect immediately rather than troubleshooting Discover identities for them.
