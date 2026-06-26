# Azure Virtual Desktop — Network Connectivity Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the full AVD network path, why connections fail, and how to fix them at every layer.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How AVD Connectivity Works](#how-avd-connectivity-works)
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

This runbook covers AVD (Azure Virtual Desktop) network connectivity from the client device through to the session host VM. Applies to:

- AVD with both pooled and personal host pools
- Spring 2020 architecture (RDP Shortpath over UDP, reverse connect via Azure)
- Clients: Windows (native client), macOS, iOS, Android, web browser
- Host VMs: Windows 10/11 multi-session or single-session, Windows Server 2019/2022
- Network configurations: Public endpoint, Private endpoint, Azure Firewall, NSG-only

Does **not** cover: WVD legacy (Fall 2019 architecture), legacy RDS gateway, or Citrix/VMware overlays.

---

## How AVD Connectivity Works

<details><summary>Full architecture — the three network paths</summary>

AVD uses a **reverse connection** model. Session hosts **initiate outbound** to Azure AVD control plane; clients never connect directly to host IPs. This eliminates the need for inbound firewall rules to hosts.

```
CLIENT DEVICE
     │
     │ HTTPS/443 (control plane) or UDP 3478 (RDP Shortpath)
     ▼
AVD GATEWAY (*.wvd.microsoft.com)  ← in Azure globally-distributed
     │
     │ Reverse WebSocket tunnel
     ▼
AVD AGENT (running on Session Host)
     │ outbound 443 to *.wvd.microsoft.com
     ▼
SESSION HOST VM
     │ lives in customer VNet
     └─ domain-joined or Entra-joined
```

**Three transport modes (priority order):**

1. **RDP Shortpath (managed networks)** — UDP direct path from client to session host using STUN/TURN. Lowest latency, requires UDP 3478 from client network to host, and *.wvd.microsoft.com relay. Only for managed/corporate networks.

2. **RDP Shortpath (public networks)** — UDP path over public internet using STUN relay. Requires UDP 3478 outbound from host VNet. Available since 2022.

3. **Reverse Connect (TCP fallback)** — WebSocket over HTTPS 443 via AVD Gateway. Always available, higher latency. Used when UDP is blocked.

**Authentication flow:**
```
1. Client authenticates to Entra ID → receives access token
2. Client requests feed from AVD feed URL → gets workspace/app list
3. Client connects to AVD Gateway → WebSocket tunnel established
4. Gateway proxies connection to Session Host Agent
5. Session Host Agent starts RDP session for the user
6. If Shortpath available: UDP path negotiated in parallel, replaces TCP
```

**Key hostnames (all require HTTPS 443 outbound):**
- `*.wvd.microsoft.com` — AVD control plane (gateways, brokers, diagnostics)
- `*.servicebus.windows.net` — Service Bus relay for agent communication
- `login.microsoftonline.com` — Authentication
- `*.msftidentity.com`, `*.msidentity.com` — Identity services
- `*.blob.core.windows.net` — Agent updates, FSLogix profile storage
- `*.table.core.windows.net` — Telemetry
- `kms.core.windows.net:1688` — Windows activation (TCP 1688)
- `azkms.core.windows.net:1688` — Azure KMS fallback

</details>

---

## Dependency Stack

```
User Authentication (Entra ID)
        │
        ▼
AVD Feed Subscription (*.wvd.microsoft.com/api/arm)
        │
        ▼
AVD Gateway Connection (reverse-connect WebSocket / UDP 3478)
        │
        ▼
AVD Agent on Session Host (outbound 443 to *.wvd.microsoft.com)
        │
        ├── DNS Resolution (session host must resolve Azure endpoints)
        ├── NSG Rules (allow outbound 443 from host subnet)
        ├── Route Table / UDR (ensure traffic not blackholed)
        ├── Azure Firewall / NVA (FQDN rules for *.wvd.microsoft.com)
        └── Private Endpoint (if using private link: AVD workspace PE)
                │
                ▼
        RDP Session to Session Host
                │
                ├── FSLogix Profile (SMB 445 to storage account)
                ├── Domain Join health (Kerberos/LDAP to DC)
                └── Line-of-business app access (varies)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| "We couldn't connect to the remote PC" (0x3000047) | AVD Agent not registered / agent dead | `Get-Service RDAgent, RDAgentBootLoader` on host |
| Client can't see any resources in feed | Feed URL not reachable or Entra auth failure | `Invoke-WebRequest https://rdweb.wvd.microsoft.com` from client |
| Connection attempt times out (~2 min) | NSG blocks outbound 443 from host VNet | Check NSG effective rules on host NIC |
| Connection drops mid-session (30–90s) | UDP Shortpath MTU mismatch or ISP UDP block | `netstat -s` / Check `RDShortpathTransport` event log |
| "Authentication failed" (0x1400) | Conditional Access blocking AVD cloud app | Review sign-in logs in Entra → filter by "Windows Virtual Desktop" |
| "Resources unavailable" in client | Host pool at capacity (max sessions reached) | Check host pool load balancing + session count |
| Very high latency (>150ms RTT in session) | Using TCP reverse-connect; UDP blocked | Check for Shortpath events in event log (EventID 131) |
| Profile doesn't load / desktop partial | FSLogix can't reach storage SMB 445 | `Test-NetConnection <storageAcct>.file.core.windows.net -Port 445` |
| Black screen after login | GPU driver / display adapter issue or Entra token refresh | Check Event Viewer → System for GPU errors |
| "No healthy hosts available" | All hosts in drain mode or health check failing | Check host health in Azure Portal → Host Pools → Session Hosts |

---

## Validation Steps

### Step 1 — Verify AVD Agent services on session host
```powershell
Get-Service -Name "RDAgent", "RDAgentBootLoader" | Select-Object Name, Status, StartType
```
**Good:** Both `Running` with `Automatic` start.
**Bad:** Either stopped or `StartType = Disabled` → agent is broken, needs reinstall.

### Step 2 — Test outbound HTTPS from session host
```powershell
$endpoints = @(
    "rdbroker.wvd.microsoft.com",
    "rdweb.wvd.microsoft.com",
    "login.microsoftonline.com",
    "kms.core.windows.net"
)
foreach ($ep in $endpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{
        Endpoint = $ep
        Port443   = $result.TcpTestSucceeded
        Latency   = "$($result.PingReplyDetails.RoundtripTime)ms"
    }
} | Format-Table -AutoSize
```
**Good:** All `Port443 = True`.
**Bad:** Any `False` → NSG, firewall, or DNS blocking that endpoint.

### Step 3 — Check AVD Agent registration status
```powershell
# Run on session host
$reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\RDInfraAgent" -ErrorAction SilentlyContinue
[PSCustomObject]@{
    IsRegistered        = $reg.IsRegistered
    RegistrationToken   = if ($reg.RegistrationToken) { "Present" } else { "MISSING" }
    LastHeartbeat       = $reg.AgentLastHeartBeat
}
```
**Good:** `IsRegistered = 1`, token present or expired (hosts re-register on reboot).
**Bad:** `IsRegistered = 0` → host was never successfully registered. Check agent logs.

### Step 4 — Check RDP Shortpath status
```powershell
# Run on session host — check if Shortpath is enabled and receiving
Get-NetUDPEndpoint | Where-Object LocalPort -eq 3390 | Select-Object LocalAddress, LocalPort, OwningProcess
# Also check recent Shortpath events:
Get-WinEvent -LogName "Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational" |
    Where-Object Id -in 131, 140 | Select-Object TimeCreated, Id, Message -First 10
```
**Good:** Port 3390 listening (if Shortpath over managed network enabled); EventID 131 shows "Shortpath transport is UP".
**Bad:** No UDP listener; EventID 140 ("Shortpath is DOWN") → check firewall rules for UDP 3390 or 3478.

### Step 5 — Validate FSLogix connectivity from session host
```powershell
# Replace with your storage account name
$storageAccount = "<storageAccountName>"
Test-NetConnection -ComputerName "$storageAccount.file.core.windows.net" -Port 445
# Check if Azure Files is mounted correctly during session
Get-SmbMapping | Where-Object Status -ne "OK"
```
**Good:** `TcpTestSucceeded = True`, SMB mapping healthy.
**Bad:** Port 445 blocked → storage account private endpoint misconfigured, or NSG blocks 445 from host subnet.

### Step 6 — Check effective NSG rules on session host NIC
```powershell
# Run in Azure Cloud Shell or local Az module
$rg   = "<resourceGroupName>"
$vm   = "<sessionHostVMName>"
$nic  = (Get-AzVM -ResourceGroupName $rg -Name $vm).NetworkProfile.NetworkInterfaces[0].Id.Split("/")[-1]
Get-AzEffectiveNetworkSecurityGroup -NetworkInterfaceName $nic -ResourceGroupName $rg |
    Select-Object -ExpandProperty EffectiveSecurityRules |
    Where-Object Direction -eq Outbound |
    Format-Table Name, Priority, Access, SourcePortRange, DestinationAddressPrefix, DestinationPortRange -AutoSize
```
**Good:** Port 443 allowed outbound to `*` or `AzureCloud` service tag. No DENY rules above it.
**Bad:** Explicit DENY at lower priority number overriding the allow.

---

## Troubleshooting Steps by Phase

### Phase 1 — Client Can't See Feed / Authenticate

1. Confirm client is on a network that can reach `login.microsoftonline.com:443` and `rdweb.wvd.microsoft.com:443`.
2. Test from the client browser: navigate to `https://client.wvd.microsoft.com/arm/webclient/` and sign in.
3. If web client works but native client doesn't: check client version. Minimum: Windows Desktop client 1.2.3577 for full Shortpath support.
4. If both fail at auth: pull Entra sign-in logs filtered on application "Windows Virtual Desktop" — look for CA policy blocking.
5. Check if Conditional Access requires compliant device. If the client device isn't Intune-compliant → connection blocked at auth.

### Phase 2 — Session Host Not Appearing (Disconnected/Unavailable State)

1. In Azure Portal → AVD → Host Pools → Session Hosts: note status (Available/Unavailable/Needs Assistance).
2. `Unavailable` = heartbeat lost. RDP to host via Azure Bastion or Serial Console.
3. Check services: `Get-Service RDAgent, RDAgentBootLoader` — restart if stopped.
4. Check agent logs: `C:\Program Files\Microsoft RDInfra\AgentInstaller\*` and `C:\WindowsAzure\Logs\`.
5. If agent logs show `HostPool registration token expired`: generate a new token in Portal → Host Pool → Registration Key.

### Phase 3 — Connection Established but Session Drops

1. Check `Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational` event log on host.
   - EventID 140: Shortpath disconnected
   - EventID 65: RDP disconnect with reason code
2. Reason code 0 = client-initiated clean disconnect (not an error).
3. Reason code 5 (client connection replaced) = user reconnected elsewhere.
4. Reason code 11/12 = network drop. Check client ISP/WiFi stability.
5. If drops are periodic (~90s): check for Idle Session Timeout GPO — `Computer Configuration → Admin Templates → Windows Components → Remote Desktop Services → RD Session Host → Session Time Limits`.

### Phase 4 — High Latency / Poor Performance

1. From client: check reported latency in AVD client (Connection Information → Estimated round-trip time).
2. Latency >150ms during normal use: UDP Shortpath likely not in use.
3. On host: check EventID 131 for "ShortpathTransport: UP". If absent, Shortpath not established.
4. For managed network Shortpath: ensure UDP 3390 inbound to host from client VNet is allowed at NSG.
5. For public network Shortpath: ensure UDP 3478 outbound from host VNet to internet is allowed.
6. Use `qwinsta /server:<hostName>` to see session states — high session count on pooled host degrades performance.

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Reinstall AVD Agent on a broken session host</summary>

**When to use:** Agent services won't start, or host stuck in "Unavailable" after service restarts.

```powershell
# 1. Generate new registration token (Portal → Host Pool → Registration Keys → + New)
#    Copy the token — valid for 1 hour max.

# 2. On session host — stop agent services
Stop-Service -Name "RDAgent", "RDAgentBootLoader" -Force

# 3. Uninstall old agent (do NOT uninstall RD Agent Boot Loader first)
$rdAgent = Get-WmiObject -Class Win32_Product | Where-Object Name -like "Remote Desktop Agent*"
$rdBoot  = Get-WmiObject -Class Win32_Product | Where-Object Name -like "Remote Desktop Agent Boot*"
$rdAgent.Uninstall()
$rdBoot.Uninstall()

# 4. Download latest agent and bootloader from:
#    https://aka.ms/RDAgent_Installer   (Microsoft.RDInfra.RDAgent.Installer-x64.msi)
#    https://aka.ms/RDAgentBootLoader   (Microsoft.RDInfra.RDAgentBootLoader.Installer-x64.msi)
# Install boot loader first, then agent.
# During agent install, paste the registration token when prompted.

# 5. Verify registration
Start-Sleep -Seconds 30
Get-Service RDAgent, RDAgentBootLoader
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\RDInfraAgent").IsRegistered
```

**Rollback:** Not applicable (reinstall is the rollback). Session host can be removed from pool if needed: Portal → Host Pool → Session Hosts → [host] → Remove.

</details>

<details>
<summary>Fix 2 — Enable RDP Shortpath for public networks</summary>

**When to use:** Users experiencing high latency; Shortpath not established on public connections.

```powershell
# Deploy via Intune or GPO to session hosts
# Registry keys for RDP Shortpath (public network):

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations"

# Enable UDP transport
Set-ItemProperty -Path $regPath -Name "ICEControl" -Value 2 -Type DWord
# 0 = disabled, 1 = managed network only, 2 = public network enabled

# Ensure Session Host is listening on UDP
Set-ItemProperty -Path $regPath -Name "WRdsMediaAudioRedirAllowed" -Value 1 -Type DWord

# Open Windows Firewall for UDP 3390 (managed network Shortpath)
New-NetFirewallRule -DisplayName "AVD RDP Shortpath (UDP 3390)" `
    -Direction Inbound -Protocol UDP -LocalPort 3390 -Action Allow -Profile Any

# Also allow UDP 3478 outbound (STUN for public Shortpath) — typically already allowed
# If behind Azure Firewall, add FQDN rule: *.servicebus.windows.net:3478 UDP

# Validate after restart
Get-NetUDPEndpoint | Where-Object LocalPort -eq 3390
```

**Note:** Changes require RDAgent service restart or session host reboot to take effect.

</details>

<details>
<summary>Fix 3 — Fix NSG blocking AVD required endpoints</summary>

**When to use:** Session hosts show Unavailable; Test-NetConnection to wvd.microsoft.com fails.

```powershell
# Create NSG rule allowing outbound to Azure AVD endpoints
# Use the AzureVirtualDesktop service tag (includes all AVD IPs) and WindowsVirtualDesktop
$rg       = "<resourceGroupName>"
$nsgName  = "<nsgName>"

$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $rg -Name $nsgName

# Allow AVD control plane
$nsg | Add-AzNetworkSecurityRuleConfig `
    -Name "Allow-AVD-Outbound" `
    -Priority 100 `
    -Direction Outbound `
    -Access Allow `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -SourceAddressPrefix VirtualNetwork `
    -DestinationAddressPrefix AzureCloud `
    -DestinationPortRange 443

# Allow Windows activation (KMS)
$nsg | Add-AzNetworkSecurityRuleConfig `
    -Name "Allow-KMS-Outbound" `
    -Priority 110 `
    -Direction Outbound `
    -Access Allow `
    -Protocol Tcp `
    -SourcePortRange "*" `
    -SourceAddressPrefix VirtualNetwork `
    -DestinationAddressPrefix Internet `
    -DestinationPortRange 1688

$nsg | Set-AzNetworkSecurityGroup
```

**Note:** If using Azure Firewall, add application rules for all FQDN wildcards listed in the architecture section rather than IP-based NSG rules. FQDN rules are more future-proof as Microsoft may add IPs.

**Rollback:**
```powershell
$nsg | Remove-AzNetworkSecurityRuleConfig -Name "Allow-AVD-Outbound"
$nsg | Set-AzNetworkSecurityGroup
```

</details>

<details>
<summary>Fix 4 — Put session hosts in drain mode for maintenance without kicking users</summary>

**When to use:** Need to patch/restart hosts without user disruption.

```powershell
# Set drain mode — no new connections accepted, existing sessions continue
$rg        = "<resourceGroupName>"
$hostPool  = "<hostPoolName>"
$hostName  = "<sessionHostFQDN>"   # e.g. "avd-host-0.contoso.com"

Update-AzWvdSessionHost `
    -ResourceGroupName $rg `
    -HostPoolName $hostPool `
    -Name $hostName `
    -AllowNewSession:$false

# Check who's still logged in
Get-AzWvdUserSession -ResourceGroupName $rg -HostPoolName $hostPool -SessionHostName $hostName |
    Select-Object UserPrincipalName, SessionState, CreateTime

# When ready: send logoff message and force logoff
Get-AzWvdUserSession -ResourceGroupName $rg -HostPoolName $hostPool -SessionHostName $hostName |
    ForEach-Object {
        Send-AzWvdUserSessionMessage -ResourceGroupName $rg -HostPoolName $hostPool `
            -SessionHostName $hostName -UserSessionId $_.Name.Split("/")[-1] `
            -MessageTitle "Maintenance" `
            -MessageBody "Your session will end in 15 minutes for maintenance. Please save your work."
    }
```

**Re-enable after maintenance:**
```powershell
Update-AzWvdSessionHost -ResourceGroupName $rg -HostPoolName $hostPool -Name $hostName -AllowNewSession:$true
```

</details>

---

## Evidence Pack

Run this script on the session host when escalating to Microsoft Support or Azure team:

```powershell
<#
.SYNOPSIS
    Collects AVD connectivity diagnostics for escalation.
.NOTES
    Run as Administrator on the session host.
#>

$outputPath = "C:\Temp\AVD-Diag-$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

# Agent registration
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\RDInfraAgent" |
    Select-Object IsRegistered, SessionHostFQDN, AgentLastHeartBeat |
    Export-Csv "$outputPath\AgentReg.csv" -NoTypeInformation

# Services
Get-Service "RDAgent", "RDAgentBootLoader" |
    Select-Object Name, Status, StartType |
    Export-Csv "$outputPath\Services.csv" -NoTypeInformation

# Network connectivity tests
$endpoints = @(
    @{H="rdbroker.wvd.microsoft.com";P=443},
    @{H="rdweb.wvd.microsoft.com";P=443},
    @{H="login.microsoftonline.com";P=443},
    @{H="kms.core.windows.net";P=1688},
    @{H="*.servicebus.windows.net";P=443}  # Test with a known SB namespace if available
)
$results = foreach ($ep in $endpoints) {
    $r = Test-NetConnection -ComputerName $ep.H -Port $ep.P -WarningAction SilentlyContinue
    [PSCustomObject]@{
        Endpoint = $ep.H
        Port     = $ep.P
        Success  = $r.TcpTestSucceeded
        Latency  = $r.PingReplyDetails.RoundtripTime
    }
}
$results | Export-Csv "$outputPath\Connectivity.csv" -NoTypeInformation

# UDP Shortpath
Get-NetUDPEndpoint | Where-Object LocalPort -in 3390, 3478 |
    Export-Csv "$outputPath\UDPPorts.csv" -NoTypeInformation

# Recent RDP/AVD events (last 24h)
$since = (Get-Date).AddDays(-1)
Get-WinEvent -LogName "Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational" -ErrorAction SilentlyContinue |
    Where-Object TimeCreated -gt $since |
    Select-Object TimeCreated, Id, Message |
    Export-Csv "$outputPath\RDPEvents.csv" -NoTypeInformation

Get-WinEvent -LogName "Microsoft-Windows-RemoteDesktopServices-RdpCoreCDV/Operational" -ErrorAction SilentlyContinue |
    Where-Object TimeCreated -gt $since |
    Select-Object TimeCreated, Id, Message |
    Export-Csv "$outputPath\CDVEvents.csv" -NoTypeInformation

# AVD Agent log (last 500 lines)
$agentLog = "C:\Program Files\Microsoft RDInfra\AgentInstaller\AgentInstall.log"
if (Test-Path $agentLog) {
    Get-Content $agentLog -Tail 500 | Out-File "$outputPath\AgentInstall.log"
}

# System info
[PSCustomObject]@{
    Hostname     = $env:COMPUTERNAME
    OS           = (Get-WmiObject Win32_OperatingSystem).Caption
    LastBoot     = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    AVD_Agent    = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\RDInfraAgent" -ErrorAction SilentlyContinue).AgentVersion
} | Export-Csv "$outputPath\SystemInfo.csv" -NoTypeInformation

Write-Host "Evidence collected at: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check agent services | `Get-Service RDAgent, RDAgentBootLoader` |
| Restart agent services | `Restart-Service RDAgent, RDAgentBootLoader` |
| Check agent registration | `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent'` |
| Test AVD gateway reachability | `Test-NetConnection rdbroker.wvd.microsoft.com -Port 443` |
| List active sessions on host | `Get-AzWvdUserSession -ResourceGroupName <rg> -HostPoolName <pool> -SessionHostName <host>` |
| Set drain mode ON | `Update-AzWvdSessionHost ... -AllowNewSession:$false` |
| Set drain mode OFF | `Update-AzWvdSessionHost ... -AllowNewSession:$true` |
| List all session hosts in pool | `Get-AzWvdSessionHost -ResourceGroupName <rg> -HostPoolName <pool>` |
| Check Shortpath UDP listener | `Get-NetUDPEndpoint \| Where-Object LocalPort -eq 3390` |
| Test FSLogix SMB path | `Test-NetConnection <storage>.file.core.windows.net -Port 445` |
| View RDP disconnect events | `Get-WinEvent -LogName "Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational"` |
| Check effective NSG rules | `Get-AzEffectiveNetworkSecurityGroup -NetworkInterfaceName <nic> -ResourceGroupName <rg>` |
| Log off all sessions on host | `Get-AzWvdUserSession ... \| Remove-AzWvdUserSession` |
| Check Windows activation | `slmgr /dlv` |

---

## 🎓 Learning Pointers

- **Reverse connect fundamentals:** AVD hosts never require inbound firewall rules because they initiate outbound. If a customer's security team opens inbound ports to session hosts "for AVD," they are wrong and adding unnecessary attack surface. [MS Docs: AVD network architecture](https://learn.microsoft.com/en-us/azure/virtual-desktop/network-connectivity)

- **Service tags vs FQDNs:** NSG service tags (`AzureVirtualDesktop`, `AzureCloud`, `WindowsVirtualDesktop`) cover IP ranges and auto-update as Microsoft changes infra — far better than hardcoding IP ranges. For Azure Firewall, use FQDN-based application rules. [Required URLs for AVD](https://learn.microsoft.com/en-us/azure/virtual-desktop/safe-url-list)

- **RDP Shortpath impact:** Testing shows 40–60% latency reduction moving from TCP reverse-connect to UDP Shortpath. If users complain about sluggish response, check whether Shortpath is actually in use before touching VM size or region. EventID 131 in `RdpCoreTS/Operational` is your telltale. [RDP Shortpath overview](https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-shortpath)

- **Private endpoints and DNS:** If the AVD workspace uses a private endpoint, the session hosts must resolve `rdweb.wvd.microsoft.com` to the private IP (via private DNS zone `privatelink.wvd.microsoft.com`). Hosts that go through Azure-provided DNS or split-brain DNS misconfigured will hit the public endpoint and connection may fail depending on policy. Always verify DNS resolution from the host matches expected private vs. public IP.

- **Agent version matters:** AVD Agent is auto-updated by Microsoft, but stale agents (3+ months behind) can lose compatibility with gateway protocol changes. Check agent version with `(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent').AgentVersion` — anything older than what's in [the release notes](https://learn.microsoft.com/en-us/azure/virtual-desktop/whats-new-agent) warrants a reinstall.

- **Scaling plan drain-mode integration:** If the customer has AVD Scaling Plans configured, power-off actions send hosts into drain mode before deallocating. Make sure scaling plan hours and maintenance windows don't conflict — a scaling plan forcing shutdown during business hours will appear as random connectivity loss. [AVD Scaling Plans](https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-scenarios)
