# RD Connection Broker & Broker High Availability — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.
> Covers: Server Manager "A Remote Desktop Services deployment does not exist in the server pool" / RDS Overview blank, users not reconnecting to their disconnected session (landing on a new host), all connections failing when one broker is down, "Configure High Availability" wizard failing with *"Could not create the database <DatabaseName>"*, broker unable to reach SQL after a SQL/driver change, client access name (DNS round-robin / load balancer) problems, broker certificate SAN mismatch after HA, and "the connection was denied because the user account is not authorized" at the redirection step.
> Deep dive: `RDConnectionBroker-A.md` · Script: `../Scripts/Get-RDConnectionBrokerDiagnostics.ps1` · Siblings: `RDGateway-B.md` · `RDWebAccess-B.md` · `RDSLicensing-B.md` · `RDSDeadlockSept2026-B.md` (Sept 2026 CU hang)

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run on **any Connection Broker** (elevated Windows PowerShell 5.1, RemoteDesktop module):

```powershell
$b = '<broker1.fqdn>'
Get-Service Tssdis, RDMS, TScPubRPC -ComputerName $b | Select MachineName, Name, Status, StartType
Get-RDConnectionBrokerHighAvailability -ConnectionBroker $b | Format-List *        # empty = single broker (WID)
Get-RDServer -ConnectionBroker $b | Select Server, @{n='Roles';e={$_.Roles -join ','}}
Get-RDCertificate -ConnectionBroker $b | Select Role, Level, ExpiresOn, Subject
Resolve-DnsName <client.access.name> -Type A | Select Name, IPAddress
```

| Result | Meaning | Go to |
|---|---|---|
| `Tssdis` stopped on a broker | Connection Broker service down → that broker can't route/reconnect | Fix 1 |
| `Get-RDConnectionBrokerHighAvailability` hangs/errors, Server Manager RDS Overview empty | Active management server down or RDMS can't reach the DB | Fix 2 |
| HA configured, **all** brokers fail after SQL patch/migration/driver change | DB connection string / ODBC driver / SQL login / TLS broken | Fix 3 |
| HA wizard: *"Could not create the database"* | String format, missing `dbcreator`, case-sensitive collation, missing driver | Fix 4 |
| Client access name resolves to one IP only, a dead IP, or not at all | DNS round-robin / LB record wrong → half of clients fail | Fix 5 |
| Cert warning naming the client access name; `Level` ≠ `Trusted` | Broker certs (`RDRedirector`/`RDPublishing`) lack the client access name in SAN | Fix 6 |
| Users land on a *new* session instead of reconnecting | Session directory stale / host drain / `Tssdis` DB mismatch / user profile disk lock | Fix 7 |
| Broker node permanently dead, need to remove it | Supported removal path via `Remove-RDServer` + HA re-point | Fix 8 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
User connects (RD Web / feed / .rdp → RD Gateway) to the deployment
└── .rdp "full address" = client access name (HA) or broker FQDN (single)
    └── DNS: client access name → A records of every broker (RR) or LB VIP
        └── TCP 3389 to a broker (LB probe on 3389, no stale IPs)
            └── Broker cert (RDRedirector) valid, SAN includes client access name
                └── Tssdis (Remote Desktop Connection Broker) running on that broker
                    └── Broker ↔ database
                        ├── Single broker: WID  (C:\Windows\rdcbDb\rdcms.mdf)
                        └── HA: SQL Server / Azure SQL (shared, active-active)
                              ├── Matching ODBC / Native Client driver installed on EVERY broker
                              ├── Connection string correct (Trusted_Connection=Yes, not YES)
                              ├── Broker computer accounts (or SQL login) → db_owner on the RDCB DB
                              ├── SQL reachable (TCP 1433 / listener), TLS acceptable to the driver
                              └── Instance collation case-INsensitive
                    └── Session directory lookup → existing session? reconnect : load-balance
                        └── Redirect to RDSH (TCP 3389) → RDSH SessionBroker-Client
                            └── RDSH licensing → session
Management plane (Server Manager / RemoteDesktop cmdlets):
└── RDMS service runs only on the ActiveManagementServer broker
    └── Set-RDActiveManagementServer to move it if that node is down
```
</details>

---
## Diagnosis & Validation Flow

1. **Is this HA at all?**
   `Get-RDConnectionBrokerHighAvailability -ConnectionBroker <b>` → returns `ActiveManagementServer`, `ClientAccessName`, `ConnectionBroker`, `DatabaseConnectionString`.
   Empty output = single broker on WID. A single-broker outage is a full outage — go straight to Fix 1 / Fix 2 and read the A-runbook on why HA matters.

2. **Is the Connection Broker service alive on every broker?**
   `Invoke-Command <b1>,<b2> { Get-Service Tssdis, RDMS | Select Name, Status }`
   `Tssdis` must be `Running` on **all** brokers. `RDMS` only needs to run on the active management server.

3. **Can the broker talk to its database?**
   `Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-SessionBroker/Admin' -MaxEvents 30 | Select TimeCreated, Id, LevelDisplayName, Message`
   Errors mentioning the database, ODBC, SQL login or "Unable to connect" = Fix 3. Clean = continue.

4. **Is the client access name healthy?**
   `Resolve-DnsName <can> -Type A` must list each broker IP (RR) or the LB VIP. Then `Test-NetConnection <each IP> -Port 3389` → `TcpTestSucceeded : True`. A dead IP in round-robin = ~1/N of users fail = Fix 5.

5. **Do the broker certs cover the client access name?**
   `Get-RDCertificate -ConnectionBroker <b> | Where Role -in 'RDRedirector','RDPublishing'` → `Level = Trusted`, not expired, and the SAN list (check the PFX) includes the client access name. Otherwise Fix 6.

6. **Is the RDSH side registered?** On a session host:
   `Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-SessionBroker-Client/Operational' -MaxEvents 20 | Select TimeCreated, Id, Message`
   Errors about joining / contacting the broker = host can't reach the client access name or `Tssdis`. Redirect errors on the host (commonly Event 1306) with broker healthy = RDSH-side issue → `RDP-B.md` / `RDSLicensing-B.md`.

---
## Common Fix Paths

<details><summary>Fix 1 — Tssdis (Remote Desktop Connection Broker) service stopped or crashing</summary>

```powershell
$b = '<broker.fqdn>'
Invoke-Command $b {
    Get-Service Tssdis, RDMS | Select Name, Status
    Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Service Control Manager'; StartTime=(Get-Date).AddHours(-24)} |
        Where Message -match 'Connection Broker|Remote Desktop Management' | Select -First 10 TimeCreated, Id, Message
    Start-Service Tssdis
    Get-Service Tssdis
}
```
- Won't start on an HA broker → almost always the DB path (Fix 3).
- Won't start on a single WID broker → check the `MSSQL$MICROSOFT##WID` service (`Get-Service 'MSSQL$MICROSOFT##WID'`) and free disk on `C:`.
- Service hangs on stop/start after the **September 2026 CU** → `RDSDeadlockSept2026-B.md` first.
</details>

<details><summary>Fix 2 — Active management server down / Server Manager shows no deployment</summary>

Only one broker runs RDMS (the management plane). Connections still route through the surviving brokers, but no config changes are possible until management is moved.

```powershell
# From a surviving broker
Get-RDConnectionBrokerHighAvailability -ConnectionBroker <surviving.fqdn> | Select ActiveManagementServer, ConnectionBroker
Set-RDActiveManagementServer -ManagementServer <surviving.fqdn>
Get-RDConnectionBrokerHighAvailability -ConnectionBroker <surviving.fqdn> | Select ActiveManagementServer
```
Then in Server Manager: **Manage → Add Servers** → add all brokers/hosts to the pool and refresh RDS Overview (it must be opened on/pointed at the active management server).
Single-broker deployment with a dead broker: no failover exists — restore the VM/backup of the broker (WID DB lives in `C:\Windows\rdcbDb`). See A-runbook "WID loss".
</details>

<details><summary>Fix 3 — HA brokers lost the SQL database (driver / string / login / TLS)</summary>

```powershell
$b = '<broker.fqdn>'
Get-RDDatabaseConnectionString -ConnectionBroker $b          # primary + secondary (passwords visible - don't paste into tickets)
Invoke-Command $b { Get-OdbcDriver -Platform 64-bit | Where Name -match 'SQL' | Select Name }
Test-NetConnection <sql.fqdn> -Port 1433
```
Match the `Driver=` in the string to an installed driver **on every broker**:

| String says | Needs installed | Common breakage |
|---|---|---|
| `SQL Server Native Client 11.0` | `sqlncli.msi` | Removed during OS in-place upgrade / not supported by SQL 2022 features |
| `ODBC Driver 17 for SQL Server` | msodbcsql 17 | Missing on the newly added broker |
| `ODBC Driver 18 for SQL Server` | msodbcsql 18 | Encrypts by default → fails if SQL cert isn't trusted |

Repoint to a working driver/string (all brokers read it from the deployment):
```powershell
Set-RDDatabaseConnectionString -ConnectionBroker $b `
  -DatabaseConnectionString 'DRIVER={ODBC Driver 17 for SQL Server};SERVER=<sql.fqdn>;Trusted_Connection=Yes;APP=Remote Desktop Services Connection Broker;DATABASE=<RDCB-DB>'
Invoke-Command <b1>,<b2> { Restart-Service Tssdis }
```
- SQL AlwaysOn: use the **listener** name and add `MultiSubnetFailover=Yes;`.
- Trusted_Connection: the **broker computer accounts** (or an AD group holding them) need a SQL login mapped to the DB with `db_owner`. A rebuilt broker has a new SID → re-grant.
- ODBC 18 + self-signed SQL cert: add `TrustServerCertificate=Yes;` as a stop-gap, fix the SQL cert properly after.
Rollback: re-run `Set-RDDatabaseConnectionString` with the previous string (copy it from step 1 first).
</details>

<details><summary>Fix 4 — HA wizard: "Could not create the database &lt;DatabaseName&gt;"</summary>

Per Microsoft's troubleshooting article, check in order:
1. String format — exactly:
   `DRIVER=SQL Server Native Client 11.0;SERVER=<sql>;Trusted_Connection=Yes;APP=Remote Desktop Services Connection Broker;Database=<name>`
   `Yes` not `YES`; **no** `.mdf` extension in `Database=`.
2. SQL login for the broker computer account (`DOMAIN\BROKER1$`) has **dbcreator** + public server roles (needed once — the wizard migrates WID into SQL).
3. Instance collation is **case-insensitive**: `Invoke-Sqlcmd -ServerInstance <sql> -Query "SELECT SERVERPROPERTY('Collation')"` → must contain `_CI_`.
4. The driver named in the string is installed on the broker (Fix 3 table).
5. `-DatabaseFilePath` (if used) exists on the **SQL server** and the SQL service account can write there.

```powershell
Set-RDConnectionBrokerHighAvailability -ConnectionBroker <broker1.fqdn> `
  -DatabaseConnectionString 'DRIVER={ODBC Driver 17 for SQL Server};SERVER=<sql.fqdn>;Trusted_Connection=Yes;APP=Remote Desktop Services Connection Broker;DATABASE=RDCB' `
  -ClientAccessName '<rdcb.contoso.com>'
Add-RDServer -Server <broker2.fqdn> -Role RDS-CONNECTION-BROKER -ConnectionBroker <broker1.fqdn>
```
</details>

<details><summary>Fix 5 — Client access name DNS / load balancer wrong</summary>

```powershell
$can = '<rdcb.contoso.com>'
Resolve-DnsName $can -Type A | Select Name, IPAddress, TTL
(Resolve-DnsName $can -Type A).IPAddress | ForEach-Object { Test-NetConnection $_ -Port 3389 | Select RemoteAddress, TcpTestSucceeded }
# Round-robin: add a missing broker / remove a dead one
Add-DnsServerResourceRecordA -ZoneName '<contoso.com>' -Name '<rdcb>' -IPv4Address '<10.0.0.9>' -ComputerName <dns-server>
Remove-DnsServerResourceRecord -ZoneName '<contoso.com>' -Name '<rdcb>' -RRType A -RecordData '<old.ip>' -ComputerName <dns-server> -Force
```
- Round-robin has no health check — a dead broker IP keeps receiving clients until removed. Keep TTL low (e.g. 300 s) or use an internal LB with a TCP 3389 probe.
- LB: backend = brokers only, probe TCP 3389, no SSL offload, session persistence not required (broker redirects).
- Renaming the access point: `Set-RDClientAccessName -ConnectionBroker <b> -ClientAccessName <new.fqdn>` — update DNS + certs (Fix 6) **before**, and re-publish/re-subscribe feeds after.
</details>

<details><summary>Fix 6 — Broker certificates don't match the client access name</summary>

After HA, clients connect to the client access name, so `RDRedirector` and `RDPublishing` must include it in their SAN (plus RD Web/Gateway names if the same cert is reused).
```powershell
$pw = Read-Host -AsSecureString 'PFX password'
'RDRedirector','RDPublishing' | ForEach-Object {
  Set-RDCertificate -Role $_ -ImportPath '<\\share\rds-san.pfx>' -Password $pw -ConnectionBroker <active-mgmt.fqdn> -Force }
Get-RDCertificate -ConnectionBroker <active-mgmt.fqdn> | Select Role, Level, ExpiresOn, Subject
```
`Set-RDCertificate` pushes to every broker in HA. If the HTML5 web client is published, re-import the broker `.cer` on RD Web afterwards → `RDWebAccess-B.md` Fix 7.
</details>

<details><summary>Fix 7 — Users don't reconnect to their existing session</summary>

```powershell
$b = '<broker.fqdn>'
Get-RDUserSession -ConnectionBroker $b | Where UserName -eq '<sam>' | Select UserName, HostServer, SessionState, UnifiedSessionId
Get-RDSessionHost -CollectionName <c> -ConnectionBroker $b | Select SessionHost, NewConnectionAllowed
```
- Session exists on host X but user goes to Y → user connected **directly to an RDSH** (bypassing the broker) or via a stale `.rdp` without `loadbalanceinfo`. Re-download from RD Web / re-subscribe feed.
- `HostServer` shown for a session that no longer exists → stale directory entry: log the ghost session off (`Invoke-RDUserLogoff -HostServer <h> -UnifiedSessionID <id> -Force`); if it persists, restart `Tssdis` on the brokers one at a time.
- Host set to `NewConnectionAllowed = No` still accepts reconnections — that's by design (drain mode).
- User profile disk "already in use" on the new host → session was actually lost; clean up the UPD lock (FSLogix/UPD runbooks).
</details>

<details><summary>Fix 8 — Remove a dead broker from an HA deployment</summary>

```powershell
# From a surviving broker; make it the management server first
Set-RDActiveManagementServer -ManagementServer <surviving.fqdn>
Remove-RDServer -Server <dead.fqdn> -Role RDS-CONNECTION-BROKER -ConnectionBroker <surviving.fqdn> -Force
Remove-DnsServerResourceRecord -ZoneName '<contoso.com>' -Name '<rdcb>' -RRType A -RecordData '<dead.ip>' -ComputerName <dns-server> -Force
```
Also remove its SQL login. A replacement broker: install matching driver → `Add-RDServer -Role RDS-CONNECTION-BROKER` → grant SQL login → add DNS/LB → re-run `Set-RDCertificate` so it gets the certs.
**Destructive/irreversible:** there is no supported path from HA back to a single WID broker — do not try to "un-HA" by deleting the DB.
</details>

---
## Escalation Evidence

```
RDS Connection Broker escalation
Tenant/customer:            <name>
Deployment brokers:         <b1>, <b2>          Active management server: <fqdn>
Client access name:         <fqdn>   DNS -> <ip list>   LB? <yes/no + probe>
HA database:                <SQL instance / Azure SQL / listener>  Driver in string: <...>
ODBC drivers per broker:    <b1: ...> <b2: ...>
Tssdis / RDMS status:       <b1: ...> <b2: ...>
Broker certs (Role/Level/Expires): <RDRedirector ...> <RDPublishing ...>
Symptom start (UTC):        <time>     Change just before?  <CU / SQL patch / cert / DNS>
SessionBroker/Admin errors: <Id + first line>
RDSH SessionBroker-Client errors: <host + Id>
Users affected:             <all / subset / only reconnects>
Script output attached:     Get-RDConnectionBrokerDiagnostics_<date>.csv  (Y/N)
Steps already taken:        <fix numbers>
```

---
## 🎓 Learning Pointers
- The broker is **two** things: `Tssdis` (routing + session directory, runs on every broker, active-active) and `RDMS` (management, runs on one). Losing the management server breaks Server Manager, not connections — don't panic-reboot the survivors. [Configure RD Connection Broker for high availability](https://learn.microsoft.com/windows-server/remote/remote-desktop-services/rds-connection-broker-cluster)
- The HA wizard error "Could not create the database" has four documented causes — string casing, `dbcreator`, case-sensitive collation, driver version. [Error after completing HA configuration](https://learn.microsoft.com/troubleshoot/windows-server/remote/error-configuration-rd-connection-brokers-high-availability)
- `Set-RDConnectionBrokerHighAvailability` takes a secondary connection string purely so SQL-auth passwords can be rotated without an outage — use it if you're on Azure SQL with SQL logins. [Set-RDConnectionBrokerHighAvailability](https://learn.microsoft.com/powershell/module/remotedesktop/set-rdconnectionbrokerhighavailability)
- A driver mismatch is the #1 "everything broke after we patched SQL" cause; the driver named in the string must exist on **every** broker, including ones added later. [Download ODBC Driver for SQL Server](https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server)
- Once HA is on, every RDS certificate conversation includes the client access name — plan the SAN before you run the wizard.
- Sibling runbooks cover the other RDS roles: `RDGateway-B.md`, `RDWebAccess-B.md`, `RDSLicensing-B.md`.
