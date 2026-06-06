# EZAdmin — Troubleshooting Runbook Prompt (Unified A/B)

Use this file to generate **GitHub-ready troubleshooting documentation** in one of two formats:

- **OUTPUT MODE A** = Reference / Verbose (deep, complete, explains why)
- **OUTPUT MODE B** = Ops / Short (skim-first, triage-first, minimal theory)

---

## RUN CONFIG (edit these)

OUTPUT MODE: <B>
SUBJECT: <Detect and Change WSUS to WFUB>
ENVIRONMENT:
- OS: <Windows 11 24h2>
- Join/Identity: <Entra ID joined>
- Management: <Intune/MDM>
- Network context: <corp LAN
- Constraints: <admin ok / no reboot>

CONTEXT (optional but recommended):
- Symptoms observed: <what the user sees>
- Error messages: <exact strings>
- What changed recently: <patches, VPN, policy, network>
- What already tried: <steps run>
- Known dependencies: <services, ports, URLs, certs>

OUTPUT OPTIONS (optional):
- Audience level: <L1 / L2 / L3> (default L2)
- Include GUI steps: <Yes/No> (default Yes when helpful)
- Include vendor specifics: <Yes/No> (default Yes when relevant)
- Include example outputs: <Yes/No> (default Yes for Mode A, selective for Mode B)

---

## GLOBAL RULES (apply to A and B)

### Accuracy + evidence
- Be correct and evidence-driven; do not guess.
- Prefer checks that produce **proof** (logs, status, config output) over “try this”.
- If the environment implies policy control (Intune/GPO), always warn that **policy overrides local settings**.

### Writing + formatting
- Output must be **GitHub Markdown** (clear headings, checklists, callouts, code fences).
- Use short paragraphs and bullets. Make it skim-friendly.
- Use `<details><summary>...</summary>...</details>` to collapse long sections.
- Keep commands copy/paste friendly.
- When you include command blocks, keep them tight and relevant.

### Troubleshooting style
- Prefer ordered, repeatable flow.
- Start with lowest-risk validation.
- Escalate complexity only when earlier layers are proven healthy.
- Always include common gotchas that fool engineers.

### Output discipline
- Produce a **single Markdown document** only.
- No extra commentary outside the doc.

---

# MODE A — Reference / Verbose

## Goal
Teach the system well enough that an engineer can troubleshoot confidently after reading once. Includes background, edge cases, and multiple remediation options.

## Required section order (must match exactly)
1) Skim Index (jump links)
2) Scope + Assumptions
3) How it works (in this environment)
4) Dependency stack (layered: hardware → OS → policy → network → external services)
5) Symptom → Likely cause map (fast triage)
6) Validation steps (top-to-bottom, commands + expected “good/bad”)
7) Troubleshooting steps (top-to-bottom, minimal risk first)
8) Remediation playbooks (by root cause; include rollback notes)
9) Evidence pack (what to collect for escalation)
10) Appendix: command cheat sheet

## Detail rules
- Always include a **Skim Index** at the top with jump links to every major section.
- L2/L3 engineer depth.
- Explain “why” briefly but clearly.
- Include GUI + CLI when useful.
- Include safety notes (what can break auth/VPN/certs/availability).
- Use `<details>` for long “how it works”, big symptom maps, and deep playbooks.

---

# MODE B — Ops / Short

## Goal
Fix or correctly escalate within **5–10 minutes**. Skim-first. Triage-first. Minimal theory.

## Required section order (must match exactly)
1) Skim Index (jump links)
2) Triage (30–60 seconds): 3–6 commands + interpretation
3) Dependency Cascade (collapsed layers; what must be true)
4) Diagnosis & Validation Flow (ordered; stop when break is found)
5) Common Fix Paths (collapsed; highest-probability only)
6) Escalation Evidence (copy/paste block for tickets)

## Rules
- No long explanations.
- Every command must have a purpose.
- Avoid rabbit holes; focus on highest-signal checks.
- Prefer strong “if X then Y” language.
- Keep it usable under pressure.

---

## NOW: WRITE THE RUNBOOK

Using the RUN CONFIG above:
- If `OUTPUT MODE` is **A**, output Mode A sections and standards.
- If `OUTPUT MODE` is **B**, output Mode B sections and standards.

Return only the final Markdown document.