# DNS Client Resolution Failures — Hotfix Runbook (Mode B: Ops)
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
# 1. Basic connectivity test — is DNS the actual problem?
Resolve-DnsName google.com -ErrorAction SilentlyContinue | Select-Object Name, IPAddress
ping -n 1 8.8.8.8

# 2. Which DNS servers is the client using?
Get-DnsClientServerAddress | Where-Object AddressFamily -eq 2 | Select-Object InterfaceAlias, ServerAddresses

# 3. What does the DNS cache look like?
Get-DnsClientCache | Where-Object { $_.Status -ne "Success" } | Select-Object Entry, Status, TTL | Select-Object -First 20

# 4. Is the DNS Client service running?
Get-Service -Name Dnscache | Select-Object Status, StartType

# 5. Check for name suffix search order (domain suffix issues)
Get-DnsClient | Select-Object InterfaceAlias, ConnectionSpecificSuffix, UseSuffixWhenRegistering
```

| If | Then |
|----|------|
| `Resolve-DnsName` fails but `ping 8.8.8.8` succeeds | DNS servers unreachable or wrong servers assigned → **Fix 1** |
| Both `Resolve-DnsName` and `ping 8.8.8.8` fail | Full network connectivity issue, not DNS → check NIC/DHCP |
| DNS resolves public but not internal names (e.g. `corp.domain.local`) | Split-brain DNS misconfiguration or wrong search suffix → **Fix 2** |
| DNS was working, now failing after update/reboot | DNS Client service or cache corruption → **Fix 3** |
| Dnscache service `Stopped` | Service crash or GPO disabled it → **Fix 4** |
| Specific names fail; others work | Cache poisoning or stale NXDOMAIN cached → **Fix 5** |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Physical/Virtual NIC — connected and operational
        │
IP address assigned (DHCP or static)
        │
DNS server IP reachable (Layer 3 path exists)
        │
DNS Client service (Dnscache) running
        │
Correct DNS servers configured on adapter
        │
Correct DNS search suffixes for internal names
        │
DNS server has valid records (A/CNAME/PTR)
        │
No stale/poisoned cache entry blocking resolution
        │
Firewall allows UDP/TCP 53 outbound
        │
Name resolves and is returned to application
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm the DNS server is reachable:**
```powershell
$dnsServer = (Get-DnsClientServerAddress | Where-Object AddressFamily -eq 2 | Select-Object -First 1).ServerAddresses | Select-Object -First 1
Test-NetConnection -ComputerName $dnsServer -Port 53
```
Expected: `TcpTestSucceeded = True`
If False → DNS server IP is unreachable. Check routing/firewall, not the client.

**2. Query DNS server directly (bypass local cache):**
```powershell
# Replace corp.domain.com with the failing name
nslookup corp.domain.com <DNS-server-IP>
Resolve-DnsName corp.domain.com -Server <DNS-server-IP> -NoHostsFile
```
Expected: Returns A record IP.
If fails here → problem is on the DNS server side, not the client.

**3. Check if client cache has a stale NXDOMAIN:**
```powershell
Get-DnsClientCache | Where-Object Entry -Like "*corp.domain*"
```
If `Status = NxDomainCache` → purge it (see Fix 5).

**4. Confirm search suffixes:**
```powershell
Get-DnsClient | Select-Object InterfaceAlias, ConnectionSpecificSuffix
ipconfig /all | Select-String "DNS Suffix"
```
For internal names to resolve without FQDN, the domain suffix (e.g. `corp.domain.com`) must appear in the search list.

**5. Check for DNS over HTTPS (DoH) blocking internal resolution:**
```powershell
Get-DnsClientDohServerAddress | Select-Object ServerAddress, DohTemplate
# If internal DNS servers are listed here with DoH, they may not support it
```

**6. Check Windows Firewall for DNS blocking:**
```powershell
Get-NetFirewallRule | Where-Object { $_.DisplayName -like "*DNS*" -and $_.Action -eq "Block" }
```

---

## Common Fix Paths

<details><summary>Fix 1 — Wrong or unreachable DNS servers configured</summary>

**Symptom:** `Get-DnsClientServerAddress` shows wrong IPs, or DNS server is unreachable.

```powershell
# View current DNS server config
Get-DnsClientServerAddress | Where-Object AddressFamily -eq 2

# Set correct DNS servers (replace with your DC IPs)
$ifIndex = (Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1).InterfaceIndex
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses @("<DC1-IP>", "<DC2-IP>")

# Verify
Get-DnsClientServerAddress -InterfaceIndex $ifIndex | Select-Object ServerAddresses

# Flush cache and retest
Clear-DnsClientCache
Resolve-DnsName <failing-name>
```

**Rollback:** Restore previous DNS server IPs or re-run DHCP release/renew:
```powershell
ipconfig /release && ipconfig /renew
```

</details>

<details><summary>Fix 2 — Internal names not resolving (split-brain / missing suffix)</summary>

**Symptom:** `ping server01` fails but `ping server01.corp.domain.com` works. Internal FQDN resolves but short name doesn't.

```powershell
# Add domain suffix to the connection-specific suffix list
$ifIndex = (Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1).InterfaceIndex
Set-DnsClient -InterfaceIndex $ifIndex -ConnectionSpecificSuffix "corp.domain.com"

# Or add to global suffix search list (requires admin / registry edit):
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
$current = (Get-ItemProperty $regPath).SearchList
Set-ItemProperty $regPath -Name "SearchList" -Value "corp.domain.com,$current"

# Verify
Get-DnsClient | Select-Object InterfaceAlias, ConnectionSpecificSuffix

# Flush and test
Clear-DnsClientCache
Resolve-DnsName server01
```

**Note:** On domain-joined machines, the domain suffix should be set automatically by Group Policy. If it's missing, check GPO: Computer Configuration → Administrative Templates → Network → DNS Client → DNS Suffix Search List.

**Rollback:**
```powershell
Set-DnsClient -InterfaceIndex $ifIndex -ConnectionSpecificSuffix ""
```

</details>

<details><summary>Fix 3 — DNS cache corrupted / stale records causing failures</summary>

**Symptom:** Name was resolving, now consistently fails. Cache entry shows wrong IP or NXDOMAIN.

```powershell
# Flush all DNS cache
Clear-DnsClientCache

# Confirm cache is cleared
Get-DnsClientCache | Measure-Object

# Also clear NetBIOS cache (for NetBIOS name resolution)
nbtstat -RR

# Re-test resolution
Resolve-DnsName <failing-name>
ipconfig /flushdns
```

**No rollback needed** — cache is rebuilt from authoritative DNS servers.

</details>

<details><summary>Fix 4 — DNS Client service (Dnscache) stopped or disabled</summary>

**Symptom:** `Get-Service Dnscache` shows `Stopped`. Name resolution fails completely.

```powershell
# Check current state
Get-Service -Name Dnscache | Select-Object Status, StartType

# Start the service
Start-Service -Name Dnscache

# Ensure it's set to Automatic
Set-Service -Name Dnscache -StartupType Automatic

# Verify
Get-Service -Name Dnscache | Select-Object Status, StartType

# Test resolution
Resolve-DnsName google.com
```

**If service won't start:** Check Event Viewer → System → filter on Source = `Service Control Manager`.

**Note:** Group Policy can disable Dnscache intentionally (rare, but seen in hardened environments). Check: `HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache` → `Start` value. 4 = Disabled.

**Rollback:** N/A — re-enabling a stopped service is safe.

</details>

<details><summary>Fix 5 — Stale NXDOMAIN or wrong IP cached for specific name</summary>

**Symptom:** Specific name (e.g. `intranet.corp.com`) returns NXDOMAIN or wrong IP. Other names work. Recently the record was changed/added on DNS server.

```powershell
# Identify the stale cache entry
Get-DnsClientCache | Where-Object Entry -Like "*intranet*"

# Remove a specific cached entry
Remove-DnsClientCache -Entry "intranet.corp.com"

# Or flush everything
Clear-DnsClientCache

# Query the DNS server directly to confirm the correct record exists
Resolve-DnsName intranet.corp.com -Server <DC-IP> -NoHostsFile

# Then test normal resolution
Resolve-DnsName intranet.corp.com
```

**Check the HOSTS file** — HOSTS file takes precedence over DNS:
```powershell
Get-Content C:\Windows\System32\drivers\etc\hosts | Where-Object { $_ -notmatch "^#" -and $_ -ne "" }
```
If a wrong entry exists for the failing name, remove it.

</details>

---

## Escalation Evidence

```
=== DNS Resolution Failure — Ticket Evidence ===

Date/Time:         _______________
Device Name:       _______________
User:              _______________
Affected Name(s):  _______________  (e.g. intranet.corp.com, server01)
Error Message:     _______________  (e.g. "DNS name does not exist", timeout)

--- Commands Run ---
Resolve-DnsName <failing-name>:          _______________
Test-NetConnection <DNS-server> -Port 53: TcpTestSucceeded = _______________
Get-DnsClientServerAddress (servers):   _______________
ping 8.8.8.8 result:                    _______________
Dnscache service status:                _______________
nslookup <name> <dc-ip> result:         _______________

--- Domain/Network Info ---
Domain joined:     _______________
VPN connected:     _______________
On-prem or remote: _______________
Recent changes:    _______________  (new policy, VPN update, OS update)

--- Steps Taken ---
[ ] Flushed DNS cache
[ ] Verified DNS server IPs
[ ] Tested DNS server directly (nslookup)
[ ] Checked HOSTS file
[ ] Restarted Dnscache service
[ ] Checked search suffixes
```

---

## 🎓 Learning Pointers

- **HOSTS file wins over DNS** — always check `C:\Windows\System32\drivers\etc\hosts` when a specific name misbehaves. A leftover test entry can silently override DNS for months. It's the first thing to rule out.

- **Dnscache TTL caching is aggressive by default** — Windows caches negative (NXDOMAIN) responses for up to 15 minutes by default (`NegativeCacheTime` registry value). If a record was recently added to DNS, clients may keep failing until the NXDOMAIN TTL expires. `Clear-DnsClientCache` is the immediate fix. [MS Docs: DNS cache settings](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/dns-client-resolution-timeouts)

- **Split-brain DNS** — in hybrid environments, internal names (`.corp.local`, `.corp.com`) must be resolved by on-prem DCs, not by public resolvers. If a client uses a public DNS (e.g. `8.8.8.8`) as its primary, internal names fail. Always verify DNS servers assigned via DHCP point to DCs, not ISP resolvers.

- **VPN DNS routing** — VPN clients often push a DNS server but fail to push search suffixes. Users can resolve `server01.corp.com` (FQDN) but not `server01` (short name). Push the DNS suffix via VPN client config or Group Policy: Computer Configuration → Administrative Templates → Network → DNS Client → DNS Suffix Search List. [MS Docs: DNS suffix](https://learn.microsoft.com/en-us/windows-server/networking/dns/troubleshoot/troubleshoot-dns-client)

- **DoH (DNS over HTTPS) can break internal resolution** — Windows 11 may attempt DoH against internal DNS servers that don't support it, causing resolution failures for internal names. Check `Get-DnsClientDohServerAddress` and remove internal DC IPs from the DoH list if present.
