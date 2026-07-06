# DHCP Client Failures — Hotfix Runbook (Mode B: Ops)
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

Run these first. Results tell you which fix path to take.

```powershell
# 1. Current IP config — is this device on APIPA or the expected subnet?
Get-NetIPAddress -AddressFamily IPv4 | Where-Object PrefixOrigin -ne "WellKnown" | Select-Object InterfaceAlias, IPAddress, PrefixOrigin

# 2. DHCP enabled on the adapter?
Get-NetIPInterface -AddressFamily IPv4 | Select-Object InterfaceAlias, Dhcp, ConnectionState

# 3. Lease details (client-side)
ipconfig /all | Select-String "DHCP Enabled|Lease Obtained|Lease Expires|DHCP Server"

# 4. Is a DHCP server actually reachable? (broadcast discover)
Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object Name, InterfaceIndex

# 5. Recent DHCP client events
Get-WinEvent -LogName System | Where-Object { $_.ProviderName -eq "Dhcp-Client" -and $_.TimeCreated -gt (Get-Date).AddHours(-4) } | Select-Object TimeCreated, Id, Message -First 15
```

| If | Then |
|----|------|
| IP is `169.254.x.x` (APIPA) | No DHCP server responded → **Fix 1** |
| `Dhcp` shows `Disabled` on the adapter | Static IP configured or policy forced static → **Fix 2** |
| Correct subnet IP but wrong DNS/gateway/options | Scope options misconfigured or wrong scope assigned → **Fix 3** |
| Lease expired, not renewing | Client can't reach DHCP server for renewal (firewall/relay) → **Fix 4** |
| Event ID 1002 ("lease declined — duplicate IP") | IP conflict on the network → **Fix 5** |
| Multiple/unexpected DHCP servers responding | Rogue or misconfigured second DHCP server on the segment → **Fix 6** |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Physical/Virtual NIC — link up, driver loaded
        │
Adapter set to obtain IP automatically (DHCP enabled)
        │
DHCPDISCOVER broadcast reaches a DHCP server
   (same broadcast domain, OR DHCP relay/IP helper forwards it)
        │
Authorized DHCP server responds (DHCPOFFER)
        │
Client accepts offer (DHCPREQUEST → DHCPACK)
        │
Scope has available addresses (not exhausted)
        │
Scope options correct (router, DNS, domain, search suffix — options 003/006/015/119)
        │
No IP conflict detected during lease acquisition
        │
Lease renews at T1 (50%) / rebinds at T2 (87.5%) before expiry
        │
Client has usable IP, gateway, DNS — network functions
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm whether this is APIPA (no DHCP response) or a bad lease:**
```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object PrefixOrigin -ne "WellKnown" | Select-Object InterfaceAlias, IPAddress
```
`169.254.x.x` = APIPA, no DHCP server responded at all. Anything else with wrong gateway/DNS = scope/option issue, not a discovery failure.

**2. Force a release/renew and watch what happens:**
```powershell
ipconfig /release
ipconfig /renew
ipconfig /all | Select-String "DHCP Server|IPv4 Address|Lease"
```
Expected: New IP from expected subnet, `DHCP Server` shows an internal server IP.
If renew hangs or fails → broadcast isn't reaching a server (see Fix 4 / Fix 6).

**3. Check adapter DHCP setting (is it even trying?):**
```powershell
Get-NetIPInterface -AddressFamily IPv4 -InterfaceAlias "<AdapterName>" | Select-Object Dhcp
```
If `Disabled` → static config or GPO forced it; go to Fix 2.

**4. Check for duplicate IP / conflict events:**
```powershell
Get-WinEvent -LogName System | Where-Object { $_.Id -in 4199,1002 -and $_.TimeCreated -gt (Get-Date).AddDays(-1) }
```
Event 4199 (TCP/IP) or 1002 (Dhcp-Client) = duplicate address detected.

**5. On a switch/VLAN with no local DHCP server — is there a relay?**
```powershell
# From a device that DOES get an IP on the same VLAN, confirm the assigned DHCP Server IP
ipconfig /all | Select-String "DHCP Server"
# If that IP isn't on the local subnet, an IP Helper/relay is in play — verify with network team
```

**6. Check for a second/rogue DHCP server (if leases are inconsistent across devices):**
```powershell
# Requires DHCP server role tools or a packet capture; quick client-side signal:
Get-WinEvent -LogName System | Where-Object { $_.ProviderName -eq "Dhcp-Client" -and $_.Message -match "different" }
```

---

## Common Fix Paths

<details><summary>Fix 1 — APIPA address, no DHCP server responded</summary>

**Symptom:** IP is `169.254.x.x`. Device has no real network connectivity.

```powershell
# Confirm NIC is actually up
Get-NetAdapter | Select-Object Name, Status, LinkSpeed

# Release/renew
ipconfig /release
ipconfig /renew

# If renew fails immediately, restart the DHCP Client service
Restart-Service -Name Dhcp -Force

# Retest
ipconfig /all | Select-String "IPv4 Address|DHCP Server"
```

**If still APIPA after renew:**
- Confirm the switch port is on the correct VLAN (802.1X or port config issue — escalate to network team)
- Confirm the DHCP server role is running and the scope is active: check on the DHCP server, not the client
- Check cable/link — `Get-NetAdapter` should show `Up` with a valid `LinkSpeed`

**Rollback:** N/A — DHCP renewal is non-destructive.

</details>

<details><summary>Fix 2 — Adapter set to static, needs to be DHCP</summary>

**Symptom:** `Get-NetIPInterface` shows `Dhcp: Disabled`. IP/gateway/DNS are manually set (possibly wrong or stale).

```powershell
$ifIndex = (Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1).InterfaceIndex

# Remove static IP config
Remove-NetIPAddress -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue

# Re-enable DHCP
Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Enabled
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ResetServerAddresses

# Renew
ipconfig /renew

# Verify
Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 | Select-Object Dhcp
```

**Note:** If this was set via GPO (Wired/Wireless Network Policy), the setting will revert on next policy refresh unless the GPO itself is corrected.

**Rollback:** Re-apply the previous static IP if the change was intentional:
```powershell
New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress <old-IP> -PrefixLength <old-prefix> -DefaultGateway <old-gateway>
```

</details>

<details><summary>Fix 3 — Correct subnet, wrong DNS/gateway/domain (bad scope options)</summary>

**Symptom:** Device gets an address in the right range but wrong DNS servers, wrong default gateway, or missing domain suffix — symptoms of a mis-scoped DHCP server, not the client.

```powershell
# Confirm what was actually handed out
ipconfig /all | Select-String "DHCP Server|DNS Servers|Default Gateway|DHCP Domain Name"
```

This is almost always a **server-side scope option problem** (Option 003 router, 006 DNS, 015 domain name, 119 search list). Client-side there is no fix beyond releasing/renewing after the server-side scope is corrected:

```powershell
ipconfig /release
ipconfig /renew
```

**Escalate to whoever owns DHCP server config** — check scope options on the DHCP server:
```powershell
# Run ON the DHCP server (requires DhcpServer module)
Get-DhcpServerv4OptionValue -ScopeId <scope-id>
```

**Rollback:** N/A — this is a config correction, not a destructive change.

</details>

<details><summary>Fix 4 — Lease not renewing (server unreachable at renewal time)</summary>

**Symptom:** Device had a valid lease, now shows expired or about-to-expire with renewal failures in the event log.

```powershell
# Check lease timers
ipconfig /all | Select-String "Lease Obtained|Lease Expires"

# Test whether the DHCP server (the one in the last lease) is reachable
$dhcpServer = (ipconfig /all | Select-String "DHCP Server" | Select-Object -First 1) -replace ".*: ", ""
Test-NetConnection -ComputerName $dhcpServer -Port 67 -InformationLevel Detailed

# Force release/renew
ipconfig /release
ipconfig /renew
```

If `Test-NetConnection` fails: the path to the DHCP server (or relay/IP helper on the router/switch) is broken. This is a network-layer escalation, not a client fix — gather evidence and hand off.

**Rollback:** N/A.

</details>

<details><summary>Fix 5 — Duplicate IP address detected (lease declined)</summary>

**Symptom:** Event ID 1002/4199. Device falls back to APIPA or a different address after detecting a conflict.

```powershell
# Confirm the conflicting IP
Get-WinEvent -LogName System | Where-Object Id -in 1002,4199 | Select-Object -First 5 -Property TimeCreated, Message | Format-List

# Release the declined lease and force a clean renew
ipconfig /release
ipconfig /renew

# Identify the OTHER device holding the IP (from another host on the same subnet):
arp -a | Select-String "<conflicting-IP>"
```

**Root cause is usually:** a statically-configured device using an address inside the DHCP scope's range. Fix by either excluding that IP from the DHCP scope (server-side) or reconfiguring the static device to use an address outside the scope.

**Rollback:** N/A — this is a network hygiene fix, not reversible in the traditional sense.

</details>

<details><summary>Fix 6 — Rogue or duplicate DHCP server on the segment</summary>

**Symptom:** Devices on the same VLAN get inconsistent IPs/DNS/gateways depending on which server answers first. Often introduced by a consumer router, a misconfigured lab VM, or a second authorized-but-misscoped server.

```powershell
# Client-side signal only — full detection needs a packet capture or DHCP server audit
# Quick check: does ipconfig /all show a DHCP Server IP you don't recognize?
ipconfig /all | Select-String "DHCP Server"
```

**This requires network-team escalation** — rogue DHCP servers are not fixable from the client. Recommended immediate mitigations:
- Enable DHCP snooping on managed switches (network team action)
- Identify and physically disconnect/disable the rogue device
- On Windows DHCP servers, confirm the legitimate server is **authorized** in AD (`Get-DhcpServerInDC`)

**Rollback:** N/A — this is an infrastructure fix.

</details>

---

## Escalation Evidence

```
=== DHCP Client Failure — Ticket Evidence ===

Date/Time:            _______________
Device Name:          _______________
User:                 _______________
VLAN / Site:          _______________
Current IP:            _______________  (note if APIPA 169.254.x.x)
Expected subnet:       _______________

--- Commands Run ---
Get-NetIPInterface (Dhcp Enabled/Disabled): _______________
ipconfig /all (DHCP Server, Lease times):   _______________
ipconfig /release && /renew result:         _______________
Test-NetConnection <DHCP-server> -Port 67:  _______________
Recent Dhcp-Client / duplicate IP events:   _______________

--- Scope of Impact ---
Single device or multiple:  _______________
Same VLAN affected devices: _______________
Recent network changes:     _______________ (new switch, VLAN change, new DHCP scope)

--- Steps Taken ---
[ ] Released/renewed lease
[ ] Confirmed adapter DHCP-enabled
[ ] Tested DHCP server reachability (port 67/68)
[ ] Checked for duplicate IP / rogue server signs
[ ] Escalated to network/DHCP server owner
```

---

## 🎓 Learning Pointers

- **APIPA (169.254.0.0/16) means the client never got a DHCPOFFER at all** — not a scope option problem, not a DNS problem. Don't waste time on DNS/gateway troubleshooting until you've ruled out basic DHCP discovery failure. [MS Docs: APIPA](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/automatic-private-ip-addressing-overview)

- **DHCP is a four-step handshake (DORA): Discover → Offer → Request → Acknowledge.** A broadcast (Discover) that never leaves the local broadcast domain is the single most common cause of "no IP address" tickets in multi-VLAN environments — it requires an IP helper/DHCP relay configured on the router or L3 switch, which is entirely outside client-side control.

- **Lease renewal happens at 50% (T1) and 87.5% (T2) of lease duration, not just at expiry** — a device that's been reachable all along but suddenly can't reach the DHCP server (firewall change, ACL, relay outage) will show renewal failures well before the lease visibly "expires." Check event log timestamps against the lease's T1/T2 windows, not just the expiry time.

- **A second authorized DHCP server with an overlapping or misconfigured scope is indistinguishable from a rogue server without packet capture** — `ipconfig /all` on affected devices showing different `DHCP Server` values for the same subnet is the fastest client-side tell. Escalate rather than chasing this from a single endpoint.

- **Static IP inside a DHCP scope's active range is the #1 cause of "random" duplicate IP tickets** — always check for statically configured infrastructure (printers, IoT devices, non-domain equipment) before assuming a software fault. [MS Docs: DHCP troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/dhcp-server-issues)
