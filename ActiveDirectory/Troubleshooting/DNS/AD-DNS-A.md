# AD-Integrated DNS — Reference Runbook (Mode A: Deep Dive)
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
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

**In scope:**
- Active Directory-integrated DNS zones hosted on Domain Controllers (Windows Server 2016–2022)
- SRV record registration and DC Locator mechanics
- Zone replication scope (Legacy/Domain/Forest), scavenging/aging, conditional forwarders, root hints
- Split-brain DNS detection between internal AD zones and external/rogue resolvers

**Out of scope:**
- Client-side DNS resolver cache/config troubleshooting — see `Windows/Troubleshooting/DNS-Client-A.md`
- AD DS replication of the directory itself (this runbook covers DNS *as a service running on DCs*, not NTDS.dit replication) — see `ActiveDirectory/Troubleshooting/Replication/AD-Replication-A.md`
- Azure/Entra-hosted DNS (Azure DNS Private Zones, Entra Domain Services DNS) — see `EntraID/Troubleshooting/EntraDomainServices-A.md`
- Third-party/non-Microsoft DNS servers (BIND, Infoblox) beyond basic conditional-forwarder interop

**Assumptions:**
- DNS Server role is installed on one or more Domain Controllers (the standard, recommended topology)
- You have Domain Admin or delegated DNS management rights
- The `DnsServer` PowerShell module is available (installed with the DNS Server role, or via RSAT)

---
## How It Works

<details><summary>Full architecture — AD-integrated DNS internals</summary>

### Why DNS Is Integrated Into AD At All

Active Directory Domain Services is fundamentally a **name-based system** — every operation (logon, LDAP bind, replication partner discovery, Kerberos ticket requests) starts with a DNS lookup to find a Domain Controller. Microsoft's solution was to store the DNS zone data itself as objects inside the AD database, so zone data replicates using the same multi-master replication engine as everything else in the directory — no separate zone-transfer mechanism needed between DCs (though standard zone transfer to non-AD-integrated secondaries is still supported).

### The `_msdcs` Zone — The Most Important Zone You'll Rarely Think About

Every AD forest has a special zone: `_msdcs.<forest-root-domain>`. This zone exists specifically to hold:
- **SRV records** for every DC in the forest, organized by service (`_ldap`, `_kerberos`, `_gc`, `_kpasswd`), by site, and by GUID
- **CNAME records** keyed by each DC's objectGUID, allowing a DC to be found even if its hostname changes (used heavily during replication and by `repadmin`)

This zone is what powers **DC Locator** — the process (`Netlogon` service, via `DsGetDcName`) that any domain member uses to find "a domain controller" or "a domain controller for site X" or "a global catalog." If `_msdcs` records are missing or stale, clients and DCs alike silently fall back to slower discovery methods or fail outright, and the failure often looks like an authentication or replication problem rather than a DNS problem.

### Record Registration Lifecycle

1. On startup (or every 24 hours by default, or on IP change), the **Netlogon service** on a DC registers:
   - Host (A/AAAA) records for the DC itself
   - Dozens of SRV records under `_msdcs.<forest-root>` and under the domain zone, scoped by site
2. This registration is a **dynamic DNS update** — the zone must have Dynamic Update set to `Secure only` (the default and recommended setting for AD-integrated zones) so only authenticated domain members can write records.
3. Registration is logged to `%windir%\System32\Config\netlogon.dns` on the DC — a text file listing every record that DC expects to have registered. Comparing this file's contents against what actually resolves is one of the fastest ways to spot a registration gap.

### Replication Scope — Where Zone Data Actually Lives

AD-integrated zones can be stored in different **application partitions**, controlling which DCs get a copy:

| Replication Scope | Stored In | Replicates To |
|---|---|---|
| **Forest DNS Zone** (recommended for `_msdcs`) | `ForestDnsZones` partition | Every DNS server in every domain of the forest |
| **Domain DNS Zone** (default for the domain zone) | `DomainDnsZones` partition | Every DNS server in that domain only |
| **Legacy (All DCs in domain, pre-Windows 2003 style)** | Domain naming context | Every DC in the domain (not just DNS servers) — larger replication footprint, rarely needed today |
| **Standard primary/secondary (non-AD-integrated)** | Zone file on disk | Explicit zone transfer only, no AD replication |

Choosing the wrong scope is a common, hard-to-spot misconfiguration: e.g., a `_msdcs` zone stuck at Domain scope in a multi-domain forest means DCs in other domains never see those SRV records, breaking cross-domain DC Locator lookups.

### Scavenging — Time-Based Record Cleanup

Because dynamic updates mean records can be created automatically by any authenticated device (not just DCs — regular workstations register their own A records too), stale records accumulate as machines are retired, re-IP'd, or renamed. **Scavenging** removes records that haven't been refreshed within a configurable window:

- **No-Refresh Interval:** After a record is created/updated, it cannot be refreshed again for this long (prevents excessive replication chatter from re-registration).
- **Refresh Interval:** After the no-refresh window ends, the record has this long to be refreshed before it's eligible for deletion.
- A record becomes eligible for scavenging only after **both** intervals have elapsed since its last refresh — default 7 days each, for a minimum 14-day grace period.

Scavenging must also be enabled **both** at the DNS server level and at the zone level — enabling it in only one place does nothing.

### Forwarders and Root Hints — The External Resolution Path

Queries for names AD doesn't own (e.g., `outlook.office365.com`) are **not** looked up via AD replication — the DNS server either forwards them to a **conditional/general forwarder** (a specific upstream DNS server) or falls back to **root hints** (the internet's root DNS servers) if no forwarder is configured or reachable. This path is entirely independent of AD zone health, which is why "internal AD works, but Outlook/Teams/websites are broken" almost always points here, not at the directory itself.

</details>

---
## Dependency Stack

```
Domain Controller with DNS Server role installed and service running
  └── AD-integrated zone(s) exist: domain zone + _msdcs.<forest-root> zone
        └── Correct Replication Scope (Forest for _msdcs, Domain or Forest for domain zone)
              └── Dynamic Update set to "Secure only" (allows Netlogon/member registration)
                    └── Netlogon service registers SRV + host records on startup/IP change/24h cycle
                          └── Scavenging (if enabled) tuned wide enough not to remove live records
                                └── AD replication (NTDS partitions) carries zone data to every DNS-hosting DC
                                      └── Clients/DCs query DC Locator (_ldap/_kerberos/_gc SRV under _msdcs)
                                            └── Kerberos auth, LDAP bind, and inter-DC replication all succeed
                                                  └── (separate path) Forwarders/root hints resolve external names
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Authentication intermittently fails, replication errors mention DNS lookup failure (repadmin error 8524) | Missing/stale SRV record for a specific DC | `Resolve-DnsName _ldap._tcp.dc._msdcs.<domain>`, compare against `netlogon.dns` on that DC |
| A DC's records worked, then vanished weeks later with no config change | Scavenging removed them — interval too aggressive for that machine's uptime pattern | `Get-DnsServerScavenging`, `Get-DnsServerZoneAging` |
| Internal AD auth/replication fine, but Outlook/Teams/web browsing broken tenant-wide | Forwarder or root-hint path broken (external resolution only) | `Get-DnsServerForwarder`, `Resolve-DnsName www.microsoft.com -Server <DC>` |
| Some users see normal behavior, others get random resolution failures, no pattern by location | Split-brain DNS — a subset of clients pointed at a non-DC resolver (DHCP scope, VPN, rogue device) | `Get-DnsClientServerAddress` on affected clients |
| Cross-domain DC Locator fails only for DCs in a specific domain of a multi-domain forest | `_msdcs` zone replication scope isn't Forest-wide | `Get-DnsServerZone -Name "_msdcs.<forest-root>"` → check `ReplicationScope` |
| Record exists on one DC's DNS console but not another's | Zone replication scope too narrow, or that DC isn't a DNS server at all and is relying on stale replication | Confirm which DCs host the DNS role; check scope |
| Dynamic update failures logged in DNS Server event log | Dynamic Update set to `None`, or `Secure only` with a permissions/Kerberos issue for the registering computer | `Get-DnsServerZone` → `DynamicUpdate` property; check computer account health |
| `dcdiag /test:dns` flags delegation errors | A parent/child zone delegation (NS/glue records) is missing or points to a decommissioned server | Review NS records for the zone and its parent |
| DNS Server service crashes or won't start | Corrupt zone data, insufficient disk space for zone/log files, or a conflicting third-party DNS service on the same port | Event Viewer → DNS Server log; `Get-Service DNS` |

---
## Validation Steps

**Step 1 — Confirm zone inventory and replication scope**
```powershell
Get-DnsServerZone | Select-Object ZoneName, ZoneType, IsDsIntegrated, ReplicationScope
```
Expected: domain zone and `_msdcs.<forest-root>` zone both present, `IsDsIntegrated: True`, `_msdcs` scoped `Forest`.

**Step 2 — Cross-check SRV records against `netlogon.dns` on each DC**
```powershell
Get-Content "$env:windir\System32\Config\netlogon.dns" | Select-String "_ldap|_kerberos" | Select-Object -First 10
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.<domain.com>" -Type SRV
```
Expected: every record listed in `netlogon.dns` actually resolves. A gap here is either a registration failure or scavenging deletion.

**Step 3 — Confirm dynamic update mode**
```powershell
Get-DnsServerZone -Name "<domain.com>" | Select-Object DynamicUpdate
```
Expected: `Secure` (labeled `Secure only` in the GUI). `None` breaks all self-registration; `NonsecureAndSecure` is a security risk (allows unauthenticated writes).

**Step 4 — Confirm scavenging is coherent (server AND zone level)**
```powershell
Get-DnsServerScavenging
Get-DnsServerZoneAging -Name "<domain.com>"
```
Expected: if either is disabled, scavenging does nothing — that's fine if intentional, but confirm it matches design intent rather than being accidentally half-configured.

**Step 5 — Validate the external resolution path independently**
```powershell
Get-DnsServerForwarder
Get-DnsServerRootHint
Resolve-DnsName -Name "www.microsoft.com" -Server <DC-IP>
```
Expected: a forwarder responds, or root hints resolve if no forwarder configured.

**Step 6 — Confirm no split-brain by comparing client resolver config against known DCs**
```powershell
Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" }
```
Expected: every server-address entry is a known internal DC/DNS server.

**Step 7 — Full DNS-specific DCDiag validation**
```powershell
dcdiag /test:dns /v /e
```
Expected: all sub-tests (Basic, Forwarders, Delegations, Dynamic Update, Records Registration) pass across every DC.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Service & Zone Layer
1. Confirm the DNS Server service is running on enough DCs to handle load and provide redundancy
2. Confirm both the domain zone and `_msdcs` zone exist and are AD-integrated
3. Confirm replication scope matches topology (Forest-wide for `_msdcs` in any multi-domain forest)

### Phase 2 — Registration Layer
1. Confirm Dynamic Update is `Secure only`
2. Compare `netlogon.dns` against live resolution for each DC
3. Force re-registration (`ipconfig /registerdns` + Netlogon restart) on any DC missing records

### Phase 3 — Retention Layer (Scavenging)
1. Confirm scavenging state at both server and zone level
2. Confirm intervals are wide enough for the environment's actual device uptime patterns
3. If records were wrongly scavenged, force immediate re-registration rather than waiting for the next natural refresh cycle

### Phase 4 — External Resolution Layer
1. Test forwarders and root hints independently of internal zone health
2. Confirm firewall egress on UDP/TCP 53 from the DC to the configured forwarder
3. Confirm no ISP/upstream change silently broke a previously-working forwarder IP

### Phase 5 — Client/Split-Brain Layer
1. Confirm affected clients' assigned DNS servers are all legitimate internal DCs
2. Check DHCP scope options for a rogue DNS server entry
3. Check for VPN/firewall appliances configured to hand out their own DNS to connected clients

### Phase 6 — Recovery Verification
1. Re-run `dcdiag /test:dns /v /e` — confirm all tests pass
2. Re-resolve the previously-missing SRV records
3. Confirm downstream symptoms (auth, replication) have cleared — cross-reference `ActiveDirectory/Troubleshooting/Replication/AD-Replication-A.md` if replication errors persist

---
## Remediation Playbooks

<details><summary>Playbook 1 — Rebuild a corrupted or missing `_msdcs` zone</summary>

**Scenario:** The `_msdcs.<forest-root>` zone was accidentally deleted, corrupted, or never properly scoped Forest-wide.

**Step 1 — Confirm the zone is genuinely missing/broken (not just a display glitch)**
```powershell
Get-DnsServerZone | Where-Object ZoneName -like "_msdcs*"
```

**Step 2 — Recreate the zone with correct Forest-wide scope**
```powershell
Add-DnsServerPrimaryZone -Name "_msdcs.<forest-root-domain>" -ReplicationScope "Forest" -DynamicUpdate "Secure"
```

**Step 3 — Force every DC to re-register into the new zone**
```powershell
$dcs = (Get-ADDomainController -Filter *).HostName
foreach ($dc in $dcs) {
    Invoke-Command -ComputerName $dc -ScriptBlock {
        ipconfig /registerdns
        Restart-Service Netlogon -Force
    }
}
```

**Step 4 — Verify across the forest**
```powershell
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.<forest-root-domain>" -Type SRV
```

**Rollback note:** Recreating a deleted zone is additive — no data loss risk beyond the time records take to re-register (typically minutes). If the zone existed but with wrong scope, changing scope re-partitions data; do this in a maintenance window.

</details>

<details><summary>Playbook 2 — Recover from over-aggressive scavenging that deleted live records</summary>

**Scenario:** Scavenging intervals were set too short (e.g., 1 day) and records for legitimately-online-but-intermittent devices were deleted, breaking DC Locator or general name resolution for those hosts.

**Step 1 — Widen the intervals immediately to stop further loss**
```powershell
Set-DnsServerScavenging -ScavengingState $true -RefreshInterval 7.00:00:00 -NoRefreshInterval 7.00:00:00 -ScavengingInterval 7.00:00:00
Set-DnsServerZoneAging -Name "<domain.com>" -Aging $true -RefreshInterval 7.00:00:00 -NoRefreshInterval 7.00:00:00
```

**Step 2 — Force immediate re-registration of affected records rather than waiting**
```powershell
# On each affected DC/server:
ipconfig /registerdns
```

**Step 3 — Confirm records reappear**
```powershell
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.<domain.com>" -Type SRV
```

**Rollback note:** Widening intervals is safe and non-destructive. If scavenging caused significant damage, consider disabling it entirely (`Set-DnsServerScavenging -ScavengingState $false`) until a controlled re-enable with validated intervals.

</details>

<details><summary>Playbook 3 — Resolve cross-domain DC Locator failure due to replication scope</summary>

**Scenario:** In a multi-domain forest, DCs in Domain B cannot locate DCs in Domain A (or vice versa) because the `_msdcs` zone is Domain-scoped instead of Forest-scoped.

**Step 1 — Confirm current scope**
```powershell
Get-DnsServerZone -Name "_msdcs.<forest-root-domain>" | Select-Object ZoneName, ReplicationScope
```

**Step 2 — Change scope to Forest** (schedule in a maintenance window — this re-partitions zone data)
```powershell
Set-DnsServerPrimaryZone -Name "_msdcs.<forest-root-domain>" -ReplicationScope "Forest"
```

**Step 3 — Allow replication to propagate, then validate from a DC in each domain**
```powershell
# Run from a DC in each domain of the forest
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.<forest-root-domain>" -Type SRV
```

**Rollback note:** Reversible by setting scope back, but each change triggers a new replication cycle across every DNS-hosting DC in the new scope — avoid repeated toggling.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  AD-Integrated DNS Evidence Collector
.NOTES     Run from a Domain Controller hosting the DNS Server role, with Domain Admin rights
#>

$reportPath = "C:\Temp\ADDnsEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== Zone Inventory ===" | Out-File "$reportPath\01_Zones.txt"
Get-DnsServerZone | Format-Table ZoneName, ZoneType, IsDsIntegrated, ReplicationScope -AutoSize |
    Out-File "$reportPath\01_Zones.txt" -Append

"=== Dynamic Update Config ===" | Out-File "$reportPath\02_DynamicUpdate.txt"
Get-DnsServerZone | Select-Object ZoneName, DynamicUpdate | Format-Table -AutoSize |
    Out-File "$reportPath\02_DynamicUpdate.txt" -Append

"=== Scavenging Config ===" | Out-File "$reportPath\03_Scavenging.txt"
Get-DnsServerScavenging | Out-File "$reportPath\03_Scavenging.txt" -Append

"=== Forwarders & Root Hints ===" | Out-File "$reportPath\04_Forwarders.txt"
Get-DnsServerForwarder | Out-File "$reportPath\04_Forwarders.txt" -Append
Get-DnsServerRootHint | Out-File "$reportPath\04_Forwarders.txt" -Append

"=== SRV Record Check (_msdcs) ===" | Out-File "$reportPath\05_SrvRecords.txt"
try {
    $domain = (Get-ADDomain).DNSRoot
    Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$domain" -Type SRV -ErrorAction SilentlyContinue |
        Out-File "$reportPath\05_SrvRecords.txt" -Append
    Resolve-DnsName -Name "_kerberos._tcp.dc._msdcs.$domain" -Type SRV -ErrorAction SilentlyContinue |
        Out-File "$reportPath\05_SrvRecords.txt" -Append
} catch {
    "Could not resolve SRV records: $_" | Out-File "$reportPath\05_SrvRecords.txt" -Append
}

"=== netlogon.dns (this DC's expected registrations) ===" | Out-File "$reportPath\06_NetlogonDns.txt"
Get-Content "$env:windir\System32\Config\netlogon.dns" -ErrorAction SilentlyContinue |
    Out-File "$reportPath\06_NetlogonDns.txt" -Append

"=== DCDiag DNS Test ===" | Out-File "$reportPath\07_DcDiagDns.txt"
dcdiag /test:dns /v /e | Out-File "$reportPath\07_DcDiagDns.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| List zones and replication scope | `Get-DnsServerZone \| Select ZoneName, IsDsIntegrated, ReplicationScope` |
| Change replication scope | `Set-DnsServerPrimaryZone -Name <zone> -ReplicationScope Forest` |
| Check dynamic update mode | `Get-DnsServerZone -Name <zone> \| Select DynamicUpdate` |
| Resolve DC Locator SRV records | `Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.<domain>" -Type SRV` |
| Force DC to re-register | `ipconfig /registerdns` + `Restart-Service Netlogon` |
| Check server-level scavenging | `Get-DnsServerScavenging` |
| Check zone-level aging | `Get-DnsServerZoneAging -Name <zone>` |
| Set scavenging intervals | `Set-DnsServerScavenging -ScavengingState $true -RefreshInterval <ts> -NoRefreshInterval <ts>` |
| Check forwarders | `Get-DnsServerForwarder` |
| Check root hints | `Get-DnsServerRootHint` |
| DNS-specific DC health test | `dcdiag /test:dns /v /e` |
| Compare expected vs. actual DC registrations | `Get-Content $env:windir\System32\Config\netlogon.dns` |
| Check client's assigned DNS servers | `Get-DnsClientServerAddress` |
| Rebuild `_msdcs` zone | `Add-DnsServerPrimaryZone -Name "_msdcs.<forest-root>" -ReplicationScope Forest -DynamicUpdate Secure` |

---
## 🎓 Learning Pointers

- **`_msdcs.<forest-root>` is arguably the single most business-critical DNS zone in any AD environment, precisely because it's invisible when healthy.** It exists purely to make DC Locator work. When it's broken, the symptoms show up everywhere except in a way that obviously points at DNS — authentication delays, replication error 8524, slow logons. [DNS support for AD DS](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/verify-srv-dns-records-have-been-created)
- **`netlogon.dns` is an underused diagnostic goldmine.** It's a plain-text list of exactly what records a given DC expects to have registered — diffing it against live `Resolve-DnsName` output is often faster than parsing dcdiag output to spot a registration gap.
- **Scavenging and replication scope are the two config choices that cause the most "it worked for years, then randomly broke" tickets.** Neither has an obvious day-to-day symptom until a threshold is crossed (an interval elapses, a new domain is added to the forest) — worth auditing proactively, not just reactively. [DNS scavenging overview](https://learn.microsoft.com/en-us/windows-server/networking/dns/deploy/dns-scavenging-overview)
- **External and internal name resolution are architecturally separate paths that share the same server.** A DC's DNS Server role answers both AD-zone queries (from its own integrated zone data) and external queries (via forwarders/root hints) — a break in one almost never implies a break in the other, so always test both independently before scoping the incident.
- **Split-brain DNS is a networking problem wearing a DNS costume.** The DNS server itself may be perfectly healthy; the actual fault is a client, DHCP scope, or network appliance pointing devices at the wrong resolver. `Get-DnsClientServerAddress` on the affected endpoint answers this faster than anything on the DNS server itself.
- **Replication scope changes are structural, not cosmetic.** Moving a zone between Domain/Forest/Legacy scope actually moves the underlying AD partition the data lives in — treat it like any other directory-partitioning change: plan it, don't do it reactively mid-incident unless the current scope is actively causing the outage.
