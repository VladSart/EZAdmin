# Windows Server Failover Clustering (WSFC) — Hotfix Runbook (Mode B: Ops)
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

**This runbook covers the Windows Server Failover Clustering (WSFC) layer itself** — quorum/witness health, cluster networking, node quarantine, and cluster service state. It is the foundation layer underneath role-specific clusters; for the workload-specific health sitting on top of a healthy cluster, see `StorageSpacesDirect-B.md` (pool-level health) or `HyperV-B.md` (CSV/VM/Live Migration).

```powershell
# 1. Cluster and node state — the fastest single "is the cluster healthy" check
Get-Cluster | Select-Object Name, QuorumType
Get-ClusterNode | Select-Object Name, State, DynamicWeight

# 2. Quorum/witness state
Get-ClusterQuorum | Select-Object QuorumResource, QuorumType

# 3. Cluster networks — a down/partitioned network is the #1 quorum-loss cause
Get-ClusterNetwork | Select-Object Name, State, Role

# 4. Is any node quarantined right now?
Get-ClusterNode | Where-Object { $_.State -eq "Down" -or $_.NodeQuarantineState -ne "NotQuarantined" } |
  Select-Object Name, State, NodeQuarantineState

# 5. Recent cluster/quorum-relevant events
Get-WinEvent -LogName "Microsoft-Windows-FailoverClustering/Operational" -MaxEvents 50 |
  Where-Object { $_.Id -in 1069,1135,1177,1558,1641,1647,1649,5120,5142 }
```

| Finding | Interpretation | Do this |
|---|---|---|
| Cluster service won't start / `Get-Cluster` fails entirely | Quorum lost, or local cluster service crashed | **Fix 1** |
| One node shows `NodeQuarantineState: Quarantined` | Node auto-isolated after repeated health-check/RHS failures | **Fix 2** |
| `Get-ClusterQuorum` shows witness resource offline/failed | Witness (disk/file share/cloud) unreachable — cluster running on reduced margin | **Fix 3** |
| Event ID 1135/1177, node dropped from membership | Network partition/heartbeat loss between nodes | **Fix 4** |
| Event ID 5120/5142 alongside quarantine | Storage/CSV access failure triggered the quarantine, not networking | See `HyperV-B.md`/`StorageSpacesDirect-B.md` for the storage layer first |
| Cluster validation report shows quorum warnings | Even number of voting nodes with no witness, or a misconfigured witness | **Fix 5** |
| Cluster works but updates require manual node-by-node maintenance mode | Cluster-Aware Updating (CAU) not configured or failing | **Fix 6** |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Cluster Service (ClusSvc) running on every node
    │
Cluster networks healthy — heartbeat (private/mixed role) + client
  network reachable between ALL nodes (UDP 3343 + related ports)
    │
Node membership — every node actively communicating maintains its vote;
  a node that drops off is evicted from the ACTIVE vote count, not
  necessarily from cluster membership itself
    │
Quorum vote count — (nodes with DynamicWeight=1) + (witness vote, if
  configured and healthy) — MORE THAN HALF of the total configured votes
  must be active or the cluster stops itself (split-brain prevention)
    │
Quorum witness (one of, optional but recommended for even node counts):
    ├── Disk witness — shared disk visible to all nodes (not usable with
    │     S2D/AlwaysOn AG/DAG-style clusters — no shared disk exists)
    ├── File share witness — SMB share (TCP 445), CNO needs Full Control
    │     on share + NTFS permissions
    └── Cloud witness — Azure Blob Storage (TCP 443 outbound from every
          node), one blob per cluster keyed by cluster unique ID
    │
Node quarantine gate — a node with repeated RHS/service crashes,
  network drops, or storage failures is AUTOMATICALLY isolated
  (cannot host roles) even while technically still a cluster member
    │
Cluster roles (VMs, CSV, file server role, SQL FCI, etc.) — can only
  run on nodes that are active AND not quarantined
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the cluster service and node membership**
```powershell
Get-Service ClusSvc | Select-Object Status, StartType
Get-ClusterNode | Select-Object Name, State, DynamicWeight
```
Expected: `ClusSvc: Running`. Every node `State: Up` with `DynamicWeight: 1` (1 = holds a vote, 0 = doesn't). A node stuck `Down` or with `DynamicWeight: 0` unexpectedly is the starting point for the investigation.

**2. Confirm quorum configuration and witness health**
```powershell
Get-ClusterQuorum
Get-ClusterResource | Where-Object { $_.ResourceType -match "Witness" } | Select-Object Name, State
```
Expected: witness resource (if configured) shows `State: Online`. `QuorumType` matches what was intentionally configured (`NodeMajority`, `NodeAndDiskMajority`, `NodeAndFileShareMajority`, `NodeAndCloudMajority`, or the not-recommended `DiskOnly`).

**3. Confirm cluster networks**
```powershell
Get-ClusterNetwork | Select-Object Name, State, Role, Metric
Test-Cluster -Node (Get-ClusterNode).Name -Include "Network"
```
Expected: all networks `State: Up`. A network in `Partitioned` or `Down` between specific nodes points directly at the physical/virtual network path between those nodes, not the cluster software.

**4. Confirm no node is quarantined**
```powershell
Get-ClusterNode | Select-Object Name, State, NodeQuarantineState
```
Expected: `NodeQuarantineState: NotQuarantined` on every node. `Quarantined` means the cluster itself already decided this node is unstable — treat it as a symptom pointing at RHS/service, network, or storage failure underneath (see Fix 2), not a fault to clear blindly.

**5. Pull the authoritative cluster log for the failure window**
```powershell
Get-ClusterLog -Destination C:\ClusterLogs -UseLocal -TimeSpan 60
```
Expected: this generates a detailed, timestamped log per node covering the last 60 minutes — the single most useful artifact for both self-diagnosis and escalation. Always collect this before engaging Microsoft Support.

---
## Common Fix Paths

<details><summary>Fix 1 — Cluster service won't start / quorum lost cluster-wide</summary>

```powershell
# Confirm this is genuinely quorum loss vs. a single-node service crash
Get-ClusterNode | Select-Object Name, State
Get-WinEvent -LogName "Microsoft-Windows-FailoverClustering/Operational" -MaxEvents 20 |
  Where-Object { $_.Id -in 1177,1641 }

# If MOST nodes are actually up and reachable but the cluster still won't
# form quorum (e.g. after a multi-node simultaneous reboot), force quorum
# on ONE node only — this is a deliberate, last-resort action
Start-ClusterNode -FixQuorum

# Once the cluster is back up and stable, clear forced-quorum mode
Stop-ClusterNode
Start-ClusterNode
```
**Rollback:** N/A for `Start-ClusterNode -FixQuorum` itself — but running the cluster in forced-quorum mode on a single node for longer than necessary risks a genuine split-brain if the other nodes rejoin unexpectedly. Return to normal quorum operation as soon as enough nodes are confirmed healthy.
</details>

<details><summary>Fix 2 — A node is quarantined</summary>

```powershell
# Confirm WHY before clearing — clearing blindly just re-triggers the same
# quarantine if the underlying cause (RHS crash loop, network, storage) is
# still present
Get-WinEvent -LogName "Microsoft-Windows-FailoverClustering/Operational" -MaxEvents 50 |
  Where-Object { $_.Id -in 1641,1647,1649,7031 }

# Once the underlying cause is resolved (service patched, AV exclusion
# added, network/storage path restored), clear the quarantine
Start-ClusterNode -Name <NodeName> -ClearQuarantine

# Confirm the node rejoined cleanly and stays out of quarantine
Get-ClusterNode -Name <NodeName> | Select-Object State, NodeQuarantineState
```
**Rollback:** N/A — clearing quarantine is a state reset, not a destructive action. If the node re-enters quarantine shortly after, the root cause was not actually resolved; escalate with `Get-ClusterLog` output rather than repeatedly clearing.
</details>

<details><summary>Fix 3 — Witness resource offline/unreachable</summary>

```powershell
# Disk witness — confirm the shared disk itself is visible to all nodes
Get-ClusterResource | Where-Object ResourceType -eq "Physical Disk" | Select-Object Name, State

# File share witness — confirm SMB reachability and CNO permissions
Test-NetConnection -ComputerName <WitnessShareServer> -Port 445
# On the file server: Cluster Name Object (CNO) computer account needs
# Full Control on BOTH the share permission and the NTFS permission

# Cloud witness — confirm outbound HTTPS and validate the storage account key
Test-NetConnection -ComputerName <storageaccount>.blob.core.windows.net -Port 443
Set-ClusterQuorum -CloudWitness -AccountName <storageAccountName> -AccessKey <key>
```
**Rollback:** N/A — witness resource repair is non-destructive. Do not remove the witness entirely as a "fix" for an even-node-count cluster; that trades a witness problem for a quorum-fragility problem (see Learning Pointers).
</details>

<details><summary>Fix 4 — Network partition / heartbeat loss between nodes</summary>

```powershell
# Confirm which specific node pair/path is affected
Get-ClusterNetworkInterface | Select-Object Name, Network, State

# Test the cluster heartbeat path directly (UDP 3343 is the core cluster
# communication port; also confirm SMB/445 for CSV and file share witness,
# and TCP 6600 if Live Migration traffic shares the same path)
Test-NetConnection -ComputerName <OtherNodeName> -Port 3343

# Check for MTU mismatch across cluster-network-tagged adapters — a classic,
# hard-to-spot cause of intermittent heartbeat loss
Get-NetAdapterAdvancedProperty -DisplayName "Jumbo Packet"
```
**Rollback:** N/A — diagnostic. Any firewall rule, NIC teaming, or MTU change should follow standard change control since it affects all cluster traffic, not just this investigation.
</details>

<details><summary>Fix 5 — Quorum configuration warning from validation</summary>

```powershell
# Re-run the quorum-specific validation test (safe to run against a live
# production cluster — this test does not take resources offline)
Test-Cluster -Node (Get-ClusterNode).Name -Include "Validate Quorum Configuration"

# Apply the wizard's recommended configuration, or set explicitly:
# Best practice: odd number of total votes. For an even node count, add
# a witness (disk/file share/cloud) rather than manually stripping node votes
Set-ClusterQuorum -NodeAndFileShareMajority "\\<Server>\<Share>"
```
**Rollback:** re-run `Set-ClusterQuorum` with the prior configuration to revert. Quorum configuration changes take effect immediately — avoid changing quorum type during an active incident unless the current configuration is the confirmed root cause.
</details>

<details><summary>Fix 6 — Cluster-Aware Updating (CAU) not running/failing</summary>

```powershell
# Confirm CAU role and current run status
Get-CauClusterRole -ClusterName <ClusterName>
Get-CauRun -ClusterName <ClusterName>

# Test readiness without applying updates
Test-CauRun -ClusterName <ClusterName>

# Manually trigger a run if the scheduled self-updating run failed
Invoke-CauRun -ClusterName <ClusterName> -MaxFailedNodes 1 -Force
```
**Rollback:** N/A for testing. `Invoke-CauRun` orchestrates real patching/reboots node-by-node — schedule it in a maintenance window, not mid-incident.
</details>

---
## Escalation Evidence

```
Failover Clustering Escalation
-------------------------------
Date/Time of failure:
Cluster name and affected node(s):
Get-ClusterNode output (all nodes, State + DynamicWeight + NodeQuarantineState):
Get-ClusterQuorum output:
Get-ClusterNetwork output:
Get-ClusterLog output (path to collected logs, -TimeSpan covering the incident):
Relevant Event IDs observed (1069/1135/1177/1558/1641/1647/1649/5120/5142):
Witness type and recent changes to it:
Recent changes (patching, network change, storage change, AV/EDR change, node added/evicted):
Attempted fixes and results:
```

---
## 🎓 Learning Pointers

- **Quorum and "the cluster is up" are not the same question** — a cluster can have every node reachable over the client network yet still be down because it lost the internal heartbeat network specifically, or because witness-vote loss dropped total active votes below a majority. Always check `Get-ClusterQuorum` and `Get-ClusterNetwork` separately, not just node ping.
- **Node quarantine is the cluster protecting itself, not a bug to clear away** — it exists specifically to stop a flapping/unstable node from repeatedly disrupting roles. Treat a quarantined node as a confirmed symptom and find the RHS/service, network, or storage root cause (Event IDs 1641/1647/7031 for service, 1135/1177 for network, 5120/5142 for storage) before clearing it. See [Cluster node quarantine troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/cluster-node-quarantine-troubleshooting).
- **An even number of voting nodes without a witness is a fragile default, not just a warning to dismiss** — best practice is an odd total vote count; for an even node count, add a disk, file share, or cloud witness rather than manually removing a node's vote. See [What is a quorum witness?](https://learn.microsoft.com/en-us/windows-server/failover-clustering/what-is-quorum-witness).
- **A disk witness is not an option for every cluster type** — Storage Spaces Direct, SQL Always On Availability Groups, and Exchange DAG clusters have no shared disk by design, so a file share or cloud witness is the only valid choice for them.
- **This is the layer underneath, not a replacement for, workload-specific cluster health** — `StorageSpacesDirect-A.md` covers pool-level quorum (a second, independently-gated quorum concept that shares only a name with cluster quorum), and `HyperV-A.md` covers CSV/Live Migration on top of a healthy cluster. Diagnose WSFC quorum/networking here first if the cluster itself is unstable before treating it as an S2D or Hyper-V-specific issue.
- **`Get-ClusterLog -UseLocal -TimeSpan <minutes>` is the single most valuable artifact for any cluster escalation** — it merges per-node, timestamped diagnostic detail that individual Event Viewer logs don't capture as coherently.
