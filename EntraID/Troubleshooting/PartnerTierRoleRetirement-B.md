# Partner Tier1/Tier2 Support Role Retirement — Hotfix Runbook (Mode B: Ops)
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

**What retired:** Microsoft Entra is **blocking new assignments** to the built-in **Partner Tier1 Support** and **Partner Tier2 Support** directory roles, starting **August 3, 2026** (rollout completing by August 24, 2026). This is an assignment *block*, not a role deletion — existing assignments keep working unchanged, and removing an existing assignment still works normally. Only NEW assignment attempts (portal, Graph API, PowerShell, or Partner Center GDAP Access Assignment mapping) fail.

**Why this exists on the MSP-relevant side:** these two roles are documented as used specifically in **CSP/GDAP delegated access scenarios** — a partner mapping a GDAP relationship's Access Assignment to Partner Tier1/Tier2 Support instead of an ordinary Entra role. Any MSP with automation, a runbook, or a Partner Center template that still assigns these roles for new customer onboarding will start failing on or after Aug 3, 2026.

```powershell
# 1. Confirm whether this tenant currently HAS any active Partner Tier1/Tier2 Support assignments
#    (these two roles are in Microsoft's "Roles not shown in the portal" list — you will NOT
#    see them in the Entra admin center Roles UI; Graph/PowerShell is required)
Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
$tier1 = Get-MgDirectoryRole -Filter "DisplayName eq 'Partner Tier1 Support'"
$tier2 = Get-MgDirectoryRole -Filter "DisplayName eq 'Partner Tier2 Support'"
if ($tier1) { Get-MgDirectoryRoleMember -DirectoryRoleId $tier1.Id }
if ($tier2) { Get-MgDirectoryRoleMember -DirectoryRoleId $tier2.Id }

# 2. Reproduce/confirm the failure signature if a ticket reports "can't assign this role"
# Attempting a NEW assignment on/after 2026-08-03 returns:
#   HTTP 400 (Request_BadRequest) — "Request_BadRequest"
# NOT a 403 (permission) and NOT a 404 (role not found) — the role objects still exist.

# 3. Check GDAP Access Assignment templates for a stale role mapping (Partner Center, not Graph)
# partner.microsoft.com -> Customers -> <client> -> Admin relationships -> GDAP -> the
# relationship's Access Assignment -> role list. Look for "Partner Tier1 Support" /
# "Partner Tier2 Support" in any SAVED TEMPLATE used to spin up new relationships.
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| New role-assignment attempt (any surface) fails with HTTP 400 on/after 2026-08-03, targeting Partner Tier1/Tier2 Support | Expected — this is the retirement working as designed | Fix 1 |
| Existing assignment made *before* 2026-08-03 stopped working / user lost access | NOT expected from this change — existing assignments are explicitly unaffected; look elsewhere (Conditional Access, PIM expiry, license) first | Fix 2 |
| A script/automation that provisions new CSP customer tenants suddenly fails partway through | Automation still hard-codes Partner Tier1/Tier2 Support in a role-assignment step | Fix 3 |
| A saved Partner Center GDAP Access Assignment template can't be reused for a NEW relationship | Template references a retired role for new assignment | Fix 4 |
| Ticket says "can't find this role in the Entra portal at all" (unrelated to the retirement) | Both roles were never shown in the standard Entra admin center Roles UI — this is normal, unrelated to the Aug 2026 change | Fix 5 |
| Some other, unrelated role assignment is failing with HTTP 400 | Not this retirement — only these two specific roles are blocked; check the target role name carefully | Escalate separately |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Entra built-in role lifecycle management
    └── Partner Tier1 Support role          } both retired as assignable roles
        Partner Tier2 Support role          } beginning 2026-08-03, complete ~2026-08-24
                │
        ┌───────┴────────────────────────────────────┐
        │                                              │
   NEW assignment attempt                    EXISTING assignment (made before cutover)
   (portal / Graph API /                              │
    PowerShell / Partner                      Continues to function UNCHANGED
    Center GDAP template)                     Removal of the assignment still works normally
        │                                      No forced de-provisioning, no expiry triggered
   BLOCKED — HTTP 400
   (Request_BadRequest)
        │
   Affected surfaces:
     - Direct Entra role assignment (rare outside CSP/support contexts)
     - Partner Center GDAP Access Assignment role mapping for a NEW relationship
     - Any Graph/PowerShell automation that assigns these roleTemplateIds programmatically
        │
   Recommended replacement roles (least-privilege, NOT a 1:1 permission match —
   review actual required permissions before picking one):
     - User Administrator        (closest general replacement per Microsoft's own guidance)
     - Helpdesk Administrator
     - Groups Administrator
     - License Administrator
     - Domain Name Administrator
     - OR a custom role scoped to the exact permissions actually needed
```

**Key concept:** this is a lifecycle *assignment block*, not a permission change to existing holders and not a role deletion. A tenant that has never used either role sees zero operational impact.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the exact role name in the failing request.** "Partner Tier1 Support" and "Partner Tier2 Support" are the only two roles affected. A different role failing with a similar-looking error is not this retirement.

**Step 2 — Confirm the assignment is genuinely NEW, not a re-save of an existing one.**
```powershell
Get-MgDirectoryRoleMember -DirectoryRoleId $tier1.Id
Get-MgDirectoryRoleMember -DirectoryRoleId $tier2.Id
```
If the principal is already listed, the operation failing is likely a *modification* (e.g., scope change) being misread as a new assignment by the calling tool — reproduce the exact API call to confirm.

**Step 3 — Confirm the date.** Rollout is global, beginning **August 3, 2026** and expected complete by **August 24, 2026**. A failure reported before Aug 3 is not this change (check for an unrelated Conditional Access or RBAC issue instead); a failure reported after Aug 24 should be treated as fully rolled out with no tenant-by-tenant variance expected.

**Step 4 — For GDAP-specific tickets, check Partner Center Access Assignment templates**, not Graph — GDAP relationship role mapping is a Partner Center construct, not a directly Graph-queryable assignment until the relationship is activated.

**Step 5 — If existing access broke, rule this retirement out explicitly** before investigating further — Microsoft's own documentation states existing assignments are unaffected. Check PIM eligibility expiry, Conditional Access policy changes, or license removal instead.

---

## Common Fix Paths

<details><summary>Fix 1 — New assignment correctly blocked (expected behavior)</summary>

**Cause:** Working as designed. No fix needed on the platform side.

**Remediation:**
1. Confirm with the requester what access they actually need.
2. Assign one of the recommended replacement roles instead — **User Administrator** is the closest general-purpose fit for most former Partner Tier1/Tier2 Support use cases:
```powershell
$replacementRole = Get-MgDirectoryRole -Filter "DisplayName eq 'User Administrator'"
New-MgDirectoryRoleMemberByRef -DirectoryRoleId $replacementRole.Id -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/<principalObjectId>"
}
```
3. If the required permission set is narrower than any single built-in role, build a **custom role** scoped to only the needed permissions instead of over-granting a broad built-in role.

**Rollback:** N/A — no assignment was made; nothing to roll back.

</details>

<details><summary>Fix 2 — Existing access broke (this is NOT the retirement)</summary>

**Cause:** By Microsoft's own documentation, pre-existing Partner Tier1/Tier2 Support assignments continue to function without change. If access broke, look elsewhere.

**Remediation:**
1. Confirm the assignment still exists: `Get-MgDirectoryRoleMember -DirectoryRoleId $tier1.Id` (or Tier2).
2. If it's PIM-eligible rather than a permanent (Active) assignment, check for expired eligibility or a lapsed activation.
3. Check Conditional Access sign-in logs for the affected principal — a CA policy change is a far more common cause of sudden access loss than this retirement.
4. Check for a recent license change if the principal is a user rather than a service principal.

**Rollback:** N/A — diagnostic redirection, not a configuration change.

</details>

<details><summary>Fix 3 — Automation/provisioning script hard-codes the retired role</summary>

**Cause:** A tenant-onboarding script, ARM/Bicep template, or Graph automation still assigns `Partner Tier1 Support` or `Partner Tier2 Support` by roleTemplateId as part of a repeatable process (e.g., standing up GDAP access for every new CSP customer).

**Remediation:**
1. Search the automation source for the roleTemplateIds:
   - Partner Tier1 Support: consult `Get-MgDirectoryRoleTemplate | Where-Object DisplayName -eq "Partner Tier1 Support"` in a tenant where it's still resolvable, since template IDs are stable across tenants but not reliably documented inline here — verify live rather than hard-coding a remembered GUID.
   - Same pattern for Partner Tier2 Support.
2. Replace the hard-coded role assignment step with one of the recommended replacement roles (User Administrator in most cases).
3. Add an explicit guard/try-catch around role-assignment steps in onboarding automation generally, so a future role retirement fails loudly with a clear message instead of silently aborting mid-provisioning.

**Rollback:** Revert the automation change if the replacement role proves to be the wrong permission fit — this is a code change, fully reversible via source control.

</details>

<details><summary>Fix 4 — Stale GDAP Access Assignment template</summary>

**Cause:** A saved Partner Center Access Assignment template (used to speed up onboarding new customers with a consistent role set) includes Partner Tier1/Tier2 Support in its role list, and that template is being reused to create a NEW relationship.

**Remediation:**
1. In Partner Center: **Customers** → **Admin relationships** → **GDAP** → open the template → remove Partner Tier1/Tier2 Support from the role list.
2. Add the appropriate replacement role(s) instead (User Administrator / Helpdesk Administrator / Groups Administrator / License Administrator / Domain Name Administrator, per what the template was actually trying to grant).
3. Re-test the template against a non-production or low-risk customer relationship before rolling it out broadly.

**Rollback:** N/A — template edit is directly reversible by re-adding the old role name, though doing so will not restore the ability to assign it.

</details>

<details><summary>Fix 5 — "I can't find this role in the portal" (unrelated to the retirement)</summary>

**Cause:** Partner Tier1 Support and Partner Tier2 Support have never been shown in the standard Entra admin center Roles UI — Microsoft documents them under "Roles not shown in the portal." This is normal, pre-existing behavior, not a symptom of the Aug 2026 retirement.

**Remediation:** Use Graph or PowerShell (`Get-MgDirectoryRole -Filter "DisplayName eq 'Partner Tier1 Support'"`) to view or manage these roles instead of searching the portal UI. If the actual need is to assign a NEW instance of either role, redirect to Fix 1 — that assignment is blocked regardless of which surface is used.

**Rollback:** N/A.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Partner Tier1/Tier2 Support Role Retirement
=====================================
Tenant:                           [tenant name/ID]
Role in question:                 [ ] Partner Tier1 Support   [ ] Partner Tier2 Support
Ticket concerns:                  [ ] New assignment blocked (expected)
                                   [ ] Existing assignment broke (NOT expected — investigate separately)
                                   [ ] Automation/provisioning script failure
                                   [ ] GDAP Access Assignment template issue
Assignment attempt date:          [date — before/on/after 2026-08-03?]
Exact error returned:             [HTTP status + message]
Current role membership (if any): [output of Get-MgDirectoryRoleMember]
Replacement role selected:        [User Administrator / Helpdesk Administrator / Groups Administrator /
                                    License Administrator / Domain Name Administrator / custom role]
Message Center post reviewed:     [MC1409305 — Yes/No]

Symptom description:
[what the user/admin reported]

Steps already attempted:
[ ] Confirmed exact role name (only these two roles are affected)
[ ] Confirmed assignment date relative to 2026-08-03 rollout start
[ ] Ruled out this retirement as the cause if EXISTING access broke
[ ] Checked Partner Center GDAP Access Assignment templates for stale role references
[ ] Selected and tested an appropriate replacement role
```

---

## 🎓 Learning Pointers

- **This is an assignment block, not a role deletion or a permission change.** Existing holders of Partner Tier1/Tier2 Support keep their access exactly as before; only NEW assignment attempts fail. Don't treat this as an emergency de-provisioning event. [Microsoft Entra built-in roles reference](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference)

- **These two roles were never visible in the standard Entra admin center Roles UI.** Microsoft's own docs list them under "Roles not shown in the portal" — if a ticket says "I can't find this role anywhere," that's normal pre-existing behavior requiring Graph/PowerShell, not a symptom of this retirement. Don't conflate the two issues.

- **User Administrator is Microsoft's own stated closest replacement for most scenarios** — but it is not a 1:1 permission match. Review what the original Partner Tier1/Tier2 Support assignment was actually being used for before defaulting to the broadest available role; Helpdesk Administrator, Groups Administrator, License Administrator, or Domain Name Administrator may be a tighter least-privilege fit depending on the use case, and a custom role is worth building for anything narrower still.

- **The failure signature is HTTP 400 (Request_BadRequest), not 403 or 404.** A 403 means a permissions problem with the *caller*; a 404 would mean the role object itself is gone (it isn't — the roles still exist, they're just blocked from new assignment). Matching the exact error code quickly confirms or rules out this retirement.

- **This directly affects CSP/GDAP-delegated-access automation** — the primary documented affected audience is admins managing role assignments in CSP or GDAP scenarios. Any MSP with a standardized new-customer-onboarding script or a saved Partner Center Access Assignment template should audit for these two role names proactively rather than waiting for the first failed onboarding to surface it.

- **Rollout is global and time-boxed (Aug 3 – Aug 24, 2026), with no tenant opt-in/opt-out.** There's no configuration flag to check or toggle — the only meaningful diagnostic question is "is today's date past the rollout window," not "is this feature enabled for us."
