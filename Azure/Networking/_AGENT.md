# Azure Networking (Hybrid Connectivity + NSG + AVNM + Virtual WAN) — Agent Instructions

## What's in this folder

Runbooks and scripts for **Azure networking**, covering four related but distinct topics. **Hybrid connectivity** — the VPN Gateway (site-to-site IPsec/BGP) and ExpressRoute (private circuit) paths that connect on-premises client networks to Azure: IPsec tunnel establishment, BGP peering and route propagation on both paths, ExpressRoute's three-zone (customer/provider/Microsoft) provisioning model, and the NSG/UDR data-plane checks that come after control-plane health is confirmed. **Network Security Groups (NSG)** — the general-purpose filtering layer itself: rule priority/evaluation order, the dual subnet-level+NIC-level enforcement model, service tags, Application Security Groups, augmented rules, and Security Admin Rules via Azure Virtual Network Manager. **Azure Virtual Network Manager (AVNM)** — the centralized governance control plane that deploys connectivity (mesh/hub-and-spoke), security admin, and routing configurations across many VNets/subscriptions at once: network manager scope/delegation, static vs. dynamic (Azure-Policy-based) network group membership, the connected-group construct behind mesh topologies, and the goal-state deployment model. **Azure Virtual WAN** — the Microsoft-managed global transit-network service: the Basic/Standard SKU capability boundary (one-way upgrade), the virtual hub and its embedded BGP router (with `ProvisioningState`/`RoutingState` as two independent health signals and a fixed ASN 65515 shared by VPN and ExpressRoute gateways), the connection association/propagation model, hub route tables and labels, and Routing Intent/Routing Policies (the declarative Internet/Private traffic-steering feature whose single biggest gotcha is silently taking over the Default route table on enable). NSG is the shared data-plane checkpoint that HybridConnectivity, AVNM's own Security Admin Rules, Virtual WAN spoke traffic, `Azure/AVD/AVD-Connectivity-A.md`, and `Azure/Windows365/Windows365-A.md` all converge on — this folder is where its mechanics are fully documented once rather than repeated in each of those files. AVNM's *connectivity configuration* topologies (mesh/hub-and-spoke) are a distinct, higher layer that can, in preview, target a Virtual WAN hub as its "hub" type — that's AVNM orchestrating Virtual WAN, not a duplicate of Virtual WAN's own native hub-routing model documented in `VirtualWAN-A.md`/`VirtualWAN-B.md`.

Does not cover point-to-site VPN as a **standalone, non-vWAN** topic (the User VPN/P2S gateway type embedded in a Virtual WAN hub is covered in `VirtualWAN-A.md`/`VirtualWAN-B.md`; a customer-managed P2S gateway on a traditional hub VNet is not separately documented), Azure Firewall/NVA **rule content or policy authoring** (covered only as Virtual WAN Routing Intent's Next Hop resource, or where it intersects GatewaySubnet behavior), User-Defined Routes/route tables as a standalone routing topic outside the hub-routing context covered here (referenced only where they intersect NSG or Virtual WAN troubleshooting), or AVNM's IP Address Management (IPAM) feature (functionally and operationally independent of connectivity/security governance, no MSP-ticket history yet).

---

## Before responding, also check

- **Azure/AVD/AVD-Connectivity-A.md** — treats NSG rules and service tags specifically as they affect AVD session host reachability; use that runbook instead of this one if the ticket is AVD-specific, not general hybrid connectivity
- **Windows/Troubleshooting/AlwaysOnVPN-A.md** — a different VPN technology entirely (client-to-Azure/on-prem via Windows' native VPN client), not to be confused with the site-to-site VPN Gateway covered here
- **Security/ConditionalAccess** — if the underlying complaint is "users can't reach an app" rather than "sites can't reach each other," confirm this isn't actually a CA/identity issue before assuming a network-path fault

---

## Folder contents

| File | What it covers |
|------|----------------|
| `HybridConnectivity-B.md` | Hotfix runbook — IPsec tunnel down, BGP peer not connecting/flapping, ExpressRoute circuit/provider provisioning stuck, eBGP peering mismatch, routes present but traffic blocked |
| `HybridConnectivity-A.md` | Deep dive — full IPsec/BGP and ExpressRoute three-zone architecture, dependency stack from physical/provisioning layer through data plane, migration and provider-outage playbooks |
| `Scripts/Get-HybridConnectivityHealth.ps1` | Read-only sweep across VPN Gateways and ExpressRoute circuits — connection/BGP/peering state, near-prefix-limit warning, control-plane-vs-data-plane traffic sanity check |
| `NSG-B.md` | NSG hotfix runbook — priority conflicts, subnet/NIC dual-layer conflicts, service tag and ASG misconfigurations, default-deny blocks, Security Admin Rule check |
| `NSG-A.md` | NSG deep dive — rule evaluation architecture, Security Admin Rules (AVNM), service tags, ASGs, augmented rules, flow log migration (NSG flow logs retiring Sept 30, 2027) |
| `Scripts/Get-NSGRuleAudit.ps1` | Read-only fleet-wide sweep — broad management-port exposure, priority-collision risk, dual-layer NIC/subnet coverage inventory, Security Admin Rule presence |
| `AVNM-B.md` | AVNM hotfix runbook — VNet not receiving configuration (scope/never-deployed), dynamic membership lag, goal-state redeploy trap, "use hub as gateway" silent partial-peering, mesh IP-overlap drops |
| `AVNM-A.md` | AVNM deep dive — scope/delegation model, network groups (static/dynamic), connectivity configuration architecture (mesh/hub-and-spoke/connected groups), goal-state deployment model, migration and fleet-audit playbooks |
| `Scripts/Get-AVNMConfigAudit.ps1` | Read-only sweep — network group membership (flags empty static groups), configurations defined but never deployed, multi-config goal-state risk regions, failed deployments, optional single-VNet effective-state check |
| `VirtualWAN-B.md` | Virtual WAN hotfix runbook — hub/router health split (ProvisioningState vs. RoutingState), Basic-SKU capability gaps, Routing Intent's Default-route-table takeover on enable, shared-ASN (65515) VPN/ExpressRoute gateway conflicts, connection association checks |
| `VirtualWAN-A.md` | Virtual WAN deep dive — Basic/Standard SKU architecture, virtual hub router, connection association/propagation/labels model, Routing Intent and secured virtual hub architecture, scale limits, greenfield/retrofit/SKU-upgrade/fleet-audit playbooks |
| `Scripts/Get-VirtualWANHealth.ps1` | Read-only sweep across every Virtual WAN — hub/router health, Basic-SKU gateway anomalies, half-finished secured-hub builds (Firewall present, no Routing Intent), inconsistent branch/spoke route-table association, optional ExpressRoute prefix-count flag |

---

## Common entry points

- **"Site-to-site VPN won't connect"** → `HybridConnectivity-B.md` Fix 1 — confirm IPsec tunnel before touching BGP
- **"BGP won't come up over our VPN"** → `HybridConnectivity-B.md` Triage row 2 — BGP cannot start until the IPsec tunnel itself is Connected
- **"VPN BGP session keeps dropping"** → `HybridConnectivity-B.md` Fix 3 — check for IPsec tunnel flapping and packet loss against the fixed 180s hold timer (no BFD support)
- **"ExpressRoute circuit shows Not provisioned"** → `HybridConnectivity-B.md` Triage — split Microsoft-side vs. provider-side immediately, escalate to the correct owner
- **"ExpressRoute BGP peering Active/Idle instead of Established"** → `HybridConnectivity-B.md` Fix 4 — VLAN/ASN/subnet/MD5 mismatch against the linked CE/PE-MSEE
- **"Routes look fine but traffic still doesn't reach the destination"** → `HybridConnectivity-B.md` Fix 5 — check GatewaySubnet and destination-subnet NSG/UDR
- **"Should we move this client from static routes to BGP?"** → `HybridConnectivity-A.md` Playbook 1
- **"Fleet-wide hybrid connectivity health check across clients"** → `Scripts/Get-HybridConnectivityHealth.ps1`
- **"I added an NSG allow rule and traffic is still blocked"** → `NSG-B.md` Fix 1 (priority conflict) then Fix 2 (subnet/NIC dual-layer gap)
- **"NSG rules look correct but traffic still misbehaves"** → `NSG-B.md` Triage step 5 — check for a Security Admin Rule (Azure Virtual Network Manager) first
- **"Rule uses a service tag and doesn't behave as expected"** → `NSG-B.md` Fix 3 — `VirtualNetwork` includes peered VNets + on-prem + gateway VIP, not just the local VNet
- **"Client wants NSG flow logs turned on"** → redirect to VNet flow logs; NSG flow logs can no longer be newly created (cutoff June 30, 2025, retiring Sept 30, 2027) — see `NSG-A.md` Learning Pointers
- **"Fleet-wide NSG hygiene / exposed management-port review"** → `Scripts/Get-NSGRuleAudit.ps1`
- **"I deployed an AVNM connectivity config and nothing happened"** → `AVNM-B.md` Fix 1 — check scope, then check it was actually deployed to the VNet's region (configurations are inert until deployed)
- **"New VNet isn't picking up our dynamic network group policy"** → `AVNM-B.md` Fix 2 — Azure Policy evaluation lag (~30 min, up to 24h at scale), not necessarily a bug
- **"I can't find the peering for our AVNM mesh connection"** → `AVNM-B.md` Triage — mesh is realized as a connected group, never a peering resource; check effective connectivity config or effective routes instead
- **"A previously-working AVNM connection broke after an unrelated change"** → `AVNM-A.md` Playbook 2 — goal-state redeploy trap, the unrelated deploy likely omitted this configuration
- **"Hub-and-spoke peering is one-sided (hub→spoke exists, spoke→hub doesn't)"** → `AVNM-B.md` Fix 4 — hub gateway didn't exist yet when "use hub as gateway" was deployed
- **"Fleet-wide AVNM configuration health check across clients"** → `Scripts/Get-AVNMConfigAudit.ps1`
- **"Our Virtual WAN hub shows healthy but I can't update routes"** → `VirtualWAN-B.md` Fix 1 — `ProvisioningState`/`RoutingState` are independent; use "Reset router," not a full hub reset
- **"Client wants ExpressRoute/P2S/Firewall/Routing Intent but the portal won't let them"** → `VirtualWAN-B.md` Fix 3 — Virtual WAN is on the `Basic` SKU; plan a one-way upgrade to Standard
- **"Our Virtual WAN static route disappeared after we set up the firewall"** → `VirtualWAN-B.md` Fix 4 — enabling Routing Intent silently took over the Default route table and connection associations
- **"Traffic isn't going through our Azure Firewall in Virtual WAN"** → `VirtualWAN-B.md` Triage — confirm the spoke's Hub VNet connection is associated to the route table Routing Intent manages
- **"Some on-prem routes aren't reaching the other gateway type in the same hub"** → `VirtualWAN-B.md` Fix 6 — both VPN and ExpressRoute gateways share a fixed ASN 65515; check for an on-prem ASN collision
- **"Should we move this client from traditional hub-and-spoke to Virtual WAN?"** → `VirtualWAN-A.md` Learning Pointers — a genuine trade-off conversation, not a strict upgrade; Virtual WAN earns its overhead mainly at 30+ spokes or 3+ regions
- **"Fleet-wide Virtual WAN health check across clients"** → `Scripts/Get-VirtualWANHealth.ps1`

---

## Key diagnostic commands

```powershell
# VPN Gateway type, SKU, BGP capability — always check first
Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName> | Select GatewayType, VpnType, Sku, EnableBgp

# VPN tunnel (connection) status — confirm before troubleshooting BGP
Get-AzVirtualNetworkGatewayConnection -ResourceGroupName <rg> -Name <connectionName> | Select ConnectionStatus

# VPN BGP peer state and route counts
Get-AzVirtualNetworkGatewayBgpPeerStatus -ResourceGroupName <rg> -VirtualNetworkGatewayName <gatewayName>

# ExpressRoute circuit + provider provisioning state
Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName> | Select CircuitProvisioningState, ServiceProviderProvisioningState

# ExpressRoute MSEE route table (eBGP peering state lives here)
Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName <circuitName> -PeeringType AzurePrivatePeering -ResourceGroupName <rg>

# Effective NSG rules for a NIC — the pre-merged, authoritative view
az network nic list-effective-nsg --resource-group <rg> --name <nicName> -o table

# Synthetic packet test — allowed or denied, and by which rule
az network watcher test-ip-flow --direction Inbound --protocol TCP --local <ip>:<port> --remote <ip>:* --vm <vmResourceId> --nic <nicName>

# Security Admin Rules (Azure Virtual Network Manager) — invisible from the NSG blade
Get-AzNetworkManager | Get-AzNetworkManagerSecurityAdminConfiguration

# AVNM — the authoritative "what's actually applied" view for a VNet (check this before anything else)
Get-AzNetworkManagerEffectiveConnectivityConfiguration -VirtualNetworkName <vnetName> -VirtualNetworkResourceGroupName <vnetRg>

# AVNM — per-region deployment status and failure detail (configurations do nothing until deployed)
Get-AzNetworkManagerDeploymentStatus -ResourceGroupName <nmRg> -NetworkManagerName <nm> -DeploymentType @("Connectivity")

# Virtual WAN — SKU (Basic vs Standard) — check first for any capability question
Get-AzVirtualWan -ResourceGroupName <rg> -Name <vwanName> | Select VirtualWANType

# Virtual WAN — hub + router health (two independent signals)
Get-AzVirtualHub -ResourceGroupName <rg> -Name <hubName> | Select ProvisioningState, RoutingState, VirtualRouterAsn

# Virtual WAN — Routing Intent policies and Next Hop for a hub
Get-AzRoutingIntent -ResourceGroupName <rg> -ParentResourceId (Get-AzVirtualHub -ResourceGroupName <rg> -Name <hubName>).Id

# Virtual WAN — spoke connection status and routing configuration (association/propagation)
Get-AzVirtualHubVnetConnection -ResourceGroupName <rg> -ParentResourceName <hubName> -Name <connectionName>
```

---

## Key dependency chain

```
VPN Gateway path                          ExpressRoute path
─────────────────                          ─────────────────
On-prem VPN device                         Customer CE router
    │                                          │
IPsec/IKE tunnel (PSK/cert)                Provider network (PE / PE-MSEE)
    │  ← must be Connected first               │  ← ServiceProviderProvisioningState
    ▼                                          ▼
BGP session (ASN/peer-IP/timers)           Microsoft network (MSEE)
    │  ← rides ON TOP of the tunnel            │  ← CircuitProvisioningState
    ▼                                          ▼
Learned + advertised routes                eBGP peering (VLAN/ASN/subnet/MD5)
    │                                          │
    ▼                                          ▼
GatewaySubnet + destination NSG/UDR   ←──  Virtual Network Gateway (ExpressRoute SKU)
    │                                          │
    ▼                                          ▼
              Traffic flows (both paths converge here)


NSG evaluation (NSG-A.md/NSG-B.md — the data-plane layer both paths above converge on):

Security Admin Rules (AVNM)  ← evaluated first, invisible from the NSG resource itself
    │  AlwaysAllow/Deny terminate here; Allow passes through
    ▼
Subnet-level NSG  ──AND──  NIC-level NSG   (order is direction-dependent: subnet-first inbound, NIC-first outbound)
    │  both must independently allow — first rule match per NSG wins, evaluation stops
    ▼
Default rules (65000/65001/65500) — cannot be deleted, only overridden by a lower-priority custom rule
    │
    ▼
Packet delivered (or dropped)
```

AVNM's own layer, which *provisions* the connectivity NSGs then filter (AVNM-A.md/AVNM-B.md):

```
Network Manager scope (management group/subscription) — hard ceiling, out-of-scope VNets get nothing
    │
    ▼
Network Group membership — static (immediate) or dynamic (Azure Policy, ~30min-24h lag)
    │
    ▼
Configuration object (connectivity/security admin/routing) — inert until deployed
    │
    ▼
Deployment (per-region commit, GOAL-STATE: exclusive per region, not additive across deploy actions)
    │
    ▼
Mesh → Connected Group (never a peering) | Hub-and-spoke → real peering | VWAN hub (preview) → VWAN connection
    │
    ▼
Effective state (Get-AzNetworkManagerEffectiveConnectivityConfiguration — the only authoritative view)
```

---

## Response format reminder (always 3 layers)

1. **Immediate action** — classify VPN vs. ExpressRoute, confirm transport layer (tunnel/circuit) before routing layer (BGP) (Mode B)
2. **Root cause** — which of the six dependency-stack layers actually failed, and which organization owns the fix (Mode A)
3. **Prevention** — diagnostic logging enabled, prefix-count monitoring, and confirming provider/Microsoft escalation contacts are documented before the next incident
