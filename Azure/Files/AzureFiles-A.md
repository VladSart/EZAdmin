# Azure Files — Reference Runbook (Mode A: Deep Dive)
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
| Product | Azure Files (SMB and NFS shares), Azure File Sync |
| Applies to | Direct SMB mounts (on-prem or Azure), AVD/FSLogix backend, Azure File Sync-synced servers |
| Tiers | Standard (Transaction Optimized, Hot, Cool) and Premium (provisioned v1/v2, file share IOPS) |
| Auth models | Storage account key, Entra Kerberos (AADKERB), AD DS Kerberos, NFS (Linux, no identity auth) |
| Out of scope | Azure NetApp Files (different service, similar concepts) — see AVD/FSLogix-A.md for ANF notes |

---
## How It Works

<details><summary>Full architecture</summary>

Azure Files exposes fully managed file shares over SMB 2.1/3.x and NFS 4.1, backed by Azure Storage. Unlike Azure Blob (object storage), Azure Files presents a real hierarchical filesystem with directories, NTFS-style ACLs (SMB) or POSIX permissions (NFS).

**Two access patterns:**

1. **Direct mount** — clients mount `\\<storageaccount>.file.core.windows.net\<share>` directly over SMB. Requires network line-of-sight to the storage endpoint (public + firewall allow-list, or Private Endpoint) and works over TCP 445.
2. **Azure File Sync (AFS)** — an on-prem or Azure VM Windows Server runs the Storage Sync Agent, which registers as a "server endpoint" syncing with a "cloud endpoint" (an Azure file share). Clients then hit the *on-prem server* over normal LAN SMB, and the server transparently syncs with the cloud copy and can tier cold files to the cloud (leaving a pointer, "cloud tiering").

```
DIRECT MOUNT MODEL:
Client ──SMB 445──► *.file.core.windows.net ──► Azure Files share
   (needs 445 reachability + identity auth)

AZURE FILE SYNC MODEL:
Client ──SMB 445 (LAN)──► On-prem/Azure VM File Server ──HTTPS 443──► Sync Service ──► Azure Files (cloud endpoint)
                                  │
                                  └─ Cloud tiering: cold files replaced with reparse-point stub;
                                     data pulled on-demand when accessed
```

**Identity-based authentication (three models):**

- **Storage account key** — full access, no per-user identity, key must be distributed/rotated carefully. Default and only option if identity auth isn't configured.
- **Entra Kerberos (AADKERB)** — Entra ID issues Kerberos tickets for cloud-only or hybrid identities without requiring an on-prem AD DS trust. Simplest for cloud-native tenants. NTFS ACLs still reference AD/Entra object SIDs.
- **AD DS authentication** — the storage account gets a computer account object in on-prem AD (via the `AzFilesHybrid` module `Join-AzStorageAccountForAuth`). Domain-joined clients get seamless Kerberos SSO exactly like an on-prem file server. Requires Entra Connect sync of the storage account's computer account password (rotates automatically, default 30 days).

**RBAC layer (separate from NTFS):**
Azure RBAC roles (`Storage File Data SMB Share Reader/Contributor/Elevated Contributor`) gate *authentication* to the share. NTFS ACLs (set via `icacls` while mounted with the storage key) gate *what the identity can do* once connected. Both layers must independently permit access — this trips up almost everyone the first time.

**Tiering (transaction vs capacity optimized):**
Standard file shares choose a tier (Transaction Optimized, Hot, Cool) that trades transaction cost against storage cost. Premium shares are provisioned (you pre-allocate IOPS/throughput capacity, billed regardless of usage) — used for latency-sensitive workloads like FSLogix or databases.

</details>

---
## Dependency Stack

```
Client (Windows/macOS/Linux, on-prem or Azure)
    │
    └─ Network path
         ├─ Public endpoint: Storage firewall allow-list (IP/VNet rules) OR "Allow trusted Azure services"
         └─ Private Endpoint: NIC in client's VNet + Private DNS Zone (privatelink.file.core.windows.net) linked to VNet
              │
              └─ TCP 445 (SMB) or 2049 (NFS) reachable end-to-end
                   │
                   └─ Identity-based auth layer
                        ├─ Storage account key (bypasses identity entirely)
                        ├─ Entra Kerberos (AADKERB) — Entra ID token exchange
                        └─ AD DS Kerberos — on-prem AD, computer account object, Entra Connect sync
                             │
                             └─ Azure RBAC (Storage File Data SMB Share *) — gates authentication
                                  │
                                  └─ NTFS ACLs on share/folders — gates authorization
                                       │
                                       └─ [Optional] Azure File Sync agent
                                            ├─ Server endpoint (on-prem path)
                                            ├─ Cloud endpoint (Azure file share)
                                            └─ Cloud tiering (reparse points for cold files)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Cannot connect at all, port 445 closed | On-prem network blocking outbound SMB | `Test-NetConnection -Port 445`; consider Private Endpoint + VPN or AFS instead |
| Connects with key but not with user identity | Identity-based auth not enabled | `Get-AzStorageAccount ... AzureFilesIdentityBasedAuth` |
| RBAC granted but still Access Denied | NTFS ACLs never set | Mount with key, run `icacls` |
| Intermittent auth failures on AD DS auth | Computer account password out of sync with AD | Check Entra Connect sync status; re-run `Update-AzStorageAccountAuthForAD` |
| Slow performance under load | Wrong tier for workload (Standard vs Premium) or transaction-heavy on Transaction Optimized tier | Check Insights/metrics for IOPS/throttling; consider Premium |
| "Not enough space" errors | Share quota reached | `Get-AzRmStorageShareStats` |
| Files show as small "cloud" icons, slow to open | Azure File Sync cloud tiering — file is a stub, being recalled | Normal behavior; check tiering policy/date threshold if excessive |
| Sync conflicts (`<file>-<servername>.txt` appearing) | Two endpoints modified same file before sync reconciled | Expected AFS conflict resolution — review conflict files |
| DNS resolves to public IP despite Private Endpoint | Private DNS Zone not linked to client VNet | `Get-AzPrivateDnsVirtualNetworkLink` |
| NFS share mount fails | NFS requires Premium tier + no identity auth + VNet-only (no public access) | Confirm share type/tier; NFS cannot use SMB identity models |

---
## Validation Steps

**1 — Confirm storage account and share exist and tier**
```powershell
Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>" | Select-Object Sku, Kind, AccessTier
Get-AzRmStorageShare -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" -Name "<share>" |
    Select-Object Name, ShareQuota, AccessTier, EnabledProtocols
```
Bad: `EnabledProtocols` shows NFS when SMB was expected (or vice versa) — protocol is fixed at share creation, cannot be changed after.

**2 — Confirm network path**
```powershell
Get-AzStorageAccountNetworkRuleSet -ResourceGroupName "<rg>" -Name "<storageaccount>"
# Expected: DefaultAction = Deny with explicit VNet/IP rules, or Allow if intentionally public
Get-AzPrivateEndpointConnection -ResourceGroupName "<rg>" -ServiceName "<storageaccount>" -PrivateLinkServiceType Microsoft.Storage
```

**3 — Confirm identity-based auth**
```powershell
(Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").AzureFilesIdentityBasedAuth
# DirectoryServiceOptions: None | AADKERB | AD
```

**4 — Confirm AD DS computer account health (if using AD DS auth)**
```powershell
# On a domain controller or RSAT machine
Get-ADComputer -Identity "<storageaccount>" -Properties PasswordLastSet
# Compare PasswordLastSet against Azure side:
Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>" |
    Select-Object -ExpandProperty AzureFilesIdentityBasedAuth
```
Bad: password rotation is >30 days out of sync between AD and Azure — indicates a broken sync job (`Update-AzStorageAccountAuthForAD` runs via scheduled task on hybrid environments).

**5 — Confirm RBAC + NTFS alignment**
```powershell
$scope = (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Id + "/fileServices/default/fileshares/<share>"
Get-AzRoleAssignment -Scope $scope

net use Z: "\\<storageaccount>.file.core.windows.net\<share>" /user:"AZURE\<storageaccount>" <key>
icacls Z:\
net use Z: /delete
```

**6 — Check metrics for throttling**
```powershell
Get-AzMetric -ResourceId (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Id `
    -MetricName "Egress","SuccessServerLatency","Throttling" -TimeGrain 00:05:00
```
Bad: sustained throttling events — either scale to Premium or split load across multiple shares/accounts.

**7 — (Azure File Sync only) Confirm sync health**
```powershell
Get-StorageSyncGroup -ParentObject (Get-StorageSyncFarm)
Get-StorageSyncServerEndpoint | Select-Object DisplayName, SyncStatus, LastSyncTimestamp
```

---
## Troubleshooting Steps (by phase)

### Phase 1 — Cannot Reach Share At All
1. Confirm DNS resolution type (public vs private) matches deployment intent.
2. Test TCP 445 (SMB) or 2049 (NFS) from the exact client experiencing the issue — not a jump box.
3. Review storage account firewall rules — `DefaultAction`, VNet rules, IP allow-list, "Allow trusted Microsoft services."
4. If on-prem and no Private Endpoint exists, determine whether Azure File Sync is a better fit than direct SMB (avoids exposing 445 to internet path entirely).

### Phase 2 — Auth Succeeds but Access Denied
1. Distinguish RBAC (authentication gate) from NTFS ACL (authorization gate) — check both independently.
2. If using AD DS auth, verify the computer account object exists in AD and its Kerberos password is in sync with Azure.
3. If using Entra Kerberos, confirm the user's Entra ID object is correctly targeted by the RBAC role assignment (group vs individual user scoping is a common miss).

### Phase 3 — Performance Complaints
1. Check share tier (Transaction Optimized/Hot/Cool vs Premium) against workload IOPS/latency needs.
2. Pull metrics for throttling events — Standard shares have per-share IOPS/throughput ceilings tied to size (or fixed baseline + burst).
3. For FSLogix/AVD-backed shares specifically, cross-reference `Azure/AVD/FSLogix-A.md` — profile container performance has additional considerations.
4. Consider Premium (provisioned v2) if consistent low-latency IOPS are required — Standard tiers are capacity-scaled, not guaranteed IOPS.

### Phase 4 — Azure File Sync Specific Issues
1. Check Server Endpoint sync status and last sync timestamp — a stuck sync often means a large file lock or a corrupted sync database (`ChangeDetectionOperation` stuck).
2. Review cloud tiering policy — files older than the "date policy" threshold or beyond the free space percentage are tiered (replaced with a pointer). This is expected, not a fault.
3. Check for sync conflict files (`<name>-<servername>.ext`) — indicates concurrent edits across endpoints before reconciliation; manual merge required.
4. Validate the Storage Sync Service and registered server certificate hasn't expired (server registration renews automatically but can fail silently after long outages).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrate a share from key-only to Entra Kerberos auth</summary>

```powershell
# 1. Enable Entra Kerberos on the storage account
Update-AzStorageAccount -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" `
    -EnableAzureActiveDirectoryKerberosForFile $true

# 2. Assign RBAC to the target group (not individual users — easier to manage)
$scope = (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Id
New-AzRoleAssignment -ObjectId "<EntraGroupObjectId>" `
    -RoleDefinitionName "Storage File Data SMB Share Contributor" -Scope $scope

# 3. Set NTFS ACLs (mount with key first — one-time setup)
net use Z: "\\<storageaccount>.file.core.windows.net\<share>" /user:"AZURE\<storageaccount>" <key>
icacls Z:\ /grant "<DOMAIN>\<GroupName>:(OI)(CI)(M)"
net use Z: /delete

# 4. Communicate to end users: they now connect using their own Entra credentials,
#    not the shared storage key — remove any cached key-based mappings first (cmdkey /delete).
```

**Rollback:** `Update-AzStorageAccount ... -EnableAzureActiveDirectoryKerberosForFile $false`. Users fall back to key-only; NTFS ACLs referencing Entra SIDs will no longer resolve to anything usable without the key.

</details>

<details><summary>Playbook 2 — Deploy Azure File Sync to replace an aging on-prem file server</summary>

```powershell
# High-level sequence (full script requires Az.StorageSync module):

# 1. Create Storage Sync Service + Sync Group
New-AzStorageSyncService -ResourceGroupName "<rg>" -Name "<syncservicename>" -Location "<region>"
$syncService = Get-AzStorageSyncService -ResourceGroupName "<rg>" -Name "<syncservicename>"
New-AzStorageSyncGroup -ParentObject $syncService -Name "<syncgroupname>"

# 2. Create cloud endpoint pointing at the Azure file share
$syncGroup = Get-AzStorageSyncGroup -ParentObject $syncService -Name "<syncgroupname>"
$storageAccount = Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>"
New-AzRmStorageSyncCloudEndpoint -ParentObject $syncGroup -Name "cloudendpoint1" `
    -StorageAccountResourceId $storageAccount.Id -AzureFileShareName "<share>"

# 3. On the on-prem server: install the Azure File Sync agent (from download center),
#    register the server against the Storage Sync Service (interactive, requires Entra auth), then:
Register-AzStorageSyncServerEndpoint -SyncGroupObject $syncGroup `
    -ServerLocalPath "D:\FileShare" -CloudTiering $true `
    -VolumeFreeSpacePercent 20

# 4. Initial sync (namespace-first, then content) can take hours/days depending on file count.
#    Monitor via: Get-StorageSyncServerEndpoint
```

**Rollback:** Server endpoints can be removed (`Remove-AzStorageSyncServerEndpoint`) without deleting the underlying cloud data — files remain in the Azure file share. Untiering (recalling all tiered files back to local disk) must be done before removing tiering if the server is being decommissioned.

</details>

<details><summary>Playbook 3 — Recover from a stuck/corrupt Azure File Sync server endpoint</summary>

```powershell
# Check sync status first
Get-StorageSyncServerEndpoint | Select-Object DisplayName, SyncStatus, LastSyncTimestamp

# If stuck for an extended period (hours+), a re-registration of the server endpoint is often
# the fastest recovery path. This does NOT delete cloud data.

# 1. Remove the affected server endpoint (files remain locally, cloud copy untouched)
Remove-AzStorageSyncServerEndpoint -ServerEndpointName "<endpoint>" -SyncGroupObject $syncGroup

# 2. Re-create it against the same path — this triggers a fresh sync/reconciliation pass
New-AzStorageSyncServerEndpoint -SyncGroupObject $syncGroup `
    -ServerId "<serverId>" -ServerLocalPath "D:\FileShare" -CloudTiering $true

# 3. Monitor initial reconciliation — this can take significant time for large namespaces
```

**Rollback:** None needed beyond re-registration; no destructive action is taken against the cloud endpoint.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Azure Files Evidence Collector — gathers diagnostic data for escalation
.NOTES     Run from an admin workstation with Az.Storage / Az.StorageSync modules.
#>

param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$StorageAccountName,
    [string]$ShareName
)

$report = [System.Collections.Generic.List[string]]::new()
$report.Add("=== Azure Files Evidence Pack - $(Get-Date -Format 'yyyy-MM-dd HH:mm') ===`n")

try {
    $sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
    $report.Add("Storage Account: $($sa.StorageAccountName) | SKU: $($sa.Sku.Name) | Kind: $($sa.Kind)")
    $report.Add("Identity Auth: $($sa.AzureFilesIdentityBasedAuth | ConvertTo-Json -Compress)")
} catch { $report.Add("ERROR reading storage account: $_") }

try {
    $net = Get-AzStorageAccountNetworkRuleSet -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
    $report.Add("`nNetwork Rules: DefaultAction=$($net.DefaultAction), VNet Rules=$($net.VirtualNetworkRules.Count), IP Rules=$($net.IpRules.Count)")
} catch { $report.Add("ERROR reading network rules: $_") }

if ($ShareName) {
    try {
        $share = Get-AzRmStorageShare -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -Name $ShareName
        $stats = Get-AzRmStorageShareStats -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -Name $ShareName
        $report.Add("`nShare: $ShareName | Quota: $($share.ShareQuota) GiB | Usage: $([math]::Round($stats.ShareUsageBytes/1GB,2)) GiB")
        $report.Add("Protocol: $($share.EnabledProtocols) | Tier: $($share.AccessTier)")
    } catch { $report.Add("ERROR reading share: $_") }
}

try {
    $scope = $sa.Id
    $roles = Get-AzRoleAssignment -Scope $scope | Where-Object { $_.RoleDefinitionName -like "Storage File Data*" }
    $report.Add("`nRBAC Assignments:")
    $roles | ForEach-Object { $report.Add("  $($_.DisplayName) - $($_.RoleDefinitionName)") }
} catch { $report.Add("ERROR reading RBAC: $_") }

$outPath = "$env:TEMP\AzureFiles-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
$report | Out-File $outPath -Encoding UTF8
Write-Host "Evidence saved to: $outPath" -ForegroundColor Green
$outPath
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| Test SMB reachability | `Test-NetConnection -ComputerName <fqdn> -Port 445` |
| Check identity auth model | `(Get-AzStorageAccount -ResourceGroupName <rg> -Name <sa>).AzureFilesIdentityBasedAuth` |
| Enable Entra Kerberos | `Update-AzStorageAccount ... -EnableAzureActiveDirectoryKerberosForFile $true` |
| Check RBAC on share | `Get-AzRoleAssignment -Scope <shareResourceId>` |
| Mount with storage key | `net use Z: \\<sa>.file.core.windows.net\<share> /user:AZURE\<sa> <key>` |
| Check/set NTFS ACLs | `icacls Z:\` / `icacls Z:\ /grant "<id>:(OI)(CI)(M)"` |
| Check quota/usage | `Get-AzRmStorageShare` / `Get-AzRmStorageShareStats` |
| Expand quota | `Update-AzRmStorageShare -QuotaGiB <n>` |
| Check Private Endpoint DNS | `Resolve-DnsName <sa>.file.core.windows.net` |
| Check Private DNS zone link | `Get-AzPrivateDnsVirtualNetworkLink` |
| AFS sync status | `Get-StorageSyncServerEndpoint` |
| AFS force re-registration | `Remove-/New-AzStorageSyncServerEndpoint` |
| Check throttling metrics | `Get-AzMetric -MetricName Throttling` |
| AD DS computer account check | `Get-ADComputer -Identity <sa> -Properties PasswordLastSet` |

---
## 🎓 Learning Pointers

- **RBAC and NTFS are independently enforced.** This is the single most common Azure Files support ticket. A user can have the correct `Storage File Data SMB Share Contributor` role and still get Access Denied because NTFS ACLs on the share were never configured — the two systems don't sync automatically. See [Azure Files identity-based auth overview](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-active-directory-overview).
- **Azure File Sync is not a backup product — it's live sync with tiering.** Cloud-tiered files show as small stub files locally and get recalled on open, which is often mistaken for corruption by end users unfamiliar with the icon overlay. Set expectations before deploying. See [cloud tiering overview](https://learn.microsoft.com/en-us/azure/storage/file-sync/file-sync-cloud-tiering-overview).
- **Standard vs Premium is a capacity-vs-guaranteed-IOPS decision.** Standard file shares scale performance with allocated size (or transaction-based billing); Premium (provisioned v2) reserves dedicated IOPS/throughput independent of size. Latency-sensitive workloads (FSLogix, databases) should default to Premium. See [Azure Files performance tiers](https://learn.microsoft.com/en-us/azure/storage/files/understanding-billing).
- **NFS shares cannot use SMB identity auth models.** NFS 4.1 shares rely on network-level security (VNet/Private Endpoint only, no public access) and Linux-style UID/GID permissions — a completely separate auth model from SMB's Entra Kerberos/AD DS. Don't try to apply SMB auth guidance to an NFS share.
- **The AD DS computer account password rotates automatically — and can silently drift.** In hybrid AD DS auth setups, the storage account's AD computer account password must periodically be refreshed (`Update-AzStorageAccountAuthForAD`), typically via a scheduled task. If that task stops running (service account expired, task deleted), auth degrades gradually rather than failing outright, making it a sneaky root cause for intermittent tickets.
- **Compare against DFS-R before recommending Azure File Sync as a wholesale replacement.** AFS solves multi-site file access well but changes the failure model (cloud dependency, tiering behavior, sync conflict resolution differs from DFS-R's replication model) — see [[project_ezadmin]] for why DFS remains a build priority alongside cloud alternatives.
