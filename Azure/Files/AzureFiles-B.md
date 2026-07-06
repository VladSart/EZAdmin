# Azure Files — Hotfix Runbook (Mode B: Ops)
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

Run these from an admin workstation (Az module) or on the affected client where noted.

```powershell
# 1. Can the client resolve and reach the storage account over SMB (445)?
Test-NetConnection -ComputerName "<storageaccount>.file.core.windows.net" -Port 445

# 2. Is the share mounted / reachable via UNC?
Test-Path "\\<storageaccount>.file.core.windows.net\<share>"

# 3. What identity-based auth method is configured on the storage account?
Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>" |
    Select-Object -ExpandProperty AzureFilesIdentityBasedAuth

# 4. Check current share quota vs usage
Get-AzRmStorageShare -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" -Name "<share>" |
    Select-Object Name, QuotaGiB

# 5. Client-side: are there stale/cached credentials for the share?
cmdkey /list | Select-String "<storageaccount>"
```

**Interpretation:**

| Finding | Action |
|---|---|
| Port 445 test fails | Fix 1 — network/firewall blocking SMB |
| `Test-Path` false but port 445 OK | Fix 2 — auth or DNS/private endpoint mismatch |
| `AzureFilesIdentityBasedAuth` shows `None` | Fix 3 — identity-based auth not configured |
| Quota usage near 100% | Fix 4 — expand quota or clean up data |
| Stale `cmdkey` entry present | Fix 5 — clear cached credential, remap |
| Everything above OK but access denied | Fix 6 — NTFS/share-level permission mismatch |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Client device (Windows/macOS/Linux, on-prem or Azure VM)
    │
    ▼
Network path to *.file.core.windows.net
    │  ├── Public endpoint + storage firewall allow-list, OR
    │  └── Private Endpoint + Private DNS Zone (privatelink.file.core.windows.net)
    │
    ▼
TCP 445 reachable (on-prem often blocks outbound 445 — needs VPN/ExpressRoute or Private Endpoint)
    │
    ▼
Identity-based auth configured on storage account
    │  ├── Entra Kerberos (cloud-only identities), OR
    │  ├── AD DS (hybrid, domain-joined), OR
    │  └── Local storage account key (fallback, not identity-based)
    │
    ▼
Azure RBAC role assigned (Storage File Data SMB Share Contributor/Reader/Elevated Contributor)
    │
    ▼
Share-level NTFS ACLs correct (icacls on the share root + subfolders)
    │
    ▼
Client mounts / accesses share successfully
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm network reachability**
```powershell
Test-NetConnection -ComputerName "<storageaccount>.file.core.windows.net" -Port 445
```
Expected: `TcpTestSucceeded : True`. If `False`, most on-prem networks block outbound 445 to the internet by default — this is expected unless a Private Endpoint + VPN/ExpressRoute path exists.

**Step 2 — Confirm DNS resolves to the expected address type**
```powershell
Resolve-DnsName "<storageaccount>.file.core.windows.net"
```
Public endpoint expected: a `*.file.core.windows.net` CNAME chain to a public Azure IP.
Private Endpoint expected: resolves to a `10.x.x.x` / private VNet IP. If it resolves public when you expected private, the Private DNS Zone is not linked to the client's VNet.

**Step 3 — Confirm identity-based auth method**
```powershell
Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>" |
    Select-Object -ExpandProperty AzureFilesIdentityBasedAuth
```
Expected: `DirectoryServiceOptions` = `AADKERB` (Entra Kerberos) or `AD` (AD DS). If `None`, only the storage account key works — no per-user identity, no NTFS-level user permissions.

**Step 4 — Confirm RBAC assignment on the share**
```powershell
$scope = (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Id
Get-AzRoleAssignment -Scope $scope | Where-Object { $_.RoleDefinitionName -like "Storage File Data*" }
```
Expected: the user/group has `Storage File Data SMB Share Contributor` (or Reader/Elevated Contributor as appropriate).

**Step 5 — Confirm share-level NTFS permissions**
```powershell
net use Z: "\\<storageaccount>.file.core.windows.net\<share>" /user:"AZURE\<storageaccount>" <storagekey>
icacls Z:\
net use Z: /delete
```
Expected: the user/group appears with the intended rights (e.g. `(OI)(CI)(M)` for Modify).

**Step 6 — Confirm quota headroom**
```powershell
Get-AzRmStorageShare -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" -Name "<share>" |
    Select-Object Name, QuotaGiB, @{N='ShareUsageBytes';E={(Get-AzRmStorageShareStats -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" -Name $_.Name).ShareUsageBytes}}
```
If usage is within a few GB of quota, writes will start failing with "disk full" style errors on the client.

---
## Common Fix Paths

<details><summary>Fix 1 — SMB port 445 blocked</summary>

```powershell
# Confirm which layer is blocking
Test-NetConnection -ComputerName "<storageaccount>.file.core.windows.net" -Port 445

# If on-prem client and no Private Endpoint/VPN path exists, 445 outbound to internet
# is blocked by most ISPs and corporate firewalls by design. Options:
#   1. Deploy a Private Endpoint for the storage account + VPN/ExpressRoute from on-prem
#   2. Use Azure File Sync (agent talks over HTTPS 443, not SMB directly) instead of
#      direct SMB mount from on-prem clients
#   3. As a last resort, some ISPs support 445 unblock requests (rare, not recommended)

# Confirm NSG isn't blocking egress on 445 if the client is an Azure VM:
Get-AzNetworkSecurityGroup -ResourceGroupName "<rg>" -Name "<nsg>" |
    Get-AzNetworkSecurityRuleConfig | Where-Object { $_.DestinationPortRange -contains "445" }
```

</details>

<details><summary>Fix 2 — Test-Path fails but port 445 is open (DNS/Private Endpoint mismatch)</summary>

```powershell
Resolve-DnsName "<storageaccount>.file.core.windows.net"
# If this returns a PUBLIC IP but you have a Private Endpoint deployed:

# Check Private DNS Zone linkage
Get-AzPrivateDnsZone -ResourceGroupName "<rg>" -Name "privatelink.file.core.windows.net"
Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName "<rg>" -ZoneName "privatelink.file.core.windows.net"
# Expected: the client's VNet is listed here. If missing, link it:
New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName "<rg>" `
    -ZoneName "privatelink.file.core.windows.net" -Name "link-<vnet>" `
    -VirtualNetworkId "<vnetResourceId>" -EnableRegistration:$false
```

</details>

<details><summary>Fix 3 — Identity-based auth not configured (only storage key works)</summary>

```powershell
# Enable Entra Kerberos (cloud-only identities — simplest path, no on-prem AD needed)
Update-AzStorageAccount -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" `
    -EnableAzureActiveDirectoryKerberosForFile $true

# OR enable AD DS auth (hybrid, requires domain-joined clients + AD sync of the storage account)
# This requires running the AzFilesHybrid PowerShell module from a domain-joined machine:
# Import-Module AzFilesHybrid
# Join-AzStorageAccountForAuth -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" -DomainAccountType ComputerAccount
```

**Rollback:** `Update-AzStorageAccount ... -EnableAzureActiveDirectoryKerberosForFile $false` reverts to key-only auth. Existing NTFS ACLs referencing AD/Entra identities will stop resolving.

</details>

<details><summary>Fix 4 — Share quota exhausted</summary>

```powershell
# Check current usage vs quota
Get-AzRmStorageShareStats -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" -Name "<share>"

# Expand quota (max 100 TiB for provisioned v2 / large file shares, 5 TiB standard)
Update-AzRmStorageShare -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" `
    -Name "<share>" -QuotaGiB 2048
```

Quota increases are non-destructive and take effect immediately. If usage is genuinely at capacity, identify largest consumers before increasing:
```powershell
# From a mounted client — largest folders by size
Get-ChildItem "\\<storageaccount>.file.core.windows.net\<share>" -Directory |
    ForEach-Object { [PSCustomObject]@{ Folder = $_.Name; SizeGB = [math]::Round((Get-ChildItem $_.FullName -Recurse -File | Measure-Object Length -Sum).Sum / 1GB, 2) } } |
    Sort-Object SizeGB -Descending
```

</details>

<details><summary>Fix 5 — Stale cached credentials on client</summary>

```powershell
# List and clear stale cmdkey entries for the storage account
cmdkey /list | Select-String "<storageaccount>"
cmdkey /delete:"<storageaccount>.file.core.windows.net"

# Disconnect any existing mapped drive and remount cleanly
net use Z: /delete
net use Z: "\\<storageaccount>.file.core.windows.net\<share>"
```

</details>

<details><summary>Fix 6 — Access denied despite correct RBAC (NTFS ACL mismatch)</summary>

```powershell
# RBAC controls share-level access; NTFS ACLs control file/folder-level access.
# Both must align. Mount with the storage key (has full rights) to fix ACLs:
net use Z: "\\<storageaccount>.file.core.windows.net\<share>" /user:"AZURE\<storageaccount>" <storagekey>

icacls Z:\ /grant "<DOMAIN>\<user-or-group>:(OI)(CI)(M)"
icacls Z:\<subfolder> /grant "<DOMAIN>\<user-or-group>:(OI)(CI)(F)" /T

net use Z: /delete
```

**Note:** RBAC role grants the *ability* to authenticate to the share; NTFS ACLs grant the *actual* file permissions. A user can have the RBAC role and still get Access Denied if NTFS ACLs were never set.

</details>

---
## Escalation Evidence

```
=== Azure Files Escalation Pack ===
Date/Time:              _______________
Storage Account:        _______________
Share Name:             _______________
Client (hostname/OS):   _______________
User/Identity affected: _______________

Auth model configured (AADKERB / AD / None): _______________
Endpoint type (Public / Private Endpoint):    _______________

Port 445 test result:   SUCCESS / FAIL
DNS resolution result:  _______________ (public IP / private IP)
RBAC role present:      YES / NO  (role name: _______________)
NTFS ACL check:         PASS / FAIL
Quota:                  ____ GiB used of ____ GiB

Symptoms:
[ ] Cannot mount share   [ ] Access denied   [ ] Slow performance   [ ] Quota/disk full   [ ] Auth prompt loop

Actions taken so far:
1.
2.
3.

Escalation contact: Microsoft Support via Azure Portal > New Support Request (Storage Account blade)
Reference: https://learn.microsoft.com/en-us/azure/storage/files/
```

---
## 🎓 Learning Pointers

- **Port 445 is the recurring blocker.** Most corporate and ISP networks block outbound SMB (445) to the internet. Direct on-prem SMB mounts to Azure Files almost always require a Private Endpoint plus VPN/ExpressRoute — or Azure File Sync instead, which uses HTTPS. See [Azure Files networking overview](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-networking-overview).
- **RBAC and NTFS are two separate gates.** Azure RBAC (`Storage File Data SMB Share *`) governs whether the identity can authenticate to the share at all; NTFS ACLs on the share govern what they can actually do once connected. Missing either one causes access denied — check both, always.
- **Entra Kerberos vs AD DS is a one-time architecture decision.** Entra Kerberos suits cloud-only identities with no on-prem AD dependency; AD DS is required for hybrid/domain-joined clients needing Kerberos SSO. Mixing both on the same share leads to confusing intermittent auth failures. See [identity-based auth overview](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-active-directory-overview).
- **Quota is a hard ceiling, not a soft warning.** Unlike on-prem NTFS quotas, Azure file share quota exhaustion causes writes to fail outright (out-of-space errors) with no grace period — plan alerting on usage at 80-85% rather than discovering it at 100%.
- **Azure File Sync is the natural DFS replacement path.** For MSPs migrating off on-prem file servers/DFS, Azure File Sync (cloud tiering + multi-site sync) solves the "cross-site file share" problem without exposing SMB 445 to the internet — worth comparing against DFS-R when clients ask about cloud migration. See [Azure File Sync overview](https://learn.microsoft.com/en-us/azure/storage/file-sync/file-sync-introduction).
