# Project Online Retirement — Agent Instructions

## What's in this folder

Coverage of the retirement of **Project Online** (the SharePoint-based Project Web App / PWA product) on **September 30, 2026** — the confirmed, multi-stage retirement timeline (MC812729), the two-layer data-architecture fact that decides what's actually at risk (SharePoint project-site content survives; Project Online's own structured schedule/resource-pool/timesheet data does not, and has no admin-facing bulk-export button), the official per-user export tool and its bulk-scope limitation, the OData API's independent HTTP-410 death, and the migration-destination landscape (Planner Premium, Project Plan 3/5 desktop, Project Server Subscription Edition, Dynamics 365 Project Operations) with an honest capability-gap comparison. This is a **different, unrelated product** from Project for the web (already retired into Planner, August 2025, no action needed) — see `M365/Planner/Planner-A.md`/`-B.md` for that product and its own disambiguation coverage; this folder is the deep-dive on the genuinely-retiring one.

---

## Before responding, also check

- `M365/_AGENT.md` — general M365 agent context and cross-service dependencies
- `M365/Planner/Planner-A.md`/`-B.md` — Project for the web's own (already-completed, no-action) August 2025 retirement, and the standing client-facing disambiguation between the two "Project" retirement stories (Planner-B.md Fix 8)
- `EntraID/` — if the underlying ask is Entra role/license administration around a Project Online license removal, rather than the retirement itself
- SharePoint admin documentation generally, if the question is actually about SharePoint project-site content (which survives this retirement unaffected) rather than Project Online's own structured data

---

## Folder contents

| File | What it covers |
|------|---------------|
| `ProjectOnline-Retirement-B.md` | Hotfix runbook — triage in under 10 min: confirm which "Project" product is meant, confirm active PWA usage, per-user export (official tool), full-portfolio OData export, broken Power BI/Excel reports, stuck timesheet approvals, license cleanup after retirement, post-retirement recovery triage |
| `ProjectOnline-Retirement-A.md` | Deep dive reference — full multi-stage retirement timeline and architecture rationale, the two-layer (SharePoint vs. Project-Online-native) data model, dependency stack, Symptom→Cause map, four remediation playbooks (bulk per-user export loop, timesheet compliance archive, destination decision framework with capability table, MSP fleet-wide proactive sweep) |
| `Scripts/Get-ProjectOnlineRetirementReadiness.ps1` | SharePoint Online Management Shell script — read-only PWA site inventory, days-remaining calculation against both the practical (Sep 1) and hard (Sep 30) 2026 deadlines, optional Microsoft Graph cross-reference of Project Online/Project Plan license assignments (flags disabled accounts still holding a license). Does not export or touch any project data — see the `-A.md` Playbook 1 for the actual export procedure. |

---

## Common entry points

- "Is Project/Planner shutting down?" / "client is panicking about a Planner shutdown" → `ProjectOnline-Retirement-B.md` Fix 1 — confirm which product first; Project for the web (Aug 2025, done, no action) is very frequently confused with Project Online (Sept 30 2026, real, needs migration)
- "Need to export a specific user's Project Online data" → `ProjectOnline-Retirement-B.md` Fix 2 — official `ExportProjectUserContent.ps1` tool, **per-user only**
- "Need to export/back up the whole portfolio, not just one person" → `ProjectOnline-Retirement-B.md` Fix 3 + `ProjectOnline-Retirement-A.md` Playbook 1 — the official tool doesn't do bulk; loop it or pull the OData API directly before retirement
- "Power BI dashboard/report built on Project Online stopped working" → `ProjectOnline-Retirement-B.md` Fix 4
- "Timesheet approvals stuck / compliance retention concern for timesheet history" → `ProjectOnline-Retirement-B.md` Fix 5 + `ProjectOnline-Retirement-A.md` Playbook 2 (emergency compliance-archive path)
- "Still being billed for Project Online after it retired" → `ProjectOnline-Retirement-B.md` Fix 6 — service retiring does NOT auto-cancel the license; manual removal required
- "Project Online is already gone, what's recoverable?" → `ProjectOnline-Retirement-B.md` Fix 7 — SharePoint project-site content survives; unexported structured project data generally does not
- "Which migration destination should a client move to?" → `ProjectOnline-Retirement-A.md` Playbook 3 — capability-gap comparison table (Planner Premium / Project Plan 3-5 / Project Server Subscription Edition / Dynamics 365 Project Operations); do not default to Planner without confirming the client doesn't need ERP/timesheets/stage-gates
- "MSP wants to sweep its whole client book ahead of the deadline" → `ProjectOnline-Retirement-A.md` Playbook 4
- "How much time is actually left / what's the real deadline" → `Scripts/Get-ProjectOnlineRetirementReadiness.ps1` — computes both the practical (Sep 1, 2026) and hard (Sep 30, 2026) deadlines against the current date live, rather than trusting a cached date from an earlier conversation

---

## Key diagnostic commands

```powershell
# Confirm whether the tenant has any active Project Online (PWA) usage at all —
# run this FIRST, before assuming a migration project is even needed
Connect-SPOService -URL https://<tenant>-admin.sharepoint.com
Get-SPOSite | ?{$_.PWAEnabled -eq "Enabled"} | ft -a Url,Owner

# Confirm the OData reporting API is still live (pre-retirement only) —
# returns HTTP 410 Gone once the service has retired
# Browse to: https://<tenant>.sharepoint.com/sites/pwa/_api/ProjectData/Projects

# Confirm Project Online / Project Plan license assignments needing manual cleanup
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "PROJECT" } |
    Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits
```

---

## Key dependency chain

```
Project Web App (PWA) — hosted ON TOP OF SharePoint Online
    │
    ├── SharePoint project sites (documents, lists) ── ordinary SPO content,
    │      SURVIVES retirement unaffected
    │
    └── Project Online's OWN structured data (Draft/Published/Reporting schemas)
           ── tasks, dependencies, baselines, custom fields, Enterprise Resource
              Pool, timesheet history — NO direct SQL/bulk-export access, NO
              survival path unless exported before Sept 30, 2026
           │
           ├── OData reporting API (/_api/ProjectData/*) → feeds Power BI/Excel
           │      (HTTP 410 Gone at retirement — independent grace period, none)
           │
           └── Official per-user export tool (ExportProjectUserContent.ps1)
                  → per-user JSON/XML/MPP output — NOT a tenant-wide bulk tool
```

---

## Response format reminder (always 3 layers)

1. **Triage first** — confirm which "Project" product is actually meant (this folder vs. Planner/Project for the web), and confirm the current date against both the September 1 practical and September 30 hard 2026 deadlines before assessing urgency.
2. **Fix or explain** — most tickets are either the product-disambiguation question (resolves immediately) or an export/migration-scoping need (route to the appropriate Fix/Playbook, and flag as a project-level engagement, not a quick ticket, once active usage is confirmed).
3. **Confirm resolution** — for export work, spot-check output completeness (Playbook 1); for migration-destination questions, confirm the capability-gap table has been reviewed against the client's actual usage before a destination is finalized.
