# Purview DLP SLA Alert Reporting Dashboard — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Microsoft Purview's out-of-box **SLA Alert Reporting Dashboard** for DLP alerts (Microsoft 365 Roadmap ID 568372; Preview target August CY2026, GA target September CY2026, Worldwide standard multi-tenant cloud).
- The three headline metrics — Mean Time to Acknowledge (MTTA), Mean Time to Detect (MTTD), Mean Time to Resolve (MTTR) — and the "Top Sensitive Information Types exposed" trend view.
- Admin-defined custom SLA thresholds per alert severity (High / Medium / Low).
- How this dashboard relates to the existing, well-documented DLP alert lifecycle and to its sibling features in the same Roadmap wave.

**Out of scope (covered elsewhere):**
- DLP Alert Auto-Resolution & Tagging (Roadmap 568371) — a separate, sibling feature from the same wave that acts on alerts rather than reporting on them; see `DLPAlertAutoResolution-A.md`/`-B.md`.
- General DLP policy authoring, detection logic, and enforcement — see `DLP-Policy-A.md`/`-B.md`.
- The underlying DLP alert lifecycle stages (Trigger/Notify/Triage/Investigate/Remediate/Tune) in full detail — see [Learn about investigating data loss prevention alerts](https://learn.microsoft.com/en-us/purview/dlp-alert-investigation-learn), summarized here only as needed.

> **Source-confidence note (read before treating anything below as settled):** as of this writing, this feature has **no dedicated Microsoft Learn conceptual or how-to page**. Everything specific to this dashboard in this runbook — its exact metric-boundary definitions, UI location, and rollout dates — is sourced from the Microsoft 365 Roadmap listing (ID 568372) and dated secondary-source blog coverage, not a primary Microsoft documentation article. This is explicitly flagged, consistent with this repo's standing practice for Preview-wave features with sparse official documentation (see `PredictiveShielding-A.md` for a prior example of the same pattern). Re-verify directly against the live Purview portal, and check for a newly-published Learn page, before presenting any metric definition as authoritative to a client.

**Assumed baseline:**
- Microsoft Purview DLP already licensed and generating alerts (any DLP-licensed tier for single-event alerts; A5/E5/G5 or add-on for aggregate/threshold alerts, per the existing DLP alerts licensing model).
- DLP Compliance Management or View-Only DLP Compliance Management role assigned for dashboard visibility.
- Worldwide standard multi-tenant cloud.

---

## How It Works

### The gap this closes

Prior to this feature, DLP alert operational performance had no out-of-box, trend-oriented reporting surface. Security teams could enumerate individual alerts (`Get-ProtectionAlert`) and their point-in-time status, but answering "are we getting faster or slower at triaging DLP alerts over the last quarter" or "which severity tier is chronically missing its response-time target" required manual export and analysis. This dashboard is Microsoft's answer: an out-of-box, trend-aware reporting layer purpose-built around three incident-response-style timing metrics adapted to the DLP alert lifecycle.

### The three headline metrics

- **Mean Time to Acknowledge (MTTA):** the average gap between an alert firing and a human beginning to work it — in general incident-response terminology, this measures triage responsiveness, not resolution speed.
- **Mean Time to Detect (MTTD):** the average time between the underlying risky activity occurring and the alert being generated/surfaced — a signal-generation-speed metric rather than a human-response metric.
- **Mean Time to Resolve/Respond (MTTR):** the average time from alert generation to final resolution/closure — the broadest of the three, spanning the full response lifecycle.

Applied to the DLP alert lifecycle (Trigger → Notify → Triage → Investigate → Remediate → Tune, as documented for the underlying alert model this dashboard reports on), these three metrics map approximately to: MTTD ≈ Trigger-to-Notify latency (largely a platform-detection metric, not typically actionable by an admin), MTTA ≈ Notify-to-Triage-start latency (the team's own responsiveness), and MTTR ≈ Notify-to-Remediate/close latency (end-to-end operational performance). **This mapping is this repo's own reasoned inference from the general MTTA/MTTD/MTTR framework applied to the documented DLP alert lifecycle stages — Microsoft has not published an explicit boundary definition for this specific dashboard as of this writing.** Treat it as a working hypothesis for client conversations, not a quoted Microsoft definition.

### Custom SLAs per severity

Admins can define their own target thresholds for High/Medium/Low severity alerts, and the dashboard reports actual performance against those thresholds rather than only showing raw averages. This mirrors standard SOC/SLA-management practice — a security team's real objective is rarely "minimize MTTA in the abstract" but rather "meet a defined SLA per severity tier," which is what the custom-threshold layer is built to measure against.

### Top Sensitive Information Types (SITs) exposed

The dashboard also surfaces which SITs most frequently appear in the alerts feeding its metrics — a triage-prioritization aid distinct from the timing metrics themselves, useful for identifying whether operational drag correlates with a specific content type (e.g., credit card numbers driving a disproportionate share of slow-to-resolve alerts).

### Relationship to sibling features in the same Roadmap wave

This dashboard, DLP Alert Auto-Resolution & Tagging (Roadmap 568371, built this same repo run in `DLPAlertAutoResolution-A.md`/`-B.md`), and a reported user-based alert aggregation capability all appear to originate from the same underlying DLP alert-operations investment wave (adjacent Roadmap IDs, overlapping Preview/GA timing). Practically, this means: a tenant that has received one of these features is a reasonable — though not certain — candidate to also check for the others, and a client evaluating "should we invest in auto-resolution rules" is a natural candidate to also be shown this dashboard, since the two are complementary (one measures response performance, the other actively improves it).

---

## Dependency Stack

```
Layer 4: SLA Alert Reporting Dashboard (NEW — Roadmap 568372)
           - MTTA / MTTD / MTTR trend visualizations
           - Top SITs exposed
           - Custom per-severity SLA threshold configuration
           - Purview portal only, no cmdlet/Graph read surface
Layer 3: DLP Compliance Management / View-Only DLP Compliance Management role
           (gates dashboard visibility, same as other DLP alert-operations features)
Layer 2: Purview DLP Alerts dashboard (pre-existing, 30-day retention) +
           Defender XDR incident queue (pre-existing, 6-month retention)
           — the dashboard's underlying data source
Layer 1: DLP policies generating alerts (single-event: any DLP-licensed tier;
           aggregate/threshold: A5/E5/G5 or qualifying add-on)
```

A tenant with a healthy Layer 1 (policies actively generating alerts) but no alert-response process at all will still produce a technically-functioning dashboard — it will simply report poor MTTA/MTTR figures, which is the dashboard doing its job correctly, not a fault condition.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Dashboard not visible in portal | Staged rollout not yet reached this tenant (Preview Aug 2026 / GA Sept 2026) | Confirm current date vs. rollout window; check for sibling feature 568371 as a cross-signal |
| Dashboard visible, empty/sparse data | Low underlying DLP alert volume, or recent enablement with no backfill yet | `Get-ProtectionAlert` volume check |
| Metrics seem to contradict manual timestamp math | Unpublished/assumed metric-boundary definition mismatch (see How It Works) rather than a data defect | Cross-check one specific alert's raw timestamps against its reported metric |
| Custom SLA thresholds not saving | Portal UI issue or missing role; no scripted workaround exists | RBAC check, then treat as support-case candidate |
| Dashboard shows data for Defender XDR-sourced alerts but seems to miss Purview-portal-only ones (or vice versa) | Possible surface-specific data-source gap — unconfirmed as of this writing given absence of an official architecture doc | Escalate with side-by-side alert counts from both surfaces |

---

## Validation Steps

1. **Confirm rollout presence.**
   Purview portal → Data Loss Prevention → Alerts → SLA dashboard view.
   *Good:* visible. *Bad:* staged-rollout gap.

2. **Confirm underlying data volume.**
   ```powershell
   Get-ProtectionAlert | Where-Object { $_.AlertType -eq "DLP" -and $_.LastUpdatedTime -gt (Get-Date).AddDays(-30) } | Measure-Object
   ```
   *Good:* nonzero, meaningful count. *Bad:* near-zero — expect a sparse dashboard as a correct outcome, not a defect.

3. **Confirm role-based visibility for the reporting user.**
   ```powershell
   Get-RoleGroupMember -Identity "DLP Compliance Management"
   Get-RoleGroupMember -Identity "View-Only DLP Compliance Management"
   ```
   *Good:* requester is a member of one. *Bad:* RBAC gap, not a dashboard defect.

4. **Spot-check one alert's manual timing against the dashboard's reported figures.**
   ```powershell
   Get-ProtectionAlert -Identity <alertId> | Select-Object Name, Severity, Status, CreatedTime, LastUpdatedTime
   ```
   Compare the raw `CreatedTime`/`LastUpdatedTime` delta against what the dashboard reports for that same alert where the portal allows per-alert drill-down.
   *Good:* roughly consistent with the working-hypothesis mapping in How It Works. *Bad:* significant, unexplained divergence — escalate.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Rollout and licensing confirmation**
Confirm the dashboard is present at all, and that the tenant's DLP licensing tier supports the alert types (single-event vs. aggregate/threshold) feeding it.

**Phase 2 — Data sufficiency**
Confirm meaningful DLP alert volume exists over the reporting window in question; a technically-correct but sparse dashboard is a very common "issue" report that isn't actually a defect.

**Phase 3 — RBAC verification**
Confirm the reporting user actually holds dashboard-visibility permissions before investigating further.

**Phase 4 — Metric-definition sanity check**
Given the unpublished exact boundary definitions, cross-check specific alerts manually rather than assuming the aggregate trend is wrong; document any discrepancy with side-by-side raw data before escalating.

**Phase 5 — Escalation**
This is Preview/early-GA-wave functionality with no primary documentation set — package the Evidence Pack and open a Microsoft support case for anything that survives Phases 1-4.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Standing up custom SLA thresholds for a new client engagement</summary>

1. Confirm dashboard presence and requester RBAC (Validation Steps 1 and 3).
2. Establish baseline MTTA/MTTD/MTTR figures over a representative window (30 days minimum) before setting any custom threshold — setting a threshold blind, before knowing current performance, produces an SLA that's either trivially met or immediately and permanently breached.
3. Set per-severity thresholds informed by the baseline and the client's actual risk tolerance — High-severity alerts typically warrant materially tighter MTTA targets than Low.
4. Re-baseline quarterly; treat the threshold values themselves as a governance artifact with a review date, consistent with this repo's standing recommendation for any DLP-alert-operations configuration (see `DLPAlertAutoResolution-A.md` for the same principle applied to auto-resolution rules).

**Rollback:** adjusting or removing a custom threshold is a non-destructive portal edit.

</details>

<details><summary>Playbook 2 — Investigating a suspected metric-definition defect</summary>

1. Select 3-5 alerts spanning a range of ages and severities.
2. For each, capture `Get-ProtectionAlert` raw `CreatedTime`, `LastUpdatedTime`, and `Status`, alongside the dashboard's own reported per-alert or aggregate figure where the portal exposes drill-down.
3. Look for a consistent pattern (e.g., every reported MTTA is exactly the same regardless of alert, suggesting a placeholder/default value rather than real computation) versus isolated, alert-specific anomalies (more likely genuine data issues on those specific records).
4. Package findings using the Evidence Pack below and escalate — do not attempt to "correct" reported values locally, since the true calculation logic isn't published.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Read-only evidence collector for Purview DLP SLA Dashboard escalations.
#>
$OutputPath = "C:\DLP-SLADashboard-Evidence"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Get-ProtectionAlert | Where-Object { $_.AlertType -eq "DLP" -and $_.LastUpdatedTime -gt (Get-Date).AddDays(-30) } |
    Select-Object Name, Severity, Status, Count, CreatedTime, LastUpdatedTime |
    Export-Csv "$OutputPath\DlpAlerts30Day.csv" -NoTypeInformation

Get-RoleGroupMember -Identity "DLP Compliance Management" |
    Export-Csv "$OutputPath\DlpComplianceManagementMembers.csv" -NoTypeInformation

Get-RoleGroupMember -Identity "View-Only DLP Compliance Management" |
    Export-Csv "$OutputPath\ViewOnlyDlpComplianceManagementMembers.csv" -NoTypeInformation

Write-Host "Evidence exported to $OutputPath. Dashboard screenshots (metric values, custom SLA thresholds, Top SITs view) must be captured manually — no cmdlet reads the dashboard itself." -ForegroundColor Yellow
```

---

## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Get-ProtectionAlert` | Raw DLP alert records — the dashboard's underlying data source |
| `Get-ProtectionAlert -Identity <id>` | Single-alert detail for manual metric cross-checking |
| `Get-RoleGroupMember -Identity "DLP Compliance Management"` | Full dashboard/rule-management RBAC membership |
| `Get-RoleGroupMember -Identity "View-Only DLP Compliance Management"` | Read-only dashboard visibility RBAC membership |
| `Get-MgSubscribedSku` | Tenant licensing tier check (aggregate/threshold alert eligibility) |
| `Get-DlpDetailReport` | Broader DLP policy-match history, useful for cross-referencing alert volume trends |
| `Connect-IPPSSession` | Required session for all Security & Compliance PowerShell cmdlets above |

---

## 🎓 Learning Pointers

- This is a **reporting layer**, not a new detection or enforcement capability — a poorly-performing MTTA/MTTR figure reflects team process, not a DLP policy defect.
- The exact MTTA/MTTD/MTTR boundary definitions for this specific dashboard are **not yet officially published** — this runbook's lifecycle-stage mapping is a reasoned working hypothesis, not a quoted Microsoft definition; always caveat this to clients until Microsoft ships primary documentation.
- Establish a baseline before setting custom SLA thresholds — a threshold set blind, without knowing current real-world performance, is operationally meaningless.
- This feature and `DLPAlertAutoResolution-A.md`/`-B.md` (Roadmap 568371) appear to be sibling features from the same DLP alert-operations investment wave — useful as a cross-check when confirming rollout status, and as a natural pairing when advising a client on DLP alert-operations maturity.
- See [Get started with data loss prevention alerts](https://learn.microsoft.com/en-us/purview/dlp-alerts-get-started) and [Learn about investigating data loss prevention alerts](https://learn.microsoft.com/en-us/purview/dlp-alert-investigation-learn) for the well-documented underlying alert model and lifecycle this dashboard reports on.
- Re-check the Microsoft 365 Roadmap (ID 568372) and the Purview portal directly before any client-facing engagement — Preview/GA dates for this wave of features have shifted before (see `EndpointDLPExcludedFolders-A.md`'s MC1384420 timeline-revision example) and should not be treated as fixed until confirmed live.
