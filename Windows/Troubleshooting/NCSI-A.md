# NCSI (Network Connectivity Status Indicator) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what. Hotfix path: `NCSI-B.md`. Evidence script: `../Scripts/Get-NCSIDiagnostics.ps1`.

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
- **In scope:** Windows 10/11 and Windows Server 2016–2025 clients reporting "No Internet access" / "Limited" / globe icon while traffic actually flows; apps that consume the NCSI verdict (Microsoft 365 Apps, Teams, OneDrive, Store, Edge captive-portal launch, Windows Update UX); enterprise proxy/PAC/firewall/DNS-filter/VPN interactions; internal probe servers for isolated networks.
- **Out of scope:** real connectivity failures (`NetworkAdapters-A.md`, `DNS-Client-A.md`, `DHCP-Client-A.md`); firewall *profile* selection Domain/Private/Public (that's the NLA domain-detection half — `Firewall-A.md` § Network Profile); Wi-Fi/802.1X authentication (`WiFi-8021x-Windows-A.md`).
- **Assumes:** local admin on the device, ability to ask the network team for proxy/firewall/DNS changes, PowerShell 5.1+.

---
## How It Works
<details><summary>Full architecture</summary>

### Two services, two jobs that get confused
| Function | Answers | Hosted in |
|---|---|---|
| **Network identification / category** (NLA) | Which network is this? Domain / Private / Public → firewall profile | NlaSvc (domain detection), Network List Service |
| **Connectivity level** (NCSI) | Does this interface reach the internet, only the local network, or nothing? | Windows 11 / Server 2022+: **Network List Service (`netprofm`)**. Windows 10 / Server 2019 and earlier: **NlaSvc** |

A device can be on the correct Domain profile and still show "No Internet" — they are separate verdicts. Both surface in `Get-NetConnectionProfile` (`NetworkCategory` vs `IPv4Connectivity`/`IPv6Connectivity`).

### Active probe (the authoritative test)
```
Trigger: interface NetReady | proxy change | hotspot change
          │
          ▼
  [DNS] resolve www.msftconnecttest.com  ── fail ──► ActiveHttpProbeFailed (name/proxy)
          │ ok
          ▼
  [Proxy?] stored proxy info (WPAD/PAC/manual, ManualProxies key)
          │
          ▼
  [HTTP] GET http://www.msftconnecttest.com/connecttest.txt   (IPv4 and IPv6 in parallel)
          │
   ┌──────┼───────────────────────────────┬─────────────────────────┐
   ▼      ▼                               ▼                         ▼
 timeout/ 200 + body == "Microsoft     200 with other body,      no route for
 refused  Connect Test"                or 302/304 (redirect)     interface
   │      │                               │                         │
   ▼      ▼                               ▼                         ▼
 ActiveHttpProbe  INTERNET             ActiveHttpProbeFailed     NoRoute
 FailedButDns                          HotspotDetected → Local
 Succeeded                             (+ captive-portal browser launch)
```
- Either IPv4 or IPv6 success is enough for "Internet".
- **Path matters for the failure verdict:** failure through a proxy → connectivity **None**; failure going direct → **Local**.
- Since Windows 10 1607 the HTTP probe is `www.msftconnecttest.com/connecttest.txt` (older: `www.msftncsi.com/ncsi.txt` → "Microsoft NCSI").
- Windows 11 always uses HTTP; DNS activity you see is to locate the HTTP probe server. Pre-Windows 11, with no proxy, a DNS probe (`dns.msftncsi.com` → `131.107.255.255`) could be used.
- **Since 20 June 2023 the public probe servers are hosted by Akamai** (previously Azure Front Door). IP-pinned allow rules for `13.107.4.52` broke at that date.

### Passive probe (supporting signal)
- Runs every 15 s by default (`PassivePollPeriod`) when allowed by policy and a user is/was logged on within 30 s.
- Inspects inbound packets' hop counts; if ≥ the system minimum (default **8**; Microsoft suggests **3** suits most enterprises) it can *raise* capability to Internet (`ChangeReason: PassivePacketHops`).
- Cannot by itself prove internet reachability — which is why disabling active probing is explicitly discouraged.

### Configuration surfaces
| Location | What lives there |
|---|---|
| `HKLM\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet` | `EnableActiveProbing`, `ActiveWebProbeHost[V6]`, `ActiveWebProbePath[V6]`, `ActiveWebProbeContent[V6]`, `ActiveDnsProbeHost[V6]`, `ActiveDnsProbeContent[V6]`, `PassivePollPeriod`, `ManualProxies` subkey |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator` | GPO-written policy (e.g. `NoActiveProbe` from *Turn off Windows NCSI active tests*; `UseGlobalDns`; `DisablePassivePolling`) |
| GPO: *Computer › Admin Templates › Network › Network Connectivity Status Indicator* | Corporate probe/DNS settings (DirectAccess-era), *Specify global DNS*, *Specify passive polling* |
| Intune Settings catalog: *Connectivity › Disallow Network Connectivity Active Tests* | MDM equivalent of turning off active tests |

### Who consumes the verdict
- Taskbar icon and Settings › Network status.
- Any app calling `INetworkListManager::get_IsConnectedToInternet` — notably **Microsoft Office** (offline banners, sign-in, activation prompts, co-authoring), plus many line-of-business apps, OneDrive, Store and Teams behaviours.
- Captive-portal detection opening the default browser (by design on hotspot verdict).

### Event logs
- `Microsoft-Windows-NCSI/Operational` — capability changes with `ChangeReason`.
- `Microsoft-Windows-NCSI/Analytic` (enable via *Show Analytic and Debug Logs*) — probe start/finish: 4013 probe started, 4017 HTTP probe started, 4018 HTTP finished, 4014 probe finished (true/false), 4005 state entered, **4051 probe result code** (WinHTTP error, e.g. `12007` = name not resolved).
</details>

---
## Dependency Stack
```
L7  App verdict           Office / Teams / OneDrive / taskbar  ← get_IsConnectedToInternet
L6  NCSI verdict          per interface, per family: Internet | Local | None(NoTraffic)
L5  Probe policy          EnableActiveProbing=1, no NoActiveProbe / DisallowNetworkConnectivityActiveTests
L4  HTTP probe            200 + exact "Microsoft Connect Test", no rewrite, no 407
L3  Proxy path            WPAD/PAC/manual discovered + reachable + no auth for probe FQDN
L2  Name resolution       www.msftconnecttest.com / ipv6.msftconnecttest.com via interface DNS
L1  Routing               default route on the interface (forced-tunnel VPN changes this)
L0  Interface             adapter up, preferred IP (else NoAddress / NoGlobalAddress)
    Host service          netprofm (Win11 / Server 2022+) or NlaSvc (Win10 / Server 2019-)
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Globe/"No Internet", browsing fine, started mid-2023 | Firewall allows probe by old IP `13.107.4.52` | Firewall rule set; `Test-NetConnection www.msftconnecttest.com -Port 80` |
| "No Internet" only for users behind authenticating proxy | Proxy returns 407 to the service-context probe | Proxy logs for `connecttest.txt`; `netsh winhttp show proxy` |
| Browser pops open on corp LAN to `msftconnecttest.com/redirect` | Web filter / SSL inspection returning a block page → hotspot verdict | `Invoke-WebRequest` body ≠ `Microsoft Connect Test` |
| Office "offline", Outlook "Disconnected" but OWA works | NCSI verdict Local/None | `Get-NetConnectionProfile` |
| Physical NIC "No Internet" while VPN up | Forced tunnel, `NoRoute` — expected for physical NIC | VPN interface verdict; default routes |
| Everything says "No Internet" in an isolated/OT/lab network | No route to public probe server (by design) | Decide: internal probe server (Playbook C) or accept |
| Icon wrong right after wake/dock, fixes itself on unplug | Stale verdict, no re-probe trigger | Adapter bounce |
| Never shows Internet, `EnableActiveProbing=0` | Old "fix" / hardening baseline | Registry + RSoP |
| Only some sites/devices, DNS filter in use | Probe FQDN categorised/blocked | `Resolve-DnsName` returns sinkhole |
| Intermittent across fleet at login | PAC not yet downloaded / proxy unreachable at probe time | Analytic log 4051 codes vs logon time |
| Correct on IPv4, wrong on IPv6 | Irrelevant if IPv4 succeeds (either suffices); if v4 broken and v6 partially configured → check v6 route | `IPv6Connectivity` column |

---
## Validation Steps
1. **Verdict per interface.** `Get-NetConnectionProfile | ft InterfaceAlias, NetworkCategory, IPv4Connectivity, IPv6Connectivity`
   *Good:* active interface `Internet`. *Bad:* `LocalNetwork` / `NoTraffic`.
2. **Host service.** `Get-Service netprofm, NlaSvc`
   *Good:* Running. *Bad:* Stopped/Disabled.
3. **Probe config defaults.** `Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet'`
   *Good:* `EnableActiveProbing 1`, host `www.msftconnecttest.com`, path `connecttest.txt`, content `Microsoft Connect Test`. *Bad:* 0 / redirected host without a working server.
4. **Policy overlay.** `Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator' -EA 0`
   *Good:* key absent or no `NoActiveProbe`. *Bad:* `NoActiveProbe = 1`.
5. **DNS.** `Resolve-DnsName www.msftconnecttest.com`
   *Good:* resolves to public CDN addresses. *Bad:* NXDOMAIN / sinkhole.
6. **HTTP content.** `(iwr http://www.msftconnecttest.com/connecttest.txt -UseBasicParsing).Content -ceq 'Microsoft Connect Test'`
   *Good:* `True`. *Bad:* `False`, 403, 407, timeout.
7. **Proxy views.** `netsh winhttp show proxy` + HKCU Internet Settings `ProxyServer`/`AutoConfigURL`
   *Good:* consistent with the network design. *Bad:* user has PAC but service context has nothing and direct egress is blocked.
8. **Verdict history.** Last 20 NCSI/Operational events; *Good:* latest `ChangeReason` is not a failure.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Is it NCSI at all?
- User can't browse either → not NCSI. Stop and follow general networking runbooks.
- App says offline but `IPv4Connectivity : Internet` → the app's own check (e.g. Teams endpoint reachability, Outlook connection status). Go to the app runbook.

### Phase 2 — Configuration
- Probing disabled or redirected? (Validation 3–4). Most "never shows Internet" cases on a single build image end here.
- Host service disabled by a debloat/hardening script?

### Phase 3 — Name resolution
- Resolve through the interface's DNS servers specifically (`-Server`). Compare with a public resolver only to prove the record exists.
- In split-DNS environments, ensure internal DNS forwards `msftconnecttest.com`/`msftncsi.com`.

### Phase 4 — Proxy and egress
- Determine the path: does the network require a proxy for port 80? If yes, the probe must be routed (PAC) and exempt from auth.
- Pull proxy/firewall logs for the device IP + `connecttest.txt` around the failure timestamp; correlate with Analytic 4051 codes.
- Content rewriting is the subtle one: a 200 with a branded block page = hotspot verdict + browser launch.

### Phase 5 — Routing / VPN
- `NoRoute` immediately after VPN connect is common with forced tunnel; judge the **VPN** interface's verdict.
- Confirm the tunnel egress meets Phase 4 requirements.

### Phase 6 — Reproduce with data
- Enable the NCSI Analytic log, start a packet capture, bounce the adapter, wait 60 s, stop. Export Analytic events and correlate timestamps (Microsoft's documented method).

---
## Remediation Playbooks

<details><summary>Playbook A — Enterprise allow-list request (firewall / proxy / DNS filter)</summary>

Hand this to the network team verbatim:

1. Allow outbound TCP 80 to `www.msftconnecttest.com` and `ipv6.msftconnecttest.com` by **FQDN** (hosted by Akamai since 20 June 2023 — do not use IPs).
2. Allow DNS resolution of `msftconnecttest.com`, `msftncsi.com` (incl. `dns.msftncsi.com`).
3. Exempt these hosts from proxy authentication, SSL/content inspection, and block-page injection.
4. PAC: return a reachable proxy or `DIRECT` for `www.msftconnecttest.com`.
5. Remove any legacy rule targeting `13.107.4.52`.

Validate per device with Fix 1 of `NCSI-B.md` (adapter bounce) and `Get-NetConnectionProfile`. No rollback needed — additive allow rules.
</details>

<details><summary>Playbook B — Restore Microsoft-default probing fleet-wide</summary>

1. Remove the policy source: GPO *Turn off Windows NCSI active tests* → Not Configured; Intune *Disallow Network Connectivity Active Tests* → remove from profile.
2. Remediate devices where the local value was hand-set (Intune Remediation or GPP):
```powershell
$k = 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet'
$want = @{ EnableActiveProbing = 1; ActiveWebProbeHost = 'www.msftconnecttest.com'; ActiveWebProbePath = 'connecttest.txt'; ActiveWebProbeContent = 'Microsoft Connect Test' }
foreach ($n in $want.Keys) {
    $cur = (Get-ItemProperty $k -Name $n -ErrorAction SilentlyContinue).$n
    if ("$cur" -ne "$($want[$n])") {
        $type = if ($n -eq 'EnableActiveProbing') { 'DWord' } else { 'String' }
        Set-ItemProperty $k -Name $n -Value $want[$n] -Type $type
        Write-Output "Set $n : '$cur' -> '$($want[$n])'"
    }
}
```
3. Detection for Remediations: exit 1 if `EnableActiveProbing -ne 1` or `ActiveWebProbeHost -ne 'www.msftconnecttest.com'`.
**Rollback:** export the key first — `reg export "HKLM\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet" "$env:TEMP\ncsi-internet.reg"`. Do *not* touch V6 values unless they were also changed.
</details>

<details><summary>Playbook C — Internal probe server for isolated / air-gapped networks</summary>

Use only where devices genuinely cannot reach the internet but need apps to see "connected" (Microsoft notes this is an uncommon but supported scenario).

1. On an internal IIS/web server publish a plain-text file at `http://<probeHost>/connecttest.txt` whose body is exactly `Microsoft Connect Test` (no BOM, no newline; set MIME `text/plain`).
   ```powershell
   [IO.File]::WriteAllText('C:\inetpub\wwwroot\connecttest.txt', 'Microsoft Connect Test', (New-Object Text.UTF8Encoding $false))
   ```
2. Create a DNS A record for `<probeHost>` (and AAAA if you want v6 to pass).
3. Deploy via GPP Registry (Update action) to `HKLM\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet`: `ActiveWebProbeHost=<probeHost>` (REG_SZ). Keep path/content default.
4. Scope only to devices that never leave the isolated network — a roaming laptop will report "No Internet" off-site where `<probeHost>` doesn't resolve.
5. Validate with `NCSI-B.md` Fix 5 snippet.
**Rollback:** GPP Delete/Replace back to `www.msftconnecttest.com`, adapter bounce.
</details>

<details><summary>Playbook D — VPN-connected devices report No Internet</summary>

1. Identify tunnel type: `Get-VpnConnection` (AOVPN/native) or third-party client config.
2. Check the VPN interface verdict, not the physical NIC: `Get-NetConnectionProfile`.
3. Forced tunnel: ensure corporate egress satisfies Playbook A; physical NIC dropping to Local is expected (`NoRoute`).
4. Split tunnel: either exclude `www.msftconnecttest.com` from the tunnel (direct) or ensure the inside path allows it — but be consistent, because the probe goes wherever the route table sends it at probe time.
5. If the verdict is wrong only for the first minute after connect, it's a route-programming delay; a re-probe happens on the next interface change. Persisting → capture with Analytic log during connect.
Related: `AlwaysOnVPN-A.md`, `GlobalSecureAccess-Windows-A.md`.
</details>

<details><summary>Playbook E — Captive-portal browser pops on corporate Wi-Fi</summary>

Root cause is always "something answered the probe with the wrong content". Find it:
```powershell
$r = Invoke-WebRequest 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -MaximumRedirection 0 -ErrorAction SilentlyContinue
$r.StatusCode; $r.Headers.Location; $r.Content.Substring(0, [Math]::Min(200, $r.Content.Length))
```
- `302` with `Location` to a guest portal → the device is on the guest SSID/VLAN or the portal isn't bypassing corporate MACs/802.1X users.
- 200 with HTML → web filter block page: Playbook A step 3.
Do not disable captive-portal detection as a fix — it's the same probe.
</details>

---
## Evidence Pack
```powershell
# Collects NCSI evidence to a folder + zip. Run elevated. Read-only except enabling the NCSI Analytic log if -EnableAnalytic.
param([string]$Out = "$env:TEMP\NCSI-Evidence-$env:COMPUTERNAME-$(Get-Date -Format yyyyMMdd-HHmm)", [switch]$EnableAnalytic)
New-Item $Out -ItemType Directory -Force | Out-Null
Get-NetConnectionProfile | Select-Object * | Export-Csv "$Out\connection-profile.csv" -NoTypeInformation
Get-NetIPConfiguration -Detailed | Out-File "$Out\ipconfig-detailed.txt"
Get-NetRoute -AddressFamily IPv4 | Sort-Object RouteMetric | Out-File "$Out\routes.txt"
Get-Service netprofm, NlaSvc | Select-Object Name, Status, StartType | Out-File "$Out\services.txt"
reg export "HKLM\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet" "$Out\ncsi-internet.reg" /y | Out-Null
reg export "HKLM\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator" "$Out\ncsi-policy.reg" /y 2>$null | Out-Null
netsh winhttp show proxy | Out-File "$Out\winhttp-proxy.txt"
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select-Object ProxyEnable, ProxyServer, ProxyOverride, AutoConfigURL, AutoDetect | Out-File "$Out\user-proxy.txt"
Resolve-DnsName www.msftconnecttest.com -ErrorAction SilentlyContinue | Out-File "$Out\dns-probe.txt"
try { $r = Invoke-WebRequest 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10; "Status=$($r.StatusCode)`nBody=$($r.Content)" } catch { "HTTP error: $($_.Exception.Message)" } | Out-File "$Out\http-probe.txt"
Get-WinEvent -LogName 'Microsoft-Windows-NCSI/Operational' -MaxEvents 200 -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$Out\ncsi-operational.csv" -NoTypeInformation
if ($EnableAnalytic) { wevtutil sl Microsoft-Windows-NCSI/Analytic /e:true /q:true; "Analytic log enabled — reproduce (bounce adapter), then rerun without -EnableAnalytic to export." | Out-File "$Out\README.txt" }
wevtutil qe Microsoft-Windows-NCSI/Analytic /f:text /c:300 2>$null | Out-File "$Out\ncsi-analytic.txt"
Compress-Archive -Path "$Out\*" -DestinationPath "$Out.zip" -Force
Write-Host "Evidence: $Out.zip"
```
For the full decoded audit (verdict + config drift + proxy + content checks with a CSV verdict) use `Windows/Scripts/Get-NCSIDiagnostics.ps1`.

---
## Command Cheat Sheet
| Purpose | Command |
|---|---|
| Verdict per interface | `Get-NetConnectionProfile \| ft InterfaceAlias, IPv4Connectivity, IPv6Connectivity` |
| Host service | `Get-Service netprofm, NlaSvc` |
| Probe config | `Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet'` |
| Policy overlay | `Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator'` |
| DNS probe host | `Resolve-DnsName www.msftconnecttest.com` |
| HTTP probe content | `(iwr http://www.msftconnecttest.com/connecttest.txt -UseBasicParsing).Content` |
| Redirect/portal check | `iwr <probeUrl> -UseBasicParsing -MaximumRedirection 0 -EA 0 \| % StatusCode` |
| TCP reachability | `Test-NetConnection www.msftconnecttest.com -Port 80` |
| Machine proxy | `netsh winhttp show proxy` |
| Force re-probe | `Restart-NetAdapter -Name <InterfaceAlias>` |
| Verdict history | `Get-WinEvent -LogName Microsoft-Windows-NCSI/Operational -MaxEvents 20` |
| Enable analytic log | `wevtutil sl Microsoft-Windows-NCSI/Analytic /e:true /q:true` |
| Export analytic log | `wevtutil qe Microsoft-Windows-NCSI/Analytic /f:text /c:300` |
| Default routes | `Get-NetRoute -DestinationPrefix 0.0.0.0/0 \| sort RouteMetric` |
| Policy source | `gpresult /h $env:TEMP\gp.html` |

---
## 🎓 Learning Pointers
- Read the three Microsoft pages together — overview (architecture, proxies, captive portals), FAQ (failure reason codes, hop count, Office's API dependency), troubleshooting guide (Analytic log + capture method): [Overview](https://learn.microsoft.com/windows-server/networking/ncsi/ncsi-overview) · [FAQ](https://learn.microsoft.com/windows-server/networking/ncsi/ncsi-frequently-asked-questions) · [Troubleshooting guide](https://learn.microsoft.com/windows-server/networking/ncsi/ncsi-troubleshooting-guide).
- The probe endpoint is part of the documented Windows endpoint list — useful evidence when a security team questions the allow rule: [Manage connections from Windows components to Microsoft services § NCSI](https://learn.microsoft.com/windows/privacy/manage-connections-from-windows-operating-system-components-to-microsoft-services#14-network-connection-status-indicator).
- Analytic event 4051 carries a WinHTTP error number — decode it with [WinHTTP error messages](https://learn.microsoft.com/windows/win32/winhttp/error-messages) (e.g. 12007 name not resolved, 12002 timeout, 12029 cannot connect) to know which team owns the fix.
- Keep NCSI (connectivity level) and NLA domain detection (firewall profile) separate in your head — a ticket can have one, the other, or both. Profile side: `Firewall-A.md`.
- Why apps trust NCSI instead of their own pings: [INetworkListManager::get_IsConnectedToInternet](https://learn.microsoft.com/windows/win32/api/netlistmgr/nf-netlistmgr-inetworklistmanager-get_isconnectedtointernet) — understanding this explains "Outlook offline but OWA works".
- Captive portal launching a browser is by design: [A browser opens when connecting to a corporate or public network](https://learn.microsoft.com/troubleshoot/windows-client/networking/internet-explorer-edge-open-connect-corporate-public-network).
