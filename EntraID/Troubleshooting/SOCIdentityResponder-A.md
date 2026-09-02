# Entra SOC Identity Responder Role — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **SOC Identity Responder** (documented by Microsoft as "Entra SOC Identity Responder"), a built-in Microsoft Entra ID role introduced roughly June–July 2026 that grants SOC analysts a narrow set of identity-containment actions — disable/enable a user account, revoke all active sessions (invalidate refresh tokens), and reset a password — **scoped exclusively to non-privileged (non-admin) target users**, without requiring the analyst to hold any broader Entra administrative role.

Primary confirmation source: Microsoft's own [Privileged roles and permissions in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/privileged-roles-permissions) reference (`ms.date` 2026-06-05, last updated 2026-07-20), which names the role twice — in both the "who can reset passwords" and "who can perform sensitive actions" tables — with the identical restriction language applied to the pre-existing **Security Operator** role: *"Security Operator and Entra SOC Identity Responder are limited to non-administrative user accounts and can't perform actions on privileged accounts."*

A secondary, community-sourced account ([Topedia Blog, 19 July 2026](https://blog-en.topedia.com/2026/07/new-admin-role-in-microsoft-entra-entra-soc-identity-responder/)) adds detail not yet found in Microsoft's own published documentation: a specific role template ID (`58f930cc-fcf4-4152-852c-1d7dbf502139`), a screenshot of four confirmed `allowedResourceActions`, and the claim that the role supports Administrative Unit scoping and is assignable through the Microsoft Defender portal's unified RBAC (URBAC) experience. **This runbook treats the Microsoft Learn material as confirmed fact and the Topedia-sourced detail as a working hypothesis to verify live against your own tenant** — consistent with this repo's standing practice for recently-shipped features where Microsoft's own documentation lags the actual rollout (see `SecurityAdminRoleExpansion-A.md`, `MemberOfRetirement-A.md` for the same pattern).

Assumes:
- A cloud-only or hybrid Entra ID tenant where the SOC Identity Responder role template has propagated (Microsoft's community-reported guidance notes newly published roles "may take some time to become fully active").
- Reader has `RoleManagement.Read.Directory` and `Directory.Read.All` Graph scopes at minimum for diagnosis; role-assignment remediation requires `RoleManagement.ReadWrite.Directory` or equivalent (Privileged Role Administrator/Global Administrator), or Security Administrator if managing the assignment through Defender unified RBAC instead.

Out of scope:
- The **Security Administrator** role's separate September 2026 identity-response expansion — a different, broader, pre-existing role gaining the same four action verbs through a different Microsoft change announcement. See `Troubleshooting/SecurityAdminRoleExpansion-B.md`/`-A.md`. The two are easy to conflate since they produce structurally identical audit-log entries.
- General **Security Operator** day-2 usage (alert triage, investigation, read access to Defender data) that does not involve identity-containment actions — Security Operator predates this role and is not itself covered here, though its relationship to SOC Identity Responder is discussed under How It Works.
- Microsoft Defender unified RBAC activation/configuration mechanics in general — this runbook covers SOC Identity Responder as an Entra directory role and its optional Defender-portal assignment surface, not the full URBAC feature (custom role creation across Defender for Endpoint/Identity/Office 365/Sentinel, etc.).
- PIM activation mechanics in general — see `Troubleshooting/PIM-B.md`/`-A.md`.

---
## How It Works

SOC Identity Responder is, structurally, an ordinary Microsoft Entra built-in directory role — the same object type (`roleDefinition`, with an `allowedResourceActions` list under `rolePermissions`) as Security Administrator, Authentication Administrator, or any other built-in role. It appears in Microsoft's own `privileged-roles-permissions` reference alongside those roles in tables that assume a standard Entra role-assignment model (Active vs. PIM-eligible, tenant-scoped vs. Administrative-Unit-scoped). This matters operationally: **it is not a Defender-portal-only construct** — it can be assigned and managed through the classic Entra admin center Roles blade exactly like Security Administrator, even though Microsoft's own guidance and community coverage both emphasize the Defender portal as the intended path for SOC analysts specifically.

**Why a new role instead of extending Security Operator?** Microsoft's own June 2026 announcement (referenced in the Topedia coverage) originally described *extending the Security Operator role* with containment capabilities. What ultimately shipped, per the confirmed Microsoft Learn documentation, is a **separate** role that "includes most of the previously mentioned permissions." The practical effect is a cleaner least-privilege boundary than a single expanded role would have provided: Security Operator continues to mean "can read/investigate Defender data" (a broad grant many analysts reasonably hold), while SOC Identity Responder means "can additionally take irreversible-in-the-moment containment action against ordinary user accounts" (a narrower grant an organization can restrict to a smaller on-call/tier-2 population). Treat this as intentional role decomposition, not as Microsoft abandoning the original plan.

**Confirmed permission set.** Per the community-sourced screenshot (not yet independently verified against Microsoft's own permissions-reference page, which was not fully enumerable at the time of writing), the role grants exactly four actions:

```
microsoft.directory/users/disable
microsoft.directory/users/enable
microsoft.directory/users/invalidateAllRefreshTokens
microsoft.directory/users/password/update
```

These are the **same action strings** already used by Authentication Administrator and User Administrator for the same functional capabilities, and the same four strings Security Administrator gained in its own, separate September 2026 expansion. This is a recurring pattern in Entra's built-in role model: a given functional capability (disable a user, revoke sessions, etc.) is expressed as one fixed action string, and multiple roles can independently carry it. **Do not assume permission uniqueness implies role uniqueness** — cross-referencing which role actually authorized a given action requires checking assignee lists, not just the action name in an audit log entry.

Microsoft's broader change-announcement language (as relayed by the Topedia coverage, quoting Microsoft) also references two additional capabilities — **"mark users compromised"** and **"delete individual authentication methods"** — as part of the same SOC-containment initiative. Neither appears in the confirmed four-action list. Treat these as **directionally likely future or tenant-variable additions, not confirmed-present capabilities** — the accompanying script checks for them explicitly and reports their presence per-tenant rather than assuming either state.

**Two independent gates then determine whether a given assignee can act on a given target:**

**Gate 1 — Assignment state and surface.** A principal must hold an Active assignment, or an activated PIM-Eligible assignment, for the actions to apply — identical to any other built-in role. The assignment can originate from either the classic Entra Roles blade or the Defender portal's Permissions → Microsoft Defender XDR → Roles page; both ultimately produce the same underlying directory-role assignment. The Defender-portal path additionally scopes the assignee's *visible UI surface* to Defender-portal experiences only (per Microsoft's own guidance: "URBAC being recommended as it gives access to the Defender portal only") — this is a UX/least-exposure benefit, not a different permission set.

**Gate 2 — Target protection.** Microsoft Entra's sensitive-actions/privileged-target protection model — the same one that already governs Authentication Administrator, User Administrator, and Helpdesk Administrator — explicitly extends to SOC Identity Responder. Per Microsoft's own documentation, both Security Operator and Entra SOC Identity Responder "are limited to non-administrative user accounts and can't perform actions on privileged accounts," with (unlike Privileged Authentication Administrator or Global Administrator) **no documented exception path** for this role to reach a protected target under any circumstance. This is a hard architectural boundary, not a policy default that can be relaxed through configuration.

**Optional Administrative Unit scoping.** Per the community-sourced coverage, the role supports assignment at the scope of an Administrative Unit, restricting which users the containment actions can reach — the standard `directoryScopeId = /administrativeUnits/{id}` mechanism already used by AU-scoped assignments of other roles (see `Troubleshooting/AdministrativeUnits-A.md` for the general mechanism). This is the primary blast-radius control available for this role short of building a custom role.

---
## Dependency Stack

```
Microsoft Entra ID (tenant)
  └── Built-in role definitions (Microsoft-managed, NOT tenant-editable)
        └── SOC Identity Responder / "Entra SOC Identity Responder"
              (introduced ~June-July 2026; confirmed in Microsoft's own
               privileged-roles-permissions reference; community-reported
               templateId 58f930cc-fcf4-4152-852c-1d7dbf502139 NOT
               independently confirmed — resolve by display name, not ID)
              ├── Confirmed action set:
              │     users/disable, users/enable,
              │     users/invalidateAllRefreshTokens, users/password/update
              ├── Unconfirmed/hypothesized additional actions (per Microsoft's
              │     own change-announcement language, not yet seen in the
              │     base role definition):
              │     "mark user compromised", "delete individual auth method"
              ├── Sibling role sharing the same non-privileged-target
              │     restriction language: Security Operator (read/investigate,
              │     pre-existing, NOT itself a containment role)
              ├── Structurally distinct but functionally overlapping role:
              │     Security Administrator (Sept 2026 expansion — same four
              │     action strings, different role, different announcement,
              │     see SecurityAdminRoleExpansion-A.md)
              └── Assignment mechanism
                    ├── Classic Entra admin center → Roles & admins
                    │     (Active / PIM-Eligible, same model as any built-in role)
                    └── Microsoft Defender portal → Permissions →
                          Microsoft Defender XDR → Roles (unified RBAC/URBAC)
                          (requires assignor to hold at least Security
                           Administrator in Entra ID; scopes assignee's
                           visible UI to Defender portal only)
                    └── Optional Administrative Unit scope
                          (directoryScopeId = /administrativeUnits/{id})
                    └── Target user evaluated against sensitive-actions /
                          privileged-target protection model
                          ├── Non-privileged target → action succeeds
                          └── Any directory-role-holding target → BLOCKED,
                                no documented exception for this role
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Role/template doesn't resolve via `Get-MgDirectoryRole` or `Get-MgDirectoryRoleTemplate` | Recently published role hasn't propagated to this tenant yet, or has never been activated (no one has ever been assigned) | Check both display-name variants; template-only presence means "never assigned," not "unavailable" |
| A SOC analyst's containment action fails against a specific user | Target holds a directory role (privileged-target protection) | Check target's directory role memberships |
| Analyst assigned via the Defender portal can't find the equivalent option in the classic Entra Roles blade (or vice versa) | Both surfaces manage the same underlying role — a UI/navigation gap, not a permissions gap | Confirm the assignment exists via Graph regardless of which portal was used to create it |
| Audit log shows a disable/reset/revoke-session action but it's unclear which role authorized it | Security Administrator's Sept 2026 expansion and SOC Identity Responder use identical action strings and produce identical-looking audit entries | Cross-reference `InitiatedBy` against both role's assignee lists, not just the action name |
| A stakeholder expects Security Operator itself to now have containment power (based on Microsoft's original June 2026 announcement language) | Microsoft ultimately shipped the containment actions as a separate role instead of expanding Security Operator directly | Clarify against the confirmed Microsoft Learn documentation, not the earlier announcement's phrasing |
| Script or automation checks for "mark user compromised" or "delete auth method" actions and finds them absent | These are referenced in Microsoft's broader change-announcement language but not confirmed present in the base role definition as of this writing | Treat as tenant-variable/future capability; verify live rather than assuming presence or absence |

---
## Validation Steps

**1. Resolve the role and confirm assignment**
```powershell
Connect-MgGraph -Scopes "RoleManagement.Read.Directory" -NoWelcome
$role = $null
foreach ($n in @("SOC Identity Responder","Entra SOC Identity Responder")) {
    $role = Get-MgDirectoryRole -Filter "displayName eq '$n'" -ErrorAction SilentlyContinue
    if ($role) { break }
}
if ($role) {
    Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id |
        Select-Object Id, @{N='Name';E={$_.AdditionalProperties.displayName}}
}
```
Good: a short, deliberate list matching a documented SOC on-call/tier-2 team. Bad: the role doesn't resolve at all (see Symptom→Cause row 1) or the assignee list includes principals with no clear incident-response function.

**2. Confirm the live role definition's confirmed and hypothesized actions**
```powershell
if ($role) {
    $roleDef = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/$($role.RoleTemplateId)"
    $allActions = $roleDef.rolePermissions.allowedResourceActions
    $allActions | Where-Object { $_ -match "users/(disable|enable|invalidateAllRefreshTokens|password)" }
}
```
Good: returns the four confirmed actions. Informational, not a bug either way: whether or not additional actions beyond the four confirmed ones are present — Microsoft has not published a fixed, versioned action list for this specific role as of this writing.

**3. Confirm target-user protection status before assuming an action will or won't succeed**
```powershell
Get-MgUserMemberOf -UserId "<targetUserId>" |
    Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.directoryRole' } |
    Select-Object @{N='Role';E={$_.AdditionalProperties.displayName}}
```
Good: empty result for an ordinary end user. Bad/expected-to-fail: any role membership — this role has no documented exception path to reach a protected target, unlike Privileged Authentication Administrator or Global Administrator.

**4. Confirm assignment surface and scope**
```powershell
if ($role) {
    Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '$($role.RoleTemplateId)'" |
        Select-Object PrincipalId, DirectoryScopeId
}
```
Good: `DirectoryScopeId = /` for a tenant-wide grant, or `/administrativeUnits/{id}` for an AU-scoped one — either is valid depending on the organization's containment-scope design. Confirm this matches the intended blast radius.

**5. Disambiguate against overlapping roles**
```powershell
foreach ($n in @("Security Operator","Security Administrator")) {
    $r = Get-MgDirectoryRole -Filter "displayName eq '$n'" -ErrorAction SilentlyContinue
    if ($r) {
        Write-Host "-- $n --"
        Get-MgDirectoryRoleMember -DirectoryRoleId $r.Id | Select-Object Id, @{N='Name';E={$_.AdditionalProperties.displayName}}
    }
}
```
Cross-reference against the SOC Identity Responder assignee list from Step 1 — overlap here is a hygiene signal (redundant containment power via multiple roles), the same pattern already documented for Security Administrator's own expansion.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the role and assignment exist**
Rule out propagation timing and display-name variance (Validation Steps 1–2) before investigating anything else. A role that resolves under one display-name variant but not the other in scripted checks is a common false alarm, not a real gap.

**Phase 2 — Confirm target protection status**
For any report of a containment action failing against a specific user, check whether that user is privileged (Validation Step 3) before treating it as a defect. This is expected, documented, hard-boundary protection with no override for this role.

**Phase 3 — Confirm assignment surface and scope match intent**
Distinguish an intentionally AU-scoped assignment from an accidental tenant-wide one (Validation Step 4). A containment role reaching more of the user population than the SOC team intended is a governance gap worth catching proactively, not just reactively.

**Phase 4 — Disambiguate against Security Administrator and Security Operator**
Whenever a ticket or audit-log review can't immediately tell which role authorized an action, run the full three-role cross-reference (Validation Step 5 plus the Security Administrator assignee list). This repo now has three distinct roles capable of producing the identical `Disable account`/`Reset user password`/session-revocation audit entries — resolving which one requires assignee-list correlation, not action-name inspection alone.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standing Up SOC Identity Responder for the First Time</summary>

1. Decide assignment surface: Defender portal (Permissions → Microsoft Defender XDR → Roles) for analysts who should only ever operate from the Defender portal, or the classic Entra Roles blade for analysts who already hold other Entra-admin-adjacent roles and don't need the narrower UI scope.
2. Decide scope: tenant-wide vs. Administrative-Unit-scoped, based on whether the SOC team's containment mandate covers the whole org or a defined subset (e.g., a specific business unit, or excluding a segment handled by a different team).
3. Default new assignments to **PIM-eligible**, not standing Active, unless the team's incident-response SLA cannot tolerate activation latency — this mirrors the same recommendation already made for Security Administrator's own expansion.
4. Document the decision (surface, scope, PIM posture) for the next access review — this role is new enough that undocumented tribal-knowledge assignments will be hard to audit six months from now.

**Rollback:** Remove the role assignment via either surface; no destructive tenant-side state is created by assignment alone.

</details>

<details><summary>Playbook 2 — Choosing Between Security Operator, SOC Identity Responder, and Security Administrator for a Given Persona</summary>

| Persona need | Role |
|---|---|
| Read/investigate Defender alerts and incidents only, no containment action | **Security Operator** |
| Take containment action (disable/reset/revoke) against non-privileged users, from either the Defender portal or Entra admin center, with optional AU scoping | **SOC Identity Responder** |
| Broader Entra security-configuration management (Conditional Access, Identity Protection policy, etc.) that happens to also now include the same four containment actions as an incidental September 2026 platform change | **Security Administrator** — but do not assign this role *specifically* to grant containment power; it carries a much larger permission surface than SOC Identity Responder for that purpose alone |

Assigning Security Administrator to a SOC analyst purely to obtain containment actions is over-provisioning — SOC Identity Responder is the narrower, purpose-built role for exactly that need and should be preferred unless the analyst genuinely also needs Security Administrator's broader configuration-management permissions.

**Rollback:** N/A — decision framework.

</details>

<details><summary>Playbook 3 — Post-Incident Review of Containment Actions</summary>

1. Pull the audit log for the four confirmed action names, filtered to the incident window (Evidence Pack script).
2. For each hit, cross-reference `InitiatedBy` against SOC Identity Responder, Security Administrator, and Security Operator assignee lists to determine which role authorized it.
3. Confirm every action taken was scoped to a non-privileged target as expected (any hit against a privileged target indicates the action necessarily came through a different role, since SOC Identity Responder has no exception path).
4. Fold findings into the standard identity-incident review process (`Troubleshooting/IdentityProtection-B.md`) if any action appears illegitimate.

**Rollback:** N/A — investigative process.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects SOC Identity Responder role posture for escalation or audit review.
#>
Connect-MgGraph -Scopes "RoleManagement.Read.Directory","AuditLog.Read.All" -NoWelcome

$role = $null
foreach ($n in @("SOC Identity Responder","Entra SOC Identity Responder")) {
    $role = Get-MgDirectoryRole -Filter "displayName eq '$n'" -ErrorAction SilentlyContinue
    if ($role) { break }
}

$assignees = if ($role) { Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id } else { @() }

$confirmedActions = @(
    "microsoft.directory/users/disable",
    "microsoft.directory/users/enable",
    "microsoft.directory/users/invalidateAllRefreshTokens",
    "microsoft.directory/users/password/update"
)
$rolloutStatus = @()
if ($role) {
    $roleDef = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/$($role.RoleTemplateId)"
    $rolloutStatus = $confirmedActions | ForEach-Object {
        [pscustomobject]@{ Action = $_; Present = ($roleDef.rolePermissions.allowedResourceActions -contains $_) }
    }
}

$recentActions = Get-MgAuditLogDirectoryAudit -Filter "activityDisplayName eq 'Disable account' or activityDisplayName eq 'Reset user password' or activityDisplayName eq 'Update user'" -Top 100

[pscustomobject]@{
    TenantId            = (Get-MgContext).TenantId
    RoleFound           = [bool]$role
    AssigneeCount       = $assignees.Count
    ActionRolloutStatus = $rolloutStatus
    RecentCandidateActions = $recentActions.Count
} | ConvertTo-Json -Depth 6
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-MgDirectoryRole -Filter "displayName eq 'SOC Identity Responder'"` | Resolve the role object (try both display-name variants) |
| `Get-MgDirectoryRoleTemplate` | Check template presence when the role has never been assigned/activated |
| `Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id` | List current assignees |
| `Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '...'"` | List assignments with their `DirectoryScopeId` (tenant-wide vs. AU-scoped) |
| `Invoke-MgGraphRequest -Method GET -Uri ".../roleDefinitions/{id}"` | Read the live `allowedResourceActions` for this role in this tenant |
| `Get-MgUserMemberOf -UserId <id>` (filtered to `directoryRole`) | Check whether a target user is privileged/protected |
| `Get-MgAuditLogDirectoryAudit -Filter "activityDisplayName eq '...'"` | Pull recent disable/enable/reset/session-revoke events for cross-role correlation |
| `New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest` | Convert a standing assignment to PIM-eligible |
| `New-MgRoleManagementDirectoryRoleAssignment -BodyParameter @{ DirectoryScopeId = "/administrativeUnits/{id}" }` | Create an AU-scoped assignment |

---
## 🎓 Learning Pointers

- **This is a distinct role from Security Administrator's own containment-action expansion**, even though both grant the identical four action verbs — they were introduced by separate Microsoft announcements and require separate assignee-list checks to disambiguate in an audit log. Reference: [Privileged roles and permissions in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/privileged-roles-permissions)
- **Microsoft's original plan (extend Security Operator directly) and what actually shipped (a new, separate role) diverge.** When a stakeholder cites the June 2026 announcement, verify against the confirmed Microsoft Learn documentation rather than the earlier announcement's framing.
- **"Can't perform actions on privileged accounts" has no documented exception for this role**, unlike the escalation paths available to Privileged Authentication Administrator or Global Administrator. This is a hard architectural boundary worth stating plainly to any stakeholder worried about privilege-escalation risk from this new role.
- **Community-sourced detail (template ID, exact confirmed action list, AU-scoping support) should be verified live against your own tenant**, not assumed from a single third-party source — Microsoft's own documentation had not published the full detail as of this writing. Reference (community source): [New admin role in Microsoft Entra: Entra SOC Identity Responder — Topedia Blog](https://blog-en.topedia.com/2026/07/new-admin-role-in-microsoft-entra-entra-soc-identity-responder/)
- **Prefer SOC Identity Responder over Security Administrator when the only need is containment action.** Assigning the broader Security Administrator role purely to obtain the same four actions is unnecessary over-provisioning now that a purpose-built, narrower role exists. Reference: [Microsoft Defender unified role-based access control (RBAC)](https://learn.microsoft.com/en-us/defender-xdr/manage-rbac)
- **Two assignment surfaces, one underlying role.** Whether an analyst was assigned through the classic Entra Roles blade or the Defender portal's URBAC experience, the Graph-level role assignment is what actually governs their permissions — always verify via Graph when reconciling a "why can/can't this person do X" question, regardless of which portal was used to configure it.
