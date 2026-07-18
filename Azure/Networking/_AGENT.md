# Azure Networking (Hybrid Connectivity) — Agent Instructions

## What's in this folder

Runbooks and scripts for **Azure hybrid connectivity** — the VPN Gateway (site-to-site IPsec/BGP) and ExpressRoute (private circuit) paths that connect on-premises client networks to Azure. Covers IPsec tunnel establishment, BGP peering and route propagation on both paths, ExpressRoute's three-zone (customer/provider/Microsoft) provisioning model, and the NSG/UDR data-plane checks that come after control-plane health is confirmed. Does not cover point-to-site VPN (individual remote-access users), Virtual WAN hub routing, or Azure Firewall/NVA routing policy beyond where it intersects GatewaySubnet behavior.

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
```

---

## Response format reminder (always 3 layers)

1. **Immediate action** — classify VPN vs. ExpressRoute, confirm transport layer (tunnel/circuit) before routing layer (BGP) (Mode B)
2. **Root cause** — which of the six dependency-stack layers actually failed, and which organization owns the fix (Mode A)
3. **Prevention** — diagnostic logging enabled, prefix-count monitoring, and confirming provider/Microsoft escalation contacts are documented before the next incident
