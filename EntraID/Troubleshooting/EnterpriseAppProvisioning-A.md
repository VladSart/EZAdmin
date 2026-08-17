# Entra ID Enterprise Application (SCIM) Provisioning — Reference Runbook (Mode A: Deep Dive)
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
- **Outbound** automatic user (and, for supported apps, group) provisioning from Microsoft Entra ID to third-party SaaS applications via the SCIM 2.0 protocol, and via the Entra provisioning agent for on-premises LDAP/SQL/REST-SOAP/PowerShell/custom-ECMA targets
- Assignment-based scoping (direct assignment, security groups, dynamic groups) and attribute-based scoping filters
- Attribute mappings, matching attributes, expression mappings
- Provisioning cycle mechanics (initial vs. incremental), watermarks, and restart semantics
- Quarantine detection, escrow thresholds, and recovery
- Deprovisioning (disable vs. delete) behavior
- Provisioning logs and Microsoft Graph monitoring

**Does not cover:**
- **Entra Cloud Sync** (Entra ID as the *target*, syncing from on-prem AD DS into Entra ID via the lightweight provisioning-agent model) — architecturally the same underlying provisioning engine but a distinct configuration surface and failure mode set; see `CloudSync-A.md`/`-B.md`
- **Entra Connect Sync** (legacy on-prem sync engine, also AD DS → Entra ID) — see `Connect-Sync-A.md`/`-B.md`
- **Cross-tenant synchronization** (Entra tenant → Entra tenant, a related but separately configured and separately quarantined provisioning job type) — see `CrossTenant-A.md`/`-B.md`
- **App Registration / Service Principal credential and consent management** (the app's own identity, API permissions, client secrets) — those objects underpin the Service Principal this document provisions *through*, but their lifecycle is covered in `AppRegistrations-A.md`/`-B.md`
- **HR-driven inbound provisioning** (Workday, SuccessFactors → Entra ID as the source of new accounts) — shares the same provisioning engine and log surface but a different direction of data flow and its own connector-specific quirks; not detailed here
- **SAML/OIDC single sign-on configuration** for the same application — SSO and provisioning are independently configured features of the same Enterprise Application object and can be enabled/broken independently of each other

**Assumes:**
- Microsoft Graph PowerShell SDK installed (`Install-Module Microsoft.Graph -Scope CurrentUser`), authenticated via `Connect-MgGraph` with at minimum `Application.Read.All` (read) or `Application.ReadWrite.All` (remediation) and `AuditLog.Read.All` (provisioning logs) scopes
- The target application is either a gallery app with a pre-built SCIM connector, or a non-gallery app exposing a SCIM 2.0-compliant endpoint
- Reader has Cloud Application Administrator, Application Administrator, or a custom role with provisioning-config permissions (Global Reader **cannot** read provisioning configuration — see Fix 5 in `-B.md`'s escalation notes below)

---
## How It Works

<details><summary>Full architecture</summary>

### The provisioning service, in one sentence

The Microsoft Entra provisioning service is a Microsoft-hosted job runner that periodically diffs Entra ID (or another configured source) against a target system's user/group API, and issues Create/Update/Disable/Delete calls to keep the target in sync — using the SCIM 2.0 protocol directly for SaaS apps, or via an on-premises provisioning agent (translating SCIM operations into LDAP, SQL, REST/SOAP, PowerShell, or a custom ECMA connector call) for on-prem targets.

```
┌─────────────────────────┐        HTTPS / TLS 1.2, SCIM 2.0 REST         ┌──────────────────────┐
│   Microsoft Entra ID     │ ───────────────────────────────────────────▶ │  Target SaaS app's    │
│  (source of truth: users,│         (Create / Update / Disable / Delete) │  SCIM 2.0 endpoint    │
│   groups, attributes)    │ ◀─────────────────────────────────────────── │  (vendor-hosted)      │
└─────────────────────────┘        query for existing users/groups        └──────────────────────┘
             │
             │  (on-prem targets only)
             ▼
   Entra provisioning agent  ──▶  LDAP / SQL / REST-SOAP / PowerShell / custom ECMA connector
   (installed on-prem, translates SCIM ops to the target protocol)
```

### Scoping — two independent mechanisms, usually both matter

1. **Assignment-based scoping** — the primary mechanism for outbound provisioning. When the job's scope is **Sync only assigned users and groups**, the service reads the Enterprise Application's App Role Assignments: direct user assignment, or membership of a security group (requires Entra ID P1/P2 and the group's `SecurityEnabled` property set to `True`) or a dynamic group. Because assignment also drives SSO access, the same group commonly gates both — but they are evaluated independently and can be toggled apart.
   - **Nested groups are not read.** The service only enumerates *immediate/direct* members of an assigned group. A user who is only a member of a group nested inside the assigned group is invisible to provisioning, even though they may have working SSO access through the same nesting (SSO group-based assignment shares this exact limitation).
   - **Dynamic groups** are supported, but provisioning speed is bound by how fast the dynamic group itself re-evaluates membership — a slow-to-evaluate dynamic group directly delays provisioning/deprovisioning. Losing dynamic group membership is treated as a deprovisioning event.
2. **Attribute-based scoping filters** — layered on top of assignment, defined as part of the attribute mappings for the connector. Primarily used for **inbound** scenarios (HCM → Entra ID) but usable outbound too. Not every attribute is eligible: `appRoleAssignments`, `userType`, `manager`, and date-type attributes (hire date, termination date, etc.) are explicitly unsupported as scoping-filter attributes.

### Attribute mappings and the matching attribute

Attribute mappings define which Entra ID user/group properties flow to which target-system properties, and in which direction (Create/Update/Delete individually toggleable as "target object actions"). One mapping is structurally special: **"Match objects using this attribute"** — the join key the service uses to decide whether an incoming source object already exists in the target. Get this wrong (e.g., mapping to a non-unique or frequently-changing attribute) and the service will either create duplicate accounts or silently update the wrong existing one.

Expression mappings allow script-like transformation of source values (e.g., concatenation, substring, function chains) for target systems needing a different format — capped at 10,000 characters per expression. A small set of attributes can never be used as **source** attributes at all (`SamAccountName`, `userType` — workaround: mirror them into a directory extension attribute first).

### Provisioning cycles: initial vs. incremental

**Initial cycle** (first run, or after any full restart): queries *every* user/group from the source, filters by assignment/scoping, matches or creates each one in the target, links reference attributes (e.g., Manager), then persists a **watermark** — the delta-query checkpoint that makes every subsequent cycle fast. Duration: 20 minutes to several hours depending on directory size; this is expected and is the single most common "is it stuck?" false alarm.

**Incremental cycles** run indefinitely afterward, at a **fixed, per-application, non-configurable interval** (documented per-app in its gallery tutorial). Each incremental cycle queries only what changed since the watermark, applies the same scoping/matching logic, and additionally handles the deprovisioning triggers below. A new initial cycle (and a fresh watermark) is forced by any of:
- Manually selecting **Restart provisioning**
- A change to attribute mappings or scoping filters (automatic, silent — the job is not stuck, it is re-evaluating the entire directory)
- Exiting quarantine after 4+ weeks (job auto-disabled instead)
- A Microsoft Graph `POST .../restart` call

### Deprovisioning — disable vs. delete

| Trigger | Result |
|---|---|
| User unassigned from the app, or falls out of scope (fails a scoping filter) | Disable (soft, via `active: false` in SCIM) — unless the target doesn't support soft-delete, in which case a hard DELETE is sent |
| User soft-deleted in Entra ID (in the 30-day recycle bin) | Disable in target |
| User permanently/hard-deleted from Entra ID (automatic 30 days after soft-delete, or manually) | DELETE in target |
| Admin sets **skip out-of-scope deletions** | Overrides the disable-on-unassign/out-of-scope behavior entirely — nothing is done |

The `isSoftDeleted` attribute mapping, if present, controls which target attribute receives the disable signal; removing it from mappings (with skip-out-of-scope-deletions also set) is the supported way to make unassignment a no-op in the target app. **Known limitation:** reactivating a soft-deleted user re-activates them in the target app but does **not** automatically restore dynamic-group-driven role/membership state — a manual restart is required to re-evaluate and reapply it.

</details>

---
## Dependency Stack

```
Layer 5 — Target application's SCIM 2.0 endpoint (vendor-owned, must return 200 OK not 404/other codes
          the service can't interpret; drives SCIM Compliance quarantine if malformed)
Layer 4 — Admin Credentials (secret token / OAuth) authorizing Entra ID → target endpoint
          (drives Invalid Credentials quarantine if wrong/expired)
Layer 3 — Attribute Mappings + Matching Attribute + Scoping Filters
          (silently forces a full restart on any edit; governs Create/Update/Delete eligibility per attribute)
Layer 2 — Assignment (direct / security group / dynamic group, DIRECT MEMBERS ONLY — no nested-group read)
          — the P1/P2-gated "who is even a candidate for provisioning" gate
Layer 1 — Microsoft Entra ID source data (user/group objects, their attribute values —
          a null/empty matching-attribute value blocks matching or creation outright)
Layer 0 — Microsoft Entra provisioning service itself (fixed per-app cycle interval, watermark state,
          quarantine/escrow bookkeeping — entirely Microsoft-hosted, no customer-side compute)
```

A failure at any layer masks visibility into the layers above it: a quarantined job (Layer 4) stops meaningfully exercising Layers 2–3 until credentials are fixed, which is why "nothing is happening" tickets should always start at Layer 4/0 before diagnosing individual users at Layer 1–2.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No users provisioned at all, job shows `Quarantine` | Invalid admin credentials, or SCIM compliance failure (unexpected HTTP status from target) | `Get-MgServicePrincipalSynchronizationJob` → `Status.QuarantineReason` |
| No users provisioned, job shows `Active`/healthy | Assignment scope is empty, or scoping filter excludes everyone | Check App Roles assignments; review scoping filter attribute values |
| One specific user skipped, log says "not effectively entitled" | Broken assignment record in Entra ID (common on Default Access role) | Unassign/reassign the user |
| One specific user skipped, log references a scoping filter | Attribute value doesn't satisfy the configured filter | Compare user's attribute value against filter condition |
| One specific user fails with a target-side unique-constraint error | Matching or unique attribute value duplicated across two source users | Query source for the duplicate value |
| Whole group of users never appears in target despite group being assigned | Users are only *nested* members, not direct members, of the assigned group | `Get-MgGroupMember` on the assigned group directly |
| Job progress frozen at a fixed percentage for hours | Either a legitimately large initial cycle in progress, or genuinely stalled — needs two time-separated checks to distinguish | `ProgressPercentage` delta across 30+ minutes |
| Manager attribute never populates in target | Manager was out of scope when the user was first provisioned; reference isn't retroactively fixed without a restart | Restart provisioning after the manager is confirmed in scope |
| Group's members provisioned but a specific member missing | That member was individually out of scope at the time the group was evaluated; membership return isn't detected until a restart | Restart provisioning periodically for group-membership drift |
| Changed Sync All → Sync Assigned, nothing changed | Scope-mode change requires a manual restart to take effect — the dropdown alone doesn't apply it | Trigger Restart provisioning explicitly |
| Users vanish unexpectedly from the target app | `isSoftDeleted`/disable mapping firing on an out-of-scope or soft-deleted source user, working as designed | Review the specific deprovisioning trigger in provisioning logs |
| Provisioning job simply doesn't exist for a custom OIDC app registration | Automatic provisioning isn't auto-enabled for app-registration-created service principals | Request gallery listing, or create a dedicated non-gallery provisioning app |
| Reader role can't see provisioning configuration at all | Global Reader is explicitly unable to read provisioning config | Grant a custom role with `microsoft.directory/applications/synchronization/standard/read` |

---
## Validation Steps

1. **Job exists and is enabled.**
   ```powershell
   Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id
   ```
   Expected: one job object, `Status.Code` = `Active`. Bad: no job returned (provisioning never configured or wrong Service Principal), or `Code` = `Paused`.

2. **Test Connection passes.** Portal-only check (**Provisioning → Edit provisioning → Test Connection**) — confirms Layer 4 (credentials) and Layer 5 (endpoint reachability/compliance) together. Expected: green success message. Bad: any failure here blocks the entire pipeline regardless of Layers 1–3.

3. **Assignment scope is non-empty.**
   ```powershell
   Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id | Measure-Object
   ```
   Expected: count > 0 (unless intentionally running Sync All). Bad: zero assignments with scope set to Sync Assigned — nothing will ever provision.

4. **Matching attribute has a value for a specific user.**
   ```powershell
   Get-MgUser -UserId "<user@contoso.com>" -Property "userPrincipalName,mail,employeeId"
   ```
   Confirm whichever attribute is configured as the matching attribute isn't null for the user in question.

5. **Provisioning log for that user shows Success or an explainable Skip.**
   Portal: **Provisioning logs**, filter by user. Expected: `Success`/`Skipped(with a documented reason)`. Bad: repeated `Failure` entries with the same unresolved error across multiple cycles.

6. **Last successful execution is recent relative to the app's documented interval.**
   ```powershell
   (Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id).Status.LastSuccessfulExecution
   ```
   Compare against the app-specific interval in its gallery tutorial (not configurable, and not identical across apps).

---
## Troubleshooting Steps (by phase)

**Phase 1 — Is the job even running?**
Check `Status.Code`. If `Quarantine`, stop here and resolve via the Quarantine playbook before doing anything else — every downstream check is unreliable while quarantined (cycles are throttled to once/day).

**Phase 2 — Is the target reachable and authenticated?**
Test Connection in the portal. A failure here is Layer 4/5 — fix credentials or confirm the target's SCIM endpoint is actually SCIM 2.0-compliant (returns 200 OK, not 404, for expected calls) before going further.

**Phase 3 — Is the user/group even in scope?**
Confirm assignment (direct, or via a group they are a **direct** member of) and check any scoping filter against the user's actual attribute values. This phase resolves the large majority of "why isn't this one person provisioning" tickets.

**Phase 4 — Is the matching/mapping configuration correct?**
Confirm the matching attribute is populated and genuinely unique per user; confirm required target attributes have values; confirm no two users collide on a unique-constrained attribute.

**Phase 5 — Read the actual provisioning log entry.**
Every prior phase is inference; the Provisioning Logs "Steps" tab states the exact reason for a skip or failure. Treat it as ground truth over any assumption made in Phases 1–4.

**Phase 6 — Escalate to the app vendor only after Phases 1–5 clear Entra ID's side.**
If Test Connection passes, scope/mapping/matching are all correct, and the log shows a failure response from the target system that doesn't match a known SCIM Compliance pattern, the fault is most likely in the vendor's SCIM implementation — escalate with the exact HTTP status/response body captured from the provisioning log.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Clear a quarantined job end-to-end</summary>

1. Identify quarantine reason via Graph (`QuarantineReason`: `EncounteredQuarantineException` = bad credentials, `EncounteredEscrowProportionThreshold` = failure-rate threshold, duplicate-roles for Salesforce/Zendesk-style apps, or `QuarantineOnDemand` = Microsoft manually flagged it).
2. Fix the underlying cause: re-enter credentials (portal only), or resolve the dominant failure pattern found in provisioning logs (grouped by `AdditionalDetails`), or de-duplicate a role in the app manifest.
3. Either wait for the next scheduled retry (6h → 12h → 24h → every 24h, for up to 28 days total) or force immediate re-evaluation with **Restart provisioning** (portal) / Graph `POST .../restart` with `resetScope: Full` (clears escrow, quarantine, and watermark together).
4. Confirm exit: `Status.Code` returns to `Active` and `QuarantineReason` is null after the next successful cycle.

**Rollback:** none — this is pure recovery, not a config change with a prior state to preserve.
</details>

<details><summary>Playbook 2 — Rebuild a broken matching-attribute configuration</summary>

1. **Before changing anything**, export current mappings from the portal (Mappings → Advanced → Show advanced options → Edit attribute list for [Object]) as a record of the prior state.
2. Identify a genuinely unique, stable, non-null source attribute (commonly `userPrincipalName`, `mail`, or `employeeId` — avoid display name or anything users can self-edit).
3. Update "Match objects using this attribute" to the corrected attribute.
4. Save — this **automatically triggers a full restart** (new initial cycle, cleared watermark). Expect duration proportional to full directory size, not incremental-cycle speed.
5. Monitor the initial cycle's provisioning logs closely for a spike in `Create` vs. `Update` actions — a spike in unexpected `Create`s for users who should already exist in the target usually means the new matching attribute still isn't resolving correctly (target-side attribute name/format mismatch).

**Rollback:** re-apply the exported prior mapping and save (triggers another full restart) if the new matching attribute produces duplicate accounts in the target.
</details>

<details><summary>Playbook 3 — Recover from unwanted mass deprovisioning</summary>

1. Immediately check **skip out-of-scope deletions** current state and provisioning logs for a spike in `Disable`/`Delete` actions with a shared root cause (e.g., a scoping filter edit that accidentally excluded a large population, or a source-side bulk attribute change).
2. If the cause is a scoping filter or mapping change, revert that specific change first — do **not** restart yet.
3. Set **skip out-of-scope deletions** to true temporarily if the issue is ongoing, to stop further disables while the root cause is fixed.
4. Once the source-side condition is corrected, remove the temporary skip-out-of-scope-deletions override and allow the next cycle (or a manual restart) to re-evaluate and re-enable affected users.
5. For users already hard-deleted in the target (irreversible on Entra's side — Entra only sends the request, it doesn't control target-side retention), recovery depends entirely on the target application's own recycle-bin/backup capability, not on anything in Entra ID.

**Rollback:** re-enabling **skip out-of-scope deletions** as a standing setting is a valid long-term choice for apps where Entra ID should never disable/delete access — but document it, since it means an unassigned or terminated user's access silently persists in that target app.
</details>

<details><summary>Playbook 4 — Bring a group-based deployment fully into scope (nested-group trap)</summary>

1. Map out the actual group structure: `Get-MgGroupMember -GroupId <assigned>` recursively, comparing direct vs. effective (nested) membership.
2. Decide the fix pattern: either (a) directly assign the group(s) that actually contain the target users — flattening one level — or (b) if group membership can't be restructured, move to a dynamic group whose rule evaluates the desired final population directly (dynamic groups still only expose their own direct membership to provisioning, but the *rule* can reach further than manual nesting).
3. Re-scope the application's assignment to the corrected group(s).
4. Restart provisioning to force full re-evaluation against the corrected scope.

**Rollback:** re-assign the original group if the flattened structure causes unintended access via SSO (remember: the same assignment usually gates both SSO and provisioning).
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects Enterprise Application provisioning job evidence for escalation.
.DESCRIPTION Read-only. Pulls job status, quarantine detail, and recent provisioning log
             failures for a named Service Principal, exporting to CSV for ticket attachment.
.PARAMETER   AppDisplayName   Display name of the Enterprise Application's Service Principal.
.EXAMPLE     .\Get-ProvisioningEvidence.ps1 -AppDisplayName "Salesforce"
.NOTES       Requires Microsoft.Graph.Applications + Microsoft.Graph.Reports modules,
             Connect-MgGraph -Scopes "Application.Read.All","AuditLog.Read.All"
#>
param([Parameter(Mandatory)][string]$AppDisplayName)

$sp  = Get-MgServicePrincipal -Filter "displayName eq '$AppDisplayName'"
$job = Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id

[PSCustomObject]@{
    AppName                 = $sp.DisplayName
    ServicePrincipalId      = $sp.Id
    JobId                   = $job.Id
    StatusCode              = $job.Status.Code
    QuarantineReason        = $job.Status.QuarantineReason
    LastSuccessfulExecution = $job.Status.LastSuccessfulExecution
    LastExecution           = $job.Status.LastExecution
} | Export-Csv -Path ".\ProvisioningJob_$($sp.DisplayName)_$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation

Get-MgAuditLogProvisioning -Filter "servicePrincipalId eq '$($sp.Id)' and provisioningStatusStatus eq 'failure'" -Top 200 |
  Select-Object ActivityDateTime, ProvisioningAction,
    @{n='SourceId';e={$_.SourceIdentity.Id}}, @{n='SourceUPN';e={$_.SourceIdentity.UserPrincipalName}},
    @{n='FailureReason';e={$_.ProvisioningStatus.StatusInfo.AdditionalDetails}} |
  Export-Csv -Path ".\ProvisioningFailures_$($sp.DisplayName)_$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation
```

---
## Command Cheat Sheet

```powershell
# Find a Service Principal by name
Get-MgServicePrincipal -Filter "displayName eq '<AppName>'"

# Get its provisioning job(s)
Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id

# Job status detail (quarantine reason, last execution, progress)
(Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id).Status

# Restart the job (full re-evaluation, clears watermark/escrow/quarantine)
Invoke-MgGraphRequest -Method POST `
  -Uri "https://graph.microsoft.com/beta/servicePrincipals/$($sp.Id)/synchronization/jobs/$($job.Id)/restart" `
  -Body (@{ criteria = @{ resetScope = "Full" } } | ConvertTo-Json)

# List everyone currently assigned to the app (what provisioning treats as "in scope" before filters)
Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id

# Direct (non-nested) members of an assigned group — the actual provisioning-visible population
Get-MgGroupMember -GroupId "<GroupId>"

# Recent provisioning log entries for the app
Get-MgAuditLogProvisioning -Filter "servicePrincipalId eq '$($sp.Id)'" -Top 50

# Recent provisioning log entries for one user across ALL apps
Get-MgAuditLogProvisioning -Filter "sourceIdentity/userPrincipalName eq 'user@contoso.com'" -Top 25

# Failures only, for pattern-grouping before a restart
Get-MgAuditLogProvisioning -Filter "servicePrincipalId eq '$($sp.Id)' and provisioningStatusStatus eq 'failure'"

# Unassign / reassign a user (fixes "not effectively entitled")
Remove-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -AppRoleAssignedToId $appRoleAssignmentId
New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -BodyParameter @{ principalId=$userId; resourceId=$sp.Id; appRoleId=$appRoleId }
```

---
## 🎓 Learning Pointers

- **Provisioning and SSO are independently configured on the same Enterprise Application object** — a working sign-in experience tells you nothing about provisioning health, and vice versa. Always check them as two separate systems even though they share one Service Principal.
- **The escrow/quarantine math has a floor before it engages** — a job needs at least 5,000 failures before Microsoft even evaluates whether to quarantine it, so a small number of persistent per-user failures can sit unnoticed indefinitely without tripping quarantine at all; don't rely on quarantine as your only failure signal. [Quarantine status in Microsoft Entra Application Provisioning](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/application-provisioning-quarantine-status)
- **A mapping or scoping-filter edit is a bigger action than it looks in the UI** — it silently discards the watermark and forces a full initial-cycle re-evaluation of the entire source directory. Batch config changes together rather than editing one attribute at a time if the app has a large user population.
- **Global Reader is explicitly denied read access to provisioning configuration** — a genuinely unusual RBAC gap worth knowing before troubleshooting a permissions-looking failure that's actually a missing custom role (`microsoft.directory/applications/synchronization/standard/read`). [Known issues for provisioning](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/known-issues)
- **Manager and group-membership *reference* attributes don't self-heal** — if a user's manager (or a group member) comes into scope after the user was already provisioned, the reference is not retroactively updated until a restart re-evaluates everyone. Build periodic restarts into an operational runbook for orgs with frequent org-chart or group-membership churn, rather than treating a stale manager field as an isolated bug.
- **Special characters in a source attribute used for matching/joining can silently break provisioning for just that one object** — Entra ID can't filter-query values containing certain special characters, so a group or user name that's perfectly valid in Entra ID can fail to sync purely because of its characters, not because of any policy or credential issue. [Known issues for provisioning](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/known-issues)
