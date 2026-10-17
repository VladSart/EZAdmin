# SQL Server AG Listener (Multi-Subnet) Client Connectivity — Reference Runbook (Mode A: Deep Dive)
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

- SQL Server 2016+ Always On availability groups on a Windows Server Failover Cluster (WSFC). Covers listeners that use a classic **Virtual Network Name (VNN)** with per-subnet IP resources, and **Distributed Network Name (DNN)** listeners on Azure VMs.
- Focus is the client-to-listener path: cluster network-name/IP resources, DNS registration, client driver behaviour, and failover reconnect time.
- **Out of scope:** replica synchronisation health, seeding, and AG failover policy (DBA domain). CNO/VCO AD permissions are in `ClusterADObjects-A.md`. Quorum, node, and network health are in `FailoverClustering-A.md`. Read-scale (clusterless) AGs have no listener in this sense.
- You have local admin on a cluster node, the FailoverClusters and DnsServer RSAT modules, and VIEW SERVER STATE on SQL.

---
## How It Works

<details><summary>Full architecture</summary>

### The listener is a cluster network-name resource

When a DBA runs `CREATE/ALTER AVAILABILITY GROUP ... ADD LISTENER` (or uses SSMS), SQL Server calls into WSFC and creates, inside the AG's cluster role:

```
Cluster role "<AGName>"
 ├── SQL Server Availability Group resource  "<AGName>"
 │      depends on ──► Network Name resource "<AGName>_<ListenerName>"
 └── Network Name "<AGName>_<ListenerName>"   (DnsName = <ListenerName>, VCO in AD)
        depends on ──► [IP <subnet A>]  OR  [IP <subnet B>]  OR ...
```

- **One static IP per subnet.** Each IP resource is bound to the cluster network for that subnet. A node can only bring online the IP for a subnet it's attached to, so when the primary moves to site B, the site-A IP goes Offline and the site-B IP goes Online.
- The **OR dependency** lets the name come online with just one IP. Offline IPs are the steady state, not a fault.
- SQL Server listens on the listener port on whichever listener IP is online on the primary node. This is in addition to the instance's own IP/port.

### DNS registration: `RegisterAllProvidersIP`

The network-name resource registers A records under its VCO identity (secure dynamic update in AD-integrated zones):

| `RegisterAllProvidersIP` | DNS content | Client experience |
|---|---|---|
| **1** (set by SQL when the listener is created) | One A record **per IP resource, online or not** | MSF-aware clients: instant. Non-MSF clients: pick the first record. If it's the offline subnet, TCP connect waits ~21 s (Windows SYN retransmit) before trying the next, or the app's login timeout (often 15 s) fires first. That gives you an "every other connection fails" pattern because DNS round-robins the order |
| **0** | Only the **currently online** IP | All clients connect cleanly, but after failover the record changes. Clients keep using their cached answer until `HostRecordTTL` expires (default **1200 s**), plus AD replication between DNS servers, plus any forwarder cache |

`HostRecordTTL` is the TTL stamped on the A records. Both parameters are read at resource online time, so a change only takes effect after the network-name resource is cycled (a short listener outage). `Update-ClusterNetworkNameResource` forces a re-registration but doesn't delete records for IPs no longer registered. Those must be removed manually when moving 1 → 0.

### Client side: `MultiSubnetFailover`

With `MultiSubnetFailover=True` (MSF), the driver resolves the name, opens TCP connections to **all** returned IPs **in parallel**, and keeps the first that completes. It also uses more aggressive internal retry timing, so it improves failover reconnects even on single-subnet AGs. Driver support:

| Driver / Provider | MSF support |
|---|---|
| `System.Data.SqlClient` (.NET Framework 4.5+) / `Microsoft.Data.SqlClient` | Yes: `MultiSubnetFailover=True` |
| ODBC Driver 11/13/17/18 for SQL Server | Yes: `MultiSubnetFailover=Yes` |
| Microsoft OLE DB Driver (MSOLEDBSQL) | Yes |
| SQL Server Native Client 11 (deprecated) | Yes |
| Microsoft JDBC 4.0+ | Yes: `multiSubnetFailover=true` |
| Legacy `SQL Server` ODBC (sqlsrv32.dll), `SQLOLEDB` | **No** |

**Transparent Network IP Resolution (TNIR).** In `System.Data.SqlClient` on .NET Framework 4.6.1+ (and `Microsoft.Data.SqlClient` on .NET Framework), when MSF is not set and the name resolves to multiple IPs, the driver tries the first IP with a short timeout (~500 ms) and then falls back to trying them in parallel. This is why some .NET apps "just work" against a multi-IP listener while ODBC/Java apps on the same network don't. TNIR is ignored when MSF is set, and it doesn't exist in ODBC/JDBC. Don't rely on it; set MSF explicitly.

### Distributed Network Name (DNN) listeners

On Azure VMs, a VNN listener in a single subnet needs an Azure Load Balancer, because Azure doesn't honour gratuitous ARP for floating IPs. The alternatives are a **multi-subnet** deployment (each replica in its own subnet, VNN with per-subnet IPs, no LB) or a **DNN** listener (SQL 2016 SP3 / 2017 CU25 / 2019 CU8+, Windows Server 2016+).

A DNN has **no IP resources**. DNS returns the node IPs of **every** replica, and SQL listens on a dedicated DNN port. So:
- the connection string must include the **DNN port** and **`MultiSubnetFailover=True`**. Without MSF, clients try a secondary's IP and time out or get redirected wrongly.
- `sys.availability_group_listeners.is_distributed_network_name = 1` identifies it.
- Some features have DNN interoperability caveats (for example, distributed AGs, replication, linked servers). Check the DNN interoperability doc before switching.

### Why failover feels slower than it is

```
Primary fails ──► AG resource moves (sec) ──► IP B online, IP A offline (sec)
                                          └─► SQL accepts on IP B (sec)
Client with MSF:            reconnects in seconds (parallel race finds IP B)
Client without MSF, RAPI=1: 50% chance it tries IP A first ──► ~21 s TCP timeout per attempt
Client without MSF, RAPI=0: waits DNS update + AD replication + TTL (≤1200 s default) + local cache
```
</details>

---
## Dependency Stack

```
[7] Application connection string  (server,port; MultiSubnetFailover; ApplicationIntent; Database)
[6] Client driver                  (MSF-capable? TNIR? encryption defaults)
[5] Client DNS resolution          (resolver cache, forwarders, conditional forwarders, TTL)
[4] DNS server zone                (A records per IP / only online IP; VCO owns records; AD replication)
[3] Cluster listener resource      (Network Name; RegisterAllProvidersIP; HostRecordTTL; OR-dependency on IPs)
[2] Cluster IP resources/networks  (one IP per subnet; cluster network Role ≠ None; no IP conflicts)
[1] AG role + SQL instance         (primary replica online; listener port bound; firewall open on all replicas)
[0] WSFC + AD                      (quorum, CNO/VCO objects & rights → ClusterADObjects / FailoverClustering)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Connections fail or succeed alternately, ~15–21 s "timeout expired" / "network-related or instance-specific error" | RAPI=1 + client without MSF | `Resolve-DnsName` returns >1 IP; connection string lacks MSF |
| Works from .NET apps, fails from ODBC/Java/SSIS on same host | TNIR masking the problem for .NET only | Compare connection strings and drivers |
| After failover, apps down for ~20 min, then recover on their own | RAPI=0 + HostRecordTTL 1200 | `Get-ClusterParameter HostRecordTTL` |
| After failover, some sites recover and others don't | DNS replication or forwarder caching between sites | `Resolve-DnsName -Server <each DNS server>` |
| Only ever connects when primary is in site A | Firewall blocks listener port on site B replicas, or site B IP missing from listener | `Test-NetConnection` per IP; SQL listener IP DMV |
| Listener won't come online after failover to site B | No cluster network / wrong subnet for site B IP; IP conflict | `Get-ClusterNetwork`; IP resource params; ping test |
| DNS still shows old IP even after `Update-ClusterNetworkNameResource` | VCO can't update the existing record (record owned by another principal) | Cluster Event 1196/1257 → ClusterADObjects |
| Read-only routing never hits secondaries | No `Database=` in connection string, or routing lists not configured | `sys.availability_read_only_routing_lists` |
| Azure VM AG: clients intermittently connect to a secondary / time out | DNN listener without MSF, or missing DNN port | `is_distributed_network_name`; connection string |
| Azure VM single-subnet VNN: listener unreachable from other VNETs | Load balancer probe/rule missing or wrong probe port | ILB health probe status |

---
## Validation Steps

1. **Listener definition in SQL**
   ```sql
   SELECT ag.name AS ag, l.dns_name, l.port, l.is_distributed_network_name, ip.ip_address, ip.ip_subnet_mask, ip.state_desc
   FROM sys.availability_groups ag
   JOIN sys.availability_group_listeners l ON ag.group_id = l.group_id
   LEFT JOIN sys.availability_group_listener_ip_addresses ip ON l.listener_id = ip.listener_id;
   ```
   Good: one IP per subnet, exactly one ONLINE. Bad: a subnet missing (site can't host the listener), or several ONLINE.

2. **Cluster parameters**
   ```powershell
   Get-ClusterResource '<AGName>_<ListenerName>' | Get-ClusterParameter DnsName, RegisterAllProvidersIP, HostRecordTTL, PublishPTRRecords
   ```
   Good: values are a documented, deliberate choice. Bad: RAPI=0 with TTL 1200 (unintended).

3. **Dependency expression**
   ```powershell
   Get-ClusterResourceDependency '<AGName>_<ListenerName>'
   ```
   Good: `[IP A] or [IP B]`. Bad: `and`, which means the listener can never come online in a multi-subnet layout.

4. **Cluster networks**
   ```powershell
   Get-ClusterNetwork | Format-Table Name, Address, AddressMask, Role, State
   ```
   Good: every listener subnet is present with Role `ClusterAndClient` (3). Bad: Role `None` (0) or subnet missing.

5. **DNS from every DNS server clients use**
   ```powershell
   '<dns1>','<dns2>' | ForEach-Object { Resolve-DnsName '<listener-fqdn>' -Type A -Server $_ -DnsOnly | Select-Object @{n='Server';e={$_}}, IPAddress, TTL }
   ```
   Good: consistent answers that match the RAPI setting. Bad: disagreeing servers, which points to replication or caching.

6. **Port reachability per IP from a client subnet**: `Test-NetConnection <ip> -Port <port>`. Good: the online IP passes and offline IPs fail fast or time out (expected). Bad: the online IP fails.

7. **Client connection test with and without MSF**
   ```powershell
   Measure-Command { sqlcmd -S tcp:<listener-fqdn>,<port> -E -Q "SELECT 1" -l 30 }
   Measure-Command { sqlcmd -S tcp:<listener-fqdn>,<port> -E -M -Q "SELECT 1" -l 30 }
   ```
   Good: both fast (RAPI=0) or MSF fast (RAPI=1). A big delta confirms the MSF diagnosis.

---
## Troubleshooting Steps (by phase)

**Phase 1: Isolate the layer.** Connect directly to the primary instance name. If that also fails, it's firewall/SQL/service and outside this runbook. If only the listener fails, continue.

**Phase 2: Cluster resources.** Check that the listener name and exactly one IP are Online, the dependency is OR, and cluster networks exist for every subnet. Review System log events 1069 (resource failed), 1196/1257 (DNS), 1194/1207 (AD objects) and 1205 (group failed).

**Phase 3: DNS.** Count A records and compare them to RAPI. Check TTL. Query each DNS server and forwarder. When RAPI=0, confirm the stale offline-subnet records were removed.

**Phase 4: Client.** Identify the driver (ODBC DSN, provider in the connection string, JDBC jar version) and confirm MSF and the explicit port. For .NET apps, note whether TNIR may be masking the issue. For SSIS/SSRS/linked servers, the connection is made by the service account's host using its own provider, so check the provider there.

**Phase 5: Failover behaviour.** In a change window, run a planned manual failover (`ALTER AVAILABILITY GROUP [<AG>] FAILOVER;` on the target secondary) and time the reconnect from a representative client of each driver type. Record the results in the CMDB.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standardise on MultiSubnetFailover across the estate</summary>

1. Inventory every connection string pointing at the listener: config files, ODBC DSNs (`Get-OdbcDsn` on app servers), SSIS project connections, SSRS data sources, linked servers (`sys.servers`), and Power BI gateway data sources.
2. Upgrade legacy drivers: `SQL Server` ODBC to ODBC Driver 18, `SQLOLEDB` to MSOLEDBSQL. Plan for ODBC 18 / MSOLEDBSQL 19 defaulting to encryption (`Encrypt=Yes`, strict certificate validation). Deploy a trusted cert on SQL or set `TrustServerCertificate=Yes` as a documented interim.
3. Add `MultiSubnetFailover=True/Yes` and an explicit `,port`.
4. Validate with a planned failover (Phase 5).
5. Only then consider leaving RAPI=1 permanently, which is the fastest failover configuration.

No server-side change, no outage. **Rollback:** revert connection strings.
</details>

<details><summary>Playbook 2 — Legacy-app listener (RAPI=0) alongside the default listener</summary>

When some apps can never set MSF (vendor-locked):

1. DBA adds a second listener to the same AG:
   ```sql
   ALTER AVAILABILITY GROUP [<AG>] ADD LISTENER N'<LegacyListener>' (WITH IP ((N'<ipA>', N'<maskA>'), (N'<ipB>', N'<maskB>')), PORT = <port>);
   ```
2. On the cluster:
   ```powershell
   $r = Get-ClusterResource '<AGName>_<LegacyListener>'
   $r | Set-ClusterParameter RegisterAllProvidersIP 0
   $r | Set-ClusterParameter HostRecordTTL 120
   Stop-ClusterResource $r; Start-ClusterResource $r; Start-ClusterGroup '<AGName>'
   $r | Update-ClusterNetworkNameResource
   ```
   Because the new listener is a dependency of the AG resource, cycling it may take the AG resource offline briefly. Schedule it.
3. Remove any stale offline-subnet A records for `<LegacyListener>` from DNS.
4. Point legacy apps at `<LegacyListener>`. Leave modern apps on the original listener.

**Rollback:** `ALTER AVAILABILITY GROUP [<AG>] REMOVE LISTENER N'<LegacyListener>';` after repointing apps.
</details>

<details><summary>Playbook 3 — Converting an existing listener from RAPI=1 to 0 (or back)</summary>

1. Change window. Notify app owners of a short outage on the listener name.
2. Run `Set-ClusterParameter` (RAPI + TTL), cycle the listener resource, `Start-ClusterGroup '<AGName>'`, then `Update-ClusterNetworkNameResource`.
3. **1 → 0:** remove the A records for offline subnets on the DNS server (`Remove-DnsServerResourceRecord`). They persist otherwise.
4. **0 → 1:** confirm all subnet records appear after the update. If they don't, check VCO record permissions (Event 1196).
5. Run `Clear-DnsClientCache` on key app servers, then test.

**Rollback:** reverse the parameter values and repeat steps 2–5.
</details>

<details><summary>Playbook 4 — Adding a new site/subnet to an existing listener</summary>

1. Confirm the new subnet appears in `Get-ClusterNetwork` with Role 3. Add a node in that subnet to the cluster first.
2. DBA adds the replica, then the IP: `ALTER AVAILABILITY GROUP [<AG>] MODIFY LISTENER N'<Listener>' (ADD IP (N'<ipC>', N'<maskC>'));`
3. Verify the dependency is now `[IP A] or [IP B] or [IP C]`.
4. With RAPI=1, a new A record appears at the next registration (run `Update-ClusterNetworkNameResource`).
5. Open the listener port in the firewall on the new replica. Test with a planned failover to that site.

**Rollback:** `MODIFY LISTENER` can only *add* IPs. To remove one, fail back to an existing site, take the unwanted IP resource offline, remove it from the listener's dependency expression in Failover Cluster Manager and delete it, then confirm `sys.availability_group_listener_ip_addresses` no longer lists it. If SQL and the cluster disagree afterwards, drop and recreate the listener in a change window.
</details>

<details><summary>Playbook 5 — Azure VM: choose VNN+LB, multi-subnet VNN, or DNN</summary>

- **Multi-subnet VNN** (recommended for new builds): each replica in its own subnet, no load balancer. Same RAPI/MSF rules as on-prem.
- **DNN**: no LB and no listener IPs, but every client **must** use MSF + the DNN port. Check feature interoperability first.
- **Single-subnet VNN + ILB**: legacy pattern. The listener IP is the ILB frontend, the probe port is set on the IP resource (`ProbePort`), and floating IP is enabled. A failing probe = listener unreachable.

To migrate a VNN to a DNN, create the DNN listener alongside, repoint clients (with MSF), then retire the VNN/LB.
</details>

---
## Evidence Pack

```powershell
# Run elevated on a cluster node. Output: C:\Temp\AGListenerEvidence_<timestamp>\
$ag   = '<AGName>'
$out  = "C:\Temp\AGListenerEvidence_$(Get-Date -Format yyyyMMdd_HHmmss)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

Get-Cluster | Select-Object Name, Domain | Export-Csv "$out\cluster.csv" -NoTypeInformation
Get-ClusterNode | Select-Object Name, State | Export-Csv "$out\nodes.csv" -NoTypeInformation
Get-ClusterNetwork | Select-Object Name, Address, AddressMask, Role, State | Export-Csv "$out\networks.csv" -NoTypeInformation
Get-ClusterGroup $ag | Get-ClusterResource | Select-Object Name, ResourceType, State, OwnerNode | Export-Csv "$out\ag-resources.csv" -NoTypeInformation
Get-ClusterGroup $ag | Get-ClusterResource | Where-Object { $_.ResourceType.Name -in 'Network Name','IP Address','Distributed Network Name' } |
  Get-ClusterParameter | Select-Object ClusterObject, Name, Value | Export-Csv "$out\name-ip-params.csv" -NoTypeInformation
Get-ClusterGroup $ag | Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'Network Name' } |
  ForEach-Object { [pscustomobject]@{ Resource=$_.Name; Dependency=(Get-ClusterResourceDependency $_).DependencyExpression } } |
  Export-Csv "$out\dependencies.csv" -NoTypeInformation
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-FailoverClustering'; Id=1069,1196,1205,1257; StartTime=(Get-Date).AddDays(-3)} -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, Message | Export-Csv "$out\cluster-events.csv" -NoTypeInformation
Get-ClusterLog -Destination $out -TimeSpan 120 -UseLocalTime | Out-Null
# Plus: Windows/Scripts/Get-SQLAGListenerHealth.ps1 -ClusterGroup $ag -ListenerFqdn <fqdn> -Port <port> -OutputPath $out
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Listener params | `Get-ClusterResource '<AG>_<L>' \| Get-ClusterParameter RegisterAllProvidersIP, HostRecordTTL` |
| Set RAPI / TTL | `Get-ClusterResource '<AG>_<L>' \| Set-ClusterParameter RegisterAllProvidersIP 0` |
| Apply (outage) | `Stop-ClusterResource '<AG>_<L>'; Start-ClusterResource '<AG>_<L>'; Start-ClusterGroup '<AG>'` |
| Re-register DNS | `Get-ClusterResource '<AG>_<L>' \| Update-ClusterNetworkNameResource` |
| Dependency expr | `Get-ClusterResourceDependency '<AG>_<L>'` |
| Cluster networks | `Get-ClusterNetwork \| ft Name, Address, Role, State` |
| DNS answer | `Resolve-DnsName <fqdn> -Type A -DnsOnly` |
| DNS records on server | `Get-DnsServerResourceRecord -ZoneName <zone> -Name <L> -RRType A -ComputerName <dns>` |
| Port test | `Test-NetConnection <ip> -Port <port>` |
| sqlcmd with MSF | `sqlcmd -S tcp:<fqdn>,<port> -E -M -Q "SELECT @@SERVERNAME"` |
| ODBC drivers / DSNs | `Get-OdbcDriver; Get-OdbcDsn` |
| Listener DMV | `SELECT * FROM sys.availability_group_listener_ip_addresses` |
| Planned failover | `ALTER AVAILABILITY GROUP [<AG>] FAILOVER;` (on target sync secondary) |
| Flush client cache | `Clear-DnsClientCache` |

---
## 🎓 Learning Pointers

- [Listeners, client connectivity, and application failover](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/listeners-client-connectivity-application-failover): Microsoft's canonical explanation of RAPI, MSF and read-only routing.
- [KB 2879704: Connection timeouts in multi-subnet availability group](https://support.microsoft.com/kb/2879704): the origin of the RAPI=0 / low-TTL workaround and why it costs failover time.
- [Configure a DNN listener for an availability group](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/availability-group-distributed-network-name-dnn-listener-configure) and the [DNN interoperability](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/availability-group-dnn-interoperability) page, read before choosing DNN on Azure.
- [SqlClient support for high availability and disaster recovery](https://learn.microsoft.com/sql/connect/ado-net/sql/sqlclient-support-high-availability-disaster-recovery) covers MSF, TNIR and ApplicationIntent from the driver's perspective.
- Community walkthrough of the mixed-estate two-listener pattern: Andy Mallon, ["Multi-subnet AG with mixed MultiSubnetFailover support"](https://dev.to/am2/multi-subnet-availability-group-with-mixed-multisubnetfailover-support-part-2-5boc).
- Related EZAdmin: `ClusterADObjects-A.md` (VCO/DNS record ownership), `FailoverClustering-A.md` (networks, quorum), `DNS-Client-A.md` (resolver cache behaviour).
