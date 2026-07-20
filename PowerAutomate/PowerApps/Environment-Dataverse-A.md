# Power Apps Environments & Dataverse Provisioning — Reference Runbook (Mode A: Deep Dive)
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

| Item | Detail |
|------|--------|
| **Surface** | Power Platform admin center environment lifecycle: creation, licensing/policy gates, Dataverse database provisioning, environment visibility across the three Power Platform portals, solution import dependency resolution |
| **Scope** | Environment creation and types, Dataverse database provisioning model, the three-portal visibility divergence, capacity model, solution import missing-dependency resolution |
| **Out of scope** | Individual flow troubleshooting (connector auth, throttling, DLP — see `PowerAutomate/Troubleshooting/`), Dataverse table/column design, Power BI, Copilot Studio-specific environment behavior (Copilot Studio's own security/governance surface — data policies, per-agent authentication, CMK, audit — is covered in `CopilotStudio-Security-A.md`/`-B.md`) |
| **Assumed role** | L2/L3 engineer or MSP admin with Power Platform administrator or Dynamics 365 administrator role in the tenant |

---

## How It Works

<details><summary>Full architecture — environments, Dataverse, and the three-portal visibility model</summary>

### What an environment actually is

An **environment** is a logical container and isolation boundary for apps, flows, connections, and (optionally) a Dataverse database. Every tenant gets exactly one **default environment**, auto-created and shared by all licensed users — this is where most "shadow IT" canvas apps and flows accumulate if no environment strategy is enforced. All other environments (Production, Sandbox, Trial, Developer) are explicitly created.

```
Tenant
 │
 ├── Default environment (auto-created, shared by all licensed users,
 │     cannot be deleted, no environment-creation license required to use it)
 │
 ├── Production environment(s) — explicit business use, admin-managed
 ├── Sandbox environment(s) — non-production, for build/test before promoting
 ├── Trial / Trial (subscription-based) environment(s) — time-limited
 └── Developer environment(s) — one per licensed developer, personal sandbox
```

### Who can create an environment — the license/role matrix

Creating a **new** environment (beyond the default) requires one of:
1. A license granting environment-creation rights (Power Apps/Power Automate/Dynamics 365 plans — Microsoft 365-only licenses do **not** grant this), **or**
2. Membership in a service admin role (Power Platform admin, Dynamics 365 admin) — this bypasses the license requirement for Trial (subscription-based), Developer, Production, and Sandbox types, but **not** for standard per-user trial environments, which still require a per-user trial-eligible license even for admins.

This split is a frequent point of confusion: an MSP engineer with Power Platform admin rights can create a Production environment for a client with zero Power Apps license assigned to their own account, but cannot self-serve a standard trial environment without one.

### The capacity model

Every environment — with or without a Dataverse database — consumes from the tenant's **database storage capacity pool**, minimum 1 GB per environment. This capacity is tenant-wide, not per-environment-allocated in advance; creating environment #20 can fail with a capacity error even though environments #1–19 are healthy, simply because the pool is exhausted. Dynamics 365 Finance & Operations apps draw from a **separate** operations database capacity pool — a client can be out of "regular" Dataverse capacity while operations capacity is untouched, or vice versa.

### Dataverse database provisioning — and its irreversible decision point

Adding a Dataverse database to an environment is a provisioning operation with real backend latency (creating the logical database, applying base schema, security model, and — if selected — installing Dynamics 365 apps). The **"Enable Dynamics 365 apps"** toggle at creation time is a one-way door: if left off, Dynamics 365 Sales/Customer Service/Field Service/etc. can never be installed into that environment later without recreating it from scratch. There is no supported "upgrade path" — this is a planning decision, not a configuration one, and needs to be surfaced to the client before database creation, not after.

A **security group** is now a required field at creation — selecting "None" gives every licensed user in the tenant open access to the environment; selecting a specific group restricts membership. This single dropdown is frequently the actual answer to "why can everyone see this environment" or, inversely, "why can't this specific team see it."

### The three-portal visibility divergence — the architectural core of this topic

This is the single most important mental model in Power Platform administration: **the Power Platform admin center, the Power Apps maker portal, and the Power Automate portal each independently compute their own environment list for a given user.** There is no single "does this user have access to this environment" answer — the answer depends on which portal is asking.

```
┌─────────────────────────────┬──────────────────────────────────────────────────┐
│ Portal                      │ Inclusion rule                                    │
├─────────────────────────────┼──────────────────────────────────────────────────┤
│ Power Platform admin center │ System Administrator (Dataverse) or Environment   │
│                              │ Admin (no-DB) role. Power Platform/Dynamics 365   │
│                              │ admins and authorized service principals see ALL  │
│                              │ environments. Dynamics 365 admins specifically    │
│                              │ are limited to environments where they're a       │
│                              │ member of the applied security group, if any.     │
├─────────────────────────────┼──────────────────────────────────────────────────┤
│ Power Apps maker portal      │ Environment Maker role, OR maker permission on    │
│                              │ ≥1 app in the environment. Environment            │
│                              │ Administrator/custom-role assignment ALONE does   │
│                              │ NOT surface the environment here. Only Entra ID   │
│                              │ group TEAM membership or DIRECT security-role     │
│                              │ assignment is recognized — Dataverse owner teams  │
│                              │ are explicitly not honored for this purpose.      │
├─────────────────────────────┼──────────────────────────────────────────────────┤
│ Power Automate portal        │ ANY built-in security role, OR co-owner status on │
│                              │ ≥1 flow within the environment.                   │
└─────────────────────────────┴──────────────────────────────────────────────────┘
```

PowerShell/CLI tooling (`Get-AdminPowerAppEnvironment`, `pac admin list`) and related admin APIs follow the **admin center's** inclusion rules, not the maker or flow portal's — a script confirming "the user has access" via these tools is only validating one of the three surfaces.

### Sync delay and pagination — two more visibility false-alarms

Role and team membership changes take up to roughly 10 minutes to propagate into portal environment lists — a "still doesn't see it" report five minutes after a role change is often just this delay, not a failed assignment. Separately, in tenants with a large number of environments, the admin center's list is paginated for load performance — a **"Show all"** control at the bottom of the list must be selected (or a search performed, which also triggers full load) to see environments beyond the first page. Both look identical to a genuine access failure at first glance.

### Solution import dependency resolution

Solutions (the ALM packaging unit for Power Apps/Automate/Dataverse customizations) declare dependencies on their components. Import into a target environment fails with a missing-dependency error in one of three shapes:

1. **Managed solution dependency missing** — the target lacks another managed solution the importing solution's components reference. Fix: import the same version of the dependency solution first (or let a retry auto-resolve if the system detects a matching available version).
2. **Unmanaged customization dependency missing** — the source environment has customizations layered directly on top of a managed solution's components that were never themselves packaged into a solution. These don't travel with a solution export at all; they must be explicitly added to a solution and re-exported, or manually rebuilt in the target.
3. **Deprecated application dependency** — the solution depends on a Microsoft application that has been deprecated/retired. No version of that dependency can be installed in a new target; the dependency must be removed from the solution at the source.

Microsoft's guidance is explicit that manually recreating a same-named component in the target to "satisfy" a missing dependency is an anti-pattern — it creates an **unmanaged layer** on top of what should be a clean managed component, which then causes conflicts on the next legitimate solution version update.

</details>

---

## Dependency Stack

```
User attempts an action (view environment / create app / run flow)
        │
        ▼
Which portal is being used?  (admin center / maker / Power Automate)
        │  — each evaluates independently, see the visibility table above
        ▼
Role/team assignment check specific to that portal's rule
        │  (System Admin / Environment Admin / Environment Maker /
        │   built-in security role / flow co-owner / security group membership)
        ▼
Environment-level access confirmed
        │
        ▼
(If Dataverse-backed) Database-level security model
        │  business units, security roles, teams (owner vs. Entra group),
        │  field-level security, row-level sharing
        ▼
Component/resource access (app, flow, table row)
```

```
Environment creation request
        │
        ▼
License OR admin-role check (bypasses license except for standard trial)
        │
        ▼
Tenant policy check ("Control who can create and manage environments")
        │
        ▼
Capacity check (≥1 GB database capacity available in the tenant pool)
        │
        ▼
Provisioning begins — environment shell first, then (if selected) Dataverse
database, then (if selected) Dynamics 365 app installation — each a
sequential, irreversible-if-skipped step for the Dynamics 365 apps choice
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| User reports environment "missing" in Power Apps maker portal but sees it fine in the admin center | Environment Administrator role assigned, but not Environment Maker — the two are not equivalent for maker portal visibility | Check role assignments; assign Environment Maker explicitly |
| Newly-added team member still can't see environment 2 minutes after role assignment | Propagation delay (up to ~10 min is normal) | Wait, retest; don't re-troubleshoot the assignment itself yet |
| Large tenant, admin reports "half our environments are gone" | Admin center pagination — list only shows a subset until "Show all" is selected | Check for the "Show all" control / use search to force full load |
| "Not enough capacity" on environment creation despite few environments existing | Old trial/sandbox environments never cleaned up are each still consuming the 1 GB minimum | Audit environment list against actual active use; delete unused ones |
| Can't add Dynamics 365 Sales to an existing environment | "Enable Dynamics 365 apps" wasn't selected at original database creation — irreversible | Confirm via admin center; only fix is a new environment with the toggle set correctly |
| Environment creation option greyed out for a non-admin user | Tenant policy restricts self-service creation | Power Platform admin center → Settings → Product → environment creation policy |
| Solution import fails citing a managed solution component | Managed dependency solution not yet installed in target, or wrong version | Import matching version of the dependency solution first |
| Solution import fails citing an unmanaged customization | Source has customizations layered outside any solution package | Add the customization to a solution at the source, re-export, re-import |
| User with Dataverse **owner team** membership still doesn't see the environment in the maker portal | Owner teams are explicitly not honored for maker portal visibility — only Entra group teams or direct role assignment count | Reassign via an Entra ID group team or direct security role |
| Dynamics 365 admin can see some environments in the admin center but not others | Security group scoping — Dynamics 365 admins (unlike Power Platform admins) are limited to environments where they're a security-group member if one is applied | Check the environment's assigned security group and the admin's membership |
| New Developer/Trial/Support environment — a second admin added later can't perform all admin functions | These environment types only auto-sync the *initial* user into the Dataverse `SystemUsers` table; additional admins must be explicitly added | Explicitly add the user to the environment per Microsoft's add-users guidance |

---

## Validation Steps

### 1. Confirm environment existence and provisioning state (admin-center truth)

```powershell
# Requires: Microsoft.PowerApps.Administration.PowerShell, connected via Add-PowerAppsAccount
Get-AdminPowerAppEnvironment -EnvironmentName '<environmentId>' |
    Select-Object DisplayName, EnvironmentName, EnvironmentType, IsDefault, ProvisioningState, Location
```
**Good:** `ProvisioningState = Succeeded`.
**Bad:** any other value persisting beyond a reasonable provisioning window (typically minutes, not hours).

### 2. Confirm Dataverse database linkage and readiness

```powershell
Get-AdminPowerAppEnvironment -EnvironmentName '<environmentId>' |
    Select-Object DisplayName, @{N='HasDatabase';E={$null -ne $_.CommonDataServiceDatabaseType -and $_.CommonDataServiceDatabaseType -ne 'none'}}
```

### 3. Determine the affected portal before touching role assignments

Ask (or infer from the ticket): is the complaint from the **admin center**, the **maker portal** (make.powerapps.com), or the **Power Automate portal** (make.powerautomate.com)? This determines which inclusion rule from the How It Works table applies — do not proceed to role changes until this is established.

### 4. Check the user's role assignments in the target environment

```
Power Platform admin center → Environments → <environment> → Settings →
  Users + permissions → Security roles (for the specific user)
```
Cross-reference against the portal-specific rule from the table above — specifically check whether the assignment is via **direct role**, **Entra group team**, or **Dataverse owner team** (only the first two count for maker portal visibility).

### 5. Check tenant environment-creation policy (for creation-blocked tickets)

```
Power Platform admin center → Settings → Product → 
  "Control who can create and manage environments"
```

### 6. Check capacity (for creation-failed tickets)

```
Power Platform admin center → Resources → Capacity
```
No reliable PowerShell equivalent exists for real-time consumption vs. entitlement — the portal is authoritative.

### 7. For solution import failures, pull the exact error detail

```
Environment → Solutions → History → select the failed import → View error details
```
The banner summary is insufficient for diagnosis — always open the detailed log for the named component and its owning solution/publisher.

---

## Troubleshooting Steps (by phase)

### Phase 1: Classify the Failure

1. Visibility (environment exists, specific user/portal can't see it) vs. provisioning (environment doesn't exist or is stuck) vs. solution import (deployment into an existing, visible environment fails)
2. For visibility: identify the specific portal before any role changes
3. For provisioning: pull `ProvisioningState` and cross-reference against elapsed time

### Phase 2: Visibility Failures

1. Confirm the user's role assignment type (direct / Entra group team / Dataverse owner team) — only the first two are portal-visibility-eligible for the maker portal
2. Confirm which specific role is assigned — Environment Administrator does not imply Environment Maker
3. Allow ~10 minutes for propagation before re-testing any change
4. For admin-center-specific gaps involving a Dynamics 365 admin, check the environment's security group assignment
5. For "environments missing at scale" in a large tenant, check pagination ("Show all") before assuming a systemic access problem

### Phase 3: Creation/Provisioning Failures

1. Confirm license or admin-role eligibility for the requesting user
2. Confirm tenant policy allows the requested creation
3. Confirm capacity is available (Resources → Capacity)
4. If Dataverse database provisioning itself stalls beyond a reasonable window, retry via the portal; escalate to Microsoft support if a second attempt also stalls
5. If Dynamics 365 apps are needed later and weren't enabled at creation, this cannot be fixed in place — plan for a net-new environment and data/customization migration

### Phase 4: Solution Import Failures

1. Read the full error detail, not just the summary
2. Classify: managed dependency / unmanaged customization / deprecated application
3. For managed: install matching dependency version in target first
4. For unmanaged: rebuild the customization inside a proper solution at the source
5. For deprecated: remove the dependency at the source; no target-side fix exists
6. Never manually recreate a same-named component in the target as a workaround

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Grant correct maker-portal visibility to a user or team</summary>

```
Power Platform admin center → Environments → <environment> → Settings →
  Users + permissions → Security roles → Assign roles

Assign: Environment Maker (or a custom role that includes maker-equivalent
privileges) — directly to the user, or to an Entra ID SECURITY GROUP that has
been added as a Dataverse TEAM of type "Microsoft Entra ID Group Team"
(not a classic Dataverse owner team).
```

**Rollback:** remove the role assignment; if using a group team, removing the user from the underlying Entra group also removes effective access without needing a Dataverse-side change.

</details>

<details>
<summary>Playbook 2 — Audit and reclaim unused Dataverse capacity</summary>

```powershell
# List all environments and flag ones with a database that may be stale
Get-AdminPowerAppEnvironment | 
    Select-Object DisplayName, EnvironmentName, EnvironmentType, CreatedTime,
    @{N='HasDatabase';E={$_.CommonDataServiceDatabaseType -ne 'none'}} |
    Sort-Object EnvironmentType, CreatedTime
```

Cross-reference against the client's actual project list — Trial and Sandbox environments left over from completed engagements are the most common source of reclaimable capacity. Confirm with the client before deleting anything (`Remove-AdminPowerAppEnvironment` is destructive and not trivially reversible after the grace/soft-delete window).

</details>

<details>
<summary>Playbook 3 — Resolve a managed solution missing-dependency import failure</summary>

```
1. Note the exact dependency solution name + version from the error detail
2. Export/obtain that same version of the dependency solution
3. Import the DEPENDENCY solution into the target environment first
4. Retry the original solution import — it should now resolve cleanly
```

If the exact version isn't available, importing the closest compatible managed version and allowing the retry to auto-negotiate is the documented workaround — but confirm this doesn't silently downgrade functionality the target solution expects.

</details>

<details>
<summary>Playbook 4 — Plan for the irreversible "Enable Dynamics 365 apps" decision</summary>

Before creating any new Production or Sandbox environment with a Dataverse database, confirm explicitly with the client/stakeholder:

```
Will this environment EVER need Dynamics 365 Sales, Customer Service, Field
Service, or another first-party Dynamics 365 app installed?
  YES → select "Yes" for Enable Dynamics 365 apps at creation (requires a
        Dynamics 365 license)
  NO  → leave it off; if the answer changes later, the only path is a new
        environment plus a data/customization migration — there is no
        supported in-place upgrade
```

Document the decision and the date in the client's environment inventory — this single field causes more "why do we need to rebuild this environment" conversations than any other setting in this topic.

</details>

---

## Evidence Pack

```powershell
# Run connected as a Power Platform admin (Add-PowerAppsAccount) — collects
# environment/Dataverse evidence for escalation

$envId = Read-Host "Enter Environment ID or search name"
$report = @()
$report += "=== POWER APPS ENVIRONMENT / DATAVERSE EVIDENCE PACK ==="
$report += "Date: $(Get-Date)"
$report += ""

$env = Get-AdminPowerAppEnvironment -EnvironmentName $envId -ErrorAction SilentlyContinue
If ($env) {
    $report += "--- Environment ---"
    $report += "DisplayName: $($env.DisplayName)"
    $report += "EnvironmentName (ID): $($env.EnvironmentName)"
    $report += "Type: $($env.EnvironmentType)"
    $report += "ProvisioningState: $($env.ProvisioningState)"
    $report += "Location: $($env.Location)"
    $report += "IsDefault: $($env.IsDefault)"
    $report += "HasDatabase: $($env.CommonDataServiceDatabaseType -ne 'none')"
} Else {
    $report += "Environment not found via Get-AdminPowerAppEnvironment — check ID/name and admin scope."
}
$report += ""

$report += "--- All environments in tenant (for capacity/context) ---"
Get-AdminPowerAppEnvironment | ForEach-Object {
    $report += "$($_.DisplayName) | Type=$($_.EnvironmentType) | DB=$($_.CommonDataServiceDatabaseType -ne 'none') | State=$($_.ProvisioningState)"
}

$outputPath = "$env:TEMP\PowerAppsEnvironment-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
$report | Out-File -FilePath $outputPath -Encoding UTF8
Write-Host "Evidence saved to: $outputPath" -ForegroundColor Cyan
```

For the portal-visibility and solution-import evidence categories, the Power Platform admin center's own screens (Users + permissions; Solutions → History → error detail) remain the authoritative source — screenshot or copy the exact error text rather than relying solely on PowerShell, since neither surface is fully exposed via cmdlets today.

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Connect as Power Platform admin | `Add-PowerAppsAccount` |
| List/find an environment | `Get-AdminPowerAppEnvironment -EnvironmentName '<id-or-name>'` |
| List all environments in tenant | `Get-AdminPowerAppEnvironment` |
| CLI equivalent (admin-center rules) | `pac admin list` |
| Check environment provisioning state | `(Get-AdminPowerAppEnvironment -EnvironmentName '<id>').ProvisioningState` |
| Check Dataverse database presence | `(Get-AdminPowerAppEnvironment -EnvironmentName '<id>').CommonDataServiceDatabaseType` |
| Recover a deleted environment | Portal: Environments → Recover (no direct PS cmdlet) |
| Environment creation policy | Portal: Settings → Product → "Control who can create and manage environments" |
| Capacity consumption | Portal: Resources → Capacity |
| Solution import error detail | Portal: Environment → Solutions → History → failed import → View details |
| Assign Environment Maker role | Portal: Environment → Settings → Users + permissions → Security roles |

---

## 🎓 Learning Pointers

- **The three-portal visibility model is the load-bearing concept of this whole topic.** Almost every "I can't see my environment" ticket resolves once you identify which of the three portals (admin center / maker / Power Automate) is actually being used, because each computes access independently. See: [Troubleshoot missing environments](https://learn.microsoft.com/en-us/troubleshoot/power-platform/dataverse/environment-app-access/troubleshoot-missing-environments)

- **Environment Administrator ≠ Environment Maker.** This asymmetry surprises even experienced Dataverse admins coming from a classic security-role background — the highest environment-level role does not automatically grant the maker portal's environment-picker visibility.

- **Dataverse owner teams are a legacy CRM concept that doesn't carry over to portal visibility.** Only Microsoft Entra ID group teams or direct security-role assignment matter for the maker portal's inclusion rule — plan team structures with Entra groups, not classic owner teams, if portal visibility matters.

- **"Enable Dynamics 365 apps" is the single highest-consequence checkbox in environment creation.** It cannot be changed after database provisioning. Build this question into every new-environment intake conversation with the client. See: [Create and manage environments](https://learn.microsoft.com/en-us/power-platform/admin/create-environment)

- **Capacity is a shared tenant pool, not a per-environment allocation.** Environment #20 failing to create is rarely about environment #20 — it's almost always about environments #1 through #19 never being cleaned up. A capacity audit should be step one for any creation-blocked ticket.

- **Never hand-build a component to satisfy a missing solution dependency.** It looks like a fix in the moment and becomes a managed/unmanaged layering conflict on the next real solution update. See: [Missing dependencies during solution import](https://learn.microsoft.com/en-us/troubleshoot/power-platform/dataverse/working-with-solutions/missing-dependency-on-solution-import)
