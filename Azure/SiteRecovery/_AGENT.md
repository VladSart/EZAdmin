# Azure Site Recovery (Azure-to-Azure) — Agent Instructions

## What's in this folder

Runbooks and scripts for **Azure Site Recovery replicating Azure VMs between regions (A2A)** — replication health, data churn, app-consistent recovery point failures, VSS provider issues, failover, and reprotect/failback. Distinct from `Azure/OnPremDR/`, which covers on-premises VMware/Hyper-V sources replicating *into* Azure (different appliance model, different fabric types) even though both use the same underlying ASR service and share some component names (Mobility Service).

---

## Before responding, also check

- **Azure/OnPremDR** (`Azure/OnPremDR/`) — if the source workload lives on-premises (VMware or Hyper-V), not already in Azure, that's the sibling folder — don't apply A2A network/churn fixes to an on-prem appliance problem
- **Azure/Backup** — this folder is about continuous replication/DR, not point-in-time backup/restore
- **Azure/Networking** — failover network config (target vNet, NSG, load balancer) issues after a failover are often a networking problem wearing an ASR costume
- **Azure/Compute** — if a *failed-over* VM won't boot, cross-check `Azure/Compute/VMBootRepair-B.md` once you've confirmed replication itself is healthy

---

## Folder contents

| File | What it covers |
|------|----------------|
| `SiteRecovery-B.md` | Hotfix runbook — high data churn, network/throttling issues, app-consistent recovery point failures, VSS provider problems, BookmarkNotFound after disk changes, expired tenant/client ID heartbeat loss, reprotect/failback |
| `SiteRecovery-A.md` | Deep dive — A2A replication architecture, full setup sequence, test failover validation, full failover/commit/reprotect lifecycle, data churn remediation |
| `Scripts/Get-SiteRecoveryHealth.ps1` | Read-only audit: vault-wide replication health, churn rate, and recovery point status across protected items |

---

## Common entry points

- **"Replication health shows Critical or Warning"** → `SiteRecovery-B.md` Triage first — identify churn vs network vs VSS before picking a fix
- **"High data churn / Error 153007"** → `SiteRecovery-B.md` Fix 1, or `SiteRecovery-A.md` Playbook 4 for disk exclusion/resize
- **"App-consistent recovery points failing / Error 153006"** → `SiteRecovery-B.md` Fix 3-4 (VSS provider)
- **"Failover fails with BookmarkNotFound"** → `SiteRecovery-B.md` Fix 5 — usually followed a disk tier/SKU change
- **"Mobility Service heartbeat lost"** → `SiteRecovery-B.md` Fix 6 (expired AAD tenant/client ID)
- **"Need to run a DR drill"** → `SiteRecovery-A.md` Playbook 2 (test failover)
- **"Actual failover happened, now what"** → `SiteRecovery-A.md` Playbook 3 (failover → commit → reprotect)
- **"Setting up A2A replication for a new workload"** → `SiteRecovery-A.md` Playbook 1
- **"Collect replication health for a report"** → `Scripts/Get-SiteRecoveryHealth.ps1`

---

## Key diagnostic commands

```powershell
# Set vault context — required before any other ASR cmdlet works
$vault = Get-AzRecoveryServicesVault -ResourceGroupName "<vaultRg>" -Name "<vaultName>"
Set-AzRecoveryServicesAsrVaultContext -Vault $vault

# Replication health and churn for all protected items
Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer (Get-AzRecoveryServicesAsrProtectionContainer) |
  Select-Object FriendlyName, ProtectionState, ReplicationHealth,
                @{N='ChurnMBps';E={$_.ProviderSpecificDetails.MonitoringPercentageCompletion}}

# Recovery points available for a specific protected item
Get-AzRecoveryServicesAsrRecoveryPoint -ReplicationProtectedItem $rpi | Select-Object RecoveryPointTime, RecoveryPointType
```

---

## Key dependency chain

```
Recovery Services Vault (ASR-enabled, A2A)
    │
    └── Replication policy (RPO threshold, recovery point retention, app-consistent frequency)
            │
            └── Mobility Service agent (installed on source Azure VM)
                    │
                    └── Cache storage account (staging for replicated writes before transfer to target region)
                            │
                            └── Data churn / bandwidth throttling determines replication health
                                    │
                                    └── Recovery points (crash-consistent continuous; app-consistent via VSS on schedule)
                                            │
                                            └── Failover (test/planned/unplanned) → commit → reprotect → failback
```

---

## Response format reminder (always 3 layers)

1. **Immediate action** — restore replication health or complete a stuck failover/reprotect (Mode B)
2. **Root cause** — churn, network/throttling, VSS/app-consistency, or auth/heartbeat issue (Mode A)
3. **Prevention** — churn monitoring and disk exclusion tuning, regular test failover drills, tenant/client ID credential rotation tracking
