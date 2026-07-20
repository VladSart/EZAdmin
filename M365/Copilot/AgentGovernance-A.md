# Microsoft 365 Copilot Agent Governance — Reference Runbook (Mode A: Deep Dive)
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
- Agent lifecycle governance in Microsoft 365 admin center: the Agent workload (Overview, Registry, Requests), approval/publish/reject/ownership workflows
- Microsoft Agent 365 as the cross-platform control plane concept
- The distinct admin surfaces governing each creation platform: Copilot Studio (MCS DA/CEA/BP), Agent Builder, Microsoft 365 Agents Toolkit, SharePoint agents, Microsoft Foundry, Frontier agents
- Agent types, roles/permissions, and licensing tiers relevant to governance decisions
- Risk/exception signals surfaced from Entra, Defender, and Purview into the agent Registry

**Out of scope (see cross-references):**
- Base Microsoft 365 Copilot licensing, tenant/per-app enablement, Conditional Access, and Graph grounding permission mechanics for using Copilot itself — see `Copilot-A.md`/`Copilot-B.md` (this file assumes Copilot works; the subject here is specifically *agent* governance layered on top)
- Copilot Studio's own bot-authoring, topics/dialog design, and connector-building mechanics — only the governance/admin-control surface is covered here, not agent development
- Power Platform DLP policy authoring in general (only referenced where it intersects agent publishing/access)
- Microsoft 365 Copilot usage/adoption reporting for the base product (`Scripts/Get-CopilotUsageReport.ps1` covers general Copilot usage; this runbook's own Evidence Pack is agent-registry-specific)

**Assumes:**
- Microsoft Graph PowerShell SDK (`Microsoft.Graph`) v2.x installed for any Graph-based evidence collection
- Caller has, at minimum, a role that can view the Agent workload (e.g., Global Reader); **AI Administrator** or **Global Administrator** required for any write action (approve, reject, assign owner, publish)
- Tenant has Microsoft 365 Copilot, Copilot Chat, and/or Microsoft Agent 365 licensing appropriate to the agents in question

---

## How It Works

<details><summary>Full architecture</summary>

### Agent governance is a control plane over agents built anywhere, not a single feature

Agent governance is the set of policies, settings, and admin actions controlling how agents are accessed, published, deployed, and managed — deliberately platform-agnostic, because organizations build and acquire agents through at least eight distinct creation paths. Microsoft's stated framing is explicit: governance should be consistent **regardless of how or where an agent was built**, which is why a dedicated **Agent workload** exists in the Microsoft 365 admin center as the "grounding control plane" rather than each creation platform shipping its own disconnected admin experience.

```
                     ┌─────────────────────────────────────────┐
                     │   Microsoft 365 admin center             │
                     │   Agent workload (grounding control plane)│
                     │   ┌───────────┬───────────┬────────────┐ │
                     │   │ Overview  │ Registry  │  Requests  │ │
                     │   └───────────┴───────────┴────────────┘ │
                     └─────────────────────────────────────────┘
                                        ▲
              ┌───────────────┬────────┼────────┬───────────────┐
              │               │                 │               │
      Copilot Studio    Agent Builder    Agents Toolkit     SharePoint
      (MCS DA/CEA/BP)    (in Copilot)   (declarative +      (.agent files,
              │               │          custom engine)      Site Assets
      Power Platform     Share/manage         │              permission-
      admin center       toggle + Share   Integrated Apps    governed, NOT
      (separate access   controls         section            routed through
      grant required)                                        the Registry
                                                               approval flow
              │               │                 │
         Microsoft Foundry (LOB / non-LOB / hosted)
         Microsoft-built, External partner, and Frontier agents
         (App Builder agent, Workflows agent — also manageable via
          Power Platform admin center)
```

**Why this matters operationally:** a support engineer who only knows the M365 admin center Registry/Requests flow will correctly triage 80% of tickets but will be stuck on Copilot Studio agents needing a separate Power Platform grant, and completely off-track on SharePoint agents, which never touch the Requests approval flow at all — they're governed purely by file permissions on the underlying `.agent` file in Site Assets.

### The Agent Registry: what "an agent" means for counting/inventory purposes

The Registry is the tenant's full agent inventory — Microsoft-built, partner-built, and custom line-of-business agents — sourced from the Agent Registry system and usage analytics pipelines, which can show minor variances against each other due to ingestion timing (expected, not a data-integrity bug). An agent is formally defined as an AI-powered entity performing tasks autonomously or semi-autonomously using instructions, context, knowledge sources, and tools. Supported creation platforms surfaced in the Registry: Copilot Studio, SharePoint, Agent Builder, AI Foundry, Agents Toolkit, other Microsoft agentic types (e.g., Researcher), and detected non-Microsoft agentic platforms.

**Draft-agent visibility is inconsistent by design, not a bug:** currently only Copilot Studio draft (unpublished) agents are visible in the Registry — draft agents built in Agent Builder, Foundry, or SharePoint are not yet surfaced. Don't conclude an agent doesn't exist just because it's absent from the Registry if it may still be in draft state on one of those other platforms.

### Agent types table (governs which controls apply)

| Type | Built with | Key governance note |
|---|---|---|
| **MCS DA** | Copilot Studio, written instructions | Declarative agent; publish/approve per channel |
| **MCS CEA** | Copilot Studio, precise settings/capabilities | Custom Engine Agent; same channel-based approval |
| **MCS BP** | Copilot Studio | Business Process agent — sequenced tasks/automation |
| **Foundry LOB** | Microsoft Foundry | In-house, tied to a specific business workflow |
| **Foundry non-LOB** | Microsoft Foundry | Not tied to a specific workflow |
| **Foundry hosted** | Microsoft Foundry | Created, stored, and run entirely inside Foundry |
| **Agent Builder** | Agent Builder in Copilot | Declarative agent; access controlled by the "Create an agent" entry-point toggle plus per-agent Share |
| **SharePoint** | SharePoint sites | `.agent` file in Site Assets; governed by file/library permissions, not Registry approval |
| **Agent Toolkit** | Microsoft 365 Agents Toolkit | Sideloaded/published via Integrated Apps |
| **Agent instance** | Any agent extended via the Microsoft Agent 365 SDK | Gains Entra-backed agent identity, enhanced notifications, extended observability, MCP tooling, IT-approved template system — the most "governable" agent form |

### Agent lifecycle: request states and what each means operationally

When a user publishes/shares an agent to the org catalog, it enters the **Requests** queue in one of three states:
- **Pending review** — a brand-new submission awaiting first approval
- **Pending update** — an existing, already-published agent has a new version awaiting approval; **the previous version remains live for users until the update is approved** — this is a frequent source of "why hasn't my update gone out" confusion
- **Pending activate** — a user is requesting to *activate* an agent so they can create instances of it, a distinct action from simply using an already-published agent

Only **AI Administrator** or **Global Administrator** roles can action requests (approve/reject) or assign ownership — this is a hard role gate, not a permission that can be delegated via a custom role assignment as of current documentation. The publishing wizard itself is multi-step: select the audience (specific users/groups, or everyone), optionally select users to have the agent preinstalled, choose a policy template (existing/default/custom), review and grant admin consent for requested Graph permissions, then publish.

### Risk and ownership as first-class governance signals, not afterthoughts

The Overview dashboard surfaces four categories of "Top actions," each mapped to a filtered Registry view:
- **Pending Requests for Agents** — approval backlog
- **Agents without owners** — an accountability gap; ownerless agents are a standing risk even when functioning correctly, since nobody is answerable for lifecycle/compliance/cost decisions
- **Agents at risk** — aggregated **high-severity** risk signals pulled from Microsoft Entra, Microsoft Defender, and Microsoft Purview; this closes what Microsoft explicitly frames as "a critical visibility gap for IT administrators responsible for governing AI agents" — meaning the Registry is a surfaced view of security findings that live natively elsewhere, not an independent risk-scoring engine
- **Agents with exceptions** — agents generating conversational errors, a functional-health rather than security signal

### Researcher and Analyst: the explicit governance carve-out

Researcher and Analyst are first-party Microsoft experiences built on the Microsoft 365 Copilot foundation, available under **Tools** in Copilot Chat, operating entirely within the Microsoft 365 commercial data-processing boundary and inheriting all standard security/privacy/compliance commitments. Despite architecturally coexisting alongside agents and "abiding by" agent-related governance capabilities in a general sense, Microsoft's documentation is explicit that these tools **will not fall under any agent-related settings** — meaning an agent-blocking or agent-scoping policy has no effect on them. This is a deliberate design choice, not a governance gap to be escalated as a bug.

### Licensing layers relevant to governance decisions

| License | Provides |
|---|---|
| Microsoft 365 (All Suites) | Includes Copilot Chat — web data agents only |
| Microsoft 365 Copilot (add-on to E3/E5, included in E7) | Web **and** work data agents |
| Microsoft Agent 365 (included in E7, or standalone) | The cross-platform control plane itself — Registry, governance actions, Agent 365 SDK identity features |
| Microsoft 365 E7 | Bundles E5 + Copilot + Agent 365 + Entra Suite together |

A governance ticket that looks like "the policy isn't applying" is sometimes actually "the license tier in question doesn't include the governed capability at all" — confirm licensing before assuming a policy misconfiguration.

</details>

---

## Dependency Stack

```
Tenant Licensing
    └── Microsoft 365 Copilot / Copilot Chat / Microsoft Agent 365 (per user, per capability tier)

Creation Platform (determines governing admin surface)
    ├── Copilot Studio → Copilot Studio User License + Power Platform admin center
    │                     "Manage access to Power Platform apps" (SEPARATE grant from
    │                     the CS license itself — both required for M365/Teams surfacing)
    ├── Agent Builder → "Create an agent" entry-point toggle (M365 admin center) +
    │                    per-agent Share control
    ├── Agents Toolkit → Integrated Apps section (M365 admin center)
    ├── SharePoint → .agent file permissions in the site's Site Assets library
    │                (standard SharePoint permission model, NOT Registry-routed)
    ├── Microsoft Foundry → Foundry platform + Registry inventory (LOB/non-LOB/hosted)
    └── Microsoft / External partner / Frontier → vendor or Microsoft-managed,
                                                     still inventoried in Registry

Registry Inventory (Agent workload > Registry)
    └── Every governable agent surfaces here regardless of creation platform
            (draft-agent visibility currently limited to Copilot Studio only)

Submission / Publish Flow (if publishing to org catalog)
    └── Requests queue: Pending review / Pending update / Pending activate
            └── Admin action REQUIRES AI Administrator or Global Administrator role
                    └── Publish to store: audience scope + policy template +
                    │   permission/consent review
                    └── OR Reject submission
                            └── (Pending update only) previous version stays live
                                until the update itself is approved

Ownership Assignment
    └── Every agent should have a designated, accountable owner

Ongoing Governance Signals (continuous, not one-time)
    ├── Risk aggregation from Entra + Defender + Purview → "Agents at risk"
    └── Conversational-error monitoring → "Agents with exceptions"

Agent available to its scoped audience; tracked continuously in the Registry
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Agent approved but a specific user still can't find/use it | Publish audience scope excludes that user/group — approval and audience are set together but are logically independent | Registry entry's Availability status + audience scope |
| "Publish to store" / "Assign Owner" buttons greyed out or missing | Signed-in admin lacks AI Administrator or Global Administrator role | Confirm role assignment via Entra admin center, not just M365 admin center visibility |
| Agent update never seems to reach users | Update sitting in "Pending update" — previous version remains live until approved | Requests tab, filter State = Pending update |
| Agent flagged "at risk" with no obvious reason in the Registry | Risk is aggregated from Entra/Defender/Purview — the Registry surfaces, not generates, the finding | Trace to the native security portal for the actual finding detail |
| Copilot Studio agent works fine in Copilot Studio, invisible in Teams/M365 Copilot | Missing the separate "Manage access to Power Platform apps" grant, distinct from the Copilot Studio User License | Confirm both controls independently |
| SharePoint agent's access behaves like a permissions issue, not a governance-policy issue | Because it is — SharePoint agents are governed by `.agent` file/library permissions, never routed through Requests | Standard SharePoint site/library permission check |
| Governance policy scoped to "block risky agents" doesn't affect Researcher/Analyst | Expected — Researcher and Analyst are explicitly carved out of all agent-related governance settings | Confirm via documentation before treating as a defect |
| Agent count in Overview doesn't match a manual count from Registry | Minor variance between Registry and usage-analytics pipelines due to ingestion timing | Expected within normal bounds; re-check trend direction, not exact parity |
| Draft agent from Agent Builder/Foundry/SharePoint not appearing anywhere in Registry | Draft-agent visibility currently supports Copilot Studio only | Confirm the agent's actual state on its native creation platform, not just the Registry |
| Frontier-type agent (App Builder / Workflows) behaves inconsistently between M365 admin center and Power Platform admin center | Both surfaces can manage these agent types independently — changes in one may not immediately reflect in the other | Confirm which surface was actually used for the most recent change |
| "Governance seems to be working differently than our old plugin/add-in model" | Agents use the unified Microsoft 365 app model (extends the Teams app platform), a deliberate architectural convergence — not the same governance model as classic Office add-ins/plugins | Confirm the ticket isn't scoped against legacy add-in expectations |

---

## Validation Steps

**Step 1 — Confirm the agent's creation platform before anything else**
Portal: Microsoft 365 admin center > Agents > All agents > Registry > search by name > note the **Platform**/**Type** column.
*Good:* Platform identified, governing admin surface known (M365 admin center alone, or M365 admin center + Power Platform admin center, or SharePoint permissions).
*Bad:* Assuming every agent is governed the same way — this is the single most common source of misdirected triage.

---

**Step 2 — Confirm the requesting/actioning admin's role**
```
Entra admin center > Roles and administrators > search the admin's account
```
*Good:* AI Administrator or Global Administrator assigned.
*Bad:* Any other role — governance actions (approve/reject/assign owner) will be unavailable even though the dashboard's gaps are visible.

---

**Step 3 — Confirm Registry state vs. Requests state**
Portal: Agents > All agents > Registry (current published state) and Agents > All agents > Requests (pending actions), filtered by State and Channel.
*Good:* Registry shows the agent's live state; Requests shows nothing pending, or a clearly identified pending item matching the reported symptom.
*Bad:* A "Pending update" entry exists that the reporting user mistook for "the agent is broken," when actually the previous version is still serving traffic correctly.

---

**Step 4 — For Copilot Studio agents, confirm both independent access controls**
```
1. Confirm Copilot Studio User License assignment (licensing admin center)
2. Confirm "Manage access to Microsoft Power Platform apps" enables THIS agent
   for Teams/M365 specifically (Power Platform admin center)
```
*Good:* Both present.
*Bad:* License present but Power Platform app access not granted — the agent will work inside Copilot Studio's own test/preview surface but never reach Microsoft 365 Copilot.

---

**Step 5 — For "at risk" flags, trace to the native security portal**
Portal: Agents > Registry filtered by risk (or Overview > "Manage agent risks") → note the source system (Entra / Defender / Purview) → pivot to that portal for the actual finding.
*Good:* A specific, actionable finding (e.g., excessive permission grant, DLP policy match, anomalous sign-in) is identified.
*Bad:* Treating the Registry's risk flag as the terminal diagnostic step — it is a pointer, not the full finding.

---

**Step 6 — For SharePoint agents, check file permissions directly**
```
Get-SPOCopilotAgentInsightsReport
```
*Good:* Command returns status/details for the agent in question, and site/library permissions match the expected access list.
*Bad:* Attempting to find the agent in Requests/Registry approval flow at all — SharePoint agents don't route through it.

---

## Troubleshooting Steps (by phase)

### Phase 1: Agent Not Visible / Not Found
1. Run Step 1 to confirm platform, then Step 3 to confirm Registry vs. Requests state
2. For SharePoint agents, skip directly to Step 6 — Registry/Requests is the wrong tool
3. Confirm audience scope explicitly, not just approval status (Fix 1 in `AgentGovernance-B.md`)
4. Confirm draft-agent visibility limitations if the agent was never formally published (only Copilot Studio drafts currently surface in Registry)

### Phase 2: Admin Cannot Take a Governance Action
1. Run Step 2 to confirm role
2. If role is correct but the action still fails, confirm the request hasn't already been actioned by another admin (check for a recent audit entry) before assuming a platform bug
3. Escalate to Microsoft Support with the Evidence Pack only after role and request-state are both confirmed correct

### Phase 3: Cross-Platform Visibility Gap (works on native platform, missing in M365 Copilot)
1. Run Step 4 for Copilot Studio agents specifically
2. For Agent Builder agents, confirm the "Create an agent" entry-point toggle is enabled tenant/group-wide, separately from any individual agent's Share settings
3. For Frontier agent types (App Builder, Workflows), confirm which admin center (M365 vs. Power Platform) was used for the most recent change and check both for consistency

### Phase 4: Security/Compliance Governance Action
1. Run Step 5, tracing the risk signal to its native portal
2. Resolve or formally accept the underlying finding in Entra/Defender/Purview — do not clear the Registry flag directly as a shortcut
3. Re-check after the source system's normal signal-refresh cycle before escalating a flag that "won't clear"

### Phase 5: Ownership / Accountability Gap
1. Confirm via Overview > "Agents without owners"
2. Identify actual creator/publisher from agent metadata
3. Assign ownership — treat this as a standing governance debt item during any periodic tenant review, not just a reactive fix

---

## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield: stand up agent governance for a new tenant/client</summary>

Use when a client is newly licensed for Microsoft 365 Copilot/Agent 365 and has no existing agent governance practice.

1. Confirm licensing: Copilot Chat vs. full Microsoft 365 Copilot vs. Microsoft Agent 365 — set expectations on which agent capabilities (web-only vs. web+work data) are actually available.
2. Assign **AI Administrator** to the specific individual(s) who will own agent governance day-to-day — avoid relying on Global Administrator for routine approvals per least-privilege guidance.
3. Establish a baseline policy template in the publishing wizard (default or custom) so every future approval applies consistent scoping rather than ad hoc decisions per agent.
4. Run an initial manual Registry review (Agents > All agents > Registry, sorted by creation date) to catalog any agents already in use before formal governance existed — shadow-agent discovery is common in tenants that had Copilot Studio or SharePoint agents active before anyone thought about governance. There is no dedicated PowerShell/Graph cmdlet set for the Registry itself as of this writing (SharePoint agents are the one exception — see the Evidence Pack), so this step is portal-driven.
5. Assign ownership to every discovered agent; reject or formally retire any with no identifiable business purpose.

</details>

---

<details><summary>Playbook 2 — Retrofit: bring an existing, ungoverned Copilot Studio deployment under M365 agent governance</summary>

Use when a client has been using Copilot Studio agents in production, published ad hoc via Power Platform, without ever routing them through the M365 admin center's Requests/Registry flow.

1. Inventory existing Copilot Studio agents via the Power Platform admin center first — these may not yet appear in the M365 Registry at all if they were never submitted for admin approval.
2. For each agent intended for tenant-wide Microsoft 365 Copilot availability, confirm both the Copilot Studio User License and the separate "Manage access to Power Platform apps" grant.
3. Formally submit/publish each agent through the standard approval flow so it becomes visible in the Registry and subject to ongoing risk/exception monitoring.
4. Assign ownership and a policy template retroactively for every agent brought under governance this way.
5. Communicate to Copilot Studio makers that future agents intended for org-wide use should go through the formal publish flow from the start, rather than being retrofitted after the fact.

</details>

---

<details><summary>Playbook 3 — Periodic governance health review (recurring MSP task)</summary>

Use as a recurring (e.g., monthly/quarterly) check across a client tenant's agent estate.

1. Review Overview dashboard: Pending Requests, Agents without owners, Agents at risk, Agents with exceptions — treat a non-zero count in any category as a work item, not just informational.
2. Cross-reference the "Top platforms used to build agents" card against expected/sanctioned platforms — an unexpected non-Microsoft platform appearing here (e.g., detected third-party agentic tools) may indicate shadow AI adoption worth a policy conversation.
3. Spot-check a sample of "Shared by creator" agents (not admin-published) for sensitive data exposure risk, since these bypass the full publish/approval review by design.
4. Confirm no Pending update requests have been sitting idle long enough that users are silently running stale agent versions.
5. Document findings per client for the account record, consistent with the Evidence Pack format below.

</details>

---

## Evidence Pack

```powershell
<#
  Microsoft 365 Copilot Agent Governance Evidence Collector
  Run before escalating a governance-action or visibility ticket to Microsoft Support.
  Note: the Agent workload (Registry/Requests/Overview) is a portal-first experience;
  as of this writing there is no dedicated public Graph/PowerShell cmdlet set for the
  Agent Registry itself (SharePoint agents are the one exception, covered via
  Get-SPOCopilotAgentInsightsReport). This collector focuses on what IS scriptable —
  licensing and role prerequisites — and documents the portal steps for the rest.
#>
Connect-MgGraph -Scopes "User.Read.All","RoleManagement.Read.Directory","Organization.Read.All"

$userUpn = Read-Host "Enter UPN of the affected user/admin"
$outPath = "$env:TEMP\AgentGovernance-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
$sb = [System.Text.StringBuilder]::new()

$null = $sb.AppendLine("=== M365 COPILOT AGENT GOVERNANCE EVIDENCE PACK ===")
$null = $sb.AppendLine("UPN: $userUpn")
$null = $sb.AppendLine("Collected: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC")
$null = $sb.AppendLine("")

# License stack relevant to agent governance
$null = $sb.AppendLine("--- License Stack ---")
Get-MgUserLicenseDetail -UserId $userUpn | ForEach-Object {
    $null = $sb.AppendLine("SKU: $($_.SkuPartNumber)")
}
$null = $sb.AppendLine("")

# Directory role assignments — confirms AI Administrator / Global Administrator eligibility
$null = $sb.AppendLine("--- Directory Role Assignments ---")
$user = Get-MgUser -UserId $userUpn
$roleAssignments = Get-MgUserMemberOf -UserId $user.Id | Where-Object { $_.AdditionalProperties["@odata.type"] -eq "#microsoft.graph.directoryRole" }
foreach ($role in $roleAssignments) {
    $null = $sb.AppendLine("Role: $($role.AdditionalProperties["displayName"])")
}
$null = $sb.AppendLine("")

$null = $sb.AppendLine("--- Manual Portal Evidence To Attach ---")
$null = $sb.AppendLine("1. Screenshot: Agents > All agents > Registry entry for the affected agent (Platform, Owner, Availability)")
$null = $sb.AppendLine("2. Screenshot: Agents > All agents > Requests entry if applicable (State, Channel)")
$null = $sb.AppendLine("3. If 'at risk': screenshot of the underlying Entra/Defender/Purview finding")
$null = $sb.AppendLine("4. If Copilot Studio agent: Power Platform admin center 'Manage access to Power Platform apps' setting for this agent")
$null = $sb.AppendLine("5. If SharePoint agent: output of Get-SPOCopilotAgentInsightsReport and site/library permission listing")

$sb.ToString() | Out-File $outPath -Encoding UTF8
Write-Host "Evidence written to: $outPath" -ForegroundColor Green
notepad $outPath
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|---------|
| View agent governance dashboard | M365 admin center > Agents > Overview |
| Full agent inventory | M365 admin center > Agents > All agents > Registry |
| Pending approvals | M365 admin center > Agents > All agents > Requests (filter State/Channel) |
| Approve a new agent | Requests > select agent > Publish to store > scope audience > apply policy template > review permissions > Publish |
| Reject a submission | Requests > select agent > ellipses > Reject submission |
| Approve an agent update | Requests > filter State = Pending update > select agent > Update in store |
| Assign an owner | Overview > "Agents without owners" > Assign Owner, or Registry > agent > Assign Owner |
| Investigate an at-risk agent | Overview > "Agents at risk" > Manage agent risks > trace to Entra/Defender/Purview |
| Confirm admin role for governance actions | Entra admin center > Roles and administrators > AI Administrator / Global Administrator |
| Enable Copilot Studio agent for Teams/M365 | Power Platform admin center > Manage access to Power Platform apps |
| SharePoint agent status report (all agents, tenant-wide) | `Get-SPOCopilotAgentInsightsReport` |
| Check a user's license stack (governance-relevant SKUs) | `Get-MgUserLicenseDetail -UserId <UPN>` |
| Check a user's directory role assignments | `Get-MgUserMemberOf -UserId <UPN>` filtered to `directoryRole` |

---

## 🎓 Learning Pointers

- **Agent governance is deliberately platform-agnostic in intent but NOT platform-uniform in practice.** The M365 admin center's Agent workload is the intended single pane of glass, but Copilot Studio agents need an additional Power Platform admin center grant, and SharePoint agents bypass the Registry/Requests flow entirely in favor of ordinary file permissions. Identify the creation platform before choosing a troubleshooting path. [MS Docs: Manage agents for Microsoft 365 Copilot](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/manage)

- **"Pending update" is a frequent silent confusion point** — an in-review update does not take the previous version offline; users keep using the old one until the new one is approved. A "my agent update didn't go out" ticket is often actually "the update is sitting in Requests," not a deployment failure. [MS Docs: Manage agent requests in Microsoft 365 admin center](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-requests)

- **Governance write actions are hard-gated to AI Administrator and Global Administrator — no delegation path exists via a lower-privilege role as of current documentation.** Provision AI Administrator to the actual day-to-day governance owner rather than routing all approvals through Global Administrator, both for least-privilege hygiene and to avoid a single point of failure when that admin is unavailable. [MS Docs: Agent management roles and permissions](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-roles-perms)

- **The Registry's "Agents at risk" signal is aggregated from Entra, Defender, and Purview — it is a pointer to a finding, not the finding itself.** Resolve or accept the underlying issue in its native security portal; clearing the flag without addressing the source finding just hides the symptom until the next signal refresh re-surfaces it. [MS Docs: Agent overview in Microsoft 365 admin center](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-365-overview)

- **Researcher and Analyst are explicitly and permanently outside agent governance scope**, despite living in the same Copilot Chat surface as agents. Don't burn troubleshooting time trying to make an agent policy affect them — check the documentation's carve-out before assuming a bug. [MS Docs: Agent settings in Microsoft 365 admin center](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-settings)

- **Draft-agent visibility in the Registry currently only covers Copilot Studio.** An agent built in Agent Builder, Foundry, or SharePoint that's still in draft state will not appear in the Registry yet — absence from the Registry does not mean the agent doesn't exist, only that it isn't (yet) formally tracked there. [MS Docs: Agent overview in Microsoft 365 admin center](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-365-overview)
