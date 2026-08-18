# Microsoft Planner — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- The **unified Planner architecture**: Basic plans (Group- or Roster-backed, Azure/Exchange/SharePoint storage) versus Premium plans (formerly the standalone "Project for the web," Dataverse storage), and the three independent admin surfaces that each piece answers to
- Basic-plan **tenant PowerShell administration** via the non-standard, separately-distributed `PlannerTenantAdmin` module — installation, prerequisites, and the full cmdlet surface
- Premium-plan **licensing and Power Platform/Dataverse dependency**: service plans, environment provisioning rules, the "Enable D365 Apps" conflict, and the Project Team Member security role
- **Roster containers** (groupless Basic plans) — creation policy, lifecycle, and self-deletion behavior
- **Guest/external access** defaults and where they can (and can't) be tightened
- **Conditional Access** behavior for the Planner mobile apps and its dependency on Exchange/SharePoint targeting
- The **Project Online vs. Project for the web vs. classic Planner** naming history and the two genuinely distinct, easily-conflated Microsoft retirement timelines (Project for the web: retired as a standalone app August 2025, no migration; Project Online: retiring September 30, 2026, migration required)
- Data residency by feature: Exchange (To Do/Outlook tasks), Azure (Basic plan/task metadata), SharePoint (Basic plan attachments, via the backing Group site), Dataverse (Premium/Project plans and tasks)

**Out of scope (see cross-references):**
- Microsoft 365 Copilot's presence inside Premium Planner plans — this runbook notes the dependency but defers to `M365/Copilot/Copilot-A/B.md` for tenant-wide Copilot licensing and governance
- The Planner Loop component's embedding mechanics inside Outlook/Teams/Loop — controlled by the same Cloud Policy engine covered in depth in `M365/Loop/Loop-A/B.md`; this runbook covers only the Planner-specific policy setting name and its independence from the other two Planner switches
- General Microsoft 365 Group lifecycle, guest access, and creation-restriction policy administration — see `EntraID/` for the underlying directory-level mechanics; this runbook covers only how those mechanics gate Basic-plan creation
- **Project Online** administration in any depth beyond distinguishing it from Project for the web/Premium Planner for client-communication purposes — Project Online is a different product (SharePoint-based Project Web App) with no shared infrastructure, licensing, or admin surface with anything else in this runbook
- General Power Platform/Dataverse environment administration (DLP policies, environment strategy, ALM) — see `PowerAutomate/` for Power Platform DLP specifically; this runbook covers only the environment provisioning rules that gate Premium Planner specifically

**Assumes:**
- Microsoft Graph PowerShell (`Microsoft.Graph.Planner`, `Microsoft.Graph.Users.Actions`) connected via `Connect-MgGraph` for all `Get/New/Remove-MgPlannerPlan` and license-management operations
- The separately-downloaded `PlannerTenantAdmin` PowerShell module, plus its `MSAL.PS` dependency, installed and imported per the vendor prerequisites for all `Set/Get-PlannerConfiguration` and `Set/Get-PlannerUserPolicy` operations — **Global Administrator** sign-in is required for these specifically; there is no delegated-admin-role equivalent
- Power Platform administrator access (`admin.powerplatform.microsoft.com`) for any Dataverse environment-layer diagnosis affecting Premium plans
- Microsoft 365 admin center access for the Project org-settings page — the Premium-plan org-wide toggle has **no PowerShell equivalent** to read or set, a genuine asymmetry against the fully-scriptable Basic-plan side

---
## How It Works

### One brand, two products, three admin surfaces

"Microsoft Planner" is the current umbrella brand for what used to be marketed as three separate things: **classic Planner** (task boards backed by a Microsoft 365 Group), **Microsoft To Do** (personal task lists, largely out of scope here as its own product), and **Project for the web** (Dataverse-backed project management with Timeline/Gantt views, dependencies, and resourcing). Since the April 2024 rebrand, all of these surface inside the single Planner app in Teams, on the web (`planner.cloud.microsoft`), and on mobile — but **the underlying architecture did not merge**. What merged was the presentation layer. Two structurally different products now share one UI shell, and each retains its own licensing model, storage backend, and administrative control surface:

| | Basic plans | Premium plans |
|---|---|---|
| Formerly known as | Classic Planner | Project for the web |
| Backing entity | Microsoft 365 Group, or a groupless **Roster** container | A **Project** record in Dataverse |
| License required | Included in most standard M365 SKUs (`PROJECTWORKMANAGEMENT` service plan) | Planner Plan 1, or Planner and Project Plan 3/5 (`PROJECT_P1` / `PROJECT_PROFESSIONAL` service plans) |
| Views | Grid, Board, Schedule, Charts | All Basic views **plus** Timeline (Gantt), People, Goals, custom fields, dependencies, sprints |
| Tenant admin surface | PowerShell (`Set-PlannerConfiguration`, non-standard module) | Microsoft 365 admin center → Settings → Org Settings → Project (no PowerShell) |
| Storage | Azure (plan/task metadata) + SharePoint (attachments, via Group site) | Dataverse, inside a Power Platform Environment |

A third, independent layer — the **Planner Loop component** — lets any plan render inline inside Outlook, Teams, and the Loop app. This is governed entirely by Cloud Policy, the same mechanism documented in depth in `M365/Loop/Loop-A.md`, and is unrelated to either switch above.

**Why this matters operationally:** an admin action taken against one surface has zero effect on the other two. The three most common "Planner isn't behaving as configured" tickets in this topic all trace back to an admin (reasonably) assuming one setting governs the whole Planner experience.

### Basic plans: Group-backed vs. Roster-backed

A Basic plan needs a container to hold its membership and permissions. By default this is a **Microsoft 365 Group** — the plan inherits the Group's membership, and plan creation is therefore gated indirectly by whatever Group-creation restriction policy the tenant has configured in Entra ID (`Group.Unified` directory setting), not by anything Planner-specific.

The alternative container is a **Roster** — a lightweight, groupless list of members that any user (including guests) can create directly inside Planner, with no corresponding Microsoft 365 Group, security group, or directory object created anywhere else. Every member of a Roster has **identical permissions**: add/remove other members, and create/edit/delete tasks, buckets, and the Roster itself. A Roster (and its plan) **automatically self-deletes** the moment its last member is removed — whether that member left voluntarily or was removed during offboarding. This is by-design lifecycle behavior, not a bug, and it means Roster-backed plans have no admin-visible "orphaned but still present" state the way Group-backed plans can.

Roster creation is controlled tenant-wide via:
```powershell
Set-PlannerConfiguration -AllowRosterCreation $false   # or $true
```
Disabling this blocks **new** Roster creation only — it has no retroactive effect on Rosters that already exist.

### Basic-plan tenant administration: a genuinely non-standard PowerShell surface

Unlike every other Microsoft 365 workload covered elsewhere in this repository, Basic-plan tenant settings are **not** exposed through Microsoft Graph PowerShell, Exchange Online PowerShell, or SharePoint Online PowerShell. They're exposed through a small, purpose-built module (`PlannerTenantAdmin.psm1`) that Microsoft distributes as a **downloadable ZIP file**, not a PowerShell Gallery package. Standing up this tooling for the first time requires:

1. The `MSAL.PS` module (a genuine external dependency, not bundled).
2. Downloading and unzipping the Planner Tenant Admin PowerShell package.
3. **Manually unblocking** the `.psm1` file (Windows blocks script execution from internet-downloaded files by default) via file Properties → Unblock, or `Unblock-File`.
4. A session-scoped execution-policy relaxation (`Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process`).
5. `Import-Module` against the **explicit local file path** — there's no module name to resolve from a repository.
6. **Global Administrator** sign-in specifically — there is no lower-privilege delegated role (no "Planner Administrator" or similar) that can run these cmdlets.

Once loaded, the cmdlet surface is small and entirely tenant-scoped (no per-user creation-policy granularity beyond the two exceptions noted below):

| Cmdlet | Controls |
|---|---|
| `Set/Get-PlannerConfiguration` | `IsPlannerAllowed` (master Basic-plan on/off), `AllowRosterCreation`, `AllowCalendarSharing` |
| `Set/Get-PlannerUserPolicy` | Per-user `BlockDeleteTasksNotCreatedBySelf` — the one setting in this surface that **is** scoped to an individual user rather than the whole tenant |

`Set-PlannerConfiguration -IsPlannerAllowed $false` turns off Basic plans across every Planner endpoint (Teams, web, mobile, connectors) tenant-wide. It has **no effect whatsoever** on Premium (Dataverse-backed) plans, which are controlled from an entirely different admin surface (see below).

### Premium plans: licensing, and the Power Platform/Dataverse dependency most Planner tickets never reach

Premium plans require one of three license tiers — **Planner Plan 1** (Timeline/People/Goals views, no advanced reporting), or **Planner and Project Plan 3/5** (adds report creation, dependencies, sprints, custom fields, team workload). The relevant service plans are `PROJECT_P1` and `PROJECT_PROFESSIONAL` respectively — checking the parent SKU alone is insufficient, since these service plans can be independently disabled within a customized license bundle.

Premium plan data lives in **Dataverse**, inside a Power Platform **Environment**. The first time a licensed user opens a Premium plan, Microsoft auto-deploys a model-driven Power App (historically branded the "Project Power App") into that environment. This introduces genuine Power Platform administration surface area into what looks, from the Planner UI, like a simple task-management feature:

- **Environment provisioning is license-gated.** A single Project license is sufficient to provision into the tenant's **Default Environment**. Provisioning into a **Production** environment specifically requires a minimum of **5** Project licenses. Additional environments beyond that are gated by available Dataverse database storage, which itself scales with license count.
- **The "Enable D365 Apps" toggle is a hard conflict, not a soft warning.** An environment with this toggle enabled — meaning it already hosts (or is intended to host) genuine Dynamics 365 applications such as Sales or Project Operations — **cannot** also host Project for the web/Premium Planner data. This is a platform-level incompatibility, not a permissions or licensing gap, and it is the single most common cause of "Premium plan creation just silently doesn't work" tickets once licensing itself has been ruled out.
- **Access control within a Premium plan's Dataverse layer is separate from Planner's own sharing model.** The customizable **Project Team Member** security role governs Dataverse-level access to project records and can be edited like any other Dataverse security role — narrowing it can produce access symptoms that look like a Planner bug but are actually a Power Platform admin-center configuration.
- **Custom extensibility exists, and has its own licensing wrinkle.** Organizations building custom Power Apps or Power BI reports against Project tables need, in addition to a Planner Plan 1/3/5 license, a **separate Power Apps or Power BI license** for the users of those custom artifacts — Premium Planner licensing alone doesn't extend to custom app/report consumption.

Premium capabilities are explicitly **not available in Government Cloud Community (GCC) High or Department of Defense (DoD) tenants** as of this writing — a hard cloud-environment gate, not a rollout-timing gap.

### The org-wide Premium toggle, and why it has no PowerShell equivalent

Turning Premium plans (Project for the web) on or off for the entire tenant is done exclusively through **Microsoft 365 admin center → Settings → Org Settings → Project**, via the **"Turn on Project for the web for your organization"** checkbox. This setting requires the **new** Microsoft 365 admin center specifically (the classic admin center does not expose it) and has no PowerShell, Graph API, or CLI equivalent for the org-wide toggle. **Turning it off has explicitly no effect on Project Online** — Microsoft's own documentation calls this out directly, underscoring that these remain fully separate products under the hood despite naming similarity.

For per-user control instead of an org-wide switch, admins disable the `Project P1` or `Project P3` **service plan** on the user's license (via the admin center's per-user license management, or in bulk via `Set-MgUserLicense`) — deliberately distinct from removing the parent **Planner Plan 1/3/5 SKU** entirely, which would also remove the user's Basic-plan access to Premium-only views.

**Roadmap** — the portfolio-level rollup view across multiple Premium plans — has its **own separate checkbox** on the same admin center page ("Turn on Roadmap for your organization") and does not automatically follow the main Project toggle in every tenant configuration. Roadmap also depends on the **Project Roadmap connector** being present in the tenant's Power Platform Data Loss Prevention policy — as of this writing, that connector does not reliably appear in the DLP policy GUI and must be added via `Add-CustomConnectorToPolicy` in the PowerApps Administrator PowerShell module (`shared_projectroadmap` connector ID) as a documented workaround. See `PowerAutomate/Troubleshooting/DLP-Policies-A/B.md` for the general Power Platform DLP mechanics this workaround sits on top of.

### Guest access and Conditional Access — two easily-misjudged defaults

Guest (external) users can be invited into a Basic plan's backing Microsoft 365 Group and, once in, have **broad default permissions**: create and delete tasks and buckets, edit task fields, and edit the plan name. Attaching a file or link to a task requires one additional permission grant beyond the guest default, but everything else is available out of the box. There is **no Planner-specific guest-permission model** narrower than this — any tightening has to happen at the Microsoft 365 Group's guest-access configuration, one layer up.

Conditional Access for the Planner **iOS/Android** apps has a similarly easy-to-miss dependency: CA is enforced on the Planner mobile apps **only if the same policy also targets Exchange Online or SharePoint Online**. A CA policy scoped to "Planner" alone, with neither of those two cloud apps included, will not be enforced on the mobile clients — a gap that surfaces almost exclusively during security reviews rather than day-to-day user complaints, since the policy silently doesn't apply rather than erroring.

### Storage and data residency by feature

| Feature | Storage | Notes |
|---|---|---|
| To Do / Outlook tasks | Exchange (mailbox) | Not Planner-specific storage at all |
| Basic plan + task metadata | Azure | Microsoft-managed, not customer-visible/configurable storage |
| Basic plan task attachments | SharePoint (the backing Group's site) | Counts against normal SharePoint storage quota |
| Premium plan + task data | Dataverse | Counts against the hosting Environment's Dataverse database capacity |

Compliance capability (eDiscovery, Auditing) differs by which of these backends holds the content in question — Purview coverage for Exchange- and SharePoint-resident content is mature and standard; Dataverse-resident Premium plan content follows Power Platform's own compliance/audit surface, a materially different investigative path than a typical SharePoint/Exchange-scoped case.

### The naming history, and the two retirements that are not the same event

This topic accumulates confusion because Microsoft has renamed and consolidated the same underlying capability several times, and because two genuinely separate retirement announcements land close together in the news cycle:

- **April 2024:** the "Tasks by Planner and To Do" app in Teams was renamed **Planner**, becoming the unified experience described throughout this runbook.
- **September 2024:** **Project Plan 1** was renamed **Planner Plan 1**; **Project Plan 3/5** were renamed **Planner and Project Plan 3/5** — a licensing SKU rename with no functional change.
- **August 2025:** the **standalone Project for the web app** (its own dedicated UI, separate from Planner) was retired. Existing Premium plans, all licensing, and all data moved into the unified Planner experience **automatically, with no migration and no license change required**. If a client asks about "Project for the web going away," this is almost certainly what they read about, and the honest answer is that it already happened over a year prior to this runbook's writing with zero required action.
- **September 30, 2026 (upcoming):** **Project Online** — a fundamentally different, SharePoint-based Project Web App (PWA) product with no shared architecture, licensing, or admin surface with Planner or Dataverse-based Project for the web — retires fully. New PWA site creation was already blocked as of April 1, 2026; SharePoint 2013 workflows powering Project Online governance broke April 2, 2026. **This one requires an actual, time-boxed migration** for any tenant with active Project Online usage — Microsoft's own guidance points customers toward Planner Premium, Project Server Subscription Edition, or Dynamics 365 Project Operations depending on need, explicitly noting that Planner Premium is **not a like-for-like replacement** for Project Online's portfolio governance, resource leveling, and financial tracking capabilities.

Given this runbook's research date is roughly six weeks before the Project Online cutoff, any client with confirmed active Project Online usage should be treated as a live, time-sensitive migration risk — not a routine Planner support matter.

---
## Dependency Stack

```
Microsoft 365 tenant with a Planner-inclusive subscription
    │
    ▼
Licensing layer — TWO independent license tracks
    ├── BASIC plans: PROJECTWORKMANAGEMENT service plan (included in most
    │     standard M365 SKUs — Business Basic/Standard, O365/M365 E1/E3/E5, A1)
    └── PREMIUM plans: PROJECT_P1 (Planner Plan 1) or PROJECT_PROFESSIONAL
          (Planner and Project Plan 3/5) service plans — NOT included by
          default in standard SKUs, must be separately licensed/assigned
    │
    ▼
Tenant admin control layer — THREE INDEPENDENT SURFACES, none a superset of another
    ├── BASIC: PowerShell (non-standard PlannerTenantAdmin module, MSAL.PS
    │     dependency, Global Admin only)
    │       ├── Set-PlannerConfiguration -IsPlannerAllowed
    │       ├── Set-PlannerConfiguration -AllowRosterCreation
    │       ├── Set-PlannerConfiguration -AllowCalendarSharing
    │       └── Set-PlannerUserPolicy -BlockDeleteTasksNotCreatedBySelf (per-user)
    ├── PREMIUM: Microsoft 365 admin center → Settings → Org Settings → Project
    │       (NO PowerShell/Graph/CLI equivalent for the org-wide toggle;
    │        per-user control via PROJECT_P1/PROJECT_PROFESSIONAL service
    │        plan removal instead)
    └── LOOP COMPONENT (either plan type, embedded view): Cloud Policy
          (config.office.com) — see M365/Loop/Loop-A.md
    │
    ▼
Container/backend layer — WHERE each plan type lives determines everything downstream
    ├── BASIC → Microsoft 365 Group (gated by Entra ID Group.Unified creation
    │     policy) OR groupless Roster container (self-deletes when empty)
    │       ├── Plan/task metadata → Azure
    │       └── Attachments → SharePoint (Group's site)
    └── PREMIUM → Dataverse record, inside a Power Platform Environment
          ├── Default Environment: 1 license sufficient to provision
          ├── Production environment: ≥5 licenses required
          ├── HARD CONFLICT: environment can't have "Enable D365 Apps" on
          │     if Project needs to deploy there
          └── Access control: customizable "Project Team Member" Dataverse
                security role (separate from Planner's own sharing model)
    │
    ▼
Guest/external access (Basic plans only) — broad by default at the Group
    layer; no Planner-specific narrower guest model exists
    │
    ▼
Conditional Access (mobile apps) — enforced ONLY if the same CA policy also
    targets Exchange Online or SharePoint Online; scoping to "Planner" alone
    is not sufficient
    │
    ▼
Compliance/Purview surface — SPLIT BY BACKEND
    ├── Exchange-resident (To Do/Outlook tasks) → standard Exchange Purview coverage
    ├── SharePoint-resident (Basic plan attachments) → standard SharePoint Purview coverage
    └── Dataverse-resident (Premium plans) → Power Platform's own compliance/audit surface
    │
    ▼
ADJACENT, ARCHITECTURALLY UNRELATED PRODUCT (do not conflate):
Project Online (SharePoint-based PWA) — retiring September 30, 2026, real
    migration required; zero shared infrastructure, licensing, or admin
    surface with anything above
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `Set-PlannerConfiguration`/`Get-PlannerConfiguration` not found | Non-standard module not installed/imported; not a Graph/EXO/SPO module | `Get-Command Get-PlannerConfiguration`, then Fix/Playbook 1 setup |
| Disabled Basic Planner, Premium plans still work | Two separate switches — Basic PowerShell vs. Premium M365 admin center toggle | `Get-PlannerConfiguration` (Basic only) + M365 admin center Project settings |
| Premium license assigned, user still can't build Timeline/Gantt plans | Service plan disabled independently of SKU, or Dataverse environment/D365-Apps conflict | `Get-MgUserLicenseDetail`, then Power Platform admin center |
| Premium plan creation silently fails for a licensed user | Target environment has "Enable D365 Apps" on, or Production-environment license minimum (5) not met | Power Platform admin center → Environments |
| User can access a Premium plan's app but not a specific project's data | Project Team Member Dataverse security role narrowed from default | Power Platform admin center → Security roles |
| Removed a Planner license, user still edits existing plans | `planner.cloud.microsoft` has no full-lockout mechanism for existing content | Confirm Group membership as a parallel, more complete control |
| Disabled Roster creation, existing Rosters still function | Setting only blocks new Roster creation, not existing ones | `Get-PlannerConfiguration` confirms `AllowRosterCreation`, not retroactive |
| A shared Roster plan disappeared without warning | Expected — Roster self-deletes when its last member is removed | Confirm via offboarding/membership change timeline, not a bug report |
| Guest edited/deleted tasks unexpectedly | Basic-plan guest defaults are broad by design | Confirm via Group guest-access settings, not a Planner permission bug |
| CA policy scoped to "Planner" not enforced on mobile | CA for Planner mobile requires Exchange or SharePoint also targeted on the same policy | Confirm CA policy's cloud-app targeting list |
| Client alarmed about a "Planner shutdown" | Almost certainly Project Online (real, Sept 30 2026) confused with Project for the web (already retired Aug 2025, no action needed) | Identify the specific product the client actually read about |
| Roadmap connector missing from Power Platform DLP policy UI | Known gap — `shared_projectroadmap` doesn't reliably surface in the DLP policy GUI | `Add-CustomConnectorToPolicy` via PowerApps Administrator module |
| Security review flags unauthenticated Planner calendar-sync links | Expected — iCalendar links carry no authentication by design | `Set-PlannerConfiguration -AllowCalendarSharing $false` if unacceptable |
| Custom Power App/Power BI report against Project data fails for a user | Missing separate Power Apps/Power BI license — Planner Plan 1/3/5 alone doesn't cover custom-artifact consumption | Confirm the user's license bundle includes the specific Power Platform product license |

---
## Validation Steps

1. **Confirm which product (Basic vs. Premium) the ticket concerns before choosing a validation path.**
   Check for Timeline/People/Goals views (Premium-only) vs. Grid/Board/Schedule/Charts (both).
   Expected: unambiguous once the specific views in question are identified.

2. **Confirm the Basic-plan PowerShell tooling is actually loaded.**
   ```powershell
   Get-Command Get-PlannerConfiguration -ErrorAction SilentlyContinue
   Get-PlannerConfiguration
   ```
   Expected: resolves and returns `IsPlannerAllowed`, `AllowRosterCreation`, `AllowCalendarSharing`.

3. **Confirm Premium-plan license state at the service-plan level, not the SKU level.**
   ```powershell
   Get-MgUserLicenseDetail -UserId <UPN> | Select-Object -ExpandProperty ServicePlans |
       Where-Object ServicePlanName -match "PROJECT_P1|PROJECT_PROFESSIONAL"
   ```
   Expected: `ProvisioningStatus: Success` for the relevant plan.

4. **Confirm the Dataverse environment layer for Premium-plan creation issues.**
   Power Platform admin center → Environments → target environment → confirm existence, active state, "Enable D365 Apps" state, and license count against the Production-environment minimum (5) if applicable.
   Expected: environment present, D365 Apps off (if Project needs to deploy there), license count sufficient.

5. **Confirm the Premium org-wide toggle manually — no PowerShell substitute exists.**
   Microsoft 365 admin center → Settings → Org Settings → Project.
   Expected: "Turn on Project for the web for your organization" and "Turn on Roadmap for your organization" reflect the intended state (these are two separate checkboxes).

6. **Confirm CA enforcement scope for any Planner-mobile-specific complaint.**
   Review the CA policy's target cloud apps list; confirm Exchange Online or SharePoint Online is included alongside (or instead of) a Planner-specific target.
   Expected: at least one of Exchange/SharePoint is present if mobile enforcement is required.

7. **For any "is Planner going away" concern, confirm the specific product before responding.**
   Ask which article/announcement prompted the question; check for active Project Online usage in the tenant (PWA site presence) versus Premium/Dataverse-backed Planner usage.
   Expected: a definitive answer naming the correct product and its actual timeline.

---
## Troubleshooting Steps (by phase)

### Phase 1: Scope the Complaint
1. Determine Basic vs. Premium plan involvement from the views/features described.
2. Determine whether the complaint is about plan **access/creation**, **content behavior** (guests, calendar sync, task deletion), or a **licensing/retirement** question — each routes to a different phase below.

### Phase 2: Admin-Surface Investigation
1. For Basic-plan issues: confirm the `PlannerTenantAdmin` module is loaded and query `Get-PlannerConfiguration`.
2. For Premium-plan issues: confirm the M365 admin center Project settings page state manually (no scriptable check exists).
3. For Loop-component-embedding issues: defer to `M365/Loop/Loop-A.md`'s Cloud Policy investigation flow.

### Phase 3: Licensing Investigation (Premium-specific)
1. Confirm `PROJECT_P1`/`PROJECT_PROFESSIONAL` service plan state at the individual-plan level, not just SKU assignment.
2. Distinguish "no Premium license at all" from "licensed but service plan independently disabled" — these produce different remediation paths.

### Phase 4: Power Platform/Dataverse Investigation (Premium-specific)
1. Confirm the target environment exists and is active.
2. Confirm "Enable D365 Apps" state on that environment.
3. Confirm license count against Default vs. Production environment minimums.
4. If access-within-a-project (not creation) is the issue, check the Project Team Member security role.

### Phase 5: Group/Container Investigation (Basic-specific)
1. Confirm whether the plan is Group-backed or Roster-backed.
2. For Group-backed plans, cross-reference Entra ID's Group creation/guest-access policies rather than searching for a Planner-specific equivalent that doesn't exist.
3. For Roster-backed plans, confirm membership changes as the likely explanation for unexpected disappearance (self-deletion on last-member removal).

### Phase 6: Retirement/Licensing-Confusion Triage
1. If the ticket concerns a Microsoft retirement announcement, identify by name which product is meant before responding: Project Online (real, imminent, needs migration) vs. Project for the web (already completed, folded into Planner, no action needed).
2. If Project Online usage is confirmed active, escalate to a migration-scoping conversation immediately — do not treat as a standard support ticket given the proximity to the September 30, 2026 cutoff.

### Phase 7: Escalation
1. Package the Evidence Pack output below.
2. Escalate genuine Power Platform environment conflicts (D365 Apps toggle, license minimums) to a Power Platform administrator rather than Planner support channels — these are Power Platform admin-center configuration items, not Planner bugs.
3. Escalate confirmed Project Online migration needs as their own scoped engagement, not a Planner ticket.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Stand up Basic-plan tenant PowerShell administration from scratch</summary>

**When to use:** First-time setup of `Set-PlannerConfiguration`/`Set-PlannerUserPolicy` tooling for a tenant, or troubleshooting why it was never configured.

1. Confirm Global Administrator sign-in is available for the session — no lower-privilege role works for these cmdlets.
2. Install the `MSAL.PS` dependency if not already present:
   ```powershell
   Install-Module -Name MSAL.PS -Scope CurrentUser
   ```
3. Download the Planner Tenant Admin PowerShell package from the official Microsoft Learn prerequisites article and unzip it locally.
4. Unblock the `.psm1` file (`Unblock-File -Path .\PlannerTenantAdmin.psm1` or via file Properties → Unblock).
5. Relax execution policy for the session only, then import by explicit path:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process
   Import-Module "C:\AdminScript\PlannerTenantAdmin.psm1"
   ```
6. Validate with a read-only call before making any changes:
   ```powershell
   Get-PlannerConfiguration
   ```
7. Document the local file path used for `Import-Module` in the organization's admin runbook — this tooling has to be re-staged on every new admin workstation, unlike a PowerShell Gallery module that installs by name.

**Rollback:** N/A — tooling setup only, no tenant configuration change.

</details>

<details><summary>Playbook 2 — Reconcile a tenant where Basic and Premium plans are in inconsistent states</summary>

**When to use:** An audit or client handoff reveals Basic plans are disabled but Premium plans are still fully active (or vice versa), and the intended state needs to be established and enforced consistently.

1. Determine the intended end-state per product independently — do not assume "Planner should be off" means the same configuration action for both.
2. Set the Basic-plan state:
   ```powershell
   Set-PlannerConfiguration -IsPlannerAllowed $true    # or $false
   Set-PlannerConfiguration -AllowRosterCreation $true  # or $false
   Set-PlannerConfiguration -AllowCalendarSharing $true # or $false
   ```
3. Set the Premium-plan state manually: Microsoft 365 admin center → Settings → Org Settings → Project → set both "Turn on Project for the web for your organization" and "Turn on Roadmap for your organization" independently — confirm both checkboxes reflect the intended state, since Roadmap does not automatically follow the main toggle in every tenant.
4. Set the Planner Loop component state via Cloud Policy at `config.office.com` if that surface is also in scope — see `M365/Loop/Loop-A.md`.
5. Document all three states together in the client's admin runbook as a single "Planner posture" record — the three-switch structure is easy for a future admin to rediscover the hard way otherwise.
6. Validate with a test user across each surface (Basic plan creation, Premium plan creation, Loop-embedded plan view) individually.

**Rollback:** Revert each of the three switches to its prior recorded state independently.

</details>

<details><summary>Playbook 3 — Provision Premium (Project for the web) capability into a Production Dataverse environment</summary>

**When to use:** An organization needs Premium Planner plans deployed into a specific Production environment rather than relying on the auto-provisioned Default Environment (common for organizations with existing Power Platform environment segmentation).

1. Confirm license count meets the **5-license minimum** required for Production-environment provisioning — Default Environment provisioning needs only 1, so this is a common trap when moving from a pilot to a full rollout.
2. Confirm the target environment's **"Enable D365 Apps"** toggle is **off**. If the environment already hosts (or is planned to host) Dynamics 365 Sales, Project Operations, or similar D365 apps, Project cannot coexist there — select or provision a different environment instead.
3. Have a licensed user open Project/Planner Premium against the target environment to trigger auto-deployment of the Power App.
4. Confirm the **Project Team Member** Dataverse security role reflects the intended access model for the organization — review and customize it explicitly rather than accepting the default if fine-grained control is a requirement, since this role governs Dataverse-level access independent of anything configured inside Planner's own sharing UI.
5. If custom Power Apps or Power BI reporting against Project tables is planned, confirm those users hold the required separate Power Apps/Power BI licenses in addition to their Planner Plan 1/3/5 license.
6. Document the environment name and its relationship to Premium Planner explicitly for future Power Platform administrators — Premium Planner's presence in a given environment is not obvious from the environment list alone without this context.

**Rollback:** N/A — provisioning action; removing Premium licenses from users does not retroactively remove already-created Dataverse records, which require separate data-cleanup handling if a full reversal is needed.

</details>

<details><summary>Playbook 4 — Client engagement triage: confirm and scope a Project Online migration before the September 30, 2026 retirement</summary>

**When to use:** Any client engagement where Project Online usage is suspected or confirmed, given the imminent hard cutoff.

1. Confirm active usage definitively — locate the tenant's Project Web App (PWA) site collection(s) (typically `https://<tenant>.sharepoint.com/sites/<pwaSiteName>`) and confirm recent activity, not just historical existence.
2. Set the client's expectations immediately and explicitly: this is **not** a Planner Premium upgrade path — Planner Premium is not a like-for-like replacement for Project Online's portfolio governance, resource leveling, or financial tracking. Point toward the specific alternative that matches the client's actual usage pattern: Planner Premium (lightweight project/task coordination), Project Server Subscription Edition (on-premises-style PWA continuity), or Dynamics 365 Project Operations (full financial/resourcing portfolio management).
3. Confirm awareness of interim deadlines already in effect as of this runbook's research date: new PWA site creation blocked since April 1, 2026; SharePoint 2013 workflows powering Project Online governance broken since April 2, 2026.
4. Scope data export/migration work as its own time-boxed project, not a routine support ticket — commonly-cited migration timelines run around twelve weeks, which needs to be weighed directly against the September 30, 2026 hard cutoff from the engagement's start date.
5. Confirm turning off Project for the web/Premium Planner (if also in scope for unrelated reasons) has **no effect** on the Project Online migration timeline or vice versa — keep the two workstreams administratively and communicably separate throughout the engagement.

**Rollback:** N/A — engagement scoping and client communication, no configuration change performed under this playbook itself.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Planner-relevant configuration evidence for escalation.
.NOTES     Read-only. Requires the PlannerTenantAdmin module loaded (Basic-plan settings)
           and Microsoft Graph PowerShell connected (Connect-MgGraph, licensing checks).
           The Premium-plan org-wide toggle has no PowerShell equivalent and must be
           captured manually from the Microsoft 365 admin center and pasted into the report.
           See Scripts/Get-PlannerAdminAudit.ps1 for the full, documented tenant-wide
           version with CSV export and explicit gap reporting.
#>
$evidence = [System.Collections.Generic.List[string]]::new()

$evidence.Add("=== Basic-Plan Tenant Configuration ===")
$evidence.Add((Get-PlannerConfiguration | Out-String))

$evidence.Add("=== Affected User License/Service-Plan State ===")
$evidence.Add((Get-MgUserLicenseDetail -UserId $UserPrincipalName |
    Select-Object SkuPartNumber -ExpandProperty ServicePlans |
    Where-Object ServicePlanName -match "PROJECTWORKMANAGEMENT|PROJECT_P1|PROJECT_PROFESSIONAL" |
    Out-String))

$evidence.Add("=== Affected User's Planner User Policy ===")
$evidence.Add((Get-PlannerUserPolicy -UserAadIdOrPrincipalName $UserPrincipalName | Out-String))

$evidence.Add("=== MANUAL: Premium (Project for the web) org-wide toggle from M365 admin center ===")
$evidence.Add("Turn on Project for the web for your organization: <fill in>")
$evidence.Add("Turn on Roadmap for your organization: <fill in>")

$evidence.Add("=== MANUAL: Dataverse environment state from Power Platform admin center (Premium issues only) ===")
$evidence.Add("Target environment name: <fill in>")
$evidence.Add("Enable D365 Apps toggle state: <fill in>")
$evidence.Add("Licensed Project users assignable to this environment: <fill in>")

$evidence | Out-File -FilePath ".\Planner-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check Basic-plan tenant configuration | `Get-PlannerConfiguration` |
| Disable/enable Basic plans tenant-wide | `Set-PlannerConfiguration -IsPlannerAllowed $false\|$true` |
| Disable/enable new Roster creation | `Set-PlannerConfiguration -AllowRosterCreation $false\|$true` |
| Disable/enable Outlook calendar sync (iCalendar links) | `Set-PlannerConfiguration -AllowCalendarSharing $false\|$true` |
| Block a user from deleting tasks they didn't create | `Set-PlannerUserPolicy -UserAadIdOrPrincipalName <UPN> -BlockDeleteTasksNotCreatedBySelf $true` |
| Check a user's Planner user policy | `Get-PlannerUserPolicy -UserAadIdOrPrincipalName <UPN>` |
| Check a user's Planner/Project service-plan state | `Get-MgUserLicenseDetail -UserId <UPN> \| Select -ExpandProperty ServicePlans` |
| Disable a specific service plan while keeping the SKU | `Set-MgUserLicense -UserId <UPN> -AddLicenses @{SkuId="<id>";DisabledPlans=@("<planId>")}` |
| List/query Basic or Premium plans via Graph | `Get-MgPlannerPlan`, `New-MgPlannerPlan`, `Remove-MgPlannerPlan` |
| Add the Project Roadmap connector to a Power Platform DLP policy | `Add-CustomConnectorToPolicy -PolicyName <name> -ConnectorId '/providers/Microsoft.PowerApps/apis/shared_projectroadmap' -GroupName hbi -ConnectorName "Project Roadmap"` |
| Premium org-wide toggle (no PowerShell) | M365 admin center → Settings → Org Settings → Project |
| Dataverse environment management (no PowerShell shortcut covers all of this reliably) | `admin.powerplatform.microsoft.com` → Environments |
| Planner Loop component policy (no PowerShell) | `https://config.office.com` → "View and edit Planner plans with the Planner Loop component" |

---
## 🎓 Learning Pointers

- **"Planner" is one brand wrapped around two structurally different products, each with its own license, storage backend, and admin surface — and neither admin surface is a superset of the other.** Basic plans (PowerShell) and Premium plans (M365 admin center, no PowerShell) must be reasoned about, configured, and documented independently. See [Microsoft Planner for admins](https://learn.microsoft.com/en-us/planner/planner-for-admins).

- **The Basic-plan PowerShell tooling breaks the pattern every other topic in this repository follows** — it's a manually-downloaded ZIP module with an `MSAL.PS` dependency and a Global-Administrator-only requirement, not a discoverable Gallery module. Budget setup time for this the first time a client engagement needs it. See [Prerequisites for making Planner changes in Windows PowerShell](https://learn.microsoft.com/en-us/planner/prerequisites-for-powershell).

- **Premium Planner's Dataverse dependency pulls Power Platform environment administration into what looks like a pure task-management feature.** The "Enable D365 Apps" conflict and the Default-vs-Production licensing minimums are genuine, non-obvious failure points that live entirely outside Planner's own settings and require Power Platform admin-center access to diagnose. See [Frequently Asked Questions - Project for the web](https://learn.microsoft.com/en-us/project-for-the-web/faq).

- **Project Online and Project for the web are unrelated products under the hood, despite sharing "Project" in the name, and their retirement timelines are not the same event.** Project for the web was folded into Planner in August 2025 with zero required action; Project Online retires September 30, 2026 and requires a genuine, time-boxed migration. Getting this distinction right — and confirming which one a client is actually asking about — prevents both unwarranted panic and, more dangerously, missed migration deadlines. See [Turn Project for the web or Roadmap on or off](https://learn.microsoft.com/en-us/project-for-the-web/turn-project-for-the-web-off).

- **Removing a user's Planner license does not fully revoke their access to already-existing plans** — `planner.cloud.microsoft` currently has no supported full-lockout mechanism for content a user can already reach directly. Group membership removal is a more complete control for Basic plans than license removal alone. See [Frequently asked questions for admins about Microsoft Planner](https://learn.microsoft.com/en-us/planner/faq-for-planner-admins).

- **Guest permissions and mobile Conditional Access both have non-obvious, easy-to-misjudge defaults that aren't configurable from inside Planner itself.** Guest access breadth is a Microsoft 365 Group setting; CA enforcement on mobile requires Exchange or SharePoint to also be targeted on the same policy. Neither has a Planner-native lever to pull. See [Frequently asked questions for admins about Microsoft Planner](https://learn.microsoft.com/en-us/planner/faq-for-planner-admins).
