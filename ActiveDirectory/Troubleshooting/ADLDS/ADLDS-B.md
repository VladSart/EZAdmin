# AD LDS (Lightweight Directory Services) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run these against the **server hosting the AD LDS instance** (not a domain controller, unless it's co-located there — AD LDS runs on member servers, standalone servers, and DCs alike):

```powershell
# 1. Is the instance service actually running? (service name is always ADAM_<instanceName>)
Get-Service "ADAM_*" | Select-Object Name, Status, StartType

# 2. Can you bind to it at all? (confirms LDAP port is listening and the instance is healthy)
Get-ADRootDSE -Server "localhost:<ldapPort>" | Select-Object namingContexts, configurationNamingContext, dsServiceName

# 3. Which instances exist on this box, and what ports/partitions do they own?
dsdbutil "list instances" q q

# 4. If this is a replication problem, check the instance's replication partners
repadmin /showrepl localhost:<ldapPort>

# 5. If this looks like an authentication (bind) failure, isolate LDAP-local vs. AD DS-proxied auth first
#    (see Diagnosis step 3 — this is the single most common misdiagnosis on this topic)
```

| Result | Interpretation |
|---|---|
| `ADAM_<name>` service not present at all | No instance with that name exists on this box — confirm the instance name/port with whoever owns the application, don't assume it's "broken" |
| Service present but `Stopped` | Go to [Fix 1](#common-fix-paths) |
| Service `Running` but `Get-ADRootDSE` times out or refuses | Port mismatch, firewall, or instance-level LDAP policy lockout — go to [Fix 2](#common-fix-paths) |
| `Get-ADRootDSE` succeeds but the application still can't bind | Almost always an application-side bind DN/port/credential config problem, not the instance — go to [Fix 5](#common-fix-paths) |
| `repadmin /showrepl` shows a replication partner with a large "last successful sync" gap or an error | Go to [Fix 3](#common-fix-paths) |
| Bind fails only for certain users, not all | This is a [proxy/bind-redirection](#common-fix-paths) issue (Fix 4), not an AD LDS instance problem |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Windows Server, "Active Directory Lightweight Directory Services" role installed
(Install-WindowsFeature ADLDS — a Windows feature, NOT dcpromo/Install-ADDSDomainController)
  └── One or more independently-created INSTANCES on this box, each:
        ├── Own Windows service: ADAM_<instanceName>
        ├── Own LDAP port + own SSL port (chosen at create time — no fixed default;
        │   389/636 conflict if the box is also a DC, so 50000/50001 is the common
        │   convention for co-located installs, but it is only a convention, not a rule)
        ├── Own data files under the instance's data directory (its own database —
        │   architecturally separate from NTDS.dit even on a DC)
        └── Own schema + own application directory partition(s) — NOT the AD DS schema,
            and changes to one instance's schema NEVER touch AD DS or any other instance
              └── (Optional) Replication: 2+ instances of the SAME instance grouped into
                  a "configuration set" — multi-master, same higher-version/
                  newer-timestamp conflict resolution as AD DS, but its OWN independent
                  replication topology (repadmin works, but only when pointed at
                  host:port — there is no site/KCC awareness shared with AD DS)
              └── (Optional) Authentication model — pick ONE per object, not global:
                    ├── Instance-local principal: user object lives IN the AD LDS
                    │   partition, password IS the AD LDS password (unrelated to any
                    │   AD DS account) — simplest, but yet another password to manage
                    └── Bind-redirection ("proxy") object: a userProxy object in AD LDS
                        holding a real AD DS account's SID — binding to it forwards the
                        password check to AD DS live, so it REQUIRES network reachability
                        from the AD LDS server to a DC in that SID's domain and an
                        unlocked/unexpired AD DS account — this is the #1 source of
                        "AD LDS auth randomly fails for some users" tickets
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the instance is running and reachable.**
   ```powershell
   Get-Service "ADAM_*"
   Test-NetConnection -ComputerName localhost -Port <ldapPort>
   ```
   Expected: service `Running`, `TcpTestSucceeded : True`. If the service is missing entirely, stop — you have the wrong server or wrong instance name.

2. **Bind and read RootDSE to confirm the instance itself is healthy.**
   ```powershell
   Get-ADRootDSE -Server "localhost:<ldapPort>"
   ```
   Expected: returns `namingContexts` including `CN=Configuration,CN={GUID}` and any application partitions. A hang or refusal here means the instance process is up but the database/LDAP stack inside it is not — treat as a service-level problem, not a network one.

3. **Isolate instance-local auth from bind-redirection (proxy) auth — do this BEFORE assuming AD LDS is broken.**
   ```powershell
   Get-ADObject -Server "localhost:<ldapPort>" -Filter "objectClass -eq 'userProxy'" -Properties objectSid | Select-Object DistinguishedName, objectSid
   ```
   If the failing account shows up here as a `userProxy` object, the failure is almost certainly happening on the **AD DS side** (locked/expired/disabled account, or the AD LDS server can't reach a DC for that account's domain) — not inside AD LDS at all. Validate the real account:
   ```powershell
   Get-ADUser -Identity <sAMAccountName> -Properties LockedOut, Enabled, PasswordExpired -Server <realDomainDC>
   ```

4. **Check replication health if this instance is part of a configuration set.**
   ```powershell
   repadmin /showrepl localhost:<ldapPort>
   repadmin /replsummary localhost:<ldapPort>
   ```
   Expected: 0 failures across all partners, recent "last success" timestamps. Note `repadmin` requires the `host:port` form for AD LDS — plain hostname alone targets AD DS on that box if it's also a DC, which silently produces the wrong (or empty) output.

5. **Check for a recent service-account change on a replication partner.**
   AD LDS instances in the same configuration set replicating while two or more partners' service accounts are changed at the same time is a documented cause of replication breakage — confirm nobody changed the "Log On As" account on `ADAM_<name>` on more than one replica recently. If they did, let replication fully converge on the first change before touching the next partner.

---
## Common Fix Paths

<details><summary>Fix 1 — Instance service won't start</summary>

```powershell
Get-Service "ADAM_*" | Where-Object Status -ne 'Running'
Get-EventLog -LogName "AD LDS (<instanceName>)" -Newest 20 -EntryType Error, Warning
Start-Service "ADAM_<instanceName>"
```
Most common causes: port already in use by another process/instance (check with `netstat -ano | findstr <ldapPort>`), the instance's own service account password expired or was changed without updating the service (`Set-Service`/services.msc "Log On As" tab), or the underlying data files were moved/deleted. Check the instance's dedicated event log (`AD LDS (<instanceName>)`, NOT the generic Directory Service log — that's AD DS only) for the specific error code before guessing further.

**Rollback:** none needed — starting a stopped service is non-destructive.
</details>

<details><summary>Fix 2 — Reachable service, but binds fail/time out</summary>

```powershell
netstat -ano | findstr <ldapPort>
Get-NetFirewallRule -DisplayName "*AD LDS*" | Select-Object DisplayName, Enabled, Direction
```
Confirm the port the client is trying is actually the port this instance is bound to — `dsdbutil "list instances" q q` shows the authoritative port list per instance. A firewall blocking the custom port (especially 50000/50001-style non-standard ports) is common when a new firewall policy is applied to a server that predates it.

**Rollback:** n/a — read-only diagnosis.
</details>

<details><summary>Fix 3 — Replication broken between configuration set partners</summary>

```powershell
repadmin /showrepl localhost:<ldapPort> /csv | ConvertFrom-Csv | Format-Table -AutoSize
repadmin /replsummary localhost:<ldapPort>
```
If the error is a service-account-change race (see Diagnosis step 5), let the currently-converging replica finish, THEN change the next one — do not change service accounts on two replicas of the same configuration set back-to-back. If it's a genuine link/connectivity failure between the two servers hosting the instances, treat it like any LDAP-over-TCP problem: confirm the specific instance port (not 389/636) is open both directions.

**Rollback:** if you changed a service account and want to revert, set it back to the previous account/password and restart the `ADAM_<name>` service on that replica only.
</details>

<details><summary>Fix 4 — Bind-redirection (proxy) auth failing for specific users</summary>

The AD LDS side is very likely healthy — this is an AD DS-side or network-path problem surfacing through AD LDS:
```powershell
# On the real domain DC:
Get-ADUser -Identity <sAMAccountName> -Properties LockedOut, Enabled, PasswordExpired, PasswordNeverExpires

# From the AD LDS server, confirm it can actually reach a DC for that user's domain:
Test-NetConnection -ComputerName <thatDomainDC> -Port 389
Test-NetConnection -ComputerName <thatDomainDC> -Port 88   # Kerberos, if applicable to the auth path in use
```
Common root causes: the real AD DS account is locked/disabled/expired, the `userProxy` object's stored SID points at a since-deleted or since-recreated (different SID) AD DS account, or a firewall/routing change removed the AD LDS server's path to a DC in that domain.

**Rollback:** none — this fix path is diagnostic; the actual remediation happens on the AD DS account or the network path, not inside AD LDS.
</details>

<details><summary>Fix 5 — Application connects to AD DS instead of AD LDS instance (or vice versa) by mistake</summary>

The single most common "AD LDS is broken" ticket that isn't actually an AD LDS problem: an application's connection string points at port 389 with no explicit instance/port, and on a box running both AD DS and AD LDS, 389 always resolves to AD DS. Confirm the application's LDAP connection string explicitly specifies `<server>:<instancePort>`, not a bare hostname.

**Rollback:** n/a — configuration correction on the application side.
</details>

<details><summary>Fix 6 — ADAMSync (one-way AD DS → AD LDS sync) not picking up changes</summary>

```powershell
adamsync /f <configFile.xml> <server>:<port>
```
ADAMSync does an incremental sync using a stored USN watermark from AD DS — if the sync account's read permissions on the AD DS source OU/attributes changed, or the mapped attributes in the XML config no longer match reality (a common cause after an AD DS schema extension), the run will silently skip the affected objects/attributes rather than erroring loudly. Re-run with the `/full` option, if supported by the config, or delete the stored cookie to force a full resync as a last resort — confirm with the application owner first, since a full resync can be slow on a large source OU.

**Rollback:** none required for a re-sync; it only pulls from AD DS, it never writes back to it.
</details>

---
## Escalation Evidence

```
AD LDS ESCALATION
==================
Server hostname:            <>
Instance name:               <>
LDAP port / SSL port:        <> / <>
ADAM_<name> service status:  <Running / Stopped / other>
Get-ADRootDSE bind result:   <success / timeout / refused / error text>
Auth model in use:           <instance-local / bind-redirection (proxy) / both>
If proxy: real AD DS account status (LockedOut/Enabled/PasswordExpired): <>
repadmin /showrepl result (if replicated instance):  <clean / errors — paste output>
Event log entries (AD LDS (<instanceName>) log, last 20): <paste or attach>
Application-side connection string / bind DN used:   <>
Business impact / affected application:              <>
Steps already attempted:                              <>
```

---
## 🎓 Learning Pointers

- AD LDS is a **Windows feature**, not a domain controller role — it's installed with `Install-WindowsFeature ADLDS`, never with `Install-ADDSDomainController`/dcpromo, and it can run happily on a plain member server, a standalone workgroup server, or even alongside AD DS on a DC. See [What Is AD LDS — Microsoft Learn](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/adam/what-is-active-directory-lightweight-directory-services).
- Every instance has its **own schema and its own port** — there is no shared "AD LDS schema" across instances on the same box the way there's one shared AD DS schema per forest. Assuming a schema change in one instance affects another (or affects AD DS) is a common misunderstanding.
- Before touching the AD LDS instance at all, check whether the failing account is a **bind-redirection (`userProxy`) object** — if it is, the fix is almost always on the AD DS side, not here.
- `repadmin` and the standard `ActiveDirectory` PowerShell module cmdlets (`Get-ADObject`, `Get-ADRootDSE`, etc.) work against AD LDS, but only when explicitly targeted with `-Server "host:port"` — a bare hostname silently targets AD DS instead if the box is also a DC.
- ADAMSync is **one-way only** (AD DS → AD LDS) and was designed for a specific, narrow LDAP-sync use case — it is not a general-purpose or bidirectional identity sync tool, and shouldn't be confused with directory-sync products built for that purpose.
- See [`ADLDS-A.md`](ADLDS-A.md) for the full architecture, the configuration-set replication model in depth, and the instance-removal procedure.
