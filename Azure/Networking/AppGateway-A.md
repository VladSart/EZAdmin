# Azure Application Gateway — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the routing/WAF architecture, not just the fix commands.

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
- Application Gateway v2 (Standard_v2 / WAF_v2) — the current recommended SKU family
- Layer 7 (HTTP/HTTPS) load balancing: listeners, routing rules, backend pools, HTTP settings
- Web Application Firewall (WAF) policy architecture and precedence
- Backend health probing mechanics
- The dedicated-subnet networking model and v2-specific control-plane requirements
- SNAT/connection capacity behavior under load

**Out of scope:**
- Application Gateway v1 (Standard/WAF, no "_v2" suffix) — legacy, no autoscaling, being phased toward retirement; flag any client still on v1 for a migration conversation rather than troubleshooting it as if it had v2 capabilities
- Application Gateway for Containers — a materially different, Kubernetes-native product sharing only the name and general L7 concept
- Azure Front Door — a separate, global-edge L7 service; referenced only where the two are commonly confused (see Learning Pointers)
- Azure Firewall — covered in `AzureFirewall-A.md`/`AzureFirewall-B.md`; Azure Firewall terminates outbound/East-West TLS only, Application Gateway is this repo's inbound reverse-proxy/WAF coverage
- Detailed WAF Core Rule Set (CRS) rule-by-rule tuning — covered at the "how to exclude a false positive" level, not a full CRS reference

**Assumptions:**
- v2 SKU (Standard_v2 or WAF_v2)
- Reader has Network Contributor or higher on the resource group
- At least one backend pool with real, reachable members

---

## How It Works

<details><summary>Full architecture</summary>

### Request Path

```
Client
   │  HTTP/HTTPS to a Public or Private frontend IP
   ▼
Listener (protocol + port, + hostname if multi-site)
   │
   ▼
[If WAF_v2] WAF policy evaluation (gateway/listener/path level — most specific wins)
   │  Detection: logs and passes through | Prevention: blocks and returns 403 on match
   ▼
Routing rule (Basic: one backend pool | Path-based: URL Path Map routes by path prefix)
   │
   ▼
Backend HTTP settings (protocol, port, cookie-based affinity, request timeout, host header handling)
   │
   ▼
Backend pool member (VM, VMSS, App Service, IP address, or FQDN — can be mixed types)
   │
   ▼
Response returned through the same path (WAF does not re-inspect response bodies by default)
```

### The Dedicated Subnet and v2 Control-Plane Model

Application Gateway v2 requires its own subnet — no other resource (VMs, other PaaS resources, even Application Gateway v1 instances) can share it. This isn't a best-practice recommendation; deployment fails if the subnet already hosts something else.

v2's autoscaling and zone-redundancy model means Microsoft manages a pool of gateway instances behind the scenes, and those instances need to communicate with the Azure control plane for health reporting, scaling decisions, and (for WAF_v2) rule engine updates. This communication happens over **TCP 65200-65535** from the `GatewayManager` service tag. An NSG on the gateway's subnet that doesn't explicitly allow this doesn't produce an access-denied style failure — it produces **blank or Unknown backend health**, because the instances can't report status back at all. This is the single most common "why can't I see backend health" root cause in v2 deployments with a custom NSG.

```powershell
# Required NSG rule
Source: GatewayManager (service tag)
Destination: * (the Application Gateway subnet)
Ports: 65200-65535
Protocol: Any (TCP is sufficient in practice, Any is Microsoft's documented recommendation)
Action: Allow
```

Outbound Internet access from the subnet must also remain allowed for WAF_v2 specifically — the WAF engine and signature set receive automatic updates over that path, independent of any application traffic the gateway is proxying.

### Listeners, Routing Rules, and Multi-Site Hosting

A **listener** binds to a frontend IP + port + protocol, and optionally a specific hostname (multi-site hosting) or wildcard hostname pattern. Multiple listeners can share the same frontend IP/port if they're differentiated by hostname (SNI for HTTPS, Host header for HTTP) — this is how one gateway serves many independent sites.

A **routing rule** connects a listener to where traffic goes:
- **Basic** — every request on this listener goes to one backend pool via one HTTP settings object.
- **Path-based** — a URL Path Map inspects the request path and routes to different backend pools based on path prefix (e.g., `/api/*` → API pool, `/*` → default web pool). Path matching is prefix-based and case-sensitive by default.

### Backend HTTP Settings

This object controls how the gateway talks to the backend, independent of how the client talks to the gateway:
- **Protocol** (HTTP or HTTPS) and **port** — can differ entirely from the frontend (e.g., HTTPS in, HTTP to backend, common when TLS is terminated at the gateway).
- **Cookie-based affinity** — sticky sessions via a gateway-managed cookie, independent of any backend-set session cookie.
- **Request timeout** — how long the gateway waits for a backend response before returning a 504. A slow-but-working backend and a genuinely broken one look identical from the client's perspective if this is set too low.
- **Host header** — `PickHostNameFromBackendAddress` (uses the backend's own FQDN) vs. an explicit override — critical for backends (like App Service) that route based on the Host header they receive.
- **Client IP preservation / Proxy Protocol** — when enabled on an HTTPS backend setting, the gateway sends a Proxy Protocol header immediately before the TLS handshake, including for health probes. A backend that doesn't parse this header fails the probe even though the application itself would otherwise work fine — a subtle, easy-to-misdiagnose failure mode since it presents as "backend unhealthy" rather than an obvious configuration error.

### Health Probing

Every backend pool member is probed independently on an interval. Default probes hit `/` on the backend's own hostname; custom probes specify a path, hostname, interval, timeout, unhealthy threshold, and expected match (status code range and/or response body substring). **Any response coded 200-399 is healthy by default** — a probe path that returns a 302 redirect to a login page still counts as healthy unless a custom match is configured to catch that. Conversely, a probe path that legitimately requires auth and returns 401/403 will show Unhealthy even though the application is otherwise fine — this is a probe design problem, not a backend outage, and is judged the single most common cause of false "backend down" alerts in real deployments.

### WAF Policy Architecture and Precedence

A WAF policy (`Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies`) is a standalone resource containing managed rule sets (OWASP Core Rule Set, Bot Manager), custom rules, and exclusions, with a mode of **Detection** (log only) or **Prevention** (log and block).

A policy can be associated at three levels simultaneously:
```
Gateway level   — applies to every listener/path with no more specific override (least specific)
Listener level  — overrides the gateway policy for that specific site/hostname
Path level      — overrides both, for a specific URL path rule (most specific)
```
**The most specific association wins entirely** — not a merge of settings. A path with its own policy in Detection mode is NOT also subject to the gateway's Prevention-mode rules; the path-level policy is the complete, exclusive answer for requests matching that path. This is a genuinely easy configuration to lose track of at scale (many listeners/paths, each potentially with its own override), and is the most common root cause of "this one endpoint behaves differently than everything else on the same gateway" tickets.

### Autoscaling and SNAT Capacity

v2 SKU autoscales instance count within a configured `MinCapacity`/`MaxCapacity` range based on load (CPU, memory, and throughput). Each instance carries its own SNAT port allocation for outbound connections to backend pool members; under sustained high-connection-count load with too few instances (or `MaxCapacity` set too low), SNAT port exhaustion produces intermittent backend connection failures that have nothing to do with backend health, WAF, or routing configuration — purely a capacity ceiling.

</details>

---

## Dependency Stack

```
Dedicated Application Gateway subnet (no other resource type may share it)
        │
NSG allows GatewayManager inbound on TCP 65200-65535 (v2 control-plane health reporting)
        │
NSG/UDR allow outbound Internet (required for WAF_v2 engine/signature auto-updates)
        │
Frontend IP configuration (Public and/or Private)
        │
Listener (protocol/port/hostname binding)
        │
[If HTTPS] Valid, non-expired, trusted certificate bound to the listener
        │
[If WAF_v2] WAF policy resolved at the most specific applicable level (path > listener > gateway)
        │
Routing rule (Basic or Path-based) maps listener → backend pool + HTTP settings
        │
Backend HTTP settings (protocol/port/host-header/timeout/affinity/proxy-protocol config)
        │
Health probe reaches backend, receives a 200-399 (or custom match) — REQUIRED for the pool
member to receive live traffic, independent of whether the member is actually reachable via
a normal client request
        │
Sufficient instance capacity / SNAT headroom for the actual connection volume
        │
Backend pool member processes the request and responds within RequestTimeout
        │
Response returned to client
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Backend health blank/Unknown for every server | Missing GatewayManager NSG rule on the gateway's own subnet (v2 control-plane) | `Get-AzNetworkSecurityRuleConfig` for a GatewayManager 65200-65535 allow |
| Backend health Unhealthy for specific servers, probe timeout | Probe path/timeout misconfigured, or backend genuinely down | `Get-AzApplicationGatewayProbeConfig`; test the probe path directly against the backend |
| Backend health Unhealthy, probe returns 401/403/302 | Probe path requires auth or redirects — outside default 200-399 healthy range | Adjust probe path to an unauthenticated endpoint, or configure a custom Match |
| 502/504, backend health shows Healthy | RequestTimeout too low for a slow backend, or Proxy Protocol header not parsed by backend on HTTPS settings with client IP preservation | Check `RequestTimeout`; confirm backend parses Proxy Protocol if enabled |
| Distinctive 403 with WAF-branded body | WAF Prevention-mode rule match (possible false positive) | Firewall diagnostic logs; identify the specific rule ID |
| One path/listener behaves differently than the rest of the same gateway | Path- or listener-level WAF policy override, or path-based routing misconfiguration | Check `FirewallPolicy` at listener AND path level, not just gateway level |
| WAF suddenly stops receiving new rule signatures / behaves stale | Outbound Internet blocked on the gateway subnet (NVA/firewall forced-tunnel with no explicit allow) | Confirm subnet UDR/NSG allow outbound to Internet |
| Intermittent connection failures under high load, backend/WAF both otherwise healthy | SNAT port exhaustion — too few instances or `MaxCapacity` too low for the load | `CurrentConnections`/`FailedRequests` metrics; raise autoscale `MaxCapacity` |
| `ProvisioningState` stuck at Updating/Failed after a config change | A change didn't complete cleanly | `Get-AzActivityLog` for the specific failed operation; re-apply via `Set-AzApplicationGateway` |
| Deployment to an existing subnet fails outright | Subnet already contains another resource type — v2 requires an exclusive subnet | Confirm subnet contents via `Get-AzVirtualNetworkSubnetConfig` |
| No data available to investigate any of the above | Diagnostic Settings never configured for Access/Performance/Firewall logs | `Set-AzDiagnosticSetting` targeting a Log Analytics workspace |

---

## Validation Steps

**1. Confirm the gateway and its SKU:**
```powershell
Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName> | Select-Object ProvisioningState, OperationalState, Sku
```
Expected: `Succeeded`/`Running`, SKU is `Standard_v2` or `WAF_v2` (flag v1 for migration if seen).

**2. Confirm the dedicated subnet and its NSG:**
```powershell
$gw = Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>
$subnetId = $gw.GatewayIPConfigurations[0].Subnet.Id
Get-AzVirtualNetworkSubnetConfig -ResourceId $subnetId
```
Expected: The subnet contains only Application Gateway resources.

**3. Confirm the GatewayManager control-plane NSG rule exists:**
```powershell
Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName> | Get-AzNetworkSecurityRuleConfig |
    Where-Object { $_.SourceAddressPrefix -match "GatewayManager" -and $_.DestinationPortRange -match "65200" }
```
Expected: An Allow rule present. Missing → blank backend health, independent of actual backend state.

**4. Confirm backend health per member:**
```powershell
Get-AzApplicationGatewayBackendHealth -ResourceGroupName <rg> -Name <gwName>
```
Expected: `Healthy` for every server in every pool.

**5. Confirm WAF policy association and mode at all three levels for the affected hostname/path:**
```powershell
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).FirewallPolicy
$gw.HttpListeners | Select-Object Name, FirewallPolicy
$gw.UrlPathMaps.PathRules | Select-Object Paths, FirewallPolicy
```
Expected: The most specific applicable policy's mode (Detection/Prevention) matches what's intended for that path.

**6. Confirm backend HTTP settings for timeout and proxy-protocol expectations:**
```powershell
$gw.BackendHttpSettingsCollection | Select-Object Name, Protocol, Port, RequestTimeout, HostName, PickHostNameFromBackendAddress
```

**7. Confirm diagnostic logging is enabled for ongoing visibility:**
```powershell
Get-AzDiagnosticSetting -ResourceId $gw.Id
```
Expected: At least `ApplicationGatewayAccessLog` and `ApplicationGatewayFirewallLog` (if WAF_v2) enabled to a Log Analytics workspace.

**8. Confirm autoscale capacity is adequate for observed load, if SNAT exhaustion is suspected:**
```powershell
$gw.AutoscaleConfiguration
Get-AzMetric -ResourceId $gw.Id -MetricName "CurrentConnections" -TimeGrain 00:01:00
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Gateway-Level Health

1. `ProvisioningState`/`OperationalState` — confirm the resource itself is healthy before investigating traffic.
2. Confirm SKU is v2, not legacy v1 (different capability set entirely).
3. Confirm the dedicated subnet is clean and its NSG has the GatewayManager 65200-65535 rule.

### Phase 2: Backend Health

1. `Get-AzApplicationGatewayBackendHealth` — split into "blank/Unknown for everyone" (control-plane/NSG issue) vs. "specific servers Unhealthy" (probe or backend issue).
2. For specific-server failures, pull the probe config and test the exact probe path directly against the backend, bypassing the gateway.
3. Check whether the probe path requires auth or redirects — both produce a false Unhealthy under default matching.

### Phase 3: Traffic-Level (WAF vs. Backend)

1. Reproduce the failure and capture the exact response — a WAF 403 body is visually distinct from a 502/504.
2. If WAF: pull Firewall diagnostic logs, identify the rule ID, add a targeted exclusion (never disable the whole managed rule set to fix one false positive).
3. If 502/504 with Healthy backend health: check `RequestTimeout` and Proxy Protocol/client-IP-preservation settings on the specific backend HTTP settings object in use.

### Phase 4: Policy Precedence Confirmation

1. Pull `FirewallPolicy` at gateway, listener, and path level for the specific failing request.
2. Confirm which one actually governs this request (most specific, full override — not a merge).
3. If an override is unintentional, remove it to fall back to the intended (usually gateway-level) policy.

### Phase 5: Capacity/Scale

1. Pull `CurrentConnections`, `FailedRequests`, `BackendConnectTime` metrics for the affected time window.
2. Compare against `AutoscaleConfiguration` min/max instance bounds.
3. Raise `MaxCapacity` if load is legitimate and sustained; investigate for a connection leak (backend not closing connections promptly) if load doesn't otherwise explain the volume.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield WAF_v2 deployment with correct NSG/subnet from the start</summary>

```powershell
# Dedicated subnet — nothing else may live here
New-AzVirtualNetworkSubnetConfig -Name "AppGwSubnet" -AddressPrefix "10.0.1.0/24"

# NSG with the required control-plane rule, applied BEFORE the gateway is deployed
$nsg = New-AzNetworkSecurityGroup -ResourceGroupName <rg> -Location <location> -Name "AppGwSubnet-NSG"
Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "Allow-GatewayManager" `
    -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 `
    -SourceAddressPrefix GatewayManager -SourcePortRange * `
    -DestinationAddressPrefix * -DestinationPortRange 65200-65535
$nsg | Set-AzNetworkSecurityGroup

# Explicit outbound Internet allow (do not rely on an implicit rule if a UDR forces egress through an NVA)
Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "Allow-Outbound-Internet" `
    -Access Allow -Protocol Tcp -Direction Outbound -Priority 100 `
    -SourceAddressPrefix * -SourcePortRange * `
    -DestinationAddressPrefix Internet -DestinationPortRange 443
$nsg | Set-AzNetworkSecurityGroup
```

**Rollback:** Standard resource deletion; no destructive dependencies beyond the gateway itself.

</details>

<details><summary>Playbook 2 — Migrate a listener/path from a gateway-wide WAF policy to a scoped exception</summary>

```powershell
# Create a narrower policy for the specific path that needs different handling
$exceptionPolicy = New-AzApplicationGatewayFirewallPolicy -ResourceGroupName <rg> -Name "<path>-exception-policy" `
    -Location <location>
$exceptionPolicy.PolicySettings.Mode = "Detection"   # start in Detection while validating
Set-AzApplicationGatewayFirewallPolicy -InputObject $exceptionPolicy

# Associate at the path level (most specific — will fully override the gateway-level policy for this path only)
$gw = Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>
$pathRule = $gw.UrlPathMaps.PathRules | Where-Object Paths -contains "/api/*"
$pathRule.FirewallPolicy = $exceptionPolicy.Id
Set-AzApplicationGateway -ApplicationGateway $gw
```

**Document the override explicitly** (in the gateway's tags or a runbook note) — a path-level policy is easy to forget about later and can cause confusion when the gateway-level policy is updated and the change appears not to take effect for this one path.

**Rollback:**
```powershell
$pathRule.FirewallPolicy = $null
Set-AzApplicationGateway -ApplicationGateway $gw
```

</details>

<details><summary>Playbook 3 — Fleet-wide backend health and WAF-mode audit</summary>

```powershell
Get-AzApplicationGateway | ForEach-Object {
    $gw = $_
    $health = Get-AzApplicationGatewayBackendHealth -ResourceGroupName $gw.ResourceGroupName -Name $gw.Name -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        Gateway         = $gw.Name
        Sku             = $gw.Sku.Name
        ProvisioningState = $gw.ProvisioningState
        WAFPolicyMode   = if ($gw.FirewallPolicy) { (Get-AzApplicationGatewayFirewallPolicy -ResourceId $gw.FirewallPolicy.Id).PolicySettings.Mode } else { "No policy" }
        UnhealthyCount  = ($health.BackendAddressPools.BackendHttpSettingsCollection.Servers | Where-Object Health -ne "Healthy").Count
    }
} | Format-Table -AutoSize
```

**Rollback:** N/A — read-only audit.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Application Gateway evidence for escalation
.NOTES     Run as a user with Reader+ on the resource group
#>

$OutputDir = "C:\Temp\AppGateway-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$gw = Get-AzApplicationGateway -ResourceGroupName $rg -Name $gwName

# 1. Gateway state and SKU
$gw | Select-Object ProvisioningState, OperationalState, Sku, AutoscaleConfiguration |
    Export-Csv "$OutputDir\Gateway-State.csv" -NoTypeInformation

# 2. Backend health
Get-AzApplicationGatewayBackendHealth -ResourceGroupName $rg -Name $gwName |
    ConvertTo-Json -Depth 6 | Out-File "$OutputDir\BackendHealth.json"

# 3. Listeners, routing rules, path maps, and WAF policy associations at every level
$gw.HttpListeners | Select-Object Name, Protocol, HostName, FirewallPolicy | Export-Csv "$OutputDir\Listeners.csv" -NoTypeInformation
$gw.RequestRoutingRules | Select-Object Name, RuleType, BackendAddressPool, BackendHttpSettings | Export-Csv "$OutputDir\RoutingRules.csv" -NoTypeInformation
$gw.UrlPathMaps.PathRules | Select-Object Paths, FirewallPolicy, BackendAddressPool | Export-Csv "$OutputDir\PathRules.csv" -NoTypeInformation

# 4. Backend HTTP settings
$gw.BackendHttpSettingsCollection | Select-Object Name, Protocol, Port, RequestTimeout, HostName, PickHostNameFromBackendAddress |
    Export-Csv "$OutputDir\BackendHttpSettings.csv" -NoTypeInformation

# 5. NSG rules on the dedicated subnet (control-plane check)
$subnetId = $gw.GatewayIPConfigurations[0].Subnet.Id
$subnet = Get-AzVirtualNetworkSubnetConfig -ResourceId $subnetId
if ($subnet.NetworkSecurityGroup) {
    $nsgName = ($subnet.NetworkSecurityGroup.Id -split '/')[-1]
    $nsgRg   = ($subnet.NetworkSecurityGroup.Id -split '/')[4]
    Get-AzNetworkSecurityGroup -ResourceGroupName $nsgRg -Name $nsgName | Get-AzNetworkSecurityRuleConfig |
        Export-Csv "$OutputDir\Subnet-NSG-Rules.csv" -NoTypeInformation
}

# 6. WAF policy detail, if present
if ($gw.FirewallPolicy) {
    Get-AzApplicationGatewayFirewallPolicy -ResourceId $gw.FirewallPolicy.Id |
        ConvertTo-Json -Depth 6 | Out-File "$OutputDir\WAFPolicy-Gateway.json"
}

# 7. Recent Activity Log entries for this resource
Get-AzActivityLog -ResourceId $gw.Id -StartTime (Get-Date).AddHours(-24) |
    Select-Object EventTimestamp, OperationName, Status, Caller |
    Export-Csv "$OutputDir\ActivityLog-24h.csv" -NoTypeInformation

# 8. Metrics relevant to capacity/SNAT investigation
Get-AzMetric -ResourceId $gw.Id -MetricName "CurrentConnections","FailedRequests","Throughput" -TimeGrain 00:05:00 -WarningAction SilentlyContinue |
    ForEach-Object { $_.Data } | Export-Csv "$OutputDir\Metrics.csv" -NoTypeInformation

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Gateway state and SKU
Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName> | Select ProvisioningState, OperationalState, Sku

# Backend health — the #1 first check
Get-AzApplicationGatewayBackendHealth -ResourceGroupName <rg> -Name <gwName>

# Listeners and their WAF policy association
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).HttpListeners | Select Name, Protocol, HostName, FirewallPolicy

# Path-based rules and their WAF policy association (most specific level)
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).UrlPathMaps.PathRules | Select Paths, FirewallPolicy

# Backend HTTP settings — timeout, host header, protocol
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).BackendHttpSettingsCollection | Select Name, Protocol, Port, RequestTimeout

# Probe configuration
Get-AzApplicationGatewayProbeConfig -ApplicationGateway $gw

# WAF policy mode and managed rule sets
Get-AzApplicationGatewayFirewallPolicy -ResourceGroupName <rg> -Name <policyName> | Select PolicySettings

# NSG rule check for the control-plane requirement
Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName> | Get-AzNetworkSecurityRuleConfig |
    Where-Object { $_.SourceAddressPrefix -match "GatewayManager" }

# Diagnostic settings
Get-AzDiagnosticSetting -ResourceId $gw.Id

# Autoscale configuration
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).AutoscaleConfiguration

# Force re-provisioning after a stuck config change
Set-AzApplicationGateway -ApplicationGateway (Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>)

# Activity log for a specific gateway
Get-AzActivityLog -ResourceId (Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).Id -StartTime (Get-Date).AddHours(-24)
```

---

## 🎓 Learning Pointers

- **The most common real-world backend health failure is a control-plane NSG gap, not a backend outage.** v2's Microsoft-managed instances need `GatewayManager` allowed on TCP 65200-65535 to report health at all — missing this shows blank/Unknown, not an explicit error, and is very easy to misdiagnose as a backend problem when it's actually the gateway's own subnet configuration. [MS Docs: Backend health troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/azure/application-gateway/application-gateway-backend-health-troubleshooting)

- **WAF policy precedence (path > listener > gateway) is a full override, not a merge.** Treat every reported "this one path/site behaves differently" ticket as a policy-precedence question first — check all three levels for the specific request in question before assuming it's a rule-tuning problem at whichever level you happened to look at first. [MS Docs: WAF policy overview](https://learn.microsoft.com/en-us/azure/web-application-firewall/ag/policy-overview)

- **Health probes default to accepting any 200-399 response as healthy** — a probe path that redirects to a login page (302) or a path that legitimately requires auth (401/403) produces a false read in either direction. Design probe paths deliberately (an unauthenticated, lightweight health endpoint) rather than reusing the application's root path by default.

- **Application Gateway is frequently confused with Azure Front Door** — both are Microsoft L7 reverse proxies with WAF capability, but Application Gateway is regional (deployed into a specific VNet/subnet, ideal for VNet-integrated backends) while Front Door is a global edge service (anycast, best for geographically distributed backends and CDN-adjacent scenarios). They are sometimes deployed together (Front Door at the edge, Application Gateway regionally behind it) — confirm which layer a given WAF finding or routing question actually belongs to before troubleshooting the wrong resource.

- **Client IP preservation on an HTTPS backend setting changes the health probe's own wire format** (a Proxy Protocol header ahead of the TLS handshake) — this is easy to overlook since it's a checkbox on the backend settings object, not something visible when just looking at probe configuration. A backend that doesn't parse Proxy Protocol will fail both live traffic and probes in a way that looks identical to a generic backend outage.
