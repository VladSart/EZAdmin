# Windows Firewall — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the WFP architecture, policy precedence, and advanced diagnostic techniques.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How Windows Firewall Works](#how-windows-firewall-works)
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

Covers Windows Defender Firewall (also called Windows Filtering Platform firewall) on:
- Windows 10 21H2+ / Windows 11
- Windows Server 2019 / 2022
- Managed via: Local policy, Group Policy (GPO), Microsoft Intune (MDM), or combinations of all three

Does **not** cover: third-party firewalls (Symantec, Sophos host-based), Azure NSGs, or Palo Alto/Cisco ASA perimeter firewalls. For Intune Endpoint Security firewall policy conflicts with MDE, see `Security/Defender/`.

---

## How Windows Firewall Works

<details><summary>Full architecture — WFP, BFE, profiles, rule stores</summary>

Windows Firewall is a **stateful, host-based packet filter** implemented via the **Windows Filtering Platform (WFP)**, a kernel-mode framework introduced in Vista/2008.

```
USER MODE
┌──────────────────────────────────────────────────────────┐
│  wf.msc / PowerShell / netsh / Intune / GPO             │
│        │ write rules via WFAS API                        │
│        ▼                                                  │
│  Windows Defender Firewall service (mpssvc)              │
│  - Reads rules from policy stores                        │
│  - Translates to WFP callout/filter objects              │
│  - Manages profile state                                 │
│        │                                                  │
│  Base Filtering Engine (BFE) — svchost                   │
│  - Manages the WFP filter database                       │
│  - Arbitrates rule precedence                            │
│  - Enforces policy stores ordering                       │
└──────────────────────────────────────────────────────────┘
           │ kernel transition via IOCTL
KERNEL MODE
┌──────────────────────────────────────────────────────────┐
│  Windows Filtering Platform (WFP)                        │
│  - 56+ filter layers (INBOUND/OUTBOUND × transport layer)│
│  - Each packet matched against all filters at each layer │
│  - First matching BLOCK wins; PERMIT requires no BLOCK   │
│  - TCP stateful tracking (connection state table)        │
└──────────────────────────────────────────────────────────┘
```

**Policy stores and precedence (highest wins):**

```
1. Group Policy Store (enforced GPO)        ← highest precedence
   HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall
   
2. MDM / Intune Store                       ← second (via MDM bridge)
   ./Vendor/MSFT/Firewall CSP
   
3. Local Policy Store                       ← user-editable rules
   HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy
   
4. Default / Boot-time rules               ← lowest; always present
```

**Network profiles:**
Windows assigns each network interface a profile based on NLA (Network Location Awareness):
- **Domain** — NLA detects that the machine is authenticated to a domain DC on this interface.
- **Private** — User-classified trusted network (home/office without domain).
- **Public** — Default for unrecognized networks. Most restrictive.

Each profile has its own: Enabled/Disabled state, Default Inbound/Outbound actions, and applicable firewall rule set. Rules can apply to one, two, or all three profiles.

**Rule evaluation order within a store:**
```
1. If ANY rule matches with Action=Block → packet dropped
2. If ANY rule matches with Action=Allow → packet permitted
3. If NO rule matches → Default Action for profile (typically Block Inbound)
```
"Block" beats "Allow" within the same store. More specific rules don't auto-beat less specific ones — all rules are evaluated, and a block anywhere wins.

**Common third-party WFP consumers that modify firewall behaviour:**
- Microsoft Defender Antivirus (callout for AMSI network inspection)
- Microsoft Defender for Endpoint (callout for NIP/network inspection)
- Windows Defender Credential Guard
- Azure VPN client / Always On VPN (adds interface-specific filters)
- Some EDR/EPP vendors

</details>

---

## Dependency Stack

```
Network Location Awareness (NlaSvc)
        │ classifies interface → Domain/Private/Public
        ▼
Base Filtering Engine (BFE)
        │ manages WFP filter database
        ▼
Windows Firewall (mpssvc)
        │
        ├── Group Policy Firewall Rules (highest precedence)
        │       └── delivered via GPMC → SYSVOL → secedit on client
        ├── Intune Firewall Policy (MDM CSP)
        │       └── delivered via DMClient → MDM bridge → mpssvc
        ├── Local Policy Rules (wf.msc / PowerShell)
        └── Built-in default rules
                │
                ▼
        Per-profile effective rule set
                │
                ├── Inbound rules
                ├── Outbound rules
                └── IPsec connection security rules (separate)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-----------------|-------|
| Application can't receive connections; port not responding | Missing or disabled inbound allow rule | `Get-NetFirewallRule -Direction Inbound -Action Allow` for the port |
| Application was working; stopped after GPO or Intune policy push | New block rule deployed | `Get-NetFirewallRule -PolicyStore RSOP -Action Block` |
| Firewall reports enabled but traffic still blocked outbound | Explicit outbound block rule exists | `Get-NetFirewallRule -Direction Outbound -Action Block -Enabled True` |
| `mpssvc` service fails to start | BFE stopped, or WFP driver corrupt | `Get-Service BFE`; run `sfc /scannow` |
| Machine shows as `Public` profile on a domain network | NLA couldn't contact DC; domain detection failed | `Test-NetConnection <DC> -Port 389`; check NlaSvc |
| Firewall rules applied but no effect on traffic | Third-party WFP callout overriding rules | `netsh wfp show filters` — look for third-party callouts |
| Ping blocked even with ICMP allow rule | Wrong ICMP type/code in rule, or IPv4 vs IPv6 mismatch | Check rule for `Protocol = ICMPv4`, type 8 (echo request) |
| Firewall causing Kerberos failures (port 88/389/445 blocked) | Overly strict outbound policy | Add allow rules for DC ports; check `Get-NetFirewallRule -Direction Outbound -Action Block` |
| Inconsistent behaviour across machines | Mixed policy sources — some machines getting GPO, others Intune | Check `Get-NetFirewallRule -PolicyStore RSOP` on affected vs healthy machines |

---

## Validation Steps

### Step 1 — Verify all dependent services
```powershell
$services = @("BFE", "mpssvc", "NlaSvc")
Get-Service -Name $services | Select-Object Name, Status, StartType |
    ForEach-Object {
        $colour = if ($_.Status -eq "Running") { "Green" } else { "Red" }
        Write-Host "[$($_.Status)] $($_.Name) - StartType: $($_.StartType)" -ForegroundColor $colour
    }
```
**Good:** All three Running. BFE and mpssvc Automatic.
**Bad:** Any stopped → fix service dependency chain before diagnosing rules.

### Step 2 — Check active profile on all interfaces
```powershell
Get-NetConnectionProfile | Select-Object InterfaceAlias, NetworkCategory, IPv4Connectivity, IPv6Connectivity
```
**Good:** Domain machine shows `DomainAuthenticated` on the LAN interface.
**Bad:** Shows `Public` on LAN → NLA failure; fix domain connectivity first (see `EntraID/Troubleshooting/HybridJoin-A.md` for domain detection issues).

### Step 3 — Dump the RSOP merged firewall rule set
```powershell
# This shows the effective rule set after all policy stores are merged
$rules = Get-NetFirewallRule -PolicyStore "RSOP" | Where-Object Enabled -eq True
$rules | Select-Object DisplayName, Direction, Action, Profile, PolicyStoreSourceType |
    Sort-Object Direction, Action | Format-Table -AutoSize
```
**Good:** Only expected allow rules for Direction=Inbound; minimal outbound blocks.
**Bad:** Unexpected Block rules — trace `PolicyStoreSourceType` to find the source GPO/Intune policy.

### Step 4 — Test specific port/protocol reachability
```powershell
# From the client machine trying to connect:
Test-NetConnection -ComputerName <targetHostname> -Port <port>

# From the server side — is the firewall dropping or is the service not listening?
# If TcpTestSucceeded = False, check whether port is even open:
netstat -ano | findstr :<port>   # on the server
# If netstat shows the port, traffic is being dropped before reaching it
```
**Good:** `TcpTestSucceeded = True`.
**Bad:** False — then check whether it's firewall (port closed, service listening) or service not listening.

### Step 5 — Enable and read drop audit events
```powershell
# Enable packet drop auditing (run once as admin)
auditpol /set /subcategory:"Filtering Platform Packet Drop" /success:enable /failure:enable
auditpol /set /subcategory:"Filtering Platform Connection" /success:enable /failure:enable

# View recent drops (EventID 5157 = connection blocked)
Get-WinEvent -LogName "Security" -FilterXPath "*[System[EventID=5157]]" -MaxEvents 30 -ErrorAction SilentlyContinue |
    ForEach-Object {
        $xml = [xml]$_.ToXml()
        $data = $xml.Event.EventData.Data
        [PSCustomObject]@{
            Time          = $_.TimeCreated
            SourceIP      = ($data | Where-Object Name -eq "SourceAddress")."#text"
            SourcePort    = ($data | Where-Object Name -eq "SourcePort")."#text"
            DestIP        = ($data | Where-Object Name -eq "DestAddress")."#text"
            DestPort      = ($data | Where-Object Name -eq "DestPort")."#text"
            Protocol      = ($data | Where-Object Name -eq "Protocol")."#text"
            FilterOrigin  = ($data | Where-Object Name -eq "FilterOrigin")."#text"
        }
    } | Format-Table -AutoSize
```
**Good:** No drops matching the suspected traffic.
**Bad:** Drops found with `FilterOrigin` pointing to a named rule → that rule is the culprit.

### Step 6 — Inspect WFP filters directly (low-level)
```powershell
# Dump WFP filter XML — extremely detailed; look for unexpected callouts
netsh wfp show filters file="C:\Temp\wfp-filters.xml"
# Then open the XML and search for the port or IP in question
```
**Good:** No unexpected third-party callout blocking the traffic.
**Bad:** EDR/AV vendor callout blocking before mpssvc rules even evaluated.

---

## Troubleshooting Steps by Phase

### Phase 1 — Service and Platform Issues

1. Start with BFE: `Get-Service BFE`. If stopped, the whole firewall stack is offline.
2. Attempt `Start-Service BFE, mpssvc`. If BFE fails: run `sfc /scannow` and `DISM /Online /Cleanup-Image /RestoreHealth` — WFP kernel driver may be corrupt.
3. If services start but rules don't apply: check WFP filter database: `netsh wfp show state file=C:\Temp\wfp-state.xml`. A large number of orphaned filters (10,000+) from a previous third-party security product can cause performance issues.
4. Reboot resolves many transient WFP corruption states — if feasible, try this early.

### Phase 2 — Rule Misconfiguration

1. Identify the affected traffic: protocol, source IP, destination IP, port, direction.
2. Search all policy stores for matching block rules:
   ```powershell
   Get-NetFirewallRule -PolicyStore RSOP -Direction Inbound -Action Block -Enabled True |
       ForEach-Object { $_ | Get-NetFirewallPortFilter } | Where-Object LocalPort -eq <port>
   ```
3. If block rule found in `GroupPolicy` or `MDM` store: escalate to the team managing that policy (usually IT/GPO admins or Intune team). Local override won't work.
4. If block rule is `Local` store: remove it or create a higher-priority allow rule.
5. Check rule profile scope: a rule only applies when the interface is in the matching profile. `Profile = Domain` rules are silently ignored on Public interfaces.

### Phase 3 — Network Profile (NLA) Issues

1. A machine showing `Public` profile on what should be a domain network is a very common cause of "firewall broke suddenly" tickets. Usually caused by DC being unreachable at login time or via NLA.
2. Check: `Test-NetConnection -ComputerName <DC-hostname> -Port 389`. If this fails, NLA can't detect the domain.
3. Fixes in order of preference:
   - Fix the DC connectivity (routing, DNS, VLAN)
   - Set the interface category manually (PowerShell, temporary): `Set-NetConnectionProfile -InterfaceAlias "Ethernet" -NetworkCategory DomainAuthenticated` — this only persists until next reboot/reconnect
   - Configure the firewall rule to apply to `Public` profile as well (less secure but may unblock immediately)

### Phase 4 — Intune and GPO Policy Conflicts

1. Use `Get-NetFirewallRule -PolicyStore RSOP | Where-Object PolicyStoreSourceType -ne "Local"` to identify non-local rules.
2. `PolicyStoreSourceType = GroupPolicy` → look in GPMC for policies applying to that OU.
3. `PolicyStoreSourceType = MDM` → look in Intune → Endpoint Security → Firewall profiles.
4. If both GPO and Intune are managing firewall: this is a known conflict zone. Intune recommends not mixing MDM and GPO for firewall management. [Intune + GPO firewall interop docs](https://learn.microsoft.com/en-us/mem/intune/protect/endpoint-security-firewall-policy#use-endpoint-security-firewall-policy-with-group-policy-configured-firewall-settings)
5. Resolution: pick one management plane. Usually GPO wins if `HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall` keys exist; Intune policies don't override enforced GPO.

---

## Remediation Playbooks

<details>
<summary>Fix 1 — Repair corrupt WFP/BFE state</summary>

**When to use:** BFE or mpssvc won't start; WFP state appears corrupt; sfc/DISM needed.

```powershell
# Step 1 — Run system file checker
sfc /scannow

# Step 2 — DISM component store repair
DISM /Online /Cleanup-Image /RestoreHealth

# Step 3 — Reset firewall to defaults
netsh advfirewall reset

# Step 4 — Re-register WFP kernel driver
sc.exe config BFE start= auto
sc.exe config mpssvc start= demand

# Step 5 — Reboot (required for WFP driver reload)
# Restart-Computer -Force  # remove comment to execute

# Step 6 — Post-reboot: start services
Start-Service BFE
Start-Service mpssvc
```

**Rollback:** Reboot to prior restore point if available. WFP corruption rarely has a non-reboot rollback.

</details>

<details>
<summary>Fix 2 — Bulk create required allow rules via PowerShell</summary>

**When to use:** A new policy (Intune/GPO) blocked many ports; need to quickly restore business-critical allows.

```powershell
# Define the rules you need to allow (customise this array)
$rulesToCreate = @(
    @{ Name = "Allow SMB Inbound";      Port = 445;  Proto = "TCP"; Dir = "Inbound" },
    @{ Name = "Allow Kerberos Inbound"; Port = 88;   Proto = "TCP"; Dir = "Inbound" },
    @{ Name = "Allow LDAP Inbound";     Port = 389;  Proto = "TCP"; Dir = "Inbound" },
    @{ Name = "Allow RDP Inbound";      Port = 3389; Proto = "TCP"; Dir = "Inbound" },
    @{ Name = "Allow WinRM Inbound";    Port = 5985; Proto = "TCP"; Dir = "Inbound" }
)

foreach ($rule in $rulesToCreate) {
    $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule `
            -DisplayName $rule.Name `
            -Direction $rule.Dir `
            -Protocol $rule.Proto `
            -LocalPort $rule.Port `
            -Action Allow `
            -Profile Domain, Private `
            -Enabled True
        Write-Host "Created: $($rule.Name)" -ForegroundColor Green
    } else {
        Write-Host "Already exists: $($rule.Name)" -ForegroundColor Yellow
    }
}
```

**Rollback:**
```powershell
$rulesToCreate | ForEach-Object { Remove-NetFirewallRule -DisplayName $_.Name -ErrorAction SilentlyContinue }
```

</details>

<details>
<summary>Fix 3 — Export, audit, and clean up firewall rules</summary>

**When to use:** Rule set has grown unmanageably; duplicate or conflicting rules suspected.

```powershell
# Export current rules for audit
$exportPath = "C:\Temp\FW-Audit-$(Get-Date -Format yyyyMMdd)"
New-Item -ItemType Directory -Path $exportPath -Force | Out-Null

# Export to wfw backup
netsh advfirewall export "$exportPath\firewall-backup.wfw"

# Export all rules to CSV for analysis
Get-NetFirewallRule | ForEach-Object {
    $portFilter = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    $appFilter  = $_ | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        Name        = $_.DisplayName
        Enabled     = $_.Enabled
        Direction   = $_.Direction
        Action      = $_.Action
        Profile     = $_.Profile
        Protocol    = $portFilter.Protocol
        LocalPort   = $portFilter.LocalPort
        RemotePort  = $portFilter.RemotePort
        Program     = $appFilter.Program
        PolicyStore = $_.PolicyStoreSourceType
    }
} | Export-Csv "$exportPath\all-rules.csv" -NoTypeInformation

# Find duplicate rules (same port/direction/action)
Import-Csv "$exportPath\all-rules.csv" |
    Group-Object LocalPort, Direction, Action |
    Where-Object Count -gt 1 |
    Select-Object Count, Name |
    Sort-Object Count -Descending

Write-Host "Audit exported to $exportPath" -ForegroundColor Green
```

</details>

<details>
<summary>Fix 4 — Configure Windows Firewall Logging for packet analysis</summary>

**When to use:** Cannot determine what's dropping traffic; need raw packet log.

```powershell
# Enable Windows Firewall's built-in log (separate from Security event log)
# This logs ALL drops and optionally allowed connections
$logPath = "C:\Temp\pfirewall.log"

Set-NetFirewallProfile -Profile Domain -LogFileName $logPath `
    -LogBlocked True -LogAllowed True -LogMaxSizeKilobytes 32768

# Wait for traffic to reproduce the issue, then parse the log
# Log format: date time action protocol src-ip dst-ip src-port dst-port ...
Select-String -Path $logPath -Pattern "DROP" | Select-Object -Last 50
```

**Disable logging when done (logs can get large):**
```powershell
Set-NetFirewallProfile -Profile Domain -LogBlocked False -LogAllowed False
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Windows Firewall diagnostics for escalation.
.NOTES
    Run as Administrator. Collects: services, profiles, rules, events, WFP state.
#>

$out = "C:\Temp\FW-Diag-$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $out -Force | Out-Null

# Services
Get-Service BFE, mpssvc, NlaSvc | Select-Object Name, Status, StartType |
    Export-Csv "$out\Services.csv" -NoTypeInformation

# Profiles
Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction, LogFileName, LogBlocked |
    Export-Csv "$out\Profiles.csv" -NoTypeInformation

# Active network profiles
Get-NetConnectionProfile | Select-Object InterfaceAlias, NetworkCategory, IPv4Connectivity |
    Export-Csv "$out\NetworkProfiles.csv" -NoTypeInformation

# All RSOP rules (effective merged set)
Get-NetFirewallRule -PolicyStore RSOP |
    Select-Object DisplayName, Direction, Action, Enabled, Profile, PolicyStoreSourceType |
    Export-Csv "$out\RSoP-Rules.csv" -NoTypeInformation

# Recent drop events
Get-WinEvent -LogName "Security" -FilterXPath "*[System[EventID=5157]]" -MaxEvents 100 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Message |
    Export-Csv "$out\DropEvents.csv" -NoTypeInformation

# WFP state (verbose; XML)
netsh wfp show state file="$out\wfp-state.xml" 2>&1 | Out-Null

# Export rules backup
netsh advfirewall export "$out\firewall.wfw" 2>&1 | Out-Null

# System info
[PSCustomObject]@{
    Hostname  = $env:COMPUTERNAME
    OS        = (Get-WmiObject Win32_OperatingSystem).Caption
    LastBoot  = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
} | Export-Csv "$out\SystemInfo.csv" -NoTypeInformation

Write-Host "Evidence at: $out" -ForegroundColor Green
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Archive: $out.zip" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check firewall service | `Get-Service mpssvc, BFE` |
| Check active profiles | `Get-NetConnectionProfile` |
| Get firewall profile state | `Get-NetFirewallProfile` |
| Enable all profiles | `Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True` |
| List all enabled block rules | `Get-NetFirewallRule -Enabled True -Action Block` |
| List effective rules (RSOP) | `Get-NetFirewallRule -PolicyStore RSOP` |
| Create allow rule (port) | `New-NetFirewallRule -DisplayName "..." -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow` |
| Remove rule | `Remove-NetFirewallRule -DisplayName "..."` |
| Export all rules | `netsh advfirewall export "C:\backup.wfw"` |
| Import rules | `netsh advfirewall import "C:\backup.wfw"` |
| Reset all rules to default | `netsh advfirewall reset` |
| Enable drop auditing | `auditpol /set /subcategory:"Filtering Platform Packet Drop" /failure:enable` |
| View drop events | `Get-WinEvent -LogName Security -FilterXPath "*[System[EventID=5157]]" -MaxEvents 20` |
| Enable firewall logging | `Set-NetFirewallProfile -Profile Domain -LogBlocked True -LogMaxSizeKilobytes 32768` |
| Show WFP filters | `netsh wfp show filters file=C:\filters.xml` |
| Show WFP state | `netsh wfp show state file=C:\state.xml` |

---

## 🎓 Learning Pointers

- **WFP is more than firewall:** The Windows Filtering Platform is used by IPsec, QoS, Windows Hello network validation, Always On VPN, and many EDR/AV products. Corrupting WFP (e.g. incomplete third-party security product uninstall) can cause mysterious failures in all of these, not just firewall rules. Always check `netsh wfp show state` when things behave strangely after software changes. [WFP overview](https://learn.microsoft.com/en-us/windows/win32/fwp/windows-filtering-platform-start-page)

- **Policy store precedence is absolute:** The Group Policy store always wins over local. Engineers sometimes spend hours creating PowerShell firewall rules that have zero effect because a GPO is enforcing the opposite. `PolicyStoreSourceType` in `Get-NetFirewallRule` output tells you exactly who owns each rule. Never trust `wf.msc` alone — it can hide GPO-sourced rules depending on the view.

- **Network profile classification drives everything:** NLA uses a domain DC ping and LDAP query at login to classify the interface. VPN-connected machines that can't reach the DC over VPN early in login may permanently sit in Public profile for that session. Fix the DC connectivity window, not just the firewall. GPO `Computer Configuration → Policies → Administrative Templates → Network → Network Connections → Windows Firewall → Domain Profile → "Windows Firewall: Allow inbound exceptions"` can help in hybrid scenarios.

- **Stateful vs stateless:** Windows Firewall is stateful for TCP. An inbound allow rule for port 443 is not needed for an outbound-initiated connection — the stateful table tracks the response. Engineers often create redundant inbound rules for client-side apps that initiate outbound. The key question is: who initiates the connection?

- **Intune firewall policy merges with GPO — with caveats:** Intune Endpoint Security firewall rules apply via MDM CSP. They merge with local rules. But if GPO enforces the firewall profile and includes block rules, those take priority. Microsoft's stance is to use one management channel. In MSP environments where customers have their own GPO and you're also managing Intune, audit for conflicts. [Firewall CSP docs](https://learn.microsoft.com/en-us/windows/client-management/mdm/firewall-csp)

- **Audit logging performance impact:** Enabling Security audit events 5157 (Filtering Platform Packet Drop) on a busy server can generate thousands of events per minute and fill the Security log. Set a maximum log size and auto-overwrite policy, or better: use Windows Firewall's own log file (`Set-NetFirewallProfile -LogBlocked True`) which is lighter-weight and easier to parse.
