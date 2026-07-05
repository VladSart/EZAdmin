# Entra ID Dynamic Groups — Hotfix Runbook (Mode B: Ops)
> Fix or escalate dynamic group membership issues in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Run these first. Paste output when escalating.

```powershell
Connect-MgGraph -Scopes "Group.Read.All","GroupMember.Read.All","Directory.Read.All" -NoWelcome

$GroupId = "<GroupObjectId>"
$UPN     = "<user@domain.com>"

# 1. Confirm the group is actually dynamic and get its rule
Get-MgGroup -GroupId $GroupId -Property "DisplayName,GroupTypes,MembershipRule,MembershipRuleProcessingState" |
    Select-Object DisplayName, GroupTypes, MembershipRule, MembershipRuleProcessingState

# 2. Check the rule processing state — this is the #1 thing people forget to check
#    "Paused" means NO membership updates are happening at all, tenant-wide or per-group

# 3. Check whether the specific user is currently a member
Get-MgGroupMember -GroupId $GroupId -All | Where-Object { $_.AdditionalProperties.userPrincipalName -eq $UPN }

# 4. Check the attributes the rule depends on, on the user object
Get-MgUser -UserId $UPN -Property "department,jobTitle,companyName,usageLocation,accountEnabled,extensionAttribute1"

# 5. Check for a recent attribute change (on-prem synced attributes lag until next Entra Connect sync cycle)
Get-MgUser -UserId $UPN -Property "onPremisesLastSyncDateTime,onPremisesSyncEnabled"
```

**Interpretation:**

| Finding | Action |
|---------|--------|
| `MembershipRuleProcessingState: Paused` | → Fix 1: Resume rule processing |
| User's attribute doesn't match rule syntax exactly | → Fix 2: Correct rule syntax or fix source attribute |
| Attribute was just changed on-prem, `onPremisesLastSyncDateTime` is old | → Fix 3: Trigger Entra Connect delta sync, then wait for evaluation |
| Rule references an attribute that is `$null` on the user | → Fix 4: Handle null attributes explicitly in the rule |
| User is a guest / service account and rule doesn't account for `userType` | → Fix 5: Scope rule by `userType` |

---

## Dependency Cascade

<details><summary>What must be true for dynamic membership to update</summary>

```
Entra ID P1/P2 license (Dynamic Groups requires P1 minimum, tenant-wide feature)
  └── Group configured as GroupTypes: ["DynamicMembership"]
        └── MembershipRule syntax is valid (validated at save time, not at eval time)
              └── MembershipRuleProcessingState = "On" (not "Paused")
                    └── Source attribute exists and is populated on the user/device object
                          ├── Cloud-only attribute — set directly or via Graph
                          └── On-prem synced attribute — must survive Entra Connect sync first
                                └── Entra Connect delta/full sync cycle has run since the attribute changed
                                      └── Membership evaluation engine processes the change
                                            (near-real-time trigger on attribute write, but can queue
                                             under load — not instantaneous in large tenants)
                                                  └── Group membership updates; downstream consumers
                                                      (licensing, CA, Intune, Exchange DLs) re-evaluate
```

**Key interlock:** Rule *syntax* being accepted at save time does NOT mean it evaluates the way you expect — a rule can be syntactically valid and still never match any users due to a typo in a value or wrong attribute name casing.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the group is dynamic and get exact rule text**
```powershell
Get-MgGroup -GroupId $GroupId -Property "DisplayName,GroupTypes,MembershipRule,MembershipRuleProcessingState"
```
*Good:* `GroupTypes` contains `DynamicMembership`, `MembershipRuleProcessingState` = `On`.
*Bad:* `MembershipRuleProcessingState` = `Paused` — nothing will update until resumed. `GroupTypes` empty — this is actually an assigned group, not dynamic; wrong runbook.

---

**Step 2 — Test the rule logic manually against the target user's actual attributes**
```powershell
$UPN = "<user@domain.com>"
Get-MgUser -UserId $UPN -Property "department,jobTitle,companyName,usageLocation,country,accountEnabled,userType"
```
Compare each attribute value character-for-character against the rule. Dynamic membership rules are case-insensitive for string comparisons but **exact-match** for value spelling — `"Sales"` will not match `"sales team"`.

---

**Step 3 — Check for validation vs. evaluation mismatch**
A rule like:
```
(user.department -eq "Sales") and (user.accountEnabled -eq true)
```
is syntactically valid even if no user will ever match it (e.g., wrong department string). Entra ID does not warn you at save time if the rule matches zero users.

*Good:* Portal's "Validate rules" preview (Entra ID > Groups > group > Dynamic membership rules > Validate Rules tab) shows the target user in the preview.
*Bad:* Target user does not appear in the validation preview despite meeting the intended criteria — the rule itself is wrong, not a processing delay.

---

**Step 4 — Rule out sync lag for on-prem synced attributes**
```powershell
Get-MgUser -UserId $UPN -Property "onPremisesLastSyncDateTime,onPremisesSyncEnabled"
```
*Good:* `onPremisesLastSyncDateTime` is recent (within the last sync cycle, typically 30 minutes).
*Bad:* Timestamp predates the attribute change made on-prem — the change hasn't synced to Entra ID yet; dynamic group evaluation runs against the Entra ID copy of the attribute, not the on-prem source directly.

---

**Step 5 — Confirm the group isn't hitting the 5-minute-to-several-hour evaluation queue under load**
Large tenants (or tenants making many simultaneous attribute changes, e.g. during a bulk import) can see dynamic group evaluation queue delays.
```powershell
# No direct cmdlet exposes queue depth; practical check:
# Re-run Step 1's member list a few minutes apart to see if membership is actively changing
Get-MgGroupMember -GroupId $GroupId -All | Measure-Object | Select-Object Count
```
If the count is actively climbing/falling over repeated checks, the engine is working — just queued. If it's static and the rule/attributes are confirmed correct, escalate.

---

## Common Fix Paths

<details><summary>Fix 1 — Resume paused rule processing</summary>

**Cause:** Rule processing was paused tenant-wide (often during a bulk operation) or per-group and never resumed.

```powershell
Connect-MgGraph -Scopes "Group.ReadWrite.All"

$GroupId = "<GroupObjectId>"

Update-MgGroup -GroupId $GroupId -BodyParameter @{
    membershipRuleProcessingState = "On"
}

# Confirm
(Get-MgGroup -GroupId $GroupId -Property "MembershipRuleProcessingState").MembershipRuleProcessingState
```
Resuming triggers a full re-evaluation of the rule against all applicable objects — expect a delay proportional to tenant size before membership fully settles.

**Rollback:**
```powershell
Update-MgGroup -GroupId $GroupId -BodyParameter @{ membershipRuleProcessingState = "Paused" }
```

</details>

<details><summary>Fix 2 — Correct rule syntax or source attribute value</summary>

**Cause:** Rule references the wrong attribute name, wrong value spelling, or wrong operator.

```powershell
Connect-MgGraph -Scopes "Group.ReadWrite.All"

$GroupId = "<GroupObjectId>"

# Example: correcting a department string mismatch
$newRule = '(user.department -eq "Sales") and (user.accountEnabled -eq true)'

Update-MgGroup -GroupId $GroupId -BodyParameter @{
    membershipRule = $newRule
}
```
Common syntax mistakes:
- Using `-contains` on a single-value string attribute instead of `-eq` (contains is for multi-value/array attributes like `memberOf` or `otherMails`)
- Forgetting `user.` or `device.` prefix on the attribute
- Comparing against `$null` incorrectly — use `-eq $null` / `-ne $null`, not `-eq ""`
- Case mismatch in extension attribute names (`extensionAttribute1` vs `ExtensionAttribute1` — Graph is case-sensitive on custom extension attribute names in some rule contexts)

**Rollback:** Revert to the previous `MembershipRule` string (keep a copy before editing).

</details>

<details><summary>Fix 3 — Force Entra Connect delta sync for stale on-prem attributes</summary>

**Cause:** The attribute changed on-prem but hasn't synced to Entra ID yet, so the rule evaluates against the old value.

Run on the Entra Connect server:
```powershell
Import-Module ADSync
Start-ADSyncSyncCycle -PolicyType Delta
```
Wait for completion, then re-check:
```powershell
Get-MgUser -UserId $UPN -Property "department,onPremisesLastSyncDateTime"
```

**Rollback:** N/A — sync is one-directional and idempotent; re-running does not undo anything.

</details>

<details><summary>Fix 4 — Handle null attributes explicitly in the rule</summary>

**Cause:** Rule doesn't account for users where the source attribute is unset (`$null`), silently excluding or including unexpected users.

```powershell
Connect-MgGraph -Scopes "Group.ReadWrite.All"

$GroupId = "<GroupObjectId>"

# Example: exclude users with no department set, rather than letting them
# match unpredictably
$newRule = '(user.department -eq "Sales") and (user.department -ne $null) and (user.accountEnabled -eq true)'

Update-MgGroup -GroupId $GroupId -BodyParameter @{ membershipRule = $newRule }
```

**Rollback:** Revert to the previous `MembershipRule` string.

</details>

<details><summary>Fix 5 — Scope rule by userType to exclude guests/service accounts</summary>

**Cause:** Rule unintentionally captures guest accounts or service accounts that happen to share an attribute value with intended members.

```powershell
Connect-MgGraph -Scopes "Group.ReadWrite.All"

$GroupId = "<GroupObjectId>"

$newRule = '(user.department -eq "Sales") and (user.userType -eq "Member") and (user.accountEnabled -eq true)'

Update-MgGroup -GroupId $GroupId -BodyParameter @{ membershipRule = $newRule }
```

**Rollback:** Revert to the previous `MembershipRule` string.

</details>

---

## Escalation Evidence

```
=== DYNAMIC GROUP ISSUE ESCALATION ===
Date/Time (UTC):              ____________________
Reported by:                  ____________________
Group name / Object ID:       ____________________
Affected user UPN:            ____________________
Tenant ID:                    ____________________
Issue description:            ____________________

=== CHECKS COMPLETED ===
[ ] MembershipRuleProcessingState:      ON / PAUSED
[ ] Current MembershipRule text:        ____________________
[ ] User's relevant attribute value(s): ____________________
[ ] Rule "Validate Rules" preview shows user: YES / NO
[ ] onPremisesLastSyncDateTime:         ____________________
[ ] User currently a member:            YES / NO
[ ] Membership count changing over repeated checks: YES / NO

=== ACTIONS TAKEN ===
[ ] Resumed rule processing:            YES / NO
[ ] Corrected rule syntax:               YES / NO — old rule: ____________________
[ ] Forced Entra Connect delta sync:     YES / NO
[ ] Added null/userType handling:        YES / NO

=== ESCALATION PATH ===
If membership still hasn't updated after 4+ hours with all checks passing:
- Open a case via https://admin.microsoft.com
- Provide: Group Object ID, Tenant ID, exact MembershipRule text, timestamp attribute was set
- Request: Backend dynamic group evaluation queue status for the tenant
```

---

## 🎓 Learning Pointers

- **A syntactically valid rule can still match zero users.** Entra ID validates rule *syntax* at save time, not whether it will ever produce a match. Always use the "Validate Rules" preview tab against a known test user before assuming the rule is broken vs. simply never matching anything. [MS Docs: Dynamic membership rules for groups](https://learn.microsoft.com/en-us/entra/identity/users/groups-dynamic-membership)

- **`MembershipRuleProcessingState: Paused` is the most commonly missed check.** It's easy to pause processing during a bulk operation (e.g., a large attribute import) and forget to resume it — the group will look correctly configured but simply never update. Always check this first, before touching rule syntax. [MS Docs: Pause and resume dynamic group processing](https://learn.microsoft.com/en-us/entra/identity/users/groups-troubleshooting)

- **On-prem synced attributes have two lag points, not one.** The attribute must first sync from on-prem AD to Entra ID via Entra Connect, THEN the dynamic group engine must evaluate the change. Checking only the Entra Connect sync status without also confirming the group's own evaluation queue can lead to premature "still broken" conclusions. [MS Docs: Dynamic membership rules syntax](https://learn.microsoft.com/en-us/entra/identity/users/groups-dynamic-membership)

- **`-contains` vs `-eq` is the single most common rule-writing mistake.** Use `-eq` for single-value string attributes (`department`, `jobTitle`) and `-contains` only for true multi-value attributes (`otherMails`, `proxyAddresses`). Using the wrong operator produces a rule that "looks right" but silently matches nobody.

- **Dynamic groups are a tenant-wide P1 feature, licensed by the tenant, not per-group or per-member.** You don't need to license every user who will be a member — you need at least one Entra ID P1 (or P2) license in the tenant to unlock the dynamic membership feature itself. [MS Docs: Create a dynamic group](https://learn.microsoft.com/en-us/entra/identity/users/groups-create-rule)
