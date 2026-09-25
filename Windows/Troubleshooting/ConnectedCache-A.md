# Microsoft Connected Cache for Enterprise & Education — Reference Runbook (Mode A: Deep Dive)
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
**In scope:** Microsoft Connected Cache for Enterprise and Education (GA 23 July 2025) — the Azure-managed, software-only cache node deployed on Windows 11 / Windows Server 2022+ (inside WSL2) or Ubuntu 24.04 / RHEL 8–9, serving Delivery Optimization (DO) content: Windows feature/quality updates, Microsoft 365 Apps (Click-to-Run), Intune Win32/Store apps, Defender definition updates, Autopilot provisioning downloads.

**Out of scope:** Connected Cache on a ConfigMgr distribution point (separate product path, managed from ConfigMgr — see Learn "Microsoft Connected Cache in Configuration Manager"), Connected Cache for ISPs, client peering behaviour and download modes (`DeliveryOptimization-A.md`), BranchCache (`BranchCache-A.md`).

**Note on older repo text:** `DeliveryOptimization-A.md` describes MCC generically (including the earlier IoT Edge/preview model). This file is the authoritative GA-era reference.

**Sources (read 2026-09-25):** Learn *MCC for Enterprise and Education overview* (ms.date 2025-07-23), *prerequisites* (updated 2026-04-09), *troubleshooting* (updated 2026-05-20).

---
## How It Works
<details><summary>Full architecture</summary>

### Control plane vs data plane
```
            ┌──────────────── Azure (control plane) ────────────────┐
            │ Resource: "Microsoft Connected Cache for Enterprise   │
            │ and Education"  → Cache node objects (config: OS,     │
            │ cache drive path/size, proxy, runtime account type)   │
            │ Portal / Azure CLI · Metrics · Diagnose & solve       │
            └───────────────┬───────────────────────────────────────┘
                            │ provisioning package + registration
                            ▼
  ┌──────────── Host machine (data plane) ─────────────┐        Internet
  │ Windows: MCC Windows app (MSIX) → PowerShell 5.1    │   ┌──────────────────────┐
  │   scripts → WSL2 distro "Ubuntu-24.04-Mcc"          │   │ DO service           │
  │   → Azure IoT Edge runtime → MCC container          │──►│ *.do.dsp.mp.microsoft│
  │   netsh portproxy 80/443/5000 → WSL IP (IP Helper)  │   │ geomcc.prod.do...    │
  │   Scheduled tasks as runtime account:               │   │ CDN: dl.delivery.mp..│
  │     MCC_Install_Task · MCC_Monitor_Task             │   │ b1.download.windows..│
  │ Linux: bash scripts → IoT Edge (Moby) → MCC         │   └──────────────────────┘
  └───────────────▲─────────────────────────────────────┘
                  │ HTTP 80 (HTTPS 443 optional)
     ┌────────────┴────────────┐
     │ DO clients               │  DOCacheHost (Intune/GPO/reg) or DHCP Option 235
     │ fallback → CDN if node   │  DelayCacheServerFallbackForeground/Background
     │ unavailable              │
     └──────────────────────────┘
```

1. Create the Azure resource and a cache node (portal or Azure CLI). The Azure resource itself **incurs no Azure cost**, but you need a subscription (pay-as-you-go is fine).
2. Deploy to the host with the OS-specific package — Windows: the Connected Cache **Windows application** (MSIX) running PowerShell 5.1 scripts; Linux: a bundle of bash scripts.
3. The MCC container is deployed via **Azure IoT Edge** container management; once running it reports status/metrics to the DO service.
4. Clients are pointed at the node via **`DOCacheHost`** (Intune/GPO/registry) or **DHCP Option 235** (with `DOCacheHostSource`).
5. Client requests → node; cache miss → node fetches from CDN and fills; subsequent requests served locally.
6. Node unavailable → clients fall back to CDN (delay with `DelayCacheServerFallbackForeground/Background`).

### Why Windows hosting is fragile in specific ways
The cache is a Linux container. On Windows it runs in **WSL2**, which:
- runs **in a user context** — hence the mandatory *runtime account* (gMSA, local user, or domain user) and the scheduled tasks that start and keep the distro alive as that account. WSL would otherwise stop an idle distro; `MCC_Monitor_Task` prevents that.
- uses a **NAT'd virtual adapter** — LAN clients reach the container only through `netsh interface portproxy` rules, which in turn **require the IP Helper service**. The WSL IP is recorded in `wslIp.txt` under the install folder (`C:\mccwsl01` default, env var `MCC_INSTALLATION_FOLDER`).
- needs **nested virtualization** — Azure VMs with *Trusted launch* and some hypervisor hardening block it.

Consequently most Windows-host failures are Windows plumbing (services, user rights, GPO, scheduled tasks, portproxy), not cache logic.

### Licensing (client side, per device)
| Client | Qualifying licence |
|---|---|
| Windows desktop | Windows Enterprise E3/E5 (incl. M365 F3/E3/E5), Windows Education A3/A5, Windows Enterprise per device |
| Windows Server | Windows Server Standard, Datacenter, Datacenter: Azure Edition |
No limit on concurrent clients. Business Premium-only fleets (Windows Business) don't qualify.

### Sizing
| Profile | CPU | RAM | Disk | NIC | Rough 8-hour delivery |
|---|---|---|---|---|---|
| Branch office (10–50 devices; can be a Windows 11 PC) | 4 | 8 GB (4 free) | 100 GB free | 1 Gbps | 100 Mbps ≈ 360 GB |
| Small/medium site / Autopilot centre (50–500) | 8 | 16 GB (4 free) | 500 GB free | 5 Gbps | 1 Gbps ≈ 3,600 GB |
| Large site (500–5,000) | 16 | 32 GB (4 free) | 2× 200–500 GB | 10 Gbps | 5 Gbps ≈ 18,000 GB |
Hard minimums: 4 GB free RAM, 100 GB free disk. **Multiple NICs aren't supported.** SR-IOV recommended.

### Host prerequisites that trip installs
- Windows 11 build ≥ 22631.3296, or Server 2022 ≥ 20348.2227 (Server 2025 supported), latest CU. **Server Core not supported** by the MSIX installer.
- WSL2 (`wsl.exe --install --no-distribution`, as local admin), Hyper-V PowerShell management tools during install (removable after).
- **Port 80 free** — no ConfigMgr DP/IIS on the same host. No pre-existing IoT Edge modules.
- Previous MCC installs uninstalled first.
- PowerShell **5.1** for deployment (7.x incompatible; fine for management afterwards).
- Proxy: reverse-proxy design; forward proxy must accept origin-form URLs and not cache (default Squid fails). `*.do.dsp.mp.microsoft.com` must bypass TLS inspection.
</details>

---
## Dependency Stack
```
Layer 7  Client savings visible: BytesFromCacheServer > 0, portal hit-rate metrics
Layer 6  Client targeting: DOCacheHost / DHCP 235 (+ DOCacheHostSource), fallback delays, licence
Layer 5  Client → node path: TCP 80(/443), host firewall, VLAN ACLs
Layer 4  Windows host bridge: netsh portproxy → WSL IP, IP Helper Running        (Linux: n/a)
Layer 3  Container runtime: IoT Edge edgeAgent/edgeHub/MCC running; cache drive writable
Layer 2  Host keep-alive: MCC_Monitor_Task as runtime account (rights, password, GPO)   (Windows)
Layer 1  Upstream: node → DO service (geomcc…) + CDN over 80/443, DNS, proxy, no TLS inspection
Layer 0  Azure resource + node config saved; host OS/build, WSL2, nested virt, single NIC, disk/RAM
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Install fails at registration | Node can't reach `geomcc.prod.do.dsp.mp.microsoft.com` | `nslookup`/`nc -vz`/`curl` inside the distro |
| "ERROR: cannot verify certificate" | TLS-inspecting proxy | Bypass `*.do.dsp.mp.microsoft.com`, supply PEM |
| `MCC_Install_Task` never runs | Credential-storage GPO, no batch-logon right, execution policy | `gpresult /h`, `secpol`, `Get-ExecutionPolicy` |
| gMSA "username or password incorrect" | Kerberos enctype mismatch gMSA vs DC | `msDS-SupportedEncryptionTypes` |
| WSL install "logon session doesn't exist" | Not interactive local admin | Log on as local admin, elevated |
| Portal Healthy, clients get nothing | IP Helper off / portproxy missing / firewall | Triage #1/#2, client test URL |
| Node drops offline days/weeks later | Runtime-account password expired → monitor task fails | Task last result, `updatetaskpasswords.ps1` |
| Portal Unhealthy | No outbound to DO service | DO endpoints, proxy config |
| Clients ignore node | No `DOCacheHost`; DHCP 235 suppressed on baseline-hardened/Autopilot devices | Client registry + DO status |
| Install fails on non-EN locale / cache overgrows drive | Pre-GA bugs | Upgrade to GA/latest app |
| `importCert.ps1` fails on Server 2022/2025 + gMSA | v1.0.24.0 limitation | Use app v1.0.26.0+ |
| Linux node after GA redeploy serves errors | Cache-drive permissions | `chmod 777 -R <cachedrive>`; `iotedge restart MCC` |
| Config change had no effect | Not **Saved** in portal, or proxy change without redeploy | Portal config page |
| Install fails in Azure VM | Trusted launch blocks nested virtualization | VM security type |

---
## Validation Steps
1. **Host prerequisites**
   ```powershell
   $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; "$($cv.CurrentBuild).$($cv.UBR)"
   (Get-Volume -DriveLetter C).SizeRemaining/1GB
   (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB
   @(Get-NetAdapter -Physical | Where-Object Status -eq 'Up').Count
   ```
   Good: build ≥ 22631.3296 (Win11) / 20348.2227 (WS2022); ≥ 100 GB; ≥ 4 GB; 1 NIC.
2. **WSL + distro**
   ```powershell
   wsl --status; wsl -l -v      # as runtime account for the distro list
   ```
   Good: WSL2 default; `Ubuntu-24.04-Mcc` Running.
3. **Containers** — inside distro: `sudo iotedge list` → `edgeAgent`, `edgeHub`, `MCC` running.
4. **Bridge** — `Get-Service iphlpsvc` Running/Automatic; `netsh interface portproxy show v4tov4` lists `0.0.0.0:80 → <WSL IP>:80`, WSL IP matches `wslIp.txt`.
5. **Tasks** — `Get-ScheduledTask MCC_Monitor_Task | Get-ScheduledTaskInfo` → `LastTaskResult 0`, recent `LastRunTime`.
6. **Client fetch** — `http://<node>/filestreamingservice/files/7bc846e0-af9c-49be-a03d-bb04428c9bb5/Microsoft.png?cacheHostOrigin=dl.delivery.mp.microsoft.com` → HTTP 200 and an image.
7. **Client use** — `Get-DeliveryOptimizationStatus` → `BytesFromCacheServer` > 0 on new downloads; portal metrics show hit volume. Bad: all bytes `BytesFromHttp`.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Azure.** Resource creation errors are almost always RBAC (need rights to create resources in the subscription) or unfilled required fields. Config not taking effect → **Save** wasn't clicked; proxy changes need **redeploy**.

**Phase 2 — Install (Windows).** Read logs in the scripts directory (`deliveryoptimization-cli mcc-get-scripts-path`): `WSL_Mcc_Install_Transcript`, `..._FromRegisteredTask_Status`, and — most useful — `WSL_Mcc_Install_FromRegisteredTask_Transcript`. Map failures to: WSL (update kernel, local-admin install), task registration (GPO/rights/execution policy), gMSA enctype, registration connectivity, TLS inspection.

**Phase 3 — Runtime.** Node went offline without changes → `MCC_Monitor_Task` + `WSL_Mcc_Monitor_FromRegisteredTask_Transcript.txt`. Almost always credentials or a host reboot with portproxy/IP Helper drift.

**Phase 4 — Reachability.** Healthy portal but no client traffic → test URL from a client subnet; work down layers 5→4 (firewall, portproxy, IP Helper).

**Phase 5 — Adoption.** Node reachable but unused → client policy. Prefer explicit `DOCacheHost` over DHCP 235 on Autopilot/baseline-hardened fleets. Confirm licensing.

**Phase 6 — Escalate.** Generate `collectmccdiagnostics.sh` bundle + portal **Diagnose and solve problems** output; open a Microsoft support case against the MCC Azure resource.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Clean reinstall on a Windows host</summary>

1. Uninstall per Learn (*Uninstall cache node*) — scripts dir contains `uninstallmcconwsl.ps1`; this also removes the auto-created port-80 firewall rule.
2. Fix root cause (GPO, rights, prerequisites).
3. Confirm: `wsl --update`; Hyper-V PS tools present; `iphlpsvc` Automatic; port 80 free.
4. Reinstall from the Windows app using the provisioning command copied from the portal (Windows PowerShell 5.1, elevated, as local admin).
5. Validate steps 2–6 above.
**Rollback:** n/a (node was already broken); clients fall back to CDN during the work — optionally raise `DelayCacheServerFallback*` to 0 temporarily so they don't wait.
</details>

<details><summary>Playbook 2 — Migrate runtime account to gMSA (end password-expiry outages)</summary>

1. Create gMSA: `New-ADServiceAccount -Name <gmsa> -DNSHostName <gmsa>.<domain> -PrincipalsAllowedToRetrieveManagedPassword <HostComputer>$`; on the host `Install-ADServiceAccount <gmsa>`; `Test-ADServiceAccount <gmsa>` → True.
2. Align `msDS-SupportedEncryptionTypes` with the DC's Kerberos policy (AES).
3. Grant *Log on as a batch job*.
4. Change the runtime account in the node configuration → Save → redeploy (uninstall/reinstall on host).
5. To interact as the gMSA later: `psexec.exe -i -u <DOMAIN\gmsa$> -p ~ powershell.exe`.
**Rollback:** redeploy with the previous local/domain account.
</details>

<details><summary>Playbook 3 — Point a site's clients at the node (Intune)</summary>

1. Settings catalog → Delivery Optimization: **DO Cache Host** = `<node FQDN or IP>` (multiple comma-separated).
2. Optional: **DO Delay Cache Server Fallback Foreground** / **Background** (seconds).
3. Scope to the site via a dynamic device group or filter (e.g., by naming/OU/Group Tag for Autopilot centres).
4. Alternatively DHCP Option 235 (string, node FQDN) + **DO Cache Host Source** = 1; don't rely on DHCP where security baselines/`LocalPolicyMerge` interfere.
5. Validate with `Get-DeliveryOptimizationStatus` and portal metrics.
**Rollback:** unassign the profile.
</details>

<details><summary>Playbook 4 — Enable HTTPS on a Windows node</summary>

1. Obtain a cert for the node FQDN (Base64 `.pem`/`.cer` can be renamed `.crt`).
2. Run `importCert.ps1` (app ≥ 1.0.26.0 if Server 2022/2025 + gMSA).
3. Add portproxy 443 + firewall 443 (see `ConnectedCache-B.md` Fix 2/5).
4. Update client `DOCacheHost` if the name changes.
**Rollback:** remove 443 rules; clients keep using HTTP 80.
</details>

---
## Evidence Pack
```powershell
# Run elevated on the Windows cache host. Output: C:\Temp\MCCEvidence_<host>_<ts>.zip
$out = "C:\Temp\MCCEvidence_$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd_HHmmss)"
New-Item -ItemType Directory -Path $out -Force | Out-Null
$inst = [Environment]::GetEnvironmentVariable('MCC_INSTALLATION_FOLDER','Machine'); if (-not $inst) { $inst = 'C:\mccwsl01' }
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
"$($cv.ProductName) $($cv.CurrentBuild).$($cv.UBR)" | Out-File "$out\os.txt"
Get-Service iphlpsvc | Format-List * | Out-File "$out\iphlpsvc.txt"
netsh interface portproxy show v4tov4 | Out-File "$out\portproxy.txt"
Get-ScheduledTask -TaskName 'MCC_*' -ErrorAction SilentlyContinue | ForEach-Object { $_ | Get-ScheduledTaskInfo } | Format-List * | Out-File "$out\tasks.txt"
Get-NetTCPConnection -LocalPort 80,443,5000 -State Listen -ErrorAction SilentlyContinue | Out-File "$out\listeners.txt"
Get-NetFirewallRule -Enabled True -Direction Inbound | Where-Object DisplayName -match 'WSL|MCC|Connected Cache' | Out-File "$out\firewall.txt"
Get-NetAdapter | Out-File "$out\nics.txt"
Get-Volume | Out-File "$out\volumes.txt"
wsl --status 2>&1 | Out-File "$out\wsl-status.txt"
if (Test-Path $inst) { Get-ChildItem $inst -Filter '*.txt' | Copy-Item -Destination $out -ErrorAction SilentlyContinue }
gpresult /scope computer /h "$out\gpresult.html" /f | Out-Null
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip  — also generate the container bundle: (as runtime account) cd $inst\MccScripts; wsl bash collectmccdiagnostics.sh"
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| Scripts / install dir | `deliveryoptimization-cli mcc-get-scripts-path` |
| Enter distro (as runtime acct) | `wsl -d Ubuntu-24.04-Mcc` |
| Containers | `sudo iotedge list` |
| IoT Edge logs | `sudo iotedge system logs -- -f` |
| Restart IoT Edge | `sudo iotedge system restart` (Linux host: `sudo systemctl restart iotedge`) |
| IoT Edge health | `sudo iotedge check --verbose` |
| Port forwarding | `netsh interface portproxy show v4tov4` |
| IP Helper | `Get-Service iphlpsvc` |
| Task status | `Get-ScheduledTask MCC_* \| Get-ScheduledTaskInfo` |
| Update task creds | `.\updatetaskpasswords.ps1 -Credential $cred` |
| Upstream test (in distro) | `curl -v http://b1.download.windowsupdate.com` |
| Registration test (in distro) | `nc -vz geomcc.prod.do.dsp.mp.microsoft.com 443` |
| Client fetch test | `Invoke-WebRequest "http://<node>/filestreamingservice/files/7bc846e0-af9c-49be-a03d-bb04428c9bb5/Microsoft.png?cacheHostOrigin=dl.delivery.mp.microsoft.com"` |
| Client use | `Get-DeliveryOptimizationStatus \| Select FileId,BytesFromCacheServer,BytesFromHttp` |
| Support bundle | `wsl bash collectmccdiagnostics.sh` |
| Scripted health check | `.\Get-ConnectedCacheNodeHealth.ps1 -Mode Host` / `-Mode Client -CacheHost <node>` |

---
## 🎓 Learning Pointers
- Think of a Windows-hosted node as "Linux appliance in WSL2 + Windows glue". The glue (runtime account, scheduled tasks, portproxy, IP Helper) is where it breaks. [MCC troubleshooting](https://learn.microsoft.com/windows/deployment/do/mcc-ent-troubleshooting).
- For big sites or anything you don't want tied to WSL quirks, an **Ubuntu 24.04** VM host removes Layers 2 and 4 of the stack entirely.
- The strongest MSP use-case is **Autopilot provisioning centres and bandwidth-poor branches** — first-download WAN saturation that DO peering alone can't fix. See `DeliveryOptimization-A.md` Phase 1.
- Licensing is client-side and easy to miss: Windows Enterprise/Education (or Windows Server) per consuming device. [Prerequisites](https://learn.microsoft.com/windows/deployment/do/mcc-ent-prerequisites).
- Don't co-host with a ConfigMgr DP (port 80 conflict); ConfigMgr shops should evaluate the DP-integrated Connected Cache instead. [MCC overview](https://learn.microsoft.com/windows/deployment/do/mcc-ent-edu-overview).
- Release notes list fixed bugs (non-EN locale install failure, cache overgrowing its drive) — always check the installed app version before deep troubleshooting. [MCC release notes](https://learn.microsoft.com/windows/deployment/do/mcc-ent-release-notes).
