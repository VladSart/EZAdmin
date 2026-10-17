# SQL Server Failover Cluster Instance (FCI) Won't Start / Won't Fail Over — Hotfix Runbook (Mode B: Ops)
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

**Scope:** a SQL Server **Always On Failover Cluster Instance** (one SQL instance, shared storage, owned by one node at a time) whose role is `Failed`/`Partial Online`, will not move to another node, fails over repeatedly ("ping-pong"), or is online but clients can't reach it by its network name (VNN or DNN). For **availability group** listeners use `SQLAGListener-B.md`. For quorum/node membership use `FailoverClustering-B.md`. For CNO/VCO computer-object permission errors (Event 1194/1207) use `ClusterADObjects-B.md`. Database-level corruption and query performance are DBA territory and out of scope.

Run on any cluster node, elevated (FailoverClusters module ships with the Failover Clustering feature):

```powershell
# 1. Every FCI role: owner, state, and the SQL resource state
Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'SQL Server' } |
  Select-Object Name, State, OwnerNode, @{n='Role';e={$_.OwnerGroup.Name}} | Format-Table -AutoSize

# 2. Everything inside the FCI role and its state (disks, name, IP/DNN, SQL, Agent)
Get-ClusterGroup -Name '<FCIRole>' | Get-ClusterResource |
  Select-Object Name, @{n='Type';e={$_.ResourceType.Name}}, State, OwnerNode | Format-Table -AutoSize

# 3. What the SQL Server resource is waiting on
Get-ClusterResourceDependency -Resource '<SQLServerResourceName>'

# 4. Recent cluster events for resource / role failures (last 24 h)
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-FailoverClustering'; Id=1069,1205,1254,1230,1135; StartTime=(Get-Date).AddHours(-24)} -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, Message | Format-List
```

> `<FCIRole>` is normally `SQL Server (MSSQLSERVER)` for a default instance or `SQL Server (<InstanceName>)` for a named instance. `<SQLServerResourceName>` is the name from command 1 (often identical, e.g. `SQL Server (MSSQLSERVER)` or `SQL Server`).

| Finding | Interpretation | Do this |
|---|---|---|
| A **Physical Disk** / **Cluster Disk** resource is `Failed` or `Offline`, SQL resource `Offline` | Storage missing on this node (path/LUN masking/iSCSI/S2D) — SQL correctly refuses to start without its disks | **Fix 1** |
| Disks + name `Online`, **SQL Server** resource `Failed`, Event 1069 for SQL | SQL service itself fails to start: service account password, master/tempdb path, startup parameter, or a database file on a disk the resource does not depend on | **Fix 2** |
| SQL comes online, then fails within ~1–2 min on every node, Event 1069 / 1230 repeatedly | `sp_server_diagnostics` health check or `IsAlive` timing out (`HealthCheckTimeout`/`FailureConditionLevel`), or SQL can't log in to itself (`NT AUTHORITY\SYSTEM` / service SID login removed) | **Fix 3** |
| Role in `Failed` state, Event **1254** ("exceeded its failover threshold") | Failover threshold hit (default `n-1` in 6 h) — cluster stopped retrying; underlying cause is one of the rows above | Fix the underlying row, then **Fix 4** |
| Role will not move to node X; Move → "no suitable node" / greys out node | Node X not a **possible owner** of SQL/disk/name resource, or not an FCI node (SQL binaries never installed via *Add node*) | **Fix 5** |
| Role `Online`, clients time out by name; **Network Name** `Online` | DNS stale/permission (VCO), client using IP/old name, or Azure VM with VNN but no load balancer | **Fix 6** |
| Azure VM FCI with a **Distributed Network Name** (`Type` = `Distributed Network Name`) and clients fail ~50% of attempts | Client connection string lacks `MultiSubnetFailover=True`, or DNN possible owners include non-FCI nodes | **Fix 6** |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Client connects to <FCI-name>[\<instance>],<port>
 └── DNS for <FCI-name> resolves to the current owner
      ├── VNN: one A record → virtual IP (IP Address resource Online on the owner)
      │     (Azure VM single subnet: VNN needs an Azure Load Balancer + probe port)
      └── DNN (Azure VM, SQL 2019 CU8 / 2017 CU25 / 2016 SP3+): A records for all possible-owner
            node IPs; client MUST use MultiSubnetFailover=True; VNN still exists underneath
 └── SQL Server resource Online on owner node
      ├── Depends on (AND): Network Name (VNN) resource Online
      │     └── Depends on: IP Address resource(s) (OR across subnets for multi-subnet FCI)
      ├── Depends on (AND): every disk that holds system DBs, user DBs, tempdb (if shared), logs
      │     ├── Physical Disk / Cluster Disk resources Online (SAN, iSCSI, shared VHDX)
      │     └── or Cluster Shared Volume (S2D / CSV — no per-disk dependency needed; path C:\ClusterStorage\...)
      ├── SQL Server service (MSSQL$<inst> / MSSQLSERVER) can start on this node
      │     ├── Binaries installed on this node via "Add node" (same version/CU on all nodes)
      │     ├── Service account valid, password current, "Log on as a service"
      │     └── Startup params (-d master, -l mastlog, -e errorlog) point at clustered disk paths
      └── Health detection succeeds (SQL Server resource DLL → sp_server_diagnostics)
            ├── Resource DLL can log in (NT AUTHORITY\SYSTEM or service SID login exists)
            └── Response within HealthCheckTimeout (default 60 000 ms) at FailureConditionLevel (default 3)
 └── Node is a possible owner of every resource in the role + role failover threshold not exceeded
 └── Cluster itself healthy: quorum, node Up, cluster network for the IP's subnet
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm cluster health first.**
   ```powershell
   Get-ClusterNode | Format-Table Name, State, DynamicWeight
   Get-ClusterQuorum | Format-List *
   ```
   Expected: all FCI nodes `Up`. If a node is `Down`/`Paused` or quorum is lost → stop, use `FailoverClustering-B.md`.

2. **Check storage visible to the owner.**
   ```powershell
   Get-ClusterGroup '<FCIRole>' | Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'Physical Disk' } | Format-Table Name, State, OwnerNode
   Get-ClusterSharedVolume | Format-Table Name, State, OwnerNode
   ```
   Expected: every disk `Online`. A `Failed` disk = storage path problem (**Fix 1**). CSV `Online` but in redirected access → check `Get-ClusterSharedVolumeState`.

3. **Check the SQL resource's dependency expression.**
   ```powershell
   Get-ClusterResourceDependency -Resource '<SQLServerResourceName>'
   ```
   Expected: `[<NetworkName>] and [Cluster Disk 1] and [Cluster Disk 2] ...` — **every** non-CSV disk that holds a database file. A disk missing here means SQL can start before that disk and databases on it go `RECOVERY_PENDING`, or (since SQL 2012) the database is refused (error 5184).

4. **Read why SQL itself failed.** The cluster only says "failed"; the SQL errorlog says why:
   ```powershell
   $p = (Get-ClusterResource '<SQLServerResourceName>' | Get-ClusterParameter -Name InstanceName).Value
   Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\*\MSSQLServer\Parameters" -ErrorAction SilentlyContinue |
     Select-Object PSPath, SQLArg0, SQLArg1, SQLArg2
   Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName="MSSQL`$$p",'MSSQLSERVER'; Level=1,2; StartTime=(Get-Date).AddHours(-24)} -ErrorAction SilentlyContinue |
     Select-Object -First 20 TimeCreated, Id, Message | Format-List
   ```
   The `-e` path in `SQLArgN` is the ERRORLOG on the clustered disk — open the newest `ERRORLOG` there. Typical lines: `18456 Login failed for user 'NT AUTHORITY\SYSTEM'`, `17113 Error 2(The system cannot find the file specified.) occurred while opening file 'X:\...\master.mdf'`, `17182 TDSSNIClient initialization failed`, `5184 Cannot use file ... because it was originally formatted with ... not dependent`.

5. **Check failure policy and possible owners.**
   ```powershell
   Get-ClusterGroup '<FCIRole>' | Format-List Name, FailoverThreshold, FailoverPeriod, AutoFailbackType
   Get-ClusterGroup '<FCIRole>' | Get-ClusterResource | ForEach-Object {
     [pscustomobject]@{ Resource=$_.Name; PossibleOwners=(($_ | Get-ClusterOwnerNode).OwnerNodes.Name -join ',') } }
   ```
   Expected: possible owners identical across SQL, disks and name; failover threshold default is `4294967295` (= use `n-1`) with `FailoverPeriod` 6 h.

6. **Generate a cluster log covering the failure** (essential for escalation):
   ```powershell
   Get-ClusterLog -Destination C:\Temp -TimeSpan 60 -UseLocalTime
   ```
   Search each `<node>_cluster.log` for `[RES] SQL Server <` and `[RCM] rcm::RcmResource::HandleFailure` — the resource DLL lines show `IsAlive`/`sp_server_diagnostics` results and component states (system, resource, query_processing, io_subsystem, events).

---
## Common Fix Paths

<details><summary>Fix 1 — Disk resource failed / offline on the owner</summary>

```powershell
# Which node can actually see the disk? Try bringing it online on its own first
Start-ClusterResource -Name '<Cluster Disk N>'
# If it fails, move the whole role to a node that sees storage
Move-ClusterGroup -Name '<FCIRole>' -Node '<GoodNode>'
# Check path/MPIO/iSCSI on the bad node
Get-Disk | Format-Table Number, FriendlyName, OperationalStatus, IsClustered, IsOffline
Get-IscsiSession -ErrorAction SilentlyContinue | Format-Table TargetNodeAddress, IsConnected
```
- S2D/CSV: `Get-StorageJob`, `Get-VirtualDisk | Format-Table FriendlyName, HealthStatus, OperationalStatus` — a degraded/detached virtual disk is a storage escalation, not a SQL one.
- **Do not** run `Clear-ClusterDiskReservation` or reformat a cluster disk without a storage owner on the call.
</details>

<details><summary>Fix 2 — SQL Server resource fails to start (service-level)</summary>

1. Service account password changed → update it with **SQL Server Configuration Manager on every node** (not services.msc — Config Manager also fixes ACLs/service SID). Rotate during a maintenance window.
2. Missing database file / wrong path in startup params (errorlog 17113/17204) → confirm the clustered drive letter or CSV path matches `SQLArg0..2`; drive letter changes on a disk break every node.
3. Database on a disk the resource doesn't depend on (error 5184 / DB `RECOVERY_PENDING` after failover) → add the dependency (online-safe, takes effect next start):
   ```powershell
   # Inspect, then append the disk with AND
   $r = '<SQLServerResourceName>'
   $expr = (Get-ClusterResourceDependency -Resource $r).DependencyExpression
   Set-ClusterResourceDependency -Resource $r -Dependency "$expr and [<Cluster Disk N>]"
   ```
   Rollback: `Set-ClusterResourceDependency -Resource $r -Dependency "<original expression>"`.
4. Start manually once the cause is fixed: `Start-ClusterResource -Name '<SQLServerResourceName>'`.
5. To read a startup failure interactively without the cluster fighting you: take the role offline, then on the owner run `net start MSSQLSERVER /f /m` (or `net start MSSQL$<inst> /f /m`) — **never** bring it online outside the cluster when another node could also own the disks.
</details>

<details><summary>Fix 3 — SQL starts then fails health checks (ping-pong)</summary>

```powershell
# Check the health-detection settings on the SQL resource (read-only)
Get-ClusterResource '<SQLServerResourceName>' | Get-ClusterParameter |
  Where-Object Name -in 'VirtualServerName','InstanceName','HealthCheckTimeout','FailureConditionLevel','VerboseLogging' |
  Format-Table Name, Value
```
- `18456 ... NT AUTHORITY\SYSTEM` in errorlog → someone dropped the login used by the resource DLL. Recreate (T-SQL, as sysadmin, via `-m` single-user or DAC if needed):
  ```sql
  CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS;   -- if missing
  GRANT VIEW SERVER STATE TO [NT AUTHORITY\SYSTEM];
  GRANT CONNECT SQL TO [NT AUTHORITY\SYSTEM];
  ```
- Health check timeouts under real load (big memory dumps, IO stalls) → raise the timeout temporarily, find the IO cause:
  ```sql
  ALTER SERVER CONFIGURATION SET FAILOVER CLUSTER PROPERTY HealthCheckTimeout = 120000;  -- ms, default 60000
  -- FailureConditionLevel default 3; lowering to 2 makes failover LESS sensitive
  ALTER SERVER CONFIGURATION SET FAILOVER CLUSTER PROPERTY FailureConditionLevel = 3;
  ```
  Rollback: set `HealthCheckTimeout = 60000`. Raising timeouts hides problems — open a DBA follow-up.
</details>

<details><summary>Fix 4 — Role stuck Failed after hitting the failover threshold (Event 1254)</summary>

```powershell
Get-ClusterGroup '<FCIRole>' | Format-List FailoverThreshold, FailoverPeriod
# After fixing the cause, bring it online on the intended node
Start-ClusterGroup -Name '<FCIRole>'
# or
Move-ClusterGroup -Name '<FCIRole>' -Node '<Node>'
```
Only change the threshold if the business accepts more automatic flapping: `(Get-ClusterGroup '<FCIRole>').FailoverThreshold = 3`.
</details>

<details><summary>Fix 5 — Role won't move to a node</summary>

```powershell
# Is the SQL instance actually installed on that node? (Add node was run)
Invoke-Command -ComputerName '<Node>' { Get-Service -Name 'MSSQLSERVER','MSSQL$*' -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType }
# Possible owners for each resource in the role
Get-ClusterGroup '<FCIRole>' | Get-ClusterResource | ForEach-Object { "{0}: {1}" -f $_.Name, (($_ | Get-ClusterOwnerNode).OwnerNodes.Name -join ',') }
# Add the node back as a possible owner (SQL setup normally manages this — prefer re-running Add node)
Get-ClusterResource '<SQLServerResourceName>' | Set-ClusterOwnerNode -Owners '<Node1>','<Node2>'
```
- No service on the node → run SQL Server setup **Add node to a SQL Server failover cluster** on it (same version + CU), don't hand-edit owners.
- Service present but SQL **CU/version differs** → patch to match before failing over (a lower-build node can't open upgraded databases).
</details>

<details><summary>Fix 6 — Online, but clients can't connect by name (VNN/DNN)</summary>

```powershell
# What name and IP(s) does the role publish?
Get-ClusterGroup '<FCIRole>' | Get-ClusterResource | Where-Object { $_.ResourceType.Name -in 'Network Name','Distributed Network Name','IP Address' } |
  ForEach-Object { $_ | Get-ClusterParameter -Name DnsName, Address -ErrorAction SilentlyContinue } | Format-Table ClusterObject, Name, Value
# From a client subnet:
Resolve-DnsName '<fci-fqdn>' -Type A -DnsOnly
Test-NetConnection '<fci-fqdn>' -Port <port>
```
- VNN record stale/missing + Event 1196 → `ClusterADObjects-B.md` Fix 5 (VCO rights on the DNS record).
- Named instance with dynamic port and UDP 1434 blocked → set a static port in Configuration Manager or open UDP 1434 to the FCI.
- **Azure VM single-subnet VNN with no load balancer** → clients will never reach it reliably. Either add an Azure Load Balancer + probe port, or create a **DNN** (SQL 2019 CU8 / 2017 CU25 / 2016 SP3+, Windows Server 2016+):
  ```powershell
  Add-ClusterResource -Name '<dnnResourceName>' -ResourceType 'Distributed Network Name' -Group '<FCIRole>'
  Get-ClusterResource -Name '<dnnResourceName>' | Set-ClusterParameter -Name DnsName -Value '<DNNName>'
  Start-ClusterResource -Name '<dnnResourceName>'
  ```
  Then trim DNN possible owners to FCI nodes only, restart the SQL resource, and change client strings to `Data Source=<DNNName>;MultiSubnetFailover=True`. **Do not delete the VNN** — it's still part of the FCI. Rollback: `Stop-ClusterResource` + `Remove-ClusterResource '<dnnResourceName>'`.
- DNN exists, clients fail intermittently → client lacks `MultiSubnetFailover=True` or uses a legacy driver (SQLOLEDB / "SQL Server" ODBC) — see `SQLAGListener-B.md` Fix 1/Fix 4 driver matrix.
</details>

---
## Escalation Evidence

```
Cluster name / FCI role:           ______________________  (SQL Server (<instance>))
SQL version + CU on each node:     Node1 ______  Node2 ______  Node3 ______
Connection point:                  VNN / DNN / VNN+Azure LB     Name: ____________
Storage type:                      SAN/iSCSI / S2D-CSV / shared VHDX / Azure shared disk / Premium file share
Symptom:                           won't start / won't fail over / ping-pong / clients can't connect
Resource that fails first:         ______________________   Event IDs: 1069 / 1205 / 1254 / 1230 / other ____
SQL errorlog lines at failure:     ______________________________________________
Dependency expression (SQL res):   ______________________________________________
Possible owners consistent?        Y / N   (differences: ______________)
HealthCheckTimeout / FCL:          ______ / ______
Recent changes (patch, password, disk added, node added, DNS):  ______________________
Attached: Get-ClusterLog (60 min, all nodes), ERRORLOG + ERRORLOG.1, Get-SQLFCIHealth CSV
```

---
## 🎓 Learning Pointers
- The cluster only knows SQL "failed"; the **SQL errorlog on the clustered disk** tells you why. Find it from the `-e` startup parameter before guessing. — [Failover cluster instance overview](https://learn.microsoft.com/sql/sql-server/failover-clusters/windows/always-on-failover-cluster-instances-sql-server)
- A database on a disk that isn't in the SQL resource's dependency list will be refused or left in recovery after failover. Add the dependency rather than moving files. — [FCI storage and dependencies](https://learn.microsoft.com/sql/sql-server/failover-clusters/windows/always-on-failover-cluster-instances-sql-server). Missing FCI nodes are added with SQL setup, not by editing owners. — [Add or remove nodes in an FCI](https://learn.microsoft.com/sql/sql-server/failover-clusters/install/add-or-remove-nodes-in-a-sql-server-failover-cluster-setup)
- Ping-pong failovers are usually health detection (`sp_server_diagnostics`, `HealthCheckTimeout`, `FailureConditionLevel`), not storage. Read the `[RES] SQL Server` lines in the cluster log. — [Failover policy for FCIs](https://learn.microsoft.com/sql/sql-server/failover-clusters/windows/failover-policy-for-failover-cluster-instances)
- On Azure VMs, a single-subnet VNN needs a load balancer; a **DNN** removes it but forces `MultiSubnetFailover=True` and keeps the VNN underneath. — [Configure a DNN for an FCI](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/failover-cluster-instance-distributed-network-name-dnn-configure)
- Change the SQL service account password with **SQL Server Configuration Manager on each node**, never services.msc. — [Configure Windows service accounts and permissions](https://learn.microsoft.com/sql/database-engine/configure-windows/configure-windows-service-accounts-and-permissions)
- Deep dive and playbooks: `SQLFCI-A.md`; evidence collection: `../Scripts/Get-SQLFCIHealth.ps1`.
