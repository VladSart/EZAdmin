# DNS Client Resolution — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains how Windows DNS resolution works end-to-end, why it breaks, and how to own the fix at every layer.

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
- Windows DNS client resolution stack (all Windows 10/11 and Server 2016+)
- On-prem AD-integrated DNS (Microsoft DNS server on DCs)
- Hybrid environments: clients resolving both internal and public names
- VPN-connected clients and DNS routing
- DNS over HTTPS (DoH) interaction with internal resolution

**Out of scope:**
- DNS server-side administration (zone management, replication)
- Third-party DNS resolvers (Pi-hole, Unbound, Cloudflare gateway)
- DNS in containers or WSL (separate resolver chain)

**Assumptions:**
- Windows 10 1903+ or Windows 11
- Devices are domain-joined or Entra ID joined/hybrid joined
- DNS servers are Windows Server DCs (AD-integrated zones)

---

## How It Works

<details><summary>Full architecture</summary>

### Windows DNS Resolution Order

Windows resolves names through an **ordered resolver chain**. Each step is tried before falling through to the next:

```
Application requests name (e.g. "server01" or "intranet.corp.com")
        │
        ▼
1. HOSTS file check
   C:\Windows\System32\drivers\etc\hosts
   (Exact match only. Always wins if entry exists.)
        │
        ▼
2. DNS Client Cache (in-memory, managed by Dnscache service)
   Positive hits: cached from previous successful resolution
   Negative hits: cached NXDOMAIN / failed lookups
   TTL-bounded — entries expire per record TTL or max cache lifetime
        │
        ▼
3. DNS Server query (UDP/53 or TCP/53)
   Queries configured DNS servers in order (primary → secondary)
   Subject to:
     - Interface DNS server assignment (DHCP or static)
     - DNS suffix search list (for unqualified names)
     - NRPT (Name Resolution Policy Table) — overrides per suffix
        │
        ▼
4. NetBIOS Name Cache (only for unqualified short names, if enabled)
   WINS / broadcast (legacy, rare in modern environments)
        │
        ▼
5. mDNS (Multicast DNS — .local names)
   Handled by Windows mDNS resolver for .local suffix
```

### DNS Suffix Search List Resolution

When an **unqualified name** (e.g. `server01`) is queried, Windows appends suffixes from the search list and tries each in order:

```
Query: "server01"
  → Try: server01.corp.domain.com (primary connection-specific suffix)
  → Try: server01.domain.com      (parent domain suffix devolution)
  → Try: server01.                (root — usually fails for internal names)
```

The search list is built from:
1. GPO: DNS Suffix Search List (Computer Config → Admin Templates → Network → DNS Client)
2. DHCP option 15 (domain name) and option 119 (search domain list)
3. Interface-specific `ConnectionSpecificSuffix`

### Name Resolution Policy Table (NRPT)

NRPT routes queries for specific namespaces to specific DNS servers, **bypassing** the interface-level DNS server. It's used by:
- DirectAccess / Always On VPN (routes internal namespace to on-prem DNS)
- DoH policies
- Split-DNS enforcement policies

```
NRPT entry:
  Namespace: .corp.domain.com
  DNS Server: 10.0.0.1 (internal DC)

Effect:
  Any query for *.corp.domain.com → sent to 10.0.0.1
  All other queries → sent to interface-configured DNS servers
```

Check NRPT:
```powershell
Get-DnsClientNrptRule | Select-Object Namespace, NameServers, DAEnable
```

### DNS Client Service (Dnscache)

`Dnscache` (svchost.exe hosting DNS Client) provides:
- In-memory cache of resolved names
- Negative caching of NXDOMAIN responses
- Aggregation of concurrent queries (deduplication)

Without Dnscache, every DNS query goes directly to the DNS server. Dnscache doesn't need to be running for DNS to work, but without it there's no caching and some APIs behave differently.

Cache configuration (registry):
```
HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters
  MaxCacheTtl        = 86400 (max seconds to cache positive responses)
  MaxNegativeCacheTtl = 900  (max seconds to cache NXDOMAIN — default 15 min)
  NegativeCacheTime  = 5     (seconds before retry of negative cached response)
```

### DNS Traffic Path

```
Windows DNS Client
        │ UDP/53 (query < 512 bytes)
        │ TCP/53 (query > 512 bytes, or after UDP truncation)
        ▼
Firewall/NAT (outbound UDP/TCP 53 must be allowed)
        │
        ▼
DNS Server (DC or forwarder)
        │
        ├─ AD-integrated zone → answers from local zone database
        ├─ Forwarder → upstream DNS (ISP or Azure DNS)
        └─ Root hints → public internet resolution
```

### DoH (DNS over HTTPS) in Windows

Windows 11 (and Windows 10 21H2+) support DoH natively. When enabled:
- DNS queries are sent over HTTPS to a configured DoH resolver
- Internal DNS servers that don't support DoH cause resolution failures
- NRPT can enforce DoH for specific namespaces

```powershell
# Check DoH configuration
Get-DnsClientDohServerAddress
netsh dns show global
```

</details>

---

## Dependency Stack

```
Physical NIC / vNIC — driver loaded, link up
        │
IP address (DHCP lease valid or static config correct)
        │
Default gateway reachable (route to DNS server exists)
        │
UDP/TCP 53 allowed through host firewall + network firewall
        │
DNS server IP reachable (ICMP or TCP ping)
        │
DNS Client service (Dnscache) running (optional but expected)
        │
Correct DNS servers assigned per interface
        │
NRPT rules (if VPN/DirectAccess/policy) routing correctly
        │
DNS suffix search list populated correctly
        │
HOSTS file clean (no overriding entries)
        │
DNS server authoritative for queried zone
        │
Correct A/CNAME/PTR records exist on DNS server
        │
Name resolves — IP returned to application
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| All name resolution fails | DNS server unreachable, Dnscache crashed, NIC issue | `Test-NetConnection <DC-IP> -Port 53`; `Get-Service Dnscache` |
| Public names resolve, internal names don't | Wrong DNS server (using ISP/public instead of DC) | `Get-DnsClientServerAddress` |
| Internal FQDNs work, short names don't | Missing or wrong DNS suffix search list | `Get-DnsClient \| Select ConnectionSpecificSuffix` |
| Specific name returns wrong IP | Stale cache, HOSTS file entry, or stale DNS record | `Get-DnsClientCache`; check HOSTS file |
| Specific name returns NXDOMAIN intermittently | Negative caching + record recently added to DNS | `Clear-DnsClientCache`; verify record on DNS server |
| VPN connected but internal names fail | VPN not pushing DNS server or suffix; NRPT missing | `Get-DnsClientNrptRule`; VPN client DNS config |
| Resolution works, then stops after ~15 min | NXDOMAIN negative cache hit; original query failed once | Set `MaxNegativeCacheTtl` lower; fix root cause |
| Everything fails only for one user on a shared machine | Per-user HOSTS file override or profile corruption | Check user HOSTS at `%USERPROFILE%\...` (rare) |
| DoH-related failures on Win 11 | Internal DC added to DoH server list without DoH support | `Get-DnsClientDohServerAddress`; remove internal IPs |
| Resolution slow (>500ms) | Secondary DNS server queried after primary timeout | Check if primary DNS is reachable; reduce timeout |
| Reverse lookup (PTR) fails | PTR record missing in DNS, or reverse zone not configured | `Resolve-DnsName <IP> -Type PTR` |

---

## Validation Steps

**1. Confirm basic IP/network layer:**
```powershell
Get-NetIPAddress | Where-Object { $_.AddressFamily -eq "IPv4" -and $_.PrefixOrigin -ne "WellKnown" }
Get-NetRoute | Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" }
```
Expected: Valid IPv4 address, default gateway present.

**2. Confirm DNS servers assigned:**
```powershell
Get-DnsClientServerAddress | Where-Object AddressFamily -eq 2 |
    Select-Object InterfaceAlias, ServerAddresses
```
Expected: DC IP(s) as primary; secondary DC or secondary DNS as backup. No public IPs as primary for domain-joined devices.

**3. Confirm DNS server is reachable:**
```powershell
$dns = (Get-DnsClientServerAddress | Where-Object AddressFamily -eq 2 | Select-Object -First 1).ServerAddresses[0]
Test-NetConnection -ComputerName $dns -Port 53
```
Expected: `TcpTestSucceeded = True`

**4. Query DNS server directly (bypass cache and NRPT):**
```powershell
nslookup <failing-name> <dns-server-IP>
Resolve-DnsName <failing-name> -Server <dns-server-IP> -NoHostsFile
```
Expected: Returns valid A record. If this works but normal resolution fails → client-side issue (cache, HOSTS, NRPT).

**5. Check NRPT rules:**
```powershell
Get-DnsClientNrptRule | Select-Object Namespace, NameServers, DAEnable
```
Expected: Rules exist for internal namespace pointing to DC IPs. If no rules and VPN connected → VPN DNS routing may be broken.

**6. Check current DNS cache for failing name:**
```powershell
Get-DnsClientCache | Where-Object Entry -Like "*<failing-name-fragment>*"
```
Look for `Status = NxDomainCache` or old IP address.

**7. Verify HOSTS file:**
```powershell
Get-Content C:\Windows\System32\drivers\etc\hosts |
    Where-Object { $_ -notmatch "^#" -and $_.Trim() -ne "" }
```
Expected: Only standard loopback entries; no entries for business names.

**8. Check DNS suffix search list:**
```powershell
(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters").SearchList
Get-DnsClient | Select-Object InterfaceAlias, ConnectionSpecificSuffix
```
Expected: Internal domain suffix present (e.g. `corp.domain.com`).

---

## Troubleshooting Steps (by phase)

### Phase 1: Total DNS Failure (Nothing Resolves)

1. Confirm NIC is up: `Get-NetAdapter | Where-Object Status -eq "Up"`
2. Confirm IP address: `Get-NetIPAddress -AddressFamily IPv4 | Where-Object PrefixOrigin -ne "WellKnown"`
3. Test network layer: `ping 8.8.8.8` (ICMP to public IP)
4. If ping works: DNS layer problem. Check Dnscache service.
5. Check Dnscache: `Get-Service Dnscache` → if Stopped, start it.
6. Check DNS server IPs: `Get-DnsClientServerAddress`
7. Test DNS server port: `Test-NetConnection <DC-IP> -Port 53`
8. If port 53 blocked: Check Windows Firewall + network firewall between client and DC.

### Phase 2: Public Works, Internal Fails

1. Check primary DNS server — should be a DC IP, not a public resolver.
2. `nslookup <internal-name> <DC-IP>` — does the DC resolve it?
   - Yes → client DNS server config is wrong (using public DNS as primary)
   - No → DNS server doesn't have the record; zone/record issue
3. Check NRPT — VPN may require NRPT rules to route internal queries to DC:
   ```powershell
   Get-DnsClientNrptRule
   ```
4. If VPN connected and no NRPT rules for internal namespace → VPN DNS configuration issue (escalate to VPN/network team).

### Phase 3: Specific Name Consistently Fails

1. Check HOSTS file first (takes precedence): look for the name.
2. Check DNS cache: `Get-DnsClientCache | Where-Object Entry -Like "*<name>*"`
   - If `NxDomainCache` → flush: `Clear-DnsClientCache`
   - If wrong IP cached → flush and retest
3. Direct query to DNS server: `Resolve-DnsName <name> -Server <DC-IP> -NoHostsFile`
   - If fails here → record missing or stale on DNS server (zone issue, AD replication lag)
   - If succeeds here → client-side override (HOSTS, cache, NRPT) is the problem
4. If record was recently changed on DNS server → clients may cache old result until TTL expires. Flush and retest.

### Phase 4: VPN DNS Routing

1. Confirm VPN is connected.
2. Check NRPT: `Get-DnsClientNrptRule` — internal namespace should have DC IP as resolver.
3. If no NRPT rules: VPN client is not setting up DNS routing.
   - For Always On VPN (AOVPN): check VPN profile XML → `<DnsSuffix>` and `<NameServers>` in `<DomainNameInformation>`.
   - For third-party VPN: check VPN client DNS settings.
4. Manual NRPT rule (temporary test):
   ```powershell
   Add-DnsClientNrptRule -Namespace ".corp.domain.com" -NameServers @("<DC-IP>")
   ```
5. Test resolution: `Resolve-DnsName server01.corp.domain.com`
6. If this works → AOVPN profile DNS config is the permanent fix needed.

### Phase 5: DNS Cache Tuning

For environments where stale negative caching causes issues (e.g., records frequently added/changed):

```powershell
# Reduce negative cache time from 900s (15min) to 60s
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters"
Set-ItemProperty -Path $regPath -Name "MaxNegativeCacheTtl" -Value 60 -Type DWord

# Reduce positive cache max TTL if needed (default 86400 = 24h)
Set-ItemProperty -Path $regPath -Name "MaxCacheTtl" -Value 3600 -Type DWord

# Restart Dnscache to apply
Restart-Service Dnscache
```

**Warning:** Reducing `MaxCacheTtl` increases DNS query load on DCs. Don't set below 300 seconds in production without understanding the load impact.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Restore correct DNS server assignment via PowerShell</summary>

```powershell
# Get the primary active interface
$adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Virtual -eq $false } | Select-Object -First 1
$ifIndex = $adapter.InterfaceIndex

Write-Host "Configuring DNS on: $($adapter.Name) (Index: $ifIndex)"

# Set DNS servers (replace with actual DC IPs)
$primaryDNS   = "<DC1-IP>"
$secondaryDNS = "<DC2-IP>"
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses @($primaryDNS, $secondaryDNS)

# Flush cache
Clear-DnsClientCache

# Verify and test
Get-DnsClientServerAddress -InterfaceIndex $ifIndex | Select-Object ServerAddresses
Resolve-DnsName <internal-test-name>
```

**Rollback:**
```powershell
# Revert to DHCP-assigned DNS
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ResetServerAddresses
ipconfig /release; ipconfig /renew
```

</details>

<details><summary>Playbook 2 — Fix DNS suffix search list (standalone or GPO)</summary>

**For immediate fix (one device):**
```powershell
# Set connection-specific suffix on the interface
$ifIndex = (Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1).InterfaceIndex
Set-DnsClient -InterfaceIndex $ifIndex -ConnectionSpecificSuffix "corp.domain.com"

# Add to global suffix search list (registry)
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
Set-ItemProperty -Path $regPath -Name "SearchList" -Value "corp.domain.com,domain.com"

# Flush and test
Clear-DnsClientCache
Resolve-DnsName server01  # should now succeed via suffix appending
```

**For fleet fix (Group Policy):**
```
Computer Configuration → Administrative Templates → Network → DNS Client
  → DNS Suffix Search List: Enabled
    Value: corp.domain.com,domain.com
  → Primary DNS Suffix Devolution: Enabled
```

**Rollback:**
```powershell
Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "SearchList" -ErrorAction SilentlyContinue
Set-DnsClient -InterfaceIndex $ifIndex -ConnectionSpecificSuffix ""
```

</details>

<details><summary>Playbook 3 — Add temporary NRPT rule for VPN internal name routing</summary>

**Use when:** VPN is connected but internal names don't resolve because no NRPT rule routes them to the DC.

```powershell
# Add NRPT rule
Add-DnsClientNrptRule -Namespace ".corp.domain.com" -NameServers @("<DC1-IP>", "<DC2-IP>")

# Verify
Get-DnsClientNrptRule | Select-Object Namespace, NameServers

# Test
Clear-DnsClientCache
Resolve-DnsName server01.corp.domain.com

# For permanent fix: update the VPN profile (AOVPN) or push via GPO:
# Computer Configuration → Windows Settings → Name Resolution Policy
```

**Rollback:**
```powershell
Get-DnsClientNrptRule | Where-Object Namespace -like "*.corp.domain.com" |
    Remove-DnsClientNrptRule -Force
```

</details>

<details><summary>Playbook 4 — Remove DoH server entries for internal DCs</summary>

**Use when:** Internal DC IPs appear in the DoH server list, causing resolution failures because DCs don't support DoH.

```powershell
# List current DoH entries
Get-DnsClientDohServerAddress | Select-Object ServerAddress, DohTemplate

# Remove internal DC IPs from DoH list
$internalDCIPs = @("<DC1-IP>", "<DC2-IP>")
foreach ($ip in $internalDCIPs) {
    try {
        Remove-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction Stop
        Write-Host "Removed DoH entry for $ip" -ForegroundColor Green
    } catch {
        Write-Host "No DoH entry found for $ip" -ForegroundColor Yellow
    }
}

# Flush and test
Clear-DnsClientCache
Resolve-DnsName <internal-name>
```

**Also check via netsh:**
```cmd
netsh dns show global
netsh dns delete dohserver serveraddress=<DC-IP>
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect DNS client evidence for escalation
.NOTES     Run as admin
#>

$OutputDir = "C:\Temp\DNS-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. Interface DNS configuration
Get-DnsClientServerAddress | Export-Csv "$OutputDir\DNS-ServerAddresses.csv" -NoTypeInformation
Get-DnsClient | Export-Csv "$OutputDir\DNS-Client-Config.csv" -NoTypeInformation

# 2. DNS cache snapshot
Get-DnsClientCache | Export-Csv "$OutputDir\DNS-Cache.csv" -NoTypeInformation

# 3. NRPT rules
Get-DnsClientNrptRule | Export-Csv "$OutputDir\DNS-NRPT-Rules.csv" -NoTypeInformation

# 4. DoH configuration
Get-DnsClientDohServerAddress | Export-Csv "$OutputDir\DNS-DoH-Servers.csv" -NoTypeInformation

# 5. HOSTS file
Copy-Item C:\Windows\System32\drivers\etc\hosts "$OutputDir\hosts.txt" -ErrorAction SilentlyContinue

# 6. Resolution tests
$testNames = @("google.com", "<internal-name-1>", "<internal-name-2>")
$results = foreach ($name in $testNames) {
    try {
        $r = Resolve-DnsName $name -ErrorAction Stop | Select-Object -First 1
        [PSCustomObject]@{ Name=$name; Status="Resolved"; IP=$r.IPAddress; Type=$r.Type }
    } catch {
        [PSCustomObject]@{ Name=$name; Status="Failed"; IP=""; Type=$_.Exception.Message }
    }
}
$results | Export-Csv "$OutputDir\Resolution-Tests.csv" -NoTypeInformation

# 7. Dnscache service and registry
Get-Service Dnscache | Select-Object Name, Status, StartType | Export-Csv "$OutputDir\Dnscache-Service.csv" -NoTypeInformation
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters" -ErrorAction SilentlyContinue |
    Select-Object MaxCacheTtl, MaxNegativeCacheTtl, NegativeCacheTime |
    Export-Csv "$OutputDir\Dnscache-Registry.csv" -NoTypeInformation

# 8. Tcpip parameters (search list)
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -ErrorAction SilentlyContinue |
    Select-Object SearchList, Domain, NV_Domain | Export-Csv "$OutputDir\Tcpip-Parameters.csv" -NoTypeInformation

# 9. ipconfig /all
ipconfig /all | Out-File "$OutputDir\ipconfig-all.txt"

# 10. System info
Get-ComputerInfo | Select-Object CsName, OsVersion, OsBuildNumber | Export-Csv "$OutputDir\System-Info.csv" -NoTypeInformation

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Resolve a name (with cache)
Resolve-DnsName server01.corp.com

# Resolve bypassing cache and HOSTS
Resolve-DnsName server01.corp.com -NoHostsFile

# Resolve against a specific DNS server
Resolve-DnsName server01.corp.com -Server 10.0.0.1

# Flush DNS cache
Clear-DnsClientCache

# View DNS cache
Get-DnsClientCache | Where-Object Status -ne "Success"

# View all DNS cache entries
Get-DnsClientCache

# Check DNS server config per adapter
Get-DnsClientServerAddress | Where-Object AddressFamily -eq 2

# Set DNS servers on an adapter
Set-DnsClientServerAddress -InterfaceIndex <index> -ServerAddresses @("10.0.0.1","10.0.0.2")

# Revert adapter DNS to DHCP
Set-DnsClientServerAddress -InterfaceIndex <index> -ResetServerAddresses

# Check NRPT rules
Get-DnsClientNrptRule

# Add NRPT rule
Add-DnsClientNrptRule -Namespace ".corp.domain.com" -NameServers @("10.0.0.1")

# Remove NRPT rule
Get-DnsClientNrptRule | Where-Object Namespace -eq ".corp.domain.com" | Remove-DnsClientNrptRule

# Check DoH servers
Get-DnsClientDohServerAddress

# Check DNS suffix search list
(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters").SearchList

# View HOSTS file
Get-Content C:\Windows\System32\drivers\etc\hosts | Where-Object { $_ -notmatch "^#" }

# Check Dnscache service
Get-Service Dnscache | Select-Object Status, StartType

# nslookup with specific server
nslookup <name> <dns-server-ip>
```

---

## 🎓 Learning Pointers

- **Resolution order matters** — HOSTS → cache → DNS → NetBIOS. Engineers waste time troubleshooting DNS when the real problem is a stale HOSTS file entry. Eliminate HOSTS as a cause within the first 60 seconds of any DNS investigation. [MS Docs: Name resolution sequence](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/dns-client-resolution-timeouts)

- **NRPT is the mechanism behind Always On VPN and DirectAccess DNS routing** — without understanding NRPT, you cannot reliably diagnose VPN + DNS issues. `Get-DnsClientNrptRule` is the single most underused command in enterprise DNS troubleshooting. [MS Docs: NRPT](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/dn593632(v=ws.11))

- **Negative caching is silent and devastating** — a single failed DNS query for a name that didn't exist yet caches a 15-minute NXDOMAIN. If a record is added to DNS right after a failed query, the client won't see it for up to 15 minutes. `Clear-DnsClientCache` is the instant fix; lowering `MaxNegativeCacheTtl` in `Dnscache\Parameters` is the permanent mitigation.

- **Split-brain DNS** is the most common cause of "works on-site, breaks on VPN" — internal names (e.g. `*.corp.com`) must be answered by on-prem DCs. Public resolvers don't know these names. If the VPN doesn't push an NRPT rule for the internal namespace, external DNS is queried and returns NXDOMAIN. The fix is always in the VPN profile's `DomainNameInformation` configuration, not the client.

- **DoH can silently break internal name resolution on Windows 11** — if an internal DC IP is configured as a DoH server (because Windows tries DoH against all configured DNS servers), and the DC doesn't support DoH/DoH returns an error, resolution falls back to unencrypted DNS or fails entirely depending on policy. Always check `Get-DnsClientDohServerAddress` when diagnosing Win 11 internal name failures. [MS Docs: DoH in Windows](https://learn.microsoft.com/en-us/windows-server/networking/dns/doh-client-support)

- **Conditional forwarders are the DNS server counterpart to NRPT** — when troubleshooting split DNS, check both the client (NRPT, DNS server assignment) and the DNS server (conditional forwarders for internal zones). If the DC doesn't have a conditional forwarder for the required zone, queries arrive but return NXDOMAIN even though the record exists in another zone/server.
