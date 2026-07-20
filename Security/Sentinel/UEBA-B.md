# Microsoft Sentinel UEBA (User & Entity Behavior Analytics) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Scope note:** This is about UEBA specifically — behavioral baselining, peer-group analysis, blast-radius scoring, and the `BehaviorAnalytics`/`IdentityInfo`/`UserPeerAnalytics`/`Anomalies` tables. If the underlying data source (Entra ID sign-ins, Defender for Identity, Office 365) isn't ingesting at all, that's `Security/Sentinel/DataConnectors-B.md` territory — UEBA can't baseline data that never arrives. If the question is about a specific **Anomaly-kind analytics rule** not firing, start here first (UEBA is what feeds it), then cross-check `AnalyticsRules-B.md` for rule-level issues once UEBA itself is confirmed healthy.

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
// 1 — Is the BehaviorAnalytics table populated at all in the last 7 days?
BehaviorAnalytics
| where TimeGenerated > ago(7d)
| summarize Count = count(), LastSeen = max(TimeGenerated)

// 2 — Is IdentityInfo (directory sync) populated? Zero rows = directory sync never completed or UEBA never enabled.
IdentityInfo
| where TimeGenerated > ago(14d)
| summarize UserCount = dcount(AccountObjectId), LastSync = max(TimeGenerated)

// 3 — Any anomalies produced in the last 7 days? (Separate table from BehaviorAnalytics — see Fix 3)
Anomalies
| where TimeGenerated > ago(7d)
| summarize Count = count(), LastSeen = max(TimeGenerated)

// 4 — Peer-group data present? (Needed for "uncommon among peers" enrichments and BlastRadius context)
UserPeerAnalytics
| where TimeGenerated > ago(14d)
| summarize UsersWithPeers = dcount(UserPrincipalName)

// 5 — Investigation-priority spike check for a specific user (fastest single-entity triage)
BehaviorAnalytics
| where TimeGenerated > ago(7d)
| where UserPrincipalName =~ "<user@domain.com>"
| project TimeGenerated, ActivityType, ActionType, InvestigationPriority, SourceIPLocation
| order by InvestigationPriority desc
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| `BehaviorAnalytics` returns **zero rows** entirely | UEBA was never enabled, or was enabled but the workspace had a resource lock blocking it, or data sources were never connected | Fix 1 |
| `IdentityInfo` returns **zero rows** | Directory sync (Entra ID and/or on-prem AD) was never configured during UEBA setup | Fix 1 |
| `BehaviorAnalytics` has rows but they stopped appearing after a specific date, with no config change remembered | Table exists but stopped flowing — known transient issue, workaround is disable/re-enable | Fix 2 |
| `BehaviorAnalytics` populated, but `Anomalies` table is **empty** | UEBA feature and "Detect Anomalies" are two independent toggles — the second one is off | Fix 3 |
| Specific on-prem AD users missing from `IdentityInfo` while cloud-only users are present | On-premises AD sync selected but the Defender for Identity sensor isn't installed/healthy on a domain controller | Fix 4 |
| `BlastRadius` field empty/null for most users in `UsersInsights` | `Manager` attribute not populated in Entra ID for those users — BlastRadius can't calculate without it | Fix 5 |
| `SentinelBehaviorInfo`/`SentinelBehaviorEntities` tables don't exist | UEBA behaviors layer is a separate, independently-enabled Preview capability — not the same switch as base UEBA | Fix 6 |
| Analyst/admin gets "insufficient permissions" trying to toggle UEBA on/off | Missing either the Entra **Security Administrator** role or the required Azure RBAC role on the workspace — both are required, not either/or | Fix 7 |

---
## Dependency Cascade

<details><summary>What must be true for UEBA to produce a usable anomaly on an entity page</summary>

```
[Workspace has no Azure resource lock]  ← blocks enabling UEBA entirely if present, silently
    └── [Entra Security Administrator role held by the person enabling UEBA]
            └── [Azure RBAC: Owner/Contributor at RG+, OR Sentinel Contributor + Log Analytics Contributor]
                    └── [UEBA feature toggled ON]
                            ├── [Directory service selected: Microsoft Entra ID and/or on-prem AD]
                            │        └── on-prem AD requires: Microsoft Defender for Identity sensor installed
                            │            and healthy on a domain controller (separate product dependency)
                            │        └── feeds: IdentityInfo table (full resync every 14 days,
                            │            near-real-time 15-30 min update on profile/group changes)
                            └── [Data sources connected: Signin Logs, Audit Logs, Azure Activity,
                                 Security Events (+ Defender-portal-only previews: AAD Managed
                                 Identity/Service Principal sign-ins, AWS CloudTrail, Device Logon
                                 Events, Okta CL, GCP Audit Logs)]
                                    └── [Baseline period elapses — varies 5 to 180 days PER
                                         ENRICHMENT, not one fixed window; ~1 week minimum before
                                         first useful insights]
                                            └── [BehaviorAnalytics table populates — InvestigationPriority
                                                 score 0-10 per event, UsersInsights/DevicesInsights/
                                                 ActivityInsights enrichment fields]
                                            └── [UserPeerAnalytics populates — top 20 peers via TF-IDF,
                                                 needed for "uncommon among peers" enrichments]
                                                    ▲
                            [SEPARATE TOGGLE — does NOT turn on automatically with UEBA]
                            └── [Detect Anomalies enabled at workspace level]
                                    └── [Anomalies table populates — AnomalyScore 0-1, ML batch model]
                                            └── [Anomaly-kind analytics rules can now fire — see
                                                 AnalyticsRules-A.md rule-kind table]

[SEPARATE, INDEPENDENTLY-ENABLED PREVIEW — third toggle, not bundled with either of the above]
UEBA behaviors layer
    └── [Enabled explicitly via its own setting]
            └── [SentinelBehaviorInfo + SentinelBehaviorEntities tables created —
                 "who did what to whom" natural-language summaries + MITRE ATT&CK mapping]
```

**The three-toggle model is the single most common source of "UEBA doesn't work" tickets.** Base UEBA (behavioral baselining → `BehaviorAnalytics`), Anomaly detection (→ `Anomalies` table, feeds Anomaly-kind rules), and the UEBA behaviors layer (→ `SentinelBehaviorInfo`/`SentinelBehaviorEntities`) are three independent switches. Enabling one does not enable the others. An engineer who only flips the first one and then wonders why no Anomaly-kind rule ever fires has found the #1 real-world gap in this topic.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm UEBA is actually enabled and which directory sources are selected**
```
Microsoft Defender portal → System → Settings → Microsoft Sentinel → UEBA tab
(or: Microsoft Sentinel → Entity behavior → Entity behavior settings)
```
Expected: **Turn on UEBA feature** toggle is On, and at least one directory service (Entra ID and/or on-prem AD) is selected with a green/connected data-source list below it. Bad: toggle is off, or every data source shows disconnected.

**Step 2 — Confirm the workspace had no resource lock at enable time**
```powershell
Get-AzResourceLock -ResourceGroupName "<rg>"
```
Bad: any lock (`CanNotDelete` or `ReadOnly`) scoped to the Log Analytics workspace resource. A lock present at enable-time silently blocks the operation — remove the lock before retrying, not after.

**Step 3 — Confirm data actually arrived (not just "enabled")**
```kusto
BehaviorAnalytics | where TimeGenerated > ago(14d) | summarize count(), max(TimeGenerated)
IdentityInfo | where TimeGenerated > ago(14d) | summarize count(), max(TimeGenerated)
```
Bad: `IdentityInfo` empty after more than a few days — directory sync itself is stuck, not just "still baselining." `BehaviorAnalytics` empty after more than a week with data sources genuinely connected — treat as a real fault, not baseline-lag.

**Step 4 — Confirm the separate "Detect Anomalies" toggle**
```
Defender portal → Settings → Microsoft Sentinel → SIEM workspaces → select workspace → Anomalies → Detect Anomalies
```
Bad: toggle is off while the ticket describes "no anomalies ever." This is the single most common false "UEBA is broken" report — UEBA itself may be working perfectly; anomaly *detection* is just a second, separately-gated feature.

**Step 5 — Check BlastRadius / peer-group prerequisite data quality**
```kusto
IdentityInfo
| where TimeGenerated > ago(14d)
| summarize Total = dcount(AccountObjectId), MissingManager = dcountif(AccountObjectId, isempty(Manager))
```
Bad: a large proportion missing `Manager` — BlastRadius will be null/unreliable for those users regardless of how healthy UEBA itself is. This is a data-hygiene problem in Entra ID, not a Sentinel fault.

**Step 6 — For on-prem AD entity gaps specifically, check Defender for Identity sensor health**
```
Cross-reference: Security/Defender/ (MDI sensor health) — if the sensor on the domain controller is
unhealthy or was never installed, on-prem AD identities never reach IdentityInfo no matter how UEBA
itself is configured.
```

---
## Common Fix Paths

<details>
<summary>Fix 1 — BehaviorAnalytics/IdentityInfo empty entirely (UEBA never truly enabled)</summary>

Confirm the three enable-time prerequisites in order, since any one missing silently blocks the whole feature with no error surfaced to the person who clicked the toggle:

1. **Resource lock:** `Get-AzResourceLock -ResourceGroupName "<rg>"` — remove any lock on the workspace, then retry enabling.
2. **Entra role:** confirm the account enabling UEBA holds **Security Administrator** (or equivalent) in Microsoft Entra ID.
3. **Azure RBAC:** confirm **Owner**/**Contributor** at resource-group-or-higher, or the least-privileged pair of **Microsoft Sentinel Contributor** (workspace level) + **Log Analytics Contributor** (resource-group level).

Re-enable from **Defender portal → Settings → Microsoft Sentinel → UEBA tab → Turn on UEBA feature**, select directory service(s), then **Connect all data sources** (or select specific ones).

**Rollback:** disabling UEBA later stops new baseline data collection but does not retroactively delete already-ingested `BehaviorAnalytics`/`IdentityInfo` rows — those age out per normal Log Analytics retention.
</details>

<details>
<summary>Fix 2 — BehaviorAnalytics table exists but stopped receiving new data</summary>

A documented, known transient behavior: UEBA data flow can silently stall without any config change. The workaround is a controlled disable/re-enable cycle:

```
Defender portal → Settings → Microsoft Sentinel → UEBA tab → Turn off UEBA feature → wait ~2 minutes → Turn on UEBA feature → reselect directory service(s) and data sources
```
Expect **15-30 minutes** before data flow resumes after re-enabling. Do not conclude the fix failed and escalate before that window elapses.

**Rollback:** none needed — re-enabling with the same prior configuration is non-destructive to existing data.
</details>

<details>
<summary>Fix 3 — BehaviorAnalytics populated but Anomalies table empty (no Anomaly-kind rule ever fires)</summary>

This is **not** the same feature as base UEBA — confirm the independent toggle:

```
Defender portal → Settings → Microsoft Sentinel → SIEM workspaces → <workspace> → Anomalies tab → Detect Anomalies → On
```

Once enabled, the `Anomalies` table populates on its own ML batch schedule (not instantaneous) and any **Anomaly**-kind analytics rules become eligible to fire — see `AnalyticsRules-A.md`'s rule-kind table for how Anomaly rules differ from Scheduled/NRT (tuned via sensitivity/threshold parameters in the portal, not KQL).

**Rollback:** toggling Detect Anomalies off stops new anomaly scoring but doesn't delete historical `Anomalies` rows.
</details>

<details>
<summary>Fix 4 — On-prem AD users/devices missing from IdentityInfo</summary>

On-premises Active Directory sync (Preview) has a hard product dependency that's easy to miss during initial UEBA setup:

```
Confirm: Microsoft Defender for Identity is onboarded (standalone or via Defender XDR) AND the MDI
sensor is installed and reporting healthy on at least one domain controller.
```
If the MDI sensor was never deployed, on-prem AD identities simply never appear in `IdentityInfo` — UEBA's own configuration is not at fault. Cross-reference `Security/Defender/` for MDI sensor deployment/health troubleshooting; there is no UEBA-side fix for this.

**Rollback:** N/A — this is a prerequisite-deployment gap, not a change to roll back.
</details>

<details>
<summary>Fix 5 — BlastRadius consistently empty/null across most users</summary>

```kusto
IdentityInfo
| where TimeGenerated > ago(14d)
| where isempty(Manager)
| project AccountDisplayName, AccountUPN, Department
```
BlastRadius requires the **Manager** property populated in Entra ID for the user in question — this is an org-chart data-quality issue, not a Sentinel/UEBA defect. Populate `Manager` via Entra ID (bulk via `Update-MgUser -Manager@odata.bind` or HR-sync if available) and allow the next `IdentityInfo` sync cycle (near-real-time on the affected records, full resync every 14 days) to pick it up.

**Rollback:** N/A — populating a manager attribute is additive and safe.
</details>

<details>
<summary>Fix 6 — UEBA behaviors layer tables (SentinelBehaviorInfo/SentinelBehaviorEntities) don't exist</summary>

This is a third, separately-enabled Preview capability — it is **not** created automatically by turning on base UEBA or Detect Anomalies:

```
Follow the dedicated enablement steps at: Enable the UEBA behaviors layer in Microsoft Sentinel
(Defender portal → Microsoft Sentinel → the behaviors-layer-specific setting, distinct from the UEBA tab)
```
Once enabled, expect the two behaviors-layer tables to begin populating with natural-language "who did what to whom" summaries and MITRE ATT&CK-mapped entries — a genuinely different data shape from raw `BehaviorAnalytics` rows.

**Rollback:** disabling stops new behaviors-layer ingestion; existing rows age out normally.
</details>

<details>
<summary>Fix 7 — "Insufficient permissions" enabling/disabling UEBA</summary>

Both of the following are required simultaneously — missing either produces a permissions error with no further detail in the portal:

| Requirement | Where to check |
|---|---|
| Entra **Security Administrator** role (or equivalent) | Entra admin center → Roles and administrators |
| Azure RBAC: Owner/Contributor at RG+, or Sentinel Contributor (workspace) + Log Analytics Contributor (RG) | Azure portal → workspace → Access control (IAM) |

Grant the missing role and retry. This gate applies **only** to turning the feature on/off — day-to-day use of UEBA data (querying `BehaviorAnalytics`, viewing entity pages) uses normal Sentinel workspace read permissions, not this elevated pair.

**Rollback:** N/A — this is a permission grant, not a destructive change.
</details>

---
## Escalation Evidence

```
=== SENTINEL UEBA ESCALATION ===
Date/Time            :
Engineer              :
Ticket                :

Workspace Name        :
UEBA Feature Enabled (Y/N)        :
Directory Service(s) Selected     : (Entra ID / on-prem AD / both)
Data Sources Connected (list)     :
Detect Anomalies Toggle (Y/N)     :
UEBA Behaviors Layer Enabled (Y/N):

BehaviorAnalytics row count (7d)  :
IdentityInfo row count (14d)      :
Anomalies row count (7d)          :
UserPeerAnalytics populated (Y/N) :

Resource Lock Present at Enable Time (Y/N):
Enabling User's Entra Role        :
Enabling User's Azure RBAC Role   :

On-prem AD in scope? MDI sensor healthy (Y/N/N-A):

Steps Attempted:
1.
2.
3.

Expected behaviour : Entities show behavioral enrichment and anomalies surface on schedule
Actual behaviour   :
```

---
## 🎓 Learning Pointers

- **UEBA, anomaly detection, and the behaviors layer are three independent toggles, not one feature with sub-options.** This is the root cause behind most "UEBA doesn't work" tickets — someone enabled UEBA itself and stopped there, then reported that Anomaly-kind rules or behavior summaries "don't work." Always confirm which of the three switches the actual complaint maps to before troubleshooting deeper. [Enable entity behavior analytics](https://learn.microsoft.com/en-us/azure/sentinel/enable-entity-behavior-analytics)
- **Baseline windows are per-enrichment, not one fixed number.** Individual `ActivityInsights` enrichments use lookback windows ranging from 5 days (burst-of-operations detection) to 180 days (first-time-action-in-tenant), so "UEBA has been on for a week and I still don't see X" can be entirely expected depending on which specific enrichment is being checked. [UEBA reference — entity enrichments](https://learn.microsoft.com/en-us/azure/sentinel/ueba-reference)
- **A resource lock on the workspace silently blocks enabling UEBA** with no descriptive error pointing at the lock as the cause — this is worth checking first, before assuming an RBAC problem, whenever enabling fails for no obvious reason. [Enable entity behavior analytics — prerequisites](https://learn.microsoft.com/en-us/azure/sentinel/enable-entity-behavior-analytics)
- **BlastRadius depends on Entra ID's `Manager` attribute being populated** — this is an identity-hygiene prerequisite outside Sentinel entirely. An MSP onboarding UEBA for a client with incomplete org-chart data in Entra ID should flag this as a data-quality gap up front, not troubleshoot it as a Sentinel defect later. [UEBA reference — UsersInsights field](https://learn.microsoft.com/en-us/azure/sentinel/ueba-reference#usersinsights-field)
- **Investigation Priority (0-10, per-event) and Anomaly Score (0-1, ML batch) are deliberately different signals that don't always agree** — a user's first-ever Azure operation can score high on Investigation Priority (genuinely rare for that user) while scoring low on Anomaly Score (common enough tenant-wide not to be inherently risky). Don't treat a low Anomaly Score as contradicting a high Investigation Priority finding; they answer different questions. [Identify threats with UEBA — scoring](https://learn.microsoft.com/en-us/azure/sentinel/identify-threats-with-entity-behavior-analytics#ueba-scoring)
- **Community resource:** the [Microsoft Sentinel Tech Community blog](https://techcommunity.microsoft.com/category/azure-sentinel) and Microsoft Q&A's `microsoft-sentinel` tag regularly cover real-world UEBA data-flow stalls and the disable/re-enable workaround ahead of any official troubleshooting doc.
