# RD Connection Broker & Broker High Availability — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.
> Ops version: `RDConnectionBroker-B.md` · Script: `../Scripts/Get-RDConnectionBrokerDiagnostics.ps1` · Siblings: `RDGateway-A.md` · `RDWebAccess-A.md` · `RDSLicensing-A.md` · `RDP-A.md`

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
- Session-based RDS deployments (Windows Server 2016 / 2019 / 2022 / 2025) managed through Server Manager or the `RemoteDesktop` module. VDI collections share the same broker mechanics but are not the focus.
- Covers the Connection Broker role only: session directory, load balancing, redirection, the RDMS management plane, the deployment database (WID vs SQL/Azure SQL), and the HA configuration (client access name, DNS round-robin / LB, certificates).
- Out of scope: RD Gateway (`RDGateway-A.md`), RD Web / HTML5 client (`RDWebAccess-A.md`), licensing (`RDSLicensing-A.md`), AVD (brokered by Microsoft, see `Azure/AVD`).
- Commands assume Windows PowerShell 5.1, elevated, with rights on the deployment (the RemoteDesktop module doesn't run under PowerShell 7).

---
## How It Works
<details><summary>Full architecture</summary>

### Two services, two planes
| Service | Display name | Where it runs | Job |
|---|---|---|---|
| `Tssdis` | Remote Desktop Connection Broker | Every broker (HA = active-active) | Session directory (who has a session where), load-balancing decision, redirection of the client to an RDSH, RemoteApp/desktop resource lookup for RD Web |
| `RDMS` | Remote Desktop Management | Only the **ActiveManagementServer** | Deployment configuration: collections, servers, certificates, properties — what Server Manager and `*-RD*` cmdlets talk to |
| `TScPubRPC` | RemoteApp and Desktop Connection Management | Brokers | Publishing / feed data for RD Web |

Consequence: losing the active management server breaks *management*, not *connections*. Losing `Tssdis` on the only broker breaks everything.

### Connection flow (brokered)
```
Client (.rdp from RD Web/feed: full address=<CAN>, loadbalanceinfo=tsv://MS Terminal Services Plugin.1.<Collection>)
   │ 1. TCP 3389 (usually via RD Gateway) to <CAN>  → any broker
   ▼
Broker (Tssdis)
   │ 2. Authenticate user, read loadbalanceinfo → collection
   │ 3. Query DB: existing disconnected session for this user in this collection?
   │      yes → target = that RDSH           no → pick RDSH by load (sessions, weight, NewConnectionAllowed)
   │ 4. Send redirection packet (target RDSH + routing token) to the client
   ▼
Client reconnects to RDSH:3389 → RDSH SessionBroker-Client validates token, reports session to broker
```
The first hop terminates on the broker, so the broker's certificate (`RDRedirector`) is the one the client validates first — hence the SAN requirement for the client access name (CAN) in HA.

### Database: WID vs SQL
- **Single broker**: Windows Internal Database (`MSSQL$MICROSOFT##WID`), files under `C:\Windows\rdcbDb\`. No failover; backup = the VM.
- **HA**: all brokers share one SQL Server / Azure SQL database. Running the HA wizard (or `Set-RDConnectionBrokerHighAvailability`) **migrates** the WID contents into SQL, which is why the first broker's computer account temporarily needs `dbcreator`. Microsoft documents that the creation script supports **case-insensitive collations only**.
- The connection string is stored in the deployment and read by each broker's `Tssdis`, so the **driver named in the string must be installed on every broker**. Microsoft's guide says to download the ODBC driver that matches the string and install it on each server that runs the broker.
- `-DatabaseSecondaryConnectionString` exists so that SQL-authenticated deployments (typical with Azure SQL) can rotate passwords: brokers fall back to the secondary string while the primary's password is being changed.
- No supported "un-HA": once converted, the deployment stays on SQL. Losing the DB without a backup = rebuild the deployment.

### Client access name (CAN)
`-ClientAccessName` is "the DNS round-robin name that contains FQDNs of the RD Connection Broker servers" (cmdlet docs). Options:
- **DNS round-robin**: one A record per broker under the same name. No health checking — a dead broker still gets its share.
- **Load balancer** (Azure ILB or on-prem): VIP for the CAN, TCP probe on 3389, rule 3389→3389. Health-aware.
The CAN appears in every `.rdp` file and feed generated after HA, and in the certificate SAN. Change it with `Set-RDClientAccessName` only alongside DNS + cert changes.

### Session hosts' view
Each RDSH is joined to the broker farm (collection) and runs the SessionBroker-Client component. It reports logon/logoff/disconnect events so the directory stays accurate and validates the redirection token. Hosts in drain (`NewConnectionAllowed = No`) still accept reconnections to existing sessions.

### Management failover
`Set-RDActiveManagementServer -ManagementServer <fqdn>` moves RDMS to another broker. Not automatic — an admin must run it when the active one dies.
</details>

---
## Dependency Stack
```
[7] User experience: reconnect to own session, balanced new sessions
[6] RDSH: SessionBroker-Client ↔ broker, drain state, licensing, UPD/FSLogix
[5] Redirection: Tssdis decision + routing token + RDRedirector cert (SAN ∋ CAN)
[4] Session directory: DB rows (users, sessions, hosts, collections)
[3] Database: WID (single) | SQL/Azure SQL (HA) — driver, string, login, collation, TLS
[2] Addressing: CAN → DNS RR / LB VIP → each broker :3389
[1] Platform: AD (computer accounts, Kerberos), DNS, time sync, Windows Server + CU level
Management side-car: RDMS on ActiveManagementServer → Server Manager / RemoteDesktop module
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Server Manager: "A Remote Desktop Services deployment does not exist in the server pool" | Server Manager not pointed at active management server / RDMS down / broker not in pool | `Get-RDConnectionBrokerHighAvailability` → `ActiveManagementServer`; `Get-Service RDMS` |
| All users fail after SQL maintenance | Driver removed, SQL login lost, TLS enforced (ODBC 18), DB offline, AG failover without listener | SessionBroker/Admin log; `Get-RDDatabaseConnectionString`; `Get-OdbcDriver` |
| ~50% of users fail, randomly | Dead broker still in DNS round-robin | `Resolve-DnsName <CAN>` + 3389 test per IP |
| New broker added, fails, other works | Driver not installed or SQL login missing on the new node | `Get-OdbcDriver` on new node; SQL logins |
| Cert warning naming `rdcb.contoso.com` | `RDRedirector`/`RDPublishing` SAN lacks CAN | `Get-RDCertificate` + PFX SAN |
| HA wizard: "Could not create the database" | String casing (`Yes`), `.mdf` in name, no `dbcreator`, CS collation, wrong driver | Microsoft troubleshooting article checklist |
| Users get a new session instead of their disconnected one | Direct-to-RDSH connection, stale `.rdp` without `loadbalanceinfo`, ghost directory entries | `Get-RDUserSession` vs `quser /server:<h>` |
| Everything unbalanced onto one host | Other hosts in drain, weights, or not in collection | `Get-RDSessionHost`, `Get-RDSessionCollectionConfiguration -LoadBalancing` |
| `Tssdis` hangs stopping/starting after Sept 2026 CU | Known CU deadlock | `RDSDeadlockSept2026-A.md` |
| Single broker VM lost | No HA; WID gone | Restore from backup; otherwise rebuild |

---
## Validation Steps
1. **HA state** — `Get-RDConnectionBrokerHighAvailability -ConnectionBroker <b> | fl *`
   Good: `ActiveManagementServer` set, `ConnectionBroker` lists all brokers, `ClientAccessName` set. Bad: empty (single broker) or cmdlet error (RDMS/DB).
2. **Services** — `Invoke-Command <brokers> { Get-Service Tssdis,RDMS,TScPubRPC }`
   Good: `Tssdis` Running everywhere; `RDMS` Running on the active node. Bad: any `Tssdis` Stopped.
3. **Drivers** — `Invoke-Command <brokers> { Get-OdbcDriver -Platform 64-bit | ? Name -match 'SQL' }`
   Good: the driver from the string present on all. Bad: missing on any node.
4. **SQL** — `Test-NetConnection <sql> -Port 1433`; collation `_CI_`; broker accounts have `db_owner` on the DB.
5. **CAN** — `Resolve-DnsName <CAN>` returns every live broker IP or the VIP; each answers TCP 3389.
6. **Certs** — `Get-RDCertificate` → all four roles `Trusted`, not expiring < 30 days, SAN covers CAN.
7. **Directory sanity** — `Get-RDUserSession -ConnectionBroker <b>` count ≈ sum of `quser /server:<h>` across hosts.
8. **Logs quiet** — `Microsoft-Windows-TerminalServices-SessionBroker/Admin` has no errors in the last 24 h.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Client can't reach any broker.** DNS for CAN (split-brain internal vs external; the gateway resolves it internally), 3389 path from gateway to brokers, broker cert. Gateway events 302/304 name the target → `RDGateway-A.md`.

**Phase 2 — Broker reached, redirection fails.** SessionBroker/Admin + Operational logs on the broker; SessionBroker-Client/Operational on target RDSH. Check `Tssdis` DB connectivity and that the target host is in the collection and not in drain for new sessions.

**Phase 3 — Wrong host / lost reconnections.** Compare `Get-RDUserSession` with `quser` per host. Look for users launching saved `.rdp` files pointing at a host name. Check UPD/FSLogix locks.

**Phase 4 — Management plane broken.** Identify the active management server; move it if dead; re-add servers to the Server Manager pool; ensure WinRM between brokers and hosts (`Test-WSMan <host>`).

**Phase 5 — Database layer.** Driver ↔ string, SQL login per broker computer account (rebuilt brokers have new SIDs), AG listener + `MultiSubnetFailover=Yes`, TLS requirements (ODBC 18 defaults to `Encrypt=yes` and needs a trusted SQL cert or `TrustServerCertificate=yes`), DB state `ONLINE`.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Convert a single broker to HA (SQL Server, Windows auth)</summary>

1. SQL prep: AD group `RDCB-Brokers` containing all broker computer accounts → SQL login for the group with `dbcreator` (can be removed after creation, keep `db_owner` on the DB). Confirm case-insensitive collation.
2. Install the same ODBC driver on every current and future broker.
3. DNS: A records for `<rdcb>` → each broker IP (TTL ~300) **or** LB VIP with TCP 3389 probe.
4. Certificate: SAN covering CAN + RD Web/Gateway FQDNs.
5. Convert and add:
```powershell
Set-RDConnectionBrokerHighAvailability -ConnectionBroker <broker1.fqdn> `
  -DatabaseConnectionString 'DRIVER={ODBC Driver 17 for SQL Server};SERVER=<sql.fqdn>;Trusted_Connection=Yes;APP=Remote Desktop Services Connection Broker;DATABASE=RDCB' `
  -ClientAccessName '<rdcb.contoso.com>'
Add-RDServer -Server <broker2.fqdn> -Role RDS-CONNECTION-BROKER -ConnectionBroker <broker1.fqdn>
$pw = Read-Host -AsSecureString
'RDRedirector','RDPublishing','RDWebAccess','RDGateway' | % { Set-RDCertificate -Role $_ -ImportPath '<pfx>' -Password $pw -ConnectionBroker <broker1.fqdn> -Force }
```
6. Re-download `.rdp` / re-subscribe feeds so clients get the CAN.
Rollback: before step 5, snapshot broker1 and back up `C:\Windows\rdcbDb`. After conversion, rollback = restore the snapshot (there is no cmdlet to revert to WID).
</details>

<details><summary>Playbook 2 — Azure SQL with SQL authentication and password rotation</summary>

```powershell
$p = 'Driver={ODBC Driver 17 for SQL Server};Server=tcp:<srv>.database.windows.net,1433;Database=<db>;Uid=<login1>;Pwd=<pw1>;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;'
$s = 'Driver={ODBC Driver 17 for SQL Server};Server=tcp:<srv>.database.windows.net,1433;Database=<db>;Uid=<login2>;Pwd=<pw2>;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;'
Set-RDDatabaseConnectionString -ConnectionBroker <b> -DatabaseConnectionString $p -DatabaseSecondaryConnectionString $s
```
Rotate login1's password → update the primary string → then rotate login2 → update the secondary. Allow brokers' outbound IPs through the Azure SQL firewall / use a private endpoint.
</details>

<details><summary>Playbook 3 — Replace the SQL driver (e.g. retire Native Client)</summary>

1. Install the new driver on **all** brokers.
2. Capture current string: `Get-RDDatabaseConnectionString -ConnectionBroker <b>`.
3. `Set-RDDatabaseConnectionString` with only `DRIVER=` changed (add `TrustServerCertificate`/`Encrypt` as needed for ODBC 18).
4. Restart `Tssdis` broker-by-broker, test a login through each broker IP.
Rollback: step 3 with the saved string (old driver still installed until validated).
</details>

<details><summary>Playbook 4 — SQL moved / Always On availability group</summary>

Point at the listener, never a replica:
`...;SERVER=<ag-listener.fqdn>;MultiSubnetFailover=Yes;Trusted_Connection=Yes;...`
Re-create broker logins on **every** replica (logins are server-level objects, not in the DB); mismatched SIDs for SQL logins across replicas cause failures only after failover.
</details>

<details><summary>Playbook 5 — Lost active management server</summary>

`Set-RDActiveManagementServer -ManagementServer <survivor>` → Server Manager on survivor → Add Servers → refresh. If the dead node will never return: Playbook = B-runbook Fix 8 (`Remove-RDServer`), then DNS/LB/SQL login cleanup.
</details>

<details><summary>Playbook 6 — Single-broker WID loss (no HA)</summary>

Options in order: restore broker VM from backup → restore `C:\Windows\rdcbDb\*` with services stopped → rebuild deployment (`New-RDSessionDeployment`, recreate collections/RemoteApps/certs). Existing RDSH need removing/re-adding. Document collections now (`Get-RDSessionCollection`, `Get-RDRemoteApp`, export to CSV) so a rebuild is quick — the evidence pack below does this.
</details>

---
## Evidence Pack
```powershell
# Run on a broker, elevated, Windows PowerShell 5.1
$b   = '<broker.fqdn>'
$out = "C:\Temp\RDCB_Evidence_$(Get-Date -f yyyyMMdd_HHmm)"; New-Item $out -ItemType Directory -Force | Out-Null
Import-Module RemoteDesktop
$ha = Get-RDConnectionBrokerHighAvailability -ConnectionBroker $b -ErrorAction SilentlyContinue
$ha | Select ActiveManagementServer, ClientAccessName, ConnectionBroker,
  @{n='DbString';e={ $_.DatabaseConnectionString -replace '(?i)(pwd|password)=[^;]*','$1=***' }} | Out-File "$out\ha.txt"
Get-RDServer -ConnectionBroker $b | Select Server, @{n='Roles';e={$_.Roles -join ','}} | Export-Csv "$out\servers.csv" -NoType
Get-RDCertificate -ConnectionBroker $b | Select Role, Level, ExpiresOn, Thumbprint, Subject | Export-Csv "$out\certs.csv" -NoType
Get-RDSessionCollection -ConnectionBroker $b | Export-Csv "$out\collections.csv" -NoType
Get-RDSessionCollection -ConnectionBroker $b | % { Get-RDSessionHost -CollectionName $_.CollectionName -ConnectionBroker $b } | Export-Csv "$out\hosts.csv" -NoType
Get-RDUserSession -ConnectionBroker $b | Select UserName, HostServer, SessionState, CollectionName | Export-Csv "$out\sessions.csv" -NoType
$brokers = if ($ha) { $ha.ConnectionBroker } else { $b }
foreach ($n in $brokers) {
  Invoke-Command $n { Get-Service Tssdis,RDMS,TScPubRPC | Select Name,Status; Get-OdbcDriver -Platform 64-bit | ? Name -match 'SQL' | Select Name } | Out-File "$out\node_$n.txt"
  Get-WinEvent -ComputerName $n -LogName 'Microsoft-Windows-TerminalServices-SessionBroker/Admin' -MaxEvents 200 -ErrorAction SilentlyContinue |
    Select TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\sbadmin_$n.csv" -NoType
}
if ($ha) { Resolve-DnsName $ha.ClientAccessName -Type A -ErrorAction SilentlyContinue | Select Name, IPAddress | Export-Csv "$out\can_dns.csv" -NoType }
Compress-Archive "$out\*" "$out.zip" -Force; "Evidence: $out.zip"
```
Passwords in SQL-auth strings are masked; still review before attaching.

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| HA config | `Get-RDConnectionBrokerHighAvailability -ConnectionBroker <b>` |
| Convert to HA | `Set-RDConnectionBrokerHighAvailability -DatabaseConnectionString <s> -ClientAccessName <can>` |
| DB string get/set | `Get-RDDatabaseConnectionString` / `Set-RDDatabaseConnectionString` |
| Move management | `Set-RDActiveManagementServer -ManagementServer <fqdn>` |
| Rename CAN | `Set-RDClientAccessName -ClientAccessName <fqdn>` |
| Add/remove broker | `Add-RDServer` / `Remove-RDServer -Role RDS-CONNECTION-BROKER` |
| Servers & roles | `Get-RDServer -ConnectionBroker <b>` |
| Certs | `Get-RDCertificate` / `Set-RDCertificate -Role RDRedirector` |
| Sessions | `Get-RDUserSession -ConnectionBroker <b>` |
| Drain host | `Set-RDSessionHost -SessionHost <h> -NewConnectionAllowed No -ConnectionBroker <b>` |
| Load-balancing weights | `Get-RDSessionCollectionConfiguration -CollectionName <c> -LoadBalancing` |
| Log off ghost | `Invoke-RDUserLogoff -HostServer <h> -UnifiedSessionID <id> -Force` |
| Drivers | `Get-OdbcDriver -Platform 64-bit` |
| Broker log | `Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-SessionBroker/Admin'` |
| Host-side log | `Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-SessionBroker-Client/Operational'` |

---
## 🎓 Learning Pointers
- Microsoft's HA guide covers the three prerequisites that fail most often: the matching ODBC driver on every broker, the connection string, and a DNS RR or load balancer for the client access name. [Configure RD Connection Broker for high availability](https://learn.microsoft.com/windows-server/remote/remote-desktop-services/rds-connection-broker-cluster)
- Microsoft's troubleshooting article is the canonical checklist for "Could not create the database": `Yes` not `YES`, `dbcreator`, case-insensitive collation. [Error after HA configuration](https://learn.microsoft.com/troubleshoot/windows-server/remote/error-configuration-rd-connection-brokers-high-availability)
- Read the cmdlet reference for `-DatabaseSecondaryConnectionString`. It lets you rotate passwords without an outage, but few MSPs use it. [Set-RDConnectionBrokerHighAvailability](https://learn.microsoft.com/powershell/module/remotedesktop/set-rdconnectionbrokerhighavailability) · [Get-RDConnectionBrokerHighAvailability](https://learn.microsoft.com/powershell/module/remotedesktop/get-rdconnectionbrokerhighavailability)
- If RDS logs are thin, Microsoft keeps a list of the logs to collect, including the broker-side traces. [Useful log files for troubleshooting RDS](https://learn.microsoft.com/troubleshoot/windows-server/remote/log-files-to-troubleshoot-rds-issues)
- DNS round-robin gives you redundancy but doesn't check health. If the customer can't tolerate 1/N failures while a broker is down, use an LB with a TCP 3389 probe.
- For RDS-heavy estates, also document collections and RemoteApps (Playbook 6). A single-broker WID deployment with no backup is a common MSP liability.
