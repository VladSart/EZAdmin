# Microsoft Purview Compliance Manager — Reference Runbook (Mode A: Deep Dive)
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
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

Covers **Microsoft Purview Compliance Manager**: the assessment/template/control/improvement-action model, the Compliance Score calculation and its point-weighting, the "Managed by" (Microsoft/Your organization/Shared) responsibility split, Compliance Manager's own distinct role group, custom assessment authoring, and how the tool relates to (but never directly configures) the underlying Purview and Entra features it scores.

Distinct from every other file in this folder: Compliance Manager does not enforce anything itself — it is a **risk-assessment and posture-scoring layer** that reads state from DLP (`DLP-Policy-A.md`), Retention Labels (`RetentionLabels-A.md`), Insider Risk (`Insider-Risk-A.md`), Sensitivity Labels (`Sensitivity-Labels-A.md`), Priva (`Priva-A.md`), Audit (`Audit-A.md`), and Entra features like Conditional Access and MFA outside this folder entirely. Also distinct from **Secure Score** (`Security/Defender/SecureScore-A.md`) — Secure Score is Microsoft Defender's security-posture scoring engine focused on identity/device/app security signals; Compliance Manager is Purview's regulatory/compliance-posture scoring engine focused on assessment templates mapped to named regulations and standards. The two tools score different things, using different point systems, and a client asking "why don't my scores match" is asking a category-error question worth correcting directly.

Does **not** cover: the configuration mechanics of any underlying feature an improvement action points to (each has its own dedicated runbook in this repo), Microsoft 365 Secure Score (see `Security/Defender/SecureScore-A.md`), or Priva's Privacy Risk Management assessments specifically (Priva has its own risk-management surface — see `Priva-A.md` — though some Priva-related improvement actions can appear inside a broader Compliance Manager assessment).

---
## How It Works

<details><summary>Full architecture</summary>

**Assessments are instantiated from templates.** Microsoft publishes a library of assessment templates mapped to named regulations, standards, and frameworks (e.g., data protection regulations, industry-specific standards, internal Microsoft-recommended baselines). An organization selects which templates to instantiate as active assessments — instantiating a template does not itself change any tenant configuration; it only creates a tracking/scoring structure. Template availability is licensing-gated: base compliance licensing exposes a reduced template set, while E5/Compliance-tier licensing unlocks the full Premium template library and more granular improvement-action detail.

**Controls group related improvement actions.** Each assessment is broken into controls (requirements grouped by theme — e.g., "data loss prevention," "access control"), and each control contains one or more improvement actions — the actual, atomic unit of work Compliance Manager tracks.

**The "Managed by" split is the single most important architectural fact for troubleshooting.** Every improvement action carries a `Managed by` attribute:

- **Microsoft-managed** — Microsoft implements and directly attests to the control (e.g., physical datacenter security, platform-level encryption-at-rest defaults). These contribute their full point value based on Microsoft's own ongoing attestation. Customers cannot action these, and should not expect a manual completion option.
- **Customer-managed** — the customer must configure the underlying feature themselves (e.g., "implement a DLP policy restricting X"). This is the majority of improvement actions in most assessments.
- **Shared** — responsibility is split between Microsoft and the customer (common in scenarios like encryption key management, where Microsoft provides the platform capability but the customer must actually configure/use it).

A client believing their score is "stuck" on a Microsoft-managed action is not experiencing a bug — that action was never theirs to complete, and its points are already counted based on Microsoft's platform-level attestation.

**Detection is either automated or manual, and this determines refresh behavior.** Some improvement actions have automated signal detection — Compliance Manager periodically checks the actual configuration state of the underlying feature (e.g., whether a specific DLP policy exists and is enabled) and updates the action's implementation status accordingly, on a refresh cycle (verify current cycle timing against Microsoft Learn — this has been refined over the product's history and should not be quoted from memory as a fixed SLA). Other actions require the assessor to manually update status (Not implemented / Implemented / Testing / Alternative implementation) and optionally attach evidence — for these, no amount of correctly configuring the underlying feature will move the score until a human updates the action's tracked status in the portal.

**Compliance Score is a weighted point calculation, not a simple percentage of actions completed.** Each improvement action carries a point value reflecting its relative risk-reduction importance within the assessment/regulation it belongs to — a small number of high-value actions can move the score more than a larger number of low-value ones. This is why "we completed most of our action list but the score barely moved" is a legitimate, explainable outcome rather than a scoring bug — the remaining actions may simply carry more weight.

**Compliance Manager's role model is distinct from both Entra ID directory roles and the broader Purview compliance portal role groups.** A Global Administrator or even a broad Purview "Compliance Administrator" role does not automatically grant Compliance Manager's own permissions. The dedicated Compliance Manager roles are: **Reader** (view only), **Contributor** (update action status, add comments/evidence), **Assessor** (Contributor plus the ability to submit an action for review/certification), and **Administrator** (full control including template/assessment management). This granular separation exists because compliance assessment work is often owned by a governance/risk/compliance (GRC) function distinct from IT administration, and Microsoft's role model reflects that organizational reality.

**Custom assessments extend, rather than replace, the template model.** An organization can clone a Microsoft template (or build from scratch) to add org-specific control language, additional internal controls not covered by any regulation template, or modified improvement-action descriptions matching internal process documentation. Crucially, custom assessments do not automatically stay in sync with updates Microsoft makes to the source template over time — this is a standing maintenance responsibility that's easy to overlook until an audit surfaces stale control language.

</details>

---
## Dependency Stack

```
Layer 0 — Licensing
    Compliance-tier SKU (E5/Compliance/EMS Premium) — gates Premium template + action availability
    │
    ▼
Layer 1 — Assessment Templates (Microsoft-authored library)
    Instantiated → Active Assessment (org-scoped, does NOT itself change tenant config)
    │
    ▼
Layer 2 — Controls (thematic grouping within an assessment)
    │
    ▼
Layer 3 — Improvement Actions (atomic unit of work)
    ├── Managed by: Microsoft   → Microsoft attests directly, no customer action possible
    ├── Managed by: Customer    → customer must configure the underlying feature
    └── Managed by: Shared      → both parties have a role
    │
    ▼
Layer 4 — Underlying Feature (the ACTUAL system of record for the control)
    DLP | Retention Labels | Sensitivity Labels | Insider Risk | Priva | Audit |
    Conditional Access | MFA | Device Compliance (Intune) | Information Barriers | etc.
    │  ← Compliance Manager NEVER configures these directly — it only reads their state
    ▼
Layer 5 — Detection / Status
    ├── Automated  → periodic signal check against underlying feature state (refresh-cycle bound)
    └── Manual     → assessor-updated status + optional evidence upload (no auto-detection)
    ▼
Layer 6 — Scoring
    Point-weighted calculation per action → rolled up per control → rolled up per assessment
    → overall Compliance Score
    │
    ▼
Layer 7 — Access Control
    Compliance Manager Reader / Contributor / Assessor / Administrator
    (distinct role group — NOT inherited from Entra directory roles or broader Purview roles)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Score unchanged after configuring the underlying feature correctly | Refresh-cycle lag (automated actions), or the action requires manual status update (not all actions auto-detect) | Action detail pane — detection method; time since config change vs. documented refresh cycle |
| Action shows "Managed by: Microsoft," client wants to complete it | Not a customer-actionable control by design — already counted via Microsoft's attestation | Action's "Managed by" field |
| Needed regulation template not selectable | License tier doesn't include it, or template not yet added to tenant's assessment list | `Get-MgSubscribedSku`; Purview portal template library vs. active assessments |
| Score dropped with no apparent tenant change | Underlying feature's config genuinely changed (policy disabled, cert expired, CA policy modified) | Audit log search on the specific underlying feature (`Audit-A.md` technique) |
| Completed most actions, score barely moved | Point-weighting — remaining actions carry disproportionate risk-reduction weight | Compare point values of completed vs. remaining actions in the assessment detail |
| User with Global Admin can't update action status | Compliance Manager role group is separate from directory roles | Roles & scopes → Compliance Manager roles for that user |
| Custom assessment's control language is stale vs. current regulation guidance | Custom assessments don't auto-sync with source template updates — a standing maintenance gap | Compare custom assessment controls against the current Microsoft-authored template version |
| Two different scoring numbers being compared (Compliance Score vs. Secure Score) | Category error — different tools, different signal domains, different point systems | Confirm which tool's score is actually being discussed before troubleshooting either |
| Evidence uploaded but action still shows "Not implemented" | Evidence upload alone doesn't change status — an assessor must also update the status field, and for some actions, submit for review/certification | Action detail — status field vs. attached evidence list |
| Assessment exists but shows 0% complete despite real remediation work done elsewhere in the tenant | Work was done in the underlying feature before the assessment/action was ever instantiated, and automated detection only evaluates current state going forward for some action types — verify current behavior rather than assuming full retroactive credit | Action detail — last detection timestamp vs. when remediation actually occurred |

---
## Validation Steps

1. **Confirm licensing tier supports the template/action in question.**
   ```powershell
   Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "E5|COMPLIANCE|EMSPREMIUM" } | Select SkuPartNumber, ConsumedUnits, PrepaidUnits
   ```
   Good: adequate SKU present with available units. Bad: only base tier → template/action gap is licensing.

2. **Confirm the specific improvement action's "Managed by" attribute before troubleshooting further.**
   Purview portal → Compliance Manager → Improvement actions → open the action → check "Managed by."
   Good: `Your organization` or `Shared` for anything the client expects to action themselves.

3. **Confirm the underlying feature's actual live configuration state, not the client's belief about it.**
   Cross-reference against the relevant feature's own runbook validation steps (e.g., `DLP-Policy-A.md` Validation Steps for a DLP-mapped action).
   Good: live config matches what the action's description expects. Bad: mismatch → this is the real root cause, not Compliance Manager.

4. **Confirm detection method (automated vs. manual) for the specific action.**
   Action detail pane shows whether Compliance Manager auto-detects this action's state.
   Good: understood before troubleshooting a "why hasn't it updated" complaint. Bad: assuming all actions auto-detect leads to wasted time waiting for a refresh that will never come for a manual-only action.

5. **Confirm the user's Compliance Manager role, separate from any Entra/Purview admin role they already hold.**
   Roles & scopes → Compliance Manager roles.
   Good: Contributor/Assessor/Administrator as appropriate for the task. Bad: role missing despite broad admin access elsewhere.

6. **For a score drop, confirm a genuine underlying change via audit log rather than assuming Compliance Manager error.**
   Use `Search-UnifiedAuditLog` (see `Audit-A.md`) scoped to the underlying feature and the approximate time window of the score drop.
   Good: a specific, dated change is found. Bad: nothing found after reasonable search → escalate as a genuine anomaly.

7. **For custom assessments, confirm currency against the source template.**
   Compare the custom assessment's control list/language against the current version of the Microsoft-authored template it was cloned from.
   Good: recently reviewed and aligned. Bad: stale, especially ahead of an audit — flag for the client's GRC owner.

---
## Troubleshooting Steps (by phase)

### Phase 1: Categorize the complaint
Determine whether this is a scoring-mechanics question (why is the number what it is), an access question (who can do what), a licensing question (why isn't X available), or a genuine underlying-feature configuration problem wearing a Compliance Manager label. Most tickets are the last category.

### Phase 2: Isolate to the specific action
Never troubleshoot "the score" in the abstract — identify the specific improvement action(s) driving the concern and check each one's "Managed by" and detection-method attributes first.

### Phase 3: Route to the underlying feature if customer-managed
If the action is customer-managed and the underlying feature isn't correctly configured, hand off to that feature's own runbook (DLP, Retention, CA, MFA, Insider Risk, Information Barriers, Priva, Audit) rather than continuing to troubleshoot inside Compliance Manager.

### Phase 4: Confirm refresh timing expectations
Before escalating a "score not updating" ticket, confirm current documented refresh-cycle timing for the specific action's detection method — don't let a client compare against an internet forum post quoting an old cycle time.

### Phase 5: Confirm role/access if the complaint is "I can't update this"
Check Compliance Manager's own role group assignment, independent of whatever other admin access the user holds.

### Phase 6: Escalate genuine anomalies
If licensing, underlying config, detection method, and role are all confirmed correct and the score still doesn't reflect reality, this is a genuine platform anomaly worth a Microsoft support case with the specific assessment/action IDs documented.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Stand up a new assessment for a client (greenfield)</summary>

1. Confirm licensing tier supports the needed template(s) before promising specific regulation coverage.
2. Instantiate the relevant template(s) from the library — this creates the tracking structure only, no tenant config changes yet.
3. Review each control's improvement actions, and pre-sort by "Managed by" so the client understands upfront what's theirs to action vs. already covered by Microsoft.
4. For customer-managed actions, cross-reference against the tenant's actual current configuration (many organizations already have partial coverage before ever opening Compliance Manager) before assuming a blank slate.
5. Assign Compliance Manager roles to the right people (often a GRC/compliance function, not general IT admins) — don't assume Global Admin access is sufficient.
6. Set a recurring review cadence (quarterly is common for regulated clients) rather than treating the initial setup as a one-time project.

**Rollback:** Deleting an assessment removes its tracking structure only — it does not undo any underlying feature configuration that was completed as part of remediation work.

</details>

<details><summary>Playbook 2 — Investigate a genuine unexplained score drop</summary>

1. Identify exactly which action(s)/control(s) dropped in points, and by how much, using the assessment's history/trend view if available.
2. For each dropped action, confirm detection method (automated vs. manual) — a manual action's score can only "drop" if someone changed its status, which narrows the investigation considerably.
3. For automated actions, audit-log-search the underlying feature around the approximate drop window.
4. Document findings in the client's compliance record, including root cause and remediation date — this matters for audit trail purposes specific to compliance-focused engagements.
5. If genuinely unexplained after thorough investigation, open a Microsoft support case with the assessment ID, action ID, and timeline rather than continuing to investigate indefinitely.

**Rollback:** N/A — investigative playbook.

</details>

<details><summary>Playbook 3 — Build and maintain a custom assessment</summary>

1. Clone the closest Microsoft-authored template as a starting point rather than building entirely from scratch, to retain useful score-contributing mappings to Microsoft's control families.
2. Add org-specific controls/actions with internal process language, clearly distinguishing them from the inherited Microsoft-authored ones for future maintainers.
3. Establish an explicit owner (typically the client's GRC/compliance lead, not IT) responsible for periodically re-comparing the custom assessment against the current version of the source template.
4. Document the review cadence and last-reviewed date directly in the assessment's description or an accompanying internal doc, since Compliance Manager itself doesn't track "staleness vs. source template" automatically.

**Rollback:** Custom assessments and their controls can be deleted independently without affecting the source template or any other assessment.

</details>

<details><summary>Playbook 4 — Correct a client's category error (Compliance Score vs. Secure Score)</summary>

1. Confirm which specific score the client is looking at — screenshots are often ambiguous between the two tools, especially since both live under similarly-named Microsoft security/compliance portals.
2. Explain plainly: Secure Score (`Security/Defender/SecureScore-A.md`) measures security posture (identity, device, app protection signals) via Microsoft Defender; Compliance Score measures regulatory/standard alignment via Purview Compliance Manager assessments. They use different point systems and will not match.
3. If the client's actual goal is regulatory alignment, ensure they're looking at Compliance Manager; if it's general security hygiene, Secure Score is the right tool — don't try to reconcile the two numbers.

**Rollback:** N/A — clarification, not a configuration change.

</details>

---
## Evidence Pack

```
Compliance Manager evidence collection is primarily portal-based (assessment/action detail, history,
and evidence attachments aren't fully exposed via a single automatable cmdlet as of this writing —
verify current Graph API coverage before assuming full parity with the portal). For an escalation packet, capture:

1. Assessment name, template source, and current overall score (Purview portal → Compliance Manager → Assessments)
2. The specific improvement action(s) in question: name, "Managed by" value, detection method, current status,
   points value, and last-updated timestamp (action detail pane)
3. Underlying feature's current live configuration state, using that feature's own evidence-pack script/commands
   (e.g., Get-DlpCompliancePolicy output for a DLP-mapped action)
4. Relevant audit log entries for the underlying feature around the time of any unexplained score change
   (Search-UnifiedAuditLog — see Audit-A.md Evidence Pack for the full collection script)
5. Compliance Manager role assignment for the affected user (Roles & scopes → Compliance Manager roles)
6. Licensing confirmation:
   Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "E5|COMPLIANCE|EMSPREMIUM" } |
       Select SkuPartNumber, ConsumedUnits, PrepaidUnits | Export-Csv .\ComplianceManager-License-Evidence.csv -NoTypeInformation
```

---
## Command Cheat Sheet

| Task | Command / Location |
|---|---|
| Compliance-tier licensing check | `Get-MgSubscribedSku \| Where-Object { $_.SkuPartNumber -match "E5\|COMPLIANCE\|EMSPREMIUM" }` |
| Assessment list | Purview portal → Compliance Manager → Assessments |
| Improvement action detail (Managed by, detection method, status, points) | Purview portal → Compliance Manager → Improvement actions → open action |
| Compliance Manager role assignment | Purview portal → Roles & scopes → Compliance Manager roles |
| Audit log search for underlying feature changes | `Search-UnifiedAuditLog -StartDate <date> -EndDate <date> -RecordType <workload>` (see `Audit-A.md`) |
| DLP policy live state (example underlying-feature check) | `Get-DlpCompliancePolicy \| Select Name, Enabled, Mode` |
| Retention label live state (example underlying-feature check) | `Get-RetentionCompliancePolicy \| Select Name, Enabled` |
| Conditional Access policy live state (example underlying-feature check) | `Get-MgIdentityConditionalAccessPolicy \| Select DisplayName, State` |
| Score/action trend history | Purview portal → Compliance Manager → assessment → History tab (if available for the assessment) |
| Clone a template into a custom assessment | Purview portal → Compliance Manager → Assessment templates → select template → Create assessment (custom) |

---
## 🎓 Learning Pointers

- **Compliance Manager is architecturally a read/scoring layer over other Purview and Entra features — it never directly configures anything.** Internalizing this reframes almost every "Compliance Manager isn't working" ticket as "which underlying feature actually needs attention." See [Microsoft Purview Compliance Manager overview](https://learn.microsoft.com/en-us/purview/compliance-manager).

- **The "Managed by" attribute is the fastest triage signal on any action-specific ticket** — Microsoft-managed actions are not customer-actionable by design, and recognizing this immediately prevents a lot of wasted troubleshooting on controls that were never meant to be touched by the tenant. See [Improvement actions in Compliance Manager](https://learn.microsoft.com/en-us/purview/compliance-manager-improvement-actions).

- **Compliance Score is point-weighted, not a simple completed/total percentage** — a client who's completed "most" of their action list can legitimately still have a modest score if the remaining actions carry disproportionate weight. Explain this before a client assumes the tool is broken. See [How Compliance Manager calculates your score](https://learn.microsoft.com/en-us/purview/compliance-manager-scoring).

- **Compliance Manager's role group is fully separate from Entra ID directory roles and the broader Microsoft Purview compliance portal role groups.** A Global Administrator does not inherit Compliance Manager Contributor/Assessor access — this is one of the most common "why can't I edit this" tickets in the whole Purview suite. See [Compliance Manager permissions](https://learn.microsoft.com/en-us/purview/compliance-manager-setup#permissions).

- **Compliance Score and Microsoft Secure Score are different tools measuring different things with different point systems** — conflating them wastes troubleshooting effort trying to reconcile numbers that were never meant to match. Confirm which score a client is actually asking about before doing anything else. See [Microsoft Secure Score](https://learn.microsoft.com/en-us/microsoft-365/security/defender/microsoft-secure-score) and compare directly against the Compliance Manager scoring doc above.

- **Custom assessments do not automatically stay synchronized with updates to their source Microsoft-authored template.** This is a standing, easy-to-overlook maintenance responsibility — assign an explicit owner and review cadence at creation time, not after an audit surfaces stale control language.
