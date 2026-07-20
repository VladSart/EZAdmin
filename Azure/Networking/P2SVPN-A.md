# Azure VPN Gateway Point-to-Site (P2S) — Reference Runbook (Mode A: Deep Dive)
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

**In scope:** Point-to-Site VPN on a **customer-managed VPN Gateway in a traditional hub VNet** (the `Vpn` gateway type's own P2S configuration) — protocols (OpenVPN, SSTP, IKEv2), authentication types (Certificate, Microsoft Entra ID, RADIUS/AD), client address pool design, routing behavior, root certificate lifecycle, and the Azure VPN Client.

**Out of scope:**
- **Site-to-Site (S2S) VPN and ExpressRoute** — a completely different gateway configuration and failure domain; see `HybridConnectivity-A.md`/`HybridConnectivity-B.md`.
- **The User VPN (P2S) gateway type embedded in a Virtual WAN hub** — architecturally different (Microsoft-managed hub router, different scale model, different configuration surface) — see `VirtualWAN-A.md`/`VirtualWAN-B.md`.
- **Always On VPN (Windows-native, device/user tunnel via Intune ProfileXML)** — a different technology entirely, client-to-on-prem via RRAS, not client-to-Azure-VNet via VPN Gateway. See `Windows/Troubleshooting/AlwaysOnVPN-A.md`.
- **NPS/RADIUS server administration** — this runbook covers RADIUS only as it appears from the P2S gateway side (reachability, pass-through behavior); for the RADIUS server's own configuration and health, see `Windows/Troubleshooting/NPS-RADIUS-A.md`.

**Assumptions:** Reader is comfortable with Azure VNets, IPsec/IKE fundamentals, and basic PKI (root/intermediate/leaf certificate chains). Examples use Az PowerShell; portal and CLI equivalents exist for all operations shown.

---
## How It Works

<details><summary>Full architecture</summary>

A Point-to-Site connection is fundamentally different from Site-to-Site: instead of two networks joined by a persistent IPsec tunnel between gateway devices, P2S is a **client-initiated, individual-device tunnel** terminating directly on the Azure VPN Gateway. The gateway must be **route-based** (policy-based gateways cannot do P2S at all).

**Protocol layer.** Three protocols are available, each with different platform support and firewall-traversal characteristics:

| Protocol | Basis | Platform support | Notes |
|---|---|---|---|
| OpenVPN | SSL/TLS (TLS 1.2/1.3) | Windows, macOS, Linux, iOS, Android | Uses TCP 443 — traverses almost any corporate firewall since it looks like ordinary HTTPS |
| SSTP | Proprietary TLS-based | Windows only | Also TCP 443-based; Windows-native alternative to OpenVPN |
| IKEv2 | Standards-based IPsec | Windows, macOS | Native OS VPN client support (no separate app needed on many platforms) |

A gateway can be configured for **one or a combination** of these — the combination determines which authentication types are even reachable, because authentication and tunnel type are cross-constrained (see the compatibility matrix below).

**Authentication layer.** Three mechanisms, and a gateway can have more than one enabled simultaneously:

1. **Certificate authentication.** The gateway trusts one or more root CA public keys (uploaded as Base64, no private key ever leaves the client environment). Each connecting client must have an installed leaf certificate issued from a chain terminating at one of those trusted roots. Validation happens entirely on the Azure gateway during tunnel establishment — no external server involved. This is the simplest model operationally but the weakest at scale (no centralized user-level revocation beyond re-issuing/removing the root, no MFA by itself).

2. **Microsoft Entra ID authentication.** The gateway integrates with Entra ID via an application (App ID) and Audience value. Two options exist: the newer **Microsoft-registered App ID** (no manual tenant registration required — the app is pre-created and automatically usable) and the older **manually-registered App ID** (requires the Cloud Application Administrator role to register and consent). A gateway supports exactly **one** Audience value at a time — mixing is not possible. This is the only auth type that lets Conditional Access and MFA apply directly to the VPN sign-in itself, since it's a genuine Entra ID authentication event. **Constraint: Entra ID auth works only over the OpenVPN tunnel type**, and only with the **Azure VPN Client** app (the OS-native VPN client cannot do Entra ID auth).

3. **RADIUS / AD Domain authentication.** The gateway acts as a pure pass-through — it forwards authentication requests to a configured RADIUS server and relays the response, but performs no validation itself. This means gateway reachability TO the RADIUS server is a hard prerequisite: if the RADIUS server is on-premises, the gateway needs a working S2S tunnel (a second, independent VPN Gateway connection type) just to reach it. RADIUS can additionally integrate with AD Certificate Services, letting an organization reuse its existing enterprise PKI for P2S certificate auth without ever uploading a root cert to Azure directly. RADIUS also opens the door to third-party MFA providers that plug into the RADIUS chain.

**Tunnel-type / auth-type compatibility matrix** (this is the single most common source of "why won't this combination work" tickets):

| Tunnel Type | Compatible Authentication |
|---|---|
| OpenVPN | Any subset of Microsoft Entra ID, RADIUS, Certificate |
| SSTP | RADIUS or Certificate only |
| IKEv2 | RADIUS or Certificate only |
| IKEv2 + OpenVPN | RADIUS, Certificate, Entra ID+RADIUS, or Entra ID+Certificate — but Entra ID itself only ever rides the OpenVPN leg |
| IKEv2 + SSTP | RADIUS or Certificate only |

**Client address pool.** A dedicated address range (`VpnClientAddressPool`) is carved out for connected clients, assigned dynamically per session. This range must not overlap the gateway's VNet, any peered VNet, or any on-premises range reachable via S2S/ExpressRoute — overlap produces silent, hard-to-diagnose asymmetric routing rather than a clean error, because the gateway has no way to know the range is "wrong," only that it's configured.

**Client profile package.** After configuration, an administrator generates a downloadable `.zip` (`New-AzVpnClientConfiguration`) containing the VPN client settings, trusted root certs (for Certificate auth), and Entra ID Audience/App details (for Entra ID auth). This package is a **point-in-time snapshot** — it does not self-update. Any of the following silently invalidates previously-distributed packages without notifying users: VNet peering changes, address pool changes, root cert changes, or Azure's own periodic P2S gateway root certificate rotation (a Microsoft-initiated event affecting the gateway's server-side certificate, independent of client-side Certificate auth).

**Routing behavior — the counter-intuitive core of this topic.** P2S routing is NOT simply "client can now reach the whole hub-and-spoke." What routes get pushed to a connecting client depends on three independent factors: the client OS, the connection protocol, and how the destination VNet is connected to everything else (isolated / peered / S2S-connected / S2S-connected-with-BGP). Critically:

- **Windows clients get their route table baked into the downloaded profile package at generation time.** If the topology changes afterward (a new peering added, a new BGP-learned route appears), Windows clients do NOT pick this up automatically — the VPN client package must be regenerated and reinstalled.
- **Non-Windows clients (macOS, Linux, iOS) receive routes dynamically and adapt to topology changes without needing a new profile package** — the opposite behavior from Windows for the exact same topology change.
- **Without BGP** on an S2S-connected VNet, P2S clients can reach only the directly-connected VNet, not further-hop networks reachable via that VNet's own S2S/peering relationships (no transitive reachability).
- **With BGP** on the S2S connections, P2S clients (both Windows and non-Windows) CAN reach multi-hop networks, but Windows clients still require manual route addition or a profile regeneration to actually use the newly-reachable routes; non-Windows clients pick them up automatically.

This asymmetry between Windows and non-Windows client route-refresh behavior is the most common "it worked yesterday, now some users can't reach the new subnet" pattern for P2S specifically — and it's not a bug, it's documented platform behavior.

</details>

---
## Dependency Stack

```
Layer 6:  Client OS + selected protocol/auth combination
              (must be a valid combination per the compatibility matrix — not all pairings exist)
Layer 5:  Client profile package (point-in-time snapshot, does not self-update)
              ├─ Windows: routes baked in at generation time — stale after topology change
              └─ Non-Windows: routes refresh dynamically post-connect
Layer 4:  Authentication mechanism
              ├─ Certificate → root CA trust chain uploaded to gateway
              ├─ Entra ID → App ID/Audience registration, OpenVPN-only, Azure VPN Client required
              └─ RADIUS → pass-through to reachable RADIUS server (on-prem RADIUS needs a live S2S tunnel)
Layer 3:  VpnClientAddressPool
              (dedicated, non-overlapping range — dynamically assigned per session)
Layer 2:  Gateway SKU capability ceiling
              (Basic SKU: no IKEv2, no IPv6, no RADIUS — hard, silent ceiling)
Layer 1:  Gateway type + VPN type
              (must be `Vpn` GatewayType, route-based VpnType — policy-based cannot do P2S)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| All P2S connections fail immediately, all auth types | Gateway itself down/updating, or `VpnClientConfiguration` never actually applied | `Get-AzVirtualNetworkGateway`, confirm `ProvisioningState` |
| Certificate-auth clients rejected, RADIUS/Entra ID clients unaffected | Root cert missing, expired, or wrong root uploaded | `VpnClientRootCertificates` list vs. client cert issuer |
| RADIUS-auth clients fail, others unaffected | RADIUS server unreachable from gateway subnet (often: on-prem RADIUS + down S2S tunnel) | Confirm S2S tunnel status first, then NSG/UDP 1812-1813 |
| Entra ID-auth clients can't connect, but same tenant works fine for other apps | Wrong/mismatched Audience value, or client using native OS VPN client instead of Azure VPN Client | `AadAudience` on gateway vs. client app config |
| Linux users specifically failing on Entra ID auth after Aug 2026 | Azure VPN Client for Linux retired | Migrate Linux users to Certificate or RADIUS auth |
| Connections succeed but users can't reach a specific subnet added recently | Windows client profile stale (routes baked in at generation time) | Regenerate + redistribute profile package |
| Same topology change, non-Windows users unaffected | Expected — non-Windows clients refresh routes dynamically; this is not a bug | No fix needed for non-Windows; still fix Windows via profile regen |
| Connections fail during business hours only, work off-peak | Client address pool exhaustion | Check pool size vs. concurrent connection count |
| "No policy match" / IKE negotiation failure | Client-side custom IPsec policy incompatible with Azure's fixed default policy set | Use the Azure-generated client profile rather than a hand-built config |
| Basic SKU gateway, IKEv2/RADIUS/IPv6 configured but not working | Basic SKU capability ceiling — silently unsupported | `Sku.Name`; plan a SKU resize |
| Client connects but internal hostnames don't resolve | VNet DNS settings not honored by client, or DNS suffix not pushed/accepted | Check VNet DNS config and client-side DNS handling |
| One gateway, some users on Certificate and some on Entra ID, both suddenly fail simultaneously | Azure's periodic P2S gateway root certificate migration (server-side cert rotation, affects ALL auth types) | Check for a recent Microsoft-notified migration; regenerate client profiles |
| P2S clients reach the hub VNet but not a peered VNet two hops away | No BGP on the intermediate S2S connection — no transitive routing without BGP | Confirm BGP status on the relevant S2S connections |

---
## Validation Steps

1. **Confirm gateway type and P2S configuration exist.**
   ```powershell
   $gw = Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName>
   $gw | Select-Object GatewayType, VpnType, Sku
   ```
   Good: `GatewayType = Vpn`, `VpnType = RouteBased`. Bad: `VpnType = PolicyBased` — P2S is impossible on this gateway as configured.

2. **Confirm SKU supports the required feature set.**
   ```powershell
   $gw.Sku.Name
   ```
   Good: `VpnGw1` or higher for IKEv2/RADIUS/IPv6. Bad: `Basic` combined with any of those features configured — they will not function.

3. **Confirm client address pool sizing and no overlap.**
   ```powershell
   $gw.VpnClientConfiguration.VpnClientAddressPool.AddressPrefixes
   ```
   Good: a range sized for peak concurrent users, distinct from VNet/peered/on-prem ranges. Bad: overlap with any reachable range, or a pool too small for the user count.

4. **Confirm root certificate presence and freshness (Certificate auth).**
   ```powershell
   $gw.VpnClientConfiguration.VpnClientRootCertificates | Select-Object Name
   ```
   Good: at least one root, matching the enterprise/self-signed CA actually issuing client certs. Bad: empty, or a root that doesn't match any deployed client cert's issuer chain.

5. **Confirm RADIUS reachability (RADIUS auth).**
   ```powershell
   $gw.VpnClientConfiguration.RadiusServerAddress
   Test-NetConnection -ComputerName <radiusServerIp> -Port 1812
   ```
   Good: reachable from a host in the gateway's VNet. Bad: timeout — check S2S tunnel status if RADIUS is on-prem.

6. **Confirm Entra ID Audience alignment (Entra ID auth).**
   ```powershell
   $gw.VpnClientConfiguration.AadAudience
   $gw.VpnClientConfiguration.AadTenant
   $gw.VpnClientConfiguration.AadIssuer
   ```
   Good: values match what the Azure VPN Client is configured to expect (Microsoft-registered, manually-registered, or custom — but consistently one, not mixed). Bad: a client profile built for one Audience type being used with a gateway now configured for a different one — this happens after switching App ID types without redistributing profiles.

7. **Confirm the distributed client profile package is current.**
   Compare the package generation date/time against the last date any of: VNet peering, address pool, root cert, or Azure's own migration notice changed. Good: package generated after the most recent of these. Bad: package predates any of them — regenerate before further troubleshooting individual client issues.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Gateway-level confirmation.** Verify `ProvisioningState = Succeeded`, correct `GatewayType`/`VpnType`, and SKU capability match for the configured auth/tunnel types.

**Phase 2 — Configuration-object confirmation.** Walk `VpnClientConfiguration` end to end: address pool, protocols, auth types, root certs (if applicable), RADIUS server address (if applicable), Entra ID Audience (if applicable).

**Phase 3 — Upstream reachability (RADIUS/Entra ID only).** For RADIUS: confirm network path from gateway subnet to RADIUS server, including any dependent S2S tunnel. For Entra ID: confirm the app registration and Audience are correctly aligned between gateway and client.

**Phase 4 — Client-side verification.** Confirm OS/protocol/auth combination is valid per the compatibility matrix, the installed client software matches the auth type (native OS client vs. Azure VPN Client), and the profile package is current.

**Phase 5 — Routing verification (post-connect).** For "connects but can't reach X" tickets specifically, separate the client-OS route-refresh question (Windows needs a profile regen after topology changes; non-Windows doesn't) from a genuine BGP/transitive-routing gap.

**Phase 6 — Scale/capacity verification.** For intermittent, load-correlated failures, check address pool exhaustion and gateway SKU connection limits before assuming a configuration fault.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield P2S rollout for a new client</summary>

1. Confirm the target gateway's `VpnType` is route-based; if it's an existing policy-based gateway, plan a gateway rebuild (destructive, requires a maintenance window).
2. Choose auth type(s) based on requirements: Certificate for simplicity/small user counts, Entra ID for CA/MFA integration and centralized user management, RADIUS for reuse of existing enterprise auth (especially if AD CS integration or third-party MFA is already in place).
3. Size the SKU for the required feature set AND expected concurrent connections — Basic is rarely appropriate for anything beyond a proof-of-concept.
4. Size the client address pool generously above the expected peak concurrent user count; leave headroom for growth.
5. Configure and validate one test client fully before mass rollout — catching a protocol/auth mismatch on one device is far cheaper than after distributing to 200 users.
6. Document the profile package generation date in the client's own change log — this becomes the reference point for the next Windows-route-staleness ticket.
</details>

<details><summary>Playbook 2 — Migrating from Certificate auth to Microsoft Entra ID auth</summary>

1. Register the App ID (or confirm eligibility for the Microsoft-registered App ID path, which requires no manual tenant registration).
2. Enable Entra ID auth on the gateway ALONGSIDE the existing Certificate auth (multiple auth types can coexist) rather than cutting over in one step.
3. Pilot with a small user group using the Azure VPN Client (not the native OS client, which cannot do Entra ID auth).
4. Once validated, redistribute updated profile packages to the full user base, then disable Certificate auth on the gateway once confirmed nobody depends on it.
5. Apply Conditional Access policies to the VPN sign-in now that it's a genuine Entra ID authentication event — this is the main reason to migrate.

**Rollback:** re-enable/retain Certificate auth until Entra ID auth is fully validated in production; do not remove the old root certs until the migration is confirmed complete.
</details>

<details><summary>Playbook 3 — Diagnosing "worked yesterday, broken today" after an unrelated network change</summary>

1. Identify what changed: new peering, new S2S connection, BGP toggle, address pool resize, or a certificate rotation (including Azure's own periodic migration).
2. Determine client OS mix among affected users — if it's Windows-only, this strongly points at stale client profiles rather than a genuine gateway misconfiguration.
3. Regenerate the client profile package and redistribute; this alone resolves the majority of "worked yesterday" P2S tickets tied to a topology change.
4. If non-Windows clients are ALSO affected, the root cause is not profile staleness — proceed to a full gateway/auth-layer investigation instead.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Azure VPN Gateway Point-to-Site diagnostic evidence for escalation.
.DESCRIPTION
    Read-only. Gathers gateway SKU/type, VpnClientConfiguration (address pool, protocols,
    auth types, root certs, RADIUS/Entra ID settings), and flags common misconfigurations.
.PARAMETER ResourceGroupName
    Resource group containing the VPN Gateway.
.PARAMETER GatewayName
    Name of the VirtualNetworkGateway resource.
.EXAMPLE
    .\Get-P2SEvidence.ps1 -ResourceGroupName rg-network-prod -GatewayName vgw-hub-01
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$GatewayName
)

$gw = Get-AzVirtualNetworkGateway -ResourceGroupName $ResourceGroupName -Name $GatewayName

$evidence = [PSCustomObject]@{
    GatewayName          = $gw.Name
    GatewayType          = $gw.GatewayType
    VpnType              = $gw.VpnType
    SkuName              = $gw.Sku.Name
    ProvisioningState    = $gw.ProvisioningState
    AddressPool          = ($gw.VpnClientConfiguration.VpnClientAddressPool.AddressPrefixes -join ", ")
    Protocols            = ($gw.VpnClientConfiguration.VpnClientProtocols -join ", ")
    RootCertCount        = $gw.VpnClientConfiguration.VpnClientRootCertificates.Count
    RadiusServerAddress  = $gw.VpnClientConfiguration.RadiusServerAddress
    AadAudience          = $gw.VpnClientConfiguration.AadAudience
    AadTenant            = $gw.VpnClientConfiguration.AadTenant
    SkuIsBasicWithGap    = ($gw.Sku.Name -eq "Basic" -and (
                                $gw.VpnClientConfiguration.VpnClientProtocols -contains "IkeV2" -or
                                $null -ne $gw.VpnClientConfiguration.RadiusServerAddress
                            ))
}
$evidence | Format-List
$evidence | Export-Csv -Path ".\P2SEvidence_$($GatewayName)_$(Get-Date -Format yyyyMMdd_HHmm).csv" -NoTypeInformation
```

Escalate with this output attached alongside: affected user list, client OS breakdown, and the profile package generation timestamp.

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-AzVirtualNetworkGateway` | Gateway type, SKU, `VpnClientConfiguration` object |
| `(Get-AzVirtualNetworkGateway).VpnClientConfiguration.VpnClientAddressPool` | Client address pool prefixes |
| `(Get-AzVirtualNetworkGateway).VpnClientConfiguration.VpnClientRootCertificates` | Trusted root certs (Certificate auth) |
| `New-AzVpnClientRootCertificate` / `Add-AzVpnClientRootCertificate` | Upload a new trusted root |
| `Remove-AzVpnClientRootCertificate` | Revoke trust in a root (blocks all certs from that chain) |
| `Set-AzVirtualNetworkGatewayVpnClientConfig` | Update address pool / protocols / auth type |
| `New-AzVpnClientConfiguration` | Generate a fresh client profile package (regenerate after ANY config change) |
| `Resize-AzVirtualNetworkGateway` | Change gateway SKU (required to unlock IKEv2/RADIUS/IPv6 from Basic) |
| `(Get-AzVirtualNetworkGateway).VpnClientConfiguration.RadiusServerAddress` | Configured RADIUS server IP |
| `(Get-AzVirtualNetworkGateway).VpnClientConfiguration.AadAudience/AadTenant/AadIssuer` | Entra ID auth configuration |
| `Test-NetConnection -Port 1812` | RADIUS reachability check (UDP — result is indicative, not definitive) |
| `Get-AzVirtualNetworkGatewayConnection` | S2S connection status (RADIUS-on-prem dependency check) |

---
## 🎓 Learning Pointers

- **P2S and S2S look like variations on the same gateway resource but are architecturally and operationally distinct products.** The gateway resource type is shared; almost nothing else is. See [About Point-to-Site VPN connections](https://learn.microsoft.com/en-us/azure/vpn-gateway/point-to-site-about).
- **The Windows-vs-non-Windows client route-refresh asymmetry is the single most counter-intuitive fact in this topic** — a topology change silently breaks routing for Windows users while non-Windows users adapt automatically, purely due to how each platform's client handles the profile package. See [About Point-to-Site VPN routing](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-point-to-site-routing).
- **Authentication type and tunnel type are cross-constrained, not independently selectable** — Entra ID auth only ever rides OpenVPN, SSTP is Windows-only, and Basic SKU rules out IKEv2/RADIUS/IPv6 entirely. Check the compatibility matrix before assuming a bug.
- **RADIUS auth makes the gateway a pure pass-through** — it has zero ability to validate credentials itself, so on-prem RADIUS reachability (frequently via a separate S2S tunnel) is a hard, easy-to-overlook dependency.
- **Client profile packages are point-in-time snapshots that never self-update** — any gateway-side change (address pool, root cert, peering, Azure's own periodic root cert migration) requires a fresh package and redistribution to affected clients.
- **The Azure VPN Client for Linux retires 31 August 2026** — audit any Entra ID-authenticated Linux P2S deployment now, since Entra ID auth has no supported Linux path after that date. See [Azure VPN Client for Linux Retirement overview and migration guide](https://learn.microsoft.com/en-us/azure/vpn-gateway/azure-vpn-client-linux-retirement).
