# Azure Hybrid Connectivity (VPN Gateway & ExpressRoute) — Hotfix Runbook (Mode B: Ops)
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

First split the ticket into one of two unrelated failure families — VPN Gateway (IPsec/site-to-site) or ExpressRoute (private circuit). They share almost no root causes; treat "on-prem can't reach Azure" tickets as VPN or ExpressRoute from the first command, not both at once.

```powershell
# 0. Which gateway type is this? (run first, always)
Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName> |
    Select-Object GatewayType, VpnType, Sku, EnableBgp

# 1. VPN Gateway — connection (IPsec tunnel) status
Get-AzVirtualNetworkGatewayConnection -ResourceGroupName <rg> -Name <connectionName> |
    Select-Object ConnectionStatus, IngressBytesTransferred, EgressBytesTransferred

# 2. VPN Gateway — BGP peer status (only if EnableBgp = True)
Get-AzVirtualNetworkGatewayBgpPeerStatus -ResourceGroupName <rg> -VirtualNetworkGatewayName <gatewayName>

# 3. ExpressRoute — circuit + provider state
Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName> |
    Select-Object CircuitProvisioningState, ServiceProviderProvisioningState

# 4. ExpressRoute — private peering BGP session (both MSEE paths)
Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName <circuitName> -PeeringType AzurePrivatePeering -ResourceGroupName <rg>
```

| Command result | Interpretation | Do this |
|---|---|---|
| `ConnectionStatus: Connected` | IPsec tunnel is up | If traffic still fails, it's routing/NSG/BGP-route, not the tunnel — go to Fix 4 or Fix 5 |
| `ConnectionStatus: NotConnected` and 0 bytes either direction | Tunnel never established — IKE/PSK/peer-IP mismatch | Fix 1 |
| BGP peer `State: Connected` but `RoutesReceived: 0` | Tunnel + BGP session fine, on-prem isn't advertising | Fix 2 |
| BGP peer flapping (Connected → Disconnected repeatedly) | Hold-timer expiry from packet loss, or IPsec tunnel itself unstable | Fix 3 |
| `CircuitProvisioningState: Enabled`, `ServiceProviderProvisioningState: Not Provisioned` | Microsoft side is ready; provider hasn't turned up their side | Escalate to circuit provider — Azure engineer cannot fix this |
| eBGP peering state `Active` or `Idle` on the MSEE route table | ASN/VLAN/subnet/MD5 key mismatch between MSEE and CE/PE-MSEE | Fix 4 |
| Circuit/peering all healthy but specific prefixes unreachable | NSG, UDR, or firewall blocking a route that IS present | Fix 5 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
VPN Gateway (site-to-site) path
─────────────────────────────────
On-prem VPN device (validated device/OS, correct public IP)
    │
    ├── Shared key (PSK) matches on both sides
    ├── Peer IP definitions match (Local Network Gateway ↔ on-prem device)
    │
    ▼
IPsec/IKE tunnel (Phase 1 + Phase 2 SAs negotiated)
    │  ← must be Connected before BGP can start
    ▼
BGP session (only if EnableBgp = True; runs ON TOP of the IPsec tunnel)
    │
    ├── ASNs differ on each side (never equal, never Azure-reserved: 8074/8075/12076/65515/65517-65520)
    ├── BGP peer IP ≠ VPN device public IP (loopback/APIPA range 169.254.21.0-169.254.22.255 only)
    ├── Keepalive 60s / Hold timer 180s (fixed on Azure side — no BFD support)
    │
    ▼
Routes learned (on-prem → Azure) + Routes advertised (Azure → on-prem)
    │
    ▼
NSG / UDR on the GatewaySubnet — must NOT block or misroute (this subnet should carry no NSG in most designs)
    │
    ▼
Traffic flows

ExpressRoute path (three independent zones — a failure in one doesn't imply a failure in another)
─────────────────────────────────
Customer network → CE router
    │
Provider network → PE routers (layer 2, or PE-MSEE if IPVPN model)
    │  ← Provider status: "Provisioned" required — Azure engineer CANNOT fix this side
    │
Microsoft network → MSEE routers
    │  ← Circuit status: "Enabled" required — provider CANNOT fix this side
    │
eBGP peering (CE/PE-MSEE ↔ MSEE) — Azure private peering and/or Microsoft peering
    │  ← VlanId, AzureASN, PeerASN, /30 subnets, MD5 key (if used) must match exactly on both ends
    │
Virtual Network Gateway (ExpressRoute SKU — separate resource from VPN gateway)
    │
NSG / UDR / firewall on the connected VNet
    │
Traffic flows
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm gateway type and SKU first.** `Get-AzVirtualNetworkGateway` → BGP is not supported on Basic SKU; policy-based gateways cannot run BGP at all. A "BGP won't connect" ticket on a Basic/policy-based gateway is not a bug — it's an unsupported combination.
   - Good: `Sku.Name` is anything other than `Basic`, `VpnType: RouteBased`.
   - Bad: `Basic` SKU + BGP request, or `VpnType: PolicyBased` + BGP request → redesign, not troubleshoot.

2. **VPN: verify the IPsec tunnel before touching BGP.** BGP peering rides on top of the tunnel; a "BGP down" ticket is often an IPsec ticket in disguise.
   ```powershell
   Get-AzVirtualNetworkGatewayConnection -ResourceGroupName <rg> -Name <connectionName> | Select ConnectionStatus
   ```
   - Good: `Connected`.
   - Bad: `NotConnected` → stop here, work Fix 1, do not investigate BGP yet.

3. **VPN: check the health probe if the tunnel itself won't come up and NSG involvement is suspected.**
   ```
   https://<GatewayPublicIP>:8081/healthprobe
   ```
   - Good: XML response with `GatewayTenantWorker` string.
   - Bad: No response → gateway unhealthy, or an NSG on the GatewaySubnet is blocking it (Basic SKU never replies — expected, not a fault).

4. **VPN: pull learned and advertised routes once BGP is Connected but traffic still fails.**
   ```powershell
   Get-AzVirtualNetworkGatewayLearnedRoute -ResourceGroupName <rg> -VirtualNetworkGatewayName <gatewayName>
   Get-AzVirtualNetworkGatewayAdvertisedRoute -ResourceGroupName <rg> -VirtualNetworkGatewayName <gatewayName> -Peer <onPremBgpPeerIp>
   ```
   - Good: Expected on-prem prefixes appear with `Origin: EBgp`; expected VNet prefixes appear in advertised output.
   - Bad: Zero eBGP routes learned → on-prem device isn't advertising (Fix 2). Missing an exact VNet prefix in advertised routes when gateway transit is enabled → this is by design (see Fix 2 note on duplicate-prefix restriction), not a fault.

5. **ExpressRoute: circuit and provider status before anything else.**
   ```powershell
   Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName> | Select CircuitProvisioningState, ServiceProviderProvisioningState
   ```
   - Good: `Enabled` / `Provisioned`.
   - Bad: Either field stuck in `Not enabled` / `Not provisioned` → this is a Microsoft-side or provider-side ticket respectively; no local PowerShell fix exists. Go straight to Escalation Evidence.

6. **ExpressRoute: BGP peering state on the MSEE.**
   ```powershell
   Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName <circuitName> -PeeringType AzurePrivatePeering -ResourceGroupName <rg>
   ```
   - Good: Routes present with a `Path` (AS path) value.
   - Bad: `Active` or `Idle` peering state → configuration mismatch, work Fix 4. A "peering not found" error means the peering was never configured — confirm with the client which peering type (Private/Microsoft) they actually expect.

---
## Common Fix Paths

<details><summary>Fix 1 — IPsec tunnel won't establish (VPN Gateway)</summary>

**When to use:** `ConnectionStatus: NotConnected`, zero bytes transferred either direction.

```powershell
# Verify shared key matches
Get-AzVirtualNetworkGatewayConnectionSharedKey -Name <connectionName> -ResourceGroupName <rg>

# Verify peer IP definitions
Get-AzLocalNetworkGateway -ResourceGroupName <rg> -Name <localGatewayName> | Select GatewayIpAddress
Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName> | Select IpConfigurations
```

Checklist, in order:
1. On-prem device is on the [validated device list](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-devices#devicetable) and firmware matches Microsoft's sample config version.
2. Shared key is byte-for-byte identical on both ends (re-set it on both sides if unsure — don't assume a visual match is a real match).
3. Local Network Gateway's `GatewayIpAddress` matches the on-prem device's actual public IP, and the on-prem device is configured to peer with Azure's public gateway IP (not the BGP peer IP — that's a Fix 3 mistake, not a Fix 1 mistake).
4. Perfect Forward Secrecy (PFS) is disabled on the on-prem device unless the Azure-side IPsec/IKE policy explicitly matches a PFS group.
5. Reset both ends as a next step if config checks pass clean:
```powershell
Reset-AzVirtualNetworkGateway -ResourceGroupName <rg> -VirtualNetworkGatewayName <gatewayName>
```
Then reset the tunnel from the on-prem device side too — a one-sided reset often just reproduces the same stuck state.

**Rollback:** Gateway reset causes a brief outage on all connections through that gateway (seconds to ~1 minute for active-standby; active-active gateways fail over per-instance). Schedule outside business hours if the tunnel is otherwise stable and this is a preventive reset rather than an active outage.

</details>

<details><summary>Fix 2 — BGP connected but no routes learned (VPN Gateway)</summary>

**When to use:** BGP peer `State: Connected`, `RoutesReceived: 0`.

```powershell
Get-AzVirtualNetworkGatewayLearnedRoute -ResourceGroupName <rg> -VirtualNetworkGatewayName <gatewayName>
```

1. Confirm on the on-prem router that BGP is enabled on the correct interface and network statements include the prefixes meant for Azure.
2. Confirm no outbound route filter on the on-prem device is silently dropping the prefixes before they reach Azure.
3. Check the prefix count — Azure VPN Gateway drops the entire BGP session (not just excess routes) if the on-prem peer advertises **more than 4,000 prefixes**. If the on-prem device summarizes poorly, this is a real failure mode, not a theoretical one.
4. If Azure routes aren't reaching on-prem instead: remember gateway transit blocks advertising a VNet's **exact** prefix — Azure only advertises a superset (e.g. advertise `10.0.0.0/8` if the VNet is `10.0.0.0/16`, not the /16 itself). A missing exact-match prefix in advertised routes is expected behavior, not a bug — don't burn time chasing it.

**Rollback:** N/A — read-only diagnosis, no config change required for this fix path itself.

</details>

<details><summary>Fix 3 — BGP session flapping (VPN Gateway)</summary>

**When to use:** BGP peer state oscillates Connected/Disconnected; users report intermittent hybrid connectivity.

1. Query the diagnostic log for a pattern (requires `RouteDiagnosticLog` enabled beforehand):
```kusto
AzureDiagnostics
| where Category == "RouteDiagnosticLog"
| where OperationName in ("BgpConnectedEvent", "BgpDisconnectedEvent")
| summarize count() by OperationName, bin(TimeGenerated, 1h)
| order by TimeGenerated desc
```
2. If disconnects correlate with a specific time of day, look for scheduled on-prem processes (backup jobs, QoS reconfiguration, ISP maintenance windows) saturating the link.
3. Cross-check `TunnelDiagnosticLog` for IPsec tunnel drops at the same timestamps — BGP flapping is very often just IPsec tunnel flapping wearing a different name. Fix the tunnel stability issue, not the BGP session.
4. Remember the hold timer is fixed at 180 seconds (60s keepalive × 3) with **no BFD support** on VPN Gateway S2S — there is no tunable to make BGP more tolerant of packet loss. If the underlying link genuinely drops >1 in 3 keepalives, that's an ISP/on-prem link-quality problem, not an Azure config problem.

**Rollback:** N/A — diagnostic only.

</details>

<details><summary>Fix 4 — ExpressRoute peering mismatch (Active/Idle BGP state on MSEE)</summary>

**When to use:** eBGP peering state on the MSEE route table shows `Active` or `Idle` instead of `Established`.

```powershell
$ckt = Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName>
Get-AzExpressRouteCircuitPeeringConfig -Name "AzurePrivatePeering" -ExpressRouteCircuit $ckt
```

Verify, matching exactly against the linked CE/PE-MSEE configuration:
1. Primary and secondary `/30` peer address prefixes match on both ends (Microsoft uses the second usable IP on the MSEE side — the CE/PE-MSEE must use the first usable IP).
2. `VlanId`, `AzureASN`, `PeerASN` are identical on both ends.
3. If MD5 hashing is used, the shared key is identical on both ends (Azure never displays a previously configured key — you cannot "check" it, only reset it).

**This is a coordination fix, not a unilateral one** — corrections on the MSEE side require the customer's CE/PE-MSEE config to change in lockstep, or the peering will re-break. Confirm the change window with whoever owns the on-prem/provider router before pushing an Azure-side peering update.

**Rollback:** Revert the peering config via the same cmdlet with prior values; a peering config change does not affect the underlying circuit provisioning state.

</details>

<details><summary>Fix 5 — Routes present but traffic still blocked (either path)</summary>

**When to use:** BGP/peering healthy, expected routes appear in learned/advertised route tables or the MSEE route table, but specific traffic still fails.

1. Check for NSGs or UDRs on the **GatewaySubnet** itself — this subnet should carry no NSG in the large majority of designs; one is a common self-inflicted block.
```powershell
Get-AzVirtualNetworkSubnetConfig -Name GatewaySubnet -VirtualNetwork (Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnetName>)
```
2. Check NSGs/UDRs on the destination subnet/NIC for the specific resource that's unreachable.
3. For ExpressRoute specifically: run the Azure portal's **Diagnose and solve problems → Connectivity & Performance issues → Test private-peering connectivity** tool with PsPing running from both ends. Match patterns:
   - Matches on both MSEEs, both directions → healthy; loss is downstream of the MSEEs (on-prem/provider side).
   - Matches inbound to Azure but not returning → on-prem/provider return-path routing issue.
   - Matches inbound to on-prem but not returning to Azure → work with the circuit provider; Azure engineer cannot fix this.
   - One MSEE shows no matches, the other healthy → one MSEE-facing path is offline; escalate with the service key.

**Rollback:** Any NSG/UDR change made as part of this fix should be documented and reverted if it doesn't resolve the issue — don't leave an experimental rule in a production GatewaySubnet or destination subnet.

</details>

---
## Escalation Evidence

```
=== Hybrid Connectivity Escalation ===
Ticket #:
Client / Tenant:
Path type:            [ ] VPN Gateway (site-to-site)   [ ] ExpressRoute

--- If VPN Gateway ---
Gateway name / RG:
Gateway SKU / VpnType:
Connection name:
ConnectionStatus:                (Connected / NotConnected)
BGP enabled:                     (Y/N)
BGP peer state (if applicable):
Routes learned / advertised count:
Health probe response (Y/N):
Reset attempted (Y/N), result:

--- If ExpressRoute ---
Circuit name / Service Key:
CircuitProvisioningState:
ServiceProviderProvisioningState:
Peering type affected:           (Private / Microsoft)
eBGP peering state (MSEE):
Provider name:
Private-peering connectivity test result:

--- Common ---
When did it last work:
What changed (client-reported):
Diagnostic log query results attached: [ ] Yes  [ ] No
Impact (users/services affected):
Escalation target:               [ ] Microsoft Support   [ ] Circuit Provider   [ ] Internal L3
```

---
## 🎓 Learning Pointers

- **VPN Gateway and ExpressRoute BGP sessions fail for almost entirely different reasons** — VPN Gateway issues are usually IPsec/PSK/ASN config; ExpressRoute issues are usually a three-way coordination problem across customer/provider/Microsoft network zones. Don't reuse VPN Gateway mental models on an ExpressRoute ticket. [Troubleshoot BGP issues for Azure VPN Gateway](https://learn.microsoft.com/en-us/troubleshoot/azure/vpn-gateway/vpn-gateway-troubleshoot-bgp) · [Verify ExpressRoute connectivity](https://learn.microsoft.com/en-us/troubleshoot/azure/expressroute/expressroute-troubleshooting-expressroute-overview)

- **"Circuit status: Enabled" and "Provider status: Provisioned" are two independent switches controlled by two different organizations.** An engineer can spend an hour on the Azure side chasing a problem that's actually sitting with the circuit provider — check both fields in the first 30 seconds of any ExpressRoute ticket.

- **BGP rides on top of IPsec for VPN Gateway — always confirm the tunnel before touching BGP config.** A flapping or dead BGP session on an otherwise-fine-looking config is very often a symptom of tunnel instability, not a BGP-layer problem.

- **VPN Gateway has no BFD support and fixed 60s/180s BGP timers.** If a client's link has real packet loss, no Azure-side timer tuning will fix session flapping — the fix is on the link itself.

- **The 4,000-prefix-per-peer limit on VPN Gateway drops the entire session, not just the excess routes.** A poorly summarized on-prem route table is a legitimate, fixable root cause for "BGP randomly drops."

- **Gateway transit's "no exact prefix match" rule is expected behavior, not a bug** — Azure only advertises superset prefixes when gateway transit is enabled; don't chase a missing exact-match advertised route as if it were a fault.
