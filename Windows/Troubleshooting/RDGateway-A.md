# RD Gateway (Remote Desktop Gateway / TSGateway) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.
> Hotfix: `RDGateway-B.md` · Script: `../Scripts/Get-RDGatewayDiagnostics.ps1` · Related: `RDP-A.md`, `RDSLicensing-A.md`, `NPS-RADIUS-A.md`, `RDSDeadlockSept2026-A.md`

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
- **In scope:** the RD Gateway role service (`RDS-Gateway`, service `TSGateway`) on Windows Server 2016/2019/2022/2025; standalone or as part of a Connection Broker deployment; local or central NPS policy store; NPS Extension for Entra MFA; HTTP and UDP transports; certificates; load balancing; WAF/reverse proxy interactions.
- **Out of scope:** target-side RDP failures (`RDP-A.md`), RDS CAL issues (`RDSLicensing-A.md`), NPS internals beyond RD Gateway (`NPS-RADIUS-A.md`), AVD (which uses its own Microsoft-managed gateway — `../../Azure/AVD/`).
- **Assumes:** domain-joined gateway, AD user accounts, admin on gateway and (for central NPS) the NPS server. `RemoteDesktopServices` module present (installed with the role's management tools).
- **Security framing:** RD Gateway is internet-facing and has had critical RCEs (e.g. CVE-2020-0609/0610 in the UDP transport). Patch cadence and exposure matter as much as config — see `RDSDeadlockSept2026-A.md` for the September 2026 patch trade-off.

---
## How It Works
<details><summary>Full architecture</summary>

### Components
| Component | Role |
|---|---|
| **TSGateway** service | Terminates client tunnels, enforces CAP/RAP, relays RDP to target on 3389 |
| **IIS / HTTP.sys** | Hosts the `/rpc` (legacy RPC-over-HTTP) and `/remoteDesktopGateway` (HTTP transport) endpoints on 443 |
| **NPS (IAS service)** | Stores and evaluates **RD CAPs** (connection authorization) as network policies. Local by default, or central |
| **RD RAP store** | Resource authorization policies, stored locally on the gateway (never on NPS) |
| **Gateway-managed computer groups** | Name lists used by RAPs as an alternative to AD computer groups |
| **UDP listener (3391)** | Optional datagram transport for the RDP stream (better perf on lossy links) |

### Connection sequence
```
Client (mstsc / Remote Desktop app / RDP file)
  │ 1. DNS resolve gateway FQDN → TCP 443
  │ 2. TLS handshake — cert SAN must match the gateway hostname the client uses
  │ 3. HTTP transport: two long-lived channels (RDG_OUT_DATA / RDG_IN_DATA)
  │    (fallback: RPC-over-HTTP /rpc on older clients)
  │ 4. User authenticates (NTLM / Kerberos / smart card / cookie from RDWeb)
  ▼                                                 Event 200 (authenticated)
RD Gateway ──► NPS: evaluate RD CAP  ──(RADIUS if central)──► Central NPS (+ MFA ext)
  │     pass → continue       fail → Event 201
  │ 5. RAP check: requested resource name ∈ RAP computer group?  fail → Event 301
  │ 6. Gateway opens TCP 3389 to target                          fail → Event 304
  │                                                              ok   → Event 302
  │ 7. Optional: client negotiates UDP 3391 side channel
  │ 8. RDP (CredSSP/NLA, then session) flows *inside* the tunnel end-to-end
  ▼
Target RDSH / workstation                          Disconnect → Event 303 (bytes, duration)
```

Key subtleties:
- **Two authentications.** The user authenticates to the *gateway* (step 4) and then, separately, to the *target* via CredSSP (step 8). mstsc can reuse credentials ("Use my RD Gateway credentials for the remote computer"), which hides the distinction until the passwords or accounts differ.
- **CAP is NPS policy.** When you create a CAP in RD Gateway Manager, it's written as an NPS Network Policy with the NAS-Port-Type "Virtual (VPN)" and a Windows-Groups condition. Editing it in the NPS console is possible but can make RD Gateway Manager unable to display it — edit CAPs where you created them.
- **Central NPS.** When the gateway is configured to use a central NPS server, it becomes a RADIUS client; the local Connection Request Policy forwards to a Remote RADIUS Server Group. Local CAPs are then **ignored**. This is the required topology for the NPS Extension for Entra MFA (the extension should be on a dedicated NPS, not the gateway itself).
- **RAP matching** is string-based against what the client requested. `server01`, `server01.contoso.local` and `10.0.0.5` are three different resources to a gateway-managed group. AD computer groups match on the computer account, so FQDN and NetBIOS usually both resolve, IPs do not.
- **UDP 3391** is optional; if it is advertised but broken mid-path, clients can connect (TCP channel succeeds) and then freeze or show a black screen when the stream shifts to UDP.
- **Connection Broker deployments** manage the gateway cert (`Set-RDCertificate -Role RDGateway`) and publish `gatewayhostname` into RemoteApp/desktop RDP files — a manual cert change on the gateway alone drifts from the deployment.

### Transports & ports
| Port | Proto | Purpose |
|---|---|---|
| 443 | TCP | HTTPS tunnel (mandatory) |
| 3391 | UDP | UDP transport (optional) |
| 3389 | TCP | Gateway → target (internal) |
| 1812/1813 | UDP | Gateway → central NPS (RADIUS) |
| 88/389/445 etc. | — | Gateway → DCs for authentication & group lookup |

### Load balancing
Multiple gateways form a **server farm** (RD Gateway Manager > Server Farm). The HTTP transport's in/out channels must reach the same node → LB with source-IP affinity (or cookie-based on L7). The UDP channel must also be affinitised. All farm members need the same cert and identical CAP/RAP config (central NPS solves CAP drift; RAPs must be kept in sync manually or via export/import).

### WAFs / reverse proxies
RD Gateway uses non-standard HTTP methods (`RDG_OUT_DATA`, `RDG_IN_DATA`) and long-lived chunked connections. Generic WAFs, SSL-inspection firewalls and some CDNs reject or time these out → connection hangs at "Initiating remote connection". Use vendor-specific RDG templates or bypass.
</details>

---
## Dependency Stack
```
[9] User productive in remote session
[8] Target host: RDP enabled, NLA/CredSSP, Remote Desktop Users, licensing (RDSLicensing-A)
[7] Gateway → target TCP 3389 + internal DNS
[6] RD RAP: requested name in allowed group, allowed port
[5] RD CAP: NPS (local/central) allows user's group; MFA extension approves within RADIUS timeout
[4] Gateway auth: NTLM/Kerberos/smart card to AD; DCs reachable from gateway
[3] TSGateway + IIS/HTTP.sys endpoints up; cert bound (RDS:\...\SSLCertificate = HTTP.sys binding)
[2] TLS: cert valid, SAN = FQDN, chain + CRL reachable by clients
[1] Network: public DNS → WAF/LB (affinity, RDG methods allowed) → gateway TCP 443 (+UDP 3391)
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| "Gateway server address is unreachable or incorrect" | DNS, firewall, TSGateway down, WAF blocking | `Test-NetConnection -Port 443`, service state, bypass WAF |
| "Certificate has expired or has been revoked" | Expired cert or client can't reach CRL | Cert `NotAfter`, `certutil -url` on client |
| "Name mismatch" / "not trusted" warning | SAN ≠ typed FQDN; internal CA on unmanaged clients | Cert SAN list, RDP file `gatewayhostname` |
| "Your user account is not authorized to access the RD Gateway" | CAP (Event 201) | CAP groups, AuthMethod, central NPS 6273 |
| Hangs ~30-60 s then CAP failure with MFA | RADIUS timeout too short / MFA extension error | Remote RADIUS group timeout, AuthNOptCh log |
| "...cannot connect to the remote computer" + Event 301 | RAP doesn't include name/port | RAP computer groups, name as typed |
| Event 304 | Target 3389 blocked / RDP disabled / user not allowed | `Test-NetConnection` from gateway, target config |
| Connects, black screen / freezes after seconds | UDP 3391 broken mid-path, MTU | `fClientDisableUDP` test |
| Works internally, fails externally | Split DNS, internal-only cert, LB affinity | Compare paths |
| Intermittent failures in a farm | LB without affinity; RAP/cert drift between nodes | Run script against every node, diff |
| Works via RDWeb, fails via saved RDP file | Stale `gatewayhostname` or credential settings in old file | Open RDP file in text editor |
| Stopped after a Windows Update | Patch regression (see `RDSDeadlockSept2026-A.md`, `KnownIssueRollback-A.md`) | Update history vs failure start |

---
## Validation Steps
1. **Role & service**
   `Get-WindowsFeature RDS-Gateway` → `Installed`. `Get-Service TSGateway` → `Running`.
   Bad: feature installed, service stopped with System log 7023/7024 → check IIS/HTTP.sys conflicts.
2. **Certificate binding consistency**
   ```powershell
   $tp = (Get-Item RDS:\GatewayServer\SSLCertificate\Thumbprint).CurrentValue
   netsh http show sslcert ipport=0.0.0.0:443
   ```
   Good: "Certificate Hash" = `$tp`, cert `NotAfter` > 30 days. Bad: different hash (IIS rebound), expired, or missing private key.
3. **Policy store**
   `(Get-Item RDS:\GatewayServer\CentralCAPEnabled).CurrentValue` → 0 local / 1 central. Good: matches the documented design.
4. **CAP/RAP enabled and non-empty**
   `Get-ChildItem RDS:\GatewayServer\CAP`, `...\RAP` — at least one each with `Status = 1`.
5. **Client path**
   `Test-NetConnection <fqdn> -Port 443` → `TcpTestSucceeded : True`; browser to `https://<fqdn>/rpc` → auth prompt with no cert warning.
6. **End-to-end**
   Successful connection produces 200 → 302 in the Operational log for the user; disconnect produces 303 with non-trivial byte counts.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Reachability (before any event is logged).** If there are no gateway events for the attempt, the problem is DNS/network/TLS/WAF. Test from outside the network (mobile hotspot). Check that the LB health probe isn't marking the node down, and that the WAF is not stripping RDG methods.

**Phase 2 — TLS.** Clients validate the chain and revocation. Unmanaged BYOD devices won't trust an internal CA. Check the CRL/OCSP URLs in the cert are reachable from the internet (`certutil -verify -urlfetch <cert.cer>`).

**Phase 3 — Gateway authentication (Event 200 absent, 201 present or auth prompts loop).** Account lockout, password expired (gateway cannot do password change), NTLM restricted on the gateway (`NTLM-A.md` — RDG commonly relies on NTLM from external clients), smart-card-only CAP.

**Phase 4 — CAP (Event 201).** Read the error code, then compare the user's group membership to CAP groups. With central NPS, the authoritative record is on the NPS server (Security 6272 grant / 6273 deny with Reason Code). With the MFA extension, also check the extension logs and that the RADIUS timeout is ≥ 60 s.

**Phase 5 — RAP (Event 301).** Resource name as recorded in the event vs RAP membership; allowed ports.

**Phase 6 — Resource (Event 304).** Network gateway → target; target RDP config; then hand off to `RDP-A.md`.

**Phase 7 — Session quality.** UDP, MTU, idle/session timeouts (RD Gateway has its own idle and session timeouts in Properties > Timeouts, separate from RDSH session limits), device-redirection restrictions set in the CAP (clipboard/drive redirection "not working" can be CAP-enforced).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Certificate renewal (standalone and deployment)</summary>

```powershell
Import-Module RemoteDesktopServices
$fqdn = '<gateway.fqdn>'
$old  = (Get-Item RDS:\GatewayServer\SSLCertificate\Thumbprint).CurrentValue
$new  = Get-ChildItem Cert:\LocalMachine\My | Where { $_.DnsNameList.Unicode -contains $fqdn -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) } | Sort NotAfter -Desc | Select -First 1
if (-not $new) { throw "No valid cert with SAN $fqdn and private key" }
# Standalone:
Set-Item RDS:\GatewayServer\SSLCertificate\Thumbprint -Value $new.Thumbprint
Restart-Service TSGateway
# Deployment (run on/against broker instead):
# Set-RDCertificate -Role RDGateway -Thumbprint $new.Thumbprint -ConnectionBroker <broker.fqdn> -Force
netsh http show sslcert ipport=0.0.0.0:443
```
Farm: repeat on every node (import PFX with private key first). Rollback: `Set-Item ... -Value $old; Restart-Service TSGateway`.
</details>

<details><summary>Playbook 2 — Move CAPs to central NPS with Entra MFA extension</summary>

1. Build a dedicated NPS server (do not install the MFA extension on the gateway itself — it would apply MFA to all RADIUS on that NPS).
2. On the gateway: RD Gateway Manager > Properties > RD CAP Store > "Central server running NPS" → add NPS server + shared secret. This sets `CentralCAPEnabled = 1` and creates the forwarding Connection Request Policy.
3. On the gateway's NPS: Remote RADIUS Server Groups > "TS GATEWAY SERVER GROUP" > server > Load Balancing → **Number of seconds without response before request is considered dropped: 60** (and the related "between requests" value to 60).
4. On central NPS: add gateway as RADIUS client; recreate the CAP as a network policy (or export/import). Connection Request Policy authenticates locally.
5. Install the NPS Extension, run `AzureMfaNpsExtnConfigSetup.ps1` with the tenant ID.
6. Test with a pilot group; watch 6272/6273 on NPS and the AuthNOptCh/AuthZOptCh logs.
Rollback: switch CAP store back to "Local server running NPS" (local CAPs are still there unless deleted).
</details>

<details><summary>Playbook 3 — Harden a legacy gateway</summary>

- Replace "any network resource" RAPs (`ComputerGroupType = 2`) with AD or gateway-managed groups.
- CAP: restrict to a dedicated "RDG Users" group; consider smart-card or MFA-only.
- Disable device redirection in the CAP where data exfiltration is a concern (drive, clipboard).
- Set idle timeout and session timeout (Properties > Timeouts).
- Disable UDP if not needed (attack surface; historic UDP RCEs).
- Keep TLS 1.2+ only via SCHANNEL settings (test older clients first).
- Monitor 201/301 spikes — they are credential-spray indicators.
</details>

<details><summary>Playbook 4 — Export / rebuild / migrate gateway</summary>

1. RD Gateway Manager > server > **Export policy and settings** → XML (includes CAPs if local, RAPs, gateway-managed groups, settings).
2. Export cert as PFX.
3. New server: `Install-WindowsFeature RDS-Gateway -IncludeManagementTools`, import PFX, **Import policy and settings**.
4. Set cert thumbprint (Playbook 1), update DNS/LB.
Rollback: repoint DNS/LB to the old node (keep it running until validated).
</details>

---
## Evidence Pack
```powershell
# Run elevated on each RD Gateway node. Output: C:\Temp\RDG-Evidence-<host>-<ts>\
$ts  = Get-Date -Format yyyyMMdd-HHmmss
$out = "C:\Temp\RDG-Evidence-$env:COMPUTERNAME-$ts"
New-Item $out -ItemType Directory -Force | Out-Null
Import-Module RemoteDesktopServices -ErrorAction SilentlyContinue
Get-Service TSGateway, IAS, W3SVC | Select Name, Status, StartType | Export-Csv "$out\services.csv" -NoTypeInformation
Get-ChildItem RDS:\GatewayServer -Recurse -ErrorAction SilentlyContinue | Where { $_.PSObject.Properties['CurrentValue'] } |
  Select PSPath, CurrentValue | Export-Csv "$out\rdg-config.csv" -NoTypeInformation
netsh http show sslcert > "$out\httpsys-sslcert.txt"
netsh http show urlacl  > "$out\httpsys-urlacl.txt"
netsh nps export filename="$out\nps-config.xml" exportPSK=NO | Out-Null
Get-ChildItem Cert:\LocalMachine\My | Select Subject, Thumbprint, NotAfter, HasPrivateKey, @{n='SAN';e={$_.DnsNameList -join ','}} | Export-Csv "$out\certs.csv" -NoTypeInformation
Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-Gateway/Operational' -MaxEvents 2000 -ErrorAction SilentlyContinue |
  Select TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\rdg-operational.csv" -NoTypeInformation
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=6272,6273; StartTime=(Get-Date).AddDays(-2)} -ErrorAction SilentlyContinue |
  Select TimeCreated, Id, Message | Export-Csv "$out\nps-6272-6273.csv" -NoTypeInformation
Get-HotFix | Sort InstalledOn -Desc | Select -First 15 | Export-Csv "$out\hotfix.csv" -NoTypeInformation
Compress-Archive "$out\*" "$out.zip" -Force
"Evidence: $out.zip"
```
`exportPSK=NO` keeps RADIUS shared secrets out of the export — keep it that way when sending to third parties.

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| Service state | `Get-Service TSGateway, IAS` |
| Load provider | `Import-Module RemoteDesktopServices; cd RDS:\GatewayServer` |
| Bound cert | `(Get-Item RDS:\GatewayServer\SSLCertificate\Thumbprint).CurrentValue` |
| HTTP.sys binding | `netsh http show sslcert ipport=0.0.0.0:443` |
| List CAPs | `Get-ChildItem RDS:\GatewayServer\CAP` |
| List RAPs | `Get-ChildItem RDS:\GatewayServer\RAP` |
| CAP store central? | `(Get-Item RDS:\GatewayServer\CentralCAPEnabled).CurrentValue` |
| Recent gateway events | `Get-WinEvent 'Microsoft-Windows-TerminalServices-Gateway/Operational' -MaxEvents 50` |
| Current connections | `Get-CimInstance -Namespace root/cimv2/TerminalServices -ClassName Win32_TSGatewayConnection` |
| NPS denies | `Get-WinEvent -FilterHashtable @{LogName='Security';Id=6273} -MaxEvents 20` |
| Client reachability | `Test-NetConnection <fqdn> -Port 443` |
| Gateway → target | `Test-NetConnection <target> -Port 3389` |
| Set cert (deployment) | `Set-RDCertificate -Role RDGateway -Thumbprint <tp> -ConnectionBroker <cb> -Force` |
| Disable client UDP (test) | `Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client' fClientDisableUDP 1` |
| Export NPS config | `netsh nps export filename=C:\Temp\nps.xml exportPSK=NO` |

---
## 🎓 Learning Pointers
- CAP vs RAP is "who" vs "what". Once you map every failure to one of 201/301/304, RD Gateway stops being mysterious. [RD Gateway events reference](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2008-r2-and-2008/ee891047(v=ws.10))
- The MFA extension topology (gateway → central NPS → Entra) and its 60 s timeout are documented step-by-step: [Integrate RD Gateway with the NPS extension](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-mfa-nps-extension-rdg)
- Deployment-managed certs: always use `Set-RDCertificate` in a broker deployment, or RDWeb, broker and gateway drift apart. [RDS certificates](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/rds-roles)
- Monitoring 201/301 is cheap threat detection for an internet-facing service — RDPSoft's write-up on CAP/RAP failure monitoring explains why.
- Consider whether an on-prem gateway is still the right answer: Entra Private Access (`GlobalSecureAccess-Windows-A.md`) and Windows 365/AVD remove inbound 443 entirely.
- NPS reason codes behind CAP denials live in `NPS-RADIUS-A.md`; NTLM restriction side-effects on RDG in `NTLM-A.md`.
