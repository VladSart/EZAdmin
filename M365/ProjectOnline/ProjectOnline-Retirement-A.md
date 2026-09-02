# Project Online Retirement — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **Project Online** (the SharePoint-based Project Web App / PWA product), its confirmed retirement on **September 30, 2026**, the data-loss mechanics behind that retirement, official and practical export paths, and the migration-destination landscape Microsoft has pointed customers toward. It assumes:

- The reader already knows Project Online is distinct from **Project for the web** (retired as a standalone app August 2025, folded into Microsoft Planner Premium with zero migration required — see `M365/Planner/Planner-A.md`, which documents that event and this runbook's disambiguation only in passing). This runbook is the deep-dive on the genuinely-retiring product; Planner's own runbooks intentionally do not duplicate this depth.
- A PWA site's presence has already been confirmed (`Get-SPOSite | ?{$_.PWAEnabled -eq "Enabled"}`) — this is not a "does the client even use this" runbook, it assumes active or recent usage.
- **Research/build date for this runbook is September 2, 2026** — inside the practical export window but past the informally-cited "start now" recommendation from most third-party migration guidance. Any reader using this runbook should recompute days-remaining against the actual current date, not assume this date still applies.

**Explicitly out of scope:** step-by-step configuration of any specific destination platform (Project Server Subscription Edition farm deployment, Dynamics 365 Project Operations setup, or third-party tools like FluentPro FluentBooks/ShareGate/Onplana) — those are each their own multi-week engagements with their own documentation. This runbook covers the retirement mechanics, the export/evidence-gathering work that is common to every destination choice, and the decision framework for choosing between them.

---
## How It Works

<details><summary>Full architecture — why the retirement exists and what actually breaks</summary>

**Why Project Online is retiring.** Project Online is built on an architecture that predates modern SharePoint/Microsoft 365 development patterns — it is fundamentally a SharePoint-hosted application (Project Web App, "PWA") backed by its own SQL Server-derived data model (the Draft, Published, and Reporting schemas), a legacy that traces back to on-premises Project Server. Microsoft's own stated rationale (Tech Community announcement, plannerblog) is that this architecture limits the pace of innovation and integration Microsoft wants to deliver through Planner, Microsoft 365 Copilot, and the Project Manager agent — newer, natively cloud/AI-native surfaces. A contributing structural factor: **SharePoint 2013 workflows**, which power several of Project Online's governance features (notably Enterprise Project Type / EPT approval workflows), are themselves being deprecated tenant-wide in 2026 — Project Online's own governance layer depends on infrastructure Microsoft is removing regardless of Project Online's own fate.

**The two-layer data model is the single most important architectural fact for this runbook.** PWA is *hosted on* SharePoint Online, which creates a persistent point of confusion: PWA site collections look and feel like SharePoint, and each project can have an associated SharePoint project site (documents, issue lists, risk registers). But Project Online's own structured data — task schedules, dependencies, baselines, custom field values, the Enterprise Resource Pool, and timesheet history — lives in Project Online's **own backend data schemas**, not as SharePoint list items. Microsoft has never exposed direct SQL or bulk-database access to this layer for cloud (Project Online) customers — the only sanctioned extraction paths are the OData reporting API and the per-project/per-user `.mpp`/`.xml`/`.json` export tooling. When Project Online retires, the **SharePoint layer survives** (it's ordinary SharePoint Online content, unaffected by this retirement) but the **Project Online data layer is decommissioned with the rest of the service** — there is no announced post-retirement recovery path for unexported data of this kind.

**Timeline mechanics — this has been a multi-stage rollout, not a single cutover date:**

| Date | Event |
|---|---|
| 2024-07-10 | Microsoft publishes Message Center notice **MC812729** — the original, authoritative retirement announcement. The September 30, 2026 date has not changed since. |
| 2025-10-01 (approx.) | New sales of **Project Online Professional** and **Project Online Premium** subscriptions stop. Existing subscriptions continue billing and functioning until the hard cutover — but cannot be renewed past it. |
| 2026-04-01 | New Project Web App (PWA) **site creation** is blocked tenant-wide. Existing PWA sites are unaffected at this stage. |
| 2026-04-02 | **SharePoint 2013 workflows** powering Project Online's EPT (Enterprise Project Type) approval/governance workflows stop functioning — this is a side effect of the broader SharePoint 2013 workflow deprecation, not a Project-Online-specific announcement, and is easy to miss if only watching Project-Online-specific Message Center posts. |
| 2026-09-01 (practical, unofficial) | **The realistic export deadline.** Third-party migration guidance uniformly recommends treating this date — not September 30 — as the last safe day to complete exports, leaving a buffer against server-side throttling as many tenants export simultaneously in the final weeks, and against the unconfirmed nature of any post-retirement grace window. |
| 2026-09-30 | **Hard cutover.** PWA stops serving pages, the OData endpoint (`/_api/ProjectData/*`) returns HTTP 410 Gone, the Enterprise Resource Pool becomes unreachable, timesheet workflows stop, and the Desktop Client's online/PWA sync features (check-in/out, publish, resource sync) stop working. Locally saved `.mpp` files and the Desktop Client itself continue to function for **local-only** use. |
| Post-2026-09-30 (unconfirmed) | An informal ~90-day **read-only** access window has followed some past Microsoft SaaS retirements, historically. **No SLA, contract clause, or Microsoft communication for this specific retirement guarantees this window will occur.** Treat any access after September 30 as a courtesy, never as the basis of a migration plan. |

**What does NOT stop:** the Microsoft 365 tenant itself, all other M365 apps, SharePoint project sites and their documents/lists (ordinary SharePoint Online content, no special Project Online dependency for basic file access), and any `.mpp` file already saved locally to a user's machine (openable indefinitely in the Desktop Client or, going forward, Project Plan 3/5's desktop app, for **local editing only** — no PWA round-trip).

</details>

---
## Dependency Stack

```
Layer 4 — Consumption / Reporting
    Power BI reports, Excel Pivot/Power Query, custom dashboards
    reading https://<tenant>.sharepoint.com/sites/pwa/_api/ProjectData/*
        ↓ depends on
Layer 3 — Project Online OData Reporting API
    /_api/ProjectData/Projects, /Resources, /TimesheetLines, /Assignments, etc.
    (returns HTTP 410 Gone the instant the service retires — no separate
     grace period documented distinct from the PWA courtesy window)
        ↓ depends on
Layer 2 — Project Online structured data (own backend schemas — NOT SharePoint)
    Draft schema, Published schema, Reporting schema
    ├─ Task schedules, dependencies, baselines, custom fields
    ├─ Enterprise Resource Pool (ERP) — cost rates, calendars, skills
    └─ Timesheet history + in-flight approval workflow state
        ↓ hosted by
Layer 1 — Project Web App (PWA) application layer
    https://<tenant>.sharepoint.com/sites/pwa
    ├─ Server Settings, Resource Center, Security groups/categories
    └─ EPT workflows (dependent on SharePoint 2013 workflow engine —
         already broken as of 2026-04-02, independently of the Sep 30 cutover)
        ↓ runs on top of
Layer 0 — SharePoint Online (hosting substrate)
    SharePoint project sites (documents, issue lists, risk registers)
        — ORDINARY SharePoint content, survives retirement unaffected —
    SharePoint Online tenant itself — unaffected by this retirement
```

**Read this stack top-down for "what breaks and when":** Layers 1–3 die together at the September 30, 2026 hard cutover (Layer 1's EPT workflow sub-component died earlier, April 2, 2026, as an independent SharePoint 2013 side effect). Layer 4 dies as a consequence of Layer 3's death — any Layer 4 asset not redirected before the cutover simply stops refreshing. **Layer 0 is architecturally distinct and unaffected** — this is the fact that resolves most "is my data safe" anxiety once correctly explained.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Client asks "is Planner shutting down too?" | Confusing Project Online with Project for the web/Planner Premium (already retired Aug 2025, no action needed) | Confirm which product; see `M365/Planner/Planner-A.md` §Retirement Timeline |
| PWA site returns a service-decommissioned page | Retirement has occurred (past Sept 30, 2026) or the tenant's PWA was already deprovisioned | Check current date against 2026-09-30; confirm via `Get-SPOSite` whether the site record still exists at all |
| EPT/governance workflow approvals silently stop advancing | SharePoint 2013 workflow deprecation (broke 2026-04-02) — independent of the main Sept 30 cutover | Confirm workflow type; this is not fixable, only routable to a manual/alternative approval process |
| Power BI report/dashboard stopped refreshing | OData endpoint returned HTTP 410 Gone (service retired) or was already unreachable | Confirm retirement date has passed; check `.pbix` data source settings for the `/_api/ProjectData/` URL |
| "We tried to create a new project site and can't" | New PWA site creation has been blocked tenant-wide since 2026-04-01 | Confirm this is a *new site* attempt, not an existing-site access issue — existing sites were unaffected at that stage |
| Timesheet approval stuck mid-workflow | Timesheet workflows stopped at the hard cutover (Sept 30, 2026) with in-flight items left incomplete | Confirm cutover date has passed; there is no completion path for items left in flight across the boundary |
| Invoice still shows Project Online Professional/Premium charges after retirement | Manual license removal was never performed — the service retiring does not cancel the subscription | M365 admin center → Billing → Licenses; remove/reassign manually |
| Can't buy a new Project Online license for a new hire | New sales of these SKUs stopped ~October 2025 | Confirm intent — likely needs Project Plan 3/5 (desktop-only) or a Planner Premium seat instead, not a Project Online SKU |
| `.mpp` file "won't sync" / "can't check in" post-cutover | Desktop Client's online/PWA sync depends on the now-retired PWA backend | Confirm the file still *opens* locally (it should) — only the server round-trip is gone, not the file |

---
## Validation Steps

1. **Confirm PWA site inventory (tenant-wide).**
   ```powershell
   Connect-SPOService -URL https://<tenant>-admin.sharepoint.com
   Get-SPOSite | ?{$_.PWAEnabled -eq "Enabled"} | ft -a Url,Owner,StorageUsageCurrent
   ```
   Good output: a table of every PWA site collection. Bad/concerning: any site with unexpectedly high `StorageUsageCurrent` that hasn't been scoped for migration yet — flag for the inventory phase.

2. **Confirm license posture.**
   M365 admin center → Billing → Licenses → filter "Project Online" / "Project Plan". Good: count matches expected active user base. Bad: licenses assigned to accounts that are disabled/departed — these still count toward the manual-cleanup obligation regardless of active use.

3. **Confirm days remaining against both deadlines.**
   Recompute `(2026-09-01 minus today)` and `(2026-09-30 minus today)` from the actual current date at time of reading — do not trust a cached calculation from a prior conversation or an earlier draft of this runbook.

4. **Confirm OData endpoint is still live (pre-retirement only).**
   Browse to `https://<tenant>.sharepoint.com/sites/pwa/_api/ProjectData/Projects` while authenticated. Good: an XML/Atom feed of projects. Bad: HTTP 410 Gone (retirement has occurred) or HTTP 403 (permissions issue, not retirement — investigate separately).

5. **Confirm timesheet workflow state.**
   In PWA: Server Settings → Time and Task Management → Manage Timesheet Periods. Good: no open periods past their expected close date. Bad: multiple open/pending periods this close to the cutover — escalate to Playbook 2 (compliance archive) immediately.

6. **Confirm Power BI/Excel report inventory.**
   There is no tenant-wide discovery tool for this — it requires asking data/reporting owners directly which dashboards point at the Project Online OData feed. Treat "we don't think we have any" answers with skepticism; this is consistently under-reported in migration retrospectives per third-party guidance.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Pre-migration discovery (should start immediately if not already underway):**
1. Run the PWA site inventory (Validation Step 1) across every site collection.
2. For each site, inventory: active project count, custom fields in use, resource pool size, whether EPT/governance workflows are relied on (already degraded since April 2026 — confirm current workaround state), and whether timesheet workflows are in active use.
3. Identify every downstream consumer of the OData feed (Power BI, Excel, Power Automate flows, custom scripts) — this step alone commonly surfaces 30–50% more scope than an initial estimate, per third-party migration guidance; treat that figure as a planning heuristic, not a guarantee.

**Phase 2 — Export execution (target completion well before Sept 1, 2026 practical deadline):**
1. Run the official per-user export (`ExportProjectUserContent.ps1`, Fix 2 in Mode B) across every active resource — see Playbook 1 for a looping approach across a resource list.
2. Pull full-portfolio OData data directly (Playbook — Evidence Pack script) for resource pool, timesheets, and cross-project fields the per-user tool won't cleanly aggregate.
3. Archive timesheet history separately if any compliance retention obligation applies (SOX, ISO 9001, contractual audit clauses) — do not assume the per-user export alone satisfies a retention requirement without confirming with the client's compliance/finance stakeholder.
4. Capture Project Home favorites/recently-viewed via screenshot (no API exists for this data) for any user who specifically needs it preserved.

**Phase 3 — Destination decision and migration (see Remediation Playbooks 3–4):**
1. Score the destination options (below) against the client's actual usage pattern — do not default to "Planner, since Microsoft recommends it" without confirming the capability gaps are acceptable.
2. Pilot with 3–5 real projects in the chosen destination before committing the full portfolio.
3. Migrate in waves; archive (rather than migrate) historical/closed projects where feasible to reduce scope.

**Phase 4 — Cutover and cleanup:**
1. Freeze new writes to Project Online once the destination is validated and the team has switched over.
2. Remove/reassign Project Online Professional/Premium licenses no longer needed (Mode B Fix 6).
3. Redirect or rebuild any Power BI/Excel reports that pointed at the now-dead OData feed.
4. Confirm no in-flight timesheet approvals remain open across the cutover boundary.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Bulk per-user export across an entire resource list</summary>

**When to use:** The official `ExportProjectUserContent.ps1` tool (Mode B Fix 2) only exports one user at a time. For a PWA site with dozens or hundreds of active resources, this needs to run in a loop rather than be invoked manually per person.

1. Pull the full resource list for the PWA site (PWA → Server Settings → Enterprise Data → Resource Center, or via the `Resource` OData entity while the endpoint is still live).
2. Export resource login names to a CSV (`LoginName` column, one row per user).
3. Loop the official script across the list:
   ```powershell
   $resources = Import-Csv .\pwa-resources.csv
   foreach ($r in $resources) {
       .\ExportProjectUserContent.ps1 `
           -Url https://<tenant>.sharepoint.com/sites/pwa `
           -LoginName $r.LoginName `
           -OutputDirectory "C:\ProjectOnlineExport\$($r.LoginName -replace '[\\/:*?""<>|@]','_')"
   }
   ```
4. Spot-check a sample of output folders for completeness (project list XML files present, feature JSON files non-empty where expected) before considering the export phase done.
5. **No rollback needed** — this is a read-only export operation against the live service; it does not modify Project Online data.

</details>

<details><summary>Playbook 2 — Timesheet compliance archive (emergency, deadline-imminent path)</summary>

**When to use:** Compliance/audit retention requirements exist for timesheet history (commonly 3+ years under SOX or ISO 9001 scopes) and the export deadline is close or has already passed the September 1 practical cutoff.

1. Immediately pull the `Timesheets` and `Timesheets_Reporting` feature JSON files via the per-user export (Playbook 1) for every resource with timesheet history, or pull the `TimesheetLines` OData entity directly if bulk speed is needed and the endpoint is still live.
2. Store the export in a location the organization controls independently of Microsoft 365 (this data does not sync anywhere else automatically and will not exist in the destination platform unless explicitly imported).
3. Document the export date, scope (which PWA site, which date range), and method used — this documentation is often what an auditor actually asks for, separately from the raw data itself.
4. If any timesheet periods are still open/pending approval, force-complete or explicitly reject them before the cutover (Mode B Fix 5) — items left in flight do not resume after retirement.
5. **Rollback note:** none required — archival is additive and does not alter the live system.

</details>

<details><summary>Playbook 3 — Destination decision framework</summary>

**When to use:** Before committing to a migration target. Do not let this default silently to "whatever Microsoft's blog post recommends first."

| Capability | Project Online | Planner (Premium, 2026) | Project Plan 3/5 (desktop) | Project Server Subscription Edition | Dynamics 365 Project Operations |
|---|---|---|---|---|---|
| Enterprise Resource Pool | Yes | No | No | Yes | Yes (via D365 resourcing) |
| OData/reporting API | Yes | Limited | No | Yes (on-prem equivalent) | Yes (Dataverse) |
| Timesheet workflows | Yes | No | No | Yes | Yes |
| Stage-gate governance / PDPs | Yes | No | No | Yes | Partial |
| Cross-portfolio rollup | Yes | Limited | No | Yes | Yes |
| Multi-project critical path/baseline | Yes | No | Single project only | Yes | Partial |
| Infrastructure ownership | Microsoft-hosted | Microsoft-hosted | N/A (desktop only) | **Customer-hosted** (new farm required) | Microsoft-hosted (Power Platform) |

**Reading this table honestly:** Planner and Project Plan 3/5 are Microsoft's most-promoted paths but leave real gaps for any client that used Project Online's enterprise governance features — do not present either as a like-for-like replacement without confirming the client doesn't need ERP, multi-project rollup, or timesheet workflows. Project Server Subscription Edition is the closest architectural match but requires deploying and operating an entirely new SharePoint Server SE farm — third-party estimates put this at **3–6 months and a wide consulting-cost range**; treat any specific cost figure as vendor-sourced and unverified until confirmed against the client's own procurement quotes, not as an EZAdmin-endorsed number. Dynamics 365 Project Operations fits clients that need financial/resourcing portfolio management specifically, at the cost of a genuinely different product and licensing model, not a migration in the narrow sense.

Third-party migration tooling (FluentPro FluentBooks, ShareGate, and others) exists for the PSSE and SharePoint-content paths specifically — these are commercial products, not Microsoft-built or Microsoft-endorsed, and should be independently evaluated per engagement rather than assumed reliable from vendor marketing alone.

</details>

<details><summary>Playbook 4 — MSP fleet-wide proactive sweep ahead of the cutover</summary>

**When to use:** An MSP managing multiple client tenants wants to get ahead of the September 30, 2026 deadline across its entire book, not just react to individual tickets.

1. Run the PWA site inventory (Validation Step 1) against every managed tenant — do not rely on client self-reporting of Project Online usage, since it is commonly forgotten or unknown to newer client-side IT contacts.
2. For every tenant with an active PWA site, open a dated internal tracking record: site URL, project count, resource count, timesheet-in-use flag, and current phase (Discovery / Export / Destination-decided / Migrated / Cutover-confirmed).
3. Prioritize outreach by proximity to the September 1 practical deadline, not just the September 30 hard date — a tenant discovered with no started export work inside the final two weeks needs an emergency-path conversation (Playbook 2 framing), not a routine scheduling email.
4. After each tenant's export/migration is confirmed complete, close the loop with license cleanup (Mode B Fix 6) as its own explicit checklist item — this is the step most likely to be forgotten once the "real" migration work is done.
5. **Rollback note:** this playbook is purely a tracking/outreach exercise and makes no changes to any client tenant on its own.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Read-only discovery pass across a tenant's Project Online footprint —
    NOT a data export tool. Run this first to scope the real work before
    committing to Playbook 1/2/3 timelines.
.DESCRIPTION
    Requires SharePoint Online Management Shell and a SharePoint admin
    connection. Confirms PWA site inventory, days remaining against both
    the practical (Sep 1) and hard (Sep 30) 2026 deadlines, and flags
    Project Online license assignments for the manual-cleanup checklist.
    Does not touch, modify, or export any Project Online project data.
#>
Connect-SPOService -URL https://<tenant>-admin.sharepoint.com

$pwaSites = Get-SPOSite | Where-Object { $_.PWAEnabled -eq "Enabled" }

$exportDeadline  = Get-Date "2026-09-01"
$hardCutover     = Get-Date "2026-09-30"
$today           = Get-Date

[PSCustomObject]@{
    PWASitesFound          = $pwaSites.Count
    DaysToExportDeadline   = [math]::Round(($exportDeadline - $today).TotalDays)
    DaysToHardCutover      = [math]::Round(($hardCutover - $today).TotalDays)
    ExportDeadlinePassed   = $today -gt $exportDeadline
    HardCutoverPassed      = $today -gt $hardCutover
} | Format-List

$pwaSites | Select-Object Url, Owner, StorageUsageCurrent | Format-Table -AutoSize

Write-Host "`nNext: for each site above, confirm active project/resource counts in" `
           "PWA Server Settings, then scope Playbook 1 (per-user export) and" `
           "Playbook 3 (destination decision) before the export deadline above." `
           -ForegroundColor Yellow
```

See `Scripts/Get-ProjectOnlineRetirementReadiness.ps1` in this folder for the full, documented version of this check with CSV export and license-assignment cross-reference.

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Connect-SPOService -URL https://<tenant>-admin.sharepoint.com` | Connect to SharePoint Online Admin Center (prerequisite for all PWA discovery) |
| `Get-SPOSite \| ?{$_.PWAEnabled -eq "Enabled"} \| ft -a Url,Owner` | Enumerate all active PWA sites in the tenant |
| `.\ExportProjectUserContent.ps1 -Url <PwaUrl> -LoginName <user> -OutputDirectory <path>` | Official per-user Project Online data export |
| `.\ExportProjectUserContent.ps1 ... -Options Timesheets` | Export only the Timesheets-related feature JSON files for one user |
| `https://<tenant>.sharepoint.com/sites/pwa/_api/ProjectData/Projects` | OData: enumerate all projects (browse or script against, while live) |
| `https://<tenant>.sharepoint.com/sites/pwa/_api/ProjectData/Resources` | OData: full Enterprise Resource Pool dataset |
| `https://<tenant>.sharepoint.com/sites/pwa/_api/ProjectData/TimesheetLines` | OData: bulk timesheet history across the portfolio |
| PWA → Server Settings → Enterprise Data → Resource Center | Find a user's Resource ID (needed if not using `-LoginName`) |
| PWA → Server Settings → Time and Task Management → Manage Timesheet Periods | Check for open/in-flight timesheet periods before cutover |
| M365 admin center → Billing → Licenses (filter "Project") | Confirm active Project Online/Project Plan license assignments |
| `project.microsoft.com` (in-browser, signed in) | View a user's Project Home favorites/recently-viewed — screenshot only, no export API |

---
## 🎓 Learning Pointers

- **The retirement is layered, not a single event** — new-SKU sales stopped ~Oct 2025, new PWA site creation blocked April 1 2026, EPT/SharePoint-2013 governance workflows broke April 2 2026, and the full service dies September 30 2026. A client who only heard about "the September date" may be unaware that some functionality already degraded months earlier. See [Microsoft Project Online is retiring: what you need to know](https://techcommunity.microsoft.com/blog/plannerblog/microsoft-project-online-is-retiring-what-you-need-to-know/4450558).
- **The official export tool's per-user scope is the single most commonly underestimated fact in this topic** — teams that assume it's a bulk/tenant export discover the gap only when they're already deep into a migration timeline. Scope Playbook 1's looping approach from day one for any portfolio with more than a handful of active resources.
- **SharePoint content surviving the retirement is the fact that resolves most client panic, and it is often the first thing to lead with** — the scarier-sounding "your data is at risk" concern usually resolves once the SharePoint-vs-Project-Online-data-layer distinction is made concrete.
- **No destination Microsoft points to is a full like-for-like replacement for every Project Online capability.** Planner lacks ERP/timesheets/stage-gates; Project Plan 3/5 is single-project desktop-only; Project Server Subscription Edition requires standing up new infrastructure. Set this expectation with the client explicitly and early — see Playbook 3's capability table before recommending a path. See [Export user data from Project Online](https://learn.microsoft.com/en-us/projectonline/export-user-data-from-project-online).
- **The September 1, 2026 "practical deadline" is a third-party-derived planning heuristic, not a Microsoft-published date** — Microsoft's own commitment is only the September 30 hard cutover, with no contractual guarantee of any read-only window after it. Communicate this distinction accurately: it is good, conservative planning advice, not an official Microsoft deadline, and should be presented to clients as such.
- **License billing surviving the service's own death is an easy final-step miss** — build the manual Project Plan 3/5 license cleanup into every migration engagement's closing checklist explicitly, rather than assuming it happens automatically once the data work is done.
