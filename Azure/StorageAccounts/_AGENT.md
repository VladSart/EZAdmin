# Azure Storage Accounts — Agent Instructions

## What's in this folder

Azure Storage Account (Blob/Queue/Table) troubleshooting runbooks and diagnostic scripts for MSP engineers. Covers the network → authentication → authorization gate model, Shared Key vs. SAS (Account/Service vs. User Delegation) vs. Entra ID (RBAC) auth, the control-plane-vs-data-plane RBAC split, soft delete/versioning/immutability (WORM), lifecycle management tiering, and public access toggles. Azure Files (SMB/NFS) has its own dedicated folder — see `Azure/Files/`.

---

## Before responding, also check

| Also check | Why |
|---|---|
| `Azure/Files/AzureFiles-B.md` and `-A.md` | Azure Files (SMB/NFS shares) lives on the same storage account resource but has a completely different protocol/identity layer — don't apply this folder's Blob/Queue/Table guidance to a Files ticket |
| `Azure/Backup/AzureBackup-B.md` and `-A.md` | Azure Backup uses storage accounts as its underlying data store for some scenarios (MARS, MABS) — a storage-account-level access issue can masquerade as a backup failure |
| `Azure/KeyVault/KeyVault-A.md` | Same RBAC-vs-legacy-authorization-model pattern (Access Policy vs. RBAC) appears there — useful comparison when explaining the concept to a client |
| `EntraID/Graph/Useful-Queries.md` | User Delegation SAS and Entra ID (RBAC) auth both depend on a healthy Entra ID token issuance path |
| `Security/ConditionalAccess/` | CA policies can block Entra ID token issuance for storage data-plane access from unmanaged devices |

---

## Folder contents

| File | What it covers |
|---|---|
| `StorageAccounts-B.md` | Hotfix runbook — 403s despite RBAC, expired/invalid SAS, firewall blocks, "missing" (soft-deleted) blobs, immutability write blocks |
| `StorageAccounts-A.md` | Deep-dive reference — network/authn/authz gate model, auth model comparison, data-plane vs. control-plane RBAC, soft delete/versioning/immutability, lifecycle management |
| `Scripts/Get-AzureStorageAccountHealth.ps1` | Reports account toggles, network posture, data-plane RBAC gaps, soft delete/versioning state, and lifecycle policy presence across one or all accounts |

---

## Common entry points

| User question | Start here |
|---|---|
| "I have Owner/Contributor but get 403 on the blob" | `StorageAccounts-B.md` → Fix 5 (missing data-plane RBAC role) |
| "Our script stopped authenticating after a security review" | `StorageAccounts-B.md` → Fix 2 (AllowSharedKeyAccess disabled) |
| "The SAS link stopped working" | `StorageAccounts-B.md` → Fix 4 (expired or key-rotated SAS) |
| "Can't reach the storage account at all" | `StorageAccounts-B.md` → Triage steps 1-2, then Fix 3 (firewall) |
| "The blob/container is just gone" | `StorageAccounts-B.md` → Fix 6 (soft delete undelete) |
| "Can't delete a blob, error mentions immutability" | `StorageAccounts-A.md` → Symptom → Cause Map (locked immutability policy) |
| "What's the difference between RBAC, SAS, and Shared Key here?" | `StorageAccounts-A.md` → How It Works |
| "Fleet-wide check before a client handoff or security review" | `Scripts/Get-AzureStorageAccountHealth.ps1 -AllAccounts` |

---

## Key diagnostic commands

```powershell
# Check account toggles (the two most common root causes)
Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<sa>" | Select-Object AllowSharedKeyAccess, AllowBlobPublicAccess

# Check data-plane RBAC (the #1 gap when control-plane access exists but data access fails)
Get-AzRoleAssignment -Scope (Get-AzStorageAccount -ResourceGroupName "<rg>" -Name "<sa>").Id |
    Where-Object { $_.RoleDefinitionName -match "Storage (Blob|Queue|Table) Data" }

# Check network firewall posture
Get-AzStorageAccountNetworkRuleSet -ResourceGroupName "<rg>" -Name "<sa>"

# Check for soft-deleted items before treating as data loss
Get-AzStorageBlob -Container "<container>" -Context $ctx -IncludeDeleted | Where-Object { $_.IsDeleted }

# Check for a locked immutability policy before troubleshooting a "can't delete" ticket
Get-AzRmStorageContainerImmutabilityPolicy -ResourceGroupName "<rg>" -StorageAccountName "<sa>" -ContainerName "<container>"
```

---

## Key dependency chain

```
Caller (user, app, managed identity)
    │
    └── Network (Public + firewall allow-list, OR Private Endpoint + Private DNS)
            │
            └── AuthN: Shared Key | Account/Service SAS | User Delegation SAS | Entra ID token
                    │
                    └── AuthZ: Storage Blob/Queue/Table Data * role (separate from control-plane RBAC)
                            │
                            └── Resource state: soft delete | versioning | immutability | lifecycle policy
```

---

## Response format reminder

Always respond in 3 layers:
1. **Immediate action** — what to run right now (triage command)
2. **Root cause** — why it's happening (which of network/authn/authz gate failed — control-plane vs. data-plane RBAC is the most common surprise)
3. **Fix + validation** — how to resolve and verify it's resolved
