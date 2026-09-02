# Local AI Agent Discovery — Hotfix Runbook (Mode B: Ops)
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

**Read this first:** Local AI Agent Discovery is a **passive inventory feature** — it discovers and lists AI agents/MCP servers already running on onboarded devices. It has **no enforcement capability of its own**. If the ticket is "block this agent" or "stop this agent from acting," that's [AI Agent Runtime Protection](AIAgentRuntimeProtection-B.md), a separate control. Confirm which one the requester actually needs before troubleshooting.

```powershell
# 1 — Is the device onboarded to Defender and is AV in active mode w/ real-time protection?
#     (Discovery has zero config of its own — it rides entirely on these two prerequisites)
Get-MpComputerStatus | Select-Object AMRunningMode, RealTimeProtectionEnabled, AntivirusSignatureVersion

# 2 — Is a known agent binary actually present on this device?
Get-Command claude, codex, gh, cursor, ollama -ErrorAction SilentlyContinue | Select-Object Name, Source

# 3 — Portal: is the agent showing in the inventory at all?
#     security.microsoft.com > Assets > AI agents > Local agents tab > filter by device name
```

| Symptom | Likely cause | Go to |
|---|---|---|
| Agent installed and used, but never appears in **Assets > AI agents > Local agents** | Device not onboarded to MDE, AV not in active mode, or agent isn't on the supported list | Fix 1 |
| Agent appears, but **Risk level / Risk indicators / Recommendations** columns are blank | Tenant has Defender for Endpoint Plan 2 only — those columns need Microsoft 365 E7 or Microsoft Agent 365 on top | Fix 2 |
| Same agent shows as **multiple separate entries** for one user on one device | Expected — Defender keys an entry by user+device+agent type; check whether it's genuinely a different install path/process, not a bug | Fix 3 |
| Requester wants Defender to **block** a discovered agent's actions | Wrong feature — Discovery is read-only. Redirect to AI Agent Runtime Protection | Fix 4 |
| Advanced hunting `AgentsInfo` query returns nothing for `Platform == "LocalAgents"` | Either no local agents on any onboarded device yet, or the query is missing the `Platform` filter and being drowned out by cloud-agent rows | Fix 5 |
| Agent was uninstalled but still shows "active" in inventory | `LifecycleStatus` hasn't updated yet, or the query used isn't filtering out `Deleted`/`Uninstalled` records | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for an agent to appear in inventory</summary>

```
[Commercial cloud tenant — sovereign/national clouds NOT supported]
    └── [Microsoft Defender for Endpoint Plan 2 license]
            └── [Device onboarded to Defender for Endpoint]
                    └── [Device on a supported Windows or macOS build]
                            └── [Defender Antivirus: active mode + real-time protection ON
                                 + current monthly platform/engine updates]
                                    └── [No additional config needed — discovery is automatic]
                                            └── [Supported agent type installed: CLI / desktop app /
                                                 agentic IDE / VS Code extension / Claw-based agent]
                                                    └── [Agent surfaces in Assets > AI agents > Local agents]
                                                            └── [Risk level / indicators / recommendations
                                                                 require ADDITIONAL license:
                                                                 Microsoft 365 E7, or Microsoft Agent 365 +
                                                                 Defender for Endpoint Plan 2]
```

**Key fact:** there is no deployment step, policy, or script to turn this on beyond the onboarding + active-mode-AV prerequisites already required for baseline Defender for Endpoint. If those two boxes are checked and an agent still doesn't appear, the answer is almost always "unsupported agent type," not a misconfiguration.

</details>

---
## Diagnosis & Validation Flow

**1. Confirm baseline Defender prerequisites on the device**
```powershell
Get-MpComputerStatus | Select-Object AMRunningMode, RealTimeProtectionEnabled
```
Expected: `AMRunningMode: Normal`, `RealTimeProtectionEnabled: True`. A third-party AV running as primary (Defender passive) blocks discovery just like it blocks every other Defender capability — this is not agent-discovery-specific.

**2. Confirm the agent type is actually supported**
Cross-check the installed agent against the supported list (CLI: Claude Code, Codex CLI, Gemini CLI, GitHub Copilot CLI, Junie CLI, Kiro CLI, OpenCode, Warp, Antigravity CLI; Desktop: ChatGPT/Claude/Codex/Goose/Hermes/Ollama/Perplexity/Poe Desktop; IDEs: Cursor, Devin Desktop, Kiro IDE, Antigravity IDE; VS Code extensions: Claude Code, Cline, Codex, Gemini Code Assist, GitHub Copilot, Roo Code; Claw-based: OpenClaw, Clawpilot, QClaw, Claw/Nanobot). An unsupported/unlisted agent will never appear — this is expected, not a bug to chase.

**3. Query the inventory directly via Advanced Hunting**
```kusto
AgentsInfo
| where Platform == "LocalAgents"
| summarize arg_max(Timestamp, Name, Version, LifecycleStatus, RawAgentInfo) by AgentId
| where LifecycleStatus !in~ ("Deleted", "Uninstalled")
```
Expected: one row per agent/device/user combination. Empty result with a known-supported agent installed → recheck prerequisite step 1, then escalate.

**4. Confirm licensing if Risk columns are the specific complaint**
Defender for Endpoint Plan 2 (bundled in Microsoft 365 E5/E7) is the floor for discovery itself. Risk level, risk indicators, and security recommendations additionally require Microsoft 365 E7 or Microsoft Agent 365 layered on top of Plan 2 — a tenant with E5-only Plan 2 will see the inventory and can query Advanced Hunting, but those three columns stay blank by design.

**5. If chasing an enforcement request, stop and redirect**
Discovery cannot block, quarantine, or restrict an agent. If the actual ask is prevention, this is [AI Agent Runtime Protection](AIAgentRuntimeProtection-B.md) — a separate feature with its own prerequisites (signature floor, `Set-MpPreference -AiAgentProtection`).

---
## Common Fix Paths

<details><summary>Fix 1 — Agent never appears in the inventory</summary>

1. Confirm the device is onboarded: `security.microsoft.com > Assets > Devices` — search for the device name.
2. Confirm AV active mode and real-time protection (Diagnosis step 1). Fix any third-party-AV-primary conflict via the standard MDE onboarding runbook, not this one.
3. Confirm the agent type against the supported list (Diagnosis step 2). If it's not listed, this is a documented gap — Defender does not discover every possible agent, only the named set. There is no manual "add this agent" override.
4. If all three check out and the agent still doesn't appear, allow up to a few hours for initial discovery to propagate, then re-check. If still missing, escalate with the Evidence Pack below — this can indicate a genuine detection gap for an otherwise-supported agent.

**Rollback:** N/A — read-only diagnostic path.

</details>

<details><summary>Fix 2 — Risk level / indicators / recommendations are blank</summary>

1. Confirm current licensing: Microsoft 365 admin center > Billing > Licenses, or `Get-MgSubscribedSku` for Microsoft 365 E7 / Microsoft Agent 365.
2. If the tenant only has Defender for Endpoint Plan 2 (via E5 or a standalone Plan 2 SKU), this is expected — not a bug. The inventory itself, agent details, and Advanced Hunting still work fully without the higher license.
3. If the business genuinely needs risk scoring on discovered agents, this is a licensing decision (E7 or Agent 365 add-on), not a support fix — route to whoever owns licensing decisions.

**Rollback:** N/A.

</details>

<details><summary>Fix 3 — Same agent shows multiple entries for one user/device</summary>

1. Defender keys an inventory entry by the combination of **user + device + agent type**. If the same person runs the same CLI tool (e.g., Claude Code) across many project folders on one machine, that's still a **single** entry, not multiple — per Microsoft's own definition.
2. Multiple entries for what looks like "the same agent" usually means: different accounts on the same device, the same account across different devices, or genuinely different agent types that share a similar name (e.g., a VS Code extension vs. the CLI tool of the same product family — these are discovered as distinct agent types).
3. Confirm via the agent's **Details** pane (Device details / User details tabs) which dimension actually differs before treating it as a duplicate-entry defect.

**Rollback:** N/A.

</details>

<details><summary>Fix 4 — Requester actually wants enforcement, not visibility</summary>

1. Local AI Agent Discovery cannot block, restrict, or quarantine anything — it is inventory-only.
2. Redirect to [AI Agent Runtime Protection](AIAgentRuntimeProtection-B.md), which monitors the agentic loop and can block malicious instructions, but has its own separate signature-version floor and `Set-MpPreference` configuration.
3. Note for the requester: both features can run simultaneously and cover the same agent — Discovery answers "what's out there and how risky," Runtime Protection answers "block it in real time." They are not alternatives to each other.

**Rollback:** N/A — no action taken by Discovery itself.

</details>

<details><summary>Fix 5 — Advanced Hunting query returns nothing</summary>

```kusto
AgentsInfo
| where Platform == "LocalAgents"
```
1. If this returns zero rows tenant-wide, confirm at least one onboarded device has a supported agent installed and meets the AV-active-mode prerequisite (Diagnosis steps 1–2) before assuming a query problem.
2. A common mistake: omitting the `Platform == "LocalAgents"` filter. Without it, cloud agent rows (Copilot Studio, Foundry, AWS Bedrock, GCP Vertex AI agents) dominate the result set and make it look like local discovery isn't working, when it's actually a filtering issue.
3. If querying `ExposureGraphNodes` instead, remember `ExposureGraphEdges` has **no property identifying local agents directly** — always resolve the local agent node set from `ExposureGraphNodes` first (filtering on `NodeLabel == "ai-agent"` and the `LocalAgents` platform property in `NodeProperties`), then join to edges by node ID. Filtering `ExposureGraphEdges` alone by `SourceNodeLabel == "ai-agent"` returns every AI agent in the tenant, cloud included.

**Rollback:** N/A — query correction only.

</details>

<details><summary>Fix 6 — Uninstalled agent still shows as active</summary>

1. `AgentsInfo` adds a new record each time an agent profile updates rather than overwriting in place — a single agent typically has several historical records.
2. Confirm the query is taking the latest record per agent (`arg_max(Timestamp, ...) by AgentId`) and filtering out `LifecycleStatus in ("Deleted", "Uninstalled")`. A query that skips either step will show stale/removed agents as current.
3. If the latest record still shows an active `LifecycleStatus` for a genuinely-uninstalled agent, allow time for the next discovery cycle to catch up before escalating — this is a detection-latency question, not a config problem, since there's no manual re-scan trigger exposed to admins.

**Rollback:** N/A.

</details>

---
## Escalation Evidence

```
LOCAL AI AGENT DISCOVERY — ESCALATION TEMPLATE
================================================
Tenant:                        <tenant name/ID>
Device(s) affected:            <device name(s) / DeviceId>
Device onboarded to MDE:       Yes / No
AV mode (AMRunningMode):       <Normal / Passive / other>
Agent in question:             <name, version, install path>
Agent on supported list:       Yes / No / Unsure
License: Defender Plan 2:      Yes / No
License: E7 or Agent 365:      Yes / No
Inventory entry present:       Yes / No
AgentsInfo query result:       <paste relevant rows or "empty">
Requested outcome:             <visibility only / enforcement — if enforcement, redirected to Runtime Protection>
Steps already tried:
```

---
## 🎓 Learning Pointers

- Discovery is **passive and automatic** — there is no deployment step, no policy object, no script to run. If baseline Defender for Endpoint onboarding and active-mode AV are already in place, discovery either works or the agent type simply isn't on the supported list yet. [Local AI agent discovery with Microsoft Defender for Endpoint (Preview)](https://learn.microsoft.com/en-us/defender-endpoint/local-agent-discovery-overview)
- Don't confuse this with [AI Agent Runtime Protection](AIAgentRuntimeProtection-B.md) — Discovery is inventory-only and has the broader supported-agent list; Runtime Protection is enforcement-only and requires its own signature floor and `Set-MpPreference` configuration. A device can have one, both, or neither independently.
- Risk level, risk indicators, and security recommendations are **licensing-gated separately** from the inventory itself — Defender for Endpoint Plan 2 gets you the list, Microsoft 365 E7 or Microsoft Agent 365 gets you the risk scoring on top of it. See [Discover local AI agents](https://learn.microsoft.com/en-us/defender-endpoint/discover-local-ai-agents#licensing).
- Windows and macOS are both supported for local discovery — this is one of the few Defender AI-security capabilities with day-one macOS parity, worth knowing for mixed-fleet tenants.
- This entire capability is explicitly labeled **Preview** by Microsoft as of this writing — expect the supported-agent list and licensing gates to change before General Availability; re-verify against the live Learn page rather than treating this runbook's supported-agent list as permanently exhaustive.
- **Community:** Microsoft Defender Tech Community (Security, Compliance, and Identity board), r/msp, r/sysadmin — this is new enough that ticket patterns are still forming.
