# WinRM / PowerShell Remoting — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why remoting fails at each layer, not just what to type.

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
- WinRM service configuration, listeners, and firewall behavior (Windows 10/11, Server 2016+)
- PowerShell Remoting (`Enter-PSSession`, `Invoke-Command`, `New-PSSession`) over WinRM
- Kerberos and NTLM authentication paths, and when each applies
- GPO-managed vs. locally-managed WinRM configuration
- The Kerberos double-hop problem and its three real solutions (CredSSP, classic constrained delegation, resource-based constrained delegation)
- WSMan resource quotas relevant to automation/CI use

**Out of scope:**
- SSH-based PowerShell Remoting (PowerShell 7's `-SSHTransport`) — a parallel, non-WinRM transport with its own config surface
- DSC (Desired State Configuration) pull/push server internals — uses WinRM as transport but has its own failure modes
- Just Enough Administration (JEA) endpoint authoring — mentioned in Learning Pointers only; a large enough topic to warrant its own future runbook
- Linux/macOS WinRM clients (`pywinrm`, Ansible) — client-side quirks differ; this runbook assumes a Windows client

**Assumptions:**
- Windows 10/11 or Windows Server 2016+ on both ends
- PowerShell 5.1 baseline (WinRM cmdlets are consistent across 5.1 and 7.x; PowerShell-7-only syntax is avoided throughout)
- Reader has local admin on at least one side of the connection being troubleshot

---

## How It Works

<details><summary>Full architecture</summary>

### The WinRM Stack

WinRM is Microsoft's implementation of WS-Management, a SOAP-based protocol for remote system management. PowerShell Remoting is built **on top of** WinRM — it isn't a separate transport. Every `Enter-PSSession`/`Invoke-Command` call is a WS-Management operation against a **session configuration endpoint** (by default, `Microsoft.PowerShell`).

```
PowerShell cmdlet (Enter-PSSession, Invoke-Command, New-PSSession)
        │
WinRM client stack (WSMan.dll)
        │  HTTP or HTTPS, SOAP envelope
        ▼
Network (port 5985 HTTP / 5986 HTTPS)
        │
WinRM service (winrm.cmd / WinRM Windows service) on the target
        │
Listener (bound to an IP/port/transport combination)
        │
Authentication negotiation (Negotiate=Kerberos/NTLM, Basic, Certificate, CredSSP)
        │
Session configuration endpoint (Microsoft.PowerShell, or a custom/JEA endpoint)
        │
A dedicated wsmprovhost.exe process hosts the PowerShell session for that connection
        │
Command executes; output is serialized back over the same channel
```

### Listeners

A **listener** binds WinRM to an address, port, and transport. `Enable-PSRemoting -Force` creates a default HTTP listener on `*` (all addresses), port 5985. Listeners are independent of the WinRM service itself — the service can be running with zero listeners configured, in which case every connection attempt fails at the "no listener" stage regardless of firewall or auth state.

```powershell
winrm enumerate winrm/config/listener
```
returns each listener's `Transport` (HTTP/HTTPS), `Address`, `Port`, and — for HTTPS — the bound certificate thumbprint.

**HTTPS listeners require a certificate** whose Subject/SAN matches the hostname used to connect, issued by an authority the client trusts. There is no `Enable-PSRemoting -UseHttps` shortcut for arbitrary environments — the certificate has to already exist in the local machine store (via AD CS auto-enrollment, a manually issued cert, or a self-signed cert for lab use) before the HTTPS listener can bind to it.

### What `Enable-PSRemoting -Force` Actually Does

This single cmdlet performs five distinct actions, each of which can fail or be blocked independently:
1. Starts the WinRM service and sets it to auto-start
2. Creates the default `Microsoft.PowerShell` session configuration (and re-registers it if `-Force` and it's corrupted)
3. Creates an HTTP listener on all addresses, port 5985
4. Enables the `WINRM-HTTP-In-TCP` firewall rule for the Domain and Private profiles (explicitly **not** Public, unless `-SkipNetworkProfileCheck` is used)
5. On some OS versions, sets `LocalAccountTokenFilterPolicy` for non-domain-joined scenarios so local (non-built-in-Administrator) accounts can authenticate remotely

Any one of these five can be independently undone (firewall rule disabled, listener removed, service stopped) while the others remain intact — which is why "I ran Enable-PSRemoting" is not itself a diagnosis; each of the five needs its own check.

### Authentication Paths: Kerberos vs. NTLM

WinRM's default authentication provider is `Negotiate`, which picks Kerberos when possible and falls back to NTLM otherwise. Which one actually gets used is determined by conditions outside WinRM's control:

| Condition | Result |
|---|---|
| Both machines domain-joined (same domain or a domain with a two-way trust), connecting by hostname or FQDN | Kerberos — no `TrustedHosts` entry needed, server identity is cryptographically verified via SPN |
| Connecting by IP address, even between two domain-joined machines | **NTLM**, even in a fully trusted domain — Kerberos cannot issue a ticket for an IP address, there is no SPN registered against an IP |
| One or both machines not domain-joined (workgroup) | NTLM only — Kerberos is unavailable |
| Cross-forest with no trust | NTLM only, and requires `TrustedHosts` on the client since there's no AD path to validate the target's identity |

**NTLM authentication over WinRM requires either `TrustedHosts` (HTTP) or a trusted HTTPS certificate.** This exists because, unlike Kerberos, NTLM provides no built-in mechanism for the *client* to verify the *server's* identity — `TrustedHosts` is an explicit statement that the client accepts this risk for the listed hosts. Adding a hostname to `TrustedHosts` does nothing for a connection that would otherwise use Kerberos; it only affects the fallback path.

### Group Policy vs. Local Configuration

The GPO setting **"Allow remote server management through WinRM"** (`Computer Configuration → Administrative Templates → Windows Components → Windows Remote Management (WinRM) → WinRM Service`) directly manages the listener and permitted `IPv4Filter`/`IPv6Filter` ranges. When this policy is **Enabled or Disabled** (i.e., explicitly configured, not "Not Configured"), it takes precedence over anything `Enable-PSRemoting`, `winrm quickconfig`, or direct `WSMan:` provider edits attempt to set locally — and local attempts to change GPO-owned settings fail with an explicit, named error rather than silently no-op-ing:

```
WSManFault
    Message = The client cannot connect to the destination specified in the request.
    ...
Set-WSManQuickConfig : <Message>Cannot complete the request due to a conflicting Group Policy setting.
```

This is a deliberate design choice — it prevents a local admin action from silently drifting a fleet-managed configuration back out of compliance — but it is frequently misread as a permissions or connectivity problem rather than what it actually is: a policy authority conflict.

### The Kerberos Double-Hop Problem

When you connect to Server A via PSRemoting, your credentials authenticate that hop and are consumed there — they are **not** automatically forwarded if code running inside that session tries to reach Server B (a file share, SQL Server, a second computer). This isn't a bug; it's Kerberos delegation working exactly as designed to prevent credential replay by default. Three mechanisms solve it, each with different security and operational trade-offs:

```
Client ──Kerberos──▶ Server A ──???──▶ Server B
                         │
             Without explicit delegation configured,
             Server A has no usable credential to
             present to Server B on your behalf.
```

| Mechanism | How it works | Trade-off |
|---|---|---|
| **CredSSP** | Client's actual credentials are sent to Server A in a form Server A can replay to any target | Simple, but Server A now holds a fully reusable copy of your credentials — a significant lateral-movement risk if Server A is compromised |
| **Classic constrained delegation** | Server A's AD computer object is configured (`msDS-AllowedToDelegateTo`) with the specific SPNs it's allowed to delegate to | Intra-domain only; configured on the **front-end** (Server A) — cross-team coordination issue if Server A and Server B have different owners |
| **Resource-based constrained delegation (RBCD)** | Server B's own AD object (`msDS-AllowedToActOnBehalfOfOtherIdentity`) authorizes Server A specifically | Current Microsoft-recommended approach; authorization lives on the **resource** (Server B), works cross-domain within a forest, no client-side config |

This repo's dedicated delegation runbook covers the full configuration mechanics, the classic-vs-RBCD authorization-direction distinction, and cross-domain constraints: `../../ActiveDirectory/Troubleshooting/KerberosDelegation/Delegation-A.md`. WinRM's role in the double-hop problem is purely as the transport that exposes it — the fix lives entirely in Kerberos delegation configuration, not in WinRM itself.

### WSMan Resource Quotas

Independent of authentication and networking, WinRM enforces its own resource quotas, set per-shell-plugin (`Microsoft.PowerShell`) and globally:

```powershell
winrm get winrm/config/winrs
```
Key values: `MaxShellsPerUser` (default 30), `MaxConcurrentOperationsPerUser` (default 1500), `MaxMemoryPerShellMB` (default 1024 on modern builds), `MaxProcessesPerShell` (default 25). These exist to prevent one account from exhausting a shared server's resources — but they're invisible until automation, CI runners, or orchestration tooling opens more concurrent sessions than the default allows, at which point failures look identical to a generic connectivity problem but are actually quota rejections.

</details>

---

## Dependency Stack

```
WinRM Windows service running and set to auto-start
        │
At least one listener bound (HTTP and/or HTTPS) — independent of service state
        │
Firewall rule enabled for the ACTIVE network profile
   (Public profile excluded by default — the #1 real-world gap)
        │
Network path clear end-to-end (host firewall, network firewall, NSG, VPN)
        │
Authentication path determined by domain relationship + connection method (name vs. IP)
        │
   ├─ Kerberos path: valid SPN, correct DNS/FQDN resolution, no clock skew >5min
        │
   └─ NTLM path: TrustedHosts entry (HTTP) OR valid trusted certificate (HTTPS)
        │
GPO WinRM policy state (may override anything above — check first if config seems to "not stick")
        │
Session configuration endpoint exists (Microsoft.PowerShell or custom/JEA) and grants caller access
        │
WSMan quotas not exhausted (MaxShellsPerUser / MaxConcurrentOperationsPerUser)
        │
[Only if remote code needs a second hop] Delegation configured — CredSSP / classic constrained / RBCD
        │
Command executes; output serialized back to caller
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `Test-NetConnection -Port 5985` fails entirely | Firewall/network path blocked, or no listener bound | `winrm enumerate winrm/config/listener`; `Get-NetFirewallRule -DisplayName "WinRM*"` |
| Port reachable, `Test-WSMan` fails "Access is denied" | Wrong credentials, or NTLM path missing `TrustedHosts` | `Get-Item WSMan:\localhost\Client\TrustedHosts`; confirm domain relationship |
| Works from one client, fails from another to the same target | Client-side `TrustedHosts` or network profile difference, not a target-side problem | Compare `Get-NetConnectionProfile` and `TrustedHosts` on both clients |
| `Enable-PSRemoting -Force` errors with "conflicting Group Policy setting" | GPO already manages WinRM on this box | `gpresult /h report.html`; `winrm get winrm/config` |
| Works to Server A, but a command run inside that session fails reaching Server B | Kerberos double-hop — no credential forwarding configured | Test the same account's access to Server B when logged on directly; if that works, it's double-hop |
| Connects fine interactively, fails intermittently under automation/parallel jobs | WSMan quota exhaustion (`MaxShellsPerUser`/`MaxConcurrentOperationsPerUser`) | `winrm get winrm/config/winrs`; `Get-WSManInstance -ResourceURI shell -Enumerate` |
| CredSSP connection refused, error mentions "Encryption Oracle Remediation" | CVE-2018-0886 patch-level mismatch between client and server | `AllowEncryptionOracle` registry value on both ends |
| Connecting by IP fails, same target by hostname works | Expected — Kerberos cannot authenticate an IP address, this forces NTLM | Add IP to `TrustedHosts` or switch to hostname/FQDN |
| HTTPS listener won't bind / `winrm create` for HTTPS fails | No certificate in the local machine store matching the hostname, or thumbprint typo | `Get-ChildItem Cert:\LocalMachine\My`; confirm CN/SAN matches connection name |
| Session opens but immediately closes / "shell was not found" | `wsmprovhost.exe` crashed (often a profile-loading script error) or `MaxMemoryPerShellMB` exceeded | Check target Application/System event logs for `wsmprovhost` crash entries |
| Remoting worked yesterday, fails today with no config change reported | GPO refresh (every 90–120 min by default) re-applied a policy that a local admin had manually worked around | `gpupdate /force` then re-check `winrm get winrm/config` against the GPO's intended state |

---

## Validation Steps

**1. Confirm the WinRM service and at least one listener exist:**
```powershell
Get-Service WinRM | Select-Object Status, StartType
winrm enumerate winrm/config/listener
```
Expected: `Running`/`Automatic`, and at least one listener entry.

**2. Confirm the firewall rule is enabled for the currently active profile:**
```powershell
Get-NetConnectionProfile | Select-Object InterfaceAlias, NetworkCategory
Get-NetFirewallRule -DisplayName "WinRM*" | Select-Object DisplayName, Enabled, Profile
```
Expected: Active `NetworkCategory` (Domain/Private/Public) is one of the profiles the enabled rule applies to.

**3. Confirm raw port reachability, decoupled from WinRM protocol logic:**
```powershell
Test-NetConnection -ComputerName <target> -Port 5985
```
Expected: `TcpTestSucceeded = True`. A `False` here rules out everything downstream — don't proceed to auth troubleshooting until this passes.

**4. Confirm the protocol handshake itself:**
```powershell
Test-WSMan -ComputerName <target>
```
Expected: Returns `wsmid` XML with product vendor/version. Failure here with a successful port test means authentication/negotiation is the problem.

**5. Determine and validate the authentication path:**
```powershell
(Get-CimInstance Win32_ComputerSystem).PartOfDomain
Resolve-DnsName <target>   # confirm name resolves correctly for Kerberos SPN matching
```
For Kerberos: `klist` after a successful connection should show a ticket for `HTTP/<target>` or `WSMAN/<target>`.
For NTLM: confirm `TrustedHosts` on the client includes the target, or an HTTPS listener with a valid cert is in place.

**6. Confirm no GPO conflict before making local changes:**
```powershell
gpresult /h C:\Temp\gpresult.html /f
```
Search the report for "Windows Remote Management" under Computer Configuration. If a policy is listed as configured, treat it as authoritative.

**7. Confirm WSMan quotas if this is an automation/CI scenario:**
```powershell
winrm get winrm/config/winrs
Get-WSManInstance -ResourceURI shell -Enumerate
```
Expected: Current shell count well under `MaxShellsPerUser`.

**8. If double-hop is suspected, isolate it explicitly:**
```powershell
# From the CLIENT, direct access as the target account — does this work?
Test-Path \\ServerB\Share -Credential (Get-Credential)

# From INSIDE the PSSession to Server A, the SAME test:
Invoke-Command -ComputerName ServerA -ScriptBlock { Test-Path \\ServerB\Share }
```
If the first succeeds and the second fails using the same account, this is conclusively double-hop, not a permissions problem on Server B.

---

## Troubleshooting Steps (by phase)

### Phase 1: No Connectivity At All

1. `Get-Service WinRM` on target — confirm running.
2. `winrm enumerate winrm/config/listener` — confirm a listener exists. If empty, `Enable-PSRemoting -Force` is needed (check Phase 4 for GPO conflicts first).
3. `Test-NetConnection -Port 5985` from the client — if this fails, stop and escalate to network/firewall, don't proceed to auth debugging.
4. `Get-NetConnectionProfile` on target — if `Public`, the default firewall rule doesn't apply regardless of listener state.

### Phase 2: Connects but Authentication Fails

1. Confirm domain relationship: `(Get-CimInstance Win32_ComputerSystem).PartOfDomain` on both machines.
2. If both domain-joined and same/trusted domain: confirm connecting by name, not IP. `klist` after attempting the connection to see if a Kerberos ticket was even requested.
3. If NTLM path (workgroup, cross-domain, or by-IP): confirm `TrustedHosts` on the **client**:
   ```powershell
   Get-Item WSMan:\localhost\Client\TrustedHosts
   ```
4. If Kerberos should apply but fails: check SPN registration (`setspn -L <targetComputer>`), DNS resolution matches the actual hostname, and clock skew is under 5 minutes (`w32tm /stripchart /computer:<target>`).

### Phase 3: GPO Conflict Suspected

1. `gpresult /h report.html /f` on the target — search for "Windows Remote Management."
2. If configured: treat the GPO as the source of truth. Read the intended state (`Allow remote server management through WinRM` → Enabled/Disabled, and any IPv4Filter/IPv6Filter ranges).
3. Compare against actual state: `winrm get winrm/config`.
4. If they diverge and the machine was recently manually reconfigured, expect `gpupdate`/background refresh to silently revert it — fix the GPO, not the machine.

### Phase 4: Double-Hop

1. Confirm it's really double-hop, not a straightforward permissions issue on the second resource (see Validation Step 8).
2. Check whether classic constrained delegation or RBCD is already partially configured:
   ```powershell
   Get-ADComputer <ServerA> -Properties msDS-AllowedToDelegateTo
   Get-ADComputer <ServerB> -Properties msDS-AllowedToActOnBehalfOfOtherIdentity
   ```
3. Route to `../../ActiveDirectory/Troubleshooting/KerberosDelegation/Delegation-A.md` for the actual delegation configuration — this runbook only identifies that double-hop is the cause.
4. If a same-session, one-time workaround is needed while delegation is configured properly, use CredSSP as a documented, time-boxed exception (Playbook 2).

### Phase 5: Automation/CI Load Failures

1. `winrm get winrm/config/winrs` — note current `MaxShellsPerUser`/`MaxConcurrentOperationsPerUser`.
2. `Get-WSManInstance -ResourceURI shell -Enumerate` — count active shells; compare against the quota.
3. If quota is being legitimately exhausted by concurrent automation (not orphaned sessions), raise the quota (Playbook 3) rather than serializing the automation, unless the target's actual resource capacity (CPU/memory) is the real constraint.
4. If shells are orphaned (count is high but no active jobs correspond), clear them and investigate whether the calling tooling is failing to close sessions (`Remove-PSSession`/`$session.Dispose()` missing in the automation code).

---

## Remediation Playbooks

<details><summary>Playbook 1 — Stand up WinRM correctly from scratch on a new box</summary>

```powershell
# On the target
Enable-PSRemoting -Force

# Verify all five things Enable-PSRemoting is supposed to have done
Get-Service WinRM | Select-Object Status, StartType
winrm enumerate winrm/config/listener
Get-NetFirewallRule -DisplayName "Windows Remote Management (HTTP-In)" | Select-Object Enabled, Profile
Get-PSSessionConfiguration | Select-Object Name, Enabled
Get-NetConnectionProfile | Select-Object NetworkCategory

# If NetworkCategory is Public and this network should be trusted for remoting,
# either reclassify it (only if genuinely private) or scope the firewall rule explicitly:
Set-NetFirewallRule -DisplayName "Windows Remote Management (HTTP-In)" -Profile Any
```

**Rollback:**
```powershell
Disable-PSRemoting -Force
Remove-Item WSMan:\localhost\Listener\* -Recurse -Force
```

</details>

<details><summary>Playbook 2 — Enable CredSSP as a documented, time-boxed double-hop workaround</summary>

**Use only when RBCD/constrained delegation can't be stood up immediately and the need is short-term.**

```powershell
# Client
Enable-WSManCredSSP -Role Client -DelegateComputer ServerA -Force

# Server A (the middle hop)
Enable-WSManCredSSP -Role Server -Force

# Connect
$cred = Get-Credential
Enter-PSSession -ComputerName ServerA -Authentication Credssp -Credential $cred
```

**Document the exception** (who approved it, why RBCD wasn't used, and a removal date) since CredSSP leaves a replayable credential on Server A for the duration it's enabled.

**Rollback (do this on the removal date):**
```powershell
Disable-WSManCredSSP -Role Client
# On Server A:
Disable-WSManCredSSP -Role Server
```

</details>

<details><summary>Playbook 3 — Raise WSMan quotas for automation workloads</summary>

```powershell
# Current values
winrm get winrm/config/winrs

# Raise per-user shell and operation limits
winrm set winrm/config/winrs '@{MaxShellsPerUser="200"}'
winrm set winrm/config/winrs '@{MaxConcurrentOperationsPerUser="3000"}'

# If large output/parallel jobs are hitting memory ceilings too:
Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB 2048
```

**Also address the root cause, not just the ceiling** — check the automation tooling is calling `Remove-PSSession`/disposing sessions after use; raising quotas without fixing session leaks just delays the same failure.

**Rollback:**
```powershell
winrm set winrm/config/winrs '@{MaxShellsPerUser="30"}'
winrm set winrm/config/winrs '@{MaxConcurrentOperationsPerUser="1500"}'
Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB 1024
```

</details>

<details><summary>Playbook 4 — Stand up an HTTPS listener for remoting across an untrusted network</summary>

```powershell
# Confirm a certificate with a matching CN/SAN exists in the local machine store
Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -like "*<target-fqdn>*" }

# Create the HTTPS listener bound to that certificate's thumbprint
$thumbprint = "<certificate-thumbprint>"
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $thumbprint -Force

# Open the HTTPS firewall rule
Enable-NetFirewallRule -DisplayName "Windows Remote Management (HTTPS-In)"

# Connect using HTTPS explicitly, without needing TrustedHosts
$opt = New-PSSessionOption -SkipCACheck:$false -SkipCNCheck:$false
Enter-PSSession -ComputerName <target-fqdn> -UseSSL -SessionOption $opt -Credential (Get-Credential)
```

**Rollback:**
```powershell
Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -match "Transport=HTTPS" } | Remove-Item -Recurse -Force
Disable-NetFirewallRule -DisplayName "Windows Remote Management (HTTPS-In)"
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect WinRM/PowerShell Remoting evidence for escalation
.NOTES     Run as admin, on the TARGET machine (run a second pass on the client if the
           problem appears client-side, e.g. TrustedHosts or network profile)
#>

$OutputDir = "C:\Temp\WinRM-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. Service and listener state
Get-Service WinRM | Select-Object Status, StartType | Export-Csv "$OutputDir\WinRM-Service.csv" -NoTypeInformation
winrm enumerate winrm/config/listener | Out-File "$OutputDir\WinRM-Listeners.txt"

# 2. Firewall rules and network profile
Get-NetFirewallRule -DisplayName "WinRM*" | Select-Object DisplayName, Enabled, Profile, Direction |
    Export-Csv "$OutputDir\WinRM-Firewall.csv" -NoTypeInformation
Get-NetConnectionProfile | Select-Object InterfaceAlias, NetworkCategory |
    Export-Csv "$OutputDir\NetworkProfile.csv" -NoTypeInformation

# 3. Full WinRM config dump (includes auth methods, quotas)
winrm get winrm/config | Out-File "$OutputDir\WinRM-FullConfig.txt"

# 4. TrustedHosts and session configurations
Get-Item WSMan:\localhost\Client\TrustedHosts | Out-File "$OutputDir\TrustedHosts.txt"
Get-PSSessionConfiguration | Select-Object Name, Enabled, Permission |
    Export-Csv "$OutputDir\SessionConfigurations.csv" -NoTypeInformation

# 5. GPO report (search this for "Windows Remote Management")
gpresult /h "$OutputDir\gpresult.html" /f

# 6. Active shells (for quota/orphan investigation)
try {
    Get-WSManInstance -ResourceURI shell -Enumerate | Export-Csv "$OutputDir\ActiveShells.csv" -NoTypeInformation
} catch { "No active shells or query failed: $_" | Out-File "$OutputDir\ActiveShells-Error.txt" }

# 7. CredSSP state (if relevant)
Get-Item WSMan:\localhost\Client\Auth\CredSSP -ErrorAction SilentlyContinue | Out-File "$OutputDir\CredSSP-Client.txt"
Get-Item WSMan:\localhost\Service\Auth\CredSSP -ErrorAction SilentlyContinue | Out-File "$OutputDir\CredSSP-Service.txt"
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters" -ErrorAction SilentlyContinue |
    Out-File "$OutputDir\CredSSP-EncryptionOracle.txt"

# 8. Recent WinRM-related event log entries
Get-WinEvent -LogName "Microsoft-Windows-WinRM/Operational" -MaxEvents 100 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$OutputDir\WinRM-Events.csv" -NoTypeInformation

# 9. System info
Get-ComputerInfo | Select-Object CsName, OsVersion, OsBuildNumber, CsDomain, CsPartOfDomain |
    Export-Csv "$OutputDir\System-Info.csv" -NoTypeInformation

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Service and listener state
Get-Service WinRM
winrm enumerate winrm/config/listener
winrm get winrm/config

# Enable remoting from scratch
Enable-PSRemoting -Force

# Test connectivity and protocol
Test-NetConnection -ComputerName <target> -Port 5985
Test-WSMan -ComputerName <target>

# TrustedHosts (NTLM path only)
Get-Item WSMan:\localhost\Client\TrustedHosts
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "<target>" -Concatenate -Force
Clear-Item WSMan:\localhost\Client\TrustedHosts -Force

# Session configurations
Get-PSSessionConfiguration
Enter-PSSession -ComputerName <target>
Invoke-Command -ComputerName <target> -ScriptBlock { <command> }
New-PSSession -ComputerName <target>

# HTTPS listener
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint <thumbprint>
Enter-PSSession -ComputerName <target-fqdn> -UseSSL

# CredSSP (double-hop workaround)
Enable-WSManCredSSP -Role Client -DelegateComputer <ServerA>
Enable-WSManCredSSP -Role Server           # run on ServerA
Enter-PSSession -ComputerName <ServerA> -Authentication Credssp -Credential (Get-Credential)
Disable-WSManCredSSP -Role Client
Disable-WSManCredSSP -Role Server

# Quotas
winrm get winrm/config/winrs
winrm set winrm/config/winrs '@{MaxShellsPerUser="100"}'
Get-WSManInstance -ResourceURI shell -Enumerate

# Firewall
Get-NetFirewallRule -DisplayName "WinRM*"
Enable-NetFirewallRule -DisplayName "Windows Remote Management (HTTP-In)"

# GPO check
gpresult /h report.html /f

# Network profile
Get-NetConnectionProfile
```

---

## 🎓 Learning Pointers

- **PowerShell Remoting is not a separate protocol from WinRM — it's WS-Management with a `Microsoft.PowerShell` session configuration on top.** Every remoting failure is, underneath, a WinRM failure, which is why the same triage (listener → firewall → auth → quota) applies regardless of which cmdlet you're using. [MS Docs: WSMan Provider](https://learn.microsoft.com/en-us/powershell/module/microsoft.wsman.management/about/about_wsman_provider)

- **Kerberos cannot authenticate an IP address — this is not a bug to fix, it's how SPNs work.** An SPN is registered against a hostname; there is no equivalent for an IP. Connecting by IP always forces the NTLM fallback, which then requires `TrustedHosts` or HTTPS. If a team insists on IP-based automation against domain-joined hosts, budget for that requirement rather than treating each failure as a new mystery.

- **`TrustedHosts` is a statement of risk acceptance, not a compatibility switch.** Adding an entry disables server identity verification for that host over HTTP. For anything crossing a network boundary you don't fully control, the durable fix is an HTTPS listener with a real certificate, not a growing `TrustedHosts` list.

- **GPO-managed WinRM configuration is authoritative and will silently re-assert itself.** A local admin "fixing" a GPO-managed box will see the change revert on the next background policy refresh (90–120 min default) with no further error — the correct fix is always in the GPO, never on the machine, once a policy is confirmed configured.

- **CredSSP and constrained delegation solve the same problem with very different blast radii.** CredSSP gives the middle hop a fully replayable copy of the caller's credentials; RBCD gives the middle hop a narrowly scoped, resource-authorized delegation with nothing replayable if compromised. Default to RBCD for anything running more than once — see this repo's `KerberosDelegation` runbook for the actual configuration. [MS Docs: Making the second hop](https://learn.microsoft.com/en-us/powershell/scripting/security/remoting/ps-remoting-second-hop)

- **Just Enough Administration (JEA)** is worth knowing exists even though it's out of scope here: it lets you publish a custom, role-scoped WinRM session configuration endpoint (instead of the full `Microsoft.PowerShell` endpoint) so a remoted-in operator only gets a specific, audited command set rather than a full shell. Relevant any time "give the helpdesk team remoting access, but only to run three specific cmdlets" comes up. [MS Docs: JEA overview](https://learn.microsoft.com/en-us/powershell/scripting/learn/remoting/jea/overview)
