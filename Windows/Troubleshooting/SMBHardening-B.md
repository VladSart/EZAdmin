# SMB Security Hardening Fallout (Win 11 24H2 / WS2025) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers what broke *because* 24H2/WS2025 changed SMB defaults: signing required, guest blocked, NTLM blocking, dialect floors, client-mandated encryption, auth rate limiter, mailslots, NetBIOS firewall ports.
> Generic SMB connectivity (port 445, DNS, share perms) → `SMB-B.md`. SMB over QUIC → `SMBoverQUIC-B.md`. Domain-wide NTLM restriction → `NTLM-B.md`.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Run on the **client that can't connect** (elevated PowerShell):

```powershell
# 1. OS build — is this a 24H2/WS2025 default-change machine? (24H2 = build 26100+)
[System.Environment]::OSVersion.Version; (Get-CimInstance Win32_OperatingSystem).Caption

# 2. Client hardening posture in one line
Get-SmbClientConfiguration | Select RequireSecuritySignature, EnableInsecureGuestLogons, RequireEncryption, BlockNTLM, Smb2DialectMin, Smb2DialectMax

# 3. What the last failures actually were (last 2h)
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-SMBClient/Security','Microsoft-Windows-SMBClient/Connectivity'; StartTime=(Get-Date).AddHours(-2)} -ErrorAction SilentlyContinue |
  Select TimeCreated, Id, LogName, @{n='Msg';e={($_.Message -split "`n")[0]}} | Format-Table -Wrap

# 4. Reproduce with the error code visible
net use \\<server>\<share>

# 5. Is the target a non-Windows device (NAS / printer / appliance / Linux Samba)?
Test-NetConnection <server> -Port 445 | Select ComputerName, RemoteAddress, TcpTestSucceeded
```

| If you see | Means | Go to |
|---|---|---|
| `System error 1272` / "organization's security policies block unauthenticated guest access" | Guest logon blocked (Pro 24H2 now matches Enterprise) | Fix 1 |
| `0xc000a000` / "The cryptographic signature is invalid" / connection drops right after negotiate | Client requires signing; device doesn't sign (or can't sign as guest) | Fix 2 |
| `BlockNTLM : True` and target is by IP, CNAME, workgroup, or non-domain NAS | SMB client refusing NTLM | Fix 3 |
| `Smb2DialectMin` set to `SMB300`/`SMB311` and target is old NAS/SMB 2.x | Dialect floor excludes device | Fix 4 |
| `RequireEncryption : True` and target is 3rd-party SMB 3.x without encryption | Client-mandated encryption | Fix 5 |
| Logons slow ~2s per bad attempt / scanners, MFPs, service accounts "hanging" | SMB auth rate limiter delaying failed auths | Fix 6 |
| Old app / DC locator / "browse" using mailslots stops working | Remote Mailslots disabled | Fix 7 |
| Works from other subnets only via 445, NetBIOS name resolution/browsing gone on WS2025 | NetBIOS 137-139 removed from built-in File & Printer Sharing rules | Fix 7 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
User can open \\server\share from a 24H2 / WS2025 client
└── TCP 445 reachable (SMB-B.md)
    └── Dialect negotiation succeeds
        ├── Server offers a dialect >= client Smb2DialectMin (and <= Smb2DialectMax)
        └── Server offers >= SMB 3.0 WITH encryption if client RequireEncryption = True
            └── Authentication succeeds
                ├── Real credentials, not guest/anonymous
                │   (EnableInsecureGuestLogons = False by default on Pro/Ent/Edu 24H2)
                ├── Kerberos available (name = SPN'd hostname, not IP/CNAME)
                │   OR NTLM allowed: BlockNTLM = False, or server in BlockNTLMServerExceptionList
                └── Not being throttled by server auth rate limiter (2s per failed attempt)
                    └── Session signing agreed
                        ├── Client RequireSecuritySignature = True (24H2 default)
                        │   → server MUST sign (guest sessions can never sign)
                        └── Server RequireSecuritySignature = True (Win11 24H2 inbound default;
                            WS2025 member = False; DC = True) → client MUST sign
                            └── Share access (NTFS + share ACL) — SMB-B.md
```
</details>

---
## Diagnosis & Validation Flow

**1. Confirm the client is on the new defaults**
```powershell
Get-SmbClientConfiguration | Select RequireSecuritySignature, EnableInsecureGuestLogons
```
Expected on 24H2 Pro/Ent/Edu: `True`, `False`. If both are already relaxed and it still fails → not a hardening issue; go to `SMB-B.md`.

**2. Find what the server negotiates (from a working session or a still-older client)**
```powershell
Get-SmbConnection | Select ServerName, ShareName, Dialect, Signed, Encrypted, UserName
```
- `Dialect 2.0.2/2.1` → old device; dialect floors and encryption requirement will kill it.
- `Signed False` on an older client → device may not support signing at all → Fix 2.
- `UserName` blank / `guest` / `nobody` → guest share → Fix 1 (and signing will also block it).

**3. Turn on 24H2 auditing to prove it before relaxing anything (no outage)**
```powershell
Set-SmbClientConfiguration -AuditServerDoesNotSupportSigning $true -AuditServerDoesNotSupportEncryption $true -Force
# reproduce, then:
Get-WinEvent -LogName 'Microsoft-Windows-SMBClient/Audit' -MaxEvents 20 | Where Id -in 31998,31999 | Format-List TimeCreated, Id, Message
```
31998/31999 name the server that can't sign/encrypt. That's your evidence for the vendor ticket.

**4. Check NTLM path**
```powershell
Get-SmbClientConfiguration | Select BlockNTLM, BlockNTLMServerExceptionList
klist get cifs/<server-fqdn>          # success = Kerberos possible if you use the FQDN
```
If `klist` fails and the target is by IP/CNAME/workgroup → NTLM is the only option → Fix 3.

**5. Server-side (if the server is WS2025 / Win11 24H2 and *clients* are failing)**
```powershell
Get-SmbServerConfiguration | Select RequireSecuritySignature, EncryptData, RejectUnencryptedAccess, Smb2DialectMin, Smb2DialectMax, InvalidAuthenticationDelayTimeInMs
Get-WinEvent -LogName 'Microsoft-Windows-SMBServer/Audit' -MaxEvents 20 -ErrorAction SilentlyContinue | Where Id -in 3021,3022
```
Old clients (XP-era scanners, embedded Linux) failing against a Win11 24H2 "server" (e.g., a shared PC folder) = inbound signing required.

---
## Common Fix Paths

> **Principle:** fix the *device* first (firmware update, enable SMB3 + signing, give it a real account). Relax Windows only with a scoped exception, and write down the rollback.

<details><summary>Fix 1 — Guest access blocked (error 1272)</summary>

Best fix: create a user on the NAS and map with credentials.
```powershell
New-SmbMapping -LocalPath Z: -RemotePath \\<nas>\<share> -UserName '<nas>\<user>' -Password '<password>' -Persistent $true
# or store the cred once
cmdkey /add:<nas> /user:<nas>\<user> /pass
```
Last resort (per-device, documented risk) — guest needs BOTH switches, because guest sessions can't sign:
```powershell
Set-SmbClientConfiguration -EnableInsecureGuestLogons $true -Force
Set-SmbClientConfiguration -RequireSecuritySignature $false -Force
```
GPO equivalents: *Network > Lanman Workstation > Enable insecure guest logons* and *Security Options > Microsoft network client: Digitally sign communications (always) = Disabled*.

**Rollback:** `Set-SmbClientConfiguration -EnableInsecureGuestLogons $false -RequireSecuritySignature $true -Force`
</details>

<details><summary>Fix 2 — Device can't sign (0xc000a000 / invalid signature)</summary>

1. Update NAS firmware / enable "SMB signing" or set min protocol SMB3 on the device (Synology, QNAP, Samba `server signing = mandatory` all support it on current firmware).
2. If impossible, relax client-side signing requirement (device-wide — no per-server signing exception exists):
```powershell
Set-SmbClientConfiguration -RequireSecuritySignature $false -Force
```
Via Intune: Settings catalog → *Local Policies Security Options* → *Microsoft Network Client Digitally Sign Communications Always* = Disable. Scope to a group of affected devices only.

**Rollback:** `Set-SmbClientConfiguration -RequireSecuritySignature $true -Force`
</details>

<details><summary>Fix 3 — NTLM blocked by SMB client</summary>

Prefer Kerberos: connect by FQDN, not IP or CNAME (for aliases, use `netdom computername <server> /add:<alias-fqdn>` so the SPN exists).

Scoped exception:
```powershell
Set-SmbClientConfiguration -BlockNTLMServerExceptionList '<nas-hostname>','<nas-fqdn>','<ip>' -Force
Get-SmbClientConfiguration | Select BlockNTLM, BlockNTLMServerExceptionList
```
GPO: *Network > Lanman Workstation > Block NTLM Server Exception List*.

**Rollback:** `Set-SmbClientConfiguration -BlockNTLMServerExceptionList @() -Force` (or remove the entry).
</details>

<details><summary>Fix 4 — Dialect floor excludes device</summary>

```powershell
Get-SmbClientConfiguration | Select Smb2DialectMin, Smb2DialectMax
# Temporarily lower the floor (valid: SMB202, SMB210, SMB300, SMB302, SMB311)
Set-SmbClientConfiguration -Smb2DialectMin SMB210 -Force
```
Plan to replace/upgrade anything that can't do SMB 3.x. Never re-enable SMB1 as a "fix".

**Rollback:** `Set-SmbClientConfiguration -Smb2DialectMin SMB311 -Force` (or your baseline).
</details>

<details><summary>Fix 5 — Client requires encryption, device doesn't support it</summary>

```powershell
Get-SmbClientConfiguration | Select RequireEncryption
Set-SmbClientConfiguration -RequireEncryption $false -Force   # only if device can't be fixed
```
Alternative: keep the mandate and move the data to a Windows/Azure Files share that encrypts.

**Rollback:** `Set-SmbClientConfiguration -RequireEncryption $true -Force`
</details>

<details><summary>Fix 6 — Auth rate limiter slowing bad-credential clients</summary>

The limiter only delays **failed** NTLM / local-KDC auths (default 2000 ms). Real fix = find the client with the wrong password.
```powershell
# On the server — who's failing?
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625; StartTime=(Get-Date).AddHours(-1)} |
  ForEach-Object { $x=[xml]$_.ToXml(); [pscustomobject]@{Time=$_.TimeCreated; User=$x.Event.EventData.Data[5].'#text'; Src=$x.Event.EventData.Data[19].'#text'} } |
  Group-Object User,Src | Sort Count -Desc | Select -First 10 Count, Name
# Tune only if a legit high-volume workload is affected (0 disables — don't)
Set-SmbServerConfiguration -InvalidAuthenticationDelayTimeInMs 2000 -Force
```
</details>

<details><summary>Fix 7 — Mailslots / NetBIOS ports</summary>

Mailslots are deprecated; fix the dependent app. If unavoidable, short term:
```powershell
Get-SmbClientConfiguration | Select EnableMailslots
Set-SmbClientConfiguration -EnableMailslots $true -Force
```
NetBIOS: WS2025's built-in *File and Printer Sharing* rules no longer open 137-139. Only re-add them for a documented legacy need:
```powershell
New-NetFirewallRule -DisplayName 'Legacy NetBIOS (TCP139)' -Direction Inbound -Protocol TCP -LocalPort 139 -Profile Domain -Action Allow
New-NetFirewallRule -DisplayName 'Legacy NetBIOS (UDP137-138)' -Direction Inbound -Protocol UDP -LocalPort 137,138 -Profile Domain -Action Allow
```
**Rollback:** `Remove-NetFirewallRule -DisplayName 'Legacy NetBIOS*'`; `Set-SmbClientConfiguration -EnableMailslots $false -Force`
</details>

---
## Escalation Evidence
```
Ticket: SMB hardening fallout
Client host / OS build:          <name> / <26100.xxxx>  Edition: <Pro|Ent|Edu>
Target server / type / firmware: <name> / <Windows|NAS vendor model|Samba ver> / <fw>
Path used (FQDN/IP/CNAME):       <\\...>
Error (net use):                 <1272 | 0xc000a000 | other>
Client config:                   RequireSecuritySignature=<> EnableInsecureGuestLogons=<> RequireEncryption=<> BlockNTLM=<> DialectMin=<> DialectMax=<>
Negotiated (from working client): Dialect=<> Signed=<> Encrypted=<> User=<>
SMBClient/Audit 31998/31999:     <paste>
SMBClient/Security + Connectivity events: <IDs + first line>
klist get cifs/<fqdn>:           <success|error>
Workaround applied (scope/rollback): <none | describe>
Vendor ticket #:                 <>
```

---
## 🎓 Learning Pointers
- **Signing is now required both ways on Win 11 24H2 Pro/Ent/Edu, outbound-only on WS2025** — that's why a 24H2 *workstation hosting a share* suddenly rejects old scanners while a WS2025 file server doesn't. [SMB security hardening](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-security-hardening)
- **Guest and signing are mutually exclusive** — a guest session has no session key, so "enable insecure guest logons" alone never fixes 24H2; that's why Fix 1 needs two switches. [Enable insecure guest logons](https://learn.microsoft.com/en-us/windows-server/storage/file-server/enable-insecure-guest-logons-smb2-and-smb3)
- **Audit before you relax**: events 31998/31999 (client) and 3021/3022 (server) let you inventory non-signing devices with zero user impact. [SMB signing overview](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-signing-overview)
- **IP/CNAME paths force NTLM** — with SMB NTLM blocking on, that's an outage, not a slowdown. [Block NTLM on SMB](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-ntlm-blocking)
- **EnableSecuritySignature is ignored for SMB2+** — only `RequireSecuritySignature` matters; don't waste time toggling the other. [Control SMB signing](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-signing)
- Deep dive: `SMBHardening-A.md`; bulk inventory: `Windows/Scripts/Get-SmbHardeningPosture.ps1`.
