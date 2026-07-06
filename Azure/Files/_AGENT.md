# Azure Files — Agent Instructions

## What's in this folder

Azure Files troubleshooting runbooks and diagnostic scripts for MSP engineers. Covers direct SMB/NFS share access, identity-based authentication (storage key, Entra Kerberos, AD DS), RBAC vs NTFS permission layers, quota management, and Azure File Sync (on-prem file server replacement / hybrid cloud tiering).

---

## Before responding, also check

| Also check | Why |
|---|---|
| `Azure/AVD/FSLogix-B.md` and `FSLogix-A.md` | FSLogix profile containers are the most common Azure Files consumer — share-level auth issues surface as profile load failures there |
| `DFS/Troubleshooting/` | Azure File Sync is frequently proposed as a cloud alternative/complement to DFS-R for multi-site file access — cross-reference when a client asks about migration |
| `EntraID/Troubleshooting/Connect-Sync-B.md` | AD DS identity-based auth depends on the storage account's computer account syncing correctly via Entra Connect |
| `EntraID/Troubleshooting/HybridJoin-B.md` | Domain-joined clients using AD DS Kerberos auth to Azure Files share dependencies with hybrid join |
| `Security/ConditionalAccess/` | CA policies can block Entra Kerberos token issuance for Azure Files access from unmanaged devices |

---

## Folder contents

| File | What it covers |
|---|---|
| `AzureFiles-B.md` | Hotfix runbook — can't mount share, access denied, quota exhausted, slow performance |
| `AzureFiles-A.md` | Deep-dive reference — direct mount vs Azure File Sync architecture, identity auth models, RBAC vs NTFS, tiering |
| `Scripts/Get-AzureFileShareHealth.ps1` | Reports share quota/usage, identity auth configuration, network rules, and RBAC assignments; optional SMB connectivity test |

---

## Common entry points

| User question | Start here |
|---|---|
| "Can't connect to the file share" | `AzureFiles-B.md` → Triage |
| "Getting access denied on the share" | `AzureFiles-B.md` → Fix 6 (RBAC vs NTFS) |
| "Share is full / out of space" | `AzureFiles-B.md` → Fix 4 |
| "How does Azure Files identity auth actually work?" | `AzureFiles-A.md` → How It Works |
| "Should we replace our file server with Azure Files?" | `AzureFiles-A.md` → Playbook 2 (Azure File Sync) |
| "Files show weird small icons and take forever to open" | `AzureFiles-A.md` → Symptom → Cause Map (cloud tiering) |
| "Need to collect data before opening a Microsoft ticket" | `Scripts/Get-AzureFileShareHealth.ps1` |

---

## Key diagnostic commands

```powershell
# Test SMB reachability to the storage account
Test-NetConnection -ComputerName "<storageaccount>.file.core.windows.net" -Port 445

# Check identity-based auth model configured
(Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").AzureFilesIdentityBasedAuth

# Check RBAC role assignments on the share
Get-AzRoleAssignment -Scope (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<storageaccount>").Id |
    Where-Object { $_.RoleDefinitionName -like "Storage File Data*" }

# Check quota vs usage
Get-AzRmStorageShare -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" -Name "<share>"
Get-AzRmStorageShareStats -ResourceGroupName "<rg>" -StorageAccountName "<storageaccount>" -Name "<share>"

# Azure File Sync server endpoint status
Get-StorageSyncServerEndpoint | Select-Object DisplayName, SyncStatus, LastSyncTimestamp
```

---

## Key dependency chain

```
Client (on-prem or Azure)
    │
    └── Network path (Public + firewall allow-list, OR Private Endpoint + Private DNS)
            │
            └── TCP 445 (SMB) / 2049 (NFS) reachable
                    │
                    └── Identity-based auth: Storage Key | Entra Kerberos (AADKERB) | AD DS
                            │
                            └── Azure RBAC (Storage File Data SMB Share *) — authentication gate
                                    │
                                    └── NTFS ACLs on share — authorization gate
                                            │
                                            └── [Optional] Azure File Sync agent
                                                    ├── Server endpoint (on-prem)
                                                    └── Cloud endpoint + tiering policy
```

---

## Response format reminder

Always respond in 3 layers:
1. **Immediate action** — what to run right now (triage command)
2. **Root cause** — why it's happening (architecture context, usually RBAC vs NTFS or network path)
3. **Fix + validation** — how to resolve and verify it's resolved
