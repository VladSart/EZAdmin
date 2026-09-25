# SMB over QUIC — Reference Runbook (Mode A: Deep Dive)
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

**In scope**
- SMB over QUIC server on **any edition of Windows Server 2025** or **Windows Server 2022 Datacenter: Azure Edition** (incl. Azure Local).
- Windows 11 SMB clients (auditing + client access control + alternative ports need **24H2** or later).
- Server certificate mapping, UDP 443 / alternative ports, KDC Proxy for Kerberos, NTLM interplay, client access control (certificate ACLs), auditing, certificate lifecycle.

**Out of scope**
- Generic SMB share/NTFS permissions, signing, SMB1 → `SMB-A.md` / `SMB-B.md`.
- Azure Files over QUIC via Azure File Sync caches — same client, but the server side is the File Sync cache server; server-side notes here still apply to that Windows Server.
- DFS Namespaces over QUIC: Microsoft advises against exposing DFS namespace names externally because referrals point to internal names clients can't reach — map the file server FQDN directly.

**Assumptions:** You have admin on the file server, a PKI (ADCS or public CA), control over public DNS and the edge firewall/NAT.

---

## How It Works

<details><summary>Full architecture</summary>

### Transport swap, not a VPN
SMB over QUIC replaces **TCP 445** with **QUIC over UDP 443**. QUIC (IETF RFC 9000, Microsoft implementation *MsQuic*) always runs TLS 1.3, so the whole SMB session — negotiate, session setup (auth), tree connect, I/O — travels inside an encrypted, server-authenticated tunnel. Nothing SMB-specific (not even the NTLM exchange) is visible on the wire. Everything above the transport — dialect 3.1.1, signing, encryption, multichannel, leasing, continuous availability — behaves as normal. Microsoft markets it as an "SMB VPN", but it is scoped to one server and one protocol.

```
 Windows 11 client                                         File server (WS2025 / 2022 AzE)
 ┌──────────────────┐       Internet / untrusted         ┌───────────────────────────────┐
 │ LanmanWorkstation│                                     │ LanmanServer (srv2.sys)       │
 │  mrxsmb / SMB3   │                                     │   SMB 3.1.1 session           │
 │ ─────────────────│  UDP 443 (or alt port)              │ ───────────────────────────── │
 │ MsQuic + TLS 1.3 │ ═══════════════════════════════════▶│ MsQuic + TLS 1.3              │
 │ (Schannel)       │  cert: SAN = fs.contoso.com         │  cert via SmbServerCertMapping│
 └──────────────────┘                                     └──────────────┬────────────────┘
                                                                          │ NTLM pass-through /
                                                                          ▼ Kerberos (KDC Proxy)
                                                                     Domain controller(s)
```

### Connection selection on the client
1. The client **tries TCP 445 first**. On a LAN or VPN that succeeds and QUIC is never used.
2. If TCP fails (e.g. from the internet where 445 is blocked), the client **falls back to QUIC** to the same name.
3. `NET USE ... /TRANSPORT:QUIC` or `New-SmbMapping -TransportType QUIC` **forces QUIC only** — the correct way to test.
4. Windows 11 24H2 / Server 2025 add per-mapping alternative ports: `-QuicPort`, `-TcpPort`, `-RdmaPort` (server side only QUIC's port can be changed, via `New-SmbServerAlternativePort`).

The fallback behaviour explains the classic false positive: "it works" when tested inside the office, because it was TCP.

### Server certificate mapping
QUIC needs a certificate to present. SMB does not bind to the machine's "best" cert automatically; the admin creates an explicit **SMB server certificate mapping**:

```
SmbServerCertificateMapping
  Name        = fs.contoso.com        ← the SNI name the client will ask for
  Thumbprint  = <SHA1 thumbprint>     ← cert in LocalMachine\My
  StoreName   = My
  Type        = QUIC
  RequireClientAuthentication       ← client access control on/off
  SkipClientCertificateAccessCheck  ← validate chain but skip ACL
```

Certificate requirements (per Microsoft Learn): Server Authentication EKU (1.3.6.1.5.5.7.3.1), digital signature key usage, SHA-256+ signature, ECDSA P-256+ (or RSA ≥ 2048), a **SAN DNS entry for each FQDN** clients use, a non-empty subject, and the **private key**. **No IP addresses** as names: IP forces NTLM and is unsupported through NAT (every Azure IaaS VM is NATed).

**Lifecycle trap:** a renewed certificate — even an ADCS autoenrollment renewal with the same template and SAN — has a **new thumbprint**. The mapping keeps pointing at the old one. When the old cert expires or is archived/removed, QUIC stops presenting a valid cert and every remote user is cut off at once. This is the single most common production failure.

### Authentication inside the tunnel
- **Default (no DC reachability from client): NTLMv2.** The client authenticates to the file server; the server does pass-through to a DC. The exchange is protected by TLS 1.3, but it is still NTLM — it collides with NTLM blocking/auditing initiatives (Windows 11 24H2 / Server 2025 SMB client `BlockNTLM`, org-wide NTLM restrictions — see `NTLM-A.md`).
- **Recommended: Kerberos via KDC Proxy.** The file server also runs the **KDC Proxy Server service (KPSSVC)** on HTTPS/TCP 443 (`/KdcProxy`). Clients configured with the *Specify KDC proxy servers for Kerberos clients* policy send AS/TGS requests over HTTPS to the proxy, which forwards to a DC. Result: Kerberos tickets for `cifs/fs.contoso.com` without any DC exposure.
- **Workgroup servers** work with local accounts + NTLM. **Entra-joined servers** only in Azure IaaS, and still need domain or local accounts for share access (Entra ID has no user SIDs for remote security ops).

### Client access control (optional hardening)
With `RequireClientAuthentication = $true`, the server demands a client certificate during the TLS handshake:
1. Client presents the cert chosen by **`New-SmbClientCertificateMapping -Namespace <server FQDN> -Thumbprint <SHA1>`**; cert must have **Client Authentication EKU (1.3.6.1.5.5.7.3.2)** and chain to a CA the server trusts.
2. Server validates the chain, then evaluates its **ACL** (`Get-SmbClientAccessToServer`), whose entries are either **SHA256** hashes of leaf certs or **ISSUER** distinguished names (intermediate/root CAs).
3. Rule: access is granted if **no** cert in the chain is Blocked and **at least one** is Granted. **Block always beats Grant** anywhere in the chain.
4. `SkipClientCertificateAccessCheck = $true` + `RequireClientAuthentication = $true` = validate chain, skip ACL.

Note the hash mismatch: **client mapping uses the SHA1 thumbprint**, **server ACL uses SHA256** (`$cert.GetCertHashString('SHA256')`).

### Auditing
- Client: `Microsoft-Windows-SMBClient/Connectivity` event **30832** — QUIC connection auditing (Windows 11 24H2+); **30831** — client access control.
- Server: `Microsoft-Windows-SMBServer/Audit` events **3007, 3008, 3009** — client certificate access decisions; off by default, enable with `Set-SmbServerConfiguration -AuditClientCertificateAccess $true`. Events include subject, issuer, serial, SHA1/SHA256 and the ACE that applied, plus a connection ID that correlates client and server events.

### Management surfaces
- **PowerShell (SmbShare module)** — authoritative, and the **only supported method on Windows Server 2025** (the WAC SMB over QUIC wizard isn't supported for 2025).
- **WAC** — for 2022 Azure Edition, domain-joined only; since WAC 2110 it also auto-configures KDC Proxy. WAC gateway on TCP 443 on the same host conflicts with KDC Proxy.
- **Group Policy / Intune** — client enable/disable, server exception list, KDC proxy client setting.
</details>

---

## Dependency Stack

```
 ┌──────────────────────────────────────────────────────────────┐
 │ 8. User experience: \\fs.contoso.com\share opens off-network │
 ├──────────────────────────────────────────────────────────────┤
 │ 7. Share + NTFS permissions (unchanged from TCP SMB)         │
 ├──────────────────────────────────────────────────────────────┤
 │ 6. Authentication: NTLMv2 pass-through  OR  Kerberos via KDC │
 │    Proxy (KPSSVC, HTTPS 443, client KDC proxy policy)        │
 ├──────────────────────────────────────────────────────────────┤
 │ 5. Optional client access control (client cert + ACL)        │
 ├──────────────────────────────────────────────────────────────┤
 │ 4. TLS 1.3 handshake: SNI name == mapping Name == cert SAN;  │
 │    client trusts issuing root; cert in date w/ private key   │
 ├──────────────────────────────────────────────────────────────┤
 │ 3. SMB server: EnableSMBQUIC, SmbServerCertificateMapping,   │
 │    UDP listener (443 or alternative port)                    │
 ├──────────────────────────────────────────────────────────────┤
 │ 2. Network: public DNS A record, edge NAT/allow UDP 443,     │
 │    host firewall UDP 443 in; client network allows UDP out   │
 ├──────────────────────────────────────────────────────────────┤
 │ 1. Platform: WS2025 (any ed.) / WS2022 AzE; Windows 11 client│
 └──────────────────────────────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| All remote users fail at the same moment | Server cert renewed/expired; mapping has stale thumbprint | `Get-SmbServerCertificateMapping` vs `Cert:\LocalMachine\My` |
| Works in office, fails at home | Office used TCP 445; QUIC never actually worked | Force `-TransportType QUIC` externally |
| Works on hotspot, fails at a particular site | Site blocks outbound UDP 443 / inspects QUIC | Hotspot A/B test; alternative port |
| "The network path was not found" immediately | No listener, firewall/NAT drop, wrong public DNS | `Get-NetUDPEndpoint -LocalPort 443`, edge NAT, `Resolve-DnsName` |
| Cert/trust error, TLS failure | SAN doesn't contain the name used; client doesn't trust private root | Compare name vs SAN; push root via Intune trusted cert profile |
| Using IP address fails / NTLM-only | IP not supported through NAT, forces NTLM | Use FQDN only |
| Tunnel connects, repeated credential prompts | NTLM blocked on client; KDC Proxy absent/misconfigured | `Get-SmbClientConfiguration` BlockNTLM; `kpssvc` status; `klist` |
| Kerberos over KDC Proxy fails after enabling WAC | WAC gateway grabbed TCP 443 | `netsh http show urlacl`, `netsh http show sslcert` |
| Access denied only after enabling client auth | Client cert not mapped / not granted / blocked in chain | `Get-SmbClientAccessToServer`, `Get-SmbClientCertificateMapping`, SMBServer/Audit 3007-3009 |
| One user denied, rest of CA fine | Leaf-level Block entry | `Get-SmbClientAccessToServer` |
| DFS path fails externally, direct server path works | Referral to internal namespace/target names | Map the server FQDN directly |
| QUIC fails after 3rd-party HTTP/3 app installed on server | UDP 443 port conflict | `Get-NetUDPEndpoint -LocalPort 443` owning process |
| Client refuses QUIC even though server fine | `EnableSMBQUIC = $false` by policy | `Get-SmbClientConfiguration`; gpresult/Intune |

---

## Validation Steps

1. **Server feature state**
   ```powershell
   Get-SmbServerConfiguration | Select-Object EnableSMBQUIC, AuditClientCertificateAccess
   ```
   Good: `EnableSMBQUIC : True`. Bad: False → nothing will listen.

2. **Mappings resolve to valid certs**
   ```powershell
   Get-SmbServerCertificateMapping | ForEach-Object {
     $c = Get-Item "Cert:\LocalMachine\My\$($_.Thumbprint)" -ErrorAction SilentlyContinue
     '{0,-30} {1} exp={2:yyyy-MM-dd} key={3} sanMatch={4}' -f $_.Name, [bool]$c, $c.NotAfter, $c.HasPrivateKey, ($c.DnsNameList.Unicode -contains $_.Name) }
   ```
   Good: every line `True`, expiry > 30 days, `key=True`, `sanMatch=True`. Bad: `False` anywhere.

3. **EKU check**
   ```powershell
   (Get-Item Cert:\LocalMachine\My\<thumbprint>).EnhancedKeyUsageList
   ```
   Good: contains `Server Authentication (1.3.6.1.5.5.7.3.1)`.

4. **Listener**
   ```powershell
   Get-NetUDPEndpoint -LocalPort 443 | Select-Object LocalAddress, OwningProcess
   Get-SmbServerAlternativePort
   ```
   Good: an endpoint owned by `System` (PID 4). Another PID on 443 = conflict.

5. **Firewall**
   ```powershell
   Get-NetFirewallPortFilter -Protocol UDP | Where-Object LocalPort -eq 443 | Get-NetFirewallRule | Select-Object DisplayName, Enabled, Direction, Action, Profile
   ```
   Good: enabled inbound Allow on the profile the public NIC is in.

6. **External QUIC-only test (client off-network)**
   ```powershell
   New-SmbMapping -LocalPath 'Q:' -RemotePath '\\fs.contoso.com\share' -TransportType QUIC
   Get-SmbConnection -ServerName fs.contoso.com | Select-Object ServerName, ShareName, Dialect, Encrypted
   ```
   Good: mapping succeeds, dialect 3.1.1. Bad: error 53/67/1231 → network/listener; 5/1326 → auth.

7. **Auth path**
   ```powershell
   klist purge; dir \\fs.contoso.com\share | Out-Null; klist | Select-String 'cifs/fs.contoso.com'
   ```
   Good (with KDC Proxy): a `cifs/fs.contoso.com` ticket. None → NTLM was used.

8. **Client access control (if on)**
   ```powershell
   Get-SmbClientAccessToServer                                     # server
   Get-WinEvent -LogName Microsoft-Windows-SMBServer/Audit -MaxEvents 20  # server
   ```
   Good: expected Grant entries; 3007–3009 show Grant decisions for your client.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Reachability.** Resolve the public name (public resolver, not internal DNS) → public IP → edge NAT to server → host firewall UDP 443 → listener. Since `Test-NetConnection` can't test UDP, the QUIC-only mapping *is* the reachability test; pair it with a packet capture on the server (`pktmon start --capture --comp nics --pkt-size 0` then filter UDP 443) to prove packets arrive.

**Phase 2 — TLS.** If packets arrive but the mapping fails: SAN/name mismatch, untrusted root on the client, expired or key-less cert, or an ECDSA/RSA cert that doesn't meet minimums. Check the client's `Microsoft-Windows-SMBClient/Connectivity` and System log (Schannel) events.

**Phase 3 — Client access control.** Only if `RequireClientAuthentication` is True. Enable server audit, reproduce, read 3007–3009 — the event names the ACE that decided.

**Phase 4 — Authentication.** Tunnel up, auth failing. Determine NTLM vs Kerberos (`klist`). For NTLM: client `BlockNTLM`, server/domain NTLM restrictions, account lockouts (internet-exposed NTLM endpoint = password-spray target — check 4625/4771 on DCs). For Kerberos: `kpssvc` running, `netsh http show urlacl` has `https://+:443/KdcProxy/`, `netsh http show sslcert` binds the right cert on `<fqdn>:443`, client policy value syntax, DC reachability from the file server.

**Phase 5 — Authorization & data path.** Now it's ordinary SMB: share/NTFS perms, DFS referrals (avoid externally), app compatibility.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield deployment on Windows Server 2025 (PowerShell)</summary>

```powershell
# 0. Prereqs: cert issued with SAN fs.contoso.com (+ any other names), Server Auth EKU, private key, in LocalMachine\My
$fqdn  = 'fs.contoso.com'
$cert  = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.HasPrivateKey -and ($_.DnsNameList.Unicode -contains $fqdn) -and $_.NotAfter -gt (Get-Date) } |
         Sort-Object NotAfter -Descending | Select-Object -First 1

# 1. Map and enable
New-SmbServerCertificateMapping -Name $fqdn -Thumbprint $cert.Thumbprint -StoreName My
Set-SmbServerConfiguration -EnableSMBQUIC $true -Force

# 2. Host firewall (edge/NAT separately). Do NOT open TCP 445 inbound from the internet.
New-NetFirewallRule -DisplayName 'SMB over QUIC (UDP 443 In)' -Direction Inbound -Protocol UDP -LocalPort 443 -Action Allow

# 3. Public DNS: A record fs.contoso.com → public IP.
# 4. KDC Proxy (Playbook 3), then optional client access control (Playbook 4).
# 5. Test from an external Windows 11 client:
#    New-SmbMapping -RemotePath \\fs.contoso.com\share -TransportType QUIC
```
Rollback: `Set-SmbServerConfiguration -EnableSMBQUIC $false -Force; Remove-SmbServerCertificateMapping -Name $fqdn -Force; Remove-NetFirewallRule -DisplayName 'SMB over QUIC (UDP 443 In)'`.
</details>

<details><summary>Playbook 2 — Certificate rotation without an outage</summary>

1. Issue/renew the new cert **before** the old one expires; confirm SAN and private key.
2. Record current mapping (`Get-SmbServerCertificateMapping | Export-Clixml C:\Temp\quicmap-before.xml`).
3. Remap:
   ```powershell
   Set-SmbServerCertificateMapping -Name 'fs.contoso.com' -Thumbprint '<newSHA1>' -StoreName My
   ```
4. If KDC Proxy shares the cert: `netsh http delete sslcert hostnameport=fs.contoso.com:443` then `netsh http add sslcert hostnameport=fs.contoso.com:443 certhash=<newSHA1> appid={<guid>} certstorename=MY`.
5. Validate externally (Validation 6–7). Existing sessions may continue on the old handshake; new connections use the new cert.
6. Only then remove the old cert.
7. Automate: schedule `Get-SmbOverQuicHealth.ps1 -ExpiryWarningDays 30` and alert on WARN.

Rollback: re-point at the old thumbprint while it is still valid.
</details>

<details><summary>Playbook 3 — Kerberos via KDC Proxy</summary>

Server:
```powershell
$kdcName = 'fs.contoso.com'; $thumb = '<SHA1 of cert with SAN fs.contoso.com>'; $guid = [guid]::NewGuid()
netsh http add urlacl url=https://+:443/KdcProxy user="NT authority\Network Service"
netsh http add sslcert hostnameport="$($kdcName):443" certhash=$thumb appid="{$guid}" certstorename=MY
New-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\KPSSVC\Settings -Name HttpsClientAuth -Type DWord -Value 0 -Force
New-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\KPSSVC\Settings -Name DisallowUnprotectedPasswordAuth -Type DWord -Value 0 -Force
Set-Service kpssvc -StartupType Automatic; Start-Service kpssvc
New-NetFirewallRule -DisplayName 'KDC Proxy (TCP 443 In)' -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow
```
Client policy: **System > Kerberos > Specify KDC proxy servers for Kerberos clients** — Enabled; value name = AD DNS domain (`contoso.com`), value = `<https fs.contoso.com:443:kdcproxy />`. Deploy via GPO for hybrid-joined devices or Intune (Settings catalog / ADMX) for cloud-managed devices.

Validate: off-network, `klist purge`, access the share, `klist` shows `krbtgt/CONTOSO.COM` and `cifs/fs.contoso.com`.
Rollback: `Stop-Service kpssvc; Set-Service kpssvc -StartupType Disabled; netsh http delete sslcert hostnameport=fs.contoso.com:443; netsh http delete urlacl url=https://+:443/KdcProxy`, remove client policy.
Conflict: WAC gateway on TCP 443 on this server → rerun the WAC MSI and choose a different port.
</details>

<details><summary>Playbook 4 — Enable client access control (device allow-list)</summary>

1. Issue each client a cert with Client Authentication EKU (ADCS template via Intune SCEP/PKCS or autoenrollment) from a CA the server trusts.
2. Client mapping (per device, e.g. Intune remediation script):
   ```powershell
   $cc = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.2' -and $_.Issuer -match 'Contoso Issuing CA' } | Sort-Object NotAfter -Descending | Select-Object -First 1
   New-SmbClientCertificateMapping -Namespace 'fs.contoso.com' -Thumbprint $cc.Thumbprint -StoreName My
   ```
3. Server ACL — prefer ISSUER entries (fewer entries, auto-covers new devices), Block individual leaves when revoking:
   ```powershell
   Grant-SmbClientAccessToServer -Name 'fs.contoso.com' -IdentifierType ISSUER -Identifier 'CN=Contoso Issuing CA, DC=contoso, DC=com'
   Block-SmbClientAccessToServer -Name 'fs.contoso.com' -IdentifierType SHA256 -Identifier '<lost-laptop-sha256>'
   ```
4. Turn on auditing, then enforcement:
   ```powershell
   Set-SmbServerConfiguration -AuditClientCertificateAccess $true -Force
   Set-SmbServerCertificateMapping -Name 'fs.contoso.com' -RequireClientAuthentication $true
   ```
5. Validate with SMBServer/Audit 3007–3009 and client 30831.

Rollback: `Set-SmbServerCertificateMapping -Name 'fs.contoso.com' -RequireClientAuthentication $false`.
</details>

<details><summary>Playbook 5 — Network blocks UDP 443: alternative port</summary>

Requires Server 2025 and Windows 11 24H2+.
```powershell
# Server
New-SmbServerAlternativePort -TransportType QUIC -Port 8443 -EnableInstances Default
New-NetFirewallRule -DisplayName 'SMB over QUIC (UDP 8443 In)' -Direction Inbound -Protocol UDP -LocalPort 8443 -Action Allow
# Client
New-SmbMapping -LocalPath 'S:' -RemotePath '\\fs.contoso.com\share' -TransportType QUIC -QuicPort 8443 -Persistent $true
```
Trade-off: non-standard UDP ports are *more* often blocked on guest networks than 443; use only where a specific network blocks 443 but allows the alternative. Clients can also be restricted from using alternative ports by policy — see the Learn page below.
</details>

---

## Evidence Pack

```powershell
<# Collect SMB over QUIC evidence. Run elevated on the file server; optionally on a client with -Client. #>
param([switch]$Client, [string]$Out = "C:\Temp\SmbQuicEvidence_$(Get-Date -Format yyyyMMdd_HHmmss)")
New-Item -ItemType Directory -Path $Out -Force | Out-Null
if (-not $Client) {
  Get-SmbServerConfiguration | Out-File "$Out\SmbServerConfiguration.txt"
  Get-SmbServerCertificateMapping | Format-List * | Out-File "$Out\ServerCertMappings.txt"
  Get-SmbServerCertificateMapping | ForEach-Object {
    Get-Item "Cert:\LocalMachine\My\$($_.Thumbprint)" -ErrorAction SilentlyContinue |
      Select-Object Thumbprint, Subject, NotBefore, NotAfter, HasPrivateKey, @{n='SAN';e={$_.DnsNameList.Unicode -join ','}}, @{n='EKU';e={$_.EnhancedKeyUsageList.FriendlyName -join ','}}
  } | Format-List | Out-File "$Out\MappedCerts.txt"
  Get-SmbServerAlternativePort -ErrorAction SilentlyContinue | Out-File "$Out\AltPorts.txt"
  Get-SmbClientAccessToServer -ErrorAction SilentlyContinue | Out-File "$Out\ClientAccessACL.txt"
  Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object LocalPort -in 443 | Out-File "$Out\UdpEndpoints.txt"
  Get-Service kpssvc -ErrorAction SilentlyContinue | Out-File "$Out\KpsSvc.txt"
  netsh http show urlacl | Out-File "$Out\urlacl.txt"
  netsh http show sslcert | Out-File "$Out\sslcert.txt"
  Get-NetFirewallRule -Enabled True -Direction Inbound | Get-NetFirewallPortFilter | Where-Object { $_.LocalPort -contains '443' } |
    Get-NetFirewallRule | Select-Object DisplayName, Profile, Action | Out-File "$Out\Firewall443.txt"
  foreach ($log in 'Microsoft-Windows-SMBServer/Audit','Microsoft-Windows-SMBServer/Operational','Microsoft-Windows-SMBServer/Connectivity') {
    $f = ($log -replace '[/\\]','_') + '.evtx'; wevtutil epl $log "$Out\$f" 2>$null }
} else {
  Get-SmbClientConfiguration | Out-File "$Out\SmbClientConfiguration.txt"
  Get-SmbClientCertificateMapping -ErrorAction SilentlyContinue | Out-File "$Out\ClientCertMappings.txt"
  Get-SmbConnection | Out-File "$Out\SmbConnections.txt"
  klist | Out-File "$Out\klist.txt"
  Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\KdcProxy\ProxyServers' -ErrorAction SilentlyContinue | Out-File "$Out\KdcProxyPolicy.txt"
  foreach ($log in 'Microsoft-Windows-SMBClient/Connectivity','Microsoft-Windows-SMBClient/Security','Microsoft-Windows-SMBClient/Operational') {
    $f = ($log -replace '[/\\]','_') + '.evtx'; wevtutil epl $log "$Out\$f" 2>$null }
}
Compress-Archive -Path "$Out\*" -DestinationPath "$Out.zip" -Force
Write-Host "Evidence: $Out.zip"
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| Server QUIC on/off | `Set-SmbServerConfiguration -EnableSMBQUIC $true -Force` |
| Client QUIC on/off | `Set-SmbClientConfiguration -EnableSMBQUIC $true -Force` |
| List server cert mappings | `Get-SmbServerCertificateMapping` |
| Create mapping | `New-SmbServerCertificateMapping -Name <fqdn> -Thumbprint <sha1> -StoreName My` |
| Re-point after renewal | `Set-SmbServerCertificateMapping -Name <fqdn> -Thumbprint <newsha1> -StoreName My` |
| Force QUIC mapping | `New-SmbMapping -RemotePath \\<fqdn>\<share> -TransportType QUIC` |
| Force QUIC (cmd) | `NET USE * \\<fqdn>\<share> /TRANSPORT:QUIC` |
| Alt port (server) | `New-SmbServerAlternativePort -TransportType QUIC -Port <p> -EnableInstances Default` |
| Alt port (client) | `New-SmbMapping ... -TransportType QUIC -QuicPort <p>` |
| Client exception list | `Set-SmbClientConfiguration -DisabledSMBQUICServerExceptionList '<fqdn>'` |
| Client access ACL | `Get-SmbClientAccessToServer` / `Grant-` / `Block-` / `Revoke-` / `Unblock-SmbClientAccessToServer` |
| Require client certs | `Set-SmbServerCertificateMapping -Name <fqdn> -RequireClientAuthentication $true` |
| Client cert mapping | `New-SmbClientCertificateMapping -Namespace <fqdn> -Thumbprint <sha1> -StoreName My` |
| SHA256 of a cert | `$cert.GetCertHashString('SHA256')` |
| Audit on | `Set-SmbServerConfiguration -AuditClientCertificateAccess $true -Force` |
| Who owns UDP 443 | `Get-NetUDPEndpoint -LocalPort 443` |

---

## 🎓 Learning Pointers
- The authoritative deployment/renewal reference: [SMB over QUIC — Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-over-quic). Note the "Windows Server 2025 = PowerShell only" callout before reaching for WAC.
- Device allow-listing and the Block-beats-Grant chain logic: [Configure SMB over QUIC client access control](https://learn.microsoft.com/en-us/windows-server/storage/file-server/configure-smb-over-quic-client-access-control).
- Ports: [Configure alternative SMB ports](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-ports) — only the QUIC listening port is changeable server-side.
- NTLM inside the tunnel will increasingly collide with NTLM-off hardening — read [SMB security hardening](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-security-hardening) and this repo's `NTLM-A.md`; plan KDC Proxy from day one.
- Treat an internet-facing SMB over QUIC endpoint like any other internet auth surface: fine-grained password policy for mobile users, lockout monitoring, and MFA-capable sign-in (WHfB / smart cards) as Microsoft recommends.
- Protocol background: [MsQuic on GitHub](https://github.com/microsoft/msquic) (the QUIC stack Windows uses) and RFC 9000/9001.
