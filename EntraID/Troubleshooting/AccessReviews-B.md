# Entra ID Governance — Access Reviews — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Scope note:** Access Reviews are periodic *recertification* of existing access (group membership, app assignment, access package assignment, Entra/Azure role assignment). This is distinct from `PIM-B.md` (role **activation** failures) and `AccessPackages-B.md` (entitlement management **delivery**, i.e. getting access in the first place). A user can be blocked activating a PIM role (PIM-B) or an access review can later ask whether they should keep that role at all (this file) — different failure modes, different fixes.

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
# 1. Confirm Entra ID Governance / Entra Suite licensing (some capabilities work with P2 alone)
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "AAD_PREMIUM_P2|GOVERNANCE|Entra_Suite" } |
    Select-Object SkuPartNumber, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}

# 2. List active access review definitions
Connect-MgGraph -Scopes "AccessReview.Read.All"
Get-MgIdentityGovernanceAccessReviewDefinition -All |
    Select-Object Id, DisplayName, Status, @{N="Reviewers";E={($_.Reviewers.Query -join ", ")}}

# 3. Check a specific review's current instance status (recurring reviews create one instance per cycle)
Get-MgIdentityGovernanceAccessReviewDefinitionInstance -AccessReviewScheduleDefinitionId "<DefinitionId>" |
    Select-Object Id, Status, StartDateTime, EndDateTime

# 4. Check decisions recorded so far for an instance
Get-MgIdentityGovernanceAccessReviewDefinitionInstanceDecision `
    -AccessReviewScheduleDefinitionId "<DefinitionId>" -AccessReviewInstanceId "<InstanceId>" |
    Select-Object PrincipalId, Decision, ReviewedBy, ReviewedDateTime

# 5. Check Entra audit log for review lifecycle events (last 7 days)
Get-MgAuditLogDirectoryAudit -Filter "category eq 'AccessReviews'" -Top 25 |
    Select-Object ActivityDisplayName, ActivityDateTime, Result, @{N="Target";E={$_.TargetResources.DisplayName -join ", "}}
```

**Interpretation table:**

| Result | What it means | Action |
|---|---|---|
| No P2/Governance SKU found | Feature may be partially or fully unavailable | Fix 1 |
| Review `Status = NotStarted` past its scheduled start | Reviewers not yet notified, or a scheduling gap | Fix 2 |
| Review `Status = InProgress` but no decisions recorded near the end date | Reviewers never received/actioned the notification | Fix 2 |
| `Status = Completed` but access wasn't removed | Auto-apply wasn't enabled, or the resource is an on-prem synced group | Fix 3 |
| Application not appearing as a reviewable resource type | App's "User assignment required" is set to No | Fix 4 |
| Group owner can't create a review for their own group | Admin hasn't enabled "Allow group owners to create and manage access reviews" | Fix 5 |
| Graph API call fails with `Authorization_RequestDenied` | Wrong permission scope — reads need `AccessReview.Read.All`, writes need `AccessReview.ReadWrite.All` | Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Entra ID Governance or Microsoft Entra Suite license
(some capabilities work with Entra ID P2 alone — inactive-user and
 user-to-group-affiliation recommendations specifically require Governance)
    │
    └── Access Review Definition (accessReviewScheduleDefinition)
            ├── Scope: what's being reviewed
            │       ├── Group membership (cloud-native OR on-prem synced — synced groups
            │       │       can be REVIEWED but not directly REMEDIATED by the review itself)
            │       ├── Application assignment (requires "User assignment required" = Yes
            │       │       on the app registration — otherwise nothing to review)
            │       ├── Access package assignment (entitlement management — configured on
            │       │       the access package's Lifecycle policy, not as a standalone review)
            │       └── Entra role / Azure resource role assignment (via PIM)
            │
            ├── Reviewer assignment (decided at creation time — CANNOT be changed after start)
            │       ├── Resource owner(s) — with fallback reviewer if unavailable
            │       ├── Specific individually-selected user(s)
            │       ├── Self-attestation (members review their own access)
            │       └── Manager (of each reviewed user) — with fallback reviewer
            │
            ├── Notification delivery
            │       └── Requires valid email address on each reviewer's Entra ID object
            │
            └── Instance lifecycle (one per recurrence)
                    ├── NotStarted → InProgress → Completed
                    ├── Decisions collected (Approve/Deny/DontKnow/NotReviewed)
                    ├── (Optional) Recommendations applied automatically if reviewer doesn't respond
                    └── (Optional) Auto-apply results — REQUIRED for automatic removal;
                            without it, an admin must manually apply results after the review ends
```

**Common gaps:**
- Auto-apply is off by default on manually-created reviews — a "completed" review with denied access decisions does nothing until someone applies the results.
- On-premises AD-synced groups have their source of authority on-prem — access reviews can survey and record decisions, but cannot write membership changes back. Requires group writeback (Cloud Sync) or manual/scripted follow-up.
- An application only becomes reviewable once "User assignment required?" is set to Yes on the Enterprise App — otherwise Entra ID treats it as open to all users and there's no discrete assignment list to review.

</details>

---

## Diagnosis & Validation Flow

**1. Identify the failure category**

```
Review never started / no notifications sent?          → Fix 2
Review completed but access not actually removed?        → Fix 3
Application doesn't show up as a reviewable resource?     → Fix 4
Group owner can't create/manage their own group's review? → Fix 5
Graph API script fails with permission error?              → Fix 6
Guest user list in review is missing expected accounts?    → Fix 7
```

**2. Confirm the review's resource type and reviewer type**

```powershell
Get-MgIdentityGovernanceAccessReviewDefinition -AccessReviewScheduleDefinitionId "<DefinitionId>" |
    Select-Object DisplayName, @{N="Scope";E={$_.Scope.AdditionalProperties}}, @{N="ReviewerType";E={$_.Reviewers.AdditionalProperties}}
```

**3. Confirm the instance is actually in progress and reviewers were notified**

Reviewer notification is email-based; there is no PowerShell/Graph confirmation of "email delivered." If a reviewer denies receiving it, check:
- Their Entra ID object has a valid, monitored email address (`Get-MgUser -UserId <id> | Select Mail,OtherMails`)
- They aren't filtering the notification as spam (sender is typically a Microsoft-owned no-reply address)
- The review's `startDateTime` has actually passed

**4. Confirm auto-apply and completion settings**

```powershell
Get-MgIdentityGovernanceAccessReviewDefinition -AccessReviewScheduleDefinitionId "<DefinitionId>" |
    Select-Object -ExpandProperty Settings
```
Look for `autoApplyDecisionsEnabled` — if `$false`, nothing is auto-removed regardless of decisions recorded.

**5. Confirm required Graph permissions for automation**

```powershell
Get-MgContext | Select-Object -ExpandProperty Scopes
```
Reads require `AccessReview.Read.All`; any create/update/delete/apply-decisions operation requires `AccessReview.ReadWrite.All`.

---

## Common Fix Paths

<details><summary>Fix 1 — Licensing gap (missing Entra ID Governance features)</summary>

**Symptom:** Reviews of inactive users, or "user-to-group affiliation" recommendations, aren't available even though basic access reviews work.

**Cause:** Basic access reviews (groups, apps) can run on Entra ID P2. Specific advanced capabilities — reviews of inactive users and user-to-group affiliation-based recommendations — require a Microsoft Entra ID Governance or Entra Suite license specifically, not just P2.

```powershell
Get-MgSubscribedSku | Where-Object { $_.ServicePlans.ServicePlanName -match "GOVERNANCE|Entra_Suite|AAD_PREMIUM_P2" } |
    Select-Object SkuPartNumber, ConsumedUnits, @{N="Enabled";E={$_.PrepaidUnits.Enabled}}
```

**Fix:** Confirm licensing tier with the customer/tenant owner; if only P2 is present, either scope reviews to features available at that tier or upgrade licensing.

**Rollback:** N/A — informational.

</details>

<details><summary>Fix 2 — Review not starting / reviewers not notified</summary>

**Symptoms:** Review shows `NotStarted` past its scheduled date, or is `InProgress` with zero decisions and reviewers say they never got an email.

**Checks:**
```powershell
# Confirm reviewer(s) have valid mail attributes
Get-MgUser -UserId "<ReviewerObjectId>" | Select-Object DisplayName, Mail, OtherMails, UserType

# Manually send a reminder (works mid-cycle; doesn't restart the review)
# No direct PowerShell cmdlet for sendReminder in all SDK versions — use Graph API directly:
Invoke-MgGraphRequest -Method POST `
  -Uri "https://graph.microsoft.com/v1.0/identityGovernance/accessReviews/definitions/<DefId>/instances/<InstanceId>/sendReminder"
```

**If the review genuinely never started (definition exists, no instance created):**
- Check the definition's `Settings.recurrence` — a misconfigured recurrence pattern (e.g. end date in the past) silently prevents new instances from being created.
- Re-create the review definition if the recurrence is unrecoverable via the portal (Identity Governance → Access reviews → New access review).

**Rollback:** N/A — reminders and diagnostics are non-destructive.

</details>

<details><summary>Fix 3 — Review completed but access wasn't removed</summary>

**Cause A — Auto-apply was never enabled:**
```powershell
Get-MgIdentityGovernanceAccessReviewDefinition -AccessReviewScheduleDefinitionId "<DefId>" |
    Select-Object -ExpandProperty Settings
```
If `AutoApplyDecisionsEnabled` is `$false`, an admin must manually apply results:
```powershell
Invoke-MgGraphRequest -Method POST `
  -Uri "https://graph.microsoft.com/v1.0/identityGovernance/accessReviews/definitions/<DefId>/instances/<InstanceId>/applyDecisions"
```

**Cause B — Reviewed resource is an on-premises AD-synced group:**
Access reviews cannot write membership changes back to on-prem AD — this is a hard architectural limitation (source of authority is on-prem). Options:
1. Configure Microsoft Entra Cloud Sync **group writeback** so the group becomes eligible for direct remediation, or
2. Export decisions and action them manually/via script against on-prem AD:
```powershell
# Retrieve decisions for manual/scripted on-prem remediation
Get-MgIdentityGovernanceAccessReviewDefinitionInstanceDecision `
    -AccessReviewScheduleDefinitionId "<DefId>" -AccessReviewInstanceId "<InstanceId>" |
    Where-Object Decision -eq "Deny" |
    Select-Object PrincipalId, Decision, Justification
# Then use the Microsoft sample script pattern (AzureADAccessReviewsOnPremises) to translate
# denied PrincipalIds into Remove-ADGroupMember calls against the source AD group.
```

**Cause C — Self-reviewed "no longer need access" isn't immediate by design:**
Users who self-attest they no longer need access are NOT removed immediately — removal happens only when the review instance ends (or is manually stopped). This is expected behavior, not a bug.

**Rollback:** If auto-apply removed access incorrectly, manually re-add the principal to the group/app/role — access reviews don't retain an automatic "undo."

</details>

<details><summary>Fix 4 — Application not reviewable</summary>

**Cause:** Access reviews for applications only work when the app enforces assignment. If "User assignment required?" is `No`, Entra ID treats the app as open to the entire directory — there's no discrete list to review.

```powershell
Get-MgServicePrincipal -Filter "displayName eq '<AppName>'" | Select-Object DisplayName, AppRoleAssignmentRequired
```

**Fix:**
```powershell
$sp = Get-MgServicePrincipal -Filter "displayName eq '<AppName>'"
Update-MgServicePrincipal -ServicePrincipalId $sp.Id -AppRoleAssignmentRequired
# Then explicitly assign the intended users/groups so there's a defined population to review
```

**Caution:** Flipping this to required will immediately block anyone NOT explicitly assigned from accessing the app — coordinate with the app owner before changing in production; assign all currently-legitimate users/groups first.

**Rollback:** `Update-MgServicePrincipal -ServicePrincipalId $sp.Id -AppRoleAssignmentRequired:$false` (returns to open access for all users).

</details>

<details><summary>Fix 5 — Group owner can't create/manage a review for their own group</summary>

**Cause:** By default, only directory-role holders (Global Administrator, User Administrator, Identity Governance Administrator, Privileged Role Administrator for role-assignable groups) can create access reviews — group owners cannot, unless explicitly enabled.

**Fix (portal-only setting, no dedicated Graph cmdlet in all SDK versions):**
Identity Governance → Access reviews → Settings → **"Allow group owners to create and manage access reviews of their groups"** → toggle on.

**Rollback:** Toggle the setting back off; existing reviews created by group owners are not retroactively affected.

</details>

<details><summary>Fix 6 — Graph API script fails with permission error</summary>

**Symptom:** `Authorization_RequestDenied` or similar on `Get-MgIdentityGovernanceAccessReviewDefinition*` / `New-MgIdentityGovernanceAccessReviewDefinition` calls.

```powershell
# Reads
Connect-MgGraph -Scopes "AccessReview.Read.All"
# Writes (create/update/delete/apply decisions)
Connect-MgGraph -Scopes "AccessReview.ReadWrite.All"

# For app-only (service principal) automation, the app registration itself needs the
# application permission granted + admin consent — delegated scopes above are for interactive use only.
```

Least-privileged directory roles for interactive use: **Global Reader / Security Reader / Security Administrator / User Administrator** for read; **User Administrator** for create/update/delete (per-resource-type nuances apply — see `AccessReviews-A.md`).

**Rollback:** N/A.

</details>

<details><summary>Fix 7 — Guest user list in a review is missing expected accounts</summary>

**Cause:** The "Guest users only" scoping option in group/app reviews only includes Microsoft Entra B2B guests (`userType = Guest`, invited via B2B collaboration). It explicitly excludes:
- External identities with `userType = Member` (e.g. certain cross-tenant sync configurations)
- Users granted access directly through SharePoint sharing outside of B2B invitation flow

**Fix:** For a complete external-access picture, don't rely solely on the review's guest scope — cross-reference with `Get-MgUser -Filter "userType eq 'Guest'"` and any direct-sharing reports from the target resource (e.g. SharePoint sharing reports) separately.

**Rollback:** N/A — informational/reporting gap, not a configuration error.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Entra ID Governance Access Reviews
=========================================================
Date/Time of issue:              ___________________________
Tenant ID:                       ___________________________
Review definition name/ID:       ___________________________
Resource type under review:      [ ] Group  [ ] Application  [ ] Access package  [ ] Entra role  [ ] Azure resource role

Symptom:
  [ ] Review not starting / no notifications
  [ ] Completed but access not removed
  [ ] App not reviewable
  [ ] Group owner can't manage review
  [ ] Graph API permission error
  [ ] Guest list incomplete

Licensing confirmed:              [ ] P2  [ ] Entra ID Governance  [ ] Entra Suite  [ ] Unclear
Auto-apply enabled:                [ ] Yes  [ ] No
On-prem synced resource:           [ ] Yes  [ ] No
Reviewer type:                     [ ] Owner  [ ] Selected individual  [ ] Self  [ ] Manager

Instance ID:                       ___________________________
Instance status:                   ___________________________
Decisions recorded / expected:     _____ / _____

Audit log excerpt (Get-MgAuditLogDirectoryAudit, category AccessReviews): 
___________________________

Attached evidence:
  [ ] Access review definition export
  [ ] Decision list export
  [ ] Audit log export

Support contact: https://admin.microsoft.com → Support → New service request
Product: Microsoft Entra ID Governance — Access Reviews
```

---

## 🎓 Learning Pointers

- **Reviewer assignment is locked in at review creation and cannot be changed mid-cycle** — if you pick the wrong reviewer type (e.g. self-attestation instead of manager review), you must wait for the instance to complete or manually stop it and recreate the definition. Plan reviewer strategy carefully before scheduling. [MS Docs: Plan an access reviews deployment](https://learn.microsoft.com/en-us/entra/id-governance/deploy-access-reviews)

- **Auto-apply is not the default** — a review that completes with clear Deny decisions changes nothing on its own unless `autoApplyDecisionsEnabled` was set at creation. This is one of the most common "the review ran but nothing happened" tickets. [MS Docs: Complete an access review](https://learn.microsoft.com/en-us/entra/id-governance/complete-access-review)

- **On-premises synced groups are review-able but not remediable by the review engine itself** — the source of authority for AD-synced groups is on-prem, so Entra ID Governance can survey and record decisions but can't push membership changes back without group writeback or manual/scripted follow-up. [MS Docs: Review access to on-premises groups](https://learn.microsoft.com/en-us/entra/id-governance/deploy-access-reviews#review-access-to-on-premises-groups)

- **The Graph API for access reviews does not cover Azure resource role reviews** — only Entra directory roles and groups/apps/access packages are supported via `identityGovernance/accessReviews`. Azure resource role reviews (PIM for Azure resources) must be managed through the Azure portal or Azure Resource Manager APIs. Don't assume Graph API parity across every reviewable resource type. [MS Graph: Access reviews API overview](https://learn.microsoft.com/en-us/graph/api/resources/accessreviewsv2-overview)

- **"User assignment required" is the hidden prerequisite for application reviews** — an Enterprise App with this set to No has no discrete assignment list, so there's nothing for a review to enumerate. This is frequently the actual root cause behind "I can't find this app in the access review resource picker." [MS Docs: Plan reviews for applications](https://learn.microsoft.com/en-us/entra/id-governance/deploy-access-reviews#plan-access-reviews-for-applications)

- **Audit everything through the standard Entra audit log, not a separate access-reviews-specific log** — filter `category eq 'AccessReviews'` and the relevant `activityDisplayName` values (Create/Update/Delete access review, Approve/Deny/Reset decision, Apply decision, Access review ended) for post-incident review or compliance evidence. [MS Docs: Monitor access reviews](https://learn.microsoft.com/en-us/entra/id-governance/deploy-access-reviews#monitor-access-reviews)
