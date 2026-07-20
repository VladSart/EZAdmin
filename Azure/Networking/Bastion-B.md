# Azure Bastion — Hotfix Runbook (Mode B: Ops)
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

```powershell
# 1. Confirm the Bastion resource exists, its SKU, and provisioning state
Get-AzBastion -ResourceGroupName <rg> -Name <bastionName> | Select-Object Name, ProvisioningState, SkuText

# 2. Confirm AzureBastionSubnet sizing and presence (dedicated deployments only — not Developer SKU)
Get-AzVirtualNetworkSubnetConfig -Name AzureBastionSubnet -VirtualNetwork (Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnetName>)

# 3. Check for an NSG on AzureBastionSubnet and whether it has the full required rule set
az network nic list-effective-nsg --ids (Get-AzBastion -ResourceGroupName <rg> -Name <bastionName>).IpConfigurations.Id 2>$null
# (if the above returns nothing, check the subnet-level NSG directly via the portal or Get-AzNetworkSecurityGroup)

# 4. Check for an NSG on the TARGET VM's subnet — a separate, equally common blocker
Get-AzNetworkSecurityGroup -ResourceGroupName <rg> | Where-Object { $_.Subnets.Id -match "<targetVmSubnetName>" }

# 5. Confirm which SKU is deployed — native client / IP-Connect / shareable link / session recording
#    all require Standard or Premium; native client and file transfer specifically need Standard+
(Get-AzBastion -ResourceGroupName <rg> -Name <bastionName>).SkuText
```

| Finding | Interpretation | Do this |
|---|---|---|
| `ProvisioningState` not `Succeeded` | Deployment still in progress or failed | Wait for completion (~10 min); if failed, check subnet size and public IP allocation |
| `AzureBastionSubnet` smaller than `/26` | Subnet too small — dedicated SKUs require `/26` or larger | Resize the subnet (may require re-addressing the VNet) |
| NSG present on `AzureBastionSubnet` missing any of the 8 required rules | Bastion platform updates and/or VM connectivity silently break | Fix 1 |
| NSG on target VM subnet has no inbound allow from `AzureBastionSubnet` for 3389/22 | Bastion reaches the subnet but the VM itself blocks it | Fix 2 |
| User tries native client (`az network bastion rdp`/`ssh`) on Basic SKU | Feature not available below Standard | Fix 3 — upgrade SKU, or use browser-based connection instead |
| Black screen after clicking Connect in the portal | Client-side WebSocket block, or NSG blocking RDP/SSH between Bastion and VM | Fix 4 |
| "Your session has expired" before session starts | Direct URL access outside the Azure portal flow — expected security behavior, not a bug | Fix 5 |
| JIT (Just-In-Time) access enabled on the target VM | Missing JIT role assignment for the connecting user | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Bastion SKU selected (Developer / Basic / Standard / Premium)
    │
    ├─ Developer: shared infra, no AzureBastionSubnet, no public IP, ONE VM at a time, no peering support
    │
    └─ Basic / Standard / Premium: dedicated deployment
            │
            ├─ AzureBastionSubnet exists, sized /26 or larger, named EXACTLY "AzureBastionSubnet"
            ├─ Public IP address (Standard SKU, Static) — EXCEPT Premium private-only deployment
            └─ NSG on AzureBastionSubnet (if applied) has ALL 8 required inbound+outbound rules
                    │  (missing even one blocks platform updates AND/OR VM connectivity)
                    ▼
            Bastion host provisioned, ProvisioningState = Succeeded
                    │
                    ▼
            User initiates connection (Azure portal browser client — all SKUs)
                    │        or (native RDP/SSH client / IP-Connect / shareable link — Standard/Premium only)
                    ▼
            NSG on TARGET VM SUBNET allows inbound 3389/22 (or custom port) FROM AzureBastionSubnet
                    │  (a SEPARATE NSG from the one above — both must independently allow)
                    ▼
            [If JIT enabled] Connecting user has the JIT role assignments on the target VM
                    │
                    ▼
            RDP/SSH session established over TLS (port 443) — target VM never needs a public IP
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm Bastion resource health.**
   ```powershell
   Get-AzBastion -ResourceGroupName <rg> -Name <bastionName> | Select-Object ProvisioningState, SkuText
   ```
   Expected: `Succeeded`. Bad sign: any other state — check subnet sizing and public IP allocation before anything else.

2. **Confirm subnet requirements for dedicated SKUs.** `AzureBastionSubnet` must be `/26` or larger and named exactly that (case-sensitive, no variations). Expected: subnet present and correctly sized. Bad sign: subnet missing, misnamed, or `/27` or smaller — deployment or scaling will fail.

3. **Confirm NSG on `AzureBastionSubnet` (if one is applied) has all 8 required rules.** This is the single highest-value check for "Bastion was working, now it isn't" tickets after any NSG change.
   | Rule | Direction | Source/Dest | Port(s) |
   |---|---|---|---|
   | AllowHttpsInbound | Inbound | Internet → * | 443 |
   | AllowGatewayManagerInbound | Inbound | GatewayManager → * | 443 |
   | AllowBastionHostCommunication | Inbound | VirtualNetwork ↔ VirtualNetwork | 8080, 5701 |
   | AllowAzureLoadBalancerInbound | Inbound | AzureLoadBalancer → * | 443 |
   | AllowSshRdpOutbound | Outbound | * → VirtualNetwork | 22, 3389 |
   | AllowAzureCloudOutbound | Outbound | * → AzureCloud | 443 |
   | AllowBastionCommunication | Outbound | VirtualNetwork ↔ VirtualNetwork | 8080, 5701 |
   | AllowHttpOutbound | Outbound | * → Internet | 80 |

   Expected: all 8 present. Bad sign: any missing — omitting even one blocks Bastion platform updates and/or breaks connectivity, and the failure mode does not clearly point back to the missing rule.

4. **Confirm the TARGET VM subnet's NSG separately.** This is a DIFFERENT NSG from step 3. Expected: an inbound allow rule for 3389/22 (or custom port) sourced from the `AzureBastionSubnet` range specifically (best practice — not from the whole VNet or Internet). Bad sign: no such rule, or a rule that's present but scoped incorrectly.

5. **If using native client, IP-Connect, or shareable link — confirm SKU.** Expected: Standard or Premium. Bad sign: Basic or Developer — these features simply aren't available; there's no override.

6. **For a black screen specifically, use the built-in Connection Troubleshoot tool** (Bastion resource → Help → Connection Troubleshoot in the Azure portal) to run a direct TCP check from a VM to the target. Expected: reports the RDP/SSH port reachable. Bad sign: reports blocked — narrows the fault to a specific NSG hop.

7. **If Just-In-Time (JIT) access is enabled on the target VM, confirm the connecting user has both JIT role assignments** (`Microsoft.Security/locations/jitNetworkAccessPolicies/read` and `/write`). Expected: both present. Bad sign: missing either — connection is blocked even with an otherwise-correct Bastion/NSG configuration.

---
## Common Fix Paths

<details><summary>Fix 1 — NSG on AzureBastionSubnet missing required rules</summary>

```powershell
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName>

Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "AllowHttpsInbound" -Access Allow -Protocol Tcp `
    -Direction Inbound -Priority 100 -SourceAddressPrefix Internet -SourcePortRange * `
    -DestinationAddressPrefix * -DestinationPortRange 443

Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "AllowGatewayManagerInbound" -Access Allow -Protocol Tcp `
    -Direction Inbound -Priority 110 -SourceAddressPrefix GatewayManager -SourcePortRange * `
    -DestinationAddressPrefix * -DestinationPortRange 443

Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "AllowAzureLoadBalancerInbound" -Access Allow -Protocol Tcp `
    -Direction Inbound -Priority 120 -SourceAddressPrefix AzureLoadBalancer -SourcePortRange * `
    -DestinationAddressPrefix * -DestinationPortRange 443

Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "AllowBastionHostCommunication" -Access Allow -Protocol * `
    -Direction Inbound -Priority 130 -SourceAddressPrefix VirtualNetwork -SourcePortRange * `
    -DestinationAddressPrefix VirtualNetwork -DestinationPortRange 8080,5701

Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "AllowSshRdpOutbound" -Access Allow -Protocol * `
    -Direction Outbound -Priority 100 -SourceAddressPrefix * -SourcePortRange * `
    -DestinationAddressPrefix VirtualNetwork -DestinationPortRange 22,3389

Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "AllowAzureCloudOutbound" -Access Allow -Protocol Tcp `
    -Direction Outbound -Priority 110 -SourceAddressPrefix * -SourcePortRange * `
    -DestinationAddressPrefix AzureCloud -DestinationPortRange 443

Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "AllowBastionCommunication" -Access Allow -Protocol * `
    -Direction Outbound -Priority 120 -SourceAddressPrefix VirtualNetwork -SourcePortRange * `
    -DestinationAddressPrefix VirtualNetwork -DestinationPortRange 8080,5701

Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "AllowHttpOutbound" -Access Allow -Protocol * `
    -Direction Outbound -Priority 130 -SourceAddressPrefix * -SourcePortRange * `
    -DestinationAddressPrefix Internet -DestinationPortRange 80

Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg
```
All 8 rules are required together — omitting any one blocks Bastion platform updates and/or connectivity in a way that doesn't clearly self-diagnose. Cross-reference `NSG-A.md` for general NSG rule-evaluation mechanics.

**Rollback:** remove the NSG from the subnet entirely (`Set-AzVirtualNetworkSubnetConfig -NetworkSecurityGroup $null`) as an emergency unblock while the rule set is corrected — only appropriate as a short-term measure.
</details>

<details><summary>Fix 2 — Target VM subnet NSG blocking Bastion→VM traffic</summary>

```powershell
$targetNsg = Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <targetSubnetNsgName>
$bastionSubnetPrefix = (Get-AzVirtualNetworkSubnetConfig -Name AzureBastionSubnet -VirtualNetwork (Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnetName>)).AddressPrefix

Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $targetNsg -Name "AllowBastionInbound" -Access Allow -Protocol Tcp `
    -Direction Inbound -Priority 100 -SourceAddressPrefix $bastionSubnetPrefix -SourcePortRange * `
    -DestinationAddressPrefix * -DestinationPortRange 3389,22

Set-AzNetworkSecurityGroup -NetworkSecurityGroup $targetNsg
```
Scope the source to the actual `AzureBastionSubnet` CIDR, not the whole VNet or a wildcard — this keeps RDP/SSH ports closed to everything except the Bastion host itself. If using the Standard/Premium custom-port feature, allow the `VirtualNetwork` service tag as the source instead per Microsoft's guidance for that scenario.

**Rollback:** remove the added rule if it turns out a different NSG (higher in evaluation order) is the actual blocker.
</details>

<details><summary>Fix 3 — Feature unavailable on current SKU (native client, IP-Connect, shareable link, session recording)</summary>

```powershell
$bastion = Get-AzBastion -ResourceGroupName <rg> -Name <bastionName>
$bastion.SkuText = "Standard"   # or "Premium"
Set-AzBastion -InputObject $bastion
```
Upgrades take approximately 10 minutes. **Downgrades are not supported** — a SKU can only be upgraded, never reduced; a downgrade requires deleting and recreating the resource. Confirm the target SKU truly needs the extra capability before upgrading, since this is a one-way door. Native client, custom ports, IP-Connect, shareable links, and file transfer all require Standard or above; session recording and private-only deployment require Premium specifically.

**Rollback:** none — SKU downgrades require delete/recreate, not a rollback command.
</details>

<details><summary>Fix 4 — Black screen in the Azure portal</summary>

1. Rule out client-side WebSocket blocking: confirm the user's local network/firewall allows outbound WebSocket traffic (the portal's browser-based session rides over this).
2. Use the Bastion resource's **Connection Troubleshoot** tool (Help section in the portal) to run a direct TCP check between a VM and the target — this isolates whether the block is between browser↔Bastion or Bastion↔target VM.
3. Re-check both NSGs (Fix 1 and Fix 2) — a black screen with no other error is the single most common symptom of an NSG blocking RDP/SSH between Bastion and the target VM specifically, not a Bastion-host problem itself.

**Rollback:** not applicable — diagnostic fix.
</details>

<details><summary>Fix 5 — "Your session has expired" error</summary>

This is expected, secure-by-design behavior when a Bastion session URL is opened directly (e.g., a bookmarked link, or opened in a second browser tab) rather than through the normal Azure portal connection flow. Instruct the user to sign back into the Azure portal and re-initiate the connection from there rather than reusing a saved/direct URL.

**Rollback:** not applicable — not a fault condition.
</details>

<details><summary>Fix 6 — Just-In-Time (JIT) access blocking connection</summary>

```powershell
# Confirm the user's role assignments include both JIT actions at the required scope
Get-AzRoleAssignment -SignInName <user@domain.com> -Scope /subscriptions/<subId>/resourceGroups/<rg>
```
Ensure the connecting user's role includes both `Microsoft.Security/locations/jitNetworkAccessPolicies/read` and `/write` at the relevant scope (built into several built-in roles, e.g. Contributor and Security Admin, but NOT into Reader). Without both, the user can see the VM but cannot request/activate JIT access, which then blocks the Bastion connection even if Bastion and NSGs are otherwise correctly configured.

**Rollback:** not applicable — permission-grant fix.
</details>

---
## Escalation Evidence

```
Ticket: Azure Bastion connectivity failure
Client / Tenant: <name>
Bastion resource: <subscription>/<rg>/<bastionName>
SKU: <Developer / Basic / Standard / Premium>
ProvisioningState: <state>
AzureBastionSubnet size: <CIDR>
NSG on AzureBastionSubnet: <present/absent, rule count vs. 8 required>
NSG on target VM subnet: <present/absent, Bastion-source rule present?>
Target VM: <name/resource ID>
Connection method attempted: <browser / native RDP-SSH / IP-Connect / shareable link>
JIT enabled on target VM: <yes/no>
Symptom: <black screen / session expired / can't connect / feature greyed out>
Connection Troubleshoot tool result: <paste>
Escalation reason: <SKU upgrade required / NSG rule gap after remediation attempt / unexplained platform issue>
```

---
## 🎓 Learning Pointers

- **Azure Bastion NSG requirements are all-or-nothing — 8 specific rules across inbound and outbound, and missing even one silently blocks platform updates or connectivity.** Always work from the full published rule table rather than reasoning from first principles about what "should" be needed. See [Configure NSG rules for Azure Bastion](https://learn.microsoft.com/en-us/azure/bastion/bastion-nsg).
- **A black screen with no error is almost always an NSG problem between Bastion and the target VM, not a Bastion host problem.** Check the target VM subnet's NSG before escalating a "Bastion is broken" ticket. See [Troubleshoot Azure Bastion connectivity problems](https://learn.microsoft.com/en-us/troubleshoot/azure/bastion/troubleshoot-connectivity-problems).
- **SKU upgrades are one-way — there is no downgrade path**, only delete-and-recreate. Confirm the actual need (native client? session recording? private-only?) before committing to Standard or Premium.
- **The target VM never needs a public IP address with Bastion** — if a ticket mentions "we removed the public IP and now RDP doesn't work," that's very likely someone trying to RDP directly instead of through Bastion, not a Bastion fault.
- **Developer SKU is free but fundamentally different, not just "Basic with a discount"** — no dedicated host, one VM connection at a time, no VNet peering support, not suitable for production. Don't recommend it as a cost-saving swap for a production Basic/Standard deployment.
- **JIT (Just-In-Time) access and Bastion are independent, stackable controls** — a user can be fully permitted at the Bastion/NSG layer and still be blocked by a missing JIT role assignment, or vice versa. See [Enable just-in-time access on VMs](https://learn.microsoft.com/en-us/azure/defender-for-cloud/just-in-time-access-usage).
