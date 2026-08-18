# Microsoft Graph Data Connect — Hotfix Runbook (Mode B: Ops)
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

Microsoft Graph Data Connect (MGDC) has **no dedicated PowerShell module** — its own state (tenant enablement toggle, app consent status, pipeline run status) lives entirely in the Microsoft 365 admin center, the Azure portal MGDC experience, and the ADF/Synapse/Fabric monitor UI. Triage is a mix of portal checks and `Az`/`Microsoft.Graph` cmdlets for the pieces that *do* have an API.

```powershell
# 1. Is Microsoft.GraphServices resource provider registered in the Azure subscription? (billing gate — blocks app registration if missing)
Connect-AzAccount
Get-AzResourceProvider -ProviderNamespace "Microsoft.GraphServices" | Select-Object ProviderNamespace, RegistrationState

# 2. Does the Entra app registration have a valid (non-guest, licensed) owner?
Connect-MgGraph -Scopes "Application.Read.All","User.Read.All"
$appOwners = Get-MgApplicationOwner -ApplicationId "<app-object-id>"
$appOwners | ForEach-Object { Get-MgUser -UserId $_.Id -Property DisplayName,UserType,Mail,AssignedLicenses |
  Select-Object DisplayName, UserType, Mail, @{N='LicenseCount';E={$_.AssignedLicenses.Count}} }

# 3. Does the app's service principal have Storage Blob Data Contributor on the destination storage account?
Get-AzRoleAssignment -ObjectId "<service-principal-object-id>" -Scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage-account>"

# 4. Is the destination storage account network-open (or correctly allow-listed for the mapped Azure region)?
Get-AzStorageAccountNetworkRuleSet -ResourceGroupName "<rg>" -Name "<storage-account>"

# 5. (Portal, no cmdlet) Tenant enablement toggle + app consent status
#    M365 admin center → Settings → Org settings → Services → Microsoft Graph Data Connect (tenant toggle)
#    M365 admin center → Settings → Org settings → Security & privacy → Microsoft Graph Data Connect applications (Pre-consent / Approved)
```

| Result | Interpretation |
|---|---|
| `RegistrationState` = `NotRegistered` | → Fix 2 |
| App owner is `UserType = Guest`, or has 0 assigned licenses, or no `Mail` | → Fix 3 |
| No `Storage Blob Data Contributor` role assignment found for the SP | → Fix 7 (storage RBAC) |
| Storage account `DefaultAction = Deny` and no IP rules for the mapped region | → Fix 7 (network) |
| App shows `Pre-consent` in the M365 admin center for more than a few hours | → Fix 4 |
| Tenant toggle is off | → Fix 1 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
M365 tenant and Azure subscription in the SAME Microsoft Entra tenancy
        │
Global Admin enables MGDC tenant-wide (M365 admin center → Org settings → Services)
        │
Microsoft.GraphServices resource provider registered in the Azure subscription (billing)
        │
Entra app registration exists — owner is a real (non-guest) user with an Exchange
Online mailbox AND an E5-qualifying license
        │
App registered with MGDC in the Azure portal (aka.ms/mgdcinazure) — dataset(s),
column(s), and user scope explicitly selected
        │
A DIFFERENT Global Admin approves the app in the M365 admin center
(Pre-consent → Approved) — self-approval by the developer account is blocked
        │
Destination storage account exists in a region compatible with the tenant's
Office-to-Azure region mapping; app's service principal granted
Storage Blob Data Contributor on it
        │
ADF / Synapse / Fabric pipeline references the Microsoft 365 linked service
(service principal ID + secret) and the target dataset, with a date filter
        │
Pipeline run: Initializing → Consent Pending (first run only) →
Extracting Data → Persisting Data → Succeeded
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm same-tenant boundary.** MGDC has zero cross-tenant support — the Azure subscription hosting the pipeline resources and the Microsoft 365 tenant must resolve to the same Entra tenant ID. If a customer routes M365 data extraction through a partner/MSP Azure subscription in a different tenant, this fails architecturally, not as a bug.
   ```powershell
   (Get-AzContext).Tenant.Id   # Azure side
   (Get-MgOrganization).Id     # M365/Entra side — must match
   ```

2. **Confirm the tenant-wide toggle is on.** M365 admin center → Settings → Org settings → Services tab → **Microsoft Graph Data Connect**. If a tenant previously had MGDC enabled and a pipeline starts failing tenant-wide with no other change, ask whether an admin recently toggled it off/on — Microsoft's own guidance is that toggling it off then back on is the documented reset step for a stuck registration state.

3. **Confirm resource provider registration** (Triage step 1). This gate is specifically for **billing** — MGDC has been metered for all Fabric pipelines since January 31, 2024, and a missing `Microsoft.GraphServices` registration surfaces as an opaque "no authorization" error at app-registration time, not a billing-specific message.

4. **Confirm app owner eligibility** (Triage step 2). This is the single most common "registration looks successful but then errors" root cause — see Fix 3.

5. **Confirm approver identity.** The user approving in the M365 admin center must be a **Global Administrator** (not Security Administrator, not Application Administrator) and must be a **different account** than the one that registered the app. An E5 license is explicitly **not** required to approve.

6. **Confirm storage RBAC and network posture** (Triage steps 3–4). Pipeline failures at the "Persisting Data" stage are almost always here.

7. **Confirm region alignment** if only a subset of users are missing from extracted data — see Fix 8.

---
## Common Fix Paths

<details><summary>Fix 1 — MGDC not enabled tenant-wide</summary>

**Symptom:** App registration wizard can't find the tenant, or a previously-working setup suddenly can't register new apps.

1. M365 admin center → Settings → Org settings → Services tab → Microsoft Graph Data Connect.
2. Confirm the **Turn Microsoft Graph Data Connect on or off for your entire organization** checkbox is selected. Save.
3. If it was already checked and the problem persists, Microsoft's documented reset is to uncheck, save, re-check, save — this re-initializes the tenant's MGDC registration state.

No rollback risk — this is a simple on/off tenant setting with no destructive side effects.

</details>

<details><summary>Fix 2 — "No authorization" creating/updating an app registration (Microsoft.GraphServices not registered)</summary>

**Symptom:** Azure portal MGDC experience shows an error creating a billing resource of type `Microsoft.GraphServices` during app registration/update.

```powershell
# Subscription admin runs this once per subscription
az provider register --namespace 'Microsoft.GraphServices'

# If the app-specific billing resource still isn't created automatically, create it explicitly:
az resource create `
  --resource-group <resource_group_name> `
  --name "mgdc-<app_id>" `
  --resource-type Microsoft.GraphServices/accounts `
  --properties '{"appId": "<app_id>"}' `
  --location Global `
  --subscription <subscription_id>
```

If the error is instead **"Already premium usage"**, a `Microsoft.GraphServices` resource already exists for this app under a different name — this is informational, no action needed.

</details>

<details><summary>Fix 3 — "Developer email not found" / registration succeeds but the app never works</summary>

**Symptom:** App registration wizard completes without error, but the app is unusable, or the M365 admin center never shows it for approval.

**Root cause:** the app's owner is a **guest user**. MGDC registration silently requires a non-guest owner.

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All","User.Read.All"

# Check current owners
Get-MgApplicationOwner -ApplicationId "<app-object-id>" | ForEach-Object {
    Get-MgUser -UserId $_.Id -Property DisplayName, UserType, Mail
}

# Add a valid (non-guest) owner — this user must ALSO have an Exchange Online
# mailbox AND an E5-qualifying license, or the same failure recurs
$newOwner = Get-MgUser -UserId "admin@contoso.com"
New-MgApplicationOwnerByRef -ApplicationId "<app-object-id>" -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($newOwner.Id)"
}
```

</details>

<details><summary>Fix 4 — App stuck at "Pre-consent" / pipeline stuck at "Consent Pending"</summary>

**Symptom:** App shows `Pre-consent` in the M365 admin center indefinitely, or a pipeline run sits at the `Consent Pending` activity status for far longer than the documented ~40-minute first-run window.

1. Confirm the account attempting to approve is a true **Global Administrator** — Security Administrator and Application Administrator cannot approve MGDC app consent, even though they can do almost everything else in the tenant related to apps.
2. Confirm the approving account is **not the same account** that registered the app in the Azure portal — self-approval is blocked outright, and the failure mode is a silent no-op, not an error message.
3. Approve from: M365 admin center → Settings → Org settings → Security & privacy tab → **Microsoft Graph Data Connect applications** → select the app → step through the dataset review wizard → **Approve**.
4. If consent was previously granted and has since **expired**, see Fix 6 (renewal) rather than treating this as a fresh registration problem.

</details>

<details><summary>Fix 5 — Pipeline succeeds but silently excludes some users</summary>

**Symptom:** Row counts are consistently lower than the tenant's total user count, with no error.

Two documented, non-bug exclusions:
- **Hybrid Exchange users** — any user whose mailbox is still on-premises (not yet migrated to Exchange Online) is not supported by MGDC and is silently excluded from the extraction. Confirm via `Get-Mailbox -RecipientTypeDetails RemoteUserMailbox` on-prem or `Get-MgUser` `onPremisesSyncEnabled`/mailbox location checks.
- **Resource accounts** (room/equipment mailboxes) are not supported for `Message` or `Event` datasets.

Neither is fixable from the MGDC side — it's an architectural scope limitation. Set client expectations accordingly rather than troubleshooting further.

</details>

<details><summary>Fix 6 — Renewing an expiring or expired app consent</summary>

**Symptom:** A pipeline that worked for months suddenly requires re-consent, or an admin wants to proactively avoid an outage.

1. M365 admin center → Settings → Org settings → Security & privacy → **Microsoft Graph Data Connect applications**.
2. Select the already-consented application → **Approve** again. This extends the authorization validity without requiring a full new registration.
3. Do this **before** the expiration date — there is no documented emergency fast-path if a production pipeline hits a hard expiry mid-run.

</details>

<details><summary>Fix 7 — Storage account access denied (linked service auth failure)</summary>

**Symptom:** Pipeline fails at "Persisting Data" with an access-denied error against the destination storage account.

**RBAC check:**
```powershell
Get-AzRoleAssignment -ObjectId "<service-principal-object-id>" `
  -Scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage-account>" |
  Where-Object { $_.RoleDefinitionName -eq "Storage Blob Data Contributor" }

# If missing, grant it:
New-AzRoleAssignment -ObjectId "<service-principal-object-id>" `
  -RoleDefinitionName "Storage Blob Data Contributor" `
  -Scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage-account>"
```

**Network check (if the storage account is closed to public access):** MGDC's internal delivery service reaches the storage account from IP ranges scoped to the **Azure region that maps to the tenant's Office region** — not necessarily the region the storage account itself is in. Look up the Office-to-Azure region mapping (see `GraphDataConnect-A.md`'s region table), then allow-list the corresponding Azure Storage service IP ranges from [Azure IP Ranges and Service Tags](https://www.microsoft.com/download/details.aspx?id=56519) on the storage account's firewall. A storage account physically located in the same region the Office region maps to (e.g., West Europe for an EUR tenant) **cannot** be closed to public access and still receive MGDC data — it must be moved to a paired alternate region (e.g., North Europe) before firewall rules will work correctly. Rollback: re-opening the storage account to "Enable public access from all networks" immediately unblocks delivery if a firewall change caused an outage.

</details>

<details><summary>Fix 8 — Multi-geo tenant: pipeline only returns users from one region</summary>

**Symptom:** A multi-geo tenant's pipeline consistently returns users from only one geography, even though the user list scope includes users tenant-wide.

This is by design, not a bug: **one MGDC pipeline can only extract data for one Office region at a time**, determined by the Azure region the pipeline's integration runtime runs in. Set up a separate pipeline per region, each pointed at the Azure region that maps to that Office region (see the region mapping table in `GraphDataConnect-A.md`).

</details>

<details><summary>Fix 9 — Duplicate records / multiple output files per run</summary>

**Symptom:** The `Message` dataset produces multiple copies of the same email, or a single pipeline run produces multiple JSON files in the sink instead of one.

- **Duplicate emails are expected**: a copy of each message exists in every recipient's mailbox, and the dataset is extracted per-mailbox. Deduplicate downstream using the `internetMessageId` field — treat two records with the same `internetMessageId` as the same message. Do this **across all output blobs**, not per-blob, since duplicates can land in different files.
- **Multiple output files per run are also expected**: MGDC parallelizes extraction across jobs based on user-list size, and each parallel job writes its own output file. If a single merged file is required, add a downstream **Copy data** activity in ADF/Synapse with `Wildcard file path` as the source and `Merge files` as the sink behavior.

</details>

---
## Escalation Evidence

```
MICROSOFT GRAPH DATA CONNECT — ESCALATION TEMPLATE
====================================================
Tenant ID (Entra):            <tenant-id>
Azure Subscription ID:        <subscription-id>
App (Client) ID:               <app-id>
App Object ID:                 <app-object-id>
Service Principal Object ID:   <sp-object-id>

Microsoft.GraphServices RegistrationState:  <from Triage step 1>
App owner UserType / license status:        <from Triage step 2>
Storage RBAC (Storage Blob Data Contributor present?): <yes/no>
Storage account network rule (Default action): <Allow/Deny>

MGDC tenant toggle status (M365 admin center):   <on/off — confirmed portal check>
App consent status (M365 admin center):          <Pre-consent / Approved / Expired>
Approving account role verified as Global Admin: <yes/no>

Pipeline name:                 <pipeline-name>
Pipeline engine:                <Fabric / Azure Synapse / Azure Data Factory>
Last run status:               <status>
Last run ID:                    <run-id>
Activity status at failure:     <Initializing / Consent Pending / Extracting Data / Persisting Data>
Error message (verbatim):       <paste>

Dataset(s) requested:           <e.g. BasicDataSet_v0.Message_v1>
Office region (tenant):         <region>
Azure region (pipeline/IR):     <region>
Destination storage account:    <name> (<region>)

Azure support request routing (if opening a ticket):
  Service type:  Microsoft Graph High-Capacity APIs
  Problem type:  Microsoft Graph Data Connect (MGDC)
```

---
## 🎓 Learning Pointers

- **MGDC and Microsoft Graph API are not competing tools for the same job — they solve different problems.** Graph API is for small-scope, real-time access (a handful of users, live data). MGDC is for bulk, at-scale, periodic extraction with a fixed ~45-minute pipeline overhead regardless of data volume. A ticket asking "why is Data Connect so slow for a quick lookup" usually means the wrong tool was chosen, not that something is broken. [MS Docs: When should I use Microsoft Graph API or Data Connect](https://learn.microsoft.com/en-us/graph/overview#when-should-i-use-microsoft-graph-api-or-data-connect)
- **The app-owner eligibility rule (non-guest, mailbox, E5) is the single highest-value fact to check first** on any "registration succeeded but nothing works" ticket — it fails silently rather than with a clear error at registration time.
- **Approval requires a specific Entra role (Global Admin) that doesn't follow the usual "who manages apps" assumption.** Application Administrator and Cloud Application Administrator — roles that normally cover full app lifecycle management — cannot approve MGDC consent. This is worth flagging proactively to clients who delegate app administration away from Global Admin.
- **Billing is per-pipeline-run with fraction-rounding-up, not per-row.** A client running many small pipeline executions instead of fewer, larger ones will be billed more than the row count alone would suggest — worth mentioning during any cost-review conversation.
- **Data doesn't stay "live."** MGDC extracts a point-in-time bulk copy; there's no MGDC-side mechanism for real-time sync. Downstream freshness is entirely a function of how often the client schedules pipeline runs — set that expectation explicitly when a client asks "why isn't yesterday's email in the report."
- For architecture, datasets, and the full region-mapping reference, see `GraphDataConnect-A.md`. For general Graph API scripting and batching, see `GraphAPI-BatchOperations-A.md`/`-B.md` in this same folder.
