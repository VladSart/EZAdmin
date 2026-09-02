# Partner Tier1/Tier2 Support Role Retirement — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers Microsoft's retirement of **new assignments** to the built-in **Partner Tier1 Support** and **Partner Tier2 Support** Microsoft Entra directory roles, announced via Message Center post **MC1409305** (published 2026-06-29) and rolling out globally **2026-08-03 through ~2026-08-24**. It assumes:

- The reader understands Entra built-in role assignment basics (`Get-MgDirectoryRole`, `New-MgDirectoryRoleMemberByRef`) and, for the CSP-specific angle, has basic familiarity with GDAP (Granular Delegated Admin Privileges) relationships in Partner Center.
- This is **not** a general GDAP relationship-lifecycle troubleshooting guide — for GDAP invitation/activation/expiry mechanics generally, see `GDAP-A.md`/`-B.md`. This runbook covers only the narrower, date-driven retirement event affecting two specific roles that GDAP relationships can optionally reference in their Access Assignment role mapping.
- Facts below are sourced from Microsoft's Message Center post MC1409305 (published 2026-06-29) and Microsoft's own built-in roles reference documentation. As of this writing, no independent secondary confirmation (community blog coverage) was located beyond Message Center aggregator mirrors — this is a lower-profile retirement than, for example, the MDTI standalone retirement, likely because the affected roles have always had limited, specialist usage.

---

## How It Works

### What's Actually Retiring

Two built-in Microsoft Entra directory roles — **Partner Tier1 Support** and **Partner Tier2 Support** — are having **new-assignment capability** blocked, as part of Microsoft's stated "ongoing role lifecycle management" practice of retiring roles that are "no longer intended for use," in favor of encouraging least-privilege role selection.

This is deliberately **not** a full role deletion:
- The role objects themselves continue to exist in the directory.
- Existing assignments (made before the cutover) continue to function with no change in effective permissions.
- **Removing** an existing assignment continues to work normally — only the *creation* of a new assignment is blocked.
- No other Entra built-in roles are affected by this specific change.

### Why These Roles Exist At All

Partner Tier1 Support and Partner Tier2 Support are historically specialist roles associated with CSP (Cloud Solution Provider) and GDAP delegated-access scenarios — roles a partner organization could assign to grant support-tier-scoped access into a managed customer tenant, distinct from the broader administrative roles (Global Administrator, User Administrator, etc.) more commonly used for day-to-day tenant management. Unlike most built-in roles, **both are explicitly documented by Microsoft under "Roles not shown in the portal"** — they have never appeared in the standard Entra admin center's Roles blade UI, and administering them (viewing membership, assigning, removing) has always required Microsoft Graph or PowerShell (`Get-MgDirectoryRole`/`Get-AzureADDirectoryRole` and related cmdlets), never the portal directly. This portal-invisibility is a pre-existing characteristic of the roles, unrelated to and unaffected by this retirement — it's called out here specifically because it's a common source of ticket confusion ("I can't find this role" vs. "I can't assign this role" are two entirely different problems that get reported with similar language).

### The Retirement Mechanism

The retirement is enforced entirely at the assignment-creation layer, uniformly across every surface capable of creating a role assignment:

- Microsoft Entra admin center (to the extent these roles were ever reachable there via deep links or API-driven UI paths)
- Microsoft Graph API (`POST /roleManagement/directory/roleAssignments`, or the directory-role-member-by-ref pattern)
- PowerShell modules wrapping the above (Microsoft Graph PowerShell SDK, and any legacy AzureAD/MSOnline equivalents still in use)
- Partner Center's GDAP Access Assignment role-mapping step, when creating a **new** GDAP relationship (or adding a **new** role mapping to an existing relationship's Access Assignment) that references either role

A new-assignment attempt against either role returns **HTTP 400 (`Request_BadRequest`)**. This is a deliberate, explicit block response — not a generic error, not a permissions-denied 403, and not a "role not found" 404. The distinction matters operationally: a 403 would point an engineer toward the *caller's* permissions as the problem; a 404 would (incorrectly) suggest the role no longer exists. The 400 response correctly signals "the request itself is invalid" — the role exists and the caller may well have sufficient privilege to assign roles generally, but this specific operation is disallowed by policy.

### Rollout Mechanics

Unlike many Entra changes that roll out per-tenant on a staggered schedule with per-tenant Message Center timing variance, this retirement is described by Microsoft as a **single global rollout window**: beginning August 3, 2026, and expected to complete by August 24, 2026. There is no tenant-level opt-in, opt-out, or feature flag to check — the only meaningful "is this live for us yet" diagnostic is the current date relative to that window, not any tenant configuration state. By the far end of the window (post Aug 24, 2026), the retirement should be considered universally in effect with no tenant-by-tenant variance expected.

### Recommended Replacement Roles

Microsoft's own guidance in MC1409305 does not present a single 1:1 role-for-role replacement — because Partner Tier1/Tier2 Support were relatively broad, support-context-specific roles, no single built-in role maps cleanly onto "whatever a support engineer at tier 1 or tier 2 needed to do." Instead, Microsoft names a menu of candidate replacements to choose from based on actual need:

| Candidate replacement | When it's the better fit |
|---|---|
| **User Administrator** | Microsoft's own stated default/closest general-purpose fit for most former Partner Tier1/Tier2 Support use cases — broad user lifecycle management (create/update/delete users, reset non-admin passwords, manage most user properties) |
| **Helpdesk Administrator** | Narrower than User Administrator — password reset and basic user support actions only, appropriate for genuinely tier-1-support-scoped needs |
| **Groups Administrator** | When the actual need was group membership/lifecycle management rather than user account management |
| **License Administrator** | When the actual need was assigning/removing licenses, not broader account administration |
| **Domain Name Administrator** | Narrow, domain-configuration-specific — rarely the right fit for a general support role, called out by Microsoft mainly for completeness |
| **Custom role** | When none of the built-in options cleanly match the actual permission set needed — Microsoft explicitly suggests this as a least-privilege-aligned option |

The right choice depends entirely on what the specific Partner Tier1/Tier2 Support assignment being replaced was actually used for — defaulting reflexively to User Administrator for every case risks over-provisioning access broader than what was previously granted.

### The GDAP-Specific Angle

GDAP (Granular Delegated Admin Privileges) relationships in Partner Center let a CSP partner scope delegated access into a customer tenant down to specific Entra roles, mapped via the relationship's **Access Assignment**. Historically, Partner Tier1 Support and Partner Tier2 Support were among the selectable roles in that mapping — appropriate for partners wanting to grant their own tier-1/tier-2 support staff narrowly scoped access into managed customer tenants without handing out broader administrative roles. After this retirement takes effect, attempting to select either role when creating a **new** GDAP relationship (or adding a new role to an existing relationship's Access Assignment) fails with the same underlying HTTP 400 block — this surfaces through the Partner Center UI rather than a raw Graph error, but the root cause is identical. Existing GDAP relationships that already reference these roles in their Access Assignment continue to function; only the creation of new role mappings referencing them is blocked.

---

## Dependency Stack

```
Microsoft Entra role lifecycle management (ongoing, Microsoft-driven)
        │
        ▼
Partner Tier1 Support role            Partner Tier2 Support role
(built-in, "Roles not shown           (built-in, "Roles not shown
 in the portal")                       in the portal")
        │                                       │
        └───────────────┬───────────────────────┘
                         ▼
        NEW-ASSIGNMENT BLOCK enforced globally
        2026-08-03 → ~2026-08-24 rollout window
                         │
        ┌────────────────┼─────────────────────────┐
        │                │                          │
   Graph API /      Entra admin center         Partner Center GDAP
   PowerShell        (roles never shown          Access Assignment
   direct assignment  in portal UI anyway)        role-mapping step
        │                │                          │
        └────────────────┴──────────────┬───────────┘
                                         ▼
                    HTTP 400 (Request_BadRequest)
                    on any NEW assignment attempt
                                         │
                         ┌───────────────┴────────────────┐
                         │                                  │
              EXISTING assignments               Removal of existing
              (pre-cutover) continue               assignments continues
              functioning UNCHANGED                to work normally
                         │
              No forced de-provisioning, no expiry, no permission change


── RECOMMENDED REPLACEMENT PATH (least-privilege selection) ──

Identify actual permission need behind the original assignment
        │
        ├── General user lifecycle management  → User Administrator
        ├── Password reset / basic support      → Helpdesk Administrator
        ├── Group membership management          → Groups Administrator
        ├── License assignment only               → License Administrator
        ├── Domain configuration only              → Domain Name Administrator
        └── None of the above cleanly fit           → Custom role (Entra custom
                                                        role definitions)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| New role assignment to Partner Tier1/Tier2 Support fails with HTTP 400 on/after 2026-08-03 | Expected — retirement working as designed | Confirm role name and date against rollout window |
| Same failure reported before 2026-08-03 | Not this retirement — investigate as an unrelated RBAC/permissions issue | Check caller's own role-assignment privilege (`RoleManagement.ReadWrite.Directory`) |
| Existing Partner Tier1/Tier2 Support assignment stopped granting access | NOT expected from this change — rule this retirement out explicitly | PIM eligibility expiry, Conditional Access policy change, license removal |
| CSP onboarding automation fails partway through new-customer setup | Automation hard-codes one of the retired roles by roleTemplateId | Grep automation source for the role display names/IDs |
| Partner Center GDAP Access Assignment template can't complete for a new relationship | Template references a retired role in its saved role list | Partner Center → GDAP relationship template → role list |
| "Role doesn't appear in the Entra admin center at all" | Pre-existing, unrelated behavior — these roles were never portal-visible | Confirm via `Get-MgDirectoryRole`, not the portal UI |
| Some other built-in role's assignment fails with HTTP 400 | Not this retirement — only these two specific roles are blocked | Re-confirm exact role display name in the failing request |

---

## Validation Steps

1. **Confirm exact role identity.** Only `Partner Tier1 Support` and `Partner Tier2 Support` are affected — verify the failing request targets one of these exact display names, not a similarly-named role.
   ```powershell
   Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
   Get-MgDirectoryRole -Filter "DisplayName eq 'Partner Tier1 Support'"
   Get-MgDirectoryRole -Filter "DisplayName eq 'Partner Tier2 Support'"
   ```
   - Good: the role objects resolve (they still exist post-retirement).
   - If either returns nothing, the role may not yet be *activated* in this tenant's directory (built-in roles activate on first reference) — this is a separate, unrelated state from the assignment block.

2. **Confirm current assignment state** before assuming an assignment attempt is "new":
   ```powershell
   Get-MgDirectoryRoleMember -DirectoryRoleId <roleId>
   ```
   - If the target principal is already a member, the failing operation may be a modification being misinterpreted as a new assignment — reproduce the exact underlying API call.

3. **Confirm the rollout date.** Global window: 2026-08-03 through ~2026-08-24. A failure before Aug 3 is not this retirement; after Aug 24, treat the block as universally in effect.

4. **Reproduce and capture the exact error.** Expected signature is HTTP 400 with `error.code = "Request_BadRequest"`. Anything returning 403 (permissions) or 404 (role/object not found) is a different problem and should not be attributed to this retirement.

5. **For GDAP-specific reports, check Partner Center directly** — GDAP Access Assignment role mapping is a Partner Center construct layered on top of the same underlying Entra role-assignment mechanism, and surfaces the same HTTP 400 root cause through its own UI error presentation.

---

## Troubleshooting Steps (by phase)

### Phase 1: Role and Date Confirmation
Establish that the exact role name matches one of the two affected roles, and that the attempt date falls within or after the rollout window. This phase alone resolves the majority of misattributed tickets.

### Phase 2: Assignment-State Confirmation
Distinguish a genuinely new assignment attempt (blocked, expected) from a modification of an existing assignment (should not be blocked) or a removal (should not be blocked) — the retirement affects creation only.

### Phase 3: Surface Identification
Determine which surface generated the failure — direct Graph/PowerShell call, Entra admin center deep link, or Partner Center GDAP Access Assignment — since the remediation path (code change vs. Partner Center template edit) differs by surface even though the root cause is identical.

### Phase 4: Replacement Role Selection
Identify the actual permission need behind the original assignment (see the replacement-role table above) rather than defaulting reflexively to the broadest available option, and assign the appropriately scoped replacement.

### Phase 5: Automation/Template Remediation
For recurring provisioning automation or saved GDAP templates, update the source (script or Partner Center template) rather than only fixing the immediate one-off failure, to prevent repeat tickets from the same stale reference.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Audit and remediate an MSP's full onboarding automation and template library</summary>

**Use when:** An MSP wants to proactively sweep all customer-onboarding automation and Partner Center templates for references to the retiring roles, rather than discovering the gap reactively during a live customer onboarding.

1. Inventory every script, ARM/Bicep template, Logic App, Power Automate flow, or CI/CD pipeline step that performs Entra role assignment as part of tenant/customer onboarding.
2. Search source for the role display names (`Partner Tier1 Support`, `Partner Tier2 Support`) and, where roleTemplateId is used directly instead of display name, resolve and check against the current tenant's role objects (`Get-MgDirectoryRole`).
3. In Partner Center, review every saved GDAP Access Assignment template for either role in its role list.
4. For each match, determine the actual permission intent (consult the person/team who built the automation if intent isn't obvious from context) and select the narrowest appropriate replacement from the table in How It Works above.
5. Update source and templates; add an automated test or dry-run step (where the tooling supports it) that would catch a similar future role retirement before it reaches production onboarding.
6. Document the mapping decision (old role → new role, and why) for future reference — this becomes useful context if a similar retirement affects a different role later.

**Rollback:** N/A — this is an audit-and-remediation sweep, not a reversible configuration change; individual automation edits remain reversible via normal source control.

</details>

<details><summary>Playbook 2 — Handling a live customer-onboarding failure discovered mid-process</summary>

**Use when:** A new-customer GDAP relationship or tenant provisioning step is actively failing right now because it references a retired role, and the immediate priority is unblocking that specific onboarding.

1. Identify the exact failing step and confirm the HTTP 400/`Request_BadRequest` signature against one of the two retired roles.
2. Select an immediate, appropriately-scoped replacement role from the table above based on what that onboarding step was actually trying to grant (don't over-provision under time pressure — Helpdesk Administrator or a narrower role is often sufficient even when User Administrator would "just work").
3. Manually complete the assignment with the replacement role to unblock the customer.
4. Flag the underlying automation/template for the Playbook 1 sweep so the same manual intervention isn't needed for the next customer.

**Rollback:** If the replacement role proves too broad or too narrow after review, adjust the assignment — this is a normal role-assignment change, fully reversible.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Partner Tier1/Tier2 Support role state for an escalation or
    pre-remediation audit, ahead of the 2026-08-03/2026-08-24 retirement window.
#>

Write-Host "=== Current Partner Tier1/Tier2 Support role membership ===" -ForegroundColor Cyan
foreach ($roleName in @("Partner Tier1 Support", "Partner Tier2 Support")) {
    $role = Get-MgDirectoryRole -Filter "DisplayName eq '$roleName'"
    if ($role) {
        Write-Host "`n-- $roleName (Id: $($role.Id)) --" -ForegroundColor Yellow
        Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id |
            Select-Object Id, @{N='Type';E={$_.AdditionalProperties['@odata.type']}} |
            Format-Table -AutoSize
    } else {
        Write-Host "`n-- $roleName: not yet activated in this tenant's directory --" -ForegroundColor DarkGray
    }
}

Write-Host "`n=== Reminder ===" -ForegroundColor Cyan
Write-Host "Existing assignments above continue to function after the 2026-08-03 rollout begins." -ForegroundColor DarkGray
Write-Host "Only NEW assignment attempts against these two roles are blocked (HTTP 400)." -ForegroundColor DarkGray
Write-Host "Cross-check Partner Center GDAP Access Assignment templates separately -" -ForegroundColor DarkGray
Write-Host "that surface is not queryable via Graph/PowerShell." -ForegroundColor DarkGray
```

---

## Command Cheat Sheet

```powershell
# Resolve role objects (both are portal-hidden - Graph/PowerShell required)
Get-MgDirectoryRole -Filter "DisplayName eq 'Partner Tier1 Support'"
Get-MgDirectoryRole -Filter "DisplayName eq 'Partner Tier2 Support'"

# Check current membership
Get-MgDirectoryRoleMember -DirectoryRoleId <roleId>

# Attempt a NEW assignment (will fail with HTTP 400 on/after 2026-08-03)
New-MgDirectoryRoleMemberByRef -DirectoryRoleId <roleId> -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/<principalObjectId>"
}

# Remove an existing assignment (continues to work, unaffected by the retirement)
Remove-MgDirectoryRoleMemberByRef -DirectoryRoleId <roleId> -DirectoryObjectId <principalObjectId>

# Recommended replacement role assignment (User Administrator example)
$replacement = Get-MgDirectoryRole -Filter "DisplayName eq 'User Administrator'"
New-MgDirectoryRoleMemberByRef -DirectoryRoleId $replacement.Id -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/<principalObjectId>"
}
```

```
# Partner Center (GDAP Access Assignment template check - not Graph-queryable)
partner.microsoft.com → Customers → <client> → Admin relationships → GDAP
    → relationship → Access Assignment → review/edit role list

# Tenant Message Center
admin.cloud.microsoft or security.microsoft.com → Message Center → search "MC1409305"
```

---

## 🎓 Learning Pointers

- **This is a new-assignment block, not a de-provisioning event.** No existing access is removed, no forced expiry occurs, and role removal continues to work exactly as before — the entire operational impact is limited to future assignment attempts. [Microsoft Entra built-in roles reference](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference)

- **Both roles have always been portal-invisible ("Roles not shown in the portal").** This is unrelated pre-existing behavior that frequently gets conflated with the retirement in ticket language — "I can't find this role" and "I can't assign this role" are different problems with different causes and need to be disambiguated early.

- **HTTP 400, not 403 or 404, is the diagnostic tell.** A 403 implicates the caller's own permissions; a 404 would (incorrectly) suggest the role object itself no longer exists. The 400/`Request_BadRequest` response correctly signals a disallowed operation against an object that still exists — matching this exact status code is the fastest way to confirm or rule out this specific retirement.

- **No single built-in role is a 1:1 replacement.** Microsoft names five candidate built-in roles plus a custom-role option rather than one canonical successor — because the retired roles' actual usage varied by partner, picking the right replacement requires understanding what the original assignment was actually granting, not defaulting reflexively to the broadest option (User Administrator).

- **The CSP/GDAP angle is the highest-value thing to proactively audit.** Because these roles are documented as used specifically in CSP/GDAP delegated access scenarios, an MSP's own repeatable customer-onboarding tooling — scripts and saved Partner Center Access Assignment templates alike — is a more likely place to find a stale reference than any single interactive admin action, and is exactly the kind of gap that stays invisible until the next new-customer onboarding run.

- **This is a comparatively low-profile retirement.** Unlike higher-visibility Entra changes of the same period (MDTI standalone retirement, custom branding CSS retirement), coverage of MC1409305 outside Microsoft's own Message Center is sparse as of this writing — treat Microsoft's Message Center post and built-in-roles reference page as the primary sources, and verify directly against a live tenant rather than assuming secondary/community coverage will fill in gaps.
