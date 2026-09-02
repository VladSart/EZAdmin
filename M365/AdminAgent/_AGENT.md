# Microsoft 365 Admin Agent — Agent Instructions

## What's in this folder

The Microsoft 365 Admin agent — Microsoft's first-party, pre-installed natural-language IT admin agent, built on the Agent 365 Platform SDK with exclusive access to native MCP (Model Context Protocol) tool servers that invoke Microsoft Graph and other admin services on the signed-in admin's behalf. No additional Copilot/Agent 365 license is required to use it. Covers its three access surfaces (Microsoft 365 Copilot Chat, the Microsoft 365 admin center's Copilot button, and a narrower SMB-scoped Microsoft Teams surface capped around 300 users), the RBAC-reflection model (the agent holds no standing privilege — every proposed or executed action mirrors the signed-in admin's own Entra role assignments), the mandatory per-write-action confirmation gate, the six documented task categories, and the fully-inherited audit/governance posture shared with every other agent in the tenant via the Agent Registry.

---

## Before responding, also check

- `M365/_AGENT.md` — general M365 agent context and cross-service dependencies
- `M365/Copilot/AgentGovernance-A.md`/`-B.md` — the Agent Registry control plane (Block/scope/approve/assign-owner) that governs this agent alongside every other agent in the tenant; that runbook covers the governance mechanism itself, this folder covers using the agent as an admin tool
- `M365/Copilot/Copilot-A.md`/`-B.md` — base Copilot licensing/Conditional Access/grounding, a separate product surface from the Admin agent
- `EntraID/Troubleshooting/` — if the underlying issue is the admin's own role assignment rather than the agent (the agent mirrors roles, it does not grant them)
- Whatever workload's own `_AGENT.md`/troubleshooting docs match the action the agent actually attempted (Entra ID, Teams, Exchange, etc.) — the agent's audit trail lives in that workload's own logs, not a separate agent-specific one

---

## Folder contents

| File | What it covers |
|------|---------------|
| `AdminAgent-B.md` | Hotfix runbook — triage in under 10 min: missing from a surface, "can't do X"/limited-data complaints, confirmed action that didn't apply, blocking/scoping the agent, finding what it changed, data/privacy questions, over-broad confirmations, "does this replace an MSP" |
| `AdminAgent-A.md` | Deep dive reference — full architecture (three surfaces, one continuous session), the RBAC-reflection model, the confirmation gate, the six task categories, Registry governance, audit trail inheritance, data/privacy posture |
| `Scripts/Get-AdminAgentGovernanceAudit.ps1` | Graph script — tenant-wide Agent Registry state for the Admin agent (Block/scope status), which roles can govern it, and current Copilot/Agent 365 SKU inventory for context |
| `LegacyAdminAppRetirement-B.md` | Hotfix runbook — retirement of the unrelated, older Teams/Outlook/Microsoft365.com "Admin app" (MC1462922, VSB-scoped, retiring Oct 2026) — triage rollout phase, confirm admin role intact, redirect to a replacement surface |
| `LegacyAdminAppRetirement-A.md` | Deep dive — full MC1462922 timeline and architecture, Symptom→Cause map, migration playbooks (admin center, Teams admin center, or this same folder's Admin Agent as Microsoft's own documented successor) |
| `Scripts/Get-LegacyAdminAppUsageAudit.ps1` | Teams PowerShell script — rollout-phase evidence, app catalog identity check (avoids confusing the retiring first-party app with a same-named custom app), and App Setup Policy pin state |

---

## Common entry points

- "The agent is missing from Teams but works in Copilot Chat / the admin center" → `AdminAgent-B.md` Fix 1 — check SMB tenant profile, platform (Desktop/Worldwide Standard Multi-Tenant only at GA), and rollout-ring timing
- "The agent says it can't do something, or returns less data than expected" → `AdminAgent-B.md` Fix 2 — not a bug; the agent mirrors the signed-in admin's own Entra role, it grants no new privilege
- "Admin confirmed an action but nothing changed in the tenant" → `AdminAgent-B.md` Fix 3 — every write action requires explicit confirmation; check the underlying workload's audit log to see if it was attempted and failed vs. never attempted
- "Need to block or restrict the Admin agent org-wide or for a subset of users" → `AdminAgent-B.md` Fix 4 — Agent Registry Block/scope action, AI Administrator or Global Administrator only
- "Can't find a record of what the agent changed" → `AdminAgent-B.md` Fix 5 — check the underlying workload's own audit log (M365 admin center, Entra, Teams); the entry attributes the action to the signed-in admin, not "the agent" as a separate actor
- "Client asks whether their tenant data trains the AI model" → `AdminAgent-B.md` Fix 6
- "Agent suggested disabling a security-relevant setting and an admin confirmed it without review" → `AdminAgent-B.md` Fix 7 — consider scoping the agent's deployment to a smaller, more experienced admin group via Fix 4
- "SMB client asks if the Admin agent replaces their MSP" → `AdminAgent-B.md` Fix 8
- "Admins report the agent 'remembers' something from a different surface" → `AdminAgent-B.md` Fix 9
- "The old Admin app disappeared from Teams/Outlook/Microsoft365.com" → `LegacyAdminAppRetirement-B.md` — this is the OLDER, unrelated VSB app retiring per MC1462922 (Oct 2026), not this folder's AI Admin agent; confirm which one the client means before troubleshooting
- "Client asks what replaces the retiring Admin app" → `LegacyAdminAppRetirement-A.md` Playbook 2 — Microsoft's own documented answer is this same folder's Admin Agent
- "How does the Admin agent actually work / what can it do?" → `AdminAgent-A.md` § How It Works
- "Full RBAC-reflection or confirmation-gate architecture question" → `AdminAgent-A.md` § How It Works / Troubleshooting Steps by Phase
- "Audit governance state across the tenant for this agent" → `Scripts/Get-AdminAgentGovernanceAudit.ps1`

---

## Key diagnostic commands

```powershell
# Confirm your own Entra role — the agent's answers/actions MIRROR your existing
# role assignments, not a separate permission grant
Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<yourObjectId>'" -ExpandProperty roleDefinition |
    Select-Object -ExpandProperty RoleDefinition | Select-Object DisplayName

# Confirm who can BLOCK or SCOPE the agent tenant-wide (Registry governance action) —
# only AI Administrator or Global Administrator
Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '{AI-Admin-role-id}'" -ExpandProperty principal

# Confirm which Copilot/Agent 365 licenses exist in the tenant (informational — the
# Admin agent itself needs none, but affects what OTHER agents/features exist)
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "Copilot|Agent365|SPE_E7" } |
    Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits
```

---

## Key dependency chain

```
Signed-in user holds an Entra admin role (any role — no minimum beyond having one)
    │
    ▼
Microsoft 365 Admin agent (pre-installed, no Copilot/Agent 365 license required)
    │
    ├── Surface: Microsoft 365 Copilot Chat (m365.cloud.microsoft) → all tenants
    ├── Surface: Microsoft 365 admin center → Copilot button → all tenants
    └── Surface: Microsoft Teams (desktop) → SMB-scoped, ~300-user ceiling,
                  Worldwide Standard Multi-Tenant cloud only at GA
    │
    ▼
Native MCP tool servers (Agent 365 Platform SDK) → invoke Microsoft Graph and
other admin services on the signed-in user's behalf
    │
    ▼
RBAC gate (per-request) — existing Entra role assignments govern EVERY action;
the agent has no standing privilege of its own
    │
    ▼
Write/execute confirmation gate (mandatory, no exceptions)
    │
    ▼
Underlying workload executes the action normally (Graph, admin center, Entra,
Teams admin services)
    │
    ▼
Audit trail — SAME logs as a manual action; no separate agent-specific surface
    │
    ▼
Governance layer (Agent Registry) — shared control plane for every agent in
the tenant; AI Administrator/Global Administrator can Block or scope
```

---

## Response format reminder (always 3 layers)

1. **Triage first** — is this a surface/rollout question, an RBAC-reflection misunderstanding, a confirmation-gate question, or a governance/blocking request?
2. **Fix or explain** — most "agent won't do X" tickets resolve by explaining the RBAC-reflection model (Fix 2), not by changing a setting
3. **Confirm resolution** — for governance changes, verify the Agent Registry state; for "did the action apply" questions, check the underlying workload's own audit log
