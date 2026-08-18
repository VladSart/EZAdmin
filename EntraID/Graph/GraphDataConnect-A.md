# Microsoft Graph Data Connect — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

Covers **Microsoft Graph Data Connect (MGDC)** — the bulk, at-scale Microsoft 365 data extraction service that copies Microsoft 365 datasets into **Microsoft Fabric, Azure Synapse Analytics, or Azure Data Factory** for enterprise analytics (customer relationship analytics, business process analytics, security/compliance analytics, people-productivity/Viva Insights analytics). Covers the onboarding/consent architecture, dataset model, region and tenant-boundary constraints, billing mechanics, and the RBAC/ownership requirements that gate every step.

**Explicitly out of scope:**
- **Microsoft Graph API** (transactional, small-scope, near-real-time access) — the sibling tool this repo already covers in `GraphAPI-BatchOperations-A.md`/`-B.md` and `Useful-Queries.md`. See [When should I use Microsoft Graph API or Data Connect](https://learn.microsoft.com/en-us/graph/overview#when-should-i-use-microsoft-graph-api-or-data-connect) for the decision framework — MGDC and Graph API access the *same underlying data* through architecturally different delivery mechanisms.
- **Viva Insights** — a complementary but separate first-party analytics application built partly on top of MGDC-style extraction; Viva Insights has its own licensing and admin surface, not covered here.
- **Delta query (`/delta`)** — a Graph API incremental-sync mechanism, unrelated to MGDC's pipeline-based bulk model.
- Downstream Power BI report design, Fabric workspace administration, or Azure Synapse/Data Factory general administration beyond what's needed to stand up an MGDC pipeline.
- Per-application data-governance/DLP policy design over the extracted data once it lands in Azure — that's a Purview/Azure governance conversation, not an MGDC configuration.

---
## How It Works

<details><summary>Full architecture</summary>

MGDC is fundamentally a **granular consent + scheduled bulk-copy pipeline service**, not a query API. Where Microsoft Graph API grants or denies an application access to *entire entities* (a user's full mailbox, for example), MGDC's consent model is scoped to a specific combination of **dataset + columns + user list + destination sink**. Changing any one of those four dimensions requires a fresh admin consent; running the same pipeline again with the same scope for a different date range does not.

**Dataset model — three tiers:**
- **Basic datasets** — raw customer-created content and inputs, extracted close to source (e.g., `Message`, `CalendarEvent`, Entra `User`/`Group` objects).
- **Cleaned datasets** — normalized/deduplicated derivatives of basic datasets, or datasets built from user activity/behavior signals.
- **Curated datasets** — purpose-built for a specific analytics scenario, including datasets sourced from other first-party Microsoft 365 analytics applications (Viva Insights, SharePoint).

Datasets span five source families and grow over time: **Teams, Outlook, Microsoft Entra ID, OneDrive/SharePoint, Viva Insights.** Individual datasets may be GA or Preview independently — Preview datasets require explicit tenant opt-in and are not automatically visible in the registration wizard.

**Onboarding flow (five stages, each gated by a distinct identity/role):**

1. **Tenant admin enables MGDC** — a single tenant-wide boolean toggle in the M365 admin center (Org settings → Services → Microsoft Graph Data Connect). This is a prerequisite gate, not itself a consent grant.
2. **Developer creates an Entra application registration** — this app's service principal becomes MGDC's identity when it later requests authorized access to the tenant's Microsoft 365 data. The app **owner** (not the app itself) must be a real, non-guest user who additionally holds an Exchange Online mailbox and an E5-qualifying license — a requirement that has nothing to do with what the app actually does, and fails silently (a "Developer email not found" error, or simply a non-functional registration) rather than with a clear permission-denied message.
3. **Developer registers the app with MGDC** via the dedicated Azure portal MGDC experience (`aka.ms/mgdcinazure`), explicitly selecting the dataset(s), column(s), and (implicitly) user scope the app needs. This is where the granular, sub-entity consent model becomes concrete — unlike a Graph API permission scope (e.g., `Mail.Read`), an MGDC registration says "give me exactly these columns of exactly this dataset."
4. **A different Global Administrator approves the app** in the M365 admin center (Org settings → Security & privacy → Microsoft Graph Data Connect applications). The app shows **Pre-consent** until approved. Two hard rules govern this step: only **Global Administrator** can approve (not Security Administrator, not Application Administrator — a deliberate carve-out, since app consent here is treated as a data-export decision, not an app-management decision), and the approving account **cannot be the same account** that registered the app (self-approval is blocked).
5. **Developer runs pipelines** — after approval, subsequent runs with the same scope require no further consent interaction; the pipeline uses the already-approved consent record.

**Pipeline mechanics:** MGDC uses Microsoft Fabric, Azure Synapse, or Azure Data Factory purely as the **orchestration and compute layer** — the actual authorization and data-boundary enforcement happens inside MGDC itself, keyed off the app's service principal. A pipeline run progresses through documented activity states: `Initializing` → `Consent Pending` (only meaningfully observed on the very first run, or after a consent lapse) → `Extracting Data` → `Persisting Data` → `Succeeded`. All pipelines carry a fixed **~45-minute minimum overhead** regardless of data volume — this is architectural (extraction is inherently a bulk-batch operation, not a low-latency one), not a performance problem to troubleshoot.

**Tenant-boundary and region enforcement — two independent hard constraints, easily confused for each other:**
- **Tenant boundary:** the Azure subscription and the Microsoft 365 tenant must be in the **same Entra tenancy**. Cross-tenant extraction (e.g., an MSP's own Azure subscription extracting a client tenant's M365 data) is not supported at all — there is no consent flow that permits it.
- **Region boundary:** a single pipeline can only extract data for **one Office region** (the geography a tenant's data is hosted in, e.g., North America, Europe, UK, Australia, Asia-Pacific), determined by the Azure region the pipeline's integration runtime runs in. Multi-geo tenants (organizations with users split across regions) must stand up **one pipeline per region**, not one pipeline with a broader user scope. Attempting to extract cross-region users through a single pipeline silently returns only the subset matching the pipeline's own region — not an error, just an incomplete result set that looks like a scoping bug.

**Billing model:** MGDC bills per **pipeline run**, not per row, with fractional-unit rounding **always rounding up**. A pipeline extracting 500 rows is billed as a full 1,000-row unit; running the same 500-row extraction 20 times in a month bills as 20 units (20,000-row equivalent), not the 10,000-row-actual/10-unit total a naive calculation would suggest. Billing has been mandatory for all Fabric-based MGDC pipelines since January 31, 2024, enforced via a `Microsoft.GraphServices` Azure resource provider registration on the subscription — if that provider isn't registered, app registration itself fails with an opaque authorization error that has nothing to do with permissions in the RBAC sense.

</details>

---
## Dependency Stack

```
Microsoft Entra tenant (single tenancy shared by M365 and Azure)
        │
MGDC tenant-wide enablement toggle (M365 admin center)
        │
Microsoft.GraphServices resource provider registered (Azure subscription — billing gate)
        │
Entra app registration
   ├── App owner: non-guest, Exchange Online mailbox, E5-qualifying license
   └── App service principal — becomes MGDC's authorized identity
        │
App registered with MGDC (Azure portal aka.ms/mgdcinazure)
   └── Dataset + column + (implicit) user scope selected
        │
Global Administrator approval (M365 admin center) — Pre-consent → Approved
   └── MUST be a different account than the one that registered the app
        │
Destination sink
   ├── Azure Storage account — region-compatible with tenant's Office region mapping
   ├── Service principal granted Storage Blob Data Contributor on the sink
   └── Storage network rules (if closed to public access) allow-listing the
       Azure region IP ranges mapped to the tenant's Office region
        │
Orchestration layer — Microsoft Fabric / Azure Synapse / Azure Data Factory
   └── Microsoft 365 linked service (authenticates as the app's service principal)
        │
Pipeline execution: Initializing → Consent Pending (first run) →
                     Extracting Data → Persisting Data → Succeeded
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Can't find MGDC in the Azure portal / registration wizard errors immediately | Tenant-wide MGDC toggle is off | M365 admin center → Org settings → Services |
| "No authorization" creating/updating an app registration | `Microsoft.GraphServices` resource provider not registered on the subscription | `Get-AzResourceProvider -ProviderNamespace Microsoft.GraphServices` |
| Registration wizard completes, but app never becomes usable / "Developer email not found" | App owner is a guest user, or lacks a mailbox/E5 license | `Get-MgApplicationOwner` → `Get-MgUser` on each owner |
| App stuck at "Pre-consent" indefinitely | Approver isn't a true Global Admin, or is the same account that registered the app | Confirm approver's Entra role and identity |
| Pipeline run stuck at "Consent Pending" past ~40 minutes | Same as above — no admin has approved yet, or approval attempt is silently failing | M365 admin center → Security & privacy → MGDC applications |
| Previously-working pipeline suddenly requires re-consent | App consent expired | M365 admin center → re-approve the app before renewal is even needed next time |
| Row counts consistently below total user count, no error | Hybrid on-prem Exchange users or resource accounts silently excluded | Confirm mailbox location / recipient type for missing users |
| Pipeline fails at "Persisting Data" | Storage RBAC missing, or storage firewall blocking MGDC's region-mapped IP ranges | `Get-AzRoleAssignment` on the SP + storage account; `Get-AzStorageAccountNetworkRuleSet` |
| Multi-geo tenant: only one region's users ever extracted | One pipeline can only serve one Office region | Confirm pipeline's integration-runtime region vs. Office-to-Azure mapping |
| Duplicate email records in extracted `Message` data | Expected — one copy per recipient mailbox | Deduplicate on `internetMessageId` across all output blobs |
| Multiple JSON files per single pipeline run | Expected — MGDC parallelizes extraction across jobs by user-list size | Add a downstream Copy-data-with-Merge-files activity if a single file is required |
| Billed units higher than expected for the row count | Per-run rounding-up billing, not per-row | Recalculate: billed units = number of pipeline runs × ceiling(rows-per-run / 1000) |

---
## Validation Steps

1. **Confirm tenant boundary alignment.**
   ```powershell
   (Get-AzContext).Tenant.Id
   (Get-MgOrganization).Id
   ```
   Good: identical tenant GUIDs. Bad: any mismatch — extraction is architecturally impossible until resolved (there is no workaround; the subscription must be associated with the correct Entra tenant).

2. **Confirm resource provider registration.**
   ```powershell
   Get-AzResourceProvider -ProviderNamespace "Microsoft.GraphServices" | Select-Object ProviderNamespace, RegistrationState
   ```
   Good: `Registered`. Bad: `NotRegistered` or `Unregistering` — app registration will fail with an opaque authorization error until this is `Registered`.

3. **Confirm app owner eligibility.**
   ```powershell
   Get-MgApplicationOwner -ApplicationId "<app-object-id>" | ForEach-Object {
       Get-MgUser -UserId $_.Id -Property DisplayName, UserType, Mail, AssignedLicenses
   }
   ```
   Good: `UserType = Member`, non-null `Mail`, at least one assigned license expected to be E5-tier (verify tier by SKU display name against the tenant's actual licensing agreement — SKU part numbers vary by agreement type; don't assume a specific GUID). Bad: any owner with `UserType = Guest`.

4. **Confirm app consent status.** Portal-only — M365 admin center → Org settings → Security & privacy → Microsoft Graph Data Connect applications. Good: `Approved`. Bad: `Pre-consent` persisting beyond a reasonable admin-response window, or `Expired`.

5. **Confirm service principal storage RBAC.**
   ```powershell
   Get-AzRoleAssignment -ObjectId "<sp-object-id>" -Scope "<storage-account-resource-id>" |
     Where-Object RoleDefinitionName -eq "Storage Blob Data Contributor"
   ```
   Good: at least one matching assignment. Bad: none — pipeline will fail at "Persisting Data."

6. **Confirm storage network posture (if firewall-restricted).**
   ```powershell
   Get-AzStorageAccountNetworkRuleSet -ResourceGroupName "<rg>" -Name "<storage-account>"
   ```
   Good: `DefaultAction = Allow`, or `Deny` with IP rules covering the Azure region mapped to the tenant's Office region. Bad: `Deny` with no matching IP rules, or a storage account physically located in the same region the Office region maps to while also closed to public access (architecturally incompatible — see Remediation Playbook 2).

7. **Confirm pipeline activity state progression** in the ADF/Synapse/Fabric monitor. Good: clean progression through `Initializing → Extracting Data → Persisting Data → Succeeded`. Bad: any state stuck for far longer than its typical window (Consent Pending > ~1 hour with no admin action; Extracting/Persisting stalled with no progress for the data volume involved).

---
## Troubleshooting Steps (by phase)

**Phase 1 — Pre-registration (tenant/subscription level):**
Confirm tenant-boundary alignment and MGDC tenant enablement before touching app registration at all. Both are prerequisite gates that produce confusing downstream errors if skipped.

**Phase 2 — App registration:**
Confirm resource provider registration first (billing gate), then app owner eligibility (guest/mailbox/license). These two account for the large majority of "registration looks broken" tickets.

**Phase 3 — Consent/approval:**
Confirm the approving identity is a true Global Administrator and is not the registering account. If consent has been previously granted, distinguish an expired-consent renewal (Remediation Playbook 1) from a fresh registration issue — the fix paths are different.

**Phase 4 — Pipeline execution:**
Confirm storage RBAC and network posture before assuming a data or scope problem. A pipeline that reaches "Extracting Data" successfully has already cleared every identity/consent gate — failures from this point forward are almost always destination-sink or region-mapping issues, not authorization issues.

**Phase 5 — Data validation:**
Confirm expected exclusions (hybrid on-prem mailboxes, resource accounts) and expected duplication/multi-file behavior before treating either as a defect.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full first-time onboarding for a new MGDC pipeline</summary>

1. Confirm tenant/subscription boundary alignment (Validation Step 1).
2. Global Admin enables MGDC tenant-wide (M365 admin center → Org settings → Services).
3. Subscription admin registers `Microsoft.GraphServices`:
   ```powershell
   az provider register --namespace 'Microsoft.GraphServices'
   ```
4. Developer creates an Entra app registration; adds a non-guest, E5-licensed, mailbox-holding user as owner.
5. Developer creates the destination Azure Storage account in a region compatible with the tenant's Office-to-Azure mapping; grants the app's service principal **Storage Blob Data Contributor** on it.
6. Developer registers the app with MGDC at `aka.ms/mgdcinazure`, selecting the exact dataset(s)/column(s) needed.
7. A **different** Global Administrator reviews and approves the app (M365 admin center → Security & privacy → MGDC applications).
8. Developer builds the pipeline in Fabric/Synapse/ADF referencing the Microsoft 365 linked service (service principal credentials) and the approved dataset, with an appropriate date filter.
9. Trigger a test run; expect the full ~40+ minute first-run cycle including the Consent Pending stage (already satisfied by step 7, so this should resolve automatically rather than stall).
10. Verify output in the destination storage container before scheduling recurring runs.

No destructive steps — safe to run end-to-end in a test/dev environment first.

</details>

<details><summary>Playbook 2 — Resolving a storage-account region/firewall incompatibility</summary>

Applies when a customer wants the destination storage account closed to public network access, but it's located in the same Azure region their Office region maps to (architecturally incompatible with MGDC's region-scoped delivery IPs).

1. Identify the tenant's Office region and its default Azure region mapping (see the Command Cheat Sheet region table).
2. Identify a documented **alternate/paired Azure region** for that Office region (e.g., North Europe as the alternate for a West-Europe-mapped EUR tenant).
3. Create a new storage account in the alternate region, or migrate the existing one — note this is a genuine data-movement operation with its own migration considerations (AzCopy/Storage Mover), not a simple firewall-rule edit.
4. Re-grant the app's service principal **Storage Blob Data Contributor** on the new/moved account.
5. Update the pipeline's linked service to point at the new storage account.
6. Allow-list the correct Azure Storage service IP ranges for the mapped region (from [Azure IP Ranges and Service Tags](https://www.microsoft.com/download/details.aspx?id=56519)) on the storage account firewall.
7. Re-run the pipeline and confirm successful delivery.

**Rollback:** if step 3 (region migration) is deemed too disruptive, fall back to `DefaultAction = Allow` on the original storage account (network-open) as an interim state — this immediately unblocks delivery at the cost of the firewall restriction, and should be flagged to the client as a temporary compensating control, not a permanent fix.

</details>

<details><summary>Playbook 3 — Standing up per-region pipelines for a multi-geo tenant</summary>

1. Obtain the tenant's list of Office regions in use (from the Microsoft 365 admin center's multi-geo configuration, or by asking the client's Global Admin — this isn't directly queryable via a documented Graph endpoint at the time of writing).
2. For each Office region: create a dedicated pipeline with its integration runtime pinned to the Azure region that maps to that Office region.
3. Register/approve a single MGDC app registration that can serve all pipelines (app registration itself is not region-specific — only the pipeline's user-scope-per-run is), or separate apps if the client wants isolated consent boundaries per region.
4. Validate each pipeline independently returns only its expected regional user subset — this is correct behavior, not a scoping bug, and should be documented as such for the client's downstream data consumers (a report combining all regions must union the outputs of every regional pipeline).

</details>

<details><summary>Playbook 4 — Client conversation: explaining MGDC billing after an unexpectedly high invoice</summary>

1. Pull the pipeline run history (ADF/Synapse/Fabric monitor) for the billing period in question — count total runs, not total rows.
2. For each run, note the approximate row count extracted.
3. Recalculate expected billed units: for each run, `ceiling(rows_extracted / 1000)`, summed across all runs.
4. Compare against the actual invoice. The most common driver of "unexpectedly high" bills is **many small, frequent pipeline runs** (e.g., hourly triggers extracting a small delta each time) rather than fewer, larger scheduled runs.
5. Recommend consolidating trigger frequency (e.g., daily instead of hourly) if the analytics use case tolerates the latency, since each run is billed with a fixed rounding-up floor regardless of how little data it moved.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects MGDC-adjacent evidence for escalation — everything reachable via
    Az/Microsoft.Graph. Portal-only state (tenant toggle, app consent status,
    pipeline run history) must be captured manually per the Escalation Evidence
    template in GraphDataConnect-B.md.
#>
param(
    [Parameter(Mandatory)] [string]$AppObjectId,
    [Parameter(Mandatory)] [string]$ServicePrincipalObjectId,
    [Parameter(Mandatory)] [string]$StorageAccountResourceId
)

Write-Host "=== Tenant/Subscription boundary ===" -ForegroundColor Cyan
[PSCustomObject]@{
    AzureTenantId = (Get-AzContext).Tenant.Id
    EntraTenantId = (Get-MgOrganization).Id
} | Format-List

Write-Host "=== Microsoft.GraphServices resource provider ===" -ForegroundColor Cyan
Get-AzResourceProvider -ProviderNamespace "Microsoft.GraphServices" |
  Select-Object ProviderNamespace, RegistrationState | Format-Table

Write-Host "=== App owners ===" -ForegroundColor Cyan
Get-MgApplicationOwner -ApplicationId $AppObjectId | ForEach-Object {
    Get-MgUser -UserId $_.Id -Property DisplayName, UserType, Mail, AssignedLicenses |
      Select-Object DisplayName, UserType, Mail, @{N='LicenseCount';E={$_.AssignedLicenses.Count}}
} | Format-Table

Write-Host "=== Service principal storage RBAC ===" -ForegroundColor Cyan
Get-AzRoleAssignment -ObjectId $ServicePrincipalObjectId -Scope $StorageAccountResourceId |
  Select-Object RoleDefinitionName, Scope | Format-Table

Write-Host "=== Storage account network rules ===" -ForegroundColor Cyan
$storage = Get-AzResource -ResourceId $StorageAccountResourceId
Get-AzStorageAccountNetworkRuleSet -ResourceGroupName $storage.ResourceGroupName -Name $storage.Name |
  Format-List DefaultAction, IpRules, VirtualNetworkRules
```

---
## Command Cheat Sheet

```powershell
# Resource provider registration
Get-AzResourceProvider -ProviderNamespace "Microsoft.GraphServices"
az provider register --namespace 'Microsoft.GraphServices'

# App owner check
Get-MgApplicationOwner -ApplicationId "<app-object-id>"
Get-MgUser -UserId "<owner-id>" -Property DisplayName,UserType,Mail,AssignedLicenses

# Add a valid app owner
New-MgApplicationOwnerByRef -ApplicationId "<app-object-id>" -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/<user-id>"
}

# Storage RBAC
Get-AzRoleAssignment -ObjectId "<sp-object-id>" -Scope "<storage-account-resource-id>"
New-AzRoleAssignment -ObjectId "<sp-object-id>" -RoleDefinitionName "Storage Blob Data Contributor" -Scope "<storage-account-resource-id>"

# Storage network rules
Get-AzStorageAccountNetworkRuleSet -ResourceGroupName "<rg>" -Name "<storage-account>"

# Tenant boundary check
(Get-AzContext).Tenant.Id
(Get-MgOrganization).Id
```

**Office-to-Azure region mapping (subset — verify current mapping before use, Microsoft adds regions periodically):**

| Office region | Primary Azure region |
|---|---|
| North America | East US / Central US / West US / etc. |
| Europe | West Europe / North Europe |
| United Kingdom | UK South / UK West |
| Australia | Australia East / Australia Southeast |
| Asia-Pacific | East Asia / Southeast Asia |
| Canada | Canada Central / Canada East |
| Japan | Japan East / Japan West |
| Germany, France, Norway, Switzerland | Own primary region, alternates to North/West Europe |

Full current mapping and destination-storage-region restrictions: [Datasets, regions, and sinks](https://learn.microsoft.com/en-us/graph/data-connect-datasets#regions).

---
## 🎓 Learning Pointers

- **MGDC's consent model is fundamentally more granular than Graph API's, and that granularity is the entire point of the product** — it exists precisely because bulk data-export governance needs dataset+column+user+sink-level control, not entity-level allow/deny. Understanding this reframes almost every "why is this so locked down" question a client asks.
- **The Global-Admin-only, self-approval-blocked consent gate is a deliberate governance decision, not an oversight** — MGDC treats bulk data export as categorically more sensitive than ordinary app permission consent, which is why even Application Administrator (normally the "owns app lifecycle" role) is excluded.
- **The 72-hour-style "why isn't this live" intuition doesn't apply here the way it does with, say, Secure Score or Exposure Management** (see `Security/ExposureManagement/ExposureManagement-A.md` for a contrasting near-real-time-but-not-quite model) — MGDC has no ambient sync at all; freshness is purely a function of pipeline schedule.
- **Billing-by-run-not-by-row is the kind of cost surprise worth flagging proactively** during any Fabric/Synapse cost-optimization engagement that touches an MGDC-based analytics pipeline.
- [MS Docs: Microsoft Graph Data Connect overview](https://learn.microsoft.com/en-us/graph/data-connect-concept-overview) · [MS Docs: Data Connect FAQ](https://learn.microsoft.com/en-us/graph/data-connect-faq) · [MS Docs: Troubleshoot Microsoft Graph Data Connect](https://learn.microsoft.com/en-us/graph/data-connect-troubleshooting) · [MS Docs: Build your first Microsoft Graph Data Connect application](https://learn.microsoft.com/en-us/graph/data-connect-quickstart)
