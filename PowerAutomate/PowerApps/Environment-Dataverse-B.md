# Power Apps Environments & Dataverse Provisioning — Hotfix Runbook (Mode B: Ops)
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

> This is the **Power Apps/Dataverse admin surface** — environment creation, database provisioning, solution import, and "I can't see my environment" complaints. If the ticket is about a specific **flow** failing (connector auth, throttling, DLP blocking a flow), go to `PowerAutomate/Troubleshooting/` instead — those are a different failure domain that happens to share the same tenant.

```powershell
# Requires: Microsoft.PowerApps.Administration.PowerShell module, connected as a Power Platform admin
# Install-Module -Name Microsoft.PowerApps.Administration.PowerShell
# Add-PowerAppsAccount

# 1. Does the environment exist at all, and what state is it in?
Get-AdminPowerAppEnvironment -EnvironmentName '<environmentId-or-search-by-name>' |
    Select-Object DisplayName, EnvironmentName, EnvironmentType, IsDefault, ProvisioningState

# 2. Is there enough Dataverse capacity to provision a NEW environment's database?
# (Power Platform admin center → Resources → Capacity → Capacity add-ons — no direct PS one-liner;
#  fastest is the portal, but this confirms current consumption)
Get-AdminPowerAppEnvironment | Where-Object { $_.EnvironmentType -ne 'Default' } | Measure-Object

# 3. Which portal is the user complaining they can't see the environment in?
#    Admin center / Maker portal / Power Automate portal have DIFFERENT inclusion rules —
#    see Dependency Cascade below before troubleting role assignments blind.

# 4. Is a solution import stuck or failed?
Get-AdminPowerAppEnvironment -EnvironmentName '<environmentId>' |
    Select-Object DisplayName, EnvironmentSku
# Then check Power Platform admin center → environment → Solutions → History for the specific error
```

| Result | Interpretation |
|--------|---------------|
| `ProvisioningState` = "Succeeded" but user still can't see it | Not a provisioning problem — it's a **visibility/role** problem. Go to Fix 2. |
| `ProvisioningState` stuck on "LinkedMetadataDatabaseProvisioning" or similar for >30 min | Genuine provisioning stall — go to Fix 1 |
| Environment creation button greyed out / access denied for a non-admin user | Tenant policy restricts self-service creation — go to Fix 3 |
| "Not enough capacity" error on environment creation | Tenant is out of the 1 GB free database capacity per environment — go to Fix 4 |
| Solution import error mentions "missing dependency" | Managed/unmanaged dependency gap between source and target — go to Fix 5 |
| User sees environment in one portal (e.g. admin center) but not another (e.g. maker portal) | **Expected** — each portal has independent inclusion rules, not a bug. Go to Fix 2. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
"I can't see the environment" — which portal?
        │
        ├─► Power Platform admin center
        │       requires: System Administrator (Dataverse) or Environment Admin
        │       (no-Dataverse) role, OR tenant-level Power Platform/Dynamics 365 admin,
        │       OR (for Dynamics 365 admins specifically) membership in the environment's
        │       security group if one is applied
        │
        ├─► Power Apps maker portal
        │       requires: Environment Maker role, OR maker permission on ≥1 app in
        │       that environment
        │       ⚠️ Environment Administrator role assignment alone does NOT surface the
        │          environment here — a common false assumption
        │       ⚠️ only Entra group TEAM membership or DIRECT security-role assignment
        │          is recognized — Dataverse OWNER teams don't count
        │
        └─► Power Automate portal
                requires: ANY built-in security role, OR co-owner on ≥1 flow in
                that environment

"Environment creation failed / can't create" 
        │
        ├─► License check: does the user have an environment-creation-eligible
        │   license, OR are they a Power Platform/Dynamics 365 admin (bypasses
        │   license requirement except for trial/standard environments)?
        ├─► Capacity check: ≥1 GB database storage capacity available (production
        │   AND sandbox; Dynamics 365 F&O apps need their own 1 GB operations pool)
        └─► Tenant policy check: does "Control who can create and manage
            environments" restrict this user/all users from self-service creation?

"Solution import failed — missing dependency"
        │
        ├─► Managed solution dependency missing in target (most common)
        ├─► Unmanaged customization dependency missing in target
        └─► Dependency on a deprecated/retired application
```

</details>

---
## Diagnosis & Validation Flow

1. **Establish which of the three failure categories this is:** visibility (environment exists, user can't see it), provisioning (environment doesn't exist yet or is stuck being created), or solution import (environment exists, a deployment into it is failing).

2. **For visibility complaints, always ask which portal first.** The three portals (admin center, maker portal, flow portal) do not share an inclusion algorithm — troubleshooting the wrong one wastes the whole ticket. See the Dependency Cascade above.

3. **For provisioning complaints, pull the environment's current state:**
   ```powershell
   Get-AdminPowerAppEnvironment -EnvironmentName '<id>' | Select-Object *
   ```
   Cross-reference `ProvisioningState` against expected values (`Succeeded`, or an in-progress state). A state stuck for over 30 minutes with no change is a genuine stall, not something to keep waiting on.

4. **For capacity-related creation failures, check Power Platform admin center → Resources → Capacity.** Consumed vs. available database capacity is not exposed cleanly via PowerShell — the portal view is authoritative and fastest here.

5. **For solution import failures, open the specific import job's error detail** (environment → Solutions → History → select the failed import → View details). The error will name the exact missing component and its solution/publisher — don't guess from the summary banner alone.

---
## Common Fix Paths

<details><summary>Fix 1 — Retry a stalled Dataverse database provisioning</summary>

```
1. Power Platform admin center → Environments → select the environment
2. Confirm the "Database" status column — if it shows "Provisioning failed"
   rather than merely slow, a retry from the portal (Edit → re-save) is the
   supported path; there is no PowerShell cmdlet to force-retry provisioning.
3. If provisioning fails a second time, capture the environment ID and open a
   support request — repeated provisioning failures usually indicate a
   backend regional capacity issue, not a client-side misconfiguration.
```

**Note:** if this environment was created off the back of a stuck Power Automate Approval flow (first-run Dataverse auto-provisioning), re-running the approval flow itself can also retrigger provisioning — see Microsoft's [Approvals Dataverse provisioning errors](https://learn.microsoft.com/en-us/troubleshoot/power-platform/power-automate/approvals/flow-approval-cds-provisioning-errors) guide for that specific trigger path.

</details>

<details>
<summary>Fix 2 — Environment "invisible" in a specific portal (role/team assignment)</summary>

```powershell
# Check current role assignments for a user in the target environment (requires Dataverse)
# Run in the target environment's context via the Dataverse Web API or Power Platform admin center →
# Environment → Settings → Users + permissions → Security roles

# Fastest portal fix for "maker portal doesn't show my environment":
# Environment → Settings → Users + permissions → Application users / Security roles →
# assign the user the "Environment Maker" role directly (NOT just Environment Administrator)
```

Checklist by portal:
- **Admin center missing** → assign System Administrator (Dataverse) or Environment Admin (no-DB), or add to the environment's security group if one is applied
- **Maker portal missing** → assign **Environment Maker** explicitly; Environment Administrator does not imply Maker visibility
- **Power Automate portal missing** → assign any built-in security role, or make the user a co-owner on an existing flow in that environment
- Always wait ~10 minutes after any role/team change before re-testing — sync delay is expected, not a fix failure
- If the admin center list still looks incomplete for a tenant with many environments, check for a **"Show all"** link at the bottom of the list — the admin center paginates and may only show a subset on first load

</details>

<details>
<summary>Fix 3 — Environment creation blocked by tenant policy</summary>

```
Power Platform admin center → Settings → Product → 
  "Control who can create and manage environments" (or search Policies)
```

Confirm whether self-service environment creation is restricted to Power Platform/Dynamics 365 admins only, or to a specific security group. If the client wants a specific user to self-serve create environments, either broaden the policy or, more commonly for MSP-managed tenants, keep it locked down and handle creation as an admin-assisted request — document the decision either way, this is a security posture choice, not a bug to "fix" by default.

</details>

<details>
<summary>Fix 4 — Out of Dataverse database capacity</summary>

```
Power Platform admin center → Resources → Capacity →
  review Database, File, and Log capacity consumption vs. entitlement
```

Options:
1. Free up capacity — delete unused trial/sandbox environments consuming the 1 GB minimum each
2. Purchase additional capacity add-ons (client/billing decision — do not purchase without sign-off)
3. For a one-off Production/Sandbox environment with no Dynamics 365 apps needed, create it **without** a Dataverse database if the use case allows (canvas apps/flows against external data sources don't require it)

</details>

<details>
<summary>Fix 5 — Solution import "missing dependency" error</summary>

```
1. Open the failed import's error detail — note the EXACT component named and
   which solution/publisher it belongs to
2. If it's a MANAGED solution dependency: import the same version of that
   managed solution into the target environment FIRST, then retry the
   original import — the system will auto-install/update the dependency
   during a subsequent import attempt if versions align
3. If it's an UNMANAGED customization dependency: the source environment has
   a customization (often a field, view, or form change) made directly against
   a managed layer that was never captured in a solution — this needs to be
   added to a solution in the source and re-exported, or manually
   recreated in the target
4. If it's a DEPRECATED application dependency: remove the dependency from the
   solution in the source environment — deprecated apps cannot be installed
   in a new target regardless of version matching
```

**Do not** attempt to bypass a missing dependency by manually creating a same-named component in the target — this creates an unmanaged layer on top of what should be a managed component and causes worse problems on the next legitimate solution update.

</details>

---
## Escalation Evidence

```
POWER APPS / DATAVERSE ENVIRONMENT ESCALATION
================================================
Environment name/ID:      <display name / GUID>
Environment type:         <Production / Sandbox / Trial / Developer>
Has Dataverse database:   <Yes / No>
ProvisioningState:        <from Get-AdminPowerAppEnvironment>
Reporting user UPN:       <UPN>
Portal affected:          <Admin center / Maker portal / Power Automate portal>
User's current roles:     <security roles + team memberships in that environment>
Capacity status:          <consumed / entitled, from admin center Resources > Capacity>
Tenant creation policy:   <who can create environments>
Solution import error
  (if applicable):        <exact error text + named missing component>
Fix attempted:            <Fix # from this runbook>
Result:                   <resolved / still failing / escalating>
```

---
## 🎓 Learning Pointers

- **Three portals, three different visibility rules — this is the #1 source of "my environment disappeared" tickets.** The admin center, maker portal, and Power Automate portal each compute their own environment list independently. Memorize the differences rather than re-deriving them under pressure. See: [Troubleshoot missing environments](https://learn.microsoft.com/en-us/troubleshoot/power-platform/dataverse/environment-app-access/troubleshoot-missing-environments)

- **Environment Administrator ≠ Environment Maker for portal visibility.** This is the single most counter-intuitive fact in this topic — assigning the highest environment role does not make the environment appear in the Power Apps maker portal's picker. Only the Maker role or app-level maker permission does that.

- **"Enable Dynamics 365 apps" at creation time is a one-way door.** If a client might ever want Dynamics 365 Sales/Field Service/etc. in an environment, that decision must be made at database creation — there is no supported path to add it retroactively without recreating the environment. Ask this question explicitly during environment planning, not after.

- **Owner teams don't grant portal visibility — Entra group teams do.** Dataverse has two team types and only one (Entra ID group-backed) is recognized by the maker portal's environment picker. This trips up admins who are used to Dataverse's classic owner-team security model from on-prem CRM days.

- **1 GB minimum capacity applies to every environment, database or not.** Sandbox and trial environments left lying around after a project ends quietly consume the same capacity pool as production — a capacity audit is often the fastest fix for "can't create a new environment" without any purchase required.
