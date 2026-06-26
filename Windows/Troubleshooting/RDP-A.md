# RDP (Remote Desktop Protocol) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How RDP Works](#how-rdp-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps (by phase)](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

- **Target OS:** Windows 10/11, Windows Server 2019/2022/2025
- **Covers:** RDP connectivity failures, authentication errors, black screen, performance issues, NLA, TLS, RemoteFX, licensing, Gateway (RD Gateway), and Intune-managed devices
- **Does NOT cover:** RDS (Remote Desktop Services) farm architecture, Session Host load balancing at scale, or AVD (see `Azure/AVD/`)
- **Run as:** Domain admin or local administrator with network visibility

---

## How RDP Works

<details><summary>Full architecture — RDP connection lifecycle</summary>

### Connection Establishment

```
Client                              Server
  |                                   |
  |--[TCP SYN → port 3389]---------->|
  |<-[TCP SYN/ACK]-------------------|
  |--[TLS ClientHello]--------------->|  (if NLA/TLS)
  |<-[TLS ServerHello + Certificate]--|
  |--[CredSSP / NLA negotiation]----->|  NTLM or Kerberos
  |<-[Auth result]-------------------|
  |--[RDP Connection Request PDU]---->|
  |<-[MCS Connect-Response]----------|
  |--[Channel negotiation]----------->|  (rdpdr, cliprdr, rdpsnd, etc.)
  |<-[Virtual channel setup]---------|
  |--[Input/output stream begins]---->|
  |<-[Bitmap/GFX updates]------------|
```

### Key Protocols & Components

| Component | Role |
|-----------|------|
| **TermService** | Core RDP listener, manages sessions |
| **NLA (Network Level Authentication)** | Pre-auth via CredSSP before session creation — prevents DoS |
| **TLS 1.2/1.3** | Encrypts the RDP channel |
| **CredSSP** | Delegates credentials via SPNEGO (Kerberos or NTLM) |
| **RD Gateway** | HTTPS tunnel (port 443) for RDP over the internet |
| **RemoteApp** | Publishes individual apps rather than full desktop |
| **Virtual Channels** | Clipboard (cliprdr), drive redirection (rdpdr), audio (rdpsnd), USB |

### Session State Machine

```
LISTEN → CONNECTING → AUTHENTICATING → LOADING → ACTIVE → IDLE → DISCONNECTED
                                                                ↓
                                                         LOGGED OFF / RESET
```

### TermService Registry Hive

All RDP configuration lives under:
```
HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server
HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp
```

Key values:
- `fDenyTSConnections` = 0 (enabled) / 1 (disabled)
- `UserAuthentication` = 1 (NLA required) / 0 (NLA optional)
- `SecurityLayer` = 2 (TLS) / 1 (Negotiate) / 0 (RDP)
- `PortNumber` = 3389 (default)
- `MinEncryptionLevel` = 2 (Client-compatible) / 3 (High) / 4 (FIPS)

### Authentication Flow with NLA

```
Client                     DC (KDC)                    RDP Server
  |                           |                             |
  |---[Kerberos TGT req]----->|                             |
  |<--[TGT granted]-----------|                             |
  |---[Service ticket for     |                             |
  |    TERMSRV/<server>]----->|                             |
  |<--[Service ticket]--------|                             |
  |---[CredSSP with ticket]-------------------------------->|
  |<--[Auth OK / access token]-----------------------------|
```

If Kerberos fails (no DC reachable, SPN missing, clock skew), CredSSP falls back to NTLM. If NTLM is blocked by policy, the connection fails.

</details>

---

## Dependency Stack

```
User RDP Client (mstsc.exe / RDP app)
        │
        ▼
  Network Layer (TCP 3389 or RD Gateway 443)
        │
        ▼
  Windows Firewall (inbound rule: Remote Desktop - User Mode TCP-In)
        │
        ▼
  TermService (Remote Desktop Services) — must be Running
        │
        ▼
  NLA / CredSSP Authentication
        │
      ┌─┴──────────────────────┐
      ▼                        ▼
  Kerberos                  NTLM
  (requires DC reachable,   (fallback — may be
   correct SPN, time sync)   blocked by policy)
        │
        ▼
  Windows Logon (winlogon.exe → userinit.exe → explorer.exe)
        │
        ▼
  Group Policy / Intune Policy application
        │
        ▼
  Active Session (graphical desktop)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| "Remote Desktop can't connect to the remote computer" | TermService stopped, firewall blocking, fDenyTSConnections=1 | `Test-NetConnection -Port 3389`, check TermService |
| "The remote computer requires NLA" client error | Client doesn't support NLA or CredSSP | Client OS version, CredSSP policy |
| "Authentication error — CredSSP encryption oracle remediation" | Mismatched CredSSP patch levels | KB4103727 / CVE-2018-0886 patch status |
| "Your credentials did not work" | Wrong password, locked account, NLA rejecting | Check ADUC lockout, NTLM restriction |
| Black/blank screen after login | GPO applying, Explorer crash, display driver issue | Event 4624 logon success, Event 6, user profile |
| Disconnects after 60 seconds | Idle session timeout GPO, RD Gateway timeout | Session time limit GPO, NPS timeout |
| Slow / laggy graphics | RemoteFX disabled, low bandwidth, wrong color depth | Check RDP-Tcp color depth, GFX policy |
| "The terminal server has exceeded the maximum number of allowed connections" | Max 2 concurrent sessions on non-RDS Windows | Shadow session or log off idle sessions |
| "Remote Desktop Services is not enabled" | fDenyTSConnections=1 | Registry or SystemPropertiesRemote |
| RD Gateway 401 error | Gateway NPS policy rejecting user | NPS event log on gateway |
| Loopback connection refused | loopback check (DisableLoopbackCheck) | Registry fix or use FQDN |

---

## Validation Steps

**1. Verify TermService is running and listening**

```powershell
Get-Service TermService | Select-Object Name, Status, StartType
netstat -ano | Select-String ':3389'
```

Expected: Status=Running, port 3389 in LISTENING state.
Bad: Stopped → `Start-Service TermService`; not listening → service issue or port changed.

---

**2. Verify RDP is enabled**

```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections
```

Expected: `fDenyTSConnections = 0`
Bad: `= 1` → `Set-ItemProperty ... -Value 0` (or enable via GPO)

---

**3. Verify firewall rule**

```powershell
Get-NetFirewallRule -DisplayName '*Remote Desktop*' | Where-Object {$_.Enabled -eq 'True'} |
    Select-Object DisplayName, Direction, Action, Profile
```

Expected: At least one rule Enabled=True, Direction=Inbound, Action=Allow.
Bad: No enabled rules → `Enable-NetFirewallRule -DisplayName 'Remote Desktop - User Mode (TCP-In)'`

---

**4. Test network connectivity from client**

```powershell
Test-NetConnection -ComputerName <target> -Port 3389
```

Expected: `TcpTestSucceeded = True`
Bad: False → firewall, no route, or wrong IP.

---

**5. Verify NLA / CredSSP settings**

```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' |
    Select-Object UserAuthentication, SecurityLayer, MinEncryptionLevel
```

Expected: `UserAuthentication = 1` (NLA), `SecurityLayer = 2` (TLS)
Bad mismatch: Client cannot negotiate → set consistently.

---

**6. Verify CredSSP policy (encryption oracle remediation)**

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' -ErrorAction SilentlyContinue |
    Select-Object AllowEncryptionOracle
```

Expected: `AllowEncryptionOracle = 0` (Mitigated — both sides patched)
Bad: `= 2` (Vulnerable) on mismatch → both sides need KB4103727+

---

**7. Check session limits (non-RDS)**

```powershell
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fSingleSessionPerUser
```

Then check concurrent connections — Windows 10/11 allows 1 user session; Server allows 2 without RDS CALs.

```powershell
quser /server:<target>
```

---

**8. Check recent authentication events**

```powershell
Get-WinEvent -ComputerName <target> -FilterHashtable @{
    LogName = 'Security'
    Id = 4625, 4624, 4776
    StartTime = (Get-Date).AddHours(-1)
} | Select-Object TimeCreated, Id, Message | Format-List
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Can the client reach the server at all?

1. `ping <target>` — confirms IP reachability
2. `Test-NetConnection <target> -Port 3389` — confirms port open
3. If port closed: check Windows Firewall, intermediary firewalls, NSG (Azure), check port not changed
4. `nslookup <target>` — ensure DNS resolves to expected IP

### Phase 2 — Is TermService healthy?

1. `Get-Service TermService` — must be Running
2. If stopped: `Start-Service TermService` — check why it stopped: `Get-WinEvent -LogName System | Where-Object {$_.ProviderName -eq 'Service Control Manager' -and $_.Message -like '*Terminal*'}`
3. Check `fDenyTSConnections = 0`
4. Check GPO: Computer Config → Windows Settings → Security Settings → System Services → Remote Desktop Services

### Phase 3 — Authentication failing?

1. Check Security event log (Event 4625 — failed logon, failure reason)
   - Failure reason 0xC000006D = unknown username/bad password
   - Failure reason 0xC0000234 = account locked
   - Failure reason 0xC000015B = user not granted logon type (not in Remote Desktop Users group)
2. Check if user is in `Remote Desktop Users` local group: `Get-LocalGroupMember 'Remote Desktop Users'`
3. Check CredSSP patch level mismatch
4. Check Kerberos: `klist` on client — service ticket for TERMSRV?
5. Check clock skew: `w32tm /query /status` — Kerberos requires <5 min difference

### Phase 4 — Connection established but desktop broken?

1. Black screen: Check winlogon / userinit in Process Explorer or Task Manager
2. Event 6 in Security log = logon, but user profile failed to load
3. Event 7002 in Application = winlogon reported error
4. Check user profile: `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*'` for corrupt SID entries
5. Check GPO applying cleanly: `gpresult /h C:\Temp\gpo-report.html`
6. Display driver: Remote Desktop with RemoteFX requires drivers — check Device Manager

### Phase 5 — Performance issues?

1. Check color depth: High color (16-bit) often faster than True Color (32-bit)
2. Check network bandwidth: `Get-NetAdapterStatistics`
3. Check CPU/memory on server: `Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 10`
4. Check if AV is scanning RDP streams — exclusion needed
5. RemoteFX/GPU: requires WDDM 2.x driver and feature enabled via GPO

---

## Remediation Playbooks

<details><summary>Fix 1 — Enable RDP and configure firewall</summary>

```powershell
# Enable RDP
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
    -Name 'fDenyTSConnections' -Value 0 -Type DWord

# Enable NLA
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
    -Name 'UserAuthentication' -Value 1 -Type DWord

# Enable firewall rules
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'

# Start TermService
Set-Service TermService -StartupType Automatic
Start-Service TermService

Write-Host "RDP enabled. Test with: Test-NetConnection <this host> -Port 3389"
```

**Rollback:**
```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
    -Name 'fDenyTSConnections' -Value 1 -Type DWord
Disable-NetFirewallRule -DisplayGroup 'Remote Desktop'
```

</details>

<details><summary>Fix 2 — Resolve CredSSP encryption oracle error</summary>

Applies when client error reads: "Authentication error has occurred... CredSSP encryption oracle remediation"

Root cause: CVE-2018-0886 — one side is patched, the other is not, and policy is Forced/Mitigated.

```powershell
# Temporary workaround on CLIENT — set to Vulnerable (patch server ASAP)
# Only use if you cannot patch the server immediately
$regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters'
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
Set-ItemProperty -Path $regPath -Name 'AllowEncryptionOracle' -Value 2 -Type DWord
Write-Warning "CLIENT is now Vulnerable. Patch the RDP SERVER with KB4103727 or later and reset this to 0."
```

**Permanent fix:** Ensure both client and server have May 2018 or later cumulative update installed, then:
```powershell
Set-ItemProperty -Path $regPath -Name 'AllowEncryptionOracle' -Value 0 -Type DWord
```

**Rollback:** Reset to 0 (Mitigated) once both sides are patched.

</details>

<details><summary>Fix 3 — Add user to Remote Desktop Users group</summary>

```powershell
param([string]$Username)

# Check current members
$rdpGroup = Get-LocalGroupMember -Group 'Remote Desktop Users'
Write-Host "Current RDP users:" -ForegroundColor Cyan
$rdpGroup | Format-Table

# Add user
Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $Username
Write-Host "Added $Username to Remote Desktop Users group" -ForegroundColor Green

# Verify
Get-LocalGroupMember -Group 'Remote Desktop Users' | Where-Object {$_.Name -like "*$Username*"}
```

**Note:** Domain admins can RDP by default. Standard users must be in this group OR granted "Allow logon through Remote Desktop Services" user right via GPO.

</details>

<details><summary>Fix 4 — Reset TermService and RDP listener</summary>

Use when RDP listener is in a broken state (port not listening despite service running).

```powershell
# Stop dependent services first
Stop-Service -Name UmRdpService -Force -ErrorAction SilentlyContinue
Stop-Service -Name TermService -Force

Start-Sleep -Seconds 3

# Re-register TermService
$wmi = Get-WmiObject Win32_TerminalServiceSetting -Namespace 'root\cimv2\TerminalServices'
$wmi.SetAllowTSConnections(1, 1) | Out-Null

# Restart
Start-Service TermService
Start-Sleep -Seconds 2
Start-Service UmRdpService -ErrorAction SilentlyContinue

# Verify listener
netstat -ano | Select-String ':3389'
Write-Host "TermService status: $((Get-Service TermService).Status)" -ForegroundColor Cyan
```

</details>

<details><summary>Fix 5 — Fix black screen / broken desktop after RDP login</summary>

```powershell
# Check for profile issues
$profileList = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*'
$badProfiles = $profileList | Where-Object {$_.PSChildName -like '*.bak'}
if ($badProfiles) {
    Write-Warning "Found .bak profile entries — possible corruption:"
    $badProfiles | Select-Object PSChildName, ProfileImagePath
}

# Check winlogon / userinit
$wlPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Get-ItemProperty $wlPath | Select-Object Shell, Userinit

# Expected:
# Shell     = explorer.exe
# Userinit  = C:\Windows\system32\userinit.exe,

# Fix corrupt Winlogon values (if tampered by malware or GPO bug)
Set-ItemProperty -Path $wlPath -Name 'Shell' -Value 'explorer.exe'
Set-ItemProperty -Path $wlPath -Name 'Userinit' -Value 'C:\Windows\system32\userinit.exe,'

Write-Host "Winlogon values restored. Restart required." -ForegroundColor Yellow
```

</details>

<details><summary>Fix 6 — Change RDP port (non-default)</summary>

Use when default port 3389 is blocked by upstream firewall and changing is permitted by security policy.

```powershell
param([int]$NewPort = 33899)

$rdpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
$currentPort = (Get-ItemProperty $rdpPath).PortNumber
Write-Host "Current port: $currentPort"

# Update registry
Set-ItemProperty -Path $rdpPath -Name 'PortNumber' -Value $NewPort -Type DWord

# Update firewall
$existingRule = Get-NetFirewallRule -DisplayName 'RDP Custom Port' -ErrorAction SilentlyContinue
if ($existingRule) { Remove-NetFirewallRule -DisplayName 'RDP Custom Port' }

New-NetFirewallRule -DisplayName 'RDP Custom Port' -Direction Inbound -Protocol TCP `
    -LocalPort $NewPort -Action Allow -Profile Domain,Private

Write-Host "RDP port changed to $NewPort. Restart TermService and reconnect on new port." -ForegroundColor Yellow

# Restart listener
Restart-Service TermService -Force
```

**Rollback:** Run same script with `$NewPort = 3389`

</details>

---

## Evidence Pack

Collect this before escalating (runs on the **RDP server**):

```powershell
<#
.SYNOPSIS  Collects RDP diagnostics for escalation
.NOTES     Run on the RDP server as administrator. Output saved to C:\Temp\RDP-Diag.txt
#>

$outputFile = "C:\Temp\RDP-Diag_$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
$null = New-Item -Path (Split-Path $outputFile) -ItemType Directory -Force -ErrorAction SilentlyContinue

function Log { param($msg) $msg | Tee-Object -FilePath $outputFile -Append | Write-Host }

Log "=== RDP Diagnostics === $(Get-Date)"
Log "`n--- OS ---"
Log (Get-WmiObject Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber | Format-List | Out-String)

Log "`n--- TermService ---"
Log (Get-Service TermService | Select-Object Name, Status, StartType | Format-List | Out-String)

Log "`n--- RDP Registry ---"
$rdpKey = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
Log "fDenyTSConnections : $($rdpKey.fDenyTSConnections)"
$rdpTcp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
Log "UserAuthentication : $($rdpTcp.UserAuthentication)"
Log "SecurityLayer      : $($rdpTcp.SecurityLayer)"
Log "PortNumber         : $($rdpTcp.PortNumber)"
Log "MinEncryptionLevel : $($rdpTcp.MinEncryptionLevel)"

Log "`n--- CredSSP Policy ---"
$credSSP = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' -ErrorAction SilentlyContinue
Log "AllowEncryptionOracle : $($credSSP.AllowEncryptionOracle)"

Log "`n--- Firewall Rules ---"
Log (Get-NetFirewallRule -DisplayName '*Remote Desktop*' | Select-Object DisplayName, Enabled, Direction, Action, Profile | Format-Table -AutoSize | Out-String)

Log "`n--- Listening Ports ---"
Log (netstat -ano | Select-String ':3389' | Out-String)

Log "`n--- Active Sessions ---"
Log (& quser 2>&1 | Out-String)

Log "`n--- Local Group: Remote Desktop Users ---"
Log (Get-LocalGroupMember 'Remote Desktop Users' 2>&1 | Format-Table | Out-String)

Log "`n--- Recent Logon Events (last 2 hours) ---"
try {
    Get-WinEvent -FilterHashtable @{LogName='Security';Id=4624,4625;StartTime=(Get-Date).AddHours(-2)} -MaxEvents 20 |
        Select-Object TimeCreated, Id, @{N='Message';E={$_.Message.Substring(0,[Math]::Min(300,$_.Message.Length))}} |
        Format-List | Out-String | Tee-Object -FilePath $outputFile -Append | Write-Host
} catch { Log "Could not read Security log: $_" }

Log "`n--- TermService Error Events ---"
try {
    Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='TermService';StartTime=(Get-Date).AddDays(-1)} -MaxEvents 10 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, Message | Format-List | Out-String | Tee-Object -FilePath $outputFile -Append | Write-Host
} catch { Log "No TermService events found" }

Log "`n=== End of RDP Diagnostics === Output: $outputFile"
```

---

## Escalation Evidence

```
TICKET ESCALATION — RDP CONNECTIVITY ISSUE
===========================================
Date/Time           : ___________
Affected server     : ___________
Client OS/version   : ___________
Error message       : ___________

RDP enabled (fDenyTSConnections): ___
TermService status              : ___
Port 3389 listening             : ___
Firewall rule enabled           : ___
NLA setting (UserAuthentication): ___
CredSSP AllowEncryptionOracle   : ___
User in Remote Desktop Users    : ___
Event 4625 failure reason code  : ___
Last successful RDP logon (4624): ___

Attached: RDP-Diag output, event log export, screenshot of error
Escalate to: [Senior Engineer / Network Team / Security Team]
```

---

## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Test-NetConnection <host> -Port 3389` | Test RDP port reachability |
| `Get-Service TermService` | Check service status |
| `quser /server:<host>` | Show active RDP sessions |
| `logoff <sessionID> /server:<host>` | Log off idle session |
| `Get-ItemProperty 'HKLM:\...\Terminal Server' -Name fDenyTSConnections` | Check if RDP is enabled |
| `Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'` | Enable firewall rules |
| `Get-LocalGroupMember 'Remote Desktop Users'` | List RDP-permitted users |
| `Add-LocalGroupMember -Group 'Remote Desktop Users' -Member <user>` | Grant RDP access |
| `netstat -ano \| Select-String ':3389'` | Verify port is listening |
| `klist` | Show Kerberos tickets (on client) |
| `w32tm /query /status` | Check time sync |
| `gpresult /r` | Verify GPO applying correctly |
| `mstsc /v:<host> /admin` | Connect to console session |
| `Restart-Service TermService -Force` | Restart RDP listener |
| `Get-WinEvent -LogName Security -FilterXPath "*[System[EventID=4625]]"` | Recent failed logons |

---

## 🎓 Learning Pointers

- **NLA protects the server by requiring auth before session creation.** Without NLA, a rogue client can consume server resources just by initiating TCP — with NLA, the session isn't created until credentials pass CredSSP. Always require NLA on modern environments. [MS Docs: NLA](https://learn.microsoft.com/en-us/windows/security/identity-protection/remote-access/remote-desktop-services/network-level-authentication)

- **The CredSSP oracle vulnerability (CVE-2018-0886) is a common gotcha during patching waves.** When the May 2018 CU ships to clients first and servers lag behind, or vice versa, connections break depending on the `AllowEncryptionOracle` policy value. The safest path is patch both sides, then set Mitigated. [KB4103727](https://support.microsoft.com/en-us/topic/credssp-updates-for-cve-2018-0886-march-13-2018-kb4093492-0bfc6a51-6f0e-2d94-bd7b-e91f2e9acf73)

- **Session limits are OS-enforced, not a bug.** Windows 10/11 allow one interactive session and one concurrent RDP session (same or different user). Windows Server without RDS CALs allows two admin sessions. Exceeding this gives a "too many connections" error — the fix is to log off idle sessions, not to patch or disable the limit.

- **RD Gateway separates RDP from internet exposure.** Direct port 3389 exposure is high risk — enumerate the service and you're one credential spray away from compromise. RD Gateway tunnels RDP over HTTPS (443) with NPS policy enforcement. For any tenant with external RDP needs, this is the correct architecture. [RD Gateway overview](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/rds-deploy-infrastructure)

- **Black screen after RDP login is most often a profile or policy issue, not graphics.** winlogon, userinit, and Explorer must form an unbroken chain. If GPO is applying during the initial session (especially at first login), the screen appears black while policies process. Waiting 60–90 seconds resolves it in most cases.

- **For Intune-managed devices, RDP access requires explicit policy.** By default, Intune does not enable RDP. You need a Configuration Profile (Settings Catalog → Remote Desktop) or a Remediation script to set `fDenyTSConnections = 0` and enable the firewall rule. [Intune: Configure RDP](https://learn.microsoft.com/en-us/mem/intune/configuration/settings-catalog)
