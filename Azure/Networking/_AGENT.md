# Azure Networking (Hybrid Connectivity + NSG) — Agent Instructions

## What's in this folder

Runbooks and scripts for **Azure networking**, covering two related but distinct topics. **Hybrid connectivity** — the VPN Gateway (site-to-site IPsec/BGP) and ExpressRoute (private circuit) paths that connect on-premises client networks to Azure: IPsec tunnel establishment, BGP peering and route propagation on both paths, ExpressRoute's three-zone (customer/provider/Microsoft) provisioning model, and the NSG/UDR data-plane checks that come after control-plane health is confirmed. **Network Security Groups (NSG)** — the general-purpose filtering layer itself: rule priority/evaluation order, the dual subnet-level+NIC-level enforcement model, service tags, Application Security Groups, augmented rules, and Security Admin Rules via Azure Virtual Network Manager. NSG is the shared data-plane checkpoint that HybridConnectivity, `Azure/AVD/AVD-Connectivity-A.md`, and `Azure/Windows365/Windows365-A.md` all converge on — this folder is where its mechanics are fully documented once rather than repeated in each of those files.

Does not cover point-to-site VPN (individual remote-access users), Virtual WAN hub routing, Azure Firewall/NVA routing policy beyond where it intersects GatewaySubnet behavior, or User-Defined Routes/route tables as a standalone routing topic (referenced here only where it intersects NSG troubleshooting).

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

---

## Response format reminder (always 3 layers)

1. **Immediate action** — classify VPN vs. ExpressRoute, confirm transport layer (tunnel/circuit) before routing layer (BGP) (Mode B)
2. **Root cause** — which of the six dependency-stack layers actually failed, and which organization owns the fix (Mode A)
3. **Prevention** — diagnostic logging enabled, prefix-count monitoring, and confirming provider/Microsoft escalation contacts are documented before the next incident
