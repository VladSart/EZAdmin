# Microsoft Purview Compliance Manager — Hotfix Runbook (Mode B: Ops)
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

Compliance Manager is a **risk-assessment and scoring tool**, not an enforcement engine — it reads signal from other Purview features (and some Microsoft-managed control evidence) to compute a Compliance Score against assessment templates, but changing a score requires action in the *underlying* feature (a DLP policy, a retention label, a Conditional Access policy, etc.), never inside Compliance Manager itself. Most "my score won't move" tickets are actually "the underlying control isn't actually configured yet" tickets in disguise.

```powershell
# 1. Confirm the tenant has Compliance Manager assessments at all (portal-only resource, no direct Graph list-all cmdlet as of this writing — verify current Graph coverage)
# Purview portal → Compliance Manager → Assessments

# 2. Confirm licensing tier — Premium assessment templates require specific SKUs
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "E5|COMPLIANCE|EMSPREMIUM" } |
    Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits

# 3. Confirm the relevant improvement action's control family and current implementation status
# Purview portal → Compliance Manager → Improvement actions → filter by product/control family

# 4. For "Microsoft managed" actions, confirm you're not trying to action something Microsoft attests to directly
# Improvement action detail pane → "Managed by" column: Microsoft / Your organization / Shared

# 5. Confirm role assignment for the person expected to update action status/evidence
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<userObjectId>'" |
    Select-Object RoleDefinitionId
```

| Command / observation result | Interpretation | Do this |
|---|---|---|
| Score not moving after a policy was created in DLP/Retention/CA | Score refresh is not real-time — there's a sync/refresh lag, and some actions require explicit evidence upload rather than auto-detection | Fix 1 |
| Improvement action shows "Managed by: Microsoft" and client wants to mark it complete themselves | That control is attested to by Microsoft directly (e.g., physical datacenter controls) — customer action is not applicable | Fix 2 |
| Assessment template needed (e.g., a specific regulation) isn't available to select | Template requires a higher license tier, or the regulation template hasn't been added to the tenant's template library yet | Fix 3 |
| User can view Compliance Manager but can't update action status or upload evidence | Missing the Compliance Manager Contributor/Assessor role — Global Admin alone does not imply these roles | Fix 4 |
| Score dropped unexpectedly after no apparent tenant change | An underlying control's state changed (e.g., a DLP policy was disabled, a CA policy modified) — Compliance Manager reflects live state, it does not "remember" a prior manually-attested score indefinitely for automatically-tracked actions | Fix 5 |
| Custom assessment built from a regulation template needs org-specific control language | Default templates are Microsoft-authored baselines — customization is expected and supported, not a limitation to work around | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Purview compliance portal license (tier gates template/action availability)
    │  ← E5/E5 Compliance/EMS Premium unlock Premium assessment templates and more granular
    │     improvement actions; base tiers get a reduced template set
    ▼
Assessment (instantiated from a template — regulation, standard, or custom)
    │  ← templates are Microsoft-authored starting points; org-specific customization is expected
    ▼
Controls (grouped improvement actions mapped to the assessment's requirements)
    │  ← each control has a "Managed by" attribute: Microsoft / Your organization / Shared
    ▼
Improvement Actions (the actual unit of work)
    ├── Microsoft-managed  → Microsoft attests directly; customer action not applicable/possible
    ├── Customer-managed   → customer configures the underlying feature themselves
    └── Shared             → both parties have a role (e.g., encryption key management scenarios)
    │
    ▼
Underlying feature the action actually points to (DLP, Retention, Sensitivity Labels, Conditional
    Access, MFA, Insider Risk, Information Barriers, Device Compliance, etc. — Compliance Manager
    is a READ layer over these, never a direct configuration surface for them)
    │  ← changing the score means changing the underlying feature's config, not anything inside
    │     Compliance Manager itself
    ▼
Signal detection / evidence
    ├── Automated  → some actions auto-detect underlying config state (sync lag applies)
    └── Manual     → some actions require explicit evidence upload + an assessor's manual sign-off
    ▼
Compliance Score (points-weighted, recalculated on a refresh cycle — not instant)
    ▼
Role-gated visibility/action:
    Compliance Manager Reader   → view only
    Compliance Manager Contributor → update action status, add evidence, comments
    Compliance Manager Assessor    → same as Contributor + submit for review
    Compliance Manager Administrator → template management, full control
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm which improvement action is in question, and its "Managed by" attribute first.**
   - Purview portal → Compliance Manager → Improvement actions → open the specific action → check the "Managed by" field.
   - Good: `Your organization` or `Shared` — customer action is expected and possible.
   - Bad: `Microsoft` and the client is trying to action it → this is expected friction, not a bug. Go to Fix 2.

2. **Confirm the underlying feature is actually configured, not just assumed to be.**
   - Cross-reference the action's description against the actual feature state (e.g., "DLP policy enforcing X" → check `Get-DlpCompliancePolicy` actually shows that policy `Enabled` and in the right mode, not just `TestWithoutNotifications`).
   - Good: underlying config matches what the action expects.
   - Bad: config missing, disabled, or in test/simulation mode → the action was likely marked complete prematurely, or the underlying feature needs actual remediation. This is a `Security/Purview/DLP-Policy-A.md`/other-topic-file handoff, not a Compliance Manager fix.

3. **Confirm licensing tier if a needed template or action isn't visible.**
   ```powershell
   Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "E5|COMPLIANCE|EMSPREMIUM" }
   ```
   - Good: an E5/Compliance-tier SKU present with available (unconsumed) units.
   - Bad: only base-tier SKUs → template/action availability gap is licensing, not configuration. Go to Fix 3.

4. **Confirm the affected user's Compliance Manager role, not just their admin role generally.**
   - Purview portal → Roles & scopes → Compliance Manager roles (a distinct role group from the broader Microsoft Purview role groups).
   - Good: user is in Compliance Manager Contributor, Assessor, or Administrator (per the action they're trying to perform).
   - Bad: user only has Global Reader, or a role from an unrelated workload → Fix 4.

5. **If the score dropped with no apparent change, check for a genuine underlying drift before assuming a Compliance Manager bug.**
   - Check recent changes to the specific policy/feature the dropped action maps to (audit log search via `Security/Purview/Audit-A.md`/`Audit-B.md` techniques) — a disabled policy, an expired certificate, or a modified CA policy are common real causes.
   - Good: a genuine, explainable underlying change is found.
   - Bad: nothing found after a reasonable search → escalate as a genuine scoring anomaly rather than continuing to search indefinitely.

---
## Common Fix Paths

<details><summary>Fix 1 — Score not reflecting a recently completed action</summary>

**When to use:** An underlying control (DLP policy, retention label, CA policy, etc.) was genuinely configured correctly, but the Compliance Score hasn't updated.

1. Confirm the improvement action's detection method — automated actions have a documented refresh cycle (historically up to 24 hours for some signal types; always confirm current cycle timing against Microsoft Learn rather than quoting a fixed number from memory) before assuming a fault.
2. For manually-tracked actions, confirm someone actually updated the action's status in the portal (Testing/Implemented/Not implemented) and, where required, attached evidence — automated detection does not apply to every action type, and leaving status at its default does not auto-update just because the underlying feature changed.
3. If well past the expected refresh window, open the action and manually re-save its status to force a re-evaluation, then re-check after the normal refresh interval.

**Rollback:** N/A — status/evidence updates are additive documentation, not destructive.

</details>

<details><summary>Fix 2 — Client wants to action a Microsoft-managed control</summary>

**When to use:** The improvement action's "Managed by" field shows `Microsoft`, and the client wants to mark it complete or believes it's blocking their score unfairly.

1. Explain that Microsoft-managed actions represent controls Microsoft implements and attests to directly (e.g., datacenter physical security, platform-level encryption at rest) — these already contribute their full point value to the score based on Microsoft's own attestation, with no customer action possible or required.
2. If the score still appears lower than expected despite this, re-check whether the *points* for that action are actually being counted — this is a portal-display question, not a configuration gap, and may warrant a support ticket if the score math genuinely looks wrong rather than a "how do I complete this" question.

**Rollback:** N/A — no action is taken; this is a client-education fix.

</details>

<details><summary>Fix 3 — Needed assessment template or action isn't available</summary>

**When to use:** A specific regulation/standard template, or a specific improvement action's full detail, isn't showing up as expected.

1. Confirm current licensing tier against Microsoft's published Compliance Manager feature-by-license comparison — Premium assessments and some improvement action detail require E5-tier compliance licensing, not just any E5 SKU generally.
2. If licensing is confirmed adequate, confirm the template has actually been added from the template library to the tenant's active assessments list — templates exist in a library separate from "currently assessed" status, and simply having license access doesn't auto-instantiate every available template.
3. If a needed regulation template genuinely doesn't exist in the library, note this as a product-coverage gap for the client (Microsoft periodically adds new templates) rather than assuming a configuration mistake on the tenant side.

**Rollback:** N/A — informational/licensing fix.

</details>

<details><summary>Fix 4 — User can't update action status or evidence</summary>

**When to use:** User has general admin access but can't interact with Compliance Manager improvement actions as expected.

1. Assign the appropriate Compliance Manager role — these are distinct from the broader Microsoft Purview role groups and from Entra ID directory roles:
   - Purview portal → Roles & scopes → Compliance Manager roles → assign **Compliance Manager Contributor** (update status/evidence) or **Compliance Manager Assessor** (Contributor + submit for review) as appropriate.
2. Confirm the user isn't scoped out by an Administrative Unit or role-scoping configuration if the tenant uses scoped role assignments.
3. Have the user sign out/in or wait for role propagation (typically well under an hour) before re-testing.

**Rollback:** Remove the assigned Compliance Manager role via the same Roles & scopes page if access was granted in error.

</details>

<details><summary>Fix 5 — Score dropped unexpectedly, genuine drift confirmed</summary>

**When to use:** Diagnosis step 5 confirmed a real underlying change caused the drop (e.g., a DLP policy was disabled, a CA policy modified, a certificate expired).

1. Remediate the underlying feature directly — this is a handoff to the relevant runbook (`Security/Purview/DLP-Policy-B.md`, `Security/ConditionalAccess/CA-Troubleshooting-B.md`, etc.), not a Compliance Manager-specific fix.
2. After remediation, re-check the action's status in Compliance Manager once the normal refresh cycle has elapsed rather than expecting instant reflection.
3. Document the root cause and the date/change in the client's compliance record — audit trail matters for compliance-focused engagements more than for typical IT tickets.

**Rollback:** N/A — this is a diagnostic handoff to another runbook's fix path.

</details>

<details><summary>Fix 6 — Need org-specific control language on a default template</summary>

**When to use:** A regulation template's default improvement actions don't match the client's actual internal control language/process, and they want to track their own wording.

1. Use **Create custom assessment** (or clone an existing one, where supported) rather than editing the Microsoft-authored template directly — default templates are not meant to be edited in place.
2. Add custom controls/improvement actions with the org's own language while keeping the underlying score-contributing mapping to Microsoft's control families where possible, so scoring stays meaningful.
3. Document that custom assessments are the client's own to maintain — Microsoft does not update custom control language when the source regulation's baseline template changes; someone needs to own re-syncing periodically.

**Rollback:** Custom assessments/controls can be deleted independently of the source template they were cloned from.

</details>

---
## Escalation Evidence

```
=== Compliance Manager Escalation ===
Ticket #:
Client / Tenant:
Assessment name / template:
Affected improvement action:              Managed by: [ ] Microsoft  [ ] Your organization  [ ] Shared
Underlying feature involved:               (DLP / Retention / CA / MFA / Insider Risk / other)
Underlying feature confirmed configured correctly (Y/N):
Current score vs. expected score:
User's Compliance Manager role:
Licensing tier confirmed (Y/N):
When did the discrepancy start:
What changed (client-reported):
Impact (audit/regulatory deadline, if any):
Escalation target:                        [ ] Microsoft Support   [ ] Internal L3   [ ] Underlying-feature owner
```

---
## 🎓 Learning Pointers

- **Compliance Manager is a read/scoring layer, never a direct configuration surface.** Every fix for a dropped or stalled score ultimately lands in a different Purview/Entra feature's own runbook — treat "my Compliance Score won't move" as a routing question first, not a Compliance-Manager-specific bug hunt. See [Microsoft Purview Compliance Manager overview](https://learn.microsoft.com/en-us/purview/compliance-manager).

- **The "Managed by" attribute (Microsoft/Your organization/Shared) on each improvement action determines who can even act on it.** Explaining this distinction upfront avoids a lot of wasted client-side troubleshooting on actions that were never actionable from their side. See [Improvement actions](https://learn.microsoft.com/en-us/purview/compliance-manager-improvement-actions).

- **Score refresh is not instant** — automated detection has a documented (and evolving) refresh cycle, and some actions require explicit manual status/evidence updates that don't happen automatically no matter how correctly the underlying feature is configured. Confirm current refresh timing against Microsoft Learn rather than quoting from memory. See [Compliance score calculation](https://learn.microsoft.com/en-us/purview/compliance-manager-scoring).

- **Compliance Manager roles are a distinct role group from both Entra ID directory roles and the broader Microsoft Purview role groups.** A Global Administrator does not automatically get Compliance Manager Contributor/Assessor access — this is a common access-request miss. See [Compliance Manager roles and permissions](https://learn.microsoft.com/en-us/purview/compliance-manager-setup#permissions).

- **Default assessment templates are Microsoft-authored baselines, not editable in place.** Org-specific control language belongs in a custom assessment (created or cloned), and someone on the client side needs to own re-syncing it as the source regulation's template evolves — Microsoft does not do this automatically for custom copies.
