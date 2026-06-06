# Version A — “Reference / Engineering Doc”
Purpose
	•	Learning
	•	Understanding systems
	•	Long-term reference
	•	Explains why things behave the way they do

Who reads it
	•	You
	•	Engineers learning the stack
	•	Future-you at 2am wondering “why is this even a thing?”

---

### Prompt Template

----

Create a Version A documentation file.

Style:
- Verbose but structured
- Engineering-grade explanations
- Clear reasoning and causality
- Assume the reader wants to understand *why*, not just *what*

Structure rules:
- Must include:
  - Overview / Scope
  - How the system works
  - Dependency stack or architecture
  - Symptom → Cause mapping
  - Full troubleshooting flow
  - Remediation playbooks
  - Escalation evidence

Tone:
- Calm
- Precise
- No fluff
- No motivational language

Formatting:
- GitHub-style Markdown
- Heavy use of headings
- Use `<details>` blocks for long sections
- Designed for deep reading, not speed

Goal:
This document should teach the system well enough that someone could
troubleshoot it confidently after reading it once.
# Prompt A

Use: `LLM/Prompt/Troubleshooting.md`
Set: `OUTPUT MODE: A`
