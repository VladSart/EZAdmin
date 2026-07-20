# Microsoft 365 Copilot Agent Governance — Hotfix Runbook (Mode B: Ops)
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

This runbook covers **agent lifecycle governance** (approval, publishing, ownership, risk, access) for agents surfaced through Microsoft 365 Copilot — declarative agents, Copilot Studio agents, Agent Builder agents, SharePoint agents, and Frontier agents. For base Copilot **licensing/policy/grounding** issues (a user can't use Copilot at all), start at `Copilot-B.md` instead — this file assumes Copilot itself already works and the problem is specifically about an *agent*.

```
1. Sign in to Microsoft 365 admin center (admin.microsoft.com) > Agents

2. Check Overview for actionable governance gaps:
   - Pending Requests for Agents
   - Agents without owners
   - Agents at risk
   - Agents with exceptions

3. Confirm your own role — approving requests and assigning ownership REQUIRES
   AI Administrator or Global Administrator. Other roles can view but not act.

4. Go to Agents > All agents > Registry and search for the specific agent by name
   to confirm: platform (Copilot Studio / Agent Builder / SharePoint / Foundry /
   Agent Toolkit), owner, publish state, and audience scope.

5. Go to Agents > All agents > Requests and filter by State
   (Pending review / Pending update / Pending activate) and Channel
   (Teams / Copilot / Office / Outlook / Word / Excel / PowerPoint) to find a
   specific stuck submission.
```

| Result | Action |
|--------|--------|
| Agent not visible to users who should have access | → Fix 1: Confirm publish audience scope, not just approval state |
| Agent stuck in "Pending review"/"Pending update"/"Pending activate" | → Fix 2: Route to a user with AI Administrator or Global Administrator role |
| Agent flagged "at risk" | → Fix 3: Investigate the underlying Entra/Defender/Purview signal before unblocking |
| Agent has no owner shown | → Fix 4: Assign ownership before it becomes a compliance/cost gap |
| Copilot Studio agent won't appear in Teams/M365 even though it works in Copilot Studio itself | → Fix 5: Separate Copilot Studio license from Power Platform app-access control |
| SharePoint agent access behaving differently than expected | → Fix 6: Governed by Site Assets file permissions, not the Copilot Control System |
| "Governance policy applied but Researcher/Analyst still behaves oddly" | → Not a bug — Researcher and Analyst are core Copilot Chat experiences and explicitly do NOT fall under agent-related governance settings |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Licensing Layer
  └─ Microsoft 365 Copilot, Copilot Chat, or Microsoft Agent 365 license
     covering the creator and/or the consuming users
         |
Creation Platform (determines WHICH admin surface governs the agent)
  ├─ Copilot Studio (MCS DA / MCS CEA / MCS BP)  → Power Platform admin center +
  │                                                  M365 admin center Integrated Apps
  ├─ Agent Builder (in Copilot)                   → "Create an agent" entry-point toggle +
  │                                                  Share/manage in M365 admin center
  ├─ Microsoft 365 Agents Toolkit                 → Integrated Apps section
  ├─ SharePoint                                   → .agent file permissions in Site Assets
  ├─ Microsoft Foundry (LOB / non-LOB / hosted)    → Foundry + M365 admin center Registry
  └─ Microsoft, External partner, or Frontier      → Vendor/Microsoft-managed, still
     (App Builder / Workflows agent) types           inventoried in the Registry
         |
Submission (if published to the org catalog)
  └─ Enters Requests as Pending review / Pending update / Pending activate
         |
Admin Approval (AI Administrator or Global Administrator role REQUIRED —
  other roles can view governance gaps but cannot act on them)
  └─ Publish to store (with audience scope + policy template + permission consent)
     OR Reject submission
         |
Ownership Assignment
  └─ Every agent should have a designated owner for lifecycle/compliance/cost
         |
Ongoing Governance Signals
  └─ Risk flags aggregated from Entra, Defender, Purview
  └─ Usage/exception monitoring via Agent Registry + Overview dashboard
         |
Agent available to its scoped audience, tracked in the Agent Registry
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm which creation platform the agent came from before troubleshooting further.** The admin surface that actually governs an agent's availability differs by platform — a Copilot Studio agent's access is partly controlled outside the M365 admin center (Power Platform admin center), while a SharePoint agent is controlled by file permissions, not a governance policy at all.
Portal: Microsoft 365 admin center > Agents > All agents > Registry > search by name > check the **Platform** column.

**2. Confirm the agent's actual state, not just "it should be approved."** An agent can be approved but still invisible to a specific user if the publish audience was scoped narrower than expected, or if an update is sitting in "Pending update" (in which case the *previous* version remains live — users see old behavior, not a broken agent).
Portal: Agents > All agents > Requests, filter State.

**3. Confirm your own admin role before assuming a portal bug.** Approving requests and assigning ownership require **AI Administrator** or **Global Administrator** specifically — a Global Reader or generic Service Support Administrator can see the governance dashboard's gaps but every action button will be unavailable, which looks like a bug but is role-gating by design.

**4. For "agent at risk," pull the underlying signal before unblocking.** Risk flags are aggregated from Microsoft Entra, Microsoft Defender, and Microsoft Purview — treat this the same as any other security alert triage, not a governance-portal-only decision.

**5. Distinguish Researcher/Analyst from agents entirely.** These are first-party Copilot Chat tools available under **Tools**, operating inside the same commercial data-processing boundary and inheriting all existing security/compliance commitments — but they explicitly do not fall under any agent-related governance setting. If a client reports "our agent block policy isn't affecting Researcher," that's expected, not a gap.

---
## Common Fix Paths

<details><summary>Fix 1 — Agent approved but not visible to expected users (audience scope)</summary>

1. Microsoft 365 admin center > Agents > All agents > Registry > select the agent.
2. Confirm **Availability status** and the specific users/groups the agent was scoped to during publishing — approval and audience scope are set together in the same wizard but are logically separate; an agent can be fully approved and still deliberately excluded from a given user/group.
3. If the audience needs to be widened, re-run the publishing flow (Agents > All agents > Requests, or edit an already-published agent's scope from the Registry) to add the missing users/groups.
4. For agents shared by their creator (not org-published), confirm the creator actually shared with the affected user — creator-shared agents are a separate access path from admin-published ones.

**Rollback:** Narrow the audience scope back if the wider access was granted in error.

</details>

---

<details><summary>Fix 2 — Agent stuck in Pending review / Pending update / Pending activate</summary>

1. Confirm a user with **AI Administrator** or **Global Administrator** role is available to action the request — this cannot be delegated to a lower-privilege role.
2. Microsoft 365 admin center > Agents > All agents > Requests > filter by the specific **State** and **Channel**.
3. Select the agent and review its details pane: description, owner, data sources, custom actions, and requested permissions.
4. For **Pending review**: select **Publish to store**, choose audience (users/groups, or everyone), apply a policy template (existing, default, or custom), review and grant/deny requested Graph permissions, then **Publish**. Or select **Reject submission** if it should not be made available.
5. For **Pending update**: select **Update in store** once the new version's changes have been reviewed — until then, the previous version remains live for existing users.
6. For **Pending activate**: this gates a user's ability to *create instances* of the agent, not just use it — review and approve/reject the same way, scoping audience on activation.

**Rollback:** Reject the submission or revert to the previously published version if the update introduces unwanted behavior.

</details>

---

<details><summary>Fix 3 — Agent flagged "at risk"</summary>

1. Microsoft 365 admin center > Agents > All agents > Registry, filter by risk, or select **Manage agent risks** from the Overview dashboard's "Agents at risk" card.
2. Identify the source signal — Entra (identity/permission risk), Defender (security detection), or Purview (compliance/DLP) — each has its own investigation path in its native portal.
3. Do not simply unblock the agent to resolve the ticket faster; resolve or explicitly accept the underlying risk in its source system first, since the agent-governance flag is a surfaced symptom, not the actual control.
4. Once the underlying finding is remediated or accepted, the risk flag should clear on its own signal-refresh cycle; if it persists after remediation, treat as a sync-lag issue and re-check before escalating.

**Rollback:** N/A — this is a security-triage path, not a reversible configuration change.

</details>

---

<details><summary>Fix 4 — Agent has no assigned owner</summary>

1. Microsoft 365 admin center > Agents > Overview > "Agents without owners" card > **Assign Owner**, or Registry filtered to ownerless agents.
2. Identify the actual creator/publisher from the agent's metadata (creation date, publisher field) to determine the right owner — don't default to yourself or a generic service account unless genuinely appropriate.
3. Assign ownership; this is required for lifecycle management (who approves future updates), compliance accountability, and cost/usage review — an ownerless agent is a standing governance gap even if it's functioning correctly today.

**Rollback:** Reassign to a different owner if the initial assignment was incorrect; ownership can be changed at any time.

</details>

---

<details><summary>Fix 5 — Copilot Studio agent works in Copilot Studio but won't appear in Teams/Microsoft 365</summary>

Copilot Studio agent availability inside Microsoft 365 Copilot is gated by **two independent controls**, not one:

1. **Copilot Studio User License** — confirm the creator/user has a license enabling them to create and manage agents in Copilot Studio itself.
2. **Manage access to Microsoft Power Platform apps** — a *separate* setting that must explicitly enable the existing Copilot Studio agent for Teams and Microsoft 365; having the Copilot Studio license alone does not automatically surface the agent in M365 Copilot.
3. Once both are confirmed, the agent still needs to go through the same **Integrated apps** publish/approval flow as any other agent for tenant-wide availability (Fix 2).

**Rollback:** Revoke Power Platform app access if the agent should be restricted back to Copilot Studio-only use.

</details>

---

<details><summary>Fix 6 — SharePoint agent access issue</summary>

SharePoint agents are represented as `.agent` files inside each site's **Site Assets** library — they are governed by **file/library permissions**, not the Copilot Control System's publish/approval workflow.

1. Confirm the requesting user's actual permission on the specific site's Site Assets library (or the `.agent` file itself if uniquely permissioned) — this is a standard SharePoint permissions check, not an agent-governance setting.
2. If billing is pay-as-you-go for this agent, confirm Org Settings in the Microsoft 365 admin center has PAYG configured for SharePoint agents, and that Azure billing is correctly linked.
3. Use `Get-SPOCopilotAgentInsightsReport` to view status/details across all active and available SharePoint Copilot agents in the tenant when auditing at scale.

**Rollback:** Adjust site/library permissions back if wider access was granted in error — standard SharePoint permission-change caution applies.

</details>

---
## Escalation Evidence

```
=== M365 COPILOT AGENT GOVERNANCE ESCALATION TEMPLATE ===
Agent name: ___________
Creation platform (Copilot Studio / Agent Builder / SharePoint / Foundry / Agent Toolkit / Microsoft / External / Frontier): ___________
Agent type (MCS DA / MCS CEA / MCS BP / Foundry LOB / Foundry non-LOB / Foundry hosted / Agent Builder / SharePoint / Agent Toolkit / Agent instance): ___________
Current state (Registry status, Requests state if applicable): ___________
Symptom (not visible to user / stuck pending / flagged at risk / no owner / Teams-visibility gap / SharePoint permission issue): ___________
Affected user(s)/group(s): ___________
Admin role of person attempting the action (must be AI Administrator or Global Administrator to approve/assign): ___________
Risk signal source if "at risk" (Entra / Defender / Purview) and finding summary: ___________
Owner currently assigned (if any): ___________
Screenshot of Registry entry / Requests entry (attach): ___________
Timeline (when reported / first observed): ___________
```

---
## 🎓 Learning Pointers

- **Which admin surface actually governs an agent depends entirely on how it was built.** Copilot Studio agents need both a Copilot Studio license AND a separate Power Platform app-access grant before they reach Microsoft 365 Copilot; SharePoint agents are governed by ordinary file permissions, not the Copilot Control System at all. Always confirm the creation platform first — applying the wrong governance model wastes the whole triage. [MS Docs: Manage agents for Microsoft 365 Copilot](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/manage)

- **Approving requests and assigning ownership require AI Administrator or Global Administrator specifically — no other role can act, only view.** A Global Reader seeing governance gaps on the Overview dashboard with every action button unavailable is by-design role-gating, not a bug. Use the least-privileged role that can actually complete the task; reserve Global Administrator for genuine emergencies. [MS Docs: Agent management roles and permissions](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-roles-perms)

- **Researcher and Analyst are NOT agents from a governance standpoint**, even though they sit alongside agents in the Copilot Chat experience. They inherit all standard Microsoft 365 security/compliance commitments but explicitly fall outside every agent-related governance policy — don't spend triage time trying to make an agent-blocking policy affect them. [MS Docs: Agent settings in Microsoft 365 admin center](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-settings)

- **An agent stuck in "Pending update" still serves its previous version to users** — this is often mistaken for "the agent isn't updating" when actually the update itself is what's blocked pending approval. Check the Requests state before assuming a deployment failure. [MS Docs: Manage agent requests in Microsoft 365 admin center](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-requests)

- **Microsoft Agent 365 is the unifying control plane across build platforms**, but licensing is layered: Copilot Chat (web-data agents only) vs. full Microsoft 365 Copilot (web + work data agents) vs. Microsoft Agent 365 itself — confirm which license the affected user/agent actually has before assuming a governance-policy problem when it's really a licensing-scope gap. [MS Docs: Agent overview in Microsoft 365 admin center](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-365-overview)
