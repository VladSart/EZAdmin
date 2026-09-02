# On-Premises to Azure Disaster Recovery — Agent Instructions

## What's in this folder

Runbooks and scripts for **Azure Site Recovery (ASR) protecting on-premises VMware and Hyper-V workloads into Azure** — the two on-prem-to-Azure replication paths, which share almost nothing at the component level below the vault. VMware/physical machines replicate through an on-premises **ASR replication appliance** (a single OVA); Hyper-V replicates through a **Provider + Recovery Services agent** installed directly on the Hyper-V host(s) or VMM server, with no separate appliance. Always confirm which platform you're on before applying a fix. Distinct from `Azure/SiteRecovery/`, which covers Azure-to-Azure (A2A) replication of VMs that already live in Azure.

---

## Before responding, also check

- **Azure/SiteRecovery** (`Azure/SiteRecovery/`) — if the source VM is already an Azure VM (A2A replication, not on-prem), that's the sibling folder — component names overlap (Mobility Service, ASR) but the topology and appliance model differ
- **Azure/Backup** — this folder is about DR/failover, not point-in-time backup/restore of the same workloads
- **ActiveDirectory** (`ActiveDirectory/`) — DR failover of a domain controller or AD-dependent app has its own consistency/USN-rollback concerns beyond ASR replication health
- **Windows/Troubleshooting** — once failed over, guest-level issues (network adapter renaming, drive letter changes) are covered there

---

## Folder contents

| File | What it covers |
|------|----------------|
| `OnPremDR-B.md` | Hotfix runbook — replication appliance/Provider offline, Mobility Service not communicating, stuck resync, proxy blocking replication, failed/stuck failback |
| `OnPremDR-A.md` | Deep dive — VMware Modernized vs Classic vs Hyper-V architecture, initial setup for both platforms, Classic-to-Modernized migration, non-recoverable Hyper-V VM recovery |
| `Scripts/Get-OnPremDRHealth.ps1` | Read-only audit: appliance/Provider connectivity, per-VM replication health and resync status across the vault |

---

## Common entry points

- **"Replication appliance/Provider shows offline or stale heartbeat"** → `OnPremDR-B.md` Fix 2 (VMware) or Fix 4 (Hyper-V)
- **"Client is still on Classic VMware experience"** → `OnPremDR-B.md` Fix 1 — flag the 30 Mar 2026 retirement date, then `OnPremDR-A.md` Playbook 3 to migrate
- **"Mobility Service agent won't talk to the appliance"** → `OnPremDR-B.md` Fix 3
- **"Hyper-V VM stuck Critical / non-recoverable"** → `OnPremDR-B.md` Fix 5, or `OnPremDR-A.md` Playbook 4 for the full recovery
- **"Resync has been running way too long"** → `OnPremDR-B.md` Fix 6
- **"Replication traffic blocked / proxy issue"** → `OnPremDR-B.md` Fix 7
- **"Failback landed but has no network"** → `OnPremDR-B.md` Fix 8
- **"Setting up DR for a new client"** → `OnPremDR-A.md` Playbook 1 (VMware) or Playbook 2 (Hyper-V + VMM)
- **"Collect DR health for a report"** → `Scripts/Get-OnPremDRHealth.ps1`

---

## Key diagnostic commands

```powershell
# Set vault context — required before any other ASR cmdlet works
$vault = Get-AzRecoveryServicesVault -ResourceGroupName "<vaultRg>" -Name "<vaultName>"
Set-AzRecoveryServicesAsrVaultContext -Vault $vault

# Fabric and appliance/Provider health (platform-agnostic call, results differ by fabric type)
Get-AzRecoveryServicesAsrFabric | Select-Object Name, FabricType,
  @{N='HealthState';E={$_.FabricSpecificDetails.HealthErrorDetails}}

# Per-VM replication/protection status
Get-AzRecoveryServicesAsrProtectionContainer -Fabric (Get-AzRecoveryServicesAsrFabric) |
  Get-AzRecoveryServicesAsrReplicationProtectedItem |
  Select-Object FriendlyName, ProtectionState, ReplicationHealth
```

---

## Key dependency chain

```
Recovery Services Vault (ASR-enabled)
    │
    ├── VMware/Physical path
    │       └── ASR Replication Appliance (OVA: config server + process server + MT roles)
    │               └── Mobility Service agent (per source VM)
    │
    └── Hyper-V path
            └── Provider + Recovery Services agent (installed on Hyper-V host(s) / VMM server)
                    │
    (both converge)
            │
            └── Replication health (initial sync → delta sync → resync if broken)
                    │
                    └── Failover (test / planned / unplanned) → commit → reprotect/failback
```

---

## Response format reminder (always 3 layers)

1. **Immediate action** — restore replication health or unblock a stuck failover/failback (Mode B)
2. **Root cause** — appliance/Provider connectivity, agent, network/proxy, or platform-migration state (Mode A)
3. **Prevention** — Classic-to-Modernized migration before the retirement deadline, proactive resync monitoring, DR drills via test failover
