# Azure Private DNS Zones — Reference Runbook (Mode A: Deep Dive)
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

Covers Azure Private DNS zones (`Microsoft.Network/privateDnsZones`) in both of their common MSP-relevant shapes: **custom zones** (e.g. `contoso.internal`) used for general VM/service name resolution inside one or more VNets, and **`privatelink.*` reserved zones** used to integrate Azure Private Endpoints with DNS so PaaS resource FQDNs resolve to private IPs instead of public ones. Also covers the two paths for extending private zone resolution beyond a single Azure-native VNet: manually-maintained DNS forwarders, and Azure DNS Private Resolver.

Does **not** cover: Azure Public DNS zones (a different resource type entirely, despite the similar-looking cmdlet names — `Get-AzDnsZone` vs `Get-AzPrivateDnsZone`), on-premises Active Directory-integrated DNS internals (only the forwarding relationship *into* Azure Private DNS is covered here), Traffic Manager or Azure Front Door DNS-based routing, or general VNet peering/connectivity troubleshooting (cross-reference `Azure/Networking/HybridConnectivity-A.md` and `Azure/Networking/NSG-B.md` for those — this runbook assumes the underlying network path is already reachable and the problem is specifically name resolution).

---
## How It Works

<details><summary>Full architecture</summary>

**The Azure-provided DNS resolver, 168.63.129.16.** Every Azure VNet is handed this address by default (unless a custom DNS server list is configured). This address is not a real routable IP in the usual sense — it's a special virtual IP served by the Azure platform itself, reachable from any VNet, that acts as a recursive resolver for public internet names *and* the authoritative source for any private DNS zone linked to that VNet. This one address is the hinge the entire private DNS story turns on: anything that stops a client from querying it (custom DNS servers, on-prem-only clients, third-party firewalls blocking outbound to it) breaks private zone resolution regardless of how correctly the zone itself is configured.

**Private DNS Zone.** A zone is a container for DNS records (A, AAAA, CNAME, MX, PTR, SOA, SRV, TXT) scoped to Azure rather than the public internet. Unlike public DNS zones, private zones do not support NS-record delegation to child zones — there is no concept of "delegate `sub.contoso.internal` to another private zone." Everything lives flat inside the one zone resource (though naming conventions can still create the illusion of hierarchy).

**Virtual Network Link — the resource that actually makes resolution possible.** A zone with zero VNet links is completely inert; no VNet can query it, no matter how many records exist inside it. Each link has one on/off setting, `registrationEnabled`:
- **Resolution only** (`registrationEnabled: false`): the linked VNet can query records already in the zone. This is what's needed for a *spoke* VNet that just needs to resolve names owned by another VNet's workloads, or to consume `privatelink.*` records for a Private Endpoint that lives elsewhere.
- **Autoregistration enabled** (`registrationEnabled: true`): in addition to resolution, every VM with a NIC in this VNet automatically gets an A record (and reverse PTR) written into the zone using its Azure-assigned hostname, kept in sync as VMs start/stop/get new IPs. This only applies to custom zones — there is no concept of "autoregistering" a PaaS resource into a `privatelink.*` zone, because there's no VM/agent to do the registering.

**Peering does not extend a zone link.** This is the single most consequential architectural fact in this topic. VNet peering is a network-layer construct — it makes packets routable between VNets. A private DNS zone link is a completely separate, DNS-layer construct. A peered spoke VNet resolving zone records requires its *own* explicit link to that zone (resolution-only is sufficient if the spoke doesn't need to register its own records). Engineers coming from a "peering equals full transitive reachability" mental model consistently miss this.

**Private Endpoint DNS integration via Zone Groups.** When a Private Endpoint is created for a PaaS resource (Storage, SQL, Key Vault, etc.), the resource's public FQDN doesn't change — instead, Microsoft's guidance is to create an A record for that exact public FQDN inside a `privatelink.*` zone, which then takes precedence for any client resolving through a VNet linked to that zone (because the linked zone is authoritative for that name from that VNet's perspective, overriding what public DNS would otherwise return). The mechanism that writes this A record automatically is the Private Endpoint's **DNS Zone Group** child resource — a Zone Group references one or more private DNS zones and Azure keeps the A record(s) synchronized with the endpoint's current private IP(s) for as long as the zone group exists. Without a zone group, nothing writes the record, and any client resolving the FQDN — even one sitting right next to the endpoint — falls through to public DNS and gets the resource's public IP.

**Reserved zone names are not arbitrary.** Each Private Link-enabled service has one specific required private DNS zone name published by Microsoft (`privatelink.blob.core.windows.net`, `privatelink.database.windows.net`, `privatelink.vaultcore.azure.net`, `privatelink.azurewebsites.net`, and so on for dozens of services). Creating a zone under a similar-but-wrong name doesn't error — it just means the integration silently does nothing, because nothing in the platform expects that name specifically.

**Extending beyond native Azure DNS resolution — two paths.** A custom DNS server (an AD-integrated DC, a third-party appliance) placed in a VNet's DNS settings takes over *all* resolution for that VNet, including private zone lookups — unless that server is configured with a conditional forwarder pointing the zone's domain suffix at `168.63.129.16`. For true hybrid scenarios (on-premises clients needing to resolve Azure private zone names), two options exist: (1) a manually deployed DNS forwarder VM inside the VNet that on-prem DNS conditionally forwards to, or (2) **Azure DNS Private Resolver**, a managed service (GA since 2023) that exposes an inbound endpoint (on-prem → Azure direction) and an outbound endpoint with a ruleset (Azure → on-prem direction), removing the need to patch and monitor a dedicated forwarder VM.

</details>

---
## Dependency Stack

```
Azure platform DNS infrastructure
    │
    ▼
Azure-provided DNS (168.63.129.16) — default resolver for every VNet unless overridden
    │
    ├── VNet DNS settings = Default (Azure-provided)  → private zone path works natively
    └── VNet DNS settings = Custom server(s)           → private zone path requires that
                                                           server to forward to 168.63.129.16,
                                                           or Azure DNS Private Resolver
    │
    ▼
Private DNS Zone resource exists
    │   ├── Custom zone (e.g. contoso.internal)
    │   └── Reserved privatelink.* zone (exact name required per service)
    ▼
Virtual Network Link (per VNet that needs resolution — peering does NOT create this)
    │   ├── Resolution-only
    │   └── Registration-enabled (custom zones only)
    ▼
Records populated in the zone
    │   ├── Custom zone  → VM autoregistration (needs registration-enabled link + running VM
    │   │                   + correct NIC state)
    │   └── privatelink.* zone → Private Endpoint's DNS Zone Group (separate resource,
    │                             independent of any VNet link's registration flag)
    ▼
Client-side resolution
    │   ├── Azure VM in a linked VNet using default DNS → works automatically
    │   ├── Azure VM in a peered-but-unlinked VNet       → FAILS until linked
    │   ├── Azure VM in a VNet with custom DNS servers   → depends entirely on that
    │   │                                                    server's forwarding config
    │   └── On-premises client                            → depends on conditional forwarder
    │                                                         or Azure DNS Private Resolver
    ▼
Resolved IP returned to client (private IP = success; public IP or NXDOMAIN = failure somewhere above)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Private Endpoint FQDN resolves to the resource's **public IP** | No DNS Zone Group on the Private Endpoint, or zone group targets the wrong zone | `Get-AzPrivateEndpoint ... \| Select PrivateDnsZoneGroup` |
| Resolves correctly from VNet A, fails (public IP or NXDOMAIN) from peered VNet B | VNet B was never linked to the zone — peering doesn't create a link | `Get-AzPrivateDnsVirtualNetworkLink` — check `VirtualNetworkId` list |
| Works for some clients in a VNet, not others | Some clients bypass the VNet's DNS setting (e.g. hardcoded DNS server on the NIC itself, overriding VNet-level DHCP-issued settings) | Check the individual NIC's DNS settings, not just the VNet's |
| Resolution fails VNet-wide, including from freshly-created VMs | VNet's DNS servers set to a custom IP with no forwarding rule for the zone's domain | `(Get-AzVirtualNetwork ...).DhcpOptions.DnsServers` |
| On-premises clients can't resolve any Azure private zone name | No conditional forwarder / Azure DNS Private Resolver inbound endpoint configured on-prem side | Check on-prem DNS server's conditional forwarders; check DNS Private Resolver deployment |
| Short hostname fails, FQDN with suffix succeeds | Client's DNS suffix search list doesn't include the zone's domain (DHCP option 15 not propagating, or static config) | `Get-DnsClientGlobalSetting` on the client |
| New VM in a registration-enabled VNet never gets an autoregistered record | VNet link's `RegistrationEnabled` is actually `false`, or the zone is a `privatelink.*` zone (autoregistration doesn't apply there) | `Get-AzPrivateDnsVirtualNetworkLink ... \| Select RegistrationEnabled` |
| Record resolves to an IP belonging to a long-deleted VM | Stale autoregistered record — cleanup didn't fire on VM/NIC deletion | `Get-AzPrivateDnsRecordSet` and cross-reference against current VM inventory |
| Zone group added, correct zone referenced, record still absent after 15+ minutes | Propagation delay, or an underlying provisioning error on the zone group itself | Check zone group `ProvisioningState`; recreate if `Failed` |
| Everything above checks out but resolution still fails | Client-side DNS cache holding a stale negative/positive result | `Clear-DnsClientCache` on the affected client before further escalation |

---
## Validation Steps

1. **Baseline the actual resolution result from the affected client.**
   ```powershell
   Resolve-DnsName -Name <fqdn> -Type A -Server 168.63.129.16
   ```
   Querying `168.63.129.16` explicitly (rather than whatever resolver the client is currently configured with) isolates whether the zone/link configuration itself is correct, independent of the client's own DNS settings — a very useful split when custom DNS is in the mix. Good: private IP. Bad: public IP (zone/zone-group problem) or `NXDOMAIN` (link problem, or record genuinely absent).

2. **Enumerate every VNet link for the zone and confirm the querying VNet is present.**
   ```powershell
   Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <rg> -ZoneName <zoneName> |
     Format-Table Name, VirtualNetworkId, RegistrationEnabled, ProvisioningState
   ```
   Good: the exact resource ID of the querying VNet appears with `ProvisioningState: Succeeded`. Bad: absent entirely, or present with `ProvisioningState: Failed`.

3. **For Private Endpoint scenarios, validate the Zone Group's target and state.**
   ```powershell
   $pe = Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>
   $pe.PrivateDnsZoneGroup
   ```
   Good: a zone group object referencing the exact reserved zone name for that service, `ProvisioningState: Succeeded`. Bad: `PrivateDnsZoneGroup` is `$null` (never configured), or references a zone name that doesn't match the service's documented requirement.

4. **Confirm the VNet's effective DNS configuration.**
   ```powershell
   (Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnetName>).DhcpOptions.DnsServers
   ```
   Good: empty (Default/Azure-provided). If populated, every one of those servers must be independently verified to forward the relevant domain suffix to `168.63.129.16`.

5. **Directly inspect the record set to separate "record doesn't exist" from "record exists but client can't see it."**
   ```powershell
   Get-AzPrivateDnsRecordSet -ResourceGroupName <rg> -ZoneName <zoneName> -RecordType A |
     Where-Object Name -like "*<hostPrefix>*" | Select Name, Ttl, Records
   ```
   If the record is present and correct here but the client still can't resolve it, the problem is downstream of the zone (link missing for that VNet, custom DNS not forwarding, or client-side cache/suffix issue) — not the zone configuration itself.

6. **For hybrid/on-premises validation, test resolution from a machine that goes through the actual forwarding path in question**, not from an Azure-native VM (which bypasses the on-prem forwarding path entirely and will give a false "it works" result).

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the record exists and is correct, independent of any client.**
Query the zone directly (`Get-AzPrivateDnsRecordSet`). If absent for a `privatelink.*` zone, the Zone Group is the problem. If absent for a custom zone, autoregistration/link configuration is the problem.

**Phase 2 — Confirm the querying VNet has a link.**
Cross-reference `VirtualNetworkId` against the VNet the client's NIC is actually in — not a similarly-named VNet, not a peered VNet, not a VNet in a different subscription that happens to share an address space.

**Phase 3 — Confirm the VNet's DNS path reaches Azure's resolver.**
Default DNS settings mean this phase is automatically satisfied. Custom DNS means every hop in the resolution chain (client → custom DNS server → forwarder rule → 168.63.129.16, or client → custom DNS → Azure DNS Private Resolver inbound endpoint) must be individually verified.

**Phase 4 — Rule out client-side state.**
DNS suffix search list, local `hosts` file entries, and stale resolver cache can all mask or mimic a zone-side problem. `Clear-DnsClientCache` and re-test before concluding the platform configuration is at fault.

**Phase 5 — For hybrid failures specifically, validate each direction independently.**
On-prem → Azure (inbound endpoint / forwarder reachability) and Azure → on-prem (outbound endpoint / ruleset, relevant if Azure workloads also need to resolve on-prem AD names) are separate failure domains within Azure DNS Private Resolver — a problem in one does not imply a problem in the other.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Repair a broken/missing Private Endpoint DNS Zone Group</summary>

```powershell
# Identify the correct reserved zone name for the service first — do not guess
# (reference: https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns)

$zone = Get-AzPrivateDnsZone -ResourceGroupName <dnsRg> -Name "privatelink.<correct-suffix>"
$config = New-AzPrivateDnsZoneConfig -Name "config1" -PrivateDnsZoneId $zone.ResourceId

# If a zone group already exists but is wrong/stuck, remove it first
Remove-AzPrivateEndpointDnsZoneGroup -ResourceGroupName <rg> -PrivateEndpointName <peName> -Name "default" -ErrorAction SilentlyContinue

New-AzPrivateEndpointDnsZoneGroup -ResourceGroupName <rg> -PrivateEndpointName <peName> `
  -Name "default" -PrivateDnsZoneConfig $config

# Confirm
(Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>).PrivateDnsZoneGroup
```

**Rollback:** `Remove-AzPrivateEndpointDnsZoneGroup` reverts to the pre-fix state (no automatic DNS integration). No impact to the endpoint's network connectivity or the PaaS resource itself either way — this only affects name resolution.

</details>

<details><summary>Playbook 2 — Link a peered VNet for resolution</summary>

```powershell
$vnet = Get-AzVirtualNetwork -ResourceGroupName <peeredRg> -Name <peeredVnetName>

New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <dnsRg> -ZoneName <zoneName> `
  -Name "link-$($vnet.Name)" -VirtualNetworkId $vnet.Id -EnableRegistration:$false
```
Use `-EnableRegistration:$true` only if VMs in this VNet also need to autoregister their own records into this zone (custom zones only — irrelevant for `privatelink.*` zones).

**Rollback:** `Remove-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <dnsRg> -ZoneName <zoneName> -Name "link-<name>"`. Removes only that VNet's ability to resolve/register into the zone; the zone and its other links are unaffected.

</details>

<details><summary>Playbook 3 — Bridge custom DNS / on-premises into Azure Private DNS</summary>

For a **single custom DNS server inside Azure** (e.g. an AD-integrated DC used as the VNet's DNS server): add a conditional forwarder on that server for the zone's domain suffix, targeting `168.63.129.16`.

For **hybrid/on-premises**, deploy Azure DNS Private Resolver rather than a manually-maintained forwarder VM:
```powershell
New-AzDnsResolver -ResourceGroupName <rg> -Name <resolverName> -Location <region> -VirtualNetworkId <vnetId>

New-AzDnsResolverInboundEndpoint -ResourceGroupName <rg> -DnsResolverName <resolverName> `
  -Name "inbound-ep" -IPConfiguration $ipConfig

New-AzDnsResolverRuleSet -ResourceGroupName <rg> -Name <rulesetName> -DnsResolverOutboundEndpoint $outboundEp

New-AzDnsResolverRule -ResourceGroupName <rg> -DnsForwardingRulesetName <rulesetName> `
  -Name "rule-privatelink" -DomainName "privatelink.blob.core.windows.net." `
  -TargetDnsServer @{IPAddress="168.63.129.16"; Port=53}
```
Point the on-premises DNS server's conditional forwarder for the relevant domain suffix(es) at the inbound endpoint's IP address.

**Rollback:** `Remove-AzDnsResolver` and associated child resources can be deleted independently of the private DNS zones themselves — this is purely a resolution-path bridge, not a data-bearing resource.

</details>

<details><summary>Playbook 4 — Fleet-wide stale record cleanup</summary>

```powershell
# Cross-reference autoregistered A records against current VM inventory in the linked VNets
$zoneRecords = Get-AzPrivateDnsRecordSet -ResourceGroupName <rg> -ZoneName <zoneName> -RecordType A
$currentVMs  = Get-AzVM -Status | Select -ExpandProperty Name

$stale = $zoneRecords | Where-Object { $_.Name -notin $currentVMs -and $_.Name -ne "@" }
$stale | Format-Table Name, Ttl

foreach ($rec in $stale) {
    Remove-AzPrivateDnsRecordSet -ResourceGroupName <rg> -ZoneName <zoneName> -Name $rec.Name -RecordType A
}
```

**Rollback:** Deleted stale records regenerate automatically on next VM restart if the VM still exists and the link has registration enabled; for genuinely decommissioned VMs, no rollback is needed.

</details>

---
## Evidence Pack

```powershell
<#
  Private DNS Zone evidence collector — read-only, safe to run in production.
  Run and attach output before escalating an unresolved private DNS ticket.
#>
param(
    [Parameter(Mandatory)] [string]$ZoneResourceGroup,
    [Parameter(Mandatory)] [string]$ZoneName,
    [string]$Fqdn
)

Write-Host "=== ZONE ===" -ForegroundColor Cyan
Get-AzPrivateDnsZone -ResourceGroupName $ZoneResourceGroup -Name $ZoneName | Format-List

Write-Host "=== VNET LINKS ===" -ForegroundColor Cyan
Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $ZoneResourceGroup -ZoneName $ZoneName |
  Format-Table Name, VirtualNetworkId, RegistrationEnabled, ProvisioningState -AutoSize

Write-Host "=== RECORD SETS (A) ===" -ForegroundColor Cyan
Get-AzPrivateDnsRecordSet -ResourceGroupName $ZoneResourceGroup -ZoneName $ZoneName -RecordType A |
  Format-Table Name, Ttl, @{L='IPs';E={($_.Records.Ipv4Address) -join ','}} -AutoSize

if ($Fqdn) {
    Write-Host "=== RESOLUTION TEST: $Fqdn ===" -ForegroundColor Cyan
    try { Resolve-DnsName -Name $Fqdn -Type A -Server 168.63.129.16 -ErrorAction Stop | Format-Table }
    catch { Write-Host "Resolution failed against 168.63.129.16: $_" -ForegroundColor Yellow }
    try { Resolve-DnsName -Name $Fqdn -Type A -ErrorAction Stop | Format-Table }
    catch { Write-Host "Resolution failed against default resolver: $_" -ForegroundColor Yellow }
}
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Resolve-DnsName -Name <fqdn> -Server 168.63.129.16` | Test resolution against Azure's resolver directly, bypassing local/custom DNS |
| `Get-AzPrivateDnsZone -ResourceGroupName <rg> -Name <zone>` | Confirm the zone exists and get its resource ID |
| `Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <rg> -ZoneName <zone>` | List every VNet linked to a zone and its registration setting |
| `New-AzPrivateDnsVirtualNetworkLink ... -EnableRegistration:$false` | Link a VNet for resolution only |
| `Get-AzPrivateEndpoint -Name <pe> \| Select PrivateDnsZoneGroup` | Check whether a Private Endpoint has DNS integration configured |
| `New-AzPrivateEndpointDnsZoneGroup` | Create/attach a DNS zone group to a Private Endpoint |
| `Get-AzPrivateDnsRecordSet -ZoneName <zone> -RecordType A` | List all A records currently in a zone |
| `Remove-AzPrivateDnsRecordSet` | Remove a specific (usually stale) record |
| `(Get-AzVirtualNetwork -Name <vnet>).DhcpOptions.DnsServers` | Check whether a VNet uses default or custom DNS |
| `Get-DnsClientGlobalSetting` | Check a client's DNS suffix search list |
| `Clear-DnsClientCache` | Clear local resolver cache before re-testing |
| `New-AzDnsResolver` / `New-AzDnsResolverInboundEndpoint` | Stand up Azure DNS Private Resolver for hybrid forwarding |
| `az network private-dns link vnet list` | CLI equivalent for listing VNet links |
| `az network private-endpoint dns-zone-group list` | CLI equivalent for checking a Private Endpoint's zone groups |

---
## 🎓 Learning Pointers

- **Peering and DNS zone links are two independent Azure constructs that happen to both involve VNets.** Internalizing this distinction resolves a large fraction of "works in one VNet, not the peered one" tickets on sight. See [Azure Private DNS zones overview](https://learn.microsoft.com/en-us/azure/dns/private-dns-overview).
- **`privatelink.*` zone names are a fixed, published list per service — never inferred.** Keep [Azure Private Endpoint DNS configuration](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns) bookmarked; guessing the zone name (e.g. assuming SQL uses the same pattern as Storage) is a common, silent failure mode.
- **168.63.129.16 is worth explicitly understanding, not just memorizing** — it's also used for platform functions like health probes and extension communication, which is why it should never be blocked outbound at the NSG/firewall layer even when it looks like unexplained traffic in flow logs. See [What is IP address 168.63.129.16](https://learn.microsoft.com/en-us/azure/virtual-network/what-is-ip-address-168-63-129-16).
- **Azure DNS Private Resolver is the modern answer to "how do I bridge on-prem DNS into Azure private zones"** — it's replacing hand-rolled forwarder VMs in current architecture guidance because it removes an unmanaged, unpatched VM from the critical path. See [Azure DNS Private Resolver overview](https://learn.microsoft.com/en-us/azure/dns/dns-private-resolver-overview).
- **Autoregistration and Private Endpoint Zone Groups are unrelated record-writing mechanisms that happen to both populate the same kind of zone resource** — conflating them leads to troubleshooting the wrong dependency (e.g. checking "registration enabled" on a VNet link when the actual record is supposed to come from a Zone Group).
- **Treat stale autoregistered records as an operational hygiene item, not an incident** — schedule periodic sweeps (see the Evidence Pack / accompanying script) rather than discovering them only when an IP gets reassigned and a client connects to the wrong host.
