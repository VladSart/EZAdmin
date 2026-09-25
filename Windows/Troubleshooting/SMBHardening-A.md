# SMB Security Hardening (Win 11 24H2 / WS2025) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

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
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions
- **In scope:** the SMB default changes shipped in Windows 11 24H2 and Windows Server 2025 — required signing, insecure-guest blocking on Pro, SMB client NTLM blocking, dialect min/max management, client-mandated encryption, the SMB authentication rate limiter, signing/encryption auditing, Remote Mailslot deprecation and the NetBIOS firewall-rule change — plus how to roll them out to a mixed MSP estate (NAS, MFP scan-to-folder, Linux/Samba, legacy apps).
- **Out of scope:** basic SMB reachability and share/NTFS permissions (`SMB-A.md`), SMB over QUIC transport/certificates (`SMBoverQUIC-A.md`), domain-wide NTLM restriction policies (`NTLM-A.md`), NTLM relay to AD CS (`NTLMRelayADCS-A.md`), LDAP signing (`ActiveDirectory/Troubleshooting/LDAPSigning/`).
- **Assumptions:** admin PowerShell 5.1+, `SmbShare` module present (in-box). Settings named here are exposed by `Get/Set-SmbClientConfiguration` and `Get/Set-SmbServerConfiguration` on 24H2/WS2025; on older builds some properties don't exist — scripts should read defensively.
- **Upgrade vs clean install:** in-place upgrades generally inherit explicitly-set policy values; defaults apply where nothing was configured. Always read effective state rather than assuming.

---
## How It Works
<details><summary>Full architecture</summary>

### 1. The two sides: LanmanWorkstation (client) and LanmanServer (server)
Every Windows machine is both. `Get-SmbClientConfiguration` reads `HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters`; `Get-SmbServerConfiguration` reads `...\LanmanServer\Parameters`. GPO (Security Options + Administrative Templates *Network > Lanman Workstation / Lanman Server*) and Intune Settings catalog write the same values. A "file server" problem is often a *client-side* requirement on the connecting PC, and vice-versa for a Win 11 PC sharing a scan folder.

### 2. Connection sequence and where each control bites
```
Client                                   Server
  | NEGOTIATE (dialects offered, min..max)  |
  |---------------------------------------->|  ← Smb2DialectMin/Max (both sides)
  |<----------------------------------------|     server picks highest common
  | SESSION_SETUP (SPNEGO: Kerberos|NTLM)   |
  |---------------------------------------->|  ← BlockNTLM (client) / rate limiter (server, on failure)
  |<----------------------------------------|     guest/anonymous = no session key
  | Session flags: signing required?        |  ← RequireSecuritySignature (either side ⇒ signed)
  | encryption required?                    |  ← client RequireEncryption / server EncryptData
  | TREE_CONNECT \\server\share             |
  |---------------------------------------->|  ← per-share EncryptData, UNC hardening
```

### 3. Signing — the headline change
- SMB2+ signing is controlled **only** by `RequireSecuritySignature`; `EnableSecuritySignature` is ignored for SMB2+. Signing happens if *either* side requires it.
- Prior default: required only by DCs (inbound) and for `\\*\SYSVOL`/`\\*\NETLOGON` via UNC hardening.
- **Windows 11 24H2 Pro/Enterprise/Education:** required outbound *and* inbound.
- **Windows Server 2025:** required outbound only (member servers); DCs still require inbound as before.
- Consequences:
  - Any server/device that can't sign fails from a 24H2 client.
  - Any **guest** session fails, because guest has no session key to sign with — even if insecure guest logons are enabled.
  - Old clients that can't sign fail when connecting *to* a Win 11 24H2 machine (classic: MFP scan-to-SMB into a user's PC folder).
- Algorithms: HMAC-SHA256 (2.0.2/2.1), AES-CMAC (3.0+), AES-GMAC (3.1.1 on WS2022/Win11+). Signing costs CPU/throughput on high-bandwidth file servers; GMAC acceleration largely offsets it on modern hardware.

### 4. Insecure guest logons
Windows 10/11 Enterprise/Education already blocked guest fallback; **24H2 extends this to Pro** (the SMB-land edition most small-business MSP clients run). `EnableInsecureGuestLogons=False` → error 1272. Because of §3, re-enabling guest also requires disabling client signing requirement — a two-step, device-wide weakening.

### 5. SMB client NTLM blocking
- Client-side only (`BlockNTLM`), available on 24H2/WS2025. Stops the SPNEGO downgrade from Kerberos to NTLM for outbound SMB.
- `BlockNTLMServerExceptionList` accepts IPs, NetBIOS names and FQDNs. Per-mapping: `NET USE ... /BLOCKNTLM` or `New-SmbMapping -BlockNTLM $true`.
- Kerberos requires a name with a matching `cifs/` SPN. **IP addresses and DNS CNAMEs force NTLM.** Non-domain NAS and workgroup peers are NTLM-only (or PKU2U).
- Not on by default in GA builds — but it's increasingly set by security baselines; treat any "worked yesterday" NAS outage after a baseline push as a suspect.

### 6. Dialect management
`Smb2DialectMin`/`Smb2DialectMax` on both client and server (values `SMB202`, `SMB210`, `SMB300`, `SMB302`, `SMB311`). Lets you enforce 3.1.1 (pre-auth integrity, AES-GMAC, AES-256). Setting a floor of 3.x on the client silently breaks every 2.x-only device.

### 7. Client-mandated encryption
`Set-SmbClientConfiguration -RequireEncryption $true` → the client only connects to servers that support SMB 3.0+ **and** encryption. Some third-party SMB 3 stacks negotiate 3.x but don't implement encryption. Not a default.

### 8. Authentication rate limiter (server)
Enabled by default, `InvalidAuthenticationDelayTimeInMs` = 2000. Applies a delay after each **failed** NTLM or local-KDC Kerberos authentication. Legit users are unaffected; stale-credential service accounts, MFPs and mapped drives with old passwords become visibly slow. The delay is a symptom pointer, not the root cause.

### 9. Auditing (24H2+)
Client: `AuditServerDoesNotSupportSigning/Encryption` → `SMBClient/Audit` events **31998/31999**. Server: `AuditClientDoesNotSupportSigning/Encryption` → `SMBServer/Audit` events **3021/3022**. This is the non-disruptive inventory tool — run it for a week before tightening anything.

### 10. Mailslots and NetBIOS
Remote Mailslots are no longer enabled by default (deprecated, unauthenticated). Legacy apps and very old DC-locator/browse behaviour break. WS2025's built-in SMB firewall rules drop NetBIOS 137-139 (SMB1-era). Neither is required for SMB2/3 over 445.
</details>

---
## Dependency Stack
```
L7  User/app opens \\server\share
L6  Share/NTFS authorization                          (SMB-A.md)
L5  Session security: signing / encryption agreed     ← RequireSecuritySignature, RequireEncryption, EncryptData
L4  Authentication: Kerberos (SPN) or NTLM allowed     ← BlockNTLM(+exceptions), guest policy, rate limiter
L3  Dialect negotiation within both sides' min..max   ← Smb2DialectMin/Max
L2  Transport: TCP 445 (or QUIC 443 / alt port)       (SMB-A.md / SMBoverQUIC-A.md)
L1  Name resolution returns a Kerberos-usable name     (DNS-Client-A.md) — IP/CNAME ⇒ NTLM
L0  Policy source: GPO / Intune Settings catalog / baseline / local
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Error 1272 "block unauthenticated guest access" | Guest blocked (Pro 24H2 now included) | `Get-SmbClientConfiguration \| Select EnableInsecureGuestLogons` |
| Guest enabled but still fails | Client signing required; guest can't sign | `RequireSecuritySignature` on client |
| 0xc000a000 invalid signature / drop after negotiate | Device can't/doesn't sign | SMBClient/Audit 31998 |
| Scanner can't save to Win 11 PC share | Inbound signing required on 24H2 client-as-server | `Get-SmbServerConfiguration \| Select RequireSecuritySignature` on the PC |
| Works by FQDN, fails by IP | NTLM blocked; IP forces NTLM | `BlockNTLM`, `klist get cifs/<fqdn>` |
| NAS broke after security baseline rollout | `BlockNTLM`, dialect floor or RequireEncryption set by baseline | RSOP / Intune device config report |
| Only old NAS/printers fail, new ones fine | Dialect floor ≥ 3.0 | `Smb2DialectMin` |
| 3rd-party SMB 3 server fails, Windows servers fine | Client RequireEncryption; server lacks encryption | SMBClient/Audit 31999 |
| Mapped drives slow to reconnect, 4625s on server | Rate limiter delaying stale creds | Security 4625 grouped by user/source |
| Legacy app "network browse"/mailslot feature dead | Remote Mailslots disabled | `EnableMailslots` |
| NetBIOS name browse fails to WS2025 | 137-139 removed from built-in rules | `Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing'` |
| High CPU / lower throughput on file server after upgrade | Signing overhead (older dialects/NICs) | `Get-SmbConnection` Dialect; prefer 3.1.1 (GMAC) |

---
## Validation Steps
1. **Effective client posture**
   ```powershell
   Get-SmbClientConfiguration | Select RequireSecuritySignature, EnableInsecureGuestLogons, RequireEncryption, BlockNTLM, BlockNTLMServerExceptionList, Smb2DialectMin, Smb2DialectMax, EnableMailslots
   ```
   Good (hardened): `True, False, <policy>, <policy>, <scoped list>, SMB300/SMB311 or none, None, False`. Bad: property missing = pre-24H2 build (hardening not present); guest `True` with signing `True` = contradictory config that still fails.
2. **Effective server posture**
   ```powershell
   Get-SmbServerConfiguration | Select RequireSecuritySignature, EncryptData, RejectUnencryptedAccess, Smb2DialectMin, Smb2DialectMax, InvalidAuthenticationDelayTimeInMs
   ```
   Good: delay `2000`; `RejectUnencryptedAccess True` only when all clients do SMB3 encryption.
3. **Live sessions**
   ```powershell
   Get-SmbConnection | Select ServerName, Dialect, Signed, Encrypted, UserName      # client side
   Get-SmbSession    | Select ClientComputerName, ClientUserName, Dialect, Signed, Encrypted  # server side
   ```
   Good: `3.1.1`, `Signed True`. Bad: `2.x`, `Signed False`, anonymous/guest user names.
4. **Policy source**
   ```powershell
   gpresult /h $env:TEMP\rsop.html   # Security Options + Lanman Workstation/Server
   Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters' | Select RequireSecuritySignature, AllowInsecureGuestAuth
   ```
   Registry value present but no GPO → Intune/baseline or local change.
5. **Audit trail**
   ```powershell
   Get-WinEvent -LogName 'Microsoft-Windows-SMBClient/Audit' -MaxEvents 50 -ErrorAction SilentlyContinue | Where Id -in 31998,31999
   ```

---
## Troubleshooting Steps (by phase)
**Phase 1 — Is it hardening at all?** Reproduce with `net use`. If the error is 53/67/1231 (name/path/network) → `SMB-A.md`. If 5 (access denied) → permissions. Only 1272, 0xc000a000, NTLM/auth, or dialect errors belong here.

**Phase 2 — Identify the control.** Compare client posture to the device's capability (step 3 from a still-working older client). Enable auditing (no impact) and reproduce.

**Phase 3 — Identify the policy source.** RSOP / Intune per-setting status / security baseline profile. Fixing locally while a baseline re-applies = ticket reopens tomorrow.

**Phase 4 — Choose the least-bad fix.** Order: device firmware/config → real credentials → Kerberos name → scoped exception (NTLM exception list) → scoped group of devices with relaxed setting → never estate-wide rollback.

**Phase 5 — Verify and document.** `Get-SmbConnection` shows the expected dialect/signing; record the exception, owner and review date.

---
## Remediation Playbooks
<details><summary>Playbook 1 — Pre-rollout inventory for an estate going to 24H2</summary>

1. On a pilot set of 24H2 devices, enable client auditing only (no enforcement change):
   ```powershell
   Set-SmbClientConfiguration -AuditServerDoesNotSupportSigning $true -AuditServerDoesNotSupportEncryption $true -Force
   ```
2. On file servers (WS2025), enable server-side audit:
   ```powershell
   Set-SmbServerConfiguration -AuditClientDoesNotSupportSigning $true -AuditClientDoesNotSupportEncryption $true -Force
   ```
3. After 5-7 business days, collect 31998/31999 and 3021/3022 with `Get-SmbHardeningPosture.ps1 -IncludeAuditEvents` across the pilot.
4. Build a device list: vendor/model/firmware; raise vendor tickets; plan replacements.
5. Also inventory guest shares: any mapping without credentials on a Pro device will break at upgrade.

**Rollback:** set the four audit switches back to `$false`.
</details>

<details><summary>Playbook 2 — NAS/appliance cannot be upgraded (scoped relaxation)</summary>

1. Create an Entra/AD group of the few devices that need the NAS.
2. Intune Settings catalog profile (or GPO filtered to the group): *Microsoft Network Client: Digitally Sign Communications (Always)* = Disabled; if guest-only, also *Lanman Workstation > Enable insecure guest logons* = Enabled.
3. Document the business owner and replacement date.
4. Verify:
   ```powershell
   Get-SmbConnection -ServerName <nas> | Select Dialect, Signed, UserName
   ```
**Rollback:** remove devices from the group; policy re-evaluates to hardened defaults.
</details>

<details><summary>Playbook 3 — Enable SMB NTLM blocking safely</summary>

1. Inventory NTLM use first (`NTLM-A.md` — NTLM operational auditing, event 8001 on clients).
2. Fix name usage: replace IP/CNAME UNC paths in drive maps, shortcuts and scripts with FQDNs; register alias SPNs with `netdom computername <server> /add:<alias-fqdn>`.
3. Build `BlockNTLMServerExceptionList` for genuine non-domain targets.
4. Pilot:
   ```powershell
   Set-SmbClientConfiguration -BlockNTLM $true -BlockNTLMServerExceptionList '<nas1>','<nas1-fqdn>' -Force
   ```
5. Expand by ring.

**Rollback:** `Set-SmbClientConfiguration -BlockNTLM $false -Force`
</details>

<details><summary>Playbook 4 — Enforce SMB 3.1.1 on a file server</summary>

1. Confirm all sessions are already 3.1.1:
   ```powershell
   Get-SmbSession | Group-Object Dialect | Select Name, Count
   ```
2. Set floor on the server:
   ```powershell
   Set-SmbServerConfiguration -Smb2DialectMin SMB311 -Force
   ```
3. Watch for connection failures from appliances (backup agents, scanners) for 48 h.

**Rollback:** `Set-SmbServerConfiguration -Smb2DialectMin SMB202 -Force` (or clear via GPO "Not configured").
</details>

<details><summary>Playbook 5 — Scan-to-folder on a Win 11 24H2 PC broken</summary>

Root cause: PC now requires inbound signing; many MFPs sign only on newer firmware or need SMB3 enabled.
1. Update MFP firmware; enable SMB3/signing in its SMB settings; use a dedicated local/domain account (not guest).
2. Better: move the scan target to a file server or scan-to-SharePoint/OneDrive connector.
3. Last resort, on that PC only:
   ```powershell
   Set-SmbServerConfiguration -RequireSecuritySignature $false -Force
   ```
**Rollback:** `Set-SmbServerConfiguration -RequireSecuritySignature $true -Force`
</details>

---
## Evidence Pack
```powershell
# Collect-SmbHardeningEvidence.ps1 — read-only; run elevated on the affected client (and server if Windows)
$out = Join-Path $env:TEMP "SMBHardening_$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd_HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null
Get-CimInstance Win32_OperatingSystem | Select Caption, Version, BuildNumber | Export-Csv "$out\os.csv" -NoTypeInformation
Get-SmbClientConfiguration | Format-List * | Out-File "$out\smbclient-config.txt"
Get-SmbServerConfiguration | Format-List * | Out-File "$out\smbserver-config.txt"
Get-SmbConnection -ErrorAction SilentlyContinue | Select ServerName, ShareName, Dialect, Signed, Encrypted, UserName | Export-Csv "$out\connections.csv" -NoTypeInformation
Get-SmbSession    -ErrorAction SilentlyContinue | Select ClientComputerName, ClientUserName, Dialect, Signed, Encrypted | Export-Csv "$out\sessions.csv" -NoTypeInformation
Get-SmbMapping    -ErrorAction SilentlyContinue | Export-Csv "$out\mappings.csv" -NoTypeInformation
foreach ($log in 'Microsoft-Windows-SMBClient/Security','Microsoft-Windows-SMBClient/Connectivity','Microsoft-Windows-SMBClient/Audit','Microsoft-Windows-SMBServer/Security','Microsoft-Windows-SMBServer/Audit') {
    $safe = $log -replace '[/\\]','_'
    Get-WinEvent -LogName $log -MaxEvents 200 -ErrorAction SilentlyContinue |
        Select TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\$safe.csv" -NoTypeInformation
}
gpresult /scope computer /h "$out\rsop.html" /f | Out-Null
klist | Out-File "$out\klist.txt"
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| Client posture | `Get-SmbClientConfiguration \| Select RequireSecuritySignature, EnableInsecureGuestLogons, RequireEncryption, BlockNTLM, Smb2DialectMin` |
| Server posture | `Get-SmbServerConfiguration \| Select RequireSecuritySignature, EncryptData, Smb2DialectMin, InvalidAuthenticationDelayTimeInMs` |
| Live client sessions | `Get-SmbConnection \| Select ServerName, Dialect, Signed, Encrypted, UserName` |
| Live server sessions | `Get-SmbSession \| Select ClientComputerName, Dialect, Signed, Encrypted` |
| Audit non-signing servers | `Set-SmbClientConfiguration -AuditServerDoesNotSupportSigning $true -Force` |
| Read audit | `Get-WinEvent -LogName Microsoft-Windows-SMBClient/Audit \| Where Id -in 31998,31999` |
| NTLM exception | `Set-SmbClientConfiguration -BlockNTLMServerExceptionList '<host>' -Force` |
| Map blocking NTLM | `New-SmbMapping -RemotePath \\<srv>\<share> -BlockNTLM $true` |
| Dialect floor | `Set-SmbServerConfiguration -Smb2DialectMin SMB311 -Force` |
| Kerberos check | `klist get cifs/<server-fqdn>` |
| Alias SPN | `netdom computername <server> /add:<alias-fqdn>` |
| Failed auths (rate limiter) | `Get-WinEvent -FilterHashtable @{LogName='Security';Id=4625} -MaxEvents 50` |
| Fleet inventory | `.\Get-SmbHardeningPosture.ps1 -ComputerName (Get-Content hosts.txt) -IncludeAuditEvents` |

---
## 🎓 Learning Pointers
- [SMB security hardening (24H2/WS2025 overview)](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-security-hardening) — the canonical list of every default that changed; re-read it when triaging "worked before the upgrade" tickets.
- [Overview of SMB signing](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-signing-overview) — explains why `EnableSecuritySignature` is ignored and why IP/CNAME paths fall back to NTLM (weaker session key).
- [Control SMB signing behavior](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-signing) — the supported way to relax signing per edition, with GPO/Intune paths.
- [Block NTLM connections on SMB](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-ntlm-blocking) — exception list semantics and per-mapping `/BLOCKNTLM`.
- [Enable insecure guest logons](https://learn.microsoft.com/en-us/windows-server/storage/file-server/enable-insecure-guest-logons-smb2-and-smb3) — read the risk section before you hand this to a client.
- Ned Pyle's *"SMB security hardening in Windows Server 2025 & Windows 11"* (Microsoft Storage blog / Tech Community) — demo video timestamps for each feature.
