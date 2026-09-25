# Microsoft Connected Cache for Enterprise & Education — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Use when:** a Connected Cache (MCC) node won't install, shows **Unhealthy** in the Azure portal, is "Healthy" but clients still pull from the internet, or goes offline by itself. Covers Windows-hosted (WSL2) and Linux-hosted nodes. Client-side Delivery Optimization (peering, download modes): `DeliveryOptimization-B.md`. Deep dive: `ConnectedCache-A.md`.

**The three things that cause most tickets:**
1. **"Healthy" ≠ reachable.** Portal health only means the container can talk to the Delivery Optimization service. Clients can still be blocked by firewall, WSL port-forwarding gaps, or a disabled **IP Helper** service.
2. **Windows nodes live inside WSL2 under a runtime account** (gMSA / local / domain user). Scheduled tasks (`MCC_Install_Task`, `MCC_Monitor_Task`) run as that account — expired passwords, missing *Log on as a batch job*, or a credential-storage GPO kill the node.
3. **TLS-inspecting proxies break registration.** `*.do.dsp.mp.microsoft.com` must bypass inspection.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
**On the Windows cache host (elevated):**
```powershell
# 1. IP Helper — required for netsh portproxy to forward LAN traffic into WSL
Get-Service iphlpsvc | Select-Object Status, StartType

# 2. Port-forwarding rules into the WSL distro (expect 80, plus 443/5000 if HTTPS/summary page used)
netsh interface portproxy show v4tov4

# 3. Keep-alive + install tasks and their last result (0 = success)
Get-ScheduledTask -TaskName 'MCC_*' | ForEach-Object { $i = $_ | Get-ScheduledTaskInfo; [pscustomobject]@{Task=$_.TaskName; State=$_.State; LastRun=$i.LastRunTime; LastResult=$i.LastTaskResult} }

# 4. Something else squatting on port 80? (ConfigMgr DP / IIS)
Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue | Select-Object LocalAddress, OwningProcess, @{n='Proc';e={(Get-Process -Id $_.OwningProcess).ProcessName}}
```
**From a client on the same network:**
```powershell
# 5. Can a client actually fetch through the node? (expect HTTP 200)
Invoke-WebRequest "http://<CacheNodeIP>/filestreamingservice/files/7bc846e0-af9c-49be-a03d-bb04428c9bb5/Microsoft.png?cacheHostOrigin=dl.delivery.mp.microsoft.com" -UseBasicParsing | Select-Object StatusCode
```

| Result | Meaning | Do |
|---|---|---|
| #1 Stopped/Disabled | portproxy rules do nothing — node only serves localhost | Fix 1 |
| #2 no rule for port 80 → WSL IP | Forwarding lost (often after reboot/WSL IP change) | Fix 2 |
| #3 `MCC_Monitor_Task` LastResult ≠ 0 or not recently run | WSL distro stopped; runtime-account creds expired | Fix 3 |
| #3 `MCC_Install_Task` never ran | GPO/batch-logon/execution-policy block | Fix 4 |
| #4 listener is not `wslrelay`/`svchost` portproxy | Port 80 conflict (DP/IIS) — unsupported | Move MCC to another host |
| #5 fails but #1–#4 fine | Host firewall / network segmentation | Fix 5 |
| #5 = 200 but clients' `BytesFromCacheServer` = 0 | Clients not pointed at the node | Fix 6 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Client download served from cache
├── Client licensed (Windows Ent E3/E5, Edu A3/A5, Ent per device, or Windows Server Std/DC)
├── Client knows the node: DOCacheHost policy (Intune/GPO/registry) OR DHCP Option 235 (DOCacheHostSource)
│   └── DHCP 235 not suppressed (LocalPolicyMerge / security baseline issue on Autopilot devices)
├── Client → node TCP 80 (443 if HTTPS configured) reachable
│   └── Windows host: firewall inbound 80/443 + netsh portproxy → WSL IP + IP Helper (iphlpsvc) Running
├── Node running
│   ├── Windows: WSL2 distro Ubuntu-24.04-Mcc up (kept alive by MCC_Monitor_Task as runtime account)
│   │   ├── Runtime account (gMSA/local/domain) valid, "Log on as a batch job", password current
│   │   └── GPO "Do not allow storage of passwords and credentials..." NOT enabled
│   ├── Linux: Ubuntu 24.04 / RHEL 8-9 (Moby, not Podman)
│   └── IoT Edge runtime: edgeAgent + edgeHub + MCC containers listed (`sudo iotedge list`)
├── Node → internet (ports 80/443) to DO + CDN endpoints; *.do.dsp.mp.microsoft.com NOT TLS-inspected
│   └── Forward proxy (if any) handles origin-form URLs, no caching (most Squid defaults fail)
└── Azure resource "Microsoft Connected Cache for Enterprise and Education" + cache node configured & Saved
    └── Azure subscription (no Azure charge for the MCC resource)
```
</details>

---
## Diagnosis & Validation Flow
1. **Portal status** — Azure portal → Connected Cache resource → Cache nodes.
   - *Unhealthy* → node can't reach the DO service: go to step 4.
   - *Healthy* → service side fine; problem is between clients and the node: step 5.
2. **Container state** (Windows: run as runtime account)
   ```powershell
   wsl -d Ubuntu-24.04-Mcc     # then:  sudo iotedge list
   ```
   Expect `edgeAgent`, `edgeHub`, **`MCC`** all `running`. Missing MCC → `sudo iotedge system logs -- -f`; restart with `sudo iotedge system restart` (Linux host: `sudo systemctl restart iotedge`).
3. **Keep-alive task** — Triage #3. Also read `C:\mccwsl01\WSL_Mcc_Monitor_FromRegisteredTask_Transcript.txt` (install dir may differ: `deliveryoptimization-cli mcc-get-scripts-path`).
4. **Upstream connectivity from inside the node** (Windows: inside `wsl -d Ubuntu-24.04-Mcc`):
   ```bash
   nslookup geomcc.prod.do.dsp.mp.microsoft.com && nc -vz geomcc.prod.do.dsp.mp.microsoft.com 443
   curl -v http://b1.download.windowsupdate.com
   ```
   DNS fail → DNS config (Linux Docker: set `"dns"` in `/etc/docker/daemon.json`). "cannot verify certificate" → TLS inspection (Fix 7).
5. **Client reachability** — Triage #5 from a client. Fails → Triage #1/#2 and host firewall (Fix 1/2/5).
6. **Client targeting** — on a client:
   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -ErrorAction SilentlyContinue | Select-Object DOCacheHost, DOCacheHostSource
   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeliveryOptimization' -ErrorAction SilentlyContinue | Select-Object DOCacheHost*
   Get-DeliveryOptimizationStatus | Select-Object FileId, BytesFromCacheServer, BytesFromHttp, Status
   ```
   No `DOCacheHost` and no DHCP source → Fix 6. `BytesFromCacheServer` > 0 = working.

---
## Common Fix Paths

<details><summary>Fix 1 — IP Helper service disabled (node only answers localhost)</summary>

```powershell
Set-Service -Name iphlpsvc -StartupType Automatic
Start-Service -Name iphlpsvc
netsh interface portproxy show v4tov4   # rules now take effect
```
Check hardening baselines/GPOs — CIS-style baselines sometimes disable IP Helper; exclude the MCC host.
</details>

<details><summary>Fix 2 — Recreate WSL port-forwarding rules (80 / 443 / 5000)</summary>

```powershell
$ipFile = Join-Path ([Environment]::GetEnvironmentVariable('MCC_INSTALLATION_FOLDER','Machine')) 'wslIp.txt'
$wslIp  = (Get-Content $ipFile | Select-Object -First 1).Trim()
netsh interface portproxy add v4tov4 listenport=80  listenaddress=0.0.0.0 connectport=80  connectaddress=$wslIp
# Only if HTTPS / remote summary page are used:
netsh interface portproxy add v4tov4 listenport=443  listenaddress=0.0.0.0 connectport=443  connectaddress=$wslIp
netsh interface portproxy add v4tov4 listenport=5000 listenaddress=0.0.0.0 connectport=5000 connectaddress=$wslIp
```
If `wslIp.txt` doesn't match the distro's current IP (`wsl -d Ubuntu-24.04-Mcc hostname -I` as runtime account), use the live IP and delete stale rules: `netsh interface portproxy delete v4tov4 listenport=80 listenaddress=0.0.0.0`.
**Rollback:** `netsh interface portproxy delete v4tov4 listenport=<port> listenaddress=0.0.0.0`.
</details>

<details><summary>Fix 3 — MCC_Monitor_Task failing (node goes offline on its own)</summary>

Usually the runtime account's password changed/expired (local or domain user).
```powershell
cd (deliveryoptimization-cli mcc-get-scripts-path)     # preview installs: C:\mccwsl01\MccScripts
$myLocalAccountCredential = Get-Credential '<Domain or Host>\<RuntimeAccount>'
.\updatetaskpasswords.ps1 -Credential $myLocalAccountCredential
Start-ScheduledTask -TaskName 'MCC_Monitor_Task'
```
Prevent recurrence: use a **gMSA** runtime account (no password rotation to manage), or exempt the local account from expiry.
</details>

<details><summary>Fix 4 — Install fails: MCC_Install_Task won't run / gMSA "wrong password"</summary>

- GPO **Network access: Do not allow storage of passwords and credentials for network authentication** = Enabled → blocks task registration. Exclude the host (or set Disabled) and reinstall.
- Grant the runtime account **Log on as a batch job** (`secpol.msc` → User Rights Assignment, or GPO).
- `Get-ExecutionPolicy` must allow scripts. Deployment scripts need **Windows PowerShell 5.1**, not PowerShell 7.
- gMSA "username or password incorrect" → Kerberos encryption type mismatch: align the gMSA's `msDS-SupportedEncryptionTypes` with the DC policy:
  ```powershell
  Get-ADServiceAccount <gmsaName> -Properties msDS-SupportedEncryptionTypes | Select-Object Name, msDS-SupportedEncryptionTypes
  ```
- `wsl --install --no-distribution` fails with "A specified logon session doesn't exist" → sign in interactively as a **local administrator** and run elevated.
- WSL errors → `wsl.exe --update`.
- Host prerequisites: Win11 ≥ 22631.3296 or Server 2022 ≥ 20348.2227 (or Server 2025), nested virtualization allowed (Azure **Trusted launch** VMs block it), Hyper-V PowerShell management tools present during install, ≥ 4 GB free RAM, ≥ 100 GB free disk, **single NIC**, no Server Core (MSIX installer unsupported there).
- Previous MCC install must be uninstalled first.
</details>

<details><summary>Fix 5 — Clients can't reach a Healthy node (firewall)</summary>

```powershell
New-NetFirewallRule -DisplayName 'MCC HTTP 80 inbound' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80
# HTTPS / summary page if used:
New-NetFirewallRule -DisplayName 'WSL2 Port Bridge (HTTPS)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 443
New-NetFirewallRule -DisplayName 'WSL2 Port Bridge (MCC SUMMARY)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5000
```
(Install normally auto-creates the port-80 rule; if a GPO disables local firewall rule merge, recreate it in the GPO.) Also check network ACLs/VLAN segmentation between client subnets and the host.
**Rollback:** `Remove-NetFirewallRule -DisplayName '<name>'`.
</details>

<details><summary>Fix 6 — Node works but clients don't use it</summary>

Intune: *Devices → Configuration → Settings catalog → Delivery Optimization* → **DO Cache Host** = node FQDN/IP (comma-separate multiple). Optional: **DO Delay Cache Server Fallback Foreground/Background** (seconds) so clients don't instantly bypass a busy node.
DHCP Option 235 route: clients need **DO Cache Host Source** = 1 (or 2 to prefer DHCP). If Option 235 isn't being picked up (common on Autopilot devices with security baselines — Microsoft flags the `LocalPolicyMerge` setting), switch to explicit `DOCacheHost`.
Verify on a client after a new download: `Get-DeliveryOptimizationStatus` → `BytesFromCacheServer` > 0.
**Rollback:** unassign the policy — clients go back to CDN/peers.
</details>

<details><summary>Fix 7 — "ERROR: cannot verify certificate" / Unhealthy behind Zscaler-type proxy</summary>

1. Bypass TLS inspection for `*.do.dsp.mp.microsoft.com` (to and from).
2. Set the proxy in the Azure portal cache-node configuration → **Save** → **redeploy** the node (proxy changes need redeploy).
3. Pass the proxy's PEM: Windows `-proxyTlsCertificatePemFileName "mycert.pem"` (file in installationFolder); Linux `proxytlscertificatepath="/path/to/pem"`.
4. Forward proxies must accept **origin-form** URLs and not cache; default Squid configs don't work — let the node go direct.
</details>

<details><summary>Fix 8 — Linux node redeployed to GA container, running but content requests fail</summary>

```bash
sudo chmod 777 -R /<cachedrivepath>
sudo iotedge restart MCC
```
RHEL hosts must use **Moby** instead of the default Podman.
</details>

---
## Escalation Evidence
```
CONNECTED CACHE ESCALATION
Ticket: ________  Tenant/Client: ________  Azure subscription: ________  MCC resource: ________
Cache node name: ________  Host OS/build: ________  Host type: [ ] Windows (WSL2) [ ] Ubuntu 24.04 [ ] RHEL __
Runtime account type: [ ] gMSA [ ] local [ ] domain       Install method: [ ] Windows app (MSIX) [ ] preview package
Portal status: [ ] Healthy [ ] Unhealthy [ ] Not reporting    Last healthy: ________
iotedge list: edgeAgent __ edgeHub __ MCC __
iphlpsvc: ________   portproxy rules (80/443/5000): ________   WSL IP: ________
MCC_Monitor_Task last result: ________   MCC_Install_Task last result: ________
Port 80 listener owner: ________
geomcc.prod.do.dsp.mp.microsoft.com 443 from inside node: [ ] OK [ ] Fail   TLS inspection bypassed: [ ] Yes [ ] No
Client test URL (Microsoft.png) HTTP code: ________   Client DOCacheHost: ________   BytesFromCacheServer: ________
Support bundle (collectmccdiagnostics.sh) attached: [ ] Yes   Get-ConnectedCacheNodeHealth.ps1 CSV attached: [ ] Yes
Notes: ________________________________________________
```
Support bundle (Windows, as runtime account): `cd C:\mccwsl01\MccScripts; wsl bash collectmccdiagnostics.sh`, then `wsl cp /etc/mccdiagnostics/<bundle>.tar.gz /mnt/c/mccwsl01/SupportBundles/`. Portal: **Diagnose and solve problems** blade.

---
## 🎓 Learning Pointers
- The portal's "Healthy" is a *service-side* heartbeat, not a client-side probe — always test with the `Microsoft.png` URL from a real client subnet. [Troubleshoot Connected Cache](https://learn.microsoft.com/windows/deployment/do/mcc-ent-troubleshooting).
- On Windows the cache is a Linux container in WSL2, reached through `netsh portproxy` — which silently depends on the IP Helper service. That one service explains a large share of "installed fine, serves nothing" tickets.
- gMSA runtime accounts remove the password-expiry failure mode that kills `MCC_Monitor_Task` on local-account installs. See `ActiveDirectory` gMSA material and [Connected Cache prerequisites](https://learn.microsoft.com/windows/deployment/do/mcc-ent-prerequisites).
- Connected Cache is a *source* for Delivery Optimization, not a replacement — client policy (`DOCacheHost`, fallback delays) still lives in the DO stack. Read `DeliveryOptimization-A.md` alongside this.
- The MCC resource costs nothing in Azure, but every client pulling from it needs Windows Enterprise/Education (or Windows Server) licensing — check before recommending it to a Business Premium-only client. [MCC overview](https://learn.microsoft.com/windows/deployment/do/mcc-ent-edu-overview).
