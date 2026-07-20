# Storage Spaces Direct (S2D) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---
## Triage

**This runbook covers the Storage Spaces Direct (S2D) hyperconverged storage layer itself** — storage pool, virtual disks, physical disks, and repair jobs on a Failover Clustering-backed cluster. For the Failover Clustering/CSV/quorum mechanics that sit above S2D once storage is healthy, see `HyperV-B.md`/`HyperV-A.md` (S2D is the storage foundation those runbooks treat as a dependency, not a topic in its own right).

```powershell
# 1. Storage pool health (S2D auto-creates one pool per cluster, named "S2D on <cluster>")
Get-StoragePool -IsPrimordial $False | Select-Object FriendlyName, HealthStatus, OperationalStatus, ReadOnlyReason

# 2. Virtual disk health — the layer volumes sit on top of
Get-VirtualDisk | Select-Object FriendlyName, HealthStatus, OperationalStatus, DetachedReason

# 3. Physical disk health — every drive across every node
Get-PhysicalDisk | Select-Object FriendlyName, MediaType, Size, HealthStatus, OperationalStatus, Usage

# 4. Any repair/rebuild jobs currently running
Get-StorageJob | Select-Object Name, JobState, PercentComplete, ElapsedTime

# 5. Cluster node and network health (S2D storage traffic depends on cluster networking, usually RDMA)
Get-ClusterNode | Select-Object Name, State
Get-ClusterNetwork | Select-Object Name, State, Role
```

| Finding | Interpretation | Do this |
|---|---|---|
| Pool `HealthStatus: Warning`, `OperationalStatus: Degraded` | One or more drives failed/missing (metadata-hosting drives only) | **Fix 1** |
| Pool `HealthStatus: Unknown`/`Unhealthy`, `ReadOnlyReason: Incomplete` | Pool lost quorum — majority of drives unreachable | **Fix 2** |
| Virtual disk `OperationalStatus: Incomplete` or `Degraded` | Reduced resilience — drive(s) failed/missing, repair may already be running | **Fix 3** |
| Virtual disk `OperationalStatus: Detached`, reason `Majority Disks Unhealthy` or `Incomplete` | Too many drives down to read the virtual disk | **Fix 3** |
| Physical disk `OperationalStatus: Lost communication` | Drive unreachable — usually a down node, not a dead drive | **Fix 4** |
| Physical disk `HealthStatus: Unhealthy`, reason `Failed media`/`Device hardware failure` | Genuine drive failure | **Fix 5** |
| `Get-StorageJob` shows a repair stuck at the same `PercentComplete` for a long time | Repair stalled — usually storage-traffic network fault, not the drive itself | **Fix 6** |
| `CannotPoolReason` on a replacement drive isn't blank | Drive not eligible for pooling yet (needs reset, still shows old metadata, etc.) | **Fix 7** |
| Multiple unrelated virtual disks degrade at once, one whole node's drives show `Lost communication` | Cluster node down or storage-network (RDMA) link down, not per-drive failures | **Fix 8** |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Failover Clustering feature installed and cluster formed (S2D is NOT a standalone
storage feature — it runs only on top of a healthy Windows Failover Cluster)
    │
Cluster networking healthy — dedicated, high-bandwidth, low-latency storage network
  between nodes (RDMA/RoCE or iWARP strongly recommended; SMB Direct + SMB
  Multichannel move storage replication traffic between nodes)
    │
Enable-ClusterStorageSpacesDirect run — creates one clustered Storage Pool
  ("S2D on <cluster-name>") spanning eligible drives on every node
    │
Physical disks eligible and pooled (CanPool = True, no CannotPoolReason)
    │       ├── Cache tier (fast NVMe/SSD) — accelerates capacity-tier reads/writes
    │       └── Capacity tier (SSD/HDD) — where resilient copies of data actually live
    │
Storage Pool healthy (majority of drives reachable = quorum; pool goes
  read-only if quorum is lost)
    │
Virtual Disks (Storage Spaces) carved from pool free space, using a
  resiliency type (Mirror / Parity / Nested resiliency for 2-node clusters)
    │
Cluster Shared Volumes (CSV) — S2D virtual disks are exposed to the cluster
  as CSVs, which is what Hyper-V VMs actually run on top of
    │
Health Service (background component, part of Failover Clustering) — monitors
  pool/disk/virtual-disk state and drives automatic repair after a drive
  replacement or reconnection
    │
Volumes/CSVs online, VMs/workloads reading and writing without degraded resilience
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the cluster and S2D are actually enabled**
```powershell
Get-Cluster | Select-Object Name
Get-ClusterS2D
```
Expected: `Get-ClusterS2D` returns `State: Enabled`. If S2D was never enabled or was disabled, none of the storage-pool commands below will show a clustered pool.

**2. Confirm storage pool health**
```powershell
Get-StoragePool -IsPrimordial $False | Select-Object FriendlyName, HealthStatus, OperationalStatus, ReadOnlyReason
```
Expected: `HealthStatus: Healthy`, `OperationalStatus: OK`. `Warning`/`Degraded` means failed or missing drives (metadata-hosting ones); `Unknown`/`Unhealthy` with a `ReadOnlyReason` means the pool has gone read-only.

**3. Confirm virtual disk health**
```powershell
Get-VirtualDisk | Select-Object FriendlyName, HealthStatus, OperationalStatus, DetachedReason
```
Expected: `HealthStatus: Healthy`, `OperationalStatus: OK` (or `Suboptimal`, which is a rebalance opportunity, not a fault). `Warning`/`Unhealthy`/`Detached` means reduced or lost redundancy — check the specific `OperationalStatus`/`DetachedReason` against Fix 3.

**4. Confirm physical disk health, per node**
```powershell
Get-PhysicalDisk | Select-Object FriendlyName, SerialNumber, MediaType, HealthStatus, OperationalStatus, Usage, PhysicalLocation
```
Expected: every drive `HealthStatus: Healthy`, `OperationalStatus: OK`. Cross-reference `Usage` — `Journal`/`Cache` drives affect the whole node's write performance if unhealthy, not just their own capacity.

**5. Confirm no repair job is stuck**
```powershell
Get-StorageJob | Select-Object Name, JobState, PercentComplete, ElapsedTime, IsBackgroundTask
```
Expected: either no jobs (steady state) or a job actively progressing (`PercentComplete` increasing on repeated checks). A job stuck at the same percentage for 15+ minutes usually means a storage-network problem, not a slow drive.

**6. Confirm storage-network health (S2D's most common silent failure point)**
```powershell
Get-ClusterNetwork | Select-Object Name, State, Role
Get-NetAdapterRdma | Select-Object Name, Enabled
Get-SmbMultichannelConnection | Select-Object ServerName, ClientRssCapable, ClientRdmaCapable
```
Expected: storage network(s) `State: Up`, RDMA adapters `Enabled: True`, active SMB Multichannel connections using RDMA where hardware supports it. A degraded/disconnected storage NIC on one node presents as that node's drives going `Lost communication` — not as an obvious network alert.

---
## Common Fix Paths

<details><summary>Fix 1 — Pool Warning/Degraded (metadata drive failed or missing)</summary>

```powershell
# Confirm which drives are affected
Get-PhysicalDisk | Where-Object { $_.HealthStatus -ne "Healthy" } | Select-Object FriendlyName, HealthStatus, OperationalStatus

# Reconnect missing drives / bring offline nodes back online first
Get-ClusterNode | Select-Object Name, State

# Replace any genuinely failed drive, then let S2D auto-repair (do NOT manually
# run Repair-VirtualDisk on S2D — the Health Service triggers repair automatically
# once the replacement drive is detected and pooled)
Get-StorageJob | Select-Object Name, JobState, PercentComplete
```
**Rollback:** N/A — reconnecting drives/nodes and letting auto-repair run is non-destructive. Do not run `Reset-PhysicalDisk` against a drive that is only temporarily unreachable — that wipes it.
</details>

<details><summary>Fix 2 — Pool read-only, quorum lost (ReadOnlyReason: Incomplete)</summary>

```powershell
# Confirm how many drives/nodes are actually down
Get-ClusterNode | Select-Object Name, State
Get-PhysicalDisk | Where-Object { $_.OperationalStatus -eq "Lost Communication" }

# Bring nodes/drives back online, THEN set the pool back to read-write
Get-StoragePool -FriendlyName "S2D*" -IsPrimordial $False | Set-StoragePool -IsReadOnly $false
```
**Rollback:** N/A — restoring quorum and setting the pool back to read-write is the fix itself, not a change requiring rollback. If quorum cannot be restored (majority of nodes/drives permanently lost), this is a data-loss-risk escalation, not a self-service fix — see Escalation Evidence.
</details>

<details><summary>Fix 3 — Virtual disk Incomplete/Degraded/Detached</summary>

```powershell
# Identify the affected virtual disk and reason
Get-VirtualDisk | Select-Object FriendlyName, HealthStatus, OperationalStatus, DetachedReason

# Reconnect missing drives/nodes first — S2D auto-starts repair once resolved
Get-ClusterNode | Select-Object Name, State

# If Detached "By Policy" (an admin took it offline / set manual attach)
Get-VirtualDisk | Where-Object { $_.OperationalStatus -eq "Detached" } | Connect-VirtualDisk

# Only if NOT using S2D auto-repair and the disk is still Incomplete/Degraded
# after reconnecting everything (rare on S2D — confirm auto-repair truly isn't running first)
Repair-VirtualDisk -FriendlyName "<virtual-disk-name>"
Get-StorageJob | Select-Object Name, JobState, PercentComplete
```
**Rollback:** N/A. If `DetachedReason: Majority Disks Unhealthy` or `Incomplete` and more copies were lost than the resiliency type tolerates, the data on that virtual disk is permanently lost — restore from backup after recreating the virtual disk. Do not attempt manual repair against a virtual disk in this state.
</details>

<details><summary>Fix 4 — Drive shows "Lost communication"</summary>

```powershell
# Check whether it's the drive or the whole node
Get-PhysicalDisk | Where-Object { $_.OperationalStatus -eq "Lost Communication" } | Select-Object FriendlyName, PhysicalLocation
Get-ClusterNode | Select-Object Name, State

# If the node is down, bring it back online — the drive should self-recover
# If the node is up but one drive is still unreachable, check physical/cabling/backplane first
```
**Rollback:** N/A. Do not run `Reset-PhysicalDisk` on a drive reported as "Lost communication" while investigating — that command wipes the drive and is only appropriate once a drive is confirmed genuinely failed and needs to be re-added clean.
</details>

<details><summary>Fix 5 — Genuine drive failure (Failed media / Device hardware failure)</summary>

```powershell
# Confirm the failure and locate the physical drive
Get-PhysicalDisk | Where-Object { $_.HealthStatus -eq "Unhealthy" } |
  Select-Object FriendlyName, SerialNumber, PhysicalLocation, HealthStatus, OperationalStatus

# Physically replace the drive, then confirm it's pooled automatically
Get-PhysicalDisk | Where-Object { $_.CanPool -eq $true }

# If it doesn't auto-pool, check why and add it manually
Get-PhysicalDisk -CanPool $True | Format-Table FriendlyName, CannotPoolReason
Add-PhysicalDisk -StoragePoolFriendlyName "S2D*" -PhysicalDisks (Get-PhysicalDisk -FriendlyName "<new-drive>")
```
**Rollback:** N/A — replacing a confirmed-failed drive and letting the pool absorb it is the intended, non-destructive path.
</details>

<details><summary>Fix 6 — Repair job stuck / not progressing</summary>

```powershell
# Confirm the job is genuinely stalled, not just slow (large drives take hours)
Get-StorageJob | Select-Object Name, JobState, PercentComplete, ElapsedTime

# Check the storage network first — this is the most common real cause
Get-ClusterNetwork | Select-Object Name, State
Get-NetAdapterRdma | Select-Object Name, Enabled
Get-Counter '\RDMA Activity(*)\RDMA Errors' -ErrorAction SilentlyContinue

# Check for a stopped/crashed Health Service component
Get-Service ClusSvc | Select-Object Status
```
**Rollback:** N/A. Forcibly stopping a storage job is a last resort and not documented as a routine operation — escalate rather than interrupting a repair against redundancy that may already be reduced.
</details>

<details><summary>Fix 7 — Replacement drive won't pool (CannotPoolReason set)</summary>

```powershell
Get-PhysicalDisk | Format-Table FriendlyName, MediaType, Size, CanPool, CannotPoolReason

# "In a pool" from a previous deployment / "Not healthy" / "Insufficient Capacity"
# (leftover partitions) — reset the drive to wipe it clean, THEN re-add
Reset-PhysicalDisk -FriendlyName "<drive-name>"
Add-PhysicalDisk -StoragePoolFriendlyName "S2D*" -PhysicalDisks (Get-PhysicalDisk -FriendlyName "<drive-name>")
```
**Rollback:** N/A — `Reset-PhysicalDisk` is destructive to any data on that drive by design (it's meant for a drive being freshly added), which is expected for a replacement drive. Never run it against a drive that still holds the only up-to-date copy of data.
</details>

<details><summary>Fix 8 — Node-wide or network-wide degradation (not per-drive)</summary>

```powershell
# Confirm the blast radius: one node's worth of drives, or truly scattered?
Get-PhysicalDisk | Where-Object { $_.OperationalStatus -ne "OK" } |
  Group-Object -Property { (Get-StorageNode -PhysicalDisk $_).Name } -ErrorAction SilentlyContinue

Get-ClusterNode | Select-Object Name, State
Get-ClusterNetwork | Select-Object Name, State, Role

# Restore the node or storage-network link — do not treat this as N separate drive failures
```
**Rollback:** N/A. Treating a node/network-wide event as many individual drive failures risks unnecessary drive resets — always confirm node/network health before touching individual physical disks.
</details>

---
## Escalation Evidence

```
Storage Spaces Direct Escalation
---------------------------------
Date/Time of failure:
Cluster name / affected node(s):
Get-ClusterS2D state:
Storage pool HealthStatus/OperationalStatus/ReadOnlyReason:
Affected virtual disk(s) and their OperationalStatus/DetachedReason:
Affected physical disk(s), HealthStatus, PhysicalLocation:
Get-StorageJob output (any stuck repairs):
Cluster/storage network state (Get-ClusterNetwork, Get-NetAdapterRdma):
Recent changes (drive replacement, node maintenance, firmware/driver updates, network changes):
Attempted fixes and results:
```

---
## 🎓 Learning Pointers

- **On S2D, do not manually run `Repair-VirtualDisk` as a first step — the Health Service triggers repair automatically** once a replaced or reconnected drive is detected as pooled. Manually forcing repair before that can fight the automatic process. See [Storage Spaces and Storage Spaces Direct health and operational states](https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/storage-spaces-states).
- **A pool losing quorum (majority of drives unreachable) sets the entire pool read-only as a safety measure** — this is not itself data loss, but every virtual disk on that pool is inaccessible until quorum is restored. Treat it as a "many things broke at once" signal and check node/drive count first, the same instinct as checking Failover Cluster quorum in `HyperV-A.md`.
- **"Lost communication" on a drive usually means the node is down, not the drive** — check `Get-ClusterNode` before assuming a hardware failure and reaching for `Reset-PhysicalDisk`, which is destructive.
- **The storage network (often RDMA/RoCE) is S2D's most under-diagnosed dependency.** A degraded storage NIC on one node looks identical to a batch of drive failures on that node — always check `Get-ClusterNetwork`/`Get-NetAdapterRdma` before treating it as a storage-hardware problem.
- **`CannotPoolReason` is the fastest way to explain "why won't this new drive join the pool"** — most commonly `In a Pool` (needs removing from its old pool) or leftover partitions (`Insufficient Capacity`, fixed by `Reset-PhysicalDisk`).
- **For the deeper dive** — pool/virtual-disk/drive state model in full, cache-tier vs. capacity-tier architecture, resiliency types (mirror/parity/nested), and the Health Service's role — see `StorageSpacesDirect-A.md`. For the Failover Clustering/CSV layer S2D sits underneath, see `HyperV-A.md`.
