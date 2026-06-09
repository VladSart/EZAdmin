# Windows Network Adapters — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

Covers physical NICs, virtual adapters (Hyper-V, VPN), Wi-Fi, and NDIS-layer issues on Windows 10/11 and Windows Server 2019/2022. Applicable in both bare-metal and VM guest scenarios (VMware, Hyper-V, Azure).

**Out of scope:** Layer 3 routing issues (see DNS-Client or AlwaysOnVPN runbooks), network switch/VLAN configuration, or Wi-Fi AP channel conflicts.

**Assumptions:**
- PowerShell 5.1+ available
- Run as administrator unless noted
- Event logs accessible (not cleared)

---

## How It Works

<details><summary>Full architecture — Windows network stack</summary>

Windows networking is layered. Understanding the stack is critical for isolating where a fault lives:

```
┌─────────────────────────────────────────────┐
│            User Applications                │
│         (Browser, SMB, RDP, etc.)           │
├─────────────────────────────────────────────┤
│         Winsock (ws2_32.dll)                │  ← socket API
├─────────────────────────────────────────────┤
│          TCP/IP Stack (tcpip.sys)           │  ← IP, TCP, UDP, ICMP
├─────────────────────────────────────────────┤
│          NDIS Filter Drivers                │  ← WFP, QoS, VPN, AV
│  (e.g. ndis.sys, wfplwf.sys, ndiscap.sys)  │
├─────────────────────────────────────────────┤
│         NDIS Miniport Driver                │  ← vendor NIC driver
│    (e.g. e1d68x64.sys, nvmxax64.sys)       │
├─────────────────────────────────────────────┤
│            Physical NIC / vNIC              │
└─────────────────────────────────────────────┘
```

**Key components:**
- **NDIS (Network Driver Interface Specification):** Abstraction layer between network protocols and hardware drivers. Current version: NDIS 6.x on Windows 10/11.
- **tcpip.sys:** Windows TCP/IP driver. Handles IP addressing, routing table, TCP/UDP connections.
- **NDIS Filter Drivers:** Third-party or OS-provided drivers that sit between the protocol layer and miniport. Common culprits in connectivity issues — VPN clients, antivirus, QoS drivers.
- **WFP (Windows Filtering Platform):** The kernel-mode firewall/packet filter. Windows Firewall and most security products hook here.
- **Network Location Awareness (NLA):** Service that determines network type (Domain/Private/Public). Affects firewall profile — stale NLA detection causes Domain profile to fall back to Public, blocking WMI, SMB, etc.

**Adapter types:**
| Type | Interface | Common Issue |
|------|-----------|--------------|
| Physical NIC | PCI/PCIe | Driver, firmware, link negotiation |
| Hyper-V Virtual NIC | VMBus | VMMS service, virtual switch |
| Wi-Fi adapter | PCI/USB | Driver, radio state, EAP auth |
| VPN (TAP/TUN) | Software | Service dependency, filter driver stack |
| Azure/AWS vNIC | Synthetic | Driver version, accelerated networking |

</details>

---

## Dependency Stack

```
Physical Link / vNIC Hardware
        │
NIC Firmware & Driver (miniport)
        │
NDIS Filter Driver Stack
  ├── WFP (Windows Firewall)
  ├── VPN filter driver (if applicable)
  └── AV/EDR NDIS filter (if applicable)
        │
NDIS Protocol Bindings (tcpip.sys, ms_msclient, ms_server)
        │
TCP/IP Stack
  ├── IP Address (DHCP client / static)
  ├── Default Gateway
  └── DNS Resolver (dnscache service)
        │
Winsock Layer
        │
NLA Service (netprofm / nlasvc)
        │
Network Profile (Domain / Private / Public)
        │
Windows Firewall Profile applied
        │
Application Connectivity
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Adapter shows "No network access" but link is up | DHCP failure or IP conflict | `ipconfig /all`; Event ID 1001 DHCP |
| Adapter shows "Identifying…" indefinitely | NLA failure or domain DC unreachable | `netsh wlan show profile` / NLM event log |
| Adapter missing from Device Manager | Driver not loaded / PnP issue | `pnputil /enum-drivers`; setupapi.dev.log |
| Intermittent drops on Wi-Fi | Power management aggressive, driver bug | `Get-NetAdapterPowerManagement` |
| VPN adapter causes split-brain DNS | Incorrect metric or DNS binding order | `Get-NetIPInterface`; `Get-DnsClientGlobalSetting` |
| NIC in "Limited connectivity" after resume | NDIS wake-arm not clearing properly | Event ID 10400 in System log; driver update |
| Network adapter disabled after update | Windows Update reset driver to default | Device Manager → Driver Roll Back |
| No network on new VM | Missing synthetic NIC driver | Hyper-V Integration Services version |
| Teaming (LBFO) bond degraded | One member down or mismatch VLAN | `Get-NetLbfoTeam`; `Get-NetLbfoTeamMember` |
| High packet loss but link healthy | MTU mismatch / jumbo frames misconfigured | `ping -f -l 1472 <gateway>` |

---

## Validation Steps

**1. Confirm adapter state and speed**
```powershell
Get-NetAdapter | Select-Object Name, Status, LinkSpeed, MediaType, DriverVersion | Format-Table -AutoSize
```
Expected: Status = Up, LinkSpeed matches infrastructure expectation (1 Gbps / 10 Gbps).
Bad: Status = Disconnected, LinkSpeed = 0, or MediaType = 802.3 on a Wi-Fi adapter.

**2. Confirm IP configuration**
```powershell
Get-NetIPAddress | Where-Object {$_.AddressFamily -eq "IPv4"} | Select-Object InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin | Format-Table -AutoSize
```
Expected: `PrefixOrigin = Dhcp` (or Manual for static). IP in the correct subnet.
Bad: APIPA address (169.254.x.x) indicates DHCP failure. Duplicate IP = `PrefixOrigin = WellKnown`.

**3. Confirm default gateway and route table**
```powershell
Get-NetRoute -AddressFamily IPv4 | Where-Object {$_.DestinationPrefix -eq "0.0.0.0/0"} | Select-Object InterfaceAlias, NextHop, RouteMetric | Format-Table
```
Expected: Single default route with appropriate metric. On VPN, two routes (split) or one via VPN tunnel (full).
Bad: No default route, or two conflicting default routes with equal metric.

**4. Test gateway reachability**
```powershell
$gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1).NextHop
Test-NetConnection -ComputerName $gw -InformationLevel Detailed
```
Expected: `PingSucceeded = True`, `TcpTestSucceeded` not applicable at L3.
Bad: `PingSucceeded = False` — issue is L1/L2 or IP misconfiguration.

**5. Confirm DNS resolution**
```powershell
Resolve-DnsName google.com -ErrorAction SilentlyContinue | Select-Object Name, Type, IPAddress
```
Expected: Returns A records.
Bad: "DNS name does not exist" — DNS client issue (see DNS-Client runbook).

**6. Check NDIS filter driver stack**
```powershell
Get-NetAdapterBinding | Where-Object {$_.Enabled -eq $true} | Select-Object Name, DisplayName, ComponentID | Sort-Object Name | Format-Table -AutoSize
```
Expected: Standard bindings: `ms_tcpip`, `ms_msclient`, `ms_server`. VPN or security filter drivers visible and expected.
Bad: Orphaned filter driver (e.g. from uninstalled VPN client) with no owning service — this stalls packets.

**7. Check Power Management (Wi-Fi / laptops)**
```powershell
Get-NetAdapterPowerManagement | Select-Object Name, AllowComputerToTurnOffDevice, WakeOnMagicPacket | Format-Table
```
Expected on servers: `AllowComputerToTurnOffDevice = Disabled`.
Bad on laptops: Can cause adapter drop after idle; disable if connectivity drops intermittently.

---

## Troubleshooting Steps by Phase

### Phase 1 — Physical / Link Layer
1. Confirm LED activity on NIC and switch port.
2. Check Event Viewer → System for Event ID **10317** (miniport driver timed out) or **10400** (wake-arm failure).
3. Check Device Manager for yellow bang (!) on network adapter — if present, driver is not loaded.
4. Run driver signature check:
   ```powershell
   Get-WindowsDriver -Online | Where-Object {$_.OriginalFileName -like "*net*"} | Select-Object Driver, ProviderName, Date, Version | Format-Table -AutoSize
   ```
5. Confirm physical NIC is not disabled in BIOS/UEFI (common on re-imaged hardware).

### Phase 2 — Driver / NDIS
1. Check driver version vs. vendor's latest release. Intel/Broadcom/Realtek all publish driver packs.
2. Check filter driver stack for orphans:
   ```powershell
   Get-NetAdapterBinding | Where-Object {$_.ComponentID -notmatch "^ms_"} | Format-Table Name, DisplayName, ComponentID, Enabled
   ```
   Orphaned third-party bindings (Enabled = True, but service gone) block traffic. Disable with:
   ```powershell
   Disable-NetAdapterBinding -Name "<adapter>" -ComponentID "<ComponentID>"
   ```
3. Reset NDIS stack without full network reset:
   ```powershell
   netsh int ip reset resetlog.txt
   netsh winsock reset
   # Then reboot
   ```

### Phase 3 — IP / DHCP
1. Force DHCP renewal:
   ```powershell
   ipconfig /release "<adapter name>"
   ipconfig /renew "<adapter name>"
   ```
2. Check DHCP client service:
   ```powershell
   Get-Service Dhcp | Select-Object Status, StartType
   ```
3. Check Event ID **1001** (DHCP address conflict) and **1007** (DHCP server unavailable) in System log:
   ```powershell
   Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001,1007; ProviderName='Microsoft-Windows-Dhcp-Client'} -MaxEvents 20 | Select-Object TimeCreated, Id, Message | Format-List
   ```
4. Static IP conflict — scan subnet with Test-NetConnection or arp -a to identify conflicting host.

### Phase 4 — NLA / Network Profile
1. Check current network profile:
   ```powershell
   Get-NetConnectionProfile | Select-Object Name, NetworkCategory, IPv4Connectivity, IPv6Connectivity
   ```
2. If profile is "Public" on a domain-joined machine, NLA failed to detect the domain. Confirm DC reachability:
   ```powershell
   nltest /dsgetdc:<domain.fqdn>
   ```
3. Force profile recategorisation (requires admin):
   ```powershell
   Set-NetConnectionProfile -InterfaceAlias "<adapter>" -NetworkCategory Private  # or DomainAuthenticated via nltest
   ```

### Phase 5 — VM / Virtual Adapter Specific
1. Hyper-V: confirm Integration Services are current:
   ```powershell
   Get-VMIntegrationService -VMName "<VMName>" | Select-Object Name, Enabled, PrimaryOperationalStatus
   ```
2. VMware: confirm VMware Tools version and `vmxnet3` driver version against VMware HCL.
3. Azure: confirm Accelerated Networking is enabled and driver (`VF` interface) is bound:
   ```powershell
   Get-NetAdapter | Where-Object {$_.DriverDescription -like "*Mellanox*" -or $_.DriverDescription -like "*Azure*"} | Format-Table Name, Status, LinkSpeed
   ```

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Reset IP stack (NDIS/TCP/Winsock)</summary>

**When to use:** After orphaned filter drivers removed, after VPN client uninstall leaves stack dirty, or persistent "Limited Connectivity" post-upgrade.

```powershell
# Run in elevated PowerShell — REBOOT REQUIRED after
netsh int ip reset C:\Temp\ip-reset.log
netsh int ipv6 reset C:\Temp\ipv6-reset.log
netsh winsock reset
netsh advfirewall reset
# Do NOT restart services — a full reboot is required to reload NDIS
Write-Host "Stack reset complete. Reboot now." -ForegroundColor Yellow
```

**Rollback:** No rollback possible — this is a clean slate. Previous static IPs must be re-entered manually. Firewall exceptions are reset to Windows defaults.

</details>

<details>
<summary>Fix 2 — Remove orphaned NDIS filter driver binding</summary>

**When to use:** Old VPN client (Cisco AnyConnect, Palo Alto GlobalProtect, Pulse Secure) uninstalled but binding remains and causes packet stalls.

```powershell
# Identify orphan
$bindings = Get-NetAdapterBinding | Where-Object {$_.Enabled -eq $true -and $_.ComponentID -notmatch "^ms_"}
$bindings | Format-Table Name, DisplayName, ComponentID, Enabled

# Disable the orphaned binding
foreach ($b in $bindings) {
    Write-Host "Disabling $($b.ComponentID) on $($b.Name)" -ForegroundColor Yellow
    Disable-NetAdapterBinding -Name $b.Name -ComponentID $b.ComponentID -Confirm:$false
}
Write-Host "Done. Test connectivity. Reboot if still degraded." -ForegroundColor Green
```

**Rollback:** Re-enable with `Enable-NetAdapterBinding -Name "<adapter>" -ComponentID "<ComponentID>"`. Reinstalling the original VPN client will also re-enable.

</details>

<details>
<summary>Fix 3 — Update or reinstall NIC driver</summary>

**When to use:** Driver-related crashes (Event ID 10317), intermittent drops after Windows Update, or new hardware not working.

```powershell
# Check current driver
Get-NetAdapter | Select-Object Name, DriverVersion, DriverDate, DriverDescription

# Update via PnP (will use Windows Update catalogue)
$adapter = Get-PnpDevice | Where-Object {$_.Class -eq "Net" -and $_.FriendlyName -like "*<NIC Name>*"}
Update-DeviceDriver -InputObject $adapter

# Manual INF install (if you have vendor driver package extracted)
# pnputil /add-driver "<path>\netxxx.inf" /install
```

**Rollback:** Device Manager → Network Adapters → Right-click → Properties → Driver tab → Roll Back Driver. Or: `pnputil /delete-driver <OEM##.inf>` to remove specific version.

</details>

<details>
<summary>Fix 4 — Fix LBFO teaming degraded member</summary>

**When to use:** Server NIC team shows degraded status; one member went down (patching, cable pull, switch port fault).

```powershell
# Check team and member status
Get-NetLbfoTeam | Select-Object Name, Status, TeamingMode, LoadBalancingAlgorithm
Get-NetLbfoTeamMember | Select-Object Name, Team, AdministrativeMode, OperationalStatus, Speed

# Re-add a removed member
Add-NetLbfoTeamMember -Name "<NIC Name>" -Team "<Team Name>"

# Force team recalculation
Set-NetLbfoTeam -Name "<Team Name>" -LoadBalancingAlgorithm Dynamic
```

**Rollback:** `Remove-NetLbfoTeamMember -Name "<NIC>" -Team "<Team>"` if member re-addition causes problems.

</details>

<details>
<summary>Fix 5 — Fix MTU / jumbo frame mismatch</summary>

**When to use:** High packet loss on large transfers, SMB/RDP works but file copies fail, ping with -f -l 1472 fails but small pings succeed.

```powershell
# Check current MTU per adapter
Get-NetIPInterface | Select-Object InterfaceAlias, NlMtu | Format-Table

# Detect MTU ceiling (run from affected host)
# Start at 1472 and reduce until ping succeeds (1472 + 28 IP/ICMP header = 1500)
1472, 1400, 1300, 1200 | ForEach-Object {
    $result = ping -f -l $_ 8.8.8.8 -n 1
    Write-Host "MTU $($_+28): $($result | Select-String 'Reply|Request')"
}

# Set MTU (adjust to discovered value, typically 1500 for LAN, 1420-1450 for VPN)
Set-NetIPInterface -InterfaceAlias "<adapter>" -NlMtuBytes 1500

# If jumbo frames needed on server (confirm switch supports it)
Set-NetAdapterAdvancedProperty -Name "<adapter>" -DisplayName "Jumbo Packet" -DisplayValue "9014 Bytes"
```

**Rollback:** `Set-NetIPInterface -InterfaceAlias "<adapter>" -NlMtuBytes 1500` to restore standard MTU. Disable jumbo frames: `Set-NetAdapterAdvancedProperty -Name "<adapter>" -DisplayName "Jumbo Packet" -DisplayValue "Disabled"`.

</details>

---

## Evidence Pack

```powershell
# Run as administrator — collects full adapter evidence for escalation
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$outputDir = "C:\Temp\NetAdapter-Evidence-$timestamp"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# Adapter state
Get-NetAdapter | Select-Object Name, Status, LinkSpeed, MediaType, DriverVersion, MacAddress |
    Export-Csv "$outputDir\adapters.csv" -NoTypeInformation

# IP configuration
Get-NetIPAddress | Where-Object {$_.AddressFamily -eq "IPv4"} |
    Export-Csv "$outputDir\ipaddresses.csv" -NoTypeInformation

# Routes
Get-NetRoute -AddressFamily IPv4 | Export-Csv "$outputDir\routes.csv" -NoTypeInformation

# NDIS bindings
Get-NetAdapterBinding | Export-Csv "$outputDir\bindings.csv" -NoTypeInformation

# Network profiles
Get-NetConnectionProfile | Export-Csv "$outputDir\profiles.csv" -NoTypeInformation

# Power management
Get-NetAdapterPowerManagement | Export-Csv "$outputDir\powermgmt.csv" -NoTypeInformation

# Event log — System, last 24h, network-related
$since = (Get-Date).AddHours(-24)
Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$since} -ErrorAction SilentlyContinue |
    Where-Object {$_.ProviderName -match "NDIS|tcpip|Dhcp|DNS|NlaSvc|netprofm"} |
    Select-Object TimeCreated, Id, ProviderName, Message |
    Export-Csv "$outputDir\events-network.csv" -NoTypeInformation

# ipconfig /all raw text
ipconfig /all > "$outputDir\ipconfig-all.txt"

# netstat
netstat -ano > "$outputDir\netstat.txt"

# Driver info
Get-WindowsDriver -Online | Where-Object {$_.OriginalFileName -like "*net*"} |
    Export-Csv "$outputDir\netdrivers.csv" -NoTypeInformation

Write-Host "Evidence collected at: $outputDir" -ForegroundColor Green
Compress-Archive -Path $outputDir -DestinationPath "C:\Temp\NetAdapter-Evidence-$timestamp.zip" -Force
Write-Host "Archive: C:\Temp\NetAdapter-Evidence-$timestamp.zip" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| List all adapters + status | `Get-NetAdapter` |
| Show IP addresses | `Get-NetIPAddress -AddressFamily IPv4` |
| Show default gateway | `Get-NetRoute -DestinationPrefix "0.0.0.0/0"` |
| Show DNS servers | `Get-DnsClientServerAddress` |
| Show NDIS bindings | `Get-NetAdapterBinding` |
| Show network profile | `Get-NetConnectionProfile` |
| Force DHCP renew | `ipconfig /release; ipconfig /renew` |
| Reset TCP/IP stack | `netsh int ip reset` |
| Reset Winsock | `netsh winsock reset` |
| Check NIC power management | `Get-NetAdapterPowerManagement` |
| Show NIC teams | `Get-NetLbfoTeam` |
| MTU discovery ping | `ping -f -l 1472 <target>` |
| View NIC driver details | `Get-PnpDevice -Class Net` |
| Disable adapter binding | `Disable-NetAdapterBinding -Name "<n>" -ComponentID "<id>"` |
| Test TCP port | `Test-NetConnection <host> -Port <port>` |

---

## 🎓 Learning Pointers

- **NDIS filter driver orphans** are one of the most common and least obvious causes of partial connectivity after VPN client upgrades or replacements. Always check `Get-NetAdapterBinding` after any VPN or security software change. See: [NDIS Filter Drivers (MS Docs)](https://learn.microsoft.com/en-us/windows-hardware/drivers/network/ndis-filter-drivers)

- **NLA misdetection** causes domain-joined machines to apply the Public firewall profile, blocking SMB, WMI, and RPC. The root cause is usually a transient DC unreachability at login time. The `nltest /dsgetdc` command is your first check. See: [Network Location Awareness (NLA)](https://learn.microsoft.com/en-us/windows/win32/winsock/network-location-awareness-service-provider-nsp--2)

- **MTU mismatches** are silent destroyers. They let ping succeed but kill large transfers. The "fragment-and-forget" behavior of some routers means ICMP "Fragmentation Needed" messages never reach the sender — so PMTUD fails. Always test with `ping -f -l 1472` before blaming application layer. See: [Path MTU Discovery (RFC 1191)](https://tools.ietf.org/html/rfc1191)

- **Jumbo frames require end-to-end agreement.** Every hop (NIC, switch, router, VM virtual switch) must support the same jumbo MTU. One non-jumbo hop silently drops frames. For Azure and Hyper-V, check the virtual switch and guest driver settings independently. See: [Jumbo Frames in Azure](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-tcpip-performance-tuning)

- **LBFO (NIC Teaming) is deprecated** in Windows Server 2022 and later. For new deployments, use Switch Embedded Teaming (SET) via Hyper-V virtual switch. See: [NIC Teaming in Windows Server](https://learn.microsoft.com/en-us/windows-server/networking/technologies/nic-teaming/nic-teaming)

- **Power management on server NICs** should always have "Allow the computer to turn off this device to save power" disabled. Windows Update sometimes resets this to enabled. Automate the check with `Get-NetAdapterPowerManagement`. See: [Network Adapter Power Settings](https://learn.microsoft.com/en-us/troubleshoot/windows-client/networking/power-management-of-network-adapter)
