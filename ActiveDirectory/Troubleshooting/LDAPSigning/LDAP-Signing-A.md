# LDAP Signing & Channel Binding — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- LDAP signing (`LDAPServerIntegrity` / client-side `LDAPClientIntegrity`) — the requirement that LDAP binds be cryptographically signed
- LDAP channel binding (`LdapEnforceChannelBinding`) — the requirement that an LDAPS/StartTLS bind carry a Channel Binding Token (CBT) tying the LDAP session to the specific TLS session it rides on
- The relay attack this hardening exists to close (NTLM relay to LDAP, used to escalate a captured/relayed NTLM authentication into arbitrary AD write access)
- Diagnostics logging (Event 2886/2887/2889, Event 3039/3040) for identifying non-compliant clients before tightening enforcement
- Remediation playbooks for phased rollout, legacy-device exceptions, and TLS-terminating proxy conflicts

**Out of scope:**
- LDAPS certificate deployment/renewal itself (issuing and binding the certificate a DC uses for port 636 — this topic assumes a valid LDAPS certificate is already installed; see your PKI/Certificate Services runbooks for issuance)
- SMB signing / SMB relay (a parallel but architecturally separate relay-mitigation control on a different protocol — see `Windows/Troubleshooting/SMB-A.md`)
- NTLM relay mitigations outside the LDAP protocol specifically (e.g., Extended Protection for Authentication on IIS/other services) — this topic covers the LDAP-specific control only
- Entra ID / Entra Domain Services LDAP behavior — this topic is on-premises AD DS `NTDS.dit`-backed domain controllers only; Entra Domain Services has its own, separately-managed secure LDAP configuration (see `EntraID/Troubleshooting/EntraDomainServices-A.md`)

**Assumptions:**
- Domain controllers are Windows Server, with the `ActiveDirectory` PowerShell module available for querying and the standard `Directory Service` Windows Event Log
- You have local administrator rights on the DC(s) in question to read/set `HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters` and `HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics`
- At least one DC is reachable for diagnostics logging and event log review before any enforcement change is made

---
## How It Works

<details><summary>Full architecture — why this hardening exists and how the two controls interact</summary>

### The Attack This Closes

LDAP, by default, supports **simple binds** — a plaintext username/password (or an anonymous bind) sent to the DC with no cryptographic signing of the session. Separately, many environments still accept NTLM authentication somewhere in the environment. An attacker who can capture or relay an NTLM authentication attempt (via a man-in-the-middle position, a poisoned name resolution response, or a coerced authentication from a vulnerable service) can relay that captured authentication straight into an **unsigned LDAP bind** against a domain controller — effectively authenticating to AD as the relayed identity and then using LDAP write operations to escalate: adding themselves to a privileged group, resetting a password, or creating a new privileged object. This is the LDAP variant of the broader NTLM relay attack class, and it was significant enough that Microsoft published dedicated guidance and security updates (beginning with the March 2020 update, commonly referenced as KB4520412) specifically to close it.

Two independent controls close two independent parts of this gap:

1. **LDAP signing** — requires every LDAP bind (regardless of transport) to be cryptographically signed, which defeats a relay attack because the attacker cannot forge a valid signature for a session it doesn't actually hold the underlying credential material for in a replayable form.
2. **LDAP channel binding** — specifically for binds over LDAPS (636) or StartTLS, requires the bind to carry a **Channel Binding Token (CBT)**, a value cryptographically derived from the specific TLS channel the bind rides on. This closes a *narrower* variant of the same relay attack where signing alone over TLS wasn't sufficient, by cryptographically tying the authenticated LDAP session to the one TLS tunnel it was negotiated inside — a relayed session negotiated over a *different* TLS tunnel produces a mismatched CBT and is rejected.

Signing and channel binding are **independently configured and independently enforced** — a DC can require one, both, or neither, and a client can fail against either control separately with a different symptom.

### LDAP Signing — `LDAPServerIntegrity` (server) / `LDAPClientIntegrity` (client)

Server-side enforcement lives at `HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters\LDAPServerIntegrity` (DWORD):
- `0` — **None.** Signing is neither offered nor required. Effectively the pre-hardening legacy posture; should not exist on any production DC today.
- `1` — **Negotiate signing.** The DC will *use* signing if the client offers it (Kerberos/SASL-based binds negotiate this transparently), but will still *accept* an unsigned simple bind. This has historically been the common default posture — it's permissive by design, and its danger is that it hides the exposure: unsigned binds succeed silently, with only a periodic Event 2887 summary count as the visible signal that anything insecure is happening.
- `2` — **Require signing.** Any bind that isn't signed is rejected outright with an LDAP bind failure. This is the actual security boundary; `1` is a monitoring/transition state, not a control.

The client-side equivalent, `HKLM:\SYSTEM\CurrentControlSet\Services\LDAP\LDAPClientIntegrity`, governs whether a Windows client *offers* signing when it initiates a bind — relevant for scripts/tools running on Windows hosts (not for third-party/non-Windows LDAP clients, which have their own, vendor-specific configuration surface entirely outside this registry key).

Kerberos-authenticated binds (the normal path for domain-joined Windows clients and AD-integrated apps using SSPI/Negotiate) sign transparently as part of the Kerberos/SASL exchange and are unaffected by moving to `Require` — the clients actually broken by tightening this setting are almost always **simple binds**: legacy LOB apps, third-party LDAP address-book integrations (older printers, scanners, fax-to-email gateways), non-Windows/non-Kerberos-aware LDAP client libraries, and scripts hardcoding a plaintext bind DN and password.

### LDAP Channel Binding — `LdapEnforceChannelBinding`

Server-side enforcement lives at `HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters\LdapEnforceChannelBinding` (DWORD), and only applies to binds over LDAPS (636) or StartTLS — a plaintext LDAP bind on port 389 has no TLS channel to bind to, so this control is a no-op for that transport (which is exactly why signing, not channel binding, is the control that matters for port 389 traffic):
- `0` — **Never.** No CBT required, regardless of client capability.
- `1` — **When supported.** If the connecting client's LDAP library sends a CBT, the DC validates it; if the client doesn't send one at all, the bind is still accepted. Like signing's `Negotiate` state, this is a transition/monitoring posture, not an enforced boundary.
- `2` — **Always.** A bind over LDAPS/StartTLS with no CBT present, or a CBT that doesn't match the actual TLS session, is rejected outright — even though the underlying TLS connection itself is completely valid and trusted.

### Why a TLS-Terminating Proxy Breaks Channel Binding By Design

Because a CBT is cryptographically derived from the specific TLS session's own certificate/handshake material, any device that **terminates** TLS between the client and the DC and re-establishes a separate TLS session onward to the DC — a load balancer, a reverse proxy, certain network security appliances doing TLS inspection — necessarily breaks the CBT's validity. The client's CBT was computed against the TLS session it held with the proxy; the DC sees a different TLS session (proxy-to-DC) and the token doesn't match. This is not a bug to patch around; it's the intended, correct behavior of channel binding. The only architecturally sound fixes are: remove the TLS-terminating hop from the LDAPS path (use a Layer-4/pass-through load balancer instead, if load balancing DCs is genuinely required), or point the client directly at a DC.

### The Long, Repeatedly-Delayed Rollout Timeline

Microsoft's original published intent (2020) was to move both settings to their strict values (`Require`/`Always`) as the **default** for all Windows Server domain controllers in a future update, giving administrators an explicit warning window via the Event 2886/2887 (signing) and Event 3039/3040 (channel binding) diagnostic events in the interim. That default-enforcement date has been pushed back multiple times across subsequent Windows releases, and administrators should **not** treat "we haven't proactively touched this setting" as evidence the domain is unenforced — the effective default varies by OS build and update level, and depending on the exact patch level a DC is running, it may already be more strict than an administrator assumes. Always query the actual registry values (Validation Step 1) rather than relying on memory of what the "default" is supposed to be.

Regardless of Microsoft's own default-enforcement timeline, this hardening should be treated as effectively mandatory from a security-posture standpoint — the relay attack it closes is well understood, has been used in real-world compromise chains, and delaying deliberate enforcement only accumulates more undiscovered non-compliant clients to remediate later.

</details>

---
## Dependency Stack

```
Client initiates an LDAP bind against a DC
  ├── Port 389 (plaintext LDAP) or StartTLS upgrade
  │     └── LDAP SIGNING is the only relevant control on this path
  │           ├── LDAPServerIntegrity = 0 (None)      — unsigned binds fully accepted, no logging signal
  │           ├── LDAPServerIntegrity = 1 (Negotiate)  — unsigned accepted, Event 2887 counts it
  │           └── LDAPServerIntegrity = 2 (Require)    — unsigned binds REJECTED
  │
  └── Port 636 (LDAPS) or completed StartTLS upgrade
        ├── LDAP SIGNING still applies (same three states as above)
        └── LDAP CHANNEL BINDING additionally applies (TLS-transport-only)
              ├── LdapEnforceChannelBinding = 0 (Never)          — CBT never required
              ├── LdapEnforceChannelBinding = 1 (When supported) — CBT validated if present, not required
              └── LdapEnforceChannelBinding = 2 (Always)         — bind REJECTED without a valid, matching CBT
                    └── REQUIRES: TLS session is not terminated by an intermediary
                          (proxy/load balancer termination invalidates every CBT behind it)
```

Both controls are evaluated per-DC (the registry values live on each DC individually, though typically deployed uniformly via GPO/security baseline across all DCs in a domain) and per-bind — there is no domain-wide single toggle outside of consistent GPO deployment.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| App/service suddenly can't bind to AD after a DC reboot, patch cycle, or GPO/security-baseline push, no config change made to the app itself | `LDAPServerIntegrity` moved from `1`/`0` to `2` (Require) on the DC(s) the app talks to | `Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters -Name LDAPServerIntegrity` on the affected DC |
| Bind fails specifically over LDAPS (636)/StartTLS but works fine over plaintext 389 | `LdapEnforceChannelBinding` is `2` (Always) and the client isn't sending a CBT | Check client library version/CBT support; confirm no TLS-terminating device sits in the path |
| Bind works for some users/apps but fails for others hitting the "same" DC name | DNS round-robin or a load balancer is actually routing to different DCs with different enforcement levels, or terminating TLS inconsistently | Resolve the DC name to a specific IP per failing attempt; compare registry values across all DCs in scope |
| Event 2887 shows a nonzero unsigned-bind count but no application-visible failures yet | DC is still on `Negotiate`/`When supported` — exposure exists but nothing is being rejected yet; this is a proactive finding, not an active incident | Enable diagnostics logging (16 LDAP Interface Events = 2) to identify the source before it becomes an outage |
| Everything behind a specific network appliance (VPN concentrator, older printer fleet, monitoring tool) fails simultaneously after enforcement was tightened | The appliance's embedded LDAP client can't be upgraded to support signing/CBT — this is a fleet-wide legacy-device problem, not an isolated bind issue | Confirm firmware update availability; if none exists, this becomes a scoped-exception decision, not a quick fix |
| A load balancer or reverse proxy was recently placed in front of the DCs' LDAPS endpoint and channel-binding-dependent binds broke afterward | The proxy terminates TLS, invalidating every client's CBT behind it — by design, not misconfiguration | Confirm the proxy's TLS-termination behavior; this requires an architecture change, not a registry change |
| `ldp.exe` bind test returns `0x2020` / an LDAP strong-auth-required-style error | Direct confirmation that signing or channel binding rejected the bind — use the exact error text/code to determine which control is the blocker | Compare the error against Microsoft's documented LDAP result codes for signing vs. channel binding rejection |
| Diagnostics logging enabled but Event 2889/3040 volume is overwhelming | Level 2 logging is intentionally verbose and meant for short, targeted collection windows, not permanent operation | Revert to level 0 once the offending clients are identified; don't leave verbose diagnostics logging on indefinitely |

---
## Validation Steps

**Step 1 — Query actual enforcement values on every DC in scope (never assume, always read)**
```powershell
$dcs = (Get-ADDomainController -Filter *).HostName
foreach ($dc in $dcs) {
  Invoke-Command -ComputerName $dc -ScriptBlock {
    Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" |
      Select-Object PSComputerName, LDAPServerIntegrity, LdapEnforceChannelBinding
  }
}
```
Expected: a consistent value across all DCs (inconsistency itself is a finding — mixed enforcement levels produce exactly the "works against one DC, fails against another" symptom).

**Step 2 — Check the periodic summary event for exposure evidence**
```powershell
Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=2886 or EventID=2887)]]" -MaxEvents 5 |
  Select-Object TimeCreated, Id, Message
```
Expected: Event 2886 confirms the DC is in the permissive `Negotiate` posture and periodically reminds of that; Event 2887 gives the actual count of unsigned/simple binds accepted in the prior ~24h window.

**Step 3 — Enable targeted diagnostics logging to identify specific non-compliant clients**
```powershell
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics" -Name "16 LDAP Interface Events" -Value 2
```
Run for a full representative business cycle (a single day may miss weekly/monthly batch jobs), then review Event 2889 (unsigned bind detail, includes source IP and bind DN) and Event 3039/3040 (channel binding detail) before reverting to `0`.

**Step 4 — Reproduce a specific failure interactively for exact error code capture**
```
ldp.exe → Connection > Connect (target DC, port 389 or 636) > Connection > Bind
```
Expected: the exact LDAP result code returned by the DC, which disambiguates a signing rejection from a channel binding rejection — critical before choosing a remediation path.

**Step 5 — Post-remediation validation**
```powershell
Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=2887)]]" -MaxEvents 3 |
  Select-Object TimeCreated, Message
```
Expected: the unsigned-bind count trending toward zero across successive collection windows as identified clients are remediated — this is a gradual, multi-day validation, not an instant pass/fail.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Confirm Current State (never assume)
1. Query `LDAPServerIntegrity` and `LdapEnforceChannelBinding` on every DC in scope — confirm they're actually consistent
2. Cross-reference against any GPO/security baseline that may be centrally managing these values, so a manual registry fix doesn't get silently reverted at next GPO refresh

### Phase 2 — Quantify Exposure Before Changing Anything
1. Review Event 2886/2887 for signing exposure, Event 3039 for channel binding exposure
2. If either count is meaningfully nonzero and enforcement isn't yet at `Require`/`Always`, treat this as a scoped remediation project — do not flip straight to strict enforcement without first identifying clients

### Phase 3 — Identify Specific Non-Compliant Clients
1. Enable `16 LDAP Interface Events = 2` diagnostics logging
2. Collect Event 2889 (signing) / Event 3040 (channel binding) over a representative period (include weekly/monthly batch processes)
3. Build an inventory: client hostname/IP, application, bind type, owner/contact

### Phase 4 — Remediate Each Identified Client
1. Preferred: reconfigure the client/app to use Kerberos/SASL signed binds, or LDAPS with a CBT-capable library
2. Acceptable bridge: temporarily hold the DC(s) at `Negotiate`/`When supported` for a defined, tracked remediation window — never as a permanent state
3. Legacy/unfixable device: document as a scoped, owned exception (see Remediation Playbook 3)

### Phase 5 — Move to Enforcement
1. Once Event 2887/3039 counts are at or near zero, move `LDAPServerIntegrity` to `2` and `LdapEnforceChannelBinding` to `2` via GPO across all DCs consistently
2. Re-run Validation Step 1 immediately after to confirm the GPO applied uniformly
3. Monitor for a follow-up spike in bind failures for a full business cycle post-enforcement — this catches infrequent/batch clients missed during the collection window

### Phase 6 — Architecture Review (if a proxy/load balancer is in the LDAPS path)
1. Confirm whether the device terminates or passes through TLS
2. If terminating, this is an architecture decision requiring stakeholder sign-off, not a quick config change — document the trade-off explicitly rather than silently loosening `LdapEnforceChannelBinding` to work around it

---
## Remediation Playbooks

<details><summary>Playbook 1 — Phased rollout from unenforced to fully required (signing and channel binding)</summary>

**Scenario:** A domain has never deliberately configured these settings and needs a safe path to full enforcement without an outage.

**Step 1 — Baseline current exposure**
```powershell
Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=2887)]]" -MaxEvents 10 |
  Select-Object TimeCreated, Message
```

**Step 2 — Enable diagnostics logging domain-wide for a full collection window (minimum 1-2 weeks to catch batch/monthly clients)**
```powershell
$dcs = (Get-ADDomainController -Filter *).HostName
foreach ($dc in $dcs) {
  Invoke-Command -ComputerName $dc -ScriptBlock {
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics" -Name "16 LDAP Interface Events" -Value 2
  }
}
```

**Step 3 — Aggregate and remediate identified clients per Phase 3/4 above**

**Step 4 — Move to enforcement via GPO (not per-DC registry edits, for consistency and to survive future DC builds)**
```
Computer Configuration > Policies > Administrative Templates > (custom ADMX or direct registry preference)
  targeting HKLM\SYSTEM\CurrentControlSet\Services\NTDS\Parameters:
    LDAPServerIntegrity = 2
    LdapEnforceChannelBinding = 2
```

**Step 5 — Revert diagnostics logging to 0 domain-wide once enforcement is stable**
```powershell
foreach ($dc in $dcs) {
  Invoke-Command -ComputerName $dc -ScriptBlock {
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics" -Name "16 LDAP Interface Events" -Value 0
  }
}
```

**Rollback note:** Every step here is reversible by resetting the registry values (directly or via GPO) back to their prior state and forcing a `gpupdate`/NTDS restart. The only non-trivial "rollback" is re-accepting the security exposure this hardening closes — treat any rollback as temporary and time-boxed, with an explicit owner and re-attempt date.

</details>

<details><summary>Playbook 2 — Diagnosing a channel-binding failure caused by a TLS-terminating load balancer</summary>

**Scenario:** DCs were recently placed behind a load balancer for LDAPS high availability, and channel-binding-dependent clients started failing.

**Step 1 — Confirm the load balancer's TLS handling mode**
Check the load balancer configuration directly: is it operating in Layer 4 (TCP pass-through, TLS untouched end-to-end) or Layer 7 (TLS termination, re-encrypted or re-established onward)? Only Layer 7 termination breaks channel binding.

**Step 2 — If Layer 7 termination is confirmed, this cannot be fixed with a DC-side setting**
```
Options, in order of preference:
1. Reconfigure the load balancer to Layer 4 / TCP pass-through for port 636 specifically
2. Point channel-binding-dependent clients directly at individual DC hostnames instead of the
   load-balanced VIP, bypassing the proxy for this traffic
3. As a last resort, and only with explicit risk acceptance, reduce LdapEnforceChannelBinding
   to 1 (When supported) — this re-opens the specific relay-attack surface this control closes
```

**Step 3 — Validate with a direct-to-DC bind test bypassing the load balancer**
```
ldp.exe → Connect directly to a single DC's hostname on 636, attempt bind
```
Expected: succeeds when bypassing the load balancer, confirming the load balancer (not the client or the DC's own config) is the actual point of failure.

**Rollback note:** Reverting `LdapEnforceChannelBinding` to `1` is a real security trade-off, not a neutral rollback — document it as an accepted risk with an owner, and prefer the architecture fix (Layer 4 mode or direct DC targeting) whenever feasible.

</details>

<details><summary>Playbook 3 — Managing a legacy device/appliance that can never support signing or channel binding</summary>

**Scenario:** A fixed-function device (older printer/scanner with LDAP address-book lookup, an EOL network appliance) has no firmware path to add signing or CBT support, and cannot be replaced immediately.

**Step 1 — Confirm this is genuinely unfixable**
Check vendor documentation/support for a firmware update that adds LDAP signing/CBT support before treating this as permanent — this is often assumed rather than verified.

**Step 2 — Scope the exception as narrowly as possible**
```
Rather than loosening LDAPServerIntegrity/LdapEnforceChannelBinding domain-wide, consider:
- Pinning the device to a single, isolated DC via its configured LDAP server address, and applying
  a scoped GPO (via WMI filtering targeting only that DC's computer object) that holds just that
  DC at a lower enforcement level
- Evaluating whether the device's LDAP dependency can be replaced with a supported alternative
  (many modern scan-to-email/address-book features now support OAuth or a vendor-hosted directory
  sync instead of direct LDAP binds)
```

**Step 3 — Document the exception formally**
Record: device, owner, business justification, DC(s) affected, exact enforcement level held back, and a review/re-attempt date. This is exactly the kind of undocumented exception that silently blocks a future domain-wide hardening push years later.

**Rollback note:** N/A — this playbook produces a documented, scoped, and reviewable risk acceptance rather than a technical rollback. Revisit on the documented review date, not indefinitely.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  LDAP Signing / Channel Binding Evidence Collector
.NOTES     Run with local admin rights on each DC queried; requires the ActiveDirectory module.
#>

$reportPath = "C:\Temp\LDAPSigningEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== Enforcement Values Per DC ===" | Out-File "$reportPath\01_EnforcementValues.txt"
$dcs = (Get-ADDomainController -Filter *).HostName
foreach ($dc in $dcs) {
  try {
    $vals = Invoke-Command -ComputerName $dc -ScriptBlock {
      Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" |
        Select-Object PSComputerName, LDAPServerIntegrity, LdapEnforceChannelBinding
    } -ErrorAction Stop
    $vals | Format-List | Out-File "$reportPath\01_EnforcementValues.txt" -Append
  } catch {
    "Could not query $dc : $($_.Exception.Message)" | Out-File "$reportPath\01_EnforcementValues.txt" -Append
  }
}

"=== Event 2886/2887 (Signing Exposure Summary) ===" | Out-File "$reportPath\02_SigningEvents.txt"
Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=2886 or EventID=2887)]]" -MaxEvents 20 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, Message | Format-List | Out-File "$reportPath\02_SigningEvents.txt" -Append

"=== Event 3039/3040 (Channel Binding Exposure Summary) ===" | Out-File "$reportPath\03_ChannelBindingEvents.txt"
Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=3039 or EventID=3040)]]" -MaxEvents 20 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, Message | Format-List | Out-File "$reportPath\03_ChannelBindingEvents.txt" -Append

"=== Diagnostics Logging Current Level ===" | Out-File "$reportPath\04_DiagnosticsLevel.txt"
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics" -Name "16 LDAP Interface Events" -ErrorAction SilentlyContinue |
  Format-List | Out-File "$reportPath\04_DiagnosticsLevel.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check server-side signing enforcement | `Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters -Name LDAPServerIntegrity` |
| Check server-side channel binding enforcement | `Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters -Name LdapEnforceChannelBinding` |
| Set signing to Require | `Set-ItemProperty HKLM:\...\NTDS\Parameters -Name LDAPServerIntegrity -Value 2` |
| Set channel binding to Always | `Set-ItemProperty HKLM:\...\NTDS\Parameters -Name LdapEnforceChannelBinding -Value 2` |
| Enable verbose LDAP diagnostics logging | `Set-ItemProperty HKLM:\...\NTDS\Diagnostics -Name "16 LDAP Interface Events" -Value 2` |
| Revert diagnostics logging | `Set-ItemProperty HKLM:\...\NTDS\Diagnostics -Name "16 LDAP Interface Events" -Value 0` |
| Restart NTDS after a registry change | `Restart-Service NTDS -Force` |
| View recent unsigned-bind summary events | `Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=2887)]]"` |
| View per-client unsigned bind detail | `Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=2889)]]"` |
| View channel binding rejection detail | `Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=3040)]]"` |
| Interactive bind test with exact error code | `ldp.exe` (Connection > Bind) |
| List all DCs to check consistency across | `Get-ADDomainController -Filter *` |

---
## 🎓 Learning Pointers

- **Signing and channel binding are two independent controls closing two related but distinct gaps** — signing protects every LDAP bind regardless of transport; channel binding additionally protects LDAPS/StartTLS binds by tying the session to its specific TLS channel. A client can fail one without failing the other, and the fix differs.
- **`Negotiate` and `When supported` are monitoring states, not security controls.** They accept the very traffic the hardening exists to stop, while quietly logging Event 2887/3039 counts. Treat any nonzero count as an active finding worth investigating, not passive telemetry.
- **A TLS-terminating proxy or load balancer breaks channel binding by cryptographic design**, not misconfiguration — there is no DC-side setting that fixes this; it requires either Layer 4 pass-through or bypassing the proxy entirely for LDAPS traffic.
- **Never treat "disable the setting" as a fix for a broken client.** This hardening closes a documented NTLM-relay-to-LDAP privilege escalation path; every rollback should be logged as a time-boxed, owned exception, not a permanent resolution.
- **Do not assume a DC's default enforcement level from memory** — Microsoft has repeatedly delayed the point at which strict enforcement becomes the out-of-box default, and the effective default varies by OS build/patch level. Always read the actual registry value.
- **Enable diagnostics logging and collect for a full business cycle (including weekly/monthly batch jobs) before tightening enforcement** — moving straight to `Require`/`Always` without first identifying dependent clients turns a planned hardening project into an unplanned outage.
- Related: [Microsoft guidance on LDAP channel binding and LDAP signing](https://learn.microsoft.com/en-us/troubleshoot/windows-server/identity/ldap-signing-and-channel-binding), [How to enable LDAP signing in Windows Server](https://learn.microsoft.com/en-us/troubleshoot/windows-server/identity/enable-ldap-signing-in-windows-server), [How to add the LDAP channel binding token requirement](https://learn.microsoft.com/en-us/troubleshoot/windows-server/identity/how-to-add-ldap-channel-binding-token-requirement)
