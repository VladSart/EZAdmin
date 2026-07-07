# Azure Backup — Agent Instructions

## What's in this folder

Runbooks and scripts for **Azure Backup via Recovery Services Vault (RSV)**, scoped to Azure VM (IaaS) protection — backup job failures, protection/coverage gaps, recovery point consistency, restores, soft delete, and vault-level configuration (redundancy, immutability, RBAC). This is infrastructure-level backup (VM disks), distinct from `M365/Backup/` (SaaS mailbox/file data protection) and out of scope for Azure Site Recovery (ASR) replication/DR, which is a related but separate service built on the same vault construct.

---

## Before responding, also check

- **M365/Backup** (`M365/Backup/`) — if the client's question is actually about mailbox/SharePoint/OneDrive data protection rather than VM disks, that's a different service and folder entirely
- **Azure/AVD** (`Azure/AVD/`) — session hosts are Azure VMs and can be protected by Azure Backup the same way; FSLogix profile *data* backup is a separate concern from the VM backup covered here
- **Windows/Troubleshooting** — guest-level issues (VM Agent, VSS writers) surfaced during backup troubleshooting often have deeper root causes covered there
- **Azure/Arc** — Arc-enabled (non-Azure) servers use a different backup extension model (MARS agent) — this folder assumes native Azure VMs

---

## Folder contents

| File | What it covers |
|------|----------------|
| `AzureBackup-B.md` | Hotfix runbook — backup job failures (guest agent, extension, VSS, stuck jobs, protection stopped) |
| `AzureBackup-A.md` | Deep dive — full architecture (instant vs vault-tier recovery points, consistency levels, soft delete, immutability), dependency stack, remediation playbooks including restore and bulk extension remediation |
| `Scripts/Get-AzureBackupJobStatus.ps1` | Vault-wide read-only report: protection status, failed jobs, guest prerequisite health, soft-deleted items pending |

---

## Common entry points

- **"Backup job failed for a VM"** → `AzureBackup-B.md` (triage first — pull the actual error code)
- **"VM isn't showing as protected / missing from backups"** → `AzureBackup-B.md` Fix 5, or `AzureBackup-A.md` Phase 2 for fleet-wide coverage gaps
- **"How do I restore a VM"** → `AzureBackup-A.md` Playbook 2
- **"I deleted a backup item by mistake"** → `AzureBackup-A.md` Playbook 1 (soft delete — 14-day window)
- **"Client wants compliance-locked/immutable backups"** → `AzureBackup-A.md` Playbook 4 — read the irreversibility warning before acting
- **"Collect vault health for a ticket/report"** → `Scripts/Get-AzureBackupJobStatus.ps1`
- **"Restore is taking forever"** → `AzureBackup-A.md` Symptom → Cause Map (instant-tier vs vault-tier recovery point)

---

## Key diagnostic commands

```powershell
# Set vault context — required before any other Az.RecoveryServices cmdlet in a session
$vault = Get-AzRecoveryServicesVault -ResourceGroupName "<rg>" -Name "<vaultName>"
Set-AzRecoveryServicesVaultContext -Vault $vault

# Recent failed jobs with error detail
Get-AzRecoveryServicesBackupJob -Status Failed -From (Get-Date).AddDays(-7) |
    ForEach-Object { Get-AzRecoveryServicesBackupJobDetail -Job $_ }

# Protection status for all Azure VMs in the vault
Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM |
    Select-Object Name, ProtectionStatus, LastBackupStatus, LastBackupTime

# Guest-level prerequisite check (per VM)
Get-AzVMExtension -ResourceGroupName "<rg>" -VMName "<vmName>" |
    Where-Object { $_.ExtensionType -like "*BackupExtension*" }
(Get-AzVM -ResourceGroupName "<rg>" -Name "<vmName>" -Status).VMAgent.Statuses

# Soft-deleted items pending
Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -DeleteState "ToBeDeleted"
```

---

## Key dependency chain

```
Recovery Services Vault
    │
    └── Backup Policy (schedule + retention)
            │
            └── Protected Item (per VM)
                    │
                    └── Azure VM Agent + Backup Extension (guest-level prerequisites)
                            │
                            └── VM power state (Running = AppConsistent eligible; Deallocated = CrashConsistent only)
                                    │
                                    └── Managed disk snapshot → Instant Recovery Point → Vault storage transfer
                                            │
                                            └── Recovery point retained per policy (subject to soft delete on item deletion)
```

---

## Response format reminder (always 3 layers)

1. **Immediate action** — what to do right now to unblock the failing job or urgent restore (Mode B)
2. **Root cause** — why it happened (guest-side vs vault-side vs policy/config) (Mode A)
3. **Prevention** — coverage audits, extension health monitoring, retention/redundancy review to stop recurrence
