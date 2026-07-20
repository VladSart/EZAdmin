# Entra Global Secure Access (GSA) — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers Microsoft Entra Global Secure Access (GSA) — the umbrella brand for two Security Service Edge (SSE) products:
- **Microsoft Entra Internet Access** — SWG-style protection and tunneling for Microsoft 365 traffic and general internet traffic
- **Microsoft Entra Private Access** — ZTNA-style replacement for traditional VPN, publishing on-prem/private applications through cloud connectors

Covers: client deployment, traffic forwarding profile design, Private Access connector architecture, Conditional Access network-compliance signals, and the shared identity dependency both products inherit from Entra ID.

**Assumes:**
- Microsoft Graph PowerShell SDK (beta module): `Install-Module Microsoft.Graph.Beta -Scope CurrentUser`
- Authenticated with `Connect-MgGraph` and `NetworkAccess.Read.All` / `NetworkAccess.ReadWrite.All` scopes as needed
- Tenant licensed for Microsoft Entra Suite, or standalone Internet Access / Private Access add-on licenses
- Devices are at minimum Entra ID registered (join type affects capability, not eligibility)

**Not covered:** Microsoft Defender for Cloud Apps session policies (a different product, sometimes confused with GSA due to overlapping "access" terminology), macOS GSA client-specific installation/architecture/troubleshooting (system extension + transparent proxy activation, MDM allow-listing, the June 2025 bundle-identifier migration, macOS 26 compatibility — see `macOS/Troubleshooting/GlobalSecureAccess-macOS-A.md`/`-B.md`), Windows/Android/iOS GSA client specifics (each has separate deployment mechanics), legacy on-prem App Proxy-only publishing (see `EntraID/Troubleshooting/AppProxy-B.md` — GSA Private Access and App Proxy are related but distinct publishing mechanisms that can coexist).

---
## How It Works

<details><summary>Full architecture</summary>

### The two products, one client model

GSA unifies traffic steering under a single Windows client and a single administrative concept — the **Traffic Forwarding Profile** — but the two products solve different problems and can be licensed/enabled independently:

| Aspect | Entra Internet Access | Entra Private Access |
|--------|------------------------|-----------------------|
| Problem solved | SWG-style filtering/protection for M365 + general internet traffic | ZTNA replacement for site-to-site/client VPN to private apps |
| What gets published | Nothing — it filters existing traffic | Enterprise Applications (internal hostnames/IPs/ports) |
| Backend infrastructure | Fully Microsoft-managed edge | Customer-deployed **Private Network Connectors** |
| Traffic forwarding profile | "Microsoft 365 access profile" + "Internet access profile" | "Private access profile" |
| Typical failure domain | Tenant-wide filtering policy or forwarding profile state | Per-connector or per-application publishing config |

### Traffic forwarding profiles — the master switch

A **Traffic Forwarding Profile** is a tenant-level object that determines whether a category of traffic is intercepted by the GSA client and tunneled to the Entra Private Access/Internet Access edge at all. Three profiles exist:
1. `Microsoft 365 access profile` — tunnels M365 endpoints (Exchange Online, SharePoint Online, Teams)
2. `Internet access profile` — tunnels general internet-bound traffic for SWG-style filtering
3. `Private access profile` — tunnels traffic destined for published Enterprise Applications

Each profile has its own **State** (`enabled`/`disabled`) independent of the others, and each is populated with **traffic rules** (FQDNs, IP ranges, or ports) that determine exactly what falls inside vs. outside the tunnel. A disabled profile means the client passes that traffic category straight through untouched — this is the single most common "why isn't GSA doing anything" root cause, and it looks identical to a healthy-but-unused client from the endpoint's perspective.

### Client acquisition and tunnel establishment

1. **Global Secure Access Client** is installed on the Windows device (via Intune Win32 app, typically) and installs a lightweight network filter driver plus a background service.
2. On first launch, the client performs **silent SSO** using the same WAM/PRT broker infrastructure as every other Entra-integrated experience (see `EntraID/Troubleshooting/PRT-Issues-A.md`) — there is no separate GSA-specific login. A broken PRT breaks GSA silently, with no distinct error surfaced to the user.
3. The client downloads the tenant's active Traffic Forwarding Profiles and their traffic rules from the Entra Network Access service.
4. Matching traffic is intercepted at the network filter driver layer and tunneled over a TLS-secured channel to the nearest Microsoft-managed Point of Presence (PoP).
5. For Internet Access traffic, the PoP applies configured filtering policies (Web Content Filtering, TLS inspection if enabled) before forwarding to the internet.
6. For Private Access traffic, the PoP matches the destination against published Enterprise Applications and routes the session to the correct **Connector Group** — a set of customer-deployed connectors with line-of-sight to the target resource.

### Private Access connector architecture

Connectors are lightweight Windows services deployed on a VM (on-prem or IaaS) with network line-of-sight to the resources being published. Architecturally they are the direct successor to Entra Application Proxy connectors, sharing the same core connector-to-cloud-service registration model:
- Connector registers with the Entra Network Access service over an **outbound-only** connection (no inbound firewall rule needed) — same "outbound 443 only" design as App Proxy
- Connectors are grouped into **Connector Groups**; each published application is assigned to exactly one Connector Group
- Health is reported via periodic heartbeat; a connector missing 2-3 consecutive heartbeats flips to `inactive`
- Traffic for a published app can route through **any healthy connector in the assigned group** — this gives basic HA if 2+ connectors are deployed per group, which is the recommended minimum for production

### Conditional Access network-compliance signal

GSA introduces a CA condition (`Compliant Network`) that is fundamentally different from **Named Locations**: Named Locations are IP-based and evaluated purely on source IP at sign-in time, whereas the GSA-aware CA signal asserts that the *specific request* was verified as having traversed the GSA tunnel. This makes it a stronger, session-bound signal, but it also means:
- It only works for traffic types actually being tunneled (a disabled forwarding profile means the signal never fires)
- It requires the client to be healthy and signed in at the moment of the request, not just installed
- Mixing GSA network-compliance conditions with legacy Named Location conditions in the same policy without report-only testing is the most common cause of unexpected CA lockouts in early GSA rollouts

</details>

---
## Dependency Stack

```
Entra ID (Identity)
  └── Tenant licensed for Entra Internet Access and/or Private Access
        └── Traffic Forwarding Profiles (tenant-level, per-category state)
              ├── Microsoft 365 access profile ── enabled/disabled
              ├── Internet access profile ────── enabled/disabled
              └── Private access profile ─────── enabled/disabled
                    └── Enterprise Application(s) published for Private Access
                          ├── DestinationHost / Port / Protocol definition
                          └── Assigned Connector Group
                                └── Private Network Connector(s)
                                      ├── Connector service running
                                      ├── Outbound 443 to Entra Network Access service
                                      ├── Recent heartbeat (Status = active)
                                      └── Line-of-sight to target internal resource
        └── Device
              ├── Entra ID registered / joined / hybrid joined (registered = minimum)
              ├── Valid PRT (shared identity dependency — see PRT-Issues-A.md)
              ├── Global Secure Access Client installed, service running
              ├── Client signed in (binds tunnel to identity, not just device)
              └── Local network path to nearest Microsoft PoP not blocked by conflicting VPN/proxy
        └── Conditional Access (optional layer)
              └── Policy referencing "Compliant Network" grant
                    └── Evaluated only against traffic actually traversing an enabled, healthy tunnel
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|--------------------|-------|
| No traffic tunneling for any category | Client service stopped, or PRT invalid | `Get-Service`, `dsregcmd /status` |
| M365/Internet traffic not tunneling, Private Access works | Forwarding profile for that category disabled | `Get-MgBetaNetworkAccessForwardingProfile` |
| One Private Access app unreachable, others fine | App's assigned Connector Group has zero healthy connectors | `Get-MgBetaNetworkAccessConnector` filtered by group |
| All Private Access apps unreachable | Tenant-wide Private Access profile disabled, or all connectors down | Profile state + connector fleet health |
| Client installed but never signs in / silently idle | PRT missing/expired on the device | `dsregcmd /status` — `AzureAdPrt` |
| CA policy unexpectedly blocking users after GSA rollout | Compliant Network condition mixed with legacy Named Location logic, not tested in report-only | CA policy `Conditions` + sign-in log `ConditionalAccessStatus` |
| Connector shows `active` locally but `inactive` in portal | Local firewall/NAT change broke outbound to Entra endpoints post-deployment, heartbeat stale | Outbound connectivity test from connector host |
| User reports "site slow through GSA" | TLS inspection enabled on Internet Access profile adding latency, or nearest PoP is geographically distant | Web Content Filtering / TLS inspection settings; client diagnostics |
| Newly published app not reachable immediately after config | Traffic rule/app propagation to client not yet refreshed (client polls periodically) | Restart client service to force refresh, or wait one polling interval |
| Private Access app reachable by IP but not by hostname | DNS resolution not routed through the tunnel for that app; Private DNS not configured | Client DNS settings; Private Access app search-domain configuration |

---
## Validation Steps

**1. Confirm Graph connection and scopes**
```powershell
Connect-MgGraph -Scopes "NetworkAccess.Read.All"
Get-MgContext | Select-Object Scopes
```
Expected: `NetworkAccess.Read.All` present (add `NetworkAccess.ReadWrite.All` if remediation steps will be run).

**2. Enumerate all Traffic Forwarding Profiles and state**
```powershell
Get-MgBetaNetworkAccessForwardingProfile | Select-Object Name, TrafficForwardingType, State
```
Expected: Every profile the tenant intends to use shows `State = enabled`. A disabled profile silently passes that traffic category untunneled — this is not an error condition on the client side, so it will not surface as a fault anywhere else.

**3. Enumerate Private Access connectors and health**
```powershell
Get-MgBetaNetworkAccessConnector -All |
    Select-Object MachineName, Status, Version, LastHeartbeat, ConnectorGroupId |
    Sort-Object Status
```
Expected: All `Status = active`, `LastHeartbeat` within the last few minutes. Group by `ConnectorGroupId` to confirm every group has at least 2 healthy connectors for HA.

**4. Enumerate published Enterprise Applications and their connector group assignment**
```powershell
Get-MgBetaNetworkAccessApplication -All |
    Select-Object DisplayName, DestinationHost, DestinationPort, Protocol, ConnectorGroupId
```
Expected: Every production app has a valid `ConnectorGroupId` pointing to a group with healthy connectors (cross-reference against Step 3's output).

**5. Confirm client-side device identity health**
```powershell
dsregcmd /status | Select-String "AzureAdJoined|WorkplaceJoined|AzureAdPrt|AzureAdPrtUpdateTime"
```
Expected: At minimum `WorkplaceJoined : YES` (registered), and `AzureAdPrt : YES`. GSA piggybacks entirely on this identity plumbing — a broken PRT breaks GSA with no GSA-specific error message.

**6. Confirm client service and recent traffic tunneling**
```powershell
Get-Service "Global Secure Access Client" | Select-Object Name, Status, StartType
Get-WinEvent -LogName "Microsoft-Global Secure Access Client/Operational" -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message
```
Expected: `Status = Running`. Recent operational log entries with no repeated `Error` level events for tunnel establishment.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Client-Side Triage (on the affected device)

1. Confirm the GSA client service is installed and running (`Get-Service`)
2. Confirm device identity health — `dsregcmd /status`, specifically `AzureAdPrt`
3. Check the client's operational event log for tunnel-establishment errors
4. Confirm no conflicting VPN client or proxy configuration is forcing traffic around the GSA tunnel

### Phase 2 — Tenant Configuration (forwarding profiles and policy)

1. Confirm the relevant Traffic Forwarding Profile is `enabled` for the traffic category in question
2. Review the traffic rules inside that profile — a profile can be enabled but scoped too narrowly to include the traffic being tested
3. Confirm no Conditional Access policy is unexpectedly blocking the sign-in that GSA depends on (silent SSO failure looks identical to a client bug)

### Phase 3 — Private Access Publishing (app-specific issues only)

1. Confirm the target Enterprise Application is actually published with the correct `DestinationHost`/port/protocol
2. Confirm the app's assigned Connector Group has at least one healthy connector
3. If reachable by IP but not hostname, check whether DNS for that namespace is configured to resolve through the tunnel (Private DNS / search domain configuration on the Private Access profile)

### Phase 4 — Connector Infrastructure (Private Access systemic issues)

1. On the connector host, confirm the connector service is running
2. Test outbound connectivity from the connector host to `login.microsoftonline.com` and the Entra Network Access service endpoints — these must not be blocked by any on-prem firewall/proxy change made after initial deployment
3. Check `LastHeartbeat` staleness — a connector that's running locally but shows `inactive` in the portal almost always means an outbound network path broke, not a service crash
4. Confirm at least 2 connectors are healthy per group in production — single-connector groups have no failover

### Phase 5 — Conditional Access Interaction

1. Filter sign-in logs by the affected user and look for `ConditionalAccessStatus = failure` correlated with policies referencing the Compliant Network grant
2. Confirm any such policy was piloted in report-only mode before enforcement — check the policy's `State` and modification history
3. If the policy blends GSA network-compliance conditions with legacy Named Locations, separate the two into distinct test policies to isolate which condition is actually failing

---
## Remediation Playbooks

<details><summary>Playbook 1 — Systemic "nothing is tunneling" across many devices</summary>

Use when: Multiple users report GSA appears to do nothing (no filtering, no Private Access), independent of device.

```powershell
# Step 1: Confirm this is a tenant config issue, not a per-device fault
Get-MgBetaNetworkAccessForwardingProfile | Select-Object Name, State

# Step 2: If any expected profile shows "disabled", enable it
$profile = Get-MgBetaNetworkAccessForwardingProfile | Where-Object Name -eq "Internet access profile"
Update-MgBetaNetworkAccessForwardingProfile -ForwardingProfileId $profile.Id -BodyParameter @{ state = "enabled" }

# Step 3: Confirm change propagated — clients poll periodically, allow a few minutes
# then re-check tunnel establishment on one test device before declaring fixed tenant-wide
```

**Rollback:** Re-disabling the profile is non-destructive and reverts traffic to direct routing — no persistent client-side state to clean up.

</details>

<details><summary>Playbook 2 — Private Access application unreachable, connectors otherwise healthy</summary>

Use when: One specific published app is unreachable but the assigned connector group shows healthy connectors and other apps through the same group work.

```powershell
# Step 1: Re-confirm the exact publishing config for the affected app
Get-MgBetaNetworkAccessApplication -All |
    Where-Object DisplayName -eq "<app-display-name>" |
    Select-Object DisplayName, DestinationHost, DestinationPort, Protocol, ConnectorGroupId

# Step 2: Test line-of-sight from a connector in the assigned group directly (not through GSA)
# On the connector host:
Test-NetConnection -ComputerName "<destination-host>" -Port <destination-port>

# Step 3: If line-of-sight fails from the connector itself, this is a network/firewall
# problem between the connector and the target resource — not a GSA configuration issue.
# Fix routing/firewall rules on the connector's network segment.

# Step 4: If line-of-sight succeeds from the connector but still fails through the tunnel,
# check for a hostname vs. IP mismatch — Private Access matches on the exact DestinationHost
# configured; a CNAME or load-balancer VIP mismatch here is a common miss.
```

**Rollback:** N/A — diagnostic steps only. Any publishing config correction is a config update, not a destructive operation.

</details>

<details><summary>Playbook 3 — Recover a Private Access connector group with zero healthy connectors</summary>

Use when: An entire connector group has dropped to `inactive`, breaking every app assigned to it.

```powershell
# Step 1: Confirm scope of the outage
Get-MgBetaNetworkAccessConnector -All |
    Where-Object ConnectorGroupId -eq "<group-id>" |
    Select-Object MachineName, Status, LastHeartbeat

# Step 2: On each connector host, check and restart the service
Get-Service "Microsoft Entra private network connector" | Select-Object Name, Status
Restart-Service "Microsoft Entra private network connector" -Force

# Step 3: Confirm outbound connectivity from each host (same endpoints App Proxy connectors need)
Test-NetConnection -ComputerName "login.microsoftonline.com" -Port 443
Test-NetConnection -ComputerName "graph.microsoft.com" -Port 443

# Step 4: If restart doesn't restore heartbeat within ~5 minutes, redeploy the connector
# agent from the admin center (Global Secure Access > Connectors > Download connector)
# rather than continuing to troubleshoot the existing install
```

**Rollback:** Restarting the service briefly interrupts all traffic through that connector — coordinate timing if it's the sole connector in the group. Redeployment is additive; the old registration can be removed from the portal once the new connector is confirmed healthy.

</details>

<details><summary>Playbook 4 — Untangle a Conditional Access lockout caused by Compliant Network rollout</summary>

Use when: Users were locked out after a CA policy referencing GSA's Compliant Network grant went into enforced mode.

```powershell
# Step 1: Identify the policy and set it back to report-only immediately to stop the bleeding
$policy = Get-MgIdentityConditionalAccessPolicy | Where-Object DisplayName -like "*Compliant Network*"
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id -BodyParameter @{
    state = "enabledForReportingButNotEnforced"
}

# Step 2: Review sign-in logs during the enforced window to identify the true failure pattern
Get-MgAuditLogSignIn -Filter "createdDateTime ge <window-start>" |
    Where-Object { $_.ConditionalAccessStatus -eq "failure" } |
    Select-Object UserPrincipalName, AppDisplayName, ConditionalAccessStatus, CreatedDateTime

# Step 3: Cross-reference affected users' Traffic Forwarding Profile coverage —
# users whose devices never had the relevant profile enabled will always fail
# a Compliant Network check regardless of client health

# Step 4: Once root cause is confirmed and profile/client coverage is fixed tenant-wide,
# re-pilot in report-only against a small group before re-enforcing broadly
```

**Rollback:** Setting the policy to report-only is itself the rollback — it stops enforcement immediately without deleting the policy or losing configuration.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Global Secure Access diagnostic evidence for a tenant-wide or per-user escalation
.NOTES     Requires Microsoft.Graph.Beta module and NetworkAccess.Read.All scope
#>

param(
    [string]$UserPrincipalName = ""
)

$outputPath = "C:\GSA_Diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

# Traffic forwarding profile state
Get-MgBetaNetworkAccessForwardingProfile |
    Select-Object Name, TrafficForwardingType, State | Export-Csv "$outputPath\forwarding_profiles.csv" -NoTypeInformation

# Connector fleet health
Get-MgBetaNetworkAccessConnector -All |
    Select-Object MachineName, Status, Version, LastHeartbeat, ConnectorGroupId | Export-Csv "$outputPath\connector_health.csv" -NoTypeInformation

# Published applications
Get-MgBetaNetworkAccessApplication -All |
    Select-Object DisplayName, DestinationHost, DestinationPort, Protocol, ConnectorGroupId | Export-Csv "$outputPath\published_apps.csv" -NoTypeInformation

# Per-user sign-in correlation (optional)
if ($UserPrincipalName -ne "") {
    Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$UserPrincipalName'" -Top 20 |
        Select-Object CreatedDateTime, AppDisplayName, ConditionalAccessStatus, Status |
        Export-Csv "$outputPath\user_signins.csv" -NoTypeInformation
}

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# List all traffic forwarding profiles and state
Get-MgBetaNetworkAccessForwardingProfile | Select Name,TrafficForwardingType,State

# Enable a specific forwarding profile
Update-MgBetaNetworkAccessForwardingProfile -ForwardingProfileId "<id>" -BodyParameter @{ state = "enabled" }

# List all Private Access connectors with health
Get-MgBetaNetworkAccessConnector -All | Select MachineName,Status,LastHeartbeat,ConnectorGroupId

# List connector groups
Get-MgBetaNetworkAccessConnectorGroup | Select Name,Region

# List published Enterprise Applications for Private Access
Get-MgBetaNetworkAccessApplication -All | Select DisplayName,DestinationHost,DestinationPort,ConnectorGroupId

# On-device: check client service
Get-Service "Global Secure Access Client" | Select Name,Status,StartType

# On-device: check identity/PRT (GSA's hidden dependency)
dsregcmd /status | Select-String "AzureAdPrt|AzureAdJoined|WorkplaceJoined"

# On-device: GSA client operational log
Get-WinEvent -LogName "Microsoft-Global Secure Access Client/Operational" -MaxEvents 50

# On connector host: check/restart connector service
Get-Service "Microsoft Entra private network connector"
Restart-Service "Microsoft Entra private network connector" -Force

# CA policy — set to report-only (fastest lockout mitigation)
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId "<id>" -BodyParameter @{ state = "enabledForReportingButNotEnforced" }

# Sign-in logs filtered to Conditional Access failures
Get-MgAuditLogSignIn -Filter "createdDateTime ge <timestamp>" | Where-Object ConditionalAccessStatus -eq "failure"
```

---
## 🎓 Learning Pointers

- **GSA is two products sharing one client and one profile framework, not one product**: Internet Access and Private Access are licensed and enabled independently — always confirm which product the reported issue actually touches (filtering vs. app publishing) before choosing a troubleshooting path. Reference: [What is Global Secure Access](https://learn.microsoft.com/en-us/entra/global-secure-access/overview-what-is-global-secure-access)
- **The forwarding profile is a silent on/off switch with no user-facing error**: A disabled profile doesn't fail loudly — traffic simply routes as if GSA weren't installed at all. This makes it the highest-value first check in any "GSA isn't doing anything" ticket. Reference: [Traffic forwarding profiles](https://learn.microsoft.com/en-us/entra/global-secure-access/concept-traffic-forwarding)
- **Private Access connectors are architecturally App Proxy's successor**: Same outbound-only registration model, same connector-group HA pattern, same class of "active locally, inactive in portal" failure mode caused by a network path change post-deployment. Treat diagnosis the same way as `EntraID/Troubleshooting/AppProxy-A.md`. Reference: [Private network connectors](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-configure-connectors)
- **PRT is GSA's invisible dependency**: Because the client relies entirely on the existing WAM/PRT broker for silent sign-in, a broken PRT produces a GSA client that looks installed and running but never actually tunnels anything — always rule out `EntraID/Troubleshooting/PRT-Issues-A.md` before assuming a GSA-specific fault.
- **Compliant Network is a session-bound signal, not an IP-based one**: Unlike Named Locations, this CA condition only evaluates true for traffic actually verified as tunneled through GSA at the time of the request — pilot any policy using it in report-only mode first, since it interacts poorly with assumptions carried over from Named Location design. Reference: [Conditional Access network compliance](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-target-resources-conditional-access)
- **Client polling means config changes aren't instant**: Newly published apps or profile changes take one client polling interval to reach devices — don't declare a fix broken until you've allowed a few minutes (or forced a client service restart) for the new config to actually land.
