# Entra ID Dynamic Groups — Reference Runbook (Mode A: Deep Dive)
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

- **Environment:** Microsoft Entra ID with at least one Entra ID P1 license in the tenant (tenant-wide unlock, not per-member)
- **Applies to:** Dynamic user groups and dynamic device groups, cloud-only and hybrid-synced attribute sources
- **Not covered:** Assigned (static) group membership, on-prem AD dynamic distribution groups (different engine entirely), PIM-eligible role assignment via groups (see `EntraID/Troubleshooting/PIM-A.md`)
- **Assumed knowledge:** Basic Graph API / Microsoft Graph PowerShell SDK familiarity, Entra Connect sync fundamentals

---
## How It Works

<details><summary>Full architecture</summary>

### What a Dynamic Group Actually Is

A dynamic group is a group object (`Microsoft.Graph.Group`) with `groupTypes` containing `"DynamicMembership"` and a `membershipRule` — a boolean expression evaluated against directory object attributes. Unlike assigned groups, membership is **computed**, not manually maintained. The directory itself owns the membership list; admins only own the rule.

### The Evaluation Pipeline

```
Attribute Write Event
  (user/device property changes — cloud API call, Entra Connect sync write, or SCIM provisioning)
        │
        ▼
Directory Service publishes a change notification internally
        │
        ▼
Dynamic Membership Evaluation Service picks up the change
        │
        ▼
Service identifies ALL dynamic groups whose rule references the changed attribute
        │
        ▼
For each candidate group: re-evaluate rule against the object's CURRENT attribute snapshot
        │
        ▼
Membership delta computed (added / removed)
        │
        ▼
Group membership table updated
        │
        ▼
Downstream consumers re-evaluate (near-real-time, but each has its own poll/cache cycle):
  ├── License assignment (group-based licensing) — re-processes on membership change
  ├── Conditional Access — re-evaluates at NEXT token request, not immediately
  ├── Intune — device/user targeting re-syncs on next check-in (up to 8h by default)
  └── Exchange Online — distribution/mail-enabled security group membership propagates
        on next directory sync to Exchange (minutes, not instant)
```

**Critical nuance:** the evaluation trigger is attribute-change-driven, not scheduled-poll-driven, for cloud-native attribute writes. But on-prem synced attributes only trigger evaluation *after* Entra Connect has synced the change — the dynamic group engine has no visibility into on-prem AD directly.

### Rule Syntax Engine

Dynamic membership rules use a proprietary expression syntax (not full PowerShell, not full Graph filter syntax, though it resembles both):

```
(user.department -eq "Sales") and (user.accountEnabled -eq true)
```

Rules are parsed and validated for **syntax** at save time only. The parser checks:
- Balanced parentheses
- Valid attribute names (must exist in the supported attribute list for the rule's object type)
- Valid operators for the attribute's data type (`-eq`, `-ne`, `-contains`, `-notContains`, `-startsWith`, `-notStartsWith`, `-match`, `-in`, `-notIn`)
- Correct type coercion (comparing a string attribute to a boolean literal fails validation)

The parser does **not** check whether the rule will ever match a real object. A rule referencing `user.department -eq "Saels"` (typo) is syntactically perfect and semantically useless.

### Supported Attributes

Not every user/device property is rule-eligible. Only attributes on Microsoft's supported list can be referenced (`department`, `jobTitle`, `companyName`, `country`, `usageLocation`, `userType`, `accountEnabled`, `memberOf` transitive checks via `-match`, extension attributes `extensionAttribute1-15`, custom security attributes as of newer tenants, device attributes like `deviceOSType`, `deviceOwnership`, `deviceManagementAppId`, `systemLabels` for AVD/Cloud PC). Attempting to reference an unsupported attribute fails validation immediately with a clear error — this is rarely the silent failure mode; the silent failure mode is always a *supported* attribute with an unexpected value.

### Nested Group Membership Is NOT Rule-Evaluable

`user.memberOf -any (group.objectId -in ['<GroupId>'])` is supported for *direct* group membership checks in some contexts, but dynamic rules cannot recursively evaluate "is this user a transitive member of a nested static group" the way you might expect from AD group nesting. Design rules around user/device attributes, not group topology, wherever possible.

### Rule Processing State

Every dynamic group has a `membershipRuleProcessingState` of `On` or `Paused`. This is a per-group switch (there is no tenant-wide pause anymore in current Entra ID — legacy documentation referencing tenant-wide pause is outdated). Pausing is commonly used deliberately during bulk attribute imports to avoid triggering thousands of re-evaluations mid-import, then forgotten.

</details>

---
## Dependency Stack

```
Entra ID P1 (or P2) license — tenant-wide feature unlock
        │
        ▼
Group object: groupTypes = ["DynamicMembership"]
        │
        ▼
membershipRule (validated syntax, stored as string)
        │
        ▼
membershipRuleProcessingState = "On"
        │
        ▼
Source attribute population
├── Cloud-native attributes — set via Graph/portal/PowerShell directly on the object
└── On-prem synced attributes — must complete Entra Connect sync cycle first
        │        (delta sync ~30 min default scheduler interval, or manually triggered)
        ▼
Dynamic Membership Evaluation Service
├── Triggered by attribute write events (near-real-time under normal load)
└── Queued under heavy load / large tenants / bulk operations
        │
        ▼
Group membership table (source of truth for all downstream consumers)
        │
        ├──► Group-based Licensing engine (re-processes assignment on membership delta)
        ├──► Conditional Access (reads membership at NEXT token issuance, not push-notified)
        ├──► Intune (targets policies/apps on next device/user check-in cycle)
        ├──► Exchange Online (mail-enabled security groups — propagation via directory sync)
        └──► Any app/API consuming Microsoft Graph group membership
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| User never joins group despite matching rule visually | Attribute value has invisible whitespace, wrong case in an extension attribute, or wrong data type | `Get-MgUser -Property <attr>` and inspect raw string length/bytes |
| Group membership was correct, now stale after HR attribute change | On-prem sync hasn't completed, or rule processing is paused | Check `onPremisesLastSyncDateTime` and `membershipRuleProcessingState` |
| Rule saved successfully but matches zero users | Typo in value string, wrong attribute referenced, or type mismatch | Portal "Validate Rules" tab against a known user |
| Group-based license not applying to new dynamic members | Licensing engine license processing failure, not a group issue | `Get-MgUserLicenseDetail`, check `Get-MgUser -Property assignedLicenses` for `ProcessingState` errors |
| Device fails to land in dynamic device group | Device attributes (`deviceOSType`, `deviceOwnership`) not populated until first Entra join/Intune enrollment completes | Confirm device object exists in Entra before troubleshooting the rule |
| Guest users unexpectedly included | Rule doesn't scope by `userType -eq "Member"` | Add explicit `userType` condition |
| Rule references `memberOf` and behaves unpredictably | Nested/transitive group membership not supported the way AD nesting works | Redesign rule around attributes, not group topology |
| Large tenant: membership updates take hours | Evaluation queue depth under load, not a config problem | Re-check membership count over time; if actively converging, it's just queued |
| Rule edited but old members still present after "removal" condition added | Evaluation hasn't run yet, or removed members still satisfy an OR branch of the rule | Re-run rule against affected user in Validate Rules; check full boolean logic, not just the changed clause |

---
## Validation Steps

**Step 1 — Confirm license and feature availability**
```powershell
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits
```
Expected: at least one Entra ID P1/P2-inclusive SKU (e.g., `AAD_PREMIUM`, `ENTERPRISEPREMIUM`) present tenant-wide.
Bad: only free-tier SKUs — dynamic groups will fail to save with a licensing error, not a silent failure.

**Step 2 — Confirm group configuration**
```powershell
$GroupId = "<GroupObjectId>"
Get-MgGroup -GroupId $GroupId -Property "DisplayName,GroupTypes,MembershipRule,MembershipRuleProcessingState,SecurityEnabled,MailEnabled"
```
Expected: `GroupTypes` contains `DynamicMembership`; `MembershipRuleProcessingState` = `On`.

**Step 3 — Validate rule against a specific user (portal, no PowerShell equivalent exists)**
`Entra Portal → Groups → <group> → Dynamic membership rules → Validate Rules tab → Add users to validate → check result`
This is the single most reliable diagnostic step — it evaluates the *actual stored rule* against the *actual current attribute snapshot*, exactly as the engine would.

**Step 4 — Inspect the exact attribute values driving the rule**
```powershell
$UPN = "<user@domain.com>"
Get-MgUser -UserId $UPN -Property "department,jobTitle,companyName,usageLocation,country,accountEnabled,userType,onPremisesSyncEnabled,onPremisesLastSyncDateTime" |
    Format-List
```
Compare byte-for-byte against the rule's literal string values. Trailing spaces and smart-quote characters pasted from Word/Outlook are the most common invisible cause of mismatch.

**Step 5 — Confirm evaluation isn't just queued (large tenant / bulk change scenario)**
```powershell
$before = (Get-MgGroupMember -GroupId $GroupId -All).Count
Start-Sleep -Seconds 300
$after = (Get-MgGroupMember -GroupId $GroupId -All).Count
"$before -> $after"
```
If the count is moving, the engine is actively processing — do not intervene further, just wait.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Confirm the Feature Is Even Working
1. Check `membershipRuleProcessingState` — `Paused` explains 100% of "nothing is updating" tickets by itself
2. Confirm tenant has valid P1/P2 licensing (dynamic groups silently stop evaluating if licensing lapses — existing members are usually retained but new evaluation halts)

### Phase 2 — Rule Correctness
1. Open Validate Rules tab against the affected user/device
2. If user does NOT appear as matching: the rule is wrong, not a timing issue — go to attribute inspection (Step 4 above)
3. If user DOES appear as matching in Validate Rules but is NOT an actual group member: this is now a timing/queue issue, go to Phase 3

### Phase 3 — Timing and Sync Lag
1. For on-prem synced attributes: confirm `onPremisesLastSyncDateTime` postdates the attribute change
2. If sync is current but membership still hasn't updated: check evaluation queue behavior (Step 5)
3. Large bulk operations (HR system import touching thousands of users) can queue evaluation for hours — this is expected, not a bug

### Phase 4 — Downstream Consumer Lag (group is correct, but "nothing happened")
1. If licenses aren't applying: check `Get-MgUser -Property assignedLicenses` for a `licenseAssignmentStates` error, independent of group membership
2. If CA isn't respecting new membership: CA reads group membership at token issuance — user must get a new token (sign out/in, or wait for token refresh) — CA does not push-invalidate active sessions on group change
3. If Intune isn't targeting the device/user: Intune polls on its own check-in schedule (up to 8h) — this is Intune's cadence, not the dynamic group's

### Phase 5 — Structural Rule Redesign
1. If the ask requires transitive/nested group logic: redesign around a directly-settable attribute (extension attribute or custom security attribute) set by an automation (Graph script, Logic App) rather than trying to force the rule engine to do group-of-groups logic
2. If the ask requires OR logic across many discrete values (e.g., 40 department codes): consider whether a custom security attribute set by HR provisioning is more maintainable than a 40-clause rule

---
## Remediation Playbooks

<details><summary>Playbook 1 — Audit all dynamic groups in the tenant for paused processing or zero-match rules</summary>

```powershell
Connect-MgGraph -Scopes "Group.Read.All"

$dynamicGroups = Get-MgGroup -All -Filter "groupTypes/any(c:c eq 'DynamicMembership')" `
    -Property "Id,DisplayName,MembershipRule,MembershipRuleProcessingState"

$report = foreach ($g in $dynamicGroups) {
    $memberCount = (Get-MgGroupMember -GroupId $g.Id -All).Count
    [PSCustomObject]@{
        DisplayName     = $g.DisplayName
        GroupId         = $g.Id
        ProcessingState = $g.MembershipRuleProcessingState
        MemberCount     = $memberCount
        Rule            = $g.MembershipRule
        Flag            = if ($g.MembershipRuleProcessingState -eq "Paused") { "PAUSED" }
                           elseif ($memberCount -eq 0) { "ZERO MEMBERS" }
                           else { "OK" }
    }
}

$report | Where-Object { $_.Flag -ne "OK" } | Format-Table -AutoSize
$report | Export-Csv "$env:TEMP\DynamicGroupAudit_$(Get-Date -Format yyyyMMdd-HHmm).csv" -NoTypeInformation
```

Run this quarterly as a hygiene check — paused groups and zero-member rules accumulate silently over time as tenants evolve.

**Rollback:** N/A — read-only audit.

</details>

<details><summary>Playbook 2 — Migrate a fragile multi-clause OR rule to a custom security attribute</summary>

**Cause:** Rules with many OR branches (e.g., matching 30+ discrete cost center codes) are hard to maintain and error-prone to edit safely.

```powershell
Connect-MgGraph -Scopes "CustomSecAttributeDefinition.ReadWrite.All","CustomSecAttributeAssignment.ReadWrite.All","Group.ReadWrite.All"

# 1. Define a custom security attribute set/attribute (one-time, requires Attribute Definition Administrator)
$attributeSet = @{
    id          = "Provisioning"
    description = "Attributes driving dynamic group membership"
}
# (Attribute sets/definitions are typically created via portal: Entra ID > Custom security attributes)

# 2. Assign the attribute to affected users via an automation/script instead of relying on HR attribute mapping
Update-MgUser -UserId "<UPN>" -CustomSecurityAttributes @{
    Provisioning = @{
        "@odata.type" = "#Microsoft.DirectoryServices.CustomSecurityAttributeValue"
        InScopeGroup  = "True"
    }
}

# 3. Simplify the dynamic rule to reference the single custom attribute
$newRule = '(user.customSecurityAttributes -match "Provisioning_InScopeGroup:True")'
Update-MgGroup -GroupId "<GroupObjectId>" -BodyParameter @{ membershipRule = $newRule }
```

**Rollback:** Revert `MembershipRule` to the prior multi-clause string; custom security attribute values can remain assigned without effect once the rule no longer references them.

</details>

<details><summary>Playbook 3 — Force full re-evaluation after a licensing or feature lapse</summary>

**Cause:** Tenant P1/P2 licensing lapsed temporarily (e.g., trial expiry gap before renewal), during which dynamic groups stopped evaluating new changes.

```powershell
Connect-MgGraph -Scopes "Group.ReadWrite.All"

$GroupId = "<GroupObjectId>"

# Toggling processing state off then on forces a full re-evaluation against all applicable objects
Update-MgGroup -GroupId $GroupId -BodyParameter @{ membershipRuleProcessingState = "Paused" }
Start-Sleep -Seconds 10
Update-MgGroup -GroupId $GroupId -BodyParameter @{ membershipRuleProcessingState = "On" }
```

Expect a delay proportional to tenant size before all affected objects re-settle. For tenants with 10,000+ users, allow several hours before escalating.

**Rollback:** N/A — this is itself the corrective action.

</details>

---
## Evidence Pack

```powershell
# Collects everything needed to escalate a dynamic group issue to Microsoft or hand off to another engineer
Connect-MgGraph -Scopes "Group.Read.All","GroupMember.Read.All","User.Read.All","Organization.Read.All"

$GroupId = "<GroupObjectId>"
$UPN     = "<user@domain.com>"
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"

$evidence = [ordered]@{}
$evidence["Group_Config"] = Get-MgGroup -GroupId $GroupId -Property "DisplayName,GroupTypes,MembershipRule,MembershipRuleProcessingState,Id,CreatedDateTime"
$evidence["Group_Members"] = Get-MgGroupMember -GroupId $GroupId -All | Select-Object Id, @{N="Name";E={$_.AdditionalProperties.displayName}}
$evidence["Target_User_Attributes"] = Get-MgUser -UserId $UPN -Property "department,jobTitle,companyName,usageLocation,country,accountEnabled,userType,onPremisesSyncEnabled,onPremisesLastSyncDateTime"
$evidence["Tenant_Licensing"] = Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits

$evidence.GetEnumerator() | ForEach-Object {
    $_.Value | Export-Csv "$env:TEMP\DynGroup_$($_.Key)_$timestamp.csv" -NoTypeInformation
}

Write-Host "Evidence collected to $env:TEMP\DynGroup_*_$timestamp.csv"
Write-Host "Also attach a screenshot of the Validate Rules tab result for the target user."
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| Get group config + rule | `Get-MgGroup -GroupId <id> -Property "GroupTypes,MembershipRule,MembershipRuleProcessingState"` |
| Pause/resume processing | `Update-MgGroup -GroupId <id> -BodyParameter @{membershipRuleProcessingState="On"}` |
| Update rule text | `Update-MgGroup -GroupId <id> -BodyParameter @{membershipRule=$rule}` |
| List all dynamic groups | `Get-MgGroup -All -Filter "groupTypes/any(c:c eq 'DynamicMembership')"` |
| Get current members | `Get-MgGroupMember -GroupId <id> -All` |
| Get user's rule-relevant attributes | `Get-MgUser -UserId <upn> -Property "department,jobTitle,usageLocation,userType"` |
| Check sync freshness | `Get-MgUser -UserId <upn> -Property "onPremisesLastSyncDateTime"` |
| Force Entra Connect delta sync | `Start-ADSyncSyncCycle -PolicyType Delta` (run on connector server) |
| Check tenant licensing | `Get-MgSubscribedSku` |
| Get device rule-relevant attributes | `Get-MgDevice -DeviceId <id> -Property "operatingSystem,trustType,deviceOwnership"` |
| Validate rule against user (no PS equivalent) | Portal → Group → Dynamic membership rules → Validate Rules |

---
## 🎓 Learning Pointers

- **The rule engine validates syntax, never semantics.** There is no Microsoft-provided way to know a rule matches zero users except by testing it — build a habit of validating every new/edited rule against at least one known-good test user before considering the change complete. [MS Docs: Dynamic membership rules for groups](https://learn.microsoft.com/en-us/entra/identity/users/groups-dynamic-membership)
- **CA and Intune don't get instant membership updates — they poll or evaluate on their own schedules.** A "fixed" dynamic group can look broken to a user two hops downstream simply because CA hasn't re-issued a token yet or Intune hasn't checked in. Always separate "is the group membership correct" from "has every downstream consumer picked it up yet." [MS Docs: Conditional Access session lifetime](https://learn.microsoft.com/en-us/entra/identity/conditional-access/howto-conditional-access-session-lifetime)
- **Custom security attributes are underused as a stabilizer for fragile rules.** Rules with many OR branches on volatile source data (job titles change more than you'd think) are a maintenance trap — pushing the logic into a purpose-built attribute set by automation is more resilient than trying to make the rule syntax do everything. [MS Docs: Custom security attributes](https://learn.microsoft.com/en-us/entra/fundamentals/custom-security-attributes-overview)
- **Group nesting does not work the way on-prem AD admins expect.** Coming from AD, it's natural to assume transitive group membership feeds cleanly into rule logic — it largely does not. Design dynamic rules around object attributes, treating group topology as a downstream consequence, not an input. [MS Docs: Dynamic membership rules syntax reference](https://learn.microsoft.com/en-us/entra/identity/users/groups-dynamic-membership)
- **Licensing lapses silently stop evaluation without deleting the group or its rule.** If P1/P2 licensing drops below the tenant-wide threshold (e.g., an expired trial before renewal processes), existing dynamic groups typically retain their last-known membership but stop evaluating new changes — this can look identical to a paused-processing issue and is worth ruling out during subscription changes.
