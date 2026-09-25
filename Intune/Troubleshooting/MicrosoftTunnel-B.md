# Microsoft Tunnel Gateway (Intune VPN for iOS/Android) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

**Scope:** Microsoft Tunnel Gateway — the Intune-managed VPN server that runs as two containers (`mstunnel-agent`, `mstunnel-server`) on a Linux host, and the Microsoft Defender for Endpoint app that acts as the Tunnel client on enrolled iOS/iPadOS and Android Enterprise devices. **Not** Always On VPN (`Windows/Troubleshooting/AlwaysOnVPN-B.md`) or Global Secure Access (`EntraID/Troubleshooting/GlobalSecureAccess-A.md`). Tunnel and GSA **can't run at the same time on the same device**.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

**Tenant side (admin workstation, PowerShell 7 or 5.1):**

```powershell
# 1. Sites + per-server health as Intune sees it (Graph beta)
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All" -NoWelcome
$sites = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/microsoftTunnelSites").value
foreach ($s in $sites) {
    $srv = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/microsoftTunnelSites/$($s.id)/microsoftTunnelServers").value
    $srv | ForEach-Object { [pscustomobject]@{ Site=$s.displayName; PublicAddress=$s.publicAddress; Server=$_.displayName; Health=$_.tunnelServerHealthStatus; LastCheckin=$_.lastCheckinDateTime } }
}

# 2. Server configurations (IP pool, DNS, split-tunnel routes, port)
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/microsoftTunnelConfigurations").value |
    Select-Object displayName, network, dnsServers, routesInclude, routesExclude, listenPort
```

**Server side (Linux host, as root):**

```bash
# 3. Are both containers up and healthy?
mst-cli agent status ; mst-cli server status

# 4. What's in the recent logs?
journalctl -t ocserv -t mstunnel-agent -t mstunnel_monitor --since "30 min ago" --no-pager | tail -60

# 5. Kernel prerequisites that silently break after reboots/upgrades
sysctl net.ipv4.ip_forward ; lsmod | grep -E "ip_tables|^tun"
```

| What you see | What it means / next step |
|---|---|
| Server `Health` = `unhealthy`/`offline`, `LastCheckin` > 5 min old | Agent can't reach Intune (outbound 443, proxy, agent cert). → Fix 1 |
| `mst-cli server status` not `running`/`healthy` | Server container down → Fix 2 |
| ocserv log: `Can't open /dev/net/tun: Operation not permitted` | Documented known issue after a Linux reboot → Fix 2 (`mst-cli server restart`) + Fix 3 (load `tun`) |
| `ip_forward = 0`, or `ip_tables`/`tun` missing from `lsmod` | Clients connect but can't reach anything internal, or can't connect at all → Fix 3 |
| All servers healthy, users get a TLS/certificate error in Defender | TLS cert expired, SAN mismatch, or private chain not pushed to devices → Fix 4 |
| Connected, but internal names don't resolve / only some subnets work | DNS servers / suffix / split-tunnel routes, or Docker/Podman bridge overlaps a corp subnet → Fix 5 |
| Users can't sign in to Edge while on Tunnel with a PAC URL | Documented PAC known issue → Fix 6 |
| Health = `offline` in admin center **but users connect fine** | Documented known issue — agent enrollment broken; reinstall re-enrolls → Fix 7 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Licensing & RBAC
  ├── Intune Plan 1 (Tunnel for MDM) — Tunnel for MAM needs the Intune Suite / advanced add-on
  └── Installer account: Intune Administrator role + an Intune licence
        └── Linux host (supported distro only: RHEL 8.10 / 9.x / 10.x w/ Podman, Ubuntu 24.04 / 26.04 w/ Docker CE)
              ├── 64-bit CPU, sized per device count (1,000 devices → 4 CPU / 4 GB / 30 GB)
              ├── net.ipv4.ip_forward = 1 (persisted in /etc/sysctl.conf)
              ├── ip_tables + tun kernel modules loaded (RHEL doesn't auto-load ip_tables)
              └── Docker/Podman bridge (172.17.0.0/16 / 10.88.0.0/16) must NOT overlap corp routes
                    └── Network
                          ├── Inbound TCP 443 AND UDP 443 (or custom listen port) → server NIC / LB
                          ├── Outbound TCP 443 → *.manage.microsoft.com, login.microsoftonline.com,
                          │   *.sts.windows.net, graph.microsoft.com, *.blob.core.windows.net,
                          │   Microsoft Artifact Registry (image pulls) — NO TLS break-and-inspect, NO auth proxy
                          └── Route from host to on-prem resources (ExpressRoute/VPN if cloud VM)
                                └── TLS certificate on the server
                                      ├── SAN matches the Site public address (FQDN or IP)
                                      ├── Full chain copied during install; OCSP/CRL reachable from server
                                      └── iOS: public cert ≤ 398 days validity
                                            └── Intune objects
                                                  ├── Server configuration (IP pool, DNS, routes, port)
                                                  ├── Site (public address, internal probe URL, upgrade window)
                                                  └── Server enrolled into the Site (agent.p12 auto-renewed)
                                                        └── Device side
                                                              ├── Enrolled iOS/iPadOS or Android Enterprise
                                                              │   (FullyManaged/COPE/BYOD work profile — NOT Dedicated)
                                                              ├── Microsoft Defender app deployed (Tunnel client)
                                                              ├── VPN profile, connection type "Microsoft Tunnel"
                                                              └── Trusted certificate profile if TLS cert is private
```
</details>

---
## Diagnosis & Validation Flow

1. **Is Intune hearing from the server?**
   `Invoke-MgGraphRequest ... microsoftTunnelServers` (Triage #1).
   Good: `tunnelServerHealthStatus` = `healthy`, `lastCheckinDateTime` within 5 minutes.
   Bad: older check-in → the agent can't get out. Go to step 4.

2. **Are the containers running?**
   `mst-cli agent status` and `mst-cli server status` → expect `State: running`, `Health: healthy`.
   `docker ps -a` (or `podman ps -a`) → expect `mstunnel-agent` and `mstunnel-server`, both `Up`.
   Bad: `Exited` → Fix 2.

3. **Is the listener reachable from outside?**
   From an external host: `curl -vk https://<tunnel-fqdn>:443/` → the server answers a GET with a static page (this is the load-balancer probe).
   Bad: timeout → inbound firewall/NAT/LB. **The readiness tool does not test inbound ports**, so check them by hand.
   Remember UDP 443 too. With TCP only, clients fall back to a slower TLS-only data channel.

4. **Can the host reach Intune without interception?**
   `sudo ./mst-readiness network` (download with `wget --output-document=mst-readiness https://aka.ms/microsofttunnelready`; needs `jq`).
   Good: every endpoint succeeds. Bad: failures on `*.manage.microsoft.com` usually mean a TLS-inspecting or authenticated proxy. The agent uses mutual TLS, so neither is supported.

5. **Kernel plumbing:** `sysctl net.ipv4.ip_forward` → `1`; `lsmod | grep ip_tables` and `lsmod | grep tun` → both present. Bad → Fix 3.

6. **Certificate:** `echo | openssl s_client -connect <tunnel-fqdn>:443 -servername <tunnel-fqdn> 2>/dev/null | openssl x509 -noout -subject -enddate -ext subjectAltName`
   Good: SAN contains the Site public address, and `notAfter` is more than 30 days away. Anything under 30 days shows as a health *Warning*.

7. **Client side:** on the device, open Defender → Tunnel and check its status. In Intune, check the VPN profile's per-device status and that the device is in the assignment group.
   Per-app VPN on iOS **ignores split-tunnel rules**. That's expected behaviour, not a fault.

---
## Common Fix Paths

<details><summary>Fix 1 — Server offline / not checking in (agent can't reach Intune)</summary>

```bash
# Look at what the agent says
journalctl -t mstunnel-agent --since "2 hours ago" --no-pager | tail -80
# Check the proxy variables Tunnel actually uses
cat /etc/mstunnel/env.sh
# Test the endpoints
sudo ./mst-readiness network
# Check the agent certificate renewal date
cat /etc/mstunnel/agent-info.json
```
- Proxy: set `http_proxy`/`https_proxy` in `/etc/mstunnel/env.sh`. For Docker, also set `/etc/systemd/system/docker.service.d/http-proxy.conf`. For Podman, set `/etc/profile.d/http_proxy.sh`.
- Exempt the host from TLS inspection. Authenticated proxies aren't supported.
- On RHEL with a proxy on a non-standard port, SELinux may block it: `sudo semanage port -a -t http_port_t -p tcp <proxyport>`.
- Then restart: `mst-cli agent restart`.
</details>

<details><summary>Fix 2 — Server container stopped / `/dev/net/tun` error after reboot</summary>

```bash
mst-cli server restart
mst-cli agent restart
mst-cli server status
# Podman "Error executing checkup" in mstunnel_monitor → restart the containers directly
podman restart mstunnel-server mstunnel-agent
```
If the problem comes back after every reboot, schedule `mst-cli server restart` from cron at boot (`@reboot sleep 60 && /usr/sbin/mst-cli server restart`). Microsoft documents this as the workaround.
</details>

<details><summary>Fix 3 — IP forwarding / ip_tables / tun missing</summary>

```bash
sysctl -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p
/sbin/modprobe ip_tables ; echo ip_tables > /etc/modules-load.d/mstunnel_iptables.conf
/sbin/modprobe tun       ; echo tun       > /etc/modules-load.d/mstunnel_tun.conf
mst-cli server restart
```
A Tunnel server update can drop manually loaded modules. Check `lsmod` after every upgrade.
</details>

<details><summary>Fix 4 — TLS certificate expired, wrong SAN, or untrusted chain</summary>

```bash
# Copy the new cert and full chain (PEM or PFX), then import
mst-cli import_cert
mst-cli server restart
```
- The SAN must match the Site **public address** exactly. Wildcards like `*.contoso.com` are OK; partial wildcards aren't.
- For a private CA, deploy the **full chain** to devices with an Intune *Trusted certificate* profile before you cut over.
- For iOS, a public certificate can't be valid for more than 398 days.
- Rollback: keep the old cert/key pair and re-run `import_cert` with it if clients break.
</details>

<details><summary>Fix 5 — Connected but internal resources unreachable (DNS / routes / bridge overlap)</summary>

1. Check the server configuration (Triage #2): `dnsServers` must be internal resolvers, and `routesInclude` must cover the target subnets.
2. Check that the host itself can reach the resource: `curl -v http://<internal-host>` from the Linux box.
3. Bridge overlap: if corp uses 172.17.x.x (Docker) or 10.88.x.x (Podman), move the bridge. For Docker:
```bash
sudo mst-cli server stop ; sudo mst-cli agent stop
sudo ip link del docker0
echo '{ "bip":"192.168.128.1/24" }' | sudo tee /etc/docker/daemon.json   # pick a non-conflicting range
sudo systemctl restart docker
sudo mst-cli agent start ; sudo mst-cli server start
```
For Podman: stop both, `ip link del cni-podman0`, edit `subnet`/`gateway` in `/etc/cni/net.d/87-podman-bridge.conflist`, then start both.
Rollback: restore the previous `daemon.json` or conflist and restart.
4. Per-app VPN doesn't support local/internal top-level domains. Use a real DNS suffix.
</details>

<details><summary>Fix 6 — Edge sign-in fails on Tunnel with a PAC file</summary>

This is a documented known issue. Use one of these workarounds:
- Switch the VPN profile to a **direct proxy** instead of a PAC URL.
- Use split tunnelling: include only the routes that need the proxy, and exclude the Entra login/auth endpoints.
</details>

<details><summary>Fix 7 — Admin center says offline, users connect fine</summary>

This is a documented known issue. The agent's enrollment with Intune is broken even though ocserv still serves clients. The fix is to **reinstall Tunnel**, which re-enrolls the agent:
```bash
mst-cli uninstall
# Re-run setup (download from Intune admin center > Tenant administration > Microsoft Tunnel Gateway > Servers > Create)
chmod +x mstunnel-setup && sudo ./mstunnel-setup
```
Do this in a maintenance window: it disconnects users. On a multi-server Site, drain one node at a time behind the LB.
</details>

---
## Escalation Evidence

```
Tenant ID:                         <tenant-guid>
Site name / public address:        <site> / <fqdn:port>
Server name(s):                    <server>
Admin-center health status:        <healthy|warning|unhealthy|offline>  Last check-in: <UTC>
Failing health check(s):           <e.g. TLS certificate / Upgradeability / Server logs>
Linux distro + version:            <e.g. RHEL 9.6 / Ubuntu 24.04>
Container runtime + version:       <docker --version / podman --version>
mst-cli agent status:              <paste>
mst-cli server status:             <paste>
ip_forward / ip_tables / tun:      <1|0> / <present|missing> / <present|missing>
Proxy in path? TLS inspection?     <yes/no> / <yes/no>
Device platform + mode:            <iOS 18.x | Android 14 COPE ...>
Defender app version:              <x.y.z>
VPN profile type:                  <device-wide | per-app>  Split tunnel: <yes/no>
Verbose logs sent (Logs tab):      <start/end UTC>  (8-hour verbosity-4 window, reproduce inside it)
journalctl excerpt:                <journalctl -t ocserv -t mstunnel-agent -t mstunnel_monitor --since ...>
Steps already tried:               <list>
```

---
## 🎓 Learning Pointers
- The **Upgradeability** and **Server version** health checks matter: two or more versions behind is *out of support*. Set the Site's upgrade window so Intune can roll servers automatically. See [Monitor Microsoft Tunnel](https://learn.microsoft.com/en-us/intune/device-security/microsoft-tunnel/monitor).
- The `deviceId` in `ocserv-access` and `OCSERV_TELEMETRY` logs is the **Defender install instance**, not the Intune or Entra device ID. It changes if Defender is reinstalled, so don't try to join it to Intune device inventory.
- The readiness tool (`mst-readiness network|utils|account`) doesn't validate **inbound** ports, which Microsoft calls out as the most common misconfiguration. Always test 443/TCP and 443/UDP from outside. See [Prerequisites](https://learn.microsoft.com/en-us/intune/device-security/microsoft-tunnel/prerequisites).
- *Send logs* in the admin center raises verbosity to 4 for a fixed 8 hours, then resets to 0 even if you had a custom level. Reproduce inside that window, and put your own verbosity back afterwards.
- Supported distros change often (RHEL 8.9/9.3/9.4 support ended Nov 2025; Android 10 support ended 31 Mar 2026). Re-check the supported table before any OS upgrade on the host. Upgrading from Podman v3 to v4.2+ needs a full Tunnel uninstall/reinstall.
- For the full architecture, see `MicrosoftTunnel-A.md`. For a fleet health snapshot, run `Scripts/Get-MicrosoftTunnelHealthAudit.ps1`.
