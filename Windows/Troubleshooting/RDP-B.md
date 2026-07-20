# Remote Desktop Protocol (RDP) — Hotfix Runbook (Mode B: Ops)
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

Run these first. Results drive which fix path to take.

```powershell
# 1. Is RDP enabled on the target machine?
(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server").fDenyTSConnections
# 0 = RDP enabled | 1 = RDP disabled

# 2. Is TermService running?
Get-Service TermService | Select-Object Status
# Expected: Running

# 3. Is port 3389 listening?
Get-NetTCPConnection -LocalPort 3389 -ErrorAction SilentlyContinue | Select-Object LocalAddress, State
# Expected: LISTEN on 0.0.0.0 or ::

# 4. Is Windows Firewall allowing RDP?
Get-NetFirewallRule -DisplayName "*Remote Desktop*" | Select-Object DisplayName, Enabled, Direction, Action
# Expected: at least one Inbound Allow rule Enabled=True

# 5. NLA requirement check
(Get-WmiObject -Class Win32_TerminalServiceSetting -Namespace root\CIMv2\TerminalServices).UserAuthenticationRequired
# 0 = NLA not required | 1 = NLA required (Kerberos/NTLM credential needed before session)
```

| Result | Action |
|--------|--------|
| `fDenyTSConnections = 1` | → [Fix 1: Enable RDP](#fix-1--enable-rdp-via-registry) |
| TermService Stopped | → [Fix 2: Start TermService](#fix-2--start-termservice) |
| Port 3389 not listening | → Fix 1 or Fix 2 first, then recheck |
| Firewall rules Enabled=False | → [Fix 3: Open Firewall Rule](#fix-3--re-enable-rdp-firewall-rule) |
| NLA=1 + user has no valid cert/credential | → [Fix 5: Disable NLA temporarily](#fix-5--disable-nla-temporarily) |
| All checks pass, still can't connect | → [Fix 4: Check NSG / routing](#fix-4--verify-network-path) |

---

## Dependency Cascade

<details><summary>What must be true for RDP to work</summary>

```
CLIENT
    │  TCP 3389 (default) or custom port
    ▼
NETWORK PATH
    ├─ No NSG block (Azure VMs)
    ├─ No firewall/ACL between subnets
    └─ No port remapping on load balancer
    │
    ▼
TARGET HOST
    ├─ fDenyTSConnections = 0 (reg)
    ├─ TermService running (svchost)
    ├─ Port 3389 listening (netstat)
    ├─ Windows Firewall: Inbound TCP 3389 Allow
    │
    ▼
AUTHENTICATION
    ├─ NLA disabled → username/password prompted in session
    ├─ NLA enabled → Kerberos or NTLM pre-auth required
    │     ├─ Domain account → AD/Entra reachable
    │     └─ Local account → SAM on host
    │
    ▼
AUTHORISATION
    ├─ User in "Remote Desktop Users" local group OR is local admin
    └─ No RDS CAL limit hit (if RDS role installed)
```
</details>

---

## Diagnosis & Validation Flow

**Step 1 — Remote registry check (if you can't RDP but have another access path)**
```powershell
# If you have admin$ access or WinRM, check RDP state remotely
$computerName = "<TargetHostname>"
Invoke-Command -ComputerName $computerName -ScriptBlock {
    $rdpEnabled = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server").fDenyTSConnections
    $svc = (Get-Service TermService).Status
    $port = (Get-NetTCPConnection -LocalPort 3389 -ErrorAction SilentlyContinue).State
    [PSCustomObject]@{
        RDPEnabled  = ($rdpEnabled -eq 0)
        TermService = $svc
        Port3389    = if ($port) { $port } else { "NOT LISTENING" }
    }
}
```
Expected: `RDPEnabled=True, TermService=Running, Port3389=LISTEN`

**Step 2 — Test network connectivity from client**
```powershell
$target = "<TargetIP>"
Test-NetConnection -ComputerName $target -Port 3389
# TcpTestSucceeded = True → network path clear
# TcpTestSucceeded = False → firewall, NSG, or routing issue
```

**Step 3 — Check RDP event logs on the target**
```powershell
# Run on target (via PSRemoting or locally)
Get-WinEvent -LogName "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational" `
    -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message |
    Format-List
```

| Event ID | Meaning |
|----------|---------|
| 21 | Session logon succeeded |
| 23 | Session logoff |
| 24 | Session disconnected |
| 25 | Session reconnected |
| 40 | Session <n> has been disconnected, reason code <x> |
| 41 | Session <n> connection failed |

**Step 4 — Check Remote Desktop Users group**
```powershell
Get-LocalGroupMember -Group "Remote Desktop Users"
# If empty and user is not admin, they cannot RDP even if port is open
```

**Step 5 — Check concurrent session limit (RDS)**
```powershell
# On RDS hosts — check active + disconnected session count
query session /server:<hostname>
# If sessions are at the licensed limit, new connections fail with "no more connections"
```

---

## Common Fix Paths

<details><summary>Fix 1 — Enable RDP via registry</summary>

```powershell
# Run locally on target, or via PSRemoting / RMM
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" `
    -Name "fDenyTSConnections" -Value 0 -Type DWord

# Also ensure TermService set to Auto and running
Set-Service -Name TermService -StartupType Automatic
Start-Service -Name TermService

Write-Host "RDP enabled. Port 3389 should now be listening." -ForegroundColor Green

# Verify
Get-NetTCPConnection -LocalPort 3389 -ErrorAction SilentlyContinue | Select-Object State
```
**Rollback:** `Set-ItemProperty ... -Value 1` to disable again.
</details>

<details><summary>Fix 2 — Start TermService and set dependency services</summary>

```powershell
# TermService depends on: RpcSs (RPC), TermDD (kernel), UmRdpService (UI)
$services = @("RpcSs", "TermService", "UmRdpService")
foreach ($svc in $services) {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne 'Running') {
        Start-Service $svc
        Write-Host "Started: $svc" -ForegroundColor Green
    }
}
# If TermService fails to start, check Event Viewer → System log for Service Control Manager errors
```
</details>

<details><summary>Fix 3 — Re-enable RDP firewall rule</summary>

```powershell
# Enable built-in RDP firewall rules
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# Verify
Get-NetFirewallRule -DisplayGroup "Remote Desktop" | Select-Object DisplayName, Enabled, Direction
# Expected: both Inbound rules show Enabled=True

# If rules are missing entirely, recreate:
New-NetFirewallRule -DisplayName "Remote Desktop (TCP-In)" `
    -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow -Profile Any
```
**Note:** If a GPO is enforcing firewall state, the rule may re-disable itself on next refresh. Check GPO: `Computer Configuration > Windows Settings > Security Settings > Windows Firewall`.
</details>

<details><summary>Fix 4 — Verify network path (NSG / routing)</summary>

```powershell
# Azure VM — check NSG rules from the client side
# (Run in Azure Cloud Shell or Az PowerShell)
$vmName = "<VMName>"
$resourceGroup = "<ResourceGroup>"

# Check effective NSG rules
$nic = (Get-AzVM -Name $vmName -ResourceGroupName $resourceGroup).NetworkProfile.NetworkInterfaces[0].Id
$nicObj = Get-AzNetworkInterface -ResourceId $nic
$nsg = Get-AzNetworkSecurityGroup -Name $nicObj.NetworkSecurityGroup.Id.Split('/')[-1] `
    -ResourceGroupName $resourceGroup
$nsg.SecurityRules | Where-Object { $_.DestinationPortRange -contains "3389" -or $_.DestinationPortRange -eq "*" } |
    Select-Object Name, Priority, Direction, Access, SourceAddressPrefix, DestinationPortRange
```
Look for an **Inbound Allow rule for TCP 3389** with priority lower than any Deny rule. If missing, add:
```powershell
Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg `
    -Name "Allow-RDP" -Priority 300 -Direction Inbound -Access Allow `
    -Protocol Tcp -SourceAddressPrefix "<your-IP>/32" `
    -SourcePortRange "*" -DestinationAddressPrefix "*" -DestinationPortRange "3389"
Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg
```
</details>

<details><summary>Fix 5 — Disable NLA temporarily (for credential troubleshooting)</summary>

```powershell
# WARNING: Reduces pre-auth security. Use only for diagnostic isolation.
# Restore NLA immediately after confirming root cause.

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
Set-ItemProperty -Path $regPath -Name "UserAuthenticationRequired" -Value 0 -Type DWord
Write-Warning "NLA disabled. Re-enable after testing: Set-ItemProperty ... -Value 1"
```
If the user can now connect → the issue is credential/Kerberos related (stale ticket, expired password, domain connectivity). Fix the root cause then re-enable NLA.

**Rollback (re-enable NLA):**
```powershell
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -Name "UserAuthenticationRequired" -Value 1 -Type DWord
```
</details>

<details><summary>Fix 6 — Add user to Remote Desktop Users group</summary>

```powershell
$username = "<DOMAIN\Username>"
Add-LocalGroupMember -Group "Remote Desktop Users" -Member $username
Write-Host "$username added to Remote Desktop Users." -ForegroundColor Green

# Verify
Get-LocalGroupMember -Group "Remote Desktop Users"
```
**Note:** Domain Admins and local Administrators bypass this requirement.
</details>

---

## Escalation Evidence

```
TICKET ESCALATION — RDP CONNECTIVITY FAILURE
============================================
Date/Time:          ___________________
Affected Host:      ___________________
Client trying to connect from: ___________________
Environment:        [ ] On-premises  [ ] Azure VM  [ ] AVD  [ ] RDS Farm

CHECKS COMPLETED:
fDenyTSConnections value:   ___   (0=enabled, 1=disabled)
TermService status:          ___   (Running/Stopped)
Port 3389 listening:         ___   (Yes/No)
Firewall RDP rule enabled:   ___   (Yes/No)
Test-NetConnection result:   ___   (TcpTestSucceeded True/False)
NLA setting:                 ___   (0=disabled, 1=enabled)
User in RDP Users group:     ___   (Yes/No)
NSG allows 3389:             ___   (Yes/No/N/A)

RELEVANT EVENT LOG ENTRIES:
(paste output of Get-WinEvent -LogName "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational" -MaxEvents 10)

___________________________________________

ERROR MESSAGE ON CLIENT:
___________________________________________

FIXES ATTEMPTED:
___________________________________________

SCREENSHOT OF ERROR: [ ] Attached
```

---

## 🎓 Learning Pointers

- **NLA is authentication, not encryption:** Network Level Authentication means the client must supply credentials *before* the remote desktop session is established. This protects the host from unauthenticated access but requires the client to have a valid Kerberos ticket or NTLM credential. Disabling it doesn't disable encryption — RDP still uses TLS. [MS Docs: NLA](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/clients/remote-desktop-allow-access)
- **TermService vs RDS role:** The `TermService` (Remote Desktop Services) service is present on every Windows machine and enables 1-2 concurrent admin sessions. Installing the full Remote Desktop Session Host (RDSH) role enables more concurrent user sessions but requires RDS CALs. Mixing these up causes "no more connections" errors that look like network issues.
- **Azure VM RDP via Bastion:** If NSG rules are blocking port 3389 for security, Azure Bastion provides browser-based RDP/SSH over HTTPS (port 443). Preferred over opening 3389 to the internet — see `Azure/Networking/Bastion-A.md`/`Bastion-B.md` for deployment, SKU selection, and its own required NSG rule set. [Azure Bastion](https://learn.microsoft.com/en-us/azure/bastion/bastion-overview)
- **Reason codes in Event 40:** The disconnect reason code in Event ID 40 maps to documented values — e.g., code 5 = "The client's connection was replaced by another connection" (shadowing), code 11 = "The user activity has initiated the disconnect". These codes are documented in the [RDP reason codes reference](https://learn.microsoft.com/en-us/windows/win32/termserv/extended-disconnect-reason-codes).
- **Port 3389 hijacking:** If port 3389 shows as listening but RDP connections still fail with "connection refused", check that the listening process is actually `svchost.exe` hosting TermService and not malware: `Get-NetTCPConnection -LocalPort 3389 | ForEach-Object { Get-Process -Id $_.OwningProcess }`.
