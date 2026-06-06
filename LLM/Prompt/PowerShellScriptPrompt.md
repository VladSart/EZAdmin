# PowerShell Script Prompt — Dependency‑Driven, Architecture‑Driven

Use this prompt to generate **reliable, repeatable PowerShell scripts** that handle real‑world constraints (permissions, policy, network, modules, reboots) and ship with preflight checks, idempotency, and rollback.

---

## How to use

1) Paste this template into ChatGPT.
2) Fill in the **Inputs** section.
3) The assistant should output:
   - A short plan
   - Then the full script
   - Then a quick “How to run”

**Output rule:** The assistant must put the **entire script in ONE single code block** with **no language tag** (so just triple backticks).

---

## Prompt Template (copy/paste)

You are my senior PowerShell automation engineer.

### 0) Non‑negotiables
- Build a **dependency-driven** and **architecture-driven** script.
- Script must be **idempotent** (safe to run multiple times).
- Must include **Preflight → Detect → Plan → Execute → Validate → Report → Rollback** phases.
- Must support **-WhatIf** and **-Confirm** semantics where applicable.
- Must produce a **clear exit code** (0 success, non-zero failure with reason).
- Must write structured logs to:
  - Console (human readable)
  - File (JSONL or CSV) at a configurable path
- Must avoid interactive prompts unless I explicitly allow them.
- Must not assume internet access unless I say so.

### 1) Goal
**What we’re trying to achieve (one sentence):**
- <WRITE THE GOAL>

### 2) Environment
- OS/Edition/Version: <e.g. Win11 24H2 / Server 2022>
- Join/Identity: <Workgroup/Domain/Entra ID>
- Management: <Intune/ConfigMgr/None>
- Execution context: <Local admin? SYSTEM? RMM?>
- Network: <Corp LAN / VPN / Proxy / No internet>

### 3) Constraints
- Reboot allowed? <Yes/No>
- Downtime allowed? <Yes/No>
- Policy limitations (GPO/Intune/ASR/AppLocker): <details>
- Change control window: <optional>

### 4) Inputs
Provide exact inputs; if unknown, say “unknown”.
- Target(s): <computer(s), user(s), file paths, URLs>
- Desired state: <what “done” means>
- Current state symptoms: <what’s happening now>
- Success criteria: <measurable checks>

### 5) Dependencies (force you to think)
List what the script might depend on. If anything is unknown, the script must **detect** it and fail with a helpful message.
- Required permissions/roles: <e.g. local admin, Exchange admin>
- Modules required: <Az, Microsoft.Graph, ActiveDirectory, etc>
- Windows features/services: <BITS, WU, WinRM, etc>
- External tools: <winget/choco/7zip>
- Endpoints/ports/URLs that must be reachable: <proxy/WUfB/Graph>
- Credentials/secrets: <how provided? never hardcode>

### 6) Output & Reporting
- Output artifacts (files/registry changes/config changes): <list>
- Required evidence pack: <logs, exported configs, command outputs>

### 7) Script Interface
Design the script like a real tool:
- Parameters (with validation): <list or “assistant propose”>
- Supports pipeline input? <Yes/No>
- Supports -Verbose/-Debug: <Yes/No>
- Supports -DryRun switch? <Yes/No>

### 8) Safety & Rollback
- What changes are risky and how to revert them: <details>
- Must include a **Rollback** function for every destructive operation.

### 9) Deliverables
Produce in this order:
1) **Dependency Map** (bulleted list)
2) **Execution Architecture** (phases + decision points)
3) **Failure Modes** (top 10 likely failures + how script handles them)
4) **The PowerShell Script** (single code block, no language tag)
5) **How to Run** (examples)
6) **Quick Verification** (commands/checks)

### 10) Quality Bar
- Use `Set-StrictMode -Version Latest`.
- Use `$ErrorActionPreference = 'Stop'` and catch errors intentionally.
- Use functions with verb-noun names.
- Use comment-based help at the top.
- Use consistent structured logging (timestamp, level, phase, message, data).
- Include `Test-*` functions for validation.
- Avoid regex/one-liners where readability suffers.
- No hardcoded tenant IDs, URLs, usernames, or secrets.

### 11) (Optional) Style preferences
- Keep code readable.
- Prefer native cmdlets.
- If you must use external tools, check presence and version first.
- If admin is required, the script must detect and exit with a clear message.

Now generate the deliverables.

---

## Minimal Example Input (for fast use)

### Goal
- Ensure Windows Update can scan Microsoft Update and download the latest feature update.

### Environment
- Win11 24H2, Entra ID joined, Intune managed, corp LAN w/ proxy

### Constraints
- No reboot, must run as local admin
- Must not use NuGet or find a roundabout way of getting it installed to get over things that block it

### Inputs
- Target: local machine
- Success: scan returns no errors; `Get-WindowsUpdateLog` contains no WSUS/dual-scan block

### Dependencies
- Services: wuauserv, bits, cryptsvc
- Policy: WUfB settings and WSUS `UseWUServer`

---

## Notes
If you want this to emit two variants ("Reference" + "Ops"), tell the assistant to produce:
- `ScriptName-A.ps1` (full logging, more checks)
- `ScriptName-B.ps1` (lean triage + minimal remediation)

