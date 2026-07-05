# M365 Group / Teams Self-Service Provisioning Flows — Hotfix Runbook (Mode B: Ops)
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
# 1. Did the underlying M365 Group actually get created?
Get-MgGroup -Filter "displayName eq '<requestedGroupName>'" |
  Select-Object DisplayName, Id, CreatedDateTime, GroupTypes

# 2. Is the group fully provisioned (Exchange + SharePoint backing store ready)?
# A group can exist in Entra ID before Exchange/SharePoint finish provisioning it — this is the #1 race condition
Get-UnifiedGroup -Identity "<groupEmailOrName>" -ErrorAction SilentlyContinue |
  Select-Object DisplayName, WhenCreated, SharePointSiteUrl

# 3. Was a Team actually created from the group, or did that step fail silently?
Get-MgTeam -TeamId (Get-MgGroup -Filter "displayName eq '<requestedGroupName>'").Id -ErrorAction SilentlyContinue

# 4. Check the flow run history for the specific failing action
# Power Automate portal → My Flows → [flow] → Run History → click failed run
# Look for: "NotFound", "ResourceNotFound", or "The remote server returned an error: (404)"
# on the "Create a team" or "Add owner" action — classic sign of the async-provisioning race

# 5. Check the group naming policy didn't silently reject/alter the name
Get-MgDirectorySettingTemplate | Where-Object { $_.DisplayName -eq "Group.Unified" }
```

**Interpret:**
- Group exists in Entra ID but `Get-UnifiedGroup` returns nothing yet → still provisioning, see [Fix 1](#fix-1--race-condition-between-group-creation-and-team-creation)
- Group and mailbox exist but Team creation step 404'd → same race condition, retry is usually enough
- Group name came back different than requested (prefix/suffix added, or request rejected) → naming policy, see [Fix 2](#fix-2--group-name-blocked-or-altered-by-naming-policy)
- Group/Team created but requestor isn't listed as owner → wrong connector action used, see [Fix 3](#fix-3--owner-not-assigned)
- Guests can't be added / external sharing not applying → see [Fix 4](#fix-4--guest-access-settings-not-applied)
- New members not getting the license the group is supposed to assign → see [Fix 5](#fix-5--group-based-licensing-not-applying-to-new-members)

---

## Dependency Cascade

<details><summary>What must be true for a provisioning flow to succeed end-to-end</summary>

```
[Flow trigger: form submission / approval completed]
        │
        ▼
[Create Group action — Groups connector or HTTP → Graph POST /groups]
        │
        ▼
[Entra ID Group Naming Policy validation]
   ├─ Blocked words list checked
   ├─ Prefix/suffix template applied (may silently change the requested name)
   └─ Rejected requests return an error the flow must handle explicitly
        │
        ▼
[Group provisioning — ASYNCHRONOUS, not instant]
   ├─ Entra ID object created immediately
   ├─ Exchange Online mailbox provisioned — typically seconds to a few minutes
   └─ SharePoint team site provisioned — can take several minutes, occasionally longer under load
        │
        ▼
[Create Team from Group action]
   └─ REQUIRES the group's SharePoint site to already exist — will fail with 404/NotFound
      if fired immediately after group creation without a wait/retry step
        │
        ▼
[Add owners / members]
   └─ "Add a member" and "Add an owner" are DIFFERENT connector actions —
      using only one when both are needed leaves a group with no manager
        │
        ▼
[Guest access / sensitivity label / group settings applied]
   └─ Depends on the correct Directory Setting Template ID being referenced
        │
        ▼
[Group-based licensing, if configured]
   └─ Membership change → license assignment processing is a separate async job,
      can lag noticeably in large tenants
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the group object was created**
```powershell
Get-MgGroup -Filter "displayName eq '<requestedGroupName>'" |
  Select-Object Id, DisplayName, Mail, CreatedDateTime, GroupTypes, SecurityEnabled
```
Expected: One matching group with `GroupTypes` containing `Unified`. If nothing returns, the Create Group action itself failed — check the flow run for the actual Graph error (commonly a naming policy rejection or missing permission scope on the connection).

**Step 2 — Confirm Exchange/SharePoint backing store finished provisioning**
```powershell
Get-UnifiedGroup -Identity "<groupEmailOrName>" |
  Select-Object DisplayName, WhenCreated, SharePointSiteUrl, EmailAddresses
```
Expected: `SharePointSiteUrl` populated. If empty or the cmdlet errors with "couldn't find object," the group is still provisioning — this is normal for the first few minutes after creation, not a failure.

**Step 3 — Confirm the Team was created from the group**
```powershell
$groupId = (Get-MgGroup -Filter "displayName eq '<requestedGroupName>'").Id
Get-MgTeam -TeamId $groupId
```
Expected: Returns the Team object. A 404 here, combined with a confirmed group in Step 1, means the "Create a team" flow action ran before provisioning finished — this is the single most common failure in these flows.

**Step 4 — Verify owners and members**
```powershell
Get-MgGroupOwner -GroupId $groupId | Select-Object Id, AdditionalProperties
Get-MgGroupMember -GroupId $groupId | Select-Object Id, AdditionalProperties
```
Expected: Requestor (or the designated owner) appears in the **Owner** list, not just Members. A group with zero owners can't be self-managed and will need admin intervention for any future changes.

**Step 5 — Check group naming policy didn't alter the request**
```powershell
$policy = Get-MgDirectorySettingTemplate | Where-Object { $_.DisplayName -eq "Group.Unified" }
Get-MgDirectorySetting | Where-Object { $_.TemplateId -eq $policy.Id } |
  Select-Object -ExpandProperty Values
```
Look for `PrefixSuffixNamingRequirement` and `CustomBlockedWordsList` values — compare against the requested name to confirm whether the mismatch is policy-driven or a flow bug.

---

## Common Fix Paths

<details><summary>Fix 1 — Race condition between group creation and Team creation</summary>

**When:** "Create a team" (or the Graph `/teams` action) fails with `NotFound` or a 404 immediately after group creation in the same flow run.

Group creation returns success as soon as the Entra ID object exists — it does **not** wait for the SharePoint site backing store, which Team creation depends on.

**Fix — add a polling/retry step between group creation and team creation:**
```
Flow edit:
1. After "Create a group" action, add a "Do until" loop
2. Condition: check group's SharePoint site exists via HTTP GET to
   https://graph.microsoft.com/v1.0/groups/{id}/drive
3. Loop with a 30-second delay, timeout after 10 minutes (20 iterations)
4. Only proceed to "Create a team" once the drive/site check succeeds
```

Alternatively, use Power Automate's built-in "Delay" action (start with 2 minutes) before the Create Team step as a simpler but less reliable fix — the polling approach above is more robust for larger tenants where provisioning is slower.

**Rollback:** N/A — this is an additive change to flow logic, not destructive.

</details>

<details><summary>Fix 2 — Group name blocked or altered by naming policy</summary>

**When:** The group is created with a different name than requested, or the Create Group action fails outright with a policy violation error.

```powershell
# Review the current naming policy
$policy = Get-MgDirectorySettingTemplate | Where-Object { $_.DisplayName -eq "Group.Unified" }
$setting = Get-MgDirectorySetting | Where-Object { $_.TemplateId -eq $policy.Id }
$setting.Values | Where-Object { $_.Name -in "PrefixSuffixNamingRequirement","CustomBlockedWordsList" }
```

If the flow doesn't account for the prefix/suffix template, the requested name and the actual name will differ — update the flow to read back the *actual* `displayName` returned by the Create Group action rather than assuming it matches the form input, and use that value in every subsequent step (Team creation, notification emails, etc.).

**If a blocked word is legitimately needed:** escalate to the Entra ID admin to adjust `CustomBlockedWordsList` — this is a tenant-wide setting, not something the flow can override.

</details>

<details><summary>Fix 3 — Owner not assigned</summary>

**When:** Group/Team is created successfully but the requestor has no management rights over it.

The Groups/Teams connector exposes **separate actions** for members vs. owners:
- "Add a member to a group" → adds to `members` only
- "Add an owner to a group" → adds to `owners` — this is the one that grants management rights

```powershell
# Check current state
$groupId = "<groupId>"
Get-MgGroupOwner -GroupId $groupId

# Manually remediate an existing group missing an owner
$userId = (Get-MgUser -UserId "<requestorUPN>").Id
$body = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$userId" }
New-MgGroupOwnerByRef -GroupId $groupId -BodyParameter $body
```

Update the flow to include the explicit "Add an owner" action — don't assume "Add a member" covers it.

</details>

<details><summary>Fix 4 — Guest access settings not applied</summary>

**When:** The flow is meant to enable/restrict guest access per group but the setting doesn't take effect.

Guest access is controlled by a **group-specific Directory Setting object** created from the `Group.Unified.Guest` template — it does not exist by default and must be explicitly created per group if the flow needs to override the tenant default.

```powershell
$template = Get-MgDirectorySettingTemplate | Where-Object { $_.DisplayName -eq "Group.Unified.Guest" }
# If the flow's HTTP action references a wrong/stale TemplateId, group-level override silently fails
# and the group falls back to the tenant-wide default (Azure AD → Groups → General settings)
```

Confirm the flow's HTTP action is using the current `TemplateId` for `Group.Unified.Guest` — template IDs are tenant-specific and copying a flow between tenants without updating this ID is a common cause of silent failure.

</details>

<details><summary>Fix 5 — Group-based licensing not applying to new members</summary>

**When:** Users added to the group via the flow don't receive the expected license within a reasonable time.

```powershell
# Check license assignment processing state for the group
Get-MgGroup -GroupId $groupId -Property "assignedLicenses,licenseProcessingState" |
  Select-Object -ExpandProperty LicenseProcessingState
```

`ProcessingState` will show `PendingProcessing` immediately after a membership change. In large tenants this can take longer than users expect (typically minutes, occasionally longer under heavy directory sync load) — this is a known async processing delay, not a flow bug. If it's been in `PendingProcessing` for over an hour, escalate to check for a licensing error on the group itself (insufficient license units is the most common root cause, surfaced as `LicenseAssignmentStates` with an `Error` status).

</details>

---

## Escalation Evidence

```
M365 Group/Teams Provisioning — Escalation Evidence
====================================================
Flow name:                     
Requestor:                     
Requested group name:          
Actual group name (if different): 
Group Id:                      
Group created (Y/N):           [Get-MgGroup output]
SharePoint site provisioned (Y/N): [Get-UnifiedGroup SharePointSiteUrl]
Team created (Y/N):            [Get-MgTeam output]
Owner assigned (Y/N):          [Get-MgGroupOwner output]
Failing action in flow:        
Error message from run history: 
Naming policy in effect:       [prefix/suffix, blocked words]
Guest access expected/actual:  
License group involved:        [Y/N, ProcessingState if Y]
```

---

## 🎓 Learning Pointers

- **Group and Team provisioning are asynchronous — success at the Entra ID layer does not mean the SharePoint/Exchange backing stores are ready.** Any flow that chains "Create a group" directly into "Create a team" without a wait/retry step will intermittently fail, especially under tenant load. This is the single most common defect in home-grown provisioning flows. [MS Docs: Team resource type](https://learn.microsoft.com/en-us/graph/api/resources/team)
- **"Add a member" and "Add an owner" are not interchangeable.** A group with members but no owner cannot be self-managed by the business — every future change (adding people, renaming, deleting) requires admin intervention. Always verify owner assignment as a distinct check.
- **Group naming policies can silently rewrite the name your flow requested.** If the flow doesn't read back the actual `displayName` from the Create Group response and instead assumes it matches the form input, every downstream reference (Team name, notification email, SharePoint URL) will be wrong. [MS Docs: Group naming policy](https://learn.microsoft.com/en-us/microsoft-365/admin/create-groups/groups-naming-policy)
- **Group-level guest access settings require an explicit Directory Setting object per group — there's no inheritance from the tenant default once you create one.** Template IDs are tenant-specific; a flow copied between tenants (or a demo template applied to a new customer) will silently fall back to defaults unless the `TemplateId` is updated for that tenant.
- **Group-based license processing is a separate async pipeline from group membership changes.** A user added to a licensing group doesn't get the license instantly — check `LicenseProcessingState` before assuming the flow or licensing configuration is broken. [MS Docs: Group-based licensing](https://learn.microsoft.com/en-us/entra/identity/users/licensing-group-advanced)
