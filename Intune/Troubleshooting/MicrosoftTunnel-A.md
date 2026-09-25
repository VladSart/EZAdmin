# Microsoft Tunnel Gateway (Intune VPN for iOS/Android) — Reference Runbook (Mode A: Deep Dive)
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

**In scope**
- Microsoft Tunnel Gateway servers (Linux + Docker/Podman) that are enrolled into Intune Sites.
- Server configurations, Sites, health checks, upgrades, and TLS/agent certificates.
- Enrolled iOS/iPadOS and Android Enterprise devices (Fully Managed, COPE, personally-owned work profile) using the Microsoft Defender app as the Tunnel client.
- Architecture notes on Tunnel for MAM (unenrolled devices). It's licensed separately as an Intune advanced capability.

**Out of scope / see elsewhere**
- Windows VPN: `Windows/Troubleshooting/AlwaysOnVPN-A.md`.
- SSE / ZTNA: `EntraID/Troubleshooting/GlobalSecureAccess-A.md` and `Windows/Troubleshooting/GlobalSecureAccess-Windows-A.md`. **Tunnel and GSA can't coexist on the same device.**
- Android Enterprise **Dedicated** devices aren't supported by Tunnel.
- Entra application proxy in front of Tunnel isn't supported.

**Assumptions**
- The Linux host is administered by the MSP. The engineer has root/sudo on it.
- The admin workstation has `Microsoft.Graph.Authentication`, and the account has at least Intune *Microsoft Tunnel Gateway / Read* rights.
- Facts come from Microsoft Learn Tunnel pages fetched on 2026-09-25: Prerequisites (`ms.date` 2026-09-03), Monitor (updated 2026-08-24), and File & command reference.

---
## How It Works

<details><summary>Full architecture</summary>

```
 iOS / Android device                       Linux host (on-prem or cloud VM)                   Microsoft cloud
 ┌─────────────────────────┐   TLS 1.3/1.2    ┌─────────────────────────────────────┐   mTLS 443   ┌──────────────────┐
 │ Microsoft Defender app  │ ───TCP 443────▶ │  mstunnel-server  (ocserv)           │              │  Intune service  │
 │  (Tunnel client)        │ ───UDP 443────▶ │   - terminates client VPN (DTLS/TLS) │              │  (Sites, Server  │
 │ VPN profile:            │                 │   - assigns IP from Server config    │              │   configs, health│
 │  "Microsoft Tunnel"     │                 │     pool (e.g. 169.100.0.0/16)       │              │   thresholds)    │
 │  device-wide / per-app  │                 │   - NAT via container bridge ─┐      │              └────────▲─────────┘
 └─────────┬───────────────┘                 │  mstunnel-agent   │           │      │ ─────────────────────┘
           │ Entra auth (token)              │   - enrolls/checks in, pulls   │      │   (*.manage.microsoft.com,
           ▼                                 │     admin-settings.json         │      │    login.microsoftonline.com,
      Microsoft Entra ID                     │   - uploads logs to Azure blob  │      │    *.blob.core.windows.net)
      (+ Conditional Access)                 │  mstunnel_monitor (host)        │      │
                                             │   - health checks every ~5 min  ▼      │
                                             │  ip_forward=1, ip_tables, tun ──▶ NIC2 ──▶ on-prem resources
                                             └─────────────────────────────────────┘
                                                        ▲ image pulls (Microsoft Artifact Registry)
```

**Two containers, one host service**
- **`mstunnel-server`** runs **ocserv**, the open-source OpenConnect-compatible server. It listens on TCP and UDP 443 by default (configurable per Server configuration). It authenticates clients using Entra ID tokens, assigns each client a virtual IP from the configured `Network` (up to 64,000 clients per server), and forwards traffic through the host kernel. That's why `ip_forward`, `ip_tables`, and `tun` are hard requirements.
- **`mstunnel-agent`** is the Intune connector. It enrolls the server using an agent certificate (`/etc/mstunnel/private/agent.p12`, auto-renewed; the renewal date is in `agent-info.json`). It pulls the serialized Server configuration into `/etc/mstunnel/admin-settings.json` (**Intune-owned, never hand-edit**), reports health, and uploads logs.
- **`mstunnel_monitor`** is a host-side task behind `mst-cli`. It runs the health checkup and restarts services. Its log tag is `mstunnel_monitor`.

**Intune object model**
- **Server configuration**: IP pool, DNS servers, default domain suffix, `RoutesInclude`/`RoutesExclude` (split tunnel), and listen port. One configuration can back many Sites.
- **Site**: a logical group of servers behind one **public address** (a single server or a load balancer). It also holds the optional **internal network probe URL** (used by the *Internal network accessibility* health check) and the **upgrade window** settings.
- **Server**: an enrolled Linux host that belongs to exactly one Site.

**Client side**
- The Tunnel client is the **Microsoft Defender for Endpoint** app. You don't need Defender threat-protection licensing just for the Tunnel role.
- The VPN profile uses connection type *Microsoft Tunnel* and can be device-wide or per-app.
- On iOS, **split-tunnel rules are ignored when the profile is per-app VPN**.
- Proxy (direct or PAC) is supported only on Android 11+ and iOS/iPadOS. Edge sign-in with a PAC URL is a documented known issue.

**Tunnel for MAM** (unenrolled devices) uses the same gateway. The client is either Edge / LOB apps built with the Tunnel for MAM SDK (iOS) or Defender plus app configuration (Android). It needs an additional licence beyond Intune Plan 1.

**Upgrades**: Intune publishes new container images. Servers pull them from the Microsoft Artifact Registry within the Site's upgrade window. The *Upgradeability* health check turns unhealthy when the server can't reach the registry. *Server version* two or more releases behind means **out of support**.

**Authentication path**: the device gets an Entra token for the Tunnel resource. Conditional Access can target it, and compliance-based CA is the usual design. See the Learn article *Use Microsoft Tunnel VPN gateway with Conditional Access*.
</details>

---
## Dependency Stack

```
L0  Licensing: Intune Plan 1 (MDM Tunnel) | + Intune advanced capability (Tunnel for MAM)
L1  Linux host: supported distro/runtime pair only
      RHEL 8.10 / 9.5–9.8 / 10.0–10.2 → Podman (rootless supported with extra prereqs)
      Ubuntu 24.04 / 26.04           → Docker CE
      (RHEL 8.9, 9.3, 9.4 support ended Nov 2025)
L2  Kernel: net.ipv4.ip_forward=1 · ip_tables · tun   (+ optional auditd)
L3  Container bridge: Docker 172.17.0.0/16 | Podman 10.88.0.0/16 — must not overlap corp routes
L4  Network: inbound TCP+UDP 443 (or custom) · outbound TCP 443 to Intune/Entra/STS/Graph/Blob/MAR
      no TLS break-and-inspect · no authenticated proxy · route to on-prem (ExpressRoute/VPN if cloud)
L5  TLS server certificate: SAN = Site public address · full chain on server · OCSP/CRL reachable
      iOS public certs ≤398 days · ≥2048-bit key · private CA chain pushed to devices
L6  Intune: Server configuration → Site → Server enrolled (agent.p12)
L7  Entra ID auth (+ Conditional Access on the Tunnel resource)
L8  Device: enrolled iOS/Android Enterprise (not Dedicated) · Defender app · VPN profile · trusted-cert profile
L9  User traffic: DNS via configured servers · routes include/exclude · per-app assignments
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Server *Last check-in* > 5 min, status Unhealthy | Outbound 443 blocked, TLS inspection, auth proxy, agent container down | `journalctl -t mstunnel-agent`, `mst-readiness network` |
| Admin center shows Offline, users still connect | Known issue: agent enrollment broken | Reinstall to re-enroll (Playbook 5) |
| Clients can't connect after host reboot; `Can't open /dev/net/tun` | Known issue: server container starts before tun is available | `mst-cli server restart`; cron `@reboot` |
| Connect OK, no internal reachability | `ip_forward=0`, `ip_tables` missing, routes/DNS, bridge overlap | `sysctl`, `lsmod`, Server config, `ip route` |
| Only certain subnets unreachable | Subnet overlaps the Docker/Podman bridge or the client IP pool | Compare `bip`/conflist and `Network` against corp ranges |
| TLS error on device | Expired cert, SAN mismatch, private chain not trusted, iOS >398-day public cert | `openssl s_client`, trusted-cert profile status |
| *TLS certificate revocation* = Warning | Server can't reach the cert's OCSP/CRL URLs | `curl` the AIA/CDP URLs from the host |
| *Upgradeability* Unhealthy | Server can't reach the Microsoft Artifact Registry | MAR firewall rules, proxy for docker/podman pulls |
| *Server version* Unhealthy | Two or more versions behind (out of support) | Site upgrade window; manual upgrade |
| *Server logs* Unhealthy | Blob upload blocked (`*.blob.core.windows.net`) | Outbound firewall |
| Podman: `Error executing checkup` in mstunnel_monitor | Known Podman container-visibility bug | `podman restart` the containers |
| Podman: `System.DateTime` JSON errors | Old agent container date-format bug, not fatal | Update containers |
| Per-app VPN on iOS ignores split-tunnel routes | By design | Use device-wide profile if split tunnel needed |
| Edge won't sign in while connected | PAC known issue | Direct proxy, or split-tunnel the auth endpoints |
| Tunnel profile won't apply; GSA client present | Tunnel and GSA are mutually exclusive on a device | Remove one |
| Android Dedicated device can't use Tunnel | Unsupported mode | Use a different enrollment mode |
| Android 10 devices dropped | Android 10 support ended 31 Mar 2026 | Upgrade to Android 11+ |

---
## Validation Steps

1. **Intune object health**
   ```powershell
   Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All" -NoWelcome
   (Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceManagement/microsoftTunnelSites").value | Select displayName, publicAddress, internalNetworkProbeUrl, upgradeAutomatically, upgradeAvailable
   ```
   Good: every Site has a public address and at least one server. Bad: a Site with zero servers means nothing ever enrolled.

2. **Per-server status**: Graph `microsoftTunnelServers` under each Site.
   Good: `healthy`, recent `lastCheckinDateTime`. Bad: `unhealthy`/`offline`, or a stale check-in.

3. **Containers**: `mst-cli agent status` and `mst-cli server status` → `running` / `healthy`.
   Also `docker ps -a` (or `podman ps -a`).

4. **Kernel**: `sysctl net.ipv4.ip_forward` → `1`; `lsmod | grep -E 'ip_tables|^tun'` → both listed.

5. **Egress**: `sudo ./mst-readiness network` → all pass. `./mst-readiness account` checks the installer account's roles.

6. **Ingress**: from outside, `curl -vk https://<fqdn>:<port>/` returns the static probe page. Test UDP separately, for example `nc -vu <fqdn> 443` from an external host. UDP is connectionless, so a clean result only proves nothing *rejected* it.

7. **Certificate**: `openssl s_client -connect <fqdn>:443 -servername <fqdn> </dev/null | openssl x509 -noout -enddate -ext subjectAltName`.

8. **Live sessions**: `mst-cli server show users` and `mst-cli server show status` show connected users and server stats.

9. **Device**: in the Defender app, Tunnel shows *Connected*. In Intune, the VPN profile shows Succeeded for the device.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Install / enrollment**
- Run `mst-readiness` (all modes) **before** `mstunnel-setup`. It needs `jq`.
- On RHEL, load `ip_tables` first. Setup stops on a missing module.
- If you're using a proxy, write `/etc/profile.d/http_proxy.sh` **before** setup (Podman). Setup then copies the values into `/etc/mstunnel/env.sh`. After setup, edit `env.sh` and run `mst-cli server restart`.
- The installer account needs the Intune Administrator role **and** an Intune licence.

**Phase 2 — Server steady state**
- Work through the health-check list in order: check-in → containers → config applied → TLS → revocation → internal probe → upgradeability → logs.
- Only CPU, memory, disk, and latency thresholds are customizable (tenant-wide).
- Default thresholds: CPU/memory ≤95% healthy. Disk >5 GB free healthy. Latency <10 ms healthy. More than 4,990 current connections flags unhealthy.

**Phase 3 — Client connect**
- Device side: Defender app present and signed in, VPN profile assigned, trusted cert installed for a private CA, device compliant if CA requires it.
- Server side: look for the user in `journalctl -t ocserv`. Turn on access logs (`TRACE_SESSIONS=1` in `env.sh`, then restart) only while diagnosing, because they cost performance.

**Phase 4 — Data path**
- DNS: the Server config `DNSServers` must be internal resolvers that the **host** can reach.
- Routes: `RoutesInclude` defaults to `default` (full tunnel). Check that on-prem return routes point back to the host for the client pool. NAT through the bridge normally hides this, but custom routing can bypass it.
- Bridge overlap: move `bip` (Docker) or the conflist subnet (Podman).

**Phase 5 — Lifecycle**
- Monitor the TLS certificate (Warning at ≤30 days) and the agent certificate (auto-renews; Warning at <30 days means renewal failed).
- Keep servers at most one version behind. Check the distro support table before OS upgrades.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Restore check-in through a proxy</summary>

1. Confirm the proxy is unauthenticated and not inspecting TLS for this host. If it is, get an exemption. There's no workaround.
2. Docker: set `/etc/systemd/system/docker.service.d/http-proxy.conf` (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY=127.0.0.1,localhost`), then `systemctl daemon-reload && systemctl restart docker`.
3. Podman: set `/etc/profile.d/http_proxy.sh` with `export HTTP_PROXY=...` and `export HTTPS_PROXY=...`. On SELinux, allow the port with `semanage port -a -t http_port_t -p tcp <port>` (use `-m` if the port is already assigned to another type).
4. Add `HTTP_PROXY` and `HTTPS_PROXY` to `/etc/mstunnel/env.sh`, then run `mst-cli agent restart; mst-cli server restart`.
5. Validate with `mst-readiness network` and a fresh Last check-in.

**Rollback:** remove the lines you added and restart the same services.
</details>

<details><summary>Playbook 2 — Replace the TLS certificate</summary>

1. Issue a cert whose SAN matches the Site public address. For iOS with a public CA, validity must be ≤398 days. Use a key of 2048 bits or larger.
2. For a private CA, assign an Intune Trusted certificate profile with the full chain to the device groups **first**, and wait for Succeeded.
3. On each server, stage the new cert, key, and chain, then run `mst-cli import_cert` and `mst-cli server restart`.
4. Validate with `openssl s_client`. The admin-center TLS health check goes Healthy on the next check-in.

**Rollback:** re-import the previous cert/key pair (keep a copy until clients are confirmed working).
</details>

<details><summary>Playbook 3 — Re-address the container bridge</summary>

1. `mst-cli server stop; mst-cli agent stop`.
2. Docker: `ip link del docker0`, set `"bip":"<new-cidr>"` in `/etc/docker/daemon.json`, then `systemctl restart docker`.
   Podman: `ip link del cni-podman0`, then edit `subnet`/`gateway` in `/etc/cni/net.d/87-podman-bridge.conflist`.
3. `mst-cli agent start; mst-cli server start`.
4. Validate: `ip addr show docker0` (or `cni-podman0`) shows the new range, and the target subnet is now reachable from a client.

**Rollback:** restore the original file (back it up first) and repeat steps 1–3.

Note: Tunnel must already be installed before you change the bridge.
</details>

<details><summary>Playbook 4 — Persist kernel prerequisites and survive reboots</summary>

```bash
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf && sysctl -p
echo ip_tables > /etc/modules-load.d/mstunnel_iptables.conf
echo tun       > /etc/modules-load.d/mstunnel_tun.conf
( crontab -l 2>/dev/null; echo '@reboot sleep 60 && /usr/sbin/mst-cli server restart' ) | crontab -
```
Re-check after every Tunnel upgrade. Microsoft notes that manually loaded modules may not persist across updates.
</details>

<details><summary>Playbook 5 — Reinstall to re-enroll (Offline-but-working, or corrupted agent)</summary>

1. Drain: take the node out of the load balancer pool. On a single-server Site, schedule an outage.
2. Run `mst-cli uninstall`. This removes the containers and `/etc/mstunnel`, so back up any custom `env.sh` edits first.
3. Download the setup script from Intune admin center > Tenant administration > Microsoft Tunnel Gateway > Servers > Create.
4. Run `chmod +x mstunnel-setup && sudo ./mstunnel-setup` (rootless Podman uses the modified command line from the install doc). Accept the EULA, place the cert chain, sign in with an Intune Admin, and choose the Site.
5. Validate the server appears Healthy under the Site, then put it back into the LB pool.

**Rollback:** none needed. The old enrollment is replaced; delete the stale server object from the Site if it stays behind.
</details>

<details><summary>Playbook 6 — Capture verbose logs for Microsoft</summary>

1. Go to Intune admin center > Tenant administration > Microsoft Tunnel Gateway > *server* > **Logs** > **Send logs**.
2. Reproduce the issue within the next **8 hours**. Verbosity is 4 during that window, and it can't be extended or stopped early.
3. After 8 hours, the second log set uploads and verbosity resets to **0**. Re-apply any custom level yourself.
4. `ocserv-access` logs aren't included. Export them yourself if relevant.
</details>

---
## Evidence Pack

Run on the admin workstation. It collects the tenant-side view and prints the Linux commands to run on each server.

```powershell
<#
  Microsoft Tunnel evidence pack (tenant side). Read-only.
  Requires: Microsoft.Graph.Authentication; DeviceManagementConfiguration.Read.All
#>
$out = Join-Path $env:TEMP ("TunnelEvidence_{0:yyyyMMdd_HHmmss}" -f (Get-Date))
New-Item -ItemType Directory -Path $out -Force | Out-Null
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All" -NoWelcome
$base = "https://graph.microsoft.com/beta/deviceManagement"
$sites   = (Invoke-MgGraphRequest GET "$base/microsoftTunnelSites").value
$configs = (Invoke-MgGraphRequest GET "$base/microsoftTunnelConfigurations").value
$servers = foreach ($s in $sites) {
    (Invoke-MgGraphRequest GET "$base/microsoftTunnelSites/$($s.id)/microsoftTunnelServers").value |
        ForEach-Object { $_ | Add-Member -NotePropertyName siteName -NotePropertyValue $s.displayName -PassThru }
}
$sites   | ConvertTo-Json -Depth 6 | Out-File "$out\sites.json"
$configs | ConvertTo-Json -Depth 6 | Out-File "$out\configurations.json"
$servers | ConvertTo-Json -Depth 6 | Out-File "$out\servers.json"
@'
# Run on EACH Linux Tunnel server as root, then attach tunnel_host_evidence.txt
{
  date -u; cat /etc/os-release; uname -r
  docker --version 2>/dev/null || podman --version
  mst-cli agent status; mst-cli server status; mst-cli server show status
  sysctl net.ipv4.ip_forward; lsmod | grep -E 'ip_tables|^tun'
  cat /etc/mstunnel/version-info.json /etc/mstunnel/agent-info.json
  grep -v -i pass /etc/mstunnel/env.sh
  ip -brief addr; ip route
  journalctl -t ocserv -t mstunnel-agent -t mstunnel_monitor --since "24 hours ago" --no-pager | tail -500
} > tunnel_host_evidence.txt 2>&1
'@ | Out-File "$out\RUN_ON_LINUX_HOST.sh" -Encoding ascii
Write-Host "Evidence written to $out"
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `mst-cli agent status` / `mst-cli server status` | Container state + health |
| `mst-cli server restart` / `mst-cli agent restart` | Restart components |
| `mst-cli server show users` | Currently connected users |
| `mst-cli server show status` | Server stats |
| `mst-cli server show ip bans` | Banned client IPs (brute-force protection) |
| `mst-cli import_cert` | Import or rotate the TLS certificate |
| `mst-cli uninstall` | Remove Tunnel (re-enroll path) |
| `journalctl -t ocserv -t mstunnel-agent -t mstunnel_monitor -f` | Live combined logs |
| `journalctl -t ocserv \| grep TELEMETRY` | Connect/disconnect telemetry |
| `sudo ./mst-readiness network` / `utils` / `account` | Pre-flight egress / utilities / RBAC checks |
| `sysctl net.ipv4.ip_forward` · `lsmod \| grep -E 'ip_tables\|^tun'` | Kernel prerequisites |
| `docker ps -a` / `podman ps -a` | Container list |
| `podman port mstunnel-server` | Port mappings (Podman) |
| `Invoke-MgGraphRequest GET .../beta/deviceManagement/microsoftTunnelSites` | Sites via Graph |
| `.../microsoftTunnelSites/{id}/microsoftTunnelServers` | Server health via Graph |

---
## 🎓 Learning Pointers
- ocserv is an OpenConnect server. That's why the client/server protocol is TLS plus a UDP (DTLS) data channel, and why UDP 443 matters for performance. Background: [ocserv project](https://ocserv.gitlab.io/www/).
- `admin-settings.json` is Intune-owned. If a setting looks wrong on the host, change the **Server configuration** in Intune and let the agent re-apply it. The *Server configuration* health check reports whether that apply worked. See [File and command reference](https://learn.microsoft.com/en-us/intune/device-security/microsoft-tunnel/ref-file-commands).
- The supported-OS table is strict ("versions not listed are not supported") and changes often. Build a quarterly check into the client's patch cycle. See [Prerequisites](https://learn.microsoft.com/en-us/intune/device-security/microsoft-tunnel/prerequisites).
- Tunnel for MAM extends the same gateway to unenrolled BYOD. Read [Microsoft Tunnel for MAM](https://learn.microsoft.com/en-us/intune/device-security/microsoft-tunnel/mam) before promising it, because licensing differs from MDM Tunnel.
- Conditional Access on the Tunnel resource is the real access-control lever. The gateway itself doesn't evaluate compliance. See *Use Microsoft Tunnel VPN gateway with Conditional Access* on Learn.
- Related in this repo: `Intune/Troubleshooting/Certificates-A.md` (trusted cert/SCEP/PKCS profiles for the private-CA chain), `Intune/Troubleshooting/AppProtection-A.md` (MAM side), and `Scripts/Get-MicrosoftTunnelHealthAudit.ps1`.
