# Global Secure Access Client (macOS) — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers the **macOS-specific** deployment, architecture, and troubleshooting of the Microsoft Entra Global Secure Access (GSA) client — the platform this repo's existing `EntraID/Troubleshooting/GlobalSecureAccess-A.md`/`-B.md` explicitly named as an open gap ("non-Windows GSA client specifics ... have separate deployment mechanics").

Covers: macOS client installation (manual, Intune, and silent/scripted), the system extension + transparent application proxy architecture, MDM allow-listing requirements, the June 2025 bundle-identifier migration, macOS 26 compatibility, the built-in Health Check diagnostic chain, and macOS-specific known limitations.

**Assumes:**
- A Mac with an Intel, M1, M2, M3, or M4 processor running macOS 14 or later (hard floor — no exceptions, no fallback client)
- Device already registered to the tenant's Microsoft Entra ID through the Company Portal app
- Tenant already onboarded to Global Secure Access, with at least one traffic forwarding profile configured — this runbook does not cover tenant-side GSA setup, forwarding profile design, or Private Access connector architecture (see `EntraID/Troubleshooting/GlobalSecureAccess-A.md` for all of that)
- Microsoft Intune as the MDM, with instructions adaptable to other MDM solutions

**Not covered:** GSA tenant-side configuration (traffic forwarding profiles, Private Access connectors, Conditional Access "Compliant Network" design) — all in `EntraID/Troubleshooting/GlobalSecureAccess-A.md`/`-B.md`. Windows/Android/iOS GSA client specifics — each has a materially different installation and diagnostics surface. Explicit Forward Proxy (EFP) configuration — mentioned here only as a documented macOS incompatibility with the GSA client, not as its own topic.

---

## How It Works

<details><summary>Full architecture</summary>

The macOS GSA client is built on two Apple-native primitives, both of which must be independently approved before the client can do anything:

1. **A System Extension** (`com.microsoft.globalsecureaccess.tunnel`) — a Network Extension that gives the client visibility into network traffic without kernel extensions (Apple deprecated KEXTs; all modern network security tooling on macOS uses System/Network Extensions instead).
2. **A Transparent Application Proxy** — configured as a `com.apple.vpn.managed` payload with `VPNType: TransparentProxy` and `ProviderType: app-proxy`. This is what actually intercepts and redirects traffic matching the tenant's forwarding profile rules — it is a proxy configuration, not a traditional full-tunnel VPN, which is why split-tunneling (only GSA-designated traffic goes to the cloud edge, everything else goes direct) works natively without extra routing rules.

Both components require **explicit user or MDM approval** — Apple's Privacy & Security gatekeeping applies to network extensions the same way it applies to any other system extension, and there is no supported way to silently force-approve them outside of an MDM profile.

### Installation paths

| Path | Mechanism | Best for |
|---|---|---|
| Manual/interactive | Run the `.pkg`, click through installer, approve extension prompts by hand | One-off testing, small pilots |
| Silent/scripted | `sudo installer -pkg ~/Downloads/GlobalSecureAccessClient.pkg -target / -verboseR` | Deployment via any script-capable MDM or manual fleet push |
| Intune managed app | Upload the `.pkg` as a macOS app (PKG) type, assign to device/user groups | Standard MDM-managed fleets — the documented, supported path |

Silent and Intune-managed installs still require the **separate** MDM allow-listing step below — installing the package alone does not pre-approve the system extension or the transparent proxy. Skipping this step is the single most common "installed fine, does nothing" deployment mistake.

### MDM allow-listing (two independent profiles)

**Profile 1 — Allow System Extensions** (Settings Catalog → System Configuration → System Extensions → Allowed System Extensions):

| Bundle identifier | Team identifier |
|---|---|
| `com.microsoft.globalsecureaccess.tunnel` | `UBF8T346G9` |
| `com.microsoft.globalsecureaccess` | `UBF8T346G9` |

**Profile 2 — Allow transparent application proxy** (Custom profile, Device channel, uploading an `.xml` payload containing a `com.apple.vpn.managed` PayloadType with `ProviderType: app-proxy`, `ProviderBundleIdentifier: com.microsoft.globalsecureaccess.tunnel`, and a `ProviderDesignatedRequirement` string that pins the extension's code-signing identity, team ID (`UBF8T346G9`), and a specific certificate OID).

Microsoft's important callout in its own docs: **the older "Extensions" MDM profile type is deprecated** — any tenant still using it must migrate to the **Allowed System Extensions** setting inside **Settings Catalog**. This is a common source of "used to work, stopped after an Intune console update" tickets, since the deprecated profile type doesn't error, it just silently stops being effective for new devices.

### Bundle identifier migration (June 2025 — client version 1.1.25060400)

This is the single highest-impact architectural fact for any tenant that deployed GSA on macOS before mid-2025: **the distribution profile identifiers changed**, and Microsoft's own upgrade instructions require a specific, ordered sequence to avoid breaking devices:

| Component | Old identifier (pre-June 2025) | Current identifier |
|---|---|---|
| Main client | `com.microsoft.naas.globalsecure-df` | `com.microsoft.globalsecureaccess` |
| Tunnel extension | `com.microsoft.naas.globalsecure.tunnel-df` | `com.microsoft.globalsecureaccess.tunnel` |

If upgrading a fleet from client version `1.1.584.1` or older to `1.1.25060400` or newer, Microsoft's documented sequence is:
1. **Exclude** target Macs from any MDM policy still distributing the *old* client version first — installing old and new side-by-side on the same device breaks client behavior.
2. Deploy the **new** Allowed System Extensions and transparent-proxy-allow profiles using the *current* identifiers (both profile types support having two generations active simultaneously without conflict, as long as the old client itself isn't also installed).
3. Deploy a policy installing the new client version.
4. **Remove** the old allow-listing profiles using the deprecated identifiers.

Fleets that upgraded from any client version *newer* than `1.1.584.1` don't need this special sequence — they were already on the current identifiers. The practical trap: an MDM allow-listing profile authored before mid-2025 and never revisited will not approve a *fresh* install of the current client on a *new* device, even though existing already-approved devices keep working fine — producing a confusing pattern where only new hires or freshly re-imaged Macs hit "system extension blocked" tickets.

### macOS 26 compatibility floor

Client version **1.1.25070402** fixed a compatibility bug with macOS 26 that otherwise causes the device to **lose connectivity entirely** post-upgrade. Microsoft's explicit guidance: deploy this client version (or newer) **before** any managed Mac upgrades to macOS 26 — not after, and not "whenever it's convenient." Treat this identically to a driver/agent compatibility gate ahead of a Windows feature update: sequence the client update ahead of the OS update in your patch/update rings.

### Client statuses and menu-bar actions

| Status | Meaning |
|---|---|
| Initializing | Checking connection to GSA |
| Connected | Fully connected — all enabled channels reachable |
| Disabled | Services offline, or user manually disabled the client |
| Disconnected | Failed to connect entirely |
| Some channels are unreachable | Partial connectivity — at least one of Entra/M365/Private Access/Internet Access failed |
| Disabled by your organization | **Tenant-wide break-glass** — all traffic forwarding profiles are disabled; expected state, not a device fault |
| Private Access is disabled | User (if permitted) disabled Private Access specifically, to reach private apps directly over the corporate network instead |
| Could not connect to the Internet | No internet detected, or network requires captive-portal sign-in the client hasn't completed |

**Disable** and **Pause** both require the user to enter a business justification and re-authenticate — both actions are logged for tenant audit. Since the June 2025 release, **disabled state does not persist across a restart** — the client automatically re-enables itself after a reboot, a deliberate anti-persistence design choice worth knowing before assuming a user's "I disabled it and it stayed off" report is accurate.

Administrators can hide/show individual menu-bar buttons (`HideDisableButton`, `HidePauseButton`, `HideQuitButton`, `HideDisablePrivateAccessButton`) via an MDM preference-file profile targeting the `com.microsoft.globalsecureaccess` preference domain — useful for locking down user self-service on regulated fleets.

</details>

---

## Dependency Stack

```
User's traffic protected by Global Secure Access on this Mac
        │
        ▲ requires
Menu bar shows "Connected"
        │
        ▲ requires
Authentication succeeded (Entra ID token issued to this specific client install)
        │
        ▲ requires
Device registered to Entra ID via Company Portal
(GSA-specific prerequisite — separate from, but often bundled with, general MDM enrollment)
        │
        ▲ requires
Tenant-side: at least one Traffic Forwarding Profile enabled
(tenant-wide setting — not controllable from the device; "Disabled by your organization" = all profiles off)
        │
        ▲ requires
Transparent Proxy network service = Enabled
(System Settings → Network → Filters & Proxies — a Configuration Profile payload, not the client app itself)
        │
        ▲ requires
System Extension = [activated enabled]
(com.microsoft.globalsecureaccess.tunnel, Team ID UBF8T346G9)
        │
        ▲ requires
MDM "Allowed System Extensions" + "transparent app proxy" profiles delivered
(two independent Settings Catalog / Custom profiles — both required, neither implies the other)
        │
        ▲ requires
GSA client .pkg installed
(manual / silent / Intune-managed — installation alone does NOT self-approve extensions)
        │
        ▲ requires
macOS 14+ on Intel/M1/M2/M3/M4 hardware
(hard floor; macOS 26 additionally requires client ≥ 1.1.25070402)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Client installs but menu bar icon never appears connected | System extension never approved | `systemextensionsctl list \| grep globalsecureaccess` |
| "System Extension Blocked" dialog never resolves via MDM | MDM Allowed System Extensions profile missing, or using deprecated old bundle IDs | Compare profile's bundle IDs against current table; check for the deprecated "Extensions" profile type still in use |
| New hires/reimaged Macs fail extension approval; existing fleet fine | MDM allow-listing profile authored pre-June-2025 with old identifiers, never updated | `systemextensionsctl list` on a new device vs. an old one; compare profile content in Intune |
| Fleet lost GSA connectivity immediately after a macOS 26 rollout | Client version predates the mandatory `1.1.25070402` macOS 26 compatibility fix | Check client version vs. macOS version across the fleet |
| Client connected, but specific FQDN-based traffic isn't tunneling | Secure DNS (DoH/DoT) in use — client can't inspect plaintext DNS to match FQDN rules | `scutil --dns`, port-853 reachability test to configured resolvers |
| Menu bar shows "Disabled by your organization" | Tenant-wide break-glass — all traffic forwarding profiles disabled | Confirm with GSA tenant admin at Connect → Traffic forwarding — not a device issue |
| Client behind an outbound proxy fails intermittently | PAC file doesn't exclude GSA's own tunneled/diagnostic destinations | `networksetup -getautoproxyurl`, inspect PAC content |
| Certificate errors alongside GSA connectivity issues, EFP also in use | GSA client and Explicit Forward Proxy are documented as mutually incompatible on macOS | Confirm whether EFP is also configured for this fleet segment |
| Transparent Proxy toggle greyed out or missing in Network settings | MDM custom transparent-proxy-allow profile not delivered | Check Intune assignment for the custom `.xml` VPN payload profile |
| "Some channels are unreachable" — only Private Access affected | Private Access-specific issue (connector health) — not a macOS client problem | See `EntraID/Troubleshooting/GlobalSecureAccess-B.md` connector Symptom→Cause rows |
| User disabled the client; it's back on at next login without them re-enabling it | Expected behavior since June 2025 — disabled state does not persist across restart | Not a bug; confirm with user whether they expected persistence |

---

## Validation Steps

**1. Confirm macOS version and hardware meet the floor**
```bash
sw_vers -productVersion
sysctl -n machdep.cpu.brand_string
```
Expected: macOS 14.0+, Intel or Apple Silicon (M1–M4). Below 14.0 is a hard stop — no client will install successfully.

**2. Confirm the installed client version against the macOS version**
```bash
defaults read "/Applications/GlobalSecureAccessClient/Global Secure Access Client.app/Contents/Info.plist" CFBundleShortVersionString
```
Expected: on macOS 26+, version `1.1.25070402` or newer. Anything older on macOS 26 is a known-broken combination, not a maybe.

**3. Confirm the system extension is installed and active**
```bash
systemextensionsctl list | grep -E '.*com\.microsoft\.(naas\.globalsecure|globalsecureaccess).*'
```
Expected: an entry ending in `[activated enabled]`. Anything else (missing entirely, or missing `enabled`) means the extension isn't functioning regardless of what the installer reported.

**4. Confirm the Transparent Proxy service is enabled**
```bash
scutil --nc list
```
Cross-check visually at **System Settings → Network → Filters & Proxies** — the GSA entry's Status column must read **Enabled**.

**5. Confirm authentication and forwarding profile currency**
Open the GSA menu bar icon → **Settings** → **Troubleshooting** → **Advanced Diagnostics Tool** → **Health Check** tab. Work top to bottom; most tests gate on the one above them (Notifications → System extension → Transparent proxy → interface/tunnel → DNS → Authentication → Forwarding profile cached → Break-glass → Proxy configured → Internet reachable → Diagnostic URLs → Edges reachable → Tunneling succeeded).

**6. Confirm DNS isn't encrypted in a way that blocks FQDN rules**
```bash
scutil --dns | grep 'nameserver\[[0-9]*\]'
nc -zv <each-resolver-ip> 853
```
Expected: port 853 connection **refused/closed** for each resolver. A successful connection means that resolver is running encrypted DNS and FQDN-based forwarding rules will silently fail to match for traffic using it.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Eligibility.** Confirm macOS 14+, supported hardware, and (if applicable) the macOS 26 client-version floor before assuming any config-level issue. A pre-14 Mac or a stale client on macOS 26 is not fixable at the config layer — it requires an OS or client version change first.

**Phase 2 — Installation.** Confirm the `.pkg` actually installed (`ls -d "/Applications/GlobalSecureAccessClient"`) via whichever path was used (manual, silent, Intune). Installation success alone proves nothing about extension or proxy approval — treat it as necessary, not sufficient.

**Phase 3 — MDM allow-listing.** Confirm both the Allowed System Extensions profile and the transparent-app-proxy custom profile are assigned and reported as **Succeeded** in Intune for this device. If either is missing, stop here — nothing downstream will work regardless of client version or network state.

**Phase 4 — Extension and proxy activation.** Run the Validation Steps 3–4 above. If the extension shows `[activated enabled]` but the proxy doesn't, or vice versa, remember these are two **independently** gated components — fixing one does not fix the other.

**Phase 5 — Authentication and forwarding.** Run the built-in Health Check. Confirm the device is Entra-registered (`profiles status -type enrollment`) — GSA has its own authentication requirement layered on top of general MDM enrollment, and a device can be MDM-enrolled without being Entra-registered in a way GSA accepts.

**Phase 6 — Network-path specifics.** Only after Phases 1–5 pass, investigate DNS encryption, proxy/PAC exclusions, and EFP coexistence — these affect specific traffic categories rather than the client's overall connected state, and chasing them before confirming the client is even connected wastes time.

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Fresh managed deployment (net-new fleet, current client)</summary>

1. Download `GlobalSecureAccessClient.pkg` from **Microsoft Entra admin center → Global Secure Access → Connect → Client download → macOS tab**.
2. Create the Intune **macOS app (PKG)** entry: Apps → All Apps → Create → Other → macOS app (PKG). Set minimum OS to macOS 14.0 on the Requirements tab.
3. Create the **Allowed System Extensions** Settings Catalog profile with both current bundle/team ID pairs (see How It Works table).
4. Create the **transparent application proxy** Custom profile (Device channel) using Microsoft's published `.xml` payload, substituting nothing except assignment scope — the `ProviderDesignatedRequirement` string must match exactly.
5. Assign all three (app + 2 profiles) to the same device/user groups, in the same rollout wave, so a device never receives the client without also receiving both allow-listing profiles.
6. Validate on a pilot device using Validation Steps 1–6 before wider assignment.

**Rollback:** remove app assignment; both profiles can be safely left in place (they only grant capability, they don't install anything themselves).

</details>

<details>
<summary>Playbook 2 — Migrating a pre-June-2025 fleet to current bundle identifiers</summary>

Follow Microsoft's documented order exactly — deviating from this sequence (e.g., installing the new client before excluding old-client policies) is the documented cause of side-by-side-install breakage:

1. **Exclude** target devices from any MDM policy currently distributing the *old* client version (pre-`1.1.25060400`).
2. Deploy new **Allowed System Extensions** and **transparent app proxy** profiles using the *current* identifiers (`com.microsoft.globalsecureaccess` / `com.microsoft.globalsecureaccess.tunnel`) — these can coexist with the old profiles temporarily.
3. Deploy a policy installing the **new** client version to the same devices.
4. Once confirmed working (Validation Steps 3–4 show the new identifiers active), **remove** the old allow-listing profiles referencing the deprecated `naas.globalsecure` / `naas.globalsecure.tunnel` identifiers.

**Rollback:** if the new client causes regressions, re-assign the old client policy and old allow-listing profiles to the affected devices, then remove the new client — since both profile generations can coexist, this is reversible without a full re-image, provided you haven't yet uninstalled the old client's supporting profiles from step 4.

</details>

<details>
<summary>Playbook 3 — Pre-macOS-26 upgrade readiness sweep</summary>

1. Inventory current GSA client versions across the macOS fleet (see `Get-GSAmacOSHealth.sh` in this topic's Scripts companion — run against a device sample, or query via your MDM's app-version reporting).
2. Identify any device running a client version older than `1.1.25070402`.
3. Push a client update to those devices via the existing Intune app assignment (update the assigned `.pkg` to the current version — Intune handles in-place upgrade automatically since the installer supports upgrades).
4. Confirm the update landed (Validation Step 2) **before** that device's macOS 26 feature update deployment ring executes — sequence the client update ring ahead of the OS update ring, the same way you'd sequence any other pre-upgrade compatibility gate.

**Rollback:** the client installer supports downgrade via the installation wizard's standard install path (run an older `.pkg`) if a regression appears — no data loss, since the client holds no user data, only cached auth/forwarding-profile state that's rebuilt automatically.

</details>

---

## Evidence Pack

Run as a normal user; escalate to root only if a specific check requires it (the script prompts).

```bash
#!/bin/bash
# GSA macOS Evidence Pack — paste output into escalation ticket
echo "=== macOS / Hardware ==="
sw_vers -productVersion
sysctl -n machdep.cpu.brand_string

echo "=== GSA Client Version ==="
defaults read "/Applications/GlobalSecureAccessClient/Global Secure Access Client.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "Client not found at expected path"

echo "=== System Extension State ==="
systemextensionsctl list | grep -E '.*com\.microsoft\.(naas\.globalsecure|globalsecureaccess).*'

echo "=== Network Service / Transparent Proxy ==="
scutil --nc list

echo "=== MDM Enrollment ==="
profiles status -type enrollment

echo "=== DNS Resolvers ==="
scutil --dns | grep 'nameserver\[[0-9]*\]'

echo "=== Proxy Auto-Config (if any) ==="
networksetup -getautoproxyurl "Wi-Fi" 2>/dev/null
networksetup -getautoproxyurl "Ethernet" 2>/dev/null

echo "=== Basic Internet Reachability (non-GSA test) ==="
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://www.msftconnecttest.com/connecttest.txt
```

For a full support-ready archive, always additionally use the client's own **Collect Logs** action (menu bar icon → Collect Logs) — it captures tunnel and UI process logs the shell commands above cannot access.

---

## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `sw_vers -productVersion` | Confirm macOS version against the 14.0 hard floor (26.0 against the client-version floor) |
| `sysctl -n machdep.cpu.brand_string` | Confirm supported processor (Intel/M1–M4) |
| `systemextensionsctl list \| grep globalsecureaccess` | Confirm system extension is `[activated enabled]` |
| `scutil --nc list` | Confirm Transparent Proxy network service state |
| `profiles status -type enrollment` | Confirm MDM enrollment (GSA's own auth prerequisite) |
| `scutil --dns \| grep nameserver` | List active DNS resolvers |
| `nc -zv <ip> 853` | Test whether a resolver enforces DNS-over-TLS (port open = encrypted) |
| `networksetup -getautoproxyurl "Wi-Fi"` | Check for a configured PAC file that might not exclude GSA destinations |
| `curl http://www.msftconnecttest.com/connecttest.txt` | Confirm basic internet reachability, independent of GSA |
| `defaults read ".../Info.plist" CFBundleShortVersionString` | Read installed GSA client version |
| Menu bar → Settings → Troubleshooting → Advanced Diagnostics → Health Check | Full interdependent diagnostic chain — always resolve top to bottom |
| Menu bar → Collect Logs | Export a support-ready `.zip` of tunnel + UI logs |
| Menu bar → Settings → Troubleshooting → Get Latest Policy | Force a fresh forwarding-profile pull without a full re-auth |
| Menu bar → Settings → Troubleshooting → Clear cached data | Wipe cached auth/forwarding-profile/FQDN/IP state, forces re-authentication |

---

## 🎓 Learning Pointers

- **System extension approval and transparent proxy enablement are two independently-gated components, not one.** Treating "the client is installed" as equivalent to "the client is working" is the most common root-cause miss for this topic — always validate both separately. See [Install the Global Secure Access client for macOS](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-install-macos-client).

- **The June 2025 bundle-identifier rename is a real migration, not a cosmetic version bump.** Any MDM allow-listing profile authored before then needs the documented four-step exclude → deploy-new → deploy-client → remove-old sequence, or new devices will fail extension approval while the existing fleet keeps working — a confusing, hard-to-diagnose split if you don't know to look for it.

- **macOS 26 has its own client-version compatibility floor, separate from the general macOS-14 minimum.** Sequence GSA client updates ahead of macOS feature-update deployment rings, exactly as you would any other pre-upgrade driver/agent compatibility check.

- **The Health Check tab's tests are deliberately ordered and interdependent** — Microsoft's own guidance is to resolve failures strictly top-to-bottom. Jumping to a test further down the list (like Tunneling succeeded) when an earlier one (System extension) is failing wastes time chasing a downstream symptom. See [Troubleshoot the macOS GSA client: Health check](https://learn.microsoft.com/en-us/entra/global-secure-access/troubleshoot-global-secure-access-client-macos-health-check).

- **"Disabled by your organization" is a tenant-wide state, not a device state.** It means every traffic forwarding profile is disabled in the portal — confirm with the tenant's GSA administrator before spending device-level troubleshooting time on it.

- **GSA and Explicit Forward Proxy (EFP) do not coexist on macOS today** — this is a documented Microsoft limitation (client certificate conflicts), not a misconfiguration to chase. See [Known limitations for Global Secure Access](https://learn.microsoft.com/en-us/entra/global-secure-access/reference-current-known-limitations).
