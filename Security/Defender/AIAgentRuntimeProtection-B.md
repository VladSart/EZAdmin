# AI Agent Runtime Protection — Hotfix Runbook (Mode B: Ops)
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

Run on the affected Windows device (elevated PowerShell):

```powershell
# 1. Signature floor — runtime protection requires 1.451.224.0 or later
Get-MpComputerStatus | Select-Object AntivirusSignatureVersion, AMServiceEnabled, RealTimeProtectionEnabled

# 2. Current runtime protection mode
Get-MpPreference | Select-Object AiAgentProtection, AiAgentNetworkInspection

# 3. Is Defender AV in active mode (not passive — required for enforcement)?
Get-MpComputerStatus | Select-Object AMRunningMode

# 4. Which supported agent(s) are actually installed?
Get-Command claude, codex, gh -ErrorAction SilentlyContinue | Select-Object Name, Source

# 5. Any recent AI prompt-injection alerts already fired on this device?
Get-MpThreatDetection | Where-Object { $_.ThreatName -match 'AiAgent|PromptInjection' } | Select-Object -First 10
```

| Result | Interpretation |
|---|---|
| `AntivirusSignatureVersion` below `1.451.224.0` | Force a signature update before touching anything else — runtime protection silently no-ops on older signatures. |
| `AiAgentProtection` / `AiAgentNetworkInspection` = `Disabled` or blank | Protection was never enabled on this device. Go to Fix 1. |
| `AMRunningMode` ≠ `Normal` | Device has a third-party AV as primary and Defender is passive — runtime protection cannot enforce. Not an AI-agent-specific issue; escalate as a Defender onboarding gap. |
| Mode shows `Audit`/`Block` but user reports agent "not being protected" | Almost always Fix 3 (stale terminal session) or Fix 5 (unsupported agent/version). |
| No supported agent binary found | Nothing to protect on this device — close as not-applicable, don't chase further. |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Licensing: Defender for Endpoint Plan 2 / M365 E5 / Microsoft Agent 365 / M365 E7
    │
    ▼
Device onboarded to Defender for Endpoint (Sense running)
    │
    ▼
Microsoft Defender Antivirus in ACTIVE mode + real-time protection ON
    │
    ▼
AntivirusSignatureVersion ≥ 1.451.224.0 (platform/engine/intel all current)
    │
    ▼
Supported local AI agent installed (Claude Code / Codex CLI / GitHub Copilot CLI / GitHub Copilot app)
    │
    ▼
Set-MpPreference -AiAgentProtection <Audit|Block>          ← agent-native event inspection
Set-MpPreference -AiAgentNetworkInspection <Audit|Block>   ← network inspection (non-hooked agents)
    │
    ▼
Tamper Protection guards this setting (blocks unauthorized local changes — including a well-meaning admin's own ad-hoc PowerShell if it doesn't go through the sanctioned deployment path)
    │
    ▼
NEW terminal/agent session opened AFTER the setting change (existing sessions keep running unprotected)
    │
    ▼
Agent exposes vendor hook interface (agent-native) OR talks to LLM over an uninspectable transport (network — fails silently for cert-pinned/HTTP-3 agents)
    │
    ▼
Prompt / tool-call / tool-response inspected inline at each checkpoint → Audit (log only) or Block (stop + notify)
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm licensing eligibility.**
   Runtime protection requires Defender for Endpoint Plan 2, Microsoft 365 E5, Microsoft Agent 365, or Microsoft 365 E7. Plan 1 and Defender for Business are not eligible for this preview feature — don't spend time troubleshooting a Plan 1 tenant.

2. **Confirm the device is onboarded and AV is active.**
   ```powershell
   Get-MpComputerStatus | Select-Object AMRunningMode, RealTimeProtectionEnabled, OnboardingState
   ```
   Expect `AMRunningMode: Normal`, `RealTimeProtectionEnabled: True`. Anything else is a Defender onboarding issue, not an AI-agent one.

3. **Confirm signature floor.**
   ```powershell
   Get-MpComputerStatus | Select-Object AntivirusSignatureVersion
   ```
   Must be `1.451.224.0` or later. If older: `Update-MpSignature` and re-check.

4. **Confirm the mode is actually set.**
   ```powershell
   Get-MpPreference | Select-Object AiAgentProtection, AiAgentNetworkInspection
   ```
   Blank/`Disabled` means nothing is enforced — expected behavior, not a bug, until Fix 1 is applied.

5. **Confirm a NEW terminal was opened after enabling.**
   Runtime protection attaches at agent-process-start. An agent process that was already running when the preference changed is not retroactively protected. Ask the user to fully close and reopen the terminal/agent, then retest.

6. **Confirm the agent is on the supported list and hook-capable.**
   Agent-native event inspection only works for agents that expose vendor hooks: Claude Code, Codex CLI, GitHub Copilot CLI, GitHub Copilot app. An older or unofficial build of any of these may not expose the hook interface yet — check the agent's own version/changelog against its hooks documentation (linked in Learning Pointers) rather than assuming coverage.

7. **Check for the alert, not just the block message.**
   A genuine detection raises a **Suspicious AI prompt injection** alert in the Microsoft Defender portal (Critical/High/Medium/Low in Block mode, Informational in Audit mode). If the user reports a block but no alert exists, verify they're looking at the right device/tenant, and check `Get-MpThreatDetection` locally as a cross-check.

---
## Common Fix Paths

<details><summary>Fix 1 — Runtime protection never enabled on this device</summary>

```powershell
# Verify signature floor first
Get-MpComputerStatus | Select-Object AntivirusSignatureVersion

# Enable agent-native event inspection (start in Audit, not Block)
Set-MpPreference -AiAgentProtection Audit

# Enable network inspection for agents without vendor hooks
Set-MpPreference -AiAgentNetworkInspection Audit

# Verify
Get-MpPreference | Select-Object AiAgentProtection, AiAgentNetworkInspection
```
Close and reopen any terminal/agent session — the setting does not apply retroactively to already-running processes.

**Rollback:** `Set-MpPreference -AiAgentProtection Disabled` / `-AiAgentNetworkInspection Disabled`. Non-destructive — this only stops future inspection, it does not undo any prior block.
</details>

<details><summary>Fix 2 — Need this org-wide, not per-device</summary>

Native Intune policy support for this feature does not exist yet (preview limitation) — deployment is via an Intune **PowerShell platform script**, not a Settings Catalog or compliance policy.

```powershell
# Script content to deploy as an Intune platform script
Set-MpPreference -AiAgentProtection Audit
Set-MpPreference -AiAgentNetworkInspection Audit
```
Deploy with **Run this script using the logged on credentials = No** (must run in SYSTEM context to change Defender AV preferences). Assign to a pilot device group first.

**Gotcha:** Intune platform scripts run once per device and do not automatically re-run on a schedule. To change the mode later (e.g., Audit → Block), you must edit the script content or the policy itself — an unmodified re-push is a no-op and will NOT re-apply the setting. This is the single most common reason a "we changed it to Block weeks ago" ticket turns out to still be running Audit fleet-wide.

**Rollback:** Redeploy the script with `Disabled` values, or reassign scope to exclude the device group.
</details>

<details><summary>Fix 3 — Mode is Block/Audit, but the agent still isn't protected</summary>

Almost always a stale session. Runtime protection hooks are established when the agent process starts, not continuously polled.

1. Fully quit the agent AND the terminal window hosting it.
2. Confirm the setting is applied: `Get-MpPreference | Select AiAgentProtection`
3. Open a brand-new terminal window, then start the agent again.
4. Reproduce the test prompt-injection scenario.

**Rollback:** N/A — this is a verification step, not a change.
</details>

<details><summary>Fix 4 — Signature version below the 1.451.224.0 floor</summary>

```powershell
Update-MpSignature
Get-MpComputerStatus | Select-Object AntivirusSignatureVersion
```
If signatures won't update, treat as a standard Defender signature-delivery issue (WSUS/proxy/connectivity) — out of scope for this runbook; see the core Defender for Endpoint onboarding troubleshooting path.

**Rollback:** N/A — non-destructive.
</details>

<details><summary>Fix 5 — Agent isn't on the supported list</summary>

Zero protection is expected — not a bug — for any agent outside: Claude Code, Codex CLI, GitHub Copilot CLI, GitHub Copilot app (agent-native), or any agent using certificate pinning / HTTP/3 (network inspection can't see inside these either). Set expectations with the requester rather than continuing to troubleshoot a non-functional gap. Track the request as a feature-coverage gap for a future Defender release rather than an incident.

**Rollback:** N/A.
</details>

<details><summary>Fix 6 — Ready to move from Audit to Block</summary>

Only after the recommended 1–2 week observation window and after triaging Audit-mode alerts for false positives:

```powershell
Set-MpPreference -AiAgentProtection Block
Set-MpPreference -AiAgentNetworkInspection Block
```
If deployed via Intune, this requires editing the platform script content (see Fix 2's gotcha) and reassigning/forcing a re-run.

**Rollback:** `Set-MpPreference -AiAgentProtection Audit` reverts to logging-only without losing visibility.
</details>

<details><summary>Fix 7 — False positive: a legitimate tool response is being blocked</summary>

1. Confirm in the Defender portal that the alert is Informational (Audit) or an active Block.
2. If the file/content triggering the detection is legitimate, [submit it to Microsoft for analysis](https://learn.microsoft.com/en-us/defender-endpoint/defender-endpoint-false-positives-negatives#part-4-submit-a-file-for-analysis) rather than disabling protection outright.
3. Do not disable `AiAgentProtection` tenant-wide to work around one false positive — that removes protection for every agent on the device, not just the one triggering the noise. There is currently no per-agent or per-rule exclusion; the false-positive submission path is the only supported remediation.

**Rollback:** N/A.
</details>

---
## Escalation Evidence

```
=== AI Agent Runtime Protection — Escalation Template ===
Device name:
Device ID (Defender portal):
User:
Ticket #:

Licensing tier confirmed (MDE P2 / M365 E5 / Agent 365 / M365 E7):
AntivirusSignatureVersion:                 (must be ≥ 1.451.224.0)
AMRunningMode:                             (must be Normal)
AiAgentProtection mode:                    (Disabled / Audit / Block)
AiAgentNetworkInspection mode:             (Disabled / Audit / Block)
Deployment method:                         (manual PowerShell / Intune platform script)
Agent + version affected:
New terminal session opened after config change? (Y/N):

Suspicious AI prompt injection alert present in Defender portal? (Y/N, alert ID if yes):
Expected behavior:
Actual behavior:
Steps already attempted:
```

---
## 🎓 Learning Pointers
- This is a **preview** feature (as of this writing) gated to specific licenses — always confirm licensing before troubleshooting further; don't assume every onboarded MDE device is eligible.
- The "works, but only after a new terminal" behavior surprises a lot of engineers used to policy settings that apply live — runtime protection attaches at process start, it does not retrofit already-running agent processes.
- Read [AI agent runtime protection with Microsoft Defender for Endpoint (Preview)](https://learn.microsoft.com/en-us/defender-endpoint/ai-agent-runtime-protection-overview) for the conceptual model before the how-to — it explains *why* there are two inspection methods (agent-native vs. network) instead of one.
- [Set up AI agent runtime protection with Microsoft Defender for Endpoint](https://learn.microsoft.com/en-us/defender-endpoint/configure-ai-agent-runtime-protection) has the full `Set-MpPreference` reference and the recommended phased Test → Review → Deploy → Enforce rollout — follow that order rather than jumping straight to Block.
- Runtime protection is a sibling feature to (not the same as) [Local AI agent discovery](https://learn.microsoft.com/en-us/defender-endpoint/local-agent-discovery-overview), which is passive/automatic inventory with no configuration surface — don't confuse a discovery-inventory ticket with a runtime-protection-configuration ticket.
- Vendor hook documentation is the ground truth for whether an agent version actually supports agent-native inspection: [Claude Code hooks](https://code.claude.com/docs/en/hooks), [Codex CLI hooks](https://developers.openai.com/codex/hooks), [GitHub Copilot hooks](https://docs.github.com/copilot/how-tos/copilot-cli/customize-copilot/use-hooks).
