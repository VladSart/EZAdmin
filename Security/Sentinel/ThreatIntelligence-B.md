# Microsoft Sentinel Threat Intelligence — Hotfix Runbook (Mode B: Ops)
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

**Disambiguation up front:** "threat intelligence" here means Sentinel's own indicator/STIX-object management layer — the four ingestion paths (Defender Threat Intelligence connector, Upload API, TAXII connector, legacy TIP connector) and the `ThreatIntelIndicators`/`ThreatIntelObjects` tables they feed. This is distinct from Defender for Endpoint's Threat Intelligence Indicators (a separate EDR-blocking feature — see `Security/Defender/`) and from Sentinel's Hunting queries (which *consume* TI as one input among many — see `Hunting-A.md`).

```kusto
// 1 — Is TI actually landing in the CURRENT tables? (legacy table was retired 2025-07-31)
ThreatIntelIndicators
| where TimeGenerated > ago(2h)
| summarize Count = count() by SourceSystem

// 2 — Is anything still writing to the OLD, retired table? (a strong signal of a stale query/rule/workbook)
ThreatIntelligenceIndicator
| where TimeGenerated > ago(7d)
| summarize Count = count()

// 3 — Confirm which connector(s) are actually enabled and their last-seen timestamp
ThreatIntelIndicators
| summarize LastSeen = max(TimeGenerated) by SourceSystem
| order by LastSeen asc

// 4 — Check whether an ingestion rule is silently deleting objects on the way in
// (Sentinel portal or Defender portal → Threat intelligence → Ingestion rules — no KQL surface for rule definitions)

// 5 — Confirm an indicator-based analytics rule is actually querying the CURRENT table, not the retired one
// (open the rule's query editor and search the rule query text for "ThreatIntelligenceIndicator" vs "ThreatIntelIndicators")
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| `ThreatIntelIndicators` returns 0 rows for every connector | No TI source actually connected/authorized, or Upload API app never granted the role | Fix 1 |
| `ThreatIntelligenceIndicator` (legacy table) still shows recent rows | A custom connector, script, or SIEM integration is still writing to the retired schema — will silently stop working with no further warning | Fix 2 |
| One connector's `SourceSystem` is missing from Triage query 3 but others are present | That specific connector's auth/consent expired, or (for TIP) it's the connector being deprecated | Fix 3 |
| Indicator clearly imported (visible in management UI) but never appears in an analytics rule/incident | Analytics rule or hunting query still references the legacy table name, or the rule's required data-source table isn't itself ingesting | Fix 4 |
| TI object imported via data connector doesn't match what an ingestion rule was supposed to do to it | Ingestion rules only apply to **data-connector** sourced TI — never touch Upload API or manually created objects | Fix 5 |
| Same indicator appears to "disappear and reappear" or shows a changed `Confidence`/`ValidUntil` with no manual edit | Normal reingestion cycle (every 7–10 days) or an ingestion rule updating attributes in place — not data loss | Not a fault — confirm against ingestion rule config before escalating |

---

## Dependency Cascade

<details><summary>What must be true for a threat intelligence indicator to reach an analytics rule or hunting query</summary>

```
[TI source: MDTI feed / STIX-TAXII server / Upload API caller / legacy TIP integration]
    └── [Connector authorized: MDTI = one-click; TAXII = API root + collection ID; Upload API = Entra
         app registration with Microsoft Sentinel Contributor role, scoped to the workspace; TIP = legacy
         Graph Security tiIndicators API, being deprecated]
            └── [Ingestion rules evaluated IN ORDER — connector-sourced objects only, never Upload API/manual]
                    └── [Object written to ThreatIntelIndicators (indicators) and/or ThreatIntelObjects
                         (all other STIX objects: threat actor, attack pattern, identity, relationship)]
                            └── [Deduplication: Id = base64(SourceSystem) + "---" + stixId — newest
                                 TimeGenerated wins if the same Id is reingested]
                                    └── [Object visible in TI management UI / queryable via Logs
                                         or Defender Advanced hunting]
                                            └── [Consumed by: indicator-based analytics rule templates
                                                 (matched against the rule's required data-source table),
                                                 Defender TI matching-analytics rule, hunting queries,
                                                 the built-in Threat Intelligence workbook, notebooks]
```

**Critical cutover point (2025-07-31):** the legacy `ThreatIntelligenceIndicator` table stopped receiving new data on that date. Any analytics rule, hunting query, workbook, or automation that still references it by name has been silently blind to new indicators since then — this is not a live outage, it's accumulated technical debt that this runbook's Fix 2/4 exist specifically to surface.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm you're querying the current schema, not the retired one**
```kusto
ThreatIntelIndicators | count
ThreatIntelObjects | count
ThreatIntelligenceIndicator | count   // should be flat/zero growth since 2025-07-31
```
Bad: `ThreatIntelligenceIndicator` shows rows with `TimeGenerated` newer than 2025-07-31 → something is still writing to (or a saved query is still reading from) the legacy schema.

**Step 2 — Identify which of the four import paths is actually in use**
```
Sentinel/Defender portal → Threat management → Threat intelligence → Data connectors filter (or Content hub → Threat Intelligence solution)
```
Confirm connector state per source: MDTI (standard/premium), TAXII, Upload API (no connector tile — check Entra app role assignment instead), legacy TIP (flagged for deprecation in the UI).

**Step 3 — For Upload API integrations, validate the Entra app's role**
```powershell
Get-AzRoleAssignment -ObjectId "<entra-app-object-id>" -Scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace>"
```
Good: `Microsoft Sentinel Contributor` present at the workspace scope. Missing this is the most common Upload API "indicators never appear" root cause.

**Step 4 — Confirm an analytics/hunting rule's query text targets the current table**
```
Open the rule → Query editor → search for "ThreatIntelligenceIndicator" (legacy) vs "ThreatIntelIndicators"/"ThreatIntelObjects" (current)
```
Bad: rule still references the legacy table name — it has been silently non-functional against new TI since 2025-07-31 even though it shows as Enabled with no error.

**Step 5 — Confirm ingestion rules aren't unexpectedly filtering objects**
```
Threat intelligence → Ingestion rules
```
Remember: rules apply **only** to data-connector-sourced objects, evaluated top-to-bottom, and a `Delete` action removes an object from the pipeline before it's ever visible. New/edited rules take up to 15 minutes to take effect.

---

## Common Fix Paths

<details>
<summary>Fix 1 — No TI landing from any source</summary>

```
1. Confirm at least one connector shows an active/connected state in Content hub → Threat Intelligence solution.
2. For MDTI: reconfirm the license tier (standard = free public/OSINT IOCs; premium requires a separate license)
   — a connector showing "Connected" with the standard tier will never populate premium-only IOC types.
3. For TAXII: reconfirm the API root and collection ID with the feed vendor — these frequently rotate
   without notice on the vendor side.
4. For Upload API: confirm the Entra app registration exists, has a valid client secret/certificate,
   and holds Microsoft Sentinel Contributor at the WORKSPACE scope (not subscription/resource-group —
   the API request endpoint is workspace-scoped by design).
```

**Rollback:** none — reconnecting/re-authorizing a TI source is additive and non-destructive.
</details>

<details>
<summary>Fix 2 — Something is still writing to (or reading from) the retired legacy table</summary>

```
1. Identify the source: a custom Logic App, a legacy TIP integration, or a saved KQL query/workbook
   still hard-coded to "ThreatIntelligenceIndicator".
2. For custom integrations: migrate to the Upload API — it uses the STIX-standardized schema natively
   and doesn't require a data connector at all.
3. For saved queries/workbooks/analytics rules: search and replace the table name.
   ThreatIntelIndicators covers indicator objects; ThreatIntelObjects covers all other STIX object
   types (threat actor, attack pattern, identity, relationship) — a query that joined across both
   indicator and non-indicator fields in the old single-table model now needs to query both tables.
```

**Rollback:** none required — this is a forward-only migration; the legacy table remains queryable for historical (pre-2025-07-31) data but will never show anything newer.
</details>

<details>
<summary>Fix 3 — One specific connector's SourceSystem has gone quiet</summary>

```
1. MDTI: check Entra app / service health for Defender Threat Intelligence specifically.
2. TAXII: re-validate credentials with the vendor; TAXII servers commonly rotate API roots on a
   fixed schedule (quarterly/annually) that customers aren't proactively notified about.
3. Legacy TIP connector: this connector is explicitly flagged by Microsoft as being deprecated.
   If this is the quiet source, don't troubleshoot it — migrate it to the Upload API instead,
   since continued investment in TIP-connector-specific fixes is a dead end.
```

**Rollback:** none — reconnecting is additive.
</details>

<details>
<summary>Fix 4 — Indicator visible in management UI but never drives a detection</summary>

```
1. Confirm the analytics rule's REQUIRED DATA SOURCE table is itself ingesting data — an
   indicator-based rule compares raw events (e.g. DeviceNetworkEvents, CommonSecurityLog) against
   TI; if the EVENT side of that join has no data, the rule will never fire regardless of how much
   TI exists.
2. Confirm the rule's query text targets ThreatIntelIndicators, not the legacy table (see Diagnosis
   Step 4).
3. For the Defender Threat Intelligence MATCHING analytics rule specifically (distinct from
   indicator-based rules the customer authors) — confirm licensing; the free experience only
   provides a SAMPLE of matches, not full coverage.
```

**Rollback:** none — this is detection-logic verification, not a destructive change.
</details>

<details>
<summary>Fix 5 — Ingestion rule doesn't appear to be filtering Upload-API or manually created TI</summary>

```
This is expected behaviour, not a bug: ingestion rules apply ONLY to threat intelligence
arriving through a data connector. Objects added via the Upload API or created manually in the
management UI are never touched by ingestion rules.

If filtering/enrichment of Upload-API-sourced TI is required, it must be handled at the source
(the platform/script calling the Upload API) before the object is sent, or via a downstream
KQL filter in the consuming query/rule.
```

**Rollback:** N/A — no change made, this fix is a correction of expectations.
</details>

---

## Escalation Evidence

```
=== SENTINEL THREAT INTELLIGENCE ESCALATION ===
Date/Time            :
Engineer              :
Ticket                :

Workspace Name        :
Affected Source(s)     (MDTI / TAXII / Upload API / TIP - legacy):
Affected Rule/Query/Workbook Name:

ThreatIntelIndicators row count (last 2h):
ThreatIntelObjects row count (last 2h):
ThreatIntelligenceIndicator (legacy) row count, TimeGenerated > 2025-07-31 (should be 0):

Upload API Entra App Object ID (if applicable):
Sentinel Contributor role confirmed on app (Y/N):

Ingestion rule(s) potentially involved (Y/N, list):

Steps Attempted:
1.
2.
3.

Expected behaviour : Indicator visible in ThreatIntelIndicators/ThreatIntelObjects and reflected in the dependent rule/query within 15 minutes of ingestion rule changes, or immediately for direct ingestion
Actual behaviour   :
```

---

## 🎓 Learning Pointers

- **The single highest-value check in this entire topic is confirming which table a query, rule, or workbook targets.** The legacy `ThreatIntelligenceIndicator` table stopped receiving new data on **2025-07-31** — a cutover now well over a year old as of this runbook — yet it's still fully queryable for historical data, so a stale reference doesn't throw an error, it just silently stops seeing anything new. Any client environment with home-grown TI dashboards or custom analytics rules predating that cutover is a strong candidate for this exact failure mode. [Threat intelligence in Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/understand-threat-intelligence)
- **Ingestion rules have a scope boundary that's easy to assume away.** They only ever touch data-connector-sourced TI — never Upload API submissions, never manually created objects. A client asking "why didn't my ingestion rule filter this indicator" is very often looking at an object that arrived through a path the rule was never able to see in the first place.
- **The legacy TIP data connector is a dead end, not a bug to keep chasing.** Microsoft has explicitly marked it for deprecation in favor of the Upload API, which uses the STIX-standardized schema natively and requires no data connector at all. Time spent debugging a flaky TIP integration is usually better spent migrating it.
- **Deduplication is Id-based, not content-based.** `Id` is a concatenation of the base64-encoded `SourceSystem` and the object's `stixId` — reingesting the same object (which happens automatically every 7–10 days for query-optimization purposes) is expected and simply refreshes `TimeGenerated`, not a sign of pipeline instability.
- **TLP (Traffic Light Protocol) sensitivity is straightforward in the UI but not in the API.** Setting TLP through the Upload API requires selecting one of four fixed `marking-definition` object GUIDs rather than a plain string — a common integration mistake worth checking early if TLP values aren't landing as expected on API-submitted objects.
- **Community/reference:** [Work with threat intelligence in Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/work-with-threat-indicators) | [Connect your threat intelligence platform using upload API](https://learn.microsoft.com/en-us/azure/sentinel/connect-threat-intelligence-upload-api) | [Threat intelligence integration catalog](https://learn.microsoft.com/en-us/azure/sentinel/threat-intelligence-integration)
