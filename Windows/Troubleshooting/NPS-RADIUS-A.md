# Network Policy Server (NPS) / RADIUS — Reference Runbook (Mode A: Deep Dive)
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

- **Applies to:** on-premises Network Policy Server (NPS) — Microsoft's implementation of RADIUS (RFC 2865/2866) as a RADIUS server, RADIUS proxy, or both — running the Network Policy and Access Services (NPAS) server role on Windows Server 2016 through 2025 (also Azure Local).
- **Covers:** RADIUS authentication/authorization/accounting for VPN (RRAS/AlwaysOnVPN), 802.1X wired/wireless (switches and access points), and dial-up/router-to-router scenarios; the NPS Extension for Microsoft Entra multifactor authentication as an add-on to primary NPS auth.
- **Does not cover:** RRAS/Always On VPN client-side certificate and ProfileXML troubleshooting (`AlwaysOnVPN-A/B.md` — this runbook picks up exactly where that one hands off to NPS), macOS/Intune-side 802.1X certificate profile deployment (`macOS/Troubleshooting/WiFi-8021x-A/B.md`), general Active Directory Certificate Services administration (`Windows/Troubleshooting/CertificateServices-A/B.md`), Windows Hello for Business or Passkeys authentication (`EntraID/Troubleshooting/WHfB-A/B.md`, `Passkeys-A/B.md` — unrelated authentication surfaces), or cloud-native/vendor cloud-RADIUS replacements (out of scope entirely — this repo covers on-prem NPS as deployed today).
- **Licensing/edition:** NPAS role is available on Windows Server Standard/Datacenter with the Desktop Experience installation option only — **not available on Server Core**. No separate license SKU; included with Windows Server.
- **Admin roles needed:** local Administrators group on the NPS server (there is no delegated RBAC model comparable to Entra roles — NPS administration is local-server-scoped).
- **Current platform status (2026):** Microsoft has not announced formal deprecation of NPS itself, and it remains fully supported on Windows Server 2025. However, NPS has received no significant feature investment in several years, and Microsoft's strategic direction for network authentication is increasingly cloud-first (Entra ID-centric). For MSP planning conversations, treat NPS as stable-but-legacy: safe to continue supporting existing on-prem 802.1X/VPN/RADIUS deployments, but flag cloud-RADIUS alternatives as a forward-looking option for greenfield builds or Entra-ID-only (no on-prem AD) environments where NPS cannot authenticate users at all.

---
## How It Works

<details><summary>Full architecture</summary>

NPS is installed via the **Network Policy and Access Services (NPAS)** Windows Server role. It can operate in one, or both simultaneously, of two modes:

**RADIUS server mode** — NPS performs authentication, authorization, and accounting directly. Network access devices (VPN gateways, wireless access points, 802.1X switches — collectively "RADIUS clients" or "Network Access Servers/NAS," a confusingly overloaded term that has nothing to do with network-attached storage) send RADIUS Access-Request messages to NPS. NPS authenticates the user/device against AD DS (or the local SAM database if NPS is not domain-joined), evaluates Network Policies to authorize the connection, and returns Access-Accept or Access-Reject. Accounting messages (session start/stop) are optionally logged.

**RADIUS proxy mode** — NPS does not authenticate locally. Instead, Connection Request Policies inspect the incoming request (commonly by the realm portion of the username, e.g. `user@partner.com`) and forward it to a Remote RADIUS Server Group — another NPS server, a third-party RADIUS server, or a server in an untrusted domain/forest. This is the mechanism that allows authentication across forests without a two-way trust, and is mandatory (not optional) when using EAP-TLS or PEAP-TLS certificate-based authentication across forest boundaries.

Both modes can coexist on the same NPS server: a Proxy policy can be evaluated first and forward matching requests elsewhere, while a Default policy processes everything else locally.

**The two-policy-type model is the single most misunderstood part of NPS by engineers coming from simpler auth systems:**

- **Connection Request Policies** decide *where* a request is processed — locally (RADIUS server behavior) or forwarded (RADIUS proxy behavior). Evaluated first, in `ProcessingOrder`.
- **Network Policies** decide *whether* an already-locally-processed request is authorized — conditions (group membership, NAS type, day/time, EAP type) and constraints (session timeout, encryption requirements). Evaluated only for requests a Connection Request Policy routed to local processing.

A request that matches no Connection Request Policy and no Network Policy is **discarded silently** (Event 6274) — not denied with a reason, just dropped. This is a frequent source of "nothing happens, no error" tickets.

### RADIUS ports and protocol

NPS listens on UDP 1812 (authentication) and 1813 (accounting) by default; legacy 1645/1646 are also supported for older NAS hardware. RADIUS runs over UDP, which has no built-in retransmission/ordering guarantee — the NAS device is responsible for retry logic, and packet loss on the network path presents identically to an NPS outage from the end-user's perspective.

### The NPS Extension for Microsoft Entra multifactor authentication

This is a separate MSI installed on top of NPS that intercepts **already-Access-Accepted** RADIUS responses and inserts a secondary Entra MFA challenge before the final response is returned to the NAS. Architecturally this means:

1. NPS performs primary AD authentication exactly as it would without the extension.
2. Only if NPS returns Access-Accept does the extension engage — it never processes an Access-Reject request. (A common misconception: "the MFA extension isn't working" tickets are very often actually primary-auth failures the extension never even saw.)
3. The extension calls out over HTTPS to `adnotifications.windowsazure.com` (the Entra MFA challenge/response endpoint) and `login.microsoftonline.com` (token acquisition), using a client certificate tied to the tenant's service principal for the connection, installed and registered during the extension's post-install PowerShell configuration step.
4. The user's on-prem AD account is matched to their Entra ID identity via `userObjectSid` lookup (or a configured Alternate Login ID attribute in more complex environments — commonly Entra Connect scenarios where the on-prem UPN doesn't match the cloud UPN).
5. Which MFA verification methods are even deliverable through this path depends on the RADIUS authentication protocol the NAS is configured to use: **PAP** supports the full set (phone call, SMS one-way text, mobile app push, mobile app verification code); **CHAPv2 and EAP** support only phone call and mobile app push notification — verification codes and SMS are silently unavailable over those protocols, a fact that is easy to miss and produces symptom-identical "MFA isn't prompting" tickets with a completely different fix (NAS protocol reconfiguration, not an MFA service issue).

Note: Microsoft's dedicated NPS-extension-error-code reference article has been moved to the Microsoft Learn "previous versions" archive as of this writing (still fully readable, but no longer the actively maintained current-docs location) — treat it as stable reference content rather than a page expected to receive future updates, and cross-check newer guidance under the main Entra multifactor authentication documentation set if troubleshooting a very recently introduced NPS extension version.

</details>

---
## Dependency Stack

```
Layer 7 — NAS device configuration (VPN gateway / AP controller / switch)
    RADIUS server IP(s), shared secret, authentication protocol (PAP/CHAPv2/EAP)
        │
Layer 6 — Network path
    UDP 1812/1813 (or 1645/1646) reachable, no ACL/firewall blocking, no asymmetric routing
        │
Layer 5 — NPS RADIUS Clients list
    NAS registered by exact IP (or IP range), shared secret matches Layer 7 exactly
        │
Layer 4 — Connection Request Policy
    Determines local processing vs. proxy forwarding; evaluated in ProcessingOrder, first match wins
        │
Layer 3 — Network Policy (only reached if Layer 4 routed to local processing)
    Conditions (group, NAS type, day/time, EAP type) AND constraints (encryption, session timeout)
    must all be satisfied; policies evaluated in ProcessingOrder, first FULL match wins
        │
Layer 2 — AD DS / local SAM authentication
    NPS must reach a domain controller (or Global Catalog for UPN-based lookups in older/mixed
    functional-level domains); dial-in properties on the user object also evaluated here
        │
Layer 1 — [Optional] NPS Extension for Entra MFA
    Only invoked on Layer 2's Access-Accept; requires registry config + outbound HTTPS +
    matching RADIUS protocol capability from Layer 7
```

A fault at any layer produces a rejected or discarded connection with symptoms that look identical from the end-user's device — this is why the diagnosis flow below insists on working top-down from the NPS server's own logs rather than guessing from client-side symptoms alone.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| All users on one NAS device fail, other NAS devices fine | RADIUS client registration issue (Layer 5) — wrong IP or shared secret for that specific NAS | `Get-NpsRadiusClient`, Event ID 13/18 |
| One specific user denied, others on the same NAS fine | AD account issue (locked, disabled, expired) or group-membership condition in Network Policy | Event 6273 Reason Code 16/48 |
| Certificate-based auth (EAP-TLS/PEAP) fails for everyone after a CA change | NPS server's trusted root store doesn't have the new/renewed issuing CA | Event 6273 Reason Code 65; check NPS server's local certificate store |
| Request silently vanishes, zero events, not even 6274 | Traffic never reaching NPS — firewall/ACL, wrong NPS IP configured on NAS, or NPS service stopped | `Get-Service IAS`; UDP port reachability test |
| Event 6274 (discarded) | Request matched no Connection Request Policy and no Network Policy — policy gap, not a credential problem | Review policy ProcessingOrder and conditions for a gap |
| Works for wired 802.1X, fails for wireless (or vice versa) | Separate Network Policies exist per NAS Port Type condition and only one is correctly configured | Compare NAS Port Type condition across policies |
| MFA push/call works, verification code/SMS silently never arrives | NAS configured for CHAPv2/EAP rather than PAP — those protocols don't support code/SMS MFA methods | Check NAS RADIUS authentication protocol setting |
| MFA doesn't prompt at all, primary auth appears to succeed on NAS side | NPS returned Access-Reject before the extension ever engaged — a primary-auth failure being misread as an MFA failure | AuthZ extension log will show no entry at all for a true pre-MFA reject |
| MFA extension error CLIENT_CERT_INSTALL_ERROR / ESTS_TOKEN_ERROR | Extension's client certificate or tenant token registration broken | Re-run `AzureMfaNpsExtnConfigSetup.ps1`; verify cert in local machine store |
| MFA extension error HTTPS_COMMUNICATION_ERROR / HTTP_CONNECT_ERROR | Outbound firewall blocking `adnotifications.windowsazure.com` / `login.microsoftonline.com`, or TLS 1.2 disabled | Port 443 reachability test; check for System log event 36871 (SChannel) |
| MFA extension error REGISTRY_CONFIG_ERROR | Post-install configuration script never completed, or a key was manually deleted | `Test-Path HKLM:\SOFTWARE\Microsoft\AzureMfa`; re-run config script |
| Authentication works but takes noticeably long / times out under load | NPS not co-located with a DC/GC, or too few concurrent authentication threads configured | Check NPS-to-DC network latency; see `nps-concurrent-auth` tuning doc |
| Proxy scenario: request never reaches the remote RADIUS server group | Remote RADIUS Server Group misconfigured, or Connection Request Policy's forwarding condition doesn't actually match | `Get-NpsRemoteRadiusServerGroup`; verify CRP forwarding action |
| Cross-forest EAP-TLS/PEAP-TLS fails despite a two-way trust existing | Certificate-based auth across forests requires a RADIUS proxy — a direct two-way trust alone is NOT sufficient for these EAP types | Confirm proxy topology is actually in place, not just forest trust |

---
## Validation Steps

**1. Confirm NPS role and service state**
```powershell
Get-WindowsFeature NPAS
Get-Service IAS | Select-Object Status, StartType
```
Good: `Installed`, service `Running`, `StartType Automatic`. Bad: service `Stopped` — check Application/System event logs for the crash/stop reason before restarting blindly.

**2. Confirm auditing is enabled (prerequisite for all further diagnosis)**
```powershell
auditpol /get /subcategory:"Network Policy Server"
```
Good: `Success and Failure`. Bad: `No Auditing` — every troubleshooting step below depends on this being on.

**3. Inventory RADIUS clients**
```powershell
Get-NpsRadiusClient | Select-Object Name, Address, Enabled, VendorName
```
Good: every production NAS device listed with the correct current IP. Bad: an entry with a stale IP after a NAS was re-IP'd, or a missing entry entirely for a device sending traffic (correlates to Event 13).

**4. Inventory and order-check policies**
```powershell
Get-NpsConnectionRequestPolicy | Sort-Object ProcessingOrder | Select-Object ProcessingOrder, Name, Enabled
Get-NpsNetworkPolicy | Sort-Object ProcessingOrder | Select-Object ProcessingOrder, Name, Enabled, PolicyState
```
Good: intended Allow policies sit at a lower `ProcessingOrder` number (evaluated first) than any catch-all Deny. Bad: a broad Deny policy sitting above a specific Allow — first-match-wins means the Deny silently shadows everything below it.

**5. Confirm AD DS / DC reachability from the NPS server itself**
```powershell
nltest /dsgetdc:<domain-fqdn>
```
Good: a DC returned with no errors. Bad: `ERROR_NO_SUCH_DOMAIN` or a timeout — NPS cannot authenticate anyone, this is a Layer 2 (dependency stack) outage, not a policy problem.

**6. Confirm certificate trust for EAP-TLS/PEAP deployments**
```powershell
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match "<expected-CA-name>" }
```
Good: the CA that signs client/NAS certificates is present and not expired. Bad: missing or expired — every EAP-TLS/PEAP authentication attempt will fail with Reason Code 65 regardless of user/group correctness.

**7. If the MFA extension is deployed, confirm its config and connectivity independently of NPS auth**
```powershell
Test-Path "HKLM:\SOFTWARE\Microsoft\AzureMfa"
Test-NetConnection adnotifications.windowsazure.com -Port 443
Test-NetConnection login.microsoftonline.com -Port 443
```
Good: registry key present, both endpoints reachable. Bad: either missing/unreachable — the extension will fail even when primary NPS auth is completely healthy, and this must be isolated as a separate fault domain from Layers 2-7.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Confirm the request reaches NPS
1. Enable auditing if not already on (Validation Step 2).
2. Reproduce the failure and immediately pull Event IDs 13, 18, 6272, 6273, 6274 from the Security log.
3. No events at all → the problem is network path or NAS misconfiguration, not NPS policy. Move to Phase 2.
4. Event 13/18 → RADIUS client registration/secret problem. Fix at Layer 5, do not proceed further until resolved.

### Phase 2 — Network path verification
1. From the NAS (or a host on the same segment), test UDP reachability to NPS on 1812/1813.
2. Check any intermediate firewall/ACL change history against the failure's start time.
3. Confirm the NAS is actually configured with the correct NPS server IP (not a decommissioned or DR server).

### Phase 3 — Policy evaluation
1. With auditing confirmed and network path confirmed, pull the Reason Code from Event 6273 for a real denial, or confirm 6274 (discarded, no matching policy).
2. Walk Connection Request Policies top-down by ProcessingOrder — identify which one actually matched.
3. If routed to local processing, walk Network Policies top-down the same way — identify which matched and what it denied on (Reason Code 48 = group condition failure is the most common).
4. If proxy mode: confirm the target Remote RADIUS Server Group is itself healthy (this may require repeating this entire runbook against the remote NPS server).

### Phase 4 — AD DS dependency check
1. Confirm DC/GC reachability from the NPS server (Validation Step 5).
2. Check the target user account's state directly: `Get-ADUser <user> -Properties LockedOut, Enabled, AccountExpirationDate`.
3. For EAP-TLS/PEAP: confirm certificate trust chain (Validation Step 6) and that the CA hasn't rotated without NPS's trust store being updated.

### Phase 5 — NPS Extension for Entra MFA (only if MFA is in the picture)
1. Confirm Phase 1-4 all pass first — a primary-auth failure will never reach this layer regardless of extension health.
2. Check the AuthN/AuthZ extension logs (`Applications and Services Logs > Microsoft > AzureMfa`), not the standard NPS Security log.
3. Match any error code against the reference table in the Symptom → Cause Map above.
4. If verification code/SMS specifically fails while push/call work, check the NAS's configured RADIUS authentication protocol (Phase 3's policy review will show the Network Policy's expected authentication methods; compare against the NAS's actual configured protocol — these are two independent settings that must agree).

### Phase 6 — Performance/scale issues (auth succeeds but is slow or intermittently times out)
1. Confirm NPS-to-DC network latency; co-locating NPS on a DC or same-subnet-as-GC server is the standard performance recommendation.
2. Review concurrent authentication thread tuning if NPS is standalone and under high request volume — see the Command Cheat Sheet for the relevant registry path.
3. Rule out SQL Server accounting logging as a bottleneck if configured — accounting failures can back-pressure the authentication path in some configurations.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Recover from a RADIUS client re-IP or shared-secret drift</summary>

**Scenario:** A NAS device (VPN gateway, AP controller) was reconfigured or replaced, and all connections through it now fail with Event 13 or 18.

```powershell
# Confirm the NAS's actual current source IP from the Event 13 message text, then:
Set-NpsRadiusClient -Name "<NAS_NAME>" -Address "<new-ip>"

# If the shared secret also needs rotating (recommended after any hardware replacement):
$newSecret = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 32 | ForEach-Object {[char]$_})
Set-NpsRadiusClient -Name "<NAS_NAME>" -SharedSecret $newSecret
# Configure the identical secret on the NAS device itself — not scriptable from NPS

# Export the updated configuration for backup immediately after any change
Export-NpsConfiguration -Path "C:\NPS-Backup\nps-config-$(Get-Date -Format yyyyMMdd-HHmm).xml"
```
**Rollback:** if the NAS's actual IP was misdiagnosed, `Set-NpsRadiusClient -Name "<NAS_NAME>" -Address "<previous-ip>"` restores prior state — no data loss risk, RADIUS client entries are configuration-only.
</details>

<details><summary>Playbook 2 — Fix a policy-ordering gap causing silent discards (Event 6274)</summary>

**Scenario:** A specific class of device or user is silently discarded (not denied — no Reason Code, just Event 6274) after a new NAS type or use case was introduced without a corresponding policy.

```powershell
Get-NpsConnectionRequestPolicy | Sort-Object ProcessingOrder | Select-Object ProcessingOrder, Name, Enabled
Get-NpsNetworkPolicy | Sort-Object ProcessingOrder | Select-Object ProcessingOrder, Name, Enabled
```
1. Identify the gap — no existing policy's conditions cover the new NAS Port Type / EAP type / group combination.
2. In `nps.msc`, create the new policy (no cmdlet provides full condition/constraint authoring — GUI or `netsh nps` scripting export/import is the practical path for bulk changes).
3. Set its `ProcessingOrder` correctly relative to existing policies — a new Allow policy placed below an existing catch-all Deny will never be evaluated.
4. Re-test and confirm Event 6272 (granted) replaces the prior 6274.

**Rollback:** disable (do not delete) the new policy via `Set-NpsNetworkPolicy -Name "<name>" -Enabled $false` if it produces unintended access grants — safer than deletion while validating.
</details>

<details><summary>Playbook 3 — Restore NPS from a full server loss using an exported configuration</summary>

**Scenario:** The NPS server itself is lost (hardware failure, corruption) and must be rebuilt from a prior `Export-NpsConfiguration` backup.

```powershell
# On the new server, after installing the NPAS role:
Install-WindowsFeature NPAS -IncludeManagementTools

# Import the prior configuration (overwrites current NPS config on this server)
Import-NpsConfiguration -Path "C:\NPS-Backup\nps-config-<latest>.xml"

# Restart the service to apply
Restart-Service IAS
```
**Important:** the exported file contains RADIUS shared secrets in plaintext — this backup file itself is sensitive and must be stored/transferred securely. `Export-NpsConfiguration` does NOT include SQL Server logging configuration — that must be reconfigured manually post-restore if used.
**Rollback:** none applicable — this playbook is itself the recovery action for a lost server; validate thoroughly in a maintenance window since import overwrites all existing local NPS configuration.
</details>

<details><summary>Playbook 4 — Recover a broken NPS Extension for Entra MFA installation</summary>

**Scenario:** Primary AD/NPS auth is confirmed healthy (Phase 1-4 all pass) but the MFA extension consistently errors.

```powershell
# Re-run the extension's post-install configuration script (downloaded with the extension MSI)
# This re-registers the service principal and rewrites the required registry keys
.\AzureMfaNpsExtnConfigSetup.ps1

# Restart NPS service to pick up the refreshed extension state
Restart-Service IAS
```
For deeper diagnosis before re-running config, Microsoft publishes a community health-check script (`azure-mfa-nps-extension-health-check` on GitHub) that isolates NPS-vs-MFA-service faults, tests specific users, and collects logs for support in one pass — the standard first tool for anything beyond a quick registry-key check.
**Rollback:** re-running the config script is idempotent and safe to repeat; if it makes things worse, uninstall/reinstall the extension MSI cleanly rather than hand-editing the registry further.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects NPS/RADIUS diagnostic evidence for escalation.
#>
$out = "C:\NPS-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $out -Force | Out-Null

auditpol /get /subcategory:"Network Policy Server" | Out-File "$out\auditpol.txt"
Get-Service IAS | Out-File "$out\service-state.txt"
Get-NpsRadiusClient | Export-Csv "$out\radius-clients.csv" -NoTypeInformation
Get-NpsConnectionRequestPolicy | Sort-Object ProcessingOrder | Export-Csv "$out\connection-request-policies.csv" -NoTypeInformation
Get-NpsNetworkPolicy | Sort-Object ProcessingOrder | Export-Csv "$out\network-policies.csv" -NoTypeInformation
Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=6272 or EventID=6273 or EventID=6274 or EventID=13 or EventID=18)]]" -MaxEvents 200 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, Message | Export-Csv "$out\nps-security-events.csv" -NoTypeInformation
Get-WinEvent -LogName "Microsoft-AzureMfa/AuthZOptCh" -MaxEvents 100 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, Message | Export-Csv "$out\mfa-authz-events.csv" -NoTypeInformation
Export-NpsConfiguration -Path "$out\nps-config-snapshot.xml"
Write-Host "Evidence collected to $out — NOTE: nps-config-snapshot.xml contains plaintext shared secrets, handle securely."
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `auditpol /get /subcategory:"Network Policy Server"` | Check whether NPS auditing is enabled |
| `Get-Service IAS` | Check NPS service state |
| `Get-NpsRadiusClient` | List/inspect registered RADIUS clients (NAS devices) |
| `New-NpsRadiusClient` / `Set-NpsRadiusClient` | Create/modify a RADIUS client entry |
| `Get-NpsConnectionRequestPolicy` | List Connection Request Policies with ProcessingOrder |
| `Get-NpsNetworkPolicy` | List Network Policies with ProcessingOrder and state |
| `Get-NpsRemoteRadiusServerGroup` | List Remote RADIUS Server Groups (proxy mode targets) |
| `Export-NpsConfiguration` / `Import-NpsConfiguration` | Full config backup/restore (contains plaintext secrets) |
| `Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=6273)]]"` | Pull authentication denial events with Reason Codes |
| `nltest /dsgetdc:<domain>` | Confirm NPS can locate a domain controller |
| `Test-NetConnection <nps-server> -Port 1812` | Approximate RADIUS auth port reachability (TCP test on a UDP port — indicative only) |
| `Get-WinEvent -LogName "Microsoft-AzureMfa/AuthZOptCh"` | NPS Entra MFA extension authorization log |
| `Test-Path HKLM:\SOFTWARE\Microsoft\AzureMfa` | Confirm MFA extension registry configuration is present |

---
## 🎓 Learning Pointers

- **Connection Request Policies and Network Policies are two independent evaluation stages, not one.** Engineers new to NPS often edit Network Policy conditions expecting to control routing/forwarding behavior, when that's actually the Connection Request Policy's job — and vice versa. Understanding this split resolves a large fraction of "I changed the policy and nothing happened" confusion. See [Connection Request Policies](https://learn.microsoft.com/en-us/windows-server/networking/technologies/nps/nps-crp-crpolicies).
- **RADIUS proxy mode is mandatory, not optional, for cross-forest EAP-TLS/PEAP-TLS** even when a two-way trust already exists — a fact that surprises engineers who assume trust alone is sufficient for any cross-forest auth scenario. See the [NPS overview](https://learn.microsoft.com/en-us/windows-server/networking/technologies/nps/nps-top).
- **The NPS Extension for Entra MFA's documentation has moved to Microsoft Learn's "previous versions" archive** — still accurate and usable, but a signal that this specific integration surface is not receiving active documentation investment. Worth flagging to clients planning greenfield 802.1X/VPN builds as a nudge toward evaluating cloud-RADIUS alternatives, while continuing to fully support existing deployments.
- **`Export-NpsConfiguration` is the cheapest disaster-recovery insurance in this entire topic and is trivially easy to forget.** Build it into a scheduled task on every NPS server in scope, and treat the output file with the same handling care as a password vault export — it contains every RADIUS shared secret in plaintext.
- **PAP is not automatically the "less secure" choice it looks like on paper in this specific integration** — the Entra MFA NPS Extension's PAP traffic is protected within the RADIUS shared-secret exchange, and PAP is required to unlock the full range of MFA verification methods. Don't reflexively push clients to CHAPv2/EAP for RADIUS without checking whether it silently removes MFA method options they're relying on.
- **NPS is not formally deprecated as of 2026** but is receiving essentially no feature investment while Microsoft's public direction favors cloud-native RADIUS/identity solutions — a useful, low-drama data point for MSP roadmap conversations rather than an urgent migration trigger for healthy existing deployments.
