# Windows Server DHCP Role — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why the server-side role behaves as it does, not just what command to run.

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

- **Applies to:** the Windows Server DHCP Server role (DHCP Server feature), Server 2016 through 2025, in standalone, split-scope, and DHCP Failover configurations.
- **Covers:** scope/superscope/multicast-scope architecture, DHCP Failover (hot standby and load-balance modes), DHCP Policies (vendor class / MAC-based option assignment), secure dynamic DNS updates and the `DhcpServerDnsCredential` account, the JET-based database and its backup/restore/repair model, audit logging, and AD authorization.
- **Does not cover:** client-side DORA handshake, lease renewal timing (T1/T2), APIPA fallback, or IP-helper/relay configuration on the network device side — all covered in `DHCP-Client-A.md`/`DHCP-Client-B.md`, which this runbook picks up from at the server boundary. Also out of scope: DHCPv6/SLAAC (different protocol), non-Windows DHCP servers, and cloud-native VNet/VPC DHCP (fully abstracted, no equivalent server role to administer).
- **Licensing/edition:** DHCP Server is a Windows Server role available on Standard and Datacenter editions, including Server Core (unlike NPAS, DHCP has no Desktop Experience requirement). No separate license SKU.
- **Admin roles needed:** local Administrators on the DHCP server for most operations; **DHCP Administrators** domain local group for delegated, non-Domain-Admin management; `Add-DhcpServerInDC`/`Remove-DhcpServerInDC` (server authorization) requires Enterprise Admins rights since server authorization is a forest-wide object under the Configuration partition.
- **Current platform status (2026):** DHCP Server remains a fully supported, actively maintained core infrastructure role with no deprecation signal. DHCP Failover (introduced Server 2012 R2) is the current recommended high-availability model — legacy split-scope (two independently configured, non-communicating servers each holding half a range) is considered a legacy pattern that Failover has functionally superseded, though it still appears in older environments and is not itself deprecated.

---

## How It Works

<details><summary>Full architecture</summary>

### Scopes, superscopes, and multicast scopes

A **scope** is the fundamental unit of DHCP configuration: one IP range mapped to one subnet, with its own lease duration, options, exclusions, and reservations. A **superscope** is an administrative grouping of multiple scopes — most commonly used when a single physical segment needs more than one logical IP range (e.g., after outgrowing the original subnet and adding a secondary range on the same VLAN, sometimes called "IP address multihoming"). Superscopes do not merge address pools into one lease-eligible space automatically for a given client's subnet identity; they let the server present multiple scopes' worth of options and answer DISCOVERs for either range on that segment, but a relay agent's `giaddr` and the server's own scope-to-subnet mapping still govern which specific scope a given request is evaluated against.

A **multicast scope** is a distinct object type for MADCAP (Multicast Address Dynamic Client Allocation Protocol) — allocating multicast group addresses, not unicast host addresses. It shares the DHCP Server role's management console but is functionally unrelated to standard client leasing; most MSP environments never touch this unless supporting specific multicast-streaming applications.

### DHCP Failover — the modern HA model

DHCP Failover creates a **relationship** between exactly two DHCP servers for a given scope (or scopes), replicating lease state between them so either can serve the full range if the other is unavailable. Two modes:

- **Hot standby mode:** one server is Active, the other is Standby (passive, only serves if the Active partner is down). Best when servers are in different physical/logical locations (e.g., hub-and-spoke, branch office backed by a central DC).
- **Load balance mode:** both servers actively serve simultaneously, splitting the client base by a hash of the client's MAC address according to `LoadBalancePercent` (default 50/50, adjustable). This is the more common mode for two servers at the same site.

Both modes share critical safety parameters:

- **MCLT (Maximum Client Lead Time):** the maximum amount of time either partner can safely extend a lease *unilaterally* if it believes the other partner is down, without risking a duplicate-address conflict if the "down" partner turns out to still be up (split-brain). Default 1 hour. This is the mechanism that makes `PartnerDown` state safe rather than catastrophic — it bounds the blast radius of split-brain to MCLT's window.
- **STATE model:** `Normal` (both healthy, replicating) → `CommunicationInterrupted` (sync channel down, neither has declared failure yet — informational, watch it) → `PartnerDown` (one server manually or automatically declared the other unreachable; it now serves the full range alone, honoring MCLT) → `Recover`/`RecoverWait`/`RecoverDone` (reconciliation sequence once the down partner returns).
- Failover relationships are configured **per-scope** (or scope group), not server-wide — a server can have some scopes in Failover with one partner and other scopes entirely standalone.

Legacy **split-scope** (two servers, each independently configured with a disjoint sub-range of the same subnet, typically an 80/20 or 70/30 split, no communication between them) predates Failover and is still functional but has no automatic reconciliation — if one server's range runs low while the other has headroom, nothing rebalances it, and an admin must manually adjust ranges. Converting an existing split-scope to a proper Failover relationship is the standard modernization path.

### DHCP Policies vs. scope/server options

Options (router, DNS, domain name, etc.) can be set at up to four levels, most specific wins: **Server level** (all scopes) → **Scope level** (this scope only) → **Policy level** (conditional, based on vendor class, user class, MAC address prefix, or other DHCPDISCOVER fields — e.g., "give VoIP phones a different DNS/TFTP option set than laptops on the same subnet") → **Reservation level** (this specific device). DHCP Policies are the mechanism for differentiating device classes on a shared subnet without needing separate VLANs/scopes for each — commonly used for VoIP phone provisioning (Option 43/vendor-specific), IoT device isolation via shorter lease durations, or serving a different boot server (Option 66/67, PXE) only to devices matching a specific vendor class string.

### Secure dynamic DNS updates and the DHCP DNS credential

When DHCP is configured to register client A/PTR records in DNS on the client's behalf (the default and near-universal configuration in AD-integrated environments), it does so using **secure dynamic updates**, which require the DHCP server to authenticate as a specific AD identity when writing to the zone. By default this is the DHCP server's own computer account, but in Failover/multi-server environments this is commonly overridden with a dedicated service account (`Set-DhcpServerDnsCredential` / `Get-DhcpServerDnsCredential`) so that **either** failover partner can register records under a consistent identity regardless of which one actually served the lease — using each server's own computer account instead would cause records registered by Server A to become unmodifiable by Server B (and vice versa) since neither computer account has rights to records the other created, a classic "why do half my DNS records look orphaned" root cause in Failover deployments that skipped this step.

This service account has **no built-in password rotation or expiry monitoring** from the DHCP role itself. When the account's password expires under normal AD password policy, DHCP leasing is entirely unaffected (a separate code path) while DNS registration for every new/renewed lease silently fails — a slow-burning fault that often isn't noticed until name resolution for recently-provisioned devices stops working days or weeks later.

### The DHCP database: JET, not SQL

The DHCP server database (`%SystemRoot%\System32\dhcp\dhcp.mdb`) uses the legacy JET (ESE) database engine — the same family used historically by AD DS and Exchange, not a SQL Server backend. It self-maintains via **online compaction** during low-activity periods and creates **automatic backups** every 60 minutes by default (`BackupInterval` setting) to `%SystemRoot%\System32\dhcp\backup\`. Corruption (JET error codes referencing `dhcp.mdb` or `.chk`/`.log` files) requires either the built-in `jetpack.exe` repair utility (offline, requires stopping the service) or a restore from the automatic backup — there is no SQL-style transaction log shipping or always-on replica; Failover is the HA mechanism, not database replication in the SQL sense.

### Audit logging

DHCP Server audit logging (distinct from Windows Security auditing used by NPS) is enabled by default and writes to `%SystemRoot%\System32\dhcp\DhcpSrvLog-<Day>.log` — one file per day of the week, overwritten weekly by default (`DhcpSrvLog-Mon.log` from this week overwrites last week's Monday log). This is the authoritative source for lease transaction history (DHCPDISCOVER/OFFER/REQUEST/ACK/NAK/DECLINE/RELEASE events with timestamps and MAC addresses) and is the first place to look for "when exactly did this device get this address" questions — more useful for that specific question than the DHCP Server's Windows Event Log entries, which cover service-level events rather than per-lease transaction detail.

</details>

---

## Dependency Stack

```
Layer 6 — Active Directory authorization
    Server object registered under CN=NetServices in the Configuration partition
    (Get-DhcpServerInDC); requires Enterprise Admins to add/remove
        │
Layer 5 — DHCP Server service (DHCPServer) running, JET database (dhcp.mdb) intact
        │
Layer 4 — Scope / Superscope / Multicast Scope definitions
    Correct StartRange/EndRange, State = Active, no overlap with adjacent scopes or
    statically assigned addresses
        │
Layer 3 — [Optional] DHCP Failover relationship
    Partner reachable, State = Normal, MCLT/StateSwitchInterval tuned appropriately,
    LoadBalancePercent (load-balance mode) or Active/Standby role (hot standby mode) set
        │
Layer 2 — Options resolution: Server → Scope → Policy → Reservation
    (DHCP Policies add conditional branching based on vendor class/MAC/user class
    on top of the base Server/Scope/Reservation hierarchy)
        │
Layer 1 — [Optional] Secure dynamic DNS update
    DhcpServerDnsCredential account valid (not expired/disabled/locked),
    has update rights on the target DNS zone
        │
Lease granted + (optionally) DNS record registered — full client stack functional
```

A fault at Layer 6 (unauthorized server) is silent and total — the server simply never leases to anyone. A fault at Layer 1 (DNS credential) is silent and partial — leasing continues perfectly while DNS registration alone fails. These two failure modes look nothing alike from a symptom perspective despite both being "server-side, not client-side" — always determine which layer before troubleshooting further.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Server running, but zero devices on any subnet ever get an address from it | Server not authorized in AD | `Get-DhcpServerInDC` |
| One specific scope never leases, others on the same server work fine | Scope `State: Inactive`, or `giaddr`/subnet mismatch | `Get-DhcpServerv4Scope` — check `State` |
| Leasing works, but new/renewed devices stop resolving by name after some time | DNS dynamic update credential's password expired | `Get-DhcpServerDnsCredential`; check `PasswordExpired` on the AD account |
| Failover partner shows `PartnerDown`, other server appears fine | Network path between partners broken, or genuine partner outage | `Get-DhcpServerv4Failover`; confirm partner reachability independently |
| Failover partner shows `CommunicationInterrupted` for an extended period | Sync channel (TCP 647 by default) blocked or intermittently failing | Firewall/ACL check between the two DHCP servers on port 647 |
| Same device gets different option sets (DNS/gateway) depending on which server answers | Failover configured but options set independently per-server rather than via the shared scope config, or a DHCP Policy applies inconsistently | Compare `Get-DhcpServerv4OptionValue` output on both partners |
| VoIP phones/IoT devices get wrong options while laptops on the same subnet are fine | DHCP Policy condition (vendor class/MAC prefix) not matching as expected | `Get-DhcpServerv4Policy`; verify condition syntax against actual DHCPDISCOVER vendor class string |
| Service won't start, System/Application log shows JET/database errors | `dhcp.mdb` corruption | Event IDs referencing `jet.log`/database; see Remediation Playbook 3 |
| Records registered by one failover partner can't be modified/cleaned up by the other | Each server used its own computer account for dynamic updates instead of a shared `DhcpServerDnsCredential` | `Get-DhcpServerDnsCredential` on both partners — should match |
| Superscope member exhausted while sibling scope has capacity, clients still fail | Relay/router not presenting both ranges on the same segment, or clients genuinely belong only to the exhausted scope's subnet | Confirm L3 device's helper-address/secondary-subnet config |
| Split-scope (legacy, no Failover) — one server's range exhausted, other has room | No automatic rebalancing exists in split-scope; this is expected behavior, not a fault | Manually adjust ranges, or migrate to proper Failover |
| Audit log shows no entries for a known recent lease | Logging disabled, or log file rotated/overwritten (weekly reuse pattern) | `Get-DhcpServerAuditLog`; confirm `Enable` is true and check correct day's file |

---

## Validation Steps

**1. Role, service, and authorization**
```powershell
Get-WindowsFeature DHCP
Get-Service DHCPServer | Select-Object Status, StartType
Get-DhcpServerInDC
```
Good: feature installed, service running/automatic, this server listed. Bad: any of the three missing — nothing downstream matters until this layer is solid.

**2. Scope inventory and state**
```powershell
Get-DhcpServerv4Scope | Select-Object ScopeId, Name, State, SubnetMask, LeaseDuration
```
Good: all production scopes `Active`. Bad: an `Inactive` scope that should be serving — a common leftover from maintenance windows.

**3. Superscope/multicast scope inventory (if used)**
```powershell
Get-DhcpServerv4Superscope
Get-DhcpServerv4MulticastScope -ErrorAction SilentlyContinue
```
Good: expected groupings present. Confirms whether superscope logic is even in play before troubleshooting a multi-range segment.

**4. Failover relationship state**
```powershell
Get-DhcpServerv4Failover | Select-Object Name, ScopeId, PartnerServer, Mode, State, LoadBalancePercent, MaxClientLeadTime
```
Good: `State: Normal` on every relationship. Bad: `PartnerDown` or `CommunicationInterrupted` sustained beyond a normal maintenance/reboot window.

**5. DHCP Policies (if used)**
```powershell
Get-DhcpServerv4Policy | Select-Object Name, Enabled, ProcessingOrder, Condition
Get-DhcpServerv4Policy -PolicyName "<name>" | Get-DhcpServerv4OptionValue
```
Good: intended conditional policies enabled and correctly ordered relative to each other (first match wins, same as NPS-style ordering). Bad: a policy with an unreachable/never-matching condition string.

**6. DNS dynamic update credential**
```powershell
$cred = Get-DhcpServerDnsCredential
Get-ADUser -Identity $cred.UserName -Properties PasswordExpired, Enabled, LockedOut -ErrorAction SilentlyContinue
```
Good: `PasswordExpired: False`, `Enabled: True`, `LockedOut: False`. This is the single highest-value check for "leasing works but DNS doesn't" tickets.

**7. Database and audit log health**
```powershell
Get-Service DHCPServer | Select-Object Status
Get-DhcpServerAuditLog
Get-Item "$env:SystemRoot\System32\dhcp\DhcpSrvLog-$(Get-Date -Format ddd).log" -ErrorAction SilentlyContinue | Select-Object LastWriteTime, Length
```
Good: service running, audit logging `Enable: True`, today's log file recently updated with non-trivial size. Bad: logging disabled, or a zero-byte/stale log file despite active leasing traffic.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm this is a server-side fault at all
1. Reproduce on a device confirmed to be on a healthy VLAN/scope elsewhere served by the same server — if it also fails, the fault is genuinely server-wide (authorization, service state).
2. If only one scope/subnet fails, narrow immediately to that scope's own state and options rather than investigating the whole server.

### Phase 2 — Authorization and service health
1. `Get-DhcpServerInDC` — if this server is missing, nothing else matters; authorize it first (Remediation Playbook 1).
2. `Get-Service DHCPServer` — if stopped, check System/Application event logs for the stop reason (crash vs. manual vs. database corruption) before blindly restarting.

### Phase 3 — Scope-level isolation
1. Confirm the specific scope's `State` and `PercentageInUse`.
2. Confirm no overlapping exclusion ranges or reservations are unintentionally starving the pool.
3. If a superscope is involved, confirm which member scope the failing subnet actually maps to — don't assume the superscope grouping implies shared capacity.

### Phase 4 — Failover-specific isolation (only if Failover is configured for the affected scope)
1. Check `State` on this server; if possible, check the partner's view too (state should agree — a mismatch itself is diagnostic).
2. If `PartnerDown`: confirm whether the partner is genuinely down (ping/RDP/service check) versus just a broken sync channel with the partner otherwise healthy — these have different remediation paths.
3. If `CommunicationInterrupted`: check TCP 647 (default failover port) reachability between the two servers before assuming a config problem.

### Phase 5 — Options and Policy resolution
1. Compare actual leased option values (`ipconfig /all` on an affected client) against what's expected.
2. Walk the resolution order: Server-level options → Scope-level → Policy-level (if a DHCP Policy's condition matches this client) → Reservation-level. Identify which level is actually supplying the wrong value.
3. For Policy-driven mismatches, verify the policy's condition against the client's actual DHCPDISCOVER vendor-class/user-class string — a packet capture is the definitive source if the condition logic itself is in doubt.

### Phase 6 — DNS registration failures (leasing healthy, names not resolving)
1. Confirm leasing itself is unaffected (rule out Phases 1-5 first) — this phase is specifically for "DHCP works, DNS doesn't."
2. Check `Get-DhcpServerDnsCredential` and the underlying AD account's password/enabled/lockout state.
3. Confirm the account has actual update rights on the target zone (typically via the `DnsUpdateProxy` group membership, or explicit ACL) — a valid, non-expired account can still fail if zone permissions were changed independently.

### Phase 7 — Database/corruption recovery
1. Confirm via event log that this is genuinely a JET/database fault, not a permissions or disk-space issue (check free space on the system volume first — the JET engine fails ungracefully when it can't write).
2. Follow Remediation Playbook 3 (repair or restore-from-backup) rather than attempting manual `.mdb` file manipulation.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Authorize a new or rebuilt DHCP server</summary>

**Scenario:** A new DHCP server was stood up (or an existing one rebuilt) and is running but leasing nothing.

```powershell
# Requires Enterprise Admins rights — authorization is a forest-wide Configuration-partition object
Add-DhcpServerInDC -DnsName <server-fqdn> -IPAddress <server-ip>
Get-DhcpServerInDC

# Restart to apply immediately rather than waiting for the periodic authorization re-check
Restart-Service DHCPServer

# Confirm leasing resumes
Get-DhcpServerv4Scope | Select-Object ScopeId, State
```
**Rollback:** `Remove-DhcpServerInDC -DnsName <server-fqdn> -IPAddress <server-ip>` immediately stops the server from leasing — use only if the authorization itself was a mistake (e.g., wrong server stood up).
</details>

<details><summary>Playbook 2 — Convert legacy split-scope to DHCP Failover</summary>

**Scenario:** Two independently managed servers each hold a disjoint static portion of the same subnet's range, with no automatic sync or rebalancing.

```powershell
# On the primary server, establish the Failover relationship for the target scope
Add-DhcpServerv4Failover `
  -ComputerName <primary-server> `
  -PartnerServer <secondary-server> `
  -Name "<relationship-name>" `
  -ScopeId <scope-id> `
  -LoadBalancePercent 50 `
  -MaxClientLeadTime 01:00:00

# This automatically replicates the scope configuration and lease state to the partner —
# the previously independent secondary-server scope, if it still exists, must be removed
# first to avoid a conflicting duplicate definition:
Remove-DhcpServerv4Scope -ComputerName <secondary-server> -ScopeId <scope-id> -ErrorAction SilentlyContinue

# Verify
Get-DhcpServerv4Failover -ComputerName <primary-server> -Name "<relationship-name>"
```
**Rollback:** `Remove-DhcpServerv4Failover -Name "<relationship-name>"` reverts to independent (non-replicated) scope management on each server — re-establish the original static split-range configuration manually if reverting fully.
</details>

<details><summary>Playbook 3 — Recover from database corruption</summary>

**Scenario:** DHCPServer service fails to start, event log references JET database errors against `dhcp.mdb`.

```powershell
Stop-Service DHCPServer

# ALWAYS back up the current (corrupted) files before attempting repair
Copy-Item "$env:SystemRoot\System32\dhcp\dhcp.mdb" "$env:SystemRoot\System32\dhcp\dhcp.mdb.bak"

# Attempt in-place repair first (least data loss)
jetpack.exe "$env:SystemRoot\System32\dhcp\dhcp.mdb" "$env:SystemRoot\System32\dhcp\temp.mdb"
Start-Service DHCPServer

# If repair fails or the service still won't start cleanly, restore from the automatic
# hourly backup instead (accepts up to ~1 hour of lease data loss, acceptable in almost
# all real scenarios since leases simply get renegotiated by clients)
Stop-Service DHCPServer
Restore-DhcpServer -Path "$env:SystemRoot\System32\dhcp\backup"
Start-Service DHCPServer

# Verify scopes and leases returned
Get-DhcpServerv4Scope
Get-DhcpServerv4Lease -ScopeId <scope-id> | Measure-Object
```
**Rollback:** the `dhcp.mdb.bak` copy taken before repair is itself the rollback point if `jetpack.exe` produces a worse outcome — stop the service, replace the file, restart.
</details>

<details><summary>Playbook 4 — Rotate the DNS dynamic update credential</summary>

**Scenario:** Scheduled/proactive credential rotation, or recovery from an expired-password DNS registration failure.

```powershell
# Reset the service account's password in AD first
$newPassword = Read-Host -AsSecureString "New password for the DHCP DNS update account"

# Apply to DHCP on EVERY server in the Failover relationship (or standalone server) —
# this is not automatically synced by Failover replication, must be set on each server
Set-DhcpServerDnsCredential -UserName "<svc-account>" -DomainName "<domain-fqdn>" -Password $newPassword

# Repeat on the failover partner if applicable
Set-DhcpServerDnsCredential -ComputerName <partner-server> -UserName "<svc-account>" -DomainName "<domain-fqdn>" -Password $newPassword

# Confirm
Get-DhcpServerDnsCredential
Get-DhcpServerDnsCredential -ComputerName <partner-server>
```
**Rollback:** revert to the previous credential only if it's still valid (not the scenario that triggered this playbook); otherwise forward-fix by setting a new valid password rather than attempting to restore an expired one.
</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects DHCP Server role diagnostic evidence for escalation.
.NOTES
    Run on the DHCP server itself with local Administrator rights.
#>
$out = "C:\DHCPServer-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

Get-WindowsFeature DHCP | Out-File "$out\feature-state.txt"
Get-Service DHCPServer | Out-File "$out\service-state.txt"
Get-DhcpServerInDC | Out-File "$out\authorization.txt"
Get-DhcpServerv4Scope | Export-Csv "$out\scopes.csv" -NoTypeInformation
Get-DhcpServerv4Scope | ForEach-Object { Get-DhcpServerv4ScopeStatistics -ScopeId $_.ScopeId } |
  Export-Csv "$out\scope-stats.csv" -NoTypeInformation
Get-DhcpServerv4Superscope -ErrorAction SilentlyContinue | Export-Csv "$out\superscopes.csv" -NoTypeInformation
Get-DhcpServerv4Failover -ErrorAction SilentlyContinue | Export-Csv "$out\failover-relationships.csv" -NoTypeInformation
Get-DhcpServerv4Policy -ErrorAction SilentlyContinue | Export-Csv "$out\policies.csv" -NoTypeInformation
Get-DhcpServerDnsCredential | Out-File "$out\dns-credential.txt"
Get-DhcpServerAuditLog | Out-File "$out\audit-log-config.txt"
Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Microsoft-Windows-DHCP-Server']]]" -MaxEvents 100 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\dhcp-server-events.csv" -NoTypeInformation
Copy-Item "$env:SystemRoot\System32\dhcp\DhcpSrvLog-$(Get-Date -Format ddd).log" "$out\" -ErrorAction SilentlyContinue

Write-Host "Evidence collected to $out"
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip"
```

---

## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-DhcpServerInDC` / `Add-DhcpServerInDC` | Check/add AD authorization |
| `Get-DhcpServerv4Scope` / `Set-DhcpServerv4Scope` | Inventory/modify scopes |
| `Get-DhcpServerv4ScopeStatistics` | Utilization per scope |
| `Get-DhcpServerv4Superscope` | Superscope groupings |
| `Get-DhcpServerv4Failover` / `Add-DhcpServerv4Failover` | Failover relationship state/creation |
| `Invoke-DhcpServerv4FailoverReplication` | Force resync between failover partners |
| `Get-DhcpServerv4Policy` | DHCP Policy inventory (conditional option assignment) |
| `Get-DhcpServerv4OptionValue` / `Set-DhcpServerv4OptionValue` | Scope/server/policy option values |
| `Get-DhcpServerDnsCredential` / `Set-DhcpServerDnsCredential` | Secure dynamic DNS update identity |
| `Get-DhcpServerAuditLog` | Audit logging configuration |
| `Get-DhcpServerv4Lease` / `Remove-DhcpServerv4Lease` | Lease inventory/manual reclamation |
| `Backup-DhcpServer` / `Restore-DhcpServer` | Manual database backup/restore |
| `jetpack.exe` | Offline JET database repair (service must be stopped) |
| `Export-DhcpServer` / `Import-DhcpServer` | Full server config export/import (server migration) |

---

## 🎓 Learning Pointers

- **Server authorization and DNS-credential health fail in opposite ways — one is loud and total, the other is silent and partial.** An unauthorized server leases to nobody, immediately and obviously. An expired DNS-update credential leases perfectly to everyone while DNS registration quietly stops — always determine which failure shape you're looking at before picking a diagnosis path. [MS Docs: DHCP top-level overview](https://learn.microsoft.com/en-us/windows-server/networking/technologies/dhcp/dhcp-top).
- **DHCP Failover's MCLT (Maximum Client Lead Time) is the specific mechanism that makes `PartnerDown` state safe rather than a split-brain risk** — it bounds how long a surviving partner will unilaterally extend leases before requiring reconciliation. Understanding this number is what separates "monitor and investigate" from "emergency" when you see `PartnerDown`.
- **Split-scope (legacy, pre-Failover) has zero automatic rebalancing** — two independently configured ranges will drift in utilization over time with nothing correcting it, unlike a proper Failover relationship's load-balance hashing. Flag any split-scope found during environment review as a modernization candidate, not just "it still works."
- **The DHCP database uses the JET/ESE engine (the same family AD DS historically used), not SQL Server** — this shapes both the failure modes (offline `jetpack.exe` repair, not SQL-style corruption recovery) and the backup model (automatic hourly file-based backups, not transaction log shipping).
- **DHCP audit logs rotate weekly by day-of-week filename** (`DhcpSrvLog-Mon.log`, etc.) and get overwritten every 7 days by default — if you need lease-transaction history older than a week, it's already gone unless log retention was explicitly extended. Build this into any client conversation about compliance/audit requirements around DHCP lease history.
- **For client-side symptoms** (APIPA, DORA handshake, relay/IP-helper architecture, lease renewal timing) **see `DHCP-Client-A.md` / `DHCP-Client-B.md`** — this runbook intentionally does not duplicate that content.
