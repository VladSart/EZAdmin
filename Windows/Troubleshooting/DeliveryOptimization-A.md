# Windows Delivery Optimization — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

Covers Windows Delivery Optimization (DO) — the built-in peer-to-peer content distribution mechanism for Windows Update, Microsoft Store apps, and (in managed environments) Intune Win32 apps and Autopatch content. Assumes Windows 10/11 devices managed via Intune and/or GPO, and that Windows Update for Business (WUfB) or WSUS governs *what* gets deployed while DO governs *how the bytes get there efficiently*. This runbook does not cover WUfB deployment ring configuration itself — see `Intune/Troubleshooting/WUfB-A.md` for that.

Out of scope: BranchCache (the older, largely superseded Windows Server-based caching technology) — most modern Intune-managed fleets should use DO + Microsoft Connected Cache instead, and BranchCache is only relevant to legacy on-prem WSUS/SCCM topologies.

---

## How It Works

<details><summary>Full architecture</summary>

Delivery Optimization runs as the `DoSvc` service and intercepts eligible downloads (Windows Update payloads, Store apps, Intune Win32/LOB app content, some Office updates) before they hit the network stack, checking first whether the content is available from a local peer or cache server.

**Content sourcing priority (roughly, in order attempted):**
1. Local DO cache (already downloaded previously on this device)
2. Local network peers (LAN or Group mode, depending on config)
3. Microsoft Connected Cache server (if configured and reachable)
4. Microsoft CDN / Windows Update servers directly over the internet (HTTP fallback, always available regardless of DO mode)

**Download Mode** (`DODownloadMode`) is the master switch controlling which of the peer sources above are eligible:
- `0` — HTTP Only: no peering, direct download only. Effectively "DO disabled" from a bandwidth-saving perspective, though the service can still run.
- `1` — LAN: peer with devices on the exact same NAT/subnet (uses local network multicast/broadcast discovery). Simplest, zero-config option for single-subnet sites.
- `2` — Group: peer with devices sharing the same Group ID, which can span multiple subnets/VLANs at a site or even across sites if intentionally configured the same. Requires `DOGroupIdSource` (how the Group ID is derived — AD Site, Domain, AAD Tenant, or a manually-set GUID) to be consistent across the intended peer set.
- `3` — Internet: peer with any device on the internet running DO with compatible content, brokered by Microsoft. Rarely appropriate for managed enterprise fleets — it means client devices are acting as P2P nodes for potentially unrelated external clients.
- `99`/`100` — Simple/Bypass: minimal DO functionality, effectively pass-through HTTP (used in some constrained/kiosk scenarios).

**Peering mechanics:** the first device at a site to need a given content package (identified by a Content ID, not just filename) downloads it from CDN/cache server normally, storing it in the local DO cache. Subsequent devices querying for the same Content ID discover the first device as a peer (via local broadcast in LAN mode, or via the Group coordination mechanism in Group mode) and pull chunks from it directly over the local network, port 7680 (both TCP and UDP used depending on transfer phase). This is fundamentally why DO provides zero benefit for the very first download of any given content at a site — there's no peer yet.

**Cache management:** each device's local DO cache is disk-backed and size-limited via `DOMaxCacheSize` (percentage of disk) or `DOAbsoluteMaxCacheSize` (fixed GB). Content ages out of cache based on size pressure and default retention policy — devices are not indefinite content repositories, so peering benefit is time-bounded to how long content stays cached after a deployment wave.

**Microsoft Connected Cache (MCC):** a free, separately-deployed caching layer (available as a Windows Server role, an Azure IoT Edge module, or in Enterprise as "MCCE") that acts as a *always-available* local seed, independent of any single client device's cache lifecycle or availability. Configured via `DOCacheHost`/`DOCacheHostSource` policy pointing clients at the MCC endpoint. This is what actually reduces WAN utilization for the *first* download at a site — peering alone cannot, structurally, help with that case.

</details>

---

## Dependency Stack

```
Content source layer
  ├── Microsoft CDN / Windows Update servers (always-available fallback, internet-facing)
  ├── Microsoft Connected Cache server (optional, on-prem or Azure IoT Edge — helps FIRST download)
  └── Local peer devices (help SECOND+ download only, via LAN/Group mode)

Delivery Optimization client (DoSvc)
  │
  ├── DODownloadMode (governs which sources above are eligible)
  ├── DOGroupIdSource + DOGroupId (Group mode peer-set definition)
  ├── DOCacheHost (Connected Cache endpoint, if deployed)
  ├── DOMaxCacheSize / DOAbsoluteMaxCacheSize (local cache disk budget)
  ├── DOMinBackgroundQoS / DOPercentageMaxForegroundBandwidth (bandwidth throttling policies)
  └── Local firewall / network path
        └── Port 7680 TCP+UDP open between intended peers (LAN/Group mode)
              └── [Group mode across subnets] Router/switch ACLs permitting the traffic between VLANs

Content consumers riding on top of DO
  ├── Windows Update / Windows Update for Business
  ├── Microsoft Store (including Store-delivered app updates)
  ├── Intune Win32 app / LOB app content
  └── Windows Autopatch update rings
```

**Key interlock:** DODownloadMode, DOGroupId, and DOCacheHost are independently configurable — a fleet can be set to Group mode with a correct Group ID but still see zero WAN savings on the first deployment wave at a new site if no Connected Cache is present, and troubleshooting will show "peering is working correctly" while the original complaint (WAN saturation on patch day) persists. Diagnose which layer the complaint actually targets before changing settings.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Zero peer traffic (`BytesFromPeers` = 0) across ALL devices at a site | Mode set to 0/HTTP-only, or firewall blocking port 7680 | `DODownloadMode` value, port reachability test |
| Peering works within a subnet but not across the site's other subnets/VLANs | Mode = 1 (LAN, subnet-scoped) instead of 2 (Group) | `DODownloadMode`, intended site topology |
| Group mode configured but devices still isolated | `DOGroupId` inconsistent/auto-generated per device | Compare `DOGroupId` across multiple devices at the same site |
| First patch-day download still saturates WAN despite healthy peering | No Connected Cache deployed — structurally expected | `DOCacheHost` policy presence, `BytesFromCacheServer` in stats |
| Disk space alerts correlating with update cycles | DO cache uncapped, growing unchecked | `DOMaxCacheSize`/`DOAbsoluteMaxCacheSize` policy values |
| Devices peering with unexpected external hosts | Mode = 3 (Internet) left at default/unintended | `DODownloadMode`, review for compliance/security implications |
| DO peering "works" in testing (small office) but fails at a large multi-floor site | Group ID source not scoped correctly for that topology (e.g. AD Site not defined per floor when it should be) | `DOGroupIdSource`, AD Sites and Services config |
| Background update downloads consuming excessive foreground bandwidth during work hours | QoS/bandwidth throttling policies not set | `DOPercentageMaxForegroundBandwidth`, `DOMinBackgroundQoS` |

---

## Validation Steps

**1. Confirm service and baseline stats**
```powershell
Get-Service DoSvc | Select-Object Status, StartType
Get-DeliveryOptimizationStatus -Verbose | Select-Object FileId, PercentPeerCaching, BytesFromPeers, BytesFromCacheServer, BytesFromHttp
```
*Good:* Service running; recent large transfers show non-zero `PercentPeerCaching` on multi-device sites.
*Bad:* Service stopped, or `PercentPeerCaching` = 0 site-wide despite adequate device density.

**2. Confirm effective policy values (not just intended values)**
```powershell
Get-DeliveryOptimizationStatus
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config"
```
*Good:* Values match what was pushed via Intune/GPO.
*Bad:* Registry values don't reflect the intended policy — indicates policy processing failure (check `gpresult`/Intune sync status), not a DO-specific bug.

**3. Confirm network path for peering**
```powershell
Test-NetConnection -ComputerName <known-peer-ip> -Port 7680
Get-NetFirewallRule -DisplayName "*Delivery Optimization*" -Enabled True
```
*Good:* Connection succeeds, rules enabled and scoped correctly (not accidentally restricted to a profile the device isn't in, e.g. rule scoped to Domain profile only while device shows Public).
*Bad:* Port unreachable — most common cause is an inter-VLAN ACL or a third-party endpoint firewall product blocking 7680 that DO's own Windows Firewall rules don't account for.

**4. Confirm Connected Cache reachability (if deployed)**
```powershell
Get-DeliveryOptimizationStatus -Verbose | Select-Object BytesFromCacheServer
# Test direct reachability to the MCC endpoint configured in DOCacheHost
Test-NetConnection -ComputerName <mcc-hostname> -Port 443
```
*Good:* `BytesFromCacheServer` > 0 for recent transfers, endpoint reachable.
*Bad:* Endpoint unreachable or 0 bytes served — MCC may be down, mis-registered, or the policy pointing to it isn't applying.

**5. Confirm cache isn't unbounded**
```powershell
Get-DeliveryOptimizationPerfSnap
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DOMaxCacheSize" -ErrorAction SilentlyContinue
```
*Good:* A cap is set appropriate to available disk (commonly 10-20% of disk or a fixed GB value on smaller SSDs).
*Bad:* No cap set and disk usage climbing — on space-constrained devices (small SSD laptops) this can contribute to low-disk-space tickets around major feature update rollouts.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the complaint category.** "WAN is saturated on patch day" (needs Connected Cache, peering alone can't fix it) is a fundamentally different problem from "peering isn't happening even though it should be" (a config/network problem peering settings CAN fix). Don't jump to Connected Cache planning if simple peering isn't even correctly configured yet — fix peering first, then re-measure whether WAN saturation persists.

**Phase 2 — Verify policy application, not just intent.** Confirm the registry values on affected devices actually match the Intune profile/GPO — a policy that "looks right" in the admin console but hasn't synced to devices (stale MDM check-in, GPO replication delay) will show no behavior change and get misdiagnosed as a DO bug.

**Phase 3 — Isolate network-layer blocks from DO-layer config.** Port 7680 blocks are invisible to the end user and to most DO status commands directly — they show up only as "peering configured correctly, zero peer bytes transferred." Always test raw port reachability between two real peer devices before concluding the DO configuration itself is wrong.

**Phase 4 — Right-size expectations by site topology.** A 5-device branch office will show minimal peering benefit simply due to low device density and infrequent simultaneous downloads — this isn't a bug, it's an expected scale limitation of peer-to-peer distribution. Reserve Connected Cache investment for sites where device count justifies the infrastructure.

---

## Remediation Playbooks

<details><summary>Playbook — Standardize DO configuration across a multi-site fleet via Intune</summary>

1. Create an Intune Delivery Optimization configuration profile (Devices → Configuration → Delivery Optimization template).
2. Set Download Mode based on site topology: `1` (LAN) for simple single-subnet branch sites, `2` (Group) for larger multi-subnet campuses. Avoid `3` (Internet) fleet-wide unless there's a specific documented reason.
3. For Group mode, set `Group ID source = AD Site` for consistency without manual GUID management, assuming AD Sites and Services accurately reflects physical site boundaries.
4. Cap cache size appropriately for device hardware profile (lower percentage for small-SSD laptops, higher for desktops with ample disk).
5. Assign the profile by site-based Intune group/dynamic group so different sites can receive different Group ID sources if topology varies.
6. Validate with a pilot group before fleet-wide rollout — confirm `BytesFromPeers` increases on the pilot devices within a week of a deployment wave.

**Rollback:** Remove/unassign the configuration profile; devices revert to Windows default DO behavior (Internet mode, unmanaged cache size) — note this itself may not be a desirable end state for a managed enterprise, so plan the rollback destination deliberately rather than assuming "off" is safe.

</details>

<details><summary>Playbook — Deploy Microsoft Connected Cache to address first-download WAN saturation</summary>

1. Identify sites where WAN saturation persists despite confirmed-healthy peer-to-peer configuration (from the validation steps above) — this is the actual signal that MCC is warranted, not just "we have a big site."
2. Deploy MCC as a Windows Server role (simplest for existing on-prem server infrastructure) or as an Azure IoT Edge module (for sites without local server infrastructure).
3. Register the MCC endpoint in Intune's Delivery Optimization profile via `DOCacheHost` policy, scoped to devices at that site.
4. Validate with `Get-DeliveryOptimizationStatus -Verbose | Select BytesFromCacheServer` showing non-zero values after the next deployment wave.
5. Monitor MCC server disk/bandwidth utilization — it becomes a new piece of infrastructure requiring its own monitoring, not a "set and forget" deployment.

**Rollback:** Remove the `DOCacheHost` policy assignment; devices fall back to peer/CDN sourcing. Decommissioning the MCC server itself is a separate, non-urgent cleanup step.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Delivery Optimization diagnostic evidence for a device or small device set.
.DESCRIPTION
    Gathers service status, effective policy configuration, peer/cache transfer stats,
    and port 7680 reachability to a specified peer for escalation packaging.
.PARAMETER PeerToTest
    IP or hostname of another device at the same site to test peer connectivity against.
.EXAMPLE
    .\Get-DOEvidence.ps1 -PeerToTest 10.10.5.42
#>
param(
    [string]$PeerToTest,
    [string]$OutputPath = "$env:TEMP\DOEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
)

$results = [PSCustomObject]@{
    ComputerName        = $env:COMPUTERNAME
    ServiceStatus       = (Get-Service DoSvc).Status
    DownloadMode        = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -ErrorAction SilentlyContinue).DODownloadMode
    GroupIdSource       = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -ErrorAction SilentlyContinue).DOGroupIdSource
    GroupId             = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -ErrorAction SilentlyContinue).DOGroupId
    CacheHost           = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -ErrorAction SilentlyContinue).DOCacheHost
    MaxCacheSizePercent = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -ErrorAction SilentlyContinue).DOMaxCacheSize
    PeerPortReachable   = if ($PeerToTest) { (Test-NetConnection -ComputerName $PeerToTest -Port 7680 -WarningAction SilentlyContinue).TcpTestSucceeded } else { "Not tested" }
}

$results | Export-Csv $OutputPath -NoTypeInformation
Get-DeliveryOptimizationStatus -Verbose |
    Select-Object FileId, PercentPeerCaching, BytesFromPeers, BytesFromCacheServer, BytesFromHttp |
    Export-Csv "$($OutputPath).transfers.csv" -NoTypeInformation

Write-Host "Evidence written to $OutputPath and companion transfers CSV" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Get-Service DoSvc` | Confirm DO service is running |
| `Get-DeliveryOptimizationStatus -Verbose` | Per-file transfer source breakdown (peer/cache/HTTP) |
| `Get-DeliveryOptimizationPerfSnap` | Cache disk usage snapshot |
| `Get-ItemProperty "HKLM:\...\DeliveryOptimization\Config"` | Effective (applied) DO policy values |
| `Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name DODownloadMode -Value <n>` | Set download mode locally for testing |
| `Test-NetConnection -ComputerName <peer> -Port 7680` | Verify peer port reachability |
| `Restart-Service DoSvc` | Force policy re-read / clear transient state |
| `Get-NetFirewallRule -DisplayName "*Delivery Optimization*"` | Check built-in DO firewall rule state |
| Intune: Devices → Configuration → Delivery Optimization | Fleet-wide policy management |
| `Get-ADReplicationSite` / AD Sites and Services console | Verify Group ID source topology when using AD Site mode |

---

## 🎓 Learning Pointers

- **Peer-to-peer distribution cannot help the first download of any content at a site — that's a structural limitation, not a config gap.** If WAN saturation is specifically a "first wave of patch day" problem, only Connected Cache (or a traditional on-prem WSUS-style cache) addresses it; tuning DODownloadMode further will not. [MS Docs: Delivery Optimization overview](https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization)
- **Group mode's peer set is only as good as the Group ID's consistency — an unintentionally auto-generated or per-device GUID silently defeats the entire point of Group mode.** Always standardize the Group ID source via policy rather than leaving it to per-device defaults. [MS Docs: DO reference — Group ID](https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization-reference#DOGroupIdSource)
- **Port 7680 blocks are invisible in most day-to-day monitoring — they manifest only as "correctly configured but zero peer bytes."** Build a port-reachability check into any DO troubleshooting flow rather than assuming config settings alone determine peering success. [MS Docs: DO setup and firewall requirements](https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization-setup)
- **Small/low-density sites will show limited peering benefit by design — this is an expected scale limitation, not a misconfiguration to keep chasing.** Reserve further DO tuning effort and Connected Cache investment for sites where device density actually justifies it. [MS Docs: DO reference — bandwidth optimization](https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization-reference)
- **Uncapped local cache size can quietly contribute to low-disk-space tickets on small-SSD laptops, especially around large feature update rollouts.** Set `DOMaxCacheSize`/`DOAbsoluteMaxCacheSize` deliberately as part of the same policy that enables peering, not as an afterthought. [MS Docs: DO reference — cache size policies](https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization-reference#DOMaxCacheSize)
