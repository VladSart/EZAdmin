# Microsoft Sentinel Threat Intelligence — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why TI silently goes stale, not just what to click.

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
- Microsoft Sentinel's own threat intelligence management layer: the four import paths (Defender Threat Intelligence connector, Upload API, STIX/TAXII connector, legacy Threat Intelligence Platform connector), the STIX object model (indicators, threat actors, attack patterns, identities, relationships), ingestion rules, and the `ThreatIntelIndicators`/`ThreatIntelObjects` table schema that replaced the legacy `ThreatIntelligenceIndicator` table on 2025-07-31
- How imported TI drives detection (indicator-based analytics rule templates, Defender TI matching analytics) and investigation (hunting, notebooks, the built-in Threat Intelligence workbook)
- MSSP/multi-workspace cost and correlation considerations

**Out of scope:**
- Defender for Endpoint's own Threat Intelligence Indicators feature (an EDR allow/block-list mechanism, unrelated data model — see `Security/Defender/`)
- Hunting query authoring and the Hunts (Preview) wrapper itself — see `Hunting-A.md` (TI is one input among many there)
- General analytics rule tuning not specific to indicator-based rule templates — see `AnalyticsRules-A.md`
- Watchlists — a separate reference-data mechanism (name-value pairs, not STIX objects) — see `Watchlists-A.md`

**Assumptions:**
- Sentinel is enabled on a Log Analytics workspace; either Azure-portal or Defender-portal onboarded (TI management sits alongside Microsoft Defender Threat Intelligence/Threat Analytics in the Defender portal regardless of which portal the workspace was provisioned through)
- Engineer has at minimum Log Analytics Reader; Microsoft Sentinel Contributor (or the equivalent Entra ID role for the Upload API's Entra app) is required to create/edit TI objects and ingestion rules

---

## How It Works

<details><summary>Full architecture</summary>

Cyber threat intelligence (CTI) in Sentinel is expressed using **STIX** (structured threat information expression), an open standard. This matters architecturally: Sentinel doesn't just store flat indicator strings, it stores typed STIX objects with relationships between them, which is why the platform migrated from a single flat table to a two-table schema mirroring that structure.

**The four import paths, in order of current recommendation:**

**1. Defender Threat Intelligence (MDTI) data connector — Microsoft's own curated feed**
```
Microsoft's global threat intelligence collection
   │
   ├─ Standard (free): public IOCs + open-source intelligence (OSINT)
   └─ Premium (licensed): adds Microsoft-curated IOCs + Microsoft-enriched OSINT
   │
   ▼
One-click connector enablement (no credentials to manage)
   │
   ▼
ThreatIntelIndicators / ThreatIntelObjects
```
A separate, freely available **Defender Threat Intelligence matching analytics rule** samples what the premium connector provides — it generates high-fidelity alerts/incidents directly by matching Microsoft's own IOCs against ingested events, distinct from the customer-authored indicator-based rule templates described below.

**2. Threat Intelligence Upload API — the current recommended path for custom/TIP integrations**
```
Your TIP platform, SOAR, or custom script
   │
   ├─ Microsoft Entra app registration, granted "Microsoft Sentinel Contributor"
   │  at the WORKSPACE scope (not subscription or resource group)
   │
   ▼
REST call to the workspace-scoped Upload Indicators API endpoint
   │      (no data connector object exists for this path — nothing to "enable" in the connector gallery)
   ▼
ThreatIntelIndicators / ThreatIntelObjects
```
This path requires no data connector because it's a direct, granular, workspace-scoped API — a deliberate design difference from every other path, which is why "check the connector gallery" is the wrong first troubleshooting move for Upload-API-sourced TI going missing.

**3. STIX/TAXII connector — industry-standard feed protocol**
```
TAXII 2.0/2.1 server (vendor- or community-operated: MISP, Cybersixgill, IBM X-Force, etc.)
   │
   ├─ API root + Collection ID (obtained from the feed operator, rotates on the vendor's schedule)
   │
   ▼
Sentinel's built-in TAXII client polls the server
   │
   ▼
ThreatIntelIndicators / ThreatIntelObjects
```

**4. Threat Intelligence Platform (TIP) data connector — being deprecated, migrate off**
```
Custom TIP or in-house tool
   │
   ├─ Legacy REST call to the Microsoft Graph Security tiIndicators API
   │  (indicators only — no support for other STIX object types)
   │
   ▼
ThreatIntelIndicators (indicators only)
```
Explicitly flagged by Microsoft as being phased out. Any remaining TIP-connector integration should be migrated to the Upload API, which uses the same object model natively and supports the full STIX object set, not just indicators.

**The 2025-07-31 schema cutover:** prior to this date, all Sentinel threat intelligence — regardless of import path — landed in a single legacy table, `ThreatIntelligenceIndicator`. On 2025-07-31, Microsoft stopped ingesting new data into that table entirely, splitting the model into `ThreatIntelIndicators` (indicator-type STIX objects) and `ThreatIntelObjects` (threat actors, attack patterns, identities, relationships — the non-indicator STIX object types). The legacy table remains queryable for historical data but will never show anything ingested after the cutover. This is a silent, no-error migration: nothing breaks visibly, saved artifacts referencing the old table simply stop seeing new data.

</details>

---

## Dependency Stack

```
Threat intelligence source (MDTI / TAXII server / Upload API caller / legacy TIP)
        │
        ▼
Authorization layer (varies by path)
        ├── MDTI: one-click connector, licensing tier gates IOC breadth (standard vs. premium)
        ├── TAXII: API root + Collection ID, credentials rotate on vendor's schedule
        ├── Upload API: Entra app registration + Microsoft Sentinel Contributor role at
        │       WORKSPACE scope specifically — subscription/RG-scoped grants do not satisfy this
        └── TIP (legacy): Graph Security tiIndicators API — deprecating, indicators-only
        │
        ▼
Ingestion rules (CONNECTOR-SOURCED OBJECTS ONLY — never applies to Upload API or manually
created TI)
        ├── Evaluated in order; a Delete action removes the object from the pipeline entirely
        ├── Update actions modify attributes (e.g. extend Valid until, remap old taxonomy tags)
        └── Changes take up to 15 minutes to take effect
        │
        ▼
Storage: ThreatIntelIndicators (indicator objects) + ThreatIntelObjects (all other STIX
object types), the CURRENT schema since 2025-07-31 — supersedes the legacy
ThreatIntelligenceIndicator single-table model, which stopped receiving new data that date
        │
        ▼
Deduplication: Id = base64(SourceSystem) + "---" + stixId; on a duplicate Id, the object
with the newest TimeGenerated wins and is the only one shown in the management interface
        │
        ▼
Automatic reingestion every 7–10 days (query-performance optimization — refreshes
TimeGenerated on unchanged objects; not a sign of pipeline instability)
        │
        ▼
Consumption layer
        ├── Indicator-based analytics rule TEMPLATES (built-in, keyed by indicator type:
        │       domain / email / file hash / IP / URL — each template documents its
        │       REQUIRED data-source table; the rule can't fire if that event-side table
        │       has no data, independent of how much TI exists)
        ├── Defender Threat Intelligence MATCHING analytics rule (separate mechanism —
        │       Microsoft's own IOCs matched directly against ingested events; free tier
        │       is a sample only, premium licensing required for full coverage)
        ├── Hunting queries / Hunts (Preview) — TI as one input among many, see Hunting-A.md
        ├── Notebooks / MSTICPy TILookup provider — code-first enrichment, see Notebooks-A.md
        └── Built-in "Threat Intelligence" workbook — visualization, customizable
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| An indicator-based analytics rule that "used to work" produces zero incidents, no error shown | Rule's query text still references the retired `ThreatIntelligenceIndicator` table | Open rule query editor, search for legacy table name |
| Custom KQL dashboard/workbook shows flat/zero TI volume since mid-2025 | Same root cause as above — dashboard built before the 2025-07-31 cutover, never migrated | Compare dashboard query against `ThreatIntelIndicators`/`ThreatIntelObjects` |
| Upload-API-submitted indicators never appear anywhere | Entra app registration missing Microsoft Sentinel Contributor at WORKSPACE scope (not sub/RG) | `Get-AzRoleAssignment -ObjectId <app-object-id> -Scope <workspace-resource-id>` |
| Same indicator seems to reappear with a refreshed timestamp every ~7-10 days with no manual action | Expected automatic reingestion cycle for query-optimization — not a fault | Confirm cadence matches; not an escalation trigger |
| An ingestion rule was configured to filter/tag Upload-API-sourced TI and appears to do nothing | Ingestion rules only apply to DATA-CONNECTOR-sourced objects — Upload API and manually created objects are structurally out of scope | Confirm the TI object's source path before assuming the rule is broken |
| TIP (legacy) connector intermittently drops indicators or shows connector-health warnings | Connector is in Microsoft's deprecation path — expect degrading reliability, not a fixable fault | Migrate to Upload API rather than continuing to troubleshoot |
| Relationship builder shows a connection that seems to duplicate a tag | Team is using both relationships AND free-form tags for the same conceptual link (documented as acceptable but redundant) | Confirm team convention — relationships for structural TTP/actor links, tags for ad hoc grouping (e.g. per-incident) |
| TLP value submitted via Upload API doesn't match what was intended | API requires one of four fixed `marking-definition` GUIDs for TLP, not a plain string value | Confirm the correct GUID-to-color mapping was used in the submission payload |
| MSSP: same TI set connected separately into every client workspace, ingestion cost climbing | Anti-pattern — TI is meant to be centralized into one workspace with cross-workspace queries for correlation | Reassess connector placement; see Remediation Playbook 2 |

---

## Validation Steps

**1. Confirm current-schema ingestion is healthy**
```kusto
ThreatIntelIndicators | where TimeGenerated > ago(24h) | summarize count() by SourceSystem
ThreatIntelObjects | where TimeGenerated > ago(24h) | summarize count() by SourceSystem
```
Good: recent rows from every expected `SourceSystem`. Bad: a source present in the connector gallery as "Connected" but absent here.

**2. Confirm nothing depends on the retired legacy table**
```kusto
ThreatIntelligenceIndicator
| summarize MaxTimeGenerated = max(TimeGenerated)
```
Good: `MaxTimeGenerated` is on or before 2025-07-31 (historical data only, as expected). Bad: a timestamp after that date indicates either a misconfigured client still writing to the old schema, or — more commonly — this is a false alarm from a query that unions both tables without realizing one is dead; confirm the actual write path, not just table contents.

**3. Validate the Upload API app's role assignment precisely**
```powershell
Get-AzRoleAssignment -ObjectId "<entra-app-object-id>" |
    Where-Object { $_.RoleDefinitionName -eq "Microsoft Sentinel Contributor" } |
    Select-Object Scope
```
Good: `Scope` is the specific workspace resource ID. Bad: role is assigned at subscription or resource-group scope only, or assigned to the wrong principal (a common mistake is granting the role to the app's *service principal* under a different Object ID than the one used in the API's bearer token).

**4. Confirm an analytics rule's event-side data source is actually populated**
```kusto
// Example: a rule template requiring DeviceNetworkEvents (Defender for Endpoint) to match IP indicators
DeviceNetworkEvents | where TimeGenerated > ago(24h) | count
```
A correctly-configured, fully-populated TI feed produces zero detections if the event-side table this rule template depends on has no data — always validate both sides of the join independently.

**5. Confirm ingestion rule scope assumptions before troubleshooting a "rule isn't working" ticket**
```
Threat intelligence → Ingestion rules → identify the TI object's SourceSystem
```
If `SourceSystem` indicates Upload API or a manually created object, the ingestion rule was never eligible to act on it — this is definitionally correct behavior, not a bug.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm scope: is this an ingestion gap or a consumption/query gap?

1. Run Validation Step 1. If TI is landing in the current tables at expected volume, the problem is downstream (a rule/query/workbook referencing the wrong schema) — skip to Phase 3.
2. If TI is NOT landing, the problem is upstream (source/auth/connector) — continue to Phase 2.

### Phase 2 — Ingestion-path diagnosis

1. Identify the specific import path (MDTI / TAXII / Upload API / TIP legacy) for the missing source.
2. MDTI: confirm license tier matches the expected IOC set (standard vs. premium — see How It Works).
3. TAXII: reconfirm API root/Collection ID with the vendor; these are the single most common TAXII breakage cause, changing on the vendor's own release cycle with no Sentinel-side notification.
4. Upload API: validate the Entra app's role assignment precisely (Validation Step 3) — workspace-scope-not-subscription-scope is the most common misconfiguration.
5. TIP (legacy): don't invest further troubleshooting time here — this connector is on a deprecation path; recommend migration to Upload API as the fix regardless of the specific symptom.

### Phase 3 — Consumption/query-schema diagnosis

1. For a rule/query/workbook that "stopped working" with no clear trigger event, check its creation or last-edit date against 2025-07-31 — if it predates the cutover and hasn't been touched since, this is very likely the cause.
2. Search the artifact's query text for the legacy table name; update to `ThreatIntelIndicators`/`ThreatIntelObjects` as appropriate for the fields being used.
3. For artifacts that joined indicator AND non-indicator STIX fields in the old single-table model, the migrated query needs to explicitly union or join across both current tables — this isn't a drop-in table rename.
4. Re-validate the artifact fires/renders correctly after the update.

### Phase 4 — Ingestion-rule diagnosis (only relevant for connector-sourced TI)

1. Confirm the TI object in question actually arrived via a data connector (not Upload API/manual) — see Validation Step 5.
2. Review ingestion rules in order — remember rules execute top-to-bottom and a `Delete` action stops all further rule evaluation for that object.
3. Allow up to 15 minutes after any ingestion rule change before concluding it isn't taking effect.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Migrate a legacy TIP connector or custom integration to the Upload API</summary>

**Use when:** A client's home-grown TI integration or the legacy TIP connector is showing degrading reliability, or as proactive work ahead of the eventual full TIP connector retirement.

```
1. Register a Microsoft Entra app dedicated to this integration (don't reuse a broad-purpose
   app — this API's permission model is workspace-scoped and should be scoped tightly).
2. Grant the app's service principal "Microsoft Sentinel Contributor" at the SPECIFIC
   WORKSPACE resource scope:
```
```powershell
New-AzRoleAssignment -ObjectId "<app-service-principal-object-id>" `
    -RoleDefinitionName "Microsoft Sentinel Contributor" `
    -Scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace>"
```
```
3. Update the calling integration to submit indicators/STIX objects in the current schema
   against the workspace-scoped Upload Indicators API endpoint (not the old Graph Security
   tiIndicators API the TIP connector used).
4. Decommission the legacy TIP connector once the Upload API path is confirmed populating
   ThreatIntelIndicators/ThreatIntelObjects at the expected volume — run both in parallel
   briefly to compare before cutting over fully.
```

**Rollback:** re-enabling the TIP connector is possible while it remains available, but Microsoft's own guidance is not to invest further in it — treat this as a one-way migration in planning terms even if technically reversible short-term.
</details>

<details><summary>Playbook 2 — Consolidate MSSP multi-workspace TI ingestion into a single centralized workspace</summary>

**Use when:** An MSSP has connected the same TAXII feeds or MDTI connector separately into many client workspaces, driving unnecessary duplicate ingestion cost.

```
1. Identify one centralized workspace (commonly the MSSP's own analyst/SOC workspace, not
   an individual client's) to own the TI connectors going forward.
2. Disconnect the redundant per-client connector instances after confirming no client-specific
   ingestion rule customization would be lost (review each client's ingestion rules first —
   consolidation can lose per-tenant filtering nuance if not reconciled).
3. Use cross-workspace KQL queries to correlate the centralized TI against each client
   workspace's event data for detection and hunting:
```
```kusto
union
  (ThreatIntelIndicators),
  (workspace("<client-workspace-name>").SecurityEvent)
| where ...
```
```
4. Rebuild any client-specific analytics rules to reference the centralized workspace's
   TI tables via cross-workspace query syntax rather than a local connector.
```

**Rollback:** reconnecting a per-client connector is straightforward if a specific client requires isolated TI (e.g. contractual data-segregation requirements) — evaluate this exception before consolidating that client.
</details>

<details><summary>Playbook 3 — Audit and update every artifact still referencing the retired legacy table</summary>

**Use when:** Onboarding an existing Sentinel workspace built before 2025-07-31, or proactively cleaning up technical debt.

```
1. Export all analytics rules, hunting queries, and workbook definitions.
2. Search each for the literal string "ThreatIntelligenceIndicator" (the legacy table).
3. For each match, determine which current table(s) the query needs — ThreatIntelIndicators
   for indicator fields, ThreatIntelObjects for actor/attack-pattern/identity/relationship
   fields — and rewrite accordingly, testing output before deploying.
4. Prioritize analytics rules (silent detection gaps are the highest-risk category) over
   workbooks (visualization-only, lower operational risk).
```

**Rollback:** N/A — this is a corrective audit, not a destructive change; keep the original query text in the escalation/change record for reference.
</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Microsoft Sentinel threat intelligence health evidence for escalation.
.NOTES     Requires Az.Accounts, Az.OperationalInsights modules and at least Log Analytics
           Reader on the target workspace; Reader on the Entra app registration for the
           Upload API role check. Run from an authenticated Az PowerShell session.
#>

param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$WorkspaceName,
    [string]$UploadApiAppObjectId
)

$OutputPath = "$env:TEMP\SentinelTI-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName

# 1. Current-table ingestion volume by source, last 24h
$q1 = "ThreatIntelIndicators | where TimeGenerated > ago(24h) | summarize Count=count() by SourceSystem"
try {
    (Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $q1).Results |
        Export-Csv "$OutputPath\01-CurrentIndicatorsBySource.csv" -NoTypeInformation
} catch { "Query failed: $($_.Exception.Message)" | Out-File "$OutputPath\01-ERROR.txt" }

# 2. Legacy table check — should show zero rows newer than 2025-07-31
$q2 = "ThreatIntelligenceIndicator | summarize MaxTimeGenerated=max(TimeGenerated)"
try {
    (Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $q2).Results |
        Export-Csv "$OutputPath\02-LegacyTableLastWrite.csv" -NoTypeInformation
} catch { "Query failed: $($_.Exception.Message)" | Out-File "$OutputPath\02-ERROR.txt" }

# 3. Upload API app role assignment (if provided)
if ($UploadApiAppObjectId) {
    Get-AzRoleAssignment -ObjectId $UploadApiAppObjectId |
        Select-Object DisplayName, RoleDefinitionName, Scope |
        Export-Csv "$OutputPath\03-UploadApiAppRoles.csv" -NoTypeInformation
}

Write-Host "Evidence collected to: $OutputPath" -ForegroundColor Green
Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath.zip" -Force
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|--------------------|
| Query current indicators | `ThreatIntelIndicators \| summarize count() by SourceSystem` |
| Query current non-indicator STIX objects | `ThreatIntelObjects \| summarize count() by SourceSystem` |
| Confirm legacy table is inactive | `ThreatIntelligenceIndicator \| summarize max(TimeGenerated)` |
| Check Upload API app's role at workspace scope | `Get-AzRoleAssignment -ObjectId <app-object-id> -Scope <workspace-id>` |
| Grant Upload API app the required role | `New-AzRoleAssignment -ObjectId <id> -RoleDefinitionName "Microsoft Sentinel Contributor" -Scope <workspace-id>` |
| View/manage TI in portal | Sentinel/Defender portal → Threat management → Threat intelligence |
| View/edit ingestion rules | Threat intelligence → Ingestion rules |
| View built-in TI workbook | Sentinel → Workbooks → Threat Intelligence |
| Check a rule's data-source requirement | Analytics rules → open rule template → Data sources tab |
| Cross-workspace TI query (MSSP) | `union (ThreatIntelIndicators), (workspace("<other-ws>").ThreatIntelIndicators)` |

---

## 🎓 Learning Pointers

- **The 2025-07-31 table-schema cutover is the single most consequential, easiest-to-miss fact in this entire topic.** It produced no errors, no portal warnings on existing rules, and no ticket at the time for most environments — just a quiet stop in new detections for anyone still querying `ThreatIntelligenceIndicator`. Given how long ago this cutover was relative to now, any client environment that hasn't had a TI-specific audit since mid-2025 is worth checking proactively, not just reactively. [Threat intelligence in Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/understand-threat-intelligence)
- **The Upload API's workspace-scoped role model is a deliberate design choice, not an oversight.** Older integration guidance (and muscle memory from other Azure RBAC patterns) leads engineers to grant roles at subscription or resource-group scope by habit — this API specifically requires and validates the workspace scope, and a broader-scoped grant will not satisfy it.
- **Ingestion rules and the STIX relationship/tag model are curation tools, not detection tools.** They shape what data looks like and how it's organized in the management UI; they have no direct effect on whether an analytics rule fires. Conflating "I fixed the TI data" with "the rule will now detect it" skips the equally important step of confirming the rule's own event-side data source is populated.
- **MSSP TI cost scales with connector count, not client count, if approached naively.** Connecting the same TAXII/MDTI feed independently into every client workspace multiplies ingestion cost for identical data; centralizing into one workspace with cross-workspace queries is the documented, cost-effective pattern — directly analogous to this repo's own Azure Lighthouse guidance on centralizing delegated access rather than duplicating it per tenant.
- **Reingestion every 7–10 days is a feature, not a symptom.** An indicator's `TimeGenerated` refreshing periodically with no visible change is Sentinel optimizing query performance over time — don't chase this as a data-integrity issue.
- **Reference:** [Work with threat intelligence in Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/work-with-threat-indicators) | [Connect your threat intelligence platform using upload API](https://learn.microsoft.com/en-us/azure/sentinel/connect-threat-intelligence-upload-api) | [Work with STIX objects (Preview)](https://learn.microsoft.com/en-us/azure/sentinel/work-with-stix-objects-indicators) | [Threat intelligence integration catalog](https://learn.microsoft.com/en-us/azure/sentinel/threat-intelligence-integration)
