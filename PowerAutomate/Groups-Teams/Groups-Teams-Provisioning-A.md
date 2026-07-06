# M365 Group / Teams Self-Service Provisioning Flows — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- Power Automate flows that create M365 Groups and/or Teams from a self-service request (form, SharePoint list, Teams app, ServiceNow/ticket trigger)
- The Entra ID / Exchange Online / SharePoint Online provisioning chain those flows depend on
- Owner/member assignment, naming policy enforcement, guest access, and group-based licensing as they interact with automated provisioning

**Out of scope:**
- Manual (non-automated) group/Team creation via the admin center or PowerShell
- Third-party group lifecycle/governance products (e.g. AI-driven access reviews) — covered only where they intersect with flow-driven provisioning
- Team-internal configuration (channels, tabs, apps) after the Team object itself exists

**Assumes:**
- Global Administrator or Groups Administrator + Teams Administrator rights for diagnostics
- Microsoft Graph PowerShell SDK (`Microsoft.Graph`) and Exchange Online Management module connected
- Power Automate maker or admin access to the flow(s) in question

---

## How It Works

<details><summary>Full architecture — why "create a group" is not one atomic operation</summary>

### The provisioning chain is a sequence of independent async services

A single "new team/group request" self-service flow typically fires a chain of calls into at least three separate backend services, each with its own provisioning latency:

```
Flow trigger (form submit / list item created / approval completed)
        │
        ▼
Graph POST /groups  (or "Create a group" connector action)
        │
        ▼
Entra ID directory object created — RETURNS IMMEDIATELY, success ≠ fully provisioned
        │
        ├──────────────────────────────┬─────────────────────────────┐
        ▼                              ▼                             ▼
Exchange Online mailbox         SharePoint Online team site   Group-based licensing
provisioning (async,            provisioning (async,          processing (async, only
usually seconds–low minutes)    can take several minutes,     if group is licensing-
                                 occasionally longer)          enabled)
        │                              │
        └──────────────┬───────────────┘
                        ▼
        "Create a team" action / Graph POST /teams
        (group.id as the base)
                        │
        REQUIRES the SharePoint site (drive) to already exist —
        this is the single most common flow defect: firing this
        step immediately after group creation with no wait/retry
```

The Entra ID object existing is a necessary but not sufficient condition for the rest of the chain. Flows written by makers unfamiliar with this (a very common pattern, since the "Create a group" action's success in the flow designer gives no visual indication that downstream provisioning is still in progress) will intermittently fail the "Create a team" step, especially under tenant load or during Microsoft service degradations, and the failure rate correlates with tenant size and how busy the backend provisioning queues are at that moment — meaning the same flow can look "fixed" for weeks and then start failing again with no flow-side change.

### Group Naming Policy is enforced server-side, and can silently change or reject the request

The `Group.Unified` directory setting template governs two independent controls:
- **Blocked words list** (`CustomBlockedWordsList`) — a request containing a blocked substring is rejected outright by the Graph API with a policy violation error.
- **Prefix/suffix template** (`PrefixSuffixNamingRequirement`) — a request is *not* rejected but the actual `displayName`/`mailNickname` returned differs from what was requested (e.g. `GRP-Marketing-Q3` becomes `GRP-Marketing-Q3-EXT` if the requestor is external, or gets a department-code prefix inserted).

A flow that doesn't read back the actual returned `displayName` from the Create Group response, and instead threads the *originally requested* name through subsequent steps (Team creation, SharePoint URL construction, notification emails), will produce inconsistent references throughout the rest of the flow and any downstream systems (ticketing, CMDB) that log the "group name."

### Owner vs. Member is not a naming nuance — it's two different Graph relationships

`owners` and `members` are separate navigation properties on the group object (`/groups/{id}/owners` vs `/groups/{id}/members`). The Groups/Teams connector in Power Automate exposes them as genuinely separate actions. A flow using only "Add a member to a group" produces a group with zero management capability — no one (short of an admin) can add/remove members, rename the group, or change its settings through self-service means going forward, which frequently surfaces weeks later as "why can't the requestor manage their own team."

### Group-based licensing runs on its own processing pipeline

When a licensing group's membership changes, Entra ID queues a separate license (re)assignment job — it does not apply synchronously with the membership change. This pipeline has its own state machine per user-group pairing, exposed via `licenseAssignmentStates`, and can report `PendingProcessing` for a period that scales with tenant size and current directory sync load. A flow or support process that treats "user added to group" as equivalent to "user now has the license" will generate false-positive escalations.

</details>

---

## Dependency Stack

```
┌─────────────────────────────────────────────┐
│  Requestor-facing form / approval flow       │  ← Power Automate trigger + UI
├─────────────────────────────────────────────┤
│  Microsoft Graph / Groups connector           │  ← Create Group, Add Owner/Member actions
├─────────────────────────────────────────────┤
│  Entra ID directory object + naming policy    │  ← Immediate; policy enforced server-side
├─────────────────────────────────────────────┤
│  Exchange Online mailbox provisioning         │  ← Async, seconds to minutes
├─────────────────────────────────────────────┤
│  SharePoint Online site/drive provisioning    │  ← Async, minutes; REQUIRED for Team creation
├─────────────────────────────────────────────┤
│  Teams service (Create a team from group)     │  ← Depends on SPO site existing
├─────────────────────────────────────────────┤
│  Group-based licensing pipeline (if enabled)  │  ← Separate async job per membership change
└─────────────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "Create a team" fails with 404/NotFound right after group creation | SharePoint site not yet provisioned — classic async race | `Get-UnifiedGroup` for `SharePointSiteUrl`, check flow's run history timing |
| Group created with a different name than requested | Prefix/suffix naming policy applied | `Get-MgDirectorySetting` for `Group.Unified`, compare to actual `displayName` |
| Create Group action fails outright with policy error | Blocked word in requested name | Same as above, check `CustomBlockedWordsList` |
| Requestor can't manage the group/Team after creation | Only "Add a member" ran, not "Add an owner" | `Get-MgGroupOwner -GroupId` — empty result confirms |
| Guest access not applying per-group override | Missing or stale `Group.Unified.Guest` directory setting object / wrong TemplateId | Check for a group-specific Directory Setting; confirm TemplateId matches current tenant |
| New group members not getting the expected license | Group-based licensing async processing still pending, or license pool exhausted | `LicenseProcessingState` and `LicenseAssignmentStates` on the group |
| Flow intermittently fails only under load / at certain times of day | Provisioning latency variance correlated with tenant/backend load, not a flow logic bug | Compare failure timestamps against Entra ID/Teams service health history |
| Flow works in one tenant, fails identically-configured in another | Hardcoded TemplateId or connection reference specific to the original tenant | Check HTTP actions referencing Directory Setting Template IDs |

---

## Validation Steps

**1. Confirm the group object exists and inspect its naming policy compliance**
```powershell
$group = Get-MgGroup -Filter "displayName eq '<requestedGroupName>'" |
  Select-Object Id, DisplayName, Mail, MailNickname, CreatedDateTime, GroupTypes
$group
```
Expected: One object, `GroupTypes` contains `Unified`. If the `DisplayName` differs from what was requested, this is naming-policy driven, not a flow error.

**2. Confirm the Exchange/SharePoint backing stores are provisioned**
```powershell
Get-UnifiedGroup -Identity $group.Mail |
  Select-Object DisplayName, WhenCreated, SharePointSiteUrl, EmailAddresses
```
Expected: `SharePointSiteUrl` populated. Empty or cmdlet error in the first few minutes after creation is normal, not a fault.

**3. Confirm the Team object was created from the group**
```powershell
Get-MgTeam -TeamId $group.Id -ErrorAction SilentlyContinue
```
Expected: Returns the Team resource. A 404 combined with a confirmed group (Step 1) confirms the async race condition.

**4. Confirm both owners and members are populated correctly**
```powershell
Get-MgGroupOwner -GroupId $group.Id | Select-Object Id, AdditionalProperties
Get-MgGroupMember -GroupId $group.Id | Select-Object Id, AdditionalProperties
```
Expected: The intended requestor/manager appears under **owners**, not just members.

**5. Inspect the tenant's group naming policy**
```powershell
$template = Get-MgDirectorySettingTemplate | Where-Object { $_.DisplayName -eq "Group.Unified" }
$setting = Get-MgDirectorySetting | Where-Object { $_.TemplateId -eq $template.Id }
$setting.Values | Where-Object { $_.Name -in "PrefixSuffixNamingRequirement","CustomBlockedWordsList" }
```
Expected: Values here should match what the flow's documentation/design assumes — if a flow was copied from another tenant, this is a common silent mismatch point.

**6. Check group-based licensing state (if the group assigns licenses)**
```powershell
Get-MgGroup -GroupId $group.Id -Property "assignedLicenses,licenseProcessingState" |
  Select-Object -ExpandProperty LicenseProcessingState
```
Expected: `Success` for a settled group. `PendingProcessing` immediately after a membership change is normal, not a fault, unless it persists well beyond the tenant's typical processing window.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm what layer actually failed
1. Open the flow's Run History for the failing/complained-about run
2. Identify the exact action that errored (Create Group, Create Team, Add Owner, etc.) and its raw error body
3. Cross-reference with Validation Steps 1–3 to confirm current backend state independent of the flow's own error message — the flow's error may be stale relative to current provisioning state if a retry has already occurred

### Phase 2 — Async race conditions (Create Team failures)
1. Confirm group exists (Step 1) but SharePoint site is missing (Step 2) or Team object missing (Step 3)
2. Check the flow's time gap between "Create a group" and "Create a team" — if there's no wait/retry step, this is root cause
3. Recommend/implement a polling loop (see Playbook 1) rather than a fixed delay, which is fragile against load variance

### Phase 3 — Naming and policy mismatches
1. Run Validation Step 5, compare against the flow's assumptions
2. Confirm the flow reads back the actual `displayName`/`mailNickname` from the Create Group response rather than reusing the form input for all downstream references
3. If a legitimately-needed word is blocked, this requires an Entra ID admin change to `CustomBlockedWordsList` — not something fixable at the flow level

### Phase 4 — Ownership and access gaps
1. Run Validation Step 4 — confirm owner is populated, not just member
2. Check for a group-specific `Group.Unified.Guest` Directory Setting object if guest access behavior differs from tenant default
3. Confirm the TemplateId referenced in any HTTP action matches the current tenant (a hardcoded ID copied from another tenant is a common defect when flows are exported/imported between environments)

### Phase 5 — Licensing lag
1. Run Validation Step 6
2. If `PendingProcessing` persists beyond a reasonable window (compare to historical processing times for this tenant), check for `LicenseAssignmentStates` errors — most commonly insufficient license units in the pool, not a flow or membership problem

---

## Remediation Playbooks

<details><summary>Playbook 1 — Add a robust provisioning-wait loop between group and Team creation</summary>

Use when: "Create a team" intermittently fails with 404/NotFound.

```
Flow edit (Power Automate designer):
1. After "Create a group", add a "Do until" loop
   Condition: a variable set by an HTTP GET to
   https://graph.microsoft.com/v1.0/groups/{groupId}/drive
   returns HTTP 200 (site provisioned) rather than 404
2. Inside the loop: HTTP GET action + a Delay action (start at 30 seconds)
3. Loop limit: 20 iterations / 10 minute timeout — set an explicit failure path
   (notify requestor + log to a tracking list) rather than letting the flow silently time out
4. Only proceed to "Create a team" once the loop condition is satisfied
```

A fixed `Delay` action (e.g. "wait 2 minutes") is simpler but not robust against load-driven variance in provisioning time — prefer the polling pattern for any flow serving a tenant of meaningful size.

**Rollback:** N/A — additive flow logic change, no data risk.

</details>

<details><summary>Playbook 2 — Make the flow naming-policy-aware</summary>

Use when: Downstream steps (Team name, notification text, SharePoint URL construction) reference the requested name rather than the actual provisioned name.

```
Flow edit:
1. Immediately after "Create a group", store the response's actual
   displayName and mailNickname into flow variables
2. Replace every downstream reference to the original form input
   with these variables
3. Add an explicit error-handling branch on the Create Group action:
   if it fails, parse the error body for a policy violation and
   surface a clear message to the requestor (rather than a generic
   flow failure notification)
```

```powershell
# Read current policy to document/communicate constraints to requestors up front
$template = Get-MgDirectorySettingTemplate | Where-Object { $_.DisplayName -eq "Group.Unified" }
$setting  = Get-MgDirectorySetting | Where-Object { $_.TemplateId -eq $template.Id }
$setting.Values | Where-Object { $_.Name -in "PrefixSuffixNamingRequirement","CustomBlockedWordsList" }
```

**Rollback:** N/A — logic correction only.

</details>

<details><summary>Playbook 3 — Remediate an existing group with a missing owner</summary>

Use when: A group/Team was already created via a flow that only ran "Add a member."

```powershell
$groupId  = "<groupId>"
$userUPN  = "<intendedOwnerUPN>"
$userId   = (Get-MgUser -UserId $userUPN).Id

$body = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$userId" }
New-MgGroupOwnerByRef -GroupId $groupId -BodyParameter $body

# Verify
Get-MgGroupOwner -GroupId $groupId
```

Then correct the flow itself to include an explicit "Add an owner" action for all future runs.

**Rollback:** `Remove-MgGroupOwnerByRef -GroupId $groupId -DirectoryObjectId $userId` if the owner was added in error.

</details>

<details><summary>Playbook 4 — Reconcile a Directory Setting Template ID after a flow migration between tenants</summary>

Use when: A guest-access-override flow, working correctly in the source tenant, silently falls back to tenant defaults after being migrated/exported to a new tenant.

```powershell
# Pull the CURRENT tenant's TemplateId — do not reuse an ID hardcoded from another tenant
$template = Get-MgDirectorySettingTemplate | Where-Object { $_.DisplayName -eq "Group.Unified.Guest" }
$template.Id
```

Update the flow's HTTP action body to reference this tenant's `template.Id`. Template IDs are **not** consistent across tenants despite the template name being identical — this is the most common defect when a flow built for one customer is reused for another without review.

**Rollback:** N/A — this is a corrective configuration change to the flow definition.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect a full provisioning-state evidence bundle for a group/Team created via automation
#>
param(
    [Parameter(Mandatory)] [string]$GroupDisplayName,
    [string]$OutputPath = "C:\Temp\GroupProvisioning-Evidence"
)

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$ts = Get-Date -Format "yyyyMMdd-HHmmss"

$group = Get-MgGroup -Filter "displayName eq '$GroupDisplayName'"
$group | Select-Object Id, DisplayName, Mail, MailNickname, CreatedDateTime, GroupTypes |
    Export-Csv "$OutputPath\group-object-$ts.csv" -NoTypeInformation

Get-UnifiedGroup -Identity $group.Mail -ErrorAction SilentlyContinue |
    Select-Object DisplayName, WhenCreated, SharePointSiteUrl |
    Export-Csv "$OutputPath\exo-sharepoint-state-$ts.csv" -NoTypeInformation

Get-MgTeam -TeamId $group.Id -ErrorAction SilentlyContinue |
    Out-File "$OutputPath\team-object-$ts.txt"

Get-MgGroupOwner -GroupId $group.Id | Export-Csv "$OutputPath\owners-$ts.csv" -NoTypeInformation
Get-MgGroupMember -GroupId $group.Id | Export-Csv "$OutputPath\members-$ts.csv" -NoTypeInformation

Get-MgGroup -GroupId $group.Id -Property "assignedLicenses,licenseProcessingState" |
    Select-Object -ExpandProperty LicenseProcessingState |
    Out-File "$OutputPath\license-processing-state-$ts.txt"

Write-Host "Evidence collected to: $OutputPath"
Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath-$ts.zip" -Force
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Find group by name | `Get-MgGroup -Filter "displayName eq '<name>'"` |
| Check Exchange/SPO provisioning state | `Get-UnifiedGroup -Identity <mail> \| Select SharePointSiteUrl` |
| Check Team object exists | `Get-MgTeam -TeamId <groupId>` |
| List owners | `Get-MgGroupOwner -GroupId <id>` |
| List members | `Get-MgGroupMember -GroupId <id>` |
| Add an owner (remediation) | `New-MgGroupOwnerByRef -GroupId <id> -BodyParameter @{"@odata.id"="https://graph.microsoft.com/v1.0/directoryObjects/<userId>"}` |
| Read naming policy | `Get-MgDirectorySettingTemplate \| ? DisplayName -eq "Group.Unified"` |
| Read guest access template | `Get-MgDirectorySettingTemplate \| ? DisplayName -eq "Group.Unified.Guest"` |
| Check license processing state | `Get-MgGroup -GroupId <id> -Property licenseProcessingState` |

---

## 🎓 Learning Pointers

- **A "success" response from Create Group means the Entra ID object exists — nothing more.** Exchange, SharePoint, and Teams provisioning are separate async pipelines behind it, and any flow chaining "Create a team" directly afterward without a wait/retry step will fail intermittently, with the failure rate tracking tenant load rather than flow logic. [MS Docs: Team resource type](https://learn.microsoft.com/en-us/graph/api/resources/team)
- **The requested name and the actual provisioned name can differ, and the flow has no way to know unless it reads the response back.** Group naming policy enforcement happens server-side and silently; threading the original form input through the rest of the flow instead of the API's returned `displayName` is a common source of "the ticket says one name, the group is called something else."
- **Owner and member are separate Graph relationships, not a UI nuance.** A group with members but zero owners cannot be managed by the business at all going forward — this frequently isn't noticed until weeks later when the requestor tries to add someone and can't. [MS Docs: Group-based licensing](https://learn.microsoft.com/en-us/entra/identity/users/licensing-group-advanced)
- **Directory Setting Template IDs are tenant-specific even when the template name is identical across tenants.** Any HTTP action in a flow that hardcodes a TemplateId will silently fall back to tenant defaults when the flow is copied to a new environment — always re-pull the ID for the target tenant during migration.
- **Group-based license assignment is a distinct async pipeline from membership changes** — treat `LicenseProcessingState` as the source of truth for "did the license actually apply," not the membership add itself.
