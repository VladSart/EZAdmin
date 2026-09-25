# Windows Admin Center (WAC) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate "WAC won't load", "can't connect to server X", certificate errors, or a broken gateway after upgrade in under 10 minutes.

> **Context (Sept 2026):** Current WAC is the **modernized gateway** ("WACv2"): version 2410 (build 2.4.x) and later, now **2511** (2.6.x; installer refreshed to 2.6.4.11 in Feb 2026 and 2.6.7 in May 2026). It runs on a **.NET 8 / Kestrel** backend as the **`WindowsAdminCenter`** service with a multi-process model. The legacy gateway (2311 and earlier) ran as **`ServerManagementGateway`** on .NET Framework/Katana. Most "it broke after upgrade" tickets come from that architecture change. The gateway manages targets with **PowerShell remoting and WMI over WinRM (TCP 5985/5986)**. 2511 also brought back **high-availability (failover cluster) deployment**. Sources: [Troubleshoot WAC (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/support/troubleshooting); [WAC known issues (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/support/known-issues); [Update the WAC certificate (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/configure/update-certificate); [WAC 2511 GA (Tech Community)](https://techcommunity.microsoft.com/blog/windows-admin-center-blog/windows-admin-center-version-2511-is-now-generally-available/4477048).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Run on the **gateway** server, elevated.

```powershell
# 1. Which generation, and is the service up? (v2 = WindowsAdminCenter, v1 = ServerManagementGateway)
Get-Service WindowsAdminCenter, ServerManagementGateway -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType
(Get-Item "$env:ProgramFiles\WindowsAdminCenter\WindowsAdminCenter.exe" -ErrorAction SilentlyContinue).VersionInfo.FileVersion

# 2. What's listening, and which certificate is bound? (v2 uses 443 on Server / 6600 on client by default)
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object LocalPort -in 443, 6600, 6601, 6602, 6603, 6604, 6605, 6606, 6607, 6608, 6609, 6610 |
    Select-Object LocalAddress, LocalPort, OwningProcess, @{n='Process';e={(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName}}
netsh http show sslcert | Select-String 'IP:port|Hostname:port|Certificate Hash'

# 3. Is the bound certificate valid, matching, and in date?
Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } |
    Select-Object Thumbprint, Subject, NotAfter, @{n='SAN';e={($_.DnsNameList -join ', ')}}

# 4. Gateway → target: does WinRM work at all? (replace <target>)
Test-NetConnection -ComputerName <target> -Port 5985 -InformationLevel Quiet
Test-WSMan -ComputerName <target> -ErrorAction SilentlyContinue

# 5. Recent WAC errors
Get-WinEvent -LogName 'WindowsAdminCenter' -MaxEvents 30 -ErrorAction SilentlyContinue |
    Where-Object LevelDisplayName -in 'Error', 'Warning' | Select-Object TimeCreated, Id, LevelDisplayName, Message -First 10
```

| Finding | Action |
|---|---|
| `WindowsAdminCenter` service **Stopped** / crashing on start | Fix 1 (service + config log). Check `C:\ProgramData\WindowsAdminCenter\Logs\Configuration.log` |
| Both `ServerManagementGateway` and `WindowsAdminCenter` present after upgrade | Half-migrated. Fix 6 (clean reinstall) |
| Browser: "connection isn't private" / cert name mismatch / expired | Fix 2 (rebind certificate) |
| Cert looks right but browser still shows the 60-day **self-signed** one | Known 2410+ behaviour when a SAN/renewed cert is set. Fix 2, then check `netsh http show sslcert` matches the thumbprint |
| Nothing listening on 443/6600 | Service down or port changed. Fix 1 / Fix 3 |
| "This site can't be reached" but port listens locally | Firewall/NSG/proxy. Fix 3 |
| WAC loads, **some** servers connect, others don't | Target-side WinRM/Kerberos. Fix 4 |
| WAC loads, **no** targets connect, error `0x8009030e` | Local account vs domain, TrustedHosts, or DC unreachable. Fix 4 |
| Remote Desktop / PowerShell / Events tools blank or hang | WebSockets blocked by proxy/WAF. Fix 5 |
| "Can't connect securely… outdated or unsafe TLS" | HTTP/2 + Windows auth conflict on the **browser** machine. Fix 5 |
| "You are not authorized to view this page" after upgrade | Wrong client cert picked, or stale browser cache. Fix 5 |
| Extensions missing after upgrade | Expected: extensions must be reinstalled after updating WAC. Fix 7 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Browser (Edge / Chrome, current) on admin workstation
   │  HTTPS 443 (Server default) / 6600 (client default); WebSockets allowed end to end
   │  No HTTP/2-only restriction on the browser machine (integrated auth needs HTTP/1.1 fallback)
   ▼
Network path: DNS name → gateway, firewall rule "Windows Admin Center" / NSG / reverse proxy
   ▼
Gateway host (Windows Server 2016+ or Windows 10 1709+/11; NOT a domain controller)
   ├─ Service "WindowsAdminCenter" (NetworkService) Running, StartType Automatic
   │     ├─ Kestrel front end on WacPort + service sub-process ports 6601–6610
   │     ├─ http.sys SSL binding → certificate thumbprint
   │     └─ Database + extensions under C:\ProgramData\WindowsAdminCenter
   ├─ TLS certificate in LocalMachine\My
   │     ├─ Server Authentication EKU, private key present
   │     ├─ Subject/SAN = the FQDN users type
   │     ├─ NETWORK SERVICE has read on the private key (Set-WACCertificateAcl)
   │     └─ Chain trusted by the admin workstation
   ├─ Login mode: FormLogin (v2 default) | WindowsAuthentication | AadSso
   ├─ Gateway access: Gateway users / Gateway administrators groups
   └─ WinRM client: TrustedHosts (workgroup/local accounts), CredSSP client (cluster tools)
   ▼
Managed target (Windows Server 2016+ / Win10+ ; 2012 R2 needs WMF 5.1)
   ├─ WinRM service Running, listener on 5985 (HTTP) or 5986 (HTTPS)
   ├─ Firewall rule WINRM-HTTP-In-TCP[-PUBLIC] allows the gateway's subnet
   ├─ Kerberos: HTTP/<fqdn> SPN not hijacked by a service account
   ├─ Account is local Administrator (or WAC RBAC role / Remote Management Users)
   └─ Local non-builtin admin → LocalAccountTokenFilterPolicy = 1
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm generation and install path**
   ```powershell
   Test-Path "$env:ProgramFiles\WindowsAdminCenter\PowerShellModules\Microsoft.WindowsAdminCenter.Configuration"
   ```
   `True` = modernized gateway (v2). You can use the `*-WAC*` configuration cmdlets. `False` with a `ServerManagementGateway` service = legacy v1 (2311 or earlier). Plan an upgrade, because v1 is out of servicing.

2. **Load the config module and read current settings**
   ```powershell
   Import-Module "$env:ProgramFiles\WindowsAdminCenter\PowerShellModules\Microsoft.WindowsAdminCenter.Configuration"
   Get-WACLoginMode
   Test-WACService
   ```
   Expected: login mode `FormLogin` (or what you chose). `Test-WACService` returns healthy. If the module won't import, check `PSModulePath` (Fix 1).

3. **Check the certificate end to end**
   ```powershell
   $bind = netsh http show sslcert | Select-String 'Certificate Hash\s+:\s+(\w+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1
   Get-Item "Cert:\LocalMachine\My\$bind" | Format-List Subject, DnsNameList, NotAfter, HasPrivateKey, EnhancedKeyUsageList
   ```
   Good: `HasPrivateKey True`, `NotAfter` in the future, `DnsNameList` contains the FQDN users browse to, EKU includes Server Authentication. Bad: thumbprint not found (binding points at a deleted cert), or subject is the gateway's short name only.

4. **Check the local browser path**
   ```powershell
   Invoke-WebRequest -Uri "https://$([System.Net.Dns]::GetHostEntry('').HostName)" -UseBasicParsing -TimeoutSec 10 | Select-Object StatusCode
   ```
   `200` (or a redirect to the login form) = the gateway works locally, so the fault is network, proxy or client. A TLS error = certificate/binding. A timeout = service/port.

5. **Check the gateway-to-target path** (the same identity WAC will use)
   ```powershell
   Enter-PSSession -ComputerName <target-fqdn>
   ```
   Connects = WinRM, Kerberos and permissions are fine. The fault is inside WAC (RBAC, stale connection, extension). Fails = go to Fix 4 with the exact error code.

6. **Check for Kerberos SPN hijack** (error `0x80090322`)
   ```powershell
   setspn -Q HTTP/<target-fqdn>
   ```
   If the SPN is registered to a **service account** (SSRS, SharePoint, Dynamics), WinRM Kerberos fails for the FQDN. Fix 4c.

---
## Common Fix Paths

<details><summary>Fix 1 — Service won't start / config module won't load</summary>

```powershell
# Read the last configuration steps and any errors
Get-Content 'C:\ProgramData\WindowsAdminCenter\Logs\Configuration.log' -Tail 60

# Module load failure "Microsoft.PowerShell.LocalAccounts could not be loaded" → PSModulePath order
[Environment]::SetEnvironmentVariable('PSModulePath',
    "$env:SystemRoot\system32\WindowsPowerShell\v1.0\Modules;" + [Environment]::GetEnvironmentVariable('PSModulePath','User'), 'User')

# Make the service automatic and start it
Set-Service WindowsAdminCenter -StartupType Automatic
Start-Service WindowsAdminCenter
Get-Service WindowsAdminCenter
```
- If it starts then stops, the most common cause is the certificate: the binding points at a missing thumbprint, or NETWORK SERVICE can't read the key. Go to Fix 2.
- **On a domain controller:** unsupported. The installer stalls on `Set-WACWinRmOverHttps`/`Set-WACLoginMode` and fails `Register-WACLocalCredSSP`. Move the gateway to a member server.
</details>

<details><summary>Fix 2 — Replace / rebind the TLS certificate</summary>

```powershell
Import-Module "$env:ProgramFiles\WindowsAdminCenter\PowerShellModules\Microsoft.WindowsAdminCenter.Configuration"

# Pick the cert (Server Auth EKU, private key, FQDN in SAN)
Get-ChildItem Cert:\LocalMachine\My | Where-Object HasPrivateKey | Select-Object Thumbprint, Subject, NotAfter

# Apply by thumbprint (safer than subject when several certs share a CN)
Set-WACCertificateSubjectName -Thumbprint '<thumbprint>'
# Give NETWORK SERVICE access to the private key
Set-WACCertificateAcl -SubjectName '<CN=gateway.contoso.com>'
Restart-Service WindowsAdminCenter

# Verify the binding actually changed
netsh http show sslcert | Select-String 'Certificate Hash'
```
- Copying the thumbprint from the MMC can paste an **invisible leading character**. Type the first character by hand, or copy it from PowerShell instead.
- If the binding still shows the old self-signed cert (reported on 2410 with SAN certs), check `Set-WACCertificateSubjectName -Thumbprint <tp> -Target All` and confirm the certificate has a **unique** subject name.
- **Rollback:** re-run `Set-WACCertificateSubjectName -Thumbprint <old thumbprint>` and restart the service. Don't delete the old cert until the new one is confirmed.
</details>

<details><summary>Fix 3 — Port / firewall / NSG / "site can't be reached"</summary>

```powershell
Import-Module "$env:ProgramFiles\WindowsAdminCenter\PowerShellModules\Microsoft.WindowsAdminCenter.Configuration"
# Re-assert ports (Server defaults shown; WAC does not support ports below 1024 except 443)
Set-WACHttpsPorts -WacPort 443 -ServicePortRangeStart 6601 -ServicePortRangeEnd 6610
Register-WACFirewallRule -Port 443
Restart-Service WindowsAdminCenter

# From the admin workstation
Test-NetConnection -ComputerName <gateway-fqdn> -Port 443 -InformationLevel Detailed
```
- For an Azure VM gateway, add an inbound 443 rule on the **NSG** as well.
- After uninstalling an old WAC, if nothing else can bind 443, clear the leftovers: `netsh http delete sslcert ipport=0.0.0.0:443` then `netsh http delete urlacl url=https://+:443/`. **Destructive:** only do this if no other site (IIS/ADFS) uses 443 on this host.
</details>

<details><summary>Fix 4 — Can't connect to some or all managed servers</summary>

**4a. WinRM off or blocked on the target** (run on the target)
```powershell
Enable-PSRemoting -Force
# Server:
Set-NetFirewallRule -Name WINRM-HTTP-In-TCP-PUBLIC -RemoteAddress Any
# Client OS:
Set-NetFirewallRule -Name WINRM-HTTP-In-TCP -RemoteAddress Any
```

**4b. Workgroup target or local-account credentials (`0x8009030e`)** (on the gateway)
```powershell
(Get-Item WSMan:\localhost\Client\TrustedHosts).Value | Out-File "$env:TEMP\TrustedHosts.bak"   # backup
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '<target1-fqdn>,<target2-fqdn>' -Force
```
On the target, if you're using a local admin that isn't the built-in Administrator:
```powershell
New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 1 -Force
```
Rollback TrustedHosts: `Set-Item WSMan:\localhost\Client\TrustedHosts -Value (Get-Content "$env:TEMP\TrustedHosts.bak") -Force`.

**4c. Kerberos SPN hijacked (`0x80090322`)**
```powershell
setspn -Q HTTP/<target-fqdn>
setspn -S HTTP/<target-fqdn>:5985 <target-netbios-name>
```
Then have WAC/PowerShell include the port in the SPN. Test with `Enter-PSSession <target-fqdn> -SessionOption (New-PSSessionOption -IncludePortInSPN)`.

**4d. Cluster tools / CAU "CredSSP" errors**: add the user to the local **Windows Admin Center CredSSP Administrators** group on the gateway, then have them sign out and back in. If validation still fails, reset CredSSP: `Disable-WSManCredSSP -Role Client` (gateway), `Disable-WSManCredSSP -Role Server` (nodes), then retry from WAC.

**4e. Large event-log export fails with packet size error**: `winrm set winrm/config @{MaxEnvelopeSizekb="8192"}` on the gateway.
</details>

<details><summary>Fix 5 — Browser-side: TLS error, not authorized, RDP/PowerShell/Events tool blank</summary>

**"Can't connect securely… outdated or unsafe TLS"** on the **browser machine** (HTTP/2-only with integrated auth):
```powershell
$p = 'HKLM:\SYSTEM\CurrentControlSet\Services\Http\Parameters'
New-ItemProperty -Path $p -Name EnableHttp2Tls -PropertyType DWord -Value 0 -Force
New-ItemProperty -Path $p -Name EnableHttp2Cleartext -PropertyType DWord -Value 0 -Force
# Reboot the browser machine. Rollback: remove both values.
```
**"You are not authorized to view this page"**: restart the browser. When prompted, pick the **Windows Admin Center Client** certificate (desktop-mode installs), or try an InPrivate window and then clear the cache.
**RDP / PowerShell / Events / Packet Monitoring blank**: WebSockets are being stripped. Bypass the proxy for the gateway FQDN, or allow `Upgrade: websocket` on the reverse proxy/WAF.
**Azure features fail in Edge**: add the gateway URL, `https://login.microsoftonline.com` and `https://login.live.com` to Trusted sites and to the pop-up allow list.
</details>

<details><summary>Fix 6 — Broken upgrade (v1 → v2, or v2 build → newer v2 build)</summary>

```powershell
# Record current settings first
Import-Module "$env:ProgramFiles\WindowsAdminCenter\PowerShellModules\Microsoft.WindowsAdminCenter.Configuration" -ErrorAction SilentlyContinue
Export-WACInstallerSettings -ErrorAction SilentlyContinue
Get-ChildItem Cert:\LocalMachine\My | Where-Object HasPrivateKey | Select-Object Thumbprint, Subject, NotAfter |
    Export-Csv "$env:TEMP\WAC-certs.csv" -NoTypeInformation
# Export the shared connection list (v2 ConnectionTools module; parameter names carried over from v1 Export-Connection, confirm with Get-Help Export-WACConnection)
Import-Module "$env:ProgramFiles\WindowsAdminCenter\PowerShellModules\Microsoft.WindowsAdminCenter.ConnectionTools" -ErrorAction SilentlyContinue
Export-WACConnection -GatewayEndpoint "https://<gateway-fqdn>" -FileName "$env:TEMP\WAC-connections.csv"
```
Then uninstall WAC (Apps & features), reboot, and install the current build **with a log**:
```powershell
Start-Process '<path>\WindowsAdminCenter.exe' -Wait -ArgumentList '/log=C:\Temp\WAC-install.log'
```
Reapply the certificate (Fix 2) and re-import connections with `Import-WACConnection`.
- Microsoft's documented fix for "installation failed / won't open after install" when an older modernized build is present is **uninstall and then reinstall**.
- The 2311 → 2410 upgrade can drop the certificate (seen with international-language installs or special characters). Fix 2 afterwards.
- **Destructive, last resort:** a corrupted connection list is fixed by uninstalling and deleting `C:\Windows\ServiceProfiles\NetworkService\AppData\Roaming\Microsoft\Server Management Experience`. This wipes connections and settings for **all** users. Export first.
</details>

<details><summary>Fix 7 — Extensions missing or broken after update</summary>

Extensions must be **reinstalled after every WAC update**. Settings → Extensions → Installed/Available → reinstall. If a feed is unreachable, WAC shows **no error**. Check proxy settings (`Get-WACProxy`) and the feed URL. Some partner extensions (for example, older Fujitsu ServerView ones) don't support the modernized gateway at all.
</details>

---
## Escalation Evidence

```
WAC ESCALATION — <ticket #>
Gateway host / OS build        : <name> / <winver>
WAC version (file version)     : <2.x.x.x>   Generation: v2 modernized / v1 legacy
Deployment                     : Server service / Win10-11 desktop / HA cluster / Azure VM
Service status                 : <Running/Stopped>  StartType: <>
Listening port(s)              : <443/6600/other>
Bound cert thumbprint / subject: <>  Expires: <>  Private key ACL for NETWORK SERVICE: <Y/N>
Login mode                     : <FormLogin / WindowsAuthentication / AadSso>
Browser + version (client)     : <>   Proxy between client and gateway: <Y/N>
Symptom                        : <can't load / cert error / some targets fail / all targets fail / tool X blank>
Failing target(s) + OS         : <>
Enter-PSSession from gateway   : <success / exact error + code>
Error codes seen               : <0x8009030e / 0x80090322 / HTTP 500 / other>
Configuration.log tail attached: <Y/N>   WindowsAdminCenter event log export: <Y/N>   HAR file: <Y/N, redacted>
Changes in last 7 days         : <upgrade / cert renewal / GPO / firewall>
Evidence script output         : Get-WindowsAdminCenterHealth.ps1 CSV attached <Y/N>
```

---
## 🎓 Learning Pointers
- If WAC "worked yesterday, broken today" after an upgrade, that almost always traces to the **v1 → v2 architecture swap**: a new service name, a new port model (front end plus 6601–6610 sub-process ports), and a new certificate path. Read the [modernized gateway overview](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/understand/what-is) once so you can tell the two generations apart.
- The gateway only works if **plain PowerShell remoting works**. `Enter-PSSession` from the gateway is the single most useful test. If it fails, WAC will fail the same way. See [about_Remote_Troubleshooting](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_remote_troubleshooting).
- `0x80090322` points to an HTTP SPN registered to a service account. That's a Kerberos problem, not a WAC one. The same fix applies to any WinRM tool. See the [WAC known issues: WinRM security error](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/support/known-issues#security-error).
- The v2 configuration module (`Microsoft.WindowsAdminCenter.Configuration`, 100+ cmdlets) is the installer's own toolkit. The installer's step order is visible in `Configuration.log`, and Joze Markic's [WACv2 installation deep dive](https://blog.markic.org/2025/03/03/deep-dive-into-windows-admin-center-v2-wacv2-installation/) maps every step to its cmdlet.
- For internet-facing or MSP-multi-tenant access, consider [Windows Admin Center in the Azure portal](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/azure/manage-vm) for Arc-enabled servers and Azure VMs. You don't need a public gateway, VPN, or inbound ports.
- Related in this repo: `Windows/Troubleshooting/WinRM-A.md`/`-B.md` (transport layer WAC depends on), `Windows/Troubleshooting/Kerberos-A.md` and `ActiveDirectory/Troubleshooting/KerberosDelegation/` (SPN and RBCD), `Windows/Troubleshooting/CertificateServices-A.md` (issuing the gateway cert), `Azure/Arc/AzureArc-A.md` (prerequisite for WAC in the Azure portal).
- Companion files: `WindowsAdminCenter-A.md` (deep dive) and `Scripts/Get-WindowsAdminCenterHealth.ps1` (evidence).
