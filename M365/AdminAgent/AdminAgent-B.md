# Microsoft 365 Admin Agent — Hotfix Runbook (Mode B: Ops)
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

**Read this first:** The Microsoft 365 Admin agent is Microsoft's own first-party, natural-language AI agent for running IT admin tasks — "list all global admins," "assign Adele Vance a Copilot license," "why can't guest users edit Teams chat messages" — surfaced in three places: **Microsoft 365 Copilot Chat** (all tenants), the **Microsoft 365 admin center** (via the Copilot button, all tenants), and a lighter, SMB-scoped surface **inside Microsoft Teams itself** (organizations up to ~300 users, GA since May 2026). It requires **no additional Microsoft 365 Copilot or Microsoft Agent 365 license** — every admin already has it. It is **not** the same thing as agent lifecycle governance (approving/publishing/owning agents in the Agent Registry) — for that, go to `Copilot/AgentGovernance-B.md` instead. This file covers using, restricting, and troubleshooting the Admin Agent itself.

```powershell
# 1. Confirm your own Entra role — the agent's answers and available actions are a MIRROR of
#    your existing role assignments, not a separate permission grant.
Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<yourObjectId>'" -ExpandProperty roleDefinition |
    Select-Object -ExpandProperty RoleDefinition | Select-Object DisplayName

# 2. Confirm who can BLOCK or SCOPE the agent tenant-wide (Registry governance action) —
#    only AI Administrator or Global Administrator can do this; other roles can only view.
Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '{AI-Admin-role-id}'" -ExpandProperty principal

# 3. Confirm which Copilot/Agent 365 licenses actually exist in the tenant (informational —
#    the Admin Agent itself doesn't need one, but it affects what OTHER agents/features exist)
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "Copilot|Agent365|SPE_E7" } |
    Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits
```

| Result | Action |
|--------|--------|
| Agent missing from Teams entirely, works fine in Copilot Chat/admin center | → Fix 1: SMB-Teams surface is a separate, narrower rollout — check eligibility, not licensing |
| Agent says it can't do something, or shows less data than expected | → Fix 2: Not a bug — the agent reflects your own Entra role, it grants no new privilege |
| Agent proposed an action but nothing changed in the tenant | → Fix 3: Expected — every write/execute action requires explicit confirmation, the agent never self-executes |
| Need to shut the agent off org-wide or for a subset of users | → Fix 4: Agent Registry Block/scope action — AI Administrator or Global Administrator only |
| Can't find a record of what the agent changed | → Fix 5: There is no separate "Admin Agent log" — check the underlying workload's own audit log |
| Client asking whether tenant data trains the AI model | → Fix 6: No — same Copilot data/privacy commitments as every other Copilot surface |
| Agent suggested disabling a security control (e.g. Copilot screen sharing, camera sharing) | → Fix 7: Treat every agent-proposed action as a draft recommendation, review before confirming — same as any admin script |
| SMB client asking if this replaces their MSP relationship | → Fix 8: Positioning conversation — the agent handles routine tasks/guidance, not judgment calls, incident response, or governance design |
| Multiple admins say the agent "remembers" something from a different app | → Fix 9: Expected — cross-surface context continuity is a designed feature, not a leak |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Signed-in user holds an Entra admin role (any admin role — no minimum beyond having one)
    │
    ▼
Microsoft 365 Admin agent (pre-installed, no Copilot/Agent 365 license required)
    │
    ├── Surface: Microsoft 365 Copilot Chat (m365.cloud.microsoft) → Agents panel → all tenants
    ├── Surface: Microsoft 365 admin center (admin.microsoft.com) → Copilot button → all tenants
    └── Surface: Microsoft Teams (desktop) → SMB-scoped, ~300-user ceiling, GA May 2026,
                  Worldwide Standard Multi-Tenant cloud only at GA
    │
    ▼
Built on the Agent 365 Platform SDK, connected to native MCP (Model Context Protocol) tool
servers — ONLY the Microsoft 365 Admin agent can use these native MCP tools; they invoke
Microsoft Graph APIs and other admin services on the signed-in user's behalf
    │
    ▼
RBAC gate (per-request, not a separate agent-level permission)
    Existing Entra role assignments (Global Administrator, AI Administrator, User Administrator,
    Teams Administrator, SharePoint Administrator, etc.) govern EVERY action the agent proposes
    or performs — the agent has no standing privilege of its own and cannot see or do anything
    the signed-in admin's own roles don't already allow
    │
    ▼
Write/execute confirmation gate (mandatory, no exceptions)
    Any action that changes tenant state requires explicit admin confirmation before it runs —
    the agent never makes changes autonomously
    │
    ▼
Underlying workload executes the action normally
    (Microsoft Graph, Microsoft 365 admin center, Entra ID, Microsoft Teams admin services)
    │
    ▼
Audit trail — recorded in the SAME logs as if the action were taken manually
    (Microsoft 365 admin center audit log, Microsoft Entra audit log, Microsoft Teams admin log)
    — there is no separate, agent-specific audit surface
    │
    ▼
Governance layer (separate control plane, shared with EVERY agent in the tenant)
    Agent Registry (Microsoft 365 admin center → Agents → Registry) — AI Administrator or
    Global Administrator can Block the agent entirely or scope its deployment to specific
    users/groups; see Copilot/AgentGovernance-B.md for the general Registry mechanics
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm which surface the complaint is about.** Teams SMB surface, Copilot Chat, and the admin center's Copilot button are three different entry points into the same agent — a gap in one does not imply a gap in the others.
   - Good: reproduce in Copilot Chat or the admin center if Teams is the reported gap, to isolate whether this is agent-wide or Teams-surface-specific.
   - Bad: only reproducible nowhere → escalate as a genuine platform issue, not a config gap.

2. **Confirm the signed-in admin's own Entra role assignments** before assuming the agent is broken.
   ```powershell
   Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<objectId>'" -ExpandProperty roleDefinition |
       Select-Object -ExpandProperty RoleDefinition | Select-Object DisplayName
   ```
   - Good: role assignment matches the capability being requested (e.g., User Administrator for license assignment, Teams Administrator for Teams chat policy questions).
   - Bad: role assignment doesn't cover the requested capability → Fix 2, this is expected behavior, not a defect.

3. **If a proposed action seemingly "didn't happen," confirm whether the confirmation step was actually completed.**
   - Good: admin recalls explicitly confirming (e.g., clicking through a "Yes, assign this license" prompt) and the action still didn't apply → genuine issue, escalate with Evidence Pack.
   - Bad: admin only asked the agent and never confirmed → Fix 3, expected behavior.

4. **If blocking/restricting the agent, confirm the acting admin holds AI Administrator or Global Administrator.**
   - Good: role confirmed, action taken from Microsoft 365 admin center → Agents → Registry → locate "Microsoft 365 Admin" → Block or scope deployment.
   - Bad: any other role attempted the action → Fix 4, insufficient privilege by design.

5. **For "where's the audit trail" requests, identify which underlying workload the action touched, then search that workload's own log — not a dedicated agent log.**
   - License/user/group change → Microsoft 365 admin center audit log or Entra audit log.
   - Teams-specific action → Microsoft Teams admin center audit log.
   - Good: action found in the appropriate underlying log, attributed to the signed-in admin.
   - Bad: nothing found in any underlying log despite a confirmed action → Fix 5, escalate.

6. **For data-handling/privacy questions, ground the answer in Microsoft's published Copilot privacy commitments rather than assumption** — see Fix 6 and the Learning Pointers below.

---
## Common Fix Paths

<details><summary>Fix 1 — Agent missing from Microsoft Teams, but works in Copilot Chat or the admin center</summary>

**When to use:** An SMB admin expects the in-Teams Admin Agent experience (add users, assign licenses, org setup/security/password-reset guidance without leaving Teams) but doesn't see it, even though the agent responds normally elsewhere.

1. Confirm this is genuinely the **Teams-embedded SMB surface**, not just "using Copilot Chat inside the Teams app" — these are architecturally different entry points into the same underlying agent.
2. Check tenant size and profile against the documented target: organizations with up to roughly 300 users that rely on Microsoft 365 for core productivity without a dedicated full-time IT admin. This is the intended audience for the Teams-embedded surface specifically — larger or more complex tenants are expected to use Copilot Chat or the admin center instead, not a broken rollout.
3. Confirm platform and cloud instance: GA as of May 2026, **Desktop Teams client only** at GA, **Worldwide (Standard Multi-Tenant)** cloud instance only — GCC/GCC High/DoD, sovereign clouds, and the Teams web/mobile clients are not confirmed at the same GA date. Check current Message Center posts for this tenant's specific rollout status before assuming a fault.
4. If the tenant profile and platform both qualify and the surface still isn't appearing, treat this as a rollout-timing gap (Microsoft 365 features roll out in rings) rather than a misconfiguration — there is no tenant-side setting that enables/disables this specific surface independent of the general agent block/scope control in Fix 4.
5. In the meantime, direct the admin to Copilot Chat (`m365.cloud.microsoft` → Agents → Microsoft 365 Admin) or the admin center's Copilot button — functionally the same agent, same capabilities, different entry point.

**Rollback:** N/A — availability/rollout investigation, no configuration change.

</details>

<details><summary>Fix 2 — Agent says it can't do something, or returns less data than an admin expects</summary>

**When to use:** An admin asks the agent to view or change something and gets a permission-related response, an incomplete answer, or a capability that "should" work per the documented example prompts doesn't.

1. Explain the core design principle first, since this is the single most common misunderstanding with this tool: **the agent has no standing privilege of its own.** It honors the signed-in admin's existing Entra role-based access control assignments exactly — if a capability requires a role the admin doesn't hold, the agent can't do it either, regardless of what the general example-prompt list suggests is possible in principle.
2. Confirm the admin's actual role assignments:
   ```powershell
   Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<objectId>'" -ExpandProperty roleDefinition |
       Select-Object -ExpandProperty RoleDefinition | Select-Object DisplayName
   ```
3. Map the requested capability to the role that actually governs it (not necessarily an AI-specific role) — e.g., license assignment needs User Administrator or Global Administrator; Teams chat policy troubleshooting needs Teams Administrator; agent registry actions specifically need AI Administrator or Global Administrator.
4. If the role is missing and the capability is genuinely needed, assign the least-privileged role that covers it — do not default to Global Administrator to "make the agent work," the same least-privilege guidance applies here as to any other admin tooling.
5. If the role IS correctly assigned and the agent still can't act, this becomes a genuine support case — escalate with the Evidence Pack below rather than continuing to assume a permissions gap.

**Rollback:** N/A — diagnostic/role-assignment correction, not a destructive change.

</details>

<details><summary>Fix 3 — Agent proposed an action but the tenant wasn't actually changed</summary>

**When to use:** An admin asked the agent to do something (assign a license, block an agent, change a Copilot setting) and later found the tenant state unchanged.

1. Confirm explicitly whether the admin completed the **confirmation step** — every write or execute action the agent proposes requires an explicit admin confirmation before it runs. The agent never makes tenant changes on its own initiative, by design, regardless of how the request was phrased.
2. Re-run the request and watch for the confirmation prompt this time; confirm it deliberately.
3. If the admin is certain they confirmed and the action still didn't apply, check the appropriate underlying workload's audit log (see Fix 5) to determine whether the action was attempted and failed, versus never attempted at all — this determines whether the next step is a permissions issue (Fix 2) or a genuine platform defect to escalate.

**Rollback:** N/A — no unintended change occurred; this fix path is about confirming intended changes actually apply.

</details>

<details><summary>Fix 4 — Need to block or restrict the Admin Agent org-wide or for a subset of users</summary>

**When to use:** A client wants to disable the Microsoft 365 Admin agent entirely, or limit it to a specific group of admins (e.g., during a pilot, or for compliance reasons).

1. Confirm the acting admin holds **AI Administrator** or **Global Administrator** — this is the same Registry governance mechanism used for every other agent type in the tenant, not a dedicated Admin-Agent-only control.
2. Sign in to the Microsoft 365 admin center (`admin.cloud.microsoft`) as that role.
3. Go to **Agents → Registry**, locate **Microsoft 365 Admin** in the list.
4. Choose **Block** to disable it tenant-wide, or use the scoped-deployment action to limit it to specific users or groups instead of the full organization.
5. Set the correct expectation: blocking this specific agent restricts admins from invoking it through Copilot Chat and admin-center surfaces — it does **not** affect any other Microsoft 365 admin center functionality; admins simply lose the natural-language shortcut and fall back to the standard portal/PowerShell/Graph paths they already had.
6. Cross-reference `Copilot/AgentGovernance-B.md` for the general Registry mechanics if this is part of a broader agent-governance conversation rather than a single-agent decision.

**Rollback:** Reverse the Block action or widen the deployment scope from the same Registry entry; takes effect on the same propagation timeline as any other Registry governance change.

</details>

<details><summary>Fix 5 — Can't find a record of what the agent changed</summary>

**When to use:** A client or internal reviewer wants to audit an action the agent took and can't find it in an "agent log."

1. Set the expectation up front: **there is no separate, dedicated audit log for the Microsoft 365 Admin agent.** Every action it performs is recorded in the same underlying workload audit log that would capture the identical action taken manually.
2. Identify which workload the action touched, then search there:
   - User/license/group changes → Microsoft 365 admin center audit log, or Microsoft Entra audit log.
   - Teams-specific actions (policy changes surfaced via the agent's Teams administration prompts) → Microsoft Teams admin center audit log.
3. The log entry attributes the action to the **signed-in admin**, not to "the agent" as a distinct actor — this is by design, consistent with the RBAC-reflection model in Fix 2.
4. If genuinely nothing appears in any underlying log despite a confirmed action having been taken, this is an anomaly worth escalating with the Evidence Pack — do not conclude "no log exists for this feature" without checking every workload the action plausibly touched.

**Rollback:** N/A — investigative workflow, no configuration change.

</details>

<details><summary>Fix 6 — Client asking whether their tenant data is used to train the AI model</summary>

**When to use:** A compliance-conscious client (or your own due-diligence process before enabling this for a regulated tenant) asks how the Admin Agent handles organizational data.

1. Confirm this agent is subject to the **same Microsoft 365 Copilot data, privacy, and security commitments** as every other Copilot surface — it is not a separate product with separate terms.
2. Key facts to relay directly, not paraphrased from memory:
   - Prompts, responses, and data accessed through Microsoft Graph are **not** used to train foundation LLMs.
   - The agent honors the same Microsoft Graph permission model as every other Microsoft 365 service — it can only surface data the signed-in admin's own role already permits.
   - EU customers retain EU Data Boundary protections for this agent the same as other Copilot experiences (with the standard, separately-documented Anthropic-subprocessor EU Data Boundary exclusion, if the tenant has that subprocessor enabled).
   - Actions are audited in the underlying workload's own logs (see Fix 5) — there is no black-box execution path.
3. Point compliance reviewers to the canonical source rather than this runbook's summary for anything contractually significant — see the Learning Pointers below for the exact Microsoft Learn article.

**Rollback:** N/A — informational response, no configuration change.

</details>

<details><summary>Fix 7 — Agent suggested disabling a security-relevant setting and an admin confirmed it without review</summary>

**When to use:** An admin used the agent to "turn off Copilot screen sharing," "disable camera sharing with Copilot," or a similarly security-relevant prompt and it turns out that wasn't actually the desired end state.

1. Treat this as a process gap, not a product defect — the agent executed exactly what was confirmed, correctly, by design.
2. Reverse the specific setting using the same agent (ask it to re-enable the setting, confirm again) or the standard admin-center/PowerShell path for that setting — there's nothing agent-specific about the rollback itself.
3. For the client conversation: recommend treating every agent-proposed write action with the same review discipline as a proposed PowerShell script or a portal change — read the confirmation prompt's specific wording before confirming, especially for prompts that broadly affect security posture, tenant-wide settings, or bulk operations.
4. If this is a recurring risk for a specific client (e.g., junior helpdesk staff with access), recommend scoping the agent's deployment (Fix 4) to a smaller, more experienced admin group rather than relying on training alone.

**Rollback:** Depends entirely on the specific setting changed; use the normal rollback procedure for that setting (most Copilot/Teams tenant settings are simple boolean toggles, reversible the same way they were set).

</details>

<details><summary>Fix 8 — SMB client asks whether the Admin Agent replaces the need for an MSP</summary>

**When to use:** A prospective or existing SMB client, having seen the Teams-embedded "run admin tasks faster" messaging, asks whether they still need managed IT support.

1. Position accurately rather than defensively: the agent's documented scope is genuinely narrow and task-level — adding users, assigning licenses, and providing guided help on setup/security/password-reset topics, all gated by the admin's own existing role and requiring their own explicit confirmation for every change.
2. It does **not** perform judgment calls, incident response, security architecture decisions, license/cost optimization strategy, compliance program design, vendor management, or anything requiring cross-system context the agent doesn't have visibility into.
3. It also does not remove the need for someone in the org to **hold an appropriate Entra admin role in the first place** — a genuinely unmanaged tenant with no admin oversight doesn't become managed just because an AI agent is available to whoever happens to sign in.
4. Frame this honestly as a complementary tool that reduces routine-task friction, not a governance or advisory replacement — consistent with how this repo frames other self-service/automation tooling elsewhere (e.g., Planner's non-standard PowerShell tooling, Loop's manual offboarding gap) as areas where an MSP's oversight remains genuinely necessary despite self-service options existing.

**Rollback:** N/A — positioning/expectation-setting conversation, no configuration change.

</details>

<details><summary>Fix 9 — Admins report the agent "remembers" something from a different surface</summary>

**When to use:** An admin starts a task in Copilot Chat, continues it in the admin center (or vice versa), and is surprised the agent retains the earlier context.

1. Confirm this is expected, documented behavior, not a data-isolation concern: admins can start a task in one experience and complete it in another **without losing context** — e.g., asking "who are the unlicensed users in my org?" in Copilot Chat, then continuing with "assign Adele Vance a Microsoft 365 E7 license" from the admin center in the same flow.
2. This continuity is scoped to the **signed-in admin's own session/interactions**, not shared across different admins' sessions — if the concern is about cross-user data leakage rather than single-user cross-surface continuity, escalate as a genuine anomaly rather than accepting this fix as the explanation.

**Rollback:** N/A — expected-behavior clarification.

</details>

---
## Escalation Evidence

```
=== Microsoft 365 Admin Agent Escalation ===
Ticket #:
Client / Tenant:
Surface affected (Teams / Copilot Chat / M365 admin center):
Signed-in admin's Entra role(s):
Exact prompt/request given to the agent:
Confirmation step completed (Y/N):
Underlying workload the action should have touched:
Audit log checked (which one) and result:
Agent Registry state for "Microsoft 365 Admin" (Blocked / Scoped / Unrestricted):
When did the issue start:
What changed (client-reported):
Escalation target:            [ ] Microsoft Support   [ ] Internal L3   [ ] AI Administrator / Global Administrator
```

---
## 🎓 Learning Pointers

- **The Admin Agent has no standing privilege of its own — it is a natural-language front end over the signed-in admin's existing Entra role assignments.** This is the single fact that resolves most "the agent won't do X" tickets; check the admin's role before assuming a product gap. See [Use Microsoft 365 Admin agent](https://learn.microsoft.com/en-us/microsoft-365/copilot/copilot-ai-admin-agent).

- **Blocking or scoping this specific agent uses the same Agent Registry governance mechanism as every other agent in the tenant** (Copilot Studio, Agent Builder, SharePoint agents, etc.) — only **AI Administrator** or **Global Administrator** can take that action; other roles, including Security Administrator and Global Reader, can view Registry data but cannot act on it. See [Agent management roles and permissions in Microsoft 365 admin center](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-roles-perms).

- **No additional Microsoft 365 Copilot or Microsoft Agent 365 license is required to use the Admin Agent** — a genuinely unusual licensing position worth confirming with clients directly, since it's easy to assume (incorrectly) that any AI agent implies a Copilot licensing conversation. See [Use Microsoft 365 Admin agent — Prerequisites](https://learn.microsoft.com/en-us/microsoft-365/copilot/copilot-ai-admin-agent#prequisites).

- **Every write or execute action requires explicit admin confirmation — the agent never changes tenant state on its own initiative.** Build client-facing expectations and internal helpdesk training around reviewing the confirmation prompt's exact wording, not just approving reflexively. See [Data, Privacy, and Security for Microsoft 365 Copilot](https://learn.microsoft.com/en-us/microsoft-365/copilot/microsoft-365-copilot-privacy).

- **The SMB-scoped, in-Teams surface (up to ~300 users, GA since May 2026, Desktop client, Worldwide Standard Multi-Tenant cloud) is architecturally the same agent as the Copilot Chat/admin center surfaces, just a narrower entry point** — don't treat its absence in a larger or non-Worldwide-multi-tenant client as a defect. Re-verify current platform/cloud-instance coverage against the Microsoft 365 Roadmap before promising availability, since this is a fast-evolving rollout. See [Microsoft 365 Roadmap ID 558255](https://www.microsoft.com/microsoft-365/roadmap?id=558255).

- **All agent actions are audited through the same underlying workload logs used for manual admin actions — there is no separate Admin-Agent-specific audit surface to search.** Route escalations to the correct underlying log (M365 admin center, Entra, or Teams admin audit log) based on what the action actually touched. See [Agent overview in Microsoft 365 admin center](https://learn.microsoft.com/en-us/microsoft-365/admin/manage/agent-365-overview).
