# Microsoft Fabric — Domains (Governance Grouping) — Hotfix Runbook (Mode B: Ops)
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

**The single most important fact about Fabric domains: they are a data-mesh grouping/discovery mechanism, not an access-control mechanism.** Assigning a workspace to a domain changes nothing about who can see or open its items — workspace roles and item permissions are entirely separate and unaffected. Most "domain" tickets are actually role/contributor-permission tickets, not domain-configuration tickets.

```powershell
# Fabric REST Admin API is the only supported programmatic surface for domains —
# there is no dedicated PowerShell cmdlet/module. All calls need a Fabric admin
# (or delegated) bearer token.

# 1 — List all domains in the tenant
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET

# 2 — List workspaces assigned to a specific domain
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/domains/<domainId>/workspaces" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET

# 3 — Confirm a specific workspace's current domain assignment (via workspace listing)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces?domain=<domainId>" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET

# 4 — Portal check (no API equivalent for delegated-settings state):
# app.fabric.microsoft.com > gear icon > Admin portal > Domains > <domain> > Domain settings
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| User says "I can't see the workspace even though it's in my domain" | Expected — domain assignment never grants visibility or access; this is a workspace-role/item-permission issue, not a domain issue | Fix 1 |
| Domain contributor can't assign a workspace to a domain | They aren't a **workspace Admin** on that workspace — domain contributor status alone isn't sufficient | Fix 2 |
| Re-assigning a workspace to a different domain silently didn't move it / still shows old domain | **"Allow tenant and domain admins to override workspace assignments"** tenant setting is disabled — existing assignments block re-assignment by default | Fix 3 |
| Workspace created by a "default domain" user didn't land in the expected domain | Default domain only auto-assigns **unassigned** workspaces and **future** workspace creation — it never overrides an existing assignment | Fix 4 |
| Domain admin can't rename the domain or add another domain admin | Correct, expected behavior — domain admins can edit description/contributors/workspace-assignment/image/delegated settings only; rename, delete, and admin-list changes are **Fabric admin only** | Fix 5 |
| Subdomain has no separate admin list / can't assign its own domain admins | By design — subdomains inherit their parent domain's admins; only General settings exist at the subdomain level | Not a bug — document and close |
| Sensitivity label / certification setting set at the domain level isn't taking effect | The tenant-level setting was never delegated to the domain level in the first place — delegation is opt-in per setting | Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true for a domain assignment to work as expected</summary>

```
[Fabric admin creates the domain — only Fabric admin can create/rename/delete a
 domain or manage its admin list]
    └── [Domain admin(s) assigned — business owners; can edit description, image,
         contributors, workspace assignment, delegated settings]
            └── [Domain contributor(s) — must ALSO independently hold the workspace
                 Admin role on any workspace they assign; contributor status on the
                 domain does not grant workspace admin rights]
                    └── [Workspace assigned to domain via one of 3 methods:
                         by name | by workspace-admin snapshot | by capacity snapshot]
                            └── [Item-level metadata gets a domain attribute —
                                 enables OneLake catalog filter/discovery ONLY]

Explicitly NOT affected by any of the above (separate, independent chain):
[Workspace roles: Admin/Member/Contributor/Viewer]
    └── [Item permissions: Read/ReadAll/Write/sharing]
            └── THIS chain — not domain assignment — governs visibility and access

Re-assignment override gate (separate tenant setting, off by default):
[Tenant setting: "Allow tenant and domain admins to override workspace
 assignments (preview)"]
    └── Must be explicitly enabled before a domain/Fabric admin can move an
        already-assigned workspace to a different domain
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm this is actually a domain question, not an access question**
Ask directly: "is the problem that you can't find/filter to this workspace's content, or that you can't open/see the data inside it?" The first is a genuine domain issue; the second is a workspace-role/item-permission issue and this runbook does not apply — route to `M365/SharePoint-OneDrive/Permissions-B.md`-equivalent Fabric workspace-role troubleshooting instead.

**Step 2 — Confirm current domain assignment**
```powershell
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET
```
Expected: response includes the correct `domainId` (or none, if intentionally unassigned).
Bad: `domainId` is null when it should be set, or points at the wrong domain.

**Step 3 — If assignment is wrong or missing, confirm who's attempting to fix it and their role**
- Fabric admin: can assign/reassign any workspace to any domain via the admin portal or REST API.
- Domain admin: can assign workspaces the same way, scoped to domains they administer.
- Domain contributor: can assign **only workspaces where they hold the Workspace Admin role** — verify this first if a contributor reports being unable to assign.

**Step 4 — If reassignment appears to silently fail, check the override tenant setting**
Portal: **Admin portal → Tenant settings → Domain management → Allow tenant and domain admins to override workspace assignments (preview)**. If disabled, an already-assigned workspace cannot be moved to a new domain by any role — this is the single most common "assignment didn't stick" root cause.

**Step 5 — If the issue is a default-domain expectation mismatch**
Confirm whether the affected workspace was **already assigned** before the user was added to the default-domain list — default domain never overrides an existing assignment, it only catches unassigned workspaces and new workspace creation going forward.

---

## Common Fix Paths

<details>
<summary>Fix 1 — "I'm in the domain but can't see/open the workspace"</summary>

1. Explain clearly: domain assignment is a discovery/grouping/governance-delegation mechanism only — it has zero effect on workspace or item access, by design (see `data-access-control-model` cross-reference in `FabricAdmin-A.md` for the actual access chain).
2. Check the real access chain instead: workspace role (`Invoke-RestMethod` against `/v1/admin/workspaces/<id>/users`) and, if the workspace has capacity-backed items, OneLake security roles.
3. Grant the correct workspace role or OneLake security role — this fixes it, not touching the domain.

**Rollback:** not applicable — no domain-side change was made.
</details>

<details>
<summary>Fix 2 — Domain contributor can't assign a workspace</summary>

1. Confirm the user is a listed domain contributor for the target domain (**Admin portal → Domains → <domain> → Domain settings → Contributors**).
2. Separately confirm the same user holds the **Admin** workspace role on the specific workspace they're trying to assign — contributor status on the domain and Admin role on the workspace are two independent requirements, both must be true.
3. If only the domain-contributor requirement is met, grant them Workspace Admin on the target workspace (or have an existing workspace Admin perform the assignment instead).

**Rollback:** remove the domain-contributor grant or the workspace-Admin role if assigned in error.
</details>

<details>
<summary>Fix 3 — Reassignment to a different domain isn't taking effect</summary>

1. Portal → **Admin portal → Tenant settings → Domain management** → confirm **"Allow tenant and domain admins to override workspace assignments (preview)"** is **Enabled**.
2. If it was just enabled, retry the reassignment — no propagation delay is documented for this specific setting, but allow a few minutes as a precaution consistent with other tenant settings.
3. Retry the assignment via **Admin portal → Domains → <target domain> → Assign workspaces**, confirming the workspace shows the "already assigned to another domain" warning and that continuing overrides it.

**Rollback:** disable the override tenant setting once the intended reassignment is complete, if the org wants to prevent future accidental overrides.
</details>

<details>
<summary>Fix 4 — Default-domain auto-assignment didn't apply to an existing workspace</summary>

1. Confirm via Step 2's API call whether the workspace already had a `domainId` set **before** the user was added to the default-domain list — if so, this is expected behavior, not a bug.
2. If the workspace was genuinely unassigned and the user is correctly on the default-domain list but assignment still didn't happen, verify the *timing*: default domain scans and assigns unassigned workspaces at the point the user/group is added to the list, and applies to workspace creation going forward — it is not a continuously re-evaluated background rule.
3. For an already-assigned workspace that should move to the default domain: this requires a manual reassignment (Fix 3 process), not the default-domain mechanism, which never overrides existing assignments.

**Rollback:** remove the user/group from the default-domain list; already-assigned workspaces are unaffected by removal.
</details>

<details>
<summary>Fix 5 — Domain admin can't perform a Fabric-admin-only action</summary>

1. Confirm which action is being attempted: **rename, delete, or manage the domain-admin list** are Fabric-admin-only, by design — domain admins cannot self-escalate or modify their own peer list.
2. Domain admins CAN: edit description, image, contributors, workspace assignment, and any delegated settings (sensitivity label default, certification) for domains they administer.
3. If the action genuinely requires Fabric-admin scope, escalate to whoever holds the Fabric Administrator (or Power Platform Administrator / Global Administrator, which also grant this) Entra role.

**Rollback:** not applicable — this is a permission boundary, not a misconfiguration.
</details>

<details>
<summary>Fix 6 — Delegated setting (sensitivity label / certification) not taking effect at the domain level</summary>

1. Confirm the specific tenant-level setting is actually **eligible for delegation** and has been delegated — not every tenant setting supports domain-level override; check **Admin portal → Domains → <domain> → Domain settings → Delegated Settings** for whether the setting even appears as an override option.
2. If it appears but "Override tenant admin selection" is unchecked, the domain is silently inheriting the tenant default — check the box and configure explicitly.
3. Re-verify the domain-level default sensitivity label feature itself is enabled tenant-wide first (a prerequisite, separate from any individual domain's delegation) if the setting doesn't appear as an option at all.

**Rollback:** uncheck "Override tenant admin selection" to revert to the tenant-wide default for that domain.
</details>

---

## Escalation Evidence

```
=== FABRIC DOMAINS ESCALATION ===
Date/Time      :
Engineer       :
Ticket         :

Domain Name / Id    :
Workspace Name / Id :
Current domainId (from /v1/admin/workspaces/<id>) :
Expected domainId   :

Requester's role    : (Fabric admin / Domain admin / Domain contributor / workspace user)
Requester's Workspace role on affected workspace : (Admin/Member/Contributor/Viewer/none)

Is this an ACCESS complaint or a DISCOVERY/GROUPING complaint : 
  (domain assignment affects discovery/grouping/delegated-settings ONLY —
   confirm this isn't actually a workspace-role/item-permission ticket first)

Override tenant setting state ("Allow tenant and domain admins to override
workspace assignments (preview)") :

Steps Attempted:
1.
2.
3.

Expected behaviour :
Actual behaviour   :
```

---

## 🎓 Learning Pointers

- **Say it out loud on every domain ticket: "domain assignment never changes who can see or open anything."** This is the exact same disambiguation pattern as SharePoint Hub Sites (`M365/SharePoint-OneDrive/HubSites-B.md`) — a navigation/grouping/discovery mechanism that looks like an access boundary but explicitly isn't one. Assume this confusion by default. [Fabric domains](https://learn.microsoft.com/en-us/fabric/governance/domains)
- **Domain contributor and workspace Admin are two independent requirements that both must be true.** Being listed as a domain contributor grants nothing on its own — the same person still needs the Admin role on the specific workspace they're trying to assign. This mirrors the pattern seen across Fabric/OneLake security (`FabricAdmin-A.md`) where control-plane role and data/assignment permission are separate axes.
- **Reassigning an already-assigned workspace is blocked by default.** The "Allow tenant and domain admins to override workspace assignments (preview)" tenant setting must be explicitly enabled first — without it, a domain/Fabric admin's reassignment attempt will show a warning but silently not take effect as expected if the admin doesn't notice the override prompt.
- **Default domain is a one-time-plus-forward-going rule, not a continuously enforced policy.** It assigns unassigned workspaces at the moment a user/group is added to the list, and governs future workspace creation — it will never retroactively move an already-assigned workspace. Treat "why didn't this get reassigned automatically" as expected behavior, not a bug, unless the workspace was genuinely unassigned.
- **Subdomains deliberately have no admin list of their own** — they inherit their parent domain's admins and only expose General settings. Don't spend time looking for a subdomain-specific admin/contributor configuration screen; it doesn't exist. [Fabric domains — subdomains](https://learn.microsoft.com/en-us/fabric/governance/domains#subdomains)
