# RD Web Access & RD Web Client (HTML5) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.
> Covers: RDWeb login page certificate warning, "The user name or password is incorrect" on `/RDWeb`, "There are currently no resources available" / empty workspace, a published desktop or RemoteApp missing for some users, `webfeed.aspx` subscription failures (RemoteApp and Desktop Connections, Windows App on macOS/iOS), HTML5 web client "An unexpected server authentication certificate was received", "We couldn't connect to the gateway because of an error", and web client install/publish failures.
> Deep dive: `RDWebAccess-A.md` · Script: `../Scripts/Get-RDWebAccessDiagnostics.ps1` · Launch works but the session fails? → `RDGateway-B.md` / `RDSLicensing-B.md` / `RDP-B.md`

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run on the **RD Web Access server** (elevated **Windows PowerShell 5.1** — the RDWebClientManagement module does not run under PowerShell 7):

```powershell
Get-Service W3SVC, WAS | Select Name, Status
Import-Module WebAdministration; Get-WebAppPoolState -Name RDWebAccess
Get-ChildItem IIS:\SslBindings | Select IPAddress, Port, Host, @{n='Thumb';e={$_.Thumbprint}}, Store
Get-ChildItem Cert:\LocalMachine\My | Where Thumbprint -in (Get-ChildItem IIS:\SslBindings | Where Port -eq 443).Thumbprint | Select Subject, NotAfter, @{n='SAN';e={$_.DnsNameList -join ','}}
Get-RDWebClientPackage -ErrorAction SilentlyContinue   # installed/published HTML5 client versions
```

Run on the **Connection Broker** (or anywhere with the RemoteDesktop module and broker rights):

```powershell
Get-RDServer -ConnectionBroker <broker.fqdn> | Select Server, Roles
Get-RDCertificate -ConnectionBroker <broker.fqdn> | Select Role, Level, ExpiresOn, Thumbprint, Subject
Get-RDSessionCollection -ConnectionBroker <broker.fqdn> | ForEach-Object { Get-RDSessionCollectionConfiguration -CollectionName $_.CollectionName -UserGroup -ConnectionBroker <broker.fqdn> }
```

| Result | Meaning | Go to |
|---|---|---|
| Browser cert warning on `https://<fqdn>/RDWeb` | RD Web cert expired/untrusted, or users typing a name not in the SAN | Fix 1 |
| `RDWebAccess` app pool `Stopped` | Pool crashed/identity broken → HTTP 503 | Fix 2 |
| Login loops / "user name or password is incorrect" for valid creds | Wrong username format, expired/must-change password, or account lockout | Fix 3 |
| Login OK but "no resources available" | User not in collection `UserGroup` / RemoteApp `UserGroups`, or RD Web can't query broker | Fix 4 |
| Only the full desktop icon is missing | Collection publishes RemoteApps → desktop hidden unless `ShowInWebAccess` | Fix 5 |
| Feed subscription (`webfeed.aspx`) fails / "no connections" | Feed URL wrong, email discovery TXT missing, feed cert untrusted | Fix 6 |
| HTML5 client: "unexpected server authentication certificate was received" | Broker cert renewed, RD Web still has the old `.cer` imported | Fix 7 |
| HTML5 client: resources listed but "couldn't connect to the gateway" | RD Gateway cert not publicly trusted, or gateway missing WebSocket support | Fix 8 |
| `Install-RDWebClientPackage` / `Publish-` errors | Old PowerShellGet on 2016, TLS 1.2 off, run in PS7, or RDWeb role not detected | Fix 9 |
| Everything shows `RDRedirector`/`RDPublishing` cert `ExpiresOn` in the past | Deployment certs expired — fixes 1, 7 and `RDGateway-B.md` Fix 2 together | Fix 1 + Fix 7 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
User launches a published desktop/RemoteApp from RD Web or the HTML5 client
└── DNS: RD Web FQDN resolves (public + internal split-brain), TCP 443 reaches IIS
    └── TLS: RD Web cert (Role RDWebAccess) valid, publicly trusted, SAN = FQDN in the URL
        └── IIS Default Web Site → /RDWeb apps, RDWebAccess app pool running
            └── Forms/Windows auth against AD (DOMAIN\user or UPN, password not expired)
                └── RD Web queries the Connection Broker for the user's resources
                    ├── User ∈ collection UserGroup AND (RemoteApp UserGroups empty OR contains user)
                    └── Desktop icon shown only if ShowInWebAccess = $true
                        └── Launch
                            ├── Classic: .rdp file (signed with RDPublishing cert) → mstsc → RD Gateway
                            └── HTML5: webclient JS → WebSocket to RD Gateway (2016+, public cert)
                                  └── Broker cert (RDRedirector) == .cer imported on RD Web
                                      └── Per-User CAL licensing (web client consumes Per-Device CALs per browser)
                                          └── RD Gateway CAP/RAP → RDSH → licensing → session
```
</details>

---
## Diagnosis & Validation Flow

1. **Can the page load cleanly?** From the client browse `https://<rdweb.fqdn>/RDWeb/` — expect the login form, no cert warning.
   Warning = Fix 1. HTTP 503 = Fix 2. HTTP 404 = RDWeb role not installed on this node / LB sending traffic elsewhere.

2. **Does auth succeed?** Log in with `DOMAIN\user`. Then check IIS log: `Get-Content C:\inetpub\logs\LogFiles\W3SVC1\u_ex$(Get-Date -f yyMMdd).log -Tail 200 | Select-String 'RDWeb/Pages'`.
   `POST .../login.aspx` returning 200 again (not 302) = auth rejected → Fix 3.

3. **Does the broker return resources for this user?**
   `Get-RDRemoteApp -CollectionName <c> -ConnectionBroker <b> | Select DisplayName, ShowInWebAccess, UserGroups`
   User missing from both the collection `UserGroup` and (non-empty) app `UserGroups` → Fix 4.

4. **Does the feed work?** From a domain client: `Invoke-WebRequest https://<rdweb.fqdn>/RDWeb/Feed/webfeed.aspx -UseDefaultCredentials -UseBasicParsing | Select StatusCode` → `200` with XML. 401 when unauthenticated is normal. Name resolution/cert errors = Fix 6.

5. **HTML5 client only.** Open `https://<rdweb.fqdn>/RDWeb/webclient/index.html`. Reproduce, then **About → Capture support information → Start/Stop recording** → `RD Console Logs.txt`. Cert-thumbprint error = Fix 7; gateway error = Fix 8.

6. **Launch reaches the gateway?** Check `Microsoft-Windows-TerminalServices-Gateway/Operational` on the gateway for the user (200/201/301/302/304). No gateway events = launch never left the client — Fixes 7/8; gateway events = continue in `RDGateway-B.md`.

---
## Common Fix Paths

<details><summary>Fix 1 — RD Web certificate expired, untrusted or name mismatch</summary>

```powershell
# On the broker — deployment-managed (preferred; updates IIS binding on every RD Web server)
$pw = Read-Host -AsSecureString "PFX password"
Set-RDCertificate -Role RDWebAccess -ImportPath '<\\share\rdweb.pfx>' -Password $pw -ConnectionBroker <broker.fqdn> -Force
# Most deployments reuse one SAN/wildcard cert for all four roles:
'RDGateway','RDPublishing','RDRedirector' | ForEach-Object {
    Set-RDCertificate -Role $_ -ImportPath '<\\share\rdweb.pfx>' -Password $pw -ConnectionBroker <broker.fqdn> -Force }
Get-RDCertificate -ConnectionBroker <broker.fqdn> | Select Role, Level, ExpiresOn, Subject
```
`Level` must be `Trusted`. Users must browse to a name in the SAN — publish **one** FQDN (e.g. `remote.contoso.com`) and split-brain DNS it internally.
Renewing `RDRedirector`/`RDPublishing` **requires Fix 7 afterwards** if the HTML5 client is published.
Rollback: re-run `Set-RDCertificate` with the previous PFX (keep it until validated).
</details>

<details><summary>Fix 2 — RDWebAccess app pool stopped / HTTP 503</summary>

```powershell
Import-Module WebAdministration
Get-ItemProperty IIS:\AppPools\RDWebAccess | Select name, state, managedRuntimeVersion, @{n='Identity';e={$_.processModel.identityType}}
Get-WinEvent -LogName System -MaxEvents 200 | Where { $_.ProviderName -in 'WAS','Microsoft-Windows-WAS' } | Select -First 10 TimeCreated, Id, Message
Start-WebAppPool -Name RDWebAccess
```
Rapid-fail after start = check `System` for WAS 5002/5021; the default identity is `ApplicationPoolIdentity` — someone changing it to a user whose password expired is the classic cause. Set it back:
`Set-ItemProperty IIS:\AppPools\RDWebAccess -Name processModel.identityType -Value ApplicationPoolIdentity`
</details>

<details><summary>Fix 3 — Valid credentials rejected at login</summary>

- RD Web needs `DOMAIN\user` or `user@upn` — bare `user` fails. Tell users, or brand the login page hint (customising `login.aspx` is unsupported and is overwritten by updates).
- Expired / "must change at next logon": RD Web cannot sign in. Enable the password change page:

```powershell
Import-Module WebAdministration
Set-WebConfigurationProperty -PSPath 'IIS:\Sites\Default Web Site\RDWeb\Pages' -Filter "appSettings/add[@key='PasswordChangeEnabled']" -Name value -Value 'true'
# Users then browse https://<rdweb.fqdn>/RDWeb/Pages/en-US/password.aspx
```
- Lockouts: check the PDC for 4740 (`Get-WinEvent -ComputerName <PDC> -FilterHashtable @{LogName='Security';Id=4740} -MaxEvents 20`) → `ActiveDirectory` lockout runbooks. A stale saved password in a subscribed feed on another device is a frequent source.
</details>

<details><summary>Fix 4 — "No resources available" / specific apps missing</summary>

```powershell
$b = '<broker.fqdn>'; $c = '<CollectionName>'
Get-RDSessionCollectionConfiguration -CollectionName $c -UserGroup -ConnectionBroker $b
Get-RDRemoteApp -CollectionName $c -ConnectionBroker $b | Select DisplayName, Alias, ShowInWebAccess, @{n='Groups';e={$_.UserGroups -join ';'}}
# Add the user's group to the collection
Set-RDSessionCollectionConfiguration -CollectionName $c -UserGroup (@((Get-RDSessionCollectionConfiguration -CollectionName $c -UserGroup -ConnectionBroker $b).UserGroup) + 'CONTOSO\RDS-Users') -ConnectionBroker $b
# Or scope an app: empty UserGroups = everyone in the collection
Set-RDRemoteApp -CollectionName $c -Alias '<alias>' -UserGroups 'CONTOSO\App-Users' -ConnectionBroker $b
```
Group membership changes need the user to sign out of RD Web and back in (new token). If **no user** sees anything, RD Web can't reach the broker: confirm this RD Web server appears in `Get-RDServer` with role `RDS-WEB-ACCESS`, and that it resolves/reaches the broker (`Test-NetConnection <broker> -Port 5985` and `-Port 135`).
</details>

<details><summary>Fix 5 — Full desktop icon missing</summary>

When a session collection publishes any RemoteApp, the desktop is hidden. To show both:
```powershell
Set-RDRemoteDesktop -CollectionName '<CollectionName>' -ShowInWebAccess $true -ConnectionBroker <broker.fqdn>
```
</details>

<details><summary>Fix 6 — Feed subscription (RemoteApp and Desktop Connections / Windows App) fails</summary>

- Feed URL must be exactly `https://<rdweb.fqdn>/RDWeb/Feed/webfeed.aspx` (or the email address, if discovery is set up).
- Email discovery needs a DNS **TXT** record `_msradc.<emaildomain>` with the feed URL as its value:
  `Resolve-DnsName _msradc.contoso.com -Type TXT`
- Feed cert must be trusted by the client with no warning — the feed client cannot "click through".
- Windows App (macOS/iOS): **Add Workspace** → feed URL; same trust/DNS rules. Windows clients: Control Panel → RemoteApp and Desktop Connections, or `mstsc` for plain desktops.
- Resources only update on the client's refresh schedule; force a refresh from the RADC control panel / Windows App workspace menu.
</details>

<details><summary>Fix 7 — HTML5: "An unexpected server authentication certificate was received"</summary>

The error shows a thumbprint. Match it to the broker cert and re-import on **every** RD Web server:
```powershell
# On the broker
Get-RDCertificate -Role RDRedirector -ConnectionBroker <broker.fqdn> | Select Thumbprint, ExpiresOn
$t = (Get-RDCertificate -Role RDRedirector -ConnectionBroker <broker.fqdn>).Thumbprint
Export-Certificate -Cert (Get-Item "Cert:\LocalMachine\My\$t") -FilePath C:\Temp\broker.cer   # public key only
# On each RD Web server (Windows PowerShell 5.1, elevated)
Import-RDWebClientBrokerCert C:\Temp\broker.cer
Publish-RDWebClientPackage -Type Production -Latest
```
If the broker cert isn't in `LocalMachine\My` on the broker (HA brokers, cert set via PFX), export the `.cer` from the source PFX instead. Make this a step in the cert-renewal change.
</details>

<details><summary>Fix 8 — HTML5: resources listed but "couldn't connect to the gateway"</summary>

- Browsers can't click through a WebSocket cert warning: the **RD Gateway cert must be publicly trusted** and match the gateway FQDN (`Get-RDCertificate -Role RDGateway`).
- Gateway must be Server 2016+ and patched (KB4025334 or any later CU).
- Reverse proxies/WAFs must pass WebSocket upgrade on `/remoteDesktopGateway/`. The web client supports **Entra application proxy** but **not** AD FS Web Application Proxy.
- Then check gateway events per `RDGateway-B.md` (201 CAP / 301 RAP / 304 resource).
</details>

<details><summary>Fix 9 — Web client install/publish fails</summary>

```powershell
# Windows PowerShell 5.1, elevated, on the RD Web server
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Install-Module -Name PowerShellGet -Force     # Server 2016 inbox version is too old — then RESTART PowerShell
Install-Module -Name RDWebClientManagement
Install-RDWebClientPackage
Import-RDWebClientBrokerCert <path\broker.cer>
Publish-RDWebClientPackage -Type Production -Latest
```
- "RD Web Access does not appear to be installed" → you are on the wrong server or the RDWeb role/IIS app is broken; `Get-WindowsFeature RDS-Web-Access`.
- "installed using an older version of RDWebClientManagement" → uninstall old client with the old module version first (see MS Learn link below).
- Per-Device CAL warning during publish is informational if the deployment is Per User; if it **is** Per Device, switch — every browser consumes a device CAL.
- Test before production: `Publish-RDWebClientPackage -Type Test -Latest` → `/RDWeb/webclient-test/index.html`.
</details>

---
## Escalation Evidence

```
Ticket: ______   Tenant/Customer: ______   Engineer: ______   Date/time (UTC): ______
RD Web URL(s): https://________/RDWeb   Web client published: Y/N  version: ______
Broker(s): ______ (HA? Y/N)   Gateway FQDN: ______   Collection(s): ______
Affected users: all / some (group: ______)   Client: browser/Windows RADC/Windows App (mac/iOS)/mstsc
Exact error text / screenshot: ______
Get-RDCertificate (Role, Level, ExpiresOn, Thumbprint): ______
Thumbprint in HTML5 error (if any): ______   .cer last imported on RD Web: ______
IIS log lines for user's login attempt: ______
RDWebAccess app pool state: ______   RD Web cert SAN: ______
Collection UserGroup / RemoteApp UserGroups for affected app: ______
RD Console Logs.txt attached: Y/N    Get-RDWebAccessDiagnostics.ps1 CSV attached: Y/N
Gateway events for the attempt (200/201/301/302/304): ______
Fixes already tried: ______
```

---
## 🎓 Learning Pointers
- The HTML5 client pins the broker's **RDRedirector** certificate via the `.cer` you import — so cert renewal is a two-server change. Put `Import-RDWebClientBrokerCert` in the renewal runbook: [Set up the Remote Desktop web client](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remote-desktop-web-client-admin).
- One public FQDN + one SAN/wildcard cert for all four deployment roles (`Get-RDCertificate`) removes most "name mismatch" tickets; split-brain DNS it internally.
- RD Web visibility is two filters stacked: collection `UserGroup` then RemoteApp `UserGroups` — empty app groups means "everyone in the collection", not "nobody".
- The web client consumes a **Per-Device** CAL per browser if the deployment isn't Per User — check `RDSLicensing-B.md` before rolling it out.
- For MFA in front of RD Web, prefer [Entra application proxy with RDS](https://learn.microsoft.com/en-us/entra/identity/app-proxy/application-proxy-integrate-with-remote-desktop-services) (supported by the web client) or the NPS extension on the gateway (`RDGateway-A.md`); AD FS WAP is not supported for the web client.
- Always capture **RD Console Logs.txt** (About → Capture support information) before escalating HTML5 issues — it shows the exact gateway/broker step that failed.
