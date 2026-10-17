# NCSI "No Internet" False Positive — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers the yellow-triangle / globe "No Internet" icon while browsing works, Office/Outlook/Teams/OneDrive/Store claiming "offline", captive-portal browser pop-ups on corporate LAN, and VPN-connected devices flipping to "No Internet".

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Run in PowerShell on the affected device (elevation only needed for the event log query). First decide: **can the user actually browse?** If not, this is a general network fault — go to `NetworkAdapters-B.md` / `DNS-Client-B.md`. NCSI troubleshooting only applies when connectivity works but Windows *says* it doesn't.

```powershell
# 1. What Windows currently believes (per interface)
Get-NetConnectionProfile | Select-Object InterfaceAlias, NetworkCategory, IPv4Connectivity, IPv6Connectivity

# 2. The two probe dependencies, from this device
Resolve-DnsName www.msftconnecttest.com -Type A -ErrorAction SilentlyContinue | Select-Object Name, Type, IPAddress
(Invoke-WebRequest 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10).Content

# 3. Is active probing switched off or redirected?
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet' |
  Select-Object EnableActiveProbing, ActiveWebProbeHost, ActiveWebProbePath, ActiveWebProbeContent, ActiveDnsProbeHost, ActiveDnsProbeContent
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator' -ErrorAction SilentlyContinue

# 4. Proxy the probe will see (machine/WinHTTP) + last NCSI verdicts
netsh winhttp show proxy
Get-WinEvent -LogName 'Microsoft-Windows-NCSI/Operational' -MaxEvents 10 -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, Message
```

| Result | Meaning | Go to |
|---|---|---|
| `IPv4Connectivity: Internet` on the active adapter | NCSI is happy — the app complaining has its own check | App-specific runbook (Outlook-Client / Teams) |
| `LocalNetwork` / `NoTraffic` but step 2 returns `Microsoft Connect Test` | Probe works *as the user* but not for the service — proxy/auth context, or stale verdict | Fix 1 then Fix 3 |
| Step 2 DNS returns nothing / NXDOMAIN / `0.0.0.0` | DNS filter or internal DNS not resolving the probe host | Fix 2 |
| Step 2 HTTP returns HTML, a login page, or a block page | Proxy / web filter / SSL inspection rewriting the response → NCSI treats as hotspot | Fix 3 |
| Step 2 HTTP times out / 403 / 407 | Firewall blocking or proxy demanding auth | Fix 3 (allow by FQDN, no auth) |
| `EnableActiveProbing = 0` or policy `NoActiveProbe = 1` | Active probing disabled (hardening baseline / old fix) — passive only, unreliable | Fix 4 |
| `ActiveWebProbeHost` isn't `www.msftconnecttest.com` | Probe redirected to a corporate server — check it still serves the exact content | Fix 5 |
| Only wrong while on VPN | Forced-tunnel route change / probe misrouted | Fix 6 |
| Operational log shows `ChangeReason: ...HotspotDetected` on corp LAN | Something answers the probe with the wrong content | Fix 3 |

---
## Dependency Cascade
<details><summary>What must be true for "Internet access" to show</summary>

```
Taskbar icon / INetworkListManager::get_IsConnectedToInternet (Office, Teams, OneDrive, Store, Edge)
└── NCSI verdict per interface = Internet
    ├── Hosting service running
    │   ├── Windows 11 / Server 2022+ : Network List Service (netprofm)
    │   └── Windows 10 / Server 2019- : Network Location Awareness (NlaSvc)
    ├── Active probing enabled (EnableActiveProbing=1, no NoActiveProbe policy)
    ├── Interface has an address + a route toward the internet (else NoAddress / NoRoute)
    ├── ACTIVE PROBE (HTTP; IPv4 and IPv6 in parallel — either succeeding is enough)
    │   ├── DNS resolves www.msftconnecttest.com (via interface DNS servers)
    │   ├── Proxy correctly discovered (WPAD/PAC/manual) and reachable — if one exists
    │   │   └── Proxy lets the probe out WITHOUT interactive auth
    │   ├── Firewall allows outbound TCP 80 to the probe FQDN (Akamai-hosted since 20 Jun 2023 — not a fixed IP)
    │   └── Response = HTTP 200 + body exactly "Microsoft Connect Test" (no rewrite / injection)
    └── PASSIVE PROBE (supporting signal)
        └── Inbound packets' hop count ≥ system minimum (default 8) — can raise to Internet, not prove it
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm the verdict and which interface it's on.**
   `Get-NetConnectionProfile`
   *Good:* active adapter shows `IPv4Connectivity : Internet`. *Bad:* `LocalNetwork` (probe failed going direct) or `NoTraffic`. Note: a probe that failed **through a proxy** yields `None/NoTraffic`; one that failed **direct** yields `Local` — that alone tells you whether the proxy path was used.

2. **Confirm the service hosting NCSI is running.**
   `Get-Service netprofm, NlaSvc | Select-Object Name, Status, StartType`
   *Good:* `netprofm` Running on Windows 11 (NlaSvc on Windows 10). *Bad:* Stopped/Disabled → start it (Fix 1); look for the security tool or debloat script that disabled it.

3. **Resolve the probe hosts through the device's own DNS.**
   `Resolve-DnsName www.msftconnecttest.com; Resolve-DnsName dns.msftncsi.com`
   *Good:* A records returned (the DNS probe host historically returns `131.107.255.255`). *Bad:* NXDOMAIN, timeout, or a sinkhole IP (e.g. `0.0.0.0`, `146.112.x.x` block page) → Fix 2.

4. **Fetch the probe file and compare byte-for-byte.**
   ```powershell
   $r = Invoke-WebRequest 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10
   $r.StatusCode; $r.Content; $r.Content -ceq 'Microsoft Connect Test'
   ```
   *Good:* `200`, `Microsoft Connect Test`, `True`. *Bad:* any other body (HTML block page, login form) → Fix 3. Exception: `407` → proxy auth (Fix 3).
   This tests in **your** user context. NCSI runs as a service — if this passes but the verdict is still wrong, compare `netsh winhttp show proxy` with the user's proxy (`Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select ProxyEnable, ProxyServer, AutoConfigURL`).

5. **Read the NCSI verdict history.**
   `Get-WinEvent -LogName 'Microsoft-Windows-NCSI/Operational' -MaxEvents 20 | Format-List TimeCreated, Message`
   Look for `Capability change ... ChangeReason:` — `ActiveHttpProbeFailed` (name/proxy), `ActiveHttpProbeFailedButDnsSucceeded` (HTTP blocked), `ActiveHttpProbeFailedHotspotDetected` (wrong content), `NoRoute` (VPN/route table), `PassivePacketHops` (not a failure — capability raised).

6. **Check probing configuration hasn't been tampered with.**
   Defaults: `EnableActiveProbing=1`, `ActiveWebProbeHost=www.msftconnecttest.com`, `ActiveWebProbePath=connecttest.txt`, `ActiveWebProbeContent=Microsoft Connect Test`. Any deviation → Fix 4 or Fix 5.

---
## Common Fix Paths

<details><summary>Fix 1 — Force a fresh probe (stale verdict after network change / sleep / dock)</summary>

NCSI only re-probes on interface, proxy or hotspot change events. If the network was fixed after the last probe, the stale "No Internet" sticks.

```powershell
# Least disruptive: bounce the adapter (triggers NetReady → active probe). Drops the session briefly.
$nic = (Get-NetConnectionProfile | Select-Object -First 1).InterfaceAlias
Restart-NetAdapter -Name $nic -Confirm:$false
Start-Sleep 20
Get-NetConnectionProfile | Select-Object InterfaceAlias, IPv4Connectivity

# Alternative if the hosting service is stopped
$svc = if ([Environment]::OSVersion.Version.Build -ge 22000) { 'netprofm' } else { 'NlaSvc' }
Start-Service $svc
```
Don't remote-bounce the only adapter on a remote session without a fallback path (iLO/Intune remote action).
</details>

<details><summary>Fix 2 — DNS cannot resolve the probe host (DNS filtering / split-brain)</summary>

```powershell
Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object ServerAddresses | Select-Object InterfaceAlias, ServerAddresses
Resolve-DnsName www.msftconnecttest.com -Server <InternalDnsServer>
Resolve-DnsName www.msftconnecttest.com -Server 1.1.1.1   # comparison only — proves the record exists publicly
Clear-DnsClientCache
```
- DNS filter (Umbrella, DNSFilter, Defender for Endpoint network protection, Pi-hole): allowlist `msftconnecttest.com`, `msftncsi.com` (and `ipv6.msftconnecttest.com`).
- Internal DNS with no forwarders / root hints (isolated networks): add a conditional forwarder or accept the icon and use Fix 5 with an internal probe server.
</details>

<details><summary>Fix 3 — Proxy, firewall or SSL/web inspection breaks the probe</summary>

Ask the network/security team for these, by **FQDN**, not IP:

| Requirement | Why |
|---|---|
| Allow outbound HTTP (TCP 80) to `www.msftconnecttest.com` and `ipv6.msftconnecttest.com` | Probe hosts moved from Azure Front Door to Akamai on 20 June 2023 — any rule pinned to the old IP `13.107.4.52` silently broke |
| Exempt those hosts from proxy authentication | A `407` makes NCSI report no connectivity — the service can't answer an auth prompt |
| Exempt from content rewriting / block-page injection / SSL inspection | Any body other than `Microsoft Connect Test` = hotspot verdict |
| PAC file returns a reachable proxy (or `DIRECT`) for `www.msftconnecttest.com` | Misrouted PAC is a top cause per Microsoft |

Check what proxy the service context sees:
```powershell
netsh winhttp show proxy
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet\ManualProxies' -ErrorAction SilentlyContinue
```
After the change, do Fix 1.
</details>

<details><summary>Fix 4 — Active probing has been disabled (re-enable it)</summary>

Microsoft explicitly warns *not* to disable active probing as an NCSI fix — passive polling alone can't determine connectivity. Old "fixes" and some hardening baselines set it off.

```powershell
# Local registry value
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet' -Name EnableActiveProbing -Value 1 -Type DWord

# If a policy sets it, find the source first (don't fight GPO locally)
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator' -ErrorAction SilentlyContinue
gpresult /h "$env:TEMP\gp.html"; Start-Process "$env:TEMP\gp.html"
```
- GPO: *Computer Configuration › Administrative Templates › System › Internet Communication Management › Internet Communication settings › Turn off Windows Network Connectivity Status Indicator active tests* → set **Not Configured/Disabled**.
- Intune: Settings catalog *Connectivity › Disallow Network Connectivity Active Tests* → remove/Not configured.
Then Fix 1. Rollback: set the value back to `0` (not recommended).
</details>

<details><summary>Fix 5 — Corporate / air-gapped network: probe redirected or needs an internal probe server</summary>

If `ActiveWebProbeHost` points at an internal server, verify it still serves the exact file:
```powershell
$p = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet'
$u = "http://$($p.ActiveWebProbeHost)/$($p.ActiveWebProbePath)"
$b = (Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 10).Content
"$u -> '$b' matches: $($b -ceq $p.ActiveWebProbeContent)"
```
- Content mismatch (BOM, trailing newline, IIS default page) → fix the file on the web server; it must be a plain-text body matching `ActiveWebProbeContent` exactly.
- Redirect is deployed by GPP registry, not an ADMX policy — document it; it breaks for roaming laptops off-network unless the host is resolvable everywhere.
- To revert to Microsoft defaults: set `ActiveWebProbeHost=www.msftconnecttest.com`, `ActiveWebProbePath=connecttest.txt`, `ActiveWebProbeContent=Microsoft Connect Test`, then Fix 1.
</details>

<details><summary>Fix 6 — "No Internet" only while VPN is connected</summary>

Typical reason codes: `NoRoute` (forced tunnel changed the route table and the physical NIC drops to Local), or the probe goes into the tunnel and dies at a corporate proxy.

```powershell
Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object InterfaceAlias, NextHop, RouteMetric
Get-NetConnectionProfile | Select-Object InterfaceAlias, IPv4Connectivity
Test-NetConnection www.msftconnecttest.com -Port 80
```
- The VPN interface itself should show `Internet` — the physical NIC showing `LocalNetwork` under forced tunnel is expected.
- Make sure the tunnel's egress (corp proxy/firewall) meets Fix 3.
- Split tunnel: either route the probe hosts direct, or ensure the tunnel path allows them. Always On VPN detail → `AlwaysOnVPN-B.md`; GSA → `GlobalSecureAccess-Windows-B.md`.
</details>

---
## Escalation Evidence
```
Ticket: NCSI "No Internet" false positive
Device / OS build        : <hostname> / <winver build>
User can browse?         : <yes/no>
Affected apps            : <Outlook / Teams / OneDrive / Store / taskbar only>
Get-NetConnectionProfile : <InterfaceAlias / IPv4Connectivity / IPv6Connectivity>
Hosting service state    : <netprofm or NlaSvc — Running/Stopped>
DNS www.msftconnecttest.com : <IP(s) or failure>
HTTP connecttest.txt     : <status code> / body: <exact body or first 80 chars>
WinHTTP proxy            : <netsh winhttp show proxy output>
User proxy / PAC         : <ProxyServer / AutoConfigURL>
EnableActiveProbing      : <0/1>   Policy NoActiveProbe: <value or absent>
ActiveWebProbeHost       : <value>
Last NCSI ChangeReason   : <from NCSI/Operational>
VPN connected?           : <yes/no — client, split/forced>
Network path             : <proxy vendor / firewall / DNS filter in path>
Fixes attempted          : <Fix N ...>
Evidence pack            : <path to Get-NCSIDiagnostics.ps1 CSV/zip>
```

---
## 🎓 Learning Pointers
- The taskbar icon and Office's "offline" banner are the **same** verdict — Office calls `INetworkListManager::get_IsConnectedToInternet`. "Browsing works but Office says offline" is an NCSI case, not an Office case. [NCSI FAQ](https://learn.microsoft.com/windows-server/networking/ncsi/ncsi-frequently-asked-questions)
- If firewall rules were written by IP before 20 June 2023 they're the likely culprit — the probe servers moved to Akamai, and Microsoft's guidance is FQDN-based rules only (same model as Windows Update). [NCSI overview](https://learn.microsoft.com/windows-server/networking/ncsi/ncsi-overview)
- Don't "fix" by disabling active tests: you lose real detection and keep the passive-hop heuristic, which defaults to a minimum of 8 hops and misjudges flat enterprise networks.
- `Local` vs `None` tells you the path: failed direct → Local; failed via proxy → None. Use it to decide whether to call the network team or the proxy team first.
- On Windows 11 NCSI lives in **netprofm** (Network List Service), not NlaSvc — old scripts that restart NlaSvc do nothing useful. Deep dive and evidence collection: `NCSI-A.md`, `Scripts/Get-NCSIDiagnostics.ps1`.
- Microsoft's data-collection method (enable the NCSI Analytic log + packet capture during an adapter bounce): [NCSI troubleshooting guide](https://learn.microsoft.com/windows-server/networking/ncsi/ncsi-troubleshooting-guide).
