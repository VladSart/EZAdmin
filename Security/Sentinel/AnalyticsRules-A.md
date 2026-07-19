# Microsoft Sentinel Analytics Rules & Incident Tuning — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

> **Scope note:** This covers analytics rules (detection logic), incident creation/grouping, entity mapping, automation rules, and false-positive tuning — the layer above data ingestion. If data isn't landing in the workspace at all, start at `Security/Sentinel/DataConnectors-A.md`; nothing in this document can compensate for an empty table.

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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

Assumes a working Microsoft Sentinel deployment on a Log Analytics workspace with at least one active data connector (see `DataConnectors-A.md`). Assumes Microsoft Sentinel Contributor or higher on the workspace/resource group. Covers **Scheduled**, **NRT (near-real-time)**, **Microsoft security (incident creation)**, **Fusion**, and **Anomaly (UEBA/ML)** rule kinds — the five rule types exposed in the Analytics rule wizard as of mid-2026. Does not cover Sentinel Solutions/Content Hub authoring, hunting query authoring outside of promoting a hunting query to a rule, or Logic Apps playbook internals (see `LogicAppsPlaybooks-A.md`/`-B.md`).

**Portal duality is load-bearing for this entire topic.** Microsoft Sentinel is transitioning from a standalone Azure portal experience to being one workload inside the unified **Microsoft Defender portal**. Since July 2025 many new customers are auto-onboarded directly to the Defender portal, and **the classic Azure-portal-only Sentinel experience retires entirely after March 31, 2027**. Several settings and behaviors described below (most importantly, who owns incident correlation) differ materially between the two modes. Always establish which mode a tenant is in before applying guidance that assumes classic Sentinel-in-Azure-portal behavior.

---
## How It Works

<details><summary>Full architecture: from query to tuned detection</summary>

**Rule kinds and what distinguishes them:**

| Kind | Query interval | Use case | Key constraint |
|---|---|---|---|
| **Scheduled** | 5 min – 14 days (lookback must be ≥ interval) | General-purpose custom detections | Standard 5-minute built-in ingestion-delay buffer |
| **NRT (near-real-time)** | Hard-coded 1 minute | Time-sensitive detections needing SIEM-like speed | Max 50 NRT rules per tenant; only effective on sources with ingestion delay under 12h; max 30 single-event alerts per run (31st+ summarized) |
| **Microsoft security** | N/A — triggered by connected Microsoft product alerts | Auto-create incidents from Defender for Identity/Cloud/Office 365/Entra ID Protection alerts | Superseded by native Defender XDR incident creation once onboarded to the Defender portal or Defender XDR incident integration is enabled |
| **Fusion** | Built-in ML correlation | Multi-stage attack detection correlating low-fidelity signals into a single high-fidelity incident | One built-in rule per workspace; individually tunable scenario exclusions |
| **Anomaly (UEBA/ML)** | Built-in ML behavioral baseline | Detects deviation from a learned per-entity behavior baseline | Requires UEBA enabled; tuned via sensitivity/threshold parameters, not KQL |

**Why NRT solves a real problem, not just speed:** standard scheduled rules use the event's own `TimeGenerated` field as the lookback anchor, but data doesn't arrive in the workspace instantly — there's ingestion delay between when an event happens at the source and when it's queryable. A scheduled rule with too short a lookback relative to real-world ingestion delay for that data source will systematically miss events that arrive *after* the query already ran for that window — a "phantom" detection gap that looks like a broken rule but is really a timing mismatch. NRT rules sidestep this by anchoring on **ingestion time** instead, with only a 2-minute built-in delay, at the cost of the 50-rule tenant cap and the 12-hour-ingestion-delay ceiling.

**The alert → incident pipeline:**
1. A scheduled/NRT rule query runs and returns results meeting the **alert threshold** (default: any result > 0, but tunable, e.g. "only alert if more than 100 events").
2. **Event grouping** decides how query results become alerts: either all results collapse into **one alert per rule execution** (default), or **one alert per individual event** (useful for per-user/per-host granularity, defined via the query itself).
3. **Entity mapping** (up to 10 entity types, up to 3 identifiers each, up to 500 entities total per alert across all mappings, 64 KB hard cap on the alert's Entities field) enriches the alert with structured identity/host/IP/file context. This is the single most consequential configuration choice in the whole pipeline — it feeds incident grouping, the Tuning insights top-entities pane, automation rule entity-based conditions, and every downstream investigation UI.
4. **Incident settings** decide whether the alert becomes an incident at all (default: yes, one incident per alert) and, if grouping is enabled, how up to 150 alerts get merged into a single incident: by matching all mapped entities (recommended — groups alerts that are actually about the same actor/asset), by rule identity alone (all alerts from this rule become one incident regardless of entity overlap — a common misconfiguration inherited from templates), or by entities plus specific alert/custom-detail fields.
5. **Automation rules** fire on incident-created, incident-updated, or alert-created triggers, evaluate conditions against the current state of the incident/alert, and execute ordered actions (task creation, status/severity/owner/tag changes, or invoking a Logic Apps playbook).
6. **Analyst classification on close** (True Positive / False Positive / Benign Positive, with sub-reasons) is the training signal for the **Tuning insights** ML feature — without consistent classification discipline, the tuning recommendations pane has no signal to work from.

**Portal-mode divergence — why this matters more than any single setting:** in classic Sentinel-in-Azure-portal mode, Sentinel's own engine owns steps 4-5 end to end, exactly as configured in the rule wizard. Once a workspace is onboarded to the **Microsoft Defender portal** (or Defender XDR incident integration is enabled), the **Defender XDR correlation engine** takes over incident creation and grouping. Your rule's Incident settings are accepted only as *initial instructions* — the correlation engine can and does override them based on its own cross-signal correlation logic, and **"Reopen closed incidents" is not available at all** in this mode. Practically: if analysts report that alerts aren't grouping the way the rule is configured, the first diagnostic question is always "which portal mode is this tenant in," not "is the grouping setting wrong."

</details>

---
## Dependency Stack

```
Layer 5: Analyst workflow
    Incident triage → classification on close (True/False/Benign Positive) → feeds Tuning insights ML model
                                    ▲
Layer 4: Automation
    Automation rules (incident-created / incident-updated / alert-created triggers)
        → actions: task, status, severity, owner, tag, or invoke Logic Apps playbook
                                    ▲
Layer 3: Incident creation & grouping
    Create incidents from alerts (default: on)
        → Alert grouping: by-entity (recommended) | by-rule-only | by-entity+details
        → up to 150 alerts/incident, overflow spawns a new incident with same details
        → Portal mode determines whether Sentinel's engine or Defender XDR's correlation
          engine has final authority over this layer
                                    ▲
Layer 2: Alert enrichment
    Entity mapping (≤10 mappings, ≤3 identifiers each, ≤500 entities/alert, 64KB cap)
    Custom details, alert detail customization
                                    ▲
Layer 1: Detection logic
    Rule kind (Scheduled / NRT / Fusion / Anomaly / Microsoft security)
        → query interval, lookback, alert threshold, event grouping (1 alert vs per-event),
          suppression window (up to 24h after an alert fires)
                                    ▲
Layer 0: Data availability
    Log Analytics table populated (see DataConnectors-A.md — out of scope here)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Rule name prefixed "AUTO DISABLED" | Repeated permanent failure (deleted table/workspace/function, permission loss, resource-drain query) | Rule description field — Sentinel appends the specific reason |
| Rule silently stopped firing, no AUTO DISABLED prefix | Transient failures still retrying, or query genuinely returns nothing now | `SecurityAlert` table for the rule's `AlertName`, last-seen timestamp |
| Cross-subscription/cross-tenant (MSSP) rule broke with no Sentinel-side change | Rule runs under creator's own credentials, not a service token; creator lost access or left | Rule health message: "insufficient access to resource"; check creator's current role assignments |
| Query returns data manually but rule never alerts | `TimeGenerated`-based lookback shorter than actual source ingestion delay | Compare source's documented ingestion delay to rule's lookback window; consider NRT |
| Duplicate incidents for what's clearly the same actor/asset | Alert grouping set to "all alerts from this rule" instead of entity-matching | Rule → Incident settings → Alert grouping method |
| One incident absorbing unrelated alerts | Grouping matched on too few/weak entity identifiers, or entity mapping missing | Rule → Set rule logic → Entity mapping |
| More than 150 alerts expected in one incident but a second incident appeared | Working as designed — 150-alert cap per incident, overflow spawns a sibling incident | Incident list — look for a second incident with matching details |
| Incident count for a rule extremely high, low signal value | Genuine tuning need — high false-positive rate or overly broad query | Tuning insights pane; `SecurityIncident` classification breakdown |
| Tuning insights entity-exclusion pane is empty | No/too few incidents from this rule closed with a False Positive classification | SOC closure discipline — classification is a prerequisite for the ML signal |
| Incidents closing themselves before an analyst looks | Automation rule auto-closing matches, often a forgotten pen-test/maintenance exception | Automation rules list, filter by analytics-rule condition, check for missing expiration |
| "Reopen closed incidents" setting seems to do nothing | Tenant onboarded to Defender portal — this setting doesn't exist in that mode | Confirm portal mode first |
| Grouping doesn't match rule configuration at all | Defender XDR correlation engine is authoritative (Defender-portal-onboarded tenant) | Same as above — settings are advisory only in this mode |
| Playbook listed under "Alert automation (classic)" stopped running | Classic alert-trigger playbook method deprecated effective March 2026 | Migrate to an automation rule with an alert-created trigger invoking the same playbook |
| Rule query flagged/blocked from re-enabling after AUTO DISABLE | Resource-drain classification — query too expensive to run safely | Rewrite query per KQL best practices before re-enabling |
| Analytics rule using a Log Analytics **function** stopped validating | Function was modified/removed by someone else independently | `Settings → Workspace settings → Functions` — confirm function still exists with same signature |

---
## Validation Steps

**1. Confirm portal mode (do this before touching any grouping/incident setting)**
```
Defender portal → Microsoft Sentinel → Settings → confirm "onboarded to Defender portal" state
```
Good: you know definitively whether Sentinel's own engine or Defender XDR's correlation engine owns incident behavior. Bad/risk: assuming classic behavior in a Defender-onboarded tenant, then "fixing" a grouping setting that was never actually authoritative.

**2. Bulk rule health sweep**
```powershell
Get-AzSentinelAlertRule -ResourceGroupName "<rg>" -WorkspaceName "<workspace>" |
    Select-Object DisplayName, Kind, Enabled, Severity
```
Good: all expected rules present, `Enabled = True`, no `AUTO DISABLED` prefixes. Bad: missing rules that should exist (deleted or never deployed from a template), disabled rules with no documented reason.

**3. Per-rule firing history**
```kusto
SecurityAlert
| where TimeGenerated > ago(30d)
| where ProductName == "Azure Sentinel"
| summarize AlertCount = count(), LastFired = max(TimeGenerated) by AlertName
| order by LastFired asc
```
Good: every enabled rule shows recent activity consistent with its expected trigger frequency. Bad: an enabled, non-NRT rule with zero alerts in 30 days — either genuinely quiet (fine) or broken (needs Fix 2 from the B-doc).

**4. Entity mapping completeness**
```
Rule → Edit → Set rule logic → Entity mapping
```
Good: at least one strong identifier mapped per relevant entity type (Account, IP, Host, URL, File, etc.). Bad: no entities mapped on a rule that's supposed to support entity-based grouping — grouping will default to less useful behavior and Tuning insights' top-entities pane stays empty.

**5. Incident/alert ratio and classification health**
```kusto
SecurityIncident
| where TimeGenerated > ago(14d)
| mv-expand RuleId = RelatedAnalyticRuleIds
| summarize Incidents = dcount(IncidentNumber),
            Closed = countif(Status == "Closed"),
            FalsePos = countif(Classification in ("FalsePositive","BenignPositive"))
            by tostring(RuleId)
| extend FPRatePct = round(100.0 * FalsePos / Closed, 1)
| order by FPRatePct desc
```
Good: false-positive rate reasonably low (context-dependent, but sustained >50% on a rule is a strong tuning signal) and most incidents reach `Closed` status rather than sitting stale. Bad: high FP rate with no corresponding tuning-insight exclusions applied, or a large backlog of never-closed incidents skewing the FP-rate math.

**6. Automation rule audit for stale exceptions**
```powershell
Get-AzSentinelAutomationRule -ResourceGroupName "<rg>" -WorkspaceName "<workspace>" |
    Select-Object DisplayName, Order, TriggeringLogic
```
Good: every closing/suppression-type automation rule has either a clear permanent business justification or an expiration date. Bad: an old pen-test/maintenance exception still active with no expiration, silently swallowing incidents indefinitely.

**7. Cross-tenant/MSSP rule credential exposure**
```
For any rule created to query across subscriptions/tenants, confirm the creating analyst's account is
still active and still holds the required role on the target workspace(s).
```
Good: documented ownership, ideally via a dedicated service account rather than a named individual's credentials. Bad: cross-tenant rules tied to a personal account with no succession plan — this breaks the moment that person's access changes for any reason, unrelated to Sentinel itself.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the failure is at this layer, not data ingestion**
Rule out `DataConnectors-A.md` territory first: query the underlying table directly, unfiltered by the rule's own logic, and confirm data actually exists in the relevant window.

**Phase 2 — Rule execution health**
Check rule Enabled state, AUTO DISABLED prefix, and the failure reason in the description. Distinguish transient (Sentinel retries automatically, no action needed beyond monitoring) from permanent (requires human fix before re-enabling) failure categories.

**Phase 3 — Alert generation correctness**
Test the query manually against current data. Confirm the alert threshold and event grouping settings match intent (single summarizing alert vs. per-event alerts). Confirm lookback window is appropriate for the data source's actual ingestion delay.

**Phase 4 — Incident behavior**
Confirm portal mode. Confirm incident creation is enabled (or correctly disabled, if this rule intentionally only feeds alert-triggered automation). Confirm grouping method matches intent, and that entity mapping supports it.

**Phase 5 — Tuning and automation**
Review Tuning insights for ML-driven exclusion recommendations (requires classification history). Review active automation rules for unintended auto-closure. Apply the appropriate exception mechanism (automation rule for temporary/audited, query/watchlist modification for permanent).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Bulk AUTO DISABLED sweep and remediation across an MSP's managed tenants</summary>

For an MSP managing many Sentinel workspaces, a scheduled sweep catches autodisabled rules that would otherwise go unnoticed until an analyst happens to look:

```powershell
$workspaces = @(
    @{ RG = "<rg1>"; WS = "<workspace1>" },
    @{ RG = "<rg2>"; WS = "<workspace2>" }
)

foreach ($w in $workspaces) {
    $rules = Get-AzSentinelAlertRule -ResourceGroupName $w.RG -WorkspaceName $w.WS
    $disabled = $rules | Where-Object { $_.DisplayName -like "AUTO DISABLED*" }
    foreach ($r in $disabled) {
        [PSCustomObject]@{
            Workspace = $w.WS
            RuleName  = $r.DisplayName
            Kind      = $r.Kind
        }
    }
}
```
For each result, read the rule's description for the specific failure reason before attempting to re-enable — re-enabling without fixing the underlying cause (a deleted function, a lost cross-tenant permission) just produces another AUTO DISABLE cycle.

**Rollback:** this playbook is read-only until you act on a specific rule; each individual fix carries its own rollback per the B-doc.
</details>

<details><summary>Playbook 2 — Migrating classic "Alert automation" playbooks to automation rules (deprecation-driven)</summary>

The legacy method of attaching a playbook directly to an analytics rule under "Alert automation (classic)" has been unable to accept new playbooks since June 2023, and the classic method itself is **deprecated effective March 2026**. Any tenant still relying on it needs migration before that cutover:

1. Identify affected rules: `Rule → Edit → Automated response tab → Alert automation (classic)` section — any playbooks listed here are affected.
2. For each playbook, create a new **automation rule** with an **alert-created trigger**, condition-scoped to the same analytics rule, with an action to run that same playbook.
3. Confirm the new automation rule fires correctly (test with a controlled alert if possible).
4. Remove the playbook from the classic list: select the ellipsis next to it → **Remove**.

**Rollback:** the classic list entry can be re-added manually if removed in error, but since new playbooks can no longer be added to it and it's being deprecated regardless, the only durable rollback is disabling the new automation rule rather than reverting to the classic method.
</details>

<details><summary>Playbook 3 — Building a tuning feedback loop (classification discipline → automated exclusion)</summary>

Tuning insights only produces useful entity-exclusion recommendations if incidents are consistently classified on close. To operationalize this as a SOC process rather than a one-off cleanup:

1. Enforce a **closing-reason requirement** for every incident (this is a SOC process/training point, not a portal setting — Sentinel does not block closing without a classification, but reports and dashboards can flag incidents closed without one).
2. On a recurring cadence (weekly/biweekly), review the Tuning insights lightbulb-flagged rules and apply recommended entity exclusions where the pattern makes sense.
3. For exclusions expected to be permanent, migrate from the rule-suggested exclusion into a shared watchlist (`_GetWatchlist`) rather than hardcoding, so the same exception can be reused across related rules.
4. Track false-positive rate per rule over time (see Validation Step 5's query) as a KPI — a rule trending toward a lower FP rate after tuning confirms the loop is working; a rule that never improves may need a redesign rather than continued exclusion tuning.

**Rollback:** entity exclusions and watchlist entries are non-destructive and reversible — remove the `where` clause or watchlist row to restore original detection scope.
</details>

<details><summary>Playbook 4 — Cross-tenant/MSSP rule credential hardening</summary>

Since cross-subscription/cross-tenant analytics rules run under the creating user's own credentials rather than an independent token, MSPs should avoid tying these to a named individual analyst account:

1. Identify all rules created to query across subscriptions/tenants (no direct PowerShell property exposes this — cross-reference rules whose query references a workspace/subscription outside the local one, or check with the team who built them).
2. Where feasible, recreate these rules under a dedicated service/automation account with documented, monitored credentials rather than a personal analyst account.
3. Document an ownership-transfer procedure for when the responsible account changes (offboarding checklist item), since this failure mode produces a health message ("insufficient access to resource") that looks nothing like a typical Sentinel problem to whoever investigates it later.

**Rollback:** recreating a rule under a different identity is safe — the original rule can be disabled (not deleted) until the replacement is confirmed working, then removed.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Read-only evidence collection for Sentinel analytics rule / tuning escalations.
.DESCRIPTION
    Pulls rule health, firing history, incident/classification stats, and automation
    rule inventory for a workspace. No rule, incident, or automation rule modification.
#>
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$WorkspaceName,
    [int]$LookbackDays = 14,
    [string]$OutputPath = ".\SentinelAnalyticsEvidence_$(Get-Date -Format yyyyMMdd_HHmm).csv"
)

$rules = Get-AzSentinelAlertRule -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
$autoDisabled = $rules | Where-Object { $_.DisplayName -like "AUTO DISABLED*" }
$disabled = $rules | Where-Object { -not $_.Enabled -and $_.DisplayName -notlike "AUTO DISABLED*" }

$autoRules = Get-AzSentinelAutomationRule -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName

$results = [PSCustomObject]@{
    Workspace           = $WorkspaceName
    TotalRules          = $rules.Count
    AutoDisabledCount   = $autoDisabled.Count
    AutoDisabledNames   = ($autoDisabled.DisplayName -join "; ")
    ManuallyDisabled    = $disabled.Count
    ManuallyDisabledNames = ($disabled.DisplayName -join "; ")
    AutomationRuleCount = $autoRules.Count
    CollectedAt         = (Get-Date -Format o)
}

$results | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Host "Evidence exported to $OutputPath" -ForegroundColor Green
```

Attach the output CSV plus the KQL query results from Validation Steps 3 and 5 to any escalation ticket.

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-AzSentinelAlertRule -ResourceGroupName <rg> -WorkspaceName <ws>` | List all analytics rules and their enabled/disabled state |
| `Get-AzSentinelAlertRule ... -RuleId <guid>` | Get a single rule's full definition |
| `Update-AzSentinelAlertRule ... -RuleId <guid> -Enabled` | Re-enable a rule (after fixing root cause) |
| `Remove-AzSentinelAlertRule ... -RuleId <guid>` | Delete a rule (destructive — confirm no dependent automation rules first) |
| `Get-AzSentinelAutomationRule -ResourceGroupName <rg> -WorkspaceName <ws>` | List automation rules and their trigger/condition logic |
| `Get-AzOperationalInsightsWorkspace -ResourceGroupName <rg> -Name <ws>` | Confirm workspace identity/quota context |
| `Invoke-AzOperationalInsightsQuery -WorkspaceId <id> -Query "<kql>"` | Run KQL from PowerShell for scripted evidence collection |
| `SecurityAlert \| summarize count() by AlertName` (KQL) | Per-rule alert volume |
| `SecurityIncident \| summarize count() by Classification` (KQL) | Classification breakdown across all incidents |
| `mv-expand RelatedAnalyticRuleIds` (KQL) | Correlate incidents back to the rule(s) that generated them |
| `_GetWatchlist('<name>')` (KQL) | Reference a watchlist for centrally-managed exceptions |
| `ipv4_lookup` plugin (KQL) | Subnet-based exclusion without listing every IP individually |
| Rule wizard → **Tuning insights** | ML-driven entity exclusion recommendations (Preview) |
| Rule wizard → **Results simulation** | Test a query against current data before saving |
| Automation page → **Automation rules** tab | Central view of all automation rules across all analytics rules |
| Incident → **Actions → Create automation rule** | Fastest path to a scoped, audited false-positive exception |

---
## 🎓 Learning Pointers

- **Custom detections in Defender XDR are positioned as the future unified authoring surface** for both Sentinel SIEM and Defender XDR detections — Microsoft's own docs now lead every analytics-rule article with this note. Building new detection logic, factor in whether it belongs in classic Sentinel analytics rules or the newer unified custom-detections experience, especially for greenfield tenants. [Custom detections overview](https://learn.microsoft.com/en-us/defender-xdr/custom-detections-overview)
- **The 150-alerts-per-incident cap is a hidden pagination behavior, not a hard failure** — when a noisy rule exceeds it, Sentinel silently spawns a second incident with identical details rather than erroring. An analyst who only looks at the first incident can badly undercount true alert volume during a real incident. [Create scheduled analytics rules](https://learn.microsoft.com/en-us/azure/sentinel/create-analytics-rules)
- **Entity mapping is the highest-leverage, most-skipped configuration step** — it silently degrades grouping quality, Tuning insights, and automation rule precision all at once when left unconfigured, yet it's easy to finish a rule wizard without ever expanding that section. Make entity mapping a mandatory checklist item in your rule-creation SOP, not an optional enhancement. [Map data fields to entities](https://learn.microsoft.com/en-us/azure/sentinel/map-data-fields-to-entities)
- **Portal mode (classic Azure portal vs. Defender-portal-onboarded) changes ground truth for incident behavior**, not just the UI chrome — grouping settings become advisory-only and an entire setting (Reopen closed incidents) disappears. Diagnosing "grouping isn't working" without first confirming portal mode risks chasing a setting that was never actually in control. [Move to the Defender portal](https://learn.microsoft.com/en-us/azure/sentinel/move-to-defender)
- **Tuning insights (Preview) is a closed-loop ML feature that depends entirely on SOC discipline** — it has no signal without a track record of classified closed incidents. A SOC with poor closure hygiene will never benefit from this feature no matter how noisy their rules are, independent of any Sentinel configuration. [Get fine-tuning recommendations](https://learn.microsoft.com/en-us/azure/sentinel/detection-tuning)
- **Community resource:** the [Microsoft Sentinel Tech Community blog](https://techcommunity.microsoft.com/category/azure-sentinel) regularly publishes real-world KQL exception patterns (watchlist-driven allowlisting, subnet exclusion at scale) worth reviewing alongside the official false-positive-handling doc.
