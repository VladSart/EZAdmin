# Windows Delivery Optimization — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Run these first — results dictate which fix path to follow. Common complaints: "Windows Updates are saturating our WAN link," "updates download painfully slowly on a large site," or "DO is pulling from the internet instead of peers on our LAN."

```powershell
# 1 — Delivery Optimization service state
Get-Service -Name DoSvc | Select-Object Name, Status, StartType

# 2 — Current DO download mode configured
Get-DeliveryOptimizationStatus | Select-Object -First 1
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -ErrorAction SilentlyContinue).DODownloadMode

# 3 — Recent DO transfer stats — see if peers are being used at all
Get-DeliveryOptimizationStatus -Verbose | Select-Object FileId, PercentPeerCaching, BytesFromPeers, BytesFromCacheServer, BytesFromHttp

# 4 — DO Group ID (required for Group mode peering across subnets)
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -ErrorAction SilentlyContinue).DOGroupIdSource

# 5 — Current cache disk usage / max cache size
Get-DeliveryOptimizationPerfSnap
```

**Interpretation table:**

| Finding | Action |
|---------|--------|
| `DoSvc` stopped | Service not running — Fix 1 |
| `BytesFromPeers` = 0 across all files, mode set to LAN/Group/Internet (1/2/3) | Peering isn't happening despite being enabled — Fix 2 |
| `DODownloadMode` = 0 (HTTP only) | DO peering disabled by policy/registry — Fix 3 |
| `DODownloadMode` = 2 (Group) but no `DOGroupIdSource`/GroupID set | Group peering misconfigured, devices isolated to themselves — Fix 4 |
| Cache filling disk / `Get-DeliveryOptimizationPerfSnap` shows high disk usage | Cache size not capped — Fix 5 |
| Devices peering fine on-site but WAN still saturated during patch Tuesday | Expected without a Connected Cache / MCC server — Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Delivery Optimization (DoSvc) service — Running
  │
  ├── Download Mode (DODownloadMode) policy value
  │     ├── 0 = HTTP only (no peering)
  │     ├── 1 = LAN (peers on same NAT/subnet only)
  │     ├── 2 = Group (peers within a defined Group ID — can span subnets/sites)
  │     ├── 3 = Internet (peers across the internet — rarely desired in a managed org)
  │     └── 99/100 = Simple/Bypass (no peering, DO acts as pass-through only)
  │
  ├── [Group mode only] DOGroupIdSource + GroupID
  │     └── Must match across all devices intended to peer with each other
  │           └── AD site, domain, or AAD Tenant ID commonly used as the source
  │
  ├── Firewall rules permitting DO peer traffic
  │     └── TCP/UDP 7680 (peer-to-peer), plus normal HTTPS 443 for cloud/CDN fallback
  │
  ├── Local DO cache (disk-backed, size-limited)
  │     └── MaxCacheSize / MinBackgroundQoS policies control disk footprint
  │
  └── [Enterprise scale] Microsoft Connected Cache (MCC) or on-prem cache server
        └── Acts as a local "seed" so the FIRST download at a site is also local, not just subsequent peer transfers
```

**Key interlock:** Peering only saves bandwidth for the *second and subsequent* downloads of the same content at a site — the very first device to download a given update package still pulls from Microsoft's CDN over the WAN unless a Connected Cache server is deployed. This is the single most common misunderstanding driving "DO isn't helping our bandwidth" tickets.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the service and current mode**
```powershell
Get-Service DoSvc | Select-Object Status
Get-DeliveryOptimizationStatus | Select-Object -First 1
```
*Good:* Service `Running`.
*Bad:* Stopped/disabled — nothing will peer at all, every device pulls full content from the internet.

---

**Step 2 — Check whether peering is actually occurring**
```powershell
Get-DeliveryOptimizationStatus -Verbose |
    Select-Object FileId, Status, PercentPeerCaching, BytesFromPeers, BytesFromHttp, BytesFromCacheServer
```
*Good:* `PercentPeerCaching` > 0 for recent large downloads (feature updates, driver packages) on sites with multiple devices.
*Bad:* Consistently 0% across every file even on sites with 20+ devices — points to a mode/Group ID/firewall problem, not just "not enough peers yet."

---

**Step 3 — Confirm the configured download mode matches intent**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -ErrorAction SilentlyContinue |
    Select-Object DODownloadMode, DOGroupIdSource, DOGroupId, DOMaxCacheSize, DOMinBackgroundQoS
```
*Good:* Mode set intentionally (1 for single-subnet sites, 2 for multi-subnet sites with a consistent Group ID).
*Bad:* Mode = 0 (explicitly disabled) or mode = 3 (Internet) in a managed enterprise — Internet mode peers with unknown external devices, which is rarely the intended posture and can raise security review flags.

---

**Step 4 — Check firewall/network path for peer traffic**
```powershell
Get-NetFirewallRule -DisplayName "*Delivery Optimization*" | Select-Object DisplayName, Enabled, Direction, Action
Test-NetConnection -ComputerName <peer-ip> -Port 7680
```
*Good:* Rules enabled, port 7680 reachable between peers on the same site.
*Bad:* Port blocked by a site firewall/switch ACL — peering silently fails and DO falls back to HTTP with no visible error to the end user.

---

**Step 5 — Confirm Group ID consistency for multi-subnet sites**
```powershell
# Run on multiple machines at the same physical site, compare output
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config").DOGroupId
```
*Good:* Identical Group ID across all devices meant to peer together.
*Bad:* Different or blank Group IDs — devices are isolated into their own single-device "group" and never peer with anyone.

---

## Common Fix Paths

<details><summary>Fix 1 — Restart the Delivery Optimization service</summary>

```powershell
Restart-Service DoSvc
Start-Sleep -Seconds 5
Get-Service DoSvc | Select-Object Status
```

**Rollback:** N/A — restarting a service is non-destructive.

</details>

<details><summary>Fix 2 — Set an explicit download mode via Intune/GPO (not just registry)</summary>

Ad-hoc registry change (test on one device first):
```powershell
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Value 1 -Type DWord
Restart-Service DoSvc
```
For fleet-wide, set via Intune: **Devices → Configuration → Delivery Optimization profile → Download Mode = LAN (1)** for single-subnet sites, **Group (2)** for multi-subnet sites.

**Rollback:** Revert `DODownloadMode` to previous value (commonly 3/Internet default) and restart the service. No data loss risk — this only affects update transfer behavior.

</details>

<details><summary>Fix 3 — Re-enable peering if disabled by policy</summary>

```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -ErrorAction SilentlyContinue
# If value is 0 or 100, someone intentionally disabled peering — confirm with change history before flipping
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Value 1 -Type DWord
```

**Rollback:** Set back to 0 if peering needs to stay disabled (e.g. a site with a documented security requirement against P2P protocols).

</details>

<details><summary>Fix 4 — Set a consistent Group ID across a multi-subnet site</summary>

```powershell
# Simplest reliable source: AD Site name, applied consistently via Intune/GPO across the fleet
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DOGroupIdSource" -Value 1 -Type DWord  # 1 = AD Site
Restart-Service DoSvc
```
Deploy via Intune profile so every device at the site inherits the same value automatically rather than manually matching GUIDs.

**Rollback:** Revert `DOGroupIdSource`/`DOGroupId` to prior values; devices fall back to LAN-only (subnet-scoped) or no peering.

</details>

<details><summary>Fix 5 — Cap the local DO cache size</summary>

```powershell
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DOMaxCacheSize" -Value 20 -Type DWord   # percent of disk, or use DOAbsoluteMaxCacheSize for GB
Restart-Service DoSvc
```

**Rollback:** Remove the cap (delete the value) to revert to default cache sizing behavior.

</details>

<details><summary>Fix 6 — Deploy Microsoft Connected Cache for real WAN savings</summary>

**Cause:** Peer-to-peer DO only saves bandwidth from the *second* download onward at a site — a large site's first patch-day download of a several-GB feature update still fully traverses the WAN. Microsoft Connected Cache (MCC) — a free downloadable Windows Server role or Azure IoT Edge module — acts as a local seed server so even the first download stays on-site.

Not a quick registry fix — plan as a change request:
1. Deploy MCC on a server (or Azure IoT Edge device) at each large site.
2. Point client Delivery Optimization config at the MCC endpoint via `DOCacheHost` policy.
3. Validate via `Get-DeliveryOptimizationStatus` showing `BytesFromCacheServer` > 0 after rollout.

**Rollback:** Remove `DOCacheHost` policy value; devices fall back to peer/CDN behavior.

</details>

---

## Escalation Evidence

```
=== DELIVERY OPTIMIZATION ESCALATION ===
Date/Time:                          ____________________
Site/location affected:             ____________________
Reported symptom:                   WAN SATURATION / SLOW DOWNLOADS / NO PEERING
Device count at site:                ____________________

=== CHECKS COMPLETED ===
[ ] DoSvc service status:            ____________________
[ ] DODownloadMode value:            ____________________
[ ] BytesFromPeers > 0 on recent transfers: YES / NO
[ ] Group ID consistent across site devices: YES / NO
[ ] Port 7680 reachable between peers:  YES / NO
[ ] Connected Cache deployed at site:  YES / NO

=== ACTIONS TAKEN ===
[ ] Restarted DoSvc:                  YES / NO
[ ] Set/corrected DODownloadMode:     YES / NO — new value: ____
[ ] Set consistent Group ID:          YES / NO
[ ] Opened firewall for port 7680:    YES / NO
[ ] Capped cache size:                YES / NO

=== ESCALATION PATH ===
If WAN saturation persists after peering is confirmed healthy:
- Raise a change request to deploy Microsoft Connected Cache at the affected site
- Include: site device count, average feature-update size, current WAN link speed
```

---

## 🎓 Learning Pointers

- **Peer-to-peer DO never helps the first download of a given file at a site — only the second device onward benefits.** For sites where the "first download" itself saturates the link, the fix is Connected Cache, not tuning peering settings further. [MS Docs: Delivery Optimization reference](https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization)
- **Group mode requires an identical Group ID across every device meant to peer — a mismatched or auto-generated GUID silently isolates each device into its own group of one.** Standardize the Group ID source (AD Site is usually simplest) and deploy it fleet-wide via policy, not per-device. [MS Docs: DO Group ID reference](https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization-reference)
- **Peer traffic uses TCP/UDP port 7680 — a site firewall or switch ACL blocking it produces silent fallback to HTTP with no user-visible error.** Always check port reachability between peers before assuming a software/config-only problem. [MS Docs: DO firewall requirements](https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization-setup)
- **Internet-mode peering (mode 3) means devices peer with unknown external clients over the internet — this is rarely the intended posture for a managed enterprise fleet and is worth flagging in a security review if found enabled by default.** [MS Docs: Download mode values](https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization-reference#download-mode)
- **Microsoft Connected Cache is free and often the actual fix for "Windows Update is killing our WAN link" tickets, not further DO tuning.** It's underused because it requires a small infrastructure deployment rather than a registry/policy change, but it addresses the root cause peering alone cannot. [MS Docs: Connected Cache overview](https://learn.microsoft.com/en-us/microsoft-365/education/deploy/deploy-windows-update-for-business-connected-cache)
