# Azure Bastion — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

**In scope:** Azure Bastion architecture across all four SKU tiers (Developer, Basic, Standard, Premium), deployment models (dedicated vs. shared/Developer vs. private-only), NSG requirements, connection methods (browser, native client, IP-Connect, shareable links), host scaling, session recording, and JIT (Just-In-Time) access interaction.

**Out of scope:**
- **NSG rule mechanics in general** (priority evaluation, service tags, ASGs beyond what Bastion specifically requires) — see `NSG-A.md`/`NSG-B.md`.
- **Defender for Cloud JIT policy configuration itself** (creating/tuning JIT policies) — this runbook covers only the role-assignment intersection with Bastion connectivity; see Microsoft Defender for Cloud documentation for JIT policy authoring.
- **Application Gateway / Web Application Firewall** — a different product for inbound HTTP(S) reverse-proxying, unrelated to Bastion's RDP/SSH management-plane access model.
- **Virtual network peering mechanics in general** — covered only as they relate to serving multiple VNets from one Bastion host.

**Assumptions:** Reader is comfortable with Azure VNets, NSGs, and basic RBAC. Examples use Az PowerShell and Azure CLI; portal equivalents exist for all operations shown.

---
## How It Works

<details><summary>Full architecture</summary>

Azure Bastion is a fully managed PaaS service that provides RDP/SSH connectivity to VMs **over TLS on port 443**, without requiring a public IP address, agent, or special client software on the target VM. The user connects through the Azure portal (or, on higher SKUs, a native client) and Bastion proxies the session to the target VM over its **private** IP address within the VNet.

**The four SKU tiers are not simply "more of the same" — they represent genuinely different deployment architectures:**

| Category | Feature | Developer | Basic | Standard | Premium |
|---|---|---|---|---|---|
| Deployment | Requires `AzureBastionSubnet` | No | Yes | Yes | Yes |
| Deployment | Requires Public IP | No | Yes | Yes | No (private-only option) |
| Deployment | Dedicated bastion host | No (shared) | Yes | Yes | Yes |
| Deployment | VNet peering support | No | Yes | Yes | Yes |
| Connectivity | Connect to peered VNets | No | Yes | Yes | Yes |
| Connectivity | Concurrent connections | No (1 VM at a time) | Yes | Yes | Yes |
| Connectivity | RDP to Linux / SSH to Windows | No | No | Yes | Yes |
| Security | Session recording | No | No | No | Yes |
| Security | Private-only deployment | No | No | No | Yes |
| Connection methods | Native client (CLI) | No | No | Yes | Yes |
| Connection methods | Custom inbound port | No | No | Yes | Yes |
| Connection methods | IP-Connect | No | No | Yes | Yes |
| Connection methods | Shareable link | No | No | Yes | Yes |
| Connection methods | File transfer (native client) | No | No | Yes | Yes |
| Scale | Host scaling | No | No | Yes (2-50 instances) | Yes (2-50 instances) |
| Cost | Hourly charge | Free | Paid | Paid | Paid |

**Developer SKU** is architecturally distinct from the other three, not a cut-down version of Basic: it uses **shared, Microsoft-managed infrastructure**, requires no dedicated `AzureBastionSubnet` and no public IP, but supports only **one VM connection at a time** and cannot reach peered VNets. It's explicitly positioned for dev/test, not production.

**Basic, Standard, and Premium** are all dedicated deployments requiring a dedicated `AzureBastionSubnet` (must be exactly named `AzureBastionSubnet`, sized `/26` or larger) and — except for Premium's private-only option — a Standard-SKU static public IP. Basic provides a fixed two-instance deployment (40 RDP / 80 SSH concurrent session capacity); Standard and Premium support **host scaling** from 2 to 50 instances, linearly increasing capacity (up to 1,000 concurrent RDP or 2,000 concurrent SSH sessions at maximum scale).

**Connection methods** diverge sharply by SKU. All four tiers support the **browser-based HTML5 client** through the Azure portal — no additional software needed. Standard and Premium additionally support the **native client** (the OS's own RDP/SSH client, invoked via Azure CLI: `az network bastion rdp`/`ssh`), which is required for file transfer and supports Microsoft Entra ID Kerberos authentication passthrough. Standard and Premium also support **IP-Connect** (connecting to a VM by private IP address rather than resource ID — useful for on-prem or cross-cloud VMs reachable via peering/VPN/ExpressRoute) and **shareable links** (a link that lets a user connect to a specific VM without needing Azure portal access or RBAC on the VM resource itself, governed instead by link-level permissions).

**Session recording** (Premium only) captures RDP/SSH session activity for compliance/audit purposes, typically to a storage account, and requires explicit configuration — it is not automatic on Premium.

**Private-only deployment** (Premium only) removes the public IP requirement entirely, keeping Bastion's own control-plane traffic on a fully private path. This is the strictest security posture available and is often paired with Azure Private Link Scope patterns elsewhere in the estate.

**Network security group requirements** are the most operationally significant architectural detail. If an NSG is applied to `AzureBastionSubnet` at all, **all 8 specific rules must be present together** — this is explicitly called out by Microsoft as an all-or-nothing requirement, not a set of independent options:

| Rule name | Direction | Source | Destination | Port(s) | Protocol |
|---|---|---|---|---|---|
| AllowHttpsInbound | Inbound | Internet | * | 443 | TCP |
| AllowGatewayManagerInbound | Inbound | GatewayManager | * | 443 | TCP |
| AllowBastionHostCommunication | Inbound | VirtualNetwork | VirtualNetwork | 8080, 5701 | * |
| AllowAzureLoadBalancerInbound | Inbound | AzureLoadBalancer | * | 443 | TCP |
| AllowSshRdpOutbound | Outbound | * | VirtualNetwork | 22, 3389 | * |
| AllowAzureCloudOutbound | Outbound | * | AzureCloud | 443 | TCP |
| AllowBastionCommunication | Outbound | VirtualNetwork | VirtualNetwork | 8080, 5701 | * |
| AllowHttpOutbound | Outbound | * | Internet | 80 | * |

Omitting even one of these rules can silently block Bastion from receiving platform updates, or block actual VM connectivity — and the resulting symptom (typically a black screen, or a generic connection failure) does not point back to the specific missing rule. Microsoft additionally enforces this at the API level: attempting to apply an NSG to `AzureBastionSubnet` that's missing required rules produces an explicit creation/update failure rather than silently accepting a partial rule set.

A **second, entirely separate NSG** — on the target VM's own subnet — must independently allow inbound RDP/SSH (3389/22, or a custom port on Standard/Premium) from the `AzureBastionSubnet` address range. This is the single most common real-world Bastion connectivity gap: administrators correctly configure the Bastion-subnet NSG and forget the target-subnet NSG needs its own, separate allow rule.

**Just-In-Time (JIT) access**, a Defender for Cloud feature, layers on top of Bastion independently. If JIT is enabled on a target VM, the connecting user needs both `Microsoft.Security/locations/jitNetworkAccessPolicies/read` and `/write` permissions at the relevant scope — built into some roles (Contributor, Security Admin) but not Reader. A user can be fully correctly provisioned at the Bastion/NSG layer and still be blocked purely on missing JIT role assignments, or vice versa — these are independent gates, not a single combined permission check.

</details>

---
## Dependency Stack

```
Layer 6:  Connecting user's RBAC + (if applicable) JIT role assignments
              (JIT read+write actions required IF JIT is enabled on the target VM — independent of Bastion RBAC)
Layer 5:  Connection method availability per SKU
              (browser: all SKUs | native client/IP-Connect/shareable link/file transfer: Standard+ | session recording/private-only: Premium only)
Layer 4:  Target VM subnet NSG — inbound allow for RDP/SSH FROM AzureBastionSubnet
              (a SEPARATE NSG from Layer 3 — both must independently allow, this is the #1 real-world gap)
Layer 3:  AzureBastionSubnet NSG (if applied) — ALL 8 required rules present together
              (missing any one: platform updates and/or connectivity silently break)
Layer 2:  Bastion host provisioned (ProvisioningState = Succeeded)
              ├─ Dedicated (Basic/Standard/Premium): AzureBastionSubnet (/26+) + Public IP (except Premium private-only)
              └─ Developer: shared infra, no subnet, no public IP required
Layer 1:  SKU tier selected — determines EVERY capability above, not just performance/cost
              (Developer / Basic / Standard / Premium — upgrade-only, no downgrade path)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Can't create/apply NSG on AzureBastionSubnet | Missing one or more of the 8 required rules — Azure rejects incomplete rule sets on this subnet specifically | Compare against the full required-rule table |
| Black screen after clicking Connect, no other error | NSG blocking RDP/SSH between Bastion and target VM (almost always the TARGET subnet's NSG, not the Bastion subnet's) | Target VM subnet NSG inbound rules |
| Black screen AND WebSocket-related browser console errors | Client-side firewall/proxy blocking WebSocket traffic | User's local network/firewall configuration |
| "Unable to connect" with no further detail | Bastion `ProvisioningState` not `Succeeded`, or a broader Azure Service Health issue | `Get-AzBastion`, then Azure Service Health |
| Native client command fails / feature greyed out in portal | SKU is Basic or Developer — native client requires Standard+ | `SkuText` on the Bastion resource |
| File transfer doesn't work via portal | Expected — file transfer works ONLY via native client (Standard/Premium), never via PowerShell or the portal browser session | Confirm connection method, not a bug |
| Session recording not appearing | SKU is not Premium, or recording wasn't explicitly configured (it's not automatic even on Premium) | SKU tier + session recording configuration |
| "Your session has expired" before session starts | Bastion session URL opened directly/bookmarked, outside the normal Azure portal flow | Expected behavior — re-initiate via portal |
| User can see the VM but connection is blocked | Missing JIT role assignment (`jitNetworkAccessPolicies/read` and `/write`) despite correct Bastion/NSG config | User's role assignments at the relevant scope |
| Can't reach a VM in a peered VNet | Developer SKU (no peering support), or missing "Allow gateway transit"/"Use remote gateways" equivalent Bastion-specific peering configuration | SKU tier; VNet peering + Bastion's own multi-VNet support model |
| Trying to downgrade SKU and can't find the option | Not supported — downgrade requires delete and recreate | No portal downgrade path exists by design |
| Multiple teams complain of connection slowness at scale | Basic SKU's fixed 2-instance capacity ceiling reached (40 RDP/80 SSH sessions) | SKU tier; consider Standard/Premium with host scaling |
| NSG on AzureBastionSubnet looks complete but connectivity still fails | Check the SEPARATE target VM subnet NSG — this is the far more common gap | Target subnet NSG, not the Bastion subnet NSG |

---
## Validation Steps

1. **Confirm Bastion resource state and SKU.**
   ```powershell
   Get-AzBastion -ResourceGroupName <rg> -Name <bastionName> | Select-Object ProvisioningState, SkuText
   ```
   Good: `Succeeded`. Bad: any other state.

2. **Confirm subnet compliance (dedicated SKUs).**
   ```powershell
   (Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnetName>).Subnets | Where-Object Name -eq "AzureBastionSubnet" | Select-Object Name, AddressPrefix
   ```
   Good: exact name `AzureBastionSubnet`, prefix `/26` or larger. Bad: misnamed or too small.

3. **Confirm all 8 NSG rules on AzureBastionSubnet (if an NSG is applied).** Good: all 8 present exactly as specified. Bad: any missing — this is an all-or-nothing requirement, not best-effort.

4. **Confirm the target VM subnet's NSG independently.** Good: inbound allow for 3389/22 (or custom port) sourced from the Bastion subnet range. Bad: absent, or scoped to the wrong source.

5. **Confirm connection-method availability matches SKU.** Good: native client/IP-Connect/shareable link/file transfer requests only made against Standard/Premium deployments. Bad: attempted on Basic/Developer — will fail or be unavailable in the UI, not a bug to chase.

6. **If JIT is enabled, confirm the connecting user's role assignments.**
   ```powershell
   Get-AzRoleAssignment -SignInName <user@domain.com> -Scope <targetVmResourceId>
   ```
   Good: role includes both JIT read and write actions. Bad: Reader-only or a custom role missing these actions.

7. **Use the Connection Troubleshoot tool for unexplained failures.** Azure portal → Bastion resource → Help → Connection Troubleshoot, which runs a Network Watcher-backed direct TCP check. Good: reports the port reachable. Bad: reports blocked — pinpoints which hop (client↔Bastion or Bastion↔VM) is the actual fault.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Resource-level confirmation.** `ProvisioningState`, SKU, subnet compliance, public IP presence/absence per SKU rules.

**Phase 2 — Network security group audit (both NSGs, separately).** `AzureBastionSubnet` NSG (all 8 rules) and target VM subnet NSG (Bastion-sourced RDP/SSH allow) — these are two independent checks and both must pass.

**Phase 3 — Client-side verification.** Browser WebSocket support/firewall for portal-based connections; correct native client and Azure CLI version for Standard/Premium native-client connections.

**Phase 4 — Permission-layer verification.** Standard RBAC for Bastion/VM access, PLUS JIT role assignments if JIT is enabled on the target — these are independent and both required when applicable.

**Phase 5 — Feature-availability confirmation.** Before troubleshooting a "missing feature" ticket as a bug, confirm the SKU actually supports it — this resolves a large fraction of Basic/Developer-tier tickets immediately.

**Phase 6 — Scale/capacity verification.** For intermittent failures under load, check SKU capacity ceiling (Basic's fixed 2-instance limit) against actual concurrent usage before assuming a configuration fault.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield Bastion deployment for a new client</summary>

1. Choose SKU based on requirements: Developer for dev/test only (never production), Basic for simple production RDP/SSH with modest concurrency, Standard for native client/scale/IP-Connect/shareable links, Premium for compliance-driven session recording or private-only deployment.
2. Provision `AzureBastionSubnet` sized generously above `/26` if any future host scaling is anticipated — resizing later may require VNet re-addressing.
3. Deploy the Bastion resource; if applying an NSG to the subnet, apply all 8 required rules in the same change, not incrementally — a partial rule set can block the deployment itself.
4. Configure target VM subnet NSGs to allow inbound from the Bastion subnet specifically (not a broader source) before the first user connection attempt.
5. If Defender for Cloud JIT is in use, confirm role assignments for the support team BEFORE go-live, not reactively after the first blocked connection.
</details>

<details><summary>Playbook 2 — SKU upgrade for expanded capability</summary>

1. Confirm the actual driver: native client need, scale requirement, session recording compliance mandate, or private-only security requirement.
2. Remember upgrades are one-way — plan for the target SKU's ongoing cost, not just the immediate feature need.
3. Execute the upgrade (`Set-AzBastion` with updated `SkuText`); expect ~10 minutes for completion, during which existing sessions may be briefly interrupted.
4. If upgrading specifically for private-only deployment (Premium), plan the public IP removal as a distinct follow-on step, not automatic with the SKU change itself.

**Rollback:** none in the traditional sense — if the upgrade doesn't meet the need, the only path is forward to a still-higher SKU or delete/recreate at a lower one (destructive, loses configuration).
</details>

<details><summary>Playbook 3 — Multi-VNet consolidation via peering</summary>

1. Confirm target SKU supports peering (Basic, Standard, Premium — NOT Developer).
2. Deploy a single Bastion host in a hub VNet rather than one per spoke VNet — this is the primary cost/operational benefit of peering support.
3. Confirm peered VNets have "Allow gateway transit"/"Use remote gateways" configured appropriately if a VPN/ExpressRoute gateway is also in the mix, since gateway transit and Bastion reachability are governed by separate peering settings.
4. Validate connectivity to a VM in EACH peered VNet individually before declaring the consolidation complete — peering misconfiguration on one spoke doesn't affect others.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Azure Bastion diagnostic evidence for escalation.
.DESCRIPTION
    Read-only. Gathers Bastion resource state, SKU, subnet compliance, and NSG rule
    presence for both the Bastion subnet and target VM subnet.
.PARAMETER ResourceGroupName
    Resource group containing the Bastion resource.
.PARAMETER BastionName
    Name of the Bastion resource.
.PARAMETER TargetVmSubnetName
    Optional. Name of the target VM's subnet, to check its NSG for a Bastion-sourced allow rule.
.EXAMPLE
    .\Get-BastionEvidence.ps1 -ResourceGroupName rg-network-prod -BastionName bastion-hub-01 -TargetVmSubnetName snet-workloads
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$BastionName,
    [Parameter(Mandatory = $false)][string]$TargetVmSubnetName
)

$bastion = Get-AzBastion -ResourceGroupName $ResourceGroupName -Name $BastionName
$requiredRules = @("AllowHttpsInbound","AllowGatewayManagerInbound","AllowBastionHostCommunication",
                    "AllowAzureLoadBalancerInbound","AllowSshRdpOutbound","AllowAzureCloudOutbound",
                    "AllowBastionCommunication","AllowHttpOutbound")

$evidence = [PSCustomObject]@{
    BastionName        = $bastion.Name
    ProvisioningState  = $bastion.ProvisioningState
    SkuText            = $bastion.SkuText
    IpConfigCount      = $bastion.IpConfigurations.Count
}
$evidence | Format-List

if ($TargetVmSubnetName) {
    $nsgs = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName
    $targetNsg = $nsgs | Where-Object { $_.Subnets.Id -match $TargetVmSubnetName }
    if ($targetNsg) {
        Write-Host "Target subnet NSG rules referencing RDP/SSH (3389/22):" -ForegroundColor Cyan
        $targetNsg.SecurityRules | Where-Object { $_.DestinationPortRange -match "3389|22" } | Format-Table Name, Access, Direction, SourceAddressPrefix, DestinationPortRange -AutoSize
    } else {
        Write-Host "No NSG found on target subnet '$TargetVmSubnetName' — traffic is unrestricted at this layer." -ForegroundColor Yellow
    }
}

$evidence | Export-Csv -Path ".\BastionEvidence_$($BastionName)_$(Get-Date -Format yyyyMMdd_HHmm).csv" -NoTypeInformation
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-AzBastion` | Resource state, SKU, IP configuration |
| `Set-AzBastion -SkuText <sku>` | Upgrade SKU (upgrade-only, ~10 min) |
| `Get-AzVirtualNetworkSubnetConfig -Name AzureBastionSubnet` | Confirm subnet name/size |
| `Get-AzNetworkSecurityGroup` | Retrieve NSG for rule audit (both Bastion subnet and target subnet) |
| `Add-AzNetworkSecurityRuleConfig` / `Set-AzNetworkSecurityGroup` | Add/apply required NSG rules |
| `az network bastion rdp --name <bastion> --resource-group <rg> --target-resource-id <vmId>` | Native RDP client connection (Standard/Premium) |
| `az network bastion ssh --name <bastion> --resource-group <rg> --target-resource-id <vmId> --auth-type ssh-key` | Native SSH client connection (Standard/Premium) |
| `az network bastion tunnel` | Generic TCP tunnel via Bastion (Standard/Premium) |
| Portal: Bastion → Help → Connection Troubleshoot | Network Watcher-backed direct TCP check, pinpoints which hop is blocked |
| `Get-AzRoleAssignment -Scope <vmResourceId>` | Confirm JIT role assignments for a connecting user |

---
## 🎓 Learning Pointers

- **The four Bastion SKUs are different products sharing a name, not a simple good/better/best price ladder.** Developer uses entirely shared infrastructure and caps at one VM connection; the jump from Basic to Standard unlocks an entire connection-method category (native client, IP-Connect, shareable links), not just more capacity. See [Choose the right Azure Bastion SKU](https://learn.microsoft.com/en-us/azure/bastion/bastion-sku-comparison).
- **NSG requirements on AzureBastionSubnet are all 8 rules together, or none at all** — this is enforced at the API level (Azure rejects incomplete rule sets on this specific subnet), unlike ordinary NSG configuration where partial rule sets are always technically valid. See [Configure NSG rules for Azure Bastion](https://learn.microsoft.com/en-us/azure/bastion/bastion-nsg).
- **Two separate NSGs gate every connection — the Bastion subnet's and the target VM subnet's — and the target subnet's NSG is the far more commonly forgotten one.** A black screen with no clear error is the signature symptom of this specific gap.
- **SKU changes are one-way (upgrade only)** — there is no supported downgrade path short of deleting and recreating the resource, which loses the existing configuration. Confirm the actual driver before upgrading.
- **JIT (Just-In-Time) access and Bastion connectivity are independently gated** — correct Bastion/NSG configuration does not imply JIT is satisfied, and vice versa. Both checks are needed when JIT is in play.
- **File transfer is a native-client-only capability** — it never works through the browser-based portal session or via PowerShell, regardless of SKU. See [Upload and download files using the native client](https://learn.microsoft.com/en-us/azure/bastion/vm-upload-download-native).
