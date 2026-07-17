# macOS Content Caching — Reference Runbook (Mode A: Deep Dive)
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

Covers **macOS Content Caching** — Apple's native local-network caching service for Software Update, App Store, iCloud, and other Apple-delivered content — as configured and enforced via Microsoft Intune's Settings Catalog "Content Caching" category. This is, architecturally, the same shape as `TimeMachine-A.md`: **Intune configures the service; Apple's own long-standing macOS subsystem does everything else**, with zero Intune-side telemetry for whether content is actually being served.

**Applies to:**
- A small, deliberately-chosen set of "always-on" Macs designated as cache hosts (desktops, Mac minis, or any Mac that stays powered on and connected)
- Client Macs, iPhones, and iPads on the same local network as a cache host — clients require **no configuration at all**, caching is transparent to them

**Out of scope:** third-party local-network caching/proxy solutions (Content Caching is Apple's only natively MDM-manageable implementation of this), Apple Configurator's device-side caching interactions, and Software Update-specific deferral/staging mechanics (covered in `SoftwareUpdates-A.md` — Content Caching accelerates delivery of update content but does not control update deferral policy).

**Explicit non-assumption:** unlike Wi-Fi/802.1X or WHfB elsewhere in this repo, Content Caching's discovery mechanism has **nothing to do with Entra ID, device groups, or any Microsoft-side identity or network construct**. It is governed entirely by Apple's own public-IP-and-local-subnet grouping logic. Troubleshooting "clients aren't finding the cache" is a network-topology investigation, not an Intune-assignment investigation.

---
## How It Works

<details><summary>Full architecture — configuration delivery, discovery, and serving</summary>

### The payload model

Content Caching settings are delivered via a Settings Catalog macOS profile (category: Content Caching). Once installed, the payload configures and starts the on-device caching daemon and its supporting services (`AssetCacheLocatorService` for discovery, plus the caching engine itself). This is standard configuration-profile delivery — inspect it the same way as any other profile via `profiles -P`, not via `mdmclient QueryDeclarations` (compare `DDM-A.md` for that distinction).

```
Intune (Settings Catalog — macOS platform, Content Caching category)
    │
    ▼
Configuration profile containing Content Caching settings
    │
    ▼
APNs push → mdmclient (device) → InstallProfile MDM command
    │
    ▼
Profile installed; caching daemon reads configuration
(Enable, Cache Type, Max Cache Size, Cache Location, Port, Tethered Caching)
    │
    ▼
Daemon starts, requests configuration from Apple
(suconfig.apple.com/resource/registration/v1/config.plist)
    │
    ▼
AssetCacheLocatorService registers the host with Apple's LCDN
(lcdn-registration.apple.com) — reports local address, public IP,
subnet range, cache capacity, capabilities, and any known peer caches
    │
    ▼
Clients (Macs, iOS/iPadOS devices, no configuration required) perform
normal Apple-content downloads through the OS's standard download path
    │
    ▼
OS-level redirect logic on the CLIENT transparently checks for a
same-public-IP, same-local-subnet cache before falling back to
the internet — entirely invisible to the user and to Intune
    │
    ▼
Cache serves from local storage (hit) or fetches-and-stores on first
request (miss, then cached for subsequent clients)
```

### What the payload actually configures

| Setting | Effect | Enforcement strength |
|---|---|---|
| Enable content caching | Turns the service on; users cannot disable it once managed | Enforced |
| Cache Type | `All content` (iCloud + shared), `User content only` (iCloud/photos/documents), or `Shared content only` (apps/updates) | Configures scope only |
| Maximum Cache Size | Disk space budget for cached content, in bytes | Enforced by the caching daemon's own purge logic once configured |
| Cache Location | Storage path for cached data — default `/Library/Application Support/Apple/AssetCache/Data` | Configures only; host needs adequate free space at the path |
| Port | TCP port for cache requests, 0–65535 (0 = auto-assigned) | Configures only |
| Tethered Caching (block internet sharing) | Prevents Internet Connection Sharing and blocks sharing cached content to USB-tethered iOS/iPadOS devices | Enforced |

### Discovery: the part with zero Intune visibility

Content Caching's discovery mechanism predates MDM entirely and has no management-service feedback channel, structurally identical in this respect to Time Machine's `backupd`. A cache host registers itself with Apple's Local Content Delivery Network (LCDN) registration service, reporting its **public IP address** and **local subnet range**. Clients — with zero configuration of their own — perform the same registration/lookup dance when they need Apple content, and Apple's infrastructure (plus the host's own `AssetCacheLocatorService` responding to local network queries) determines whether a matching cache exists **on the same public IP**.

This is why the single most common real-world failure mode is a **public IP mismatch** between a cache host and its intended clients — split-tunnel VPNs, multi-WAN/SD-WAN egress, and separate guest/corporate NAT gateways all break this silently, with no error surfaced to the user, the admin, or Intune. The client simply downloads from the internet as if no cache existed.

### Why there's no completion signal

Exactly as with Time Machine (`TimeMachine-A.md`), Content Caching's actual serving behavior is governed by a system daemon (`AssetCacheLocatorService`/caching engine) with internal logic that was never built with an MDM feedback channel. Intune can confirm the profile was delivered and the service was told to enable — it has no visibility into hit rates, registration success, or whether a single byte has ever actually been served from the cache. All of that lives exclusively on the host, surfaced via `AssetCacheManagerUtil` and the unified log.

</details>

---
## Dependency Stack

```
MDM enrollment; Settings Catalog Content Caching profile assigned to a
deliberately-chosen always-on host (NOT a broad device group — see
Remediation Playbook 1)
        │
Profile delivered → caching daemon configured and started
        │
Host has outbound HTTPS reachability to Apple's registration/config
endpoints (lcdn-registration.apple.com, suconfig.apple.com) — no TLS
interception supported on these endpoints
        │
Host successfully registers: public IP recorded, local subnet range set,
capacity/capabilities reported
        │
Client and host share the SAME public IP as observed by Apple
(the actual discovery grouping key — entirely outside Intune's model)
        │
Client requests Apple-eligible content via the OS's normal download path
(macOS updates, App/iOS Store apps+updates, iCloud, GarageBand, Books,
Xcode components — NOT manual/direct-link downloads)
        │
Cache serves from local storage or fetches-and-caches on first request
        │
Visible via AssetCacheManagerUtil status / Activity Monitor Cache tab
on the HOST ONLY (NOT visible in Intune — no portal signal exists,
and NOT visible on the client beyond normal/faster download speed)
```

**The critical break point in most real-world tickets is "client and host share the same public IP."** Everything above that line can look perfectly configured in Intune while this one network-topology fact silently defeats the entire feature.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| `profiles -P` shows no Content Caching payload on the intended host | Policy not assigned, or targeting the wrong device group | Confirm Intune assignment scope |
| Profile present but `AssetCacheManagerUtil status` shows not activated | Service failed to start — disk space, permissions, or macOS version issue at the configured cache location | Check `df -h` at Cache Location, check unified log for daemon startup errors |
| Service active but no public IP / registration failing | Outbound HTTPS to Apple's LCDN endpoints blocked (firewall, TLS-intercepting proxy) | `curl` test against `lcdn-registration.apple.com` and `suconfig.apple.com` |
| Host registered, but `AssetCacheLocatorUtil` on clients finds nothing | Client and host present different public IPs to the internet (VPN split-tunnel, multi-WAN, guest/corporate NAT separation) | Compare public IP from host and client independently |
| Cache discovered, but a specific download still hits the internet | Content type not cache-eligible, or Cache Type scope excludes it (e.g. "Shared content only" excludes iCloud) | Confirm content type against Apple's eligible-content list and the configured Cache Type |
| Caching activity stops during a known maintenance window | Cache host itself is installing an update and cannot serve while doing so | Expected behavior — confirm host update status |
| Multiple sites/subnets each need their own cache, but only one was deployed | Content Caching discovery does not span WAN links by design — one cache per local network/subnet is the intended topology | Review Remediation Playbook 2 (multi-site design) |
| Two profiles targeting one host produce inconsistent/undefined behavior | Apple's payload spec forbids multiple Content Caching profiles per device | `profiles -P` — count Content Caching payload instances |
| Cache fills up and evicts recently-cached items quickly | Max Cache Size configured too small relative to update/app cycle volume for the client population | Check `AssetCacheManagerUtil status` cache size vs. actual demand; adjust Settings Catalog value |

---
## Validation Steps

**1. Confirm the profile delivered to the intended host**
```bash
sudo profiles -P | grep -iB2 -A15 "AssetCache\|Content Caching"
```

**2. Confirm the service is active and read effective settings**
```bash
sudo AssetCacheManagerUtil status
sudo AssetCacheManagerUtil settings
```
Good: `Activated: true`, `Active: true`. Bad: activated but not active, or not activated at all despite a delivered profile.

**3. Confirm outbound reachability to Apple's registration/config endpoints**
```bash
curl -sv --max-time 10 https://lcdn-registration.apple.com/lcdn/register -o /dev/null 2>&1 | tail -15
curl -sv --max-time 10 https://suconfig.apple.com/resource/registration/v1/config.plist -o /dev/null 2>&1 | tail -15
```

**4. Confirm registration succeeded (public IP populated)**
```bash
sudo AssetCacheManagerUtil status | grep -iE "public|registration"
```

**5. Compare public IP between host and a representative client**
```bash
curl -s https://api.ipify.org   # run on host, then on client, compare output
```

**6. Confirm client-side discovery**
```bash
# On the client
/usr/bin/AssetCacheLocatorUtil 2>&1
```
Good: at least one entry matching the intended host's local address. Bad: empty result despite matching public IPs — check the host's local subnet range restriction if one was explicitly narrowed.

**7. Confirm live serving during a real download**
```bash
# On the HOST, while a client performs an eligible download
log stream --predicate 'subsystem == "com.apple.AssetCache"' --info
```

**8. Check cache storage health**
```bash
df -h /Library/Application\ Support/Apple/AssetCache/Data 2>&1
```
(Adjust path if a non-default Cache Location was configured.)

---
## Troubleshooting Steps (by phase)

### Phase 1: Profile not delivering to the intended host

1. Confirm Intune assignment targets the specific always-on Mac(s) chosen as cache hosts — this should be a small, deliberate group, not a broad device population.
2. Force an MDM sync and re-check `profiles -P`.
3. Confirm no conflicting/duplicate Content Caching profile is also in scope for the same device (see Fix 4 in `ContentCaching-B.md`).

### Phase 2: Profile delivered, service not starting

1. Check `AssetCacheManagerUtil status` for activation state.
2. Check free disk space at the configured Cache Location.
3. Check the unified log around service startup for permission or storage errors: `log show --predicate 'subsystem == "com.apple.AssetCache"' --last 1h`.

### Phase 3: Service active, not registering with Apple

1. Test outbound HTTPS reachability to `lcdn-registration.apple.com` and `suconfig.apple.com` directly from the host.
2. Rule out TLS-intercepting proxies/firewalls on those specific endpoints — Content Caching registration does not tolerate broken TLS chains to Apple's services.
3. Re-check `AssetCacheManagerUtil status` for a populated public IP after connectivity is confirmed.

### Phase 4: Registered, but clients can't discover it

1. Compare public IP as seen by the host vs. a representative client — this is the single highest-yield check in this entire topic.
2. If IPs differ, this is a network-topology finding (VPN split-tunnel, multi-WAN, separate NAT gateway) that Content Caching configuration cannot fix — escalate to network architecture, not MDM policy.
3. If IPs match but discovery still fails, check for an explicitly narrowed local-subnet restriction in the host's settings.

### Phase 5: Discovered, but specific content not caching

1. Confirm the content type is on Apple's eligible list (Software Update, App Store, iCloud, GarageBand, Books, Xcode) and not a manual/direct-link download.
2. Confirm the configured Cache Type (All / User-only / Shared-only) includes that content category.
3. Confirm the cache host isn't mid-update itself at the time of the failed request.

---
## Remediation Playbooks

<details>
<summary>Playbook 1 — Standing up a Content Caching host for a single office/site</summary>

**Scenario:** First-time deployment for a site with a shared local network and a natural "always-on" Mac candidate.

1. Identify a Mac that stays powered on and network-connected during business hours (a desktop or Mac mini is ideal; avoid laptops that sleep/roam).
2. Confirm the site's egress path presents a single, stable public IP to the internet for all client devices that should use the cache — verify this *before* deployment, not after, since it's the dependency most likely to silently break the whole feature.
3. Assign the Settings Catalog Content Caching profile to that single host only — do not assign it broadly.
4. Set Cache Type and Max Cache Size deliberately based on the client population's update/app cycle volume, not defaults, if the site has meaningfully more or fewer devices than typical.
5. Validate via `AssetCacheManagerUtil status` (registration succeeded) and `AssetCacheLocatorUtil` from a client (cache discovered) before considering the rollout complete.
6. Document that there is no Intune-side reporting for cache hit rate or health — set that expectation with stakeholders up front, exactly as with Time Machine (`TimeMachine-A.md` Playbook 3).

**Rollback:** Remove the profile assignment from the host. The service deactivates; existing cached content on disk can be manually cleared via System Settings → General → Sharing → Content Caching → Reset (or left in place harmlessly — it is not synced or referenced by anything once the service is off).

</details>

<details>
<summary>Playbook 2 — Multi-site / multi-subnet design</summary>

**Scenario:** An organization with several physical sites, each needing local caching, incorrectly deploys one Content Caching profile expecting it to cover the whole WAN.

Content Caching's discovery mechanism is explicitly local-network-and-public-IP scoped by design — it does not, and is not intended to, span sites connected only by WAN/VPN links back to a hub. Each site with its own distinct public IP egress needs its **own** cache host and its own profile-assignment scope (typically modeled as a per-site device group in Intune).

1. Enumerate sites by distinct public IP egress, not by physical address or subnet alone (a site behind a shared SD-WAN egress with another site may share a public IP and could potentially share a cache — verify before assuming one-cache-per-building).
2. For larger deployments, Apple supports a peer/parent cache hierarchy (a cache can source from a sibling or parent cache rather than always hitting Apple's servers directly) — this is configured via the host's own advanced settings and is a capacity-planning decision, not something Intune's Settings Catalog surface currently exposes; treat it as an out-of-band host configuration decision layered on top of the Intune-delivered baseline settings.
3. Assign one Content Caching profile per site-scoped device group, targeting that site's designated host(s).
4. Validate each site independently using the standard discovery test (`AssetCacheLocatorUtil` from a representative client at that site).

**Rollback:** Remove site-specific assignments individually; sites are independent, so a rollback at one site has no effect on others.

</details>

<details>
<summary>Playbook 3 — Recovering from a corrupted or bloated cache</summary>

**Scenario:** Clients report downloads that "complete" but then fail verification, or the cache volume is full and evicting content faster than expected.

1. Confirm the symptom is genuinely cache-side and not a network/content-integrity issue elsewhere by testing a direct (non-cached) download of the same content for comparison.
2. The Apple-supported reset path is via the host's own UI: System Settings → General → Sharing → Content Caching → **Reset** — this clears the cache's stored data and re-initializes cleanly. Treat any lower-level manual manipulation of the cache's internal storage/database as unsupported and liable to corrupt the cache further; if a command-line-only remediation is required, verify exact current syntax via `man AssetCacheManagerUtil` on the actual host before running anything destructive, since Apple has changed this tool's flags across macOS versions and no single set of flags should be assumed stable long-term.
3. After a reset, re-verify registration (`AssetCacheManagerUtil status`) and re-test discovery/serving from a client before considering the host healthy again.
4. If the volume was full, either increase Max Cache Size in the Settings Catalog profile (if disk space allows) or move Cache Location to a larger volume — changing Cache Location requires the service to reinitialize and will not migrate existing cached content, so expect a temporary cache-cold period afterward.

**Rollback:** A cache reset is inherently destructive to cached *content* only — it does not affect the profile, the service's configuration, or any client-facing data; clients simply re-download and repopulate the cache from Apple as normal, at the cost of temporarily higher WAN usage.

</details>

---
## Evidence Pack

```bash
# Run this on the CACHE HOST via macOS shell (remote session, Intune Shell Script, or SSH)
# Collects Content Caching configuration + registration + activity evidence for escalation

OutputPath="/tmp/cc-evidence-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OutputPath"

sudo profiles -P > "$OutputPath/all_profiles.txt" 2>&1
sudo AssetCacheManagerUtil status > "$OutputPath/cache_status.txt" 2>&1
sudo AssetCacheManagerUtil settings > "$OutputPath/cache_settings.txt" 2>&1

curl -sv --max-time 10 https://lcdn-registration.apple.com/lcdn/register -o /dev/null > "$OutputPath/reg_endpoint_test.txt" 2>&1
curl -sv --max-time 10 https://suconfig.apple.com/resource/registration/v1/config.plist -o /dev/null > "$OutputPath/config_endpoint_test.txt" 2>&1
curl -s https://api.ipify.org > "$OutputPath/host_public_ip.txt" 2>&1

df -h > "$OutputPath/disk_space.txt" 2>&1

log show --predicate 'subsystem == "com.apple.AssetCache"' --last 4h --info > "$OutputPath/assetcache_log_4h.txt" 2>&1

tar czf /tmp/cc-evidence.tar.gz -C /tmp "$(basename "$OutputPath")"
echo "Evidence pack: /tmp/cc-evidence.tar.gz"
echo "Remember to also collect AssetCacheLocatorUtil output FROM A CLIENT separately — it cannot be run remotely from the host."
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| List all profiles (find Content Caching payload) | `sudo profiles -P \| grep -iB2 -A15 "AssetCache"` |
| Check service activation/status | `sudo AssetCacheManagerUtil status` |
| Show effective configuration | `sudo AssetCacheManagerUtil settings` |
| Test registration endpoint reachability | `curl -sv --max-time 10 https://lcdn-registration.apple.com/lcdn/register -o /dev/null` |
| Test config endpoint reachability | `curl -sv --max-time 10 https://suconfig.apple.com/resource/registration/v1/config.plist -o /dev/null` |
| Check public IP (host and client, compare) | `curl -s https://api.ipify.org` |
| Discover caches from a client | `/usr/bin/AssetCacheLocatorUtil` |
| Live activity stream (host) | `log stream --predicate 'subsystem == "com.apple.AssetCache"' --info` |
| Historical activity (host, last 4h) | `log show --predicate 'subsystem == "com.apple.AssetCache"' --last 4h --info` |
| Check free space at cache location | `df -h /Library/Application\ Support/Apple/AssetCache/Data` |
| Reset the cache (UI, supported path) | System Settings → General → Sharing → Content Caching → Reset |

---
## 🎓 Learning Pointers

- **This is configuration delivery, not a managed serving pipeline.** Exactly like Time Machine, Intune's role ends the moment the service is enabled and configured. Hit rate, registration health, and actual serving are Apple's own long-standing `AssetCacheLocatorService` behavior, with zero Intune reporting. See: [Apple — About content caching](https://support.apple.com/guide/mac-help/about-content-caching-mchl1490577b/mac) and [Apple — Content caching metrics on Mac](https://support.apple.com/guide/deployment/content-caching-metrics-dep0504346e1/web)

- **Discovery is public-IP-scoped, not Intune-group-scoped — and this is the recurring failure mode.** A cache host and its clients must present the same public IP to the internet. VPN split-tunneling, multi-WAN egress, and separated guest/corporate NAT gateways all defeat this silently, with clients simply falling back to normal internet downloads with no error anywhere. Verify public IP match early in any "caching isn't working" investigation — it resolves the majority of real-world tickets on this topic.

- **"One profile only" is an Apple-enforced constraint, unusual among Settings Catalog categories.** Most Settings Catalog categories tolerate (or explicitly define precedence for) multiple overlapping profiles; Content Caching does not — a second profile targeting the same device produces undefined behavior per Apple's own documentation, not a predictable override.

- **Manual/direct downloads are permanently outside the cache's reach.** Apple Developer account downloads and other non-standard delivery paths never route through Content Caching, regardless of configuration — this is a scope boundary, not a fault to chase.

- **Content Caching is single-site by design; multi-site needs multiple hosts.** Don't expect one cache to serve a whole WAN — each distinct public-IP-egress location needs its own host and profile assignment scope, with Apple's peer/parent cache hierarchy (an out-of-band host configuration, not an Intune setting) as the mechanism for larger, more complex topologies.
