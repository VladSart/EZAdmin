# Entra ID Enterprise Application (SCIM) Provisioning — Hotfix Runbook (Mode B: Ops)
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
# Requires: Microsoft.Graph.Applications module, Connect-MgGraph -Scopes "Application.Read.All"
# 1. Find the service principal + its provisioning job
$sp = Get-MgServicePrincipal -Filter "displayName eq '<AppName>'"
$job = Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id

# 2. Current status — the single most important field
$job | Select-Object Id, @{n='Status';e={$_.Status.Code}}, @{n='Quarantine';e={$_.Status.QuarantineReason}}

# 3. Last execution summary
$job.Status | Select-Object LastSuccessfulExecution, LastExecution, SteadyStateVersion

# 4. Pull the last 25 provisioning log events for this app (portal is faster for ad-hoc reads, this is for scripted triage)
Get-MgAuditLogProvisioning -Filter "servicePrincipalId eq '$($sp.Id)'" -Top 25 |
  Select-Object ActivityDateTime, @{n='Action';e={$_.ProvisioningAction}}, @{n='Status';e={$_.ProvisioningStatus.Status}}, @{n='Reason';e={$_.ProvisioningStatus.StatusInfo.AdditionalDetails}}

# 5. One user stuck? Check assignment + jump straight to their log entries
Get-MgUserAppRoleAssignment -UserId "<user@contoso.com>" | Where-Object ResourceId -eq $sp.Id
```

| Triage result | Interpretation | Do this |
|---|---|---|
| `Status.Code` = `Quarantine`, `QuarantineReason` = `EncounteredQuarantineException` | Admin credentials to the target app are invalid/expired | Fix 1 |
| `Status.Code` = `Quarantine`, `QuarantineReason` = `EncounteredEscrowProportionThreshold` | ≥40% (or ≥40,000) of provisioning events are failing | Fix 2 |
| `LastSuccessfulExecution` is null or the job never left `NotStarted` | Initial cycle hasn't completed — can legitimately take 20 min–several hours on a large directory | Fix 3 |
| A specific user's log entry shows `skipped` + `"not effectively entitled"` | Broken assignment record — very common on Default Access role | Fix 4 |
| A specific user's log entry shows `skipped` + scoping-filter reference | Attribute value fails a configured scoping filter | Fix 5 |
| Log entry shows `failed` with a duplicate-value / unique-constraint error on the target side | Two source users map to the same target attribute value (matching or unique attribute) | Fix 6 |
| Job status is healthy but a user in a **nested** group never provisions | Provisioning only reads immediate group members — nested groups are not supported | Fix 7 |
| Job status is healthy but nothing has happened since a mapping/scoping-filter edit | Edits to mappings/scoping filters silently trigger a full restart (new initial cycle) — it's running, not stuck | Fix 8 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Entra ID (source of truth for users/groups)
   │
   ├─ Users/Groups assigned to the Enterprise Application (App roles / assignments)
   │     └─ "Sync only assigned users and groups" scope reads THIS list
   │           (nested group members are invisible — first level only)
   │
   ├─ Provisioning job configuration (per Service Principal)
   │     ├─ Admin Credentials — auth to the target app's SCIM endpoint (Test Connection)
   │     ├─ Attribute Mappings — incl. the "Match objects using this attribute" matching rule
   │     ├─ Scoping Filters (optional, attribute-based, layered on top of assignment)
   │     └─ Target object actions (Create / Update / Delete toggles)
   │
   ├─ Provisioning Service (Microsoft-hosted, runs the cycle on a fixed per-app interval —
   │  NOT configurable) ── HTTPS/TLS 1.2 ──▶ Target application's SCIM 2.0 endpoint
   │     (or, for on-prem targets: Entra provisioning agent ──▶ LDAP/SQL/REST/PowerShell/ECMA)
   │
   └─ Watermark (delta-query checkpoint persisted after each cycle)
         cleared by: Restart provisioning / mapping or scoping-filter change / quarantine exit
```

If the job is `Quarantine`, nothing downstream of "Admin Credentials" is even being attempted at normal frequency — cycles drop to once per day.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the job exists and is On.**
   `Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id` → `Status.Code` should be `Active`, not `Paused`/`Quarantine`/`NotStarted`.
2. **Check Test Connection.** Portal: **Enterprise Apps → [App] → Provisioning → Edit provisioning → Test Connection**. A failure here means credentials/endpoint URL are wrong — nothing else matters until this passes.
3. **Open Provisioning Logs and search by user.** Portal: **Entra ID → Enterprise Apps → Provisioning logs**, filter by the user's UPN. Expected: a `Success` or `Skipped` row with a `Steps` tab explaining *why*.
4. **Read the Steps tab on a `Skipped` row**, don't guess. It will say one of: not in scope of assignment, filtered by scoping filter, not effectively entitled, or a specific missing/invalid attribute.
5. **Confirm the matching attribute has a value.** If the source-side matching attribute (e.g. `userPrincipalName`) is null/empty for the user, the job can't match or create them — expected behavior, not a bug.
6. **If nothing at all is happening**, check whether an initial cycle is still running (`Status.Code` = `NotStarted` or the portal progress bar shows "Provisioning starting"). This is normal for up to several hours on a large directory the first time a job runs, or any time it's fully restarted.

---
## Common Fix Paths

<details><summary>Fix 1 — Quarantine: invalid admin credentials</summary>

```powershell
# Portal is the only supported way to re-enter credentials:
# Enterprise Apps → [App] → Provisioning → Edit provisioning → Admin Credentials
# Re-enter the Secret Token / OAuth authorization, click Test Connection, then Save.
```
Saving valid credentials automatically triggers a restart and clears the credential-related quarantine reason on the next cycle. No PowerShell path exists for re-entering the secret itself (it's a one-way write in the UI); you can only read/monitor status via Graph.

**Rollback:** none needed — this only re-authorizes an existing connection.
</details>

<details><summary>Fix 2 — Quarantine: escrow/failure-rate threshold exceeded</summary>

```powershell
# 1. Find the dominant failure reason first — don't restart blind
Get-MgAuditLogProvisioning -Filter "servicePrincipalId eq '$($sp.Id)' and provisioningStatusStatus eq 'failure'" -Top 50 |
  Group-Object { $_.ProvisioningStatus.StatusInfo.AdditionalDetails } |
  Sort-Object Count -Descending | Select-Object Count, Name -First 5

# 2. Once the root cause (bad mapping, missing required attribute, duplicate value) is fixed,
#    restart the job — clears escrow, quarantine, and watermark, and forces a fresh initial cycle
$body = @{ criteria = @{ resetScope = "Full" } } | ConvertTo-Json
Invoke-MgGraphRequest -Method POST `
  -Uri "https://graph.microsoft.com/beta/servicePrincipals/$($sp.Id)/synchronization/jobs/$($job.Id)/restart" `
  -Body $body
```
A job needs a minimum of 5,000 failures before quarantine is even evaluated; it then quarantines at >40% failure rate OR >40,000 absolute failures (reference-attribute failures like manager/group-member updates don't count toward that 40%/40,000 figure, but do count toward a separate 60,000 combined ceiling). Fixing the root cause without restarting still clears quarantine automatically on the next successful cycle — a manual restart just forces it immediately and re-evaluates every user from scratch.

**Rollback:** a Full restart re-runs the entire initial cycle (can take hours on a large directory) — don't run it repeatedly while still diagnosing.
</details>

<details><summary>Fix 3 — Initial cycle looks stuck</summary>

```powershell
# Confirm it's actually progressing, not stalled
Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id |
  Select-Object -ExpandProperty Status |
  Select-Object Code, ProgressPercentage, LastExecution
```
An initial cycle can legitimately take 20 minutes to several hours depending on directory size — this is expected, not a fault. Only escalate if `ProgressPercentage` hasn't moved across two checks 30+ minutes apart.

**Rollback:** none — this is a read-only check.
</details>

<details><summary>Fix 4 — User skipped: "not effectively entitled"</summary>

```powershell
# Unassign then reassign — this is the documented fix, there is no in-place repair
$appRole = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id |
  Where-Object PrincipalId -eq (Get-MgUser -UserId "<user@contoso.com>").Id
Remove-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -AppRoleAssignedToId $appRole.Id

New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -BodyParameter @{
  principalId = (Get-MgUser -UserId "<user@contoso.com>").Id
  resourceId  = $sp.Id
  appRoleId   = "00000000-0000-0000-0000-000000000000"   # default access role unless a specific app role is used
}
```
This error means the assignment *record* itself is broken in Entra ID, not a mapping or credential problem. It's also the historical default behavior for users left on the app's built-in "Default Access" role — assign a real app role if the target app defines one.

**Rollback:** re-assigning is non-destructive; if the user had a specific (non-default) app role, re-assign that same role rather than default access.
</details>

<details><summary>Fix 5 — User skipped: scoping filter</summary>

```powershell
# Read the exact filter currently configured (portal: Provisioning → Edit provisioning → Mappings → [Object] → Scoping Filters)
# Then confirm the user's source attribute value against it directly:
Get-MgUser -UserId "<user@contoso.com>" -Property "department,employeeType,usageLocation" |
  Select-Object department, employeeType, usageLocation
```
Remember: `appRoleAssignments`, `userType`, `manager`, and any date-type attribute (hire/termination date, etc.) are **not supported** as scoping-filter attributes — if the filter looks like it references one of these, it will not behave as expected and needs to be rebuilt against a supported attribute.

**Rollback:** none — filter is read-only in this fix; edit it in the portal Mappings UI.
</details>

<details><summary>Fix 6 — Duplicate/unique-constraint failure on target</summary>

```powershell
# Find every source user sharing the conflicting value (commonly mail, employeeId, or the configured matching attribute)
Get-MgUser -Filter "mail eq '<conflicting-value>'" -Property "id,displayName,userPrincipalName,mail"
```
Two users can't share the value used as either the **matching attribute** or a target-side unique attribute (e.g. `userName`/`email` in the target app). Correct the duplicate at the source, or adjust the attribute mapping so it no longer collides (e.g. append a disambiguator via an expression mapping) — do not delete the target-side account manually, let the next cycle reconcile it once the source is fixed.

**Rollback:** none — this is a data-correction fix, not a destructive operation.
</details>

<details><summary>Fix 7 — Nested group member never provisions</summary>

```powershell
# Confirm the user is only an INDIRECT (nested) member of the assigned group
Get-MgGroupMember -GroupId "<AssignedGroupId>" | Where-Object Id -eq (Get-MgUser -UserId "<user@contoso.com>").Id
# If this returns nothing but the user is clearly "in" the group via a nested group, that's the root cause
```
This is a hard product limitation, not a bug: provisioning only reads users who are **immediate/direct** members of an assigned group. Fix by directly assigning the group that actually contains the users (or the users themselves) to the application — flattening the group structure for provisioning purposes, or scoping in the correct group directly.

**Rollback:** none — this is an architectural constraint to design around, not something to undo.
</details>

<details><summary>Fix 8 — Nothing happening after a mapping/scoping-filter edit</summary>

```powershell
Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id |
  Select-Object -ExpandProperty Status | Select-Object Code, ProgressPercentage
```
Changing attribute mappings or scoping filters **automatically triggers a new initial cycle** (clears the watermark, re-evaluates every source object). This is expected and can take as long as the original initial cycle — it is not stuck, it is redoing full-directory evaluation. Also remember: switching scope from **Sync All** to **Sync Assigned** does *not* take effect until you manually trigger **Restart provisioning** in the portal — the dropdown change alone is not enough.

**Rollback:** none needed.
</details>

---
## Escalation Evidence

```
App / Service Principal name: ____________________
Service Principal Object ID: ____________________
Synchronization Job ID: ____________________
Job status (Code / QuarantineReason): ____________________
Affected user(s) UPN: ____________________
Provisioning log "Steps" tab text for the affected user (verbatim): ____________________
Last successful execution timestamp: ____________________
Test Connection result (pass/fail + error text): ____________________
Screenshot/export of Provisioning logs for the affected time window: ____________________
Was a Restart provisioning already attempted? (Y/N, timestamp): ____________________
```

---
## 🎓 Learning Pointers

- **"Match objects using this attribute" is the single most important setting in the whole job** — it decides whether Entra creates a duplicate account, silently updates the wrong one, or never matches at all. Review it before touching anything else. [Understand how Application Provisioning works](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/how-provisioning-works)
- **Nested groups are a permanent, documented limitation**, not a bug you'll ever see fixed — provisioning (like SSO group-based assignment) only reads direct/immediate members. Plan group structures for provisioning with this in mind from day one.
- **Quarantine has a hard 4-week clock.** A job stuck in quarantine for more than 28 days is automatically disabled, not just paused — treat any quarantine alert as time-boxed, not something to defer indefinitely. [Quarantine status in Microsoft Entra Application Provisioning](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/application-provisioning-quarantine-status)
- **Restarting is a bigger hammer than it looks.** "Restart provisioning" clears the watermark and re-evaluates every single source object from scratch — appropriate for clearing quarantine or a bad mapping, wasteful as a first troubleshooting step for one stuck user (use the Provisioning Logs "Steps" tab instead).
- **The provisioning interval is fixed per application and not configurable** — if a change "hasn't shown up yet," check the app-specific interval documented in its gallery tutorial before assuming something is broken. [No users are being provisioned](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/application-provisioning-config-problem-no-users-provisioned)
- **Deprovisioning defaults to disable, not delete**, and only escalates to a hard delete when the target app doesn't support soft-delete or after a user is hard-deleted from Entra ID (30 days after soft-delete). If users are unexpectedly vanishing from a target app, check whether `isSoftDeleted` is mapped and what the app does with `active: false`.
