# macOS Content Caching — Hotfix Runbook (Mode B: Ops)
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

Content Caching is a native macOS service (not an Intune-invented feature) that Intune's Settings Catalog can *turn on and configure* on a designated Mac — it then caches macOS updates, App Store apps/updates, iCloud content, and other Apple-delivered content locally so other Macs, iPhones, and iPads on the same network pull from it instead of the internet. **Intune's role ends at "the service is on and configured."** Discovery and serving are handled entirely by Apple's own local-network protocol (`AssetCacheLocatorService`) with zero Intune-side visibility into whether anything is actually being served — the same "configuration delivery only" shape as `TimeMachine-B.md`.

```bash
# Run these ON THE CACHE HOST (the Mac running the service), not a client
# 1. Confirm the managed profile delivered
sudo profiles -P | grep -iB2 -A15 "AssetCache\|Content Caching"

# 2. Confirm the service is actually running and its current settings
sudo AssetCacheManagerUtil status
sudo AssetCacheManagerUtil settings

# 3. Confirm it's registered with Apple and knows its own reachability
sudo AssetCacheManagerUtil status | grep -iE "registration|public ip|active"

# 4. Watch live activity (leave running while a client tries to download something)
log stream --predicate 'subsystem == "com.apple.AssetCache"' --info

# 5. From a CLIENT Mac on the same network — confirm the cache is discoverable at all
/usr/bin/AssetCacheLocatorUtil 2>&1 | tail -30
```

| Result | Interpretation |
|---|---|
| `profiles -P` shows no AssetCache/Content Caching payload on the intended host | Policy never assigned to this device, or MDM sync hasn't landed — check Intune assignment before anything else |
| `AssetCacheManagerUtil status` shows the service not running despite the profile being present | Service failed to start — check disk space at the configured cache location and macOS version compatibility |
| Status shows `Registration Status: not registered` or no public IP listed | Host can't reach Apple's registration endpoint (`lcdn-registration.apple.com`) — outbound HTTPS is blocked, see Fix 1 |
| `AssetCacheLocatorUtil` on a client returns no caches found | Client and cache host don't share the same **public IP** as seen by Apple — most common cause is split-tunnel VPN, multi-WAN, or the client being on a different physical network than expected — see Fix 2 |
| Cache is discovered and registered, but client downloads still pull from the internet | Content type not eligible for caching (e.g. a manually-downloaded Developer-account file), or the specific asset isn't cacheable — see Fix 3 |
| `AssetCacheManagerUtil status` shows the service is busy/updating | The cache host itself is mid-update and cannot serve while doing so — this is expected behavior, not a fault |
| Two or more Content Caching profiles assigned in the same tenant/scope | Apple's own payload spec forbids multiple Content Caching profiles — behavior is explicitly undefined/erroring, not "last one wins" — see Fix 4 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Cache host is MDM-enrolled, Settings Catalog "Content Caching" profile assigned
        │
Profile delivered → com.apple.AssetCache managed preferences written
        │
AssetCacheLocatorService / caching daemon starts and reads config
        │      (Cache Type: All / User-only / Shared-only, Max Cache Size,
        │       Cache Location — default /Library/Application Support/Apple/AssetCache/Data,
        │       Port — 0 = auto-assigned)
        │
Host has outbound HTTPS reachability to Apple's registration service
(lcdn-registration.apple.com, suconfig.apple.com) — required to register
its public IP and learn about sibling/parent caches
        │
Host and CLIENT share the same public IP + are on a routable local subnet
(this is Apple's discovery grouping key — NOT anything Intune configures
or is aware of)
        │
Client requests eligible content (macOS update, App Store app, iCloud data,
GarageBand/Books/Xcode content — see Apple's content list) via the OS's
normal download path, which transparently redirects to the local cache
        │
Cache serves from local storage, or fetches-and-stores on first request
        │
Visible via AssetCacheManagerUtil status / Activity Monitor "Cache" tab
(on the HOST only — clients have no caching-specific UI or log signal
beyond faster/normal download speed)
```

**The public-IP-matching discovery mechanism is the single most common point of confusion.** It has nothing to do with Intune group assignment, device compliance, or network profiles documented elsewhere in this repo — it's Apple's own Bonjour-adjacent local-network + public-IP grouping logic, and it fails silently from a client's perspective (downloads just proceed normally from the internet, no error is shown).

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the profile delivered to the intended cache host**
```bash
sudo profiles -P | grep -iB2 -A15 "AssetCache\|Content Caching"
```
Expected: a profile entry referencing Content Caching settings. Bad: no match → check Intune assignment scope — this profile should almost always target a small, deliberate set of always-on Macs, not a broad device group.

**2. Confirm the service is active and read its settings**
```bash
sudo AssetCacheManagerUtil status
sudo AssetCacheManagerUtil settings
```
Expected: `Activated: true`, `Active: true`, a populated `Cache Details` / storage figure. Bad: `Activated: false` despite the profile being present → service failed to initialize, check Console/log for errors around cache location permissions or disk space.

**3. Confirm registration with Apple**
```bash
sudo AssetCacheManagerUtil status | grep -iE "public|registration|peer"
log show --predicate 'subsystem == "com.apple.AssetCache"' --last 1h --info | grep -iE "registration|public ip" | tail -20
```
Expected: a public IP address populated and `Request for registration ... succeeded` in the log. Bad: no public IP, or repeated registration failures → outbound HTTPS to Apple's registration endpoints is blocked — see Fix 1.

**4. Confirm client-side discovery**
```bash
# On a client Mac on the SAME network as the host
/usr/bin/AssetCacheLocatorUtil 2>&1
```
Expected: at least one cache listed with the host's local address. Bad: empty/no caches found → public IP mismatch between host and client, or local subnet range restriction on the host is scoped too narrowly — see Fix 2.

**5. Watch a live download to confirm actual serving**
```bash
# On the HOST, while a client performs a real download (App Store app, macOS update)
log stream --predicate 'subsystem == "com.apple.AssetCache"' --info
```
Expected: `Received GET request by ...` / `Served ... from cache` entries appearing in real time. Bad: nothing appears during a known-eligible download → client isn't reaching the cache at all (network/discovery issue) rather than a content-eligibility issue.

**6. Check cache storage health**
```bash
df -h "$(sudo AssetCacheManagerUtil settings 2>/dev/null | awk -F': ' '/Cache Location|DataPath/{print $2; exit}')" 2>&1
```
Expected: meaningful free space remaining relative to configured `Max Cache Size`. Bad: volume nearly full → cache is aggressively purging older content, reducing hit rate.

---
## Common Fix Paths

<details>
<summary>Fix 1 — Host can't register with Apple (outbound HTTPS blocked)</summary>

**Scenario:** `AssetCacheManagerUtil status` shows no public IP / registration never succeeds.

Content Caching requires the host to reach Apple's registration and configuration endpoints over standard HTTPS (443). This is a firewall/proxy problem, not an MDM problem.

```bash
# Confirm basic reachability to Apple's registration/config endpoints
curl -sv --max-time 10 https://lcdn-registration.apple.com/lcdn/register -o /dev/null 2>&1 | tail -20
curl -sv --max-time 10 https://suconfig.apple.com/resource/registration/v1/config.plist -o /dev/null 2>&1 | tail -20
```

If either fails: check outbound firewall/proxy rules for the host. A transparent HTTPS-inspecting proxy that breaks TLS to Apple's endpoints is a common cause in tightly locked-down environments — Content Caching does not support proxy-based TLS interception on these endpoints.

**Rollback:** N/A — diagnostic and firewall-rule verification only.

</details>

<details>
<summary>Fix 2 — Clients can't discover the cache (public IP / subnet mismatch)</summary>

**Scenario:** `AssetCacheLocatorUtil` on a client returns no results, but the host itself shows `Activated: true` and registered.

Apple groups a cache host with its clients by **the public IP address both present to the internet**, plus the host's configured local subnet range. If the client and host exit to the internet via different public IPs (split-tunnel VPN, multi-WAN/SD-WAN failover, guest vs. corporate SSID on different NAT gateways), discovery silently fails — there is no error, downloads simply proceed from the internet as normal.

```bash
# Confirm host and client see the SAME public IP
curl -s https://api.ipify.org      # run on the host
curl -s https://api.ipify.org      # run on the client — compare

# Check the host's configured local-subnet restriction (if any was set beyond default)
sudo AssetCacheManagerUtil settings | grep -i "subnet\|local"
```

If the public IPs differ: this is a network topology issue, not a Content Caching configuration issue — the host and client need to share an egress path, or the environment needs a peer/parent caching hierarchy designed around that topology (see `ContentCaching-A.md` Remediation Playbooks for multi-site design).

**Rollback:** N/A — diagnostic. No destructive change involved.

</details>

<details>
<summary>Fix 3 — Cache is discovered but specific downloads still pull from the internet</summary>

**Scenario:** `AssetCacheLocatorUtil` finds the cache and other content is being served, but a particular download isn't.

Not everything is eligible. Confirm the content type is actually covered — macOS Software Update content, Internet Recovery images (10.13.5+), App/iOS/iPadOS App Store apps and updates, GarageBand downloadable content, iCloud (Photos/Documents), Apple Books, and Xcode downloadable components. Content obtained through **manual/direct download links (including many Apple Developer account downloads)** does not route through the cache regardless of configuration.

```bash
# Confirm the cache type setting includes what's needed
sudo AssetCacheManagerUtil settings | grep -i "cache type\|shared\|personal"
```

If `Cache Type` is set to "Shared content only," personal iCloud content will never be cached even though App Store content is — this is a deliberate scope setting, not a bug. Adjust the Settings Catalog profile's Cache Type value if broader coverage is required.

**Rollback:** N/A — configuration-scope clarification, not a destructive change.

</details>

<details>
<summary>Fix 4 — Multiple Content Caching profiles assigned to the same device</summary>

**Scenario:** A device has more than one Content Caching-category Settings Catalog profile in scope (e.g. one from a broad group, one from a device-specific group).

Apple's own payload documentation is explicit: **use only one profile for these settings.** Assigning multiple triggers an error state, not a merge or "most recent wins" — the resulting behavior is undefined and should not be relied upon.

```bash
# List every profile that touches AssetCache settings
sudo profiles -P | grep -iB5 "AssetCache"
```

Remove or re-scope Intune assignments so exactly one Content Caching profile targets any given device — consolidate into a single profile with the correct settings rather than layering a second one for an override.

**Rollback:** Re-assign whichever profile was removed if this was done in error — deleting a Settings Catalog assignment does not delete existing cached content on the host.

</details>

---
## Escalation Evidence

```
Cache host name / serial:
Managed profile present on host (Y/N):
AssetCacheManagerUtil status output:
Registration succeeded (public IP shown, Y/N):
Cache Type / Max Cache Size / Cache Location configured:
Client device(s) affected — name/serial:
Client public IP vs. host public IP (match, Y/N):
AssetCacheLocatorUtil result from client:
Content type affected (macOS update / App Store / iCloud / other):
Free disk space at cache location:
Issue first observed:
Business impact (single site / multi-site):
```

---
## 🎓 Learning Pointers

- **This is Apple's native service, wearing Intune's configuration.** Intune (via Settings Catalog) can turn Content Caching on, set its cache type/size/location/port, and prevent the user from disabling it — but discovery and serving are entirely Apple's own `AssetCacheLocatorService` protocol, invisible to Intune. There is no Intune report for "is this actually caching anything" — that question can only be answered on the host itself. See: [Apple — About content caching](https://support.apple.com/guide/mac-help/about-content-caching-mchl1490577b/mac) and [Apple — Content caching metrics on Mac](https://support.apple.com/guide/deployment/content-caching-metrics-dep0504346e1/web)

- **Discovery is public-IP-based, not Intune-group-based.** This is the single most common source of "it's configured correctly but nothing is happening" tickets. A client and its intended cache host must present the same public IP to the internet — VPN split-tunneling, multi-WAN setups, and guest/corporate network separation are the usual culprits, and none of them show up as an Intune configuration problem because there isn't one.

- **"Use only one profile" is a hard constraint, not a style preference.** Apple's payload spec explicitly warns that multiple Content Caching profiles on one device produce an error, unlike most Settings Catalog categories where the latest-assigned or most-restrictive value typically wins. Treat a second profile targeting the same device as a bug to fix, not layered configuration.

- **Manual/direct downloads bypass the cache regardless of configuration.** Apple Developer account downloads and other non-standard delivery paths are a known, permanent exception — don't spend triage time chasing why a specific manual download "isn't being cached" when it was never eligible.

- **The cache host can't serve while updating itself.** If the designated host Mac is mid-macOS-update, treat a temporary drop in caching activity as expected, not a fault — plan update timing for cache hosts deliberately (update the host first, then clients) to get the most caching benefit from a fleet-wide rollout, per Apple's own operational guidance.
