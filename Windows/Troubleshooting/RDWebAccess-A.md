# RD Web Access & RD Web Client (HTML5) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.
> Hotfix: `RDWebAccess-B.md` · Script: `../Scripts/Get-RDWebAccessDiagnostics.ps1` · Siblings: `RDGateway-A.md`, `RDSLicensing-A.md`, `RDP-A.md`

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
- On-premises / IaaS **Remote Desktop Services** deployments (Server 2016–2025) managed by a Connection Broker (`RemoteDesktop` module). Standalone RDWeb against 2008 R2 "RemoteApp sources" is out of scope.
- Covers the RD Web Access role (`RDS-Web-Access`), the `webfeed.aspx` workspace feed consumed by RemoteApp and Desktop Connections (RADC) and Windows App on macOS/iOS, and the HTML5 **Remote Desktop web client** published with the `RDWebClientManagement` module.
- Not covered: Azure Virtual Desktop / Windows 365 web clients (`Azure/AVD/`), gateway CAP/RAP internals (`RDGateway-A.md`), CAL issuance (`RDSLicensing-A.md`).
- Commands assume elevated **Windows PowerShell 5.1**; `RDWebClientManagement` cmdlets do not run in PowerShell 7.

---
## How It Works
<details><summary>Full architecture</summary>

### Components
| Component | Where | Role |
|---|---|---|
| IIS `Default Web Site` → `/RDWeb`, `/RDWeb/Pages`, `/RDWeb/Feed`, `/RDWeb/FeedLogon` | RD Web server | Forms-auth portal and the XML workspace feed. Files under `C:\Windows\Web\RDWeb`. App pool `RDWebAccess`. |
| Connection Broker (RDMS + SessionBroker) | Broker(s) | Source of truth for collections, RemoteApps, user groups, and deployment certificates; signs `.rdp` files (RDPublishing). |
| `/RDWeb/webclient` | RD Web server | Static HTML5/JS client, published from packages downloaded by `Install-RDWebClientPackage`. Test channel at `/RDWeb/webclient-test`. |
| RD Gateway | Gateway | Mandatory for the web client (WebSocket transport); optional-but-standard for classic launches from outside. |
| Deployment certificates | Broker config | `RDWebAccess` (IIS binding), `RDGateway`, `RDPublishing` (signs RDP files), `RDRedirector` (broker SSO / redirection). |

### Classic portal launch (mstsc)
```
Browser ──443──► /RDWeb/Pages/login.aspx (forms auth vs AD)
                   │
                   ├─► RD Web asks broker: "resources for <user>?"  (collection UserGroup ∩ app UserGroups)
                   ▼
            Default.aspx renders icons ──click──► downloads signed .rdp
                                                   │  (gatewayhostname, loadbalanceinfo, signature)
                                                   ▼
                                  mstsc ──443/3391──► RD Gateway ──3389──► Broker redirection ──► RDSH
```
The portal only *lists* and *hands out* `.rdp` files. Everything after the click is mstsc + gateway + broker — so "portal works, launch fails" is almost never an RD Web problem.

### Workspace feed (RADC / Windows App)
`https://<fqdn>/RDWeb/Feed/webfeed.aspx` returns an XML document listing the same resources plus the signed RDP content. Clients subscribe once, cache credentials, and refresh on a schedule; icons appear in the Start menu (Windows RADC) or in the workspace (Windows App on macOS/iOS). Email-based discovery looks up DNS TXT `_msradc.<emaildomain>` whose value is the feed URL. The feed client performs strict TLS validation — no click-through — so any cert gap that users ignore in the browser surfaces here first.

### HTML5 web client
```
Browser ──443──► /RDWeb/webclient/index.html (JS app)
   │  auth + resource list via RD Web feed (same UserGroup rules)
   ▼
Browser ──WSS 443──► RD Gateway (/remoteDesktopGateway/)  ← gateway cert must be publicly trusted
   │   RDP stack runs in JavaScript; TLS to the broker/RDSH is validated
   │   against the broker .cer imported with Import-RDWebClientBrokerCert
   ▼
Broker redirection ──► RDSH session rendered in a canvas
```
Key consequences:
- **Cert pinning**: the client trusts the broker by the `.cer` baked into the published package. Renewing the `RDRedirector` cert without re-importing breaks every web client launch with *"An unexpected server authentication certificate was received"*.
- **Gateway required**: without a gateway the web client can only reach a broker directly on Server 2019 with the WebSocket listener on 3392 (`WebSocketURI` = `https://+:3392/rdp/`) — an edge configuration, not an MSP default.
- **Licensing**: each browser profile looks like a new device; with Per-Device CALs the pool drains. Microsoft requires Per-User CALs for the web client.
- **Proxies**: Entra application proxy is supported (pre-auth + WebSocket pass-through); AD FS Web Application Proxy is **not**.
- **Versioning**: packages are installed side by side; `Publish-RDWebClientPackage -Type Production -Latest` switches users on next page load. Test channel lets you validate first.

### High availability
Multiple RD Web servers sit behind a load balancer; they are stateless except for forms-auth cookies (enable affinity or configure a shared machine key in `web.config` if users bounce between nodes). Each node needs its own `Import-RDWebClientBrokerCert` and `Publish-RDWebClientPackage`. Broker HA (SQL) does not change RD Web behaviour but means the `RDRedirector` cert may not exist in any single broker's store — keep the PFX.

### Settings surfaces
| Setting | Where | Notes |
|---|---|---|
| `PasswordChangeEnabled`, `DefaultTSGateway`, `ShowDesktops`, session timeouts | IIS → `RDWeb/Pages` → Application Settings (`web.config` appSettings) | Survives most CUs; back up `web.config` first. |
| Gateway used in `.rdp` files | `Set-RDDeploymentGatewayConfiguration` | Deployment-wide; overrides per-page gateway settings for deployment resources. |
| Desktop visibility | `Set-RDRemoteDesktop -ShowInWebAccess` | Hidden automatically when RemoteApps are published. |
| Web client launch method / telemetry | `Set-RDWebClientDeploymentSetting -Name LaunchResourceInBrowser / SuppressTelemetry` | Reset with `Reset-RDWebClientDeploymentSetting`. |
</details>

---
## Dependency Stack
```
Layer 9  Session on RDSH (licensing, profile, apps)                → RDSLicensing-A / RDP-A
Layer 8  RD Gateway CAP/RAP + WebSocket / HTTP transport            → RDGateway-A
Layer 7  Launch artefact: signed .rdp (RDPublishing) | HTML5 + broker .cer (RDRedirector)
Layer 6  Resource filtering: collection UserGroup ∩ RemoteApp UserGroups, ShowInWebAccess
Layer 5  RD Web ↔ Connection Broker query (RD Web listed in Get-RDServer, broker reachable)
Layer 4  Authentication: forms auth to AD (DOMAIN\user / UPN, password state, lockout)
Layer 3  IIS: Default Web Site, /RDWeb apps, RDWebAccess app pool
Layer 2  TLS: RDWebAccess cert trusted, SAN = public FQDN, HTTP.sys/IIS binding on 443
Layer 1  Network: DNS (public + split-brain), LB/WAF, TCP 443, _msradc TXT for discovery
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Browser cert warning on `/RDWeb` | RDWebAccess cert expired / self-signed / wrong name | `Get-RDCertificate -Role RDWebAccess` |
| HTTP 503 | `RDWebAccess` app pool stopped (identity password, rapid-fail) | `Get-WebAppPoolState RDWebAccess`, System log WAS |
| HTTP 404 on `/RDWeb` | LB node without the role, or IIS app deleted | `Get-WindowsFeature RDS-Web-Access` |
| Valid creds rejected | Bare username, expired/must-change password, lockout | IIS log `login.aspx` 200 loop; PDC 4740 |
| "No resources available" for one user | Not in collection `UserGroup` or app `UserGroups` | `Get-RDSessionCollectionConfiguration -UserGroup` |
| "No resources available" for everyone | RD Web cannot query broker / not in deployment | `Get-RDServer` role `RDS-WEB-ACCESS`; broker reachability |
| Desktop icon missing | RemoteApps published, `ShowInWebAccess` false | `Get-RDRemoteDesktop` |
| Launch: "publisher can't be identified" | RDPublishing cert untrusted/expired | `Get-RDCertificate -Role RDPublishing` |
| Feed subscribe fails silently | Cert warning on feed, wrong URL, missing `_msradc` TXT | `Resolve-DnsName _msradc.<dom> -Type TXT` |
| HTML5 "unexpected server authentication certificate" | Broker cert renewed, stale `.cer` on RD Web | Compare thumbprint in error vs `RDRedirector` |
| HTML5 "couldn't connect to the gateway" | Gateway cert not public, pre-2016 gateway, proxy strips WebSocket | `RDGateway-B.md`; WAF logs |
| HTML5 works for some, CALs exhausted | Deployment in Per-Device mode | `RDSLicensing-A.md` |
| Users bounce back to login between clicks | LB without affinity / different machine keys | LB persistence; `web.config` machineKey |
| Web client install error on 2016 | Inbox PowerShellGet, TLS 1.2 off, PS7 used | Fix 9 in B |

---
## Validation Steps
1. **Role inventory** — `Get-RDServer -ConnectionBroker <b>` → every RD Web node listed with `RDS-WEB-ACCESS`. Missing = node not part of deployment (portal shows nothing).
2. **Certificates** — `Get-RDCertificate -ConnectionBroker <b>` → four roles, `Level = Trusted`, `ExpiresOn` > 30 days, same subject/SAN covering the public FQDN. `NotConfigured` / `Untrusted` = bad.
3. **IIS binding** — on each RD Web node `Get-ChildItem IIS:\SslBindings | Where Port -eq 443` thumbprint = `RDWebAccess` thumbprint. Different = someone bound a cert manually in IIS; the next `Set-RDCertificate` will overwrite it.
4. **App pool** — `Get-WebAppPoolState RDWebAccess` → `Started`.
5. **Portal** — `Invoke-WebRequest https://<fqdn>/RDWeb/Pages/en-US/login.aspx -UseBasicParsing` → `StatusCode 200`. TLS exception = layer 2.
6. **Feed** — `Invoke-WebRequest https://<fqdn>/RDWeb/Feed/webfeed.aspx -UseDefaultCredentials -UseBasicParsing` (domain client) → `200`, content starts with `<?xml` and contains `<Resource`. `200` with zero resources = layer 6.
7. **Discovery** — `Resolve-DnsName _msradc.<emaildomain> -Type TXT` → `Strings` = feed URL.
8. **Web client** — `Get-RDWebClientPackage` → a version with `Production` published; browse `/RDWeb/webclient/index.html`.
9. **Broker cert parity** — thumbprint of the `.cer` last imported (keep it in the change record) = `Get-RDCertificate -Role RDRedirector`.
10. **End to end** — launch a desktop from the HTML5 client and confirm Gateway event 302 for the user.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Reachability & TLS.** Browser/`Invoke-WebRequest` from outside and inside. Cert errors → Playbook 1. Separate DNS answers inside vs outside are normal (split-brain) but both must land on a node with a cert matching the name.

**Phase 2 — Portal & auth.** IIS log (`C:\inetpub\logs\LogFiles\W3SVC1`) shows `POST /RDWeb/Pages/<lang>/login.aspx`; success is followed by `GET .../Default.aspx`. Repeated login POSTs with no Default = auth failed → check format, password state, lockout (DC 4625/4740 with the RD Web server as source).

**Phase 3 — Resource enumeration.** Compare the user's groups with collection/app groups. Remember tokens: group changes need a fresh sign-in. If nobody sees resources, it's the RD Web ↔ broker path (deployment membership, broker service `Tssdis`/RDMS up, name resolution).

**Phase 4 — Launch (classic).** Open the downloaded `.rdp` in Notepad: `gatewayhostname`, `full address`, `loadbalanceinfo` (`tsv://MS Terminal Services Plugin.1.<Collection>`) and `signature` present. Wrong gateway = `Set-RDDeploymentGatewayConfiguration`. Then → `RDGateway-B.md`.

**Phase 5 — Launch (HTML5).** Capture RD Console Logs. Cert-thumbprint message → Playbook 2. Gateway handshake failures → gateway cert trust / WebSocket through proxy. Then gateway events.

**Phase 6 — Session.** Licensing ("no licenses available"), profile, app issues → sibling runbooks.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Deployment certificate renewal (all four roles, HTML5-safe)</summary>

```powershell
$b  = '<broker.fqdn>'
$pw = Read-Host -AsSecureString 'PFX password'
$pfx = '<\\share\remote-2027.pfx>'
Get-RDCertificate -ConnectionBroker $b | Export-Csv C:\Temp\RDCert-before.csv -NoTypeInformation   # rollback reference
foreach ($role in 'RDGateway','RDWebAccess','RDRedirector','RDPublishing') {
    Set-RDCertificate -Role $role -ImportPath $pfx -Password $pw -ConnectionBroker $b -Force
}
Get-RDCertificate -ConnectionBroker $b | Select Role, Level, ExpiresOn, Thumbprint
# Produce the public .cer for the web client from the same PFX
$c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfx, $pw)
[IO.File]::WriteAllBytes('C:\Temp\broker.cer', $c.Export('Cert'))
# Then on EVERY RD Web node:
#   Import-RDWebClientBrokerCert C:\Temp\broker.cer ; Publish-RDWebClientPackage -Type Production -Latest
```
Rollback: re-run the loop with the previous PFX, re-import its `.cer`. Existing sessions are unaffected; new connections pick up the new cert. Schedule out of hours — gateway cert swap drops in-flight gateway connections.
</details>

<details><summary>Playbook 2 — Deploy or upgrade the HTML5 web client safely</summary>

```powershell
# Preflight
Get-RDLicenseConfiguration -ConnectionBroker <b> | Select Mode   # must be PerUser
Get-RDCertificate -ConnectionBroker <b> -Role RDGateway | Select Level, ExpiresOn   # Trusted, public CA
# Install / upgrade (per RD Web node)
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Install-Module RDWebClientManagement -Force
Install-RDWebClientPackage
Import-RDWebClientBrokerCert C:\Temp\broker.cer
Publish-RDWebClientPackage -Type Test -Latest        # validate /RDWeb/webclient-test/index.html
Publish-RDWebClientPackage -Type Production -Latest
Set-RDWebClientDeploymentSetting -Name SuppressTelemetry $true
```
Offline nodes: `Save-RDWebClientPackage C:\WebClient\` + `Save-Module RDWebClientManagement` on an internet box, then `Install-RDWebClientPackage -Source <zip>`.
Rollback: `Get-RDWebClientPackage` then `Publish-RDWebClientPackage -Type Production -Version <previous>`. Full removal: `Uninstall-RDWebClient` + `Uninstall-Module RDWebClientManagement`.
</details>

<details><summary>Playbook 3 — Resource visibility model clean-up</summary>

1. One AD group per collection (`RDS-<Collection>-Users`), assigned with `Set-RDSessionCollectionConfiguration -UserGroup`.
2. Leave RemoteApp `UserGroups` empty unless an app must be narrower; then use `RDS-App-<Name>` groups.
3. Decide per collection whether the desktop is shown: `Set-RDRemoteDesktop -ShowInWebAccess $true|$false`.
4. Export the result for the customer record:
```powershell
Get-RDSessionCollection -ConnectionBroker <b> | ForEach-Object {
  $c = $_.CollectionName
  Get-RDRemoteApp -CollectionName $c -ConnectionBroker <b> | Select @{n='Collection';e={$c}}, DisplayName, ShowInWebAccess, @{n='Groups';e={$_.UserGroups -join ';'}}
} | Export-Csv C:\Temp\RDWeb-Visibility.csv -NoTypeInformation
```
</details>

<details><summary>Playbook 4 — Add MFA in front of RD Web</summary>

- **Entra application proxy** (recommended for Entra-connected tenants): publish `https://<fqdn>/RDWeb/` with Entra pre-authentication and the gateway with pass-through; supported for both the portal and the HTML5 client. Follow MS Learn "Publish Remote Desktop with Microsoft Entra application proxy".
- **NPS extension for Entra MFA on the gateway**: MFA happens at launch (CAP), not at portal login — see `RDGateway-A.md` Playbook 2 (RADIUS timeout ≥ 60 s).
- Do **not** place the HTML5 client behind AD FS WAP. Third-party portal MFA modules patch RDWeb pages and break on updates — document them in the customer record.
</details>

<details><summary>Playbook 5 — Enable password change and friendlier login</summary>

```powershell
Import-Module WebAdministration
Copy-Item C:\Windows\Web\RDWeb\Pages\web.config C:\Temp\RDWeb-Pages-web.config.bak
Set-WebConfigurationProperty -PSPath 'IIS:\Sites\Default Web Site\RDWeb\Pages' -Filter "appSettings/add[@key='PasswordChangeEnabled']" -Name value -Value 'true'
```
Users with expired passwords use `/RDWeb/Pages/en-US/password.aspx`. Rollback: restore the backup `web.config`. Login-page text edits (username hint) are unsupported customisations — keep a copy; CUs may revert them.
</details>

---
## Evidence Pack
```powershell
# Run elevated (Windows PowerShell 5.1) on each RD Web node. Set $Broker first.
$Broker = '<broker.fqdn>'
$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = "C:\Temp\RDWeb-Evidence-$env:COMPUTERNAME-$ts"; New-Item $out -ItemType Directory -Force | Out-Null
Import-Module WebAdministration
Get-WindowsFeature RDS-Web-Access, Web-Server | Export-Csv "$out\features.csv" -NoTypeInformation
Get-WebAppPoolState -Name RDWebAccess | Out-File "$out\apppool.txt"
Get-ChildItem IIS:\SslBindings | Select IPAddress, Port, Host, Thumbprint, Store | Export-Csv "$out\sslbindings.csv" -NoTypeInformation
netsh http show sslcert | Out-File "$out\httpsys-sslcert.txt"
Get-ChildItem Cert:\LocalMachine\My | Select Subject, Thumbprint, NotAfter, @{n='SAN';e={$_.DnsNameList -join ';'}} | Export-Csv "$out\certs.csv" -NoTypeInformation
Copy-Item C:\Windows\Web\RDWeb\Pages\web.config "$out\pages-web.config" -ErrorAction SilentlyContinue
Get-ChildItem C:\inetpub\logs\LogFiles\W3SVC1 -ErrorAction SilentlyContinue | Sort LastWriteTime -Desc | Select -First 2 | Copy-Item -Destination $out
try { Get-RDWebClientPackage | Out-File "$out\webclient-packages.txt" } catch { "RDWebClientManagement not installed" | Out-File "$out\webclient-packages.txt" }
try {
  Import-Module RemoteDesktop
  Get-RDServer -ConnectionBroker $Broker | Export-Csv "$out\rdservers.csv" -NoTypeInformation
  Get-RDCertificate -ConnectionBroker $Broker | Export-Csv "$out\rdcerts.csv" -NoTypeInformation
  Get-RDLicenseConfiguration -ConnectionBroker $Broker | Out-File "$out\licensing.txt"
  Get-RDDeploymentGatewayConfiguration -ConnectionBroker $Broker | Out-File "$out\gatewaycfg.txt"
} catch { $_.Exception.Message | Out-File "$out\rd-module-error.txt" }
Get-WinEvent -LogName System -MaxEvents 300 | Where ProviderName -match 'WAS' | Export-Csv "$out\was-events.csv" -NoTypeInformation
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```
Attach the user's **RD Console Logs.txt** for any HTML5 issue.

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| Deployment role servers | `Get-RDServer -ConnectionBroker <b>` |
| Deployment certs | `Get-RDCertificate -ConnectionBroker <b>` |
| Replace a role cert | `Set-RDCertificate -Role RDWebAccess -ImportPath <pfx> -Password $pw -ConnectionBroker <b> -Force` |
| Collection user groups | `Get-RDSessionCollectionConfiguration -CollectionName <c> -UserGroup -ConnectionBroker <b>` |
| RemoteApp visibility | `Get-RDRemoteApp -CollectionName <c> -ConnectionBroker <b> \| Select DisplayName, ShowInWebAccess, UserGroups` |
| Show desktop icon | `Set-RDRemoteDesktop -CollectionName <c> -ShowInWebAccess $true -ConnectionBroker <b>` |
| Gateway in RDP files | `Get-RDDeploymentGatewayConfiguration -ConnectionBroker <b>` |
| Licensing mode | `Get-RDLicenseConfiguration -ConnectionBroker <b>` |
| App pool state | `Get-WebAppPoolState -Name RDWebAccess` |
| Feed test | `Invoke-WebRequest https://<fqdn>/RDWeb/Feed/webfeed.aspx -UseDefaultCredentials -UseBasicParsing` |
| Discovery record | `Resolve-DnsName _msradc.<domain> -Type TXT` |
| Web client packages | `Get-RDWebClientPackage` |
| Re-import broker cert | `Import-RDWebClientBrokerCert <path.cer>` |
| Publish web client | `Publish-RDWebClientPackage -Type Production -Latest` |
| Web client settings | `Set-RDWebClientDeploymentSetting -Name LaunchResourceInBrowser $true` |

---
## 🎓 Learning Pointers
- Read [Set up the Remote Desktop web client for your users](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remote-desktop-web-client-admin) end to end once — the prerequisites (Per-User CALs, public certs on Gateway and RD Web, 2016+ gateway) explain most first-deployment failures.
- [Supported configurations for RDS](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/rds-supported-config) covers which reverse proxies are supported (Entra application proxy yes, WAP no for the web client).
- [Publish Remote Desktop with Microsoft Entra application proxy](https://learn.microsoft.com/en-us/entra/identity/app-proxy/application-proxy-integrate-with-remote-desktop-services) is the cleanest route to MFA + no inbound 443 for RD Web.
- Treat the four deployment certs as one asset with one expiry date; `Get-RDCertificate` in a monthly check (or `Get-RDWebAccessDiagnostics.ps1`) catches renewals before users do.
- RD Web is a *broker front end*: when "portal works, launch fails", move straight to `.rdp` contents and gateway events rather than IIS.
- [What's new in the Remote Desktop web client](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/web-client-whats-new) — check before upgrading packages; use the Test channel first.
