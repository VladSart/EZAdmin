# Windows Server Failover Clustering (WSFC) — Reference Runbook (Mode A: Deep Dive)
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

- **Applies to:** Windows Server Failover Clustering (WSFC) on Windows Server 2016 through 2025 — the general-purpose clustering platform underneath Hyper-V clusters, Storage Spaces Direct, SQL Server Failover Cluster Instances (FCI), scale-out file servers, and generic file server/print/DHCP clustered roles.
- **Covers:** quorum theory and voting mechanics, the three quorum witness types, dynamic quorum management, cluster networking and heartbeat, node quarantine (Health Service–driven node isolation), cluster validation, and Cluster-Aware Updating (CAU).
- **Does not cover:** Storage Spaces Direct's own pool-level health/quorum, which is a **separate, independently-gated concept that shares only the word "quorum" with cluster quorum** — a cluster can be fully quorate while an S2D storage pool is simultaneously read-only for entirely unrelated reasons (see `StorageSpacesDirect-A.md`); Hyper-V-specific behavior on top of a healthy cluster — CSV ownership, Live Migration authentication modes, Hyper-V Replica (see `HyperV-A.md`); SQL Server Always On Availability Groups' own health model, which uses WSFC only for its own quorum voting, not for SQL-level replica health.
- **Admin roles needed:** local Administrators on every cluster node, plus, for quorum witness configuration involving Active Directory (file share witness permissions on the Cluster Name Object), sufficient AD rights to grant the CNO computer account permissions on the target file share.

---
## How It Works

<details><summary>Full architecture</summary>

**The core problem WSFC quorum solves.** In any cluster designed for high availability, a network partition can split the cluster into two (or more) groups of nodes that can each still see storage and clients, but can no longer see each other. Without a tie-breaking mechanism, both halves could conclude they're the "real" cluster and simultaneously host the same roles against the same data — a **split-brain** scenario that causes data corruption. Quorum solves this by requiring **more than half** of all configured votes to be active before the cluster will run any role. A partition that can't reach a majority stops itself rather than risk corruption.

**Votes.** Each node gets one vote by default. A quorum **witness** — a disk, file share, or cloud blob — can optionally hold one additional vote, primarily to give an even-numbered cluster a tie-breaking majority. The total vote count and the "more than half must be active" rule together determine how many simultaneous node/witness failures the cluster can tolerate before it stops.

**Quorum modes** (what `Get-ClusterQuorum`/`QuorumType` reports):
- **Node Majority** — no witness; only nodes vote. Simplest, appropriate for an odd number of nodes.
- **Node Majority with Witness** (disk, file share, or cloud) — nodes vote, plus the witness. Recommended for even node counts.
- **Disk Only** (no node majority) — only a single disk witness votes, nodes don't. **Not recommended**: this makes the disk witness a single point of failure for the entire cluster, defeating the purpose of clustering.

**The three witness types, and why you'd pick each:**
- **Disk witness** — a small shared disk visible to every node, holding a copy of the cluster configuration database. Requires genuinely shared storage reachable by all nodes, which rules it out entirely for cluster types with no shared disk by design (S2D, SQL Always On AG, Exchange DAG).
- **File share witness** — an SMB share (TCP 445) that stores a log file, not the full cluster database. Works for any cluster type including shared-nothing ones, and is the standard choice for S2D. Requires the Cluster Name Object (CNO) computer account to have Full Control at both the SMB share-permission and NTFS-permission layers — a frequent source of "witness won't come online" tickets when only one of the two permission layers was granted.
- **Cloud witness** — uses an Azure Storage account Blob as the witness, one blob per cluster keyed by the cluster's unique GUID, so a single storage account can safely back witnesses for multiple clusters. Requires outbound HTTPS (TCP 443) from every node to the storage endpoint. Popular for multi-site clusters where a mutually-trusted third physical site for a file share witness isn't practical.

**Dynamic quorum management.** By default, WSFC dynamically adjusts node vote weight (`DynamicWeight`) as nodes are sequentially and gracefully taken down (e.g., planned maintenance) so the cluster can continue running down to a single surviving node without a manual quorum reconfiguration. This is different from — and does not replace — the witness vote; dynamic quorum management still requires that whatever votes remain active constitute a majority of the votes present **at the time of the failure**, not the original total. In S2D-enabled clusters specifically, dynamic quorum caps the number of simultaneous node failures the cluster can tolerate at two, regardless of total node count, because S2D itself needs enough surviving nodes to maintain data resiliency independent of pure quorum math.

**Node quarantine.** Separately from quorum, WSFC's cluster Health Service actively monitors each node for instability — repeated Resource Hosting Subsystem (RHS) crashes, repeated cluster service failures, or persistent network/storage communication failures from that specific node. If a node crosses a failure threshold within a rolling window, the Health Service **automatically quarantines it**: the node remains a cluster member (it still counts toward quorum voting in most cases) but cannot host any cluster roles until quarantine is cleared, either automatically after a cooldown period or manually via `Start-ClusterNode -ClearQuarantine`. This exists specifically to stop a "flapping" node from repeatedly yanking VMs or other roles back and forth as it fails over and over.

**Cluster networking.** WSFC classifies each detected network by role — **Cluster and Client** (both heartbeat/internal traffic and client-facing traffic), **Cluster Only** (internal heartbeat/CSV/Live Migration traffic, typically an isolated/private network), or **None** (excluded from cluster use, e.g. a dedicated backup or iSCSI network). The internal cluster communication (heartbeat, membership, some CSV redirected-I/O traffic) uses UDP port 3343 by default; Live Migration traffic and CSV direct I/O have their own port/protocol requirements layered on top. A network flagged `Partitioned` means some but not all nodes can reach each other over it — this is functionally more dangerous than a network being fully `Down`, since it can produce inconsistent views of cluster state across nodes rather than a clean, unambiguous failure.

**Cluster-Aware Updating (CAU).** CAU automates the traditionally manual process of patching a cluster node-by-node: draining roles off a node, pausing it, installing updates, rebooting, resuming it, and moving to the next node — while continuously re-checking that quorum and role availability remain intact throughout. It can run in **self-updating mode** (the cluster updates itself on a schedule via a CAU clustered role) or **remote-updating mode** (triggered from a management machine). `Test-CauRun` performs a dry-run readiness check without applying anything.

</details>

---
## Dependency Stack

```
Layer 4 — Cluster roles: VMs (Hyper-V), CSV, SQL FCI, file/print server
              role, scale-out file server — can only run on nodes that
              are Up AND not quarantined
Layer 3 — Node quarantine gate (Health Service) — monitors RHS/service
              crash frequency, network reliability, and storage
              reliability PER NODE; auto-isolates an unstable node
              independent of quorum math
Layer 2 — Quorum vote count — (active nodes with DynamicWeight=1) +
              (witness vote, if configured and its resource is Online) —
              must exceed 50% of currently-configured total votes
Layer 1 — Quorum witness (optional but recommended for even node
              counts), one of:
              ├── Disk witness (shared disk — not usable with
              │     shared-nothing cluster types)
              ├── File share witness (SMB/445, CNO needs Full Control
              │     on share AND NTFS permissions)
              └── Cloud witness (Azure Blob, outbound HTTPS/443)
Layer 0 — Foundation:
              ├── Cluster Service (ClusSvc) running on every node
              └── Cluster networks — heartbeat (UDP 3343) and client
                    paths reachable between ALL nodes; a Partitioned
                    network is more dangerous than a fully Down one
```

A fault at Layer 0/1 (network partition, or witness unreachable on an even-node cluster) threatens the ENTIRE cluster's ability to maintain quorum. A fault at Layer 3 (node quarantine) is scoped to a single node and does not by itself threaten overall quorum unless enough nodes are quarantined simultaneously to also break the Layer 2 vote majority.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Entire cluster down, `Get-Cluster` fails on every node | Quorum lost — active votes dropped below majority | `Get-ClusterNode`, `Get-ClusterQuorum`, recent Event ID 1177 |
| One node shows `NodeQuarantineState: Quarantined` | Health Service auto-isolated it after repeated RHS/service/network/storage failures | Event IDs 1641/1647/1649/7031 |
| Witness resource shows `Offline`/`Failed` | Witness type-specific reachability or permissions issue | `Get-ClusterResource` witness state, type-specific check (SMB 445 / HTTPS 443 / shared disk visibility) |
| Cluster stayed up through a node failure it "shouldn't" have survived | Dynamic quorum management adjusted vote weight as the node went down gracefully | `Get-ClusterNode` `DynamicWeight` history, confirm the shutdown was graceful vs. a hard failure |
| Cluster validation warns about quorum configuration | Even voting-node count with no witness, or `DiskOnly` mode in use | `Test-Cluster -Include "Validate Quorum Configuration"` |
| Network shows `Partitioned` rather than `Down` | Some but not all nodes can reach each other over that network — asymmetric failure | `Get-ClusterNetworkInterface`, per-node connectivity test |
| Node repeatedly evicted and rejoining | Underlying instability (network flap, storage flap, or crashing service) not yet resolved — quarantine clearing without root-cause fix | `Get-ClusterLog`, correlate with Event IDs by category |
| CAU run fails partway through | A node failed its post-update health re-check, or quorum margin too thin to safely continue | `Get-CauRun`, `Test-CauRun`, check `-MaxFailedNodes` setting |
| Cluster fully up, but S2D storage pool is read-only | Two independent quorum concepts — cluster quorum is fine, S2D pool quorum is not | See `StorageSpacesDirect-A.md`, not this file |

---
## Validation Steps

**1. Confirm cluster service and membership baseline**
```powershell
Get-Cluster | Select-Object Name, QuorumType
Get-ClusterNode | Select-Object Name, State, DynamicWeight, NodeQuarantineState
```
Good: `ClusSvc` running everywhere, every node `Up`, no unexpected `DynamicWeight: 0`, no node `Quarantined`. Bad: any node `Down` unexpectedly, or `NodeQuarantineState` not `NotQuarantined`.

**2. Confirm quorum configuration matches intent**
```powershell
Get-ClusterQuorum
Test-Cluster -Node (Get-ClusterNode).Name -Include "Validate Quorum Configuration"
```
Good: `QuorumType` is one of the recommended modes for the node count (odd nodes: Node Majority; even nodes: with witness). Bad: `DiskOnly` in use, or the validation test recommends a change that was never applied.

**3. Confirm witness resource health end-to-end**
```powershell
Get-ClusterResource | Where-Object { $_.ResourceType -match "Witness" } | Select-Object Name, State, OwnerNode
```
Good: `State: Online`. Bad: `Offline`/`Failed` — cross-reference the specific witness type's dependency (SMB permissions, HTTPS reachability, or shared disk visibility) per the How It Works section.

**4. Confirm cluster network health and role assignment**
```powershell
Get-ClusterNetwork | Select-Object Name, State, Role, Metric
Get-ClusterNetworkInterface | Select-Object Name, Network, Node, State
```
Good: every network `Up`, roles assigned as intended (Cluster and Client / Cluster Only / None). Bad: any network `Partitioned` (worse than `Down` — asymmetric), or a network that should be `Cluster Only` accidentally left as `None`.

**5. Confirm no node is silently near a quarantine threshold**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-FailoverClustering/Operational" -MaxEvents 200 |
  Where-Object { $_.Id -in 1641,1647,1649,7031 } | Sort-Object TimeCreated -Descending
```
Good: no recent occurrences. Bad: a rising frequency of these IDs for one node — it is trending toward auto-quarantine even if not yet quarantined.

**6. Pull the authoritative merged cluster log**
```powershell
Get-ClusterLog -Destination C:\ClusterLogs -UseLocal -TimeSpan 60
```
Good: log generates cleanly per node. This is the primary artifact for both self-diagnosis of a subtle timing-related issue and for Microsoft Support escalation.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Scope the fault: whole cluster, or one node?
1. `Get-ClusterNode` across all nodes. A single node `Down`/`Quarantined` with the rest `Up` scopes the issue to that node's health (network/storage/service). All or most nodes unreachable/`Down` scopes it to quorum itself or a shared dependency (network core, AD, DNS).

### Phase 2 — For a whole-cluster quorum loss, establish the vote math
2. `Get-ClusterQuorum` and `Get-ClusterNode` `DynamicWeight` together determine whether the surviving nodes + witness constitute a majority of currently-active votes. If they don't, the cluster stopping itself is the CORRECT, designed behavior — the fix is restoring enough nodes/witness, not forcing the cluster up carelessly.

### Phase 3 — For a quarantined node, find the pre-quarantine root cause
3. Correlate Event IDs 1641/1647/1649 (quarantine-specific) with 7031 (service crash), 1135/1177 (network), or 5120/5142 (storage/CSV) in the window immediately before quarantine activated. The quarantine event itself is a downstream symptom, not the root cause.

### Phase 4 — For witness failures, isolate by witness type
4. Disk witness: confirm shared-disk visibility from every node. File share witness: confirm SMB reachability AND that the CNO has Full Control at both the share and NTFS permission layers (a partial-permission grant is the most common single cause). Cloud witness: confirm outbound HTTPS to the storage endpoint and that the access key configured in `Set-ClusterQuorum` hasn't rotated/expired.

### Phase 5 — For network-classified issues, separate "Down" from "Partitioned"
5. A `Partitioned` network state means the fault is asymmetric — test connectivity from EVERY node to EVERY other node over that specific network, not just a single pair, since a partition can look healthy from some nodes' perspective and broken from others'.

### Phase 6 — Before clearing quarantine or forcing quorum, confirm root cause is resolved
6. Both `Start-ClusterNode -ClearQuarantine` and `Start-ClusterNode -FixQuorum` are state-override actions that will simply recur (or worse, risk split-brain in the forced-quorum case) if the underlying network, storage, or service issue driving the original failure hasn't actually been fixed.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Recover a cluster that lost quorum after a multi-node outage</summary>

**Scenario:** A power event or coordinated maintenance took down enough nodes simultaneously that the survivors can no longer form a majority, even though several nodes are otherwise healthy and reachable.

```powershell
# 1. Confirm which nodes are genuinely reachable right now
Get-ClusterNode | Select-Object Name, State

# 2. On ONE healthy, reachable node, force quorum — this starts the cluster
#    using only currently-available votes, bypassing the majority requirement
Start-ClusterNode -FixQuorum

# 3. Bring remaining healthy nodes back into the cluster normally
Start-Service ClusSvc

# 4. Once enough nodes have rejoined that normal quorum math is satisfied,
#    return the forced node to standard quorum operation
Stop-ClusterNode
Start-ClusterNode

# 5. Re-validate
Get-ClusterQuorum
Get-ClusterNode | Select-Object Name, State, DynamicWeight
```
**Rollback:** running in forced-quorum mode longer than necessary is itself a risk — if a network partition later reconnects unexpected nodes while forced quorum is still active, split-brain becomes possible again. Treat forced quorum as a bridge to full recovery, not a steady state. Based on [What is a quorum witness?](https://learn.microsoft.com/en-us/windows-server/failover-clustering/what-is-quorum-witness) and general WSFC recovery guidance.
</details>

<details><summary>Playbook 2 — Diagnose and clear a recurring node quarantine</summary>

**Scenario:** A specific node repeatedly enters quarantine, gets manually cleared, and re-enters within hours.

```powershell
# 1. Pull the full quarantine + service-crash event history for this node
Get-WinEvent -LogName "Microsoft-Windows-FailoverClustering/Operational" -MaxEvents 500 |
  Where-Object { $_.Id -in 1641,1647,1649,7031 } | Sort-Object TimeCreated

# 2. Cross-reference with System/Application logs for the SAME timestamps
#    to identify what actually crashed or failed (often a specific
#    service like the Resource Hosting Subsystem, or a driver)
Get-WinEvent -LogName System -MaxEvents 200 |
  Where-Object { $_.LevelDisplayName -eq "Error" }

# 3. Check for known interference: AV/EDR filter drivers holding cluster
#    processes, or missing recommended exclusions on Hyper-V hosts
fltmc filters

# 4. Only after the root cause is remediated (patch applied, exclusion
#    added, faulty NIC/HBA replaced), clear quarantine
Start-ClusterNode -Name <NodeName> -ClearQuarantine

# 5. Monitor for recurrence over the following 24-48 hours
Get-ClusterNode -Name <NodeName> | Select-Object State, NodeQuarantineState
```
**Rollback:** N/A — this is a diagnose-then-fix playbook, not a destructive change. Based on [Cluster node quarantine troubleshooting guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/cluster-node-quarantine-troubleshooting), including its recommended antivirus-exclusion and driver/firmware-update checks.
</details>

<details><summary>Playbook 3 — Migrate or repair a failing quorum witness</summary>

**Scenario:** The current witness (of any type) is degraded, was hosted on decommissioned infrastructure, or was never correctly permissioned.

```powershell
# 1. Confirm current configuration
Get-ClusterQuorum

# 2. Migrate to a file share witness (works for ALL cluster types,
#    including shared-nothing S2D/AG/DAG clusters)
Set-ClusterQuorum -NodeAndFileShareMajority "\\<FileServer>\<ShareName>"
# On the file server: grant the CNO computer account Full Control on
# BOTH the SMB share permission and the NTFS permission — partial
# permission grants are the most common single cause of a witness
# that appears configured but won't come Online

# 3. OR migrate to a cloud witness (no extra physical site required)
Set-ClusterQuorum -CloudWitness -AccountName <storageAccountName> -AccessKey <key>

# 4. Verify the new witness comes online
Get-ClusterResource | Where-Object { $_.ResourceType -match "Witness" } | Select-Object Name, State
```
**Rollback:** re-run `Set-ClusterQuorum` with the prior witness configuration to revert. Changing witness type takes effect immediately and briefly recalculates quorum — avoid doing this while the cluster is already in a degraded vote state.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Failover Clustering diagnostic evidence for escalation.
.NOTES
    Run on any healthy cluster node with local Administrator rights.
#>
$out = "C:\ClusterEvidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

Get-ClusterLog -Destination $out -UseLocal -TimeSpan 120

Get-ClusterNode | Select-Object Name, State, DynamicWeight, NodeQuarantineState |
  Export-Csv "$out\cluster-nodes.csv" -NoTypeInformation

Get-ClusterQuorum | Export-Csv "$out\cluster-quorum.csv" -NoTypeInformation

Get-ClusterNetwork | Select-Object Name, State, Role, Metric |
  Export-Csv "$out\cluster-networks.csv" -NoTypeInformation

Get-ClusterResource | Where-Object { $_.ResourceType -match "Witness" } |
  Select-Object Name, State, OwnerNode | Export-Csv "$out\witness-state.csv" -NoTypeInformation

Get-WinEvent -LogName "Microsoft-Windows-FailoverClustering/Operational" -MaxEvents 500 -ErrorAction SilentlyContinue |
  Where-Object { $_.Id -in 1069,1135,1177,1558,1641,1647,1649,5120,5142,7031 } |
  Select-Object TimeCreated, Id, LevelDisplayName, Message |
  Export-Csv "$out\cluster-events.csv" -NoTypeInformation

Write-Host "Evidence collected to $out"
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip"
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-Cluster` / `Get-ClusterNode` | Cluster and node identity, state, quorum type |
| `Get-ClusterQuorum` | Current quorum type and witness resource |
| `Test-Cluster -Include "Validate Quorum Configuration"` | Non-disruptive quorum configuration validation |
| `Get-ClusterNetwork` / `Get-ClusterNetworkInterface` | Cluster network inventory, state, per-node interface health |
| `Get-ClusterResource` | Cluster resources including the witness resource |
| `Start-ClusterNode -ClearQuarantine` | Manually clear a quarantined node (after root cause resolved) |
| `Start-ClusterNode -FixQuorum` | Force quorum on one node during a majority-loss outage (last resort) |
| `Set-ClusterQuorum` | Change quorum type/witness configuration |
| `Get-ClusterLog -UseLocal -TimeSpan <min>` | Merged, timestamped per-node cluster log — primary escalation artifact |
| `Get-CauRun` / `Test-CauRun` / `Invoke-CauRun` | Cluster-Aware Updating status, dry-run, and manual trigger |
| `Get-WinEvent -LogName "Microsoft-Windows-FailoverClustering/Operational"` | Cluster-specific event log (quorum, quarantine, network, storage IDs) |

---
## 🎓 Learning Pointers

- **Quorum exists to prevent split-brain, not to maximize uptime at any cost** — a cluster that stops itself when it can't confirm a majority is behaving correctly, even though it feels like an outage. Resist the urge to force quorum reflexively; confirm the vote math first. See [What is a quorum witness?](https://learn.microsoft.com/en-us/windows-server/failover-clustering/what-is-quorum-witness).
- **Node quarantine and quorum are two separate protection mechanisms answering different questions** — quorum asks "do we have enough votes to safely run at all," quarantine asks "is this specific node too unstable to trust with roles." A node can be quarantined while the cluster overall remains perfectly quorate.
- **Dynamic quorum management adapts vote weight only for graceful, sequential node departures** — it is not a substitute for a witness, and a sudden multi-node hard failure can still break quorum even with dynamic quorum management enabled, especially on S2D clusters where simultaneous-failure tolerance is capped at two nodes regardless of total node count.
- **A `Partitioned` cluster network is more dangerous than a `Down` one** — it means different nodes have inconsistent views of reachability, which is exactly the asymmetric-failure condition quorum logic is designed to guard against. Test connectivity from every node to every other node, not just one pair, when this state appears.
- **File share witness failures are very often a permissions problem, not a networking one** — the Cluster Name Object needs Full Control at BOTH the SMB share-permission layer and the NTFS-permission layer; granting only one is a common, easy-to-miss misconfiguration.
- **This file is the shared foundation under `StorageSpacesDirect-A.md` and `HyperV-A.md`** — both of those topics have their own additional, independently-gated health concepts layered on top of a healthy WSFC cluster (S2D pool quorum; CSV ownership and Live Migration). Diagnose cluster-level quorum/networking/quarantine issues here first before assuming a workload-specific root cause.
