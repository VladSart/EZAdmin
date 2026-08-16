# Azure Private Link / Private Endpoints — Hotfix Runbook (Mode B: Ops)
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
# 1. Connection state — ONLY "Approved" sends traffic; everything else is dead on arrival
(Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>).PrivateLinkServiceConnections | Select-Object Name, PrivateLinkServiceConnectionState

# 2. DNS resolution — does the FQDN resolve to the private IP, or is it leaking to the public one?
Resolve-DnsName -Name <resourceFqdn>

# 3. Does the Private Endpoint even have a DNS Zone Group attached?
(Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>).PrivateDnsZoneGroup

# 4. Is the client's VNet actually linked to the private DNS zone (peering does NOT imply a link)?
Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <rg> -ZoneName <privatelinkZoneName>

# 5. Are NSG/UDR even being applied to this subnet, or are they silently ignored?
(Get-AzVirtualNetworkSubnetConfig -ResourceId <subnetId>).PrivateEndpointNetworkPolicies
```

| If | Then |
|----|------|
| Connection state is `Pending` | Owner never approved the request — the endpoint sends zero traffic until they do → **Fix 1** |
| Connection state is `Rejected` or `Disconnected` | Endpoint is dead; must be deleted and recreated, cannot be "re-approved" → **Fix 2** |
| `nslookup`/`Resolve-DnsName` returns the resource's PUBLIC IP, not a 10.x/172.x/192.168.x address | DNS isn't resolving to the private IP — check Zone Group next, this is the #1 real-world ticket → **Fix 3** |
| `PrivateDnsZoneGroup` is null/empty | No automatic DNS record management configured at all — manual record or missing entirely → **Fix 4** |
| Zone Group exists but VNet link is missing for the CLIENT's VNet (not just the PE's own VNet) | Peering never implies a zone link — each VNet needs its own explicit link → **Fix 5** |
| Two different services' records keep overwriting each other in the same zone | One zone was reused across two different private-link resources — each service needs its own zone → **Fix 6** |
| NSG changes to the PE subnet appear to have no effect | `PrivateEndpointNetworkPolicies` is disabled (the default) — NSG/UDR are structurally not evaluated for PE traffic until enabled → **Fix 7** |
| On-premises clients can't resolve the FQDN at all, VNet clients can | No DNS forwarding path from on-prem to Azure's private zone — needs a forwarder VM or Private Resolver → **Fix 8** |
| A second, unrelated Private Endpoint was just created and now the FIRST one's DNS broke | Same zone reused across unlike services — record collision, see Fix 6 | 

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Private-link resource (the PaaS service or Private Link Service) exists and supports Private Link
        │
Private Endpoint created in a client subnet — gets ONE static private IP for the resource's lifetime
        │
Connection approval state = Approved (Automatic if you own the resource; Manual otherwise — Pending
   until the resource owner acts; ONLY Approved sends traffic)
        │
Private DNS Zone Group attached to the Private Endpoint (the automation layer — creates/maintains the
   A record; without it, DNS is either unmanaged or manually scripted)
        │
Private DNS Zone uses the exact reserved privatelink.<service>.<suffix> name for that service
   (one zone per service — never share a zone across two DIFFERENT services)
        │
Virtual Network Link connects the zone to EVERY VNet that needs resolution
   (peering NEVER implies a link — each VNet, hub or spoke, needs its own explicit link)
        │
[On-premises clients] DNS forwarding path exists — conditional forwarder VM or Azure DNS Private
   Resolver — on-prem cannot query Azure's 168.63.129.16 resolver directly
        │
Client resolves FQDN → private IP (not the public IP) → traffic reaches the Private Endpoint NIC
        │
[If NSG/UDR expected to apply] PrivateEndpointNetworkPolicies enabled on the subnet — OFF by default,
   and PE traffic is structurally exempt from NSG/UDR evaluation until turned on
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm the connection is actually Approved — this gates everything else:**
```powershell
(Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>).PrivateLinkServiceConnections |
    Select-Object Name, PrivateLinkServiceConnectionState
```
`Pending` → Fix 1. `Rejected`/`Disconnected` → Fix 2 (delete and recreate, never "re-approve"). Only `Approved` can carry traffic — don't chase DNS or NSG issues on a non-Approved endpoint, that's not yet the problem.

**2. Split the problem: is this a resolution failure or a connectivity failure?**
```powershell
Resolve-DnsName -Name <resourceFqdn>
```
Resolves to a public IP (not 10.x/172.16-31.x/192.168.x) → this is DNS, go to step 3.
Resolves to the correct private IP but the connection still times out → this is NSG/routing, go to step 6.
NXDOMAIN or resolves to nothing → check the zone and link exist at all (step 4).

**3. DNS resolves to the public IP — check the Zone Group first, not the zone itself:**
```powershell
(Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>).PrivateDnsZoneGroup
```
Null/empty → Fix 4 (no automation configured). Present → confirm the zone it points to is actually linked to the CLIENT's VNet (not just the PE's own VNet) — step 4.

**4. Confirm the private DNS zone is linked to every VNet that needs resolution:**
```powershell
Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <rg> -ZoneName <privatelinkZoneName>
```
Client's VNet missing from the list → Fix 5. This is the single most common gap in hub-and-spoke: the hub VNet (where the PE often lives) is linked, but a newly added spoke VNet never got its own link — VNet peering does not create one automatically.

**5. Confirm the zone hasn't been contaminated by a second, unrelated service:**
```powershell
Get-AzPrivateDnsRecordSet -ResourceGroupName <rg> -ZoneName <privatelinkZoneName> -RecordType A
```
Records present that don't belong to the service you're troubleshooting → Fix 6 — a second Private Endpoint for a DIFFERENT service was pointed at this same zone, and its Zone Group deployment silently deleted/overwrote the original A record on its last update.

**6. DNS is correct, but the connection still fails — check network policies on the subnet:**
```powershell
(Get-AzVirtualNetworkSubnetConfig -ResourceId <subnetId>).PrivateEndpointNetworkPolicies
```
`Disabled` (the default) and an NSG rule was expected to block/allow PE traffic → that NSG is not being evaluated at all for this traffic. This is expected default behavior, not a bug — Fix 7 if NSG/UDR enforcement is actually required.

**7. On-premises clients specifically can't resolve, VNet clients are fine:**
On-prem clients cannot query Azure's internal resolver (168.63.129.16) directly. Confirm a DNS forwarder (VM-based conditional forwarder or Azure DNS Private Resolver) exists in a VNet linked to the zone — Fix 8.

---

## Common Fix Paths

<details><summary>Fix 1 — Connection stuck in Pending</summary>

**Symptom:** `PrivateLinkServiceConnectionState.Status` is `Pending`. No traffic flows regardless of how correct the DNS/network configuration otherwise is.

```powershell
# From the RESOURCE OWNER side — list pending connections needing action
Get-AzPrivateEndpointConnection -ResourceGroupName <ownerRg> -ServiceName <resourceName> -PrivateLinkResourceType Microsoft.Storage/storageAccounts |
    Where-Object { $_.PrivateLinkServiceConnectionState.Status -eq 'Pending' }

# Approve it
Approve-AzPrivateEndpointConnection -ResourceGroupName <ownerRg> -ServiceName <resourceName> `
    -PrivateLinkResourceType Microsoft.Storage/storageAccounts -Name <connectionName>
```

If you own the resource and expected automatic approval, confirm the requester actually holds the `Microsoft.<Provider>/<resource_type>/privateEndpointConnectionsApproval/action` permission — without it, even same-tenant requests fall back to manual/Pending.

**Rollback:** N/A — approval is additive; reject instead if the connection shouldn't exist.

</details>

<details><summary>Fix 2 — Connection is Rejected or Disconnected</summary>

**Symptom:** Status shows `Rejected` (owner declined) or `Disconnected` (owner deleted the connection from their side). The Private Endpoint object still exists on the client side but is permanently inert.

```powershell
# There is no "re-approve" path for Rejected/Disconnected — the endpoint must be recreated
Remove-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName> -Force

# Recreate with a fresh manual connection request
New-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName> -Location <location> -Subnet $subnet `
    -PrivateLinkServiceConnection $privateLinkServiceConnection
```

**Rollback:** N/A — the prior object was already non-functional; recreation is the only path forward.

</details>

<details><summary>Fix 3 — DNS resolves to the public IP instead of the private IP</summary>

**Symptom:** `Resolve-DnsName`/`nslookup` against the resource's FQDN returns a public IP. This is the single most common Private Link ticket.

```powershell
# Confirm the Zone Group is attached at all (see Fix 4 if empty)
(Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>).PrivateDnsZoneGroup

# Confirm the zone is linked to the CLIENT's VNet specifically (see Fix 5 if missing)
Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <rg> -ZoneName <privatelinkZoneName>

# Confirm the VNet is actually using Azure-provided DNS, not a custom DNS server bypassing it
(Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnetName>).DhcpOptions.DnsServers
```

If a custom DNS server is configured, it must forward the `privatelink.*` zone's suffix to `168.63.129.16` — otherwise every query for that suffix leaves the VNet and resolves publicly, which is exactly this symptom.

**Rollback:** N/A — diagnostic only until a specific gap (Zone Group, link, or custom DNS forwarding) is identified and fixed via Fix 4/5.

</details>

<details><summary>Fix 4 — No Private DNS Zone Group attached</summary>

**Symptom:** `PrivateDnsZoneGroup` returns null. DNS records for this endpoint are either entirely unmanaged or were created manually and will silently go stale on any IP change.

```powershell
$zoneConfig = New-AzPrivateDnsZoneConfig -Name 'privatelink-config' -PrivateDnsZoneId (Get-AzPrivateDnsZone -ResourceGroupName <rg> -Name <privatelinkZoneName>).ResourceId

New-AzPrivateDnsZoneGroup -ResourceGroupName <rg> -PrivateEndpointName <peName> `
    -Name 'default' -PrivateDnsZoneConfig $zoneConfig
```

This creates the A record automatically and keeps it in sync going forward — including on region changes or endpoint recreation, without hand-scripted DNS updates.

**Rollback:** `Remove-AzPrivateDnsZoneGroup` reverts to unmanaged DNS; any manually-created record is untouched by this action either way.

</details>

<details><summary>Fix 5 — Zone exists but isn't linked to the client's VNet</summary>

**Symptom:** Zone Group is attached, zone has the correct record — but a specific VNet (often a newly added spoke) still resolves publicly or gets NXDOMAIN.

```powershell
New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <rg> -ZoneName <privatelinkZoneName> `
    -Name "link-$(($vnetName))" -VirtualNetworkId $vnet.Id
```

Remember: VNet peering (regional or global) does **not** create this link automatically, no matter how thoroughly the peering itself is configured. In a hub-and-spoke topology, every spoke that needs resolution needs its own explicit link to the (typically centrally hosted) zone.

**Rollback:** `Remove-AzPrivateDnsVirtualNetworkLink` if the link was added to the wrong VNet.

</details>

<details><summary>Fix 6 — Two services sharing one zone, records overwriting each other</summary>

**Symptom:** A Private Endpoint that was working suddenly resolves incorrectly or stops resolving, right after an unrelated Private Endpoint for a DIFFERENT service was created.

```powershell
# Confirm the zone's actual record set — look for records that don't belong to the service you expect
Get-AzPrivateDnsRecordSet -ResourceGroupName <rg> -ZoneName <privatelinkZoneName> -RecordType A
```

Microsoft's own documented guidance: **never place records for two different Azure services in the same private DNS zone.** Each Private Endpoint's Zone Group deployment manages "its" record and will overwrite conflicting entries on its next update.

```powershell
# Create a dedicated zone for the second service and re-point its Zone Group to it
New-AzPrivateDnsZone -ResourceGroupName <rg> -Name <correctPrivatelinkZoneNameForService2>
New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <rg> -ZoneName <correctPrivatelinkZoneNameForService2> -Name "link-$vnetName" -VirtualNetworkId $vnet.Id
Remove-AzPrivateDnsZoneGroup -ResourceGroupName <rg> -PrivateEndpointName <secondPeName> -Name 'default'
# then re-run Fix 4 against the new, correctly-scoped zone
```

**Rollback:** Original zone's correct record self-heals once the offending Zone Group is repointed and its next reconciliation runs, or can be recreated manually in the interim.

</details>

<details><summary>Fix 7 — NSG/UDR changes on the PE subnet have no visible effect</summary>

**Symptom:** An NSG rule was added or changed on the Private Endpoint's subnet specifically to control PE traffic, and it appears to do nothing — traffic that should be blocked isn't, or vice versa.

```powershell
$vnet = Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnetName>
$subnet = $vnet.Subnets | Where-Object Name -eq <subnetName>
$subnet.PrivateEndpointNetworkPolicies
```

`Disabled` (the default) means NSG and UDR are **structurally not evaluated** for traffic to/from a Private Endpoint on that subnet — this isn't a permissive default rule, it's a complete bypass of the policy engine for that traffic class.

```powershell
$subnet.PrivateEndpointNetworkPolicies = "Enabled"
Set-AzVirtualNetwork -VirtualNetwork $vnet
```

**Rollback:** Set back to `Disabled` if this breaks Private Endpoint creation on the subnet (some regions/scenarios have documented incompatibilities — see `PrivateLink-A.md` Learning Pointers).

</details>

<details><summary>Fix 8 — On-premises clients can't resolve, VNet clients can</summary>

**Symptom:** Resolution and connectivity work correctly from inside Azure VNets but fail entirely from on-premises networks connected via VPN/ExpressRoute.

```powershell
# Confirm on-prem DNS has a conditional forwarder pointed at an in-VNet forwarder or Private Resolver
# (on-prem CANNOT query 168.63.129.16 directly — it's only reachable from inside a VNet)
```

The supported bridge is either a DNS forwarder VM deployed in a VNet linked to the zone, or **Azure DNS Private Resolver** (Microsoft's current recommended approach — no VM to patch/maintain). See `PrivateLink-A.md` Playbook 3 for the Private Resolver deployment sequence.

**Rollback:** N/A — this is additive infrastructure; removing a forwarder simply reverts on-prem to public resolution.

</details>

---

## Escalation Evidence

```
=== Private Link / Private Endpoint Failure — Ticket Evidence ===

Date/Time:                            _______________
Private Endpoint name / RG:           _______________
Target private-link resource:         _______________
Reported symptom:                     _______________  (approval / DNS-public-IP / no-connectivity / on-prem-only)

--- Commands Run ---
Connection state:                          _______________
Resolve-DnsName result (IP returned):      _______________
PrivateDnsZoneGroup present (Y/N):         _______________
VNet link present for client's VNet (Y/N): _______________
Zone record set (any unexpected entries):  _______________
PrivateEndpointNetworkPolicies state:      _______________
VNet DNS servers (Default or custom):      _______________

--- Steps Taken ---
[ ] Confirmed connection state is Approved
[ ] Confirmed DNS resolves to the private IP, not public
[ ] Confirmed Zone Group is attached
[ ] Confirmed VNet link exists for the CLIENT's VNet specifically
[ ] Checked for zone record collision from an unrelated service
[ ] Checked PrivateEndpointNetworkPolicies if NSG/UDR expected to apply
[ ] Confirmed on-prem DNS forwarding path if applicable
```

---

## 🎓 Learning Pointers

- **DNS resolving to the public IP is the single most common Private Link ticket, and it's almost never the zone itself — it's the Zone Group or the VNet link.** Check `PrivateDnsZoneGroup` on the endpoint before looking at the zone's records; an empty Zone Group means nothing is managing DNS for this endpoint at all. [MS Docs: Private Endpoint DNS integration](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns-integration)

- **VNet peering never implies a private DNS zone link — full stop, no exceptions.** A hub-and-spoke topology where the hub resolves correctly but a spoke doesn't is almost always a missing `New-AzPrivateDnsVirtualNetworkLink` for that specific spoke, not a peering misconfiguration. [MS Docs: Private DNS virtual network links](https://learn.microsoft.com/en-us/azure/dns/private-dns-virtual-network-links)

- **Never place records for two different Azure services in the same private DNS zone**, even if it seems convenient. Each Private Endpoint's own Zone Group deployment reconciles "its" record on every update and will silently delete a conflicting entry from a different service — this produces the confusing symptom of "a Private Endpoint that was working for months just stopped, right after we deployed an unrelated one." [MS Docs: Azure Private Endpoint DNS integration scenarios](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns-integration)

- **`PrivateEndpointNetworkPolicies` disabled (the default) means NSG/UDR are not evaluated at all for PE traffic** — not permissively allowed, structurally bypassed. If a client expects NSG rules to control access to a Private Endpoint and they appear to have zero effect, this setting is almost always why.

- **Only an `Approved` connection state sends any traffic whatsoever.** `Pending` looks deceptively complete in the portal (the endpoint exists, has an IP, DNS may even be configured) but carries zero traffic until the resource owner acts — always check this first, before spending time on DNS or NSG.

- **On-premises clients cannot query Azure's `168.63.129.16` resolver directly** — a forwarder (VM-based conditional forwarder, or the currently-recommended Azure DNS Private Resolver) must exist inside a VNet that's itself linked to the zone. This is a distinct requirement from VNet-to-VNet resolution and is easy to miss when a Private Link deployment was only tested from inside Azure.
