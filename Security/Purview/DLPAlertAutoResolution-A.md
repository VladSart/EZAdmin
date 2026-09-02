# DLP Alert Auto-Resolution & Tagging — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

This runbook covers **Microsoft Purview DLP Alert Auto-Resolution and Tagging rules** (Microsoft 365 Roadmap ID 568371) — Preview August 2026, General Availability September 2026, for Microsoft Purview on the web in the Worldwide standard multi-tenant cloud. It assumes:

- One or more DLP policies already exist and are actively generating alerts (this runbook does not cover DLP policy authoring — see `DLP-Policy-A.md`/`-B.md` for that).
- The tenant holds any DLP-licensed SKU (single-event alerting is available on every DLP-licensed tier; aggregate/threshold alerting requires A5, E5/G5, or specific add-ons — see Dependency Stack).
- The reader is already comfortable with the general DLP alert lifecycle (Trigger → Notify → Triage → Investigate → Remediate → Tune).

**Does not cover:** DLP policy rule authoring or SIT/classification tuning (`DLP-Policy-A.md`), the AI-assisted **DLP Alert Triage Agent** in Security Copilot (a separate, non-deterministic capability — contrasted below but not documented in depth here), Defender XDR's broader incident-correlation model (`Security/Defender/_AGENT.md`), or GCC/GCC High/DoD rollout timing (this feature's initial GA wave targets Worldwide standard multi-tenant only; sovereign-cloud availability should be re-verified against the live Roadmap entry before being promised to a client).

As of this writing, **auto-resolution and tagging rules have no documented PowerShell or Microsoft Graph read/write surface** — they are configured and inspected entirely in the Purview portal (Data Loss Prevention → Alerts → Alert rules). This is explicitly called out throughout this runbook and its companion audit script, rather than implied.

---

## How It Works

### The DLP alert lifecycle this feature sits inside

Every Purview DLP alert moves through six stages, and understanding where auto-resolution/tagging sits in that chain is the single most important architectural fact in this topic:

1. **Trigger** — a DLP policy rule's conditions are matched (sensitive info exfiltrated, shared inappropriately, or a risky endpoint activity like removable-media copy).
2. **Notify** — the alert is sent to *both* the Defender XDR incident queue and the Purview DLP Alerts dashboard independently; email notifications may also fire per policy configuration.
3. **Triage** — an analyst (or, as of Sept 2026, a **rule**) decides true positive vs. false positive, sets priority, and assigns an owner.
4. **Investigate** — the assigned owner correlates evidence using Activity Explorer, Content Explorer, and Defender's incident-correlation tooling.
5. **Remediate** — actions taken (reset password, disable account, apply a sensitivity label, unshare, and more via Defender XDR's in-place remediation actions).
6. **Tune** — the underlying DLP policy itself is adjusted based on what the alert history reveals.

**Auto-resolution and tagging rules operate entirely within stage 3 (Triage).** They never touch stages 1-2 (the DLP policy's own detection/enforcement logic keeps running exactly as configured) and they don't perform stage 5 remediation actions. A rule can only change an alert's *disposition* (Resolved, tagged) — it cannot suppress the underlying policy match, cannot un-block content, and cannot modify what gets logged to Activity Explorer.

### Single-event vs. aggregate-event alerts (the population these rules act on)

| Alert type | Typical use | Licensing |
|---|---|---|
| **Single-event** | High-sensitivity, low-volume events (e.g., one email with 10+ credit card numbers) | Any DLP-licensed tier (E1/E3/E5/F1/G1/G3/G5) |
| **Aggregate-event** | Higher-volume patterns over a time window (e.g., 10 separate emails with 1 card number each over 48 hrs) | Requires A5, E5/G5, or an E1/F1/G1/E3/G3 tenant with Defender for Office 365 Plan 2, Microsoft Purview Suite, or the Microsoft 365 eDiscovery and Audit add-on |
| **User-and-rule-based aggregation (preview)** | Single-event alerts aggregated per user within a configurable 15-60 minute window at the tenant level | Same licensing floor as aggregate-event |

Auto-resolution/tagging rules match against **alert-level properties** (policy matched, rule matched, severity, sensitive information type detected, workload/location, sender/recipient) regardless of which alert type produced the alert — the rule engine doesn't care whether the alert was single-event or aggregate, only what the resulting alert record looks like.

### Deterministic rules vs. AI-assisted triage — don't conflate the two

<details><summary>Full comparison</summary>

| Capability | Core approach | Best suited to | Configuration surface |
|---|---|---|---|
| **Rule-based auto-resolution** | Deterministic, customer-defined logic (if alert matches X, close it) | Repetitive, approved, low-risk, already-understood cases | Purview portal, Alert rules |
| **Rule-based alert tagging** | Deterministic classification/routing | Departmental ownership, business-workflow categorization | Purview portal, Alert rules |
| **DLP Alert Triage Agent** (Security Copilot) | AI-assisted analysis on a Microsoft-managed schedule or on demand, over a configurable time range (new alerts through the prior 30 days) | Alerts that still require contextual interpretation | Security Copilot / Purview Alerts dashboard |
| **Human review** | Expert judgment | High-impact, ambiguous, novel, or sensitive cases | Purview Alerts dashboard / Defender XDR |

These four layers are complementary, not competing: a mature deployment uses auto-resolution to keep known-safe volume out of the queue entirely, tags to route the remainder to the right owner, the Triage Agent to help analysts interpret what's left, and human review for anything genuinely ambiguous or high-impact.

</details>

### Why auto-resolution is not the same as suppression

The roadmap's own framing distinguishes "alerts security teams do not need to see" from disabling detection. A DLP policy that matches a condition still fully evaluates and (if configured to) blocks, restricts, or warns on the content — auto-resolution changes only whether a human has to look at the resulting alert record. This matters for audit posture: the underlying policy match, action taken, and any user override/justification remain fully logged in Activity Explorer and the Office 365 Management Activity API regardless of how the alert itself was disposed.

---

## Dependency Stack

```
Tier 0 — Licensing
  [DLP-licensed SKU present] (any of E1/E3/E5/F1/G1/G3/G5)
        │
Tier 1 — Policy & Alert Generation
  [DLP policy: Enabled, Mode != TestWithoutNotifications-silent,
   rule configured to generate an alert]
        ├── Single-event alert config — available on the Tier 0 floor alone
        └── Aggregate/threshold alert config — requires A5, E5/G5, or an
              E1/F1/G1/E3/G3 tenant + (Defender for O365 Plan 2 OR
              Purview Suite OR eDiscovery & Audit add-on)
        │
Tier 2 — Alert Routing (both surfaces populated independently, same event)
  ├── [Microsoft Defender XDR incident queue] — 6-month retention,
  │     alerts grouped into correlated Incidents with other MDE/MDO signal
  └── [Purview DLP Alerts dashboard] — 30-day retention,
        source of truth for policy-authoring-adjacent alert management
        │
Tier 3 — RBAC Gate for Rule Authorship
  [Role group membership: "Manage alerts" role required, held via one of
   Compliance Administrator / Compliance Data Administrator / Security
   Administrator / Security Operator / Security Reader / Information
   Protection Admin / Information Protection Analyst / Information
   Protection Investigator]
        └── [DLP Compliance Management role — full rule CRUD]
              (or View-Only DLP Compliance Management — read-only)
        │
Tier 4 — Auto-Resolution & Tagging Rule Engine (Roadmap 568371)
  [Preview Aug 2026 → GA Sept 2026, Worldwide standard multi-tenant only]
        ├── Deterministic condition match against alert-level properties
        │     (policy, rule, severity, SIT, workload, sender/recipient)
        ├── Action: Auto-resolve (sets alert Status) and/or Apply tag(s)
        └── No PowerShell/Graph read or write surface as of this writing —
              portal-configured and portal-inspected only
```

A rule at Tier 4 can never compensate for a gap at Tier 0-2 — if aggregate alerting isn't licensed, there's nothing for a rule to act on beyond single-event alerts; if the RBAC gate at Tier 3 is too permissive, Tier 4 rules become a governance risk rather than a triage improvement (see Fix 2 in the companion `-B.md`).

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Alert rules page doesn't exist in the Purview portal | Tenant hasn't received the staged Sept 2026 GA rollout, or is on a non-Worldwide cloud environment | Confirm cloud environment + wait for rollout; no early-access switch exists |
| Rule exists, conditions look right, alert still untouched | Exact-match condition logic (domain/property mismatch), or <3 hrs propagation delay | Diagnosis Steps 3-4 in `-B.md` |
| Real alert was auto-resolved that shouldn't have been | Rule scoped too broadly — governance failure, not a product bug | Fix 2 in `-B.md` — widen/disable rule, re-open affected alerts |
| Analysts still overwhelmed despite active rules | Rules addressing volume but not ownership/routing — tagging strategy incomplete | Fix 3 in `-B.md` — tag-first phased rollout |
| Anyone in the tenant can create resolution rules | Manage alerts / DLP Compliance Management assigned too broadly | Fix 4 in `-B.md` — audit `Get-RoleGroupMember` |
| Alert visible in Defender XDR but "missing" from Purview dashboard (or vice versa) | Different retention windows — 6 months (Defender XDR) vs. 30 days (Purview dashboard) | Check the older surface first for anything >30 days old |
| Client conflates this feature with "AI auto-triage" | Confusing deterministic rules with the separate DLP Alert Triage Agent (Security Copilot) | See How It Works → comparison table |

---

## Validation Steps

1. **Confirm licensing floor.**
   ```powershell
   Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits
   ```
   *Good:* at least one DLP-licensed SKU present. *Bad:* no DLP-capable SKU — nothing downstream in this runbook applies.

2. **Confirm DLP policies are actively generating alerts.**
   ```powershell
   Connect-IPPSSession -UserPrincipalName <adminUPN>
   Get-DlpCompliancePolicy | Select-Object Name, Mode, Enabled
   Get-DlpComplianceRule | Select-Object Name, Policy, Disabled, GenerateAlert
   ```
   *Good:* one or more `Enabled` policies with rules that generate alerts. *Bad:* no active alerting policies — there is no alert population for a resolution/tagging rule to act on yet.

3. **Confirm RBAC scoping for rule authorship.**
   ```powershell
   Get-RoleGroupMember -Identity "DLP Compliance Management"
   ```
   *Good:* a small, named, documented set of owners. *Bad:* broad or stale membership — flag before any rule work begins.

4. **Confirm the feature surface is present** (portal-only — Purview → Data Loss Prevention → Alerts → Alert rules). *Good:* page loads and lists rules (possibly zero). *Bad:* page absent — rollout-timing gap, not a configuration issue.

5. **Spot-check one rule's real-world effect** against a recent, known alert (see `-B.md` Diagnosis Steps 2-3) before trusting the rule's broader scope.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the population.** Before troubleshooting a specific rule, confirm there's a real, repeatable alert pattern behind the request (Validation Steps 1-2). A one-off alert is not a rule candidate.

**Phase 2 — Confirm governance readiness.** Verify RBAC scope (Validation Step 3) and, for any *existing* rule under investigation, pull its documented business justification (see Remediation Playbook 1's template) before assuming a technical fault.

**Phase 3 — Reproduce against a specific alert.** Use `-B.md` Diagnosis Steps 2-4 to test one concrete alert against one concrete rule, accounting for the 3-hour propagation window.

**Phase 4 — Escalate only after ruling out timing and scope.** No cmdlet exists to inspect a rule's internal match logic beyond what the portal UI shows — a genuine engine-level fault requires a Microsoft support case with the Evidence Pack below attached.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Stand up a new auto-resolution rule safely</summary>

1. **Document before configuring.** Every rule should have a short decision record before it exists in the portal:
   - Policy/alert conditions involved
   - Why the activity is accepted (business rationale)
   - Approved external domains/partners/departments in scope
   - Responsible business owner
   - Approval date and mandatory review/expiration date
   - Conditions that must exclude a match from auto-resolution (see the "do-not-auto-resolve" list below)
2. **Build as tag-only first.** Run for at least one full triage cycle; manually validate that tagged alerts match the intended population before enabling auto-resolution.
3. **Convert to auto-resolution** only after tag-phase validation, and only for narrow, high-confidence, low-severity, well-governed cases.
4. **Maintain a standing "do-not-auto-resolve" exception list** — high-severity events, bulk transfers over a defined volume, privileged/regulated/export-controlled data, unusual device/location/identity signals, activity tied to an open insider-risk or security investigation, and matches involving a recently added or unreviewed partner should never be eligible for auto-resolution regardless of an otherwise-matching domain.

**Rollback:** disabling a rule is immediate, portal-only, and affects only future alert matches — it never retroactively changes already-resolved or already-tagged alerts (those require manual re-triage; see Playbook 2).

</details>

<details><summary>Playbook 2 — Recover from an over-broad rule that suppressed real risk</summary>

1. Disable or narrow the rule immediately (stops the bleeding; does not undo history).
2. Pull the resolved-alert history for the rule's active window:
   ```powershell
   Get-ProtectionAlert | Where-Object { $_.Status -eq "Resolved" -and $_.LastUpdatedTime -gt (Get-Date).AddDays(-30) } |
       Select-Object Name, Severity, Count, LastUpdatedTime
   ```
3. Manually re-triage every alert that falls inside the rule's scope and doesn't clearly meet the documented exception bar from Playbook 1.
4. Treat this as an incident-review item for the client, not just a config change — a rule that hid a real signal is a control failure.

**Rollback:** N/A — this playbook *is* the rollback/recovery path for Playbook 1 going wrong.

</details>

<details><summary>Playbook 3 — Quarterly rule health review</summary>

1. Export the current rule list from the portal (screenshot/manual — no API export exists).
2. For each rule, confirm the documented review/expiration date from Playbook 1 hasn't lapsed.
3. Cross-check each rule's scope against current business relationships (partner domains, departments) — a partner relationship that ended six months ago but still has an active auto-resolution rule is a silent risk.
4. Re-baseline alert volume (`Get-ProtectionAlert`) to confirm rules are still addressing a real, current pattern and haven't become dead configuration.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects DLP alert-operations context for a support case or client review.
.NOTES     Read-only. Does not read or modify auto-resolution/tagging rules themselves —
           no cmdlet surface exists for that as of this writing (portal-only).
#>
$ErrorActionPreference = "Stop"
$out = "DLPAlertOps_Evidence_$(Get-Date -Format yyyyMMdd_HHmmss).txt"

"=== DLP-licensed SKUs ===" | Out-File $out
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits | Out-File $out -Append

"`n=== Active DLP policies + alert config ===" | Out-File $out -Append
Get-DlpCompliancePolicy | Select-Object Name, Mode, Enabled | Out-File $out -Append
Get-DlpComplianceRule | Select-Object Name, Policy, Disabled, GenerateAlert | Out-File $out -Append

"`n=== Last 30 days of DLP alerts ===" | Out-File $out -Append
Get-ProtectionAlert | Where-Object { $_.AlertType -eq "DLP" -and $_.LastUpdatedTime -gt (Get-Date).AddDays(-30) } |
    Select-Object Name, Severity, Status, Count, LastUpdatedTime | Out-File $out -Append

"`n=== DLP Compliance Management role membership ===" | Out-File $out -Append
Get-RoleGroupMember -Identity "DLP Compliance Management" | Select-Object Name, RecipientType | Out-File $out -Append

Write-Host "Evidence written to $out"
```

---

## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Connect-IPPSSession` | Connect to Security & Compliance PowerShell (required for all DLP cmdlets below) |
| `Get-DlpCompliancePolicy` | List DLP policies and their Enabled/Mode state |
| `Get-DlpComplianceRule` | List rules and their alert-generation config |
| `Get-ProtectionAlert` | List generated DLP alerts, status, severity, recency |
| `Get-DlpDetailReport` | Detailed per-match report (policy, rule, SIT, action, user) |
| `Get-RoleGroupMember -Identity "DLP Compliance Management"` | Audit who can author auto-resolution/tagging rules |
| `Get-RoleGroupMember -Identity "Information Protection"` | Audit broader Information Protection role membership |
| `Get-MgSubscribedSku` | Confirm DLP/aggregate-alert licensing floor |
| *(portal only)* Data Loss Prevention → Alerts → Alert rules | Create/edit/inspect auto-resolution and tagging rules — no cmdlet equivalent |
| *(portal only)* DLP Alerts dashboard → alert details | Inspect an individual alert's matched policy/rule/severity/tags |

---

## 🎓 Learning Pointers

- This feature is Microsoft 365 Roadmap ID 568371 — always re-check the live roadmap entry before quoting a rollout date to a client, since Preview/GA dates for actively-shipping Purview features shift (see `PriorityCleanupHardDelete-A.md` for a documented example of a five-times-revised timeline in this same product area).
- The "trusted partner domain" auto-resolution pattern is the strongest documented use case, but domain trust is not static — build layered conditions (severity + recipient + data category + source group + workload) rather than a bare domain allowlist, and give every partner exception a named owner and review date.
- Purview's two alert surfaces have different retention: Defender XDR (6 months) vs. the Purview DLP Alerts dashboard (30 days). An alert that's "gone" from one may still be recoverable from the other.
- Don't let a tag substitute for severity. Purview alert severity, business-process tags, alert disposition, and any broader security-incident status are four independent fields — a "Business Process" tag should describe context, never override risk.
- Reference: [Get started with data loss prevention alerts](https://learn.microsoft.com/en-us/purview/dlp-alerts-get-started), [Learn about investigating data loss prevention alerts](https://learn.microsoft.com/en-us/purview/dlp-alert-investigation-learn), [Investigate data loss incidents with Microsoft Defender XDR](https://learn.microsoft.com/en-us/defender-xdr/dlp-investigate-alerts-defender).
