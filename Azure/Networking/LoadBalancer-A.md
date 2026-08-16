# Azure Load Balancer — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the Layer 4 distribution/outbound model, not just the fix commands.

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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- Standard SKU Load Balancer — public and internal, the only SKU that can still be created
- Layer 4 (TCP/UDP) traffic distribution: frontend IP, backend pool, load-balancing rules, inbound NAT rules
- Health probes (TCP/HTTP/HTTPS) and their effect on existing vs. new flows
- Outbound connectivity: SNAT behavior, outbound rules, and the three supported outbound-access methods
- High Availability (HA) Ports for NVA/firewall scale-out scenarios
- Availability-zone frontend models (zone-redundant, zonal, non-zonal)

**Out of scope:**
- **Basic SKU Load Balancer** — retired September 30, 2025. Cannot be newly created; existing instances remain operational but are explicitly unsupported and carry no SLA. Any Basic Load Balancer found in a client environment today is a migration finding, not a troubleshooting target — see Playbook 1.
- **Azure Application Gateway** — a Layer 7 HTTP/HTTPS reverse proxy with WAF, covered in `AppGateway-A.md`/`AppGateway-B.md`. See the disambiguation in Learning Pointers; this is the single most common confusion an MSP engineer hits when a client says "the load balancer."
- **Azure Front Door / Traffic Manager** — global-edge (Front Door) and DNS-based (Traffic Manager) distribution services, architecturally unrelated to this regional, VNet-scoped resource.
- **Gateway Load Balancer** — a distinct SKU/resource type for transparently chaining third-party NVAs into traffic paths via VXLAN encapsulation; referenced only where HA Ports' flow-symmetry limitation points to it as the alternative.
- **NAT Gateway internals** — covered only as one of the three outbound-access methods this topic must choose between; NAT Gateway's own configuration and troubleshooting is a separate future topic if ticket volume justifies it.

**Assumptions:**
- Standard SKU (public or internal)
- Reader has Network Contributor or higher on the resource group
- At least one backend pool with real, reachable members

---

## How It Works

<details><summary>Full architecture</summary>

### Public vs. Internal — Determined Entirely by the Frontend IP Type

A Load Balancer's frontend IP configuration decides everything about its role. A **public IP** frontend makes it a public load balancer (maps a public IP:port to a private IP:port on the backend, and the reverse for return traffic). A **private IP** frontend makes it an internal load balancer (distributes traffic to VNet-internal resources only; Azure guarantees an internal load balancer's frontend is never directly reachable from the internet — there is no "make it public later" toggle, a new frontend IP configuration is required to change this). Both frontend types are Standard SKU only since Basic's retirement.

### The Five Components

```
Frontend IP configuration (public or private — determines LB type)
        │
Backend pool (VMs / VMSS instances, added by NIC or by IP; single VNet scope only)
        │
Health probe (TCP / HTTP / HTTPS — determines which pool members receive NEW flows)
        │
Load-balancing rule (frontend IP:port → backend pool:port, inbound traffic only)
        │
   ├── Inbound NAT rule  — frontend IP:port → ONE specific backend instance (port forwarding, e.g. per-VM RDP/SSH)
   └── Outbound rule     — backend pool → SNAT'd outbound Internet access (public LB only)
```

Load-balancing rules and inbound NAT rules both use the same underlying hash-based distribution; the difference is cardinality — a load-balancing rule fans out to every healthy member of a backend pool, an inbound NAT rule targets exactly one member.

### Distribution Mode: 5-Tuple Hash, Not Round-Robin

Azure Load Balancer does not round-robin requests. Every new flow is assigned to a backend instance based on a hash of the **5-tuple**: source IP, source port, destination IP, destination port, protocol. Because the hash includes source port, a single client opening many short-lived connections is distributed across the backend pool — but a single **long-lived** connection (a persistent TCP session) stays pinned to one backend instance for its lifetime by design. This is not session affinity/stickiness in the Application Gateway sense; it's a side effect of the hash inputs staying constant for the life of one flow, and it resets to a potentially different backend the moment the client opens a new TCP connection.

### Health Probes and What Happens to Existing Flows When One Fails

A probe (TCP, HTTP, or HTTPS — HTTPS probes are Standard SKU only) is evaluated per backend instance on an interval, with a configurable unhealthy threshold. A failed probe removes that instance from consideration for **new** flows only:

- **Existing TCP connections continue** until the application ends the flow, the connection idle-times out, or the VM itself shuts down — a probe going Unhealthy does not forcibly reset in-flight TCP sessions.
- **UDP flows behave differently by design**: if one instance goes unhealthy, its UDP flows are moved to a remaining healthy instance. If **every** instance in the pool goes unhealthy simultaneously, all existing UDP flows terminate outright — there's no "wait for recovery" grace period for UDP the way there implicitly is for TCP.

**HTTP probes have a documented restricted-port list** — 19, 21, 25, 70, 110, 119, 143, 220, and 993 are blocked by the underlying WinHTTP stack the probe engine uses, regardless of what the backend is actually listening on. A probe configured against one of these ports fails outright with no useful diagnostic beyond "probe down" — this is a probe-port choice problem, not a backend health problem, and is easy to lose an hour to if the restricted-port list isn't already known.

### Outbound Connectivity — The Single Biggest Post-Migration Surprise

This is architecturally the most consequential difference between Basic and Standard SKU, and the fact every "we upgraded and now our VMs can't reach the internet" ticket traces back to:

**Basic Load Balancer implicitly allowed outbound Internet access** for backend pool members with no configuration required. **Standard Load Balancer does not.** A backend pool sitting behind a Standard public load balancer has **no outbound Internet path by default** unless one of exactly three methods is explicitly configured:

1. **Outbound rules on the Load Balancer itself** — SNAT via the load balancer's own public frontend IP(s).
2. **NAT Gateway** attached to the backend members' subnet — Microsoft's own current recommendation for production outbound, because it scales SNAT port allocation independently of the load balancer and doesn't compete with inbound frontend configuration.
3. **Instance-level public IP** directly on each backend VM's NIC — bypasses the load balancer's outbound path entirely, uncommon outside specific per-instance requirements.

These three methods are **mutually exclusive in effect on a given NIC's outbound path** in the sense that whichever is present takes precedence in Azure's own documented SNAT selection order (instance-level public IP wins over NAT Gateway, which wins over Load Balancer outbound rules) — mixing them without understanding this precedence is a common source of "I added an outbound rule and outbound still doesn't work as expected" tickets, when in fact a different mechanism was already silently governing the path.

### SNAT Port Allocation — Default vs. Manual

When using Load Balancer outbound rules, each public frontend IP contributes up to **64,000 ephemeral ports** for SNAT, and the load balancer must allocate a slice of that pool to each backend instance. **Default port allocation is deliberately conservative and shrinks as the backend pool grows** — allocation is calculated per the number of backend instances, up to a documented maximum of 1,024 ports per instance per frontend IP, meaning a large backend pool can end up with a surprisingly small per-instance SNAT budget under default allocation. This is Microsoft's own explicitly documented reason default allocation is **not recommended for production workloads**: outbound-heavy applications (many concurrent short-lived outbound connections — think web scraping, external API fan-out, or SMTP relay) exhaust their allocated ports and see intermittent, hard-to-reproduce outbound connection failures that look like nothing is wrong with the load balancer itself. **Manual port allocation** (explicitly setting `AllocatedOutboundPorts` on the outbound rule) or moving outbound entirely to **NAT Gateway** are the two documented mitigations; NAT Gateway is Microsoft's current stated recommendation over tuning manual allocation for anything beyond a small, predictable backend pool.

### High Availability (HA) Ports

An HA Ports rule is a load-balancing rule with **protocol = All** and **port = 0**, available only on an **internal** Standard Load Balancer (never a public one). It load-balances every TCP and UDP flow arriving on every port in a single rule, using the same 5-tuple hash as a normal rule, and — uniquely among LB rule types — also carries ICMP traffic once enabled. This exists specifically for **NVA (Network Virtual Appliance) high-availability scenarios** (firewalls, VPN concentrators, SD-WAN appliances) where defining one rule per port is impractical, and for genuinely large port-range load-balancing needs outside the NVA use case.

HA Ports has two supported configuration shapes, and they are not interchangeable:

- **Non-floating IP (Floating IP / Direct Server Return disabled)** — the simple case. This is the *only* rule allowed on that load balancer resource for that backend — no other load-balancing rule, and no other internal load balancer resource, can coexist with it for the same backend instances. A public Standard Load Balancer CAN still sit alongside it for the same backend, though.
- **Floating IP (DSR) enabled** — allows multiple HA Ports frontends (multiple private frontend IPs, each its own HA Ports rule) plus combination with a public load balancer, at the cost of requiring the backend NVA software to understand DSR (the backend responds using the original destination IP directly rather than the load balancer's rewritten one).

**Flow symmetry** (ensuring return traffic from an NVA takes the same path egress as ingress) is only guaranteed in specific single-internal-LB topologies (hub-and-spoke force-tunnel through one internal LB with HA Ports). It is explicitly **not guaranteed** across two different load balancers or multiple frontend configurations — a public-LB-in-front-of-an-NVA-behind-an-internal-LB topology needing symmetric flows should use **Gateway Load Balancer** instead, which is purpose-built for transparent NVA insertion via VXLAN and isn't subject to this limitation.

### Availability Zones

A Standard Load Balancer's zone behavior is entirely a property of its **frontend IP configuration**, decided at creation and not modifiable afterward (changing zone behavior requires creating a new frontend IP configuration and re-pointing rules to it — there's no in-place conversion):

- **Zone-redundant** (Microsoft's blanket recommendation, including for single-zone workloads) — one IP address, served by infrastructure present in every zone in the region simultaneously; the data plane survives the loss of any single zone as long as one zone in the region remains healthy.
- **Zonal** — the frontend is pinned to one specific zone's infrastructure; simpler but a single-zone dependency for the load balancer itself.
- **Non-zonal** — no zone guarantee, generally only seen on older resources or specific regional constraints.

Zone redundancy of the load balancer is entirely independent of the **backend pool's** zone distribution — a zone-redundant frontend does not make a single-zone backend pool resilient to a zone outage. If every backend instance lives in one zone, that zone's failure takes the application down regardless of how the load balancer's own frontend is configured. This is a genuinely easy trap: engineers confirm "yes, our load balancer is zone-redundant" and stop there without checking whether the VMs behind it actually span zones.

</details>

---

## Dependency Stack

```
Frontend IP configuration (public or private IP — decides LB type; zone-redundant/zonal/non-zonal, fixed at creation)
        │
NSG on the frontend/backend subnet explicitly allows the intended traffic
   (Standard SKU public IPs are secure-by-default — NO implicit inbound allow, unlike legacy Basic SKU)
        │
Backend pool populated with real instances (single VNet scope; cannot include a Private Endpoint)
        │
Health probe (TCP/HTTP/HTTPS) reaching each instance and receiving a passing response
   — governs eligibility for NEW flows only; failing this does not reset already-established TCP flows
        │
Load-balancing rule OR Inbound NAT rule maps frontend IP:port → backend pool / specific instance
        │
[If public LB backend needs outbound Internet] EXACTLY ONE explicit outbound method configured:
   Load Balancer outbound rule (SNAT via LB frontend, watch default port allocation) |
   NAT Gateway on the subnet (current MS recommendation for production) |
   Instance-level public IP (bypasses LB outbound path entirely)
   — Standard SKU provides NONE of these implicitly; absence of all three = no outbound path, silently
        │
[If internal LB + HA Ports for NVA scale-out] Floating IP mode chosen deliberately
   (non-floating = exclusive rule, simplest; floating/DSR = multi-frontend + public-LB-combinable,
    requires DSR-aware NVA software)
        │
Traffic flows to/from backend instance
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| VMs behind a newly-migrated Standard LB can't reach the internet | Standard SKU provides no implicit outbound path (unlike retired Basic SKU) — no outbound method configured | Confirm outbound rule, NAT Gateway, or instance-level public IP exists on the backend subnet/NICs |
| Outbound works but fails intermittently under load, especially with a large backend pool | Default SNAT port allocation shrinking per-instance ports as pool size grows | Check `AllocatedOutboundPorts`; move to manual allocation or NAT Gateway |
| Inbound traffic to a public frontend times out with no NSG deny logged | Standard SKU public IPs are secure-by-default — NSG must explicitly allow, there's no implicit permit | `Get-AzNetworkSecurityRuleConfig` on the frontend/backend subnet or NIC |
| Health probe shows all instances Unhealthy, but the app itself works fine when hit directly | Probe hitting a WinHTTP-restricted port (19/21/25/70/110/119/143/220/993), or wrong probe path/protocol | Change probe to a non-restricted port; verify protocol matches what the backend actually serves |
| One client's long session always lands on the same backend instance; a new client session sometimes doesn't | Expected 5-tuple hash behavior, not a fault — distribution is per-flow, not per-client | Confirm this is understood as by-design, not a "sticky session broken" bug |
| Existing TCP sessions to an instance keep working even though its probe just went Unhealthy | By design — probe failure blocks NEW flows only, doesn't reset established TCP connections | Confirm via `Get-AzLoadBalancerBackendHealth`; not a bug |
| All UDP-based service connectivity drops simultaneously | Every backend instance failed its probe at the same time — Azure terminates all UDP flows when the whole pool is unhealthy (no partial-pool grace period for UDP) | Check probe history/thresholds across the whole pool for a simultaneous failure, not just one instance |
| Client insists "the load balancer" is dropping HTTPS requests based on URL path | This is very likely an Application Gateway (L7) question, not this L4 resource — Load Balancer has no path/host awareness at all | Confirm which resource actually fronts the traffic; redirect to `AppGateway-A.md`/`AppGateway-B.md` if so |
| HA Ports rule creation fails or behaves unexpectedly alongside other rules | Non-floating-IP HA Ports must be the ONLY rule on that resource for that backend; mixing rule types incorrectly | Confirm Floating IP mode chosen matches the intended coexistence (single-rule vs. multi-frontend+public-LB) |
| A client is still running a Basic SKU load balancer found during an audit | Basic SKU retired September 30, 2025 — unsupported, no SLA, cannot be recreated if deleted | Flag for migration; see Playbook 1 |
| Backend pool member won't attach — resource type rejected | Load Balancer backend pools cannot contain a Private Endpoint, and are scoped to a single VNet | Confirm the resource type and VNet membership of the intended pool member |

---

## Validation Steps

**1. Confirm SKU and frontend type/zone configuration:**
```powershell
Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName> |
    Select-Object Sku, @{N='Frontends';E={$_.FrontendIpConfigurations | Select-Object Name, PrivateIpAddress, PublicIpAddress, Zones}}
```
Expected: `Sku.Name = Standard`. Any `Basic` result is an immediate migration finding (see Playbook 1), not something to troubleshoot further as-is.

**2. Confirm backend pool membership and health:**
```powershell
Get-AzLoadBalancerBackendAddressPool -ResourceGroupName <rg> -LoadBalancerName <lbName> |
    Select-Object Name, BackendIpConfigurations, LoadBalancerBackendAddresses
Get-AzLoadBalancerBackendHealth -ResourceGroupName <rg> -Name <lbName>
```
Expected: All intended instances present, `LoadBalancerBackendAddress` populated, and health status Up for every instance expected to be serving traffic.

**3. Confirm probe protocol/port isn't hitting the WinHTTP restricted-port list:**
```powershell
Get-AzLoadBalancerProbeConfig -LoadBalancer $lb | Select-Object Name, Protocol, Port, RequestPath, IntervalInSeconds, ProbeCount
```
Cross-check `Port` against 19, 21, 25, 70, 110, 119, 143, 220, 993 for HTTP/HTTPS probes.

**4. Confirm which of the three outbound methods is actually governing outbound traffic (public LB backends only):**
```powershell
# Load Balancer outbound rules
Get-AzLoadBalancerOutboundRuleConfig -LoadBalancer $lb | Select-Object Name, AllocatedOutboundPorts, FrontendIpConfigurations

# NAT Gateway on the subnet
Get-AzNatGateway -ResourceGroupName <rg> | Select-Object Name, ResourceGroupName
(Get-AzVirtualNetworkSubnetConfig -ResourceId <subnetId>).NatGateway

# Instance-level public IP directly on a backend NIC
(Get-AzNetworkInterface -ResourceGroupName <rg> -Name <nicName>).IpConfigurations.PublicIpAddress
```
Expected: Exactly one method present and understood; zero present on a public-LB backend pool needing outbound = confirmed root cause.

**5. Confirm NSG explicitly allows the intended inbound traffic (Standard SKU is secure-by-default):**
```powershell
Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName> | Get-AzNetworkSecurityRuleConfig
```
Expected: An explicit Allow matching the load-balancing rule's frontend port. No result here is a common false "the load balancer is broken" report that's actually an NSG gap.

**6. Confirm HA Ports configuration shape matches intent, if applicable:**
```powershell
Get-AzLoadBalancerRuleConfig -LoadBalancer $lb | Where-Object { $_.LoadDistribution -eq 'Default' -and $_.BackendPort -eq 0 } |
    Select-Object Name, Protocol, FrontendPort, BackendPort, EnableFloatingIP
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Resource and SKU Health

1. Confirm `Sku.Name` is `Standard` — flag any surviving `Basic` for migration before investigating further as if it had Standard capabilities.
2. Confirm `ProvisioningState = Succeeded` for the load balancer resource itself.
3. Confirm frontend IP configuration (public vs. internal, zone setting) matches what's expected.

### Phase 2: Inbound Path

1. Confirm the load-balancing rule or inbound NAT rule maps the reported frontend port to the correct backend pool/instance and port.
2. Confirm backend health via `Get-AzLoadBalancerBackendHealth` — split "all instances Unhealthy" (likely a probe configuration issue) from "some instances Unhealthy" (likely genuine per-instance backend issue).
3. If probe-related, check the probe port against the WinHTTP restricted-port list before assuming the backend itself is broken.
4. Confirm NSG explicitly allows the traffic — Standard SKU has no implicit inbound allow.

### Phase 3: Outbound Path (Public LB Backends)

1. Identify which of the three outbound methods (LB outbound rule / NAT Gateway / instance-level public IP) is actually present — absence of all three on a Standard SKU backend is itself the root cause, not a symptom to investigate further.
2. If an outbound rule is present, check `AllocatedOutboundPorts` and backend pool size together — default allocation shrinks per instance as the pool grows.
3. If intermittent failures under load, correlate with SNAT port exhaustion signals (connection failures clustering with high concurrent outbound connection counts) rather than assuming an application-layer bug.

### Phase 4: HA Ports / NVA Scenarios

1. Confirm the rule is on an **internal** load balancer — HA Ports is never valid on a public LB.
2. Confirm Floating IP mode matches the topology's actual requirement (single exclusive rule vs. multi-frontend with DSR).
3. If flow asymmetry is reported across a public+internal LB NVA chain, confirm this against the documented flow-symmetry limitation before assuming an NVA misconfiguration — Gateway Load Balancer may be the architecturally correct fix, not a rule change on the current resource.

### Phase 5: Disambiguation from Application Gateway / Front Door

1. Before troubleshooting further, confirm the reported symptom (path-based routing, WAF blocking, TLS termination, hostname-based rules) isn't actually describing Application Gateway or Front Door behavior misattributed to "the load balancer."
2. Load Balancer has zero Layer 7 awareness — no path, host header, or cookie visibility. Any symptom description involving those concepts belongs in `AppGateway-A.md`/`AppGateway-B.md`.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Migrate a surviving Basic SKU Load Balancer to Standard</summary>

Basic SKU is retired (September 30, 2025) — unsupported, no SLA, cannot be recreated if deleted. Treat any discovery of one as a migration finding requiring a planned maintenance window, not an in-place fix.

```powershell
# 1. Inventory the Basic LB's current configuration before touching anything
$basicLb = Get-AzLoadBalancer -ResourceGroupName <rg> -Name <basicLbName>
$basicLb.FrontendIpConfigurations | Select-Object Name, PrivateIpAddress, PublicIpAddress
$basicLb.BackendAddressPools | Select-Object Name, BackendIpConfigurations
$basicLb.LoadBalancingRules | Select-Object Name, FrontendIPConfiguration, BackendAddressPool, Protocol, FrontendPort, BackendPort
$basicLb.Probes | Select-Object Name, Protocol, Port, RequestPath

# 2. All associated Public IPs must be Static allocation before migration — Basic often defaults to Dynamic
Get-AzPublicIpAddress -ResourceGroupName <rg> | Where-Object { $_.IpConfiguration.Id -like "*$basicLbName*" } |
    Select-Object Name, PublicIpAllocationMethod, Sku

# 3. Use Microsoft's own automated migration script rather than a manual rebuild — see:
#    https://learn.microsoft.com/en-us/azure/load-balancer/upgrade-basic-standard-with-powershell
# It creates the new Standard LB, migrates backend pool membership/rules/probes, and re-points
# VMSS/VM NIC associations in a single guided operation, minimizing the downtime window a manual
# rebuild (delete/recreate) would otherwise require.

# 4. After migration, explicitly configure outbound access — Standard SKU provides none implicitly
#    even if the Basic LB's backend pool had working outbound before migration
```

**Rollback:** The automated script is designed to be re-run/resumed; a failed manual migration should have its Basic LB left in place (do not delete it) until the Standard LB is fully validated and cut over.

</details>

<details><summary>Playbook 2 — Add production-safe outbound access after a Basic→Standard migration or greenfield deploy</summary>

```powershell
# Option A (Microsoft's current recommendation for production): NAT Gateway
$natGwPip = New-AzPublicIpAddress -ResourceGroupName <rg> -Name "natgw-pip" -Location <location> -Sku Standard -AllocationMethod Static
$natGw = New-AzNatGateway -ResourceGroupName <rg> -Name "natgw" -Location <location> -Sku Standard -PublicIpAddress $natGwPip -IdleTimeoutInMinutes 10
$vnet = Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnetName>
$subnet = $vnet.Subnets | Where-Object Name -eq <subnetName>
$subnet.NatGateway = $natGw
Set-AzVirtualNetwork -VirtualNetwork $vnet

# Option B: Load Balancer outbound rule with MANUAL port allocation (avoid default allocation in production)
$lb = Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>
$feConfig = $lb.FrontendIpConfigurations | Where-Object Name -eq <frontendName>
$bePool = $lb.BackendAddressPools | Where-Object Name -eq <poolName>
Add-AzLoadBalancerOutboundRuleConfig -LoadBalancer $lb -Name "OutboundRule1" `
    -FrontendIpConfiguration $feConfig -BackendAddressPool $bePool `
    -Protocol All -AllocatedOutboundPort 1024 -IdleTimeoutInMinutes 4
$lb | Set-AzLoadBalancer
```

**Rollback:** Remove the outbound rule or dissociate the NAT Gateway from the subnet; existing established connections drain per idle timeout, no forced disconnect.

</details>

<details><summary>Playbook 3 — Fleet-wide Basic-SKU and outbound-access-gap audit</summary>

```powershell
Get-AzLoadBalancer | ForEach-Object {
    $lb = $_
    $isPublic = $lb.FrontendIpConfigurations.PublicIpAddress.Count -gt 0
    $hasOutboundRule = $lb.OutboundRules.Count -gt 0
    [PSCustomObject]@{
        LoadBalancer   = $lb.Name
        ResourceGroup  = $lb.ResourceGroupName
        Sku            = $lb.Sku.Name
        IsPublic       = $isPublic
        BackendCount   = ($lb.BackendAddressPools.BackendIpConfigurations | Measure-Object).Count
        HasOutboundRule = $hasOutboundRule
        NeedsReview    = ($lb.Sku.Name -eq 'Basic') -or ($isPublic -and -not $hasOutboundRule)
    }
} | Where-Object NeedsReview | Format-Table -AutoSize
```

**Rollback:** N/A — read-only audit.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Azure Load Balancer evidence for escalation
.NOTES     Run as a user with Reader+ on the resource group
#>

$OutputDir = "C:\Temp\LoadBalancer-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$lb = Get-AzLoadBalancer -ResourceGroupName $rg -Name $lbName

# 1. SKU, frontend configuration, zone settings
$lb | Select-Object Sku, ProvisioningState | Export-Csv "$OutputDir\LB-State.csv" -NoTypeInformation
$lb.FrontendIpConfigurations | Select-Object Name, PrivateIpAddress, PublicIpAddress, Zones |
    Export-Csv "$OutputDir\Frontends.csv" -NoTypeInformation

# 2. Backend pool membership and live health
$lb.BackendAddressPools | Select-Object Name, BackendIpConfigurations | ConvertTo-Json -Depth 6 |
    Out-File "$OutputDir\BackendPools.json"
Get-AzLoadBalancerBackendHealth -ResourceGroupName $rg -Name $lbName |
    ConvertTo-Json -Depth 6 | Out-File "$OutputDir\BackendHealth.json"

# 3. Rules — load-balancing, inbound NAT, and outbound
$lb.LoadBalancingRules | Select-Object Name, FrontendIPConfiguration, BackendAddressPool, Protocol, FrontendPort, BackendPort |
    Export-Csv "$OutputDir\LBRules.csv" -NoTypeInformation
$lb.InboundNatRules | Select-Object Name, FrontendIPConfiguration, BackendIPConfiguration, Protocol, FrontendPort, BackendPort |
    Export-Csv "$OutputDir\InboundNatRules.csv" -NoTypeInformation
$lb.OutboundRules | Select-Object Name, AllocatedOutboundPorts, FrontendIpConfigurations |
    Export-Csv "$OutputDir\OutboundRules.csv" -NoTypeInformation

# 4. Health probes
$lb.Probes | Select-Object Name, Protocol, Port, RequestPath, IntervalInSeconds, ProbeCount |
    Export-Csv "$OutputDir\Probes.csv" -NoTypeInformation

# 5. Alternate outbound mechanisms present on the backend subnet(s)
Get-AzNatGateway -ResourceGroupName $rg | Select-Object Name |
    Export-Csv "$OutputDir\NatGateways.csv" -NoTypeInformation

# 6. NSG rules on the frontend/backend subnet
$vnet = Get-AzVirtualNetwork -ResourceGroupName $rg
$vnet.Subnets | ForEach-Object {
    if ($_.NetworkSecurityGroup) {
        $nsgName = ($_.NetworkSecurityGroup.Id -split '/')[-1]
        Get-AzNetworkSecurityGroup -ResourceGroupName $rg -Name $nsgName | Get-AzNetworkSecurityRuleConfig
    }
} | Export-Csv "$OutputDir\Subnet-NSG-Rules.csv" -NoTypeInformation

# 7. Recent Activity Log entries for this resource
Get-AzActivityLog -ResourceId $lb.Id -StartTime (Get-Date).AddHours(-24) |
    Select-Object EventTimestamp, OperationName, Status, Caller |
    Export-Csv "$OutputDir\ActivityLog-24h.csv" -NoTypeInformation

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# SKU, provisioning state, frontend config — always check first
Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName> | Select Sku, ProvisioningState

# Backend pool membership + live health — the #1 first check for any "traffic isn't reaching backends" ticket
Get-AzLoadBalancerBackendHealth -ResourceGroupName <rg> -Name <lbName>

# Health probe configuration — check port against the WinHTTP restricted-port list
(Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>).Probes | Select Name, Protocol, Port, RequestPath

# Load-balancing rules
(Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>).LoadBalancingRules | Select Name, FrontendPort, BackendPort, Protocol

# Outbound rules — SNAT port allocation, the #1 post-migration outbound-connectivity check
(Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>).OutboundRules | Select Name, AllocatedOutboundPorts

# NAT Gateway attached to a subnet — the alternate/recommended outbound mechanism
(Get-AzVirtualNetworkSubnetConfig -ResourceId <subnetId>).NatGateway

# Instance-level public IP directly on a backend NIC — the third outbound mechanism
(Get-AzNetworkInterface -ResourceGroupName <rg> -Name <nicName>).IpConfigurations.PublicIpAddress

# HA Ports rules (internal LB only) — Protocol All, Port 0
(Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>).LoadBalancingRules | Where-Object BackendPort -eq 0

# NSG rules on the backend subnet — Standard SKU has no implicit inbound allow
Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName> | Get-AzNetworkSecurityRuleConfig

# Fleet-wide SKU check — find any surviving (unsupported) Basic Load Balancers
Get-AzLoadBalancer | Where-Object { $_.Sku.Name -eq 'Basic' } | Select Name, ResourceGroupName

# Activity log for a specific load balancer
Get-AzActivityLog -ResourceId (Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>).Id -StartTime (Get-Date).AddHours(-24)
```

---

## 🎓 Learning Pointers

- **Standard SKU's outbound behavior is the single biggest surprise for anyone used to Basic SKU.** Basic implicitly allowed backend VMs to reach the internet; Standard does not, full stop, until one of exactly three explicit methods is configured (Load Balancer outbound rules, NAT Gateway, or an instance-level public IP). Since Basic's full retirement on September 30, 2025, every remaining migration surfaces this the same way: "we upgraded and now nothing can reach the internet." Check this before anything else on a post-migration outbound ticket. [MS Docs: SNAT for outbound connections](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-outbound-connections)

- **This is a distinct mechanism from Azure's broader "default outbound access" retirement** (the implicit outbound path that exists for a VM with *no* explicit LB/NAT Gateway/public IP at all — being phased out for new deployments tied to API versions released after March 31, 2026, per Microsoft's own delayed timeline). A VM behind a Standard Load Balancer with no outbound rule was **already** cut off from outbound access the moment it joined that backend pool, independent of the separate platform-wide default-outbound-access change — don't conflate the two when explaining root cause to a client. [MS Docs: Default outbound access retirement](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access)

- **Default SNAT port allocation gets worse as the backend pool gets bigger, not better.** Ports are allocated per-instance up to a 1,024-port ceiling per frontend IP, calculated based on backend pool size — a large, legitimately busy backend pool is exactly the scenario most likely to hit SNAT exhaustion under default allocation. Microsoft's own guidance is to move outbound-heavy production workloads to NAT Gateway rather than tuning manual allocation indefinitely. [MS Docs: Load Balancer best practices](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-best-practices)

- **A failed health probe doesn't reset existing TCP connections — only blocks new ones.** This is by design (graceful drain rather than a hard cutover) but is routinely misread as "the probe must not really be failing" when a client reports an instance is still serving live traffic well after its probe went Unhealthy. UDP is the exception: a single instance's UDP flows move to a healthy peer, but if the *entire* pool is unhealthy simultaneously, all UDP flows terminate immediately with no grace period.

- **Azure Load Balancer is frequently confused with Application Gateway** — both distribute traffic across a backend pool, but Load Balancer operates purely at Layer 4 (TCP/UDP, 5-tuple hash, zero path/host/cookie awareness) while Application Gateway is Layer 7 (HTTP/HTTPS, path-based routing, WAF, TLS termination). A client describing path-based rules, a WAF block, or hostname-specific behavior is describing Application Gateway even if they call it "the load balancer" — confirm which resource is actually in the path before troubleshooting the wrong one. See `AppGateway-A.md` for the reverse-direction disambiguation.
