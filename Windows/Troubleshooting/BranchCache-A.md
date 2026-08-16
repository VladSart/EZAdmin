# BranchCache — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why WAN caching succeeds or fails at each layer, not just what to type.

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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- BranchCache distributed cache mode and hosted cache mode architecture, and when each applies
- BranchCache-enabled content servers: SMB file servers, Web servers (IIS), BITS/application servers (WSUS)
- Content information versioning (V1 vs. V2) and cross-version cache-sharing limitations
- The BranchCache-Offline-Files dependency for SMB caching
- Windows Update/WSUS/Configuration Manager integration, including the Windows 11 Delivery Optimization interaction
- Firewall/transport requirements for both modes

**Out of scope:**
- Delivery Optimization's own peer-to-peer distribution architecture — a parallel, separate technology; see `Troubleshooting/DeliveryOptimization-A.md`
- Configuration Manager Branch Distribution Point deep internals — covered only as a BranchCache content-server type, not a full ConfigMgr topic
- Offline Files / Client-Side Caching (CSC) internals beyond the specific dependency BranchCache has on the service — see `Troubleshooting/FolderRedirection-A.md` for the full Offline Files architecture
- Azure File Sync caching (a different, cloud-tiering-based technology despite similar goals)

**Assumptions:**
- Windows Server 2012 R2 through Server 2025 for content/hosted-cache servers; Windows 8.1 through Windows 11 for clients (BranchCache is not part of Windows 11 Home/Pro-without-BranchCache-support — Enterprise/Education/Pro-with-BITS-only editions apply, matching the same edition matrix as prior Windows versions)
- Reader has local admin on the machines being troubleshot and appropriate rights to edit GPOs if a policy-level fix is needed
- PowerShell 5.1 baseline; `netsh branchcache` is used throughout since it remains the primary supported interface (no full PowerShell module replaces it)

---

## How It Works

<details><summary>Full architecture</summary>

### What BranchCache Actually Does

BranchCache is a WAN bandwidth-optimization technology: instead of every client in a branch office independently pulling the same file or web content across the WAN link from a main-office (or cloud) content server, the first client to request it caches the content locally in the branch — either spread across client machines (**distributed cache mode**) or centralized on a branch-office server (**hosted cache mode**). Subsequent requests for the same content are served from the local branch cache instead of crossing the WAN again.

```
Main Office / Cloud                          Branch Office
┌─────────────────────┐                      ┌──────────────────────────────┐
│ Content Server        │                      │  Client A ──┐                │
│ (SMB / Web / BITS)     │◀──── WAN link ─────▶│  Client B ──┼─ cache lookup   │
└─────────────────────┘   (only on cache miss) │  Client C ──┘  (peer or       │
                                                │               hosted server) │
                                                └──────────────────────────────┘
```

Critically, BranchCache does **not** change authentication or authorization. A client still authenticates to and is authorized by the real content server before it ever receives the content information (hashes) needed to locate and validate a cached copy. BranchCache is a caching layer bolted underneath the existing security model, not a replacement for it.

### The Two Modes

**Distributed cache mode** — the cache is spread across the client computers in the branch that have already requested the content. No extra branch-office hardware is required. Peer discovery uses **WS-Discovery**, a multicast-based protocol: a client looking for content sends a multicast Probe message containing a Segment ID, and any peer holding matching content replies with a unicast Probe-Match. Because this is multicast, **distributed mode operates on a single subnet only** — a multi-subnet branch office running distributed mode has effectively separate, non-sharing caches per subnet, since Probe messages don't cross routed boundaries.

**Hosted cache mode** — the cache is centralized on one or more dedicated servers (hosted cache servers) in the branch. Clients upload content they've fetched to the hosted cache server (the "offer" process) and query it directly rather than using multicast discovery. This solves the multi-subnet limitation (every client in the branch, regardless of subnet, can reach the same hosted cache server over standard routed IP) and increases cache availability (content stays available even if the client that originally cached it goes offline). **Only one mode can be active per branch office** — you can mix modes across different branch offices, but not within one.

### Content Information and the Security Model

When a client requests content from a BranchCache-enabled server, on the *first* request it gets the actual content, plus **content information** — a set of cryptographic hashes (SHA-256) computed by dividing the content into segments and blocks. On subsequent requests (from the same or a different client in the branch), the client instead requests content information from the server, then uses it to locate and validate a cached copy locally rather than pulling the full content again:

```
Client → requests content → Content Server verifies auth/ACL (unchanged from normal access)
                                    │
                          Server generates content information:
                          Block Hash List → Hash of Data (HoD) → Segment Secret
                          (keyed by a per-server "server secret" so clients can't forge hashes)
                                    │
Client uses HoD + Segment Secret to derive a Segment ID → locates matching content in the
local branch cache (peer discovery in distributed mode, or a direct hosted-cache-server query)
                                    │
If found locally: content is retrieved from the peer/hosted cache, decrypted client-side,
and validated against the block hashes before being trusted
                                    │
If NOT found locally: client falls back to pulling the actual content over the WAN,
then adds it to the local cache (client cache in distributed mode, or offered up to the
hosted cache server) for the next requester
```

The **server secret** is what prevents a malicious client from generating valid-looking content information itself — without it, an attacker with access to an old version of a file couldn't brute-force guess what a newer version's hashes would be. All content servers in a deployment sharing a cache pool need the same server secret configured.

### Content Information Versions (V1 vs. V2) — and Why Mixed Fleets Don't Share

There are two incompatible content-information formats:

| Version | Used by | Segment structure |
|---|---|---|
| V1 | Windows 7 / Server 2008 R2 (and any endpoint of that generation) | Larger, **fixed-size** segments. A single byte inserted early in a file invalidates every segment from that point to the end of the file — a small edit can force re-download of the rest of the file. |
| V2 | Windows 8+/Server 2012+ through current Windows 10/11/Server 2025 | Smaller, **variable-size** segments (content-defined chunking), tolerant of insertions/edits — only the actually-changed region typically needs re-fetching. |

**In distributed cache mode, clients using different content-information versions cannot share cached content with each other at all** — a V1 client's cache is structurally invisible to a V2 client's discovery process, and vice versa. This is architectural, not a settings problem. **Hosted cache mode does not have this limitation** for the *serving* side — the hosted cache server negotiates and serves the correct version to each requesting client — making it the practical fix for a branch office with a mixed-generation client fleet that still needs full cache sharing.

### The Offline Files Dependency (SMB Caching)

BranchCache's SMB caching path is built on top of the same client-side caching (CSC) infrastructure used by Offline Files (see `Troubleshooting/FolderRedirection-A.md`). Microsoft's own guidance states this dependency explicitly: **if Offline Files is disabled, BranchCache SMB caching does not function correctly** — and there is no separate error message pointing at Offline Files as the cause. A security baseline or GPO change that disables Offline Files for unrelated reasons (e.g., moving to Work Folders, or a policy that blanket-disables CSC for data-loss-prevention reasons) will silently break BranchCache for file shares as a side effect.

### Content Update Handling

When a branch-office user edits a cached document, the change is written directly back to the content server over the WAN — BranchCache has no role in the write path at all, only reads. The next time a *different* client in the branch requests the updated file, only the changed segments are fetched fresh from the content server (more efficiently under V2's variable-segment model than V1's fixed-segment one) and merged into the branch cache. This guarantees branch users always see the current version — BranchCache cannot serve a stale cached copy once the source has changed, because the content information (hashes) for the new version won't match what's cached.

### Windows 11 and Delivery Optimization

Windows 10 (1607+) introduced Delivery Optimization as the default download agent for Windows Update content, even when sourced from WSUS — but a Download Mode of `100` (Bypass) let administrators force BITS to be used instead so BranchCache could accelerate update traffic. **This Bypass mode is deprecated in Windows 11, and BranchCache is explicitly not supported for content downloaded via Delivery Optimization on Windows 11.** In practice this means BranchCache's practical scope on Windows 11 fleets narrows to SMB file shares and Web/BITS-application-server content — Windows Update/feature-update traffic should be handled through Delivery Optimization's own peer-caching configuration instead (`Troubleshooting/DeliveryOptimization-A.md`).

</details>

---

## Dependency Stack

```
BranchCache role/feature installed
   Content server (SMB): "BranchCache for Network Files" role service
   Content server (Web/App): "BranchCache" feature + IIS site or BITS-based app (e.g. WSUS)
   Hosted cache server: "BranchCache" feature with hosted cache mode enabled
   Client: built into the OS, no install needed — just enable + configure mode
        │
BranchCache service mode configured and matches deployment intent
   (Distributed OR Hosted — exactly one per branch office; GPO-managed in production, not local netsh)
        │
Hash publication / caching enabled at the CONTENT SOURCE
   SMB shares: CachingMode set to allow BranchCache generation (separate from the role service)
   Web/App servers: BranchCache feature enabled on the specific site/app, not just installed
        │
Firewall rules open for the transport in active use
   Distributed: WS-Discovery (UDP 3702 multicast) + Peer Content Caching (HTTP, port 443 by default)
   Hosted: HTTPS to the hosted cache server (TCP 443, certificate-bound on Server 2008 R2 hosted
   servers only — not required on Server 2012+ hosted cache servers)
        │
[Distributed mode ONLY] Same subnet as the peer — WS-Discovery multicast does not route
        │
Content information version compatibility (V1 vs. V2)
   Distributed mode: mismatched versions CANNOT share a cache with each other at all
   Hosted mode: server negotiates the correct version per client — no mismatch limitation
        │
[SMB scenarios only] Offline Files (CscService) running — a hard, undocumented-at-error-time
dependency for BranchCache's SMB caching path
        │
[Windows 11 clients, Windows Update traffic] Delivery Optimization NOT the active download
path — BranchCache does not accelerate DO-sourced content on Windows 11
        │
Client request → content information exchange → local cache lookup → peer/hosted-cache
retrieval on hit, WAN fallback + cache population on miss
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `netsh branchcache show status all` shows caching disabled | BranchCache never enabled on this client | `netsh branchcache set service mode=DISTRIBUTED` (or HOSTEDCLIENT) |
| Everything looks enabled, but a specific file share never caches | Hash publication (`CachingMode`) not set on that share | `Get-SmbShare -Name <Share> \| Select CachingMode` |
| Two clients on the same subnet, distributed mode, never share cache | Firewall blocking WS-Discovery/Peer Content Retrieval | `Get-NetFirewallRule -DisplayGroup "BranchCache*"` |
| Two clients "in the same branch" never share cache, firewall confirmed clean | Actually on different subnets — WS-Discovery multicast doesn't route | Compare subnet masks/IPv4 addresses on both machines |
| Older (Win7/2008R2) and newer client never share cache in distributed mode | Content-information V1/V2 incompatibility — architectural, not fixable in distributed mode | Confirm OS versions; consider hosted cache mode for that branch |
| Hosted mode configured, client never populates from/to the hosted server | Client not pointed at the server, or server-side service/cert broken | `netsh branchcache show status all` (client) + `Get-Service PeerDistSvc` (server) |
| BranchCache SMB caching stops working after an unrelated GPO/security change | Offline Files (`CscService`) was disabled — hard undocumented dependency | `Get-Service CscService` |
| Windows 11 clients, Windows Update content never cached by BranchCache | Expected — BranchCache doesn't accelerate Delivery-Optimization-sourced content on Win11 | Confirm via Delivery Optimization status instead; not a BranchCache defect |
| Cache appears to fill up and stop accepting new content | Client-side cache size limit reached (percentage of local disk, policy-configurable) | `netsh branchcache show status all` (Local Cache section, size/limit) |
| Content served from cache is stale relative to a very recent edit | Expected transient state — next request after the edit lands fetches fresh segments; not stale beyond one write-then-first-read cycle | Re-request after confirming the write completed on the source |

---

## Validation Steps

**1. Confirm BranchCache is enabled and in the intended mode:**
```powershell
netsh branchcache show status all
```
Expected: `Service mode = Local Caching is enabled` with the appropriate Distributed/Hosted designation. Compare against the GPO-intended mode, not assumption.

**2. Confirm hash publication at the content source (SMB scenario):**
```powershell
Get-SmbShare | Select-Object Name, CachingMode
```
Expected: `CachingMode` reflects `BranchCache` (or `Documents`/`Programs` presets that include BranchCache) for shares that should be cached.

**3. Confirm the BranchCache role/feature is actually installed on the server side:**
```powershell
Get-WindowsFeature -Name FS-BranchCache, BranchCache
```
Expected: `Installed` for whichever role applies to that server's function (SMB file server vs. Web/App/hosted-cache).

**4. Confirm firewall rules for the transport in use:**
```powershell
Get-NetFirewallRule -DisplayGroup "BranchCache*" | Select-Object DisplayName, Enabled, Profile
```
Expected: all relevant rules `Enabled = True` for the active network profile.

**5. [Distributed mode] Confirm subnet alignment between peers:**
```powershell
ipconfig | Select-String "IPv4 Address", "Subnet Mask"
```
Compare the network portion of the address on both machines — they must match for WS-Discovery multicast to reach both.

**6. [Hosted mode] Confirm client-to-server reachability and server health:**
```powershell
# Client
Test-NetConnection -ComputerName <hostedCacheServer> -Port 443

# Server
Get-Service PeerDistSvc | Select-Object Status
netsh http show sslcert
```

**7. Confirm the Offline Files dependency (SMB scenarios):**
```powershell
Get-Service CscService | Select-Object Status, StartType
```
Expected: `Running`/`Automatic`. If not, BranchCache SMB caching will not function correctly regardless of every other setting being right.

**8. Confirm content-information version isn't a factor for a mixed-OS distributed-mode complaint:**
```powershell
(Get-CimInstance Win32_OperatingSystem).Caption
```
Run on both peers being compared; a Windows 7/Server 2008 R2 result alongside a Windows 8+/Server 2012+ result in distributed mode explains non-sharing without any further troubleshooting needed.

---

## Troubleshooting Steps (by phase)

### Phase 1: BranchCache Not Enabled / Wrong Mode

1. `netsh branchcache show status all` — confirm current state.
2. Compare against GPO policy intent (`Computer Configuration → Administrative Templates → Network → BranchCache`).
3. If mismatched, fix the GPO for a fleet-wide issue; use `netsh branchcache set service mode=...` only for a single-machine test/exception.

### Phase 2: Content Never Caches (Source-Side)

1. Confirm the correct role/feature is installed for the content-server type (SMB vs. Web/App).
2. For SMB: confirm per-share `CachingMode` — this is the most frequently missed step.
3. For Web/App: confirm the BranchCache feature is enabled at the site/app level, not just installed at the OS level.

### Phase 3: Peers/Hosted Server Never Connect (Transport-Side)

1. Confirm firewall rules for the active mode's transport.
2. Distributed mode: confirm same-subnet alignment; this rules out an entire class of "it should work but doesn't" tickets immediately.
3. Hosted mode: confirm client-side hosted-server pointer and server-side service/certificate health.

### Phase 4: Partial Failure (Some Content Caches, Some Doesn't)

1. Isolate to a specific share/site vs. a systemic issue — test a known-good share/site alongside the failing one.
2. If systemic: revisit Phases 1–3.
3. If isolated to one share/site: revisit its specific `CachingMode`/feature-enablement setting.
4. If isolated to a specific OS-version pairing in distributed mode: this is the V1/V2 content-information limitation, not a fixable fault — consider hosted mode.

### Phase 5: SMB Caching Broke After an Unrelated Change

1. Check `CscService` (Offline Files) state first — this is the highest-probability cause when SMB BranchCache regresses without any BranchCache-specific change being made.
2. Trace the change that disabled it (GPO history, recent security baseline deployment) and reconcile the two requirements rather than silently re-enabling Offline Files without documenting why it was disabled in the first place.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Deploy BranchCache distributed mode via GPO (small branch, no local server)</summary>

```
Computer Configuration → Administrative Templates → Network → BranchCache
  → Turn on BranchCache: Enabled
  → Set BranchCache Distributed Cache mode: Enabled
  → Configure client BranchCache Package Version Support: (leave default unless a
    specific old-client scenario requires forcing a version)
```

On the content server (SMB file server):
```powershell
Install-WindowsFeature FS-BranchCache
Set-SmbShare -Name <ShareName> -CachingMode BranchCache -Force
```

**Verify:**
```powershell
netsh branchcache show status all
Get-SmbShare -Name <ShareName> | Select-Object CachingMode
```

**Rollback:** set the "Turn on BranchCache" GPO setting to Disabled and run `gpupdate /force` on affected clients; `Set-SmbShare -CachingMode Manual` on the server.

</details>

<details><summary>Playbook 2 — Deploy BranchCache hosted mode (branch office with a local server)</summary>

```
Computer Configuration → Administrative Templates → Network → BranchCache
  → Turn on BranchCache: Enabled
  → Set BranchCache Hosted Cache mode: Enabled, Hosted Cache Server = <FQDN>
  → (Client-side) Configure Hosted Cache Servers: <FQDN> (Server 2012+ supports multiple)
```

On the hosted cache server:
```powershell
Install-WindowsFeature BranchCache
netsh branchcache set service mode=HOSTEDSERVER

# Server 2008 R2 hosted cache servers ONLY — bind a certificate; Server 2012+ does not need this
netsh http add sslcert ipport=0.0.0.0:443 certhash=<thumbprint> appid="{d673f5ee-a3b2-4d02-9d67-00e60d7e2b74}"
```

**Verify:**
```powershell
Get-Service PeerDistSvc
netsh branchcache show status all   # run on a client after gpupdate
```

**Rollback:** set "Set BranchCache Hosted Cache mode" to Disabled (or switch to Distributed), `gpupdate /force`; `netsh branchcache set service mode=DISABLED` on the server if fully decommissioning.

</details>

<details><summary>Playbook 3 — Reconcile BranchCache SMB caching with an Offline-Files-disabling security baseline</summary>

Use when a security/DLP baseline needs Offline Files disabled fleet-wide, but specific branch-office machines still need BranchCache SMB caching.

```powershell
# Create a targeted GPO (or WMI-filtered/OU-scoped exception) that re-enables Offline Files
# ONLY for the machines that need BranchCache SMB caching, rather than reverting the baseline globally
Set-Service CscService -StartupType Automatic
Start-Service CscService
```
Document the exception explicitly (which OU/machines, why, and who approved carving them out of the baseline) since this is a deliberate, scoped deviation from a security control, not a default state.

**Rollback:**
```powershell
Set-Service CscService -StartupType Disabled
Stop-Service CscService
```

</details>

<details><summary>Playbook 4 — Bridge a mixed-OS-generation branch office via hosted cache mode</summary>

Use when distributed mode's V1/V2 content-information incompatibility is blocking cache sharing between an older and newer client population that can't be upgraded together.

```
Computer Configuration → Administrative Templates → Network → BranchCache
  → Set BranchCache Distributed Cache mode: Disabled
  → Set BranchCache Hosted Cache mode: Enabled, Hosted Cache Server = <FQDN>
```
Stand up the hosted cache server per Playbook 2. The hosted server negotiates the correct content-information version per requesting client, so both the V1 (older) and V2 (newer) populations get full cache-sharing benefit through the single hosted cache, something distributed mode cannot provide across that OS-version boundary.

**Rollback:** revert to distributed mode per Playbook 1's GPO settings; understand that this reintroduces the V1/V2 non-sharing limitation for that branch.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect BranchCache evidence for escalation
.NOTES     Run as admin. Run once on the CLIENT and, if the issue may be server-side,
           a second pass on the content server / hosted cache server.
#>

$OutputDir = "C:\Temp\BranchCache-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. BranchCache service state and mode
netsh branchcache show status all | Out-File "$OutputDir\BranchCache-Status.txt"

# 2. GPO-intended configuration (registry-based policy read)
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\BranchCache" -ErrorAction SilentlyContinue |
    Out-File "$OutputDir\BranchCache-GPOPolicy.txt"

# 3. Firewall rules
Get-NetFirewallRule -DisplayGroup "BranchCache*" | Select-Object DisplayName, Enabled, Profile, Direction |
    Export-Csv "$OutputDir\BranchCache-Firewall.csv" -NoTypeInformation

# 4. SMB share caching modes (if this is a file-server issue)
Get-SmbShare | Select-Object Name, CachingMode, Path |
    Export-Csv "$OutputDir\SMBShare-CachingMode.csv" -NoTypeInformation

# 5. Offline Files (CscService) dependency state
Get-Service CscService | Select-Object Status, StartType |
    Export-Csv "$OutputDir\CscService-State.csv" -NoTypeInformation

# 6. Network profile / subnet info (for distributed-mode subnet-alignment checks)
Get-NetIPConfiguration | Select-Object InterfaceAlias, IPv4Address, IPv4DefaultGateway |
    Export-Csv "$OutputDir\NetworkConfig.csv" -NoTypeInformation

# 7. OS version (for content-information V1/V2 comparison across peers)
(Get-CimInstance Win32_OperatingSystem) | Select-Object Caption, Version, BuildNumber |
    Export-Csv "$OutputDir\OSVersion.csv" -NoTypeInformation

# 8. Installed BranchCache-related roles/features
Get-WindowsFeature -Name *BranchCache* -ErrorAction SilentlyContinue |
    Export-Csv "$OutputDir\BranchCacheFeatures.csv" -NoTypeInformation

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Status and mode
netsh branchcache show status all
netsh branchcache set service mode=DISTRIBUTED
netsh branchcache set service mode=HOSTEDCLIENT location=<hostedCacheServerFQDN>
netsh branchcache set service mode=HOSTEDSERVER
netsh branchcache set service mode=DISABLED

# Reset the local cache (client-side troubleshooting)
netsh branchcache flush

# SMB share caching
Get-SmbShare | Select-Object Name, CachingMode
Set-SmbShare -Name <ShareName> -CachingMode BranchCache -Force

# Roles/features
Get-WindowsFeature -Name FS-BranchCache, BranchCache
Install-WindowsFeature FS-BranchCache
Install-WindowsFeature BranchCache

# Firewall
Get-NetFirewallRule -DisplayGroup "BranchCache*"
Enable-NetFirewallRule -DisplayGroup "BranchCache - Content Retrieval (Uses HTTP)"
Enable-NetFirewallRule -DisplayGroup "BranchCache - Peer Discovery (Uses WSD)"

# Hosted cache server health
Get-Service PeerDistSvc
netsh http show sslcert

# Offline Files dependency (SMB caching)
Get-Service CscService
Set-Service CscService -StartupType Automatic; Start-Service CscService

# Subnet check (distributed mode)
ipconfig | Select-String "IPv4 Address", "Subnet Mask"

# OS version (content-info V1/V2 check)
(Get-CimInstance Win32_OperatingSystem).Caption
```

---

## 🎓 Learning Pointers

- **BranchCache is a caching layer, not an authentication or authorization change.** Every content retrieval still goes through the source server's normal auth/ACL check on first access; caching only affects where subsequent bytes physically come from. If a permissions problem shows up "through BranchCache," the fix is in the source ACL, not in BranchCache configuration. [MS Docs: BranchCache overview](https://learn.microsoft.com/en-us/windows-server/networking/branchcache/branchcache)

- **Distributed cache mode's single-subnet limitation is a WS-Discovery protocol property, not a configurable setting.** Multicast Probe/Probe-Match messages don't route. Recognizing this early turns a multi-hour "why won't these two machines share a cache" investigation into a two-command subnet comparison.

- **Content-information version (V1/V2) incompatibility in distributed mode is the least obvious limitation in this whole feature** — two fully, correctly configured clients simply cannot share content if one is old enough to use V1 and the other uses V2. Hosted cache mode is the only real bridge across that boundary, since the server (not a peer) negotiates the version per requester.

- **BranchCache's dependency on Offline Files for SMB caching is easy to lose track of** because it produces no BranchCache-specific error — content just silently stops caching. Any time SMB BranchCache regresses after an unrelated policy or security-baseline change, check `CscService` before anything BranchCache-specific.

- **Windows 11's shift to Delivery Optimization as the default Windows Update download path, combined with the deprecation of the Bypass workaround, effectively narrows BranchCache's real-world footprint to file shares and Web/BITS-application content on modern client fleets.** Don't try to force update traffic through BranchCache on Windows 11 — use Delivery Optimization's own peer-caching modes instead. [MS Docs: Configure BranchCache for Windows client updates](https://learn.microsoft.com/en-us/windows/deployment/update/waas-branchcache)

- **Hash publication is per-share, not per-server.** Installing the BranchCache for Network Files role service is a prerequisite, not a sufficient condition — every share that should be cached needs its own `CachingMode` set explicitly. Auditing this across a fleet of file servers is the single highest-value BranchCache health check to automate.
