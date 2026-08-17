# Microsoft Fabric — Tenant/Capacity Administration — Reference Runbook (Mode A: Deep Dive)
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

This is the deep-dive companion to `FabricAdmin-B.md`. It covers the **why** behind three admin-facing mechanics that generate the most confusing tickets:

1. **CU-second billing, bursting, smoothing, and the four-stage throttling policy** — why a capacity can show "over 100% utilization" for hours with zero user-visible impact, and why it can later reject everything even though nobody changed anything.
2. **OneLake's data-access-role (RBAC) security model** — how it interacts with (and is mostly overridden by) Fabric workspace roles, and where it actually matters.
3. **Capacity overage (preview)** as a cost/reliability trade-off admins can opt into.

**Assumes:** F-SKU (or trial) capacity — the current model. Legacy P-SKU (Power BI Premium) behavior is noted only where it materially differs (Autoscale instead of capacity overage; no bursting/smoothing on Autoscale-billed Spark).

**Does not cover:** data engineering authoring inside Fabric items (pipelines, notebook code, Lakehouse/Warehouse schema design), Row-Level/Column-Level Security *authoring* syntax, Purview sensitivity-label enforcement inside Fabric (see `Security/Purview/DSPM-for-AI-A.md`), or Git integration internals beyond what's in `FabricAdmin-B.md` Fix 4.

---

## How It Works

<details><summary>Full architecture — CU-seconds, bursting, smoothing, and the throttling state machine</summary>

**The unit of billing is the CU-second.** Every F-SKU is entitled to a fixed number of Capacity Units (CUs) — e.g. F2 = 2 CUs, F64 = 64 CUs. Fabric divides time into **timepoints of 30 seconds**; there are 2,880 timepoints in a 24-hour day. In each timepoint, a capacity has `CU count × 30` CU-seconds of compute available (an F2 has 60 CU-seconds per timepoint).

**Bursting** lets an operation temporarily consume far more compute than the SKU nominally provides, so results come back fast instead of queuing. A small capacity can burst to run a job that would otherwise need a much bigger SKU.

**Smoothing** is what makes bursting affordable: instead of charging the full burst cost against the timepoint it ran in, Fabric spreads ("smooths") the CU-second cost forward across many future timepoints:
- **Interactive operations** (user-driven — opening a report, running a query) smooth over a minimum of **5 minutes**, up to **64 minutes**, depending on how much CU the operation consumed.
- **Background operations** (scheduled refreshes, pipelines, most Warehouse-category operations, DMV queries) smooth over a full **24 hours**.

This is why Warehouse operations are deliberately classified as *background* even though a user is often waiting on them: 24-hour smoothing means a burst that would spike a 10-minute window into throttling instead contributes a tiny fraction (often ~2%) to any single timepoint. A 1-CU-hour background job on an F2 (48 CU-hours/day) contributes roughly 2.1% load to every timepoint it touches, not 100% to the timepoint it ran in.

**The four-stage throttling policy** (evaluated per capacity, not per workspace):

| Stage | Trigger (future capacity consumed) | Effect |
|-------|-------------------------------------|--------|
| Overage protection | ≤ 10 minutes | No impact — this is the built-in cushion for normal spikes |
| Interactive delay | 10 min – 60 min | New interactive operations delayed 20 seconds at submission |
| Interactive rejection | 60 min – 24 hours | New interactive operations rejected outright; background operations still start |
| Background rejection | > 24 hours | **All** new requests rejected, interactive and background |

Key mechanics that explain most "why is this throttled" confusion:
- **In-flight operations are never throttled mid-run** — throttling only blocks *new* requests submitted after the state changes. A long query that started before throttling began finishes normally.
- **Overage becomes carryforward.** If smoothed usage in a timepoint exceeds what's available, the excess becomes a "carryforward" debt applied to subsequent timepoints. Unused capacity in later timepoints reduces (burns down) that debt. Throttling persists until carryforward reaches zero.
- **Real-Time Intelligence skips the 20-second interactive-delay stage** entirely (a fixed delay would defeat the point of "real-time") and goes straight to rejection at the 60-minute mark.
- **Compound throttling protection**: a single user action (e.g. opening a report) can trigger a chain of dependent operations (report → semantic model → OneLake read). Without protection, each hop could be throttled independently, multiplying the effective delay. Supported workload chains (DirectQuery between semantic models; paginated-report DAX queries) are throttled at most once per capacity in the chain.
- **Classification can flip.** Fabric must classify an operation as interactive or background *before* it runs, using the information available at submission time. When ambiguous, it defaults to background — the safer assumption for the customer.

**Capacity overage (preview)** is a separate, opt-in escape valve: instead of throttling once the 10-minute overage-protection window is exhausted, Fabric keeps paying the excess CU-seconds by billing the Azure subscription directly, at **3× the pay-as-you-go rate**, up to an admin-configured **rolling 24-hour CU-hour limit** (re-evaluated every 5 minutes). It does not increase available compute or speed anything up — it only prevents user-visible rejection. Enabling it requires available **Fabric quota** equal to 1/24th of the chosen limit (Fabric spreads the CU-hour limit across 24 hours internally). It pairs with, but doesn't override, surge protection.

</details>

<details><summary>Full architecture — OneLake data-access-role (RBAC) security model</summary>

OneLake security is a **separate, additive layer underneath** Fabric workspace roles and item sharing — not a replacement for either.

**Layer 1 — Workspace roles (the first and usually decisive boundary).** Admin, Member, and Contributor all have `Write` access to OneLake **by design**, and Write always overrides any OneLake security Read restriction. Practically: those three roles can always view and write every file in every item in the workspace, regardless of what OneLake security roles say. Only **Viewer** is meaningfully restricted by default (no OneLake access at all unless a OneLake security role grants it) — and only Admin/Member can author OneLake security roles in the first place (Contributor cannot).

**Layer 2 — Item-level Fabric permissions** (via sharing or "Manage permissions"): `Read`, `ReadAll`, `Write`, plus non-standalone flags (`Execute`, `Reshare`, `ViewOutput`, `ViewLogs`). `ReadAll` grants OneLake file visibility through an auto-created `DefaultReader` role; plain `Read` grants nothing in OneLake unless a OneLake security role separately covers it.

**Layer 3 — OneLake security roles** — the actual RBAC layer, scoped to Lakehouse, Azure Databricks mirrored catalog, mirrored databases, and mirrored catalogs only (not every Fabric item type). Deny-by-default: a user in zero roles sees zero data. Roles are GRANT-only (no DENY role type is supported — exclusion is achieved by omission, not by an explicit deny rule). Two permissions exist:
- `Read` — view data + table/column metadata (≈ `SELECT` + `VIEW_DEFINITION`).
- `ReadWrite` — includes Read, plus create/delete/rename folders, tables, and shortcuts, and upload/edit files. Only meaningful for Viewers or Read-only users — assigning it to Admin/Member/Contributor is a no-op since they already have Write implicitly. `ReadWrite` roles cannot carry RLS/CLS constraints.

**Default roles** are auto-created per item and use member virtualization (membership = "anyone in the workspace with the qualifying permission," not a static list): Lakehouse gets `DefaultReader` (Read, for anyone with `ReadAll`) and `DefaultReadWriter` (for anyone with `Write`). This is why a freshly created item already has *some* baseline access before an admin configures anything — and why removing that baseline requires deliberately editing or deleting the default role, not just "not configuring security."

**Permission inheritance and traversal:** a role grants access to everything under the folder it targets, recursively. Granting Read on a *subfolder* also grants list/traversal rights on its parent directories (so the item is discoverable), but that traversal grant does **not** extend sideways to sibling folders — it mirrors classic Windows NTFS folder-permission traversal behavior.

**Row-Level and Column-Level Security combine differently across multiple roles than most admins expect.** Within a single role, RLS/CLS/object access is an **intersection** (all conditions must hold). Across multiple roles a user belongs to, the roles combine via **union** (least-restrictive wins) — except Column-Level Security specifically in the **SQL Analytics Endpoint**, which uses a stricter **intersection/deny** semantic: a column hidden by *any* role the user is in stays hidden even if another role would show it. This asymmetry (union everywhere except CLS-via-SQL-endpoint) is a documented, non-obvious exception worth testing explicitly rather than assuming consistent behavior across engines.

**Shortcuts** add a second dimension: *passthrough* shortcuts evaluate the querying user's own identity against the shortcut target (requiring that user to independently have OneLake security permissions at the target); *delegated* shortcuts (S3/ADLS/Dataverse) evaluate **both** the delegated credential's access at the source **and** the requesting user's OneLake security permissions — either one failing blocks access. A subtlety: **Direct Lake over SQL** and **T-SQL in delegated-identity mode** do NOT pass the calling user's identity through a shortcut — they delegate to the item owner's identity instead, silently changing who's actually being authorized. Use Direct Lake over OneLake mode or T-SQL user's-identity mode where per-user shortcut security must be enforced.

**Hard limits:** 250 OneLake security roles per item (extendable to 1,000 via support request), 500 members per role, 500 permissions per role.

**Propagation latency is not instant and differs by change type:** role *definition* changes (which tables/folders/permissions a role grants) apply in ~5 minutes. Changes to **group membership** used inside a role take up to **~1 hour** to apply — and some Fabric engines cache access separately, potentially adding another hour on top. A "I just removed him from the group and he can still see the data" ticket less than an hour old is very likely just latency, not a misconfiguration.

</details>

---

## Dependency Stack

```
Layer 5 — Query/consumption engine
    Lakehouse SQL analytics endpoint | Spark notebooks | Direct Lake semantic models |
    Eventhouse (RLS only, preview) | authorized third-party engines
    └── each engine independently supports (or doesn't) RLS/CLS enforcement — check
        the per-engine table before assuming security "just works" everywhere

Layer 4 — OneLake security roles (RBAC)
    Deny-by-default | Read / ReadWrite permissions | table + folder + column scoping |
    default (auto) roles per item | 250 roles/item, 500 members/role limits
    └── BYPASSED ENTIRELY by Workspace Admin/Member/Contributor Write access (Layer 2)

Layer 3 — Fabric item permissions (sharing / manage permissions)
    Read | ReadAll (→ DefaultReader) | Write | Execute/Reshare/ViewOutput/ViewLogs
    └── governs whether a user can see the ITEM at all before OneLake security is
        even evaluated

Layer 2 — Fabric workspace roles
    Admin / Member / Contributor — ALWAYS Write access to OneLake, bypasses Layer 4
    Viewer — no OneLake access by default, the only role OneLake security meaningfully
             restricts
    └── governs control-plane actions (create/manage items) independent of data access

Layer 1 — Capacity (compute + billing substrate for everything above)
    Azure subscription → Microsoft.Fabric/capacities resource (F-SKU or trial)
        └── Capacity State = Active (not Paused/Deleted)
                └── CU-second budget per 30-second timepoint
                        ├── Bursting: temporarily exceed nominal CU rate
                        ├── Smoothing: interactive 5–64 min / background 24 hr
                        │       spread of consumed CU-seconds into future timepoints
                        └── Throttling state machine (per capacity, not per workspace):
                                Overage protection (≤10min) → Interactive delay (20s,
                                10–60min) → Interactive rejection (60min–24hr) →
                                Background rejection (>24hr)
                                    └── Optional: Capacity overage (preview) pays off
                                        excess at 3x rate instead of throttling, up to
                                        an admin-set rolling 24hr CU-hour limit
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Metrics app shows >100% utilization for hours, nobody complains | Smoothing is working as designed — background jobs spread load over 24hr | Compute page: confirm no throttling-stage events, only elevated utilization |
| Everything on the capacity suddenly rejects, no recent change | Carryforward debt crossed the 24-hour Background Rejection threshold | Overages tab: check cumulative/carryforward trend leading up to the event |
| Only *new* interactive actions fail; a report that was already loading finishes fine | Expected — in-flight operations are never throttled mid-run | Confirm the failing actions were all submitted after the throttling state changed |
| One workspace throttled, a "sibling" workspace on a different capacity is fine | Throttling is per-capacity, not tenant-wide | `Get-PowerBIWorkspace` — confirm the two workspaces are on different `CapacityId`s |
| Report → semantic model → OneLake chain feels doubly slow under load | Compound throttling protection didn't apply (unsupported chain type) or applied and this is still expected added latency | Confirm whether the specific workload pair is in the supported compound-throttling list |
| Real-Time Intelligence item rejecting fast, no 20-second delay phase observed | Expected — RTI skips the interactive-delay stage entirely | Not a bug; document as expected behavior in the ticket |
| User removed from a security group still sees data 20 minutes later | Group-membership propagation lag (up to ~1hr, +up to 1hr more for cached engines) | Re-test after the full latency window before treating as a misconfiguration |
| Role permissions changed, still not reflected after 10+ minutes | Role *definition* change should land in ~5 min — investigate as a real issue, not latency | Re-verify the role was saved correctly; check for a typo in scope/table path |
| Viewer sees a lakehouse's data with no OneLake security role ever configured | `DefaultReader` auto-role granting access to anyone with `ReadAll` item permission | `ReadAll` item permission is doing the granting, not an intentionally authored OneLake role |
| Admin/Member/Contributor "restricted" via OneLake security role still sees everything | Expected — Write access from workspace role always overrides OneLake security Read restrictions | Confirm this is a workspace-role, not OneLake-role, problem — demote to Viewer + explicit OneLake role if true restriction is required |
| SQL Analytics Endpoint hides a column that Spark/Lakehouse view shows for the same user | CLS intersection/deny semantic is SQL-Endpoint-specific; other engines use union | Confirm which engine is being compared — this is documented divergent behavior, not a bug |
| Shortcut to another OneLake location returns "access denied" for a user who can access the shortcut's own workspace fine | Passthrough shortcut requires the user to independently hold OneLake security permission at the TARGET, not just the shortcut | Check OneLake security role assignment on the target item, not the shortcut item |
| Direct Lake over SQL / delegated T-SQL mode returns data a specific user shouldn't see via a shortcut | Delegated-identity mode passes the item OWNER's identity through the shortcut, not the querying user's | Switch to Direct Lake over OneLake mode or T-SQL user's-identity mode if per-user shortcut enforcement is required |
| Capacity overage enabled but throttling still resumed mid-incident | Rolling 24hr CU-hour limit was reached, or available Fabric quota doesn't support the configured limit | Check the limit value against Fabric quota (limit ÷ 24 must fit available quota) |
| Scaled capacity down while capacity overage was enabled, unexpected large bill | Scaling down while overage is active can trigger significant overage charges | Disable/lower capacity overage limit before scaling down, not after |
| Spark job billing looks like flat pay-as-you-go with no smoothing/bursting behavior | Autoscale Billing for Spark is enabled — bursting/smoothing explicitly don't apply in this mode | Confirm Autoscale Billing for Spark setting on the capacity |

---

## Validation Steps

**1 — Confirm current throttling stage via the Capacity Metrics app**
Portal: **Fabric Capacity Metrics app → Compute page → Throttling chart**.
Expected: no active throttling stage, or a stage consistent with a known, explainable spike.
Bad: `Interactive rejection` or `Background rejection` with no obvious cause — proceed to carryforward analysis.

**2 — Check carryforward and burndown trend**
Portal: **Compute page → Overages tab**, switch scale between 10min / 60min / 24hr views.
Expected: carryforward trending toward zero (burning down) once load drops.
Bad: carryforward flat or climbing despite reduced load — capacity is genuinely undersized for sustained demand, not just spiking.

**3 — Identify the operation(s) driving the overage**
Portal: **Compute page → Utilization chart**, drill through a spike to the timepoint page, review interactive and background operations listed for that window.
Expected: a specific, attributable job or user query.
Bad: no clear driver — check for compound-chain effects or Spark Autoscale Billing interfering with normal accounting.

```powershell
Get-PowerBICapacity -Scope Organization | Select-Object DisplayName, Id, Sku, State
```
Confirm SKU size matches what the client believes they purchased — a common surprise is discovering the assigned SKU is smaller than assumed.

**4 — Confirm OneLake security role assignment matches expectation**
Portal: item → **Manage OneLake data access roles**.
Expected: role membership and scope match the access the client described wanting.
Bad: no roles exist at all (falling back to default-role behavior) or a role's scope is broader than intended (check folder/table paths carefully — permissions inherit recursively).

**5 — Confirm workspace role isn't silently overriding an OneLake restriction**
```powershell
# Requires Fabric admin API access via Invoke-RestMethod (no dedicated cmdlet for workspace role membership)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>/users" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET
```
Bad: the "restricted" user shows as Admin/Member/Contributor — that role's implicit Write access overrides any OneLake security Read-only role.

**6 — For latency-suspected access issues, re-test against the correct SLA window**
Role definition changes: allow ~5 minutes. Group membership changes used inside a role: allow up to ~1 hour, plus up to another hour for engines with their own caching layer. Don't escalate a group-membership access issue as broken until the full window has elapsed.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Scope the blast radius**
Is this one user, one workspace, or "everything"? "Everything" symptoms point at capacity state or throttling (Layer 1). Single-user symptoms point at OneLake security or item permissions (Layers 2–4). Confirm via `Get-PowerBICapacity` / `Get-PowerBIWorkspace` before going deeper.

**Phase 2 — If capacity-level: classify the throttling stage**
Use the Metrics app Throttling chart to place the incident precisely in the four-stage table. This determines urgency and the correct fix (wait it out vs. scale vs. pause/resume vs. enable overage).

**Phase 3 — If capacity-level and stage is Background/Interactive Rejection: find the driver**
Drill through Utilization → timepoint → operations. Distinguish a one-off spike (let it burn down, or pause/resume to force zero future-usage) from a sustained pattern (right-size the SKU — see Learning Pointers on the F256/F512 boundary caveat).

**Phase 4 — If access-level: walk the layer stack top-down**
Workspace role first (does Write access explain full access?) → item permission (Read/ReadAll/Write) → OneLake security role existence and scope → default-role behavior if no explicit role exists → engine-specific RLS/CLS enforcement table if data is visible in one engine but not another.

**Phase 5 — If access-level and a shortcut is involved**
Determine passthrough vs. delegated shortcut type first — this changes which identity is actually being evaluated at the target, and whether Direct Lake/T-SQL identity mode is silently substituting the item owner's identity for the querying user's.

**Phase 6 — Close out with the correct latency expectation**
Before declaring a fix "not working," confirm enough time has passed for the specific change type (5 min for role definitions, up to 2 hours for group membership across cached engines).

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Right-size a capacity showing a sustained (not spiky) overload pattern</summary>

1. Confirm the pattern is sustained via the Overages tab (carryforward not burning down between peaks) — a one-off spike does not need a SKU change, see Fix 2 in `FabricAdmin-B.md`.
2. Identify the largest recurring contributor via timepoint drill-through (background job, semantic model refresh, or a specific team's usage pattern).
3. Consider **capacity overage** as a bridge before committing to a permanent SKU increase if the overload is occasional/seasonal rather than a steady-state trend — it costs 3x pay-as-you-go but requires no procurement/commitment change and can be disabled instantly.
4. If scaling the SKU: be aware that crossing the **F256/F512 boundary** can change performance characteristics (documented by Microsoft as a potential "slower experience" transition point) — validate post-scale performance rather than assuming linear improvement.
5. If capacity overage is left enabled during a SKU scale-down: disable or lower the overage limit first — scaling down while overage is active can generate large, unexpected overage charges against the new, smaller baseline.

**Rollback:** revert SKU size; disable capacity overage (`0` limit or toggle off) at any time — no standing charge exists for having it enabled with zero triggered overage.
</details>

<details>
<summary>Playbook 2 — Correctly restrict data access for external/guest or partial-trust internal users</summary>

1. Do **not** attempt to restrict an Admin/Member/Contributor via OneLake security roles alone — their workspace-role Write access overrides any Read restriction. If true restriction is required, the user's workspace role itself must be Viewer (or the item shared at Read/ReadAll only, not via workspace-role membership).
2. For a Viewer who needs scoped (not full) access: create a OneLake security role scoped to the specific table/folder path, assign the user or their Entra group as a member, and use `ReadWrite` only if write access is genuinely required (it's a no-op if mistakenly applied to a role for an Admin/Member/Contributor).
3. Verify inheritance didn't over-grant: a role scoped to a parent folder grants access to everything beneath it — scope to the most specific folder/table that satisfies the requirement.
4. For B2B guest access specifically: confirm Entra External ID's **Guest user access** setting is "Guest users have the same access as members" — OneLake security roles assigned to a guest are ineffective if this tenant-level Entra setting isn't configured first (this is an Entra-side prerequisite, not a Fabric-side one — see `EntraID/Troubleshooting/ExternalIdentities-B.md`).
5. Test as the actual restricted user (or via impersonation/test account) after the ~5-minute role-definition propagation window, not immediately after saving.

**Rollback:** remove the OneLake security role assignment or delete the role — this only removes the explicit grant; it does not affect workspace-role-derived access, which was never governed by the role in the first place.
</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Fabric capacity + workspace evidence for escalation.
.DESCRIPTION
    Read-only. Gathers capacity state/SKU, workspace-to-capacity mapping, and
    workspaces with no assigned capacity. Does not query OneLake security roles or
    the Capacity Metrics app data (both require portal/Fabric REST API access beyond
    what MicrosoftPowerBIMgmt exposes) — attach Metrics app screenshots manually.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ".\FabricEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
)

Import-Module MicrosoftPowerBIMgmt -ErrorAction Stop
if (-not (Get-PowerBIAccessToken -ErrorAction SilentlyContinue)) {
    Connect-PowerBIServiceAccount
}

$capacities = Get-PowerBICapacity -Scope Organization
$workspaces = Get-PowerBIWorkspace -Scope Organization -Include All

$report = foreach ($ws in $workspaces) {
    $cap = $capacities | Where-Object Id -eq $ws.CapacityId
    [PSCustomObject]@{
        WorkspaceName = $ws.Name
        WorkspaceId   = $ws.Id
        WorkspaceState = $ws.State
        CapacityId    = $ws.CapacityId
        CapacityName  = $cap.DisplayName
        CapacitySku   = $cap.Sku
        CapacityState = $cap.State
        NoCapacityAssigned = [bool](-not $ws.CapacityId)
    }
}

$report | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Host "Evidence exported to $OutputPath" -ForegroundColor Green
Write-Host "Attach manually: Capacity Metrics app Throttling chart + Overages tab screenshots for the affected time window." -ForegroundColor Yellow
```

---

## Command Cheat Sheet

```powershell
# Connect
Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser -Force
Connect-PowerBIServiceAccount

# All capacities + state/SKU
Get-PowerBICapacity -Scope Organization | Select-Object DisplayName, Id, Sku, State

# All workspaces + capacity assignment
Get-PowerBIWorkspace -Scope Organization -Include All |
    Select-Object Name, Id, CapacityId, State

# Workspaces with NO capacity assigned
Get-PowerBIWorkspace -Scope Organization -Include All | Where-Object { -not $_.CapacityId }

# Reassign a workspace to a capacity
Set-PowerBIWorkspace -Id "<workspaceId>" -CapacityId "<capacityId>" -Scope Organization

# Unassign (revert to Pro-only shared capacity behavior)
Set-PowerBIWorkspace -Id "<workspaceId>" -CapacityId $null -Scope Organization

# Fabric REST Admin API — list workspaces (broader coverage than PBI cmdlets)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET

# Fabric REST Admin API — workspace user/role membership (no dedicated cmdlet exists)
Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/<workspaceId>/users" `
    -Headers @{ Authorization = "Bearer $token" } -Method GET
```

Portal-only (no cmdlet coverage):
- Fabric Capacity Metrics app — Compute page (Utilization, Throttling, Overages tabs) — install once via Apps
- Admin portal → Tenant settings — propagation not instant, avoid stacking changes
- Item → Manage OneLake data access roles — role/permission/member authoring
- Capacity settings → Capacity overage — enable/disable, set rolling 24hr CU-hour limit

---

## 🎓 Learning Pointers

- **">100% utilization" is not itself a problem — it's smoothing working as intended.** Only a Throttling-chart event (Interactive delay/rejection or Background rejection) is an actual user-visible impact. Don't chase utilization percentage alone. [Understand capacity throttling and smoothing](https://learn.microsoft.com/en-us/fabric/enterprise/throttling)
- **Throttling is a per-capacity state machine with four distinct stages, not a binary on/off.** Knowing which stage an incident is in (10min / 60min / 24hr threshold) tells you both the urgency and the correct remedy — a stage-1 delay often self-resolves, a stage-3 background rejection usually needs active intervention (scale, pause/resume, or overage). [Fabric capacity throttling policy](https://learn.microsoft.com/en-us/fabric/enterprise/throttling)
- **Capacity overage trades cost for uptime at a fixed 3x multiplier, with a hard rolling 24-hour spending ceiling.** It's a bridge for occasional spikes, not a substitute for right-sizing a capacity under sustained load — and it requires Fabric quota headroom (limit ÷ 24) to even enable. [Capacity overage (preview)](https://learn.microsoft.com/en-us/fabric/enterprise/capacity-overage-overview)
- **OneLake security is real RBAC, but Admin/Member/Contributor workspace roles bypass it completely by design.** It only meaningfully restricts Viewers and external/guest access — never assume OneLake security enforces least-privilege among internal collaborators with elevated workspace roles. [OneLake security access control model](https://learn.microsoft.com/en-us/fabric/onelake/security/data-access-control-model)
- **Column-Level Security has one documented exception to the "union across roles" rule: the SQL Analytics Endpoint uses intersection/deny for CLS specifically.** A column hidden anywhere stays hidden there, even if it's visible through another engine for the same user under the same roles — test per-engine, don't assume consistency.
- **Propagation latency differs by change type and isn't optional to account for.** Role definition edits: ~5 minutes. Group membership changes: up to ~1 hour, plus up to another hour for engines with independent caching. Re-test against the correct window before treating a change as "not working."
