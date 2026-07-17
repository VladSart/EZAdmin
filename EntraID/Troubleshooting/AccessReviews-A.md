# Entra ID Governance — Access Reviews — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

Covers **Microsoft Entra Access Reviews** — the periodic recertification capability of Microsoft Entra ID Governance. Access reviews answer "does this principal still need this access?" for:

- Group membership (cloud-native and, with caveats, on-premises AD-synced groups)
- Application assignment (Enterprise Apps with assignment enforcement)
- Access package assignment (entitlement management lifecycle)
- Microsoft Entra role assignment (via PIM — eligible and active)
- Azure resource role assignment (via PIM for Azure resources)

**Explicitly out of scope** (see the linked topics instead):
- Role **activation** mechanics (approval flow, MFA-at-activation, TAP bootstrap) → `PIM-B.md` / `PIM-A.md`
- Access package **request/delivery** (approval workflow, connected org sync) → `AccessPackages-B.md` / `-A.md`
- General group lifecycle (dynamic membership rules, processing pipeline) → `DynamicGroups-B.md` / `-A.md`

Access Reviews is one of five Microsoft Entra ID Governance capabilities — the others are entitlement management, PIM, lifecycle workflows, and terms of use — together answering: who has access to what, what are they doing with it, is there effective control, and can auditors verify it.

**Assumptions:**
- Microsoft Entra ID Governance or Microsoft Entra Suite licensing for full capability; Entra ID P2 covers a meaningful subset
- Microsoft Graph PowerShell SDK (`Microsoft.Graph.Identity.Governance` module) or direct Graph REST calls for automation
- Familiarity with the general Entra RBAC role model for permission troubleshooting

---

## How It Works

<details><summary>Full architecture — review definitions, instances, decisions, and the remediation gap</summary>

### Object model

```
accessReviewScheduleDefinition   (the "review" as configured by an admin)
    │
    ├── scope: what resource type + which specific resource(s)
    ├── reviewers: who evaluates (fixed at creation, cannot change mid-cycle)
    ├── settings: recurrence, auto-apply, recommendations, notification behavior
    │
    └── instances (accessReviewInstance)   — one per recurrence cycle
            │
            ├── status: NotStarted → InProgress → Completed
            ├── startDateTime / endDateTime
            │
            └── decisions (accessReviewInstanceDecisionItem)  — one per principal-in-scope
                    ├── decision: Approve / Deny / DontKnow / NotReviewed
                    ├── reviewedBy / reviewedDateTime / justification
                    └── recommendation (system-generated, based on sign-in/access recency —
                            "user-to-group affiliation" recommendations require an Entra ID
                            Governance license specifically, not just P2)
```

### Who can be a reviewer — and why the choice is permanent per cycle

At definition creation time, the admin picks exactly one reviewer strategy:

| Reviewer type | Mechanics |
|---|---|
| Resource owner(s) | Group owners, access package catalog owners/managers. Fallback reviewer required in case the owner is unavailable. |
| Individually selected user(s) | Named delegate(s), independent of resource ownership. |
| Self (members review their own access) | Lowest admin overhead; relies on honest self-attestation; denial-by-self is not immediate (see remediation gap below). |
| Manager | Each reviewed user's manager evaluates their reports' access. Requires accurate manager attribute in Entra ID. Fallback reviewer required. |

This is locked for the life of the definition — changing reviewer strategy requires creating a new definition, not editing the existing one mid-cycle.

### The remediation gap — why "review completed" ≠ "access changed"

A completed review only changes actual access if **both** of the following are true:
1. `autoApplyDecisionsEnabled` was set to `true` at creation (off by default for hand-built reviews; on by default in some entitlement-management-integrated flows), AND
2. The underlying resource's source of authority is Microsoft Entra ID itself.

For resource #2 specifically, **on-premises AD-synced groups fail this test** — Entra ID Connect/Cloud Sync makes AD the source of authority, so Entra ID Governance can survey membership and record decisions, but literally cannot write a membership change back into AD. This is not a licensing or configuration gap — it's architectural. The only two paths forward are:
- **Group writeback** (Microsoft Entra Cloud Sync) — promotes the group to a state where Entra ID CAN push changes back to AD, OR
- **Manual/scripted remediation** — export decisions via Graph API, translate `Deny` decisions into `Remove-ADGroupMember` calls against the on-prem group directly.

### Self-review semantics — deliberately not instant

When a user self-reviews and indicates they no longer need access, Entra ID Governance does **not** remove them immediately. The removal is deferred until the review instance formally ends (its `endDateTime` passes) or an admin manually stops it. This is intentional — it keeps the audit trail consistent (a decision was "made" at time T, but "applied" at end-of-cycle time T+n) and avoids partial, straggling removals mid-review.

### Reviewable resource administrative permission model

Unlike most Entra ID features, the role required to **create and manage** a review, and the (different, broader) role required to merely **read results**, varies by the resource type under review:

| Resource type | Create/manage (creators) | Read results only |
|---|---|---|
| Group or application | Global Administrator, User Administrator, Identity Governance Administrator, Privileged Role Administrator (role-assignable groups only), Group owner (if explicitly enabled) | Global Administrator, Global Reader, User Administrator, Identity Governance Administrator, Privileged Role Administrator, Security Reader, Group owner (if enabled) |
| Microsoft Entra roles | Global Administrator, Privileged Role Administrator | Global Administrator, Global Reader, User Administrator, Privileged Role Administrator, Security Reader |
| Azure resource roles | User Access Administrator (for the resource), resource owner, custom role with `Microsoft.Authorization/*` | User Access Administrator, resource owner, Reader, custom role with `Microsoft.Authorization/*/read` |
| Access package | Global Administrator, Identity Governance Administrator, catalog owner, access package manager | Global Administrator, Global Reader, User Administrator, Identity Governance Administrator, catalog owner, access package manager, Security Reader |

This table is the first thing to check when a customer reports "I have Global Reader but can't create a review" — Global Reader is a **read-only** role for every resource type; it was never going to work for creation.

### Application reviewability gate

An Enterprise App is only reviewable if `appRoleAssignmentRequired` (portal: "User assignment required?") is `true`. If `false`, Entra ID treats the app as open to the entire directory by policy — there is no discrete assignment list for a review to enumerate against, so the app simply won't appear as a reviewable resource. This is the single most common "why can't I review this app" root cause.

### Graph API coverage gap for Azure resource roles

The `identityGovernance/accessReviews` Graph API surface supports Entra directory roles and Entra ID resources (groups, apps, access packages) — but **not** Azure resource role reviews (PIM for Azure resources). Those must be managed through the Azure portal or Azure Resource Manager APIs directly. Automation that assumes uniform Graph API coverage across every reviewable resource type will silently fail (or simply find nothing) for the Azure resource role case.

</details>

---

## Dependency Stack

```
Microsoft Entra ID tenant
        │
Microsoft Entra ID P2 (baseline) or Entra ID Governance / Entra Suite (full capability)
        │
        ├── accessReviewScheduleDefinition
        │       ├── Scope (resource type + specific resource — see reviewability gates below)
        │       │       ├── Group: cloud-native (fully remediable) vs. on-prem synced (survey-only
        │       │       │       unless group writeback is configured)
        │       │       ├── Application: requires appRoleAssignmentRequired = true
        │       │       ├── Access package: configured via the package's own Lifecycle policy tab,
        │       │       │       not as an independent review object
        │       │       └── Entra role / Azure resource role: surfaced through PIM's review UI,
        │       │               same underlying accessReviewScheduleDefinition object for Entra
        │       │               roles; Azure resource roles use a PARALLEL, non-Graph-API-exposed
        │       │               mechanism
        │       │
        │       ├── Reviewer strategy (fixed at creation — owner / individual / self / manager)
        │       │       └── Fallback reviewer (for owner/manager strategies)
        │       │
        │       └── Settings
        │               ├── Recurrence (one-time or recurring; malformed recurrence = instances
        │               │       silently stop generating)
        │               ├── autoApplyDecisionsEnabled (off by default — gates all automatic
        │               │       remediation)
        │               └── Recommendations (inactive-user / user-to-group-affiliation require
        │                       Entra ID Governance license specifically)
        │
        └── Audit trail: Microsoft Entra audit logs, category = AccessReviews
                (Create/Update/Delete access review, Access review ended, Approve/Deny/Reset/Apply decision)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "Global Reader can't create a review" | Global Reader is read-only for every resource type in this feature | Confirm role vs. resource-type table above; assign User Administrator or Identity Governance Administrator |
| Review completed, decisions all Deny, access unchanged | `autoApplyDecisionsEnabled` was false | `Get-MgIdentityGovernanceAccessReviewDefinition` → `Settings` |
| Review completed, decisions all Deny, access STILL unchanged even with auto-apply on | Resource is an on-prem AD-synced group (survey-only) | Confirm group's `OnPremisesSyncEnabled` property |
| App never shows as a reviewable resource in the picker | `appRoleAssignmentRequired` is false | `Get-MgServicePrincipal` → `AppRoleAssignmentRequired` |
| Group owner can't create a review of their own group | "Allow group owners..." setting not enabled tenant-wide | Identity Governance → Access reviews → Settings (portal-only) |
| Self-reviewed "no longer need access" user still has access mid-cycle | Expected — removal deferred until instance end, by design | Confirm instance `endDateTime` |
| Azure resource role review data missing from a Graph API script | Graph API doesn't support Azure resource role reviews | Use Azure portal / ARM API for this specific resource type |
| Reviewer never got a notification email | Missing/invalid `mail` attribute, or spam filtering of Microsoft no-reply sender | `Get-MgUser` → `Mail`/`OtherMails` |
| "Guest users only" review scope missing some external accounts | Only includes B2B `userType = Guest`; excludes `userType = Member` externals and non-B2B direct-share access | Cross-reference with a separate guest inventory / sharing report |
| Inactive-user or affiliation-based recommendations missing | Requires Entra ID Governance license, not just P2 | `Get-MgSubscribedSku` — confirm Governance/Entra Suite SKU present |
| Review shows `NotStarted` indefinitely | Malformed recurrence pattern (e.g., end date already in the past) | Recreate the definition with a valid recurrence window |

---

## Validation Steps

**1. Confirm licensing tier**
```powershell
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "AAD_PREMIUM_P2|GOVERNANCE|Entra_Suite" } |
    Select-Object SkuPartNumber, ConsumedUnits, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}
```

**2. Confirm the caller's role matches the resource-type-specific requirement**
```powershell
Get-MgContext | Select-Object Account, Scopes
Get-MgUserMemberOf -UserId (Get-MgContext).Account | Select-Object -ExpandProperty AdditionalProperties |
    Select-Object displayName
```
*Expected:* A role from the correct column (creator vs. reader) of the resource-type table for the action being attempted.

**3. Enumerate all review definitions and their settings**
```powershell
Connect-MgGraph -Scopes "AccessReview.Read.All"
Get-MgIdentityGovernanceAccessReviewDefinition -All |
    Select-Object Id, DisplayName, Status,
        @{N="AutoApply";E={$_.Settings.AdditionalProperties.autoApplyDecisionsEnabled}},
        @{N="Recurrence";E={$_.Settings.AdditionalProperties.recurrence}}
```

**4. Confirm resource reviewability before troubleshooting "why isn't this here"**
```powershell
# Application
Get-MgServicePrincipal -Filter "displayName eq '<AppName>'" | Select-Object DisplayName, AppRoleAssignmentRequired

# Group source of authority
Get-MgGroup -Filter "displayName eq '<GroupName>'" | Select-Object DisplayName, OnPremisesSyncEnabled, OnPremisesDomainName
```

**5. Confirm instance progress and decision counts**
```powershell
$instances = Get-MgIdentityGovernanceAccessReviewDefinitionInstance -AccessReviewScheduleDefinitionId "<DefId>"
foreach ($i in $instances) {
    $decisions = Get-MgIdentityGovernanceAccessReviewDefinitionInstanceDecision -AccessReviewScheduleDefinitionId "<DefId>" -AccessReviewInstanceId $i.Id
    [PSCustomObject]@{
        InstanceId = $i.Id
        Status     = $i.Status
        Total      = $decisions.Count
        Reviewed   = ($decisions | Where-Object Decision -ne "NotReviewed").Count
    }
}
```

**6. Confirm audit trail is capturing lifecycle events**
```powershell
Get-MgAuditLogDirectoryAudit -Filter "category eq 'AccessReviews'" -Top 50 |
    Select-Object ActivityDisplayName, ActivityDateTime, Result
```

**7. Confirm reviewer email deliverability prerequisites**
```powershell
Get-MgUser -UserId "<ReviewerId>" | Select-Object DisplayName, Mail, OtherMails, AccountEnabled
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Definition/permission issues

1. Confirm the caller's role against the resource-type-specific table — do not assume Global Reader or Security Reader is sufficient for creation; they're read-only across every resource type.
2. Confirm licensing tier matches the capability requested (basic reviews vs. inactive-user/affiliation recommendations).
3. For group-owner-initiated reviews, confirm the tenant-wide "Allow group owners..." setting is enabled (portal-only toggle, no dedicated read cmdlet in all SDK versions — verify via Identity Governance → Access reviews → Settings).

### Phase 2: Reviewability gate issues

1. For applications: confirm `AppRoleAssignmentRequired = $true`; if false, this is the root cause, full stop — no other troubleshooting will surface the app as reviewable until this changes.
2. For groups: confirm `OnPremisesSyncEnabled` — if true, set remediation expectations accordingly (survey-only unless writeback configured) before the review even starts, not after.
3. For access packages: confirm the review is configured on the package's own Lifecycle policy tab — it is not a standalone `accessReviewScheduleDefinition` created independently of the package.

### Phase 3: Notification and reviewer issues

1. Confirm reviewer(s) have valid `Mail`/`OtherMails` attributes.
2. Confirm the review's `startDateTime` has actually passed — a future-dated review correctly shows no notifications yet.
3. For owner/manager reviewer types, confirm a fallback reviewer is configured — if the primary reviewer is unavailable and no fallback exists, the review can stall indefinitely with zero decisions.
4. Manually trigger a reminder via Graph API (`sendReminder` action) rather than waiting for the next scheduled reminder cycle, when time-sensitive.

### Phase 4: Completion and remediation issues

1. Confirm `autoApplyDecisionsEnabled` on the definition's `Settings`.
2. If auto-apply is on but access still didn't change, check the resource's source of authority (on-prem sync) before assuming a product bug.
3. For self-review "no longer need access" cases reported as "not working," confirm this is expected deferred-removal behavior, not a fault — removal happens at instance end, not at decision time.
4. For manually-applied results, confirm the `applyDecisions` action actually succeeded (check the audit log for "Apply decision" entries) rather than assuming the API call completing means the removal completed — group/role removal itself can fail independently (e.g., last-owner protection on a group).

### Phase 5: Automation/Graph API issues

1. Confirm delegated or application permission scope matches the operation (`AccessReview.Read.All` vs. `AccessReview.ReadWrite.All`).
2. Confirm the resource type being automated is actually covered by the Graph API — Azure resource role reviews are not, and any script assuming otherwise needs a separate ARM-API-based path.
3. Use Graph Explorer to validate a new query shape before embedding it in a script — this is Microsoft's own recommended practice specifically for this API surface, given its relative complexity (schedule definitions, instances, and decisions are three separate object types with three separate endpoints).

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Stand up a first access review program (groups + apps, piloted)</summary>

**Scenario:** Tenant has never used access reviews; leadership wants a recertification program for external/guest access as a starting point.

**Steps:**
1. Identify pilot scope — start with a small, non-critical set of groups/apps, not "All groups" tenant-wide.
2. Confirm licensing (Entra ID Governance recommended for full capability; P2 sufficient for basic group/app reviews without advanced recommendations).
3. Create the review (portal recommended for first-time setup — Identity Governance → Access reviews → New access review):
   - Resource type: Groups or Apps
   - Scope: specific pilot resources
   - Reviewers: Owners (with a designated fallback reviewer — do not skip this)
   - Recurrence: start with a one-time review before committing to a recurring cadence
   - Auto-apply: leave OFF for the pilot, so an admin reviews outcomes before anything changes automatically
4. Monitor the pilot instance via `Get-MgIdentityGovernanceAccessReviewDefinitionInstance` for completion and decision coverage.
5. After a successful pilot, convert to a recurring review and enable auto-apply once confidence is established.
6. Document reviewer responsibilities and communicate the cultural shift (decisions moving from IT to resource owners) — this is explicitly called out as the top cause of failed access review rollouts.

**Rollback:** Delete the pilot review definition (`Remove-MgIdentityGovernanceAccessReviewDefinition`) — no access changes occurred if auto-apply was left off.

</details>

<details>
<summary>Playbook 2 — Enable remediation for an on-premises synced group via group writeback</summary>

**Scenario:** An access review of a hybrid-synced security group completes with clear Deny decisions, but nothing changes because the group's source of authority is on-prem AD.

**Steps:**
1. Confirm the group is a genuine sync candidate for writeback (security group or Microsoft 365 group originally created in Entra ID and synced back, or an AD-originated group being promoted — writeback mechanics differ; consult current Cloud Sync group writeback documentation for the specific group type).
2. Configure Microsoft Entra Cloud Sync group writeback for the target group scope.
3. Re-run or wait for the next review cycle; confirm `autoApplyDecisionsEnabled` remains appropriately set.
4. Validate that a Deny decision now actually removes the member from the on-prem group (check both Entra ID and on-prem AD post-sync).

**Interim/non-writeback alternative** (if writeback isn't feasible short-term):
```powershell
# Export decisions for manual/scripted on-prem action
$decisions = Get-MgIdentityGovernanceAccessReviewDefinitionInstanceDecision `
    -AccessReviewScheduleDefinitionId "<DefId>" -AccessReviewInstanceId "<InstanceId>" |
    Where-Object Decision -eq "Deny"
$decisions | Select-Object PrincipalId, Decision, Justification | Export-Csv "DeniedAccess.csv" -NoTypeInformation
# Cross-reference PrincipalId (Entra ID objectId) to on-prem sAMAccountName via ms-DS-ConsistencyGuid /
# ImmutableID mapping, then action with Remove-ADGroupMember on-prem.
```

**Rollback:** Disable writeback for the group scope; on-prem membership is unaffected by disabling writeback itself (only future review-driven changes stop flowing).

</details>

<details>
<summary>Playbook 3 — Bring Azure resource role reviews into a consistent reporting cadence despite the Graph API gap</summary>

**Scenario:** Tenant has both Entra role reviews (fully Graph-API-automatable) and Azure resource role reviews (portal/ARM-only) and wants consistent evidence-pack reporting across both for compliance.

**Steps:**
1. For Entra role reviews: automate collection via `identityGovernance/accessReviews` as with any other resource type.
2. For Azure resource role reviews: since Graph API access reviews don't cover this scope, use Azure PIM's own portal-based review creation/monitoring, or the Azure Resource Manager REST API (`Microsoft.Authorization/roleAssignmentScheduleRequests` and related PIM-for-Azure-resources endpoints) for automation instead.
3. Build a unified compliance report by combining both data sources at the reporting layer (e.g., a scheduled script that pulls Graph API results for Entra roles and ARM API results for Azure resource roles, merging into one CSV/dashboard) rather than expecting one API to cover both.
4. Document this split clearly for any team inheriting the automation — it is a genuine, current product limitation, not a bug to work around.

**Rollback:** N/A — this is a reporting/automation architecture decision, not a configuration change.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects Entra ID Access Reviews configuration and status for escalation or audit.
.DESCRIPTION Read-only. Exports review definitions, instance status, decision summaries, and
             reviewability-gate checks (app assignment requirement, group sync state) to CSV.
.NOTES       Requires: Microsoft.Graph.Identity.Governance module, Connect-MgGraph with
             AccessReview.Read.All, Directory.Read.All, and Application.Read.All scopes.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "C:\Temp\AccessReviews-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

function Write-Status { param([string]$Msg,[string]$Status="INFO") Write-Host "[$Status] $Msg" -ForegroundColor $(switch($Status){"OK"{"Green"}"WARN"{"Yellow"}"ERROR"{"Red"}default{"Cyan"}}) }

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Write-Status "Collecting access review definitions..."
$defs = Get-MgIdentityGovernanceAccessReviewDefinition -All
$defs | Select-Object Id, DisplayName, Status,
    @{N="AutoApply";E={$_.Settings.AdditionalProperties.autoApplyDecisionsEnabled}},
    @{N="Recurrence";E={$_.Settings.AdditionalProperties.recurrence | Out-String}} |
    Export-Csv "$OutputPath\review_definitions.csv" -NoTypeInformation

Write-Status "Collecting instance status per definition..."
$instanceRows = foreach ($def in $defs) {
    try {
        Get-MgIdentityGovernanceAccessReviewDefinitionInstance -AccessReviewScheduleDefinitionId $def.Id |
            Select-Object @{N="DefinitionId";E={$def.Id}}, @{N="DefinitionName";E={$def.DisplayName}}, Id, Status, StartDateTime, EndDateTime
    } catch { Write-Status "Could not get instances for $($def.DisplayName): $_" "WARN" }
}
$instanceRows | Export-Csv "$OutputPath\review_instances.csv" -NoTypeInformation

Write-Status "Collecting decision summaries (Total/Reviewed/Approved/Denied per instance)..."
$decisionRows = foreach ($inst in $instanceRows) {
    try {
        $decisions = Get-MgIdentityGovernanceAccessReviewDefinitionInstanceDecision `
            -AccessReviewScheduleDefinitionId $inst.DefinitionId -AccessReviewInstanceId $inst.Id
        [PSCustomObject]@{
            DefinitionName = $inst.DefinitionName
            InstanceId     = $inst.Id
            Total          = $decisions.Count
            Approved       = ($decisions | Where-Object Decision -eq "Approve").Count
            Denied         = ($decisions | Where-Object Decision -eq "Deny").Count
            NotReviewed    = ($decisions | Where-Object Decision -eq "NotReviewed").Count
        }
    } catch { Write-Status "Could not get decisions for instance $($inst.Id): $_" "WARN" }
}
$decisionRows | Export-Csv "$OutputPath\decision_summaries.csv" -NoTypeInformation

Write-Status "Checking application reviewability gate (AppRoleAssignmentRequired)..."
try {
    Get-MgServicePrincipal -All -Property DisplayName,AppRoleAssignmentRequired |
        Select-Object DisplayName, AppRoleAssignmentRequired |
        Export-Csv "$OutputPath\app_reviewability_gate.csv" -NoTypeInformation
} catch { Write-Status "Could not enumerate service principals: $_" "WARN" }

Write-Status "Checking recent AccessReviews audit log activity (last 7 days)..."
try {
    $since = (Get-Date).AddDays(-7).ToString("yyyy-MM-ddTHH:mm:ssZ")
    Get-MgAuditLogDirectoryAudit -Filter "category eq 'AccessReviews' and activityDateTime ge $since" -All |
        Select-Object ActivityDisplayName, ActivityDateTime, Result, @{N="Target";E={$_.TargetResources.DisplayName -join ", "}} |
        Export-Csv "$OutputPath\audit_log_last7days.csv" -NoTypeInformation
} catch { Write-Status "Could not query audit log: $_" "WARN" }

Write-Status "Evidence collected to: $OutputPath" "OK"
Write-Status "Files: $(Get-ChildItem $OutputPath | Measure-Object | Select-Object -ExpandProperty Count)" "OK"
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| List all review definitions | `Get-MgIdentityGovernanceAccessReviewDefinition -All` |
| Get a specific definition | `Get-MgIdentityGovernanceAccessReviewDefinition -AccessReviewScheduleDefinitionId <id>` |
| List instances for a definition | `Get-MgIdentityGovernanceAccessReviewDefinitionInstance -AccessReviewScheduleDefinitionId <id>` |
| List decisions for an instance | `Get-MgIdentityGovernanceAccessReviewDefinitionInstanceDecision -AccessReviewScheduleDefinitionId <id> -AccessReviewInstanceId <id>` |
| Send a reviewer reminder | `POST /identityGovernance/accessReviews/definitions/{id}/instances/{id}/sendReminder` |
| Manually apply decisions | `POST /identityGovernance/accessReviews/definitions/{id}/instances/{id}/applyDecisions` |
| Manually stop an instance | `POST /identityGovernance/accessReviews/definitions/{id}/instances/{id}/stop` |
| Reset decisions to NotReviewed | `POST /identityGovernance/accessReviews/definitions/{id}/instances/{id}/resetDecisions` |
| Check app reviewability gate | `Get-MgServicePrincipal -Filter "displayName eq '<name>'" \| Select AppRoleAssignmentRequired` |
| Check group sync state | `Get-MgGroup -Filter "displayName eq '<name>'" \| Select OnPremisesSyncEnabled` |
| Query AccessReviews audit log | `Get-MgAuditLogDirectoryAudit -Filter "category eq 'AccessReviews'"` |
| Required scope — read | `AccessReview.Read.All` |
| Required scope — write | `AccessReview.ReadWrite.All` |
| Portal — Access reviews | `entra.microsoft.com` → Identity governance → Access reviews |
| Portal — Group-owner review setting | Identity governance → Access reviews → Settings |

---

## 🎓 Learning Pointers

- **The role-per-resource-type permission table is the single most valuable reference in this topic** — "I have an admin role but can't create a review" almost always traces back to having a read-oriented role (Global Reader, Security Reader) applied to a create-oriented action. Memorize that Global Reader is read-only across every single resource type here. [MS Docs: Who will create and manage access reviews?](https://learn.microsoft.com/en-us/entra/id-governance/deploy-access-reviews#who-will-create-and-manage-access-reviews)

- **Auto-apply and source-of-authority are two independent gates, not one** — a review can have auto-apply correctly enabled and still not change anything if the target is an on-prem synced group. Diagnose both before concluding "the feature is broken." [MS Docs: Review access to on-premises groups](https://learn.microsoft.com/en-us/entra/id-governance/deploy-access-reviews#review-access-to-on-premises-groups)

- **Access reviews and PIM role activation are adjacent but distinct control planes** — PIM governs "can this user turn on this role right now," access reviews govern "should this user still have this role at all." A well-designed privileged access program uses both together: PIM for just-in-time elevation, access reviews for periodic recertification of the underlying eligibility. [MS Docs: What is Privileged Identity Management?](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-configure)

- **The Graph API surface for this feature has an asymmetry worth internalizing early:** Entra directory roles and Entra-native resources (groups/apps/access packages) are fully covered, but Azure resource role reviews are not. Any automation project scoping "all access reviews" needs a second, ARM-API-based code path for that one resource type. [MS Graph: Access reviews API overview](https://learn.microsoft.com/en-us/graph/api/resources/accessreviewsv2-overview)

- **Self-review's deferred-removal behavior is a deliberate audit-integrity design choice**, not a lag or bug — decisions are recorded at click-time but applied at cycle-end-time, keeping the review's "as of" evidence internally consistent. Explain this proactively to stakeholders who expect instant removal. [MS Docs: Self-review assigned access package(s)](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-reviews-self-review)

- **Plan reviewer strategy before creating the definition, not after** — reviewer type cannot be changed mid-cycle, and a stalled review with an unavailable reviewer and no fallback configured can sit indefinitely with zero decisions, silently failing a compliance deadline. [MS Docs: Who will review the access to the resource?](https://learn.microsoft.com/en-us/entra/id-governance/deploy-access-reviews#who-will-review-the-access-to-the-resource)
