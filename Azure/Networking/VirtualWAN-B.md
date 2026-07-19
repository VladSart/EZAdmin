# Azure Virtual WAN (Hub Routing, Routing Intent, Secured Hub) — Hotfix Runbook (Mode B: Ops)
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

Virtual WAN wraps VPN Gateway, ExpressRoute Gateway, and Azure Firewall inside a Microsoft-managed **virtual hub** with its own BGP router. Before touching any of those individually, confirm the hub/SKU/routing-intent layer first — most "my VPN/ExpressRoute is broken" tickets on a vWAN hub are actually a hub-router or routing-intent problem wearing a familiar disguise.

```powershell
# 0. Hub + SKU + provisioning state — always first
Get-AzVirtualHub -ResourceGroupName <rg> -Name <hubName> |
    Select-Object Name, ProvisioningState, RoutingState, VirtualRouterAsn, Sku

# 1. Virtual WAN type (Basic vs Standard) — determines what the hub is even allowed to run
Get-AzVirtualWan -ResourceGroupName <rg> -Name <vwanName> | Select-Object Name, VirtualWANType

# 2. Routing Intent — is traffic actually supposed to go through a firewall/NVA?
Get-AzRoutingIntent -ResourceGroupName <rg> -ParentResourceId (Get-AzVirtualHub -ResourceGroupName <rg> -Name <hubName>).Id

# 3. Hub VNet connection health (per spoke)
Get-AzVirtualHubVnetConnection -ResourceGroupName <rg> -ParentResourceName <hubName> |
    Select-Object Name, ConnectionStatus, EnableInternetSecurity

# 4. Gateways actually present in the hub (VPN / ExpressRoute / User VPN)
Get-AzVpnGateway -ResourceGroupName <rg> | Where-Object VirtualHub.Id -like "*$hubName*"
Get-AzExpressRouteGateway -ResourceGroupName <rg>
```

| Command result | Interpretation | Do this |
|---|---|---|
| `ProvisioningState: Succeeded`, `RoutingState: Failed` | Hub resource is fine; the internal router is stuck | Fix 1 (Router Reset) |
| `ProvisioningState: Failed` on the hub itself | Deeper hub-level failure — router reset won't touch this | Fix 2 (Hub Reset) |
| `VirtualWANType: Basic` and the client is asking for ExpressRoute, P2S, Firewall, or Routing Intent | Unsupported combination — Basic only supports site-to-site VPN | Fix 3 (Basic→Standard upgrade — one-way, plan before executing) |
| Routing Intent exists but a spoke's traffic still bypasses the firewall | Spoke's connection isn't associated to the route table Routing Intent manages, or was added after Routing Intent silently took over the Default route table | Fix 4 |
| `ConnectionStatus: Connected` on the VNet connection but traffic still fails | Fault has left this topic — hand off to NSG on the spoke subnet, or `HybridConnectivity-B.md` if the far end is on-prem | Fix 5 |
| ExpressRoute Gateway and VPN Gateway both present in the same hub, one gateway's on-prem routes aren't reaching the other | Both gateway types share the **same fixed ASN 65515** inside a vWAN hub — a documented conflict source | Fix 6 |
| Static route on a hub route table appears to have vanished after enabling Routing Intent | Expected — enabling Routing Intent hands the Default route table's management to Routing Intent and can overwrite prior associations | Fix 4, and re-document any static routes before re-enabling |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Virtual WAN resource (Basic or Standard — a hard capability ceiling, not a pricing tier only)
    │  ← Basic: site-to-site VPN ONLY. No ExpressRoute, no P2S, no Firewall/NVA, no Routing Intent.
    │  ← Standard: VPN + ExpressRoute + P2S (User VPN) + Firewall/NVA + Routing Intent + full-mesh transit
    ▼
Virtual Hub (regional deployment; its own BGP router, ASN fixed at 65515)
    │  ← ProvisioningState (hub resource) and RoutingState (internal router) are TWO INDEPENDENT
    │     health signals — a hub can be Succeeded while its router is Failed, and vice versa
    ▼
Gateways deployed IN the hub (0 or more of each, Standard only for ER/P2S)
    ├── Site-to-site VPN gateway  (scale units, 500 Mbps/unit, 20 Gbps aggregate max)
    ├── ExpressRoute gateway     (20 Gbps aggregate max, up to 8 circuit connections/hub)
    ├── User VPN (P2S) gateway   (up to 200 Gbps aggregate, 100,000 users/hub)
    └── Azure Firewall / supported NVA (Standard only — required for Routing Intent's Next Hop)
    │
    ▼
Connections (VPN / ExpressRoute / P2S config / Hub VNet connection)
    │  ← each connection ASSOCIATES to exactly one route table
    │  ← each connection PROPAGATES its routes to one or more route tables (via Labels)
    │  ← all branch connections (S2S/P2S/ER) must associate+propagate to the SAME set, or
    │     branches will learn inconsistent route sets from each other
    ▼
Route Tables (Default / None / custom) + Labels (Default label = auto-applies to every
    hub's Default RT across the whole Virtual WAN)
    │  ← static routes always win over dynamically learned routes for the same prefix
    ▼
Routing Intent (OPTIONAL — Internet Traffic Policy + Private Traffic Policy, one of each max/hub)
    │  ← the moment this is enabled, it TAKES OVER management of the Default route table
    │     and every connection's association/propagation — a destructive-by-default upgrade
    │     path if static routes or custom associations already existed
    ▼
Secured Virtual Hub (Routing Intent's Next Hop = Azure Firewall via Firewall Manager, or a
    supported third-party NVA/SaaS) — all Internet and/or Private traffic bends through here
    ▼
Effective routes on the spoke VNet / on-prem branch
    ▼
Traffic flows
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the hub and router are both healthy — they are independent signals.**
   ```powershell
   Get-AzVirtualHub -ResourceGroupName <rg> -Name <hubName> | Select ProvisioningState, RoutingState
   ```
   - Good: both `Succeeded`.
   - Bad: `RoutingState: Failed` with `ProvisioningState: Succeeded` → Fix 1 (Router Reset), not a full hub reset. `ProvisioningState: Failed` → Fix 2.

2. **Confirm the Virtual WAN SKU supports what's being asked for.**
   ```powershell
   Get-AzVirtualWan -ResourceGroupName <rg> -Name <vwanName> | Select VirtualWANType
   ```
   - Good: `Standard` if ExpressRoute, P2S, Firewall/NVA, or Routing Intent are involved.
   - Bad: `Basic` + any of those → this is a design/licensing gap, not a bug. Go to Fix 3.

3. **Check whether Routing Intent is configured, and what its Next Hop actually is.**
   ```powershell
   Get-AzRoutingIntent -ResourceGroupName <rg> -ParentResourceId $hubId | Select Name, RoutingPolicies
   ```
   - Good: the expected policy type(s) (`PrivateTraffic`/`PublicTraffic`) present with the correct Next Hop resource ID.
   - Bad: no Routing Intent object at all despite the client believing traffic is being firewalled → nothing is enforcing that expectation; this is a configuration gap, not a live fault.

4. **Confirm the specific spoke's connection state and association.**
   ```powershell
   Get-AzVirtualHubVnetConnection -ResourceGroupName <rg> -ParentResourceName <hubName> -Name <connectionName>
   ```
   - Good: `ConnectionStatus: Connected`.
   - Bad: anything else → this is a connection-provisioning problem, work it before assuming a routing problem.

5. **Pull effective routes on the actual spoke NIC — the authoritative "what's really happening" view.**
   ```powershell
   Get-AzEffectiveRouteTable -ResourceGroupName <spokeRg> -NetworkInterfaceName <nic>
   ```
   - Good: expected next hop (Firewall/NVA private IP if Routing Intent is active, or `VirtualNetworkGateway`/`VirtualHub` otherwise).
   - Bad: unexpected next hop, or the destination prefix missing entirely → work back up the cascade rather than guessing at the spoke.

6. **If two gateway types (VPN + ExpressRoute) coexist in the same hub and one side's routes seem to vanish, suspect the shared ASN.**
   ```powershell
   Get-AzVirtualHub -ResourceGroupName <rg> -Name <hubName> | Select VirtualRouterAsn
   ```
   - Both gateway types are fixed at **65515** inside a vWAN hub — this is expected Microsoft architecture, not a misconfiguration, but it can conflict with an on-prem device also using 65515 (rare, but a real support-ticket cause). Confirm the on-prem ASN doesn't collide before assuming an Azure-side fault.

---
## Common Fix Paths

<details><summary>Fix 1 — Router shows Failed while the hub itself shows Succeeded</summary>

**When to use:** `RoutingState: Failed`, `ProvisioningState: Succeeded`. You can't update routes, but existing data-plane traffic may still be flowing.

Portal-only — there is no PowerShell cmdlet for this specific action:
1. Azure portal → the virtual hub resource → **Reset router** (not the same button as "Reset", which resets the whole hub).
2. Typically completes in under 10 minutes and rarely disrupts existing traffic.
3. Re-check `RoutingState` afterward.

**Rollback:** N/A — this is itself the recovery action, and it does not touch gateway resources.

</details>

<details><summary>Fix 2 — Hub resource itself shows Failed (route tables, hub router, or the hub object)</summary>

**When to use:** `ProvisioningState: Failed` on the virtual hub resource itself, not just the router.

Portal-only:
1. Azure portal → the virtual hub resource → **Reset** (full hub reset — brings failed route tables, the hub router, or the hub resource back to its provisioned state).
2. This does **not** reset any gateways deployed in the hub — if a gateway is separately unhealthy, it needs its own remediation.
3. Consider this before opening a Microsoft support case; Microsoft's own guidance is to attempt a hub reset first.

**Rollback:** N/A — recovery action, not a configuration change.

</details>

<details><summary>Fix 3 — Basic SKU can't support what's being requested (ExpressRoute / P2S / Firewall / Routing Intent)</summary>

**When to use:** Client wants ExpressRoute, User VPN (P2S), Azure Firewall/NVA integration, or Routing Intent, and the Virtual WAN is `Basic`.

```powershell
# Confirm current type first
Get-AzVirtualWan -ResourceGroupName <rg> -Name <vwanName> | Select VirtualWANType
```

1. Basic → Standard upgrade is supported and non-destructive to existing site-to-site VPN connectivity, but it is **one-way** — there is no supported downgrade path back to Basic.
2. If the hub has **pre-existing static routes** configured in the legacy Routing section (not the newer route-table model), those must be deleted first, then the upgrade performed, before the new route-table/Routing-Intent features become usable.
3. Perform the upgrade via the Azure portal's Basic-to-Standard upgrade flow (see Microsoft's upgrade doc — this is not currently a single PowerShell cmdlet operation).
4. Set client expectations up front: this is a one-way architectural commitment, not a toggle to test and revert.

**Rollback:** None available — communicate this clearly before executing, ideally during a change-management window rather than mid-incident.

</details>

<details><summary>Fix 4 — Routing Intent enabled but a spoke still bypasses the firewall (or a static route "disappeared")</summary>

**When to use:** Routing Intent is configured with a Next Hop firewall/NVA, but effective routes on a spoke show direct next hops instead of the firewall, OR a previously-configured static route on the Default route table is no longer present.

```powershell
Get-AzRoutingIntent -ResourceGroupName <rg> -ParentResourceId $hubId
Get-AzVirtualHubVnetConnection -ResourceGroupName <rg> -ParentResourceName <hubName> -Name <connectionName> |
    Select RoutingConfiguration
```

1. Confirm the spoke's Hub VNet connection is associated to the route table Routing Intent manages (normally the Default route table) — a connection deliberately associated elsewhere won't receive the redirected routes.
2. Remember: **enabling Routing Intent takes over management of the Default route table and every connection's association/propagation.** Any static routes or custom associations that predate Routing Intent may be overwritten silently the moment it's enabled — this is documented, expected behavior, not a bug, but it is the single most common source of "my routing configuration disappeared" tickets on this topic.
3. If Azure Firewall is deployed across multiple regions/hubs: confirm **every** spoke VNet in a given hub is associated to the same route table. Mixing "some spokes through the firewall, some bypassing it" within one hub is not a supported configuration.
4. Re-add any static routes that were lost as part of the Routing Intent's managed route table going forward, documented so a future re-enable doesn't repeat the loss.

**Rollback:** Disabling Routing Intent (`Remove-AzRoutingIntent`) returns route-table management to manual, but does not automatically restore any static routes or associations that existed before it was enabled — those must be re-created explicitly.

</details>

<details><summary>Fix 5 — Connection is healthy but traffic still fails</summary>

**When to use:** `ConnectionStatus: Connected`, Routing Intent (if present) looks correctly configured, but specific traffic still doesn't reach its destination.

1. The fault has left the Virtual WAN layer. Check NSGs on the destination spoke subnet/NIC — vWAN hubs themselves carry no customer-configurable NSG; all filtering happens on spoke VNet subnets or inside the Firewall/NVA.
2. If the far end is an on-premises branch over VPN or ExpressRoute, hand off to `HybridConnectivity-B.md` Triage — that runbook covers IPsec/BGP and ExpressRoute-specific failure modes in depth; don't re-diagnose them here.
3. If a Firewall is in the path (Routing Intent's Next Hop), check its own logs/rules — `AVNM-A.md`/`NSG-A.md` don't cover Firewall rule content, and neither does this file.

**Rollback:** N/A — diagnostic handoff, not a destructive action.

</details>

<details><summary>Fix 6 — VPN and ExpressRoute gateways in the same hub, routes not crossing between them</summary>

**When to use:** Both an S2S VPN gateway and an ExpressRoute gateway exist in the same virtual hub, and prefixes learned on one side aren't being propagated to the other as expected.

1. Confirm both gateway types' connections are associated **and** propagating to the same route table/label set — a mismatch here (not the ASN) is the far more common cause than the shared ASN itself.
2. Confirm the on-premises device(s) on each side aren't independently configured with ASN 65515 — since both Azure-side gateways in the hub are fixed to that ASN, an on-prem device reusing it (intentionally or by copy-paste from a template) creates a genuine BGP conflict that no Azure-side change can fix; the on-prem ASN must change.
3. Check the ExpressRoute side isn't silently dropping prefixes — Azure enforces a **maximum of 1,000 IPv4 prefixes per ExpressRoute connection**; an on-premises router advertising more than that will have excess routes dropped without an obvious client-facing error.

**Rollback:** N/A — diagnostic; any ASN change needed is on the on-premises device, not Azure.

</details>

---
## Escalation Evidence

```
=== Azure Virtual WAN Escalation ===
Ticket #:
Client / Tenant:
Virtual WAN name / RG:                    VirtualWANType (Basic/Standard):
Virtual Hub name / region:
Hub ProvisioningState:                    Hub RoutingState:
Routing Intent configured (Y/N):          Next Hop resource (if Y):
Affected connection name/type:            (VPN / ExpressRoute / P2S / Hub VNet connection)
ConnectionStatus:
Gateways present in hub:                  [ ] VPN  [ ] ExpressRoute  [ ] User VPN  [ ] Firewall/NVA
Effective route next hop observed on affected spoke NIC:
Static routes present before last change (Y/N), documented where:
On-prem ASN (if VPN/ER involved):
When did it last work:
What changed (client-reported):
Router/Hub reset attempted (Y/N), result:
Impact (users/services affected):
Escalation target:                        [ ] Microsoft Support   [ ] Internal L3   [ ] Circuit Provider (if ER involved)
```

---
## 🎓 Learning Pointers

- **Hub `ProvisioningState` and `RoutingState` are two separate health signals** — a hub can report `Succeeded` while its internal BGP router is `Failed`. Always check both before deciding between a router reset and a full hub reset. See [About virtual hub routing — Hub reset / Router reset](https://learn.microsoft.com/en-us/azure/virtual-wan/about-virtual-hub-routing).

- **Basic and Standard Virtual WAN are a hard capability boundary, not just a pricing tier** — Basic supports site-to-site VPN only. ExpressRoute, P2S, Firewall/NVA integration, and Routing Intent all require Standard, and the Basic→Standard upgrade is one-way with no downgrade path. Confirm SKU in the first 30 seconds of any "we want to add X" request. See [Virtual WAN FAQ](https://learn.microsoft.com/en-us/azure/virtual-wan/virtual-wan-faq) and [Upgrade a Virtual WAN](https://learn.microsoft.com/en-us/azure/virtual-wan/upgrade-virtual-wan).

- **Enabling Routing Intent silently takes over the Default route table and every connection's association/propagation.** Any static routes or manual associations configured before Routing Intent was enabled can be overwritten without a distinct warning at enable-time — document existing static routes before turning this on, not after something "disappears." See [How to configure Routing Intent](https://learn.microsoft.com/en-us/azure/virtual-wan/how-to-routing-policies).

- **Both the VPN gateway and the ExpressRoute gateway inside a vWAN hub share a fixed ASN of 65515.** This is normal architecture, but it becomes a real fault if an on-premises device on either side is also configured with 65515 — the fix is always on the on-premises side, never on Azure's.

- **A vWAN hub carries no customer-configurable NSG of its own.** All packet filtering happens on spoke VNet subnets/NICs or inside the Firewall/NVA that Routing Intent points to — don't go looking for a hub-level NSG that doesn't exist.

- **ExpressRoute connections silently drop prefixes beyond 1,000 IPv4 routes advertised.** A poorly summarized on-premises route table is a legitimate, fixable root cause for "some of our on-prem subnets aren't reachable through vWAN" — check the actual advertised count before assuming an Azure-side fault. See [Getting Started with Troubleshooting Virtual WAN](https://learn.microsoft.com/en-us/azure/virtual-wan/virtual-wan-troubleshooting-overview).
