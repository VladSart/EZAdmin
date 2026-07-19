# Network Policy Server (NPS) / RADIUS — Hotfix Runbook (Mode B: Ops)
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

**First, identify which NPS role is actually failing** — NPS can be a RADIUS server (authenticates directly), a RADIUS proxy (forwards to another RADIUS server), or both. Most "NPS is broken" tickets are actually one specific link in the chain: RADIUS client (VPN gateway / wireless AP / switch) → NPS → AD DS → (optionally) NPS MFA extension → Entra ID.

```powershell
# 1. Is NPS auditing even enabled? If not, you're diagnosing blind.
auditpol /get /subcategory:"Network Policy Server"

# 2. Enable it if not (safe, no service restart needed)
auditpol /set /subcategory:"Network Policy Server" /success:enable /failure:enable

# 3. Pull the last 20 auth events — 6272 = granted, 6273 = denied, 6274 = discarded
Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=6272 or EventID=6273 or EventID=6274)]]" -MaxEvents 20 |
  Select-Object TimeCreated, Id, @{n='Reason';e={($_.Message -split "Reason Code:")[1] -split "`n" | Select-Object -First 1}}

# 4. Confirm the RADIUS client (NAS) sending the request is actually registered
Get-NpsRadiusClient | Select-Object Name, Address, Enabled

# 5. Confirm the NPS service itself is running
Get-Service IAS
```

| Finding | Interpretation | Do this |
|---|---|---|
| Event 6273, Reason Code 16 | Bad password / locked account | Not an NPS bug — reset password / unlock account in AD, confirm with user |
| Event 6273, Reason Code 48 | User not in the AD group the Network Policy requires | Check group membership vs. the policy's Conditions tab |
| Event 6273, Reason Code 65 | Client cert not trusted by NPS (EAP-TLS/PEAP) | NPS server doesn't have the issuing CA in its trusted root store |
| Event ID 13 (not 6273) | RADIUS request from an IP not in the RADIUS Clients list | Add the device/controller's IP as a RADIUS client, or fix a NAT/IP change |
| Event ID 18 | Message authenticator invalid — shared secret mismatch | Shared secret on the NAS doesn't match NPS. Reset both ends to the same value |
| No event at all, not even 6274 | Request never reached NPS | Firewall (UDP 1812/1813 or legacy 1645/1646) or NPS service down |
| 6272 granted, but user still can't connect | NPS did its job — problem is downstream (VPN gateway, AP, switch) | Escalate to network/VPN team with the granted timestamp |
| AuthZ log shows AccessReject before MFA prompt | Primary AD auth already failed — NPS MFA extension only processes AccessAccept | Fix primary auth first; MFA extension is not the root cause here |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
RADIUS Client (VPN gateway / WAP / switch)
    │  registered in NPS RADIUS Clients list, shared secret matches
    ▼
Network connectivity: UDP 1812 (auth) + 1813 (accounting), or legacy 1645/1646
    │  no firewall/ACL blocking between NAS and NPS
    ▼
NPS service (IAS) running
    │
    ├── Connection Request Policy matches → processed locally (RADIUS server mode)
    │       or forwarded to a Remote RADIUS Server Group (RADIUS proxy mode)
    │
    ▼
Network Policy conditions match (group membership, day/time, NAS type, EAP type)
    │
    ▼
AD DS authentication (or local SAM if standalone)
    │  NPS must be able to reach a DC; if using UPNs/older domains, needs Global Catalog access
    ▼
[Optional] NPS Extension for Microsoft Entra MFA
    │  registry keys under HKLM\SOFTWARE\Microsoft\AzureMfa present
    │  outbound HTTPS to adnotifications.windowsazure.com + login.microsoftonline.com
    │  requires PAP (or CHAPv2/EAP for phone-call/push-only) between NAS and NPS
    ▼
Access-Accept returned to RADIUS client → client grants network access
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm the request is reaching NPS at all**
```powershell
Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=13 or EventID=18)]]" -MaxEvents 10
```
Expected: no recent hits. Event 13 = unregistered client IP. Event 18 = shared secret mismatch. Either means the request arrived but was rejected before real auth was attempted — different fix path than an AD/policy problem.

**2. Confirm the RADIUS client is registered correctly**
```powershell
Get-NpsRadiusClient -Name "<NAS_NAME>" | Format-List Name, Address, SharedSecret, VendorName
```
Expected: `Address` matches the NAS's actual source IP exactly (or its IP falls inside a configured range). A NAT'd or multi-homed NAS sending from an unexpected interface is a common silent cause.

**3. Confirm the connection request / network policy chain**
```powershell
Get-NpsConnectionRequestPolicy | Select-Object Name, Enabled, PolicyState, ProcessingOrder
Get-NpsNetworkPolicy | Select-Object Name, Enabled, PolicyState, ProcessingOrder
```
Expected: at least one enabled policy whose conditions match the failing request (NAS type, group, day/time). Policies are evaluated in `ProcessingOrder` — a higher-priority Deny policy above the intended Allow policy silently wins.

**4. Confirm AD DS reachability from the NPS box**
```powershell
nltest /dsgetdc:<domain-fqdn>
Test-NetConnection -ComputerName (nltest /dsgetdc:<domain-fqdn> | Select-String "DC:").ToString().Split()[-1] -Port 389
```
Expected: a DC is located and LDAP (389) is reachable. If NPS is not itself a domain controller, this hop is a common latency/outage point that only shows up under load.

**5. If MFA is involved, check the AuthN/AuthZ extension log — not the standard NPS event log**
```powershell
Get-WinEvent -LogName "Microsoft-AzureMfa/AuthZOptCh" -MaxEvents 20 -ErrorAction SilentlyContinue
Get-ChildItem "$env:ProgramFiles\Microsoft\AzureMfa\Logs" -ErrorAction SilentlyContinue
```
Expected: entries correlating to the failed attempt. **The MFA extension only evaluates requests NPS already returned as AccessAccept from primary auth** — if primary auth failed, don't look here first, fix Step 1-4.

**6. Confirm PAP vs. CHAPv2/EAP on the NAS side if MFA prompts never arrive**
Check the NAS/VPN gateway's configured RADIUS authentication protocol. PAP supports all Entra MFA verification methods (call, SMS, push, verification code); CHAPv2 and EAP only support phone call and push notification. A NAS hard-coded to CHAPv2 will silently never deliver a verification-code MFA prompt — this looks identical to "MFA isn't working" but is a protocol mismatch, not an MFA service fault.

---
## Common Fix Paths

<details><summary>Fix 1 — RADIUS client IP mismatch or missing registration (Event ID 13)</summary>

```powershell
# Confirm the actual source IP NPS is seeing (from the Event 13 message text)
# then add or correct the RADIUS client entry
New-NpsRadiusClient -Name "<NAS_NAME>" -Address "<correct-ip>" -SharedSecret "<matching-secret>" -VendorName "RADIUS Standard"

# If it already exists but with the wrong address:
Set-NpsRadiusClient -Name "<NAS_NAME>" -Address "<correct-ip>"
```
**Rollback:** `Remove-NpsRadiusClient -Name "<NAS_NAME>"` if the change was wrong — the NAS will simply be rejected again (same as before the fix), no destructive side effect.
</details>

<details><summary>Fix 2 — Shared secret mismatch (Event ID 18)</summary>

```powershell
# Generate a new strong shared secret and set it on both ends
$secret = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 32 | ForEach-Object {[char]$_})
Set-NpsRadiusClient -Name "<NAS_NAME>" -SharedSecret $secret
# Now configure the identical string on the NAS/VPN gateway/AP controller — this step is NOT scriptable from NPS
```
**Rollback:** keep the old secret noted before rotating; if the NAS-side change fails, `Set-NpsRadiusClient -Name "<NAS_NAME>" -SharedSecret "<old-secret>"` restores the prior state.
</details>

<details><summary>Fix 3 — Network Policy denies access despite correct group membership</summary>

```powershell
# List policies in evaluation order — look for a higher-priority Deny matching first
Get-NpsNetworkPolicy | Sort-Object ProcessingOrder | Select-Object ProcessingOrder, Name, Enabled, PolicyState

# Inspect the specific policy's conditions/constraints via the GUI (nps.msc) —
# no cmdlet exposes full condition/constraint detail; PowerShell here is inventory-only
```
Confirm the intended Allow policy's `ProcessingOrder` is lower (higher priority) than any catch-all Deny, and that its Conditions tab actually includes the user's group — nested/nested-nested group membership is not always what the admin assumes it is.
</details>

<details><summary>Fix 4 — Firewall/connectivity blocking RADIUS traffic</summary>

```powershell
# From the NAS or a test host, confirm UDP reachability (TCP test approximates; use a UDP-aware tool for certainty)
Test-NetConnection -ComputerName <nps-server> -Port 1812
Test-NetConnection -ComputerName <nps-server> -Port 1813

# On the NPS server, confirm the Windows Firewall rule group is enabled
Get-NetFirewallRule -DisplayGroup "Network Policy Server" | Select-Object DisplayName, Enabled
```
**Rollback:** none needed — this is a read/verify step; only re-enable rules that were found disabled.
</details>

<details><summary>Fix 5 — NPS Extension for Entra MFA registry/connectivity error</summary>

```powershell
# Confirm the required registry keys exist (installed by the post-install PowerShell script)
Test-Path "HKLM:\SOFTWARE\Microsoft\AzureMfa"
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\AzureMfa" -ErrorAction SilentlyContinue

# Confirm outbound HTTPS reachability required by the extension
Test-NetConnection -ComputerName adnotifications.windowsazure.com -Port 443
Test-NetConnection -ComputerName login.microsoftonline.com -Port 443

# Confirm TLS 1.2 is enabled (required; a disabled TLS 1.2 causes silent auth failure with
# System-log event 36871 source SChannel, not an NPS-specific event)
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" -ErrorAction SilentlyContinue
```
If the registry key set is missing/incomplete, re-run the NPS extension's post-install PowerShell configuration script (`AzureMfaNpsExtnConfigSetup.ps1`) rather than editing the registry by hand — it also registers the tenant's service principal correctly.
**Rollback:** re-running the config script is idempotent; no rollback needed.
</details>

<details><summary>Fix 6 — PAP vs CHAPv2/EAP mismatch blocking specific MFA methods</summary>

Confirm on the NAS/VPN gateway which RADIUS authentication protocol is configured. If verification-code or SMS MFA silently never prompts but push notification does work, switch the NAS to PAP if your security posture allows it (PAP is encrypted end-to-end within the RADIUS shared-secret tunnel in this specific Entra MFA integration, not sent in the clear across the open network). If PAP is not acceptable, the fallback is push-notification-only MFA methods.
**Rollback:** revert the NAS's authentication protocol setting; this is a NAS-side config change, not an NPS-side one.
</details>

---
## Escalation Evidence

```
NPS / RADIUS Escalation
------------------------
Date/Time of failure:
Affected user(s) / device(s):
RADIUS client (NAS) name and IP:
NPS server name:
Event IDs observed (6272/6273/6274/13/18) and Reason Code if 6273:
Connection Request Policy matched (if known):
Network Policy matched (if known):
Is Entra MFA extension involved? (Y/N):
  If Y — AuthN/AuthZ log entries attached? (Y/N)
Firewall/network path confirmed reachable? (Y/N)
Shared secret last rotated (date, if known):
Scope: single user / single NAS / site-wide / all NPS traffic
Attempted fixes and results:
```

---
## 🎓 Learning Pointers

- **Event 6273's Reason Code is the single most useful piece of data in this whole topic** — the generic "Access Denied" tells you nothing; the numeric reason code (16, 48, 65, and others) tells you exactly which layer failed. Never escalate an NPS ticket without pulling it first. See [NPS troubleshooting guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/troubleshoot-network-policy-server).
- **The NPS MFA extension only ever evaluates requests NPS already Access-Accepted from primary AD auth.** If you see `AccessReject` in the AuthZ log before an MFA prompt, the fix is in AD/Network Policy, not in the MFA extension — a very common wrong-turn in real tickets.
- **PAP vs CHAPv2/EAP silently changes which Entra MFA verification methods work.** This is one of the least obvious facts in RADIUS/MFA troubleshooting and explains a specific, repeatable class of "MFA doesn't work for some users" tickets that are actually protocol configuration, not identity configuration.
- **`Export-NpsConfiguration` should be run after every NPS change and stored securely** — it's the fastest disaster-recovery path for a lost/corrupted NPS server, but the exported file contains RADIUS shared secrets in plaintext. See [NPS best practices](https://learn.microsoft.com/en-us/windows-server/networking/technologies/nps/nps-best-practices).
- **For the deeper dive** — RADIUS proxy vs. server mode, connection request policy forwarding logic, and the NPS extension's full failure taxonomy — see `NPS-RADIUS-A.md`.
