# Storage Spaces Direct (S2D) — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

- **Applies to:** Windows Server 2016 through 2025, and Azure Local (formerly Azure Stack HCI), running Storage Spaces Direct as the hyperconverged storage layer under a Failover Cluster. Covers 2-node through 16-node deployments.
- **Covers:** storage pool/virtual disk/physical disk architecture and health states, cache-tier vs. capacity-tier design, resiliency types (Two-way/Three-way Mirror, Parity, Nested Resiliency for 2-node clusters), the Health Service and automatic repair, drive replacement workflow, and storage-network (RDMA) dependencies.
- **Does not cover:** the Failover Clustering/CSV/quorum layer above S2D in general (a clustered VM's own state, Live Migration, Hyper-V Replica — see `HyperV-A.md`, which treats S2D as its storage dependency); standalone (non-Direct) Storage Spaces on shared SAS JBODs (a materially different, older architecture); Azure Local's cloud-management-plane specifics (Arc registration, cloud billing) — this runbook covers the on-prem storage engine that underlies both.
- **Admin roles needed:** local Administrators on each cluster node; cluster-level operations effectively require membership in the cluster's own access control (typically domain accounts, not a separate AD group by default) — the same model documented in `HyperV-A.md`.

---
## How It Works

<details><summary>Full architecture</summary>

Storage Spaces Direct pools the local, direct-attached drives (NVMe, SSD, HDD) inside every node of a Failover Cluster into a single software-defined storage fabric — no shared SAS JBOD or external SAN required. It is not a standalone feature: it runs strictly on top of a healthy Windows Failover Cluster, and `Enable-ClusterStorageSpacesDirect` is what turns a plain cluster's local drives into one clustered storage pool (conventionally named `S2D on <cluster-name>`).

**Object model** (bottom to top): physical disks are added to a storage pool; virtual disks (Storage Spaces) are carved from the pool's free space with a chosen resiliency type; volumes are formatted on top of virtual disks; and on a clustered S2D deployment, those volumes are exposed cluster-wide as Cluster Shared Volumes (CSV) — the same CSV mechanism `HyperV-A.md` documents as what makes Live Migration of VM storage possible without a separate migration step.

**Cache tier vs. capacity tier.** In hybrid deployments (mixing fast and slow media), S2D automatically designates the fastest drive type present as a *cache* tier and the rest as the *capacity* tier — the cache absorbs both reads and writes to accelerate the slower capacity media underneath it. An all-flash deployment (all NVMe, or all SSD) may run with no cache tier at all, or use a faster NVMe cache in front of SSD capacity purely for endurance/wear-leveling reasons rather than raw speed. A failed or missing cache device degrades write performance for every capacity drive it was accelerating on that node, not just its own capacity — this is a frequent source of "the whole node got slow" reports that don't initially look like a storage-health issue at all.

**Resiliency types.** *Two-way mirror* keeps two copies of data (tolerates one drive or one node failure, 2x storage overhead); *three-way mirror* keeps three copies (tolerates two failures, 3x overhead, the default and recommended type for most production deployments); *Parity* (erasure coding) trades more compute for better storage efficiency, generally suited to capacity-optimized, less-performance-sensitive workloads on larger clusters; *Nested Resiliency* is a 2-node-cluster-specific mechanism that layers mirroring/parity within each node's own drive set on top of mirroring between the two nodes, so the cluster can survive a whole-node failure AND a drive failure on the surviving node simultaneously — something a plain two-way mirror across only two nodes cannot do.

**The Health Service** is the background component (part of Failover Clustering, running per-node) that continuously evaluates pool, virtual disk, and physical disk state, and — critically for day-to-day operations — **automatically starts a repair job the moment a failed drive is replaced or a temporarily-missing drive/node reconnects.** This is the single most important operational difference from standalone (non-Direct) Storage Spaces, where `Repair-VirtualDisk` must be run manually: on S2D, manually invoking `Repair-VirtualDisk` is rarely necessary and can be redundant with — or interfere with — a repair the Health Service has already started.

**Storage networking.** S2D nodes replicate writes to each other in real time over the cluster's storage network, using SMB3 as the transport (specifically SMB Direct, using RDMA, and SMB Multichannel for path redundancy/load balancing). RDMA (RoCE or iWARP) is strongly recommended and, on larger or performance-sensitive deployments, effectively required — a degraded or disconnected storage NIC on a single node does not present as a network alert; it presents as that node's drives going `Lost Communication`, which is why storage-network health must be checked as a first-class diagnostic step, not an afterthought.

**Quorum, at the pool level, is distinct from cluster quorum.** A storage pool has its own quorum concept: it needs a majority of the drives that host pool metadata to be reachable, or the entire pool goes read-only (`ReadOnlyReason: Incomplete`) as a data-integrity safety measure — independent of whether the underlying Failover Cluster itself still has quorum. A cluster can have quorum while its storage pool does not (e.g., enough nodes are up to run the cluster, but not enough drives are reachable to satisfy pool quorum), and vice versa.

</details>

---
## Dependency Stack

```
Layer 5 — Workload (VM/CSV consumer, e.g. Hyper-V — see HyperV-A.md)
              reads/writes through Cluster Shared Volumes
Layer 4 — Cluster Shared Volumes (CSV)
              formatted volumes exposed cluster-wide on top of virtual disks
Layer 3 — Virtual Disks (Storage Spaces)
              resiliency type (mirror/parity/nested) applied across pooled drives;
              HealthStatus/OperationalStatus/DetachedReason live here
Layer 2 — Storage Pool ("S2D on <cluster>")
              pool-level quorum (majority of metadata-hosting drives reachable);
              HealthStatus/OperationalStatus/ReadOnlyReason live here
Layer 1 — Physical Disks (per node) — cache tier + capacity tier
              CanPool/CannotPoolReason, HealthStatus, OperationalStatus, Usage
Layer 0 — Foundation:
              ├── Failover Cluster formed and healthy (Get-ClusterNode, cluster quorum)
              ├── Enable-ClusterStorageSpacesDirect has been run
              └── Storage network (RDMA/RoCE or iWARP, SMB Direct + Multichannel)
                    between every node — the most commonly overlooked dependency
```

A fault at Layer 0 (cluster or storage network) presents as widespread, seemingly-unrelated drive/virtual-disk degradation across one or more entire nodes — always rule this out before working through individual drives. A fault at Layer 1 (a single physical disk) is narrow and self-contained, and on S2D the Health Service handles recovery automatically once the drive is replaced or reconnected.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Entire storage pool `Warning`/`Degraded` | One or more metadata-hosting drives failed/missing | `Get-StoragePool -IsPrimordial $False` |
| Pool `Unknown`/`Unhealthy`, `ReadOnlyReason: Incomplete` | Pool lost quorum — majority of drives unreachable | `Get-StoragePool ... \| Select ReadOnlyReason` |
| Pool `ReadOnlyReason: Policy` | An administrator deliberately set the pool read-only | Confirm with team before reverting |
| Virtual disk `OperationalStatus: In service` | Normal — active repair/rebalance in progress | `Get-StorageJob` for progress |
| Virtual disk `OperationalStatus: Incomplete` | Reduced resilience, but all remaining copies are up to date | `Get-VirtualDisk`, then `Get-ClusterNode`/reconnect drives |
| Virtual disk `OperationalStatus: Degraded` | Reduced resilience AND some remaining copies are stale | Same as above — repair required after reconnect |
| Virtual disk `HealthStatus: Unhealthy`, `No redundancy` | More drives failed than the resiliency type tolerates — data loss | Restore from backup; this is not self-recoverable |
| Virtual disk `Detached`, reason `By Policy` | Admin took it offline, or set to manual-attach | `Connect-VirtualDisk` |
| Virtual disk `Detached`, reason `Majority Disks Unhealthy`/`Incomplete` | Too many drives down to even read the disk | Reconnect drives/nodes; may require restore |
| One drive `Lost communication` | Usually the owning node is down, not the drive itself | `Get-ClusterNode` first |
| Whole node's drives `Lost communication` together | Storage network (RDMA) link down on that node | `Get-ClusterNetwork`, `Get-NetAdapterRdma` |
| Drive `HealthStatus: Unhealthy`, `Failed media`/`Device hardware failure` | Genuine physical drive failure | Replace drive |
| Drive `Split` | Drive physically separated from the pool without proper removal | `Reset-PhysicalDisk` then `Repair-VirtualDisk` if needed |
| New/replacement drive won't pool, `CannotPoolReason` set | Leftover pool membership, partitions, or non-compliant firmware | `Get-PhysicalDisk \| Format-Table ... CannotPoolReason` |
| Whole node reports abnormally slow storage, no drive shows Unhealthy | Cache-tier device degraded/failed on that node | `Get-PhysicalDisk \| Where Usage -eq "Journal"` (cache role) |
| `Get-StorageJob` shows a repair stalled at a fixed percentage | Storage-network fault interrupting inter-node replication traffic | `Get-ClusterNetwork`, `Get-NetAdapterRdma`, RDMA error counters |
| Cluster itself healthy, but S2D storage totally inaccessible | `Enable-ClusterStorageSpacesDirect` was never run, or S2D was disabled | `Get-ClusterS2D` |

---
## Validation Steps

**1. Confirm S2D is enabled on the cluster**
```powershell
Get-ClusterS2D
```
Good: `State: Enabled`. Bad: `Disabled` or the cmdlet errors — nothing below applies until S2D is actually enabled.

**2. Confirm storage pool health and quorum**
```powershell
Get-StoragePool -IsPrimordial $False | Select-Object FriendlyName, HealthStatus, OperationalStatus, ReadOnlyReason
```
Good: `Healthy`/`OK`, `ReadOnlyReason` blank. Bad: any `ReadOnlyReason` populated — the pool cannot accept writes until resolved.

**3. Confirm virtual disk health across all volumes**
```powershell
Get-VirtualDisk | Select-Object FriendlyName, HealthStatus, OperationalStatus, DetachedReason, ResiliencySettingName
```
Good: `Healthy`/`OK` (or `Suboptimal`, a rebalance opportunity — see `Optimize-StoragePool`). Bad: `Warning`/`Unhealthy`/`Detached`.

**4. Confirm physical disk health per node, including cache-tier drives**
```powershell
Get-PhysicalDisk | Select-Object FriendlyName, MediaType, Usage, HealthStatus, OperationalStatus, PhysicalLocation
```
Good: every drive `Healthy`/`OK`. Bad: any `Unhealthy`, or a `Usage: Journal`/`Cache` drive in a degraded state (impacts the whole node's write path, not just its own capacity).

**5. Confirm no repair job is silently stalled**
```powershell
Get-StorageJob | Select-Object Name, JobState, PercentComplete, ElapsedTime
```
Good: no jobs (steady state) or `PercentComplete` advancing on repeated checks. Bad: a job static across multiple checks — investigate the storage network next.

**6. Confirm storage-network (RDMA) health**
```powershell
Get-ClusterNetwork | Select-Object Name, State, Role
Get-NetAdapterRdma | Select-Object Name, Enabled, InterfaceDescription
Get-SmbMultichannelConnection | Select-Object ServerName, ClientRdmaCapable, ClientRssCapable
```
Good: storage network(s) `Up`, RDMA adapters `Enabled: True`, active connections show `ClientRdmaCapable: True` where hardware supports it. Bad: a storage network `Down`/`Partitioned`, or RDMA disabled on one node's adapter while its peers show it enabled.

**7. Confirm the Health Service itself is reporting**
```powershell
Get-StorageSubSystem -FriendlyName "Clustered Windows Storage on *" | Debug-StorageSubSystem
```
Good: returns without errors, no unexpected `FaultingObjectUniqueId` entries. Bad: errors here mean the Health Service's own reporting is impaired — treat cluster/CSV service health as suspect and cross-check via `Get-ClusterLog`.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Scope the fault: single drive, single node, or fabric-wide?
1. Run `Get-PhysicalDisk | Where-Object { $_.OperationalStatus -ne "OK" }` and group by node (`PhysicalLocation`/owning node) before touching anything.
2. If drives across multiple nodes are affected simultaneously, check `Get-ClusterNode` and `Get-ClusterNetwork` FIRST — this shape almost always means a cluster or storage-network event, not N coincidental drive failures.
3. If only one drive on one node is affected, this is a routine, self-contained drive-replacement case (Playbook 1).

### Phase 2 — Confirm pool-level quorum before assuming individual disk faults
4. `Get-StoragePool -IsPrimordial $False | Select ReadOnlyReason` — a populated reason changes the whole investigation: the pool itself, not any single disk, is the blocking factor.
5. Cross-check whether *cluster* quorum (Failover Clustering) is also affected (`Get-ClusterQuorum`) — pool quorum and cluster quorum are independent and a fault in one does not imply a fault in the other.

### Phase 3 — Validate the storage network before touching drives
6. A degraded RDMA path is the single most common S2D root cause that gets mis-diagnosed as hardware failure, because its symptom (drives "Lost Communication" on one node) looks identical to a batch of dead drives. Confirm `Get-ClusterNetwork`/`Get-NetAdapterRdma` health before any drive-level remediation.

### Phase 4 — Let automatic repair run before manual intervention
7. Once physical faults are ruled out or resolved (drives/nodes reconnected, failed drives replaced), check `Get-StorageJob` — the Health Service starts repair automatically. Manual `Repair-VirtualDisk` is a fallback for the rare case repair does not auto-start, not a routine first step.

### Phase 5 — Escalate data-loss-risk scenarios distinctly from routine repairs
8. `No redundancy` (virtual disk) or a pool that cannot regain quorum despite all reachable drives/nodes being healthy indicates data has already been lost or is at active risk — this is a restore-from-backup and root-cause-review situation, not a repair-and-move-on situation. Flag it accordingly rather than treating it as another routine fix.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Routine drive replacement</summary>

**Scenario:** A single physical disk has failed (`HealthStatus: Unhealthy`, `Failed media` or `Device hardware failure`) and needs replacing — the most common S2D maintenance event.

```powershell
# 1. Confirm the failed drive and its physical location (bay/slot)
Get-PhysicalDisk | Where-Object { $_.HealthStatus -eq "Unhealthy" } |
  Select-Object FriendlyName, SerialNumber, PhysicalLocation, MediaType

# 2. Optionally place the drive in maintenance mode before physical removal
#    (prevents the Health Service from reacting to the removal as a surprise fault)
Get-PhysicalDisk -FriendlyName "<drive>" | Enable-StorageMaintenanceMode

# 3. Physically replace the drive

# 4. Confirm the new drive is visible and eligible to pool
Get-PhysicalDisk | Where-Object { $_.CanPool -eq $true } | Select-Object FriendlyName, CannotPoolReason

# 5. S2D normally auto-pools and auto-repairs. If it doesn't within a few minutes:
Add-PhysicalDisk -StoragePoolFriendlyName "S2D*" -PhysicalDisks (Get-PhysicalDisk -FriendlyName "<new-drive>")

# 6. Monitor repair to completion
Get-StorageJob | Select-Object Name, JobState, PercentComplete
```
**Rollback:** N/A — this is the intended, non-destructive maintenance path. If maintenance mode was enabled in step 2, always disable it after the drive is confirmed healthy: `Get-PhysicalDisk -FriendlyName "<drive>" | Disable-StorageMaintenanceMode`.
</details>

<details><summary>Playbook 2 — Recover a pool from lost quorum</summary>

**Scenario:** Multiple nodes or drives went offline together (planned maintenance gone wrong, network outage, power event) and the storage pool is now read-only with `ReadOnlyReason: Incomplete`.

```powershell
# 1. Establish exactly how many nodes/drives are actually down
Get-ClusterNode | Select-Object Name, State
Get-PhysicalDisk | Where-Object { $_.OperationalStatus -eq "Lost Communication" } |
  Group-Object -Property { (Get-ClusterNode).Name }

# 2. Bring nodes back online first — network/power/hardware root cause, not a storage command
Start-ClusterNode -Name <node-name>

# 3. Once enough drives are reachable again, set the pool back to read-write
Get-StoragePool -FriendlyName "S2D*" -IsPrimordial $False | Set-StoragePool -IsReadOnly $false

# 4. Confirm virtual disks resume repair automatically
Get-VirtualDisk | Select-Object FriendlyName, HealthStatus, OperationalStatus
Get-StorageJob | Select-Object Name, JobState, PercentComplete
```
**Rollback:** N/A — restoring nodes and reverting read-only state is the fix itself. If quorum cannot be restored because the missing nodes/drives are permanently gone, this is a genuine data-loss-risk event requiring restore from backup, not a configuration change to walk back.
</details>

<details><summary>Playbook 3 — Diagnose and resolve a stalled repair job (storage-network root cause)</summary>

**Scenario:** `Get-StorageJob` shows a repair stuck at the same `PercentComplete` across multiple checks, and no drive shows an obvious hardware fault.

```powershell
# 1. Confirm the job is genuinely stalled, not just large/slow
Get-StorageJob | Select-Object Name, JobState, PercentComplete, ElapsedTime

# 2. Check storage network health across every node — the most common cause
Get-ClusterNetwork | Select-Object Name, State, Role
Get-NetAdapterRdma | Select-Object Name, Enabled
Get-NetAdapterStatistics | Select-Object Name, ReceivedDiscardedPackets, OutboundDiscardedPackets

# 3. Check for RDMA-specific errors if hardware supports the counters
Get-Counter '\RDMA Activity(*)\RDMA Errors' -ErrorAction SilentlyContinue

# 4. If the storage network is confirmed healthy and the job is STILL stalled,
#    check whether the underlying drive itself has gone degraded mid-repair
Get-PhysicalDisk | Where-Object { $_.OperationalStatus -ne "OK" }

# 5. Once the root cause (network link, faulty NIC, failing drive) is corrected,
#    the Health Service resumes the job automatically — do not manually restart it
```
**Rollback:** N/A — this playbook is diagnostic; no destructive action is taken. Avoid forcibly stopping a storage job as a troubleshooting step — interrupting a repair against already-reduced redundancy increases risk rather than resolving the stall.
</details>

<details><summary>Playbook 4 — Onboard a replacement/expansion drive that won't pool</summary>

**Scenario:** A new or replacement drive shows `CanPool: False` with a populated `CannotPoolReason`.

```powershell
# 1. Identify the specific reason
Get-PhysicalDisk | Format-Table FriendlyName, MediaType, Size, CanPool, CannotPoolReason

# 2. Common cause: "In a Pool" — drive still references a previous pool's metadata
#    (e.g., redeployed from another cluster or a decommissioned node)
Reset-PhysicalDisk -FriendlyName "<drive>"

# 3. Common cause: "Insufficient Capacity" — leftover partitions consuming free space
Clear-Disk -Number <disk-number> -RemoveData -RemoveOEM -Confirm:$false

# 4. Re-check eligibility, then add to the pool
Get-PhysicalDisk -CanPool $True | Where-Object FriendlyName -eq "<drive>"
Add-PhysicalDisk -StoragePoolFriendlyName "S2D*" -PhysicalDisks (Get-PhysicalDisk -FriendlyName "<drive>")
```
**Rollback:** N/A by design — `Reset-PhysicalDisk` and `Clear-Disk -RemoveData` are intentionally destructive to whatever was previously on the drive, appropriate only for a drive being freshly onboarded. Never run either against a drive suspected of holding the last good copy of data still needed for recovery.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Storage Spaces Direct diagnostic evidence for escalation.
.NOTES
    Run on any cluster node with local Administrator rights.
    Non-S2D or non-clustered hosts will show empty/errored sections — expected.
#>
$out = "C:\S2D-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

Get-ClusterS2D | Out-File "$out\s2d-state.txt"
Get-StoragePool -IsPrimordial $False | Select-Object FriendlyName, HealthStatus, OperationalStatus, ReadOnlyReason |
  Export-Csv "$out\storage-pools.csv" -NoTypeInformation
Get-VirtualDisk | Select-Object FriendlyName, HealthStatus, OperationalStatus, DetachedReason, ResiliencySettingName |
  Export-Csv "$out\virtual-disks.csv" -NoTypeInformation
Get-PhysicalDisk | Select-Object FriendlyName, SerialNumber, MediaType, Usage, HealthStatus, OperationalStatus, PhysicalLocation, CanPool, CannotPoolReason |
  Export-Csv "$out\physical-disks.csv" -NoTypeInformation
Get-StorageJob | Select-Object Name, JobState, PercentComplete, ElapsedTime | Export-Csv "$out\storage-jobs.csv" -NoTypeInformation

Get-ClusterNode | Export-Csv "$out\cluster-nodes.csv" -NoTypeInformation
Get-ClusterNetwork | Export-Csv "$out\cluster-networks.csv" -NoTypeInformation
Get-NetAdapterRdma | Export-Csv "$out\rdma-adapters.csv" -NoTypeInformation
Get-SmbMultichannelConnection | Export-Csv "$out\smb-multichannel.csv" -NoTypeInformation

Get-WinEvent -LogName "Microsoft-Windows-StorageSpaces-Driver/Operational" -MaxEvents 100 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\storagespaces-events.csv" -NoTypeInformation
Get-ClusterLog -UseLocalTime -Destination $out -ErrorAction SilentlyContinue

Write-Host "Evidence collected to $out"
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip"
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-ClusterS2D` | Confirm S2D is enabled on the cluster |
| `Get-StoragePool -IsPrimordial $False` | Pool health/operational status/read-only reason |
| `Set-StoragePool -IsReadOnly $false` | Restore a pool to read-write after quorum is regained |
| `Get-VirtualDisk` | Virtual disk health/operational status/detached reason |
| `Connect-VirtualDisk` | Reattach a virtual disk detached "By Policy" |
| `Repair-VirtualDisk` | Manual repair trigger (rarely needed on S2D — Health Service auto-repairs) |
| `Get-PhysicalDisk` | Per-drive health, usage role (cache/capacity), pooling eligibility |
| `Get-PhysicalDisk ... CannotPoolReason` | Diagnose why a drive won't join the pool |
| `Add-PhysicalDisk` | Manually add an eligible drive to the pool |
| `Reset-PhysicalDisk` | Wipe a drive clean for re-pooling (destructive by design) |
| `Enable-/Disable-StorageMaintenanceMode` | Take a drive offline for planned replacement without a fault event |
| `Get-StorageJob` | Monitor active repair/rebalance jobs |
| `Optimize-StoragePool` | Rebalance data evenly across drives (`Suboptimal` state) |
| `Debug-StorageSubSystem` | Health Service diagnostic pass on the clustered storage subsystem |
| `Get-ClusterNetwork` / `Get-NetAdapterRdma` | Storage-network and RDMA adapter health |
| `Get-SmbMultichannelConnection` | Confirm SMB Direct/Multichannel is actually using RDMA paths |
| `Get-ClusterLog -UseLocalTime -Destination` | Full cluster log export for escalation |

---
## 🎓 Learning Pointers

- **The Health Service automating repair is the single biggest operational difference between S2D and standalone Storage Spaces.** Engineers with standalone Storage Spaces experience instinctively reach for `Repair-VirtualDisk` first; on S2D that instinct is usually unnecessary and occasionally counterproductive. See [Storage Spaces and Storage Spaces Direct health and operational states](https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/storage-spaces-states).
- **Pool quorum and cluster quorum are two independent concepts that happen to share the word "quorum."** A cluster can be fully quorate while its storage pool is read-only, or vice versa — always check both (`Get-ClusterQuorum` and `Get-StoragePool ... ReadOnlyReason`) rather than assuming one implies the other. This is the same "looks like one gate, is actually several independently-gated things" shape documented elsewhere in this knowledge base (e.g. `Security/Sentinel/SentinelGraph-A.md`'s three-permission-system finding) — here it's two independent quorum mechanisms layered on the same physical cluster.
- **A degraded storage-network (RDMA) link on one node is functionally indistinguishable, from the drive-status output alone, from a batch of simultaneous drive failures on that node.** Always check `Get-ClusterNetwork`/`Get-NetAdapterRdma` before working through individual physical disks when a whole node's drives report `Lost Communication` together.
- **The cache tier accelerates every capacity drive it fronts, not just its own capacity** — a single degraded cache device can make an entire node's storage feel slow without any drive showing `Unhealthy`. Treat unexplained node-wide performance complaints as a cache-tier candidate, not just a workload-side issue.
- **`Reset-PhysicalDisk` and `Clear-Disk -RemoveData` are intentionally, irreversibly destructive** — they exist specifically to onboard a drive cleanly, and running either against a drive that still holds the only up-to-date copy of data (rather than a confirmed-replaceable one) is how a routine drive swap turns into a real data-loss incident.
- **For the Failover Clustering/CSV/quorum layer immediately above S2D**, and for how a clustered Hyper-V workload actually consumes these CSVs, see `HyperV-A.md` — this runbook deliberately stops at the storage-fabric boundary rather than duplicating that content.
