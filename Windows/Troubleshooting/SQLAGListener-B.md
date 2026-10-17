# SQL Server AG Listener (Multi-Subnet) Client Timeouts — Hotfix Runbook (Mode B: Ops)
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

**Scope:** clients that connect to a SQL Server Always On availability group **listener** time out, connect intermittently (roughly every other attempt), or take minutes to reconnect after a failover, especially when the AG spans two or more subnets or sites. Use this runbook for the listener's Windows cluster/DNS layer and for the client connection string. For CNO/VCO permission failures (Event 1194/1207), use `ClusterADObjects-B.md`. For quorum or node problems, use `FailoverClustering-B.md`. SQL replica sync health (log send queue, suspended data movement) is DBA territory and is not covered here.

Run on any cluster node, elevated (FailoverClusters module):

```powershell
# 1. Listener network-name resources and the two parameters that drive client behaviour
Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'Network Name' -and $_.OwnerGroup.Name -eq '<AGName>' } |
  ForEach-Object { $_ | Get-ClusterParameter -Name DnsName, RegisterAllProvidersIP, HostRecordTTL } |
  Format-Table ClusterObject, Name, Value -AutoSize

# 2. IP resources behind the listener: one per subnet, only the local-subnet one should be Online
Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'IP Address' -and $_.OwnerGroup.Name -eq '<AGName>' } |
  ForEach-Object { [pscustomobject]@{ Name=$_.Name; State=$_.State; Address=($_ | Get-ClusterParameter Address).Value; Owner=$_.OwnerNode } }

# 3. What DNS actually hands to clients (run from a CLIENT subnet, not the node)
Resolve-DnsName -Name '<listener-fqdn>' -Type A -DnsOnly | Select-Object Name, IPAddress, TTL

# 4. Can the client reach the listener port on each returned IP?
(Resolve-DnsName '<listener-fqdn>' -Type A -DnsOnly).IPAddress |
  ForEach-Object { [pscustomobject]@{ IP=$_; Open=(Test-NetConnection $_ -Port <listenerPort> -WarningAction SilentlyContinue).TcpTestSucceeded } }
```

> `<AGName>` is the cluster role name, which equals the AG name. If unsure: `Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'SQL Server Availability Group' } | Format-Table Name, OwnerGroup, State`.

| Finding | Interpretation | Do this |
|---|---|---|
| DNS returns **2+ IPs**, one port test fails, app connects ~50% of the time / 15–21 s timeouts | `RegisterAllProvidersIP=1` (default) and the client does **not** use `MultiSubnetFailover=True`. It tries the first IP returned, which is the offline one half the time | **Fix 1** (preferred) or **Fix 2** |
| DNS returns **1 IP** that is the **old** primary's subnet after failover | `RegisterAllProvidersIP=0` with default `HostRecordTTL` (1200 s = 20 min), or stale DNS on client/forwarders | **Fix 3** |
| DNS returns 1 correct IP, port test passes, app still fails | Driver/connection-string issue (wrong port, `ApplicationIntent`, legacy driver), not cluster/DNS | **Fix 4** |
| DNS has **no** record / old record never updated, cluster Event **1196/1257** | Listener VCO can't register DNS (record ACL / secure zone) | `ClusterADObjects-B.md` Fix 5 |
| Listener resource `Failed`, Event **1069** + IP resource failed | IP conflict, wrong subnet mask, or no cluster network for that subnet | **Fix 5** |
| Listener is a **DNN** (Azure VM, `is_distributed_network_name = 1`) and clients time out | DNN listeners require `MultiSubnetFailover=True` and the DNN port in the connection string | **Fix 1** + **Fix 4** |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Client application connects to <listener>,<port>
 └── Client driver honours MultiSubnetFailover (or DNS returns only the live IP)
      ├── Driver supports MSF: Microsoft.Data.SqlClient / System.Data.SqlClient (.NET 4.5+),
      │     ODBC Driver 11+ for SQL Server, MSOLEDBSQL, JDBC 4.0+   (legacy "SQL Server"/SQLOLEDB = NO)
      └── DNS answer for <listener-fqdn>
           ├── RegisterAllProvidersIP=1 → all per-subnet IPs registered (A records)
           ├── RegisterAllProvidersIP=0 → only the ONLINE IP registered; cached for HostRecordTTL
           └── DNS zone accepts update from the listener VCO (secure dynamic update ACL)
                └── Cluster network-name resource (listener) Online
                     ├── OR-dependency on one IP Address resource per subnet
                     │    └── Only the IP for the current primary's subnet is Online (others Offline = NORMAL)
                     ├── Cluster network exists for each subnet (Get-ClusterNetwork, Role ≠ 0)
                     └── VCO in AD, owned/updatable by CNO  → see ClusterADObjects
                          └── AG role Online on primary replica; SQL listening on <port> on that IP
                               └── Windows Firewall allows <port> on every replica
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm it's a listener problem, not SQL.** From the client, connect straight to the current primary instance name.
   ```powershell
   Test-NetConnection <primary-node-fqdn> -Port <instancePort>
   ```
   Succeeds instantly but the listener is slow, so it's a listener/DNS/driver problem. Continue. If this fails too, it's firewall or SQL service. Stop here and fix that first.

2. **Count the A records.**
   ```powershell
   Resolve-DnsName '<listener-fqdn>' -Type A -DnsOnly
   ```
   Expected (default config): one A record per subnet in the AG. Multiple records are **normal**. They're only a problem for clients that don't use MSF.

3. **Check which IP resource is Online.**
   ```powershell
   Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'IP Address' -and $_.OwnerGroup.Name -eq '<AGName>' } | Format-Table Name, State, OwnerNode
   ```
   Expected: exactly one Online (the primary's subnet), the rest **Offline**. A Failed IP resource is not normal. Go to Fix 5.

4. **Read the listener parameters.**
   ```powershell
   Get-ClusterResource '<AGName>_<ListenerName>' | Get-ClusterParameter RegisterAllProvidersIP, HostRecordTTL
   ```
   `1` / `1200` = defaults for a listener created by SSMS/T-SQL (all IPs registered, 20-minute TTL). `0` / `1200` = "legacy client" config left at the default TTL, which is the classic cause of 20-minute post-failover outages.

5. **Identify the client driver and connection string.** Ask the app owner for the exact string, or check the ODBC DSN:
   ```powershell
   Get-OdbcDsn | Select-Object Name, DriverName, Platform, @{n='Server';e={$_.Attribute['Server']}}
   Get-OdbcDriver | Where-Object Name -match 'SQL' | Select-Object Name, Platform
   ```
   `DriverName = SQL Server` (sqlsrv32.dll) can't do MSF. You need Fix 2 or a driver upgrade.

6. **Look at the SQL side of the listener** (any replica, SSMS or `Invoke-Sqlcmd`):
   ```sql
   SELECT l.dns_name, l.port, l.is_distributed_network_name, ip.ip_address, ip.ip_subnet_mask, ip.state_desc
   FROM sys.availability_group_listeners l
   JOIN sys.availability_group_listener_ip_addresses ip ON l.listener_id = ip.listener_id;
   ```
   One ONLINE row plus N-1 OFFLINE rows is healthy for a multi-subnet AG. (`is_distributed_network_name` exists on 2016 SP3 / 2017 CU25 / 2019 CU8 and later.)

---
## Common Fix Paths

<details><summary>Fix 1 — Add MultiSubnetFailover=True to the client connection string (preferred, no outage)</summary>

This is the supported fix. The driver opens TCP to **all** returned IPs in parallel and uses the first that answers. It also speeds up single-subnet failovers.

| Driver | Keyword |
|---|---|
| .NET `Microsoft.Data.SqlClient` / `System.Data.SqlClient` (4.5+) | `MultiSubnetFailover=True` |
| ODBC Driver 17/18 for SQL Server | `MultiSubnetFailover=Yes` |
| MSOLEDBSQL | `MultiSubnetFailover=Yes` |
| JDBC | `multiSubnetFailover=true` |
| `sqlcmd` (ODBC-based) | `-M` |

```text
Server=tcp:<listener-fqdn>,<port>;Database=<db>;Integrated Security=SSPI;MultiSubnetFailover=True;Encrypt=True
```

ODBC DSN (System, 64-bit) via PowerShell:
```powershell
Set-OdbcDsn -Name '<DSNName>' -DsnType System -Platform 64-bit -SetPropertyValue 'MultiSubnetFailover=Yes'
```

Test from the client:
```powershell
sqlcmd -S tcp:<listener-fqdn>,<port> -E -M -Q "SELECT @@SERVERNAME"
```
Should return immediately, every time.

**Rollback:** remove the keyword. Nothing changes server-side.
</details>

<details><summary>Fix 2 — Legacy clients that can't use MSF: RegisterAllProvidersIP=0 + low TTL (brief listener outage)</summary>

Use this only when the app/driver can't be changed. Trade-off: after every failover, clients reconnect only after the DNS update replicates **and** their cached TTL expires.

```powershell
$res = Get-ClusterResource '<AGName>_<ListenerName>'
$res | Set-ClusterParameter -Name RegisterAllProvidersIP -Value 0
$res | Set-ClusterParameter -Name HostRecordTTL -Value 300   # 120–300 is common; lower = more DNS traffic

# Change applies only after the name resource cycles. MAINTENANCE WINDOW: listener goes offline.
Stop-ClusterResource  $res
Start-ClusterResource $res
Start-ClusterGroup '<AGName>'   # bring dependants (the AG resource) back if they dropped
Get-ClusterResource '<AGName>_<ListenerName>' | Update-ClusterNetworkNameResource
```

Then on DNS, delete the stale A records for the offline subnets (they aren't removed automatically):
```powershell
Get-DnsServerResourceRecord -ComputerName <DNSServer> -ZoneName '<zone>' -Name '<ListenerShortName>' -RRType A
Remove-DnsServerResourceRecord -ComputerName <DNSServer> -ZoneName '<zone>' -Name '<ListenerShortName>' -RRType A -RecordData '<offline-subnet-ip>' -Force
```

**Mixed estate?** Create a **second listener** on the same AG with `RegisterAllProvidersIP=0` for legacy apps. Leave the original at `1` for MSF-capable apps. Both fail over together.

**Rollback:** set `RegisterAllProvidersIP` back to `1`, cycle the resource, run `Update-ClusterNetworkNameResource`.
</details>

<details><summary>Fix 3 — Slow reconnect after failover (single A record still pointing at old subnet)</summary>

```powershell
# On the cluster: force re-registration of the listener's current IP
Get-ClusterResource '<AGName>_<ListenerName>' | Update-ClusterNetworkNameResource

# Lower the TTL for next time (takes effect after next resource cycle / registration)
Get-ClusterResource '<AGName>_<ListenerName>' | Set-ClusterParameter HostRecordTTL 300

# On affected clients / app servers: drop the cached answer
Clear-DnsClientCache
```

Still wrong on clients after this? Check AD-integrated zone replication between sites (`repadmin /syncall /AdeP` in a change window) and any DNS forwarder/conditional-forwarder cache between client and AD DNS. Clear those caches too (`Clear-DnsServerCache -ComputerName <forwarder>`).

The real fix is still Fix 1. Fix 3 only shortens the outage window.
</details>

<details><summary>Fix 4 — Correct IP, still can't connect: port / driver / intent</summary>

- **Port:** if the listener isn't on 1433, the port **must** be in the connection string (`<listener>,<port>`). SQL Browser does **not** resolve listener ports. DNN listeners always need the explicit DNN port.
- **Firewall:** the listener port must be open on **every** replica, not only the current primary:
  ```powershell
  Invoke-Command -ComputerName <node1>,<node2> { Get-NetFirewallPortFilter -Protocol TCP | Where-Object LocalPort -eq '<port>' | Get-NetFirewallRule | Select-Object DisplayName, Enabled, Action }
  ```
- **Read-only routing:** `ApplicationIntent=ReadOnly` routes only if a **database** is specified in the connection string and read-only routing lists are configured. Without a database, it lands on the primary.
- **Legacy driver:** `Driver={SQL Server}` / `Provider=SQLOLEDB`. Upgrade to ODBC Driver 18 or MSOLEDBSQL, then apply Fix 1. Note that ODBC 18 defaults `Encrypt=Yes`, so the server cert must be trusted or add `TrustServerCertificate=Yes` as a stop-gap.
</details>

<details><summary>Fix 5 — Listener IP resource Failed / listener won't come online</summary>

```powershell
# Every subnet in the AG needs a cluster network
Get-ClusterNetwork | Format-Table Name, Address, AddressMask, Role, State

# IP conflict check from a node on that subnet (no reply = good)
Test-Connection <listener-ip-for-that-subnet> -Count 2 -Quiet

# Inspect the failing IP resource parameters
Get-ClusterResource '<IPResourceName>' | Get-ClusterParameter Address, SubnetMask, Network, EnableDhcp
```
- `Role = 0` (None) on the network for that subnet means the cluster won't place IPs there. Set it with `(Get-ClusterNetwork '<name>').Role = 3` (cluster and client).
- Wrong mask or IP outside the cluster network means you fix the IP on the SQL side so both stay consistent:
  `ALTER AVAILABILITY GROUP [<AG>] MODIFY LISTENER '<ListenerName>' (ADD IP ('<ip>','<mask>'));` and then remove the bad IP resource in Failover Cluster Manager.
- The OR-dependency must list every IP. Check it with `Get-ClusterResourceDependency '<AGName>_<ListenerName>'`, which should read `[IP A] or [IP B]`, **not** `and`.
</details>

---
## Escalation Evidence

```text
=== SQL AG Listener Escalation ===
Ticket #:                    <ticket>
AG name / Listener FQDN:     <AGName> / <listener-fqdn>
Listener port / DNN?:        <port> / <yes|no>
SQL version + CU:            <e.g. 2022 CU14>
Subnets / sites in AG:       <list>
RegisterAllProvidersIP:      <0|1>          HostRecordTTL: <sec>
IP resources (name:state):   <...>
Resolve-DnsName from client: <IPs + TTL>
Port test per IP from client:<IP: True/False ...>
Client driver + version:     <e.g. ODBC Driver 18 18.4 / SqlClient 5.2 / SQL Server (legacy)>
Connection string (redacted):<...MultiSubnetFailover=?...>
Failover time / first error: <timestamp> / <error text>
Cluster events 1069/1196/1257 last 24h: <paste>
Fixes attempted:             <Fix N ...>
Evidence script output:      Get-SQLAGListenerHealth.ps1 CSV attached
```

---
## 🎓 Learning Pointers

- **Multiple A records are by design.** The listener registers every subnet's IP so MSF-capable clients can race them. The "fix" is in the client, not DNS. See [Listeners, client connectivity, application failover](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/listeners-client-connectivity-application-failover).
- **`RegisterAllProvidersIP=0` swaps a client problem for a failover-time problem.** Reconnect time becomes replication latency plus TTL. Document it so the next engineer doesn't "fix" the TTL back. Background: [KB 2879704 — Connection timeouts in multi-subnet AG](https://support.microsoft.com/kb/2879704).
- **Offline IP resources are healthy.** The listener has an OR dependency. Only the primary's subnet IP should be Online, so don't try to bring the others online.
- **DNN listeners (Azure VMs) have no IPs at all.** DNS returns every replica's own IP, so MSF and an explicit port are mandatory. See [Configure a DNN listener](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/availability-group-distributed-network-name-dnn-listener-configure).
- **Changing listener parameters means a short listener outage.** Schedule it, and always run `Update-ClusterNetworkNameResource` afterwards so DNS matches the new setting.
- Deep dive and the evidence script: `SQLAGListener-A.md`, `Windows/Scripts/Get-SQLAGListenerHealth.ps1`.
