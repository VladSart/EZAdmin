# LDAP Signing & Channel Binding — Hotfix Runbook (Mode B: Ops)
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

Run these from an elevated PowerShell session on a DC (or against a DC via `-ComputerName`):

```powershell
# 1. Current server-side LDAP signing requirement (0=None, 1=Negotiate signing, 2=Require signing)
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -Name "LDAPServerIntegrity" -ErrorAction SilentlyContinue

# 2. Current server-side channel binding requirement (0=Never, 1=When supported, 2=Always)
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -Name "LdapEnforceChannelBinding" -ErrorAction SilentlyContinue

# 3. How many unsigned/simple binds hit this DC in the last 24h (Event 2887 in Directory Service log)
Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=2887)]]" -MaxEvents 5 |
  Select-Object TimeCreated, @{N='Message';E={$_.Message}}

# 4. Which specific clients are binding without signing or channel binding (requires diagnostics logging — see Fix 3)
Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=2889 or EventID=3040)]]" -MaxEvents 20 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, Message

# 5. Confirm this DC's actual OS-default posture if neither registry value above is set (defaults vary by build)
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" |
  Select-Object LDAPServerIntegrity, LdapEnforceChannelBinding
```

| What you see | What it means |
|---|---|
| `LDAPServerIntegrity = 2` and apps suddenly broke after a DC reboot/patch | Signing was moved to **Require** (by GPO, a security baseline, or a recent security update) and at least one client/app is binding unsigned — go to Fix 1 |
| `LdapEnforceChannelBinding = 2` and LDAPS-based apps/binds fail with error `0x2020 (LDAP_STRONG_AUTH_REQUIRED)` or similar | Channel binding moved to **Always** and a client is binding over LDAPS without a channel binding token (old library, misconfigured client, or a TLS-terminating proxy in front of the DC) — go to Fix 2 |
| Event 2887 shows a nonzero count but you don't know **which** client | Diagnostics logging isn't enabled — go to Fix 3 to identify the offending host/app before changing anything domain-wide |
| Both registry values are absent (not set) | DC is on OS defaults for its build — do **not** assume "None/Never"; confirm the effective default for this OS version before treating it as unenforced (see Learning Pointers) |
| App vendor says "just disable LDAP signing" | **Do not disable it domain-wide as a fix** — that re-opens the exact NTLM relay-to-LDAP vulnerability this hardening closes. Fix the client/app instead (Fix 1/Fix 4), or use a scoped exception only as a documented, time-boxed last resort |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Client/app supports LDAP signing (SASL/Kerberos-based bind, not simple bind over plaintext LDAP)
  └── DC's LDAPServerIntegrity policy allows the client's bind type
        ├── 0/None  — signing not required (legacy, insecure, avoid)
        ├── 1/Negotiate — signed if client offers it, unsigned still accepted (the risky "quiet failure" middle state)
        └── 2/Require — unsigned binds are REJECTED outright
              └── (LDAPS/636 or StartTLS only) Channel binding token (CBT) support
                    └── DC's LdapEnforceChannelBinding policy allows the client's CBT support level
                          ├── 0/Never — no CBT required
                          ├── 1/When supported — required only if client's OS/library sends one
                          └── 2/Always — bind REJECTED if no CBT present, even over valid TLS
                                └── (if TLS-terminating proxy/load balancer sits in front of DC)
                                      CBT is cryptographically tied to the TLS session the DC itself
                                      terminates — a proxy that re-terminates TLS breaks this by design
```

Key failure points:
- A DC patched with a Windows security update, or a GPO/security baseline applied, silently moved `LDAPServerIntegrity`/`LdapEnforceChannelBinding` from the permissive default to a stricter value — the trigger event is often invisible to the person filing the ticket
- Legacy line-of-business apps, printers/scanners with LDAP address-book lookups, and older Linux/Java LDAP clients frequently bind unsigned by default and have no easy toggle
- Any network appliance or proxy that terminates TLS between the client and the DC breaks channel binding for every client behind it, all at once — looks like a mass outage, not a config change
- `Negotiate`/`When supported` (the historical default posture) hides the problem until the day someone tightens it to `Require`/`Always` — plan for this transition, don't wait for it to break

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm current enforcement level on the affected DC(s)**
```powershell
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" |
  Select-Object LDAPServerIntegrity, LdapEnforceChannelBinding
```
Expected: a known value (0/1/2 for each). If absent, treat as build-default — do not assume unenforced.

**Step 2 — Count unsigned bind attempts DC-wide**
```powershell
Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=2887)]]" -MaxEvents 1 |
  Select-Object TimeCreated, Message
```
Expected: Event 2887 logs a periodic (roughly every 24h while `LDAPServerIntegrity=1`) summary count of unsigned/simple binds and channel-binding-less binds accepted. A nonzero count confirms exposure even before you tighten anything.

**Step 3 — Enable per-client diagnostics logging to name the offending host**
```powershell
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics" -Name "16 LDAP Interface Events" -Value 2
```
Expected: subsequent unsigned/uncoveted-channel-binding binds log Event 2889 (unsigned bind, includes client IP and account) and Event 3040 (channel binding-related) with the source identified. Revert to `0` once identification is complete — this logging level is verbose.

**Step 4 — Reproduce the failure from the specific client/app**
```powershell
# From the affected host, force a simple bind test against the DC to reproduce the exact error
Import-Module ActiveDirectory
Get-ADDomainController -Discover -Service "PrimaryDC"
# Or, for LDAPS/channel binding testing specifically:
ldp.exe   # Connect > LDAPS port 636 > Bind — surfaces the exact LDAP error code returned by the DC
```
Expected: the exact `LDAP_STRONG_AUTH_REQUIRED` or bind-failure error code, which confirms whether signing or channel binding is the blocking factor.

**Step 5 — Validate after remediation**
```powershell
Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=2887)]]" -MaxEvents 1
```
Expected: count trending to zero over subsequent 24h windows as clients are remediated — this is a gradual validation, not an instant one.

---
## Common Fix Paths

<details><summary>Fix 1 — Client/app is binding unsigned and now fails against Require (LDAPServerIntegrity=2)</summary>

**Cause:** The client or its LDAP library defaults to a plaintext/simple bind and never negotiated signing. This worked silently while the DC was on `Negotiate`, and broke the moment it moved to `Require`.

```powershell
# Confirm the exact posture causing the rejection
(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters").LDAPServerIntegrity

# Preferred fix: reconfigure the client/app to bind using SASL/Kerberos (signed) or LDAPS (636/TLS)
# instead of unsigned simple bind over 389 — this is application-specific; check vendor docs for
# "LDAP signing", "SASL bind", or "use SSL/TLS" options

# If the app cannot be fixed in time and remediation must be deferred, temporarily step the DC(s)
# back to Negotiate (1) — NOT a permanent fix, track as a remediation debt item with an owner and date
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -Name "LDAPServerIntegrity" -Value 1
# Restart NTDS for the change to take effect
Restart-Service NTDS -Force
```

**Rollback note:** Reverting `LDAPServerIntegrity` to `1` re-opens the unsigned-bind exposure this hardening closes — only do this as a time-boxed bridge while the client is fixed or replaced, never as the final state. Document the exception and revisit it.

</details>

<details><summary>Fix 2 — Channel binding rejects a client over LDAPS (LdapEnforceChannelBinding=2)</summary>

**Cause:** The client is binding over LDAPS/StartTLS but its LDAP library doesn't send a Channel Binding Token, or a TLS-terminating proxy/load balancer sits between the client and the DC and breaks the token's cryptographic link to the actual TLS session.

```powershell
# Confirm current channel binding enforcement
(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters").LdapEnforceChannelBinding

# If a TLS-terminating proxy/load balancer is in the path, this is an architecture problem, not a
# registry fix — the proxy must be removed from the LDAPS path, or the client pointed directly at
# the DC/a pass-through (non-terminating) load balancer

# If the client library is simply outdated (pre-2018-era OpenLDAP/JDK LDAP clients commonly lack
# CBT support), update the client library first

# Temporary bridge only, same caveat as Fix 1 — step back to "When supported" (1)
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -Name "LdapEnforceChannelBinding" -Value 1
Restart-Service NTDS -Force
```

**Rollback note:** Same as Fix 1 — this is a temporary bridge, not a resolution. `Never` (0) should not be used except in isolated lab environments.

</details>

<details><summary>Fix 3 — Need to identify which client is causing unsigned/CBT-less binds before changing policy</summary>

**Cause:** Event 2887 confirms exposure exists but doesn't name the client. Escalating enforcement blind risks breaking an unknown production dependency.

```powershell
# Enable verbose LDAP interface diagnostics logging on the DC(s)
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics" -Name "16 LDAP Interface Events" -Value 2

# Let it run through at least one full business cycle, then review
Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=2889 or EventID=3040)]]" |
  Select-Object TimeCreated, Id, Message | Format-List

# Revert logging level once the offending clients are identified — level 2 is chatty
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics" -Name "16 LDAP Interface Events" -Value 0
```

**Rollback note:** Diagnostics logging is non-destructive; only impact is log volume/disk usage while enabled. Always revert the diagnostics level back to 0 once data collection is done.

</details>

<details><summary>Fix 4 — Network appliance (printer, scanner, monitoring tool, older NAS) can't be reconfigured to sign/CBT</summary>

**Cause:** Fixed-function or end-of-life devices frequently ship with an LDAP client that can never support signing or channel binding — no firmware update path exists.

```powershell
# Confirm this is genuinely unfixable (check for a firmware update first) before treating it as
# permanent legacy debt

# Where policy allows, scope the exception as narrowly as possible rather than loosening the whole
# domain: e.g., isolate the device's LDAP traffic to a specific DC pinned at a lower enforcement
# level via a dedicated GPO WMI/security filter targeting only that DC, or migrate the device off
# direct-LDAP address-book lookups entirely if a vendor-supported alternative exists

# Track every such exception explicitly — this is exactly the kind of debt that becomes invisible
# and then blocks a future domain-wide hardening push
```

**Rollback note:** N/A — this fix path is about documenting and scoping an accepted risk, not a reversible technical change.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — LDAP Signing / Channel Binding Issue

Affected DC(s): ____________
LDAPServerIntegrity value (0/1/2): ____________
LdapEnforceChannelBinding value (0/1/2): ____________
Event 2887 unsigned-bind count (last 24h): ____________
Affected client/app/device: ____________
Exact bind failure error code observed: ____________
Bind method used by client (simple/SASL/LDAPS): ____________
TLS-terminating proxy/load balancer in the LDAPS path (Yes/No): ____________

Steps already attempted:
[ ] Confirmed current enforcement level on affected DC(s)
[ ] Enabled diagnostics logging (Event 2889/3040) to identify the specific client
[ ] Reproduced the failure and captured the exact LDAP error code
[ ] Checked for a TLS-terminating proxy/appliance in the LDAPS path
[ ] Confirmed no vendor firmware/client update resolves it
```

---
## 🎓 Learning Pointers

- **`Negotiate` (1) and `When supported` (1) are the historically common but risky middle states** — they don't reject unsigned/CBT-less binds, they just accept them while quietly logging Event 2887/2889. Treat a nonzero 2887 count as an active finding, not background noise.
- **Never treat "disable LDAP signing" as the fix.** This hardening exists specifically to close an NTLM-relay-to-LDAP privilege escalation path; loosening the domain-wide policy to unblock one client trades a real security control for convenience.
- **A TLS-terminating proxy in front of a DC breaks channel binding by design**, not by misconfiguration — CBT is cryptographically bound to the exact TLS session the DC terminates. This is an architecture decision, not a registry fix.
- **Microsoft has repeatedly delayed moving the OS-wide default enforcement level for this hardening** — do not assume "we never touched this setting" means it's unenforced on a given build. Always read the actual registry value rather than assuming a default.
- **Enable diagnostics logging (`16 LDAP Interface Events` = 2) before changing enforcement**, not after — identifying every dependent client first avoids turning a policy change into an outage.
- Related: [Microsoft guidance on LDAP channel binding and LDAP signing](https://learn.microsoft.com/en-us/troubleshoot/windows-server/identity/ldap-signing-and-channel-binding), [How to enable LDAP signing](https://learn.microsoft.com/en-us/troubleshoot/windows-server/identity/enable-ldap-signing-in-windows-server)
