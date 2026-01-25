# Version B — “Ops / Incident / Runbook”
Purpose
	•	Fix the problem
	•	Fast
	•	Under pressure
	•	Minimal thinking

Who reads it
	•	On-call engineer
	•	You at work
	•	Someone with 3 tickets open and no patience

---

### Prompt Template

----

Create a Version B documentation file.

Style:
- Short
- Sharp
- Operational
- Zero theory unless required for decision-making

Structure rules:
- Must include, in this order:
  1. Skim Index
  2. Triage (30–60 seconds)
  3. Dependency Cascade (collapsed)
  4. Ordered diagnosis & validation flow
  5. Common fix paths
  6. Escalation evidence

Rules:
- No long explanations
- No history lessons
- No architecture essays
- Every command must exist for a reason

Tone:
- Direct
- Confident
- Practical

Formatting:
- GitHub Markdown
- Designed for fast scrolling
- Collapsible sections preferred
- Copy/paste friendly

Goal:
Someone should be able to fix or correctly escalate the issue
within 5–10 minutes using only this document.
# Prompt B

Use: `LLM/Prompt/Troubleshooting.md`
Set: `OUTPUT MODE: B`
