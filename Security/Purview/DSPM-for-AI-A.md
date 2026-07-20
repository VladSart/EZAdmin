# Microsoft Purview DSPM for AI — Reference Runbook (Mode A: Deep Dive)
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
- Microsoft Purview **Data Security Posture Management (DSPM)** — the current, unified solution (2026) that merged the former standalone **DSPM for AI** and general-purpose **DSPM** into one Objectives-driven experience
- The two now-classic predecessor experiences (**DSPM for AI (classic)**, **DSPM (classic)**) — still functional, frozen, no new features — enough to recognize which one a client is actually looking at and route accordingly
- Data risk assessments (default and custom) for oversharing detection across SharePoint/OneDrive and Fabric, including the item-level scanning and Fabric prerequisite app-registration chains
- The one-click default policy set DSPM creates across DLP, Insider Risk Management, Communication Compliance, and Collection policies, and where each is actually owned/edited
- The role model gating DSPM access, with particular attention to the separately-gated AI interaction content-visibility permission
- AI observability, Asset explorer, and the Objectives workflow model introduced in the current version

**Out of scope (see cross-references):**
- Base Microsoft 365 Copilot licensing, tenant/app enablement, and Conditional Access for Copilot itself — see `M365/Copilot/Copilot-A.md`/`-B.md` (this runbook assumes Copilot works; DSPM observes and governs its data exposure, it doesn't gate Copilot's own functioning)
- Agent lifecycle governance (Registry, approval/publish workflows for individual Copilot agents) — see `M365/Copilot/AgentGovernance-A.md`/`-B.md` (DSPM's **AI observability** and **Asset explorer** surface agent risk signal; agent lifecycle/ownership approval is a separate admin surface)
- DLP policy authoring mechanics in general — see `DLP-Policy-A.md`/`-B.md` (this runbook covers DSPM's own DLP-owned default policies only insofar as they relate to AI oversharing/exfiltration)
- Sensitivity label architecture and publishing — see `Sensitivity-Labels-A.md`/`-B.md`
- Insider Risk Management policy authoring and Adaptive Protection's own risk-level mechanics — see `Insider-Risk-A.md`/`-B.md` and `AdaptiveProtection-A.md`/`-B.md` (DSPM's default policies frequently create or depend on these; this runbook covers the DSPM-side trigger, not the underlying engine)
- Communication Compliance investigation/remediation workflow — see (if present) the Communication Compliance runbook; this file covers only the DSPM-created default policy that feeds it
- Unified Audit Log internals — see `Audit-A.md`/`-B.md` (this runbook treats Audit as a binary prerequisite gate)
- Microsoft Purview Compliance Manager scoring — see `ComplianceManager-A.md`/`-B.md` (a separate read/scoring layer; DSPM and Compliance Manager both consume signal from the same underlying features but serve different purposes — DSPM for operational data-security action, Compliance Manager for regulatory scoring)

**Assumes:**
- Microsoft Purview portal access (`purview.microsoft.com`) with at least one of: Entra Compliance Administrator, Entra Global Administrator, or Purview Compliance Administrator role group
- Microsoft Graph PowerShell SDK (`Microsoft.Graph`) for any Graph-based evidence collection — DSPM itself has **no dedicated PowerShell/API cmdlet surface**; its state is portal/API-only, so this runbook diagnoses via the adjacent Purview features (DLP, Audit, licensing, sensitivity labels) whose state DSPM reads and acts through
- Tenant has Microsoft 365 Copilot and/or other AI app usage the client wants visibility into or protection from

---
## How It Works

### The 2026 convergence — why "DSPM for AI" now means two different things

Microsoft originally shipped two adjacent-but-separate solutions: **DSPM for AI** (AI-specific: Copilot/agent oversharing, prompt/response monitoring, AI site DLP) and general-purpose **DSPM** (broader data security posture across Microsoft 365, Azure, Fabric, and — via partner integration — third-party SaaS/IaaS). In 2026 Microsoft converged both into a single **Data Security Posture Management** solution built around **Data security objectives** rather than separate per-product dashboards. The two originals did not get deleted or auto-migrated — they persist as **DSPM for AI (classic)** and **DSPM (classic)**, fully functional, but explicitly frozen: "most new features will be added to this version only" (the current one). This is the single most important fact for anyone supporting a client on this topic in 2026: **the same words ("DSPM", "DSPM for AI") now correctly refer to three distinct, simultaneously-live experiences** (current unified, DSPM for AI classic, DSPM classic), and documentation, training material, and screenshots written before the convergence describe the classic experience, not the current one.

```
Microsoft Purview portal → Solutions
    │
    ├── DSPM (current, unified — 2026+)
    │       Objectives-driven: Posture / Objectives / AI observability / Asset explorer / Reports / Setup tasks
    │       Receives ALL new feature development going forward
    │
    ├── DSPM for AI (classic)
    │       AI-specific predecessor: Overview / Reports / Policies / Apps and agents / Activity explorer /
    │       Data risk assessments — frozen, fully functional, no new capability
    │
    └── DSPM (classic)
            General-purpose predecessor — frozen, fully functional, no new capability
```

### The Objectives model (current version)

Rather than navigating to separate solution areas, the current DSPM organizes work around **Data security objectives** — outcome-oriented workflows, each bundling the relevant Purview solutions (DLP, Insider Risk Management, Information Protection, eDiscovery) behind one guided flow:

- **Prevent data exposure in Microsoft 365 Copilot and Microsoft Copilot interactions**
- **Prevent oversharing of sensitive data**
- **Prevent exfiltration to risky locations**
- **Discover sensitive data in your organization**

Each objective surfaces an **Outcome** card with live metrics (percentage of data covered by policy, count of risky sharing incidents, trend over time), a prioritized action list (apply labels, configure DLP, investigate alerts), and the ability to act directly from the workflow rather than navigating to each underlying solution separately. Reporting is likewise organized by objective. The **Prevent exfiltration to risky destinations** objective additionally integrates with **Data Security Investigations**: when enabled, DSPM auto-creates and continuously refreshes an investigation analyzing recently exfiltrated sensitive data across five risk categories, surfacing risk counts directly on the objective card without the analyst manually starting an investigation.

DSPM's AI integration runs in both directions: it **secures AI** (the objectives above), and it **uses AI to secure** — Microsoft Security Copilot and Purview AI agents analyze access patterns, sharing behavior, and policy gaps inside DSPM itself, can propose or (with review/approval) directly execute remediation such as removing a public sharing link or applying a DLP policy, and every such action is audited. This is opt-in and reviewable, not autonomous-by-default.

### Data risk assessments — the oversharing detection engine

Generative AI's core oversharing risk isn't a new access-control flaw; it's that AI can **proactively surface** content a human would have had to manually search for, at speed, across everything a user's existing permissions already reach. Content that was technically accessible but practically obscure (an old, over-permissioned SharePoint site nobody remembered) becomes a live, easily-discovered risk the moment Copilot can summarize it. Data risk assessments exist specifically to find this **before** a Copilot rollout amplifies it, not just audit it after the fact.

- **Default assessment**: runs automatically, weekly, against the **top 100 SharePoint sites by usage** — no configuration needed, but a **~4-day delay** before the first results appear.
- **Custom assessment (Microsoft 365 tab)**: scoped to specific users/sites, two scan levels:
  - **Basic** — standard scan, no extra authentication.
  - **Item-level** — identifies items with sharing links for external/anonymous users at the individual-file level, shows applied sensitivity label and owner, and supports direct remediation actions (Resolve, Apply sensitivity label, Notify owner, Remove sharing link). Requires a **one-time Entra app registration** with specific Graph application permissions (see Dependency Stack) and admin consent — this authentication step is the most common real-world setup failure in this entire topic.
  - Hard limits: 200,000 items per location cap (file count becomes unreliable above ~100,000/location), **OneDrive is not supported for item-level scanning**, and a current maximum of **10 SharePoint sites** per item-level assessment.
  - Results take ~48 hours to stabilize and expire after 30 days — use **Duplicate** to re-run with the same scope rather than expecting an in-place refresh.
- **Custom assessment (Fabric tab)**: identifies oversharing in Fabric workspaces. Requires a **separate, independent** Entra app registration authenticated as a Fabric admin-API service principal (federated credential recommended over client secret), added to a security group, with a **Fabric Administrator** (not a Purview role) enabling both read-only and update admin-API access for that group in the Fabric admin portal's tenant settings. This prerequisite chain shares no components with the Microsoft 365 item-level scanning app above — building one does not help configure the other.

### One-click default policies — DSPM creates them, but never owns them

On first use (and via ongoing recommendations), DSPM creates a set of default policies across four **owning** solutions. DSPM's own **Policies** page is a dashboard for monitoring and quick-navigation only — every edit happens in the owning solution:

| Policy type | Owning solution | Example |
|---|---|---|
| DLP policy | Data Loss Prevention | `DSPM for AI - Block sensitive info from AI sites`, `DSPM for AI - Protect sensitive data from Copilot processing` |
| Insider Risk Management policy | Insider Risk Management | `DSPM for AI - Detect risky AI usage`, `DSPM for AI - Detect when users visit AI sites` |
| Communication Compliance policy | Communication Compliance | `DSPM for AI - Unethical behavior in AI apps` |
| Collection policy | Collection policies solution | `DSPM for AI - Capture interactions for Copilot experiences`, `DSPM for AI - Detect sensitive info shared with AI via network` |

Two details commonly cause confusion:
1. **Content capture on collection policies is opt-in and off by default** for several of these (notably the SASE/SSE network-detection policy) — the policy will show detection activity in reports with zero visible prompt/response text until content capture is explicitly enabled on the policy itself.
2. **Adaptive Protection auto-enablement**: DSPM's default policies that rely on Adaptive Protection turn it on automatically (with default risk levels for all users/groups) if it isn't already on — an org that never explicitly evaluated Adaptive Protection can find it live in their tenant purely as a side effect of accepting a DSPM recommendation. See `AdaptiveProtection-A.md` for what that engine then does with risk signal.
3. Any default policy created while this solution was in public preview (under its pre-launch name, **Microsoft Purview AI Hub**) permanently retains the **"Microsoft AI Hub -"** name prefix — Microsoft explicitly does not rename these retroactively.

### The role model — and the separately-gated content-visibility permission

DSPM access is governed by standard Purview roles (Entra Compliance Administrator / Global Administrator, or the Purview Compliance Administrator role group for full read/write; Purview Security Reader, Data Security Viewer, Entra AI Administrator, or Purview Data Security AI Viewer for view-only). The permissions matrix contains one load-bearing exception that trips up almost every first-time deployment: **holding any of the above roles — including full Compliance Administrator — does not by itself grant visibility into actual AI interaction prompt/response text.** Viewing that specific content requires the separate **Purview Data Security AI Content Viewer** role (or **Content Explorer Content Viewer**). This is a deliberate, privacy-conscious design decision (prompt/response content can be extremely sensitive), not an oversight — but it means "I have Compliance Administrator and still can't see the prompt text" is expected, correct behavior, not a bug, until the content-viewer role is separately granted.

### Where this fits alongside the rest of this folder

DSPM **consumes** signal from DLP, Insider Risk Management, Information Protection, and Data Security Investigations, and it **feeds** the AI-specific reporting/oversharing/exfiltration objectives on top of them — it does not replace or duplicate any of those engines' own configuration surfaces. Compliance Manager (`ComplianceManager-A.md`) is a parallel, separately-purposed read layer over much of the same underlying configuration, scoring it against regulatory assessment templates rather than surfacing it as operational remediation guidance — a client asking about "our AI compliance score" most likely means Compliance Manager; a client asking "what's overshared and who can see it" means DSPM.

---
## Dependency Stack

```
Microsoft Purview tenant + licensing
    │  (E5/Compliance-tier licensing broadens; base tiers still get core DSPM capability)
    ▼
Prerequisites (all independently gate what DSPM can observe or protect)
    ├── Microsoft Purview Audit — ON (default for new tenants; REQUIRED for all Copilot/agent
    │   activity insight, no retroactive backfill once enabled)
    ├── Microsoft 365 Copilot license — per user (gates Copilot/agent visibility for that user only)
    ├── Pay-as-you-go billing — tenant-level (gates Fabric Copilot, Security Copilot, Entra-registered
    │   AI apps, ChatGPT Enterprise — anything that isn't Copilot/Facilitator)
    ├── Microsoft Purview browser extension + device onboarding — per device (REQUIRED for
    │   third-party AI site visibility and Endpoint DLP on those sites)
    └── Edge configuration policy — tenant/device (REQUIRED to activate Purview integration in Edge)
    │
    ▼
Solution surface selection (client-visible; determines which docs/features apply)
    ├── DSPM (current, unified) — all new development
    ├── DSPM for AI (classic) — frozen
    └── DSPM (classic) — frozen
    │
    ▼
Objectives (current version only) — bundle underlying solutions behind guided workflows
    │
    ▼
Underlying owning solutions (DSPM creates/reads, never itself the system of record):
    ├── Data Loss Prevention           (DLP policies)
    ├── Insider Risk Management        (IRM policies; may auto-enable Adaptive Protection)
    ├── Communication Compliance       (unethical-behavior detection)
    ├── Collection policies solution   (prompt/response capture; content capture is opt-in per policy)
    └── Information Protection         (sensitivity labels / auto-labeling / DLP-by-label for Copilot)
    │
    ▼
Data risk assessments (oversharing detection)
    ├── Default (weekly, top 100 SharePoint sites, ~4-day first delay)
    ├── Custom M365 (Basic, or Item-level → REQUIRES Entra app: Application.Read.All,
    │   Directory.Read.All, Files.ReadWrite.All, SensitivityLabels.Read.All, Sites.ReadWrite.All,
    │   User.Read.All + admin consent; OneDrive unsupported; 10-site/200k-item caps)
    └── Custom Fabric (REQUIRES a SEPARATE Entra app as Fabric admin-API service principal +
        Fabric Administrator tenant-setting enablement — independent prerequisite chain)
    │
    ▼
Role-gated visibility
    ├── General view/manage roles (Compliance Administrator family, view-only family)
    └── AI interaction CONTENT visibility — SEPARATE gate: Purview Data Security AI Content Viewer
        or Content Explorer Content Viewer (not implied by any general role above)
    │
    ▼
Activity explorer / Reports / AI observability / Asset explorer (what the analyst actually sees)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Client describes a feature/screen not matching what they see | Client and engineer are looking at different DSPM surfaces (current vs. classic) | Confirm exact **Solutions →** navigation path |
| No Copilot/agent activity visible anywhere in DSPM | Purview Audit is disabled, or no Copilot license assigned | `Get-AdminAuditLogConfig`; `Get-MgSubscribedSku` |
| Reports/policies visible, but "AI interaction" events show no prompt/response text | Missing Purview Data Security AI Content Viewer role, OR content capture off on the collection policy | Check role assignment; check policy's content-capture setting |
| Fabric/Security Copilot activity not captured | No pay-as-you-go billing configured for the tenant | Check DSPM UI notifications under Setup tasks |
| Third-party AI site (ChatGPT/Gemini) visits invisible | Device not onboarded to Purview, or browser extension not deployed | Purview portal → device onboarding status |
| Endpoint DLP not blocking sensitive pastes into AI sites in Edge | Edge configuration policy for the Purview integration not deployed | Check managed Edge policy / group policy state |
| Default data risk assessment empty | Within the documented ~4-day first-run delay | Check assessment creation timestamp |
| Custom assessment stuck/empty after 48+ hours | Assessment scope resolved to zero matching items, or a genuine platform issue | Re-check scope; escalate if scope is confirmed non-empty |
| Item-level scan fails at Authenticate step | Entra app missing required Graph permissions or admin consent | Review app's API permissions blade |
| Fabric assessment "Set config" fails | Wrong/missing Entra app, or Fabric admin-API tenant setting not enabled for the app's security group | Fabric admin portal → Tenant settings → Admin API settings |
| Policy shows "Microsoft AI Hub -" prefix | Tenant enabled this solution during its public preview; prefix is permanent | No action — cosmetic |
| Adaptive Protection suddenly active, nobody configured it | A DSPM default policy that depends on Adaptive Protection auto-enabled it | `AdaptiveProtection-A.md` — check policy dependency chain |
| Score/metric mismatch between DSPM and Compliance Manager | Different tools, different purposes — DSPM is operational, Compliance Manager is regulatory scoring | Confirm which tool the client actually means |
| Sensitive info type detected but no user risk level shown in Activity explorer | Known product limitation — the Sensitive info types detected event never surfaces user risk level | Not a bug; cross-reference Insider Risk Management directly if risk level is needed |

---
## Validation Steps

1. **Confirm the solution surface.** Purview portal → Solutions → confirm whether the client means **DSPM**, **DSPM for AI (classic)**, or **DSPM (classic)**. Expected: unambiguous. Bad: client conflates two of them — resolve this before any other step.

2. **Confirm Audit.**
   ```powershell
   Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
   ```
   Expected: `True`. Bad: `False`.

3. **Confirm Copilot licensing for the affected user(s).**
   ```powershell
   Get-MgUserLicenseDetail -UserId <UPN> | Select-Object SkuPartNumber
   ```
   Expected: a Copilot SKU present. Bad: absent.

4. **Confirm the requester's DSPM role(s).**
   ```powershell
   Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<userObjectId>'" |
       Select-Object RoleDefinitionId
   ```
   Expected: Compliance Administrator/Global Administrator/Compliance Administrator role group for full access, or an appropriate view-only role. Bad: no recognized role.

5. **If content visibility is in question, confirm the AI Content Viewer role specifically** (Purview portal → Roles & scopes — not resolvable purely via the Entra role assignment check above, since this is a Purview-scoped role). Expected: role present when content visibility is required. Bad: absent.

6. **Confirm default policy presence and mode.**
   ```powershell
   Get-DlpCompliancePolicy | Where-Object { $_.Name -like "*DSPM for AI*" -or $_.Name -like "*Microsoft AI Hub*" } |
       Select-Object Name, Mode, Enabled
   ```
   Expected: expected default policies present and enabled/in the intended mode (test vs. enforce). Bad: missing or unexpectedly disabled.

7. **Confirm data risk assessment freshness.** Purview portal → DSPM → Discover → Data risk assessments → check **Last run**/creation timestamp against the ~4-day (default) or ~48-hour (custom) expected windows.

---
## Troubleshooting Steps (by phase)

### Phase 1: Surface & Prerequisite Confirmation
1. Confirm which DSPM surface is in play (current/classic-AI/classic-general).
2. Confirm Audit, Copilot licensing, and (if relevant) pay-as-you-go billing.
3. Confirm device onboarding + browser extension if third-party AI sites are involved.

### Phase 2: Role & Visibility Confirmation
1. Confirm the requester's general DSPM role.
2. If content visibility is the actual complaint, separately confirm the AI Content Viewer role — do not conflate this with general access troubleshooting.

### Phase 3: Policy-Level Investigation
1. Enumerate default DSPM-created policies across DLP/IRM/Communication Compliance/Collection and confirm each is in its owning solution's expected state.
2. For missing prompt/response content specifically, check the owning collection policy's content-capture setting before assuming a permissions issue.

### Phase 4: Data Risk Assessment Investigation
1. Identify assessment type (default/custom-M365-basic/custom-M365-item-level/Fabric).
2. For item-level or Fabric assessments, verify the correct, independent Entra app registration and its permission/consent state.
3. Check elapsed time against documented delays before treating an empty result as a fault.

### Phase 5: Cross-Feature Side Effects
1. If Adaptive Protection, sensitivity label auto-labeling, or Communication Compliance behavior changed unexpectedly, trace it back to a DSPM default-policy dependency before troubleshooting that feature in isolation.
2. Confirm the client isn't actually asking about Compliance Manager scoring under a similar-sounding name.

### Phase 6: Escalation
1. Package the Evidence Pack output below.
2. Escalate to Microsoft Support for genuine platform-side assessment/reporting failures once local prerequisites are fully confirmed.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield DSPM onboarding for a new client</summary>

1. Confirm Purview Audit is enabled (should be default-on; verify, don't assume for older tenants).
2. Confirm Microsoft 365 Copilot licensing is assigned to the intended user population.
3. Sign in to Purview portal → Solutions → **DSPM** (current version — do not start a new client on a classic surface).
4. Complete the **Getting Started** setup tasks (device onboarding, browser extension deployment, Edge configuration policy) relevant to the client's AI usage pattern (Microsoft 365 Copilot only vs. broader third-party AI site usage).
5. Review each **Objective** and decide, with the client, which to activate first — **Prevent oversharing of sensitive data** is the highest-value starting point ahead of any Copilot rollout, since it runs the default weekly SharePoint assessment automatically.
6. Assign the AI Content Viewer role deliberately and narrowly — decide up front who genuinely needs to see prompt/response content, rather than defaulting everyone with admin access into it.
7. Allow the documented delays (Audit ingestion, ~4-day default assessment, ~1 day for general reports) before declaring anything broken.

**Rollback:** Disabling DSPM itself isn't a supported concept — the underlying policies it created can each be individually disabled/deleted from their owning solution if the client decides against a specific control.

</details>

<details><summary>Playbook 2 — Pre-Copilot-rollout oversharing remediation</summary>

**When to use:** A client is about to license Microsoft 365 Copilot broadly and wants oversharing risk addressed first.

1. Run (or wait for) the default data risk assessment; supplement with a custom item-level assessment scoped to the highest-risk known sites (recently reorganized departments, legacy project sites, anything with a history of "share with anyone" links).
2. For each flagged site, review the **Identify** (scan coverage), **Protect** (remediation options), and **Monitor** (current sharing exposure) tabs.
3. Prioritize remediation in this order: (a) **Restrict access by label** for genuinely sensitive content that must stay locked from Copilot summarization, (b) **Apply sensitivity label** for correctly-scoped but unlabeled sensitive content, (c) **Remove sharing link** only for content confirmed as inappropriately exposed — this is the most disruptive option and should be last-resort per-item, not a bulk action.
4. Consider **Restrict all items** (SharePoint Restricted Content Discovery) for entire sites that should never be Copilot-discoverable regardless of individual item sensitivity (e.g., an HR site with mixed sensitive/non-sensitive content that isn't worth item-by-item labeling).
5. Re-run the assessment after remediation to confirm the exposure metrics actually improved before greenlighting the Copilot rollout.

**Rollback:** Sharing-link removals and restricted-content-discovery settings can be reversed from SharePoint site administration directly if a legitimate access need is broken by the remediation.

</details>

<details><summary>Playbook 3 — Migrating a client's mental model from classic to current DSPM</summary>

**When to use:** A client (or a newer engineer) trained on the classic experience needs to work in the current, unified one, or vice versa for legacy documentation reasons.

1. Use the [official task-mapping table](https://learn.microsoft.com/en-us/purview/dspm-task-mapping) rather than re-deriving navigation from memory — the mapping is non-obvious in places (e.g., "Apps and agents" exists in both versions but the current version's **AI observability** page is the one that includes Microsoft Agent 365, while **Discover → Apps and agents** in the current version explicitly does not).
2. Confirm no client-critical workflow depends on a classic-only quirk before recommending a full switch — in practice this is rare since the current version is a superset, but the two are not byte-for-byte identical in every corner (e.g., named report layouts differ).
3. Document which surface the client's team will use going forward in their engagement notes, since both remain simultaneously accessible and re-confusion is easy without an explicit decision on record.

**Rollback:** N/A — both experiences remain available regardless of which one is designated as "the one we use."

</details>

<details><summary>Playbook 4 — MSP fleet-wide DSPM readiness audit</summary>

**When to use:** An MSP wants a standing check across all managed tenants for DSPM prerequisite gaps before recommending Copilot expansion.

1. Run `Scripts/Get-DSPMforAIAudit.ps1` (per-tenant) to collect Audit status, Copilot/PAYG licensing signal, the presence and mode of default DSPM-named DLP/IRM/CommComp policies, and sensitivity label coverage as a proxy for oversharing readiness.
2. Cross-reference findings against each tenant's actual Copilot rollout status/timeline — flag any tenant with Copilot licenses assigned but Audit disabled or no default oversharing-relevant policies present as a priority follow-up.
3. Use results to prioritize Playbook 2 engagements ahead of, not after, each client's Copilot expansion.

**Rollback:** N/A — read-only audit.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects DSPM-relevant prerequisite and policy evidence for escalation or fleet audit.
.NOTES     Read-only. See Scripts/Get-DSPMforAIAudit.ps1 for the full, documented version with
           CSV export and multi-signal interpretation. This inline block is the minimal manual
           equivalent for a single quick escalation.
#>
$evidence = [System.Collections.Generic.List[string]]::new()

$evidence.Add("=== Audit ===")
$audit = Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
$evidence.Add(($audit | Out-String))

$evidence.Add("=== Copilot Licensing ===")
$evidence.Add((Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "Copilot" } |
    Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits | Out-String))

$evidence.Add("=== Default DSPM Policies (DLP) ===")
$evidence.Add((Get-DlpCompliancePolicy | Where-Object { $_.Name -like "*DSPM for AI*" -or $_.Name -like "*Microsoft AI Hub*" } |
    Select-Object Name, Mode, Enabled | Out-String))

$evidence | Out-File -FilePath ".\DSPM-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check Audit ingestion status | `Get-AdminAuditLogConfig \| Select-Object UnifiedAuditLogIngestionEnabled` |
| Enable Audit | `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true` |
| Check Copilot SKU consumption | `Get-MgSubscribedSku \| Where-Object { $_.SkuPartNumber -match "Copilot" }` |
| Check a specific user's licenses | `Get-MgUserLicenseDetail -UserId <UPN>` |
| List default DSPM DLP policies | `Get-DlpCompliancePolicy \| Where-Object { $_.Name -like "*DSPM for AI*" }` |
| Check a user's directory role assignments | `Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<id>'"` |
| List Insider Risk policies (module-dependent cmdlet name may vary by tenant) | `Get-InsiderRiskPolicy` |
| Check sensitivity labels published | `Get-Label \| Select-Object DisplayName, Priority` |
| List DLP compliance rules for a policy | `Get-DlpComplianceRule -Policy "<PolicyName>"` |
| Find Entra app registrations by display name | `Get-MgApplication -Filter "startswith(displayName,'<name>')"` |
| Check app registration's granted API permissions | `Get-MgServicePrincipal -Filter "appId eq '<appId>'" \| Get-MgServicePrincipalAppRoleAssignment` |

---
## 🎓 Learning Pointers

- **The 2026 DSPM/DSPM-for-AI convergence is the single most important fact to internalize for this topic.** Three simultaneously-live surfaces answer to overlapping names; all pre-convergence documentation, training, and screenshots describe the classic experience. Always confirm the exact navigation path before troubleshooting. See [Learn about Data Security Posture Management](https://learn.microsoft.com/en-us/purview/data-security-posture-management-learn-about) and the [task mapping reference](https://learn.microsoft.com/en-us/purview/dspm-task-mapping).

- **AI interaction content visibility is a separate gate from every general DSPM role, including Compliance Administrator.** This is a deliberate privacy control, not a bug — plan client access requests around it explicitly. See [Permissions for Data Security Posture Management](https://learn.microsoft.com/en-us/purview/data-security-posture-management-permissions).

- **Data risk assessments encode real, non-obvious delays** (~4 days default first-run, ~48 hours custom stabilization, 30-day custom expiration) — treat "no results yet" as expected behavior within these windows, not a fault to chase. See [Prevent oversharing with data risk assessments](https://learn.microsoft.com/en-us/purview/data-security-posture-management-oversharing).

- **Item-level (Microsoft 365) and Fabric data risk assessments each require their own, independent Entra app registration** with non-overlapping permission sets and different admin-role prerequisites to create — this is the most common real-world configuration failure in this topic, and the two are easy to conflate. See [Considerations for deploying DSPM for AI](https://learn.microsoft.com/en-us/purview/dspm-for-ai-considerations#prerequisites-for-fabric-data-risk-assessments).

- **DSPM's default policies can silently turn on Adaptive Protection** as a side effect of accepting a recommendation — an org that never deliberately evaluated Adaptive Protection can find it active purely through DSPM onboarding. Always check for this cross-feature dependency when Adaptive Protection behavior appears unexpectedly. See `AdaptiveProtection-A.md` and [Adaptive Protection quick setup](https://learn.microsoft.com/en-us/purview/insider-risk-management-adaptive-protection#quick-setup).

- **DSPM and Compliance Manager are not the same tool wearing different names**, despite both reading signal from the same underlying Purview features — DSPM is operational (what's overshared, who can see it, fix it now), Compliance Manager is regulatory scoring (how compliant are we against a named standard). Confirm which one a client actually means before routing a ticket. See `ComplianceManager-A.md`.
