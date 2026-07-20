# Azure ExpressRoute — Reference Runbook (Mode A: Deep Dive)
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

Covers **Azure ExpressRoute** as its own architectural topic, at a depth beyond what `HybridConnectivity-A.md` treats jointly with VPN Gateway: the circuit provisioning model (customer/provider/Microsoft three-party handoff), the two peering types (Azure Private Peering and Microsoft Peering) as independent routing domains, Route Filters, circuit SKU/tier economics and their hard prefix-limit consequences, ExpressRoute Direct (customer-owned physical ports bypassing a connectivity provider), Global Reach (circuit-to-circuit interconnection), FastPath (gateway data-plane bypass), gateway SKU sizing, and Connection Monitor / Traffic Collector for ongoing health visibility.

Assumes the reader already understands baseline hybrid-connectivity concepts (VNets, gateways, BGP fundamentals) from `HybridConnectivity-A.md` — this file does not re-explain what a Virtual Network Gateway is in general, only what's ExpressRoute-specific about it.

Does **not** cover: VPN Gateway site-to-site/point-to-site (see `HybridConnectivity-A.md`), Virtual WAN's own hub-embedded ExpressRoute Gateway model (see `VirtualWAN-A.md` — the hub absorbs some of this file's gateway-sizing concerns into its own scale-unit model), Azure Private Peering's downstream NSG/UDR data-plane behavior once traffic reaches a VNet (see `NSG-A.md`), or Private DNS resolution across an ExpressRoute-connected hybrid network (see `PrivateDNS-A.md` — DNS is a separate dependency chain layered on top of whatever connectivity this file establishes).

---
## How It Works

<details><summary>Full architecture</summary>

**The three-party provisioning model.** Unlike VPN Gateway, which is a two-party (customer ↔ Azure) IPsec relationship, a standard ExpressRoute circuit involves three parties: the customer, a connectivity provider (a carrier operating cross-connects at a Microsoft peering location), and Microsoft. This is why a circuit carries **two independent provisioning-state fields**: `CircuitProvisioningState` (Microsoft's side — did Microsoft finish configuring the circuit) and `ServiceProviderProvisioningState` (the provider's side — did the provider complete the physical/logical cross-connect). Both must show provisioned/enabled before the circuit is usable; either one can be stuck independently of the other, and only the owning party can resolve their half. This is the most common source of confusion for engineers used to Azure-only resources, where a single `ProvisioningState` is normally sufficient.

**ExpressRoute Direct** is the alternative provisioning model: the customer obtains their own physical 10 Gbps or 100 Gbps ports directly into Microsoft's network at a peering location, eliminating the connectivity-provider party entirely. Circuits are then created *on top of* the ExpressRoute Direct resource (a "sub-circuit" model), sharing the physical bandwidth as multiple logical circuits with their own billing and SKU. This is a specialist deployment (large enterprises, cross-jurisdiction data-sovereignty requirements needing MACsec at the physical layer) — most MSP client engagements use standard provider-based circuits.

**Two independent peering types.** A circuit can have Azure Private Peering, Microsoft Peering, or both — configured, provisioned, and monitored entirely separately:

- **Azure Private Peering** — routes between on-premises and Azure VNets (via an ExpressRoute Gateway attached to the VNet/hub). This is the peering type analogous to what a VPN Gateway's site-to-site tunnel provides, but over a private circuit instead of IPsec-over-internet.
- **Microsoft Peering** — routes between on-premises and Microsoft's public/SaaS services (Microsoft 365, and public Azure PaaS endpoints when configured) over the same private circuit, without traversing the public internet. Requires a **Route Filter** — a separate resource that specifies which Microsoft service "communities" (BGP community values corresponding to Exchange Online, SharePoint Online, etc.) should actually be advertised down the circuit. An engineer can have Microsoft Peering showing fully `Provisioned`/`Enabled` with a live eBGP session, and still receive **zero routes**, because no Route Filter was ever attached — this is one of the most common "why doesn't Microsoft Peering work" tickets, and it's a configuration gap rather than a fault.

Historically a third peering type, **Azure Public Peering**, existed for reaching Azure PaaS public endpoints; it has been retired in favor of Microsoft Peering for new circuits — if encountered on a legacy circuit, treat it as deprecated and plan migration to Microsoft Peering rather than troubleshooting it as if it were current.

**eBGP as the routing protocol.** Both peering types use external BGP between the customer/provider edge router and Microsoft's edge (MSEE — Microsoft Enterprise Edge). Each peering has its own VLAN ID, a `/30` (or `/126` for IPv6) point-to-point addressing scheme for the primary and secondary redundant links, Azure-side and peer-side ASNs, and optionally MD5 authentication. **ExpressRoute always provisions two physical connections (primary and secondary) for redundancy** — this is built into the circuit model, not an optional add-on, and both should show `Established` in normal operation; a circuit running on only one of the two links is in a degraded, not fully redundant, state even if traffic is currently flowing.

**Prefix limits are a hard SKU-tier ceiling, not a soft warning.** `Sku.Tier` (Local, Standard, or Premium — distinct from `Sku.Family`, which is Metered vs. Unlimited and purely a billing/egress-charging distinction) sets a maximum number of prefixes the circuit will accept from the customer side. Advertising beyond that ceiling doesn't generate an alert by default — excess prefixes are simply not accepted, and routes to those destinations silently fail. Standard/Local tier historically caps around 4,000 prefixes; Premium raises this substantially (~10,000) and additionally unlocks cross-geopolitical-region connectivity (a Premium circuit can connect to VNets outside its own geopolitical region, which Standard cannot) and a higher VNet-link count per circuit. Always verify current published limits against Microsoft Learn at time of sizing, since these have been revised across the product's history.

**Global Reach — circuit-to-circuit, not circuit-to-VNet.** Global Reach links two ExpressRoute circuits (potentially belonging to different customers, different regions, or different providers) so their respective on-premises networks can exchange routes and traffic through Microsoft's backbone, entirely without traversing a VNet. This is the mechanism for "our two office sites, each on their own ExpressRoute circuit, need to reach each other" — without Global Reach, ExpressRoute only connects each on-prem site to Azure, not to each other. Establishing it requires generating an authorization on one circuit and redeeming it when creating the connection object on the second circuit — a two-step, two-directional-intent process that's easy to leave half-finished (authorization created, never redeemed).

**FastPath — bypassing the ExpressRoute Gateway for data-plane traffic.** By default, all traffic between on-premises and a VNet over ExpressRoute transits the ExpressRoute Gateway (a resource in the VNet/hub, analogous to a VPN Gateway). This gateway has a throughput ceiling determined by its SKU. FastPath, where the gateway SKU and circuit combination support it (UltraPerformance/ErGw3AZ and above, with ongoing feature-parity expansion for scenarios like VNet peering and Private Link — verify current support matrix before promising a specific scenario works), redirects the data plane to bypass the gateway entirely, sending traffic directly to the destination VM/NIC. The control plane (BGP route exchange) continues to transit the gateway regardless of FastPath status — only the data plane is bypassed. This distinction matters because "FastPath is on but routes still show learned via the gateway" is expected behavior, not a misconfiguration.

**Gateway SKU sizing is independent of circuit bandwidth.** A circuit provisioned at 1 Gbps, 10 Gbps, or higher says nothing about what the attached ExpressRoute Gateway can actually push — the gateway SKU (Standard, HighPerformance, UltraPerformance, or the availability-zone-aware ErGw1AZ/ErGw2AZ/ErGw3AZ family) has its own independent throughput ceiling. A circuit and gateway mismatch (large circuit, undersized gateway) is one of the most common "we're not getting the bandwidth we're paying for" tickets, and it produces no distinct error state anywhere — both resources report healthy.

</details>

---
## Dependency Stack

```
Layer 0 — Physical/Provider layer
    Connectivity provider cross-connect (or ExpressRoute Direct physical port pair)
    │  ← owned by the provider (or the customer, for Direct); Azure has no visibility below this

Layer 1 — Circuit (Microsoft resource)
    ExpressRoute Circuit — SKU (Family: Metered/Unlimited × Tier: Local/Standard/Premium)
    │  ← CircuitProvisioningState (Microsoft) + ServiceProviderProvisioningState (provider):
    │     TWO INDEPENDENT fields, both required

Layer 2 — Peerings (0, 1, or 2 configured independently per circuit)
    ├── Azure Private Peering  (→ VNets, via ExpressRoute Gateway)
    └── Microsoft Peering      (→ M365/public Azure PaaS, requires an attached Route Filter)
    │  ← each has its own ProvisioningState, State, VLAN, ASNs, redundant primary/secondary links

Layer 3 — eBGP sessions (primary + secondary per peering)
    │  ← Idle/Connect = not forming (VLAN/ASN/subnet/MD5 mismatch); Established = healthy
    │  ← Route Filter (Microsoft Peering only) gates WHICH routes are advertised even once Established

Layer 4 — Route exchange
    │  ← hard prefix ceiling by Sku.Tier — excess prefixes silently dropped, not alerted

Layer 5 — Circuit-to-VNet link
    ExpressRoute Gateway (SKU: Standard/HighPerformance/UltraPerformance/ErGw1-3AZ)
    │  ← independent throughput ceiling from the circuit's own provisioned bandwidth

Layer 6 — Optional data-plane/interconnect features
    ├── FastPath        (bypasses Gateway for data plane; control plane still transits Gateway)
    └── Global Reach     (circuit-to-circuit; authorization+redemption; bypasses VNets entirely)

Layer 7 — Traffic
    Data flows on-prem ↔ VNet (Private Peering) and/or on-prem ↔ M365/PaaS (Microsoft Peering)
    and/or on-prem ↔ on-prem via a second circuit (Global Reach)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Circuit shows healthy, but no VNet connectivity at all | Azure Private Peering never configured, or `ProvisioningState: NotProvisioned` | `(Get-AzExpressRouteCircuit ...).Peerings` filtered to `AzurePrivatePeering` |
| VNet connectivity fine, but no route to Exchange Online/SharePoint | Microsoft Peering has no Route Filter attached (peering itself can be fully healthy) | Peering's `RouteFilter` property — null means zero routes regardless of BGP state |
| eBGP peer stuck in `Idle` | VLAN ID, ASN, or `/30` subnet mismatch between customer/provider edge and Azure config | `Get-AzExpressRouteCircuitRouteTable` peer state; cross-check against provider-issued LOA/config sheet |
| On-prem routes present in BGP but destinations unreachable past a certain count | Prefix ceiling for the circuit's `Sku.Tier` exceeded — excess silently dropped | Count advertised prefixes vs. tier limit; `Sku.Tier` field |
| Two on-prem sites, each with their own circuit, can't reach each other via Azure | Global Reach not configured, or authorization created but never redeemed | `Get-AzExpressRouteCircuitConnectionConfig` on both circuits |
| Circuit and gateway both "healthy," throughput below expected | Gateway SKU under-provisioned for circuit bandwidth, and/or FastPath not enabled | Gateway SKU vs. published throughput table; `FastPathEnabled` on the connection |
| FastPath enabled, but a specific scenario (VNet peering transit, Private Link) still transits the gateway | FastPath's supported-scenario matrix hasn't caught up with the feature yet — verify current Microsoft support matrix, don't assume full bypass | Compare the specific traffic pattern against Microsoft's current FastPath scenario support table |
| Circuit provisioned via ExpressRoute Direct, MACsec expected but traffic unencrypted | MACsec is a separate, explicit configuration step on the ExpressRoute Direct port pair — not automatic just because Direct is in use | `Get-AzExpressRoutePort` MACsec configuration properties |
| One of the two redundant BGP sessions (primary/secondary) down, traffic still flows | Expected — the circuit is running in a degraded-redundancy state on the surviving link, not a full outage, but should be treated as a priority fix, not ignored because traffic is up | Check both `DevicePath Primary` and `DevicePath Secondary` route tables independently |
| Circuit migrated from Standard to Premium, but a Global Reach connection to a different-region circuit still fails | Global Reach region-pairing support and SKU requirements are independent of the general Premium upgrade taking effect elsewhere — re-verify Global Reach's own support matrix post-upgrade | `Get-AzExpressRouteCircuitConnectionConfig` post-upgrade; current Microsoft Global Reach region-availability doc |

---
## Validation Steps

1. **Circuit provisioning (both sides).**
   ```powershell
   Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName> |
       Select CircuitProvisioningState, ServiceProviderProvisioningState, Sku
   ```
   Good: both provisioned/enabled. Bad: either stuck → identify which party owns the fix before doing anything else.

2. **Peering-level state, both types if configured.**
   ```powershell
   (Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName>).Peerings |
       Select PeeringType, ProvisioningState, State, VlanId, AzureASN, PeerASN, RouteFilter
   ```
   Good: expected peering(s) `Provisioned`/`Enabled`; Microsoft Peering has a non-null `RouteFilter`. Bad: any mismatch from expected.

3. **eBGP session state on both redundant links.**
   ```powershell
   Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName <circuitName> -PeeringType AzurePrivatePeering -ResourceGroupName <rg>
   Get-AzExpressRouteCircuitRouteTable -DevicePath Secondary -ExpressRouteCircuitName <circuitName> -PeeringType AzurePrivatePeering -ResourceGroupName <rg>
   ```
   Good: both `Established`. Bad: either not established → full redundancy is not in place even if one link is up.

4. **Prefix count vs. tier ceiling.**
   ```powershell
   (Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName <circuitName> -PeeringType AzurePrivatePeering -ResourceGroupName <rg>).Count
   ```
   Compare against `Sku.Tier`'s published ceiling. Good: comfortably under. Bad: at or near the ceiling → summarization conversation needed before it becomes a routing failure.

5. **Gateway SKU vs. circuit bandwidth, and FastPath status.**
   ```powershell
   Get-AzExpressRouteGateway -ResourceGroupName <rg>
   Get-AzExpressRouteConnection -ResourceGroupName <rg> -ExpressRouteGatewayName <gatewayName> | Select FastPathEnabled
   ```
   Good: gateway SKU matches circuit tier's expected throughput; FastPath enabled where eligible. Bad: undersized gateway or FastPath eligible-but-off.

6. **Global Reach connection state, if in use.**
   ```powershell
   Get-AzExpressRouteCircuitConnectionConfig -ResourceGroupName <rg> -ExpressRouteCircuitName <circuitName>
   ```
   Good: `ConnectionState: Connected`. Bad: missing or `NotConnected` → authorization/redemption gap.

7. **Ongoing health visibility — Connection Monitor / Traffic Collector, if deployed.**
   Confirm whether Azure Network Watcher Connection Monitor tests are configured across the circuit for proactive latency/loss alerting, and whether ExpressRoute Traffic Collector is enabled for flow-level visibility — absence of either isn't a fault, but its absence should be flagged as a monitoring gap during any deep-dive engagement, since circuit-level provisioning states alone don't surface gradual latency/packet-loss degradation.

---
## Troubleshooting Steps (by phase)

### Phase 1: Circuit and provider provisioning
Confirm `CircuitProvisioningState` and `ServiceProviderProvisioningState` independently. A provider-side stall requires escalation to the connectivity provider with the circuit's service key — no Azure-side PowerShell action resolves it.

### Phase 2: Peering configuration
Identify which peering type(s) the ticket concerns. Confirm `ProvisioningState`/`State` for that specific peering — never assume Private Peering health implies anything about Microsoft Peering, or vice versa.

### Phase 3: eBGP session and route exchange
Check both redundant links' session state. Cross-reference VLAN/ASN/subnet/MD5 against the provider-issued configuration sheet or Letter of Authorization (LOA) rather than assuming Azure-side values are wrong first — most mismatches originate on the customer/provider edge device.

### Phase 4: Route Filter (Microsoft Peering only)
If Microsoft Peering, confirm a Route Filter is attached and includes the expected service communities. This step is frequently skipped because the peering's own provisioning state gives no indication a Route Filter is even required.

### Phase 5: Gateway and data-plane features
Confirm gateway SKU against circuit bandwidth expectations. Check FastPath eligibility and status for throughput complaints. Check Global Reach connection state for cross-site-via-Azure complaints.

### Phase 6: Ongoing visibility
Confirm whether Connection Monitor and/or Traffic Collector are deployed for the circuit. Recommend enabling both as part of remediation if the incident stemmed from a gradual degradation that provisioning-state checks alone wouldn't have caught early.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield ExpressRoute circuit setup (provider-based)</summary>

1. Create the circuit with the correct SKU (Family + Tier) sized for current and near-term prefix/bandwidth needs — remember Tier is not easily downgraded later without more restriction than the upgrade path.
2. Provide the Service Key to the connectivity provider; provider completes their side of the cross-connect.
3. Once `ServiceProviderProvisioningState` shows provisioned, configure Azure Private Peering (VLAN, ASNs, `/30` subnets) matching the provider-issued LOA.
4. Deploy an ExpressRoute Gateway (SKU sized to bandwidth needs) in the target VNet/hub and link it to the circuit.
5. If Microsoft Peering is also required, configure it separately and create/attach a Route Filter with the needed service communities — do not assume Private Peering setup covers this.
6. Validate eBGP `Established` on both primary and secondary links before declaring the circuit live.
7. Enable Connection Monitor for ongoing latency/loss visibility as a standard part of go-live, not an afterthought.

**Rollback:** Circuit deletion is available at any stage before go-live; once traffic is live, treat any peering/gateway change as a planned maintenance window, not an ad hoc edit.

</details>

<details><summary>Playbook 2 — Migrate Standard to Premium tier</summary>

1. Confirm the business driver — prefix ceiling being hit, or cross-geopolitical-region VNet connectivity needed, or a higher VNet-link count required.
2. Execute the tier upgrade (supported in-place for the circuit; billing changes take effect immediately) during a change window, even though the upgrade itself is non-disruptive to existing connectivity in the documented case — verify current Microsoft guidance for any exceptions before the specific engagement.
3. Post-upgrade, re-verify prefix counts are now comfortably under the new ceiling, and re-verify Global Reach connections (if any) still show `Connected` — region-pairing support for Global Reach has its own independent matrix that a Premium upgrade doesn't automatically re-validate.
4. Document the one-way nature of this change (downgrade back to Standard has materially more restrictions — verify current terms) in the client's change record.

**Rollback:** Premium→Standard downgrade should be treated as its own separately-scoped change, not an assumed reversible step — verify current support and restrictions before committing to this being available.

</details>

<details><summary>Playbook 3 — Enable FastPath</summary>

1. Confirm gateway SKU is UltraPerformance/ErGw3AZ or newer, and confirm the specific traffic scenario (VM-to-on-prem, VNet-peered VM, Private Link) is on the currently supported FastPath scenario list — this list has expanded over time and should be re-checked against current Microsoft documentation rather than assumed from memory.
2. Enable FastPath on the ExpressRoute connection object (not the circuit or the gateway directly):
   ```powershell
   Set-AzExpressRouteConnection -InputObject $conn -ExpressRouteGatewayName <gatewayName> -ResourceGroupName <rg> -FastPathEnabled $true
   ```
3. Validate with a throughput test from an actual on-prem-connected client to a VM behind the gateway, comparing before/after.
4. Document that control-plane BGP routes continue transiting the gateway regardless — this is expected and shouldn't be reported as "FastPath partially not working."

**Rollback:** `-FastPathEnabled $false` reverts cleanly; useful if FastPath's gateway bypass conflicts with an NVA the client expected inline in the data path.

</details>

<details><summary>Playbook 4 — Fleet-wide ExpressRoute health audit across multiple clients</summary>

1. Run `Scripts/Get-ExpressRouteCircuitAudit.ps1` across all in-scope subscriptions to surface: circuits with only one of two redundant BGP links established, Microsoft Peering configured without a Route Filter, prefix counts approaching tier ceilings, Global Reach connections in a `NotConnected` state, and gateway SKU/circuit bandwidth mismatches.
2. Triage output by client-impact severity: a single-link degraded-redundancy circuit carrying production traffic outranks a Route-Filter gap on a rarely-used Microsoft Peering.
3. For each finding, confirm root cause against this file's Symptom → Cause Map before opening remediation tickets — several of these symptoms look identical from the audit script's output alone (e.g., "no Microsoft Peering routes" could be a missing Route Filter or a genuinely unconfigured peering).

**Rollback:** N/A — read-only audit.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS Collects ExpressRoute circuit, peering, BGP, and gateway evidence for escalation.
#>
param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$CircuitName
)

$circuit = Get-AzExpressRouteCircuit -ResourceGroupName $ResourceGroupName -Name $CircuitName
$evidence = [ordered]@{
    Circuit          = $circuit | Select-Object Name, CircuitProvisioningState, ServiceProviderProvisioningState, Sku, ServiceProviderNotes
    Peerings         = $circuit.Peerings | Select-Object PeeringType, ProvisioningState, State, VlanId, AzureASN, PeerASN, RouteFilter
    PrimaryRoutes    = try { Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName $CircuitName -PeeringType AzurePrivatePeering -ResourceGroupName $ResourceGroupName } catch { "Unavailable: $_" }
    SecondaryRoutes  = try { Get-AzExpressRouteCircuitRouteTable -DevicePath Secondary -ExpressRouteCircuitName $CircuitName -PeeringType AzurePrivatePeering -ResourceGroupName $ResourceGroupName } catch { "Unavailable: $_" }
    GlobalReach      = try { Get-AzExpressRouteCircuitConnectionConfig -ResourceGroupName $ResourceGroupName -ExpressRouteCircuitName $CircuitName } catch { "None configured" }
    CollectedAt      = Get-Date -Format "u"
}
$evidence | ConvertTo-Json -Depth 6 | Out-File ".\ExpressRoute-Evidence-$CircuitName-$(Get-Date -Format yyyyMMdd-HHmm).json"
Write-Host "Evidence pack written." -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Circuit provisioning states | `Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <c> \| Select CircuitProvisioningState, ServiceProviderProvisioningState` |
| Peering config, both types | `(Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <c>).Peerings` |
| eBGP route table (primary) | `Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName <c> -PeeringType AzurePrivatePeering -ResourceGroupName <rg>` |
| eBGP route table (secondary) | `Get-AzExpressRouteCircuitRouteTable -DevicePath Secondary -ExpressRouteCircuitName <c> -PeeringType AzurePrivatePeering -ResourceGroupName <rg>` |
| Route Filter for Microsoft Peering | `Get-AzRouteFilter -ResourceGroupName <rg> -Name <filterName>` |
| Global Reach connection state | `Get-AzExpressRouteCircuitConnectionConfig -ResourceGroupName <rg> -ExpressRouteCircuitName <c>` |
| Create Global Reach authorization | `New-AzExpressRouteCircuitAuthorization -ResourceGroupName <rg> -CircuitName <c> -Name <authName>` |
| ExpressRoute Gateway inventory | `Get-AzExpressRouteGateway -ResourceGroupName <rg>` |
| Connection object + FastPath status | `Get-AzExpressRouteConnection -ResourceGroupName <rg> -ExpressRouteGatewayName <gw>` |
| Enable FastPath | `Set-AzExpressRouteConnection -InputObject $conn -ExpressRouteGatewayName <gw> -ResourceGroupName <rg> -FastPathEnabled $true` |
| ExpressRoute Direct ports (if applicable) | `Get-AzExpressRoutePort -ResourceGroupName <rg> -Name <portName>` |
| Circuit SKU / tier check | `(Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <c>).Sku` |
| Circuit authorizations (VNet-link, not Global Reach) | `Get-AzExpressRouteCircuitAuthorization -ResourceGroupName <rg> -CircuitName <c>` |
| List all circuits in a subscription | `Get-AzExpressRouteCircuit \| Select Name, ResourceGroupName, CircuitProvisioningState` |

---
## 🎓 Learning Pointers

- **The three-party (customer/provider/Microsoft) provisioning model is what makes `CircuitProvisioningState` and `ServiceProviderProvisioningState` genuinely independent** — this is architecturally different from almost every other Azure resource, where a single provisioning state is authoritative. Treat a stuck provider-side state as an external escalation, not an Azure misconfiguration to keep digging into. See [ExpressRoute circuits and routing domains](https://learn.microsoft.com/en-us/azure/expressroute/expressroute-circuit-peerings).

- **Microsoft Peering without a Route Filter is a fully healthy peering that delivers zero routes.** This is the single most-missed step in Microsoft Peering setup — the peering's own health signals give no hint that a Route Filter is even required. See [Configure a Route Filter](https://learn.microsoft.com/en-us/azure/expressroute/how-to-routefilter-powershell).

- **Every circuit provisions two physical/logical redundant links (primary and secondary) by design.** A circuit running healthy traffic on only one of the two is in a real degraded-redundancy state that won't surface as a fault anywhere except by explicitly checking both `DevicePath` values — worth building into any routine circuit health check, not just incident response. See [ExpressRoute circuit provisioning](https://learn.microsoft.com/en-us/azure/expressroute/expressroute-workflows).

- **`Sku.Tier` (Local/Standard/Premium), not `Sku.Family` (Metered/Unlimited), governs the prefix ceiling and cross-geopolitical-region reach.** These two SKU dimensions are billing vs. capability respectively, and conflating them during capacity planning is a repeat mistake worth explicitly correcting when reviewing a client's circuit sizing. See [ExpressRoute FAQ — SKU comparison](https://learn.microsoft.com/en-us/azure/expressroute/expressroute-faqs).

- **Global Reach and Virtual WAN's own hub routing are not the same thing, and don't substitute for each other.** Global Reach connects two ExpressRoute circuits directly; a Virtual WAN hub with two circuits connected still routes site-to-site traffic through the hub's own routing/Routing-Intent model (see `VirtualWAN-A.md`), not via a separate Global Reach connection between the circuits themselves. Don't assume a client using Virtual WAN needs Global Reach configured on top — it's typically redundant in that topology.

- **FastPath bypasses the data plane only — the control plane (BGP) always transits the ExpressRoute Gateway regardless of FastPath status.** Reporting "routes still show learned via the Gateway even with FastPath on" as a bug wastes troubleshooting time on expected behavior; confirm actual data-plane throughput/latency rather than BGP route-learned-via output when validating FastPath. See [ExpressRoute FastPath overview](https://learn.microsoft.com/en-us/azure/expressroute/about-fastpath).
