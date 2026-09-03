# Teams Mandatory Pre-Meeting Consent — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---

> **Source-confidence note:** this feature (Message Center post MC1454114, Roadmap ID 561914) is Message Center-only as of this writing — no Microsoft Learn conceptual page and no PowerShell/Graph cmdlet surface exist yet. Everything below is sourced from MC1454114's own description; re-verify the exact Teams admin center navigation path against the live portal, since it may still be settling. Rollout is phased by cloud: Targeted Release from September 2026, Worldwide/GCC mid-Oct to mid-Nov 2026, GCC High/DoD mid-Nov to mid-Dec 2026 — confirm the tenant's ring before troubleshooting an "it's missing" report.

---

## Triage

This is a Teams admin center UI feature with no PowerShell cmdlet surface — triage is portal-based, not script-based.

**First — identify which of two different "consent" features the ticket actually means.** This is the #1 source of wasted troubleshooting time:

| Reporter says... | They mean... |
|---|---|
| "I have to click through a message/agree to terms before I can even join the meeting" | **This feature** — mandatory pre-meeting consent |
| "A banner appeared saying the meeting is being recorded" | **Existing recording-consent notification** — see `Meeting-Policies-A/B.md`, unrelated feature |

**Once confirmed as this feature:**

1. Confirm the tenant's cloud (Worldwide / GCC / GCC High / DoD) and cross-check against the rollout table above — if the tenant is outside its window, the feature is not yet available, full stop.
2. In Teams admin center, confirm whether a consent policy has been **authored** (content exists) and, separately, whether it has been **enabled** (the feature is disabled by default — authoring alone does nothing).
3. If a consent screen appeared in an unexpected language, confirm which languages were actually authored versus the participant's device language setting.
4. If an organizer reports being blocked by their own meeting's consent screen, this is expected — organizers are not exempt.

| Result | Action |
|--------|--------|
| Tenant is outside its documented rollout ring/window | → Not a bug — inform the requester of the expected availability window |
| Policy authored but not enabled | → [Fix 1 — Enable the policy](#fix-1--enable-a-configured-but-inactive-policy) |
| No policy exists yet and one is wanted | → [Fix 2 — Author and enable a new policy](#fix-2--author-and-enable-a-new-consent-policy) |
| Wrong-language content shown | → [Fix 3 — Language fallback is working as designed](#fix-3--wrong-language-content-shown) |
| Organizer/internal user blocked by their own policy | → [Fix 4 — Expected behavior, no role exemption](#fix-4--organizer-or-internal-user-gated-by-their-own-policy) |
| Anonymous/external attendee stuck with no visible way past the screen | → [Fix 5 — Escalate as undocumented behavior](#fix-5--anonymous-or-external-attendee-appears-stuck) |
| Ticket is actually about recording consent, not this feature | → Redirect to `Meeting-Policies-A/B.md` |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Tenant's cloud has reached its rollout window for this feature
        │
Consent policy AUTHORED in Teams admin center (default-language content required)
        │
Consent policy EXPLICITLY ENABLED (disabled by default)
        │
Participant attempts to join a meeting governed by the policy
        │
Device language matched against authored languages (up to 4 extra + 1 default)
    -> match: shows that language's content
    -> no match: shows DEFAULT language content (silent fallback)
        │
ALL participants gated identically - organizer, internal, external, anonymous
        │
Consent acknowledgment recorded in tenant audit log
        │
Participant proceeds to normal join flow (lobby/auth per existing meeting policy)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm rollout eligibility**
Identify tenant cloud (Worldwide/GCC/GCC High/DoD) and compare today's date against the documented ring windows. If outside the window, stop here — this is expected non-availability, not a defect.

**Step 2 — Confirm policy exists and is enabled**
In Teams admin center, locate the consent policy configuration surface and confirm both that content has been authored and that the policy has been switched on. These are two separate steps — authored-but-disabled is the most common "nothing happens" root cause.

**Step 3 — Confirm language configuration**
Compare the list of authored languages against the reporting participant's device language. A mismatch resolves to the default language automatically; this is expected, not an error.

**Step 4 — Confirm role expectations**
No participant role — including the organizer — is exempt from a governed meeting's consent gate. Treat any "why do I have to consent to my own meeting" report as an expectation-setting conversation, not a bug investigation.

**Step 5 — For anything else, treat as undocumented territory**
Behavior for anonymous-attendee decline/skip flows, exact audit log record schema, and per-meeting scoping granularity are not fully documented by Microsoft as of this writing. Do not guess at a fix — collect evidence and escalate.

---

## Common Fix Paths

<details><summary>Fix 1 — Enable a configured-but-inactive policy</summary>

In Teams admin center, navigate to the consent policy configuration surface, confirm the authored default-language content (and any additional languages) look correct via the built-in preview, then explicitly enable the policy. Communicate the change to end users before enabling broadly — this is a hard, unskippable join-flow change with no organizer exemption.

**Rollback:** disable the policy. This stops future consent gating; already-recorded audit log entries are not affected and should be treated as a permanent compliance record.

</details>

<details><summary>Fix 2 — Author and enable a new consent policy</summary>

1. Confirm the exact required text with the requesting team (Legal/Compliance/Privacy) — this is compliance-facing content, not discretionary UX copy.
2. Author the default-language content in Teams admin center; add up to 4 additional language variants if the org has meaningful non-default-language meeting populations.
3. Use the built-in preview to confirm each language renders as expected.
4. Communicate to end users before enabling.
5. Enable the policy, then run a test join as both an internal and (if feasible) an external participant to confirm the consent screen and a corresponding audit log entry both appear.

**Rollback:** disable the policy in Teams admin center; no destructive state to undo.

</details>

<details><summary>Fix 3 — Wrong-language content shown</summary>

This is expected, silent-fallback behavior, not a defect. Confirm the participant's actual device language setting, then confirm whether that language was ever authored in the policy. If the business wants that language covered, add it as one of the up-to-4 additional language variants (if slots remain) — otherwise, the default language will continue to be shown for any unmatched device language.

**Rollback:** N/A — this is a configuration/expectation clarification, not a change to undo.

</details>

<details><summary>Fix 4 — Organizer or internal user gated by their own policy</summary>

Confirm this is expected: no role, including the meeting organizer, is exempt from a governed meeting's consent screen. Set expectations with the reporter rather than investigating further as an access-control fault.

**Rollback:** N/A.

</details>

<details><summary>Fix 5 — Anonymous or external attendee appears stuck</summary>

Microsoft has not fully documented the decline/skip workflow for anonymous or external attendees as of this writing. If reproducible, collect the Escalation Evidence below (including the exact join method and attendee type) and escalate to Microsoft support rather than attempting a local workaround — there is no confirmed client-side fix for this scenario at this time.

**Rollback:** N/A — escalation path, not a change.

</details>

---

## Escalation Evidence

```
TICKET: Teams Mandatory Pre-Meeting Consent Issue
=====================================================
Tenant cloud (Worldwide/GCC/GCC High/DoD): <value>
Current date vs. documented rollout window for that ring: <in/out of window>
Consent policy status (authored / enabled / disabled): <state>
Default language configured: <language>
Additional languages configured: <list>
Participant role affected (organizer/internal/external/anonymous): <role>
Participant's device language: <language>
Meeting join method (desktop app / web / mobile / device): <method>
Symptom: <no prompt appears / wrong language / stuck at consent screen / organizer unexpectedly gated>
Reproduction steps: <steps>
Audit log entry present for a test join: <yes/no>
Business impact: <e.g., compliance requirement blocked, meetings can't start>
Message Center post MC1454114 revision checked: <date>
```

---

## 🎓 Learning Pointers

- Confirm which of two similarly-named features a ticket is actually about first: this new join-flow consent gate, or Teams' existing recording-consent notification (`Meeting-Policies-A/B.md`). They are unrelated.
- The feature is **disabled by default** — authored content alone does nothing until a policy is explicitly enabled.
- **No role is exempt**, including meeting organizers — this is the most common source of confused tickets once a client first enables the policy.
- Rollout is phased **by cloud**, not just by date: Targeted Release (Sept 2026) → Worldwide/GCC (mid-Oct–mid-Nov 2026) → GCC High/DoD (mid-Nov–mid-Dec 2026). Always check this before troubleshooting an absent feature.
- There is no PowerShell or Graph cmdlet surface for this feature as of this writing — don't waste time hunting for one; Teams admin center is the only configuration path.
- Enabling this feature stores new customer data (consent acknowledgments) in the tenant audit log — worth flagging to a client's compliance/privacy reviewer before enabling. [Microsoft 365 Roadmap ID 561914](https://www.microsoft.com/en-US/microsoft-365/roadmap?filters=&searchterms=561914)
