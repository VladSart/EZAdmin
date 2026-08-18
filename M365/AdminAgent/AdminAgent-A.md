# Microsoft 365 Admin Agent — Reference Runbook (Mode A: Deep Dive)
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
- The Microsoft 365 Admin agent as a **first-party, Microsoft-built agentic tool for IT administrators** — its three access surfaces (Microsoft 365 Copilot Chat, Microsoft 365 admin center, and the SMB-scoped Microsoft Teams surface), licensing model, and cross-surface session continuity
- Its **RBAC-reflection architecture** — the agent has no standing privilege of its own; every action it can propose or perform is gated by the signed-in admin's existing Entra role assignments
- The **mandatory write/execute confirmation model** and what it does and doesn't guarantee
- The **six documented task categories** (users/licenses/groups, Copilot management, agent management, change management, help and support, Teams administration) and their representative capabilities
- **Governance** of the agent itself — how it's blocked, scoped, or restricted via the Agent Registry, and who is authorized to do so
- **Audit trail architecture** — where actions taken through the agent actually get logged, and why there is no dedicated agent-specific log
- **Data, privacy, and security posture** as it applies specifically to this agent, inherited from the broader Microsoft 365 Copilot commitments
- The **SMB-focused Teams surface** specifically — target audience, platform/cloud-instance constraints at GA, and how it differs architecturally (not functionally) from the Copilot Chat/admin center surfaces

**Out of scope (see cross-references):**
- **Agent lifecycle governance for the general Agent Registry** — approving/rejecting agent requests, assigning ownership, investigating at-risk or ownerless agents, and the distinct admin surfaces per creation platform (Copilot Studio, Agent Builder, SharePoint, Foundry) for **any** agent in the tenant, not just this one — see `Copilot/AgentGovernance-A.md`/`-B.md`. This runbook covers the Microsoft 365 Admin agent as a *consumer-facing IT tool*; that runbook covers the *control plane* governing every agent, including this one, at the Registry level
- Base Microsoft 365 Copilot licensing, tenant/per-app enablement, Conditional Access, and Graph grounding permission mechanics for Copilot generally — see `Copilot/Copilot-A.md`/`-B.md`
- Copilot Studio agent authoring, custom-engine agent development, or any agent-building mechanics — this runbook covers only a pre-built, Microsoft-managed agent
- Data oversharing risk assessment and AI-interaction content monitoring at the tenant level (DSPM for AI) — see `Security/Purview/DSPM-for-AI-A.md`/`-B.md`
- General Entra role-based access control administration (creating custom roles, PIM activation workflows) — see `EntraID/` for RBAC mechanics broadly; this runbook covers only how existing role assignments gate this specific agent's behavior

**Assumes:**
- Microsoft Graph PowerShell SDK (`Microsoft.Graph`) v2.x for any Graph-based role-assignment evidence collection
- The reader understands basic Entra ID admin role concepts (role assignment, least privilege) — see `EntraID/` for foundational RBAC content
- No dedicated PowerShell or Graph API exists, as of this runbook's research date, for reading Agent Registry block/scope state or Admin-Agent-specific usage analytics — all such checks are UI-based in the Microsoft 365 admin center, called out explicitly throughout

---

## How It Works

### What it is, architecturally

The Microsoft 365 Admin agent is an **assistive, agentic experience** — not a chatbot with canned responses, but a system that interprets a natural-language admin request, determines which underlying Microsoft 365 service(s) it needs to query or act on, and either answers directly or proposes a concrete action for the admin to confirm. It is built on the **Agent 365 Platform SDK** and connects to multiple **Model Context Protocol (MCP)** servers — a standardized way for an AI agent to discover and invoke external tools. Critically, **only the Microsoft 365 Admin agent can access these particular native MCP tools**; third-party or custom agents built via Copilot Studio, Agent Builder, or Foundry do not have the same tool access, even if granted broad Graph permissions. This is a deliberate first-party/Microsoft-managed distinction, not a licensing tier difference.

The stated design goal is shifting admin work "from manual configuration to intent-driven, observable, and governed operations" — in practice this means the agent can chain together multiple Graph API calls and admin-service reads/writes behind a single natural-language request that would otherwise require navigating several portal blades or writing a short PowerShell/Graph script.

### Three access surfaces, one underlying agent

| Surface | Availability | Notes |
|---|---|---|
| **Microsoft 365 Copilot Chat** (`m365.cloud.microsoft`) | All tenants, any admin role | Navigate to Agents → Microsoft 365 Admin agent |
| **Microsoft 365 admin center** (`admin.microsoft.com`) | All tenants, any admin role | Launched via the Copilot button in the top of the window; the agent is pre-selected in the agent picker |
| **Microsoft Teams** (desktop) | SMB-scoped: organizations up to roughly 300 users without a dedicated full-time IT role | GA since **May CY2026**; at GA, Desktop platform and **Worldwide (Standard Multi-Tenant)** cloud instance only (per the Microsoft 365 Roadmap entry, ID 558255) — re-verify current platform/cloud coverage before promising availability to a GCC/GCC High/sovereign-cloud or mobile-first client, since this is a fast-evolving rollout |

All three surfaces reach the **same agent and the same underlying capability set** — the Teams surface is not a functionally reduced version, it's a narrower-audience *entry point* designed to sit inside a tool SMB admins (often wearing multiple hats, without a dedicated IT function) already use daily, framed around organization setup, security settings, and password-reset guidance without requiring them to learn a separate admin portal first.

A deliberate UX feature ties all three surfaces together: **cross-surface session continuity**. An admin can start a request in Copilot Chat ("who are the unlicensed users in my org?") and continue the same flow in the admin center ("assign Adele Vance a Microsoft 365 E7 license") without repeating context — the agent retains the conversation thread across surfaces for that admin's own session.

### Licensing — a genuinely unusual position

**No additional Microsoft 365 Copilot or Microsoft Agent 365 license is required.** The agent is pre-installed in Microsoft 365 Copilot Chat for every Microsoft 365 administrator, at no incremental license cost. This is worth stating explicitly and early in any client conversation, since the near-universal pattern with new AI-branded Microsoft 365 capabilities is an additional Copilot/Agent 365 licensing requirement — this specific agent breaks that pattern. (This does not mean the *tenant* has no Copilot licensing considerations at all — Copilot Chat itself, and any other agents the tenant uses, may still have their own licensing gates; only the Admin agent specifically is licensing-independent.)

### The RBAC-reflection model — no standing privilege

This is the architectural fact that resolves the largest share of "the agent won't do X" tickets: **the Microsoft 365 Admin agent has no privilege of its own.** Every action it proposes or performs is gated by the **signed-in admin's existing Microsoft Entra role-based access control (RBAC) assignments** — the same roles that would gate that action if performed manually through the portal, PowerShell, or Graph.

Concretely:
- A **User Administrator** can ask the agent to list unlicensed users and assign licenses; a **Reports Reader** asking the same thing gets read access to usage data but cannot complete the license assignment.
- A **Teams Administrator** can get chat-policy and call-quality troubleshooting answers; a role without Teams admin scope gets a permission-gated response for the same prompt.
- Approving/rejecting Registry requests, assigning agent ownership, or changing tenant-wide agent-access settings — regardless of which agent is in question, including this one — requires **AI Administrator** or **Global Administrator** specifically; other roles (Global Reader, AI Reader, Security Administrator, Security Reader, Reports Reader, User Experience Success Manager) can view Registry data but cannot act on it, and User Account Administrator cannot even view Registry information.

This means capability differs meaningfully by which admin is asking — the same prompt can produce a full answer, a partial read-only answer, or an explicit permission-denied response depending purely on the signed-in user's own role assignments, with zero agent-side configuration involved.

### The confirmation gate — mandatory for every write action

**Any write or execute action the agent proposes requires explicit admin confirmation before it is performed. The agent never makes tenant changes on its own.** This is stated as a hard guarantee, not a configurable setting — there is no tenant option to make the agent auto-execute proposed changes. Practically, this means every "assign this license," "block this agent," "disable this Copilot setting" style request surfaces as a proposal the admin must actively approve, functioning as a built-in human-in-the-loop control for every consequential action regardless of the admin's role or the client's own governance maturity.

### The six documented task categories

As of this runbook's research date, Microsoft documents only generally-available capabilities, organized into six categories (new scenarios are added over time as they reach GA — treat any specific capability list as a snapshot, not a ceiling):

1. **Manage users, licenses, and groups** — list admins/users by attribute, Copilot usage counts, license inventory and assignment, pending license requests, group ownership gaps.
2. **Copilot management** — readiness assessment, prioritized readiness actions, tenant-wide Copilot settings (unlicensed-user Copilot Chat access, automatic file access, image generation, screen/camera sharing with Copilot, AI disclaimer formatting, third-party AI subprocessor enablement e.g. Anthropic/OpenAI).
3. **Agent management** — discover agents in the Registry by name/publisher/platform/owner status, view usage analytics and details for a specific agent, block/deploy/assign-owner actions, manage tenant-wide agent access and sharing permissions. (This category overlaps functionally with `Copilot/AgentGovernance-A/B.md` — the Admin agent is simply a natural-language front end onto the same Registry actions that runbook covers via the portal UI directly.)
4. **Change management** — organizational recaps, Message Center summaries filtered by topic (e.g., Copilot, Teams), service health status checks.
5. **Help and support** — self-help guidance for common admin how-tos, support ticket status lookups, FastTrack assistance requests.
6. **Teams administration** — chat policy troubleshooting (e.g., why a user can't delete/edit messages), call and meeting quality analysis by user/meeting ID, enterprise voice value lookups, unassigned phone number inventory, account type lookups.

A seventh, cross-cutting category — **identity, migration, and other admin scenarios** — covers tenant ID lookup, active-service inventory, security/compliance contact lookup, third-party migration guidance, self-service password reset enablement, MFA status, directory sync status, and authentication-method/passwordless configuration.

### Governance — a shared control plane, not an agent-specific one

Blocking or restricting the Microsoft 365 Admin agent uses **exactly the same Agent Registry mechanism** that governs every other agent in the tenant (Copilot Studio agents, Agent Builder agents, SharePoint agents, Foundry agents): Microsoft 365 admin center → **Agents → Registry** → locate the agent by name → **Block** (tenant-wide) or scope deployment to specific users/groups. Only **AI Administrator** or **Global Administrator** can take this action. Blocking restricts admins from invoking the agent through Copilot Chat and admin-center surfaces; it has no effect on any other Microsoft 365 admin center functionality — admins simply lose the natural-language shortcut and revert to the standard portal/PowerShell/Graph paths.

### Audit trail — inherited, not dedicated

There is **no separate, Admin-Agent-specific audit log.** Actions performed through the agent are recorded in the **same underlying workload audit logs** that would capture the identical action if taken manually — Microsoft 365 admin center audit logs, Microsoft Entra audit logs, and Microsoft Teams admin logs, depending on which service the action touched. Log entries attribute the action to the **signed-in admin**, consistent with the RBAC-reflection model — the agent is not a distinct actor from an audit-trail perspective.

### Data, privacy, and security posture

The agent inherits the full set of Microsoft 365 Copilot data/privacy/security commitments rather than operating under separate terms:
- Prompts, responses, and Microsoft Graph-accessed data are **not used to train foundation LLMs**.
- The agent honors the same **Microsoft Graph permission model** as every other Microsoft 365 service — it surfaces only data the signed-in admin's own role already permits, via the same identity-based access boundary used elsewhere in Microsoft 365.
- **EU Data Boundary** protections apply to this agent the same as other Copilot experiences for EU customers, with the standard caveat that Anthropic-provided subprocessor models are currently excluded from the EU Data Boundary if that subprocessor is enabled for the tenant.
- Actions are subject to the same content-filtering and jailbreak/prompt-injection defenses (classifiers, harm filters) as the rest of Microsoft 365 Copilot — no separate, weaker guardrail set applies just because this is an admin-facing agent.
- Underlying MCP tool invocations "follow the same data handling, compliance, and audit requirements as the underlying admin experiences" — i.e., the tool layer does not create a new compliance surface distinct from the workloads it touches.

---

## Dependency Stack

```
Microsoft Entra tenant
    │
    ▼
Signed-in user holds ANY Entra admin role (no minimum privilege floor to use the agent at all)
    │
    ▼
Microsoft 365 Admin agent — pre-installed, no Copilot/Agent 365 license required
    ├── Surface: Microsoft 365 Copilot Chat (m365.cloud.microsoft) — all tenants
    ├── Surface: Microsoft 365 admin center (admin.microsoft.com, Copilot button) — all tenants
    └── Surface: Microsoft Teams desktop — SMB-scoped (~300 users), GA May 2026,
                  Worldwide Standard Multi-Tenant cloud only at GA
    │  (all three share one session-continuous conversation thread per admin)
    ▼
Agent 365 Platform SDK + native MCP (Model Context Protocol) tool servers
    — exclusive to this agent; invokes Microsoft Graph APIs and admin services
    │
    ▼
RBAC gate — per REQUEST, not a standing agent privilege
    Signed-in admin's existing Entra role assignments determine:
      • what data the agent can read     (e.g., Reports Reader, Global Reader)
      • what actions the agent can take  (e.g., User Administrator, Teams Administrator)
      • whether Registry governance actions are available at all
        (AI Administrator / Global Administrator ONLY — Block, scope, approve, assign owner)
    │
    ▼
Confirmation gate — MANDATORY for every write/execute action, no auto-execution, ever
    │
    ▼
Underlying workload executes the confirmed action
    (Microsoft Graph, Entra ID, Microsoft 365 admin center, Microsoft Teams admin services)
    │
    ▼
Audit trail — inherited from the underlying workload, NOT a separate Admin-Agent log
    (M365 admin center audit log / Entra audit log / Teams admin log, per workload touched)
    │
    ▼
Governance layer — Agent Registry (shared control plane for EVERY agent in the tenant)
    Microsoft 365 admin center → Agents → Registry → Block / Scope deployment
    (AI Administrator / Global Administrator only — see Copilot/AgentGovernance-A/B.md)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Agent can't complete a requested action, or shows a permission-related response | Signed-in admin's Entra role doesn't cover the requested capability — expected, not a bug | `Get-MgRoleManagementDirectoryRoleAssignment` for the admin's own roles |
| Agent proposed a change but the tenant is unchanged afterward | Confirmation step never completed | Re-run and explicitly confirm the proposed action |
| Two admins get different answers to the identical prompt | Different underlying Entra role assignments — RBAC-reflection working as designed | Compare each admin's role assignments |
| Agent missing entirely from Teams, works fine in Copilot Chat/admin center | Teams surface is SMB-scoped (~300 users) and was Desktop/Worldwide-Multi-Tenant-only at GA | Confirm tenant size/profile, client platform, and cloud instance against current rollout status |
| Can't find a log entry for an action taken via the agent | No dedicated agent audit log exists — action is logged under the underlying workload instead | Check M365 admin center / Entra / Teams admin audit log matching the workload touched |
| Admin without AI Administrator/Global Administrator can't Block or scope the agent | Registry governance actions require AI Administrator or Global Administrator specifically | Confirm role via `Get-MgRoleManagementDirectoryRoleAssignment`, escalate to a qualifying role |
| Admin assumes the agent needs a Copilot license and is blocked by licensing | Incorrect assumption — this specific agent requires no additional Copilot/Agent 365 license | Confirm via the agent's own prerequisites documentation, not general Copilot licensing rules |
| Client worried tenant data trains the underlying AI model | Standard, valid Copilot data-handling misconception | Cite the Copilot privacy commitments directly (grounding data and prompts excluded from foundation-model training) |
| Agent context appears to carry over between Copilot Chat and the admin center unexpectedly | Expected — deliberate cross-surface session continuity for the same signed-in admin | Confirm it's single-admin continuity, not cross-admin data leakage |
| A capability from the documented example-prompt list doesn't work at all, for every admin regardless of role | Capability may not yet be GA for this tenant/region, or rollout-ring timing | Re-check the current Microsoft Learn example-prompt list and Message Center for rollout status before assuming misconfiguration |

---

## Validation Steps

1. **Confirm the agent is reachable in at least one surface.**
   Sign in to `m365.cloud.microsoft` → Agents → Microsoft 365 Admin, or `admin.microsoft.com` → Copilot button.
   Expected: agent responds to a simple, low-privilege prompt (e.g., "what is my tenant ID?").

2. **Confirm the signed-in admin's actual Entra role assignments before troubleshooting any capability gap.**
   ```powershell
   Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
   Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<objectId>'" -ExpandProperty roleDefinition |
       Select-Object -ExpandProperty RoleDefinition | Select-Object DisplayName
   ```
   Expected: role list matches the capability being tested against the six task categories above.

3. **Confirm write-action confirmation behavior explicitly.**
   Ask the agent to propose (but do not yet confirm) a low-risk change (e.g., a Copilot setting toggle in a test/non-production context if available). Expected: agent presents the proposed action and waits for explicit confirmation before applying it.

4. **Confirm Registry governance access for AI Administrator/Global Administrator specifically.**
   Sign in as a role holder → Microsoft 365 admin center → Agents → Registry → locate "Microsoft 365 Admin." Expected: Block/scope-deployment actions are available. Repeat as a Global Reader or Security Reader — expected: view-only, no action controls available.

5. **Confirm audit trail attribution for a completed action.**
   After confirming a real action through the agent (e.g., a license assignment in a test tenant), check the Microsoft 365 admin center audit log or Entra audit log for a matching entry attributed to the signed-in admin.

6. **Confirm Teams-surface eligibility before promising it to a client.**
   Cross-check tenant user count (~300 ceiling), client platform (Desktop at GA), and cloud instance (Worldwide Standard Multi-Tenant at GA) against the current Microsoft 365 Roadmap entry (ID 558255) and Message Center, since this surface's coverage is actively expanding.

---

## Troubleshooting Steps (by phase)

### Phase 1: Scope the Complaint
1. Identify which of the three surfaces (Teams, Copilot Chat, admin center) is affected — a surface-specific gap and an agent-wide gap have different root causes and different fixes.
2. Identify whether the complaint is about a **read** (the agent can't see/report something) or a **write** (the agent can't change something) — these map to different parts of the RBAC-reflection model.

### Phase 2: RBAC Investigation
1. Pull the signed-in admin's actual Entra role assignments via Microsoft Graph.
2. Map the requested capability to the role that genuinely governs it — not necessarily an AI-branded role; most capabilities map to the same roles that would govern the equivalent manual action (User Administrator, Teams Administrator, SharePoint Administrator, etc.).
3. For Registry-specific actions (block, scope, approve, assign owner) specifically, confirm AI Administrator or Global Administrator — no other role qualifies, regardless of how much visibility that role otherwise has.

### Phase 3: Confirmation & Execution Investigation
1. Confirm whether the proposed action was actually confirmed by the admin, not just requested.
2. If confirmed but not applied, check the relevant underlying workload directly (outside the agent) to determine whether the action was attempted and failed there, versus never reaching the workload at all.

### Phase 4: Surface & Rollout Investigation
1. For Teams-surface-specific gaps, confirm tenant size/profile, client platform, and cloud instance against current rollout documentation before treating this as a defect.
2. For capability gaps present across all three surfaces, check whether the capability is documented as GA yet — Microsoft explicitly notes new scenarios are added over time and only GA capabilities are documented.

### Phase 5: Audit & Governance Investigation
1. Route audit questions to the correct underlying workload log based on what the action touched — never assume a dedicated agent log exists.
2. Route governance questions (block/restrict/scope) to the Agent Registry, cross-referencing `Copilot/AgentGovernance-A/B.md` for the general mechanism if the conversation extends beyond this one agent.

### Phase 6: Escalation
1. Package the Evidence Pack below.
2. Escalate genuine platform gaps (documented capability not working for a qualifying role/surface/tenant combination) to Microsoft Support.
3. Escalate governance/compliance questions that exceed this runbook's scope (e.g., contractual data-processing commitments) to the client's own legal/compliance function with the cited Microsoft Learn sources, rather than answering definitively on their behalf.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Rolling out the Admin Agent intentionally to an SMB client (role cleanup first)</summary>

**When to use:** Onboarding a new SMB client, or formalizing use of the Admin agent for an existing one, rather than leaving it available by default to whoever happens to hold an admin role.

1. Inventory current Entra role assignments across the tenant first — since the agent has no privilege beyond existing roles, an over-privileged or stale role assignment (e.g., a departed employee still holding Global Administrator) becomes an over-privileged agent capability the moment that account signs in and uses the agent.
   ```powershell
   Get-MgRoleManagementDirectoryRoleAssignment -ExpandProperty principal,roleDefinition |
       Select-Object @{N='Role';E={$_.RoleDefinition.DisplayName}}, @{N='Principal';E={$_.Principal.AdditionalProperties.displayName}}
   ```
2. Apply standard least-privilege cleanup before promoting the agent as a client-facing tool — remove stale Global Administrator assignments, right-size roles to the specific task categories the client actually needs (e.g., User Administrator for a client that only needs the users/licenses category).
3. Confirm the client's tenant profile genuinely fits the Teams-surface target audience (≤~300 users, no dedicated IT role) before pointing them there specifically — larger clients should be directed to Copilot Chat/admin center instead, where the same governance and RBAC model applies identically.
4. Brief the client (or the specific admins who will use it) on the confirmation-gate model explicitly — every write action requires their active confirmation, framed as a safety feature rather than friction.
5. Decide and document, as part of the engagement, whether the agent will be left unrestricted (any admin, reflecting existing roles) or scoped to a specific subset via the Registry (Playbook 2) — don't leave this as an unconsidered default.

**Rollback:** N/A — onboarding/role-hygiene playbook; role assignment changes made during cleanup follow standard Entra role-assignment rollback (re-assign as needed).

</details>

<details><summary>Playbook 2 — Blocking or scoping the Admin Agent for a specific client</summary>

**When to use:** A client's compliance posture, pilot program, or risk tolerance calls for restricting who can use the agent, or disabling it entirely.

1. Confirm the acting admin holds AI Administrator or Global Administrator.
2. Microsoft 365 admin center → **Agents → Registry** → locate **Microsoft 365 Admin**.
3. For full disablement: select **Block**. For partial restriction: use the scoped-deployment action to limit availability to a specific user or group (e.g., only senior admins, excluding first-line helpdesk staff).
4. Document the decision and rationale in the client's engagement record — this is the same Registry mechanism covering every other agent, so a scoping decision here should be considered alongside the broader agent-governance posture covered in `Copilot/AgentGovernance-A.md`, not in isolation.
5. Communicate to affected admins that blocking removes only the natural-language shortcut — all underlying portal, PowerShell, and Graph capabilities they already had remain fully available and unaffected.

**Rollback:** Reverse the Block action or widen the deployment scope from the same Registry entry at any time; no data or configuration is lost by blocking, since the agent itself holds no state independent of the underlying workloads.

</details>

<details><summary>Playbook 3 — Building a lightweight internal governance layer around agent write actions</summary>

**When to use:** An MSP wants a consistent internal standard for how their own technicians (or a client's staff) use the agent's write capabilities, beyond relying on the built-in confirmation gate alone.

1. Treat every agent-proposed write action with the same review discipline applied to a proposed PowerShell script or manual portal change — read the confirmation prompt's exact wording before confirming, particularly for prompts affecting tenant-wide security settings (e.g., disabling Copilot screen/camera sharing) or bulk operations (e.g., mass license changes).
2. For MSP technicians specifically, consider scoping agent access (Playbook 2) to exclude first-line/junior staff from security-relevant task categories (Copilot management, agent management) while leaving lower-risk categories (help and support, change management recaps) broadly available.
3. Establish an internal norm that any agent-confirmed action affecting more than a handful of users or any tenant-wide setting gets a second-technician sanity check before confirmation, mirroring change-management discipline applied elsewhere (see `M365/Backup/`, `Security/` for comparable "verify before you commit" patterns in this repo).
4. Periodically spot-check the underlying audit logs (Playbook 4 below covers the mechanics) against expected agent-driven activity as a lightweight internal QA measure, since there's no dedicated agent-usage dashboard for this level of granular review.

**Rollback:** N/A — internal process/governance playbook, no tenant configuration change.

</details>

<details><summary>Playbook 4 — Pre-engagement compliance review before enabling the agent for a regulated client</summary>

**When to use:** Scoping the agent's use for a client in a regulated industry (healthcare, finance, government-adjacent) as part of a broader Microsoft 365 compliance review.

1. Confirm and document the data-handling facts directly from Microsoft's published commitments rather than summarizing from memory: prompts/responses/Graph-accessed data excluded from foundation-model training; Graph permission model enforced per-request; EU Data Boundary coverage (noting the Anthropic-subprocessor exclusion if that subprocessor is enabled for the tenant).
2. Confirm audit-log coverage meets the client's regulatory logging requirements by tracing a sample action through to its underlying workload log (Validation Step 5) — since there's no dedicated agent log, the review should explicitly confirm the *underlying* logs capture what the regulation requires, not assume agent-specific tooling exists.
3. Confirm RBAC hygiene (Playbook 1) is complete and current before enabling the agent broadly — since the agent adds no new access control layer of its own, any gap in the existing Entra role model is inherited directly and immediately.
4. Decide, and document, the scoping/blocking posture (Playbook 2) as an explicit compliance decision, not a default.
5. Revisit this review periodically — the documented example-prompt/capability list is explicitly described by Microsoft as growing over time, meaning the agent's practical capability surface (and therefore its data-handling footprint) can expand without a corresponding tenant-side configuration change to trigger re-review.

**Rollback:** N/A — pre-engagement compliance scoping, no configuration change of its own.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Microsoft 365 Admin agent governance evidence for escalation or compliance review.
.NOTES     Read-only. Requires Microsoft Graph PowerShell SDK (Connect-MgGraph) with
           RoleManagement.Read.Directory and Directory.Read.All scopes. Agent Registry
           block/scope state and Teams-surface rollout eligibility have NO Graph/PowerShell
           read API as of this runbook's writing — both must be confirmed manually in the
           Microsoft 365 admin center. See Scripts/Get-AdminAgentGovernanceAudit.ps1 for the
           full, documented tenant-wide version with CSV export.
#>
$evidence = [System.Collections.Generic.List[string]]::new()

$evidence.Add("=== Global Administrator role holders ===")
$evidence.Add((Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '62e90394-69f5-4237-9190-012177145e10'" -ExpandProperty principal |
    Select-Object @{N='Principal';E={$_.Principal.AdditionalProperties.displayName}} | Out-String))

$evidence.Add("=== AI Administrator role holders (can govern this and every other agent) ===")
$evidence.Add((Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq 'd2562ede-74db-457e-a7b6-544e236ebb61'" -ExpandProperty principal |
    Select-Object @{N='Principal';E={$_.Principal.AdditionalProperties.displayName}} | Out-String))

$evidence.Add("=== Copilot / Agent 365 licensing present in tenant (informational — agent itself needs none) ===")
$evidence.Add((Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "Copilot|Agent365|SPE_E7" } |
    Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits | Out-String))

$evidence.Add("=== MANUAL: Agent Registry state for 'Microsoft 365 Admin' ===")
$evidence.Add("Blocked / Scoped / Unrestricted: <fill in from Microsoft 365 admin center > Agents > Registry>")

$evidence.Add("=== MANUAL: Teams-surface rollout eligibility ===")
$evidence.Add("Tenant user count: <fill in>  |  Client platform: <fill in>  |  Cloud instance: <fill in>")

$evidence | Out-File -FilePath ".\AdminAgent-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| Connect to Microsoft Graph for role evidence | `Connect-MgGraph -Scopes "RoleManagement.Read.Directory","Directory.Read.All"` |
| List a specific admin's Entra role assignments | `Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<objectId>'" -ExpandProperty roleDefinition` |
| List all Global Administrator holders | `Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '62e90394-69f5-4237-9190-012177145e10'" -ExpandProperty principal` |
| List all AI Administrator holders | `Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq 'd2562ede-74db-457e-a7b6-544e236ebb61'" -ExpandProperty principal` |
| Check Copilot/Agent 365 SKUs present in tenant | `Get-MgSubscribedSku \| Where-Object { $_.SkuPartNumber -match "Copilot\|Agent365" }` |
| Open the agent — Copilot Chat | `https://m365.cloud.microsoft` → Agents → Microsoft 365 Admin |
| Open the agent — admin center | `https://admin.microsoft.com` → Copilot button (top of window) |
| Block/scope the agent (portal only, no cmdlet) | `admin.cloud.microsoft` → Agents → Registry → Microsoft 365 Admin → Block / scope deployment |
| Check Message Center for rollout status | `admin.microsoft.com` → Health → Message center → filter "Admin agent" or "Teams" |
| M365 admin center audit log search | `purview.microsoft.com` (or admin center Audit blade) → filter by admin UPN and activity date/time |
| Entra audit log search | `entra.microsoft.com` → Identity → Monitoring & health → Audit logs → filter by initiated-by |
| Teams admin center audit log search | `admin.teams.microsoft.com` → Analytics & reports, or via Purview unified audit log filtered to Teams activities |
| Check current Roadmap status for Teams-surface rollout | `https://www.microsoft.com/microsoft-365/roadmap?id=558255` |

---

## 🎓 Learning Pointers

- **The Admin agent's entire capability envelope is defined by the signed-in admin's existing Entra RBAC — it introduces no new privilege model of its own.** Internalizing this one fact resolves most "the agent won't/can't do X" questions faster than any agent-specific troubleshooting step. See [Use Microsoft 365 Admin agent](https://learn.microsoft.com/en-us/microsoft-365/copilot/copilot-ai-admin-agent).

- **Registry governance (block/scope/approve/own) for this agent — and every other agent in the tenant — is restricted to AI Administrator and Global Administrator specifically**, with several other roles (Global Reader, AI Reader, Security Administrator/Reader, Reports Reader, User Experience Success Manager) able to view but not act, and User Account Administrator unable even to view. Get this table memorized rather than re-deriving it per ticket. See [Agent management roles and permissions in Microsoft 365 admin center](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-roles-perms).

- **No dedicated audit surface exists for this agent — every action lands in the same log the manual equivalent would.** Build the habit of asking "which underlying workload did this touch?" before searching for a log, rather than looking for an "Admin Agent" log source that doesn't exist. See [Agent overview in Microsoft 365 admin center](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-365-overview).

- **The SMB-scoped Teams surface is a genuinely different rollout track (audience size, platform, cloud instance) layered on the same underlying agent** — treat "not showing up in Teams" and "not working at all" as different diagnostic paths, and re-check current platform/cloud-instance coverage against the Microsoft 365 Roadmap before making availability commitments, since this is one of the more actively-expanding surfaces covered in this repo as of the research date. See [Microsoft 365 Roadmap ID 558255](https://www.microsoft.com/microsoft-365/roadmap?id=558255).

- **This agent's data-handling posture is inherited wholesale from Microsoft 365 Copilot's broader privacy commitments, not a separate policy** — when a client asks about AI data handling for this specific tool, the correct source is the general Copilot privacy documentation, cited directly, not an agent-specific privacy statement (none exists separately). See [Data, Privacy, and Security for Microsoft 365 Copilot](https://learn.microsoft.com/en-us/microsoft-365/copilot/microsoft-365-copilot-privacy).

- **The documented capability list (six task categories, dozens of example prompts) is explicitly a living, GA-only snapshot that Microsoft states will grow over time** — don't treat a capability's absence today as permanent, and don't assume a capability exists in a client's tenant just because a general web search or this runbook describes it, without confirming current GA status for that tenant/region. Cross-reference the live example-prompts page periodically rather than relying on this runbook's list indefinitely. See [Use Microsoft 365 Admin agent — Example prompts](https://learn.microsoft.com/en-us/microsoft-365/copilot/copilot-ai-admin-agent#example-prompts).
