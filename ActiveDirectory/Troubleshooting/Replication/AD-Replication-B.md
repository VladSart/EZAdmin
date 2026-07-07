# AD DS Replication Failures — Hotfix Runbook (Mode B: Ops)
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

Run these from an elevated PowerShell session on any Domain Controller (or a management box with RSAT):

```powershell
# 1. Replication summary across all DCs — the single best "is it broken" command
repadmin /replsummary

# 2. Check for replication failures with detail (largest metadata delta first)
repadmin /showrepl * /csv | ConvertFrom-Csv | Sort-Object "Number of Failures" -Descending | Select-Object -First 15

# 3. DC-wide health check (covers DNS, replication, services, SYSVOL, trust)
dcdiag /q

# 4. Check FSMO role holders are online and reachable
netdom query fsmo

# 5. Check AD replication-relevant Windows services
Get-Service -Name NTDS, Netlogon, DNS, W32Time | Select-Object Name, Status, StartType
```

| What you see | What it means |
|---|---|
| `repadmin /replsummary` shows non-zero "Fails" for a DC | That DC has failing inbound or outbound partners — go to Diagnosis |
| `dcdiag /q` returns nothing | All tests passed — problem is likely not core AD health |
| `dcdiag /q` prints failed test names | Note the exact test (Replications, Advertising, KnowsOfRoleHolders, etc.) |
| `netdom query fsmo` hangs or errors on one role | That FSMO holder is down or unreachable — high priority |
| `Get-Service NTDS` not Running | DC is not functioning as a domain controller — escalate immediately |
| Largest metadata delta > 24h | Lingering objects risk on that DC if tombstone lifetime is approaching |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
DNS (correctly pointing DCs at each other, SRV records registered)
  └── Netlogon service running (registers SRV records, locates DCs)
        └── KCC (Knowledge Consistency Checker) builds replication topology
              └── RPC connectivity between DC pairs (dynamic port range + 135)
                    └── Kerberos authentication between DCs (time sync dependency)
                          └── W32Time within 5-minute skew (Kerberos hard limit)
                                └── Replication partners exchange USN vectors
                                      └── Changes applied, up-to-dateness vector updated
                                            └── SYSVOL replicates (DFSR or legacy FRS)
```

Key failure points:
- DNS records stale or missing (DC re-IP'd, DNS not updated)
- Firewall blocking RPC dynamic ports between sites
- Time skew > 5 minutes breaks Kerberos, which breaks RPC auth, which breaks replication
- A DC has been offline past tombstone lifetime (default 180 days) — cannot safely rejoin
- Stale KCC topology after a site link or subnet change

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm which DC(s) are failing**
```powershell
repadmin /replsummary
```
Expected: `Largest Delta` under a few hours, `Fails/Total` = `0/N` for every DC.
Bad: any DC showing consistent failures — note its name and partner.

**Step 2 — Get the exact error code for the failing partnership**
```powershell
repadmin /showrepl <FailingDCName> /verbose /all
```
Look at the `Last Error` line — it gives a Win32 error code (e.g., `8524`, `1722`, `1256`, `8453`).

**Step 3 — Interpret common error codes**

| Error code | Meaning | Likely cause |
|---|---|---|
| `1722` | RPC server unavailable | Network path down, firewall, or DC offline |
| `1256` | Remote system not available | DC powered off / network unreachable |
| `8524` | DSA operation unable to proceed (DNS lookup failed) | DNS record missing/stale for that DC |
| `8453` | Replication access denied | Kerberos/time skew, or broken trust between DCs |
| `8606` | Insufficient attributes to update object | Schema mismatch (rare, usually post-upgrade) |
| `-2146893022` | The target principal name is incorrect | Kerberos SPN issue, often stale computer account |

**Step 4 — Check time sync (breaks everything else if wrong)**
```powershell
w32tm /monitor
w32tm /query /status
```
Expected: `Stratum` reasonable (2-4), offset under a few seconds between DCs.

**Step 5 — Check DNS records for the failing DC**
```powershell
nslookup <FailingDCName>.<domain.com>
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.<domain.com>" -Type SRV
```
Expected: DC resolves to correct IP; SRV records list all healthy DCs.

**Step 6 — Force replication and watch for the specific error**
```powershell
repadmin /replicate <DestDC> <SourceDC> <NamingContextDN> /force
```

**Step 7 — Full health sweep**
```powershell
dcdiag /v /c /d /e /s:<FailingDCName>
```

---
## Common Fix Paths

<details><summary>Fix 1 — RPC unreachable / network path down (Error 1722 / 1256)</summary>

**Cause:** Firewall blocking RPC dynamic ports, VPN/site-link down, or the DC is genuinely offline.

```powershell
# Confirm basic reachability
Test-Connection -ComputerName <FailingDCName> -Count 4
Test-NetConnection -ComputerName <FailingDCName> -Port 135   # RPC endpoint mapper
Test-NetConnection -ComputerName <FailingDCName> -Port 389   # LDAP

# If reachable on 135 but not the dynamic range, check firewall rules
Get-NetFirewallRule -DisplayGroup "Active Directory Domain Services" | Where-Object Enabled -eq True
```

Required ports between all DCs: TCP/UDP 389 (LDAP), TCP 636 (LDAPS), TCP 3268/3269 (GC), TCP/UDP 88 (Kerberos), TCP/UDP 53 (DNS), TCP 135 + dynamic RPC 49152-65535.

**Rollback note:** No destructive action here — this is connectivity troubleshooting only.

</details>

<details><summary>Fix 2 — Time skew breaking Kerberos (Error 8453 or Kerberos failures)</summary>

**Cause:** A DC's clock has drifted more than 5 minutes from the PDC Emulator, which is the domain's authoritative time source.

```powershell
# Identify the PDC Emulator (authoritative time source)
netdom query fsmo

# On a non-PDC DC, force resync against the domain hierarchy
w32tm /resync /rediscover

# Verify
w32tm /query /status
w32tm /query /peers
```

**Rollback note:** Time correction is one-directional and safe. If skew is severe (hours), investigate why — a bad BIOS clock or VM host time source is a common root cause.

</details>

<details><summary>Fix 3 — Stale DNS record for a DC (Error 8524)</summary>

**Cause:** DC's IP changed, or the DNS record de-registered and didn't refresh.

```powershell
# Force DC to re-register its DNS records
ipconfig /registerdns
Restart-Service Netlogon

# Verify SRV records are correct after 2-3 minutes
Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.<domain.com>" -Type SRV
```

**Rollback note:** Safe — re-registering DNS does not remove existing valid records, only refreshes/adds.

</details>

<details><summary>Fix 4 — Forcing replication topology recalculation (KCC)</summary>

**Cause:** Topology is stale after a site/subnet/site-link change and isn't self-healing within the expected interval.

```powershell
# Force the KCC to recalculate the topology on a given DC
repadmin /kcc <DCName>

# Then force replication across all partners
repadmin /syncall /AdeP
```

`/A` = all NCs, `/d` = identify by DN, `/e` = enterprise-wide, `/P` = push mode.

**Rollback note:** Safe, read/recompute operation. Does not modify object data.

</details>

<details><summary>Fix 5 — Lingering object / DC offline past tombstone lifetime</summary>

**Cause:** A DC was offline longer than the tombstone lifetime (default 180 days, check `Get-ADObject` for actual value). Rejoining it as-is risks reintroducing deleted objects (lingering objects).

```powershell
# Check tombstone lifetime
Get-ADObject "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,DC=<domain>,DC=<com>" `
  -Properties tombstoneLifetime | Select-Object tombstoneLifetime

# Check when the DC last replicated successfully
repadmin /showrepl <DCName> | Select-String "Last successful sync"
```

⚠️ **Do not simply re-enable replication on a DC that has exceeded tombstone lifetime.** It must be demoted (forcibly if unreachable via normal `dcpromo`) and rebuilt from scratch. Reintroducing it risks lingering objects across the forest.

**Rollback note:** N/A — this is a decommission decision, not a reversible fix.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Active Directory Replication Failure

Domain: ________________________
Forest functional level: ________
Affected DC(s): _________________
FSMO role holders (netdom query fsmo output): 
  ___________________________________

repadmin /replsummary output:
---
[paste here]
---

Failing partnership error code: ________
Error meaning (from lookup table): ______

Last successful replication (per repadmin /showrepl): ____________
Time skew between affected DCs (w32tm /stripchart or /monitor): ____

DNS SRV record check (dc._msdcs): (OK / Missing / Stale)
Network path test (135, 389, dynamic RPC): (OK / Blocked / Unreachable)

Steps already attempted:
[ ] repadmin /replsummary and /showrepl reviewed
[ ] Error code identified and matched to cause
[ ] Time sync verified/corrected
[ ] DNS records verified/re-registered
[ ] Forced replication attempted (repadmin /syncall)
[ ] dcdiag /v full run attached
[ ] Firewall/network path confirmed open
```

---
## 🎓 Learning Pointers

- **`repadmin /replsummary` should be your first command, every time.** It aggregates every DC's inbound/outbound replication status into one table — you'll spot the sick DC in seconds instead of hunting through Event Viewer. [Repadmin reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/repadmin)
- **Kerberos has a hard 5-minute time-skew tolerance.** This isn't a soft warning — past 5 minutes, authentication fails outright, and since replication itself uses Kerberos/RPC auth between DCs, a clock problem cascades into a replication problem that looks unrelated to time. Always rule out `w32tm /query /status` early.
- **Tombstone lifetime is a one-way door.** A DC offline longer than tombstone lifetime cannot simply "catch back up" — Microsoft's guidance is to forcibly demote and rebuild it, because reintroducing it risks resurrecting deleted objects (lingering objects) forest-wide. [Lingering objects guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/identity/lingering-objects-domain-services)
- **The KCC rebuilds topology automatically, but not instantly.** After a site-link or subnet change, give it 15 minutes before assuming something is broken — or force it manually with `repadmin /kcc`.
- **DCDiag and Repadmin test different things.** DCDiag validates the DC's overall health (DNS, advertising, services, trust). Repadmin validates replication state specifically. Use both — a DC can pass DCDiag and still have a replication partner issue.
- Community resource: r/sysadmin and r/activedirectory threads on error 8453/1722 consistently trace back to firewall or time-sync — check those two first before assuming a deeper AD corruption issue.
