# Microsoft Planner — Hotfix Runbook (Mode B: Ops)
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

**Read this first:** "Microsoft Planner" is now one brand covering **two architecturally separate products with three independent admin kill switches**. **Basic plans** (the classic Planner experience — tied to a Microsoft 365 Group or a groupless Roster) store data in Azure/Exchange/SharePoint and are controlled by the `Set-PlannerConfiguration` PowerShell cmdlets. **Premium plans** (the former standalone "Project for the web," retired as its own app in August 2025 and folded into Planner with no data or license change) store data in **Dataverse** and are controlled entirely from the **Microsoft 365 admin center's Project settings page** — there is no PowerShell equivalent. A third, separate switch (Cloud Policy) controls only the **Planner Loop component**. Disabling one does nothing to the other two — most "I turned off Planner and it's still there" tickets are this split. Separately: **Project Online** (the old SharePoint-based PWA product) is a *different product entirely* and is retiring **September 30, 2026** — do not confuse a Project Online migration deadline with anything in this runbook.

```powershell
# 1. Basic-plan tenant configuration (requires the special PlannerTenantAdmin PowerShell
#    module — see Fix 1 if this cmdlet isn't found)
Get-PlannerConfiguration
# Returns: IsPlannerAllowed, AllowCalendarSharing, AllowRosterCreation

# 2. Premium (Project for the web / Dataverse-backed) service plan state for a user —
#    confirms whether the PROJECT_P1 / PROJECT_PROFESSIONAL service plan is actually enabled,
#    not just whether the parent SKU is assigned
Get-MgUserLicenseDetail -UserId <UPN> |
    Select-Object -ExpandProperty ServicePlans |
    Where-Object ServicePlanName -match "PROJECT_P1|PROJECT_PROFESSIONAL|PROJECTWORKMANAGEMENT"

# 3. Confirm the Dataverse Default Environment exists and isn't blocked by the D365-apps gate
#    (Power Platform admin center → Environments → Default Environment → Details)
#    No PowerShell one-liner replaces this UI check reliably across tenant configurations —
#    treat this as a manual step, not a scripted one.

# 4. Confirm which Microsoft 365 Group creation policy governs who can create a NEW Basic plan
#    (Basic plans are Group-backed by default; this is an EntraID-side control, not Planner's)
Get-MgBetaDirectorySetting | Where-Object DisplayName -EQ "Group.Unified" |
    Select-Object -ExpandProperty Values

# 5. List Roster-backed (groupless) plans a user owns, via Graph — useful when a plan has no
#    corresponding Microsoft 365 Group and standard group-based lookups come up empty
Get-MgPlannerPlan -Filter "owner eq '<groupOrRosterId>'" -ErrorAction SilentlyContinue
```

**Interpret immediately:**

| Symptom | Quick check | Go to |
|---|---|---|
| `Set-PlannerConfiguration`/`Get-PlannerConfiguration` — "command not found" | Not a Graph/EXO/SPO module issue — Planner tenant admin cmdlets ship as a separate downloadable ZIP, not a PowerShell Gallery module | Fix 1 |
| Disabled Planner org-wide but users with Project Plan licenses can still build Gantt/Timeline plans | Only the Basic-plan switch was flipped; Premium (Dataverse-backed) plans have a completely separate on/off toggle in the M365 admin center | Fix 2 |
| Removed a user's Planner license but they can still create/edit plans | `planner.cloud.microsoft` direct URL bypasses license-gated navigation tiles; also check the Microsoft 365 Group creation policy | Fix 3 |
| User with a valid Planner and Project Plan 3/5 license can't create a Premium/Project plan | Dataverse Default Environment missing, "Enable D365 Apps" conflict, or fewer than 5 licenses when targeting a Production environment | Fix 4 |
| Disabled Roster creation but Roster-backed plans keep appearing | `AllowRosterCreation $false` only blocks *new* Rosters — existing ones remain fully usable | Fix 5 |
| Guest/external user edited or deleted a task, plan name, or bucket unexpectedly | Guest default permissions in Basic plans are broad by design, not a misconfiguration | Fix 6 |
| Conditional Access policy scoped to "Planner" isn't enforced on the iOS/Android app | CA for Planner mobile only applies if CA is enabled for Exchange **or** SharePoint — there is no direct Planner CA target | Fix 7 |
| Client is panicking about a "Planner shutdown" after reading about a Microsoft retirement | Almost certainly confusing **Project Online** (retiring Sept 30, 2026 — real, needs migration) with **Project for the web** (already retired Aug 2025, folded into Planner, zero action needed) | Fix 8 |
| Security review flags Planner's "Add to Outlook calendar" iCalendar links | Expected behavior — those links carry no authentication by design | Fix 9 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft 365 subscription with a Planner-inclusive SKU
(Business Basic/Standard, Office/Microsoft 365 E1/E3/E5, Microsoft 365 A1)
    │
    ├── BASIC PLANS (classic Planner) ─────────────────────────────────────────┐
    │     Service plan: PROJECTWORKMANAGEMENT                                  │
    │     Controlled by: Set-PlannerConfiguration (special downloadable        │
    │       PlannerTenantAdmin PowerShell module — NOT PS Gallery)             │
    │         ├── IsPlannerAllowed        → master Basic-plan on/off           │
    │         ├── AllowRosterCreation     → groupless "Roster" plan creation   │
    │         └── AllowCalendarSharing    → unauthenticated iCalendar export   │
    │     Backing container: Microsoft 365 Group (default) OR groupless        │
    │       Roster container (self-deletes when last member is removed)       │
    │     Group creation gated separately by EntraID's                        │
    │       "Group.Unified" / restricted-group-creation directory setting      │
    │                                                                          │
    ├── PREMIUM PLANS (formerly "Project for the web", retired as its own      │
    │     app Aug 2025 — same product now surfaced inside Planner) ───────────┤
    │     License: Planner Plan 1 / Planner and Project Plan 3 / Plan 5        │
    │     Service plans: PROJECT_P1 (Plan 1) / PROJECT_PROFESSIONAL (Plan 3,5) │
    │     Controlled by: M365 admin center → Settings → Org Settings →         │
    │       Project (NO PowerShell equivalent for the org-wide toggle)         │
    │     Storage: Dataverse, inside a Power Platform Environment              │
    │         ├── Default Environment: auto-provisioned, 1 license enough      │
    │         ├── Production environments: require ≥5 Project licenses         │
    │         └── "Enable D365 Apps" toggle must be OFF for that environment   │
    │               (Project cannot coexist with Dynamics 365 Sales /          │
    │                Project Operations in the same environment)               │
    │     Access control inside Dataverse: customizable "Project Team          │
    │       Member" security role (separate from Planner's own permissions)    │
    │     Roadmap sub-feature: separate on/off checkbox, same admin page;      │
    │       needs its connector added to Power Platform DLP policies manually  │
    │                                                                          │
    └── PLANNER LOOP COMPONENT (view/edit a plan inline in Outlook/Teams/      │
          Loop app) ────────────────────────────────────────────────────────┘
          Controlled by: Cloud Policy (config.office.com) — completely
            separate from both switches above; see M365/Loop/Loop-A.md for
            the shared Cloud Policy architecture this rides on
    │
    ▼
Microsoft 365 Copilot in Planner (Premium plans only) — additional layer,
    requires a Copilot license on top of Planner Plan 1/3/5; see
    M365/Copilot/Copilot-A.md for tenant-wide Copilot enablement
    │
    ▼
A COMPLETELY UNRELATED PRODUCT SHARING NO INFRASTRUCTURE:
Project Online (SharePoint-based Project Web App) — retiring Sept 30, 2026.
    Turning Project Online on/off for a user has NO effect on Project for
    the web/Premium Planner access, and vice versa — separate license
    service plans, separate admin toggle, separate retirement timeline.
```

</details>

---
## Diagnosis & Validation Flow

1. **Identify which of the three products the ticket is actually about before touching anything.** Ask: is this a Basic (Group/Roster) plan, a Premium (Timeline/Gantt/dependencies) plan, or the Planner Loop component embedded in another app? Each has a different admin surface — skipping this step is the single biggest time-waster in this topic.
   - Good: symptom clearly maps to one of the three.
   - Bad: ambiguous — check `Get-MgPlannerPlan` for the plan's `container.type` (`group` vs `roster`) or ask whether the user sees a Timeline/People/Goals view (Premium-only) to disambiguate.

2. **For Basic-plan tenant settings, confirm the PowerShell module is actually loaded — this is not a standard module.**
   ```powershell
   Get-Command Get-PlannerConfiguration -ErrorAction SilentlyContinue
   ```
   - Good: command resolves.
   - Bad: not found → Fix 1 before doing anything else in this flow.

3. **For Premium-plan access issues, confirm the license service plan, not just the SKU.**
   ```powershell
   Get-MgUserLicenseDetail -UserId <UPN> | Select-Object SkuPartNumber -ExpandProperty ServicePlans
   ```
   - Good: `PROJECT_P1` or `PROJECT_PROFESSIONAL` shows `ProvisioningStatus: Success`.
   - Bad: service plan disabled independently of the parent SKU (common when a license bundle was customized) → Fix 4.

4. **For Premium-plan creation failures with a valid license, check the Dataverse environment layer next.**
   - Power Platform admin center → Environments → confirm a Default (or target) Environment exists, is not in a suspended/disabled state, and does **not** have "Enable D365 Apps" turned on if Project needs to deploy there.
   - Good: environment present, D365 Apps toggle off, license count sufficient for the target environment type.
   - Bad: any of the above fails → Fix 4.

5. **For "Planner won't turn off" complaints, confirm which of the three switches was actually changed.**
   - Good: the admin can state definitively they changed all three relevant switches (Basic PowerShell config, Premium M365 admin center toggle, Cloud Policy for the Loop component) for the surface in question.
   - Bad: only one was changed, or the admin assumed one setting covers all three → Fix 2.

6. **For guest/external-access complaints, confirm expected-vs-broken before changing anything.**
   - Good: understand that Basic-plan guests can create/edit/delete tasks and buckets and rename the plan by design — this is not a misconfiguration to "fix" via a support ticket.
   - Bad: time being spent trying to find a broken permission that doesn't exist → Fix 6.

7. **For any "Planner is being shut down" client concern, separate the two retirements by name before responding.**
   - Good: confirm which product the client actually read about — Project Online (real, Sept 30, 2026, needs migration) vs. Project for the web (already folded into Planner over a year ago, zero action needed).
   - Bad: answering in general terms without naming the specific product → Fix 8.

---
## Common Fix Paths

<details><summary>Fix 1 — Planner tenant-admin PowerShell cmdlets not found</summary>

**When to use:** `Set-PlannerConfiguration`, `Get-PlannerConfiguration`, `Set-PlannerUserPolicy`, or `Get-PlannerUserPolicy` return "command not found," and the usual `Connect-MgGraph`/`Connect-ExchangeOnline`/`Connect-SPOService` connections don't fix it.

1. Understand why first: these cmdlets are **not** part of Microsoft Graph PowerShell, Exchange Online PowerShell, or SharePoint Online PowerShell. They ship as a standalone downloadable ZIP (`tenant-admin-scripts.zip`) containing a `.psm1` module — a genuinely different distribution model from every other Planner-adjacent module in this repo's other M365 topics.
2. Confirm the `MSAL.PS` dependency is installed:
   ```powershell
   Get-Module -ListAvailable MSAL.PS
   # If missing:
   Install-Module -Name MSAL.PS -Scope CurrentUser
   ```
3. Download the Planner Tenant Admin PowerShell package from the official Microsoft Learn "Prerequisites for making Planner changes in Windows PowerShell" article and unzip it locally.
4. **Unblock the file** — Windows blocks script execution from downloaded files by default: right-click `plannertenantadmin.psm1` → Properties → General tab → **Unblock** → OK. (Or `Unblock-File -Path .\PlannerTenantAdmin.psm1`.)
5. Enable script execution for the session and import the module by explicit path:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process
   Import-Module "C:\AdminScript\PlannerTenantAdmin.psm1"
   ```
6. Confirm the signed-in account is a **Global Administrator** — these cmdlets have no lower-privilege delegation path; a Planner-scoped or Groups admin role is not sufficient.
7. Re-run `Get-PlannerConfiguration` — it should now resolve and return `IsPlannerAllowed`, `AllowCalendarSharing`, `AllowRosterCreation`.

**Rollback:** N/A — this is an environment/tooling fix, not a tenant configuration change.

</details>

<details><summary>Fix 2 — "I turned off Planner" but Premium plans (or the Loop component) still work</summary>

**When to use:** An admin disabled Basic Planner tenant-wide but users with Project Plan 1/3/5 licenses can still create Timeline/Gantt plans, or a plan still renders as a Loop component in Outlook/Teams.

1. Confirm which switch was actually flipped:
   ```powershell
   Get-PlannerConfiguration   # Basic plans only — IsPlannerAllowed
   ```
   This has **zero effect** on Premium (Dataverse-backed) plans or the Loop component.
2. To disable Premium plans org-wide: **Microsoft 365 admin center → Settings → Org Settings → Project** → deselect **"Turn on Project for the web for your organization"** → Save changes. There is no PowerShell equivalent for this org-wide toggle.
3. To disable Premium access for specific users instead of the whole org, remove the `Project P1` or `Project P3` service plan from their license (do **not** confuse this with removing the parent Planner Plan 1/3/5 SKU, which also removes Basic-plan Premium-view access):
   ```powershell
   # Bulk example via Microsoft Graph — disable the PROJECT_P1 service plan while
   # keeping the rest of the SKU intact (replace SkuId/DisabledPlans with tenant values)
   Set-MgUserLicense -UserId <UPN> -AddLicenses @{SkuId="<skuId>";DisabledPlans=@("<PROJECT_P1-planId>")} -RemoveLicenses @()
   ```
4. To disable the **Planner Loop component** specifically (view/edit a plan inline in Outlook/Teams/Loop): configure the **"View and edit Planner plans with the Planner Loop component"** Cloud Policy setting at `config.office.com` — see `M365/Loop/Loop-A.md` for the shared Cloud Policy mechanics this setting rides on.
5. Confirm Roadmap separately if it was also expected to go dark — it has its own checkbox on the same Project settings page ("Turn on Roadmap for your organization") and does not follow the main Project for the web toggle automatically in every tenant state.

**Rollback:** Re-enable the specific switch(es) changed; each is independent and reversible without affecting the other two.

</details>

<details><summary>Fix 3 — Removed a user's Planner license, but they can still create/edit plans</summary>

**When to use:** A user's Planner-inclusive license was removed (or the `PROJECTWORKMANAGEMENT` service plan was disabled), but they report still being able to use Planner.

1. Confirm the mechanism first: removing a license only removes the **Planner navigation tile** from the app launcher and other Microsoft apps. It does **not** block direct access at `planner.cloud.microsoft` — Microsoft's own documentation states there is currently no way to remove a user's ability to view/modify **existing** plans there.
2. What admins **can** control: whether the user can **create new** plans at `planner.cloud.microsoft`. Confirm this is scoped correctly rather than expecting full lockout.
3. If the underlying access path is a Microsoft 365 Group the user still belongs to (most Basic plans are Group-backed), removing them from the Group is a more complete block than the Planner license alone — check Group membership as a parallel control, not a substitute explanation.
4. Set client expectations explicitly: full, license-based lockout of Planner is **not currently a supported guarantee** for existing content the user already has direct links to — document this rather than continuing to search for a missing toggle.

**Rollback:** N/A — clarifying fix; re-adding the license restores the navigation tile if removed in error.

</details>

<details><summary>Fix 4 — User with a valid Premium license can't create a Project/Timeline plan</summary>

**When to use:** A user has a confirmed Planner Plan 1, or Planner and Project Plan 3/5 license with the `PROJECT_P1`/`PROJECT_PROFESSIONAL` service plan enabled, but plan creation fails or the Premium views (Timeline, People, Goals) never appear.

1. Re-confirm the service plan (not just the parent SKU) is enabled and has finished provisioning:
   ```powershell
   Get-MgUserLicenseDetail -UserId <UPN> |
       Select-Object -ExpandProperty ServicePlans |
       Where-Object ServicePlanName -match "PROJECT_P1|PROJECT_PROFESSIONAL"
   ```
2. Check the Dataverse **Default Environment** in the Power Platform admin center (`admin.powerapps.com` / `admin.powerplatform.microsoft.com`) — Project auto-deploys its Power App there the first time a licensed user opens it. If the Default Environment was deleted, disabled, or never provisioned, creation fails silently from the user's point of view.
3. Check the **"Enable D365 Apps"** toggle on the target environment. Project **cannot** be deployed into an environment that has this toggle on (i.e., one already hosting Dynamics 365 Sales, Project Operations, or similar apps) — this is a hard platform constraint, not a permission issue. Either target a different environment or leave D365 Apps disabled on the one Project needs.
4. Check license count if targeting a **Production** environment specifically: a minimum of **5** Project licenses is required to provision Project into Production environments; the Default Environment only requires 1.
5. If access-within-a-project is the actual complaint (user can open the app but not a specific project), check the **Project Team Member** Dataverse security role for that user — it's customizable per tenant and may have been narrowed from its default.

**Rollback:** N/A — diagnostic/provisioning fix; re-enabling a toggle or re-provisioning the environment is safe and non-destructive to existing project data.

</details>

<details><summary>Fix 5 — Roster-backed plans keep appearing after disabling Roster creation</summary>

**When to use:** `Set-PlannerConfiguration -AllowRosterCreation $false` was run, but Roster-backed (groupless) plans still show up for users.

1. Confirm the setting only blocks **new** Roster creation going forward — it does not remove, hide, or restrict existing Roster containers or the plans inside them:
   ```powershell
   Get-PlannerConfiguration   # confirm AllowRosterCreation is now False
   ```
2. If the goal is removing a specific existing Roster-backed plan, that has to be done per-plan (deleting the plan, or removing all members so the Roster self-deletes) — there's no bulk "purge all Rosters" tenant command.
3. If users report a Roster plan self-deleted unexpectedly, this is expected behavior: a Roster and its plan **automatically self-delete** when the last member is removed (whether by a member leaving voluntarily or being offboarded) — set expectations rather than treating it as data loss to investigate.

**Rollback:** `Set-PlannerConfiguration -AllowRosterCreation $true` to re-allow new Roster creation.

</details>

<details><summary>Fix 6 — Guest user edited/deleted content in a Basic plan unexpectedly</summary>

**When to use:** A guest (external) user created, edited, or deleted tasks/buckets, or renamed a plan, and the internal team assumed guests had read-only or limited access.

1. Confirm this is expected default behavior, not a bug: guest access to a Basic plan by default allows creating and deleting tasks and buckets, editing task fields, and editing the plan name. Attaching a file or link requires one additional permission grant beyond the default.
2. If tighter control is actually required, the fix is at the **Microsoft 365 Group guest access** layer (who can be invited as a guest to the group backing the plan at all), not inside Planner itself — Planner has no separate, more restrictive guest-permission model of its own.
3. Cross-reference the tenant's overall external collaboration/guest settings in Entra ID if the real ask is "guests generally shouldn't have this much access" rather than a Planner-specific complaint.

**Rollback:** N/A — informational; adjust Group guest-access settings if a policy change is actually warranted.

</details>

<details><summary>Fix 7 — Conditional Access not enforcing on the Planner iOS/Android app</summary>

**When to use:** A Conditional Access policy was scoped to "Planner" (or the client app appears in sign-in logs) but doesn't appear to be enforced on mobile.

1. Confirm the mechanism: Conditional Access policies apply to the Planner iOS/Android apps **only if CA is already enabled for Exchange Online or SharePoint Online** on that policy. Scoping a CA policy to Planner alone, with neither Exchange nor SharePoint included, does not apply the policy to the Planner mobile apps.
2. Add Exchange Online and/or SharePoint Online as target cloud apps on the same CA policy (in addition to, not instead of, any Planner-specific targeting already present).
3. Re-test sign-in from the mobile app and confirm enforcement via the CA policy's sign-in log entries, not just observed app behavior.

**Rollback:** Remove the added Exchange/SharePoint targeting if this was exploratory and the intended scope needs re-evaluating with the client.

</details>

<details><summary>Fix 8 — Client confused about "Planner shutting down" (Project Online vs. Project for the web)</summary>

**When to use:** A client raises concern after reading about a Microsoft "Project" retirement and asks whether their Planner data or workflows are at risk.

1. Identify which product they actually read about — the two are frequently conflated in third-party coverage:
   - **Project Online** (the older, SharePoint-based Project Web App/PWA product) — genuinely retiring **September 30, 2026**. New PWA site creation was already blocked as of April 1, 2026, and SharePoint 2013 workflows powering Project Online governance broke April 2, 2026. **This requires an actual migration** if the client has active Project Online usage — data must be exported before the retirement date; a standard migration is commonly quoted at roughly twelve weeks, so this needs to start now if it hasn't already.
   - **Project for the web** (the Dataverse-based standalone app) — already retired as its own standalone experience in **August 2025**. All plans, licensing, and data moved into Planner with **no migration, no data loss, and no license change required**. If this is what the client read about, the honest answer is "already handled, nothing to do."
2. Confirm which product the client's tenant actually uses by checking for active Project Online site collections (`https://<tenant>.sharepoint.com/sites/pwa` or similar PWA instance) versus Dataverse-backed Premium Planner plans — don't rely on the client's own description alone, since the naming confusion is exactly what caused the concern.
3. If Project Online is confirmed in use, treat this as a genuine, time-boxed migration project — not a Planner support ticket — and escalate to migration planning immediately given the proximity to the September 30, 2026 cutoff.

**Rollback:** N/A — clarification and, if warranted, escalation to a migration engagement.

</details>

<details><summary>Fix 9 — Security review flags Planner's Outlook calendar sync links</summary>

**When to use:** A security review or client raises concern that Planner's "Add 'My Tasks' to Outlook calendar" iCalendar links don't require authentication.

1. Confirm this is expected, documented behavior, not a vulnerability to remediate: Planner's iCalendar (`.ics`) links for Basic plans and "Assigned to me" tasks are unauthenticated by design — Microsoft's own documentation carries an explicit warning that anyone possessing the link can view the synced task details for as long as the link remains enabled.
2. If the organization's risk posture doesn't allow this, disable calendar sharing tenant-wide rather than trying to add authentication to individual links (no such option exists):
   ```powershell
   Set-PlannerConfiguration -AllowCalendarSharing $false
   ```
3. For a narrower response, advise users with sensitive plans not to generate or share the iCalendar link rather than disabling the feature tenant-wide, if that better matches the actual risk.

**Rollback:** `Set-PlannerConfiguration -AllowCalendarSharing $true` to restore calendar sync.

</details>

---
## Escalation Evidence

```
=== Microsoft Planner Escalation ===
Ticket #:
Client / Tenant:
Product in scope:              [ ] Basic plan (Group/Roster)  [ ] Premium plan (Dataverse)  [ ] Loop component  [ ] Project Online (separate product)
Affected user UPN:
License SKU assigned:
Relevant service plan state (PROJECTWORKMANAGEMENT / PROJECT_P1 / PROJECT_PROFESSIONAL):
Get-PlannerConfiguration output (if Basic-plan related):
M365 admin center Project settings state (if Premium-plan related):
Dataverse environment name + "Enable D365 Apps" state (if Premium creation failure):
Plan container type (group / roster), from Get-MgPlannerPlan:
Guest/external users involved (Y/N):
When did the issue start:
What changed (client-reported):
Escalation target:            [ ] Microsoft Support   [ ] Internal L3   [ ] Power Platform administrator
```

---
## 🎓 Learning Pointers

- **"Planner" is a single brand covering two architecturally different products with three independent admin switches — not one setting.** Basic plans (PowerShell, `Set-PlannerConfiguration`) and Premium plans (M365 admin center Project settings, no PowerShell equivalent) are controlled completely separately, and the Planner Loop component is a third, separate Cloud Policy switch. See [Microsoft Planner for admins](https://learn.microsoft.com/en-us/planner/planner-for-admins).

- **The Planner tenant-admin PowerShell cmdlets are not a standard PowerShell Gallery module.** They ship as a downloadable ZIP requiring the `MSAL.PS` module, a manual file-unblock step, and Global Administrator sign-in — expect this friction the first time, and don't assume `Connect-MgGraph`/`Connect-ExchangeOnline` sessions carry over. See [Prerequisites for making Planner changes in Windows PowerShell](https://learn.microsoft.com/en-us/planner/prerequisites-for-powershell).

- **Project Online and Project for the web are two different products with two different retirement stories — conflating them causes real client anxiety and misdirected migration effort.** Project Online retires September 30, 2026 and requires an active migration (interim deadlines already passed as of April 2026); Project for the web was folded into Planner in August 2025 with zero required action. Confirm which one a client is actually asking about before responding. See [Turn Project for the web or Roadmap on or off](https://learn.microsoft.com/en-us/project-for-the-web/turn-project-for-the-web-off).

- **Removing a user's Planner license does not fully lock them out of Planner.** It removes the navigation tile; direct access to existing plans at `planner.cloud.microsoft` currently has no supported full-block mechanism. Set client expectations accordingly rather than promising complete lockout. See [Frequently asked questions for admins about Microsoft Planner](https://learn.microsoft.com/en-us/planner/faq-for-planner-admins).

- **Premium (Project for the web) plans live in Dataverse and inherit Power Platform environment constraints most Planner tickets never consider** — the "Enable D365 Apps" toggle, Default vs. Production environment licensing minimums, and the customizable Project Team Member security role are all genuine failure points outside Planner's own settings entirely. See [Frequently Asked Questions - Project for the web](https://learn.microsoft.com/en-us/project-for-the-web/faq).

- **Guest permissions in Basic plans are broad by default — creating/deleting tasks and buckets, editing fields, renaming the plan — and this is not independently configurable inside Planner.** Any tightening has to happen at the Microsoft 365 Group guest-access layer instead. See [Guest access in Microsoft Planner](https://support.office.com/article/guest-access-in-microsoft-planner-cc5d7f96-dced-4da4-ab62-08c72d9759c6).
