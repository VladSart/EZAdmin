# Azure Load Balancer — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

Run these first. Results tell you which fix path to take.

```powershell
# 1. SKU and provisioning state — Basic SKU is retired (Sept 30, 2025), unsupported, no SLA
Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName> | Select-Object Sku, ProvisioningState

# 2. Backend pool health — the single most useful first check for any "can't reach the app" ticket
Get-AzLoadBalancerBackendHealth -ResourceGroupName <rg> -Name <lbName>

# 3. Is this actually an outbound (internet access) complaint, not an inbound one?
#    Standard SKU gives backend VMs NO outbound path by default — check all three possible methods
(Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>).OutboundRules
(Get-AzVirtualNetworkSubnetConfig -ResourceId <subnetId>).NatGateway
(Get-AzNetworkInterface -ResourceGroupName <rg> -Name <nicName>).IpConfigurations.PublicIpAddress

# 4. Is an NSG actually allowing the traffic? Standard SKU has NO implicit inbound allow.
Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName> | Get-AzNetworkSecurityRuleConfig

# 5. Is the reported symptom actually Layer 7 (path/host/WAF) rather than this Layer 4 resource?
#    If so, stop here — redirect to AppGateway-B.md instead.
```

| If | Then |
|----|------|
| `Sku` shows `Basic` | Unsupported, no SLA — flag for migration, don't troubleshoot as if it were Standard → **Fix 1** |
| Backend pool VMs can't reach the internet | No outbound method configured — Standard SKU gives no implicit outbound path → **Fix 2** |
| Outbound worked, now fails intermittently under load | SNAT port exhaustion, usually on a large backend pool with default allocation → **Fix 3** |
| Inbound traffic to the public frontend times out, no NSG deny logged | Standard SKU secure-by-default — NSG must explicitly allow, nothing is implicit → **Fix 4** |
| Health probe shows all instances Unhealthy but the app works when hit directly | Probe hitting a WinHTTP-restricted port, or wrong protocol/path → **Fix 5** |
| Client describes path-based routing, a WAF block, or hostname rules on "the load balancer" | This is Application Gateway (Layer 7), not this resource → **Fix 6** (redirect) |
| HA Ports rule won't create, or coexistence with other rules fails | Floating IP mode mismatch for the intended topology → **Fix 7** |
| A single long-lived session always lands on the same backend instance | Expected 5-tuple hash behavior — not a fault → **Fix 8** (confirm by-design) |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Frontend IP configuration (public or private — decides LB type; zone setting fixed at creation)
        │
NSG explicitly allows the intended traffic
   (Standard SKU = secure-by-default, NO implicit inbound permit — unlike retired Basic SKU)
        │
Backend pool populated with real, reachable instances (single VNet scope; no Private Endpoints)
        │
Health probe (TCP/HTTP/HTTPS) passing — governs NEW flows only, does NOT reset already-established
   TCP connections when it fails; ALL-instances-unhealthy DOES terminate every UDP flow immediately
        │
Load-balancing rule OR Inbound NAT rule maps frontend IP:port → backend
        │
[Public LB backend needing outbound Internet] ONE of exactly three explicit methods present:
   Load Balancer outbound rule | NAT Gateway on the subnet | instance-level public IP
   — Standard SKU has ZERO implicit outbound path; this is the #1 post-migration ticket source
        │
[Internal LB + HA Ports for NVA scale-out] Floating IP mode deliberately chosen
   (non-floating = exclusive single rule; floating/DSR = multi-frontend + public-LB combinable)
        │
Traffic flows to/from backend instance
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm SKU first — this changes everything about what's possible:**
```powershell
Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName> | Select-Object Sku, ProvisioningState
```
`Basic` → unsupported since September 30, 2025, no SLA, cannot be recreated if deleted. Flag for migration (Fix 1) rather than deep-troubleshooting.

**2. Split the problem: inbound or outbound?**
- Inbound (clients can't reach the app through the frontend) → go to step 3.
- Outbound (backend VMs can't reach the internet) → go to step 4 directly, this is almost always Fix 2.

**3. Inbound — check backend health, then NSG:**
```powershell
Get-AzLoadBalancerBackendHealth -ResourceGroupName <rg> -Name <lbName>
```
Unhealthy on all instances with the app otherwise reachable directly → check probe port against the WinHTTP restricted list (19/21/25/70/110/119/143/220/993) — Fix 5.
Healthy backends but still unreachable from outside → check NSG next:
```powershell
Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName> | Get-AzNetworkSecurityRuleConfig
```
No explicit allow for the frontend port → Fix 4. This is not a bug; Standard SKU never had an implicit allow.

**4. Outbound — confirm which of the three methods is present (if any):**
```powershell
(Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>).OutboundRules
(Get-AzVirtualNetworkSubnetConfig -ResourceId <subnetId>).NatGateway
(Get-AzNetworkInterface -ResourceGroupName <rg> -Name <nicName>).IpConfigurations.PublicIpAddress
```
All three empty → Fix 2, this is the root cause, not a symptom needing further investigation.
An outbound rule exists but failures are intermittent under load → Fix 3 (SNAT exhaustion), check `AllocatedOutboundPorts` against backend pool size.

**5. Confirm this is actually a Layer 4 issue, not Layer 7 misattributed to "the load balancer":**
If the report mentions specific URL paths, hostnames, a WAF block, or TLS certificate errors at the application layer — this resource has none of that awareness. Redirect to `AppGateway-B.md` (Fix 6) before spending more time here.

**6. HA Ports-specific (internal LB, NVA scenarios only):**
```powershell
(Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>).LoadBalancingRules | Where-Object BackendPort -eq 0
```
Confirm this is on an internal LB (HA Ports is never valid on a public one) and that Floating IP mode matches the topology (Fix 7).

---

## Common Fix Paths

<details><summary>Fix 1 — Client is running an unsupported Basic SKU Load Balancer</summary>

**Symptom:** `Sku.Name` returns `Basic`. Retired September 30, 2025 — no SLA, cannot be recreated if deleted, and increasingly likely to hit edge cases as Azure's platform evolves around it.

```powershell
# Inventory current config before scheduling a migration window
$basicLb = Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>
$basicLb.FrontendIpConfigurations | Select-Object Name, PrivateIpAddress, PublicIpAddress
$basicLb.LoadBalancingRules | Select-Object Name, FrontendPort, BackendPort, Protocol
$basicLb.Probes | Select-Object Name, Protocol, Port, RequestPath
```

This is not an emergency fix — it's a migration to schedule using Microsoft's automated PowerShell migration script (`Upgrade-Basic-Standard-with-PowerShell`, see `LoadBalancer-A.md` Playbook 1), not a same-ticket change. Note it in the ticket as a required follow-up.

**Rollback:** N/A — inventory only, no change made.

</details>

<details><summary>Fix 2 — Backend VMs can't reach the internet (no outbound path)</summary>

**Symptom:** Public Standard Load Balancer backend pool members have no outbound Internet access; this is expected, not a bug, unless one of three methods is explicitly configured.

```powershell
# Fastest production-safe fix: attach a NAT Gateway to the backend subnet (current MS recommendation)
$natGwPip = New-AzPublicIpAddress -ResourceGroupName <rg> -Name "natgw-pip" -Location <location> -Sku Standard -AllocationMethod Static
$natGw = New-AzNatGateway -ResourceGroupName <rg> -Name "natgw" -Location <location> -Sku Standard -PublicIpAddress $natGwPip -IdleTimeoutInMinutes 10
$vnet = Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnetName>
$subnet = $vnet.Subnets | Where-Object Name -eq <subnetName>
$subnet.NatGateway = $natGw
Set-AzVirtualNetwork -VirtualNetwork $vnet
```

**Alternative — Load Balancer outbound rule (use manual port allocation, not default):**
```powershell
$lb = Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>
$feConfig = $lb.FrontendIpConfigurations | Where-Object Name -eq <frontendName>
$bePool = $lb.BackendAddressPools | Where-Object Name -eq <poolName>
Add-AzLoadBalancerOutboundRuleConfig -LoadBalancer $lb -Name "OutboundRule1" `
    -FrontendIpConfiguration $feConfig -BackendAddressPool $bePool `
    -Protocol All -AllocatedOutboundPort 1024 -IdleTimeoutInMinutes 4
$lb | Set-AzLoadBalancer
```

**Rollback:** Remove the NAT Gateway subnet association or delete the outbound rule; existing connections drain per idle timeout, no forced disconnect.

</details>

<details><summary>Fix 3 — Intermittent outbound failures under load (SNAT exhaustion)</summary>

**Symptom:** Outbound worked when the backend pool was small; now, under higher concurrent connection volume, connections fail intermittently. Usually correlates with backend pool growth.

```powershell
# Check current allocation — default allocation shrinks per-instance ports as the pool grows
(Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>).OutboundRules | Select-Object Name, AllocatedOutboundPorts

# Move to manual allocation with a larger explicit budget per instance
$lb = Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>
$rule = $lb.OutboundRules | Where-Object Name -eq <ruleName>
$rule.AllocatedOutboundPorts = 4096
$lb | Set-AzLoadBalancer
```

**Better long-term fix — move outbound to NAT Gateway**, which allocates SNAT ports independently of the load balancer's own port budget and is Microsoft's stated recommendation for production outbound-heavy workloads (see Fix 2 for the NAT Gateway commands).

**Rollback:** Reduce `AllocatedOutboundPorts` back down if over-allocation starves other rules sharing the same frontend IP; removing the NAT Gateway reverts to whatever outbound method was previously in place.

</details>

<details><summary>Fix 4 — Inbound traffic blocked, no explicit deny logged</summary>

**Symptom:** Clients time out reaching the public frontend; backend health shows Healthy; nothing obviously wrong with the load balancer configuration itself.

```powershell
# Standard SKU public IPs are secure-by-default — confirm an explicit allow actually exists
Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName> | Get-AzNetworkSecurityRuleConfig |
    Where-Object { $_.DestinationPortRange -contains "<frontendPort>" -and $_.Access -eq "Allow" }

# Add the missing rule if absent
Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "Allow-LB-Frontend" `
    -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 `
    -SourceAddressPrefix Internet -SourcePortRange * `
    -DestinationAddressPrefix * -DestinationPortRange <frontendPort>
$nsg | Set-AzNetworkSecurityGroup
```

**Rollback:** Remove the added rule if it turns out traffic should have been denied — always confirm the source scope (`Internet` vs. a narrower prefix) matches the actual security intent before leaving this in place.

</details>

<details><summary>Fix 5 — Health probe shows all instances Unhealthy, app works when hit directly</summary>

**Symptom:** `Get-AzLoadBalancerBackendHealth` reports every instance Down, but manually connecting to a backend instance on the expected port works fine.

```powershell
# Check probe port against the WinHTTP restricted-port list: 19, 21, 25, 70, 110, 119, 143, 220, 993
(Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>).Probes | Select-Object Name, Protocol, Port, RequestPath

# If the port is on the restricted list, move the probe to a different port/endpoint
$lb = Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>
$probe = $lb.Probes | Where-Object Name -eq <probeName>
$probe.Port = 8080
$lb | Set-AzLoadBalancer
```

If the port isn't restricted, confirm `RequestPath` (HTTP/HTTPS probes) and `Protocol` actually match what the backend serves on that port — a TCP probe against an HTTPS-only listener, or an HTTP probe path that 404s, both read as Unhealthy even though the service is otherwise up.

**Rollback:** Revert probe port/path to the prior value if this wasn't the actual cause.

</details>

<details><summary>Fix 6 — Symptom is actually Layer 7 (redirect to Application Gateway)</summary>

**Symptom:** Client describes path-based routing behavior, a WAF-branded 403, TLS certificate handling, or hostname-specific rules on "the load balancer" — none of which this resource can do.

Azure Load Balancer operates purely at Layer 4 (TCP/UDP, 5-tuple hash). It has no concept of URL paths, HTTP headers, hostnames, or WAF rules. Confirm which resource is actually fronting the traffic:

```powershell
# If a public IP resolves to an Application Gateway rather than this Load Balancer, that's your answer
Get-AzPublicIpAddress -ResourceGroupName <rg> | Select-Object Name, IpAddress, IpConfiguration
```

Redirect the ticket to `AppGateway-B.md` if confirmed.

**Rollback:** N/A — diagnostic redirect only.

</details>

<details><summary>Fix 7 — HA Ports rule creation fails or coexistence with other rules breaks</summary>

**Symptom:** Adding an HA Ports rule fails, or an existing HA Ports setup stops behaving as expected after another rule was added.

```powershell
# Confirm this is on an INTERNAL load balancer — HA Ports is never valid on a public one
(Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>).FrontendIpConfigurations | Select-Object Name, PrivateIpAddress, PublicIpAddress
```

- **Non-floating IP (Floating IP disabled):** must be the ONLY rule on that load balancer resource for that backend — no other load-balancing rule, no other internal LB resource, can coexist for the same backend instances. If another rule was added, that's the conflict.
- **Floating IP (DSR) enabled:** required if you need multiple HA Ports frontends or coexistence with a public load balancer on the same backend — but requires the backend NVA software to support DSR.

**Rollback:** Remove the conflicting rule, or switch Floating IP mode to match the intended topology (requires recreating the rule — Floating IP can't be toggled on an existing rule).

</details>

<details><summary>Fix 8 — Confirm 5-tuple hash session pinning is by design, not a fault</summary>

**Symptom:** A client reports "sticky sessions are broken" or "the same user always hits the same backend" as if it were a defect.

```powershell
# This is expected: distribution is per-FLOW (5-tuple: src IP, src port, dst IP, dst port, protocol),
# not per-client and not round-robin. A single long-lived TCP connection stays on one backend for its
# lifetime by design; a new connection may hash to a different backend.
```

If genuine client-IP-based session affinity is required, that's an Application Gateway (cookie-based affinity) or application-layer concern — not something this Layer 4 resource provides or is expected to provide.

**Rollback:** N/A — confirmation only, no configuration change needed.

</details>

---

## Escalation Evidence

```
=== Azure Load Balancer Failure — Ticket Evidence ===

Date/Time:                       _______________
Load Balancer name / RG:         _______________
SKU (flag if Basic):             _______________
Public or Internal:              _______________
Reported symptom:                _______________  (inbound / outbound / HA Ports / L7-misattributed)

--- Commands Run ---
ProvisioningState:                    _______________
Backend health (per instance):        _______________
Outbound method present (Y/N, which): _______________
NSG explicit allow present (Y/N):     _______________
Probe protocol/port/path:             _______________
Probe port on WinHTTP restricted list (Y/N): _______________

--- Steps Taken ---
[ ] Confirmed SKU (flagged if Basic)
[ ] Split inbound vs. outbound
[ ] Checked backend health per instance
[ ] Checked outbound method (LB outbound rule / NAT Gateway / instance-level public IP)
[ ] Checked NSG explicit allow
[ ] Checked probe port against WinHTTP restricted list
[ ] Confirmed not actually a Layer 7 (Application Gateway) issue
```

---

## 🎓 Learning Pointers

- **The #1 real-world ticket after any Basic-to-Standard migration is "our VMs can't reach the internet."** Standard SKU gives backend pool members zero implicit outbound path — Basic did, silently. Check for a Load Balancer outbound rule, a NAT Gateway on the subnet, or an instance-level public IP before investigating anything else on an outbound complaint. [MS Docs: SNAT for outbound connections](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-outbound-connections)

- **Default SNAT port allocation gets worse, not better, as the backend pool grows** — it's calculated per instance up to a 1,024-port ceiling per frontend IP. A large, busy backend pool is exactly the scenario most likely to hit exhaustion under default allocation. Move to manual allocation or NAT Gateway for production, per Microsoft's own explicit recommendation. [MS Docs: Load Balancer best practices](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-best-practices)

- **A failed health probe blocks new flows only — it does not reset existing TCP connections.** A backend instance can keep serving live traffic for a while after going Unhealthy, and that's by design, not a bug. UDP is the one exception: if the entire pool fails simultaneously, all UDP flows terminate immediately with no grace period.

- **Basic SKU Load Balancer was fully retired September 30, 2025** — any instance still found in a client environment is unsupported and carries no SLA. It's a scheduled migration, not an urgent same-ticket fix, but it should be logged and flagged the moment it's discovered.

- **"The load balancer" is one of the most overloaded phrases in an MSP ticket** — confirm whether the client actually means this Layer 4 resource or Application Gateway (Layer 7) before troubleshooting. Path-based routing, WAF, TLS termination, and hostname rules all belong to `AppGateway-B.md`, not here.
