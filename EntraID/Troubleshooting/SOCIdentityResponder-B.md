# Entra SOC Identity Responder Role — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## ⚠ A note before you start — three roles now do adjacent things, confirm which one a ticket actually concerns

Microsoft introduced a new built-in Entra role, **SOC Identity Responder** (also referred to as "Entra SOC Identity Responder" in Microsoft's own documentation), around June–July 2026. It gives SOC analysts a narrow, dedicated set of identity-containment actions — disable/enable a user account, revoke active sessions, reset a password — **scoped to non-privileged (non-admin) targets only**, without requiring any broader Entra admin role. It is confirmed in Microsoft's official [Privileged roles and permissions in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/privileged-roles-permissions) reference, which explicitly names it (alongside **Security Operator**) as restricted from acting on privileged accounts.

Before troubleshooting, confirm which of **three** related-but-distinct mechanisms a ticket actually concerns — they are easy to conflate:

| If the ticket concerns... | Go to... |
|---|---|
| A SOC analyst using **SOC Identity Responder** to disable/reset/revoke a non-admin user, assigned via the Entra Roles blade or the Defender portal | **This file** |
| The built-in **Security Administrator** role gaining the same four containment actions as part of Microsoft's September 2026 rollout (a different, broader, pre-existing role) | `Troubleshooting/SecurityAdminRoleExpansion-B.md` |
| A SOC analyst's **read/investigate** access to Defender alerts and incidents (no containment action involved) | The pre-existing **Security Operator** role — not covered by either of the above |

---
## Triage

```powershell
# 1. Connect with the scopes needed for every check below
Connect-MgGraph -Scopes "RoleManagement.Read.Directory","Directory.Read.All" -NoWelcome
(Get-MgContext).TenantId

# 2. Find the SOC Identity Responder role — Microsoft's docs use two labels ("SOC Identity Responder"
#    and "Entra SOC Identity Responder"); check both display-name variants and fall back to the
#    template list if the role has never been activated in this tenant.
$roleNames = @("SOC Identity Responder", "Entra SOC Identity Responder")
$role = $null
foreach ($n in $roleNames) {
    $role = Get-MgDirectoryRole -Filter "displayName eq '$n'" -ErrorAction SilentlyContinue
    if ($role) { break }
}
if (-not $role) {
    Write-Host "Role not active in this tenant yet — checking role templates..." -ForegroundColor Yellow
    $template = Get-MgDirectoryRoleTemplate | Where-Object { $roleNames -contains $_.DisplayName }
    if ($template) {
        Write-Host "Template found ($($template.Id)) but role has never been assigned/activated — see Fix 1." -ForegroundColor Yellow
    } else {
        Write-Host "No matching role template found either — this tenant may not have the role surfaced yet (recently published roles can take time to propagate). See Fix 1." -ForegroundColor Yellow
    }
} else {
    Write-Host "Role found: $($role.DisplayName) ($($role.Id))" -ForegroundColor Green
}

# 3. List current active assignees (only if the role is active)
if ($role) {
    Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id |
        Select-Object Id, @{N='Type';E={$_.AdditionalProperties.'@odata.type' -replace '#microsoft.graph.',''}}, @{N='Name';E={$_.AdditionalProperties.displayName}}
}

# 4. Check the live role definition for the four confirmed containment actions
if ($role) {
    $roleDef = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/$($role.RoleTemplateId)"
    $confirmedActions = @(
        "microsoft.directory/users/disable",
        "microsoft.directory/users/enable",
        "microsoft.directory/users/invalidateAllRefreshTokens",
        "microsoft.directory/users/password/update"
    )
    $confirmedActions | ForEach-Object {
        [pscustomobject]@{ Action = $_; PresentInThisTenant = ($roleDef.rolePermissions.allowedResourceActions -contains $_) }
    }
}

# 5. Cross-check for overlapping containment/identity-response power (redundant-access signal)
foreach ($overlapRole in @("Security Operator","Security Administrator","Authentication Administrator","User Administrator")) {
    $rid = (Get-MgDirectoryRole -Filter "displayName eq '$overlapRole'").Id
    if ($rid) {
        Write-Host "`n-- $overlapRole members --" -ForegroundColor Cyan
        Get-MgDirectoryRoleMember -DirectoryRoleId $rid | Select-Object Id, @{N='Name';E={$_.AdditionalProperties.displayName}}
    }
}
```

| Result | Action |
|--------|--------|
| Role/template not found in this tenant at all | → [Fix 1 — Confirm Tenant Readiness and Assignment Surface](#fix-1--confirm-tenant-readiness-and-assignment-surface) |
| Assignee reports the containment action fails against a specific target | → [Fix 2 — Confirm Target Is Non-Privileged](#fix-2--confirm-target-is-non-privileged) |
| SOC Identity Responder is assigned tenant-wide when only a subset of users/departments need coverage | → [Fix 3 — Apply Administrative Unit Scoping](#fix-3--apply-administrative-unit-scoping) |
| Standing (Active, non-PIM) assignments exist for a containment-capable role | → [Fix 4 — Convert to PIM-Eligible](#fix-4--convert-to-pim-eligible) |
| Ticket is ambiguous about which of the three mechanisms (this role / Security Administrator expansion / Security Operator) actually granted the observed access | → [Fix 5 — Disambiguate the Source Role](#fix-5--disambiguate-the-source-role) |
| All checks pass, behavior still doesn't match documentation | → Escalate — capture the Evidence Pack below and open a support case |

---
## Dependency Cascade

<details><summary>What determines whether a SOC Identity Responder holder can act on a given user</summary>

```
Microsoft Entra ID (built-in directory role)
  └── SOC Identity Responder / Entra SOC Identity Responder
        (introduced ~June-July 2026; confirmed in Microsoft's
         privileged-roles-permissions reference alongside Security Operator;
         a community-reported templateId — 58f930cc-fcf4-4152-852c-1d7dbf502139 —
         has NOT been independently confirmed against Microsoft's own docs;
         this runbook's script resolves the role by display name, not by
         trusting that ID blindly)
        └── Confirmed action set (per public role-permission screenshot,
              matches the same action strings Security Administrator/
              Authentication Administrator already use):
                microsoft.directory/users/disable
                microsoft.directory/users/enable
                microsoft.directory/users/invalidateAllRefreshTokens
                microsoft.directory/users/password/update
              (Microsoft's own change-announcement language also references
               "mark users compromised" and "delete individual authentication
               methods" as part of the broader SOC-containment initiative —
               NOT confirmed present in the base role definition; verify live,
               do not assume)
        └── Two assignment surfaces (functionally equivalent, different UX):
              ├── Classic Entra admin center → Identity → Roles & admins
              │     (same PIM/eligible/active model as any built-in role)
              └── Microsoft Defender portal → Permissions → Microsoft
                    Defender XDR → Roles (unified RBAC / URBAC) — the
                    Microsoft-recommended path for SOC analysts, since it
                    scopes the assignee to Defender-portal access only
                    (requires the assignor to hold at least Security
                    Administrator in Entra ID to manage URBAC roles)
        └── Optional Administrative Unit scoping
              (restricts which users the role's actions can reach)
        └── Target user evaluated against
              "who can perform sensitive actions" / "who can reset
              passwords" protection model
              ├── Target is a NON-PRIVILEGED user
              │     → action succeeds (this is the whole point of the role)
              └── Target holds any directory role themselves
                    → action is BLOCKED — Microsoft's own documentation
                      states SOC Identity Responder (like Security Operator)
                      "can't perform actions on privileged accounts," with
                      no documented exception path from this role alone
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the role exists and is assigned in this tenant**
Use Triage steps 2–3. A recently published role can take time to become fully active tenant-side — absence on day one is not necessarily a misconfiguration.

**Step 2 — Confirm the confirmed action set is actually live**
Use Triage step 4. If the role resolves but none of the four actions show `PresentInThisTenant = True`, treat this as informational (propagation timing), not a bug, and re-check later.

**Step 3 — Confirm the target user isn't protected**
```powershell
Get-MgUserMemberOf -UserId "<targetUserId>" |
    Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.directoryRole' } |
    Select-Object @{N='Role';E={$_.AdditionalProperties.displayName}}
```
Expected: any result here means the target is privileged and SOC Identity Responder alone cannot act on them — this is documented, by-design behavior for both SOC Identity Responder and Security Operator.

**Step 4 — Confirm which assignment surface was used**
Ask whether the analyst was assigned through the Entra admin center Roles blade or through the Defender portal's Permissions → Microsoft Defender XDR → Roles page. Both grant the same underlying directory-role actions, but only the Defender-portal path additionally scopes the analyst's *visible surface* to the Defender portal itself — a support question about "why can't this analyst see the Entra admin center" is answered here, not by a permissions bug.

**Step 5 — Validate against audit logs after a reported containment action**
```powershell
Get-MgAuditLogDirectoryAudit -Filter "activityDisplayName eq 'Disable account' or activityDisplayName eq 'Reset user password' or activityDisplayName eq 'Update user'" -Top 25 |
    Select-Object ActivityDateTime, ActivityDisplayName, InitiatedBy, TargetResources
```
Cross-reference `InitiatedBy` against the SOC Identity Responder assignee list — and separately against Security Administrator and Security Operator assignees — to confirm which role's grant actually authorized the observed action, since all three can now produce visually identical audit entries.

---
## Common Fix Paths

<details><summary>Fix 1 — Confirm Tenant Readiness and Assignment Surface</summary>

**When:** The role/template lookup in Triage step 2 returns nothing.

1. Confirm the tenant has had time to receive the role — Microsoft's own guidance notes a newly published role "may take some time to become fully active." Re-check after a few hours/days rather than assuming a permanent gap.
2. If the role template exists but has never been assigned, it won't appear via `Get-MgDirectoryRole` (which only returns *activated* roles). Assign it once via either surface to activate it:

```powershell
# Assign via classic Entra role (requires Privileged Role Administrator / Global Administrator)
$template = Get-MgDirectoryRoleTemplate | Where-Object DisplayName -in @("SOC Identity Responder","Entra SOC Identity Responder")
New-MgDirectoryRole -BodyParameter @{ RoleTemplateId = $template.Id }
```

3. Alternatively, assign via the Defender portal: **Microsoft Defender portal → Permissions → Microsoft Defender XDR → Roles → Create custom role** (or locate the built-in equivalent if surfaced there directly), following [Create custom roles with Microsoft Defender unified RBAC](https://learn.microsoft.com/en-us/defender-xdr/create-custom-rbac-roles). This path requires the assignor to hold at least Security Administrator in Entra ID.

**Rollback:** Remove the role assignment via `Remove-MgDirectoryRoleMemberByRef` (classic) or by deleting/editing the custom role in the Defender portal.

</details>

<details><summary>Fix 2 — Confirm Target Is Non-Privileged</summary>

**When:** An assignee reports the disable/reset/revoke action fails against a specific user.

Run Diagnosis Step 3. If the target holds any directory role, this is expected, documented protection — not a bug. Escalate to a role capable of acting on protected principals (Privileged Authentication Administrator, Global Administrator) rather than troubleshooting SOC Identity Responder's permissions further.

**Rollback:** N/A — read-only diagnosis.

</details>

<details><summary>Fix 3 — Apply Administrative Unit Scoping</summary>

**When:** SOC Identity Responder is assigned tenant-wide but the organization only wants a given analyst team able to act on users in specific departments/business units.

```powershell
# Example: scope a role assignment to an Administrative Unit (requires the AU to already exist)
$au = Get-MgDirectoryAdministrativeUnit -Filter "displayName eq '<AU DisplayName>'"
New-MgRoleManagementDirectoryRoleAssignment -BodyParameter @{
    PrincipalId      = "<principalObjectId>"
    RoleDefinitionId = "<SOCIdentityResponderRoleDefinitionId>"
    DirectoryScopeId = "/administrativeUnits/$($au.Id)"
}
```

AU scoping is the primary blast-radius control this role supports — narrower than a tenant-wide assignment without requiring a custom role.

**Rollback:** Remove the scoped assignment; reassign tenant-wide if the narrower scope proves operationally unworkable.

</details>

<details><summary>Fix 4 — Convert to PIM-Eligible</summary>

**When:** SOC Identity Responder is a standing (Active) assignment for analysts who only need containment power during an active on-call rotation or incident.

```powershell
$params = @{
    Action = "adminAssign"
    Justification = "Convert standing SOC Identity Responder to eligible"
    RoleDefinitionId = "<SOCIdentityResponderRoleDefinitionId>"
    DirectoryScopeId = "/"
    PrincipalId = "<principalObjectId>"
    ScheduleInfo = @{
        StartDateTime = (Get-Date)
        Expiration = @{ Type = "afterDuration"; Duration = "P365D" }
    }
}
New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -BodyParameter $params
```

This is the same highest-leverage lever every other role-expansion topic in this repo points back to: gate containment power behind PIM activation (and, if policy requires, approval/justification/MFA) rather than leaving it always-on.

**Rollback:** Cancel the eligibility schedule request and re-add as an Active assignment if PIM friction proves operationally unworkable during live incidents (weigh this carefully — containment speed is the entire point of this role).

</details>

<details><summary>Fix 5 — Disambiguate the Source Role</summary>

**When:** A ticket describes a SOC analyst (or any user) taking a disable/reset/revoke-session action, and it isn't clear which of the three mechanisms authorized it.

Run Triage step 5's audit-log cross-reference against all three role membership lists (SOC Identity Responder, Security Administrator, Security Operator) simultaneously. The action verbs and audit-log activity names are identical across all three paths — only the `InitiatedBy` principal's role membership distinguishes which grant was actually exercised.

**Rollback:** N/A — diagnostic only.

</details>

---
## Escalation Evidence

```
=== SOC IDENTITY RESPONDER ESCALATION EVIDENCE PACK ===
Date/Time (UTC): _______________
Reported by: _______________
Tenant ID: _______________

SYMPTOM:
[ ] Role/template not found in tenant
[ ] Containment action failed against a specific target
[ ] Assignment scope question (AU scoping)
[ ] Standing assignment / PIM conversion question
[ ] Unclear which role (SOC Identity Responder / Security Administrator / Security Operator) authorized an action
[ ] Other: _______________

TRIAGE RESULTS:
Role found in tenant (Y/N): _______________
Active assignee count: _______________
Confirmed actions present in role definition (Y/N per action): _______________
Assignment surface used (Entra admin center / Defender portal): _______________
Target user privileged-role status: _______________
Overlap with Security Operator / Security Administrator / Auth Admin / User Admin: _______________

ACTIONS TAKEN:
_______________

CORRELATION ID: _______________
```

---
## 🎓 Learning Pointers

- **This is a new, dedicated role — not an expansion of an existing one.** Don't confuse SOC Identity Responder with the Security Administrator role's separate September 2026 identity-response expansion (`SecurityAdminRoleExpansion-B.md`); they grant the same four action verbs but through two structurally different roles, introduced by two different Microsoft announcements. Reference: [Privileged roles and permissions in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/privileged-roles-permissions)
- **Microsoft's original June 2026 announcement described extending Security Operator; what actually shipped was a separate role.** If a stakeholder read the June announcement and expects Security Operator itself to have gained containment power, clarify that the containment actions live on the new SOC Identity Responder role instead — worth confirming directly with the stakeholder's source before assuming a documentation error on either side.
- **"Can't perform actions on privileged accounts" is explicit and documented for this role**, using the same protection language Microsoft applies to Security Operator. Don't troubleshoot a blocked action against an admin target as a bug.
- **Two assignment surfaces exist for the same underlying role** — the classic Entra admin center Roles blade, and the Defender portal's unified RBAC (URBAC) experience. The Defender-portal path is Microsoft's recommended one for SOC analysts specifically because it scopes visible access to the Defender portal only. Reference: [Microsoft Defender unified role-based access control (RBAC)](https://learn.microsoft.com/en-us/defender-xdr/manage-rbac)
- **The community-reported role template ID (58f930cc-fcf4-4152-852c-1d7dbf502139) has not been independently confirmed against Microsoft's own documentation** as of this writing — this repo's script resolves the role live by display name rather than trusting a hardcoded ID. Reference (community source): [New admin role in Microsoft Entra: Entra SOC Identity Responder — Topedia Blog](https://blog-en.topedia.com/2026/07/new-admin-role-in-microsoft-entra-entra-soc-identity-responder/)
- **PIM conversion remains the highest-leverage single mitigation** for any newly-introduced containment-capable role, balanced against the operational cost of activation friction during a live incident — weigh this trade-off explicitly with the SOC team rather than defaulting to either extreme.
