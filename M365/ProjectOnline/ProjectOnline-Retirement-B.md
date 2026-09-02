# Project Online Retirement — Hotfix Runbook (Mode B: Ops)
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

**Read this first — the clock is real.** Microsoft Project Online retires **September 30, 2026** (announced via Message Center notice MC812729, published 2024-07-10). This is a hard cutover with no extension precedent for a Microsoft SaaS retirement once a date is formally published — do not tell a client "they'll probably push it back." The **practical export deadline is September 1, 2026**, not September 30 — Microsoft has never contractually guaranteed a post-retirement read-only window (an informal ~90-day courtesy window has followed some past retirements, not all, and carries no SLA). **If today's date is on or after September 1, 2026, treat any client with unexported Project Online data as an active, urgent risk — not a routine ticket.** Confirm the actual current date before responding; do not assume this runbook's own research date still applies.

This is a **different product** from Project for the web / Planner Premium. Do not confuse the two — see Fix 1 below before doing anything else.

| # | Command / Check | Interpretation |
|---|---|---|
| 1 | Ask the client directly: "Is this about Project Online (PWA, `/sites/pwa`) or Project for the web / Planner Premium?" | If Project for the web — **no action needed**, it was already folded into Planner in August 2025. See `M365/Planner/Planner-B.md` Fix 8. Stop here for that case. |
| 2 | `Get-SPOSite \| ?{$_.PWAEnabled -eq "Enabled"} \| ft -a Url,Owner` (SharePoint Online Management Shell, SharePoint admin) | Confirms whether the tenant actually has an active Project Online (PWA) site. No results = no Project Online usage; redirect the client to Fix 1's disambiguation instead of scoping a migration that isn't needed. |
| 3 | Navigate to `https://<tenant>.sharepoint.com/sites/pwa` (or the URL from check 2) in a browser | Loads normally = still in service, plan/act now. Service-decommissioned error = retirement has already occurred; see Fix 7 (post-retirement triage). |
| 4 | Check today's date against **September 1, 2026** (practical export deadline) and **September 30, 2026** (hard cutover) | Before Sep 1: normal urgency, start migration scoping this week. Sep 1–29: **critical urgency**, escalate to Playbook/migration engagement same day, do not treat as a standard ticket. On/after Sep 30: retirement has occurred — go to Fix 7. |
| 5 | `Get-MsolAccountSku` / M365 admin center → Billing → Licenses, filter for "Project Online Professional" or "Project Online Premium" | Confirms active Project Online license count — new sales of these SKUs stopped **October 2025**, but existing assignments continue billing until manually removed, including **after** the service itself retires. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Project Online (PWA) — SharePoint-based Project Web App
│
├─ Project Web App (PWA) site  ─── https://<tenant>.sharepoint.com/sites/pwa
│    └─ SharePoint Online tenant (hosting layer only — PWA is an app ON TOP of SPO)
│
├─ Structured project data (SQL-backed, INSIDE Project Online — no direct admin access)
│    ├─ Task schedules, dependencies, baselines, custom fields
│    ├─ Enterprise Resource Pool (ERP) — cost rates, calendars, skills
│    └─ Timesheet history and in-flight approval workflows
│         (NONE of this is SharePoint content — it does NOT survive retirement
│          unless separately exported before the cutover)
│
├─ OData reporting API — /_api/ProjectData/*
│    └─ Feeds: Power BI reports, Excel pivots, custom dashboards
│         (returns HTTP 410 Gone the moment the service retires)
│
├─ Project Online Desktop Client
│    ├─ Local .mpp files — survive retirement, open fine, no server needed
│    └─ Online/PWA sync (check-in/out, publish, resource sync) — dies with PWA
│
└─ SharePoint project sites (documents, issue lists, risk registers)
     └─ Ordinary SharePoint Online content — SURVIVES retirement unaffected;
          only the Project-Online-to-SharePoint SYNC integration dies, not the content
```

The single fact this cascade exists to make unmissable: **"SharePoint site" and "Project Online data" are not the same thing.** SharePoint project sites survive the retirement. The scheduling database, resource pool, and timesheets do not — and there is no admin-facing SQL access or bulk backup button for that layer. Export before the deadline or it is gone.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm which product the client means.**
   Ask directly — do not infer from the word "Project." If Project for the web/Planner Premium, redirect to `M365/Planner/Planner-B.md` Fix 8 and stop.

2. **Confirm active Project Online usage exists.**
   ```powershell
   Connect-SPOService -URL https://<tenant>-admin.sharepoint.com
   Get-SPOSite | ?{$_.PWAEnabled -eq "Enabled"} | ft -a Url,Owner
   ```
   Expected good output: zero or more PWA site URLs. Zero rows means there is nothing to migrate — confirm with the client before scoping any work.

3. **Confirm days remaining against both deadlines.**
   Practical export deadline: **September 1, 2026**. Hard cutover: **September 30, 2026**. If the export deadline has already passed, do not present this as routine — see the Triage note above and go straight to Playbook/escalation framing.

4. **Confirm license state.**
   M365 admin center → Billing → Licenses → filter "Project Online". Note the count — this is also what needs manual cancellation later (Fix 6), since the service retiring does **not** stop the invoice.

5. **Confirm what the client actually needs preserved.**
   Ask specifically about: active project schedules, resource pool/rate data, timesheet history (compliance-sensitive — SOX/ISO retention requirements may apply), Power BI/Excel reports built on the OData feed, and SharePoint document content (lower urgency — this survives on its own).

---
## Common Fix Paths

<details><summary>Fix 1 — Client confused: "Is Planner/Project for the web shutting down too?"</summary>

No. These are two unrelated products that happen to share the word "Project" in their history:

- **Project for the web** — retired as its own standalone app in **August 2025**, folded into Microsoft Planner (Premium plans) with **zero migration required**. Nothing to do here.
- **Project Online** — the older, SharePoint-based Project Web App (PWA) product — is the one genuinely retiring, **September 30, 2026**, and it **does** require an active migration if in use.

Confirm which product by checking for an active PWA site (`Get-SPOSite | ?{$_.PWAEnabled -eq "Enabled"}`) versus Dataverse-backed Premium Planner plans (M365 admin center → Settings → Org Settings → Project). See `M365/Planner/Planner-B.md` Fix 8 for the full disambiguation if the client also has Planner questions.

</details>

<details><summary>Fix 2 — Export a specific user's project data (official Microsoft tool)</summary>

Microsoft's only first-party export tool is **per-user**, not a tenant-wide bulk export. Plan accordingly — for a portfolio with many active users, this must be run once per user (see Playbook 1 in the Mode A runbook for a looping approach).

**Prerequisites:**
- SharePoint Online Management Shell installed
- Project Online Premium or Professional license assigned to the person running the export
- Project Online Desktop Client installed and connected to the target PWA site
- Either site collection admin on the PWA site, or (Project permission mode) **Manage Users and Groups** + **Access Project Server Reporting Service**, or SharePoint admin

```powershell
# 1. Download and unblock the official script package first:
#    https://go.microsoft.com/fwlink/?linkid=871953
#    (Project Online User Content Export and Delete script package)

# 2. Find the PWA site(s):
Connect-SPOService -URL https://<tenant>-admin.sharepoint.com
Get-SPOSite | ?{$_.PWAEnabled -eq "Enabled"} | ft -a Url,Owner

# 3. Run the export (by login name — simplest, avoids the Resource ID lookup):
.\ExportProjectUserContent.ps1 `
    -Url https://<tenant>.sharepoint.com/sites/pwa `
    -LoginName user@<tenant>.onmicrosoft.com `
    -OutputDirectory C:\ProjectOnlineExport\<username>
```

Output includes project list XML files, ~27 feature-specific JSON files (Security, Timesheets, ResourcePlans, etc.), and per-project `.mpp`/`.xml`/`.json` triples for every project the user owns, is assigned to, or manages status for. **Not exported by this tool:** Project Home favorites/recently-viewed (screenshot only — no API), full Enterprise Resource Pool as a standalone dataset, and any user the script isn't explicitly run for.

</details>

<details><summary>Fix 3 — Need full-portfolio / cross-project data, not just one user</summary>

The per-user script (Fix 2) does not give you a clean tenant-wide export. For resource pool, timesheet history across the whole portfolio, cross-project financials, and custom field values at scale, query the **OData API directly** before retirement:

```
https://<tenant>.sharepoint.com/sites/pwa/_api/ProjectData/Projects
https://<tenant>.sharepoint.com/sites/pwa/_api/ProjectData/Resources
https://<tenant>.sharepoint.com/sites/pwa/_api/ProjectData/TimesheetLines
```

Pull these into Excel Power Query, Power BI Desktop, or a script-driven REST client and save the output locally — this endpoint returns **HTTP 410 Gone** the instant the service retires, with no grace period documented for the API specifically (separate from the informal PWA read-only-window courtesy). See Mode A Evidence Pack for a fuller enumeration script.

</details>

<details><summary>Fix 4 — Power BI report/dashboard built on Project Online broke</summary>

Expected — any Power BI report, Excel pivot, or custom dashboard pointed at `/_api/ProjectData/*` stops refreshing the moment Project Online retires (or if the tenant's PWA site is already gone). This is not a bug to troubleshoot; it is the retirement doing exactly what it's documented to do.

1. Confirm the report's data source is the Project Online OData feed (Power BI Desktop → Transform Data → Data source settings).
2. There is no fix that restores the old connection — the source is gone. Redirect the report to the exported dataset (Fix 3) or to the destination platform's own reporting surface once migrated.
3. If the `.pbix` file itself is still needed, it can be downloaded and kept, but its embedded connection string will need rewiring to a new data source — it will not "just work" again.

</details>

<details><summary>Fix 5 — Timesheet approvals stuck / in-flight at cutover</summary>

Timesheet workflows stop the instant Project Online retires. Any approval in flight on that date will **not** complete — there is no post-retirement completion path.

1. Before the cutover, run a report of all open/pending timesheet periods across every PWA site.
2. Force-complete or explicitly reject any pending approvals — do not leave items "in flight" across the retirement boundary.
3. If timesheet history has compliance retention requirements (SOX, ISO 9001, contractual audit clauses), export the `Timesheets`/`Timesheets_Reporting` JSON via Fix 2 (per user) or the OData `TimesheetLines` entity (Fix 3) and archive it in a system the organization controls — this data is not synced anywhere else automatically and does not survive in SharePoint.

**No rollback note needed** — this fix is a proactive drain-and-archive action, not a destructive change to existing state.

</details>

<details><summary>Fix 6 — Licenses still billing after the service retired</summary>

Expected. Project Plan 3 (formerly Project Online Professional) and Plan 5 (formerly Project Online Premium) subscriptions **do not auto-cancel** when the underlying service retires — an admin must manually remove the license assignment.

1. M365 admin center → Billing → Licenses → locate the Project Online/Project Plan 3/Plan 5 SKU.
2. Review assigned users; confirm none still need the Desktop Client specifically (local `.mpp` editing is the only surviving use case for these licenses post-retirement).
3. Remove or reassign licenses as appropriate. **Rollback note:** removing a license does not delete any local `.mpp` files already on a user's machine — this is a billing action, not a data action, and is safe to do without further backup.

</details>

<details><summary>Fix 7 — Retirement has already occurred; client asking what's recoverable</summary>

1. Confirm the actual retirement occurred (not just an outage): navigate to the PWA URL — a service-decommissioned page rather than a timeout or 403 confirms retirement rather than a transient issue.
2. SharePoint project sites (documents, lists) are **unaffected** — they were never part of the retirement. Point the client there first; this is often the reassurance they actually need.
3. Structured project data (schedules, resource pool, timesheets) is **not recoverable through support** if it was never exported — Microsoft does not provide post-retirement data-recovery requests for this service. Set expectations accordingly rather than opening an escalation that cannot be fulfilled.
4. Locally saved `.mpp` files on any user's machine still open fine in the Desktop Client — check for these before concluding all data is lost.
5. If an informal read-only window is still active (unconfirmed, not guaranteed), attempt the PWA URL and OData endpoint once — if either responds, treat it as bonus time and export immediately rather than assuming it will persist.

</details>

---
## Escalation Evidence

```
PROJECT ONLINE RETIREMENT — ESCALATION TEMPLATE
=================================================
Tenant:                        <tenant>.onmicrosoft.com
Date of this ticket:           <today's date — confirm against Sep 1 / Sep 30 2026 deadlines>
PWA site(s) confirmed active:  <Get-SPOSite output — Url / Owner>
Retirement date:                September 30, 2026 (MC812729)
Practical export deadline:      September 1, 2026 (no SLA-backed grace period after)
Days remaining to export:       <calculate from today>

Confirmed in use:
  [ ] Active project schedules              Count: ___
  [ ] Enterprise Resource Pool               Users/resources: ___
  [ ] Timesheet workflows (compliance-sensitive?  Y/N)
  [ ] Power BI / Excel reports on OData feed  Count: ___
  [ ] SharePoint project-site documents      (lower urgency — survives retirement)

Export status:
  [ ] Per-user export run (Fix 2)   —  users completed: ___ / ___
  [ ] OData bulk pull completed (Fix 3)
  [ ] Timesheet archive completed (Fix 5)
  [ ] Power BI reports redirected (Fix 4)

License cleanup:
  [ ] Project Plan 3/5 licenses identified for removal   Count: ___

Migration destination decided:  [ ] Planner Premium  [ ] Project Plan 3/5 (single-project only)
                                 [ ] Project Server Subscription Edition  [ ] Dynamics 365 Project Operations
                                 [ ] Third-party platform (name): ___________
Migration engagement scoped as its own project:  [ ] Yes  [ ] No — STILL A TICKET, ESCALATE

Escalate to: Migration/PMO engagement owner — this is a project, not a support ticket, once
active Project Online usage is confirmed.
```

---
## 🎓 Learning Pointers

- **The two "Project" retirements are not the same event and mixing them up causes real client anxiety or, worse, a missed deadline.** Project for the web retired quietly in August 2025 with zero action required (folded into Planner). Project Online retires September 30, 2026 and needs an active, time-boxed migration. Always confirm which one before responding. See [Export user data from Project Online](https://learn.microsoft.com/en-us/projectonline/export-user-data-from-project-online).
- **SharePoint content and Project Online's own structured data are stored completely separately**, despite PWA being built on top of SharePoint. Only the latter is at risk — internalize this distinction before triaging any "is my data safe" question.
- **The official Microsoft export tool is per-user, not tenant-wide.** Admins scoping a "quick export" based on the tool's name alone will badly underestimate the work — see Mode A for a looping approach across an entire resource list.
- **The OData API dies with no separate grace period from the PWA courtesy window** — any Power BI/Excel/custom reporting built on `/_api/ProjectData/*` needs its data pulled and archived before the cutover, independently from exporting individual projects.
- **License billing does not stop when the service does.** This is a manual cleanup step that is easy to forget once the "real" migration work is done — build it into the closing checklist, not an afterthought.
- This is a sensitive, time-boxed compliance and continuity topic for any client with active usage — if uncertain about scope or retention obligations, loop in the account's migration/PMO lead rather than guessing at what "needs" to be exported.
