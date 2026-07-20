# Hyper-V Host & VM — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why the virtualization stack behaves as it does, not just what command to run.

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

- **Applies to:** the Windows Server Hyper-V role, Server 2016 through 2025, in standalone-host and Failover Clustering (Hyper-V cluster) configurations, including Hyper-V Replica for disaster recovery.
- **Covers:** VM lifecycle and state model, Integration Services (host↔guest two-way communication), checkpoints/differencing disks (AVHDX) and their failure modes, virtual switch architecture, Live Migration (including authentication modes and the Event ID 21502 failure family), Failover Clustering integration (Cluster Shared Volumes, quorum, cluster resource model for VMs), and Hyper-V Replica (asynchronous DR replication).
- **Does not cover:** guest-OS-internal troubleshooting once the VM is confirmed running and healthy at the virtualization layer (that's the guest's own OS-specific runbook); Storage Spaces Direct (S2D) deep architecture — this runbook treats shared storage as a dependency, not a topic in its own right; Azure/AVD cloud-hosted session VMs (see `Azure/AVD/` — a materially different management plane); System Center Virtual Machine Manager (SCVMM) — this runbook assumes native Hyper-V Manager/PowerShell/Failover Cluster Manager administration.
- **Licensing/edition:** Hyper-V is a role available on Windows Server Standard and Datacenter, including Server Core. Standard edition includes rights for up to 2 Windows Server guest OS instances per license; Datacenter includes unlimited Windows Server guest instances on the licensed host — a genuinely consequential distinction for any MSP sizing a new virtualization host, since guest OS licensing (not the Hyper-V role itself, which is free either way) is usually the larger cost driver.
- **Admin roles needed:** local Administrators on the Hyper-V host for most VM operations; **Hyper-V Administrators** local group for delegated management without full local admin rights; cluster operations additionally require membership appropriate to the Failover Clustering feature (typically domain accounts in the cluster's own access control, not a separate AD group by default).
- **Current platform status (2026):** Hyper-V remains Microsoft's actively developed core hypervisor and the foundation under Azure Local (formerly Azure Stack HCI), AVD, and Windows 365 — not a legacy technology. The one live deprecation to flag: **LBFO NIC Teaming is deprecated in favor of Switch Embedded Teaming (SET)** for any new host network configuration; existing LBFO deployments continue to function but Microsoft's own current guidance explicitly steers new builds to SET.

---

## How It Works

<details><summary>Full architecture</summary>

### VM lifecycle and the state model

A Hyper-V VM's `State` (from `Get-VM`) moves through `Off → Starting → Running → (Saving/Paused) → Stopping → Off`, with `Critical` reserved for a VM that can't function due to a missing/inaccessible resource (most often a virtual hard disk the host can no longer reach). `Status` is a separate field reporting operational health once `Running` — `Operating normally` is the only fully healthy value; anything else (including blank) means Integration Services, a checkpoint operation, or a backup interaction is in a transitional or degraded state. Each running VM is backed by its own **worker process** (`vmwp.exe`) — one per VM, independent of the others, which is why one VM being stuck does not by itself indicate host-wide failure and why restarting the **VMMS** (Virtual Machine Management Service, the host-wide management/orchestration service) does not stop already-running VMs.

### Integration Services — the host↔guest communication channel

Integration Services are a set of six components providing two-way communication between host and guest over the VMBus (a high-speed in-memory channel, not a network path): Heartbeat, Time Synchronization, Data Exchange (KVP), Guest Shutdown, VSS (backup), and Guest Service Interface (file copy). **Each must be enabled on both host and guest to function** — the host-side `Enable-VMIntegrationService`/`Disable-VMIntegrationService` controls whether the host permits the channel; the guest-side Windows service (named `vmicXXX`, e.g. `vmicheartbeat`) must independently be running. Enabling a service host-side auto-starts the guest service; the reverse relationship is asymmetric by design — starting a guest-disabled service in-guest gets it stopped again by Hyper-V, while stopping a host-enabled service in-guest gets it restarted by Hyper-V. This asymmetry is a common point of confusion when engineers try to manage these as ordinary Windows services from inside the guest. Linux guests implement the equivalent functionality via the `hv_utils` kernel module and userspace daemons (`hv_kvp_daemon`, `hv_vss_daemon`, `hv_fcopy_daemon`) rather than Windows services.

### Checkpoints and differencing disks (AVHDX)

A checkpoint captures VM state by redirecting new writes to a new **differencing disk** (`.avhdx`) chained to the disk state at checkpoint time, rather than copying the base disk. Deleting/merging a checkpoint folds the differencing disk's changes back into its parent. This design means checkpoints are cheap to create but **the chain itself is the fragile part** — a broken parent/child link (from a crash mid-merge, manual file deletion, or storage failure) can render every checkpoint after the break unusable, and a long, unmerged chain both consumes growing disk space and adds read-path latency (every read may need to walk multiple differencing disks to find the actual data). Production Checkpoints (the default checkpoint type since Server 2016, using VSS/Volume Snapshot Service inside the guest for application-consistent state) are recommended over the legacy "Standard" checkpoint type (a crash-consistent, in-memory-state-included snapshot) for any VM where Integration Services/VSS support exists in the guest. **Checkpoints are explicitly not a backup strategy** — they have no independent retention policy, no offline copy, and depend entirely on the same storage as the VM itself; third-party backup software creating and failing to clean up its own checkpoints is the single most common real-world source of orphaned/excessive checkpoint chains.

### Virtual switches

Hyper-V Virtual Switch has three types: **External** (bound to a physical NIC, gives VMs a path to the physical network), **Internal** (VM-to-VM and VM-to-host communication, no physical NIC, host itself gets a virtual adapter on this switch), and **Private** (VM-to-VM only, not even the host can reach it — commonly used for isolated lab/test segments). **Switch names must match exactly across every host in a cluster** for Live Migration to succeed — this isn't a soft recommendation, it's a hard requirement enforced at migration time (Event ID 21502). For host networking redundancy, Microsoft's current guidance is **Switch Embedded Teaming (SET)** rather than legacy LBFO NIC Teaming — SET integrates teaming directly into the virtual switch rather than as a separate NIC-teaming layer underneath it, and is required for certain newer features (RDMA passthrough to VMs, for example, is SET-only).

### Live Migration

Live Migration moves a running VM between hosts with no perceived downtime, by iteratively copying memory pages while the VM keeps running on the source, then performing a brief final "blackout" handoff (typically sub-second on a healthy network; anything approaching or exceeding a second or two, as flagged by Event ID 20417, indicates insufficient migration network bandwidth). Live Migration requires **matching virtual switch names**, **compatible or explicitly-compatibility-mode processors** across source and destination, **an identical or upgradeable VM configuration version**, and a working **authentication path** between hosts — either **Kerberos** (requires Constrained Delegation configured in AD for the `cifs` and Microsoft Virtual System Migration Service SPNs on both host computer accounts) or **CredSSP** (simpler to configure — no AD delegation setup — but requires the initiating user to be interactively logged onto the source host, which makes it unsuitable for fully automated/remote migration triggers). TCP port 6600 carries the actual migration traffic; TCP port 3343 is used for cluster-to-cluster coordination when clustering is involved. `Compare-VM -Name <vm> -DestinationHost <host>` runs the same compatibility checks Hyper-V performs automatically before a real migration, surfacing switch/processor/version mismatches in a single, safe, non-disruptive call — this is the standard first diagnostic for any migration failure rather than working backward from an Event ID 21502 sub-code.

### Failover Clustering integration

A clustered Hyper-V deployment layers VMs on top of standard Windows Failover Clustering. **Cluster Shared Volumes (CSV)** provide the mechanism that lets every node in the cluster simultaneously access the same shared storage volume as if it were locally mounted, which is what makes Live Migration of a VM's storage-resident state possible without a separate storage migration step. Each VM is represented in the cluster as two linked cluster resources — "Virtual Machine" and "Virtual Machine Configuration" — both of which must have every intended failover target listed as a possible owner node (a common, silent cause of Event ID 21502's `0x80071398`/`ERROR_HOST_NODE_NOT_GROUP_OWNER` when a node was added to the cluster after the VM resource was created and never added to its possible-owners list). **Quorum** determines how many node/witness failures the cluster can tolerate before losing the ability to make authoritative decisions about resource ownership; a cluster that loses quorum takes all clustered resources — including every VM — offline as a safety measure against split-brain, regardless of whether the underlying hosts and storage are individually still healthy.

### Hyper-V Replica

Hyper-V Replica provides asynchronous, storage-independent VM replication to a secondary host or cluster for disaster recovery — a fundamentally different mechanism from Failover Clustering (which provides high availability within a site via shared storage) or Live Migration (which is a planned, momentary state transfer, not ongoing replication). Replica tracks changes via a **Hyper-V Replica Log (HRL)** file that accumulates write deltas on the primary and periodically ships them to the replica target; **HRL growth is the single most common Replica-specific storage problem** — if the network path to the replica target degrades or the target falls behind, the HRL keeps growing on the primary rather than the replication simply stalling silently, and can exhaust primary-side disk space if left unaddressed. Clustered Replica deployments require a **Hyper-V Replica Broker** cluster role (a dedicated resource that abstracts which physical node is currently hosting a given replicated VM, so the replica relationship survives a Live Migration or failover on the primary side without needing reconfiguration). Authentication is Kerberos (default, intra-domain/trusted-domain scenarios) or certificate-based (required for cross-forest, workgroup, or Internet-facing DR scenarios, and uses HTTPS on TCP 443 by default rather than Kerberos's port).

</details>

---

## Dependency Stack

```
Layer 7 — [Clustered only] Failover Cluster quorum and cluster service health
    Quorum maintained; loss of quorum takes ALL clustered VMs offline as a
    safety measure regardless of individual host/storage health
        │
Layer 6 — [Clustered only] Cluster Shared Volume (CSV) accessibility
    CSV State: Online on the owning node; Event ID 5120 signals interruption
        │
Layer 5 — Hyper-V role + VMMS (Virtual Machine Management Service) running
    Host-wide; independent of any single VM's worker process (vmwp.exe)
        │
Layer 4 — Host resource availability (CPU, memory, storage IO)
    vmwp.exe (per-VM) fails to allocate if the host genuinely lacks headroom
        │
Layer 3 — Virtual switch configuration
    Must exist with an IDENTICAL name on every node for Live Migration;
    External/Internal/Private type determines VM network reachability
        │
Layer 2 — VM configuration (.vmcx) + virtual disks (.vhdx/.avhdx) accessible
    Config version supported by every node that might host this VM;
    differencing disk chain (if checkpoints exist) unbroken
        │
Layer 1 — Integration Services enabled BOTH host-side and guest-side
    Asymmetric enforcement: host state governs, guest state can only comply
    or be silently corrected back into compliance
        │
[Optional branch] Live Migration — auth path (Kerberos delegation or CredSSP),
  TCP 6600/3343 reachable, Compare-VM reports no incompatibilities
        │
[Optional branch] Hyper-V Replica — Broker role (clustered) or direct host
  config (standalone), TCP 443 reachable, HRL not exhausting primary storage
        │
VM Running, Status: Operating normally
```

A fault at Layer 7 (quorum) is total and cluster-wide — it takes down every clustered VM simultaneously regardless of that VM's own health, which is the single most catastrophic-looking but often fastest-to-diagnose failure shape (check quorum before assuming a storage or VM-specific fault when multiple unrelated VMs go offline together). A fault at Layer 1 (Integration Services) is narrow and per-VM, visible primarily as a degraded `Status` rather than an outage.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Single VM shows `State: Off`, no admin action taken | VM crashed, or host forcibly reclaimed resources under memory pressure | `Get-WinEvent` on Hyper-V-Worker-Admin log; host memory headroom |
| VM `Running` but `Status` not `Operating normally` | Integration Services degraded, most often Heartbeat | `Get-VMIntegrationService`; guest-side `vmicheartbeat` service state |
| Multiple unrelated VMs go offline simultaneously (clustered) | Quorum lost — cluster-wide safety shutdown, not a per-VM fault | `Get-ClusterNode`; cluster quorum configuration/witness state |
| Checkpoint won't delete or merge | Orphaned checkpoint (usually backup software), file lock, or broken chain | `Get-VMSnapshot` vs. actual `.avhdx` files on disk |
| VM extremely slow, disk I/O heavy despite normal host load | Long unmerged checkpoint chain — every read walks multiple differencing disks | `Get-VHD` `ParentPath` chain depth |
| Live Migration fails, Event ID 21502, switch-related message | Virtual switch name mismatch between source and destination | `Get-VMSwitch` on both hosts; names must match exactly |
| Live Migration fails, `0x80071398`/`ERROR_HOST_NODE_NOT_GROUP_OWNER` | Target node not listed as a possible owner for the VM's cluster resources | `Get-ClusterResource "<vm>" \| Get-ClusterOwnerNode` |
| Live Migration fails, Kerberos/credential error (`0x8009030D`/`0x8009030E`) | Constrained Delegation not configured (or Kerberos selected but CredSSP was intended) | AD computer account Delegation tab; `Hyper-V Settings > Live Migrations > Authentication Protocol` |
| Live Migration succeeds but VM loses network connectivity after | Source/destination virtual networks aren't actually the same subnet despite same switch name | Compare subnet/VLAN config on both hosts' physical uplinks |
| Event ID 5120 repeating with `STATUS_CLUSTER_CSV_AUTO_PAUSE_ERROR` only | Benign, known false-positive pattern | Confirm no OTHER status code is interleaved in the same window |
| Event ID 5120 with any other status code | Genuine storage/network interruption between node and CSV | Storage/network driver and firmware currency; `Get-ClusterSharedVolume` state |
| VM won't start after restore/import, "Incomplete VM configuration" | Config files on non-shared (local) storage in a cluster, or config version unsupported on this node | `Get-VM ... \| Select Path, ConfigurationLocation`; `Get-VMHostSupportedVersion` |
| Replication health `Critical`/`Warning` | Sync fell behind (HRL growing) or last sync attempt failed (auth/network) | `Get-VMReplication`; `Measure-VMReplication` for pending change size |
| Replication health `Resynchronization Required` | A full resync baseline is needed — typically after an extended primary/replica disconnect | `Start-VMResynchronization` |
| Primary host disk filling up unexpectedly on a Replica-enabled VM | HRL file growing because replica target isn't keeping up or is unreachable | Check `.hrl` file size in the VM's storage folder; replica network path |

---

## Validation Steps

**1. Role and management service**
```powershell
Get-WindowsFeature Hyper-V
Get-Service VMMS | Select-Object Status, StartType
```
Good: feature installed, service running/automatic. Bad: VMMS stopped — no VM management operations succeed host-wide, though already-running VMs (their independent `vmwp.exe` processes) keep running.

**2. VM inventory and Integration Services**
```powershell
Get-VM | Select-Object Name, State, Status, Version
Get-VM | Get-VMIntegrationService | Select-Object VMName, Name, Enabled, PrimaryStatusDescription
```
Good: `Status: Operating normally` on all running VMs, all intended Integration Services `Enabled: True` with OK status. Bad: any VM's Heartbeat showing a non-OK status — treat as the first sign of a guest-side or VMBus-level problem.

**3. Checkpoint and disk chain audit**
```powershell
Get-VM | Get-VMSnapshot | Select-Object VMName, Name, CreationTime, SnapshotType
Get-VM | Get-VMHardDiskDrive | ForEach-Object { Get-VHD -Path $_.Path } | Select-Object Path, ParentPath, VhdType, FileSize
```
Good: every `.avhdx` on disk corresponds to a visible checkpoint; chains are shallow (single digits). Bad: `.avhdx` files with no matching `Get-VMSnapshot` entry (orphans), or chains 10+ deep.

**4. [Clustered] Cluster, quorum, and CSV health**
```powershell
Get-Cluster | Select-Object Name, QuorumType
Get-ClusterNode | Select-Object Name, State
Get-ClusterSharedVolume | Select-Object Name, State, Node
Get-ClusterResource | Where-Object { $_.ResourceType -eq "Virtual Machine" } | Select-Object Name, State, OwnerNode
```
Good: all nodes `Up`, all CSVs `Online`, all VM resources `Online` on an expected owner. Bad: any node not `Up` while VMs are still expected to be highly available — confirm the cluster can still tolerate the current failure count against its quorum model.

**5. Virtual switch consistency (pre-migration check)**
```powershell
Get-VMSwitch -ComputerName <host1>, <host2> | Select-Object PSComputerName, Name, SwitchType
Compare-VM -Name <vm-name> -DestinationHost <target-host>
```
Good: identical switch names and types across all hosts; `Compare-VM` returns no incompatibilities. Bad: any naming or type mismatch — this WILL fail Live Migration at the point the VM's switch dependency is evaluated.

**6. Live Migration network and auth readiness**
```powershell
netstat -ano | findstr /I "6600"
Get-VMHost | Select-Object VirtualMachineMigrationAuthenticationType, VirtualMachineMigrationEnabled
```
Good: port 6600 listening, migration enabled, authentication type matches what's actually configured (Kerberos delegation done in AD, or CredSSP with an interactive session).

**7. Hyper-V Replica health (if configured)**
```powershell
Get-VMReplication | Select-Object VMName, State, Health, FrequencySec
Measure-VMReplication -VMName <vm-name>
```
Good: `State: Replicating`, `Health: Normal`, pending changes within expected size for the configured replication frequency. Bad: `Health: Critical` or a pending-change size that's clearly outgrown the configured RPO window.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Scope the fault: one VM, one host, or cluster-wide?
1. If multiple unrelated VMs on a cluster fail simultaneously, check quorum FIRST (`Get-ClusterNode`, `Get-Cluster`) before investigating any individual VM — a quorum loss looks identical to "everything broke at once" from inside any single VM's perspective.
2. If it's genuinely one VM, confirm whether the host itself is healthy (other VMs on the same host unaffected) before assuming a host-wide cause.

### Phase 2 — Role, service, and resource health
1. `Get-Service VMMS` — if stopped, this blocks management operations host-wide (not running VMs themselves).
2. Check host CPU/memory/storage headroom — Layer 4 exhaustion produces failures that look VM-specific (a single VM won't start) but are actually host-wide capacity problems that happened to hit this VM first.

### Phase 3 — VM state and Integration Services
1. `Get-VM` — confirm `State` and `Status` together, not just one.
2. If `Status` is degraded, check Integration Services on both host and guest side — remember the asymmetric enforcement (host state governs, guest can't override it).
3. Confirm guest-side Integration Services version currency if any specific feature (VSS backup, file copy) is misbehaving despite Heartbeat being healthy — different Integration Services can be independently stale.

### Phase 4 — Checkpoint/disk isolation (if relevant)
1. `Get-VMSnapshot` vs. actual files on disk — identify orphans before attempting any merge.
2. Confirm sufficient free space exists (rule of thumb: space equal to the disk size) before attempting a merge — a merge that runs out of space mid-operation is a worse state than the orphan it started from.
3. For clustered VMs, confirm CSV health independently before assuming a checkpoint-specific storage fault — a struggling CSV manifests identically to slow/failing checkpoint operations.

### Phase 5 — Live Migration isolation (if migration is the symptom)
1. `Compare-VM` first, always — it's non-disruptive and surfaces the specific incompatibility class (switch/processor/version) in one call.
2. Only after `Compare-VM` passes clean, move to network/auth diagnosis (port 6600/3343 reachability, Kerberos delegation vs. CredSSP mismatch).
3. For cluster-resource-ownership errors specifically (`0x80071398`), check possible-owner lists — this is a config-drift issue (node added after VM resource creation), not a live infrastructure fault.

### Phase 6 — Cluster/CSV isolation (if clustered)
1. Confirm quorum state before CSV-specific diagnosis — a quorum-adjacent issue can produce CSV symptoms that look storage-specific.
2. For Event ID 5120, distinguish the benign `STATUS_CLUSTER_CSV_AUTO_PAUSE_ERROR`-only pattern from genuine interruption codes before escalating as an emergency.
3. Check storage/network driver and firmware currency — the overwhelming majority of genuine (non-benign) 5120 status codes trace back to outdated drivers/firmware rather than a Hyper-V-layer misconfiguration.

### Phase 7 — Hyper-V Replica isolation (if DR replication is the symptom)
1. Confirm this is a Replica-specific issue and not a downstream symptom of a Layer 1-4 fault on the primary (Replica depends on everything below it working first).
2. Check HRL file growth on the primary as the leading indicator of a replication that's silently falling behind rather than obviously failed.
3. Distinguish network/auth failures (`Health: Critical`, connection errors) from a legitimate need for full resynchronization (`Resynchronization Required`, typically after an extended outage) — these have different remediation paths (Fix/reconnect vs. accept a full-baseline resync).

---

## Remediation Playbooks

<details><summary>Playbook 1 — Recover from a broken/orphaned checkpoint chain</summary>

**Scenario:** Checkpoints visible in Hyper-V Manager won't merge, or `.avhdx` files exist on disk with no corresponding checkpoint entry (most often left by backup software that failed to clean up).

```powershell
# ALWAYS back up the VM folder before manual chain surgery
$vmPath = (Get-VM -Name <vm-name>).ConfigurationLocation
Copy-Item -Path $vmPath -Destination "$vmPath-backup-$(Get-Date -Format yyyyMMdd)" -Recurse

Stop-VM -Name <vm-name>

# Attempt standard removal first — triggers merge if the chain is intact enough
Get-VM -Name <vm-name> | Get-VMSnapshot | Remove-VMSnapshot

# For orphans not visible to Get-VMSnapshot, inspect the chain directly
Get-VMHardDiskDrive -VMName <vm-name> | ForEach-Object {
    Get-VHD -Path $_.Path | Select-Object Path, ParentPath, VhdType
}

# Merge the orphan into its actual parent (confirm direction from ParentPath output above)
Merge-VHD -Path "<orphan.avhdx>" -DestinationPath "<correct-parent.vhdx>"

# Point the VM's hard disk drive back at the merged, single vhdx if needed
Set-VMHardDiskDrive -VMName <vm-name> -Path "<merged.vhdx>"

Start-VM -Name <vm-name>
```
**Rollback:** restore from the pre-operation folder backup taken in step 1 if the merge produces a non-booting or corrupted disk — this is the only reliable rollback path since `Merge-VHD` operations are not themselves reversible.
</details>

<details><summary>Playbook 2 — Diagnose and fix a Live Migration failure end-to-end</summary>

**Scenario:** Live Migration fails with Event ID 21502 and an unclear root cause.

```powershell
# Step 1 — non-disruptive compatibility check, always first
Compare-VM -Name <vm-name> -DestinationHost <target-host>

# Step 2 — if switch-related, confirm exact name match (case and whitespace both matter)
Get-VMSwitch -ComputerName <source-host> | Select-Object Name
Get-VMSwitch -ComputerName <target-host> | Select-Object Name

# Step 3 — if processor-related, enable compatibility mode (accepts a feature-set floor)
Set-VMProcessor -VMName <vm-name> -CompatibilityForMigrationEnabled $true

# Step 4 — if cluster-resource-ownership related (0x80071398), fix possible-owners
Get-ClusterResource -Name "Virtual Machine <vm-name>" | Get-ClusterOwnerNode
(Get-ClusterResource -Name "Virtual Machine <vm-name>").SetOwnerNode(@("<node1>","<node2>","<node3>"))

# Step 5 — if Kerberos-auth related, confirm delegation on both host computer accounts
# (Active Directory Users and Computers > host computer object > Delegation tab >
#  "Trust this computer for delegation to specified services only" > cifs + Microsoft
#  Virtual System Migration Service, targeting the OTHER host's computer account)

# Step 6 — retry
Move-VM -Name <vm-name> -DestinationHost <target-host> -IncludeStorage:$false
```
**Rollback:** processor compatibility mode (`-CompatibilityForMigrationEnabled $false`) can be reverted once cross-generation migration is no longer needed; possible-owner-node changes are configuration-only and safely reversible via `SetOwnerNode` with the prior node list.
</details>

<details><summary>Playbook 3 — Recover a cluster from quorum loss</summary>

**Scenario:** Multiple clustered VMs went offline simultaneously; `Get-ClusterNode` shows one or more nodes down and the cluster itself is non-functional.

```powershell
# Confirm the actual quorum model and current node/witness state
Get-Cluster | Select-Object Name, QuorumType
Get-ClusterNode | Select-Object Name, State
Get-ClusterQuorum

# If enough nodes are genuinely healthy and reachable but the cluster still won't
# form quorum (e.g., witness itself failed), force quorum as a LAST RESORT —
# this is destructive if used incorrectly (can cause a true split-brain)
Start-ClusterNode -FixQuorum

# Once the cluster is healthy again, always disable forced-quorum mode
Stop-ClusterNode -FixQuorum
Start-ClusterNode
```
**Rollback:** `Start-ClusterNode -FixQuorum` deliberately bypasses the cluster's own split-brain protection — only use it when you have independently confirmed the other nodes are genuinely down (not just unreachable from this node's perspective), and always follow up with a clean node restart once quorum is naturally restored.
</details>

<details><summary>Playbook 4 — Recover Hyper-V Replica after an extended outage</summary>

**Scenario:** Replication health shows `Resynchronization Required` after the replica target was unreachable for an extended period, or the primary's HRL file has grown large enough to threaten disk space.

```powershell
# Confirm current health and pending change volume
Get-VMReplication -VMName <vm-name> | Select-Object State, Health
Measure-VMReplication -VMName <vm-name>

# Check HRL file size directly if disk space is a concern
Get-ChildItem -Path (Get-VM -Name <vm-name>).ConfigurationLocation -Filter "*.hrl" |
  Select-Object Name, @{N="SizeGB";E={[math]::Round($_.Length/1GB,2)}}

# Attempt a standard resume first (cheaper than a full resync)
Resume-VMReplication -VMName <vm-name>

# If health explicitly requires resynchronization, this transfers a full new
# baseline — expect significant network/storage load, schedule accordingly
Start-VMResynchronization -VMName <vm-name>

# Verify recovery
Get-VMReplication -VMName <vm-name> | Select-Object State, Health
```
**Rollback:** N/A — resuming or resynchronizing replication doesn't affect the running primary VM. If the replica relationship needs to be abandoned entirely rather than repaired, `Remove-VMReplication -VMName <vm-name>` cleanly tears it down without touching the primary.
</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Hyper-V host/VM diagnostic evidence for escalation.
.NOTES
    Run on the Hyper-V host itself with local Administrator rights.
    Cluster-specific sections auto-skip on a standalone host.
#>
$out = "C:\HyperV-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

Get-WindowsFeature Hyper-V | Out-File "$out\feature-state.txt"
Get-Service VMMS | Out-File "$out\vmms-service.txt"
Get-VM | Select-Object Name, State, Status, Version, Uptime | Export-Csv "$out\vms.csv" -NoTypeInformation
Get-VM | Get-VMIntegrationService | Export-Csv "$out\integration-services.csv" -NoTypeInformation
Get-VM | Get-VMSnapshot | Select-Object VMName, Name, CreationTime, SnapshotType | Export-Csv "$out\checkpoints.csv" -NoTypeInformation
Get-VMSwitch | Export-Csv "$out\vswitches.csv" -NoTypeInformation
Get-VMHost | Select-Object VirtualMachineMigrationEnabled, VirtualMachineMigrationAuthenticationType, VirtualMachineMigrationPerformanceOption |
  Out-File "$out\migration-config.txt"

if (Get-Command Get-Cluster -ErrorAction SilentlyContinue) {
    Get-Cluster | Out-File "$out\cluster.txt"
    Get-ClusterNode | Export-Csv "$out\cluster-nodes.csv" -NoTypeInformation
    Get-ClusterSharedVolume | Export-Csv "$out\csv-state.csv" -NoTypeInformation
    Get-ClusterResource | Where-Object { $_.ResourceType -eq "Virtual Machine" } |
      Export-Csv "$out\cluster-vm-resources.csv" -NoTypeInformation
    Get-ClusterLog -UseLocalTime -Destination $out
}

Get-VMReplication -ErrorAction SilentlyContinue | Export-Csv "$out\replication.csv" -NoTypeInformation

Get-WinEvent -LogName "Microsoft-Windows-Hyper-V-VMMS-Admin" -MaxEvents 100 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\vmms-events.csv" -NoTypeInformation
Get-WinEvent -LogName "Microsoft-Windows-Hyper-V-Worker-Admin" -MaxEvents 100 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\worker-events.csv" -NoTypeInformation
Get-WinEvent -LogName System -FilterXPath "*[System[(EventID=5120)]]" -MaxEvents 50 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, Message | Export-Csv "$out\csv-5120-events.csv" -NoTypeInformation

Write-Host "Evidence collected to $out"
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip"
```

---

## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-VM` / `Get-VMIntegrationService` | VM state/status; Integration Services health |
| `Get-VMSnapshot` / `Remove-VMSnapshot` / `Merge-VHD` | Checkpoint inventory, removal, manual merge |
| `Get-VHD` | Differencing disk chain inspection (`ParentPath`) |
| `Compare-VM -DestinationHost` | Non-disruptive Live Migration compatibility check |
| `Move-VM` | Perform Live Migration (with or without storage) |
| `Set-VMProcessor -CompatibilityForMigrationEnabled` | Cross-generation CPU migration compatibility mode |
| `Get-VMSwitch` | Virtual switch inventory (name/type consistency check) |
| `Get-Cluster` / `Get-ClusterQuorum` | Cluster identity and quorum model |
| `Get-ClusterNode` / `Get-ClusterSharedVolume` | Node and CSV health |
| `Get-ClusterResource \| Get-ClusterOwnerNode` | Cluster resource possible-owner inspection |
| `Start-ClusterNode -FixQuorum` | Force quorum (last resort, split-brain risk) |
| `Get-VMReplication` / `Measure-VMReplication` | Hyper-V Replica health and pending change volume |
| `Resume-VMReplication` / `Start-VMResynchronization` | Recover a paused/behind replica relationship |
| `Update-VMVersion` / `Get-VMHostSupportedVersion` | VM configuration version management (one-way upgrade) |
| `Get-ClusterLog -UseLocalTime -Destination` | Full cluster log export for escalation |

---

## 🎓 Learning Pointers

- **VMMS (host-wide) and `vmwp.exe` (one per VM) are independent processes — restarting VMMS does not stop running VMs.** This is the key fact that lets you safely recover a hung management layer without touching production workloads, and it's the reason "one stuck VM" and "host-wide management failure" require completely different triage paths. [MS Docs: high-availability VM troubleshooting guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/high-availability-virtual-machine-troubleshooting-guidance).
- **Integration Services enforcement is asymmetric by design** — the host state governs, and Hyper-V will silently correct a guest-side service back into compliance with the host's Enabled/Disabled setting rather than the other way around. Engineers coming from a pure Windows-services mental model often fight this instead of just fixing it at the host.
- **`Compare-VM` is a free, non-disruptive dry-run of everything Hyper-V checks before a real Live Migration** — running it first turns "Event ID 21502, unclear cause" into a specific, actionable incompatibility in one call, every time. [MS Docs: troubleshoot live migration issues](https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/troubleshoot-live-migration-issues).
- **A single `Event ID 5120` with `STATUS_CLUSTER_CSV_AUTO_PAUSE_ERROR` is documented, known noise — but any other status code in the same event ID is a genuine signal.** Building alert rules that distinguish these two cases (rather than paging on every 5120) is one of the highest-value pieces of monitoring hygiene for a Hyper-V cluster.
- **Checkpoints and Hyper-V Replica solve different problems and are frequently confused** — checkpoints are point-in-time, same-storage, and not a retention strategy; Replica is continuous, cross-site, and specifically built for DR. A VM can (and often should) use both simultaneously without conflict, but treating checkpoints as a substitute for Replica (or a backup product) is a common and costly misunderstanding.
- **LBFO NIC Teaming is deprecated in favor of Switch Embedded Teaming (SET)** — flag any new Hyper-V host build still defaulting to LBFO as a modernization item, not just a style preference, since some newer capabilities (RDMA passthrough to VMs) require SET specifically. [MS Docs: SET / host network requirements](https://learn.microsoft.com/en-us/azure/azure-local/concepts/host-network-requirements#switch-embedded-teaming-set).
