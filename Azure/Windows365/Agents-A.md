# Windows 365 for Agents — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **Windows 365 for Agents**, a distinct Cloud PC class built on the same Windows 365 platform as Windows 365 Enterprise/Business/Flex, purpose-built for **AI agent workloads** rather than a persistent, named human user. It is consumed two ways: by **agentic applications** (Microsoft Copilot Studio computer use, Project Opal, Researcher, and Microsoft Agent 365 agents) that programmatically check out, operate, and check in a Cloud PC via APIs; and by **human users** through a chat-based interactive UX for oversight, debugging, or direct use. Management is **pool-based**, not device-based — administrators configure and monitor a Cloud PC agent pool as a single resource, not individual VMs.

**In scope:** the four-subsystem architecture, provisioning policy (agents) and Cloud PC agent pool lifecycle, how these Cloud PCs differ operationally from Enterprise Cloud PCs (persistence, billing, assignment, access), Intune device visibility and management specifics, and the read-only relationship between Intune and third-party agent solution portals.

**Explicitly out of scope:**
- Windows 365 Enterprise/Business/Flex/Reserve/Link provisioning and licensing — see `Windows365-A.md`, `Flex-A.md`, `Reserve-A.md`, `Link-A.md` respectively. Windows 365 for Agents shares the underlying HOBO provisioning fabric but has its own licensing (consumption-based), assignment (pool, not user), and persistence (reset-after-use, not persistent) model — do not assume parity.
- Building or debugging the agent orchestration logic itself (Copilot Studio topics, Project Opal workflows, custom MCP orchestrators) — this runbook covers the Cloud PC compute layer those systems consume, not the agent logic running on top of it.
- Azure Virtual Desktop session host troubleshooting — Windows 365 for Agents uses the same underlying connection/media stack lineage as AVD/Windows 365 generally (IC3 media for the human chat UX) but is not an AVD host pool and doesn't share AVD's host-pool management surface.

**Assumes:** engineer has familiarity with standard Windows 365 Enterprise concepts (provisioning policy, Azure Network Connection, Intune enrollment) and basic Microsoft Graph / Intune admin center navigation.

---
## How It Works

<details><summary>Full architecture</summary>

Windows 365 for Agents is organized into **four cooperating subsystems**, each owning a distinct stage of the Cloud PC for Agents lifecycle:

**1. Computer-Create (provisioning)** — the control plane IT admins and agent makers interact with. Creates and maintains the Cloud PC agent pool using the same underlying provisioning process as Windows 365 Enterprise (Hosted-On-Behalf-Of / HOBO architecture — Microsoft provisions and manages the compute in its own subscription, not the customer's). Each pool VM enrolls into the customer's Microsoft Entra tenant and Microsoft Intune the same way an Enterprise Cloud PC does. Administrative surfaces: Graph API, the Intune admin center, and the Microsoft Admin Center (for chargeback/billing visibility). Each provisioned VM runs an **on-box CUA (computer-using agent) client** that enables the agentic control plane to actually drive the OS.

**2. Computer-Get (assignment)** — brokers available Cloud PCs from the pool to whichever caller needs one. Exposes an **MCP (Model Context Protocol) server** so Cloud PC acquisition is directly callable by agent orchestrators. Implements the **check-out/check-in** model: an agent checks out a Cloud PC for the duration of a session and returns it to the pool when done, at which point it becomes available again (after reset). "Agentic cloud assignment" matches a checkout request to the optimal available Cloud PC by capability, region, and availability.

**3. Computer-Do (actions)** — the plane through which an agent actually drives the operating system once it holds a checked-out Cloud PC. Exposes its own MCP server with an action API (click, type, navigate, run), and a relay/protocol layer transports those action requests to the on-box CUA client running inside the target VM.

**4. Computer-See & Computer-Take Control (access and control)** — delivers the interactive pixel-and-device experience to **human** users specifically, via **IC3 media** (Microsoft's real-time media stack for audio/video/peripheral redirection — the same media lineage used elsewhere in Teams/Windows 365). This is the path a human uses to converse with the system through a chat UX and be connected to a live Cloud PC session, distinct from the API-driven agentic path.

**Entry points**, correspondingly: a **Chat UX** for humans (connects via Computer-See & Computer-Take Control), an **Agentic app** — a host containing a model and an orchestrator that calls Computer-Get to claim a Cloud PC and Computer-Do to operate it — and **IT admins/agent makers**, who enter through Computer-Create for pool configuration and lifecycle management.

**How Cloud PCs for Agents differ from Enterprise Cloud PCs:**

| Aspect | Enterprise Cloud PCs | Cloud PCs for Agents |
|---|---|---|
| Management model | Device-focused | Pool-focused |
| Assignment | Assigned to a primary human user | Shared across multiple agents |
| Persistence | Persistent per user | Reset after use |
| Access | User access through Windows App | Agentic access through APIs (or chat UX for humans) |
| Billing | License-based | Consumption-based |

**Two distinct consumption paths in practice:**
- **Agent 365 path** — the customer creates their own **provisioning policy (agents)** in the Intune admin center (or via the Cloud PC Graph APIs), which defines the pool (billing plan, region, Cloud PC count, image). Agent 365 agents (and WorkIQ tooling) then integrate against these self-managed pools.
- **Partner-solution path** — for Microsoft Copilot Studio computer use, Project Opal, and Researcher, the Cloud PC agent pool is created and configured **entirely within that partner's own portal** (e.g., Copilot Studio's "Use a Cloud PC pool for computer use runs" settings). No setup is required in Intune for these. The resulting provisioning policy still appears in Intune's **Devices > Provision Cloud PCs > Provisioning policies** list for visibility, but it is **read-only** there — all configuration changes happen in the owning partner portal.

**Device identity in Intune:** Cloud PCs for Agents enroll like any other Intune-managed device but are identifiable by a **`CPCA-` device name prefix** and a device model of **Cloud PC for Agents**; the device's enrollment profile name matches the provisioning policy name that created it. A documented, current limitation: the **default (legacy) device view** under Devices > All devices does not display detailed information for these devices — an admin must turn on **Preview new device view** to see full detail.

**Pool status** is evaluated **at the pool level, not per individual Cloud PC**: `Creating` (provisioning in progress), `Available` (healthy, may have provisioned Cloud PCs), `Updating` (an ongoing reprovision/pool update), `Available with warning` (some failed updates, but some devices may still be usable), `Failed` (no available devices — action required), `Deleting` (pool teardown in progress). "Available sessions" for a pool is visible via the provisioning policy's own session view.

**Session accounting:** for a given provisioning policy (agents), **Active sessions** (currently checked out) + **Available sessions** (checkoutable now) together equal the policy's **Always available Cloud PCs count** — the pool's fixed ceiling, a deliberate consumption-based sizing/cost control, not an auto-scaling limit.

**Editing a pool:** when a provisioning policy (agents) is edited, **some properties require a manual reprovision** to take effect on already-provisioned Cloud PCs — Windows 365 does **not** automatically reprovision existing Cloud PCs on every policy edit. Deleting a pool or its provisioning policy causes Windows 365 to clean up all Cloud PCs created during provisioning.

</details>

---
## Dependency Stack

```
Microsoft Entra tenant + Microsoft Intune tenant (mandatory prerequisites, same as Enterprise Cloud PC)
    │
    └── Provisioning policy (agents)
            ├── Created via: Intune admin center, OR Cloud PC Graph APIs, OR (partner-solution
            │   path) a partner portal (Copilot Studio / Project Opal / Researcher) — surfaces
            │   read-only in Intune for the partner-solution path
            ├── Required properties: Billing plan, Region, Cloud PC count, Image
            └── Computer-Create subsystem provisions the Cloud PC agent pool
                    └── Hosted-On-Behalf-Of (HOBO) architecture — Microsoft-managed Azure
                        subscription, same fabric as Windows 365 Enterprise provisioning
                            ├── Per-VM: Microsoft Entra enrollment (mandatory)
                            ├── Per-VM: Microsoft Intune enrollment (mandatory)
                            │       └── Device identity: "CPCA-*" name / model "Cloud PC
                            │           for Agents" / enrollment profile = policy name
                            └── Per-VM: on-box CUA (computer-using agent) client installed
                                    │
                                    └── Cloud PC agent pool status: Available
                                            │
                                            ├── Computer-Get (MCP server, check-out/check-in)
                                            │       └── Computer-Do (MCP action API + relay
                                            │           to on-box CUA client) — agentic driving
                                            │
                                            └── Computer-See & Computer-Take Control (IC3
                                                media) — human chat UX interactive access
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Pool status `Failed`, zero available devices | Image, licensing/billing plan, or regional capacity failure at provisioning time | Provisioning policy (agents) detail pane; same root-cause classes as Enterprise Cloud PC provisioning failures |
| Pool status `Available with warning` | Some devices failed an update/reprovision cycle but pool remains partially usable | Compare available-device count against expected pool size |
| Agent checkout request fails ("no capacity") | Active + Available sessions already equal the Always available Cloud PCs count | Provisioning policy (agents) session view |
| Policy edited, no behavior change on existing Cloud PCs | Edited property doesn't auto-propagate; requires manual reprovision | "Edit a provisioning policy (agents)" property list; reprovision status |
| `CPCA-*` device shows no detail in Devices > All devices | Known legacy-device-view gap for Cloud PCs for Agents | Preview new device view toggle state |
| Can't edit a Copilot Studio / Project Opal / Researcher provisioning policy from Intune | By design — those policies are owned and edited in the partner's own portal; Intune's copy is read-only | Confirm which "path" created the policy (self-managed vs. partner-solution) |
| App/configuration policy assignment never reaches these Cloud PCs | Assignment scoped to a user or static device group; these VMs are pool-provisioned, non-persistent, with no primary user | Assignment target — should use device-name-prefix filter, device model, or enrollment profile |
| Human expects to open a Cloud PC for Agents in the Windows App like an Enterprise Cloud PC | Wrong access model — these are reached via APIs (agentic) or a chat UX (human), not the standard Windows 365 client | Confirm actual product requirement; may indicate Enterprise/Business/Flex is the correct product instead |

---
## Validation Steps

1. **Confirm the provisioning policy (agents) exists and its creation path**:
   ```powershell
   Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -All |
       Select-Object DisplayName, Id, ProvisioningType, CloudPcNamingTemplate
   ```
   Expected "good": policy present with `ProvisioningType` reflecting an agents pool and a `CPCA-`-style naming template. If the policy was created via a partner portal, this Graph read still returns it, but edits must be made in that partner portal, not here.

2. **Confirm pool status**:
   Devices > Provision Cloud PCs > Provisioning policies (Agents) > select policy — look for `Available` (good) vs. `Available with warning`/`Failed` (needs action).

3. **Confirm device enrollment and identity**:
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "startswith(deviceName,'CPCA-')" |
       Select-Object DeviceName, Model, EnrolledDateTime, LastSyncDateTime
   ```
   Expected "good": devices present with `Model` = "Cloud PC for Agents" and recent `LastSyncDateTime`. A device present in the pool's expected count but missing here suggests an enrollment-stage failure, not a pool-status issue.

4. **Confirm session accounting**:
   In the provisioning policy's session view, confirm `Active sessions + Available sessions = Always available Cloud PCs count`. A mismatch (rare) or a persistent Active-at-ceiling state both warrant follow-up — the former as a data/reporting anomaly, the latter as a capacity conversation.

5. **Confirm device visibility for troubleshooting**:
   Turn on **Preview new device view** before evaluating device-level detail for any `CPCA-*` device — validating against the legacy view will produce false "missing data" findings.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Pool/provisioning:**
1. Classify pool status (`Available` / `Available with warning` / `Failed` / transient `Creating`/`Updating`).
2. For `Failed` or `Available with warning`, root-cause using the same categories as Enterprise Cloud PC provisioning: image validity, licensing/billing plan validity for the assigned SKU, and regional compute capacity.
3. Confirm whether the pool was created via the self-managed (Intune/Graph) path or a partner-solution path — this determines who can actually change pool configuration.

**Phase 2 — Session/capacity:**
1. Pull Active vs. Available session counts against the Always available Cloud PCs count.
2. If saturated, determine whether this is a transient burst (workload issue — confirm agents are checking sessions back in) or a sustained ceiling (sizing/cost issue — requires deliberate policy change).

**Phase 3 — Configuration drift:**
1. For "my change didn't apply" reports, identify the specific edited property and cross-check whether it requires reprovision.
2. Trigger reprovision if required, or explain the wait-for-natural-churn alternative if reprovision is undesirable mid-workload.

**Phase 4 — Visibility/assignment:**
1. For device-detail gaps, confirm Preview new device view is enabled.
2. For assignment-not-landing reports, confirm the targeting mechanism (prefix filter / model / enrollment profile) rather than user or static device group membership.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standing up a new Cloud PC agent pool (self-managed / Agent 365 path)</summary>

1. In the Intune admin center, create a **provisioning policy (agents)**, specifying billing plan, region, Cloud PC count, and image.
2. Confirm the pool reaches `Available` status before pointing any agent workload at it.
3. Optionally link a Microsoft Entra group or an Intune Autopilot device preparation profile at creation time for downstream assignment convenience (see Cloud PC agent pool device grouping and preparation), rather than retrofitting group membership later.
4. Validate device enrollment and identity per Validation Steps 3 before declaring the pool production-ready.
5. No destructive step here; safe to iterate on pool size before committing a workload to it.

</details>

<details><summary>Playbook 2 — Resizing pool capacity</summary>

1. Determine target Always available Cloud PCs count from observed session-saturation data (Validation Step 4), not guesswork.
2. Edit the provisioning policy (agents) to the new count.
3. Confirm via the session view that the ceiling has updated and that newly available sessions appear.
4. This is a **billing/cost decision** — consumption-based pricing means a larger pool has a direct, ongoing cost impact; confirm with whoever owns the workload's budget before resizing significantly upward.

</details>

<details><summary>Playbook 3 — Decommissioning a pool</summary>

1. Confirm no agent workload still depends on the pool (check recent Active session activity first).
2. Delete the provisioning policy (agents) or the Cloud PC agent pool directly — Windows 365 automatically cleans up all Cloud PCs created during provisioning as part of this action.
3. **This is destructive and has no separate "pause" state** — there's no soft-disable short of deletion; if temporary suspension is the actual goal, consider reducing the Always available Cloud PCs count toward (but not necessarily to) zero instead.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Windows 365 for Agents pool, policy, and device evidence for escalation.
#>
Connect-MgGraph -Scopes "CloudPC.Read.All","DeviceManagementManagedDevices.Read.All","DeviceManagementConfiguration.Read.All"

Write-Host "=== Provisioning policies (agents) ===" -ForegroundColor Cyan
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -All |
    Select-Object DisplayName, Id, ProvisioningType, CloudPcNamingTemplate | Format-Table -AutoSize

Write-Host "=== CPCA-* managed devices ===" -ForegroundColor Cyan
Get-MgDeviceManagementManagedDevice -Filter "startswith(deviceName,'CPCA-')" |
    Select-Object DeviceName, Model, EnrolledDateTime, LastSyncDateTime, ManagementAgent |
    Format-Table -AutoSize

Write-Host "=== Cloud PCs for Agents (per policy) ===" -ForegroundColor Cyan
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId } |
    Select-Object DisplayName, Status, ProvisioningPolicyId | Format-Table -AutoSize
```

Package with: pool status screenshot (Provisioning policies (Agents) view), session-count screenshot (Active/Available), a copy of the Escalation Evidence template from `Agents-B.md`, and — if a partner-solution pool — confirmation of which partner portal owns the policy.

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| List agent provisioning policies | `Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -All` |
| Find CPCA-* devices | `Get-MgDeviceManagementManagedDevice -Filter "startswith(deviceName,'CPCA-')"` |
| List Cloud PCs by policy | `Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "provisioningPolicyId eq '<id>'"` |
| Confirm device sync recency | `Select-Object DeviceName, LastSyncDateTime` |
| Confirm enrollment profile matches policy name | Compare `EnrollmentProfileName` to provisioning policy `DisplayName` |
| Check pool status | Intune admin center > Devices > Provision Cloud PCs > Provisioning policies (Agents) |
| Toggle new device view | Devices > All devices > **Preview new device view** |
| Cloud PC Graph API reference | [cloudpc-api-overview](https://learn.microsoft.com/en-us/graph/api/resources/cloudpc-api-overview?view=graph-rest-beta&preserve-view=true) |

---
## 🎓 Learning Pointers

- **Pool-based management is the single biggest mental-model shift from Enterprise Cloud PCs.** Status, health, and most operational questions apply to the pool, not an individual VM — see [Cloud PC agent pools](https://learn.microsoft.com/en-us/windows-365/agents/cloud-pc-agent-pools).
- **The four-subsystem model (Computer-Create/Get/Do/See) maps directly onto where a given failure lives** — a provisioning problem is Computer-Create, a "can't get a Cloud PC" problem is Computer-Get, an action/automation problem is Computer-Do, and a human-access problem is Computer-See & Computer-Take Control. See [Architecture overview](https://learn.microsoft.com/en-us/windows-365/agents/architecture-overview).
- **Two ownership paths exist for provisioning policies, and only one is editable in Intune.** Self-managed (Agent 365) policies are edited in Intune; partner-solution (Copilot Studio, Project Opal, Researcher) policies are read-only in Intune and must be edited in the owning partner's portal. See [What is Windows 365 for Agents?](https://learn.microsoft.com/en-us/windows-365/agents/introduction-windows-365-for-agents).
- **Consumption-based billing and reset-after-use persistence are deliberate, not limitations to work around** — don't attempt to force user-persistent behavior onto this product; if that's the actual requirement, redirect to Enterprise/Business/Flex.
- **The legacy device view gap for `CPCA-*` devices is documented and current** — always confirm Preview new device view before investigating a "missing device data" report on one of these devices. See [Manage and monitor Cloud PCs for Agents in Microsoft Intune](https://learn.microsoft.com/en-us/windows-365/agents/device-management-cloud-pcs-agents).
- A companion **Windows 365 for Agents security baseline** (Windows 11, Microsoft Edge, Microsoft Defender for Endpoint settings) shipped in Intune Service Release 2608 (August 2026) — apply it to new agent pools the same way a security baseline would be applied to any other managed device population, via the standard Intune baseline assignment flow.
