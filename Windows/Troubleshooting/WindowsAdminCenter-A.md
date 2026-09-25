# Windows Admin Center (WAC) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

> **Currency (Sept 2026):** Covers the **modernized gateway** (WAC 2410 / build 2.4.x onward, current GA **2511**, build 2.6.x, installer refreshes 2.6.4.11 in Feb 2026 and 2.6.7 in May 2026). It also covers the legacy gateway (2311 and earlier) for migration and comparison. Primary sources: [What is WAC](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/understand/what-is), [Troubleshoot WAC](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/support/troubleshooting), [Known issues](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/support/known-issues), [Update the certificate](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/configure/update-certificate), [2511 GA announcement](https://techcommunity.microsoft.com/blog/windows-admin-center-blog/windows-admin-center-version-2511-is-now-generally-available/4477048), and [Joze Markic, WACv2 installation deep dive](https://blog.markic.org/2025/03/03/deep-dive-into-windows-admin-center-v2-wacv2-installation/) for installer internals.

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
- **In scope:** the self-hosted WAC gateway on Windows Server (service mode) or Windows 10/11 (desktop mode), and its connectivity to managed Windows Server / client / cluster targets. Also covers certificates, authentication and login modes, gateway RBAC, WinRM/Kerberos/CredSSP, extensions, upgrades, and HA.
- **Partly in scope:** **WAC in the Azure portal** (for Arc-enabled servers and Azure VMs). That's a different delivery model with no customer gateway, and it's covered here only to help you choose between the two.
- **Out of scope:** extension-specific functional bugs (HCI/Azure Local, cluster tools), and Azure Local deployment itself.
- **Assumptions:** you're a local admin on the gateway, and you can run elevated PowerShell 5.1 on the gateway and targets. Examples use a domain-joined gateway unless marked *workgroup*.
- **Not supported:** installing on a **domain controller**. It can be forced to work, but the installer stalls and CredSSP group creation fails. Don't do this for customers.

---
## How It Works
<details><summary>Full architecture</summary>

### Three tiers
```
[ Browser (Edge/Chrome) ]  --HTTPS (443 server / 6600 client) + WebSockets-->
[ WAC gateway ]            --WinRM (PS remoting + WMI/CIM) 5985/5986-->
[ Managed nodes ]
```
The browser never talks to the managed servers directly. **All** management traffic is PowerShell and CIM that the gateway runs over WinRM using the signed-in user's credentials, or explicitly supplied "Manage as" credentials. That's why the gateway is only as capable as `Enter-PSSession` from that host.

### Legacy vs modernized gateway
| Aspect | Legacy (≤ 2311) | Modernized (2410+ / "v2") |
|---|---|---|
| Runtime | .NET Framework 4.6.2, Katana/OWIN | **.NET 8**, ASP.NET Core **Kestrel** |
| Process model | Single process `sme.exe` | Process manager plus per-task/per-plug-in **sub-processes** |
| Service name | `ServerManagementGateway` | **`WindowsAdminCenter`** |
| Protocol | HTTP/1.1 | HTTP/2 supported |
| Ports | One port | Front end `WacPort` (443 server / 6600 client) plus **service port range 6601–6610** |
| Default login | NTLM/Kerberos (Windows auth) | **FormLogin** (HTML form). Windows auth and **AadSso** are optional |
| Installer | MSI | Inno Setup `.exe`, driven by the `Microsoft.WindowsAdminCenter.Configuration` module |
| Install logs | MSI verbose log | `%TEMP%\Setup Log <date> #00x.txt` plus `C:\ProgramData\WindowsAdminCenter\Logs\Configuration.log` |
| Event log | `Microsoft-ServerManagementExperience` | **`WindowsAdminCenter`** |
| HA | Supported | Removed in 2410, **restored in 2511** |

**Why FormLogin matters:** with NTLM/Kerberos the gateway gets a token limited to localhost. Some APIs (for example DeploymentShare) then fail for non-admins. Form login gets around that restriction. With Windows auth, integrated authentication **can't run over HTTP/2**, which causes the "outdated or unsafe TLS" browser error on machines that force HTTP/2.

### What the installer actually does
The installer is a scripted sequence of `*-WAC*` cmdlets. In order, Express mode on Server runs roughly:
`Set-WACNetworkServiceAccess` → `Enable-WACPSRemoting` (runs `Enable-PSRemoting -Force`, which **drops any remote PS session you're installing over**) → `New-WACSelfSignedCertificate` (60-day cert) or use your thumbprint → `Set-WACEndpointFqdn` → `Register-WACService -Automatic` → `Set-WACWinRmTrustedHosts -TrustAll` → `Set-WACWinRmOverHttps` → `Set-WACSoftwareUpdateMode` → `Set-WACLoginMode -Mode FormLogin` → `Set-WACCertificateSubjectName` → `Set-WACCertificateAcl` → `Set-WACHttpsPorts -WacPort 443 -ServicePortRangeStart 6601 -ServicePortRangeEnd 6610` → `Register-WACFirewallRule -Port 443` → `Register-WACLocalCredSSP` → `Initialize-WACDatabase` → `Import-WACExistingExtensions` → `New-WACEventLog` → `Start-WACLauncher`.

Consequences:
- **Express defaults set TrustedHosts to `*`.** That's convenient, but a security review will flag it. Custom mode lets you choose "trusted domain computers only".
- **Every installer step can be rerun by hand.** If one step failed (see `Configuration.log`), you can finish the install from the module instead of reinstalling.
- Silent installs (`/silent`, `/verysilent`, `/log=`) only expose Inno's standard settings. For custom values, install silently and then run the cmdlets afterwards.
- **Desktop (client OS) differences:** port 6600, localhost-only, service set to On-Demand, no firewall rule.

### Certificates
- Service mode needs a TLS cert in `LocalMachine\My` with the Server Authentication EKU, a private key, and the user-facing FQDN in the subject/SAN. The chain must be trusted by the admin workstations.
- The service runs as **NETWORK SERVICE**, so that account needs read access to the private key (`Set-WACCertificateAcl`). A missing ACL is the classic "service starts then stops" or "TLS handshake fails" cause.
- `Set-WACCertificateSubjectName` takes `-SubjectName` or `-Thumbprint`, plus `-Target All|FrontEnd|Service`. The front end and the internal sub-process endpoints can use different certs. A **mismatch or invalid cert on the internal endpoints breaks v2 even when the browser looks fine**, because the sub-processes talk to each other over TLS.
- Self-signed certs from the installer expire after **60 days**. That makes for a predictable ticket two months after a PoC becomes production.

### Authentication and authorization layers
1. **Gateway access** decides who can open WAC: *Gateway users* and *Gateway administrators* (local groups, AD groups, or Entra ID when registered with Azure). Being a gateway admin gives **no** rights on the gateway OS.
2. **Target access** is the credentials WAC passes over WinRM. These must be a local admin on the target, or have a **WAC RBAC** JEA role (Administrators / Hyper-V Administrators / Readers) deployed to the target. RBAC can't deploy on targets running **WDAC**. In clusters, deploy it per node.
3. **Delegation**: Kerberos constrained delegation (resource-based) from the gateway lets WAC act on targets without CredSSP. The cluster creation and CAU tools still use **CredSSP**, managed through the local *Windows Admin Center CredSSP Administrators* group and `Register-WACLocalCredSSP`.

### High availability (2511)
2511 restores failover-cluster deployment. The gateway runs as a clustered generic role with shared program-files access. The module includes `Set-WACHAProgramFilesAccess`, `Update-WACHAAppSettings`, `New/Start/Update/Remove-WACHARole`, `Test-WACClusterRole` and `Register-WACClusterScheduledTask`. The certificate must cover the **client access point name**, not the node names.

### WAC in the Azure portal
For **Azure VMs** and **Arc-enabled servers**, WAC runs as a VM/Arc extension. You open it from the Azure portal, it's authenticated with Entra ID, and it's authorized with the Azure RBAC role *Windows Admin Center Administrator Login*. It needs no inbound ports, VPN or customer gateway. MSPs managing many small tenants can use it to avoid maintaining publicly reachable gateways.
</details>

---
## Dependency Stack
```
L7  Extensions (Server Manager, Cluster, Hyper-V, partner) ── reinstalled after every WAC update
L6  WAC RBAC / JEA endpoints on targets (optional) ── blocked by WDAC on target
L5  Target authorization: local Administrators / Remote Management Users / LocalAccountTokenFilterPolicy
L4  WinRM transport: service + listener 5985/5986, firewall scope, Kerberos (HTTP SPN), TrustedHosts, CredSSP
L3  Gateway authentication: FormLogin | WindowsAuthentication | AadSso; Gateway users/admins groups
L2  Gateway service: WindowsAdminCenter (NETWORK SERVICE), Kestrel, ports WacPort + 6601–6610, DB under ProgramData
L1  TLS: cert in LocalMachine\My, private-key ACL, http.sys binding, chain trust on clients
L0  Host: Windows Server 2016+ member server (not DC) or Win10 1709+/11; PSModulePath intact; .NET runtime bundled
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Service starts then stops | Bound cert missing, or NETWORK SERVICE can't read the key | `Configuration.log`, `netsh http show sslcert`, key ACL in certlm.msc |
| Browser "connection isn't private" 60 days after install | Installer self-signed cert expired | `Get-ChildItem Cert:\LocalMachine\My` → NotAfter |
| New CA cert set but browser still shows the old/self-signed cert | Non-unique subject, `-Target` only partially applied, or the SAN-cert issue seen on 2410 | `netsh http show sslcert` hash vs the intended thumbprint |
| Pasted thumbprint rejected | Invisible leading character from MMC copy | Retype the first character |
| Installer "failed" or WAC won't open after upgrading a v2 build | Older modernized build left behind | Uninstall, reboot, reinstall (documented fix) |
| Cert missing after 2311 → 2410 upgrade | Known migration bug (international locale/special characters) | Re-run `Set-WACCertificateSubjectName` |
| "Site can't be reached" remotely, OK locally | Firewall/NSG/proxy | `Test-NetConnection <gw> -Port 443` from the client |
| "Can't connect securely… outdated TLS" | HTTP/2-only browser machine + Windows auth | `HKLM\...\Http\Parameters` EnableHttp2Tls/Cleartext |
| "You are not authorized to view this page" | Wrong client cert chosen / stale cache | InPrivate test |
| RDP, PowerShell, Events, Packet Monitor tools blank | WebSockets stripped by proxy/WAF | Bypass proxy for the gateway FQDN |
| Some targets fail, others fine | Target-side WinRM/firewall/SPN | `Enter-PSSession` from the gateway |
| `0x8009030e` | Local account to a domain target, target can't reach a DC, or not in TrustedHosts | TrustedHosts, DC reachability |
| `0x80090322` | HTTP SPN registered to a service account | `setspn -Q HTTP/<fqdn>` |
| WinRM HTTP 500 | Listener misconfigured / file permissions on target | Target WinRM operational log |
| Workgroup target, local admin denied | UAC remote token filtering | `LocalAccountTokenFilterPolicy` |
| Cluster create/validate "error during the validation" | CredSSP state corruption | Disable-WSManCredSSP client/server, repair secure channel |
| Event export "packet size" error | WinRM MaxEnvelopeSizekb | `winrm get winrm/config` |
| Extensions gone after update | By design, they must be reinstalled | Settings → Extensions |
| Extension feed silently empty | Unreachable feed, no error shown | `Get-WACProxy`, feed URL |
| Connection list garbled | Corrupt per-gateway store | Destructive reset (Playbook 6) |
| Heavy gateway on WS2016 crashes (`sme.exe` / `WsmSvc.dll`) | Legacy v1 bug on 2016 | KB4480977 or later CU; better, move to v2 on WS2022/2025 |
| RBAC deploy fails on a target | Target runs WDAC | App Control policy allowances, or no RBAC there |
| Volume deletions misbehave in Cluster Manager | Cluster Manager extension < 5.2.6 | Update to WAC 2511 build 2.6.6.18+ or extension 5.2.6+ |

---
## Validation Steps
1. **Generation and version**
   `(Get-Item "$env:ProgramFiles\WindowsAdminCenter\WindowsAdminCenter.exe").VersionInfo.FileVersion`
   Good: `2.6.x` (2511). Bad: `2.4.x`, which is behind (2410). No such file plus a `ServerManagementGateway` service means legacy v1.
2. **Service**
   `Get-Service WindowsAdminCenter` → `Running`, StartType `Automatic` (service mode). On a desktop install, `Manual` is normal.
3. **Listener and binding**
   `netsh http show sslcert` → one entry for `0.0.0.0:<WacPort>` or `[::]:<WacPort>` whose hash equals the intended thumbprint. Bad: the hash points at a cert that isn't in `LocalMachine\My`.
4. **Certificate fitness**
   `Get-Item Cert:\LocalMachine\My\<tp> | fl DnsNameList, NotAfter, HasPrivateKey, EnhancedKeyUsageList`
   Good: FQDN present, > 30 days left, private key present, Server Authentication EKU.
5. **Private-key ACL**
   Use certlm.msc → Manage Private Keys, or use the evidence script. Good: `NETWORK SERVICE` has Read.
6. **Local HTTPS**
   `Invoke-WebRequest https://<gw-fqdn> -UseBasicParsing` → 200/302. Bad: a TLS exception means the cert or binding is wrong, and a timeout means the service or port is the problem.
7. **Remote HTTPS**
   Run `Test-NetConnection <gw-fqdn> -Port 443` from an admin workstation → `TcpTestSucceeded : True`.
8. **Gateway → target WinRM**
   `Test-WSMan <target>` returns protocol info. `Enter-PSSession <target>` opens a prompt.
9. **Kerberos health**
   `klist get HTTP/<target-fqdn>` on the gateway succeeds. `setspn -Q HTTP/<target-fqdn>` returns the **computer** account, or nothing (the default HOST SPN covers it).
10. **Event log clean**
    `Get-WinEvent -LogName WindowsAdminCenter -MaxEvents 50` has no repeating errors.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Install / upgrade**
- Always install with `/log=<path>`. Read `Configuration.log` for the last successful cmdlet. Everything after it can be run by hand.
- Don't install over a PowerShell remoting session, because `Enable-WACPSRemoting` resets WinRM and kills the session. Use PsExec/SCCM/Intune or console access.
- Upgrading from v1: export connections with the old gateway's `Export-Connection` first, and record the cert thumbprint and port. The v2 migration module (`Update-WACEnvironment`) migrates settings and the DB, but treat the cert as something you'll re-apply.

**Phase 2 — Gateway reachability (browser → gateway)**
- Split local vs remote: local `Invoke-WebRequest` first, then `Test-NetConnection` from the client, then an InPrivate browser.
- Proxies: WAC needs WebSockets. Behind a reverse proxy (App Proxy, NGINX, F5), configure WebSocket upgrade and long idle timeouts. Otherwise the RDP, PowerShell and Events tools fail while other pages load.

**Phase 3 — Gateway authentication**
- Form login failing for domain users → check that the gateway can reach a DC and that the user is in *Gateway users*.
- Want SSO? Choose Windows auth (Kerberos needs `HTTP/<gw-fqdn>` on the gateway computer account) or AadSso (requires Azure registration). Remember the HTTP/2 constraint for Windows auth.

**Phase 4 — Target connectivity**
- Reproduce in plain PowerShell **from the gateway, as the same user**. If `Enter-PSSession` fails, WAC is not the problem.
- Walk this order: DNS → TCP 5985 → `Test-WSMan` → auth (Kerberos vs NTLM, TrustedHosts) → authorization (admin/RBAC) → UAC token filtering.

**Phase 5 — Tool-specific**
- The Cluster, CAU and HCI deploy tools use CredSSP. Group membership changes need the user to **sign out and back in** on the gateway (or the desktop, in desktop mode).
- Files larger than 100 MB can't be uploaded or downloaded through WAC. That's a product limit, not a fault.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Replace an expiring or wrong certificate (zero-downtime-ish)</summary>

```powershell
Import-Module "$env:ProgramFiles\WindowsAdminCenter\PowerShellModules\Microsoft.WindowsAdminCenter.Configuration"
$old = (netsh http show sslcert | Select-String 'Certificate Hash\s+:\s+(\w+)').Matches | Select-Object -First 1 | ForEach-Object { $_.Groups[1].Value }
"Old thumbprint: $old" | Tee-Object "$env:TEMP\WAC-oldcert.txt"

$new = '<new thumbprint>'
$c = Get-Item "Cert:\LocalMachine\My\$new"
if (-not $c.HasPrivateKey) { throw 'New certificate has no private key' }
Set-WACCertificateSubjectName -Thumbprint $new -Target All
Set-WACCertificateAcl -SubjectName $c.Subject
Restart-Service WindowsAdminCenter
Start-Sleep 10
netsh http show sslcert | Select-String 'Certificate Hash'
```
**Rollback:** `Set-WACCertificateSubjectName -Thumbprint $old -Target All; Restart-Service WindowsAdminCenter`.
</details>

<details><summary>Playbook 2 — Lock down TrustedHosts after an Express install</summary>

```powershell
$cur = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
$cur | Out-File "$env:ProgramData\WAC-TrustedHosts.bak"
# Domain-only estate: TrustedHosts not needed for Kerberos → clear it
Clear-Item WSMan:\localhost\Client\TrustedHosts -Force
# Mixed estate: list only the workgroup/IP-addressed nodes
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '<wg-node1>,<wg-node2>' -Force
```
**Rollback:** `Set-Item WSMan:\localhost\Client\TrustedHosts -Value (Get-Content "$env:ProgramData\WAC-TrustedHosts.bak") -Force`.
Test afterwards: connect to one domain node and one workgroup node in WAC.
</details>

<details><summary>Playbook 3 — Fix Kerberos to a target with a hijacked HTTP SPN</summary>

```powershell
setspn -Q HTTP/<target-fqdn>                       # who owns it?
setspn -S HTTP/<target-fqdn>:5985 <TARGET-NETBIOS> # add port-specific SPN to computer account
# Test with port-in-SPN
Enter-PSSession -ComputerName <target-fqdn> -SessionOption (New-PSSessionOption -IncludePortInSPN)
```
Don't remove the service account's `HTTP/<fqdn>` SPN unless the application owner agrees, because that would break SSRS/SharePoint. **Rollback:** `setspn -D HTTP/<target-fqdn>:5985 <TARGET-NETBIOS>`.
</details>

<details><summary>Playbook 4 — Resource-based Kerberos constrained delegation (avoid CredSSP)</summary>

Lets the gateway use the user's identity on the target for second-hop operations such as file shares or cluster calls.
```powershell
# On a machine with RSAT AD tools
$gw = Get-ADComputer '<GATEWAY>'
Set-ADComputer -Identity '<TARGET>' -PrincipalsAllowedToDelegateToAccount $gw
# Verify
Get-ADComputer '<TARGET>' -Properties PrincipalsAllowedToDelegateToAccount | Select-Object -ExpandProperty PrincipalsAllowedToDelegateToAccount
```
**Rollback:** `Set-ADComputer -Identity '<TARGET>' -PrincipalsAllowedToDelegateToAccount $null`. Note that this **overwrites** any existing list, so read it first and merge.
</details>

<details><summary>Playbook 5 — Clean reinstall with settings preserved</summary>

1. Record settings: `Get-WACLoginMode`, the ports (`Get-NetTCPConnection -State Listen -OwningProcess (Get-Process WindowsAdminCenter*).Id`), the cert thumbprint, and TrustedHosts.
2. Export connections: `Export-WACConnection` (ConnectionTools module). Confirm the parameters with `Get-Help Export-WACConnection -Full`.
3. Uninstall, then reboot.
4. Install the current build: `Start-Process WindowsAdminCenter.exe -Wait -ArgumentList '/log=C:\Temp\WAC.log /verysilent'`.
5. Re-apply the cert (Playbook 1), login mode (`Set-WACLoginMode -Mode <mode>`), and ports (`Set-WACHttpsPorts`). Restart the service.
6. Import connections (`Import-WACConnection`) and reinstall extensions.
</details>

<details><summary>Playbook 6 — Corrupt connection list (destructive)</summary>

Wipes connections and per-user settings for **every** gateway user. Export connections first (Playbook 5, step 2).
1. Uninstall WAC.
2. `Remove-Item 'C:\Windows\ServiceProfiles\NetworkService\AppData\Roaming\Microsoft\Server Management Experience' -Recurse -Force`
3. Reinstall, then re-import connections.
**Rollback:** none. Take a copy of the folder before deleting it, because it can be restored while the service is stopped.
</details>

<details><summary>Playbook 7 — Workgroup / DMZ targets</summary>

On the target:
```powershell
Enable-PSRemoting -Force
Set-NetFirewallRule -Name WINRM-HTTP-In-TCP-PUBLIC -RemoteAddress <gateway-IP>
New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 1 -Force
```
On the gateway, add the target to TrustedHosts (Playbook 2). Better still for a DMZ, use **WinRM over HTTPS (5986)** with a cert on the target, and turn on `Set-WACWinRmOverHttps -Enable $true` on the gateway.
**Rollback:** set `LocalAccountTokenFilterPolicy` to 0 and narrow or restore the firewall rule scope.
</details>

---
## Evidence Pack
Run `Windows/Scripts/Get-WindowsAdminCenterHealth.ps1` on the gateway (optionally with `-Target <fqdn>,<fqdn>`). It exports CSV plus a log/event bundle. Minimal inline alternative:

```powershell
$out = "C:\Temp\WAC-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"; New-Item $out -ItemType Directory -Force | Out-Null
Get-Service WindowsAdminCenter, ServerManagementGateway, WinRM -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType | Export-Csv "$out\services.csv" -NoTypeInformation
(Get-Item "$env:ProgramFiles\WindowsAdminCenter\WindowsAdminCenter.exe" -ErrorAction SilentlyContinue).VersionInfo | Select-Object FileVersion, ProductVersion | Export-Csv "$out\version.csv" -NoTypeInformation
netsh http show sslcert > "$out\sslcert.txt"
netsh http show urlacl  > "$out\urlacl.txt"
Get-ChildItem Cert:\LocalMachine\My | Select-Object Thumbprint, Subject, NotAfter, HasPrivateKey, @{n='DNS';e={$_.DnsNameList -join ';'}} | Export-Csv "$out\certs.csv" -NoTypeInformation
Get-Item WSMan:\localhost\Client\TrustedHosts | Select-Object Value | Export-Csv "$out\trustedhosts.csv" -NoTypeInformation
Copy-Item 'C:\ProgramData\WindowsAdminCenter\Logs\*' $out -ErrorAction SilentlyContinue
Get-WinEvent -LogName WindowsAdminCenter -MaxEvents 500 -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\wac-events.csv" -NoTypeInformation
Compress-Archive "$out\*" "$out.zip" -Force; "Evidence: $out.zip"
```
Add a **HAR file** from the browser (F12 → Network → Preserve log → reproduce → Export HAR). **Redact** tokens and passwords before sending it.

---
## Command Cheat Sheet
| Purpose | Command |
|---|---|
| Load config module | `Import-Module "$env:ProgramFiles\WindowsAdminCenter\PowerShellModules\Microsoft.WindowsAdminCenter.Configuration"` |
| Service health | `Get-Service WindowsAdminCenter` / `Test-WACService` / `Restart-WACService` |
| Set certificate | `Set-WACCertificateSubjectName -Thumbprint <tp> [-Target All]` |
| Key ACL for NETWORK SERVICE | `Set-WACCertificateAcl -SubjectName '<CN=...>'` |
| Ports | `Set-WACHttpsPorts -WacPort 443 -ServicePortRangeStart 6601 -ServicePortRangeEnd 6610` |
| Firewall rule | `Register-WACFirewallRule -Port 443` |
| Login mode | `Get-WACLoginMode` / `Set-WACLoginMode -Mode FormLogin\|WindowsAuthentication\|AadSso` |
| Proxy used by gateway | `Get-WACProxy` / `Set-WACProxy` |
| WinRM over HTTPS to nodes | `Set-WACWinRmOverHttps -Enable $true` |
| Show SSL binding | `netsh http show sslcert` |
| Gateway → node test | `Test-WSMan <node>`; `Enter-PSSession <node>` |
| TrustedHosts | `Get-Item WSMan:\localhost\Client\TrustedHosts` |
| SPN check | `setspn -Q HTTP/<fqdn>` |
| Install with log | `WindowsAdminCenter.exe /log=C:\Temp\WAC.log /verysilent` |
| Config log | `Get-Content C:\ProgramData\WindowsAdminCenter\Logs\Configuration.log -Tail 80` |

---
## 🎓 Learning Pointers
- The modernized gateway is a **process manager plus sub-processes over internal TLS**. That's why a cert that looks fine in the browser can still break WAC: every internal endpoint has to trust it too. See [What is Windows Admin Center](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/understand/what-is).
- Treat the installer as a PowerShell script you can resume. `Configuration.log` plus the `*-WAC*` cmdlets let you finish a half-failed install without reinstalling. See [Markic's WACv2 deep dive](https://blog.markic.org/2025/03/03/deep-dive-into-windows-admin-center-v2-wacv2-installation/).
- Express mode sets **TrustedHosts to `*`**, which weakens NTLM server authentication. Revisit it after every PoC-to-production move. See [about_Remote_Troubleshooting](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_remote_troubleshooting).
- Use **resource-based constrained delegation** instead of CredSSP wherever the tool allows it, because CredSSP exposes reusable credentials on the target. See [Kerberos constrained delegation overview](https://learn.microsoft.com/en-us/windows-server/security/kerberos/kerberos-constrained-delegation-overview).
- For MSP estates, compare the cost of patching and exposing a self-hosted gateway with **WAC in the Azure portal** for Arc-enabled servers, where access is controlled by Azure RBAC and no inbound ports are needed. See [WAC and Azure integration](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/azure/).
- Related in this repo: `Windows/Troubleshooting/WinRM-A.md`/`-B.md` (transport layer WAC depends on), `Windows/Troubleshooting/Kerberos-A.md` and `ActiveDirectory/Troubleshooting/KerberosDelegation/` (SPN and RBCD), `Windows/Troubleshooting/CertificateServices-A.md` (issuing the gateway cert), `Azure/Arc/AzureArc-A.md` (prerequisite for WAC in the Azure portal).
- Keep the [known issues page](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/support/known-issues) bookmarked. Many "bugs" (100 MB file limit, extension reinstall after update, no RBAC on WDAC targets) are documented behaviour.
