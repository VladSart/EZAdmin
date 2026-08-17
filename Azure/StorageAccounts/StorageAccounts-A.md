# Azure Storage Accounts (Blob/Queue/Table) — Reference Runbook (Mode A: Deep Dive)
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

| Item | Detail |
|------|--------|
| Product | Azure Storage Accounts — Blob, Queue, and Table services (general-purpose v2) |
| Applies to | App/service data access, backups/exports landing in Blob, SAS-based integrations, static website hosting, lifecycle-managed archival data |
| Redundancy options | LRS, ZRS, GRS, GZRS, RA-GRS, RA-GZRS |
| Access tiers (Blob) | Hot, Cool, Cold, Archive (rehydration required before read) |
| Out of scope | Azure Files (SMB/NFS) — see `Azure/Files/AzureFiles-A.md`; Azure Backup's use of storage as a backend — see `Azure/Backup/AzureBackup-A.md`; Azure NetApp Files (separate service) |

---
## How It Works

<details><summary>Full architecture</summary>

A general-purpose v2 storage account is a management/billing envelope over up to five distinct data services: Blob, Queue, Table, Files, and (legacy) managed disks page blobs. This topic covers Blob, Queue, and Table — the three services with fully overlapping authorization and networking models. Azure Files has its own dedicated topic because SMB/NFS introduces an entirely different protocol and identity layer.

**Three independent gates every request must pass, in order:**

```
1. NETWORK   — can the request even reach the service endpoint?
2. AUTHN     — does the request prove a valid identity (key, SAS, or Entra ID token)?
3. AUTHZ     — does that identity have a data-plane role/permission for this operation?
```

All three are evaluated independently. A request can pass network and fail authn (wrong/expired SAS), or pass network+authn and fail authz (valid Entra ID token, but no `Storage Blob Data *` role) — the error surface (403 vs 404 vs timeout) differs by which gate failed, which is why the Symptom → Cause Map below is ordered by gate.

**Authorization models (four, not mutually exclusive at the account level):**

1. **Shared Key** — the account's two rotating access keys. Grants full account-level access, no per-identity audit trail beyond "someone with the key." Disabled entirely when `AllowSharedKeyAccess = $false`.
2. **Shared Access Signature (SAS)** — a time-boxed, scope-limited token. Two flavors:
   - **Account/Service SAS** — signed with an account key. Still blocked if `AllowSharedKeyAccess = $false`, since it derives its trust from the key.
   - **User Delegation SAS** — signed with an Entra ID token instead of an account key. Works even when Shared Key access is disabled; the effective permissions are the intersection of the SAS parameters and the signing identity's own RBAC role.
3. **Microsoft Entra ID (RBAC)** — the modern, recommended model. The caller authenticates with Entra ID and presents a token; Azure evaluates `Storage Blob/Queue/Table Data *` role assignments scoped to the account, a container, or (for Blob, via ABAC conditions) even individual blobs/paths.
4. **Anonymous (public) read access** — requires BOTH `AllowBlobPublicAccess = $true` at the account level AND a container-level public access setting (`Blob` or `Container`). Either gate alone is insufficient — the account-level toggle is a prerequisite that overrides the container setting when `$false`.

**Data-plane RBAC vs control-plane RBAC — the most consequential distinction in this topic:**
Azure RBAC roles like Owner, Contributor, and Reader operate at the *control plane* (create/delete/configure the storage account resource itself). They grant **zero** implicit access to the *data plane* (read/write a blob, dequeue a message, query a table entity). Data-plane access requires an explicit `Storage Blob Data Reader/Contributor/Owner`, `Storage Queue Data *`, or `Storage Table Data *` role assignment. This split is intentional (least-privilege by design) and is the single most common source of "I have full access but get 403" tickets.

**Soft delete, versioning, and immutability — three independent, stackable protections:**

- **Soft delete** (blob and/or container level) — deleted items are retained for a configurable period (default 7 days, up to 365) and recoverable via undelete. Does not prevent deletion; it delays the effect.
- **Blob versioning** — every overwrite creates a new immutable version rather than replacing data in place. Combines with soft delete for point-in-time recovery.
- **Immutability policies (WORM)** — time-based retention or legal hold at the container or version level. Once **locked**, blocks deletion/modification for *everyone including the account Owner* until the retention period expires. This is compliance-grade protection, distinct from and stricter than soft delete.

**Lifecycle management policies** — rule-based engine that automatically tiers (Hot→Cool→Cold→Archive) or deletes blobs based on age-since-modification/access. Runs on a roughly daily cadence, not instantly — a blob matching a "move to Archive after 30 days" rule may take up to 24-48 hours after crossing the threshold to actually transition.

</details>

---
## Dependency Stack

```
Caller (user, app, managed identity, service principal, on-prem client)
    │
    └─ Network path
         ├─ Public endpoint: Storage firewall (DefaultAction Allow/Deny + IP/VNet rules + "trusted Azure services")
         └─ Private Endpoint: NIC in caller's VNet + Private DNS Zone (privatelink.blob/queue/table.core.windows.net)
              │
              └─ Authentication (AuthN)
                   ├─ Shared Key (blocked entirely if AllowSharedKeyAccess = false)
                   ├─ SAS — Account/Service SAS (key-derived) or User Delegation SAS (Entra-derived)
                   ├─ Microsoft Entra ID token
                   └─ Anonymous (requires AllowBlobPublicAccess=true AND container public-access setting)
                        │
                        └─ Authorization (AuthZ) — data plane, independent of control-plane RBAC
                             ├─ Storage Blob Data Reader/Contributor/Owner (+ optional ABAC conditions)
                             ├─ Storage Queue Data Reader/Contributor/Message Processor/Sender
                             └─ Storage Table Data Reader/Contributor
                                  │
                                  └─ Resource-state gates (evaluated per-operation)
                                       ├─ Soft delete retention (deleted ≠ gone within window)
                                       ├─ Blob versioning (overwrite creates new version, doesn't replace)
                                       ├─ Immutability policy / legal hold (blocks writes/deletes if locked)
                                       └─ Lifecycle management policy (auto-tier/auto-delete, ~daily cadence)
                                            │
                                            └─ Successful Blob/Queue/Table operation
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| 403 Forbidden, caller has Owner/Contributor | Missing data-plane RBAC role | `Get-AzRoleAssignment -Scope <accountId>` — look for `Storage * Data *` roles specifically |
| Auth suddenly stopped working after a security review | `AllowSharedKeyAccess` flipped to `$false` | `(Get-AzStorageAccount ...).AllowSharedKeyAccess` |
| SAS URL returns `AuthenticationFailed` | SAS expired (`se=` param) or signed with a now-revoked key | Decode `se=` timestamp; check if `Set-AzStorageAccountKey` rotated the signing key since issuance |
| Request times out / connection refused | Firewall `DefaultAction = Deny` and caller not in allow-list | `Get-AzStorageAccountNetworkRuleSet` |
| DNS resolves to a public IP when a Private Endpoint is expected | Private DNS Zone not linked to caller's VNet | `Get-AzPrivateDnsVirtualNetworkLink -ZoneName privatelink.blob.core.windows.net` |
| Blob/container "missing" but client swears it existed | Soft-deleted within retention window | `Get-AzStorageBlob -IncludeDeleted` |
| Can't delete or overwrite a blob, error mentions immutability | Locked immutability policy or active legal hold | `Get-AzRmStorageContainerImmutabilityPolicy` |
| Public/anonymous read stopped working after account creation | `AllowBlobPublicAccess` defaults to `$false` since ~2021; container setting alone is not enough | `(Get-AzStorageAccount ...).AllowBlobPublicAccess` |
| Archive-tier blob read fails immediately | Archive blobs require rehydration (hours) before they're readable — not an error, expected latency | `Get-AzStorageBlob` → check `AccessTier` and rehydration status |
| Data unexpectedly moved to Cool/Archive tier | Lifecycle management policy matched on age | `Get-AzStorageAccountManagementPolicy` |
| Throttling / `ServerBusy` under load | Account-level scalability target exceeded (requests/sec, ingress/egress) | Check Insights metrics for `Throttling` |

---
## Validation Steps

**1 — Confirm account health and key toggles**
```powershell
Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>" |
    Select-Object StatusOfPrimary, Sku, Kind, AllowSharedKeyAccess, AllowBlobPublicAccess, MinimumTlsVersion
```
Bad: `MinimumTlsVersion` below `TLS1_2` on an account created after the 2021 default change usually indicates a legacy account that should be reviewed for hardening.

**2 — Confirm network posture**
```powershell
Get-AzStorageAccountNetworkRuleSet -ResourceGroupName "<rg>" -Name "<storageaccount>"
Get-AzPrivateEndpointConnection -ResourceGroupName "<rg>" -ServiceName "<storageaccount>" -PrivateLinkServiceType Microsoft.Storage -ErrorAction SilentlyContinue
```

**3 — Confirm data-plane RBAC for the caller**
```powershell
$scope = (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Id
Get-AzRoleAssignment -Scope $scope -ObjectId "<callerObjectId>" |
    Where-Object { $_.RoleDefinitionName -match "Storage (Blob|Queue|Table) Data" }
```
Bad: only control-plane roles (Owner/Contributor/Reader) present, no `Storage * Data *` role.

**4 — Confirm soft delete/versioning/immutability configuration**
```powershell
Get-AzStorageBlobServiceProperty -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" |
    Select-Object -ExpandProperty DeleteRetentionPolicy
Get-AzStorageBlobServiceProperty -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" |
    Select-Object -ExpandProperty IsVersioningEnabled
Get-AzRmStorageContainerImmutabilityPolicy -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" -ContainerName "<container>" -ErrorAction SilentlyContinue
```

**5 — Confirm lifecycle management policy (if data is moving/vanishing unexpectedly)**
```powershell
Get-AzStorageAccountManagementPolicy -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" | ConvertTo-Json -Depth 10
```

**6 — Check for throttling under load**
```powershell
Get-AzMetric -ResourceId (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Id `
    -MetricName "Transactions","Egress","SuccessE2ELatency" -TimeGrain 00:05:00
```

---
## Troubleshooting Steps (by phase)

### Phase 1 — Cannot Reach the Service At All
1. Confirm DNS resolution type (public vs private) matches the deployment's intent.
2. Test the relevant endpoint (`<account>.blob/queue/table.core.windows.net`) reachability over HTTPS 443.
3. Review the storage account firewall — `DefaultAction`, IP rules, VNet rules, "Allow trusted Microsoft services" (needed for services like Azure Backup, Azure Monitor to reach the account even with a locked-down firewall).
4. If a Private Endpoint is deployed, confirm the Private DNS Zone is linked to every VNet that needs to resolve it — a common miss in hub-and-spoke topologies where only the hub VNet gets linked.

### Phase 2 — Reaches the Service but Auth Fails
1. Identify which auth model the caller is actually using (key, SAS, Entra ID) — don't assume.
2. If `AllowSharedKeyAccess = $false`, confirm the caller isn't still using a key-signed SAS or connection string — this is the most common regression after a hardening pass.
3. For SAS-based access, decode the `se=` (expiry) and `sig=` parameters conceptually — an expired or key-rotated SAS produces the same `AuthenticationFailed` error, so confirm the key wasn't rotated after the SAS was issued.
4. For Entra ID auth, confirm token acquisition succeeded (this is an Entra ID/app registration problem, not a storage problem) before troubleshooting further on the storage side.

### Phase 3 — Auth Succeeds but Authorization Fails (403)
1. Check for data-plane RBAC roles specifically — control-plane Owner/Contributor is a near-guaranteed red herring here.
2. If using ABAC conditions (attribute-based access control on Blob RBAC roles), confirm the condition's path/tag match actually covers the target blob — a too-narrow condition produces a 403 that looks identical to a missing role.
3. Check for a locked immutability policy or legal hold if the failing operation is a write/delete, not a read.

### Phase 4 — Data Appears Missing or in an Unexpected State
1. Check soft delete retention before treating this as data loss — `Get-AzStorageBlob -IncludeDeleted`.
2. Check blob versioning — the "current" version may have been overwritten, with prior versions still recoverable.
3. Check the lifecycle management policy — data may have been auto-tiered (Archive requires rehydration before read, which can look like "missing" to an impatient app) or auto-deleted per an aging rule the client forgot they configured.
4. For Archive-tier blobs, confirm rehydration was actually kicked off (`Set-AzStorageBlobContent` re-upload or `Start-AzStorageBlobCopy` with a different tier) — rehydration takes hours (Standard priority) or ~1 hour (High priority, extra cost), it is not instantaneous.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrate an integration from Shared Key/Account SAS to Entra ID (RBAC) or User Delegation SAS</summary>

```powershell
# 1. Disable Shared Key access (do this LAST, after confirming all consumers are migrated)
# Update-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>" -AllowSharedKeyAccess $false

# 2. Grant the app/service's managed identity or service principal a data-plane role
$scope = (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Id
New-AzRoleAssignment -ObjectId "<managedIdentityObjectId>" -RoleDefinitionName "Storage Blob Data Contributor" -Scope $scope

# 3. For scripts/tools that still need a SAS (e.g. handing a link to an external party),
#    issue a User Delegation SAS instead of an account-key-signed one:
$ctx = New-AzStorageContext -StorageAccountName "<storageaccount>" -UseConnectedAccount
New-AzStorageBlobSASToken -Context $ctx -Container "<container>" -Blob "<blobname>" -Permission "r" -ExpiryTime (Get-Date).AddHours(4)

# 4. Only after confirming zero remaining key-based consumers (check diagnostic logs for
#    Shared Key auth events), disable Shared Key access account-wide.
```

**Rollback:** re-enable `AllowSharedKeyAccess = $true` if a consumer was missed. Treat every rollback as a signal to re-audit before re-attempting the disable.

</details>

<details><summary>Playbook 2 — Recover from an accidental bulk delete (soft delete + versioning)</summary>

```powershell
$ctx = (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Context

# Undelete all soft-deleted blobs in a container within the retention window
Get-AzStorageBlob -Container "<container>" -Context $ctx -IncludeDeleted |
    Where-Object { $_.IsDeleted } |
    ForEach-Object {
        Write-Host "Restoring: $($_.Name)"
        $_.BlobClient.Undelete()
    }

# If versioning is enabled and the "current" version was overwritten (not deleted),
# promote a prior version instead:
Get-AzStorageBlob -Container "<container>" -Blob "<blobname>" -Context $ctx -IncludeVersion |
    Sort-Object -Property @{Expression = {$_.BlobProperties.LastModified}} -Descending
# Then copy the desired version back over the current one.
```

**Rollback:** none needed — this is itself the recovery action. If soft delete was disabled at the time of the original deletion, data is not recoverable this way; escalate to Microsoft Support only if geo-redundancy and a very recent deletion make a best-effort case (not guaranteed).

</details>

<details><summary>Playbook 3 — Onboard a client's existing storage estate to standardized governance</summary>

```powershell
# 1. Inventory current posture across all accounts in the subscription
Get-AzStorageAccount | Select-Object StorageAccountName, ResourceGroupName, AllowSharedKeyAccess, AllowBlobPublicAccess, MinimumTlsVersion

# 2. Enable soft delete + versioning as a baseline on every account (idempotent)
foreach ($sa in (Get-AzStorageAccount)) {
    Enable-AzStorageBlobDeleteRetentionPolicy -ResourceGroupName $sa.ResourceGroupName -StorageAccountName $sa.StorageAccountName -RetentionDays 14
    Update-AzStorageBlobServiceProperty -ResourceGroupName $sa.ResourceGroupName -StorageAccountName $sa.StorageAccountName -IsVersioningEnabled $true
}

# 3. Standardize minimum TLS and disable public blob access unless explicitly required
foreach ($sa in (Get-AzStorageAccount)) {
    Update-AzStorageAccount -ResourceGroupName $sa.ResourceGroupName -Name $sa.StorageAccountName `
        -MinimumTlsVersion TLS1_2 -AllowBlobPublicAccess $false
}

# 4. Only after confirming no legacy app depends on it, plan the AllowSharedKeyAccess=false
#    rollout account-by-account (see Playbook 1) rather than tenant-wide in one pass.
```

**Rollback:** each `Update-AzStorageAccount`/`Enable-` call can be reversed individually; there is no bulk undo, so stage this rollout account group by account group for a large estate.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Azure Storage Account Evidence Collector — gathers diagnostic data for escalation
.NOTES     Run from an admin workstation with Az.Storage / Az.Resources modules.
#>

param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$StorageAccountName,
    [string]$ContainerName
)

$report = [System.Collections.Generic.List[string]]::new()
$report.Add("=== Azure Storage Account Evidence Pack - $(Get-Date -Format 'yyyy-MM-dd HH:mm') ===`n")

try {
    $sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
    $report.Add("Account: $($sa.StorageAccountName) | SKU: $($sa.Sku.Name) | Status: $($sa.StatusOfPrimary)")
    $report.Add("AllowSharedKeyAccess: $($sa.AllowSharedKeyAccess) | AllowBlobPublicAccess: $($sa.AllowBlobPublicAccess) | MinTLS: $($sa.MinimumTlsVersion)")
} catch { $report.Add("ERROR reading storage account: $_") }

try {
    $net = Get-AzStorageAccountNetworkRuleSet -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
    $report.Add("`nNetwork: DefaultAction=$($net.DefaultAction), VNet Rules=$($net.VirtualNetworkRules.Count), IP Rules=$($net.IpRules.Count)")
} catch { $report.Add("ERROR reading network rules: $_") }

try {
    $scope = $sa.Id
    $roles = Get-AzRoleAssignment -Scope $scope | Where-Object { $_.RoleDefinitionName -match "Storage (Blob|Queue|Table) Data" }
    $report.Add("`nData-Plane RBAC Assignments:")
    if ($roles) { $roles | ForEach-Object { $report.Add("  $($_.DisplayName) - $($_.RoleDefinitionName)") } }
    else { $report.Add("  NONE FOUND — likely root cause of 403s despite control-plane access") }
} catch { $report.Add("ERROR reading RBAC: $_") }

try {
    $del = Get-AzStorageBlobServiceProperty -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName
    $report.Add("`nSoft Delete: Enabled=$($del.DeleteRetentionPolicy.Enabled), Days=$($del.DeleteRetentionPolicy.Days) | Versioning: $($del.IsVersioningEnabled)")
} catch { $report.Add("ERROR reading blob service properties: $_") }

if ($ContainerName) {
    try {
        $imm = Get-AzRmStorageContainerImmutabilityPolicy -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -ContainerName $ContainerName -ErrorAction SilentlyContinue
        $report.Add("`nImmutability Policy on '$ContainerName': $(if ($imm) { 'PRESENT - ' + ($imm | ConvertTo-Json -Compress) } else { 'None' })")
    } catch { $report.Add("ERROR reading immutability policy: $_") }
}

try {
    $policy = Get-AzStorageAccountManagementPolicy -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -ErrorAction SilentlyContinue
    $report.Add("`nLifecycle Management Policy: $(if ($policy) { 'PRESENT - ' + $policy.Rule.Count.ToString() + ' rule(s)' } else { 'None configured' })")
} catch { $report.Add("ERROR reading lifecycle policy: $_") }

$outPath = "$env:TEMP\StorageAccount-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
$report | Out-File $outPath -Encoding UTF8
Write-Host "Evidence saved to: $outPath" -ForegroundColor Green
$outPath
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check account status/toggles | `Get-AzStorageAccount \| Select StatusOfPrimary,AllowSharedKeyAccess,AllowBlobPublicAccess` |
| Check network firewall | `Get-AzStorageAccountNetworkRuleSet` |
| Check data-plane RBAC | `Get-AzRoleAssignment -Scope <accountId> \| ? RoleDefinitionName -match "Data"` |
| Grant data-plane role | `New-AzRoleAssignment -RoleDefinitionName "Storage Blob Data Contributor" -Scope <id>` |
| Issue User Delegation SAS | `New-AzStorageBlobSASToken -Context $ctx -Container <c> -Blob <b> -Permission r -ExpiryTime <dt>` |
| Check soft delete config | `Get-AzStorageBlobServiceProperty \| Select DeleteRetentionPolicy` |
| List/undelete soft-deleted blobs | `Get-AzStorageBlob -IncludeDeleted \| ? IsDeleted` / `.BlobClient.Undelete()` |
| Check immutability policy | `Get-AzRmStorageContainerImmutabilityPolicy` |
| Check lifecycle policy | `Get-AzStorageAccountManagementPolicy` |
| Check Private DNS Zone link | `Get-AzPrivateDnsVirtualNetworkLink -ZoneName privatelink.blob.core.windows.net` |
| Check throttling metrics | `Get-AzMetric -MetricName Transactions,Egress,SuccessE2ELatency` |
| Customer-managed failover (GRS/GZRS) | `Invoke-AzStorageAccountFailover` |

---
## 🎓 Learning Pointers

- **The network → authn → authz ordering explains the error you see.** A network-layer failure looks like a timeout; an authn failure looks like `AuthenticationFailed`; an authz failure looks like a clean `403 Forbidden` with a valid-looking request. Reading the exact error type tells you which of the three gates to start at, instead of guessing. See [Authorize access to data in Azure Storage](https://learn.microsoft.com/en-us/azure/storage/common/authorize-data-access).
- **Data-plane RBAC is deliberately decoupled from control-plane RBAC — this is the recurring root cause across nearly every 403 ticket.** Design reviews and onboarding checklists should explicitly call out that granting Contributor on a storage account does not grant blob/queue/table access; a separate `Storage * Data *` role assignment is always required. See [Azure built-in roles for Storage](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/storage).
- **Immutability policies protect against the account Owner too, once locked — that's the point, not a bug.** WORM compliance requirements (SEC 17a-4, financial/legal retention) specifically require that nobody, including admins, can delete data early. Set client expectations before locking a policy — it cannot be shortened or removed early once locked, only allowed to expire.
- **Archive tier trades cost for latency, not just cost for less storage.** A blob in Archive tier cannot be read at all until rehydrated (hours, or ~1 hour at High priority for extra cost) — this catches teams who tier data to Archive assuming it behaves like Cool with slightly slower reads.
- **`AllowBlobPublicAccess` at the account level is a hard override, not a default.** Since the ~2021 platform default change, new accounts are created with this `$false`; a container's own "Blob" or "Container" public access level has zero effect until the account-level toggle is also `$true`. This trips up teams following older tutorials/screenshots.
- Related: [Azure Storage security guide](https://learn.microsoft.com/en-us/azure/storage/blobs/security-recommendations), [Soft delete for blobs](https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-overview), [Immutable storage for blobs](https://learn.microsoft.com/en-us/azure/storage/blobs/immutable-storage-overview), [Blob storage lifecycle management](https://learn.microsoft.com/en-us/azure/storage/blobs/lifecycle-management-overview), [Azure Storage redundancy](https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy)
