# Local AI Agent Discovery — Reference Runbook (Mode A: Deep Dive)
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

This covers **Local AI Agent Discovery** in Microsoft Defender for Endpoint (Preview) — the passive inventory capability that automatically detects AI agents and MCP (Model Context Protocol) server configurations running on onboarded Windows and macOS devices, and surfaces them in the Microsoft Defender portal's **Assets > AI agents > Local agents** inventory. It is a **different capability** from:

- **[AI Agent Runtime Protection](AIAgentRuntimeProtection-A.md)** — the enforcement layer that monitors the agentic loop and blocks malicious instructions in real time. Discovery has zero enforcement capability; the two features are independently enabled, independently licensed, and cover an overlapping but not identical set of agents.
- **Cloud/platform agent discovery** — a separate Defender capability that finds agents built with Microsoft Copilot Studio, Microsoft Foundry, AWS Bedrock, and GCP Vertex AI. Both local and cloud discovery feed the same `AgentsInfo` Advanced Hunting table and the same exposure graph, distinguished by the `Platform` property.
- **App Governance** (`Security/Defender/AppGovernance-A.md`) — governs OAuth-app-based Copilot/agent access to Microsoft 365 data, a different control plane entirely from device-level local agent processes.

Assumes: tenant is on commercial cloud (not sovereign/national cloud), has Defender for Endpoint Plan 2 at minimum, and devices are already onboarded to Defender for Endpoint. This capability is explicitly labeled **Preview** by Microsoft as of this writing (source pages dated 2026-05-27 through 2026-08-07) — treat specifics (supported-agent list, licensing gates, exact table schema) as subject to change before General Availability.

---
## How It Works

<details><summary>Full architecture</summary>

Microsoft Defender defines a **local AI agent** as the combination of three things: a **user**, a **device**, and an **agent type**. This composite-key model is the single most important architectural fact for understanding inventory behavior — it explains why the same tool can appear as one entry or many depending on who's running it and where, and why running the same CLI agent across many project folders on one machine does **not** multiply entries (folder isn't part of the key; user+device+type is).

```
┌──────────────────────────────────────────────────────────────────┐
│  Onboarded device (Windows or macOS)                              │
│                                                                     │
│   [Local AI agent process]  e.g. Claude Code, Cursor, Ollama       │
│         │  runs with USER-LEVEL permissions                       │
│         │  can reach files/tools/services the user account can    │
│         ▼                                                          │
│   [Defender Antivirus — active mode, real-time protection ON]      │
│         │  passive detection, no config needed beyond this         │
│         ▼                                                          │
│   [Defender sensor reports agent + MCP server config to cloud]     │
└──────────────────────────┬───────────────────────────────────────┘
                            ▼
        ┌───────────────────────────────────────────┐
        │  Microsoft Defender portal / backend        │
        │                                              │
        │  AgentsInfo table (profile: what IS it)      │
        │  ExposureGraphNodes (entity + criticality)   │
        │  ExposureGraphEdges (runs on / uses / used by)│
        │                                              │
        │  Assets > AI agents > Local agents (UI)      │
        └───────────────────────────────────────────┘
```

**Why this matters operationally:** because the key is user+device+type, a single physical machine used by three different engineers each running Claude Code will show **three separate inventory entries** — each carrying its own risk profile, since risk depends partly on the identity's own criticality (e.g., a Global Administrator running an auto-approving agent is a materially different risk than a standard user doing the same).

**The two visibility tiers (licensing-gated):**

| Tier | What it includes | License floor |
|---|---|---|
| **Inventory (base)** | Agent name/version/vendor, device, account, MCP server list, Advanced Hunting access via `AgentsInfo` | Defender for Endpoint Plan 2 |
| **Risk posture (add-on)** | Risk level, risk indicators (e.g., "Running on a Critical Device", "Used by a Critical User"), security recommendations | Microsoft 365 E7, or Microsoft Agent 365 + Defender for Endpoint Plan 2 |

Microsoft 365 E5 and E7 both *include* Defender for Endpoint Plan 2, so an E5 tenant gets the base inventory tier automatically but not risk posture; only E7 (or Agent 365 layered on Plan 2) unlocks the full picture.

**The supported agent taxonomy** (four categories, all discovered the same way):

| Category | Examples |
|---|---|
| CLI agents | Claude Code, Codex CLI, Gemini CLI, GitHub Copilot CLI, Junie CLI, Kiro CLI, OpenCode, Warp, Antigravity CLI |
| Desktop apps | ChatGPT Desktop, Claude Desktop, Codex Desktop, Goose Desktop, Hermes Agent, Ollama Desktop, Perplexity Desktop, Poe Desktop |
| Agentic IDEs | Cursor, Devin Desktop (formerly Windsurf), Kiro IDE, Antigravity IDE |
| VS Code extensions | Claude Code, Cline, Codex, Gemini Code Assist, GitHub Copilot, Roo Code |
| Claw-based agents | OpenClaw, Clawpilot, QClaw, Claw/Nanobot |

**MCP server discovery runs alongside agent discovery.** When a supported agent has configured MCP servers — local (a process the agent starts, identified by its launch command) or remote (a networked endpoint) — Defender surfaces both in the agent's detail pane and in Advanced Hunting via `McpServers`, `DeclaredTools`, and the `localAgentMetadata.localMcps` property.

</details>

---
## Dependency Stack

```
[Tier 0 — Tenant eligibility]
  Commercial cloud only (sovereign/national clouds unsupported)
  Defender for Endpoint Plan 2 license (minimum)
         │
[Tier 1 — Device onboarding]
  Device onboarded to Microsoft Defender for Endpoint
  Supported Windows or macOS build
  Defender Antivirus: active mode, real-time protection ON,
    current monthly platform/engine updates
         │
[Tier 2 — Discovery (automatic, zero config)]
  No policy, script, or deployment step required beyond Tier 0-1
  Discovery begins automatically once prerequisites are met
         │
[Tier 3 — Agent + MCP server detection]
  Supported agent type running under a user account on the device
  MCP server configurations (local and/or remote) associated with it
         │
[Tier 4 — Inventory surfacing]
  Assets > AI agents > Local agents (portal UI)
  AgentsInfo / ExposureGraphNodes / ExposureGraphEdges (Advanced Hunting)
         │
[Tier 5 — Risk posture layer — SEPARATE LICENSE GATE]
  Requires Microsoft 365 E7, or Microsoft Agent 365 + Defender Plan 2
  Unlocks: Risk level, Risk indicators, Security recommendations
```

**Cross-cutting dependency:** unlike almost every other Defender for Endpoint capability in this repo, there is **no configuration surface at all** for Discovery itself — no `Set-MpPreference` flag, no Intune policy, no onboarding-package option. The entire dependency chain is: is the device onboarded, and is AV in active mode. If both are true, discovery either works for a supported agent or the agent type simply isn't recognized yet.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Agent installed, used daily, never shows in inventory | Agent type not on the supported list — this is the #1 cause, not a config gap | Cross-check against the four-category supported list above |
| Agent shows in inventory but Risk fields are blank | Tenant lacks Microsoft 365 E7 / Microsoft Agent 365 on top of Defender Plan 2 | `Get-MgSubscribedSku`; confirm E7 or Agent 365 SKU present |
| Discovery works on Windows devices but not macOS (or vice versa) | Unlikely by design — both platforms are supported day-one; more likely a per-device onboarding/AV-mode gap on the affected platform specifically | Confirm onboarding + `AMRunningMode` on the affected device individually, don't assume a platform-wide gap |
| Same user/device/agent-type combo appears to duplicate | Almost never a true duplicate — usually a different host process (e.g., VS Code extension vs. CLI binary of the same product) being treated as a distinct agent type, which is correct behavior | Check the agent's `relatedProcess` field in `AgentsInfo`/`RawAgentInfo.localAgentMetadata` |
| `AgentsInfo` query returns cloud agents mixed in with local, or nothing at all | Missing `Platform == "LocalAgents"` filter | Add the filter; re-run |
| `ExposureGraphEdges` query returns every AI agent in the tenant, not just local ones | `ExposureGraphEdges` has no local-vs-cloud property of its own | Resolve local agent node IDs from `ExposureGraphNodes` first, then join to edges by `NodeId` |
| A `join` between `AgentsInfo` and `ExposureGraphNodes` returns zero rows despite both having data | `AgentId` is a `guid` in `AgentsInfo` but a string in the exposure graph's `NodeProperties` | Wrap both sides in `tostring()` before joining |
| Agent uninstalled weeks ago still appears "active" | Query isn't filtering `LifecycleStatus` to exclude `Deleted`/`Uninstalled`, or isn't taking only the latest record per `AgentId` | Use `arg_max(Timestamp, ...) by AgentId` then filter `LifecycleStatus` |
| Requester expects Defender to have blocked/stopped the agent | Category confusion — Discovery is inventory-only | Redirect to AI Agent Runtime Protection |

---
## Validation Steps

**1. Confirm tenant-level eligibility**
```powershell
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits |
    Where-Object { $_.SkuPartNumber -match "MDE|EMS|SPE" }
```
Good: Defender for Endpoint Plan 2 present (directly, or bundled via M365 E5/E7). Bad: no matching SKU — discovery cannot function tenant-wide regardless of per-device config.

**2. Confirm a specific device meets the two hard prerequisites**
```powershell
Get-MpComputerStatus | Select-Object AMRunningMode, RealTimeProtectionEnabled, AntivirusSignatureVersion
```
Good: `AMRunningMode: Normal`, `RealTimeProtectionEnabled: True`. Bad: `Passive` (third-party AV primary) — discovery, like every other Defender capability, goes dark.

**3. Confirm inventory population via the portal**
```
security.microsoft.com > Assets > AI agents > Local agents tab
```
Good: expected agents appear with device/user association. Bad: gaps — cross-reference against Diagnosis steps in the B-doc before assuming a defect.

**4. Confirm Advanced Hunting access and correct query shape**
```kusto
AgentsInfo
| where Platform == "LocalAgents"
| summarize arg_max(Timestamp, Name, Version, LifecycleStatus, RawAgentInfo) by AgentId
| where LifecycleStatus !in~ ("Deleted", "Uninstalled")
| count
```
Good: a count roughly matching the portal inventory's active-agent count. A material mismatch usually means the portal is showing a filtered/scoped view (e.g., RBAC-limited) that doesn't match an unrestricted KQL query's tenant-wide scope.

**5. Confirm risk-posture licensing if that's the specific gap**
```powershell
Get-MgSubscribedSku | Select-Object SkuPartNumber | Where-Object { $_.SkuPartNumber -match "SPE_E7|Agent365" }
```
Good: a matching SKU. Bad: none found — risk level/indicators/recommendations will stay blank regardless of device-level config; this is a licensing decision, not a technical fault.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Tenant and licensing eligibility**
1. Confirm commercial cloud (not GCC High/DoD/21Vianet/sovereign) — Discovery is unsupported there entirely as of this writing.
2. Confirm Defender for Endpoint Plan 2 at minimum.
3. If risk posture is the actual complaint, separately confirm E7 or Agent 365 — don't conflate the two license gates.

**Phase 2 — Device-level prerequisites**
4. Confirm the device is onboarded to Defender for Endpoint (`security.microsoft.com > Assets > Devices`).
5. Confirm `AMRunningMode: Normal` and `RealTimeProtectionEnabled: True` — the same two checks used for every other Defender AV-dependent capability in this repo.
6. Confirm current monthly platform/engine updates are applied — Microsoft explicitly lists this as a prerequisite distinct from just "AV is on."

**Phase 3 — Agent-type support verification**
7. Cross-check the specific agent binary/process against the four-category supported list. An agent not on the list will never appear — there is no manual override or "request support for this agent" self-service path documented.
8. If the agent is a VS Code extension vs. a CLI tool of the same product family, expect them to register as **distinct** agent types even though they share a vendor/name — this is correct, not a duplicate.

**Phase 4 — Query correctness (Advanced Hunting)**
9. Always filter `Platform == "LocalAgents"` in `AgentsInfo` queries — omitting it mixes in cloud agents (Copilot Studio, Foundry, AWS Bedrock, GCP Vertex AI).
10. Always resolve local agent nodes from `ExposureGraphNodes` before joining to `ExposureGraphEdges` — the edges table has no platform-identifying property of its own.
11. Always `tostring()` both sides of an `AgentId`-to-`NodeProperties.rawData.aiAgentMetadata.id` join — type mismatch (guid vs. string) silently returns zero rows rather than an error.
12. Always take the latest record per `AgentId` via `arg_max(Timestamp, ...)` and exclude `Deleted`/`Uninstalled` `LifecycleStatus` values when building a "current state" view — `AgentsInfo` is an append-log of profile updates, not a single current-state table.

**Phase 5 — Scope correction**
13. If the actual requirement is enforcement (block/restrict an agent's actions), stop — this capability cannot do that. Redirect to AI Agent Runtime Protection and confirm its separate prerequisites.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Close a visibility gap for a genuinely-supported agent</summary>

1. Confirm the agent is on the supported list (Phase 3) — if not, this is not fixable by configuration; document as a known product limitation and consider Microsoft feedback channels if business-critical.
2. Confirm the device onboarding + AV-active-mode prerequisites (Phase 2) on the specific affected device(s), not just tenant-wide.
3. Allow a reasonable propagation window (Microsoft doesn't publish an exact SLA for first discovery; treat "several hours" as the working assumption based on comparable Defender discovery features) before escalating.
4. If still missing after prerequisites are confirmed and time has passed, capture the Evidence Pack below and escalate to Microsoft support — this can indicate a genuine backend discovery gap for an otherwise-eligible agent.

**Rollback:** N/A — Discovery has no destructive actions; this playbook is purely diagnostic/escalatory.

</details>

<details><summary>Playbook 2 — Stand up risk-posture visibility for a tenant that only has base inventory</summary>

1. Confirm current state: Defender for Endpoint Plan 2 present, E7/Agent 365 absent (Validation step 5).
2. This is a licensing decision, not a technical configuration — route to whoever owns Microsoft 365 licensing for a cost/benefit call on E7 vs. standalone Microsoft Agent 365.
3. Once the license lands, no additional configuration is needed — risk level, indicators, and recommendations populate automatically for already-discovered agents; there's no separate "enable risk scoring" toggle.

**Rollback:** Removing the E7/Agent 365 license reverts risk-posture visibility to blank on next evaluation cycle; the base inventory (Plan 2 tier) remains unaffected.

</details>

<details><summary>Playbook 3 — Build a recurring local-agent risk review using Advanced Hunting</summary>

1. Use the "risky configurations" query pattern (agents with `AutoApprove =~ "true"` or `TrustedProcess =~ "false"`) as a scheduled Advanced Hunting detection rule, so newly-discovered risky agents generate an alert rather than requiring a manual portal check.
2. Layer in the critical-device join (agents running on `criticalityLevel` 0/1 assets) to prioritize triage — an auto-approving agent on a standard workstation is a different urgency than the same configuration on a domain controller or executive's device.
3. For identity-centric risk, use the "users whose agents reach critical/sensitive assets" query pattern to find the accounts with the widest blast radius, independent of which specific agent they're running.
4. Route findings to whoever owns AI governance/security posture for the org — this is a visibility tool, not an enforcement one, so findings require a human or a separate enforcement control (Runtime Protection, Conditional Access, etc.) to act on.

**Rollback:** N/A — read-only reporting playbook.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Local build-side evidence for a Local AI Agent Discovery escalation.
    For the full tenant-wide inventory/risk picture, pair this with the
    AgentsInfo Advanced Hunting queries documented in this runbook.
#>
$evidence = [ordered]@{
    ComputerName          = $env:COMPUTERNAME
    AMRunningMode         = (Get-MpComputerStatus).AMRunningMode
    RealTimeProtection    = (Get-MpComputerStatus).RealTimeProtectionEnabled
    SignatureVersion      = (Get-MpComputerStatus).AntivirusSignatureVersion
    KnownAgentBinaries    = Get-Command claude, codex, gh, cursor, ollama, cline `
                                -ErrorAction SilentlyContinue |
                                Select-Object Name, Source, Version
    OSBuild               = (Get-CimInstance Win32_OperatingSystem).Version
}
$evidence.GetEnumerator() | ForEach-Object { "`n=== $($_.Key) ===`n"; $_.Value | Format-Table -AutoSize | Out-String }
$evidence | ConvertTo-Json -Depth 6 | Out-File ".\LocalAIAgentDiscovery-Evidence-$(Get-Date -Format yyyyMMdd-HHmm).json"
```

Pair this local snapshot with the tenant-wide `Get-LocalAIAgentDiscoveryAudit.ps1` script (Graph-based) for the portal-side inventory and licensing state.

---
## Command Cheat Sheet

| Command / Query | Purpose |
|---|---|
| `Get-MpComputerStatus` | Local AV mode, real-time protection, signature version |
| `Get-MgSubscribedSku` | Tenant licensing — Defender Plan 2, E7, Agent 365 |
| `AgentsInfo \| where Platform == "LocalAgents"` | Advanced Hunting: local agent profile records |
| `ExposureGraphNodes \| where NodeLabel == "ai-agent"` | Advanced Hunting: agent nodes in the exposure graph |
| `ExposureGraphEdges` (joined via resolved node IDs) | Advanced Hunting: agent-to-device/identity/resource relationships |
| Portal: `Assets > AI agents > Local agents` | Inventory UI, per-agent detail pane, attack surface map |
| Portal: agent detail pane > **Go hunt** | Jumps to a pre-filled Advanced Hunting query for that agent |
| Portal: agent detail pane > **View on map** | Opens the exposure/attack-surface map centered on that agent |

---
## 🎓 Learning Pointers

- **Zero configuration surface** — no policy, script, or Intune profile turns this on. If Tier 0-1 prerequisites (licensing + onboarding + active-mode AV) are met, discovery is automatic. This is a sharp contrast to Runtime Protection, which needs explicit `Set-MpPreference` configuration, and is worth stating plainly to admins who go looking for a toggle that doesn't exist. [Local AI agent discovery overview](https://learn.microsoft.com/en-us/defender-endpoint/local-agent-discovery-overview)
- **The composite key is user + device + agent type**, not just "the tool." This explains both why the same tool used in many project folders is one entry, and why the same tool used by different people on the same machine is genuinely multiple entries — each carrying independent risk context tied to that specific identity.
- **Two separate license gates, easy to conflate.** Defender for Endpoint Plan 2 gets the inventory and Advanced Hunting access; Microsoft 365 E7 or Microsoft Agent 365 additionally unlocks risk level/indicators/recommendations. An E5 tenant (which bundles Plan 2) will see agents listed with no risk score, and that's expected, not broken. [Discover local AI agents — Licensing](https://learn.microsoft.com/en-us/defender-endpoint/discover-local-ai-agents#licensing)
- **Advanced Hunting query correctness matters more here than most tables** — three distinct footguns are documented directly by Microsoft: forgetting the `Platform` filter, joining `ExposureGraphEdges` without first resolving local agent nodes from `ExposureGraphNodes`, and comparing `AgentId` (guid) to the exposure graph's string representation without `tostring()`. All three fail silently (wrong or empty results), not with an error.
- **This is inventory, not enforcement — say so explicitly to requesters.** The most likely support-ticket miscommunication is someone expecting Discovery to have stopped an agent from doing something; it never can. Pair with [AI Agent Runtime Protection](AIAgentRuntimeProtection-A.md) when the actual need is blocking, not visibility.
- **Preview status caveat:** re-verify the supported-agent list and licensing table against the live Learn pages before treating either as settled — Microsoft's own disclaimer states this content may be substantially modified before General Availability.
- **Official docs:** [Local AI agent discovery with Microsoft Defender for Endpoint (Preview)](https://learn.microsoft.com/en-us/defender-endpoint/local-agent-discovery-overview) | [Discover local AI agents with Microsoft Defender for Endpoint (Preview)](https://learn.microsoft.com/en-us/defender-endpoint/discover-local-ai-agents) | [AgentsInfo table reference](https://learn.microsoft.com/en-us/defender-xdr/advanced-hunting-agentsinfo-table) | [Discover AI agents and assess security posture using Microsoft Defender](https://learn.microsoft.com/en-us/defender-xdr/security-for-ai/ai-agent-inventory)
