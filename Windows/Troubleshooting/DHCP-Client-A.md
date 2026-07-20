# DHCP Client — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why DHCP fails end-to-end, not just what command to run.

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

**In scope:**
- Windows DHCP client behavior (Windows 10/11, Server 2016+) on wired and wireless adapters
- Windows Server DHCP role as the authoritative server, covered here only at the basic scope-design/options/relay level needed to diagnose a client-side symptom — for Failover, DHCP Policies, the DNS dynamic update credential, and database internals, see `DHCP-Server-A.md`
- Multi-VLAN environments requiring DHCP relay
- Lease lifecycle: DORA handshake, renewal (T1/T2), release, conflict detection

**Out of scope:**
- Non-Windows DHCP servers (ISC DHCP, pfSense, router-based DHCP) — client-side troubleshooting applies the same way, but server administration commands differ
- DHCPv6 / IPv6 stateless autoconfiguration (SLAAC) — different protocol, not covered here
- Cloud-native DHCP (Azure VNet, AWS VPC) — abstracted away from the OS in ways that make this runbook not directly applicable

**Assumptions:**
- Windows Server DHCP role or equivalent enterprise DHCP server is authoritative for the environment
- Devices are on a switched/routed network with defined VLANs
- IP helper / DHCP relay is configured on L3 devices for any VLAN without a local DHCP server

---

## How It Works

<details><summary>Full architecture</summary>

### The DORA Handshake

DHCP is a four-message exchange, all via broadcast/unicast UDP on ports 67 (server) and 68 (client):

```
Client                                          DHCP Server
  │                                                   │
  │──── DHCPDISCOVER (broadcast, src 0.0.0.0) ───────▶│
  │                                                   │  (checks scope, finds available lease)
  │◀─── DHCPOFFER (candidate IP + options) ──────────│
  │                                                   │
  │──── DHCPREQUEST (broadcast, "I accept this IP") ─▶│  (broadcast so OTHER DHCP servers
  │                                                   │   see the client rejected their offer)
  │                                                   │
  │◀─── DHCPACK (lease confirmed, options finalized) │
  │                                                   │
  Client configures IP, gateway, DNS, other options
```

If two DHCP servers respond to a single DISCOVER, the client picks one offer (typically first received or best match) and broadcasts DHCPREQUEST — every DHCP server on the segment sees this and the non-selected server(s) release their reservation.

### Lease Lifecycle

```
T0 = lease granted
        │
T1 (50% of lease duration) ──▶ Client attempts UNICAST renewal to the ORIGINAL server
        │                       If successful: lease extended, T1/T2 reset from T0(new)
        │                       If server unreachable: client waits, retries
        ▼
T2 (87.5% of lease duration) ──▶ Client broadcasts RENEWAL request to ANY DHCP server
        │                        (rebinding — original server may be down/unreachable)
        ▼
100% (lease expiry) ──▶ If no renewal succeeded, client drops the IP
        │                and falls back to APIPA (169.254.0.0/16) after ~1 min of trying,
        ▼                unless an "Alternate Configuration" static IP is set
    APIPA / no connectivity
```

### Relay / IP Helper (Cross-VLAN DHCP)

DHCPDISCOVER is a **Layer 2 broadcast** — it does not cross VLAN/subnet boundaries on its own. In any environment where DHCP server and clients live on different VLANs, a **relay agent** (IP Helper on Cisco, DHCP Relay on other vendors, or the Windows DHCP Relay Agent role) is required:

```
Client VLAN 10 (no local DHCP server)
        │  DHCPDISCOVER (broadcast, stays in VLAN 10)
        ▼
L3 Switch/Router (default gateway for VLAN 10)
        │  IP Helper configured: forward DHCP to 10.0.0.5 (DHCP server, unicast)
        ▼
DHCP Server (VLAN 99, e.g. 10.0.0.5)
        │  Sees "giaddr" (gateway IP address) field = relay's IP
        │  Uses giaddr to select the correct scope (VLAN 10's scope)
        ▼
DHCPOFFER sent back to relay → forwarded to client
```

**Critical detail:** the DHCP server selects which **scope** to offer from based on the `giaddr` field the relay stamps into the packet. If the relay is misconfigured (wrong IP helper address) or the corresponding scope doesn't exist/is exhausted on the server, clients on that VLAN get nothing — indistinguishable from "DHCP server is down" from the client's perspective.

### DHCP Options Relevant to Windows Clients

| Option | Name | Effect |
|--------|------|--------|
| 003 | Router | Default gateway |
| 006 | DNS Servers | DNS server list |
| 015 | DNS Domain Name | Primary DNS suffix |
| 044 | WINS/NBNS Servers | Legacy NetBIOS name resolution |
| 046 | WINS/NBT Node Type | NetBIOS resolution mode |
| 051 | Lease Time | Overrides scope default lease duration for this client |
| 119 | Domain Search List | DNS suffix search list (multiple domains) |
| 121 | Classless Static Routes | Additional routes pushed via DHCP |
| 252 | WPAD (proxy autoconfig URL) | Proxy discovery |

### Conflict Detection

Before finalizing a lease, the Windows DHCP **server** typically performs a ping test against the candidate IP (configurable, "Conflict detection attempts" on the scope) to avoid handing out an address already in use by a statically configured device. The **client** also performs gratuitous ARP after accepting a lease; if it detects a reply from another host using the same IP, it declines the lease (DHCPDECLINE) and restarts the discovery process — this is Event ID 1002 (Dhcp-Client) / 4199 (Tcpip).

</details>

---

## Dependency Stack

```
Physical/virtual NIC — link up, driver functional
        │
Adapter configured for DHCP (Dhcp: Enabled on the interface)
        │
Layer 2 broadcast domain reaches either:
   (a) a local, authorized DHCP server, OR
   (b) an L3 device with IP Helper/relay configured toward a remote DHCP server
        │
DHCP server is authorized in Active Directory (Windows DHCP requires AD authorization)
        │
Scope exists for the client's VLAN/subnet and has available (non-exhausted) addresses
        │
Scope options correctly configured (gateway, DNS, domain, search list, static routes)
        │
Server-side conflict detection passes (candidate IP not already in use)
        │
DHCPACK received — client configures interface
        │
Client-side ARP conflict check passes (no duplicate detected)
        │
Lease renews at T1/T2 before expiry (requires continued server reachability)
        │
Client has full IP configuration — network layer functional
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| IP is `169.254.x.x` (APIPA) | No DHCPOFFER received — server unreachable, broadcast not relayed, scope exhausted | `Get-NetAdapter`; confirm relay config; check scope on server |
| Correct subnet, wrong gateway/DNS | Bad scope options (003/006/015) on the DHCP server | `ipconfig /all`; server-side `Get-DhcpServerv4OptionValue` |
| Some devices on a VLAN get IPs, others don't | Scope exhaustion (address pool depleted) | Server-side `Get-DhcpServerv4ScopeStatistics` |
| Devices on VLAN X never get an IP, VLAN Y works fine | Missing/misconfigured IP helper on the VLAN X gateway | Check `giaddr` forwarding at L3 device; confirm scope for VLAN X exists |
| Lease expires and doesn't renew despite server being "up" | Firewall/ACL change blocking UDP 67/68 between client and server post-lease | `Test-NetConnection <server> -Port 67`; check firewall/ACL changes timeline |
| Duplicate IP / lease declined (Event 1002/4199) | Static device using an address inside the active DHCP scope range | `arp -a`; check scope exclusions on server |
| Inconsistent IP/DNS across identical devices on same VLAN | Two DHCP servers responding (rogue or duplicate authorized server) | Compare `DHCP Server` field across devices; packet capture if needed |
| DHCP works but WPAD/proxy is wrong | Option 252 misconfigured or GPO proxy policy conflicting | Check option 252 value vs. Group Policy proxy settings |
| Renewal works over wired, fails over Wi-Fi only | Wireless VLAN/SSID mapped to a different (broken) scope, or client isolation blocking broadcast | Compare wired vs wireless `ipconfig /all`; check AP client-isolation setting |
| Very long DHCPDISCOVER→DHCPACK time (multi-second delays) | DHCP server overloaded, AD replication lag affecting authorization checks, or conflict-detection ping timeouts | Check DHCP server event log; review "Conflict detection attempts" scope setting |

---

## Validation Steps

**1. Confirm adapter state and DHCP enablement:**
```powershell
Get-NetAdapter | Select-Object Name, Status, LinkSpeed
Get-NetIPInterface -AddressFamily IPv4 | Select-Object InterfaceAlias, Dhcp, ConnectionState
```
Expected: `Status = Up`, `Dhcp = Enabled` on the active adapter.

**2. Confirm current lease details:**
```powershell
ipconfig /all | Select-String "IPv4 Address|Subnet Mask|Default Gateway|DHCP Server|Lease Obtained|Lease Expires"
```
Expected: address within the expected subnet, plausible lease window, recognized DHCP server IP.

**3. Force release/renew and observe timing:**
```powershell
Measure-Command { ipconfig /release; ipconfig /renew } 
```
Expected: completes within a few seconds. Long delays (>5-10s) suggest server-side conflict detection ping timeouts or an overloaded/unreachable server.

**4. Test reachability to the DHCP server on the DHCP ports:**
```powershell
$dhcpServer = ((ipconfig /all | Select-String "DHCP Server").ToString() -replace ".*: ", "").Trim()
Test-NetConnection -ComputerName $dhcpServer -Port 67
```
Note: UDP port testing is unreliable with `Test-NetConnection` (it's TCP-oriented) — treat a failure here as informational, not conclusive. A full packet capture is the authoritative test for UDP broadcast/relay issues.

**5. On the DHCP server — confirm authorization and scope health:**
```powershell
# Run on/against the DHCP server (DhcpServer module)
Get-DhcpServerInDC
Get-DhcpServerv4Scope
Get-DhcpServerv4ScopeStatistics -ScopeId <scope-id>
```
Expected: server listed as authorized; target scope `Active`; `PercentageInUse` well under 100%.

**6. Confirm scope options match expected network config:**
```powershell
Get-DhcpServerv4OptionValue -ScopeId <scope-id>
```
Expected: Option 003 (router) matches the VLAN's real gateway; Option 006 (DNS) matches internal DNS servers; Option 015/119 match the domain.

**7. Check for conflict/decline events on the client:**
```powershell
Get-WinEvent -LogName System | Where-Object { $_.Id -in 1002,4199 -and $_.TimeCreated -gt (Get-Date).AddDays(-2) }
```
Expected: no entries. Any entries indicate an active IP conflict pattern.

---

## Troubleshooting Steps (by phase)

### Phase 1: No IP at all (APIPA)

1. Confirm physical/virtual link is up: `Get-NetAdapter`
2. Confirm DHCP is enabled on the interface (not static, not disabled by policy)
3. Release/renew and time it: if it fails fast (<1s), the client isn't even attempting broadcast correctly — check NIC driver; if it fails slow (times out), broadcast isn't reaching a server
4. If other devices on the same VLAN/port work: isolate to this device (NIC, cable, port, driver)
5. If no devices on the VLAN get an address: escalate to network team — check IP helper/relay config on the VLAN's L3 gateway, and confirm the scope for that VLAN exists and is active on the DHCP server

### Phase 2: Wrong config, right subnet

1. Compare `ipconfig /all` output against the expected scope options (gateway, DNS, domain)
2. This is a **server-side** problem in the vast majority of cases — verify on the DHCP server: `Get-DhcpServerv4OptionValue -ScopeId <id>`
3. Check for scope-level vs. server-level vs. reservation-level option overrides — options can be set at three different levels and the most specific wins:
   ```
   Server level (all scopes) → Scope level (this scope only) → Reservation level (this specific device)
   ```
4. After correcting server-side options, force client renewal — DHCP does not push new options to existing leases mid-lease; the client must renew or the server must be configured to force renewal.

### Phase 3: Scope exhaustion

1. Check scope utilization on the server: `Get-DhcpServerv4ScopeStatistics -ScopeId <id>` — look at `PercentageInUse`
2. If near 100%: identify stale/abandoned leases (`Get-DhcpServerv4Lease -ScopeId <id> | Where-Object AddressState -eq "Active"` cross-referenced against known active device count)
3. Options: shorten lease duration (forces faster reclamation), expand the scope's address range, or add exclusion ranges review (reservations/exclusions eating into usable pool unnecessarily)

### Phase 4: Relay/multi-VLAN failure

1. Confirm which VLAN/subnet the affected device is on
2. Confirm a scope exists on the DHCP server for that specific subnet
3. Confirm the L3 gateway for that VLAN has IP helper pointing at the correct DHCP server IP (this is a network-device config check, typically outside Windows tooling — coordinate with network team)
4. Confirm no ACL/firewall between the relay and the DHCP server blocks UDP 67/68
5. Test from a device on a **working** VLAN to isolate whether the problem is server-wide or relay-specific to one VLAN

### Phase 5: Renewal failures on an established lease

1. Confirm the lease was previously valid (`Lease Obtained` timestamp exists and is old)
2. Check event log around the time renewal should have occurred (T1 = 50% of lease duration)
3. Test connectivity to the specific DHCP server IP recorded in the lease — if that specific server is now unreachable (decommissioned, moved, ACL change) but others exist, this explains why T2 rebinding (broadcast to ANY server) may still succeed while T1 unicast renewal fails
4. Root cause is almost always a network path change (firewall rule, VLAN re-IP, decommissioned DHCP server) rather than a Windows client fault

---

## Remediation Playbooks

<details><summary>Playbook 1 — Clean release/renew with service restart (client-side reset)</summary>

```powershell
# Full client-side DHCP reset
ipconfig /release
Restart-Service -Name Dhcp -Force
Start-Sleep -Seconds 3
ipconfig /renew

# Verify
ipconfig /all | Select-String "IPv4 Address|DHCP Server|Lease Obtained|Lease Expires"
Get-NetIPInterface -AddressFamily IPv4 | Select-Object InterfaceAlias, Dhcp
```

**Rollback:** N/A — non-destructive; worst case is a brief loss of connectivity during the renew.

</details>

<details><summary>Playbook 2 — Correct scope options and force option propagation (server-side)</summary>

```powershell
# Run ON the DHCP server (DhcpServer module) — requires DHCP admin rights

# View current options for a scope
Get-DhcpServerv4OptionValue -ScopeId 10.10.20.0

# Set/correct router (003) and DNS (006) options
Set-DhcpServerv4OptionValue -ScopeId 10.10.20.0 -Router 10.10.20.1 -DnsServer 10.10.20.5,10.10.20.6
Set-DhcpServerv4OptionValue -ScopeId 10.10.20.0 -OptionId 15 -Value "corp.domain.com"

# Verify
Get-DhcpServerv4OptionValue -ScopeId 10.10.20.0

# Clients must renew to pick up the change — cannot be pushed mid-lease
# Optionally shorten lease duration temporarily to speed convergence:
Set-DhcpServerv4Scope -ScopeId 10.10.20.0 -LeaseDuration 1.00:00:00
```

**Rollback:**
```powershell
Set-DhcpServerv4OptionValue -ScopeId 10.10.20.0 -Router <previous-gateway> -DnsServer <previous-dns-list>
```

</details>

<details><summary>Playbook 3 — Reclaim scope capacity (exhaustion)</summary>

```powershell
# Run ON the DHCP server

# Check utilization
Get-DhcpServerv4ScopeStatistics -ScopeId 10.10.20.0 | Select-Object ScopeId, Free, InUse, PercentageInUse

# List active leases to identify stale/abandoned entries
Get-DhcpServerv4Lease -ScopeId 10.10.20.0 | Where-Object AddressState -eq "ActiveReservation" | Select-Object IPAddress, HostName, LeaseExpiryTime

# Manually reclaim a specific stale lease (confirm it's genuinely stale first!)
Remove-DhcpServerv4Lease -ScopeId 10.10.20.0 -IPAddress 10.10.20.150

# Or reduce lease duration for faster natural reclamation (temporary, watch server load)
Set-DhcpServerv4Scope -ScopeId 10.10.20.0 -LeaseDuration 08:00:00

# Long-term: expand scope range if genuinely undersized for device count
Set-DhcpServerv4Scope -ScopeId 10.10.20.0 -StartRange 10.10.20.10 -EndRange 10.10.20.250
```

**Rollback:**
```powershell
Set-DhcpServerv4Scope -ScopeId 10.10.20.0 -LeaseDuration 8.00:00:00   # restore original duration
```

</details>

<details><summary>Playbook 4 — Verify and document IP helper / relay config (network-layer, coordination)</summary>

This is typically executed by the network team on switches/routers, not from Windows, but the DHCP-side verification is:

```powershell
# Confirm the DHCP server has an active scope matching the relay's giaddr subnet
Get-DhcpServerv4Scope | Select-Object ScopeId, Name, State

# Confirm the server is authorized (unauthorized Windows DHCP servers silently refuse to lease)
Get-DhcpServerInDC
```

**Request from network team:** confirm `ip helper-address <DHCP-server-IP>` (Cisco syntax; equivalent exists on all major vendors) is configured on the SVI/gateway for the affected VLAN, and that no ACL blocks UDP 67/68 between the relay and server.

**Rollback:** N/A — verification only.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect DHCP client evidence for escalation
.NOTES     Run as admin on the affected client
#>

$OutputDir = "C:\Temp\DHCP-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. Adapter and IP config
Get-NetAdapter | Export-Csv "$OutputDir\NetAdapters.csv" -NoTypeInformation
Get-NetIPInterface -AddressFamily IPv4 | Export-Csv "$OutputDir\IPInterfaces.csv" -NoTypeInformation
Get-NetIPAddress -AddressFamily IPv4 | Export-Csv "$OutputDir\IPAddresses.csv" -NoTypeInformation

# 2. Full ipconfig output
ipconfig /all | Out-File "$OutputDir\ipconfig-all.txt"

# 3. DHCP client event log (last 24h)
Get-WinEvent -LogName System -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -eq "Dhcp-Client" -and $_.TimeCreated -gt (Get-Date).AddHours(-24) } |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$OutputDir\Dhcp-Client-Events.csv" -NoTypeInformation

# 4. Conflict/decline events (broader window)
Get-WinEvent -LogName System -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -in 1002,4199 -and $_.TimeCreated -gt (Get-Date).AddDays(-7) } |
    Select-Object TimeCreated, Id, Message |
    Export-Csv "$OutputDir\Conflict-Events.csv" -NoTypeInformation

# 5. ARP table (for duplicate IP investigation)
arp -a | Out-File "$OutputDir\arp-table.txt"

# 6. Release/renew timing test
$timing = Measure-Command { ipconfig /release | Out-Null; ipconfig /renew | Out-Null }
"Release/Renew took: $($timing.TotalSeconds) seconds" | Out-File "$OutputDir\Release-Renew-Timing.txt"
ipconfig /all | Out-File -Append "$OutputDir\Release-Renew-Timing.txt"

# 7. System info
Get-ComputerInfo | Select-Object CsName, OsVersion, OsBuildNumber | Export-Csv "$OutputDir\System-Info.csv" -NoTypeInformation

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Client-side
Get-NetIPAddress -AddressFamily IPv4 | Where-Object PrefixOrigin -ne "WellKnown"
Get-NetIPInterface -AddressFamily IPv4 | Select-Object InterfaceAlias, Dhcp
ipconfig /all
ipconfig /release
ipconfig /renew
Restart-Service Dhcp -Force
Get-WinEvent -LogName System | Where-Object ProviderName -eq "Dhcp-Client"

# Force DHCP on an interface
Set-NetIPInterface -InterfaceIndex <index> -Dhcp Enabled
Set-DnsClientServerAddress -InterfaceIndex <index> -ResetServerAddresses

# Server-side (DhcpServer module, run on/against the DHCP server)
Get-DhcpServerInDC
Get-DhcpServerv4Scope
Get-DhcpServerv4ScopeStatistics -ScopeId <scope-id>
Get-DhcpServerv4OptionValue -ScopeId <scope-id>
Get-DhcpServerv4Lease -ScopeId <scope-id>
Set-DhcpServerv4OptionValue -ScopeId <scope-id> -Router <gw> -DnsServer <dns1,dns2>
Set-DhcpServerv4Scope -ScopeId <scope-id> -LeaseDuration <timespan>
Remove-DhcpServerv4Lease -ScopeId <scope-id> -IPAddress <ip>
```

---

## 🎓 Learning Pointers

- **DHCPDISCOVER is a Layer 2 broadcast — it never crosses a subnet boundary without a relay.** Every "device on VLAN X can't get an IP but VLAN Y is fine" ticket traces back to this single fact. Learn to check IP helper configuration on the gateway before assuming the DHCP server itself is broken. [MS Docs: DHCP relay agent](https://learn.microsoft.com/en-us/windows-server/networking/technologies/dhcp/dhcp-top)

- **Windows DHCP servers must be authorized in Active Directory to lease addresses** — an unauthorized server will see DHCPDISCOVER packets but silently refuse to respond. This is a common cause of "the DHCP server is running but nothing works" after standing up a new server. `Get-DhcpServerInDC` confirms authorization status.

- **T1/T2 renewal timing explains "it worked yesterday, broke today" tickets** — a network path that changed mid-lease (firewall rule, ACL, decommissioned server) won't surface as a problem until the client's T1 unicast renewal attempt fails, which could be hours or days after the actual change. Always correlate renewal failure timestamps against known infra changes, not just "when the user noticed."

- **Scope options exist at three levels — server, scope, and reservation — and the most specific wins.** A device with a static reservation can have entirely different DNS/gateway options than the rest of the scope, which is a frequent source of "this one device is different" confusion. Always check all three levels when troubleshooting option mismatches.

- **Client-side DHCPDECLINE (duplicate IP) is the client protecting itself, not a bug** — Windows performs a gratuitous ARP check after accepting a lease and will voluntarily decline and restart discovery if it detects a conflict. The real fix is almost always removing a statically-configured device from inside the DHCP scope's active range, or adding an exclusion for that address. [MS Docs: DHCP client troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/dhcp-server-issues)

- **For server-side administration** — DHCP Failover (hot standby/load balance, MCLT split-brain safety), DHCP Policies, the secure dynamic DNS update credential (a common slow-burning failure independent of leasing health), and JET database backup/repair — see `DHCP-Server-A.md` / `DHCP-Server-B.md`.
