# DLP Alert Auto-Resolution & Tagging — Hotfix Runbook (Mode B: Ops)
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

## Triage

Run these within the first 60 seconds to classify the problem. Auto-resolution and tagging *rules themselves* are configured in the Microsoft Purview portal (Data Loss Prevention > Alerts > Auto-resolution and tagging rules — no PowerShell/Graph cmdlet surface exists as of this writing), so triage leans on the adjacent, scriptable signals: alert volume, licensing, and role assignment.

```powershell
# Connect to Security & Compliance PowerShell
Connect-IPPSSession -UserPrincipalName <adminUPN>

# 1. Recent DLP alert volume and status — is there actually a noise problem, or a missing-resolution problem?
Get-ProtectionAlert | Where-Object { $_.AlertType -eq "DLP" -and $_.LastUpdatedTime -gt (Get-Date).AddDays(-7) } |
    Select-Object Name, Severity, Status, Count, LastUpdatedTime | Sort-Object LastUpdatedTime -Descending |
    Format-Table -AutoSize

# 2. Who can even see or configure alert rules? (Manage alerts + DLP Compliance Management)
Get-RoleGroupMember -Identity "DLP Compliance Management" | Select-Object Name, RecipientType
Get-RoleGroupMember -Identity "Information Protection" | Select-Object Name, RecipientType

# 3. Which DLP policies are generating the alert volume in question?
Get-DlpDetailReport -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) -PageSize 100 |
    Group-Object Policy | Sort-Object Count -Descending | Select-Object Name, Count

# 4. Tenant licensing signal for aggregate-alert configuration (needed for threshold-based rules, not a hard
#    requirement for auto-resolution/tagging itself, but a good proxy for which alert model a tenant is on)
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "SPE_E5|ENTERPRISEPREMIUM|IDENTITY_THREAT_PROTECTION|M365_E5_SUITE_COMPONENTS" } |
    Select-Object SkuPartNumber, PrepaidUnits, ConsumedUnits
```

**Interpretation:**

| Result | Meaning | Next step |
|--------|---------|-----------|
| High alert count, one or two policies dominate | Good auto-resolution/tagging candidate — narrow, high-volume, likely-repetitive source | Go to Fix 1 |
| Alert count is low but analysts still complain about noise | Not a volume problem — likely a triage/ownership problem | Go to Fix 3 (tag-first approach) before touching auto-resolution |
| `Get-RoleGroupMember` returns nobody with legitimate business need | RBAC gap — anyone who *can* create a rule may not be who *should* | Go to Fix 4 before building any rules |
| Feature not visible in Purview portal at all | Tenant hasn't received the Sept 2026 GA rollout yet, or is on a cloud environment outside Worldwide standard multi-tenant (GCC/GCC High/DoD timing is separate and typically later) | Go to Fix 5 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
[Microsoft Purview DLP subscription] (E1/E3/E5/F1/G1/G3/G5 — any DLP-licensed tier)
        └── [DLP policy exists, is Enabled, and its rule(s) generate alerts]
              │       (single-event alerts: available on ANY DLP-licensed tier;
              │        aggregate/threshold alerts: require A5, E5/G5, or an E1/F1/G1/E3/G3
              │        tenant with Defender for Office 365 Plan 2, Purview Suite, or the
              │        eDiscovery & Audit add-on)
              └── [Alerts flow to BOTH surfaces independently]
                    ├── [Microsoft Defender XDR incident queue] — 6-month retention,
                    │     Microsoft's recommended surface for triage/investigation
                    └── [Purview DLP Alerts dashboard] — 30-day retention,
                          Microsoft's recommended surface for policy authoring
                                └── [Auto-resolution & tagging rules] (Roadmap 568371 —
                                      Preview Aug 2026, GA Sept 2026, Worldwide standard
                                      multi-tenant cloud, Purview portal only)
                                      ├── requires the "Manage alerts" role
                                      └── requires DLP Compliance Management (or
                                            View-Only DLP Compliance Management for
                                            read-only visibility into existing rules)
```

A rule created here acts on the **alert record**, after the underlying DLP policy has already evaluated and acted on the content. It never changes what the DLP policy itself detects or blocks — those two layers are independent, and confusing them is the single most common misconfiguration (see Fix 2).

</details>

---

## Diagnosis & Validation Flow

1. **Confirm the feature is actually present in this tenant.**
   In the Purview portal: **Data Loss Prevention → Alerts → Alert rules** (naming may read "Auto-resolution and tagging rules" depending on rollout wave). If absent, the tenant hasn't yet received the staged Sept 2026 GA rollout — there is no tenant-level opt-in cmdlet to force it early.
   *Good:* the rules page is visible and lists zero or more rules.
   *Bad:* no such page exists under Alerts — this is a rollout-timing issue, not a misconfiguration. Escalate only if the client's contract/SLA requires the feature by a specific date; otherwise, note and revisit.

2. **Reproduce with a known alert.**
   Pick a specific alert from `Get-ProtectionAlert` (Triage step 1) that the client says *should have* been auto-resolved or tagged. Open it in the Purview Alerts dashboard and check its current Status and any Tags field.
   *Good:* alert shows the expected tag or a Resolved status matching an existing rule's stated scope.
   *Bad:* alert is untouched — proceed to step 3.

3. **Check rule conditions against the actual alert's properties.**
   Auto-resolution and tagging rules match on alert-level properties (policy, rule, severity, sender/recipient domain, workload) — the same property set documented for DLP alert events (policy matched, rule matched, SIT detected, severity, workload). Compare the rule's defined conditions in the portal against the specific alert's own **Alert details** pane.
   *Good:* a clear mismatch is found (e.g., rule scoped to `partner-a.com`, alert recipient is `partner-b.com`).
   *Bad:* conditions appear to match and the alert is still untouched — this is a timing issue (step 4) or a genuine product gap to escalate.

4. **Account for propagation delay.**
   Microsoft's documented DLP alert-configuration latency is up to 3 hours for *policy* alert-configuration changes to take effect; treat newly created or edited auto-resolution/tagging rules with the same expectation until Microsoft publishes rule-specific timing. Re-check after 3 hours before escalating a "rule isn't firing" report.

---

## Common Fix Paths

<details><summary>Fix 1 — Alert isn't auto-resolving despite matching a rule's stated scope</summary>

1. Re-verify the rule's exact conditions in the portal — domain matches are typically exact-match, not wildcard/subdomain-inclusive (consistent with the same exact-match behavior documented for Network Data Security's FQDN matching; assume the same until Microsoft states otherwise).
2. Confirm the alert's own **Severity** field matches what the rule expects — a rule scoped to "Low severity only" will silently skip a Medium/High alert even from an otherwise-matching sender.
3. Wait out the propagation window (see Diagnosis step 4) before concluding the rule is broken.
4. If still unresolved, capture the rule definition (screenshot — no cmdlet export exists) and the specific alert's Alert ID for a Microsoft support case; this is current-generation Preview/GA-wave functionality without a mature troubleshooting doc set yet.

No PowerShell rollback is needed — this fix path is entirely portal configuration review.

</details>

<details><summary>Fix 2 — Auto-resolved alerts are hiding real risk (governance failure, not a bug)</summary>

This is the most consequential failure mode: a rule was scoped too broadly and is now silently closing alerts that deserved review.

1. **Immediately widen or disable the offending rule** in the portal — this stops new alerts from being auto-resolved but does **not** retroactively re-open ones already closed.
2. Pull the alert history for the rule's match window:
   ```powershell
   Get-ProtectionAlert | Where-Object { $_.LastUpdatedTime -gt (Get-Date).AddDays(-30) -and $_.Status -eq "Resolved" } |
       Select-Object Name, Severity, Count, LastUpdatedTime, Status | Sort-Object LastUpdatedTime -Descending
   ```
   Cross-reference against the rule's stated scope to identify every alert it likely touched.
3. Manually re-open and re-triage any alert whose underlying activity doesn't hold up under the "narrow, documented, owner-approved exception" bar described in the rule's original justification (see `DLPAlertAutoResolution-A.md` → Remediation Playbooks for the documentation template every rule should have had from day one).
4. Route the incident through the client's own change-control process — a rule that hid a real alert is a control failure worth a retrospective, not just a config change.

**Rollback:** disabling or narrowing the rule is immediate and non-destructive; it only affects *future* alert matches.

</details>

<details><summary>Fix 3 — "Too many alerts" complaint but auto-resolution isn't the right fix yet</summary>

Don't reach for auto-resolution as the first response to alert fatigue. Start with **tagging only** (per Microsoft's own phased-rollout guidance) so the team can validate that a proposed rule's conditions actually capture the intended population before anything is automatically closed:

1. Build the rule as a **tag-only** action first (e.g., tag matching alerts "Business Process — Pending Review").
2. Run it for at least one full triage cycle (a week is a reasonable minimum) and manually spot-check the tagged alerts.
3. Only convert to auto-resolution once the tag's precision has been validated against real alert traffic.

</details>

<details><summary>Fix 4 — Anyone with Purview access can create resolution rules (RBAC gap)</summary>

Auto-resolution/tagging rule authorship should be tightly held — these rules decide what a security team never sees.

```powershell
# Audit current membership of the roles that gate this feature
Get-RoleGroupMember -Identity "DLP Compliance Management"
Get-RoleGroupMember -Identity "Information Protection"
```

Remove anyone without a documented, current business need. If the client wants alert *visibility* without rule-authoring power, use **View-Only DLP Compliance Management** instead of the full role — this is the standard least-privilege split for this feature.

</details>

<details><summary>Fix 5 — Feature not present in the portal yet</summary>

1. Confirm tenant cloud environment — Worldwide standard multi-tenant is the initial GA target (Sept 2026); GCC/GCC High/DoD and sovereign clouds typically trail commercial cloud rollouts by weeks to months for Purview features.
2. Confirm the tenant has any DLP-licensed SKU active (Triage step 4) — a completely unlicensed tenant won't show any DLP surface at all, which is a different problem than a rollout-timing gap.
3. If licensing and cloud environment both check out, this is a staged-rollout timing gap, not a misconfiguration — there is no tenant-level PowerShell/Graph switch to force early access. Set client expectations accordingly and revisit in 2-4 weeks.

</details>

---

## Escalation Evidence

```
=== DLP Alert Auto-Resolution & Tagging — Escalation Packet ===
Tenant:
Ticket #:
Date/Time (UTC):

1. Feature visibility in Purview portal (Data Loss Prevention > Alerts > Alert rules): Present / Absent
2. Cloud environment: Worldwide / GCC / GCC High / DoD / Other: ____________
3. Rule name and full stated conditions (screenshot attached): ____________
4. Specific Alert ID(s) expected to match: ____________
5. Get-ProtectionAlert output for the affected alert(s) (attach):
6. Time elapsed since rule creation/edit (must be >3 hrs before escalating): ____________
7. Get-RoleGroupMember output for "DLP Compliance Management" (attach):
8. Licensing SKU confirmation (Get-MgSubscribedSku, attach):
9. Business impact: [ ] Noise/fatigue only  [ ] Real alert was suppressed (Fix 2 path — treat as priority)
10. Prior fix paths attempted from this runbook: ____________
```

---

## 🎓 Learning Pointers

- Auto-resolution and tagging act on the **alert record**, not the underlying DLP policy — a "resolved" alert means the policy still evaluated and acted on the content exactly as configured; only the alert's downstream triage status changed. See [Get started with data loss prevention alerts](https://learn.microsoft.com/en-us/purview/dlp-alerts-get-started).
- The DLP alert lifecycle is Trigger → Notify → Triage → Investigate → Remediate → Tune; auto-resolution/tagging rules operate entirely inside the **Triage** step, which is why they never touch the policy configuration that governs Trigger. See [Learn about investigating data loss prevention alerts](https://learn.microsoft.com/en-us/purview/dlp-alert-investigation-learn).
- Don't confuse this deterministic, rule-based feature with the **DLP Alert Triage Agent** (Security Copilot) — the Triage Agent uses AI-assisted analysis on a schedule or on demand and is a separate capability layered on top of, not replaced by, auto-resolution rules.
- Defender XDR retains DLP-sourced incidents for 6 months; the Purview Alerts dashboard retains them for only 30 days — always check both surfaces before concluding an alert "disappeared."
- Treat every auto-resolution rule as a governance artifact with an owner and a review date, not a one-time configuration task — see the deep-dive runbook's Remediation Playbooks for a documentation template.
