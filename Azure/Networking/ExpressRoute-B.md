# Azure ExpressRoute — Hotfix Runbook (Mode B: Ops)
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

This file covers **ExpressRoute-specific** failure modes that go beyond the shared circuit/BGP-provisioning checks already in `HybridConnectivity-B.md` Triage: peering-type-specific breakage (Private vs. Microsoft peering), Global Reach cross-connections, FastPath eligibility/config drift, gateway SKU vs. circuit bandwidth mismatches, and authorization/cross-tenant redemption issues. If the circuit itself shows `Not Provisioned` on either side, start in `HybridConnectivity-B.md` first — that's the correct triage entry point for basic circuit/provider provisioning.

```powershell
# 0. Circuit + both provisioning states — confirm circuit is actually live before anything peering-specific
Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName> |
    Select-Object Name, CircuitProvisioningState, ServiceProviderProvisioningState, Sku, ServiceProviderNotes

# 1. Peering-level state — Private and Microsoft peering are independently provisioned and independently fail
(Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName>).Peerings |
    Select-Object PeeringType, ProvisioningState, State, AzureASN, PeerASN, RouteFilter

# 2. eBGP session state per peering — the authoritative "is this actually up" check
Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName <circuitName> `
    -PeeringType AzurePrivatePeering -ResourceGroupName <rg>

# 3. Global Reach connections (circuit-to-circuit, not circuit-to-VNet)
Get-AzExpressRouteCircuitConnectionConfig -ResourceGroupName <rg> -ExpressRouteCircuitName <circuitName>

# 4. FastPath status on the connection (VNet-side object, not the circuit)
Get-AzExpressRouteConnection -ResourceGroupName <rg> -ExpressRouteGatewayName <gatewayName> |
    Select-Object Name, ExpressRouteCircuitPeering, EnableInternetSecurity, RoutingWeight, FastPathEnabled

# 5. ExpressRoute Gateway SKU vs. circuit bandwidth — the most common "it's slow" root cause
Get-AzExpressRouteGateway -ResourceGroupName <rg> | Select-Object Name, VirtualHub, ExpressRouteConnections
```

| Command result | Interpretation | Do this |
|---|---|---|
| Circuit `CircuitProvisioningState: Enabled`, but a specific peering shows `ProvisioningState: NotProvisioned` | That peering was never configured on the Microsoft side — usually a config that was requested but never completed | Fix 1 |
| Peering `ProvisioningState: Provisioned`, `State: Disabled` | Peering exists and is configured correctly but has been administratively disabled | Fix 2 |
| Route table shows peer in `Idle` instead of `Established` | eBGP session isn't forming — VLAN/ASN/subnet/MD5 mismatch against the customer/provider edge router | Fix 3 |
| Private peering `Established` but Microsoft peering `Idle`/missing | The two peerings are fully independent — Private peering health tells you nothing about Microsoft peering | Fix 3, scoped to Microsoft peering specifically |
| Global Reach connection config shows `ConnectionState: NotConnected` | Authorization not redeemed, or the two circuits are in a currently-unsupported region pairing | Fix 4 |
| Users on one on-prem site can't reach resources reachable from a different on-prem site, both connected via ExpressRoute | Missing or broken Global Reach connection between the two circuits (ExpressRoute connects on-prem↔Azure, not on-prem↔on-prem, without it) | Fix 4 |
| `FastPathEnabled: False` and client reports high latency / lower-than-expected throughput to VM NICs | FastPath not enabled, or the gateway/circuit combination doesn't support it (UltraPerformance/ErGw3AZ + specific circuit SKUs only) | Fix 5 |
| Circuit SKU is `Premium` but Route Filter / route count looks capped at ~4,000 prefixes | Actually on `Standard` behavior — check the SKU tier, not just SKU family; Premium raises the prefix ceiling and adds cross-geopolitical connectivity | Fix 6 |
| Circuit `ServiceProviderProvisioningState: NotProvisioned` for more than a few hours after provider confirmed completion | Provisioning acknowledgment mismatch between provider and Microsoft — hand off to circuit provider, not an Azure-side fix | Escalate to Circuit Provider |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
ExpressRoute Circuit (SKU: Local/Standard/Premium × Tier: Metered/Unlimited)
    │  ← CircuitProvisioningState (Microsoft side) + ServiceProviderProvisioningState (provider side)
    │     are TWO INDEPENDENT signals — both must show provisioned/enabled
    ▼
Peerings (configured independently per type — a circuit can have one, the other, or both)
    ├── Azure Private Peering   → reaches VNets (via circuit link / ExpressRoute Gateway)
    └── Microsoft Peering       → reaches Microsoft 365 / public Azure PaaS endpoints over the private circuit
    │  ← each peering has its own ProvisioningState, State (Enabled/Disabled), VLAN ID, and ASNs
    ▼
eBGP session per peering (VLAN, Azure ASN, Peer ASN, /30 or /126 subnet, optional MD5)
    │  ← Established required before any route is usable; Idle = session hasn't formed
    ▼
Route exchange
    │  ← Standard/Local SKU: ~4,000 prefix ceiling on-prem→Azure; Premium: ~10,000
    │  ← Route Filter object required on Microsoft Peering to select which MS 365 services
    │     Azure receives — an empty/missing Route Filter is why "Microsoft Peering is up but
    │     I don't see Exchange Online routes" is common, not a bug
    ▼
Circuit-to-VNet link (ExpressRoute Gateway of type ExpressRoute in the target VNet/hub)
    │  ← Gateway SKU (Standard/HighPerformance/UltraPerformance/ErGw1-3AZ) caps throughput
    │     independent of what the circuit itself is provisioned for — a mismatch here silently
    │     throttles traffic without any error state anywhere
    ▼
FastPath (OPTIONAL, connection-level toggle — bypasses the ExpressRoute Gateway for data path)
    │  ← requires UltraPerformance/ErGw3AZ gateway SKU (or newer) + compatible circuit; without
    │     it ALL data plane traffic transits the gateway, which is a throughput ceiling on its own
    ▼
Global Reach (OPTIONAL, circuit-to-circuit authorization+connection — NOT circuit-to-VNet)
    │  ← connects two ExpressRoute circuits so their respective on-prem sites can reach each
    │     other THROUGH Azure's backbone, without traffic ever entering a VNet
    ▼
Traffic flows
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the circuit itself is provisioned on both sides before touching peerings.**
   ```powershell
   Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName> |
       Select CircuitProvisioningState, ServiceProviderProvisioningState
   ```
   - Good: both `Enabled`/`Provisioned`.
   - Bad: `ServiceProviderProvisioningState: NotProvisioned` → this is the circuit provider's action item, not Azure's. Escalate directly rather than chasing peering config.

2. **Check each peering type independently — they do not share health.**
   ```powershell
   (Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName>).Peerings |
       Select PeeringType, ProvisioningState, State, VlanId, PeerASN
   ```
   - Good: the peering(s) actually in use show `ProvisioningState: Provisioned`, `State: Enabled`.
   - Bad: a peering shows `NotProvisioned` when the client believes it's configured → that peering was requested but the config was never completed on the Microsoft side. Go to Fix 1.

3. **Check the eBGP session state for the peering that's failing.**
   ```powershell
   Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName <circuitName> `
       -PeeringType AzurePrivatePeering -ResourceGroupName <rg>
   ```
   - Good: peer state `Established`.
   - Bad: `Idle` or `Connect` → VLAN/ASN/subnet/MD5 mismatch on the customer or provider edge device. Go to Fix 3.

4. **If Microsoft Peering is in play, confirm a Route Filter is attached.**
   ```powershell
   (Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName>).Peerings |
       Where PeeringType -eq "MicrosoftPeering" | Select RouteFilter
   ```
   - Good: a Route Filter resource ID is present, with the expected M365 service community values (e.g., Exchange Online, SharePoint Online) selected.
   - Bad: `RouteFilter: null` → Microsoft Peering can be `Provisioned`/`Enabled` and still deliver zero routes because nothing was told which service families to advertise. This is a configuration gap, not a fault.

5. **If this is a Global Reach ticket ("on-prem site A can't reach on-prem site B via Azure"), check the connection object, not either circuit's own health.**
   ```powershell
   Get-AzExpressRouteCircuitConnectionConfig -ResourceGroupName <rg> -ExpressRouteCircuitName <circuitName>
   ```
   - Good: `ConnectionState: Connected`.
   - Bad: `NotConnected` or the object doesn't exist → Fix 4. Confirm both circuits are Premium SKU (or same-country Standard, where supported) before assuming a config error — some SKU/region combinations are not supported for Global Reach at all.

6. **If this is a throughput/latency complaint with all provisioning states healthy, check gateway SKU and FastPath.**
   ```powershell
   Get-AzExpressRouteGateway -ResourceGroupName <rg> | Select Name, VirtualHub
   Get-AzExpressRouteConnection -ResourceGroupName <rg> -ExpressRouteGatewayName <gatewayName> |
       Select FastPathEnabled, RoutingWeight
   ```
   - Good: gateway SKU matches expected throughput tier, and FastPath is enabled if eligible.
   - Bad: gateway SKU under-provisioned for circuit bandwidth, or FastPath eligible but off → Fix 5.

---
## Common Fix Paths

<details><summary>Fix 1 — A peering shows NotProvisioned when it should be configured</summary>

**When to use:** Circuit itself is `Enabled`/`Provisioned`, but a specific peering (Private or Microsoft) shows `ProvisioningState: NotProvisioned`.

```powershell
# Re-check exact current peering config before changing anything
Get-AzExpressRouteCircuitPeeringConfig -ResourceGroupName <rg> -ExpressRouteCircuitName <circuitName> -Name AzurePrivatePeering

# Add/repair Azure Private Peering (values must match what the provider/customer edge expects)
Add-AzExpressRouteCircuitPeeringConfig -Name AzurePrivatePeering -ExpressRouteCircuit $circuit `
    -PeeringType AzurePrivatePeering -PeerASN <peerAsn> -PrimaryPeerAddressPrefix <primary/30> `
    -SecondaryPeerAddressPrefix <secondary/30> -VlanId <vlanId>
Set-AzExpressRouteCircuit -ExpressRouteCircuit $circuit
```

1. Confirm the VLAN ID, primary/secondary `/30` (or `/126` for IPv6) subnets, and peer ASN against what the circuit provider issued — a transposed VLAN or subnet is the single most common cause of a peering that "should be configured" but shows `NotProvisioned`.
2. For Microsoft Peering specifically, a Route Filter must also be attached (see Diagnosis step 4) — the peering itself provisioning correctly does not mean routes will flow.
3. Changes typically apply within a few minutes; re-check `ProvisioningState` before assuming failure.

**Rollback:** `Remove-AzExpressRouteCircuitPeeringConfig -Name AzurePrivatePeering -ExpressRouteCircuit $circuit` followed by `Set-AzExpressRouteCircuit` removes the peering config cleanly if the wrong values were applied.

</details>

<details><summary>Fix 2 — Peering is Provisioned but administratively Disabled</summary>

**When to use:** `ProvisioningState: Provisioned`, `State: Disabled` on the affected peering.

```powershell
$circuit = Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName>
($circuit.Peerings | Where PeeringType -eq "AzurePrivatePeering").State = "Enabled"
Set-AzExpressRouteCircuit -ExpressRouteCircuit $circuit
```

1. Confirm with the client this wasn't disabled deliberately (e.g., during a migration cutover) before re-enabling.
2. Re-check eBGP session state a few minutes after enabling — the session should move from `Idle` to `Established` on its own once the peering is `Enabled`.

**Rollback:** Set `State` back to `Disabled` and re-run `Set-AzExpressRouteCircuit`.

</details>

<details><summary>Fix 3 — eBGP session stuck in Idle/Connect (VLAN, ASN, subnet, or MD5 mismatch)</summary>

**When to use:** Peering shows `Provisioned`/`Enabled`, but the route table peer state never reaches `Established`.

1. Confirm the VLAN ID configured on the customer/provider edge device matches exactly what's on the Azure-side peering config — a VLAN mismatch prevents the underlying Layer 2 handoff, and the BGP session never even attempts to form.
2. Confirm ASNs on both sides — Azure's side is whatever was configured in `PeerASN`/`AzureASN`; a swapped or incorrect ASN on the customer edge is a common copy-paste error during initial setup.
3. Confirm the `/30` (or `/126`) peering subnet addresses are configured identically (mirrored) on both ends — Azure uses `.1` or `.2` per the standard convention documented at circuit creation time.
4. If MD5 authentication is configured, confirm the shared secret matches exactly on both sides — a mismatched or since-rotated secret silently prevents the session without a distinct Azure-side error.
5. Check with the provider/customer edge team whether Layer 2 (VLAN/dot1q tagging) is actually up before assuming this is purely a BGP config issue — Azure's route table view only shows what's arriving at the Microsoft edge (MSEE); it can't see if the customer's own router never sent anything.

**Rollback:** N/A — diagnostic correction, not a destructive action. Reverting any parameter change uses the same `Add-AzExpressRouteCircuitPeeringConfig`/`Set-AzExpressRouteCircuit` pattern as Fix 1.

</details>

<details><summary>Fix 4 — Global Reach connection missing or NotConnected</summary>

**When to use:** Two ExpressRoute circuits exist for the same client (e.g., two different sites/regions), each independently healthy to Azure, but the client reports the two on-prem sites can't reach each other through Azure.

```powershell
# Authorization must be created on circuit A, then redeemed when creating the connection FROM circuit B
$auth = New-AzExpressRouteCircuitAuthorization -ResourceGroupName <rgA> -CircuitName <circuitA> -Name GlobalReachAuth
Set-AzExpressRouteCircuit -ExpressRouteCircuit $circuitA

# Create the connection from the second circuit, redeeming circuit A's authorization
Add-AzExpressRouteCircuitConnectionConfig -ExpressRouteCircuit $circuitB -Name "GlobalReachConnection" `
    -PeerExpressRouteCircuitPeering $circuitA.Peerings[0].Id -AddressPrefix <169.254.x.x/29> `
    -AuthorizationKey $auth.AuthorizationKey
Set-AzExpressRouteCircuit -ExpressRouteCircuit $circuitB
```

1. Confirm both circuits are on a SKU/region combination that supports Global Reach — historically Premium SKU was required for cross-region Global Reach; same-country connections on Standard have broader support, but this varies by region and should be verified against current Microsoft documentation before promising a client it will work.
2. The `AddressPrefix` for the connection is a small (`/29`) address block used purely for the Global Reach link itself — it must not overlap with any other address space in use.
3. Both circuits must have Azure Private Peering configured and `Provisioned` before Global Reach can be added — it rides on top of Private Peering, the same way BGP rides on top of an IPsec tunnel for VPN Gateway.
4. Global Reach connects circuit-to-circuit, never on-prem-to-on-prem directly and never through a VNet — if the client's mental model is "route through our hub VNet," correct that expectation; VNets are not in this data path at all.

**Rollback:** `Remove-AzExpressRouteCircuitConnectionConfig -ExpressRouteCircuit $circuitB -Name "GlobalReachConnection"` followed by `Set-AzExpressRouteCircuit -ExpressRouteCircuit $circuitB` removes the connection; the authorization on circuit A can be separately removed with `Remove-AzExpressRouteCircuitAuthorization` if no longer needed.

</details>

<details><summary>Fix 5 — Throughput/latency below expectation (gateway SKU or FastPath)</summary>

**When to use:** All provisioning/BGP states are healthy, but the client reports lower throughput or higher latency than the circuit's provisioned bandwidth would suggest.

1. Confirm the ExpressRoute Gateway SKU actually supports the circuit's bandwidth — a `Standard` gateway SKU caps well below what a 10 Gbps circuit can deliver; the circuit being fully healthy doesn't mean the gateway isn't the bottleneck. Compare current SKU against Microsoft's published gateway SKU throughput table before promising a fix.
2. Check FastPath eligibility and status:
   ```powershell
   Get-AzExpressRouteConnection -ResourceGroupName <rg> -ExpressRouteGatewayName <gatewayName> |
       Select FastPathEnabled
   ```
   FastPath requires an UltraPerformance or ErGw3AZ (or newer) gateway SKU, and bypasses the gateway for the data plane — without it, every packet transits the gateway even if the gateway SKU itself is adequately sized.
3. If FastPath is eligible but disabled:
   ```powershell
   $conn = Get-AzExpressRouteConnection -ResourceGroupName <rg> -ExpressRouteGatewayName <gatewayName> -Name <connectionName>
   $conn.EnableInternetSecurity = $conn.EnableInternetSecurity  # no-op placeholder, see below
   Set-AzExpressRouteConnection -InputObject $conn -ExpressRouteGatewayName <gatewayName> -ResourceGroupName <rg> -FastPathEnabled $true
   ```
4. If the gateway SKU itself is undersized, a gateway SKU upgrade (not a resize-in-place for older SKUs — check current Microsoft guidance on which SKU transitions are in-place vs. requiring a new gateway) is the real fix — set expectations that this may involve a brief connectivity interruption during the resize/replace window.

**Rollback:** `Set-AzExpressRouteConnection ... -FastPathEnabled $false` reverts FastPath if it introduces unexpected behavior (e.g., bypassing an NVA the client expected in the data path via the gateway).

</details>

<details><summary>Fix 6 — Prefix limit / SKU tier confusion (Standard vs. Premium)</summary>

**When to use:** Client reports missing on-prem routes in Azure, and the on-premises router is confirmed to be advertising more prefixes than the circuit is currently accepting.

1. Confirm the circuit's SKU family and tier together — `Sku.Family` (MeteredData/UnlimitedData) is billing-only and irrelevant to prefix limits; `Sku.Tier` (Local/Standard/Premium) is what determines the prefix ceiling (Local/Standard: ~4,000 prefixes; Premium: ~10,000 — verify current published limits, as these have changed over the product's history).
   ```powershell
   (Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName>).Sku
   ```
2. If the on-prem router is advertising more prefixes than the tier supports, excess prefixes are dropped silently — there is no distinct Azure-side error for this. Have the on-prem network team summarize routes more aggressively, or upgrade the circuit to Premium if summarization isn't feasible.
3. A Standard→Premium upgrade is supported without recreating the circuit, but is a **billing-affecting, one-way** change per Microsoft's current terms at time of upgrade — confirm with the client before executing, ideally during a change window rather than mid-incident.

**Rollback:** Premium→Standard downgrade support and process should be verified against current Microsoft documentation before promising it — historically this has had more restrictions than the upgrade path.

</details>

---
## Escalation Evidence

```
=== ExpressRoute Escalation ===
Ticket #:
Client / Tenant:
Circuit name / RG:                        SKU (Family/Tier):
CircuitProvisioningState:                 ServiceProviderProvisioningState:
Affected peering type:                    [ ] Private  [ ] Microsoft
Peering ProvisioningState:                Peering State (Enabled/Disabled):
eBGP peer state observed:                 VLAN ID:
Route Filter attached (Microsoft Peering only, Y/N):
Global Reach involved (Y/N):              ConnectionState (if Y):
ExpressRoute Gateway SKU:                 FastPath enabled:
Circuit provider / circuit ID:
When did it last work:
What changed (client-reported):
Provider-side ticket # (if applicable):
Impact (users/services affected):
Escalation target:                        [ ] Microsoft Support   [ ] Internal L3   [ ] Circuit Provider
```

---
## 🎓 Learning Pointers

- **Azure Private Peering and Microsoft Peering are fully independent** — provisioning, health, and BGP state for one tells you nothing about the other. A circuit can have flawless Private Peering (VNet connectivity) and completely absent Microsoft Peering (no route to Exchange Online/SharePoint over the circuit) at the same time. Always specify which peering is affected before troubleshooting. See [ExpressRoute circuits and routing domains](https://learn.microsoft.com/en-us/azure/expressroute/expressroute-circuit-peerings).

- **Microsoft Peering requires a Route Filter to deliver any routes at all** — the peering itself showing `Provisioned`/`Enabled` is necessary but not sufficient. Without a Route Filter selecting specific M365 service communities, zero routes are advertised to the customer edge even though the peering "looks" healthy. See [Route Filters for Microsoft Peering](https://learn.microsoft.com/en-us/azure/expressroute/how-to-routefilter-powershell).

- **Global Reach connects circuits to each other, not on-prem sites directly and not through a VNet.** It requires an authorization generated on one circuit and redeemed on the other — a common failure is generating the authorization but never redeeming it, which leaves the connection permanently absent with no error surfaced to either party until someone checks. See [ExpressRoute Global Reach](https://learn.microsoft.com/en-us/azure/expressroute/expressroute-global-reach).

- **FastPath and gateway SKU are two separate throughput levers.** An undersized gateway SKU throttles traffic even with a large circuit; FastPath (where eligible) bypasses the gateway for data-plane traffic but doesn't fix an undersized gateway for the control-plane/non-FastPath-eligible flows. Both need checking on any throughput complaint. See [ExpressRoute FastPath](https://learn.microsoft.com/en-us/azure/expressroute/about-fastpath).

- **Circuit `Sku.Tier` (Local/Standard/Premium), not `Sku.Family`, governs the prefix ceiling.** Engineers checking only the family (Metered/Unlimited, a billing distinction) can miss that a circuit is capped at the Standard tier's lower prefix limit while troubleshooting "missing on-prem routes." See [ExpressRoute circuits and routing domains — SKU comparison](https://learn.microsoft.com/en-us/azure/expressroute/expressroute-faqs).

- **`CircuitProvisioningState` and `ServiceProviderProvisioningState` are two independently-owned signals**, same pattern as the hub `ProvisioningState`/`RoutingState` split covered in `VirtualWAN-B.md` — a stuck `ServiceProviderProvisioningState` is the circuit provider's action item and no Azure-side PowerShell command will resolve it; escalate to the provider directly rather than repeatedly re-checking from the Azure side.
