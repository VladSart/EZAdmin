# Azure Storage Accounts (Blob/Queue/Table) — Hotfix Runbook (Mode B: Ops)
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

Run these from an admin workstation with the Az module. This covers Blob, Queue, and Table data-plane access — for Azure Files (SMB/NFS) see `Azure/Files/AzureFiles-B.md` instead.

```powershell
# 1. Does the storage account exist and what's its current state?
Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>" |
    Select-Object StorageAccountName, ProvisioningState, StatusOfPrimary, AllowBlobPublicAccess, AllowSharedKeyAccess

# 2. What's the network firewall posture — is the caller's path even allowed in?
Get-AzStorageAccountNetworkRuleSet -ResourceGroupName "<rg>" -Name "<storageaccount>"

# 3. Is the caller using a SAS token, and has it expired?
#    Decode the 'se=' (signed expiry) query param from the SAS URL — compare to current UTC time
[datetime]::Parse("<se-value-from-sas-url>") -lt (Get-Date).ToUniversalTime()

# 4. What RBAC data-plane roles does the caller's identity have on this account?
$scope = (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Id
Get-AzRoleAssignment -Scope $scope | Where-Object { $_.RoleDefinitionName -like "Storage Blob Data*" -or $_.RoleDefinitionName -like "Storage Queue Data*" -or $_.RoleDefinitionName -like "Storage Table Data*" }

# 5. Is soft delete masking what looks like a "missing" blob/container?
Get-AzStorageBlobServiceProperty -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" |
    Select-Object -ExpandProperty DeleteRetentionPolicy
```

**Interpretation:**

| Finding | Action |
|---|---|
| `StatusOfPrimary` not `Available` | Fix 1 — regional outage or account-level issue, check Azure Status first |
| `AllowSharedKeyAccess = $false` and caller uses a key/SAS | Fix 2 — account requires Entra ID (RBAC) auth only |
| Network rule set `DefaultAction = Deny` and caller's IP/VNet not listed | Fix 3 — firewall blocking the caller |
| SAS `se=` timestamp is in the past | Fix 4 — expired SAS token, reissue |
| No `Storage Blob/Queue/Table Data *` role at any scope | Fix 5 — missing RBAC data-plane role (having Owner/Contributor is NOT enough) |
| Soft delete enabled and item "missing" | Fix 6 — undelete within retention window |
| `AllowBlobPublicAccess = $false` and app expects anonymous read | Fix 7 — public access disabled at account level |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Caller (user, app, service principal, or on-prem client)
    │
    ▼
Network path to <account>.blob/queue/table.core.windows.net
    │  ├── Public endpoint + storage firewall allow-list (IP/VNet/"trusted services"), OR
    │  └── Private Endpoint + Private DNS Zone (privatelink.blob/queue/table.core.windows.net)
    │
    ▼
Authorization model presented by the caller
    │  ├── Microsoft Entra ID (RBAC) — Storage Blob/Queue/Table Data * role, OR
    │  ├── Shared Key (account key) — full access, requires AllowSharedKeyAccess = true, OR
    │  └── Shared Access Signature (SAS) — Account SAS or User Delegation SAS, has an expiry
    │
    ▼
Account-level access toggles
    │  ├── AllowBlobPublicAccess (anonymous container/blob access, off by default since 2021)
    │  └── AllowSharedKeyAccess (if false, only Entra ID/RBAC or user-delegation SAS works)
    │
    ▼
Resource-level state
    │  ├── Soft delete retention (blob/container — "missing" items may just be soft-deleted)
    │  ├── Immutability policy / legal hold (WORM — blocks writes/deletes even for Owners)
    │  └── Lifecycle management policy (auto-tiers or auto-deletes aged blobs — can surprise clients)
    │
    ▼
Successful data-plane operation (GET/PUT/DELETE on blob, queue message, or table entity)
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the account is healthy**
```powershell
Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>" | Select-Object StatusOfPrimary, StatusOfSecondary
```
Expected: `Available`. Anything else — check [Azure Status](https://status.azure.com) for a regional incident before troubleshooting further.

**Step 2 — Confirm network path**
```powershell
Get-AzStorageAccountNetworkRuleSet -ResourceGroupName "<rg>" -Name "<storageaccount>"
Resolve-DnsName "<storageaccount>.blob.core.windows.net"
```
If `DefaultAction = Deny`, the caller's IP or VNet subnet must appear in the rule list, OR the request must come from a Private Endpoint. A public IP resolution when a Private Endpoint is expected means the Private DNS Zone isn't linked to the caller's VNet.

**Step 3 — Confirm which auth model the caller is actually using**
```powershell
(Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").AllowSharedKeyAccess
```
If `$false`, account keys and Account SAS tokens signed with a key are rejected outright — only Entra ID (RBAC) tokens or a User Delegation SAS (itself backed by an Entra ID token) will work. This is a common "it worked last week" complaint after a security hardening pass disables shared key access.

**Step 4 — Confirm RBAC data-plane role (if using Entra ID auth)**
```powershell
$scope = (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Id
Get-AzRoleAssignment -Scope $scope -ObjectId "<callerObjectId>"
```
Expected: one of `Storage Blob Data Reader/Contributor/Owner`, `Storage Queue Data *`, or `Storage Table Data *`. **Owner/Contributor on the account (control plane) does NOT grant data-plane access** — this is the single most common gap.

**Step 5 — Confirm the blob/container isn't soft-deleted**
```powershell
Get-AzStorageBlobServiceProperty -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" |
    Select-Object -ExpandProperty DeleteRetentionPolicy
$ctx = (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Context
Get-AzStorageBlob -Container "<container>" -Blob "<blobname>" -Context $ctx -IncludeDeleted
```

**Step 6 — Confirm no immutability policy/legal hold is blocking a write or delete**
```powershell
Get-AzRmStorageContainerImmutabilityPolicy -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" -ContainerName "<container>"
```
If a policy is present and locked, writes/overwrites/deletes to existing blobs within the retention period are blocked for everyone, including the account owner — this is by design (WORM compliance).

---
## Common Fix Paths

<details><summary>Fix 1 — Account/region unavailable</summary>

```powershell
Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>" | Select-Object StatusOfPrimary, StatusOfSecondary, FailoverInProgress

# Check Azure Status for the region first: https://status.azure.com
# If GRS/GZRS and primary is down for an extended outage, customer-initiated failover is possible:
# Invoke-AzStorageAccountFailover -ResourceGroupName "<rg>" -Name "<storageaccount>"
```

**Note:** customer-managed failover is a last resort — it can cause data loss for any writes not yet replicated to the secondary region (RPO is typically minutes, not zero), and DNS propagation takes time. Confirm with the client before invoking.

</details>

<details><summary>Fix 2 — Shared Key access disabled, caller using key/SAS</summary>

```powershell
# Confirm the toggle
(Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").AllowSharedKeyAccess

# Option A (recommended): migrate the caller to Entra ID (RBAC) auth
$scope = (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Id
New-AzRoleAssignment -ObjectId "<callerObjectId>" -RoleDefinitionName "Storage Blob Data Contributor" -Scope $scope

# Option B (if the client insists on SAS): issue a User Delegation SAS instead of an
# account-key-signed SAS — this is backed by an Entra ID token and still works when
# AllowSharedKeyAccess is $false
$ctx = New-AzStorageContext -StorageAccountName "<storageaccount>" -UseConnectedAccount
New-AzStorageContainerSASToken -Context $ctx -Name "<container>" -Permission rwl -ExpiryTime (Get-Date).AddHours(4)
```

**Rollback:** `Update-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>" -AllowSharedKeyAccess $true` re-enables key-based auth. Treat re-enabling as a security regression unless there's a specific legacy-app reason.

</details>

<details><summary>Fix 3 — Firewall/network blocking the caller</summary>

```powershell
# Add the caller's public IP (short-term/troubleshooting)
Add-AzStorageAccountNetworkRule -ResourceGroupName "<rg>" -Name "<storageaccount>" -IPAddressOrRange "<callerPublicIP>"

# Add a VNet/subnet (preferred for persistent access from a known network)
Add-AzStorageAccountNetworkRule -ResourceGroupName "<rg>" -Name "<storageaccount>" -VirtualNetworkResourceId "<subnetResourceId>"

# If a Private Endpoint should be used instead, confirm the Private DNS Zone is linked:
Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName "<rg>" -ZoneName "privatelink.blob.core.windows.net"
```

**Rollback:** `Remove-AzStorageAccountNetworkRule` reverses the specific rule added.

</details>

<details><summary>Fix 4 — Expired SAS token</summary>

```powershell
# Reissue a SAS with a sensible expiry. Prefer User Delegation SAS (Entra-backed, no
# long-lived secret embedded) over Account SAS/Service SAS where the client supports it.
$ctx = New-AzStorageContext -StorageAccountName "<storageaccount>" -UseConnectedAccount
New-AzStorageBlobSASToken -Context $ctx -Container "<container>" -Blob "<blobname>" `
    -Permission "r" -ExpiryTime (Get-Date).AddHours(1)
```

**Note:** if SAS tokens keep expiring mid-operation for large transfers, extend the expiry window rather than shortening retry logic — large blob uploads/downloads over slow links can outlast a short-lived SAS.

</details>

<details><summary>Fix 5 — Missing RBAC data-plane role</summary>

```powershell
# Confirm current state
$scope = (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Id
Get-AzRoleAssignment -Scope $scope -ObjectId "<callerObjectId>"

# Grant the minimum role needed (Reader for read-only, Contributor for read/write, avoid Owner)
New-AzRoleAssignment -ObjectId "<callerObjectId>" -RoleDefinitionName "Storage Blob Data Contributor" -Scope $scope
# Queue/Table equivalents:
# New-AzRoleAssignment -ObjectId "<callerObjectId>" -RoleDefinitionName "Storage Queue Data Contributor" -Scope $scope
# New-AzRoleAssignment -ObjectId "<callerObjectId>" -RoleDefinitionName "Storage Table Data Contributor" -Scope $scope
```

**Note:** RBAC role assignments can take up to a few minutes to propagate — don't immediately assume the fix failed if access is still denied 30 seconds after assignment.

</details>

<details><summary>Fix 6 — Soft-deleted blob/container recovery</summary>

```powershell
$ctx = (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Context

# Undelete a soft-deleted blob (must be within the retention window)
Get-AzStorageBlob -Container "<container>" -Blob "<blobname>" -Context $ctx -IncludeDeleted |
    Where-Object { $_.IsDeleted } | ForEach-Object { $_.BlobClient.Undelete() }

# Undelete a soft-deleted container
Get-AzStorageContainer -Context $ctx -IncludeDeleted | Where-Object { $_.Name -eq "<container>" -and $_.IsDeleted } |
    ForEach-Object { Restore-AzStorageContainer -Context $ctx -Name $_.Name }
```

**Rollback:** none needed — this operation only restores data, it does not delete anything.

</details>

<details><summary>Fix 7 — Anonymous public access disabled at account level</summary>

```powershell
# Check current state
(Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").AllowBlobPublicAccess

# Enable at the account level first (prerequisite — container-level setting is ignored if this is $false)
Update-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>" -AllowBlobPublicAccess $true

# Then set the specific container's public access level
$ctx = (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Context
Set-AzStorageContainerAcl -Container "<container>" -Permission Blob -Context $ctx
```

**Rollback:** `Update-AzStorageAccount ... -AllowBlobPublicAccess $false` — re-disabling at the account level immediately blocks anonymous access regardless of container-level settings, which is the safer default for most clients.

</details>

---
## Escalation Evidence

```
=== Azure Storage Account Escalation Pack ===
Date/Time:              _______________
Storage Account:        _______________
Resource Group:         _______________
Service (Blob/Queue/Table): _______________
Caller identity:        _______________ (user/SP/managed identity)

StatusOfPrimary:        _______________
AllowSharedKeyAccess:    YES / NO
AllowBlobPublicAccess:   YES / NO
Network DefaultAction:   Allow / Deny
Caller's path allowed:   YES / NO

Auth method used:       Shared Key / Account SAS / User Delegation SAS / Entra ID (RBAC)
RBAC data-plane role present: YES / NO (role: _______________)
SAS expiry (if applicable):    _______________

Soft delete enabled:    YES / NO
Item soft-deleted:      YES / NO
Immutability policy present: YES / NO (locked: YES / NO)

Symptoms:
[ ] 403 Forbidden   [ ] 404 Not Found (possibly soft-deleted)   [ ] Auth failure   [ ] Timeout/unreachable   [ ] Write blocked (immutability)

Actions taken so far:
1.
2.
3.

Escalation contact: Microsoft Support via Azure Portal > New Support Request (Storage Account blade)
Reference: https://learn.microsoft.com/en-us/azure/storage/common/storage-introduction
```

---
## 🎓 Learning Pointers

- **Control-plane RBAC (Owner/Contributor) does not grant data-plane access.** A user can be Owner of the entire subscription and still get 403s reading a blob — `Storage Blob/Queue/Table Data *` roles are separate, data-plane-specific role assignments. This is the single most common "but I have full access" ticket.
- **`AllowSharedKeyAccess = $false` silently breaks every key- and Account-SAS-based integration.** Security hardening passes often flip this without inventorying which legacy scripts/apps still use connection strings with embedded keys — always check this toggle before assuming a firewall or RBAC issue when "it worked yesterday."
- **Soft delete makes "the blob is gone" almost never actually true within the retention window** — check `-IncludeDeleted` before escalating a "data loss" ticket as a real incident.
- **Immutability policies block deletes and overwrites for everyone, including the account Owner, once locked.** This is intentional WORM/compliance behavior, not a bug — confirm the policy and its expiry before spending time troubleshooting a "can't delete" ticket.
- Related: [Authorize access to data in Azure Storage](https://learn.microsoft.com/en-us/azure/storage/common/authorize-data-access), [Prevent Shared Key authorization](https://learn.microsoft.com/en-us/azure/storage/common/shared-key-authorization-prevent), [Soft delete for blobs](https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-overview), [Immutable storage for blobs](https://learn.microsoft.com/en-us/azure/storage/blobs/immutable-storage-overview), [Configure Azure Storage firewalls and virtual networks](https://learn.microsoft.com/en-us/azure/storage/common/storage-network-security)
