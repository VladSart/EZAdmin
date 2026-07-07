# Microsoft Sentinel Analytics Rules & Incident Tuning — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Scope note:** This is about rules that are *running* but producing the wrong volume/quality of incidents (silent AUTO DISABLE, alert flood, grouping producing duplicate/split incidents, false-positive noise). If the problem is that **no data is arriving at all**, that's a data connector problem — see `Security/Sentinel/DataConnectors-B.md` first. Analytics rules can't fire on data that never landed.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

```kusto
// 1 — Any rules currently AUTO DISABLED? (Sentinel auto-disables after repeated permanent failures)
// Run in Log Analytics against the workspace: check the Analytics > Active rules list, sort by name.
// AUTO DISABLED rules sort to the top — there is no KQL table for rule metadata itself, this is a portal check.

// 2 — Rule efficiency: alerts-per-incident and false-positive ratio for a specific rule (last 14 days)
SecurityIncident
| where TimeGenerated > ago(14d)
| where RelatedAnalyticRuleIds has "<rule-guid>"
| summarize IncidentCount = dcount(IncidentNumber),
            AvgAlerts = avg(toint(AlertsCount)),
            FalsePositives = countif(Classification == "FalsePositive" or Classification == "BenignPositive"),
            Closed = countif(Status == "Closed")
| extend FPRatePct = round(100.0 * FalsePositives / Closed, 1)

// 3 — Is a specific rule actually firing at all in the lookback window?
SecurityAlert
| where TimeGenerated > ago(14d)
| where ProductName == "Azure Sentinel" and AlertName == "<rule-display-name>"
| summarize FirstSeen = min(TimeGenerated), LastSeen = max(TimeGenerated), Count = count()

// 4 — Incident flood check: which rule generated the most incidents today?
SecurityIncident
| where TimeGenerated > ago(24h)
| mv-expand RuleId = RelatedAnalyticRuleIds
| summarize IncidentCount = dcount(IncidentNumber) by tostring(RuleId)
| order by IncidentCount desc
| take 10

// 5 — Automation rule interference check: is an automation rule auto-closing incidents from this analytics rule?
// Portal check: Automation > Automation rules > filter by "Analytic rule name" condition == <rule>
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| Rule name shows **"AUTO DISABLED"** prefix | Repeated permanent failure (deleted table/workspace/function, lost permissions, or a resource-drain query) | Fix 1 |
| Rule enabled, but `SecurityAlert` shows zero rows for it in 14 days | Query too narrow, upstream table renamed/empty, or the rule was always broken since creation | Fix 2 |
| `AvgAlerts` per incident very high (dozens+) or `IncidentCount` spiking | Grouping settings wrong, or a genuine noisy/low-fidelity detection needs tuning | Fix 3 |
| `FPRatePct` consistently above ~50% | Rule needs exclusion tuning — check Tuning insights pane first (see Fix 4) | Fix 4 |
| Analysts report the same incident "keeps reopening" or alerts land in unrelated incidents | Grouping method not entity-based, or **Reopen closed incidents** setting fighting analyst workflow | Fix 5 |
| Incidents closing themselves instantly with no analyst action | An automation rule (possibly a stale pen-test/maintenance exception) is auto-closing matches | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for an analytics rule to produce a correctly-tuned incident</summary>

```
[Log Analytics table populated]  ← if empty, this is a DataConnectors-B.md problem, not this one
    └── [Scheduled/NRT query executes on schedule]
            └── [Query returns TimeGenerated-anchored results within lookback window]
                    └── [Alert threshold met] → [Alert created]
                            ├── [Entity mapping configured] → entities attached to alert
                            │        └── feeds: Tuning insights "top entities" pane, entity-based grouping, automation rule entity conditions
                            └── [Incident settings: "Create incidents" = Enabled]
                                    └── [Alert grouping settings]
                                            ├── Group by matching entities (recommended)
                                            ├── Group all alerts from this rule into one incident
                                            └── Group by entities + alert details/custom details
                                                    └── [Incident created — up to 150 alerts per incident, overflow spawns a new one]
                                                            └── [Automation rules evaluate conditions on incident-created trigger]
                                                                    └── [Analyst triage / closure classification feeds back into ML tuning insights]
```

Two separate portals govern this depending on tenant state: **Azure portal** (classic Sentinel) vs **Microsoft Defender portal** (unified SecOps — Sentinel onboarded). If onboarded to Defender, the Defender XDR correlation engine — not the rule's own grouping settings — has final say over how alerts land in incidents, and **"Reopen closed incidents" is unavailable**. Always confirm which portal mode the tenant is in before trusting a grouping setting to behave as configured.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm which portal/mode governs incident creation**
```
Defender portal (security.microsoft.com) → Microsoft Sentinel → Settings → check if "Onboarded to Defender portal" is active
```
Expected: know before touching grouping settings whether Sentinel's own engine or Defender XDR's correlation engine is authoritative. This changes what "Fix" is even possible (see Fix 5).

**Step 2 — Check for AUTO DISABLED rules**
```
Analytics → Active rules → sort by Name (AUTO DISABLED rules sort first)
```
Bad: any rule with `AUTO DISABLED` prefix and a failure reason appended to its description. SOC managers should check this list on a recurring schedule — Sentinel does **not** page or alert when a rule autodisables.

**Step 3 — Pull rule health via PowerShell (bulk check across all rules)**
```powershell
Get-AzSentinelAlertRule -ResourceGroupName "<rg>" -WorkspaceName "<workspace>" |
    Select-Object DisplayName, Kind, Enabled, Severity |
    Where-Object { $_.DisplayName -like "AUTO DISABLED*" -or -not $_.Enabled }
```
Bad: any row returned — either an autodisabled rule or one manually disabled and forgotten.

**Step 4 — Check Tuning insights for the specific rule (Preview feature)**
```
Analytics → select rule → Edit → Set rule logic tab → scroll below Results simulation → Tuning insights
```
Look at all three panes: rule efficiency (alerts/incident, open/closed by classification), entity exclusion recommendations, top 4 entities. The entity exclusion pane only populates if you have **closed incidents classified as False Positive** — if it's empty, you haven't closed enough incidents with a classification yet for the ML model to have signal.

**Step 5 — Validate entity mapping is actually configured**
```
Rule → Edit → Set rule logic → Entity mapping
```
Bad: no entities mapped. Without entity mapping, entity-based grouping falls back to "all alerts into one incident" behavior in practice, and the Tuning insights top-entities pane produces nothing.

**Step 6 — Check for automation rules silently closing incidents**
```
Automation → Automation rules → filter/sort by "Analytic rule name" condition
```
Bad: an automation rule with an expired-looking name (e.g., referencing an old pen-test) still enabled with no expiration date set, auto-closing every matching incident before an analyst sees it.

---
## Common Fix Paths

<details>
<summary>Fix 1 — Rule shows AUTO DISABLED</summary>

Read the failure reason Sentinel appended to the rule's **description** field first — it tells you exactly which permanent-failure category applies:

| Failure category | What to check |
|---|---|
| Target workspace/table deleted | Confirm table still exists; if renamed, rebuild the query against the new name |
| Sentinel removed from workspace | Re-onboard Sentinel to the workspace before re-enabling |
| Function used by the query no longer valid | Check **Settings → Workspace settings → Log Analytics → Functions** for the referenced function name |
| Permissions changed on a data source | See the cross-tenant/MSSP case below — this is the most common MSP-specific cause |
| Resource drain (query too expensive) | Rewrite the query — see [Kusto query best practices](https://learn.microsoft.com/en-us/kusto/query/best-practices) |

**MSP-specific cross-tenant gotcha:** if this rule queries workspaces in another subscription/tenant (MSSP/Lighthouse scenario), it runs under the **creating user's own credentials**, not an independent access token. If that analyst's account is disabled, loses a role, or leaves the org, every cross-tenant rule they created breaks silently and eventually auto-disables with an "insufficient access to resource" health message — with no connection to anything that changed in Sentinel itself.

```powershell
# Re-enable after the underlying cause is fixed
Update-AzSentinelAlertRule -ResourceGroupName "<rg>" -WorkspaceName "<workspace>" `
    -RuleId "<rule-guid>" -Kind Scheduled -Enabled
```

**Rollback:** re-enabling a previously-disabled rule is safe; monitor its next few executions to confirm the underlying cause is actually resolved before walking away.
</details>

<details>
<summary>Fix 2 — Rule enabled but never fires (zero alerts in lookback)</summary>

```kusto
// Test the rule's query manually — does it return anything at all right now?
<paste rule query here>
| take 10
```
Common root causes: the query references a table that was renamed by a connector update, a `TimeGenerated`-dependent lookback that's shorter than the actual event latency for that source (see NRT rules below for a fix), or the query was written against test data during creation and never validated against production volume.

If the source has known ingestion delay longer than the rule's lookback window, consider converting to an **NRT (near-real-time) rule** — NRT rules use ingestion time rather than `TimeGenerated`, avoiding the classic "rule looks broken but is really just querying before the data arrived" trap. NRT is capped at 50 rules per tenant and only helps for sources with ingestion delay under 12 hours.

**Rollback:** none — this is diagnostic only until you edit the query.
</details>

<details>
<summary>Fix 3 — Alert/incident volume too high (grouping or genuine noise)</summary>

First distinguish grouping-setting noise from genuine detection noise:

```
Rule → Edit → Incident settings → Alert grouping
```
Confirm **"Group alerts into a single incident if all the entities match"** is selected (recommended) rather than **"Group all alerts triggered by this rule into a single incident"** — the latter merges unrelated alerts together purely because they came from the same rule, which is almost never what you want and is a common misconfiguration inherited from rule templates.

If grouping is already correct and volume is still high, this is a genuine tuning problem — go to Fix 4.

**Rollback:** changing grouping method only affects future incidents, not existing ones.
</details>

<details>
<summary>Fix 4 — High false-positive rate / noisy rule (tuning)</summary>

Two mechanisms, pick based on permanence needed:

**A. Automation rule exception (temporary, audited, fast — do this first for a one-off pattern)**
1. Open the false-positive incident → **Actions → Create automation rule**.
2. Sentinel pre-fills the entity conditions from the incident (e.g., the specific IP or service principal that triggered it) — keep or broaden them (e.g., an IP to a subnet).
3. Confirm the action is **Close incident**, pick a closing reason, add a comment explaining the exception.
4. Set an **expiration date** — default is 24 hours; extend if the exception should live longer (e.g., a recurring scheduled maintenance window), but avoid leaving it permanently open-ended without a documented reason, since this is the #1 cause of Fix 6 later.

**B. Modify the analytics rule query (permanent, more precise)**
```kusto
let allowlist = (_GetWatchlist('sentinel_fp_exceptions') | project IPAddress);
SigninLogs
| where TimeGenerated >= ago(1d)
| where IPAddress !in (allowlist)
...
```
Prefer a **watchlist-backed exception** (`_GetWatchlist`) over hardcoding IPs/users directly in the query — it lets analysts maintain the exception list without touching the rule itself, and the same watchlist can back multiple rules.

**Rollback:** for (A), delete the automation rule or let it expire. For (B), remove the `where` clause and the watchlist entry — this is a query edit, fully reversible via rule version history in the wizard.
</details>

<details>
<summary>Fix 5 — Incidents reopening unexpectedly, or grouping ignored</summary>

If the tenant is **onboarded to the Microsoft Defender portal**, the Defender XDR correlation engine owns incident grouping — your rule's grouping settings are treated as *initial instructions only* and the engine can override them. **"Reopen closed incidents" does not exist in this mode at all.** Don't spend time tuning grouping settings expecting classic-Sentinel behavior if this is the case; the fix here is process (train analysts on Defender XDR's correlation behavior), not a rule setting.

If **not** onboarded to Defender and reopening is unwanted, disable it:
```
Rule → Edit → Incident settings → Alert grouping → Re-open closed matching incidents → Disabled
```

**Rollback:** toggling this setting is non-destructive and takes effect on the next matching alert.
</details>

<details>
<summary>Fix 6 — Incidents auto-closing before analysts see them</summary>

```
Automation → Automation rules → sort by rule name, look for pen-test/maintenance-window exceptions with no expiration date
```
```powershell
# List automation rules applying to a specific analytics rule (no direct cmdlet filter — pull all and filter client-side)
Get-AzSentinelAutomationRule -ResourceGroupName "<rg>" -WorkspaceName "<workspace>" |
    Where-Object { $_.TriggeringLogic.Conditions.ConditionProperties.PropertyName -contains "IncidentRelatedAnalyticRuleIds" }
```
If found and stale, either add/shorten the expiration date or disable it. This is a very common leftover from onboarding/pen-test periods that nobody cleaned up.

**Rollback:** disabling an automation rule doesn't affect already-closed incidents; re-enable if disabling was the wrong call.
</details>

---
## Escalation Evidence

```
=== SENTINEL ANALYTICS RULE / TUNING ESCALATION ===
Date/Time            :
Engineer              :
Ticket                :

Workspace Name        :
Rule Name             :
Rule Kind (Scheduled/NRT/Fusion/MS Security/Anomaly):
Rule Enabled (Y/N)    :
AUTO DISABLED (Y/N) + reason from description:

Portal Mode (Azure / Defender-onboarded):
Incident Creation Enabled (Y/N):
Alert Grouping Method :
Entity Mapping Configured (Y/N):

14-day Alert Count    :
14-day Incident Count :
Avg Alerts/Incident   :
False Positive Rate % :

Automation Rules Applying to This Analytics Rule (list + expiration dates):

Steps Attempted:
1.
2.
3.

Expected behaviour : Rule fires at expected volume with acceptable false-positive rate
Actual behaviour   :
```

---
## 🎓 Learning Pointers

- **A rule autodisabling is silent — Sentinel does not alert you.** Build a recurring check (weekly, via `Get-AzSentinelAlertRule` filtered on `DisplayName -like "AUTO DISABLED*"`) into your own MSP monitoring rather than relying on someone noticing during a portal visit. [Troubleshooting analytics rules](https://learn.microsoft.com/en-us/azure/sentinel/troubleshoot-analytics-rules)
- **Cross-tenant/MSSP rules run under the creator's own identity, not a service token** — this is the single most MSP-relevant failure mode in this whole topic, since analyst turnover is routine and the resulting breakage looks nothing like a Sentinel problem. [Troubleshooting analytics rules — permanent failure due to lost access](https://learn.microsoft.com/en-us/azure/sentinel/troubleshoot-analytics-rules#permanent-failure-due-to-lost-access-across-subscriptionstenants)
- **Tuning insights (Preview) needs closed, classified incidents to produce anything** — if your SOC doesn't consistently classify incidents as True/False/Benign Positive on close, the entity-exclusion ML recommendation pane will stay empty regardless of how noisy the rule actually is. Classification discipline is a prerequisite for this feature, not optional hygiene. [Get fine-tuning recommendations](https://learn.microsoft.com/en-us/azure/sentinel/detection-tuning)
- **Automation-rule exceptions and query-based exceptions solve different problems** — automation rules are fast, audited, and time-boxed (good for one-off/temporary noise); query/watchlist exceptions are permanent and precise (good for a known, durable false-positive pattern). Reaching for the wrong one either leaves permanent debt in a "temporary" automation rule or requires a rule edit for something that should have expired on its own. [Handle false positives in Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/false-positives)
- **The Azure portal's Sentinel experience is being retired** — after March 31, 2027 Sentinel is Defender-portal-only, and since July 2025 many new customers are auto-onboarded straight to the Defender portal. If a runbook step references classic Azure-portal-only settings (like "Reopen closed incidents"), confirm the tenant's portal mode first; it may simply not apply. [Move to the Defender portal](https://learn.microsoft.com/en-us/azure/sentinel/move-to-defender)
- **Community resource:** the [Microsoft Sentinel Tech Community blog](https://techcommunity.microsoft.com/category/azure-sentinel) and r/AzureSentinel regularly cover real-world tuning patterns (e.g., watchlist-driven exception management at scale) ahead of official docs.
