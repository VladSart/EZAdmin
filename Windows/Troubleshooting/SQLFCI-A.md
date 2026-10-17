# SQL Server Failover Cluster Instance (FCI) — Reference Runbook (Mode A: Deep Dive)
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

- SQL Server 2016–2022 **Failover Cluster Instances** on Windows Server 2016–2025 Failover Clustering, on-premises or on Azure VMs.
- Storage: traditional shared disks (SAN FC/iSCSI, shared VHDX), **Cluster Shared Volumes** on Storage Spaces Direct (supported for FCI since SQL 2016 on WS2016), Azure shared disks, or SMB file shares (Azure Premium file share / SOFS — not a cluster resource at all).
- Connection point: classic **Virtual Network Name (VNN)** with one IP per subnet, or on Azure a **Distributed Network Name (DNN)** (SQL 2019 CU8, 2017 CU25, 2016 SP3 and later on WS2016+) or VNN + Azure Load Balancer.
- **Out of scope:** Always On availability group listeners (`SQLAGListener-A.md`), quorum/node health (`FailoverClustering-A.md`), cluster computer objects (`ClusterADObjects-A.md`), DBA work (corruption, query tuning, backups).
- Read-only checks need local admin on a node; changing dependencies, owners or DNN resources needs cluster admin rights; T-SQL fixes need `sysadmin`.

---
## How It Works

<details><summary>Full architecture</summary>

### One instance, many possible homes
An FCI is a **single SQL Server instance** whose binaries are installed locally on every node (by SQL setup *Install new FCI* on the first node, *Add node* on the others) but whose **system and user databases live on shared storage**. The Windows cluster owns an FCI role (cluster group) named `SQL Server (<instance>)` that contains:

```
Cluster group "SQL Server (MSSQLSERVER)"
 ├── IP Address  (one per subnet; OR-dependency for multi-subnet FCI)
 ├── Network Name (the VNN = SQL "virtual server name" clients use)
 ├── [Distributed Network Name]  (optional, Azure VMs)
 ├── Physical Disk / Cluster Disk N  (not needed for CSV/SMB storage)
 ├── SQL Server            ── resource type "SQL Server"   (resource DLL sqsrvres.dll)
 └── SQL Server Agent      ── resource type "SQL Server Agent" (depends on SQL Server)
```

Only one node runs the SQL service at a time. On failover the cluster stops SQL on node A (or finds it dead), moves the disks (SCSI-3 persistent reservations change owner), brings IP → name → SQL online on node B, and SQL runs crash recovery on every database. **Failover time = detection + resource moves + database recovery** — long-running transactions make the last part dominate.

### The SQL Server resource and its private properties
The resource stores what it needs as private cluster parameters:

| Parameter | Meaning |
|---|---|
| `VirtualServerName` | The VNN the instance is bound to |
| `InstanceName` | `MSSQLSERVER` or the named instance |
| `HealthCheckTimeout` | ms before a non-responsive `sp_server_diagnostics` = failure (default 60000) |
| `FailureConditionLevel` | 0–5, which diagnostic conditions trigger failover (default 3) |

`HealthCheckTimeout` and `FailureConditionLevel` should be changed with `ALTER SERVER CONFIGURATION SET FAILOVER CLUSTER PROPERTY` (T-SQL) so SQL and the cluster stay in sync, not by editing the cluster parameter directly.

### Health detection (since SQL 2012)
The resource DLL opens a persistent connection to the instance and runs `sp_server_diagnostics`, which streams component states every `HealthCheckTimeout/3`:

| Component | Example "error" condition |
|---|---|
| system | Spinlocks, severe non-yielding schedulers, access violations |
| resource | Out-of-memory conditions |
| query_processing | Deadlocked schedulers, worker exhaustion |
| io_subsystem | Long IO (reported, not used for failover by default) |
| events | Informational |

`FailureConditionLevel` maps to: 1 = service down; 2 = + server unresponsive (no data within timeout); **3 (default)** = + critical `system` errors; 4 = + moderate `resource` errors; 5 = + `query_processing` errors. Lower = fewer automatic failovers. The DLL connects as **`NT AUTHORITY\SYSTEM`** (the RHS process identity). If that login is dropped or denied, every node "fails" health checks right after startup — the classic self-inflicted ping-pong.

### Dependencies are a correctness feature
SQL refuses to use a database file on a cluster disk that the SQL resource does not depend on (error 5184 since SQL 2012), because otherwise SQL could start while that disk is still on another node. CSV paths (`C:\ClusterStorage\VolumeN`) are exempt — CSVs are online on all nodes simultaneously. Adding a disk after install = add to the role **and** add to the dependency expression with `and`.

### Failover policy
- **Resource level:** restart attempts on the same node (`RestartThreshold` within `RestartPeriod`), then fail the group if `RestartAction` = 2.
- **Group level:** `FailoverThreshold` within `FailoverPeriod` (hours). Default threshold `4294967295` means "nodes − 1". After that the group stays `Failed` with **Event 1254** until an admin intervenes.
- **Possible owners** (resource) vs **preferred owners** (group): a node not in a resource's possible owners can never host the group. SQL setup sets SQL/name possible owners as nodes are added/removed — edits by hand drift.

### Connection points
- **VNN:** an A record registered by the cluster (VCO computer account in AD). Multi-subnet FCIs (SQL 2012+) use OR-dependent IPs; the same `RegisterAllProvidersIP`/`HostRecordTTL`/`MultiSubnetFailover` trade-offs as AG listeners apply (see `SQLAGListener-A.md`).
- **Azure VMs:** Azure doesn't honour gratuitous ARP for a floating VIP, so a single-subnet VNN needs an **Azure Load Balancer** with a health probe port. Alternatives: put nodes in different subnets (multi-subnet VNN), or add a **DNN**.
- **DNN:** a cluster resource whose DNS name registers the IP of **every possible owner node**; the client's `MultiSubnetFailover=True` parallel connect finds the node that actually listens. The **VNN still exists** and must not be deleted. DNN possible owners should be trimmed to FCI nodes. Clients that can't do MultiSubnetFailover cannot use a DNN. Clients can keep the old name by renaming the VNN first and assigning the old name to the DNN. Some features that hard-code the VNN (e.g. certain replication/linked server setups) need a server alias — see the DNN interoperability article.
- **Named instances:** clients resolve the port via SQL Browser (UDP 1434) unless a static port is configured; Browser must run on every node.

### Storage options and what "disk" means
| Storage | Cluster resource | Dependency needed | Notes |
|---|---|---|---|
| SAN / iSCSI / shared VHDX | Physical Disk | Yes | SCSI-3 PR; MPIO consistent on all nodes |
| S2D / CSV | Cluster Shared Volume | No | Path `C:\ClusterStorage\...`; watch redirected IO |
| Azure shared disk | Physical Disk | Yes | Premium SSD/Ultra with `maxShares` ≥ node count |
| SMB (Azure Premium files, SOFS) | none | No | Service account needs share + NTFS rights; network = storage |
</details>

---
## Dependency Stack

```
[7] Client: driver + connection string (name, instance/port, MultiSubnetFailover for DNN/multi-subnet)
[6] DNS: VNN A record (VCO rights) | DNN A records for all possible-owner nodes
[5] SQL Server Agent resource  → depends on SQL Server
[4] SQL Server resource Online + health detection passing (NT AUTHORITY\SYSTEM login, sp_server_diagnostics)
[3] SQL dependencies: Network Name (→ IP Address OR-set) AND every non-CSV data/log disk
[2] Node eligibility: SQL binaries + same CU on node, possible owner of every resource, threshold not exceeded
[1] Storage reachable from the node: LUN/MPIO/iSCSI, CSV healthy, or SMB share reachable with service account
[0] Cluster core: quorum, node Up, cluster network for each IP subnet, AD (CNO/VCO), DNS
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| SQL resource fails immediately, disks fine | Service account password / logon right, missing master path | Application log MSSQL events, ERRORLOG 17113/17204/17058 |
| SQL online for ~1 min then fails on every node | `NT AUTHORITY\SYSTEM` login dropped / denied; health check timeout | ERRORLOG 18456 for SYSTEM; cluster log `[RES] SQL Server` lines |
| Ping-pong only under heavy load / during dumps | `HealthCheckTimeout` too short for real stalls; IO latency | cluster log component states; `sys.dm_io_virtual_file_stats` |
| DB `RECOVERY_PENDING` after failover; error 5184 | Disk not in SQL resource dependency | `Get-ClusterResourceDependency` |
| Role `Failed`, Event 1254 | Failover threshold reached | `FailoverThreshold`/`FailoverPeriod` on group |
| Can't move role to node X | X not possible owner / SQL not installed on X / CU mismatch | `Get-ClusterOwnerNode`, service list on X, `@@VERSION` per node |
| Disk resource fails on one node only | Path/MPIO/iSCSI/zoning on that node | `Get-Disk`, `Get-IscsiSession`, `mpclaim -s -d` |
| CSV in redirected mode, SQL slow/timeouts | Lost direct storage path / backup snapshot | `Get-ClusterSharedVolumeState` |
| Clients time out by name, role healthy | DNS stale (VCO rights), Browser/static port, Azure VNN w/o LB | `Resolve-DnsName`, `Test-NetConnection -Port`, Event 1196 |
| DNN: ~50% connect failures | Client lacks `MultiSubnetFailover=True` / legacy driver | Connection string; driver version |
| DNN: clients reach a non-FCI node | DNN possible owners include non-FCI nodes | `Get-ClusterOwnerNode -Resource <dnn>` |
| Agent jobs not running after failover | SQL Server Agent resource offline / failed separately | Agent resource state; SQLAGENT.OUT |

---
## Validation Steps

1. **Cluster core healthy** — `Get-ClusterNode` → all FCI nodes `Up`. Bad: `Down`/`Paused`/`Isolated` → fix cluster first.
2. **Role online on intended node** — `Get-ClusterGroup '<FCIRole>'` → `State Online`. Bad: `Failed`/`PartialOnline`.
3. **Every resource online** — `Get-ClusterGroup '<FCIRole>' | Get-ClusterResource` → all `Online`. Bad: any `Failed` names the layer.
4. **Dependencies complete** — `Get-ClusterResourceDependency '<SQLServerResourceName>'` → name AND every non-CSV DB disk. Bad: a disk holding DB files absent.
5. **Possible owners consistent** — `Get-ClusterOwnerNode -Resource <each>` → same node list on SQL, name, disks, DNN. Bad: drift.
6. **Same build on every node** — script below / `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\<InstanceId>\Setup' PatchLevel` on each node → identical. Bad: mismatch blocks failover to the lower node.
7. **Health detection** — from SQL: `SELECT * FROM sys.dm_os_cluster_properties;` → expected `HealthCheckTimeout 60000`, `FailureConditionLevel 3` (or documented values). `SELECT name FROM sys.server_principals WHERE name = 'NT AUTHORITY\SYSTEM';` → row exists.
8. **Cluster view from SQL** — `SELECT * FROM sys.dm_os_cluster_nodes;` → all nodes, `status_description = up`, `is_current_owner = 1` on one.
9. **Connectivity** — from a client subnet: `Resolve-DnsName <name>` (VNN: one IP; DNN: all FCI node IPs) and `Test-NetConnection <name> -Port <port>` → True.
10. **Planned failover test** (maintenance window) — `Move-ClusterGroup '<FCIRole>' -Node <other>` → online within your RTO; repeat back.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Is it the cluster or SQL?** If nodes/quorum are unhealthy, nothing below matters (`FailoverClustering-A.md`). If the role fails at an IP/name resource, it's network/AD/DNS (`ClusterADObjects-A.md`). If disks fail, it's storage. Only when IP/name/disks are online and SQL fails is it SQL.

**Phase 2 — Storage.** Identify which disks are in the role, which node sees them (`Get-Disk` per node), MPIO path count, iSCSI sessions, CSV state. For S2D: `Get-StoragePool`, `Get-VirtualDisk`, `Get-StorageJob` (repairs in progress make IO slow → health timeouts).

**Phase 3 — SQL startup.** Read startup params from the registry (`SQLArg0..n`), open the ERRORLOG at the `-e` path. Map the first error: 17113/17204 (file), 17058 (errorlog path), 17182/17826 (network/TDS, often a cert or port conflict), 18456 for SYSTEM (health login), 912/3417 (script upgrade failed after a CU — DBA escalation, may need trace flag 902).

**Phase 4 — Health detection.** Generate the cluster log; look for `[RES] SQL Server <SQL Server (X)>: [sqsrvres]` lines showing `IsAlive`, component states, and "Failure detected, diagnostics heartbeat is lost". Correlate with ERRORLOG non-yielding scheduler dumps and IO warnings (error 833: IO requests taking longer than 15 seconds).

**Phase 5 — Movement policy.** Check group failover threshold/period, Event 1254, possible owners, preferred owners and `AutoFailbackType` (failback during business hours causes a second outage).

**Phase 6 — Client path.** DNS (VNN/DNN), VCO record ACL (Event 1196), port (static vs Browser), firewall on every node, Azure LB probe or DNN `MultiSubnetFailover`, driver support.

---
## Remediation Playbooks

<details><summary>Playbook A — Add a disk to a running FCI correctly</summary>

1. Present the LUN to **all** FCI nodes; on one node: initialise, format, but don't assign as non-clustered storage.
2. `Get-ClusterAvailableDisk | Add-ClusterDisk`
3. Move it into the role: `Move-ClusterResource -Name '<Cluster Disk N>' -Group '<FCIRole>'`
4. Add the dependency: `$e=(Get-ClusterResourceDependency '<SQLServerResourceName>').DependencyExpression; Set-ClusterResourceDependency -Resource '<SQLServerResourceName>' -Dependency "$e and [<Cluster Disk N>]"`
5. SQL picks up the new dependency without restart (SQL 2012+); verify with `SELECT * FROM sys.dm_io_cluster_valid_path_names;` — the new path should be listed.
6. Rollback: restore the original expression with `Set-ClusterResourceDependency`, then `Move-ClusterResource` the disk to Available Storage.
</details>

<details><summary>Playbook B — Recover from a dropped NT AUTHORITY\SYSTEM login (ping-pong)</summary>

1. Take the role offline except storage: `Stop-ClusterResource '<SQLServerResourceName>'` (leave disks online on the current owner).
2. On that owner, start SQL outside the cluster in single-user mode: `net start MSSQLSERVER /m"SQLCMD"` (named: `net start MSSQL$<inst> /m"SQLCMD"`).
3. `sqlcmd -S <VNN>\<inst> -E` (as a local admin, which is sysadmin in single-user mode) and run:
   ```sql
   IF SUSER_ID('NT AUTHORITY\SYSTEM') IS NULL CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS;
   ALTER LOGIN [NT AUTHORITY\SYSTEM] ENABLE;
   GRANT CONNECT SQL, VIEW SERVER STATE TO [NT AUTHORITY\SYSTEM];
   ```
4. `net stop MSSQLSERVER`, then `Start-ClusterResource '<SQLServerResourceName>'` — the cluster must be the one to start it.
5. Prevent recurrence: CIS/hardening scripts that drop `NT AUTHORITY\SYSTEM` must exclude FCIs (and AG replicas, which use it too).
</details>

<details><summary>Playbook C — Tune health detection after a real stall (temporary)</summary>

```sql
SELECT * FROM sys.dm_os_cluster_properties;
ALTER SERVER CONFIGURATION SET FAILOVER CLUSTER PROPERTY HealthCheckTimeout = 120000;
ALTER SERVER CONFIGURATION SET FAILOVER CLUSTER PROPERTY VerboseLogging = 1;   -- extra diag logs in LOG folder
```
- Keep `FailureConditionLevel` at 3 unless the DBA owns the decision; lowering it trades availability for fewer false positives.
- Rollback: `HealthCheckTimeout = 60000`, `VerboseLogging = 0`.
- Follow up on the cause: memory dumps (non-yielding scheduler), IO 833 warnings, antivirus scanning DB/log folders.
</details>

<details><summary>Playbook D — Add a DNN to an Azure VM FCI (replace VNN + load balancer)</summary>

Prereqs: SQL 2019 CU8 / 2017 CU25 / 2016 SP3+, Windows Server 2016+, all clients able to use `MultiSubnetFailover=True`.
```powershell
Add-ClusterResource -Name '<dnnResourceName>' -ResourceType 'Distributed Network Name' -Group '<FCIRole>'
Get-ClusterResource -Name '<dnnResourceName>' | Set-ClusterParameter -Name DnsName -Value '<DNNName>'
Start-ClusterResource -Name '<dnnResourceName>'
# Match DNN possible owners to the SQL resource's
$owners = (Get-ClusterOwnerNode -Resource '<SQLServerResourceName>').OwnerNodes.Name
Get-ClusterResource '<dnnResourceName>' | Set-ClusterOwnerNode -Owners $owners
# Restart SQL so it listens via the DNN
Stop-ClusterResource '<SQLServerResourceName>'; Start-ClusterGroup '<FCIRole>'
```
- Keep the client name: rename the VNN first (FCI rename procedure), then set the DNN `DnsName` to the old name.
- Optionally move the now-unused VIP to an APIPA address so Azure can't hand it to another NIC: `Get-ClusterResource '<IPResource>' | Set-ClusterParameter -Multiple @{Address='169.254.1.1';SubnetMask='255.255.0.0';OverrideAddressMatch=1;EnableDhcp=0}`.
- **Never delete the VNN.** Rollback: change clients back, `Stop-ClusterResource '<dnnResourceName>'; Remove-ClusterResource '<dnnResourceName>' -Force`.
</details>

<details><summary>Playbook E — Patch an FCI with minimal downtime (rolling)</summary>

1. Don't edit possible owners by hand; SQL setup handles them. Patch passive nodes first, one at a time.
2. `Move-ClusterGroup '<FCIRole>' -Node <patchedNode>` — SQL runs script upgrade on startup (watch ERRORLOG for "Script level upgrade ... completed").
3. Patch the former owner. Optionally move back.
4. Verify `SELECT SERVERPROPERTY('ProductUpdateLevel'), @@VERSION;` and the registry `PatchLevel` on every node match.
- Script-upgrade failure (912/3417) → leave role offline, escalate to DBA (trace flag 902 bypass is a DBA call).
</details>

---
## Evidence Pack

```powershell
# Run elevated on any FCI node. Writes to C:\Temp\FCI-Evidence-<timestamp>
$role = '<FCIRole>'
$out  = "C:\Temp\FCI-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null
Get-ClusterNode | Select-Object Name, State, DynamicWeight | Export-Csv "$out\nodes.csv" -NoTypeInformation
Get-ClusterQuorum | Format-List * | Out-File "$out\quorum.txt"
Get-ClusterGroup $role | Format-List * | Out-File "$out\group.txt"
Get-ClusterGroup $role | Get-ClusterResource | ForEach-Object {
  [pscustomobject]@{
    Resource = $_.Name; Type = $_.ResourceType.Name; State = $_.State; Owner = $_.OwnerNode
    Dependency = (Get-ClusterResourceDependency -Resource $_.Name).DependencyExpression
    PossibleOwners = (($_ | Get-ClusterOwnerNode).OwnerNodes.Name -join ',')
  } } | Export-Csv "$out\resources.csv" -NoTypeInformation
Get-ClusterGroup $role | Get-ClusterResource | Get-ClusterParameter | Export-Csv "$out\resource-params.csv" -NoTypeInformation
Get-ClusterSharedVolume -ErrorAction SilentlyContinue | Select-Object Name, State, OwnerNode | Export-Csv "$out\csv.csv" -NoTypeInformation
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-FailoverClustering'; StartTime=(Get-Date).AddDays(-2)} -ErrorAction SilentlyContinue |
  Where-Object { $_.Level -le 3 } | Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\cluster-events.csv" -NoTypeInformation
Get-ClusterLog -Destination $out -TimeSpan 120 -UseLocalTime | Out-Null
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
"Evidence: $out.zip  — also attach ERRORLOG + ERRORLOG.1 from the -e path on the clustered disk."
```
For a richer, scripted check (build per node, DNN/VNN DNS, health properties) run `../Scripts/Get-SQLFCIHealth.ps1`.

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| List FCI SQL resources | `Get-ClusterResource \| ? { $_.ResourceType.Name -eq 'SQL Server' }` |
| Role contents | `Get-ClusterGroup '<FCIRole>' \| Get-ClusterResource` |
| SQL dependencies | `Get-ClusterResourceDependency '<SQLServerResourceName>'` |
| Add a disk dependency | `Set-ClusterResourceDependency -Resource <r> -Dependency "<expr> and [<disk>]"` |
| Possible owners | `Get-ClusterOwnerNode -Resource '<r>'` |
| SQL resource private props | `Get-ClusterResource '<r>' \| Get-ClusterParameter` |
| Planned failover | `Move-ClusterGroup '<FCIRole>' -Node <node>` |
| Failover policy | `Get-ClusterGroup '<FCIRole>' \| fl FailoverThreshold, FailoverPeriod, AutoFailbackType` |
| Cluster log | `Get-ClusterLog -Destination C:\Temp -TimeSpan 60 -UseLocalTime` |
| CSV state | `Get-ClusterSharedVolumeState` |
| Health props (T-SQL) | `SELECT * FROM sys.dm_os_cluster_properties;` |
| Nodes seen by SQL | `SELECT * FROM sys.dm_os_cluster_nodes;` |
| Valid storage paths | `SELECT * FROM sys.dm_io_cluster_valid_path_names;` |
| Change health timeout | `ALTER SERVER CONFIGURATION SET FAILOVER CLUSTER PROPERTY HealthCheckTimeout = 60000;` |
| Create DNN | `Add-ClusterResource -Name <n> -ResourceType 'Distributed Network Name' -Group '<FCIRole>'` |

---
## 🎓 Learning Pointers
- FCI failover is "detect + move + recover" — the recovery part depends on open transactions, so a slow failover isn't always a cluster problem. — [Always On FCI overview](https://learn.microsoft.com/sql/sql-server/failover-clusters/windows/always-on-failover-cluster-instances-sql-server)
- `FailureConditionLevel` and `HealthCheckTimeout` are the dials for automatic failover sensitivity; set them via T-SQL so SQL and WSFC agree. — [Failover policy for FCIs](https://learn.microsoft.com/sql/sql-server/failover-clusters/windows/failover-policy-for-failover-cluster-instances) and [Configure HealthCheckTimeout](https://learn.microsoft.com/sql/sql-server/failover-clusters/windows/configure-healthchecktimeout-property-settings)
- The resource DLL logs in as `NT AUTHORITY\SYSTEM`; hardening that removes it breaks FCIs and AGs alike.
- On Azure VMs choose between VNN + load balancer, multi-subnet VNN, or DNN; DNN is simplest but client-dependent. — [Configure a DNN for an FCI](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/failover-cluster-instance-distributed-network-name-dnn-configure), [FCI with DNN interoperability](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/failover-cluster-instance-dnn-interoperability)
- S2D/CSV storage removes per-disk dependencies but adds CSV redirected-IO and storage repair jobs as new failure modes. — [FCI with Storage Spaces Direct (Azure VM)](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/failover-cluster-instance-storage-spaces-direct-manually-configure)
- Related: `SQLAGListener-A.md` (MultiSubnetFailover driver matrix), `FailoverClustering-A.md`, `ClusterADObjects-A.md`.
