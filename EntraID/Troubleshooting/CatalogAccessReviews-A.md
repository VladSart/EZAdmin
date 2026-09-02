# Entra ID Governance — Catalog / User-centric Access Reviews (UAR) — Reference Runbook (Mode A: Deep Dive)
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

Microsoft Entra ID Governance's standard Access Reviews (`AccessReviews-B.md`/`-A.md`) certify one **resource's** membership at a time: does this group's member list still make sense, does this app's assignment list still make sense, does this role's eligible/active list still make sense. Reviewers are typically resource owners, and the reviewer sees one review target per instance.

**Catalog Access Reviews — marketed by Microsoft as User-centric Access Reviews (UAR), GA September 2026** — flip the axis. The reviewer sees a **user**, and reviews **every resource that user has access to within a catalog** in a single unified decision surface. This is the difference between "does this group still make sense" and "does this person still need everything they currently have." Both models have their place; UAR is specifically aimed at manager-driven, person-centric recertification (the classic "does Jane still need all this access" question a manager actually wants to answer in one pass, rather than being pulled into five separate group-owner reviews).

This file assumes familiarity with entitlement management catalogs (`Create and manage a catalog of resources`) as the container concept — UAR does not introduce a new resource-grouping mechanism, it reuses the existing catalog object and adds a new review template that scopes against the whole catalog rather than one resource inside it.

**Out of scope for this file** (see cross-references):
- Standard single-resource access reviews — `AccessReviews-B.md`/`-A.md`
- Access package delivery/approval itself — `AccessPackages-B.md`/`-A.md`
- Catalog creation/resource-management mechanics unrelated to reviews — Microsoft Learn: Create and manage a catalog of resources
- Entitlement management access-package-level periodic recertification (a catalog can host access packages too, but UAR reviews the catalog's groups/apps/custom-data resources directly — it is not the same mechanism as an access package's own review policy)

---

## How It Works

<details><summary>Full architecture</summary>

**1. The catalog as review scope.** An entitlement management catalog is a container object (`identityGovernance/entitlementManagement/catalogs/{id}`) that can hold groups/Teams, applications (service principals), and — the piece that makes UAR distinct from anything else in Entra Governance — **Custom Data Provided Resources**: placeholder resource objects representing an application Entra has no live connector to at all. A catalog's resources are added once, independent of any specific review; a review is created afterward pointing at the catalog as a whole.

**2. Custom Data Provided Resources are the architecturally interesting piece.** A CDPR is not a real, queryable object anywhere — it's a name and description registered in the catalog. All actual access data for it (who has what permission) is supplied out-of-band, per review instance, via CSV upload or the Graph `customDataProvidedResourceUploadSession` API. This is how UAR extends governance to genuinely disconnected systems (a legacy on-prem app, a SaaS tool with no SCIM/OAuth integration, anything with no representation in Entra's directory graph) without requiring Entra to have any live read access to that system. The trade-off: because Entra has no live connection, it also has no write-back path — remediation for CDPR decisions is entirely the calling organization's responsibility (see Applying-stage detail below).

**3. Review creation uses a distinct template.** In the Access Reviews creation UI, "Review users access across multiple resource types within a catalog" is a separate template from the standard "Groups and Teams," "Applications," etc. templates. Structurally, the resulting `accessReviewScheduleDefinition` scope references the catalog itself rather than a single group/app/role object ID — this is the field to inspect programmatically to distinguish a UAR/catalog review from a standard one (see Command Cheat Sheet).

**4. Reviewer model differs by resource type, within the same review.** Groups and applications in a catalog review support the same multi-stage model as standard reviews (primary reviewer, optional second-stage resource-owner reviewer). Custom Data Provided Resources do not — Microsoft's documentation is explicit that CDPR reviews currently support single-stage only, with the reviewer locked to "manager of the reviewed user." There is no owner, self-attestation, or arbitrary-selected-reviewer option for CDPR specifically. This is a real, current-as-of-GA capability gap, not a misconfiguration a customer can work around in the portal.

**5. Instance lifecycle has an extra pair of states for CDPR-containing reviews.** A standard review instance moves `NotStarted → InProgress → Completed` (optionally `Applied` if auto-apply is on). A catalog review containing at least one CDPR moves through a documented four-state machine specific to that resource:

```
Initializing  →  Active  →  Applying  →  Applied
```

- **Initializing**: the instance has been created but is waiting for custom access data. The calling org has **exactly two hours** from this point to upload up to 10 CSVs (or use the Graph upload-session API) containing the CDPR's access data for this cycle. Before uploading, the operator must retrieve both the **Access Review object ID** and the **Access Review instance object ID** from the review's overview/instance screens — there is no discoverable shortcut, these are read directly off the portal (or via `GET .../accessReviews/definitions/{id}` and `.../instances/{id}`).
- **Active**: reviewers (the target users' managers, for the CDPR portion; owners/selected reviewers for group/app portions) make Approve/Deny decisions via the My Access portal until the review's end date.
- **Applying**: decisions are being remediated. For groups and apps, this is automatic and behaves like a standard review's auto-apply. For CDPR decisions, remediation is entirely external: the calling organization must (a) actually remove the denied access in the real system, then (b) call `PATCH .../decisions/{decisionId}` with an `applyResult` of `AppliedSuccessfully` or `AppliedWithFailure` to tell Entra the item is done. Microsoft's documented time budget for this stage is **30 days**, and the review instance remains in `Applying` — not `Completed`, not `Applied` — until every decision across every resource type in the review reports a terminal `applyResult`.
- **Applied**: terminal state, reached only once 100% of decision items (connected and disconnected) are accounted for.

**6. The 12-hour freeze window.** Microsoft's own documentation calls out that catalog resource changes (adding/removing a group, app, or CDPR) made within 12 hours of a scheduled review's start time may not be reflected in that instance. This is presented as a hard timing behavior of the review-instance-generation process, not a bug — plan catalog membership changes accordingly for recurring reviews.

**7. Reviewer completion surface is intentionally unified but lives in a separate UI location.** All catalog/UAR review decisions — across every resource type in the catalog — are completed in one place: the My Access portal's **Multi-resource** tab. This is deliberately distinct from the default Access Reviews list a reviewer sees for standard, single-resource reviews they're assigned to. A reviewer who has only ever used standard reviews will not organically find this tab.

</details>

---

## Dependency Stack

```
Microsoft Entra ID Governance / Microsoft Entra Suite license  (hard gate, no P1/P2-only path)
    │
    ▼
Entitlement Management Catalog  (identityGovernance/entitlementManagement/catalogs/{id})
    │
    ├── Groups and Teams resources          (live, connected — direct membership read/write)
    ├── Application resources               (live, connected — app role assignment read/write)
    └── Custom Data Provided Resources       (NOT connected — placeholder object only;
            │                                 all access data supplied per-review-instance)
            │
            ▼
      Access Review Definition  (template: "multiple resource types within a catalog")
            │
            ├── Reviewers & schedule
            │       ├── Groups/Apps  → multi-stage supported (owner as stage 2)
            │       └── CDPR         → single-stage ONLY, reviewer = manager (fixed)
            │
            ▼
      Access Review Instance
            │
            ├── (no CDPR in catalog) NotStarted → InProgress → Completed [→ Applied if auto-apply]
            │
            └── (CDPR present) Initializing → Active → Applying → Applied
                    │                │           │
                    │                │           └── Groups/Apps: auto-applied
                    │                │               CDPR: MANUAL — external remediation +
                    │                │                     Graph PATCH per decision item required
                    │                │
                    │                └── Reviewer decisions via My Access → Multi-resource tab
                    │
                    └── 2-hour CSV/Graph upload window for CDPR access data
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No catalog review template in the New Access Review wizard | Missing Governance/Entra Suite license | `Get-MgSubscribedSku` for GOVERNANCE/Entra_Suite service plans |
| Reviewer says the review doesn't exist | Looking at the standard Access Reviews list instead of My Access → Multi-resource tab | Confirm reviewer is checking the correct portal tab |
| CDPR shows zero items for a cycle | 2-hour upload window from `Initializing` expired before CSV/Graph upload | Instance `status` and elapsed time since creation |
| Review stuck in `Applying` well past the end date | CDPR decisions never PATCHed with a terminal `applyResult` | List decisions filtered to the CDPR resourceId, check `applyResult` field |
| Catalog resource change absent from a review instance | 12-hour pre-start freeze window | Compare catalog resource-added timestamp to instance `startDateTime` |
| Can't assign a second-stage owner reviewer for a CDPR | Not supported for this resource type — documented limitation | N/A — confirm resource type is CDPR, not group/app |
| Graph script fails with `Authorization_RequestDenied` on catalog calls | Missing `EntitlementManagement.Read/ReadWrite.All` scope | `Get-MgContext` → `.Scopes` |
| Graph script fails with `Authorization_RequestDenied` on review calls | Missing `AccessReview.Read/ReadWrite.All` scope | `Get-MgContext` → `.Scopes` |
| Uploaded CSV rejected/ignored | Missing one of the six mandatory columns, or `PrincipalType` not exactly `EntraIdUser`, or `PrincipalId` doesn't match a real Entra user | Re-validate CSV against the documented column schema; check entitlement management audit log for the upload event's result |

---

## Validation Steps

**1. Confirm licensing.**
```powershell
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "GOVERNANCE|Entra_Suite" } |
    Select-Object SkuPartNumber, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}
```
Expected: at least one enabled unit under a Governance or Entra Suite plan. No output → the feature is unavailable tenant-wide, full stop.

**2. Confirm the catalog exists and inventory its resource types.**
```powershell
$catalog = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/catalogs/<CatalogId>"
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/catalogs/<CatalogId>/resources" |
    Select-Object -ExpandProperty value | Group-Object resourceType | Select-Object Name, Count
```
Expected: a breakdown across `AadGroup`/`AadApplication`/custom-data resource types. Zero resources means no review created from this catalog will have anything to certify.

**3. Confirm the review definition is genuinely catalog-scoped.**
```powershell
$def = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/<DefinitionId>"
$def.scope | ConvertTo-Json -Depth 6
```
Expected: a scope object referencing the catalog resource (not a single group/app/role object ID). If it references one object ID directly, this is a standard review — stop, this file doesn't apply.

**4. Confirm reviewer configuration matches resource-type constraints.**
```powershell
$def.settings.reviewers, $def.settings.instanceGenerationSettings | ConvertTo-Json -Depth 5
```
Expected for CDPR-containing catalogs: reviewer type resolves to manager, single stage. A second stage configured against a CDPR resource is a sign the review was miscreated or the CDPR was added to an existing group/app-oriented review by mistake.

**5. Walk the instance lifecycle for a CDPR-containing review.**
```powershell
$instance = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/<DefinitionId>/instances/<InstanceId>"
$instance | Select-Object status, startDateTime, endDateTime
```
Expected states in order: `Initializing` (briefly, ≤2h) → `Active` (until end date) → `Applying` (until all decisions applied, ≤30d) → `Applied`. A review sitting in `Initializing` past 2 hours, or `Applying` past 30 days, is off the happy path — go to the corresponding Remediation Playbook.

**6. Confirm 100% decision-item apply-completion for a review stuck in Applying.**
```powershell
$decisions = Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/<DefinitionId>/instances/<InstanceId>/decisions" |
  Select-Object -ExpandProperty value
$decisions | Group-Object { if ($_.applyResult -and $_.applyResult -ne "New") { "Applied" } else { "Outstanding" } } |
    Select-Object Name, Count
```
Expected: zero "Outstanding" once genuinely complete. Any outstanding count explains exactly why the instance hasn't reached `Applied`.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Pre-creation (catalog/licensing)**
1. Confirm license (Validation Step 1).
2. Confirm the catalog has at least one resource of a supported type — Groups/Teams, Applications, or Custom Data Provided Resources are the only three; anything else (e.g. an attempt to add a raw Azure resource role) has no catalog-review path.
3. For CDPR specifically: confirm the calling org has an actual process ready to supply CSV/Graph data on a recurring basis and to consume+action the `Applying`-stage decision list. UAR does not make disconnected-app governance free — it makes the recertification UI unified while the remediation plumbing remains the customer's job.

**Phase 2 — Review creation**
1. Use the correct template ("Review users access across multiple resource types within a catalog") — do not attempt to build the same outcome by chaining multiple single-resource reviews; that defeats the "certify a user, not a resource" design intent and produces a worse reviewer experience.
2. For catalogs containing CDPR, budget the review's start-to-first-CSV-upload window: the instance's `Initializing` state gives only 2 hours. If the CSV export is generated by a nightly batch job in the source system, make sure that job's timing can realistically land inside the window relative to when the review's recurrence pattern creates new instances.
3. Configure reviewers per resource-type constraint (Validation Step 4) — don't promise a customer owner-based secondary review across the whole catalog if CDPR resources are included; that promise can only be kept for the group/app portion.

**Phase 3 — Active review (reviewer experience)**
1. Direct reviewers explicitly to My Access → Access reviews → **Multi-resource** tab in any rollout communication. This is the single highest-friction point of the whole feature from a support-ticket-volume perspective.
2. Confirm reviewer identity resolution for CDPR: the "manager" reviewer is computed from the reviewed user's manager attribute in Entra ID at instance-creation time — a manager change mid-cycle does not retroactively reassign the review.

**Phase 4 — Applying (post-decision remediation)**
1. For groups/apps: confirm auto-apply completed via the standard mechanism (identical behavior to `AccessReviews-A.md`'s auto-apply path).
2. For CDPR: run the list-decisions → remediate-in-source-system → PATCH-decision loop (Remediation Playbook 1 below). Track this as an actual operational runbook step in the customer's process documentation — it is not automatic and will not become automatic without a custom integration.
3. Monitor for the 30-day `Applying` ceiling; a review that blows past it should be escalated as a stuck instance, not treated as still "in normal flight."

---

## Remediation Playbooks

<details><summary>Playbook 1 — Wire up Custom Data Provided Resource remediation (recurring)</summary>

**Goal:** Build a repeatable process so CDPR decisions don't silently stall a review in `Applying`.

1. **Capture the review's object ID and instance object ID** as soon as the instance is created (portal, or poll `GET .../accessReviews/definitions?$filter=...` for new instances programmatically).
2. **Generate and upload the CSV inside the 2-hour Initializing window.** Required columns, all mandatory: `PrincipalId` (the reviewed user's Entra object ID), `PrincipalType` (always `EntraIdUser` for this feature), `PermissionId`, `PermissionName`, `PermissionDescription`, `PermissionType`. Confirm success via the entitlement management audit log, not just the absence of an error in the upload dialog.
3. **Wait for the review to reach `Active` → `Applying`** (or poll instance status programmatically).
4. **Pull denied decisions scoped to the CDPR resource:**
   ```powershell
   GET https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/{defId}/instances/{instanceId}/decisions?$filter=(decision eq 'Deny' and resourceId eq '{cdprResourceId}')
   ```
5. **Actually remove access in the real system** (ServiceNow ticket, manual admin action, script against whatever the disconnected app's own admin API is) — Entra has no ability to do this step; it never had a connection to the resource in the first place.
6. **Report completion back per decision item:**
   ```powershell
   PATCH https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/{defId}/instances/{instanceId}/decisions/{decisionId}
   { "applyResult": "AppliedSuccessfully", "applyDescription": "Removed via <ticket ref>" }
   ```
   Use `AppliedWithFailure` (with a description) if remediation could not be completed — this still counts as a terminal state for the instance's `Applied` transition, so failures don't silently block the whole review forever, but they should be tracked separately for follow-up.
7. **Confirm `Applied` transition** once all decisions — CDPR and connected resources alike — report a terminal result.

**Rollback:** If access was removed from the source system in error, re-grant it directly there — there is no review-engine undo for a CDPR decision.

</details>

<details><summary>Playbook 2 — Recover a review stuck in Initializing past 2 hours</summary>

1. Confirm current status and elapsed time (Validation Step 5).
2. If still `Initializing` and inside the window, upload immediately — do not wait for a "confirmation" prompt that doesn't exist; the window is wall-clock, not activity-based.
3. If the window has closed, there is no supported retroactive upload for that instance. Document the miss, and for the next recurrence, move the CSV-generation trigger earlier in the pipeline (ideally: on instance-creation webhook/poll, not on a fixed daily schedule that may drift relative to the review's own schedule).

**Rollback:** N/A — no destructive action taken; this is a process-timing fix for future cycles.

</details>

<details><summary>Playbook 3 — Distinguish a catalog/UAR review from a standard review when a ticket is ambiguous</summary>

1. Get the definition and inspect `scope`:
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/<DefinitionId>" |
       Select-Object -ExpandProperty scope | ConvertTo-Json -Depth 6
   ```
2. A `scope` referencing `entitlementManagement/catalogs/{id}` (or a `resourceScopes`-style collection spanning multiple resource types) = catalog/UAR review → this file.
3. A `scope` referencing a single `group`, `servicePrincipal`, or role object = standard review → route to `AccessReviews-B.md`/`-A.md` instead. Don't apply this file's fixes (especially the Applying-stage PATCH loop, which is CDPR-specific) to a standard review — they don't apply and will not resolve the actual issue.

**Rollback:** N/A — diagnostic only.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Catalog/UAR access review evidence for escalation: licensing,
    catalog resource inventory, review definition scope/reviewer config,
    instance status/age, and outstanding (unapplied) decision counts.
#>
param(
    [Parameter(Mandatory)] [string]$DefinitionId,
    [Parameter(Mandatory)] [string]$InstanceId,
    [string]$OutputPath = ".\CatalogAccessReview-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').json"
)

$evidence = [ordered]@{
    CollectedAt = (Get-Date).ToString("o")
    Licensing   = Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "GOVERNANCE|Entra_Suite" } |
                    Select-Object SkuPartNumber, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}
    Definition  = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/$DefinitionId"
    Instance    = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/$DefinitionId/instances/$InstanceId"
    Decisions   = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/$DefinitionId/instances/$InstanceId/decisions").value
}

$outstanding = $evidence.Decisions | Where-Object { -not $_.applyResult -or $_.applyResult -eq "New" }
$evidence.OutstandingDecisionCount = @($outstanding).Count
$evidence.TotalDecisionCount       = @($evidence.Decisions).Count

$evidence | ConvertTo-Json -Depth 8 | Out-File $OutputPath
Write-Host "Evidence written to $OutputPath"
```

---

## Command Cheat Sheet

| Purpose | Command |
|---|---|
| Confirm licensing | `Get-MgSubscribedSku \| ? { $_.ServicePlans.ServicePlanName -match "GOVERNANCE\|Entra_Suite" }` |
| List catalogs | `GET /beta/identityGovernance/entitlementManagement/catalogs` |
| List a catalog's resources | `GET /beta/identityGovernance/entitlementManagement/catalogs/{id}/resources` |
| Get a review definition (check scope for catalog-vs-single-resource) | `GET /beta/identityGovernance/accessReviews/definitions/{id}` |
| List instances for a definition | `GET /beta/identityGovernance/accessReviews/definitions/{id}/instances` |
| Get one instance's status | `GET /beta/identityGovernance/accessReviews/definitions/{id}/instances/{instanceId}` |
| List decisions (optionally filtered) | `GET /beta/identityGovernance/accessReviews/definitions/{id}/instances/{instanceId}/decisions?$filter=...` |
| Apply/report a CDPR decision | `PATCH /beta/identityGovernance/accessReviews/definitions/{id}/instances/{instanceId}/decisions/{decisionId}` |
| Create a catalog review programmatically | `POST /beta/identityGovernance/accessReviews/definitions` (see Graph docs example 6, catalog scope) |
| Custom data upload session (Graph, alternative to portal CSV) | `POST customDataProvidedResourceUploadSession` resource |
| Reviewer completion UI | `https://myaccess.microsoft.com` → Access reviews → **Multi-resource** tab |
| Required delegated scopes (read) | `EntitlementManagement.Read.All`, `AccessReview.Read.All` |
| Required delegated scopes (write) | `EntitlementManagement.ReadWrite.All`, `AccessReview.ReadWrite.All` |

---

## 🎓 Learning Pointers

- **UAR is a reviewer-experience unification, not a remediation-automation feature** — it collapses "review this group, then this app, then this other app" into one pass for the reviewer, but for Custom Data Provided Resources it does not remove the need for a real integration to actually act on Deny decisions. Selling or scoping this feature as "fully automated governance for disconnected apps" will set the wrong expectation. [MS Docs: Custom data provided resource access reviews](https://learn.microsoft.com/en-us/entra/id-governance/custom-data-resource-access-reviews)

- **The scope object is the reliable way to tell catalog reviews apart from standard reviews programmatically** — don't rely on the display name or template name alone in automation; inspect `scope` on the `accessReviewScheduleDefinition` directly. [MS Graph: accessReviewSet](https://learn.microsoft.com/en-us/graph/api/accessreviewset-post-definitions?view=graph-rest-beta&tabs=http)

- **Reviewer-model asymmetry within one catalog is a design constraint, not a bug to route around** — CDPR resources are locked to single-stage, manager-only review. If a customer needs owner-based review for a disconnected system, that requirement has to be met by converting it to a connected resource type or handled outside UAR entirely for now.

- **The 2-hour and 30-day windows are the two numbers worth memorizing** — 2 hours from `Initializing` to upload custom data, 30 days as the documented ceiling for the `Applying` stage before a review should be treated as stuck rather than "still processing." Both are silent failure modes with no proactive alerting from Microsoft — build your own monitoring around `Get-CatalogAccessReviewAudit.ps1` if this feature is in production use for a customer.

- **This feature currently has no typed Microsoft.Graph PowerShell cmdlet coverage confirmed for the catalog-scoped review surface** — all commands in this file use `Invoke-MgGraphRequest` against the beta REST endpoints directly, consistent with this repo's standing practice for Preview/newly-GA features without a confirmed stable typed SDK surface (see also `MCPFirewall-A.md`, `TenantGovernance-A.md`). Re-check for typed cmdlet availability as the Microsoft.Graph.Beta module evolves.

- **Don't conflate this with access package review policies** — a catalog can host access packages, and access packages have their own periodic-recertification policy mechanism configured on the package's lifecycle policy. UAR reviews the catalog's groups/apps/CDPR resources directly; it is a parallel governance mechanism, not a superset or replacement of access-package-level review policies. [MS Docs: What are access reviews?](https://learn.microsoft.com/en-us/entra/id-governance/access-reviews-overview)
