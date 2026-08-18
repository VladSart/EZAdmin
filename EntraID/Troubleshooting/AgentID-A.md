# Microsoft Entra Agent ID — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This covers **Microsoft Entra Agent ID**, the identity and security framework (reached General Availability April 2026) that extends Microsoft Entra's identity, access, and governance model to AI agents as first-class, nonhuman identities. It assumes:

- The reader already understands standard Entra concepts (app registrations, service principals, Conditional Access, entitlement management, Identity Protection) — this topic builds on top of those rather than re-explaining them.
- **Out of scope:** the M365 admin center **Agent Registry** (catalog/publish/approve/pin agents for Copilot surfaces — see `M365/Copilot/AgentGovernance-A.md`/`-B.md`), and first-party agents that consume this platform, such as the **Microsoft 365 Admin Agent** (see `M365/AdminAgent/AdminAgent-A.md`/`-B.md`), which has no standing privilege of its own and instead reflects the signed-in admin's existing Entra roles rather than using an Agent ID identity per se.
- This topic assumes Microsoft Agent 365 licensing questions are the exception, not the rule, for basic object creation — the platform's core identity constructs (creating and managing agent identities/blueprints) are available to **all** Entra customers with no additional license. Agent 365 is required specifically to extend Entra's *security and governance* features (Conditional Access, Identity Protection, ID Governance at scale) to those objects.
- Graph API surfaces referenced here (`agentIdentity`, `agentIdentityBlueprint`, `agentIdentityBlueprintPrincipal`, `agentUser`) are documented at **beta** as of this writing — schema and endpoint paths are subject to change ahead of v1.0 promotion.

---
## How It Works

<details><summary>Full architecture</summary>

**The four object types.** Agent ID introduces four new directory object types, distinct from application/service-principal objects and from user objects:

```
Agent identity blueprint (template)
  │  Defines: exposed/required OAuth 2 permission scopes, appRoles, audience, verification,
  │  authentication config, credentials — everything an agent instance will inherit.
  │
  ├── Agent identity blueprint principal (OPTIONAL — only for multitenant-capable agents)
  │     A representation of the blueprint brought into a CONSUMING tenant, analogous to how a
  │     multitenant application has a service principal object in every tenant that consented to
  │     it. Lets a multitenant agent create agent identities inside that consuming tenant.
  │     EXEMPT from the sponsor-required-at-creation rule (unlike the two objects below).
  │
  └── Agent identity (individual instance, created FROM a blueprint)
        Inherits OAuth 2 delegated permission scopes from its parent blueprint at creation.
        This is the object that actually authenticates and acts.
          │
          └── Agent user (OPTIONAL, 1:1 paired account)
                A companion Entra USER object — persistent identity, mailbox, calendar, Teams
                channel access, document access. Does NOT replace the agent identity; both
                objects exist simultaneously and typically share the same sponsor.
                Use ONLY when the agent must access systems that fundamentally require a user
                object (mailbox-bound workflows, Teams-native experiences).
```

**Two authentication patterns, matching two deployment models:**

- **Interactive agents** act on behalf of a signed-in user via the OAuth 2 on-behalf-of (OBO) flow, using Entra **delegated permissions**. Examples: a chat-interface sales-recommendation assistant, a support-escalation helper.
- **Autonomous agents** run independently under their own identity via the **client credentials flow**, with no human in the loop at authentication time. Examples: a background log-monitoring agent, an unattended infrastructure-deployment agent.

An agent's user account (if one exists) is a third, complementary surface — it lets the SAME underlying agent also hold genuinely user-shaped resources, authenticated separately from the agent identity's own client-credential flow.

**Protocol support.** The platform supports OAuth 2.0 for authentication, and both Model Context Protocol (MCP) and agent-to-agent (A2A) for tool use and inter-agent communication — with agent-to-agent discovery and authorization built on these standard protocols rather than a proprietary Microsoft-only handshake.

**Cross-platform by design, not Microsoft-only.** Agents built on non-Microsoft platforms (AWS Bedrock, n8n, and others) can still receive a governed Entra Agent ID via one of two integration paths: the **Microsoft Entra ID Auth SDK (sidecar)**, or standard **workload identity federation**. Neither path is automatic — a third-party agent existing in a tenant does NOT mean it has an Agent ID unless one of these was explicitly configured. First-party products that DO auto-provision Agent ID objects on your behalf include Microsoft Foundry (a default blueprint + identity per project, a dedicated blueprint + identity per published agent), Copilot Studio (preview auto-create setting), Azure App Service/Functions (opt-in agent identity platform integration), and the Teams platform Developer Portal.

**The administrative model deliberately separates three concerns** that are conflated in most systems into a single "admin" role:

| Relationship | Concern | Allowed principal types | Required? | Can modify config? | Can disable/delete? |
|---|---|---|---|---|---|
| **Owner** | Technical operation | Users (incl. guests), service principals — NOT groups | Optional | Yes (auth properties, credentials, other owners/sponsors) | Yes (also: re-enable, restore soft-deleted, hard-delete — sponsors cannot) |
| **Sponsor** | Business accountability | Users (incl. guests), Dynamic (security/M365) groups, Assigned M365 groups — NOT role-assignable groups, NOT assigned-security groups | **Required** at creation for agent identity + blueprint (NOT blueprint principal) | No | Yes (disable, soft-delete, modify sponsor list — non-destructive lifecycle only) |
| **Manager** | Org-hierarchy access requests | Individual users only | Optional | No | No |

This split exists so that a business stakeholder (sponsor) can make "is this agent still needed" calls without ever touching its credentials, while a technical owner can rotate credentials without needing business justification authority — and so that neither role alone can both silently reconfigure AND silently kill an agent without the other's visibility.

**Sponsor limits differ by object.** An agent identity/blueprint/blueprint-principal allows up to 100 sponsors with no more than 5 of them being groups. An agent's USER ACCOUNT (a different object, governed by the pre-existing B2B-sponsor mechanism, not the Agent ID administrative model) allows a maximum of 5 sponsors, any group type, with no direct authorization to modify the sponsored object at all. These are easy to conflate because both use the word "sponsor" — they are different mechanisms with different rules.

**Access is layered, not monolithic.** A freshly created agent identity has only the OAuth 2 delegated scopes inherited from its parent blueprint. Additional resource access — security group membership, application OAuth API permissions (including Graph), or Entra directory roles — is granted through **entitlement management access packages**, via three distinct request pathways: the agent identity itself programmatically calling the `accessPackageAssignmentRequest` API, its sponsor requesting on its behalf (with human oversight built into the request), or an administrator directly assigning it. Access package assignment policies must explicitly enable "users, service principals, and agent identities" plus an "All agents" (or scoped) selector — the default policy shape does not cover agent identities.

**Zero Trust enforcement mirrors the human-identity model.** Conditional Access policies can target agent identities the same way they target users, with the added capability of applying a policy at the **blueprint level** so every current and future instance created from that blueprint inherits it automatically — including the ability to disable an entire class of agents in one operation by editing the blueprint-level policy. Microsoft Managed Policies provide an out-of-the-box baseline that blocks high-risk agents. Identity Protection extends risk detection to agents: an agent's risk score is derived both from the linked user's risk (for interactive/OBO-flow agents) and from the agent's own anomalous action patterns (for autonomous agents), feeding back into Conditional Access as a real-time signal.

**Governance targets "agent sprawl" as a named, first-class risk**, not an incidental side effect. Agent sprawl is the uncontrolled proliferation of agents without adequate ownership, visibility, or lifecycle control — created by business units without IT oversight (shadow AI), left running past their intended purpose, or holding permissions never subsequently reviewed. The Agent Registry's Shadow agent risk type (Critical severity) operationalizes this: it fires when an agent has no Registry entry, no owner, OR no Entra Agent ID — any single missing prerequisite is sufficient, making the check a logical OR, not an AND, across three independently-sourced signals (Entra + M365 admin center).

</details>

---
## Dependency Stack

```
Layer 0 — Tenant & Licensing
  Microsoft Entra tenant (any edition) → Agent ID platform available, no extra license
  Microsoft Agent 365 (M365 E7 bundled | add-on to E5/A5/Business Premium
    | Defender Suite + Purview Suite) → required to extend CA/Identity Protection/Governance
    to agent objects
  Entra ID Governance license (M365 E7, or Agent 365 + Entra P1/M365 E3 minimum)
    → required specifically for governing agent identities via ID Governance features

Layer 1 — Object Model (Microsoft Graph beta: agentIdentity, agentIdentityBlueprint,
  agentIdentityBlueprintPrincipal, agentUser)
  Agent identity blueprint
    → Agent identity blueprint principal (multitenant only, sponsor-exempt)
    → Agent identity (inherits blueprint's delegated scopes)
        → Agent user (optional, 1:1, separate B2B-style sponsor rules)

Layer 2 — RBAC Roles (tenant-wide, Entra admin center > Roles & administrators)
  Agent ID Administrator (privileged) — full lifecycle CRUD across all four object types,
    hard-delete/restore, license + session management for agent users
  Agent ID Developer — delegated create of blueprint + blueprint principal, auto-owner
  Agent Registry Administrator — Registry metadata/collections/visibility only (M365
    admin center surface, NOT the Entra objects themselves)
  AI Administrator (privileged) — OVERLAPS Agent ID Administrator's full agent-identity
    CRUD, PLUS Copilot/Integrated Apps/admin-consent-policy governance

Layer 3 — Object-Level Administrative Relationships (independent of Layer 2 roles)
  Owners (technical) — optional, users/guests/service principals only
  Sponsors (business) — required for identity + blueprint, restricted group types
  Managers — agent user account only, request-only rights

Layer 4 — Access Assignment
  Entitlement Management access packages, policy scoped to "users, service principals,
    and agent identities" + "All agents" (or scoped) — a SEPARATE parallel policy with
    "All Service principals" needed to also cover non-Agent-ID legacy agents

Layer 5 — Zero Trust Enforcement
  Conditional Access for agents (blueprint-level inheritance available)
  Identity Protection for agents (risk derived from linked user + agent's own actions)

Layer 6 — Cross-Platform Extension (optional)
  Third-party agent platforms (AWS Bedrock, n8n, etc.) → Entra ID Auth SDK (sidecar)
    OR workload identity federation — NOT automatic, must be explicitly configured

Layer 7 — Visibility & Catalog Governance (a DIFFERENT product surface — cross-reference,
  not owned by this topic)
  M365 admin center Agent Registry (AgentGovernance-A.md/-B.md) — aggregates risk signals
    from Entra + Defender + Purview; "Shadow agent" (Critical) fires on missing Registry
    entry OR missing owner OR missing Entra Agent ID (logical OR across all three)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Agent identity/blueprint creation request rejected | No sponsor specified (mandatory except for blueprint principals) | Confirm request payload/flow explicitly set a sponsor; delegated flows auto-sponsor the calling user only if none was specified |
| Sponsor group assigned but approvals/lifecycle actions don't work | Invalid sponsor group type (role-assignable or assigned-security group) | Check group's Membership type + "roles can be assigned" flag in Entra admin center |
| Two admins disagree on which role to assign for agent management | AI Administrator and Agent ID Administrator both grant full agent-identity CRUD | Compare each role's documented action list; pick based on whether Copilot/Registry scope should also be included |
| Access package request from an agent identity silently fails or is invisible as an option | Assignment policy's "Who can get access" not scoped to agent identities | Open the policy, confirm "For users, service principals, and agent identities" + agent scope selector |
| Legacy (non-Agent-ID) agent can't get the same access package as newer Agent-ID agents | Missing parallel "All Service principals" policy | Add a second assignment policy scoped to service principals alongside the agent-identity one |
| Agent lost access with no visible config change | Access package assignment expiry passed, sponsor didn't act on renewal notice | Check assignment expiry date and sponsor notification/response history |
| Agent identity has no functioning technical admin after a departure | Ownership doesn't auto-transfer on employee offboarding (sponsorship does) | Audit for single-owner objects; reassign owner via Agent ID Administrator |
| Agent shows Critical "Shadow agent" risk despite working normally | Missing ONE of: Registry entry, owner, or Entra Agent ID (any one triggers it) | Check M365 admin center Registry flyout for which specific prerequisite is absent |
| Third-party (non-Microsoft) agent has no Entra Agent ID at all | Cross-platform integration (Auth SDK sidecar / workload identity federation) never configured | Confirm with the platform team whether either integration path was set up |
| Conditional Access policy for agents not applying to newly created instances | Policy was applied per-identity instead of at the blueprint level | Reconfigure the CA policy to target the blueprint so all current/future instances inherit it |
| Agent blocked from a resource despite an approved access package | Conditional Access risk-based block (Microsoft Managed Policy default-blocking high-risk agents) | Check Identity Protection's agent risk detections before assuming an entitlement-management gap |
| Tenant has Agent ID objects but Conditional Access/Identity Protection tabs for agents are unavailable | Missing Microsoft Agent 365 license | Confirm licensing under Billing > Licenses; Agent 365 is required to unlock these surfaces, not bundled automatically with base Entra |

---
## Validation Steps

**1. Confirm the object exists and its type.**
```
GET https://graph.microsoft.com/beta/directory/agentIdentities/{id}
```
Good: returns the object with `displayName`, `createdDateTime`, and inherited scope data. Bad: 404 — confirm you're not actually looking for a blueprint, blueprint principal, or agent user instead (four different endpoints).

**2. Confirm sponsor and owner assignment.**
```
GET https://graph.microsoft.com/beta/directory/agentIdentities/{id}/sponsors
GET https://graph.microsoft.com/beta/directory/agentIdentities/{id}/owners
```
Good: at least one sponsor listed (required by creation-time validation, so an empty result here after successful creation would indicate drift, not an expected state). Bad: empty owners collection is valid (owners are optional) but should be flagged as a hygiene gap, not treated as broken.

**3. Confirm RBAC role assignment for the person attempting an admin action.**
```
GET https://graph.microsoft.com/beta/roleManagement/directory/roleAssignments?$filter=roleDefinitionId eq 'db506228-d27e-4b7d-95e5-295956d6615f'
```
(Template ID `db506228-d27e-4b7d-95e5-295956d6615f` = Agent ID Administrator, verified directly against the live Microsoft Entra built-in roles reference.) Good: the user/group appears in the results. Bad: absent — check AI Administrator (a documented functional superset for agent-identity actions) before assuming a genuine access gap.

**4. Confirm access package policy scope for agent identities.**
```
GET https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages/{id}/assignmentPolicies
```
Good: at least one policy's `requestorSettings` includes agent identities in its allowed requestor scope. Bad: only user/service-principal scopes present — this is Fix 4 in `AgentID-B.md`.

**5. Confirm licensing before troubleshooting a missing CA/Identity Protection/Governance surface for agents.**
Portal: Microsoft 365 admin center > Billing > Licenses > Subscriptions — confirm Microsoft Agent 365 (or M365 E7) is present. Good: license present, feature tabs for agents visible under Conditional Access / Identity Protection / ID Governance. Bad: license absent — this is an expected gate, not a bug, and no amount of RBAC-role troubleshooting will resolve it.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Object identification.** Determine which of the four object types the ticket concerns (blueprint, blueprint principal, identity, or agent user) before anything else — each has different creation rules (sponsor requirement), different limits (sponsor count/type), and different downstream behavior.

**Phase 2 — Licensing confirmation.** Separate "the platform doesn't support this" from "this tenant hasn't licensed the security/governance layer." Basic object CRUD works everywhere; CA, Identity Protection, and ID Governance for agents specifically gate on Microsoft Agent 365 + Entra P1/M365 E3 minimum (or M365 E7 bundling both).

**Phase 3 — Administrative relationship audit.** Pull Owners, Sponsors, and (if applicable) Manager for the specific object in question. Cross-check sponsor group types against the allowed list (Dynamic security/M365, Assigned M365 — never role-assignable or assigned-security groups). This resolves the large majority of "can't approve/can't modify/can't request access" tickets without ever touching RBAC roles.

**Phase 4 — RBAC role confirmation (tenant-wide).** If the object-level relationships check out and the requester still can't perform a tenant-wide administrative action, confirm their actual role assignment against the documented action list for Agent ID Administrator, Agent ID Developer, Agent Registry Administrator, and AI Administrator — remembering the last two both function for agent-identity CRUD despite having different primary purposes.

**Phase 5 — Access assignment (entitlement management).** For resource-access tickets specifically, inspect the access package's assignment policy scope directly rather than assuming a delegated-permission or RBAC problem — this is architecturally a separate control plane from both.

**Phase 6 — Zero Trust / risk layer.** If access is denied despite a correctly-scoped access package, check Conditional Access (including Microsoft Managed Policies that block high-risk agents by default) and Identity Protection's agent risk detections before further entitlement-management troubleshooting.

**Phase 7 — Cross-reference the Registry layer.** If the ticket originated from a "Shadow agent" or other Registry risk flag rather than a direct Agent ID complaint, confirm which of the three OR'd conditions (no Registry entry / no owner / no Entra Agent ID) is actually missing before remediating in the wrong system.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standing up a new governed agent identity from scratch</summary>

1. Confirm licensing: Microsoft Agent 365 (or M365 E7) present if Conditional Access/Identity Protection/Governance will be applied to this agent; otherwise base Entra licensing is sufficient for the identity objects alone.
2. Create the agent identity blueprint first (via Agent ID Administrator, Agent ID Developer, or a delegated app holding `AgentIdentity.Create.All`/`AgentIdentity.ReadWrite.All`/`AgentIdentity.ReadWrite.ManagedBy`). Define exposed/required OAuth 2 scopes, appRoles, and authentication config at this level so every future instance inherits consistent policy.
3. Assign a sponsor at blueprint creation (mandatory) — a real business stakeholder, not the creating admin by default. Assign at least one owner (optional but strongly recommended — see Playbook 3 for the risk of skipping this).
4. Create the agent identity instance from the blueprint. It inherits the blueprint's delegated scopes automatically.
5. If the agent needs user-object resources (mailbox, Teams, documents), create the paired agent user account, ideally sharing the same sponsor as the agent identity for consistency.
6. Grant additional resource access via an entitlement management access package scoped to include agent identities (not the default user/service-principal-only scope) — do not hand-assign group memberships or app permissions directly outside this flow, or lifecycle expiry/renewal tracking is lost.
7. Apply Conditional Access at the blueprint level if this agent class should inherit consistent risk-based controls going forward, rather than per-instance (which doesn't automatically extend to future instances).
8. Register the agent in the M365 admin center Agent Registry if it will be surfaced through Copilot/Teams/Outlook channels — this is a separate step in a separate system (see `AgentGovernance-B.md` Fix 2), not automatic just because an Entra Agent ID exists.

**Rollback:** Disable the agent identity (Owner or Agent ID Administrator action) rather than deleting outright if the rollout needs to pause — deletion is recoverable via soft-delete/restore for a limited window but disabling is faster and non-destructive.

</details>

---

<details><summary>Playbook 2 — Least-privilege role realignment (AI Administrator overuse)</summary>

1. Pull every holder of AI Administrator via `Get-AgentIdentityGovernanceAudit.ps1` (or the Graph role-assignment query in Validation Step 3, substituting the AI Administrator template ID).
2. For each holder, determine whether their actual job requires Copilot/Integrated Apps/admin-consent-policy governance, or only agent-identity lifecycle management.
3. For holders who only need the latter, replace their AI Administrator assignment with **Agent ID Administrator** — this preserves their ability to manage agent identities while removing the broader Copilot governance surface they weren't using.
4. For holders who need narrower, blueprint-scoped self-service only (a specific team managing only their own agents), consider **Agent ID Developer** instead of either administrator role.
5. Re-run the audit after the change to confirm the removed AI Administrator assignment didn't break an unrelated Copilot-governance workflow the same person was quietly relying on — cross-check against `AgentGovernance-A.md`'s role table before finalizing.

**Rollback:** Re-add AI Administrator if a genuine Copilot-governance dependency surfaces post-change; role reassignment is fully reversible with no data loss.

</details>

---

<details><summary>Playbook 3 — Closing the single-owner succession gap</summary>

1. Run `Get-AgentIdentityGovernanceAudit.ps1` to enumerate every agent identity and blueprint with zero or exactly one owner.
2. For zero-owner objects: assign at least one technical owner (a real person or a service principal used for automated management) — these currently have no one who can rotate credentials or modify configuration without going through Agent ID Administrator each time.
3. For single-owner objects: assign a backup co-owner. Unlike sponsorship, ownership has no automatic succession on departure — a disabled or deleted sole-owner account leaves the object in a state where only sponsors (business-only, non-technical) and tenant-wide Agent ID Administrators can act on it.
4. Cross-check the sponsor side simultaneously — while sponsorship auto-transfers to a departed sponsor's manager, confirm that manager relationship is actually populated in the directory (a sponsor whose manager field is empty breaks the auto-transfer chain silently).
5. Consider a Lifecycle Workflow to automate future sponsor-transition notifications for this class of object, rather than relying on manual review each time.

**Rollback:** N/A — this is additive (assigning owners), not a configuration change requiring rollback.

</details>

---

<details><summary>Playbook 4 — Reconciling Entra Agent ID state with the M365 admin center Agent Registry</summary>

1. Export the Registry's full agent list (M365 admin center > Agents > All agents > Registry > Export) and the Entra tenant's agent identity list (Graph beta `agentIdentities` endpoint, or the audit script).
2. Cross-reference by agent name/metadata — flag Registry entries with no linked Entra Agent ID (these will show as Shadow agent risks) and Entra Agent IDs with no corresponding Registry entry (invisible to Copilot governance even though technically well-governed at the identity layer).
3. For Registry entries missing an Entra Agent ID: determine whether the agent is a genuine candidate for Agent ID onboarding (internal custom automation, LOB agent) or an external/Microsoft-published agent where this may not apply — check `AgentGovernance-A.md`'s agent-type table (Microsoft / external partner / published-by-org / shared-by-creator) before assuming every entry needs one.
4. For Entra Agent IDs with no Registry entry: if the agent is Copilot-surfaced (Teams/Outlook/M365 apps channel), it needs to go through the Registry upload/publish flow in `AgentGovernance-B.md` Fix 2 — an Entra Agent ID alone does not make an agent discoverable to end users.
5. Re-run both exports after remediation and confirm the previously-flagged Shadow agent risks have cleared on their next refresh cycle (allow up to the platform's documented refresh delay before escalating a flag that hasn't cleared).

**Rollback:** N/A — this is a reconciliation/audit process, not a configuration change with a rollback path.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Read-only evidence collector for Microsoft Entra Agent ID escalations.
.DESCRIPTION
    Companion to Scripts/Get-AgentIdentityGovernanceAudit.ps1 (full tenant-wide sweep).
    This inline snippet is scoped to a SINGLE agent identity for fast escalation-ticket
    evidence gathering. Requires Microsoft.Graph.Authentication module and an existing
    Connect-MgGraph session with Directory.Read.All / RoleManagement.Read.Directory scopes.
    Read-only — makes no changes.
#>
param(
    [Parameter(Mandatory)][string]$AgentIdentityId
)
$agent    = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/agentIdentities/$AgentIdentityId"
$owners   = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/agentIdentities/$AgentIdentityId/owners"
$sponsors = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/agentIdentities/$AgentIdentityId/sponsors"

[PSCustomObject]@{
    DisplayName    = $agent.displayName
    ObjectId       = $agent.id
    CreatedDate    = $agent.createdDateTime
    OwnerCount     = $owners.value.Count
    OwnerNames     = ($owners.value.displayName -join '; ')
    SponsorCount   = $sponsors.value.Count
    SponsorNames   = ($sponsors.value.displayName -join '; ')
    NoOwnerRisk    = ($owners.value.Count -eq 0)
    SingleOwnerRisk = ($owners.value.Count -eq 1)
} | Format-List
```

---
## Command Cheat Sheet

| Command / Endpoint | Purpose |
|---|---|
| `GET /beta/directory/agentIdentities` | List all agent identities in the tenant |
| `GET /beta/directory/agentIdentityBlueprints` | List all agent identity blueprints |
| `GET /beta/directory/agentIdentityBlueprintPrincipals` | List blueprint principals (multitenant agents) |
| `GET /beta/directory/agentUsers` | List agent user accounts |
| `GET /beta/directory/agentIdentities/{id}/owners` | Owners for a specific agent identity |
| `GET /beta/directory/agentIdentities/{id}/sponsors` | Sponsors for a specific agent identity |
| `GET /beta/roleManagement/directory/roleAssignments?$filter=roleDefinitionId eq 'db506228-d27e-4b7d-95e5-295956d6615f'` | Agent ID Administrator role holders |
| `GET /beta/roleManagement/directory/roleAssignments?$filter=roleDefinitionId eq 'adb2368d-a9be-41b5-8667-d96778e081b0'` | Agent ID Developer role holders |
| `GET /beta/roleManagement/directory/roleAssignments?$filter=roleDefinitionId eq '6b942400-691f-4bf0-9d12-d8a254a2baf5'` | Agent Registry Administrator role holders |
| `GET /beta/identityGovernance/entitlementManagement/accessPackages/{id}/assignmentPolicies` | Access package policy scope (check agent-identity inclusion) |
| `POST /beta/identityGovernance/entitlementManagement/accessPackageAssignmentRequests` | Agent self-request or sponsor-on-behalf access package request |
| Entra admin center > Identity > Applications > Agent identities | Portal home for all four object types |
| M365 admin center > Agents > All agents > Registry | Cross-reference: Registry/Shadow-agent risk view |
| M365 admin center > Billing > Licenses > Subscriptions | Confirm Microsoft Agent 365 / M365 E7 presence |

---
## 🎓 Learning Pointers

- **The object model is deliberately layered (blueprint → blueprint principal → identity → agent user) so that policy defined once at the blueprint propagates to every instance** — this is the same design principle as Conditional Access template inheritance or Intune configuration profile assignment, applied to identity. Understanding this hierarchy up front prevents a lot of "why didn't my policy apply to the new instance" confusion. [MS Docs: What is Microsoft Entra Agent ID?](https://learn.microsoft.com/en-us/entra/agent-id/what-is-microsoft-entra-agent-id)

- **Owner/Sponsor/Manager is a genuinely novel administrative model worth internalizing on its own terms rather than mapping it onto a familiar RBAC mental model.** It's closer to how a company assigns a "budget owner" (sponsor) separately from a "system administrator" (owner) for a piece of infrastructure than to a traditional single-admin-role pattern. [MS Docs: Administrative relationships in Microsoft Entra Agent ID](https://learn.microsoft.com/en-us/entra/agent-id/agent-owners-sponsors-managers)

- **Treat "agent sprawl" the same way you'd treat unmanaged service accounts or forgotten app registrations with stale secrets** — it's the same underlying failure mode (a nonhuman identity nobody is actively accountable for) wearing a new name. The proactive audit discipline that already exists for app registration credential hygiene (see `AppRegistrations-A.md`) applies directly here. [MS Docs: Microsoft Entra security for AI overview](https://learn.microsoft.com/en-us/entra/agent-id/security-for-ai-overview)

- **The Graph API surface for this feature is still beta** (`agentIdentity`, `agentIdentityBlueprint`, and related resources are documented under `graph-rest-beta`) — build any automation against it with the expectation that endpoint shapes may shift before v1.0, and re-verify script queries against current documentation periodically rather than treating them as permanently stable.

- **AI Administrator's overlap with Agent ID Administrator is a real, first-party design choice, not a documentation inconsistency** — Microsoft appears to want AI Administrator to remain a fully capable "one role covers all AI-adjacent admin needs" option for smaller organizations, while Agent ID Administrator exists for organizations that want role separation. Recommend the split explicitly to clients who are large enough to benefit from least-privilege role separation. [MS Docs: Microsoft Entra built-in roles](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference)

- **Cross-platform agent onboarding (Auth SDK sidecar / workload identity federation) is worth flagging proactively in any multi-vendor AI strategy conversation** — clients adopting agents from multiple platforms (Microsoft Foundry, Copilot Studio, plus a third-party framework) need to know that governance parity across platforms isn't automatic and requires deliberate integration work per non-Microsoft platform. [MS Docs: Governing Agent Identities](https://learn.microsoft.com/en-us/entra/id-governance/agent-id-governance-overview)
