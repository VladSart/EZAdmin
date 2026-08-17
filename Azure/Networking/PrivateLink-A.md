# Azure Private Link / Private Endpoints — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the DNS-resolution and approval-workflow architecture, not just the fix commands.

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
- Private Endpoints as the client-side network object — the NIC-with-a-private-IP that brings a supported PaaS resource (or a third-party Private Link Service) into a VNet
- The connection approval workflow (Automatic vs. Manual; Pending/Approved/Rejected/Disconnected states) and who owns each action
- Private DNS zone integration — the `privatelink.*` reserved naming convention, Zone Groups, Virtual Network Links, and the six documented DNS resolution topologies (single VNet, peered/hub-and-spoke, on-prem via forwarder, Azure Private Resolver in its three configurations)
- Network policies (NSG/UDR/ASG support) on the Private Endpoint's own subnet — off by default, and what changes when enabled
- Multi-service, multi-region, and hub-and-spoke DNS architecture patterns

**Out of scope:**
- **Private Link Service (the provider side)** — publishing your own service behind a Standard Load Balancer for others to consume via Private Link. This topic covers the consumer/client side only (creating and troubleshooting a Private Endpoint against someone else's — including Microsoft's — service).
- **Azure Front Door's Private Link origins (Premium tier)** — a specific, REVERSED application of this mechanism (Front Door itself is the consumer, creating the PE from its own managed VNet rather than a customer VNet) — now its own dedicated topic in `FrontDoorPrivateLink-A.md`/`FrontDoorPrivateLink-B.md`. The general connection-state-machine concepts here still apply; the reversed-consumer architecture, origin-type support list, and PE-reuse-by-tuple mechanics are Front-Door-specific and documented there instead.
- **Service Endpoints** — an older, architecturally distinct mechanism (extends the VNet's identity to a service over the Microsoft backbone via route injection, but keeps the resource's public IP and requires no NIC in the VNet). Referenced only for disambiguation — see Learning Pointers.
- **Azure DNS Private Resolver's own deployment/scaling/health troubleshooting as a standalone topic** — covered here only as the client-side integration point for on-premises resolution; a dedicated Private Resolver topic is a plausible future candidate if ticket volume justifies deeper coverage of the resolver's own ruleset/endpoint architecture.
- **Per-service private-link resource quirks** (e.g., Azure SQL Managed Instance's specific subnet delegation model, Azure Cosmos DB's per-API sub-resource list) — this topic covers the DNS/approval/network-policy mechanics common to every service; consult the specific service's own documentation for resource-type-specific subresource names and prerequisites.

**Assumptions:**
- Reader has Network Contributor (client side) and/or ownership/delegated approval rights on the target private-link resource
- At least one VNet with a subnet available for Private Endpoint deployment
- Familiarity with `PrivateDNS-A.md`/`PrivateDNS-B.md`'s general zone/link architecture — this topic layers Private Endpoint-specific mechanics (Zone Groups, approval workflow) on top of that foundation rather than re-explaining it from scratch

---

## How It Works

<details><summary>Full architecture</summary>

### What a Private Endpoint Actually Is

A Private Endpoint is a special-purpose network interface (NIC), automatically created and managed for the lifecycle of the Private Endpoint resource, that receives a **static, dynamically-assigned-once private IP address** from a subnet in your VNet. That NIC is bound to one specific **private-link resource** (an Azure PaaS resource like Storage, Key Vault, or SQL Database — or a third party's own service published via Private Link Service) and, for services with multiple data planes, one specific **subresource** (e.g., Storage's `blob`, `file`, `table`, `queue`, `web`, and `dfs` sub-resources each require their own separate Private Endpoint — one PE per subresource, not one PE covering the whole storage account).

Connections are strictly **one-directional**: only the client side can initiate a connection to the Private Endpoint. The service provider has no routing configuration that lets it reach back into the customer's network — this is a deliberate security property of the architecture, not a limitation to work around.

### The Private-Link Resource Table (Selected High-Frequency Services)

Not every Azure service supports Private Link, and support is tracked per resource type + subresource. Frequently encountered in MSP environments:

| Service | Resource Type | Subresources |
|---|---|---|
| Azure Storage | `Microsoft.Storage/storageAccounts` | blob, file, table, queue, web, dfs (+ `_secondary` variants) |
| Azure Key Vault | `Microsoft.KeyVault/vaults` | vault |
| Azure SQL Database | `Microsoft.Sql/servers` | sqlServer |
| Azure SQL Managed Instance | `Microsoft.Sql/managedInstances` | managedInstance |
| Azure App Service | `Microsoft.Web/sites` | sites |
| Azure Monitor (Log Analytics/App Insights) | `Microsoft.Insights/privatelinkscopes` | azuremonitor |
| Azure Cosmos DB | `Microsoft.DocumentDB/databaseAccounts` | Sql, MongoDB, Cassandra, Gremlin, Table, Analytical |
| Azure Container Registry | `Microsoft.ContainerRegistry/registries` | registry |
| Azure Backup (Recovery Services) | `Microsoft.RecoveryServices/vaults` | AzureBackup, AzureSiteRecovery |

A private-link resource can be deployed in a **different region** than the VNet/Private Endpoint consuming it — regional co-location is not required, only that the Private Endpoint itself deploys in the same region and subscription as its VNet.

### The Connection Approval Workflow

Every Private Endpoint's link to its target resource carries a **connection state**, independent of the Private Endpoint resource's own provisioning state:

- **Approved** — the only state that carries traffic. Set automatically if the requester holds the specific `Microsoft.<Provider>/<resource_type>/privateEndpointConnectionsApproval/action` permission on the target resource (same-subscription same-owner is the common case), or manually by the resource owner otherwise.
- **Pending** — created via the manual-request path (no automatic-approval permission, or connecting via an **alias** to a third-party Private Link Service). The endpoint exists, has its private IP, and DNS may even already be configured — but zero traffic flows until the owner acts. This is the state most likely to be mistaken for "it's basically working" when it isn't working at all.
- **Rejected** — the owner explicitly declined the request. Not reversible in place; the requester must delete and recreate the Private Endpoint to try again.
- **Disconnected** — the owner removed an existing (previously Approved) connection from their side. The Private Endpoint object survives on the client side in an inert state and should be deleted for cleanup — it cannot be reconnected without recreation.

Only the private-link resource **owner** can Approve, Reject, or Delete a connection from their side; the Private Endpoint **consumer** can only Delete their own endpoint object.

### DNS Integration — Why This Is the Most Common Real-World Failure Point

A private-link-enabled service's FQDN **already resolves publicly** to a public IP by default — nothing about creating a Private Endpoint changes that automatically. Separate DNS configuration, almost always via a **private DNS zone**, is required to make the same FQDN resolve to the Private Endpoint's private IP instead. Skipping or misconfiguring this step is, by a wide margin, the most common real-world Private Link support ticket: the endpoint is created, approved, and network-reachable, but clients still resolve and connect to the public endpoint (or fail entirely if public access is separately disabled).

**Reserved zone naming is mandatory and per-service**: each supported service has an exact, Microsoft-documented `privatelink.<service-suffix>` zone name (e.g., `privatelink.blob.core.windows.net` for Storage blob, `privatelink.vaultcore.azure.net` for Key Vault). Using a different, custom zone name for the actual public suffix will not be picked up by the automatic Zone Group mechanism and requires entirely manual record management.

**The Private DNS Zone Group** is the automation layer that removes the need to hand-script DNS record creation/maintenance: attaching a Zone Group to a Private Endpoint tells Azure to automatically create and maintain the A record(s) in the specified zone(s), and to keep them in sync on changes (region additions/removals, IP changes on recreation). Without a Zone Group, DNS for that endpoint is either entirely unmanaged or dependent on manually-created records that will silently drift stale.

**Zone Group constraints** (all enforced, not just recommended): up to five zones per Zone Group; only one private DNS zone per zone *name* per group (can't attach two different `privatelink.blob.core.windows.net` zone resources to the same group); only one Zone Group per Private Endpoint total.

**A critical, easy-to-violate rule**: never place DNS records for two *different* Azure services in the same private DNS zone, even if doing so seems administratively convenient. Each Private Endpoint's Zone Group deployment treats "its" record set as authoritative and will overwrite/delete conflicting entries left by a different service's Zone Group on its next reconciliation pass. The result is a working Private Endpoint that mysteriously breaks the moment an unrelated Private Endpoint for a different service is deployed against the same shared zone.

### DNS Resolution Topologies

Microsoft documents six supported resolution scenarios, differentiated by whether an Azure Private Resolver is in the path and whether the client is inside Azure or on-premises:

1. **Single VNet, no Private Resolver** — client queries Azure's own DNS service (`168.63.129.16`), which natively resolves the zone linked to that VNet. Simplest, most common case.
2. **Peered VNets, no Private Resolver** — extend the same private DNS zone with a Virtual Network Link to every peered VNet needing resolution. **A single shared zone, not one zone per VNet** — creating duplicate zones with the same name per VNet requires manual record merging Microsoft explicitly warns against.
3. **On-premises via a DNS forwarder, no Private Resolver** — a DNS-forwarder-capable VM (or Azure Firewall's DNS proxy feature) deployed in a VNet linked to the zone, with on-premises DNS conditionally forwarding the zone's **public** suffix (e.g., `database.windows.net`, not `privatelink.database.windows.net`) to that forwarder.
4. **Azure Private Resolver for on-premises workloads** — replaces the forwarder VM with a managed service; on-premises DNS conditionally forwards to the Private Resolver's inbound endpoint instead.
5. **Azure Private Resolver with on-premises DNS forwarder** — same as #4, extended for environments with an existing on-prem DNS solution that itself needs the conditional-forward rule pointed at the resolver.
6. **Azure Private Resolver for both VNet and on-premises workloads** — a single shared private DNS zone serves both on-prem and Azure-native clients simultaneously via the resolver, with **one zone required across the whole topology** — the same "don't fragment the zone" principle as scenario 2, extended to hybrid.

**The forwarding direction matters and is a frequent source of misconfiguration**: conditional forwarders must point at the **public** DNS suffix (`database.windows.net`), never at the `privatelink.` prefixed zone name directly — forwarding at the `privatelink.` name breaks the resolution chain Azure DNS expects.

### Network Policies — Why NSG Rules on a PE Subnet Sometimes Do Nothing

By default, **network policies are disabled** for every subnet with respect to Private Endpoint traffic. This isn't a permissive default rule — it's a structural exemption: NSG, UDR, and ASG (Application Security Group) enforcement are simply **not evaluated at all** for traffic to/from a Private Endpoint on that subnet until `PrivateEndpointNetworkPolicies` is explicitly set to `Enabled`. An administrator who adds an NSG deny rule targeting a Private Endpoint's subnet, sees no effect, and concludes the NSG is broken has usually just discovered this default.

Once enabled, several documented limitations apply that don't affect normal VM traffic on the same subnet:
- Effective routes and effective security rules are **not displayed** in the portal for the Private Endpoint's own NIC (the underlying enforcement still applies — this is a visibility gap in tooling, not a functional one).
- NSG flow logs are **unsupported** for inbound traffic destined to a Private Endpoint.
- Outbound traffic **denied** from a Private Endpoint is not a meaningful scenario — the service provider side has no ability to originate a connection back in, by the one-directional architecture described above.
- Some services (Cosmos DB is Microsoft's own documented example) may require **all destination ports open** in NSG rules due to how their data-plane connections negotiate ports — a narrowly-scoped port rule can silently break connectivity to those specific services even with network policies correctly enabled.
- A small number of Azure regions do not support network policies for Private Endpoints at all as of this writing (West India, Australia Central 2, South Africa West, Brazil Southeast, all Government and China regions) — confirm regional support before troubleshooting an NSG that "should" be working.

### Static IP Limitations

A small set of private-link resource types do not currently support specifying a static private IP for their Private Endpoint (the platform still assigns one, but you can't pin a specific address in advance): Azure Kubernetes Service, Azure Application Gateway, HDInsight, Recovery Services Vaults, and third-party Private Link services in general. Relevant when planning IP address management/documentation for a client environment expecting predictable addressing.

</details>

---

## Dependency Stack

```
Private-link resource supports Private Link for the specific subresource needed
   (per-subresource, not per-service — e.g., Storage blob vs. file are separate PEs)
        │
Private Endpoint created — one static private IP for its lifetime, in a client subnet
   (same region + subscription as the VNet; the target resource may be in a different region)
        │
Connection approval state = Approved
   (Automatic if requester holds privateEndpointConnectionsApproval/action; Manual/Pending otherwise —
    Pending/Rejected/Disconnected all carry ZERO traffic regardless of how complete the rest looks)
        │
Private DNS Zone Group attached to the Private Endpoint
   (the automation layer; without it, DNS is unmanaged or manually/fragile-scripted)
        │
Private DNS Zone uses the EXACT reserved privatelink.<service> name — never shared across
   two DIFFERENT services in the same zone (each service's Zone Group reconciliation will
   overwrite a conflicting record left by another service)
        │
Virtual Network Link connects the zone to EVERY VNet needing resolution
   (peering NEVER implies a link — one shared zone extended by links, not duplicate zones)
        │
[On-premises clients] DNS forwarding path — forwarder VM or Azure Private Resolver,
   conditionally forwarding the PUBLIC suffix (never the privatelink.-prefixed name) —
   on-prem cannot query 168.63.129.16 directly
        │
Client resolves FQDN → private IP → traffic reaches the Private Endpoint NIC
        │
[If NSG/UDR enforcement required] PrivateEndpointNetworkPolicies = Enabled on the subnet
   (Disabled by default = NSG/UDR structurally not evaluated for this traffic at all)
        │
Traffic reaches the private-link resource
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| DNS resolves the FQDN to a public IP, not the private IP | Missing/empty Private DNS Zone Group, or the zone isn't linked to the client's VNet | `PrivateDnsZoneGroup` on the endpoint; `Get-AzPrivateDnsVirtualNetworkLink` for the client's VNet |
| Endpoint exists, DNS even looks correct, but zero traffic flows | Connection state is Pending/Rejected/Disconnected, not Approved | `PrivateLinkServiceConnectionState.Status` |
| A previously-working endpoint suddenly resolves incorrectly right after an unrelated PE was deployed | Two services' records sharing one private DNS zone; the new PE's Zone Group overwrote the old record | `Get-AzPrivateDnsRecordSet` — look for records not belonging to the expected service |
| Resolution and connectivity work in the hub VNet but not a peered spoke | VNet peering doesn't create a DNS zone link; the spoke needs its own explicit link | `Get-AzPrivateDnsVirtualNetworkLink` for the spoke's VNet specifically |
| NSG rule added to the PE subnet has no visible effect at all | `PrivateEndpointNetworkPolicies` disabled (default) — NSG/UDR not evaluated for PE traffic | Subnet's `PrivateEndpointNetworkPolicies` property |
| On-premises clients can't resolve, VNet-native clients resolve fine | No DNS forwarding path from on-prem into the zone (168.63.129.16 isn't reachable from on-prem directly) | Confirm a forwarder VM or Azure Private Resolver exists and on-prem conditional forwarding targets it |
| On-prem conditional forwarder configured but still failing | Forwarding rule points at the `privatelink.`-prefixed zone name instead of the public suffix | Confirm the forwarder targets e.g. `database.windows.net`, not `privatelink.database.windows.net` |
| Connectivity works for most operations on a service but fails for specific data-plane calls | Some services (Cosmos DB is Microsoft's documented example) need a broader port range than a narrow NSG rule allows even with network policies enabled | Confirm the service's own documented port requirements against the NSG rule scope |
| Static private IP was requested but the portal won't allow it | Resource type is one of the documented static-IP-unsupported types (AKS, App Gateway, HDInsight, Recovery Services Vaults, most 3rd-party PLS) | Confirm resource type against the known limitation list |
| Duplicate zones with the same name created for different VNets, records not merging | Microsoft's model expects ONE shared zone extended by links, not one zone per VNet | Consolidate to a single zone; delete the duplicate and re-link affected VNets |
| Effective routes/security rules blank for the PE's own NIC in the portal | Documented tooling limitation — effective routes/rules aren't displayed for PE NICs even when policies are enabled and enforced | Not a functional bug; verify enforcement via actual connectivity/NSG flow tests instead |

---

## Validation Steps

**1. Confirm the private-link resource and subresource actually support Private Link:**
```powershell
Get-AzPrivateLinkResource -PrivateLinkResourceId <targetResourceId>
```
Confirms the exact `GroupId` (subresource name) required when creating the connection — using the wrong subresource name is a common creation-time error for multi-subresource services like Storage.

**2. Confirm connection approval state:**
```powershell
(Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>).PrivateLinkServiceConnections |
    Select-Object Name, PrivateLinkServiceConnectionState
```
Expected: `Status = Approved`. Anything else means zero traffic regardless of DNS/network correctness.

**3. Confirm DNS Zone Group presence and target zone:**
```powershell
(Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>).PrivateDnsZoneGroup
```
Expected: at least one zone config present, referencing the exact reserved `privatelink.*` zone name for the service.

**4. Confirm the zone's Virtual Network Links cover every VNet that needs resolution:**
```powershell
Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <rg> -ZoneName <privatelinkZoneName> |
    Select-Object Name, VirtualNetworkId, VirtualNetworkLinkState
```
Expected: every client VNet (including peered spokes, not just the hub or the PE's own VNet) present with `LinkState = Completed`.

**5. Confirm the zone's record set doesn't contain unexpected entries from another service:**
```powershell
Get-AzPrivateDnsRecordSet -ResourceGroupName <rg> -ZoneName <privatelinkZoneName> -RecordType A
```
Expected: A records matching only the service this zone is named for.

**6. Confirm actual end-to-end resolution from a representative client:**
```powershell
Resolve-DnsName -Name <resourceFqdn>
```
Expected: a private IP (10.x/172.16-31.x/192.168.x) matching the Private Endpoint's assigned address, not the resource's public IP.

**7. Confirm network policy state on the subnet if NSG/UDR enforcement is expected:**
```powershell
(Get-AzVirtualNetworkSubnetConfig -ResourceId <subnetId>).PrivateEndpointNetworkPolicies
```
Expected: `Enabled` if NSG/UDR enforcement on PE traffic is a stated requirement; `Disabled` (default) otherwise is normal, not a fault.

---

## Troubleshooting Steps (by phase)

### Phase 1: Resource and Connection State

1. Confirm the target private-link resource and subresource genuinely support Private Link — check the platform-specific subresource list, not just "does this service support Private Link at all."
2. Confirm connection state is `Approved`. If `Pending`, identify and act on the owner side. If `Rejected`/`Disconnected`, plan recreation rather than trying to reverse the state in place.

### Phase 2: DNS Resolution

1. Confirm a Zone Group is attached, referencing the correct reserved `privatelink.*` zone name.
2. Confirm every VNet needing resolution has its own explicit Virtual Network Link to that zone — check peered/spoke VNets specifically, not just the zone's origin VNet.
3. Confirm the zone's record set isn't contaminated by a second service's records.
4. Test actual resolution from a representative client in each VNet that needs it.

### Phase 3: On-Premises Resolution (if applicable)

1. Confirm a DNS forwarder (VM or Azure Private Resolver) exists in a VNet linked to the zone.
2. Confirm on-premises conditional forwarding targets the **public** suffix, not the `privatelink.`-prefixed name.
3. Test resolution from an actual on-premises client, not just from the forwarder itself.

### Phase 4: Network Path

1. If NSG/UDR enforcement is expected on the PE subnet, confirm `PrivateEndpointNetworkPolicies` is `Enabled` — this is off by default and a common source of "the NSG isn't working" confusion.
2. For services with documented broad-port-range requirements (Cosmos DB, notably), confirm the NSG rule scope matches the service's actual requirement rather than a narrowly-guessed port list.
3. Confirm regional support for network policies if troubleshooting in one of the documented unsupported regions.

### Phase 5: Multi-Region / Scale Considerations

1. For services spanning multiple regions with their own Private Endpoints, confirm the Zone Group correctly reflects the current region set — Zone Groups automatically update records as regions are added/removed, but a stale manual record predating Zone Group adoption can coexist incorrectly.
2. In hub-and-spoke topologies, confirm the zone is centrally hosted in the hub (Microsoft's own recommended pattern) with links extended to each spoke, rather than duplicated per spoke.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield Private Endpoint deployment with full DNS automation</summary>

```powershell
# 1. Confirm the exact subresource (GroupId) required
Get-AzPrivateLinkResource -PrivateLinkResourceId <targetResourceId>

# 2. Create the Private Endpoint with an automatic-approval connection (requires owning the target)
$plsConnection = New-AzPrivateLinkServiceConnection -Name "pe-connection" `
    -PrivateLinkServiceId <targetResourceId> -GroupId <subresourceGroupId>

$pe = New-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName> -Location <location> `
    -Subnet $subnet -PrivateLinkServiceConnection $plsConnection

# 3. Create (if needed) and link the reserved private DNS zone
New-AzPrivateDnsZone -ResourceGroupName <rg> -Name <privatelinkZoneName>
New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <rg> -ZoneName <privatelinkZoneName> `
    -Name "link-$vnetName" -VirtualNetworkId $vnet.Id

# 4. Attach the Zone Group for automatic record management
$zoneConfig = New-AzPrivateDnsZoneConfig -Name 'default-config' `
    -PrivateDnsZoneId (Get-AzPrivateDnsZone -ResourceGroupName <rg> -Name <privatelinkZoneName>).ResourceId
New-AzPrivateDnsZoneGroup -ResourceGroupName <rg> -PrivateEndpointName <peName> `
    -Name 'default' -PrivateDnsZoneConfig $zoneConfig

# 5. Validate
Resolve-DnsName -Name <resourceFqdn>
```

**Rollback:** `Remove-AzPrivateEndpoint` cleanly removes the endpoint and its NIC; the DNS zone/link can be left in place for reuse by future endpoints against the same service.

</details>

<details><summary>Playbook 2 — Hub-and-spoke centralized DNS pattern for multiple VNets</summary>

```powershell
# Host the zone in the hub subscription/resource group (Microsoft's recommended pattern)
New-AzPrivateDnsZone -ResourceGroupName <hubRg> -Name <privatelinkZoneName>

# Link the hub VNet itself
New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <hubRg> -ZoneName <privatelinkZoneName> `
    -Name "link-hub" -VirtualNetworkId $hubVnet.Id

# Link EVERY spoke VNet individually — peering does not do this automatically
foreach ($spoke in $spokeVnets) {
    New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <hubRg> -ZoneName <privatelinkZoneName> `
        -Name "link-$($spoke.Name)" -VirtualNetworkId $spoke.Id
}

# Attach the Zone Group on the Private Endpoint (which can live in the hub or a spoke) to this single zone
```

**Rollback:** Remove individual `VirtualNetworkLink` resources for spokes being decommissioned; the shared zone and other spokes' links are unaffected.

</details>

<details><summary>Playbook 3 — Bridge on-premises resolution via Azure DNS Private Resolver</summary>

```powershell
# 1. Deploy the Private Resolver into a VNet already linked to the target private DNS zone(s)
New-AzDnsResolver -ResourceGroupName <rg> -Name <resolverName> -Location <location> -VirtualNetworkId $vnet.Id

# 2. Create an inbound endpoint — this is what on-premises DNS will conditionally forward to
New-AzDnsResolverInboundEndpoint -ResourceGroupName <rg> -DnsResolverName <resolverName> `
    -Name "inbound-endpoint" -Location <location> -IPConfiguration @{Subnet=@{Id=$inboundSubnet.Id}}

# 3. On-premises DNS: add a conditional forwarder for the PUBLIC suffix (never privatelink.-prefixed)
#    pointed at the inbound endpoint's IP — this step happens in the on-prem DNS infrastructure,
#    not in Azure, and is the step most often gotten backwards (forwarding the privatelink. name instead)

# 4. Validate from an actual on-premises client, not from inside Azure
Resolve-DnsName -Name <resourceFqdn>  # run FROM an on-prem machine
```

**Rollback:** Removing the resolver's inbound endpoint or the resolver itself reverts on-prem clients to public resolution (or failure, if public access is disabled) — coordinate with a maintenance window since this affects live resolution paths.

</details>

<details><summary>Playbook 4 — Fleet-wide Private Endpoint / DNS integration audit</summary>

```powershell
Get-AzPrivateEndpoint | ForEach-Object {
    $pe = $_
    $connState = $pe.PrivateLinkServiceConnections[0].PrivateLinkServiceConnectionState.Status
    $hasZoneGroup = $null -ne $pe.PrivateDnsZoneGroup -and $pe.PrivateDnsZoneGroup.Count -gt 0
    [PSCustomObject]@{
        PrivateEndpoint = $pe.Name
        ResourceGroup   = $pe.ResourceGroupName
        ConnectionState = $connState
        HasZoneGroup    = $hasZoneGroup
        NeedsReview     = ($connState -ne 'Approved') -or (-not $hasZoneGroup)
    }
} | Where-Object NeedsReview | Format-Table -AutoSize
```

**Rollback:** N/A — read-only audit.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Private Link / Private Endpoint evidence for escalation
.NOTES     Run as a user with Reader+ on the resource group(s) involved
#>

$OutputDir = "C:\Temp\PrivateLink-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$pe = Get-AzPrivateEndpoint -ResourceGroupName $rg -Name $peName

# 1. Connection state
$pe.PrivateLinkServiceConnections | Select-Object Name, PrivateLinkServiceConnectionState |
    ConvertTo-Json -Depth 6 | Out-File "$OutputDir\ConnectionState.json"

# 2. DNS Zone Group configuration
$pe.PrivateDnsZoneGroup | ConvertTo-Json -Depth 6 | Out-File "$OutputDir\ZoneGroup.json"

# 3. Zone links and record set (requires knowing the zone name — derive from PE's FQDN if needed)
Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $rg -ZoneName $zoneName |
    Select-Object Name, VirtualNetworkId, VirtualNetworkLinkState |
    Export-Csv "$OutputDir\ZoneLinks.csv" -NoTypeInformation
Get-AzPrivateDnsRecordSet -ResourceGroupName $rg -ZoneName $zoneName -RecordType A |
    Export-Csv "$OutputDir\ZoneRecords.csv" -NoTypeInformation

# 4. Subnet network policy state
(Get-AzVirtualNetworkSubnetConfig -ResourceId $pe.Subnet.Id).PrivateEndpointNetworkPolicies |
    Out-File "$OutputDir\SubnetNetworkPolicy.txt"

# 5. Live resolution test
Resolve-DnsName -Name $resourceFqdn | Out-File "$OutputDir\DnsResolution.txt"

# 6. Recent Activity Log entries for this endpoint
Get-AzActivityLog -ResourceId $pe.Id -StartTime (Get-Date).AddHours(-24) |
    Select-Object EventTimestamp, OperationName, Status, Caller |
    Export-Csv "$OutputDir\ActivityLog-24h.csv" -NoTypeInformation

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Connection approval state — the #1 first check, gates everything else
(Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>).PrivateLinkServiceConnections |
    Select Name, PrivateLinkServiceConnectionState

# Approve a pending connection from the resource owner's side
Approve-AzPrivateEndpointConnection -ResourceGroupName <ownerRg> -ServiceName <resourceName> `
    -PrivateLinkResourceType <resourceType> -Name <connectionName>

# DNS Zone Group presence — the automation layer for DNS records
(Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>).PrivateDnsZoneGroup

# Zone's Virtual Network Links — confirm EVERY client VNet has its own link
Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <rg> -ZoneName <privatelinkZoneName>

# Zone's record set — check for cross-service contamination
Get-AzPrivateDnsRecordSet -ResourceGroupName <rg> -ZoneName <privatelinkZoneName> -RecordType A

# Live resolution test — private IP expected, not public
Resolve-DnsName -Name <resourceFqdn>

# Subnet network policy state — off by default; NSG/UDR not evaluated for PE traffic until Enabled
(Get-AzVirtualNetworkSubnetConfig -ResourceId <subnetId>).PrivateEndpointNetworkPolicies

# Which subresources a target resource supports (and their exact GroupId)
Get-AzPrivateLinkResource -PrivateLinkResourceId <targetResourceId>

# VNet's DNS server configuration — Default (Azure-provided) vs. custom
(Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnetName>).DhcpOptions.DnsServers

# Fleet-wide: every Private Endpoint's connection state + Zone Group presence in one pass
Get-AzPrivateEndpoint | Select Name, ResourceGroupName, @{N='State';E={$_.PrivateLinkServiceConnections[0].PrivateLinkServiceConnectionState.Status}}
```

---

## 🎓 Learning Pointers

- **Creating a Private Endpoint does not, by itself, change what a resource's FQDN resolves to.** The resource's public DNS entry keeps working exactly as before; a completely separate DNS configuration step (almost always the private DNS zone + Zone Group) is what redirects resolution to the private IP. This single fact explains the majority of "we set up Private Link and nothing changed" tickets. [MS Docs: What is a private endpoint?](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview)

- **Only an `Approved` connection state carries traffic — Pending, Rejected, and Disconnected all carry none, regardless of how complete DNS and networking otherwise look.** A Private Endpoint stuck in Pending has a real IP, may resolve correctly via DNS, and looks fully deployed in the portal, but is functionally inert until the resource owner acts. Check this before spending time on anything else. [MS Docs: Access to a private-link resource using approval workflow](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview#access-to-a-private-link-resource-using-approval-workflow)

- **Never share one private DNS zone across two different Azure services.** Each Private Endpoint's Zone Group deployment treats its own record as authoritative and will silently overwrite a conflicting entry from a different service on its next reconciliation. This produces a distinctive, confusing symptom: a Private Endpoint that had been working correctly for months breaks the moment an unrelated Private Endpoint (for a different service) gets deployed against the same shared zone. [MS Docs: Azure Private Endpoint DNS integration scenarios](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns-integration)

- **VNet peering — regional or global — never implies a private DNS zone link.** Microsoft's documented model is one shared zone extended by an explicit `Virtual Network Link` to every VNet needing resolution, not one zone per VNet. In hub-and-spoke environments this means every new spoke needs its own link added as a deliberate step, every time — it will never happen automatically as a side effect of the peering itself.

- **Private Link is architecturally distinct from the older Service Endpoint mechanism, and the two are frequently conflated.** A Service Endpoint extends your VNet's identity to a service over the Microsoft backbone via route injection — the service keeps its public IP, and traffic leaves via the service's public endpoint (just authenticated as coming from your VNet). A Private Endpoint brings the service's own private IP into your VNet, with genuinely private, on-network traffic and no public IP exposure in the connection path at all. A client asking to "lock down" access to a PaaS resource may mean either, and the two have very different security postures.

- **`PrivateEndpointNetworkPolicies` defaults to disabled, and this is a structural exemption from NSG/UDR evaluation, not a permissive default rule.** An engineer who adds an explicit NSG deny targeting a Private Endpoint's subnet and observes no effect at all has almost certainly just discovered this default rather than found a genuine NSG bug — this is one of the more counter-intuitive defaults in the whole Private Link model and worth explaining proactively to a client who expects standard NSG behavior to apply.
