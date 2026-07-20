# Global Secure Access Client (macOS) — Hotfix Runbook (Mode B: Ops)
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

Run these immediately to classify the issue:

```bash
# 1. macOS version and processor — hard prerequisite floor
sw_vers -productVersion
sysctl -n machdep.cpu.brand_string

# 2. Client system extension activation state
systemextensionsctl list | grep -i "globalsecureaccess\|naas.globalsecure"

# 3. Transparent Proxy service state (Network > Filters & Proxies)
scutil --nc list 2>/dev/null | grep -i "globalsecureaccess\|proxy"

# 4. Is the device MDM-enrolled and registered to Entra? (GSA requires both)
profiles status -type enrollment

# 5. Confirm secure DNS is NOT overriding the resolver (breaks FQDN-based tunneling)
scutil --dns | grep 'nameserver\[[0-9]*\]'
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| `sw_vers` < 14.0 | Below GSA client's hard minimum (macOS 14) | Not eligible — upgrade macOS first, no client workaround |
| `systemextensionsctl list` shows no GSA line | System extension never approved or not installed | → Fix 1 |
| Line present but not `[activated enabled]` | Extension blocked in Privacy & Security | → Fix 1 |
| Transparent Proxy shows `Disabled` in Network settings | Proxy service toggled off — client can install but won't tunnel anything | → Fix 2 |
| `profiles status` shows no MDM enrollment | GSA requires Entra registration via Company Portal — not optional | Re-enroll before anything else |
| Menu bar icon shows **Disconnected** or **Some channels are unreachable** | Partial or full connectivity failure to the GSA edge | → Diagnosis Flow, then Fix 3/4 |
| Menu bar icon shows **Disabled by your organization** | All traffic forwarding profiles are unchecked tenant-wide (break-glass) — expected state, not a device bug | Confirm with tenant admin before treating as a fault |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
User's traffic is tunneled/protected by Global Secure Access
        │
        ▼
GSA client shows "Connected" in the menu bar
        │
        ▼
Authentication succeeded (Entra ID token issued to the client)
        │
        ▼
Device registered to Entra ID via Company Portal (prerequisite — not optional)
        │
        ▼
At least one Traffic Forwarding Profile enabled tenant-wide
(Microsoft 365 / Private Access / Internet Access — "break-glass" = all disabled)
        │
        ▼
Client's System Extension is installed AND approved
(com.microsoft.globalsecureaccess.tunnel — Team ID UBF8T346G9)
        │
        ▼
Transparent Proxy network service is Enabled
(System Settings → Network → Filters & Proxies)
        │
        ▼
macOS 14+ on Intel/M1/M2/M3/M4 hardware (hard floor — no exceptions)
        │
        ▼
DNS resolver is NOT using DNS-over-HTTPS/TLS
(client must see plaintext DNS to match FQDN-based forwarding rules)
        │
        ▼
No conflicting proxy/PAC config tunneling GSA's own destinations elsewhere
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the client version supports the installed macOS version**

```bash
defaults read "/Applications/GlobalSecureAccessClient/Global Secure Access Client.app/Contents/Info.plist" CFBundleShortVersionString
sw_vers -productVersion
```

If macOS is version 26 or later, the client **must** be version `1.1.25070402` or newer — earlier versions have a documented macOS 26 compatibility bug that drops connectivity entirely. This is the single most common "worked before the OS update, broken after" pattern for this client.

Bad: client version older than `1.1.25070402` on macOS 26+ → upgrade the client first, before troubleshooting anything else.

---

**Step 2 — Confirm the system extension is active**

```bash
systemextensionsctl list | grep -E '.*com\.microsoft\.(naas\.globalsecure|globalsecureaccess).*'
```

Expected output contains `[activated enabled]`, e.g.:
```
UBF8T346G9    com.microsoft.globalsecureaccess.tunnel (1.1.x/1.1.x)    Global Secure Access Network Extension    [activated enabled]
```

Bad: no line at all, or missing `enabled` → the system extension was never approved (manual install) or the MDM **Allowed System Extensions** profile hasn't landed (managed install). → Fix 1.

---

**Step 3 — Confirm the Transparent Proxy network service is enabled**

```bash
scutil --nc list
```

Bad: no Global Secure Access entry, or an entry with a disabled/inactive state → open **System Settings → Network → Filters & Proxies** and confirm the Global Secure Access Transparent Proxy status is **Enabled**. → Fix 2.

---

**Step 4 — Confirm authentication and forwarding profile are current**

Open the GSA menu bar icon → **Settings** → **Troubleshooting** tab → **Advanced Diagnostics Tool** → **Health Check** tab. Resolve failed tests top-to-bottom — most tests are interdependent (system extension must pass before proxy tests are meaningful, which must pass before authentication/tunneling tests are meaningful).

If **Authentication succeeded** fails specifically:
```bash
# Confirm device is Entra-registered (GSA requires it — not just MDM-enrolled)
profiles status -type enrollment
```
Then check **Entra ID admin center → Devices → Overview** for this device's registration state and **Audit logs** for recent sign-in/auth failures.

---

**Step 5 — Confirm secure DNS isn't blocking FQDN-based tunneling**

```bash
scutil --dns | grep 'nameserver\[[0-9]*\]'
```

Then, for each resolver IP returned, confirm port 853 (DNS-over-TLS) is closed:
```bash
nc -zv <resolver-ip> 853
```

If the connection *succeeds*, that DNS server is encrypted and the client cannot inspect FQDN-based forwarding rules for traffic using it. → Fix 4.

---

**Step 6 — Rule out a proxy/PAC conflict**

If the Mac is behind an outbound proxy (browser-level or OS-level), confirm the PAC file explicitly excludes GSA's own destinations — otherwise GSA traffic gets double-tunneled (once by GSA, once by the proxy) and typically fails outright.

```bash
networksetup -getautoproxyurl "Wi-Fi"
```

→ Fix 5 if a PAC URL is configured and doesn't exclude `*.edgediagnostic.globalsecureaccess.microsoft.com` and your tenant's tunneled FQDNs.

---

## Common Fix Paths

<details>
<summary>Fix 1 — System extension blocked or never approved</summary>

**When:** `systemextensionsctl list` shows no GSA entry, or shows one without `enabled`.

Manual (interactive) install:
1. From the GSA menu bar icon, check for an **Allow Network Extension** option — select it if present.
2. If not present or it doesn't resolve the issue: **System Settings → Privacy & Security** → scroll to the **Security** section → look for a blocked-extension message referencing Global Secure Access → select **Allow**.
3. Re-check:
```bash
systemextensionsctl list | grep -i globalsecureaccess
```

Managed (MDM) install — the extension must be pre-approved via an **Allowed System Extensions** Settings Catalog profile with both bundle/team ID pairs:

| Bundle identifier | Team identifier |
|---|---|
| `com.microsoft.globalsecureaccess.tunnel` | `UBF8T346G9` |
| `com.microsoft.globalsecureaccess` | `UBF8T346G9` |

If the profile predates June 2025, confirm it uses the **current** identifiers above — the client's June 2025 release (`1.1.25060400`) renamed both bundle identifiers from `com.microsoft.naas.globalsecure-df` / `com.microsoft.naas.globalsecure.tunnel-df`. A profile still targeting the old identifiers will not approve a current client install. See the Deep Dive's "Bundle identifier migration" section before assuming this is a fresh deployment issue.

**Rollback note:** none — approving the extension only grants a capability the client already requested; it makes no other system change.

</details>

<details>
<summary>Fix 2 — Transparent Proxy service disabled</summary>

**When:** `scutil --nc list` shows no active GSA proxy entry, or Health Check's **Transparent proxy service** test fails.

1. **System Settings → Network → Filters & Proxies**.
2. Confirm the **Global Secure Access Transparent Proxy** entry's **Status** is **Enabled**. Toggle it on if not.
3. If the toggle is missing entirely (not just disabled), the MDM **transparent application proxy** custom profile (VPN payload, `ProviderType: app-proxy`) hasn't landed — check Intune assignment for the custom configuration profile carrying `com.microsoft.globalsecureaccess` as its `VPNSubType`.
4. Re-check:
```bash
scutil --nc list
```

**Rollback note:** re-disabling the proxy stops all GSA traffic acquisition immediately — only do this deliberately (e.g., isolating a network issue), not as a "try turning it off and on" step without cause.

</details>

<details>
<summary>Fix 3 — Client disconnected / "Some channels are unreachable"</summary>

**When:** Menu bar shows **Disconnected** or **Some channels are unreachable** (at least one of Entra/M365/Private Access/Internet Access failed).

1. Right-click the GSA menu bar icon → **Restart**.
2. If that doesn't clear it, from **Settings → Troubleshooting**: select **Get Latest Policy** to force a fresh forwarding profile pull.
3. If still failing, select **Clear cached data** (removes cached auth/forwarding-profile/FQDN/IP state), then sign in again.
4. Confirm basic internet reachability independent of GSA:
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://www.msftconnecttest.com/connecttest.txt
```
A non-`200` result here means the underlying network is the problem, not GSA — stop troubleshooting the client and check the network path first.
5. If only specific channels fail, run the built-in **Advanced Diagnostics → Health Check** and resolve the first failing test — most subsequent tests are gated on it.

**Rollback note:** **Clear cached data** forces re-authentication and a fresh forwarding-profile download — expected user impact is a single sign-in prompt, no data loss.

</details>

<details>
<summary>Fix 4 — Secure DNS (DoH/DoT) blocking FQDN-based rules</summary>

**When:** Step 5 of Diagnosis shows an encrypted resolver, and the tenant's forwarding profile includes FQDN-based rules (most Internet Access profiles do).

The GSA client can only match FQDN-based tunneling rules if it can read plaintext DNS queries. If the network's configured DNS server enforces DNS-over-TLS/HTTPS at the OS level:

1. Change the Mac's DNS servers (**System Settings → Network → Wi-Fi/Ethernet → Details → DNS**) to a resolver that responds on standard port 53 without enforced encryption, or
2. If DNS is pushed via MDM/DHCP and can't be changed org-wide, this becomes a tenant-level design decision (IP-based forwarding rules don't have this dependency) — escalate to whoever owns the traffic forwarding profile design rather than continuing device-level troubleshooting.

**Rollback note:** none — this only affects which forwarding rules the client can match, not connectivity itself.

</details>

<details>
<summary>Fix 5 — Proxy/PAC file doesn't exclude GSA destinations</summary>

**When:** Step 6 of Diagnosis finds a PAC URL configured and GSA's own diagnostic/tunneled destinations aren't excluded.

Add explicit `DIRECT` exceptions to the PAC file for:
- `.edgediagnostic.globalsecureaccess.microsoft.com` (health-probing — required for the client to report status correctly)
- Every FQDN/IP your tenant's forwarding profile tunnels to GSA

```javascript
function FindProxyForURL(url, host) {
    if (isPlainHostName(host) ||
        dnsDomainIs(host, ".edgediagnostic.globalsecureaccess.microsoft.com") ||
        dnsDomainIs(host, ".contoso.com"))
       return "DIRECT";
    else
       return "PROXY 10.1.0.10:8080";
}
```

Without these exclusions, GSA-tunneled HTTP(S) requests get routed to the outbound proxy instead of the GSA client, and typically fail or silently bypass GSA protection entirely.

**Rollback note:** none — this only widens the DIRECT exception list, no destinations are removed from proxy coverage.

</details>

<details>
<summary>Fix 6 — Coexistence conflict with Explicit Forward Proxy (EFP)</summary>

**When:** Tenant also uses Explicit Forward Proxy (preview) and the Mac experiences client certificate errors alongside GSA connectivity issues.

This is a documented Microsoft limitation, not a misconfiguration: **on macOS, GSA client and EFP settings cannot coexist** due to client certificate conflicts. There is no supported fix at the device level — the tenant must choose one mechanism per macOS fleet segment (GSA client tunneling, or EFP's PAC-file-based explicit proxy) rather than running both simultaneously on the same devices.

**Rollback note:** N/A — this is an architecture decision, escalate to whoever owns the GSA/EFP rollout plan.

</details>

---

## Escalation Evidence

```
=== GSA macOS Client Escalation Package ===
Date/Time:            ___________
Device Name:          ___________
macOS Version:        ___________  (sw_vers -productVersion)
Processor:            ___________  (Intel / M1 / M2 / M3 / M4)
GSA Client Version:   ___________  (About, from menu bar)
User UPN:             ___________
Entra Device ID:      ___________  (Company Portal → Device Details)
MDM Enrolled:         Yes / No
Menu Bar Status:      Connected / Disconnected / Some channels unreachable / Disabled by org / Private Access disabled

=== Commands Output (paste results) ===

systemextensionsctl list | grep globalsecureaccess:
[PASTE]

scutil --nc list:
[PASTE]

profiles status -type enrollment:
[PASTE]

scutil --dns | grep nameserver:
[PASTE]

=== Health Check Tab Results (Advanced Diagnostics) ===
[PASTE — list each test and Pass/Fail]

=== Error Description ===
- User reports: ___________
- Started occurring: ___________ (tie to any recent macOS/client update)
- Affects all traffic / specific channel (M365, Private Access, Internet Access): ___________
- Behind a corporate outbound proxy: Yes / No

=== Steps Already Tried ===
[ ] Restart client from menu bar
[ ] Get Latest Policy
[ ] Clear cached data + re-authenticate
[ ] Confirmed non-GSA internet reachability (msftconnecttest.com)
[ ] Collected logs via menu bar → Collect Logs
[ ] Other: ___________
```

Attach the **Collect Logs** `.zip` (menu bar icon → **Collect Logs**) to any Microsoft Support escalation — it captures both the tunnel and UI process logs in one archive.

---

## 🎓 Learning Pointers

- **The client's own "Disabled by your organization" status is not a device fault.** It means every traffic forwarding profile is unchecked tenant-wide — Microsoft's own documented "break-glass" state. Confirm with whoever owns **Global Secure Access → Connect → Traffic forwarding** before spending time on device-level diagnosis. See [Known limitations for Global Secure Access](https://learn.microsoft.com/en-us/entra/global-secure-access/reference-current-known-limitations).

- **The June 2025 bundle-identifier rename is a real deployment trap for orgs that built their MDM profiles before then.** Old identifiers (`com.microsoft.naas.globalsecure-df` / `.tunnel-df`) still work for already-installed clients but won't approve a *new* install — see the Deep Dive's Bundle Identifier Migration section before troubleshooting a "system extension won't approve" ticket as a one-off.

- **macOS 26 has a hard version floor on the client, not just macOS.** Deploying the OS update without first confirming client version `1.1.25070402`+ is a documented way to lose GSA connectivity fleet-wide. Treat this the same way you'd treat a driver compatibility check before a Windows feature update.

- **The Health Check tab's tests are ordered and interdependent — always fix top-to-bottom, never skip to the test that "looks most related."** A DNS or tunneling test failing further down the list is frequently a downstream symptom of the system extension or proxy test failing above it. See [Troubleshoot the macOS GSA client: Health check](https://learn.microsoft.com/en-us/entra/global-secure-access/troubleshoot-global-secure-access-client-macos-health-check).

- **Secure DNS (DoH/DoT) silently breaks FQDN-based rules with no client-side error** — it just looks like intermittent tunneling failures for specific destinations. This is easy to miss because IP-based rules keep working fine, making the failure look inconsistent rather than systemic.

- **GSA and Explicit Forward Proxy (EFP) are mutually exclusive on macOS today** — not a misconfiguration to troubleshoot, but a real platform limitation. Don't spend escalation time chasing certificate errors that are actually this known coexistence gap.
