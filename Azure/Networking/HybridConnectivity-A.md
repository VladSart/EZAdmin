# Azure Hybrid Connectivity (VPN Gateway & ExpressRoute) — Reference Runbook (Mode A: Deep Dive)
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

Covers Resource-Manager-deployment-model **Azure VPN Gateway** (site-to-site IPsec, route-based, with or without BGP) and **Azure ExpressRoute** (circuit provisioning, private/Microsoft peering, BGP) as the two supported paths for hybrid (on-premises ↔ Azure) network connectivity. Both are treated together here because MSP engineers frequently triage "on-prem can't reach Azure" tickets before knowing which path is in play — this runbook's Symptom → Cause Map is deliberately split by path once the initial gateway-type check narrows it down.

Does **not** cover: point-to-site VPN on a customer-managed gateway (individual user remote access — a different gateway configuration and a different failure domain, now its own dedicated topic — see `P2SVPN-A.md`/`P2SVPN-B.md`), Virtual WAN hub-and-spoke topologies (adds an additional routing layer — SD-WAN/hub routing intent — on top of everything here), Azure Firewall/NVA-based routing policy (covered only where it intersects directly with GatewaySubnet NSG/UDR behavior), or classic (non-Resource-Manager) deployment model gateways (legacy, rare in current client environments). Cross-reference `Azure/AVD/AVD-Connectivity-A.md` for AVD-specific NSG/service-tag guidance — that runbook treats NSG rules as they affect AVD reachability specifically, not as a general hybrid-connectivity topic.

---
## How It Works

<details><summary>Full architecture</summary>

**VPN Gateway (site-to-site).** A Virtual Network Gateway of type `Vpn` terminates an IPsec/IKE tunnel to an on-premises VPN device. The gateway lives in a dedicated `GatewaySubnet` inside the VNet — this subnet name is reserved and cannot be renamed. Two negotiation phases happen before any data flows:

- **IKE Phase 1** — establishes a secure channel between the two gateway endpoints using a pre-shared key (PSK) or certificate, negotiating an IKE Security Association (SA).
- **IKE Phase 2 (IPsec)** — establishes the actual IPsec SA(s) that encrypt data traffic, using the Phase 1 channel.

Once the IPsec tunnel shows `Connected`, traffic can flow using **static routing** (policy-based, or route-based with statically defined address prefixes) or **dynamic routing via BGP**. BGP is the modern default for anything beyond a single simple site — it eliminates the need to hand-maintain address-space lists on both ends and enables automatic failover across multiple tunnels.

**Critically, BGP for VPN Gateway runs as a session layered on top of the already-established IPsec tunnel.** If the tunnel isn't up, BGP cannot even attempt to peer — this is the single most common source of "BGP won't connect" tickets that are actually IPsec tickets. BGP requires a route-based VPN type (never policy-based) and any SKU except Basic. The two ASNs (Azure side and on-premises side) must differ — Azure's default gateway ASN is 65515 unless explicitly changed, and several ASNs are reserved and cannot be used on either side: 8074, 8075, 12076, 65515, 65517–65520 (IANA-reserved ranges apply too).

If the on-premises device uses APIPA (169.254.x.x) addresses for its BGP peer IP — common with some hardware VPN appliances that don't expose a routable loopback — Azure supports this only within the narrow reserved range **169.254.21.0–169.254.22.255**, and requires the on-premises device (not Azure) to initiate the BGP session.

BGP timers on VPN Gateway are **fixed, not tunable**: 60-second keepalive, 180-second hold timer (three missed keepalives = session drop). There is **no BFD (Bidirectional Forwarding Detection) support** for VPN Gateway site-to-site connections, meaning fast sub-second failure detection is not available on this path — a meaningful limitation to set expectations around when a client asks about failover speed.

**ExpressRoute** is architecturally a different animal entirely: a private, non-internet Layer 2/3 connection between an on-premises network and Microsoft's network, mediated by a connectivity provider. Three network zones are always involved, each independently owned and independently capable of failure:

```
Customer network (CE routers)
        │
Provider network (PE routers, or PE-MSEE in an IPVPN model)
        │
Microsoft network (MSEE — Microsoft Enterprise Edge routers)
```

Four connectivity models exist: **cloud exchange colocation** (customer colocated at a shared facility with an ExpressRoute location), **point-to-point Ethernet**, **any-to-any (IPVPN)** (provider's IPVPN service extends to Microsoft — most common with large telecom/MPLS providers), and **ExpressRoute Direct** (customer connects straight to an MSEE port over dark fiber, bypassing zones 3/4 entirely — 10 or 100 Gbps only).

Provisioning an ExpressRoute circuit establishes redundant Layer 2 connectivity between the CE/PE-MSEE pair and MSEE pair — this state is tracked by **two independent status fields**: `CircuitProvisioningState` (Microsoft's side — becomes `Enabled` once Microsoft's infrastructure is ready) and `ServiceProviderProvisioningState` (the provider's side — becomes `Provisioned` once the provider has completed their turn-up). Both must show the healthy value for the circuit to carry traffic; a stuck `Not enabled` is a Microsoft Support case, a stuck `Not provisioned` is a provider case, and an engineer troubleshooting from PowerShell alone cannot force either one.

Once the circuit is provisioned, **peering** is configured on top of it — either **Azure private peering** (for reaching private VNet resources — this is what most MSP clients mean by "ExpressRoute") or **Microsoft peering** (for reaching PaaS/SaaS public endpoints like Microsoft 365 or Azure Storage without transiting the public internet). Each peering runs its own eBGP session between the CE/PE-MSEE and the MSEE, using a dedicated `/30` subnet for the point-to-point interface addresses — Microsoft always takes the second usable IP in that /30, so the customer/provider side must be configured with the first usable IP, a frequently-missed detail during initial setup.

A Virtual Network Gateway of type `ExpressRoute` (a **separate gateway resource type** from the VPN gateway, even though both live in a `GatewaySubnet`) links the circuit's private peering to a specific VNet, making the circuit's routes available to that VNet's resources.

</details>

---
## Dependency Stack

```
Layer 6 — Destination resource NSG / route table / firewall
Layer 5 — Traffic (data plane)
Layer 4 — Route propagation
              VPN path: BGP-learned routes (or static routes) on the VPN gateway
              ExpressRoute path: routes on the MSEE route table, both primary + secondary paths
Layer 3 — Dynamic/static routing session
              VPN path: BGP session (ASN, peer IP, timers) — layered ON TOP of Layer 2
              ExpressRoute path: eBGP peering (VlanId, AzureASN, PeerASN, /30 subnets, optional MD5)
Layer 2 — Transport establishment
              VPN path: IPsec/IKE tunnel (PSK/cert, Phase 1 + Phase 2 SAs)
              ExpressRoute path: Layer 2 circuit provisioning across 3 independently-owned zones
                  (Customer CE → Provider PE → Microsoft MSEE)
Layer 1 — Physical/logical prerequisite
              VPN path: Validated on-prem VPN device, public IP reachability, correct gateway SKU/type
              ExpressRoute path: Physical cross-connect or provider circuit at a peering location,
                  Circuit + Provider provisioning state
```

A ticket at Layer 6 (traffic blocked despite everything below looking healthy) is the single most common false-escalation to "the VPN/ExpressRoute is broken" — always confirm Layers 1–4 are genuinely healthy before assuming the connectivity path itself is at fault, and always confirm Layers 1–4 before assuming a NSG/routing problem if they haven't been checked yet.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| VPN `ConnectionStatus: NotConnected`, 0 bytes transferred | IKE/PSK mismatch, unvalidated device, wrong peer IP | `Get-AzVirtualNetworkGatewayConnectionSharedKey`, compare peer IPs |
| VPN tunnel connects then drops within seconds | PFS mismatch, or IPsec/IKE policy mismatch between Azure and on-prem | Check on-prem PFS setting; compare custom IPsec/IKE policy if one is configured |
| VPN BGP peer `Unknown`/`Not connected` | IPsec tunnel not yet established (BGP can't start without it) | Verify `ConnectionStatus: Connected` first |
| VPN BGP peer `Connected`, `RoutesReceived: 0` | On-prem device not advertising, or an outbound route filter is blocking prefixes | `Get-AzVirtualNetworkGatewayLearnedRoute`; check on-prem BGP config |
| VPN BGP session repeatedly connects/disconnects | Packet loss exceeding 3 missed 60s keepalives (180s hold timer), or underlying IPsec tunnel flapping | `RouteDiagnosticLog` + `TunnelDiagnosticLog` correlation |
| VPN BGP session drops suddenly, previously stable | On-prem device started advertising >4,000 prefixes (hard session-drop limit, not a soft warning) | Count on-prem advertised prefixes |
| Azure VNet exact-match prefix missing from advertised routes | Gateway transit blocks exact-prefix advertisement by design — only superset prefixes are sent | Confirm this is expected, not a fault |
| Active-active VPN gateway — only one instance's BGP session connects | On-prem device not configured to peer with both gateway-instance BGP IPs | Confirm on-prem config lists both peer IPs |
| ExpressRoute `CircuitProvisioningState: Not enabled` | Microsoft-side provisioning incomplete/stuck | Escalate to Microsoft Support with service key — no local fix |
| ExpressRoute `ServiceProviderProvisioningState: Not provisioned` | Provider hasn't completed their turn-up | Escalate to circuit provider — no local fix |
| ExpressRoute eBGP peering state `Active` or `Idle` on MSEE route table | ASN/VLAN/subnet/MD5 mismatch between MSEE and CE/PE-MSEE | Compare `VlanId`, `AzureASN`, `PeerASN`, `/30` subnets on both ends |
| ExpressRoute peering config lookup returns "Sequence contains no matching element" | That peering type (Private/Microsoft) was never configured | Confirm with client which peering they actually expect |
| ExpressRoute BGP established, but a specific destination is unreachable | Prefix present on MSEE route table but blocked downstream by NSG/UDR/firewall | `Get-AzExpressRouteCircuitRouteTable`, then check NSG/UDR on destination |
| ExpressRoute traffic in one direction only (PsPing asymmetry) | Return-path routing issue (missing advertised prefix, UDR override) or provider-side routing fault | Interpret PsPing match pattern per direction |
| ExpressRoute performance degraded, connectivity otherwise fine | Scheduled Microsoft maintenance on the virtual network gateway infrastructure | Portal → Diagnose and solve problems → Performance Issues |
| Both VPN and ExpressRoute configured to the same VNet, unpredictable path selection | ExpressRoute is preferred by default when both exist and BGP is used on both — expected, not a fault, unless AS-path prepending was intended to change this | Confirm routing intent/design, don't assume misconfiguration |

---
## Validation Steps

1. **Confirm gateway type, SKU, and VPN type before any BGP troubleshooting.**
   ```powershell
   Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName> | Select GatewayType, VpnType, Sku, EnableBgp
   ```
   Good: SKU is not `Basic`; `VpnType: RouteBased` if BGP is expected. Bad: Basic SKU or PolicyBased type combined with a BGP requirement — this is an unsupported design, not a fixable fault.

2. **Confirm IPsec tunnel state before BGP.**
   ```powershell
   Get-AzVirtualNetworkGatewayConnection -ResourceGroupName <rg> -Name <connectionName> | Select ConnectionStatus
   ```
   Good: `Connected`. Bad: `NotConnected` — stop and resolve at Layer 2 before proceeding to Layer 3.

3. **Confirm BGP peer status and route counts.**
   ```powershell
   Get-AzVirtualNetworkGatewayBgpPeerStatus -ResourceGroupName <rg> -VirtualNetworkGatewayName <gatewayName>
   Get-AzVirtualNetworkGatewayLearnedRoute -ResourceGroupName <rg> -VirtualNetworkGatewayName <gatewayName>
   Get-AzVirtualNetworkGatewayAdvertisedRoute -ResourceGroupName <rg> -VirtualNetworkGatewayName <gatewayName> -Peer <onPremPeerIp>
   ```
   Good: `State: Connected`, non-zero learned routes with `Origin: EBgp`, expected VNet prefixes in advertised output. Bad: `RoutesReceived: 0` or missing expected prefixes.

4. **Confirm ExpressRoute circuit and provider provisioning state.**
   ```powershell
   Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName> | Select CircuitProvisioningState, ServiceProviderProvisioningState
   ```
   Good: `Enabled` / `Provisioned`. Bad: either field not in its healthy state — escalate per ownership, do not continue local troubleshooting.

5. **Confirm ExpressRoute peering configuration matches the linked CE/PE-MSEE.**
   ```powershell
   $ckt = Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName>
   Get-AzExpressRouteCircuitPeeringConfig -Name "AzurePrivatePeering" -ExpressRouteCircuit $ckt
   ```
   Good: `ProvisioningState: Succeeded`, subnet/ASN/VLAN values match the known-good customer/provider config. Bad: values don't match, or the peering doesn't exist at all yet the client expects it to.

6. **Confirm eBGP peering state on the MSEE route table itself.**
   ```powershell
   Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName <circuitName> -PeeringType AzurePrivatePeering -ResourceGroupName <rg>
   ```
   Good: Routes present with a populated `Path` (AS path). Bad: `Active`/`Idle` peering state, or an empty table despite `Established` state (rare — indicates a route-filtering issue rather than a peering issue).

7. **Confirm traffic flow with real byte counters, not just session state.**
   ```powershell
   Get-AzExpressRouteCircuitStats -ResourceGroupName <rg> -ExpressRouteCircuitName <circuitName> -PeeringType AzurePrivatePeering
   ```
   Good: Non-zero, growing `PrimaryBytesIn`/`PrimaryBytesOut`. Bad: Zero bytes despite a healthy-looking BGP session — strongly suggests an NSG/UDR/firewall block downstream rather than a connectivity-path fault.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Classify the path.** Run the Layer-1 checks (gateway type for VPN; circuit + provider status for ExpressRoute) before doing anything else. This single step prevents the most time-wasting mistake in this domain: troubleshooting BGP config on a path where the underlying transport was never actually up.

**Phase 2 — Validate transport (Layer 2).** VPN: confirm `ConnectionStatus: Connected` and, if not, work the IKE/PSK/device-validation checklist. ExpressRoute: confirm both `CircuitProvisioningState` and `ServiceProviderProvisioningState`, and if either is stuck, hand off to the correct owner (Microsoft Support or the provider) rather than continuing to troubleshoot locally — there is genuinely nothing further to check from the customer/MSP side.

**Phase 3 — Validate routing session (Layer 3).** VPN: BGP peer state, ASN/peer-IP correctness, APIPA range compliance if applicable. ExpressRoute: eBGP peering state on the MSEE, subnet/VLAN/ASN/MD5 match against the linked CE/PE-MSEE.

**Phase 4 — Validate route propagation (Layer 4).** Learned and advertised routes (VPN) or MSEE route table contents (ExpressRoute). This is where "gateway transit doesn't advertise exact prefixes" and "4,000-prefix session-drop limit" show up as legitimate, documented, non-bug behaviors that are easy to mistake for faults.

**Phase 5 — Validate data plane (Layers 5–6).** Byte counters, PsPing private-peering connectivity test (ExpressRoute), and NSG/UDR review on both the GatewaySubnet and the destination subnet. A healthy control plane (BGP Established, routes present) with zero data-plane traffic is the classic signature of a downstream network security block, not a connectivity-path fault.

**Phase 6 — Escalate with evidence, not conclusions.** For anything that traces to the provider network zone or Microsoft's MSEE/circuit infrastructure, the fastest resolution path is a well-evidenced ticket to the correct owner, not further local diagnosis. Include the service key (ExpressRoute) or connection/gateway resource IDs (VPN) in every escalation.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrate a static-route VPN connection to BGP</summary>

**When to use:** Client is manually maintaining address-space lists on a policy-based or static route-based connection and wants automatic route propagation and multi-tunnel failover.

1. Confirm current gateway is not Basic SKU — BGP requires an upgrade first if it is (`Resize-AzVirtualNetworkGateway` or resource recreation depending on SKU generation).
2. Confirm `VpnType: RouteBased` — policy-based gateways must be recreated as route-based; this is not an in-place conversion.
3. Assign a non-default, non-reserved ASN on the Azure side if the default 65515 conflicts with anything on the on-prem side (rare, but check first): `Set-AzVirtualNetworkGateway -Asn <asn>`.
4. Configure the on-prem device with the Azure BGP peer IP (not the gateway public IP) and the Azure ASN, matching Microsoft's sample config for the validated device model.
5. Enable BGP on the connection object: `Set-AzVirtualNetworkGatewayConnection -EnableBgp $true`.
6. Verify learned/advertised routes populate before removing any legacy static address-space entries — run both configurations in parallel briefly to confirm BGP is actually working before cutting over.

**Rollback:** Disable BGP on the connection (`-EnableBgp $false`) and restore the static address-space list — the underlying IPsec tunnel is unaffected by this change, so rollback carries minimal risk.

</details>

<details><summary>Playbook 2 — Recover from an ExpressRoute provider-side outage</summary>

**When to use:** `ServiceProviderProvisioningState` shows `Not provisioned` unexpectedly on a previously-healthy circuit, or the provider reports a maintenance/outage event.

1. Confirm this is genuinely provider-side by checking `CircuitProvisioningState` remains `Enabled` — if both fields degrade simultaneously, treat as a Microsoft-side event instead and open a Microsoft Support case.
2. Pull the circuit's Service Key (`Get-AzExpressRouteCircuit` → `ServiceKey`) — this is the required identifier for any provider or Microsoft ticket.
3. If a secondary/backup path exists (VPN Gateway as an ExpressRoute failover, or a redundant circuit), confirm routing has failed over as expected — remember ExpressRoute is generally preferred over a VPN Gateway path by default when both exist, so a properly configured failover VPN should already be carrying traffic; if it isn't, check whether BGP AS-path prepending or local preference was set up correctly for the failover scenario.
4. Engage the provider with the service key and a timeline of the `ServiceProviderProvisioningState` transition.
5. Once the provider confirms restoration, re-verify `ServiceProviderProvisioningState: Provisioned` and re-check the MSEE route table before declaring the incident resolved — a provider's "it's fixed" claim should be independently confirmed against Azure-side state.

**Rollback:** N/A — this is an availability incident, not a configuration change; no rollback required, only restoration confirmation.

</details>

<details><summary>Playbook 3 — Correct an ExpressRoute peering mismatch without extended downtime</summary>

**When to use:** eBGP peering state is `Active`/`Idle` due to a confirmed VLAN/ASN/subnet mismatch, and the circuit otherwise carries production traffic (correcting it live, not during a maintenance window).

1. Document the exact current (broken) values and the target (correct) values for `VlanId`, `PeerASN`, and the `/30` subnet pair — this MUST be coordinated with whoever controls the CE/PE-MSEE side; a unilateral Azure-side change without a matching on-prem/provider change will not fix anything and may worsen the mismatch.
2. Schedule the change with the customer/provider — this is inherently a two-sided coordination task, not a single PowerShell command.
3. Apply the corrected peering config on the Azure side:
   ```powershell
   $ckt = Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName>
   Set-AzExpressRouteCircuitPeeringConfig -Name "AzurePrivatePeering" -ExpressRouteCircuit $ckt `
       -PeerASN <correctedAsn> -PrimaryPeerAddressPrefix <correctedPrefix1> -SecondaryPeerAddressPrefix <correctedPrefix2> -VlanId <correctedVlan>
   Set-AzExpressRouteCircuit -ExpressRouteCircuit $ckt
   ```
4. Confirm the CE/PE-MSEE-side change lands within the same window — a partial (one-sided) correction leaves the peering broken in a new way.
5. Re-verify with `Get-AzExpressRouteCircuitRouteTable` post-change.

**Rollback:** Re-apply the prior (documented) values via the same cmdlet pattern — since this is a coordinated two-sided change, rollback also requires reverting the CE/PE-MSEE side in lockstep.

</details>

<details><summary>Playbook 4 — Fleet-wide hybrid connectivity health sweep (multi-client MSP scenario)</summary>

**When to use:** Proactive health check across multiple client subscriptions/tenants, or after a broad Azure/provider advisory affecting VPN or ExpressRoute services.

1. Run `Scripts/Get-HybridConnectivityHealth.ps1` against each client subscription (script supports both single-resource-group and subscription-wide sweep modes).
2. Triage output by severity: `NotConnected` VPN connections and `Not enabled`/`Not provisioned` ExpressRoute circuits are P1 (active outage); flapping/degraded BGP sessions and near-prefix-limit route counts are P2 (at-risk, proactive fix); healthy-but-undocumented configs (e.g., missing diagnostic logging) are P3 (hygiene).
3. For any P1 finding, immediately cross-check whether it correlates with a known Azure Service Health advisory before starting local troubleshooting — a broad regional VPN Gateway or ExpressRoute platform issue looks identical to a local misconfiguration in the first few commands.

**Rollback:** N/A — read-only sweep, no configuration changes.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS Collects hybrid connectivity diagnostic evidence for VPN Gateway and/or ExpressRoute escalation.
#>
param(
    [string]$ResourceGroupName,
    [string]$VpnGatewayName,
    [string]$VpnConnectionName,
    [string]$ExpressRouteCircuitName
)

$evidence = [ordered]@{}

if ($VpnGatewayName) {
    $gw = Get-AzVirtualNetworkGateway -ResourceGroupName $ResourceGroupName -Name $VpnGatewayName
    $evidence.GatewayType   = $gw.GatewayType
    $evidence.VpnType       = $gw.VpnType
    $evidence.Sku           = $gw.Sku.Name
    $evidence.EnableBgp     = $gw.EnableBgp
    if ($VpnConnectionName) {
        $conn = Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $ResourceGroupName -Name $VpnConnectionName
        $evidence.ConnectionStatus = $conn.ConnectionStatus
        $evidence.IngressBytes     = $conn.IngressBytesTransferred
        $evidence.EgressBytes      = $conn.EgressBytesTransferred
    }
    if ($gw.EnableBgp) {
        $evidence.BgpPeerStatus  = Get-AzVirtualNetworkGatewayBgpPeerStatus -ResourceGroupName $ResourceGroupName -VirtualNetworkGatewayName $VpnGatewayName
        $evidence.LearnedRoutes  = Get-AzVirtualNetworkGatewayLearnedRoute -ResourceGroupName $ResourceGroupName -VirtualNetworkGatewayName $VpnGatewayName
    }
}

if ($ExpressRouteCircuitName) {
    $ckt = Get-AzExpressRouteCircuit -ResourceGroupName $ResourceGroupName -Name $ExpressRouteCircuitName
    $evidence.CircuitProvisioningState         = $ckt.CircuitProvisioningState
    $evidence.ServiceProviderProvisioningState = $ckt.ServiceProviderProvisioningState
    $evidence.ServiceKey                       = $ckt.ServiceKey
    try {
        $evidence.PrivatePeeringRouteTable = Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName $ExpressRouteCircuitName -PeeringType AzurePrivatePeering -ResourceGroupName $ResourceGroupName
    } catch { $evidence.PrivatePeeringRouteTable = "Not configured or not retrievable: $($_.Exception.Message)" }
    try {
        $evidence.CircuitStats = Get-AzExpressRouteCircuitStats -ResourceGroupName $ResourceGroupName -ExpressRouteCircuitName $ExpressRouteCircuitName -PeeringType AzurePrivatePeering
    } catch { $evidence.CircuitStats = "Not retrievable: $($_.Exception.Message)" }
}

$evidence | ConvertTo-Json -Depth 6 | Out-File ".\HybridConnectivity-Evidence-$(Get-Date -Format yyyyMMdd-HHmm).json"
Write-Host "Evidence collected. Attach the JSON file to the escalation ticket." -ForegroundColor Green
```

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| Gateway type/SKU/BGP flag | `Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gw>` |
| VPN connection (tunnel) status | `Get-AzVirtualNetworkGatewayConnection -ResourceGroupName <rg> -Name <conn>` |
| VPN shared key (view/reset) | `Get-AzVirtualNetworkGatewayConnectionSharedKey` / `Set-AzVirtualNetworkGatewayConnectionSharedKey` |
| VPN BGP peer status | `Get-AzVirtualNetworkGatewayBgpPeerStatus -ResourceGroupName <rg> -VirtualNetworkGatewayName <gw>` |
| VPN learned routes | `Get-AzVirtualNetworkGatewayLearnedRoute -ResourceGroupName <rg> -VirtualNetworkGatewayName <gw>` |
| VPN advertised routes | `Get-AzVirtualNetworkGatewayAdvertisedRoute -ResourceGroupName <rg> -VirtualNetworkGatewayName <gw> -Peer <ip>` |
| Reset VPN gateway | `Reset-AzVirtualNetworkGateway -ResourceGroupName <rg> -VirtualNetworkGatewayName <gw>` |
| VPN health probe | `https://<GatewayPublicIP>:8081/healthprobe` (8083 for active-active secondary) |
| ExpressRoute circuit status | `Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <ckt>` |
| ExpressRoute peering config | `Get-AzExpressRouteCircuitPeeringConfig -Name <peeringType> -ExpressRouteCircuit $ckt` |
| ExpressRoute MSEE route table | `Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName <ckt> -PeeringType <type> -ResourceGroupName <rg>` |
| ExpressRoute traffic stats | `Get-AzExpressRouteCircuitStats -ResourceGroupName <rg> -ExpressRouteCircuitName <ckt> -PeeringType <type>` |
| ExpressRoute ARP table | See [Getting ARP tables](https://learn.microsoft.com/en-us/azure/expressroute/expressroute-troubleshooting-arp-resource-manager) |
| RouteDiagnosticLog KQL (BGP events) | `AzureDiagnostics \| where Category == "RouteDiagnosticLog"` |
| GatewaySubnet NSG/UDR check | `Get-AzVirtualNetworkSubnetConfig -Name GatewaySubnet -VirtualNetwork $vnet` |
| Portal ExpressRoute diagnostics | Circuit → Diagnose and solve problems → Connectivity & Performance issues |

---
## 🎓 Learning Pointers

- **Two independently-owned provisioning states gate every ExpressRoute circuit** — `CircuitProvisioningState` (Microsoft) and `ServiceProviderProvisioningState` (the provider). Recognizing which one is stuck in the first 30 seconds of a ticket saves hours of misdirected local troubleshooting. [Verify ExpressRoute connectivity](https://learn.microsoft.com/en-us/troubleshoot/azure/expressroute/expressroute-troubleshooting-expressroute-overview)

- **BGP on VPN Gateway has zero BFD support and fixed 60s/180s timers** — this is a hard platform limitation, not a configuration gap. Set client expectations accordingly for failover-speed requirements; if sub-second failover matters, the conversation needs to be about ExpressRoute with a redundant circuit, not VPN Gateway BGP tuning. [Troubleshoot BGP issues for Azure VPN Gateway](https://learn.microsoft.com/en-us/troubleshoot/azure/vpn-gateway/vpn-gateway-troubleshoot-bgp)

- **The 4,000-prefix VPN Gateway BGP limit drops the whole session, not just the overflow routes.** A single overly-granular on-prem route table can look exactly like a random, unexplained BGP outage until the prefix count is actually checked.

- **Gateway transit's exact-prefix-match block is a documented, permanent behavior**, not something to troubleshoot around — a VNet always advertises via a superset prefix under gateway transit, never its own exact CIDR. [BGP FAQ — advertise exact prefixes](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-vpn-faq#advertise-exact-prefixes)

- **A healthy BGP/peering session with zero data-plane bytes is the signature of a downstream NSG/UDR/firewall block**, not a connectivity-path fault — always check `Get-AzExpressRouteCircuitStats` byte counters (or VPN connection ingress/egress bytes) as a control-plane-vs-data-plane sanity check before re-touching BGP or peering config.

- **PsPing private-peering test results have direction-specific meanings** — matching results in one direction but not the other point to a return-path routing problem, which is often on the provider/on-prem side and outside the scope of anything fixable from the Azure portal alone. [Verify ExpressRoute connectivity — Test private peering connectivity](https://learn.microsoft.com/en-us/troubleshoot/azure/expressroute/expressroute-troubleshooting-expressroute-overview)
