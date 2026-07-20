# Windows Server DHCP Role — Hotfix Runbook (Mode B: Ops)
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

**This runbook is for the DHCP server role itself** — failover partner state, superscopes, DNS dynamic update credential, database health, and audit logging. If a single client can't get an address and the server side already looks healthy, start at `DHCP-Client-B.md` instead; come back here once the problem is confirmed server-side.

```powershell
# 1. Is the DHCP service actually running, and is the server authorized in AD?
Get-Service DHCPServer | Select-Object Status, StartType
Get-DhcpServerInDC

# 2. Scope health at a glance — utilization and state for every scope
Get-DhcpServerv4Scope | Select-Object ScopeId, Name, State
Get-DhcpServerv4Scope | ForEach-Object { Get-DhcpServerv4ScopeStatistics -ScopeId $_.ScopeId } |
  Select-Object ScopeId, Free, InUse, PercentageInUse | Sort-Object PercentageInUse -Descending

# 3. Failover relationship state (if configured — most production scopes should be)
Get-DhcpServerv4Failover | Select-Object Name, ScopeId, PartnerServer, State, Mode

# 4. DNS dynamic update credential — the #1 silent-failure cause on aging DHCP servers
Get-DhcpServerDnsCredential

# 5. Recent DHCP server audit log errors (default location, last 24h worth of entries)
Get-ChildItem "$env:SystemRoot\System32\dhcp\DhcpSrvLog-*.log" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
```

| Finding | Interpretation | Do this |
|---|---|---|
| `PercentageInUse` > 90% on any scope | Scope exhaustion imminent/active | **Fix 1** |
| `Get-DhcpServerv4Failover` shows `State: PartnerDown` | Failover partner unreachable — this server is serving alone | **Fix 2** |
| `State: CommunicationInterrupted` | Partners can't sync, but neither has declared the other down yet | **Fix 2** (monitor, don't panic-fail-over) |
| `Get-DhcpServerInDC` doesn't list this server | Server isn't authorized — silently refuses to lease to anyone | **Fix 3** |
| DNS records for DHCP clients are stale/missing, `Get-DhcpServerDnsCredential` shows an account whose password expired | Dynamic DNS update credential is broken | **Fix 4** |
| `Get-Service DHCPServer` won't start, event log shows JET/database errors | DHCP database (`dhcp.mdb`) corruption | **Fix 5** |
| Two servers on the same subnet both answering DISCOVERs, no failover relationship between them | Unmanaged split-scope or rogue second server | **Fix 6** |
| Superscope shows one member scope exhausted while sibling has free addresses | Client not roaming to the sibling scope's pool as expected | **Fix 7** |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
DHCP Server role installed, DHCPServer service running
    │
Server authorized in Active Directory (Get-DhcpServerInDC)
    │
Scope exists for the requesting subnet, State = Active
    │
    ├── Failover configured (recommended) ──▶ Partner reachable, State = Normal,
    │                                          both partners' clocks within tolerance
    │                                          (MaxClientLeadTime governs split-brain risk)
    │
    ├── Superscope (if used) ──▶ member scopes correctly grouped, each with its own
    │                             utilization tracked independently
    │
Scope has free addresses (PercentageInUse < 100%)
    │
Scope options / policies correctly resolve for the requesting client
  (server-level → scope-level → policy-level → reservation-level, most specific wins)
    │
[Optional] Secure dynamic DNS update ──▶ DhcpServerDnsCredential account valid,
                                          password not expired, has rights on the DNS zone
    │
Lease granted, written to the DHCP database (JET-based, dhcp.mdb)
    │
Audit log captures the transaction (DhcpSrvLog-*.log, enabled by default)
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm the role and authorization state**
```powershell
Get-WindowsFeature DHCP
Get-Service DHCPServer | Select-Object Status, StartType
Get-DhcpServerInDC
```
Expected: feature `Installed`, service `Running`, this server's name/IP listed by `Get-DhcpServerInDC`. A server that's running but NOT authorized will silently ignore every DHCPDISCOVER it receives — no error, no event, just no offers.

**2. Confirm scope state and utilization**
```powershell
Get-DhcpServerv4Scope | Select-Object ScopeId, Name, State, LeaseDuration
Get-DhcpServerv4Scope | ForEach-Object { Get-DhcpServerv4ScopeStatistics -ScopeId $_.ScopeId } |
  Select-Object ScopeId, Free, InUse, Reserved, PercentageInUse
```
Expected: target scope `Active`, `PercentageInUse` with meaningful headroom. `Inactive` scopes exist but never lease — a common "why isn't this VLAN's scope working" gotcha after a scope was disabled during maintenance and never re-enabled.

**3. Confirm failover relationship health (if configured)**
```powershell
Get-DhcpServerv4Failover | Select-Object Name, ScopeId, PartnerServer, Mode, State, LoadBalancePercent
```
Expected: `State: Normal` on both partners. `PartnerDown` means one server declared the other unreachable and is now serving the full range alone (safe short-term, but a real outage on the partner needs fixing before `MaxClientLeadTime` window assumptions break down). `CommunicationInterrupted` means the sync channel is broken but neither side has failed over yet — treat as an active warning, not yet an emergency.

**4. Confirm the DNS dynamic update credential is valid**
```powershell
Get-DhcpServerDnsCredential
# Test the account directly against AD
$cred = Get-DhcpServerDnsCredential
Get-ADUser -Identity $cred.UserName -Properties PasswordExpired, Enabled -ErrorAction SilentlyContinue
```
Expected: `PasswordExpired: False`, `Enabled: True`. This account performs secure dynamic DNS updates on behalf of every DHCP client that registers a record — when its password expires (it has no automatic rotation by default), DNS registration fails silently for every lease going forward while DHCP itself keeps working perfectly, producing a slow-burning "why can't I ping devices by name anymore" ticket days or weeks later.

**5. Confirm database and audit logging health**
```powershell
Get-Service DHCPServer | Select-Object Status
Get-WinEvent -LogName System -FilterXPath "*[System[Provider[@Name='Microsoft-Windows-DHCP-Server'] and (Level=1 or Level=2)]]" -MaxEvents 20 -ErrorAction SilentlyContinue
```
Expected: service running, no recent Critical/Error events. JET database errors (event IDs in the 1000s referencing `jet.log` / `dhcp.mdb`) mean the database needs offline repair — see Fix 5.

---

## Common Fix Paths

<details><summary>Fix 1 — Scope exhaustion</summary>

```powershell
$scopeId = "10.10.20.0"

# Confirm severity
Get-DhcpServerv4ScopeStatistics -ScopeId $scopeId | Select-Object Free, InUse, PercentageInUse

# Reclaim obviously stale leases first (verify each is genuinely stale before removing)
Get-DhcpServerv4Lease -ScopeId $scopeId | Where-Object { $_.AddressState -eq "Active" -and $_.LeaseExpiryTime -lt (Get-Date) }

# If failover is configured, confirm the partner isn't holding an equal share unused —
# LoadBalancePercent may need rebalancing rather than expanding the range
Get-DhcpServerv4Failover -ScopeId $scopeId | Select-Object LoadBalancePercent

# Expand the range if genuinely undersized (confirm no overlap with adjacent scopes/statics first)
Set-DhcpServerv4Scope -ScopeId $scopeId -StartRange 10.10.20.10 -EndRange 10.10.20.250

# Or shorten lease duration for faster natural turnover (temporary measure, watch server load)
Set-DhcpServerv4Scope -ScopeId $scopeId -LeaseDuration 04:00:00
```
**Rollback:** `Set-DhcpServerv4Scope -ScopeId $scopeId -LeaseDuration 8.00:00:00` restores prior duration; range changes should be reverted to the documented original values if the expansion collides with statically assigned addresses elsewhere.
</details>

<details><summary>Fix 2 — Failover partner down or communication interrupted</summary>

```powershell
$relName = (Get-DhcpServerv4Failover).Name

# Confirm current state from both sides if possible
Get-DhcpServerv4Failover -Name $relName | Select-Object State, Mode, PartnerServer

# If genuinely PartnerDown and the outage is confirmed (not just a blip), this server continues
# serving the full range alone automatically — no action required to keep leasing working.
# Once the partner is back online, reconcile scope databases:
Invoke-DhcpServerv4FailoverReplication -ComputerName <this-server> -Name $relName -Force

# If the relationship itself is broken (not just one server down), inspect and repair:
Get-DhcpServerv4Failover -Name $relName -ErrorAction Stop
```
**Rollback:** none needed for the automatic failover behavior itself; if a manual `Invoke-DhcpServerv4FailoverReplication -Force` was run against the wrong direction, re-run it from the authoritative side to resync correctly.
</details>

<details><summary>Fix 3 — Server not authorized in AD</summary>

```powershell
# From an account with Enterprise Admins rights (authorization is a forest-wide AD object)
Add-DhcpServerInDC -DnsName <server-fqdn> -IPAddress <server-ip>

# Confirm
Get-DhcpServerInDC

# Restart the service to pick up authorized state immediately rather than waiting for the
# periodic re-check
Restart-Service DHCPServer
```
**Rollback:** `Remove-DhcpServerInDC -DnsName <server-fqdn> -IPAddress <server-ip>` if authorization was added in error — but note this immediately stops the server from leasing anything.
</details>

<details><summary>Fix 4 — DNS dynamic update credential expired/broken</summary>

```powershell
# Identify the current configured account
Get-DhcpServerDnsCredential

# Reset the account's password in AD (coordinate with whoever owns that service account)
# Then update DHCP to use the new password:
Set-DhcpServerDnsCredential -UserName "<svc-account>" -DomainName "<domain-fqdn>" -Password (Read-Host -AsSecureString "New password")

# Confirm the account still has the required rights on the DNS zone (typically delegated
# via the DnsUpdateProxy group, or explicit ACL on the zone)
```
**Rollback:** revert to the previous account/password if the new credential also fails — but a genuinely expired password has no working rollback target; the fix is to set a new valid password, not restore the old (expired) one.
</details>

<details><summary>Fix 5 — DHCP database (JET) corruption</summary>

```powershell
# Stop the service before touching the database file
Stop-Service DHCPServer

# Run the JET repair utility against the database (default path shown; confirm actual path first)
jetpack.exe "$env:SystemRoot\System32\dhcp\dhcp.mdb" "$env:SystemRoot\System32\dhcp\temp.mdb"

# Restart and verify
Start-Service DHCPServer
Get-DhcpServerv4Scope
```
**Rollback:** back up `dhcp.mdb` and the `dhcp\backup\` folder BEFORE running `jetpack.exe` — if repair makes things worse, restore from the DHCP server's own automatic backup (`Restore-DhcpServer -Path <backup-folder>`) or the most recent scheduled backup instead.
</details>

<details><summary>Fix 6 — Unmanaged split-scope / rogue second server</summary>

```powershell
# Confirm this server's own scope config is clean and non-overlapping
Get-DhcpServerv4Scope | Select-Object ScopeId, StartRange, EndRange

# If a legitimate split-scope was intended, convert it to a proper Failover relationship
# instead of two independently managed static ranges (eliminates manual sync drift):
Add-DhcpServerv4Failover -ComputerName <this-server> -PartnerServer <other-server> -Name "<relationship-name>" -ScopeId <scope-id> -LoadBalancePercent 50
```
**Rollback:** if the second server is genuinely rogue (unauthorized/unmanaged), it cannot be fixed from this server — escalate for physical/logical removal. If it was an intentional legacy split-scope being converted, `Remove-DhcpServerv4Failover` reverts to independent management.
</details>

<details><summary>Fix 7 — Superscope member imbalance</summary>

```powershell
# List member scopes and their individual utilization
Get-DhcpServerv4Superscope | Select-Object SuperscopeName
Get-DhcpServerv4Scope -SuperscopeName "<superscope-name>" | ForEach-Object {
    Get-DhcpServerv4ScopeStatistics -ScopeId $_.ScopeId
} | Select-Object ScopeId, PercentageInUse

# Superscopes don't auto-balance — clients only roam to a sibling scope's pool when the
# ORIGINAL scope for their subnet is exhausted AND a relay/router is presenting both
# ranges on the same segment. Confirm the router/relay config actually spans both ranges.
```
**Rollback:** N/A — this is a design/verification check, not a destructive change.
</details>

---

## Escalation Evidence

```
DHCP Server Escalation
-----------------------
Date/Time of failure:
Affected scope(s) / subnet(s):
DHCP server name(s):
Failover relationship name (if any) and State:
Scope PercentageInUse at time of failure:
Get-DhcpServerInDC output (authorization confirmed?):
DNS dynamic update credential status (PasswordExpired?):
Recent DHCP-Server event log Critical/Error entries:
Scope of impact: single subnet / multiple / all scopes on this server
Recent changes (scope edits, failover config, DNS credential rotation, server rebuild):
Attempted fixes and results:
```

---

## 🎓 Learning Pointers

- **`Get-DhcpServerInDC` returning nothing (or missing this server) means it will silently ignore every DHCPDISCOVER it sees** — no error is logged on the client side, no obvious server-side alarm either. Any newly built or restored DHCP server needs this checked before assuming a scope-level problem. See [MS Docs: authorize a DHCP server](https://learn.microsoft.com/en-us/windows-server/networking/technologies/dhcp/dhcp-top).
- **The DNS dynamic update credential is the single most common slow-burning DHCP failure** — DHCP keeps handing out addresses perfectly while DNS record registration silently fails once the service account's password expires, since there's no automatic rotation and no loud alert. Treat this account like any other service account requiring a password-expiry monitor.
- **Failover `PartnerDown` is not itself an emergency** — the surviving partner automatically serves the full address range alone per the configured `MaxClientLeadTime` safety window. The real risk is leaving it in that state indefinitely without investigating why the partner is actually down.
- **Superscopes group scopes for administrative/reporting purposes and to let a single interface serve multiple logical subnets — they do not automatically load-balance address exhaustion between members** unless the network path (relay/router) genuinely presents both ranges to clients on the same segment.
- **For the deeper dive** — failover mode selection (hot standby vs. load balance), DHCP policies (vendor class/MAC-based option assignment), audit log rotation, and backup/restore internals — see `DHCP-Server-A.md`. For client-side DORA/lease/relay troubleshooting, see `DHCP-Client-A.md` / `DHCP-Client-B.md`.
