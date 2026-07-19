# Azure Virtual WAN — Reference Runbook (Mode A: Deep Dive)
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

Covers **Azure Virtual WAN** as a Microsoft-managed global transit-network service: the Virtual WAN resource and its Basic/Standard SKU boundary, the virtual hub and its embedded BGP router, the four connection types (VPN, ExpressRoute, User VPN/P2S, Hub VNet connection) and their association/propagation model, hub route tables and labels, Routing Intent and Routing Policies (the declarative Internet/Private traffic-steering feature), secured virtual hubs (Azure Firewall Manager-integrated), and the standard troubleshooting decision tree for hub-router health, SKU capability gaps, and routing-intent adoption.

Does **not** cover: the internal mechanics of BGP peering, IPsec tunnel establishment, or ExpressRoute circuit/provider provisioning — those are fully documented in `HybridConnectivity-A.md`/`HybridConnectivity-B.md` for the **traditional, self-managed** hub-VNet model (a VPN/ExpressRoute gateway object attached directly to a customer-managed hub VNet). This file assumes those same underlying protocols but as they run **inside a vWAN-managed virtual hub**, which is a different resource model with different ASN handling (fixed 65515 for both gateway types) and different scale limits — cross-reference `HybridConnectivity-A.md` for tunnel/BGP-session-level diagnosis once a connection is confirmed to exist and associate correctly here. Also does not cover NSG rule evaluation or content (`NSG-A.md`/`NSG-B.md` — a vWAN hub itself carries no customer-configurable NSG; all filtering happens on spoke subnets/NICs or inside the Firewall/NVA that Routing Intent points to). Also does not cover Azure Virtual Network Manager's own hub-and-spoke connectivity configurations (`AVNM-A.md`) — AVNM can, in preview, target a Virtual WAN hub as its "hub" type, but that is a separate governance/automation control plane sitting *above* Virtual WAN, creating or updating Virtual WAN virtual network connections rather than owning the hub itself; this file covers the hub and its native routing model, not AVNM's orchestration of it. Also does not cover Azure Firewall rule content/policy authoring — only its role as Routing Intent's Next Hop resource.

---
## How It Works

<details><summary>Full architecture</summary>

**The core idea.** Traditional Azure hub-and-spoke networking is self-managed: an engineer creates a hub VNet, peers every spoke to it, deploys a VPN/ExpressRoute gateway inside the hub, and manually maintains route tables and NSGs as the estate grows. Azure Virtual WAN replaces that self-managed hub with a **Microsoft-managed, software-defined transit network**: a global "Virtual WAN" resource contains one or more regional **virtual hubs**, each of which is an Azure-managed VNet-like construct with its own embedded router, capable of hosting VPN, ExpressRoute, and User VPN (point-to-site) gateways plus Azure Firewall — all pre-wired for any-to-any transitive routing without the customer building peerings or route tables by hand.

**Basic vs. Standard — a capability ceiling, not just a price point.** The Virtual WAN resource itself is typed **Basic** or **Standard** at creation, and this determines what its hubs are even allowed to run:
- **Basic**: site-to-site VPN only. No ExpressRoute, no User VPN (P2S), no Azure Firewall/NVA integration, no Routing Intent, no full-mesh VNet-to-VNet transit.
- **Standard**: everything — ExpressRoute, User VPN, Firewall/NVA integration, Routing Intent, and transitive VNet-to-VNet routing through the hub at up to 50 Gbps aggregate.

Upgrading Basic → Standard is supported and does not disrupt existing site-to-site connectivity, but it is **one-way** — there is no supported downgrade path. If the hub has pre-existing routes configured in the legacy (pre-route-table) Routing section, those must be deleted before the upgrade, or before new route tables can be created on a Standard hub with legacy leftovers.

**The virtual hub router.** Every virtual hub contains a Microsoft-managed router that speaks BGP to every gateway and connection attached to the hub, and provides transit connectivity between VNets connected to it — up to an aggregate 50 Gbps for VNet-to-VNet traffic. Both the VPN gateway and the ExpressRoute gateway deployed inside a given hub use a **fixed ASN of 65515** — identical for both gateway types, in every hub. This is normal, unremarkable Microsoft architecture right up until an on-premises device on either the VPN or ExpressRoute side is *also* configured with ASN 65515 (common in copy-pasted lab configs), at which point it becomes a genuine, hard-to-spot BGP conflict — the fix is always on the on-premises side.

**Hub health has two independent signals.** `ProvisioningState` reflects the hub resource itself; `RoutingState` reflects the internal router specifically. A hub can show `Succeeded` while its router shows `Failed` (routes can't be updated, though existing data-plane traffic may keep flowing), or the hub resource itself can fail outright. Two distinct portal actions address these: **Reset router** (targeted, typically resolves in under 10 minutes, rarely disrupts traffic, does not touch gateways) and **Reset** (the full hub reset, for failed route tables/router/hub object, also does not reset gateways). Microsoft's own guidance is to attempt the appropriate reset before opening a support case.

**Connections and their routing configuration.** Four connection types exist: **VPN connection** (site to hub VPN gateway), **ExpressRoute connection** (circuit to hub ExpressRoute gateway), **P2S configuration connection** (User VPN client config to hub P2S gateway), and **Hub virtual network connection** (a spoke VNet to the hub). Every connection has a routing configuration with two independent properties:
- **Association** — the *one* route table a connection's traffic is routed according to. By default, every connection associates to the hub's built-in **Default route table**.
- **Propagation** — the route table(s) a connection's *own* routes are advertised into, via **Labels** (a route-table grouping mechanism). The built-in `Default` label automatically applies to every hub's Default route table across the entire Virtual WAN — propagating to `Default` reaches every hub's default table in one step, not just the local hub's.

A **None route table** exists per hub for connections that should propagate no routes at all. Static routes added directly to a route table always take precedence over dynamically (BGP-)learned routes for the same prefix.

**Consistency rule for branches.** All branch connections (VPN, ExpressRoute, P2S) must associate to the same route table and propagate to the same set of route tables/labels — if branches are inconsistent, some branches will learn a different set of "who else is reachable" than others, which is confusing to diagnose because each individual connection can look perfectly healthy in isolation.

**Routing Intent and Routing Policies — declarative traffic steering.** Rather than hand-building UDRs to force traffic through a firewall, Routing Intent lets an engineer declare, at the hub level, that Internet-bound and/or Private (branch + VNet, including inter-hub) traffic should be sent to a **Next Hop** — Azure Firewall (via Firewall Manager), a supported third-party NVA, or a SaaS security provider. Each hub supports **at most one Internet Traffic Routing Policy and one Private Traffic Routing Policy**, each with a single Next Hop resource.
- **Internet Traffic Routing Policy** — all branch and VNet connections to that hub send Internet-bound traffic to the Next Hop.
- **Private Traffic Routing Policy** — **all** branch and VNet traffic in and out of the hub, including inter-hub traffic, is forwarded to the Next Hop. There is no partial/selective private-traffic option within a hub.

**The single most important operational gotcha in this entire topic:** the moment Routing Intent is enabled, it **takes over management of the hub's default route table and every connection's association/propagation configuration.** Static routes or custom associations that existed before enabling Routing Intent can be silently overwritten as part of that takeover — this is documented, intentional behavior, not a bug, but it is the overwhelming majority-cause of "our routing configuration just disappeared" tickets on Virtual WAN. Document any static routes and non-default associations *before* enabling Routing Intent, not after something breaks.

**Secured virtual hub.** A secured virtual hub is simply a virtual hub with Routing Intent's Next Hop pointed at Azure Firewall, provisioned and managed through **Azure Firewall Manager** rather than the Firewall resource directly. When Azure Firewall spans multiple regions/hubs, every spoke VNet within a given hub must be associated to the same route table — Azure does not support "some spokes through the firewall, some bypassing it" within a single hub.

**Global transit and cross-hub behavior.** Hubs within the same Virtual WAN dynamically announce routes to each other (as long as propagation targets the same labels) — but this applies to dynamic routing only; once a static route is defined, hub-to-hub dynamic announcement for that prefix no longer applies automatically. The `0.0.0.0/0` (default Internet) route is explicitly scoped to its local hub's route table and does **not** propagate across hubs. Virtual WAN also cannot inject a route into a spoke that matches or is more specific than that spoke VNet's own address prefix — it can only attract traffic for prefixes broader (less specific) than the VNet's own range.

**Scale limits worth knowing before a design conversation, not during an incident** (current published limits, verify against the live FAQ before quoting a client): 1,000 VPN branch connections per hub; 20 Gbps aggregate throughput per S2S VPN gateway; 2 Gbps per VPN connection (2 tunnels, 1 Gbps/tunnel); 100,000 Point-to-Site users per hub; 200 Gbps aggregate P2S gateway throughput; 20 Gbps aggregate ExpressRoute gateway throughput; 8 ExpressRoute circuit connections per hub; up to 1,000 IPv4 prefixes advertised per ExpressRoute connection (excess silently dropped); VNet connections per hub without Routing Intent = 500 minus the total number of hubs in the Virtual WAN; with Routing Intent private routing policies enabled, up to 600 VNet address spaces per hub; 50 Gbps aggregate hub-router throughput for VNet-to-VNet transit; up to 2,000 VM workloads across all VNets connected to a single hub; and a hard ceiling of 10,000 total routes a hub will accept from all connected resources combined.

</details>

---
## Dependency Stack

```
Layer 7 — Effective routes on the spoke NIC / on-prem branch
          (Get-AzEffectiveRouteTable / on-prem router's own route table —
           the only fully authoritative "what's actually happening" view)
              ▲
Layer 6 — Secured Virtual Hub (Routing Intent's Next Hop = Azure Firewall via
          Firewall Manager, or a supported third-party NVA/SaaS)
              ▲
Layer 5 — Routing Intent (OPTIONAL — Internet + Private Traffic Routing Policies,
          max 1 each per hub; ENABLING THIS TAKES OVER the Default route table
          and every connection's association/propagation — destructive-by-default
          to pre-existing static routes/custom associations)
              ▲
Layer 4 — Route Tables (Default / None / custom) + Labels
          (Default label auto-applies to every hub's Default RT across the whole
           Virtual WAN; static routes always beat dynamically learned ones)
              ▲
Layer 3 — Connections (VPN / ExpressRoute / P2S config / Hub VNet connection)
          Each has: ONE association (which RT governs its traffic) +
                    propagation (which RT(s)/label(s) its own routes reach)
          All branch connections must be consistent with each other, or branches
          learn different reachability sets from one another
              ▲
Layer 2 — Gateways deployed in the hub (Standard SKU required for all but S2S VPN)
          VPN gateway | ExpressRoute gateway | User VPN (P2S) gateway | Firewall/NVA
          Both VPN and ExpressRoute gateways share a FIXED ASN of 65515 in every hub
              ▲
Layer 1 — Virtual Hub (regional; its own BGP router; ProvisioningState and
          RoutingState are INDEPENDENT health signals)
              ▲
Layer 0 — Virtual WAN resource, typed Basic or Standard at creation
          (Basic = site-to-site VPN ONLY; upgrade to Standard is supported but
           ONE-WAY, no downgrade path)
```

A failure at any layer tends to surface as the same downstream symptom — "traffic isn't reaching where I expect" — which is why Layer 7 (effective routes) is always the first diagnostic pull: it tells you definitively whether the problem sits above or below it before you guess at a layer.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Hub shows healthy in the portal but route changes won't apply | `ProvisioningState: Succeeded`, `RoutingState: Failed` — two independent signals | `Get-AzVirtualHub` → both fields; use Reset router, not full hub Reset |
| Client asks for ExpressRoute/P2S/Firewall/Routing Intent and it's simply not available in the portal | Virtual WAN is typed `Basic` | `Get-AzVirtualWan` → `VirtualWANType`; plan a one-way Standard upgrade |
| A static route that used to exist on the Default route table is gone | Routing Intent was enabled and took over Default route table management | `Get-AzRoutingIntent`; compare against pre-change documentation |
| A spoke's traffic bypasses the Firewall even though Routing Intent is configured | Spoke's Hub VNet connection isn't associated to the route table Routing Intent manages | `Get-AzVirtualHubVnetConnection` → `RoutingConfiguration.AssociatedRouteTable` |
| Multi-region Azure Firewall, and the client wants only some spokes in a hub filtered | Not supported — every spoke VNet in a hub must associate to the same route table | Confirm all spoke associations in that hub match |
| Branch A can reach spoke X, Branch B can't, despite both looking "Connected" | Branches propagate/associate to different route tables — an inconsistency, not a fault on either individual connection | Compare `RoutingConfiguration` across every branch connection |
| VPN and ExpressRoute gateways share a hub; one side's on-prem routes never reach the other's on-prem network | Fixed shared ASN 65515 conflicting with an on-prem device also using 65515 | Confirm on-prem BGP ASN on both sides; the fix is on-prem, not Azure |
| Cross-hub traffic to the internet fails from a second hub even though the first hub has an Internet Routing Policy | `0.0.0.0/0` is local-hub-only and does not propagate across hubs | Confirm each hub needing internet egress has its own Internet Traffic Routing Policy |
| A new, more-specific static route to a subnet inside an already-connected spoke VNet won't take effect | Virtual WAN cannot inject a route matching or more specific than the VNet's own prefix | Compare the static route's prefix length against the VNet's actual address space |
| ExpressRoute-connected on-prem site is missing some routes, seemingly at random | On-prem router advertising more than 1,000 IPv4 prefixes on that connection; excess silently dropped | Count actual advertised prefixes on the ExpressRoute connection |
| Pre-existing legacy static routes block creation of new route tables on a Standard hub | Legacy (pre-route-table) Routing-section routes must be deleted first | Portal → hub → Routing (legacy) section; delete, then create new route tables |
| Trying to upgrade a Basic vWAN with legacy routes still configured | Same legacy-route blocker as above, but upgrade-gated | Delete legacy routes, then upgrade Basic → Standard (one-way) |
| AVNM shows a "Virtual WAN hub" connectivity option and the client expects it to behave like this file's model | AVNM's Virtual WAN hub support (preview) is a separate governance layer that creates/updates VWAN virtual network connections — it doesn't replace or duplicate this file's routing model | See `AVNM-A.md` "Hub-and-spoke" section; confirm which layer actually owns the configuration in question |
| Two spokes in the same hub, one reportedly "not going through the firewall" while the other is | Very likely a per-spoke association mismatch, not a Firewall rule issue | `Get-AzVirtualHubVnetConnection` on both spokes; compare `RoutingConfiguration.AssociatedRouteTable` |

---
## Validation Steps

1. **Confirm hub and router health independently.**
   ```powershell
   Get-AzVirtualHub -ResourceGroupName <rg> -Name <hubName> | Select ProvisioningState, RoutingState, VirtualRouterAsn
   ```
   Good: both `Succeeded`. Bad: either `Failed` — see the matching reset action before anything else.

2. **Confirm the Virtual WAN SKU.**
   ```powershell
   Get-AzVirtualWan -ResourceGroupName <rg> -Name <vwanName> | Select VirtualWANType
   ```
   Good: `Standard` for anything beyond plain site-to-site VPN. Bad: `Basic` + an unsupported ask — this is a design conversation, not a fix.

3. **Enumerate gateways actually deployed in the hub.**
   ```powershell
   Get-AzVpnGateway -ResourceGroupName <rg> | Where-Object { $_.VirtualHub.Id -like "*$hubName*" }
   Get-AzExpressRouteGateway -ResourceGroupName <rg>
   ```
   Good: exactly the gateway types the client expects to have deployed. Bad: a missing gateway type the client believes is configured — nothing downstream will work until it's actually deployed.

4. **Confirm Routing Intent's presence, policy types, and Next Hop.**
   ```powershell
   $hub = Get-AzVirtualHub -ResourceGroupName <rg> -Name <hubName>
   Get-AzRoutingIntent -ResourceGroupName <rg> -ParentResourceId $hub.Id | Select Name, RoutingPolicies
   ```
   Good: the expected policy type(s) present, Next Hop resource ID matches the intended Firewall/NVA. Bad: missing entirely, or Next Hop pointing at an unexpected resource.

5. **Confirm each relevant connection's association and propagation.**
   ```powershell
   Get-AzVirtualHubVnetConnection -ResourceGroupName <rg> -ParentResourceName <hubName> -Name <connectionName> |
       Select ConnectionStatus, RoutingConfiguration
   ```
   Good: `Connected`, association matches the route table Routing Intent (if any) manages. Bad: `Connected` but associated to an unexpected/custom route table — traffic will not be steered as the client expects.

6. **Pull effective routes on the actual spoke NIC — the ground truth.**
   ```powershell
   Get-AzEffectiveRouteTable -ResourceGroupName <spokeRg> -NetworkInterfaceName <nic>
   ```
   Good: next hop matches expectation (Firewall/NVA private IP under Routing Intent, or `VirtualNetworkGateway`/hub router otherwise). Bad: unexpected next hop or a missing destination prefix entirely.

7. **For hub-to-hub or Internet egress questions, confirm per-hub scope explicitly.**
   ```powershell
   Get-AzRoutingIntent -ResourceGroupName <rg> -ParentResourceId (Get-AzVirtualHub -ResourceGroupName <rg> -Name <otherHubName>).Id
   ```
   Good: each hub needing its own Internet egress has its own Internet Traffic Routing Policy — remember `0.0.0.0/0` does not propagate cross-hub. Bad: assuming one hub's Internet policy covers the whole Virtual WAN.

---
## Troubleshooting Steps (by phase)

**Phase 1 — SKU and hub health (rule out the two silent design/health gaps first).**
Confirm Virtual WAN type against what's being requested (Validation Step 2), and confirm `ProvisioningState`/`RoutingState` independently (Validation Step 1). A huge fraction of "this feature doesn't work" tickets on Virtual WAN are actually "this feature isn't available on this SKU" or "the router itself is unhealthy" — both fail without an obvious error message pointing at the real cause.

**Phase 2 — Gateway and connection inventory.**
Confirm every gateway the client believes exists is actually deployed (Validation Step 3), and confirm the specific connection's status and routing configuration (Validation Step 5). A connection that looks "Connected" can still be associated to the wrong route table.

**Phase 3 — Routing Intent adoption check.**
If Routing Intent is in play, confirm it exists, confirm its Next Hop, and — critically — confirm whether it was enabled *after* any static routes or custom associations were configured. If timing suggests Routing Intent was turned on after prior manual configuration, assume the takeover behavior is the root cause before looking anywhere else.

**Phase 4 — Effective-state confirmation.**
Pull `Get-AzEffectiveRouteTable` on the actual affected spoke NIC rather than reasoning from portal configuration screens. This resolves the majority of "is it even applying" questions in one step, the same way `Get-AzNetworkManagerEffectiveConnectivityConfiguration` does for AVNM.

**Phase 5 — Cross-hub and branch-consistency audit.**
For multi-hub or multi-branch environments, confirm every branch connection associates/propagates consistently, and confirm each hub needing Internet egress has its own policy (default route doesn't cross hubs). Inconsistent branch configuration is a common, easy-to-miss root cause precisely because each individual connection can look completely healthy in isolation.

**Phase 6 — Escalate beyond this topic only after the above confirm clean.**
If SKU, hub/router health, gateway presence, connection association, and effective routes all check out and traffic still fails, hand off: to `HybridConnectivity-B.md`/`HybridConnectivity-A.md` for BGP/IPsec/ExpressRoute-circuit-level diagnosis, to `NSG-B.md`/`NSG-A.md` for spoke-subnet filtering, or to the Firewall/NVA's own logs if Routing Intent's Next Hop is in the path. Don't keep re-auditing Virtual WAN configuration that's already confirmed correct.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield Virtual WAN hub with Routing Intent (secured hub) onboarding</summary>

Use when standing up a new client's Virtual WAN hub from scratch with Azure Firewall as the security boundary.

1. Create the Virtual WAN resource as **Standard** from the outset if Routing Intent, ExpressRoute, or P2S are anywhere in the client's roadmap — starting Basic and upgrading later is fine operationally, but there's no reason to plan for a one-way upgrade if the requirement is already known.
2. Create the virtual hub in the target region(s); deploy the required gateways (VPN/ExpressRoute/P2S) and Azure Firewall.
3. Configure Azure Firewall as a **secured virtual hub** via Firewall Manager, then enable Routing Intent with the Internet and/or Private Traffic Routing Policies pointed at the Firewall as Next Hop.
4. Attach spoke VNet connections and branch connections — since Routing Intent is enabled *before* any static routes exist, there's nothing for it to silently overwrite; this ordering avoids the single most common Routing Intent complaint entirely.
5. Confirm every spoke intended to be firewalled is associated to the route table Routing Intent manages (normally Default) — remember mixed bypass within one hub isn't supported.
6. Validate via `Get-AzEffectiveRouteTable` on at least one representative spoke NIC before considering the build complete.

**Rollback:** Removing Routing Intent (`Remove-AzRoutingIntent`) returns route-table management to manual but does not restore a prior state, since none existed yet in a greenfield build — low risk at this stage compared to retrofitting an existing hub.

</details>

<details><summary>Playbook 2 — Retrofitting Routing Intent onto an existing hub with manual static routes</summary>

Use when a client already has a working Virtual WAN hub with manually configured route tables/static routes and wants to add Azure Firewall via Routing Intent.

1. **Document every static route and every connection's current association/propagation configuration before touching anything** — export via the Evidence Pack script below. This is the single most important step in this playbook; skipping it is how "our routes disappeared" incidents happen.
2. Deploy Azure Firewall in the hub and configure it as a secured virtual hub via Firewall Manager.
3. Enable Routing Intent with the desired policy types and Next Hop set to the Firewall.
4. Immediately re-pull the Default route table and every connection's routing configuration; compare against the pre-change export. Re-create any static routes that were overwritten, and re-associate any connections that reverted to defaults unexpectedly.
5. Validate with `Get-AzEffectiveRouteTable` on representative spokes and branches.

**Rollback:** `Remove-AzRoutingIntent` returns management to manual, but again does not restore prior static routes automatically — the pre-change export from step 1 is what makes rollback actually possible, not the removal command itself.

</details>

<details><summary>Playbook 3 — Basic-to-Standard SKU upgrade</summary>

Use when a client on Basic Virtual WAN needs ExpressRoute, P2S, Firewall/NVA integration, or Routing Intent.

1. Confirm no legacy (pre-route-table) static routes remain in the hub's Routing section — delete them first if present; a Standard hub with legacy leftovers can't create new route tables until they're cleared.
2. Perform the upgrade via the Azure portal's Basic→Standard flow.
3. Set explicit client expectations beforehand: this is **one-way** — there is no supported path back to Basic once upgraded.
4. Existing site-to-site VPN connectivity is not disrupted by the upgrade itself; validate post-upgrade regardless.
5. Only after the upgrade completes, proceed with deploying ExpressRoute/P2S gateways, Firewall, or Routing Intent as needed.

**Rollback:** None. This playbook has no rollback step by design — communicate this before scheduling the change, not after.

</details>

<details><summary>Playbook 4 — Fleet-wide Virtual WAN health sweep (MSP multi-client)</summary>

Use for a periodic governance check across every Virtual WAN an MSP manages on behalf of clients.

1. Run `Scripts/Get-VirtualWANHealth.ps1` against each client subscription to inventory Virtual WAN SKU, hub provisioning/routing health, gateway presence and scale-unit sizing, Routing Intent presence and Next Hop, and per-connection association/propagation consistency.
2. Flag any hub with `RoutingState: Failed` for immediate router-reset action rather than waiting for a client-reported incident.
3. Flag any Basic-SKU Virtual WAN where gateway/connection inventory suggests the client is already approaching site-to-site-only limits, as a proactive Standard-upgrade conversation.
4. Flag any hub where Routing Intent is absent but a Firewall/NVA resource exists in the hub's resource group — a common half-finished secured-hub deployment.
5. Cross-reference branch connection association/propagation for consistency across every branch on a given hub, surfacing mismatches before they generate a confusing client ticket.

**Rollback:** N/A — read-only audit playbook.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Azure Virtual WAN evidence for a specific hub ahead of escalation — SKU, hub/router
    health, gateway inventory, Routing Intent configuration, and every connection's routing
    configuration in one pass.
#>
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$VirtualWanName,
    [Parameter(Mandatory)][string]$HubName
)

$hub = Get-AzVirtualHub -ResourceGroupName $ResourceGroupName -Name $HubName

$evidence = [ordered]@{
    VirtualWan          = Get-AzVirtualWan -ResourceGroupName $ResourceGroupName -Name $VirtualWanName | Select-Object Name, VirtualWANType
    Hub                 = $hub | Select-Object Name, ProvisioningState, RoutingState, VirtualRouterAsn, AddressPrefix
    VpnGateways         = Get-AzVpnGateway -ResourceGroupName $ResourceGroupName | Where-Object { $_.VirtualHub.Id -eq $hub.Id }
    ExpressRouteGateways = Get-AzExpressRouteGateway -ResourceGroupName $ResourceGroupName | Where-Object { $_.VirtualHub.Id -eq $hub.Id }
    RoutingIntent       = try { Get-AzRoutingIntent -ResourceGroupName $ResourceGroupName -ParentResourceId $hub.Id } catch { "None or inaccessible: $($_.Exception.Message)" }
    HubVnetConnections  = Get-AzVirtualHubVnetConnection -ResourceGroupName $ResourceGroupName -ParentResourceName $HubName |
                              Select-Object Name, ConnectionStatus, EnableInternetSecurity, RoutingConfiguration
    VpnConnections      = Get-AzVpnConnection -ResourceGroupName $ResourceGroupName -ParentResourceName ((Get-AzVpnGateway -ResourceGroupName $ResourceGroupName | Where-Object { $_.VirtualHub.Id -eq $hub.Id } | Select-Object -First 1).Name) -ErrorAction SilentlyContinue
}

$evidence | ConvertTo-Json -Depth 8 | Out-File "VirtualWAN-Evidence-$HubName-$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
Write-Host "Evidence pack written." -ForegroundColor Green
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-AzVirtualWan -ResourceGroupName <rg> -Name <vwan>` | Confirm Basic vs. Standard SKU — the first thing to check on any capability question |
| `Get-AzVirtualHub -ResourceGroupName <rg> -Name <hub>` | Hub `ProvisioningState`, `RoutingState`, `VirtualRouterAsn` — two independent health signals |
| `Get-AzVpnGateway -ResourceGroupName <rg>` | Enumerate VPN gateways and which hub they belong to |
| `Get-AzExpressRouteGateway -ResourceGroupName <rg>` | Enumerate ExpressRoute gateways in scope |
| `Get-AzP2sVpnGateway -ResourceGroupName <rg>` | Enumerate User VPN (Point-to-Site) gateways |
| `Get-AzRoutingIntent -ResourceGroupName <rg> -ParentResourceId <hubId>` | Routing Intent policies and Next Hop resource for a hub |
| `Get-AzVirtualHubVnetConnection -ResourceGroupName <rg> -ParentResourceName <hub>` | Spoke VNet connection status and routing configuration |
| `Get-AzVpnConnection -ResourceGroupName <rg> -ParentResourceName <vpnGatewayName>` | Branch VPN connection status per gateway |
| `Get-AzVirtualHubRouteTable -ResourceGroupName <rg> -VirtualHubName <hub>` | Enumerate route tables on a hub (Default/None/custom) |
| `Get-AzVHubEffectiveRoute -ResourceGroupName <rg> -VirtualHubName <hub> -ResourceId <connectionId>` | Effective routes as seen by a specific hub connection |
| `Get-AzEffectiveRouteTable -ResourceGroupName <rg> -NetworkInterfaceName <nic>` | Ground-truth effective routes on a spoke VM NIC |
| `Get-AzVirtualHub \| Select Name, RoutingState` (fleet sweep) | Quick multi-hub router-health scan |
| `Remove-AzRoutingIntent -ResourceGroupName <rg> -ParentResourceId <hubId>` | Disable Routing Intent — does NOT restore prior static routes automatically |
| Portal: hub blade → **Reset router** | Targeted router recovery; doesn't touch gateways |
| Portal: hub blade → **Reset** | Full hub recovery (route tables/router/hub object); doesn't touch gateways |
| Portal: Basic→Standard upgrade flow | One-way SKU upgrade; no PowerShell-only equivalent currently documented |

---
## 🎓 Learning Pointers

- **Basic and Standard Virtual WAN are a hard architectural boundary, not a pricing preference.** Confirm SKU before promising ExpressRoute, P2S, Firewall/NVA integration, or Routing Intent to a client — and remember the upgrade is one-way. See [Virtual WAN FAQ](https://learn.microsoft.com/en-us/azure/virtual-wan/virtual-wan-faq) and [Upgrade a Virtual WAN from Basic to Standard](https://learn.microsoft.com/en-us/azure/virtual-wan/upgrade-virtual-wan).

- **Enabling Routing Intent takes over the Default route table and every connection's association/propagation — this is the single highest-impact gotcha in the entire topic.** Always export and document existing static routes and custom associations before enabling it on a hub that's already in production, per Playbook 2. See [How to configure Virtual WAN hub routing policies](https://learn.microsoft.com/en-us/azure/virtual-wan/how-to-routing-policies).

- **Hub `ProvisioningState` and `RoutingState` are independent — and there are two distinct reset actions for them.** A "Reset" on a hub whose router alone has failed is more disruptive than necessary; use "Reset router" first for that specific case. See [About virtual hub routing — Hub reset / Router reset](https://learn.microsoft.com/en-us/azure/virtual-wan/about-virtual-hub-routing).

- **Both gateway types inside a vWAN hub share a fixed ASN of 65515.** This is invisible until an on-premises device on either side happens to reuse the same ASN — a subtle, hard-to-spot BGP conflict whose fix is always on the customer's router, never Azure's.

- **The `0.0.0.0/0` default route is local to its own hub and never propagates across hubs.** Every hub needing independent Internet egress needs its own Internet Traffic Routing Policy — don't assume one hub's policy covers a whole multi-hub Virtual WAN.

- **Virtual WAN is a Microsoft-managed alternative to a self-built hub-and-spoke, not a superset of it in every dimension.** Traditional hub-and-spoke still gives finer-grained UDR/NSG control and can be cheaper below roughly 30 spokes or a single-region footprint; Virtual WAN's automatic any-to-any transit and native multi-region hub mesh earn their operational overhead mainly at 30+ spokes or 3+ regions. This is a genuine architectural trade-off conversation, not a strict upgrade — see the [Azure Virtual WAN network topology design guide](https://learn.microsoft.com/en-us/azure/networking/design-guide/virtual-wan) before recommending one over the other.
