# AVD Network Connectivity — Hotfix Runbook (Mode B: Ops)
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

Run these first — on the **AVD Session Host** or from the admin workstation with Azure PowerShell:

```powershell
# 1. Check AVD Agent health on the session host
$agentStatus = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RDInfra\RDAgent' -ErrorAction SilentlyContinue
Write-Host "AVD Agent version : $($agentStatus.Version)"
Get-Service RDAgentBootLoader | Select-Object Name, Status

# 2. Check session host registered with host pool
# (Run from admin machine with Az.DesktopVirtualization module)
Connect-AzAccount -TenantId <tenantId>
Get-AzWvdSessionHost -ResourceGroupName '<rg>' -HostPoolName '<hostpool>' |
    Select-Object Name, Status, LastHeartBeat, AllowNewSession | Format-Table -AutoSize

# 3. Check AVD outbound URL reachability from session host
$avdEndpoints = @(
    'rdbroker.wvd.microsoft.com',
    'rdweb.wvd.microsoft.com',
    'login.microsoftonline.com',
    'catalogartifact.azureedge.net',
    'gcs.prod.monitoring.core.windows.net'
)
foreach ($ep in $avdEndpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    Write-Host "$ep : $($result.TcpTestSucceeded)" -ForegroundColor $(if($result.TcpTestSucceeded){'Green'}else{'Red'})
}

# 4. Check Windows Event Log for AVD agent errors
Get-WinEvent -LogName 'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational' -MaxEvents 20 -ErrorAction SilentlyContinue |
    Where-Object {$_.Level -le 3} | Select-Object TimeCreated, Level, Message | Format-List
```

**Interpretation:**

| Finding | Do This |
|---------|---------|
| RDAgentBootLoader stopped | Start service, check why it stopped |
| Session host Status = Unavailable | Check agent version, re-register host |
| Any `rdbroker.wvd.microsoft.com` unreachable | NSG/firewall blocking outbound 443 — see Fix 2 |
| `login.microsoftonline.com` unreachable | DNS or proxy issue — AVD cannot authenticate |
| Session host LastHeartBeat > 5 min ago | Agent lost connectivity to control plane |
| Event log shows "No endpoints available" | Host pool drain mode on OR no hosts healthy |

---

## Dependency Cascade

<details><summary>What must be true for an AVD connection to succeed</summary>

```
User Client (RD Client / Browser)
        │
        ▼
  Azure AVD Gateway (public endpoint, port 443 WebSockets)
        │
        ▼
  AVD Broker (rdbroker.wvd.microsoft.com)
        │
        ▼
  Session Host VM (in Azure VNet)
        ├── RDAgentBootLoader service: RUNNING
        ├── RDAgent service: RUNNING
        ├── Outbound 443 to AVD control plane: OPEN
        ├── Outbound 443 to Azure monitoring: OPEN
        ├── Joined to domain (Hybrid) or Entra ID: VALID
        └── Not in drain mode: CONFIRMED
                │
                ▼
  Windows Logon on Session Host
        │
        ▼
  FSLogix Profile (if used) — must mount from storage account
        │
        ▼
  User Desktop / RemoteApp
```

Every layer must be healthy. The most common breaks are: NSG blocking outbound 443, agent service down, or FSLogix profile mount failure (see `FSLogix-B.md`).

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the error type from the user**

| User error | Points to |
|------------|-----------|
| "We can't connect to the session host" | Client → gateway path, or host unavailable |
| "Your session was disconnected" mid-session | Network interruption, idle timeout, or session host crash |
| "No resources available" | Host pool has no available session hosts |
| "Sign-in failed" | Authentication / Entra ID / MFA issue |
| "Loading virtual desktop…" hangs indefinitely | FSLogix profile not mounting, GPO applying slowly |

---

**Step 2 — Check session host status in host pool**

```powershell
# From admin machine
Get-AzWvdSessionHost -ResourceGroupName '<rg>' -HostPoolName '<hostpool>' |
    Select-Object Name, Status, UpdateState, LastHeartBeat, AllowNewSession, Sessions |
    Format-Table -AutoSize
```

Expected: `Status = Available`, `AllowNewSession = True`, heartbeat recent.

Bad outcomes:
- `Status = Unavailable` — agent health issue on VM
- `AllowNewSession = False` — drain mode is on
- `UpdateState = Pending` — Intune/MEM update in progress

---

**Step 3 — Verify AVD agent services on session host**

```powershell
# Run on session host (RDP or Azure Bastion)
$services = @('RDAgentBootLoader', 'RDAgent', 'WVDAgentMonitoringAgent', 'TermService')
$services | ForEach-Object {
    $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
    Write-Host "$_ : $(if($svc){$svc.Status}else{'NOT FOUND'})" `
        -ForegroundColor $(if($svc -and $svc.Status -eq 'Running'){'Green'} elseif($svc){'Yellow'} else{'Red'})
}
```

---

**Step 4 — Verify outbound connectivity from session host**

```powershell
# Required outbound URLs for AVD (all port 443)
$required = @(
    @{Host='rdbroker.wvd.microsoft.com'; Port=443},
    @{Host='rdweb.wvd.microsoft.com'; Port=443},
    @{Host='rdgateway.wvd.microsoft.com'; Port=443},
    @{Host='rddiagnostics.wvd.microsoft.com'; Port=443},
    @{Host='login.microsoftonline.com'; Port=443},
    @{Host='login.windows.net'; Port=443},
    @{Host='gcs.prod.monitoring.core.windows.net'; Port=443},
    @{Host='production.diagnostics.monitoring.core.windows.net'; Port=443}
)

$required | ForEach-Object {
    $r = Test-NetConnection -ComputerName $_.Host -Port $_.Port -WarningAction SilentlyContinue
    [PSCustomObject]@{
        Endpoint = $_.Host
        Port     = $_.Port
        Reachable = $r.TcpTestSucceeded
    }
} | Format-Table -AutoSize
```

---

**Step 5 — Check NSG rules on session host subnet**

```powershell
# From admin machine — check NSG for deny rules on outbound 443
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName '<rg>' -Name '<nsg-name>'
$nsg.SecurityRules | Where-Object {$_.Direction -eq 'Outbound' -and $_.Access -eq 'Deny'} |
    Select-Object Name, Priority, Protocol, DestinationPortRange, DestinationAddressPrefix |
    Sort-Object Priority | Format-Table -AutoSize
```

Look for any Deny rules with priority lower than Allow rules that might be catching port 443 to `WindowsVirtualDesktop` or `AzureCloud` service tags.

---

**Step 6 — Check drain mode**

```powershell
# Check if host pool or individual hosts are in drain mode
Get-AzWvdSessionHost -ResourceGroupName '<rg>' -HostPoolName '<hostpool>' |
    Select-Object Name, AllowNewSession | Format-Table

# Check host pool level drain mode (should be False normally)
Get-AzWvdHostPool -ResourceGroupName '<rg>' -Name '<hostpool>' |
    Select-Object Name, StartVMOnConnect, LoadBalancerType | Format-Table
```

---

## Common Fix Paths

<details><summary>Fix 1 — Restart AVD agent services (session host agent down)</summary>

Run on the **session host** (via Azure Bastion or emergency RDP):

```powershell
# Restart AVD agent stack in correct order
$services = @('WVDAgentMonitoringAgent', 'RDAgent', 'RDAgentBootLoader')

# Stop in reverse order
$services | ForEach-Object {
    $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-Host "Stopping $_..."
        Stop-Service $_ -Force
    }
}

Start-Sleep -Seconds 5

# Start in correct order
$services | Select-Object -Last 1 | ForEach-Object { Start-Service $_ }
Start-Sleep -Seconds 3
$services | Select-Object -SkipLast 1 | Sort-Object @{e={[Array]::IndexOf($services,$_)}} -Descending | ForEach-Object {
    Start-Service $_ -ErrorAction SilentlyContinue
}

# Verify
$services | ForEach-Object {
    $svc = Get-Service $_ -ErrorAction SilentlyContinue
    Write-Host "$_ : $($svc.Status)" -ForegroundColor $(if($svc.Status -eq 'Running'){'Green'}else{'Red'})
}
```

**Wait 2–3 minutes**, then check session host status in Intune/Azure portal — it should return to Available.

**Rollback:** N/A — service restart is non-destructive.

</details>

<details><summary>Fix 2 — Add NSG rule to allow AVD outbound traffic</summary>

Run from **admin machine** with Azure PowerShell:

```powershell
param(
    [string]$ResourceGroupName = '<rg>',
    [string]$NSGName = '<nsg-name>'
)

$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $NSGName

# Add outbound allow rule for AVD service tag
$ruleParams = @{
    Name                     = 'Allow-AVD-Outbound'
    Description              = 'Allow AVD session hosts to reach control plane'
    Access                   = 'Allow'
    Protocol                 = 'Tcp'
    Direction                = 'Outbound'
    Priority                 = 100
    SourceAddressPrefix      = 'VirtualNetwork'
    SourcePortRange          = '*'
    DestinationAddressPrefix = 'WindowsVirtualDesktop'
    DestinationPortRange     = '443'
}
$nsg | Add-AzNetworkSecurityRuleConfig @ruleParams | Set-AzNetworkSecurityGroup

# Also ensure AzureCloud is reachable for monitoring/auth
$ruleParams2 = @{
    Name                     = 'Allow-AzureCloud-Outbound'
    Description              = 'Allow AVD hosts to reach Azure monitoring and auth'
    Access                   = 'Allow'
    Protocol                 = 'Tcp'
    Direction                = 'Outbound'
    Priority                 = 110
    SourceAddressPrefix      = 'VirtualNetwork'
    SourcePortRange          = '*'
    DestinationAddressPrefix = 'AzureCloud'
    DestinationPortRange     = '443'
}
$nsg | Add-AzNetworkSecurityRuleConfig @ruleParams2 | Set-AzNetworkSecurityGroup

Write-Host "NSG rules added. Test connectivity from session host." -ForegroundColor Green
```

**Rollback:**
```powershell
Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $NSGName |
    Remove-AzNetworkSecurityRuleConfig -Name 'Allow-AVD-Outbound' |
    Remove-AzNetworkSecurityRuleConfig -Name 'Allow-AzureCloud-Outbound' |
    Set-AzNetworkSecurityGroup
```

</details>

<details><summary>Fix 3 — Disable drain mode on session host(s)</summary>

```powershell
param(
    [string]$ResourceGroupName = '<rg>',
    [string]$HostPoolName = '<hostpool>'
)

$hosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName |
    Where-Object {$_.AllowNewSession -eq $false}

if (-not $hosts) {
    Write-Host "No session hosts are in drain mode." -ForegroundColor Green
} else {
    Write-Host "Enabling new sessions on $($hosts.Count) host(s):"
    foreach ($h in $hosts) {
        $hostName = ($h.Name -split '/')[1]
        Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName `
            -HostPoolName $HostPoolName -Name $hostName -AllowNewSession:$true
        Write-Host "  Enabled: $hostName" -ForegroundColor Green
    }
}
```

**Note:** Drain mode is often set intentionally before maintenance. Confirm with the engineer who set it before re-enabling.

</details>

<details><summary>Fix 4 — Re-register session host with host pool</summary>

Use when: session host shows Unavailable and agent restart doesn't fix it. The registration token may have expired.

```powershell
# Step 1: Generate a new registration token (from admin machine)
$expiry = (Get-Date).AddHours(2).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$token = New-AzWvdRegistrationInfo -ResourceGroupName '<rg>' -HostPoolName '<hostpool>' -ExpirationTime $expiry
Write-Host "New registration token (copy this):"
Write-Host $token.Token -ForegroundColor Yellow

# Step 2: On the SESSION HOST — update the agent registration
# Run as Administrator on the session host:
$registrationToken = '<paste token here>'
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\RDInfra\RDAgent' `
    -Name 'RegistrationToken' -Value $registrationToken

# Restart agent to pick up new token
Restart-Service RDAgentBootLoader -Force
Start-Sleep -Seconds 5
Restart-Service RDAgent -Force

Write-Host "Agent re-registered. Check portal in 2-3 minutes for Available status."
```

**Note:** Registration tokens expire. Always generate a fresh token — do not reuse old ones.

</details>

---

## Escalation Evidence

```
TICKET ESCALATION — AVD CONNECTIVITY ISSUE
===========================================
Date/Time              : ___________
Affected users         : ___________
Host pool name         : ___________
Session host name(s)   : ___________
Error message shown    : ___________

AVD agent services status:
  RDAgentBootLoader    : ___________
  RDAgent              : ___________

Session host status in portal : ___________
Last heartbeat timestamp      : ___________
Drain mode status             : ___________

Outbound connectivity (port 443):
  rdbroker.wvd.microsoft.com  : ___________
  login.microsoftonline.com   : ___________

NSG deny rules blocking 443   : ___________
Proxy in use (if any)         : ___________

Event log errors:
  RemoteDesktopServices-RdpCoreTS: ___________
  System log (service failures)  : ___________

Attached: Test-NetConnection output, Get-AzWvdSessionHost output, agent event log export
Escalate to: Azure AVD / Infrastructure team
```

---

## 🎓 Learning Pointers

- **AVD uses reverse-connect — session hosts dial OUT to the gateway, not the other way.** This means you don't need inbound 3389 open on your NSG. All you need is outbound 443 to the `WindowsVirtualDesktop` and `AzureCloud` Azure service tags. If those are blocked, the session host can't register with the broker and users see "no resources available." [AVD required URL list](https://learn.microsoft.com/en-us/azure/virtual-desktop/safe-url-list)

- **The RDAgentBootLoader → RDAgent dependency chain must start in order.** RDAgentBootLoader is the parent; it starts RDAgent. If you try to start RDAgent without BootLoader being healthy, it will fail within seconds. Always restart BootLoader first, wait for it to stabilize, then check RDAgent.

- **Drain mode is intentional — check before overriding.** Hosts are put into drain mode during patching, maintenance, or scaling operations. Blindly re-enabling new sessions on a host that's mid-patch can result in users landing on a broken or rebooting VM. Always confirm with the team that set drain mode before re-enabling.

- **Registration tokens expire — stale tokens are a common cause of "Unavailable" hosts after a rebuild.** If you re-image a session host but don't re-register it, the old token is rejected by the broker. Generate a fresh token in the portal (valid for up to 27 days), copy it to the host, and restart the agent stack.

- **NSG Service Tags are the correct way to whitelist AVD.** Use `WindowsVirtualDesktop` and `AzureCloud` service tags in NSG outbound rules rather than IP ranges — Microsoft updates the IP addresses behind these tags automatically, so hardcoded IPs go stale. Service tag rules are self-maintaining. [AVD NSG guidance](https://learn.microsoft.com/en-us/azure/virtual-desktop/network-connectivity)
