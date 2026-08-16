# BranchCache — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

Run these first. Results tell you which fix path to take.

```powershell
# 1. Is BranchCache even enabled, and what mode is it in?
netsh branchcache show status all

# 2. Which mode does policy say this client SHOULD be in?
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\BranchCache" -ErrorAction SilentlyContinue

# 3. Is the target content server actually BranchCache-enabled?
#    (SMB file server — hash publication must be turned on for the SHARE, not just the service)
Get-SmbServerConfiguration | Select-Object EnableSMB2Protocol
Get-SmbShare | Select-Object Name, CachingMode

# 4. Are the two clients that should be sharing a cache on the SAME subnet? (Distributed mode only)
ipconfig | Select-String "IPv4 Address", "Subnet Mask"

# 5. Is content actually being served from cache, or silently falling back to the WAN every time?
netsh branchcache show status all | Select-String "Data Cache", "Service mode"
```

| If | Then |
|----|------|
| `netsh branchcache show status all` shows `Service mode = Local Caching is disabled` | BranchCache was never turned on for this client → **Fix 1** |
| Distributed mode, two clients on the same subnet still each pull from WAN every time | Discovery (WS-Discovery multicast) isn't reaching peers — firewall/network issue → **Fix 2** |
| Hosted mode, clients can't find/reach the hosted cache server | Client not pointed at the hosted cache server, or the server's listener/cert is broken → **Fix 3** |
| File share content never caches even though BranchCache is enabled everywhere | Hash publication was never turned on for that specific SMB share → **Fix 4** |
| Two machines on the same distributed-mode segment never share cached content, one is older | Client OS content-information version mismatch (V1 vs. V2) — they cannot share a cache | **Fix 5** |
| Content downloads via Delivery Optimization instead of BITS/WSUS-direct on a Windows 11 client | BranchCache does not accelerate Delivery-Optimization-sourced content on Windows 11 — this is expected, not a bug → **Fix 6** |
| `EnableSMB2Protocol`/share caching looks correct but Offline Files was disabled on this box | BranchCache SMB caching silently breaks without Offline Files running underneath it → **Fix 7** |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
BranchCache feature/role service installed
   - Content server (SMB): "BranchCache for Network Files" role service
   - Content server (Web/App): "BranchCache" feature + IIS or BITS
   - Client: BranchCache is built into Windows, just needs enabling
        │
BranchCache service enabled + mode configured (Distributed OR Hosted — one mode per branch office)
   Distributed: no extra config beyond enabling the client
   Hosted: client must be pointed at the hosted cache server (name + port)
        │
Hash publication turned on at the CONTENT SOURCE
   - SMB shares: CachingMode set to allow BranchCache hash generation (not just Offline Files caching)
   - Web/App servers: BranchCache feature installed + enabled on the IIS site / BITS app
        │
Firewall rules open for the transport actually in use
   Distributed mode: WS-Discovery (UDP 3702) + Peer Content Caching (TCP/UDP 443 by default)
   Hosted mode: HTTPS to the hosted cache server (TCP 443, cert-bound)
        │
[Distributed mode only] Client and peer on the SAME SUBNET
   (WS-Discovery is multicast — it does not cross subnet/router boundaries)
        │
Content information version compatibility (V1 vs. V2)
   Clients using different content-info versions in distributed mode CANNOT share a cache with each other
        │
[If SMB caching is in play] Offline Files (CSC) service must be running
   BranchCache SMB caching depends on the Offline Files stack underneath it — disabling
   Offline Files silently breaks BranchCache SMB caching, with no obvious error pointing at the cause
        │
Client requests content → gets hashes, not data, on a repeat request → pulls actual bytes from
local cache/peer/hosted server instead of the WAN-side content server
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm the local BranchCache service state and mode:**
```powershell
netsh branchcache show status all
```
Expected: `Service mode = Local Caching is enabled` (or `Distributed Caching` / `Hosted Caching`, depending on target mode). If it reports `Local Caching is disabled`, nothing downstream matters until this is turned on.

**2. Confirm which mode policy actually wants for this client, and that it matches:**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\BranchCache" -ErrorAction SilentlyContinue
```
A client stuck in Distributed mode when policy says Hosted (or vice versa) behaves as if BranchCache is broken — it's actually just in the wrong mode and never talking to the right peer/server.

**3. If Hosted mode, confirm the client is actually pointed at the right server:**
```powershell
netsh branchcache show status all | Select-String "Hosted Cache"
Test-NetConnection -ComputerName <hostedCacheServer> -Port 443
```
Expected: hosted cache server name populated, port 443 reachable. A blank hosted-cache-server field means the client-side GPO/policy setting was never applied.

**4. If Distributed mode, confirm both machines are on the same subnet:**
```powershell
ipconfig | Select-String "IPv4 Address", "Subnet Mask"
```
WS-Discovery is multicast-based and does not route across subnets. Two machines in the same "branch office" but on different VLANs will never see each other's cache in distributed mode — this is architectural, not a misconfiguration to chase.

**5. Confirm hash publication is actually enabled at the content source (SMB share):**
```powershell
Get-SmbShare | Select-Object Name, CachingMode
```
`CachingMode` needs to allow BranchCache (this is a **per-share** setting, separate from the BranchCache role service being installed on the server). A share with the role service installed but caching left at the default can silently never publish hashes.

**6. Confirm the firewall isn't blocking the transport actually in use:**
```powershell
Get-NetFirewallRule -DisplayGroup "BranchCache*" | Select-Object DisplayName, Enabled, Profile
```
Expected: `BranchCache - Content Retrieval (Uses HTTP)`, `BranchCache - Peer Discovery (Uses WSD)`, and (hosted mode only) `BranchCache - Hosted Cache Server (Uses HTTPS)` all enabled for the active profile.

**7. Confirm Offline Files is running if SMB BranchCache is involved:**
```powershell
Get-Service CscService | Select-Object Status, StartType
```
BranchCache's own documentation states explicitly: disabling Offline Files breaks BranchCache SMB caching. If this service is stopped/disabled, that's the root cause — not a BranchCache-specific bug.

---

## Common Fix Paths

<details><summary>Fix 1 — BranchCache never enabled on this client</summary>

**Symptom:** `netsh branchcache show status all` shows `Local Caching is disabled`.

```powershell
# Distributed mode
netsh branchcache set service mode=DISTRIBUTED

# OR Hosted mode, pointed at a specific server
netsh branchcache set service mode=HOSTEDCLIENT location=<hostedCacheServerFQDN>

# Confirm
netsh branchcache show status all
```

**In a managed environment, do this via GPO instead of per-machine `netsh`** so it survives a policy refresh:
`Computer Configuration → Administrative Templates → Network → BranchCache → Turn on BranchCache` (+ the corresponding "Set BranchCache Distributed Cache mode" or "Set BranchCache Hosted Cache mode" policy).

**Rollback:**
```powershell
netsh branchcache set service mode=DISABLED
```

</details>

<details><summary>Fix 2 — Distributed mode: peers never discover each other</summary>

**Symptom:** Two clients on the same subnet, both configured for distributed mode, never serve content to each other — every request goes back to the WAN.

```powershell
# Confirm the discovery/content-retrieval firewall rules are enabled for the active profile
Get-NetFirewallRule -DisplayGroup "BranchCache*" | Select-Object DisplayName, Enabled, Profile

# Re-enable if disabled
Enable-NetFirewallRule -DisplayGroup "BranchCache - Content Retrieval (Uses HTTP)"
Enable-NetFirewallRule -DisplayGroup "BranchCache - Peer Discovery (Uses WSD)"
```

If firewall rules are correct on both ends and this still fails, confirm they are genuinely on the same broadcast domain (**Diagnosis Step 4**) — WS-Discovery's multicast Probe/Probe-Match messages do not traverse routed subnet boundaries, and no firewall fix resolves a routing-layer mismatch.

**Rollback:** N/A (firewall rules only re-enabled, not created).

</details>

<details><summary>Fix 3 — Hosted mode: client can't reach or use the hosted cache server</summary>

**Symptom:** Hosted mode configured, but `netsh branchcache show status all` shows no successful hosted-cache activity, or `Test-WSMan`/`Test-NetConnection` to the hosted server fails.

```powershell
# On the CLIENT — confirm the configured hosted cache server name/port
netsh branchcache show status all | Select-String "Hosted Cache"

# Confirm reachability
Test-NetConnection -ComputerName <hostedCacheServer> -Port 443

# On the HOSTED CACHE SERVER — confirm the role is installed and the service is running
Get-WindowsFeature -Name BranchCache
Get-Service PeerDistSvc | Select-Object Status

# Confirm the HTTPS certificate is bound correctly (required for Windows Server 2008 R2 hosted
# cache servers; NOT required for Windows Server 2012+ hosted cache servers)
netsh http show sslcert
```

If the client-side hosted-cache-server value is blank or wrong, fix the GPO ("Set BranchCache Hosted Cache mode") rather than the individual client — a per-machine `netsh` fix will drift back out on the next policy refresh.

**Rollback:**
```powershell
netsh branchcache set service mode=DISTRIBUTED
```

</details>

<details><summary>Fix 4 — SMB share content never caches (hash publication off)</summary>

**Symptom:** BranchCache is enabled and healthy on both client and server, firewall is clean, but content from a specific file share is never served from cache.

```powershell
# Check current caching mode on the share
Get-SmbShare -Name <ShareName> | Select-Object Name, CachingMode

# Enable BranchCache hash publication for the share
Set-SmbShare -Name <ShareName> -CachingMode BranchCache -Force

# Confirm the "BranchCache for Network Files" role service is actually installed on the server
Get-WindowsFeature -Name FS-BranchCache
```

This is the single most common "BranchCache is on everywhere but nothing caches" root cause — the role service being installed does not automatically turn on hash generation for existing shares.

**Rollback:**
```powershell
Set-SmbShare -Name <ShareName> -CachingMode Manual -Force
```

</details>

<details><summary>Fix 5 — Content-information version mismatch blocks peer sharing (distributed mode)</summary>

**Symptom:** A newer client (Windows 10/11, Server 2012+) and an older client (Windows 7, Server 2008 R2) on the same subnet in distributed mode never share cached content with each other, even though both show BranchCache enabled and healthy individually.

This is not a bug to fix with a setting — V1 (older) and V2 (newer) content-information formats are **not cross-compatible** in distributed cache mode. Each version segment/hash structure is different, so a V2 client's cache is invisible to a V1 client and vice versa.

**Options, in order of preference:**
1. Confirm this is actually acceptable — most environments have aged out V1-only clients; if so, no fix needed, this is expected behavior.
2. If the older client's traffic volume matters, move that branch office to **hosted cache mode** — the hosted cache server negotiates the correct content-information version per requesting client, working around the distributed-mode incompatibility.
3. Upgrade the older client OS if in scope.

**Rollback:** N/A — this is architectural, not a configuration to revert.

</details>

<details><summary>Fix 6 — Windows 11 client, Windows Update/Delivery Optimization traffic isn't cached</summary>

**Symptom:** BranchCache is fully configured and working for file shares, but Windows Update content on Windows 11 clients never appears to use BranchCache.

**This is expected, not a fault.** Microsoft's own guidance states BranchCache is not supported for content downloaded using Delivery Optimization, and Windows 11's Update Agent uses Delivery Optimization by default even against WSUS. On Windows 10 (1607+) the workaround was to set Delivery Optimization Download Mode to `100` (Bypass) so BITS/BranchCache could be used instead — that Bypass mode is **deprecated on Windows 11**, so it is not a durable fix there.

**Practical path for Windows 11 fleets:** rely on Delivery Optimization's own peer-to-peer caching (Group/Intranet download mode) for update traffic instead of trying to force BranchCache — see `Troubleshooting/DeliveryOptimization-B.md` for that configuration. Keep BranchCache scoped to SMB file shares and Web/App-server content where it's still fully supported.

**Rollback:** N/A — configuration guidance, not a change to revert.

</details>

<details><summary>Fix 7 — SMB caching breaks after Offline Files was disabled</summary>

**Symptom:** BranchCache SMB caching stops working after a security baseline or GPO change disabled Offline Files fleet-wide.

```powershell
Get-Service CscService | Select-Object Status, StartType

# Re-enable if this box needs BranchCache SMB caching
Set-Service CscService -StartupType Automatic
Start-Service CscService
```

If Offline Files was disabled deliberately (e.g., a Work Folders migration — see `Troubleshooting/FolderRedirection-A.md`), that decision needs to be reconciled with BranchCache's dependency on it before re-enabling BranchCache SMB caching on those clients — the two features cannot be decoupled for SMB content.

**Rollback:**
```powershell
Set-Service CscService -StartupType Disabled
Stop-Service CscService
```

</details>

---

## Escalation Evidence

```
=== BranchCache Failure — Ticket Evidence ===

Date/Time:                   _______________
Client machine:              _______________
Content server / share:      _______________
Deployment mode:             _______________  (Distributed / Hosted)
Content type:                _______________  (SMB file share / Web-HTTP / BITS-App)

--- Commands Run ---
netsh branchcache show status all (client):        Service mode = _______________
Get-SmbShare CachingMode (server, if SMB):          _______________
Get-NetFirewallRule BranchCache* Enabled:           _______________
[Distributed] Same subnet as peer confirmed (Y/N):  _______________
[Hosted] Hosted cache server reachable on 443 (Y/N):_______________
CscService (Offline Files) status:                  _______________

--- Scenario ---
[ ] Never worked (new deployment)
[ ] Worked before, broke after a policy/GPO change
[ ] Works for some content but not a specific share
[ ] Cross-OS-version peers not sharing cache (V1/V2 mismatch)
[ ] Windows 11 Update/Delivery Optimization traffic specifically

--- Steps Taken ---
[ ] Verified BranchCache service mode matches policy intent
[ ] Verified share-level hash publication (SMB scenarios)
[ ] Verified firewall rules for the active transport
[ ] Verified subnet match (distributed mode) or hosted server reachability (hosted mode)
[ ] Verified Offline Files (CscService) is running
```

---

## 🎓 Learning Pointers

- **Distributed cache mode is single-subnet only — this is a protocol limitation, not a bug.** WS-Discovery's multicast Probe/Probe-Match exchange does not cross routed subnet boundaries. A multi-subnet branch office needs hosted cache mode (or one distributed-mode "island" per subnet, which loses cross-subnet sharing entirely) — don't spend time debugging firewall rules for a topology problem. [MS Docs: BranchCache overview](https://learn.microsoft.com/en-us/windows-server/networking/branchcache/branchcache)

- **Hash publication is a per-share setting, independent of the server role being installed.** `FS-BranchCache` being installed does not retroactively enable caching on existing SMB shares — each share's `CachingMode` needs to be set explicitly. This is the most common "everything looks right but nothing caches" root cause.

- **BranchCache SMB caching has a hard, easy-to-miss dependency on Offline Files.** Microsoft's own documentation calls this out directly: disabling Offline Files breaks BranchCache SMB caching. If a security baseline disables Offline Files fleet-wide for unrelated reasons, BranchCache silently stops working for file shares with no error pointing back at the actual cause.

- **Content-information version (V1 vs. V2) determines cache compatibility between peers in distributed mode, and there is no override.** A Windows 7 client and a Windows 11 client on the same subnet, both correctly configured, simply cannot share a cache — hosted cache mode is the only way to bridge mixed-OS-version branch offices, since the hosted server negotiates the right version per client.

- **BranchCache does not accelerate Delivery-Optimization-sourced content on Windows 11.** Windows 11's Update Agent defaults to Delivery Optimization, and the Windows 10-era Bypass workaround (Download Mode `100`) is deprecated on Windows 11. Don't chase this as a BranchCache misconfiguration — use Delivery Optimization's own peer-caching modes for update traffic instead. [MS Docs: Configure BranchCache for Windows client updates](https://learn.microsoft.com/en-us/windows/deployment/update/waas-branchcache)

- **A server secret, not per-client credentials, is what makes cached content tamper-evident.** BranchCache's security model doesn't change how ACLs or authentication work at all — a client still has to authenticate and be authorized by the real content server before it ever gets the content information needed to pull from a peer or hosted cache. If content is unexpectedly accessible, that's a share-permission problem, not a BranchCache one.
