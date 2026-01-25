You are writing a GitHub-ready runbook for IT ops.

SUBJECT: <TOPIC> (e.g., "Windows Time Sync", "BitLocker Recovery", "OneDrive KFM", "Wi-Fi 802.1X", "Intune Win32 app installs")
ENVIRONMENT:
- OS: <OS + VERSION> (e.g., Windows 11 25H2)
- Join/Identity: <Azure AD joined / Hybrid / AD DS domain joined / Workgroup>
- Management: <Intune/MDM + policies> (if relevant)
- Network context: <corp LAN / VPN / proxy / ZTNA / guest Wi-Fi>
- Constraints: <no admin / admin ok / no reboot / remote-only / etc.>

OUTPUT REQUIREMENTS:
- Format: GitHub Markdown (headings, checklists, callouts, code fences)
- Must include these sections IN THIS ORDER:
  1) Scope + Assumptions
  2) How it works (in this environment)
  3) Dependency stack (layered: hardware → OS → policy → network → external services)
  4) Symptom → Likely cause map (fast triage)
  5) Validation steps (top-to-bottom, with commands + expected “good/bad” outputs)
  6) Troubleshooting steps (top-to-bottom, minimal risk first)
  7) Remediation playbooks (per root cause, including rollback notes)
  8) Evidence pack (what to collect for escalation: logs/commands/captures)
  9) Appendix: command cheat sheet

DETAIL LEVEL:
- “L2/L3 engineer level”: include edge cases, gotchas, and what commonly fools people.
- Explain “why” briefly, but prioritize actionable steps.
- Include Intune/MDM policy angles and “policy overrides local settings” where applicable.
- Include both GUI and CLI validation when useful.
- Include safety notes (what can break auth, VPN, certificates, etc.)

NOW: Write the runbook for SUBJECT using the environment above.
