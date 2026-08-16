# Azure Application Gateway — Hotfix Runbook (Mode B: Ops)
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
# 1. Is the gateway itself healthy, and what SKU/tier is it?
Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName> | Select-Object ProvisioningState, OperationalState, Sku

# 2. Backend pool health — the single most useful first check for any "site is down" ticket
Get-AzApplicationGatewayBackendHealth -ResourceGroupName <rg> -Name <gwName> |
    Select-Object -ExpandProperty BackendAddressPools |
    ForEach-Object { $_.BackendHttpSettingsCollection.Servers | Select-Object Address, Health, HealthProbeLog }

# 3. Is a WAF policy involved, and is it blocking (Prevention) or just logging (Detection)?
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).FirewallPolicy
Get-AzApplicationGatewayFirewallPolicy -ResourceGroupName <rg> -Name <policyName> | Select-Object PolicySettings

# 4. Is this a 502/504 pattern (backend-side) or a WAF block (403 with a WAF-specific body)?
#    Check the diagnostic Access log if enabled — httpStatus + a populated WAF action column tells you immediately
Get-AzApplicationGatewayFirewallLog  # (requires Diagnostic Settings → AzureDiagnostics sent to Log Analytics — see Fix 6 if not enabled)

# 5. Subnet-level check — is the dedicated Application Gateway subnet actually clean of anything blocking control-plane traffic?
Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName> |
    Get-AzNetworkSecurityRuleConfig | Where-Object { $_.DestinationPortRange -match "65200|65535" }
```

| If | Then |
|----|------|
| `ProvisioningState` isn't `Succeeded` | A configuration change is stuck or failed → **Fix 1** |
| Backend health shows `Unhealthy` with a probe timeout/wrong-status-code detail | Health probe misconfigured, or backend itself is down → **Fix 2** |
| Users see a WAF-branded 403, not a generic 502/504 | WAF rule false positive in Prevention mode → **Fix 3** |
| 502 on every request, backend health shows Healthy | TLS/Proxy-protocol mismatch on backend HTTPS settings, or connection draining during a scale event → **Fix 4** |
| Some paths/sites work, others on the same gateway don't | Per-listener or per-path WAF policy override, or path-based rule misrouting → **Fix 5** |
| No diagnostic logs available to investigate | Diagnostic Settings never configured → **Fix 6** |
| High request volume, intermittent backend connection failures under load | SNAT port exhaustion — check `Failed Requests` / `Current Connections` metrics → **Fix 7** |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Dedicated subnet (Application Gateway ONLY — cannot share with any other resource type)
        │
NSG on that subnet allows GatewayManager service tag inbound on TCP 65200-65535
   (control-plane health; v2 SKU — missing this shows backend health as blank/unknown,
    not an explicit deny, which is easy to misdiagnose as a backend problem)
        │
NSG/UDR allow outbound Internet from the subnet
   (required for WAF rule/engine auto-updates on WAF_v2 — do not force all egress through
    an NVA/firewall without an explicit allow, this silently breaks WAF signature updates)
        │
Public/Private frontend IP configuration
        │
Listener (protocol, port, hostname if multi-site) bound to the frontend IP
        │
[If HTTPS] Certificate valid, not expired, chain trusted
        │
[If WAF_v2] WAF policy associated — gateway level, optionally overridden at listener or path level
   (most-specific wins: path > listener > gateway — a silent override is the #1
    "why is this one path behaving differently" cause)
        │
Routing rule (basic or path-based) maps listener → backend pool + HTTP settings
        │
Backend HTTP settings (protocol, port, cookie affinity, request timeout, host header override)
        │
Health probe reaches backend pool member and receives a response coded 200-399 by default
        │
Backend pool member accepts the connection and responds within the configured timeout
        │
Response returned to client
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm the gateway resource itself is healthy:**
```powershell
Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName> |
    Select-Object ProvisioningState, OperationalState
```
Expected: `ProvisioningState = Succeeded`, `OperationalState = Running`.
If `ProvisioningState` is `Updating` or `Failed` → a prior configuration change didn't complete; see Fix 1 before anything else.

**2. Check backend health — this immediately splits the problem into gateway-side vs. backend-side:**
```powershell
Get-AzApplicationGatewayBackendHealth -ResourceGroupName <rg> -Name <gwName>
```
Expected: Every backend server shows `Health = Healthy`.
- `Unhealthy` with a specific probe error → the backend or the probe configuration, not the gateway. Fix 2.
- Health shows blank/`Unknown` for ALL backends → this is very often the 65200-65535 NSG gap on the gateway's own subnet, not a backend problem at all. Fix 2 (NSG section).

**3. Distinguish a WAF block from a real backend failure:**
```powershell
# A WAF block returns a distinctive 403 body ("Request blocked" / rule reference) — NOT a 502/504
# Confirm via diagnostic Access + Firewall logs if enabled, or reproduce with curl -v against the frontend
curl -v https://<gateway-frontend-fqdn>/<path>
```
If the response is a 403 with WAF-specific content → this is Fix 3, not a backend investigation.

**4. If 502/504 with backend health showing Healthy, check TLS/proxy-protocol and timeouts:**
```powershell
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).BackendHttpSettingsCollection |
    Select-Object Name, Protocol, Port, RequestTimeout, HostName, PickHostNameFromBackendAddress
```
A `Protocol = Https` backend setting with client IP preservation enabled sends a Proxy Protocol header before the TLS handshake for probes — a backend that doesn't parse this fails the probe even though the app itself is fine. See Fix 4.

**5. Confirm which WAF policy is actually in effect for the failing path — precedence matters:**
```powershell
# Gateway-level (least specific)
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).FirewallPolicy

# Per-listener override, if any
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).HttpListeners | Select-Object Name, FirewallPolicy

# Per-path override, if any (inside a URL Path Map's path rules)
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).UrlPathMaps.PathRules | Select-Object Paths, FirewallPolicy
```
Most specific wins. If a path/listener has its own policy in Detection mode while the gateway-level policy is Prevention (or vice versa), the more specific one is what actually governs that request.

**6. Confirm the dedicated subnet's NSG allows the control-plane port range (v2 SKU only):**
```powershell
Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName> | Get-AzNetworkSecurityRuleConfig |
    Where-Object { $_.SourceAddressPrefix -match "GatewayManager" }
```
Expected: An Allow rule, source `GatewayManager`, destination ports `65200-65535`. Missing this produces blank/unknown backend health with no explicit deny logged — it looks like a backend problem but is a control-plane block.

---

## Common Fix Paths

<details><summary>Fix 1 — Gateway stuck in Updating / Failed provisioning state</summary>

**Symptom:** `ProvisioningState` isn't `Succeeded`; recent portal/CLI changes appear to have not completed.

```powershell
# Confirm the actual state and check for a stuck operation
Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName> | Select-Object ProvisioningState

# Re-apply the current config to force a clean re-provision (safe — does not change config)
$gw = Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>
Set-AzApplicationGateway -ApplicationGateway $gw

# If v2/autoscale SKU and this doesn't resolve within ~15 minutes, check Activity Log for the specific failure reason
Get-AzActivityLog -ResourceGroupName <rg> -StartTime (Get-Date).AddHours(-2) |
    Where-Object { $_.ResourceId -like "*$gwName*" } | Select-Object EventTimestamp, OperationName, Status
```

**Rollback:** N/A — `Set-AzApplicationGateway` with the existing config object doesn't change anything, it only re-triggers provisioning. If a specific recent change caused the stuck state, revert that change specifically (listener, rule, or backend setting) and re-apply.

</details>

<details><summary>Fix 2 — Backend health Unhealthy or Unknown</summary>

**Symptom:** `Get-AzApplicationGatewayBackendHealth` shows `Unhealthy` for some/all servers, or blank/`Unknown` for everything.

**If Unknown for ALL backends — check the 65200-65535 NSG rule first (v2 SKU):**
```powershell
Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <appGwSubnetNsg> | Get-AzNetworkSecurityRuleConfig |
    Where-Object { $_.SourceAddressPrefix -match "GatewayManager" }

# If missing, add it
Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "Allow-GatewayManager" `
    -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 `
    -SourceAddressPrefix GatewayManager -SourcePortRange * `
    -DestinationAddressPrefix * -DestinationPortRange 65200-65535
$nsg | Set-AzNetworkSecurityGroup
```

**If Unhealthy for specific backends — check probe path and expected response:**
```powershell
Get-AzApplicationGatewayProbeConfig -ApplicationGateway $gw | Select-Object Name, Path, Match, Interval, Timeout, UnhealthyThreshold

# Test the probe path directly against the backend, bypassing the gateway
curl -v -H "Host: <expected-host-header>" http://<backend-ip>:<port>/<probe-path>
```
Common causes: probe path returns a redirect to a login page (302/401, outside the default 200-399 healthy range), backend is overloaded and timing out, or the probe's expected `Match` string/status doesn't match the real response body.

**Rollback:** Revert probe configuration to the last known-working path/match string if a recent change caused this.

</details>

<details><summary>Fix 3 — WAF blocking legitimate traffic (403)</summary>

**Symptom:** Users see a distinctive WAF-branded 403; backend health is Healthy; the request never reached the backend.

```powershell
# Identify the exact rule that fired — requires Firewall diagnostic logs enabled (see Fix 6)
# In Log Analytics:
# AzureDiagnostics | where Category == "ApplicationGatewayFirewallLog" | where action_s == "Blocked" | order by TimeGenerated desc

# Add a targeted exclusion for the specific rule + match variable — do NOT disable the whole ruleset
$policy = Get-AzApplicationGatewayFirewallPolicy -ResourceGroupName <rg> -Name <policyName>
# Add a rule-specific exclusion in the portal or via the WAF policy's ManagedRules.Exclusions collection,
# scoped to the specific RequestArgNames/RequestHeaderNames causing the false positive
```

**If this is a NEW policy being rolled out:** run it in Detection mode first and review logs before switching to Prevention:
```powershell
$policy.PolicySettings.Mode = "Detection"
Set-AzApplicationGatewayFirewallPolicy -InputObject $policy
```

**Rollback:** Remove the targeted exclusion if it turns out to be too broad; switch back to Detection mode if Prevention is blocking more than expected while tuning.

</details>

<details><summary>Fix 4 — 502/504 with backend health showing Healthy</summary>

**Symptom:** Backend pool shows Healthy in `Get-AzApplicationGatewayBackendHealth`, but live requests still fail with 502 or 504.

```powershell
# Check backend HTTP settings — request timeout is a common silent cause under slow backend responses
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).BackendHttpSettingsCollection |
    Select-Object Name, RequestTimeout, Protocol, HostName, PickHostNameFromBackendAddress

# If backend protocol is HTTPS and client IP preservation is enabled, confirm the backend
# actually parses the Proxy Protocol header the gateway sends ahead of the TLS handshake —
# a backend that doesn't will intermittently fail even though the health probe (a simpler path) passes
```

**Raise the request timeout if the backend is simply slow, not broken:**
```powershell
$settings = (Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).BackendHttpSettingsCollection |
    Where-Object Name -eq "<settingsName>"
$settings.RequestTimeout = 60
Set-AzApplicationGateway -ApplicationGateway $gw
```

**Rollback:** Revert `RequestTimeout` to its prior value once the underlying backend slowness is addressed — a permanently raised timeout masks a backend performance problem rather than fixing it.

</details>

<details><summary>Fix 5 — Some paths/sites behave differently on the same gateway</summary>

**Symptom:** One path or hostname is blocked/misbehaving while others on the same Application Gateway work fine.

```powershell
# Check for a path- or listener-specific WAF policy override — most specific always wins
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).HttpListeners | Select-Object Name, FirewallPolicy
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).UrlPathMaps.PathRules | Select-Object Paths, FirewallPolicy, BackendAddressPool

# Confirm the path-based rule is actually matching the request as expected
# (path matching is case-sensitive and prefix-based by default — /api and /API are different rules)
```

**Rollback:** Remove the per-listener/per-path override to fall back to the gateway-level policy, if the override was unintentional rather than a deliberate per-site exception.

</details>

<details><summary>Fix 6 — No diagnostic logs available for investigation</summary>

**Symptom:** Backend health and WAF blocking need investigating, but no Access/Performance/Firewall log data exists.

```powershell
$gw = Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName <rg> -Name <workspaceName>

Set-AzDiagnosticSetting -ResourceId $gw.Id -WorkspaceId $workspace.ResourceId `
    -Enabled $true -Category ApplicationGatewayAccessLog, ApplicationGatewayPerformanceLog, ApplicationGatewayFirewallLog
```

**Rollback:** N/A — enabling diagnostics is non-disruptive; leave it on going forward for future troubleshooting.

</details>

<details><summary>Fix 7 — SNAT port exhaustion under high load</summary>

**Symptom:** High request volume, intermittent backend connection failures that aren't explained by backend health or WAF blocks; `Current Connections` metric is high and climbing.

```powershell
# Check the relevant metrics
Get-AzMetric -ResourceId $gw.Id -MetricName "CurrentConnections","FailedRequests","BackendConnectTime" -TimeGrain 00:01:00
```

This is a capacity/scale issue, not a misconfiguration:
- On v2/autoscale SKU, confirm autoscale min/max instance count is set high enough — SNAT ports scale per instance.
- Reduce backend connection reuse pressure by confirming Connection Draining is configured sensibly (not disabled) so recycled backend instances don't pile up new connections abruptly.
- If backend pool members are few in number relative to request volume, adding more backend instances spreads the outbound connection load.

```powershell
$gw.AutoscaleConfiguration.MinCapacity = 3
$gw.AutoscaleConfiguration.MaxCapacity = 10
Set-AzApplicationGateway -ApplicationGateway $gw
```

**Rollback:** Reduce `MaxCapacity` back down once load subsides if cost, not capability, is the concern — this doesn't affect correctness, only headroom.

</details>

---

## Escalation Evidence

```
=== Application Gateway Failure — Ticket Evidence ===

Date/Time:                  _______________
Gateway name / RG:          _______________
SKU (Standard_v2/WAF_v2):   _______________
Affected hostname/path:     _______________
Error seen by users:        _______________  (502 / 504 / WAF 403 / connection refused)

--- Commands Run ---
ProvisioningState/OperationalState:   _______________
Backend health (per server):          _______________
WAF policy mode (Detection/Prevent):  _______________
WAF policy level that applied (gateway/listener/path): _______________
NSG 65200-65535 GatewayManager rule present (Y/N):     _______________
Diagnostic logs enabled (Y/N):        _______________

--- Steps Taken ---
[ ] Checked ProvisioningState
[ ] Checked backend health per server
[ ] Distinguished WAF block vs. backend failure
[ ] Checked WAF policy precedence (path > listener > gateway)
[ ] Checked dedicated subnet NSG for GatewayManager rule
[ ] Checked SNAT/connection metrics if load-related
```

---

## 🎓 Learning Pointers

- **Blank/Unknown backend health on every server is very often the 65200-65535 NSG gap, not a backend problem.** The v2 SKU needs the `GatewayManager` service tag allowed inbound on that port range for its own control-plane health reporting — a block here doesn't produce an explicit deny log entry, it just produces no health data at all, which reads exactly like "we can't tell what's wrong with the backend." Check this before spending time on backend-side debugging. [MS Docs: Backend health troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/azure/application-gateway/application-gateway-backend-health-troubleshooting)

- **WAF policy precedence is path > listener > gateway, and the more specific override is silent.** A gateway-level policy in Prevention mode gives no indication that one path has its own Detection-mode policy quietly letting traffic through — or the reverse, where a global Detection policy is overridden by a stricter per-listener Prevention policy nobody remembers configuring. Always check all three levels for the specific hostname/path in question, not just the gateway-level policy. [MS Docs: WAF policy overview](https://learn.microsoft.com/en-us/azure/web-application-firewall/ag/policy-overview)

- **A WAF block and a backend failure look similar to an end user ("the site is down") but are diagnosed completely differently.** A WAF 403 has a distinctive body and never touches the backend at all; a 502/504 means the request reached (or tried to reach) the backend. Confirm which one you're looking at in the first 60 seconds — it changes whether you're reading WAF logs or backend health.

- **Never block outbound Internet access on the Application Gateway subnet for WAF_v2** — the WAF engine and rule set receive automatic updates over that path, and blocking it breaks WAF functionality in a way that isn't obvious from the gateway's health status. Route egress through an NVA/firewall if required by policy, but with an explicit allow for this traffic, not a default-deny.

- **The Application Gateway subnet must be dedicated — no other resource type can share it.** This is enforced at deployment time, not a best practice suggestion, and trips up anyone reusing an existing subnet for "just one more thing."
