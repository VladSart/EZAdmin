# AD-Integrated DNS — Hotfix Runbook (Mode B: Ops)
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

Run these from an elevated PowerShell session on a Domain Controller running DNS Server:

```powershell
# 1. Is the DNS Server service actually up on this DC?
Get-Service -Name DNS | Select-Object Name, Status, StartType

# 2. Do the critical AD SRV records exist and resolve?
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.<domain.com>" -Type SRV -ErrorAction SilentlyContinue
Resolve-DnsName -Name "_kerberos._tcp.dc._msdcs.<domain.com>" -Type SRV -ErrorAction SilentlyContinue

# 3. Full DNS-specific DCDiag test (registers/validates the SRV records the DC needs)
dcdiag /test:dns /v

# 4. Zone replication scope and record count sanity check
Get-DnsServerZone | Select-Object ZoneName, ZoneType, IsDsIntegrated, ReplicationScope

# 5. Are any conditional forwarders or the root hints broken?
Get-DnsServerForwarder
Get-DnsServerRootHint
```

| What you see | What it means |
|---|---|
| `DNS` service not Running | This DC cannot answer any queries — high priority, check dependent DCs immediately |
| `Resolve-DnsName` for `_ldap._tcp.dc._msdcs` returns nothing | DC Locator is broken — clients/DCs cannot find domain controllers, cascades into auth and replication failures |
| `dcdiag /test:dns /v` reports delegation or dynamic-update errors | Zone config issue — go to Diagnosis |
| A DC-integrated zone shows `IsDsIntegrated: False` unexpectedly | That zone isn't replicating via AD — it's either a legacy standard-primary zone or was reconfigured; treat as high priority |
| `Get-DnsServerForwarder` empty and root hints also unreachable | Internal names resolve, but internet-bound name resolution is broken (Autodiscover, external mail, licensing checks) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
DNS Server service running on enough DCs to cover client/DC lookup load
  └── AD-integrated zone(s) present with correct Replication Scope
        (Forest DNS Zone / Domain DNS Zone / Legacy _msdcs.<domain>)
        └── Netlogon service registers this DC's SRV + host (A/AAAA) records at startup
              └── Scavenging/aging settings don't prematurely delete live records
                    └── Zone transfer / AD replication carries records to every other DNS-hosting DC
                          └── Clients/DCs query via DC Locator (_ldap, _kerberos, _gc SRV records)
                                └── Kerberos + LDAP + replication all depend on correct answers
```

Key failure points:
- Netlogon failed to register records at boot (stopped mid-registration, or zone doesn't allow dynamic updates from that DC)
- Scavenging enabled with an aggressive no-refresh/refresh interval, deleting records that are still in use
- A DC was demoted improperly and left stale glue/NS records behind
- Conditional forwarder or root hints misconfigured after a firewall or ISP change — breaks external resolution only, internal AD keeps working (easy to misdiagnose as "everything is down")
- Split-brain DNS: a non-AD DNS server (e.g., firewall appliance, Pi-hole, ISP router) is answering internal queries instead of the DC

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the DNS Server role is healthy on every DC that hosts it**
```powershell
Get-DnsServerZone | Where-Object { $_.ZoneName -like "*msdcs*" -or $_.ZoneName -eq (Get-ADDomain).DNSRoot }
```
Expected: the domain zone and `_msdcs.<forest root>` zone both present and `IsDsIntegrated: True`.

**Step 2 — Confirm SRV records exist for every DC, not just one**
```powershell
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.<domain.com>" -Type SRV | Select-Object NameTarget
```
Expected: one entry per DC. A missing DC name means that DC never registered (Netlogon issue) or scavenging removed it.

**Step 3 — Force the affected DC to re-register**
```powershell
ipconfig /registerdns
Restart-Service Netlogon
```
Wait 2-3 minutes, then re-run Step 2.

**Step 4 — Check scavenging configuration if records keep disappearing**
```powershell
Get-DnsServerScavenging
Get-DnsServerZoneAging -Name "<domain.com>"
```
Expected: if scavenging is enabled, `NoRefreshInterval` + `RefreshInterval` should total at least 2x the longest client/DC uptime cycle (default 7+7 days is usually safe). Aggressive settings (e.g., 1 day) will delete records for machines that are simply off overnight.

**Step 5 — Check for split-brain / rogue DNS answering internal queries**
```powershell
nslookup <domain.com> <SuspectExternalOrOtherDNS-IP>
nslookup <domain.com> <KnownGoodDC-IP>
```
Compare results — if a client is pointed at anything other than an internal DC for internal name resolution, that's the root cause.

**Step 6 — Validate external resolution path (forwarders/root hints) separately from internal AD resolution**
```powershell
Resolve-DnsName -Name "www.microsoft.com" -Server <DC-IP>
Get-DnsServerForwarder
```
If internal AD names resolve fine but this fails, the problem is forwarders/root hints/egress firewall — not AD DNS itself.

**Step 7 — Full DNS-specific DCDiag pass**
```powershell
dcdiag /test:dns /v /e
```

---
## Common Fix Paths

<details><summary>Fix 1 — Missing/incomplete SRV records for a DC (DC Locator broken)</summary>

**Cause:** Netlogon didn't register records at startup, or dynamic updates are disabled on the zone.

```powershell
# Confirm dynamic updates are allowed (Secure only, for AD-integrated zones)
Get-DnsServerZone -Name "<domain.com>" | Select-Object DynamicUpdate

# Force re-registration on the affected DC
ipconfig /registerdns
Restart-Service Netlogon -Force

# Verify
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.<domain.com>" -Type SRV
```

**Rollback note:** Safe — re-registering DNS only adds/refreshes records, doesn't remove valid ones.

</details>

<details><summary>Fix 2 — Scavenging deleted records that are still live</summary>

**Cause:** No-refresh/refresh interval too short, or scavenging was enabled without accounting for devices that are frequently offline.

```powershell
# Check current scavenging config on the server
Get-DnsServerScavenging

# Widen the intervals (example: 7 days each, matches Microsoft's default guidance)
Set-DnsServerScavenging -ScavengingState $true -RefreshInterval 7.00:00:00 -NoRefreshInterval 7.00:00:00 -ScavengingInterval 7.00:00:00

# Manually re-register the affected records immediately rather than waiting for the client
ipconfig /registerdns
```

**Rollback note:** Disabling scavenging entirely (`Set-DnsServerScavenging -ScavengingState $false`) is safe short-term but allows stale records to accumulate — re-enable with wider intervals once cleaned up, don't leave it off permanently.

</details>

<details><summary>Fix 3 — Conditional forwarder / root hints broken (external resolution only)</summary>

**Cause:** ISP change, firewall rule change, or a forwarder IP that no longer answers.

```powershell
# Check current forwarders
Get-DnsServerForwarder

# Replace with known-good public resolvers (adjust to org policy — this is illustrative)
Set-DnsServerForwarder -IPAddress "1.1.1.1","8.8.8.8" -PassThru

# Verify
Resolve-DnsName -Name "www.microsoft.com" -Server <DC-IP>
```

**Rollback note:** Safe — forwarder changes only affect where non-authoritative queries are sent, not internal AD zone data.

</details>

<details><summary>Fix 4 — Split-brain DNS (client pointed at a non-AD DNS server)</summary>

**Cause:** DHCP scope, static config, or a VPN/firewall device is handing out a non-DC DNS server for internal name resolution.

```powershell
# Confirm what DNS servers a client is actually using
Get-DnsClientServerAddress -AddressFamily IPv4

# Correct via DHCP scope option, or directly on the NIC
Set-DnsClientServerAddress -InterfaceAlias "<AdapterName>" -ServerAddresses ("<DC1-IP>","<DC2-IP>")
```

**Rollback note:** Safe — this only changes which DNS server the client queries, no data is modified.

</details>

<details><summary>Fix 5 — Zone replication scope mismatch (records exist on one DC, not others)</summary>

**Cause:** Zone was created with the wrong replication scope (Legacy/Domain-only) so not all DNS-hosting DCs receive it.

```powershell
# Check current scope
Get-DnsServerZone -Name "<domain.com>" | Select-Object ZoneName, ReplicationScope

# Change to Forest-wide scope (recommended default for _msdcs zone especially)
Set-DnsServerPrimaryZone -Name "<domain.com>" -ReplicationScope "Forest"
```

⚠️ Changing replication scope re-partitions the zone data in the directory — schedule during a maintenance window and confirm via `dcdiag /test:dns` afterward that every DC still answers correctly.

**Rollback note:** Reversible by setting `-ReplicationScope` back, but triggers another replication cycle — avoid doing this repeatedly in a short window.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — AD-Integrated DNS Issue

Domain: ________________________
Affected DC(s) hosting DNS: _____
Zone(s) involved: _______________
Replication scope (Get-DnsServerZone): ___________

Symptom: (SRV records missing / stale records / external resolution failing / split-brain suspected)

Resolve-DnsName SRV output for _ldap._tcp.dc._msdcs:
---
[paste here]
---

dcdiag /test:dns /v output:
---
[paste here]
---

Scavenging config (Get-DnsServerScavenging):
---
[paste here]
---

Forwarders/root hints (Get-DnsServerForwarder):
---
[paste here]
---

Steps already attempted:
[ ] ipconfig /registerdns + Netlogon restart on affected DC
[ ] Scavenging interval reviewed/widened
[ ] Forwarders/root hints verified
[ ] Client DNS server assignment confirmed (no split-brain)
[ ] Zone replication scope confirmed correct
[ ] dcdiag /test:dns /v attached
```

---
## 🎓 Learning Pointers

- **DC Locator depends entirely on SRV records, not host records.** A DC can have a perfectly valid A record and still be invisible to clients/other DCs if its `_ldap`/`_kerberos`/`_gc` SRV records under `_msdcs.<forest-root>` never registered. Always check SRV records specifically, not just `nslookup <DCName>`. [DNS support for AD DS](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/verify-srv-dns-records-have-been-created)
- **Scavenging is the single most common cause of "records keep disappearing."** Default intervals (7 days no-refresh + 7 days refresh) are conservative on purpose — shortening them without accounting for devices that go offline over a weekend or vacation reliably deletes still-in-use records. [DNS scavenging guidance](https://learn.microsoft.com/en-us/windows-server/networking/dns/deploy/dns-scavenging-overview)
- **External name resolution failures are a red herring for "AD is down."** Forwarder/root-hint breakage only affects internet-bound lookups (Autodiscover, licensing endpoints, external mail) — internal AD replication and auth keep working fine. Test both paths separately before escalating as a directory-wide outage.
- **Split-brain DNS is easy to miss because internal AD names still resolve — just inconsistently.** If a firewall appliance, ISP router, or misconfigured DHCP scope is handing out a non-DC DNS server, some clients see a healthy domain and others see intermittent failures. Always confirm `Get-DnsClientServerAddress` matches the org's DCs.
- **Replication scope isn't "set and forget."** A zone created years ago as Domain-scope in a since-expanded multi-domain forest may not be reaching every DC that needs it. Confirm scope matches current topology, especially the `_msdcs` zone, which should almost always be Forest-scoped.
- Community resource: r/sysadmin and r/activedirectory threads on "DNS works sometimes" nearly always trace back to either scavenging or a rogue DHCP-assigned DNS server — check those two before assuming zone corruption.
