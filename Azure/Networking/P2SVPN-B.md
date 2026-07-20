# Azure VPN Gateway Point-to-Site (P2S) — Hotfix Runbook (Mode B: Ops)
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

Point-to-Site (P2S) is an **individual client → Azure VNet** VPN — a different gateway configuration, protocol set, and failure domain from Site-to-Site (S2S). Do not reuse S2S/`HybridConnectivity-B.md` triage here; confirm this is genuinely P2S first.

```powershell
# 1. Confirm gateway supports P2S and which auth types are configured
Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName> | Select-Object GatewayType, VpnType, Sku, VpnClientConfiguration

# 2. Gateway SKU — Basic does NOT support IKEv2, IPv6, or RADIUS auth (silent failure otherwise)
(Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName>).Sku.Name

# 3. Client address pool health — is it configured, and not exhausted/overlapping?
(Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName>).VpnClientConfiguration.VpnClientAddressPool

# 4. Root certificate(s) trusted by the gateway (Certificate auth only)
(Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName>).VpnClientConfiguration.VpnClientRootCertificates | Select-Object Name

# 5. On the CLIENT: is the installed VPN client profile stale? (topology or root-cert changes require a re-download)
# Windows: Settings > Network & Internet > VPN > <profile> — check "last updated" against the portal's package generation time
```

| Finding | Interpretation | Do this |
|---|---|---|
| `VpnClientConfiguration` is `$null` | P2S was never configured on this gateway | Not a P2S problem — check if the ticket actually means S2S; escalate to design if P2S is genuinely needed |
| `Sku.Name` is `Basic` and auth type is RADIUS or tunnel type includes IKEv2 | Unsupported combination — Basic SKU silently can't do this | Resize the gateway SKU (destructive resize, causes brief downtime) — see Fix 5 |
| Address pool present but small (e.g. `/29`) and many users report failure at peak hours | Pool exhaustion — no free IPs left to assign | Fix 1 |
| Root certificate list is empty but auth type includes Certificate | No trusted root uploaded — every client cert will be rejected | Fix 2 |
| Client profile "last updated" predates a recent VNet peering/topology change or Azure's periodic root-cert rotation | Stale client profile — routes or trust chain are out of date | Fix 3 |
| Entra ID auth configured, client is on Linux | Unsupported — Entra ID auth is OpenVPN-only via the Azure VPN Client, and the Linux Azure VPN Client retires 31 Aug 2026 | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Gateway SKU supports the chosen tunnel type + auth type
    │  (Basic SKU: no IKEv2, no IPv6, no RADIUS — silent capability ceiling, not an error message)
    ▼
VpnClientConfiguration exists on the gateway
    ├─ VpnClientAddressPool configured, non-overlapping with VNet/on-prem ranges, not exhausted
    ├─ VpnClientProtocols / TunnelType selected (OpenVPN / SSTP / IKEv2, or a combination)
    └─ Authentication type(s) selected — Certificate / Microsoft Entra ID / RADIUS (can select more than one)
            │
            ├─ Certificate ──> Root CA public key uploaded to gateway
            │                       │
            │                       ▼
            │                  Client has an installed cert issued FROM that root
            │
            ├─ Microsoft Entra ID ──> OpenVPN tunnel type only; Azure VPN Client required
            │                              │
            │                              ▼
            │                         App ID / Audience value configured (Microsoft-registered or custom)
            │
            └─ RADIUS ──> On-prem or Azure-hosted RADIUS server reachable FROM the gateway subnet
                                │  (on-prem RADIUS needs a working S2S tunnel for reachability)
                                ▼
                           RADIUS server validates against AD / integrates with AD CS for cert auth
    ▼
Client downloads VPN client profile configuration package (generated AFTER the above is set)
    │  stale package = stale routes + stale trust chain, not auto-refreshed
    ▼
Client establishes tunnel — protocol/auth combination must match what the CLIENT device OS supports
    │
    ▼
Routing: which VNets/on-prem sites the client can reach after connecting
    │  (peering vs. S2S-BGP vs. non-BGP all produce DIFFERENT route sets — see P2SVPN-A.md)
    ▼
Traffic flows
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm this is P2S, not S2S.** `GatewayType` must be `Vpn` and the complaint must be an individual user, not a whole site. Expected: user-specific symptom. Bad sign: multiple users at one physical office all affected — that's likely S2S/on-prem, not P2S.

2. **Check gateway SKU capability ceiling.**
   ```powershell
   (Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName>).Sku.Name
   ```
   Expected: `VpnGw1` or higher if using IKEv2/RADIUS/IPv6. Bad sign: `Basic` — this SKU is legacy, capped, and silently drops these features rather than erroring clearly.

3. **Check client address pool utilization.**
   ```powershell
   $gw = Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName>
   $gw.VpnClientConfiguration.VpnClientAddressPool.AddressPrefixes
   ```
   Expected: a pool sized comfortably above concurrent-connection peak (a `/24` supports ~250 clients; a `/29` supports only ~5). Bad sign: users can connect off-peak but fail during business hours — classic exhaustion pattern.

4. **Check root certificate trust chain (Certificate auth).**
   ```powershell
   $gw.VpnClientConfiguration.VpnClientRootCertificates | Select-Object Name, PublicCertData
   ```
   Expected: at least one root present, matching the CA that issued the client's cert. Bad sign: empty list, or the client cert's issuer doesn't match any listed root — every connection attempt is rejected at the cert-validation step before any tunnel negotiation.

5. **Check for Azure's periodic P2S root certificate migration.** Azure rotates the gateway's own server-side root cert on a schedule with advance notice. Expected: client profile downloaded after the migration date. Bad sign: gateway continues to "work" from Azure's side but ALL clients — not just Certificate-auth ones — start failing simultaneously; this affects every auth type since it's the gateway's own server certificate, not the client trust chain.

6. **On the client: confirm protocol/auth support matches the client OS.**
   | Auth type | Supported tunnel types | Client OS constraint |
   |---|---|---|
   | Certificate | IKEv2, SSTP (Windows); IKEv2 (macOS); OpenVPN (all) | SSTP is Windows-only |
   | Microsoft Entra ID | OpenVPN only | Azure VPN Client required; Windows/macOS only for Entra ID; Linux client retires 31 Aug 2026 |
   | RADIUS | IKEv2, SSTP, OpenVPN | Not supported on Basic SKU |

   Bad sign: a mixed fleet (e.g., some Linux users) configured only for SSTP+Certificate — those clients have no valid path at all.

7. **Validate end-to-end after any fix.**
   ```powershell
   # Re-generate and hand the client a fresh profile package after ANY gateway-side config change
   New-AzVpnClientConfiguration -ResourceGroupName <rg> -VirtualNetworkGatewayName <gatewayName> -AuthenticationMethod EAPTLS
   ```
   Expected: a download URL for a fresh `.zip`. Every client must reinstall this after root cert, address pool, or auth-type changes — the old profile does not self-update.

---
## Common Fix Paths

<details><summary>Fix 1 — Client address pool exhausted</summary>

```powershell
$gw = Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName>
Set-AzVirtualNetworkGatewayVpnClientConfig -VirtualNetworkGateway $gw -VpnClientAddressPool @("172.16.0.0/22")
```
Pick a pool that does not overlap the VNet's own address space, any peered VNet, or any on-prem range reachable via S2S/ExpressRoute — an overlapping pool causes silent asymmetric routing failures, not a clean error. This operation does not require a full gateway resize and is non-destructive to existing connections, but new connections may briefly be unavailable during the update (typically under a minute).

**Rollback:** re-run with the previous prefix if the new range turns out to collide with something discovered after the fact.
</details>

<details><summary>Fix 2 — Missing or wrong root certificate (Certificate auth)</summary>

```powershell
# Export the root CA's public key as Base64 (no private key), then:
$cert = New-AzVpnClientRootCertificate -Name "RootCert01" -PublicCertData "<Base64CertData>"
Add-AzVpnClientRootCertificate -VpnClientRootCertificateName "RootCert01" -VirtualNetworkGatewayName <gatewayName> -ResourceGroupName <rg> -PublicCertData "<Base64CertData>"
```
Confirm the client's installed certificate was issued **from this exact root** (or an intermediate chaining to it) — a self-signed cert generated with a different tool/root than the one uploaded will always fail validation even though everything "looks" configured.

**Rollback:** `Remove-AzVpnClientRootCertificate` to pull a compromised or wrong root; existing clients using that root immediately lose the ability to connect.
</details>

<details><summary>Fix 3 — Stale client profile (topology change or root-cert migration)</summary>

```powershell
New-AzVpnClientConfiguration -ResourceGroupName <rg> -VirtualNetworkGatewayName <gatewayName> -AuthenticationMethod EAPTLS
```
Redistribute the resulting package to affected users. This is required — not optional — after: peering changes to the gateway's VNet, Azure's own periodic P2S root certificate migration, or any change to `VpnClientAddressPool`/auth configuration. Windows clients are the most visible symptom of this gap because Windows silently keeps using stale routes rather than erroring.

**Rollback:** none needed — this is a read/regenerate operation, not a destructive change.
</details>

<details><summary>Fix 4 — RADIUS authentication timing out or rejecting all clients</summary>

```powershell
# Confirm the gateway's configured RADIUS server IP and shared secret
(Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName>).VpnClientConfiguration.RadiusServerAddress
```
If the RADIUS server is on-premises, the gateway reaches it **through the same VNet's S2S tunnel** — if that S2S tunnel is down, RADIUS auth fails for every P2S user simultaneously even though P2S itself looks configured correctly. Check `HybridConnectivity-B.md` Fix 1 for the S2S tunnel first. If RADIUS is Azure-hosted (e.g., NPS on an Azure VM), confirm NSG rules allow UDP 1812/1813 from the gateway subnet.

**Rollback:** switch to Certificate auth temporarily as a fallback while the RADIUS path is repaired (requires clients to already have or receive certificates).
</details>

<details><summary>Fix 5 — Gateway SKU can't support the required feature (Basic SKU ceiling)</summary>

```powershell
$gw = Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName>
Resize-AzVirtualNetworkGateway -VirtualNetworkGateway $gw -GatewaySku VpnGw1
```
Basic SKU is legacy and does not support IKEv2, IPv6, or RADIUS — there is no in-place feature flag to unlock these; the SKU itself must change. This causes a brief connectivity interruption for all existing P2S and S2S connections on the gateway (typically a few minutes) — schedule during a maintenance window.

**Rollback:** gateway SKU downgrades are not supported the same way; if a resize causes unexpected issues, resize forward to a still-higher SKU rather than attempting to reverse it, and open a support case if a genuine rollback is required.
</details>

<details><summary>Fix 6 — Microsoft Entra ID auth failing or unsupported client OS</summary>

Confirm the client OS and tunnel combination: Entra ID auth is **OpenVPN-only**, requires the **Azure VPN Client** app (not the native OS VPN client), and is supported on Windows and macOS. The Azure VPN Client for **Linux retires 31 August 2026** — Linux users need Certificate or RADIUS auth instead after that date.

```powershell
# Confirm which Audience/App ID the gateway is configured with
(Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName>).VpnClientConfiguration.AadAudience
```
A P2S gateway supports only **one** Audience value at a time — mixing the Microsoft-registered App ID with a manually-registered or custom Audience on the same gateway is not possible; pick one and update all client profiles to match.

**Rollback:** none — this is a configuration-alignment fix, not a destructive change.
</details>

<details><summary>Fix 7 — "No policy match" / IKE proposal mismatch on connect</summary>

The client and gateway must agree on IKE/IPsec cipher suites. Azure's P2S gateway uses a fixed set of default policies (GCM_AES256/SHA256/SHA384 families across several DH groups) — a hardened or custom client-side IPsec policy that doesn't include any of these will fail to negotiate. Prefer the Azure-provided VPN client profile package over a hand-built client configuration, since it embeds compatible policy values automatically.

**Rollback:** none — revert any manually-edited client-side IPsec policy file back to the values from the downloaded profile package.
</details>

<details><summary>Fix 8 — Internal DNS names don't resolve over the P2S tunnel</summary>

P2S connects the client's IP layer to the VNet but does not automatically configure DNS. Confirm the VNet's DNS settings (custom DNS server vs. Azure-provided) are what the client needs, and that the client's OS is honoring the DNS suffix/servers pushed in the client profile package — some third-party OpenVPN clients ignore embedded DNS settings by default and require manual `--dhcp-option DNS` configuration.

**Rollback:** none — this is a configuration/verification fix.
</details>

---
## Escalation Evidence

```
Ticket: P2S VPN connectivity failure
Client / Tenant: <name>
Gateway resource ID: <subscription>/<rg>/<gatewayName>
Gateway SKU: <e.g. VpnGw1>
Auth type(s) configured: <Certificate / Entra ID / RADIUS>
Tunnel type(s) configured: <OpenVPN / SSTP / IKEv2>
Affected user(s): <UPN / device name / OS>
VpnClientAddressPool: <prefix>
Client profile package generated on: <date> vs. last topology/cert change on: <date>
Symptom: <can't connect at all / connects but no route to X / auth rejected / DNS not resolving>
Error message from client (verbatim): <paste>
Root cert / RADIUS server checked: <yes/no, result>
Escalation reason: <SKU resize needed / on-prem RADIUS unreachable / Azure-side root cert migration in progress / other>
```

---
## 🎓 Learning Pointers

- **P2S and S2S share a gateway resource type but are functionally two different products with different failure domains.** Never reuse S2S triage steps for a P2S ticket — check `GatewayType`/`VpnType` first. See [About Point-to-Site VPN connections](https://learn.microsoft.com/en-us/azure/vpn-gateway/point-to-site-about).
- **A stale client profile is one of the highest-frequency, lowest-visibility P2S failure modes.** Windows clients silently keep using old routes and old trust chains after a topology change or Azure's own periodic root-cert rotation — there's no client-side warning. Always ask "when was the profile last regenerated" before deep technical troubleshooting.
- **Basic gateway SKU is a silent capability ceiling, not an error state.** IKEv2, IPv6, and RADIUS auth simply don't work on Basic — there's no clear failure message pointing at the SKU. See [VPN Gateway settings](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings#gwsku).
- **Microsoft Entra ID auth is OpenVPN-only and requires the Azure VPN Client app** — it cannot be mixed-and-matched arbitrarily with other tunnel types, and a P2S gateway supports only one Audience value at a time.
- **On-premises RADIUS reachability for P2S depends on a healthy S2S tunnel from the SAME gateway** — an S2S outage silently breaks RADIUS-authenticated P2S too, even though P2S itself looks fully configured. Cross-reference `HybridConnectivity-B.md`.
- **The Azure VPN Client for Linux retires 31 August 2026** — flag any Linux-based P2S deployment using Entra ID auth now, since that auth path has no Linux path afterward. See [Azure VPN Client for Linux Retirement](https://learn.microsoft.com/en-us/azure/vpn-gateway/azure-vpn-client-linux-retirement).
