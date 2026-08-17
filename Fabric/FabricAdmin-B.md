# Microsoft Fabric — Tenant/Capacity Admin — Hotfix Runbook (Mode B: Ops)
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

Fabric problems almost always trace back to one of three layers: **capacity state**, **tenant settings**, or **workspace-to-capacity assignment**. Check capacity state first — it explains the majority of "everything broke at once" tickets.

```powershell
# 1 — Install/connect (one-time)
Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser -Force
Connect-PowerBIServiceAccount

# 2 — List all capacities and their state
Get-PowerBICapacity -Scope Organization | Select-Object DisplayName, Id, Sku, State

# 3 — List workspaces and confirm capacity assignment
Get-PowerBIWorkspace -Scope Organization -Include All |
    Select-Object Name, Id, CapacityId, State |
    Where-Object { -not $_.CapacityId }   # workspaces with NO capacity assigned

# 4 — Check tenant settings for the affected feature (portal, no cmdlet for all settings)
# app.fabric.microsoft.com > gear icon > Admin portal > Tenant settings

# 5 — Capacity Metrics app (portal) for throttling diagnosis
# Install from: app.fabric.microsoft.com > Apps > Microsoft Fabric Capacity Metrics
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| Capacity `State = Paused` | Admin or auto-pause (cost control) paused it — all workspace operations blocked tenant-wide for that capacity | Fix 1 |
| Capacity missing entirely from `Get-PowerBICapacity` output | Capacity deleted — check for 7-day soft-delete recovery window on affected items | Fix 1 |
| Workspace `CapacityId` is null/empty | Never assigned, or assignment was removed — falls back to Pro-only behavior | Fix 3 |
| Reports/queries slow or queuing, capacity shows Active | CU-second overload — check Capacity Metrics app for Overloaded state | Fix 2 |
| Git integration button greyed out or sync errors | Tenant setting not enabled, or ADO/GitHub permissions/repo config issue | Fix 4 |
| External/guest user can't be added to workspace | Tenant-level external sharing or guest access setting disabled | Fix 5 |
| Tenant setting change made but users still see old behavior | Propagation delay — not instant tenant-wide | Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true for a Fabric workspace to function</summary>

```
[Azure subscription: Microsoft.Fabric/capacities resource provisioned]
    └── [Capacity SKU: F2–F2048, or trial (auto F4/F64), or legacy P-SKU]
            └── [Capacity State = Active — not Paused, not Deleted]
                    └── [Workspace explicitly assigned to this capacity]
                            └── [CU-second consumption under threshold — sustained >100%
                                 for >10 min triggers progressive throttling]
                                    └── [Fabric items function: Lakehouse, Warehouse,
                                         Notebook, Pipeline, Power BI reports/semantic models]
                                            └── [Below F64: report viewers still need
                                                 individual Power BI Pro license]
                                            └── [F64+: viewers do NOT need Pro license]

Separately gated, tenant-wide (admin portal, NOT per-workspace):
[Tenant settings: external sharing | guest access | Git integration | domains]
    └── Must be explicitly enabled before per-workspace features work
            └── Changes propagate tenant-wide but are NOT instant
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm capacity state**
```powershell
Get-PowerBICapacity -Scope Organization | Select-Object DisplayName, Id, Sku, State
```
Expected: `State = Active` for the capacity backing the affected workspace.
Bad: `Paused` (all operations blocked, reversible) or capacity absent entirely (deleted — check soft-delete window).

**Step 2 — Confirm workspace-to-capacity assignment**
```powershell
Get-PowerBIWorkspace -Scope Organization -Include All |
    Where-Object Name -eq "<affected workspace name>" |
    Select-Object Name, Id, CapacityId, State
```
Bad: `CapacityId` is `$null` — workspace has no capacity, Fabric items (non-Power BI) will not function; classic Power BI reports may still work under Pro/shared behavior.

**Step 3 — Check for throttling if capacity is Active but performance is degraded**
Portal: **Fabric Capacity Metrics app** (install once from the Apps section). Look at the Overload states over time:
- `InteractiveDelay` — early warning, requests slowed but succeeding
- `InteractiveRejected` — interactive requests being rejected
- `AllRejected` — capacity fully saturated
- `SurgeProtection` — background operations throttled to protect interactive workloads

Bad: any sustained `AllRejected`/`SurgeProtection` window correlating with the reported outage time.

**Step 4 — Confirm the relevant tenant setting is enabled and check propagation timing**
Portal: **admin.microsoft.com** (or **app.fabric.microsoft.com → gear → Admin portal**) **→ Tenant settings**. Search for the specific setting (Git integration, external sharing, guest access). Note: changes are not always instant — allow time before re-testing, and don't stack multiple simultaneous tenant-setting changes when isolating a specific issue.

**Step 5 — For Git integration specifically, confirm provider and permission model**
Only **Azure DevOps** (recommended, GA) and **GitHub** (more limited) are supported. Confirm:
- User has read-write item permission on the workspace (required, not just workspace Admin/Member)
- Repo/branch exists and the connecting account has access to it
- Commit size is under 150 MB and the workspace is under the 1,000-item cap

---

## Common Fix Paths

<details>
<summary>Fix 1 — Capacity paused or deleted</summary>

**If Paused:**
```powershell
# Confirm state
Get-PowerBICapacity -Scope Organization | Select-Object DisplayName, State

# Resume via Azure portal (Fabric capacity is an Azure resource) or Azure CLI:
# az resource update --resource-group <rg> --name <capacityName> `
#     --resource-type "Microsoft.Fabric/capacities" --set properties.state=Active
```
Re-check workspace operations resume within a few minutes of the capacity returning to `Active`.

**If Deleted:**
1. Non-Power BI Fabric items in workspaces assigned to the deleted capacity are **soft-deleted**, not gone — a **7-day recovery window** applies
2. Provision a new capacity **in the same region** as the original
3. Reassign the affected workspace(s) to the new capacity within the 7-day window:
```powershell
Set-PowerBIWorkspace -Id "<workspaceId>" -CapacityId "<newCapacityId>" -Scope Organization
```
4. Confirm items are restored — Lakehouse/Warehouse/Notebook items reappear as usable once reassignment lands within the window

**Rollback:** not applicable for pause/resume. For deletion, recovery is only possible within the 7-day window — after that, items are permanently lost.
</details>

<details>
<summary>Fix 2 — CU-second throttling</summary>

```powershell
# Confirm capacity SKU and current assigned workload count
Get-PowerBICapacity -Scope Organization | Select-Object DisplayName, Sku, State
Get-PowerBIWorkspace -Scope Organization -Include All |
    Where-Object CapacityId -eq "<capacityId>" | Measure-Object
```
1. Open the **Fabric Capacity Metrics app** and identify the time window and workload driving consumption (which item/workspace is consuming the most CU-seconds)
2. Short-term: pause or reschedule non-critical background jobs (pipelines, dataflow refreshes) during peak interactive hours
3. Medium-term: consider a capacity size increase (next F-SKU tier) if sustained overage is a pattern, not a one-off spike
4. Note the 10-minute overage buffer — brief spikes self-resolve; only sustained overage causes user-visible rejection

**Rollback:** revert any SKU size change if it was a one-off spike, not a sustained pattern — right-size based on the Metrics app trend, not a single incident.
</details>

<details>
<summary>Fix 3 — Workspace has no capacity assigned</summary>

```powershell
# Confirm the gap
Get-PowerBIWorkspace -Scope Organization -Include All |
    Where-Object Name -eq "<workspace name>" | Select-Object Name, CapacityId

# Assign to an existing capacity
Set-PowerBIWorkspace -Id "<workspaceId>" -CapacityId "<capacityId>" -Scope Organization
```
1. Confirm the target capacity has headroom (check Metrics app) before assigning another workspace to it
2. If below F64, remind the client that report viewers still need individual Pro licenses — capacity assignment alone doesn't remove that requirement
3. Re-check: Fabric items (Lakehouse/Warehouse/Notebook/Pipeline) should now be creatable in the workspace

**Rollback:** `Set-PowerBIWorkspace -Id "<workspaceId>" -CapacityId $null` to unassign, reverting to Pro-only shared capacity behavior.
</details>

<details>
<summary>Fix 4 — Git integration won't connect or sync fails</summary>

1. Confirm provider: **Azure DevOps is recommended**; GitHub has more limitations — if GitHub is failing, consider migrating the connection to ADO
2. Confirm the connecting user has **read-write item permission** on the workspace — workspace Admin/Member role alone is not sufficient if item-level permissions have been customized
3. Confirm repo/branch access from the connecting account's side (ADO/GitHub), not just the Fabric side
4. Check limits: commit under 150 MB, workspace under 1,000 items
5. Disconnect and reconnect the Git integration from workspace settings if a sync gets stuck in a bad state — this does not delete workspace content, only resets the sync pointer

**Rollback:** Disconnecting Git integration leaves workspace content untouched; it only stops tracking Git history going forward.
</details>

<details>
<summary>Fix 5 — External/guest user can't be added to a workspace</summary>

1. Portal → **Admin portal → Tenant settings** → confirm **"Guest users can access Fabric"** / relevant external sharing settings are **enabled** at the tenant level — per-workspace guest sharing cannot override a tenant-level block
2. Confirm the guest account exists as a B2B guest in Entra ID first (see `EntraID/Troubleshooting/ExternalIdentities-B.md`) — Fabric doesn't provision the guest identity itself
3. Once tenant setting is enabled, add the guest to the workspace via normal workspace access management
4. Allow propagation time before re-testing if the tenant setting was *just* changed

**Rollback:** disable the tenant setting to revert; existing guest access already granted is not automatically revoked by disabling the setting going forward (verify current behavior in the admin portal before assuming otherwise).
</details>

<details>
<summary>Fix 6 — Tenant setting change hasn't taken effect yet</summary>

1. Confirm the change actually saved: **Admin portal → Tenant settings**, re-open the setting and verify current value
2. Note that propagation is **not instant** across a large tenant — avoid making a second conflicting change while waiting, as this compounds troubleshooting difficulty
3. Have the affected user sign out/in or start a new browser session — some settings are cached at the client session level
4. If still not reflected after a reasonable wait, escalate with the exact setting name, the time it was changed, and the time it was last re-verified

**Rollback:** revert the setting to its prior value if the change is confirmed not to be the cause and is causing confusion during triage.
</details>

---

## Escalation Evidence

```
=== FABRIC ADMIN ESCALATION ===
Date/Time      :
Engineer       :
Ticket         :

Affected Workspace : (name + ID)
Capacity Assigned  : (Id, Sku, State — from Get-PowerBICapacity / Get-PowerBIWorkspace)
Capacity Region    :

Symptom            : (all workspaces down / one workspace / slow / Git / sharing / other)
Capacity Metrics App findings : (Overload state observed, time window)

Tenant Setting Involved : (name, current value, last changed)
Workspace Role Note     : (Admin/Member/Contributor bypass OneLake granular security —
                           confirm this isn't a permissions-model misunderstanding)

Steps Attempted:
1.
2.
3.

Expected behaviour :
Actual behaviour   :
```

---

## 🎓 Learning Pointers

- **Capacity state is the first thing to check, always.** A paused or deleted capacity produces a tenant-wide "everything is broken" symptom that looks like a bigger problem than it is — `Get-PowerBICapacity` takes seconds and rules this in or out immediately. [Fabric capacity settings](https://learn.microsoft.com/en-us/fabric/admin/capacity-settings)
- **Deleted capacity has a 7-day soft-delete recovery window** — non-Power BI Fabric items become unusable but aren't immediately destroyed. Reassigning the workspace to a same-region replacement capacity within the window restores them; after 7 days, they're gone. [Workspace capacity reassignment](https://learn.microsoft.com/en-us/fabric/admin/portal-workspace-capacity-reassignment)
- **F64 is the real line, not F2/F4.** Below F64, report viewers still need individual Power BI Pro licenses even with a paid F-SKU assigned — a common client cost-surprise when they assume "we bought Fabric capacity" removes all per-user licensing.
- **OneLake's granular data-access security barely touches internal roles.** Workspace Admin, Member, and Contributor all bypass OneLake's item-level data-access controls entirely — those controls meaningfully restrict only Viewer-tier and external/guest access. Don't assume OneLake security enforces least-privilege among internal collaborators. [OneLake data access control model](https://learn.microsoft.com/en-us/fabric/onelake/security/data-access-control-model)
- **Tenant settings are tenant-wide and not instant.** Resist the urge to toggle a second setting while waiting to see if the first one propagated — it makes root-causing a "still broken" report much harder. [Fabric admin overview](https://learn.microsoft.com/en-us/fabric/admin/admin-overview)
- **Throttling has a grace period.** CU-second overage doesn't throttle immediately — there's roughly a 10-minute buffer before progressive throttling kicks in, so brief spikes are often self-resolving; only sustained overage needs a capacity-sizing conversation. [Capacity throttling](https://learn.microsoft.com/en-us/fabric/enterprise/throttling)
