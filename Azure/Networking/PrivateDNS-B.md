# Azure Private DNS Zones — Hotfix Runbook (Mode B: Ops)
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

Run these first — in order. Stop as soon as one gives you the answer.

```powershell
# 1. What does the client actually resolve the FQDN to, right now?
Resolve-DnsName -Name <fqdn> -Type A          # e.g. mystorage.privatelink.blob.core.windows.net

# 2. Is the querying VNet even linked to the zone that should own this record?
Get-AzPrivateDnsZone -ResourceGroupName <rg> -Name <zoneName> |
  Get-AzPrivateDnsVirtualNetworkLink | Select Name, VirtualNetworkId, RegistrationEnabled

# 3. If this is a Private Endpoint FQDN — does the Private Endpoint have a DNS Zone Group at all?
Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName> |
  Select -ExpandProperty PrivateDnsZoneGroup

# 4. What DNS servers is the VNet actually configured to use? (custom DNS breaks the built-in resolver path)
(Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnetName>).DhcpOptions.DnsServers

# 5. Does the record exist in the zone at all, regardless of what the client sees?
Get-AzPrivateDnsRecordSet -ResourceGroupName <rg> -ZoneName <zoneName> -RecordType A |
  Where-Object Name -like "*<hostPrefix>*"
```

| If... | Then... |
|---|---|
| Step 1 returns the **public IP** of a PaaS resource instead of a private IP | [Fix 1 — Private Endpoint DNS zone group missing/broken](#fix-1) |
| Step 2 shows no link for the VNet the client sits in (but a link exists for a *peered* VNet) | [Fix 2 — Peered VNet not linked](#fix-2) |
| Step 4 shows custom DNS servers (not "Default (Azure-provided)") | [Fix 3 — Custom DNS not forwarding to Azure](#fix-3) |
| Step 5 shows the record simply doesn't exist yet | [Fix 4 — Zone group present but record never populated](#fix-4) |
| Short name (`vm1`) fails but FQDN (`vm1.contoso.internal`) resolves fine | [Fix 5 — Missing DNS suffix search list](#fix-5) |
| Record resolves to an IP that belongs to a VM that was deleted weeks ago | [Fix 6 — Stale autoregistered record](#fix-6) |
| Client is **on-premises**, not in any Azure VNet | Skip straight to [Fix 3](#fix-3) — on-prem is just the extreme case of "not forwarding to Azure DNS" |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Azure-provided DNS (168.63.129.16)
  — every VNet gets this by default; it is the ONLY thing that knows how to answer
    private DNS zone queries for that VNet
    │
    ▼
VNet's DNS server setting
  ├─ "Default (Azure-provided)"  → private zone resolution works automatically for linked zones
  └─ Custom DNS server(s)        → resolution BREAKS unless that custom server forwards the
                                    zone's domain suffix to 168.63.129.16, or you deploy
                                    Azure DNS Private Resolver
    │
    ▼
Private DNS Zone exists (e.g. contoso.internal, or a reserved privatelink.*.<svc> name)
    │
    ▼
Virtual Network Link — the querying VNet must be explicitly linked. Peering does NOT imply a link.
  ├─ Resolution-only link  → VNet can query records already in the zone
  └─ Registration-enabled  → VMs in THIS VNet also get auto-created A/PTR records
    │
    ▼
Records actually populated in the zone
  ├─ Custom zones   → populated by VM autoregistration (needs registration-enabled link + running VM)
  └─ privatelink.* zones → populated by the Private Endpoint's "DNS Zone Group" resource,
                            NEVER by VM autoregistration (there's no VM to register)
    │
    ▼
Client query resolves correctly
```

**The two failure modes that account for most tickets:** (1) a peered VNet was never *linked* to the zone — peering only moves packets, it does not extend DNS resolution — and (2) a Private Endpoint has no DNS Zone Group, so the record was never written and the client falls through to public DNS and gets the public IP.

</details>

---
## Diagnosis & Validation Flow

1. **Establish what's actually being returned today.**
   ```powershell
   Resolve-DnsName -Name <fqdn> -Type A
   ```
   Good: a private IP (10.x/172.16-31.x/192.168.x) matching the resource's private endpoint or VM NIC. Bad: a public IP (means the query never reached the private zone — it fell through to public DNS), or `NXDOMAIN`.

2. **Confirm the querying VNet is linked to the zone.**
   ```powershell
   Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <rg> -ZoneName <zoneName> |
     Select Name, VirtualNetworkId, RegistrationEnabled, ProvisioningState
   ```
   Match `VirtualNetworkId` against the resource ID of the VNet the client's NIC actually lives in — not a peered VNet, not a similarly-named VNet in another RG. This is the single most-missed check.

3. **For Private Endpoint FQDNs, confirm the Zone Group exists and points at the right zone.**
   ```powershell
   (Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>).PrivateDnsZoneGroup
   ```
   Expected: a zone group referencing the exact reserved zone name for that service (e.g. `privatelink.blob.core.windows.net` for Storage blob, `privatelink.database.windows.net` for Azure SQL, `privatelink.vaultcore.azure.net` for Key Vault). A misspelled or wrong-service zone name means Azure never writes the record — check the exact required name against [Azure Private Endpoint DNS configuration](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns).

4. **Check the VNet's DNS server configuration.**
   ```powershell
   (Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnetName>).DhcpOptions.DnsServers
   ```
   Empty/null = Azure-provided default (good, works automatically for linked zones). Any IP listed here = custom DNS, which must itself forward the zone's suffix to `168.63.129.16` or the client will never see the private record no matter how correctly the zone and links are configured.

5. **If everything above checks out but the record still isn't there, look at the record set directly.**
   ```powershell
   Get-AzPrivateDnsRecordSet -ResourceGroupName <rg> -ZoneName <zoneName> -RecordType A
   ```
   Zone group / autoregistration writes can lag a few minutes after resource creation — don't assume broken after only 60 seconds.

---
## Common Fix Paths

<details><summary id="fix-1">Fix 1 — Private Endpoint DNS zone group missing or broken</summary>

**Symptom:** FQDN resolves to the resource's public IP instead of the private endpoint IP.

```powershell
# Check the zone group that's supposed to exist
Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName> | Select -ExpandProperty PrivateDnsZoneGroup

# Create the zone group if missing (Storage blob example — swap zone/config name for the correct service)
$zone = Get-AzPrivateDnsZone -ResourceGroupName <dnsRg> -Name "privatelink.blob.core.windows.net"
$config = New-AzPrivateDnsZoneConfig -Name "blob-config" -PrivateDnsZoneId $zone.ResourceId
New-AzPrivateEndpointDnsZoneGroup -ResourceGroupName <rg> -PrivateEndpointName <peName> `
  -Name "default" -PrivateDnsZoneConfig $config
```

**Rollback:** Removing a zone group only stops future record management for that endpoint — `Remove-AzPrivateEndpointDnsZoneGroup`. It does not affect the private endpoint's connectivity, only DNS registration.

</details>

<details><summary id="fix-2">Fix 2 — Peered VNet not linked to the zone</summary>

**Symptom:** Resolution works from the "primary" VNet but fails from a peered spoke/hub VNet, even though network connectivity (ping to the private IP) works fine.

```powershell
# Add a resolution-only link for the peered VNet — it does NOT need registration enabled
# unless VMs in that VNet also need to register their own records into this zone
$vnet = Get-AzVirtualNetwork -ResourceGroupName <peeredRg> -Name <peeredVnetName>
New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <dnsRg> -ZoneName <zoneName> `
  -Name "link-$($vnet.Name)" -VirtualNetworkId $vnet.Id -EnableRegistration:$false
```

**Rollback:** `Remove-AzPrivateDnsVirtualNetworkLink` — non-destructive to the zone or its records, only removes that VNet's ability to resolve them.

</details>

<details><summary id="fix-3">Fix 3 — Custom DNS server not forwarding to Azure (including on-premises clients)</summary>

**Symptom:** VNet's `DnsServers` setting shows a custom IP (a DNS forwarder VM, domain controller, or on-premises server), and private zone records never resolve from that VNet — or from on-prem at all.

**Option A — quick fix for a single custom DNS server:** add a conditional forwarder on that DNS server for the zone's domain suffix pointing at `168.63.129.16`.

**Option B — proper fix for on-premises/hybrid environments:** deploy Azure DNS Private Resolver so on-prem DNS can conditionally forward into Azure Private DNS without needing a manually-maintained forwarder VM:
```powershell
# Outline — full deployment requires a dedicated subnet for each endpoint type
New-AzDnsResolver -ResourceGroupName <rg> -Name <resolverName> -Location <region> -VirtualNetworkId <vnetId>
New-AzDnsResolverInboundEndpoint -ResourceGroupName <rg> -DnsResolverName <resolverName> `
  -Name "inbound" -IPConfiguration <ipConfigObject>
```
Then point the on-premises DNS server's conditional forwarder at the inbound endpoint's IP for the relevant domain suffix(es).

**Rollback:** Forwarder changes on the custom DNS server are configuration-only and reversible. Azure DNS Private Resolver resources can be deleted (`Remove-AzDnsResolver`) without affecting the private DNS zones themselves.

</details>

<details><summary id="fix-4">Fix 4 — Zone group present but record never populated</summary>

**Symptom:** Zone group exists and looks correctly configured, but `Get-AzPrivateDnsRecordSet` shows no matching record even after 15+ minutes.

```powershell
# Force reconciliation by removing and recreating the zone group — this is the supported
# way to force Azure to re-evaluate and rewrite the record
Remove-AzPrivateEndpointDnsZoneGroup -ResourceGroupName <rg> -PrivateEndpointName <peName> -Name "default"
$zone = Get-AzPrivateDnsZone -ResourceGroupName <dnsRg> -Name <correctZoneName>
$config = New-AzPrivateDnsZoneConfig -Name "config" -PrivateDnsZoneId $zone.ResourceId
New-AzPrivateEndpointDnsZoneGroup -ResourceGroupName <rg> -PrivateEndpointName <peName> `
  -Name "default" -PrivateDnsZoneConfig $config
```

**Rollback:** None needed — this recreates the same intended state; no data outside DNS records is touched.

</details>

<details><summary id="fix-5">Fix 5 — Missing DNS suffix search list (short names don't resolve)</summary>

**Symptom:** `vm1.contoso.internal` resolves but plain `vm1` doesn't, from a VM inside the linked VNet.

```powershell
# Check the VM's current DNS suffix search list
Get-DnsClientGlobalSetting

# Add the zone's domain as a suffix (persists across reboots)
Set-DnsClientGlobalSetting -SuffixSearchList @("contoso.internal")
```
Root cause is usually that the VNet's DNS suffix isn't being handed out via DHCP option 15, or the VM was joined to the VNet before the zone link with autoregistration existed. New VMs created after the link/registration is in place normally pick this up automatically via DHCP.

**Rollback:** Non-destructive; revert the suffix list to its previous value if needed.

</details>

<details><summary id="fix-6">Fix 6 — Stale autoregistered record from a deleted VM</summary>

**Symptom:** A record still resolves to the IP of a VM that was deleted or re-IP'd, causing connections to fail or hit the wrong host (only relevant to custom zones using autoregistration — privatelink zone records are managed by the zone group, not this mechanism).

```powershell
# Find and remove the stale record manually
Get-AzPrivateDnsRecordSet -ResourceGroupName <rg> -ZoneName <zoneName> -RecordType A |
  Where-Object Name -eq "<staleHostName>"
Remove-AzPrivateDnsRecordSet -ResourceGroupName <rg> -ZoneName <zoneName> -Name "<staleHostName>" -RecordType A
```
Autoregistered records are normally cleaned up automatically when a VM's NIC is deleted through Azure, but this can lag or fail to fire (e.g. NIC deleted out-of-band, or the deletion happened during a zone/link outage). Manual cleanup is the safe fallback.

**Rollback:** If removed in error, the record regenerates automatically on the next VM restart/NIC refresh (autoregistration), or can be recreated manually with `New-AzPrivateDnsRecordSet`.

</details>

---
## Escalation Evidence

Copy this template and fill in before escalating:

```
PRIVATE DNS ESCALATION — <date/time>
FQDN affected: <fqdn>
Expected result: <private IP>          Actual result: <what Resolve-DnsName returned>

Zone: <zoneName>                        Zone type: <custom / privatelink.*>
Querying VNet: <vnetName> (<resourceId>)
VNet link present for this VNet?  <Yes — registration <on/off> / No>
VNet DNS server setting: <Default (Azure-provided) / custom IP(s)>

If Private Endpoint related:
  Private Endpoint: <peName>
  DNS Zone Group present?  <Yes, targets <zoneName> / No>

Record set query result (paste):
  Get-AzPrivateDnsRecordSet -ResourceGroupName <rg> -ZoneName <zoneName> -RecordType A

What's been tried:
  <bullet list>

Business impact / urgency:
  <one line>
```

---
## 🎓 Learning Pointers

- **VNet peering never implies a DNS zone link.** This is the #1 real-world cause behind "it resolves from the hub but not the spoke." Peering moves packets; a private DNS zone needs its own explicit `VirtualNetworkLink` per VNet that needs to resolve it. See [Azure Private DNS zones overview](https://learn.microsoft.com/en-us/azure/dns/private-dns-overview).
- **`privatelink.*` zone names are reserved, not custom.** Each PaaS service that supports Private Link has one exact required zone name (e.g. `privatelink.database.windows.net` for Azure SQL). A zone created under a slightly different name silently fails to integrate — there's no error, the record just never appears. Cross-check against [Azure Private Endpoint DNS configuration](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns) for the exact name per service before assuming the zone group is broken.
- **Custom DNS in a VNet opts you out of the automatic path entirely.** The moment a VNet's DNS servers setting is anything other than "Default (Azure-provided)", every private zone lookup depends on that custom server correctly forwarding to `168.63.129.16` — this is a very common regression when someone points a VNet at a domain controller for AD-integrated DNS without adding the forwarder.
- **Autoregistration and Private Endpoint DNS Zone Groups are two unrelated mechanisms** — don't troubleshoot a `privatelink.*` zone by checking VNet link "registration enabled" status; that flag only matters for custom zones with VM autoregistration.
- **For hybrid/on-premises resolution, Azure DNS Private Resolver is the current recommended path** over running a dedicated DNS forwarder VM — it removes a VM to patch/monitor and is the direction Microsoft's guidance has moved. See [What is Azure DNS Private Resolver](https://learn.microsoft.com/en-us/azure/dns/dns-private-resolver-overview).
- **Stale autoregistered records after VM deletion are a known operational gap**, not a bug to "fix" structurally — build periodic record hygiene sweeps (see the accompanying script) into routine environment maintenance rather than waiting for an IP-reuse collision to surface it.
