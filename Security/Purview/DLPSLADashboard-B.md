# Purview DLP SLA Alert Reporting Dashboard — Hotfix Runbook (Mode B: Ops)
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

> **Source-confidence note:** as of this writing, this feature (Microsoft 365 Roadmap ID 568372) has no dedicated Microsoft Learn conceptual page — it is documented only via the Microsoft 365 Roadmap listing and dated secondary sources (Preview target August CY2026, GA target September CY2026, Worldwide standard multi-tenant cloud). The dashboard's exact MTTA/MTTD/MTTR calculation boundaries (which lifecycle-stage timestamps define "start" and "end" for each metric) are **not yet officially documented**. Re-verify against the live Purview portal and any subsequently published Learn page before quoting exact metric definitions to a client.

---

## Triage

Run these within the first 60 seconds to classify the problem. The dashboard itself is a **portal-only reporting surface** (Data Loss Prevention > Alerts > SLA dashboard, naming may vary by rollout wave) with no documented PowerShell/Graph read API. Triage leans on the same underlying alert data the dashboard is built from.

```powershell
# Connect to Security & Compliance PowerShell
Connect-IPPSSession -UserPrincipalName <adminUPN>

# 1. Is there actually alert volume for the dashboard to report on?
Get-ProtectionAlert | Where-Object { $_.AlertType -eq "DLP" -and $_.LastUpdatedTime -gt (Get-Date).AddDays(-30) } |
    Select-Object Name, Severity, Status, Count, LastUpdatedTime | Sort-Object LastUpdatedTime -Descending

# 2. Who can see the dashboard? (same role gate as other DLP alert-operations features)
Get-RoleGroupMember -Identity "DLP Compliance Management"
Get-RoleGroupMember -Identity "View-Only DLP Compliance Management"

# 3. Tenant licensing signal for aggregate/threshold-based alerting (affects what feeds the dashboard)
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "SPE_E5|ENTERPRISEPREMIUM|IDENTITY_THREAT_PROTECTION|M365_E5_SUITE_COMPONENTS" } |
    Select-Object SkuPartNumber, PrepaidUnits, ConsumedUnits

# 4. Approximate the metrics manually from raw alert timestamps as a sanity check
#    (proxy only — the portal dashboard's own boundary definitions are not published)
Get-ProtectionAlert | Where-Object { $_.AlertType -eq "DLP" -and $_.LastUpdatedTime -gt (Get-Date).AddDays(-30) } |
    Select-Object Name, Severity, Status, CreatedTime, LastUpdatedTime,
        @{N='AgeHours';E={ [math]::Round(((Get-Date) - $_.CreatedTime).TotalHours,1) }}
```

**Interpretation:**

| Result | Meaning | Next step |
|--------|---------|-----------|
| Dashboard not visible in the portal at all | Tenant hasn't received the Preview/GA rollout yet (target: Preview Aug CY2026, GA Sept CY2026) | Go to Fix 3 |
| Dashboard visible but shows no data / "insufficient data" | Little or no recent DLP alert volume, or alert data hasn't backfilled yet for a newly-enabled tenant | Go to Fix 1 |
| Custom SLA thresholds (high/med/low) not saving or not applying | Portal configuration issue — no PowerShell path exists to set these; treat as a UI bug candidate once ruled out as user error | Go to Fix 2 |
| Metrics look implausible (e.g., MTTA of 0 seconds for everything) | Likely a metric-definition misunderstanding rather than a data bug — see source-confidence note above | Go to Fix 4 |
| `Get-RoleGroupMember` shows the requester isn't in either DLP role | RBAC gap — dashboard visibility requires DLP Compliance Management or View-Only DLP Compliance Management | Go to Fix 5 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
[Microsoft Purview DLP subscription] (any DLP-licensed tier for base alerting;
                                        A5/E5/G5 or add-on for aggregate/threshold alerts)
        └── [DLP policies generate alerts] (Get-ProtectionAlert-visible records)
              └── [Alerts flow to the Purview DLP Alerts dashboard] (30-day retention)
                    └── [SLA Alert Reporting Dashboard] (NEW — Roadmap 568372,
                          Preview Aug 2026 / GA Sept 2026, Worldwide standard
                          multi-tenant, Purview portal only, no cmdlet surface)
                          ├── requires "Manage alerts"-equivalent visibility —
                          │     DLP Compliance Management or View-Only DLP
                          │     Compliance Management role
                          ├── [Out-of-box metrics]: MTTA / MTTD / MTTR trends,
                          │     Top Sensitive Information Types (SITs) exposed
                          └── [Custom SLA definitions]: admin-set thresholds
                                per severity (High / Medium / Low)
```

This dashboard is a **read/reporting layer** over the same alert data already produced by existing DLP policies — it introduces no new detection, enforcement, or alert-generation behavior of its own. A tenant with low or no DLP alert volume will see a sparse or empty dashboard regardless of configuration; that is expected, not a defect.

</details>

---

## Diagnosis & Validation Flow

1. **Confirm the feature is present in this tenant.**
   Purview portal → Data Loss Prevention → Alerts → look for an SLA dashboard tab/view.
   *Good:* visible. *Bad:* not yet rolled out — this is a staged-rollout timing gap (Preview Aug 2026, GA Sept 2026), not a misconfiguration.

2. **Confirm there's enough underlying alert data.**
   `Get-ProtectionAlert` (Triage step 1) for the last 30 days.
   *Good:* meaningful alert volume exists. *Bad:* sparse/no data — the dashboard has nothing to compute trends from; this is expected behavior for a low-alert-volume tenant, not a bug.

3. **Confirm role-based access for the person reporting the issue.**
   `Get-RoleGroupMember` (Triage step 2).
   *Good:* requester is a member of DLP Compliance Management or View-Only DLP Compliance Management. *Bad:* not a member — this is an RBAC gap, not a dashboard defect.

4. **Sanity-check reported metrics against raw alert timestamps.**
   Since the dashboard's exact metric-boundary definitions aren't yet officially published, cross-check a specific alert's `CreatedTime`/`LastUpdatedTime`/`Status` progression (Triage step 4) against the dashboard's reported value for that same alert where possible, rather than assuming either source is definitively correct.

---

## Common Fix Paths

<details><summary>Fix 1 — Dashboard shows no/insufficient data</summary>

1. Confirm real alert volume exists via `Get-ProtectionAlert` — if genuinely low, this is expected and not fixable via configuration.
2. For a newly-enabled tenant, allow time for historical backfill; Microsoft has not published a specific backfill window for this feature, so treat "wait and re-check in 24-48 hours" as the working assumption until documented otherwise.
3. If alert volume is clearly present but the dashboard still reports empty, treat as a Preview-wave defect candidate and proceed to escalation.

**Rollback:** none — no configuration change was made.

</details>

<details><summary>Fix 2 — Custom SLA thresholds won't save</summary>

1. Re-attempt in the Purview portal, confirming the account has the required role (Fix 5).
2. Try a simpler threshold value first (e.g., a round-number hour boundary) to rule out an input-validation edge case.
3. No PowerShell/Graph path exists to set SLA thresholds as a workaround — if the portal UI is confirmed broken after role and input checks, this is a support-case item, not something scriptable around.

**Rollback:** none needed — thresholds are configuration only, not destructive.

</details>

<details><summary>Fix 3 — Feature not present in the portal yet</summary>

1. Confirm tenant cloud environment — Worldwide standard multi-tenant is the initial target; GCC/GCC High/DoD and sovereign clouds are not confirmed in this wave as of this writing.
2. Confirm current date against the Preview (Aug 2026) / GA (Sept 2026) target window — there is no tenant-level switch to force early access.
3. Set client expectations accordingly; this pairs with the sibling `DLPAlertAutoResolution-B.md` feature (Roadmap 568371) from the same DLP alert-operations wave, which follows the same rollout pattern — if that feature is also absent, it further confirms a rollout-timing gap rather than an isolated bug.

</details>

<details><summary>Fix 4 — Reported metrics look implausible</summary>

1. Do not assume the metric is wrong before confirming what it's actually measuring — MTTA/MTTD/MTTR boundary definitions are not yet officially published for this specific dashboard (see source-confidence note).
2. Cross-check one specific alert manually (Diagnosis step 4) rather than judging the aggregate trend in isolation.
3. If a specific alert's dashboard-reported time clearly contradicts its own `CreatedTime`/`LastUpdatedTime` values (e.g., a negative duration, or a duration exceeding the alert's total age), this is a genuine defect candidate — escalate with both values captured side by side.

</details>

<details><summary>Fix 5 — Requester lacks dashboard visibility (RBAC gap)</summary>

```powershell
Get-RoleGroupMember -Identity "DLP Compliance Management"
Get-RoleGroupMember -Identity "View-Only DLP Compliance Management"
```

Add the requester to **View-Only DLP Compliance Management** if they only need to view the dashboard, rather than the full management role — the standard least-privilege split used consistently across this repo's other Purview DLP alert-operations topics.

</details>

---

## Escalation Evidence

```
=== Purview DLP SLA Dashboard — Escalation Packet ===
Tenant:
Ticket #:
Date/Time (UTC):

1. Dashboard visibility in Purview portal (Data Loss Prevention > Alerts): Present / Absent
2. Cloud environment: Worldwide / GCC / GCC High / DoD / Other: ____________
3. Get-ProtectionAlert output for the last 30 days (attach):
4. Specific alert ID(s) with implausible metric values, plus their raw CreatedTime/LastUpdatedTime (attach):
5. Custom SLA threshold values attempted, if applicable: ____________
6. Get-RoleGroupMember output for both DLP roles (attach):
7. Licensing SKU confirmation (Get-MgSubscribedSku, attach):
8. Whether sibling feature DLPAlertAutoResolution (Roadmap 568371) is present in this tenant: Yes / No
9. Prior fix paths attempted from this runbook: ____________
```

---

## 🎓 Learning Pointers

- This dashboard is a **reporting layer only** — it introduces no new DLP detection, alerting, or enforcement behavior. A sparse dashboard on a low-alert-volume tenant is expected, not a defect.
- Treat the exact MTTA/MTTD/MTTR calculation boundaries as **unpublished** until Microsoft ships a dedicated Learn page — this repo deliberately avoids fabricating a precise definition and instead cross-checks specific alerts manually when a value looks wrong. See [Get started with data loss prevention alerts](https://learn.microsoft.com/en-us/purview/dlp-alerts-get-started) for the underlying, well-documented alert model this dashboard reports on.
- This feature ships in the same Roadmap wave as `DLPAlertAutoResolution-A.md`/`-B.md` (Roadmap 568371) — if one is present in a tenant's portal, the other is a reasonable candidate to also check for, and vice versa if one is unexpectedly absent.
- Custom SLA thresholds are portal-configuration only; there is no scripted or bulk-configuration path as of this writing, so treat threshold-setting issues as UI-support items rather than automation candidates.
- Dashboard visibility follows the same RBAC gate as other DLP alert-operations features (DLP Compliance Management / View-Only DLP Compliance Management) — always confirm role membership before treating a "can't see the dashboard" report as a product defect.
