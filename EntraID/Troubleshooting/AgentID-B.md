# Microsoft Entra Agent ID — Hotfix Runbook (Mode B: Ops)
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

This runbook covers **Microsoft Entra Agent ID** — the identity/security framework (GA April 2026) that gives AI agents their own governable identity objects in Entra ID (agent identity blueprints, agent identities, agent identity blueprint principals, and optional agent user accounts). It is NOT the same layer as `M365/Copilot/AgentGovernance-B.md` (the Microsoft 365 admin center **Agent Registry** — catalog/publish/approve for Copilot-surfaced agents). An agent can be fully approved in the Registry and still have no Entra Agent ID behind it (flagged as a **Shadow agent** risk), or have a healthy Entra Agent ID and never appear in the Registry at all. Confirm which layer the ticket is actually about before troubleshooting further.

```
1. Confirm the object type in question first — Entra admin center > Identity > Applications > Agent identities
   (or Microsoft Graph beta: GET /beta/directory/agentIdentities). Four distinct object types exist:
   agent identity blueprint, agent identity blueprint principal, agent identity, agent user.

2. Confirm licensing before assuming a bug:
   - Creating/using basic Agent ID platform objects: available to all Entra customers, no extra license
   - Conditional Access / Identity Protection / Governance for agents: requires Microsoft Agent 365
     (included in M365 E7, or add-on to E5/A5/Business Premium / Defender Suite + Purview Suite)
   - Entra ID Governance for agent identities specifically: M365 E7, OR Agent 365 + Entra P1/M365 E3 minimum

3. Confirm the requester's actual role — Entra admin center > Identity > Roles & administrators, filter
   "Agent ID Administrator" / "Agent ID Developer" / "Agent Registry Administrator" / "AI Administrator".
   NOTE: AI Administrator ALSO grants full agent-identity lifecycle CRUD (create/delete/disable/owners) —
   this is a real, documented overlap with Agent ID Administrator, not a misconfiguration.

4. For a specific agent identity/blueprint: open its object in the Entra admin center and check the
   Owners, Sponsors, and (if an agent user exists) Manager tabs — these are OBJECT-LEVEL relationships,
   separate from RBAC role assignments, and most "who can do what" tickets trace back here.

5. For an access/permission problem: check the agent identity's assigned access packages under
   Identity Governance > Entitlement management, not just its OAuth API permissions.
```

| Result | Action |
|--------|--------|
| Agent identity creation request fails, "sponsor required" | → Fix 1: sponsor is mandatory at creation for agent identities/blueprints (not blueprint principals) |
| Assigned a group as sponsor, doesn't behave as expected / can't approve anything | → Fix 2: wrong group type — only Dynamic (security or M365) and Assigned-membership M365 groups are valid sponsors |
| Unsure whether to assign AI Administrator or Agent ID Administrator | → Fix 3: genuine overlap — pick based on whether Copilot/Integrated Apps rights should come along too |
| Agent can't request/receive an access package even though the policy looks fine | → Fix 4: assignment policy's "Who can get access" wasn't scoped to include agent identities |
| Agent lost access unexpectedly, no one touched a policy | → Fix 5: access package assignment expired, sponsor renewal window passed |
| Departed employee left an agent identity behind, sponsor works but owner is gone | → Fix 6: sponsorship auto-transfers to manager, ownership does NOT — needs manual reassignment |
| Agent shows "Shadow agent" (Critical) in M365 admin center despite working fine | → Fix 7: Registry risk fires on missing Registry entry, missing owner, OR missing Entra Agent ID — any one triggers it |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Licensing Layer
  ├─ Agent ID platform (create/manage basic objects) → all Entra customers, no extra license
  └─ Security/Governance for agents (CA, Identity Protection, Entitlement Mgmt at scale)
       → Microsoft Agent 365 (bundled in M365 E7; add-on to E5/A5/Business Premium
         or Defender Suite + Purview Suite) + at least Entra P1/M365 E3
         |
Object Model (created via blueprint, in this order)
  Agent identity blueprint (template)
    └─ Agent identity blueprint principal (only for multitenant-capable agents —
       brought into a consuming tenant like a multitenant app's service principal)
    └─ Agent identity (individual instance, inherits delegated permission scopes
       from its parent blueprint)
         └─ Agent user (OPTIONAL, 1:1 paired account — only when the agent needs
            user-object resources: mailbox, calendar, Teams, documents)
         |
Administrative Relationships (object-level, separate from RBAC roles)
  ├─ Owners (technical) — users/guests or service principals, NOT groups, optional
  ├─ Sponsors (business) — REQUIRED at creation for identity + blueprint (not for
  │   blueprint principal); users/guests or Dynamic/Assigned-M365 groups only
  └─ Managers — only meaningful on the agent's user account, request access packages
         |
RBAC Roles (tenant-wide, separate from the object-level relationships above)
  ├─ Agent ID Administrator — full lifecycle CRUD, hard-delete/restore, session revoke
  ├─ Agent ID Developer — delegated create of blueprint + blueprint principal only
  ├─ Agent Registry Administrator — Registry metadata/collections/visibility only
  └─ AI Administrator — OVERLAPS Agent ID Administrator's full agent-identity CRUD,
      PLUS Copilot/Integrated Apps governance (see AgentGovernance-A.md)
         |
Access Assignment (Entra ID Governance — Entitlement Management)
  └─ Access packages, assignment policy must explicitly include agent identities
     (three request paths: agent self-request via API, sponsor-on-behalf, admin direct-assign)
         |
Zero Trust Enforcement
  ├─ Conditional Access for agents (can apply at blueprint level, inherited by all
  │   instances; Microsoft Managed Policies block high-risk agents by default)
  └─ Identity Protection for agents (agent identity risk derived from linked user
      risk + the agent's own anomalous actions)
         |
Visibility / Governance Layer (a DIFFERENT product surface, cross-reference only)
  └─ M365 admin center Agent Registry (AgentGovernance-A.md) — "Shadow agent" risk
     fires specifically when an agent has no Registry entry, no owner, OR no Entra
     Agent ID — any one of the three is sufficient to trigger it
```

</details>

---
## Diagnosis & Validation Flow

**1. Identify the object type before doing anything else.** "Agent ID" ticket language conflates four distinct object types. A blueprint problem, an individual identity problem, a blueprint-principal (multitenant) problem, and an agent-user problem each have different fix paths below.
Portal: Entra admin center > Identity > Applications > Agent identities (or the Agent identity blueprints / Agent identity blueprint principals / Agent users tabs alongside it).

**2. Confirm the licensing tier before troubleshooting a "missing feature."** Basic Agent ID objects work for any Entra customer. Conditional Access, Identity Protection, and ID Governance for agents specifically require Microsoft Agent 365 layered on Entra P1/M365 E3 minimum (M365 E7 bundles all of it). A tenant without Agent 365 will see agent identities exist but CA/Identity Protection/Governance features for them simply won't be available — this looks like a bug but is a licensing gate.

**3. Separate RBAC roles from object-level relationships — they are not the same control surface.** A user can hold Agent ID Administrator tenant-wide and still not be listed as an Owner or Sponsor on a specific agent identity (irrelevant — the role already grants access). Conversely, an Owner or Sponsor on one specific agent identity has zero rights over any other agent identity unless they also hold a tenant role. Don't diagnose a role problem when the real gap is an object-level assignment, or vice versa.

**4. For AI Administrator vs. Agent ID Administrator confusion, check the actual documented action list, not assumptions.** Both roles grant `microsoft.directory/agentIdentities/*`, `agentIdentityBlueprints/*`, and `agentIdentityBlueprintPrincipals/*` actions (create/delete/disable/enable/owners-update/tag-update). AI Administrator additionally covers Copilot/Integrated Apps and admin-consent-request-policy management; Agent ID Administrator additionally covers agent-user license/session management and hard-delete/restore. Neither is a subset of the other for every action — check both role detail pages if precision matters.

**5. For access problems, check the access package assignment POLICY's scope setting, not just the assignment itself.** An access package can exist, be perfectly configured for users and service principals, and still silently refuse every agent identity request if "Who can get access" wasn't explicitly set to include agent identities.

---
## Common Fix Paths

<details><summary>Fix 1 — Agent identity/blueprint creation fails: sponsor required</summary>

A sponsor is **mandatory** when creating an agent identity or an agent identity blueprint. Agent identity blueprint principals are exempt from this requirement.

1. In delegated (user-context) creation flows, the calling user automatically becomes the sponsor **only if no other sponsor is explicitly specified**. If one or more sponsors were named, the calling user is not auto-added — confirm at least one was actually set.
2. In app-only (service-to-service) creation requests, there is no calling user to fall back to — the creating service **must** explicitly set one or more valid sponsors (user, guest, or a supported group — see Fix 2) or the request fails outright.
3. Users holding Agent ID Administrator or Agent ID Developer are never made sponsor automatically, by design — this avoids silently overloading admins with individual agent lifecycle responsibility. Assign a real business owner explicitly.

**Rollback:** N/A — this is a creation-time validation, not a reversible state change.

</details>

---

<details><summary>Fix 2 — Group assigned as sponsor doesn't behave correctly</summary>

Only specific group types are valid sponsors for an agent identity, agent identity blueprint, or blueprint principal:

- **Allowed:** Dynamic membership groups (security or Microsoft 365), Assigned membership groups (Microsoft 365 only)
- **NOT allowed:** Role-assignable groups (security or Microsoft 365), Assigned membership groups of type *security*

1. Check the group's type: Entra admin center > Groups > select the group > Overview (Membership type, Group type, "Microsoft Entra roles can be assigned to the group" flag).
2. If it's a role-assignable group or an assigned-membership security group, it will not function as a sponsor even if the UI let you attach it — remove it and assign a Dynamic or Assigned-M365 group instead, or fall back to individual user/guest sponsors.
3. Note the separate, smaller limits for an agent's **user account** sponsors (any group type allowed, max 5) vs. sponsors on the agent identity/blueprint/blueprint-principal itself (restricted group types, max 100 with no more than 5 groups) — these are two different objects with two different rulesets, don't conflate them.

**Rollback:** Reassign the previous (working) sponsor if the group swap breaks approval flows.

</details>

---

<details><summary>Fix 3 — Unsure whether to assign AI Administrator or Agent ID Administrator</summary>

Both roles grant full agent-identity lifecycle CRUD — this is confirmed in each role's own documented action list, not a documentation error.

1. If the assignee's job is **purely** agent-identity lifecycle management (create/disable/delete/reassign owners for agent identities, blueprints, blueprint principals, and agent users) and they should NOT also get Copilot/Integrated Apps/admin-consent-policy rights → assign **Agent ID Administrator**.
2. If the assignee also needs to approve/publish Copilot agents in the Agent Registry, manage admin consent request policies, or otherwise administer Microsoft 365 Copilot broadly → **AI Administrator** covers agent identities AND that wider surface — see `AgentGovernance-A.md`/`-B.md` for the Registry-specific half of that role's job.
3. For a narrower, developer-self-service scenario (a specific team should be able to create their own agent identities from a blueprint they own, nothing else) → **Agent ID Developer** is the least-privilege choice; it only grants delegated create rights for blueprints/blueprint principals, with the creator auto-added as owner.
4. For governance of the M365 admin center Agent Registry catalog specifically (metadata, collections, visibility — NOT the underlying Entra identity objects) → **Agent Registry Administrator**, a fourth and functionally separate role.

**Rollback:** Remove the broader role and reassign the narrower one if least-privilege review flags an over-scoped assignment.

</details>

---

<details><summary>Fix 4 — Agent identity can't request or receive an access package</summary>

1. Open the access package's assignment policy: Identity Governance > Entitlement management > Access packages > select the package > Policies > select the relevant policy.
2. Check **Who can get access** — this must be set to **"For users, service principals, and agent identities in your directory"**, then the agent scope option set to **"All agents"** (or a narrower agent-specific configuration). The default/legacy setting only covers users and service principals.
3. If some of the tenant's agents are not yet using Microsoft Entra Agent IDs (still bare app registrations/service principals), a **second, parallel policy** with **"All Service principals"** selected is required to cover them — one policy does not cover both populations.
4. Confirm the request path actually being used: the agent identity itself calling the `accessPackageAssignmentRequest` API, its sponsor requesting on its behalf via My Access, or an admin direct-assigning from Entitlement management — each has a different failure mode if misconfigured (e.g., a missing `AgentIdentity.ReadWrite.All`-class delegated permission blocks the self-request path specifically).

**Rollback:** Revert the policy scope if opening it to agent identities was done in error and needs tightening back.

</details>

---

<details><summary>Fix 5 — Agent lost access with no configuration change made</summary>

1. Check the access package assignment's expiry date, not the underlying policy — access can be time-bound per-assignment even when the policy itself is unchanged.
2. If a sponsor is set on the agent identity, they should have received a pre-expiry notification with the option to request an extension (triggering a new approval cycle) or let it lapse. Confirm whether that notification was acted on — a missed sponsor notification is the most common cause of this ticket type.
3. If the assignment already expired, the agent identity has automatically lost access — this is expected behavior, not a fault. Have the sponsor (or an admin) submit a fresh access package request; there is no "un-expire" action.

**Rollback:** N/A — re-request access through the normal flow; nothing to roll back.

</details>

---

<details><summary>Fix 6 — Departed employee left an orphaned agent identity</summary>

Sponsorship and ownership do **not** behave the same way on employee departure:

1. **Sponsorship auto-transfers** to the departed sponsor's manager when they leave the organization, keeping a human accountable without manual intervention. Lifecycle Workflows can automate the notification chain to co-sponsors and the sponsor's manager for this transition.
2. **Ownership does NOT auto-transfer.** Owners are technical administrators with no built-in succession mechanism — if the sole owner of an agent identity or blueprint leaves, the object is left with no one able to modify authentication properties, credentials, or configuration until a human with Agent ID Administrator (or an existing co-owner) manually assigns a new owner.
3. Audit for this proactively rather than waiting for a ticket: any agent identity/blueprint with exactly one owner is a single-point-of-failure risk the moment that person's account is disabled. See `Scripts/Get-AgentIdentityGovernanceAudit.ps1` for a tenant-wide sweep.

**Rollback:** N/A — this is a remediation (assign a new owner), not a reversible change.

</details>

---

<details><summary>Fix 7 — Agent flagged "Shadow agent" (Critical) in the M365 admin center despite working correctly</summary>

The Agent Registry's Shadow agent risk (Critical severity) fires when an agent has **no Registry entry, no owner, OR no Microsoft Entra Agent ID** — any single one of the three conditions is sufficient, they are not additive requirements.

1. Confirm which of the three is actually missing before assuming the agent needs to be rebuilt: M365 admin center > Agents > All agents > Registry, open the agent's flyout, check Publisher/Owner fields and whether a linked Entra Agent ID is shown.
2. A custom internal automation built as a bare app registration + client secret (no Agent ID object, no Registry upload) will always show this flag — that is accurate, not a false positive, and is the intended nudge toward onboarding it onto Agent ID.
3. If the agent genuinely already has an Entra Agent ID and a Registry entry but still shows Critical, confirm the **owner** field specifically — an agent can have both other prerequisites satisfied and still trip this flag purely on a missing/removed owner (see Fix 6).
4. This is a Registry-layer (M365 admin center) risk signal, not an Entra Agent ID configuration error — do not attempt to "fix" it inside the Entra admin center's Agent identities blade; the remediation actions (assign owner, upload to Registry, provision an Agent ID) live in their respective owning surfaces.

**Rollback:** N/A — this is a visibility/governance flag, not a blocking control; remediate the missing prerequisite rather than trying to suppress the flag.

</details>

---
## Escalation Evidence

```
=== MICROSOFT ENTRA AGENT ID ESCALATION TEMPLATE ===
Object type (agent identity / agent identity blueprint / blueprint principal / agent user): ___________
Object display name / object ID: ___________
Tenant licensing (M365 E7 / Agent 365 + Entra P1/E3 / base Entra only — confirm via Billing > Licenses): ___________
Symptom (creation fails / sponsor issue / role confusion / access package / expired access / orphaned owner / Shadow agent flag): ___________
Sponsor(s) currently assigned (user/guest/group, and group type if applicable): ___________
Owner(s) currently assigned: ___________
Manager (if agent user account exists): ___________
Admin role of person attempting the action (Agent ID Administrator / Agent ID Developer / AI Administrator / Agent Registry Administrator / other): ___________
Access package name + assignment policy "Who can get access" setting (if relevant): ___________
Registry status if cross-referencing AgentGovernance-B.md (owner shown, Entra Agent ID linked, publish state): ___________
Timeline (when reported / first observed): ___________
Screenshot of the object's Owners/Sponsors/Manager tabs (attach): ___________
```

---
## 🎓 Learning Pointers

- **Microsoft Entra Agent ID and the M365 admin center Agent Registry are two different products solving two different problems, and a ticket that mixes them up wastes the whole triage.** Agent ID is the identity plane (does this agent have a governable Entra object, RBAC, CA, entitlement management); the Registry is the catalog/publishing plane (is this agent approved, owned, and visible to the right users in Copilot). Confirm which one the ticket is actually about first. [MS Docs: What is Microsoft Entra Agent ID?](https://learn.microsoft.com/en-us/entra/agent-id/what-is-microsoft-entra-agent-id)

- **AI Administrator and Agent ID Administrator both grant full agent-identity lifecycle CRUD — this is a genuine, documented overlap, not a permissions bug.** Default to the narrower role (Agent ID Administrator) unless the assignee's job genuinely spans into Copilot/Integrated Apps governance too. [MS Docs: Microsoft Entra built-in roles — Agent ID Administrator](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference#agent-id-administrator)

- **Sponsorship auto-transfers on departure; ownership does not.** Any single-owner agent identity or blueprint is a standing succession risk the moment that owner's account is disabled — treat it the same way you'd treat a single-owner Global Admin service account, and audit for it before it becomes a ticket. [MS Docs: Administrative relationships in Microsoft Entra Agent ID](https://learn.microsoft.com/en-us/entra/agent-id/agent-owners-sponsors-managers)

- **Access packages don't cover agent identities by default — the assignment policy's "Who can get access" setting has to explicitly opt them in, and legacy non-Agent-ID agents (bare service principals) need a second, parallel policy.** This is the single most common "why can't my agent get access" root cause. [MS Docs: Governing Agent Identities](https://learn.microsoft.com/en-us/entra/id-governance/agent-id-governance-overview)

- **"Agent sprawl" / shadow AI is treated as a first-class governance risk, not an afterthought** — the Registry's Critical-severity Shadow agent flag exists specifically to surface agents running with no owner, no inventory entry, or no governed identity at all. Proactively auditing for this (rather than waiting for the flag to fire) is worth building into a standing MSP hygiene check. [MS Docs: Microsoft Entra security for AI overview](https://learn.microsoft.com/en-us/entra/agent-id/security-for-ai-overview)

- **Third-party agent platforms (AWS Bedrock, n8n, and similar) don't automatically get an Entra Agent ID just by existing in the tenant** — they need to be explicitly integrated via the Entra ID Auth SDK sidecar or workload identity federation. If a client asks why their non-Microsoft agent isn't showing up anywhere in Entra, this is almost always the answer. [MS Docs: What is Microsoft Entra Agent ID?](https://learn.microsoft.com/en-us/entra/agent-id/what-is-microsoft-entra-agent-id)
