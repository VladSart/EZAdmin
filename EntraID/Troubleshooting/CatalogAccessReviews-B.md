# Entra ID Governance — Catalog / User-centric Access Reviews (UAR) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Scope note:** This is a distinct review *type* from the standard, single-resource access review already covered in `AccessReviews-B.md`/`-A.md`. A standard review certifies membership of **one** group, **one** app, or **one** role. A catalog (a.k.a. User-centric Access Review / UAR — GA September 2026) certifies **one user's** access across **every resource in a catalog at once** — groups, applications, and custom "disconnected" resources uploaded from a system with no Entra connector at all. If the ticket says "the reviewer can't find this review" or "I approved everything but access wasn't removed," confirm which review type you're looking at FIRST — the two have different UI locations, different auto-apply behavior, and different reviewer models. See the Dependency Cascade below before assuming this is the same fix path as `AccessReviews-B.md`.

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
# 1. Confirm Entra ID Governance / Entra Suite licensing — UAR has NO P2-only fallback,
#    unlike several base Access Reviews capabilities
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "GOVERNANCE|Entra_Suite" } |
    Select-Object SkuPartNumber, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}

# 2. List entitlement management catalogs and their resource counts (beta — catalog
#    review resource scoping has no stable v1.0 surface yet)
Connect-MgGraph -Scopes "EntitlementManagement.Read.All", "AccessReview.Read.All"
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/catalogs" |
    Select-Object -ExpandProperty value | Select-Object id, displayName, state

# 3. List access review definitions and identify which are catalog-scoped
#    (scope references a catalog resourceId rather than a single group/app/role)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions?`$expand=instances" |
    Select-Object -ExpandProperty value |
    Select-Object id, displayName, @{N="ScopeType";E={$_.scope.'@odata.type'}}

# 4. Check a specific catalog review instance's status
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/<DefinitionId>/instances" |
    Select-Object -ExpandProperty value | Select-Object id, status, startDateTime, endDateTime

# 5. Pull decisions for a stuck instance, filtered to a specific custom-data resource
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/<DefinitionId>/instances/<InstanceId>/decisions?`$filter=(decision eq 'Deny')"
```

**Interpretation table:**

| Result | What it means | Action |
|---|---|---|
| No Governance/Entra Suite SKU found | UAR is entirely unavailable — this is not a partial-feature gap like base Access Reviews on P2 | Fix 1 |
| Reviewer says "I don't see this review" but the definition/instance clearly exists | They're looking at the wrong tab in My Access | Fix 2 |
| Instance `status = Initializing` for more than 2 hours | Custom data upload window expired without an upload | Fix 3 |
| Instance `status = Applying` and stuck there for days | Custom-data-provided resource decisions were never PATCHed back — this does NOT auto-clear like group/app decisions | Fix 4 |
| Catalog resource (group/app) added or removed right before the review started, but the review doesn't reflect it | 12-hour pre-start freeze window on catalog resource changes | Fix 5 |
| Trying to add a second-stage owner reviewer to a custom-data-resource review | Not supported — custom data reviews are single-stage, manager-only | Fix 6 |
| Graph calls fail with `Authorization_RequestDenied` | Missing `EntitlementManagement.Read.All` (catalog) or `AccessReview.ReadWrite.All` (review) scope | Fix 7 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Entra ID Governance or Microsoft Entra Suite license
(hard requirement — no P2-only tier for this feature, unlike base Access Reviews)
    │
    └── Entitlement Management Catalog
            ├── Resources added to catalog (ONLY three types supported):
            │       ├── Groups and Teams
            │       ├── Applications (service principals)
            │       └── Custom Data Provided Resources (disconnected apps —
            │               access data supplied by CSV/Graph upload, not live-read)
            │
            └── Catalog Access Review (created from the "Review users access across
                    multiple resource types within a catalog" template)
                    ├── Resources tab → points at the catalog (NOT an individual resource)
                    ├── Reviewers tab
                    │       ├── Groups/Apps in the catalog → multi-stage supported,
                    │       │       resource owner can be a secondary-stage reviewer
                    │       └── Custom Data resources → SINGLE-STAGE ONLY, reviewer
                    │               must be "manager" — no owner/self/selected-user option
                    │
                    ├── Instance lifecycle — DIFFERENT for custom-data resources:
                    │       Initializing (2-hour CSV upload window, else empty resource)
                    │           → Active (reviewer decisions via My Access portal)
                    │           → Applying (up to 30 days — group/app decisions
                    │                 auto-apply here; custom-data decisions do NOT —
                    │                 an external system must remove access AND
                    │                 PATCH each decision item back via Graph)
                    │           → Applied (only once EVERY decision item, across every
                    │                 resource type, is marked applied)
                    │
                    └── Reviewer completion surface
                            └── My Access portal (myaccess.microsoft.com) →
                                    Access reviews → "Multi-resource" tab
                                    (a DIFFERENT tab from single-resource reviews —
                                     this is the #1 "reviewer can't find it" ticket)
```

**Common gaps:**
- A catalog review with a Custom Data Provided Resource in it will sit in `Applying` indefinitely if nobody wires up the Graph decision-list → remediate-in-source-system → PATCH-decision loop. This is silent — no error, no notification, just a review that never reaches `Applied`.
- Changes to catalog membership (adding/removing a group, app, or custom resource) inside the 12 hours before a scheduled review start may not be reflected in that instance. This is a hard timing window, not a caching bug.
- Custom data resource reviews cap reviewers to "manager of the reviewed user" — there is no owner-based or self-attestation option for that resource type, even though the catalog's other resource types (groups/apps) support both.

</details>

---

## Diagnosis & Validation Flow

**1. Identify the failure category**

```
Feature entirely missing from the portal?                        → Fix 1
Reviewer insists the review doesn't exist?                        → Fix 2
Custom data resource shows zero items to review?                  → Fix 3
Review stuck in "Applying" past its end date?                     → Fix 4
Catalog resource change didn't make it into the review?           → Fix 5
Can't configure a second-stage reviewer on a custom-data resource? → Fix 6
Graph automation script fails with a permission error?             → Fix 7
```

**2. Confirm licensing before anything else**

UAR has no fallback tier. If `Get-MgSubscribedSku` in Triage step 1 shows neither Governance nor Entra Suite, stop — this is a licensing conversation, not a configuration bug.

**3. Confirm which review type the ticket is actually about**

```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/<DefinitionId>" |
    Select-Object displayName, @{N="Scope";E={$_.scope | ConvertTo-Json -Depth 5}}
```
If `scope` references `.../entitlementManagement/catalogs/<id>` (directly or via a `resourceScopes` collection with multiple resource types), it's a catalog/UAR review — use this file. If it references a single group/app/role object ID, it's a standard review — use `AccessReviews-B.md` instead.

**4. Check instance status and time-in-state**

```powershell
$instance = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/<DefinitionId>/instances/<InstanceId>")
$instance | Select-Object status, startDateTime, endDateTime
if ($instance.status -eq "Applying") {
    $daysApplying = ((Get-Date) - [datetime]$instance.endDateTime).TotalDays
    "In Applying for $([math]::Round($daysApplying,1)) day(s) (30-day ceiling before it needs escalation)"
}
```

**5. For a stuck custom-data resource, pull outstanding decisions**

```powershell
$decisions = Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/<DefinitionId>/instances/<InstanceId>/decisions?`$filter=(resourceId eq '<CustomDataResourceId>')" |
  Select-Object -ExpandProperty value
$decisions | Where-Object { $_.applyResult -eq "New" -or -not $_.applyResult } |
  Select-Object principal, decision, applyResult
```
Any decision without a non-"New" `applyResult` is why the instance can't reach `Applied`.

---

## Common Fix Paths

<details><summary>Fix 1 — Licensing gap (feature entirely unavailable)</summary>

**Symptom:** No "Review users access across multiple resource types within a catalog" template option when creating a new access review; catalogs exist but have no review-creation path referencing them.

```powershell
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "GOVERNANCE|Entra_Suite" } |
    Select-Object SkuPartNumber, ConsumedUnits, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}
```

**Fix:** Confirm Microsoft Entra ID Governance or Microsoft Entra Suite licensing with the tenant owner. Unlike several base Access Reviews capabilities, there is no P1/P2-only tier that unlocks catalog/UAR reviews — this is an all-or-nothing gate.

**Rollback:** N/A — informational.

</details>

<details><summary>Fix 2 — Reviewer can't find the review</summary>

**Cause:** Catalog/UAR reviews surface in a separate tab from ordinary single-resource reviews in the My Access portal.

**Fix:** Have the reviewer sign in to `https://myaccess.microsoft.com`, select **Access reviews** in the left menu, then select the **Multi-resource** tab specifically — not the default single-resource list. Confirm they're signed in as the correct reviewer identity (manager-based reviews assign to the target user's manager, not the target user themselves).

**Rollback:** N/A — navigation guidance only.

</details>

<details><summary>Fix 3 — Custom data resource shows zero reviewable items</summary>

**Cause:** Custom data must be uploaded (up to 10 CSVs) within a **2-hour window** starting when the instance enters `Initializing`. Miss the window and that resource simply has nothing to review for that cycle — no error is raised to the reviewer, it just looks empty.

```powershell
$instance = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/<DefId>/instances/<InstanceId>"
$instance.status   # if still "Initializing" and > 2h since creation, the window is closing/closed
```

**Fix (if still inside the window):** In the source catalog → Resources → select the custom data resource → **Upload custom access data** → provide the Access Review definition object ID and instance object ID (from the review's overview/instance screen) → upload up to 10 CSVs with all six mandatory columns (`PrincipalId`, `PrincipalType` = `EntraIdUser`, `PermissionId`, `PermissionName`, `PermissionDescription`, `PermissionType`). Confirm success in the entitlement management audit log, not just the upload dialog.

**If the window already closed:** No supported way to retroactively add data to that instance. The custom-data portion of that cycle is a loss — plan the next cycle's upload earlier, ideally scripted immediately after instance creation is detected.

**Rollback:** N/A — data upload, not a destructive action.

</details>

<details><summary>Fix 4 — Review stuck in "Applying" (custom-data decisions never applied)</summary>

**Cause:** Group and application decisions in a catalog review auto-apply in the `Applying` stage exactly like a standard review. Custom Data Provided Resource decisions do **not** — there is no connector to action them automatically. Someone (or some integration) must: pull denied decisions, remove access in the actual source system, then PATCH each decision item to report success.

```powershell
# 1. Get denied decisions for the custom-data resource
$denied = Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/<DefId>/instances/<InstanceId>/decisions?`$filter=(decision eq 'Deny' and resourceId eq '<CustomDataResourceId>')" |
  Select-Object -ExpandProperty value

# 2. For each, remove access in the actual disconnected system (ServiceNow ticket,
#    manual admin action, whatever the resource actually is), THEN report back:
foreach ($d in $denied) {
    Invoke-MgGraphRequest -Method PATCH `
      -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/<DefId>/instances/<InstanceId>/decisions/$($d.id)" `
      -Body (@{ applyResult = "AppliedSuccessfully"; applyDescription = "Removed via <ticket/system reference>" } | ConvertTo-Json)
}
```

The instance moves to `Applied` only once **every** decision item across **every** resource type reports a non-"New" `applyResult`. Partial completion leaves it in `Applying` indefinitely (documented 30-day ceiling before it should be escalated as stuck).

**Rollback:** If access was removed in error, re-grant it in the source system directly — the review engine has no undo for custom-data decisions since it never had write access to that system in the first place.

</details>

<details><summary>Fix 5 — Catalog resource change not reflected in the review</summary>

**Cause:** A documented 12-hour freeze window exists before a review's `startDateTime` — resource additions/removals to the catalog inside that window may not carry into the instance.

**Fix:** No remediation for the current instance. For the next cycle, make catalog membership changes more than 12 hours before the scheduled start, or manually re-trigger/re-scope if the review supports recreation.

**Rollback:** N/A — timing constraint, not a bug.

</details>

<details><summary>Fix 6 — Can't add a second-stage reviewer to a custom-data resource</summary>

**Cause:** Custom Data Provided Resource reviews are documented as single-stage, manager-only. Groups and applications in the same catalog DO support multi-stage (resource owner as stage 2) — this is a genuine capability gap between resource types within the same catalog review, not a misconfiguration.

**Fix:** None available for the custom-data portion. If owner-based secondary review is a hard requirement, that resource needs to become a connected resource type (group/app) instead of custom data, or the requirement should be handled by a separate manual review process outside UAR for that specific resource.

**Rollback:** N/A.

</details>

<details><summary>Fix 7 — Graph automation fails with permission error</summary>

**Symptom:** `Authorization_RequestDenied` on catalog or access-review-definition calls.

```powershell
# Catalog reads/writes
Connect-MgGraph -Scopes "EntitlementManagement.Read.All"      # read
Connect-MgGraph -Scopes "EntitlementManagement.ReadWrite.All" # catalog/resource changes

# Access review reads/writes (definitions, instances, decisions)
Connect-MgGraph -Scopes "AccessReview.Read.All"                # read
Connect-MgGraph -Scopes "AccessReview.ReadWrite.All"           # create/update/PATCH decisions
```

App-only (service principal) automation needs the equivalent Application permission with admin consent granted — delegated scopes above are for interactive sessions only.

**Rollback:** N/A.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Entra ID Governance Catalog / User-centric Access Reviews (UAR)
=====================================================================================
Date/Time of issue:              ___________________________
Tenant ID:                       ___________________________
Catalog name/ID:                 ___________________________
Access review definition ID:     ___________________________
Instance ID:                     ___________________________

Symptom:
  [ ] Feature not available (licensing)
  [ ] Reviewer can't find the review
  [ ] Custom data resource shows nothing to review
  [ ] Stuck in Applying past end date
  [ ] Catalog resource change not reflected
  [ ] Can't add second-stage reviewer to custom-data resource
  [ ] Graph permission error

Licensing confirmed:              [ ] Entra ID Governance  [ ] Entra Suite  [ ] Neither found
Resource types in this catalog:   [ ] Groups/Teams  [ ] Applications  [ ] Custom Data Provided
Instance status:                  ___________________________
Days in current status:           ___________________________
Custom-data decisions unapplied:  _____ / _____ total decisions

Upload window compliance (custom data resources only):
  Instance entered Initializing:  ___________________________
  CSV uploaded within 2 hours:    [ ] Yes  [ ] No  [ ] N/A

Attached evidence:
  [ ] Access review definition export (scope, reviewer config)
  [ ] Decision list export (filtered to affected resource)
  [ ] Entitlement management audit log excerpt (upload confirmation)

Support contact: https://admin.microsoft.com → Support → New service request
Product: Microsoft Entra ID Governance — Access Reviews (Catalog / UAR)
```

---

## 🎓 Learning Pointers

- **UAR has no partial-license fallback** — unlike base Access Reviews (which run core functionality on P2 and gate only inactive-user/affiliation recommendations behind Governance), catalog/user-centric reviews require Entra ID Governance or Entra Suite outright. Don't assume P2 alone gets you anything here. [MS Docs: Catalog Access Reviews](https://learn.microsoft.com/en-us/entra/id-governance/catalog-access-reviews)

- **Custom-data decisions do not auto-apply — ever** — this is the single most common "review is stuck" ticket for this feature. Group and application decisions in the same catalog review auto-apply normally in the `Applying` stage; custom data provided resource decisions require an external system integration to remove access and PATCH the decision item back via Graph. Budget for that integration before promising a customer "fully automated" UAR for disconnected apps. [MS Docs: Custom data provided resource access reviews](https://learn.microsoft.com/en-us/entra/id-governance/custom-data-resource-access-reviews)

- **The 2-hour custom-data upload window is unforgiving and silent** — miss it and that resource contributes zero reviewable items for the cycle, with no error surfaced to anyone. If a customer commits to UAR for a disconnected app, script the CSV upload to fire immediately on instance creation rather than relying on a human noticing the `Initializing` state in time.

- **"I can't find my review" is almost always the wrong My Access tab** — catalog/UAR reviews live under the **Multi-resource** tab, separate from the default single-resource Access reviews list. This is worth adding to any customer-facing UAR rollout communication, since it will otherwise generate a support ticket on day one.

- **Multi-stage review support is resource-type-dependent within the same catalog review** — groups and applications support a second-stage owner reviewer; custom data provided resources are locked to single-stage, manager-only. Don't design a review workflow assuming uniform reviewer-stage behavior across every resource type in one catalog.

- **The 12-hour pre-start freeze on catalog membership changes is a real operational constraint** — if a customer adds or removes a resource from the catalog right before a scheduled review kicks off, don't assume the instance reflects it; confirm against the instance's actual resource scope rather than the current catalog contents. [MS Docs: What are access reviews?](https://learn.microsoft.com/en-us/entra/id-governance/access-reviews-overview)
