# SMB over QUIC — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

**Scope:** Windows 11 clients mapping shares over the internet from a Windows Server 2025 (any edition) or Windows Server 2022 Datacenter: Azure Edition file server using SMB over QUIC (UDP/443, TLS 1.3). Classic SMB/TCP 445 problems → `SMB-B.md`. Deep dive → `SMBoverQUIC-A.md`. Audit script → `../Scripts/Get-SmbOverQuicHealth.ps1`.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Run on the **file server** (1–3) and the **affected client** (4–5). 60 seconds.

```powershell
# 1. SERVER: is QUIC enabled and is a certificate mapped?
Get-SmbServerConfiguration | Select-Object EnableSMBQUIC, AuditClientCertificateAccess
Get-SmbServerCertificateMapping | Format-Table Name, Thumbprint, StoreName, Type, RequireClientAuthentication, SkipClientCertificateAccessCheck -AutoSize

# 2. SERVER: does every mapped thumbprint exist, unexpired, with a private key?
Get-SmbServerCertificateMapping | ForEach-Object {
  $c = Get-Item "Cert:\LocalMachine\My\$($_.Thumbprint)" -ErrorAction SilentlyContinue
  [pscustomobject]@{ Name=$_.Name; Found=[bool]$c; NotAfter=$c.NotAfter; HasKey=$c.HasPrivateKey
    SAN=($c.DnsNameList.Unicode -join ',') }
}

# 3. SERVER: is anything listening on UDP 443 (or the alternative port)?
Get-NetUDPEndpoint -LocalPort 443 -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, OwningProcess
Get-SmbServerAlternativePort -ErrorAction SilentlyContinue

# 4. CLIENT: QUIC enabled + force a QUIC-only mapping (bypasses the TCP-first attempt)
Get-SmbClientConfiguration | Select-Object EnableSMBQUIC, DisabledSMBQUICServerExceptionList
New-SmbMapping -RemotePath '\\<fs-public-fqdn>\<share>' -TransportType QUIC

# 5. CLIENT: what did the connection attempt log?
Get-WinEvent -LogName 'Microsoft-Windows-SMBClient/Connectivity' -MaxEvents 20 |
  Format-Table TimeCreated, Id, LevelDisplayName, @{n='Msg';e={$_.Message.Split("`n")[0]}} -AutoSize -Wrap
```

| Result | Meaning | Go to |
|---|---|---|
| `EnableSMBQUIC` = False on server | Feature switched off (or never configured) | Fix 1 |
| No rows from `Get-SmbServerCertificateMapping` | QUIC has nothing to present — no listener | Fix 1 |
| Mapped thumbprint `Found=False` or `NotAfter` in the past | Certificate was renewed/replaced — **new thumbprint, mapping still points at the old one** | Fix 2 |
| `HasKey=False` | Imported cert without private key | Fix 2 |
| Mapping `Name` not in cert SAN, or client uses a name not in any mapping | Name mismatch — TLS fails | Fix 3 |
| No UDP 443 endpoint on server | Listener not bound (no mapping / port clash / alternative port in use) | Fix 1 / Fix 5 |
| Server fine, client `EnableSMBQUIC` False | Client-side disable (GPO / script) | Fix 4 |
| QUIC mapping works from phone hotspot, fails from office/hotel | Upstream network blocks outbound UDP 443 | Fix 5 |
| Connects, then "access denied" / credential prompt loop | Auth: NTLM blocked on client or Kerberos unreachable (no KDC Proxy) | Fix 6 |
| `RequireClientAuthentication` True and client denied | Client access control: cert not granted / blocked / not mapped on client | Fix 7 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
User maps \\fs.contoso.com\share over the internet
│
├── 1. Client
│   ├── Windows 11 (QUIC client built in); EnableSMBQUIC = True
│   ├── Name used == a SAN on the server cert == a server certificate mapping Name
│   ├── DNS (public) resolves that FQDN to the server's public IP (never use IP)
│   ├── Trusts the server cert's issuing root (public CA or pushed enterprise root)
│   └── Outbound UDP 443 (or alt port) allowed by whatever network it sits on
│
├── 2. Network edge
│   ├── Inbound UDP 443 → file server allowed (NAT/port-forward if needed)
│   └── TCP 445 inbound NOT exposed (by design)
│
├── 3. File server
│   ├── Server 2025 (any edition) or 2022 Datacenter: Azure Edition
│   ├── EnableSMBQUIC = True
│   ├── Cert in LocalMachine\My: Server Auth EKU, private key, SAN = public FQDN(s), in date
│   ├── SmbServerCertificateMapping per FQDN → that cert's thumbprint
│   └── Windows Firewall allows inbound UDP 443 on the public-facing profile
│
├── 4. Authentication (inside the TLS 1.3 tunnel)
│   ├── Default: NTLMv2 (server talks to DC on client's behalf)
│   │     └── breaks if client BlockNTLM / NTLM restrictions are on
│   └── Recommended: Kerberos via KDC Proxy (KPSSVC on HTTPS 443/TCP) + client KDC proxy GPO
│
└── 5. Optional: client access control
    ├── RequireClientAuthentication = True on the mapping
    ├── Client has Client-Auth cert + New-SmbClientCertificateMapping for the FQDN
    └── Grant-SmbClientAccessToServer (SHA256 leaf or ISSUER) and no Block entry in chain
```
</details>

---

## Diagnosis & Validation Flow

1. **Confirm the transport actually in use.**
   ```powershell
   Get-SmbConnection | Select-Object ServerName, ShareName, Dialect, Encrypted
   Get-SmbMultichannelConnection -ErrorAction SilentlyContinue
   ```
   Expected: a connection to the public FQDN exists. Clients try **TCP first**, then QUIC — inside the office a mapping will quietly use TCP 445. Always test with `-TransportType QUIC` (or `NET USE ... /TRANSPORT:QUIC`) from an **external** network before declaring QUIC healthy.

2. **Check the certificate chain from the client's point of view.**
   ```powershell
   # On client: does the name resolve publicly and is UDP reachable? (TNC can't test UDP - use the mapping itself)
   Resolve-DnsName <fs-public-fqdn> -Type A
   ```
   Expected: public IP of the edge/NAT. Internal IP or NXDOMAIN → split-brain DNS / missing public record.

3. **Server certificate mapping vs certificate store.** Run Triage 2. Every mapping must resolve to a present, in-date cert with a private key and matching SAN. A renewal (even ADCS autoenrollment) produces a **new thumbprint** and does **not** update the mapping.

4. **Server listener.** Triage 3. No UDP 443 endpoint while mapping exists → port conflict or firewall/service problem; check System/SMBServer event logs and whether an alternative port was configured.

5. **Client event evidence.** `Microsoft-Windows-SMBClient/Connectivity` — event **30832** (QUIC connection audit, Win 11 24H2+) and **30831** (client access control). Server side (if auditing on): `Microsoft-Windows-SMBServer/Audit` **3007 / 3008 / 3009**.

6. **Authentication.** Connected but denied → check client `Get-SmbClientConfiguration | Select BlockNTLM` and whether the KDC Proxy is configured (see Fix 6).

---

## Common Fix Paths

<details><summary>Fix 1 — QUIC not enabled / no certificate mapping on the server</summary>

```powershell
# On the file server (elevated). Pick the cert whose SAN contains the public FQDN.
$fqdn = '<fs-public-fqdn>'
$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
  $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and ($_.DnsNameList.Unicode -contains $fqdn) } |
  Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) { throw "No valid cert with SAN $fqdn and private key" }

New-SmbServerCertificateMapping -Name $fqdn -Thumbprint $cert.Thumbprint -StoreName My
Set-SmbServerConfiguration -EnableSMBQUIC $true -Force

# Firewall: allow inbound UDP 443 (scope the profile to what the public NIC uses)
New-NetFirewallRule -DisplayName 'SMB over QUIC (UDP 443 In)' -Direction Inbound -Protocol UDP -LocalPort 443 -Action Allow
```
Add one mapping per FQDN clients use (e.g. `fs.contoso.com` **and** `fs` short name only if you really want it). On **Server 2025, use PowerShell** — the WAC SMB over QUIC wizard is not supported there.

Rollback: `Remove-SmbServerCertificateMapping -Name $fqdn` and/or `Set-SmbServerConfiguration -EnableSMBQUIC $false -Force`.
</details>

<details><summary>Fix 2 — Certificate renewed/expired: mapping points at an old thumbprint</summary>

```powershell
$fqdn = '<fs-public-fqdn>'
$new  = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
  $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and ($_.DnsNameList.Unicode -contains $fqdn) } |
  Sort-Object NotAfter -Descending | Select-Object -First 1
Get-SmbServerCertificateMapping -Name $fqdn | Format-List Name, Thumbprint   # record old value for rollback
Set-SmbServerCertificateMapping -Name $fqdn -Thumbprint $new.Thumbprint -StoreName My
```
If `Set-` complains, remove and recreate: `Remove-SmbServerCertificateMapping -Name $fqdn -Force; New-SmbServerCertificateMapping -Name $fqdn -Thumbprint $new.Thumbprint -StoreName My`.
**Prevent recurrence:** schedule `Get-SmbOverQuicHealth.ps1` (flags mappings expiring < 30 days / orphaned thumbprints) — every renewal needs a remap.
Rollback: re-point at the old thumbprint (only useful if it is still valid).
</details>

<details><summary>Fix 3 — Name mismatch (SAN / mapping / what the user typed)</summary>

The client name must match **a SAN on the cert** and **a mapping Name**. Do **not** use an IP address — it forces NTLM and does not work through NAT (Azure IaaS included).

```powershell
# Server: list SANs for each mapped cert vs mapping name
Get-SmbServerCertificateMapping | ForEach-Object {
  $c = Get-Item "Cert:\LocalMachine\My\$($_.Thumbprint)"
  [pscustomobject]@{ Mapping=$_.Name; SANs=($c.DnsNameList.Unicode -join ', '); Match=($c.DnsNameList.Unicode -contains $_.Name) } }
```
Fix: reissue cert with the correct SAN(s) **or** add a mapping for the name users actually use; fix drive-map scripts/GPP to the FQDN in the SAN.
</details>

<details><summary>Fix 4 — Client has SMB over QUIC disabled</summary>

```powershell
# Client (elevated)
Set-SmbClientConfiguration -EnableSMBQUIC $true -Force
# If policy disables QUIC but one server must be allowed:
Set-SmbClientConfiguration -DisabledSMBQUICServerExceptionList '<fs-public-fqdn>' -Force
```
If it flips back, a GPO/Intune setting is enforcing it — `gpresult /h C:\Temp\gp.html` and search for "SMB over QUIC"; fix at the source.
</details>

<details><summary>Fix 5 — UDP 443 blocked upstream / port clash → use alternative port</summary>

Test from a phone hotspot first. If that works, the user's network filters UDP 443 (common in hotels, guest Wi-Fi, some corporate egress proxies). Options: a different network, or an alternative QUIC port (Server 2025 / Win 11 24H2+):

```powershell
# Server
New-SmbServerAlternativePort -TransportType QUIC -Port <altPort> -EnableInstances Default
New-NetFirewallRule -DisplayName 'SMB over QUIC (alt UDP)' -Direction Inbound -Protocol UDP -LocalPort <altPort> -Action Allow
# Client
New-SmbMapping -LocalPath 'S:' -RemotePath '\\<fs-public-fqdn>\<share>' -TransportType QUIC -QuicPort <altPort>
```
Port clash on the server (another UDP 443 listener, e.g. HTTP/3-enabled IIS) → move one of them.
Rollback: `Remove-SmbServerAlternativePort` (check parameters with `Get-Help Remove-SmbServerAlternativePort`) and remove the firewall rule.
</details>

<details><summary>Fix 6 — Tunnel up but authentication fails (NTLM blocked / no KDC Proxy)</summary>

Without line-of-sight to a DC the client uses **NTLMv2** inside the tunnel. If the client blocks NTLM for SMB (`BlockNTLM`) or org NTLM restrictions are on, auth fails.

```powershell
# Client: check
Get-SmbClientConfiguration | Select-Object BlockNTLM, BlockNTLMServerExceptionList
```
Short-term: add the server to the NTLM exception list (`Set-SmbClientConfiguration -BlockNTLMServerExceptionList '<fs-public-fqdn>'`).
Proper fix — **KDC Proxy** on the file server so Kerberos works over HTTPS:
```powershell
# Server (elevated) - cert with SAN for the KDC proxy name
$kdcName = '<fs-public-fqdn>'; $thumb = '<server-cert-thumbprint>'; $guid = [guid]::NewGuid()
netsh http add urlacl url=https://+:443/KdcProxy user="NT authority\Network Service"
netsh http add sslcert hostnameport="$($kdcName):443" certhash=$thumb appid="{$guid}" certstorename=MY
New-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\KPSSVC\Settings -Name HttpsClientAuth -Type DWord -Value 0 -Force
New-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\KPSSVC\Settings -Name DisallowUnprotectedPasswordAuth -Type DWord -Value 0 -Force
Set-Service -Name kpssvc -StartupType Automatic; Start-Service kpssvc
New-NetFirewallRule -DisplayName 'KDC Proxy (TCP 443 In)' -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow
```
Client: GPO/Intune **Computer Configuration > Administrative Templates > System > Kerberos > Specify KDC proxy servers for Kerberos clients** → value name `contoso.com`, value `<https <fs-public-fqdn>:443:kdcproxy />`. Then `klist purge` and remap.
WAC gateway on TCP 443 on the same server conflicts with KDC Proxy — move WAC to another port.
</details>

<details><summary>Fix 7 — Client access control denies the device</summary>

```powershell
# Server: current ACL and mapping flags
Get-SmbClientAccessToServer
Get-SmbServerCertificateMapping | Select-Object Name, RequireClientAuthentication, SkipClientCertificateAccessCheck
# Client: is a client cert mapped for this server name?
Get-SmbClientCertificateMapping
$cc = Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -Match '<client-subject>'
$cc.GetCertHashString('SHA256')     # value the server ACL needs (NOT the SHA1 Thumbprint)
```
Fix (server): `Grant-SmbClientAccessToServer -Name <fs-public-fqdn> -IdentifierType SHA256 -Identifier <sha256>` (or `-IdentifierType ISSUER -Identifier "CN=Contoso Issuing CA, DC=contoso, DC=com"` for a whole CA).
Fix (client): `New-SmbClientCertificateMapping -Namespace <fs-public-fqdn> -Thumbprint $cc.Thumbprint -StoreName My`.
Remember: **any Block entry anywhere in the chain wins** over a Grant. Check `Unblock-SmbClientAccessToServer` if a block is stale.
Emergency bypass (still validates chain, skips ACL): `Set-SmbServerCertificateMapping -Name <fqdn> -SkipClientCertificateAccessCheck $true` — revert afterwards.
</details>

---

## Escalation Evidence

```
SMB over QUIC escalation
------------------------
Ticket #:                     ______
File server / OS build:       ______   (Server 2025 edition / 2022 Azure Edition)
Public FQDN used by clients:  ______   Public IP: ______   NAT/port-forward: Y/N
EnableSMBQUIC (server):       ______
Cert mapping(s) Name → Thumbprint → NotAfter → SAN match:  ______
UDP 443 listener present:     Y/N      Alternative port: ______
Client OS build:              ______   EnableSMBQUIC (client): ______
Test from external network w/ -TransportType QUIC: result/error ______
Works from hotspot but not site X: Y/N
Auth path: NTLM / KDC Proxy     BlockNTLM on client: ______
Client access control: RequireClientAuthentication ______  Get-SmbClientAccessToServer output attached Y/N
Client events (SMBClient/Connectivity 30831/30832) attached: Y/N
Server events (SMBServer/Audit 3007-3009) attached: Y/N
Get-SmbOverQuicHealth.ps1 CSV attached: Y/N
```

---

## 🎓 Learning Pointers
- **Renewal = remap.** The #1 SMB over QUIC outage is a cert renewal: new thumbprint, old mapping, instant failure. See "Certificate expiration and renewal" in [SMB over QUIC](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-over-quic).
- **TCP is tried first.** Testing from inside the LAN proves nothing — always force `-TransportType QUIC` from outside.
- **NTLM inside the tunnel is the default, not the goal.** Pair with KDC Proxy, especially as NTLM blocking rolls out on clients ([SMB security hardening](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-security-hardening)).
- **Client access control** uses **SHA256** hashes on the server ACL but the **SHA1** thumbprint for the client mapping — mixing them up is the usual mistake ([Configure SMB over QUIC client access control](https://learn.microsoft.com/en-us/windows-server/storage/file-server/configure-smb-over-quic-client-access-control)).
- Blocked UDP 443 networks are a real limitation — know the [alternative SMB ports](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-ports) option before promising "works everywhere".
