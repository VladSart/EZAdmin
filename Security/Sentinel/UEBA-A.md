# Microsoft Sentinel UEBA (User & Entity Behavior Analytics) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

> **Scope note:** Covers UEBA's enablement model, data sources, entity enrichment tables (`BehaviorAnalytics`, `IdentityInfo`, `UserPeerAnalytics`, `Anomalies`), scoring model, and the newer UEBA behaviors layer (`SentinelBehaviorInfo`/`SentinelBehaviorEntities`) — and, critically, how these relate to the **Anomaly** analytics rule kind and to Fusion. Does not cover data connector ingestion mechanics for the underlying sources (see `DataConnectors-A.md`), authoring custom hunting queries against UEBA tables beyond the built-in UEBA Essentials solution (a future dedicated hunting/KQL-authoring topic), or Microsoft Defender for Identity sensor deployment itself (see `Security/Defender/` for MDI).

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

Assumes a working Microsoft Sentinel deployment on a Log Analytics workspace with at least one active data connector already ingesting (see `DataConnectors-A.md`) — UEBA is an analysis layer on top of existing ingested data, not an independent ingestion pipeline. Assumes the reader has Microsoft Sentinel Contributor-or-higher on the workspace for any configuration change, and at minimum Sentinel Reader for querying UEBA tables. Covers UEBA in both the Azure portal and Microsoft Sentinel-in-Defender-portal experiences; **UEBA is included with Sentinel at no extra licensing cost**, though the new Log Analytics tables it creates are billed at standard ingestion/retention rates like any other table.

**Portal duality applies here exactly as it does across the rest of this domain.** After **March 31, 2027** Microsoft Sentinel is Defender-portal-only; several UEBA analyst experiences described below (the home-page widget, embedded user-page insights, "Go hunt" queries from incident graphs) are Defender-portal-native features with no Azure-portal equivalent, so a tenant still on the classic Azure portal will not see them regardless of UEBA configuration.

---
## How It Works

<details><summary>Full architecture: from raw logs to a scored anomaly on an entity page</summary>

**The headline finding for this topic: UEBA is not one feature, it's three independently-toggled capabilities that happen to share a name and a settings area.**

| Capability | Toggle location | Output table(s) | What it needs to work |
|---|---|---|---|
| **Base UEBA** (behavioral baselining) | Defender portal → Settings → Microsoft Sentinel → **UEBA tab** | `BehaviorAnalytics`, `IdentityInfo`, `UserPeerAnalytics` | Directory sync configured, data sources connected, no resource lock on the workspace at enable time |
| **Anomaly detection** | Defender portal → Settings → Microsoft Sentinel → **SIEM workspaces → [workspace] → Anomalies → Detect Anomalies** | `Anomalies` | Base UEBA must already be healthy — Anomaly detection consumes UEBA's baseline, it doesn't build its own |
| **UEBA behaviors layer** (Preview) | Its own dedicated enablement flow, separate from the UEBA tab | `SentinelBehaviorInfo`, `SentinelBehaviorEntities` | Independent of both of the above — aggregates raw logs into structured, natural-language "who did what to whom" summaries with MITRE ATT&CK mapping; explicitly documented as *not* indicating risk by itself, unlike alerts/anomalies |

This mirrors a pattern seen elsewhere in this repo (compare `EntraID/Troubleshooting/LifecycleWorkflows-A.md`'s `IsEnabled`/`IsSchedulingEnabled` split): a feature that looks single-switch in the UI is actually a small dependency chain of independently-gated capabilities, and the most common real-world support ticket is someone who flipped the first switch and stopped.

**Enablement prerequisites** (to toggle UEBA on/off — not required for day-to-day querying once enabled):
- Entra ID **Security Administrator** role (or equivalent), *and*
- An Azure RBAC role: **Owner** or **Contributor** at resource-group-or-higher, or the least-privileged combination of **Microsoft Sentinel Contributor** (workspace scope) + **Log Analytics Contributor** (resource-group scope), *and*
- **No Azure resource lock** (`CanNotDelete` or `ReadOnly`) on the workspace — a lock silently blocks the enable operation with no descriptive error surfaced in the portal.

**Directory sync — the two source options:**
- **Microsoft Entra ID** (cloud) — always available, no extra prerequisite.
- **On-premises Active Directory (Preview)** — requires the tenant already onboarded to **Microsoft Defender for Identity** (standalone or via Defender XDR) with the **MDI sensor installed and healthy on at least one domain controller**. This is a hard external product dependency: UEBA configuration itself cannot compensate for a missing/unhealthy MDI sensor, and on-prem identities simply never populate `IdentityInfo` if this prerequisite isn't met.

**Data sources UEBA analyzes** (once connected, either from the UEBA tab directly or from the underlying data connector's own Advanced options → Configure UEBA panel):

| Source | Availability | Log Analytics table |
|---|---|---|
| Sign-in Logs | Azure portal + Defender portal | `SigninLogs` |
| Audit Logs | Azure portal + Defender portal | `AuditLogs` |
| Azure Activity | Azure portal + Defender portal | `AzureActivity` |
| Security Events (Windows) | Azure portal + Defender portal | `WindowsEvent` / `SecurityEvent` |
| AAD Managed Identity sign-ins (Preview) | Defender portal only | `AADManagedIdentitySignInLogs` |
| AAD Service Principal sign-ins (Preview) | Defender portal only | `AADServicePrincipalSignInLogs` |
| AWS CloudTrail (Preview) | Defender portal only | `AWSCloudTrail` |
| Device Logon Events (Preview) | Defender portal only | `DeviceLogonEvents` |
| Okta CL (Preview) | Defender portal only | `Okta_CL` / `OktaV2_CL` |
| GCP Audit Logs (Preview) | Defender portal only | `GCPAuditLogs` |

The multi-cloud/Okta sources are a genuine differentiator worth knowing for MSPs with clients running mixed Azure/AWS/GCP/Okta estates — UEBA isn't Entra-only, but the newer non-Microsoft sources are Defender-portal-exclusive.

**Baseline building — per-enrichment, not a single fixed window.** Individual `ActivityInsights` enrichments each define their own lookback period, ranging from **5 days** (e.g., "uncommon high volume of operations", "unusual number of Conditional Access failures") through **7-10 days** (uncommonly-performed-by-user checks) to **30, 90, or 180 days** (first-time-in-tenant checks, peer-comparison checks). A commonly-cited rule of thumb is "wait about a week" before expecting first insights, but that's a floor for the *fastest* enrichments, not a ceiling for all of them — a "first time action performed in tenant" flag (180-day baseline) genuinely needs that much history to be meaningful.

**Scoring model — two deliberately different scores, not a single anomaly rating:**

| Aspect | Investigation Priority Score | Anomaly Score |
|---|---|---|
| Table / field | `BehaviorAnalytics.InvestigationPriority` | `Anomalies.AnomalyScore` |
| Range | 0-10 (0 benign, 10 highly anomalous) | 0-1 (0 benign, 1 highly anomalous) |
| Measures | How unusual a **single event** is, from profile-driven rules | Holistic anomalous **pattern across multiple events**, ML-derived |
| Processing | Near real-time, event-level | Batch, behavior-level |
| Calculation | Entity Anomaly Score (rarity of the entities involved) + Time Series Score (abnormal timing/frequency patterns) | ML anomaly detector trained on the workspace's own telemetry |

The two scores are expected to *sometimes* diverge rather than always agree — e.g. a user's first-ever Azure operation is a high Investigation Priority event (genuinely novel for that user) but typically a low Anomaly Score (first-time Azure actions are common tenant-wide, not inherently risky). Treat them as two different lenses, not a primary score and a redundant confirmation.

**Peer group calculation:** `UserPeerAnalytics` ranks each user's top 20 peers using a TF-IDF (term frequency-inverse document frequency) algorithm over security-group membership, mailing lists, and similar associations — smaller shared groups carry proportionally more weight than large, generic ones (e.g., sharing a 5-person project security group weighs more than sharing an "All Employees" group). This peer data underlies every "uncommon among peers" enrichment in `ActivityInsights`.

**BlastRadius calculation** (in `UsersInsights`, values Low/Medium/High) factors the user's position in the org tree plus their Entra role/permission set — and **requires the `Manager` property populated in Entra ID** to calculate at all. This is an identity-data-hygiene dependency entirely outside Sentinel/UEBA's own control.

**Relationship to Anomaly-kind analytics rules and Fusion:** the **Anomaly** rule kind (see `AnalyticsRules-A.md`'s rule-kind table) is a direct downstream consumer of UEBA's ML behavioral baseline — it's tuned via sensitivity/threshold parameters in the rule wizard, not KQL, precisely because the underlying detection logic lives in UEBA's model, not in an editable query. **Fusion** rules separately correlate low-fidelity signals (which can include UEBA anomalies among other inputs) into higher-fidelity multi-stage-attack incidents. Neither Anomaly rules nor Fusion can produce meaningful output if base UEBA and/or Detect Anomalies aren't both healthy first — this is the most common reason a client asks "why did Fusion/Anomaly rules never catch X" when the real gap is upstream in UEBA enablement.

**UEBA Essentials solution** (optional, Content Hub): a curated bundle of prebuilt hunting queries — including multi-cloud anomaly-detection queries across Azure, AWS, GCP, and Okta — maintained by Microsoft. Installing it is the fastest path to getting value from UEBA data without hand-authoring KQL against `BehaviorAnalytics`/`Anomalies` from scratch; it does not change UEBA's own data collection, only adds analyst-facing content on top.

**UEBA behaviors layer** (Preview, third independent toggle): rather than baseline-vs-deviation scoring, this layer aggregates related raw-log events into structured behavior objects with natural-language explanations ("who did what to whom") and MITRE ATT&CK technique mapping. Explicitly documented as *not* itself indicating risk — it's an abstraction/context layer that makes hunting and detection authoring easier, distinct in purpose from both `BehaviorAnalytics` (deviation scoring) and `Anomalies` (ML pattern detection).

</details>

---
## Dependency Stack

```
Layer 6: Downstream consumers
    Anomaly-kind analytics rules (AnalyticsRules-A.md) → Fusion correlation → entity-page UEBA
    widgets/insights → Defender portal home-page UEBA widget → "Go hunt" incident-graph queries
                                    ▲
Layer 5: Anomaly detection (independent toggle #2)
    Detect Anomalies = On → Anomalies table (AnomalyScore 0-1, ML batch)
                                    ▲
Layer 4: Entity enrichment output (base UEBA, toggle #1)
    BehaviorAnalytics (InvestigationPriority 0-10, event-level, near real-time)
    UserPeerAnalytics (top-20 peers via TF-IDF)
    IdentityInfo (synced identity profiles — 14-day full resync, 15-30 min incremental)
                                    ▲
Layer 3: Baseline building (per-enrichment lookback, 5-180 days)
                                    ▲
Layer 2: Data sources connected
    Signin/Audit/Activity/Security Events (+ Defender-portal-only previews: managed identity/SP
    sign-ins, AWS CloudTrail, Device Logon Events, Okta CL, GCP Audit Logs)
                                    ▲
Layer 1: Directory sync configured
    Microsoft Entra ID (always available) and/or on-prem AD (requires healthy MDI sensor —
    external product dependency, see Security/Defender/)
                                    ▲
Layer 0: Enablement prerequisites
    No resource lock on workspace + Entra Security Administrator + Azure RBAC role
                                    │
    [SEPARATE BRANCH, toggle #3 — not stacked on Layers 4-6]
    UEBA behaviors layer → SentinelBehaviorInfo + SentinelBehaviorEntities
    (own enablement flow, independent of both base UEBA and Detect Anomalies)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `BehaviorAnalytics` and `IdentityInfo` both return zero rows | UEBA was never actually enabled, or enable attempt was silently blocked | UEBA tab toggle state; resource lock on workspace |
| UEBA toggle shows "on" but no data after 2+ weeks | Data sources were never connected despite the base feature toggle, or directory sync never completed | Data source connection list under the UEBA tab |
| Enable attempt fails with a generic permissions error | Missing either Entra Security Administrator or the required Azure RBAC role — both required together | Role assignments for the enabling account |
| Enable attempt fails for no visible reason | Resource lock (`CanNotDelete`/`ReadOnly`) present on the workspace at enable time | `Get-AzResourceLock` |
| `BehaviorAnalytics` had data, then stopped on a specific date with no config change | Known transient data-flow stall | Disable/re-enable UEBA, allow 15-30 min |
| `BehaviorAnalytics` healthy, `Anomalies` table empty, Anomaly-kind rules never fire | Detect Anomalies is a separate, independently-off toggle | SIEM workspaces → Anomalies → Detect Anomalies setting |
| Cloud (Entra) users present in `IdentityInfo`, on-prem AD users absent | On-prem directory sync selected but MDI sensor not installed/healthy | Defender for Identity sensor health on domain controllers |
| `BlastRadius` null/empty for most users | `Manager` attribute not populated in Entra ID | `IdentityInfo` — `isempty(Manager)` count |
| "Uncommon among peers" enrichments never populate for a user | `UserPeerAnalytics` has no peer data for that user yet, or the user has too few/no shared group memberships for TF-IDF to rank peers | `UserPeerAnalytics` row presence for the user |
| `SentinelBehaviorInfo`/`SentinelBehaviorEntities` tables don't exist at all | UEBA behaviors layer is a third, separately-enabled Preview capability | Dedicated behaviors-layer enablement setting, distinct from the UEBA tab |
| Investigation Priority high but Anomaly Score low for the same event, analyst confused | Working as designed — the two scores measure different things (single-event rarity vs. multi-event pattern) and are expected to diverge sometimes | `UEBA scoring` reference — not a bug |
| Fusion or Anomaly-kind rule "never catches" an expected scenario | Upstream UEBA/Detect Anomalies gap, not a rule-tuning problem | Confirm both UEBA toggles are healthy before tuning the rule itself |
| Analyst can't see the Defender-portal UEBA home-page widget, embedded user-page insights, or "Go hunt" options | Tenant still on classic Azure-portal Sentinel experience — these are Defender-portal-native analyst experiences | Confirm portal mode |

---
## Validation Steps

**1. Confirm all three toggles' actual state (not assumed state)**
```
Defender portal → Settings → Microsoft Sentinel → UEBA tab (base UEBA + directory sync + data sources)
Defender portal → Settings → Microsoft Sentinel → SIEM workspaces → [workspace] → Anomalies (Detect Anomalies)
Behaviors-layer-specific enablement setting (separate from both of the above)
```
Good: all three states are explicitly known before troubleshooting proceeds. Bad: assuming any one implies another is also on.

**2. Confirm enablement prerequisites were met**
```powershell
Get-AzResourceLock -ResourceGroupName "<rg>"
```
Good: no lock scoped to the workspace. Bad: a lock present — this blocks (re-)enabling until removed, regardless of RBAC correctness.

**3. Data flow health across all core UEBA tables**
```kusto
union isfuzzy=true
  (BehaviorAnalytics | summarize Table="BehaviorAnalytics", Count=count(), Last=max(TimeGenerated)),
  (IdentityInfo | summarize Table="IdentityInfo", Count=count(), Last=max(TimeGenerated)),
  (UserPeerAnalytics | summarize Table="UserPeerAnalytics", Count=count(), Last=max(TimeGenerated)),
  (Anomalies | summarize Table="Anomalies", Count=count(), Last=max(TimeGenerated))
```
Good: all four tables show recent `Last` timestamps and non-zero counts (Anomalies may legitimately be low-volume in a quiet environment, but shouldn't be permanently zero if Detect Anomalies is on). Bad: any table showing zero rows despite its corresponding toggle being confirmed on.

**4. Directory sync completeness and freshness**
```kusto
IdentityInfo
| where TimeGenerated > ago(14d)
| summarize Total = dcount(AccountObjectId), MissingManager = dcountif(AccountObjectId, isempty(Manager)), LastSync = max(TimeGenerated)
```
Good: `Total` roughly matches the expected tenant user count, `LastSync` within the last 14 days (full resync cadence), `MissingManager` low. Bad: `Total` far below expected headcount (sync incomplete or on-prem AD not reaching UEBA), high `MissingManager` (BlastRadius will be unreliable).

**5. On-prem AD sync prerequisite (if selected)**
```
Cross-reference Security/Defender/ for Microsoft Defender for Identity sensor health on domain
controllers. No amount of UEBA-side reconfiguration substitutes for a missing/unhealthy sensor.
```
Good: sensor reporting healthy. Bad: sensor never installed, or installed but unhealthy — on-prem identities will never populate `IdentityInfo` regardless of UEBA settings.

**6. Anomaly-kind rule dependency confirmation**
```
Before tuning or troubleshooting an Anomaly-kind analytics rule as if it were broken, confirm both
BehaviorAnalytics and Anomalies are independently healthy per Steps 3-4 above.
```
Good: both upstream tables healthy, so any remaining Anomaly-rule issue is genuinely rule-level (see `AnalyticsRules-A.md`). Bad: skipping this and spending time tuning rule sensitivity when the actual gap is upstream.

**7. Portal-mode confirmation for analyst-facing UEBA experiences**
```
Confirm tenant's Sentinel portal mode (classic Azure portal vs. Defender-portal-onboarded) before
troubleshooting a missing UEBA home-page widget, entity-page insights, or "Go hunt" option — none of
these exist in classic Azure-portal Sentinel.
```

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm scope: which of the three toggles does this ticket actually concern?**
Most "UEBA is broken" tickets resolve immediately once it's clear whether the complaint is about base behavioral data (`BehaviorAnalytics`/`IdentityInfo`), anomaly detection specifically (`Anomalies`, Anomaly-kind rules), or the newer behaviors layer (`SentinelBehaviorInfo`/`SentinelBehaviorEntities`). Establish this before touching any setting.

**Phase 2 — Enablement prerequisite audit**
Check resource lock state, the enabling account's Entra role, and Azure RBAC role. A failure here explains both "I can't even turn it on" and, less obviously, "I turned it on but nothing happened" if the toggle silently failed.

**Phase 3 — Data source and directory sync verification**
Confirm which data sources are actually connected (not just theoretically eligible) and which directory service(s) are selected. For on-prem AD, verify the MDI sensor dependency separately — this is an external product health check, not a UEBA setting.

**Phase 4 — Baseline-period sanity check**
Before treating sparse enrichment data as a fault, confirm how long UEBA/the specific data source has actually been enabled against the relevant enrichment's documented baseline window (5-180 days depending on the specific `ActivityInsights` field in question).

**Phase 5 — Downstream consumer verification**
For Anomaly-rule or Fusion complaints, confirm the upstream tables (`BehaviorAnalytics`, `Anomalies`) are independently healthy before assuming the rule itself is misconfigured.

**Phase 6 — Evidence before escalation**
Collect toggle states, table row counts, resource lock status, and directory sync completeness (see Evidence Pack below) before opening a Microsoft support case — most real UEBA gaps are configuration/prerequisite gaps resolvable without vendor escalation.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield UEBA onboarding for a new Sentinel workspace</summary>

1. Confirm prerequisites: no resource lock on the workspace; the onboarding account holds Entra Security Administrator and an appropriate Azure RBAC role.
2. Enable base UEBA: **Defender portal → Settings → Microsoft Sentinel → UEBA tab → Turn on UEBA feature**.
3. Select directory service(s) — Entra ID at minimum; add on-prem AD only if Defender for Identity with a healthy sensor is already in place (don't select it speculatively).
4. Connect all eligible data sources (or select specific ones deliberately, if data-volume cost is a concern for the client).
5. Separately enable **Detect Anomalies** from SIEM workspaces → [workspace] → Anomalies, once base UEBA data is confirmed flowing (don't enable it day one before there's any baseline to detect against).
6. Install the **UEBA Essentials** solution from Content Hub for immediate hunting-query value rather than authoring from scratch.
7. Set client expectations explicitly: meaningful anomaly output takes 1-3 weeks depending on which enrichments matter most for their threat model (5-day burst detection vs. 180-day first-time-in-tenant baselines).

**Rollback:** disabling any of the three toggles stops new data collection for that layer; already-ingested data ages out per normal retention, nothing is force-deleted.
</details>

<details><summary>Playbook 2 — Extending UEBA to on-premises AD via Defender for Identity</summary>

1. Confirm Microsoft Defender for Identity is onboarded for the tenant (standalone or as part of Defender XDR).
2. Deploy and confirm health of the **MDI sensor** on at least one domain controller — cross-reference `Security/Defender/` for sensor deployment/health troubleshooting; this step has no UEBA-side equivalent.
3. Once the sensor is confirmed healthy, select **on-premises Active Directory (Preview)** as an additional directory service on the UEBA tab.
4. Validate on-prem identities begin appearing in `IdentityInfo` (`SourceSystem == "ActiveDirectory"` or `"Hybrid"`) within the expected sync window.

**Rollback:** deselecting on-prem AD sync stops new on-prem identity ingestion; existing synced records age out per `IdentityInfo`'s standard retention, independent of the MDI sensor's own state.
</details>

<details><summary>Playbook 3 — BlastRadius/peer-group data-hygiene remediation</summary>

For a client where BlastRadius is consistently unreliable across most users:

1. Run the query from Validation Step 4 to quantify how many users are missing the `Manager` attribute in Entra ID.
2. Populate `Manager` in bulk — via `Update-MgUser -UserId <id> -Manager@odata.bind "https://graph.microsoft.com/v1.0/users/<managerId>"` per user, or via an existing HR-to-Entra sync pipeline if one exists (preferred, since it stays current rather than being a one-time fix).
3. Allow the next `IdentityInfo` sync cycle (near-real-time for individually-changed records, full resync every 14 days) to reflect the update.
4. Re-run the Validation Step 4 query to confirm the missing-manager count has dropped.

**Rollback:** N/A — populating an identity attribute is additive; no destructive action is taken.
</details>

<details><summary>Playbook 4 — Fleet-wide MSP UEBA health audit</summary>

For an MSP managing UEBA across multiple client workspaces, use `Scripts/Get-SentinelUEBAAudit.ps1` (this folder) to sweep toggle state (where queryable), core table population, and directory-sync completeness across every managed workspace in one pass, rather than checking each client's UEBA tab manually. Feed findings into onboarding-hygiene tracking — a client with `BlastRadius`/peer-group gaps today is a client whose UEBA value will look weaker in any future security-posture review, even though the platform itself is functioning correctly.

**Rollback:** the script is fully read-only; no rollback applicable.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Read-only evidence collection for Sentinel UEBA escalations.
.DESCRIPTION
    Pulls core UEBA table health (BehaviorAnalytics, IdentityInfo, UserPeerAnalytics, Anomalies),
    resource lock state, and directory-sync completeness for a workspace. No configuration change.
#>
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$WorkspaceName,
    [string]$OutputPath = ".\SentinelUEBAEvidence_$(Get-Date -Format yyyyMMdd_HHmm).csv"
)

$ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName
$locks = Get-AzResourceLock -ResourceGroupName $ResourceGroupName

$tableQuery = @"
union isfuzzy=true
  (BehaviorAnalytics | summarize Table="BehaviorAnalytics", Count=count(), Last=max(TimeGenerated)),
  (IdentityInfo | summarize Table="IdentityInfo", Count=count(), Last=max(TimeGenerated)),
  (UserPeerAnalytics | summarize Table="UserPeerAnalytics", Count=count(), Last=max(TimeGenerated)),
  (Anomalies | summarize Table="Anomalies", Count=count(), Last=max(TimeGenerated))
"@
$tableHealth = Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $tableQuery

$result = [PSCustomObject]@{
    Workspace         = $WorkspaceName
    ResourceLockCount = $locks.Count
    TableHealth       = ($tableHealth.Results | ForEach-Object { "$($_.Table): $($_.Count) rows, last $($_.Last)" }) -join " | "
    CollectedAt       = (Get-Date -Format o)
}

$result | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Host "Evidence exported to $OutputPath" -ForegroundColor Green
```

Attach this output plus the Validation Step 3-4 query results and a screenshot of the UEBA tab's toggle/data-source state to any escalation ticket.

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `BehaviorAnalytics \| summarize count(), max(TimeGenerated)` (KQL) | Base UEBA data-flow health |
| `IdentityInfo \| summarize dcount(AccountObjectId), max(TimeGenerated)` (KQL) | Directory sync completeness/freshness |
| `Anomalies \| summarize count(), max(TimeGenerated)` (KQL) | Anomaly-detection-toggle data-flow health |
| `UserPeerAnalytics \| summarize dcount(UserPrincipalName)` (KQL) | Peer-group data presence |
| `IdentityInfo \| where isempty(Manager)` (KQL) | BlastRadius-blocking data-hygiene gaps |
| `Get-AzResourceLock -ResourceGroupName <rg>` | Confirm no lock blocking UEBA enable/disable |
| `Get-AzOperationalInsightsWorkspace -ResourceGroupName <rg> -Name <ws>` | Resolve workspace identity for KQL queries |
| `Invoke-AzOperationalInsightsQuery -WorkspaceId <id> -Query "<kql>"` | Run KQL from PowerShell for scripted evidence collection |
| `Update-MgUser -UserId <id> -Manager@odata.bind "<managerUrl>"` | Populate Manager attribute for BlastRadius remediation |
| Defender portal → Settings → Microsoft Sentinel → **UEBA tab** | Base UEBA toggle, directory sync, data sources |
| Defender portal → Settings → Microsoft Sentinel → **SIEM workspaces → Anomalies** | Detect Anomalies toggle (independent of UEBA tab) |
| Defender portal → Microsoft Sentinel → **Entity behavior** | Base UEBA config alternate entry point |
| Entity page → **Overview tab → Top UEBA anomalies** | Analyst-facing per-user anomaly summary (Defender portal only) |
| Incident graph → **Go hunt → All user anomalies** | Pivot from an incident to UEBA data (Defender portal only) |
| Content Hub → **UEBA Essentials** | Install prebuilt multi-cloud hunting queries |

---
## 🎓 Learning Pointers

- **UEBA is three products wearing one name.** Base behavioral baselining, anomaly detection, and the behaviors layer are independently toggled, independently gated, and populate entirely different tables. Framing every UEBA ticket as "which of the three is this actually about" resolves the majority of confusion before any real troubleshooting starts. [Identify threats with UEBA](https://learn.microsoft.com/en-us/azure/sentinel/identify-threats-with-entity-behavior-analytics)
- **Per-enrichment baseline windows (5-180 days) mean "UEBA has been on for two weeks and X still isn't showing" is not automatically a fault** — check which specific enrichment is in question and its documented lookback before assuming something is broken. [UEBA reference](https://learn.microsoft.com/en-us/azure/sentinel/ueba-reference)
- **A resource lock is an easy-to-miss, silent blocker at enable time** — it produces no descriptive error in the portal, so an engineer troubleshooting "UEBA won't turn on" should check for a lock before spending time re-verifying RBAC roles that may already be correct. [Enable entity behavior analytics — prerequisites](https://learn.microsoft.com/en-us/azure/sentinel/enable-entity-behavior-analytics)
- **BlastRadius and peer-group quality are downstream of Entra ID identity hygiene, not Sentinel configuration** — an MSP onboarding a client with an incomplete org chart (missing `Manager` attributes) should flag this as a data-quality prerequisite during onboarding, since no amount of UEBA reconfiguration compensates for it. [UEBA reference — UsersInsights field](https://learn.microsoft.com/en-us/azure/sentinel/ueba-reference#usersinsights-field)
- **Investigation Priority and Anomaly Score are two deliberately different lenses, not primary/backup signals** — expecting them to always agree (and treating disagreement as a bug) misreads the design. Event-level rarity and ML-derived pattern anomaly are genuinely different questions. [Identify threats with UEBA — scoring](https://learn.microsoft.com/en-us/azure/sentinel/identify-threats-with-entity-behavior-analytics#ueba-scoring)
- **Community resource:** Microsoft's own [UEBA and New Data Sources for UEBA Analytics and Anomalies webinar](https://www.youtube.com/watch?v=rekJwHjKLWg) and the [Expanding Microsoft Sentinel UEBA Ninja show](https://www.youtube.com/watch?v=R0PnVy-vp_4) go deeper on real-world tuning than the reference docs alone; Microsoft Q&A's `microsoft-sentinel` tag has several first-hand reports of the disable/re-enable data-flow-stall workaround ahead of any formal troubleshooting article covering it.
