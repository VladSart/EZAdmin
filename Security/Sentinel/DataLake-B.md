# Microsoft Sentinel Data Lake — Hotfix Runbook (Mode B: Ops)
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

Most "data lake" tickets are one of three things: (1) someone with full Sentinel Contributor rights can't create/schedule a KQL job because data lake access uses a **completely different, Entra-ID-based role system** than Sentinel SIEM's Azure RBAC; (2) a table or query "disappeared" because onboarding silently absorbed auxiliary tables out of Defender Advanced Hunting; or (3) a job/query is timing out or failing on a documented, named limit. Run these first.

```powershell
# 1. Confirm the tenant is actually onboarded to the data lake — look for the managed identity
#    Microsoft creates during onboarding (prefix is fixed: msg-resources-<guid>)
Get-AzRoleAssignment -ResourceGroupName <DataLakeResourceGroup> |
    Where-Object { $_.DisplayName -like "msg-resources-*" }

# 2. Confirm that managed identity has Log Analytics Contributor on the destination workspace
#    (required ONLY for KQL jobs that create NEW custom tables in the analytics tier — a manual,
#    not-automatic grant)
Get-AzRoleAssignment -Scope (Get-AzOperationalInsightsWorkspace -ResourceGroupName <SentinelRG> -Name <SentinelWorkspaceName>).ResourceId |
    Where-Object { $_.DisplayName -like "msg-resources-*" }

# 3. Confirm the AFFECTED USER's Entra ID directory role — NOT their Sentinel Azure RBAC role.
#    Requires Microsoft.Graph.Identity.Governance / Microsoft.Graph.Users
Connect-MgGraph -Scopes "RoleManagement.Read.Directory"
Get-MgUserMemberOf -UserId <user@domain.com> |
    Where-Object { $_.AdditionalProperties.displayName -match "Security Operator|Security Administrator|Global Administrator|Global Reader|Security Reader" }

# 4. Confirm the workspace isn't on Customer-Managed Keys (CMK) — CMK workspaces are NOT
#    accessible via data lake experiences at all, by design
Get-AzOperationalInsightsWorkspace -ResourceGroupName <SentinelRG> -Name <SentinelWorkspaceName> |
    Select-Object Name, PublicNetworkAccessForIngestion, Sku

# 5. If a specific KQL job is failing, check its exact error text against the known table below
#    before assuming it's a permissions problem
```

| Result | Meaning | Action |
|---|---|---|
| #1 returns nothing | Tenant was never onboarded to the data lake | Onboarding must be started from **Defender portal → System → Settings → Microsoft Sentinel → Data lake**; go to [Fix 1](#fix-1--tenant-not-onboarded-or-onboarding-failed-dl102dl103) |
| #2 returns nothing | Jobs can query and promote to existing tables, but **cannot create new custom tables** in the analytics tier | Go to [Fix 2](#fix-2--kql-job-cant-create-a-new-custom-table) |
| #3 shows only a Sentinel Azure RBAC role (Reader/Responder/Contributor), no Entra ID role | User can view/query but **cannot create or schedule KQL jobs** — this is the single most common ticket on this topic | Go to [Fix 3](#fix-3--user-has-full-sentinel-contributor-but-cant-createschedule-a-kql-job) |
| #4 shows a CMK-linked cluster | Data lake experiences are structurally unavailable for this workspace — not a bug, a hard product limitation | Go to [Fix 7](#fix-7--workspace-uses-customer-managed-keys-cmk) |
| All four pass, specific job/query still fails | Root cause is a named KQL/job limit or malformed query | Continue to [Diagnosis & Validation Flow](#diagnosis--validation-flow) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Prerequisites (one-time, before onboarding)
  ├─ Primary Sentinel workspace connected to Defender portal
  ├─ Direct Azure subscription Owner (management-group-level Owner is NOT sufficient)
  ├─ Region supports data lake (data lake is provisioned in the PRIMARY workspace's region only)
  └─ Workspace does NOT use Customer-Managed Keys (CMK)  ◄── hard incompatibility, no workaround

Onboarding (Defender portal, one-time, ~60 min, region/subscription/RG locked after provisioning)
  ├─ Azure Policy must allow Microsoft.SentinelPlatformServices/sentinelplatformservices
  │    (blocked → DL103; capacity issue → DL102)
  └─ Creates managed identity msg-resources-<guid>
       ├─ Auto-granted: Azure Reader over onboarded subscriptions
       └─ NOT auto-granted: Log Analytics Contributor  ◄── manual grant required for KQL jobs
            that create NEW custom tables in the analytics tier

Access (TWO INDEPENDENT SYSTEMS — this is the #1 confusion point)
  ├─ Azure RBAC (Sentinel SIEM)        → Sentinel Reader/Responder/Contributor
  │    controls: incidents, analytics rules, workbooks, playbooks — the SIEM surface
  │    ALSO grants: interactive data lake queries on workspaces the role covers
  │
  └─ Entra ID directory roles (Data lake)  → Global Reader/Security Reader/Security Operator/
       Security Administrator/Global Administrator
       controls: cross-workspace read, ALL job creation/scheduling/management, ALL writes
       A Sentinel Contributor with NO Entra ID role CANNOT create or schedule a KQL job.

Storage tiers
  ├─ Analytics tier — hot, 90 days default (extensible to 2 years), real-time queries
  └─ Data lake tier — cold, up to 12 years, ~15 min ingestion latency, mirrors analytics tier
       data forward from onboarding date (pre-existing data is NOT retroactively mirrored)

Data access tools (pick the right one — see Diagnosis step 1)
  ├─ KQL queries/jobs — up to 12 yr lookback, joins/unions, federated tables supported
  ├─ Summary rules — frequent (20 min+) aggregation, works on non-data-lake tiers too
  ├─ Search jobs — single-table hydration, works on Archive tier
  └─ Federated tables (Databricks/ADLS Gen2/Fabric) — read-only, one-directional, requires
       PUBLIC network accessibility on the external source (no private endpoints)
```

</details>

---
## Diagnosis & Validation Flow

1. **Identify which tool the ticket actually needs — this alone resolves a large share of "it doesn't work" reports.**
   - Need up to 12 years of history, joins/unions, or to query federated tables → **KQL job**.
   - Need frequent (sub-hourly) aggregation of high-volume logs, or the data source is Auxiliary/Basic tier → **Summary rule**.
   - Need to hydrate one specific table from Archive tier, or from before the tenant's data lake onboarding date → **Search job**.
   - Using the wrong tool for the scenario is the most common root cause logged against this topic — confirm before troubleshooting "why doesn't X work."

2. **Confirm onboarding actually completed**, not just started (Triage #1). Onboarding takes up to 60 minutes; newly enabled tables or tables that just switched tiers take an additional **90–120 minutes** before data appears.
   - Expected: `msg-resources-<guid>` managed identity exists in the target resource group.
   - Bad: nothing found — the "Get started" banner in the Defender portal was likely dismissed without completing setup.

3. **Separate "user can view data" from "user can create/schedule jobs."** These use different role systems entirely (Triage #3).
   - Expected: a Sentinel Azure RBAC role AND, separately, one of the five/three Entra ID roles depending on whether they need read-only or write/job-management access.
   - Bad: only a Sentinel Azure RBAC role present — explains "I can query but can't save a job" tickets precisely.

4. **If a KQL job fails, read the exact error text** and match it against the [KQL job error table](#fix-4--kql-job-fails-with-a-specific-error-message) before assuming a permissions or data problem — most job failures are self-explanatory once matched to the correct row.

5. **If data recently ingested isn't showing up in a query**, check timing before escalating: **~15 minutes** typical latency for new rows in existing tables/federated tables, **90–120 minutes** for a table that was just enabled or moved tiers. A query or job scheduled to run immediately after ingestion, with no delay buffer, will appear to "miss" the newest data — this is expected cold-storage behavior, not a fault.

6. **If an auxiliary log table "disappeared" from Defender Advanced Hunting**, this is expected: once a tenant onboards to the data lake, auxiliary tables move into data lake exploration KQL queries/Notebooks and are no longer queryable from Advanced Hunting. Go to [Fix 5](#fix-5--auxiliary-log-table-missing-from-advanced-hunting).

---
## Common Fix Paths

<details><summary>Fix 1 — Tenant not onboarded, or onboarding failed (DL102/DL103)</summary>

Onboarding is one-time, tenant-wide, and starts only from the Defender portal — there is no PowerShell/CLI onboarding path.

1. Sign in to `https://security.microsoft.com` → the onboarding banner appears if not yet onboarded, or go directly to **System → Settings → Microsoft Sentinel → Data lake**.
2. Confirm the account has the required roles (Subscription Owner/Contributor for billing setup, plus Entra ID Global Administrator or Security Administrator for data ingestion authorization) — a permissions side panel appears automatically if not.
3. Select the target **Subscription** and **Resource group**, then **Set up data lake**. This choice is **permanent** — the data lake cannot be migrated to a different subscription/resource group later.
4. If setup fails with **DL102** ("Can't complete setup" — lack of Azure resources in the region): simply retry: transient regional capacity issue.
5. If setup fails with **DL103** ("Can't complete setup" — a policy blocks required resources): add a policy exemption scoped to the target resource group for resource type `Microsoft.SentinelPlatformServices/sentinelplatformservices`, then retry.
6. Allow up to 60 minutes for setup, plus a further 90–120 minutes before newly enabled table data is queryable.

No rollback path exists via self-service — offboarding requires a Microsoft support request (see Fix 6).

</details>

<details><summary>Fix 2 — KQL job can't create a new custom table</summary>

The data lake managed identity only receives **Azure Reader** automatically. Creating a *new* custom table via a KQL job (as opposed to appending to an existing one) additionally requires **Log Analytics Contributor** on that specific destination workspace, granted manually.

```powershell
$sentinelWs = Get-AzOperationalInsightsWorkspace -ResourceGroupName <SentinelRG> -Name <SentinelWorkspaceName>
$identity   = Get-AzADServicePrincipal -DisplayNameBeginsWith "msg-resources-"

New-AzRoleAssignment -ObjectId $identity.Id -RoleDefinitionName "Log Analytics Contributor" -Scope $sentinelWs.ResourceId
```

Rollback: remove the role assignment with `Remove-AzRoleAssignment` using the same scope/principal — this only affects the data lake identity's ability to create/modify tables in that workspace, nothing else.

</details>

<details><summary>Fix 3 — User has full Sentinel Contributor but can't create/schedule a KQL job</summary>

Azure RBAC (Sentinel Contributor) and Entra ID directory roles are **two separate systems** for the data lake. Sentinel Contributor alone never grants job creation rights.

Grant one of these Entra ID roles (Entra admin center → Roles and administrators, or via Graph):
- **Security Operator** — narrowest role that still permits job creation/management.
- **Security Administrator** — broader security-admin scope, also covers this.
- **Global Administrator** — works, but avoid using it just for this; assign the least-privileged option (Security Operator) instead.

```powershell
# Requires RoleManagement.ReadWrite.Directory
Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory"
$role = Get-MgDirectoryRole -Filter "displayName eq 'Security Operator'"
$user = Get-MgUser -UserId "user@domain.com"
New-MgDirectoryRoleMemberByRef -DirectoryRoleId $role.Id -BodyParameter @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)" }
```

Do not assign Global Administrator as a substitute for narrower roles without a documented reason — this is a tenant-wide highly-privileged role, not scoped to Sentinel.

</details>

<details><summary>Fix 4 — KQL job fails with a specific error message</summary>

| Error | Root cause | Fix |
|---|---|---|
| `KQL job name must be unique.` | Job names are unique per **tenant**, including Notebooks jobs, not just per workspace | Rename the job |
| `The specified target table does not exist in the destination workspace.` | Table renamed/deleted, or job created before the table existed | Verify table name and existence before resubmitting |
| `The query output schema does not match the schema of the destination table.` | Column names/count differ from an *existing* destination table | Align the `project`/`project-away` clause to the destination schema exactly |
| `The data types of one or more columns in the query output do not match the destination table schema.` | Type mismatch (e.g. `string` vs `datetime`) | Cast columns explicitly (`todatetime()`, `tostring()`, etc.) |
| `Invalid column name. It should start with a letter and contain only letters, numbers, and underscores (_)` | Output column violates naming rules, or collides with a reserved column (`TenantId`, `_TimeReceived`, `Type`, `SourceSystem`, `_ResourceId`, `_SubscriptionId`, `_ItemId`, `_BilledSize`, `_IsBillable`, `_WorkspaceId`) | Rename the offending column — reserved columns are always overwritten by the ingestion pipeline regardless of query output |
| `Unsupported function... ingestion_time().` (or `adx()`, `arg()`, `externaldata()`) | These four functions are unsupported in data lake KQL, jobs and interactive alike | Remove the function; find an alternative expression |
| `Query execution has exceeded the allowed limits.` (interactive query) | Interactive KQL queries in the data lake cap at 500,000 rows | Move the query into a **KQL job** (no row cap on job output, subject to the 1-hour timeout) or use Notebooks |
| Job silently produced fewer rows than expected | Query exceeded the 1-hour job timeout — **partial results are promoted**, not a full failure | Narrow the time range or add filters, then re-run |

</details>

<details><summary>Fix 5 — Auxiliary log table missing from Advanced Hunting</summary>

This is **expected behavior once the data lake is onboarded**, not a data-loss incident:

- Auxiliary log tables in Defender-connected workspaces onboarded to the data lake are absorbed into data lake exploration and are **no longer accessible from Defender Advanced Hunting**.
- The data itself is not lost — it's queryable via **Microsoft Sentinel → Data lake exploration → KQL queries** or Notebooks in the Defender portal instead.
- Confirm with the requester which portal surface they were using before treating this as an outage.

No fix needed beyond redirecting the user to the correct query surface; this cannot be reverted short of a full data lake offboarding (Fix 6).

</details>

<details><summary>Fix 6 — Need to disable/offboard the data lake entirely</summary>

There is no self-service offboarding toggle. [Submit a support request](https://learn.microsoft.com/en-us/defender-xdr/contact-defender-support) explicitly requesting Microsoft Sentinel data lake offboarding.

Before requesting this, confirm the business driver — offboarding reverses table visibility (auxiliary tables return to Advanced Hunting) and disables all KQL jobs, federated connections, and Notebooks-on-the-lake access for the whole tenant, not just one workspace. Individual workspaces also cannot be selectively removed from an onboarded data lake while it remains active — that too requires a support request.

</details>

<details><summary>Fix 7 — Workspace uses Customer-Managed Keys (CMK)</summary>

CMK-protected workspaces are **not accessible via any data lake experience** — this is a hard platform limitation, not a configuration gap to fix.

- Confirm via `Get-AzOperationalInsightsWorkspace` and checking the linked Log Analytics **cluster's** key configuration (CMK is set at the dedicated cluster level, not the workspace itself).
- There is no supported workaround short of migrating the workspace off CMK, which is a separate, high-impact change requiring its own change-management process — do not attempt this solely to unblock data lake access without a full risk review, since CMK is very often mandated by the client's own compliance posture.
- Set expectations with the requester up front: this is a documented incompatibility Microsoft has not published a timeline to resolve.

</details>

---
## Escalation Evidence

```
SENTINEL DATA LAKE ISSUE — ESCALATION TEMPLATE
================================================
Client / Tenant:
Primary Sentinel workspace name + region:
Data lake subscription / resource group:
Onboarded? (confirm via msg-resources-<guid> presence):

Affected user (UPN):
Sentinel Azure RBAC role (Triage #3, Azure side):
Entra ID directory role (Triage #3, Graph side):

Tool in use: [ ] KQL query  [ ] KQL job  [ ] Summary rule  [ ] Search job  [ ] Federated table  [ ] Notebook
Exact error text:
Job name (if applicable):
Source table(s) / destination table:
Time range / lookback used:

CMK in use on this workspace? (Y/N):
Onboarding completed >120 minutes ago? (Y/N):

Steps already attempted:
1.
2.
3.

Escalating to: [Tier 3 / Sentinel platform team / Microsoft Support (offboarding, DL102/DL103 persisting)]
```

---
## 🎓 Learning Pointers
- The data lake's access model is **not** an extension of Sentinel SIEM's Azure RBAC — it's a parallel system built on Entra ID directory roles. This is a different shape of "two independent gates" than `Notebooks-A.md`'s two-Azure-resource split, but the same underlying trap: full Sentinel Contributor rights say nothing about data lake write/job access. See [Roles and permissions for the Microsoft Sentinel data lake](https://learn.microsoft.com/en-us/azure/sentinel/roles#roles-and-permissions-for-the-microsoft-sentinel-data-lake).
- Picking the wrong tool (KQL job vs. Summary rule vs. Search job) generates more "broken" tickets than any actual defect in this topic — see [KQL jobs, summary rules, and search jobs](https://learn.microsoft.com/en-us/azure/sentinel/datalake/kql-jobs-summary-rules-search-jobs) and internalize the decision table before troubleshooting further.
- Onboarding is a one-way, tenant-wide, subscription/resource-group-locked decision with no self-service reversal — treat the initial subscription/RG choice with the same weight as any other irreversible platform decision documented elsewhere in this repo (compare purge-protected Key Vaults and immutable Backup vaults).
- Cold-storage ingestion latency (~15 min routine, 90–120 min for newly enabled tables/tier switches) is architecture, not a fault — build a `now() - 15m` delay buffer into any scheduled KQL job the same way `Hunting-A.md` recommends for other Sentinel scheduled content.
- Data federation is one-directional and requires the **external** source to be publicly network-accessible — a client asking to federate a private-endpoint-only Databricks or Fabric workspace needs to know upfront that this isn't currently supported, not after a failed connector setup. See [Data federation overview](https://learn.microsoft.com/en-us/azure/sentinel/datalake/data-federation-overview).
