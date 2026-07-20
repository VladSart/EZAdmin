# Power Automate — Agent Instructions

## What's in this folder

Microsoft Power Automate (formerly Microsoft Flow) — cloud flows, desktop flows, and their integration with the Microsoft 365 ecosystem.

This module focuses on what MSPs actually use Power Automate for:
- **SharePoint site provisioning** — creating sites, applying templates, setting default libraries
- **SharePoint permission management** — breaking inheritance, assigning roles, managing groups
- **M365 Group and Teams provisioning** — automated workspace creation with governance
- **Approval workflows** — routing requests before provisioning
- **Connector troubleshooting** — auth failures, throttling, licence issues
- **Flow governance** — DLP policies, environment management, licence requirements
- **Desktop flows (RPA)** — machine runtime registration, attended/unattended session model, capacity licensing — a distinct execution model from cloud flows (see `Desktop-RPA/`)
- **Power Apps environments & Dataverse** — environment creation/licensing/capacity, Dataverse database provisioning, the three-portal (admin center/maker/Power Automate) visibility divergence, solution import missing-dependency resolution — a distinct admin surface from flow execution (see `PowerApps/`)
- **Copilot Studio security & governance** — data (DLP) policies scoped to Copilot Studio's own connectors (authentication gate, knowledge sources, channels, HTTP, skills, event triggers), per-agent authentication modes, tenant-level generative-AI publish controls, customer-managed keys (CMK), and audit logging — a distinct governance surface from both flow DLP and the Microsoft 365 Agent Registry (see `PowerApps/`)

---

## Before responding, also check

- `M365/SharePoint-OneDrive/` — if the issue is in SharePoint itself, not the flow
- `EntraID/` — if connector auth is failing (OAuth, service principal, permissions)
- `EntraID/Graph/` — for flows using HTTP/Graph API actions
- `Intune/` — if Power Automate Desktop flows are deployed via Intune
- `Desktop-RPA/` — if the issue is a desktop flow's **machine/session runtime** (registration, RDP, service account, unattended capacity) rather than the cloud flow orchestrating it — the two have entirely separate failure domains
- `PowerApps/` — if the issue is **environment/Dataverse admin** (can't create an environment, can't see an environment, database provisioning stuck, solution import failing) rather than a specific flow's execution — again, an entirely separate failure domain from the flow-focused topics in this folder
- `PowerApps/CopilotStudio-Security-B.md`/`-A.md` — if the issue is **Copilot Studio agent security/governance** (publish blocked by a data policy, unauthenticated agent, knowledge-source restriction, CMK, audit) rather than a flow or environment issue
- `M365/Copilot/AgentGovernance-B.md`/`-A.md` — if the issue is the **Microsoft 365 Agent Registry/Agent 365** cross-platform lifecycle (approve/reject/publish/ownership across all agent-creation platforms) rather than Copilot Studio's own DLP/authentication/CMK configuration

---

## Folder contents

| File | What it covers |
|------|---------------|
| `SharePoint/SharePoint-Site-Provisioning-B.md` | Hotfix: site creation flows broken |
| `SharePoint/SharePoint-Site-Provisioning-A.md` | Deep dive: site provisioning architecture, permissions model |
| `SharePoint/Permission-Management-B.md` | Hotfix: permission flows failing |
| `SharePoint/Permission-Management-A.md` | Deep dive: SharePoint permission model via flow — role definitions, group vs. item-level breaks, batching/throttling behaviour of the SharePoint connector's permission actions |
| `Troubleshooting/Connector-Auth-B.md` | Hotfix: connector auth failures, token expiry |
| `Troubleshooting/Throttling-Limits-B.md` | Hotfix: 429 throttling, flow run quotas |
| `Troubleshooting/Approval-Workflows-B.md` | Hotfix: stuck approvals, departed approvers, 30-day run ceiling |
| `Troubleshooting/DLP-Policies-B.md` | Hotfix: flow broken/blocked by a DLP policy — connector classification conflict, newly-applied tenant policy |
| `Troubleshooting/DLP-Policies-A.md` | Deep dive: DLP policy architecture — Business/Non-Business/Blocked connector groups, policy scope precedence (environment vs. tenant-wide), classification conflict resolution |
| `Groups-Teams/Groups-Teams-Provisioning-B.md` | Hotfix: M365 Group/Teams self-service provisioning flows — async race conditions, naming policy, owner assignment, guest access, group-based licensing lag |
| `Troubleshooting/Flow-Ownership-Transfer-B.md` | Hotfix: flows breaking during offboarding — finding flows owned by a departing user and transferring ownership |
| `Troubleshooting/Flow-Ownership-Transfer-A.md` | Deep dive: ownership vs. connection-identity model, why reassigning ownership alone doesn't fix runtime auth, bulk sweep and service-account patterns |
| `Scripts/New-SharePointSiteViaGraph.ps1` | PS equivalent: create SP site via Graph (for when Flow won't do it) |
| `Scripts/Set-SharePointSitePermissions.ps1` | PS: assign/remove site permissions at scale |
| `Scripts/Get-ConnectorAuthHealth.ps1` | PS: flags connections owned by disabled/deleted accounts, stale tokens, orphaned refs |
| `Scripts/Get-DLPPolicyImpactReport.ps1` | PS: cross-policy connector classification matrix + effective-classification resolver |
| `Scripts/Get-FlowRunHistory.ps1` | PS: pulls recent run history/status for a flow |
| `Scripts/Get-GroupsTeamsProvisioningHealth.ps1` | PS: flags async-race, no-owner, and license-pending conditions on self-service Group/Team provisioning |
| `Scripts/Get-ApprovalApproverEligibilityAudit.ps1` | PS: checks approver account/license eligibility for a stuck approval, resolves manager for escalation |
| `Scripts/Get-FlowOwnershipSweep.ps1` | PS: tenant-wide discovery of flows owned by a departing user — no-co-owner and premium-connector risk flags |
| `Scripts/Get-ThrottlingLimitDiagnostics.ps1` | PS: flags confirmed 429/throttle runs, retry-cascade risk, missing loop concurrency, high-frequency recurrence triggers |
| `Desktop-RPA/MachineRuntime-B.md` | Hotfix: desktop flow (attended/unattended) failing to start or run on a registered machine — UIFlowService, RDP, session collisions, connectivity |
| `Desktop-RPA/MachineRuntime-A.md` | Deep dive: direct-connectivity architecture (gateways retired), session lifecycle, full error-code taxonomy, machine groups, Process/Unattended RPA capacity licensing |
| `Desktop-RPA/Scripts/Get-PADMachineHealth.ps1` | PS: local/fleet health check for UIFlowService, RDP, Remote Desktop Users membership, PAD version vs. direct-connectivity floor |
| `PowerApps/Environment-Dataverse-B.md` | Hotfix: environment creation blocked (license/policy/capacity), environment "invisible" in a specific portal, Dataverse database provisioning stuck, solution import missing-dependency error |
| `PowerApps/Environment-Dataverse-A.md` | Deep dive: environment/license/capacity model, Dataverse provisioning architecture, the three-portal (admin center/maker/Power Automate) visibility divergence, the irreversible "Enable Dynamics 365 apps" decision, solution import dependency resolution |
| `PowerApps/Scripts/Get-PowerAppsEnvironmentAudit.ps1` | PS: tenant-wide environment inventory — flags stalled provisioning and Trial/Sandbox capacity-reclaim candidates |
| `PowerApps/CopilotStudio-Security-B.md` | Hotfix: Copilot Studio agent publish blocked by a data policy, unauthenticated agent, channel/knowledge-source restriction, CMK, audit trail request |
| `PowerApps/CopilotStudio-Security-A.md` | Deep dive: Copilot Studio's layered security model — tenant generative-AI controls, DLP data policies scoped to Copilot Studio connectors, per-agent authentication modes, CMK, sensitivity-label-aware knowledge grounding, audit logging |
| `PowerApps/Scripts/Get-CopilotStudioDLPAudit.ps1` | PS: tenant-wide audit of Copilot Studio-relevant data policy connector classifications — flags missing unauthenticated-chat blocks and default-classification risk |

---

## Common entry points

- "Flow to create SharePoint site is failing" → `SharePoint/SharePoint-Site-Provisioning-B.md`
- "Permission assignment step in flow throws 403" → `SharePoint/Permission-Management-B.md`, check service account permissions
- "Flow shows 'Connection requires attention'" → `Troubleshooting/Connector-Auth-B.md`
- "Flow runs but SharePoint site wasn't created" → `SharePoint/SharePoint-Site-Provisioning-A.md` (timing/async issues)
- "Getting 429 errors or flow suspended" → `Troubleshooting/Throttling-Limits-B.md`
- "Need to build a site creation flow from scratch" → `SharePoint/SharePoint-Site-Provisioning-A.md`
- "DLP policy blocking connector" → `Troubleshooting/DLP-Policies-B.md`; use `Scripts/Get-DLPPolicyImpactReport.ps1` to resolve effective classification across overlapping policies
- "Approval flow stuck / approver never responds" → `Troubleshooting/Approval-Workflows-B.md`
- "Self-service Team/Group provisioning flow fails or is inconsistent" → `Groups-Teams/Groups-Teams-Provisioning-B.md`
- "An employee is leaving, what happens to their flows?" / "Flow stopped working after we disabled someone's account" → `Troubleshooting/Flow-Ownership-Transfer-B.md`
- "Desktop flow won't run / machine shows offline / unattended flow fails to start a session" → `Desktop-RPA/MachineRuntime-B.md`
- "Client mentions a 'Power Automate gateway' for desktop flows" → that model is retired; point to `Desktop-RPA/MachineRuntime-A.md` Remediation Playbook 2 (migrate to direct connectivity)
- "Can't create a new environment / 'not enough capacity' / creation button greyed out" → `PowerApps/Environment-Dataverse-B.md`; use `Scripts/Get-PowerAppsEnvironmentAudit.ps1` to find reclaimable Trial/Sandbox capacity
- "User can see the environment in [admin center/maker portal/Power Automate portal] but not the others" → `PowerApps/Environment-Dataverse-B.md` Fix 2 — the three portals have independent visibility rules, this is usually expected once the right role is assigned
- "Dataverse database stuck provisioning" / "solution import fails with missing dependency" → `PowerApps/Environment-Dataverse-B.md`
- "Copilot Studio agent won't publish / blocked by a data policy" → `PowerApps/CopilotStudio-Security-B.md`; use `Scripts/Get-CopilotStudioDLPAudit.ps1` to find the blocking connector/classification
- "Copilot Studio agent has no login / anyone can chat with it" → `PowerApps/CopilotStudio-Security-B.md` Fix 2
- "Client wants Copilot Studio conversation data encrypted with their own key" → `PowerApps/CopilotStudio-Security-B.md` Fix 5 / `PowerApps/CopilotStudio-Security-A.md` Playbook 3

---

## Key dependencies for Power Automate flows

```
[Flow trigger] → [Connection/Connector] → [Licensed user or service principal]
      ↓                     ↓                           ↓
  Runs in          OAuth token valid            Power Automate licence
  Environment      (expires, needs refresh)     (Per-user / Per-flow / E3/E5)
      ↓
  Actions execute → SharePoint/Graph API → App permissions or delegated
      ↓
  Throttle limits apply:
    SharePoint REST: 200 req/sec per tenant
    Graph API: 10k req/10min per app
    Power Automate: depends on licence tier
```

---

## Licence requirements (common confusion)

| Feature | Minimum licence |
|---------|----------------|
| Basic automated flows | Microsoft 365 E3/E5 (seeded) |
| Premium connectors (SQL, Azure, etc.) | Power Automate Premium |
| Per-flow licence | Power Automate per-flow plan |
| Unattended desktop flows | Power Automate Process licence (or legacy Unattended RPA add-on — combined into one capacity pool today); allocated as an "unattended bot" per machine, see `Desktop-RPA/MachineRuntime-A.md` |
| HTTP connector (to Graph API) | Premium connector = Premium licence |

> ⚠️ The HTTP connector is premium. Many flows that "just use Graph" break because the HTTP action requires a premium licence that the account doesn't have.

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — identify broken step → fix connection/permission → validate flow runs
2. **Deep Dive** — full dependency chain, SharePoint API behaviour, governance model
3. **Learning Pointers** — what to explore after the fix
